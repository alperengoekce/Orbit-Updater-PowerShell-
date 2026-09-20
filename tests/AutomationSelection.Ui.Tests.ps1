[CmdletBinding()]
param()

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes

$projectRoot = Split-Path -Parent $PSScriptRoot
$controllerPath = Join-Path $projectRoot 'WingetAutoUpdater.ps1'
$commonPath = Join-Path $projectRoot 'OrbitData.ps1'
$powershellExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('OrbitUpdaterSelectionUiTests-' + [Guid]::NewGuid().ToString('N'))
$resolvedTemp = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\'
$resolvedTestRoot = [IO.Path]::GetFullPath($testRoot)
$process = $null
$passed = 0

function Assert-True {
    param([bool]$Condition,[string]$Message)
    if(-not $Condition){throw "Assertion failed: $Message"}
    $script:passed++
    Write-Output "PASS $Message"
}

function Find-OrbitElement {
    param($Root,[string]$AutomationId)
    $condition=New-Object Windows.Automation.PropertyCondition([Windows.Automation.AutomationElement]::AutomationIdProperty,$AutomationId)
    return $Root.FindFirst([Windows.Automation.TreeScope]::Descendants,$condition)
}

function Invoke-OrbitButton {
    param($Root,[string]$AutomationId)
    $element=Find-OrbitElement $Root $AutomationId
    if($null -eq $element){throw "$AutomationId was not found."}
    $element.GetCurrentPattern([Windows.Automation.InvokePattern]::Pattern).Invoke()
    Start-Sleep -Milliseconds 350
}

function Toggle-OrbitElement {
    param($Root,[string]$AutomationId)
    $element=Find-OrbitElement $Root $AutomationId
    if($null -eq $element){throw "$AutomationId was not found."}
    $element.GetCurrentPattern([Windows.Automation.TogglePattern]::Pattern).Toggle()
    Start-Sleep -Milliseconds 180
}

