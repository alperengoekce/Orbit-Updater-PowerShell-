Set-StrictMode -Version 2.0

$script:OrbitProductName = 'Orbit Updater'
$script:OrbitAppVersion = '0.9.1-beta.1'
$script:OrbitAppUserModelId = 'Orbit.Updater'
$script:OrbitInternalTaskName = 'Winget Auto Updater'
$script:OrbitInternalDataFolder = 'WingetAutoUpdater'
if ($null -eq (Get-Variable -Name OrbitCrashSignatures -Scope Script -ErrorAction SilentlyContinue)) {
    $script:OrbitCrashSignatures = @{}
}

function Initialize-OrbitShellIdentity {
    if ($null -ne ('OrbitShellIdentity' -as [type])) { return }

    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

public static class OrbitShellIdentity
{
    private const uint GpsReadWrite = 0x00000002;

    [StructLayout(LayoutKind.Sequential, Pack = 4)]
    private struct PropertyKey
    {
        public Guid FormatId;
        public uint PropertyId;

        public PropertyKey(Guid formatId, uint propertyId)
        {
            FormatId = formatId;
            PropertyId = propertyId;
        }
    }

    [StructLayout(LayoutKind.Explicit)]
    private struct PropVariant
    {
        [FieldOffset(0)]
        public ushort VariantType;

        [FieldOffset(8)]
        public IntPtr PointerValue;

        public static PropVariant FromString(string value)
        {
            PropVariant result = new PropVariant();
            result.VariantType = (ushort)VarEnum.VT_LPWSTR;
            result.PointerValue = Marshal.StringToCoTaskMemUni(value);
            return result;
        }
    }

    [ComImport]
    [Guid("886D8EEB-8CF2-4446-8D02-CDBA1DBDCF99")]
    [InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface IPropertyStore
    {
        [PreserveSig]
        int GetCount(out uint propertyCount);

        [PreserveSig]
        int GetAt(uint propertyIndex, out PropertyKey key);

        [PreserveSig]
        int GetValue(ref PropertyKey key, out PropVariant value);

        [PreserveSig]
        int SetValue(ref PropertyKey key, ref PropVariant value);

        [PreserveSig]
        int Commit();
    }

    [DllImport("shell32.dll", CharSet = CharSet.Unicode, PreserveSig = true)]
    private static extern int SetCurrentProcessExplicitAppUserModelID(string appId);

    [DllImport("shell32.dll", CharSet = CharSet.Unicode, PreserveSig = true)]
    private static extern int SHGetPropertyStoreFromParsingName(
        string path,
        IntPtr bindContext,
        uint flags,
        ref Guid interfaceId,
        [MarshalAs(UnmanagedType.Interface)] out IPropertyStore propertyStore);

    [DllImport("ole32.dll", PreserveSig = true)]
    private static extern int PropVariantClear(ref PropVariant value);

    public static void SetCurrentProcessAppUserModelId(string appId)
    {
        int result = SetCurrentProcessExplicitAppUserModelID(appId);
        if (result < 0) { Marshal.ThrowExceptionForHR(result); }
    }

    public static void SetShortcutAppUserModelId(string shortcutPath, string appId)
    {
        Guid interfaceId = typeof(IPropertyStore).GUID;
        IPropertyStore propertyStore;
        int result = SHGetPropertyStoreFromParsingName(shortcutPath, IntPtr.Zero, GpsReadWrite, ref interfaceId, out propertyStore);
        if (result < 0) { Marshal.ThrowExceptionForHR(result); }

        PropertyKey appUserModelIdKey = new PropertyKey(
            new Guid("9F4C2855-9F79-4B39-A8D0-E1D42DE1D5F3"),
            5);
        PropVariant value = PropVariant.FromString(appId);
        try
        {
            result = propertyStore.SetValue(ref appUserModelIdKey, ref value);
            if (result < 0) { Marshal.ThrowExceptionForHR(result); }
            result = propertyStore.Commit();
            if (result < 0) { Marshal.ThrowExceptionForHR(result); }
        }
        finally
        {
            PropVariantClear(ref value);
            if (propertyStore != null) { Marshal.ReleaseComObject(propertyStore); }
        }
    }
}
'@
}

function Set-OrbitCurrentProcessAppIdentity {
    Initialize-OrbitShellIdentity
    [OrbitShellIdentity]::SetCurrentProcessAppUserModelId($script:OrbitAppUserModelId)
}

function Set-OrbitShortcutAppIdentity {
    param([Parameter(Mandatory = $true)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) { throw "Shortcut does not exist: $Path" }
    Initialize-OrbitShellIdentity
    [OrbitShellIdentity]::SetShortcutAppUserModelId([IO.Path]::GetFullPath($Path), $script:OrbitAppUserModelId)
}

function Get-OrbitDataRoot {
    if (-not [string]::IsNullOrWhiteSpace($env:ORBIT_UPDATER_TEST_ROOT)) {
        return [IO.Path]::GetFullPath($env:ORBIT_UPDATER_TEST_ROOT)
    }
    return Join-Path $env:LOCALAPPDATA $script:OrbitInternalDataFolder
}

function Get-OrbitLogRoot {
    return Join-Path (Get-OrbitDataRoot) 'Logs'
}

function Get-OrbitCrashLogRoot {
    if (-not [string]::IsNullOrWhiteSpace($env:ORBIT_UPDATER_TEST_ROOT)) {
        return Join-Path (Get-OrbitLogRoot) 'Crashes'
    }
    return Join-Path (Join-Path $env:LOCALAPPDATA 'OrbitUpdater') 'Logs\Crashes'
}

function Write-OrbitCrashReport {
    param(
        [Parameter(Mandatory = $true)][string]$Operation,
        [System.Management.Automation.ErrorRecord]$ErrorRecord = $null,
        [Exception]$Exception = $null,
        $Context = $null
    )

    try {
        if ($null -eq $Exception -and $null -ne $ErrorRecord) { $Exception = $ErrorRecord.Exception }
        if ($null -eq $Exception) { $Exception = New-Object Exception('An unspecified Orbit Updater error occurred.') }

        $reportTime = [DateTimeOffset]::Now
        $signature = '{0}|{1}|{2}' -f $Operation, $Exception.GetType().FullName, $Exception.Message
        if ($script:OrbitCrashSignatures.ContainsKey($signature) -and
            $reportTime.Subtract([DateTimeOffset]$script:OrbitCrashSignatures[$signature]).TotalSeconds -lt 30) {
            return $null
        }
        $script:OrbitCrashSignatures[$signature] = $reportTime

        $innerExceptions = @()
        $inner = $Exception.InnerException
        while ($null -ne $inner) {
            $innerExceptions += [ordered]@{
                type       = $inner.GetType().FullName
                message    = $inner.Message
                stackTrace = $inner.StackTrace
            }
            $inner = $inner.InnerException
        }

        $process = [Diagnostics.Process]::GetCurrentProcess()
        $thread = [Threading.Thread]::CurrentThread
        $processStartTime = $null
        try { $processStartTime = $process.StartTime.ToString('o') } catch { }
        $report = [ordered]@{
            timestamp       = $reportTime.ToString('o')
            appVersion      = $script:OrbitAppVersion
            operation       = $Operation
            exceptionType   = $Exception.GetType().FullName
            exceptionMessage = $Exception.Message
            stackTrace      = $Exception.StackTrace
            scriptStackTrace = if ($null -ne $ErrorRecord) { $ErrorRecord.ScriptStackTrace } else { $null }
            invocation      = if ($null -ne $ErrorRecord -and $null -ne $ErrorRecord.InvocationInfo) { $ErrorRecord.InvocationInfo.PositionMessage } else { $null }
            innerExceptions = $innerExceptions
            powerShellVersion = $PSVersionTable.PSVersion.ToString()
            windowsVersion  = [Environment]::OSVersion.VersionString
            process         = [ordered]@{
                id        = $process.Id
                name      = $process.ProcessName
                startTime = $processStartTime
            }
            thread          = [ordered]@{
                managedId  = $thread.ManagedThreadId
                name       = $thread.Name
                apartment  = $thread.ApartmentState.ToString()
                isThreadPool = $thread.IsThreadPoolThread
            }
            context         = $Context
        }

        $crashRoot = Get-OrbitCrashLogRoot
        if (-not (Test-Path -LiteralPath $crashRoot)) {
            New-Item -ItemType Directory -Path $crashRoot -Force | Out-Null
        }
        $safeOperation = ($Operation -replace '[^A-Za-z0-9_.-]', '_')
        $fileName = '{0}_{1}_{2}.json' -f ($reportTime.ToString('yyyy-MM-dd_HH-mm-ss-fff')), $safeOperation, ([Guid]::NewGuid().ToString('N').Substring(0, 8))
        $path = Join-Path $crashRoot $fileName
        $json = $report | ConvertTo-Json -Depth 12
        [IO.File]::WriteAllText($path, $json, (New-Object Text.UTF8Encoding($false)))
        return $path
    }
    catch {
        return $null
    }
}

function Get-OrbitLatestRunLogPath {
    param([string]$PreferredLogFile = '')

    $logRoot = Get-OrbitLogRoot
    if (-not (Test-Path -LiteralPath $logRoot)) { return $null }

    if (-not [string]::IsNullOrWhiteSpace($PreferredLogFile)) {
        $safeName = [IO.Path]::GetFileName($PreferredLogFile)
        if (-not [string]::IsNullOrWhiteSpace($safeName)) {
            $preferredPath = Join-Path $logRoot $safeName
            if (Test-Path -LiteralPath $preferredPath -PathType Leaf) {
                return [IO.Path]::GetFullPath($preferredPath)
            }
        }
    }

    try {
        $latest = Get-ChildItem -LiteralPath $logRoot -File -Filter '*.log' -ErrorAction Stop |
            Where-Object { $_.Name -ne 'updater.log' } |
            Sort-Object LastWriteTimeUtc -Descending |
            Select-Object -First 1
        if ($null -ne $latest) { return $latest.FullName }
    }
    catch { }
    return $null
}

function Read-OrbitRecentLog {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [ValidateRange(4096, 1048576)][int]$MaximumBytes = 131072
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return '' }

    $stream = $null
    try {
        $stream = [IO.File]::Open(
            $Path,
            [IO.FileMode]::Open,
            [IO.FileAccess]::Read,
            ([IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete)
        )
        $length = [long]$stream.Length
        $start = [Math]::Max([long]0, $length - [long]$MaximumBytes)
        [void]$stream.Seek($start, [IO.SeekOrigin]::Begin)
        $count = [int]($length - $start)
        [byte[]]$buffer = New-Object byte[] $count
        $offset = 0
        while ($offset -lt $count) {
            $read = $stream.Read($buffer, $offset, $count - $offset)
            if ($read -le 0) { break }
            $offset += $read
        }

        $text = [Text.Encoding]::UTF8.GetString($buffer, 0, $offset)
        $text = $text.TrimStart([char[]]@([char]0xFEFF))
        if ($start -gt 0) {
            $firstNewLine = $text.IndexOf("`n")
            if ($firstNewLine -ge 0) { $text = $text.Substring($firstNewLine + 1) }
            $text = "... showing the most recent technical activity ...`r`n$text"
        }
        return $text.TrimEnd()
    }
    catch {
        [void](Write-OrbitCrashReport -Operation 'Activity.LogRead' -ErrorRecord $_ -Context ([ordered]@{ path = $Path; maximumBytes = $MaximumBytes }))
        return 'The latest technical log could not be read.'
    }
    finally {
        if ($null -ne $stream) { $stream.Dispose() }
    }
}

function Get-OrbitHistoryPath {
    return Join-Path (Join-Path (Get-OrbitDataRoot) 'History') 'history.json'
}

function Get-OrbitWingetArguments {
    param(
        [ValidateSet('Check', 'Update')][string]$Operation = 'Update',
        $Configuration = $null,
        [AllowEmptyString()][string]$PackageId = '',
        [AllowEmptyString()][string]$PackageSource = ''
    )

    if ($null -eq $Configuration) { $Configuration = Get-OrbitConfiguration }

    $arguments = @('upgrade')
    if ($Operation -eq 'Update') {
        if ([string]::IsNullOrWhiteSpace($PackageId)) {
            $arguments += '--all'
        }
        else {
            $arguments += @('--id', $PackageId, '--exact')
            if (-not [string]::IsNullOrWhiteSpace($PackageSource)) {
                $arguments += @('--source', $PackageSource)
            }
        }
    }
    $arguments += '--include-unknown'

    if ([bool]$Configuration.unattendedModeEnabled) {
        $arguments += '--accept-source-agreements'
        if ($Operation -eq 'Update') {
            $arguments += '--accept-package-agreements'
            $arguments += '--silent'
        }
        $arguments += '--disable-interactivity'
    }

    return $arguments
}

function Get-OrbitWingetCommandText {
    param(
        [ValidateSet('Check', 'Update')][string]$Operation = 'Update',
        $Configuration = $null,
        [AllowEmptyString()][string]$PackageId = '',
        [AllowEmptyString()][string]$PackageSource = ''
    )

    $arguments = @(Get-OrbitWingetArguments -Operation $Operation -Configuration $Configuration -PackageId $PackageId -PackageSource $PackageSource)
    $displayArguments = @($arguments | ForEach-Object {
        $value = [string]$_
        if ($value -match '[\s"]') { '"' + ($value -replace '"', '\"') + '"' } else { $value }
    })
    return ('winget {0}' -f ($displayArguments -join ' ')).Trim()
}

function ConvertTo-OrbitDateTimeOffset {
    param([Parameter(Mandatory = $true)]$Value)

    if ($Value -is [DateTimeOffset]) { return [DateTimeOffset]$Value }
    if ($Value -is [DateTime]) { return [DateTimeOffset]([DateTime]$Value) }

    $text = [string]$Value
    $parsed = [DateTimeOffset]::MinValue
    if ([DateTimeOffset]::TryParseExact(
            $text,
            'o',
            [Globalization.CultureInfo]::InvariantCulture,
            [Globalization.DateTimeStyles]::RoundtripKind,
            [ref]$parsed)) {
        return $parsed
    }
    return [DateTimeOffset]::Parse($text, [Globalization.CultureInfo]::CurrentCulture)
}

function Write-OrbitJsonFile {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)]$Value,
        [int]$Depth = 10
    )

    $directory = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $directory)) {
        New-Item -ItemType Directory -Path $directory -Force | Out-Null
    }

    $temporaryPath = Join-Path $directory ('.{0}.{1}.tmp' -f ([IO.Path]::GetFileName($Path)), [Guid]::NewGuid().ToString('N'))
    $json = $Value | ConvertTo-Json -Depth $Depth
    [IO.File]::WriteAllText($temporaryPath, $json, (New-Object Text.UTF8Encoding($false)))

    try {
        $committed = $false
        for ($attempt = 1; $attempt -le 4 -and -not $committed; $attempt++) {
            try {
                if (Test-Path -LiteralPath $Path) {
                    try {
                        [IO.File]::Replace($temporaryPath, $Path, $null, $true)
                    }
                    catch {
                        [IO.File]::Copy($temporaryPath, $Path, $true)
                        Remove-Item -LiteralPath $temporaryPath -Force -ErrorAction SilentlyContinue
                    }
                }
                else {
                    [IO.File]::Move($temporaryPath, $Path)
                }
                $committed = $true
            }
            catch [IO.IOException] {
                if ($attempt -ge 4) { throw }
                Start-Sleep -Milliseconds (75 * $attempt)
            }
            catch [UnauthorizedAccessException] {
                if ($attempt -ge 4) { throw }
                Start-Sleep -Milliseconds (75 * $attempt)
            }
        }
    }
    finally {
        if (Test-Path -LiteralPath $temporaryPath) {
            Remove-Item -LiteralPath $temporaryPath -Force -ErrorAction SilentlyContinue
        }
    }
}

