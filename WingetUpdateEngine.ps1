[CmdletBinding()]
param(
    [switch]$CheckOnly,
    [switch]$Scheduled,
    [switch]$SignIn
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$commonPath = Join-Path $PSScriptRoot 'OrbitData.ps1'
if (-not (Test-Path -LiteralPath $commonPath)) { throw 'OrbitData.ps1 is missing.' }
. $commonPath

$dataRoot = Get-OrbitDataRoot
$logRoot = Get-OrbitLogRoot
$tempRoot = Join-Path $dataRoot 'Temp'
$statePath = Join-Path $dataRoot 'state.json'
$updatesPath = Join-Path $dataRoot 'updates.json'
$diagnosticsPath = Join-Path $dataRoot 'last-run.json'
$liveProgressPath = Join-Path $dataRoot 'live-progress.json'
$legacyLogPath = Join-Path $logRoot 'updater.log'
$manualRequestPath = Join-Path $dataRoot 'manual-update-request.json'

foreach ($path in @($dataRoot, $logRoot, $tempRoot, (Split-Path -Parent (Get-OrbitHistoryPath)))) {
    if (-not (Test-Path -LiteralPath $path)) {
        New-Item -ItemType Directory -Path $path -Force | Out-Null
    }
}

$runId = [Guid]::NewGuid().ToString('D')
$startedAt = [DateTimeOffset]::Now
$configuration = Get-OrbitConfiguration
$manualRequest = $null
$selectionSpecified = $false
$selectedPackageIds = @()
$selectedPackageRequests = @()

if ($CheckOnly) {
    $runType = 'manual-check'
}
elseif ($SignIn) {
    $runType = 'sign-in-update'
}
elseif ($Scheduled) {
    $runType = 'scheduled-update'
}
else {
    $runType = 'manual-update'
}

if (-not $CheckOnly -and (Test-Path -LiteralPath $manualRequestPath)) {
    try {
        $candidateRequest = Get-Content -LiteralPath $manualRequestPath -Raw -Encoding UTF8 | ConvertFrom-Json
        $requestedAt = ConvertTo-OrbitDateTimeOffset -Value $candidateRequest.requestedAt
        if ([DateTimeOffset]::Now.Subtract($requestedAt).TotalMinutes -le 2) {
            $manualRequest = $candidateRequest
            $requestMode = if ($null -ne $candidateRequest.PSObject.Properties['mode']) { [string]$candidateRequest.mode } else { 'manual' }
            $runType = if ($requestMode -eq 'startup') { 'startup-update' } else { 'manual-update' }
            if ($null -ne $candidateRequest.PSObject.Properties['selectedPackages']) {
                $selectionSpecified = $true
                $requestKeys = @{}
                foreach ($candidatePackage in @($candidateRequest.selectedPackages)) {
                    if ($null -eq $candidatePackage) { continue }
                    $candidateId = if ($null -ne $candidatePackage.PSObject.Properties['id']) { [string]$candidatePackage.id } else { '' }
                    $candidateSource = if ($null -ne $candidatePackage.PSObject.Properties['source']) { [string]$candidatePackage.source } else { '' }
                    if ([string]::IsNullOrWhiteSpace($candidateId)) { continue }
                    $requestKey = ('{0}|{1}' -f $candidateId.Trim().ToUpperInvariant(), $candidateSource.Trim().ToUpperInvariant())
                    if (-not $requestKeys.ContainsKey($requestKey)) {
                        $requestKeys[$requestKey] = $true
                        $selectedPackageRequests += [PSCustomObject]@{ Id = $candidateId.Trim(); Source = $candidateSource.Trim() }
                    }
                }
                $selectedPackageIds = @($selectedPackageRequests | ForEach-Object { [string]$_.Id })
            }
            elseif ($null -ne $candidateRequest.PSObject.Properties['selectedPackageIds']) {
                $selectionSpecified = $true
                $selectedPackageIds = @($candidateRequest.selectedPackageIds | ForEach-Object { [string]$_ } |
                    Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique)
                $selectedPackageRequests = @($selectedPackageIds | ForEach-Object { [PSCustomObject]@{ Id = [string]$_; Source = '' } })
            }
        }
    }
    catch { }
    finally { Remove-Item -LiteralPath $manualRequestPath -Force -ErrorAction SilentlyContinue }
}

if ($runType -eq 'startup-update' -and
    (-not [bool]$configuration.automaticInstallationEnabled -or -not [bool]$configuration.installOnStartupEnabled)) {
    exit 0
}

# Installed background tasks remain enabled and wake hourly. The user-writable
# configuration decides whether an automatic run is enabled and currently due.
# Manual updates routed through the task bypass this gate.
if (($Scheduled -or $SignIn) -and $runType -notin @('manual-update', 'startup-update')) {
    if (-not [bool]$configuration.automaticUpdatesEnabled) { exit 0 }
    if ($Scheduled -and -not (Test-OrbitAutomaticRunDue -Configuration $configuration -Now $startedAt)) { exit 0 }
    if (-not [bool]$configuration.automaticInstallationEnabled) {
        $runType = if ($SignIn) { 'sign-in-check' } else { 'scheduled-check' }
    }
}

$effectiveCheckOnly = [bool]$CheckOnly -or $runType -in @('scheduled-check', 'sign-in-check')

$logFileName = '{0}_{1}.log' -f $startedAt.ToString('yyyy-MM-dd_HH-mm-ss'), $runType
$runLogPath = Join-Path $logRoot $logFileName
$mutex = $null
$hasMutex = $false
$historyWritten = $false
$wingetVersion = 'Unavailable'
$displayCommand = ''
$standardOutput = ''
$standardError = ''
$exitCode = 1
$technicalSectionsWritten = $false
$wingetWasExecuted = $false
$upgradeItems = @()
$selectedItems = @()
$notSelectedItems = @()
$packageResults = @()
$installedCount = 0
$failedCount = 0
$skippedCount = 0
$restartRequired = $false
$pipelineStopwatch = $null
$ownsLiveProgress = $false
$script:liveProgressLastWriteUtc = [DateTimeOffset]::MinValue
$script:liveProgressLastSignature = ''
$script:liveProgressCurrentItem = $null
$script:liveProgressCurrentIndex = 0
$script:liveProgressCurrentTotal = 0
$script:liveProgressObservedPercentage = $null

function Write-RunLog {
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$Message)
    Add-Content -LiteralPath $runLogPath -Value $Message -Encoding UTF8
}

function Write-LegacySummary {
    param([Parameter(Mandatory = $true)][string]$Message)
    $line = '[{0}] {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message
    Add-Content -LiteralPath $legacyLogPath -Value $line -Encoding UTF8
}

function Write-TechnicalSections {
    $commandText = if ([string]::IsNullOrWhiteSpace($displayCommand)) { 'Not started' } else { $displayCommand }
    Write-RunLog "Winget version: $wingetVersion"
    Write-RunLog "Command: $commandText"
    Write-RunLog ''
    Write-RunLog '--- Standard output ---'
    if ([string]::IsNullOrWhiteSpace($standardOutput)) { Write-RunLog '(no output)' }
    else { Write-RunLog ([string]$standardOutput).TrimEnd() }
    Write-RunLog ''
    Write-RunLog '--- Standard error ---'
    if ([string]::IsNullOrWhiteSpace($standardError)) { Write-RunLog '(no error output)' }
    else { Write-RunLog ([string]$standardError).TrimEnd() }
    $script:technicalSectionsWritten = $true
}

function Write-RunFooter {
    param(
        [Parameter(Mandatory = $true)]$Classification,
        [Parameter(Mandatory = $true)][DateTimeOffset]$FinishedAt,
        [bool]$HasWingetExitCode
    )

    Write-RunLog ''
    Write-RunLog "End time: $($FinishedAt.ToString('o'))"
    if ($HasWingetExitCode) { Write-RunLog "Winget exit code: $exitCode (0x$('{0:X8}' -f $exitCode))" }
    else { Write-RunLog 'Winget exit code: Not available' }
    Write-RunLog "Restart required: $([bool]$Classification.Restart)"
    Write-RunLog "Result: $($Classification.Message)"
}

function Write-State {
    param([Parameter(Mandatory = $true)][hashtable]$State)
    Write-OrbitJsonFile -Path $statePath -Value $State -Depth 6
}

function ConvertTo-NativeArgumentString {
    param([string[]]$Arguments)
    $escaped = foreach ($argument in $Arguments) {
        if ($argument -match '[\s"]') {
            '"{0}"' -f ($argument -replace '(\\*)"', '$1$1\"')
        }
        else { $argument }
    }
    return $escaped -join ' '
}

function Get-OrbitProgressPercentage {
    param([AllowEmptyString()][string]$Text)

    if ([string]::IsNullOrWhiteSpace($Text)) { return $null }
    $normalizedText = $Text -replace '\x1B\[[0-9;?]*[ -/]*[@-~]', ''
    $matches = @([regex]::Matches(
        $normalizedText,
        '(?<![-+\d.,\p{L}])(?<value>\d{1,3}(?:[.,]\d+)?)\s*%(?![%\d\p{L}])',
        [Text.RegularExpressions.RegexOptions]::CultureInvariant
    ))
    for ($index = $matches.Count - 1; $index -ge 0; $index--) {
        $numberText = [string]$matches[$index].Groups['value'].Value
        $value = 0.0
        if ([double]::TryParse(
                ($numberText -replace ',', '.'),
                [Globalization.NumberStyles]::AllowDecimalPoint,
                [Globalization.CultureInfo]::InvariantCulture,
                [ref]$value) -and
            $value -ge 0 -and $value -le 100) {
            return [int][Math]::Round($value, 0, [MidpointRounding]::AwayFromZero)
        }
    }
    return $null
}

