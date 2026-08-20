#Requires -Version 7.0

<#
.SYNOPSIS
Classifies the most likely latency pattern in a collected evidence directory.

.DESCRIPTION
Reads the evidence produced by Invoke-LatencyDiagnostic.ps1 and creates:

- observed-pattern-summary.txt
- observed-pattern-summary.json

The classification is rule-based. It identifies patterns supported by the available
evidence; it does not claim to prove root cause.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateScript({ Test-Path -LiteralPath $_ -PathType Container })]
    [string]$EvidencePath,

    [ValidateRange(0.1, 300)]
    [double]$SlowClientFirstByteSeconds = 5,

    [ValidateRange(0.05, 60)]
    [double]$SlowNetworkPhaseSeconds = 1,

    [ValidateRange(100, 300000)]
    [double]$SlowModelFirstResponseMilliseconds = 5000,

    [ValidateRange(100, 300000)]
    [double]$SlowAuthenticationMilliseconds = 2000,

    [ValidateRange(10, 300000)]
    [double]$SlowFlushMilliseconds = 500,

    [ValidateRange(1, 3600)]
    [double]$SlowTotalSeconds = 15
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Read-JsonFile {
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return $null
    }

    try {
        return Get-Content -LiteralPath $Path -Raw -Encoding utf8 | ConvertFrom-Json
    }
    catch {
        return $null
    }
}

function Test-JsonRows {
    param([Parameter(Mandatory)][string]$Path)

    $value = Read-JsonFile -Path $Path
    if ($null -eq $value) {
        return $false
    }

    if ($value -is [array]) {
        return $value.Count -gt 0
    }

    if ($value.PSObject.Properties.Name -contains "value") {
        return @($value.value).Count -gt 0
    }

    return $value.PSObject.Properties.Count -gt 0
}

function Read-KeyValueFile {
    param([Parameter(Mandatory)][string]$Path)

    $values = @{}
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return $values
    }

    foreach ($line in Get-Content -LiteralPath $Path -Encoding utf8) {
        if ($line -match "^\s*([^=]+)=(.*)\s*$") {
            $values[$matches[1].Trim()] = $matches[2].Trim()
        }
    }
    return $values
}

function Get-DoubleValue {
    param(
        [Parameter(Mandatory)][hashtable]$Values,
        [Parameter(Mandatory)][string]$Name
    )

    if (-not $Values.ContainsKey($Name)) {
        return $null
    }

    $number = 0.0
    if ([double]::TryParse(
        $Values[$Name],
        [Globalization.NumberStyles]::Float,
        [Globalization.CultureInfo]::InvariantCulture,
        [ref]$number
    )) {
        return $number
    }
    return $null
}

function Get-MetricSummary {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$MetricName
    )

    $document = Read-JsonFile -Path $Path
    if ($null -eq $document) {
        return $null
    }

    $metrics = if ($document.PSObject.Properties.Name -contains "value") {
        @($document.value)
    }
    else {
        @($document)
    }

    $metric = $metrics | Where-Object {
        $name = if ($_.name -is [string]) { $_.name } else { $_.name.value }
        $name -eq $MetricName
    } | Select-Object -First 1

    if ($null -eq $metric) {
        return $null
    }

    $samples = @()
    foreach ($series in @($metric.timeseries)) {
        foreach ($dataPoint in @($series.data)) {
            foreach ($property in @("average", "maximum", "total", "minimum")) {
                if ($dataPoint.PSObject.Properties.Name -contains $property -and $null -ne $dataPoint.$property) {
                    $samples += [double]$dataPoint.$property
                    break
                }
            }
        }
    }

    if ($samples.Count -eq 0) {
        return $null
    }

    $unit = if ($metric.PSObject.Properties.Name -contains "unit") {
        [string]$metric.unit
    }
    else {
        ""
    }

    return [pscustomobject]@{
        Name    = $MetricName
        Average = ($samples | Measure-Object -Average).Average
        Maximum = ($samples | Measure-Object -Maximum).Maximum
        Unit    = $unit
        Count   = $samples.Count
    }
}

