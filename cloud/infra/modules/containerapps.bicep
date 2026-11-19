// Azure Container Apps: orquestador serverless basado en Kubernetes + KEDA + Envoy.
// Cada microservicio es una Container App con su propia regla de escalado (elasticidad).
param location string
param environmentName string
param logAnalyticsName string
param identityId string
param identityClientId string
param registryServer string
param keyVaultUri string
param imageTag string

@secure()
@description('Contraseña de Grafana. main.bicep la lee de Key Vault en el despliegue (getSecret), no del pipeline.')
param grafanaAdminPassword string
@description('URL de un frontend ya desplegado (p. ej. https://teamforme-frontend.<dominio>). Si se indica, no se crea la app "frontend" y el gateway envía "/" a esa URL. Vacío = crear la app "frontend" en este entorno.')
param frontendUrl string = ''

@description('Nombre de un Container Apps Environment existente del grupo de recursos para reutilizarlo. Azure for Students permite 1 entorno por región. Vacío = crear environmentName.')
param existingEnvironmentName string = ''

@secure()
@description('Contraseña de Grafana. Solo se usa al reutilizar un entorno existente (ver expressCompatible).')
param grafanaAdminPassword string = ''

var useExistingFrontend = !empty(frontendUrl)
var useExistingEnvironment = !empty(existingEnvironmentName)

// Al reutilizar un entorno existente se asume que puede ser "Express" (el tipo que crea el portal
// por defecto), que no admite ingress.allowInsecure ni secretos con keyVaultUrl:
//   - las apps internas solo aceptan HTTPS y se llaman entre sí por https://<app>.internal.<dominio>;
//   - la contraseña de Grafana va como secreto de la app (mismo valor que en Key Vault).
// Ambos ajustes también son válidos en un entorno normal.
var expressCompatible = useExistingEnvironment
var internalScheme = expressCompatible ? 'https' : 'http'

resource logs 'Microsoft.OperationalInsights/workspaces@2023-09-01' existing = {
  name: logAnalyticsName
}

resource existingEnvironment 'Microsoft.App/managedEnvironments@2024-03-01' existing = if (useExistingEnvironment) {
  name: existingEnvironmentName
}

resource newEnvironment 'Microsoft.App/managedEnvironments@2024-03-01' = if (!useExistingEnvironment) {
  name: environmentName
  location: location
  properties: {
    appLogsConfiguration: {
      destination: 'log-analytics'
      logAnalyticsConfiguration: {
        customerId: logs.properties.customerId
        sharedKey: logs.listKeys().primarySharedKey
      }
    }
  }
}

var environmentId = useExistingEnvironment ? existingEnvironment.id : newEnvironment.id
var environmentDomain = useExistingEnvironment ? existingEnvironment!.properties.defaultDomain : newEnvironment!.properties.defaultDomain

// Variables comunes de los microservicios .NET: Key Vault vía SDK + identidad administrada.
var dotnetEnv = [
  { name: 'ASPNETCORE_ENVIRONMENT', value: 'Production' }
  { name: 'KeyVault__Uri', value: keyVaultUri }
  { name: 'AZURE_CLIENT_ID', value: identityClientId }
  { name: 'APP_VERSION', value: imageTag }
]

var dotnetProbes = [
  { type: 'Liveness', httpGet: { path: '/health/live', port: 8080 }, periodSeconds: 10 }
  { type: 'Readiness', httpGet: { path: '/health/ready', port: 8080 }, periodSeconds: 5 }
]

// Regla de escalado HTTP (KEDA): +1 réplica por cada 30 peticiones concurrentes.
var httpScaleRule = [
  { name: 'http-concurrency', http: { metadata: { concurrentRequests: '30' } } }
]

// Tráfico entre apps: HTTPS a la URL PÚBLICA de cada app (https://<app>.<dominio>).
// El entorno que se reutiliza (el del frontend) es "express", y express no tiene descubrimiento
// de servicios interno: las apps solo se comunican por sus URL públicas (ni http://<app> ni
// <app>.internal.<dominio>). Por eso todas las apps tienen ingreso externo y las rutas
// servicio a servicio (/internal/*) se protegen con la clave de Key Vault (X-Internal-Key).
// Va fuera de "apps" porque defaultDomain solo se conoce en tiempo de despliegue y el arreglo
// de un loop debe poder calcularse al inicio.
func appUrl(app string, domain string) string => 'https://${app}.${domain}'