function Get-OrbitDefaultConfiguration {
    return [PSCustomObject][ordered]@{
        schemaVersion             = 4
        automaticUpdatesEnabled  = $true
        automaticInstallationEnabled = $false
        installOnStartupEnabled  = $false
        notificationsEnabled     = $true
        showTaskbarStatusBadge   = $true
        intervalHours            = 6
        theme                    = 'System'
        showTechnicalDetails     = $false
        technicalDetailsLocation = 'Separate'
        historyRetentionDays     = 90
        deleteLogsWithHistory    = $false
        unattendedModeEnabled    = $true
        updatedAt                = [DateTimeOffset]::Now.ToString('o')
    }
}

function Get-OrbitConfiguration {
    $defaults = Get-OrbitDefaultConfiguration
    $configPath = Join-Path (Get-OrbitDataRoot) 'config.json'
    $configuration = [ordered]@{}

    foreach ($property in $defaults.PSObject.Properties) {
        $configuration[$property.Name] = $property.Value
    }

    if (Test-Path -LiteralPath $configPath) {
        try {
            $saved = Get-Content -LiteralPath $configPath -Raw -Encoding UTF8 | ConvertFrom-Json
            $hasCurrentAutomaticSetting = $null -ne $saved.PSObject.Properties['automaticUpdatesEnabled']
            foreach ($property in $saved.PSObject.Properties) {
                $matchingKey = @($configuration.Keys | Where-Object {
                    [string]::Equals([string]$_, [string]$property.Name, [StringComparison]::OrdinalIgnoreCase)
                }) | Select-Object -First 1
                if ($null -ne $matchingKey) {
                    $configuration[$matchingKey] = $property.Value
                }
            }
            # Versions before structured config used `enabled` for the same
            # real scheduling preference. Honor it during in-place upgrades.
            if (-not $hasCurrentAutomaticSetting -and $null -ne $saved.PSObject.Properties['enabled']) {
                $configuration.automaticUpdatesEnabled = [bool]$saved.enabled
            }
        }
        catch {
            [void](Write-OrbitCrashReport -Operation 'Configuration.Load' -ErrorRecord $_ -Context ([ordered]@{ configPath = $configPath }))
        }
    }

    if (@(1, 3, 6, 12, 24) -notcontains [int]$configuration.intervalHours) {
        $configuration.intervalHours = 6
    }
    if (@('System', 'Light', 'Dark') -notcontains [string]$configuration.theme) {
        $configuration.theme = 'System'
    }
    if ($configuration.showTechnicalDetails -isnot [bool]) {
        $configuration.showTechnicalDetails = $false
    }
    foreach ($booleanSetting in @(
            'automaticUpdatesEnabled',
            'automaticInstallationEnabled',
            'installOnStartupEnabled',
            'notificationsEnabled',
            'showTaskbarStatusBadge',
            'deleteLogsWithHistory',
            'unattendedModeEnabled')) {
        if ($configuration.$booleanSetting -isnot [bool]) {
            $configuration.$booleanSetting = [bool](Get-OrbitDefaultConfiguration).$booleanSetting
        }
    }
    if (-not [bool]$configuration.automaticInstallationEnabled) {
        $configuration.installOnStartupEnabled = $false
    }
    if (@(30, 90, 0) -notcontains [int]$configuration.historyRetentionDays) {
        $configuration.historyRetentionDays = 90
    }
    if ([string]$configuration.technicalDetailsLocation -ne 'Separate') {
        $configuration.technicalDetailsLocation = 'Separate'
    }

    return [PSCustomObject]$configuration
}

