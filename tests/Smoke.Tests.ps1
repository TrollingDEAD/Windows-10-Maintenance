BeforeDiscovery {
    $script:IsAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

Describe 'Dry-run smoke test' -Skip:(-not $script:IsAdmin) {
    BeforeAll {
        $script:Script = Join-Path $PSScriptRoot '..\Windows10_SystemMaintenance.ps1'
        $script:Out = Join-Path ([IO.Path]::GetTempPath()) ("w10m_smoke_" + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:Out | Out-Null
        $args2 = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $script:Script, '-NoElevate', '-Auto', '-Quiet', '-DryRun',
            '-Modules', 'sys,disk,sec,audit,rec,svc', '-ReportPath', $script:Out, '-ReportFormat', 'Markdown,Html,Json')
        $p = Start-Process -FilePath "$env:WINDIR\System32\WindowsPowerShell\v1.0\powershell.exe" -ArgumentList $args2 -Wait -PassThru -WindowStyle Hidden
        $script:Exit = $p.ExitCode
    }
    AfterAll { Remove-Item -LiteralPath $script:Out -Recurse -Force -ErrorAction SilentlyContinue }

    It 'finishes with a defined exit code' { $script:Exit | Should -BeIn 0, 10, 11, 12 }
    It 'writes the Markdown report' { Get-ChildItem $script:Out -Filter 'Windows10_SystemReport_*.md' | Should -Not -BeNullOrEmpty }
    It 'writes the HTML report' { Get-ChildItem $script:Out -Filter 'Windows10_SystemReport_*.html' | Should -Not -BeNullOrEmpty }
    It 'writes a JSON report that matches the schema' {
        $f = Get-ChildItem $script:Out -Filter 'Windows10_SystemReport_*.json' | Select-Object -First 1
        $f | Should -Not -BeNullOrEmpty
        $json = Get-Content -LiteralPath $f.FullName -Raw -Encoding UTF8
        $obj = $json | ConvertFrom-Json
        $obj.DryRun | Should -BeTrue
        $obj.Findings | Should -Not -BeNullOrEmpty
        if (Get-Command Test-Json -ErrorAction SilentlyContinue) {
            Test-Json -Json $json -SchemaFile (Join-Path $PSScriptRoot '..\schema\report.schema.json') | Should -BeTrue
        }
    }
}
