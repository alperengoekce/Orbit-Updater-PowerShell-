[CmdletBinding()]
param([switch]$NoElevation)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$productName = 'Orbit Updater'
$internalTaskName = 'Winget Auto Updater'
$signInTaskName = 'Winget Auto Updater - Sign-in'
$legacyShortcutName = 'Winget Auto Updater'
$expectedInstallRoot = Join-Path $env:LOCALAPPDATA 'Programs\Winget Auto Updater'
$dataRoot = Join-Path $env:LOCALAPPDATA 'WingetAutoUpdater'
$powershellExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'

function Test-IsAdministrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

if (-not (Test-IsAdministrator)) {
    if ($NoElevation) { throw 'Administrator permission is required to uninstall the app.' }
    $arguments = '-NoProfile -ExecutionPolicy Bypass -File "{0}" -NoElevation' -f $PSCommandPath
    $elevated = Start-Process -FilePath $powershellExe -Verb RunAs -ArgumentList $arguments -Wait -PassThru
    exit $elevated.ExitCode
}

try {
    Unregister-ScheduledTask -TaskName $internalTaskName -Confirm:$false -ErrorAction SilentlyContinue
    Unregister-ScheduledTask -TaskName $signInTaskName -Confirm:$false -ErrorAction SilentlyContinue

    $shortcutPaths = @(
        (Join-Path $env:APPDATA "Microsoft\Windows\Start Menu\Programs\$productName.lnk"),
        (Join-Path $env:APPDATA "Microsoft\Windows\Start Menu\Programs\$legacyShortcutName.lnk"),
        (Join-Path ([Environment]::GetFolderPath('Desktop')) "$productName.lnk"),
        (Join-Path ([Environment]::GetFolderPath('Desktop')) "$legacyShortcutName.lnk")
    )
    foreach ($shortcutPath in $shortcutPaths) {
        if (Test-Path -LiteralPath $shortcutPath) {
            Remove-Item -LiteralPath $shortcutPath -Force
        }
    }

    $protocolRoot = 'HKCU:\Software\Classes\orbitupdater'
    if (Test-Path -LiteralPath $protocolRoot) {
        Remove-Item -LiteralPath $protocolRoot -Recurse -Force
    }

    if (Test-Path -LiteralPath $dataRoot) {
        Remove-Item -LiteralPath $dataRoot -Recurse -Force
    }

    # This is one fixed, fully resolved per-user path; it is safe whether the
    # uninstaller was launched from the setup folder or the installed folder.
    $resolvedExpected = [IO.Path]::GetFullPath($expectedInstallRoot).TrimEnd('\')
    $expectedSuffix = [IO.Path]::Combine('Programs', 'Winget Auto Updater')
    if ($resolvedExpected.EndsWith($expectedSuffix, [StringComparison]::OrdinalIgnoreCase) -and
        (Test-Path -LiteralPath $resolvedExpected)) {
        Remove-Item -LiteralPath $expectedInstallRoot -Recurse -Force
    }

    Add-Type -AssemblyName PresentationFramework
    [System.Windows.MessageBox]::Show(
        "$productName and its update history were removed.",
        $productName,
        [System.Windows.MessageBoxButton]::OK,
        [System.Windows.MessageBoxImage]::Information
    ) | Out-Null
}
catch {
    Add-Type -AssemblyName PresentationFramework
    [System.Windows.MessageBox]::Show(
        $_.Exception.Message,
        "$productName uninstall failed",
        [System.Windows.MessageBoxButton]::OK,
        [System.Windows.MessageBoxImage]::Error
    ) | Out-Null
    exit 1
}

exit 0
