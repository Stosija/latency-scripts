#Requires -Version 7.0

<#
.SYNOPSIS
Runs a controlled Codex latency test and collects correlated Azure evidence.

.DESCRIPTION
Creates a unique run ID, optionally sends a synthetic streaming request, and collects
Container Apps, Application Insights/OpenTelemetry, Azure OpenAI, PostgreSQL, DNS-adjacent,
revision, replica, configuration, and Azure Monitor evidence for the same UTC window.

The bearer token is supplied to curl through standard input rather than the process command
line. Raw model output and response headers remain local in the evidence directory.

.EXAMPLE
.\Invoke-LatencyDiagnostic.ps1 `
  -SubscriptionId "<subscription-id>" `
  -ResourceGroup "<resource-group>" `
  -ProxyApp "<proxy-container-app>" `
  -OpenWebUiApp "<openwebui-container-app>" `
  -AoaiAccount "<azure-openai-account>" `
  -AoaiDeployment "<deployment-name>" `
  -PostgresServer "<postgres-flexible-server>" `
  -WorkspaceId "<workspace-customer-id-guid>" `
  -CodexUrl "https://<CODEX_API_HOST>/<API_PATH>" `
  -RequestBodyPath ".\synthetic-request.json"

.EXAMPLE
.\Invoke-LatencyDiagnostic.ps1 `
  -SubscriptionId "<subscription-id>" `
  -ResourceGroup "<resource-group>" `
  -ProxyApp "<proxy-container-app>" `
  -OpenWebUiApp "<openwebui-container-app>" `
  -AoaiAccount "<azure-openai-account>" `
  -PostgresServer "<postgres-flexible-server>" `
  -WorkspaceId "<workspace-customer-id-guid>" `
  -RunId "<existing-correlation-id>" `
  -StartUtc "2026-08-20T17:00:00Z" `
  -EndUtc "2026-08-20T17:15:00Z" `
  -SkipClientTest
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$SubscriptionId,

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$ResourceGroup,

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$ProxyApp,

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$OpenWebUiApp,

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$AoaiAccount,

    [string]$AoaiDeployment,

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$PostgresServer,

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$WorkspaceId,

    [string]$CodexUrl,

    [string]$RequestBodyPath,

    [string]$CorrelationHeader = "x-client-request-id",

    [securestring]$BearerToken,

    [string]$RunId,

    [datetime]$StartUtc,

    [datetime]$EndUtc,

    [string]$OutputRoot = (Join-Path $PWD "latency-evidence"),

    [switch]$SkipClientTest
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Assert-Command {
    param([Parameter(Mandatory)][string]$Name)

    if (-not (Get-Command $Name -ErrorAction SilentlyContinue)) {
        throw "Required command '$Name' was not found. Install it and retry."
    }
}

function ConvertTo-UtcIso {
    param([Parameter(Mandatory)][datetime]$Value)

    return $Value.ToUniversalTime().ToString("o")
}

function ConvertTo-CurlConfigValue {
    param([Parameter(Mandatory)][string]$Value)

    return $Value.Replace("\", "\\").Replace('"', '\"')
}

function Invoke-AzCapture {
    param(
        [Parameter(Mandatory)][string[]]$Arguments,
        [Parameter(Mandatory)][string]$OutputPath,
        [switch]$Optional
    )

    Write-Host "Collecting $(Split-Path $OutputPath -Leaf)..."
    $output = & az @Arguments 2>&1
    $exitCode = $LASTEXITCODE
    $output | Set-Content -LiteralPath $OutputPath -Encoding utf8

    if ($exitCode -ne 0) {
        $message = "Azure CLI command failed with exit code $exitCode. Details: $OutputPath"
        if ($Optional) {
            Write-Warning $message
            return $false
        }
        throw $message
    }

    return $true
}

function Invoke-LogQuery {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Query,
        [Parameter(Mandatory)][string]$EvidencePath
    )

    $queryPath = Join-Path $EvidencePath "$Name.kql"
    $resultPath = Join-Path $EvidencePath "$Name.json"
    $Query | Set-Content -LiteralPath $queryPath -Encoding utf8

    Invoke-AzCapture -Arguments @(
        "monitor", "log-analytics", "query",
        "--workspace", $WorkspaceId,
        "--analytics-query", $Query,
        "--output", "json"
    ) -OutputPath $resultPath -Optional | Out-Null
}

function Get-ResourceId {
    param(
        [Parameter(Mandatory)][string[]]$Arguments,
        [Parameter(Mandatory)][string]$Description
    )

    $result = & az @Arguments "--query" "id" "--output" "tsv" 2>&1
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace(($result -join ""))) {
        throw "Could not resolve $Description. $($result -join [Environment]::NewLine)"
    }
    return ($result -join "").Trim()
}

function Export-SupportedMetrics {
    param(
        [Parameter(Mandatory)][string]$ResourceId,
        [Parameter(Mandatory)][string[]]$RequestedMetrics,
        [Parameter(Mandatory)][string]$Prefix,
        [Parameter(Mandatory)][string]$EvidencePath,
        [Parameter(Mandatory)][string]$WindowStart,
        [Parameter(Mandatory)][string]$WindowEnd
    )

    $definitionsPath = Join-Path $EvidencePath "$Prefix-metric-definitions.json"
    $definitionsRaw = & az monitor metrics list-definitions --resource $ResourceId --output json 2>&1
    $definitionsExitCode = $LASTEXITCODE
    $definitionsRaw | Set-Content -LiteralPath $definitionsPath -Encoding utf8

    if ($definitionsExitCode -ne 0) {
        Write-Warning "Could not retrieve $Prefix metric definitions. Details: $definitionsPath"
        return
    }

    try {
        $definitions = ($definitionsRaw -join [Environment]::NewLine) | ConvertFrom-Json
    }
    catch {
        Write-Warning "Could not parse $Prefix metric definitions. Details: $definitionsPath"
        return
    }

    $supportedNames = @($definitions | ForEach-Object { $_.name.value })
    $selectedMetrics = @($RequestedMetrics | Where-Object { $supportedNames -contains $_ })
    $missingMetrics = @($RequestedMetrics | Where-Object { $supportedNames -notcontains $_ })

    if ($missingMetrics.Count -gt 0) {
        "Unavailable requested metrics: $($missingMetrics -join ', ')" |
            Set-Content -LiteralPath (Join-Path $EvidencePath "$Prefix-unavailable-metrics.txt") -Encoding utf8
    }

    if ($selectedMetrics.Count -eq 0) {
        Write-Warning "None of the requested $Prefix metrics are available on this resource."
        return
    }

    $arguments = @(
        "monitor", "metrics", "list",
        "--resource", $ResourceId,
        "--metric"
    ) + $selectedMetrics + @(
        "--start-time", $WindowStart,
        "--end-time", $WindowEnd,
        "--interval", "PT1M",
        "--output", "json"
    )

    Invoke-AzCapture -Arguments $arguments `
        -OutputPath (Join-Path $EvidencePath "$Prefix-metrics.json") `
        -Optional | Out-Null
}

function Invoke-StreamingClientTest {
    param(
        [Parameter(Mandatory)][string]$Url,
        [Parameter(Mandatory)][string]$BodyPath,
        [Parameter(Mandatory)][securestring]$Token,
        [Parameter(Mandatory)][string]$CorrelationId,
        [Parameter(Mandatory)][string]$HeaderName,
        [Parameter(Mandatory)][string]$EvidencePath
    )

    Assert-Command -Name "curl.exe"

    $resolvedBody = (Resolve-Path -LiteralPath $BodyPath).Path
    $responsePath = Join-Path $EvidencePath "client-response.ndjson"
    $headersPath = Join-Path $EvidencePath "client-response-headers.txt"
    $timingPath = Join-Path $EvidencePath "client-timing.txt"
    $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($Token)
    $plainToken = $null

    try {
        $plainToken = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
        $config = @(
            "url = `"$(ConvertTo-CurlConfigValue $Url)`""
            "request = `"POST`""
            "header = `"Authorization: Bearer $(ConvertTo-CurlConfigValue $plainToken)`""
            "header = `"Content-Type: application/json`""
            "header = `"$(ConvertTo-CurlConfigValue $HeaderName): $(ConvertTo-CurlConfigValue $CorrelationId)`""
            "data-binary = `"@$(ConvertTo-CurlConfigValue $resolvedBody)`""
            "dump-header = `"$(ConvertTo-CurlConfigValue $headersPath)`""
            "output = `"$(ConvertTo-CurlConfigValue $responsePath)`""
            "no-buffer"
            "silent"
            "show-error"
            "write-out = `"run_id=$CorrelationId\nhttp_code=%{http_code}\ndns_s=%{time_namelookup}\nconnect_s=%{time_connect}\ntls_s=%{time_appconnect}\npretransfer_s=%{time_pretransfer}\nfirst_byte_s=%{time_starttransfer}\ntotal_s=%{time_total}\nremote_ip=%{remote_ip}\n`""
        ) -join [Environment]::NewLine

        Write-Host "Running the synthetic streaming request with correlation ID $CorrelationId..."
        $timing = $config | & curl.exe --config - 2>&1
        $exitCode = $LASTEXITCODE
        $timing | Set-Content -LiteralPath $timingPath -Encoding utf8

        if ($exitCode -ne 0) {
            throw "The client request failed with curl exit code $exitCode. Details: $timingPath"
        }
    }
    finally {
        $plainToken = $null
        if ($bstr -ne [IntPtr]::Zero) {
            [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
        }
    }
}

