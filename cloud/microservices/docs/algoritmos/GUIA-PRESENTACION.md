# Guía de presentación técnica · Algoritmos de infraestructura en Azure

Duración sugerida: **20 minutos** (15 de exposición y demo, 5 de preguntas).

## 1. Mensaje central
> TeamForMe se lanzó en Azure Container Apps aplicando cuatro algoritmos de infraestructura.
> Cada uno está **implementado en código** (C#), **configurado en Azure** (Bicep y az CLI) y
> **demostrado con evidencia medible** (salidas de terminal y capturas del portal).

## 2. Guion
| Min | Diapositiva / demo | Qué mostrar | Archivo |
|---|---|---|---|
| 0–2 | Contexto y arquitectura | Diagrama del README: gateway → ms-events (revisiones) → KEDA, Log Analytics | [README.md](README.md) |
| 2–3 | Infraestructura como código | `infra/main.bicep` y sus módulos; región `centralus` por la política de Azure for Students | [`containerapps.bicep`](../../../infra/modules/containerapps.bicep) |
| 3–6 | **Algoritmo 1: balanceo** | Código de Smooth WRR + tabla de la simulación (RR p95 = 32 s frente a LC = 116 ms) + reparto real entre réplicas | [01](01-balanceo-de-carga.md) |
| 6–10 | **Algoritmo 2: autoescalado** | Fórmula HPA en C# → regla KEDA en Bicep → prueba de carga en vivo → gráfica *Replica Count* | [02](02-autoescalado.md) |
| 10–13 | **Algoritmo 3: canary** | Pseudocódigo + `canary.ps1` → portal con 90/10 → promoción; luego `-SimulateFailure` → rollback | [03](03-despliegue-canary.md) |
| 13–15 | **Algoritmo 4: resiliencia** | Token bucket (ráfaga → 429) + circuit breaker (Abierto → Semiabierto) + logs en Log Analytics | [04](04-resiliencia-y-rate-limiting.md) |
| 15 | Calidad | `dotnet test` → 12 pruebas en verde | [`AlgorithmTests.cs`](../../tests/TeamForMe.Algorithms.Tests/AlgorithmTests.cs) |
| 15–20 | Preguntas | Ver §6 | |

## 3. Preparación antes de presentar (≈ 15 min antes)
```powershell
az login
```
```powershell
./scripts/azure/demo-algoritmos.ps1 -Only balanceo      # calienta ms-events (scale-from-zero)
```
- Abrir en pestañas del portal: `ms-events` → *Revisions and replicas*, *Metrics* y *Logs*.
- Tener a mano las evidencias ya generadas en `evidencias/`, por si falla la red durante la demo.
- La prueba de carga tarda unos 4 min y la bajada otros 5 min: lánzala al empezar el bloque de
  autoescalado y explica el código mientras sube.

## 4. Capturas del portal de Azure
Guárdalas en [`capturas/`](capturas/) con estos nombres:

| # | Archivo | Ruta en el portal | Qué debe verse | Algoritmo |
|---|---|---|---|---|
| 1 | `01-grupo-recursos.jpg` | Resource groups → `rg-teamforme` | Container Apps, ACR, Key Vault, Log Analytics en centralus | Infraestructura |
| 2 | `02-container-apps.jpg` | `cae-teamforme` → *Apps* | Las 9 apps del entorno | Infraestructura |
| 3 | `03-regla-escalado.jpg` | `ms-events` → *Application → Scale and replicas* | Regla `http-concurrency` 30, mín. 0, máx. 10 | 2 |
| 4 | `04-replicas-carga.jpg` | `ms-events` → *Revisions and replicas* → *Replicas* | Varias réplicas *Running* durante la carga | 1 y 2 |
| 5 | `05-metrica-replicas.jpg` | `ms-events` → *Monitoring → Metrics* → *Replica Count* (máx.) + *Requests* | Escalón 0 → N → 0 | 2 |
| 6 | `06-canary-90-10.jpg` | `ms-events` → *Revisions and replicas* | Dos revisiones activas, *Traffic* 90 % / 10 % | 3 |
| 7 | `07-canary-promovido.jpg` | ídem | La nueva al 100 %, la anterior inactiva | 3 |
| 8 | `08-canary-rollback.jpg` | ídem | La estable al 100 %, la defectuosa inactiva | 3 |
| 9 | `09-logs-resiliencia.jpg` | `ms-events` → *Monitoring → Logs*, consulta del doc 04 | Líneas `Reintento N`, `Circuit breaker ABIERTO`, `Rate limit excedido` | 4 |
| 10 | `10-lab-json.jpg` | Navegador: `https://<gateway>/api/lab/load-balancing` | JSON con `best` y los p95 | 1 |
| 11 | `11-key-vault.jpg` | `kv-teamforme-…` → *Secrets* | `Internal--ApiKey`, `grafana-admin-password` (sin mostrar valores) | Seguridad |

Consulta de *Metrics* para la captura 5 (alternativa en *Logs*):
```kusto
ContainerAppSystemLogs_CL
| where ContainerAppName_s == "ms-events"
| where Reason_s in ("AssigningReplica", "KEDAScalersStarted", "ScaledObjectCheckFailed", "ReplicaUnhealthy") or Log_s has "Scaled"
| project TimeGenerated, RevisionName_s, Reason_s, Log_s
| order by TimeGenerated desc
```

## 5. Evidencias de terminal
Las genera `demo-algoritmos.ps1` en [`evidencias/`](evidencias/):

| Archivo | Contenido |
|---|---|
| `00-pruebas-unitarias.txt` | Salida de `dotnet test` (12 pruebas) |
| `01-balanceo-de-carga.txt` | Tabla comparativa, secuencia del WRR, reparto real por réplica |
| `02-autoescalado.txt` | Línea de tiempo simulada, regla en Azure, réplicas en vivo durante la carga |
| `03-rate-limiting.txt` | Ráfaga con códigos 200 / 429 y `Retry-After` |
| `04-resiliencia.txt` | Llamadas con reintentos y estados del circuito |
| `05-canary.txt` / `06-canary-rollback.txt` | Pasos del canary y rollback automático |

## 6. Preguntas probables
| Pregunta | Respuesta corta |
|---|---|
| ¿Por qué no usar Round Robin siempre? | Es óptimo solo con réplicas iguales. Con capacidades distintas satura a la más lenta (simulación: cola de 642 y p95 de 32 s). Container Apps usa réplicas homogéneas, por eso Envoy usa RR. |
| ¿Qué diferencia hay entre su autoescalador y KEDA? | Es el mismo algoritmo (el del HPA). La clase C# lo hace explícito y testeable; en producción lo ejecuta KEDA con la regla definida en Bicep. |
| ¿Por qué 30 peticiones concurrentes? | Con 0,25 vCPU, ms-events mantiene la latencia estable hasta ~40 concurrentes; 30 deja margen (umbral de ≈ 75 %). |
| ¿Qué pasa si el canary falla al 50 %? | La puerta mide el error **solo del canary**. Supera el 2 % → rollback automático y se desactiva la revisión. Solo el 10 % del tráfico estuvo expuesto, y por segundos. |
| ¿Por qué token bucket y no ventana fija? | Permite ráfagas legítimas cortas (hasta C) y acota la tasa sostenida (r). Es O(1) por cliente y no tiene el problema de los bordes de la ventana fija. |
| ¿El límite es global? | No: es por réplica (con N réplicas ≈ N·r). Un límite global exacto requiere un almacén compartido como Redis; queda como siguiente hito. |
| ¿Por qué jitter? | Sin jitter, todas las réplicas reintentan al mismo tiempo y se produce una tormenta de reintentos. El jitter las desincroniza. |
| ¿Qué evita el circuit breaker? | Que un servicio caído acumule hilos esperando timeouts en los servicios que lo llaman (fallo en cascada). Abierto = fail fast en ~0 ms. |
| ¿Cuánto cuesta? | Scale to zero en ms-events, users y frontend. Las apps con mín. 1 consumen el grant gratuito. `scripts/azure/costs.ps1` lo apaga todo tras la presentación. |

## 7. Después de presentar
Para no consumir crédito de Azure for Students, baja a 0 réplicas las apps que tienen mínimo 1:
```powershell
./scripts/azure/costs.ps1 -Action Pause
```
Para retomar: `-Action Resume`. **Cuidado:** `-Action Delete` borra el grupo `rg-teamforme`
completo, incluidos los recursos creados a mano antes de este despliegue (`teamforme-frontend`,
`teamforme-env`, `teamforme-env-cus`, `acrteamforme93140`). Ver
[GUIA-AZURE-STUDENTS.md](../despliegue/GUIA-AZURE-STUDENTS.md).
