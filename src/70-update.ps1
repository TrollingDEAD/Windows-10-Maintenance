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
        Set-RegistryValueTracked -Path $pol -Name TargetReleaseVersion -Value 1 -Type DWord
        Set-RegistryValueTracked -Path $pol -Name ProductVersion -Value 'Windows 10' -Type String
        Set-RegistryValueTracked -Path $pol -Name TargetReleaseVersionInfo -Value '22H2' -Type String
        Set-RegistryValueTracked -Path $pol -Name DisableOSUpgrade -Value 1 -Type DWord
        $os2 = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\OSUpgrade'
        Set-RegistryValueTracked -Path $os2 -Name AllowOSUpgrade -Value 0 -Type DWord
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
            try { Set-ServiceStartTracked -Name $n -StartupType Manual; Write-Ok "Service '$n' was disabled and has been set to 'Manual'."; Add-Action 'Update services' 'Fixed' "$n from Disabled to Manual." } catch {}
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

    # Report table: what is pending, with KB numbers and links
    $pendRows = foreach ($grp in @(@{ K = 'Update'; L = $normal }, @{ K = 'Feature (Win 10)'; L = $feature }, @{ K = 'Preview (not installed)'; L = $preview })) {
        foreach ($u in $grp.L) {
            $kb = ''; try { $kb = ($u.KBArticleIDs | ForEach-Object { "KB$_" }) -join ', ' } catch {}
            [pscustomobject]@{ Type = $grp.K; KB = $kb; Title = [string]$u.Title; Size = (Format-Size $u.MaxDownloadSize) }
        }
    }
    if (@($pendRows).Count -gt 0) { $script:Tables['Pending Windows updates'] = @($pendRows) }

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

