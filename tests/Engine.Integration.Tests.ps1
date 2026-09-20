[CmdletBinding()]
param()

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$projectRoot = Split-Path -Parent $PSScriptRoot
$enginePath = Join-Path $projectRoot 'WingetUpdateEngine.ps1'
$taskManagerPath = Join-Path $projectRoot 'TaskManager.ps1'
$commonPath = Join-Path $projectRoot 'OrbitData.ps1'
$powershellExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('OrbitUpdaterEngineTests-' + [Guid]::NewGuid().ToString('N'))
$resolvedTemp = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\'
$resolvedTestRoot = [IO.Path]::GetFullPath($testRoot)
$originalPath = $env:PATH
$passed = 0

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw "Assertion failed: $Message" }
    $script:passed++
    Write-Output "PASS $Message"
}

function Invoke-TestEngine {
    param([string]$Arguments)
    $argumentText = '-NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}" {1}' -f $enginePath, $Arguments
    $process = Start-Process -FilePath $powershellExe -ArgumentList $argumentText -WorkingDirectory $resolvedTestRoot -WindowStyle Hidden -Wait -PassThru
    return $process.ExitCode
}

function Invoke-TestEngineWithProgressCapture {
    param([string]$Arguments)

    $argumentText = '-NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}" {1}' -f $enginePath, $Arguments
    $process = Start-Process -FilePath $powershellExe -ArgumentList $argumentText -WorkingDirectory $resolvedTestRoot -WindowStyle Hidden -PassThru
    $progressPath = Join-Path $resolvedTestRoot 'live-progress.json'
    $snapshots = @()
    $lastSignature = ''
    $deadline = [DateTime]::Now.AddSeconds(60)
    try {
        while (-not $process.HasExited -and [DateTime]::Now -lt $deadline) {
            if (Test-Path -LiteralPath $progressPath) {
                try {
                    $snapshot = Get-Content -LiteralPath $progressPath -Raw -Encoding UTF8 | ConvertFrom-Json
                    $signature = '{0}|{1}|{2}|{3}|{4}' -f $snapshot.phase,$snapshot.packageId,$snapshot.currentIndex,$snapshot.totalPackages,$snapshot.percentage
                    if ($signature -ne $lastSignature) {
                        $snapshots += $snapshot
                        $lastSignature = $signature
                    }
                }
                catch { }
            }
            Start-Sleep -Milliseconds 25
            $process.Refresh()
        }
        if (-not $process.HasExited) {
            Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue
            throw 'The progress integration run did not finish in time.'
        }
        return [PSCustomObject]@{ ExitCode=$process.ExitCode; Snapshots=@($snapshots) }
    }
    finally { $process.Dispose() }
}

function Invoke-TestTaskPreference {
    param([ValidateSet('Enable', 'Disable')][string]$Action, [int]$Hours)
    $argumentText = '-NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}" -Action {1} -IntervalHours {2} -NoElevation' -f $taskManagerPath, $Action, $Hours
    $process = Start-Process -FilePath $powershellExe -ArgumentList $argumentText -WindowStyle Hidden -PassThru
    if (-not $process.WaitForExit(60000)) {
        Stop-Process -Id $process.Id -Force
        throw "The $Action preference action did not finish without an elevation prompt."
    }
    return $process.ExitCode
}

