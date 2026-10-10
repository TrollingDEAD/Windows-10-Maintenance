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
    $stuck = @(Get-ChildItem "$env:WINDIR\System32\spool\PRINTERS" -File -Force -ErrorAction SilentlyContinue | Where-Object { $_.LastWriteTime -lt (Get-Date).AddHours(-1) })
    if ($stuck.Count -gt 0) {
        Add-Finding -Id 'print-stuck' -Severity 'Low' -Category 'System' -Title "$($stuck.Count) print job file(s) are stuck in the spooler queue" `
            -Meaning 'Old queue files block printing ("printer offline" / jobs that never finish).' -Recommendation 'Stop the Print Spooler, delete the queue files, start it again (the script can do this).'
        if (Confirm-Step 'Clear the stuck print queue (stops and restarts the Print Spooler)?' -Default $false -Risky) {
            Stop-Service -Name Spooler -Force -ErrorAction SilentlyContinue
            $stuck | Remove-Item -Force -ErrorAction SilentlyContinue
            Start-Service -Name Spooler -ErrorAction SilentlyContinue
            Set-FindingFixed -Id 'print-stuck' -WhatWasDone 'The spooler queue was cleared and the service restarted.'
            Add-Action 'Printer repair' 'Success' "$($stuck.Count) stuck file(s) removed."
        }
    }
    if (Confirm-Step 'Rebuild the Windows Search index (fixes missing results / high indexer load; takes a while in the background)?' -Default $false -Risky) {
        Stop-Service -Name WSearch -Force -ErrorAction SilentlyContinue
        Set-RegistryValueTracked -Path 'HKLM:\SOFTWARE\Microsoft\Windows Search' -Name 'SetupCompletedSuccessfully' -Value 0 -Type DWord
        Start-Service -Name WSearch -ErrorAction SilentlyContinue
        Add-Action 'Search repair' 'Success' 'Index rebuild triggered.'
    }
    if (Confirm-Step 'Rebuild the Explorer icon cache (fixes wrong/blank icons; Explorer restarts briefly)?' -Default $false -Risky) {
        Stop-Process -Name explorer -Force -ErrorAction SilentlyContinue
        Get-ChildItem "$env:LOCALAPPDATA\Microsoft\Windows\Explorer" -Filter 'iconcache_*.db' -Force -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue
        Remove-Item "$env:LOCALAPPDATA\IconCache.db" -Force -ErrorAction SilentlyContinue
        Start-Process explorer.exe
        Add-Action 'Shell repair' 'Success' 'Icon cache deleted, Explorer restarted.'
    }
}

