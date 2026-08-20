#Requires -Version 7.0

<#
.SYNOPSIS
Runs unauthenticated DNS and network-phase checks from inside the Codex proxy Container App.

.DESCRIPTION
Uses az containerapp exec to resolve the Azure OpenAI, PostgreSQL, and OpenWebUI hostnames
from the running proxy container. It also measures DNS, connect, TLS, first-byte, and total
time for Azure OpenAI and OpenWebUI. HTTP 401 or 403 is expected for unauthenticated probes.

No application or Azure OpenAI credentials are transmitted by this script.
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
    [ValidatePattern("^[A-Za-z0-9.-]+$")]
    [string]$AoaiHost,

    [Parameter(Mandatory)]
    [ValidatePattern("^[A-Za-z0-9.-]+$")]
    [string]$PostgresHost,

    [Parameter(Mandatory)]
    [ValidatePattern("^[A-Za-z0-9.-]+$")]
    [string]$OpenWebUiHost,

    [string]$OutputPath = (Join-Path $PWD "container-network-checks.txt")
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
    throw "Azure CLI was not found."
}

& az account set --subscription $SubscriptionId
if ($LASTEXITCODE -ne 0) {
    throw "Unable to select subscription '$SubscriptionId'. Run 'az login' and retry."
}

$safeOpenWebUiHost = if ($OpenWebUiHost -match "^[A-Za-z0-9.-]+$") {
    $OpenWebUiHost
}
else {
    throw "OpenWebUiHost contains unsupported characters."
}

$containerCommand = @"
set -eu
date -u
echo '--- resolver configuration ---'
cat /etc/resolv.conf
echo '--- hostname resolution ---'
(getent ahosts '$AoaiHost' || nslookup '$AoaiHost' || true)
(getent ahosts '$PostgresHost' || nslookup '$PostgresHost' || true)
(getent ahosts '$safeOpenWebUiHost' || nslookup '$safeOpenWebUiHost' || true)
echo '--- repeated Azure OpenAI resolution ---'
i=1
while [ `$i -le 5 ]; do
  date -u
  time (getent hosts '$AoaiHost' || nslookup '$AoaiHost') >/dev/null
  i=`$((i+1))
done
echo '--- unauthenticated HTTPS timing ---'
curl -sS -o /dev/null -w 'aoai code=%{http_code} dns=%{time_namelookup}s connect=%{time_connect}s tls=%{time_appconnect}s first_byte=%{time_starttransfer}s total=%{time_total}s remote=%{remote_ip}\n' 'https://$AoaiHost/'
curl -sS -o /dev/null -w 'openwebui code=%{http_code} dns=%{time_namelookup}s connect=%{time_connect}s tls=%{time_appconnect}s first_byte=%{time_starttransfer}s total=%{time_total}s remote=%{remote_ip}\n' 'https://$safeOpenWebUiHost/api/v1/models'
"@

Write-Host "Running network checks inside '$ProxyApp'..."
$output = & az containerapp exec `
    --resource-group $ResourceGroup `
    --name $ProxyApp `
    --command "/bin/sh -c `"$containerCommand`"" 2>&1
$exitCode = $LASTEXITCODE
$output | Tee-Object -FilePath $OutputPath

if ($exitCode -ne 0) {
    throw "The in-container command failed with exit code $exitCode. If the image lacks sh, curl, getent, and nslookup, use the application's approved diagnostic image or execute equivalent checks through application telemetry."
}

Write-Host "Results saved to $OutputPath"
