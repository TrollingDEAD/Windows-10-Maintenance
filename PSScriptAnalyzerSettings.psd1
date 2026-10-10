@{
    Severity     = @('Error', 'Warning')
    ExcludeRules = @(
        # Interactive console tool: coloured Write-Host output is intentional.
        'PSAvoidUsingWriteHost'
        # Internal helpers; the script confirms risky steps itself via Confirm-Step.
        'PSUseShouldProcessForStateChangingFunctions'
        # Source file is saved with a UTF-8 BOM on purpose (Windows PowerShell 5.1).
        'PSUseBOMForUnicodeEncodedFile'
        # Diagnostics are best-effort probes (WMI classes, registry values and cmdlets that are missing on some
        # editions); a failing probe must never abort the run, so swallowing the error is intentional.
        'PSAvoidUsingEmptyCatchBlock'
        # Internal function names such as Invoke-SystemDiagnostics read better than their singular forms.
        'PSUseSingularNouns'
    )
}