function Clear-OrbitLiveProgress {
    Remove-Item -LiteralPath $liveProgressPath -Force -ErrorAction SilentlyContinue
    $script:liveProgressLastSignature = ''
    $script:liveProgressLastWriteUtc = [DateTimeOffset]::MinValue
}

function Publish-OrbitLiveProgress {
    param(
        [ValidateSet('installing', 'finalizing')][string]$Phase = 'installing',
        [AllowNull()]$Item = $null,
        [int]$Index = 0,
        [int]$Total = 0,
        [AllowNull()][Nullable[int]]$Percentage = $null,
        [switch]$Force
    )

    $safeTotal = [Math]::Max(0, $Total)
    $safeIndex = if ($Phase -eq 'installing' -and $safeTotal -gt 0) { [Math]::Min([Math]::Max(1, $Index), $safeTotal) } else { 0 }
    $packageId = if ($null -ne $Item) { [string]$Item.Id } else { '' }
    $packageName = if ($null -ne $Item) { [string]$Item.Name } else { '' }
    $percentageValue = if ($null -ne $Percentage) { [Math]::Min(100, [Math]::Max(0, [int]$Percentage)) } else { $null }
    $signature = '{0}|{1}|{2}|{3}|{4}' -f $Phase,$packageId,$safeIndex,$safeTotal,$percentageValue
    if ($signature -eq $script:liveProgressLastSignature) { return }

    $now = [DateTimeOffset]::UtcNow
    if (-not $Force -and $script:liveProgressLastWriteUtc -ne [DateTimeOffset]::MinValue -and
        $now.Subtract($script:liveProgressLastWriteUtc).TotalMilliseconds -lt 200) { return }

    Write-OrbitJsonFile -Path $liveProgressPath -Value ([ordered]@{
        schemaVersion   = 1
        runId           = $runId
        engineProcessId = $PID
        phase           = $Phase
        packageName     = $packageName
        packageId       = $packageId
        packageSource   = if ($null -ne $Item) { [string]$Item.Source } else { '' }
        currentIndex    = $safeIndex
        totalPackages   = $safeTotal
        percentage      = $percentageValue
        isIndeterminate = $null -eq $percentageValue
        updatedAt       = $now.ToString('o')
    }) -Depth 5
    $script:liveProgressLastSignature = $signature
    $script:liveProgressLastWriteUtc = $now
}

function Invoke-OrbitProcessOutputCallback {
    param(
        [AllowNull()][scriptblock]$Callback,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Text,
        [ValidateSet('stdout', 'stderr')][string]$Stream,
        [long]$ElapsedMilliseconds
    )

    if ($null -eq $Callback) { return }
    try {
        & $Callback ([PSCustomObject]@{
            Text = $Text
            Stream = $Stream
            ElapsedMilliseconds = $ElapsedMilliseconds
        })
    }
    catch {
        # Progress reporting is best-effort and must never fail the package process.
    }
}

function Invoke-HiddenProcess {
    param(
        [Parameter(Mandatory = $true)][string]$FilePath,
        [Parameter(Mandatory = $true)][string[]]$Arguments,
        [AllowNull()][scriptblock]$OutputCallback = $null
    )

    $startInfo = New-Object Diagnostics.ProcessStartInfo
    $startInfo.FileName = $FilePath
    $startInfo.Arguments = ConvertTo-NativeArgumentString -Arguments $Arguments
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.WindowStyle = [Diagnostics.ProcessWindowStyle]::Hidden
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    try {
        $utf8 = New-Object Text.UTF8Encoding($false)
        $startInfo.StandardOutputEncoding = $utf8
        $startInfo.StandardErrorEncoding = $utf8
    }
    catch { }

    $process = New-Object Diagnostics.Process
    $process.StartInfo = $startInfo
    $outputSource = 'OrbitUpdater.ProcessOutput.{0}' -f [Guid]::NewGuid().ToString('N')
    $errorSource = 'OrbitUpdater.ProcessError.{0}' -f [Guid]::NewGuid().ToString('N')
    $outputRegistration = $null
    $errorRegistration = $null
    $outputLines = New-Object 'System.Collections.Generic.List[string]'
    $errorLines = New-Object 'System.Collections.Generic.List[string]'
    $firstOutputMilliseconds = [long]-1
    $stopwatch = New-Object Diagnostics.Stopwatch
    try {
        $outputRegistration = Register-ObjectEvent -InputObject $process -EventName OutputDataReceived -SourceIdentifier $outputSource
        $errorRegistration = Register-ObjectEvent -InputObject $process -EventName ErrorDataReceived -SourceIdentifier $errorSource
        $stopwatch.Start()
        if (-not $process.Start()) { throw "Could not start $FilePath" }
        $process.BeginOutputReadLine()
        $process.BeginErrorReadLine()

        do {
            foreach ($event in @(Get-Event -SourceIdentifier $outputSource -ErrorAction SilentlyContinue)) {
                if ($null -ne $event.SourceEventArgs.Data) {
                    if ($firstOutputMilliseconds -lt 0) { $firstOutputMilliseconds = $stopwatch.ElapsedMilliseconds }
                    $outputText = [string]$event.SourceEventArgs.Data
                    $outputLines.Add($outputText)
                    Invoke-OrbitProcessOutputCallback -Callback $OutputCallback -Text $outputText -Stream stdout -ElapsedMilliseconds $stopwatch.ElapsedMilliseconds
                }
                Remove-Event -EventIdentifier $event.EventIdentifier -ErrorAction SilentlyContinue
            }
            foreach ($event in @(Get-Event -SourceIdentifier $errorSource -ErrorAction SilentlyContinue)) {
                if ($null -ne $event.SourceEventArgs.Data) {
                    if ($firstOutputMilliseconds -lt 0) { $firstOutputMilliseconds = $stopwatch.ElapsedMilliseconds }
                    $errorText = [string]$event.SourceEventArgs.Data
                    $errorLines.Add($errorText)
                    Invoke-OrbitProcessOutputCallback -Callback $OutputCallback -Text $errorText -Stream stderr -ElapsedMilliseconds $stopwatch.ElapsedMilliseconds
                }
                Remove-Event -EventIdentifier $event.EventIdentifier -ErrorAction SilentlyContinue
            }
        } while (-not $process.WaitForExit(100))

        $process.WaitForExit()
        foreach ($event in @(Get-Event -SourceIdentifier $outputSource -ErrorAction SilentlyContinue)) {
            if ($null -ne $event.SourceEventArgs.Data) {
                if ($firstOutputMilliseconds -lt 0) { $firstOutputMilliseconds = $stopwatch.ElapsedMilliseconds }
                $outputText = [string]$event.SourceEventArgs.Data
                $outputLines.Add($outputText)
                Invoke-OrbitProcessOutputCallback -Callback $OutputCallback -Text $outputText -Stream stdout -ElapsedMilliseconds $stopwatch.ElapsedMilliseconds
            }
            Remove-Event -EventIdentifier $event.EventIdentifier -ErrorAction SilentlyContinue
        }
        foreach ($event in @(Get-Event -SourceIdentifier $errorSource -ErrorAction SilentlyContinue)) {
            if ($null -ne $event.SourceEventArgs.Data) {
                if ($firstOutputMilliseconds -lt 0) { $firstOutputMilliseconds = $stopwatch.ElapsedMilliseconds }
                $errorText = [string]$event.SourceEventArgs.Data
                $errorLines.Add($errorText)
                Invoke-OrbitProcessOutputCallback -Callback $OutputCallback -Text $errorText -Stream stderr -ElapsedMilliseconds $stopwatch.ElapsedMilliseconds
            }
            Remove-Event -EventIdentifier $event.EventIdentifier -ErrorAction SilentlyContinue
        }
        $stopwatch.Stop()
        return [PSCustomObject]@{
            ExitCode       = $process.ExitCode
            StandardOutput = [string]($outputLines -join "`r`n")
            StandardError  = [string]($errorLines -join "`r`n")
            FirstOutputMilliseconds = $firstOutputMilliseconds
            DurationMilliseconds = [long]$stopwatch.ElapsedMilliseconds
        }
    }
    finally {
        if ($stopwatch.IsRunning) { $stopwatch.Stop() }
        if ($null -ne $outputRegistration) { Unregister-Event -SourceIdentifier $outputSource -ErrorAction SilentlyContinue }
        if ($null -ne $errorRegistration) { Unregister-Event -SourceIdentifier $errorSource -ErrorAction SilentlyContinue }
        Get-Event -SourceIdentifier $outputSource -ErrorAction SilentlyContinue | Remove-Event -ErrorAction SilentlyContinue
        Get-Event -SourceIdentifier $errorSource -ErrorAction SilentlyContinue | Remove-Event -ErrorAction SilentlyContinue
        if ($null -ne $outputRegistration) { Remove-Job -Job $outputRegistration -Force -ErrorAction SilentlyContinue }
        if ($null -ne $errorRegistration) { Remove-Job -Job $errorRegistration -Force -ErrorAction SilentlyContinue }
        $process.Dispose()
    }
}