function Convert-MetricToMilliseconds {
    param([Parameter(Mandatory)]$Metric)

    if ($Metric.Unit -match "(?i)second" -and $Metric.Unit -notmatch "(?i)milli") {
        return [double]$Metric.Average * 1000
    }
    return [double]$Metric.Average
}

function Find-MillisecondDuration {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string[]]$FieldPatterns
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return $null
    }

    $content = Get-Content -LiteralPath $Path -Raw -Encoding utf8
    $values = @()
    foreach ($fieldPattern in $FieldPatterns) {
        $pattern = "(?i)[`"']?(?:$fieldPattern)[`"']?\s*[:=]\s*[`"']?([0-9]+(?:\.[0-9]+)?)"
        foreach ($match in [regex]::Matches($content, $pattern)) {
            $values += [double]::Parse($match.Groups[1].Value, [Globalization.CultureInfo]::InvariantCulture)
        }
    }

    if ($values.Count -eq 0) {
        return $null
    }
    return ($values | Measure-Object -Average).Average
}

function New-Pattern {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][int]$Score,
        [Parameter(Mandatory)][string]$Confidence,
        [Parameter(Mandatory)][string[]]$Evidence,
        [Parameter(Mandatory)][string]$NextAction
    )

    return [pscustomobject]@{
        pattern    = $Name
        score      = $Score
        confidence = $Confidence
        evidence   = $Evidence
        nextAction = $NextAction
    }
}

$resolvedEvidencePath = (Resolve-Path -LiteralPath $EvidencePath).Path
$patterns = [Collections.Generic.List[object]]::new()
$signals = [ordered]@{}

$clientTiming = Read-KeyValueFile -Path (Join-Path $resolvedEvidencePath "client-timing.txt")
$clientFirstByte = Get-DoubleValue -Values $clientTiming -Name "first_byte_s"
$clientTotal = Get-DoubleValue -Values $clientTiming -Name "total_s"
$dnsTime = Get-DoubleValue -Values $clientTiming -Name "dns_s"
$connectTime = Get-DoubleValue -Values $clientTiming -Name "connect_s"
$tlsTime = Get-DoubleValue -Values $clientTiming -Name "tls_s"

$signals.clientFirstByteSeconds = $clientFirstByte
$signals.clientTotalSeconds = $clientTotal
$signals.dnsSeconds = $dnsTime
$signals.connectSeconds = $connectTime
$signals.tlsSeconds = $tlsTime

$correlatedLogPath = Join-Path $resolvedEvidencePath "container-correlated.json"
$authMilliseconds = Find-MillisecondDuration -Path $correlatedLogPath -FieldPatterns @(
    "auth(?:entication)?_ms",
    "auth(?:entication)?DurationMs",
    "auth(?:entication)?_duration_ms"
)
$upstreamMilliseconds = Find-MillisecondDuration -Path $correlatedLogPath -FieldPatterns @(
    "upstream(?:FirstResponse|TimeToFirstResponse|Ttfr)_ms",
    "azureOpenAI(?:TimeToResponse|FirstResponse)Ms",
    "model(?:FirstResponse|Ttfr)_ms"
)
$flushMilliseconds = Find-MillisecondDuration -Path $correlatedLogPath -FieldPatterns @(
    "flush(?:Delay)?_ms",
    "firstFlushMs",
    "proxyFlushDelayMs"
)

$signals.authenticationMilliseconds = $authMilliseconds
$signals.upstreamFirstResponseMilliseconds = $upstreamMilliseconds
$signals.flushMilliseconds = $flushMilliseconds

$aoaiMetricPath = Join-Path $resolvedEvidencePath "azure-openai-metrics.json"
$modelFirstResponseMetric = Get-MetricSummary -Path $aoaiMetricPath -MetricName "AzureOpenAITimeToResponse"
$modelTotalMetric = Get-MetricSummary -Path $aoaiMetricPath -MetricName "AzureOpenAITTLTInMS"
$modelFirstResponseMilliseconds = if ($null -ne $upstreamMilliseconds) {
    $upstreamMilliseconds
}
elseif ($null -ne $modelFirstResponseMetric) {
    Convert-MetricToMilliseconds -Metric $modelFirstResponseMetric
}
else {
    $null
}
$modelTotalMilliseconds = if ($null -ne $modelTotalMetric) {
    Convert-MetricToMilliseconds -Metric $modelTotalMetric
}
else {
    $null
}

$signals.modelFirstResponseMilliseconds = $modelFirstResponseMilliseconds
$signals.modelTotalMilliseconds = $modelTotalMilliseconds

$hasAoaiFailures = Test-JsonRows -Path (Join-Path $resolvedEvidencePath "azure-openai-failures.json")
$hasContainerLifecycleEvents = Test-JsonRows -Path (Join-Path $resolvedEvidencePath "container-system-events.json")
$hasPostgresPressure = Test-JsonRows -Path (Join-Path $resolvedEvidencePath "postgres-pressure.json")
$signals.azureOpenAIFailuresOrThrottling = $hasAoaiFailures
$signals.containerLifecycleEvents = $hasContainerLifecycleEvents
$signals.postgresPressureEvents = $hasPostgresPressure

if ($hasAoaiFailures) {
    $patterns.Add((New-Pattern `
        -Name "Azure OpenAI throttling, retry, or service failure" `
        -Score 100 `
        -Confidence "High" `
        -Evidence @("Azure OpenAI failure query returned 429, retry, throttling, or 5xx evidence in the selected window.") `
        -NextAction "Inspect status-code dimensions, deployment utilization, quota, concurrency, and retry logs. Determine whether delay accumulated before the successful response.")) | Out-Null
}

