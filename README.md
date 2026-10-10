<div align="center">

# Windows 10 System Maintenance

### Diagnose. Clean. Repair. Update. Understand.

A single-file PowerShell tool that checks the health of a Windows 10 PC, fixes what is safe to fix, asks before anything risky, and explains every result in plain language.

[![Lint and test](https://github.com/TrollingDEAD/Windows-10-Maintenance/actions/workflows/lint.yml/badge.svg)](https://github.com/TrollingDEAD/Windows-10-Maintenance/actions/workflows/lint.yml)
[![License: MIT](https://img.shields.io/badge/license-MIT-2ea44f.svg)](LICENSE)
![Platform](https://img.shields.io/badge/Windows-10-0078D6?logo=windows&logoColor=white)
![PowerShell](https://img.shields.io/badge/PowerShell-5.1%2B-5391FE?logo=powershell&logoColor=white)
![Dependencies](https://img.shields.io/badge/dependencies-none-lightgrey)

[Quick start](#quick-start) · [Features](#what-it-does) · [Safety](#safety-model) · [Report](#the-report) · [FAQ](#faq) · [Contributing](CONTRIBUTING.md)

</div>

---

## Why this exists

Most "PC optimizer" tools are opaque, push cosmetic tweaks, and quietly change settings you never asked about. This script takes the opposite approach:

- **Real maintenance, no folklore.** It runs the Microsoft-supported tools (DISM, SFC, `chkdsk`, Windows Update, Defender, winget) and cleans only known junk locations.
- **Nothing hidden.** One readable `.ps1` file, no installer, no binaries, no telemetry, no network calls except to Microsoft's own update services.
- **Explains itself.** Cryptic output such as HRESULT codes, bugcheck codes and CBS log lines is translated into what it means and what to do next.
- **Keeps you on Windows 10.** Feature updates are limited to Windows 10 22H2. Windows 11 is blocked and never installed.

> [!IMPORTANT]
> Windows 10 reached end of support on 2025-10-14. This tool helps an existing installation stay healthy and as secure as it can, but it does not replace a supported operating system. The report states the current support status for your machine.

## Quick start

**1. Download** [`Windows10_SystemMaintenance.ps1`](Windows10_SystemMaintenance.ps1) (or clone the repository).

**2. Run it** by right-clicking the file and choosing **Run with PowerShell**, or from a terminal:

```powershell
powershell.exe -ExecutionPolicy Bypass -File .\Windows10_SystemMaintenance.ps1
```

**3. Confirm the UAC prompt.** The script relaunches itself with administrator rights, runs a preflight check, and shows the menu:

```text
 ======================================================================
  WINDOWS 10 - SYSTEM MAINTENANCE  (Version 3.0)
 ======================================================================

  1  Full maintenance (recommended): diagnostics, cleanup, repair, updates, Store, optimization
  2  Diagnostics only (nothing is changed, except clearly detected misconfigurations)
  3  Cleanup only
  4  Check and repair integrity only (DISM, SFC, file system, WMI)
  5  Windows Update only (Windows 11 stays blocked)
  6  Microsoft Store / app updates only
  7  Optimizations only
  8  Set/check the Windows 11 block
  9  Security deep-dive only (persistence, accounts, ports, Defender settings)
  0  Exit (the report is still created)
```

**4. Read the report** that appears on your desktop when the run finishes.

> [!TIP]
> Not sure where to start? Choose **2** first. It looks at everything and the report tells you what, if anything, needs attention.

### Command-line options

| Parameter | Effect |
| --- | --- |
| `-Auto` | Unattended run of all modules with no prompts. Riskier actions are skipped and listed in the report as open items. |
| `-SkipRestorePoint` | Do not create a System Restore point before making changes. |
| `-NoElevate` | Do not relaunch with administrator rights automatically. |
| `-DryRun` (alias `-WhatIf`) | Diagnose everything, change nothing. Every skipped change is printed as `[DryRun] would ...`. Cleanup shows what *would* be freed; SFC runs in `/verifyonly` mode. |
| `-Modules sys,sec,audit` | Run only the listed modules: `sys`, `net`, `disk`, `sec`, `audit`, `evt`, `svc`, `clean`, `integ`, `wu`, `store`, `opt`, `w11`. |
| `-ReportPath <folder>` | Where to write the reports (default: desktop, or `%ProgramData%\Windows10_SystemMaintenance\Reports` when run as SYSTEM). |
| `-ReportFormat Markdown,Html,Json` | Report formats to write. A JSON snapshot is always kept for the "new since last run" comparison. |
| `-LogRetentionDays <n>` | Delete logs and snapshots older than `n` days (default 60, `0` keeps everything). |
| `-AllowOnBattery` | Long operations (DISM, SFC, updates, defrag) are skipped on battery power unless you pass this. |
| `-Schedule` / `-Unschedule` | Register or remove a weekly task (Sundays 03:00, SYSTEM, `-Auto`). |

```powershell
# Unattended full run, for example from Task Scheduler
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Windows10_SystemMaintenance.ps1 -Auto

# See what a full run would do, without changing anything
.\Windows10_SystemMaintenance.ps1 -DryRun -ReportFormat Markdown,Html

# Weekly unattended maintenance
.\Windows10_SystemMaintenance.ps1 -Schedule
```

**Exit codes** (useful for schedulers and RMM tools): `0` nothing important open, `10` Medium finding open, `11` High, `12` Critical, `3` no administrator rights, `4` another instance is already running.

## What it does

<table>
<tr>
<td width="50%" valign="top">

### Diagnose
Read-only checks that feed the report.

- **System:** OS build and support status, hardware, uptime, BIOS age, pending reboots, CPU throttling and temperature, RAM channel/speed, activation, top memory consumers
- **Disks:** SMART and reliability counters, free space, dirty bit, hibernation file, where the space went (biggest folders and files)
- **Security:** Defender state, exclusions, Tamper Protection and cloud protection, third-party antivirus, UAC, SMB1 (server and feature), PowerShell 2.0, WDigest, NTLMv1, BitLocker, TPM, Secure Boot, Remote Desktop, firewall, suspicious `hosts` entries, system and user proxy
- **Security audit:** local accounts, listening ports, scheduled tasks and Run keys (with signature check), services with unquoted or user-writable paths, WMI event subscriptions, Winlogon/IFEO/AppInit hijacks, installed software and end-of-life detection
- **Network:** connectivity, DNS, metered connection, link speed and packet errors, Wi-Fi signal, router latency and packet loss, time source
- **Event log:** repeated crashes and hangs, stop (bugcheck) codes, storage-controller resets, Defender detections, Reliability Monitor index, memory-diagnostic result
- **Services and drivers:** failed or disabled services, devices with driver errors, unsigned and very old drivers

</td>
<td width="50%" valign="top">

### Clean
Only known junk locations. Documents, pictures, downloads and the desktop are never touched.

- Temp folders (user and Windows)
- Internet and thumbnail caches, DirectX shader cache
- Crash dumps and Windows Error Reporting data
- Old servicing logs and leftover update backup folders
- Kernel live reports, Windows Update and setup logs, Defender scan history
- App caches: Teams, Discord, Slack, Spotify, Office file cache, npm, pip, NuGet
- Browser caches for Chrome, Edge, Brave and Vivaldi plus Firefox: **cache only**, never cookies, passwords or history, and skipped while the browser is open
- Windows Disk Cleanup "system files" handlers and component store cleanup (DISM `StartComponentCleanup`), after confirmation
- Recycle Bin, only if you explicitly agree

</td>
</tr>
<tr>
<td width="50%" valign="top">

### Repair
- **DISM** quick check, scan and restore of the component store, with time limits and a WSUS fallback
- **SFC** with evaluation of the CBS log, so you learn *which* files were fixed or could not be
- **File system** scan of every fixed NTFS volume with an optional scheduled `chkdsk /F`
- Optional, confirmed repairs: network stack reset, Store cache reset, icon cache rebuild
- **WMI repository** consistency check
- **Windows Update components** reset when updating is broken, with known error codes explained

</td>
<td width="50%" valign="top">

### Update and optimize
- **Windows Update:** security and quality updates, WSUS and policy conflicts detected
- **Microsoft Update:** optional registration so Office and other Microsoft products are updated too
- **Microsoft Store and apps:** Store background scan, winget upgrades for Store apps and (on request) desktop apps
- **Windows 11 block:** target version pinned to Windows 10, upgrade offers filtered and hidden, installation assistant detected
- **TRIM** for SSDs, **defrag** only for hard disks
- **Defender:** signature update and optional quick scan
- **Time sync, System Restore, page file and Fast Startup** review

</td>
</tr>
</table>

## Safety model

| Principle | How it is implemented |
| --- | --- |
| **Reversible first** | A System Restore point is created before the first change. If System Restore is off, the script offers to turn it on. |
| **You decide** | Risky actions (emptying the Recycle Bin, disabling SMB1, scheduling `chkdsk`, restarting) require an explicit yes. |
| **Unattended means conservative** | In `-Auto` mode every risky action is skipped and reported as an open item rather than done. |
| **No security downgrades** | The script never disables Defender, the firewall, UAC or any other protection. It only reports them, and re-enables what it can safely re-enable. |
| **No tweak folklore** | No debloating, no registry "speed-ups", no telemetry changes, no service disabling. |
| **Auditable** | Everything is logged to a transcript, and every action taken appears in the report. |

## The report

Each run ends with a report saved to your desktop (Markdown by default, optionally HTML and JSON). It contains:

- **Summary:** how many findings were fixed automatically and how many remain open, plus whether a restart is needed
- **Since the last run:** which problems are new and which were resolved, based on a snapshot stored in the log folder
- **Findings:** severity (`High`, `Medium`, ...), category, a plain-language explanation, the technical evidence, a concrete recommendation, and a status of `Fixed` or `Open`
- **Actions taken:** every change the script made and whether it succeeded, was skipped, or failed
- **System facts and tables:** build, hardware, free space reclaimed, devices with driver problems

An example of how a finding reads:

```markdown
### Real-time antivirus protection is turned off   `High` · Security · Open

**What this means:** Without real-time protection, malware can run unnoticed ...
**Evidence:** Defender RealTimeProtectionEnabled = False
**Recommendation:** Turn real-time protection back on in Windows Security ...
```

| Item | Location |
| --- | --- |
| Report | Desktop (or `-ReportPath`): `Windows10_SystemReport_<yyyyMMdd_HHmmss>.md` / `.html` / `.json` |
| Console transcript | `%LOCALAPPDATA%\Windows10_SystemMaintenance\Logs\` |
| Run snapshots | `%LOCALAPPDATA%\Windows10_SystemMaintenance\Snapshots\` |

## Requirements

| | |
| --- | --- |
| **Operating system** | Windows 10, any edition |
| **PowerShell** | Windows PowerShell 5.1 (included with Windows 10) or newer |
| **Privileges** | Administrator (requested automatically) |
| **Network** | Needed for Windows Update, Store/winget and Defender signature updates. Without it, those modules are skipped and everything else still runs. |
| **Installation** | None. Single file. |

## FAQ

<details>
<summary><b>Is it safe to run?</b></summary>

It creates a restore point first, asks before risky steps, and only cleans known junk locations. It is still a tool that repairs system components, so back up important data before any maintenance. You use it at your own risk (see the [license](LICENSE)).
</details>

<details>
<summary><b>Will it upgrade me to Windows 11?</b></summary>

No. It sets the Windows Update target version to Windows 10, filters feature-update offers, hides upgrade offers and reports if the Windows 11 installation assistant is running. Menu option 8 re-applies and verifies the block.
</details>

<details>
<summary><b>Does it remove apps or disable telemetry?</b></summary>

No. It is not a debloater and does not touch privacy or telemetry settings.
</details>

<details>
<summary><b>Why does it need <code>-ExecutionPolicy Bypass</code>?</b></summary>

Downloaded scripts are blocked by the default execution policy. The flag applies only to that one process. You can instead review the file and run `Unblock-File .\Windows10_SystemMaintenance.ps1`.
</details>

<details>
<summary><b>Can I schedule it?</b></summary>

Yes: run `.\Windows10_SystemMaintenance.ps1 -Schedule` once. It registers a weekly task (Sundays 03:00, as SYSTEM, with `-Auto`); `-Unschedule` removes it. Risky actions are skipped in that mode and listed in the report, and long operations are skipped on battery power.
</details>

<details>
<summary><b>What happens when Windows 10 updates stop entirely?</b></summary>

The update module keeps working for as long as Microsoft delivers updates (including Extended Security Updates where enrolled) and reports clearly when none are available. The report's support section tells you where you stand.
</details>

## Development

```powershell
# Lint
Install-Module PSScriptAnalyzer -Scope CurrentUser
Invoke-ScriptAnalyzer -Path . -Recurse -Settings .\PSScriptAnalyzerSettings.psd1

# Tests
Install-Module Pester -MinimumVersion 5.0 -Scope CurrentUser
Invoke-Pester .\tests
```

```text
.
├── Windows10_SystemMaintenance.ps1   # the tool
├── tests/                            # Pester tests
├── PSScriptAnalyzerSettings.psd1     # lint configuration
├── .github/                          # CI, issue and PR templates, Dependabot
├── CHANGELOG.md  CONTRIBUTING.md  SECURITY.md  CODE_OF_CONDUCT.md  LICENSE
```

Contributions are welcome. Please read [CONTRIBUTING.md](CONTRIBUTING.md) first. To report a vulnerability, see [SECURITY.md](SECURITY.md). Release history is in [CHANGELOG.md](CHANGELOG.md).

## Disclaimer

This software modifies system settings and runs repair commands. It is provided "as is", without warranty of any kind. Back up your data and use it at your own risk.

## License

Released under the [MIT License](LICENSE).
