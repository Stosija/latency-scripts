#Requires -Version 7.0

<#
.SYNOPSIS
Finds candidate application correlation IDs in Log Analytics.

.DESCRIPTION
Searches Container Apps console and HTTP logs plus workspace-based Application
Insights telemetry for explicit application correlation fields. When an explicit
correlation value is unavailable, Application Insights operation IDs are returned
as fallback candidates and identified as such.

Use the selected ID with Invoke-LatencyDiagnostic.ps1 -RunId and the same UTC
window. An Application Insights operation ID is only suitable for cross-service
correlation when the application propagates it to its downstream logs and headers.

.EXAMPLE
.\Find-CorrelationId.ps1 `
  -SubscriptionId "<subscription-id>" `
  -WorkspaceId "<workspace-customer-id-guid>" `
  -ProxyApp "<proxy-container-app>" `
  -StartUtc "2026-08-20T17:00:00Z" `
  -EndUtc "2026-08-20T17:15:00Z"

.EXAMPLE
.\Find-CorrelationId.ps1 `
  -SubscriptionId "<subscription-id>" `
  -WorkspaceId "<workspace-customer-id-guid>" `
  -ProxyApp "<proxy-container-app>" `
  -SearchText "/v1/responses" `
  -Hours 2 `
  -OnlyExplicitCorrelationIds
#>

[CmdletBinding(DefaultParameterSetName = "Lookback")]
param(
    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$SubscriptionId,

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$WorkspaceId,

    [string]$ProxyApp,

    [string]$SearchText,

    [Parameter(ParameterSetName = "Window", Mandatory)]
    [datetime]$StartUtc,

    [Parameter(ParameterSetName = "Window", Mandatory)]
    [datetime]$EndUtc,

    [Parameter(ParameterSetName = "Lookback")]
    [ValidateRange(1, 168)]
    [int]$Hours = 4,

    [ValidateRange(1, 500)]
    [int]$MaxResults = 50,

    [switch]$OnlyExplicitCorrelationIds,

    [string]$OutputPath,

    [switch]$QueryOnly
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function ConvertTo-KqlString {
    param([AllowEmptyString()][string]$Value)

    if ($null -eq $Value) {
        return ""
    }
    return $Value.Replace("'", "''")
}

if ($PSCmdlet.ParameterSetName -eq "Lookback") {
    $EndUtc = [DateTime]::UtcNow
    $StartUtc = $EndUtc.AddHours(-$Hours)
}

$StartUtc = $StartUtc.ToUniversalTime()
$EndUtc = $EndUtc.ToUniversalTime()
if ($StartUtc -ge $EndUtc) {
    throw "StartUtc must be earlier than EndUtc."
}

$startIso = $StartUtc.ToString("o")
$endIso = $EndUtc.ToString("o")
$proxyFilter = ConvertTo-KqlString -Value $ProxyApp
$textFilter = ConvertTo-KqlString -Value $SearchText
$explicitFilter = if ($OnlyExplicitCorrelationIds) {
    "| where IdType == 'Explicit application correlation ID'"
}
else {
    ""
}

$query = @"
let start=datetime($startIso);
let end=datetime($endIso);
let proxyApp='$proxyFilter';
let searchText='$textFilter';
union isfuzzy=true
    (ContainerAppConsoleLogs_CL
    | project TimeGenerated,
        SourceTable='ContainerAppConsoleLogs_CL',
        AppName=tostring(column_ifexists('ContainerAppName_s', '')),
        OperationId='',
        Record=tostring(pack_all())),
    (ContainerAppConsoleLogs
    | project TimeGenerated,
        SourceTable='ContainerAppConsoleLogs',
        AppName=tostring(column_ifexists('ContainerAppName', '')),
        OperationId='',
        Record=tostring(pack_all())),
    (ContainerAppHTTPLogs
    | project TimeGenerated,
        SourceTable='ContainerAppHTTPLogs',
        AppName=tostring(column_ifexists('ContainerAppName', '')),
        OperationId=tostring(column_ifexists('RequestId', '')),
        Record=tostring(pack_all())),
    (requests
    | project TimeGenerated=timestamp,
        SourceTable='requests',
        AppName=tostring(cloud_RoleName),
        OperationId=tostring(operation_Id),
        Record=tostring(pack_all())),
    (traces
    | project TimeGenerated=timestamp,
        SourceTable='traces',
        AppName=tostring(cloud_RoleName),
        OperationId=tostring(operation_Id),
        Record=tostring(pack_all())),
    (customEvents
    | project TimeGenerated=timestamp,
        SourceTable='customEvents',
        AppName=tostring(cloud_RoleName),
        OperationId=tostring(operation_Id),
        Record=tostring(pack_all()))
| where TimeGenerated between (start .. end)
| where isempty(proxyApp) or AppName =~ proxyApp or Record has proxyApp
| where isempty(searchText) or Record contains searchText
| extend ExplicitId=extract(
    @"(?i)(?:x-client-request-id|x-correlation-id|request_id|requestId|correlation_id|correlationId)[^A-Za-z0-9]+([A-Za-z0-9][A-Za-z0-9._:-]{7,127})",
    1,
    Record)
| extend CorrelationId=coalesce(ExplicitId, OperationId)
| extend IdType=iff(
    isnotempty(ExplicitId),
    'Explicit application correlation ID',
    'Application Insights operation_Id fallback')
| where isnotempty(CorrelationId)
$explicitFilter
| summarize
    FirstSeenUtc=min(TimeGenerated),
    LastSeenUtc=max(TimeGenerated),
    EventCount=count(),
    Sources=make_set(SourceTable, 10),
    Applications=make_set(AppName, 10)
    by CorrelationId, IdType
| order by LastSeenUtc desc
| take $MaxResults
"@

if ($QueryOnly) {
    $query
    return
}

if (-not (Get-Command "az" -ErrorAction SilentlyContinue)) {
    throw "Required command 'az' was not found. Install Azure CLI and retry."
}

& az account set --subscription $SubscriptionId
if ($LASTEXITCODE -ne 0) {
    throw "Could not select Azure subscription '$SubscriptionId'."
}

$rawResult = & az monitor log-analytics query `
    --workspace $WorkspaceId `
    --analytics-query $query `
    --output json 2>&1
$exitCode = $LASTEXITCODE

if ($exitCode -ne 0) {
    throw "Log Analytics query failed.`n$($rawResult -join [Environment]::NewLine)"
}

$json = $rawResult -join [Environment]::NewLine
if (-not [string]::IsNullOrWhiteSpace($OutputPath)) {
    $parent = Split-Path -Parent $OutputPath
    if (-not [string]::IsNullOrWhiteSpace($parent)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }
    $json | Set-Content -LiteralPath $OutputPath -Encoding utf8
}

$results = @($json | ConvertFrom-Json)
if ($results.Count -eq 0) {
    Write-Warning "No candidate IDs were found. Widen the UTC window, remove filters, or confirm that the proxy emits request_id or a correlation header."
    return
}

$results |
    Select-Object CorrelationId, IdType, FirstSeenUtc, LastSeenUtc, EventCount,
        @{ Name = "Sources"; Expression = { $_.Sources -join ", " } },
        @{ Name = "Applications"; Expression = { $_.Applications -join ", " } } |
    Format-Table -AutoSize

if (-not $OnlyExplicitCorrelationIds -and
    @($results | Where-Object { $_.IdType -like "*fallback" }).Count -gt 0) {
    Write-Warning "operation_Id values are fallbacks. Use one as -RunId only if the application propagates it to downstream headers or logs."
}
