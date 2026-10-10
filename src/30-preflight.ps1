# ----------------------------------------------------------------------------------------------
# 3. Preparation: operating system, internet, restore point
# ----------------------------------------------------------------------------------------------
# ---- Configuration, health score, redaction, history, notifications, self-update -------------
function Import-ScriptConfig {
    $script:Config = @{ SuppressFindings = @(); NeverCleanPaths = @(); NeverTouchServices = @(); WingetPin = @(); EsuEndDate = '2026-10-13'; WebhookUrl = '' }
    if (Test-Path -LiteralPath $script:ConfigFile) {
        try {
            $c = Get-Content -LiteralPath $script:ConfigFile -Raw -Encoding UTF8 | ConvertFrom-Json
            foreach ($p in $c.PSObject.Properties) { if ($p.Name -notmatch '^_') { $script:Config[$p.Name] = $p.Value } }
            Write-Info "Configuration loaded: $script:ConfigFile"
        } catch { Write-Warn2 "Configuration file is not valid JSON and was ignored: $($_.Exception.Message)" }
    }
}

function New-ScriptConfig {
    # Writes a commented starter config the first time it is requested (never overwrites).
    if (Test-Path -LiteralPath $script:ConfigFile) { return }
    $starter = [ordered]@{
        '_help'            = 'SuppressFindings: finding IDs (wildcards ok, e.g. "evt-*") you accept and do not want in the report. NeverCleanPaths: folders the cleanup must skip. NeverTouchServices: service names the script must not reset. WingetPin: winget package IDs that must not be upgraded. EsuEndDate: end of your Windows 10 ESU coverage. WebhookUrl: optional https notification endpoint.'
        'SuppressFindings' = @()
        'NeverCleanPaths'  = @()
        'NeverTouchServices' = @()
        'WingetPin'        = @()
        'EsuEndDate'       = '2026-10-13'
        'WebhookUrl'       = ''
    }
    try {
        New-Item -ItemType Directory -Path (Split-Path $script:ConfigFile -Parent) -Force | Out-Null
        [IO.File]::WriteAllText($script:ConfigFile, ($starter | ConvertTo-Json), (New-Object System.Text.UTF8Encoding($true)))
        Write-Info "A starter configuration was written to $script:ConfigFile"
    } catch {}
}

function Get-HealthScore {
    # 100 minus weighted open findings; returns Score (0-100) and a label.
    $weights = @{ 'Critical' = 25; 'High' = 12; 'Medium' = 5; 'Low' = 2; 'Info' = 0 }
    $penalty = 0
    foreach ($f in @($script:Findings | Where-Object { $_.Status -eq 'Open' })) { $penalty += $weights[$f.Severity] }
    $score = [math]::Max(0, 100 - $penalty)
    $label = if ($score -ge 90) { 'Excellent' } elseif ($score -ge 75) { 'Good' } elseif ($score -ge 50) { 'Needs attention' } else { 'Poor' }
    return [pscustomobject]@{ Score = $score; Label = $label }
}

function Protect-ReportText([string]$Text) {
    # -Redact: mask identifying details so a report can be posted publicly.
    if (-not $script:Redact -or [string]::IsNullOrEmpty($Text)) { return $Text }
    $names = @($env:COMPUTERNAME, $env:USERNAME, $env:USERDOMAIN)
    try { $names += (Get-CimInstance Win32_BIOS -ErrorAction Stop).SerialNumber } catch {}
    try { $names += (Get-CimInstance Win32_ComputerSystemProduct -ErrorAction Stop).UUID } catch {}
    try { $names += (Get-CimInstance Win32_BaseBoard -ErrorAction Stop).SerialNumber } catch {}
    foreach ($n in ($names | Where-Object { $_ -and $_.Length -ge 3 -and $_ -notmatch '^(To be filled|Default string|None|System Serial|0+)' } | Select-Object -Unique)) {
        $Text = $Text -replace [regex]::Escape($n), '[redacted]'
    }
    $Text = $Text -replace '\b(?!127\.|0\.)(25[0-5]|2[0-4]\d|1?\d?\d)(\.(25[0-5]|2[0-4]\d|1?\d?\d)){3}\b', 'x.x.x.x'
    $Text = $Text -replace '\b([0-9A-Fa-f]{2}[:-]){5}[0-9A-Fa-f]{2}\b', 'xx:xx:xx:xx:xx:xx'
    return $Text
}

