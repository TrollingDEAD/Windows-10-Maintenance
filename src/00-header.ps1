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

.PARAMETER Quiet
    No colours and no decorative output (plain lines), suited for log files and RMM tools. Combine with -Auto.

.PARAMETER Redact
    Masks computer name, user name, serial numbers, IP/MAC addresses and profile paths in all reports so they can be
    posted in forums or GitHub issues.

.PARAMETER Undo
    Reverts the registry, service and policy changes recorded in the undo journal of the last run, then exits.

.PARAMETER History
    Prints the trend of the health score and the number of open findings from the stored snapshots, then exits.

.PARAMETER ConfigPath
    JSON file with preferences: SuppressFindings (finding IDs to hide), NeverCleanPaths, NeverTouchServices,
    EsuEndDate, WebhookUrl. Default: %LOCALAPPDATA%\Windows10_SystemMaintenance\config.json (created on request).

.PARAMETER WebhookUrl
    HTTPS URL (Teams, Slack, ntfy, Discord, ...) that receives a short JSON summary, but only when the set of open
    findings changed since the previous run.

.PARAMETER Toast
    Shows a Windows notification with the result at the end of the run.

.PARAMETER CheckUpdate
    Asks the GitHub Releases API whether a newer version exists and verifies the published SHA256 before offering the
    download. Never updates by itself.

.PARAMETER UninstallKB
    Uninstalls one update by its KB number (for example KB5034441) via wusa, then exits.

.PARAMETER ScheduleDay
    Day of the week for -Schedule (default Sunday).

.PARAMETER ScheduleTime
    Time of day (HH:mm) for -Schedule (default 03:00).

.PARAMETER Gui
    Opens a small window to pick modules and options (dry run, HTML report), then starts the normal run with them.

.PARAMETER ExportApps
    Writes the list of installed winget packages to a JSON file next to the report (for reinstalling after a reset).

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
    [switch]$AllowOnBattery,
    [switch]$Quiet,
    [switch]$Redact,
    [switch]$Undo,
    [switch]$History,
    [string]$ConfigPath,
    [string]$WebhookUrl,
    [switch]$Toast,
    [switch]$CheckUpdate,
    [string]$UninstallKB,
    [ValidateSet('Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', 'Sunday')]
    [string]$ScheduleDay = 'Sunday',
    [ValidatePattern('^\d{1,2}:\d{2}$')]
    [string]$ScheduleTime = '03:00',
    [switch]$ExportApps,
    [switch]$Gui
)

$ErrorActionPreference = 'Continue'
$script:Version = '3.1'
$script:RepoUrl = 'https://github.com/TrollingDEAD/Windows-10-Maintenance'
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
    foreach ($fwd in 'ReportFormat', 'WebhookUrl', 'ConfigPath', 'Redact', 'Quiet', 'Toast') {
        if ($PSBoundParameters.ContainsKey($fwd)) {
            $v = $PSBoundParameters[$fwd]
            if ($v -is [switch]) { if ($v.IsPresent) { $taskArgs += " -$fwd" } } else { $taskArgs += " -$fwd `"$(@($v) -join ',')`"" }
        }
    }
    $at = [datetime]::ParseExact($ScheduleTime.PadLeft(5, '0'), 'HH:mm', [Globalization.CultureInfo]::InvariantCulture)
    $trigger = New-ScheduledTaskTrigger -Weekly -DaysOfWeek $ScheduleDay -At $at
    $action = New-ScheduledTaskAction -Execute $psExe -Argument $taskArgs
    $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
    # Only when idle, wake the PC for the run, and give up after 4 hours
    $settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -WakeToRun -RunOnlyIfIdle -IdleDuration (New-TimeSpan -Minutes 5) -IdleWaitTimeout (New-TimeSpan -Hours 2) -ExecutionTimeLimit (New-TimeSpan -Hours 4) -MultipleInstances IgnoreNew
    Register-ScheduledTask -TaskName $script:TaskName -Trigger $trigger -Action $action -Principal $principal -Settings $settings -Force | Out-Null
    Write-Host "Scheduled task '$($script:TaskName)' registered: $ScheduleDay $ScheduleTime as SYSTEM (-Auto, runs when idle). Reports go to %ProgramData%\Windows10_SystemMaintenance\Reports." -ForegroundColor Green
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
$validModules = 'sys', 'net', 'disk', 'sec', 'evt', 'svc', 'audit', 'rec', 'clean', 'integ', 'wu', 'store', 'opt', 'w11'
$badModules = @($script:ModuleList | Where-Object { $_ -notin $validModules })
if ($badModules.Count -gt 0) { Write-Host "Unknown module(s): $($badModules -join ', '). Valid: $($validModules -join ', ')" -ForegroundColor Red; exit 1 }
$badFormats = @($script:ReportFormats | Where-Object { $_ -notin 'Markdown', 'Html', 'Json' })
if ($badFormats.Count -gt 0) { Write-Host "Unknown report format(s): $($badFormats -join ', '). Valid: Markdown, Html, Json" -ForegroundColor Red; exit 1 }

$script:Auto = [bool]$Auto
$script:DryRun = [bool]$DryRun
$script:AllowOnBattery = [bool]$AllowOnBattery
$script:IsSystem = [Security.Principal.WindowsIdentity]::GetCurrent().IsSystem
$script:ExitCode = 0
$script:Quiet = [bool]$Quiet
$script:Redact = [bool]$Redact
$script:Config = @{}
$script:Journal = New-Object System.Collections.Generic.List[object]
$script:Suppressed = New-Object System.Collections.Generic.List[string]
$script:JournalPath = $null
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
$script:JournalDir = Join-Path $dataRoot 'Journal'
$script:ConfigFile = if ($ConfigPath) { $ConfigPath } else { Join-Path $dataRoot 'config.json' }
$script:LogPath = Join-Path $script:LogDir ("SystemMaintenance_{0}.log" -f $stamp)
try {
    New-Item -ItemType Directory -Path $script:LogDir -Force | Out-Null
    New-Item -ItemType Directory -Path $script:SnapshotDir -Force | Out-Null
    New-Item -ItemType Directory -Path $script:JournalDir -Force | Out-Null
    Start-Transcript -Path $script:LogPath -Force | Out-Null
    $script:TranscriptOn = $true
} catch { $script:TranscriptOn = $false }

# Log/snapshot retention (reports on the desktop are the user's and are not touched).
if ($LogRetentionDays -gt 0) {
    foreach ($d in $script:LogDir, $script:SnapshotDir, $script:JournalDir) {
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

