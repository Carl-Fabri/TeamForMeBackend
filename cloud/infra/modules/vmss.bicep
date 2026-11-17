// Virtual Machine Scale Set + Autoscale: escalado HORIZONTAL clásico de IaaS.
// Azure Monitor evalúa la CPU media del conjunto y añade/quita VMs idénticas.
param location string
param name string
param adminUsername string = 'azureuser'
param adminPublicKey string
param vmSize string = 'Standard_B1s'
param minInstances int = 1
param maxInstances int = 3

// Cada instancia sirve una página con su hostname (para ver el reparto entre VMs).
var cloudInit = '''
#cloud-config
packages: [nginx, stress-ng]
runcmd:
  - echo "TeamForMe VMSS instancia: $(hostname)" > /var/www/html/index.html
  - systemctl enable --now nginx
'''

resource vnet 'Microsoft.Network/virtualNetworks@2023-11-01' = {
  name: '${name}-vnet'
  location: location
  properties: {
    addressSpace: { addressPrefixes: ['10.20.0.0/16'] }
    subnets: [
      { name: 'default', properties: { addressPrefix: '10.20.1.0/24' } }
    ]
  }
}

resource vmss 'Microsoft.Compute/virtualMachineScaleSets@2024-03-01' = {
  name: name
  location: location
  sku: { name: vmSize, tier: 'Standard', capacity: minInstances }
  properties: {
    orchestrationMode: 'Uniform'
    // 'Manual': Rolling exigiría una sonda de salud o la extensión Application Health.
    upgradePolicy: { mode: 'Manual' }
    overprovision: false
    virtualMachineProfile: {
      osProfile: {
        computerNamePrefix: 'tfm'
        adminUsername: adminUsername
        customData: base64(cloudInit)
        linuxConfiguration: {
          disablePasswordAuthentication: true
          ssh: {
            publicKeys: [
              { path: '/home/${adminUsername}/.ssh/authorized_keys', keyData: adminPublicKey }
            ]
          }
        }
      }
      storageProfile: {
        imageReference: {
          publisher: 'Canonical'
          offer: 'ubuntu-24_04-lts'
          sku: 'server'
          version: 'latest'
        }
        osDisk: {
          createOption: 'FromImage'
          managedDisk: { storageAccountType: 'Standard_LRS' }
        }
      }
      networkProfile: {
        networkInterfaceConfigurations: [
          {
            name: 'nic'
            properties: {
              primary: true
              ipConfigurations: [
                { name: 'ipconfig', properties: { subnet: { id: vnet.properties.subnets[0].id } } }
              ]
            }
          }
        ]
      }
    }
  }
}

// Reglas de autoescalado (umbral + enfriamiento):
//   CPU media > 70 % durante 5 min  -> +1 VM (espera 5 min antes de volver a evaluar)
//   CPU media < 30 % durante 10 min -> -1 VM
resource autoscale 'Microsoft.Insights/autoscalesettings@2022-10-01' = {
  name: '${name}-autoscale'
  location: location
  properties: {
    enabled: true
    targetResourceUri: vmss.id
    profiles: [
      {
        name: 'cpu-based'
        capacity: {
          minimum: string(minInstances)
          maximum: string(maxInstances)
          default: string(minInstances)
        }
        rules: [
          {
            metricTrigger: {
              metricName: 'Percentage CPU'
              metricResourceUri: vmss.id
              timeGrain: 'PT1M'
              statistic: 'Average'
              timeWindow: 'PT5M'
              timeAggregation: 'Average'
              operator: 'GreaterThan'
              threshold: 70
            }
            scaleAction: { direction: 'Increase', type: 'ChangeCount', value: '1', cooldown: 'PT5M' }
          }
          {
            metricTrigger: {
              metricName: 'Percentage CPU'
              metricResourceUri: vmss.id
              timeGrain: 'PT1M'
              statistic: 'Average'
              timeWindow: 'PT10M'
              timeAggregation: 'Average'
              operator: 'LessThan'
              threshold: 30
            }
            scaleAction: { direction: 'Decrease', type: 'ChangeCount', value: '1', cooldown: 'PT5M' }
          }
        ]
      }
    ]
  }
}

output name string = vmss.name
