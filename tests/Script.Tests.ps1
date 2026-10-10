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
