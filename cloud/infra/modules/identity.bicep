// Identidad administrada asignada por el usuario: la "cuenta de servicio" de TeamForMe en Azure.
// La usan Container Apps, AKS (Workload Identity) y la VM para leer Key Vault y ACR sin secretos.
param location string
param name string

resource identity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: name
  location: location
}

output id string = identity.id
output name string = identity.name
output principalId string = identity.properties.principalId
output clientId string = identity.properties.clientId
