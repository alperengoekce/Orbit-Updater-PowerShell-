[CmdletBinding()]
param([switch]$SmokeTest)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class OrbitWindowTheme
{
    [DllImport("dwmapi.dll")]
    public static extern int DwmSetWindowAttribute(IntPtr hwnd, int attribute, ref int value, int valueSize);
}
'@

$commonPath = Join-Path $PSScriptRoot 'OrbitData.ps1'
if (-not (Test-Path -LiteralPath $commonPath)) { throw 'OrbitData.ps1 is missing.' }
. $commonPath

$productName = $script:OrbitProductName
$taskName = $script:OrbitInternalTaskName
$signInTaskName = "$taskName - Sign-in"
$enginePath = Join-Path $PSScriptRoot 'WingetUpdateEngine.ps1'
$dataRoot = Get-OrbitDataRoot
$logRoot = Get-OrbitLogRoot
$statePath = Join-Path $dataRoot 'state.json'
$updatesPath = Join-Path $dataRoot 'updates.json'
$historyPath = Get-OrbitHistoryPath
$manualRequestPath = Join-Path $dataRoot 'manual-update-request.json'
$liveProgressPath = Join-Path $dataRoot 'live-progress.json'
$launcherPath = Join-Path $PSScriptRoot 'OrbitUpdaterLauncher.vbs'
$scriptHostPath = Join-Path $env:SystemRoot 'System32\wscript.exe'
$iconPath = Join-Path $PSScriptRoot 'assets\orbit-updater.ico'
$logoPath = Join-Path $PSScriptRoot 'assets\orbit-icon-128.png'
$xamlPath = Join-Path $PSScriptRoot 'OrbitUpdater.xaml'

Set-OrbitCurrentProcessAppIdentity

if (-not (Test-Path -LiteralPath $xamlPath)) { throw 'OrbitUpdater.xaml is missing.' }
[xml]$xaml = Get-Content -LiteralPath $xamlPath -Raw -Encoding UTF8
$xmlReader = New-Object Xml.XmlNodeReader $xaml
$window = [Windows.Markup.XamlReader]::Load($xmlReader)

$controlNames = @(
    'SidebarLogo', 'AboutLogo', 'SidebarScheduleText',
    'OverviewNavButton', 'HistoryNavButton', 'SettingsNavButton',
    'HeaderTitle', 'HeaderSubtitle', 'HeaderStatusPill', 'HeaderStatusDot', 'HeaderStatusText',
    'OverviewPanel', 'HistoryPanel', 'SettingsPanel',
    'BannerBorder', 'BannerText', 'AutoStatusTitle', 'AutoStatusDetail', 'AutomaticUpdatesToggle',
    'IntervalPanel', 'IntervalSlider', 'IntervalLabelsGrid', 'IntervalHit1', 'IntervalHit3', 'IntervalHit6', 'IntervalHit12', 'IntervalHit24', 'IntervalTick1', 'IntervalTick3', 'IntervalTick6', 'IntervalTick12', 'IntervalTick24',
    'LastRunDateText', 'LastRunTimeText', 'LastResultText',
    'ActionCardTitle', 'ActionCardSubtitle', 'CheckButton', 'RunButton', 'ProgressPanel', 'ActionProgressBar', 'ProgressText', 'ProgressQueueText', 'ProgressPercentText',
    'TechnicalCommandBlock', 'TechnicalCommandLabel', 'TechnicalCommandText', 'CopyTechnicalCommandButton',
    'TechnicalActivityBlock', 'ActivityOutputTextBox', 'ActivityOpenLogButton',
    'AvailableUpdatesTitle', 'AvailableUpdatesSubtitle', 'AvailableUpdatesCount', 'AvailableUpdatesEmpty', 'AvailableUpdatesList', 'AvailableUpdatesItems',
    'ClearHistoryButton', 'HistoryEmptyText', 'HistoryList', 'HistorySelectionHint', 'HistoryDetailsButton', 'HistoryLogButton', 'DeleteHistoryButton',
    'ThemeSystemOption', 'ThemeLightOption', 'ThemeDarkOption', 'ThemeSystemRadio', 'ThemeLightRadio', 'ThemeDarkRadio',
    'AutomaticInstallationToggle', 'StartupInstallationToggle', 'StartupInstallationRow', 'NotificationsToggle',
    'TechnicalDetailsToggle', 'TaskbarStatusBadgeToggle',
    'Retention30Radio', 'Retention90Radio', 'RetentionUnlimitedRadio', 'DeleteLogsToggle', 'OpenLogFolderButton'
)
foreach ($name in $controlNames) {
    $control = $window.FindName($name)
    if ($null -eq $control) { throw "Required UI control is missing: $name" }
    Set-Variable -Name $name -Value $control -Scope Script
}
[Windows.Controls.Panel]::SetZIndex($IntervalLabelsGrid, 1)

$brushConverter = New-Object Windows.Media.BrushConverter
$script:configuration = Get-OrbitConfiguration
$script:automaticUpdatesEnabled = $false
$script:intervalHours = [int]$script:configuration.intervalHours
$script:intervalOptions = @(1, 3, 6, 12, 24)
$script:engineWorker = $null
$script:waitingForScheduledRun = $false
$script:scheduledRequestTime = $null
$script:lastUpdatesWrite = [DateTime]::MinValue
$script:lastHistoryWrite = [DateTime]::MinValue
$script:lastStateWrite = [DateTime]::MinValue
$script:themePreference = [string]$script:configuration.theme
$script:effectiveTheme = ''
$script:bannerKind = 'Info'
$script:bannerTimer = $null
$script:bannerTimerPhase = 'Idle'
$script:suppressThemeEvents = $false
$script:suppressAutoEvents = $false
$script:suppressIntervalEvents = $false
$script:suppressRetentionEvents = $false
$script:suppressSettingsEvents = $false
$script:pendingIntervalHours = $null
$script:intervalSelectionGeneration = [long]0
$script:intervalSaveDueAt = [DateTimeOffset]::MinValue
$script:intervalSaveWorker = $null
$script:intervalSaveFailed = $false
$script:intervalCloseRequested = $false
$script:selectedPage = 'Overview'
$script:taskSchedulerService = $null
$script:schedulingReady = $false
$script:technicalCommandMode = 'Update'
$script:activityLogPath = $null
$script:activityLogWriteTime = [DateTime]::MinValue
$script:activityLogLength = [long]-1
$script:currentOperation = 'Application.Startup'
$script:lastUserAction = 'Application.Startup'
$script:lastWingetExitCode = $null
$script:windowInitialized = $false
$script:isShuttingDown = $false
$script:overviewStatusOverride = ''
$script:overviewStatusOverrideStateWrite = [DateTime]::MinValue
$script:availableUpdateItems = @()
$script:suppressAutomationEvents = $false
$script:activeTechnicalCommands = @()
$script:authoritativeOverviewState = 'NotChecked'
$script:taskbarBadgeImages = @{}
$script:taskbarBadgeRenderState = ''
$script:liveProgressVisible = $false
$script:liveProgressSignature = ''
$script:lastSlowRefreshAt = [DateTimeOffset]::MinValue

function Set-Brush {
    param($Target, [string]$Property, [string]$Color)
    $Target.$Property = $brushConverter.ConvertFromString($Color)
}

function Get-OptionalProperty {
    param($Object, [string]$Name, $Default = $null)
    if ($null -eq $Object) { return $Default }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) { return $Default }
    return $property.Value
}

function Get-OrbitUiCrashContext {
    $selectedHistoryEntry = $null
    try { $selectedHistoryEntry = $HistoryList.SelectedItem.Raw } catch { }

    $workerActive = $false
    $workerId = $null
    try {
        if ($null -ne $script:engineWorker) {
            $workerActive = -not $script:engineWorker.HasExited
            $workerId = $script:engineWorker.Id
        }
    }
    catch { }

    $sliderValue = $null
    try { $sliderValue = [double]$IntervalSlider.Value } catch { }

    return [ordered]@{
        currentPage       = $script:selectedPage
        currentOperation  = $script:currentOperation
        lastUserAction    = $script:lastUserAction
        activeThread      = [Threading.Thread]::CurrentThread.ManagedThreadId
        automaticUpdatesEnabled = $script:automaticUpdatesEnabled
        configuredIntervalHours = $script:intervalHours
        sliderValue       = $sliderValue
        pendingIntervalHours = $script:pendingIntervalHours
        waitingForScheduledRun = $script:waitingForScheduledRun
        childProcessActive = $workerActive
        childProcessId    = $workerId
        lastWingetExitCode = $script:lastWingetExitCode
        selectedHistoryEntryId = [string](Get-OptionalProperty $selectedHistoryEntry 'id' '')
        selectedHistoryLogFile = [string](Get-OptionalProperty $selectedHistoryEntry 'logFile' '')
        paths = [ordered]@{
            dataRoot    = $dataRoot
            logRoot     = $logRoot
            state       = $statePath
            updates     = $updatesPath
            history     = $historyPath
            liveProgress = $liveProgressPath
            engine      = $enginePath
            launcher    = $launcherPath
        }
    }
}

function Invoke-OrbitUiAction {
    param(
        [Parameter(Mandatory = $true)][string]$Operation,
        [Parameter(Mandatory = $true)][scriptblock]$Action,
        [string]$FailureMessage = 'The action could not be completed. Orbit Updater is still open and ready to retry.',
        [switch]$Background
    )

    if (-not $Background) {
        $script:lastUserAction = $Operation
        $script:currentOperation = $Operation
    }

    try {
        & $Action
        return $true
    }
    catch {
        [void](Write-OrbitCrashReport -Operation $Operation -ErrorRecord $_ -Context (Get-OrbitUiCrashContext))
        try { Set-Activity -Active $false } catch { }
        try { Show-Banner -Message $FailureMessage -Kind Error } catch { }
        return $false
    }
}

