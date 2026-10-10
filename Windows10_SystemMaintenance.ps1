#requires -version 5.1
<#
.SYNOPSIS
    Windows 10 system maintenance: diagnostics, safe cleanup, repair, updates, optimization and a plain-language report.

.DESCRIPTION
    Interactive maintenance script exclusively for Windows 10.

    What the script does:
      * Diagnostics: system, disks (SMART), security, network, services, drivers, event log
      * Cleanup: temp files, caches, update cache, error reports, component store
      * Repair: DISM, SFC (with CBS log evaluation), WMI repository, file system, Windows Update components
      * Windows Update: installs security and quality updates. Windows 11 is NEVER installed
        (policy "target version = Windows 10" + filter + hiding the upgrade offers).
      * Microsoft Store / app updates (winget + Store background scan)
      * Optimizations: TRIM/defrag, Defender signatures, time synchronization, System Restore, etc.
      * Report: detailed Markdown report on the desktop with plain-language explanations

    The script does NO "debloat", no telemetry tweaks and does not disable any security features.
    Before making changes, a restore point is created (if possible).

.PARAMETER Auto
    Fully automatic run without prompts. Riskier actions (e.g. emptying the Recycle Bin, disabling SMB1) are
    skipped and listed in the report as open items.

.PARAMETER SkipRestorePoint
    Does not create a restore point.

.PARAMETER NoElevate
    Does not automatically restart with administrator rights.

.PARAMETER DryRun
    (Alias: -WhatIf) Diagnoses everything but changes nothing: no deletion, repair, install or setting change.
    Every skipped change is printed as "[DryRun] would ...".

.PARAMETER Modules
    Runs only the listed modules (implies non-interactive module selection). Valid: sys, net, disk, sec, evt, svc,
    audit, clean, integ, wu, store, opt, w11. Without -Auto the prompts still appear.

.PARAMETER ReportPath
    Folder for the report files. Default: the desktop (or %ProgramData%\Windows10_SystemMaintenance when run as SYSTEM).

.PARAMETER ReportFormat
    One or more of Markdown, Html, Json. Default: Markdown. A JSON snapshot is always stored in the log folder
    and is used for the "new since last run" comparison.

.PARAMETER LogRetentionDays
    Logs, snapshots and reports older than this many days are deleted from the log folder (default 60; 0 = keep all).

.PARAMETER Schedule
    Registers a weekly scheduled task (Sunday 03:00, runs as SYSTEM with -Auto) and exits. Use -Unschedule to remove it.

.PARAMETER Unschedule
    Removes the scheduled task created by -Schedule and exits.

.PARAMETER AllowOnBattery
    Long operations (DISM, SFC, updates, defrag) are normally skipped on battery power. This overrides that.

.EXAMPLE
    powershell.exe -ExecutionPolicy Bypass -File .\Windows10_SystemMaintenance.ps1

.EXAMPLE
    .\Windows10_SystemMaintenance.ps1 -DryRun -Modules sys,sec,audit -ReportFormat Markdown,Html

.EXAMPLE
    .\Windows10_SystemMaintenance.ps1 -Schedule

.NOTES
    Start: right-click the file > "Run with PowerShell" or use the command above.
    The script requests administrator rights itself (UAC prompt).
#>
[CmdletBinding()]
param(
    [switch]$Auto,
    [switch]$SkipRestorePoint,
    [switch]$NoElevate,
    [Alias('WhatIf')][switch]$DryRun,
    [string[]]$Modules,
    [string]$ReportPath,
    [string[]]$ReportFormat = @('Markdown'),
    [int]$LogRetentionDays = 60,
    [switch]$Schedule,
    [switch]$Unschedule,
    [switch]$AllowOnBattery
)

$ErrorActionPreference = 'Continue'
$script:Version = '3.0'
$script:TaskName = 'Windows10_SystemMaintenance_Weekly'

# ----------------------------------------------------------------------------------------------
# 0. Basics: admin rights, Windows 10 check
# ----------------------------------------------------------------------------------------------
function Test-IsAdmin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $pr = New-Object Security.Principal.WindowsPrincipal($id)
    return $pr.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

if ($env:OS -ne 'Windows_NT') {
    Write-Host 'This script only runs on Windows 10.' -ForegroundColor Red
    exit 1
}

if (-not (Test-IsAdmin)) {
    if (-not $NoElevate -and $PSCommandPath) {
        Write-Host 'Requesting administrator rights (please confirm the UAC prompt) ...' -ForegroundColor Yellow
        $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$PSCommandPath`"")
        foreach ($k in $PSBoundParameters.Keys) {
            $v = $PSBoundParameters[$k]
            if ($k -eq 'NoElevate') { continue }
            if ($v -is [switch]) { if ($v.IsPresent) { $argList += "-$k" } }
            elseif ($v -is [array]) { $argList += "-$k"; $argList += "`"$($v -join ',')`"" }
            else { $argList += "-$k"; $argList += "`"$v`"" }
        }
        # Always relaunch in Windows PowerShell 5.1: Checkpoint-Computer, Repair-WindowsImage etc. are native there.
        $psExe = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
        if (-not (Test-Path -LiteralPath $psExe)) { $psExe = (Get-Process -Id $PID).Path }
        try {
            Start-Process -FilePath $psExe -ArgumentList $argList -Verb RunAs -ErrorAction Stop
            exit 0
        } catch {
            Write-Host 'The administrator request was declined or failed.' -ForegroundColor Red
        }
    }
    Write-Host 'This script cannot work meaningfully without administrator rights. Please run it as administrator.' -ForegroundColor Red
    Read-Host 'Press Enter to exit' | Out-Null
    exit 3
}

# -Schedule / -Unschedule: manage the weekly task and exit.
if ($Schedule -or $Unschedule) {
    if ($Unschedule) {
        Unregister-ScheduledTask -TaskName $script:TaskName -Confirm:$false -ErrorAction SilentlyContinue
        Write-Host "Scheduled task '$($script:TaskName)' removed." -ForegroundColor Green
        exit 0
    }
    if (-not $PSCommandPath) { Write-Host 'Scheduling needs the script to be run from a file.' -ForegroundColor Red; exit 1 }
    $taskArgs = "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`" -Auto -NoElevate"
    $psExe = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $trigger = New-ScheduledTaskTrigger -Weekly -DaysOfWeek Sunday -At 3am
    $action = New-ScheduledTaskAction -Execute $psExe -Argument $taskArgs
    $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
    $settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -ExecutionTimeLimit (New-TimeSpan -Hours 4) -MultipleInstances IgnoreNew
    Register-ScheduledTask -TaskName $script:TaskName -Trigger $trigger -Action $action -Principal $principal -Settings $settings -Force | Out-Null
    Write-Host "Scheduled task '$($script:TaskName)' registered: Sundays 03:00 as SYSTEM (-Auto). Reports go to %ProgramData%\Windows10_SystemMaintenance\Reports." -ForegroundColor Green
    exit 0
}

# Only one instance at a time (two parallel DISM/SFC/update runs would corrupt each other).
$script:Mutex = New-Object Threading.Mutex($false, 'Global\Windows10_SystemMaintenance')
$script:HasMutex = $false
try { $script:HasMutex = $script:Mutex.WaitOne(0) } catch [Threading.AbandonedMutexException] { $script:HasMutex = $true }
if (-not $script:HasMutex) {
    Write-Host 'Another instance of this script is already running. Exiting.' -ForegroundColor Red
    exit 4
}

# Normalise array parameters (the elevated relaunch passes them as "a,b").
$script:ModuleList = @($Modules | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim().ToLower() } | Where-Object { $_ })
$script:ReportFormats = @($ReportFormat | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ })
$validModules = 'sys', 'net', 'disk', 'sec', 'evt', 'svc', 'audit', 'clean', 'integ', 'wu', 'store', 'opt', 'w11'
$badModules = @($script:ModuleList | Where-Object { $_ -notin $validModules })
if ($badModules.Count -gt 0) { Write-Host "Unknown module(s): $($badModules -join ', '). Valid: $($validModules -join ', ')" -ForegroundColor Red; exit 1 }
$badFormats = @($script:ReportFormats | Where-Object { $_ -notin 'Markdown', 'Html', 'Json' })
if ($badFormats.Count -gt 0) { Write-Host "Unknown report format(s): $($badFormats -join ', '). Valid: Markdown, Html, Json" -ForegroundColor Red; exit 1 }

$script:Auto = [bool]$Auto
$script:DryRun = [bool]$DryRun
$script:AllowOnBattery = [bool]$AllowOnBattery
$script:IsSystem = [Security.Principal.WindowsIdentity]::GetCurrent().IsSystem
$script:ExitCode = 0
$script:StartedAt = Get-Date
$script:Findings = New-Object System.Collections.Generic.List[object]
$script:Actions = New-Object System.Collections.Generic.List[object]
$script:Facts = [ordered]@{}
$script:Tables = [ordered]@{}
$script:RebootNeeded = $false
$script:RebootReasons = New-Object System.Collections.Generic.List[string]
$script:Online = $false
$script:RestorePointDone = $false
$script:Win11BlockState = 'not checked'
$script:FreedTotal = [int64]0
$script:Desktop = [Environment]::GetFolderPath('Desktop')
$dataRoot = if ($script:IsSystem -or -not $env:LOCALAPPDATA) { Join-Path $env:ProgramData 'Windows10_SystemMaintenance' } else { Join-Path $env:LOCALAPPDATA 'Windows10_SystemMaintenance' }
if ($ReportPath) { $script:ReportDir = $ReportPath }
elseif ($script:IsSystem -or -not $script:Desktop) { $script:ReportDir = Join-Path $env:ProgramData 'Windows10_SystemMaintenance\Reports' }
else { $script:ReportDir = $script:Desktop }
try { New-Item -ItemType Directory -Path $script:ReportDir -Force | Out-Null } catch { $script:ReportDir = $env:TEMP }
$stamp = Get-Date -Format 'yyyyMMdd_HHmmss'
$script:ReportBase = Join-Path $script:ReportDir ("Windows10_SystemReport_{0}" -f $stamp)
$script:ReportPath = "$($script:ReportBase).md"
$script:LogDir = Join-Path $dataRoot 'Logs'
$script:SnapshotDir = Join-Path $dataRoot 'Snapshots'
$script:LogPath = Join-Path $script:LogDir ("SystemMaintenance_{0}.log" -f $stamp)
try {
    New-Item -ItemType Directory -Path $script:LogDir -Force | Out-Null
    New-Item -ItemType Directory -Path $script:SnapshotDir -Force | Out-Null
    Start-Transcript -Path $script:LogPath -Force | Out-Null
    $script:TranscriptOn = $true
} catch { $script:TranscriptOn = $false }

# Log/snapshot retention (reports on the desktop are the user's and are not touched).
if ($LogRetentionDays -gt 0) {
    foreach ($d in $script:LogDir, $script:SnapshotDir) {
        Get-ChildItem -LiteralPath $d -File -ErrorAction SilentlyContinue |
            Where-Object { $_.LastWriteTime -lt (Get-Date).AddDays(-$LogRetentionDays) } |
            Remove-Item -Force -ErrorAction SilentlyContinue
    }
}

# Keep the PC awake during long operations (DISM/SFC/updates take 30+ minutes).
try {
    Add-Type -Namespace Win32 -Name PowerState -MemberDefinition '[DllImport("kernel32.dll")] public static extern uint SetThreadExecutionState(uint esFlags);' -ErrorAction Stop
    # ES_CONTINUOUS | ES_SYSTEM_REQUIRED
    [void][Win32.PowerState]::SetThreadExecutionState([uint32]2147483649)
} catch {}

try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch {}

# ----------------------------------------------------------------------------------------------
# 1. Helper functions: output, input, findings
# ----------------------------------------------------------------------------------------------
function Write-Title([string]$Text) {
    Write-Host ''
    Write-Host ('=' * 74) -ForegroundColor DarkCyan
    Write-Host ("  $Text") -ForegroundColor Cyan
    Write-Host ('=' * 74) -ForegroundColor DarkCyan
}
function Write-Info([string]$m) { Write-Host "  [i]  $m" -ForegroundColor Gray }
function Write-Ok([string]$m)   { Write-Host "  [OK] $m" -ForegroundColor Green }
function Write-Warn2([string]$m){ Write-Host "  [!]  $m" -ForegroundColor Yellow }
function Write-Bad([string]$m)  { Write-Host "  [X]  $m" -ForegroundColor Red }

function Confirm-Step {
    # Yes/no prompt. -Risky: in Auto mode it is NOT executed.
    param([string]$Question, [bool]$Default = $true, [switch]$Risky, [switch]$ReadOnly)
    if ($script:DryRun -and -not $ReadOnly) { Write-Info "[DryRun] would ask/do: $Question"; return $false }
    if ($script:Auto) {
        if ($Risky) { Write-Info "[Auto] skipped (needs your decision): $Question"; return $false }
        return $Default
    }
    $hint = if ($Default) { 'Y/n' } else { 'y/N' }
    $a = Read-Host "  ?  $Question [$hint]"
    if ([string]::IsNullOrWhiteSpace($a)) { return $Default }
    return ($a.Trim() -match '^(y|yes|j|ja)$')
}

function Test-DryRun([string]$What) {
    # Returns $true (and says so) when a change must be skipped because of -DryRun.
    if ($script:DryRun) { Write-Info "[DryRun] would: $What"; return $true }
    return $false
}

function Test-OnBattery {
    try {
        $b = Get-CimInstance Win32_Battery -ErrorAction Stop | Select-Object -First 1
        return ($b -and $b.BatteryStatus -eq 1)   # 1 = discharging
    } catch { return $false }
}

function Test-LongOperationAllowed {
    # Guards DISM/SFC/updates/defrag: battery, metered connection, free space.
    param([string]$Name, [double]$MinFreeGB = 0)
    if (-not $script:AllowOnBattery -and (Test-OnBattery)) {
        Write-Warn2 "$Name skipped: the PC runs on battery power. Plug it in or use -AllowOnBattery."
        Add-Action $Name 'Skipped' 'Running on battery power.'
        return $false
    }
    if ($MinFreeGB -gt 0) {
        $free = (Get-SystemFreeBytes) / 1GB
        if ($free -lt $MinFreeGB) {
            Write-Warn2 ("{0} skipped: only {1:N1} GB free on the system drive (needs about {2} GB)." -f $Name, $free, $MinFreeGB)
            Add-Action $Name 'Skipped' ("Only {0:N1} GB free." -f $free)
            return $false
        }
    }
    return $true
}

function Invoke-WithTimeout {
    # Runs a script block in a background job; kills it after the timeout. Returns @{ Completed; Output; Error }.
    param([scriptblock]$Body, [int]$TimeoutSec = 900, [object[]]$ArgumentList = @())
    $job = Start-Job -ScriptBlock $Body -ArgumentList $ArgumentList
    $done = Wait-Job -Job $job -Timeout $TimeoutSec
    $out = $null; $err = $null
    if ($done) {
        try { $out = Receive-Job -Job $job -ErrorAction Stop } catch { $err = $_.Exception.Message }
    } else { Stop-Job -Job $job -ErrorAction SilentlyContinue }
    Remove-Job -Job $job -Force -ErrorAction SilentlyContinue
    return [pscustomobject]@{ Completed = [bool]$done; Output = $out; Error = $err }
}

function Add-Action {
    param([string]$Module, [string]$Status, [string]$Details)
    $script:Actions.Add([pscustomobject]@{ Time = (Get-Date -Format 'HH:mm:ss'); Module = $Module; Status = $Status; Details = $Details })
}
function Add-Fact([string]$Key, $Value) { $script:Facts[$Key] = "$Value" }

$script:SevRank = @{ 'Critical' = 0; 'High' = 1; 'Medium' = 2; 'Low' = 3; 'Info' = 4 }

function Add-Finding {
    param(
        [Parameter(Mandatory)][string]$Id,
        [Parameter(Mandatory)][ValidateSet('Critical','High','Medium','Low','Info')][string]$Severity,
        [Parameter(Mandatory)][string]$Category,
        [Parameter(Mandatory)][string]$Title,
        [Parameter(Mandatory)][string]$Meaning,
        [string]$Evidence = '',
        [string]$Recommendation = '',
        [ValidateSet('Open','Fixed','Info')][string]$Status = 'Open'
    )
    $old = $script:Findings | Where-Object { $_.Id -eq $Id } | Select-Object -First 1
    if ($old) { [void]$script:Findings.Remove($old) }
    $script:Findings.Add([pscustomobject]@{
        Id = $Id; Severity = $Severity; Category = $Category; Title = $Title; Meaning = $Meaning
        Evidence = $Evidence; Recommendation = $Recommendation; Status = $Status
    })
    $color = switch ($Severity) { 'Critical' { 'Red' } 'High' { 'Red' } 'Medium' { 'Yellow' } 'Low' { 'DarkYellow' } default { 'Gray' } }
    $tag = if ($Status -eq 'Fixed') { 'FIXED' } else { $Severity.ToUpper() }
    Write-Host ("  [{0}] {1}" -f $tag, $Title) -ForegroundColor $color
}

function Set-FindingFixed {
    param([string]$Id, [string]$WhatWasDone)
    $f = $script:Findings | Where-Object { $_.Id -eq $Id } | Select-Object -First 1
    if ($f) {
        $f.Status = 'Fixed'
        if ($WhatWasDone) { $f.Recommendation = $WhatWasDone }
        Write-Ok "Fixed: $($f.Title)"
    }
}

function Request-Reboot([string]$Reason) {
    $script:RebootNeeded = $true
    if (-not $script:RebootReasons.Contains($Reason)) { $script:RebootReasons.Add($Reason) }
}

function Invoke-Module {
    param([string]$Name, [scriptblock]$Body)
    Write-Title $Name
    try { & $Body }
    catch {
        Write-Bad "Unexpected error in module: $($_.Exception.Message)"
        Add-Action $Name 'Error' $_.Exception.Message
        Add-Finding -Id "module-$Name" -Severity 'Low' -Category 'Script' `
            -Title "Module '$Name' was not fully executed" `
            -Meaning 'An unexpected error occurred in one step of the script. The remaining modules were run anyway. This is usually a sign of a blocked or broken Windows component.' `
            -Evidence $_.Exception.Message `
            -Recommendation 'Run the script again. If the error recurs, research the error text together with the console log (path at the end of the report).'
    }
}

function Format-Size([double]$Bytes) {
    if ($Bytes -ge 1GB) { return ('{0:N2} GB' -f ($Bytes / 1GB)) }
    if ($Bytes -ge 1MB) { return ('{0:N1} MB' -f ($Bytes / 1MB)) }
    if ($Bytes -ge 1KB) { return ('{0:N0} KB' -f ($Bytes / 1KB)) }
    return ('{0:N0} Byte' -f $Bytes)
}

