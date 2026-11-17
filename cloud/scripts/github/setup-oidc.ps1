<#
.SYNOPSIS
  Conecta GitHub Actions con Azure mediante OIDC (federación de identidad), sin contraseñas.

.DESCRIPTION
  Crea una identidad administrada "id-github-deployer" en el grupo de recursos y le agrega
  una credencial federada que confía en los tokens que GitHub emite para el entorno
  "production" del repositorio indicado. Se usa una identidad administrada (y no un App
  Registration) porque muchos tenants universitarios no permiten registrar aplicaciones.

  Roles asignados (solo sobre el grupo de recursos, mínimo privilegio):
    - Contributor: crear y actualizar recursos (Bicep) y hacer push a ACR.
    - Role Based Access Control Administrator: el Bicep crea asignaciones de rol
      (Key Vault Secrets User, AcrPull) para la identidad de las apps.

  Al final imprime las variables y secretos que hay que cargar en GitHub. Con
  -ConfigureGitHub los carga directamente usando la CLI "gh" (requiere `gh auth login`).

.EXAMPLE
  ./scripts/github/setup-oidc.ps1 -Repo Carl-Fabri/TeamForMeBackend -Branch master   # backend
  ./scripts/github/setup-oidc.ps1 -Repo Carl-Fabri/TeamForMe -Branch main            # frontend
  ./scripts/github/setup-oidc.ps1 -Repo Carl-Fabri/TeamForMe -Location centralus -ConfigureGitHub
#>
param(
    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[A-Za-z0-9-]+/[A-Za-z0-9._-]+$')]
    [string]$Repo,
    [string]$ResourceGroup = "rg-teamforme",
    [string]$Location = "centralus",
    [string]$IdentityName = "id-github-deployer",
    [string]$Environment = "production",
    # Rama desde la que se despliega (master en TeamForMeBackend, main en TeamForMe).
    [string]$Branch = "main",
    [switch]$ConfigureGitHub
)

$ErrorActionPreference = "Stop"
function Step($text) { Write-Host "`n==> $text" -ForegroundColor Cyan }
function Invoke-Az { az @args; if ($LASTEXITCODE -ne 0) { throw "Falló: az $args" } }

Step "Suscripción activa"
$account = az account show --query "{id:id, tenant:tenantId, name:name}" -o json | ConvertFrom-Json
if (-not $account) { throw "Ejecuta 'az login' primero." }
Write-Host "$($account.name) ($($account.id))"

# Azure for Students limita las regiones con la política "Allowed resource deployment regions".
$allowed = az policy assignment list --query "[].parameters.listOfAllowedLocations.value[]" -o tsv
if ($allowed -and ($allowed -notcontains $Location)) {
    throw "La región '$Location' no está permitida en esta suscripción. Usa -Location con una de: $($allowed -join ', ')"
}

Step "Grupo de recursos $ResourceGroup"
if ((az group exists -n $ResourceGroup) -ne "true") {
    Invoke-Az group create -n $ResourceGroup -l $Location --tags project=teamforme environment=student -o none
}
$rgId = az group show -n $ResourceGroup --query id -o tsv

Step "Identidad administrada $IdentityName"
# "list" con filtro devuelve null si no existe, sin escribir en stderr. "show" fallaría con
# ResourceNotFound y, con ErrorActionPreference=Stop, Windows PowerShell 5.1 corta el script
# aunque se redirija con 2>$null.
$identity = az identity list -g $ResourceGroup --query "[?name=='$IdentityName'] | [0]" -o json | ConvertFrom-Json
if (-not $identity) {
    # Región explícita: sin -l se usaría la del grupo de recursos, que puede no estar permitida.
    $identity = az identity create -g $ResourceGroup -n $IdentityName -l $Location -o json | ConvertFrom-Json
    if ($LASTEXITCODE -ne 0 -or -not $identity) { throw "No se pudo crear la identidad $IdentityName" }
}
Write-Host "clientId: $($identity.clientId)"

# Dos credenciales: el job "infra" usa el entorno (compuerta de aprobación) y el resto de
# jobs del workflow se autentican como la rama main.
$repoSlug = ($Repo -replace '[^A-Za-z0-9-]', '-')
$subjects = [ordered]@{
    "github-$repoSlug-$Environment" = "repo:${Repo}:environment:${Environment}"
    "github-$repoSlug-$Branch"       = "repo:${Repo}:ref:refs/heads/$Branch"
}

