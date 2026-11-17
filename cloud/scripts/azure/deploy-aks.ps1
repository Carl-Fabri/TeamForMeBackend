<#
.SYNOPSIS
  Despliega el módulo MS.Events en AKS (requiere haber corrido deploy.ps1 -WithAks).
.EXAMPLE
  ./scripts/azure/deploy-aks.ps1 -ResourceGroup rg-teamforme
#>
param(
    [string]$ResourceGroup = "rg-teamforme",
    [string]$Prefix = "teamforme",
    [string]$ImageTag = "latest"
)
$ErrorActionPreference = "Stop"
$root = Resolve-Path (Join-Path $PSScriptRoot "../..")

$outputs = az deployment group show -g $ResourceGroup -n "teamforme-base" --query properties.outputs -o json | ConvertFrom-Json
$acr = $outputs.acrName.value
$kvUri = $outputs.keyVaultUri.value
$clientId = $outputs.identityClientId.value
$aks = "aks-$Prefix"

Write-Host "==> Credenciales de $aks" -ForegroundColor Cyan
az aks get-credentials -g $ResourceGroup -n $aks --overwrite-existing
if ($LASTEXITCODE -ne 0) { throw "No se encontró el clúster $aks. ¿Desplegaste con -WithAks?" }

Write-Host "==> Renderizando overlay AKS (ACR=$acr)" -ForegroundColor Cyan
$manifest = kubectl kustomize (Join-Path $root "k8s/ms-events/overlays/aks") | Out-String
$manifest = $manifest.Replace("__ACR_NAME__", $acr).Replace("__KEYVAULT_URI__", $kvUri).Replace("__IDENTITY_CLIENT_ID__", $clientId)
$manifest = $manifest.Replace("/teamforme/ms-events:latest", "/teamforme/ms-events:$ImageTag")
$manifest | kubectl apply -f -

Write-Host "==> VPA en modo recomendación" -ForegroundColor Cyan
kubectl apply -f (Join-Path $root "k8s/ms-events/tools/vpa.yaml")

kubectl rollout status deployment/ms-events -n teamforme --timeout=180s
kubectl get pods,svc,hpa -n teamforme
Write-Host "`nIP pública (puede tardar 1-2 min): kubectl get svc ms-events -n teamforme -w"
Write-Host "Prueba de carga:  kubectl apply -f k8s/ms-events/tools/loadtest-job.yaml ; kubectl get hpa -n teamforme -w"