function Invoke-Native {
    # Runs a console program and collects its output (NUL characters from UTF-16 are removed).
    param([string]$File, [string[]]$Arguments, [switch]$Quiet, [int]$TimeoutSec = 0)
    $lines = New-Object System.Collections.Generic.List[string]
    if ($TimeoutSec -gt 0) {
        # Time-limited run: output goes through a temp file; the process is killed when the limit is exceeded.
        $tmp = Join-Path $env:TEMP ("w10m_{0}.txt" -f [guid]::NewGuid().ToString('N'))
        $argStr = ($Arguments | ForEach-Object { if ($_ -match '\s') { "`"$_`"" } else { $_ } }) -join ' '
        $timedOut = $false; $code = -1
        try {
            $p = Start-Process -FilePath $File -ArgumentList $argStr -NoNewWindow -PassThru -RedirectStandardOutput $tmp -ErrorAction Stop
            if (-not $p.WaitForExit($TimeoutSec * 1000)) { $timedOut = $true; try { $p.Kill() } catch {} } else { $code = $p.ExitCode }
        } catch { $code = -1 }
        if (Test-Path -LiteralPath $tmp) {
            $bytes = [IO.File]::ReadAllBytes($tmp)
            # sfc.exe writes UTF-16, most other tools write the OEM/ANSI code page.
            $isUtf16 = ($bytes.Length -gt 1 -and ($bytes | Select-Object -First 200 | Where-Object { $_ -eq 0 }).Count -gt 10)
            $text = if ($isUtf16) { [Text.Encoding]::Unicode.GetString($bytes) } else { [Text.Encoding]::Default.GetString($bytes) }
            foreach ($raw in ($text -split "`r?`n")) {
                $l = (([string]$raw) -replace "`0", '').Trim()
                if ($l) { $lines.Add($l); if (-not $Quiet) { Write-Host "       $l" -ForegroundColor DarkGray } }
            }
            Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
        }
        return [pscustomobject]@{ ExitCode = $code; Output = ($lines -join "`n"); TimedOut = $timedOut }
    }
    & $File @Arguments 2>&1 | ForEach-Object {
        $l = (([string]$_) -replace "`0", '') -replace '[\r\n]+', ' '
        $l = $l.Trim()
        if ($l) {
            $lines.Add($l)
            if (-not $Quiet) { Write-Host "       $l" -ForegroundColor DarkGray }
        }
    }
    return [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = ($lines -join "`n") }
}

function Get-HResultHex($Exception) {
    try { return ('{0:X8}' -f [int]$Exception.HResult) } catch { return '00000000' }
}

function Get-SystemFreeBytes {
    try { return [int64](New-Object IO.DriveInfo($env:SystemDrive)).AvailableFreeSpace } catch { return [int64]0 }
}

function Get-FilesSafe {
    # Walks a folder without following junctions/symlinks (prevents deleting outside the target folder).
    param([string]$Path, [System.Collections.Generic.List[string]]$DirList)
    $stack = New-Object System.Collections.Generic.Stack[string]
    $stack.Push($Path)
    while ($stack.Count -gt 0) {
        $dir = $stack.Pop()
        $items = Get-ChildItem -LiteralPath $dir -Force -ErrorAction SilentlyContinue
        foreach ($it in $items) {
            if ($it.Attributes -band [IO.FileAttributes]::ReparsePoint) { continue }
            if ($it.PSIsContainer) {
                $stack.Push($it.FullName)
                if ($DirList) { $DirList.Add($it.FullName) }
            } else { $it }
        }
    }
}

function Get-FolderBytes([string]$Path) {
    if (-not $Path -or -not (Test-Path -LiteralPath $Path -ErrorAction SilentlyContinue)) { return [int64]0 }
    $sum = [int64]0
    foreach ($f in (Get-FilesSafe -Path $Path)) { $sum += [int64]$f.Length }
    return $sum
}

function Clear-Folder {
    # Deletes files in a folder (optionally only older ones). Locked files are skipped.
    param([string]$Path, [int]$OlderThanDays = 0, [string]$NameLike = '*')
    $res = [pscustomobject]@{ Freed = [int64]0; Files = 0; Failed = 0 }
    if (-not $Path -or -not (Test-Path -LiteralPath $Path -ErrorAction SilentlyContinue)) { return $res }
    $cutoff = (Get-Date).AddDays(-$OlderThanDays)
    $dirs = New-Object System.Collections.Generic.List[string]
    foreach ($f in (Get-FilesSafe -Path $Path -DirList $dirs)) {
        if ($f.Name -notlike $NameLike) { continue }
        if ($OlderThanDays -gt 0 -and $f.LastWriteTime -gt $cutoff) { continue }
        try {
            $len = [int64]$f.Length
            if (-not $script:DryRun) { Remove-Item -LiteralPath $f.FullName -Force -ErrorAction Stop }
            $res.Freed += $len; $res.Files++
        } catch { $res.Failed++ }
    }
    if ($script:DryRun) { return $res }   # nothing deleted: the numbers are what WOULD be freed
    for ($i = $dirs.Count - 1; $i -ge 0; $i--) {
        try { [IO.Directory]::Delete($dirs[$i]) } catch {}   # fails on non-empty folders (intended)
    }
    return $res
}

function Get-BackupFolderAge($Dir) {
    # Folder names look like "SoftwareDistribution.bak_20250131_142501" -> age in days (999 if unparsable = old).
    if ($Dir.Name -match '_(\d{8}_\d{6})$') {
        try { return ((Get-Date) - [datetime]::ParseExact($Matches[1], 'yyyyMMdd_HHmmss', [Globalization.CultureInfo]::InvariantCulture)).TotalDays } catch {}
    }
    return 999
}

function Test-PendingReboot {
    $reasons = @()
    if (Test-Path 'HKLM:\SOFTWARE\Microsoft\Updates\UpdateExeVolatile') {
        $v = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Updates\UpdateExeVolatile' -ErrorAction SilentlyContinue).Flags
        if ($v -and $v -ne 0) { $reasons += 'Update installer (UpdateExe)' }
    }
    try {
        $a = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\ComputerName\ActiveComputerName' -ErrorAction Stop).ComputerName
        $p = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\ComputerName\ComputerName' -ErrorAction Stop).ComputerName
        if ($a -ne $p) { $reasons += 'Pending computer rename' }
    } catch {}
    if (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending') { $reasons += 'Component servicing (CBS)' }
    if (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired') { $reasons += 'Windows Update' }
    try {
        $p = Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager' -Name PendingFileRenameOperations -ErrorAction Stop
        # Leftover temp-file deletions (often from antivirus/installers) are harmless noise -> ignore those.
        $real = @($p.PendingFileRenameOperations | Where-Object { $_ -and $_ -notmatch '(?i)\\Temp\\|\.tmp$|\\Microsoft\\Windows Defender\\' })
        if ($real.Count -gt 0) { $reasons += 'Pending file rename operations' }
    } catch {}
    return $reasons
}

# ----------------------------------------------------------------------------------------------
# 2. Knowledge base: error codes and events in plain language
# ----------------------------------------------------------------------------------------------
function Get-WuErrorInfo([string]$Hex) {
    $h = $Hex.ToUpper().Replace('0X', '')
    $kb = @{
        '80070002' = @{ M = 'A file required for the update was not found. The update cache (SoftwareDistribution) is usually corrupted.'; F = 'Reset the update components (the script offers this).'; Reset = $true }
        '80070003' = @{ M = 'A path in the update store was not found. The update cache is probably corrupted.'; F = 'Reset the update components.'; Reset = $true }
        '80070005' = @{ M = 'Access denied. Security software or a faulty permission often blocks the update process.'; F = 'Check/temporarily disable third-party antivirus, restart, try again.'; Reset = $false }
        '8007000E' = @{ M = 'Not enough memory for the operation.'; F = 'Close programs, restart, try again. If it recurs, test the RAM (mdsched.exe).'; Reset = $false }
        '80070057' = @{ M = 'Invalid parameter. Typical for corrupted update data or a damaged component store.'; F = 'Run DISM/SFC repair, then reset the update components.'; Reset = $true }
        '80070070' = @{ M = 'Not enough free space on the system drive.'; F = 'Free up at least 10-20 GB and try again.'; Reset = $false }
        '80070422' = @{ M = 'A service required for updates is disabled.'; F = 'The script automatically resets disabled update services; then try again.'; Reset = $false }
        '80070490' = @{ M = 'An element was not found in the component store - the Windows component store is damaged.'; F = 'Run DISM /RestoreHealth and SFC (Integrity module).'; Reset = $false }
        '800705B4' = @{ M = 'Timeout during the update operation.'; F = 'Check the network, try again later.'; Reset = $false }
        '80070643' = @{ M = 'Fatal error during installation (often .NET Framework or Windows Installer).'; F = 'Repair .NET Framework with the Microsoft repair tool, restart, try again.'; Reset = $false }
        '80070BC2' = @{ M = 'The update is installed but still needs a restart.'; F = 'Restart Windows.'; Reset = $false }
        '80073712' = @{ M = 'A file in the component store required by the update is missing or corrupted.'; F = 'Run DISM /RestoreHealth and SFC.'; Reset = $false }
        '8007371B' = @{ M = 'A transaction in the component store is incomplete - indicates a damaged component store.'; F = 'Run DISM /RestoreHealth and SFC.'; Reset = $false }
        '800F081F' = @{ M = 'The source files for repair or installation were not found.'; F = 'Run DISM /RestoreHealth (with an internet connection).'; Reset = $false }
        '800F0831' = @{ M = 'A previous update that serves as a prerequisite is missing or corrupted.'; F = 'Run DISM /RestoreHealth, reset the update components.'; Reset = $true }
        '800F0922' = @{ M = 'The update could not be completed. Causes: system partition too small, active VPN connection or a network problem.'; F = 'Disconnect the VPN, restart, try again. If it recurs, check free space on the system reserved partition.'; Reset = $false }
        '80240017' = @{ M = 'The update is not applicable to this computer.'; F = 'The update can usually be ignored.'; Reset = $false }
        '8024001E' = @{ M = 'The operation was cancelled because the service or the system was shutting down.'; F = 'Restart and try again.'; Reset = $false }
        '80240020' = @{ M = 'No user is signed in who could confirm the update.'; F = 'Stay signed in and try again.'; Reset = $false }
        '80240034' = @{ M = 'The update download failed. The update cache is usually corrupted or the connection was interrupted.'; F = 'Reset the update components and try again.'; Reset = $true }
        '8024200D' = @{ M = 'The update needs a new download - the local data is incomplete.'; F = 'Reset the update components.'; Reset = $true }
        '80246007' = @{ M = 'The download service (BITS) did not fully download the update.'; F = 'Reset the update components, check the BITS service.'; Reset = $true }
        '8024401C' = @{ M = 'Timeout when connecting to the update servers.'; F = 'Check internet, proxy, firewall and DNS.'; Reset = $false }
        '8024402C' = @{ M = 'The update servers could not be reached (proxy, DNS or firewall).'; F = 'Check proxy settings (netsh winhttp show proxy), DNS and firewall.'; Reset = $false }
        '80244022' = @{ M = 'The update servers reply with "service unavailable" (HTTP 503), usually a temporary server problem.'; F = 'Try again after a few hours.'; Reset = $false }
        '80072EE2' = @{ M = 'Timeout during the internet connection.'; F = 'Check internet connection, proxy and DNS.'; Reset = $false }
        '80072EE7' = @{ M = 'The server name could not be resolved (DNS problem).'; F = 'Check DNS settings (e.g. restart the router, use a different DNS server).'; Reset = $false }
        '80072EFD' = @{ M = 'No connection to the server possible (network, firewall or proxy).'; F = 'Check network, firewall and proxy.'; Reset = $false }
        '80072F8F' = @{ M = 'Security/certificate error - usually the PC date or time is wrong.'; F = 'Correct the date, time and time zone and run time synchronization.'; Reset = $false }
        'C1900101' = @{ M = 'A driver aborted the installation of a large update (rollback).'; F = 'Update drivers, disconnect extra devices, check disks, try again.'; Reset = $false }
    }
    if ($kb.ContainsKey($h)) { return $kb[$h] }
    return @{ M = "Windows Update reported error code 0x$h, which the script does not know in detail."; F = "Research the code '0x$h' online (search: 'Windows Update 0x$h') and reset the update components."; Reset = $false }
}

$script:BugCheckNames = @{
    '0x0000000a' = 'IRQL_NOT_LESS_OR_EQUAL - a driver accessed memory illegally'
    '0x0000001a' = 'MEMORY_MANAGEMENT - memory management error, often defective RAM'
    '0x0000001e' = 'KMODE_EXCEPTION_NOT_HANDLED - driver or hardware problem'
    '0x0000003b' = 'SYSTEM_SERVICE_EXCEPTION - usually a faulty driver (often graphics)'
    '0x00000050' = 'PAGE_FAULT_IN_NONPAGED_AREA - invalid memory access, RAM or driver'
    '0x0000007a' = 'KERNEL_DATA_INPAGE_ERROR - read error from the disk'
    '0x0000007b' = 'INACCESSIBLE_BOOT_DEVICE - Windows cannot access the boot drive'
    '0x0000007e' = 'SYSTEM_THREAD_EXCEPTION_NOT_HANDLED - faulty driver'
    '0x0000009f' = 'DRIVER_POWER_STATE_FAILURE - driver problem during power saving/standby'
    '0x000000d1' = 'DRIVER_IRQL_NOT_LESS_OR_EQUAL - faulty driver (often network/WLAN)'
    '0x000000ef' = 'CRITICAL_PROCESS_DIED - a critical Windows process was terminated'
    '0x000000f4' = 'CRITICAL_OBJECT_TERMINATION - disk or critical process failed'
    '0x00000101' = 'CLOCK_WATCHDOG_TIMEOUT - a processor core is not responding (CPU/BIOS/overclocking)'
    '0x00000116' = 'VIDEO_TDR_FAILURE - graphics driver/graphics card no longer responds'
    '0x00000124' = 'WHEA_UNCORRECTABLE_ERROR - severe hardware error (CPU, RAM, mainboard, power supply)'
    '0x00000133' = 'DPC_WATCHDOG_VIOLATION - a driver is blocking the system (often SSD/chipset driver)'
    '0x00000139' = 'KERNEL_SECURITY_CHECK_FAILURE - memory error or driver error'
    '0x000000c2' = 'BAD_POOL_CALLER - faulty driver'
    '0x000000c5' = 'DRIVER_CORRUPTED_EXPOOL - faulty driver'
}

$script:EventKb = @{
    'Microsoft-Windows-Kernel-Power|41' = @{ S = 'High'; T = 'Unexpected restarts or crashes (Kernel-Power 41)'
        M = 'The PC restarted without having been shut down cleanly beforehand. Typical causes: blue screen, power outage, overheating, faulty power supply, unstable driver or holding the power button.'
        A = 'Check temperatures, fans and power supply/outlet, update graphics and chipset drivers, test the RAM (Windows Memory Diagnostic: mdsched.exe). For blue screens, note the stop code in this report.' }
    'EventLog|6008' = @{ S = 'Low'; T = 'Previous shutdown was unexpected (EventLog 6008)'; Min = 2
        M = 'Windows logs that the last shutdown did not proceed properly (crash, power loss or hard power-off).'
        A = 'Isolated cases are harmless. If they accumulate, see the note on Kernel-Power 41.' }
    'disk|7' = @{ S = 'Critical'; T = 'Bad block on a disk (disk 7)'
        M = 'Windows could not read an area on the disk. This is a clear warning sign of an impending failure of the hard drive/SSD or a faulty cable/USB enclosure.'
        A = 'Make a backup of important data IMMEDIATELY. Then run the drive manufacturer''s diagnostic tool and check the cable/connector. Replace the drive if further errors occur.' }
    'disk|11' = @{ S = 'High'; T = 'Controller error during disk access (disk 11)'
        M = 'The disk controller responded incorrectly to a request. Common causes are loose/defective SATA cables, power supply problems, drivers or a dying drive.'
        A = 'Check cables and connectors, update chipset/storage controller drivers, check SMART values. Back up important data.' }
    'disk|51' = @{ S = 'High'; T = 'Error accessing the page file (disk 51)'
        M = 'An error occurred while reading/writing the page file - an indication of disk problems.'
        A = 'Check disk health (see SMART section), make a backup.' }
    'disk|153' = @{ S = 'Medium'; T = 'Disk accesses had to be retried (disk 153)'; Min = 3
        M = 'Windows had to repeat read/write accesses. This occurs with unstable connections or aging drives.'
        A = 'Check the cable/USB connection, update the drive firmware, monitor the SMART values.' }
    'Ntfs|55' = @{ S = 'High'; T = 'File system corruption detected (NTFS 55)'
        M = 'The NTFS file system reported an inconsistency in its management structure. This can happen after crashes or with disk errors.'
        A = 'Run a disk check with repair (chkdsk /F, requires a restart) and check disk health.' }
    'Microsoft-Windows-Ntfs|55' = @{ S = 'High'; T = 'File system corruption detected (NTFS 55)'
        M = 'The NTFS file system reported an inconsistency in its management structure. This can happen after crashes or with disk errors.'
        A = 'Run a disk check with repair (chkdsk /F, requires a restart) and check disk health.' }
    'Microsoft-Windows-WHEA-Logger|17' = @{ S = 'High'; T = 'Hardware error reported (WHEA 17)'
        M = 'The hardware error monitoring (WHEA) reported a hardware error, e.g. on the PCIe bus. This points to a hardware problem or an unstable driver/BIOS.'
        A = 'Update BIOS and chipset drivers, undo overclocking, reseat expansion cards, check temperatures.' }
    'Microsoft-Windows-WHEA-Logger|18' = @{ S = 'Critical'; T = 'Severe hardware error (WHEA 18)'
        M = 'An uncorrectable hardware error was detected (CPU, RAM or mainboard). It often leads to blue screens.'
        A = 'Test the RAM (mdsched.exe), remove overclocking, update the BIOS, check temperatures. If necessary contact the manufacturer''s support or a repair shop.' }
    'Microsoft-Windows-WHEA-Logger|19' = @{ S = 'Medium'; T = 'Corrected hardware error (WHEA 19)'; Min = 3
        M = 'The hardware corrected an error itself. Harmless when isolated, a sign of unstable hardware when frequent.'
        A = 'Monitor. If frequent, update BIOS/drivers and check the hardware.' }
    'Display|4101' = @{ S = 'Medium'; T = 'Graphics driver stopped responding (Display 4101)'
        M = 'The graphics driver stopped responding and was reset by Windows (screen flickers/briefly goes black). Causes: outdated driver, overheated or overclocked graphics card.'
        A = 'Update the graphics driver directly from the manufacturer (NVIDIA/AMD/Intel), check temperatures.' }
    'Microsoft-Windows-WER-SystemErrorReporting|1001' = @{ S = 'High'; T = 'Blue screen (bugcheck) occurred'
        M = 'Windows was halted because of a severe error (blue screen) and restarted.'
        A = 'Note the stop code in the detail list of this report. Update drivers and Windows, check RAM and disks.' }
    'Service Control Manager|7000' = @{ S = 'Medium'; T = 'A Windows service could not be started (7000)'; Min = 2
        M = 'A background service does not start. Consequences: depending on the service, missing functions (network, updates, driver software).'
        A = 'Check the affected service in the details; reinstall or update the related software.' }
    'Service Control Manager|7001' = @{ S = 'Medium'; T = 'Service does not start because of a missing dependency (7001)'; Min = 2
        M = 'A service needs another service that is not running.'
        A = 'Check the dependencies in the Services manager (services.msc) or reinstall the software.' }
    'Service Control Manager|7009' = @{ S = 'Low'; T = 'Timeout during service start (7009)'; Min = 3
        M = 'A service took too long to start. This occurs on overloaded systems or slow drives.'
        A = 'Reduce autostart items, check disk health.' }
    'Service Control Manager|7023' = @{ S = 'Medium'; T = 'Service terminated with an error (7023)'; Min = 2
        M = 'A service terminated itself with an error message.'
        A = 'Check the affected service in the details; update or reinstall the related software.' }
    'Service Control Manager|7031' = @{ S = 'Medium'; T = 'Service terminated unexpectedly (7031)'; Min = 2
        M = 'A service crashed (Windows may try to restart the service).'
        A = 'Check the affected service in the details; update or reinstall the related software.' }
    'Service Control Manager|7034' = @{ S = 'Medium'; T = 'Service terminated unexpectedly (7034)'; Min = 2
        M = 'A service crashed and was not restarted.'
        A = 'Check the affected service in the details; update or reinstall the related software.' }
    'Microsoft-Windows-WindowsUpdateClient|20' = @{ S = 'Medium'; T = 'Installation of a Windows update failed'
        M = 'At least one Windows update could not be installed. The script''s update module evaluates the error code and attempts a repair.'
        A = 'See the Windows Update section in this report.' }
    'Microsoft-Windows-Resource-Exhaustion-Detector|2004' = @{ S = 'Medium'; T = 'Memory was exhausted (Resource-Exhaustion 2004)'
        M = 'Windows reported that virtual memory ran low; programs may crash or the system becomes sluggish.'
        A = 'Use fewer programs at the same time, let the page file be managed automatically, install more RAM if necessary.' }
}
$script:EventKb += @{
    'storahci|129' = @{ S = 'High'; T = 'Storage controller reset (storahci 129)'; Min = 2
        M = 'The SATA/AHCI controller did not answer in time and Windows had to reset it. Typical for a failing drive, a loose or bad SATA cable/power connector, or an outdated storage driver.'
        A = 'Check SATA cable and power, update chipset/storage drivers, check SMART values. Back up important data.' }
    'stornvme|129' = @{ S = 'High'; T = 'NVMe controller reset (stornvme 129)'; Min = 2
        M = 'The NVMe SSD stopped responding for a moment and Windows reset it. Causes: SSD firmware bugs, overheating, power management (ASPM/APST) or a failing SSD.'
        A = 'Update SSD firmware and chipset drivers, check temperature and seating of the M.2 drive, back up important data.' }
    'Microsoft-Windows-Kernel-PnP|219' = @{ S = 'Low'; T = 'A driver could not be loaded (Kernel-PnP 219)'; Min = 3
        M = 'Windows failed to load a driver for a device. The device may be missing or limited.'
        A = 'Check Device Manager for the affected device and update/reinstall its driver.' }
    'Microsoft-Windows-Kernel-Power|109' = @{ S = 'Low'; T = 'Kernel power transition error (Kernel-Power 109)'; Min = 3
        M = 'A shutdown or sleep transition did not complete cleanly.'
        A = 'Update chipset and BIOS; try disabling Fast Startup if shutdowns misbehave.' }
    'volsnap|36' = @{ S = 'Medium'; T = 'Shadow copies were aborted (volsnap 36)'
        M = 'Volume Shadow Copy ran out of space and deleted snapshots. Restore points and file history backups may be incomplete.'
        A = 'Increase the shadow storage size (vssadmin Resize ShadowStorage) or free disk space.' }
    'Ntfs|140' = @{ S = 'Medium'; T = 'NTFS could not write data to the volume (NTFS 140)'
        M = 'The file system could not flush data to the disk. Often an early sign of a failing drive or a flaky USB enclosure.'
        A = 'Check disk health, cable/USB connection and run a file system check.' }
    'Tcpip|4227' = @{ S = 'Low'; T = 'TCP port exhaustion (Tcpip 4227)'; Min = 3
        M = 'A program opened too many connections in a short time and Windows ran out of local ports.'
        A = 'Find the program with many connections (netstat -ano), restart or update it.' }
    'Schannel|36887' = @{ S = 'Low'; T = 'TLS alert received (Schannel 36887)'; Min = 5
        M = 'A secure connection was rejected by the other side. Occasional entries are normal; many point to outdated software/TLS settings or a wrong system date.'
        A = 'Check date/time, update the affected software.' }
    'Microsoft-Windows-WindowsUpdateClient|25' = @{ S = 'Medium'; T = 'Windows Update could not download an update (WindowsUpdateClient 25)'; Min = 2
        M = 'An update download failed. See the Windows Update section for the error code.'
        A = 'Run the Windows Update module; reset the update components if it recurs.' }
    'MsiInstaller|11708' = @{ S = 'Low'; T = 'An installation failed (MsiInstaller 11708)'; Min = 2
        M = 'A Windows Installer package could not be installed or updated.'
        A = 'Run the installer again as administrator; remove leftovers of the old version first.' }
    'Microsoft-Windows-Windows Defender|3002' = @{ S = 'High'; T = 'Defender real-time protection failed (Defender 3002)'
        M = 'Microsoft Defender could not keep its real-time protection running. The PC may be unprotected.'
        A = 'Open Windows Security; check for conflicting security software; run sfc /scannow and update Defender.' }
    'Microsoft-Windows-Windows Defender|1116' = @{ S = 'High'; T = 'Defender detected malware (Defender 1116)'
        M = 'Microsoft Defender detected a threat in the last 7 days.'
        A = 'Open Windows Security > Protection history, apply the proposed actions and run a full scan.' }
    'Microsoft-Windows-Windows Defender|1117' = @{ S = 'Medium'; T = 'Defender took action against malware (Defender 1117)'
        M = 'Microsoft Defender removed or quarantined a threat. Check how it got onto the PC.'
        A = 'Review Protection history in Windows Security; change important passwords if the threat was a stealer/trojan.' }
}
$script:EventIgnore = @('Microsoft-Windows-DistributedCOM|10016')

# ----------------------------------------------------------------------------------------------
# 3. Preparation: operating system, internet, restore point
# ----------------------------------------------------------------------------------------------
function Initialize-Preflight {
    $os = Get-CimInstance Win32_OperatingSystem -ErrorAction SilentlyContinue
    $cv = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -ErrorAction SilentlyContinue
    $build = [int]$os.BuildNumber
    $script:Build = $build
    if ($build -ge 22000) {
        Write-Bad "Detected: $($os.Caption) (build $build). This script is intended exclusively for Windows 10 and will exit."
        if ($script:TranscriptOn) { try { Stop-Transcript | Out-Null } catch {} }
        Read-Host 'Press Enter to exit' | Out-Null
        exit 2
    }
    $disp = $cv.DisplayVersion
    if (-not $disp) { $disp = $cv.ReleaseId }
    $script:DisplayVersion = $disp
    $ubr = $cv.UBR
    Add-Fact 'Operating system' "$($os.Caption) $disp (build $build.$ubr)"
    Add-Fact 'Edition' $cv.EditionID
    Add-Fact 'Computer name' $env:COMPUTERNAME
    Add-Fact 'User' "$env:USERDOMAIN\$env:USERNAME"
    if ($os.InstallDate) { Add-Fact 'Windows installed on' ($os.InstallDate.ToString('yyyy-MM-dd')) }
    Write-Ok "Detected: $($os.Caption) $disp (build $build.$ubr)"

    if ($build -lt 19045) {
        Add-Finding -Id 'os-not-22h2' -Severity 'High' -Category 'Windows Update' `
            -Title "Windows 10 is not up to date (version $disp instead of 22H2)" `
            -Meaning 'Windows 10 version 22H2 is the last Windows 10 version. Older versions no longer receive security updates. The update to 22H2 stays Windows 10 - it is NOT Windows 11.' `
            -Evidence "Installed build: $build" `
            -Recommendation 'The script''s update module offers the feature update to Windows 10 22H2, provided Windows Update makes it available.'
    }

    # Support status
    $esuEnd = Get-Date '2026-10-13'
    $today = Get-Date
    $daysEsu = [math]::Ceiling(($esuEnd.Date - $today.Date).TotalDays)
    if ($daysEsu -ge 0) {
        $txt = "Regular support for Windows 10 ended on 2025-10-14. Further security updates are only available through the 'Extended Security Updates' (ESU) program. Consumer ESU is documented to end on 2026-10-13 (in $daysEsu day(s)) - please check the current status with Microsoft."
    } else {
        $txt = 'Regular support for Windows 10 ended on 2025-10-14. The consumer ESU year (until 2026-10-13) has also expired. Without security updates the risk grows that newly discovered vulnerabilities are no longer fixed - please check the current status with Microsoft.'
    }
    Add-Finding -Id 'os-end-of-support' -Severity 'High' -Category 'Security' `
        -Title 'Windows 10 is (largely) out of support' `
        -Meaning $txt `
        -Evidence "Today's date: $($today.ToString('yyyy-MM-dd')). End of support for Windows 10: 2025-10-14." `
        -Recommendation 'Check security updates (see update section), use a current browser and antivirus, do not use the PC for risky activities, make backups. Long term: switch to a supported system (you explicitly excluded Windows 11 - an alternative is e.g. a Linux system) or secured operation with ESU.' `
        -Status 'Open'

    # Reboot pending?
    $pend = Test-PendingReboot
    if ($pend.Count -gt 0) {
        Add-Finding -Id 'reboot-pending' -Severity 'Medium' -Category 'System' `
            -Title 'A restart is pending' `
            -Meaning 'Windows has prepared changes (e.g. updates) that only take effect after a restart. While it is pending, updates and repairs can fail or remain incomplete.' `
            -Evidence ("Indications: " + ($pend -join ', ')) `
            -Recommendation 'Save your work, restart Windows and then run the script again.'
    }

    # Internet
    $script:Online = $false
    try {
        $r = Invoke-WebRequest -Uri 'http://www.msftconnecttest.com/connecttest.txt' -UseBasicParsing -TimeoutSec 10 -ErrorAction Stop
        if ($r.Content -match 'Microsoft Connect Test') { $script:Online = $true }
    } catch {}
    if ($script:Online) { Write-Ok 'Internet connection available.' } else { Write-Warn2 'No working internet connection detected - online modules will be skipped.' }
    Add-Fact 'Internet connection' $(if ($script:Online) { 'yes' } else { 'no' })
}

function Initialize-RestorePoint {
    if ($script:RestorePointDone -or $SkipRestorePoint) { return }
    $script:RestorePointDone = $true
    if ($script:DryRun) { Write-Info '[DryRun] would create a restore point.'; return }
    Write-Info 'Creating a restore point (so that changes can be undone) ...'

    $srKey = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\SystemRestore'
    $disableSr = (Get-ItemProperty 'HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\SystemRestore' -ErrorAction SilentlyContinue).DisableSR
    $srOff = ($disableSr -eq 1) -or ((Get-ItemProperty $srKey -ErrorAction SilentlyContinue).RPSessionInterval -eq 0)
    $enabledNow = $false
    if ($srOff) {
        if (Confirm-Step 'System Restore is turned off. Turn it on for the system drive now (recommended)?') {
            try { Enable-ComputerRestore -Drive "$env:SystemDrive\" -ErrorAction Stop; $enabledNow = $true } catch { Write-Warn2 $_.Exception.Message }
        }
    }

    # Windows skips a new restore point silently if one exists within the last 24 h -> lift that limit temporarily.
    $freqName = 'SystemRestorePointCreationFrequency'
    $oldFreq = (Get-ItemProperty $srKey -Name $freqName -ErrorAction SilentlyContinue).$freqName
    $before = @(Get-ComputerRestorePoint -ErrorAction SilentlyContinue).Count
    try {
        Set-ItemProperty -Path $srKey -Name $freqName -Value 0 -Type DWord -Force -ErrorAction SilentlyContinue
        Checkpoint-Computer -Description 'Windows10_SystemMaintenance (before changes)' -RestorePointType MODIFY_SETTINGS -WarningAction SilentlyContinue -ErrorAction Stop
        $after = @(Get-ComputerRestorePoint -ErrorAction SilentlyContinue).Count
        if ($after -gt $before) {
            Write-Ok 'Restore point created.'
            Add-Action 'Restore point' 'Success' 'A restore point was created before the changes.'
            if ($enabledNow) {
                Add-Finding -Id 'restore-off' -Severity 'Medium' -Category 'Security' -Title 'System Restore was turned off' `
                    -Meaning 'Without System Restore, faulty drivers or updates cannot be rolled back via a restore point.' `
                    -Recommendation 'The script turned on System Restore for the system drive.' -Status 'Fixed'
            }
        } else {
            Write-Warn2 'Windows reported no error, but no new restore point appeared.'
            Add-Action 'Restore point' 'Not verified' 'Checkpoint-Computer returned without error but no new restore point was found.'
        }
    } catch {
        Write-Warn2 "Restore point could not be created: $($_.Exception.Message)"
        Add-Action 'Restore point' 'Not possible' $_.Exception.Message
    } finally {
        if ($null -ne $oldFreq) { Set-ItemProperty -Path $srKey -Name $freqName -Value $oldFreq -Type DWord -Force -ErrorAction SilentlyContinue }
        else { Remove-ItemProperty -Path $srKey -Name $freqName -ErrorAction SilentlyContinue }
    }

    # Shadow storage: a tiny cap makes restore points useless.
    try {
        $vs = (Invoke-Native -File "$env:WINDIR\System32\vssadmin.exe" -Arguments @('List', 'ShadowStorage') -Quiet).Output
        if ($vs -match 'No items found|Keine Elemente') {
            Add-Finding -Id 'shadow-storage' -Severity 'Low' -Category 'Security' -Title 'No space is reserved for System Restore' `
                -Meaning 'Restore points need reserved disk space (shadow storage). Without it they cannot be kept.' `
                -Recommendation "PowerShell (admin): vssadmin Resize ShadowStorage /For=$env:SystemDrive /On=$env:SystemDrive /MaxSize=5%"
        }
    } catch {}
}

# ----------------------------------------------------------------------------------------------
# 4. Diagnostic modules
# ----------------------------------------------------------------------------------------------
function Invoke-SystemDiagnostics {
    $os = Get-CimInstance Win32_OperatingSystem
    $cs = Get-CimInstance Win32_ComputerSystem
    $cpu = Get-CimInstance Win32_Processor | Select-Object -First 1
    $bios = Get-CimInstance Win32_BIOS -ErrorAction SilentlyContinue
    Add-Fact 'Manufacturer / model' "$($cs.Manufacturer) $($cs.Model)"
    Add-Fact 'Processor' "$($cpu.Name.Trim()) ($($cpu.NumberOfCores) cores / $($cpu.NumberOfLogicalProcessors) threads)"
    $ramGB = [math]::Round($cs.TotalPhysicalMemory / 1GB, 1)
    $freeRam = [math]::Round($os.FreePhysicalMemory / 1MB, 1)
    $usedPct = [math]::Round(100 - ($os.FreePhysicalMemory * 1KB / $cs.TotalPhysicalMemory * 100), 0)
    Add-Fact 'Memory (RAM)' "$ramGB GB total, $freeRam GB free ($usedPct % used)"
    if ($bios) {
        $biosDate = $bios.ReleaseDate
        Add-Fact 'BIOS/UEFI' "$($bios.SMBIOSBIOSVersion)$(if ($biosDate) { ', ' + $biosDate.ToString('yyyy-MM-dd') })"
        if ($biosDate -and $biosDate -lt (Get-Date).AddYears(-5)) {
            Add-Finding -Id 'bios-old' -Severity 'Info' -Category 'Hardware' -Title 'BIOS/UEFI is older than 5 years' `
                -Meaning 'The BIOS/UEFI is the firmware of the mainboard. Manufacturers fix stability and security problems in it. An update is not without risk, though, and only makes sense for specific problems.' `
                -Evidence "BIOS date: $($biosDate.ToString('yyyy-MM-dd'))" `
                -Recommendation 'Look for a BIOS update on the support page of the PC/mainboard manufacturer and follow the instructions exactly (make sure the power supply is stable!). Only necessary if you have problems.' -Status 'Info'
        }
    }
    $up = (Get-Date) - $os.LastBootUpTime
    Add-Fact 'Uptime since last restart' ("{0} days {1} h" -f [int]$up.TotalDays, $up.Hours)
    Write-Info "Uptime since restart: $([int]$up.TotalDays) days"
    if ($up.TotalDays -gt 14) {
        Add-Finding -Id 'uptime-long' -Severity 'Low' -Category 'System' -Title "The PC has been running for $([int]$up.TotalDays) days without a restart" `
            -Meaning 'On Windows 10 with Fast Startup enabled, "Shut down" does not mean a real restart. Memory leaks, hung drivers and unfinished updates accumulate.' `
            -Recommendation "Choose 'Restart' (not 'Shut down') once. This is the simplest measure against many strange errors."
    }
    if ($usedPct -ge 90) {
        Add-Finding -Id 'ram-full' -Severity 'Medium' -Category 'Performance' -Title "Memory is $usedPct % used" `
            -Meaning 'When memory is almost full, Windows moves data to the (slower) disk and the PC becomes noticeably slow.' `
            -Evidence "$freeRam GB of $ramGB GB free." `
            -Recommendation 'Look for memory-hungry programs in Task Manager (Ctrl+Shift+Esc), trim the autostart items or install more RAM.'
    }
    if ($ramGB -lt 8) {
        Add-Finding -Id 'ram-low' -Severity 'Info' -Category 'Performance' -Title "Little memory installed ($ramGB GB)" `
            -Meaning 'With less than 8 GB of RAM, modern software (browsers with many tabs, Office, video conferences) quickly becomes sluggish.' `
            -Recommendation 'A RAM upgrade to 8-16 GB is often the most effective and cheapest speed-up, provided the device is expandable.' -Status 'Info'
    }

    # Graphics driver
    try {
        $gpus = Get-CimInstance Win32_VideoController | Where-Object { $_.Name -notmatch 'Basic|Basis|Remote|Virtual' }
        foreach ($g in $gpus) {
            Add-Fact "Graphics: $($g.Name)" "Driver $($g.DriverVersion), date $(if ($g.DriverDate) { $g.DriverDate.ToString('yyyy-MM-dd') })"
            if ($g.DriverDate -and $g.DriverDate -lt (Get-Date).AddYears(-2)) {
                Add-Finding -Id "gpu-driver-$($g.PNPDeviceID)" -Severity 'Info' -Category 'Drivers' -Title "Graphics driver is over 2 years old ($($g.Name))" `
                    -Meaning 'Current graphics drivers fix crashes, display glitches and security holes, and often bring performance in games. Windows Update usually only delivers older versions.' `
                    -Evidence "Driver date: $($g.DriverDate.ToString('yyyy-MM-dd'))" `
                    -Recommendation 'Get the current driver directly from the manufacturer (NVIDIA, AMD or Intel). For security reasons the script does not install drivers from third-party sites.' -Status 'Info'
            }
        }
    } catch {}

    # Battery
    try {
        $bat = Get-CimInstance Win32_Battery -ErrorAction SilentlyContinue
        if ($bat) {
            $full = Get-CimInstance -Namespace root\wmi -ClassName BatteryFullChargedCapacity -ErrorAction SilentlyContinue | Select-Object -First 1
            $stat = Get-CimInstance -Namespace root\wmi -ClassName BatteryStaticData -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($full -and $stat -and $stat.DesignedCapacity -gt 0) {
                $health = [math]::Round($full.FullChargedCapacity / $stat.DesignedCapacity * 100, 0)
                Add-Fact 'Battery condition' "$health % of the original capacity"
                if ($health -lt 60) {
                    Add-Finding -Id 'battery-weak' -Severity 'Low' -Category 'Hardware' -Title "Battery has only $health % of its original capacity" `
                        -Meaning 'Lithium batteries wear out. Below 60 % the device lasts much shorter and, in extreme cases, the battery can swell.' `
                        -Recommendation 'Have the battery replaced. If the case is bulging, disconnect the device from power immediately.'
                }
            }
        }
    } catch {}
    # CPU load, throttling and temperature
    try {
        $load = [int](Get-CimInstance Win32_Processor | Measure-Object -Property LoadPercentage -Average).Average
        Add-Fact 'CPU load (snapshot)' "$load %"
        if ($cpu.MaxClockSpeed -gt 0) {
            $pctClock = [math]::Round($cpu.CurrentClockSpeed / $cpu.MaxClockSpeed * 100, 0)
            Add-Fact 'CPU clock' "$($cpu.CurrentClockSpeed) MHz of $($cpu.MaxClockSpeed) MHz ($pctClock %)"
            if ($load -gt 60 -and $pctClock -lt 60) {
                Add-Finding -Id 'cpu-throttle' -Severity 'Medium' -Category 'Performance' -Title "CPU runs at only $pctClock % of its clock speed under load" `
                    -Meaning 'The processor is busy but not boosting. Typical causes: overheating, a weak power plan ("Power saver"), a failing fan or dust in the heat sink, or power limits set by the laptop.' `
                    -Evidence "Load $load %, clock $($cpu.CurrentClockSpeed)/$($cpu.MaxClockSpeed) MHz." `
                    -Recommendation 'Check the power plan, clean fans and vents, check temperatures (e.g. HWiNFO).'
            }
        }
    } catch {}
    try {
        $tz = @(Get-CimInstance -Namespace root\wmi -ClassName MSAcpi_ThermalZoneTemperature -ErrorAction Stop)
        $temps = @($tz | ForEach-Object { [math]::Round($_.CurrentTemperature / 10 - 273.15, 0) } | Where-Object { $_ -gt 0 -and $_ -lt 150 })
        if ($temps.Count -gt 0) {
            $maxT = ($temps | Measure-Object -Maximum).Maximum
            Add-Fact 'ACPI temperature (max)' "$maxT °C"
            if ($maxT -ge 90) {
                Add-Finding -Id 'temp-high' -Severity 'High' -Category 'Hardware' -Title "A thermal sensor reports $maxT °C" `
                    -Meaning 'Sustained temperatures this high cause throttling, crashes and shorten component life.' `
                    -Recommendation 'Clean dust from fans and vents, check the fans spin, replace dried thermal paste, use the PC on a hard surface.'
            }
        }
    } catch {}
    try {
        $top = Get-Process -ErrorAction SilentlyContinue | Sort-Object WorkingSet64 -Descending | Select-Object -First 8
        $script:Tables['Top memory consumers'] = @($top | ForEach-Object { [pscustomobject]@{ Process = $_.ProcessName; 'Memory' = (Format-Size $_.WorkingSet64); Id = $_.Id } })
    } catch {}

    # Memory modules: single channel / speed below rated
    try {
        $dimms = @(Get-CimInstance Win32_PhysicalMemory -ErrorAction Stop)
        if ($dimms.Count -gt 0) {
            Add-Fact 'RAM modules' (($dimms | ForEach-Object { "$(Format-Size $_.Capacity) @ $($_.ConfiguredClockSpeed) MHz" }) -join '; ')
            if ($dimms.Count -eq 1 -and $cs.PCSystemType -ne 2) {
                Add-Finding -Id 'ram-single-channel' -Severity 'Info' -Category 'Performance' -Title 'Only one RAM module installed (single channel)' `
                    -Meaning 'Two identical modules run in dual-channel mode, which roughly doubles memory bandwidth. Integrated graphics and games benefit the most.' `
                    -Recommendation 'If the board has a free slot, add a second identical module.' -Status 'Info'
            }
            $slow = @($dimms | Where-Object { $_.Speed -and $_.ConfiguredClockSpeed -and $_.ConfiguredClockSpeed -lt ($_.Speed * 0.85) })
            if ($slow.Count -gt 0) {
                Add-Finding -Id 'ram-slow' -Severity 'Info' -Category 'Performance' -Title 'RAM runs slower than its rated speed' `
                    -Meaning 'The modules are rated for a higher speed than they currently run at. Often XMP/DOCP is simply not enabled in the BIOS.' `
                    -Evidence (($slow | ForEach-Object { "rated $($_.Speed) MHz, running $($_.ConfiguredClockSpeed) MHz" }) -join '; ') `
                    -Recommendation 'Enable XMP/DOCP in the BIOS/UEFI (stability test afterwards).' -Status 'Info'
            }
        }
    } catch {}

    # Activation
    try {
        $lic = Get-CimInstance SoftwareLicensingProduct -Filter "PartialProductKey IS NOT NULL AND Name LIKE 'Windows%'" -ErrorAction Stop | Select-Object -First 1
        if ($lic) {
            $ls = @{ 0 = 'Unlicensed'; 1 = 'Licensed'; 2 = 'Out-of-box grace'; 3 = 'Out-of-tolerance grace'; 4 = 'Non-genuine grace'; 5 = 'Notification'; 6 = 'Extended grace' }[[int]$lic.LicenseStatus]
            Add-Fact 'Windows activation' $ls
            if ($lic.LicenseStatus -ne 1) {
                Add-Finding -Id 'not-activated' -Severity 'Low' -Category 'System' -Title "Windows is not activated ($ls)" `
                    -Meaning 'Unactivated Windows shows a watermark and blocks personalization; some updates and features can be limited.' `
                    -Recommendation 'Settings > Update & Security > Activation. Use a genuine license key or digital license.'
            }
        }
    } catch {}

    # Battery cycle count
    try {
        $cyc = Get-CimInstance -Namespace root\wmi -ClassName BatteryCycleCount -ErrorAction Stop | Select-Object -First 1
        if ($cyc -and $cyc.CycleCount -gt 0) { Add-Fact 'Battery charge cycles' $cyc.CycleCount }
    } catch {}

    # Temporary profile
    if ($env:USERPROFILE -match '\\TEMP(\.|$)') {
        Add-Finding -Id 'temp-profile' -Severity 'High' -Category 'System' -Title 'You are signed in with a temporary profile' `
            -Meaning 'Windows could not load your real profile. Everything saved in this session is lost at sign-out.' `
            -Recommendation 'Restart. If it recurs, repair the profile registry key (ProfileList) or create a new user account and copy your data.'
    }
    Add-Action 'System diagnostics' 'Completed' "RAM usage $usedPct %, uptime $([int]$up.TotalDays) days."
}

