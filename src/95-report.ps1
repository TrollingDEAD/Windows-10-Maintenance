# ----------------------------------------------------------------------------------------------
# 10. Markdown report
# ----------------------------------------------------------------------------------------------
function Format-MdText([string]$s) {
    if ($null -eq $s) { return '' }
    return ($s -replace '\|', '\|' -replace '\r?\n', ' ')
}
function ConvertTo-MdTable {
    param($Rows)
    $Rows = @($Rows)
    if ($Rows.Count -eq 0) { return @('_No entries._') }
    $props = $Rows[0].PSObject.Properties.Name
    $out = New-Object System.Collections.Generic.List[string]
    $out.Add('| ' + ($props -join ' | ') + ' |')
    $out.Add('|' + (($props | ForEach-Object { '---' }) -join '|') + '|')
    foreach ($r in $Rows) { $out.Add('| ' + (($props | ForEach-Object { Format-MdText ([string]$r.$_) }) -join ' | ') + ' |') }
    return $out
}

function New-MarkdownReport {
    $dur = [math]::Round(((Get-Date) - $script:StartedAt).TotalMinutes, 1)
    $L = New-Object System.Collections.Generic.List[string]
    $icon = @{ 'Critical' = '🔴'; 'High' = '🟠'; 'Medium' = '🟡'; 'Low' = '🔵'; 'Info' = '⚪' }
    $open = @($script:Findings | Where-Object { $_.Status -eq 'Open' } | Sort-Object { $script:SevRank[$_.Severity] }, Category)
    $fixed = @($script:Findings | Where-Object { $_.Status -eq 'Fixed' } | Sort-Object { $script:SevRank[$_.Severity] })
    $info = @($script:Findings | Where-Object { $_.Status -eq 'Info' } | Sort-Object Category)

    $worst = 'Info'
    foreach ($f in $open) { if ($script:SevRank[$f.Severity] -lt $script:SevRank[$worst]) { $worst = $f.Severity } }
    $verdict = switch ($worst) {
        'Critical' { '🔴 **Urgent action required** - there are critical findings (e.g. impending data loss or an active threat).' }
        'High'     { '🟠 **Action required** - there are important open problems that you should address soon.' }
        'Medium'   { '🟡 **Mostly fine** - there are a few items you should take a look at.' }
        'Low'      { '🟢 **Good** - only minor things open.' }
        default    { '🟢 **Very good** - no open problems were found.' }
    }

    $L.Add('# Windows 10 System Report'); $L.Add('')
    $L.Add("> Created on $(Get-Date -Format 'yyyy-MM-dd') at $(Get-Date -Format 'HH:mm') · Duration $dur min. · Computer **$env:COMPUTERNAME** · Script version $script:Version"); $L.Add('')
    $L.Add('## 1. Overall result'); $L.Add('')
    $L.Add($verdict); $L.Add('')
    $hs = Get-HealthScore
    $L.Add("**Health score: $($hs.Score) / 100 ($($hs.Label))** `` $('█' * [math]::Round($hs.Score / 5))$('░' * (20 - [math]::Round($hs.Score / 5))) ``"); $L.Add('')
    if ($script:Suppressed.Count -gt 0) { $L.Add("_$($script:Suppressed.Count) finding(s) are hidden by your configuration (SuppressFindings): $($script:Suppressed -join ', ')_"); $L.Add('') }
    if ($script:Redact) { $L.Add('_This report was redacted (-Redact): computer name, user name, serial numbers, IP and MAC addresses are masked._'); $L.Add('') }
    $L.Add("| Fixed automatically | Open (your task) | Notes |"); $L.Add('|---|---|---|')
    $L.Add("| **$($fixed.Count)** | **$($open.Count)** | **$($info.Count)** |"); $L.Add('')
    if ($script:FreedTotal -gt 0) { $L.Add("🧹 The cleanup freed approx. **$(Format-Size $script:FreedTotal)** of storage."); $L.Add('') }
    if ($script:RebootNeeded) {
        $L.Add("🔁 **A restart is required** ($($script:RebootReasons -join '; ')). Please save your work, restart Windows and - if updates were installed - run the script once more afterwards."); $L.Add('')
    }
    $L.Add("🛡️ **Windows 11 protection:** $script:Win11BlockState. This script never installs Windows 11; any Windows 11 offer it sees is hidden."); $L.Add('')
    $top = @($open | Select-Object -First 3)
    if ($top.Count -gt 0) {
        $L.Add('**Most important first:**'); $L.Add('')
        $n = 0
        foreach ($t in $top) { $n++; $L.Add("$n. $($icon[$t.Severity]) $($t.Title)") }
        $L.Add('')
    }

    if ($script:Diff -and $script:Diff.HasPrev) {
        $L.Add("**Compared with the previous run ($($script:Diff.PrevDate)):** $(@($script:Diff.New).Count) new, $(@($script:Diff.Resolved).Count) resolved."); $L.Add('')
        foreach ($n in @($script:Diff.New)) { $L.Add("- 🆕 $n") }
        foreach ($n in @($script:Diff.Resolved)) { $L.Add("- ✔️ resolved: $n") }
        if (@($script:Diff.New).Count + @($script:Diff.Resolved).Count -gt 0) { $L.Add('') }
    }
    if ($script:DryRun) { $L.Add('🧪 **Dry run:** nothing was changed on this PC. Items marked "would ..." in the action log were skipped on purpose.'); $L.Add('') }

    $L.Add('## 2. Open problems - the script could not fix these itself'); $L.Add('')
    $L.Add('_Sorted by urgency. For each item: what it means, how it was detected and what you can do._'); $L.Add('')
    if ($open.Count -eq 0) { $L.Add('✅ No open problems.'); $L.Add('') }
    $i = 0
    foreach ($f in $open) {
        $i++
        $L.Add("### 2.$i $($icon[$f.Severity]) $($f.Title)"); $L.Add('')
        $L.Add("**Urgency:** $($f.Severity) · **Area:** $($f.Category)"); $L.Add('')
        $L.Add("**What does this mean?** $($f.Meaning)"); $L.Add('')
        if ($f.Evidence) { $L.Add('**How was it detected?**'); $L.Add(''); foreach ($e in ($f.Evidence -split "`r?`n")) { $L.Add("> $e") }; $L.Add('') }
        if ($f.Recommendation) { $L.Add("**What can you do?** $($f.Recommendation)"); $L.Add('') }
        $L.Add("_Finding ID:_ ``$($f.Id)`` · [background and fix guide]($($script:RepoUrl)/blob/main/docs/FINDINGS.md#$(($f.Id.ToLower() -replace '[^a-z0-9]+', '-').Trim('-')))"); $L.Add('')
    }

    $L.Add('## 3. Fixed automatically'); $L.Add('')
    if ($fixed.Count -eq 0) { $L.Add('_No problems had to be fixed automatically._'); $L.Add('') }
    foreach ($f in $fixed) {
        $L.Add("- ✅ **$($f.Title)** ($($f.Category))"); $L.Add("  - _Background:_ $($f.Meaning)"); if ($f.Recommendation) { $L.Add("  - _What was done:_ $($f.Recommendation)") }
    }
    $L.Add('')
    if ($script:Tables.Contains('Cleanup in detail') -and @($script:Tables['Cleanup in detail']).Count -gt 0) {
        $L.Add('### Cleanup in detail'); $L.Add('')
        ConvertTo-MdTable $script:Tables['Cleanup in detail'] | ForEach-Object { $L.Add($_) }; $L.Add('')
    }

    $L.Add('## 4. Notes and recommendations'); $L.Add('')
    if ($info.Count -eq 0) { $L.Add('_No additional notes._'); $L.Add('') }
    foreach ($f in $info) {
        $L.Add("- ⚪ **$($f.Title)** ($($f.Category))"); $L.Add("  - $($f.Meaning)"); if ($f.Recommendation) { $L.Add("  - _Recommendation:_ $($f.Recommendation)") }
    }
    $L.Add('')

    $L.Add('## 5. System overview'); $L.Add('')
    $L.Add('| Property | Value |'); $L.Add('|---|---|')
    foreach ($k in $script:Facts.Keys) { $L.Add("| $(Format-MdText $k) | $(Format-MdText $script:Facts[$k]) |") }
    $L.Add('')
    foreach ($name in $script:Tables.Keys) {
        if ($name -eq 'Cleanup in detail') { continue }
        $rows = @($script:Tables[$name])
        if ($rows.Count -eq 0) { continue }
        $L.Add("### $name"); $L.Add('')
        ConvertTo-MdTable $rows | ForEach-Object { $L.Add($_) }; $L.Add('')
    }

    $L.Add('## 6. Action log'); $L.Add('')
    $L.Add('| Time | Module | Result | Details |'); $L.Add('|---|---|---|---|')
    foreach ($a in $script:Actions) { $L.Add("| $($a.Time) | $(Format-MdText $a.Module) | $(Format-MdText $a.Status) | $(Format-MdText $a.Details) |") }
    $L.Add('')

    $L.Add('## 7. Undoing changes and further help'); $L.Add('')
    $L.Add('- **Restore point:** Before making changes, a restore point was created (if Windows allowed it). To restore: Start > "Create a restore point" > System Restore.')
    $L.Add("- **Lifting the Windows 11 block** (if you later decide to switch after all): PowerShell as administrator: ``Remove-ItemProperty 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate' -Name TargetReleaseVersion,ProductVersion,TargetReleaseVersionInfo,DisableOSUpgrade`` and ``Set-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\OSUpgrade' -Name AllowOSUpgrade -Value 1``. Hidden updates: Windows Update > Update history or wushowhide.")
    $L.Add('- **What this script deliberately does NOT do:** uninstall programs, telemetry/privacy tweaks, disable security features, delete personal files, install drivers from the web, or perform automatic registry "optimization".')
    $L.Add('- **Limits:** Automatic diagnoses can contain false alarms. A "no problems" result is not a guarantee of being error-free. For hardware warnings (disks, WHEA, blue screens), a backup takes priority over everything else.')
    $L.Add("- **Technical console log:** ``$script:LogPath``")
    $L.Add('')

    return ($L -join "`r`n")
}

