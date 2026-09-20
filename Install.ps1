[CmdletBinding()]
param()

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$productName = 'Orbit Updater'
$internalTaskName = 'Winget Auto Updater'
$signInTaskName = 'Winget Auto Updater - Sign-in'
$legacyShortcutName = 'Winget Auto Updater'
$installRoot = Join-Path $env:LOCALAPPDATA 'Programs\Winget Auto Updater'
$powershellExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'

function Test-IsAdministrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

if (-not (Test-IsAdministrator)) {
    $arguments = '-NoProfile -ExecutionPolicy Bypass -File "{0}"' -f $PSCommandPath
    Start-Process -FilePath $powershellExe -Verb RunAs -ArgumentList $arguments | Out-Null
    exit 0
}

try {
    if (-not (Get-Command 'winget.exe' -ErrorAction SilentlyContinue)) {
        throw 'winget.exe is not available. Install App Installer from Microsoft Store before setting up this app.'
    }

    $commonSource = Join-Path $PSScriptRoot 'OrbitData.ps1'
    if (-not (Test-Path -LiteralPath $commonSource)) { throw 'Required setup file is missing: OrbitData.ps1' }
    . $commonSource
    $savedConfiguration = Get-OrbitConfiguration
    $existingTask = Get-ScheduledTask -TaskName $internalTaskName -ErrorAction SilentlyContinue
    $wasAutomaticEnabled = [bool]$savedConfiguration.automaticUpdatesEnabled
    if ($null -ne $existingTask -and $existingTask.State.ToString() -eq 'Disabled') { $wasAutomaticEnabled = $false }
    $savedInterval = [int]$savedConfiguration.intervalHours

    if (-not (Test-Path -LiteralPath $installRoot)) {
        New-Item -ItemType Directory -Path $installRoot -Force | Out-Null
    }

    $filesToInstall = @(
        'WingetAutoUpdater.ps1',
        'WingetUpdateEngine.ps1',
        'TaskManager.ps1',
        'OrbitData.ps1',
        'OrbitUpdater.xaml',
        'OrbitUpdaterLauncher.vbs',
        'Uninstall.ps1',
        'README.md'
    )

    foreach ($file in $filesToInstall) {
        $source = Join-Path $PSScriptRoot $file
        if (-not (Test-Path -LiteralPath $source)) {
            throw "Required setup file is missing: $file"
        }
        Copy-Item -LiteralPath $source -Destination (Join-Path $installRoot $file) -Force
    }

    $assetSource = Join-Path $PSScriptRoot 'assets'
    $assetDestination = Join-Path $installRoot 'assets'
    if (-not (Test-Path -LiteralPath $assetSource)) { throw 'Required setup folder is missing: assets' }
    if (-not (Test-Path -LiteralPath $assetDestination)) { New-Item -ItemType Directory -Path $assetDestination -Force | Out-Null }
    Get-ChildItem -LiteralPath $assetSource -File | ForEach-Object {
        Copy-Item -LiteralPath $_.FullName -Destination (Join-Path $assetDestination $_.Name) -Force
    }

    & (Join-Path $installRoot 'TaskManager.ps1') -Action Install -IntervalHours $savedInterval -NoElevation
    if ($LASTEXITCODE -ne 0) {
        throw 'The automatic update task could not be created.'
    }
    if (-not $wasAutomaticEnabled) {
        [void](Save-OrbitConfiguration -Changes @{ automaticUpdatesEnabled = $false; intervalHours = $savedInterval })
    }

    $shell = New-Object -ComObject WScript.Shell
    $installedLauncher = Join-Path $installRoot 'OrbitUpdaterLauncher.vbs'
    $scriptHost = Join-Path $env:SystemRoot 'System32\wscript.exe'
    $shortcutArguments = '"{0}" --ui' -f $installedLauncher

    $startMenuRoot = Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs'
    $startMenuShortcut = Join-Path $startMenuRoot "$productName.lnk"
    $legacyStartMenuShortcut = Join-Path $startMenuRoot "$legacyShortcutName.lnk"
    if (Test-Path -LiteralPath $legacyStartMenuShortcut) { Remove-Item -LiteralPath $legacyStartMenuShortcut -Force }
    $shortcut = $shell.CreateShortcut($startMenuShortcut)
    $shortcut.TargetPath = $scriptHost
    $shortcut.Arguments = $shortcutArguments
    $shortcut.WorkingDirectory = $installRoot
    $shortcut.IconLocation = "$(Join-Path $installRoot 'assets\orbit-updater.ico'),0"
    $shortcut.Description = 'Keep Winget-managed applications up to date'
    $shortcut.Save()
    Set-OrbitShortcutAppIdentity -Path $startMenuShortcut

    $desktopRoot = [Environment]::GetFolderPath('Desktop')
    if (-not [string]::IsNullOrWhiteSpace($desktopRoot)) {
        $desktopShortcut = Join-Path $desktopRoot "$productName.lnk"
        $legacyDesktopShortcut = Join-Path $desktopRoot "$legacyShortcutName.lnk"
        if (Test-Path -LiteralPath $legacyDesktopShortcut) { Remove-Item -LiteralPath $legacyDesktopShortcut -Force }
        Copy-Item -LiteralPath $startMenuShortcut -Destination $desktopShortcut -Force
        Set-OrbitShortcutAppIdentity -Path $desktopShortcut
    }

    # Classic desktop toasts use a local protocol activation target. It routes
    # through the existing hidden launcher, so clicking a notification opens
    # Orbit on its default Overview without introducing a console window.
    $protocolRoot = 'HKCU:\Software\Classes\orbitupdater'
    $protocolCommandKey = Join-Path $protocolRoot 'shell\open\command'
    New-Item -Path $protocolCommandKey -Force | Out-Null
    Set-Item -Path $protocolRoot -Value 'URL:Orbit Updater Protocol'
    New-ItemProperty -Path $protocolRoot -Name 'URL Protocol' -Value '' -PropertyType String -Force | Out-Null
    New-ItemProperty -Path $protocolRoot -Name 'FriendlyTypeName' -Value $productName -PropertyType String -Force | Out-Null
    $protocolIconKey = Join-Path $protocolRoot 'DefaultIcon'
    New-Item -Path $protocolIconKey -Force | Out-Null
    Set-Item -Path $protocolIconKey -Value ('"{0}",0' -f (Join-Path $installRoot 'assets\orbit-updater.ico'))
    $protocolCommand = '"{0}" "{1}" --ui' -f $scriptHost,$installedLauncher
    Set-Item -Path $protocolCommandKey -Value $protocolCommand

    # Start the first autonomous check on a new install. Installation remains
    # opt-in and is enforced by the user configuration inside the engine.
    if ($wasAutomaticEnabled) { Start-ScheduledTask -TaskName $internalTaskName -ErrorAction SilentlyContinue }

    Add-Type -AssemblyName PresentationFramework
    [System.Windows.MessageBox]::Show(
        "$productName $($script:OrbitAppVersion) is installed.`n`nYour existing appearance, interval, and history settings were preserved where available.",
        $productName,
        [System.Windows.MessageBoxButton]::OK,
        [System.Windows.MessageBoxImage]::Information
    ) | Out-Null

    Start-Process -FilePath $startMenuShortcut | Out-Null
}
catch {
    if ($null -ne (Get-Command Write-OrbitCrashReport -ErrorAction SilentlyContinue)) {
        [void](Write-OrbitCrashReport -Operation 'Setup.Install' -ErrorRecord $_ -Context ([ordered]@{
            installRoot = $installRoot
            taskName    = $internalTaskName
            signInTaskName = $signInTaskName
        }))
    }
    Add-Type -AssemblyName PresentationFramework
    [System.Windows.MessageBox]::Show(
        $_.Exception.Message,
        "$productName setup failed",
        [System.Windows.MessageBoxButton]::OK,
        [System.Windows.MessageBoxImage]::Error
    ) | Out-Null
    exit 1
}

exit 0
