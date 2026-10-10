# Changelog

All notable changes to this project are documented here.
The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the project uses [Semantic Versioning](https://semver.org/).

## [3.0] - 2026-10-10

### Fixed
- Monthly cumulative updates were classified as feature updates, so the feature-update prompt appeared for ordinary patches and preview updates slipped past the preview filter. Preview is now checked first and feature updates are matched on their title or the `Upgrades` category.
- Event log analysis only read Error/Critical entries, so rules for events logged as Warnings (disk 51/153, WHEA 17/19, Display 4101, Resource-Exhaustion 2004) could never fire. Warnings are now included.
- The restore point was reported as created even when Windows silently skipped it (24-hour limit). The limit is lifted temporarily and the result is verified.
- Leftover `SoftwareDistribution.bak_*` folders were aged by their `LastWriteTime`, which a rename does not change. Age is now read from the timestamp in the folder name.
- The file system check covered only the system drive; it now scans every fixed NTFS volume.
- `-Auto` no longer installs the Windows 10 feature update or switches the firewall back on without a decision from the user.
- Pending-restart detection ignores harmless leftover temp-file renames and also checks `UpdateExeVolatile` and pending computer renames.
- Removed first-person wording from the support-status text, an unused SFC variable, and a too-broad `failed` match in the winget result parser.

### Added
- `-DryRun` (alias `-WhatIf`), `-Modules`, `-ReportPath`, `-ReportFormat` (Markdown, Html, Json), `-LogRetentionDays`, `-Schedule` / `-Unschedule` and `-AllowOnBattery`.
- Security audit module (menu option 9): local accounts, listening ports, scheduled tasks, Run keys with signature check, services with unquoted or user-writable paths, WMI persistence, Winlogon/IFEO/AppInit tampering, user proxy, installed software with end-of-life detection.
- Extra security checks: Defender exclusions, Tamper Protection, cloud protection, PUA, BitLocker, TPM, SMB1 feature, PowerShell 2.0, WDigest, NTLMv1, auto-logon, SmartScreen, AutoRun.
- Extra diagnostics: CPU throttling and temperature, RAM channel and speed, activation, battery cycles, Reliability Monitor index, memory-diagnostic result, dirty bit, hibernation file, biggest folders and files, metered connection, link speed and packet errors, Wi-Fi signal, router latency, unsigned and old drivers, more services and event rules (storahci, stornvme, Defender detections, ...).
- Cleanup: kernel live reports, Windows Update and setup logs, Defender scan history, app caches (Teams, Discord, Slack, Spotify, Office, npm, pip, NuGet), Vivaldi cache, Disk Cleanup system handlers, component store analysis, WSL disk hint.
- Repair: DISM CheckHealth before ScanHealth, WSUS fallback for RestoreHealth, time limits for DISM, SFC and the update search, BITS queue reset, optional network stack, Store cache and icon cache repairs.
- Windows Update: optional Microsoft Update registration, battery and free-space guards, asynchronous search with a time limit; winget upgrades for desktop apps on request.
- Reports: HTML and JSON output, "new since last run" comparison, log and snapshot retention, exit codes for schedulers.
- Keeps the PC awake during long operations, refuses to run twice at the same time, and always relaunches in Windows PowerShell 5.1.

### Changed
- Restart prompt now uses a 60-second `shutdown /r` countdown instead of `Restart-Computer -Force`.
- Menu option 9 now starts the security audit (the report is still created when you exit with 0).
- `PSScriptAnalyzerSettings.psd1` excludes `PSAvoidUsingEmptyCatchBlock` and `PSUseSingularNouns` (best-effort probes are intentional).
- Renamed `Ensure-RestorePoint` to `Initialize-RestorePoint` (approved PowerShell verb).

### Removed
- Unused variables flagged by PSScriptAnalyzer (`$eol`, `$w`, `$browserCaches`, and an unused `$c`).

## [2.0] - 2026-10-10

### Added
- Initial public version: diagnostics, cleanup, repair, Windows Update (Windows 11 blocked), Store/app updates, optimizations and a Markdown report.
