BeforeAll {
    $script:ScriptPath = Join-Path $PSScriptRoot '..\Windows10_SystemMaintenance.ps1'
}

Describe 'Windows10_SystemMaintenance.ps1' {
    It 'exists' {
        Test-Path -LiteralPath $script:ScriptPath | Should -BeTrue
    }

    It 'parses without syntax errors' {
        $errors = $null
        [void][System.Management.Automation.Language.Parser]::ParseFile($script:ScriptPath, [ref]$null, [ref]$errors)
        $errors | Should -BeNullOrEmpty
    }

    It 'declares the expected parameters' {
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($script:ScriptPath, [ref]$null, [ref]$null)
        $names = $ast.ParamBlock.Parameters.Name.VariablePath.UserPath
        $names | Should -Contain 'Auto'
        $names | Should -Contain 'SkipRestorePoint'
        $names | Should -Contain 'NoElevate'
    }

    It 'only defines functions with approved verbs' {
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($script:ScriptPath, [ref]$null, [ref]$null)
        $approved = (Get-Verb).Verb
        $funcs = $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true)
        $bad = $funcs | Where-Object { $_.Name -match '^(\w+)-' -and $Matches[1] -notin $approved } | ForEach-Object Name
        $bad | Should -BeNullOrEmpty
    }
}

Describe 'Behaviour of extracted helper functions' {
    BeforeAll {
        # Load single functions from the script without executing it (the script runs on load).
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($script:ScriptPath, [ref]$null, [ref]$null)
        $want = 'Get-UpdateKind', 'Get-BackupFolderAge', 'Format-Size', 'Get-WuErrorInfo'
        $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -in $want }, $true) |
            ForEach-Object { . ([scriptblock]::Create($_.Extent.Text)) }
        function New-FakeUpdate($Title, $Categories = @()) {
            [pscustomobject]@{ Title = $Title; Categories = @($Categories | ForEach-Object { [pscustomobject]@{ Name = $_ } }) }
        }
    }

    It 'treats monthly cumulative updates as normal updates, not feature updates' {
        Get-UpdateKind (New-FakeUpdate '2025-09 Cumulative Update for Windows 10 Version 22H2 for x64-based Systems (KB5065429)') | Should -Be 'Normal'
    }
    It 'recognises preview updates before anything else' {
        Get-UpdateKind (New-FakeUpdate '2025-09 Cumulative Update Preview for Windows 10 Version 22H2 for x64-based Systems') | Should -Be 'Preview'
    }
    It 'recognises the Windows 10 feature update' {
        Get-UpdateKind (New-FakeUpdate 'Feature update to Windows 10, version 22H2' 'Upgrades') | Should -Be 'Feature10'
    }
    It 'recognises Windows 11 offers' {
        Get-UpdateKind (New-FakeUpdate 'Feature update to Windows 11, version 24H2' 'Upgrades') | Should -Be 'Win11'
    }
    It 'reads the age of a backup folder from its name, not from its timestamp' {
        Get-BackupFolderAge ([pscustomobject]@{ Name = 'SoftwareDistribution.bak_20200101_000000' }) | Should -BeGreaterThan 365
        Get-BackupFolderAge ([pscustomobject]@{ Name = ('SoftwareDistribution.bak_' + (Get-Date -Format 'yyyyMMdd_HHmmss')) }) | Should -BeLessThan 1
    }
    It 'formats sizes' {
        Format-Size 2GB | Should -Match 'GB'
    }
    It 'knows common update error codes' {
        (Get-WuErrorInfo '0x80070422').M | Should -Match 'disabled'
    }
}

Describe 'New parameters' {
    BeforeAll {
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($script:ScriptPath, [ref]$null, [ref]$null)
        $script:ParamNames = $ast.ParamBlock.Parameters.Name.VariablePath.UserPath
    }
    It 'exposes <_>' -ForEach 'DryRun', 'Modules', 'ReportPath', 'ReportFormat', 'LogRetentionDays', 'Schedule', 'Unschedule', 'AllowOnBattery' {
        $script:ParamNames | Should -Contain $_
    }
}

