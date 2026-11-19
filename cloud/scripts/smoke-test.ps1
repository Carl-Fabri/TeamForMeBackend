<#
.SYNOPSIS
  Smoke tests de lanzamiento de TeamForMe (los de microservices/docs/despliegue/LANZAMIENTO.md §4).

.DESCRIPTION
  Recorre el flujo completo a través del gateway: frontend, catálogo, privacidad de equipos,
  postulación aceptada, equipo lleno, postulación rechazada con liberación de cupo,
  notificaciones, validación, bloqueo de /internal y uso de Key Vault.
  Devuelve código de salida 1 si alguna prueba falla (sirve como "gate" de Go/No-Go o en CI).

.EXAMPLE
  ./scripts/smoke-test.ps1                                   # local (puerto de .env o 8080)
  ./scripts/smoke-test.ps1 -BaseUrl https://gateway.<hash>.centralus.azurecontainerapps.io -ExpectKeyVault
#>
param(
    [string]$BaseUrl = "",
    [switch]$ExpectKeyVault,
    [int]$ResolveTimeoutSeconds = 30
)

$ErrorActionPreference = "Stop"

if (-not $BaseUrl) {
    $port = "8080"
    $envFile = Join-Path $PSScriptRoot "../.env"
    if (Test-Path $envFile) {
        $line = Get-Content $envFile | Where-Object { $_ -match '^GATEWAY_PORT=(\d+)' } | Select-Object -First 1
        if ($line) { $port = $Matches[1] }
    }
    $BaseUrl = "http://localhost:$port"
}
$BaseUrl = $BaseUrl.TrimEnd('/')
$results = New-Object System.Collections.Generic.List[object]

# Petición HTTP que no lanza excepción con códigos 4xx/5xx (compatible con PowerShell 5.1).
function Invoke-Api([string]$Method, [string]$Path, $Body = $null) {
    $params = @{ Uri = "$BaseUrl$Path"; Method = $Method; UseBasicParsing = $true; TimeoutSec = 30 }
    if ($null -ne $Body) {
        $params.Body = [System.Text.Encoding]::UTF8.GetBytes(($Body | ConvertTo-Json -Compress))
        $params.ContentType = "application/json; charset=utf-8"
    }
    # PowerShell 7 (runners de GitHub Actions) lanza HttpResponseException ante un 4xx/5xx;
    # con SkipHttpErrorCheck devuelve la respuesta igual que un 2xx.
    if ($PSVersionTable.PSVersion.Major -ge 7) { $params.SkipHttpErrorCheck = $true }
    try {
        $r = Invoke-WebRequest @params
        $code = [int]$r.StatusCode
        $content = $r.Content
        # PowerShell 7 entrega bytes cuando el Content-Type no es "texto" para él, como el
        # application/problem+json de los errores de validación de ASP.NET (prueba 09).
        if ($content -is [byte[]]) { $content = [System.Text.Encoding]::UTF8.GetString($content) }
    } catch [System.Net.WebException] {
        $resp = $_.Exception.Response
        if ($null -eq $resp) { return [pscustomobject]@{ Status = 0; Json = $null; Raw = $_.Exception.Message } }
        $code = [int]$resp.StatusCode
        $content = (New-Object System.IO.StreamReader($resp.GetResponseStream())).ReadToEnd()
    } catch {
        # Error de red (DNS, timeout, conexión rechazada) en cualquier versión.
        return [pscustomobject]@{ Status = 0; Json = $null; Raw = $_.Exception.Message }
    }
    $json = $null
    if ($content -and $content.TrimStart() -match '^[\[{]') {
        $json = $content | ConvertFrom-Json
    }
    [pscustomobject]@{ Status = $code; Json = $json; Raw = $content }
}

function Check([string]$Name, [bool]$Ok, [string]$Detail) {
    $results.Add([pscustomobject]@{ Prueba = $Name; Resultado = $(if ($Ok) { "OK" } else { "FALLA" }); Detalle = $Detail })
    $color = "Red"; if ($Ok) { $color = "Green" }
    Write-Host ("[{0}] {1} - {2}" -f $(if ($Ok) { " OK  " } else { "FALLA" }), $Name, $Detail) -ForegroundColor $color
}

function Wait-Status([string]$AppId) {
    $deadline = (Get-Date).AddSeconds($ResolveTimeoutSeconds)
    do {
        $r = Invoke-Api GET "/api/applications/$AppId"
        if ($r.Status -eq 200 -and $r.Json.status -ne "pending") { return $r.Json.status }
        Start-Sleep -Seconds 2
    } while ((Get-Date) -lt $deadline)
    return "pending"
}

Write-Host "Smoke tests contra $BaseUrl`n" -ForegroundColor Cyan
$applicant = @{ fullName = "Smoke Test"; email = "smoke@teamforme.dev"; role = "QA"; motivation = "Validación de lanzamiento" }

