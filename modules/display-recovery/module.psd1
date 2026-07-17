@{
    SchemaVersion = 1
    Id = 'display-recovery'
    DisplayNameKey = 'modules.displayRecovery.name'
    DescriptionKey = 'modules.displayRecovery.description'
    Handler = 'handler.ps1'
    SupportsDiagnose = $true
    SupportsRepair = $true
    RepairRequiresAdmin = $false
    Order = 15
    Enabled = $true
    Settings = @{
        TargetMonitorPattern = 'SE2425HG'
        ExpectedActiveDisplays = 3
        ExtendAttemptsBeforeOutputRefresh = 1
        OutputRefreshAttempts = 2
        ExtendAttemptsAfterScan = 2
        TopologyRefreshAttempts = 1
    }
}
