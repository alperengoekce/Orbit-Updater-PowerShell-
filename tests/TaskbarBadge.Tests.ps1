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

function Get-OrbitUiCrashContext { return [ordered]@{} }
function Write-OrbitCrashReport {
    param([string]$Operation, $ErrorRecord, $Context)
    $script:capturedBadgeFailureCount++
    return 'captured'
}

$brushConverter = New-Object Windows.Media.BrushConverter
$window = New-Object Windows.Window
$script:configuration = [PSCustomObject]@{ showTaskbarStatusBadge = $true }
$script:effectiveTheme = 'Light'
$script:taskbarBadgeImages = @{}
$script:taskbarBadgeRenderState = ''
$script:capturedBadgeFailureCount = 0

foreach ($name in @('Get-StatusSemanticPalette','Get-OverviewStatusPresentation','New-TaskbarStatusBadgeImage','Update-TaskbarStatusBadge')) {
    Invoke-Expression (Get-FunctionDefinitionText -Path $controllerPath -Name $name)
}

function Get-OverlayFill {
    $image = $window.TaskbarItemInfo.Overlay
    if ($null -eq $image) { return '' }
    return $image.Drawing.Children[1].Brush.Color.ToString()
}

function Assert-VectorRenderAtSize {
    param([Windows.Media.ImageSource]$Source, [int]$Size)
    $imageControl = New-Object Windows.Controls.Image
    $imageControl.Source = $Source
    $imageControl.Stretch = 'Uniform'
    $imageControl.Measure([Windows.Size]::new($Size, $Size))
    $imageControl.Arrange([Windows.Rect]::new(0, 0, $Size, $Size))
    $imageControl.UpdateLayout()
    $bitmap = [Windows.Media.Imaging.RenderTargetBitmap]::new($Size, $Size, 96, 96, [Windows.Media.PixelFormats]::Pbgra32)
    $bitmap.Render($imageControl)
    $pixels = New-Object byte[] ($Size * $Size * 4)
    $bitmap.CopyPixels($pixels, $Size * 4, 0)
    $centerAlpha = $pixels[((([int]($Size / 2)) * $Size + [int]($Size / 2)) * 4) + 3]
    $cornerAlpha = $pixels[3]
    Assert-True ($centerAlpha -gt 0 -and $cornerAlpha -eq 0) "vector badge stays crisp and padded at ${Size}x${Size}"
}

try {
    $expected = [ordered]@{
        Checking = '#FF2563EB'
        UpToDate = '#FF15803D'
        UpdatesAvailable = '#FFC2410C'
        Installing = '#FF4F46E5'
        CompletedWithIssues = '#FFC2410C'
        CheckFailed = '#FFDC2626'
        InstallationFailed = '#FFDC2626'
    }

    foreach ($state in $expected.Keys) {
        $presentation = Get-OverviewStatusPresentation -State $state -UpdateCount 2
        Update-TaskbarStatusBadge -State $state -Color $presentation.Foreground
        Assert-True ((Get-OverlayFill) -eq $expected[$state]) "$state badge reuses the established semantic color"
    }

    $source = $window.TaskbarItemInfo.Overlay
    foreach ($size in @(16, 20, 24, 32)) { Assert-VectorRenderAtSize -Source $source -Size $size }

    $script:configuration.showTaskbarStatusBadge = $false
    Update-TaskbarStatusBadge -State 'InstallationFailed' -Color '#DC2626'
    Assert-True ($null -eq $window.TaskbarItemInfo.Overlay) 'disabling the preference removes the overlay immediately'

    $script:configuration.showTaskbarStatusBadge = $true
    Update-TaskbarStatusBadge -State 'UpToDate' -Color '#15803D'
    Assert-True ((Get-OverlayFill) -eq '#FF15803D') 're-enabling the preference restores the current authoritative status color'

    Update-TaskbarStatusBadge -State 'NotChecked' -Color '#6B7280'
    Assert-True ($null -eq $window.TaskbarItemInfo.Overlay) 'Not checked intentionally has no taskbar badge'

    Update-TaskbarStatusBadge -State 'Checking' -Color '#2563EB'
    Update-TaskbarStatusBadge -State 'Installing' -Color '#4F46E5'
    Update-TaskbarStatusBadge -State 'InstallationFailed' -Color '#DC2626'
    Assert-True ((Get-OverlayFill) -eq '#FFDC2626') 'rapid status transitions leave only the newest overlay state'

    $script:taskbarBadgeRenderState = ''
    Update-TaskbarStatusBadge -State 'Checking' -Color 'not-a-color'
    Assert-True ($script:capturedBadgeFailureCount -eq 1 -and (Get-OverlayFill) -eq '#FFDC2626') 'overlay rendering failures are logged and leave the application state intact'

    Write-Output "`n$passed taskbar badge runtime assertions passed."
}
finally {
    if ($null -ne $window.TaskbarItemInfo) { $window.TaskbarItemInfo.Overlay = $null }
    $window.Close()
}
