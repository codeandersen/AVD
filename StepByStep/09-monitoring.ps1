#Requires -Modules Az.Accounts, Az.Resources, Az.OperationalInsights, Az.Monitor, Az.DesktopVirtualization
<#
.SYNOPSIS
    Phase 9/10 – Configure Azure Monitor, AVD Insights, and alerts.
.DESCRIPTION
    Creates a Log Analytics workspace, enables diagnostic settings on the host
    pool, workspace and session hosts, configures AVD Insights, and sets up a
    heartbeat alert to notify when a session host stops responding.
.NOTES
    Steps covered: 74–76 from the deployment plan.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

. "$PSScriptRoot\config.ps1"

Write-Host "`n=== Phase 9/10: Monitoring & Alerts ===" -ForegroundColor Cyan

# Connect
if (-not (Get-AzContext -ErrorAction SilentlyContinue)) {
    Connect-AzAccount -Subscription $AzSubscriptionId
} else {
    Set-AzContext -Subscription $AzSubscriptionId | Out-Null
    Write-Host "Using Azure context: $((Get-AzContext).Subscription.Name)" -ForegroundColor Gray
}

foreach ($mod in @("Az.OperationalInsights","Az.Monitor","Az.DesktopVirtualization")) {
    if (-not (Get-Module -ListAvailable -Name $mod)) {
        Install-Module $mod -Scope CurrentUser -Force -AllowClobber
    }
}
Import-Module Az.OperationalInsights, Az.Monitor, Az.DesktopVirtualization

$alertEmail = Read-Host "Enter email address for monitoring alerts"

# -----------------------------------------------------------------------------
# Step 75 – Create Log Analytics Workspace
# -----------------------------------------------------------------------------
Write-Host "`n[Step 75] Creating Log Analytics Workspace '$LogAnalyticsName'..." -ForegroundColor Yellow

$law = Get-AzOperationalInsightsWorkspace `
    -ResourceGroupName $AzResourceGroup `
    -Name              $LogAnalyticsName `
    -ErrorAction SilentlyContinue

if (-not $law) {
    $law = New-AzOperationalInsightsWorkspace `
        -ResourceGroupName $AzResourceGroup `
        -Name              $LogAnalyticsName `
        -Location          $AzLocation `
        -Sku               "PerGB2018" `
        -RetentionInDays   30
    Write-Host "  Created: $LogAnalyticsName" -ForegroundColor Green
} else {
    Write-Host "  Already exists, skipping." -ForegroundColor Gray
}

$lawId = $law.ResourceId

# -----------------------------------------------------------------------------
# Step 74 – Enable Diagnostic Settings on Host Pool
# -----------------------------------------------------------------------------
Write-Host "`n[Step 74] Enabling diagnostic settings on Host Pool '$HostPoolName'..." -ForegroundColor Yellow

$hostPool   = Get-AzWvdHostPool -ResourceGroupName $AzResourceGroup -Name $HostPoolName
$hostPoolId = $hostPool.Id

$existingDiag = Get-AzDiagnosticSetting -ResourceId $hostPoolId -ErrorAction SilentlyContinue |
    Where-Object { $_.WorkspaceId -eq $lawId }

if (-not $existingDiag) {
    $logCategories = @(
        "Checkpoint",
        "Error",
        "Management",
        "Connection",
        "HostRegistration",
        "AgentHealthStatus",
        "NetworkData",
        "SessionHostManagement",
        "AutoscaleEvaluationPooled"
    )
    $logSettings = $logCategories | ForEach-Object {
        New-AzDiagnosticSettingLogSettingsObject -Enabled $true -Category $_
    }

    Set-AzDiagnosticSetting `
        -ResourceId   $hostPoolId `
        -Name         "avd-hostpool-to-law" `
        -WorkspaceId  $lawId `
        -Log          $logSettings | Out-Null
    Write-Host "  Diagnostics enabled on host pool." -ForegroundColor Green
} else {
    Write-Host "  Diagnostics already configured, skipping." -ForegroundColor Gray
}

# Enable diagnostics on Workspace
Write-Host "  Enabling diagnostic settings on Workspace '$WorkspaceName'..." -ForegroundColor Yellow
$avdWorkspace   = Get-AzWvdWorkspace -ResourceGroupName $AzResourceGroup -Name $WorkspaceName
$avdWorkspaceId = $avdWorkspace.Id

