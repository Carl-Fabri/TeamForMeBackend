// Azure Container Registry (Basic): imágenes de los microservicios.
param location string
param name string
param pullPrincipalId string

var acrPullRole = subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '7f951dda-4ed3-4680-a7ca-43fe172d538d')

resource registry 'Microsoft.ContainerRegistry/registries@2023-07-01' = {
  name: name
  location: location
  sku: { name: 'Basic' }
  properties: {
    adminUserEnabled: false
  }
}

resource pullAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(registry.id, pullPrincipalId, acrPullRole)
  scope: registry
  properties: {
    roleDefinitionId: acrPullRole
    principalId: pullPrincipalId
    principalType: 'ServicePrincipal'
  }
}

output name string = registry.name
output loginServer string = registry.properties.loginServer