Assert-Command -Name "az"

if ([string]::IsNullOrWhiteSpace($RunId)) {
    $RunId = "latency-$([DateTime]::UtcNow.ToString('yyyyMMddTHHmmssZ'))-$([guid]::NewGuid().ToString('N').Substring(0, 8))"
}

$runStartedUtc = [DateTime]::UtcNow
if (-not $PSBoundParameters.ContainsKey("StartUtc")) {
    $StartUtc = $runStartedUtc.AddMinutes(-5)
}

$evidencePath = Join-Path $OutputRoot $RunId
New-Item -ItemType Directory -Path $evidencePath -Force | Out-Null

Write-Host "Evidence directory: $evidencePath"
Write-Host "Correlation ID: $RunId"

& az account set --subscription $SubscriptionId
if ($LASTEXITCODE -ne 0) {
    throw "Unable to select subscription '$SubscriptionId'. Run 'az login' and retry."
}

Invoke-AzCapture -Arguments @(
    "account", "show",
    "--query", "{subscription:name,subscriptionId:id,tenantId:tenantId,user:user.name}",
    "--output", "json"
) -OutputPath (Join-Path $evidencePath "azure-account.json") | Out-Null

$proxyId = Get-ResourceId -Arguments @(
    "containerapp", "show", "--resource-group", $ResourceGroup, "--name", $ProxyApp
) -Description "Codex proxy Container App"

