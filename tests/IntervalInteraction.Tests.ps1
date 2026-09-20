[CmdletBinding()]
param()
Set-StrictMode -Version 2.0
$ErrorActionPreference='Stop'
Add-Type -AssemblyName PresentationFramework
$projectRoot=Split-Path -Parent $PSScriptRoot
$commonPath=Join-Path $projectRoot 'OrbitData.ps1'
$controllerPath=Join-Path $projectRoot 'WingetAutoUpdater.ps1'
$testRoot=Join-Path ([IO.Path]::GetTempPath()) ('OrbitIntervalTests-'+[Guid]::NewGuid().ToString('N'))
$originalTestRoot=$env:ORBIT_UPDATER_TEST_ROOT
$env:ORBIT_UPDATER_TEST_ROOT=$testRoot
. $commonPath
$passed=0
$tokens=$null;$errors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile($controllerPath,[ref]$tokens,[ref]$errors)
if($errors.Count){throw ($errors|Out-String)}
function Import-ControllerFunction([string]$Name) {
    $node=$ast.Find({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $Name},$true)
    if($null -eq $node){throw "Missing $Name"}
    Set-Item "Function:script:$Name" ([scriptblock]::Create($node.Body.Extent.Text.Substring(1,$node.Body.Extent.Text.Length-2)))
}
function Assert([bool]$Condition,[string]$Message) {
    if(-not $Condition){throw "FAIL $Message"}
    $script:passed++;Write-Output "PASS $Message"
}
function Pump([int]$Milliseconds) {
    $frame=New-Object Windows.Threading.DispatcherFrame
    $stop=New-Object Windows.Threading.DispatcherTimer
    $stop.Interval=[TimeSpan]::FromMilliseconds($Milliseconds)
    $stop.Add_Tick({$frame.Continue=$false;$stop.Stop()}.GetNewClosure())
    $stop.Start();[Windows.Threading.Dispatcher]::PushFrame($frame)
}
function Await-Save {
    $limit=[DateTimeOffset]::UtcNow.AddSeconds(12)
    while(($null -ne $script:intervalSaveWorker -or ($null -ne $script:pendingIntervalHours -and -not $script:intervalSaveFailed)) -and [DateTimeOffset]::UtcNow -lt $limit){Pump 30}
    if($null -ne $script:intervalSaveWorker){throw 'Save did not complete'}
}
function Get-OrbitRegisteredTask { [PSCustomObject]@{Enabled=$true} }
function Set-AutomationSettingsVisual {}
function Update-TechnicalCommandBlock {}
function Get-OrbitUiCrashContext { @{} }
$script:failureMessages=@()
function Invoke-OrbitUiAction {
    param($Operation,$FailureMessage,[scriptblock]$Action)
    try { & $Action; return $true }
    catch { $script:failureMessages+= $FailureMessage; return $false }
}
foreach($name in @('Update-IntervalVisual','Set-IntervalFromLabel','Request-IntervalSave','Start-IntervalSaveWorker','Complete-IntervalSave','Invoke-IntervalSaveTick','Refresh-TaskStatus','Set-AutomaticUpdateVisual','Update-BackgroundStatus','Get-OptionalProperty')){Import-ControllerFunction $name}
$realStartWorker=${function:Start-IntervalSaveWorker}
$script:workerStarts=0
function Start-IntervalSaveWorker {
    param([int]$Hours,[long]$Generation)
    $script:workerStarts++
    & $realStartWorker -Hours $Hours -Generation $Generation
}
[xml]$xaml=Get-Content (Join-Path $projectRoot 'OrbitUpdater.xaml') -Raw -Encoding UTF8
$window=[Windows.Markup.XamlReader]::Load((New-Object Xml.XmlNodeReader $xaml))
$window.ShowInTaskbar=$false;$window.ShowActivated=$false;$window.Left=-30000;$window.Top=-30000
foreach($name in @('IntervalSlider','IntervalTick1','IntervalTick3','IntervalTick6','IntervalTick12','IntervalTick24','AutomaticUpdatesToggle','IntervalPanel','AutoStatusTitle','AutoStatusDetail','SidebarScheduleText')){Set-Variable $name $window.FindName($name)}
$brushConverter=New-Object Windows.Media.BrushConverter
$script:intervalOptions=@(1,3,6,12,24)
$script:intervalHitTargets=@(1,3,6,12,24|ForEach-Object{$window.FindName("IntervalHit$_")})
$script:windowInitialized=$true;$script:suppressIntervalEvents=$false;$script:suppressAutoEvents=$false
$script:engineWorker=$null;$script:waitingForScheduledRun=$false;$script:isShuttingDown=$false
$script:pendingIntervalHours=$null;$script:intervalSelectionGeneration=[long]0
$script:intervalSaveWorker=$null;$script:intervalSaveFailed=$false;$script:intervalCloseRequested=$false
$script:intervalSaveDueAt=[DateTimeOffset]::MinValue
$intervalSaveTimer=New-Object Windows.Threading.DispatcherTimer
$intervalSaveTimer.Interval=[TimeSpan]::FromMilliseconds(50)
$intervalSaveTimer.Add_Tick({Invoke-IntervalSaveTick})
$valueHandler=$ast.EndBlock.Statements | Where-Object {$_.Extent.Text.StartsWith('$IntervalSlider.Add_ValueChanged(')} | Select-Object -First 1
Invoke-Expression $valueHandler.Extent.Text
$taskName='test';$signInTaskName='test-signin'
function Reset-Interval([int]$Hours) {
    Await-Save
    $script:configuration=Save-OrbitConfiguration -Changes @{intervalHours=$Hours;automaticUpdatesEnabled=$true}
    $script:pendingIntervalHours=$null;$script:intervalSaveFailed=$false
    Refresh-TaskStatus
}
function Verify-Interval([int]$Hours,[string]$Message) {
    Refresh-TaskStatus
    Assert ($script:intervalOptions[[int]$IntervalSlider.Value] -eq $Hours) "${Message}: refresh preserves latest visible selection"
    Await-Save
    Refresh-TaskStatus
    Assert ((Get-OrbitConfiguration).intervalHours -eq $Hours -and $script:intervalOptions[[int]$IntervalSlider.Value] -eq $Hours) "${Message}: final selection is persisted and retained"
    $active=@(1,3,6,12,24|Where-Object{$window.FindName("IntervalTick$_").FontWeight -eq [Windows.FontWeights]::SemiBold})
    Assert ($active.Count -eq 1 -and $active[0] -eq $Hours) "${Message}: active label matches selection"
}
try {
    $window.Show();$window.UpdateLayout()
    Reset-Interval 3
    $IntervalSlider.Value=2
    Verify-Interval 6 'TEST 1 fast 3h to 6h'
    $IntervalSlider.Value=1
    Verify-Interval 3 'TEST 2 fast 6h to 3h'
    Reset-Interval 1
    $starts=$script:workerStarts
    foreach($index in @(1,2,3,4)){$IntervalSlider.Value=$index;Refresh-TaskStatus}
    Verify-Interval 24 'TEST 3 rapid ascending selection'
    Assert ($script:workerStarts-$starts -eq 1) 'TEST 8 rapid selections create one debounced save'
    foreach($index in @(3,2,1,0)){$IntervalSlider.Value=$index;Refresh-TaskStatus}
    Verify-Interval 1 'TEST 4 rapid descending selection'
    foreach($index in @(1,2,3)){[void](Set-IntervalFromLabel $script:intervalHitTargets[$index]);Refresh-TaskStatus}
    Verify-Interval 12 'TEST 5 rapid label selections'

    Reset-Interval 1
    $track=$IntervalSlider.Template.FindName('PART_Track',$IntervalSlider)
    $thumb=$track.Thumb
    $started=New-Object Windows.Controls.Primitives.DragStartedEventArgs(0,0)
    $started.RoutedEvent=[Windows.Controls.Primitives.Thumb]::DragStartedEvent
    $thumb.RaiseEvent($started)
    foreach($delta in @(70.0,55.0,45.0,-30.0,300.0)){
        $drag=New-Object Windows.Controls.Primitives.DragDeltaEventArgs($delta,0)
        $drag.RoutedEvent=[Windows.Controls.Primitives.Thumb]::DragDeltaEvent
        $thumb.RaiseEvent($drag);$window.UpdateLayout();Refresh-TaskStatus
    }
    $finished=New-Object Windows.Controls.Primitives.DragCompletedEventArgs(440,0,$false)
    $finished.RoutedEvent=[Windows.Controls.Primitives.Thumb]::DragCompletedEvent
    $thumb.RaiseEvent($finished)
    Assert ($IntervalSlider.Value -eq 4 -and $IntervalSlider.IsSnapToTickEnabled) 'TEST 6 rapid routed thumb drag snaps to the final allowed index'
    Verify-Interval 24 'TEST 6 drag completion'

    # A genuinely in-flight old save runs behind a gate, while the dispatcher
    # continues accepting newer input. Only this worker factory is substituted.
    $script:gate=New-Object Threading.ManualResetEvent($false)
    function Start-IntervalSaveWorker {
        param([int]$Hours,[long]$Generation)
        $writer=[PowerShell]::Create()
        [void]$writer.AddScript({param($path,$hours,$gate) [void]$gate.WaitOne(5000);. $path;Save-OrbitConfiguration -Changes @{intervalHours=$hours}}).AddArgument($commonPath).AddArgument($Hours).AddArgument($script:gate)
        [PSCustomObject]@{Writer=$writer;Handle=$writer.BeginInvoke();Hours=$Hours;Generation=$Generation}
    }
    Reset-Interval 3
    $IntervalSlider.Value=2
    $script:intervalSaveDueAt=[DateTimeOffset]::MinValue;Invoke-IntervalSaveTick
    Assert ($null -ne $script:intervalSaveWorker -and -not $script:intervalSaveWorker.Handle.IsCompleted) 'TEST 9 old save is actually in flight'
    $IntervalSlider.Value=3;Refresh-TaskStatus
    [void]$script:gate.Set();Await-Save
    Verify-Interval 12 'TEST 9 older completion cannot reset newer selection'
    $script:gate.Dispose()
    Set-Item Function:Start-IntervalSaveWorker $realStartWorker

    Reset-Interval 3
    $IntervalSlider.Value=2;$oldGeneration=$script:intervalSelectionGeneration
    $IntervalSlider.Value=3
    $oldError=New-Object Management.Automation.ErrorRecord((New-Object IO.IOException('Old save failed')),'OldSave',[Management.Automation.ErrorCategory]::WriteError,$null)
    $failuresBefore=$script:failureMessages.Count
    Complete-IntervalSave -Generation $oldGeneration -Hours 6 -Failure $oldError
    Assert ($script:pendingIntervalHours -eq 12 -and -not $script:intervalSaveFailed -and $script:failureMessages.Count -eq $failuresBefore) 'TEST 9 obsolete failure cannot roll back or show an error for a newer selection'
    Verify-Interval 12 'TEST 9 obsolete failure recovery'

    # Exercise the existing atomic writer's real retries against a read-only
    # config file; current selection remains visible even after failure/refresh.
    Reset-Interval 3
    $configPath=Join-Path $testRoot 'config.json'
    $lock=[IO.File]::Open($configPath,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
    try {
        $IntervalSlider.Value=2
        Await-Save;Refresh-TaskStatus
        Assert ($script:intervalSaveFailed -and $IntervalSlider.Value -eq 2 -and $script:pendingIntervalHours -eq 6) 'TEST 10 failed latest save keeps a consistent visible selection'
        Assert ($script:failureMessages.Count -eq $failuresBefore+1 -and $script:failureMessages[-1] -match 'could not be saved') 'TEST 10 latest failure uses the existing error handling'
        Assert ((Get-OrbitConfiguration).intervalHours -eq 3) 'TEST 10 failed write leaves the previous valid configuration intact'
    } finally { $lock.Dispose() }
    [void](Set-IntervalFromLabel $script:intervalHitTargets[2])
    Verify-Interval 6 'TEST 10 selecting the same label retries successfully'

    # Simulate a fresh controller restoring from disk after successful persistence.
    $script:pendingIntervalHours=$null;$script:intervalHours=1
    $script:suppressIntervalEvents=$true;$IntervalSlider.Value=0;$script:suppressIntervalEvents=$false
    $generationBefore=$script:intervalSelectionGeneration
    Refresh-TaskStatus
    Assert ($IntervalSlider.Value -eq 2 -and $script:intervalSelectionGeneration -eq $generationBefore) 'TEST 7 startup restore reads latest persisted value without a user event'
    Set-AutomaticUpdateVisual $false
    Assert (-not $IntervalSlider.IsEnabled) 'Automatic checks off still disables interval input'
    Set-AutomaticUpdateVisual $true
    Assert ($IntervalSlider.IsEnabled -and $IntervalSlider.Value -eq 2) 'Automatic checks on retains interval selection'
    Write-Output "$passed interval interaction assertions passed."
}
finally {
    if($null -ne $script:intervalSaveWorker){Await-Save}
    $intervalSaveTimer.Stop();$window.Close()
    $env:ORBIT_UPDATER_TEST_ROOT=$originalTestRoot
    $tempPrefix=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')+'\'
    if([IO.Path]::GetFullPath($testRoot).StartsWith($tempPrefix,[StringComparison]::OrdinalIgnoreCase) -and (Test-Path -LiteralPath $testRoot)){Remove-Item -LiteralPath $testRoot -Recurse -Force}
}
