## What the script does

The script:

1. Selects the supplied Azure subscription.
2. Resolves the Container Apps, Container Apps environment, Azure OpenAI, and
   PostgreSQL resource IDs.
3. Resolves an existing Log Analytics workspace.
4. Creates or updates a diagnostic setting named `<application-name>-latency-review`.
5. Enables selected Container Apps, Azure OpenAI, PostgreSQL, and Entra logs.
6. Enables PostgreSQL Query Store in `top` mode and wait sampling in `all`
   mode, unless explicitly skipped.
7. Enables exportable platform metrics through diagnostic settings.
8. Exports selected resource configuration without retrieving secrets.
9. Discovers supported metrics and collects the relevant metrics at one-minute
   intervals.
10. Runs latency and error queries against Log Analytics.
11. Writes all results to a local output folder for review.

The script modifies diagnostic configuration and can change a Container Apps
environment from no logging to the `azure-monitor` logging destination.

Diagnostic settings only affect telemetry generated after they are enabled.
Run the script once to configure logging, reproduce the latency, wait several
minutes for ingestion, and run it again to collect the resulting logs.

## Prerequisites

- PowerShell 5.1 or later
- Azure CLI installed
- The Azure CLI `containerapp` and `log-analytics` extensions
- An authenticated Azure CLI session:

```powershell
az login
```

- Access to the target subscription
- Contributor or Monitoring Contributor access to create resource diagnostic
  settings
- Permission to update the Container Apps managed environment when its logging
  destination must be changed
- Log Analytics Contributor access to the destination workspace
- Appropriate Entra administrator and monitoring permissions to configure
  tenant-level sign-in logs

The script enables these sources in the selected Log Analytics workspace:

- Container Apps console, system, and HTTP logs
- Azure OpenAI categories `RequestResponse`, `AzureOpenAIRequestUsage`,
  `Audit`, and `Trace`
- PostgreSQL server logs, Query Store runtime/waits, and session data
- Entra interactive and noninteractive sign-in logs

Azure Monitor ingestion and retention charges can apply. Azure OpenAI request
logs, PostgreSQL logs, Container Apps HTTP logs, and Entra logs can contain
customer or user metadata.

Query Store can take up to approximately 20 minutes to persist its first batch
of data. Query Store captures query-performance information inside PostgreSQL;
review its data-governance implications before running against production.

## Run the script

Open PowerShell in this folder and run:

```powershell
.\collect-codex-latency.ps1 `
  -SubscriptionId '<subscription-id>' `
  -ResourceGroup '<resource-group>' `
  -ApplicationName '<application-name>' `
  -ProxyContainerAppName '<codex-proxy-container-app>' `
  -OpenWebUiContainerAppName '<openwebui-container-app>' `
  -AzureOpenAIResourceName '<azure-openai-resource-name>' `
  -AzureOpenAIDeploymentName '<azure-openai-deployment-name>' `
  -PostgreSqlServerName '<postgresql-server-name>' `
  -EntraAppDisplayName '<entra-app-display-name>' `
  -LogAnalyticsWorkspaceResourceId '<workspace-resource-id>' `
  -Hours 4
```

Use the actual Azure resource and deployment names. The names visible in the
diagram might differ from the deployed resource names.

If Azure OpenAI or PostgreSQL is in another resource group, add:

```powershell
-AzureOpenAIResourceGroup '<openai-resource-group>' `
-PostgreSqlResourceGroup '<postgres-resource-group>'
```

If the Container Apps environment already uses the desired Log Analytics
workspace, the script can normally discover it. Otherwise, supply the complete
workspace resource ID:

```powershell
-LogAnalyticsWorkspaceResourceId '/subscriptions/<subscription-id>/resourceGroups/<workspace-resource-group>/providers/Microsoft.OperationalInsights/workspaces/<workspace-name>'
```

`WorkspaceCustomerId` remains available as a fallback when the workspace is in
the selected subscription.

To include a separate Azure Load Balancer:

```powershell
-LoadBalancerResourceId '<load-balancer-resource-id>'
```

To collect data without creating or updating diagnostics:

```powershell
-SkipDiagnosticConfiguration
```

To configure Azure resource diagnostics but not tenant-wide Entra logs:

```powershell
-SkipEntraDiagnostics
```

To leave PostgreSQL Query Store and wait-sampling parameters unchanged:

```powershell
-SkipPostgreSqlQueryStoreConfiguration
```

## Parameters