$networkEvidence = @()
if ($null -ne $dnsTime -and $dnsTime -ge $SlowNetworkPhaseSeconds) {
    $networkEvidence += "Client DNS lookup was $([math]::Round($dnsTime, 3)) seconds."
}
if ($null -ne $connectTime -and $connectTime -ge $SlowNetworkPhaseSeconds) {
    $networkEvidence += "Client TCP connect time was $([math]::Round($connectTime, 3)) seconds."
}
if ($null -ne $tlsTime -and $tlsTime -ge $SlowNetworkPhaseSeconds) {
    $networkEvidence += "Client TLS time was $([math]::Round($tlsTime, 3)) seconds."
}
if ($networkEvidence.Count -gt 0) {
    $patterns.Add((New-Pattern `
        -Name "DNS, connection, or TLS path latency" `
        -Score 95 `
        -Confidence "High" `
        -Evidence $networkEvidence `
        -NextAction "Run the in-container network checks and inspect DNS forwarding, private endpoint resolution, routing, firewall/NVA inspection, and public hairpin behavior.")) | Out-Null
}

if ($null -ne $authMilliseconds -and $authMilliseconds -ge $SlowAuthenticationMilliseconds) {
    $authEvidence = @("Authentication or validation averaged $([math]::Round($authMilliseconds, 0)) ms.")
    if ($hasPostgresPressure) {
        $authEvidence += "PostgreSQL pressure or wait evidence overlaps the same window."
    }
    $patterns.Add((New-Pattern `
        -Name "Authentication or OpenWebUI validation latency" `
        -Score 94 `
        -Confidence $(if ($hasPostgresPressure) { "High" } else { "Medium" }) `
        -Evidence $authEvidence `
        -NextAction "Compare the validation endpoint directly, inspect OpenWebUI dependencies and PostgreSQL, and test a short-lived validation cache or internal validation route.")) | Out-Null
}

