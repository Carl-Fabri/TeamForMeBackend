# Guía de levantamiento de TeamForMe con Azure for Students

Esta guía lleva el sistema desde cero hasta producción en Azure usando la suscripción
**Azure for Students** (100 USD de crédito por 12 meses, sin tarjeta de crédito).

| Ruta | Qué levanta | Costo aproximado | Tiempo |
|---|---|---|---|
| **A. Local** | Todo con Docker Compose | 0 | 10 min |
| **B. Azure Container Apps** (recomendada) | Sistema completo serverless + Key Vault + métricas | ~5–8 USD/mes (ACR Basic + lo que exceda el grant gratuito) | 25 min |
| **C. AKS** (opcional) | Módulo MS.Events en Kubernetes | ~1 USD/día con el nodo encendido | +15 min |
| **D. VM / VMSS** (opcional) | Sistema en IaaS / autoscale de VMs | 0 con B1s free tier (VMSS: ~0,4 USD/día por instancia extra) | +15 min |

> Los costos son estimaciones de referencia; revisa siempre la calculadora de precios y Cost
> Management. **Elimina o pausa los recursos cuando termines la demo** (paso 9).

---

## 0. Requisitos

| Herramienta | Versión | Instalación (Windows) |
|---|---|---|
| Cuenta Azure for Students | — | https://azure.microsoft.com/free/students (verificación con correo institucional) |
| Azure CLI | ≥ 2.60 | `winget install Microsoft.AzureCLI` |
| Bicep | se instala con la CLI | `az bicep install` |
| Docker Desktop | ≥ 4.30 | `winget install Docker.DockerDesktop` |
| kubectl | ≥ 1.29 (solo ruta C) | `az aks install-cli` |
| Git / PowerShell | PowerShell 5.1+ o 7 | incluidos en Windows |

```powershell
az version
```
```powershell
docker version
```

## A. Levantamiento local (Docker Compose)

1. Desde la raíz `TeamForMe/`, copia el archivo de variables:
   ```powershell
   Copy-Item .env.example .env
   ```
   Si los puertos 8080, 9090 o 3000 ya están ocupados en tu equipo (por ejemplo, por otro
   proyecto en Docker), cámbialos en `.env` con `GATEWAY_PORT`, `PROMETHEUS_PORT` y
   `GRAFANA_PORT`. Las URLs de abajo asumen los valores por defecto.
2. Construye y levanta todo:
   ```powershell
   docker compose up -d --build
   ```
3. Verifica:

   | URL | Esperado |
   |---|---|
   | http://localhost:8080 | Frontend TeamForMe |
   | http://localhost:8080/api/events | JSON con 3 eventos |
   | http://localhost:8080/api/events/evt-hackcloud-2026/teams | 4 equipos (el privado sin `members`) |
   | http://localhost:8080/api/events/_info | `instance` cambia entre las 2 réplicas |
   | http://localhost:9090/targets | Targets `UP` |
   | http://localhost:3000 | Grafana (admin/admin) con el dashboard *TeamForMe · Microservicios* |

4. Prueba el flujo de postulación:
   ```powershell
   $body = @{ fullName="Ana"; email="ana@example.com"; role="Backend"; motivation="Aprender cloud" } | ConvertTo-Json
   $app = Invoke-RestMethod -Method Post -Uri http://localhost:8080/api/teams/team-cloud-cats/applications -Body $body -ContentType "application/json"
   $app.status                                                          # pending
   Start-Sleep 8; (Invoke-RestMethod http://localhost:8080/api/applications/$($app.id)).status   # accepted
   Invoke-RestMethod http://localhost:8080/api/users/u-1/notifications
   ```
   Si se postula a `team-pixel-forge` (lleno) devuelve **409**, y `team-hard-pass` termina en `rejected`.
5. Escalado horizontal:
   ```powershell
   docker compose up -d --scale ms-events=4
   ```

## B. Despliegue en Azure Container Apps (ruta recomendada)

### Paso 1 · Iniciar sesión y elegir la suscripción
```powershell
az login
```
```powershell
az account list -o table
```
```powershell
az account set --subscription "Azure for Students"
```

