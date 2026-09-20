[CmdletBinding()]
param()

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase

$projectRoot = Split-Path -Parent $PSScriptRoot
$xamlPath = Join-Path $projectRoot 'OrbitUpdater.xaml'
$controllerPath = Join-Path $projectRoot 'WingetAutoUpdater.ps1'
$passed = 0

function Assert-True {
    param([bool]$Condition,[string]$Message)
    if (-not $Condition) { throw "Assertion failed: $Message" }
    $script:passed++
    Write-Output "PASS $Message"
}

function Get-FunctionDefinitionText {
    param([string]$Path,[string]$Name)
    $tokens = $null
    $errors = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile($Path,[ref]$tokens,[ref]$errors)
    if ($errors.Count -gt 0) { throw "Cannot parse $Path." }
    $definition = $ast.FindAll({param($node)$node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $Name},$true) | Select-Object -First 1
    if ($null -eq $definition) { throw "Function $Name was not found." }
    return $definition.Extent.Text
}

[xml]$xaml = Get-Content -LiteralPath $xamlPath -Raw -Encoding UTF8
$reader = New-Object Xml.XmlNodeReader $xaml
$window = [Windows.Markup.XamlReader]::Load($reader)
foreach ($name in @('ActionCardTitle','ActionCardSubtitle','ProgressPanel','ActionProgressBar','ProgressText','ProgressQueueText','ProgressPercentText')) {
    $control = $window.FindName($name)
    if ($null -eq $control) { throw "Required progress control is missing: $name" }
    Set-Variable -Name $name -Value $control -Scope Script
}
$script:liveProgressVisible = $false
$script:liveProgressSignature = ''

Invoke-Expression (Get-FunctionDefinitionText -Path $controllerPath -Name 'Get-OptionalProperty')
Invoke-Expression (Get-FunctionDefinitionText -Path $controllerPath -Name 'Reset-LiveInstallationProgressVisual')
Invoke-Expression (Get-FunctionDefinitionText -Path $controllerPath -Name 'Set-LiveInstallationProgressVisual')

$packageA = [PSCustomObject]@{phase='installing';packageName='Package A';currentIndex=1;totalPackages=3;percentage=68}
Assert-True (Set-LiveInstallationProgressVisual -Progress $packageA) 'a valid package progress snapshot is accepted'
Assert-True ($ActionCardTitle.Text -eq 'Installing Package A' -and $ActionCardSubtitle.Text -eq 'Winget is installing the selected update.') 'the action card uses the authoritative current package name'
Assert-True ($ProgressQueueText.Text -eq '1 of 3 updates' -and $ProgressQueueText.Visibility.ToString() -eq 'Visible') 'queue position is displayed separately from package percentage'
Assert-True (-not $ActionProgressBar.IsIndeterminate -and [int]$ActionProgressBar.Value -eq 68 -and $ProgressPercentText.Text -eq '68%') 'a real package percentage drives both the bar and matching numeric label'

$packageB = [PSCustomObject]@{phase='installing';packageName='Package B';currentIndex=2;totalPackages=3;percentage=$null}
Assert-True (Set-LiveInstallationProgressVisual -Progress $packageB) 'the next package accepts an unavailable percentage'
Assert-True ($ActionCardTitle.Text -eq 'Installing Package B' -and $ProgressQueueText.Text -eq '2 of 3 updates') 'package transition updates the name and queue position'
Assert-True ($ActionProgressBar.IsIndeterminate -and [int]$ActionProgressBar.Value -eq 0 -and $ProgressPercentText.Visibility.ToString() -eq 'Collapsed') 'package transition clears the previous percentage and uses the indeterminate fallback'

$packageC = [PSCustomObject]@{phase='installing';packageName='Package C';currentIndex=3;totalPackages=3;percentage=$null}
Assert-True (Set-LiveInstallationProgressVisual -Progress $packageC) 'a third package follows the same authoritative progress path'
Assert-True ($ProgressQueueText.Text -eq '3 of 3 updates' -and $ActionProgressBar.IsIndeterminate) 'the final package retains queue progress without fabricating a percentage'

for ($percentage = 0; $percentage -le 100; $percentage++) {
    [void](Set-LiveInstallationProgressVisual -Progress ([PSCustomObject]@{phase='installing';packageName='Rapid Output Package';currentIndex=3;totalPackages=3;percentage=$percentage}))
}
Assert-True ([int]$ActionProgressBar.Value -eq 100 -and $ProgressPercentText.Text -eq '100%') 'rapid valid updates leave the newest percentage visible without a stale value'

$finalizing = [PSCustomObject]@{phase='finalizing';packageName='';currentIndex=0;totalPackages=3;percentage=$null}
Assert-True (Set-LiveInstallationProgressVisual -Progress $finalizing) 'the finalizing phase is handled explicitly'
Assert-True (-not $script:liveProgressVisible -and $ProgressPanel.Visibility.ToString() -eq 'Collapsed' -and $ProgressQueueText.Text -eq '' -and $ProgressPercentText.Text -eq '') 'finalization clears package progress and stops the progress animation'

$invalid = [PSCustomObject]@{phase='installing';packageName='';currentIndex=4;totalPackages=3;percentage=250}
Assert-True (-not (Set-LiveInstallationProgressVisual -Progress $invalid)) 'malformed package progress is rejected without changing normal UI state'

Write-Output "`n$passed live progress UI assertions passed."