function Get-WingetUpgradeParseResult {
    param([string]$Output)

    $items = @()
    $summaryCounts = New-Object 'System.Collections.Generic.List[int]'
    $rejectedCandidates = 0
    $separatorIndex = -1
    $columnStarts = @()

    if (-not [string]::IsNullOrWhiteSpace($Output)) {
        $lines = @($Output -split "`r?`n")
        for ($index = 0; $index -lt $lines.Count; $index++) {
            $candidate = ($lines[$index] -replace '\x1B\[[0-9;?]*[ -/]*[@-~]', '' -replace '[\x00-\x1F]', '').Trim()
            if ($candidate -match '^-{10,}$') {
                $separatorIndex = $index
                $headerIndex = $index - 1
                while ($headerIndex -ge 0 -and [string]::IsNullOrWhiteSpace($lines[$headerIndex])) { $headerIndex-- }
                if ($headerIndex -ge 0) {
                    $header = ($lines[$headerIndex] -replace '\x1B\[[0-9;?]*[ -/]*[@-~]', '' -replace '[\x00-\x1F]', '').TrimEnd()

                    # Normal Winget tables pad the five localized headings with at
                    # least two spaces. Some compact layouts use only one space
                    # between their final headings, so fall back to token starts
                    # only when the header still has exactly five tokens.
                    $headerColumns = @([regex]::Matches($header, '\S(?:.*?\S)?(?=\s{2,}|\s*$)'))
                    if ($headerColumns.Count -eq 5) {
                        $columnStarts = @($headerColumns | ForEach-Object { [int]$_.Index })
                    }
                    else {
                        $headerTokens = @([regex]::Matches($header, '\S+'))
                        if ($headerTokens.Count -eq 5) {
                            $columnStarts = @($headerTokens | ForEach-Object { [int]$_.Index })
                        }
                    }
                }
                break
            }
        }

        $scanStart = if ($separatorIndex -ge 0) { $separatorIndex + 1 } else { 0 }
        for ($index = $scanStart; $index -lt $lines.Count; $index++) {
            $line = ($lines[$index] -replace '\x1B\[[0-9;?]*[ -/]*[@-~]', '' -replace '[\x00-\x1F]', '').TrimEnd()
            if ([string]::IsNullOrWhiteSpace($line) -or $line.Trim() -match '^-{10,}$') { continue }

            $isPackageRow = $false
            if ($columnStarts.Count -eq 5) {
                $columns = @()
                for ($columnIndex = 0; $columnIndex -lt 5; $columnIndex++) {
                    $start = [int]$columnStarts[$columnIndex]
                    if ($line.Length -le $start) { $columns += ''; continue }
                    $length = if ($columnIndex -lt 4) {
                        [Math]::Min([int]$columnStarts[$columnIndex + 1] - $start, $line.Length - $start)
                    }
                    else { $line.Length - $start }
                    $columns += $line.Substring($start, $length).Trim()
                }

                $hasAllColumns = -not ([string]::IsNullOrWhiteSpace($columns[0]) -or
                    [string]::IsNullOrWhiteSpace($columns[1]) -or
                    [string]::IsNullOrWhiteSpace($columns[2]) -or
                    [string]::IsNullOrWhiteSpace($columns[3]) -or
                    [string]::IsNullOrWhiteSpace($columns[4]))
                if ($hasAllColumns -and $columns[1] -notmatch '\s' -and $columns[4] -notmatch '\s') {
                    $name = [string]$columns[0]
                    $installedVersion = [string]$columns[2]
                    $duplicateVersionSuffix = ' ' + $installedVersion
                    if ($name.EndsWith($duplicateVersionSuffix, [StringComparison]::OrdinalIgnoreCase)) {
                        $name = $name.Substring(0, $name.Length - $duplicateVersionSuffix.Length).TrimEnd()
                    }
                    if (-not [string]::IsNullOrWhiteSpace($name)) {
                        $items += [PSCustomObject][ordered]@{
                            Name             = $name
                            Id               = [string]$columns[1]
                            InstalledVersion = $installedVersion
                            AvailableVersion = [string]$columns[3]
                            Source           = [string]$columns[4]
                        }
                        $isPackageRow = $true
                    }
                }
                elseif (@($columns | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }).Count -ge 4) {
                    $rejectedCandidates++
                }
            }

            if (-not $isPackageRow) {
                # Winget's count sentence is localized. Treat a compact line that
                # begins with one integer and otherwise contains only human text as
                # a defensive consistency signal, never as package data.
                $summaryMatch = [regex]::Match($line, '^\s*(?<count>[0-9]+)\s+(?=[^\r\n]*\p{L})[^0-9\r\n]*\s*$')
                if ($summaryMatch.Success -and $line.Length -le 160) {
                    [void]$summaryCounts.Add([int]$summaryMatch.Groups['count'].Value)
                }
            }
        }
    }

    $distinctSummaryCounts = @($summaryCounts | Select-Object -Unique)
    $expectedCount = if ($distinctSummaryCounts.Count -eq 1) { [int]$distinctSummaryCounts[0] } else { $null }
    $isConsistent = $true
    $reason = ''
    if ($distinctSummaryCounts.Count -gt 1) {
        $isConsistent = $false
        $reason = 'Winget emitted conflicting update counts.'
    }
    elseif ($separatorIndex -ge 0 -and $columnStarts.Count -ne 5) {
        $isConsistent = $false
        $reason = 'Orbit could not determine all five Winget table columns.'
    }
    elseif ($null -ne $expectedCount -and $expectedCount -ne $items.Count) {
        $isConsistent = $false
        $reason = 'The reported update count does not match the parsed package count.'
    }
    elseif ($rejectedCandidates -gt 0) {
        $isConsistent = $false
        $reason = 'One or more package-like rows could not be parsed safely.'
    }
    elseif ($separatorIndex -ge 0 -and $null -eq $expectedCount -and $items.Count -eq 0) {
        $isConsistent = $false
        $reason = 'Winget emitted a package table, but Orbit could not recover any package rows.'
    }

    $reportedText = if ($distinctSummaryCounts.Count -gt 1) { 'ambiguous' } elseif ($null -ne $expectedCount) { [string]$expectedCount } else { 'not available' }
    $diagnosticLines = @(
        "Winget reported updates: $reportedText"
        "Orbit parsed packages: $($items.Count)"
        "Parser consistency check: $(if ($isConsistent) { 'PASSED' } else { 'FAILED' })"
    )
    if (-not [string]::IsNullOrWhiteSpace($reason)) { $diagnosticLines += "Parser consistency reason: $reason" }
    if ($rejectedCandidates -gt 0) { $diagnosticLines += "Rejected package-like rows: $rejectedCandidates" }

    return [PSCustomObject][ordered]@{
        Items              = @($items)
        ExpectedCount      = $expectedCount
        IsConsistent       = $isConsistent
        DiagnosticLines    = @($diagnosticLines)
        ConsistencyReason  = $reason
    }
}

function Get-WingetUpgradeItems {
    param([string]$Output)

    return @((Get-WingetUpgradeParseResult -Output $Output).Items)
}

function Get-IncompleteParseClassification {
    return [PSCustomObject]@{
        State = 'LastCheckFailed'
        History = 'failed'
        Category = 'incomplete-parse'
        Message = 'Winget found updates, but Orbit could not read all package details.'
        Restart = $false
    }
}

function Write-AvailableUpdates {
    param(
        [object[]]$Items,
        [ValidateSet('Available', 'Processed', 'Failed')][string]$Status
    )
    $payload = [ordered]@{
        schemaVersion = 1
        generatedAt   = [DateTimeOffset]::Now.ToString('o')
        status        = $Status
        count         = @($Items).Count
        items         = @($Items)
    }
    Write-OrbitJsonFile -Path $updatesPath -Value $payload -Depth 6
}