function Invoke-DiskDiagnostics {
    $rows = @()
    try {
        $pds = Get-PhysicalDisk -ErrorAction Stop
        foreach ($pd in $pds) {
            $rel = $null
            try { $rel = $pd | Get-StorageReliabilityCounter -ErrorAction Stop } catch {}
            $temp = if ($rel -and $rel.Temperature) { "$($rel.Temperature) °C" } else { '-' }
            $wear = if ($rel -and $null -ne $rel.Wear) { "$($rel.Wear) %" } else { '-' }
            $hours = if ($rel -and $rel.PowerOnHours) { "$($rel.PowerOnHours) h" } else { '-' }
            $rows += [pscustomobject]@{
                Drive = $pd.FriendlyName; Type = "$($pd.MediaType) / $($pd.BusType)"; Size = (Format-Size $pd.Size)
                Health = "$($pd.HealthStatus)"; Status = "$($pd.OperationalStatus)"; Temperature = $temp; Wear = $wear; PowerOnHours = $hours
            }
            Write-Info ("{0}: {1}, {2}" -f $pd.FriendlyName, $pd.HealthStatus, $pd.MediaType)
            if ("$($pd.HealthStatus)" -ne 'Healthy') {
                Add-Finding -Id "disk-health-$($pd.DeviceId)" -Severity 'Critical' -Category 'Disks' -Title "Disk reports a health problem: $($pd.FriendlyName)" `
                    -Meaning 'Windows rates this disk as unhealthy (warning or error). The hard drive/SSD may fail soon; data may be lost.' `
                    -Evidence "Health: $($pd.HealthStatus), operational status: $($pd.OperationalStatus)" `
                    -Recommendation 'Make a complete backup IMMEDIATELY. Then run the manufacturer''s diagnostic tool and replace the drive if confirmed.'
            }
            if ($rel) {
                if ($null -ne $rel.Wear -and [int]$rel.Wear -ge 80) {
                    Add-Finding -Id "disk-wear-$($pd.DeviceId)" -Severity 'High' -Category 'Disks' -Title "SSD is heavily worn ($($rel.Wear) % wear): $($pd.FriendlyName)" `
                        -Meaning 'SSDs only tolerate a limited amount of write operations. With high wear the probability of failure increases.' `
                        -Recommendation 'Make a backup and plan a replacement.'
                }
                if ($rel.Temperature -and [int]$rel.Temperature -ge 70) {
                    Add-Finding -Id "disk-temp-$($pd.DeviceId)" -Severity 'Medium' -Category 'Disks' -Title "Disk is hot ($($rel.Temperature) °C): $($pd.FriendlyName)" `
                        -Meaning 'Permanently high temperatures shorten the lifespan and can lead to throttling.' `
                        -Recommendation 'Check case ventilation/dust, retrofit a heat sink for M.2 SSDs if necessary.'
                }
                if ($rel.WriteErrorsUncorrected -and [int]$rel.WriteErrorsUncorrected -gt 0) {
                    Add-Finding -Id "disk-writeerr-$($pd.DeviceId)" -Severity 'High' -Category 'Disks' -Title "Uncorrectable write errors: $($pd.FriendlyName)" `
                        -Meaning 'The disk could not write data without errors. The drive or its connection is failing.' `
                        -Evidence "Uncorrected write errors: $($rel.WriteErrorsUncorrected)" -Recommendation 'Make a backup immediately and replace the drive.'
                }
                if ($rel.TemperatureMax -and [int]$rel.TemperatureMax -ge 80) {
                    Add-Fact "Disk max temperature: $($pd.FriendlyName)" "$($rel.TemperatureMax) °C (lifetime maximum)"
                }
                if ($rel.ReadErrorsUncorrected -and [int]$rel.ReadErrorsUncorrected -gt 0) {
                    Add-Finding -Id "disk-readerr-$($pd.DeviceId)" -Severity 'High' -Category 'Disks' -Title "Uncorrectable read errors: $($pd.FriendlyName)" `
                        -Meaning 'The disk could not read data without errors. This is an early warning sign of data loss.' `
                        -Evidence "Uncorrected read errors: $($rel.ReadErrorsUncorrected)" -Recommendation 'Make a backup, check the drive with the manufacturer''s tool.'
                }
            }
        }
    } catch { Write-Warn2 "Physical disks could not be queried: $($_.Exception.Message)" }
    $script:Tables['Physical disks'] = $rows

    try {
        $pf = Get-CimInstance -Namespace root\wmi -ClassName MSStorageDriver_FailurePredictStatus -ErrorAction Stop | Where-Object { $_.PredictFailure }
        if ($pf) {
            Add-Finding -Id 'smart-fail' -Severity 'Critical' -Category 'Disks' -Title 'SMART predicts an imminent failure of a drive' `
                -Meaning 'SMART is the self-monitoring of hard drives/SSDs. The warning means: the drive expects to fail soon.' `
                -Recommendation 'Make a backup immediately and replace the drive.'
        }
    } catch {}

    $vrows = @()
    try {
        $vols = Get-Volume | Where-Object { $_.DriveLetter -and $_.DriveType -eq 'Fixed' }
        foreach ($v in $vols) {
            $freePct = if ($v.Size -gt 0) { [math]::Round($v.SizeRemaining / $v.Size * 100, 0) } else { 0 }
            $vrows += [pscustomobject]@{ Drive = "$($v.DriveLetter):"; Name = $v.FileSystemLabel; FileSystem = $v.FileSystem; Size = (Format-Size $v.Size); Free = (Format-Size $v.SizeRemaining); 'Free %' = "$freePct %"; Condition = "$($v.HealthStatus)" }
            Write-Info ("{0}: {1} free of {2} ({3} %)" -f $v.DriveLetter, (Format-Size $v.SizeRemaining), (Format-Size $v.Size), $freePct)
            $isSys = ("$($v.DriveLetter):" -eq $env:SystemDrive)
            $freeGB = $v.SizeRemaining / 1GB
            if ($isSys -and $freeGB -lt 10) {
                Add-Finding -Id "space-$($v.DriveLetter)" -Severity 'High' -Category 'Disks' -Title "System drive almost full: only $(Format-Size $v.SizeRemaining) free" `
                    -Meaning 'Windows needs free space for updates, the page file and temporary files. With less than about 10 GB, updates fail and the PC becomes slow.' `
                    -Evidence "$freePct % free." -Recommendation 'Check large files/programs (Settings > System > Storage), clean up downloads, move data to another drive if necessary.'
            } elseif ($isSys -and $freePct -lt 15) {
                Add-Finding -Id "space-$($v.DriveLetter)" -Severity 'Medium' -Category 'Disks' -Title "System drive is getting tight: $(Format-Size $v.SizeRemaining) free ($freePct %)" `
                    -Meaning 'With less than 15 % free space an SSD in particular slows down, and large updates can fail.' `
                    -Recommendation 'Clean up storage (Settings > System > Storage), uninstall programs you do not need.'
            } elseif (-not $isSys -and $freePct -lt 5) {
                Add-Finding -Id "space-$($v.DriveLetter)" -Severity 'Low' -Category 'Disks' -Title "Drive $($v.DriveLetter): is almost full ($freePct % free)" `
                    -Meaning 'An almost full drive becomes slow and can cause write errors.' -Recommendation 'Move or delete files.'
            }
            if ($v.HealthStatus -and "$($v.HealthStatus)" -ne 'Healthy') {
                Add-Finding -Id "vol-health-$($v.DriveLetter)" -Severity 'High' -Category 'Disks' -Title "File system of $($v.DriveLetter): reports problems" `
                    -Meaning 'The file system is marked as unhealthy (errors or check pending).' -Evidence "Condition: $($v.HealthStatus)" `
                    -Recommendation "Run the 'Integrity and repair' module (file system check) or in Explorer: drive > Properties > Tools > Check."
            }
        }
    } catch { Write-Warn2 "Volumes could not be queried: $($_.Exception.Message)" }
    $script:Tables['Drives (partitions)'] = $vrows

    # Dirty bit
    try {
        $dirty = (Invoke-Native -File "$env:WINDIR\System32\fsutil.exe" -Arguments @('dirty', 'query', $env:SystemDrive) -Quiet).Output
        if ($dirty -match 'is Dirty|ist ein Dirty|is dirty') {
            Add-Finding -Id 'dirty-bit' -Severity 'High' -Category 'Disks' -Title "The system drive is flagged 'dirty'" `
                -Meaning 'Windows marked the file system as possibly inconsistent (after a crash/power loss). A disk check will run at the next restart.' `
                -Evidence $dirty -Recommendation 'Restart and let the check finish; run the Integrity module afterwards.'
        }
    } catch {}

    # Hibernation file
    try {
        $hib = Get-Item -LiteralPath "$env:SystemDrive\hiberfil.sys" -Force -ErrorAction Stop
        Add-Fact 'Hibernation file (hiberfil.sys)' (Format-Size $hib.Length)
        $sysVol = $vrows | Where-Object { $_.Drive -eq $env:SystemDrive }
        if ($hib.Length -gt 8GB -and $sysVol -and ([double](($sysVol.'Free %' -replace '[^\d]', '')) -lt 25)) {
            Add-Finding -Id 'hiberfil-big' -Severity 'Info' -Category 'Storage' -Title "hiberfil.sys occupies $(Format-Size $hib.Length)" `
                -Meaning 'The hibernation file stores memory content for hibernate and Fast Startup. On a tight system drive it is a quick way to win space.' `
                -Recommendation "Admin command prompt: 'powercfg /h /type reduced' (keeps Fast Startup, smaller file) or 'powercfg /h off' (no hibernate, no Fast Startup)." -Status 'Info'
        }
    } catch {}

    # Where did the space go? (only when the system drive is getting full)
    try {
        $sv = $vrows | Where-Object { $_.Drive -eq $env:SystemDrive }
        if ($sv -and [double](($sv.'Free %' -replace '[^\d]', '')) -lt 20) {
            Write-Info 'System drive is getting full - measuring the biggest folders (may take a minute) ...'
            $cands = @("$env:USERPROFILE\Downloads", "$env:USERPROFILE\Documents", "$env:USERPROFILE\Desktop", "$env:USERPROFILE\Videos", "$env:USERPROFILE\Pictures",
                       "$env:USERPROFILE\AppData\Local", "$env:USERPROFILE\AppData\Roaming", "$env:ProgramData", "${env:ProgramFiles}", "${env:ProgramFiles(x86)}",
                       "$env:WINDIR\WinSxS", "$env:WINDIR\Installer", "$env:WINDIR\SoftwareDistribution", "$env:SystemDrive\Windows.old")
            $big = foreach ($c in $cands) { if ($c -and (Test-Path -LiteralPath $c)) { [pscustomobject]@{ Folder = $c; Bytes = (Get-FolderBytes $c) } } }
            $script:Tables['Biggest folders on the system drive'] = @($big | Sort-Object Bytes -Descending | Select-Object -First 10 | ForEach-Object { [pscustomobject]@{ Folder = $_.Folder; Size = (Format-Size $_.Bytes) } })
            $largeFiles = Get-ChildItem -LiteralPath $env:USERPROFILE -Recurse -File -Force -ErrorAction SilentlyContinue |
                Where-Object { $_.Length -gt 1GB } | Sort-Object Length -Descending | Select-Object -First 15
            if ($largeFiles) {
                $script:Tables['Largest files in your profile (over 1 GB)'] = @($largeFiles | ForEach-Object { [pscustomobject]@{ File = $_.FullName; Size = (Format-Size $_.Length); Modified = $_.LastWriteTime.ToString('yyyy-MM-dd') } })
            }
        }
    } catch {}
    Add-Action 'Disk diagnostics' 'Completed' "$($rows.Count) drive(s), $($vrows.Count) volume(s) checked."
}

function Get-RegValue($Path, $Name) {
    try { return (Get-ItemProperty -LiteralPath $Path -Name $Name -ErrorAction Stop).$Name } catch { return $null }
}

