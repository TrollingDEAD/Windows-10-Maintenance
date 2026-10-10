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
            'rec'   { Invoke-Module 'Recovery readiness' { Invoke-RecoveryCheck } }
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

$script:ModulesDiag = @('sys', 'net', 'disk', 'sec', 'audit', 'rec', 'evt', 'svc')
$script:ModulesFull = @('sys', 'net', 'disk', 'sec', 'audit', 'rec', 'evt', 'svc', 'clean', 'integ', 'wu', 'store', 'opt')

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
    Write-Host '   R  Recovery readiness (WinRE, restore points, backups, BitLocker keys)'
    Write-Host '   U  Undo the changes of the last run     H  Health history     C  Config file'
    Write-Host '   0  Exit (the report is still created)'
    Write-Host ''
    return (Read-Host '  Your choice')
}

function Wait-Key { if (-not $script:Auto) { Read-Host '  Press Enter to return to the menu' | Out-Null } }

function Show-Gui {
    # Minimal launcher: choose modules/options, then start this same script with the matching parameters.
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing
    $mods = [ordered]@{
        'sys' = 'System diagnostics'; 'net' = 'Network'; 'disk' = 'Disk health'; 'sec' = 'Security check'; 'audit' = 'Security audit (persistence, accounts, ports)'
        'rec' = 'Recovery readiness'; 'evt' = 'Event log analysis'; 'svc' = 'Services and drivers'; 'clean' = 'Cleanup'; 'integ' = 'Integrity and repair (DISM, SFC)'
        'wu' = 'Windows Update (Windows 11 stays blocked)'; 'store' = 'Store / app updates'; 'opt' = 'Optimizations'
    }
    $form = New-Object Windows.Forms.Form
    $form.Text = 'Windows 10 System Maintenance'; $form.Size = New-Object Drawing.Size(460, 560); $form.StartPosition = 'CenterScreen'; $form.FormBorderStyle = 'FixedDialog'; $form.MaximizeBox = $false
    $lbl = New-Object Windows.Forms.Label; $lbl.Text = 'Choose what to run:'; $lbl.Location = '12,10'; $lbl.AutoSize = $true; $form.Controls.Add($lbl)
    $list = New-Object Windows.Forms.CheckedListBox; $list.Location = '12,34'; $list.Size = '420,300'; $list.CheckOnClick = $true
    $diagOnly = 'sys', 'net', 'disk', 'sec', 'audit', 'rec', 'evt', 'svc'
    foreach ($k in $mods.Keys) { [void]$list.Items.Add("$k  -  $($mods[$k])", ($k -in $diagOnly)) }
    $form.Controls.Add($list)
    $dry = New-Object Windows.Forms.CheckBox; $dry.Text = 'Dry run (change nothing)'; $dry.Location = '12,345'; $dry.AutoSize = $true; $dry.Checked = $true; $form.Controls.Add($dry)
    $auto = New-Object Windows.Forms.CheckBox; $auto.Text = 'Unattended (no questions; risky steps are skipped)'; $auto.Location = '12,370'; $auto.AutoSize = $true; $form.Controls.Add($auto)
    $html = New-Object Windows.Forms.CheckBox; $html.Text = 'Also create an HTML report'; $html.Location = '12,395'; $html.AutoSize = $true; $html.Checked = $true; $form.Controls.Add($html)
    $red = New-Object Windows.Forms.CheckBox; $red.Text = 'Redact the report (safe to share)'; $red.Location = '12,420'; $red.AutoSize = $true; $form.Controls.Add($red)
    $go = New-Object Windows.Forms.Button; $go.Text = 'Run'; $go.Location = '12,455'; $go.Size = '120,32'; $go.DialogResult = 'OK'; $form.Controls.Add($go); $form.AcceptButton = $go
    $cancel = New-Object Windows.Forms.Button; $cancel.Text = 'Cancel'; $cancel.Location = '142,455'; $cancel.Size = '100,32'; $cancel.DialogResult = 'Cancel'; $form.Controls.Add($cancel)
    if ($form.ShowDialog() -ne 'OK') { return }
    $sel = @(); $i = 0
    foreach ($k in $mods.Keys) { if ($list.GetItemChecked($i)) { $sel += $k }; $i++ }
    if ($sel.Count -eq 0) { return }
    $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-NoExit', '-File', "`"$PSCommandPath`"", '-NoElevate', '-Modules', "`"$($sel -join ',')`"")
    if ($dry.Checked) { $argList += '-DryRun' }
    if ($auto.Checked) { $argList += '-Auto' }
    if ($red.Checked) { $argList += '-Redact' }
    $argList += '-ReportFormat'; $argList += $(if ($html.Checked) { '"Markdown,Html"' } else { 'Markdown' })
    # Release the single-instance lock so the child run can take it
    try { if ($script:HasMutex) { $script:Mutex.ReleaseMutex(); $script:HasMutex = $false } } catch {}
    $psExe = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
    Start-Process -FilePath $psExe -ArgumentList $argList
}

