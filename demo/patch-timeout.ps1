# Patches the live logic-cst8917-main Logic App to use a longer approval timeout.
# Safe to re-run: GETs the current workflow, changes one parameter, PUTs it back.
#
# Usage:  .\demo\patch-timeout.ps1 [-Timeout PT10M]
# Requires:  .\demo\prime.ps1 already dot-sourced (needs $env:RG).

param(
    [string]$Timeout = "PT10M"
)

$ErrorActionPreference = "Stop"

if (-not $env:RG) {
    throw "Shell not primed. Run:  . .\demo\prime.ps1"
}

$sub = az account show --query id -o tsv
if (-not $sub) { throw "Not logged in. Run: az login" }

$uri = "https://management.azure.com/subscriptions/$sub/resourceGroups/$($env:RG)/providers/Microsoft.Logic/workflows/logic-cst8917-main?api-version=2019-05-01"

Write-Host "Fetching current workflow definition..."
$wf = az rest --method get --uri $uri | ConvertFrom-Json
$current = $wf.properties.parameters.approvalTimeout.value
Write-Host "  current approvalTimeout: $current"
Write-Host "  new approvalTimeout    : $Timeout"

if ($current -eq $Timeout) {
    Write-Host "Already set to $Timeout. Nothing to do." -ForegroundColor Yellow
    exit 0
}

$wf.properties.parameters.approvalTimeout.value = $Timeout

$body = @{
    location   = $wf.location
    properties = @{
        state      = $wf.properties.state
        definition = $wf.properties.definition
        parameters = $wf.properties.parameters
    }
} | ConvertTo-Json -Depth 100 -Compress

$tmp = Join-Path $env:TEMP "wf-patch-$(Get-Random).json"
$body | Out-File -Encoding utf8 -FilePath $tmp

try {
    Write-Host "PUT workflow back..."
    $result = az rest --method put --uri $uri --body "@$tmp" --query "properties.parameters.approvalTimeout.value" -o tsv
    Write-Host "Done. Live approvalTimeout = $result" -ForegroundColor Green
}
finally {
    Remove-Item -Force -ErrorAction SilentlyContinue $tmp
}
