#requires -version 5.1
<#
.SYNOPSIS
    Builds the single-file release Windows10_SystemMaintenance.ps1 from src/*.ps1.

.DESCRIPTION
    The sources in src/ are concatenated in file-name order (00-, 10-, 20-, ...) with LF line endings and a UTF-8 BOM
    (required by Windows PowerShell 5.1 for non-ASCII characters). The result is the file users download.

.PARAMETER Check
    Build in memory and exit with code 1 if Windows10_SystemMaintenance.ps1 differs (used by CI).

.PARAMETER Split
    One-time helper: splits an existing Windows10_SystemMaintenance.ps1 into src/ at the "# N. Title" banners.
#>
[CmdletBinding()]
param([switch]$Check, [switch]$Split)

$root = Split-Path $PSScriptRoot -Parent
$srcDir = Join-Path $root 'src'
$target = Join-Path $root 'Windows10_SystemMaintenance.ps1'
$utf8Bom = New-Object System.Text.UTF8Encoding($true)

if ($Split) {
    $text = [IO.File]::ReadAllText($target)
    $lines = $text -split "`n"
    $names = @{
        1 = '10-helpers'; 2 = '20-knowledge'; 3 = '30-preflight'; 4 = '40-diagnostics'; 5 = '50-cleanup'; 6 = '60-integrity'
        7 = '70-update'; 8 = '80-store'; 9 = '90-optimize'; 10 = '95-report'; 11 = '99-main'
    }
    $starts = [ordered]@{ '00-header' = 0 }
    for ($i = 1; $i -lt $lines.Count - 1; $i++) {
        $m = [regex]::Match($lines[$i], '^# (\d+)\. ')
        if ($m.Success -and $lines[$i - 1] -match '^# -{20,}' -and [int]$m.Groups[1].Value -ge 1) {
            $starts[$names[[int]$m.Groups[1].Value]] = $i - 1
        }
    }
    New-Item -ItemType Directory -Path $srcDir -Force | Out-Null
    $keys = @($starts.Keys)
    for ($k = 0; $k -lt $keys.Count; $k++) {
        $from = $starts[$keys[$k]]
        $to = if ($k + 1 -lt $keys.Count) { $starts[$keys[$k + 1]] - 1 } else { $lines.Count - 1 }
        $chunk = ($lines[$from..$to] -join "`n")
        if ($k + 1 -lt $keys.Count) { $chunk += "`n" }
        [IO.File]::WriteAllText((Join-Path $srcDir "$($keys[$k]).ps1"), $chunk, $utf8Bom)
        Write-Host ("{0,-16} lines {1}-{2}" -f $keys[$k], ($from + 1), ($to + 1))
    }
    return
}

$parts = Get-ChildItem -LiteralPath $srcDir -Filter '*.ps1' | Sort-Object Name
if (-not $parts) { throw "No sources found in $srcDir" }
$sb = New-Object System.Text.StringBuilder
foreach ($p in $parts) {
    # Each part is stored with a BOM; ReadAllText strips it, so parts join without stray BOM characters.
    $t = [IO.File]::ReadAllText($p.FullName) -replace "`r`n", "`n"
    [void]$sb.Append($t)
}
$built = $sb.ToString()

if ($Check) {
    $current = [IO.File]::ReadAllText($target) -replace "`r`n", "`n"
    if ($current -ne $built) { Write-Host 'Windows10_SystemMaintenance.ps1 is out of date. Run tools/Build-Script.ps1 and commit the result.' -ForegroundColor Red; exit 1 }
    Write-Host 'Built script matches src/.' -ForegroundColor Green
    exit 0
}
[IO.File]::WriteAllText($target, $built, $utf8Bom)
Write-Host "Built $target from $(@($parts).Count) source files ($($built.Length) characters)." -ForegroundColor Green
