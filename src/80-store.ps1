# ----------------------------------------------------------------------------------------------
# 8. Microsoft Store / app updates
# ----------------------------------------------------------------------------------------------
function Invoke-StoreModule {
    $store = Get-AppxPackage -Name Microsoft.WindowsStore -ErrorAction SilentlyContinue
    if (-not $store) {
        Add-Finding -Id 'store-missing' -Severity 'Info' -Category 'Apps' -Title 'The Microsoft Store is not installed' `
            -Meaning 'Some editions (e.g. LTSC) have no Store, or it was removed. In that case there are no Store app updates either.' `
            -Recommendation "If it should be there: PowerShell (admin) 'Get-AppxPackage -AllUsers Microsoft.WindowsStore | ForEach-Object { Add-AppxPackage -DisableDevelopmentMode -Register `"`$(`$_.InstallLocation)\AppxManifest.xml`" }'." -Status 'Info'
        return
    }
    if (-not $script:Online) { Write-Bad 'No internet connection - Store updates skipped.'; Add-Action 'Store updates' 'Skipped' 'No internet connection.'; return }
    $done = $false

    # 1. winget (supported, silent, with progress output)
    $winget = Get-Command winget -ErrorAction SilentlyContinue
    if ($winget) {
        # Packages the user wants to keep at their current version (config: WingetPin = [ids])
        foreach ($pin in @($script:Config.WingetPin)) {
            if ($pin -and -not $script:DryRun) { Invoke-Native -File $winget.Source -Arguments @('pin', 'add', '--id', [string]$pin, '--accept-source-agreements') -Quiet -TimeoutSec 60 | Out-Null }
        }
        if (Confirm-Step 'Update Microsoft Store apps via winget now?') {
            Write-Info 'winget is updating the Store apps ... (may take a few minutes)'
            $r = Invoke-Native -File $winget.Source -Arguments @('upgrade', '--all', '--source', 'msstore', '--silent', '--accept-package-agreements', '--accept-source-agreements', '--disable-interactivity') -Quiet
            $lines = $r.Output -split "`n" | Where-Object { $_ -and $_ -notmatch '^[\s\\|/\-]*$' -and $_ -notmatch '[█▒]' }
            $lines | Select-Object -First 25 | ForEach-Object { Write-Host "       $_" -ForegroundColor DarkGray }
            # The patterns also match the German winget output (localized Windows).
            $okCount = @($lines | Where-Object { $_ -match 'Successfully installed|Erfolgreich installiert' }).Count
            $failCount = @($lines | Where-Object { $_ -match 'Installer failed|Installationsprogramm.*fehlgeschlagen|install failed|Installation failed' }).Count
            Add-Action 'Store updates (winget)' $(if ($r.ExitCode -eq 0) { 'Success' } else { 'Note' }) "Return code $($r.ExitCode); installed: $okCount; errors: $failCount."
            if ($r.ExitCode -eq 0 -or $okCount -gt 0) { $done = $true }
            if ($failCount -gt 0) {
                Add-Finding -Id 'store-app-error' -Severity 'Low' -Category 'Apps' -Title "$failCount Store app(s) could not be updated" `
                    -Meaning 'An app could not be updated, e.g. because it is currently running or the Store cache is corrupted.' `
                    -Recommendation 'Close the apps and run again; if that does not help, open "Downloads and updates" in the Store or run "wsreset.exe" (only resets the Store cache).'
            }
        }
        # Third-party desktop apps (Git, 7-Zip, VLC, ...) from the winget community repository
        $pending = (Invoke-Native -File $winget.Source -Arguments @('upgrade', '--source', 'winget', '--accept-source-agreements', '--disable-interactivity') -Quiet -TimeoutSec 300).Output
        $m = [regex]::Match($pending, '(\d+)\s+(upgrades? available|Aktualisierungen verf)')
        if ($m.Success -and [int]$m.Groups[1].Value -gt 0) {
            Write-Info "$($m.Groups[1].Value) desktop app update(s) are available through winget."
            Add-Fact 'Desktop apps with updates (winget)' $m.Groups[1].Value
            if (Confirm-Step "Update these $($m.Groups[1].Value) desktop apps via winget as well? (Apps in use may be closed or skipped)" -Default $false -Risky) {
                $r2 = Invoke-Native -File $winget.Source -Arguments @('upgrade', '--all', '--source', 'winget', '--silent', '--accept-package-agreements', '--accept-source-agreements', '--disable-interactivity') -Quiet -TimeoutSec 3600
                Add-Action 'App updates (winget)' $(if ($r2.ExitCode -eq 0) { 'Success' } else { 'Note' }) "Return code $($r2.ExitCode)."
            } else {
                Add-Finding -Id 'winget-desktop-updates' -Severity 'Info' -Category 'Apps' -Title "$($m.Groups[1].Value) desktop app(s) can be updated via winget" `
                    -Meaning 'Outdated browsers, archivers and media players are a common way for malware to get in.' `
                    -Recommendation "Run 'winget upgrade' in a terminal to list them, then 'winget upgrade --all' to update." -Status 'Info'
            }
        }
    } else {
        Write-Info 'winget (App Installer) is not installed - Store updates run via the Store background scan.'
    }

    # 2. Trigger the Store background update scan
    try {
        $inst = Get-CimInstance -Namespace 'root\cimv2\mdm\dmmap' -ClassName 'MDM_EnterpriseModernAppManagement_AppManagement01' -ErrorAction Stop
        Invoke-CimMethod -InputObject $inst -MethodName UpdateScanMethod -ErrorAction Stop | Out-Null
        Write-Ok 'Store background scan triggered (updates are downloaded in the background).'
        Add-Action 'Store updates' 'Triggered' 'UpdateScanMethod triggered.'
        $done = $true
    } catch { Write-Info 'The Store background scan is not available on this system.' }

    # 3. Open the Store page for verification
    Add-Finding -Id 'store-check' -Severity 'Info' -Category 'Apps' -Title 'Please check the Store updates once in the Store' `
        -Meaning 'There is no official interface with which a script can reliably confirm that all Store apps are really up to date.' `
        -Recommendation "Open Microsoft Store > 'Library' (or 'Downloads and updates') > 'Get updates'." -Status 'Info'
    if (-not $done -or (Confirm-Step 'Open the Microsoft Store on the update page now to check the result and click "Get updates" if needed?' -Default $false)) {
        try { Start-Process 'ms-windows-store://downloadsandupdates'; Add-Action 'Store updates' 'Store opened' 'Update page was opened.' } catch { Write-Warn2 'The Store could not be opened.' }
    }
}