Describe 'Repository consistency' {
    It 'keeps the version in the script and the newest CHANGELOG entry in sync' {
        $script:ver = [regex]::Match((Get-Content -LiteralPath $script:ScriptPath -Raw), "\`$script:Version = '([^']+)'").Groups[1].Value
        $log = Get-Content -LiteralPath (Join-Path $PSScriptRoot '..\CHANGELOG.md') -Raw
        $top = [regex]::Match($log, '(?m)^## \[(\d+\.\d+(\.\d+)?)\]').Groups[1].Value
        $script:ver | Should -Not -BeNullOrEmpty
        $top | Should -Be $script:ver
    }
    It 'has the built script equal to src/ (run tools/Build-Script.ps1)' {
        & (Join-Path $PSScriptRoot '..\tools\Build-Script.ps1') -Check
        $LASTEXITCODE | Should -Be 0
    }
    It 'has an up-to-date docs/FINDINGS.md (run tools/New-FindingDocs.ps1)' {
        & (Join-Path $PSScriptRoot '..\tools\New-FindingDocs.ps1') -Check
        $LASTEXITCODE | Should -Be 0
    }
    It 'documents every finding ID prefix exactly once' {
        $md = Get-Content -LiteralPath (Join-Path $PSScriptRoot '..\docs\FINDINGS.md') -Raw
        $ids = [regex]::Matches($md, '(?m)^<a id="([^"]+)"></a>$') | ForEach-Object { $_.Groups[1].Value }
        ($ids | Group-Object | Where-Object Count -gt 1) | Should -BeNullOrEmpty
    }
}

Describe 'Safety invariants in the source' {
    BeforeAll { $script:Src = Get-Content -LiteralPath $script:ScriptPath -Raw }
    It 'never disables Defender real-time protection' {
        $script:Src | Should -Not -Match 'DisableRealtimeMonitoring\s+\$true'
    }
    It 'only turns a firewall profile off inside the undo handler' {
        ([regex]::Matches($script:Src, 'Set-NetFirewallProfile[^\n]*-Enabled\s+(False|\$false)')).Count | Should -BeLessOrEqual 1
    }
    It 'only uses https for the webhook' {
        $script:Src | Should -Match "notmatch '\^https://'"
    }
    It 'gates the Recycle Bin behind a Risky confirmation' {
        $script:Src | Should -Match "Permanently empty the Recycle Bin[^\n]*-Risky"
    }
}

Describe 'Redaction and health score' {
    BeforeAll {
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($script:ScriptPath, [ref]$null, [ref]$null)
        $want = 'Protect-ReportText', 'Get-HealthScore'
        $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -in $want }, $true) |
            ForEach-Object { . ([scriptblock]::Create($_.Extent.Text)) }
        $script:SevRank = @{ 'Critical' = 0; 'High' = 1; 'Medium' = 2; 'Low' = 3; 'Info' = 4 }
    }
    It 'masks IP and MAC addresses when -Redact is on' {
        $script:Redact = $true
        $r = Protect-ReportText 'Gateway 192.168.1.1 mac AA:BB:CC:DD:EE:FF loopback 127.0.0.1 version 10.0.19045.6456'
        $r | Should -Match 'x\.x\.x\.x'
        $r | Should -Match 'xx:xx:xx:xx:xx:xx'
        $r | Should -Match '127\.0\.0\.1'
        $r | Should -Match '10\.0\.19045\.6456'
    }
    It 'does nothing when -Redact is off' {
        $script:Redact = $false
        Protect-ReportText 'Gateway 192.168.1.1' | Should -Be 'Gateway 192.168.1.1'
    }
    It 'scores 100 with no findings and drops with severity' {
        $script:Findings = New-Object System.Collections.Generic.List[object]
        (Get-HealthScore).Score | Should -Be 100
        $script:Findings.Add([pscustomobject]@{ Status = 'Open'; Severity = 'High' })
        $script:Findings.Add([pscustomobject]@{ Status = 'Open'; Severity = 'Medium' })
        $script:Findings.Add([pscustomobject]@{ Status = 'Fixed'; Severity = 'Critical' })
        (Get-HealthScore).Score | Should -Be 83
    }
}