### Paso 2 · Elegir una región permitida
Las suscripciones de estudiante tienen una política que limita las regiones. Consulta cuáles permite la tuya:
```powershell
az policy assignment list --query "[?contains(displayName,'region') || contains(displayName,'location')].parameters" -o json
```
En la suscripción del proyecto la política permite **centralus, eastus, canadacentral, mexicocentral y chilecentral** (`eastus2` NO). El grupo de recursos puede estar en otra región: lo que cuenta es `-ResourceLocation`. El error
`RequestDisallowedByAzure` indica una región no permitida.

### Paso 3 · Registrar los proveedores de recursos (una sola vez)
```powershell
"Microsoft.App","Microsoft.ContainerRegistry","Microsoft.KeyVault","Microsoft.OperationalInsights","Microsoft.ContainerService","Microsoft.Insights" | ForEach-Object { az provider register --namespace $_ }
```
El script del paso 4 también lo hace, pero el registro puede tardar unos minutos.

### Paso 4 · Ejecutar el despliegue
Desde la raíz `TeamForMe/` (con Docker Desktop encendido, o con `-UseAcrBuild` para construir en ACR Tasks sin Docker):
```powershell
./scripts/azure/deploy.ps1 -ResourceGroup rg-teamforme -ResourceLocation centralus -UseAcrBuild
```
Si PowerShell bloquea el script: `Set-ExecutionPolicy -Scope Process Bypass`.

El script hace lo siguiente:

| Fase | Acción | Recursos |
|---|---|---|
| 0 | Genera `infra/secrets.local.json` (clave interna y contraseña de Grafana; **no se sube a git**) | — |
| 1 | `az deployment group create` con `deployApps=false` | Identidad administrada, Key Vault + 2 secretos + RBAC, ACR, Log Analytics |
| 2 | `docker build` + `docker push` de 9 imágenes a ACR | ms-events, ms-teams, ms-applications, ms-users, ms-notifications, gateway, frontend, prometheus, grafana |
| 3 | `az deployment group create` con `deployApps=true` | Entorno de Container Apps + 9 apps con escalado |

> **ACR Tasks:** con `-UseAcrBuild` las imágenes se construyen en la nube en lugar de con Docker
> local. Algunas suscripciones gratuitas/de estudiante tienen ACR Tasks deshabilitado
> (`TasksOperationsNotAllowed`); en ese caso usa el modo por defecto (Docker local).

### Paso 5 · Verificar
Al final el script imprime algo como:
```text
Aplicación (gateway): https://gateway.<hash>.centralus.azurecontainerapps.io
Grafana:              https://grafana.<hash>.centralus.azurecontainerapps.io
```

| Verificación | Comando / URL |
|---|---|
| Frontend | `<gateway>/` |
| API | `<gateway>/api/events` |
| Key Vault en uso | `<gateway>/api/events/_info` → `"keyVault": true` |
| `/internal` bloqueado | `<gateway>/api/teams/internal/x` → 404 |
| Réplicas | `az containerapp replica list -n ms-events -g rg-teamforme -o table` |
| Logs | `az containerapp logs show -n ms-applications -g rg-teamforme --follow` |
| Contraseña de Grafana | `az keyvault secret show --vault-name <kv> -n grafana-admin-password --query value -o tsv` |

La primera petición a `ms-events`, `ms-users` o `frontend` puede tardar unos segundos (arranque desde 0 réplicas).

Verificación automática de todo el flujo (debe terminar en **GO**):
```powershell
./scripts/smoke-test.ps1 -BaseUrl <gateway> -ExpectKeyVault
```
En local basta con `./scripts/smoke-test.ps1`: toma el puerto de `GATEWAY_PORT` en `.env`.

### Paso 6 · Presupuesto y alertas de costo (muy recomendado)
Portal → **Cost Management + Billing → Budgets → + Add**:
- Ámbito: la suscripción Azure for Students. Monto: 20 USD/mes.
- Alertas al 50 %, 80 % y 100 % a tu correo.

El saldo restante del crédito se consulta en https://www.microsoftazuresponsorships.com/balance.

### Paso 7 · Actualizar la aplicación (nuevo despliegue)
```powershell
./scripts/azure/deploy.ps1
```
Cada ejecución usa un tag nuevo (`yyyyMMddHHmm`) y Container Apps crea una **nueva revisión**
sin caída. Para volver atrás, se consulta el tag anterior con
`az acr repository show-tags -n <acr> --repository teamforme/ms-events -o table` y se vuelve a
desplegar ese tag sin reconstruir imágenes:
```powershell
./scripts/azure/deploy.ps1 -SkipImages -ImageTag 202610251530
```