function Save-OrbitConfiguration {
    param([Parameter(Mandatory = $true)][hashtable]$Changes)

    $configurationMutex = New-Object Threading.Mutex($false, 'Local\OrbitUpdater.Configuration')
    $acquired = $false
    try {
        $acquired = $configurationMutex.WaitOne([TimeSpan]::FromSeconds(5))
        if (-not $acquired) { throw 'Configuration storage is busy. Try again in a moment.' }

        $current = Get-OrbitConfiguration
        $updated = [ordered]@{}
        foreach ($property in $current.PSObject.Properties) {
            $updated[$property.Name] = $property.Value
        }
        foreach ($key in $Changes.Keys) {
            if ($updated.Contains($key)) {
                $updated[$key] = $Changes[$key]
            }
        }
        if (-not [bool]$updated.automaticInstallationEnabled) {
            $updated.installOnStartupEnabled = $false
        }
        $updated.schemaVersion = 4
        $updated.updatedAt = [DateTimeOffset]::Now.ToString('o')
        Write-OrbitJsonFile -Path (Join-Path (Get-OrbitDataRoot) 'config.json') -Value $updated
        return [PSCustomObject]$updated
    }
    finally {
        if ($acquired) { try { $configurationMutex.ReleaseMutex() } catch { } }
        $configurationMutex.Dispose()
    }
}