$openWebUiId = Get-ResourceId -Arguments @(
    "containerapp", "show", "--resource-group", $ResourceGroup, "--name", $OpenWebUiApp
) -Description "OpenWebUI Container App"

$aoaiId = Get-ResourceId -Arguments @(
    "cognitiveservices", "account", "show", "--resource-group", $ResourceGroup, "--name", $AoaiAccount
) -Description "Azure OpenAI account"

$postgresId = Get-ResourceId -Arguments @(
    "postgres", "flexible-server", "show", "--resource-group", $ResourceGroup, "--name", $PostgresServer
) -Description "PostgreSQL Flexible Server"

if (-not $SkipClientTest) {
    if ([string]::IsNullOrWhiteSpace($CodexUrl)) {
        throw "CodexUrl is required unless SkipClientTest is specified."
    }
    if ([string]::IsNullOrWhiteSpace($RequestBodyPath) -or -not (Test-Path -LiteralPath $RequestBodyPath -PathType Leaf)) {
        throw "RequestBodyPath must identify an existing synthetic JSON request unless SkipClientTest is specified."
    }
    if (-not $BearerToken) {
        $BearerToken = Read-Host "Enter the short-lived test bearer token" -AsSecureString
    }

    Copy-Item -LiteralPath $RequestBodyPath -Destination (Join-Path $evidencePath "request.json") -Force
    Invoke-StreamingClientTest `
        -Url $CodexUrl `
        -BodyPath $RequestBodyPath `
        -Token $BearerToken `
        -CorrelationId $RunId `
        -HeaderName $CorrelationHeader `
        -EvidencePath $evidencePath
}

