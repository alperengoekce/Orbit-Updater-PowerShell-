[CmdletBinding()]
param()

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$projectRoot = Split-Path -Parent $PSScriptRoot
$commonPath = Join-Path $projectRoot 'OrbitData.ps1'
$enginePath = Join-Path $projectRoot 'WingetUpdateEngine.ps1'
$taskManagerPath = Join-Path $projectRoot 'TaskManager.ps1'
$installPath = Join-Path $projectRoot 'Install.ps1'
$controllerPath = Join-Path $projectRoot 'WingetAutoUpdater.ps1'
$launcherPath = Join-Path $projectRoot 'OrbitUpdaterLauncher.vbs'
$runAppPath = Join-Path $projectRoot 'Run App.cmd'
$xamlPath = Join-Path $projectRoot 'OrbitUpdater.xaml'
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('OrbitUpdaterTests-' + [Guid]::NewGuid().ToString('N'))
$resolvedTemp = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\'
$resolvedTestRoot = [IO.Path]::GetFullPath($testRoot)
$passed = 0

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw "Assertion failed: $Message" }
    $script:passed++
    Write-Output "PASS $Message"
}

function Get-FunctionDefinitionText {
    param([string]$Path, [string]$Name)
    $tokens = $null
    $errors = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$errors)
    if ($errors.Count -gt 0) { throw "Cannot load test function from $Path because it has parser errors." }
    $definition = $ast.FindAll({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $Name }, $true) | Select-Object -First 1
    if ($null -eq $definition) { throw "Function $Name was not found in $Path." }
    return $definition.Extent.Text
}

function New-HistoryEntry {
    param([string]$Id, [DateTimeOffset]$StartedAt, [string]$LogFile)
    return [PSCustomObject][ordered]@{
        id = $Id
        startedAt = $StartedAt.ToString('o')
        finishedAt = $StartedAt.AddSeconds(4).ToString('o')
        runType = 'manual-check'
        status = 'success'
        exitCode = 0
        updatesFound = 1
        updatesInstalled = 0
        updatesFailed = 0
        updatesSkipped = 0
        durationSeconds = 4
        restartRequired = $false
        logFile = $LogFile
        packages = @()
    }
}