function Get-ResultClassification {
    param(
        [int]$Code,
        [bool]$IsCheck,
        [int]$UpdatesFound
    )

    $hex = '{0:X8}' -f $Code
    if ($Code -eq 0) {
        if ($UpdatesFound -eq 0) {
            return [PSCustomObject]@{ State = 'NoUpdates'; History = 'no-updates-found'; Category = 'none'; Message = 'No applicable Winget updates were found.'; Restart = $false }
        }
        if ($IsCheck) {
            $label = if ($UpdatesFound -eq 1) { '1 Winget update is available.' } else { "$UpdatesFound Winget updates are available." }
            return [PSCustomObject]@{ State = 'UpdatesAvailable'; History = 'success'; Category = 'updates-available'; Message = $label; Restart = $false }
        }
        return [PSCustomObject]@{ State = 'Success'; History = 'success'; Category = 'none'; Message = 'The Winget update run completed successfully.'; Restart = $false }
    }

    switch ($hex) {
        '8A15002B' { return [PSCustomObject]@{ State = 'NoUpdates'; History = 'no-updates-found'; Category = 'none'; Message = 'No applicable Winget updates were found.'; Restart = $false } }
        '8A15002C' { return [PSCustomObject]@{ State = 'ActionRequired'; History = $(if ($IsCheck) { 'failed' } else { 'partial-success' }); Category = 'partial-success'; Message = 'Some Winget updates completed, but one or more packages need attention.'; Restart = $false } }
        # A signal or app termination proves interruption, not explicit cancellation.
        '8A150005' { return [PSCustomObject]@{ State = $(if ($IsCheck) { 'LastCheckFailed' } else { 'ActionRequired' }); History = 'failed'; Category = 'interrupted'; Message = 'The Winget operation was interrupted before completion.'; Restart = $false } }
        '8A15006A' { return [PSCustomObject]@{ State = $(if ($IsCheck) { 'LastCheckFailed' } else { 'ActionRequired' }); History = 'failed'; Category = 'app-termination'; Message = 'The Winget operation stopped because the application was closing.'; Restart = $false } }
        '8A15008E' { return [PSCustomObject]@{ State = 'ActionRequired'; History = 'failed'; Category = 'installer-technology-mismatch'; Message = 'Manual action required. The newer version uses a different installer technology; the existing version may need to be removed before reinstalling.'; Restart = $false } }
        '8A150010' { return [PSCustomObject]@{ State = 'ActionRequired'; History = 'failed'; Category = 'no-applicable-installer'; Message = 'No applicable installer is available for this Windows configuration.'; Restart = $false } }
        '8A15005F' { return [PSCustomObject]@{ State = 'ActionRequired'; History = 'failed'; Category = 'install-location-required'; Message = 'This update requires an install location that has not been configured.'; Restart = $false } }
        '8A150050' { return [PSCustomObject]@{ State = 'ActionRequired'; History = 'failed'; Category = 'installed-version-unknown'; Message = 'Version information is unavailable, so Winget could not safely complete the upgrade.'; Restart = $false } }
        '8A15004F' { return [PSCustomObject]@{ State = 'ActionRequired'; History = 'failed'; Category = 'package-skipped'; Message = 'Winget skipped a package because the offered version is not newer than the installed version.'; Restart = $false } }
        '8A150056' { return [PSCustomObject]@{ State = 'ActionRequired'; History = 'failed'; Category = 'installer-context'; Message = 'The installer cannot run with administrator privileges. This package needs a user-level update.'; Restart = $false } }
        '8A150068' { return [PSCustomObject]@{ State = 'ActionRequired'; History = 'failed'; Category = 'package-pinned'; Message = 'A package is pinned and was skipped by Winget.'; Restart = $false } }
        '8A15007D' { return [PSCustomObject]@{ State = 'ActionRequired'; History = 'failed'; Category = 'installer-context'; Message = 'A user-scoped package cannot be updated from an administrator context.'; Restart = $false } }
        '8A150041' { return [PSCustomObject]@{ State = 'ActionRequired'; History = 'failed'; Category = 'agreement-failure'; Message = 'A package agreement was not accepted.'; Restart = $false } }
        '8A150046' { return [PSCustomObject]@{ State = 'ActionRequired'; History = 'failed'; Category = 'agreement-failure'; Message = 'A Winget source agreement was not accepted.'; Restart = $false } }
        '8A15000B' { return [PSCustomObject]@{ State = 'LastCheckFailed'; History = 'failed'; Category = 'source-failure'; Message = 'Winget source information is unavailable or damaged.'; Restart = $false } }
        '8A150045' { return [PSCustomObject]@{ State = 'LastCheckFailed'; History = 'failed'; Category = 'source-failure'; Message = 'Winget could not open one of its package sources.'; Restart = $false } }
        '8A15004B' { return [PSCustomObject]@{ State = 'LastCheckFailed'; History = $(if ($IsCheck) { 'failed' } else { 'partial-success' }); Category = 'source-failure'; Message = 'Winget could not open all configured package sources.'; Restart = $false } }
        '8A150065' { return [PSCustomObject]@{ State = 'ActionRequired'; History = $(if ($IsCheck) { 'failed' } else { 'partial-success' }); Category = 'partial-success'; Message = 'Some packages installed, but one or more installations failed.'; Restart = $false } }
        '8A15006D' { return [PSCustomObject]@{ State = 'LastCheckFailed'; History = 'failed'; Category = 'service-unavailable'; Message = 'A service required by Winget is unavailable. Try again later.'; Restart = $false } }
        '8A150101' { return [PSCustomObject]@{ State = 'ActionRequired'; History = 'failed'; Category = 'package-in-use'; Message = 'Close the application that is being updated, then try again.'; Restart = $false } }
        '8A150102' { return [PSCustomObject]@{ State = 'ActionRequired'; History = 'failed'; Category = 'installation-in-progress'; Message = 'Another installation is already in progress. Try again when it finishes.'; Restart = $false } }
        '8A150103' { return [PSCustomObject]@{ State = 'ActionRequired'; History = 'failed'; Category = 'file-in-use'; Message = 'A required file is in use. Close the affected application, then try again.'; Restart = $false } }
        '8A150105' { return [PSCustomObject]@{ State = 'ActionRequired'; History = 'failed'; Category = 'disk-full'; Message = 'There is not enough free disk space to install an update.'; Restart = $false } }
        '8A150107' { return [PSCustomObject]@{ State = 'LastCheckFailed'; History = 'failed'; Category = 'network-required'; Message = 'An installer needs an internet connection. Check the network, then try again.'; Restart = $false } }
        '8A150109' { return [PSCustomObject]@{ State = 'RestartRequired'; History = 'success'; Category = 'restart-required'; Message = 'Updates were installed. Restart Windows to finish.'; Restart = $true } }
        '8A15010A' { return [PSCustomObject]@{ State = 'RestartRequired'; History = 'failed'; Category = 'restart-required'; Message = 'Restart Windows, then run the update again.'; Restart = $true } }
        '8A15010B' { return [PSCustomObject]@{ State = 'RestartRequired'; History = 'success'; Category = 'restart-required'; Message = 'Windows is restarting to finish an installation.'; Restart = $true } }
        '8A15010C' { return [PSCustomObject]@{ State = 'Cancelled'; History = 'cancelled'; Category = 'cancelled'; Message = 'The installer was cancelled.'; Restart = $false } }
        '8A150114' { return [PSCustomObject]@{ State = 'ActionRequired'; History = 'failed'; Category = 'upgrade-not-supported'; Message = 'The installer does not support upgrading the existing installation. Manual action may be required.'; Restart = $false } }
        '00000BC2' { return [PSCustomObject]@{ State = 'RestartRequired'; History = 'success'; Category = 'restart-required'; Message = 'Updates were installed. Restart Windows to finish.'; Restart = $true } }
        default {
            $defaultState = if ($IsCheck) { 'LastCheckFailed' } else { 'ActionRequired' }
            $defaultCategory = if ($IsCheck) { 'check-failed' } else { 'installation-failed' }
            return [PSCustomObject]@{ State = $defaultState; History = 'failed'; Category = $defaultCategory; Message = 'Winget could not complete the operation. Open technical details for more information.'; Restart = $false }
        }
    }
}

function New-HistoryPackages {
    param(
        [object[]]$Items,
        [string]$HistoryStatus,
        [bool]$IsCheck,
        [bool]$RestartRequired
    )

    $packages = @()
    foreach ($item in @($Items)) {
        if ($IsCheck) {
            $packageResult = 'available'
            $packageMessage = 'A newer version is available through Winget.'
        }
        elseif ($HistoryStatus -eq 'success') {
            $packageResult = if ($RestartRequired) { 'installed-restart-required' } else { 'installed' }
            $packageMessage = if ($RestartRequired) { 'Installed; restart required.' } else { 'Installed successfully.' }
        }
        else {
            $packageResult = 'not-reported'
            $packageMessage = 'Winget did not provide a reliable per-package result for this run.'
        }

        $packages += [PSCustomObject][ordered]@{
            applicationName = [string]$item.Name
            packageId       = [string]$item.Id
            oldVersion      = [string]$item.InstalledVersion
            newVersion      = [string]$item.AvailableVersion
            source          = [string]$item.Source
            result          = $packageResult
            message         = $packageMessage
        }
    }
    return $packages
}

function New-PackageHistoryResult {
    param(
        [Parameter(Mandatory = $true)]$Item,
        [Parameter(Mandatory = $true)][string]$Result,
        [Parameter(Mandatory = $true)][string]$Message,
        [AllowNull()]$ExitCode = $null,
        [AllowEmptyString()][string]$ErrorCategory = ''
    )

    return [PSCustomObject][ordered]@{
        applicationName = [string]$Item.Name
        packageId       = [string]$Item.Id
        oldVersion      = [string]$Item.InstalledVersion
        newVersion      = [string]$Item.AvailableVersion
        source          = [string]$Item.Source
        result          = $Result
        message         = $Message
        exitCode        = $ExitCode
        errorCategory   = $ErrorCategory
    }
}

