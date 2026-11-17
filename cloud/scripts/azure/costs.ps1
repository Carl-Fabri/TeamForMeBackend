<#
.SYNOPSIS
  Control de costos para Azure for Students: pausar, reanudar o eliminar TeamForMe.
.EXAMPLE
  ./scripts/azure/costs.ps1 -Action Pause    # detiene AKS, desasigna VM, VMSS a 0
  ./scripts/azure/costs.ps1 -Action Resume
  ./scripts/azure/costs.ps1 -Action Delete   # borra TODO el grupo de recursos
#>
param(
    [ValidateSet("Pause", "Resume", "Delete", "Status")]
    [string]$Action = "Status",
    [string]$ResourceGroup = "rg-teamforme",
    [string]$Prefix = "teamforme"
)
$aks = "aks-$Prefix"; $vm = "vm-$Prefix"; $vmss = "vmss-$Prefix"
function Exists($type, $name) { [bool](az resource list -g $ResourceGroup --resource-type $type --name $name --query "[0].id" -o tsv 2>$null) }

switch ($Action) {
    "Pause" {
        if (Exists "Microsoft.ContainerService/managedClusters" $aks) { az aks stop -g $ResourceGroup -n $aks }
        # "deallocate" (no solo "stop") libera el hardware y deja de cobrar cómputo.
        if (Exists "Microsoft.Compute/virtualMachines" $vm) { az vm deallocate -g $ResourceGroup -n $vm }
        if (Exists "Microsoft.Compute/virtualMachineScaleSets" $vmss) { az vmss deallocate -g $ResourceGroup -n $vmss }
        # Container Apps con minReplicas 0 ya no cobran sin tráfico; las de minReplicas 1 se bajan a 0.
        foreach ($app in "ms-teams", "ms-applications", "ms-notifications", "gateway", "prometheus", "grafana") {
            az containerapp update -g $ResourceGroup -n $app --min-replicas 0 -o none 2>$null
        }
    }
    "Resume" {
        if (Exists "Microsoft.ContainerService/managedClusters" $aks) { az aks start -g $ResourceGroup -n $aks }
        if (Exists "Microsoft.Compute/virtualMachines" $vm) { az vm start -g $ResourceGroup -n $vm }
        if (Exists "Microsoft.Compute/virtualMachineScaleSets" $vmss) { az vmss start -g $ResourceGroup -n $vmss }
        foreach ($app in "ms-teams", "ms-applications", "ms-notifications", "gateway", "prometheus", "grafana") {
            az containerapp update -g $ResourceGroup -n $app --min-replicas 1 -o none 2>$null
        }
    }
    "Delete" {
        az group delete -n $ResourceGroup --yes --no-wait
        Write-Host "Eliminando $ResourceGroup en segundo plano. Key Vault queda en 'soft delete' 7 días:"
        Write-Host "  az keyvault list-deleted -o table ; az keyvault purge -n <nombre>"
    }
    "Status" {
        az resource list -g $ResourceGroup --query "[].{nombre:name, tipo:type}" -o table
        az containerapp list -g $ResourceGroup --query "[].{app:name, min:properties.template.scale.minReplicas, max:properties.template.scale.maxReplicas, estado:properties.runningStatus}" -o table
    }
}
