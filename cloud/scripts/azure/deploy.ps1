<#
.SYNOPSIS
  Despliega TeamForMe en Azure (suscripción Azure for Students).

.DESCRIPTION
  1. Crea el grupo de recursos.
  2. Fase 1 de Bicep: identidad administrada, Key Vault (+ secretos), ACR, Log Analytics.
  3. Construye y publica las 9 imágenes en ACR (Docker local o ACR Tasks).
  4. Fase 2 de Bicep: entorno y Container Apps con escalado automático.
  Opcional: -WithAks (Kubernetes para MS.Events), -WithVm (IaaS), -WithVmss (autoscale de VMs).

.EXAMPLE
  ./scripts/azure/deploy.ps1 -ResourceGroup rg-teamforme -ResourceLocation centralus -UseAcrBuild
  ./scripts/azure/deploy.ps1 -WithAks
  ./scripts/azure/deploy.ps1 -WithVm -SshPublicKeyPath ~/.ssh/id_ed25519.pub -MyIp 181.50.10.20
#>
param(
    [string]$ResourceGroup = "rg-teamforme",
    # Región del grupo de recursos (solo se usa si hay que crearlo).
    [string]$Location = "centralus",
    # Región de los recursos. Azure for Students limita las regiones por política
    # (centralus, eastus, canadacentral, mexicocentral, chilecentral): eastus2 NO está permitida.
    [string]$ResourceLocation = "centralus",
    [string]$Prefix = "teamforme",
    [string]$ImageTag = (Get-Date -Format "yyyyMMddHHmm"),
    [switch]$UseAcrBuild,
    [switch]$SkipImages,
    [switch]$WithAks,
    [switch]$WithVm,
    [switch]$WithVmss,
    [string]$SshPublicKeyPath = "$HOME/.ssh/id_ed25519.pub",
    [string]$MyIp = ""
)

$ErrorActionPreference = "Stop"
$root = Resolve-Path (Join-Path $PSScriptRoot "../..")
$infra = Join-Path $root "infra"

function Step($text) { Write-Host "`n==> $text" -ForegroundColor Cyan }
function Invoke-Az { az @args; if ($LASTEXITCODE -ne 0) { throw "Falló: az $args" } }

# --- 0. Prerrequisitos ---------------------------------------------------------------
Step "Verificando sesión de Azure CLI"
$account = az account show --query "{name:name, id:id, user:user.name}" -o json | ConvertFrom-Json
if (-not $account) { throw "Ejecuta 'az login' primero." }
Write-Host "Suscripción: $($account.name) ($($account.id)) - $($account.user)"

foreach ($rp in "Microsoft.App", "Microsoft.ContainerRegistry", "Microsoft.KeyVault", "Microsoft.OperationalInsights", "Microsoft.ContainerService", "Microsoft.Insights") {
    az provider register --namespace $rp --only-show-errors | Out-Null
}

# --- 1. Secretos locales (se generan una vez y se reutilizan en cada despliegue) -----
$secretsFile = Join-Path $infra "secrets.local.json"
if (-not (Test-Path $secretsFile)) {
    Step "Generando secretos en infra/secrets.local.json (no se sube a git)"
    $gen = { -join ((48..57) + (65..90) + (97..122) | Get-Random -Count 32 | ForEach-Object { [char]$_ }) }
    @{ internalApiKey = (& $gen); grafanaAdminPassword = (& $gen) } | ConvertTo-Json | Set-Content -Encoding utf8 $secretsFile
}
$secrets = Get-Content $secretsFile -Raw | ConvertFrom-Json
$env:TFM_INTERNAL_API_KEY = $secrets.internalApiKey
$env:TFM_GRAFANA_PASSWORD = $secrets.grafanaAdminPassword

$deployer = az ad signed-in-user show --query id -o tsv 2>$null

$extra = @("prefix=$Prefix", "deployerPrincipalId=$deployer", "location=$ResourceLocation")
if ($WithAks) { $extra += "deployAks=true" }
if ($WithVm -or $WithVmss) {
    if (-not (Test-Path $SshPublicKeyPath)) { throw "No existe la clave SSH $SshPublicKeyPath (ssh-keygen -t ed25519)." }
    $extra += "adminPublicKey=$((Get-Content $SshPublicKeyPath -Raw).Trim())"
}
if ($WithVm) {
    if (-not $MyIp) { $MyIp = (Invoke-RestMethod -Uri "https://api.ipify.org") }
    $extra += @("deployVm=true", "allowedSshCidr=$MyIp/32")
}
if ($WithVmss) { $extra += "deployVmss=true" }