function Invoke-SecurityHardening {
    $thirdAV = $null
    try { $thirdAV = Get-CimInstance -Namespace root\SecurityCenter2 -ClassName AntiVirusProduct -ErrorAction Stop | Where-Object { $_.displayName -notmatch 'Windows Defender|Microsoft Defender' } } catch {}

    # --- Defender configuration (only meaningful when Defender is the active product) ---
    if (-not $thirdAV) {
        try {
            $pref = Get-MpPreference -ErrorAction Stop
            $mp = Get-MpComputerStatus -ErrorAction Stop
            $ex = @()
            # Without admin rights Defender returns "N/A: Must be an administrator..." placeholders
            foreach ($p in @($pref.ExclusionPath)) { if ($p -and $p -notmatch '^N/A') { $ex += "Path: $p" } }
            foreach ($p in @($pref.ExclusionExtension)) { if ($p -and $p -notmatch '^N/A') { $ex += "Extension: $p" } }
            foreach ($p in @($pref.ExclusionProcess)) { if ($p -and $p -notmatch '^N/A') { $ex += "Process: $p" } }
            if ($ex.Count -gt 0) {
                $risky = @($ex | Where-Object { $_ -match '(?i)\\Users\\|\\Temp\\|\\AppData\\|Extension:|C:\\\*?$|\\Windows\\' })
                Add-Finding -Id 'defender-exclusions' -Severity $(if ($risky.Count -gt 0) { 'Medium' } else { 'Info' }) -Category 'Security' `
                    -Title "Defender has $($ex.Count) exclusion(s)" `
                    -Meaning 'Files and folders on the exclusion list are never scanned. Malware often adds itself there; legitimate software (games, developer tools) sometimes does too.' `
                    -Evidence (($ex | Select-Object -First 15) -join "`n") `
                    -Recommendation 'Windows Security > Virus & threat protection > Manage settings > Exclusions: remove everything you do not recognise.' `
                    -Status $(if ($risky.Count -gt 0) { 'Open' } else { 'Info' })
            }
            if ($mp.PSObject.Properties.Name -contains 'IsTamperProtected' -and -not $mp.IsTamperProtected) {
                Add-Finding -Id 'defender-tamper' -Severity 'Low' -Category 'Security' -Title 'Defender Tamper Protection is off' `
                    -Meaning 'Tamper Protection stops malware (and scripts) from switching Defender off.' `
                    -Recommendation 'Windows Security > Virus & threat protection > Manage settings > Tamper Protection: On.'
            }
            if ($pref.MAPSReporting -eq 0) {
                Add-Finding -Id 'defender-cloud' -Severity 'Low' -Category 'Security' -Title 'Defender cloud-delivered protection is off' `
                    -Meaning 'Cloud protection lets Defender recognise brand-new malware within minutes instead of waiting for the next signature update.' `
                    -Recommendation 'Windows Security > Virus & threat protection > Manage settings > Cloud-delivered protection: On.'
            }
            if ($pref.PUAProtection -eq 0) {
                Add-Finding -Id 'defender-pua' -Severity 'Info' -Category 'Security' -Title 'Protection against potentially unwanted apps is off' `
                    -Meaning 'This blocks adware and bundled "optimizer" junk.' `
                    -Recommendation 'Windows Security > App & browser control > Reputation-based protection > Potentially unwanted app blocking.' -Status 'Info'
            }
            Add-Fact 'Defender extras' ("Tamper protection: $($mp.IsTamperProtected); cloud: $(if ($pref.MAPSReporting -eq 0) { 'off' } else { 'on' }); PUA: $($pref.PUAProtection); Controlled folder access: $($pref.EnableControlledFolderAccess); Network protection: $($pref.EnableNetworkProtection)")
        } catch {}
    }

    # --- Encryption / TPM ---
    try {
        $bl = @(Get-BitLockerVolume -ErrorAction Stop | Where-Object { $_.VolumeType -eq 'OperatingSystem' })
        foreach ($v in $bl) {
            Add-Fact "BitLocker $($v.MountPoint)" "$($v.ProtectionStatus), $($v.VolumeStatus)"
            if ("$($v.ProtectionStatus)" -ne 'On') {
                Add-Finding -Id 'bitlocker-off' -Severity 'Info' -Category 'Security' -Title "The system drive is not encrypted (BitLocker off on $($v.MountPoint))" `
                    -Meaning 'If a laptop is lost or stolen, an unencrypted drive can be read by anyone, even without your password.' `
                    -Recommendation 'Windows 10 Pro: Control Panel > BitLocker Drive Encryption. SAVE the recovery key outside the PC. Home: "Device encryption" in Settings > Update & Security if available.' -Status 'Info'
            }
        }
    } catch {}
    try {
        $tpm = Get-Tpm -ErrorAction Stop
        Add-Fact 'TPM' "present: $($tpm.TpmPresent), ready: $($tpm.TpmReady)"
    } catch {}

    # --- Legacy protocols / optional features ---
    try {
        $f = Get-WindowsOptionalFeature -Online -FeatureName SMB1Protocol -ErrorAction Stop
        if ("$($f.State)" -eq 'Enabled') {
            Add-Finding -Id 'smb1-feature' -Severity 'Medium' -Category 'Security' -Title 'The SMB1 Windows feature is installed' `
                -Meaning 'Even if the SMB1 server is off, the installed feature keeps the outdated and exploitable SMB1 client/server components on the PC.' `
                -Recommendation "Disable-WindowsOptionalFeature -Online -FeatureName SMB1Protocol (restart required). Old NAS devices may stop working."
            if (Confirm-Step 'Remove the SMB1 Windows feature now? (Very old NAS/printers may stop working.)' -Risky) {
                try { Disable-WindowsOptionalFeature -Online -FeatureName SMB1Protocol -NoRestart -ErrorAction Stop | Out-Null; Set-FindingFixed -Id 'smb1-feature' -WhatWasDone 'The SMB1 feature was removed (effective after a restart). Undo: Enable-WindowsOptionalFeature -Online -FeatureName SMB1Protocol'; Request-Reboot 'SMB1 feature removal'; Add-Action 'SMB1 feature' 'Fixed' 'Removed.' } catch { Write-Warn2 $_.Exception.Message }
            }
        }
    } catch {}
    try {
        $f = Get-WindowsOptionalFeature -Online -FeatureName MicrosoftWindowsPowerShellV2Root -ErrorAction Stop
        if ("$($f.State)" -eq 'Enabled') {
            Add-Finding -Id 'psv2' -Severity 'Low' -Category 'Security' -Title 'Windows PowerShell 2.0 is installed' `
                -Meaning 'PowerShell 2.0 has no modern logging or AMSI protection; attackers use it to bypass defences ("downgrade attack").' `
                -Recommendation 'Disable-WindowsOptionalFeature -Online -FeatureName MicrosoftWindowsPowerShellV2Root (restart not needed for most systems).'
            if (Confirm-Step 'Remove PowerShell 2.0 now (recommended, nothing modern needs it)?' -Risky) {
                try { Disable-WindowsOptionalFeature -Online -FeatureName MicrosoftWindowsPowerShellV2Root -NoRestart -ErrorAction Stop | Out-Null; Set-FindingFixed -Id 'psv2' -WhatWasDone 'PowerShell 2.0 was removed.'; Add-Action 'PowerShell 2.0' 'Fixed' 'Removed.' } catch { Write-Warn2 $_.Exception.Message }
            }
        }
    } catch {}
    foreach ($tn in 'TelnetClient', 'TFTP') {
        try {
            $f = Get-WindowsOptionalFeature -Online -FeatureName $tn -ErrorAction Stop
            if ("$($f.State)" -eq 'Enabled') {
                Add-Finding -Id "feature-$tn" -Severity 'Low' -Category 'Security' -Title "Legacy feature '$tn' is installed" `
                    -Meaning 'Telnet and TFTP send everything unencrypted and are rarely needed.' -Recommendation "Disable-WindowsOptionalFeature -Online -FeatureName $tn"
            }
        } catch {}
    }

    # --- Registry-based hardening checks ---
    $lsa = 'HKLM:\SYSTEM\CurrentControlSet\Control\Lsa'
    $lm = Get-RegValue $lsa 'LmCompatibilityLevel'
    if ($null -ne $lm -and [int]$lm -lt 3) {
        Add-Finding -Id 'ntlmv1' -Severity 'Medium' -Category 'Security' -Title "Outdated NTLM authentication allowed (LmCompatibilityLevel $lm)" `
            -Meaning 'Values below 3 let this PC send weak LM/NTLMv1 hashes, which can be cracked in minutes.' `
            -Recommendation 'Set LmCompatibilityLevel to 5 (NTLMv2 only) in the registry or via Local Security Policy, unless a very old device needs it.'
    }
    if ((Get-RegValue 'HKLM:\SYSTEM\CurrentControlSet\Control\SecurityProviders\WDigest' 'UseLogonCredential') -eq 1) {
        Add-Finding -Id 'wdigest' -Severity 'High' -Category 'Security' -Title 'WDigest stores passwords in clear text in memory' `
            -Meaning 'With UseLogonCredential=1 any tool that can read memory (e.g. Mimikatz) can read your Windows password in plain text. It is a classic attacker setting.' `
            -Recommendation "Set HKLM\SYSTEM\CurrentControlSet\Control\SecurityProviders\WDigest\UseLogonCredential to 0 (or delete it) and check the PC for malware."
        if (Confirm-Step 'Set WDigest UseLogonCredential back to 0 now (safe)?') {
            if (-not (Test-DryRun 'set WDigest UseLogonCredential=0')) {
                try { Set-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\SecurityProviders\WDigest' -Name UseLogonCredential -Value 0 -Type DWord -ErrorAction Stop; Set-FindingFixed -Id 'wdigest' -WhatWasDone 'UseLogonCredential was set to 0.'; Add-Action 'WDigest' 'Fixed' 'UseLogonCredential=0' } catch { Write-Warn2 $_.Exception.Message }
            }
        }
    }
    if ((Get-RegValue $lsa 'RunAsPPL') -ne 1) {
        Add-Fact 'LSA protection (RunAsPPL)' 'off'
    }
    $wl = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon'
    if ((Get-RegValue $wl 'AutoAdminLogon') -eq '1') {
        $hasPw = $null -ne (Get-RegValue $wl 'DefaultPassword')
        Add-Finding -Id 'autologon' -Severity $(if ($hasPw) { 'High' } else { 'Low' }) -Category 'Security' -Title 'Automatic sign-in is configured' `
            -Meaning "Windows signs in without asking for a password. $(if ($hasPw) { 'The password is stored in clear text in the registry (DefaultPassword) and readable by every administrator/process with registry access.' })" `
            -Recommendation 'Run netplwiz and tick "Users must enter a user name and password", and delete the DefaultPassword value.'
    }
    $shell = Get-RegValue $wl 'Shell'
    if ($shell -and $shell.Trim() -ne 'explorer.exe') {
        Add-Finding -Id 'winlogon-shell' -Severity 'High' -Category 'Security' -Title 'The Windows shell value was changed' `
            -Meaning 'HKLM\...\Winlogon\Shell should be exactly "explorer.exe". Anything else is started at every sign-in and is a typical malware persistence trick.' `
            -Evidence "Shell = $shell" -Recommendation 'Reset the value to explorer.exe and run a full virus scan (offline scan recommended).'
    }
    $ui = Get-RegValue $wl 'Userinit'
    if ($ui -and $ui.Trim().TrimEnd(',') -notmatch '(?i)^c:\\windows\\system32\\userinit\.exe$') {
        Add-Finding -Id 'winlogon-userinit' -Severity 'High' -Category 'Security' -Title 'The Winlogon Userinit value was changed' `
            -Meaning 'Userinit should be exactly "C:\Windows\system32\userinit.exe,". Extra programs there start at every sign-in with your rights.' `
            -Evidence "Userinit = $ui" -Recommendation 'Reset the value and run a full virus scan.'
    }
    $aid = Get-RegValue 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Windows' 'AppInit_DLLs'
    if ($aid -and $aid.Trim() -ne '' -and (Get-RegValue 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Windows' 'LoadAppInit_DLLs') -eq 1) {
        Add-Finding -Id 'appinit' -Severity 'High' -Category 'Security' -Title 'AppInit_DLLs is active' `
            -Meaning 'Every program that uses a window loads these DLLs. This old mechanism is used by malware and badly behaved "overlay" tools.' `
            -Evidence "AppInit_DLLs = $aid" -Recommendation 'Remove the entry unless you know the software that needs it; run a full virus scan.'
    }
    $ifeo = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options'
    try {
        $hij = @()
        foreach ($k in (Get-ChildItem -LiteralPath $ifeo -ErrorAction Stop)) {
            $dbg = Get-RegValue $k.PSPath 'Debugger'
            if ($dbg -and $dbg -notmatch '(?i)vsjitdebugger|drwtsn32|windbg|ntsd|devenv') { $hij += "$($k.PSChildName) -> $dbg" }
        }
        if ($hij.Count -gt 0) {
            Add-Finding -Id 'ifeo' -Severity 'High' -Category 'Security' -Title 'Programs are hijacked through Image File Execution Options' `
                -Meaning 'A "Debugger" value makes Windows start a different program whenever the named program (e.g. sethc.exe, utilman.exe, taskmgr.exe, an antivirus) is launched. This is a standard malware trick.' `
                -Evidence ($hij -join "`n") -Recommendation 'Delete the Debugger value (or key) after checking what it points to, then run a full virus scan.'
        }
    } catch {}
    $smbSig = $null
    try { $smbSig = (Get-SmbServerConfiguration -ErrorAction Stop).RequireSecuritySignature } catch {}
    if ($smbSig -eq $false) { Add-Fact 'SMB signing required' 'no (default on workstations)' }
    if ((Get-RegValue 'HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\DNSClient' 'EnableMulticast') -ne 0) { Add-Fact 'LLMNR' 'enabled (default)' }

    # SmartScreen
    $ss = Get-RegValue 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\System' 'EnableSmartScreen'
    $ss2 = Get-RegValue 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer' 'SmartScreenEnabled'
    if ($ss -eq 0 -or "$ss2" -eq 'Off') {
        Add-Finding -Id 'smartscreen-off' -Severity 'Low' -Category 'Security' -Title 'Windows SmartScreen is turned off' `
            -Meaning 'SmartScreen warns before you run unknown downloaded programs.' `
            -Recommendation 'Windows Security > App & browser control > Reputation-based protection: turn it on.'
    }
    # AutoRun
    $nd = Get-RegValue 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Explorer' 'NoDriveTypeAutoRun'
    if ($nd -eq 0) {
        Add-Finding -Id 'autorun-on' -Severity 'Low' -Category 'Security' -Title 'AutoRun is enabled for all drive types' `
            -Meaning 'Plugging in an infected USB stick can start programs without asking.' `
            -Recommendation 'Set NoDriveTypeAutoRun to 255 (0xFF) or use Settings > Devices > AutoPlay.'
    }
}

function Invoke-SecurityAudit {
    $startAt = Get-Date

    # --- Local accounts ---
    try {
        $users = @(Get-LocalUser -ErrorAction Stop)
        $guest = $users | Where-Object { $_.SID.Value -match '-501$' -and $_.Enabled }
        if ($guest) {
            Add-Finding -Id 'guest-enabled' -Severity 'Medium' -Category 'Accounts' -Title 'The Guest account is enabled' `
                -Meaning 'The Guest account allows sign-in without a personal account and is rarely needed.' `
                -Recommendation "net user Guest /active:no (admin prompt)."
            if (Confirm-Step 'Disable the Guest account now?' -Risky) {
                if (-not (Test-DryRun 'disable Guest account')) { try { Disable-LocalUser -Name $guest.Name -ErrorAction Stop; Set-FindingFixed -Id 'guest-enabled' -WhatWasDone 'The Guest account was disabled.' } catch { Write-Warn2 $_.Exception.Message } }
            }
        }
        $builtIn = $users | Where-Object { $_.SID.Value -match '-500$' -and $_.Enabled }
        if ($builtIn) {
            Add-Finding -Id 'builtin-admin' -Severity 'Info' -Category 'Accounts' -Title "The built-in Administrator account ($($builtIn.Name)) is enabled" `
                -Meaning 'This well-known account name is the first target of password guessing and has no UAC prompt protection by default.' `
                -Recommendation 'Use a normal account that is a member of Administrators and disable the built-in one unless you need it.' -Status 'Info'
        }
        # Microsoft-account users report PasswordRequired=False although sign-in is protected -> only local accounts without a password ever set
        $nopw = @($users | Where-Object { $_.Enabled -and -not $_.PasswordRequired -and $_.SID.Value -notmatch '-50[13]$' -and "$($_.PrincipalSource)" -eq 'Local' -and -not $_.PasswordLastSet })
        if ($nopw.Count -gt 0) {
            Add-Finding -Id 'accounts-nopw' -Severity 'Medium' -Category 'Accounts' -Title "$($nopw.Count) account(s) do not require a password" `
                -Meaning 'Anyone with access to the PC (or the network, if file sharing/RDP is on) can sign in without a password.' `
                -Evidence (($nopw | ForEach-Object { $_.Name }) -join ', ') -Recommendation 'Set a password (or a PIN with Windows Hello) for these accounts.'
        }
        $admins = @(Get-LocalGroupMember -Group 'Administrators' -ErrorAction SilentlyContinue)
        if ($admins.Count -gt 0) { Add-Fact 'Local administrators' (($admins | ForEach-Object { $_.Name }) -join ', ') }
        if ($admins.Count -gt 3) {
            Add-Finding -Id 'many-admins' -Severity 'Low' -Category 'Accounts' -Title "$($admins.Count) accounts have administrator rights" `
                -Meaning 'The more administrator accounts, the bigger the attack surface.' -Evidence (($admins | ForEach-Object { $_.Name }) -join ', ') `
                -Recommendation 'Remove administrator rights from accounts that do not need them (Settings > Accounts > Family & other users).'
        }
    } catch {}

    # --- Listening ports ---
    try {
        $lis = @(Get-NetTCPConnection -State Listen -ErrorAction Stop | Where-Object { $_.LocalAddress -in '0.0.0.0', '::' })
        $procs = @{}; Get-Process -ErrorAction SilentlyContinue | ForEach-Object { $procs[$_.Id] = $_.ProcessName }
        $rows = @($lis | Sort-Object LocalPort -Unique | ForEach-Object { [pscustomobject]@{ Port = $_.LocalPort; Process = $procs[[int]$_.OwningProcess] } })
        $script:Tables['Ports open to the network (TCP listening on all interfaces)'] = $rows
        $risk = @{ 23 = 'Telnet'; 21 = 'FTP'; 5900 = 'VNC'; 5985 = 'WinRM (HTTP)'; 5986 = 'WinRM (HTTPS)'; 3389 = 'Remote Desktop'; 445 = 'SMB file sharing'; 139 = 'NetBIOS' }
        $hits = @($rows | Where-Object { $risk.ContainsKey([int]$_.Port) } | ForEach-Object { "$($_.Port) ($($risk[[int]$_.Port])) - $($_.Process)" })
        $serious = @($hits | Where-Object { $_ -match '^(23|21|5900) ' })
        if ($serious.Count -gt 0) {
            Add-Finding -Id 'ports-risky' -Severity 'High' -Category 'Network' -Title 'Unencrypted remote-access services are listening on the network' `
                -Meaning 'Telnet, FTP and VNC without tunnel send passwords in clear text and are frequently attacked.' `
                -Evidence ($serious -join "`n") -Recommendation 'Stop and disable the service, or block the port in Windows Firewall.'
        }
        $info = @($hits | Where-Object { $_ -notmatch '^(23|21|5900) ' })
        if ($info.Count -gt 0) {
            Add-Finding -Id 'ports-info' -Severity 'Info' -Category 'Network' -Title 'File sharing / remote management ports are open' `
                -Meaning 'These ports are normal for file sharing or remote administration but should never be reachable from the internet.' `
                -Evidence ($info -join "`n") -Recommendation 'On a home PC without sharing: turn off file sharing (Network and Sharing Center) and Remote Desktop.' -Status 'Info'
        }
    } catch {}
    foreach ($s in @(@{ N = 'RemoteRegistry'; T = 'Remote Registry'; Sev = 'Medium' }, @{ N = 'TlntSvr'; T = 'Telnet server'; Sev = 'High' }, @{ N = 'SSDPSRV'; T = 'SSDP/UPnP discovery'; Sev = 'Info' })) {
        $svc = Get-Service -Name $s.N -ErrorAction SilentlyContinue
        if ($svc -and $svc.Status -eq 'Running') {
            $st = if ($s.Sev -eq 'Info') { 'Info' } else { 'Open' }
            Add-Finding -Id "svc-running-$($s.N)" -Severity $s.Sev -Category 'Security' -Title "$($s.T) service is running" `
                -Meaning 'This service lets other computers query or reach this PC. Most home users never need it.' `
                -Recommendation "Stop-Service $($s.N); Set-Service $($s.N) -StartupType Disabled (only if nothing you use depends on it)." -Status $st
        }
    }

    # --- Persistence: scheduled tasks ---
    $susRx = '(?i)\\(AppData|Temp|Downloads|Users\\Public)\\|powershell.*(\s-e\s|-enc|-encodedcommand|-w\s+hidden|-windowstyle\s+hidden)|mshta|wscript|cscript.*\.(js|vbs|wsf)|regsvr32.*http|rundll32.*javascript|certutil.*urlcache|bitsadmin.*transfer|cmd.*/c.*https?://|frombase64string'
    $okRx = '(?i)\\Microsoft\\(OneDrive|Teams|Edge|EdgeUpdate)\\|\\Google\\|\\Mozilla|\\Zoom|\\Discord|\\Slack|\\Spotify|\\Programs\\Microsoft VS Code|\\Dropbox'
    try {
        $tasks = @(Get-ScheduledTask -ErrorAction Stop | Where-Object { $_.TaskPath -notlike '\Microsoft\*' -and $_.State -ne 'Disabled' })
        $trows = @(); $sus = @()
        foreach ($t in $tasks) {
            $cmd = (@($t.Actions | ForEach-Object { "$($_.Execute) $($_.Arguments)".Trim() }) -join ' ; ')
            $trows += [pscustomobject]@{ Task = "$($t.TaskPath)$($t.TaskName)"; Command = $(if ($cmd.Length -gt 90) { $cmd.Substring(0, 90) + '...' } else { $cmd }); RunAs = "$($t.Principal.UserId)" }
            if ($cmd -match $susRx -and $cmd -notmatch $okRx) { $sus += "$($t.TaskPath)$($t.TaskName): $cmd" }
        }
        $script:Tables['Third-party scheduled tasks'] = @($trows | Select-Object -First 60)
        Add-Fact 'Third-party scheduled tasks' "$($tasks.Count)"
        if ($sus.Count -gt 0) {
            Add-Finding -Id 'tasks-suspicious' -Severity 'Medium' -Category 'Persistence' -Title "$($sus.Count) scheduled task(s) look unusual" `
                -Meaning 'These tasks run from user-writable folders or use script/encoded-command tricks. Legitimate software does this sometimes, malware does it almost always.' `
                -Evidence (($sus | Select-Object -First 8) -join "`n") `
                -Recommendation 'Open Task Scheduler, check each task. If you do not recognise it, disable it, delete the file it starts and run a full virus scan.'
        }
    } catch {}

    # --- Persistence: Run keys (+ signature check) ---
    try {
        $runKeys = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run', 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce',
                   'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Run', 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run', 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce'
        $runRows = @(); $unsigned = @(); $susRun = @()
        foreach ($rk in $runKeys) {
            $item = Get-ItemProperty -LiteralPath $rk -ErrorAction SilentlyContinue
            if (-not $item) { continue }
            foreach ($p in $item.PSObject.Properties | Where-Object { $_.Name -notmatch '^PS' }) {
                $val = [string]$p.Value
                $runRows += [pscustomobject]@{ Name = $p.Name; Command = $(if ($val.Length -gt 90) { $val.Substring(0, 90) + '...' } else { $val }); Where = ($rk -replace 'HKLM:\\SOFTWARE\\|HKCU:\\SOFTWARE\\|Microsoft\\Windows\\CurrentVersion\\', '') }
                if ($val -match $susRx -and $val -notmatch $okRx) { $susRun += "$($p.Name): $val" }
                $exe = if ($val -match '^\s*"([^"]+)"') { $Matches[1] } elseif ($val -match '^\s*(\S+\.(exe|dll|bat|cmd|ps1|vbs|js))') { $Matches[1] } else { $null }
                if ($exe) {
                    $exe = [Environment]::ExpandEnvironmentVariables($exe)
                    if (Test-Path -LiteralPath $exe -PathType Leaf) {
                        $sig = Get-AuthenticodeSignature -LiteralPath $exe -ErrorAction SilentlyContinue
                        if ($sig -and "$($sig.Status)" -ne 'Valid') { $unsigned += "$($p.Name): $exe ($($sig.Status))" }
                    }
                }
            }
        }
        $script:Tables['Autostart entries (Run keys)'] = $runRows
        if ($susRun.Count -gt 0) {
            Add-Finding -Id 'run-suspicious' -Severity 'Medium' -Category 'Persistence' -Title "$($susRun.Count) autostart entr(ies) look unusual" `
                -Meaning 'Autostart entries that start scripts or run from Temp/AppData/Downloads are a common malware pattern.' `
                -Evidence (($susRun | Select-Object -First 8) -join "`n") -Recommendation 'Task Manager > Startup: disable what you do not recognise, then run a full scan.'
        }
        if ($unsigned.Count -gt 0) {
            Add-Finding -Id 'run-unsigned' -Severity 'Low' -Category 'Persistence' -Title "$($unsigned.Count) autostart program(s) have no valid digital signature" `
                -Meaning 'Unsigned does not mean malicious (many small tools are unsigned), but malware is almost never signed.' `
                -Evidence (($unsigned | Select-Object -First 8) -join "`n") -Recommendation 'Check that you know each program; search its file name online if unsure.'
        }
    } catch {}

    # --- Persistence: services ---
    try {
        $svcs = @(Get-CimInstance Win32_Service -ErrorAction Stop | Where-Object { $_.PathName })
        $unq = @($svcs | Where-Object { $_.PathName -notmatch '^\s*"' -and $_.PathName -match '^(.+?\.exe)' -and $Matches[1] -match '\s' -and $_.PathName -notmatch '(?i)^\s*(c:\\windows\\system32\\|c:\\windows\\syswow64\\)' })
        if ($unq.Count -gt 0) {
            Add-Finding -Id 'svc-unquoted' -Severity 'Medium' -Category 'Persistence' -Title "$($unq.Count) service(s) have an unquoted path with spaces" `
                -Meaning 'If the path to a service is not in quotes, a local attacker can place a program such as "C:\Program.exe" that will be run as SYSTEM (privilege escalation).' `
                -Evidence (($unq | Select-Object -First 8 | ForEach-Object { "$($_.Name): $($_.PathName)" }) -join "`n") `
                -Recommendation 'Reinstall/update the software; or put the full path to the service in quotes under HKLM\SYSTEM\CurrentControlSet\Services\<name>\ImagePath.'
        }
        $usr = @($svcs | Where-Object { $_.PathName -match '(?i)\\Users\\|\\Temp\\|\\AppData\\' })
        if ($usr.Count -gt 0) {
            Add-Finding -Id 'svc-userpath' -Severity 'Medium' -Category 'Persistence' -Title "$($usr.Count) service(s) run programs from user-writable folders" `
                -Meaning 'Services normally live in Program Files or Windows. A service started from a user profile or Temp folder is unusual and is a malware pattern.' `
                -Evidence (($usr | Select-Object -First 8 | ForEach-Object { "$($_.Name): $($_.PathName)" }) -join "`n") -Recommendation 'Check what these services are; remove them if unknown and run a full scan.'
        }
    } catch {}

    # --- Persistence: WMI event subscriptions ---
    try {
        $cons = @(Get-CimInstance -Namespace root\subscription -ClassName __EventConsumer -ErrorAction Stop | Where-Object { $_.Name -ne 'SCM Event Log Consumer' })
        if ($cons.Count -gt 0) {
            Add-Finding -Id 'wmi-persist' -Severity 'High' -Category 'Persistence' -Title "$($cons.Count) permanent WMI event subscription(s) found" `
                -Meaning 'WMI subscriptions can run programs invisibly at boot or on events. Almost no consumer software uses them, but fileless malware does.' `
                -Evidence (($cons | ForEach-Object { "$($_.CimClass.CimClassName): $($_.Name)" }) -join "`n") `
                -Recommendation 'Inspect with Get-CimInstance -Namespace root\subscription -ClassName __EventConsumer / __FilterToConsumerBinding, remove unknown ones and run a full offline scan.'
        }
    } catch {}

    # --- User proxy, DNS ---
    $inet = 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Internet Settings'
    $pxOn = Get-RegValue $inet 'ProxyEnable'; $pxSrv = Get-RegValue $inet 'ProxyServer'; $pac = Get-RegValue $inet 'AutoConfigURL'
    if (($pxOn -eq 1 -and $pxSrv) -or $pac) {
        Add-Finding -Id 'user-proxy' -Severity 'Medium' -Category 'Network' -Title 'A browser/system proxy is configured for your user' `
            -Meaning 'All web traffic of Chrome, Edge and many programs goes through this proxy. In companies this is normal; at home it is a typical result of adware or malware ("proxy hijack").' `
            -Evidence "ProxyServer: $pxSrv; AutoConfigURL: $pac" -Recommendation 'Settings > Network & Internet > Proxy: turn off "Use a proxy server" and "Use setup script" if you did not set them.'
    }

    # --- Installed software inventory + end-of-life detection ---
    try {
        $keys = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*', 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*', 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*'
        $apps = @(Get-ItemProperty -Path $keys -ErrorAction SilentlyContinue | Where-Object { $_.DisplayName -and -not $_.SystemComponent -and -not $_.ParentKeyName } |
            Sort-Object DisplayName -Unique | Select-Object DisplayName, DisplayVersion, Publisher, InstallDate)
        Add-Fact 'Installed programs' "$($apps.Count)"
        $script:Tables['Installed programs'] = @($apps | ForEach-Object { [pscustomobject]@{ Name = $_.DisplayName; Version = $_.DisplayVersion; Publisher = $_.Publisher; Installed = $_.InstallDate } })
        $eolRx = '(?i)Adobe Flash|Shockwave|Silverlight|QuickTime|^Python 2\.|Java\(TM\) (6|7) |Java (6|7) Update|\.NET Core.* (1|2|3)\.\d|\.NET (Runtime|SDK|Core).* (5|7)\.\d|Microsoft Office.*(2007|2010|2013)|Adobe (Reader|Acrobat).*(9|X|XI|10|11)\b|Internet Explorer 11 Update|Skype for Business 2015'
        $eol = @($apps | Where-Object { $_.DisplayName -match $eolRx })
        if ($eol.Count -gt 0) {
            Add-Finding -Id 'eol-software' -Severity 'Medium' -Category 'Software' -Title "$($eol.Count) installed program(s) are out of support" `
                -Meaning 'Software that no longer gets security fixes is a favourite entry point for attackers (browser plug-ins, Java, old Office/Acrobat).' `
                -Evidence (($eol | ForEach-Object { "$($_.DisplayName) $($_.DisplayVersion)" }) -join "`n") -Recommendation 'Uninstall them or replace them with a supported version.'
        }
    } catch {}

    Add-Action 'Security audit' 'Completed' ("Accounts, ports, persistence, services, proxy, software in {0:N0} s." -f ((Get-Date) - $startAt).TotalSeconds)
}

function Invoke-SecurityDiagnostics {
    # Antivirus
    $thirdAV = $null
    try {
        $thirdAV = Get-CimInstance -Namespace root\SecurityCenter2 -ClassName AntiVirusProduct -ErrorAction Stop | Where-Object { $_.displayName -notmatch 'Windows Defender|Microsoft Defender' }
    } catch {}
    if ($thirdAV) { Add-Fact 'Antivirus (third-party)' (($thirdAV | ForEach-Object { $_.displayName }) -join ', ') }
    try {
        $mp = Get-MpComputerStatus -ErrorAction Stop
        Add-Fact 'Microsoft Defender' "Real-time protection: $($mp.RealTimeProtectionEnabled), signatures: $($mp.AntivirusSignatureLastUpdated), quick scan $($mp.QuickScanAge) day(s) ago"
        Write-Info "Defender: real-time protection $($mp.RealTimeProtectionEnabled), signature age $($mp.AntivirusSignatureAge) day(s)"
        if (-not $mp.RealTimeProtectionEnabled -and -not $thirdAV) {
            Add-Finding -Id 'defender-off' -Severity 'High' -Category 'Security' -Title 'Real-time antivirus protection is turned off' `
                -Meaning 'Without real-time protection, malware is not detected when opened/downloaded, and no other antivirus is active.' `
                -Recommendation 'Windows Security > Virus & threat protection > turn on real-time protection.'
            if (-not (Test-DryRun 'turn Defender real-time protection on')) { try {
                Set-MpPreference -DisableRealtimeMonitoring $false -ErrorAction Stop
                Start-Sleep -Seconds 2
                if ((Get-MpComputerStatus).RealTimeProtectionEnabled) { Set-FindingFixed -Id 'defender-off' -WhatWasDone 'The script turned Microsoft Defender real-time protection back on.' }
            } catch {} }
        }
        if ($mp.AntivirusSignatureAge -gt 3 -and -not $thirdAV) {
            Add-Finding -Id 'defender-sig' -Severity 'Medium' -Category 'Security' -Title "Virus signatures are $($mp.AntivirusSignatureAge) days old" `
                -Meaning 'Antivirus scanners only detect known threats. Outdated signatures mean a protection gap against new malware.' `
                -Recommendation 'The script updates the signatures in the optimization module; alternatively Windows Security > Protection updates.'
        }
        if ($mp.QuickScanAge -gt 14 -and $mp.FullScanAge -gt 30 -and -not $thirdAV) {
            Add-Finding -Id 'defender-scan-old' -Severity 'Low' -Category 'Security' -Title 'No virus scan for over 2 weeks' `
                -Meaning 'Real-time protection detects a lot, but regular scans also find dormant threats.' `
                -Recommendation 'The optimization module offers a quick scan.'
        }
        try {
            $threats = Get-MpThreat -ErrorAction Stop | Where-Object { $_.IsActive }
            if ($threats) {
                Add-Finding -Id 'defender-threat' -Severity 'Critical' -Category 'Security' -Title 'Active threat(s) reported by Defender' `
                    -Meaning 'Defender detected malware that has not been completely removed yet.' `
                    -Evidence (($threats | ForEach-Object { "ThreatID $($_.ThreatID)" }) -join '; ') `
                    -Recommendation 'Open Windows Security > Virus & threat protection > Protection history, apply the actions, then run a full scan (or offline scan) and change the passwords of important accounts.'
            }
        } catch {}
    } catch {
        if ($thirdAV) { Write-Info "Third-party antivirus active: $(($thirdAV | ForEach-Object { $_.displayName }) -join ', ')" }
        else {
            Add-Finding -Id 'no-av' -Severity 'High' -Category 'Security' -Title 'No antivirus detected' `
                -Meaning 'Neither Microsoft Defender nor any other antivirus responds. The system is unprotected against malware.' `
                -Recommendation 'Open Windows Security and enable Defender (or install a reputable antivirus).'
        }
    }

    # Firewall
    try {
        $fw = Get-NetFirewallProfile -ErrorAction Stop
        foreach ($p in ($fw | Where-Object { -not $_.Enabled })) {
            $fid = "firewall-$($p.Name)"
            Add-Finding -Id $fid -Severity 'High' -Category 'Security' -Title "Windows Firewall is turned off in the '$($p.Name)' profile" `
                -Meaning 'The firewall blocks unwanted connections from outside. Without it, services on your PC are directly reachable on the network.' `
                -Recommendation 'Windows Security > Firewall & network protection > turn on the profile.'
            if (Confirm-Step "Turn firewall profile '$($p.Name)' back on now (recommended, unless another firewall is in use)?" -Risky) {
                try { Set-NetFirewallProfile -Name $p.Name -Enabled True -ErrorAction Stop; Set-FindingFixed -Id $fid -WhatWasDone "The script turned on Windows Firewall in the '$($p.Name)' profile."; Add-Action 'Firewall' 'Fixed' "Profile $($p.Name) turned on." } catch { Write-Warn2 $_.Exception.Message }
            }
        }
    } catch {}

    # UAC
    $lua = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System' -ErrorAction SilentlyContinue).EnableLUA
    if ($lua -eq 0) {
        Add-Finding -Id 'uac-off' -Severity 'High' -Category 'Security' -Title 'User Account Control (UAC) is turned off' `
            -Meaning 'UAC asks for confirmation before programs use administrator rights. When turned off, malware can dig deeper into the system unnoticed.' `
            -Recommendation "Control Panel > User Accounts > 'Change User Account Control settings' and enable it again (restart required). The script deliberately does not change this itself."
    }

    # SMB1
    try {
        $smb = Get-SmbServerConfiguration -ErrorAction Stop
        if ($smb.EnableSMB1Protocol) {
            Add-Finding -Id 'smb1' -Severity 'Medium' -Category 'Security' -Title 'Outdated network protocol SMB1 is active' `
                -Meaning 'SMB1 is a file-sharing protocol over 30 years old with serious security holes (the basis of WannaCry, among others). Only very old devices (old NAS, printers) still need it.' `
                -Recommendation "Turn it off unless an old device depends on it: PowerShell (admin) 'Set-SmbServerConfiguration -EnableSMB1Protocol `$false'."
            if (Confirm-Step 'Turn off SMB1 now? (Older network devices may no longer be reachable afterwards.)' -Default $true -Risky) {
                try { Set-SmbServerConfiguration -EnableSMB1Protocol $false -Force -ErrorAction Stop; Set-FindingFixed -Id 'smb1' -WhatWasDone 'SMB1 was turned off. To undo: Set-SmbServerConfiguration -EnableSMB1Protocol $true'; Add-Action 'SMB1' 'Fixed' 'SMB1 server disabled.' } catch { Write-Warn2 $_.Exception.Message }
            }
        }
    } catch {}

    # Secure Boot
    try {
        $sb = Confirm-SecureBootUEFI -ErrorAction Stop
        Add-Fact 'Secure Boot' $(if ($sb) { 'active' } else { 'inactive' })
        if (-not $sb) {
            Add-Finding -Id 'secureboot-off' -Severity 'Info' -Category 'Security' -Title 'Secure Boot is turned off' `
                -Meaning 'Secure Boot prevents tampered boot loaders (bootkits) from starting before Windows. When turned off, it is often intentional (dual boot) - but the security benefit is lost.' `
                -Recommendation 'Can be enabled in the UEFI/BIOS if the PC was installed in UEFI mode. Only change it if you know what you are doing.' -Status 'Info'
        }
    } catch { Add-Fact 'Secure Boot' 'not available (legacy BIOS) or not queryable' }

    # Remote Desktop
    $rdp = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server' -ErrorAction SilentlyContinue).fDenyTSConnections
    if ($rdp -eq 0) {
        Add-Finding -Id 'rdp-on' -Severity 'Medium' -Category 'Security' -Title 'Remote Desktop access is turned on' `
            -Meaning 'Remote Desktop lets someone on the network sign in to this PC. If the service is reachable from the internet, it is a main entry point for attacks.' `
            -Recommendation 'If you do not need it: turn it off under Settings > System > Remote Desktop.'
    }

    # hosts file
    try {
        $hosts = Get-Content "$env:WINDIR\System32\drivers\etc\hosts" -ErrorAction Stop | Where-Object { $_ -match '^\s*[0-9a-fA-F:.]+\s+\S+' -and $_ -notmatch '^\s*#' }
        $entries = @($hosts | Where-Object { $_ -notmatch '^\s*(127\.0\.0\.1|::1)\s+localhost\s*$' })
        $susp = @($entries | Where-Object { $_ -match 'microsoft|windowsupdate|defender|kaspersky|avast|norton|eset|bitdefender|malwarebytes|mcafee' })
        if ($susp.Count -gt 0) {
            Add-Finding -Id 'hosts-suspicious' -Severity 'High' -Category 'Security' -Title 'The hosts file blocks/redirects addresses of Microsoft or security vendors' `
                -Meaning 'The hosts file overrides DNS resolution. Entries for update or antivirus servers are a typical sign of malware (or of manual "telemetry blockers" - but then they also block updates).' `
                -Evidence (($susp | Select-Object -First 8) -join "`n") `
                -Recommendation "Open the file C:\Windows\System32\drivers\etc\hosts as admin in an editor and remove unknown entries, then run a full virus scan."
        } elseif ($entries.Count -gt 20) {
            Add-Finding -Id 'hosts-large' -Severity 'Info' -Category 'Security' -Title "The hosts file contains $($entries.Count) entries" `
                -Meaning 'Large hosts files usually come from ad/tracker blockers. They are harmless but can block legitimate sites.' -Status 'Info'
        }
    } catch {}

    # Proxy
    try {
        $px = (Invoke-Native -File "$env:WINDIR\System32\netsh.exe" -Arguments @('winhttp', 'show', 'proxy') -Quiet).Output
        if ($px -notmatch 'Direct access|Direkter Zugriff') {
            Add-Finding -Id 'winhttp-proxy' -Severity 'Info' -Category 'Network' -Title 'A system-wide WinHTTP proxy is set' `
                -Meaning 'Windows Update and the Store use this proxy. In company networks this is normal; on a home network a forgotten proxy often prevents updates (error 0x8024402C).' `
                -Evidence $px -Recommendation "If no proxy is wanted: PowerShell (admin) 'netsh winhttp reset proxy'." -Status 'Info'
        }
    } catch {}
    Invoke-SecurityHardening
    Add-Action 'Security check' 'Completed' 'Checked antivirus, firewall, UAC, SMB1, Secure Boot, Remote Desktop, hosts, proxy, Defender settings, encryption, legacy protocols.'
}

function Test-MeteredConnection {
    try {
        $null = [Windows.Networking.Connectivity.NetworkInformation, Windows.Networking.Connectivity, ContentType = WindowsRuntime]
        $prof = [Windows.Networking.Connectivity.NetworkInformation]::GetInternetConnectionProfile()
        if ($prof) { return ($prof.GetConnectionCost().NetworkCostType -ne 'Unrestricted') }
    } catch {}
    return $false
}

function Invoke-NetworkDetails {
    # Metered connection: Windows Update will not download everything.
    if (Test-MeteredConnection) {
        Add-Finding -Id 'metered' -Severity 'Low' -Category 'Network' -Title 'The active connection is set to "metered"' `
            -Meaning 'On a metered connection Windows postpones most update downloads. Updates can look "stuck" even though nothing is wrong.' `
            -Recommendation 'Settings > Network & Internet > (your connection) > Properties > "Set as metered connection": Off (unless you really have a data cap).'
    }

    # Link speed / errors
    try {
        foreach ($a in (Get-NetAdapter -Physical -ErrorAction Stop | Where-Object { $_.Status -eq 'Up' })) {
            $st = Get-NetAdapterStatistics -Name $a.Name -ErrorAction SilentlyContinue
            if ($a.LinkSpeed -match '^100 Mbps$' -and $a.PhysicalMediaType -match '802\.3|Ethernet') {
                Add-Finding -Id "link100-$($a.Name)" -Severity 'Low' -Category 'Network' -Title "Ethernet adapter '$($a.Name)' links at only 100 Mbps" `
                    -Meaning 'Modern gigabit hardware falling back to 100 Mbps usually means a damaged cable, a bad port or a very old switch.' `
                    -Recommendation 'Try another cable (Cat5e or better) and another switch/router port.'
            }
            if ($st -and ($st.ReceivedDiscardedPackets + $st.ReceivedPacketErrors + $st.OutboundPacketErrors) -gt 1000) {
                Add-Finding -Id "neterr-$($a.Name)" -Severity 'Low' -Category 'Network' -Title "Adapter '$($a.Name)' shows many packet errors/discards" `
                    -Meaning 'Frequent packet errors point to a bad cable, interference or a driver problem.' `
                    -Evidence "Discarded $($st.ReceivedDiscardedPackets), receive errors $($st.ReceivedPacketErrors), send errors $($st.OutboundPacketErrors)" `
                    -Recommendation 'Replace the cable, update the network driver, check for Wi-Fi interference.'
            }
        }
    } catch {}

    # Wi-Fi signal
    try {
        $w = (Invoke-Native -File "$env:WINDIR\System32\netsh.exe" -Arguments @('wlan', 'show', 'interfaces') -Quiet).Output
        if ($w -match '(?m)Signal\s*:\s*(\d+)%') {
            $sig = [int]$Matches[1]
            Add-Fact 'Wi-Fi signal' "$sig %"
            if ($sig -lt 40) {
                Add-Finding -Id 'wifi-weak' -Severity 'Low' -Category 'Network' -Title "Weak Wi-Fi signal ($sig %)" `
                    -Meaning 'A weak signal causes slow speeds, drops and failed downloads (including updates).' `
                    -Recommendation 'Move closer to the router, use the 5 GHz band, or add a mesh/access point.'
            }
        }
    } catch {}

    # DNS servers + gateway latency
    try {
        $dns = @(Get-DnsClientServerAddress -AddressFamily IPv4 -ErrorAction Stop | Where-Object { $_.ServerAddresses } | ForEach-Object { $_.ServerAddresses } | Select-Object -Unique)
        if ($dns.Count -gt 0) { Add-Fact 'DNS servers' ($dns -join ', ') }
        $gw = (Get-NetRoute -DestinationPrefix '0.0.0.0/0' -ErrorAction Stop | Sort-Object RouteMetric | Select-Object -First 1).NextHop
        if ($gw -and $gw -ne '0.0.0.0') {
            $pings = @(Test-Connection -ComputerName $gw -Count 4 -ErrorAction SilentlyContinue)
            $loss = 4 - $pings.Count
            if ($pings.Count -gt 0) {
                $avg = [math]::Round(($pings | Measure-Object -Property ResponseTime -Average).Average, 0)
                Add-Fact 'Router latency' "$avg ms, packet loss $([int]($loss / 4 * 100)) %"
                if ($loss -ge 2 -or $avg -gt 100) {
                    Add-Finding -Id 'gateway-bad' -Severity 'Medium' -Category 'Network' -Title 'Connection to the router is unstable' `
                        -Meaning 'Packet loss or high latency to the router itself (not the internet) points to Wi-Fi/cable problems in your local network.' `
                        -Evidence "Average $avg ms, $loss of 4 pings lost." -Recommendation 'Check cable/Wi-Fi, restart the router, update the network driver.'
                }
            }
        }
    } catch {}

    # Network category: Public vs Private
    try {
        $pub = @(Get-NetConnectionProfile -ErrorAction Stop | Where-Object { $_.NetworkCategory -eq 'Public' -and $_.IPv4Connectivity -ne 'Disconnected' })
        if ($pub.Count -gt 0) { Add-Fact 'Network profile' "Public ($(($pub | ForEach-Object { $_.Name }) -join ', ')) - stricter firewall rules" }
    } catch {}

    # Time source
    try {
        $t = (Invoke-Native -File "$env:WINDIR\System32\w32tm.exe" -Arguments @('/query', '/status') -Quiet).Output
        if ($t -match '(?m)Source:\s*(.+)$') { Add-Fact 'Time source' $Matches[1].Trim() }
    } catch {}
}

function Invoke-NetworkDiagnostics {
    try {
        $up = Get-NetAdapter -Physical -ErrorAction Stop | Where-Object { $_.Status -eq 'Up' }
        Add-Fact 'Active network adapters' (($up | ForEach-Object { "$($_.Name) ($($_.LinkSpeed))" }) -join ', ')
        Write-Info "Active adapters: $(($up | ForEach-Object { $_.Name }) -join ', ')"
    } catch {}
    Invoke-NetworkDetails
    $dnsOk = $false
    try { $null = [Net.Dns]::GetHostAddresses('www.microsoft.com'); $dnsOk = $true } catch {}
    if ($script:Online) { Write-Ok 'Internet reachable, DNS works.'; return }
    $pingOk = $false
    $pingTarget = '1.1.1.1'   # public resolver, used only to tell "no internet" from "no DNS"
    try { $pingOk = Test-Connection -ComputerName $pingTarget -Count 1 -Quiet -ErrorAction Stop } catch {}
    if ($pingOk -and -not $dnsOk) {
        Add-Finding -Id 'dns-error' -Severity 'High' -Category 'Network' -Title 'Internet reachable, but name resolution (DNS) does not work' `
            -Meaning 'DNS translates web addresses into IP addresses. Without DNS, no browser, no Windows Update and no Store works even though the line is up.' `
            -Recommendation 'Restart the router; alternatively enter a different DNS server in the adapter settings (e.g. 1.1.1.1 or 9.9.9.9).'
        Invoke-Native -File "$env:WINDIR\System32\ipconfig.exe" -Arguments @('/flushdns') -Quiet | Out-Null
        Add-Action 'Network' 'DNS cache flushed' 'ipconfig /flushdns was executed.'
    } elseif (-not $pingOk) {
        Add-Finding -Id 'offline' -Severity 'High' -Category 'Network' -Title 'No internet connection' `
            -Meaning 'Without internet, Windows Update, the Store, Defender updates and DISM repairs from the web are not possible.' `
            -Recommendation 'Check cable/WLAN, router and airplane mode. Then start the script again. If Windows network problems persist: Settings > Network & Internet > Network troubleshooter.'
    }
}

function Invoke-StabilityCheck {
    # Reliability Monitor index (1 = unstable ... 10 = rock solid)
    try {
        $rm = @(Get-CimInstance Win32_ReliabilityStabilityMetrics -ErrorAction Stop | Where-Object { $_.TimeGenerated -gt (Get-Date).AddDays(-14) } | Sort-Object TimeGenerated)
        if ($rm.Count -gt 0) {
            $avg = [math]::Round(($rm | Measure-Object -Property SystemStabilityIndex -Average).Average, 1)
            $last = [math]::Round($rm[-1].SystemStabilityIndex, 1)
            Add-Fact 'Stability index (Reliability Monitor, 14 days)' "average $avg / 10, latest $last / 10"
            if ($avg -lt 5) {
                Add-Finding -Id 'stability-low' -Severity 'Medium' -Category 'Stability' -Title "Reliability index is low ($avg / 10)" `
                    -Meaning 'The Reliability Monitor condenses crashes, hangs and failed installs into one score. Below 5 the PC has had repeated problems recently.' `
                    -Evidence "14-day average $avg, latest $last." -Recommendation 'Open "View reliability history" (Start menu search) to see which program or update caused the drops.'
            }
        }
    } catch {}

    # Windows Memory Diagnostic result (1201 = ok, 1202 = errors)
    try {
        $md = Get-WinEvent -FilterHashtable @{ LogName = 'System'; ProviderName = 'Microsoft-Windows-MemoryDiagnostics-Results'; StartTime = (Get-Date).AddDays(-180) } -MaxEvents 1 -ErrorAction Stop
        if ($md) {
            Add-Fact 'Last memory diagnostic' "$($md.TimeCreated.ToString('yyyy-MM-dd')): $(if ($md.Id -eq 1202) { 'ERRORS FOUND' } else { 'no errors' })"
            if ($md.Id -eq 1202) {
                Add-Finding -Id 'memdiag-errors' -Severity 'Critical' -Category 'Hardware' -Title 'Windows Memory Diagnostic found RAM errors' `
                    -Meaning 'The memory test reported errors. Defective RAM causes blue screens, corrupted files and random crashes.' `
                    -Evidence $md.TimeCreated.ToString('yyyy-MM-dd HH:mm') -Recommendation 'Test one RAM stick at a time (MemTest86), remove or replace the faulty module. Undo XMP/overclocking first.'
            }
        }
    } catch {}

    # Kernel live reports can grow to several GB
    try {
        $lk = Get-FolderBytes "$env:WINDIR\LiveKernelReports"
        if ($lk -gt 1GB) { Add-Fact 'LiveKernelReports size' (Format-Size $lk) }
    } catch {}
}

function Invoke-EventLogAnalysis {
    $since = (Get-Date).AddDays(-7)
    Write-Info 'Analyzing errors of the last 7 days in the System and Application event logs ...'
    $events = @()
    # Levels 1-3: several known events (disk 51/153, WHEA 17/19, Display 4101, Resource-Exhaustion 2004) are Warnings.
    try { $events = @(Get-WinEvent -FilterHashtable @{ LogName = 'System', 'Application'; Level = 1, 2, 3; StartTime = $since } -MaxEvents 8000 -ErrorAction SilentlyContinue) } catch {}
    # Defender lives in its own log (threat detections, real-time protection failures).
    try {
        $events += @(Get-WinEvent -FilterHashtable @{ LogName = 'Microsoft-Windows-Windows Defender/Operational'; Id = 1116, 1117, 3002; StartTime = $since } -MaxEvents 200 -ErrorAction SilentlyContinue)
    } catch {}
    Add-Fact 'Error/warning entries (7 days)' "$($events.Count)"
    Write-Info "$($events.Count) error/warning entries found."
    if ($events.Count -eq 0) { Invoke-StabilityCheck; Add-Action 'Event log' 'Completed' 'No error entries in the last 7 days.'; return }

    $groups = $events | Group-Object { "$($_.ProviderName)|$($_.Id)" }
    $unknown = @()
    foreach ($g in $groups) {
        $key = $g.Name
        if ($script:EventIgnore -contains $key) { continue }
        if ($script:EventKb.ContainsKey($key)) {
            $kb = $script:EventKb[$key]
            $min = if ($kb.Min) { [int]$kb.Min } else { 1 }
            if ($g.Count -lt $min) { continue }
            $details = @()
            foreach ($e in ($g.Group | Select-Object -First 3)) {
                $prop = ''
                try {
                    if ($e.ProviderName -eq 'Microsoft-Windows-Windows Defender' -and $e.Properties.Count -gt 7) { $prop = " - $($e.Properties[7].Value)" }   # threat name
                    elseif ($e.Properties.Count -gt 0) { $prop = " - $($e.Properties[0].Value)" }
                } catch {}
                $details += "$($e.TimeCreated.ToString('MM-dd HH:mm'))$prop"
            }
            $extra = ''
            if ($key -eq 'Microsoft-Windows-WER-SystemErrorReporting|1001') {
                $codes = @()
                foreach ($e in $g.Group) {
                    $m = [regex]::Match([string]$e.Message, '0x[0-9a-fA-F]{8}')
                    if ($m.Success) {
                        $c = $m.Value.ToLower()
                        $name = if ($script:BugCheckNames.ContainsKey($c)) { $script:BugCheckNames[$c] } else { 'unknown stop code' }
                        $codes += "$c = $name"
                    }
                }
                if ($codes.Count -gt 0) { $extra = "`nStop codes: " + (($codes | Select-Object -Unique) -join '; ') }
            }
            Add-Finding -Id "evt-$key" -Severity $kb.S -Category 'Event log' -Title "$($kb.T) - $($g.Count)x in 7 days" `
                -Meaning $kb.M -Evidence ("Most recent: " + ($details -join '; ') + $extra) -Recommendation $kb.A
        } elseif ($key -match '^Application Error\|1000$') {
            $apps = $g.Group | Group-Object { try { [string]$_.Properties[0].Value } catch { 'unknown' } } | Sort-Object Count -Descending
            $top = $apps | Where-Object { $_.Count -ge 3 } | Select-Object -First 8
            if ($top) {
                Add-Finding -Id 'evt-appcrash' -Severity 'Medium' -Category 'Event log' -Title 'Programs crash repeatedly' `
                    -Meaning 'A program is terminated by Windows because of a severe error. Repeated crashes of the same program point to a broken installation, incompatibility, outdated version or faulty drivers/hardware.' `
                    -Evidence (($top | ForEach-Object { "$($_.Name): $($_.Count)x" }) -join '; ') `
                    -Recommendation 'Update or reinstall the affected program. If many different programs crash, check the RAM (mdsched.exe) and disks.'
            }
        } elseif ($key -match '^Application Hang\|1002$') {
            $apps = $g.Group | Group-Object { try { [string]$_.Properties[0].Value } catch { 'unknown' } } | Sort-Object Count -Descending
            $top = $apps | Where-Object { $_.Count -ge 3 } | Select-Object -First 8
            if ($top) {
                Add-Finding -Id 'evt-apphang' -Severity 'Low' -Category 'Event log' -Title 'Programs repeatedly stop responding' `
                    -Meaning 'Programs that stop responding ("Not responding") point to overload, a slow disk or software errors.' `
                    -Evidence (($top | ForEach-Object { "$($_.Name): $($_.Count)x" }) -join '; ') `
                    -Recommendation 'Update/reinstall the program, watch disk health and RAM usage.'
            }
        } elseif ($g.Count -ge 5 -and $g.Group[0].Level -le 2) {
            $sample = $g.Group[0]
            $msg = ''
            try { $msg = ([string]$sample.Message -split "`r?`n")[0] } catch {}
            if ($msg.Length -gt 160) { $msg = $msg.Substring(0, 160) + ' ...' }
            $unknown += [pscustomobject]@{ Source = $sample.ProviderName; 'Event ID' = $sample.Id; Count = $g.Count; SampleMessage = $msg }
        }
    }
    $script:Tables['Other frequent error messages (5x or more in 7 days)'] = @($unknown | Sort-Object Count -Descending | Select-Object -First 12)
    if ($unknown.Count -gt 0) {
        Add-Finding -Id 'evt-other' -Severity 'Info' -Category 'Event log' -Title "$($unknown.Count) other error message(s) occur frequently" `
            -Meaning 'The script does not know these messages in detail. Individual errors in the event log are normal for Windows; what matters are accumulations or messages that match noticeable problems.' `
            -Evidence 'See the table "Other frequent error messages" further down in the report.' `
            -Recommendation 'Search online for "<source> event <ID>". Only intervene if you also notice problems.' -Status 'Info'
    }

    # Minidumps
    try {
        $dumps = Get-ChildItem "$env:WINDIR\Minidump" -Filter *.dmp -ErrorAction SilentlyContinue | Where-Object { $_.LastWriteTime -gt (Get-Date).AddDays(-30) }
        if ($dumps) {
            Add-Fact 'Crash dumps (30 days)' "$(@($dumps).Count)"
            Add-Finding -Id 'bsod-dumps' -Severity 'High' -Category 'Stability' -Title "$(@($dumps).Count) blue screen crash dump(s) in the last 30 days" `
                -Meaning 'On every blue screen Windows writes a crash dump. It helps to determine the causing driver.' `
                -Evidence ((($dumps | Sort-Object LastWriteTime -Descending | Select-Object -First 5) | ForEach-Object { "$($_.Name) ($($_.LastWriteTime.ToString('yyyy-MM-dd HH:mm')))" }) -join '; ') `
                -Recommendation "Use the free Microsoft tool WinDbg or NirSoft BlueScreenView to determine the causing driver. The files are located in C:\Windows\Minidump and were deliberately NOT deleted by this script."
        }
    } catch {}
    Invoke-StabilityCheck
    Add-Action 'Event log' 'Completed' "$($events.Count) error/warning entries of the last 7 days evaluated."
}

function Invoke-ServiceAndDriverCheck {
    # 1. Important services that someone set to "Disabled"
    $expected = [ordered]@{
        'wuauserv' = 'Manual'; 'BITS' = 'Manual'; 'CryptSvc' = 'Automatic'; 'EventLog' = 'Automatic'; 'Winmgmt' = 'Automatic'
        'mpssvc' = 'Automatic'; 'Schedule' = 'Automatic'; 'Dhcp' = 'Automatic'; 'Dnscache' = 'Automatic'; 'W32Time' = 'Manual'
        'TrustedInstaller' = 'Manual'; 'UsoSvc' = 'Automatic'; 'InstallService' = 'Manual'; 'ClipSVC' = 'Manual'
        'wscsvc' = 'Automatic'; 'AppXSvc' = 'Manual'; 'RpcSs' = 'Automatic'; 'BrokerInfrastructure' = 'Automatic'
        'WinDefend' = 'Automatic'; 'SecurityHealthService' = 'Manual'; 'StateRepository' = 'Manual'; 'DoSvc' = 'Automatic'
        'LanmanWorkstation' = 'Automatic'; 'nsi' = 'Automatic'; 'Wcmsvc' = 'Automatic'; 'DcomLaunch' = 'Automatic'; 'sppsvc' = 'Automatic'
        'netprofm' = 'Manual'; 'TimeBrokerSvc' = 'Manual'; 'VSS' = 'Manual'; 'swprv' = 'Manual'
    }
    $nice = @{
        'wuauserv' = 'Windows Update'; 'BITS' = 'Background Intelligent Transfer Service (update download)'; 'CryptSvc' = 'Cryptographic Services (update signatures)'
        'EventLog' = 'Event Log'; 'Winmgmt' = 'WMI (Windows Management Instrumentation)'; 'mpssvc' = 'Windows Firewall'; 'Schedule' = 'Task Scheduler'
        'Dhcp' = 'DHCP Client'; 'Dnscache' = 'DNS Client'; 'W32Time' = 'Windows Time'; 'TrustedInstaller' = 'Windows Modules Installer (updates)'
        'UsoSvc' = 'Update Orchestrator'; 'InstallService' = 'Microsoft Store Install Service'; 'ClipSVC' = 'Client License Service (Store)'
        'wscsvc' = 'Security Center'; 'AppXSvc' = 'AppX Deployment Service (Store apps)'; 'RpcSs' = 'RPC Service'; 'BrokerInfrastructure' = 'Background Tasks Infrastructure'
        'WinDefend' = 'Microsoft Defender Antivirus Service'; 'SecurityHealthService' = 'Windows Security Service'; 'StateRepository' = 'State Repository (Store apps)'
        'DoSvc' = 'Delivery Optimization (update downloads)'; 'LanmanWorkstation' = 'Workstation (network shares)'; 'nsi' = 'Network Store Interface'
        'Wcmsvc' = 'Windows Connection Manager'; 'DcomLaunch' = 'DCOM Server Process Launcher'; 'sppsvc' = 'Software Protection (activation)'
        'netprofm' = 'Network List Service'; 'TimeBrokerSvc' = 'Time Broker'; 'VSS' = 'Volume Shadow Copy (restore points)'; 'swprv' = 'Software Shadow Copy Provider'
    }
    $fixedSvc = @(); $failedSvc = @()
    foreach ($name in $expected.Keys) {
        $svc = Get-CimInstance Win32_Service -Filter "Name='$name'" -ErrorAction SilentlyContinue
        if (-not $svc) { continue }
        if ($svc.StartMode -eq 'Disabled') {
            $label = "$($nice[$name]) ($name)"
            Write-Warn2 "Service disabled: $label"
            if (Test-DryRun "reset $label to $($expected[$name])") { $failedSvc += "$label (DryRun: not changed)"; continue }
            try {
                Set-Service -Name $name -StartupType $expected[$name] -ErrorAction Stop
                if ($expected[$name] -eq 'Automatic') { Start-Service -Name $name -ErrorAction SilentlyContinue }
                $fixedSvc += $label
            } catch { $failedSvc += "$label ($($_.Exception.Message))" }
        }
    }
    if ($fixedSvc.Count -gt 0) {
        Add-Finding -Id 'services-disabled' -Severity 'High' -Category 'Services' -Title "$($fixedSvc.Count) important Windows service(s) were disabled" `
            -Meaning 'These services are required for updates, security or system stability. They are often switched off by "optimization tools" and then cause hard-to-explain errors (e.g. update error 0x80070422).' `
            -Evidence ($fixedSvc -join '; ') -Recommendation 'The script reset the services to the Windows default startup type. No further action needed.' -Status 'Fixed'
        Add-Action 'Services' 'Fixed' "Reset: $($fixedSvc -join ', ')"
    }
    if ($failedSvc.Count -gt 0) {
        Add-Finding -Id 'services-disabled-failed' -Severity 'High' -Category 'Services' -Title "$($failedSvc.Count) disabled service(s) could not be reset" `
            -Meaning 'Services are disabled and could not be corrected automatically (e.g. protected by group policy or security software).' `
            -Evidence ($failedSvc -join '; ') -Recommendation 'Open services.msc, double-click the service and set the startup type back to the default manually; on company computers ask the IT department.'
    }

    # 2. Automatic services that ended with an error
    try {
        $bad = @(Get-CimInstance Win32_Service -Filter "StartMode='Auto' AND State='Stopped'" -ErrorAction Stop | Where-Object { $_.ExitCode -notin 0, 1077 })
        $stillBad = @()
        foreach ($b in $bad) {
            if ($script:DryRun) { $stillBad += "$($b.DisplayName) [$($b.Name)] (exit code $($b.ExitCode), DryRun: not restarted)"; continue }
            try { Start-Service -Name $b.Name -ErrorAction Stop; Write-Ok "Service '$($b.DisplayName)' restarted." } catch { $stillBad += "$($b.DisplayName) [$($b.Name)] (exit code $($b.ExitCode))" }
        }
        if ($stillBad.Count -gt 0) {
            Add-Finding -Id 'services-error' -Severity 'Medium' -Category 'Services' -Title "$($stillBad.Count) automatically starting service(s) ended with an error and do not start" `
                -Meaning 'A service that should run automatically has crashed or does not start. Consequence: the related function (e.g. driver software, cloud sync, security program) is missing.' `
                -Evidence (($stillBad | Select-Object -First 10) -join '; ') `
                -Recommendation 'Update/reinstall the related software. Details: Event Viewer > Windows Logs > System.'
        }
    } catch {}

    # 3. Devices with driver problems
    $codeMap = @{
        1 = 'Device is not configured correctly'; 3 = 'Driver corrupted or not enough memory'; 10 = 'The device cannot start'
        12 = 'Resource conflict'; 14 = 'Restart required'; 18 = 'Reinstall the driver'; 19 = 'Registry corrupted'; 24 = 'Device not present/defective'
        28 = 'No driver is installed'; 31 = 'The device is not working properly (driver cannot be loaded)'; 37 = 'Driver initialization failed'
        39 = 'Driver corrupted or missing'; 41 = 'Driver loaded, but device not found'; 43 = 'The device reported problems and was stopped'
        52 = 'Driver signature cannot be verified'
    }
    try {
        $pnp = Get-CimInstance Win32_PnPEntity -ErrorAction Stop | Where-Object { $_.ConfigManagerErrorCode -and $_.ConfigManagerErrorCode -notin 0, 22, 45 -and $_.Present -ne $false }
        $pnp = @($pnp | Where-Object { $_.Name })
        $prows = @()
        foreach ($d in $pnp) {
            $c = [int]$d.ConfigManagerErrorCode
            $m = if ($codeMap.ContainsKey($c)) { $codeMap[$c] } else { 'Unknown device error' }
            $prows += [pscustomobject]@{ Device = $d.Name; ErrorCode = $c; Meaning = $m }
        }
        $script:Tables['Devices with driver problems'] = $prows
        if ($prows.Count -gt 0) {
            Add-Finding -Id 'driver-problems' -Severity 'Medium' -Category 'Drivers' -Title "$($prows.Count) device(s) with an error in Device Manager" `
                -Meaning 'A driver is missing for these devices or the driver does not work. The device (e.g. WLAN, sound card, card reader) then does not work or only works in a limited way.' `
                -Evidence (($prows | Select-Object -First 8 | ForEach-Object { "$($_.Device): code $($_.ErrorCode) - $($_.Meaning)" }) -join "`n") `
                -Recommendation 'Let Windows Update look for drivers (optional updates) or download the driver from the manufacturer of the device or laptop. Device Manager > right-click the device > Update driver.'
        }
    } catch {}
    # 4. Unsigned and very old drivers
    try {
        $drv = @(Get-CimInstance Win32_PnPSignedDriver -ErrorAction Stop | Where-Object { $_.DeviceName -and $_.DriverProviderName -notmatch '^Microsoft' })
        $uns = @($drv | Where-Object { $_.IsSigned -eq $false })
        if ($uns.Count -gt 0) {
            Add-Finding -Id 'drivers-unsigned' -Severity 'Medium' -Category 'Drivers' -Title "$($uns.Count) unsigned driver(s) installed" `
                -Meaning 'Unsigned kernel drivers were not verified by Microsoft. They are a stability risk and a favourite hiding place for rootkits.' `
                -Evidence (($uns | Select-Object -First 8 | ForEach-Object { "$($_.DeviceName) ($($_.DriverProviderName) $($_.DriverVersion))" }) -join "`n") `
                -Recommendation 'Update the drivers from the manufacturer, or uninstall the device/software if you do not recognise it.'
        }
        $old = @($drv | Where-Object { $_.DriverDate -and $_.DriverDate -lt (Get-Date).AddYears(-6) -and $_.DeviceClass -in 'NET', 'MEDIA', 'DISPLAY', 'SYSTEM', 'HDC', 'USB', 'BLUETOOTH' })
        if ($old.Count -gt 0) {
            $script:Tables['Drivers older than 6 years'] = @($old | Sort-Object DriverDate | Select-Object -First 15 | ForEach-Object { [pscustomobject]@{ Device = $_.DeviceName; Provider = $_.DriverProviderName; Version = $_.DriverVersion; Date = $_.DriverDate.ToString('yyyy-MM-dd') } })
        }
    } catch {}
    Add-Action 'Services & drivers' 'Completed' "Services reset: $($fixedSvc.Count)."
}

# ----------------------------------------------------------------------------------------------
# 5. Cleanup
# ----------------------------------------------------------------------------------------------
function Invoke-Cleanup {
    Initialize-RestorePoint
    $freeBefore = Get-SystemFreeBytes
    $rows = @()
    $runningBrowsers = @(Get-Process -Name chrome, msedge, firefox, brave, opera, vivaldi -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Name -Unique)

    # (display name, path, minimum age in days, file filter)
    $targets = @(
        @('Temporary files (user)', $env:TEMP, 2, '*'),
        @('Temporary files (Windows)', "$env:WINDIR\Temp", 2, '*'),
        @('Internet cache (Windows/IE)', "$env:LOCALAPPDATA\Microsoft\Windows\INetCache", 2, '*'),
        @('Crash dumps of programs', "$env:LOCALAPPDATA\CrashDumps", 0, '*'),
        @('Windows error reports (user)', "$env:LOCALAPPDATA\Microsoft\Windows\WER", 0, '*'),
        @('Windows error reports (system)', "$env:ProgramData\Microsoft\Windows\WER\ReportArchive", 0, '*'),
        @('Windows error reports (queue)', "$env:ProgramData\Microsoft\Windows\WER\ReportQueue", 0, '*'),
        @('Shader cache (DirectX)', "$env:LOCALAPPDATA\D3DSCache", 0, '*'),
        @('Thumbnail cache', "$env:LOCALAPPDATA\Microsoft\Windows\Explorer", 0, 'thumbcache_*.db'),
        @('Old Windows servicing logs (CBS cabs)', "$env:WINDIR\Logs\CBS", 14, '*.cab'),
        @('Kernel live reports', "$env:WINDIR\LiveKernelReports", 7, '*.dmp'),
        @('Windows Update logs', "$env:WINDIR\Logs\WindowsUpdate", 14, '*'),
        @('Windows setup logs (Panther)', "$env:WINDIR\Panther", 30, '*.log'),
        @('Downloaded Program Files', "$env:WINDIR\Downloaded Program Files", 0, '*'),
        @('Defender scan history', "$env:ProgramData\Microsoft\Windows Defender\Scans\History\Results", 14, '*'),
        @('Icon cache', "$env:LOCALAPPDATA\Microsoft\Windows\Explorer", 0, 'iconcache_*.db'),
        @('Microsoft Office file cache', "$env:LOCALAPPDATA\Microsoft\Office\16.0\OfficeFileCache", 7, '*'),
        @('Teams cache (classic)', "$env:APPDATA\Microsoft\Teams\Cache", 0, '*'),
        @('Teams cache (classic, GPU)', "$env:APPDATA\Microsoft\Teams\GPUCache", 0, '*'),
        @('Discord cache', "$env:APPDATA\discord\Cache", 0, '*'),
        @('Discord code cache', "$env:APPDATA\discord\Code Cache", 0, '*'),
        @('Slack cache', "$env:APPDATA\Slack\Cache", 0, '*'),
        @('Spotify cache', "$env:LOCALAPPDATA\Spotify\Data", 0, '*'),
        @('npm cache', "$env:LOCALAPPDATA\npm-cache", 30, '*'),
        @('pip cache', "$env:LOCALAPPDATA\pip\Cache", 30, '*'),
        @('NuGet HTTP cache', "$env:LOCALAPPDATA\NuGet\v3-cache", 30, '*'),
        @('Old update backup folders (SoftwareDistribution.bak)', $null, 0, '*')
    )
    Write-Info 'Only junk folders are cleaned. Personal files (documents, pictures, downloads, desktop) are NOT touched.'
    foreach ($t in $targets) {
        $name = $t[0]; $path = $t[1]
        if ($name -like 'Old update backup folders*') {
            $bytes = [int64]0; $n = 0
            # Age comes from the timestamp in the folder name (renaming a folder does not change its LastWriteTime).
            Get-ChildItem -Path $env:WINDIR -Directory -Filter 'SoftwareDistribution.bak_*' -ErrorAction SilentlyContinue |
                Where-Object { (Get-BackupFolderAge $_) -gt 7 } | ForEach-Object {
                    $b = Get-FolderBytes $_.FullName
                    if ($script:DryRun) { Write-Info "[DryRun] would delete $($_.FullName)"; return }
                    try { Remove-Item -LiteralPath $_.FullName -Recurse -Force -ErrorAction Stop; $bytes += $b; $n++ } catch {}
                }
            Get-ChildItem -Path "$env:WINDIR\System32" -Directory -Filter 'catroot2.bak_*' -ErrorAction SilentlyContinue |
                Where-Object { (Get-BackupFolderAge $_) -gt 7 } | ForEach-Object {
                    if ($script:DryRun) { return }
                    try { Remove-Item -LiteralPath $_.FullName -Recurse -Force -ErrorAction Stop } catch {}
                }
            if ($n -gt 0) { $rows += [pscustomobject]@{ Area = $name; Freed = (Format-Size $bytes); Files = $n; Skipped = 0 }; $script:FreedTotal += $bytes; Write-Ok "$name : $(Format-Size $bytes)" }
            continue
        }
        if (-not (Test-Path -LiteralPath $path -ErrorAction SilentlyContinue)) { continue }
        $r = Clear-Folder -Path $path -OlderThanDays $t[2] -NameLike $t[3]
        if ($r.Files -gt 0 -or $r.Failed -gt 0) {
            $rows += [pscustomobject]@{ Area = $name; Freed = (Format-Size $r.Freed); Files = $r.Files; Skipped = $r.Failed }
            $script:FreedTotal += $r.Freed
            Write-Ok ("{0}{1}: {2} ({3} files, {4} in use/skipped)" -f $(if ($script:DryRun) { '[DryRun, not deleted] ' } else { '' }), $name, (Format-Size $r.Freed), $r.Files, $r.Failed)
        }
    }

    # Browser caches (cache only, no cookies/passwords/history)
    foreach ($b in @(
        @{ N = 'Google Chrome'; P = 'chrome'; R = "$env:LOCALAPPDATA\Google\Chrome\User Data" },
        @{ N = 'Microsoft Edge'; P = 'msedge'; R = "$env:LOCALAPPDATA\Microsoft\Edge\User Data" },
        @{ N = 'Brave'; P = 'brave'; R = "$env:LOCALAPPDATA\BraveSoftware\Brave-Browser\User Data" },
        @{ N = 'Vivaldi'; P = 'vivaldi'; R = "$env:LOCALAPPDATA\Vivaldi\User Data" })) {
        if (-not (Test-Path -LiteralPath $b.R)) { continue }
        if ($runningBrowsers -contains $b.P) {
            Write-Warn2 "$($b.N) is running - cache is skipped (close the browser and run again to clear it)."
            Add-Action 'Cleanup' 'Skipped' "$($b.N) cache: browser was open."
            continue
        }
        $bytes = [int64]0; $files = 0
        foreach ($prof in (Get-ChildItem -LiteralPath $b.R -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -eq 'Default' -or $_.Name -like 'Profile *' })) {
            foreach ($sub in 'Cache', 'Code Cache', 'GPUCache', 'Service Worker\CacheStorage', 'Service Worker\ScriptCache') {
                $r = Clear-Folder -Path (Join-Path $prof.FullName $sub)
                $bytes += $r.Freed; $files += $r.Files
            }
        }
        if ($files -gt 0) { $rows += [pscustomobject]@{ Area = "$($b.N) cache"; Freed = (Format-Size $bytes); Files = $files; Skipped = 0 }; $script:FreedTotal += $bytes; Write-Ok "$($b.N) cache: $(Format-Size $bytes)" }
    }
    if (Test-Path "$env:LOCALAPPDATA\Mozilla\Firefox\Profiles") {
        if ($runningBrowsers -contains 'firefox') { Write-Warn2 'Firefox is running - cache is skipped.' }
        else {
            $bytes = [int64]0; $files = 0
            foreach ($prof in (Get-ChildItem "$env:LOCALAPPDATA\Mozilla\Firefox\Profiles" -Directory -ErrorAction SilentlyContinue)) {
                $r = Clear-Folder -Path (Join-Path $prof.FullName 'cache2'); $bytes += $r.Freed; $files += $r.Files
            }
            if ($files -gt 0) { $rows += [pscustomobject]@{ Area = 'Firefox cache'; Freed = (Format-Size $bytes); Files = $files; Skipped = 0 }; $script:FreedTotal += $bytes; Write-Ok "Firefox cache: $(Format-Size $bytes)" }
        }
    }

    # Windows Update download cache
    $sdDownload = "$env:WINDIR\SoftwareDistribution\Download"
    if (Test-Path $sdDownload) {
        $sz = Get-FolderBytes $sdDownload
        if ($sz -gt 50MB -and (Confirm-Step "Clear the Windows Update download cache ($(Format-Size $sz))? Windows downloads required updates again when needed.")) {
            foreach ($s in 'wuauserv', 'bits') { Stop-Service -Name $s -Force -ErrorAction SilentlyContinue }
            Start-Sleep -Seconds 2
            $r = Clear-Folder -Path $sdDownload
            foreach ($s in 'bits', 'wuauserv') { try { $st = (Get-Service $s).StartType; if ($st -ne 'Disabled') { Start-Service -Name $s -ErrorAction SilentlyContinue } } catch {} }
            $rows += [pscustomobject]@{ Area = 'Windows Update download cache'; Freed = (Format-Size $r.Freed); Files = $r.Files; Skipped = $r.Failed }
            $script:FreedTotal += $r.Freed
            Write-Ok "Update download cache: $(Format-Size $r.Freed)"
        }
    }

    # Delivery Optimization
    try {
        $doPath = "$env:WINDIR\ServiceProfiles\NetworkService\AppData\Local\Microsoft\Windows\DeliveryOptimization\Cache"
        $sz = Get-FolderBytes $doPath
        if ($sz -gt 50MB -and -not (Test-DryRun "clear Delivery Optimization cache ($(Format-Size $sz))")) {
            Delete-DeliveryOptimizationCache -Force -ErrorAction SilentlyContinue
            $new = Get-FolderBytes $doPath
            if ($sz -gt $new) { $rows += [pscustomobject]@{ Area = 'Delivery Optimization (update cache)'; Freed = (Format-Size ($sz - $new)); Files = '-'; Skipped = 0 }; $script:FreedTotal += ($sz - $new); Write-Ok "Delivery Optimization: $(Format-Size ($sz - $new))" }
        }
    } catch {}

    # Memory dumps
    $recentBsod = @(Get-ChildItem "$env:WINDIR\Minidump" -Filter *.dmp -ErrorAction SilentlyContinue | Where-Object { $_.LastWriteTime -gt (Get-Date).AddDays(-14) })
    $memDmp = "$env:WINDIR\MEMORY.DMP"
    if (Test-Path $memDmp) {
        $dsz = (Get-Item $memDmp -Force).Length
        if ($recentBsod.Count -gt 0) {
            Write-Info "MEMORY.DMP ($(Format-Size $dsz)) is kept because blue screens occurred recently (it is needed for troubleshooting)."
        } elseif (Confirm-Step "Delete the old memory dump C:\Windows\MEMORY.DMP ($(Format-Size $dsz))? It is only needed for troubleshooting after blue screens.") {
            try { Remove-Item -LiteralPath $memDmp -Force -ErrorAction Stop; $script:FreedTotal += $dsz; $rows += [pscustomobject]@{ Area = 'Memory dump MEMORY.DMP'; Freed = (Format-Size $dsz); Files = 1; Skipped = 0 }; Write-Ok 'MEMORY.DMP deleted.' } catch { Write-Warn2 'MEMORY.DMP could not be deleted.' }
        }
    }

    # Recycle Bin (personal data -> never automatically)
    try {
        $rbBytes = [int64]0
        foreach ($d in (Get-CimInstance Win32_LogicalDisk -Filter 'DriveType=3' -ErrorAction SilentlyContinue)) {
            $rb = Join-Path ($d.DeviceID + '\') '$Recycle.Bin'
            if (Test-Path -LiteralPath $rb -ErrorAction SilentlyContinue) { $rbBytes += Get-FolderBytes $rb }
        }
        if ($rbBytes -gt 100MB) {
            Write-Info "The Recycle Bin contains about $(Format-Size $rbBytes)."
            if (Confirm-Step 'Permanently empty the Recycle Bin now? Deleted files cannot be recovered afterwards.' -Default $false -Risky) {
                Clear-RecycleBin -Force -ErrorAction SilentlyContinue
                $script:FreedTotal += $rbBytes
                $rows += [pscustomobject]@{ Area = 'Recycle Bin'; Freed = (Format-Size $rbBytes); Files = '-'; Skipped = 0 }
            } else {
                Add-Finding -Id 'recycle-bin' -Severity 'Info' -Category 'Storage' -Title "Recycle Bin occupies about $(Format-Size $rbBytes)" `
                    -Meaning 'Files deleted into the Recycle Bin keep occupying storage until it is emptied. The script only empties it with your explicit consent.' `
                    -Recommendation 'Check the Recycle Bin and empty it manually.' -Status 'Info'
            }
        }
    } catch {}

    # Notes on large legacy leftovers (report only, no deletion)
    foreach ($old in @(@{ P = "$env:SystemDrive\Windows.old"; N = 'Windows.old (previous Windows installation)' }, @{ P = "$env:SystemDrive\`$WINDOWS.~BT"; N = '$WINDOWS.~BT (upgrade installation files)' }, @{ P = "$env:SystemDrive\`$WINDOWS.~WS"; N = '$WINDOWS.~WS (upgrade installation files)' })) {
        if (Test-Path -LiteralPath $old.P -ErrorAction SilentlyContinue) {
            $sz = Get-FolderBytes $old.P
            if ($sz -gt 500MB) {
                Add-Finding -Id "leftover-$($old.P)" -Severity 'Info' -Category 'Storage' -Title "$($old.N) occupies $(Format-Size $sz)" `
                    -Meaning 'These folders are created by large Windows updates or upgrade preparations. They allow rolling back to the old version. If $WINDOWS.~BT was created by a Windows 11 preparation, it is unnecessary.' `
                    -Recommendation 'Delete safely via: Settings > System > Storage > Temporary files > "Previous Windows installation(s)" or Disk Cleanup > Clean up system files. Do not delete manually in Explorer. After deletion, rolling back is no longer possible.' -Status 'Info'
            }
        }
    }

    # Component store: how much is reclaimable?
    try {
        $an = (Invoke-Native -File "$env:WINDIR\System32\dism.exe" -Arguments @('/Online', '/Cleanup-Image', '/AnalyzeComponentStore') -Quiet -TimeoutSec 600).Output
        $m = [regex]::Match($an, '(?im)(Reclaimable Packages|Wiederherstellbare Pakete)\s*:\s*(\d+)')
        $m2 = [regex]::Match($an, '(?im)(Actual Size of Component Store|Tatsächliche Größe des Komponentenspeichers)\s*:\s*(.+)$')
        if ($m2.Success) { Add-Fact 'Component store (WinSxS) size' $m2.Groups[2].Value.Trim() }
        if ($m.Success) { Add-Fact 'Reclaimable component packages' $m.Groups[2].Value }
    } catch {}

    # Windows 10 built-in cleanup handlers (Disk Cleanup "system files"): old upgrade logs, driver packages, etc.
    if (Confirm-Step 'Run Windows Disk Cleanup for system files (update leftovers, upgrade logs, error-report files, setup logs)?') {
        $vc = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\VolumeCaches'
        $handlers = 'Update Cleanup', 'Windows Upgrade Log Files', 'Setup Log Files', 'Windows Error Reporting Files', 'Temporary Setup Files', 'Delivery Optimization Files', 'Device Driver Packages', 'Windows ESD installation files', 'Old ChkDsk Files', 'Thumbnail Cache'
        foreach ($h in $handlers) { if (Test-Path "$vc\$h") { Set-ItemProperty -Path "$vc\$h" -Name 'StateFlags6464' -Value 2 -Type DWord -ErrorAction SilentlyContinue } }
        $before = Get-SystemFreeBytes
        $null = Invoke-Native -File "$env:WINDIR\System32\cleanmgr.exe" -Arguments @('/sagerun:6464') -Quiet -TimeoutSec 1800
        foreach ($h in $handlers) { Remove-ItemProperty -Path "$vc\$h" -Name 'StateFlags6464' -ErrorAction SilentlyContinue }
        $gain = (Get-SystemFreeBytes) - $before
        if ($gain -gt 0) { $rows += [pscustomobject]@{ Area = 'Windows Disk Cleanup (system files)'; Freed = (Format-Size $gain); Files = '-'; Skipped = 0 }; $script:FreedTotal += $gain }
        Add-Action 'Cleanup' 'Success' 'Windows Disk Cleanup (system files) ran.'
    }

    # Docker / WSL disk images do not shrink by themselves
    $wslDisks = @(Get-ChildItem "$env:LOCALAPPDATA\Packages" -Filter ext4.vhdx -Recurse -ErrorAction SilentlyContinue | Where-Object { $_.Length -gt 5GB })
    if ($wslDisks.Count -gt 0) {
        Add-Finding -Id 'wsl-vhdx' -Severity 'Info' -Category 'Storage' -Title "WSL virtual disk(s) occupy $(Format-Size (($wslDisks | Measure-Object Length -Sum).Sum))" `
            -Meaning 'WSL distributions store their files in a .vhdx that grows but never shrinks automatically.' `
            -Evidence (($wslDisks | ForEach-Object { "$($_.FullName) ($(Format-Size $_.Length))" }) -join "`n") `
            -Recommendation 'Run "wsl --shutdown", then "Optimize-VHD -Path <file> -Mode Full" (Hyper-V module) or diskpart > select vdisk file=... > compact vdisk.' -Status 'Info'
    }

    # Component store cleanup
    if ((Test-LongOperationAllowed 'Component store cleanup') -and (Confirm-Step 'Clean up the Windows component store (DISM StartComponentCleanup, safe, may take a few minutes)?')) {
        Write-Info 'Cleaning up the component store ...'
        $r = Invoke-Native -File "$env:WINDIR\System32\dism.exe" -Arguments @('/Online', '/Cleanup-Image', '/StartComponentCleanup') -Quiet -TimeoutSec 3600
        if ($r.ExitCode -eq 0) { Write-Ok 'Component store cleaned up.'; Add-Action 'Cleanup' 'Success' 'DISM StartComponentCleanup completed.' }
        else { Write-Warn2 "DISM reported code $($r.ExitCode)."; Add-Action 'Cleanup' 'Note' "DISM StartComponentCleanup: return code $($r.ExitCode)" }
    }

    $freeAfter = Get-SystemFreeBytes
    $realGain = $freeAfter - $freeBefore
    if ($realGain -lt 0) { $realGain = 0 }
    $script:Tables['Cleanup in detail'] = $rows
    Add-Fact 'Freed by cleanup' "$(Format-Size $script:FreedTotal) (measured gain on the system drive: $(Format-Size $realGain))"
    Add-Action 'Cleanup' 'Completed' "Freed: approx. $(Format-Size $script:FreedTotal); measured: $(Format-Size $realGain)."
    Write-Ok "Cleanup finished. Freed: approx. $(Format-Size $script:FreedTotal) (measured: $(Format-Size $realGain))."
}

# ----------------------------------------------------------------------------------------------
# 6. Integrity and repair
# ----------------------------------------------------------------------------------------------
function Get-LogTail {
    param([string]$Path, [int64]$FromOffset)
    try {
        $fs = New-Object IO.FileStream($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
        if ($FromOffset -lt $fs.Length) { [void]$fs.Seek($FromOffset, [IO.SeekOrigin]::Begin) }
        $sr = New-Object IO.StreamReader($fs)
        $t = $sr.ReadToEnd(); $sr.Close(); $fs.Close()
        return $t
    } catch { return '' }
}

function Invoke-Sfc {
    $cbs = "$env:WINDIR\Logs\CBS\CBS.log"
    $off = if (Test-Path $cbs) { (Get-Item $cbs).Length } else { 0 }
    Write-Info 'SFC checks all protected system files - this takes about 5-15 minutes ...'
    $sfcArg = if ($script:DryRun) { '/verifyonly' } else { '/scannow' }
    $r = Invoke-Native -File "$env:WINDIR\System32\sfc.exe" -Arguments @($sfcArg) -Quiet -TimeoutSec 5400
    $txt = $r.Output
    if ($r.PSObject.Properties.Name -contains 'TimedOut' -and $r.TimedOut) {
        return [pscustomobject]@{ State = 'timeout'; Files = @() }
    }
    $tail = if (Test-Path $cbs) { Get-LogTail -Path $cbs -FromOffset $off } else { '' }
    $srLines = @($tail -split "`r?`n" | Where-Object { $_ -match '\[SR\]' })
    $cannot = @($srLines | Where-Object { $_ -match 'Cannot repair' })
    $repaired = @($srLines | Where-Object { $_ -match 'Repairing corrupted file|Repair complete|Repaired file' })
    # The patterns also match the German console output (localized Windows).
    $cleanTxt = $txt -match 'keine Integrit.{1,3}tsverletzungen|did not find any integrity violations'
    $fixedTxt = $txt -match 'erfolgreich repariert|successfully repaired'
    $failTxt = $txt -match 'nicht reparieren|unable to fix'
    $opFail = $txt -match 'konnte den angeforderten Vorgang nicht|could not perform the requested operation'
    $state = 'unknown'
    if ($opFail) { $state = 'notrun' }
    elseif ($script:DryRun -and ($txt -match 'found integrity violations|Integrit.{1,3}tsverletzungen gefunden|hat Integrit') -and -not $cleanTxt) { $state = 'violations' }
    elseif ($cannot.Count -gt 0 -or $failTxt) { $state = 'unrepairable' }
    elseif ($repaired.Count -gt 0 -or $fixedTxt) { $state = 'repaired' }
    elseif ($cleanTxt -or ($srLines | Where-Object { $_ -match 'Verify complete' })) { $state = 'clean' }
    $names = @()
    foreach ($l in $cannot) { $m = [regex]::Match($l, '"([^"]+)"'); if ($m.Success) { $names += $m.Groups[1].Value } }
    return [pscustomobject]@{ State = $state; Files = ($names | Select-Object -Unique) }
}

function Invoke-DismImage {
    # Repair-WindowsImage in a background job with a time limit. Returns State / Error / HResult / TimedOut.
    param([ValidateSet('CheckHealth', 'ScanHealth', 'RestoreHealth')][string]$Mode, [int]$TimeoutSec = 3600)
    $r = Invoke-WithTimeout -TimeoutSec $TimeoutSec -ArgumentList @($Mode) -Body {
        param($m)
        try {
            switch ($m) {
                'CheckHealth'   { $x = Repair-WindowsImage -Online -CheckHealth -ErrorAction Stop }
                'ScanHealth'    { $x = Repair-WindowsImage -Online -ScanHealth -ErrorAction Stop }
                'RestoreHealth' { $x = Repair-WindowsImage -Online -RestoreHealth -ErrorAction Stop }
            }
            [pscustomobject]@{ State = "$($x.ImageHealthState)"; Error = $null; HResult = $null }
        } catch {
            [pscustomobject]@{ State = $null; Error = $_.Exception.Message; HResult = ('{0:X8}' -f [int]$_.Exception.HResult) }
        }
    }
    if (-not $r.Completed) { return [pscustomobject]@{ State = $null; Error = 'Timed out'; HResult = '00000000'; TimedOut = $true } }
    $o = @($r.Output | Where-Object { $_ -and $_.PSObject.Properties.Name -contains 'State' }) | Select-Object -Last 1
    if (-not $o) { return [pscustomobject]@{ State = $null; Error = $(if ($r.Error) { $r.Error } else { 'No result from DISM' }); HResult = '00000000'; TimedOut = $false } }
    $o | Add-Member -NotePropertyName TimedOut -NotePropertyValue $false -Force
    return $o
}

function Invoke-DismRestoreWithWsusFallback {
    # RestoreHealth needs Windows Update as the file source. If a WSUS policy is active, bypass it temporarily.
    $res = Invoke-DismImage -Mode RestoreHealth -TimeoutSec 3600
    if ($res.State -eq 'Healthy') { return $res }
    $au = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU'
    if ((Get-RegValue $au 'UseWUServer') -eq 1) {
        Write-Info 'An internal update server (WSUS) is configured - retrying DISM with Windows Update as source ...'
        try {
            Set-ItemProperty -Path $au -Name UseWUServer -Value 0 -Type DWord -ErrorAction Stop
            Restart-Service -Name wuauserv -Force -ErrorAction SilentlyContinue
            $res = Invoke-DismImage -Mode RestoreHealth -TimeoutSec 3600
        } finally {
            Set-ItemProperty -Path $au -Name UseWUServer -Value 1 -Type DWord -ErrorAction SilentlyContinue
            Restart-Service -Name wuauserv -Force -ErrorAction SilentlyContinue
        }
    }
    return $res
}

function Invoke-IntegrityChecks {
    Initialize-RestorePoint

    # 1. WMI repository
    Write-Info 'Checking the WMI repository ...'
    $w = Invoke-Native -File "$env:WINDIR\System32\wbem\winmgmt.exe" -Arguments @('/verifyrepository') -Quiet
    if ($w.Output -match '(?i)inconsistent|nicht konsistent|inkonsistent' -and $w.Output -notmatch '(?i)is consistent|ist konsistent') {
        Add-Finding -Id 'wmi-broken' -Severity 'High' -Category 'Integrity' -Title 'WMI repository is inconsistent' `
            -Meaning 'WMI is the database from which Windows and many programs query system information. If it is damaged, hardware info, diagnostic tools and sometimes updates fail.' `
            -Evidence $w.Output -Recommendation 'A repair will be attempted (winmgmt /salvagerepository).'
        if (Test-DryRun 'repair the WMI repository (winmgmt /salvagerepository)') { $w2 = [pscustomobject]@{ Output = 'DryRun: not repaired' } }
        else {
            $s = Invoke-Native -File "$env:WINDIR\System32\wbem\winmgmt.exe" -Arguments @('/salvagerepository') -Quiet
            $w2 = Invoke-Native -File "$env:WINDIR\System32\wbem\winmgmt.exe" -Arguments @('/verifyrepository') -Quiet
        }
        if ($w2.Output -match '(?i)is consistent|ist konsistent') { Set-FindingFixed -Id 'wmi-broken' -WhatWasDone 'The WMI repository was repaired with "winmgmt /salvagerepository" and is consistent again.'; Add-Action 'WMI repository' 'Fixed' 'Repository repaired.' }
        else { Add-Action 'WMI repository' 'Not fixed' $w2.Output }
    } else { Write-Ok 'WMI repository is consistent.'; Add-Action 'WMI repository' 'OK' 'Consistent.' }

    # 2. Component store (DISM): fast CheckHealth first, full ScanHealth only if needed/asked
    $dismRepaired = $false
    if ((Test-LongOperationAllowed 'DISM' -MinFreeGB 2) -and (Confirm-Step 'Check the component store for corruption (DISM CheckHealth + ScanHealth, approx. 5-10 minutes)?' -ReadOnly)) {
        Write-Info 'DISM is checking the component store ...'
        $quick = Invoke-DismImage -Mode CheckHealth -TimeoutSec 300
        if ($quick.State) { Write-Info "Quick check (CheckHealth): $($quick.State)" }
        $scan = if ($quick.State -eq 'Healthy' -and -not (Confirm-Step 'The quick check found no flag. Run the full (slow) ScanHealth anyway?' -Default $false -ReadOnly)) { $quick } else { Invoke-DismImage -Mode ScanHealth -TimeoutSec 2400 }
        if ($scan.TimedOut) {
            Write-Warn2 'DISM ScanHealth took too long and was stopped.'
            Add-Action 'DISM ScanHealth' 'Timeout' 'Stopped after the time limit.'
        } elseif ($scan.Error) {
            $hex = $scan.HResult
            Write-Warn2 "DISM error 0x$hex : $($scan.Error)"
            $info = Get-WuErrorInfo $hex
            Add-Finding -Id 'dism-error' -Severity 'Medium' -Category 'Integrity' -Title 'DISM could not check/repair the component store' `
                -Meaning "DISM is the repair tool for the component store. $($info.M)" -Evidence "0x$hex - $($scan.Error)" `
                -Recommendation "Restart and try again. Log: C:\Windows\Logs\DISM\dism.log. If that does not help, perform a repair upgrade with the Media Creation Tool."
        } else {
            $stateStr = $scan.State
            Write-Info "Component store state: $stateStr"
            if ($stateStr -eq 'Healthy') {
                Write-Ok 'Component store is fine.'
                Add-Action 'DISM ScanHealth' 'OK' 'No corruption found.'
            } elseif ($stateStr -eq 'Repairable') {
                Add-Finding -Id 'dism-broken' -Severity 'High' -Category 'Integrity' -Title 'The Windows component store is damaged (repairable)' `
                    -Meaning 'The component store (WinSxS) is the "spare parts depot" of Windows. Damage leads to failing updates, errors in Windows features and instability.' `
                    -Evidence "ImageHealthState: $stateStr" -Recommendation 'A repair will be attempted (DISM RestoreHealth).'
                if (-not $script:Online) { Write-Warn2 'The repair needs an internet connection (Windows Update as the source).' }
                elseif (Confirm-Step 'Repair now (DISM RestoreHealth, downloads files from Windows Update, approx. 10-30 minutes)?') {
                    $res = Invoke-DismRestoreWithWsusFallback
                    if ($res.State -eq 'Healthy') { Set-FindingFixed -Id 'dism-broken' -WhatWasDone 'The component store was successfully repaired with DISM /RestoreHealth.'; $dismRepaired = $true; Add-Action 'DISM RestoreHealth' 'Fixed' 'Component store repaired.' }
                    else { Add-Action 'DISM RestoreHealth' 'Not complete' "State afterwards: $($res.State) $($res.Error)" }
                }
            } else {
                Add-Finding -Id 'dism-irreparable' -Severity 'Critical' -Category 'Integrity' -Title 'The Windows component store is not repairable' `
                    -Meaning 'Windows can no longer repair its own system components by itself. Updates and system functions become increasingly unreliable.' `
                    -Evidence "ImageHealthState: $stateStr" `
                    -Recommendation "Recommended: 'repair upgrade' - start the setup file with the Windows 10 Media Creation Tool (microsoft.com/software-download/windows10) and choose 'Keep personal files and apps'. This reinstalls Windows 10 but keeps your data. Make a backup BEFOREHAND."
            }
        }
    }

    # 3. System files (SFC) - with a second pass after repair
    if ((Test-LongOperationAllowed 'SFC') -and (Confirm-Step 'Check and repair protected system files (SFC /scannow, approx. 5-15 minutes)?' -ReadOnly)) {
        $s = Invoke-Sfc
        switch ($s.State) {
            'violations' {
                Add-Finding -Id 'sfc-violations' -Severity 'High' -Category 'Integrity' -Title 'SFC finds corrupted system files (DryRun: not repaired)' `
                    -Meaning 'The read-only check found damaged Windows system files.' -Recommendation 'Run the script without -DryRun to repair them (DISM + SFC).'
            }
            'timeout' {
                Add-Finding -Id 'sfc-timeout' -Severity 'Low' -Category 'Integrity' -Title 'SFC took too long and was stopped' `
                    -Meaning 'The system file check did not finish within 90 minutes. This is unusual and often points to a very slow or failing disk.' `
                    -Recommendation 'Check disk health (SMART section of this report), restart and run the script again.'
            }
            'clean' { Write-Ok 'SFC: no integrity violations.'; Add-Action 'SFC' 'OK' 'No corrupted system files.' }
            'repaired' {
                Write-Ok 'SFC: corrupted system files found and repaired.'
                Add-Finding -Id 'sfc-repaired' -Severity 'Medium' -Category 'Integrity' -Title 'Corrupted system files were repaired' `
                    -Meaning 'SFC found modified or corrupted Windows system files and replaced them with originals. Corruption results from crashes, power outages, disk errors, faulty tuning tools or malware.' `
                    -Recommendation 'The script fixed this automatically. If such findings occur repeatedly, check disk health and RAM.' -Status 'Fixed'
                Add-Action 'SFC' 'Fixed' 'Corrupted system files repaired.'
            }
            'unrepairable' {
                Write-Warn2 'SFC could not repair some files - trying DISM repair and repeating SFC.'
                if (-not $dismRepaired -and $script:Online) {
                    $res = Invoke-DismRestoreWithWsusFallback
                    if ($res.State -eq 'Healthy') { $dismRepaired = $true } elseif ($res.Error) { Write-Warn2 $res.Error }
                }
                $s2 = Invoke-Sfc
                if ($s2.State -in 'clean', 'repaired') {
                    Write-Ok 'SFC: successful after DISM repair.'
                    Add-Finding -Id 'sfc-repaired' -Severity 'Medium' -Category 'Integrity' -Title 'Corrupted system files were repaired with DISM + SFC' `
                        -Meaning 'Some system files were corrupted and could not be repaired at first. After restoring the component store, the repair succeeded.' `
                        -Recommendation 'Done. A restart is recommended.' -Status 'Fixed'
                    Add-Action 'SFC' 'Fixed' 'Repair via DISM + SFC.'
                    Request-Reboot 'System file repair'
                } else {
                    Add-Finding -Id 'sfc-unrepairable' -Severity 'High' -Category 'Integrity' -Title 'SFC finds corrupted system files that cannot be repaired' `
                        -Meaning 'Windows system files are corrupted and the automatic repair failed. This shows up as crashes, failing updates or missing features.' `
                        -Evidence ("Affected files (excerpt): " + (($s2.Files | Select-Object -First 10) -join '; ')) `
                        -Recommendation "1) Restart, run the script again. 2) If that does not help: repair upgrade with the Windows 10 Media Creation Tool (option 'Keep personal files and apps'). Details: C:\Windows\Logs\CBS\CBS.log (search for '[SR]')."
                    Add-Action 'SFC' 'Not fixed' 'Unrepairable system files.'
                }
            }
            'notrun' {
                Add-Finding -Id 'sfc-not-run' -Severity 'Medium' -Category 'Integrity' -Title 'SFC could not be run' `
                    -Meaning 'The system file check was aborted by Windows - often because a restart is pending or the Windows Modules Installer (TrustedInstaller) does not start.' `
                    -Recommendation 'Restart Windows and run the script again.'
                Request-Reboot 'SFC could not run'
            }
            default {
                Write-Warn2 'The SFC result could not be read unambiguously.'
                Add-Finding -Id 'sfc-unclear' -Severity 'Low' -Category 'Integrity' -Title 'SFC result unclear' `
                    -Meaning 'The script could not derive a clear result from the console and the CBS log.' `
                    -Recommendation "Open the CBS log (C:\Windows\Logs\CBS\CBS.log) and search for '[SR]', or run 'sfc /verifyonly' manually."
            }
        }
    }

    # 4. File system (online) - all fixed NTFS volumes
    $fsVols = @()
    try { $fsVols = @(Get-Volume | Where-Object { $_.DriveLetter -and $_.DriveType -eq 'Fixed' -and $_.FileSystem -eq 'NTFS' }) } catch {}
    if ($fsVols.Count -gt 0 -and (Confirm-Step "Check the file system of $(($fsVols | ForEach-Object { "$($_.DriveLetter):" }) -join ', ') online for errors (Repair-Volume -Scan)?")) {
        foreach ($vol in $fsVols) {
            $dl = "$($vol.DriveLetter)"
            Write-Info "File system check running on ${dl}: ..."
            try {
                $rv = Repair-Volume -DriveLetter $dl -Scan -ErrorAction Stop
                Write-Info "Result: $rv"
                if ("$rv" -eq 'NoErrorsFound') { Write-Ok "File system ${dl}: is fine."; Add-Action 'File system check' 'OK' "Drive ${dl}: without errors." }
                else {
                    $fid = "fs-error-$dl"
                    Add-Finding -Id $fid -Severity 'High' -Category 'Integrity' -Title "File system errors found on drive ${dl}:" `
                        -Meaning 'NTFS management data is inconsistent (e.g. after a crash or power outage). Left untreated, files can be lost or Windows may no longer start.' `
                        -Evidence "Repair-Volume -Scan: $rv" -Recommendation 'Repair at the next restart (chkdsk /F).'
                    if (Confirm-Step "Schedule the repair for the next restart (chkdsk /F on ${dl}:)?" -Risky) {
                        $null = Invoke-Native -File "$env:WINDIR\System32\cmd.exe" -Arguments @('/c', "echo Y| chkdsk ${dl}: /F") -Quiet
                        Request-Reboot "Scheduled file system check (chkdsk ${dl}:)"
                        Add-Action 'File system check' 'Scheduled' "chkdsk /F on ${dl}: runs at the next restart."
                        ($script:Findings | Where-Object { $_.Id -eq $fid }).Recommendation = 'The repair (chkdsk /F) has been scheduled and runs at the next restart. Please restart and wait for the process to finish (may take a long time); then run the script again.'
                    }
                }
            } catch {
                Write-Warn2 "File system check on ${dl}: failed: $($_.Exception.Message)"
                Add-Action 'File system check' 'Error' $_.Exception.Message
            }
        }
    }

    # 5. Optional, targeted repairs (never in -Auto mode: they interrupt the network or reset user-visible state)
    $netTrouble = [bool]($script:Findings | Where-Object { $_.Id -in 'dns-error', 'offline', 'gateway-bad' })
    if ($netTrouble -and (Confirm-Step 'Network problems were found. Reset the network stack (Winsock + TCP/IP, needs a restart)?' -Default $false -Risky)) {
        Invoke-Native -File "$env:WINDIR\System32\netsh.exe" -Arguments @('winsock', 'reset') -Quiet | Out-Null
        Invoke-Native -File "$env:WINDIR\System32\netsh.exe" -Arguments @('int', 'ip', 'reset') -Quiet | Out-Null
        Invoke-Native -File "$env:WINDIR\System32\ipconfig.exe" -Arguments @('/flushdns') -Quiet | Out-Null
        Request-Reboot 'Network stack reset'
        Add-Action 'Network repair' 'Success' 'netsh winsock reset + int ip reset.'
    }
    if ($script:Findings | Where-Object { $_.Id -eq 'store-app-error' }) {
        if (Confirm-Step 'Reset the Microsoft Store cache (wsreset, does not delete apps)?' -Default $false -Risky) {
            Start-Process -FilePath "$env:WINDIR\System32\wsreset.exe" -WindowStyle Hidden -Wait -ErrorAction SilentlyContinue
            Add-Action 'Store repair' 'Success' 'wsreset executed.'
        }
    }
    if (Confirm-Step 'Rebuild the Explorer icon cache (fixes wrong/blank icons; Explorer restarts briefly)?' -Default $false -Risky) {
        Stop-Process -Name explorer -Force -ErrorAction SilentlyContinue
        Get-ChildItem "$env:LOCALAPPDATA\Microsoft\Windows\Explorer" -Filter 'iconcache_*.db' -Force -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue
        Remove-Item "$env:LOCALAPPDATA\IconCache.db" -Force -ErrorAction SilentlyContinue
        Start-Process explorer.exe
        Add-Action 'Shell repair' 'Success' 'Icon cache deleted, Explorer restarted.'
    }
}

# ----------------------------------------------------------------------------------------------
# 7. Windows Update with hard Windows 11 protection
# ----------------------------------------------------------------------------------------------
function Set-Win11Block {
    # Official method: set the "target feature update version" -> stays on Windows 10 22H2, Windows 11 is never offered.
    $pol = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate'
    if ($script:DryRun) {
        $cur = Get-ItemProperty $pol -ErrorAction SilentlyContinue
        $script:Win11BlockState = if ($cur -and $cur.TargetReleaseVersion -eq 1 -and $cur.ProductVersion -eq 'Windows 10') { "ACTIVE (target version $($cur.TargetReleaseVersionInfo))" } else { 'NOT SET (DryRun: not changed)' }
        Write-Info "[DryRun] Windows 11 block state: $script:Win11BlockState"
        Add-Fact 'Windows 11 block' $script:Win11BlockState
        return
    }
    try {
        if (-not (Test-Path $pol)) { New-Item -Path $pol -Force | Out-Null }
        $cur = Get-ItemProperty $pol -ErrorAction SilentlyContinue
        $prev = "TargetReleaseVersion=$($cur.TargetReleaseVersion); ProductVersion=$($cur.ProductVersion); TargetReleaseVersionInfo=$($cur.TargetReleaseVersionInfo)"
        Set-ItemProperty -Path $pol -Name TargetReleaseVersion -Value 1 -Type DWord -Force
        Set-ItemProperty -Path $pol -Name ProductVersion -Value 'Windows 10' -Type String -Force
        Set-ItemProperty -Path $pol -Name TargetReleaseVersionInfo -Value '22H2' -Type String -Force
        Set-ItemProperty -Path $pol -Name DisableOSUpgrade -Value 1 -Type DWord -Force
        $os2 = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\OSUpgrade'
        if (-not (Test-Path $os2)) { New-Item -Path $os2 -Force | Out-Null }
        Set-ItemProperty -Path $os2 -Name AllowOSUpgrade -Value 0 -Type DWord -Force
        $script:Win11BlockState = 'ACTIVE (policy target version = Windows 10 22H2 set)'
        Write-Ok 'Windows 11 block active: target version = Windows 10 22H2.'
        Add-Action 'Windows 11 block' 'Active' "Policy set. Previous state: $prev"
        Add-Fact 'Windows 11 block' $script:Win11BlockState
    } catch {
        $script:Win11BlockState = 'FAILED - only the script filter is active'
        Write-Warn2 "Policy could not be set: $($_.Exception.Message)"
        Add-Finding -Id 'win11-block-error' -Severity 'High' -Category 'Windows Update' -Title 'Windows 11 block could not be set permanently' `
            -Meaning 'The policy that permanently keeps Windows 11 out of Windows Update could not be written. This script never installs Windows 11 anyway; however, Windows Update itself might offer it later.' `
            -Evidence $_.Exception.Message -Recommendation 'Run as administrator and check for security software that blocks registry write access.'
    }
    # Is the Windows 11 installation assistant running?
    $assist = @(Get-Process -ErrorAction SilentlyContinue | Where-Object { $_.Name -match 'Windows11InstallationAssistant|Windows10UpgraderApp|Windows11Upgrade' })
    if ($assist.Count -gt 0) {
        Write-Warn2 'A Windows 11 installation assistant is running!'
        Add-Finding -Id 'win11-assistant' -Severity 'High' -Category 'Windows Update' -Title 'The Windows 11 installation assistant is running' `
            -Meaning 'This program would upgrade your system to Windows 11.' -Evidence (($assist | ForEach-Object { $_.Name }) -join ', ') -Recommendation 'Terminate the process.'
        if (Confirm-Step 'Terminate the installation assistant now?') {
            $assist | ForEach-Object { try { Stop-Process -Id $_.Id -Force -ErrorAction Stop } catch {} }
            Set-FindingFixed -Id 'win11-assistant' -WhatWasDone 'The installation assistant was terminated.'
        }
    }
}

function Get-UpdateKind($u) {
    $cats = @()
    try { $cats = @($u.Categories | ForEach-Object { $_.Name }) } catch {}
    $t = [string]$u.Title
    if ($t -match '(?i)windows\s*11' -or ($cats -contains 'Upgrades' -and $t -notmatch '(?i)windows\s*10')) { return 'Win11' }
    # Preview first: "Cumulative Update Preview for Windows 10 Version 22H2" must never count as a feature update.
    if ($t -match '(?i)preview|vorschau') { return 'Preview' }
    # Feature updates only: monthly cumulative updates also contain "Windows 10 Version 22H2" in their title.
    if ($t -match '(?i)^\s*(feature update|funktionsupdate)\b.*windows 10' -or ($cats -contains 'Upgrades' -and $t -match '(?i)windows 10')) { return 'Feature10' }
    return 'Normal'
}

function Repair-UpdateServices {
    foreach ($n in 'wuauserv', 'BITS', 'CryptSvc', 'UsoSvc') {
        $s = Get-CimInstance Win32_Service -Filter "Name='$n'" -ErrorAction SilentlyContinue
        if ($s -and $s.StartMode -eq 'Disabled' -and -not (Test-DryRun "set update service $n from Disabled to Manual")) {
            try { Set-Service -Name $n -StartupType Manual -ErrorAction Stop; Write-Ok "Service '$n' was disabled and has been set to 'Manual'."; Add-Action 'Update services' 'Fixed' "$n from Disabled to Manual." } catch {}
        }
    }
    $wuPol = Get-ItemProperty 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU' -ErrorAction SilentlyContinue
    $wsus = Get-ItemProperty 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate' -ErrorAction SilentlyContinue
    if ($wsus -and $wsus.WUServer) {
        Add-Finding -Id 'wsus' -Severity 'Info' -Category 'Windows Update' -Title 'Updates come from an internal WSUS server' `
            -Meaning 'A policy redirects Windows Update to a company server. Available updates then depend on what IT approves.' -Evidence "WUServer: $($wsus.WUServer)" -Status 'Info'
    }
    if ($wuPol -and $wuPol.NoAutoUpdate -eq 1) {
        Add-Finding -Id 'au-off' -Severity 'High' -Category 'Windows Update' -Title 'Automatic updates are turned off by policy' `
            -Meaning 'Windows does not install updates by itself - security holes stay open until someone searches manually.' `
            -Recommendation "If this is not intended: gpedit.msc > Computer Configuration > Administrative Templates > Windows Components > Windows Update > set 'Configure Automatic Updates' to 'Not configured'."
    }
}

function Reset-WindowsUpdateComponents {
    if (Test-DryRun 'reset the Windows Update components') { return }
    Write-Info 'Resetting Windows Update components (stop services, rename cache, start services) ...'
    foreach ($s in 'wuauserv', 'bits', 'cryptsvc', 'msiserver', 'usosvc') { Stop-Service -Name $s -Force -ErrorAction SilentlyContinue }
    Start-Sleep -Seconds 3
    # Clear the BITS job queue (stuck download jobs are a classic cause of "downloading 0%")
    Get-ChildItem "$env:ALLUSERSPROFILE\Microsoft\Network\Downloader" -Filter 'qmgr*.dat' -Force -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue
    $st = Get-Date -Format 'yyyyMMdd_HHmmss'
    foreach ($p in @("$env:WINDIR\SoftwareDistribution", "$env:WINDIR\System32\catroot2")) {
        if (Test-Path -LiteralPath $p) {
            try { Rename-Item -LiteralPath $p -NewName ("{0}.bak_{1}" -f (Split-Path $p -Leaf), $st) -ErrorAction Stop } catch { Write-Warn2 "Could not rename ${p}: $($_.Exception.Message)" }
        }
    }
    foreach ($s in 'cryptsvc', 'bits', 'wuauserv', 'usosvc') {
        try { if ((Get-Service $s -ErrorAction Stop).StartType -ne 'Disabled') { Start-Service -Name $s -ErrorAction SilentlyContinue } } catch {}
    }
    Add-Action 'Windows Update' 'Components reset' 'SoftwareDistribution and catroot2 were recreated (old folders saved as .bak_*, cleaned up automatically after 7 days).'
    Write-Ok 'Update components reset.'
}

function Invoke-WindowsUpdateModule {
    param([int]$Attempt = 1)
    Initialize-RestorePoint
    Set-Win11Block
    Repair-UpdateServices
    if (-not $script:Online) { Write-Bad 'No internet connection - Windows Update skipped.'; Add-Action 'Windows Update' 'Skipped' 'No internet connection.'; return }

    # State: last successfully installed update
    try {
        $hf = Get-HotFix -ErrorAction SilentlyContinue | Where-Object { $_.InstalledOn } | Sort-Object InstalledOn -Descending | Select-Object -First 1
        if ($hf) {
            Add-Fact 'Last installed update' "$($hf.HotFixID) on $($hf.InstalledOn.ToString('yyyy-MM-dd'))"
            $age = ((Get-Date) - $hf.InstalledOn).Days
            if ($age -gt 60) {
                Add-Finding -Id 'updates-old' -Severity 'High' -Category 'Windows Update' -Title "The last Windows update is $age days old" `
                    -Meaning 'Microsoft publishes security updates monthly. If several are missing, known vulnerabilities are open on this PC.' -Evidence "Last update: $($hf.HotFixID) from $($hf.InstalledOn.ToString('yyyy-MM-dd'))" `
                    -Recommendation 'Install updates now (this module) and pay attention to the error report if errors occur.'
            }
        }
    } catch {}

    $session = New-Object -ComObject Microsoft.Update.Session
    $session.ClientApplicationID = 'Windows10-SystemMaintenance'
    $searcher = $session.CreateUpdateSearcher()

    # Microsoft Update: also deliver updates for Office and other Microsoft products (skipped when WSUS is in charge)
    $muId = '7971f918-a847-4430-9279-4a52d1efe18d'
    try {
        $wsusPol = Get-RegValue 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate' 'WUServer'
        if (-not $wsusPol) {
            $sm = New-Object -ComObject Microsoft.Update.ServiceManager
            $hasMu = @($sm.Services | Where-Object { $_.ServiceID -eq $muId }).Count -gt 0
            if (-not $hasMu -and (Confirm-Step 'Also receive updates for Office and other Microsoft products (register Microsoft Update)?')) {
                [void]$sm.AddService2($muId, 7, '')
                $hasMu = $true
                Add-Action 'Windows Update' 'Configured' 'Microsoft Update service registered.'
            }
            if ($hasMu) { $searcher.ServerSelection = 3; $searcher.ServiceID = $muId }
        }
    } catch { Write-Info "Microsoft Update could not be registered: $($_.Exception.Message)" }

    if (Test-MeteredConnection) { Write-Warn2 'The connection is metered - Windows may postpone downloads (see network section).' }

    # Evaluate earlier update errors
    try {
        $cnt = $searcher.GetTotalHistoryCount()
        if ($cnt -gt 0) {
            $hist = $searcher.QueryHistory(0, [math]::Min($cnt, 60))
            $failed = @()
            for ($i = 0; $i -lt $hist.Count; $i++) {
                $h = $hist.Item($i)
                if ($h.ResultCode -eq 4 -and $h.Date -gt (Get-Date).AddDays(-30)) { $failed += [pscustomobject]@{ Title = $h.Title; Date = $h.Date; Code = ('{0:X8}' -f [int]$h.HResult) } }
            }
            if ($failed.Count -gt 0) {
                $codes = $failed | Group-Object Code
                $ev = @()
                foreach ($c in $codes) { $inf = Get-WuErrorInfo $c.Name; $ev += "0x$($c.Name) ($($c.Count)x): $($inf.M)" }
                Add-Finding -Id 'update-history-error' -Severity 'Medium' -Category 'Windows Update' -Title "$($failed.Count) failed update installation(s) in the last 30 days" `
                    -Meaning 'Earlier update installations failed. The error codes reveal the cause; the evaluation is below.' -Evidence ($ev -join "`n") `
                    -Recommendation 'The script now tries the updates again and resets the update components if necessary.'
            }
        }
    } catch {}

    # Windows 11 leftovers
    foreach ($p in @("$env:SystemDrive\`$WINDOWS.~BT", "$env:SystemDrive\`$WINDOWS.~WS")) {
        if (Test-Path -LiteralPath $p -ErrorAction SilentlyContinue) { Write-Warn2 "Upgrade preparation folder found: $p (see Cleanup)" }
    }

    Write-Info 'Searching for updates (may take a few minutes) ...'
    $result = $null
    try {
        # Asynchronous search so a hung Windows Update service cannot block the script forever (20 minute limit).
        $async = $searcher.BeginSearch("IsInstalled=0 and IsHidden=0 and Type='Software'", $null, $null)
        $sw = [Diagnostics.Stopwatch]::StartNew()
        while (-not $async.IsCompleted) {
            if ($sw.Elapsed.TotalMinutes -gt 20) { throw 'The update search did not finish within 20 minutes.' }
            Start-Sleep -Seconds 2
        }
        $result = $searcher.EndSearch($async)
    }
    catch {
        $hex = Get-HResultHex $_.Exception
        $inf = Get-WuErrorInfo $hex
        Write-Bad "Update search failed (0x$hex): $($inf.M)"
        if ($Attempt -eq 1 -and ($inf.Reset -or $hex -in '80070422', '8024402C', '80244022', '80072EE2')) {
            if (Confirm-Step 'Reset the update components now and try the search again? (The displayed update history will be cleared; installed updates remain.)') {
                Reset-WindowsUpdateComponents
                Invoke-WindowsUpdateModule -Attempt 2
                return
            }
        }
        Add-Finding -Id 'update-search' -Severity 'High' -Category 'Windows Update' -Title 'The search for Windows updates failed' `
            -Meaning $inf.M -Evidence "Error code 0x$hex - $($_.Exception.Message)" -Recommendation $inf.F
        Add-Action 'Windows Update' 'Error' "Search: 0x$hex"
        return
    }

    $normal = @(); $feature = @(); $preview = @(); $blocked = @()
    for ($i = 0; $i -lt $result.Updates.Count; $i++) {
        $u = $result.Updates.Item($i)
        switch (Get-UpdateKind $u) {
            'Win11' { $blocked += $u }
            'Feature10' { $feature += $u }
            'Preview' { $preview += $u }
            default { $normal += $u }
        }
    }
    # Hide and hold back Windows 11 offers
    foreach ($u in $blocked) {
        if (-not $script:DryRun) { try { $u.IsHidden = $true } catch {} }
        Write-Warn2 "Windows 11 offer detected and BLOCKED: $($u.Title)"
    }
    if ($blocked.Count -gt 0) {
        Add-Action 'Windows 11 block' 'Offer blocked' (($blocked | ForEach-Object { $_.Title }) -join '; ')
        Add-Fact 'Blocked Windows 11 offers' (($blocked | ForEach-Object { $_.Title }) -join '; ')
    }
    # Only count drivers
    $drvCount = 0
    try { $drvCount = $searcher.Search("IsInstalled=0 and IsHidden=0 and Type='Driver'").Updates.Count } catch {}

    Write-Info ("Found: {0} updates, {1} Windows 10 feature update(s), {2} optional preview update(s), {3} Windows 11 offer(s) (blocked), {4} drivers (notice only)." -f $normal.Count, $feature.Count, $preview.Count, $blocked.Count, $drvCount)
    if ($drvCount -gt 0) {
        Add-Finding -Id 'driver-updates' -Severity 'Info' -Category 'Windows Update' -Title "$drvCount optional driver update(s) available through Windows Update" `
            -Meaning 'Windows Update offers drivers that the script deliberately does not install automatically, because wrong drivers can cause problems.' `
            -Recommendation 'Settings > Update & Security > Windows Update > "View optional updates" and select individual drivers only if needed. It is better to download graphics drivers directly from the manufacturer.' -Status 'Info'
    }
    if ($preview.Count -gt 0) {
        Add-Finding -Id 'preview-updates' -Severity 'Info' -Category 'Windows Update' -Title "$($preview.Count) optional preview update(s) not installed" `
            -Meaning 'Preview updates (Optional/Preview) are test versions of the next monthly updates and contain bug fixes that are not yet mature. They are not needed for security.' `
            -Evidence (($preview | ForEach-Object { $_.Title }) -join "`n") -Recommendation 'Normally do not install; the contents arrive on the next regular Patch Tuesday.' -Status 'Info'
    }

    $toInstall = New-Object System.Collections.ArrayList
    if (-not (Test-LongOperationAllowed 'Windows Update installation' -MinFreeGB 5)) {
        if (($normal.Count + $feature.Count) -gt 0) {
            Add-Finding -Id 'updates-deferred' -Severity 'Low' -Category 'Windows Update' -Title "$($normal.Count + $feature.Count) update(s) are waiting but were not installed" `
                -Meaning 'Installing was skipped because the PC is on battery power or the system drive is nearly full.' `
                -Recommendation 'Plug in the PC / free up space and run the script again.'
        }
        return
    }
    if ($normal.Count -gt 0) {
        Write-Host ''
        Write-Host '  The following updates are ready to install:' -ForegroundColor Cyan
        $n = 0
        foreach ($u in $normal) { $n++; Write-Host ("   {0,2}. {1}  [{2}]" -f $n, $u.Title, (Format-Size $u.MaxDownloadSize)) }
        if (Confirm-Step 'Download and install these updates now?') { foreach ($u in $normal) { [void]$toInstall.Add($u) } }
    }
    if ($feature.Count -gt 0) {
        Write-Host ''
        Write-Host '  Windows 10 feature update (stays Windows 10, NOT Windows 11):' -ForegroundColor Cyan
        foreach ($u in $feature) { Write-Host ("   - {0}  [{1}]" -f $u.Title, (Format-Size $u.MaxDownloadSize)) }
        if (Confirm-Step 'Install the Windows 10 feature update as well? (Takes longer, requires a restart)' -Risky) { foreach ($u in $feature) { [void]$toInstall.Add($u) } }
    }
    if ($toInstall.Count -eq 0) {
        Write-Ok 'No updates to install.'
        Add-Action 'Windows Update' 'Up to date' "No installation needed. Blocked Windows 11 offers: $($blocked.Count)."
        return
    }

    # Last safety barrier: never Windows 11
    $safeList = New-Object System.Collections.ArrayList
    foreach ($u in $toInstall) { if ((Get-UpdateKind $u) -ne 'Win11' -and $u.Title -notmatch '(?i)windows\s*11') { [void]$safeList.Add($u) } }

    try {
        $coll = New-Object -ComObject Microsoft.Update.UpdateColl
        foreach ($u in $safeList) { try { if (-not $u.EulaAccepted) { $u.AcceptEula() }; [void]$coll.Add($u) } catch {} }
        Write-Info "Downloading $($coll.Count) update(s) ..."
        $dl = $session.CreateUpdateDownloader(); $dl.Updates = $coll
        $dlr = $dl.Download()
        $inst = New-Object -ComObject Microsoft.Update.UpdateColl
        foreach ($u in $safeList) { if ($u.IsDownloaded) { [void]$inst.Add($u) } }
        if ($inst.Count -eq 0) { throw "Download failed (ResultCode $($dlr.ResultCode))." }
        Write-Info "Installing $($inst.Count) update(s) - please do not switch off ..."
        $installer = $session.CreateUpdateInstaller(); $installer.Updates = $inst; $installer.AllowSourcePrompts = $false
        $ir = $installer.Install()
        $okN = 0; $failRows = @(); $needReset = $false
        for ($i = 0; $i -lt $inst.Count; $i++) {
            $ur = $ir.GetUpdateResult($i); $title = $inst.Item($i).Title
            if ($ur.ResultCode -in 2, 3) { $okN++; Write-Ok $title }
            else {
                $hex = '{0:X8}' -f [int]$ur.HResult; $inf = Get-WuErrorInfo $hex
                if ($inf.Reset) { $needReset = $true }
                $failRows += "$title -> 0x$hex : $($inf.M) Solution: $($inf.F)"
                Write-Bad "$title (0x$hex)"
            }
        }
        Add-Action 'Windows Update' $(if ($failRows.Count -eq 0) { 'Success' } else { 'Partial' }) "$okN of $($inst.Count) update(s) installed."
        Add-Fact 'Windows updates this run' "$okN of $($inst.Count) installed"
        if ($ir.RebootRequired) { Request-Reboot 'Windows updates installed'; Write-Warn2 'A restart is required to finish.' }
        if ($failRows.Count -gt 0) {
            if ($needReset -and $Attempt -eq 1 -and (Confirm-Step 'Some updates failed because of a corrupted update cache. Reset the components and try again?')) {
                Reset-WindowsUpdateComponents
                Invoke-WindowsUpdateModule -Attempt 2
                return
            }
            Add-Finding -Id 'update-install-error' -Severity 'High' -Category 'Windows Update' -Title "$($failRows.Count) update(s) could not be installed" `
                -Meaning 'At least one update failed. The cause for each update is listed here.' -Evidence ($failRows -join "`n") `
                -Recommendation 'Restart and run the script again. If the error persists, follow the stated solution for each update; for component store errors run the Integrity module.'
        } else { Set-FindingFixed -Id 'update-history-error' -WhatWasDone 'The updates were installed successfully now.' }
    } catch {
        $hex = Get-HResultHex $_.Exception; $inf = Get-WuErrorInfo $hex
        Write-Bad "Update installation failed: $($_.Exception.Message)"
        Add-Finding -Id 'update-install-error' -Severity 'High' -Category 'Windows Update' -Title 'The installation of Windows updates failed' `
            -Meaning $inf.M -Evidence "0x$hex - $($_.Exception.Message)" -Recommendation $inf.F
        Add-Action 'Windows Update' 'Error' "0x$hex"
    }
    $pend = Test-PendingReboot
    if ($pend.Count -gt 0) { Request-Reboot 'Pending updates/maintenance' }
}

# ----------------------------------------------------------------------------------------------
# 8. Microsoft Store / app updates
# ----------------------------------------------------------------------------------------------
function Invoke-StoreModule {
    $store = Get-AppxPackage -Name Microsoft.WindowsStore -ErrorAction SilentlyContinue
    if (-not $store) {
        Add-Finding -Id 'store-missing' -Severity 'Info' -Category 'Apps' -Title 'The Microsoft Store is not installed' `
            -Meaning 'Some editions (e.g. LTSC) have no Store, or it was removed. In that case there are no Store app updates either.' `
            -Recommendation "If it should be there: PowerShell (admin) 'Get-AppxPackage -AllUsers Microsoft.WindowsStore | ForEach-Object { Add-AppxPackage -DisableDevelopmentMode -Register `"`$(`$_.InstallLocation)\AppxManifest.xml`" }'." -Status 'Info'
        return
    }
    if (-not $script:Online) { Write-Bad 'No internet connection - Store updates skipped.'; Add-Action 'Store updates' 'Skipped' 'No internet connection.'; return }
    $done = $false

    # 1. winget (supported, silent, with progress output)
    $winget = Get-Command winget -ErrorAction SilentlyContinue
    if ($winget) {
        if (Confirm-Step 'Update Microsoft Store apps via winget now?') {
            Write-Info 'winget is updating the Store apps ... (may take a few minutes)'
            $r = Invoke-Native -File $winget.Source -Arguments @('upgrade', '--all', '--source', 'msstore', '--silent', '--accept-package-agreements', '--accept-source-agreements', '--disable-interactivity') -Quiet
            $lines = $r.Output -split "`n" | Where-Object { $_ -and $_ -notmatch '^[\s\\|/\-]*$' -and $_ -notmatch '[█▒]' }
            $lines | Select-Object -First 25 | ForEach-Object { Write-Host "       $_" -ForegroundColor DarkGray }
            # The patterns also match the German winget output (localized Windows).
            $okCount = @($lines | Where-Object { $_ -match 'Successfully installed|Erfolgreich installiert' }).Count
            $failCount = @($lines | Where-Object { $_ -match 'Installer failed|Installationsprogramm.*fehlgeschlagen|install failed|Installation failed' }).Count
            Add-Action 'Store updates (winget)' $(if ($r.ExitCode -eq 0) { 'Success' } else { 'Note' }) "Return code $($r.ExitCode); installed: $okCount; errors: $failCount."
            if ($r.ExitCode -eq 0 -or $okCount -gt 0) { $done = $true }
            if ($failCount -gt 0) {
                Add-Finding -Id 'store-app-error' -Severity 'Low' -Category 'Apps' -Title "$failCount Store app(s) could not be updated" `
                    -Meaning 'An app could not be updated, e.g. because it is currently running or the Store cache is corrupted.' `
                    -Recommendation 'Close the apps and run again; if that does not help, open "Downloads and updates" in the Store or run "wsreset.exe" (only resets the Store cache).'
            }
        }
        # Third-party desktop apps (Git, 7-Zip, VLC, ...) from the winget community repository
        $pending = (Invoke-Native -File $winget.Source -Arguments @('upgrade', '--source', 'winget', '--accept-source-agreements', '--disable-interactivity') -Quiet -TimeoutSec 300).Output
        $m = [regex]::Match($pending, '(\d+)\s+(upgrades? available|Aktualisierungen verf)')
        if ($m.Success -and [int]$m.Groups[1].Value -gt 0) {
            Write-Info "$($m.Groups[1].Value) desktop app update(s) are available through winget."
            Add-Fact 'Desktop apps with updates (winget)' $m.Groups[1].Value
            if (Confirm-Step "Update these $($m.Groups[1].Value) desktop apps via winget as well? (Apps in use may be closed or skipped)" -Default $false -Risky) {
                $r2 = Invoke-Native -File $winget.Source -Arguments @('upgrade', '--all', '--source', 'winget', '--silent', '--accept-package-agreements', '--accept-source-agreements', '--disable-interactivity') -Quiet -TimeoutSec 3600
                Add-Action 'App updates (winget)' $(if ($r2.ExitCode -eq 0) { 'Success' } else { 'Note' }) "Return code $($r2.ExitCode)."
            } else {
                Add-Finding -Id 'winget-desktop-updates' -Severity 'Info' -Category 'Apps' -Title "$($m.Groups[1].Value) desktop app(s) can be updated via winget" `
                    -Meaning 'Outdated browsers, archivers and media players are a common way for malware to get in.' `
                    -Recommendation "Run 'winget upgrade' in a terminal to list them, then 'winget upgrade --all' to update." -Status 'Info'
            }
        }
    } else {
        Write-Info 'winget (App Installer) is not installed - Store updates run via the Store background scan.'
    }

    # 2. Trigger the Store background update scan
    try {
        $inst = Get-CimInstance -Namespace 'root\cimv2\mdm\dmmap' -ClassName 'MDM_EnterpriseModernAppManagement_AppManagement01' -ErrorAction Stop
        Invoke-CimMethod -InputObject $inst -MethodName UpdateScanMethod -ErrorAction Stop | Out-Null
        Write-Ok 'Store background scan triggered (updates are downloaded in the background).'
        Add-Action 'Store updates' 'Triggered' 'UpdateScanMethod triggered.'
        $done = $true
    } catch { Write-Info 'The Store background scan is not available on this system.' }

    # 3. Open the Store page for verification
    Add-Finding -Id 'store-check' -Severity 'Info' -Category 'Apps' -Title 'Please check the Store updates once in the Store' `
        -Meaning 'There is no official interface with which a script can reliably confirm that all Store apps are really up to date.' `
        -Recommendation "Open Microsoft Store > 'Library' (or 'Downloads and updates') > 'Get updates'." -Status 'Info'
    if (-not $done -or (Confirm-Step 'Open the Microsoft Store on the update page now to check the result and click "Get updates" if needed?' -Default $false)) {
        try { Start-Process 'ms-windows-store://downloadsandupdates'; Add-Action 'Store updates' 'Store opened' 'Update page was opened.' } catch { Write-Warn2 'The Store could not be opened.' }
    }
}

