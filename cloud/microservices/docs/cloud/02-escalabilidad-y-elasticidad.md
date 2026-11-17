# 02 · Escalabilidad y elasticidad (vertical y horizontal)

## 1. Definiciones

- **Escalabilidad:** capacidad del sistema de atender **más carga añadiendo recursos**, con un
  aumento de costo razonable. Es una propiedad del diseño y se planifica.
- **Elasticidad:** capacidad de **ajustar los recursos automáticamente y en poco tiempo** a la
  demanda, tanto hacia arriba como hacia abajo. Es una propiedad de la operación.

Un sistema puede ser escalable sin ser elástico (se añaden servidores a mano) y la elasticidad
solo funciona si el diseño es escalable.

```text
 carga ▲          ┌──┐                       ── demanda
       │      ┌───┘  └──┐                    ▓▓ capacidad elástica
       │  ┌───┘▓▓▓▓▓▓▓▓▓└──┐                 ░░ capacidad fija (sobre-aprovisionada)
       │░░░░░░░░░░░░░░░░░░░░░░░░░░
       │▓▓▓▓              ▓▓▓▓▓▓▓
       └──────────────────────────► tiempo
```

## 2. Vertical vs. horizontal

| | Escalado **vertical** (scale up/down) | Escalado **horizontal** (scale out/in) |
|---|---|---|
| Qué cambia | El **tamaño** de la instancia (vCPU, RAM) | El **número** de instancias |
| Límite | El tamaño máximo de máquina disponible | Prácticamente ilimitado |
| Interrupción | Normalmente requiere reinicio | Sin interrupción (se añaden réplicas) |
| Requisito de diseño | Ninguno | Servicio **sin estado** + balanceador |
| Tolerancia a fallos | Punto único de fallo | Alta (N réplicas) |
| Ejemplo Azure | Cambiar VM B1s → B2s; `cpu 0.25 → 0.5` en Container Apps; VPA | VMSS, HPA, reglas KEDA de Container Apps |

## 3. Implementación en TeamForMe

### 3.1 Horizontal
| Nivel | Implementación | Archivo |
|---|---|---|
| Contenedor local | `deploy.replicas: 2` y `docker compose up --scale ms-events=3` | `docker-compose.yml` |
| Pods (AKS) | **HPA** 2–10 réplicas, CPU 60 % / memoria 75 % | `k8s/ms-events/base/hpa.yaml` |
| Nodos (AKS) | **Cluster Autoscaler** 1–2 nodos, `least-waste` | `infra/modules/aks.bicep` |
| Serverless | **KEDA** HTTP: 30 peticiones concurrentes por réplica, 0–5 | `infra/modules/containerapps.bicep` |
| VMs | **VMSS** + Autoscale por CPU, 1–3 instancias | `infra/modules/vmss.bicep` |

### 3.2 Vertical
| Nivel | Implementación | Archivo |
|---|---|---|
| Pods (AKS) | **VPA** en modo `Off` (recomienda requests/limits) | `k8s/ms-events/tools/vpa.yaml` |
| Container Apps | Servicios con estado (teams, applications, notifications): se sube `cpu`/`memory` | `containerapps.bicep` |
| VM | `az vm resize --size Standard_B2s` (requiere reinicio) | guía de despliegue |
| Runtime .NET | `DOTNET_gcHeapHardLimitPercent=75 %`: el heap se adapta al límite del contenedor | `microservices/Dockerfile` |

> **No combinar** VPA en modo `Auto` con un HPA que use la misma métrica (CPU/memoria): uno
> cambiaría los requests y el otro reaccionaría a ese cambio. Por eso el VPA va en modo recomendación.

### 3.3 Qué hace posible escalar horizontalmente
1. **Sin estado** en MS.Events/MS.Users (catálogo inmutable).
2. **Balanceo health-aware**: Service de Kubernetes / Envoy solo usan réplicas *Ready*.
3. **Arranque rápido**: imagen runtime sin SDK, GC en modo workstation, `startupProbe`.
4. **Apagado ordenado**: `ShutdownTimeout 20 s` < `terminationGracePeriodSeconds 30 s`, así el
   scale-in drena las peticiones en curso.
5. **PodDisruptionBudget** (`minAvailable: 1`): siempre queda al menos una réplica.
6. **Rolling update** `maxSurge 1 / maxUnavailable 0`: despliegues sin caída.

## 4. Demostraciones

### 4.1 Local (compose)
```bash
docker compose up -d --scale ms-events=4
```
Luego se llama varias veces a `/api/events/_info`:
```bash
for i in $(seq 1 8); do curl -s localhost:8080/api/events/_info | grep -o '"instance":"[^"]*"'; done
```
Aparecen hasta 4 hostnames distintos y, en Grafana, el panel "Réplicas activas" pasa a 4.

### 4.2 AKS (HPA)
```bash
kubectl apply -f k8s/ms-events/tools/loadtest-job.yaml
```
```bash
kubectl get hpa ms-events -n teamforme --watch
```
Se observa `TARGETS 180%/60%` → `REPLICAS 2 → 4 → 8`. Al terminar la carga baja de a 1 pod por minuto.
Si los pods quedan `Pending` por falta de CPU, el Cluster Autoscaler añade el segundo nodo.

### 4.3 Container Apps (KEDA)
```bash
hey -z 2m -c 200 https://<gateway>/api/events
```
```bash
az containerapp replica list -n ms-events -g rg-teamforme -o table
```
Tras ~5 minutos sin tráfico, `ms-events` vuelve a 0 réplicas (*scale to zero*).
En el portal: *Container App → Metrics → Replica Count*.

### 4.4 VMSS
```bash
az vmss run-command invoke -g rg-teamforme -n vmss-teamforme --instance-id 0 --command-id RunShellScript --scripts "stress-ng --cpu 1 --timeout 600s &"
```
A los ~5 minutos Autoscale crea una segunda instancia: `az vmss list-instances -g rg-teamforme -n vmss-teamforme -o table`.

## 5. Límites conocidos
- Los servicios con estado en memoria no escalan horizontalmente (ver docs de cada servicio).
- Prometheus en Container Apps hace scrape cada 30 s: eso mantiene despierta una réplica de
  ms-events y ms-users. Es un *trade-off* consciente entre observabilidad y scale-to-zero.
  Para priorizar el costo, quita esos jobs de `prometheus.aca.yml`.