if (-not $PSBoundParameters.ContainsKey("EndUtc")) {
    $EndUtc = [DateTime]::UtcNow.AddMinutes(5)
}

$startIso = ConvertTo-UtcIso $StartUtc
$endIso = ConvertTo-UtcIso $EndUtc

$context = [ordered]@{
    runId               = $RunId
    startUtc            = $startIso
    endUtc              = $endIso
    subscriptionId      = $SubscriptionId
    resourceGroup       = $ResourceGroup
    proxyApp            = $ProxyApp
    openWebUiApp        = $OpenWebUiApp
    azureOpenAIAccount  = $AoaiAccount
    azureOpenAIDeployment = $AoaiDeployment
    postgresServer      = $PostgresServer
    workspaceId         = $WorkspaceId
    correlationHeader   = $CorrelationHeader
    clientTestExecuted  = -not $SkipClientTest
    proxyResourceId     = $proxyId
    openWebUiResourceId = $openWebUiId
    azureOpenAIResourceId = $aoaiId
    postgresResourceId  = $postgresId
}
$context | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $evidencePath "context.json") -Encoding utf8

Invoke-AzCapture -Arguments @(
    "containerapp", "show", "--resource-group", $ResourceGroup, "--name", $ProxyApp,
    "--query", "{name:name,location:location,environment:properties.environmentId,fqdn:properties.configuration.ingress.fqdn,revisionMode:properties.configuration.activeRevisionsMode,ingress:properties.configuration.ingress,scale:properties.template.scale,containers:properties.template.containers[].{name:name,cpu:resources.cpu,memory:resources.memory,probes:probes}}",
    "--output", "json"
) -OutputPath (Join-Path $evidencePath "proxy-config.json") | Out-Null

Invoke-AzCapture -Arguments @(
    "containerapp", "show", "--resource-group", $ResourceGroup, "--name", $OpenWebUiApp,
    "--query", "{name:name,location:location,environment:properties.environmentId,fqdn:properties.configuration.ingress.fqdn,revisionMode:properties.configuration.activeRevisionsMode,ingress:properties.configuration.ingress,scale:properties.template.scale,containers:properties.template.containers[].{name:name,cpu:resources.cpu,memory:resources.memory,probes:probes}}",
    "--output", "json"
) -OutputPath (Join-Path $evidencePath "openwebui-config.json") | Out-Null

Invoke-AzCapture -Arguments @(
    "cognitiveservices", "account", "show", "--resource-group", $ResourceGroup, "--name", $AoaiAccount,
    "--query", "{name:name,location:location,kind:kind,publicNetworkAccess:properties.publicNetworkAccess,customSubDomain:properties.customSubDomainName}",
    "--output", "json"
) -OutputPath (Join-Path $evidencePath "azure-openai-config.json") | Out-Null

Invoke-AzCapture -Arguments @(
    "postgres", "flexible-server", "show", "--resource-group", $ResourceGroup, "--name", $PostgresServer,
    "--query", "{name:name,location:location,version:version,publicNetworkAccess:network.publicNetworkAccess,highAvailability:highAvailability,sku:sku}",
    "--output", "json"
) -OutputPath (Join-Path $evidencePath "postgres-config.json") | Out-Null