### Paso 8 · Rotar un secreto
```powershell
az keyvault secret set --vault-name <kv> -n Internal--ApiKey --value (New-Guid).Guid
```
Los microservicios recargan el valor en ≤ 5 minutos. Actualiza también `infra/secrets.local.json`
para que el próximo despliegue no vuelva a escribir el valor anterior.

## C. Módulo MS.Events en AKS (opcional)

> Revisa la cuota de vCPU: `az vm list-usage -l centralus -o table` (familia *Standard BS* y
> *Total Regional vCPUs*). El clúster usa 1 nodo B2s (2 vCPU) y puede crecer a 2.

```powershell
./scripts/azure/deploy.ps1 -WithAks -SkipImages
```
```powershell
./scripts/azure/deploy-aks.ps1 -ResourceGroup rg-teamforme
```
```powershell
kubectl get pods,svc,hpa -n teamforme
```
Demostración del HPA:
```powershell
kubectl apply -f k8s/ms-events/tools/loadtest-job.yaml
```
```powershell
kubectl get hpa ms-events -n teamforme --watch
```
Recomendación del VPA: `kubectl describe vpa ms-events -n teamforme`.

**Apagar el clúster cuando no se use:** `az aks stop -g rg-teamforme -n aks-teamforme`.

## D. VM y VMSS (opcional)

```powershell
ssh-keygen -t ed25519
```
```powershell
./scripts/azure/deploy.ps1 -WithVm -SkipImages
```
Luego sigue [07-maquinas-virtuales.md](../cloud/07-maquinas-virtuales.md#21-vm-única-lift--shift-del-sistema-completo-iaas)
para copiar el proyecto y ejecutar `docker compose` en la VM.

VMSS con autoescalado: `./scripts/azure/deploy.ps1 -WithVmss -SkipImages`.

## 9. Pausar o eliminar (control del crédito)

| Acción | Comando |
|---|---|
| Ver estado | `./scripts/azure/costs.ps1 -Action Status` |
| Pausar (AKS stop, VM deallocate, apps a 0) | `./scripts/azure/costs.ps1 -Action Pause` |
| Reanudar | `./scripts/azure/costs.ps1 -Action Resume` |
| **Eliminar todo** | `./scripts/azure/costs.ps1 -Action Delete` |

Pausar reinicia el estado en memoria de MS.Teams, MS.Applications y MS.Notifications (vuelven a
los datos semilla). Tras eliminar, Key Vault queda 7 días en *soft delete*; para reutilizar el
mismo nombre, púrgalo con `az keyvault purge -n <kv>`.

## 10. Solución de problemas

| Síntoma | Causa probable | Solución |
|---|---|---|
| `RequestDisallowedByAzure` / `RequestDisallowedByPolicy` | Región no permitida por la política de estudiante | Usar otra región (paso 2) |
| `MissingSubscriptionRegistration` | Proveedor no registrado | Paso 3 y esperar a `Registered` |
| `QuotaExceeded` al crear AKS/VM | Cuota de vCPU agotada | Desplegar AKS y VMSS por separado o borrar VMs |
| App en `Activating` o reiniciándose | Key Vault aún sin permisos (el RBAC tarda en propagarse ~1–5 min) | Esperar; `az containerapp revision restart` |
| `ImagePullBackOff` / `unauthorized` en ACR | Falta AcrPull o la imagen no existe | `az acr repository list -n <acr>`; repetir la fase de imágenes |
| 502 en el gateway | Un upstream escalado a 0 tardó en arrancar | Reintentar; subir `minReplicas` a 1 en ese servicio |
| Frontend responde pero sin SSR | Host no permitido por Angular SSR | Ajustar `NG_ALLOWED_HOSTS` en `containerapps.bicep` |
| `TasksOperationsNotAllowed` | ACR Tasks deshabilitado en la suscripción | No usar `-UseAcrBuild` |
| `docker push` muy lento | Imágenes grandes y conexión lenta | Construir solo lo cambiado (`-SkipImages` + push manual) |
