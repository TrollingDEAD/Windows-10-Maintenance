# ----------------------------------------------------------------------------------------------
# 1. Helper functions: output, input, findings
# ----------------------------------------------------------------------------------------------
function Out-Line([string]$Text, [string]$Color = 'Gray') {
    # Single exit point for console text: -Quiet prints plain lines without colour.
    if ($script:Quiet) { Write-Host $Text } else { Write-Host $Text -ForegroundColor $Color }
}
function Write-Title([string]$Text) {
    if ($script:Quiet) { Write-Host "== $Text =="; return }
    Write-Host ''
    Write-Host ('=' * 74) -ForegroundColor DarkCyan
    Write-Host ("  $Text") -ForegroundColor Cyan
    Write-Host ('=' * 74) -ForegroundColor DarkCyan
}
function Write-Info([string]$m) { Out-Line "  [i]  $m" 'Gray' }
function Write-Ok([string]$m)   { Out-Line "  [OK] $m" 'Green' }
function Write-Warn2([string]$m){ Out-Line "  [!]  $m" 'Yellow' }
function Write-Bad([string]$m)  { Out-Line "  [X]  $m" 'Red' }

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
    # User-accepted findings (config SuppressFindings, wildcards allowed) are counted but not reported
    foreach ($pat in @($script:Config.SuppressFindings)) {
        if ($pat -and $Id -like $pat) {
            if (-not $script:Suppressed.Contains($Id)) { $script:Suppressed.Add($Id) }
            return
        }
    }
    $old = $script:Findings | Where-Object { $_.Id -eq $Id } | Select-Object -First 1
    if ($old) { [void]$script:Findings.Remove($old) }
    $script:Findings.Add([pscustomobject]@{
        Id = $Id; Severity = $Severity; Category = $Category; Title = $Title; Meaning = $Meaning
        Evidence = $Evidence; Recommendation = $Recommendation; Status = $Status
    })
    $color = switch ($Severity) { 'Critical' { 'Red' } 'High' { 'Red' } 'Medium' { 'Yellow' } 'Low' { 'DarkYellow' } default { 'Gray' } }
    $tag = if ($Status -eq 'Fixed') { 'FIXED' } else { $Severity.ToUpper() }
    Out-Line ("  [{0}] {1}" -f $tag, $Title) $color
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

# ---- Undo journal: every reversible change is recorded with its previous value ----------------
function Save-Journal {
    if ($script:DryRun -or $script:Journal.Count -eq 0 -or -not $script:JournalPath) { return }
    try {
        $obj = [ordered]@{ Version = $script:Version; Date = (Get-Date).ToString('o'); Computer = $env:COMPUTERNAME; Entries = $script:Journal.ToArray() }
        [IO.File]::WriteAllText($script:JournalPath, ($obj | ConvertTo-Json -Depth 6), (New-Object System.Text.UTF8Encoding($true)))
    } catch {}
}

function Add-JournalEntry {
    param([string]$Type, [string]$Target, $Old, $New, [string]$Note = '')
    if ($script:DryRun) { return }
    if (-not $script:JournalPath) { $script:JournalPath = Join-Path $script:JournalDir ("journal_{0}.json" -f (Get-Date -Format 'yyyyMMdd_HHmmss')) }
    $script:Journal.Add([pscustomobject]@{ Time = (Get-Date).ToString('o'); Type = $Type; Target = $Target; Old = $Old; New = $New; Note = $Note })
    Save-Journal
}

function Set-RegistryValueTracked {
    param([string]$Path, [string]$Name, $Value, [ValidateSet('String', 'DWord')][string]$Type = 'DWord')
    $existed = $false; $old = $null
    try { $old = (Get-ItemProperty -LiteralPath $Path -Name $Name -ErrorAction Stop).$Name; $existed = $true } catch {}
    if (-not (Test-Path -LiteralPath $Path)) { New-Item -Path $Path -Force | Out-Null }
    Set-ItemProperty -LiteralPath $Path -Name $Name -Value $Value -Type $Type -Force -ErrorAction Stop
    Add-JournalEntry -Type 'Registry' -Target "$Path|$Name|$Type" -Old $(if ($existed) { "$old" } else { $null }) -New "$Value" -Note $(if ($existed) { 'value changed' } else { 'value created' })
}

function Set-ServiceStartTracked {
    param([string]$Name, [string]$StartupType)
    $before = (Get-CimInstance Win32_Service -Filter "Name='$Name'" -ErrorAction SilentlyContinue).StartMode
    Set-Service -Name $Name -StartupType $StartupType -ErrorAction Stop
    Add-JournalEntry -Type 'Service' -Target $Name -Old $before -New $StartupType
}