function Get-OrbitHistory {
    $historyPath = Get-OrbitHistoryPath
    if (-not (Test-Path -LiteralPath $historyPath)) { return @() }

    try {
        $saved = Get-Content -LiteralPath $historyPath -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($null -ne $saved.PSObject.Properties['entries']) {
            return @($saved.entries)
        }
        return @($saved)
    }
    catch {
        [void](Write-OrbitCrashReport -Operation 'History.Load' -ErrorRecord $_ -Context ([ordered]@{ historyPath = $historyPath }))
        return @()
    }
}

function Test-OrbitAutomaticRunDue {
    param(
        $Configuration = $null,
        [DateTimeOffset]$Now = [DateTimeOffset]::Now
    )

    if ($null -eq $Configuration) { $Configuration = Get-OrbitConfiguration }
    if (-not [bool]$Configuration.automaticUpdatesEnabled) { return $false }

    $intervalHours = [int]$Configuration.intervalHours
    if (@(1, 3, 6, 12, 24) -notcontains $intervalHours) { $intervalHours = 6 }

    $lastAutomaticRun = $null
    foreach ($entry in @(Get-OrbitHistory)) {
        if ([string]$entry.runType -notin @('scheduled-check', 'scheduled-update', 'sign-in-check', 'sign-in-update')) { continue }
        $timestampValue = if ($null -ne $entry.PSObject.Properties['finishedAt']) { $entry.finishedAt } else { $entry.startedAt }
        try {
            $timestamp = ConvertTo-OrbitDateTimeOffset -Value $timestampValue
            if ($null -eq $lastAutomaticRun -or $timestamp -gt $lastAutomaticRun) { $lastAutomaticRun = $timestamp }
        }
        catch { }
    }

    if ($null -eq $lastAutomaticRun) { return $true }
    return $Now.Subtract([DateTimeOffset]$lastAutomaticRun).TotalHours -ge $intervalHours
}

