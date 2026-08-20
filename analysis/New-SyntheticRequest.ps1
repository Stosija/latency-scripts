#Requires -Version 7.0

<#
.SYNOPSIS
Creates a generic synthetic streaming request body for the latency diagnostic.

.DESCRIPTION
The generated request contains no customer data. Adjust the property names to match the
actual API contract used by the Codex proxy before running the diagnostic collector.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$Model,

    [string]$OutputPath = (Join-Path $PWD "synthetic-request.json"),

    [ValidateRange(1, 1000)]
    [int]$MaxOutputTokens = 150
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$request = [ordered]@{
    model             = $Model
    input             = "Return exactly five short numbered lines. This is a synthetic latency test."
    stream            = $true
    background        = $false
    max_output_tokens = $MaxOutputTokens
}

$request | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $OutputPath -Encoding utf8
Write-Host "Synthetic request created at $OutputPath"
Write-Host "Confirm that the field names match the proxy's actual API contract before use."
