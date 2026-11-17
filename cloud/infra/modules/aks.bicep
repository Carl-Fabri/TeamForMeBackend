// AKS (Kubernetes administrado) para el módulo MS.Events.
// Plano de control en tier "Free" (sin costo); solo se pagan los nodos.
param location string
param name string
param identityName string
param registryName string
@description('Tamaño de nodo. Standard_B2s (2 vCPU / 4 GiB) es el mínimo válido para un pool de sistema.')
param nodeVmSize string = 'Standard_B2s'

var acrPullRole = subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '7f951dda-4ed3-4680-a7ca-43fe172d538d')

resource aks 'Microsoft.ContainerService/managedClusters@2024-05-01' = {
  name: name
  location: location
  sku: { name: 'Base', tier: 'Free' }
  identity: { type: 'SystemAssigned' }
  properties: {
    dnsPrefix: name
    agentPoolProfiles: [
      {
        name: 'system'
        mode: 'System'
        osType: 'Linux'
        osSKU: 'AzureLinux'
        type: 'VirtualMachineScaleSets'
        vmSize: nodeVmSize
        count: 1
        // Cluster Autoscaler: añade/quita NODOS (VMs) cuando hay pods pendientes o nodos ociosos.
        enableAutoScaling: true
        minCount: 1
        maxCount: 2
      }
    ]
    autoScalerProfile: {
      'scale-down-unneeded-time': '5m'
      'scale-down-delay-after-add': '5m'
      expander: 'least-waste'
    }
    // Requisitos de Workload Identity (pods -> Entra ID -> Key Vault).
    oidcIssuerProfile: { enabled: true }
    securityProfile: { workloadIdentity: { enabled: true } }
    // Vertical Pod Autoscaler administrado (escalado vertical de pods).
    workloadAutoScalerProfile: { verticalPodAutoscaler: { enabled: true } }
    networkProfile: {
      networkPlugin: 'azure'
      networkPluginMode: 'overlay'
      loadBalancerSku: 'standard'
    }
  }
}

resource identity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' existing = {
  name: identityName
}

// Confianza federada: el ServiceAccount teamforme/ms-events puede actuar como la identidad.
resource federation 'Microsoft.ManagedIdentity/userAssignedIdentities/federatedIdentityCredentials@2023-01-31' = {
  parent: identity
  name: 'aks-ms-events'
  properties: {
    issuer: aks.properties.oidcIssuerProfile.issuerURL
    subject: 'system:serviceaccount:teamforme:ms-events'
    audiences: ['api://AzureADTokenExchange']
  }
}

resource registry 'Microsoft.ContainerRegistry/registries@2023-07-01' existing = {
  name: registryName
}

// Los nodos (kubelet) descargan imágenes de ACR.
resource kubeletPull 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(registry.id, aks.id, acrPullRole)
  scope: registry
  properties: {
    roleDefinitionId: acrPullRole
    principalId: aks.properties.identityProfile.kubeletidentity.objectId
    principalType: 'ServicePrincipal'
  }
}

output name string = aks.name
