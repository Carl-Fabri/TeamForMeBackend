// =====================================================================================
// TeamForMe — infraestructura en Azure (pensada para la suscripción Azure for Students).
//
// Fase 1 (deployApps=false): identidad, Key Vault, ACR, Log Analytics, entorno base.
// Fase 2 (deployApps=true):  Container Apps con las imágenes ya publicadas en ACR.
// Opcionales: deployAks (Kubernetes para MS.Events), deployVm (IaaS), deployVmss (autoscale de VMs).
// =====================================================================================
targetScope = 'resourceGroup'

@description('Región. En Azure for Students algunas regiones están bloqueadas por política.')
param location string = resourceGroup().location

@minLength(3)
@maxLength(10)
@description('Prefijo corto en minúsculas para los nombres de recursos.')
param prefix string = 'teamforme'

@description('false en la primera ejecución (aún no hay imágenes en ACR).')
param deployApps bool = false

param imageTag string = 'latest'

@description('URL pública de un frontend ya desplegado (repositorio TeamForMe). Vacío = crear la app "frontend" aquí.')
param frontendUrl string = ''

@description('Container Apps Environment existente a reutilizar (Azure for Students permite 1 por región). Vacío = crear cae-<prefix>.')
param existingEnvironmentName string = ''

@secure()
@description('Secreto compartido entre microservicios. Se guarda en Key Vault como Internal--ApiKey.')
param internalApiKey string

@secure()
param grafanaAdminPassword string

@description('objectId del usuario que despliega (az ad signed-in-user show --query id -o tsv).')
param deployerPrincipalId string = ''

param deployAks bool = false
param deployVm bool = false
param deployVmss bool = false

@description('Clave SSH pública para la VM / VMSS.')
param adminPublicKey string = ''
@description('CIDR autorizado para SSH a la VM, ej. 181.50.10.20/32.')
param allowedSshCidr string = '0.0.0.0/32'

var suffix = take(uniqueString(resourceGroup().id), 6)
// Nombre calculable al inicio del despliegue: lo necesita la referencia "existing" de abajo.
var keyVaultName = 'kv-${prefix}-${suffix}'

module monitoring 'modules/monitoring.bicep' = {
  name: 'monitoring'
  params: {
    location: location
    name: 'log-${prefix}-${suffix}'
  }
}

module identity 'modules/identity.bicep' = {
  name: 'identity'
  params: {
    location: location
    name: 'id-${prefix}'
  }
}

module keyVault 'modules/keyvault.bicep' = {
  name: 'keyvault'
  params: {
    location: location
    name: keyVaultName
    readerPrincipalId: identity.outputs.principalId
    adminPrincipalId: deployerPrincipalId
    internalApiKey: internalApiKey
    grafanaAdminPassword: grafanaAdminPassword
  }
}

module registry 'modules/registry.bicep' = {
  name: 'registry'
  params: {
    location: location
    name: 'acr${prefix}${suffix}'
    pullPrincipalId: identity.outputs.principalId
  }
}

// Referencia al vault para leer secretos en el despliegue (Key Vault reference de ARM).
resource vault 'Microsoft.KeyVault/vaults@2023-07-01' existing = {
  name: keyVaultName
}

module containerApps 'modules/containerapps.bicep' = if (deployApps) {
  name: 'containerapps'
  params: {
    location: location
    environmentName: 'cae-${prefix}'
    logAnalyticsName: monitoring.outputs.name
    identityId: identity.outputs.id
    identityClientId: identity.outputs.clientId
    registryServer: registry.outputs.loginServer
    keyVaultUri: keyVault.outputs.uri
    imageTag: imageTag
    // keyVaultUri ya hace que este módulo espere al de Key Vault: el secreto existe y está
    // actualizado cuando ARM lo lee aquí.
    grafanaAdminPassword: vault.getSecret('grafana-admin-password')
    frontendUrl: frontendUrl
    existingEnvironmentName: existingEnvironmentName
  }
}

module aks 'modules/aks.bicep' = if (deployAks) {
  name: 'aks'
  params: {
    location: location
    name: 'aks-${prefix}'
    identityName: identity.outputs.name
    registryName: registry.outputs.name
  }
}

module vm 'modules/vm.bicep' = if (deployVm) {
  name: 'vm'
  params: {
    location: location
    name: 'vm-${prefix}'
    adminPublicKey: adminPublicKey
    allowedSshCidr: allowedSshCidr
    identityId: identity.outputs.id
  }
}

module vmss 'modules/vmss.bicep' = if (deployVmss) {
  name: 'vmss'
  params: {
    location: location
    name: 'vmss-${prefix}'
    adminPublicKey: adminPublicKey
  }
}

output acrName string = registry.outputs.name
output acrLoginServer string = registry.outputs.loginServer
output keyVaultName string = keyVault.outputs.name
output keyVaultUri string = keyVault.outputs.uri
output identityClientId string = identity.outputs.clientId
output gatewayUrl string = deployApps ? containerApps!.outputs.gatewayUrl : ''
output grafanaUrl string = deployApps ? containerApps!.outputs.grafanaUrl : ''
output aksName string = deployAks ? aks!.outputs.name : ''
output vmFqdn string = deployVm ? vm!.outputs.fqdn : ''
