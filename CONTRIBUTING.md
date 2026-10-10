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

Before opening a pull request, make sure both pass:

```powershell
Invoke-ScriptAnalyzer -Path . -Recurse -Settings .\PSScriptAnalyzerSettings.psd1
Invoke-Pester .\tests
```

Test any behavior change on a Windows 10 machine or VM (ideally with a snapshot), once interactively and once with `-Auto`.

## Guidelines

- **Scope:** keep it maintenance, not tweaking. No debloat, no telemetry tweaks, nothing that weakens security.
- **Safety first:** risky actions must go through `Confirm-Step -Risky` and must be skipped in `-Auto` mode.
- **Explain results:** every finding needs plain-language `-Meaning`, `-Evidence` and `-Recommendation`.
- **Style:** follow the surrounding code, use approved PowerShell verbs (`Get-Verb`), 4-space indentation, no unused variables. Keep the file UTF-8 with BOM and CRLF line endings.
- **Compatibility:** Windows PowerShell 5.1 must keep working; avoid PowerShell 7-only syntax.
- **Docs:** update [README.md](README.md) and [CHANGELOG.md](CHANGELOG.md) when behavior changes.

## Commits and pull requests

- Small, focused pull requests are easier to review.
- Use clear, imperative commit messages (`Add SMART check for NVMe drives`).
- Describe what changed, why, and how you tested it.

By contributing you agree that your contributions are licensed under the [MIT License](LICENSE).
