# Sends two Service Bus messages and clicks the approve + reject links.
# Exercises the B-2 (manager approve) and B-3 (manager reject) paths.
#
# Usage:  .\demo\test-version-b-approval.ps1
# Self-contained - reads env vars ($env:RG, $env:SB, $env:FB) set by .\demo\prime.ps1,
# but does not need prime.ps1 functions in scope.

$ErrorActionPreference = "Stop"

if (-not $env:RG) { throw "Shell not primed. Run:  . .\demo\prime.ps1  first." }
if (-not $env:SB) { throw "SB env var missing. Re-run:  . .\demo\prime.ps1" }
if (-not $env:FB) { throw "FB env var missing. Re-run:  . .\demo\prime.ps1" }

if (-not $env:AIB) {
    Write-Host "Fetching AIB..."
    $env:AIB = az monitor app-insights component show -g $env:RG --app $env:FB --query appId -o tsv
}

function Send-ToQueue($payload) {
    $token = az account get-access-token --resource "https://servicebus.azure.net" --query accessToken -o tsv
    $json  = $payload | ConvertTo-Json -Compress
    $uri   = "https://$($env:SB).servicebus.windows.net/expense-requests/messages"
    $hdrs  = @{ Authorization = "Bearer $token"; "Content-Type" = "application/json" }
    Invoke-WebRequest -UseBasicParsing -Method POST -Uri $uri -Headers $hdrs -Body $json | Out-Null
}

$tStart = (Get-Date).ToUniversalTime().ToString("o")

Write-Host "Sending B-2 (manager approve - \$1,500 travel)..."
Send-ToQueue @{
    employee_name  = "BobApprove"
    employee_email = "b@t.com"
    amount         = 1500
    category       = "travel"
    description    = "B2 flights demo"
    manager_email  = "m@t.com"
}

Write-Host "Sending B-3 (manager reject - \$2,500 equipment)..."
Send-ToQueue @{
    employee_name  = "CharlieReject"
    employee_email = "c@t.com"
    amount         = 2500
    category       = "equipment"
    description    = "B3 monitor demo"
    manager_email  = "m@t.com"
}

Write-Host "`nPolling App Insights for APPROVAL_LINKS..."
$links   = $null
$maxWait = 80
$waited  = 0
while ($waited -lt $maxWait) {
    Start-Sleep 8; $waited += 8
    $query = "traces | where timestamp > datetime($tStart) | where message startswith 'APPROVAL_LINKS' | project timestamp, message | order by timestamp asc | take 10"
    $rows  = az monitor app-insights query --app $env:AIB --analytics-query $query --query "tables[0].rows" -o json | ConvertFrom-Json
    if ($rows.Count -ge 2) {
        $links = @()
        foreach ($r in $rows) {
            $msg     = $r[1]
            $approve = (($msg -split 'approve=')[1] -split ' reject=')[0]
            $reject  =  ($msg -split 'reject=')[1]
            $links  += [pscustomobject]@{ time = $r[0]; approve = $approve; reject = $reject }
        }
        break
    }
    Write-Host "  waited ${waited}s, got $($rows.Count) links so far..."
}

if (-not $links -or $links.Count -lt 2) {
    throw "Only got $($links.Count) approval links after ${waited}s. Check the Function App logs."
}

Write-Host "Got $($links.Count) pending approvals." -ForegroundColor Green

Write-Host "`nClicking APPROVE on link 1 (B-2)..."
try {
    $s1 = (Invoke-WebRequest -Uri $links[0].approve -UseBasicParsing -TimeoutSec 30).StatusCode
    Write-Host "  status: $s1" -ForegroundColor Green
} catch {
    Write-Host "  FAILED: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host "  (If 502, the approvalTimeout expired. Run .\demo\patch-timeout.ps1 to bump it.)" -ForegroundColor Yellow
}

Write-Host "`nClicking REJECT on link 2 (B-3)..."
try {
    $s2 = (Invoke-WebRequest -Uri $links[1].reject -UseBasicParsing -TimeoutSec 30).StatusCode
    Write-Host "  status: $s2" -ForegroundColor Green
} catch {
    Write-Host "  FAILED: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host "  (If 502, the approvalTimeout expired. Run .\demo\patch-timeout.ps1 to bump it.)" -ForegroundColor Yellow
}

Write-Host "`nWaiting 15s then checking main LA runs..."
Start-Sleep 15
$sub = az account show --query id -o tsv
az rest --method get `
    --uri "https://management.azure.com/subscriptions/$sub/resourceGroups/$($env:RG)/providers/Microsoft.Logic/workflows/logic-cst8917-main/runs?api-version=2016-06-01" `
    --query "value[0:4].{name:name, status:properties.status, start:properties.startTime}" -o table

Write-Host "`nLatest notifier runs:"
foreach ($wf in "logic-cst8917-notify-approved", "logic-cst8917-notify-rejected") {
    Write-Host "--- $wf ---"
    az rest --method get `
        --uri "https://management.azure.com/subscriptions/$sub/resourceGroups/$($env:RG)/providers/Microsoft.Logic/workflows/$wf/runs?api-version=2016-06-01" `
        --query "value[0:2].{name:name, status:properties.status, time:properties.startTime}" -o table
}