function Write-PackageProcessSection {
    param(
        [Parameter(Mandatory = $true)]$Item,
        [Parameter(Mandatory = $true)][string]$Command,
        [Parameter(Mandatory = $true)]$Result,
        [long]$QueueOffsetMilliseconds = -1
    )

    Write-RunLog ''
    Write-RunLog ('[{0}] Package: {1} ({2})' -f ([DateTimeOffset]::Now.ToString('o')), [string]$Item.Name, [string]$Item.Id)
    Write-RunLog "Command: $Command"
    if ($QueueOffsetMilliseconds -ge 0) { Write-RunLog ('Process start: T+{0:N3} s' -f ($QueueOffsetMilliseconds / 1000.0)) }
    if ([long]$Result.FirstOutputMilliseconds -ge 0) { Write-RunLog ('Time to first output: {0:N3} s' -f ([long]$Result.FirstOutputMilliseconds / 1000.0)) }
    else { Write-RunLog 'Time to first output: no output captured' }
    Write-RunLog ('Package process duration: {0:N3} s' -f ([long]$Result.DurationMilliseconds / 1000.0))
    Write-RunLog "Exit code: $([int]$Result.ExitCode) (0x$('{0:X8}' -f [int]$Result.ExitCode))"
    Write-RunLog '--- Standard output ---'
    if ([string]::IsNullOrWhiteSpace([string]$Result.StandardOutput)) { Write-RunLog '(no output)' }
    else { Write-RunLog ([string]$Result.StandardOutput).TrimEnd() }
    Write-RunLog '--- Standard error ---'
    if ([string]::IsNullOrWhiteSpace([string]$Result.StandardError)) { Write-RunLog '(no error output)' }
    else { Write-RunLog ([string]$Result.StandardError).TrimEnd() }
}

function Get-PackageQueueClassification {
    param(
        [int]$Selected,
        [int]$Installed,
        [int]$Failed,
        [int]$Skipped,
        [bool]$RestartRequired,
        [object[]]$PackageResults = @()
    )

    $failedPackages = @($PackageResults | Where-Object { [string]$_.result -eq 'failed' })
    $firstFailure = if ($failedPackages.Count -gt 0) { $failedPackages[0] } else { $null }
    $failureDetail = if ($null -ne $firstFailure -and -not [string]::IsNullOrWhiteSpace([string]$firstFailure.message)) { [string]$firstFailure.message } else { '' }
    $failureName = if ($null -ne $firstFailure -and -not [string]::IsNullOrWhiteSpace([string]$firstFailure.applicationName)) { [string]$firstFailure.applicationName } else { 'The selected update' }

    if ($Failed -gt 0 -and $Installed -gt 0) {
        $message = "$Installed of $Selected selected updates were installed. $Failed could not be installed."
        if ($Failed -eq 1 -and -not [string]::IsNullOrWhiteSpace($failureDetail)) { $message += " $failureName`: $failureDetail" }
        return [PSCustomObject]@{
            State='CompletedWithIssues'; History='partial-success'; Category='partial-success'
            Message=$message
            Restart=$RestartRequired
        }
    }
    if ($Failed -gt 0) {
        $message = if ($Selected -eq 1 -and $Failed -eq 1) { "$failureName could not be updated." } else { "$Failed of $Selected selected updates could not be installed." }
        if ($Failed -eq 1 -and -not [string]::IsNullOrWhiteSpace($failureDetail)) { $message += " $failureDetail" }
        return [PSCustomObject]@{
            State='ActionRequired'; History='failed'; Category='installation-failed'
            Message=$message
            Restart=$RestartRequired
        }
    }
    if ($RestartRequired) {
        return [PSCustomObject]@{
            State='RestartRequired'; History='success'; Category='restart-required'
            Message='The selected updates were installed. Restart Windows to finish.'
            Restart=$true
        }
    }
    if ($Selected -eq 0) {
        return [PSCustomObject]@{
            State='NoUpdates'; History='not-started'; Category='nothing-selected'
            Message='No updates were selected for installation.'
            Restart=$false
        }
    }
    $message = if ($Installed -eq 1) { 'The selected update was installed successfully.' } else { 'All selected updates were installed successfully.' }
    return [PSCustomObject]@{
        State='Success'; History='success'; Category='none'; Message=$message; Restart=$false
    }
}

function Send-OrbitBackgroundNotification {
    param(
        [Parameter(Mandatory = $true)][string]$Title,
        [Parameter(Mandatory = $true)][string]$Body,
        [Parameter(Mandatory = $true)][string]$Fingerprint
    )

    if (-not [bool]$configuration.notificationsEnabled -or [string]::IsNullOrWhiteSpace($Fingerprint)) { return $false }
    $notificationStatePath = Join-Path $dataRoot 'notification-state.json'
    $stateEntries = @()
    try {
        if (Test-Path -LiteralPath $notificationStatePath) {
            $savedState = Get-Content -LiteralPath $notificationStatePath -Raw -Encoding UTF8 | ConvertFrom-Json
            if ($null -ne $savedState.PSObject.Properties['entries']) { $stateEntries = @($savedState.entries) }
        }
    }
    catch {
        Write-RunLog "Notification state warning: $($_.Exception.Message)"
        $stateEntries = @()
    }

    if (@($stateEntries | Where-Object { [string]$_.fingerprint -eq $Fingerprint }).Count -gt 0) {
        Write-RunLog 'Notification suppressed because the same background result was already reported.'
        return $false
    }

    try {
        if (-not [string]::IsNullOrWhiteSpace($env:ORBIT_UPDATER_TEST_ROOT) -and $env:ORBIT_UPDATER_TEST_NOTIFICATION_FAILURE -eq '1') { throw 'Simulated notification delivery failure.' }
        if (-not [string]::IsNullOrWhiteSpace($env:ORBIT_UPDATER_TEST_ROOT)) {
            $testNotificationPath = Join-Path $dataRoot 'notification-test.json'
            $testEntries = @()
            if (Test-Path -LiteralPath $testNotificationPath) {
                try {
                    $testPayload = Get-Content -LiteralPath $testNotificationPath -Raw -Encoding UTF8 | ConvertFrom-Json
                    if ($null -ne $testPayload.PSObject.Properties['entries']) { $testEntries = @($testPayload.entries) }
                }
                catch { $testEntries = @() }
            }
            $testEntries += [PSCustomObject][ordered]@{ title=$Title; body=$Body; fingerprint=$Fingerprint; launch='orbitupdater://overview'; sentAt=[DateTimeOffset]::Now.ToString('o') }
            Write-OrbitJsonFile -Path $testNotificationPath -Value ([ordered]@{schemaVersion=1;entries=$testEntries}) -Depth 6
        }
        else {
            Add-Type -AssemblyName System.Runtime.WindowsRuntime -ErrorAction Stop
            $escapedTitle = [Security.SecurityElement]::Escape($Title)
            $escapedBody = [Security.SecurityElement]::Escape($Body)
            $toastXml = @"
<toast activationType="protocol" launch="orbitupdater://overview">
  <visual><binding template="ToastGeneric"><text>$escapedTitle</text><text>$escapedBody</text></binding></visual>
</toast>
"@
            $xmlDocument = New-Object 'Windows.Data.Xml.Dom.XmlDocument, Windows.Data.Xml.Dom, ContentType=WindowsRuntime'
            $xmlDocument.LoadXml($toastXml)
            $toast = New-Object 'Windows.UI.Notifications.ToastNotification, Windows.UI.Notifications, ContentType=WindowsRuntime' -ArgumentList $xmlDocument
            $notifier = [Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType=WindowsRuntime]::CreateToastNotifier($script:OrbitAppUserModelId)
            $notifier.Show($toast)
        }

        $stateEntries += [PSCustomObject][ordered]@{fingerprint=$Fingerprint;sentAt=[DateTimeOffset]::Now.ToString('o')}
        if ($stateEntries.Count -gt 50) { $stateEntries = @($stateEntries | Select-Object -Last 50) }
        Write-OrbitJsonFile -Path $notificationStatePath -Value ([ordered]@{schemaVersion=1;entries=$stateEntries}) -Depth 5
        Write-RunLog "Notification sent: $Title"
        return $true
    }
    catch {
        Write-RunLog "Notification delivery warning: $($_.Exception.Message)"
        return $false
    }
}

