[CmdletBinding()]
param()

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName PresentationFramework

$projectRoot = Split-Path -Parent $PSScriptRoot
$xamlPath = Join-Path $projectRoot 'OrbitUpdater.xaml'
$controllerPath = Join-Path $projectRoot 'WingetAutoUpdater.ps1'
[xml]$xaml = Get-Content -LiteralPath $xamlPath -Raw -Encoding UTF8
$reader = New-Object Xml.XmlNodeReader $xaml
$window = [Windows.Markup.XamlReader]::Load($reader)
$window.WindowStartupLocation = 'Manual'
$window.Left = -30000
$window.Top = -30000
$window.ShowInTaskbar = $false
$window.ShowActivated = $false
$window.Opacity = 0.01

$slider = $window.FindName('IntervalSlider')
$labels = @(
    $window.FindName('IntervalTick1'),
    $window.FindName('IntervalTick3'),
    $window.FindName('IntervalTick6'),
    $window.FindName('IntervalTick12'),
    $window.FindName('IntervalTick24')
)
$hitTargets = @(
    $window.FindName('IntervalHit1'),
    $window.FindName('IntervalHit3'),
    $window.FindName('IntervalHit6'),
    $window.FindName('IntervalHit12'),
    $window.FindName('IntervalHit24')
)
[Windows.Controls.Panel]::SetZIndex($window.FindName('IntervalLabelsGrid'), 1)