$existingWsDiag = Get-AzDiagnosticSetting -ResourceId $avdWorkspaceId -ErrorAction SilentlyContinue |
    Where-Object { $_.WorkspaceId -eq $lawId }

if (-not $existingWsDiag) {
    $wsLogSettings = @("Checkpoint","Error","Management","Feed") | ForEach-Object {
        New-AzDiagnosticSettingLogSettingsObject -Enabled $true -Category $_
    }
    Set-AzDiagnosticSetting `
        -ResourceId  $avdWorkspaceId `
        -Name        "avd-workspace-to-law" `
        -WorkspaceId $lawId `
        -Log         $wsLogSettings | Out-Null
    Write-Host "  Diagnostics enabled on workspace." -ForegroundColor Green
} else {
    Write-Host "  Workspace diagnostics already configured, skipping." -ForegroundColor Gray
}

# Enable Azure Monitor agent on session hosts
Write-Host "  Enabling Azure Monitor Agent on session hosts..." -ForegroundColor Yellow
for ($i = 0; $i -lt $SessionHostCount; $i++) {
    $vmName = "$SessionHostPrefix-$i"
    # VMs are in the hosts RG
    $vm     = Get-AzVM -ResourceGroupName $AzResourceGroupHosts -Name $vmName -ErrorAction SilentlyContinue
    if (-not $vm) {
        Write-Warning "    VM '$vmName' not found in '$AzResourceGroupHosts' — skipping."
        continue
    }

    $amaExtension = Get-AzVMExtension -ResourceGroupName $AzResourceGroupHosts -VMName $vmName `
        -Name "AzureMonitorWindowsAgent" -ErrorAction SilentlyContinue
    if (-not $amaExtension) {
        Set-AzVMExtension `
            -ResourceGroupName  $AzResourceGroupHosts `
            -VMName             $vmName `
            -Name               "AzureMonitorWindowsAgent" `
            -Publisher          "Microsoft.Azure.Monitor" `
            -ExtensionType      "AzureMonitorWindowsAgent" `
            -TypeHandlerVersion "1.0" `
            -Location           $AzLocation `
            -EnableAutomaticUpgrade $true | Out-Null
        Write-Host "    AMA installed on $vmName" -ForegroundColor Green
    } else {
        Write-Host "    AMA already installed on $vmName" -ForegroundColor Gray
    }
}

# -----------------------------------------------------------------------------
# Step 76 – Create Alert Action Group (email notification)
# -----------------------------------------------------------------------------
Write-Host "`n[Step 76] Creating alert action group..." -ForegroundColor Yellow

$actionGroupName    = "ag-avd-admins"
$actionGroupShort   = "avdadmins"
$existingActionGroup = Get-AzActionGroup `
    -ResourceGroupName $AzResourceGroup `
    -Name              $actionGroupName `
    -ErrorAction SilentlyContinue

if (-not $existingActionGroup) {
    $emailReceiver = New-AzActionGroupEmailReceiverObject `
        -Name                 "AVD Admin" `
        -EmailAddress         $alertEmail `
        -UseCommonAlertSchema $true

    $actionGroup = Set-AzActionGroup `
        -ResourceGroupName $AzResourceGroup `
        -Name              $actionGroupName `
        -ShortName         $actionGroupShort `
        -EmailReceiver     @($emailReceiver)
    Write-Host "  Created action group: $actionGroupName (email: $alertEmail)" -ForegroundColor Green
} else {
    Write-Host "  Action group already exists, skipping." -ForegroundColor Gray
    $actionGroup = $existingActionGroup
}

$actionGroupId = $actionGroup.Id

# Create Session Host Heartbeat alert (fires when a host stops responding)
Write-Host "  Creating session host heartbeat alert..." -ForegroundColor Yellow
$alertName = "AVD - Session Host Down"

$existingAlert = Get-AzScheduledQueryRule `
    -ResourceGroupName $AzResourceGroup `
    -Name              $alertName `
    -ErrorAction SilentlyContinue

if (-not $existingAlert) {
    $alertCondition = New-AzScheduledQueryRuleConditionObject `
        -Query @"
