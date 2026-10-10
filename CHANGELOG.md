# Changelog

All notable changes to this project are documented here.
The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the project uses [Semantic Versioning](https://semver.org/).

## [3.1] - 2026-10-10

### Added
- **Undo journal and `-Undo`** (menu U): registry values, service start types, power plan, firewall, SMB1, optional features, Guest account, page file and autostart changes are recorded with their previous value and can be reverted.
- **`-Redact`** masks computer and user names, serial numbers, IP and MAC addresses in all reports.
- **Configuration file** (`config.json`, menu C): `SuppressFindings` (wildcards), `NeverCleanPaths`, `NeverTouchServices`, `WingetPin`, `EsuEndDate`, `WebhookUrl`. Suppressed findings are listed as hidden in the report.
- **Health score** (0-100) in the console, Markdown and HTML reports; **`-History`** and an inline trend chart in the HTML report; HTML report with severity filter, print layout and keyboard focus styles.
- **Recovery readiness module** (menu R): Windows RE (can enable it), restore-point age, File History / OneDrive backup, BitLocker recovery keys, BCD readability.
- **Performance diagnostics:** boot time and slowest startup programs, slow shutdowns, 5-second CPU/disk/process sample, disabled and cleared event logs, Office Click-to-Run status, servicing-channel hint (LTSC/IoT).
- **Security audit additions:** open network shares, wide-open firewall rules, RDP without NLA, password/lockout policy, exploit protection (DEP), VPN and virtualization-based security state, expiring certificates, stale accounts, outdated browsers and browser extension inventory, orphaned scheduled tasks and services.
- **Guided autostart review** (switch items off the same reversible way Task Manager does) and **driver store cleanup** (keep the two newest versions of each driver).
- **Cleanup/repair extras:** optional DISM `/ResetBase`, print-queue repair, Windows Search index rebuild.
- **Update extras:** pending-updates table with KB numbers, `-UninstallKB`, `-CheckUpdate` (SHA256-verified, never self-updating), winget pinning, `-ExportApps`.
- **Notifications:** `-WebhookUrl` (https only, only when findings changed) and `-Toast`.
- **`-Quiet`**, **`-Gui`** launcher, `-ScheduleDay` / `-ScheduleTime`; the scheduled task now runs only when the PC is idle and can wake it.
- **`Invoke-FleetMaintenance.ps1`** to run the script on many PCs through PowerShell remoting and collect the JSON reports.
- **Documentation:** `docs/` (FINDINGS generated from the code, SAFETY with the full blast radius, TROUBLESHOOTING, ARCHITECTURE, ROADMAP) and a JSON schema for the report. Reports link every open finding to its page.
- **Development workflow:** the single-file script is now generated from `src/` by `tools/Build-Script.ps1`; `tools/New-FindingDocs.ps1` generates the findings reference; CI checks both, lints, runs unit tests and a dry-run smoke test; a tag-triggered workflow publishes a release with SHA256 checksums.

### Fixed
- Output of tools run with a time limit is decoded with the console (OEM) code page and includes standard error.
- Windows 10 end-of-support date can be set in the config instead of being hard-coded.

### Changed
- The bug report template asks for the script version, display language and a redacted JSON report.

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
