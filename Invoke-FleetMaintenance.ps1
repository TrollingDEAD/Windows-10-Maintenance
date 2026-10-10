#requires -version 5.1
<#
.SYNOPSIS
    Runs Windows10_SystemMaintenance.ps1 on several PCs through PowerShell remoting and aggregates the results.

.DESCRIPTION
    For every computer the script is copied to a temporary folder over a PSSession, started unattended
    (-Auto -Quiet -ReportFormat Json), and the JSON report is fetched back. The result is a summary table
    (health score, open findings, worst severity) plus one JSON file per computer in -OutputPath.

    Requirements: WinRM enabled on the targets (Enable-PSRemoting), administrator credentials, and the
    targets must be Windows 10. Nothing is installed permanently: the temporary folder is removed afterwards.

.PARAMETER ComputerName
    One or more computer names.

.PARAMETER Credential
    Administrator credential for the targets (default: current user).

.PARAMETER ScriptPath
    Path to Windows10_SystemMaintenance.ps1 (default: next to this file).

.PARAMETER OutputPath
    Folder for the collected JSON reports and the summary (default: .\FleetReports).

.PARAMETER DryRun
    Passes -DryRun to the targets: diagnose only, change nothing.

.PARAMETER Modules
    Optional module list passed as -Modules (for example sys,sec,audit).

.PARAMETER ThrottleLimit
    How many computers run in parallel (default 5).

.EXAMPLE
    .\Invoke-FleetMaintenance.ps1 -ComputerName PC01,PC02 -DryRun

.EXAMPLE
    .\Invoke-FleetMaintenance.ps1 -ComputerName (Get-Content .\pcs.txt) -Credential (Get-Credential) -Modules sys,sec,audit
#>
[Diagnostics.CodeAnalysis.SuppressMessageAttribute("PSUseUsingScopeModifierInNewRunspaces", "", Justification = "Values are passed explicitly with param() and -ArgumentList.")]
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string[]]$ComputerName,
    [pscredential]$Credential,
    [string]$ScriptPath = (Join-Path $PSScriptRoot 'Windows10_SystemMaintenance.ps1'),
    [string]$OutputPath = (Join-Path (Get-Location) 'FleetReports'),
    [switch]$DryRun,
    [string[]]$Modules,
    [int]$ThrottleLimit = 5
)

if (-not (Test-Path -LiteralPath $ScriptPath)) { throw "Script not found: $ScriptPath" }
New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null
$stamp = Get-Date -Format 'yyyyMMdd_HHmmss'

$work = {
    param($Computer, [pscredential]$Cred, $Script, $Out, $Dry, $Mods)
    $result = [ordered]@{ Computer = $Computer; Status = 'Failed'; Score = $null; Open = $null; Worst = $null; Detail = '' }
    $session = $null
    try {
        $sp = @{ ComputerName = $Computer; ErrorAction = 'Stop' }
        if ($Cred) { $sp.Credential = $Cred }
        $session = New-PSSession @sp
        $remoteDir = Invoke-Command -Session $session -ScriptBlock {
            $d = Join-Path $env:TEMP ("w10m_" + [guid]::NewGuid().ToString('N')); New-Item -ItemType Directory -Path $d | Out-Null; $d
        }
        Copy-Item -LiteralPath $Script -Destination (Join-Path $remoteDir 'Windows10_SystemMaintenance.ps1') -ToSession $session
        $code = Invoke-Command -Session $session -ArgumentList $remoteDir, $Dry, $Mods -ScriptBlock {
            param($dir, $dry, $mods)
            $a = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', (Join-Path $dir 'Windows10_SystemMaintenance.ps1'), '-Auto', '-Quiet', '-NoElevate', '-ReportPath', $dir, '-ReportFormat', 'Json')
            if ($dry) { $a += '-DryRun' }
            if ($mods) { $a += '-Modules'; $a += ($mods -join ',') }
            $p = Start-Process -FilePath "$env:WINDIR\System32\WindowsPowerShell\v1.0\powershell.exe" -ArgumentList $a -Wait -PassThru -WindowStyle Hidden
            $p.ExitCode
        }
        $json = Invoke-Command -Session $session -ArgumentList $remoteDir -ScriptBlock {
            param($dir)
            $f = Get-ChildItem -LiteralPath $dir -Filter 'Windows10_SystemReport_*.json' | Sort-Object LastWriteTime -Descending | Select-Object -First 1
            if ($f) { Get-Content -LiteralPath $f.FullName -Raw -Encoding UTF8 }
        }
        if ($json) {
            $dest = Join-Path $Out ("{0}_{1}.json" -f $Computer, (Get-Date -Format 'yyyyMMdd_HHmmss'))
            [IO.File]::WriteAllText($dest, $json, (New-Object System.Text.UTF8Encoding($true)))
            $r = $json | ConvertFrom-Json
            $open = @($r.Findings | Where-Object { $_.Status -eq 'Open' })
            $w = @{ 'Critical' = 0; 'High' = 1; 'Medium' = 2; 'Low' = 3; 'Info' = 4 }
            $worst = ($open | Sort-Object { $w[$_.Severity] } | Select-Object -First 1).Severity
            $pen = @{ 'Critical' = 25; 'High' = 12; 'Medium' = 5; 'Low' = 2; 'Info' = 0 }
            $score = [math]::Max(0, 100 - (($open | ForEach-Object { $pen[$_.Severity] } | Measure-Object -Sum).Sum))
            $result.Status = 'OK'; $result.Score = $score; $result.Open = $open.Count; $result.Worst = $(if ($worst) { $worst } else { '-' }); $result.Detail = "exit $code"
        } else { $result.Detail = "No report produced (exit $code)." }
        Invoke-Command -Session $session -ArgumentList $remoteDir -ScriptBlock { param($d) Remove-Item -LiteralPath $d -Recurse -Force -ErrorAction SilentlyContinue }
    } catch { $result.Detail = $_.Exception.Message }
    finally { if ($session) { Remove-PSSession $session -ErrorAction SilentlyContinue } }
    [pscustomobject]$result
}

# Parallel execution without extra modules: one background job per computer, throttled
$jobs = @(); $results = @()
foreach ($c in $ComputerName) {
    while (@($jobs | Where-Object { $_.State -eq 'Running' }).Count -ge $ThrottleLimit) { Start-Sleep -Seconds 2 }
    Write-Host "Starting $c ..." -ForegroundColor Cyan
    $jobs += Start-Job -ScriptBlock $work -ArgumentList $c, $Credential, $ScriptPath, $OutputPath, [bool]$DryRun, $Modules
}
foreach ($j in $jobs) { $results += Receive-Job -Job $j -Wait; Remove-Job -Job $j -Force }

$results = $results | Sort-Object Computer
$results | Format-Table Computer, Status, Score, Open, Worst, Detail -AutoSize
$summary = Join-Path $OutputPath "FleetSummary_$stamp.csv"
$results | Export-Csv -LiteralPath $summary -NoTypeInformation -Encoding UTF8
Write-Host "Summary: $summary" -ForegroundColor Green
$failed = @($results | Where-Object Status -ne 'OK').Count
if ($failed -gt 0) { Write-Warning "$failed computer(s) failed." ; exit 1 }