var gatewayEnv = [
  { name: 'EVENTS_UPSTREAM', value: '${internalScheme}://ms-events.${internalSuffix}' }
  { name: 'TEAMS_UPSTREAM', value: '${internalScheme}://ms-teams.${internalSuffix}' }
  { name: 'APPLICATIONS_UPSTREAM', value: '${internalScheme}://ms-applications.${internalSuffix}' }
  { name: 'USERS_UPSTREAM', value: '${internalScheme}://ms-users.${internalSuffix}' }
  { name: 'NOTIFICATIONS_UPSTREAM', value: '${internalScheme}://ms-notifications.${internalSuffix}' }
  // Frontend existente (otro repositorio): se alcanza por su URL pública HTTPS.
  { name: 'FRONTEND_UPSTREAM', value: useExistingFrontend ? frontendUrl : '${internalScheme}://frontend.${internalSuffix}' }
]

// Variables que dependen del dominio del entorno (no pueden ir dentro de "allApps").
// En modo normal se conservan los nombres cortos por HTTP de siempre.
var applicationsEnv = concat(dotnetEnv, [
  { name: 'Services__Teams', value: expressCompatible ? 'https://ms-teams.${internalSuffix}' : 'http://ms-teams' }
  { name: 'Services__Notifications', value: expressCompatible ? 'https://ms-notifications.${internalSuffix}' : 'http://ms-notifications' }
])
var grafanaEnv = [
  { name: 'PROMETHEUS_URL', value: expressCompatible ? 'https://prometheus.${internalSuffix}' : 'http://prometheus' }
  { name: 'GF_SECURITY_ADMIN_PASSWORD', secretRef: 'grafana-admin-password' }
  { name: 'GF_DASHBOARDS_DEFAULT_HOME_DASHBOARD_PATH', value: '/var/lib/grafana/dashboards/teamforme-overview.json' }
]
var envOverrides = {
  gateway: gatewayEnv
  'ms-applications': applicationsEnv
  grafana: grafanaEnv
}

// Variables que dependen del dominio del entorno, por app. Se aplican en el loop en lugar de
// app.env (mismo motivo que gatewayEnv).
var domainEnv = {
  gateway: gatewayEnv
  'ms-applications': concat(dotnetEnv, [
    { name: 'Services__Teams', value: appUrl('ms-teams', environmentDomain) }
    { name: 'Services__Notifications', value: appUrl('ms-notifications', environmentDomain) }
  ])
  // prometheus.aca.yml usa ${APPS_DOMAIN}; el entrypoint de la imagen lo sustituye al arrancar.
  prometheus: [
    { name: 'APPS_DOMAIN', value: environmentDomain }
  ]
  grafana: [
    { name: 'PROMETHEUS_URL', value: appUrl('prometheus', environmentDomain) }
    { name: 'GF_SECURITY_ADMIN_PASSWORD', secretRef: 'grafana-admin-password' }
    { name: 'GF_DASHBOARDS_DEFAULT_HOME_DASHBOARD_PATH', value: '/var/lib/grafana/dashboards/teamforme-overview.json' }
  ]
}

// Catálogo de apps. minReplicas 0 = "scale to zero": sin tráfico no consume (ni cobra) CPU.
// Los servicios con estado en memoria (teams, applications, notifications) se fijan en 1 réplica.
//
// ms-events es el servicio de demostración de los algoritmos de infraestructura:
//   - revisions 'Multiple' (solo con multipleRevisions=true, en un entorno estándar): varias
//     revisiones activas a la vez con reparto de tráfico por pesos → despliegue canary /
//     blue-green (scripts/azure/canary.ps1). En el entorno express compartido va en 'Single'.
//   - max 10 réplicas con la regla KEDA HTTP (autoescalado: ⌈concurrentes / 30⌉).
//   - RateLimit__*: token bucket por cliente (ráfaga 100, 50 peticiones/s).
var multiRevisionApps = multipleRevisions ? ['ms-events'] : []