function Get-OrbitRegisteredTask {
    param([Parameter(Mandatory = $true)][string]$Name)

    try {
        if ($null -eq $script:taskSchedulerService) {
            $script:taskSchedulerService = New-Object -ComObject 'Schedule.Service'
            $script:taskSchedulerService.Connect()
        }
        $rootFolder = $script:taskSchedulerService.GetFolder('\')
        return $rootFolder.GetTask($Name)
    }
    catch {
        $script:taskSchedulerService = $null
        return $null
    }
}

function New-OrbitBitmap {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    $bitmap = New-Object Windows.Media.Imaging.BitmapImage
    $bitmap.BeginInit()
    $bitmap.CacheOption = [Windows.Media.Imaging.BitmapCacheOption]::OnLoad
    $bitmap.UriSource = New-Object Uri($Path, [UriKind]::Absolute)
    $bitmap.EndInit()
    $bitmap.Freeze()
    return $bitmap
}

if (Test-Path -LiteralPath $iconPath) {
    try { $window.Icon = [Windows.Media.Imaging.BitmapFrame]::Create((New-Object Uri($iconPath, [UriKind]::Absolute))) } catch { }
}
$brandBitmap = New-OrbitBitmap -Path $logoPath
if ($null -ne $brandBitmap) {
    $SidebarLogo.Source = $brandBitmap
    $AboutLogo.Source = $brandBitmap
}

function Get-SystemTheme {
    try {
        $personalizePath = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize'
        if ([int](Get-ItemProperty -Path $personalizePath -Name AppsUseLightTheme -ErrorAction Stop).AppsUseLightTheme -eq 0) { return 'Dark' }
    }
    catch { }
    return 'Light'
}

function Set-TitleBarTheme {
    param([bool]$Dark)
    try {
        $helper = New-Object Windows.Interop.WindowInteropHelper($window)
        if ($helper.Handle -eq [IntPtr]::Zero) { return }
        $value = if ($Dark) { 1 } else { 0 }
        $result = [OrbitWindowTheme]::DwmSetWindowAttribute($helper.Handle, 20, [ref]$value, 4)
        if ($result -ne 0) { [void][OrbitWindowTheme]::DwmSetWindowAttribute($helper.Handle, 19, [ref]$value, 4) }
    }
    catch { }
}

function Set-EffectiveTheme {
    param([ValidateSet('Light', 'Dark')][string]$Theme)
    if ($script:effectiveTheme -eq $Theme) { return }

    if ($Theme -eq 'Dark') {
        $palette = [ordered]@{
            PageBrush='#0B1220'; SurfaceBrush='#172033'; SurfaceAltBrush='#101828'; TextBrush='#F2F4F7'; MutedBrush='#98A2B3'; SecondaryTextBrush='#D0D5DD'; LineBrush='#344054'; InputBrush='#1D2939'; HoverBrush='#1D2939'; PressedBrush='#344054';
            SidebarBrush='#101828'; SidebarElevatedBrush='#182230'; SidebarSelectedBrush='#1D2939'; SidebarTextBrush='#F2F4F7'; SidebarMutedBrush='#667085'
        }
    }
    else {
        $palette = [ordered]@{
            PageBrush='#F4F7FA'; SurfaceBrush='#FFFFFF'; SurfaceAltBrush='#F8FAFC'; TextBrush='#172033'; MutedBrush='#667085'; SecondaryTextBrush='#475467'; LineBrush='#E2E8F0'; InputBrush='#FFFFFF'; HoverBrush='#F1F5F9'; PressedBrush='#E2E8F0';
            SidebarBrush='#FFFFFF'; SidebarElevatedBrush='#F1F5F9'; SidebarSelectedBrush='#E6F3FF'; SidebarTextBrush='#172033'; SidebarMutedBrush='#667085'
        }
    }
    foreach ($entry in $palette.GetEnumerator()) { $window.Resources[$entry.Key] = $brushConverter.ConvertFromString([string]$entry.Value) }
    $script:effectiveTheme = $Theme
    Set-TitleBarTheme -Dark ($Theme -eq 'Dark')
    if ($BannerBorder.Visibility -eq 'Visible') { Set-BannerAppearance -Kind $script:bannerKind }
}

function Set-ThemePreference {
    param([ValidateSet('System', 'Light', 'Dark')][string]$Theme, [switch]$Persist)
    $script:themePreference = $Theme
    $effective = if ($Theme -eq 'System') { Get-SystemTheme } else { $Theme }
    Set-EffectiveTheme -Theme $effective
    $script:suppressThemeEvents = $true
    $ThemeSystemRadio.IsChecked = ($Theme -eq 'System')
    $ThemeLightRadio.IsChecked = ($Theme -eq 'Light')
    $ThemeDarkRadio.IsChecked = ($Theme -eq 'Dark')
    $script:suppressThemeEvents = $false
    if ($Persist) {
        $script:configuration = Save-OrbitConfiguration -Changes @{ theme = $Theme }
    }
}

function Get-StatusSemanticPalette {
    param([ValidateSet('Neutral', 'Checking', 'Success', 'UpdatesAvailable', 'Installing', 'Warning', 'Error')][string]$Family)

    $dark = $script:effectiveTheme -eq 'Dark'
    switch ($Family) {
        'Checking'         { return [PSCustomObject]@{ PillBackground='#EFF6FF'; PillForeground='#2563EB'; BannerBackground=$(if($dark){'#102A56'}else{'#EFF6FF'}); BannerBorder=$(if($dark){'#175CD3'}else{'#BFDBFE'}); BannerForeground=$(if($dark){'#84ADFF'}else{'#1D4ED8'}) } }
        'Success'          { return [PSCustomObject]@{ PillBackground='#ECFDF3'; PillForeground='#15803D'; BannerBackground=$(if($dark){'#053321'}else{'#ECFDF3'}); BannerBorder=$(if($dark){'#067647'}else{'#ABEFC6'}); BannerForeground=$(if($dark){'#6CE9A6'}else{'#067647'}) } }
        'UpdatesAvailable' { return [PSCustomObject]@{ PillBackground='#FFF7ED'; PillForeground='#C2410C'; BannerBackground=$(if($dark){'#3B2A0A'}else{'#FFF7ED'}); BannerBorder=$(if($dark){'#B54708'}else{'#FED7AA'}); BannerForeground=$(if($dark){'#FEC84B'}else{'#C2410C'}) } }
        'Installing'       { return [PSCustomObject]@{ PillBackground='#EEF2FF'; PillForeground='#4F46E5'; BannerBackground=$(if($dark){'#25215A'}else{'#EEF2FF'}); BannerBorder=$(if($dark){'#6366F1'}else{'#C7D2FE'}); BannerForeground=$(if($dark){'#C7D2FE'}else{'#4F46E5'}) } }
        'Warning'          { return [PSCustomObject]@{ PillBackground='#FFF7ED'; PillForeground='#C2410C'; BannerBackground=$(if($dark){'#3B2A0A'}else{'#FFFAEB'}); BannerBorder=$(if($dark){'#B54708'}else{'#FEDF89'}); BannerForeground=$(if($dark){'#FEC84B'}else{'#B54708'}) } }
        'Error'            { return [PSCustomObject]@{ PillBackground='#FEF2F2'; PillForeground='#DC2626'; BannerBackground=$(if($dark){'#3B1115'}else{'#FEF3F2'}); BannerBorder=$(if($dark){'#B42318'}else{'#FECDCA'}); BannerForeground=$(if($dark){'#FDA29B'}else{'#B42318'}) } }
        default            { return [PSCustomObject]@{ PillBackground='#F3F4F6'; PillForeground='#6B7280'; BannerBackground=$(if($dark){'#1F2937'}else{'#F3F4F6'}); BannerBorder=$(if($dark){'#4B5563'}else{'#D1D5DB'}); BannerForeground=$(if($dark){'#D1D5DB'}else{'#4B5563'}) } }
    }
}

function Resolve-BannerFamily {
    param([string]$Kind)
    if ($Kind -eq 'Info') { return 'Checking' }
    return $Kind
}

function Set-BannerAppearance {
    param([string]$Kind)
    $palette = Get-StatusSemanticPalette -Family (Resolve-BannerFamily -Kind $Kind)
    Set-Brush $BannerBorder Background $palette.BannerBackground
    Set-Brush $BannerBorder BorderBrush $palette.BannerBorder
    Set-Brush $BannerText Foreground $palette.BannerForeground
}

function Hide-Banner {
    if ($null -ne $script:bannerTimer) { $script:bannerTimer.Stop() }
    $script:bannerTimerPhase = 'Idle'
    $BannerBorder.BeginAnimation([Windows.UIElement]::OpacityProperty, $null)
    $BannerBorder.Opacity = 1.0
    $BannerBorder.Visibility = 'Collapsed'
}

function Show-Banner {
    param(
        [string]$Message,
        [ValidateSet('Info', 'Neutral', 'Checking', 'Success', 'UpdatesAvailable', 'Installing', 'Warning', 'Error')][string]$Kind = 'Info',
        [switch]$Persistent,
        [int]$TimeoutMilliseconds = 0
    )

    if ($null -ne $script:bannerTimer) { $script:bannerTimer.Stop() }
    $BannerBorder.BeginAnimation([Windows.UIElement]::OpacityProperty, $null)
    $BannerBorder.Opacity = 1.0
    $script:bannerKind = $Kind
    $BannerText.Text = $Message
    $BannerBorder.Visibility = 'Visible'
    Set-BannerAppearance -Kind $Kind

    if (-not $Persistent -and $null -ne $script:bannerTimer) {
        if ($TimeoutMilliseconds -le 0) {
            $TimeoutMilliseconds = if ($Kind -in @('Warning', 'Error')) { 9000 } else { 4500 }
        }
        $script:bannerTimerPhase = 'Waiting'
        $script:bannerTimer.Interval = [TimeSpan]::FromMilliseconds($TimeoutMilliseconds)
        $script:bannerTimer.Start()
    }
}

function Invoke-BannerTimerTick {
    if ($script:isShuttingDown) { $script:bannerTimer.Stop(); return }
    if ($script:bannerTimerPhase -eq 'Waiting') {
        $script:bannerTimer.Stop()
        $script:bannerTimerPhase = 'Fading'
        $fade = New-Object Windows.Media.Animation.DoubleAnimation
        $fade.From = 1.0
        $fade.To = 0.0
        $fade.Duration = New-Object Windows.Duration -ArgumentList ([TimeSpan]::FromMilliseconds(250))
        $fade.FillBehavior = [Windows.Media.Animation.FillBehavior]::HoldEnd
        $BannerBorder.BeginAnimation([Windows.UIElement]::OpacityProperty, $fade)
        $script:bannerTimer.Interval = [TimeSpan]::FromMilliseconds(250)
        $script:bannerTimer.Start()
    }
    else {
        Hide-Banner
    }
}

function Get-OverviewStatusPresentation {
    param(
        [ValidateSet('NotChecked', 'Checking', 'UpToDate', 'UpdatesAvailable', 'Installing', 'CompletedWithIssues', 'CheckFailed', 'InstallationFailed')][string]$State,
        [int]$UpdateCount = 0
    )

    $idleTitle = 'Check for updates'
    $idleSubtitle = 'Check for available Winget updates or install selected updates.'
    switch ($State) {
        'Checking' {
            $palette = Get-StatusSemanticPalette Checking
            return [PSCustomObject]@{ BadgeText='Checking'; Background=$palette.PillBackground; Foreground=$palette.PillForeground; CardTitle='Checking for updates'; CardSubtitle='Winget is scanning your managed applications.' }
        }
        'UpToDate' {
            $palette = Get-StatusSemanticPalette Success
            return [PSCustomObject]@{ BadgeText='Up to date'; Background=$palette.PillBackground; Foreground=$palette.PillForeground; CardTitle=$idleTitle; CardSubtitle=$idleSubtitle }
        }
        'UpdatesAvailable' {
            $count = [Math]::Max(1, $UpdateCount)
            $badgeText = if ($count -eq 1) { '1 update available' } else { "$count updates available" }
            $palette = Get-StatusSemanticPalette UpdatesAvailable
            return [PSCustomObject]@{ BadgeText=$badgeText; Background=$palette.PillBackground; Foreground=$palette.PillForeground; CardTitle='Updates ready to install'; CardSubtitle='Review the available updates below or install all of them.' }
        }
        'Installing' {
            $palette = Get-StatusSemanticPalette Installing
            return [PSCustomObject]@{ BadgeText='Installing'; Background=$palette.PillBackground; Foreground=$palette.PillForeground; CardTitle='Installing updates'; CardSubtitle='Winget is installing the available updates. This may take a few minutes.' }
        }
        'CompletedWithIssues' {
            $palette = Get-StatusSemanticPalette Warning
            return [PSCustomObject]@{ BadgeText='Completed with issues'; Background=$palette.PillBackground; Foreground=$palette.PillForeground; CardTitle='Some updates need attention'; CardSubtitle='Orbit installed the updates it could. Review the remaining items below.' }
        }
        'CheckFailed' {
            $palette = Get-StatusSemanticPalette Error
            return [PSCustomObject]@{ BadgeText='Check failed'; Background=$palette.PillBackground; Foreground=$palette.PillForeground; CardTitle='Update operation failed'; CardSubtitle='Review the status and Activity output, then try again.' }
        }
        'InstallationFailed' {
            $palette = Get-StatusSemanticPalette Error
            return [PSCustomObject]@{ BadgeText='Installation failed'; Background=$palette.PillBackground; Foreground=$palette.PillForeground; CardTitle='Update operation failed'; CardSubtitle='Review the status and Activity output, then try again.' }
        }
        default {
            $palette = Get-StatusSemanticPalette Neutral
            return [PSCustomObject]@{ BadgeText='Not checked yet'; Background=$palette.PillBackground; Foreground=$palette.PillForeground; CardTitle=$idleTitle; CardSubtitle=$idleSubtitle }
        }
    }
}

function New-TaskbarStatusBadgeImage {
    param([Parameter(Mandatory = $true)][string]$Color)

    $badgeBrush = $brushConverter.ConvertFromString($Color)
    if ($badgeBrush.CanFreeze) { $badgeBrush.Freeze() }

    $drawingGroup = New-Object Windows.Media.DrawingGroup
    $canvasDrawing = New-Object Windows.Media.GeometryDrawing
    $canvasDrawing.Brush = [Windows.Media.Brushes]::Transparent
    $canvasDrawing.Geometry = [Windows.Media.RectangleGeometry]::new([Windows.Rect]::new(0, 0, 16, 16))
    [void]$drawingGroup.Children.Add($canvasDrawing)

    $badgeDrawing = New-Object Windows.Media.GeometryDrawing
    $badgeDrawing.Brush = $badgeBrush
    $badgeDrawing.Geometry = [Windows.Media.EllipseGeometry]::new([Windows.Point]::new(8, 8), 6.25, 6.25)
    [void]$drawingGroup.Children.Add($badgeDrawing)
    if ($drawingGroup.CanFreeze) { $drawingGroup.Freeze() }

    $image = [Windows.Media.DrawingImage]::new($drawingGroup)
    if ($image.CanFreeze) { $image.Freeze() }
    return $image
}

function Update-TaskbarStatusBadge {
    param(
        [Parameter(Mandatory = $true)][string]$State,
        [Parameter(Mandatory = $true)][string]$Color
    )

    try {
        $enabled = $null -ne $script:configuration -and [bool]$script:configuration.showTaskbarStatusBadge
        $renderState = if ($enabled -and $State -ne 'NotChecked') { "$State|$Color" } else { 'None' }
        if ($script:taskbarBadgeRenderState -eq $renderState) { return }

        if ($null -eq $window.TaskbarItemInfo) {
            $window.TaskbarItemInfo = New-Object Windows.Shell.TaskbarItemInfo
        }

        if ($renderState -eq 'None') {
            $window.TaskbarItemInfo.Overlay = $null
        }
        else {
            if (-not $script:taskbarBadgeImages.ContainsKey($Color)) {
                $script:taskbarBadgeImages[$Color] = New-TaskbarStatusBadgeImage -Color $Color
            }
            $window.TaskbarItemInfo.Overlay = $script:taskbarBadgeImages[$Color]
        }
        $script:taskbarBadgeRenderState = $renderState
    }
    catch {
        try {
            [void](Write-OrbitCrashReport -Operation 'TaskbarBadge.Render' -ErrorRecord $_ -Context (Get-OrbitUiCrashContext))
        }
        catch { }
    }
}

function Set-OverviewStatus {
    param(
        [ValidateSet('NotChecked', 'Checking', 'UpToDate', 'UpdatesAvailable', 'Installing', 'CompletedWithIssues', 'CheckFailed', 'InstallationFailed')][string]$State,
        [int]$UpdateCount = 0
    )

    $script:authoritativeOverviewState = $State
    $presentation = Get-OverviewStatusPresentation -State $State -UpdateCount $UpdateCount
    $HeaderStatusText.Text = $presentation.BadgeText
    Set-Brush $HeaderStatusPill Background $presentation.Background
    Set-Brush $HeaderStatusText Foreground $presentation.Foreground
    Set-Brush $HeaderStatusDot Fill $presentation.Foreground
    $ActionCardTitle.Text = $presentation.CardTitle
    $ActionCardSubtitle.Text = $presentation.CardSubtitle
    Update-TaskbarStatusBadge -State $State -Color $presentation.Foreground
}

function Set-OverviewStatusOverride {
    param([ValidateSet('CheckFailed', 'InstallationFailed')][string]$State)

    $script:overviewStatusOverride = $State
    $script:overviewStatusOverrideStateWrite = if (Test-Path -LiteralPath $statePath) { (Get-Item -LiteralPath $statePath).LastWriteTimeUtc } else { [DateTime]::MinValue }
    Set-OverviewStatus $State
}

function Get-ConfirmedUpdateCount {
    param($State)

    $rawCount = Get-OptionalProperty $State 'updatesRemaining' (Get-OptionalProperty $State 'updatesFound' $null)
    if ($null -ne $rawCount) {
        try { return [Math]::Max(0, [int]$rawCount) } catch { }
    }

    if (Test-Path -LiteralPath $updatesPath) {
        try {
            $savedUpdates = Get-Content -LiteralPath $updatesPath -Raw -Encoding UTF8 | ConvertFrom-Json
            if ([string](Get-OptionalProperty $savedUpdates 'status' '') -eq 'Available') {
                $savedCount = Get-OptionalProperty $savedUpdates 'count' $null
                if ($null -ne $savedCount) { return [Math]::Max(0, [int]$savedCount) }
                return @($savedUpdates.items).Count
            }
        }
        catch { }
    }
    return 1
}

function Get-OverviewStatusState {
    param(
        $State,
        [AllowEmptyString()][ValidateSet('', 'Checking', 'Installing')][string]$ActiveState = '',
        [int]$UpdateCount = 0
    )

    if (-not [string]::IsNullOrWhiteSpace($ActiveState)) {
        return [PSCustomObject]@{ State=$ActiveState; UpdateCount=0 }
    }
    if ($null -eq $State) {
        return [PSCustomObject]@{ State='NotChecked'; UpdateCount=0 }
    }

    $runType = [string](Get-OptionalProperty $State 'runType' '')
    $status = [string](Get-OptionalProperty $State 'status' '')
    $errorCategory = [string](Get-OptionalProperty $State 'errorCategory' '')
    if ($status -eq 'Running') {
        $runningState = if ($runType -in @('manual-check','scheduled-check','sign-in-check')) { 'Checking' } else { 'Installing' }
        return [PSCustomObject]@{ State=$runningState; UpdateCount=0 }
    }
    if ($status -eq 'UpdatesAvailable') {
        return [PSCustomObject]@{ State='UpdatesAvailable'; UpdateCount=[Math]::Max(1, $UpdateCount) }
    }
    if ($status -eq 'CompletedWithIssues') {
        return [PSCustomObject]@{ State='CompletedWithIssues'; UpdateCount=0 }
    }
    if ($errorCategory -eq 'incomplete-parse') {
        return [PSCustomObject]@{ State='CheckFailed'; UpdateCount=0 }
    }
    if ($runType -in @('manual-check','scheduled-check','sign-in-check')) {
        if ($status -eq 'Success' -and $UpdateCount -gt 0) {
            return [PSCustomObject]@{ State='UpdatesAvailable'; UpdateCount=$UpdateCount }
        }
        $checkState = if ($status -in @('NoUpdates', 'Success')) { 'UpToDate' } else { 'CheckFailed' }
        return [PSCustomObject]@{ State=$checkState; UpdateCount=0 }
    }
    if ($status -in @('NoUpdates', 'Success', 'RestartRequired')) {
        return [PSCustomObject]@{ State='UpToDate'; UpdateCount=0 }
    }
    if ([string]::IsNullOrWhiteSpace($status) -or $status -eq 'AutomaticUpdatesDisabled') {
        return [PSCustomObject]@{ State='NotChecked'; UpdateCount=0 }
    }
    return [PSCustomObject]@{ State='InstallationFailed'; UpdateCount=0 }
}

function Get-ActiveOverviewStatus {
    if ($script:waitingForScheduledRun) { return 'Installing' }
    if ($null -eq $script:engineWorker) { return '' }
    try {
        if (-not $script:engineWorker.HasExited) {
            $activeState = if ($script:currentOperation -eq 'Overview.CheckOnly') { 'Checking' } else { 'Installing' }
            return $activeState
        }
    }
    catch { }
    return ''
}

function Show-AppPage {
    param([ValidateSet('Overview', 'History', 'Settings')][string]$Page)
    $script:selectedPage = $Page
    $OverviewPanel.Visibility = if ($Page -eq 'Overview') { 'Visible' } else { 'Collapsed' }
    $HistoryPanel.Visibility = if ($Page -eq 'History') { 'Visible' } else { 'Collapsed' }
    $SettingsPanel.Visibility = if ($Page -eq 'Settings') { 'Visible' } else { 'Collapsed' }
    $OverviewNavButton.Tag = if ($Page -eq 'Overview') { 'Selected' } else { $null }
    $HistoryNavButton.Tag = if ($Page -eq 'History') { 'Selected' } else { $null }
    $SettingsNavButton.Tag = if ($Page -eq 'Settings') { 'Selected' } else { $null }
    $HeaderStatusPill.Visibility = if ($Page -eq 'Overview') { 'Visible' } else { 'Collapsed' }
    switch ($Page) {
        'History' { $HeaderTitle.Text='History'; $HeaderSubtitle.Text='Review previous checks and update runs.'; Refresh-History }
        'Settings'{ $HeaderTitle.Text='Settings'; $HeaderSubtitle.Text='Configure appearance, automation, technical details, and history.' }
        default   { $HeaderTitle.Text='Overview'; $HeaderSubtitle.Text='Manage your Winget updates in one place.' }
    }
}

function Reset-LiveInstallationProgressVisual {
    param([switch]$HidePanel)

    $script:liveProgressVisible = $false
    $script:liveProgressSignature = ''
    $ProgressQueueText.Text = ''
    $ProgressQueueText.Visibility = 'Collapsed'
    $ProgressPercentText.Text = ''
    $ProgressPercentText.Visibility = 'Collapsed'
    $ProgressText.Visibility = 'Visible'
    $ActionProgressBar.IsIndeterminate = $true
    $ActionProgressBar.Value = 0
    if ($HidePanel) { $ProgressPanel.Visibility = 'Collapsed' }
}

function Set-LiveInstallationProgressVisual {
    param([Parameter(Mandatory = $true)]$Progress)

    $phase = [string](Get-OptionalProperty $Progress 'phase' '')
    if ($phase -eq 'finalizing') {
        Reset-LiveInstallationProgressVisual -HidePanel
        return $true
    }
    if ($phase -ne 'installing') { return $false }

    $packageName = [string](Get-OptionalProperty $Progress 'packageName' '')
    $currentIndex = [int](Get-OptionalProperty $Progress 'currentIndex' 0)
    $totalPackages = [int](Get-OptionalProperty $Progress 'totalPackages' 0)
    if ([string]::IsNullOrWhiteSpace($packageName) -or $currentIndex -lt 1 -or $totalPackages -lt 1 -or $currentIndex -gt $totalPackages) { return $false }

    $percentage = Get-OptionalProperty $Progress 'percentage' $null
    $percentageValue = $null
    if ($null -ne $percentage) {
        try {
            $candidate = [int]$percentage
            if ($candidate -ge 0 -and $candidate -le 100) { $percentageValue = $candidate }
        }
        catch { }
    }
    $signature = '{0}|{1}|{2}|{3}' -f $packageName,$currentIndex,$totalPackages,$percentageValue
    if ($signature -eq $script:liveProgressSignature -and $script:liveProgressVisible) { return $true }

    $script:liveProgressSignature = $signature
    $script:liveProgressVisible = $true
    $ActionCardTitle.Text = "Installing $packageName"
    $ActionCardSubtitle.Text = 'Winget is installing the selected update.'
    $ProgressPanel.Visibility = 'Visible'
    $ProgressText.Visibility = 'Collapsed'
    $ProgressQueueText.Text = "$currentIndex of $totalPackages updates"
    $ProgressQueueText.Visibility = 'Visible'
    if ($null -eq $percentageValue) {
        $ActionProgressBar.Value = 0
        $ActionProgressBar.IsIndeterminate = $true
        $ProgressPercentText.Text = ''
        $ProgressPercentText.Visibility = 'Collapsed'
    }
    else {
        $ActionProgressBar.IsIndeterminate = $false
        $ActionProgressBar.Value = $percentageValue
        $ProgressPercentText.Text = "$percentageValue%"
        $ProgressPercentText.Visibility = 'Visible'
    }
    return $true
}

function Refresh-LiveInstallationProgress {
    if (-not (Test-Path -LiteralPath $liveProgressPath)) {
        if ($script:liveProgressVisible) { Reset-LiveInstallationProgressVisual -HidePanel }
        return
    }

    try {
        $progress = Get-Content -LiteralPath $liveProgressPath -Raw -Encoding UTF8 | ConvertFrom-Json
        $engineProcessId = [int](Get-OptionalProperty $progress 'engineProcessId' 0)
        if ($engineProcessId -le 0) { throw 'The progress publisher identity is unavailable.' }
        $engineProcess = Get-Process -Id $engineProcessId -ErrorAction Stop
        if ($engineProcess.HasExited) { throw 'The progress publisher has exited.' }

        if ([string](Get-OptionalProperty $progress 'phase' '') -eq 'installing' -and -not $script:liveProgressVisible) {
            Set-Activity $true
            Set-OverviewStatus Installing
        }
        if (-not (Set-LiveInstallationProgressVisual -Progress $progress)) {
            Reset-LiveInstallationProgressVisual -HidePanel
        }
    }
    catch {
        Reset-LiveInstallationProgressVisual -HidePanel
    }
}

function Set-Activity {
    param([bool]$Active, [string]$Message = '')
    $CheckButton.IsEnabled = -not $Active
    $AutomaticUpdatesToggle.IsEnabled = -not $Active
    $AvailableUpdatesItems.IsEnabled = -not $Active
    $IntervalSlider.IsEnabled = (-not $Active -and $script:automaticUpdatesEnabled)
    $ProgressPanel.Visibility = if ($Active) { 'Visible' } else { 'Collapsed' }
    if ($Active -and -not $script:liveProgressVisible) {
        $ProgressText.Visibility = 'Visible'
        $ProgressQueueText.Visibility = 'Collapsed'
        $ProgressPercentText.Visibility = 'Collapsed'
        $ActionProgressBar.IsIndeterminate = $true
        $ActionProgressBar.Value = 0
        if (-not [string]::IsNullOrWhiteSpace($Message)) { $ProgressText.Text = $Message }
    }
    if ($Active) { $RunButton.IsEnabled = $false }
    else { Reset-LiveInstallationProgressVisual -HidePanel; Update-InstallSelectionState }
}

function Get-SelectedAvailablePackages {
    return @(@($script:availableUpdateItems) | Where-Object {
        [bool]$_.IsSelected -and -not [string]::IsNullOrWhiteSpace([string]$_.Id)
    })
}

function Get-SelectedAvailablePackageIds {
    $selectedPackages = @(Get-SelectedAvailablePackages)
    return @($selectedPackages | ForEach-Object { [string]$_.Id } | Select-Object -Unique)
}

function Update-InstallSelectionState {
    $total = @($script:availableUpdateItems).Count
    $selected = @(Get-SelectedAvailablePackages).Count
    $allSelected = $total -gt 0 -and $selected -eq $total
    $RunButton.Content = if ($allSelected) { 'Install all updates' } else { 'Install selected updates' }
    $busy = $null -ne $script:engineWorker -or $script:waitingForScheduledRun
    $RunButton.IsEnabled = -not $busy -and $selected -gt 0
}

function Update-IntervalVisual {
    $index = [int][Math]::Round($IntervalSlider.Value)
    if ($index -lt 0) { $index = 0 }
    if ($index -gt 4) { $index = 4 }
    $ticks = @($IntervalTick1,$IntervalTick3,$IntervalTick6,$IntervalTick12,$IntervalTick24)
    foreach ($tick in $ticks) { $tick.FontWeight='Normal'; $tick.Foreground=$window.Resources['MutedBrush'] }
    $ticks[$index].FontWeight='SemiBold'
    $ticks[$index].Foreground=$brushConverter.ConvertFromString('#0891B2')
    $hours = $script:intervalOptions[$index]
    if ($script:automaticUpdatesEnabled) {
        $unit = if ($hours -eq 1) { 'hour' } else { 'hours' }
        $AutoStatusDetail.Text = "Checks automatically every $hours $unit and at sign-in."
    }
    return $hours
}

function Set-IntervalFromLabel {
    param($Sender)

    if (-not $script:windowInitialized -or $script:suppressIntervalEvents -or -not $IntervalSlider.IsEnabled) { return $false }
    $index = [Array]::IndexOf($script:intervalHitTargets, $Sender)
    if ($index -lt 0 -or $index -ge $script:intervalOptions.Count) { return $false }
    if ($IntervalSlider.Value -eq [double]$index -and $script:automaticUpdatesEnabled) {
        Request-IntervalSave -Hours $script:intervalOptions[$index]
    }
    $IntervalSlider.Value = [double]$index
    return $true
}

function Request-IntervalSave {
    param([int]$Hours)
    if ($script:intervalOptions -notcontains $Hours) { return }
    $script:intervalSelectionGeneration++
    $script:pendingIntervalHours = $Hours
    $script:intervalSaveFailed = $false
    $script:intervalSaveDueAt = [DateTimeOffset]::UtcNow.AddMilliseconds(650)
    $intervalSaveTimer.Start()
}

function Start-IntervalSaveWorker {
    param([int]$Hours, [long]$Generation)
    # Reuse the safe configuration writer in a background runspace: no process,
    # console, scheduler call, or UI-thread mutex wait is needed for this preference.
    $writer = [PowerShell]::Create()
    try {
        [void]$writer.AddScript({
            param($dataScript, $hours)
            $ErrorActionPreference = 'Stop'
            . $dataScript
            Save-OrbitConfiguration -Changes @{intervalHours=[int]$hours}
        }).AddArgument($commonPath).AddArgument($Hours)
        $handle = $writer.BeginInvoke()
        return [PSCustomObject]@{ Writer=$writer; Handle=$handle; Hours=$Hours; Generation=$Generation }
    }
    catch { $writer.Dispose(); throw }
}

function Complete-IntervalSave {
    param([long]$Generation, [int]$Hours, $Failure = $null)
    $isLatest = $Generation -eq $script:intervalSelectionGeneration
    if ($null -eq $Failure) {
        # A superseded save may have reached disk, but must never reset the latest
        # slider selection or replace unrelated settings with its older snapshot.
        $script:intervalHours = $Hours
        $script:configuration.intervalHours = $Hours
        if ($isLatest) {
            $script:pendingIntervalHours = $null
            $script:intervalSaveFailed = $false
        }
    }
    elseif ($isLatest) {
        $script:intervalSaveFailed = $true
        [void](Invoke-OrbitUiAction -Operation 'Overview.IntervalSlider' -FailureMessage 'The update interval could not be saved. Your selection is still shown; select an interval again to retry.' -Action { throw $Failure })
    }
    else {
        [void](Write-OrbitCrashReport -Operation 'Overview.IntervalSlider.SupersededSave' -ErrorRecord $Failure -Context (Get-OrbitUiCrashContext))
    }
}

function Invoke-IntervalSaveTick {
    if ($script:isShuttingDown) { $intervalSaveTimer.Stop(); return }
    if ($null -ne $script:intervalSaveWorker) {
        if (-not $script:intervalSaveWorker.Handle.IsCompleted) { return }
        $worker = $script:intervalSaveWorker
        $script:intervalSaveWorker = $null
        $failure = $null
        try {
            [void]$worker.Writer.EndInvoke($worker.Handle)
            if ($worker.Writer.HadErrors) { $failure = $worker.Writer.Streams.Error[0] }
        }
        catch { $failure = $_ }
        finally { $worker.Writer.Dispose() }
        Complete-IntervalSave -Generation $worker.Generation -Hours $worker.Hours -Failure $failure
    }
    if ($null -eq $script:pendingIntervalHours -or $script:intervalSaveFailed) {
        $intervalSaveTimer.Stop()
        if ($script:intervalCloseRequested) {
            $script:intervalCloseRequested = $false
            if (-not $script:intervalSaveFailed) { $window.Close() }
        }
        return
    }
    if ([DateTimeOffset]::UtcNow -lt $script:intervalSaveDueAt) { return }
    $hours = [int]$script:pendingIntervalHours
    $generation = $script:intervalSelectionGeneration
    if ($hours -eq $script:intervalHours) {
        Complete-IntervalSave -Generation $generation -Hours $hours
        return
    }
    try { $script:intervalSaveWorker = Start-IntervalSaveWorker -Hours $hours -Generation $generation }
    catch { Complete-IntervalSave -Generation $generation -Hours $hours -Failure $_ }
}

function Update-BackgroundStatus {
    $automaticChecks = [bool](Get-OptionalProperty $script:configuration 'automaticUpdatesEnabled' $script:automaticUpdatesEnabled)
    $automaticInstallation = [bool](Get-OptionalProperty $script:configuration 'automaticInstallationEnabled' $false)
    $startupInstallation = $automaticInstallation -and [bool](Get-OptionalProperty $script:configuration 'installOnStartupEnabled' $false)
    $notifications = [bool](Get-OptionalProperty $script:configuration 'notificationsEnabled' $true)

    $lines = New-Object 'System.Collections.Generic.List[string]'
    $lines.Add($(if ($automaticChecks) { 'Automatic checks on' } else { 'Automatic checks off' }))
    $lines.Add($(if ($automaticInstallation) { 'Automatic installation on' } else { 'Automatic installation off' }))
    if ($automaticInstallation) {
        $lines.Add($(if ($startupInstallation) { 'Install on Orbit startup on' } else { 'Install on Orbit startup off' }))
    }
    $lines.Add($(if ($notifications) { 'Notifications on' } else { 'Notifications off' }))
    $SidebarScheduleText.Text = $lines -join [Environment]::NewLine
}

function Set-AutomaticUpdateVisual {
    param([bool]$Enabled)

    $script:automaticUpdatesEnabled = $Enabled
    if ($null -eq $AutomaticUpdatesToggle.IsChecked -or [bool]$AutomaticUpdatesToggle.IsChecked -ne $Enabled) {
        $script:suppressAutoEvents = $true
        $AutomaticUpdatesToggle.IsChecked = $Enabled
        $script:suppressAutoEvents = $false
    }
    $IntervalPanel.IsEnabled = $Enabled
    $IntervalPanel.Opacity = if ($Enabled) { 1.0 } else { 0.45 }
    $IntervalSlider.IsEnabled = $Enabled -and $null -eq $script:engineWorker -and -not $script:waitingForScheduledRun
    if ($Enabled) {
        $AutoStatusTitle.Text = 'Automatic checks'
        $visibleHours = if ($null -ne $script:pendingIntervalHours) { [int]$script:pendingIntervalHours } else { $script:intervalHours }
        $unit = if ($visibleHours -eq 1) { 'hour' } else { 'hours' }
        $AutoStatusDetail.Text = "Checks automatically every $visibleHours $unit and at sign-in."
    }
    else {
        $AutoStatusTitle.Text = 'Automatic checks are off'
        $AutoStatusDetail.Text = 'Scheduled checks are disabled.'
    }
    Update-BackgroundStatus
}

function Set-AutomationSettingsVisual {
    $automaticInstallation = [bool]$script:configuration.automaticInstallationEnabled
    $startupInstallation = $automaticInstallation -and [bool]$script:configuration.installOnStartupEnabled
    $script:suppressAutomationEvents = $true
    $AutomaticInstallationToggle.IsChecked = $automaticInstallation
    $StartupInstallationToggle.IsChecked = $startupInstallation
    $NotificationsToggle.IsChecked = [bool]$script:configuration.notificationsEnabled
    $script:suppressAutomationEvents = $false
    $StartupInstallationToggle.IsEnabled = $automaticInstallation
    $StartupInstallationRow.Opacity = if($automaticInstallation){1.0}else{0.45}
    Update-BackgroundStatus
}

function Refresh-TaskStatus {
    $script:configuration = Get-OrbitConfiguration
    $task = Get-OrbitRegisteredTask -Name $taskName
    $signInTask = Get-OrbitRegisteredTask -Name $signInTaskName
    $script:schedulingReady = ($null -ne $task -and [bool]$task.Enabled -and
        $null -ne $signInTask -and [bool]$signInTask.Enabled)
    $enabled = [bool]$script:configuration.automaticUpdatesEnabled
    $script:intervalHours = [int]$script:configuration.intervalHours
    Set-AutomaticUpdateVisual -Enabled $enabled

    # Disk remains the startup source, but a debouncing, in-flight, or failed
    # selection belongs to the user until its own save completes successfully.
    if ($null -eq $script:pendingIntervalHours -and $null -eq $script:intervalSaveWorker) {
        $index = [Array]::IndexOf($script:intervalOptions, $script:intervalHours)
        if ($index -lt 0) { $index = 2 }
        $script:suppressIntervalEvents = $true
        try { $IntervalSlider.Value = $index }
        finally { $script:suppressIntervalEvents = $false }
    }
    [void](Update-IntervalVisual)
    if ($enabled -and -not $script:schedulingReady) {
        $AutoStatusTitle.Text = 'Automatic checks need setup'
        $AutoStatusDetail.Text = 'Run Setup.cmd once to repair the background task.'
    }
    Set-AutomationSettingsVisual
    Update-TechnicalCommandBlock
}

function Get-PreferredActivityLogFile {
    if (-not (Test-Path -LiteralPath $statePath)) { return '' }
    try {
        $state = Get-Content -LiteralPath $statePath -Raw -Encoding UTF8 | ConvertFrom-Json
        return [string](Get-OptionalProperty $state 'logFile' '')
    }
    catch { return '' }
}

function Refresh-TechnicalActivity {
    if (-not [bool]$script:configuration.showTechnicalDetails) { return }

    $preferredLogFile = Get-PreferredActivityLogFile
    $path = Get-OrbitLatestRunLogPath -PreferredLogFile $preferredLogFile
    if ([string]::IsNullOrWhiteSpace([string]$path)) {
        $script:activityLogPath = $null
        $script:activityLogWriteTime = [DateTime]::MinValue
        $script:activityLogLength = [long]-1
        $ActivityOpenLogButton.IsEnabled = $false
        if ($ActivityOutputTextBox.Text -ne 'No technical activity recorded yet.') {
            $ActivityOutputTextBox.Text = 'No technical activity recorded yet.'
        }
        return
    }

    try {
        $item = Get-Item -LiteralPath $path -ErrorAction Stop
        $ActivityOpenLogButton.IsEnabled = $true
        if ([string]::Equals([string]$script:activityLogPath, [string]$item.FullName, [StringComparison]::OrdinalIgnoreCase) -and
            $script:activityLogWriteTime -eq $item.LastWriteTimeUtc -and
            $script:activityLogLength -eq [long]$item.Length) { return }

        $recentText = Read-OrbitRecentLog -Path $item.FullName -MaximumBytes 131072
        if ([string]::IsNullOrWhiteSpace($recentText)) { $recentText = 'No technical activity recorded yet.' }
        $script:activityLogPath = $item.FullName
        $script:activityLogWriteTime = $item.LastWriteTimeUtc
        $script:activityLogLength = [long]$item.Length
        $ActivityOutputTextBox.Text = $recentText
        $ActivityOutputTextBox.ScrollToEnd()
    }
    catch {
        $ActivityOpenLogButton.IsEnabled = $false
        $ActivityOutputTextBox.Text = 'The latest technical log could not be read.'
    }
}

function Update-TechnicalCommandBlock {
    $enabled = [bool]$script:configuration.showTechnicalDetails
    $TechnicalCommandBlock.Visibility = if ($enabled) { 'Visible' } else { 'Collapsed' }
    $TechnicalActivityBlock.Visibility = if ($enabled) { 'Visible' } else { 'Collapsed' }
    $TechnicalCommandLabel.Text = if ($script:technicalCommandMode -eq 'Check') { 'COMMAND USED FOR CHECKS' } else { 'COMMAND USED FOR UPDATES' }
    if($script:technicalCommandMode -eq 'Check'){
        $TechnicalCommandText.Text = Get-OrbitWingetCommandText -Operation Check -Configuration $script:configuration
    }
    elseif(@($script:activeTechnicalCommands).Count -gt 0){
        $TechnicalCommandText.Text = @($script:activeTechnicalCommands) -join "`r`n"
    }
    else{
        $selectedPackages=@(Get-SelectedAvailablePackages)
        if($selectedPackages.Count -gt 0){$TechnicalCommandText.Text=@($selectedPackages|ForEach-Object{Get-OrbitWingetCommandText -Operation Update -Configuration $script:configuration -PackageId ([string]$_.Id) -PackageSource ([string]$_.Source)}) -join "`r`n"}
        else{$TechnicalCommandText.Text=Get-OrbitWingetCommandText -Operation Check -Configuration $script:configuration}
    }
    if ($enabled) { Refresh-TechnicalActivity }
}

function Refresh-State {
    $state = $null
    if (-not [string]::IsNullOrWhiteSpace($script:overviewStatusOverride) -and (Test-Path -LiteralPath $statePath)) {
        try {
            if ((Get-Item -LiteralPath $statePath).LastWriteTimeUtc -gt $script:overviewStatusOverrideStateWrite) {
                $script:overviewStatusOverride = ''
            }
        }
        catch { }
    }
    if (Test-Path -LiteralPath $statePath) {
        try { $state = Get-Content -LiteralPath $statePath -Raw -Encoding UTF8 | ConvertFrom-Json } catch { }
    }
    $activeOverviewState = Get-ActiveOverviewStatus
    if ($null -eq $state) {
        $LastRunDateText.Text='No run recorded'; $LastRunTimeText.Text=''; $LastResultText.Text='Run a check to get started.'
        if ([string]::IsNullOrWhiteSpace($activeOverviewState) -and -not [string]::IsNullOrWhiteSpace($script:overviewStatusOverride)) {
            Set-OverviewStatus $script:overviewStatusOverride
        }
        else {
            $resolvedOverview = Get-OverviewStatusState -State $null -ActiveState $activeOverviewState
            Set-OverviewStatus $resolvedOverview.State -UpdateCount $resolvedOverview.UpdateCount
        }
        return
    }

    $runType = [string](Get-OptionalProperty $state 'runType' '')
    $commandMode = if ($runType -in @('manual-check','scheduled-check','sign-in-check')) { 'Check' } else { 'Update' }
    if ($null -eq $script:engineWorker -and -not $script:waitingForScheduledRun -and $script:technicalCommandMode -ne $commandMode) {
        $script:technicalCommandMode = $commandMode
        Update-TechnicalCommandBlock
    }
    $status = [string](Get-OptionalProperty $state 'status' '')
    $message = [string](Get-OptionalProperty $state 'message' '')
    if ([string]::IsNullOrWhiteSpace($activeOverviewState) -and -not [string]::IsNullOrWhiteSpace($script:overviewStatusOverride)) {
        Set-OverviewStatus $script:overviewStatusOverride
    }
    else {
        $countIsAuthoritative = $status -eq 'UpdatesAvailable' -or ($runType -eq 'manual-check' -and $status -eq 'Success')
        $confirmedCount = if ($countIsAuthoritative) { Get-ConfirmedUpdateCount -State $state } else { 0 }
        $resolvedOverview = Get-OverviewStatusState -State $state -ActiveState $activeOverviewState -UpdateCount $confirmedCount
        Set-OverviewStatus $resolvedOverview.State -UpdateCount $resolvedOverview.UpdateCount
    }
    if ($status -eq 'Running') { Set-Activity $true $message }

    $dateValue = Get-OptionalProperty $state 'completedAt' (Get-OptionalProperty $state 'startedAt' $null)
    if ($null -ne $dateValue) {
        try {
            $local = (ConvertTo-OrbitDateTimeOffset -Value $dateValue).ToLocalTime()
            $culture = [Globalization.CultureInfo]::CurrentCulture
            $LastRunDateText.Text = $local.ToString('ddd, d MMM yyyy', $culture)
            $LastRunTimeText.Text = $local.ToString('t', $culture)
        }
        catch { }
    }
    if (-not [string]::IsNullOrWhiteSpace($message)) { $LastResultText.Text = $message }
    if ($status -ne 'Running' -and $null -eq $script:engineWorker -and -not $script:waitingForScheduledRun) { Set-Activity $false }
}

function Refresh-AvailableUpdates {
    if (-not (Test-Path -LiteralPath $updatesPath)) {
        $script:availableUpdateItems=@();$AvailableUpdatesTitle.Text='Available updates'; $AvailableUpdatesSubtitle.Text='Run Check only to scan Winget-managed applications.'; $AvailableUpdatesCount.Text='Not scanned'; $AvailableUpdatesEmpty.Text='No update scan data yet.'; $AvailableUpdatesEmpty.Visibility='Visible'; $AvailableUpdatesList.Visibility='Collapsed'; $AvailableUpdatesItems.ItemsSource=$null;Update-InstallSelectionState; return
    }
    try {
        $data = Get-Content -LiteralPath $updatesPath -Raw -Encoding UTF8 | ConvertFrom-Json
        $items = @($data.items)
        $count = $items.Count
        $scanTime = (ConvertTo-OrbitDateTimeOffset -Value $data.generatedAt).ToLocalTime().ToString('g', [Globalization.CultureInfo]::CurrentCulture)
        if ([string]$data.status -eq 'Failed' -and $count -eq 0) {
            $script:availableUpdateItems=@();$AvailableUpdatesTitle.Text='Update details unavailable'; $AvailableUpdatesSubtitle.Text="The latest Winget scan at $scanTime could not be read completely."; $AvailableUpdatesCount.Text='Check failed'; $AvailableUpdatesEmpty.Text='Try Check only again. Technical details contain the complete Winget output.'; $AvailableUpdatesEmpty.Visibility='Visible'; $AvailableUpdatesList.Visibility='Collapsed'; $AvailableUpdatesItems.ItemsSource=$null;Update-InstallSelectionState; return
        }
        if ($count -eq 0) {
            $script:availableUpdateItems=@();$AvailableUpdatesTitle.Text='No updates available through Winget'; $AvailableUpdatesSubtitle.Text="Last scan: $scanTime"; $AvailableUpdatesCount.Text='0 updates'; $AvailableUpdatesEmpty.Text='All Winget-managed applications are up to date.'; $AvailableUpdatesEmpty.Visibility='Visible'; $AvailableUpdatesList.Visibility='Collapsed'; $AvailableUpdatesItems.ItemsSource=$null;Update-InstallSelectionState; return
        }
        switch ([string]$data.status) {
            'Processed' { $AvailableUpdatesTitle.Text='Updates detected in the latest run'; $AvailableUpdatesSubtitle.Text="Found before the update run at $scanTime."; $AvailableUpdatesCount.Text="$count handled" }
            'Failed' { $AvailableUpdatesTitle.Text='Updates need attention'; $AvailableUpdatesSubtitle.Text="Detected at $scanTime."; $AvailableUpdatesCount.Text="$count detected" }
            default { $AvailableUpdatesTitle.Text=if($count -eq 1){'1 update available'}else{"$count updates available"}; $AvailableUpdatesSubtitle.Text="Latest scan: $scanTime"; $AvailableUpdatesCount.Text=if($count -eq 1){'1 update'}else{"$count updates"} }
        }
        $viewItems=@()
        foreach($item in $items){
            $viewItems += [PSCustomObject][ordered]@{IsSelected=$true;Name=[string](Get-OptionalProperty $item 'Name' 'Unknown application');Id=[string](Get-OptionalProperty $item 'Id' '');InstalledVersion=[string](Get-OptionalProperty $item 'InstalledVersion' 'Unknown');AvailableVersion=[string](Get-OptionalProperty $item 'AvailableVersion' 'Unknown');Source=[string](Get-OptionalProperty $item 'Source' '')}
        }
        $script:availableUpdateItems=@($viewItems)
        $AvailableUpdatesItems.ItemsSource=$script:availableUpdateItems; $AvailableUpdatesEmpty.Visibility='Collapsed'; $AvailableUpdatesList.Visibility='Visible';Update-InstallSelectionState;Update-TechnicalCommandBlock
    }
    catch {
        $script:availableUpdateItems=@();$AvailableUpdatesTitle.Text='Available updates'; $AvailableUpdatesSubtitle.Text='The saved update list could not be read.'; $AvailableUpdatesCount.Text='Unavailable'; $AvailableUpdatesEmpty.Text='Run Check only to try again.'; $AvailableUpdatesEmpty.Visibility='Visible'; $AvailableUpdatesList.Visibility='Collapsed';$AvailableUpdatesItems.ItemsSource=$null;Update-InstallSelectionState
    }
}

function Get-RunTypeText {
    param([string]$RunType)
    switch ($RunType) { 'manual-check'{'Manual check'} 'manual-update'{'Manual update'} 'scheduled-check'{'Scheduled check'} 'scheduled-update'{'Scheduled update'} 'sign-in-check'{'Sign-in check'} 'sign-in-update'{'Sign-in update'} 'startup-update'{'Startup update'} default{'Update run'} }
}

function Get-HistoryStatusText {
    param([string]$Status)
    switch ($Status) { 'success'{'Success'} 'partial-success'{'Completed with issues'} 'failed'{'Failed'} 'skipped'{'Skipped'} 'not-started'{'Not started'} 'cancelled'{'Cancelled'} 'no-updates-found'{'No updates found'} default{'Unknown'} }
}

function Get-HistoryStatusColor {
    param([string]$Status)
    switch ($Status) { 'success'{'#12B76A'} 'no-updates-found'{'#0891B2'} 'partial-success'{'#F79009'} 'skipped'{'#98A2B3'} 'not-started'{'#98A2B3'} 'cancelled'{'#98A2B3'} default{'#F04438'} }
}

function ConvertTo-HistoryDisplayItem {
    param($Entry)
    $started = (ConvertTo-OrbitDateTimeOffset -Value $Entry.startedAt).ToLocalTime()
    $culture = [Globalization.CultureInfo]::CurrentCulture
    $found = [int](Get-OptionalProperty $Entry 'updatesFound' 0)
    $installedValue = Get-OptionalProperty $Entry 'updatesInstalled' $null
    $failedValue = Get-OptionalProperty $Entry 'updatesFailed' $null
    $skippedValue = Get-OptionalProperty $Entry 'updatesSkipped' $null
    $selectedValue = Get-OptionalProperty $Entry 'updatesSelected' $null
    $notSelectedValue = Get-OptionalProperty $Entry 'updatesNotSelected' $null
    $errorCategory = [string](Get-OptionalProperty $Entry 'errorCategory' '')
    if ($errorCategory -eq 'incomplete-parse') {
        $counts = 'Update details incomplete'
    }
    elseif ($null -ne $installedValue -and $null -ne $failedValue -and $null -ne $skippedValue) {
        $counts = "$found detected"
        if($null -ne $selectedValue){$counts += "  |  $selectedValue selected"}
        $counts += "  |  $installedValue installed  |  $failedValue failed"
        if([int]$skippedValue -gt 0){$counts += "  |  $skippedValue skipped"}
        if($null -ne $notSelectedValue -and [int]$notSelectedValue -gt 0){$counts += "  |  $notSelectedValue not selected"}
    }
    elseif ($found -gt 0) {
        $counts = "$found found  |  Installation breakdown not reported by Winget"
    }
    else {
        $counts = '0 found  |  0 installed  |  0 failed  |  0 skipped'
    }
    $duration = [double](Get-OptionalProperty $Entry 'durationSeconds' 0)
    $durationText = if ($duration -ge 60) { '{0:N1} min' -f ($duration / 60) } else { '{0:N1} s' -f $duration }
    return [PSCustomObject]@{
        Raw=$Entry; Id=[string]$Entry.id; DateText=$started.ToString('d',$culture); TimeText=$started.ToString('t',$culture); RunTypeText=Get-RunTypeText ([string]$Entry.runType); StatusText=Get-HistoryStatusText ([string]$Entry.status); StatusBrush=$brushConverter.ConvertFromString((Get-HistoryStatusColor ([string]$Entry.status))); Message=[string](Get-OptionalProperty $Entry 'message' 'No summary was recorded.'); CountsText=$counts; DurationText=$durationText; RestartText=if([bool](Get-OptionalProperty $Entry 'restartRequired' $false)){'Restart required'}else{''}
    }
}

function Refresh-History {
    try { Invoke-OrbitHistoryRetention } catch { }
    $entries = @(Get-OrbitHistory)
    $display = @()
    foreach ($entry in $entries) { try { $display += ConvertTo-HistoryDisplayItem -Entry $entry } catch { } }
    $HistoryList.ItemsSource = $display
    $hasEntries = $display.Count -gt 0
    $HistoryList.Visibility = if ($hasEntries) { 'Visible' } else { 'Collapsed' }
    $HistoryEmptyText.Visibility = if ($hasEntries) { 'Collapsed' } else { 'Visible' }
    $ClearHistoryButton.IsEnabled = $hasEntries
    $HistoryDetailsButton.IsEnabled=$false; $HistoryLogButton.IsEnabled=$false; $DeleteHistoryButton.IsEnabled=$false
    $HistorySelectionHint.Text='Select a run to view its details or log.'
}

function Open-LogFolder {
    if (-not (Test-Path -LiteralPath $logRoot)) { New-Item -ItemType Directory -Path $logRoot -Force | Out-Null }
    Start-Process -FilePath explorer.exe -ArgumentList ('"{0}"' -f $logRoot) | Out-Null
}

function Open-HistoryLog {
    param($Entry)
    $fileName = [IO.Path]::GetFileName([string](Get-OptionalProperty $Entry 'logFile' ''))
    if ([string]::IsNullOrWhiteSpace($fileName)) { Show-Banner 'No technical log is associated with this history entry.' Warning; return }
    $path = Join-Path $logRoot $fileName
    if (Test-Path -LiteralPath $path) { Start-Process -FilePath $path | Out-Null }
    else { [Windows.MessageBox]::Show('The associated technical log is no longer available.',$productName,'OK','Information') | Out-Null }
}

function Show-HistoryDetails {
    param($Entry)
    if ($null -eq $Entry) { throw 'The selected History entry is no longer available.' }
    $background = if($script:effectiveTheme -eq 'Dark'){'#172033'}else{'#FFFFFF'}
    $foreground = if($script:effectiveTheme -eq 'Dark'){'#F2F4F7'}else{'#172033'}
    $muted = if($script:effectiveTheme -eq 'Dark'){'#98A2B3'}else{'#667085'}
    $detailXaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml" Title="Run details - Orbit Updater" Width="720" Height="560" WindowStartupLocation="CenterOwner" ShowInTaskbar="False" Background="$background" FontFamily="Segoe UI Variable Text, Segoe UI">
 <Grid Margin="24"><Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="*"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
  <TextBlock Text="Run details" Foreground="$foreground" FontSize="21" FontWeight="SemiBold"/>
  <TextBlock x:Name="Summary" Grid.Row="1" Foreground="$muted" FontSize="11" TextWrapping="Wrap" Margin="0,10,0,16"/>
  <TextBox x:Name="Packages" Grid.Row="2" IsReadOnly="True" TextWrapping="Wrap" VerticalScrollBarVisibility="Auto" BorderThickness="1" BorderBrush="#475467" Background="$background" Foreground="$foreground" FontFamily="Cascadia Mono, Consolas" FontSize="11" Padding="14"/>
  <StackPanel Grid.Row="3" Orientation="Horizontal" HorizontalAlignment="Right" Margin="0,16,0,0"><Button x:Name="OpenLog" Content="Open log" Padding="14,8" Margin="0,0,8,0"/><Button x:Name="Close" Content="Close" Padding="14,8"/></StackPanel>
 </Grid>
</Window>
"@
    [xml]$detailXml=$detailXaml; $reader=New-Object Xml.XmlNodeReader $detailXml; $dialog=[Windows.Markup.XamlReader]::Load($reader); $dialog.Owner=$window; if(Test-Path $iconPath){try{$dialog.Icon=$window.Icon}catch{}}
    $startedText = 'Date and time unavailable'
    $finishedText = ''
    $startedValue = Get-OptionalProperty $Entry 'startedAt' $null
    $finishedValue = Get-OptionalProperty $Entry 'finishedAt' $null
    if ($null -ne $startedValue) {
        try {
            $started = (ConvertTo-OrbitDateTimeOffset -Value $startedValue).ToLocalTime()
            $startedText = $started.ToString('f', [Globalization.CultureInfo]::CurrentCulture)
        }
        catch { }
    }
    if ($null -ne $finishedValue) {
        try {
            $finished = (ConvertTo-OrbitDateTimeOffset -Value $finishedValue).ToLocalTime()
            $finishedText = ' - ' + $finished.ToString('T', [Globalization.CultureInfo]::CurrentCulture)
        }
        catch { }
    }
    $runType = [string](Get-OptionalProperty $Entry 'runType' '')
    $historyStatus = [string](Get-OptionalProperty $Entry 'status' '')
    $dialog.FindName('Summary').Text = "$(Get-RunTypeText $runType)  |  $(Get-HistoryStatusText $historyStatus)`n$startedText$finishedText`n$([string](Get-OptionalProperty $Entry 'message' ''))"
    $packages=@(Get-OptionalProperty $Entry 'packages' @())
    if($packages.Count -eq 0){$packageText='No reliable package-level data was recorded for this run.'}else{$lines=foreach($package in $packages){$resultCode=[string](Get-OptionalProperty $package 'result' 'not-reported');$resultText=switch($resultCode){'available'{'Available'}'installed'{'Installed'}'installed-restart-required'{'Installed - restart required'}'failed'{'Failed'}'skipped'{'Skipped'}'not-selected'{'Not selected'}default{'Not reported'}};"$([string](Get-OptionalProperty $package 'applicationName' 'Unknown application'))`n  $([string](Get-OptionalProperty $package 'oldVersion' 'Unknown')) -> $([string](Get-OptionalProperty $package 'newVersion' 'Unknown'))`n  Result: $resultText`n  $([string](Get-OptionalProperty $package 'message' ''))"};$packageText=$lines -join "`r`n`r`n"}
    $dialog.FindName('Packages').Text=$packageText
    $dialog.FindName('OpenLog').Add_Click({Open-HistoryLog -Entry $Entry})
    $dialog.FindName('Close').Add_Click({$dialog.Close()})
    [void]$dialog.ShowDialog()
}

function ConvertTo-ProcessArguments {
    param([string[]]$Arguments)
    return (($Arguments | ForEach-Object { if($_ -match '[\s"]'){'"'+($_ -replace '"','\"')+'"'}else{$_} }) -join ' ')
}

function Start-HiddenEngine {
    param([string[]]$EngineArguments=@())
    if (-not (Test-Path -LiteralPath $launcherPath -PathType Leaf)) {
        throw 'The background launcher is missing. Run Setup.cmd again to repair the app.'
    }

    if (-not (Test-Path -LiteralPath $scriptHostPath -PathType Leaf)) {
        throw 'The Windows Script Host is unavailable.'
    }

    $arguments=@($launcherPath,'--engine')+$EngineArguments
    $argumentText=ConvertTo-ProcessArguments $arguments
    try {
        $startInfo=New-Object Diagnostics.ProcessStartInfo; $startInfo.FileName=$scriptHostPath; $startInfo.Arguments=$argumentText; $startInfo.UseShellExecute=$false; $startInfo.CreateNoWindow=$true; $startInfo.WindowStyle=[Diagnostics.ProcessWindowStyle]::Hidden; $startInfo.WorkingDirectory=$PSScriptRoot
        $process=New-Object Diagnostics.Process; $process.StartInfo=$startInfo; if(-not $process.Start()){throw 'Process could not start.'}; return $process
    }
    catch { throw "The operation could not be started: $($_.Exception.Message)" }
}

function Stop-OrbitProcessTree {
    param([int]$ProcessId)
    if ($ProcessId -le 0 -or $ProcessId -eq $PID) { return }

    try {
        $children = @(Get-CimInstance Win32_Process -Filter "ParentProcessId = $ProcessId" -ErrorAction SilentlyContinue)
        foreach ($child in $children) { Stop-OrbitProcessTree -ProcessId ([int]$child.ProcessId) }
        Stop-Process -Id $ProcessId -Force -ErrorAction SilentlyContinue
    }
    catch { }
}

function Test-IsAdministrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Test-OrbitEngineBusy {
    $probe = $null
    $acquired = $false
    try {
        try { $probe = [Threading.Mutex]::OpenExisting('Local\WingetAutoUpdater.Engine') }
        catch [Threading.WaitHandleCannotBeOpenedException] { return $false }
        $acquired = $probe.WaitOne(0)
        return (-not $acquired)
    }
    catch {
        return $false
    }
    finally {
        if ($acquired -and $null -ne $probe) { try { $probe.ReleaseMutex() } catch { } }
        if ($null -ne $probe) { $probe.Dispose() }
    }
}

function Start-CheckOnly {
    if($null -ne $script:engineWorker -or $script:waitingForScheduledRun){return}
    if(Test-OrbitEngineBusy){Show-Banner 'Another Winget operation is already running.' Warning;return}
    $script:overviewStatusOverride=''
    $script:currentOperation='Overview.CheckOnly'
    $script:activeTechnicalCommands=@()
    $script:technicalCommandMode='Check';Update-TechnicalCommandBlock
    $script:engineWorker=Start-HiddenEngine -EngineArguments @('-CheckOnly')
    if($null -ne $script:engineWorker){Set-OverviewStatus Checking;Set-Activity $true 'Checking Winget-managed applications...';Show-Banner 'Checking for available Winget updates...' Checking -Persistent}
}

function Start-UpdateNow {
    param([ValidateSet('manual','startup')][string]$Mode='manual')
    if($null -ne $script:engineWorker -or $script:waitingForScheduledRun){return}
    if(Test-OrbitEngineBusy){Show-Banner 'Another Winget operation is already running.' Warning;return}
    $selectedPackages=@(if($Mode -eq 'manual'){Get-SelectedAvailablePackages})
    $selectedIds=@($selectedPackages|ForEach-Object{[string]$_.Id}|Select-Object -Unique)
    if($Mode -eq 'manual' -and $selectedIds.Count -eq 0){Update-InstallSelectionState;return}
    $script:overviewStatusOverride=''
    $script:currentOperation=if($Mode -eq 'startup'){'Automation.StartupInstallation'}else{'Overview.InstallSelectedUpdates'}
    $script:technicalCommandMode='Update';Update-TechnicalCommandBlock
    $script:activeTechnicalCommands=@(if($selectedPackages.Count -gt 0){$selectedPackages|ForEach-Object{Get-OrbitWingetCommandText -Operation Update -Configuration $script:configuration -PackageId ([string]$_.Id) -PackageSource ([string]$_.Source)}})
    Update-TechnicalCommandBlock
    try {
        Remove-Item -LiteralPath $liveProgressPath -Force -ErrorAction SilentlyContinue
        Reset-LiveInstallationProgressVisual
        $request=[ordered]@{requestedAt=[DateTimeOffset]::Now.ToString('o');requestId=[Guid]::NewGuid().ToString('D');mode=$Mode}
        if($Mode -eq 'manual'){
            $request.selectedPackageIds=@($selectedIds)
            $request.selectedPackages=@($selectedPackages|ForEach-Object{[ordered]@{id=[string]$_.Id;source=[string]$_.Source}})
            $request.detectedCount=@($script:availableUpdateItems).Count
        }
        Write-OrbitJsonFile -Path $manualRequestPath -Value $request
        $task=Get-OrbitRegisteredTask -Name $taskName
        if($null -ne $task -and [bool]$task.Enabled){
            $script:scheduledRequestTime=[DateTimeOffset]::Now;$script:waitingForScheduledRun=$true;[void]$task.Run($null);Set-OverviewStatus Installing;Set-Activity $true 'Starting the background update...';Show-Banner 'Installing selected updates...' Installing -Persistent
        }elseif(Test-IsAdministrator){
            $script:engineWorker=Start-HiddenEngine
            if($null -ne $script:engineWorker){Set-OverviewStatus Installing;Set-Activity $true 'Installing selected Winget updates...';Show-Banner 'Installing selected updates...' Installing -Persistent}
        }else{
            Remove-Item -LiteralPath $manualRequestPath -Force -ErrorAction SilentlyContinue
            Set-OverviewStatusOverride InstallationFailed;Set-Activity $false
            Show-Banner 'The background update task is unavailable. Run Setup.cmd once to repair it, then try again.' Error
        }
    }
    catch {Remove-Item -LiteralPath $manualRequestPath -Force -ErrorAction SilentlyContinue;Set-OverviewStatusOverride InstallationFailed;Set-Activity $false;throw}
}

function Refresh-Dashboard {
    Refresh-TaskStatus
    Refresh-State
    if(Test-Path $updatesPath){$write=(Get-Item $updatesPath).LastWriteTimeUtc;if($write -ne $script:lastUpdatesWrite){$script:lastUpdatesWrite=$write;Refresh-AvailableUpdates}}else{Refresh-AvailableUpdates}
    if($script:selectedPage -eq 'History'){
        if(Test-Path $historyPath){$historyWrite=(Get-Item $historyPath).LastWriteTimeUtc;if($historyWrite -ne $script:lastHistoryWrite){$script:lastHistoryWrite=$historyWrite;Refresh-History}}
    }
}

$intervalSaveTimer=New-Object Windows.Threading.DispatcherTimer
$intervalSaveTimer.Interval=[TimeSpan]::FromMilliseconds(50)
$intervalSaveTimer.Add_Tick({ Invoke-IntervalSaveTick })

$script:bannerTimer = New-Object Windows.Threading.DispatcherTimer
$script:bannerTimer.Add_Tick({ Invoke-BannerTimerTick })

$OverviewNavButton.Add_Click({[void](Invoke-OrbitUiAction -Operation 'Navigation.Overview' -Action {Show-AppPage Overview})})
$HistoryNavButton.Add_Click({[void](Invoke-OrbitUiAction -Operation 'Navigation.History' -Action {Show-AppPage History})})
$SettingsNavButton.Add_Click({[void](Invoke-OrbitUiAction -Operation 'Navigation.Settings' -Action {Show-AppPage Settings})})
$ThemeSystemOption.Add_MouseLeftButtonUp({$ThemeSystemRadio.IsChecked=$true})
$ThemeLightOption.Add_MouseLeftButtonUp({$ThemeLightRadio.IsChecked=$true})
$ThemeDarkOption.Add_MouseLeftButtonUp({$ThemeDarkRadio.IsChecked=$true})
$ThemeSystemRadio.Add_Checked({if(-not $script:suppressThemeEvents){[void](Invoke-OrbitUiAction -Operation 'Settings.Theme.System' -Action {Set-ThemePreference System -Persist})}})
$ThemeLightRadio.Add_Checked({if(-not $script:suppressThemeEvents){[void](Invoke-OrbitUiAction -Operation 'Settings.Theme.Light' -Action {Set-ThemePreference Light -Persist})}})
$ThemeDarkRadio.Add_Checked({if(-not $script:suppressThemeEvents){[void](Invoke-OrbitUiAction -Operation 'Settings.Theme.Dark' -Action {Set-ThemePreference Dark -Persist})}})

$automaticUpdatesChanged={
    if($script:suppressAutoEvents){return}
    [void](Invoke-OrbitUiAction -Operation 'Overview.AutomaticUpdatesToggle' -Action {
        $desired=[bool]$AutomaticUpdatesToggle.IsChecked;$script:automaticUpdatesEnabled=$desired
        $script:configuration=Save-OrbitConfiguration -Changes @{automaticUpdatesEnabled=$desired}
        Set-AutomaticUpdateVisual -Enabled $desired
        if($desired -and -not $script:schedulingReady){$AutoStatusTitle.Text='Automatic checks need setup';$AutoStatusDetail.Text='Run Setup.cmd once to repair the background task.';Show-Banner 'Automatic checks were enabled, but the background task needs repair. Run Setup.cmd once.' Warning}
        else{$automaticBannerMessage=if($desired){'Automatic checks are on.'}else{'Automatic checks are off.'};Show-Banner $automaticBannerMessage Success}
    })
}
$AutomaticUpdatesToggle.Add_Checked($automaticUpdatesChanged)
$AutomaticUpdatesToggle.Add_Unchecked($automaticUpdatesChanged)

$automaticInstallationChanged={
    if($script:suppressAutomationEvents){return}
    [void](Invoke-OrbitUiAction -Operation 'Settings.AutomaticInstallationToggle' -Action {
        $enabled=[bool]$AutomaticInstallationToggle.IsChecked
        $script:configuration=Save-OrbitConfiguration -Changes @{automaticInstallationEnabled=$enabled}
        Set-AutomationSettingsVisual
        Show-Banner $(if($enabled){'Automatic installation is on.'}else{'Automatic installation is off.'}) Success
    })
}
$AutomaticInstallationToggle.Add_Checked($automaticInstallationChanged)
$AutomaticInstallationToggle.Add_Unchecked($automaticInstallationChanged)

$startupInstallationChanged={
    if($script:suppressAutomationEvents){return}
    [void](Invoke-OrbitUiAction -Operation 'Settings.StartupInstallationToggle' -Action {
        $enabled=[bool]$StartupInstallationToggle.IsChecked
        if($enabled -and -not [bool]$script:configuration.automaticInstallationEnabled){return}
        $script:configuration=Save-OrbitConfiguration -Changes @{installOnStartupEnabled=$enabled}
        Set-AutomationSettingsVisual
    })
}
$StartupInstallationToggle.Add_Checked($startupInstallationChanged)
$StartupInstallationToggle.Add_Unchecked($startupInstallationChanged)

$notificationsChanged={
    if($script:suppressAutomationEvents){return}
    [void](Invoke-OrbitUiAction -Operation 'Settings.NotificationsToggle' -Action {
        $script:configuration=Save-OrbitConfiguration -Changes @{notificationsEnabled=[bool]$NotificationsToggle.IsChecked}
        Set-AutomationSettingsVisual
    })
}
$NotificationsToggle.Add_Checked($notificationsChanged)
$NotificationsToggle.Add_Unchecked($notificationsChanged)

$script:intervalHitTargets = @($IntervalHit1,$IntervalHit3,$IntervalHit6,$IntervalHit12,$IntervalHit24)
$intervalLabelClicked = {
    param($sender, $eventArgs)
    [void](Invoke-OrbitUiAction -Operation 'Overview.IntervalLabel' -Action {
        if (Set-IntervalFromLabel -Sender $sender) { $eventArgs.Handled = $true }
    })
}
foreach ($intervalHitTarget in $script:intervalHitTargets) {
    $intervalHitTarget.Add_MouseLeftButtonUp($intervalLabelClicked)
}

$availableSelectionChanged = [Windows.RoutedEventHandler]{
    param($sender,$eventArgs)
    if($script:isShuttingDown){return}
    [void](Invoke-OrbitUiAction -Operation 'Overview.UpdateSelection' -Background -Action {
        $checkbox=$eventArgs.OriginalSource
        if($null -ne $checkbox -and $null -ne $checkbox.DataContext -and $null -ne $checkbox.DataContext.PSObject.Properties['IsSelected']){
            $checkbox.DataContext.IsSelected=[bool]$checkbox.IsChecked
        }
        Update-InstallSelectionState
        if($script:technicalCommandMode -eq 'Update' -and @($script:activeTechnicalCommands).Count -eq 0){Update-TechnicalCommandBlock}
    })
}
$AvailableUpdatesItems.AddHandler([Windows.Controls.Primitives.ToggleButton]::CheckedEvent,$availableSelectionChanged)
$AvailableUpdatesItems.AddHandler([Windows.Controls.Primitives.ToggleButton]::UncheckedEvent,$availableSelectionChanged)

$IntervalSlider.Add_ValueChanged({
    if (-not $script:windowInitialized -or $script:suppressIntervalEvents) { return }
    [void](Invoke-OrbitUiAction -Operation 'Overview.IntervalSlider' -Action {
        $sliderValue = [double]$IntervalSlider.Value
        if ([double]::IsNaN($sliderValue) -or [double]::IsInfinity($sliderValue)) { return }
        $index = [int][Math]::Round($sliderValue)
        if ($index -lt 0 -or $index -ge $script:intervalOptions.Count) { return }
        $hours=Update-IntervalVisual
        if($script:automaticUpdatesEnabled){Request-IntervalSave -Hours $hours}
    })
})

$RunButton.Add_Click({$completed=Invoke-OrbitUiAction -Operation 'Overview.InstallSelectedUpdates' -Action {Start-UpdateNow -Mode manual};if(-not $completed){Set-OverviewStatusOverride InstallationFailed}})
$CheckButton.Add_Click({$completed=Invoke-OrbitUiAction -Operation 'Overview.CheckOnly' -Action {Start-CheckOnly};if(-not $completed){Set-OverviewStatusOverride CheckFailed}})
$CopyTechnicalCommandButton.Add_Click({[void](Invoke-OrbitUiAction -Operation 'Overview.CopyTechnicalCommand' -FailureMessage 'The Winget command could not be copied.' -Action {if(-not [string]::IsNullOrWhiteSpace($TechnicalCommandText.Text)){[Windows.Clipboard]::SetText($TechnicalCommandText.Text);Show-Banner 'The Winget command was copied.' Success}})})
$ActivityOutputTextBox.Add_TextChanged({if(-not $script:isShuttingDown){try{$ActivityOutputTextBox.ScrollToEnd()}catch{[void](Write-OrbitCrashReport -Operation 'Overview.ActivityScroll' -ErrorRecord $_ -Context (Get-OrbitUiCrashContext))}}})
$ActivityOpenLogButton.Add_Click({[void](Invoke-OrbitUiAction -Operation 'Overview.OpenActivityLog' -Action {if(-not [string]::IsNullOrWhiteSpace([string]$script:activityLogPath) -and (Test-Path -LiteralPath $script:activityLogPath -PathType Leaf)){Start-Process -FilePath $script:activityLogPath | Out-Null}else{Open-LogFolder}})})
$OpenLogFolderButton.Add_Click({[void](Invoke-OrbitUiAction -Operation 'Settings.OpenLogFolder' -Action {Open-LogFolder})})

$technicalDetailsChanged={if(-not $script:suppressSettingsEvents){[void](Invoke-OrbitUiAction -Operation 'Settings.TechnicalDetailsToggle' -Action {$enabled=[bool]$TechnicalDetailsToggle.IsChecked;$script:configuration=Save-OrbitConfiguration -Changes @{showTechnicalDetails=$enabled};Update-TechnicalCommandBlock})}}
$TechnicalDetailsToggle.Add_Checked($technicalDetailsChanged)
$TechnicalDetailsToggle.Add_Unchecked($technicalDetailsChanged)
$taskbarStatusBadgeChanged={if(-not $script:suppressSettingsEvents){[void](Invoke-OrbitUiAction -Operation 'Settings.TaskbarStatusBadgeToggle' -Action {$enabled=[bool]$TaskbarStatusBadgeToggle.IsChecked;$script:configuration=Save-OrbitConfiguration -Changes @{showTaskbarStatusBadge=$enabled};$presentation=Get-OverviewStatusPresentation -State $script:authoritativeOverviewState;Update-TaskbarStatusBadge -State $script:authoritativeOverviewState -Color $presentation.Foreground})}}
$TaskbarStatusBadgeToggle.Add_Checked($taskbarStatusBadgeChanged)
$TaskbarStatusBadgeToggle.Add_Unchecked($taskbarStatusBadgeChanged)
$DeleteLogsToggle.Add_Click({if(-not $script:suppressSettingsEvents){[void](Invoke-OrbitUiAction -Operation 'Settings.DeleteLogsToggle' -Action {$script:configuration=Save-OrbitConfiguration -Changes @{deleteLogsWithHistory=[bool]$DeleteLogsToggle.IsChecked}})}})

function Set-RetentionPreference {
    param([int]$Days)
    if($script:suppressRetentionEvents){return}
    $old=[int](Get-OrbitConfiguration).historyRetentionDays
    if($Days -eq $old){return}
    $expired=@()
    if($Days -gt 0){$cutoff=[DateTimeOffset]::Now.AddDays(-$Days);$expired=@(Get-OrbitHistory|Where-Object{try{(ConvertTo-OrbitDateTimeOffset -Value $_.startedAt)-lt $cutoff}catch{$false}})}
    if($expired.Count -gt 0){$deleteLogs=[bool](Get-OrbitConfiguration).deleteLogsWithHistory;$message="This will remove $($expired.Count) expired history entries."+$(if($deleteLogs){' Their associated raw logs will also be deleted.'}else{' Their raw logs will be kept.'})+"`n`nContinue?";$answer=[Windows.MessageBox]::Show($message,'Change history retention','YesNo','Warning');if($answer -ne 'Yes'){$script:suppressRetentionEvents=$true;$Retention30Radio.IsChecked=($old -eq 30);$Retention90Radio.IsChecked=($old -eq 90);$RetentionUnlimitedRadio.IsChecked=($old -eq 0);$script:suppressRetentionEvents=$false;return}}
    $script:configuration=Save-OrbitConfiguration -Changes @{historyRetentionDays=$Days};Invoke-OrbitHistoryRetention;Refresh-History
}
$Retention30Radio.Add_Checked({[void](Invoke-OrbitUiAction -Operation 'Settings.Retention30' -Action {Set-RetentionPreference 30})})
$Retention90Radio.Add_Checked({[void](Invoke-OrbitUiAction -Operation 'Settings.Retention90' -Action {Set-RetentionPreference 90})})
$RetentionUnlimitedRadio.Add_Checked({[void](Invoke-OrbitUiAction -Operation 'Settings.RetentionUnlimited' -Action {Set-RetentionPreference 0})})

$HistoryList.Add_SelectionChanged({[void](Invoke-OrbitUiAction -Operation 'History.SelectionChanged' -Background -Action {$selected=$HistoryList.SelectedItem;$has=$null -ne $selected;$HistoryDetailsButton.IsEnabled=$has;$HistoryLogButton.IsEnabled=$has;$DeleteHistoryButton.IsEnabled=$has;$HistorySelectionHint.Text=if($has){"Selected: $($selected.RunTypeText) at $($selected.TimeText)"}else{'Select a run to view its details or log.'}})})
$HistoryDetailsButton.Add_Click({[void](Invoke-OrbitUiAction -Operation 'History.OpenDetails' -FailureMessage 'The selected run details are unavailable. Orbit Updater is still open.' -Action {if($null -ne $HistoryList.SelectedItem){Show-HistoryDetails -Entry $HistoryList.SelectedItem.Raw}})})
$HistoryLogButton.Add_Click({[void](Invoke-OrbitUiAction -Operation 'History.OpenLog' -FailureMessage 'The selected technical log could not be opened.' -Action {if($null -ne $HistoryList.SelectedItem){Open-HistoryLog -Entry $HistoryList.SelectedItem.Raw}})})
$DeleteHistoryButton.Add_Click({[void](Invoke-OrbitUiAction -Operation 'History.DeleteEntry' -Action {if($null -eq $HistoryList.SelectedItem){return};$answer=[Windows.MessageBox]::Show('Delete this history entry?','Delete entry','YesNo','Warning');if($answer -eq 'Yes'){$config=Get-OrbitConfiguration;Remove-OrbitHistoryEntry -Id $HistoryList.SelectedItem.Id -DeleteAssociatedLog ([bool]$config.deleteLogsWithHistory);Refresh-History}})})
$ClearHistoryButton.Add_Click({[void](Invoke-OrbitUiAction -Operation 'History.Clear' -Action {$entries=@(Get-OrbitHistory);if($entries.Count -eq 0){return};$config=Get-OrbitConfiguration;$message="Clear all $($entries.Count) history entries?"+$(if([bool]$config.deleteLogsWithHistory){' Associated raw logs will also be deleted.'}else{' Raw logs will be kept.'});$answer=[Windows.MessageBox]::Show($message,'Clear history','YesNo','Warning');if($answer -eq 'Yes'){Clear-OrbitHistory -DeleteAssociatedLogs ([bool]$config.deleteLogsWithHistory);Refresh-History}})})

$timer=New-Object Windows.Threading.DispatcherTimer
$timer.Interval=[TimeSpan]::FromMilliseconds(250)
$timer.Add_Tick({
    [void](Invoke-OrbitUiAction -Operation 'Application.Refresh' -Background -Action {
        $now=[DateTimeOffset]::UtcNow
        $performSlowRefresh=$script:lastSlowRefreshAt -eq [DateTimeOffset]::MinValue -or $now.Subtract($script:lastSlowRefreshAt).TotalMilliseconds -ge 2000
        if($performSlowRefresh){
            $script:lastSlowRefreshAt=$now
            if($script:themePreference -eq 'System'){Set-EffectiveTheme (Get-SystemTheme)}
            Refresh-Dashboard
        }
        Refresh-LiveInstallationProgress

        if($null -ne $script:engineWorker){
            if($script:engineWorker.HasExited){
                $code=$script:engineWorker.ExitCode
                $script:lastWingetExitCode=$code
                $script:engineWorker.Dispose()
                $script:engineWorker=$null
                $script:currentOperation=''
                Set-Activity $false
                Refresh-LiveInstallationProgress
                Refresh-Dashboard
                Refresh-History
                $completedState=$null
                if(Test-Path -LiteralPath $statePath){try{$completedState=Get-Content -LiteralPath $statePath -Raw -Encoding UTF8|ConvertFrom-Json}catch{}}
                $completedStatus=[string](Get-OptionalProperty $completedState 'status' '')
                if($code -eq 0 -and $script:technicalCommandMode -eq 'Check' -and $completedStatus -eq 'UpdatesAvailable'){Show-Banner 'Updates were found and are ready to install.' UpdatesAvailable}
                elseif($code -eq 0 -and $script:technicalCommandMode -eq 'Check'){Show-Banner 'The Winget operation completed. No updates are available.' Success}
                elseif($completedStatus -eq 'CompletedWithIssues'){Show-Banner ([string](Get-OptionalProperty $completedState 'message' 'The Winget operation completed with issues.')) Warning}
                elseif($code -eq 0){Show-Banner ([string](Get-OptionalProperty $completedState 'message' 'The update installation completed.')) Success}
                elseif($script:technicalCommandMode -eq 'Check'){Show-Banner ([string](Get-OptionalProperty $completedState 'message' 'The update check failed.')) Error}
                else{Show-Banner ([string](Get-OptionalProperty $completedState 'message' 'The update installation failed.')) Error}
            }
        }

        if($performSlowRefresh -and $script:waitingForScheduledRun -and $null -ne $script:scheduledRequestTime){
            $state=$null
            if(Test-Path $statePath){
                try{$state=Get-Content $statePath -Raw -Encoding UTF8|ConvertFrom-Json}
                catch{[void](Write-OrbitCrashReport -Operation 'Scheduler.StateRead' -ErrorRecord $_ -Context (Get-OrbitUiCrashContext))}
            }
            if($null -ne $state -and $null -ne (Get-OptionalProperty $state 'startedAt' $null)){
                try{
                    $stateStarted=ConvertTo-OrbitDateTimeOffset -Value $state.startedAt
                    if($stateStarted -ge $script:scheduledRequestTime -and [string]$state.status -ne 'Running'){
                        $script:waitingForScheduledRun=$false
                        $script:lastWingetExitCode=Get-OptionalProperty $state 'exitCode' $null
                        $script:currentOperation=''
                        Set-Activity $false
                        Refresh-LiveInstallationProgress
                        Refresh-Dashboard
                        Refresh-History
                        if([string]$state.status -eq 'RestartRequired'){Show-Banner ([string]$state.message) Warning}
                        elseif([string]$state.status -eq 'CompletedWithIssues'){Show-Banner ([string]$state.message) Warning}
                        elseif([string]$state.status -in @('Success','NoUpdates')){Show-Banner ([string](Get-OptionalProperty $state 'message' 'The update installation completed.')) Success}
                        else{Show-Banner ([string](Get-OptionalProperty $state 'message' 'The update installation failed.')) Error}
                    }
                }
                catch{[void](Write-OrbitCrashReport -Operation 'Scheduler.Completion' -ErrorRecord $_ -Context (Get-OrbitUiCrashContext))}
            }
            if([DateTimeOffset]::Now.Subtract($script:scheduledRequestTime).TotalSeconds -gt 60 -and ($null -eq $state -or [string]$state.status -ne 'Running')){
                $script:waitingForScheduledRun=$false
                $script:currentOperation=''
                Set-Activity $false
                Set-OverviewStatusOverride InstallationFailed
                Show-Banner 'The background task did not start in time. Run Setup.cmd to repair scheduling.' Error
            }
        }
    })
})

$window.Add_Loaded({
    $loaded = Invoke-OrbitUiAction -Operation 'Application.Startup' -Action {
        Set-ThemePreference -Theme ([string](Get-OrbitConfiguration).theme)
        $script:configuration=Get-OrbitConfiguration
        $script:suppressSettingsEvents=$true;$TechnicalDetailsToggle.IsChecked=[bool]$script:configuration.showTechnicalDetails;$TaskbarStatusBadgeToggle.IsChecked=[bool]$script:configuration.showTaskbarStatusBadge;$DeleteLogsToggle.IsChecked=[bool]$script:configuration.deleteLogsWithHistory;$script:suppressSettingsEvents=$false
        Set-AutomationSettingsVisual
        $script:suppressRetentionEvents=$true;$Retention30Radio.IsChecked=([int]$script:configuration.historyRetentionDays -eq 30);$Retention90Radio.IsChecked=([int]$script:configuration.historyRetentionDays -eq 90);$RetentionUnlimitedRadio.IsChecked=([int]$script:configuration.historyRetentionDays -eq 0);$script:suppressRetentionEvents=$false
        try{Invoke-OrbitHistoryRetention}catch{[void](Write-OrbitCrashReport -Operation 'History.Retention' -ErrorRecord $_ -Context (Get-OrbitUiCrashContext))}
        Show-AppPage Overview;Refresh-Dashboard;Refresh-LiveInstallationProgress;Refresh-History
        $script:windowInitialized=$true
        $script:currentOperation=''
    }
    if($SmokeTest){$window.Close();return}
    if($loaded){
        $timer.Start()
        if([bool]$script:configuration.automaticInstallationEnabled -and [bool]$script:configuration.installOnStartupEnabled){
            [void]$window.Dispatcher.BeginInvoke([Action]{[void](Invoke-OrbitUiAction -Operation 'Automation.StartupInstallation' -Action {Start-UpdateNow -Mode startup})})
        }
    }
})

$window.Dispatcher.Add_UnhandledException({
    param($sender,$eventArgs)
    try {
        $dispatcherOperation=if([string]::IsNullOrWhiteSpace($script:currentOperation)){'Application.Dispatcher'}else{$script:currentOperation}
        [void](Write-OrbitCrashReport -Operation $dispatcherOperation -Exception $eventArgs.Exception -Context (Get-OrbitUiCrashContext))
        Set-Activity $false
        Show-Banner 'Orbit Updater recovered from an unexpected error. You can retry the action.' Error
        $eventArgs.Handled=$true
    }
    catch { }
})

$window.Add_Closing({
    param($sender, $eventArgs)
    if ($null -ne $script:intervalSaveWorker -or ($null -ne $script:pendingIntervalHours -and -not $script:intervalSaveFailed)) {
        # Finish the latest preference asynchronously before normal shutdown.
        # A failed save leaves the window open with the existing error banner.
        $eventArgs.Cancel = $true
        $script:intervalCloseRequested = $true
        $script:intervalSaveDueAt = [DateTimeOffset]::MinValue
        $intervalSaveTimer.Start()
    }
})

$window.Add_Closed({
    $script:isShuttingDown=$true
    $script:currentOperation='Application.Shutdown'
    $timer.Stop()
    $intervalSaveTimer.Stop()
    if($null -ne $script:bannerTimer){$script:bannerTimer.Stop()}
    try { if($null -ne $window.TaskbarItemInfo){$window.TaskbarItemInfo.Overlay=$null} } catch { }
    $script:pendingIntervalHours=$null
    if($null -ne $script:engineWorker){
        try {
            if(-not $script:engineWorker.HasExited){Stop-OrbitProcessTree -ProcessId $script:engineWorker.Id}
            $script:engineWorker.Dispose()
        }
        catch { }
        $script:engineWorker=$null
    }
    Reset-LiveInstallationProgressVisual -HidePanel
})

try {
    [void]$window.ShowDialog()
}
catch {
    $unhandledOperation=if([string]::IsNullOrWhiteSpace($script:currentOperation)){'Application.Unhandled'}else{$script:currentOperation}
    [void](Write-OrbitCrashReport -Operation $unhandledOperation -ErrorRecord $_ -Context (Get-OrbitUiCrashContext))
    try {
        [Windows.MessageBox]::Show('Orbit Updater encountered an unexpected error and closed safely. A crash report was saved for troubleshooting.',$productName,'OK','Error') | Out-Null
    }
    catch { }
    exit 1
}
