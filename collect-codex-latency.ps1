[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$SubscriptionId,

    [Parameter(Mandatory)]
    [string]$ResourceGroup,

    [Parameter(Mandatory)]
    [string]$ApplicationName,

    [Parameter(Mandatory)]
    [string]$ProxyContainerAppName,

    [Parameter(Mandatory)]
    [string]$OpenWebUiContainerAppName,

    [Parameter(Mandatory)]
    [string]$AzureOpenAIResourceName,

    [Parameter(Mandatory)]
    [string]$AzureOpenAIDeploymentName,

    [Parameter(Mandatory)]
    [string]$PostgreSqlServerName,

    [Parameter(Mandatory)]
    [string]$EntraAppDisplayName,

    [string]$AzureOpenAIResourceGroup = $ResourceGroup,
    [string]$PostgreSqlResourceGroup = $ResourceGroup,
    [string]$WorkspaceCustomerId,
    [string]$LogAnalyticsWorkspaceResourceId,
    [string]$DiagnosticSettingName = "$ApplicationName-latency-review",
    [string]$LoadBalancerResourceId,
    [switch]$SkipDiagnosticConfiguration,
    [switch]$SkipEntraDiagnostics,
    [switch]$SkipPostgreSqlQueryStoreConfiguration,
    [ValidateRange(1, 168)]
    [int]$Hours = 4,
    [string]$OutputPath = "."
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

function Invoke-Az {
    param(
        [Parameter(Mandatory)]
        [string[]]$Arguments
    )

    $output = & az @Arguments --only-show-errors 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "az $($Arguments -join ' ') failed:`n$($output -join [Environment]::NewLine)"
    }

    return $output
}

function Invoke-AzTsv {
    param(
        [Parameter(Mandatory)]
        [string[]]$Arguments
    )

    return ((Invoke-Az -Arguments ($Arguments + @("--output", "tsv"))) -join "`n").Trim()
}

function Export-AzJson {
    param(
        [Parameter(Mandatory)]
        [string[]]$Arguments,

        [Parameter(Mandatory)]
        [string]$Path
    )

    Invoke-Az -Arguments ($Arguments + @("--output", "json")) |
        Set-Content -Path $Path -Encoding utf8
}

function Invoke-AzJson {
    param(
        [Parameter(Mandatory)]
        [string[]]$Arguments
    )

    $json = (Invoke-Az -Arguments ($Arguments + @("--output", "json"))) -join "`n"
    return ($json | ConvertFrom-Json)
}

function Export-Metrics {
    param(
        [Parameter(Mandatory)]
        [string]$ResourceId,

        [Parameter(Mandatory)]
        [string[]]$DesiredMetrics,

        [Parameter(Mandatory)]
        [string]$Prefix
    )

    $definitionsPath = Join-Path $OutputPath "$Prefix-metric-definitions.json"
    Export-AzJson -Arguments @(
        "monitor", "metrics", "list-definitions",
        "--resource", $ResourceId
    ) -Path $definitionsPath

    $availableMetrics = @(
        Invoke-AzTsv -Arguments @(
            "monitor", "metrics", "list-definitions",
            "--resource", $ResourceId,
            "--query", "[].name.value"
        )
    ) -split "`r?`n"

    $missing = @($DesiredMetrics | Where-Object { $_ -notin $availableMetrics })
    if ($missing.Count -gt 0) {
        $missing | Set-Content (Join-Path $OutputPath "$Prefix-unavailable-metrics.txt")
    }

    foreach ($metric in ($DesiredMetrics | Where-Object { $_ -in $availableMetrics })) {
        $safeMetricName = $metric -replace "[^A-Za-z0-9_.-]", "_"
        $metricPath = Join-Path $OutputPath "$Prefix-metric-$safeMetricName.json"

        try {
            Export-AzJson -Arguments @(
                "monitor", "metrics", "list",
                "--resource", $ResourceId,
                "--metrics", $metric,
                "--interval", "PT1M",
                "--start-time", $script:StartTime,
                "--end-time", $script:EndTime
            ) -Path $metricPath
        }
        catch {
            $_.Exception.Message |
                Set-Content (Join-Path $OutputPath "$Prefix-metric-$safeMetricName-error.txt")
        }
    }
}