function Save-OrbitHistory {
    param([Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]]$Entries)

    $orderedEntries = @($Entries | Sort-Object { ConvertTo-OrbitDateTimeOffset -Value $_.startedAt } -Descending)
    $payload = [ordered]@{
        schemaVersion = 1
        updatedAt     = [DateTimeOffset]::Now.ToString('o')
        entries       = $orderedEntries
    }
    Write-OrbitJsonFile -Path (Get-OrbitHistoryPath) -Value $payload -Depth 12
}

function Invoke-OrbitHistoryLocked {
    param([Parameter(Mandatory = $true)][scriptblock]$Action)

    $historyMutex = New-Object Threading.Mutex($false, 'Local\WingetAutoUpdater.History')
    $acquired = $false
    try {
        $acquired = $historyMutex.WaitOne([TimeSpan]::FromSeconds(10))
        if (-not $acquired) { throw 'History storage is busy. Try again in a moment.' }
        return & $Action
    }
    finally {
        if ($acquired) { try { $historyMutex.ReleaseMutex() } catch { } }
        $historyMutex.Dispose()
    }
}

function Add-OrbitHistoryEntry {
    param([Parameter(Mandatory = $true)]$Entry)

    Invoke-OrbitHistoryLocked {
        $entries = @(Get-OrbitHistory)
        $combined = @($Entry) + $entries
        Save-OrbitHistory -Entries $combined
    }
}

