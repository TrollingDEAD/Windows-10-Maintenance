# Roadmap

Ideas that are **not** implemented yet. Contributions welcome; see [CONTRIBUTING.md](../CONTRIBUTING.md) and [ARCHITECTURE.md](ARCHITECTURE.md).

## Needs infrastructure or a maintainer decision

- **Code signing** of releases (needs a certificate) so users can run under `AllSigned` instead of `-ExecutionPolicy Bypass`.
- **VM test matrix** (Windows 10 Home / Pro / LTSC, 21H2 / 22H2, domain + WSUS, third-party AV, non-English locales) running the elevated paths in CI.
- **Localisation**: user-facing text lives inline today. A resource table plus translations (German first) would help non-English users; tool-output parsers already accept English and German.
- **Screenshots / sample report** in the README (needs a real run on a clean machine).
- **GitHub repository metadata**: description, topics (`windows-10`, `powershell`, `maintenance`, `dism`, `sfc`), social preview image, Discussions and a wiki mirror of `docs/`.

## Possible features

- Windows Update: pause/resume and active hours via the supported policies, Patch Tuesday status.
- Real ESU enrollment detection once Microsoft documents a reliable signal.
- winget bootstrap when App Installer is missing.
- Trusted root certificate audit with a bundled known-good list.
- Browser profile deep-check (extension permissions) and outdated-version check against vendor release feeds.
- GPU / chipset / NVMe firmware freshness against vendor feeds (opt-in network calls).
- File-level integrity checks for the script itself (self-test of embedded checksum).
- Optional per-finding "fix" actions in the HTML report (copy-ready commands).
- Fleet dashboard from the collected JSON files.

## Technical debt

- Several tool-output parsers still match English/German text (`winmgmt`, `fsutil`, `vssadmin`, `reagentc`, `winget`). Prefer cmdlets, WMI or exit codes where they exist.
- Windows Update installation runs in-process; a hung COM call cannot be killed (the search has a time limit, the install does not).
- Move the knowledge base (event rules, error codes, EOL patterns) to a data file embedded at build time.
