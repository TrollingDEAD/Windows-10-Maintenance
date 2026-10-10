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

    Invoke-DriverStoreReview

    # Component store cleanup
    if ((Test-LongOperationAllowed 'Component store cleanup') -and (Confirm-Step 'Clean up the Windows component store (DISM StartComponentCleanup, safe, may take a few minutes)?')) {
        Write-Info 'Cleaning up the component store ...'
        $r = Invoke-Native -File "$env:WINDIR\System32\dism.exe" -Arguments @('/Online', '/Cleanup-Image', '/StartComponentCleanup') -Quiet -TimeoutSec 3600
        if ($r.ExitCode -eq 0) { Write-Ok 'Component store cleaned up.'; Add-Action 'Cleanup' 'Success' 'DISM StartComponentCleanup completed.' }
        else { Write-Warn2 "DISM reported code $($r.ExitCode)."; Add-Action 'Cleanup' 'Note' "DISM StartComponentCleanup: return code $($r.ExitCode)" }
        if ($r.ExitCode -eq 0 -and (Confirm-Step 'ALSO remove all superseded component versions (DISM /ResetBase)? Frees the most space, but installed updates can then no longer be uninstalled.' -Default $false -Risky)) {
            $r2 = Invoke-Native -File "$env:WINDIR\System32\dism.exe" -Arguments @('/Online', '/Cleanup-Image', '/StartComponentCleanup', '/ResetBase') -Quiet -TimeoutSec 3600
            Add-Action 'Cleanup' $(if ($r2.ExitCode -eq 0) { 'Success' } else { 'Note' }) "DISM /ResetBase: return code $($r2.ExitCode)"
        }
    }

    $freeAfter = Get-SystemFreeBytes
    $realGain = $freeAfter - $freeBefore
    if ($realGain -lt 0) { $realGain = 0 }
    $script:Tables['Cleanup in detail'] = $rows
    Add-Fact 'Freed by cleanup' "$(Format-Size $script:FreedTotal) (measured gain on the system drive: $(Format-Size $realGain))"
    Add-Action 'Cleanup' 'Completed' "Freed: approx. $(Format-Size $script:FreedTotal); measured: $(Format-Size $realGain)."
    Write-Ok "Cleanup finished. Freed: approx. $(Format-Size $script:FreedTotal) (measured: $(Format-Size $realGain))."
}

