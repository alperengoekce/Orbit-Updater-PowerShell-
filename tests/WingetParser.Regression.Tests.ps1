[CmdletBinding()]
param()

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$projectRoot = Split-Path -Parent $PSScriptRoot
$enginePath = Join-Path $projectRoot 'WingetUpdateEngine.ps1'
$script:passed = 0
$script:failures = New-Object System.Collections.Generic.List[string]

function Assert-True {
    param([bool]$Condition, [string]$Message)

    if ($Condition) {
        $script:passed++
        Write-Output "PASS $Message"
        return
    }

    [void]$script:failures.Add($Message)
    Write-Output "FAIL $Message"
}

function Assert-Equal {
    param($Expected, $Actual, [string]$Message)

    $matches = if ($null -eq $Expected) { $null -eq $Actual } else { $Expected -eq $Actual }
    Assert-True -Condition $matches -Message ("{0} (expected={1}; actual={2})" -f $Message, $Expected, $Actual)
}

function Get-FunctionDefinitionText {
    param([string]$Path, [string]$Name)

    $tokens = $null
    $errors = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$errors)
    if ($errors.Count -gt 0) { throw "Cannot inspect $Path because it has parser errors." }
    $definition = $ast.FindAll({
        param($node)
        $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $Name
    }, $true) | Select-Object -First 1
    if ($null -eq $definition) { return $null }
    return $definition.Extent.Text
}

function Import-TestedFunction {
    param([string]$Name, [bool]$Required = $true)

    $definition = Get-FunctionDefinitionText -Path $enginePath -Name $Name
    if ([string]::IsNullOrWhiteSpace($definition)) {
        if ($Required) { Assert-True $false "engine defines $Name" }
        return $false
    }
    $openingBrace = $definition.IndexOf('{')
    $body = $definition.Substring($openingBrace + 1, $definition.Length - $openingBrace - 2)
    Set-Item -Path ("Function:script:{0}" -f $Name) -Value ([scriptblock]::Create($body))
    return $true
}

function New-WingetRow {
    param(
        [string]$Name,
        [string]$Id,
        [string]$InstalledVersion,
        [string]$AvailableVersion,
        [string]$Source,
        [int]$NameWidth = 38,
        [int]$IdWidth = 28,
        [int]$InstalledWidth = 15,
        [int]$AvailableWidth = 15
    )

    return ('{0,-' + $NameWidth + '}{1,-' + $IdWidth + '}{2,-' + $InstalledWidth + '}{3,-' + $AvailableWidth + '}{4}') -f $Name, $Id, $InstalledVersion, $AvailableVersion, $Source
}

function New-WingetHeader {
    param(
        [string[]]$Labels = @('Name', 'ID', 'Version', 'Available', 'Source'),
        [int]$NameWidth = 38,
        [int]$IdWidth = 28,
        [int]$InstalledWidth = 15,
        [int]$AvailableWidth = 15
    )

    return ('{0,-' + $NameWidth + '}{1,-' + $IdWidth + '}{2,-' + $InstalledWidth + '}{3,-' + $AvailableWidth + '}{4}') -f $Labels[0], $Labels[1], $Labels[2], $Labels[3], $Labels[4]
}

function New-WingetFixture {
    param(
        [string[]]$Body,
        [string[]]$Labels = @('Name', 'ID', 'Version', 'Available', 'Source'),
        [int]$NameWidth = 38,
        [int]$IdWidth = 28,
        [int]$InstalledWidth = 15,
        [int]$AvailableWidth = 15
    )

    $header = New-WingetHeader -Labels $Labels -NameWidth $NameWidth -IdWidth $IdWidth -InstalledWidth $InstalledWidth -AvailableWidth $AvailableWidth
    return (@($header, ('-' * $header.Length)) + @($Body)) -join "`r`n"
}

function Get-TestParseResult {
    param([string]$Output)

    if (Get-Command Get-WingetUpgradeParseResult -ErrorAction SilentlyContinue) {
        return Get-WingetUpgradeParseResult -Output $Output
    }

    return [PSCustomObject]@{
        Items = @(Get-WingetUpgradeItems -Output $Output)
        ExpectedCount = $null
        IsConsistent = $null
        DiagnosticLines = @()
    }
}

[void](Import-TestedFunction -Name 'Get-WingetReportedUpdateCount' -Required $false)
[void](Import-TestedFunction -Name 'ConvertFrom-WingetUpgradeRow' -Required $false)
[void](Import-TestedFunction -Name 'Get-WingetUpgradeParseResult' -Required $false)
[void](Import-TestedFunction -Name 'Get-WingetUpgradeItems')
[void](Import-TestedFunction -Name 'Get-ResultClassification')
[void](Import-TestedFunction -Name 'Get-IncompleteParseClassification')

$physXOutputAfterSummary = @'
Name                                  ID           Version   Verf{U}gbar Quelle
-----------------------------------------------------------------------------

