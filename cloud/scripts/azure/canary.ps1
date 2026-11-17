<#
.SYNOPSIS
  Despliegue progresivo (canary) con puertas de calidad y rollback automático en Azure Container Apps.

.DESCRIPTION
  Algoritmo (progressive delivery):
    1. Fija el 100 % del tráfico en la revisión estable actual (azul).
    2. Crea la revisión nueva (verde) con 0 % de tráfico: blue-green, ambas activas.
    3. Para cada paso de peso w en -Steps (por defecto 10, 50, 100):
         a. Reparte el tráfico: estable = 100 − w, nueva = w (Envoy aplica los pesos).
         b. Envía -RequestsPerStep peticiones reales a través del gateway.
         c. Puerta de calidad: tasa de errores ≤ -MaxErrorRate y p95 ≤ -P95BudgetMs.
         d. Si la puerta falla → ROLLBACK: 100 % a la estable y se desactiva la nueva.
    4. Con 100 % en la nueva y la puerta superada, se desactiva la revisión anterior
       (salvo -KeepOldRevision, que la deja lista para un rollback instantáneo).

  -SimulateFailure crea la revisión nueva con Chaos__FailureRate=0.3 (30 % de errores 500)
  para demostrar que el algoritmo detecta la versión defectuosa y revierte solo.

.EXAMPLE
  ./scripts/azure/canary.ps1 -Version v2
  ./scripts/azure/canary.ps1 -Version v3-defectuosa -SimulateFailure
  ./scripts/azure/canary.ps1 -Version v2 -Steps 25,100 -RequestsPerStep 300
#>
param(
    [string]$ResourceGroup = "rg-teamforme",
    [string]$App = "ms-events",
    [Parameter(Mandatory = $true)][string]$Version,
    [string]$Image = "",
    [int[]]$Steps = @(10, 50, 100),
    [int]$RequestsPerStep = 200,
    [double]$MaxErrorRate = 0.02,
    [int]$P95BudgetMs = 2000,
    [int]$SettleSeconds = 20,
    [switch]$SimulateFailure,
    [switch]$KeepOldRevision
)

$ErrorActionPreference = "Stop"
[Console]::OutputEncoding = [Text.Encoding]::UTF8
$root = Resolve-Path (Join-Path $PSScriptRoot "../..")

function Step($text) { Write-Host "`n==> $text" -ForegroundColor Cyan }
function Invoke-Az { $out = az @args; if ($LASTEXITCODE -ne 0) { throw "Falló: az $args" }; return $out }

# Herramienta de carga (microservices/tools/TeamForMe.LoadTest), compilada una sola vez.
$toolDir = Join-Path $env:TEMP "tfm-load"
$tool = Join-Path $toolDir "tfm-load.dll"
if (-not (Test-Path $tool)) {
    dotnet build (Join-Path $root "microservices/tools/TeamForMe.LoadTest") -c Release -o $toolDir --nologo -v q | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "No se pudo compilar la herramienta de carga" }
}

$gatewayFqdn = Invoke-Az containerapp show -g $ResourceGroup -n gateway --query properties.configuration.ingress.fqdn -o tsv
$probeUrl = "https://$gatewayFqdn/api/events/_info"
Write-Host "Gateway: https://$gatewayFqdn"

# --- 1. Revisión estable -----------------------------------------------------------------
Step "1. Revisión estable (azul)"
Invoke-Az containerapp revision set-mode -g $ResourceGroup -n $App --mode multiple -o none
$traffic = Invoke-Az containerapp ingress traffic show -g $ResourceGroup -n $App -o json | ConvertFrom-Json
$pinned = $traffic | Where-Object { $_.revisionName -and $_.weight -gt 0 } | Sort-Object weight -Descending | Select-Object -First 1
$stable = if ($pinned) { $pinned.revisionName } else { Invoke-Az containerapp show -g $ResourceGroup -n $App --query properties.latestRevisionName -o tsv }
Write-Host "Estable: $stable"
Invoke-Az containerapp ingress traffic set -g $ResourceGroup -n $App --revision-weight "$stable=100" -o none

# --- 2. Revisión nueva con 0 % ----------------------------------------------------------
$suffix = (($Version.ToLower() -replace '[^a-z0-9-]', '-') + "-" + (Get-Date -Format "HHmmss")).Trim('-')
$candidate = "$App--$suffix"
Step "2. Creando la revisión nueva (verde) $candidate con 0 % de tráfico"
$envVars = @("APP_VERSION=$Version")
if ($SimulateFailure) {
    $envVars += "Chaos__FailureRate=0.3"
    Write-Host "  (versión defectuosa simulada: 30 % de respuestas 500)" -ForegroundColor Yellow
} else {
    $envVars += "Chaos__FailureRate=0"
}
$updateArgs = @("containerapp", "update", "-g", $ResourceGroup, "-n", $App, "--revision-suffix", $suffix, "--set-env-vars") + $envVars
if ($Image) { $updateArgs += @("--image", $Image) }
Invoke-Az @updateArgs -o none