function Export-LogQuery {
    param(
        [Parameter(Mandatory)]
        [string]$Name,

        [Parameter(Mandatory)]
        [string]$Query
    )

    $queryPath = Join-Path $OutputPath "$Name.kql"
    $resultPath = Join-Path $OutputPath "$Name.json"
    $Query | Set-Content -Path $queryPath -Encoding utf8

    try {
        Export-AzJson -Arguments @(
            "monitor", "log-analytics", "query",
            "--workspace", $WorkspaceCustomerId,
            "--analytics-query", $Query,
            "--timespan", "$StartTime/$EndTime"
        ) -Path $resultPath
    }
    catch {
        $_.Exception.Message |
            Set-Content (Join-Path $OutputPath "$Name-error.txt")
    }
}

function Set-ResourceDiagnosticSetting {
    param(
        [Parameter(Mandatory)]
        [string]$ResourceId,

        [Parameter(Mandatory)]
        [string]$Prefix,

        [Parameter(Mandatory)]
        [string[]]$LogCategoryPatterns,

        [switch]$ExportToResourceSpecific
    )

    $categoryResponse = Invoke-AzJson -Arguments @(
        "monitor", "diagnostic-settings", "categories", "list",
        "--resource", $ResourceId
    )
    $categories = if ($categoryResponse.PSObject.Properties.Name -contains "value") {
        @($categoryResponse.value)
    }
    else {
        @($categoryResponse)
    }

    $availableLogs = @(
        $categories | Where-Object {
            $categoryType = if (
                $_.PSObject.Properties.Name -contains "categoryType"
            ) {
                $_.categoryType
            }
            elseif (
                $_.PSObject.Properties.Name -contains "properties" -and
                $_.properties.PSObject.Properties.Name -contains "categoryType"
            ) {
                $_.properties.categoryType
            }
            else {
                ""
            }
            $categoryType -eq "Logs"
        }
    )
    $availableMetrics = @(
        $categories | Where-Object {
            $categoryType = if (
                $_.PSObject.Properties.Name -contains "categoryType"
            ) {
                $_.categoryType
            }
            elseif (
                $_.PSObject.Properties.Name -contains "properties" -and
                $_.properties.PSObject.Properties.Name -contains "categoryType"
            ) {
                $_.properties.categoryType
            }
            else {
                ""
            }
            $categoryType -eq "Metrics"
        }
    )

    $selectedLogs = if ($LogCategoryPatterns.Count -gt 0) {
        @(
            $availableLogs | Where-Object {
                $category = $_
                $displayName = if (
                    $category.PSObject.Properties.Name -contains
                    "categoryDisplayName"
                ) {
                    [string]$category.categoryDisplayName
                }
                elseif (
                    $category.PSObject.Properties.Name -contains "properties" -and
                    $category.properties.PSObject.Properties.Name -contains
                    "categoryDisplayName"
                ) {
                    [string]$category.properties.categoryDisplayName
                }
                else {
                    ""
                }
                $LogCategoryPatterns | Where-Object {
                    $category.name -match $_ -or
                    $displayName -match $_
                }
            }
        )
    }
    else {
        @()
    }

    if ($LogCategoryPatterns.Count -gt 0 -and $selectedLogs.Count -eq 0) {
        throw "None of the requested diagnostic log categories are available for $ResourceId."
    }
    if ($selectedLogs.Count -eq 0 -and $availableMetrics.Count -eq 0) {
        throw "No requested logs or exportable metric categories are available for $ResourceId."
    }

    $logs = @(
        $selectedLogs | ForEach-Object {
            @{
                category = $_.name
                enabled = $true
            }
        }
    )
    $metrics = @(
        $availableMetrics | ForEach-Object {
            @{
                category = $_.name
                enabled = $true
            }
        }
    )

    $arguments = @(
        "monitor", "diagnostic-settings", "create",
        "--name", $DiagnosticSettingName,
        "--resource", $ResourceId,
        "--workspace", $LogAnalyticsWorkspaceResourceId
    )
    if ($logs.Count -gt 0) {
        $arguments += @(
            "--logs", (ConvertTo-Json -InputObject $logs -Depth 5 -Compress)
        )
    }
    if ($metrics.Count -gt 0) {
        $arguments += @(
            "--metrics", (ConvertTo-Json -InputObject $metrics -Depth 5 -Compress)
        )
    }
    if ($ExportToResourceSpecific) {
        $arguments += @("--export-to-resource-specific", "true")
    }

    Export-AzJson -Arguments $arguments -Path (
        Join-Path $OutputPath "$Prefix-diagnostic-setting-created.json"
    )
}

