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

    # Sampled load: who uses CPU and disk right now? (locale-independent WMI performance classes)
    try {
        Write-Info 'Sampling CPU and disk activity for 5 seconds ...'
        $cores = [math]::Max(1, [int]$cs.NumberOfLogicalProcessors)
        $diskS = @(); $procMax = @{}
        for ($i = 0; $i -lt 5; $i++) {
            $pp = @(Get-CimInstance Win32_PerfFormattedData_PerfProc_Process -ErrorAction Stop | Where-Object { $_.Name -notin '_Total', 'Idle' })
            foreach ($p in $pp) {
                if (-not $procMax.ContainsKey($p.Name)) { $procMax[$p.Name] = [pscustomobject]@{ Name = $p.Name; Cpu = 0.0; Io = 0.0 } }
                $procMax[$p.Name].Cpu += [double]$p.PercentProcessorTime / $cores / 5
                $procMax[$p.Name].Io += [double]$p.IODataBytesPersec / 5
            }
            $d = Get-CimInstance Win32_PerfFormattedData_PerfDisk_PhysicalDisk -Filter "Name='_Total'" -ErrorAction SilentlyContinue
            if ($d) { $diskS += [double]$d.PercentDiskTime }
            Start-Sleep -Seconds 1
        }
        $diskAvg = if ($diskS.Count) { [math]::Round(($diskS | Measure-Object -Average).Average, 0) } else { $null }
        if ($null -ne $diskAvg) { Add-Fact 'Disk activity (5 s average)' "$([math]::Min(100, $diskAvg)) %" }
        $topCpu = @($procMax.Values | Sort-Object Cpu -Descending | Select-Object -First 5)
        $script:Tables['Busiest processes (5 second sample)'] = @($topCpu | ForEach-Object { [pscustomobject]@{ Process = $_.Name; 'CPU %' = [math]::Round($_.Cpu, 1); 'Disk I/O' = "$(Format-Size $_.Io)/s" } })
        if ($null -ne $diskAvg -and $diskAvg -ge 90) {
            $topIo = ($procMax.Values | Sort-Object Io -Descending | Select-Object -First 1).Name
            Add-Finding -Id 'disk-busy' -Severity 'Medium' -Category 'Performance' -Title "The system drive is busy ($([math]::Min(100, $diskAvg)) % active)" `
                -Meaning 'A constantly busy drive makes the whole PC feel slow. Typical culprits: indexing, antivirus scans, updates, an almost full or failing disk (especially an HDD).' `
                -Evidence "Most disk traffic: $topIo" -Recommendation 'Wait for background work to finish, check disk health in this report, and consider an SSD if this is a hard disk.'
        }
    } catch {}

    # Edition quirks and Office Click-to-Run
    try {
        $ed = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -ErrorAction Stop).EditionID
        if ($ed -match 'EnterpriseS|IoT|LTSC') { Add-Fact 'Servicing channel' "$ed (long-term servicing: no Store/feature updates by design)" }
    } catch {}
    $c2r = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Office\ClickToRun\Configuration' -ErrorAction SilentlyContinue
    if ($c2r -and $c2r.VersionToReport) {
        Add-Fact 'Office (Click-to-Run)' "$($c2r.VersionToReport), channel: $(($c2r.CDNBaseUrl -split '/')[-1]), updates enabled: $($c2r.UpdatesEnabled)"
        if ("$($c2r.UpdatesEnabled)" -eq 'False') {
            Add-Finding -Id 'office-updates-off' -Severity 'Medium' -Category 'Software' -Title 'Microsoft Office updates are turned off' `
                -Meaning 'Office is a prime target for attackers; without updates known holes stay open.' -Recommendation 'Any Office app > File > Account > Update Options > Enable Updates.'
        }
    }

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
                try { Disable-WindowsOptionalFeature -Online -FeatureName SMB1Protocol -NoRestart -ErrorAction Stop | Out-Null; Add-JournalEntry -Type 'Feature' -Target 'SMB1Protocol' -Old 'Enabled' -New 'Disabled'; Set-FindingFixed -Id 'smb1-feature' -WhatWasDone 'The SMB1 feature was removed (effective after a restart). Undo: Enable-WindowsOptionalFeature -Online -FeatureName SMB1Protocol'; Request-Reboot 'SMB1 feature removal'; Add-Action 'SMB1 feature' 'Fixed' 'Removed.' } catch { Write-Warn2 $_.Exception.Message }
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
                try { Disable-WindowsOptionalFeature -Online -FeatureName MicrosoftWindowsPowerShellV2Root -NoRestart -ErrorAction Stop | Out-Null; Add-JournalEntry -Type 'Feature' -Target 'MicrosoftWindowsPowerShellV2Root' -Old 'Enabled' -New 'Disabled'; Set-FindingFixed -Id 'psv2' -WhatWasDone 'PowerShell 2.0 was removed.'; Add-Action 'PowerShell 2.0' 'Fixed' 'Removed.' } catch { Write-Warn2 $_.Exception.Message }
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
                try { Set-RegistryValueTracked -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\SecurityProviders\WDigest' -Name UseLogonCredential -Value 0 -Type DWord; Set-FindingFixed -Id 'wdigest' -WhatWasDone 'UseLogonCredential was set to 0.'; Add-Action 'WDigest' 'Fixed' 'UseLogonCredential=0' } catch { Write-Warn2 $_.Exception.Message }
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
                if (-not (Test-DryRun 'disable Guest account')) { try { Disable-LocalUser -Name $guest.Name -ErrorAction Stop; Add-JournalEntry -Type 'Account' -Target $guest.Name -Old 'Enabled' -New 'Disabled'; Set-FindingFixed -Id 'guest-enabled' -WhatWasDone 'The Guest account was disabled.' } catch { Write-Warn2 $_.Exception.Message } }
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
        $orphans = @()
        foreach ($t in $tasks) {
            $exe = [Environment]::ExpandEnvironmentVariables([string](@($t.Actions)[0].Execute)).Trim('"')
            if ($exe -and $exe -match '^[A-Za-z]:\\' -and -not (Test-Path -LiteralPath $exe -ErrorAction SilentlyContinue)) { $orphans += "$($t.TaskPath)$($t.TaskName) -> $exe" }
        }
        if ($orphans.Count -gt 0) {
            Add-Finding -Id 'tasks-orphaned' -Severity 'Low' -Category 'Persistence' -Title "$($orphans.Count) scheduled task(s) point to programs that no longer exist" `
                -Meaning 'Leftovers of uninstalled software. They fail silently at every trigger and clutter the system; malware cleanup also often leaves them.' `
                -Evidence (($orphans | Select-Object -First 8) -join "`n") -Recommendation 'Task Scheduler: delete these tasks.'
        }
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
        $orphSvc = @($svcs | Where-Object { $_.PathName -match '^\s*"?([A-Za-z]:\\[^"]+?\.(exe|sys))' -and -not (Test-Path -LiteralPath ([Environment]::ExpandEnvironmentVariables($Matches[1]))) })
        if ($orphSvc.Count -gt 0) {
            Add-Finding -Id 'svc-orphaned' -Severity 'Low' -Category 'Persistence' -Title "$($orphSvc.Count) service(s) point to files that no longer exist" `
                -Meaning 'Remnants of removed software (or of malware that was cleaned up). Harmless but they log errors at every boot.' `
                -Evidence (($orphSvc | Select-Object -First 8 | ForEach-Object { "$($_.Name): $($_.PathName)" }) -join "`n") -Recommendation "Admin prompt: sc delete <name> (after confirming the software is gone)."
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

    # --- Network shares open to Everyone ---
    try {
        $open = @()
        foreach ($sh in (Get-SmbShare -ErrorAction Stop | Where-Object { -not $_.Special })) {
            $acc = @(Get-SmbShareAccess -Name $sh.Name -ErrorAction SilentlyContinue | Where-Object { $_.AccountName -match 'Everyone|Jeder|ANONYMOUS' -and "$($_.AccessControlType)" -eq 'Allow' })
            if ($acc.Count -gt 0) { $open += "$($sh.Name) -> $($sh.Path) ($(($acc | ForEach-Object { $_.AccessRight }) -join '/'))" }
        }
        if ($open.Count -gt 0) {
            Add-Finding -Id 'shares-everyone' -Severity 'Medium' -Category 'Network' -Title "$($open.Count) network share(s) are open to Everyone" `
                -Meaning 'Anyone who can reach this PC on the network can read (or change) the shared folder.' -Evidence ($open -join "`n") `
                -Recommendation 'Share only with named users (folder > Properties > Sharing > Advanced Sharing > Permissions) or remove the share.'
        }
    } catch {}

    # --- Firewall: inbound allow rules without program and port restriction ---
    try {
        $wide = @()
        foreach ($r in (Get-NetFirewallRule -Enabled True -Direction Inbound -Action Allow -PolicyStore ActiveStore -ErrorAction Stop | Where-Object { [string]::IsNullOrEmpty($_.DisplayGroup) })) {
            $app = $r | Get-NetFirewallApplicationFilter -ErrorAction SilentlyContinue
            $port = $r | Get-NetFirewallPortFilter -ErrorAction SilentlyContinue
            $addr = $r | Get-NetFirewallAddressFilter -ErrorAction SilentlyContinue
            if ($app.Program -eq 'Any' -and $port.LocalPort -eq 'Any' -and $addr.RemoteAddress -eq 'Any' -and $port.Protocol -in 'Any', '6', '17') { $wide += $r.DisplayName }
        }
        if ($wide.Count -gt 0) {
            Add-Finding -Id 'firewall-wide-open' -Severity 'Medium' -Category 'Security' -Title "$($wide.Count) custom firewall rule(s) allow all inbound traffic" `
                -Meaning 'A rule with no program, no port and no address restriction switches the firewall off for everything it covers.' `
                -Evidence (($wide | Select-Object -First 8) -join "`n") -Recommendation 'Windows Defender Firewall with Advanced Security > Inbound Rules: delete or restrict these rules.'
        }
    } catch {}

    # --- Remote Desktop hardening (only if RDP is on) ---
    if ((Get-RegValue 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server' 'fDenyTSConnections') -eq 0) {
        $rdpTcp = 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp'
        if ((Get-RegValue $rdpTcp 'UserAuthentication') -eq 0) {
            Add-Finding -Id 'rdp-no-nla' -Severity 'High' -Category 'Security' -Title 'Remote Desktop does not require Network Level Authentication' `
                -Meaning 'Without NLA the login screen is exposed before authentication, which enables brute force and several known RDP exploits.' `
                -Recommendation 'Settings > System > Remote Desktop > Advanced settings: require Network Level Authentication.'
        }
    }

    # --- Local password and lockout policy ---
    try {
        $inf = Join-Path $env:TEMP ("w10m_sec_{0}.inf" -f [guid]::NewGuid().ToString('N'))
        $null = Invoke-Native -File "$env:WINDIR\System32\secedit.exe" -Arguments @('/export', '/cfg', $inf, '/areas', 'SECURITYPOLICY') -Quiet -TimeoutSec 60
        if (Test-Path -LiteralPath $inf) {
            $pol = Get-Content -LiteralPath $inf -Raw
            Remove-Item -LiteralPath $inf -Force -ErrorAction SilentlyContinue
            $minLen = [regex]::Match($pol, '(?m)^MinimumPasswordLength\s*=\s*(\d+)').Groups[1].Value
            $lock = [regex]::Match($pol, '(?m)^LockoutBadCount\s*=\s*(\d+)').Groups[1].Value
            if ($minLen -ne '' -or $lock -ne '') { Add-Fact 'Password policy' "min. length $minLen, lockout after $(if ($lock -eq '0') { 'never' } else { "$lock failed attempts" })" }
            if ($lock -eq '0') {
                Add-Finding -Id 'no-lockout' -Severity 'Low' -Category 'Accounts' -Title 'Accounts are never locked after failed sign-ins' `
                    -Meaning 'Without an account lockout threshold, passwords can be guessed indefinitely (relevant if RDP or file sharing is reachable).' `
                    -Recommendation "Local Security Policy > Account Policies > Account Lockout Policy: threshold 10, duration 15 minutes."
            }
        }
    } catch {}

    # --- Exploit protection (DEP / ASLR) ---
    try {
        $mit = Get-ProcessMitigation -System -ErrorAction Stop
        Add-Fact 'Exploit protection (system)' "DEP: $($mit.DEP.Enable), ASLR bottom-up: $($mit.ASLR.BottomUp)"
        if ("$($mit.DEP.Enable)" -eq 'OFF') {
            Add-Finding -Id 'dep-off' -Severity 'High' -Category 'Security' -Title 'Data Execution Prevention (DEP) is off system-wide' `
                -Meaning 'DEP blocks code from running in data memory, a basic defence against many exploits.' -Recommendation "Windows Security > App & browser control > Exploit protection settings > DEP: Use default (On)."
        }
    } catch {}

    # --- VPN left connected, Device Guard ---
    try {
        $vpn = @(Get-VpnConnection -AllUserConnection -ErrorAction SilentlyContinue | Where-Object { "$($_.ConnectionStatus)" -eq 'Connected' })
        if ($vpn.Count -gt 0) { Add-Fact 'VPN connected' (($vpn | ForEach-Object { $_.Name }) -join ', ') }
    } catch {}
    try {
        $dg = Get-CimInstance -Namespace root\Microsoft\Windows\DeviceGuard -ClassName Win32_DeviceGuard -ErrorAction Stop
        Add-Fact 'Virtualization-based security' $(if (@($dg.SecurityServicesRunning).Count -gt 0) { "running (services: $(@($dg.SecurityServicesRunning) -join ','))" } else { 'not running' })
    } catch {}

    # --- Expired / expiring machine certificates ---
    try {
        $certs = @(Get-ChildItem Cert:\LocalMachine\My -ErrorAction Stop | Where-Object { $_.NotAfter -lt (Get-Date).AddDays(30) })
        if ($certs.Count -gt 0) {
            Add-Finding -Id 'certs-expiring' -Severity 'Low' -Category 'Security' -Title "$($certs.Count) computer certificate(s) expired or expire within 30 days" `
                -Meaning 'Expired certificates break VPN, Wi-Fi 802.1X, RDP or internal web access.' `
                -Evidence (($certs | Select-Object -First 6 | ForEach-Object { "$($_.Subject) (expires $($_.NotAfter.ToString('yyyy-MM-dd')))" }) -join "`n") -Recommendation 'Renew or remove the certificates you no longer use (certlm.msc).'
        }
    } catch {}

    # --- Stale local accounts ---
    try {
        $stale = @(Get-LocalUser -ErrorAction Stop | Where-Object { $_.Enabled -and $_.LastLogon -and $_.LastLogon -lt (Get-Date).AddDays(-180) -and $_.SID.Value -notmatch '-50[0-3]$' })
        if ($stale.Count -gt 0) {
            Add-Finding -Id 'stale-accounts' -Severity 'Low' -Category 'Accounts' -Title "$($stale.Count) enabled account(s) not used for 6+ months" `
                -Meaning 'Forgotten accounts are easy targets because nobody notices misuse.' -Evidence (($stale | ForEach-Object { "$($_.Name) (last sign-in $($_.LastLogon.ToString('yyyy-MM-dd')))" }) -join "`n") `
                -Recommendation 'Disable or delete accounts you no longer need (Settings > Accounts > Family & other users).'
        }
    } catch {}

    # --- Browsers: age of the installed build, and extensions ---
    try {
        $browsers = @(
            @{ N = 'Google Chrome'; P = "${env:ProgramFiles}\Google\Chrome\Application\chrome.exe"; P2 = "${env:ProgramFiles(x86)}\Google\Chrome\Application\chrome.exe"; Ext = "$env:LOCALAPPDATA\Google\Chrome\User Data\Default\Extensions" },
            @{ N = 'Microsoft Edge'; P = "${env:ProgramFiles(x86)}\Microsoft\Edge\Application\msedge.exe"; P2 = "${env:ProgramFiles}\Microsoft\Edge\Application\msedge.exe"; Ext = "$env:LOCALAPPDATA\Microsoft\Edge\User Data\Default\Extensions" },
            @{ N = 'Mozilla Firefox'; P = "${env:ProgramFiles}\Mozilla Firefox\firefox.exe"; P2 = "${env:ProgramFiles(x86)}\Mozilla Firefox\firefox.exe"; Ext = $null })
        $extRows = @()
        foreach ($b in $browsers) {
            $exe = @($b.P, $b.P2) | Where-Object { $_ -and (Test-Path -LiteralPath $_) } | Select-Object -First 1
            if (-not $exe) { continue }
            $item = Get-Item -LiteralPath $exe
            $ageD = [int]((Get-Date) - $item.LastWriteTime).TotalDays
            Add-Fact "Browser: $($b.N)" "$($item.VersionInfo.ProductVersion), file date $($item.LastWriteTime.ToString('yyyy-MM-dd'))"
            if ($ageD -gt 120) {
                Add-Finding -Id "browser-old-$($b.N -replace '\W', '')" -Severity 'Medium' -Category 'Software' -Title "$($b.N) has not been updated for $ageD days" `
                    -Meaning 'Browsers are patched every few weeks; an old build has known, publicly exploitable holes.' -Recommendation 'Open the browser > About, let it update, and restart it (or run the winget upgrade step).'
            }
            if ($b.Ext -and (Test-Path -LiteralPath $b.Ext)) {
                foreach ($d in (Get-ChildItem -LiteralPath $b.Ext -Directory -ErrorAction SilentlyContinue)) {
                    $ver = Get-ChildItem -LiteralPath $d.FullName -Directory -ErrorAction SilentlyContinue | Sort-Object Name -Descending | Select-Object -First 1
                    $man = if ($ver) { Join-Path $ver.FullName 'manifest.json' } else { $null }
                    $nm = ''; $vv = ''
                    if ($man -and (Test-Path -LiteralPath $man)) { try { $mj = Get-Content -LiteralPath $man -Raw -Encoding UTF8 | ConvertFrom-Json; $nm = [string]$mj.name; $vv = [string]$mj.version } catch {} }
                    $extRows += [pscustomobject]@{ Browser = $b.N; Extension = $(if ($nm -match '^__MSG') { "$($d.Name) (localized name)" } elseif ($nm) { $nm } else { $d.Name }); Version = $vv }
                }
            }
        }
        if ($extRows.Count -gt 0) { $script:Tables['Browser extensions (default profile)'] = @($extRows | Select-Object -First 60) }
    } catch {}

    Add-Action 'Security audit' 'Completed' ("Accounts, ports, persistence, services, proxy, shares, firewall, RDP, policy, browsers, software in {0:N0} s." -f ((Get-Date) - $startAt).TotalSeconds)
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
                try { Set-NetFirewallProfile -Name $p.Name -Enabled True -ErrorAction Stop; Add-JournalEntry -Type 'Firewall' -Target $p.Name -Old 'False' -New 'True'; Set-FindingFixed -Id $fid -WhatWasDone "The script turned on Windows Firewall in the '$($p.Name)' profile."; Add-Action 'Firewall' 'Fixed' "Profile $($p.Name) turned on." } catch { Write-Warn2 $_.Exception.Message }
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
                try { Set-SmbServerConfiguration -EnableSMB1Protocol $false -Force -ErrorAction Stop; Add-JournalEntry -Type 'Smb1' -Target 'SMB1 server' -Old 'True' -New 'False'; Set-FindingFixed -Id 'smb1' -WhatWasDone 'SMB1 was turned off. To undo: Set-SmbServerConfiguration -EnableSMB1Protocol $true'; Add-Action 'SMB1' 'Fixed' 'SMB1 server disabled.' } catch { Write-Warn2 $_.Exception.Message }
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

    # Boot time and the slowest startup items (Diagnostics-Performance log, events 100/101)
    try {
        $perf = 'Microsoft-Windows-Diagnostics-Performance/Operational'
        $boots = @(Get-WinEvent -FilterHashtable @{ LogName = $perf; Id = 100; StartTime = (Get-Date).AddDays(-30) } -MaxEvents 10 -ErrorAction Stop)
        $times = foreach ($b in $boots) {
            $x = [xml]$b.ToXml()
            $bt = ($x.Event.EventData.Data | Where-Object { $_.Name -eq 'BootTime' }).'#text'
            if ($bt) { [math]::Round([double]$bt / 1000, 0) }
        }
        if (@($times).Count -gt 0) {
            $avg = [math]::Round((@($times) | Measure-Object -Average).Average, 0)
            Add-Fact 'Boot time (last boots)' "average $avg s, latest $(@($times)[0]) s, from $(@($times).Count) boot(s)"
            if ($avg -gt 120) {
                Add-Finding -Id 'boot-slow' -Severity 'Low' -Category 'Performance' -Title "Windows takes about $avg seconds to start" `
                    -Meaning 'A start longer than two minutes usually means too many startup programs, a slow or full drive, or a driver that delays the boot.' `
                    -Recommendation 'See the list of slow startup items in this report, reduce autostart programs and check disk health.'
            }
        }
        $slow = @(Get-WinEvent -FilterHashtable @{ LogName = $perf; Id = 101; StartTime = (Get-Date).AddDays(-30) } -MaxEvents 200 -ErrorAction Stop)
        $rows = foreach ($s in $slow) {
            $x = [xml]$s.ToXml(); $d = $x.Event.EventData.Data
            [pscustomobject]@{ Program = ($d | Where-Object Name -eq 'FriendlyName').'#text'; Seconds = [math]::Round([double]($d | Where-Object Name -eq 'TotalTime').'#text' / 1000, 1) }
        }
        $top = @($rows | Where-Object { $_.Program } | Group-Object Program | ForEach-Object { [pscustomobject]@{ 'Startup program' = $_.Name; 'Slowed boot (times)' = $_.Count; 'Average delay (s)' = [math]::Round(($_.Group | Measure-Object Seconds -Average).Average, 1) } } |
            Sort-Object 'Average delay (s)' -Descending | Select-Object -First 8)
        if ($top.Count -gt 0) { $script:Tables['Slowest startup programs (last 30 days)'] = $top }
        $sd = @(Get-WinEvent -FilterHashtable @{ LogName = $perf; Id = 203; StartTime = (Get-Date).AddDays(-30) } -MaxEvents 20 -ErrorAction Stop)
        if ($sd.Count -ge 3) {
            Add-Finding -Id 'shutdown-slow' -Severity 'Low' -Category 'Performance' -Title "$($sd.Count) slow shutdowns in 30 days" `
                -Meaning 'Windows had to wait for an app or service to close during shutdown.' -Recommendation 'Update or uninstall the programs named in Event Viewer > Applications and Services Logs > Microsoft > Windows > Diagnostics-Performance (event 203).'
        }
    } catch {}

    # Event logs: disabled or recently cleared logs hide problems (and are an attacker trick)
    try {
        foreach ($l in (Get-WinEvent -ListLog 'System', 'Application', 'Microsoft-Windows-Windows Defender/Operational' -ErrorAction SilentlyContinue)) {
            if (-not $l.IsEnabled) {
                Add-Finding -Id "evtlog-off-$($l.LogName)" -Severity 'Medium' -Category 'Event log' -Title "The event log '$($l.LogName)' is disabled" `
                    -Meaning 'Without it Windows and the script cannot see errors or Defender detections.' -Recommendation 'Enable the log in Event Viewer (right-click > Enable Log).'
            }
        }
        $cleared = @(Get-WinEvent -FilterHashtable @{ LogName = 'System'; Id = 104; StartTime = (Get-Date).AddDays(-30) } -MaxEvents 5 -ErrorAction SilentlyContinue)
        if ($cleared.Count -gt 0) {
            Add-Finding -Id 'evtlog-cleared' -Severity 'Medium' -Category 'Event log' -Title 'An event log was cleared in the last 30 days' `
                -Meaning 'Clearing logs removes evidence. You may have done it with a "cleaner" tool; if not, it is a typical step after a compromise.' `
                -Evidence (($cleared | ForEach-Object { $_.TimeCreated.ToString('yyyy-MM-dd HH:mm') }) -join '; ') -Recommendation 'If you did not do this, run a full offline Defender scan and change important passwords.'
        }
    } catch {}
}

function Invoke-RecoveryCheck {
    # Can the PC be recovered? WinRE, restore points, backups, BitLocker keys, boot configuration.
    try {
        $re = (Invoke-Native -File "$env:WINDIR\System32\reagentc.exe" -Arguments @('/info') -Quiet -TimeoutSec 60).Output
        if ($re -match '(?i)Windows RE status\s*:\s*Disabled|Windows RE-Status\s*:\s*(Deaktiviert|Disabled)') {
            Add-Finding -Id 'winre-off' -Severity 'Medium' -Category 'Recovery' -Title 'The Windows Recovery Environment (WinRE) is disabled' `
                -Meaning 'WinRE provides "Reset this PC", Startup Repair and System Restore from the boot menu. Without it a PC that no longer boots is much harder to rescue.' `
                -Evidence $re -Recommendation "Admin prompt: 'reagentc /enable'. If that fails, the recovery partition is missing or too small."
            if (Confirm-Step 'Try to enable WinRE now (reagentc /enable)?') {
                $r = Invoke-Native -File "$env:WINDIR\System32\reagentc.exe" -Arguments @('/enable') -Quiet -TimeoutSec 120
                if ($r.ExitCode -eq 0) { Set-FindingFixed -Id 'winre-off' -WhatWasDone 'WinRE was enabled with reagentc /enable.'; Add-Action 'WinRE' 'Fixed' 'reagentc /enable' }
                else { Write-Warn2 "reagentc /enable failed (exit $($r.ExitCode))." }
            }
        } elseif ($re -match '(?i)Enabled|Aktiviert') { Add-Fact 'Windows Recovery Environment' 'enabled' }
    } catch {}

    $rp = $null
    try { $rp = Get-ComputerRestorePoint -ErrorAction Stop | Sort-Object CreationTime -Descending | Select-Object -First 1 } catch {}
    $rpAge = $null
    if ($rp) { try { $rpAge = ((Get-Date) - [Management.ManagementDateTimeConverter]::ToDateTime($rp.CreationTime)).Days } catch {} }
    if ($null -ne $rpAge) { Add-Fact 'Newest restore point' "$rpAge day(s) old" }

    $fh = $null
    try { $fh = Get-WinEvent -FilterHashtable @{ LogName = 'Microsoft-Windows-FileHistory-Core/WHC'; StartTime = (Get-Date).AddDays(-30) } -MaxEvents 1 -ErrorAction Stop } catch {}
    $docs = [Environment]::GetFolderPath('MyDocuments')
    $oneDriveKfm = $docs -match 'OneDrive'
    Add-Fact 'File History (30 days)' $(if ($fh) { 'active' } else { 'no activity' })
    Add-Fact 'Documents folder in OneDrive' $(if ($oneDriveKfm) { 'yes' } else { 'no' })
    if (-not $fh -and -not $oneDriveKfm -and ($null -eq $rpAge -or $rpAge -gt 30)) {
        Add-Finding -Id 'no-backup' -Severity 'Medium' -Category 'Recovery' -Title 'No Windows backup mechanism is in use' `
            -Meaning 'Neither File History, OneDrive folder backup nor a recent restore point was found. If the drive fails or ransomware hits, personal files are lost. (Third-party backup tools are not detected by this check.)' `
            -Recommendation 'Turn on File History (Settings > Update & Security > Backup) or OneDrive "Back up" for Desktop/Documents/Pictures, and keep one copy offline.'
    }

    try {
        foreach ($v in @(Get-BitLockerVolume -ErrorAction Stop | Where-Object { "$($_.ProtectionStatus)" -eq 'On' })) {
            if (-not @($v.KeyProtector | Where-Object { "$($_.KeyProtectorType)" -eq 'RecoveryPassword' })) {
                Add-Finding -Id "bitlocker-nokey-$($v.MountPoint)" -Severity 'Medium' -Category 'Recovery' -Title "BitLocker on $($v.MountPoint) has no recovery password" `
                    -Meaning 'If the TPM or hardware changes you can be locked out of your own data.' -Recommendation "manage-bde -protectors -add $($v.MountPoint) -RecoveryPassword, then store the key outside this PC."
            } else { Add-Fact "BitLocker recovery key ($($v.MountPoint))" 'a recovery password exists - make sure you stored it outside this PC' }
        }
    } catch {}

    try {
        $bcd = Invoke-Native -File "$env:WINDIR\System32\bcdedit.exe" -Arguments @('/enum') -Quiet -TimeoutSec 30
        if ($bcd.ExitCode -ne 0) {
            Add-Finding -Id 'bcd-error' -Severity 'High' -Category 'Recovery' -Title 'The boot configuration (BCD) cannot be read' `
                -Meaning 'The boot configuration store is damaged or inaccessible. The PC may fail to boot after the next restart.' `
                -Evidence $bcd.Output -Recommendation 'Boot from Windows installation media > Repair your computer > Command Prompt: bootrec /rebuildbcd. The script never does this automatically.'
        }
    } catch {}
    Add-Action 'Recovery check' 'Completed' 'WinRE, restore points, File History/OneDrive, BitLocker keys, BCD.'
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
            if ($script:Config.NeverTouchServices -and $name -in @($script:Config.NeverTouchServices)) { Write-Info "Service $name is on your NeverTouchServices list - left disabled."; continue }
            try {
                Set-ServiceStartTracked -Name $name -StartupType $expected[$name]
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