# GitHub puede emitir el "subject" con IDs inmutables: repo:<owner>@<ownerId>/<repo>@<repoId>:...
# (evita que alguien recree una cuenta o repo con el mismo nombre). Azure compara el texto exacto,
# así que se registran ambos formatos. Los IDs se leen de la API pública de GitHub.
try {
    $gh = Invoke-RestMethod -Uri "https://api.github.com/repos/$Repo" -Headers @{ "User-Agent" = "teamforme-setup" }
    $owner, $name = $Repo.Split('/')
    $immutable = "${owner}@$($gh.owner.id)/${name}@$($gh.id)"
    $subjects["github-$repoSlug-$Environment-ids"] = "repo:${immutable}:environment:${Environment}"
    $subjects["github-$repoSlug-$Branch-ids"]       = "repo:${immutable}:ref:refs/heads/$Branch"
} catch {
    Write-Warning "No se pudieron leer los IDs de $Repo en la API de GitHub (¿repositorio privado?). Solo se registra el formato por nombre."
}
foreach ($credName in $subjects.Keys) {
    $subject = $subjects[$credName]
    Step "Credencial federada $subject"
    $existing = az identity federated-credential list -g $ResourceGroup --identity-name $IdentityName --query "[?subject=='$subject'].name" -o tsv
    if (-not $existing) {
        Invoke-Az identity federated-credential create -g $ResourceGroup --identity-name $IdentityName `
            --name $credName --issuer "https://token.actions.githubusercontent.com" `
            --subject $subject --audiences "api://AzureADTokenExchange" -o none
    }
}

Step "Roles sobre $ResourceGroup"
foreach ($role in "Contributor", "Role Based Access Control Administrator") {
    # Filtro por principalId en vez de --assignee: no consulta Entra ID, que puede no conocer
    # todavía una identidad recién creada.
    $has = az role assignment list --scope $rgId --query "[?principalId=='$($identity.principalId)' && roleDefinitionName=='$role'].id | [0]" -o tsv
    if (-not $has) {
        # La identidad recién creada puede tardar unos segundos en propagarse en Entra ID, así que
        # se reintenta; mientras tanto los fallos de az no deben cortar el script.
        $ErrorActionPreference = "Continue"
        for ($i = 1; $i -le 6; $i++) {
            az role assignment create --assignee-object-id $identity.principalId --assignee-principal-type ServicePrincipal `
                --role $role --scope $rgId -o none 2>&1 | Out-Null
            if ($LASTEXITCODE -eq 0) { break }
            Write-Host "  esperando propagación de la identidad ($i/6)..."
            Start-Sleep -Seconds 10
        }
        $ErrorActionPreference = "Stop"
        if ($LASTEXITCODE -ne 0) { throw "No se pudo asignar el rol '$role'. ¿Tienes rol Owner en la suscripción?" }
    }
    Write-Host "  $role ✓"
}

# Secretos de la aplicación: se generan una vez; en GitHub viven como "secrets" del repositorio.
$gen = { -join ((48..57) + (65..90) + (97..122) | Get-Random -Count 32 | ForEach-Object { [char]$_ }) }
$internalKey = & $gen
$grafanaPassword = & $gen

$vars = [ordered]@{
    AZURE_CLIENT_ID       = $identity.clientId
    AZURE_TENANT_ID       = $account.tenant
    AZURE_SUBSCRIPTION_ID = $account.id
    AZURE_RESOURCE_GROUP  = $ResourceGroup
    AZURE_LOCATION        = $Location
}

if ($ConfigureGitHub) {
    Step "Cargando variables y secretos en GitHub ($Repo)"
    if (-not (Get-Command gh -ErrorAction SilentlyContinue)) { throw "No se encontró la CLI 'gh'. Instálala con: winget install GitHub.cli" }
    gh api -X PUT "repos/$Repo/environments/$Environment" --silent
    foreach ($k in $vars.Keys) { gh variable set $k --repo $Repo --body $vars[$k] }
    $has = gh secret list --repo $Repo --json name --jq ".[].name"
    if ($has -notcontains "INTERNAL_API_KEY") { gh secret set INTERNAL_API_KEY --repo $Repo --body $internalKey }
    if ($has -notcontains "GRAFANA_ADMIN_PASSWORD") { gh secret set GRAFANA_ADMIN_PASSWORD --repo $Repo --body $grafanaPassword }
    Write-Host "Listo. Revisa: https://github.com/$Repo/settings/variables/actions" -ForegroundColor Green
} else {
    Step "Configura esto en GitHub → Settings → Secrets and variables → Actions"
    Write-Host "Variables (pestaña Variables):" -ForegroundColor Yellow
    foreach ($k in $vars.Keys) { Write-Host ("  {0,-22} {1}" -f $k, $vars[$k]) }
    Write-Host "Secrets (pestaña Secrets) — valores recién generados, cópialos ahora:" -ForegroundColor Yellow
    Write-Host "  INTERNAL_API_KEY       $internalKey"
    Write-Host "  GRAFANA_ADMIN_PASSWORD $grafanaPassword"
    Write-Host "Crea también el entorno '$Environment' en Settings → Environments (opcional: revisores obligatorios)."
}