function Test-IsWithinTarget {
    param($Element, $Target)
    $current = $Element
    while ($null -ne $current) {
        if ([object]::ReferenceEquals($current, $Target)) { return $true }
        try { $current = [Windows.Media.VisualTreeHelper]::GetParent($current) }
        catch { return $false }
    }
    return $false
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

$script:windowInitialized = $true
$script:suppressIntervalEvents = $false
$script:automaticUpdatesEnabled = $false
$script:intervalOptions = @(1,3,6,12,24)
$script:intervalHitTargets = $hitTargets
$IntervalSlider = $slider
$IntervalTick1 = $labels[0]
$IntervalTick3 = $labels[1]
$IntervalTick6 = $labels[2]
$IntervalTick12 = $labels[3]
$IntervalTick24 = $labels[4]
$AutoStatusDetail = $window.FindName('AutoStatusDetail')
$brushConverter = New-Object Windows.Media.BrushConverter
Invoke-Expression (Get-FunctionDefinitionText -Path $controllerPath -Name 'Set-IntervalFromLabel')
Invoke-Expression (Get-FunctionDefinitionText -Path $controllerPath -Name 'Update-IntervalVisual')
$slider.Add_ValueChanged({ [void](Update-IntervalVisual) })

try {
    $window.Show()
    $window.UpdateLayout()
    $window.Width = 1000
    $window.Height = 700
    $sidebarStatus = $window.FindName('SidebarScheduleText')
    $sidebarVersion = $window.FindName('SidebarVersionText')
    $settingsNavigation = $window.FindName('SettingsNavButton')
    $sidebarStatus.Text = @('Automatic checks on','Automatic installation on','Install on Orbit startup on','Notifications on') -join [Environment]::NewLine
    $window.UpdateLayout()
    $statusOrigin = $sidebarStatus.TransformToAncestor($window).Transform((New-Object Windows.Point -ArgumentList 0,0))
    $versionOrigin = $sidebarVersion.TransformToAncestor($window).Transform((New-Object Windows.Point -ArgumentList 0,0))
    $navigationOrigin = $settingsNavigation.TransformToAncestor($window).Transform((New-Object Windows.Point -ArgumentList 0,0))
    $statusBottom = $statusOrigin.Y + $sidebarStatus.ActualHeight
    $versionBottom = $versionOrigin.Y + $sidebarVersion.ActualHeight
    $navigationBottom = $navigationOrigin.Y + $settingsNavigation.ActualHeight
    if ($navigationBottom -ge $statusOrigin.Y -or $statusBottom -ge $versionOrigin.Y -or $versionBottom -gt $window.ActualHeight) {
        throw "Expanded Background Status overlaps sidebar content at the minimum window size (navigationBottom=$navigationBottom status=$($statusOrigin.Y)-$statusBottom version=$($versionOrigin.Y)-$versionBottom windowHeight=$($window.ActualHeight))."
    }
    if ([double]$sidebarStatus.FontSize -ne 11 -or [double]$sidebarVersion.FontSize -ne 10) { throw 'Sidebar text was reduced to accommodate Background Status.' }
    foreach ($scalePercent in @(100,125,150,200)) {
        $scale = [double]$scalePercent / 100
        if (($navigationBottom * $scale) -ge ($statusOrigin.Y * $scale) -or ($statusBottom * $scale) -ge ($versionOrigin.Y * $scale)) {
            throw "Expanded Background Status overlaps sidebar content at $scalePercent% scaling."
        }
    }
    Write-Output 'PASS four-line Background Status and the version footer remain visible and non-overlapping at minimum size and 100%-200% scaling.'
    [void]$slider.ApplyTemplate()
    $track = $slider.Template.FindName('PART_Track', $slider)
    if ($null -eq $track -or $null -eq $track.Thumb) { throw 'The interval slider track was not created.' }

    $baseDeltas = @()
    $hitTargetDeltas = @()
    $hitBounds = @()
    for ($index = 0; $index -lt 5; $index++) {
        $slider.Value = $index
        $window.UpdateLayout()
        $thumbPoint = $track.Thumb.TransformToAncestor($window).Transform(
            (New-Object Windows.Point -ArgumentList ([double]($track.Thumb.ActualWidth / 2)), 0)
        )
        $labelPoint = $labels[$index].TransformToAncestor($window).Transform(
            (New-Object Windows.Point -ArgumentList ([double]($labels[$index].ActualWidth / 2)), 0)
        )
        $hitOrigin = $hitTargets[$index].TransformToAncestor($window).Transform((New-Object Windows.Point -ArgumentList 0, 0))
        $hitPoint = $hitTargets[$index].TransformToAncestor($window).Transform(
            (New-Object Windows.Point -ArgumentList ([double]($hitTargets[$index].ActualWidth / 2)), 0)
        )
        $baseDeltas += [Math]::Abs($thumbPoint.X - $labelPoint.X)
        $hitTargetDeltas += [Math]::Abs($thumbPoint.X - $hitPoint.X)
        $hitArea = $hitTargets[$index].ActualWidth * $hitTargets[$index].ActualHeight
        $labelArea = $labels[$index].ActualWidth * $labels[$index].ActualHeight
        if ($hitArea -le $labelArea -or $hitTargets[$index].ActualHeight -le $labels[$index].ActualHeight) {
            throw "Interval hit target $index is not larger than its visible label."
        }
        $hitBounds += [PSCustomObject]@{ Left=$hitOrigin.X; Top=$hitOrigin.Y; Right=$hitOrigin.X+$hitTargets[$index].ActualWidth; Bottom=$hitOrigin.Y+$hitTargets[$index].ActualHeight }
        $samplePoints = @(
            (New-Object Windows.Point -ArgumentList ($hitOrigin.X+4), ($hitOrigin.Y+$hitTargets[$index].ActualHeight/2)),
            (New-Object Windows.Point -ArgumentList ($hitOrigin.X+$hitTargets[$index].ActualWidth-4), ($hitOrigin.Y+$hitTargets[$index].ActualHeight/2)),
            (New-Object Windows.Point -ArgumentList ($hitOrigin.X+$hitTargets[$index].ActualWidth/2), ($hitOrigin.Y+4)),
            (New-Object Windows.Point -ArgumentList ($hitOrigin.X+$hitTargets[$index].ActualWidth/2), ($hitOrigin.Y+$hitTargets[$index].ActualHeight-4))
        )
        foreach ($samplePoint in $samplePoints) {
            $hitElement = $window.InputHitTest($samplePoint)
            if (-not (Test-IsWithinTarget -Element $hitElement -Target $hitTargets[$index])) {
                $hitDescription = if ($null -eq $hitElement) { 'null' } else { "$($hitElement.GetType().Name):$($hitElement.Name)" }
                $ancestry = @()
                $ancestor = $hitElement
                while ($null -ne $ancestor) {
                    $ancestorName = try { [string]$ancestor.Name } catch { '' }
                    $ancestry += "$($ancestor.GetType().Name):$ancestorName"
                    try { $ancestor = [Windows.Media.VisualTreeHelper]::GetParent($ancestor) } catch { $ancestor = $null }
                }
                $intervalPanel = $window.FindName('IntervalPanel')
                $intervalPanelOrigin = $intervalPanel.TransformToAncestor($window).Transform((New-Object Windows.Point -ArgumentList 0,0))
                $labelsGrid = $window.FindName('IntervalLabelsGrid')
                $labelsGridOrigin = $labelsGrid.TransformToAncestor($window).Transform((New-Object Windows.Point -ArgumentList 0,0))
                throw "Interval hit target $index does not receive input at $($samplePoint.X),$($samplePoint.Y); target $($hitOrigin.X),$($hitOrigin.Y) $($hitTargets[$index].ActualWidth)x$($hitTargets[$index].ActualHeight); panel $($intervalPanelOrigin.X),$($intervalPanelOrigin.Y) $($intervalPanel.ActualWidth)x$($intervalPanel.ActualHeight); grid $($labelsGridOrigin.X),$($labelsGridOrigin.Y) $($labelsGrid.ActualWidth)x$($labelsGrid.ActualHeight); hit $hitDescription; tree $($ancestry -join ' > ')."
            }
        }
    }

    for ($index = 0; $index -lt 4; $index++) {
        if ($hitBounds[$index].Right -gt $hitBounds[$index + 1].Left) { throw "Adjacent interval hit targets $index and $($index + 1) overlap." }
    }

    for ($index = 0; $index -lt 5; $index++) {
        if (-not (Set-IntervalFromLabel -Sender $hitTargets[$index])) { throw "Interval label $index did not select its slider position." }
        $window.UpdateLayout()
        if ([int]$slider.Value -ne $index) { throw "Interval label $index selected slider position $([int]$slider.Value)." }
        $selectedLabels = @($labels | Where-Object { $_.FontWeight -eq [Windows.FontWeights]::SemiBold })
        if ($selectedLabels.Count -ne 1 -or -not [object]::ReferenceEquals($selectedLabels[0], $labels[$index])) {
            throw "Interval label $index did not become the sole active highlight."
        }
    }

    for ($iteration = 0; $iteration -lt 600; $iteration++) {
        $index = ($iteration * 3) % 5
        if (($iteration % 2) -eq 0) { [void](Set-IntervalFromLabel -Sender $hitTargets[$index]) }
        else { $slider.Value = [double]$index }
    }
    $expectedFinalIndex = ((599 * 3) % 5)
    if ([int]$slider.Value -ne $expectedFinalIndex) { throw 'Rapid mixed label and slider interaction did not retain the final intended value.' }
    $selectedLabels = @($labels | Where-Object { $_.FontWeight -eq [Windows.FontWeights]::SemiBold })
    if ($selectedLabels.Count -ne 1 -or -not [object]::ReferenceEquals($selectedLabels[0], $labels[$expectedFinalIndex])) {
        throw 'Rapid mixed interaction left the active highlight out of sync with the slider.'
    }
    Write-Output 'PASS every label selects the matching slider position and 600 mixed rapid changes retain one correct active highlight.'

    foreach ($scalePercent in @(100, 125, 150, 200)) {
        $scale = [double]$scalePercent / 100
        $maximumScaledDelta = ($baseDeltas | ForEach-Object { $_ * $scale } | Measure-Object -Maximum).Maximum
        if ($maximumScaledDelta -gt (0.75 * $scale)) {
            throw "Interval labels drift by $maximumScaledDelta physical pixels at $scalePercent% scaling."
        }
        $maximumScaledHitDelta = ($hitTargetDeltas | ForEach-Object { $_ * $scale } | Measure-Object -Maximum).Maximum
        if ($maximumScaledHitDelta -gt (0.75 * $scale)) { throw "Interval hit targets drift by $maximumScaledHitDelta physical pixels at $scalePercent% scaling." }
        Write-Output "PASS interval labels and hit targets remain centered at $scalePercent% scaling (maximum delta $([Math]::Round([Math]::Max($maximumScaledDelta,$maximumScaledHitDelta), 3)))."
    }
    Write-Output 'PASS interval hit targets are larger than their labels, non-overlapping, and receive input near every edge.'
}
finally {
    $window.Close()
}