function Write-ReportFile {
    param([string]$Path, [string]$Content)
    $enc = New-Object System.Text.UTF8Encoding($true)
    $Content = Protect-ReportText $Content
    try {
        [IO.File]::WriteAllText($Path, $Content, $enc)
        return $Path
    } catch {
        Write-Bad "The report could not be saved to $(Split-Path $Path -Parent): $($_.Exception.Message)"
        try {
            $alt = Join-Path $env:TEMP (Split-Path $Path -Leaf)
            [IO.File]::WriteAllText($alt, $Content, $enc)
            Write-Host "  Alternative location: $alt" -ForegroundColor Yellow
            return $alt
        } catch { return $null }
    }
}

function Get-SnapshotDiff {
    # Compares this run with the newest earlier JSON snapshot ("new since last run").
    $script:Diff = @{ HasPrev = $false; New = @(); Resolved = @(); PrevDate = '' }
    try {
        $prev = Get-ChildItem -LiteralPath $script:SnapshotDir -Filter 'snapshot_*.json' -ErrorAction Stop | Sort-Object LastWriteTime -Descending | Select-Object -First 1
        if (-not $prev) { return }
        $old = Get-Content -LiteralPath $prev.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
        $oldOpen = @{}; foreach ($f in @($old.Findings)) { if ($f.Status -eq 'Open') { $oldOpen[$f.Id] = $f.Title } }
        $nowOpen = @{}; foreach ($f in @($script:Findings | Where-Object { $_.Status -eq 'Open' })) { $nowOpen[$f.Id] = $f.Title }
        $script:Diff.HasPrev = $true
        $script:Diff.PrevDate = $prev.LastWriteTime.ToString('yyyy-MM-dd HH:mm')
        $script:Diff.New = @($nowOpen.Keys | Where-Object { -not $oldOpen.ContainsKey($_) } | ForEach-Object { $nowOpen[$_] })
        $script:Diff.Resolved = @($oldOpen.Keys | Where-Object { -not $nowOpen.ContainsKey($_) } | ForEach-Object { $oldOpen[$_] })
    } catch {}
}

