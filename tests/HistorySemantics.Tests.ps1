[CmdletBinding()]
param()
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot
$passed = 0
function Assert-Equal($Expected, $Actual, [string]$Message) {
    if ($Expected -ne $Actual) { throw "$Message (expected $Expected, received $Actual)" }
    $script:passed++
    Write-Output "PASS $Message"
}
function Import-Function([string]$File, [string]$Name) {
    $tokens=$null; $errors=$null
    $ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $projectRoot $File),[ref]$tokens,[ref]$errors)
    if ($errors.Count) { throw ($errors | Out-String) }
    $node=$ast.Find({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $Name},$true)
    if ($null -eq $node) { throw "Missing function $Name" }
    Set-Item -Path "Function:script:$Name" -Value ([scriptblock]::Create($node.Body.Extent.Text.Trim().Substring(1,$node.Body.Extent.Text.Trim().Length-2)))
}
foreach($name in @('Get-PackageQueueClassification','Get-ResultClassification','Get-IncompleteParseClassification')) {
    Import-Function 'WingetUpdateEngine.ps1' $name
}
foreach($name in @('Get-HistoryStatusText','Get-HistoryStatusColor','Get-OptionalProperty','ConvertTo-HistoryDisplayItem','Start-UpdateNow')) {
    Import-Function 'WingetAutoUpdater.ps1' $name
}
$cases=@(
    @{Selected=1;Installed=1;Failed=0;Expected='success';Label='Success'},
    @{Selected=3;Installed=2;Failed=1;Expected='partial-success';Label='Completed with issues'},
    @{Selected=2;Installed=0;Failed=2;Expected='failed';Label='Failed'},
    @{Selected=0;Installed=0;Failed=0;Expected='not-started';Label='Not started'}
)
foreach($case in $cases) {
    $result=Get-PackageQueueClassification -Selected $case.Selected -Installed $case.Installed -Failed $case.Failed -Skipped 0 -RestartRequired $false
    Assert-Equal $case.Expected $result.History "Queue $($case.Selected)/$($case.Installed)/$($case.Failed) stores the correct History status"
    Assert-Equal $case.Label (Get-HistoryStatusText $result.History) 'History list and details use the same accurate label'
}
Assert-Equal 'success' (Get-ResultClassification -Code 0 -IsCheck $true -UpdatesFound 2).History 'Successful check with updates records success'
Assert-Equal 'no-updates-found' (Get-ResultClassification -Code 0 -IsCheck $true -UpdatesFound 0).History 'True zero-update check retains successful no-update semantics'
Assert-Equal 'failed' (Get-ResultClassification -Code 17 -IsCheck $true -UpdatesFound 0).History 'Failed check records failed'
Assert-Equal 'failed' (Get-IncompleteParseClassification).History 'Incomplete parsing records failed'
foreach($hex in @('8A150005','8A15006A','8A15002C','8A15004B','8A150065')) {
    Assert-Equal 'failed' (Get-ResultClassification -Code ([Convert]::ToInt32($hex,16)) -IsCheck $true -UpdatesFound 0).History "Interrupted or unsuccessful check $hex cannot claim cancellation or installation partial success"
}
Assert-Equal 'cancelled' (Get-ResultClassification -Code ([Convert]::ToInt32('8A15010C',16)) -IsCheck $false -UpdatesFound 1).History 'Explicit installer cancellation remains representable'
Assert-Equal 'Cancelled' (Get-HistoryStatusText 'cancelled') 'Legacy and actual Cancelled status remains supported'
Assert-Equal 'Skipped' (Get-HistoryStatusText 'skipped') 'Skipped status has a concise History label'
Assert-Equal '#98A2B3' (Get-HistoryStatusColor 'not-started') 'Not started uses the existing neutral History color'

# Normal manual UI invocation returns before writing a request or starting work.
$script:engineWorker=$null; $script:waitingForScheduledRun=$false; $script:selectionRefreshes=0
function Test-OrbitEngineBusy { return $false }
function Get-SelectedAvailablePackages { return @() }
function Update-InstallSelectionState { $script:selectionRefreshes++ }
Start-UpdateNow -Mode manual
Assert-Equal 1 $script:selectionRefreshes 'Zero-selection UI path returns before starting an installation'

