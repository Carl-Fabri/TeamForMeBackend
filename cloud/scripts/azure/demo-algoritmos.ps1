<#
.SYNOPSIS
  Ejecuta las demostraciones de los algoritmos de infraestructura contra el despliegue en
  Azure y guarda la salida como evidencia en microservices/docs/algoritmos/evidencias/.

.DESCRIPTION
  balanceo     Simulación comparativa (RR, WRR, LC, P2C) + reparto REAL entre réplicas de Envoy.
  autoescalado Algoritmo HPA/KEDA simulado + prueba de carga REAL observando las réplicas.
  ratelimit    Ráfaga de peticiones contra el token bucket (HTTP 429 + Retry-After).
  resiliencia  Reintentos con backoff exponencial + circuit breaker (Abierto/Semiabierto).
  (El canary tiene su propio script: canary.ps1.)

.EXAMPLE
  ./scripts/azure/demo-algoritmos.ps1
  ./scripts/azure/demo-algoritmos.ps1 -Only autoescalado -Concurrency 200 -DurationSeconds 300
#>
param(
    [string]$ResourceGroup = "rg-teamforme",
    [ValidateSet("todo", "balanceo", "autoescalado", "ratelimit", "resiliencia")]
    [string]$Only = "todo",
    [int]$Concurrency = 150,
    [int]$DurationSeconds = 240,
    [int]$WorkMs = 2000
)

$ErrorActionPreference = "Stop"
[Console]::OutputEncoding = [Text.Encoding]::UTF8
$root = Resolve-Path (Join-Path $PSScriptRoot "../..")
$evidence = Join-Path $root "microservices/docs/algoritmos/evidencias"
New-Item -ItemType Directory -Force $evidence | Out-Null

$toolDir = Join-Path $env:TEMP "tfm-load"
$tool = Join-Path $toolDir "tfm-load.dll"
dotnet build (Join-Path $root "microservices/tools/TeamForMe.LoadTest") -c Release -o $toolDir --nologo -v q | Out-Null
if ($LASTEXITCODE -ne 0) { throw "No se pudo compilar la herramienta de carga" }

$gw = "https://" + (az containerapp show -g $ResourceGroup -n gateway --query properties.configuration.ingress.fqdn -o tsv)
if ($LASTEXITCODE -ne 0) { throw "No se encontró el gateway en $ResourceGroup" }

$script:file = $null
function Section($name, $title) {
    $script:file = Join-Path $evidence "$name.txt"
    Set-Content -Path $script:file -Value "" -Encoding utf8
    Log ("=" * 90)
    Log "$title"
    Log ("Fecha: {0:yyyy-MM-dd HH:mm:ss}  |  Gateway: $gw" -f (Get-Date))
    Log ("=" * 90)
}
function Log($text) { Write-Host $text; Add-Content -Path $script:file -Value $text -Encoding utf8 }
function Cmd($label, [scriptblock]$block) {
    Log ""
    Log "PS> $label"
    & $block 2>&1 | ForEach-Object { Log "$_" }
}
function Json($url) { (Invoke-WebRequest -UseBasicParsing -Uri $url -TimeoutSec 120).Content | ConvertFrom-Json }
function Replicas {
    $r = az containerapp revision list -g $ResourceGroup -n ms-events --query "[?properties.active].properties.replicas" -o tsv
    ($r | Measure-Object -Sum).Sum
}

# ------------------------------------------------------------------------------ Balanceo
if ($Only -in "todo", "balanceo") {
    Section "01-balanceo-de-carga" "ALGORITMO 1 · BALANCEO DE CARGA"

    Cmd "GET $gw/api/lab/load-balancing?requests=5000&rate=80" {
        $r = Json "$gw/api/lab/load-balancing?requests=5000&rate=80"
        "Escenario: capacidad total $($r.scenario.totalCapacityRps) rps, llegada $($r.scenario.arrivalRps) rps (utilización $($r.scenario.utilizationPercent) %), $($r.scenario.requests) peticiones"
        $r.results | ForEach-Object {
            $s = $_
            [pscustomobject]@{
                Algoritmo      = $s.strategy
                "Latencia prom" = "$($s.avgLatencyMs) ms"
                p95            = "$($s.p95LatencyMs) ms"
                p99            = "$($s.p99LatencyMs) ms"
                "Reparto a/b/c" = ($s.backends | ForEach-Object { "$($_.sharePercent)%" }) -join " / "
                "Cola máx c"   = $s.backends[2].maxActive
            }
        } | Format-Table -AutoSize | Out-String -Width 200
        "Mejor p95: $($r.best)"
    }

    Cmd "GET $gw/api/lab/load-balancing/sequence?weights=5,1,1 (Smooth Weighted Round Robin)" {
        $r = Json "$gw/api/lab/load-balancing/sequence?weights=5,1,1"
        "Pesos a=5 b=1 c=1 → secuencia: $($r.sequence)"
    }

    Cmd "Reparto REAL entre réplicas (Envoy, round robin) · tfm-load distribution /api/events/_info" {
        "Réplicas activas de ms-events: $(Replicas)"
        dotnet $tool distribution "$gw/api/events/_info" --count 200 --parallel 16
    }
}