Invoke-AzCapture -Arguments @(
    "containerapp", "revision", "list", "--resource-group", $ResourceGroup, "--name", $ProxyApp,
    "--output", "json"
) -OutputPath (Join-Path $evidencePath "proxy-revisions.json") -Optional | Out-Null

Invoke-AzCapture -Arguments @(
    "containerapp", "replica", "list", "--resource-group", $ResourceGroup, "--name", $ProxyApp,
    "--output", "json"
) -OutputPath (Join-Path $evidencePath "proxy-replicas.json") -Optional | Out-Null

Invoke-AzCapture -Arguments @(
    "containerapp", "revision", "list", "--resource-group", $ResourceGroup, "--name", $OpenWebUiApp,
    "--output", "json"
) -OutputPath (Join-Path $evidencePath "openwebui-revisions.json") -Optional | Out-Null

Invoke-AzCapture -Arguments @(
    "containerapp", "replica", "list", "--resource-group", $ResourceGroup, "--name", $OpenWebUiApp,
    "--output", "json"
) -OutputPath (Join-Path $evidencePath "openwebui-replicas.json") -Optional | Out-Null

Invoke-AzCapture -Arguments @(
    "containerapp", "logs", "show", "--resource-group", $ResourceGroup, "--name", $ProxyApp,
    "--type", "console", "--tail", "300", "--format", "json"
) -OutputPath (Join-Path $evidencePath "proxy-console-tail.json") -Optional | Out-Null

Invoke-AzCapture -Arguments @(
    "containerapp", "logs", "show", "--resource-group", $ResourceGroup, "--name", $ProxyApp,
    "--type", "system", "--tail", "300", "--format", "json"
) -OutputPath (Join-Path $evidencePath "proxy-system-tail.json") -Optional | Out-Null

Invoke-AzCapture -Arguments @(
    "containerapp", "logs", "show", "--resource-group", $ResourceGroup, "--name", $OpenWebUiApp,
    "--type", "console", "--tail", "300", "--format", "json"
) -OutputPath (Join-Path $evidencePath "openwebui-console-tail.json") -Optional | Out-Null

Invoke-AzCapture -Arguments @(
    "containerapp", "logs", "show", "--resource-group", $ResourceGroup, "--name", $OpenWebUiApp,
    "--type", "system", "--tail", "300", "--format", "json"
) -OutputPath (Join-Path $evidencePath "openwebui-system-tail.json") -Optional | Out-Null

$containerCorrelationKql = @"
let start=datetime($startIso);
let end=datetime($endIso);
union isfuzzy=true ContainerAppConsoleLogs_CL, ContainerAppConsoleLogs, ContainerAppSystemLogs_CL, ContainerAppSystemLogs, ContainerAppHTTPLogs
| where TimeGenerated between (start .. end)
| where * has '$RunId'
| project TimeGenerated, Record=pack_all()
| order by TimeGenerated asc
"@
Invoke-LogQuery -Name "container-correlated" -Query $containerCorrelationKql -EvidencePath $evidencePath

$containerSystemKql = @"
let start=datetime($startIso);
let end=datetime($endIso);
union isfuzzy=true ContainerAppSystemLogs_CL, ContainerAppSystemLogs
| where TimeGenerated between (start .. end)
| where * has_any ('$ProxyApp', '$OpenWebUiApp')
| where * has_any ('start','stop','restart','replica','scale','probe','unhealthy','failed','timeout','eject')
| project TimeGenerated, Record=pack_all()
| order by TimeGenerated asc
"@
Invoke-LogQuery -Name "container-system-events" -Query $containerSystemKql -EvidencePath $evidencePath

$containerHttpKql = @"
let start=datetime($startIso);
let end=datetime($endIso);
ContainerAppHTTPLogs
| where TimeGenerated between (start .. end)
| where * has_any ('$ProxyApp', '$OpenWebUiApp', '$RunId')
| project TimeGenerated, Record=pack_all()
| order by TimeGenerated asc
"@
Invoke-LogQuery -Name "container-http" -Query $containerHttpKql -EvidencePath $evidencePath