function Save-Snapshot {
    try {
        $snap = [ordered]@{
            Version = $script:Version; Date = (Get-Date).ToString('o'); Computer = $env:COMPUTERNAME; DryRun = $script:DryRun
            Score = (Get-HealthScore).Score
            Facts = $script:Facts
            Findings = @($script:Findings.ToArray() | ForEach-Object { [ordered]@{ Id = $_.Id; Severity = $_.Severity; Category = $_.Category; Title = $_.Title; Status = $_.Status } })
        }
        # Dry runs are valid snapshots for diagnostics, but never overwrite the comparison base with a partial module run
        if ($script:ModuleList.Count -eq 0 -or $script:ModuleList.Count -ge 6) {
            $p = Join-Path $script:SnapshotDir ("snapshot_{0}.json" -f (Get-Date -Format 'yyyyMMdd_HHmmss'))
            [IO.File]::WriteAllText($p, ($snap | ConvertTo-Json -Depth 5), (New-Object System.Text.UTF8Encoding($true)))
        }
    } catch {}
}

function New-HtmlReport {
    $e = { param($x) [Net.WebUtility]::HtmlEncode([string]$x) }
    $sevColor = @{ 'Critical' = '#b00020'; 'High' = '#d9480f'; 'Medium' = '#b08900'; 'Low' = '#1c7ed6'; 'Info' = '#6c757d' }
    $open = @($script:Findings | Where-Object { $_.Status -eq 'Open' } | Sort-Object { $script:SevRank[$_.Severity] }, Category)
    $fixed = @($script:Findings | Where-Object { $_.Status -eq 'Fixed' })
    $info = @($script:Findings | Where-Object { $_.Status -eq 'Info' })
    $h = New-Object System.Collections.Generic.List[string]
    $h.Add('<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>Windows 10 System Report</title>')
    $h.Add('<style>:root{color-scheme:light dark}body{font:15px/1.5 Segoe UI,Arial,sans-serif;max-width:960px;margin:2rem auto;padding:0 1rem}h1{margin-bottom:0}.sub{color:#6c757d}')
    $h.Add('.card{border:1px solid #8884;border-left:6px solid var(--c);border-radius:6px;padding:.7rem 1rem;margin:.8rem 0}.tag{display:inline-block;color:#fff;background:var(--c);border-radius:4px;padding:0 .5rem;font-size:.8rem}')
    $h.Add('table{border-collapse:collapse;width:100%;margin:.5rem 0}td,th{border:1px solid #8884;padding:.25rem .5rem;text-align:left;font-size:.9rem;vertical-align:top}pre{white-space:pre-wrap;background:#8881;padding:.5rem;border-radius:4px}')
    $h.Add('.kpi span{display:inline-block;margin-right:1.5rem;font-size:1.1rem}#flt button{font:inherit;padding:.15rem .7rem;border:1px solid #8888;border-radius:4px;background:transparent;color:inherit;cursor:pointer}:focus-visible{outline:3px solid #1c7ed6;outline-offset:2px}@media print{#flt{display:none}.card{break-inside:avoid}}</style></head><body><main>')
    $h.Add("<h1>Windows 10 System Report</h1><div class='sub'>$(& $e $env:COMPUTERNAME) &middot; $(Get-Date -Format 'yyyy-MM-dd HH:mm') &middot; script $(& $e $script:Version)$(if ($script:DryRun) { ' &middot; DRY RUN' })</div>")
    $hs = Get-HealthScore
    $h.Add("<p class='kpi'><span><b>$($hs.Score)</b>/100 health ($(& $e $hs.Label))</span><span><b>$($fixed.Count)</b> fixed</span><span><b>$($open.Count)</b> open</span><span><b>$($info.Count)</b> notes</span>$(if ($script:FreedTotal -gt 0) { "<span><b>$(& $e (Format-Size $script:FreedTotal))</b> freed</span>" })</p>")
    if ($script:RebootNeeded) { $h.Add("<p><b>Restart required:</b> $(& $e ($script:RebootReasons -join '; '))</p>") }
    $h.Add("<p><b>Windows 11 protection:</b> $(& $e $script:Win11BlockState)</p>")
    if ($script:Diff -and $script:Diff.HasPrev) {
        $h.Add("<p>Since the previous run ($(& $e $script:Diff.PrevDate)): <b>$(@($script:Diff.New).Count)</b> new, <b>$(@($script:Diff.Resolved).Count)</b> resolved.</p>")
    }
    # Score trend from earlier snapshots (inline SVG)
    try {
        $pts = @(Get-ChildItem -LiteralPath $script:SnapshotDir -Filter 'snapshot_*.json' -ErrorAction Stop | Sort-Object LastWriteTime | Select-Object -Last 30 |
            ForEach-Object { (Get-Content -LiteralPath $_.FullName -Raw -Encoding UTF8 | ConvertFrom-Json).Score } | Where-Object { $null -ne $_ })
        $pts += $hs.Score
        if ($pts.Count -ge 2) {
            $w = 300; $ht = 60; $step = $w / ($pts.Count - 1)
            $poly = (0..($pts.Count - 1) | ForEach-Object { '{0:N1},{1:N1}' -f ($_ * $step), ($ht - ($pts[$_] / 100 * $ht)) }) -join ' '
            $h.Add("<p class='sub'>Health score trend ($($pts.Count) runs)</p><svg width='$w' height='$ht' viewBox='0 0 $w $ht' role='img' aria-label='Health score trend'><polyline fill='none' stroke='#1c7ed6' stroke-width='2' points='$poly'/></svg>")
        }
    } catch {}
    $h.Add('<h2>Open problems</h2><p id="flt"><button data-f="all">All</button> <button data-f="Critical">Critical</button> <button data-f="High">High</button> <button data-f="Medium">Medium</button> <button data-f="Low">Low</button></p>')
    if ($open.Count -eq 0) { $h.Add('<p>No open problems.</p>') }
    foreach ($f in $open) {
        $h.Add("<div class='card' data-sev='$($f.Severity)' style='--c:$($sevColor[$f.Severity])'><span class='tag'>$(& $e $f.Severity)</span> <b>$(& $e $f.Title)</b> <span class='sub'>$(& $e $f.Category)</span>")
        $h.Add("<p><b>What does this mean?</b> $(& $e $f.Meaning)</p>")
        if ($f.Evidence) { $h.Add("<p><b>How was it detected?</b></p><pre>$(& $e $f.Evidence)</pre>") }
        if ($f.Recommendation) { $h.Add("<p><b>What can you do?</b> $(& $e $f.Recommendation)</p>") }
        $h.Add('</div>')
    }
    $h.Add('<h2>Fixed automatically</h2>')
    if ($fixed.Count -eq 0) { $h.Add('<p>Nothing had to be fixed.</p>') } else { $h.Add('<ul>'); foreach ($f in $fixed) { $h.Add("<li><b>$(& $e $f.Title)</b> &mdash; $(& $e $f.Recommendation)</li>") }; $h.Add('</ul>') }
    $h.Add('<h2>Notes</h2><ul>')
    foreach ($f in $info) { $h.Add("<li><b>$(& $e $f.Title)</b> &mdash; $(& $e $f.Meaning)</li>") }
    $h.Add('</ul><h2>System overview</h2><table>')
    foreach ($k in $script:Facts.Keys) { $h.Add("<tr><th>$(& $e $k)</th><td>$(& $e $script:Facts[$k])</td></tr>") }
    $h.Add('</table>')
    foreach ($name in $script:Tables.Keys) {
        $rows = @($script:Tables[$name]); if ($rows.Count -eq 0) { continue }
        $props = $rows[0].PSObject.Properties.Name
        $h.Add("<h3>$(& $e $name)</h3><table><tr>$(($props | ForEach-Object { "<th>$(& $e $_)</th>" }) -join '')</tr>")
        foreach ($r in $rows) { $h.Add("<tr>$(($props | ForEach-Object { "<td>$(& $e $r.$_)</td>" }) -join '')</tr>") }
        $h.Add('</table>')
    }
    $h.Add('<h2>Action log</h2><table><tr><th>Time</th><th>Module</th><th>Result</th><th>Details</th></tr>')
    foreach ($a in $script:Actions) { $h.Add("<tr><td>$(& $e $a.Time)</td><td>$(& $e $a.Module)</td><td>$(& $e $a.Status)</td><td>$(& $e $a.Details)</td></tr>") }
    $h.Add("</table><p class='sub'>Console log: $(& $e $script:LogPath)</p><script>document.querySelectorAll('#flt button').forEach(function(b){b.onclick=function(){var f=b.dataset.f;document.querySelectorAll('.card').forEach(function(c){c.style.display=(f==='all'||c.dataset.sev===f)?'':'none'})}})</script></main></body></html>")
    return ($h -join "`n")
}