$deadline = (Get-Date).AddMinutes(6)
do {
    Start-Sleep -Seconds 10
    $state = Invoke-Az containerapp revision show -g $ResourceGroup -n $App --revision $candidate --query "properties.provisioningState" -o tsv
    Write-Host "  estado de aprovisionamiento: $state"
} while ($state -ne "Provisioned" -and (Get-Date) -lt $deadline)
if ($state -ne "Provisioned") { throw "La revisión $candidate no terminó de aprovisionarse" }

# --- 3. Pasos progresivos con puerta de calidad ----------------------------------------
$history = @()
foreach ($w in $Steps) {
    Step "3. Paso canary: $w % a $Version / $(100 - $w) % a la estable"
    if ($w -ge 100) {
        Invoke-Az containerapp ingress traffic set -g $ResourceGroup -n $App --revision-weight "$candidate=100" "$stable=0" -o none
    } else {
        Invoke-Az containerapp ingress traffic set -g $ResourceGroup -n $App --revision-weight "$stable=$(100 - $w)" "$candidate=$w" -o none
    }
    Write-Host "  esperando $SettleSeconds s a que Envoy aplique los pesos..."
    Start-Sleep -Seconds $SettleSeconds

    $m = dotnet $tool distribution $probeUrl --count $RequestsPerStep --parallel 8 --json | ConvertFrom-Json

    # Análisis canary: la tasa de error se mide SOLO sobre las respuestas de la versión nueva
    # (con 10 % de tráfico, un 30 % de fallos del canary sería apenas un 3 % global).
    $newCount = 0; $newErrors = 0
    if ($m.versions.PSObject.Properties.Name -contains $Version) {
        $newCount = $m.versions.$Version
        $newErrors = $m.versionErrors.$Version
    }
    $observed = [math]::Round(100.0 * $newCount / [math]::Max(1, $m.requests), 1)
    $canaryErrorRate = if ($newCount -gt 0) { $newErrors / $newCount } else { 0 }
    $unattributed = $m.errors - (($m.versionErrors.PSObject.Properties | Measure-Object -Property Value -Sum).Sum)
    $globalErrorRate = $m.errorRate
    $passed = ($newCount -gt 0) -and ($canaryErrorRate -le $MaxErrorRate) -and ($globalErrorRate -le [math]::Max($MaxErrorRate, 0.05)) -and ($m.latencyMs.p95 -le $P95BudgetMs)

    $row = [pscustomobject]@{
        Peso                = "$w %"
        Observado           = "$observed %"
        Peticiones          = $m.requests
        "Resp. canary"      = $newCount
        "Errores canary"    = $newErrors
        "Error canary"      = "{0:P1}" -f $canaryErrorRate
        "Error global"      = "{0:P1}" -f $globalErrorRate
        "Sin versión"       = $unattributed
        "p95 (ms)"          = $m.latencyMs.p95
        Puerta              = if ($passed) { "OK" } else { "FALLA" }
    }
    $history += $row
    $row | Format-Table -AutoSize | Out-String | Write-Host

    if (-not $passed) {
        Step "ROLLBACK automático: la puerta de calidad falló en el paso de $w %"
        Invoke-Az containerapp ingress traffic set -g $ResourceGroup -n $App --revision-weight "$stable=100" "$candidate=0" -o none
        Invoke-Az containerapp revision deactivate -g $ResourceGroup -n $App --revision $candidate -o none
        Write-Host "Tráfico restaurado al 100 % en $stable; $candidate desactivada." -ForegroundColor Red
        $history | Format-Table -AutoSize | Out-String | Write-Host
        exit 1
    }
}

# --- 4. Promoción -------------------------------------------------------------------------
Step "4. Promoción completada: $candidate recibe el 100 %"
if (-not $KeepOldRevision) {
    Invoke-Az containerapp revision deactivate -g $ResourceGroup -n $App --revision $stable -o none
    Write-Host "Revisión anterior $stable desactivada."
} else {
    Write-Host "Revisión anterior $stable sigue activa con 0 % (rollback instantáneo disponible)."
}
$history | Format-Table -AutoSize | Out-String | Write-Host
Invoke-Az containerapp revision list -g $ResourceGroup -n $App --query "[].{revision:name, activa:properties.active, trafico:properties.trafficWeight, replicas:properties.replicas, creada:properties.createdTime}" -o table
exit 0