# ----------------------------------------------------------------------------------------------
# 9. Optimizations
# ----------------------------------------------------------------------------------------------
function Invoke-Optimizations {
    Initialize-RestorePoint

    # Disks: TRIM for SSD, defrag only for HDD
    try {
        $vols = Get-Volume | Where-Object { $_.DriveLetter -and $_.DriveType -eq 'Fixed' -and $_.FileSystem -eq 'NTFS' }
        foreach ($v in $vols) {
            $media = 'Unspecified'
            try { $media = "$((Get-Partition -DriveLetter $v.DriveLetter | Get-Disk | Get-PhysicalDisk).MediaType)" } catch {}
            if ($media -eq 'SSD') {
                if (Confirm-Step "Run TRIM on SSD $($v.DriveLetter): (returns free blocks to the SSD, safe and fast)?") {
                    try { Optimize-Volume -DriveLetter $v.DriveLetter -ReTrim -ErrorAction Stop; Write-Ok "TRIM on $($v.DriveLetter): completed."; Add-Action 'Optimization' 'Success' "TRIM on $($v.DriveLetter):" } catch { Write-Warn2 $_.Exception.Message }
                }
            } elseif ($media -eq 'HDD') {
                if ((Test-LongOperationAllowed 'Defragmentation') -and (Confirm-Step "Defragment hard disk $($v.DriveLetter): (may take a while)?")) {
                    try { Optimize-Volume -DriveLetter $v.DriveLetter -Defrag -ErrorAction Stop; Write-Ok "Defragmentation on $($v.DriveLetter): completed."; Add-Action 'Optimization' 'Success' "Defragmentation on $($v.DriveLetter):" } catch { Write-Warn2 $_.Exception.Message }
                }
            } else { Write-Info "Drive $($v.DriveLetter): type '$media' - no optimization performed." }
        }
    } catch {}

    # Defender signatures / quick scan
    try {
        $thirdAV = $null
        try { $thirdAV = Get-CimInstance -Namespace root\SecurityCenter2 -ClassName AntiVirusProduct -ErrorAction Stop | Where-Object { $_.displayName -notmatch 'Defender' } } catch {}
        if (-not $thirdAV -and $script:Online -and -not (Test-DryRun 'update Defender signatures')) {
            Write-Info 'Updating Defender virus signatures ...'
            try {
                Update-MpSignature -ErrorAction Stop
                Write-Ok 'Signatures updated.'
                Add-Action 'Defender' 'Success' 'Signatures updated.'
                Set-FindingFixed -Id 'defender-sig' -WhatWasDone 'The Defender virus signatures were updated.'
            } catch { Write-Warn2 "Signature update failed: $($_.Exception.Message)" }
            if (Confirm-Step 'Start a Defender quick scan (approx. 5-15 minutes)?' -Default $false) {
                try { Start-MpScan -ScanType QuickScan -ErrorAction Stop; Write-Ok 'Quick scan completed.'; Add-Action 'Defender' 'Success' 'Quick scan performed.'; Set-FindingFixed -Id 'defender-scan-old' -WhatWasDone 'A quick scan was performed.' } catch { Write-Warn2 $_.Exception.Message }
            }
        }
    } catch {}

    # System time
    try {
        $w32 = Get-Service W32Time -ErrorAction Stop
        if (-not $script:DryRun) {
            if ($w32.Status -ne 'Running') { Start-Service W32Time -ErrorAction SilentlyContinue }
            if ($script:Online) {
                $t = Invoke-Native -File "$env:WINDIR\System32\w32tm.exe" -Arguments @('/resync', '/force') -Quiet
                if ($t.ExitCode -ne 0) {
                    # Default time.windows.com sometimes fails: fall back to a public pool and retry once.
                    Invoke-Native -File "$env:WINDIR\System32\w32tm.exe" -Arguments @('/config', '/manualpeerlist:time.windows.com,0x9 pool.ntp.org,0x9', '/syncfromflags:manual', '/update') -Quiet | Out-Null
                    $t = Invoke-Native -File "$env:WINDIR\System32\w32tm.exe" -Arguments @('/resync', '/force') -Quiet
                }
                if ($t.ExitCode -eq 0) { Write-Ok 'System time synchronized.'; Add-Action 'Optimization' 'Success' 'Time synchronized (w32tm /resync).' }
            }
        }
    } catch {}

    # DNS cache
    if (-not (Test-DryRun 'flush the DNS cache')) {
        Invoke-Native -File "$env:WINDIR\System32\ipconfig.exe" -Arguments @('/flushdns') -Quiet | Out-Null
        Add-Action 'Optimization' 'Success' 'DNS cache flushed.'
    }

    # Manage the page file automatically
    try {
        $cs = Get-CimInstance Win32_ComputerSystem
        if (-not $cs.AutomaticManagedPagefile) {
            Add-Finding -Id 'pagefile-manual' -Severity 'Low' -Category 'Performance' -Title 'The page file is not managed automatically' `
                -Meaning 'A fixed page file that is set too small can lead to memory errors and crashes; otherwise Windows can adjust the size optimally by itself.' `
                -Recommendation 'Enable automatic management (System Properties > Advanced > Performance > Settings > Advanced > Virtual memory).'
            if (Confirm-Step 'Turn on automatic management of the page file (recommended, restart required)?') {
                try { Set-CimInstance -InputObject $cs -Property @{ AutomaticManagedPagefile = $true } -ErrorAction Stop; Set-FindingFixed -Id 'pagefile-manual' -WhatWasDone 'Automatic management of the page file was turned on (effective after a restart).'; Request-Reboot 'Page file' } catch { Write-Warn2 $_.Exception.Message }
            }
        }
    } catch {}

    # System Restore
    try {
        $rp = Get-ComputerRestorePoint -ErrorAction SilentlyContinue | Sort-Object CreationTime -Descending | Select-Object -First 1
        if ($rp) { Add-Fact 'Last restore point' ([Management.ManagementDateTimeConverter]::ToDateTime($rp.CreationTime).ToString('yyyy-MM-dd HH:mm') + " - $($rp.Description)") }
    } catch {}

    # Power plan, Fast Startup, autostart (information only)
    try {
        $plan = (Invoke-Native -File "$env:WINDIR\System32\powercfg.exe" -Arguments @('/getactivescheme') -Quiet).Output
        $planName = ($plan -replace '^.*:\s*[0-9a-f-]+\s*', '')
        Add-Fact 'Power plan' $planName
        if ($planName -match '(?i)power saver|energiesparmodus' -and -not (Get-CimInstance Win32_Battery -ErrorAction SilentlyContinue)) {
            Add-Finding -Id 'powerplan-saver' -Severity 'Low' -Category 'Performance' -Title 'A desktop PC runs on the "Power saver" plan' `
                -Meaning 'Power saver limits the CPU speed. On a desktop this just makes the PC slower without saving noticeable energy.' `
                -Recommendation "Control Panel > Power Options > choose 'Balanced'."
            if (Confirm-Step 'Switch to the Balanced power plan now?') {
                Invoke-Native -File "$env:WINDIR\System32\powercfg.exe" -Arguments @('/setactive', '381b4222-f694-41f0-9685-ff5bb260df2e') -Quiet | Out-Null
                Set-FindingFixed -Id 'powerplan-saver' -WhatWasDone 'Switched to the Balanced power plan.'
            }
        }
    } catch {}
    $fs = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power' -ErrorAction SilentlyContinue).HiberbootEnabled
    if ($fs -eq 1) {
        Add-Finding -Id 'fast-startup' -Severity 'Info' -Category 'Performance' -Title 'Fast Startup is turned on' `
            -Meaning "Fast Startup saves the system state on 'Shut down' and therefore starts faster. Downside: there is no real restart, driver and update problems survive the 'Shut down'." `
            -Recommendation "The script does not change this. For strange errors use 'Restart' instead of 'Shut down' or turn off Fast Startup under Control Panel > Power Options > 'Choose what the power buttons do'." -Status 'Info'
    }
    try {
        $startup = @(Get-CimInstance Win32_StartupCommand -ErrorAction Stop)
        $rows = $startup | Sort-Object Name | ForEach-Object { [pscustomobject]@{ Name = $_.Name; Command = ([string]$_.Command).Substring(0, [math]::Min(80, ([string]$_.Command).Length)); Location = $_.Location } }
        $script:Tables['Startup programs'] = @($rows)
        Add-Fact 'Startup entries' "$($startup.Count)"
        if ($startup.Count -gt 12) {
            Add-Finding -Id 'startup-many' -Severity 'Low' -Category 'Performance' -Title "$($startup.Count) programs start automatically with Windows" `
                -Meaning 'Every startup program prolongs system start and occupies memory. Many of them (updaters, helper programs, launchers) are not needed all the time.' `
                -Recommendation 'Task Manager (Ctrl+Shift+Esc) > "Startup" tab: set programs with "High impact" that you do not need all the time to "Disabled". The script deliberately does not do this itself, because only you know what you need. The list is in the appendix of the report.' -Status 'Open'
        }
    } catch {}
    Add-Action 'Optimizations' 'Completed' 'Checked TRIM/defrag, Defender, time, DNS, page file, startup.'
}

