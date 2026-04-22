# Sends B-2 (approve) and B-3 (reject), polls App Insights for links, and clicks them.
# Usage:  .\demo\approve-reject.ps1
# Requires:  env vars set by  . .\demo\prime.ps1

$ErrorActionPreference = "Stop"

if (-not $env:RG)  { throw "Shell not primed. Run:  . .\demo\prime.ps1" }
if (-not $env:SB)  { throw "SB env var missing. Re-run:  . .\demo\prime.ps1" }
if (-not $env:AIB) { throw "AIB env var missing. Re-run:  . .\demo\prime.ps1" }

function Send-SB($payload) {
    $token = az account get-access-token --resource "https://servicebus.azure.net" --query accessToken -o tsv
    $json  = $payload | ConvertTo-Json -Compress
    Invoke-WebRequest -UseBasicParsing -Method POST `
        -Uri "https://$($env:SB).servicebus.windows.net/expense-requests/messages" `
        -Headers @{ Authorization = "Bearer $token"; "Content-Type" = "application/json" } `
        -Body $json | Out-Null
}

$tStart = (Get-Date).ToUniversalTime().ToString("o")

Send-SB @{ employee_name="Bob2";     employee_email="b@t.com"; amount=1500; category="travel";    description="B2b flights"; manager_email="m@t.com" }
Send-SB @{ employee_name="Charlie2"; employee_email="c@t.com"; amount=2500; category="equipment"; description="B3b monitor"; manager_email="m@t.com" }
Write-Host "Sent. Polling for links..."

$links = $null
foreach ($i in 1..8) {
    Start-Sleep 8
    $query = "traces | where timestamp > datetime($tStart) | where message startswith 'APPROVAL_LINKS' | project timestamp, message | order by timestamp asc"
    $rows  = az monitor app-insights query --app $env:AIB --analytics-query $query --query "tables[0].rows" -o json | ConvertFrom-Json
    if ($rows.Count -ge 2) {
        $links = $rows | ForEach-Object {
            [pscustomobject]@{
                approve = (($_[1] -split 'approve=')[1] -split ' reject=')[0]
                reject  =  ($_[1] -split 'reject=')[1]
            }
        }
        break
    }
    Write-Host "  waited $($i*8)s, got $($rows.Count) links"
}

if (-not $links -or $links.Count -lt 2) {
    throw "Never saw 2 APPROVAL_LINKS entries. Check Function App logs."
}

Write-Host "Got $($links.Count) links. Clicking NOW."

$s1 = (Invoke-WebRequest -Uri $links[0].approve -UseBasicParsing -TimeoutSec 30).StatusCode
Write-Host "approve -> $s1"

$s2 = (Invoke-WebRequest -Uri $links[1].reject -UseBasicParsing -TimeoutSec 30).StatusCode
Write-Host "reject  -> $s2"