function Send-OrbitRunNotification {
    param(
        [Parameter(Mandatory = $true)]$Classification,
        [object[]]$DetectedItems = @(),
        [int]$Installed = 0,
        [int]$Failed = 0
    )

    if ($runType -notin @('scheduled-check','sign-in-check','scheduled-update','sign-in-update')) { return $false }
    $packageFingerprint = @($DetectedItems | ForEach-Object { '{0}@{1}' -f [string]$_.Id,[string]$_.AvailableVersion } | Sort-Object) -join '|'
    if ([string]$Classification.Category -eq 'incomplete-parse') {
        $body = if ([string]$Classification.State -eq 'CompletedWithIssues') {
            'Updates were processed, but Orbit could not verify whether more updates remain.'
        }
        else {
            'Winget found updates, but Orbit could not read all package details.'
        }
        return Send-OrbitBackgroundNotification -Title 'Update check needs attention' -Body $body -Fingerprint "incomplete-parse|$packageFingerprint"
    }
    if ([string]$Classification.State -eq 'UpdatesAvailable') {
        $count = @($DetectedItems).Count
        $title = if($count -eq 1){'1 update available'}else{"$count updates available"}
        return Send-OrbitBackgroundNotification -Title $title -Body 'Open Orbit to review and install them.' -Fingerprint "updates-available|$packageFingerprint"
    }
    if ([string]$Classification.State -eq 'CompletedWithIssues') {
        return Send-OrbitBackgroundNotification -Title 'Updates need attention' -Body "$Installed updates were installed. $Failed could not be installed." -Fingerprint "partial|$Installed|$Failed|$packageFingerprint"
    }
    if ([string]$Classification.History -eq 'failed') {
        if($runType -in @('scheduled-check','sign-in-check')){
            return Send-OrbitBackgroundNotification -Title 'Update check failed' -Body 'Orbit could not check for updates.' -Fingerprint "check-failed|$packageFingerprint"
        }
        return Send-OrbitBackgroundNotification -Title 'Update failed' -Body 'Orbit could not install the available updates.' -Fingerprint "failed|$Failed|$packageFingerprint"
    }
    if ([string]$Classification.History -eq 'success' -and $Installed -gt 0) {
        $body = if($Installed -eq 1){'1 update was installed successfully.'}else{"$Installed updates were installed successfully."}
        return Send-OrbitBackgroundNotification -Title 'Updates installed' -Body $body -Fingerprint "installed|$Installed|$packageFingerprint"
    }
    return $false
}

function Complete-Run {
    param(
        [Parameter(Mandatory = $true)]$Classification,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]]$Items,
        [Parameter(Mandatory = $true)][DateTimeOffset]$FinishedAt,
        [AllowNull()][object[]]$PackageResults = $null,
        [int]$SelectedCount = -1,
        [int]$InstalledCount = -1,
        [int]$FailedCount = -1,
        [int]$SkippedCount = -1,
        [int]$NotSelectedCount = -1,
        [int]$RemainingCount = -1,
        [switch]$SkipCurrentState
    )

    $durationSeconds = [Math]::Round($FinishedAt.Subtract($startedAt).TotalSeconds, 1)
    $updatesFound = @($Items).Count
    $isCheck = [bool]$effectiveCheckOnly

    if ($InstalledCount -ge 0 -and $FailedCount -ge 0 -and $SkippedCount -ge 0) {
        $installed = $InstalledCount; $failed = $FailedCount; $skipped = $SkippedCount
    }
    elseif ($Classification.History -eq 'no-updates-found') {
        $installed = 0; $failed = 0; $skipped = 0
    }
    elseif ($isCheck) {
        $installed = 0; $failed = 0; $skipped = 0
    }
    elseif ($Classification.History -eq 'success') {
        $installed = $updatesFound; $failed = 0; $skipped = 0
    }
    else {
        $installed = $null; $failed = $null; $skipped = $null
    }

    if ($SelectedCount -lt 0) { $SelectedCount = if ($isCheck) { 0 } else { $updatesFound } }
    if ($NotSelectedCount -lt 0) { $NotSelectedCount = 0 }
    $packages = if ($null -ne $PackageResults) {
        @($PackageResults)
    }
    else {
        @(New-HistoryPackages -Items $Items -HistoryStatus $Classification.History -IsCheck $isCheck -RestartRequired ([bool]$Classification.Restart))
    }
    $historyEntry = [PSCustomObject][ordered]@{
        id              = $runId
        startedAt       = $startedAt.ToString('o')
        finishedAt      = $FinishedAt.ToString('o')
        runType         = $runType
        status          = [string]$Classification.History
        exitCode        = $exitCode
        errorCategory   = [string]$Classification.Category
        message         = [string]$Classification.Message
        updatesFound    = $updatesFound
        updatesSelected = $SelectedCount
        updatesInstalled = $installed
        updatesFailed   = $failed
        updatesSkipped  = $skipped
        updatesNotSelected = $NotSelectedCount
        updatesRemaining = if($RemainingCount -ge 0){$RemainingCount}else{$updatesFound}
        durationSeconds = $durationSeconds
        restartRequired = [bool]$Classification.Restart
        logFile         = $logFileName
        packages        = $packages
    }
    try {
        $historyStopwatch = [Diagnostics.Stopwatch]::StartNew()
        Add-OrbitHistoryEntry -Entry $historyEntry
        $script:historyWritten = $true
        Invoke-OrbitHistoryRetention
        $historyStopwatch.Stop()
        Write-RunLog ('History persistence: {0:N3} s' -f ($historyStopwatch.ElapsedMilliseconds / 1000.0))
    }
    catch {
        Write-RunLog "History storage warning: $($_.Exception.Message)"
    }

    if (-not $SkipCurrentState) {
        Write-State @{
            schemaVersion   = 3
            status          = [string]$Classification.State
            runType         = $runType
            startedAt       = $startedAt.ToString('o')
            completedAt     = $FinishedAt.ToString('o')
            exitCode        = $exitCode
            errorCategory   = [string]$Classification.Category
            message         = [string]$Classification.Message
            restartRequired = [bool]$Classification.Restart
            updatesFound    = $updatesFound
            updatesSelected = $SelectedCount
            updatesInstalled = $installed
            updatesFailed   = $failed
            updatesSkipped  = $skipped
            updatesNotSelected = $NotSelectedCount
            updatesRemaining = if($RemainingCount -ge 0){$RemainingCount}else{$updatesFound}
            logFile         = $logFileName
        }

        Write-OrbitJsonFile -Path $diagnosticsPath -Value ([ordered]@{
            schemaVersion  = 1
            runId          = $runId
            runType        = $runType
            command        = $displayCommand
            standardOutput = $standardOutput
            standardError  = $standardError
            exitCode       = $exitCode
            wingetVersion  = $wingetVersion
            appVersion     = $script:OrbitAppVersion
            startedAt      = $startedAt.ToString('o')
            finishedAt     = $FinishedAt.ToString('o')
            restartRequired = [bool]$Classification.Restart
            logFile        = $logFileName
        }) -Depth 5
    }
}

Write-RunLog "Orbit Updater $($script:OrbitAppVersion)"
Write-RunLog "Run ID: $runId"
Write-RunLog "Start time: $($startedAt.ToString('o'))"
Write-RunLog "Run type: $runType"