# ------------------------------------------------------------------------------ Autoescalado
if ($Only -in "todo", "autoescalado") {
    Section "02-autoescalado" "ALGORITMO 2 · AUTOESCALADO HORIZONTAL (HPA / KEDA)"

    Cmd "GET $gw/api/lab/autoscaler?profile=spike (simulación del algoritmo)" {
        $r = Json "$gw/api/lab/autoscaler?profile=spike&target=30&min=0&max=10"
        "Fórmula: $($r.algorithm)"
        $r.timeline | Select-Object t, load, replicasBefore, perReplica, rawDesired, replicasAfter, reason |
            Format-Table -AutoSize | Out-String -Width 220
    }

    Cmd "Regla de escalado configurada en Azure (az containerapp show ms-events)" {
        az containerapp show -g $ResourceGroup -n ms-events --query "properties.template.scale" -o json
    }

    Log ""
    Log "PS> Prueba de carga REAL: $Concurrency conexiones concurrentes a /api/lab/work?ms=$WorkMs durante $DurationSeconds s"
    Log "    Réplicas esperadas por el algoritmo: ceil($Concurrency / 30) = $([math]::Ceiling($Concurrency / 30)) (máx 10)"
    $job = Start-Job -ScriptBlock {
        param($tool, $url, $c, $d)
        [Console]::OutputEncoding = [Text.Encoding]::UTF8
        dotnet $tool load $url --concurrency $c --duration $d
    } -ArgumentList $tool, "$gw/api/lab/work?ms=$WorkMs", $Concurrency, $DurationSeconds

    $start = Get-Date
    Log ""
    Log "  Tiempo   Réplicas activas de ms-events"
    while ($job.State -eq "Running") {
        $elapsed = [int]((Get-Date) - $start).TotalSeconds
        $n = Replicas
        Log ("  t={0,4}s  {1,2}  {2}" -f $elapsed, $n, ("█" * $n))
        Start-Sleep -Seconds 15
    }
    Receive-Job $job | ForEach-Object { Log "$_" }
    Remove-Job $job

    Cmd "Reparto entre las réplicas creadas por el autoescalado" {
        dotnet $tool distribution "$gw/api/events/_info" --count 300 --parallel 16
    }

    Log ""
    Log "  Bajada (cooldown de 300 s de KEDA antes de reducir réplicas):"
    for ($i = 0; $i -lt 8; $i++) {
        Log ("  {0:HH:mm:ss}  réplicas={1}" -f (Get-Date), (Replicas))
        Start-Sleep -Seconds 60
    }
}

# ------------------------------------------------------------------------------ Rate limit
if ($Only -in "todo", "ratelimit") {
    Section "03-rate-limiting" "ALGORITMO 4a · LIMITACIÓN DE TASA (TOKEN BUCKET)"
    Cmd "Configuración: capacidad 100 (ráfaga), relleno 50 fichas/s por cliente" { "" }
    Cmd "tfm-load burst $gw/api/users/u-1 --count 400" {
        dotnet $tool burst "$gw/api/users/u-1" --count 400
    }
    Cmd "Cabeceras de una respuesta (Invoke-WebRequest)" {
        try {
            $resp = Invoke-WebRequest -UseBasicParsing -Uri "$gw/api/users/u-1"
            "HTTP $($resp.StatusCode)  X-RateLimit-Limit=$($resp.Headers['X-RateLimit-Limit'])  X-RateLimit-Remaining=$($resp.Headers['X-RateLimit-Remaining'])"
        } catch { "HTTP $($_.Exception.Response.StatusCode.value__) (limitado)" }
    }
}

# ------------------------------------------------------------------------------ Resiliencia
if ($Only -in "todo", "resiliencia") {
    Section "04-resiliencia" "ALGORITMO 4b · RESILIENCIA: BACKOFF EXPONENCIAL + JITTER Y CIRCUIT BREAKER"
    Cmd "GET $gw/api/lab/resilience?failureRate=0.8&calls=24&pauseMs=1000" {
        $r = Json "$gw/api/lab/resilience?failureRate=0.8&calls=24&pauseMs=1000"
        "Política: $($r.policy)"
        $r.calls | Select-Object call, atSecond, outcome, networkAttempts, elapsedMs | Format-Table -AutoSize | Out-String -Width 200
    }
    Cmd "GET $gw/api/lab/resilience?failureRate=0&calls=4 (servicio recuperado → el circuito se cierra)" {
        Start-Sleep -Seconds 16
        $r = Json "$gw/api/lab/resilience?failureRate=0&calls=4"
        $r.calls | Select-Object call, outcome, networkAttempts, elapsedMs | Format-Table -AutoSize | Out-String -Width 200
    }
}

Write-Host "`nEvidencias guardadas en $evidence" -ForegroundColor Green
