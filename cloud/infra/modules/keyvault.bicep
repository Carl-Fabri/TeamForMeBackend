// Azure Key Vault: almacén centralizado de secretos con autorización RBAC.
param location string
param name string
@description('principalId de la identidad administrada que leerá los secretos.')
param readerPrincipalId string
@description('objectId del usuario que despliega (para ver/rotar secretos en el portal). Opcional.')
param adminPrincipalId string = ''
@secure()
param internalApiKey string
@secure()
param grafanaAdminPassword string

var secretsUserRole = subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '4633458b-17de-408a-b874-0445c86b69e6')
var secretsOfficerRole = subscriptionResourceId('Microsoft.Authorization/roleDefinitions', 'b86a8fe4-44ce-4948-aee5-eccb2c155cd7')

resource vault 'Microsoft.KeyVault/vaults@2023-07-01' = {
  name: name
  location: location
  properties: {
    tenantId: subscription().tenantId
    sku: { family: 'A', name: 'standard' }
    enableRbacAuthorization: true
    // Permite que ARM lea secretos durante un despliegue (getSecret en main.bicep) para
    // entregarlos como secrets de Container Apps sin pasar por el pipeline.
    enabledForTemplateDeployment: true
    enableSoftDelete: true
    softDeleteRetentionInDays: 7
    publicNetworkAccess: 'Enabled'
  }
}

// Convención: "--" en el nombre del secreto = ":" en la configuración de .NET.
resource internalKey 'Microsoft.KeyVault/vaults/secrets@2023-07-01' = {
  parent: vault
  name: 'Internal--ApiKey'
  properties: { value: internalApiKey, contentType: 'text/plain' }
}

resource grafanaPassword 'Microsoft.KeyVault/vaults/secrets@2023-07-01' = {
  parent: vault
  name: 'grafana-admin-password'
  properties: { value: grafanaAdminPassword, contentType: 'text/plain' }
}

// Mínimo privilegio: la identidad de las apps solo puede LEER secretos.
resource readerAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(vault.id, readerPrincipalId, secretsUserRole)
  scope: vault
  properties: {
    roleDefinitionId: secretsUserRole
    principalId: readerPrincipalId
    principalType: 'ServicePrincipal'
  }
}

resource adminAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (!empty(adminPrincipalId)) {
  name: guid(vault.id, adminPrincipalId, secretsOfficerRole)
  scope: vault
  properties: {
    roleDefinitionId: secretsOfficerRole
    principalId: adminPrincipalId
    principalType: 'User'
  }
}

output name string = vault.name
output uri string = vault.properties.vaultUri
