# Contributing

Thanks for your interest in improving this project! Bug reports, ideas and pull requests are welcome.

## Reporting bugs and requesting features

Use the [issue templates](../../issues/new/choose). For bugs, include your Windows 10 build (`winver`), PowerShell version (`$PSVersionTable.PSVersion`), and the relevant part of the console log from `%LOCALAPPDATA%\Windows10_SystemMaintenance\Logs\`. Remove personal data first.

Security problems: please follow [SECURITY.md](SECURITY.md) instead of opening a public issue.

## Development setup

```powershell
Install-Module PSScriptAnalyzer -Scope CurrentUser
Install-Module Pester -MinimumVersion 5.0 -Scope CurrentUser
```

**Edit `src/*.ps1`, not `Windows10_SystemMaintenance.ps1`.** The single-file script is generated (see [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md)). Before opening a pull request, run:

```powershell
.\tools\Build-Script.ps1          # src/ -> Windows10_SystemMaintenance.ps1
.\tools\New-FindingDocs.ps1       # refresh docs/FINDINGS.md when findings changed
Invoke-ScriptAnalyzer -Path .\Windows10_SystemMaintenance.ps1 -Settings .\PSScriptAnalyzerSettings.psd1
Invoke-Pester .\tests
```

Commit both the sources and the generated files; CI fails when they are out of sync. Bump `$script:Version` in `src/00-header.ps1` and add a `CHANGELOG.md` entry for user-visible changes (a test checks that they match).

Test any behavior change on a Windows 10 machine or VM (ideally with a snapshot), once interactively and once with `-Auto`.

## Guidelines

- **Scope:** keep it maintenance, not tweaking. No debloat, no telemetry tweaks, nothing that weakens security.
- **Safety first:** risky actions must go through `Confirm-Step -Risky` and must be skipped in `-Auto` mode.
- **Explain results:** every finding needs plain-language `-Meaning`, `-Evidence` and `-Recommendation`, and a stable `-Id`.
- **Reversible changes:** use `Set-RegistryValueTracked`, `Set-ServiceStartTracked` or `Add-JournalEntry` so `-Undo` works, and honour `-DryRun` (`Test-DryRun`, or `Confirm-Step`).
- **Good first contributions:** new event rules, error codes, junk locations and end-of-life software patterns (see [docs/ROADMAP.md](docs/ROADMAP.md)).
- **Style:** follow the surrounding code, use approved PowerShell verbs (`Get-Verb`), 4-space indentation, no unused variables. Keep the file UTF-8 with BOM and CRLF line endings.
- **Compatibility:** Windows PowerShell 5.1 must keep working; avoid PowerShell 7-only syntax.
- **Docs:** update [README.md](README.md) and [CHANGELOG.md](CHANGELOG.md) when behavior changes.

## Commits and pull requests

- Small, focused pull requests are easier to review.
- Use clear, imperative commit messages (`Add SMART check for NVMe drives`).
- Describe what changed, why, and how you tested it.

By contributing you agree that your contributions are licensed under the [MIT License](LICENSE).