function Set-EntraDiagnosticSetting {
    $settingName = [Uri]::EscapeDataString($DiagnosticSettingName)
    $url = "https://management.azure.com/providers/microsoft.aadiam/" +
        "diagnosticSettings/$settingName?api-version=2017-04-01-preview"
    $body = @{
        properties = @{
            workspaceId = $LogAnalyticsWorkspaceResourceId
            logs = @(
                @{
                    category = "SignInLogs"
                    enabled = $true
                    retentionPolicy = @{
                        enabled = $false
                        days = 0
                    }
                },
                @{
                    category = "NonInteractiveUserSignInLogs"
                    enabled = $true
                    retentionPolicy = @{
                        enabled = $false
                        days = 0
                    }
                }
            )
            metrics = @()
        }
    } | ConvertTo-Json -Depth 8 -Compress

    try {
        Export-AzJson -Arguments @(
            "rest",
            "--method", "put",
            "--url", $url,
            "--body", $body
        ) -Path (Join-Path $OutputPath "entra-diagnostic-setting-created.json")
    }
    catch {
        $_.Exception.Message |
            Set-Content (Join-Path $OutputPath "entra-diagnostic-setting-error.txt")
    }
}

if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
    throw "Azure CLI is not installed or is not on PATH."
}

New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null
$OutputPath = (Resolve-Path $OutputPath).Path

$End = (Get-Date).ToUniversalTime()
$Start = $End.AddHours(-$Hours)
$script:StartTime = $Start.ToString("yyyy-MM-ddTHH:mm:ssZ")
$script:EndTime = $End.ToString("yyyy-MM-ddTHH:mm:ssZ")

Invoke-Az -Arguments @("account", "set", "--subscription", $SubscriptionId) | Out-Null
Export-AzJson -Arguments @("account", "show") -Path (Join-Path $OutputPath "azure-context.json")

$proxyId = Invoke-AzTsv -Arguments @(
    "containerapp", "show",
    "--name", $ProxyContainerAppName,
    "--resource-group", $ResourceGroup,
    "--query", "id"
)
$openWebUiId = Invoke-AzTsv -Arguments @(
    "containerapp", "show",
    "--name", $OpenWebUiContainerAppName,
    "--resource-group", $ResourceGroup,
    "--query", "id"
)
$environmentId = Invoke-AzTsv -Arguments @(
    "containerapp", "show",
    "--name", $ProxyContainerAppName,
    "--resource-group", $ResourceGroup,
    "--query", "properties.managedEnvironmentId"
)
$environmentName = ($environmentId -split "/")[-1]
$environmentResourceGroup = ($environmentId -split "/")[4]
$azureOpenAIId = Invoke-AzTsv -Arguments @(
    "cognitiveservices", "account", "show",
    "--name", $AzureOpenAIResourceName,
    "--resource-group", $AzureOpenAIResourceGroup,
    "--query", "id"
)
$postgresId = Invoke-AzTsv -Arguments @(
    "postgres", "flexible-server", "show",
    "--name", $PostgreSqlServerName,
    "--resource-group", $PostgreSqlResourceGroup,
    "--query", "id"
)

$environmentLogDestination = Invoke-AzTsv -Arguments @(
    "containerapp", "env", "show",
    "--name", $environmentName,
    "--resource-group", $environmentResourceGroup,
    "--query", "properties.appLogsConfiguration.destination"
)
$environmentWorkspaceCustomerId = Invoke-AzTsv -Arguments @(
    "containerapp", "env", "show",
    "--name", $environmentName,
    "--resource-group", $environmentResourceGroup,
    "--query", "properties.appLogsConfiguration.logAnalyticsConfiguration.customerId"
)

if ($LogAnalyticsWorkspaceResourceId) {
    $WorkspaceCustomerId = Invoke-AzTsv -Arguments @(
        "monitor", "log-analytics", "workspace", "show",
        "--ids", $LogAnalyticsWorkspaceResourceId,
        "--query", "customerId"
    )
}
elseif (-not $WorkspaceCustomerId) {
    $WorkspaceCustomerId = $environmentWorkspaceCustomerId
}

