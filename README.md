# Orbit Updater 0.9.1-beta.1

Orbit Updater is a PowerShell 5.1 and WPF utility for Windows 11. It checks and installs updates offered through Windows Package Manager while keeping technical output out of the main interface by default.

This is a prerelease build intended for active testing.

## Install or upgrade

1. Keep this folder, including `assets`, together.
2. Double-click **Setup.cmd**.
3. Approve the Windows administrator prompt.

Setup installs the current-user app, creates Orbit Updater shortcuts, and configures separate periodic and sign-in Scheduled Tasks. Running Setup again upgrades the existing installation in place and preserves supported settings.

The visible product name changed to **Orbit Updater**. For upgrade compatibility, these internal identifiers intentionally remain unchanged:

- Install folder: `%LOCALAPPDATA%\Programs\Winget Auto Updater`
- Data folder: `%LOCALAPPDATA%\WingetAutoUpdater`
- Primary Scheduled Task: `Winget Auto Updater`

## Main interface

### Overview

- Shows the overall Winget update state, automatic-check state, interval, last run, and available package versions.
- **Check only** scans without installing.
- Available updates are selected by default. Clear a package checkbox to exclude it from the current manual installation only.
- The primary action says **Install all updates** when everything is selected and **Install selected updates** for a partial selection; it is disabled when nothing is selected.
- During installation, the action card shows the authoritative package name and queue position. A real 0–100% value is shown only when redirected Winget or installer output provides one; otherwise the compact progress bar remains indeterminate.
- The automatic-check switch controls periodic and Windows sign-in checks without automatically granting installation permission.
- The interval slider supports only 1, 3, 6, 12, and 24 hours, saves automatically, and does not recreate the Scheduled Task.

### History

Each run has a structured summary containing its run type, status, counts, duration, restart requirement, and reliable package information. A history entry can open its readable details or matching technical log, or be deleted after confirmation.

### Settings

- Appearance: System default, Light, or Dark.
- Automation:
  - **Automatic installation** allows scheduled checks to install updates and is off by default.
  - **Install updates automatically when Orbit starts** is available only when automatic installation is enabled and is off by default.
  - **Notify me when updates are available** controls concise local Windows notifications and is on by default.
- **Show technical details**: shows the compact effective Winget command and a bounded, read-only view of the latest raw run log on Overview. It is off by default.
- History retention: 30 days, 90 days, or Unlimited. The default is 90 days.
- Associated raw logs can either be retained or deleted with their history entries. Log deletion is off by default.

## Winget execution

An update run first performs a read-only discovery check. Each selected package is then targeted independently by its stable Winget ID, conceptually:

```text
winget upgrade --id <PackageId> --exact --include-unknown
```

A check-only run does not include an installation target. When unattended mode is enabled, Orbit Updater adds the applicable agreement, silent, and non-interactive flags. One package failure is recorded without aborting later packages; aggregate results distinguish success, completed with issues, and complete failure. Orbit performs a post-install check so installed packages disappear while failed or deliberately unselected updates remain available.

Winget is launched directly with .NET process APIs. Shell execution is disabled, no console window is created, standard output and error are redirected, and a named mutex prevents overlapping runs. The UI, shortcuts, and Scheduled Tasks use the built-in windowless Windows Script Host launcher instead of starting a console-hosted PowerShell process directly. Setup requests administrator approval once to register hidden highest-privilege tasks. Normal UI sessions never launch a `RunAs` child: manual installations use the registered task, while checks and ordinary settings remain unelevated. If that task is missing or disabled, the app asks the user to run Setup once instead of displaying another UAC prompt. An individual installer can still display its own UI if it does not honor Winget's silent option.

The periodic task wakes hourly. Before starting Winget, the engine reads the saved automatic-check state and selected 1/3/6/12/24-hour interval from the existing user-writable configuration, and exits quietly when no automatic run is due. Sign-in runs remain independent of the periodic interval. Automatic installation is a separate opt-in and reuses the same per-package queue as manual installation.

Orbit Updater never uninstalls an application or changes installer technology automatically.

## History and logs

Structured history is stored separately from raw logs:

```text
%LOCALAPPDATA%\WingetAutoUpdater\History\history.json
%LOCALAPPDATA%\WingetAutoUpdater\Logs\yyyy-MM-dd_HH-mm-ss_run-type.log
%LOCALAPPDATA%\OrbitUpdater\Logs\Crashes\yyyy-MM-dd_HH-mm-ss-operation.json
```

Every raw run log records the app version, run ID, start and end times, run type, exact command when one was started, Winget version, standard output, standard error, exit result, and restart requirement. Raw output is available through the optional Overview Activity section and the History page's per-run log action.

Parsing of the available-update table uses column position after Winget's table separator instead of localized header words. History records detected, selected, installed, failed, skipped, and not-selected counts plus safe package-level results. It does not invent package results when reliable data is unavailable.

## Notifications

Meaningful automatic results can produce local Windows notifications for available updates, successful installation, partial installation, or failure. Notification delivery is best-effort and cannot fail an update run. Identical unchanged results are deduplicated locally. Notification clicks use the `orbitupdater://overview` per-user protocol and the existing hidden launcher to open Orbit without a terminal window. Orbit adds no telemetry, analytics, accounts, or external notification service.

## Branding assets

The supplied Orbit artwork is preserved unchanged as `assets\orbit-logo-original.png`. Derived PNG sizes and `assets\orbit-updater.ico` provide the window, taskbar, sidebar, About, Start menu, and desktop shortcut artwork.

This distribution is a PowerShell script application and does not contain a standalone compiled executable. Therefore there is no separate PE executable resource to brand; installed shortcuts and the WPF window carry the official icon.

## Uninstall

Double-click **Uninstall.cmd**. Uninstall removes both Scheduled Tasks, current and legacy shortcuts, installed app files, structured history, and raw logs.

## Requirements

- Windows 11
- Windows PowerShell 5.1
- Microsoft App Installer / `winget.exe`
- Administrator approval for one-time setup, repair, and uninstall

## License

Copyright © 2026 Alperen Gökce. All rights reserved.

This repository is provided for portfolio and demonstration purposes.
No permission is granted to copy, modify, distribute, or reuse the source code.