try {
    if (-not $resolvedTestRoot.StartsWith($resolvedTemp, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'Refusing to use a test path outside the system temporary directory.'
    }
    $fakeBin = Join-Path $resolvedTestRoot 'bin'
    New-Item -ItemType Directory -Path $fakeBin -Force | Out-Null
    $fakeWingetPath = Join-Path $env:SystemRoot 'System32\cscript.exe'
    # Reuse Microsoft's signed console-script host as the test executable. A
    # newly compiled fake EXE is correctly blocked on Windows systems that
    # enforce application-control policy, which would make the test unreliable.
    $fakeUpgradeScript = @'
Dim argument
Dim scenario
Dim argumentsText
Dim packageId
Dim isVersion
Dim tracePath
Dim fso
scenario = LCase(CreateObject("WScript.Shell").ExpandEnvironmentStrings("%ORBIT_UPDATER_TEST_WINGET_SCENARIO%"))
tracePath = CreateObject("WScript.Shell").ExpandEnvironmentStrings("%ORBIT_UPDATER_TEST_WINGET_TRACE%")
argumentsText = ""
packageId = ""
isVersion = False
Set fso = CreateObject("Scripting.FileSystemObject")
For Each argument In WScript.Arguments
    argumentsText = argumentsText & " " & CStr(argument)
    If LCase(CStr(argument)) = "--version" Then
        isVersion = True
    End If
Next
For argument = 0 To WScript.Arguments.Count - 2
    If LCase(CStr(WScript.Arguments(argument))) = "--id" Then packageId = CStr(WScript.Arguments(argument + 1))
Next
If isVersion Then
    WScript.Echo "v9.9-test"
    WScript.Quit 0
End If
If Len(tracePath) > 0 Then
    Dim traceFile
    Set traceFile = fso.OpenTextFile(tracePath, 8, True)
    traceFile.WriteLine Trim(argumentsText)
    traceFile.Close
End If
If scenario = "empty" Then WScript.Quit 0
If scenario = "malformed" Then
    WScript.Echo "Unexpected output without a package table"
    WScript.Quit 0
End If
If scenario = "count-mismatch" Then
    WScript.Echo "Name                         ID                         Version    Available  Source"
    WScript.Echo "----------------------------------------------------------------------------------"
    WScript.Echo "3 mises a jour disponibles."
    WScript.Echo "Example Application          Example.Package            1.2.3      2.0.0      winget"
    WScript.Echo "Another App                  Vendor.Another              Unknown    5.1        msstore"
    WScript.Quit 0
End If
If scenario = "nonzero" Then
    WScript.Echo "Unexpected simulated Winget failure"
    WScript.Quit 17
End If
If scenario = "queue-partial" Or scenario = "queue-selection" Or scenario = "queue-fail-all" Or scenario = "queue-progress" Then
    If Len(packageId) > 0 Then
        If scenario = "queue-progress" Then
            If LCase(packageId) = "vendor.a" Then
                WScript.Echo "Preparing package A"
                WScript.Sleep 250
                WScript.Echo "12%"
                Dim progressValue
                For progressValue = 13 To 67
                    WScript.Echo CStr(progressValue) & "%"
                Next
                WScript.Sleep 300
                WScript.Echo "68 %"
                WScript.Sleep 300
                WScript.Echo "100%"
                WScript.Quit 0
            End If
            If LCase(packageId) = "vendor.b" Then
                WScript.Echo "Preparing package B"
                WScript.Sleep 250
                WScript.Echo "40%"
                WScript.Sleep 350
                WScript.StdErr.WriteLine "Simulated installer failure for Vendor.B"
                WScript.Quit 17
            End If
            If LCase(packageId) = "vendor.c" Then
                WScript.Echo "Installer does not report a percentage"
                WScript.Sleep 500
                WScript.Echo "Installed Vendor.C"
                WScript.Quit 0
            End If
        End If
        If scenario = "queue-fail-all" Or (scenario = "queue-partial" And LCase(packageId) = "vendor.b") Then
            WScript.StdErr.WriteLine "Simulated installer failure for Vendor.B"
            WScript.Quit 17
        End If
        WScript.Echo "Installed " & packageId
        WScript.Quit 0
    End If
    Dim traceText
    traceText = ""
    If Len(tracePath) > 0 And fso.FileExists(tracePath) Then traceText = LCase(fso.OpenTextFile(tracePath, 1).ReadAll())
    ' A completed queue must return Winget's no-update shape, not an ambiguous
    ' empty package table (which correctly triggers Orbit's parser safety guard).
    If scenario = "queue-selection" And InStr(traceText, "--id vendor.a") > 0 And InStr(traceText, "--id vendor.b") > 0 And InStr(traceText, "--id vendor.c") > 0 Then
        WScript.Echo "No applicable update found."
        WScript.Quit 0
    End If
    WScript.Echo "Name                         ID                         Version    Available  Source"
    WScript.Echo "----------------------------------------------------------------------------------"
    If InStr(traceText, "--id vendor.a") = 0 Then WScript.Echo "Package A                    Vendor.A                    1.0        2.0        winget"
    If scenario = "queue-selection" Then
        If InStr(traceText, "--id vendor.b") = 0 Then WScript.Echo "Package B                    Vendor.B                    1.0        2.0        msstore"
    Else
        WScript.Echo "Package B                    Vendor.B                    1.0        2.0        msstore"
    End If
    If InStr(traceText, "--id vendor.c") = 0 Then WScript.Echo "Package C                    Vendor.C                    1.0        2.0        winget"
    WScript.Quit 0
End If
If Len(packageId) > 0 Then
    WScript.Echo "Installed " & packageId
    WScript.Quit 0
End If
WScript.Echo "Name                         ID                         Version    Available  Source"
WScript.Echo "----------------------------------------------------------------------------------"
WScript.Echo "Example Application          Example.Package            1.2.3      2.0.0      winget"
WScript.Echo "Another App                  Vendor.Another              Unknown    5.1        winget"
WScript.Echo "2 upgrades available."
'@
    $fakeWingetScript = Join-Path $resolvedTestRoot 'fake-winget.vbs'
    [IO.File]::WriteAllText($fakeWingetScript, $fakeUpgradeScript, (New-Object Text.UTF8Encoding($false)))

    $env:ORBIT_UPDATER_TEST_ROOT = $resolvedTestRoot
    $env:ORBIT_UPDATER_TEST_WINGET_PATH = $fakeWingetPath
    $env:ORBIT_UPDATER_TEST_WINGET_SCRIPT = $fakeWingetScript
    $tracePath = Join-Path $resolvedTestRoot 'winget-trace.txt'
    $env:ORBIT_UPDATER_TEST_WINGET_TRACE = $tracePath
    . $commonPath

    $checkExit = Invoke-TestEngine -Arguments '-CheckOnly'
    if ($checkExit -ne 0) {
        Write-Output "Engine check failed with exit code $checkExit. Isolated diagnostics follow:"
        Get-ChildItem -LiteralPath (Get-OrbitLogRoot) -File -ErrorAction SilentlyContinue | ForEach-Object {
            Write-Output "--- $($_.Name) ---"
            Get-Content -LiteralPath $_.FullName -Raw -Encoding UTF8
        }
        foreach ($diagnosticName in @('state.json', 'last-run.json')) {
            $diagnosticPath = Join-Path $resolvedTestRoot $diagnosticName
            if (Test-Path -LiteralPath $diagnosticPath) {
                Write-Output "--- $diagnosticName ---"
                Get-Content -LiteralPath $diagnosticPath -Raw -Encoding UTF8
            }
        }
    }
    Assert-True ($checkExit -eq 0) 'check-only engine run completes against the fake Winget process'
    $history = @(Get-OrbitHistory)
    $checkEntry = $history | Where-Object { $_.runType -eq 'manual-check' } | Select-Object -First 1
    Assert-True ($null -ne $checkEntry -and [int]$checkEntry.updatesFound -eq 2) 'check-only run writes structured history with parsed update count'
    Assert-True ([int]$checkEntry.updatesInstalled -eq 0 -and @($checkEntry.packages).Count -eq 2) 'check-only history stores reliable package versions without claiming installation'
    $checkLogPath = Join-Path (Get-OrbitLogRoot) ([IO.Path]::GetFileName([string]$checkEntry.logFile))
    $checkLog = Get-Content -LiteralPath $checkLogPath -Raw -Encoding UTF8
    Assert-True ($checkLog -match 'Command: .*upgrade --include-unknown' -and $checkLog -notmatch 'Command: .*upgrade --all') 'check-only command scans without the install-all switch'
    Assert-True ($checkLog -match 'Standard output' -and $checkLog -match 'Standard error' -and $checkLog -match 'Winget exit code: 0') 'check-only raw log contains redirected streams and exit metadata'
    $activityText = Read-OrbitRecentLog -Path (Get-OrbitLatestRunLogPath -PreferredLogFile ([string]$checkEntry.logFile))
    Assert-True ($activityText -match 'Run type: manual-check' -and $activityText -match 'Example Application') 'Activity reads new manual-check output from the existing raw log'
    Assert-True ($checkEntry.status -eq 'success') 'successful check History is Success'

    $stateBeforeBlocked = Get-Content -LiteralPath (Join-Path $resolvedTestRoot 'state.json') -Raw
    $traceBeforeBlocked = Get-Content -LiteralPath $tracePath -Raw
    $executionLock = New-Object Threading.Mutex($false, 'Local\WingetAutoUpdater.Engine')
    $ownsTestLock = $executionLock.WaitOne(0)
    try {
        if (-not $ownsTestLock) { throw 'Cannot test lock contention while another real engine is running.' }
        $blockedExit = Invoke-TestEngine -Arguments '-CheckOnly'
    }
    finally {
        if ($ownsTestLock) { $executionLock.ReleaseMutex() }
        $executionLock.Dispose()
    }
    $blockedEntry = @(Get-OrbitHistory) | Where-Object errorCategory -eq 'duplicate-run' | Select-Object -First 1
    Assert-True ($blockedExit -eq 2 -and $blockedEntry.status -eq 'skipped' -and $blockedEntry.updatesInstalled -eq 0) 'blocked duplicate request records Skipped with zero installations'
    Assert-True ((Get-Content -LiteralPath (Join-Path $resolvedTestRoot 'state.json') -Raw) -eq $stateBeforeBlocked -and (Get-Content -LiteralPath $tracePath -Raw) -eq $traceBeforeBlocked) 'blocked request neither overwrites the active state nor invokes Winget'
    Assert-True (Test-Path -LiteralPath (Join-Path (Get-OrbitLogRoot) $blockedEntry.logFile)) 'skipped History entry retains its technical log'

    $env:ORBIT_UPDATER_TEST_WINGET_SCENARIO = 'empty'
    $emptyExit = Invoke-TestEngine -Arguments '-CheckOnly'
    $emptyState = Get-Content -LiteralPath (Join-Path $resolvedTestRoot 'state.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    Assert-True ($emptyExit -eq 0 -and $emptyState.status -eq 'NoUpdates') 'an empty Winget result does not crash the check path'
    Assert-True ((@(Get-OrbitHistory) | Select-Object -First 1).status -eq 'no-updates-found') 'true empty check retains successful no-update History'

    $env:ORBIT_UPDATER_TEST_WINGET_SCENARIO = 'malformed'
    $malformedExit = Invoke-TestEngine -Arguments '-CheckOnly'
    $malformedState = Get-Content -LiteralPath (Join-Path $resolvedTestRoot 'state.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    Assert-True ($malformedExit -eq 0 -and $malformedState.status -eq 'NoUpdates') 'unexpected localized or malformed output is handled without a process failure'

    $env:ORBIT_UPDATER_TEST_WINGET_SCENARIO = 'count-mismatch'
    $mismatchExit = Invoke-TestEngine -Arguments '-CheckOnly'
    $mismatchState = Get-Content -LiteralPath (Join-Path $resolvedTestRoot 'state.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    $mismatchUpdates = Get-Content -LiteralPath (Join-Path $resolvedTestRoot 'updates.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    $mismatchLog = Get-Content -LiteralPath (Join-Path (Get-OrbitLogRoot) ([string]$mismatchState.logFile)) -Raw -Encoding UTF8
    Assert-True ($mismatchExit -eq 1 -and $mismatchState.status -eq 'LastCheckFailed' -and $mismatchState.errorCategory -eq 'incomplete-parse') 'a reported/parsed count mismatch becomes a failed update check'
    Assert-True ($mismatchUpdates.status -eq 'Failed' -and [int]$mismatchUpdates.count -eq 2) 'a mismatch preserves only the authoritative parsed package collection without reporting success'
    Assert-True ($mismatchLog -match 'Winget reported updates:\s*3' -and $mismatchLog -match 'Orbit parsed packages:\s*2' -and $mismatchLog -match 'Parser consistency check:\s*FAILED') 'a mismatch records reported count, parsed count, and failed consistency diagnostics'

    $env:ORBIT_UPDATER_TEST_WINGET_SCENARIO = 'nonzero'
    $nonzeroExit = Invoke-TestEngine -Arguments '-CheckOnly'
    $nonzeroState = Get-Content -LiteralPath (Join-Path $resolvedTestRoot 'state.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    Assert-True ($nonzeroExit -eq 1 -and $nonzeroState.status -eq 'LastCheckFailed') 'a nonzero Winget result is classified and retained without crashing the engine'

    Remove-Item Env:ORBIT_UPDATER_TEST_WINGET_SCENARIO -ErrorAction SilentlyContinue
    $validTestWingetPath = $env:ORBIT_UPDATER_TEST_WINGET_PATH
    $env:ORBIT_UPDATER_TEST_WINGET_PATH = Join-Path $resolvedTestRoot 'missing-winget.exe'
    $missingExit = Invoke-TestEngine -Arguments '-CheckOnly'
    $missingState = Get-Content -LiteralPath (Join-Path $resolvedTestRoot 'state.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    Assert-True ($missingExit -eq 1 -and $missingState.errorCategory -eq 'winget-unavailable') 'missing or inaccessible Winget is reported without terminating the caller unexpectedly'
    $env:ORBIT_UPDATER_TEST_WINGET_PATH = $validTestWingetPath

    $updateExit = Invoke-TestEngine -Arguments ''
    Assert-True ($updateExit -eq 0) 'manual update engine run completes against the fake Winget process'
    $history = @(Get-OrbitHistory)
    $updateEntry = $history | Where-Object { $_.runType -eq 'manual-update' } | Select-Object -First 1
    Assert-True ($null -ne $updateEntry -and [int]$updateEntry.updatesInstalled -eq 2) 'successful manual update history records installed count'
    $updateLogPath = Join-Path (Get-OrbitLogRoot) ([IO.Path]::GetFileName([string]$updateEntry.logFile))
    $updateLog = Get-Content -LiteralPath $updateLogPath -Raw -Encoding UTF8
    Assert-True ($updateLog -match 'upgrade --id Example\.Package --exact' -and $updateLog -match 'upgrade --id Vendor\.Another --exact' -and $updateLog -notmatch 'upgrade --all') 'manual update targets every detected package by exact ID instead of using install-all'

    Remove-Item -LiteralPath $tracePath -Force -ErrorAction SilentlyContinue
    $env:ORBIT_UPDATER_TEST_WINGET_SCENARIO = 'queue-partial'
    $partialExit = Invoke-TestEngine -Arguments ''
    $partialState = Get-Content -LiteralPath (Join-Path $resolvedTestRoot 'state.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    $partialEntry = @(Get-OrbitHistory) | Where-Object { $_.runType -eq 'manual-update' -and $_.status -eq 'partial-success' } | Select-Object -First 1
    $partialTrace = Get-Content -LiteralPath $tracePath -Raw
    Assert-True ($partialExit -eq 1 -and $partialState.status -eq 'CompletedWithIssues' -and [int]$partialState.updatesInstalled -eq 2 -and [int]$partialState.updatesFailed -eq 1) 'three-package queue reports partial success when the middle package fails'
    Assert-True ($partialTrace.IndexOf('--id Vendor.A') -lt $partialTrace.IndexOf('--id Vendor.B') -and $partialTrace.IndexOf('--id Vendor.B') -lt $partialTrace.IndexOf('--id Vendor.C')) 'package C still executes after package B fails'
    Assert-True ($null -ne $partialEntry -and @($partialEntry.packages | Where-Object result -eq 'installed').Count -eq 2 -and @($partialEntry.packages | Where-Object result -eq 'failed').Count -eq 1 -and [int]$partialEntry.updatesSelected -eq 3) 'partial-success History retains reliable package-level results and aggregate counts'
    $failedPackageHistory = @($partialEntry.packages | Where-Object result -eq 'failed')[0]
    Assert-True ($failedPackageHistory.packageId -eq 'Vendor.B' -and $failedPackageHistory.oldVersion -eq '1.0' -and $failedPackageHistory.newVersion -eq '2.0' -and $failedPackageHistory.source -eq 'msstore' -and [int]$failedPackageHistory.exitCode -eq 17) 'failed package History retains identity, versions, source, and the technical exit code'
    Assert-True ($partialState.message -match 'Package B' -and $partialState.message -match 'could not complete') 'partial failure state names the affected package and presents its concise reason'
    $partialLogPath = Join-Path (Get-OrbitLogRoot) ([IO.Path]::GetFileName([string]$partialEntry.logFile))
    $partialLog = Get-Content -LiteralPath $partialLogPath -Raw -Encoding UTF8
    Assert-True ($partialLog -match 'Initial check process:' -and $partialLog -match 'Initial output parsing:' -and $partialLog -match 'Queue construction:' -and $partialLog -match 'Process start:' -and $partialLog -match 'Time to first output:' -and $partialLog -match 'Package process duration:' -and $partialLog -match 'Post-install check process:' -and $partialLog -match 'History persistence:') 'raw logs retain discovery, parsing, queue, process, post-check, and history timing phases'
    $remainingAfterPartial = Get-Content -LiteralPath (Join-Path $resolvedTestRoot 'updates.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    Assert-True (@($remainingAfterPartial.items).Count -eq 1 -and $remainingAfterPartial.items[0].Id -eq 'Vendor.B') 'post-install check keeps only the still-available failed package'

    Clear-OrbitHistory -DeleteAssociatedLogs $false
    Remove-Item -LiteralPath $tracePath -Force -ErrorAction SilentlyContinue
    $env:ORBIT_UPDATER_TEST_WINGET_SCENARIO = 'queue-progress'
    $progressRun = Invoke-TestEngineWithProgressCapture -Arguments ''
    $progressSnapshots = @($progressRun.Snapshots)
    $packageASnapshots = @($progressSnapshots | Where-Object { $_.phase -eq 'installing' -and $_.packageId -eq 'Vendor.A' })
    $packageBSnapshots = @($progressSnapshots | Where-Object { $_.phase -eq 'installing' -and $_.packageId -eq 'Vendor.B' })
    $packageCSnapshots = @($progressSnapshots | Where-Object { $_.phase -eq 'installing' -and $_.packageId -eq 'Vendor.C' })
    $packageAPercentages = @($packageASnapshots | Where-Object { $null -ne $_.percentage } | ForEach-Object { [int]$_.percentage })
    $packageBPercentages = @($packageBSnapshots | Where-Object { $null -ne $_.percentage } | ForEach-Object { [int]$_.percentage })
    $progressEntry = @(Get-OrbitHistory) | Select-Object -First 1
    Assert-True ($progressRun.ExitCode -eq 1 -and [int]$progressEntry.updatesInstalled -eq 2 -and [int]$progressEntry.updatesFailed -eq 1) 'live progress leaves the existing middle-failure isolation and History result unchanged'
    Assert-True (@($packageASnapshots | Where-Object { [int]$_.currentIndex -eq 1 -and [int]$_.totalPackages -eq 3 }).Count -gt 0 -and $packageAPercentages -contains 68 -and $packageAPercentages -contains 100) ("package A publishes its authoritative name, 1-of-3 queue position, and real percentages (captured: {0})" -f (($progressSnapshots | ForEach-Object { '{0}/{1}/{2}/{3}/{4}' -f $_.phase,$_.packageId,$_.currentIndex,$_.totalPackages,$_.percentage }) -join ', '))
    Assert-True (@($packageBSnapshots | Where-Object { [int]$_.currentIndex -eq 2 -and $null -eq $_.percentage -and [bool]$_.isIndeterminate }).Count -gt 0 -and $packageBPercentages -contains 40) 'package B resets to indeterminate at 2 of 3 before publishing its own percentage'
    Assert-True (@($packageCSnapshots | Where-Object { [int]$_.currentIndex -eq 3 -and [int]$_.totalPackages -eq 3 -and $null -eq $_.percentage -and [bool]$_.isIndeterminate }).Count -gt 0 -and @($packageCSnapshots | Where-Object { $null -ne $_.percentage }).Count -eq 0) 'package C uses an indeterminate fallback at 3 of 3 without inheriting package B progress'
    Assert-True (@($progressSnapshots | Where-Object phase -eq 'finalizing').Count -gt 0 -and -not (Test-Path -LiteralPath (Join-Path $resolvedTestRoot 'live-progress.json'))) 'current-package progress clears for finalization and the snapshot is removed when the engine exits'
    Assert-True ($packageAPercentages.Count -lt 20) 'rapid percentage output is throttled before persistence instead of writing every progress fragment'
    $progressLogPath = Join-Path (Get-OrbitLogRoot) ([IO.Path]::GetFileName([string]$progressEntry.logFile))
    $progressLog = Get-Content -LiteralPath $progressLogPath -Raw -Encoding UTF8
    Assert-True ($progressLog -match '12%' -and $progressLog -match '68 %' -and $progressLog -match 'Simulated installer failure' -and $progressLog -match 'Installer does not report a percentage') 'raw Activity/log output remains complete alongside graphical progress'

    Remove-Item -LiteralPath $tracePath -Force -ErrorAction SilentlyContinue
    $env:ORBIT_UPDATER_TEST_WINGET_SCENARIO = 'queue-selection'
    Write-OrbitJsonFile -Path (Join-Path $resolvedTestRoot 'manual-update-request.json') -Value ([ordered]@{ requestedAt=[DateTimeOffset]::Now.ToString('o'); mode='manual'; selectedPackageIds=@('Vendor.A','Vendor.C'); selectedPackages=@([ordered]@{id='Vendor.A';source='winget'},[ordered]@{id='Vendor.C';source='winget'}) })
    $selectionExit = Invoke-TestEngine -Arguments ''
    $selectionTrace = Get-Content -LiteralPath $tracePath -Raw
    $selectionEntry = @(Get-OrbitHistory) | Where-Object { $_.runType -eq 'manual-update' -and [int]$_.updatesNotSelected -eq 1 } | Select-Object -First 1
    Assert-True ($selectionExit -eq 0 -and $selectionTrace -match '--id Vendor\.A' -and $selectionTrace -match '--id Vendor\.C' -and $selectionTrace -notmatch '--id Vendor\.B') 'manual package selection attempts only checked package IDs'
    Assert-True ($selectionTrace -match '--id Vendor\.A --exact --source winget' -and $selectionTrace -match '--id Vendor\.C --exact --source winget') 'structured selections preserve the detected source in each exact package command'
    Assert-True ($null -ne $selectionEntry -and [int]$selectionEntry.updatesSelected -eq 2 -and [int]$selectionEntry.updatesNotSelected -eq 1 -and @($selectionEntry.packages | Where-Object result -eq 'not-selected').Count -eq 1) 'unchecked package is recorded as not selected rather than failed'

    Clear-OrbitHistory -DeleteAssociatedLogs $false
    Remove-Item -LiteralPath $tracePath -Force -ErrorAction SilentlyContinue
    Write-OrbitJsonFile -Path (Join-Path $resolvedTestRoot 'manual-update-request.json') -Value ([ordered]@{requestedAt=[DateTimeOffset]::Now.ToString('o');mode='manual';selectedPackages=@()})
    $zeroSelectionExit = Invoke-TestEngine -Arguments ''
    $zeroSelectionTrace = Get-Content -LiteralPath $tracePath -Raw
    $zeroSelectionEntry = @(Get-OrbitHistory) | Select-Object -First 1
    Assert-True ($zeroSelectionExit -eq 0 -and $zeroSelectionTrace -notmatch '--id ' -and [int]$zeroSelectionEntry.updatesSelected -eq 0 -and [int]$zeroSelectionEntry.updatesNotSelected -eq 3) 'zero selected packages performs no package process and records all discovered items as not selected'
    Assert-True ($zeroSelectionEntry.status -eq 'not-started' -and $zeroSelectionEntry.message -eq 'No updates were selected for installation.') 'zero-selection edge case records Not started, never Cancelled'

    $singleSelectionCases = @(
        [PSCustomObject]@{Id='Vendor.A';Source='winget'},
        [PSCustomObject]@{Id='Vendor.B';Source='msstore'},
        [PSCustomObject]@{Id='Vendor.C';Source='winget'}
    )
    foreach ($singleCase in $singleSelectionCases) {
        Clear-OrbitHistory -DeleteAssociatedLogs $false
        Remove-Item -LiteralPath $tracePath -Force -ErrorAction SilentlyContinue
        Write-OrbitJsonFile -Path (Join-Path $resolvedTestRoot 'manual-update-request.json') -Value ([ordered]@{requestedAt=[DateTimeOffset]::Now.ToString('o');mode='manual';selectedPackages=@([ordered]@{id=$singleCase.Id;source=$singleCase.Source})})
        $singleExit = Invoke-TestEngine -Arguments ''
        $singleTrace = Get-Content -LiteralPath $tracePath -Raw
        $singleEntry = @(Get-OrbitHistory) | Select-Object -First 1
        Assert-True ($singleEntry.status -eq 'success') 'one successful selected installation records Success'
        $otherIds = @('Vendor.A','Vendor.B','Vendor.C') | Where-Object { $_ -ne $singleCase.Id }
        $onlyRequestedExecuted = $singleTrace -match ('--id {0} --exact --source {1}' -f [regex]::Escape($singleCase.Id), [regex]::Escape($singleCase.Source))
        foreach ($otherId in $otherIds) { $onlyRequestedExecuted = $onlyRequestedExecuted -and $singleTrace -notmatch ('--id {0}' -f [regex]::Escape($otherId)) }
        Assert-True ($singleExit -eq 0 -and $onlyRequestedExecuted -and [int]$singleEntry.updatesSelected -eq 1 -and [int]$singleEntry.updatesInstalled -eq 1 -and [int]$singleEntry.updatesNotSelected -eq 2 -and @($singleEntry.packages).Count -eq 3) ("exactly one selected package executes and records accurate cardinality: {0}" -f $singleCase.Id)
    }

    Clear-OrbitHistory -DeleteAssociatedLogs $false
    Remove-Item -LiteralPath $tracePath -Force -ErrorAction SilentlyContinue
    $env:ORBIT_UPDATER_TEST_WINGET_SCENARIO = 'queue-partial'
    Write-OrbitJsonFile -Path (Join-Path $resolvedTestRoot 'manual-update-request.json') -Value ([ordered]@{requestedAt=[DateTimeOffset]::Now.ToString('o');mode='manual';selectedPackages=@([ordered]@{id='Vendor.B';source='msstore'})})
    $singleFailureExit = Invoke-TestEngine -Arguments ''
    $singleFailureState = Get-Content -LiteralPath (Join-Path $resolvedTestRoot 'state.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    $singleFailureEntry = @(Get-OrbitHistory) | Select-Object -First 1
    Assert-True ($singleFailureExit -eq 1 -and $singleFailureState.message -match '^Package B could not be updated\.' -and [int]$singleFailureEntry.updatesSelected -eq 1 -and [int]$singleFailureEntry.updatesFailed -eq 1 -and @($singleFailureEntry.packages | Where-Object result -eq 'failed').Count -eq 1) 'single-package failure remains isolated, understandable, and accurately represented in History'

    Clear-OrbitHistory -DeleteAssociatedLogs $false
    Remove-Item -LiteralPath $tracePath -Force -ErrorAction SilentlyContinue
    $env:ORBIT_UPDATER_TEST_WINGET_SCENARIO = 'queue-selection'
    $allSelectionExit = Invoke-TestEngine -Arguments ''
    $allSelectionTrace = Get-Content -LiteralPath $tracePath -Raw
    $allSelectionEntry = @(Get-OrbitHistory) | Select-Object -First 1
    Assert-True ($allSelectionExit -eq 0 -and [int]$allSelectionEntry.updatesSelected -eq 3 -and [int]$allSelectionEntry.updatesInstalled -eq 3 -and [int]$allSelectionEntry.updatesNotSelected -eq 0 -and $allSelectionTrace -match '--id Vendor\.A' -and $allSelectionTrace -match '--id Vendor\.B --exact --source msstore' -and $allSelectionTrace -match '--id Vendor\.C') 'all discovered packages execute independently with their sources and produce accurate aggregate History counts'

    Clear-OrbitHistory -DeleteAssociatedLogs $false
    Remove-Item -LiteralPath $tracePath -Force -ErrorAction SilentlyContinue
    [void](Save-OrbitConfiguration -Changes @{automaticInstallationEnabled=$false;installOnStartupEnabled=$false})
    Write-OrbitJsonFile -Path (Join-Path $resolvedTestRoot 'manual-update-request.json') -Value ([ordered]@{requestedAt=[DateTimeOffset]::Now.ToString('o');mode='startup'})
    $disabledStartupExit = Invoke-TestEngine -Arguments ''
    Assert-True ($disabledStartupExit -eq 0 -and @(Get-OrbitHistory).Count -eq 0 -and -not (Test-Path -LiteralPath $tracePath)) 'startup installation does no Winget work when the opt-in preference is off'

    [void](Save-OrbitConfiguration -Changes @{automaticInstallationEnabled=$true;installOnStartupEnabled=$true})
    Write-OrbitJsonFile -Path (Join-Path $resolvedTestRoot 'manual-update-request.json') -Value ([ordered]@{requestedAt=[DateTimeOffset]::Now.ToString('o');mode='startup'})
    Remove-Item Env:ORBIT_UPDATER_TEST_WINGET_SCENARIO -ErrorAction SilentlyContinue
    $enabledStartupExit = Invoke-TestEngine -Arguments ''
    $startupEntry = @(Get-OrbitHistory) | Where-Object runType -eq 'startup-update' | Select-Object -First 1
    Assert-True ($enabledStartupExit -eq 0 -and $null -ne $startupEntry -and [int]$startupEntry.updatesInstalled -eq 2) 'opted-in startup installation reuses the same per-package engine'

    Remove-Item Env:ORBIT_UPDATER_TEST_WINGET_SCENARIO -ErrorAction SilentlyContinue
    Clear-OrbitHistory -DeleteAssociatedLogs $false
    [void](Save-OrbitConfiguration -Changes @{ automaticUpdatesEnabled=$true; automaticInstallationEnabled=$false })
    $firstScheduledExit = Invoke-TestEngine -Arguments '-Scheduled'
    Assert-True ($firstScheduledExit -eq 0) 'the first hourly background wake-up performs a scheduled check when automatic installation is off'
    $history = @(Get-OrbitHistory)
    $scheduledEntry = $history | Where-Object { $_.runType -eq 'scheduled-check' } | Select-Object -First 1
    Assert-True ($null -ne $scheduledEntry -and [int]$scheduledEntry.updatesFound -eq 2) 'a due scheduled check is retained without automatic installation'
    $notificationPath = Join-Path $resolvedTestRoot 'notification-test.json'
    $notifications = Get-Content -LiteralPath $notificationPath -Raw -Encoding UTF8 | ConvertFrom-Json
    Assert-True (@($notifications.entries).Count -eq 1 -and $notifications.entries[0].title -eq '2 updates available' -and $notifications.entries[0].launch -eq 'orbitupdater://overview') 'scheduled checks send one actionable local updates-available notification'
    $signInExit = Invoke-TestEngine -Arguments '-SignIn'
    $signInEntry = @(Get-OrbitHistory) | Where-Object { $_.runType -eq 'sign-in-check' } | Select-Object -First 1
    Assert-True ($signInExit -eq 0 -and $null -ne $signInEntry -and [int]$signInEntry.updatesFound -eq 2) 'sign-in checks reuse the same parser and retain the authoritative package collection'
    $historyCountBeforeSkippedWake = @(Get-OrbitHistory).Count
    $runLogCountBeforeSkippedWake = @(Get-ChildItem -LiteralPath (Get-OrbitLogRoot) -File -Filter '*_scheduled-check.log').Count

    $notDueExit = Invoke-TestEngine -Arguments '-Scheduled'
    Assert-True ($notDueExit -eq 0) 'an hourly wake-up before the selected interval exits cleanly'
    Assert-True (@(Get-OrbitHistory).Count -eq $historyCountBeforeSkippedWake -and @(Get-ChildItem -LiteralPath (Get-OrbitLogRoot) -File -Filter '*_scheduled-check.log').Count -eq $runLogCountBeforeSkippedWake) 'a not-due wake-up creates no duplicate history or raw log'

    Clear-OrbitHistory -DeleteAssociatedLogs $false
    $dedupeExit = Invoke-TestEngine -Arguments '-Scheduled'
    $notifications = Get-Content -LiteralPath $notificationPath -Raw -Encoding UTF8 | ConvertFrom-Json
    Assert-True ($dedupeExit -eq 0 -and @($notifications.entries).Count -eq 1) 'an unchanged automatic result is deduplicated instead of notifying every interval'

    Clear-OrbitHistory -DeleteAssociatedLogs $false
    Remove-Item -LiteralPath $tracePath -Force -ErrorAction SilentlyContinue
    [void](Save-OrbitConfiguration -Changes @{automaticUpdatesEnabled=$true;automaticInstallationEnabled=$true})
    $env:ORBIT_UPDATER_TEST_WINGET_SCENARIO='queue-selection'
    $automaticSuccessExit = Invoke-TestEngine -Arguments '-Scheduled'
    $automaticSuccess = @(Get-OrbitHistory) | Select-Object -First 1
    $notifications = Get-Content -LiteralPath $notificationPath -Raw -Encoding UTF8 | ConvertFrom-Json
    Assert-True ($automaticSuccessExit -eq 0 -and $automaticSuccess.runType -eq 'scheduled-update' -and [int]$automaticSuccess.updatesInstalled -eq 3) 'automatic installation reuses the successful per-package queue'
    Assert-True (@($notifications.entries | Where-Object title -eq 'Updates installed').Count -eq 1) 'successful automatic installation sends a concise notification'

    Clear-OrbitHistory -DeleteAssociatedLogs $false
    Remove-Item -LiteralPath $tracePath -Force -ErrorAction SilentlyContinue
    $env:ORBIT_UPDATER_TEST_WINGET_SCENARIO='queue-partial'
    $automaticPartialExit = Invoke-TestEngine -Arguments '-Scheduled'
    $notifications = Get-Content -LiteralPath $notificationPath -Raw -Encoding UTF8 | ConvertFrom-Json
    Assert-True ($automaticPartialExit -eq 1 -and @($notifications.entries | Where-Object title -eq 'Updates need attention').Count -eq 1) 'partial automatic installation sends an attention notification after continuing the queue'

    Clear-OrbitHistory -DeleteAssociatedLogs $false
    Remove-Item -LiteralPath $tracePath -Force -ErrorAction SilentlyContinue
    $env:ORBIT_UPDATER_TEST_WINGET_SCENARIO='queue-fail-all'
    $automaticFailureExit = Invoke-TestEngine -Arguments '-Scheduled'
    $notifications = Get-Content -LiteralPath $notificationPath -Raw -Encoding UTF8 | ConvertFrom-Json
    Assert-True ($automaticFailureExit -eq 1 -and @($notifications.entries | Where-Object title -eq 'Update failed').Count -eq 1) 'total automatic installation failure sends a concise failure notification'

    Clear-OrbitHistory -DeleteAssociatedLogs $false
    Remove-Item Env:ORBIT_UPDATER_TEST_WINGET_SCENARIO -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath (Join-Path $resolvedTestRoot 'notification-state.json') -Force -ErrorAction SilentlyContinue
    [void](Save-OrbitConfiguration -Changes @{automaticInstallationEnabled=$false})
    $env:ORBIT_UPDATER_TEST_NOTIFICATION_FAILURE='1'
    $notificationFailureExit = Invoke-TestEngine -Arguments '-Scheduled'
    Remove-Item Env:ORBIT_UPDATER_TEST_NOTIFICATION_FAILURE -ErrorAction SilentlyContinue
    Assert-True ($notificationFailureExit -eq 0 -and @(Get-OrbitHistory | Where-Object runType -eq 'scheduled-check').Count -eq 1) 'notification delivery failure cannot fail or suppress the completed update check'

    [void](Save-OrbitConfiguration -Changes @{ automaticUpdatesEnabled = $false })
    $historyCountBeforeDisabled = @(Get-OrbitHistory).Count
    $scheduledLogCountBeforeDisabled = @(Get-ChildItem -LiteralPath (Get-OrbitLogRoot) -File | Where-Object Name -match '_scheduled-(check|update)\.log$').Count
    $scheduledExit = Invoke-TestEngine -Arguments '-Scheduled'
    Assert-True ($scheduledExit -eq 0) 'disabled scheduled run exits cleanly without launching Winget'
    Assert-True (@(Get-OrbitHistory).Count -eq $historyCountBeforeDisabled -and @(Get-ChildItem -LiteralPath (Get-OrbitLogRoot) -File | Where-Object Name -match '_scheduled-(check|update)\.log$').Count -eq $scheduledLogCountBeforeDisabled) 'disabled automatic wake-ups exit before creating history or log noise'

    $disablePreferenceExit = Invoke-TestTaskPreference -Action Disable -Hours 12
    $disabledPreference = Get-OrbitConfiguration
    Assert-True ($disablePreferenceExit -eq 0 -and -not [bool]$disabledPreference.automaticUpdatesEnabled -and [int]$disabledPreference.intervalHours -eq 12) 'automatic disable saves locally without elevation or task mutation'
    $enablePreferenceExit = Invoke-TestTaskPreference -Action Enable -Hours 3
    $enabledPreference = Get-OrbitConfiguration
    Assert-True ($enablePreferenceExit -eq 0 -and [bool]$enabledPreference.automaticUpdatesEnabled -and [int]$enabledPreference.intervalHours -eq 3) 'automatic enable saves locally without elevation or task mutation'

    $diagnostics = Get-Content -LiteralPath (Join-Path $resolvedTestRoot 'last-run.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    Assert-True ($diagnostics.appVersion -eq '0.9.1-beta.1' -and $diagnostics.runType -eq 'scheduled-check') 'last-run diagnostics record app version and run type'

    Clear-OrbitHistory -DeleteAssociatedLogs $false
    [void](Save-OrbitConfiguration -Changes @{automaticUpdatesEnabled=$true;automaticInstallationEnabled=$false;unattendedModeEnabled=$false})
    $traceBeforePrerequisite = Get-Content -LiteralPath $tracePath -Raw
    $prerequisiteExit = Invoke-TestEngine -Arguments '-SignIn'
    $prerequisiteEntry = @(Get-OrbitHistory) | Select-Object -First 1
    Assert-True ($prerequisiteExit -eq 3 -and $prerequisiteEntry.status -eq 'skipped' -and $prerequisiteEntry.errorCategory -eq 'unattended-mode-disabled') 'unmet unattended prerequisite records Skipped rather than Cancelled'
    Assert-True ((Get-Content -LiteralPath $tracePath -Raw) -eq $traceBeforePrerequisite) 'skipped prerequisite run executes no Winget command'

    Write-Output "`n$passed integration assertions passed."
}
finally {
    $env:PATH = $originalPath
    Remove-Item Env:ORBIT_UPDATER_TEST_ROOT -ErrorAction SilentlyContinue
    Remove-Item Env:ORBIT_UPDATER_TEST_WINGET_PATH -ErrorAction SilentlyContinue
    Remove-Item Env:ORBIT_UPDATER_TEST_WINGET_SCRIPT -ErrorAction SilentlyContinue
    Remove-Item Env:ORBIT_UPDATER_TEST_WINGET_SCENARIO -ErrorAction SilentlyContinue
    Remove-Item Env:ORBIT_UPDATER_TEST_WINGET_TRACE -ErrorAction SilentlyContinue
    Remove-Item Env:ORBIT_UPDATER_TEST_NOTIFICATION_FAILURE -ErrorAction SilentlyContinue
    if ($resolvedTestRoot.StartsWith($resolvedTemp, [StringComparison]::OrdinalIgnoreCase) -and (Test-Path -LiteralPath $resolvedTestRoot)) {
        Remove-Item -LiteralPath $resolvedTestRoot -Recurse -Force
    }
}
