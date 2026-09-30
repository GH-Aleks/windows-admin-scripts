@{
    # Standardregeln plus Syntax-Kompatibilitaet zu Windows PowerShell 5.1 und PowerShell 7
    IncludeDefaultRules = $true
    Severity            = @('Error', 'Warning', 'Information')
    Rules               = @{
        PSUseCompatibleSyntax = @{
            Enable         = $true
            TargetVersions = @('5.1', '7.0')
        }
    }
}