if ($null -ne $flushMilliseconds -and $flushMilliseconds -ge $SlowFlushMilliseconds) {
    $patterns.Add((New-Pattern `
        -Name "Proxy or ingress response buffering" `
        -Score 93 `
        -Confidence "High" `
        -Evidence @("First-chunk flush delay averaged $([math]::Round($flushMilliseconds, 0)) ms.") `
        -NextAction "Inspect response compression, middleware, reverse proxy buffering, ingress behavior, and explicit response flushing.")) | Out-Null
}

if (
    $null -ne $clientFirstByte -and
    $clientFirstByte -ge $SlowClientFirstByteSeconds -and
    $null -ne $modelFirstResponseMilliseconds -and
    $modelFirstResponseMilliseconds -lt $SlowModelFirstResponseMilliseconds -and
    (($clientFirstByte * 1000) - $modelFirstResponseMilliseconds) -ge 2000
) {
    $patterns.Add((New-Pattern `
        -Name "Application or proxy overhead after a timely model response" `
        -Score 90 `
        -Confidence "Medium" `
        -Evidence @(
            "Client first byte was $([math]::Round($clientFirstByte, 3)) seconds.",
            "Azure OpenAI first response was approximately $([math]::Round($modelFirstResponseMilliseconds, 0)) ms."
        ) `
        -NextAction "Use the T0-T4 application timestamps to isolate authentication, proxy preparation, ingress, buffering, and client delivery time.")) | Out-Null
}

if ($null -ne $modelFirstResponseMilliseconds -and $modelFirstResponseMilliseconds -ge $SlowModelFirstResponseMilliseconds) {
    $patterns.Add((New-Pattern `
        -Name "Azure OpenAI first-response latency" `
        -Score 88 `
        -Confidence $(if ($null -ne $upstreamMilliseconds) { "High" } else { "Medium" }) `
        -Evidence @("Azure OpenAI first response was approximately $([math]::Round($modelFirstResponseMilliseconds, 0)) ms.") `
        -NextAction "Inspect prompt tokens, cache behavior, deployment utilization, concurrency, model settings, content filtering, and throttling.")) | Out-Null
}

if (
    $null -ne $modelTotalMilliseconds -and
    $modelTotalMilliseconds -ge ($SlowTotalSeconds * 1000) -and
    ($null -eq $modelFirstResponseMilliseconds -or $modelTotalMilliseconds -ge ($modelFirstResponseMilliseconds * 2))
) {
    $patterns.Add((New-Pattern `
        -Name "Slow token generation or long response after first token" `
        -Score 75 `
        -Confidence "Medium" `
        -Evidence @("Azure OpenAI total latency was approximately $([math]::Round($modelTotalMilliseconds, 0)) ms, materially longer than first-response time.") `
        -NextAction "Inspect generated-token counts, output limits, time-between-token metrics, reasoning settings, and downstream client backpressure.")) | Out-Null
}

if ($hasContainerLifecycleEvents) {
    $score = if ($null -ne $clientFirstByte -and $clientFirstByte -ge $SlowClientFirstByteSeconds) { 82 } else { 58 }
    $confidence = if ($score -ge 80) { "Medium" } else { "Low" }
    $patterns.Add((New-Pattern `
        -Name "Container Apps lifecycle, scaling, restart, or probe activity" `
        -Score $score `
        -Confidence $confidence `
        -Evidence @("Container Apps system events matching startup, scaling, replica, restart, probe, timeout, or failure terms overlap the selected window.") `
        -NextAction "Compare the slow request with replica creation, startup and readiness events, minimum replicas, restarts, and revision health.")) | Out-Null
}

if ($hasPostgresPressure -and ($null -eq $authMilliseconds -or $authMilliseconds -lt $SlowAuthenticationMilliseconds)) {
    $patterns.Add((New-Pattern `
        -Name "PostgreSQL pressure or wait activity" `
        -Score 60 `
        -Confidence "Low" `
        -Evidence @("PostgreSQL logs or Query Store returned error, timeout, deadlock, connection, wait, long-running, or temporary-file evidence.") `
        -NextAction "Correlate the exact OpenWebUI dependency duration with CPU, connections, IOPS, waits, and Query Store runtime before assigning causality.")) | Out-Null
}

