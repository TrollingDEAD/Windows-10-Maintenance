# Troubleshooting

## The script closes immediately or does nothing

- Run it from an elevated terminal to see messages: `powershell.exe -ExecutionPolicy Bypass -File .\Windows10_SystemMaintenance.ps1 -NoElevate`.
- **"Another instance is already running" (exit code 4):** a previous run is still active (maybe the scheduled task). Check Task Manager for `powershell.exe`, or wait for it to finish.
- **"cannot work without administrator rights" (exit code 3):** the UAC prompt was declined. Run it again and accept it.
- **"intended exclusively for Windows 10" (exit code 2):** the build is 22000 or higher (Windows 11).
- **Script is blocked:** right-click > Properties > Unblock, or `Unblock-File .\Windows10_SystemMaintenance.ps1`.

## Where are the logs and reports?

| What | Where |
| --- | --- |
| Console transcript | `%LOCALAPPDATA%\Windows10_SystemMaintenance\Logs\` (or `%ProgramData%\Windows10_SystemMaintenance\Logs` when run as SYSTEM, e.g. by the scheduled task) |
| Reports | Desktop, or `-ReportPath`; SYSTEM runs use `%ProgramData%\Windows10_SystemMaintenance\Reports` |
| Run snapshots (history, "new since last run") | `...\Snapshots\` |
| Undo journal | `...\Journal\` |
| Config | `...\config.json` (created on first interactive run; open it with menu **C**) |
| DISM / CBS logs | `C:\Windows\Logs\DISM\dism.log`, `C:\Windows\Logs\CBS\CBS.log` (search `[SR]`) |

## Exit codes

| Code | Meaning |
| --- | --- |
| 0 | Run finished, nothing Medium or worse is open |
| 10 / 11 / 12 | Worst open finding is Medium / High / Critical |
| 1 | Invalid parameter value or the fleet wrapper had failures |
| 2 | Not Windows 10 |
| 3 | No administrator rights |
| 4 | Another instance is running |

## Common situations

**A module says "skipped: the PC runs on battery power".** Plug in the charger or pass `-AllowOnBattery`.

**Windows Update shows "metered connection".** Windows postpones downloads on metered connections. Settings > Network & Internet > your connection > Properties > Metered connection: Off.

**Windows Update fails with 0x80070422 / 0x8024402C / 0x80072EE2.** The report names the cause. The script already resets disabled update services; for proxy/DNS codes check `netsh winhttp show proxy` and your DNS. Reset the update components when the script offers it.

**DISM RestoreHealth fails on a company PC.** A WSUS policy points Windows Update to an internal server. The script retries with the policy bypassed for the duration of the repair; if IT blocks that, mount a Windows 10 ISO and run `DISM /Online /Cleanup-Image /RestoreHealth /Source:wim:D:\sources\install.wim:1 /LimitAccess`.

**"Defender exclusions" / registry writes are blocked.** Third-party security software or Tamper Protection can block registry or service changes. The report lists what could not be changed.

**The report shows findings I do not care about.** Add their IDs (wildcards allowed) to `SuppressFindings` in `config.json`. They are counted and listed as hidden in the report.

**Output is unreadable in an RMM tool.** Use `-Quiet` (plain text, no colours) and `-ReportFormat Json`.

**Something was changed that I want back.** `-Undo` (or menu **U**) reverts the last run's journal: registry values, service start types, power plan, firewall/SMB/feature/account changes, autostart items. Cleaned files cannot be restored; use the System Restore point for system settings.

**A scheduled run did nothing.** `Get-ScheduledTaskInfo -TaskName Windows10_SystemMaintenance_Weekly` shows the last result. The task runs only when the PC is idle; check the logs under `%ProgramData%`.

## Reporting a bug

Run the failing step again with `-DryRun -Redact -ReportFormat Markdown,Json` and attach the redacted JSON report and the log excerpt to the issue. `-Redact` masks computer and user names, serial numbers, IP and MAC addresses.
