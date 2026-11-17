// Parámetros por defecto. Los secretos NO se escriben aquí: el script deploy.ps1 los
// lee de infra/secrets.local.json (ignorado por git) y los pasa en la línea de comandos.
using 'main.bicep'

param prefix = 'teamforme'
param imageTag = 'latest'
param internalApiKey = readEnvironmentVariable('TFM_INTERNAL_API_KEY', '')
param grafanaAdminPassword = readEnvironmentVariable('TFM_GRAFANA_PASSWORD', '')
// URL del frontend desplegado desde el repositorio TeamForMe (vacío = crear la app "frontend").
param frontendUrl = readEnvironmentVariable('TFM_FRONTEND_URL', '')
// Entorno de Container Apps existente a reutilizar (vacío = crear uno nuevo).
param existingEnvironmentName = readEnvironmentVariable('TFM_EXISTING_ENVIRONMENT', '')