# ----------------------------------------------------------------------------------------------
# 10. Markdown report
# ----------------------------------------------------------------------------------------------
function Format-MdText([string]$s) {
    if ($null -eq $s) { return '' }
    return ($s -replace '\|', '\|' -replace '\r?\n', ' ')
}
function ConvertTo-MdTable {
    param($Rows)
    $Rows = @($Rows)
    if ($Rows.Count -eq 0) { return @('_No entries._') }
    $props = $Rows[0].PSObject.Properties.Name
    $out = New-Object System.Collections.Generic.List[string]
    $out.Add('| ' + ($props -join ' | ') + ' |')
    $out.Add('|' + (($props | ForEach-Object { '---' }) -join '|') + '|')
    foreach ($r in $Rows) { $out.Add('| ' + (($props | ForEach-Object { Format-MdText ([string]$r.$_) }) -join ' | ') + ' |') }
    return $out
}

function New-MarkdownReport {
    $dur = [math]::Round(((Get-Date) - $script:StartedAt).TotalMinutes, 1)
    $L = New-Object System.Collections.Generic.List[string]
    $icon = @{ 'Critical' = '🔴'; 'High' = '🟠'; 'Medium' = '🟡'; 'Low' = '🔵'; 'Info' = '⚪' }
    $open = @($script:Findings | Where-Object { $_.Status -eq 'Open' } | Sort-Object { $script:SevRank[$_.Severity] }, Category)
    $fixed = @($script:Findings | Where-Object { $_.Status -eq 'Fixed' } | Sort-Object { $script:SevRank[$_.Severity] })
    $info = @($script:Findings | Where-Object { $_.Status -eq 'Info' } | Sort-Object Category)

    $worst = 'Info'
    foreach ($f in $open) { if ($script:SevRank[$f.Severity] -lt $script:SevRank[$worst]) { $worst = $f.Severity } }
    $verdict = switch ($worst) {
        'Critical' { '🔴 **Urgent action required** - there are critical findings (e.g. impending data loss or an active threat).' }
        'High'     { '🟠 **Action required** - there are important open problems that you should address soon.' }
        'Medium'   { '🟡 **Mostly fine** - there are a few items you should take a look at.' }
        'Low'      { '🟢 **Good** - only minor things open.' }
        default    { '🟢 **Very good** - no open problems were found.' }
    }

    $L.Add('# Windows 10 System Report'); $L.Add('')
    $L.Add("> Created on $(Get-Date -Format 'yyyy-MM-dd') at $(Get-Date -Format 'HH:mm') · Duration $dur min. · Computer **$env:COMPUTERNAME** · Script version $script:Version"); $L.Add('')
    $L.Add('## 1. Overall result'); $L.Add('')
    $L.Add($verdict); $L.Add('')
    $L.Add("| Fixed automatically | Open (your task) | Notes |"); $L.Add('|---|---|---|')
    $L.Add("| **$($fixed.Count)** | **$($open.Count)** | **$($info.Count)** |"); $L.Add('')
    if ($script:FreedTotal -gt 0) { $L.Add("🧹 The cleanup freed approx. **$(Format-Size $script:FreedTotal)** of storage."); $L.Add('') }
    if ($script:RebootNeeded) {
        $L.Add("🔁 **A restart is required** ($($script:RebootReasons -join '; ')). Please save your work, restart Windows and - if updates were installed - run the script once more afterwards."); $L.Add('')
    }
    $L.Add("🛡️ **Windows 11 protection:** $script:Win11BlockState. This script never installs Windows 11; any Windows 11 offer it sees is hidden."); $L.Add('')
    $top = @($open | Select-Object -First 3)
    if ($top.Count -gt 0) {
        $L.Add('**Most important first:**'); $L.Add('')
        $n = 0
        foreach ($t in $top) { $n++; $L.Add("$n. $($icon[$t.Severity]) $($t.Title)") }
        $L.Add('')
    }

    if ($script:Diff -and $script:Diff.HasPrev) {
        $L.Add("**Compared with the previous run ($($script:Diff.PrevDate)):** $(@($script:Diff.New).Count) new, $(@($script:Diff.Resolved).Count) resolved."); $L.Add('')
        foreach ($n in @($script:Diff.New)) { $L.Add("- 🆕 $n") }
        foreach ($n in @($script:Diff.Resolved)) { $L.Add("- ✔️ resolved: $n") }
        if (@($script:Diff.New).Count + @($script:Diff.Resolved).Count -gt 0) { $L.Add('') }
    }
    if ($script:DryRun) { $L.Add('🧪 **Dry run:** nothing was changed on this PC. Items marked "would ..." in the action log were skipped on purpose.'); $L.Add('') }

    $L.Add('## 2. Open problems - the script could not fix these itself'); $L.Add('')
    $L.Add('_Sorted by urgency. For each item: what it means, how it was detected and what you can do._'); $L.Add('')
    if ($open.Count -eq 0) { $L.Add('✅ No open problems.'); $L.Add('') }
    $i = 0
    foreach ($f in $open) {
        $i++
        $L.Add("### 2.$i $($icon[$f.Severity]) $($f.Title)"); $L.Add('')
        $L.Add("**Urgency:** $($f.Severity) · **Area:** $($f.Category)"); $L.Add('')
        $L.Add("**What does this mean?** $($f.Meaning)"); $L.Add('')
        if ($f.Evidence) { $L.Add('**How was it detected?**'); $L.Add(''); foreach ($e in ($f.Evidence -split "`r?`n")) { $L.Add("> $e") }; $L.Add('') }
        if ($f.Recommendation) { $L.Add("**What can you do?** $($f.Recommendation)"); $L.Add('') }
    }

    $L.Add('## 3. Fixed automatically'); $L.Add('')
    if ($fixed.Count -eq 0) { $L.Add('_No problems had to be fixed automatically._'); $L.Add('') }
    foreach ($f in $fixed) {
        $L.Add("- ✅ **$($f.Title)** ($($f.Category))"); $L.Add("  - _Background:_ $($f.Meaning)"); if ($f.Recommendation) { $L.Add("  - _What was done:_ $($f.Recommendation)") }
    }
    $L.Add('')
    if ($script:Tables.Contains('Cleanup in detail') -and @($script:Tables['Cleanup in detail']).Count -gt 0) {
        $L.Add('### Cleanup in detail'); $L.Add('')
        ConvertTo-MdTable $script:Tables['Cleanup in detail'] | ForEach-Object { $L.Add($_) }; $L.Add('')
    }

    $L.Add('## 4. Notes and recommendations'); $L.Add('')
    if ($info.Count -eq 0) { $L.Add('_No additional notes._'); $L.Add('') }
    foreach ($f in $info) {
        $L.Add("- ⚪ **$($f.Title)** ($($f.Category))"); $L.Add("  - $($f.Meaning)"); if ($f.Recommendation) { $L.Add("  - _Recommendation:_ $($f.Recommendation)") }
    }
    $L.Add('')

    $L.Add('## 5. System overview'); $L.Add('')
    $L.Add('| Property | Value |'); $L.Add('|---|---|')
    foreach ($k in $script:Facts.Keys) { $L.Add("| $(Format-MdText $k) | $(Format-MdText $script:Facts[$k]) |") }
    $L.Add('')
    foreach ($name in $script:Tables.Keys) {
        if ($name -eq 'Cleanup in detail') { continue }
        $rows = @($script:Tables[$name])
        if ($rows.Count -eq 0) { continue }
        $L.Add("### $name"); $L.Add('')
        ConvertTo-MdTable $rows | ForEach-Object { $L.Add($_) }; $L.Add('')
    }

    $L.Add('## 6. Action log'); $L.Add('')
    $L.Add('| Time | Module | Result | Details |'); $L.Add('|---|---|---|---|')
    foreach ($a in $script:Actions) { $L.Add("| $($a.Time) | $(Format-MdText $a.Module) | $(Format-MdText $a.Status) | $(Format-MdText $a.Details) |") }
    $L.Add('')

    $L.Add('## 7. Undoing changes and further help'); $L.Add('')
    $L.Add('- **Restore point:** Before making changes, a restore point was created (if Windows allowed it). To restore: Start > "Create a restore point" > System Restore.')
    $L.Add("- **Lifting the Windows 11 block** (if you later decide to switch after all): PowerShell as administrator: ``Remove-ItemProperty 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate' -Name TargetReleaseVersion,ProductVersion,TargetReleaseVersionInfo,DisableOSUpgrade`` and ``Set-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\OSUpgrade' -Name AllowOSUpgrade -Value 1``. Hidden updates: Windows Update > Update history or wushowhide.")
    $L.Add('- **What this script deliberately does NOT do:** uninstall programs, telemetry/privacy tweaks, disable security features, delete personal files, install drivers from the web, or perform automatic registry "optimization".')
    $L.Add('- **Limits:** Automatic diagnoses can contain false alarms. A "no problems" result is not a guarantee of being error-free. For hardware warnings (disks, WHEA, blue screens), a backup takes priority over everything else.')
    $L.Add("- **Technical console log:** ``$script:LogPath``")
    $L.Add('')

    return ($L -join "`r`n")
}