function Invoke-Undo {
    $files = @(Get-ChildItem -LiteralPath $script:JournalDir -Filter 'journal_*.json' -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending)
    if ($files.Count -eq 0) { Write-Warn2 'No undo journal found - nothing to revert.'; return }
    $f = $files[0]
    $j = Get-Content -LiteralPath $f.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
    $entries = @($j.Entries)
    Write-Info "Undo journal $($f.Name) from $($j.Date): $($entries.Count) change(s)."
    if (-not (Confirm-Step "Revert these $($entries.Count) change(s) now?" -Default $false -ReadOnly)) { Write-Info 'Nothing reverted.'; return }
    [array]::Reverse($entries)
    $okN = 0; $failN = 0; $notReversible = $false
    foreach ($e in $entries) {
        try {
            switch ($e.Type) {
                'Registry' {
                    $p, $n, $t = $e.Target -split '\|'
                    if ($null -eq $e.Old) { Remove-ItemProperty -LiteralPath $p -Name $n -ErrorAction Stop }
                    else {
                        $val = if ($t -eq 'DWord') { [int]$e.Old } else { [string]$e.Old }
                        Set-ItemProperty -LiteralPath $p -Name $n -Value $val -Type $t -Force -ErrorAction Stop
                    }
                }
                'Service'   { if ($e.Old) { Set-Service -Name $e.Target -StartupType ($(if ($e.Old -eq 'Auto') { 'Automatic' } else { $e.Old })) -ErrorAction Stop } }
                'PowerPlan' { Invoke-Native -File "$env:WINDIR\System32\powercfg.exe" -Arguments @('/setactive', [string]$e.Old) -Quiet | Out-Null }
                'Feature'   { Enable-WindowsOptionalFeature -Online -FeatureName $e.Target -NoRestart -ErrorAction Stop | Out-Null }
                'Account'   { Enable-LocalUser -Name $e.Target -ErrorAction Stop }
                'Firewall'  { Set-NetFirewallProfile -Name $e.Target -Enabled False -ErrorAction Stop }
                'Smb1'      { Set-SmbServerConfiguration -EnableSMB1Protocol $true -Force -ErrorAction Stop }
                'StartupApproved' {
                    $p, $n = $e.Target -split '\|'
                    if ($null -eq $e.Old) { Remove-ItemProperty -LiteralPath $p -Name $n -ErrorAction Stop }
                    else { Set-ItemProperty -LiteralPath $p -Name $n -Value ([byte[]]($e.Old -split '-' | ForEach-Object { [Convert]::ToByte($_, 16) })) -Type Binary -Force -ErrorAction Stop }
                }
                'Pagefile'  { Set-CimInstance -InputObject (Get-CimInstance Win32_ComputerSystem) -Property @{ AutomaticManagedPagefile = $false } -ErrorAction Stop }
                default     { $notReversible = $true }
            }
            if ($notReversible) { Write-Info "Skipped (not reversible): $($e.Type) $($e.Target) $($e.Note)"; $notReversible = $false; continue }
            Write-Ok "Reverted: $($e.Type) $($e.Target)"; $okN++
        } catch { Write-Warn2 "Could not revert $($e.Type) $($e.Target): $($_.Exception.Message)"; $failN++ }
    }
    Add-Action 'Undo' $(if ($failN -eq 0) { 'Success' } else { 'Partial' }) "$okN reverted, $failN failed (journal $($f.Name))."
    Write-Info "Undo finished: $okN reverted, $failN failed. A restart may be needed for features and policies."
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
        $timedOut = $false; $code = -1; $errText = ''
        try {
            $p = Start-Process -FilePath $File -ArgumentList $argStr -NoNewWindow -PassThru -RedirectStandardOutput $tmp -RedirectStandardError "$tmp.err" -ErrorAction Stop
            if (-not $p.WaitForExit($TimeoutSec * 1000)) { $timedOut = $true; try { $p.Kill() } catch {} } else { $code = $p.ExitCode }
        } catch { $code = -1 }
        if (Test-Path -LiteralPath "$tmp.err") {
            # stderr is appended to the output so error messages of the tool are not lost
            try { $errText = [string](Get-Content -LiteralPath "$tmp.err" -Raw -ErrorAction SilentlyContinue) } catch {}
            Remove-Item -LiteralPath "$tmp.err" -Force -ErrorAction SilentlyContinue
        }
        if (Test-Path -LiteralPath $tmp) {
            $bytes = [IO.File]::ReadAllBytes($tmp)
            # sfc.exe writes UTF-16, most other tools write the OEM/ANSI code page.
            $isUtf16 = ($bytes.Length -gt 1 -and ($bytes | Select-Object -First 200 | Where-Object { $_ -eq 0 }).Count -gt 10)
            $text = if ($isUtf16) { [Text.Encoding]::Unicode.GetString($bytes) } else { [Text.Encoding]::GetEncoding([Globalization.CultureInfo]::CurrentCulture.TextInfo.OEMCodePage).GetString($bytes) }   # console tools write the OEM code page
            if ($errText) { $text += "`n$errText" }
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
    foreach ($never in @($script:Config.NeverCleanPaths)) {
        if ($never -and $Path -like "$never*") { Write-Info "Skipped (NeverCleanPaths): $Path"; return $res }
    }
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

