# 2 · Autoescalado horizontal (algoritmo HPA / KEDA)

## Problema
El tráfico de TeamForMe es irregular: casi nada de madrugada y picos cuando se publica un
hackathon. Con un número fijo de réplicas, o se paga capacidad ociosa o se cae en el pico.
El autoescalado decide **cuántas réplicas** debe haber en cada momento.

## El algoritmo
Código: [`TeamForMe.Shared/Algorithms/HorizontalAutoscaler.cs`](../../src/TeamForMe.Shared/Algorithms/HorizontalAutoscaler.cs)

Es el mismo algoritmo del **Horizontal Pod Autoscaler** de Kubernetes, que KEDA aplica dentro de
Azure Container Apps:

```text
ratio    = métricaPorRéplica / objetivo
deseadas = ⌈ réplicasActuales × ratio ⌉   =   ⌈ métricaTotal / objetivo ⌉
si |ratio − 1| ≤ 0,1                → no cambiar                  (banda muerta / tolerancia)
si sube                             → máx. +4 réplicas o ×2 por evaluación (política de subida)
si baja                             → máximo de las recomendaciones de los últimos 300 s (estabilización)
final    = clamp(deseadas, mín, máx)
mín = 0                             → "scale to zero": sin tráfico no hay réplicas (ni costo)
```

```csharp
var perReplica = totalMetric / currentReplicas;
var ratio = perReplica / o.TargetPerReplica;
if (Math.Abs(ratio - 1) <= o.Tolerance) raw = currentReplicas;           // banda muerta
else raw = (int)Math.Ceiling(currentReplicas * ratio);                   // fórmula HPA

_recommendations.Enqueue((now, raw));                                    // ventana de 300 s
if (raw < currentReplicas)
    stabilized = Math.Min(currentReplicas, _recommendations.Max(r => r.Desired));

var limit = Math.Max(currentReplicas + o.ScaleUpMaxPods,                 // política de subida
                     (int)Math.Ceiling(currentReplicas * (1 + o.ScaleUpMaxPercent / 100)));
var final = Math.Clamp(stabilized, o.MinReplicas, o.MaxReplicas);
```

| Mecanismo | Para qué sirve |
|---|---|
| Fórmula `⌈total / objetivo⌉` | Proporcional: el doble de carga pide el doble de réplicas |
| Tolerancia del 10 % | Evita escalar por variaciones pequeñas (ruido) |
| Estabilización de bajada (300 s) | Un valle momentáneo no elimina réplicas que se volverán a necesitar (evita el *flapping*) |
| Política de subida | Limita el crecimiento por evaluación ante métricas anómalas |
| Mín. 0 | Elasticidad total: con cero tráfico, cero réplicas y cero vCPU cobradas |

## Configuración en Azure
[`infra/modules/containerapps.bicep`](../../../infra/modules/containerapps.bicep):
```bicep
var httpScaleRule = [
  { name: 'http-concurrency', http: { metadata: { concurrentRequests: '30' } } }
]
// ms-events
min: 0
max: 10
rules: httpScaleRule
```
- **Métrica:** peticiones HTTP concurrentes que mide el proxy Envoy de Container Apps.
- **Objetivo:** 30 por réplica. Con 150 concurrentes → ⌈150 / 30⌉ = **5 réplicas**.
- **Evaluación:** KEDA consulta cada 30 s; *cooldown* de 300 s antes de reducir.

## Simulación del algoritmo (perfil "spike")
`GET /api/lab/autoscaler?profile=spike&target=30&min=0&max=10`

| t | Carga | Réplicas antes | Deseadas (fórmula) | Réplicas después | Motivo |
|---|---|---|---|---|---|
| 0–30 s | 0 | 0 | 0 | 0 | sin tráfico (escalado a cero) |
| 60 s | 150 | 0 | 5 | **5** | activación desde cero: ⌈150/30⌉ |
| 90–210 s | 150 | 5 | 5 | 5 | ratio 1,00, dentro de la tolerancia |
| 240 s | 40 | 5 | 2 | **5** | la estabilización retiene 5 |
| 300–510 s | 10 → 0 | 5 | 1 → 0 | 5 | la estabilización retiene 5 |
| 540 s | 0 | 5 | 0 | 2 | caduca la recomendación de 5 |
| 660 s | 0 | 1 | 0 | **0** | escalado a cero |

## Prueba de carga real en Azure
```powershell
./scripts/azure/demo-algoritmos.ps1 -Only autoescalado -Concurrency 150 -DurationSeconds 240
```
1. [`tfm-load`](../../tools/TeamForMe.LoadTest/Program.cs) abre 150 conexiones concurrentes contra
   `/api/lab/work?ms=2000`. Cada petición queda abierta 2 s, como una E/S lenta.
2. Cada 15 s el script consulta `az containerapp revision list` y dibuja las réplicas activas.
3. Al terminar, mide el reparto entre las réplicas nuevas y observa la bajada (cooldown).

`/lab/work` está exento del token bucket (`.SkipTokenBucketRateLimit()`), porque la prueba de
carga supera a propósito el límite por cliente.

Resultado: [`evidencias/02-autoescalado.txt`](evidencias/02-autoescalado.txt).

## Capturas para la presentación
1. Portal → `ms-events` → **Scale** (*Application → Scale and replicas*): regla `http-concurrency`, mín. 0, máx. 10.
2. Portal → `ms-events` → **Metrics** → métrica **Replica Count**, más *Requests*, últimos 30 min: el escalón 0 → 5 → 0.
3. Portal → `ms-events` → **Revisions and replicas** → *Replicas* durante la prueba (varias en *Running*).
4. Terminal con la salida de `demo-algoritmos.ps1` (barras de réplicas en el tiempo).
