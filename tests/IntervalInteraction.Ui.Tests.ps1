[CmdletBinding()]
param()
Set-StrictMode -Version 2.0
$ErrorActionPreference='Stop'
Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes
$projectRoot=Split-Path -Parent $PSScriptRoot
$testRoot=Join-Path ([IO.Path]::GetTempPath()) ('OrbitIntervalUi-'+[Guid]::NewGuid().ToString('N'))
$originalTestRoot=$env:ORBIT_UPDATER_TEST_ROOT
$env:ORBIT_UPDATER_TEST_ROOT=$testRoot
. (Join-Path $projectRoot 'OrbitData.ps1')
$process=$null;$passed=0
function Assert([bool]$Condition,[string]$Message){if(-not $Condition){throw "FAIL $Message"};$script:passed++;Write-Output "PASS $Message"}
function Find-Element([string]$Id){$condition=New-Object Windows.Automation.PropertyCondition([Windows.Automation.AutomationElement]::AutomationIdProperty,$Id);$root.FindFirst([Windows.Automation.TreeScope]::Descendants,$condition)}
function Launch-Orbit {
    $args='-NoProfile -NonInteractive -STA -ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}"' -f (Join-Path $projectRoot 'WingetAutoUpdater.ps1')
    $script:process=Start-Process -FilePath (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe') -ArgumentList $args -WindowStyle Hidden -PassThru
    $limit=[DateTime]::Now.AddSeconds(60)
    do {
        Start-Sleep -Milliseconds 100;$process.Refresh()
        if($process.HasExited){throw 'Orbit exited during startup'}
        if($process.MainWindowHandle -ne [IntPtr]::Zero){
            $script:root=[Windows.Automation.AutomationElement]::FromHandle($process.MainWindowHandle)
            $slider=Find-Element 'IntervalSlider'
            if($null -ne $slider -and $slider.Current.IsEnabled){
                $script:range=$slider.GetCurrentPattern([Windows.Automation.RangeValuePattern]::Pattern)
                return
            }
        }
    }while([DateTime]::Now -lt $limit)
    throw 'Slider did not become ready'
}
function Wait-Interval([int]$Hours) {
    $limit=[DateTime]::Now.AddSeconds(10)
    do {
        Start-Sleep -Milliseconds 100
        if((Get-OrbitConfiguration).intervalHours -eq $Hours){return}
    }while([DateTime]::Now -lt $limit)
    throw "Interval $Hours was not persisted"
}
function Click-Button([string]$Id){(Find-Element $Id).GetCurrentPattern([Windows.Automation.InvokePattern]::Pattern).Invoke();Start-Sleep -Milliseconds 150}
function Close-Orbit {
    [void]$process.CloseMainWindow()
    if(-not $process.WaitForExit(10000)){throw 'Normal Orbit shutdown timed out'}
    Assert ($process.ExitCode -eq 0) 'Orbit closes normally without a crash'
    $process.Dispose();$script:process=$null
}
try {
    [void](Save-OrbitConfiguration -Changes @{intervalHours=3;automaticUpdatesEnabled=$true;automaticInstallationEnabled=$false;installOnStartupEnabled=$false;theme='Light'})
    Launch-Orbit
    Assert ($range.Current.Value -eq 1) 'Application starts with persisted 3h'
    $range.SetValue(2)
    # Observe multiple actual dashboard refreshes, not just an immediate setter.
    $limit=[DateTime]::Now.AddSeconds(3)
    do {Start-Sleep -Milliseconds 40;Assert ($range.Current.Value -eq 2) 'Fast 3h to 6h survives the application refresh timer'}while([DateTime]::Now -lt $limit)
    Wait-Interval 6
    $range.SetValue(3);$range.SetValue(0);$range.SetValue(4)
    Wait-Interval 24
    Close-Orbit
    Launch-Orbit
    Assert ($range.Current.Value -eq 4) 'TEST 7 a real application reopen restores the final 24h selection'
    Click-Button 'SettingsNavButton'
    (Find-Element 'ThemeDarkRadio').GetCurrentPattern([Windows.Automation.SelectionItemPattern]::Pattern).Select()
    Start-Sleep -Milliseconds 150
    Assert ((Get-OrbitConfiguration).theme -eq 'Dark') 'Dark mode remains functional'
    (Find-Element 'ThemeLightRadio').GetCurrentPattern([Windows.Automation.SelectionItemPattern]::Pattern).Select()
    Start-Sleep -Milliseconds 150
    Assert ((Get-OrbitConfiguration).theme -eq 'Light') 'Light mode remains functional'
    Click-Button 'OverviewNavButton'
    Assert ($range.Current.Value -eq 4) 'Settings navigation and themes preserve the interval'
    $toggle=(Find-Element 'AutomaticUpdatesToggle').GetCurrentPattern([Windows.Automation.TogglePattern]::Pattern)
    $toggle.Toggle();Start-Sleep -Milliseconds 150
    Assert (-not (Find-Element 'IntervalSlider').Current.IsEnabled) 'Automatic checks off disables the slider'
    $toggle.Toggle();Start-Sleep -Milliseconds 150
    Assert ((Find-Element 'IntervalSlider').Current.IsEnabled) 'Automatic checks on re-enables the slider'
    Assert ((Find-Element 'SidebarScheduleText').Current.Name -match 'Automatic checks on') 'Background Status remains consistent'
    $range.SetValue(1)
    Close-Orbit
    Assert ((Get-OrbitConfiguration).intervalHours -eq 3) 'Closing during debounce finishes the last preference before exit'
    Launch-Orbit
    Assert ($range.Current.Value -eq 1) 'A preference flushed during closing survives reopen'
    Close-Orbit
    Write-Output "$passed application interval assertions passed."
}
finally {
    if($null -ne $process -and -not $process.HasExited){[void]$process.CloseMainWindow();[void]$process.WaitForExit(10000)}
    $env:ORBIT_UPDATER_TEST_ROOT=$originalTestRoot
    $tempPrefix=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')+'\'
    if([IO.Path]::GetFullPath($testRoot).StartsWith($tempPrefix,[StringComparison]::OrdinalIgnoreCase) -and (Test-Path -LiteralPath $testRoot)){Remove-Item -LiteralPath $testRoot -Recurse -Force}
}
