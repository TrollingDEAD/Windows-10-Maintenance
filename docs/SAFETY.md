# Safety and blast radius

This page lists **everything** the script can change or contact, so you can judge the risk before running it. Anything not listed here is not touched. Run with `-DryRun` to see what *would* happen without changing anything, and use `-Undo` (menu **U**) to revert the recorded changes of the last run.

## Guarantees

- Personal folders (Documents, Pictures, Downloads, Desktop, Videos, Music) are never deleted from.
- Protections are never switched off. The script only re-enables Defender real-time protection and the firewall, and only the firewall step is optional.
- Every reversible change is written to an undo journal (`%LOCALAPPDATA%\Windows10_SystemMaintenance\Journal`) with its previous value.
- A restore point is created before the first change (unless `-SkipRestorePoint`).
- In `-Auto` mode every step marked *asks first* below is skipped, not done.
- No telemetry. The only outbound connections are listed under *Network*.

## Registry

| Key / value | When | Why | Reversible |
| --- | --- | --- | --- |
| `HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate`: `TargetReleaseVersion`, `ProductVersion`, `TargetReleaseVersionInfo`, `DisableOSUpgrade` | Windows Update module / menu 8 | Keeps the PC on Windows 10 22H2 | Yes (`-Undo`) |
| `HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\OSUpgrade`: `AllowOSUpgrade` | same | Hides Windows 11 upgrade offers | Yes |
| `HKLM\SYSTEM\CurrentControlSet\Control\SecurityProviders\WDigest`: `UseLogonCredential` | Only if it was `1`; asks first | Stops clear-text passwords in memory | Yes |
| `HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\SystemRestore`: `SystemRestorePointCreationFrequency` | During restore point creation | Lifts the 24 h limit; the old value is restored immediately | Automatic |
| `HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU`: `UseWUServer` | Only during a DISM repair on a WSUS-managed PC | Lets DISM reach Windows Update; restored afterwards | Automatic |
| `HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\VolumeCaches\*`: `StateFlags6464` | Disk Cleanup step | Selects cleanup handlers; removed afterwards | Automatic |
| `HKLM\SOFTWARE\Microsoft\Windows Search`: `SetupCompletedSuccessfully` | Search index rebuild; asks first | Triggers a rebuild | Yes |
| `...\Explorer\StartupApproved\Run*` | Autostart review; you choose each item | Same mechanism as Task Manager's "Disable" | Yes |

## Services, features, accounts, settings

| Change | Condition |
| --- | --- |
| Reset a *disabled* Windows service to its default start type (wuauserv, BITS, CryptSvc, EventLog, Winmgmt, mpssvc, Schedule, Dhcp, Dnscache, W32Time, TrustedInstaller, UsoSvc, WinDefend, ...) | Automatic; skipped for services in `NeverTouchServices` |
| Start automatic services that stopped with an error | Automatic |
| Stop and start wuauserv, BITS, CryptSvc, msiserver, UsoSvc | Update cache clear / component reset |
| Stop and start Spooler or WSearch | Print queue clear / index rebuild; asks first |
| Turn on Defender real-time protection | Only if it was off and no other antivirus is active |
| Turn on a Windows Firewall profile | Asks first (skipped in `-Auto`) |
| Disable SMB1 (server, feature), PowerShell 2.0, Guest account | Asks first (skipped in `-Auto`) |
| Enable System Restore, Windows RE, automatic page file management, Microsoft Update registration, Balanced power plan | Asks first |
| Switch the active power plan | Desktop on *Power saver* only; asks first |

## Files and folders that may be deleted

Only the contents of: user and Windows `Temp`, `INetCache`, `CrashDumps`, Windows Error Reporting folders, `D3DSCache`, thumbnail and icon caches, old CBS logs (`*.cab` older than 14 days), `LiveKernelReports\*.dmp` older than 7 days, Windows Update and setup logs, `Downloaded Program Files`, Defender scan history, `SoftwareDistribution\Download` (asks first), Delivery Optimization cache, old `SoftwareDistribution.bak_*` and `catroot2.bak_*` folders (older than 7 days), browser **caches** (Chrome, Edge, Brave, Vivaldi, Firefox; never cookies, passwords or history; skipped while the browser runs), app caches (Teams, Discord, Slack, Spotify, Office file cache, npm, pip, NuGet), `MEMORY.DMP` (asks first, kept after recent blue screens), the Recycle Bin (asks first, never in `-Auto`). Folders listed in `NeverCleanPaths` are skipped.

## Commands that are run

`dism.exe` (CheckHealth, ScanHealth, RestoreHealth, AnalyzeComponentStore, StartComponentCleanup; `/ResetBase` only after an explicit yes), `sfc.exe`, `chkdsk` (only after a yes, runs at next restart), `winmgmt /salvagerepository` (only if the repository is inconsistent), `Repair-Volume -Scan`, `cleanmgr /sagerun` (asks first), `pnputil /delete-driver` (old driver versions; asks first, Windows refuses packages in use), `reagentc /enable` (asks first), `netsh winsock reset` / `int ip reset` (asks first, needs restart), `w32tm`, `ipconfig /flushdns`, `powercfg`, `vssadmin` (read-only), `wusa /uninstall` (only with `-UninstallKB`), `shutdown /r /t 60` (asks first), `winget` (list/upgrade/pin/export), `wsreset` (asks first).

## Network connections

| Destination | Purpose | When |
| --- | --- | --- |
| `www.msftconnecttest.com` (HTTP) | Internet check | Every run |
| Windows Update / Microsoft Update, Microsoft download servers | Updates, DISM repair source | Update and integrity modules |
| winget sources (`cdn.winget.microsoft.com`) | App updates | Store/apps module |
| Defender signature servers | Signature update | Optimizations module |
| `time.windows.com` / `pool.ntp.org` | Time sync (fallback only if the first fails) | Optimizations module |
| `api.github.com` and release assets of this repository | Update check | Only with `-CheckUpdate` |
| Your `WebhookUrl` (https only) | Result notification | Only if configured, and only when findings changed |

## What the script never does

Uninstall programs, change privacy/telemetry settings, disable Defender, the firewall, UAC or Windows Update, install drivers from the internet, edit the `hosts` file, remove accounts, or run `bootrec`/`diskpart`.