try {
    $mutex = New-Object Threading.Mutex($false, 'Local\WingetAutoUpdater.Engine')
    $hasMutex = $mutex.WaitOne(0)
    if (-not $hasMutex) {
        $skipped = [PSCustomObject]@{ State = 'Running'; History = 'skipped'; Category = 'duplicate-run'; Message = 'Another Winget operation is already running.'; Restart = $false }
        $exitCode = 2
        $standardError = 'Another update run already owns the execution lock.'
        $finishedAt = [DateTimeOffset]::Now
        Write-TechnicalSections
        Write-RunFooter -Classification $skipped -FinishedAt $finishedAt -HasWingetExitCode $false
        Write-LegacySummary "$runType skipped; details: $logFileName"
        Complete-Run -Classification $skipped -Items @() -FinishedAt $finishedAt -SelectedCount 0 -InstalledCount 0 -FailedCount 0 -SkippedCount 0 -SkipCurrentState
        exit 2
    }

    if (-not $effectiveCheckOnly) {
        $ownsLiveProgress = $true
        Clear-OrbitLiveProgress
    }

    if (($Scheduled -or $SignIn) -and -not [bool]$configuration.unattendedModeEnabled) {
        $skipped = [PSCustomObject]@{ State = 'ActionRequired'; History = 'skipped'; Category = 'unattended-mode-disabled'; Message = 'The scheduled run was skipped because unattended agreement handling is disabled.'; Restart = $false }
        $exitCode = 3
        $standardError = 'Scheduled execution requires unattended agreement handling.'
        $finishedAt = [DateTimeOffset]::Now
        Write-TechnicalSections
        Write-RunFooter -Classification $skipped -FinishedAt $finishedAt -HasWingetExitCode $false
        Write-LegacySummary "$runType skipped; details: $logFileName"
        Complete-Run -Classification $skipped -Items @() -FinishedAt $finishedAt -SelectedCount 0 -InstalledCount 0 -FailedCount 0 -SkippedCount 0
        exit 3
    }

    Write-State @{
        schemaVersion   = 3
        runId           = $runId
        status          = 'Running'
        runType         = $runType
        startedAt       = $startedAt.ToString('o')
        completedAt     = $null
        exitCode        = $null
        errorCategory   = $null
        message         = if ($effectiveCheckOnly) { 'Checking Winget-managed applications...' } else { 'Installing selected Winget updates...' }
        restartRequired = $false
        updatesFound    = $null
        logFile         = $logFileName
    }

    $wingetPrefixArguments = @()
    if (-not [string]::IsNullOrWhiteSpace($env:ORBIT_UPDATER_TEST_ROOT) -and
        -not [string]::IsNullOrWhiteSpace($env:ORBIT_UPDATER_TEST_WINGET_PATH)) {
        $wingetSource = [IO.Path]::GetFullPath($env:ORBIT_UPDATER_TEST_WINGET_PATH)
        if (-not (Test-Path -LiteralPath $wingetSource -PathType Leaf)) { throw 'WINGET_UNAVAILABLE' }
        if (-not [string]::IsNullOrWhiteSpace($env:ORBIT_UPDATER_TEST_WINGET_SCRIPT)) {
            $wingetPrefixArguments += [IO.Path]::GetFullPath($env:ORBIT_UPDATER_TEST_WINGET_SCRIPT)
        }
    }
    else {
        $winget = Get-Command 'winget.exe' -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($null -eq $winget) { throw 'WINGET_UNAVAILABLE' }
        $wingetSource = $winget.Source
    }

    $pipelineStopwatch = [Diagnostics.Stopwatch]::StartNew()
    try {
        $versionResult = Invoke-HiddenProcess -FilePath $wingetSource -Arguments @($wingetPrefixArguments + @('--version'))
        if ($versionResult.ExitCode -eq 0) { $wingetVersion = $versionResult.StandardOutput.Trim() }
    }
    catch { }

    # Every run begins with the same read-only discovery command. Update runs then
    # target each selected stable package ID independently and perform a final check.
    $checkArguments = @(Get-OrbitWingetArguments -Operation Check -Configuration $configuration)
    $checkCommand = Get-OrbitWingetCommandText -Operation Check -Configuration $configuration
    $result = Invoke-HiddenProcess -FilePath $wingetSource -Arguments @($wingetPrefixArguments + $checkArguments)
    Write-RunLog ('Initial check process: {0:N3} s; first output: {1}' -f
        ($result.DurationMilliseconds / 1000.0),
        $(if ([long]$result.FirstOutputMilliseconds -ge 0) { '{0:N3} s' -f ($result.FirstOutputMilliseconds / 1000.0) } else { 'no output captured' }))
    $wingetWasExecuted = $true
    $exitCode = [int]$result.ExitCode
    $standardOutput = [string]$result.StandardOutput
    $standardError = [string]$result.StandardError
    $parseStopwatch = [Diagnostics.Stopwatch]::StartNew()
    $upgradeParseResult = Get-WingetUpgradeParseResult -Output $standardOutput
    $upgradeItems = @($upgradeParseResult.Items)
    $parseStopwatch.Stop()
    Write-RunLog ('Initial output parsing: {0:N3} s; rows parsed: {1}' -f ($parseStopwatch.ElapsedMilliseconds / 1000.0), $upgradeItems.Count)
    foreach ($diagnosticLine in @($upgradeParseResult.DiagnosticLines)) { Write-RunLog $diagnosticLine }
    $discoveryClassification = Get-ResultClassification -Code $exitCode -IsCheck $true -UpdatesFound $upgradeItems.Count
    if ($exitCode -eq 0 -and -not [bool]$upgradeParseResult.IsConsistent) {
        $discoveryClassification = Get-IncompleteParseClassification
    }

    if ($effectiveCheckOnly) {
        $displayCommand = $checkCommand
        $classification = $discoveryClassification
        Write-TechnicalSections
        if ($classification.State -eq 'LastCheckFailed' -or $classification.State -eq 'ActionRequired') {
            Write-AvailableUpdates -Items $upgradeItems -Status Failed
        }
        else {
            Write-AvailableUpdates -Items $upgradeItems -Status Available
        }
        $finishedAt = [DateTimeOffset]::Now
        Write-RunFooter -Classification $classification -FinishedAt $finishedAt -HasWingetExitCode $true
        Write-LegacySummary "$runType completed; details: $logFileName"
        Complete-Run -Classification $classification -Items $upgradeItems -FinishedAt $finishedAt
        [void](Send-OrbitRunNotification -Classification $classification -DetectedItems $upgradeItems)
        if ($classification.History -eq 'failed' -or $classification.History -eq 'partial-success') { exit 1 }
        exit 0
    }

    if ($discoveryClassification.State -eq 'LastCheckFailed' -or $discoveryClassification.State -eq 'ActionRequired') {
        $displayCommand = $checkCommand
        $classification = $discoveryClassification
        Write-TechnicalSections
        Write-AvailableUpdates -Items $upgradeItems -Status Failed
        $finishedAt = [DateTimeOffset]::Now
        Write-RunFooter -Classification $classification -FinishedAt $finishedAt -HasWingetExitCode $true
        Write-LegacySummary "$runType failed during discovery; details: $logFileName"
        Complete-Run -Classification $classification -Items $upgradeItems -FinishedAt $finishedAt -SelectedCount 0 -InstalledCount 0 -FailedCount 0 -SkippedCount 0 -NotSelectedCount 0
        [void](Send-OrbitRunNotification -Classification $classification -DetectedItems $upgradeItems)
        exit 1
    }

    $queueStopwatch = [Diagnostics.Stopwatch]::StartNew()
    $selectedItems = @()
    $notSelectedItems = @()
    if ($selectionSpecified) {
        foreach ($item in $upgradeItems) {
            $itemId = [string]$item.Id
            $itemSource = [string]$item.Source
            $matchedRequest = @($selectedPackageRequests | Where-Object {
                [string]::Equals([string]$_.Id, $itemId, [StringComparison]::OrdinalIgnoreCase) -and
                ([string]::IsNullOrWhiteSpace([string]$_.Source) -or [string]::Equals([string]$_.Source, $itemSource, [StringComparison]::OrdinalIgnoreCase))
            }).Count -gt 0
            if ($matchedRequest) { $selectedItems += $item }
            else { $notSelectedItems += $item }
        }
    }
    else {
        $selectedItems = @($upgradeItems)
    }

    $packageResults = @()
    foreach ($item in $notSelectedItems) {
        $packageResults += New-PackageHistoryResult -Item $item -Result 'not-selected' -Message 'Not selected for this manual installation run.'
    }
    $queueStopwatch.Stop()
    Write-RunLog ('Queue construction: {0:N3} s; discovered: {1}; selected: {2}; not selected: {3}' -f
        ($queueStopwatch.ElapsedMilliseconds / 1000.0), $upgradeItems.Count, $selectedItems.Count, $notSelectedItems.Count)

    $commands = @($checkCommand)
    $outputSections = @("[Discovery]`r`n$standardOutput")
    $errorSections = @()
    if (-not [string]::IsNullOrWhiteSpace($standardError)) { $errorSections += "[Discovery]`r`n$standardError" }
    $installedCount = 0
    $failedCount = 0
    $skippedCount = 0
    $restartRequired = $false
    $firstFailureExitCode = $null

    $packagePosition = 0
    foreach ($item in $selectedItems) {
        $packagePosition++
        $packageId = [string]$item.Id
        $packageSource = [string]$item.Source
        $script:liveProgressCurrentItem = $item
        $script:liveProgressCurrentIndex = $packagePosition
        $script:liveProgressCurrentTotal = $selectedItems.Count
        $script:liveProgressObservedPercentage = $null
        Publish-OrbitLiveProgress -Phase installing -Item $item -Index $packagePosition -Total $selectedItems.Count -Percentage $null -Force
        if ([string]::IsNullOrWhiteSpace($packageId)) {
            $failedCount++
            $packageResults += New-PackageHistoryResult -Item $item -Result 'failed' -Message 'Winget did not provide a package ID, so Orbit could not target this update safely.' -ErrorCategory 'missing-package-id'
            continue
        }

        $packageArguments = @(Get-OrbitWingetArguments -Operation Update -Configuration $configuration -PackageId $packageId -PackageSource $packageSource)
        $packageCommand = Get-OrbitWingetCommandText -Operation Update -Configuration $configuration -PackageId $packageId -PackageSource $packageSource
        $commands += $packageCommand
        Write-RunLog ('[{0}] Installing {1} ({2})' -f ([DateTimeOffset]::Now.ToString('o')), [string]$item.Name, $packageId)

        try {
            $queueOffsetMilliseconds = if ($null -ne $pipelineStopwatch) { [long]$pipelineStopwatch.ElapsedMilliseconds } else { -1 }
            $progressCallback = {
                param($outputEvent)
                $progressValue = Get-OrbitProgressPercentage -Text ([string]$outputEvent.Text)
                if ($null -ne $progressValue) {
                    $script:liveProgressObservedPercentage = [int]$progressValue
                    Publish-OrbitLiveProgress -Phase installing -Item $script:liveProgressCurrentItem -Index $script:liveProgressCurrentIndex -Total $script:liveProgressCurrentTotal -Percentage ([int]$progressValue)
                }
            }
            $packageProcess = Invoke-HiddenProcess -FilePath $wingetSource -Arguments @($wingetPrefixArguments + $packageArguments) -OutputCallback $progressCallback
            if ($null -ne $script:liveProgressObservedPercentage) {
                Publish-OrbitLiveProgress -Phase installing -Item $item -Index $packagePosition -Total $selectedItems.Count -Percentage ([int]$script:liveProgressObservedPercentage) -Force
            }
            Write-PackageProcessSection -Item $item -Command $packageCommand -Result $packageProcess -QueueOffsetMilliseconds $queueOffsetMilliseconds
            $outputSections += "[$packageId]`r`n$([string]$packageProcess.StandardOutput)"
            if (-not [string]::IsNullOrWhiteSpace([string]$packageProcess.StandardError)) {
                $errorSections += "[$packageId]`r`n$([string]$packageProcess.StandardError)"
            }
            $packageClassification = Get-ResultClassification -Code ([int]$packageProcess.ExitCode) -IsCheck $false -UpdatesFound 1
            if ($packageClassification.History -eq 'success') {
                $installedCount++
                $restartRequired = $restartRequired -or [bool]$packageClassification.Restart
                $resultName = if ([bool]$packageClassification.Restart) { 'installed-restart-required' } else { 'installed' }
                $packageResults += New-PackageHistoryResult -Item $item -Result $resultName -Message ([string]$packageClassification.Message) -ExitCode ([int]$packageProcess.ExitCode) -ErrorCategory ([string]$packageClassification.Category)
            }
            elseif ($packageClassification.History -eq 'no-updates-found') {
                $skippedCount++
                $packageResults += New-PackageHistoryResult -Item $item -Result 'skipped' -Message 'The package was no longer available when installation began.' -ExitCode ([int]$packageProcess.ExitCode) -ErrorCategory 'package-no-longer-available'
            }
            else {
                $failedCount++
                if ($null -eq $firstFailureExitCode) { $firstFailureExitCode = [int]$packageProcess.ExitCode }
                $packageResults += New-PackageHistoryResult -Item $item -Result 'failed' -Message ([string]$packageClassification.Message) -ExitCode ([int]$packageProcess.ExitCode) -ErrorCategory ([string]$packageClassification.Category)
            }
        }
        catch {
            $failedCount++
            if ($null -eq $firstFailureExitCode) { $firstFailureExitCode = 1 }
            $errorSections += "[$packageId]`r`n$($_.Exception.Message)"
            $packageResults += New-PackageHistoryResult -Item $item -Result 'failed' -Message 'Orbit could not start or complete this package installation.' -ExitCode 1 -ErrorCategory 'package-process-error'
            Write-RunLog "Package process error: $($_.Exception.Message)"
        }
    }

    Publish-OrbitLiveProgress -Phase finalizing -Index 0 -Total $selectedItems.Count -Percentage $null -Force

    $postCheckItems = @($upgradeItems)
    $postCheckIncomplete = $false
    try {
        $commands += $checkCommand
        Write-RunLog ('[{0}] Refreshing available updates after the installation queue.' -f ([DateTimeOffset]::Now.ToString('o')))
        $postCheckResult = Invoke-HiddenProcess -FilePath $wingetSource -Arguments @($wingetPrefixArguments + $checkArguments)
        Write-RunLog ('Post-install check process: {0:N3} s; first output: {1}' -f
            ($postCheckResult.DurationMilliseconds / 1000.0),
            $(if ([long]$postCheckResult.FirstOutputMilliseconds -ge 0) { '{0:N3} s' -f ($postCheckResult.FirstOutputMilliseconds / 1000.0) } else { 'no output captured' }))
        $outputSections += "[Post-install check]`r`n$([string]$postCheckResult.StandardOutput)"
        if (-not [string]::IsNullOrWhiteSpace([string]$postCheckResult.StandardError)) {
            $errorSections += "[Post-install check]`r`n$([string]$postCheckResult.StandardError)"
        }
        $postParseStopwatch = [Diagnostics.Stopwatch]::StartNew()
        $postCheckParseResult = Get-WingetUpgradeParseResult -Output ([string]$postCheckResult.StandardOutput)
        $postCheckItems = @($postCheckParseResult.Items)
        $postParseStopwatch.Stop()
        Write-RunLog ('Post-install output parsing: {0:N3} s; rows parsed: {1}' -f ($postParseStopwatch.ElapsedMilliseconds / 1000.0), $postCheckItems.Count)
        foreach ($diagnosticLine in @($postCheckParseResult.DiagnosticLines)) { Write-RunLog $diagnosticLine }
        $postCheckClassification = Get-ResultClassification -Code ([int]$postCheckResult.ExitCode) -IsCheck $true -UpdatesFound $postCheckItems.Count
        if ([int]$postCheckResult.ExitCode -eq 0 -and -not [bool]$postCheckParseResult.IsConsistent) {
            $postCheckIncomplete = $true
            $postCheckClassification = Get-IncompleteParseClassification
        }
        if ($postCheckClassification.State -eq 'LastCheckFailed' -or $postCheckClassification.State -eq 'ActionRequired') {
            Write-AvailableUpdates -Items $postCheckItems -Status Failed
        }
        else {
            Write-AvailableUpdates -Items $postCheckItems -Status Available
        }
    }
    catch {
        $errorSections += "[Post-install check]`r`n$($_.Exception.Message)"
        Write-AvailableUpdates -Items $postCheckItems -Status Failed
    }

    $classification = Get-PackageQueueClassification -Selected $selectedItems.Count -Installed $installedCount -Failed $failedCount -Skipped $skippedCount -RestartRequired $restartRequired -PackageResults $packageResults
    if ($postCheckIncomplete -and [string]$classification.History -eq 'success') {
        $classification = [PSCustomObject]@{
            State = 'CompletedWithIssues'
            History = 'partial-success'
            Category = 'incomplete-parse'
            Message = 'Updates were processed, but Orbit could not verify whether more Winget updates remain.'
            Restart = [bool]$classification.Restart
        }
    }
    elseif($classification.State -eq 'Success' -and $postCheckItems.Count -gt 0){
        $remainingLabel=if($postCheckItems.Count -eq 1){'1 update remains available.'}else{"$($postCheckItems.Count) updates remain available."}
        $classification=[PSCustomObject]@{State='UpdatesAvailable';History='success';Category='updates-remaining';Message="All selected updates were processed. $remainingLabel";Restart=$false}
    }
    $exitCode = if ($failedCount -gt 0) { if ($null -ne $firstFailureExitCode) { [int]$firstFailureExitCode } else { 1 } } else { 0 }
    $displayCommand = $commands -join "`r`n"
    $standardOutput = $outputSections -join "`r`n`r`n"
    $standardError = $errorSections -join "`r`n`r`n"
    Write-TechnicalSections

    $finishedAt = [DateTimeOffset]::Now
    Write-RunFooter -Classification $classification -FinishedAt $finishedAt -HasWingetExitCode $true
    Write-LegacySummary "$runType completed; details: $logFileName"
    Complete-Run -Classification $classification -Items $upgradeItems -FinishedAt $finishedAt -PackageResults $packageResults -SelectedCount $selectedItems.Count -InstalledCount $installedCount -FailedCount $failedCount -SkippedCount $skippedCount -NotSelectedCount $notSelectedItems.Count -RemainingCount $postCheckItems.Count
    [void](Send-OrbitRunNotification -Classification $classification -DetectedItems $upgradeItems -Installed $installedCount -Failed $failedCount)

    if ($classification.History -eq 'failed' -or $classification.History -eq 'partial-success') { exit 1 }
    exit 0
}
catch {
    $failureMessage = $_.Exception.Message
    [void](Write-OrbitCrashReport -Operation ("Engine.{0}" -f $runType) -ErrorRecord $_ -Context ([ordered]@{
        runId             = $runId
        runType           = $runType
        checkOnly         = [bool]$CheckOnly
        scheduled         = [bool]$Scheduled
        signIn            = [bool]$SignIn
        command           = $displayCommand
        wingetWasExecuted = $wingetWasExecuted
        wingetExitCode    = $exitCode
        runLogPath        = $runLogPath
        statePath         = $statePath
        historyPath       = Get-OrbitHistoryPath
    }))
    if ($failureMessage -eq 'WINGET_UNAVAILABLE') {
        $failure = [PSCustomObject]@{ State = 'ActionRequired'; History = 'failed'; Category = 'winget-unavailable'; Message = 'Winget is unavailable. Install or repair App Installer, then try again.'; Restart = $false }
    }
    else {
        $failure = [PSCustomObject]@{ State = 'LastCheckFailed'; History = 'failed'; Category = 'internal-error'; Message = 'Orbit Updater could not complete the operation. Open technical details for more information.'; Restart = $false }
    }
    $standardError = $failureMessage
    $exitCode = 1
    $finishedAt = [DateTimeOffset]::Now
    if (-not $technicalSectionsWritten) { Write-TechnicalSections }
    else { Write-RunLog ''; Write-RunLog "Internal error: $failureMessage" }
    Write-RunFooter -Classification $failure -FinishedAt $finishedAt -HasWingetExitCode $wingetWasExecuted
    Write-LegacySummary "$runType failed; details: $logFileName"
    if (-not $historyWritten) {
        $failureCompletion = @{
            Classification = $failure
            Items = @($upgradeItems)
            FinishedAt = $finishedAt
        }
        if (@($packageResults).Count -gt 0 -or @($selectedItems).Count -gt 0) {
            $failureCompletion.PackageResults = @($packageResults)
            $failureCompletion.SelectedCount = @($selectedItems).Count
            $failureCompletion.InstalledCount = $installedCount
            $failureCompletion.FailedCount = $failedCount
            $failureCompletion.SkippedCount = $skippedCount
            $failureCompletion.NotSelectedCount = @($notSelectedItems).Count
        }
        Complete-Run @failureCompletion
    }
    [void](Send-OrbitRunNotification -Classification $failure -DetectedItems @($upgradeItems) -Failed ([Math]::Max(1, $failedCount)))
    exit 1
}
finally {
    if ($ownsLiveProgress) { Clear-OrbitLiveProgress }
    if ($hasMutex -and $null -ne $mutex) {
        try { $mutex.ReleaseMutex() } catch { }
    }
    if ($null -ne $mutex) { $mutex.Dispose() }
}