# 1. Frontend
$r = Invoke-Api GET "/eventos"
Check "01 Frontend" ($r.Status -eq 200 -and $r.Raw -match "<title>TeamForMe</title>") "HTTP $($r.Status)"

# 2. Catálogo de eventos
$r = Invoke-Api GET "/api/events"
# Solo cuentan objetos JSON con id: el SSR del frontend responde 200 con HTML a cualquier ruta.
$events = @($r.Json | Where-Object { $null -ne $_ -and $_.id })
Check "02 Catálogo de eventos" ($r.Status -eq 200 -and $events.Count -ge 1) "$($events.Count) eventos"

# 3. Equipos y privacidad
$r = Invoke-Api GET "/api/events/evt-hackcloud-2026/teams"
$teams = @($r.Json | Where-Object { $null -ne $_ -and $_.id })
$leaks = @($teams | Where-Object { $_.isPrivate -and @($_.members).Count -gt 0 })
Check "03 Equipos privados sin integrantes" ($r.Status -eq 200 -and $teams.Count -gt 0 -and $leaks.Count -eq 0) "$($teams.Count) equipos, $($leaks.Count) filtraciones"

$open = $teams | Where-Object { $_.filled -lt $_.capacity -and $_.id -ne "team-hard-pass" } | Select-Object -First 1
$full = $teams | Where-Object { $_.filled -ge $_.capacity } | Select-Object -First 1

# 4-5. Postulación aceptada
if ($open) {
    $r = Invoke-Api POST "/api/teams/$($open.id)/applications" $applicant
    $ok = ($r.Status -eq 201 -and $r.Json.status -eq "pending")
    Check "04 Postulación creada (pending)" $ok "HTTP $($r.Status) en $($open.id)"
    if ($ok) {
        $final = Wait-Status $r.Json.id
        Check "05 Postulación resuelta (accepted)" ($final -eq "accepted") "estado final: $final"
    }
} else {
    Check "04 Postulación creada (pending)" $false "no quedan equipos con cupo (reinicia el stack para restaurar los datos semilla)"
}

# 6. Equipo lleno
if ($full) {
    $r = Invoke-Api POST "/api/teams/$($full.id)/applications" $applicant
    Check "06 Equipo lleno rechazado" ($r.Status -eq 409 -and $r.Json.error -eq "team_full") "HTTP $($r.Status) en $($full.id)"
} else {
    Check "06 Equipo lleno rechazado" $false "no hay ningún equipo lleno para probar"
}

# 7. Postulación rechazada y cupo liberado
$before = (Invoke-Api GET "/api/teams/team-hard-pass").Json.filled
$r = Invoke-Api POST "/api/teams/team-hard-pass/applications" $applicant
if ($r.Status -eq 201) {
    $final = Wait-Status $r.Json.id
    Start-Sleep -Seconds 1
    $after = (Invoke-Api GET "/api/teams/team-hard-pass").Json.filled
    Check "07 Rechazo y cupo liberado" ($final -eq "rejected" -and $after -eq $before) "estado: $final, cupos $before -> $after"
} else {
    Check "07 Rechazo y cupo liberado" $false "HTTP $($r.Status)"
}

# 8. Notificaciones
$r = Invoke-Api GET "/api/users/u-1/notifications"
$types = @($r.Json | Where-Object { $null -ne $_ -and $_.type } | ForEach-Object { $_.type })
Check "08 Notificaciones generadas" ($r.Status -eq 200 -and ($types -contains "application_accepted") -and ($types -contains "application_rejected")) "$($types.Count) notificaciones"

# 9. Validación
$r = Invoke-Api POST "/api/teams/team-cloud-cats/applications" @{ fullName = ""; email = "no-es-email"; role = "x"; motivation = "" }
Check "09 Validación de entrada" ($r.Status -eq 400 -and $null -ne $r.Json.errors.email) "HTTP $($r.Status)"

# 10. /internal bloqueado
$r = Invoke-Api POST "/api/teams/internal/teams/team-cloud-cats/reserve"
Check "10 /internal no expuesto" ($r.Status -eq 404) "HTTP $($r.Status)"

# 11. Key Vault y salud de cada servicio
foreach ($svc in "events", "teams", "applications", "users", "notifications") {
    $r = Invoke-Api GET "/api/$svc/_info"
    $kvOk = (-not $ExpectKeyVault) -or ($r.Json.keyVault -eq $true)
    $isService = ($r.Status -eq 200 -and $r.Json.service -eq "ms-$svc")
    Check "11 Servicio ms-$svc" ($isService -and $kvOk) "HTTP $($r.Status), instancia $($r.Json.instance), keyVault=$($r.Json.keyVault)"
}

$failed = @($results | Where-Object { $_.Resultado -eq "FALLA" }).Count
Write-Host ""
if ($failed -eq 0) {
    Write-Host "GO: $($results.Count) pruebas OK" -ForegroundColor Green
    exit 0
}
Write-Host "NO-GO: $failed de $($results.Count) pruebas fallaron" -ForegroundColor Red
exit 1