# Render new statuses and old entries through the real History adapter without
# changing their stored values, counts, or package results.
Add-Type -AssemblyName PresentationFramework
$brushConverter=New-Object Windows.Media.BrushConverter
function ConvertTo-OrbitDateTimeOffset($Value) { return [DateTimeOffset]::Parse([string]$Value) }
Import-Function 'WingetAutoUpdater.ps1' 'Get-RunTypeText'
foreach($status in @('success','partial-success','failed','skipped','not-started','cancelled','no-updates-found')) {
    $entry=[PSCustomObject]@{id='test';startedAt='2026-09-06T10:00:00+02:00';runType='manual-update';status=$status;updatesFound=3;updatesSelected=3;updatesInstalled=2;updatesFailed=1;updatesSkipped=0;packages=@()}
    $before=$entry|ConvertTo-Json -Depth 6
    $display=ConvertTo-HistoryDisplayItem $entry
    Assert-Equal (Get-HistoryStatusText $status) $display.StatusText "History adapter supports $status"
    Assert-Equal $before ($entry|ConvertTo-Json -Depth 6) "Rendering $status leaves legacy data unchanged"
}
$originalTestRoot=$env:ORBIT_UPDATER_TEST_ROOT
$testRoot=Join-Path ([IO.Path]::GetTempPath()) ('OrbitHistorySemantics-'+[Guid]::NewGuid().ToString('N'))
$window=$null; $timer=$null
try {
    $env:ORBIT_UPDATER_TEST_ROOT=$testRoot
    . (Join-Path $projectRoot 'OrbitData.ps1')
    $legacy=[PSCustomObject]@{id='old';startedAt='2026-01-01T10:00:00+01:00';runType='manual-update';status='cancelled';message='No updates were selected for installation.';packages=@()}
    $latest=[PSCustomObject]@{id='new';startedAt='2026-09-06T10:00:00+02:00';runType='manual-update';status='partial-success';message='2 of 3 selected updates were installed.';logFile='history-test.log';packages=@([PSCustomObject]@{applicationName='Example';oldVersion='1';newVersion='2';result='failed';message='Installer failed.'})}
    Add-OrbitHistoryEntry $latest
    Add-OrbitHistoryEntry $legacy
    $loaded=@(Get-OrbitHistory)
    Assert-Equal 'new,old' (($loaded | ForEach-Object {$_.id}) -join ',') 'History loads and sorts newest first after adding an older entry'
    Assert-Equal 'cancelled' $loaded[1].status 'Saving new entries does not migrate legacy cancelled records'
    $historyBefore=[IO.File]::ReadAllText((Get-OrbitHistoryPath))
    $logRoot=Get-OrbitLogRoot
    [void](New-Item -ItemType Directory -Path $logRoot -Force)
    [void](New-Item -ItemType File -Path (Join-Path $logRoot 'history-test.log'))
    Import-Function 'WingetAutoUpdater.ps1' 'Open-HistoryLog'
    Import-Function 'WingetAutoUpdater.ps1' 'Show-HistoryDetails'
    # Intercept only the external editor launch; exercise the real button handler
    # and log resolver without opening an unrelated user's editor.
    function Start-Process([string]$FilePath) { $script:openedLog=$FilePath }
    $script:effectiveTheme='Light'
    $iconPath=Join-Path $projectRoot 'assets\orbit.ico'
    $window=New-Object Windows.Window
    $window.ShowInTaskbar=$false; $window.Width=1; $window.Height=1; $window.Opacity=0
    $window.Show()
    $script:dialogSummary='';$script:dialogPackages='';$script:openedLog='';$script:dialogError=''
    $timer=New-Object Windows.Threading.DispatcherTimer
    $timer.Interval=[TimeSpan]::FromMilliseconds(100)
    $timer.Add_Tick({
        if($window.OwnedWindows.Count -eq 0){return}
        $timer.Stop()
        $details=$window.OwnedWindows[0]
        try {
            $script:dialogSummary=$details.FindName('Summary').Text
            $script:dialogPackages=$details.FindName('Packages').Text
            $details.FindName('OpenLog').RaiseEvent((New-Object Windows.RoutedEventArgs([Windows.Controls.Button]::ClickEvent)))
        } catch { $script:dialogError=$_.Exception.Message }
        finally { $details.Close() }
    })
    $timer.Start()
    Show-HistoryDetails $latest
    Assert-Equal '' $script:dialogError 'History details and Open log button execute without error'
    Assert-Equal $true ($script:dialogSummary -match 'Completed with issues') 'Real History details dialog displays the corrected partial-success label'
    Assert-Equal $true ($script:dialogPackages -match 'Result: Failed') 'History details retain the package-level result'
    Assert-Equal (Join-Path $logRoot 'history-test.log') $script:openedLog 'Open log resolves the entry-specific technical log'
    Assert-Equal $historyBefore ([IO.File]::ReadAllText((Get-OrbitHistoryPath))) 'Opening History details does not change stored History'
} finally {
    if($null -ne $timer){$timer.Stop()}
    if($null -ne $window){$window.Close()}
    $env:ORBIT_UPDATER_TEST_ROOT=$originalTestRoot
    $tempPrefix=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')+'\'
    if([IO.Path]::GetFullPath($testRoot).StartsWith($tempPrefix,[StringComparison]::OrdinalIgnoreCase) -and (Test-Path -LiteralPath $testRoot)) {
        Remove-Item -LiteralPath $testRoot -Recurse -Force
    }
}
Write-Output "$passed History semantics assertions passed."