function Save-Report {
    Get-SnapshotDiff
    $saved = @()
    $md = New-MarkdownReport
    $p = Write-ReportFile -Path $script:ReportPath -Content $md
    if ($p) { $script:ReportPath = $p; $saved += $p }
    if ($script:ReportFormats -contains 'Html') {
        $p = Write-ReportFile -Path "$($script:ReportBase).html" -Content (New-HtmlReport)
        if ($p) { $saved += $p }
    }
    if ($script:ReportFormats -contains 'Json') {
        $data = [ordered]@{
            Version = $script:Version; Date = (Get-Date).ToString('o'); Computer = $env:COMPUTERNAME; DryRun = $script:DryRun
            RebootNeeded = $script:RebootNeeded; RebootReasons = $script:RebootReasons.ToArray(); Win11Block = $script:Win11BlockState
            # .ToArray(): @() on an empty List[object] throws "Argument types do not match" in Windows PowerShell 5.1
            Facts = $script:Facts; Findings = $script:Findings.ToArray(); Tables = $script:Tables; Actions = $script:Actions.ToArray()
        }
        $p = Write-ReportFile -Path "$($script:ReportBase).json" -Content ($data | ConvertTo-Json -Depth 6)
        if ($p) { $saved += $p }
    }
    Save-Snapshot
    foreach ($s in $saved) { Write-Host "  Report saved: $s" -ForegroundColor Green }
    return ($saved.Count -gt 0)
}