try {
    if (-not $resolvedTestRoot.StartsWith($resolvedTemp, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'Refusing to use a test path outside the system temporary directory.'
    }
    New-Item -ItemType Directory -Path $resolvedTestRoot -Force | Out-Null
    $env:ORBIT_UPDATER_TEST_ROOT = $resolvedTestRoot
    . $commonPath

    $defaultConfig = Get-OrbitConfiguration
    Assert-True ($script:OrbitAppUserModelId -eq 'Orbit.Updater') 'Orbit uses one stable explicit AppUserModelID'
    $identityShortcutPath = Join-Path $resolvedTestRoot 'Orbit Identity Test.lnk'
    $identityShell = New-Object -ComObject WScript.Shell
    $identityShortcut = $identityShell.CreateShortcut($identityShortcutPath)
    $identityShortcut.TargetPath = Join-Path $env:SystemRoot 'System32\notepad.exe'
    $identityShortcut.Save()
    Set-OrbitShortcutAppIdentity -Path $identityShortcutPath
    $identityShellItem = (New-Object -ComObject Shell.Application).Namespace($resolvedTestRoot).ParseName('Orbit Identity Test.lnk')
    Assert-True ([string]$identityShellItem.ExtendedProperty('System.AppUserModel.ID') -eq $script:OrbitAppUserModelId) 'shortcut identity metadata is written and can be read back by Windows Shell'
    Assert-True ($defaultConfig.theme -eq 'System') 'configuration defaults to the system theme'
    Assert-True ($defaultConfig.showTechnicalDetails -eq $false) 'technical details default to off'
    Assert-True ($defaultConfig.historyRetentionDays -eq 90) 'history retention defaults to 90 days'
    Assert-True ($defaultConfig.automaticInstallationEnabled -eq $false) 'automatic installation defaults to off'
    Assert-True ($defaultConfig.installOnStartupEnabled -eq $false) 'startup installation defaults to off'
    Assert-True ($defaultConfig.notificationsEnabled -eq $true) 'background notifications default to on'
    Assert-True ($defaultConfig.showTaskbarStatusBadge -eq $true) 'taskbar status badge defaults to on'

    $configurationPath = Join-Path $resolvedTestRoot 'config.json'
    Write-OrbitJsonFile -Path $configurationPath -Value ([ordered]@{ intervalHours=12;theme='Light' })
    $missingTechnicalPreference = Get-OrbitConfiguration
    Assert-True ($missingTechnicalPreference.showTechnicalDetails -eq $false -and $missingTechnicalPreference.intervalHours -eq 12 -and $missingTechnicalPreference.theme -eq 'Light') 'a missing technical-details preference defaults off without resetting unrelated settings'
    Write-OrbitJsonFile -Path $configurationPath -Value ([ordered]@{ intervalHours=3;theme='Dark';showTechnicalDetails=$null })
    $nullTechnicalPreference = Get-OrbitConfiguration
    Assert-True ($nullTechnicalPreference.showTechnicalDetails -eq $false -and $nullTechnicalPreference.intervalHours -eq 3 -and $nullTechnicalPreference.theme -eq 'Dark') 'a null technical-details preference safely defaults off'
    Write-OrbitJsonFile -Path $configurationPath -Value ([ordered]@{ intervalHours=24;theme='Light';showTechnicalDetails='enabled' })
    $invalidTechnicalPreference = Get-OrbitConfiguration
    Assert-True ($invalidTechnicalPreference.showTechnicalDetails -eq $false -and $invalidTechnicalPreference.intervalHours -eq 24 -and $invalidTechnicalPreference.theme -eq 'Light') 'an invalid technical-details preference defaults off without resetting unrelated settings'

    Write-OrbitJsonFile -Path $configurationPath -Value ([ordered]@{ intervalHours=12;theme='Light' })
    $missingTaskbarBadgePreference = Get-OrbitConfiguration
    Assert-True ($missingTaskbarBadgePreference.showTaskbarStatusBadge -eq $true -and $missingTaskbarBadgePreference.intervalHours -eq 12 -and $missingTaskbarBadgePreference.theme -eq 'Light') 'a missing taskbar-badge preference defaults on without resetting unrelated settings'
    Write-OrbitJsonFile -Path $configurationPath -Value ([ordered]@{ intervalHours=3;theme='Dark';showTaskbarStatusBadge='enabled' })
    $invalidTaskbarBadgePreference = Get-OrbitConfiguration
    Assert-True ($invalidTaskbarBadgePreference.showTaskbarStatusBadge -eq $true -and $invalidTaskbarBadgePreference.intervalHours -eq 3 -and $invalidTaskbarBadgePreference.theme -eq 'Dark') 'an invalid taskbar-badge preference defaults on without resetting unrelated settings'

    Write-OrbitJsonFile -Path $configurationPath -Value ([ordered]@{ enabled = $false; IntervalHours = 12; Theme = 'Light' })
    $legacyConfig = Get-OrbitConfiguration
    Assert-True ($legacyConfig.automaticUpdatesEnabled -eq $false) 'legacy paused scheduling preference migrates without being re-enabled'
    Assert-True ($legacyConfig.intervalHours -eq 12 -and $legacyConfig.theme -eq 'Light') 'legacy configuration keys load case-insensitively'

    $savedConfig = Save-OrbitConfiguration -Changes @{ theme = 'Dark'; intervalHours = 3; showTechnicalDetails = $true }
    $reloadedConfig = Get-OrbitConfiguration
    Assert-True ($reloadedConfig.theme -eq 'Dark' -and $reloadedConfig.intervalHours -eq 3) 'configuration changes survive serialization'
    Assert-True ($reloadedConfig.showTechnicalDetails -eq $true -and $reloadedConfig.deleteLogsWithHistory -eq $false) 'configuration merging preserves unrelated fields'
    [void](Save-OrbitConfiguration -Changes @{ automaticInstallationEnabled=$true; installOnStartupEnabled=$true; notificationsEnabled=$false })
    $automationConfig = Get-OrbitConfiguration
    Assert-True ($automationConfig.automaticInstallationEnabled -and $automationConfig.installOnStartupEnabled -and -not $automationConfig.notificationsEnabled) 'automation preferences persist independently from automatic checking'
    [void](Save-OrbitConfiguration -Changes @{ automaticInstallationEnabled=$false })
    Assert-True (-not (Get-OrbitConfiguration).installOnStartupEnabled) 'disabling automatic installation also disables startup installation'
    [void](Save-OrbitConfiguration -Changes @{ showTechnicalDetails = $false })
    Assert-True ((Get-OrbitConfiguration).showTechnicalDetails -eq $false) 'disabled technical-details preference persists across reload'
    [void](Save-OrbitConfiguration -Changes @{ showTechnicalDetails = $true })
    Assert-True ((Get-OrbitConfiguration).showTechnicalDetails -eq $true) 'enabled technical-details preference persists across reload'
    [void](Save-OrbitConfiguration -Changes @{ showTaskbarStatusBadge = $false })
    Assert-True ((Get-OrbitConfiguration).showTaskbarStatusBadge -eq $false) 'disabled taskbar-badge preference persists across reload'
    [void](Save-OrbitConfiguration -Changes @{ showTaskbarStatusBadge = $true })
    Assert-True ((Get-OrbitConfiguration).showTaskbarStatusBadge -eq $true) 'enabled taskbar-badge preference persists across reload'

    $testException = New-Object InvalidOperationException('stability-test failure')
    $crashReportPath = Write-OrbitCrashReport -Operation 'Tests.CrashReport' -Exception $testException -Context ([ordered]@{ currentPage='Overview'; sliderValue=3 })
    $crashReport = Get-Content -LiteralPath $crashReportPath -Raw -Encoding UTF8 | ConvertFrom-Json
    Assert-True ($crashReport.operation -eq 'Tests.CrashReport' -and $crashReport.exceptionType -eq 'System.InvalidOperationException') 'crash reports retain the operation and exception type'
    Assert-True ($crashReport.context.currentPage -eq 'Overview' -and $null -ne $crashReport.thread.managedId) 'crash reports retain UI context and thread information'

    $configurationLock = [IO.File]::Open($configurationPath,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::None)
    $lockedSaveFailed = $false
    try {
        try { [void](Save-OrbitConfiguration -Changes @{ intervalHours = 12 }) }
        catch { $lockedSaveFailed = $true }
    }
    finally { $configurationLock.Dispose() }
    $configurationAfterLock = Get-OrbitConfiguration
    Assert-True ($lockedSaveFailed -and [int]$configurationAfterLock.intervalHours -eq 3) 'a locked configuration fails safely without corrupting the previous interval'

    [IO.File]::WriteAllText($configurationPath, '{ malformed configuration', (New-Object Text.UTF8Encoding($false)))
    $recoveredConfiguration = Get-OrbitConfiguration
    Assert-True ($recoveredConfiguration.theme -eq 'System' -and [int]$recoveredConfiguration.intervalHours -eq 6 -and $recoveredConfiguration.showTechnicalDetails -eq $false) 'malformed configuration loads safe defaults with technical details off'
    [void](Save-OrbitConfiguration -Changes @{ theme='Dark'; intervalHours=3; showTechnicalDetails=$true })

    $unattendedConfig = [PSCustomObject]@{ unattendedModeEnabled = $true }
    $interactiveConfig = [PSCustomObject]@{ unattendedModeEnabled = $false }
    $updateCommand = Get-OrbitWingetCommandText -Operation Update -Configuration $unattendedConfig
    $checkCommand = Get-OrbitWingetCommandText -Operation Check -Configuration $unattendedConfig
    $interactiveCommand = Get-OrbitWingetCommandText -Operation Update -Configuration $interactiveConfig
    $packageCommand = Get-OrbitWingetCommandText -Operation Update -Configuration $unattendedConfig -PackageId 'Example.Package'
    $sourcedPackageCommand = Get-OrbitWingetCommandText -Operation Update -Configuration $unattendedConfig -PackageId 'Store.Package' -PackageSource 'msstore'
    Assert-True ($updateCommand -eq 'winget upgrade --all --include-unknown --accept-source-agreements --accept-package-agreements --silent --disable-interactivity') 'update command text matches the shared unattended argument builder'
    Assert-True ($checkCommand -eq 'winget upgrade --include-unknown --accept-source-agreements --disable-interactivity') 'check command text omits update-only arguments'
    Assert-True ($interactiveCommand -eq 'winget upgrade --all --include-unknown') 'non-unattended command text omits agreement and silent arguments'
    Assert-True ($packageCommand -eq 'winget upgrade --id Example.Package --exact --include-unknown --accept-source-agreements --accept-package-agreements --silent --disable-interactivity') 'per-package command targets the stable package ID with exact matching'
    Assert-True ($sourcedPackageCommand -eq 'winget upgrade --id Store.Package --exact --source msstore --include-unknown --accept-source-agreements --accept-package-agreements --silent --disable-interactivity') 'per-package command preserves the discovered source as part of the exact target'

    $historyStoragePath = Get-OrbitHistoryPath
    $historyStorageDirectory = Split-Path -Parent $historyStoragePath
    New-Item -ItemType Directory -Path $historyStorageDirectory -Force | Out-Null
    [IO.File]::WriteAllText($historyStoragePath, '{ malformed history', (New-Object Text.UTF8Encoding($false)))
    Assert-True (@(Get-OrbitHistory).Count -eq 0) 'malformed structured History loads as an empty collection without throwing'
    Clear-OrbitHistory -DeleteAssociatedLogs $false
    $dueNow = [DateTimeOffset]::Parse('2026-08-04T12:00:00+02:00')
    $automaticConfig = [PSCustomObject]@{ automaticUpdatesEnabled = $true; intervalHours = 3 }
    Assert-True (Test-OrbitAutomaticRunDue -Configuration $automaticConfig -Now $dueNow) 'automatic interval gate permits the first scheduled run'
    $automaticEntry = New-HistoryEntry -Id 'automatic-run' -StartedAt $dueNow.AddHours(-2) -LogFile 'automatic.log'
    $automaticEntry.runType = 'scheduled-update'
    Add-OrbitHistoryEntry -Entry $automaticEntry
    Assert-True (-not (Test-OrbitAutomaticRunDue -Configuration $automaticConfig -Now $dueNow)) 'automatic interval gate skips an hourly wake-up before the selected interval'
    Assert-True (Test-OrbitAutomaticRunDue -Configuration $automaticConfig -Now $dueNow.AddHours(2)) 'automatic interval gate permits a wake-up after the selected interval'
    Assert-True (-not (Test-OrbitAutomaticRunDue -Configuration ([PSCustomObject]@{ automaticUpdatesEnabled = $false; intervalHours = 1 }) -Now $dueNow)) 'disabled automatic updates skip background work without task changes'
    Clear-OrbitHistory -DeleteAssociatedLogs $false

    $logRoot = Get-OrbitLogRoot
    New-Item -ItemType Directory -Path $logRoot -Force | Out-Null
    $largeLog = Join-Path $logRoot 'large.log'
    [IO.File]::WriteAllText($largeLog, (('older activity line' + "`r`n") * 12000) + "IMPORTANT ERROR: preserved at the end`r`n")
    $recentLargeLog = Read-OrbitRecentLog -Path $largeLog -MaximumBytes 4096
    Assert-True ($recentLargeLog -match 'showing the most recent technical activity' -and $recentLargeLog -match 'IMPORTANT ERROR: preserved at the end') 'large Activity logs are bounded while preserving recent errors'
    Assert-True ($recentLargeLog.Length -lt 5000) 'large Activity logs return a responsive recent portion'
    $malformedLog = Join-Path $logRoot 'malformed.log'
    [IO.File]::WriteAllBytes($malformedLog, [byte[]]@(0xFF,0xFE,0x00,0x80,0x0A,0x41))
    $malformedText = Read-OrbitRecentLog -Path $malformedLog
    Assert-True ($null -ne $malformedText) 'malformed Activity logs do not throw or crash the reader'
    Assert-True ((Get-OrbitLatestRunLogPath -PreferredLogFile 'large.log') -eq $largeLog) 'Activity resolves the raw log associated with the current run'
    $oldLog = Join-Path $logRoot 'old.log'
    $recentLog = Join-Path $logRoot 'recent.log'
    [IO.File]::WriteAllText($oldLog, 'old')
    [IO.File]::WriteAllText($recentLog, 'recent')
    Add-OrbitHistoryEntry -Entry (New-HistoryEntry -Id 'old' -StartedAt ([DateTimeOffset]::Now.AddDays(-120)) -LogFile 'old.log')
    Add-OrbitHistoryEntry -Entry (New-HistoryEntry -Id 'recent' -StartedAt ([DateTimeOffset]::Now.AddDays(-2)) -LogFile 'recent.log')
    Assert-True (@(Get-OrbitHistory).Count -eq 2) 'structured history serializes multiple entries'

    [void](Save-OrbitConfiguration -Changes @{ historyRetentionDays = 90; deleteLogsWithHistory = $true })
    Invoke-OrbitHistoryRetention
    $retained = @(Get-OrbitHistory)
    Assert-True ($retained.Count -eq 1 -and $retained[0].id -eq 'recent') 'retention removes only expired history entries'
    Assert-True (-not (Test-Path -LiteralPath $oldLog)) 'retention removes an associated log when configured'
    Assert-True (Test-Path -LiteralPath $recentLog) 'retention preserves logs for retained entries'

    Clear-OrbitHistory -DeleteAssociatedLogs $false
    $keptLog = Join-Path $logRoot 'kept.log'
    [IO.File]::WriteAllText($keptLog, 'keep')
    Add-OrbitHistoryEntry -Entry (New-HistoryEntry -Id 'keep-log' -StartedAt ([DateTimeOffset]::Now.AddDays(-45)) -LogFile 'kept.log')
    [void](Save-OrbitConfiguration -Changes @{ historyRetentionDays = 30; deleteLogsWithHistory = $false })
    Invoke-OrbitHistoryRetention
    Assert-True (@(Get-OrbitHistory).Count -eq 0) 'shorter retention removes expired structured history'
    Assert-True (Test-Path -LiteralPath $keptLog) 'retention keeps raw logs when log deletion is disabled'

    Invoke-Expression (Get-FunctionDefinitionText -Path $enginePath -Name 'Get-ResultClassification')
    Invoke-Expression (Get-FunctionDefinitionText -Path $enginePath -Name 'Get-WingetUpgradeParseResult')
    Invoke-Expression (Get-FunctionDefinitionText -Path $enginePath -Name 'Get-WingetUpgradeItems')
    Invoke-Expression (Get-FunctionDefinitionText -Path $enginePath -Name 'Get-OrbitProgressPercentage')
    $noUpdates = Get-ResultClassification -Code -1978335189 -IsCheck $true -UpdatesFound 0
    $mismatch = Get-ResultClassification -Code -1978335090 -IsCheck $false -UpdatesFound 1
    $restart = Get-ResultClassification -Code -1978334967 -IsCheck $false -UpdatesFound 1
    $locationRequired = Get-ResultClassification -Code -1978335137 -IsCheck $false -UpdatesFound 1
    Assert-True ($noUpdates.State -eq 'NoUpdates' -and $noUpdates.History -eq 'no-updates-found') 'Winget no-update HRESULT maps accurately'
    Assert-True ($mismatch.Category -eq 'installer-technology-mismatch' -and $mismatch.State -eq 'ActionRequired') 'installer mismatch maps to manual action required'
    Assert-True ($restart.Restart -eq $true -and $restart.State -eq 'RestartRequired') 'reboot-required HRESULT maps accurately'
    Assert-True ($locationRequired.Category -eq 'install-location-required' -and $locationRequired.Message -match 'install location') 'missing install-location HRESULT maps to a concise user-facing reason'

    $localizedTable = @'
Name                         ID                         Version    Verf{U}gbar  Quelle
----------------------------------------------------------------------------------
Example Application          Example.Package            1.2.3      2.0.0      winget
Another App                  Vendor.Another              Unknown    5.1        winget
2 Aktualisierungen verfügbar.
'@
    $localizedTable = $localizedTable -replace '\{U\}',([string][char]0x00FC)
    $parsedItems = @(Get-WingetUpgradeItems -Output $localizedTable)
    Assert-True ($parsedItems.Count -eq 2) 'available-update parsing does not depend on localized header words'
    Assert-True ($parsedItems[0].Id -eq 'Example.Package' -and $parsedItems[0].AvailableVersion -eq '2.0.0') ("available-update versions and IDs are parsed by column position (actual ID={0}, available={1})" -f $parsedItems[0].Id,$parsedItems[0].AvailableVersion)

    $realGermanTable = @'
Name                                  ID                          Version        Verf{U}gbar      Quelle
------------------------------------------------------------------------------------------------------
Battle.net                            Blizzard.BattleNet          Unknown        1.19.3.3219    winget
Microsoft Edge                        Microsoft.Edge              151.0.4129.101 151.0.4129.107 winget
NVIDIA PhysX-Systemsoftware 9.23.1019 Nvidia.PhysX                9.23.1019      9.26.0703      winget
Tower of Fantasy                      PerfectWorld.TowerOfFantasy Unknown        0.0.6.471      winget
4 Aktualisierungen verfügbar.
'@
    $realGermanTable = $realGermanTable -replace '\{U\}',([string][char]0x00FC)
    $realGermanItems = @(Get-WingetUpgradeItems -Output $realGermanTable)
    Assert-True ($realGermanItems.Count -eq 4) 'fixed-width localized output retains every package row when populated version fields have only single-space separation'
    Assert-True ($realGermanItems[1].Name -eq 'Microsoft Edge' -and $realGermanItems[1].InstalledVersion -eq '151.0.4129.101' -and $realGermanItems[1].AvailableVersion -eq '151.0.4129.107') 'fully populated adjacent version columns are sliced by header offsets'
    Assert-True ($realGermanItems[2].Name -eq 'NVIDIA PhysX-Systemsoftware' -and $realGermanItems[3].Source -eq 'winget') 'duplicated installed-version suffixes are normalized while source metadata survives parsing'
    $singleRowTable = (($realGermanTable -split "`r?`n")[0..2] + '1 Aktualisierung verfügbar.') -join "`r`n"
    $singleParsedItem = @(Get-WingetUpgradeItems -Output $singleRowTable)
    Assert-True ($singleParsedItem.Count -eq 1 -and $singleParsedItem[0].Id -eq 'Blizzard.BattleNet') 'one-row localized output remains an explicit one-item collection at the parser boundary'

    Assert-True ((Get-OrbitProgressPercentage -Text 'Fortschritt: 68 %') -eq 68) 'live progress parsing is independent of localized surrounding words and whitespace'
    Assert-True ((Get-OrbitProgressPercentage -Text "12%`r48%`r91%") -eq 91) 'live progress parsing accepts carriage-return updates and uses the newest valid value'
    Assert-True ((Get-OrbitProgressPercentage -Text (([char]27) + '[36m48.4%' + ([char]27) + '[0m')) -eq 48) 'live progress parsing tolerates console color/control sequences and decimal percentages'
    Assert-True ($null -eq (Get-OrbitProgressPercentage -Text 'invalid: -5% 101% 250%')) 'live progress parsing rejects negative and out-of-range values'
    Assert-True ($null -eq (Get-OrbitProgressPercentage -Text 'Package 100%Pure has no progress report')) 'percent-like package names are not mistaken for installation progress'

    $script:effectiveTheme = 'Light'
    Invoke-Expression (Get-FunctionDefinitionText -Path $controllerPath -Name 'Get-StatusSemanticPalette')
    Invoke-Expression (Get-FunctionDefinitionText -Path $controllerPath -Name 'Get-OverviewStatusPresentation')
    $notCheckedPresentation = Get-OverviewStatusPresentation -State NotChecked
    $checkingPresentation = Get-OverviewStatusPresentation -State Checking
    $upToDatePresentation = Get-OverviewStatusPresentation -State UpToDate
    $oneUpdatePresentation = Get-OverviewStatusPresentation -State UpdatesAvailable -UpdateCount 1
    $multipleUpdatesPresentation = Get-OverviewStatusPresentation -State UpdatesAvailable -UpdateCount 4
    $installingPresentation = Get-OverviewStatusPresentation -State Installing
    $partialPresentation = Get-OverviewStatusPresentation -State CompletedWithIssues
    $checkFailedPresentation = Get-OverviewStatusPresentation -State CheckFailed
    $installationFailedPresentation = Get-OverviewStatusPresentation -State InstallationFailed
    Assert-True ($notCheckedPresentation.BadgeText -eq 'Not checked yet' -and $notCheckedPresentation.Background -eq '#F3F4F6' -and $notCheckedPresentation.Foreground -eq '#6B7280') 'fresh Overview status is neutral and does not invent an update result'
    Assert-True ($checkingPresentation.BadgeText -eq 'Checking' -and $checkingPresentation.CardTitle -eq 'Checking for updates') 'check-running presentation keeps badge and action card consistent'
    Assert-True ($upToDatePresentation.BadgeText -eq 'Up to date' -and $upToDatePresentation.CardTitle -eq 'Check for updates') 'zero-update presentation returns the action card to idle'
    Assert-True ($oneUpdatePresentation.BadgeText -eq '1 update available' -and $oneUpdatePresentation.CardTitle -eq 'Updates ready to install') 'one available update uses singular badge grammar'
    Assert-True ($multipleUpdatesPresentation.BadgeText -eq '4 updates available' -and $multipleUpdatesPresentation.CardSubtitle -notmatch '\b4\b') 'multiple updates use plural badge grammar without repeating the count in the card'
    Assert-True ($installingPresentation.BadgeText -eq 'Installing' -and $installingPresentation.CardTitle -eq 'Installing updates') 'installation-running presentation keeps badge and action card consistent'
    Assert-True ($partialPresentation.BadgeText -eq 'Completed with issues' -and $partialPresentation.Foreground -eq '#C2410C') 'partial installation uses the centralized orange warning presentation'
    Assert-True ($checkFailedPresentation.BadgeText -eq 'Check failed' -and $checkFailedPresentation.CardTitle -eq 'Update operation failed') 'check failure uses the focused failure presentation'
    Assert-True ($installationFailedPresentation.BadgeText -eq 'Installation failed' -and $installationFailedPresentation.CardTitle -eq 'Update operation failed') 'installation failure uses the focused failure presentation'

    Invoke-Expression (Get-FunctionDefinitionText -Path $controllerPath -Name 'Get-OptionalProperty')
    Invoke-Expression (Get-FunctionDefinitionText -Path $controllerPath -Name 'Get-OverviewStatusState')
    $freshState = Get-OverviewStatusState -State $null
    $checkingState = Get-OverviewStatusState -State ([PSCustomObject]@{runType='manual-check';status='NoUpdates'}) -ActiveState Checking
    $zeroUpdateState = Get-OverviewStatusState -State ([PSCustomObject]@{runType='manual-check';status='NoUpdates'})
    $oneUpdateState = Get-OverviewStatusState -State ([PSCustomObject]@{runType='manual-check';status='UpdatesAvailable'}) -UpdateCount 1
    $multipleUpdateState = Get-OverviewStatusState -State ([PSCustomObject]@{runType='manual-check';status='UpdatesAvailable'}) -UpdateCount 4
    $compatibleSuccessState = Get-OverviewStatusState -State ([PSCustomObject]@{runType='manual-check';status='Success'}) -UpdateCount 3
    $installingState = Get-OverviewStatusState -State ([PSCustomObject]@{runType='manual-update';status='NoUpdates'}) -ActiveState Installing
    $installedState = Get-OverviewStatusState -State ([PSCustomObject]@{runType='manual-update';status='Success'})
    $remainingUpdateState = Get-OverviewStatusState -State ([PSCustomObject]@{runType='manual-update';status='UpdatesAvailable'}) -UpdateCount 2
    $failedCheckState = Get-OverviewStatusState -State ([PSCustomObject]@{runType='manual-check';status='LastCheckFailed'})
    $incompleteScheduledState = Get-OverviewStatusState -State ([PSCustomObject]@{runType='scheduled-update';status='LastCheckFailed';errorCategory='incomplete-parse'})
    $failedInstallState = Get-OverviewStatusState -State ([PSCustomObject]@{runType='manual-update';status='ActionRequired'})
    $partialInstallState = Get-OverviewStatusState -State ([PSCustomObject]@{runType='manual-update';status='CompletedWithIssues'})
    $refreshedUpdateState = Get-OverviewStatusState -State ([PSCustomObject]@{runType='manual-check';status='UpdatesAvailable'}) -UpdateCount 4
    Assert-True ($freshState.State -eq 'NotChecked') 'fresh state resolves to Not checked yet'
    Assert-True ($checkingState.State -eq 'Checking') 'an active check takes precedence over the previous confirmed result'
    Assert-True ($zeroUpdateState.State -eq 'UpToDate') 'a completed zero-update check resolves to Up to date'
    Assert-True ($oneUpdateState.State -eq 'UpdatesAvailable' -and $oneUpdateState.UpdateCount -eq 1) 'a completed one-update check retains its confirmed count'
    Assert-True ($multipleUpdateState.State -eq 'UpdatesAvailable' -and $multipleUpdateState.UpdateCount -eq 4) 'a completed multi-update check retains its confirmed count'
    Assert-True ($compatibleSuccessState.State -eq 'UpdatesAvailable' -and $compatibleSuccessState.UpdateCount -eq 3) 'a successful compatible check state with a positive count cannot become Up to date'
    Assert-True ($installingState.State -eq 'Installing') 'an active installation takes precedence over the previous confirmed result'
    Assert-True ($installedState.State -eq 'UpToDate') 'a successful completed installation resolves to Up to date'
    Assert-True ($remainingUpdateState.State -eq 'UpdatesAvailable' -and $remainingUpdateState.UpdateCount -eq 2) 'a confirmed post-install remaining count resolves to Updates available'
    Assert-True ($failedCheckState.State -eq 'CheckFailed') 'a failed check resolves to Check failed'
    Assert-True ($incompleteScheduledState.State -eq 'CheckFailed') 'an incomplete background parse resolves to Check failed instead of Up to date or Installation failed'
    Assert-True ($failedInstallState.State -eq 'InstallationFailed') 'a failed installation resolves to Installation failed'
    Assert-True ($partialInstallState.State -eq 'CompletedWithIssues') 'a partial package queue resolves to Completed with issues'
    Assert-True ($refreshedUpdateState.State -eq $multipleUpdateState.State -and $refreshedUpdateState.UpdateCount -eq $multipleUpdateState.UpdateCount) 'a timer refresh preserves the latest confirmed Updates available state'

    $engineText = Get-Content -LiteralPath $enginePath -Raw -Encoding UTF8
    $controllerText = Get-Content -LiteralPath $controllerPath -Raw -Encoding UTF8
    $taskText = Get-Content -LiteralPath $taskManagerPath -Raw -Encoding UTF8
    $installText = Get-Content -LiteralPath $installPath -Raw -Encoding UTF8
    $commonText = Get-Content -LiteralPath $commonPath -Raw -Encoding UTF8
    $launcherText = Get-Content -LiteralPath $launcherPath -Raw -Encoding UTF8
    $runAppText = Get-Content -LiteralPath $runAppPath -Raw -Encoding UTF8
    Assert-True ($engineText -match '\.UseShellExecute\s*=\s*\$false' -and $engineText -match '\.CreateNoWindow\s*=\s*\$true') 'Winget process disables shell execution and console creation'
    Assert-True ($engineText -match '\.RedirectStandardOutput\s*=\s*\$true' -and $engineText -match '\.RedirectStandardError\s*=\s*\$true') 'Winget process redirects both output streams'
    Assert-True ($engineText -match 'OutputCallback' -and $engineText -match 'Publish-OrbitLiveProgress' -and $engineText -match 'live-progress\.json') 'per-package output streams feed the throttled live-progress snapshot'
    Assert-True ($engineText -match 'TotalMilliseconds\s+-lt\s+200' -and $controllerText -match 'FromMilliseconds\(250\)') 'engine publication and UI polling are bounded instead of dispatching every output fragment'
    Assert-True ($taskText -match '-WindowStyle Hidden' -and $taskText -match '-MultipleInstances IgnoreNew') 'scheduled tasks are hidden and reject overlapping instances'
    Assert-True ($taskText -match 'New-ScheduledTaskAction -Execute \$scriptHost' -and $taskText -match 'OrbitUpdaterLauncher\.vbs' -and $taskText -notmatch 'New-ScheduledTaskAction -Execute \$powershellExe') 'scheduled runs use the windowless script host instead of a console-hosted PowerShell action'
    Assert-True ($installText -match '\$shortcut\.TargetPath = \$scriptHost' -and $installText -match 'OrbitUpdaterLauncher\.vbs') 'installed shortcuts use the windowless script host'
    Assert-True ($commonText -match 'SetCurrentProcessExplicitAppUserModelID' -and $controllerText -match 'Set-OrbitCurrentProcessAppIdentity') 'the hosted WPF process receives the explicit Orbit identity before its window is loaded'
    Assert-True (([regex]::Matches($installText, 'Set-OrbitShortcutAppIdentity')).Count -eq 2) 'Start menu and desktop shortcuts receive the same explicit Orbit identity'
    Assert-True ($runAppText -match 'wscript\.exe' -and $runAppText -notmatch 'powershell\.exe|pwsh\.exe|wt\.exe') 'the compatibility launcher no longer starts PowerShell directly'
    Assert-True ($launcherText -match 'shell\.Run\(command, 0, True\)' -and $launcherText -match 'OrbitUpdater\\Logs\\Crashes') 'the launcher creates no visible window and records startup failures'
    Assert-True ($taskText -match 'RepetitionInterval \(New-TimeSpan -Hours 1\)' -and $engineText -match 'Test-OrbitAutomaticRunDue') 'periodic task wakes hourly while the engine applies the saved effective interval'
    Assert-True ($taskText -match '\$requiresAdministrator = \$Action -in @\(''Install'', ''Uninstall''\)') 'task management checks elevation only for one-time privileged actions'
    Assert-True ($taskText -match '(?s)''Enable''\s*\{\s*Save-Configuration -Enabled \$true\s*\}' -and $taskText -match '(?s)''Disable''\s*\{\s*Save-Configuration -Enabled \$false\s*\}') 'legacy enable and disable task-manager actions now update only user settings'
    Assert-True ($controllerText -notmatch 'Verb\s+RunAs|Invoke-TaskManager|taskManagerPath|\[switch\]\$Elevated' -and $installText -notmatch "-Action Disable") 'normal UI settings and update paths do not launch elevated child processes or disable tasks'
    Assert-True ($controllerText -match '(?s)\$automaticUpdatesChanged=.*Save-OrbitConfiguration -Changes @\{automaticUpdatesEnabled=\$desired\}.*Set-AutomaticUpdateVisual' -and $controllerText -notmatch 'Approve the Windows prompt') 'automatic-update toggles persist locally without requesting elevation'
    Assert-True ($controllerText -notmatch 'Set-HeaderStatus\s+\(if\s*\(') 'running status syntax remains compatible with Windows PowerShell 5.1'
    Assert-True ($controllerText -match 'Get-ConfirmedUpdateCount -State \$state' -and $controllerText -notmatch 'default\s*\{\s*if \(\$script:automaticUpdatesEnabled\) \{ Set-HeaderStatus ''Up to date''') 'confirmed update counts cannot be overwritten by the old idle Up to date fallback'
    Assert-True ($controllerText -match 'xmlns:x="http://schemas\.microsoft\.com/winfx/2006/xaml" Title="Run details' -and $controllerText -match 'Get-OptionalProperty \$Entry ''finishedAt''') 'History details XAML and older optional timestamps are handled safely'
    Assert-True ($controllerText -match "Invoke-OrbitUiAction -Operation 'Overview\.IntervalSlider'" -and $controllerText -match '\$script:windowInitialized') 'the interval slider is initialization-guarded and saves through a recoverable event boundary'
    Assert-True ($controllerText -match 'Dispatcher\.Add_UnhandledException' -and $controllerText -match 'Write-OrbitCrashReport') 'the WPF controller has top-level Dispatcher and operation crash logging'
    Assert-True ($engineText -match 'Get-OrbitWingetArguments') 'Winget execution uses the shared command argument builder'
    Assert-True ($engineText -match 'foreach \(\$item in \$selectedItems\)' -and $engineText -match '-PackageId \$packageId' -and $engineText -match 'Write-PackageProcessSection') 'the update engine executes and records each selected package independently by exact ID'
    Assert-True ($engineText -match 'Get-PackageQueueClassification' -and $engineText -match "State='CompletedWithIssues'" -and $engineText -match "History='partial-success'") 'the engine has an explicit aggregate partial-success result'
    Assert-True ($installText -match 'HKCU:\\Software\\Classes\\orbitupdater' -and $installText -match 'orbit-updater\.ico' -and $installText -match '--ui') 'setup registers notification activation through the existing hidden Orbit launcher'

    [xml]$xaml = Get-Content -LiteralPath $xamlPath -Raw -Encoding UTF8
    Assert-True ($xaml.Window.Title -eq 'Orbit Updater') 'window branding is Orbit Updater'
    $xamlText = Get-Content -LiteralPath $xamlPath -Raw -Encoding UTF8
    Assert-True ($xamlText -match 'x:Name="TechnicalCommandBlock"\s+Visibility="Collapsed"' -and $xamlText -match 'x:Name="TechnicalCommandText"') 'Overview contains the compact technical command block and hides it by default'
    Assert-True ($xamlText -match 'x:Name="ActionProgressBar"' -and $xamlText -match 'x:Name="ProgressQueueText"' -and $xamlText -match 'x:Name="ProgressPercentText"') 'the existing action card exposes compact package, queue, and real-percentage progress controls'
    Assert-True ($xamlText -match 'x:Name="TechnicalActivityBlock"\s+Visibility="Collapsed"' -and $xamlText -match 'x:Name="ActivityOutputTextBox"[^>]+IsReadOnly="True"') 'Overview contains a collapsed read-only Activity section'
    Assert-True ($xamlText.IndexOf('x:Name="AvailableUpdatesTitle"') -lt $xamlText.IndexOf('x:Name="TechnicalCommandBlock"') -and $xamlText.IndexOf('x:Name="TechnicalCommandBlock"') -lt $xamlText.IndexOf('x:Name="TechnicalActivityBlock"')) 'available updates, command, and Activity appear in the required Overview order'
    Assert-True (([regex]::Matches($xamlText, 'x:Name="AvailableUpdatesTitle"')).Count -eq 1 -and ([regex]::Matches($xamlText, 'x:Name="AvailableUpdatesItems"')).Count -eq 1) 'Overview contains exactly one available-updates section'
    Assert-True ($xamlText -match 'IsChecked="\{Binding IsSelected, Mode=TwoWay, UpdateSourceTrigger=PropertyChanged\}"' -and $xamlText -match 'AutomationProperties\.AutomationId="\{Binding Id\}"') 'every available update exposes a checked-state binding tied to its stable package ID'
    Assert-True ($xamlText.IndexOf('Text="Automation"') -lt $xamlText.IndexOf('Text="Advanced"') -and $xamlText -match 'x:Name="AutomaticInstallationToggle"' -and $xamlText -match 'x:Name="StartupInstallationToggle"' -and $xamlText -match 'x:Name="NotificationsToggle"') 'user-facing installation and notification preferences are grouped in normal Settings before Advanced'
    Assert-True ($xamlText.IndexOf('x:Name="TaskbarStatusBadgeToggle"') -lt $xamlText.IndexOf('Text="Automation"') -and ([regex]::Matches($xamlText, 'x:Name="TaskbarStatusBadgeToggle"')).Count -eq 1) 'taskbar status badge preference appears once in the normal Appearance settings'
    $taskbarBadgeSupportText = 'Show the current update status on the taskbar icon.'
    Assert-True ($xamlText.Contains($taskbarBadgeSupportText)) 'taskbar status badge preference uses the required support text'
    $requiredCopy = @(
        'Manage your Winget updates in one place.',
        'Check for available Winget updates or install selected updates.',
        'View results from previous checks and installations.',
        'Select a run to view its details or log.',
        'Choose how Orbit looks.',
        'Use the Windows appearance setting.',
        'Always use light appearance.',
        'Always use dark appearance.',
        'Configure automatic updates and notifications.',
        'Install available updates automatically after scheduled checks.',
        'Check for and install available updates when Orbit starts.',
        'Show Windows notifications when updates are available.',
        'Configure optional technical information.',
        'Show Winget commands and technical activity on Overview.',
        'Configure history and log retention.',
        'Delete matching log files when history entries are removed.',
        'A Windows utility for managing Winget updates.'
    )
    Assert-True (@($requiredCopy | Where-Object { -not $xamlText.Contains($_) }).Count -eq 0) 'specified Overview, History, Settings, and About copy is present exactly'
    $requiredDynamicCopy = @(
        'Manage your Winget updates in one place.',
        'Review previous checks and update runs.',
        'Configure appearance, automation, technical details, and history.',
        'Check for available Winget updates or install selected updates.',
        'All Winget-managed applications are up to date.',
        'Select a run to view its details or log.'
    )
    Assert-True (@($requiredDynamicCopy | Where-Object { -not $controllerText.Contains($_) }).Count -eq 0) 'dynamic headers, idle state, no-update state, and History hint use the specified copy'
    Assert-True ($xamlText -notmatch 'calm|bright|Scan safely|Off by default|Windows app-mode|console noise') 'replaced marketing and inconsistent supporting copy is absent from the visible XAML'
    Assert-True (([regex]::Matches($xamlText, 'x:Name="TechnicalDetailsToggle"')).Count -eq 1) 'Advanced retains only the existing technical-details preference'
    Assert-True ($controllerText -match "Install all updates' \} else \{ 'Install selected updates" -and $controllerText -match '\$RunButton\.IsEnabled = -not \$busy -and \$selected -gt 0') 'the primary install action follows the current checkbox count'
    Assert-True ($xamlText -match 'x:Name="IntervalLabelsGrid"[^>]+Margin="0,-14,0,0"' -and $xamlText -match 'x:Name="IntervalTick1"[^>]+TextAlignment="Center"' -and $xamlText -match 'x:Name="IntervalTick24"[^>]+TextAlignment="Center"') 'interval labels use deterministic endpoint-centered placement'
    Assert-True (([regex]::Matches($xamlText, 'x:Name="IntervalHit(?:1|3|6|12|24)"[^>]+Height="28"[^>]+Background="Transparent"')).Count -eq 5 -and ([regex]::Matches($xamlText, 'x:Name="IntervalHit(?:3|6|12)"[^>]+Width="80"')).Count -eq 3) 'all five interval labels have larger transparent hit targets'
    $labelSelectionText = Get-FunctionDefinitionText -Path $controllerPath -Name 'Set-IntervalFromLabel'
    Assert-True ($labelSelectionText -match '\[Array\]::IndexOf\(\$script:intervalHitTargets, \$Sender\)' -and $labelSelectionText -match '\$IntervalSlider\.Value = \[double\]\$index' -and $labelSelectionText -notmatch 'Save-OrbitConfiguration|intervalHours\s*=') 'label clicks move the authoritative slider without a separate persistence path'
    Assert-True ($controllerText -match "Invoke-OrbitUiAction -Operation 'Overview\.IntervalLabel'" -and $controllerText -match 'Set-IntervalFromLabel -Sender \$sender') 'all interval-label clicks use one guarded event path'
    Assert-True ($controllerText -match '\$ticks\[\$index\]\.FontWeight=''SemiBold''' -and $controllerText -match '\$ticks\[\$index\]\.Foreground=\$brushConverter\.ConvertFromString\(''#0891B2''\)') 'the actual slider value controls the persistent active-label highlight'
    Assert-True ($xamlText -notmatch 'TechnicalDetailsOverviewButton|OpenTechnicalDetailsButton') 'technical details adds no navigation button to Overview or Settings'
    Assert-True ($xamlText -match 'x:Name="ActionCardTitle"' -and $xamlText -match 'x:Name="ActionCardSubtitle"' -and ([regex]::Matches($xamlText, 'x:Name="HeaderStatusPill"')).Count -eq 1) 'status UX reuses the existing badge and action card without adding status elements'
    Assert-True ($controllerText -match '\$TechnicalCommandBlock\.Visibility\s*=\s*if \(\$enabled\)' -and $controllerText -match '\$TechnicalActivityBlock\.Visibility\s*=\s*if \(\$enabled\)') 'one setting directly controls both technical sections'
    Assert-True ($controllerText -notmatch 'function\s+Show-TechnicalDetails') 'the separate diagnostics view is removed'
    Assert-True ($controllerText -match '\$script:bannerTimer\s*=\s*New-Object Windows\.Threading\.DispatcherTimer' -and $controllerText -match '\$script:bannerTimerPhase\s*=\s*''Fading''') 'one WPF DispatcherTimer controls banner waiting and fade phases'
    Assert-True ($controllerText -match 'if \(\$Kind -in @\(''Warning'', ''Error''\)\) \{ 9000 \} else \{ 4500 \}' -and $controllerText -match 'FromMilliseconds\(250\)') 'banner result, warning, and fade durations use the focused timeout values'
    Assert-True ($controllerText -match '\$BannerBorder\.Visibility = ''Collapsed''' -and $controllerText -match '\$script:bannerTimer\.Stop\(\)') 'banner cleanup collapses layout space and stops the shared timer'
    Assert-True ($controllerText -match 'Show-Banner ''Checking for available Winget updates\.\.\.''' -and $controllerText -match 'Checking -Persistent' -and $controllerText -match 'Show-Banner ''Installing selected updates\.\.\.''' -and $controllerText -match 'Installing -Persistent') 'running check and install banners remain visible until completion replaces them'
    Assert-True ($controllerText -match 'function Get-StatusSemanticPalette' -and $controllerText -match 'PillBackground=.+BannerBackground=') 'status pill and banner colors come from one semantic palette'
    $setOverviewStatusText = Get-FunctionDefinitionText -Path $controllerPath -Name 'Set-OverviewStatus'
    Assert-True ($setOverviewStatusText -match '\$script:authoritativeOverviewState\s*=\s*\$State' -and $setOverviewStatusText -match 'Update-TaskbarStatusBadge -State \$State -Color \$presentation\.Foreground') 'taskbar badge consumes the authoritative Overview state and existing semantic foreground color'
    Assert-True ($controllerText -match 'Windows\.Shell\.TaskbarItemInfo' -and $controllerText -match 'Windows\.Media\.DrawingImage' -and $controllerText -notmatch 'taskbar-badge.*\.png|taskbar-badge.*\.ico') 'taskbar badge uses a native vector overlay without a second icon asset system'
    Assert-True ($controllerText -match 'ShowInTaskbar="False"') 'owned history details do not create a duplicate taskbar entry'
    Assert-True ($controllerText -match 'Checks automatically every \$hours \$unit and at sign-in\.' -and $controllerText -notmatch 'when you sign in to Windows') 'automatic-check summaries use the concise dynamic sign-in wording'
    Invoke-Expression (Get-FunctionDefinitionText -Path $controllerPath -Name 'Get-OptionalProperty')
    Invoke-Expression (Get-FunctionDefinitionText -Path $controllerPath -Name 'Update-BackgroundStatus')
    $SidebarScheduleText = [PSCustomObject]@{ Text = '' }
    $script:automaticUpdatesEnabled = $true
    $script:configuration = [PSCustomObject]@{automaticUpdatesEnabled=$true;automaticInstallationEnabled=$false;installOnStartupEnabled=$false;notificationsEnabled=$true}
    Update-BackgroundStatus
    Assert-True ($SidebarScheduleText.Text -eq (@('Automatic checks on','Automatic installation off','Notifications on') -join [Environment]::NewLine)) 'Background Status case 1 hides startup installation when automatic installation is off'
    $script:configuration = [PSCustomObject]@{automaticUpdatesEnabled=$true;automaticInstallationEnabled=$true;installOnStartupEnabled=$false;notificationsEnabled=$true}
    Update-BackgroundStatus
    Assert-True ($SidebarScheduleText.Text -eq (@('Automatic checks on','Automatic installation on','Install on Orbit startup off','Notifications on') -join [Environment]::NewLine)) 'Background Status case 2 shows the disabled startup state when automatic installation is on'
    $script:configuration = [PSCustomObject]@{automaticUpdatesEnabled=$true;automaticInstallationEnabled=$true;installOnStartupEnabled=$true;notificationsEnabled=$false}
    Update-BackgroundStatus
    Assert-True ($SidebarScheduleText.Text -eq (@('Automatic checks on','Automatic installation on','Install on Orbit startup on','Notifications off') -join [Environment]::NewLine)) 'Background Status case 3 shows enabled startup installation and disabled notifications'
    $script:configuration = [PSCustomObject]@{automaticUpdatesEnabled=$false;automaticInstallationEnabled=$false;installOnStartupEnabled=$false;notificationsEnabled=$false}
    Update-BackgroundStatus
    Assert-True ($SidebarScheduleText.Text -eq (@('Automatic checks off','Automatic installation off','Notifications off') -join [Environment]::NewLine)) 'Background Status case 4 shows all disabled effective settings without a startup line'
    Assert-True ((Get-FunctionDefinitionText -Path $controllerPath -Name 'Update-BackgroundStatus') -notmatch 'Save-OrbitConfiguration|Get-OrbitConfiguration') 'Background Status derives from existing authoritative configuration without separate persistence'
    Assert-True ($script:OrbitAppVersion -eq '0.9.1-beta.1') 'shared app version is the live-progress 0.9.1 prerelease version'

    Write-Output "`n$passed assertions passed."
}
finally {
    Remove-Item Env:ORBIT_UPDATER_TEST_ROOT -ErrorAction SilentlyContinue
    if ($resolvedTestRoot.StartsWith($resolvedTemp, [StringComparison]::OrdinalIgnoreCase) -and (Test-Path -LiteralPath $resolvedTestRoot)) {
        Remove-Item -LiteralPath $resolvedTestRoot -Recurse -Force
    }
}
