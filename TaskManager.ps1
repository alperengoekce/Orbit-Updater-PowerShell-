[CmdletBinding()]
param(
    [ValidateSet('Install', 'Enable', 'Disable', 'Uninstall')]
    [string]$Action = 'Install',

    [ValidateSet(1, 3, 6, 12, 24)]
    [int]$IntervalHours = 6,

    [switch]$NoElevation
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$taskName = 'Winget Auto Updater'
$signInTaskName = 'Winget Auto Updater - Sign-in'
$enginePath = Join-Path $PSScriptRoot 'WingetUpdateEngine.ps1'
$launcherPath = Join-Path $PSScriptRoot 'OrbitUpdaterLauncher.vbs'
$commonPath = Join-Path $PSScriptRoot 'OrbitData.ps1'
if (-not (Test-Path -LiteralPath $commonPath)) { throw 'OrbitData.ps1 is missing.' }
. $commonPath
$dataRoot = Get-OrbitDataRoot
$powershellExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$scriptHost = Join-Path $env:SystemRoot 'System32\wscript.exe'

trap {
    [void](Write-OrbitCrashReport -Operation ("TaskManager.{0}" -f $Action) -ErrorRecord $_ -Context ([ordered]@{
        action        = $Action
        intervalHours = $IntervalHours
        taskName      = $taskName
        signInTaskName = $signInTaskName
        enginePath    = $enginePath
        launcherPath  = $launcherPath
    }))
    exit 1
}

function Test-IsAdministrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

$requiresAdministrator = $Action -in @('Install', 'Uninstall')
if ($requiresAdministrator -and -not (Test-IsAdministrator)) {
    if ($NoElevation) {
        throw 'Administrator permission is required to manage the automatic update task.'
    }

    $arguments = '-NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}" -Action {1} -IntervalHours {2} -NoElevation' -f $PSCommandPath, $Action, $IntervalHours
    $elevated = Start-Process -FilePath $powershellExe -Verb RunAs -ArgumentList $arguments -WindowStyle Hidden -Wait -PassThru
    exit $elevated.ExitCode
}

if (-not (Test-Path -LiteralPath $dataRoot)) {
    New-Item -ItemType Directory -Path $dataRoot -Force | Out-Null
}

function Save-Configuration {
    param([bool]$Enabled)
    [void](Save-OrbitConfiguration -Changes @{
        automaticUpdatesEnabled = $Enabled
        intervalHours           = $IntervalHours
    })
}

switch ($Action) {
    'Install' {
        if (-not (Test-Path -LiteralPath $enginePath)) {
            throw "The update engine was not found at $enginePath"
        }
        if (-not (Test-Path -LiteralPath $launcherPath)) {
            throw "The windowless background launcher was not found at $launcherPath"
        }

        $scheduledArguments = '"{0}" --engine -Scheduled' -f $launcherPath
        $scheduledAction = New-ScheduledTaskAction -Execute $scriptHost -Argument $scheduledArguments -WorkingDirectory $PSScriptRoot
        $signInArguments = '"{0}" --engine -SignIn' -f $launcherPath
        $signInAction = New-ScheduledTaskAction -Execute $scriptHost -Argument $signInArguments -WorkingDirectory $PSScriptRoot

        $periodicTrigger = New-ScheduledTaskTrigger `
            -Once `
            -At (Get-Date).AddMinutes(2) `
            -RepetitionInterval (New-TimeSpan -Hours 1) `
            -RepetitionDuration (New-TimeSpan -Days 3650)
        $logonTrigger = New-ScheduledTaskTrigger -AtLogOn

        $settings = New-ScheduledTaskSettingsSet `
            -AllowStartIfOnBatteries `
            -DontStopIfGoingOnBatteries `
            -StartWhenAvailable `
            -MultipleInstances IgnoreNew `
            -Hidden `
            -ExecutionTimeLimit (New-TimeSpan -Hours 4)

        $currentUser = [Security.Principal.WindowsIdentity]::GetCurrent().Name
        $principal = New-ScheduledTaskPrincipal -UserId $currentUser -LogonType Interactive -RunLevel Highest
        $task = New-ScheduledTask `
            -Action $scheduledAction `
            -Trigger $periodicTrigger `
            -Settings $settings `
            -Principal $principal `
            -Description 'Orbit Updater hourly background wake-up; the effective interval is read from user settings.'

        $signInTask = New-ScheduledTask `
            -Action $signInAction `
            -Trigger $logonTrigger `
            -Settings $settings `
            -Principal $principal `
            -Description 'Orbit Updater sign-in background update task.'

        Register-ScheduledTask -TaskName $taskName -InputObject $task -Force | Out-Null
        Register-ScheduledTask -TaskName $signInTaskName -InputObject $signInTask -Force | Out-Null
        Save-Configuration -Enabled $true
    }
    'Enable' {
        Save-Configuration -Enabled $true
    }
    'Disable' {
        Save-Configuration -Enabled $false
    }
    'Uninstall' {
        Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue
        Unregister-ScheduledTask -TaskName $signInTaskName -Confirm:$false -ErrorAction SilentlyContinue
    }
}

exit 0