function Show-History {
    $snaps = @(Get-ChildItem -LiteralPath $script:SnapshotDir -Filter 'snapshot_*.json' -ErrorAction SilentlyContinue | Sort-Object LastWriteTime)
    if ($snaps.Count -eq 0) { Write-Warn2 'No snapshots yet - run the script at least once.'; return }
    $rows = foreach ($s in $snaps) {
        try {
            $j = Get-Content -LiteralPath $s.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
            $open = @($j.Findings | Where-Object { $_.Status -eq 'Open' })
            [pscustomobject]@{
                Date = ([datetime]$j.Date).ToString('yyyy-MM-dd HH:mm'); Score = $j.Score
                Open = $open.Count; Critical = @($open | Where-Object Severity -eq 'Critical').Count; High = @($open | Where-Object Severity -eq 'High').Count
                Bar = ('#' * [math]::Round([double]$j.Score / 5))
            }
        } catch {}
    }
    Write-Info "Health history (newest last, $(@($rows).Count) run(s)):"
    @($rows) | Format-Table Date, Score, Open, Critical, High, Bar -AutoSize | Out-String -Width 200 | Write-Host
    $first = @($rows)[0]; $last = @($rows)[-1]
    if ($first -and $last -and $null -ne $first.Score -and $null -ne $last.Score) {
        $d = [int]$last.Score - [int]$first.Score
        Write-Info ("Trend since the first run: {0}{1} points." -f $(if ($d -ge 0) { '+' } else { '' }), $d)
    }
}

