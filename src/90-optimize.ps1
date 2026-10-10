# ----------------------------------------------------------------------------------------------
# 9. Optimizations
# ----------------------------------------------------------------------------------------------
function Invoke-StartupReview {
    # Guided autostart review: shows each Run-key program with its measured boot delay and lets the user switch
    # items off the same (reversible) way Task Manager does, via StartupApproved. Interactive only.
    if ($script:Auto -or $script:DryRun) { return }
    $sources = @(
        @{ Hive = 'HKCU'; Run = 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run'; Appr = 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run' },
        @{ Hive = 'HKLM'; Run = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run'; Appr = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run' },
        @{ Hive = 'HKLM32'; Run = 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Run'; Appr = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run32' })
    $delays = @{}
    if ($script:Tables.Contains('Slowest startup programs (last 30 days)')) {
        foreach ($r in @($script:Tables['Slowest startup programs (last 30 days)'])) { $delays[[string]$r.'Startup program'] = $r.'Average delay (s)' }
    }
    $items = @()
    foreach ($s in $sources) {
        $p = Get-ItemProperty -LiteralPath $s.Run -ErrorAction SilentlyContinue
        if (-not $p) { continue }
        foreach ($prop in $p.PSObject.Properties | Where-Object { $_.Name -notmatch '^PS' }) {
            $state = Get-ItemProperty -LiteralPath $s.Appr -Name $prop.Name -ErrorAction SilentlyContinue
            $disabled = $false
            if ($state) { $b = $state.($prop.Name); if ($b -and ($b[0] % 2) -eq 1) { $disabled = $true } }
            if ($disabled) { continue }
            $delay = ($delays.GetEnumerator() | Where-Object { $_.Key -like "*$($prop.Name)*" -or ([string]$prop.Value) -like "*$($_.Key)*" } | Select-Object -First 1).Value
            $items += [pscustomobject]@{ No = $items.Count + 1; Name = $prop.Name; Where = $s.Hive; Command = ([string]$prop.Value); Appr = $s.Appr; Delay = $delay }
        }
    }
    if ($items.Count -eq 0) { return }
    Write-Host ''
    Write-Host '  Programs that start with Windows (enabled):' -ForegroundColor Cyan
    foreach ($i in $items) {
        $cmd = if ($i.Command.Length -gt 60) { $i.Command.Substring(0, 60) + '...' } else { $i.Command }
        Write-Host ("   {0,2}. {1,-28} {2,-6} {3}{4}" -f $i.No, $i.Name, $i.Where, $cmd, $(if ($i.Delay) { "   [boot delay ~$($i.Delay) s]" } else { '' }))
    }
    $ans = Read-Host '  ?  Numbers to switch OFF (comma separated, Enter = leave all, reversible with -Undo)'
    if ([string]::IsNullOrWhiteSpace($ans)) { return }
    foreach ($n in ($ans -split '[,; ]+' | Where-Object { $_ -match '^\d+$' })) {
        $it = $items | Where-Object { $_.No -eq [int]$n } | Select-Object -First 1
        if (-not $it) { continue }
        try {
            if (-not (Test-Path -LiteralPath $it.Appr)) { New-Item -Path $it.Appr -Force | Out-Null }
            $old = $null; try { $old = (Get-ItemProperty -LiteralPath $it.Appr -Name $it.Name -ErrorAction Stop).($it.Name) } catch {}
            $bytes = [byte[]](3, 0, 0, 0) + [BitConverter]::GetBytes([DateTime]::UtcNow.ToFileTimeUtc())
            Set-ItemProperty -LiteralPath $it.Appr -Name $it.Name -Value $bytes -Type Binary -Force -ErrorAction Stop
            Add-JournalEntry -Type 'StartupApproved' -Target "$($it.Appr)|$($it.Name)" -Old $(if ($old) { [BitConverter]::ToString($old) } else { $null }) -New 'disabled'
            Write-Ok "Switched off: $($it.Name)"
            Add-Action 'Startup review' 'Success' "Disabled autostart: $($it.Name)"
        } catch { Write-Warn2 "Could not switch off $($it.Name): $($_.Exception.Message)" }
    }
}

function Invoke-DriverStoreReview {
    # Old versions of the same driver pile up in the driver store. Report; optionally keep newest two per driver.
    try {
        $drv = @(Get-WindowsDriver -Online -ErrorAction Stop)
    } catch { return }
    $groups = @($drv | Group-Object { "$($_.OriginalFileName | Split-Path -Leaf)|$($_.ProviderName)|$($_.ClassName)" } | Where-Object { $_.Count -gt 2 })
    if ($groups.Count -eq 0) { return }
    $stale = foreach ($g in $groups) { $g.Group | Sort-Object { [version]($_.Version -replace '[^\d\.]', '') } -Descending -ErrorAction SilentlyContinue | Select-Object -Skip 2 }
    $stale = @($stale)
    if ($stale.Count -eq 0) { return }
    Add-Finding -Id 'driverstore-old' -Severity 'Info' -Category 'Storage' -Title "$($stale.Count) old driver package version(s) in the driver store" `
        -Meaning 'Windows keeps previous driver versions for rollback. More than two per driver is rarely useful and wastes space.' `
        -Evidence (($stale | Select-Object -First 8 | ForEach-Object { "$($_.Driver) $($_.ProviderName) $($_.Version)" }) -join "`n") `
        -Recommendation 'The Cleanup module offers to remove all but the newest two versions of each driver (never drivers in use).' -Status 'Info'
    if (Confirm-Step "Remove these $($stale.Count) old driver package(s)? (Keeps the two newest of each; packages in use are refused by Windows.)" -Default $false -Risky) {
        $n = 0
        foreach ($d in $stale) {
            $r = Invoke-Native -File "$env:WINDIR\System32\pnputil.exe" -Arguments @('/delete-driver', $d.Driver) -Quiet -TimeoutSec 60
            if ($r.ExitCode -eq 0) { $n++ }
        }
        Write-Ok "$n old driver package(s) removed."
        Add-Action 'Driver store' 'Success' "$n of $($stale.Count) old packages removed."
        Set-FindingFixed -Id 'driverstore-old' -WhatWasDone "$n old driver package(s) were removed (newest two versions kept)."
    }
}

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
                try { Set-CimInstance -InputObject $cs -Property @{ AutomaticManagedPagefile = $true } -ErrorAction Stop; Add-JournalEntry -Type 'Pagefile' -Target 'AutomaticManagedPagefile' -Old 'False' -New 'True'; Set-FindingFixed -Id 'pagefile-manual' -WhatWasDone 'Automatic management of the page file was turned on (effective after a restart).'; Request-Reboot 'Page file' } catch { Write-Warn2 $_.Exception.Message }
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
                $oldGuid = [regex]::Match($plan, '[0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}').Value
                if ($oldGuid) { Add-JournalEntry -Type 'PowerPlan' -Target 'ActiveScheme' -Old $oldGuid -New '381b4222-f694-41f0-9685-ff5bb260df2e' }
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
    if ($script:Facts.Contains('Startup entries') -and [int]$script:Facts['Startup entries'] -gt 8 -and (Confirm-Step 'Review the autostart programs now and switch off the ones you do not need?' -Default $false)) { Invoke-StartupReview }
    Add-Action 'Optimizations' 'Completed' 'Checked TRIM/defrag, Defender, time, DNS, page file, startup.'
}

