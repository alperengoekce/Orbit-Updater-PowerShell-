[CmdletBinding()]
param()

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes

$projectRoot = Split-Path -Parent $PSScriptRoot
$controllerPath = Join-Path $projectRoot 'WingetAutoUpdater.ps1'
$commonPath = Join-Path $projectRoot 'OrbitData.ps1'
$powershellExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('OrbitUpdaterUiTests-' + [Guid]::NewGuid().ToString('N'))
$resolvedTemp = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\'
$resolvedTestRoot = [IO.Path]::GetFullPath($testRoot)
$process = $null

function Find-OrbitElement {
    param($Root, [string]$AutomationId)
    $condition = New-Object Windows.Automation.PropertyCondition(
        [Windows.Automation.AutomationElement]::AutomationIdProperty,
        $AutomationId
    )
    return $Root.FindFirst([Windows.Automation.TreeScope]::Descendants, $condition)
}

function Test-OrbitElementVisible {
    param($Root, [string]$AutomationId)
    $element = Find-OrbitElement -Root $Root -AutomationId $AutomationId
    return ($null -ne $element -and -not [bool]$element.Current.IsOffscreen)
}

function Invoke-OrbitButton {
    param($Root, [string]$AutomationId)
    $element = Find-OrbitElement -Root $Root -AutomationId $AutomationId
    if ($null -eq $element) { throw "$AutomationId was not found." }
    $pattern = $element.GetCurrentPattern([Windows.Automation.InvokePattern]::Pattern)
    $pattern.Invoke()
    Start-Sleep -Milliseconds 350
}

function Get-OrbitSettingsChildCount {
    param([int]$ParentProcessId)
    try {
        return @(Get-CimInstance Win32_Process -Filter "ParentProcessId = $ParentProcessId" -ErrorAction Stop |
            Where-Object { $_.Name -match '^(powershell|pwsh|cmd)\.exe$' }).Count
    }
    catch { return -1 }
}

