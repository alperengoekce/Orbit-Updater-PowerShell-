[CmdletBinding()]
param()

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase

$projectRoot = Split-Path -Parent $PSScriptRoot
$controllerPath = Join-Path $projectRoot 'WingetAutoUpdater.ps1'
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
    if ($errors.Count -gt 0) { throw "Cannot parse $Path." }
    $definition = $ast.FindAll({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $Name }, $true) | Select-Object -First 1
    if ($null -eq $definition) { throw "Function $Name was not found." }
    return $definition.Extent.Text
}

function Pump-Dispatcher {
    param([int]$Milliseconds)
    $frame = New-Object Windows.Threading.DispatcherFrame
    $stopTimer = New-Object Windows.Threading.DispatcherTimer
    $stopTimer.Interval = [TimeSpan]::FromMilliseconds($Milliseconds)
    $stopTimer.Add_Tick({ $stopTimer.Stop(); $frame.Continue = $false })
    $stopTimer.Start()
    [Windows.Threading.Dispatcher]::PushFrame($frame)
}

$brushConverter = New-Object Windows.Media.BrushConverter
$BannerBorder = New-Object Windows.Controls.Border
$BannerText = New-Object Windows.Controls.TextBlock
$BannerBorder.Child = $BannerText
$script:effectiveTheme = 'Light'
$script:bannerKind = 'Info'
$script:bannerTimerPhase = 'Idle'
$script:isShuttingDown = $false

foreach ($name in @('Set-Brush','Get-StatusSemanticPalette','Resolve-BannerFamily','Set-BannerAppearance','Hide-Banner','Show-Banner','Invoke-BannerTimerTick')) {
    Invoke-Expression (Get-FunctionDefinitionText -Path $controllerPath -Name $name)
}

$script:bannerTimer = New-Object Windows.Threading.DispatcherTimer
$script:bannerTimer.Add_Tick({ Invoke-BannerTimerTick })

try {
    $checking = Get-StatusSemanticPalette Checking
    $installing = Get-StatusSemanticPalette Installing
    Assert-True ($checking.PillForeground -eq '#2563EB' -and $checking.BannerForeground -eq '#1D4ED8') 'checking pill and banner share the blue semantic family'
    Assert-True ($installing.PillForeground -eq '#4F46E5' -and $installing.BannerForeground -eq '#4F46E5') 'installing pill and banner share the indigo semantic family'
    $script:effectiveTheme = 'Dark'
    $darkSuccess = Get-StatusSemanticPalette Success
    Assert-True ($darkSuccess.PillForeground -eq '#15803D' -and $darkSuccess.BannerBackground -eq '#053321' -and $darkSuccess.BannerForeground -eq '#6CE9A6') 'dark mode keeps success pill and banner in the green semantic family'
    $script:effectiveTheme = 'Light'

    Show-Banner 'Checking now' Checking -Persistent
    Pump-Dispatcher 350
    Assert-True ($BannerBorder.Visibility -eq 'Visible' -and $BannerText.Text -eq 'Checking now' -and -not $script:bannerTimer.IsEnabled) 'a running banner remains visible without an expiry timer'

    Show-Banner 'First result' Success -TimeoutMilliseconds 400
    Pump-Dispatcher 100
    Show-Banner 'Latest result' UpdatesAvailable -TimeoutMilliseconds 120
    Assert-True ($BannerText.Text -eq 'Latest result' -and $script:bannerTimerPhase -eq 'Waiting') 'a newer banner immediately replaces the old message and resets timing'
    Pump-Dispatcher 400
    Pump-Dispatcher 800
    Assert-True ($BannerBorder.Visibility -eq 'Collapsed' -and $BannerBorder.Opacity -eq 1.0 -and -not $script:bannerTimer.IsEnabled) 'a result banner fades, collapses, and leaves the timer stopped'

    Show-Banner 'Failure' Error -TimeoutMilliseconds 350
    Pump-Dispatcher 150
    Assert-True ($BannerBorder.Visibility -eq 'Visible') 'an error banner remains visible until its configured warning/error timeout'
    Pump-Dispatcher 500
    Pump-Dispatcher 800
    Assert-True ($BannerBorder.Visibility -eq 'Collapsed') 'an error banner collapses after its timeout and fade'

    Show-Banner 'Closing' Success -TimeoutMilliseconds 100
    $script:isShuttingDown = $true
    Pump-Dispatcher 180
    Assert-True (-not $script:bannerTimer.IsEnabled) 'shutdown stops an active banner timer without a stale callback'

    Write-Output "`n$passed banner runtime assertions passed."
}
finally {
    $script:isShuttingDown = $true
    if ($null -ne $script:bannerTimer) { $script:bannerTimer.Stop() }
}