function Remove-OrbitEntryLog {
    param($Entry)

    if ($null -eq $Entry -or [string]::IsNullOrWhiteSpace([string]$Entry.logFile)) { return }
    $logRoot = [IO.Path]::GetFullPath((Get-OrbitLogRoot)).TrimEnd('\') + '\'
    $candidate = [IO.Path]::GetFullPath((Join-Path (Get-OrbitLogRoot) ([IO.Path]::GetFileName([string]$Entry.logFile))))
    if ($candidate.StartsWith($logRoot, [StringComparison]::OrdinalIgnoreCase) -and (Test-Path -LiteralPath $candidate)) {
        Remove-Item -LiteralPath $candidate -Force -ErrorAction SilentlyContinue
    }
}

function Remove-OrbitHistoryEntry {
    param(
        [Parameter(Mandatory = $true)][string]$Id,
        [bool]$DeleteAssociatedLog = $true
    )

    Invoke-OrbitHistoryLocked {
        $entries = @(Get-OrbitHistory)
        $removed = @($entries | Where-Object { [string]$_.id -eq $Id })
        $remaining = @($entries | Where-Object { [string]$_.id -ne $Id })
        Save-OrbitHistory -Entries $remaining
        if ($DeleteAssociatedLog) {
            foreach ($entry in $removed) { Remove-OrbitEntryLog -Entry $entry }
        }
    }
}

function Clear-OrbitHistory {
    param([bool]$DeleteAssociatedLogs = $true)

    Invoke-OrbitHistoryLocked {
        $entries = @(Get-OrbitHistory)
        Save-OrbitHistory -Entries @()
        if ($DeleteAssociatedLogs) {
            foreach ($entry in $entries) { Remove-OrbitEntryLog -Entry $entry }
        }
    }
}

function Invoke-OrbitHistoryRetention {
    $configuration = Get-OrbitConfiguration
    $retentionDays = [int]$configuration.historyRetentionDays
    if ($retentionDays -eq 0) { return }

    $cutoff = [DateTimeOffset]::Now.AddDays(-$retentionDays)
    Invoke-OrbitHistoryLocked {
        $entries = @(Get-OrbitHistory)
        $expired = @()
        $retained = @()
        foreach ($entry in $entries) {
            try {
                if ((ConvertTo-OrbitDateTimeOffset -Value $entry.startedAt) -lt $cutoff) { $expired += $entry }
                else { $retained += $entry }
            }
            catch { $retained += $entry }
        }

        if ($expired.Count -gt 0) {
            Save-OrbitHistory -Entries $retained
            if ([bool]$configuration.deleteLogsWithHistory) {
                foreach ($entry in $expired) { Remove-OrbitEntryLog -Entry $entry }
            }
        }
    }
}