try {
    if (-not $resolvedTestRoot.StartsWith($resolvedTemp, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'Refusing to use a UI test path outside the system temporary directory.'
    }
    New-Item -ItemType Directory -Path $resolvedTestRoot -Force | Out-Null
    $env:ORBIT_UPDATER_TEST_ROOT = $resolvedTestRoot
    . $commonPath
    [void](Save-OrbitConfiguration -Changes @{ theme = 'Light'; showTechnicalDetails = $false })

    $arguments = '-NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -STA -File "{0}"' -f $controllerPath
    $process = Start-Process -FilePath $powershellExe -ArgumentList $arguments -WindowStyle Hidden -PassThru
    $deadline = [DateTime]::Now.AddSeconds(90)
    $handle = [IntPtr]::Zero
    while ([DateTime]::Now -lt $deadline) {
        Start-Sleep -Milliseconds 250
        $process.Refresh()
        if ($process.HasExited) { throw 'Orbit Updater exited before the UI test could connect.' }
        if ($process.MainWindowHandle -ne [IntPtr]::Zero) { $handle = $process.MainWindowHandle; break }
    }
    if ($handle -eq [IntPtr]::Zero) { throw 'Orbit Updater did not expose a window in time.' }

    $root = [Windows.Automation.AutomationElement]::FromHandle($handle)
    if ((Test-OrbitElementVisible -Root $root -AutomationId 'TechnicalCommandText') -or
        (Test-OrbitElementVisible -Root $root -AutomationId 'ActivityOutputTextBox')) {
        throw 'Technical content is visible while the setting is disabled.'
    }
    Write-Output 'PASS both technical sections are hidden when the setting is disabled.'

    Invoke-OrbitButton -Root $root -AutomationId 'SettingsNavButton'
    $toggle = Find-OrbitElement -Root $root -AutomationId 'TechnicalDetailsToggle'
    if ($null -eq $toggle) { throw 'TechnicalDetailsToggle was not found.' }
    $togglePattern = $toggle.GetCurrentPattern([Windows.Automation.TogglePattern]::Pattern)
    $togglePattern.Toggle()
    Start-Sleep -Milliseconds 350
    if (-not [bool](Get-OrbitConfiguration).showTechnicalDetails) { throw 'The existing toggle did not persist its enabled state.' }
    Invoke-OrbitButton -Root $root -AutomationId 'OverviewNavButton'
    $commandVisible = Test-OrbitElementVisible -Root $root -AutomationId 'TechnicalCommandText'
    $activityVisible = Test-OrbitElementVisible -Root $root -AutomationId 'ActivityOutputTextBox'
    if (-not $commandVisible -or -not $activityVisible) {
        Write-Output "Diagnostic visibility: command=$commandVisible activity=$activityVisible"
        throw 'Both technical sections did not appear after enabling the setting.'
    }
    Write-Output 'PASS both technical sections appear immediately after enabling the existing toggle.'

    Invoke-OrbitButton -Root $root -AutomationId 'SettingsNavButton'
    $toggle = Find-OrbitElement -Root $root -AutomationId 'TechnicalDetailsToggle'
    $togglePattern = $toggle.GetCurrentPattern([Windows.Automation.TogglePattern]::Pattern)
    $togglePattern.Toggle()
    Start-Sleep -Milliseconds 350
    if ([bool](Get-OrbitConfiguration).showTechnicalDetails) { throw 'The existing toggle did not persist its disabled state.' }
    Invoke-OrbitButton -Root $root -AutomationId 'OverviewNavButton'
    if ((Test-OrbitElementVisible -Root $root -AutomationId 'TechnicalCommandText') -or
        (Test-OrbitElementVisible -Root $root -AutomationId 'ActivityOutputTextBox')) {
        throw 'Technical content remains visible after disabling the setting.'
    }
    Write-Output 'PASS both technical sections disappear immediately after disabling the existing toggle.'

    $initialChildCount = Get-OrbitSettingsChildCount -ParentProcessId $process.Id
    $slider = Find-OrbitElement -Root $root -AutomationId 'IntervalSlider'
    if ($null -eq $slider) { throw 'IntervalSlider was not found.' }
    $rangePattern = $slider.GetCurrentPattern([Windows.Automation.RangeValuePattern]::Pattern)
    $intervals = @(1, 3, 6, 12, 24)
    for ($index = 0; $index -lt $intervals.Count; $index++) {
        $rangePattern.SetValue([double]$index)
        Start-Sleep -Milliseconds 800
        if ([int](Get-OrbitConfiguration).intervalHours -ne $intervals[$index]) {
            throw "The interval slider did not save $($intervals[$index]) hours."
        }
    }
    Write-Output 'PASS every interval slider value saves as a user preference without task re-registration.'

    Invoke-OrbitButton -Root $root -AutomationId 'SettingsNavButton'
    foreach ($themeName in @('Dark', 'Light', 'System')) {
        $radio = Find-OrbitElement -Root $root -AutomationId ("Theme{0}Radio" -f $themeName)
        if ($null -eq $radio) { throw "The $themeName theme choice was not found." }
        $selectionPattern = $radio.GetCurrentPattern([Windows.Automation.SelectionItemPattern]::Pattern)
        $selectionPattern.Select()
        Start-Sleep -Milliseconds 200
        if ([string](Get-OrbitConfiguration).theme -ne $themeName) { throw "The $themeName theme was not saved." }
    }
    Write-Output 'PASS theme changes remain ordinary unelevated settings operations.'

    $finalChildCount = Get-OrbitSettingsChildCount -ParentProcessId $process.Id
    if ($initialChildCount -ge 0 -and $finalChildCount -ne $initialChildCount) {
        throw "Settings interactions changed the PowerShell/cmd child-process count from $initialChildCount to $finalChildCount."
    }
    Write-Output 'PASS slider and theme interactions spawn no elevated helper process.'
}
finally {
    if ($null -ne $process -and -not $process.HasExited) {
        [void]$process.CloseMainWindow()
        if (-not $process.WaitForExit(10000)) { Stop-Process -Id $process.Id -Force }
    }
    Remove-Item Env:ORBIT_UPDATER_TEST_ROOT -ErrorAction SilentlyContinue
    if ($resolvedTestRoot.StartsWith($resolvedTemp, [StringComparison]::OrdinalIgnoreCase) -and (Test-Path -LiteralPath $resolvedTestRoot)) {
        Remove-Item -LiteralPath $resolvedTestRoot -Recurse -Force
    }
}