# ---- Start ----
function Stop-Script([int]$Code = 0) {
    # Releases the keep-awake request, the single-instance lock and the transcript, then exits.
    try { [void][Win32.PowerState]::SetThreadExecutionState([uint32]2147483648) } catch {}
    if ($script:TranscriptOn) { try { Stop-Transcript | Out-Null } catch {} }
    try { if ($script:HasMutex) { $script:Mutex.ReleaseMutex() } } catch {}
    exit $Code
}

if (-not $script:Quiet) { Clear-Host }
Write-Title "Windows 10 System Maintenance $script:Version"
Write-Info "The report is saved to: $script:ReportDir"
Write-Info "Console log: $script:LogPath"
if ($script:Auto) { Write-Warn2 'Automatic mode: no prompts are shown. Riskier actions are skipped.' }
if ($script:DryRun) { Write-Warn2 'DRY RUN: diagnosing only. Nothing will be deleted, repaired, installed or changed.' }
Import-ScriptConfig
if (-not (Test-Path -LiteralPath $script:ConfigFile) -and -not $script:Auto) { New-ScriptConfig }

# Utility commands that replace the normal run
if ($Gui) { Show-Gui; Stop-Script 0 }
if ($History) { Show-History; Stop-Script 0 }
if ($Undo) { Invoke-Undo; Stop-Script 0 }
if ($UninstallKB) { Invoke-KbUninstall $UninstallKB; Stop-Script 0 }

Initialize-Preflight

$utilityOnly = ($CheckUpdate -or $ExportApps) -and $script:ModuleList.Count -eq 0 -and -not $script:Auto
if ($CheckUpdate) { Invoke-UpdateCheck }
if ($ExportApps) { Export-InstalledApp }
if ($utilityOnly) { Stop-Script 0 }

if ($script:ModuleList.Count -gt 0) {
    Invoke-Run $script:ModuleList
} elseif ($script:Auto) {
    Invoke-Run $script:ModulesFull
} else {
    $quit = $false
    do {
        $c = Show-Menu
        switch ($c.Trim().ToLower()) {
            '1' { Invoke-Run $script:ModulesFull; Wait-Key }
            '2' {
                Invoke-Run $script:ModulesDiag
                $openNow = @($script:Findings | Where-Object { $_.Status -eq 'Open' }).Count
                if ($openNow -gt 0 -and -not $script:DryRun) {
                    Write-Host ''
                    if (Confirm-Step "$openNow open finding(s). Run the repair and maintenance modules now (cleanup, integrity, updates, Store, optimizations)? Each risky step still asks first.") {
                        Invoke-Run @('clean', 'integ', 'wu', 'store', 'opt')
                    }
                }
                Wait-Key
            }
            '3' { Invoke-Run @('clean'); Wait-Key }
            '4' { Invoke-Run @('integ'); Wait-Key }
            '5' { Invoke-Run @('wu'); Wait-Key }
            '6' { Invoke-Run @('store'); Wait-Key }
            '7' { Invoke-Run @('opt'); Wait-Key }
            '8' { Invoke-Run @('w11'); Wait-Key }
            '9' { Invoke-Run @('audit'); Wait-Key }
            'r' { Invoke-Run @('rec'); Wait-Key }
            'u' { Invoke-Undo; Wait-Key }
            'h' { Show-History; Wait-Key }
            'c' { New-ScriptConfig; Write-Info "Edit this file to suppress findings or protect folders: $script:ConfigFile"; Wait-Key }
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
$finalScore = Get-HealthScore
Out-Line "  Health score: $($finalScore.Score)/100 ($($finalScore.Label))   |   Fixed automatically: $($counts.fixed)   |   Open: $($counts.open)" 'Cyan'
if ($script:Journal.Count -gt 0) { Write-Info "$($script:Journal.Count) change(s) were recorded and can be reverted with -Undo (menu U)." }
if ($WebhookUrl -or $script:Config.WebhookUrl -or $Toast) { Send-RunNotification }

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

Stop-Script $script:ExitCode