function Get-BackgroundStatusLines {
    param($Root)
    $element = Find-OrbitElement $Root 'SidebarScheduleText'
    if ($null -eq $element) { throw 'SidebarScheduleText was not found.' }
    return @([regex]::Split([string]$element.Current.Name, '\r?\n') | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
}

function Assert-BackgroundStatus {
    param($Root,[string[]]$Expected,[string]$Message)
    $actual = @(Get-BackgroundStatusLines $Root)
    Assert-True (($actual -join '|') -eq ($Expected -join '|')) ("$Message (actual: {0})" -f ($actual -join ' | '))
}

try {
    if(-not $resolvedTestRoot.StartsWith($resolvedTemp,[StringComparison]::OrdinalIgnoreCase)){throw 'Refusing to use a UI test path outside the system temporary directory.'}
    New-Item -ItemType Directory -Path $resolvedTestRoot -Force|Out-Null
    $env:ORBIT_UPDATER_TEST_ROOT=$resolvedTestRoot
    . $commonPath
    [void](Save-OrbitConfiguration -Changes @{theme='Light';automaticUpdatesEnabled=$true;automaticInstallationEnabled=$false;installOnStartupEnabled=$false;notificationsEnabled=$true})
    Write-OrbitJsonFile -Path (Join-Path $resolvedTestRoot 'updates.json') -Value ([ordered]@{
        schemaVersion=1;generatedAt=[DateTimeOffset]::Now.ToString('o');status='Available';count=3;items=@(
            [ordered]@{Name='Package A';Id='Vendor.A';InstalledVersion='1.0';AvailableVersion='2.0';Source='winget'},
            [ordered]@{Name='Package B';Id='Vendor.B';InstalledVersion='1.0';AvailableVersion='2.0';Source='winget'},
            [ordered]@{Name='Package C';Id='Vendor.C';InstalledVersion='1.0';AvailableVersion='2.0';Source='winget'}
        )
    })

    $arguments='-NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -STA -File "{0}"' -f $controllerPath
    $process=Start-Process -FilePath $powershellExe -ArgumentList $arguments -WindowStyle Hidden -PassThru
    $deadline=[DateTime]::Now.AddSeconds(90)
    $handle=[IntPtr]::Zero
    while([DateTime]::Now -lt $deadline){Start-Sleep -Milliseconds 250;$process.Refresh();if($process.HasExited){throw 'Orbit exited before UI automation connected.'};if($process.MainWindowHandle -ne [IntPtr]::Zero){$handle=$process.MainWindowHandle;break}}
    if($handle -eq [IntPtr]::Zero){throw 'Orbit did not expose a window in time.'}
    $root=[Windows.Automation.AutomationElement]::FromHandle($handle)

    $uiReadyDeadline=[DateTime]::Now.AddSeconds(15)
    do{
        $runButton=Find-OrbitElement $root 'RunButton'
        $packageC=Find-OrbitElement $root 'Vendor.C'
        if($null -ne $runButton -and $null -ne $packageC -and $runButton.Current.Name -eq 'Install all updates'){break}
        Start-Sleep -Milliseconds 200
    }while([DateTime]::Now -lt $uiReadyDeadline)
    Assert-True ($null -ne $runButton -and $runButton.Current.Name -eq 'Install all updates' -and $runButton.Current.IsEnabled) 'all newly detected updates are selected and use Install all updates'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $resolvedTestRoot 'manual-update-request.json'))) 'opening Orbit with the startup-install preference off does not request an installation'
    Assert-BackgroundStatus $root @('Automatic checks on','Automatic installation off','Notifications on') 'Background Status shows enabled checks, disabled installation, and enabled notifications without a startup line'

    Toggle-OrbitElement $root 'Vendor.B'
    $runButton=Find-OrbitElement $root 'RunButton'
    Assert-True ($runButton.Current.Name -eq 'Install selected updates' -and $runButton.Current.IsEnabled) 'one unchecked update immediately changes the enabled action to Install selected updates'

    for($index=0;$index -lt 12;$index++){Toggle-OrbitElement $root 'Vendor.B'}
    $packageB=Find-OrbitElement $root 'Vendor.B'
    $runButton=Find-OrbitElement $root 'RunButton'
    Assert-True ($packageB.GetCurrentPattern([Windows.Automation.TogglePattern]::Pattern).Current.ToggleState -eq [Windows.Automation.ToggleState]::Off -and $runButton.Current.Name -eq 'Install selected updates') 'rapid checkbox changes leave the button text consistent with the final selection'

    Toggle-OrbitElement $root 'Vendor.A'
    Toggle-OrbitElement $root 'Vendor.C'
    $runButton=Find-OrbitElement $root 'RunButton'
    Assert-True ($runButton.Current.Name -eq 'Install selected updates' -and -not $runButton.Current.IsEnabled) 'zero selected updates disables Install selected updates'

    Toggle-OrbitElement $root 'Vendor.A'
    Toggle-OrbitElement $root 'Vendor.B'
    Toggle-OrbitElement $root 'Vendor.C'
    $runButton=Find-OrbitElement $root 'RunButton'
    Assert-True ($runButton.Current.Name -eq 'Install all updates' -and $runButton.Current.IsEnabled) 'reselecting all packages restores Install all updates'

    Invoke-OrbitButton $root 'SettingsNavButton'
    $automaticInstall=Find-OrbitElement $root 'AutomaticInstallationToggle'
    $startupInstall=Find-OrbitElement $root 'StartupInstallationToggle'
    $notifications=Find-OrbitElement $root 'NotificationsToggle'
    Assert-True ($null -ne $automaticInstall -and $null -ne $startupInstall -and $null -ne $notifications) 'Automation preferences are present in the normal Settings page'
    Assert-True (-not $startupInstall.Current.IsEnabled) 'startup installation is unavailable until automatic installation is enabled'
    Toggle-OrbitElement $root 'AutomaticInstallationToggle'
    $startupInstall=Find-OrbitElement $root 'StartupInstallationToggle'
    Assert-True ([bool](Get-OrbitConfiguration).automaticInstallationEnabled -and $startupInstall.Current.IsEnabled) 'automatic installation persists and enables its startup preference'
    Assert-BackgroundStatus $root @('Automatic checks on','Automatic installation on','Install on Orbit startup off','Notifications on') 'enabling automatic installation immediately adds its effective startup state'
    Toggle-OrbitElement $root 'StartupInstallationToggle'
    Toggle-OrbitElement $root 'NotificationsToggle'
    $saved=Get-OrbitConfiguration
    Assert-True ([bool]$saved.installOnStartupEnabled -and -not [bool]$saved.notificationsEnabled) 'startup installation and notification preferences persist independently'
    Assert-BackgroundStatus $root @('Automatic checks on','Automatic installation on','Install on Orbit startup on','Notifications off') 'startup installation and notification changes appear immediately in Background Status'
    Toggle-OrbitElement $root 'AutomaticInstallationToggle'
    $saved=Get-OrbitConfiguration
    Assert-True (-not [bool]$saved.automaticInstallationEnabled -and -not [bool]$saved.installOnStartupEnabled) 'disabling automatic installation safely clears startup installation'
    Assert-BackgroundStatus $root @('Automatic checks on','Automatic installation off','Notifications off') 'disabling automatic installation immediately removes the ineffective startup line'

    Invoke-OrbitButton $root 'OverviewNavButton'
    Toggle-OrbitElement $root 'AutomaticUpdatesToggle'
    Assert-BackgroundStatus $root @('Automatic checks off','Automatic installation off','Notifications off') 'disabling automatic checks updates Background Status without navigation or restart'

    Write-Output "`n$passed automation and selection UI assertions passed."
}
finally {
    if($null -ne $process -and -not $process.HasExited){[void]$process.CloseMainWindow();if(-not $process.WaitForExit(10000)){Stop-Process -Id $process.Id -Force}}
    Remove-Item Env:ORBIT_UPDATER_TEST_ROOT -ErrorAction SilentlyContinue
    if($resolvedTestRoot.StartsWith($resolvedTemp,[StringComparison]::OrdinalIgnoreCase) -and (Test-Path -LiteralPath $resolvedTestRoot)){Remove-Item -LiteralPath $resolvedTestRoot -Recurse -Force}
}