Heartbeat
| where Computer startswith "$SessionHostPrefix"
| summarize LastHeartbeat = max(TimeGenerated) by Computer
| where LastHeartbeat < ago(5m)
"@ `
        -TimeAggregation "Count" `
        -Operator        "GreaterThan" `
        -Threshold       0 `
        -FailingPeriodNumberOfEvaluationPeriod 1 `
        -FailingPeriodMinFailingPeriodsToAlert  1

    New-AzScheduledQueryRule `
        -ResourceGroupName    $AzResourceGroup `
        -Name                 $alertName `
        -Location             $AzLocation `
        -DisplayName          $alertName `
        -Description          "Fires when an AVD session host has not sent a heartbeat for 5+ minutes" `
        -Scope                @($lawId) `
        -Severity             2 `
        -Enabled              $true `
        -EvaluationFrequency  "PT5M" `
        -WindowSize           "PT10M" `
        -CriterionAllOf       @($alertCondition) `
        -Action               @{ ActionGroup = @($actionGroupId) } | Out-Null
    Write-Host "  Alert '$alertName' created." -ForegroundColor Green
} else {
    Write-Host "  Alert already exists, skipping." -ForegroundColor Gray
}

# Create AVD User Connection Failure alert
$connAlertName = "AVD - Connection Failures Spike"
$existingConnAlert = Get-AzScheduledQueryRule `
    -ResourceGroupName $AzResourceGroup `
    -Name              $connAlertName `
    -ErrorAction SilentlyContinue

if (-not $existingConnAlert) {
    $connAlertCondition = New-AzScheduledQueryRuleConditionObject `
        -Query @"
WVDConnections
| where TimeGenerated > ago(15m)
| where State == "Failed"
| summarize FailureCount = count() by bin(TimeGenerated, 5m)
| where FailureCount > 5
"@ `
        -TimeAggregation "Count" `
        -Operator        "GreaterThan" `
        -Threshold       0 `
        -FailingPeriodNumberOfEvaluationPeriod 1 `
        -FailingPeriodMinFailingPeriodsToAlert  1

    New-AzScheduledQueryRule `
        -ResourceGroupName    $AzResourceGroup `
        -Name                 $connAlertName `
        -Location             $AzLocation `
        -DisplayName          $connAlertName `
        -Description          "Fires when more than 5 AVD connection failures occur in a 5-minute window" `
        -Scope                @($lawId) `
        -Severity             3 `
        -Enabled              $true `
        -EvaluationFrequency  "PT5M" `
        -WindowSize           "PT15M" `
        -CriterionAllOf       @($connAlertCondition) `
        -Action               @{ ActionGroup = @($actionGroupId) } | Out-Null
    Write-Host "  Alert '$connAlertName' created." -ForegroundColor Green
} else {
    Write-Host "  Connection failure alert already exists, skipping." -ForegroundColor Gray
}

# -----------------------------------------------------------------------------
# AVD Insights workbook reminder
# -----------------------------------------------------------------------------
Write-Host "`n[AVD Insights] Final step — open in Portal:" -ForegroundColor Yellow
Write-Host "  1. Azure Portal > Azure Virtual Desktop > Insights"
Write-Host "  2. Select host pool '$HostPoolName'"
Write-Host "  3. Click 'Open configuration workbook' if prompted"
Write-Host "  4. Link all diagnostic resources to Log Analytics workspace '$LogAnalyticsName'"
Write-Host "  5. Verify the Connection Diagnostics and User Report tabs populate after first connections"

Write-Host "`n=== Phase 9/10 Complete ===" -ForegroundColor Cyan
Write-Host ""
Write-Host "Deployment summary:" -ForegroundColor White
Write-Host "  Host pool      : $HostPoolName" -ForegroundColor Gray
Write-Host "  Session hosts  : $SessionHostPrefix-0, $SessionHostPrefix-1" -ForegroundColor Gray
Write-Host "  Workspace      : $WorkspaceName" -ForegroundColor Gray
Write-Host "  Profiles share : \\$StorageAccountName.file.core.windows.net\$FileShareName" -ForegroundColor Gray
Write-Host "  Log Analytics  : $LogAnalyticsName" -ForegroundColor Gray
Write-Host "  Alerts email   : $alertEmail" -ForegroundColor Gray
Write-Host ""
Write-Host "Testing checklist is in portal-guide.md Phase 9." -ForegroundColor White