| Parameter | Required | Description |
| --- | --- | --- |
| `SubscriptionId` | Yes | Azure subscription containing the resources |
| `ResourceGroup` | Yes | Default resource group for the Container Apps |
| `ApplicationName` | Yes | Application name used to derive default diagnostic setting and Entra app display names |
| `ProxyContainerAppName` | Yes | Codex ASP.NET Core proxy Container App |
| `OpenWebUiContainerAppName` | Yes | OpenWebUI backend Container App |
| `AzureOpenAIResourceName` | Yes | Underlying Azure OpenAI resource name |
| `AzureOpenAIDeploymentName` | Yes | Azure OpenAI model deployment name |
| `PostgreSqlServerName` | Yes | PostgreSQL Flexible Server name |
| `EntraAppDisplayName` | Yes | Complete display name of the Entra application |
| `AzureOpenAIResourceGroup` | No | Defaults to `ResourceGroup` |
| `PostgreSqlResourceGroup` | No | Defaults to `ResourceGroup` |
| `WorkspaceCustomerId` | No | Log Analytics workspace GUID |
| `LogAnalyticsWorkspaceResourceId` | No | Complete workspace ARM resource ID; required when it cannot be discovered |
| `DiagnosticSettingName` | No | Diagnostic setting name; defaults to `<application-name>-latency-review` |
| `LoadBalancerResourceId` | No | Optional Azure Load Balancer resource ID |
| `SkipDiagnosticConfiguration` | No | Collect without creating resource diagnostic settings |
| `SkipEntraDiagnostics` | No | Do not configure tenant-wide Entra sign-in logs |
| `SkipPostgreSqlQueryStoreConfiguration` | No | Do not enable PostgreSQL Query Store or wait sampling |
| `Hours` | No | Lookback period, from 1 to 168 hours; default is 4 |
| `OutputPath` | No | Results directory; defaults to the present working directory |

## Important output

| Output | What it shows |
| --- | --- |
| `resource-map.json` | Resource IDs and the UTC collection window |
| `*-config.json` | Region, scaling, ingress, networking, and SKU configuration |
| `*-diagnostic-settings.json` | Diagnostic settings currently enabled |
| `*-diagnostic-categories.json` | Diagnostic categories supported by each resource |
| `*-diagnostic-setting-created.json` | Diagnostic setting created or updated by the script |
| `entra-diagnostic-setting-created.json` | Tenant-level Entra diagnostic setting result |
| `entra-diagnostic-setting-error.txt` | Entra setup failed, usually because of tenant permissions |
| `postgres-query-store-enabled.json` | Result of enabling top-level query capture |
| `postgres-wait-sampling-enabled.json` | Result of enabling PostgreSQL wait sampling |
| `*-metric-*.json` | One-minute Azure Monitor metric data |
| `aca-http-latency-by-path.json` | Request counts and P50/P95/P99 by app and path |
| `aca-http-slowest-requests.json` | Slow requests, retries, status, replica, and request ID |
| `aca-system-events.json` | Scaling, probe, restart, crash, and provisioning events |
| `aca-console-errors.json` | Application exceptions, timeouts, retries, and connection errors |
| `azure-openai-resource-logs.json` | Azure OpenAI request, usage, audit, and trace events |
| `postgres-errors.json` | PostgreSQL errors, timeouts, connection failures, and deadlocks |
| `postgres-query-runtime.json` | Slow Query Store entries |
| `postgres-session-waits.json` | PostgreSQL session and wait-state counts |
| `entra-signins.json` | Entra sign-in latency and failures |
| `*-error.txt` | A missing table, missing diagnostic source, or query permission problem |

## How to interpret the results

- High Container Apps latency with low `AzureOpenAITimeToResponse` indicates
  proxy, authentication, buffering, ingress, or networking overhead.
- High `AzureOpenAITimeToResponse` with stable prompt size indicates model
  deployment load or capacity pressure.
- High `ProcessedPromptTokens` usually explains increased first-token latency.
- High `AzureOpenAINormalizedTBTInMS` or low
  `AzureOpenAITokenPerSecond` indicates slower token generation.
- A replica count of zero before a slow request indicates a cold start.
- Slow OpenWebUI `/api/v1/models` requests combined with PostgreSQL pressure
  implicate per-request bearer-key validation.
- Retries, 429 responses, connection-pool waits, and timeouts add hidden delay.

## Recommended proxy instrumentation

Platform metrics cannot fully separate authentication time from Azure OpenAI
time or response-buffering time. For definitive attribution, emit structured
JSON console events from the proxy:

- `proxy.request.received`
- `proxy.auth.completed`
- `proxy.openai.headers`
- `proxy.first_chunk.flushed`
- `proxy.request.completed`

Include these fields:

- `request_id`
- `auth_ms`
- `upstream_first_byte_ms`
- `first_chunk_flush_ms`
- `total_ms`
- `prompt_tokens`
- `output_tokens`
- `retry_count`
- `stream`
- `background`
- `status_code`

The script includes `proxy-structured-timings.kql` and runs it automatically.
The result remains empty until the proxy emits these events.
