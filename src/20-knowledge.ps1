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