# --- 2. Fase 1: infraestructura base ---------------------------------------------------
if ((az group exists -n $ResourceGroup) -eq "true") {
    Step "Usando el grupo de recursos existente $ResourceGroup (recursos en $ResourceLocation)"
} else {
    Step "Creando grupo de recursos $ResourceGroup en $Location"
    Invoke-Az group create -n $ResourceGroup -l $Location --tags project=teamforme environment=student -o none
}

Step "Fase 1: identidad, Key Vault, ACR, Log Analytics"
$base = az deployment group create -g $ResourceGroup -n "teamforme-base" `
    -f (Join-Path $infra "main.bicep") -p (Join-Path $infra "main.bicepparam") `
    -p deployApps=false $extra --query properties.outputs -o json | ConvertFrom-Json
if ($LASTEXITCODE -ne 0) { throw "Falló la fase 1" }
$acr = $base.acrName.value
$acrServer = $base.acrLoginServer.value
Write-Host "ACR: $acrServer | Key Vault: $($base.keyVaultName.value)"

# --- 3. Imágenes ----------------------------------------------------------------------
$images = @(
    @{ name = "ms-events";        context = "microservices";     args = "SERVICE=MS.Events" },
    @{ name = "ms-teams";         context = "microservices";     args = "SERVICE=MS.Teams" },
    @{ name = "ms-applications";  context = "microservices";     args = "SERVICE=MS.Applications" },
    @{ name = "ms-users";         context = "microservices";     args = "SERVICE=MS.Users" },
    @{ name = "ms-notifications"; context = "microservices";     args = "SERVICE=MS.Notifications" },
    @{ name = "gateway";          context = "gateway";           args = "" },
    @{ name = "frontend";         context = "TeamForMeFrontend"; args = "" },
    @{ name = "prometheus";       context = "observability/prometheus"; args = "" },
    @{ name = "grafana";          context = "observability/grafana";    args = "" }
)

if (-not $SkipImages) {
    if ($UseAcrBuild) {
        Step "Construyendo imágenes en la nube con ACR Tasks"
    } else {
        Step "Construyendo imágenes con Docker local y publicando en ACR"
        Invoke-Az acr login -n $acr
    }
    foreach ($img in $images) {
        $tagged = "teamforme/$($img.name):$ImageTag"
        $latest = "teamforme/$($img.name):latest"
        $ctx = Join-Path $root $img.context
        $buildArgs = @("--build-arg", "APP_VERSION=$ImageTag")
        if ($img.args) { $buildArgs += @("--build-arg", $img.args) }
        Write-Host "  - $tagged"
        if ($UseAcrBuild) {
            Invoke-Az acr build -r $acr -t $tagged -t $latest @buildArgs $ctx --only-show-errors
        } else {
            docker build --platform linux/amd64 -t "$acrServer/$tagged" -t "$acrServer/$latest" @buildArgs $ctx
            if ($LASTEXITCODE -ne 0) { throw "docker build falló para $($img.name)" }
            docker push --all-tags "$acrServer/teamforme/$($img.name)"
            if ($LASTEXITCODE -ne 0) { throw "docker push falló para $($img.name)" }
        }
    }
}

# --- 4. Fase 2: Container Apps ---------------------------------------------------------
Step "Fase 2: Container Apps (tag $ImageTag)"
$out = az deployment group create -g $ResourceGroup -n "teamforme-apps" `
    -f (Join-Path $infra "main.bicep") -p (Join-Path $infra "main.bicepparam") `
    -p deployApps=true imageTag=$ImageTag $extra --query properties.outputs -o json | ConvertFrom-Json
if ($LASTEXITCODE -ne 0) { throw "Falló la fase 2" }

Step "Listo"
Write-Host "Aplicación (gateway): $($out.gatewayUrl.value)" -ForegroundColor Green
Write-Host "API de ejemplo:       $($out.gatewayUrl.value)/api/events"
Write-Host "Grafana:              $($out.grafanaUrl.value)  (usuario admin, contraseña en Key Vault: grafana-admin-password)"
if ($WithAks) { Write-Host "AKS: $($out.aksName.value) -> ejecuta ./scripts/azure/deploy-aks.ps1 -ResourceGroup $ResourceGroup" }
if ($WithVm)  { Write-Host "VM:  ssh azureuser@$($out.vmFqdn.value)" }