$applicationTraceKql = @"
let start=datetime($startIso);
let end=datetime($endIso);
union isfuzzy=true requests, dependencies, traces, exceptions, customEvents
| where timestamp between (start .. end)
| where operation_Id == '$RunId' or tostring(customDimensions) has '$RunId' or message has '$RunId'
| project timestamp, Record=pack_all()
| order by timestamp asc
"@
Invoke-LogQuery -Name "application-trace" -Query $applicationTraceKql -EvidencePath $evidencePath

$dependencyKql = @"
let start=datetime($startIso);
let end=datetime($endIso);
dependencies
| where timestamp between (start .. end)
| where operation_Id == '$RunId' or tostring(customDimensions) has '$RunId'
| project timestamp, operation_Id, name, target, type, duration, resultCode, success, data, customDimensions
| order by timestamp asc
"@
Invoke-LogQuery -Name "application-dependencies" -Query $dependencyKql -EvidencePath $evidencePath

$aoaiDiagnosticsKql = @"
let start=datetime($startIso);
let end=datetime($endIso);
AzureDiagnostics
| where TimeGenerated between (start .. end)
| where _ResourceId =~ '$aoaiId'
| where Category in ('RequestResponse','AzureOpenAIRequestUsage','Trace','Audit')
| where * has '$RunId' or Category in ('RequestResponse','AzureOpenAIRequestUsage')
| project TimeGenerated, Category, OperationName, ResultType, ResultSignature, DurationMs, CorrelationId, properties_s
| order by TimeGenerated asc
"@
Invoke-LogQuery -Name "azure-openai-diagnostics" -Query $aoaiDiagnosticsKql -EvidencePath $evidencePath

$aoaiFailuresKql = @"
let start=datetime($startIso);
let end=datetime($endIso);
AzureDiagnostics
| where TimeGenerated between (start .. end) and _ResourceId =~ '$aoaiId'
| where ResultType in ('429','500','502','503','504') or tostring(properties_s) has_any ('429','retry','throttl')
| summarize Requests=count() by ResultType, bin(TimeGenerated, 1m)
| order by TimeGenerated asc
"@
Invoke-LogQuery -Name "azure-openai-failures" -Query $aoaiFailuresKql -EvidencePath $evidencePath

$azureMetricsKql = @"
let start=datetime($startIso);
let end=datetime($endIso);
AzureMetrics
| where TimeGenerated between (start .. end)
| where ResourceId =~ '$aoaiId'
| where MetricName in ('AzureOpenAITimeToResponse','AzureOpenAINormalizedTBTInMS','AzureOpenAITTLTInMS','AzureOpenAITokenPerSecond','AzureOpenAIRequests','ProcessedPromptTokens','GeneratedTokens','ActiveTokens')
| project TimeGenerated, MetricName, Average, Minimum, Maximum, Total, Count, UnitName, Tags
| order by TimeGenerated asc
"@
Invoke-LogQuery -Name "azure-openai-log-metrics" -Query $azureMetricsKql -EvidencePath $evidencePath

$postgresKql = @"
let start=datetime($startIso);
let end=datetime($endIso);
union isfuzzy=true PGSQLServerLogs, PGSQLQueryStoreRuntime, PGSQLQueryStoreWaits, PGSQLPgStatActivitySessions
| where TimeGenerated between (start .. end)
| where _ResourceId =~ '$postgresId'
| project TimeGenerated, Record=pack_all()
| order by TimeGenerated asc
"@
Invoke-LogQuery -Name "postgres-logs" -Query $postgresKql -EvidencePath $evidencePath

$postgresPressureKql = @"
let start=datetime($startIso);
let end=datetime($endIso);
union isfuzzy=true PGSQLServerLogs, PGSQLQueryStoreRuntime, PGSQLQueryStoreWaits, PGSQLPgStatActivitySessions
| where TimeGenerated between (start .. end) and _ResourceId =~ '$postgresId'
| where * has_any ('error','fatal','timeout','deadlock','connection','wait','long','temporary')
| project TimeGenerated, Record=pack_all()
| order by TimeGenerated asc
"@
Invoke-LogQuery -Name "postgres-pressure" -Query $postgresPressureKql -EvidencePath $evidencePath