if (-not $LogAnalyticsWorkspaceResourceId -and $WorkspaceCustomerId) {
    $escapedWorkspaceId = $WorkspaceCustomerId.Replace("'", "''")
    $LogAnalyticsWorkspaceResourceId = Invoke-AzTsv -Arguments @(
        "monitor", "log-analytics", "workspace", "list",
        "--subscription", $SubscriptionId,
        "--query", "[?customerId=='$escapedWorkspaceId'].id | [0]"
    )
}

if (-not $WorkspaceCustomerId -or -not $LogAnalyticsWorkspaceResourceId) {
    throw "A Log Analytics workspace could not be resolved. Supply -LogAnalyticsWorkspaceResourceId, or use the workspace already configured on the Container Apps environment."
}

if (-not $SkipDiagnosticConfiguration) {
    $useExistingContainerAppLogAnalytics = (
        $environmentLogDestination -eq "log-analytics" -and
        $environmentWorkspaceCustomerId -eq $WorkspaceCustomerId
    )

    if (-not $useExistingContainerAppLogAnalytics -and
        $environmentLogDestination -ne "azure-monitor") {
        Invoke-Az -Arguments @(
            "containerapp", "env", "update",
            "--name", $environmentName,
            "--resource-group", $environmentResourceGroup,
            "--logs-destination", "azure-monitor"
        ) | Out-Null
        $environmentLogDestination = "azure-monitor"
    }

    $containerAppsEnvironmentLogPatterns = if ($useExistingContainerAppLogAnalytics) {
        @("^ContainerAppHTTPLogs$")
    }
    else {
        @(
            "^ContainerAppConsoleLogs$",
            "^ContainerAppSystemLogs$",
            "^ContainerAppHTTPLogs$"
        )
    }

    Set-ResourceDiagnosticSetting `
        -ResourceId $environmentId `
        -Prefix "containerapps-environment" `
        -LogCategoryPatterns $containerAppsEnvironmentLogPatterns `
        -ExportToResourceSpecific

    Set-ResourceDiagnosticSetting `
        -ResourceId $proxyId `
        -Prefix "proxy" `
        -LogCategoryPatterns @() `
        -ExportToResourceSpecific

    Set-ResourceDiagnosticSetting `
        -ResourceId $openWebUiId `
        -Prefix "openwebui" `
        -LogCategoryPatterns @() `
        -ExportToResourceSpecific

    Set-ResourceDiagnosticSetting `
        -ResourceId $azureOpenAIId `
        -Prefix "azure-openai" `
        -LogCategoryPatterns @(
            "^Audit$",
            "^AzureOpenAIRequestUsage$",
            "^RequestResponse$",
            "^Trace$"
        )

    if (-not $SkipPostgreSqlQueryStoreConfiguration) {
        Export-AzJson -Arguments @(
            "postgres", "flexible-server", "parameter", "set",
            "--server-name", $PostgreSqlServerName,
            "--resource-group", $PostgreSqlResourceGroup,
            "--name", "pg_qs.query_capture_mode",
            "--value", "top"
        ) -Path (Join-Path $OutputPath "postgres-query-store-enabled.json")

        Export-AzJson -Arguments @(
            "postgres", "flexible-server", "parameter", "set",
            "--server-name", $PostgreSqlServerName,
            "--resource-group", $PostgreSqlResourceGroup,
            "--name", "pgms_wait_sampling.query_capture_mode",
            "--value", "all"
        ) -Path (Join-Path $OutputPath "postgres-wait-sampling-enabled.json")
    }

    Set-ResourceDiagnosticSetting `
        -ResourceId $postgresId `
        -Prefix "postgres" `
        -LogCategoryPatterns @(
            "^PostgreSQLLogs$",
            "^PostgreSQLFlexQueryStoreRuntime$",
            "^PostgreSQLFlexQueryStoreWaitStats$",
            "^PostgreSQLFlexSessions$",
            "PostgreSQL.*Server.*Logs",
            "PostgreSQL.*Query Store Runtime",
            "PostgreSQL.*Query Store Wait",
            "PostgreSQL.*Sessions"
        ) `
        -ExportToResourceSpecific

    if (-not $SkipEntraDiagnostics) {
        Set-EntraDiagnosticSetting
    }
}

@{
    startTimeUtc = $StartTime
    endTimeUtc = $EndTime
    proxyContainerAppId = $proxyId
    openWebUiContainerAppId = $openWebUiId
    containerAppsEnvironmentId = $environmentId
    azureOpenAIResourceId = $azureOpenAIId
    azureOpenAIDeploymentName = $AzureOpenAIDeploymentName
    postgreSqlResourceId = $postgresId
    logAnalyticsWorkspaceResourceId = $LogAnalyticsWorkspaceResourceId
    logAnalyticsWorkspaceCustomerId = $WorkspaceCustomerId
    diagnosticSettingName = $DiagnosticSettingName
} | ConvertTo-Json -Depth 5 |
    Set-Content (Join-Path $OutputPath "resource-map.json") -Encoding utf8

$containerAppProjection = "{id:id,location:location,provisioningState:properties.provisioningState," +
    "latestReadyRevision:properties.latestReadyRevisionName," +
    "activeRevisionsMode:properties.configuration.activeRevisionsMode," +
    "ingress:{fqdn:properties.configuration.ingress.fqdn,external:properties.configuration.ingress.external," +
    "transport:properties.configuration.ingress.transport,targetPort:properties.configuration.ingress.targetPort}," +
    "scale:properties.template.scale," +
    "containers:properties.template.containers[].{name:name,cpu:resources.cpu,memory:resources.memory}}"

Export-AzJson -Arguments @(
    "containerapp", "show",
    "--name", $ProxyContainerAppName,
    "--resource-group", $ResourceGroup,
    "--query", $containerAppProjection
) -Path (Join-Path $OutputPath "proxy-containerapp-config.json")

Export-AzJson -Arguments @(
    "containerapp", "show",
    "--name", $OpenWebUiContainerAppName,
    "--resource-group", $ResourceGroup,
    "--query", $containerAppProjection
) -Path (Join-Path $OutputPath "openwebui-containerapp-config.json")

Export-AzJson -Arguments @(
    "containerapp", "revision", "list",
    "--name", $ProxyContainerAppName,
    "--resource-group", $ResourceGroup
) -Path (Join-Path $OutputPath "proxy-revisions.json")

Export-AzJson -Arguments @(
    "containerapp", "revision", "list",
    "--name", $OpenWebUiContainerAppName,
    "--resource-group", $ResourceGroup
) -Path (Join-Path $OutputPath "openwebui-revisions.json")

Export-AzJson -Arguments @(
    "containerapp", "env", "show",
    "--name", $environmentName,
    "--resource-group", $environmentResourceGroup,
    "--query", "{id:id,location:location,provisioningState:properties.provisioningState," +
        "vnetConfiguration:properties.vnetConfiguration," +
        "zoneRedundant:properties.zoneRedundant," +
        "logConfiguration:properties.appLogsConfiguration}"
) -Path (Join-Path $OutputPath "containerapps-environment-config.json")

Export-AzJson -Arguments @(
    "cognitiveservices", "account", "show",
    "--name", $AzureOpenAIResourceName,
    "--resource-group", $AzureOpenAIResourceGroup,
    "--query", "{id:id,location:location,sku:sku,kind:kind," +
        "publicNetworkAccess:properties.publicNetworkAccess," +
        "networkAcls:properties.networkAcls," +
        "privateEndpointConnections:properties.privateEndpointConnections}"
) -Path (Join-Path $OutputPath "azure-openai-config.json")

Export-AzJson -Arguments @(
    "cognitiveservices", "account", "deployment", "show",
    "--name", $AzureOpenAIResourceName,
    "--resource-group", $AzureOpenAIResourceGroup,
    "--deployment-name", $AzureOpenAIDeploymentName
) -Path (Join-Path $OutputPath "azure-openai-deployment.json")

Export-AzJson -Arguments @(
    "postgres", "flexible-server", "show",
    "--name", $PostgreSqlServerName,
    "--resource-group", $PostgreSqlResourceGroup,
    "--query", "{id:id,location:location,sku:sku,version:version,state:state," +
        "network:network,storage:storage,highAvailability:highAvailability," +
        "privateEndpointConnections:privateEndpointConnections}"
) -Path (Join-Path $OutputPath "postgres-config.json")

foreach ($resource in @(
    @{ Name = "containerapps-environment"; Id = $environmentId },
    @{ Name = "azure-openai"; Id = $azureOpenAIId },
    @{ Name = "postgres"; Id = $postgresId }
)) {
    Export-AzJson -Arguments @(
        "monitor", "diagnostic-settings", "list",
        "--resource", $resource.Id
    ) -Path (Join-Path $OutputPath "$($resource.Name)-diagnostic-settings.json")

    Export-AzJson -Arguments @(
        "monitor", "diagnostic-settings", "categories", "list",
        "--resource", $resource.Id
    ) -Path (Join-Path $OutputPath "$($resource.Name)-diagnostic-categories.json")
}

$containerAppMetrics = @(
    "Requests",
    "ResponseTime",
    "Replicas",
    "RestartCount",
    "CpuPercentage",
    "MemoryPercentage",
    "UsageNanoCores",
    "WorkingSetBytes",
    "RxBytes",
    "TxBytes",
    "ResiliencyConnectTimeouts",
    "ResiliencyRequestRetries",
    "ResiliencyRequestsPendingConnectionPool",
    "ResiliencyRequestTimeouts",
    "ResiliencyEjectedHosts"
)

$azureOpenAIMetrics = @(
    "AzureOpenAITimeToResponse",
    "AzureOpenAINormalizedTBTInMS",
    "AzureOpenAITTLTInMS",
    "AzureOpenAITokenPerSecond",
    "ProcessedPromptTokens",
    "GeneratedTokens",
    "AzureOpenAIRequests",
    "AzureOpenAIAvailabilityRate",
    "AzureOpenAIContextTokensCacheMatchRate",
    "AzureOpenAIProvisionedManagedUtilizationV2",
    "ActiveTokens"
)

$postgresMetrics = @(
    "is_db_alive",
    "cpu_percent",
    "memory_percent",
    "active_connections",
    "max_connections",
    "connections_succeeded",
    "connections_failed",
    "disk_iops_consumed_percentage",
    "disk_bandwidth_consumed_percentage",
    "disk_queue_depth",
    "iops",
    "read_iops",
    "write_iops",
    "network_bytes_ingress",
    "network_bytes_egress",
    "sessions_by_state",
    "sessions_by_wait_event_type",
    "longest_query_time_sec",
    "longest_transaction_time_sec",
    "deadlocks",
    "temp_bytes",
    "tcp_connection_backlog"
)

Export-Metrics -ResourceId $proxyId -DesiredMetrics $containerAppMetrics -Prefix "proxy"
Export-Metrics -ResourceId $openWebUiId -DesiredMetrics $containerAppMetrics -Prefix "openwebui"
Export-Metrics -ResourceId $azureOpenAIId -DesiredMetrics $azureOpenAIMetrics -Prefix "azure-openai"
Export-Metrics -ResourceId $postgresId -DesiredMetrics $postgresMetrics -Prefix "postgres"

if ($LoadBalancerResourceId) {
    Export-Metrics -ResourceId $LoadBalancerResourceId -Prefix "load-balancer" -DesiredMetrics @(
        "VipAvailability",
        "DipAvailability",
        "ByteCount",
        "PacketCount",
        "SYNCount",
        "SnatConnectionCount",
        "AllocatedSnatPorts",
        "UsedSnatPorts"
    )
}

$escapedProxyName = $ProxyContainerAppName.Replace("'", "''")
$escapedOpenWebUiName = $OpenWebUiContainerAppName.Replace("'", "''")
$escapedDeploymentName = $AzureOpenAIDeploymentName.Replace("'", "''")
$escapedEntraAppName = $EntraAppDisplayName.Replace("'", "''")

Export-LogQuery -Name "aca-http-latency-by-path" -Query @"
ContainerAppHTTPLogs
| where TimeGenerated between (datetime($StartTime) .. datetime($EndTime))
| where ContainerAppName in ('$escapedProxyName', '$escapedOpenWebUiName')
| summarize
    Requests=count(),
    Errors=countif(StatusCode >= 400),
    P50Ms=percentile(RequestDuration, 50),
    P95Ms=percentile(RequestDuration, 95),
    P99Ms=percentile(RequestDuration, 99),
    MaxMs=max(RequestDuration),
    RetriedRequests=countif(UpstreamRequestAttemptCount > 1)
  by ContainerAppName, RevisionName, Method, Path, StatusCode
| order by P95Ms desc
"@

    Export-LogQuery -Name "aca-http-slowest-requests" -Query @"
ContainerAppHTTPLogs
| where TimeGenerated between (datetime($StartTime) .. datetime($EndTime))
| where ContainerAppName in ('$escapedProxyName', '$escapedOpenWebUiName')
| top 200 by RequestDuration desc
| project TimeGenerated, ContainerAppName, RevisionName, ReplicaName,
    Method, Path, StatusCode, ResponseCodeDetails, ResponseFlags,
    RequestDuration, UpstreamRequestAttemptCount, RequestId,
    Protocol, BytesReceived, BytesSent, UpstreamHost
"@

    Export-LogQuery -Name "aca-system-events" -Query @"
union isfuzzy=true
    (ContainerAppSystemLogs_CL
    | project TimeGenerated,
        ContainerAppName=tostring(ContainerAppName_s),
        RevisionName=tostring(RevisionName_s),
        ReplicaName=tostring(column_ifexists('ReplicaName_s', '')),
        Message=tostring(Log_s)),
    (ContainerAppSystemLogs
    | project TimeGenerated,
        ContainerAppName=tostring(ContainerAppName),
        RevisionName=tostring(RevisionName),
        ReplicaName=tostring(column_ifexists('ReplicaName', '')),
        Message=tostring(Log))
| where TimeGenerated between (datetime($StartTime) .. datetime($EndTime))
| where ContainerAppName in ('$escapedProxyName', '$escapedOpenWebUiName')
| where Message has_any ('error', 'timeout', 'probe', 'restart', 'crash', 'provision', 'scale')
| project TimeGenerated, ContainerAppName, RevisionName, ReplicaName, Message
| order by TimeGenerated desc
"@

    Export-LogQuery -Name "aca-console-errors" -Query @"
union isfuzzy=true
    (ContainerAppConsoleLogs_CL
    | project TimeGenerated,
        ContainerAppName=tostring(ContainerAppName_s),
        RevisionName=tostring(RevisionName_s),
        ReplicaName=tostring(ContainerGroupName_g),
        Message=tostring(Log_s)),
    (ContainerAppConsoleLogs
    | project TimeGenerated,
        ContainerAppName=tostring(ContainerAppName),
        RevisionName=tostring(RevisionName),
        ReplicaName=tostring(ContainerGroupName),
        Message=tostring(Log))
| where TimeGenerated between (datetime($StartTime) .. datetime($EndTime))
| where ContainerAppName in ('$escapedProxyName', '$escapedOpenWebUiName')
| where Message has_any ('error', 'exception', 'timeout', '429', 'retry', 'socket', 'DNS', 'connection')
| project TimeGenerated, ContainerAppName, RevisionName, ReplicaName, Message
| order by TimeGenerated desc
"@

    Export-LogQuery -Name "proxy-structured-timings" -Query @"
union isfuzzy=true
    (ContainerAppConsoleLogs_CL
    | project TimeGenerated,
        ContainerAppName=tostring(ContainerAppName_s),
        Message=tostring(Log_s)),
    (ContainerAppConsoleLogs
    | project TimeGenerated,
        ContainerAppName=tostring(ContainerAppName),
        Message=tostring(Log))
| where TimeGenerated between (datetime($StartTime) .. datetime($EndTime))
| where ContainerAppName == '$escapedProxyName'
| extend Log = parse_json(Message)
| where tostring(Log.event) in (
    'proxy.request.received',
    'proxy.auth.completed',
    'proxy.openai.headers',
    'proxy.first_chunk.flushed',
    'proxy.request.completed')
| project TimeGenerated,
    Event=tostring(Log.event),
    RequestId=tostring(Log.request_id),
    AuthMs=todouble(Log.auth_ms),
    UpstreamFirstByteMs=todouble(Log.upstream_first_byte_ms),
    FirstChunkFlushMs=todouble(Log.first_chunk_flush_ms),
    TotalMs=todouble(Log.total_ms),
    PromptTokens=toint(Log.prompt_tokens),
    OutputTokens=toint(Log.output_tokens),
    RetryCount=toint(Log.retry_count),
    Stream=tobool(Log.stream),
    Background=tobool(Log.background),
    StatusCode=toint(Log.status_code)
| order by TimeGenerated desc
"@

    Export-LogQuery -Name "azure-openai-resource-logs" -Query @"
AzureDiagnostics
| where TimeGenerated between (datetime($StartTime) .. datetime($EndTime))
| where ResourceId =~ '$azureOpenAIId'
| where Category in ('RequestResponse', 'AzureOpenAIRequestUsage', 'Audit', 'Trace')
| extend
    DurationMsSafe=todouble(column_ifexists('DurationMs', '')),
    DeploymentName=tostring(column_ifexists('modelDeploymentName_s', '')),
    Properties=tostring(column_ifexists('properties_s', ''))
| where isempty(DeploymentName) or DeploymentName == '$escapedDeploymentName'
| project TimeGenerated, Category, OperationName, ResultType,
    ResultSignature, DurationMsSafe, CorrelationId, DeploymentName, Properties
| order by TimeGenerated desc
| take 5000
"@

    Export-LogQuery -Name "postgres-errors" -Query @"
PGSQLServerLogs
| where TimeGenerated between (datetime($StartTime) .. datetime($EndTime))
| where _ResourceId =~ '$postgresId'
| where Message has_any ('ERROR', 'FATAL', 'PANIC', 'timeout', 'connection', 'deadlock')
| project TimeGenerated, Severity, Message, DatabaseName, UserName
| order by TimeGenerated desc
| take 1000
"@

    Export-LogQuery -Name "postgres-query-runtime" -Query @"
PGSQLQueryStoreRuntime
| where TimeGenerated between (datetime($StartTime) .. datetime($EndTime))
| where _ResourceId =~ '$postgresId'
| project TimeGenerated,
    QueryId=column_ifexists('QueryId', ''),
    DatabaseName=column_ifexists('DatabaseName', ''),
    Calls=tolong(column_ifexists('Calls', '')),
    MeanExecTimeMs=todouble(column_ifexists('MeanExecTime', '')),
    MaxExecTimeMs=todouble(column_ifexists('MaxExecTime', '')),
    TotalExecTimeMs=todouble(column_ifexists('TotalExecTime', ''))
| top 200 by MaxExecTimeMs desc
"@

    Export-LogQuery -Name "postgres-session-waits" -Query @"
PGSQLPgStatActivitySessions
| where TimeGenerated between (datetime($StartTime) .. datetime($EndTime))
| where _ResourceId =~ '$postgresId'
| summarize Sessions=count()
    by State=column_ifexists('State', ''),
       WaitEventType=column_ifexists('WaitEventType', ''),
       bin(TimeGenerated, 5m)
| order by TimeGenerated desc
"@

    Export-LogQuery -Name "entra-signins" -Query @"
SigninLogs
| where TimeGenerated between (datetime($StartTime) .. datetime($EndTime))
| where AppDisplayName == '$escapedEntraAppName'
| summarize
    SignIns=count(),
    Failures=countif(ResultType != '0'),
    P50DurationMs=percentile(DurationMs, 50),
    P95DurationMs=percentile(DurationMs, 95),
    P99DurationMs=percentile(DurationMs, 99)
  by ResultType, ResultDescription, ConditionalAccessStatus,
     bin(TimeGenerated, 5m)
| order by TimeGenerated desc
"@

@"
Diagnostic configuration and collection complete.

UTC range: $StartTime through $EndTime
Output: $OutputPath

Diagnostic settings only affect new telemetry. If they were created by this run,
reproduce the latency, wait several minutes for ingestion, and run the script
again to collect the new logs. PostgreSQL Query Store can take up to about
20 minutes to persist its first batch.

Interpretation:
- High client/Container Apps latency but low AzureOpenAITimeToResponse points to auth, proxy, buffering, ingress, or network overhead.
- High AzureOpenAITimeToResponse with stable prompt tokens points to deployment load or capacity.
- High ProcessedPromptTokens usually explains high time to first token.
- High AzureOpenAINormalizedTBTInMS or low AzureOpenAITokenPerSecond indicates slow token generation.
- Replicas reaching zero before slow requests indicates cold starts.
- High proxy ResponseTime with low OpenWebUI ResponseTime isolates the proxy or Azure OpenAI leg.
- Slow /api/v1/models requests plus PostgreSQL pressure implicate per-request key validation.
- UpstreamRequestAttemptCount above 1, resiliency retries, 429s, or timeouts add hidden delay.

The proxy-structured-timings query only returns data after the proxy emits the documented JSON timing events.
"@ | Set-Content (Join-Path $OutputPath "README.txt") -Encoding utf8

Write-Host "Diagnostics written to $OutputPath"