if ($patterns.Count -eq 0) {
    $missing = @()
    if ($null -eq $clientFirstByte) { $missing += "client timing" }
    if ($null -eq $modelFirstResponseMilliseconds) { $missing += "Azure OpenAI first-response timing" }
    if (-not (Test-Path -LiteralPath $correlatedLogPath)) { $missing += "correlated application logs" }

    $patterns.Add((New-Pattern `
        -Name "No conclusive latency pattern detected" `
        -Score 0 `
        -Confidence "Insufficient evidence" `
        -Evidence @("The available evidence did not cross a configured classification threshold.", "Missing or unavailable signals: $($missing -join ', ').") `
        -NextAction "Confirm the UTC window and correlation ID, wait for telemetry ingestion, and verify that client timing, application stage timing, Azure OpenAI, Container Apps, and PostgreSQL diagnostics are present.")) | Out-Null
}

$rankedPatterns = @($patterns | Sort-Object score -Descending)
$primary = $rankedPatterns[0]
$result = [ordered]@{
    generatedUtc = [DateTime]::UtcNow.ToString("o")
    evidencePath = $resolvedEvidencePath
    primaryPattern = $primary
    additionalPatterns = @($rankedPatterns | Select-Object -Skip 1)
    signals = $signals
    thresholds = [ordered]@{
        slowClientFirstByteSeconds = $SlowClientFirstByteSeconds
        slowNetworkPhaseSeconds = $SlowNetworkPhaseSeconds
        slowModelFirstResponseMilliseconds = $SlowModelFirstResponseMilliseconds
        slowAuthenticationMilliseconds = $SlowAuthenticationMilliseconds
        slowFlushMilliseconds = $SlowFlushMilliseconds
        slowTotalSeconds = $SlowTotalSeconds
    }
    disclaimer = "Rule-based classification identifies patterns supported by available evidence; it does not prove root cause."
}

$jsonPath = Join-Path $resolvedEvidencePath "observed-pattern-summary.json"
$textPath = Join-Path $resolvedEvidencePath "observed-pattern-summary.txt"
$result | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $jsonPath -Encoding utf8

$text = [Collections.Generic.List[string]]::new()
$text.Add("Observed latency pattern") | Out-Null
$text.Add("========================") | Out-Null
$text.Add("") | Out-Null
$text.Add("Primary pattern: $($primary.pattern)") | Out-Null
$text.Add("Confidence: $($primary.confidence)") | Out-Null
$text.Add("") | Out-Null
$text.Add("Supporting evidence:") | Out-Null
foreach ($evidenceItem in $primary.evidence) {
    $text.Add("- $evidenceItem") | Out-Null
}
$text.Add("") | Out-Null
$text.Add("Recommended next action:") | Out-Null
$text.Add($primary.nextAction) | Out-Null

if ($rankedPatterns.Count -gt 1) {
    $text.Add("") | Out-Null
    $text.Add("Additional patterns to review:") | Out-Null
    foreach ($pattern in $rankedPatterns | Select-Object -Skip 1) {
        $text.Add("- $($pattern.pattern) [$($pattern.confidence)]") | Out-Null
    }
}

$text.Add("") | Out-Null
$text.Add("Important: $($result.disclaimer)") | Out-Null
$text | Set-Content -LiteralPath $textPath -Encoding utf8

Write-Host ""
Write-Host "Observed pattern: $($primary.pattern)"
Write-Host "Confidence: $($primary.confidence)"
Write-Host "Summary: $textPath"