1 Aktualisierungen verf{U}gbar.
NVIDIA PhysX-Systemsoftware 9.23.1019 Nvidia.PhysX 9.23.1019 9.26.0703 winget
'@ -replace '\{U\}', ([string][char]0x00FC)

# TEST A - exact real-world order: header, separator, blank, summary, PhysX row.
$testA = Get-TestParseResult -Output $physXOutputAfterSummary
Assert-Equal 1 @($testA.Items).Count 'TEST A exact real-world output yields one package'
if (@($testA.Items).Count -eq 1) {
    Assert-Equal 'NVIDIA PhysX-Systemsoftware' $testA.Items[0].Name 'TEST A normalizes the confirmed PhysX display name'
    Assert-Equal 'Nvidia.PhysX' $testA.Items[0].Id 'TEST A preserves the PhysX package ID'
    Assert-Equal '9.23.1019' $testA.Items[0].InstalledVersion 'TEST A preserves the installed version'
    Assert-Equal '9.26.0703' $testA.Items[0].AvailableVersion 'TEST A preserves the available version'
    Assert-Equal 'winget' $testA.Items[0].Source 'TEST A preserves the package source'
}

# TEST B - normal order: the same confirmed PhysX row precedes the summary.
$physXOutputBeforeSummary = @'
Name                                  ID           Version   Verf{U}gbar Quelle
-----------------------------------------------------------------------------
NVIDIA PhysX-Systemsoftware 9.23.1019 Nvidia.PhysX 9.23.1019 9.26.0703 winget
1 Aktualisierungen verf{U}gbar.
'@ -replace '\{U\}', ([string][char]0x00FC)
$testB = Get-TestParseResult -Output $physXOutputBeforeSummary
Assert-Equal 1 @($testB.Items).Count 'TEST B normal row-before-summary order yields one package'
if (@($testB.Items).Count -eq 1) {
    Assert-Equal 'Nvidia.PhysX' $testB.Items[0].Id 'TEST B retains the confirmed package after normal ordering'
}

$rowA = New-WingetRow -Name 'Alpha Editor' -Id 'Vendor.Alpha' -InstalledVersion '1.2.3' -AvailableVersion '2.0.0' -Source 'winget'
$rowB = New-WingetRow -Name 'Beta Store Tool' -Id '9NBLGGH4BETA' -InstalledVersion '151.0.4129.101' -AvailableVersion '151.0.4129.107' -Source 'msstore'
$rowC = New-WingetRow -Name 'Gamma Runtime' -Id 'Vendor.Gamma' -InstalledVersion 'Unknown' -AvailableVersion '2026.1-preview' -Source 'winget'

# TEST C - three rows after the summary.
$testC = Get-TestParseResult -Output (New-WingetFixture -Body @('3 updates available.', $rowA, $rowB, $rowC))
Assert-Equal 3 @($testC.Items).Count 'TEST C retains three package rows after a summary'

# TEST D - three rows before the summary.
$testD = Get-TestParseResult -Output (New-WingetFixture -Body @($rowA, $rowB, $rowC, '3 updates available.'))
Assert-Equal 3 @($testD.Items).Count 'TEST D retains three package rows before a summary'

# TEST E - summary in the middle of otherwise valid package rows.
$testE = Get-TestParseResult -Output (New-WingetFixture -Body @($rowA, '3 updates available.', $rowB, $rowC))
Assert-Equal 3 @($testE.Items).Count 'TEST E treats a middle summary as metadata instead of an end marker'

# TEST F - a real zero-result shape remains a successful zero-package parse.
$zeroFixture = "No applicable update found.`r`n"
$testF = Get-TestParseResult -Output $zeroFixture
Assert-Equal 0 @($testF.Items).Count 'TEST F true zero result contains no parsed packages'
if ($null -ne $testF.IsConsistent) {
    Assert-True ([bool]$testF.IsConsistent) 'TEST F true zero result has no parser consistency warning'
}
$zeroClassification = Get-ResultClassification -Code 0 -IsCheck $true -UpdatesFound @($testF.Items).Count
Assert-Equal 'NoUpdates' $zeroClassification.State 'TEST F true zero result maps to the successful Up to date state'

