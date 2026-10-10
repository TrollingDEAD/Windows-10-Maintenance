# Architecture

## Source layout

```text
src/                      development sources (edit these)
  00-header.ps1           help, parameters, bootstrap (elevation, lock, logging)
  10-helpers.ps1          output, prompts, findings, journal, native-command runner
  20-knowledge.ps1        error codes, event rules, bugcheck names
  30-preflight.ps1        config, health score, redaction, history, notifications, preflight
  40-diagnostics.ps1      system, disk, security, audit, network, event log, services, recovery
  50-cleanup.ps1          cleanup
  60-integrity.ps1        DISM / SFC / WMI / file system / optional repairs
  70-update.ps1           Windows Update with the Windows 11 block
  80-store.ps1            Store and winget
  90-optimize.ps1         optimizations, startup review
  95-report.ps1           Markdown / HTML / JSON reports, snapshots
  99-main.ps1             GUI, menu and main flow
tools/Build-Script.ps1    concatenates src/ into Windows10_SystemMaintenance.ps1
tools/New-FindingDocs.ps1 generates docs/FINDINGS.md from the code
Windows10_SystemMaintenance.ps1   the built, single-file release artifact
Invoke-FleetMaintenance.ps1       multi-PC wrapper (PowerShell remoting)
```

`Windows10_SystemMaintenance.ps1` is **generated**. Edit `src/*.ps1`, run `tools/Build-Script.ps1`, commit both. CI runs `Build-Script.ps1 -Check` and fails if they differ.

## Run flow

1. Parameter binding, elevation (relaunch in Windows PowerShell 5.1), single-instance mutex, transcript, keep-awake.
2. Load the config file; utility commands (`-Undo`, `-History`, `-UninstallKB`, `-Gui`) run and exit.
3. `Initialize-Preflight`: Windows 10 check, support status, pending reboot, internet.
4. Modules run through `Invoke-Run` -> `Invoke-Module` (each module is wrapped in try/catch so one failure never stops the run).
5. `Save-Report`: findings -> Markdown/HTML/JSON, snapshot, diff against the previous snapshot; health score; optional notification.
6. Exit code from the worst open finding.

## Core concepts

- **Finding** (`Add-Finding`): `Id`, `Severity`, `Category`, `Title`, `Meaning`, `Evidence`, `Recommendation`, `Status` (`Open`, `Fixed`, `Info`). IDs are stable and documented in `docs/FINDINGS.md`. Findings matching `SuppressFindings` in the config are counted but not reported.
- **Fact / Table**: key-value rows and tables for the system overview.
- **Action log** (`Add-Action`): what the script did and how it ended.
- **Confirm-Step**: the only prompt. `-Risky` steps are skipped in `-Auto`; in `-DryRun` everything except `-ReadOnly` steps returns *no*.
- **Change gates**: `Test-DryRun` for direct changes, `Set-RegistryValueTracked` / `Set-ServiceStartTracked` / `Add-JournalEntry` for reversible ones (undo journal).
- **Guards**: `Test-LongOperationAllowed` (battery, free space), `Invoke-WithTimeout` / `Invoke-Native -TimeoutSec` (hung tools).
- **Health score**: 100 minus 25 / 12 / 5 / 2 per open Critical / High / Medium / Low finding.

## Adding a check

1. Put the probe in the right function (wrap uncertain probes in `try { } catch { }`; a missing WMI class must never abort a module).
2. Report problems with `Add-Finding` with a stable `-Id`. Write `-Meaning` for a non-expert and give a concrete `-Recommendation`.
3. If it changes something, gate it (`Confirm-Step`, `Test-DryRun`) and record it in the journal.
4. Run `tools/New-FindingDocs.ps1`, add a Pester test, update `CHANGELOG.md`, run `tools/Build-Script.ps1`.

## Adding an event rule

Add an entry to `$script:EventKb` in `src/20-knowledge.ps1` (`Provider|EventId` key, `S` severity, `T` title, `M` meaning, `A` action, optional `Min` count). Remember that many events are logged at *Warning* level; the query already includes levels 1-3.

## Testing

- `tests/Script.Tests.ps1`: syntax, parameters, helper behaviour (functions are extracted from the AST, the script itself is never executed).
- `tests/Smoke.Tests.ps1`: runs the diagnostics in `-DryRun` and checks the report files.
- CI: PSScriptAnalyzer (`PSScriptAnalyzerSettings.psd1`), Pester, doc and build consistency.