function Write-ReportFile {
    param([string]$Path, [string]$Content)
    $enc = New-Object System.Text.UTF8Encoding($true)
    try {
        [IO.File]::WriteAllText($Path, $Content, $enc)
        return $Path
    } catch {
        Write-Bad "The report could not be saved to $(Split-Path $Path -Parent): $($_.Exception.Message)"
        try {
            $alt = Join-Path $env:TEMP (Split-Path $Path -Leaf)
            [IO.File]::WriteAllText($alt, $Content, $enc)
            Write-Host "  Alternative location: $alt" -ForegroundColor Yellow
            return $alt
        } catch { return $null }
    }
}

function Get-SnapshotDiff {
    # Compares this run with the newest earlier JSON snapshot ("new since last run").
    $script:Diff = @{ HasPrev = $false; New = @(); Resolved = @(); PrevDate = '' }
    try {
        $prev = Get-ChildItem -LiteralPath $script:SnapshotDir -Filter 'snapshot_*.json' -ErrorAction Stop | Sort-Object LastWriteTime -Descending | Select-Object -First 1
        if (-not $prev) { return }
        $old = Get-Content -LiteralPath $prev.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
        $oldOpen = @{}; foreach ($f in @($old.Findings)) { if ($f.Status -eq 'Open') { $oldOpen[$f.Id] = $f.Title } }
        $nowOpen = @{}; foreach ($f in @($script:Findings | Where-Object { $_.Status -eq 'Open' })) { $nowOpen[$f.Id] = $f.Title }
        $script:Diff.HasPrev = $true
        $script:Diff.PrevDate = $prev.LastWriteTime.ToString('yyyy-MM-dd HH:mm')
        $script:Diff.New = @($nowOpen.Keys | Where-Object { -not $oldOpen.ContainsKey($_) } | ForEach-Object { $nowOpen[$_] })
        $script:Diff.Resolved = @($oldOpen.Keys | Where-Object { -not $nowOpen.ContainsKey($_) } | ForEach-Object { $oldOpen[$_] })
    } catch {}
}