# TEST G - a high-confidence reported count must expose a deliberate incomplete parse.
$invalidRow = 'This row deliberately cannot provide five package fields'
$testG = Get-TestParseResult -Output (New-WingetFixture -Body @('3 updates available.', $rowA, $invalidRow, $rowB))
Assert-Equal 2 @($testG.Items).Count 'TEST G fixture deliberately yields only two valid package objects'
Assert-Equal 3 $testG.ExpectedCount 'TEST G reads the independently reported update count'
Assert-True ($testG.IsConsistent -eq $false) 'TEST G flags a reported-three/parsed-two result as incomplete'
$testGDiagnostics = @($testG.DiagnosticLines) -join "`n"
Assert-True ($testGDiagnostics -match 'Winget reported updates:\s*3') 'TEST G diagnostics record the reported count'
Assert-True ($testGDiagnostics -match 'Orbit parsed packages:\s*2') 'TEST G diagnostics record the parsed count'
Assert-True ($testGDiagnostics -match 'Parser consistency check:\s*FAILED') 'TEST G diagnostics record the failed consistency check'
$engineText = Get-Content -LiteralPath $enginePath -Raw
Assert-True ($engineText -match 'incomplete-parse') 'TEST G engine defines an incomplete-parse failure category'
Assert-True ($engineText -match 'Winget found updates, but Orbit could not read all package details\.') 'TEST G uses the concise normal-user incomplete-check message'
$testGClassification = Get-IncompleteParseClassification
Assert-Equal 'LastCheckFailed' $testGClassification.State 'TEST G maps incomplete package data to a failed check state'
Assert-Equal 'failed' $testGClassification.History 'TEST G records incomplete package data as failed history'
Assert-Equal 'incomplete-parse' $testGClassification.Category 'TEST G preserves the incomplete-parse diagnostic category'
$testGZero = Get-TestParseResult -Output (New-WingetFixture -Body @('1 update available.', $invalidRow))
Assert-Equal 0 @($testGZero.Items).Count 'TEST G one-reported/zero-parsed fixture remains an empty authoritative collection'
Assert-True ($testGZero.IsConsistent -eq $false) 'TEST G one-reported/zero-parsed fixture cannot become a successful zero-update result'
$unusableHeaderFixture = "Nom de l application ID Version Nouvelle Origine`r`n------------------------------------------------------------`r`n"
$unusableHeaderResult = Get-TestParseResult -Output $unusableHeaderFixture
Assert-True ($unusableHeaderResult.IsConsistent -eq $false) 'TEST G an unresolvable package table cannot silently become a successful zero-update result'

# TEST H - localized human-readable labels do not control structural row extraction.
$localizedLabels = @('Nom', 'Identifiant', 'Installee', 'Nouvelle', 'Origine')
$testH = Get-TestParseResult -Output (New-WingetFixture -Labels $localizedLabels -Body @('3 mises a jour disponibles.', $rowA, $rowB, $rowC))
Assert-Equal 3 @($testH.Items).Count 'TEST H structurally parses rows under localized headings and summary wording'
if (@($testH.Items).Count -eq 3) {
    Assert-Equal 'Vendor.Alpha' $testH.Items[0].Id 'TEST H retains package identity independently of heading language'
}

# TEST I - source values remain authoritative in mixed-source output.
$testI = Get-TestParseResult -Output (New-WingetFixture -Body @($rowA, $rowB, '2 updates available.'))
Assert-Equal 2 @($testI.Items).Count 'TEST I retains both mixed-source packages'
if (@($testI.Items).Count -eq 2) {
    Assert-Equal 'winget' $testI.Items[0].Source 'TEST I preserves the winget source'
    Assert-Equal 'msstore' $testI.Items[1].Source 'TEST I preserves the msstore source'
}

# TEST J - long names, punctuation, numbers, parentheses, and Unicode remain intact.
$complexName = 'Orbit Caf{E} 2026 (x64) - Pro.Edition {O}{R}{B}{I}{T} Utilities'
$complexName = $complexName.Replace('{E}', [string][char]0x00E9)
$complexName = $complexName.Replace('{O}', [string][char]0x8F68)
$complexName = $complexName.Replace('{R}', [string][char]0x9053)
$complexName = $complexName.Replace('{B}', [string][char]0x66F4)
$complexName = $complexName.Replace('{I}', [string][char]0x65B0)
$complexName = $complexName.Replace('{T}', [string][char]0x5DE5)
$complexRow = New-WingetRow -Name $complexName -Id 'Example.Complex-App_2026' -InstalledVersion 'Unknown' -AvailableVersion '2026.1-rc.2+build.7' -Source 'winget' -NameWidth 64 -IdWidth 30 -AvailableWidth 24
$testJ = Get-TestParseResult -Output (New-WingetFixture -Body @($complexRow, '1 update available.') -NameWidth 64 -IdWidth 30 -AvailableWidth 24)
Assert-Equal 1 @($testJ.Items).Count 'TEST J parses one long/complex-name package'
if (@($testJ.Items).Count -eq 1) {
    Assert-Equal $complexName $testJ.Items[0].Name 'TEST J preserves the complete display name'
    Assert-Equal 'Example.Complex-App_2026' $testJ.Items[0].Id 'TEST J preserves punctuation and numbers in the package ID'
    Assert-Equal 'Unknown' $testJ.Items[0].InstalledVersion 'TEST J preserves the Unknown installed version'
    Assert-Equal '2026.1-rc.2+build.7' $testJ.Items[0].AvailableVersion 'TEST J accepts a non-numeric available version'
}

Write-Output ("Parser regression assertions passed: {0}; failed: {1}" -f $script:passed, $script:failures.Count)
if ($script:failures.Count -gt 0) {
    throw ("Parser regression failures ({0}):`n- {1}" -f $script:failures.Count, ($script:failures -join "`n- "))
}