Export-SupportedMetrics `
    -ResourceId $aoaiId `
    -RequestedMetrics @(
        "AzureOpenAITimeToResponse",
        "AzureOpenAINormalizedTBTInMS",
        "AzureOpenAITTLTInMS",
        "AzureOpenAITokenPerSecond",
        "AzureOpenAIRequests",
        "ProcessedPromptTokens",
        "GeneratedTokens",
        "ActiveTokens"
    ) `
    -Prefix "azure-openai" `
    -EvidencePath $evidencePath `
    -WindowStart $startIso `
    -WindowEnd $endIso

$containerMetrics = @(
    "Requests",
    "ResponseTime",
    "Replicas",
    "RestartCount",
    "CpuPercentage",
    "MemoryPercentage",
    "UsageNanoCores",
    "WorkingSetBytes",
    "RxBytes",
    "TxBytes"
)

Export-SupportedMetrics `
    -ResourceId $proxyId `
    -RequestedMetrics $containerMetrics `
    -Prefix "proxy" `
    -EvidencePath $evidencePath `
    -WindowStart $startIso `
    -WindowEnd $endIso

Export-SupportedMetrics `
    -ResourceId $openWebUiId `
    -RequestedMetrics $containerMetrics `
    -Prefix "openwebui" `
    -EvidencePath $evidencePath `
    -WindowStart $startIso `
    -WindowEnd $endIso

Export-SupportedMetrics `
    -ResourceId $postgresId `
    -RequestedMetrics @(
        "cpu_percent",
        "memory_percent",
        "active_connections",
        "failed_connections",
        "connections_failed",
        "transactions_per_second",
        "read_iops",
        "write_iops",
        "disk_queue_depth",
        "network_bytes_ingress",
        "network_bytes_egress"
    ) `
    -Prefix "postgres" `
    -EvidencePath $evidencePath `
    -WindowStart $startIso `
    -WindowEnd $endIso

Invoke-AzCapture -Arguments @(
    "network", "private-endpoint", "list", "--resource-group", $ResourceGroup,
    "--output", "json"
) -OutputPath (Join-Path $evidencePath "private-endpoints.json") -Optional | Out-Null

Invoke-AzCapture -Arguments @(
    "network", "private-dns", "zone", "list", "--resource-group", $ResourceGroup,
    "--output", "json"
) -OutputPath (Join-Path $evidencePath "private-dns-zones.json") -Optional | Out-Null

$patternAnalyzer = Join-Path $PSScriptRoot "Get-LatencyObservedPattern.ps1"
if (Test-Path -LiteralPath $patternAnalyzer -PathType Leaf) {
    try {
        & $patternAnalyzer -EvidencePath $evidencePath
    }
    catch {
        $analysisErrorPath = Join-Path $evidencePath "observed-pattern-analysis-error.txt"
        $_ | Out-String | Set-Content -LiteralPath $analysisErrorPath -Encoding utf8
        Write-Warning "Observed-pattern analysis failed. Details: $analysisErrorPath"
    }
}
else {
    Write-Warning "Observed-pattern analyzer was not found at $patternAnalyzer."
}

Get-ChildItem -LiteralPath $evidencePath -File |
    Select-Object Name, Length, LastWriteTimeUtc |
    Export-Csv -LiteralPath (Join-Path $evidencePath "manifest.csv") -NoTypeInformation -Encoding utf8

$archivePath = "$evidencePath.zip"
Compress-Archive -Path (Join-Path $evidencePath "*") -DestinationPath $archivePath -Force

Write-Host ""
Write-Host "Collection complete."
Write-Host "Evidence: $evidencePath"
Write-Host "Archive:  $archivePath"
Write-Host "Review and redact request/response content and headers before sharing the archive."
