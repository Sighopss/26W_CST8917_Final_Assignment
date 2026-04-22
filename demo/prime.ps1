# Priming script for the CST8917 final demo.
# Usage (from repo root):  . .\demo\prime.ps1
# Dot-source it so the env vars and functions persist in your shell.

$ErrorActionPreference = "Stop"

$env:RG  = "rg-cst8917-final"
$env:SB  = "sb-cst8917-4dad68"
$env:FA  = "func-cst8917-durable-4dad68"
$env:FB  = "func-cst8917-logic-4dad68"

Write-Host "Verifying Azure login..."
$sub = az account show --query id -o tsv 2>$null
if (-not $sub) { throw "Not logged in. Run: az login" }
Write-Host "  subscription: $sub"

Write-Host "Fetching App Insights ID for Version B..."
$env:AIB = (az monitor app-insights component show -g $env:RG --app $env:FB --query appId -o tsv)

Write-Host "Fetching Function A keys..."
$env:keyA = (az functionapp keys list -g $env:RG -n $env:FA --query "functionKeys.default" -o tsv)
$env:keyM = (az functionapp keys list -g $env:RG -n $env:FA --query "masterKey" -o tsv)

function Start-Exp($b) {
    $json = $b | ConvertTo-Json -Compress
    $uri  = "https://$($env:FA).azurewebsites.net/api/expenses?code=$($env:keyA)"
    Invoke-RestMethod -Method POST -ContentType "application/json" -Uri $uri -Body $json
}

function Get-Stat($id) {
    $uri = "https://$($env:FA).azurewebsites.net/runtime/webhooks/durabletask/instances/$id"
    Invoke-RestMethod -Headers @{ "x-functions-key" = $env:keyM } -Uri $uri
}

function Send-Dec($id, $d) {
    $body = @{ decision = $d; approver = "m@t.com"; comment = "via demo" } | ConvertTo-Json -Compress
    $uri  = "https://$($env:FA).azurewebsites.net/api/expenses/$id/decision?code=$($env:keyA)"
    Invoke-RestMethod -Method POST -ContentType "application/json" -Uri $uri -Body $body
}

function Send-SB($b) {
    $token = az account get-access-token --resource "https://servicebus.azure.net" --query accessToken -o tsv
    $json  = $b | ConvertTo-Json -Compress
    $uri   = "https://$($env:SB).servicebus.windows.net/expense-requests/messages"
    $headers = @{
        Authorization  = "Bearer $token"
        "Content-Type" = "application/json"
    }
    Invoke-WebRequest -UseBasicParsing -Method POST -Uri $uri -Headers $headers -Body $json | Out-Null
}

Write-Host ""
Write-Host "===================== READY =====================" -ForegroundColor Green
Write-Host "RG      : $env:RG"
Write-Host "FA      : $env:FA"
Write-Host "FB      : $env:FB"
Write-Host "AIB     : $env:AIB"
Write-Host ("keyA    : " + ([bool]$env:keyA))
Write-Host ("keyM    : " + ([bool]$env:keyM))
Write-Host ""
Write-Host "Functions loaded: Start-Exp, Get-Stat, Send-Dec, Send-SB" -ForegroundColor Cyan
Write-Host "================================================="
