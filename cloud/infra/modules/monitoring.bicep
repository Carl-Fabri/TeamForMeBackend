// Log Analytics: almacén de logs y métricas de plataforma (Azure Monitor).
// Las consultas KQL sobre la tabla ContainerAppConsoleLogs_CL / métricas son series temporales.
param location string
param name string

resource workspace 'Microsoft.OperationalInsights/workspaces@2023-09-01' = {
  name: name
  location: location
  properties: {
    sku: { name: 'PerGB2018' }
    retentionInDays: 30
    // Tope diario de ingesta: protege el crédito de Azure for Students.
    workspaceCapping: { dailyQuotaGb: json('0.5') }
  }
}

output id string = workspace.id
output name string = workspace.name
output customerId string = workspace.properties.customerId