var allApps = [
  {
    name: 'ms-events'
    image: 'teamforme/ms-events'
    port: 8080
    cpu: '0.25'
    memory: '0.5Gi'
    min: 0
    max: 10
    rules: httpScaleRule
    env: concat(dotnetEnv, [
      { name: 'RateLimit__Capacity', value: '100' }
      { name: 'RateLimit__RefillPerSecond', value: '50' }
      { name: 'Lab__SelfUrl', value: 'http://localhost:8080' }
    ])
    probes: dotnetProbes
    secrets: []
  }
  {
    name: 'ms-users'
    image: 'teamforme/ms-users'
    port: 8080
    cpu: '0.25'
    memory: '0.5Gi'
    min: 0
    max: 3
    rules: httpScaleRule
    env: dotnetEnv
    probes: dotnetProbes
    secrets: []
  }
  {
    name: 'ms-teams'
    image: 'teamforme/ms-teams'
    port: 8080
    cpu: '0.25'
    memory: '0.5Gi'
    min: 1
    max: 1
    rules: []
    env: dotnetEnv
    probes: dotnetProbes
    secrets: []
  }
  {
    name: 'ms-notifications'
    image: 'teamforme/ms-notifications'
    port: 8080
    cpu: '0.25'
    memory: '0.5Gi'
    min: 1
    max: 1
    rules: []
    env: dotnetEnv
    probes: dotnetProbes
    secrets: []
  }
  {
    name: 'ms-applications'
    image: 'teamforme/ms-applications'
    port: 8080
    cpu: '0.25'
    memory: '0.5Gi'
    min: 1
    max: 1
    rules: []
    // Se define en applicationsEnv (depende del dominio del entorno).
    env: []
    probes: dotnetProbes
    secrets: []
  }
  {
    name: 'frontend'
    image: 'teamforme/frontend'
    port: 4000
    cpu: '0.5'
    memory: '1Gi'
    min: 0
    max: 3
    rules: httpScaleRule
    env: [
      { name: 'PORT', value: '4000' }
      { name: 'NG_ALLOWED_HOSTS', value: 'frontend' }
    ]
    probes: []
    secrets: []
  }
  {
    name: 'gateway'
    image: 'teamforme/gateway'
    port: 8080
    cpu: '0.25'
    memory: '0.5Gi'
    min: 1
    max: 5
    rules: httpScaleRule
    // Se reemplaza por domainEnv en el loop (depende del dominio del entorno).
    env: []
    probes: [
      { type: 'Liveness', httpGet: { path: '/health', port: 8080 }, periodSeconds: 10 }
    ]
    secrets: []
  }
  {
    name: 'prometheus'
    image: 'teamforme/prometheus'
    port: 9090
    cpu: '0.25'
    memory: '0.5Gi'
    min: 1
    max: 1
    rules: []
    // Se reemplaza por domainEnv en el loop.
    env: []
    probes: []
    secrets: []
  }
  {
    name: 'grafana'
    image: 'teamforme/grafana'
    port: 3000
    cpu: '0.25'
    memory: '0.5Gi'
    min: 1
    max: 1
    rules: []
    // Se define en grafanaEnv (depende del dominio del entorno).
    env: []
    probes: []
    // Valor leído de Key Vault en el despliegue (referencia de ARM, ver main.bicep). Los entornos
    // express no admiten secrets con keyVaultUrl (referencia resuelta en tiempo de ejecución), así
    // que rotar esta contraseña = actualizar el secreto en Key Vault y volver a desplegar.
    secrets: [
      expressCompatible
        ? { name: 'grafana-admin-password', value: grafanaAdminPassword }
        : { name: 'grafana-admin-password', keyVaultUrl: '${keyVaultUri}secrets/grafana-admin-password', identity: identityId }
    ]
  }
]

// Con un frontend existente (repositorio TeamForMe), este entorno no crea su propia app "frontend".
var apps = filter(allApps, app => !(useExistingFrontend && app.name == 'frontend'))
var appNames = map(apps, app => app.name)

resource containerApps 'Microsoft.App/containerApps@2024-03-01' = [for app in apps: {
  name: app.name
  location: location
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: { '${identityId}': {} }
  }
  properties: {
    managedEnvironmentId: environmentId
    configuration: {
      activeRevisionsMode: contains(multiRevisionApps, app.name) ? 'Multiple' : 'Single'
      ingress: {
        // Externo en todas: express solo permite llamadas entre apps por la URL pública.
        external: true
        targetPort: app.port
        transport: 'auto'
        // Tráfico interno por HTTP dentro del entorno (Envoy); el externo siempre por HTTPS.
        allowInsecure: !app.external && !expressCompatible
      }
      registries: [
        { server: registryServer, identity: identityId }
      ]
      secrets: app.secrets
    }
    template: {
      containers: [
        {
          name: app.name
          image: '${registryServer}/${app.image}:${imageTag}'
          resources: { cpu: json(app.cpu), memory: app.memory }
          env: envOverrides[?app.name] ?? app.env
          probes: app.probes
        }
      ]
      scale: {
        minReplicas: app.min
        maxReplicas: app.max
        rules: app.rules
      }
    }
  }
}]

output environmentId string = environmentId
// Por nombre y no por posición: el arreglo cambia según exista o no la app "frontend".
output gatewayUrl string = 'https://${containerApps[indexOf(appNames, 'gateway')].properties.configuration.ingress.fqdn}'
output grafanaUrl string = 'https://${containerApps[indexOf(appNames, 'grafana')].properties.configuration.ingress.fqdn}'