function Send-RunNotification {
    $hs = Get-HealthScore
    $open = @($script:Findings | Where-Object { $_.Status -eq 'Open' })
    $changed = (-not $script:Diff) -or (-not $script:Diff.HasPrev) -or (@($script:Diff.New).Count + @($script:Diff.Resolved).Count -gt 0)
    $name = if ($script:Redact) { '[redacted]' } else { $env:COMPUTERNAME }
    $summary = "${name}: health $($hs.Score)/100 ($($hs.Label)), $($open.Count) open, $(@($script:Findings | Where-Object { $_.Status -eq 'Fixed' }).Count) fixed."
    if ($script:Diff -and $script:Diff.HasPrev) { $summary += " New: $(@($script:Diff.New).Count), resolved: $(@($script:Diff.Resolved).Count)." }

    $url = if ($WebhookUrl) { $WebhookUrl } else { [string]$script:Config.WebhookUrl }
    if ($url -and $changed) {
        if ($url -notmatch '^https://') { Write-Warn2 'Webhook ignored: only https:// URLs are allowed.' }
        else {
            try {
                if ($url -match 'ntfy') { Invoke-RestMethod -Uri $url -Method Post -Body $summary -ContentType 'text/plain' -TimeoutSec 20 | Out-Null }
                else {
                    $body = @{ text = $summary; content = $summary; computer = $name; score = $hs.Score; open = $open.Count } | ConvertTo-Json -Compress
                    Invoke-RestMethod -Uri $url -Method Post -Body $body -ContentType 'application/json' -TimeoutSec 20 | Out-Null
                }
                Write-Ok 'Notification sent to the webhook.'
                Add-Action 'Notification' 'Success' 'Webhook called.'
            } catch { Write-Warn2 "Webhook failed: $($_.Exception.Message)" }
        }
    } elseif ($url) { Write-Info 'Webhook not called: nothing changed since the previous run.' }

    if ($Toast) {
        try {
            $null = [Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime]
            $null = [Windows.Data.Xml.Dom.XmlDocument, Windows.Data.Xml.Dom.XmlDocument, ContentType = WindowsRuntime]
            $xml = New-Object Windows.Data.Xml.Dom.XmlDocument
            $xml.LoadXml("<toast><visual><binding template='ToastGeneric'><text>Windows 10 maintenance finished</text><text>$([Security.SecurityElement]::Escape($summary))</text></binding></visual></toast>")
            $appId = '{1AC14E77-02E7-4E5D-B744-2EB1AE5198B7}\WindowsPowerShell\v1.0\powershell.exe'
            [Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier($appId).Show([Windows.UI.Notifications.ToastNotification]::new($xml))
        } catch { Write-Info "Toast notification not available: $($_.Exception.Message)" }
    }
}

function Invoke-UpdateCheck {
    # Opt-in: asks GitHub for the latest release and verifies its SHA256. Never replaces the running script.
    if (-not $script:Online) { Write-Warn2 'No internet connection - update check skipped.'; return }
    try {
        $api = ($script:RepoUrl -replace 'https://github.com/', 'https://api.github.com/repos/') + '/releases/latest'
        $rel = Invoke-RestMethod -Uri $api -Headers @{ 'User-Agent' = 'Windows10-SystemMaintenance'; 'Accept' = 'application/vnd.github+json' } -TimeoutSec 20
        $latest = ($rel.tag_name -replace '^v', '')
        Write-Info "Installed version: $script:Version, latest release: $latest"
        $isNewer = $false
        try { $isNewer = ([version]$latest -gt [version]$script:Version) } catch { $isNewer = ($latest -ne $script:Version) }
        if (-not $isNewer) { Write-Ok 'You are up to date.'; return }
        $asset = @($rel.assets | Where-Object { $_.name -eq 'Windows10_SystemMaintenance.ps1' }) | Select-Object -First 1
        $sums = @($rel.assets | Where-Object { $_.name -match 'SHA256' }) | Select-Object -First 1
        Write-Info "A newer version is available: $($rel.html_url)"
        Add-Finding -Id 'script-update' -Severity 'Info' -Category 'Script' -Title "Version $latest of this script is available" `
            -Meaning 'A newer release exists on GitHub. The script never updates itself.' -Recommendation "Review the release notes at $($rel.html_url)" -Status 'Info'
        if ($asset -and $sums -and (Confirm-Step 'Download the new version to your Downloads folder and verify its checksum?' -Default $false -Risky)) {
            $dir = Join-Path ([Environment]::GetFolderPath('UserProfile')) 'Downloads'
            $target = Join-Path $dir "Windows10_SystemMaintenance_$latest.ps1"
            Invoke-WebRequest -Uri $asset.browser_download_url -OutFile $target -UseBasicParsing -TimeoutSec 60
            $sumText = (Invoke-WebRequest -Uri $sums.browser_download_url -UseBasicParsing -TimeoutSec 20).Content
            $want = [regex]::Match([string]$sumText, "(?im)^\s*([0-9a-f]{64})\s+\*?Windows10_SystemMaintenance\.ps1").Groups[1].Value
            $have = (Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash
            if ($want -and $have -ieq $want) { Write-Ok "Downloaded and verified: $target (SHA256 $have). Review it, then replace your copy."; Add-Action 'Update check' 'Downloaded' $target }
            else { Remove-Item -LiteralPath $target -Force -ErrorAction SilentlyContinue; Write-Bad 'Checksum mismatch - the download was deleted.'; Add-Action 'Update check' 'Checksum mismatch' 'Download deleted.' }
        }
    } catch { Write-Warn2 "Update check failed: $($_.Exception.Message)" }
}

function Invoke-KbUninstall([string]$Kb) {
    $id = ($Kb -replace '(?i)^KB', '')
    if ($id -notmatch '^\d{6,8}$') { Write-Bad "'$Kb' is not a valid KB number."; return }
    if (-not (Get-HotFix -Id "KB$id" -ErrorAction SilentlyContinue)) { Write-Warn2 "KB$id is not installed."; return }
    if (-not (Confirm-Step "Uninstall KB$id now? (Security updates should normally stay installed.)" -Default $false -Risky)) { return }
    if (Test-DryRun "uninstall KB$id") { return }
    $r = Invoke-Native -File "$env:WINDIR\System32\wusa.exe" -Arguments @('/uninstall', "/kb:$id", '/quiet', '/norestart') -Quiet -TimeoutSec 1800
    Write-Info "wusa exit code $($r.ExitCode) (3010 = restart required, 2359302 = not installed)."
    if ($r.ExitCode -in 0, 3010) { Request-Reboot "KB$id uninstalled"; Add-Action 'KB uninstall' 'Success' "KB$id" } else { Add-Action 'KB uninstall' 'Failed' "KB$id exit $($r.ExitCode)" }
}

function Export-InstalledApp {
    $w = Get-Command winget -ErrorAction SilentlyContinue
    if (-not $w) { Write-Warn2 'winget is not installed - app export skipped.'; return }
    $out = Join-Path $script:ReportDir ("Windows10_Apps_{0}.json" -f (Get-Date -Format 'yyyyMMdd_HHmmss'))
    $r = Invoke-Native -File $w.Source -Arguments @('export', '-o', $out, '--accept-source-agreements', '--disable-interactivity') -Quiet -TimeoutSec 300
    if (Test-Path -LiteralPath $out) { Write-Ok "Installed apps exported: $out (restore with 'winget import -i <file>')."; Add-Action 'App export' 'Success' $out }
    else { Write-Warn2 "winget export produced no file (exit code $($r.ExitCode))." }
}

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
    try { if ($script:Config.EsuEndDate) { $esuEnd = [datetime]::Parse([string]$script:Config.EsuEndDate, [Globalization.CultureInfo]::InvariantCulture) } } catch {}
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

