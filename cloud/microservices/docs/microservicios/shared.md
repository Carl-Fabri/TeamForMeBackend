# TeamForMe.Shared — librería transversal

Ubicación: `microservices/src/TeamForMe.Shared/`. Todos los microservicios llaman a
`builder.AddCloudDefaults("<nombre>")` y `app.MapCloudDefaults()`.

## `CloudDefaults.cs`

| Funcionalidad | Detalle | Concepto cloud |
|---|---|---|
| Key Vault | `AddAzureKeyVaultIfConfigured()` si existe `KeyVault__Uri` | Gestión de secretos |
| Health checks | `/health/live` (tag `live`) y `/health/ready` | Auto-reparación (self-healing) |
| Métricas | `UseHttpMetrics()` + `MapMetrics("/metrics")` (prometheus-net) | Series temporales |
| CORS | `Cors:AllowedOrigins` (`*` por defecto) | — |
| Apagado ordenado | `HostOptions.ShutdownTimeout = 20 s` | Elasticidad: el scale-in no corta peticiones |
| `/info` | hostname de la réplica, versión, uso de Key Vault | Verificar balanceo/escalado |

## `KeyVaultConfiguration.cs`

- Proveedor `Azure.Extensions.AspNetCore.Configuration.Secrets` + `DefaultAzureCredential`.
- Cadena de credenciales: Workload Identity (AKS) → Managed Identity (Container Apps/VM, con
  `AZURE_CLIENT_ID` para la identidad asignada por el usuario) → Azure CLI (desarrollo local).
- `ReloadInterval = 5 min`: los secretos rotados se aplican sin reiniciar.
- Convención: el secreto `Internal--ApiKey` se lee como la clave de configuración `Internal:ApiKey`.
- Si el vault está configurado pero no es accesible, el servicio **falla al arrancar** (fail fast)
  y el orquestador lo reintenta: mejor que arrancar sin secretos.

## `InternalApiKey.cs`

- `app.MapInternalGroup()` crea el grupo `/internal` con un *endpoint filter* que compara la
  cabecera `X-Internal-Key` con `Internal:ApiKey` (leído en cada petición, así soporta rotación).
- `InternalApiKey.AttachInternalKey(client, config)` agrega la cabecera a los `HttpClient` tipados.

## Paquetes

| Paquete | Versión | Uso |
|---|---|---|
| Azure.Identity | 1.21.0 | Autenticación sin secretos |
| Azure.Extensions.AspNetCore.Configuration.Secrets | 1.5.2 | Key Vault como `IConfiguration` |
| prometheus-net.AspNetCore | 8.2.1 | Exportador de métricas |
| Microsoft.Extensions.Http.Resilience | 10.11.0 | Reintentos, timeout, circuit breaker |
