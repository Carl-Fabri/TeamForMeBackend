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

@description('Revisiones múltiples en ms-events (canary / blue-green). Los entornos express no lo admiten (ExpressMultiRevisionModeNotSupported): solo true en un entorno estándar.')
param multipleRevisions bool = false

var useExistingFrontend = !empty(frontendUrl)
var useExistingEnvironment = !empty(existingEnvironmentName)

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

// Tráfico entre apps: HTTPS al FQDN interno (https://<app>.internal.<dominio>).
// Los entornos "express" de Container Apps (como el del frontend que se reutiliza) no admiten
// allowInsecure, así que una llamada HTTP se redirigiría (301) a HTTPS. Con el FQDN completo el
// certificado del entorno es válido. Además el resolver de nginx no aplica dominios de búsqueda.
// Va fuera de "apps" porque defaultDomain solo se conoce en tiempo de despliegue y el arreglo
// de un loop debe poder calcularse al inicio.
var internalSuffix = 'internal.${environmentDomain}'
func internalUrl(app string, suffix string) string => 'https://${app}.${suffix}'

var gatewayEnv = [
  { name: 'EVENTS_UPSTREAM', value: internalUrl('ms-events', internalSuffix) }
  { name: 'TEAMS_UPSTREAM', value: internalUrl('ms-teams', internalSuffix) }
  { name: 'APPLICATIONS_UPSTREAM', value: internalUrl('ms-applications', internalSuffix) }
  { name: 'USERS_UPSTREAM', value: internalUrl('ms-users', internalSuffix) }
  { name: 'NOTIFICATIONS_UPSTREAM', value: internalUrl('ms-notifications', internalSuffix) }
  // Frontend existente (otro entorno, otro repositorio): se alcanza por su URL pública HTTPS.
  { name: 'FRONTEND_UPSTREAM', value: useExistingFrontend ? frontendUrl : internalUrl('frontend', internalSuffix) }
]

// Variables que dependen del dominio del entorno, por app. Se aplican en el loop en lugar de
// app.env (mismo motivo que gatewayEnv).
var domainEnv = {
  gateway: gatewayEnv
  'ms-applications': concat(dotnetEnv, [
    { name: 'Services__Teams', value: internalUrl('ms-teams', internalSuffix) }
    { name: 'Services__Notifications', value: internalUrl('ms-notifications', internalSuffix) }
  ])
  // prometheus.aca.yml usa ${INTERNAL_SUFFIX}; el entrypoint de la imagen lo sustituye al arrancar.
  prometheus: [
    { name: 'INTERNAL_SUFFIX', value: internalSuffix }
  ]
  grafana: [
    { name: 'PROMETHEUS_URL', value: internalUrl('prometheus', internalSuffix) }
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
    external: false
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
    external: false
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
    external: false
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
    external: false
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
    external: false
    cpu: '0.25'
    memory: '0.5Gi'
    min: 1
    max: 1
    rules: []
    // Se reemplaza por domainEnv en el loop (URLs con el dominio del entorno).
    env: []
    probes: dotnetProbes
    secrets: []
  }
  {
    name: 'frontend'
    image: 'teamforme/frontend'
    port: 4000
    external: false
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
    external: true
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
    external: false
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
    external: true
    cpu: '0.25'
    memory: '0.5Gi'
    min: 1
    max: 1
    rules: []
    // Se reemplaza por domainEnv en el loop.
    env: []
    probes: []
    // Valor leído de Key Vault en el despliegue (referencia de ARM, ver main.bicep). Los entornos
    // express no admiten secrets con keyVaultUrl (referencia resuelta en tiempo de ejecución), así
    // que rotar esta contraseña = actualizar el secreto en Key Vault y volver a desplegar.
    secrets: [
      { name: 'grafana-admin-password', value: grafanaAdminPassword }
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
        external: app.external
        targetPort: app.port
        transport: 'auto'
        // Sin allowInsecure: todo el tráfico, interno y externo, va por HTTPS (requisito de los
        // entornos express y mejor práctica en cualquier entorno).
        allowInsecure: false
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
          env: domainEnv[?app.name] ?? app.env
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