function Save-Snapshot {
    try {
        $snap = [ordered]@{
            Version = $script:Version; Date = (Get-Date).ToString('o'); Computer = $env:COMPUTERNAME; DryRun = $script:DryRun
            Facts = $script:Facts
            Findings = @($script:Findings.ToArray() | ForEach-Object { [ordered]@{ Id = $_.Id; Severity = $_.Severity; Category = $_.Category; Title = $_.Title; Status = $_.Status } })
        }
        # Dry runs are valid snapshots for diagnostics, but never overwrite the comparison base with a partial module run
        if ($script:ModuleList.Count -eq 0 -or $script:ModuleList.Count -ge 6) {
            $p = Join-Path $script:SnapshotDir ("snapshot_{0}.json" -f (Get-Date -Format 'yyyyMMdd_HHmmss'))
            [IO.File]::WriteAllText($p, ($snap | ConvertTo-Json -Depth 5), (New-Object System.Text.UTF8Encoding($true)))
        }
    } catch {}
}

function New-HtmlReport {
    $e = { param($x) [Net.WebUtility]::HtmlEncode([string]$x) }
    $sevColor = @{ 'Critical' = '#b00020'; 'High' = '#d9480f'; 'Medium' = '#b08900'; 'Low' = '#1c7ed6'; 'Info' = '#6c757d' }
    $open = @($script:Findings | Where-Object { $_.Status -eq 'Open' } | Sort-Object { $script:SevRank[$_.Severity] }, Category)
    $fixed = @($script:Findings | Where-Object { $_.Status -eq 'Fixed' })
    $info = @($script:Findings | Where-Object { $_.Status -eq 'Info' })
    $h = New-Object System.Collections.Generic.List[string]
    $h.Add('<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>Windows 10 System Report</title>')
    $h.Add('<style>:root{color-scheme:light dark}body{font:15px/1.5 Segoe UI,Arial,sans-serif;max-width:960px;margin:2rem auto;padding:0 1rem}h1{margin-bottom:0}.sub{color:#6c757d}')
    $h.Add('.card{border:1px solid #8884;border-left:6px solid var(--c);border-radius:6px;padding:.7rem 1rem;margin:.8rem 0}.tag{display:inline-block;color:#fff;background:var(--c);border-radius:4px;padding:0 .5rem;font-size:.8rem}')
    $h.Add('table{border-collapse:collapse;width:100%;margin:.5rem 0}td,th{border:1px solid #8884;padding:.25rem .5rem;text-align:left;font-size:.9rem;vertical-align:top}pre{white-space:pre-wrap;background:#8881;padding:.5rem;border-radius:4px}')
    $h.Add('.kpi span{display:inline-block;margin-right:1.5rem;font-size:1.1rem}</style></head><body>')
    $h.Add("<h1>Windows 10 System Report</h1><div class='sub'>$(& $e $env:COMPUTERNAME) &middot; $(Get-Date -Format 'yyyy-MM-dd HH:mm') &middot; script $(& $e $script:Version)$(if ($script:DryRun) { ' &middot; DRY RUN' })</div>")
    $h.Add("<p class='kpi'><span><b>$($fixed.Count)</b> fixed</span><span><b>$($open.Count)</b> open</span><span><b>$($info.Count)</b> notes</span>$(if ($script:FreedTotal -gt 0) { "<span><b>$(& $e (Format-Size $script:FreedTotal))</b> freed</span>" })</p>")
    if ($script:RebootNeeded) { $h.Add("<p><b>Restart required:</b> $(& $e ($script:RebootReasons -join '; '))</p>") }
    $h.Add("<p><b>Windows 11 protection:</b> $(& $e $script:Win11BlockState)</p>")
    if ($script:Diff -and $script:Diff.HasPrev) {
        $h.Add("<p>Since the previous run ($(& $e $script:Diff.PrevDate)): <b>$(@($script:Diff.New).Count)</b> new, <b>$(@($script:Diff.Resolved).Count)</b> resolved.</p>")
    }
    $h.Add('<h2>Open problems</h2>')
    if ($open.Count -eq 0) { $h.Add('<p>No open problems.</p>') }
    foreach ($f in $open) {
        $h.Add("<div class='card' style='--c:$($sevColor[$f.Severity])'><span class='tag'>$(& $e $f.Severity)</span> <b>$(& $e $f.Title)</b> <span class='sub'>$(& $e $f.Category)</span>")
        $h.Add("<p><b>What does this mean?</b> $(& $e $f.Meaning)</p>")
        if ($f.Evidence) { $h.Add("<p><b>How was it detected?</b></p><pre>$(& $e $f.Evidence)</pre>") }
        if ($f.Recommendation) { $h.Add("<p><b>What can you do?</b> $(& $e $f.Recommendation)</p>") }
        $h.Add('</div>')
    }
    $h.Add('<h2>Fixed automatically</h2>')
    if ($fixed.Count -eq 0) { $h.Add('<p>Nothing had to be fixed.</p>') } else { $h.Add('<ul>'); foreach ($f in $fixed) { $h.Add("<li><b>$(& $e $f.Title)</b> &mdash; $(& $e $f.Recommendation)</li>") }; $h.Add('</ul>') }
    $h.Add('<h2>Notes</h2><ul>')
    foreach ($f in $info) { $h.Add("<li><b>$(& $e $f.Title)</b> &mdash; $(& $e $f.Meaning)</li>") }
    $h.Add('</ul><h2>System overview</h2><table>')
    foreach ($k in $script:Facts.Keys) { $h.Add("<tr><th>$(& $e $k)</th><td>$(& $e $script:Facts[$k])</td></tr>") }
    $h.Add('</table>')
    foreach ($name in $script:Tables.Keys) {
        $rows = @($script:Tables[$name]); if ($rows.Count -eq 0) { continue }
        $props = $rows[0].PSObject.Properties.Name
        $h.Add("<h3>$(& $e $name)</h3><table><tr>$(($props | ForEach-Object { "<th>$(& $e $_)</th>" }) -join '')</tr>")
        foreach ($r in $rows) { $h.Add("<tr>$(($props | ForEach-Object { "<td>$(& $e $r.$_)</td>" }) -join '')</tr>") }
        $h.Add('</table>')
    }
    $h.Add('<h2>Action log</h2><table><tr><th>Time</th><th>Module</th><th>Result</th><th>Details</th></tr>')
    foreach ($a in $script:Actions) { $h.Add("<tr><td>$(& $e $a.Time)</td><td>$(& $e $a.Module)</td><td>$(& $e $a.Status)</td><td>$(& $e $a.Details)</td></tr>") }
    $h.Add("</table><p class='sub'>Console log: $(& $e $script:LogPath)</p></body></html>")
    return ($h -join "`n")
}

function Save-Report {
    Get-SnapshotDiff
    $saved = @()
    $md = New-MarkdownReport
    $p = Write-ReportFile -Path $script:ReportPath -Content $md
    if ($p) { $script:ReportPath = $p; $saved += $p }
    if ($script:ReportFormats -contains 'Html') {
        $p = Write-ReportFile -Path "$($script:ReportBase).html" -Content (New-HtmlReport)
        if ($p) { $saved += $p }
    }
    if ($script:ReportFormats -contains 'Json') {
        $data = [ordered]@{
            Version = $script:Version; Date = (Get-Date).ToString('o'); Computer = $env:COMPUTERNAME; DryRun = $script:DryRun
            RebootNeeded = $script:RebootNeeded; RebootReasons = $script:RebootReasons.ToArray(); Win11Block = $script:Win11BlockState
            # .ToArray(): @() on an empty List[object] throws "Argument types do not match" in Windows PowerShell 5.1
            Facts = $script:Facts; Findings = $script:Findings.ToArray(); Tables = $script:Tables; Actions = $script:Actions.ToArray()
        }
        $p = Write-ReportFile -Path "$($script:ReportBase).json" -Content ($data | ConvertTo-Json -Depth 6)
        if ($p) { $saved += $p }
    }
    Save-Snapshot
    foreach ($s in $saved) { Write-Host "  Report saved: $s" -ForegroundColor Green }
    return ($saved.Count -gt 0)
}

# ----------------------------------------------------------------------------------------------
# 11. Menu and main flow
# ----------------------------------------------------------------------------------------------
function Invoke-Run {
    param([string[]]$Modules)
    foreach ($m in $Modules) {
        switch ($m) {
            'sys'   { Invoke-Module 'System diagnostics' { Invoke-SystemDiagnostics } }
            'net'   { Invoke-Module 'Network' { Invoke-NetworkDiagnostics } }
            'disk'  { Invoke-Module 'Disk health' { Invoke-DiskDiagnostics } }
            'sec'   { Invoke-Module 'Security check' { Invoke-SecurityDiagnostics } }
            'audit' { Invoke-Module 'Security audit' { Invoke-SecurityAudit } }
            'evt'   { Invoke-Module 'Event log analysis' { Invoke-EventLogAnalysis } }
            'svc'   { Invoke-Module 'Services and drivers' { Invoke-ServiceAndDriverCheck } }
            'clean' { Invoke-Module 'Cleanup' { Invoke-Cleanup } }
            'integ' { Invoke-Module 'Integrity and repair' { Invoke-IntegrityChecks } }
            'wu'    { Invoke-Module 'Windows Update (without Windows 11)' { Invoke-WindowsUpdateModule } }
            'store' { Invoke-Module 'Microsoft Store and apps' { Invoke-StoreModule } }
            'opt'   { Invoke-Module 'Optimizations' { Invoke-Optimizations } }
            'w11'   { Invoke-Module 'Windows 11 block' { Set-Win11Block } }
        }
    }
}

$script:ModulesDiag = @('sys', 'net', 'disk', 'sec', 'audit', 'evt', 'svc')
$script:ModulesFull = @('sys', 'net', 'disk', 'sec', 'audit', 'evt', 'svc', 'clean', 'integ', 'wu', 'store', 'opt')

function Show-Menu {
    Clear-Host
    Write-Host ''
    Write-Host '  ======================================================================' -ForegroundColor DarkCyan
    Write-Host "   WINDOWS 10 - SYSTEM MAINTENANCE  (Version $script:Version)" -ForegroundColor Cyan
    Write-Host '  ======================================================================' -ForegroundColor DarkCyan
    Write-Host "   $((Get-CimInstance Win32_OperatingSystem).Caption) $script:DisplayVersion  |  Windows 11 block: $script:Win11BlockState" -ForegroundColor Gray
    Write-Host ''
    Write-Host '   1  Full maintenance (recommended): diagnostics, cleanup, repair, updates, Store, optimization'
    Write-Host '   2  Diagnostics only (nothing is changed, except clearly detected misconfigurations)'
    Write-Host '   3  Cleanup only'
    Write-Host '   4  Check and repair integrity only (DISM, SFC, file system, WMI)'
    Write-Host '   5  Windows Update only (Windows 11 stays blocked)'
    Write-Host '   6  Microsoft Store / app updates only'
    Write-Host '   7  Optimizations only'
    Write-Host '   8  Set/check the Windows 11 block'
    Write-Host '   9  Security deep-dive only (persistence, accounts, ports, Defender settings)'
    Write-Host '   0  Exit (the report is still created)'
    Write-Host ''
    return (Read-Host '  Your choice')
}

function Wait-Key { if (-not $script:Auto) { Read-Host '  Press Enter to return to the menu' | Out-Null } }

# ---- Start ----
Clear-Host
Write-Title "Windows 10 System Maintenance $script:Version"
Write-Info "The report is saved to: $script:ReportDir"
Write-Info "Console log: $script:LogPath"
if ($script:Auto) { Write-Warn2 'Automatic mode: no prompts are shown. Riskier actions are skipped.' }
if ($script:DryRun) { Write-Warn2 'DRY RUN: diagnosing only. Nothing will be deleted, repaired, installed or changed.' }
Initialize-Preflight

if ($script:ModuleList.Count -gt 0) {
    Invoke-Run $script:ModuleList
} elseif ($script:Auto) {
    Invoke-Run $script:ModulesFull
} else {
    $quit = $false
    do {
        $c = Show-Menu
        switch ($c.Trim()) {
            '1' { Invoke-Run $script:ModulesFull; Wait-Key }
            '2' { Invoke-Run $script:ModulesDiag; Wait-Key }
            '3' { Invoke-Run @('clean'); Wait-Key }
            '4' { Invoke-Run @('integ'); Wait-Key }
            '5' { Invoke-Run @('wu'); Wait-Key }
            '6' { Invoke-Run @('store'); Wait-Key }
            '7' { Invoke-Run @('opt'); Wait-Key }
            '8' { Invoke-Run @('w11'); Wait-Key }
            '9' { Invoke-Run @('audit'); Wait-Key }
            '0' { $quit = $true }
            default { Write-Warn2 'Invalid selection.'; Start-Sleep -Seconds 1 }
        }
    } while (-not $quit)
}

# Finish: pending restart?
$pend = Test-PendingReboot
if ($pend.Count -gt 0) { Request-Reboot ('Pending operations: ' + ($pend -join ', ')) }
if ($script:RebootNeeded) {
    Add-Finding -Id 'reboot-required' -Severity 'Medium' -Category 'System' -Title 'Restart required to complete the maintenance' `
        -Meaning 'Updates or repairs were prepared and only take effect after a restart. Until then, security holes may still be open.' `
        -Evidence ($script:RebootReasons -join '; ') -Recommendation 'Save your work and restart Windows. Then run the script again to check whether everything is clean.'
}

Write-Title 'Creating the report'
$ok = Save-Report
$counts = @{
    open = @($script:Findings | Where-Object { $_.Status -eq 'Open' }).Count
    fixed = @($script:Findings | Where-Object { $_.Status -eq 'Fixed' }).Count
}
Write-Host ''
Write-Host "  Fixed automatically: $($counts.fixed)   |   Open: $($counts.open)" -ForegroundColor Cyan

# Exit code for schedulers/RMM: 0 = nothing important open, 10 = Medium, 11 = High, 12 = Critical
$worstOpen = 99
foreach ($f in @($script:Findings | Where-Object { $_.Status -eq 'Open' })) { if ($script:SevRank[$f.Severity] -lt $worstOpen) { $worstOpen = $script:SevRank[$f.Severity] } }
$script:ExitCode = switch ($worstOpen) { 0 { 12 } 1 { 11 } 2 { 10 } default { 0 } }

if ($script:TranscriptOn) { try { Stop-Transcript | Out-Null } catch {} }
if ($ok -and (Test-Path -LiteralPath $script:ReportPath)) {
    if (-not $script:Auto -and (Confirm-Step 'Open the report now?' -ReadOnly)) { try { Start-Process -FilePath $script:ReportPath } catch { Start-Process notepad.exe -ArgumentList "`"$script:ReportPath`"" } }
}
if ($script:RebootNeeded -and -not $script:Auto) {
    if (Confirm-Step 'Restart Windows now (60 second countdown, cancel with "shutdown /a")?' -Default $false -Risky) {
        Invoke-Native -File "$env:WINDIR\System32\shutdown.exe" -Arguments @('/r', '/t', '60', '/c', 'Windows10_SystemMaintenance: restart to finish maintenance') -Quiet | Out-Null
    }
}
if (-not $script:Auto) { Read-Host '  Press Enter to exit' | Out-Null }

# Release the keep-awake request and the single-instance lock
try { [void][Win32.PowerState]::SetThreadExecutionState([uint32]2147483648) } catch {}
try { if ($script:HasMutex) { $script:Mutex.ReleaseMutex() } } catch {}
exit $script:ExitCode
