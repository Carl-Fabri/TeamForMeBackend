# 1 · Balanceo de carga

## Problema
Cuando el autoescalado crea varias réplicas de `ms-events`, algo tiene que decidir a cuál réplica
va cada petición. Si esa decisión es mala, una réplica se satura mientras otras están libres, y la
latencia crece aunque sobre capacidad.

## Algoritmos implementados
Código: [`TeamForMe.Shared/Algorithms/LoadBalancing.cs`](../../src/TeamForMe.Shared/Algorithms/LoadBalancing.cs)

Los cuatro heredan de `LoadBalancer`. `Select()` elige el destino y `Acquire()` además cuenta la
conexión activa hasta que se libera el `BackendLease` (lo necesita Least Connections).

| Algoritmo | Regla de decisión | Costo | Considera carga | Considera capacidad |
|---|---|---|---|---|
| **Round Robin** | `i = contador++ mod n` | O(1) | No | No |
| **Smooth Weighted RR** (nginx) | `actual[i] += peso[i]`; elegir el máximo; `actual[elegido] -= Σpesos` | O(n) | No | Sí |
| **Least Connections** (ponderado) | mínimo de `activas / peso` | O(n) | Sí | Sí |
| **Power of Two Choices** | 2 réplicas al azar y se elige la menos cargada | O(1) | Sí (muestreo) | Sí |

### Round Robin (lo que usa Envoy en Container Apps)
```csharp
public override Backend Select()
{
    var i = Interlocked.Increment(ref _next);          // contador atómico, seguro entre hilos
    return Backends[(int)(i % (uint)Backends.Count)];
}
```

### Smooth Weighted Round Robin
Con pesos `{a:5, b:1, c:1}` no envía `a a a a a b c` (ráfaga sobre `a`), sino que intercala:
```csharp
for (var i = 0; i < Backends.Count; i++)
{
    _current[i] += Backends[i].Weight;
    if (_current[i] > _current[best]) best = i;
}
_current[best] -= _totalWeight;
```
| Elección | actual antes (a,b,c) | gana | actual después |
|---|---|---|---|
| 1 | 5, 1, 1 | a | −2, 1, 1 |
| 2 | 3, 2, 2 | a | −4, 2, 2 |
| 3 | 1, 3, 3 | b | 1, −4, 3 |
| 4 | 6, −3, 4 | a | −1, −3, 4 |
| 5 | 4, −2, 5 | c | 4, −2, −2 |
| 6 | 9, −1, −1 | a | 2, −1, −1 |
| 7 | 7, 0, 0 | a | 0, 0, 0 ← vuelve al inicio |

Salida real del endpoint: `a a b a c a a a a b a c a a`.

### Least Connections y P2C
```csharp
// Least Connections: menor carga relativa; empates en orden circular
private static double Load(Backend b) => (double)b.ActiveConnections / b.Weight;

// P2C: dos índices distintos al azar y se queda con el menos cargado
var a = _random.Next(n);
var b = _random.Next(n - 1); if (b >= a) b++;
return Load(x) <= Load(y) ? x : y;
```

## Experimento: simulación de eventos discretos
Código: [`LoadBalancingSimulator.cs`](../../src/TeamForMe.Shared/Algorithms/LoadBalancingSimulator.cs) ·
Endpoint: `GET /api/lab/load-balancing?requests=5000&rate=80`

- 3 réplicas **heterogéneas**: a = 20 ms (peso 3), b = 30 ms (peso 2), c = 60 ms (peso 1).
  Capacidad total: 50 + 33,3 + 16,7 = **100 peticiones/s**.
- Llegadas de **Poisson** a 80 peticiones/s (80 % de utilización), con tiempo de servicio ±50 %.
- Los cuatro algoritmos procesan **exactamente las mismas peticiones** (semilla 42).

| Algoritmo | Latencia promedio | p95 | p99 | Reparto a / b / c | Cola máx. en c |
|---|---|---|---|---|---|
| round-robin | 6 447 ms | **32 493 ms** | 37 358 ms | 33,3 / 33,3 / 33,3 % | **642** |
| weighted | 55,6 ms | 125,2 ms | 174,1 ms | 50 / 33,3 / 16,7 % | 5 |
| least-connections | **53,9 ms** | **116,4 ms** | 156 ms | 49,6 / 33,3 / 17 % | 4 |
| p2c | 59 ms | 131 ms | 175 ms | 48,6 / 34 / 17,4 % | 4 |

**Conclusión:** Round Robin le envía a la réplica *c* 26,7 peticiones/s cuando solo puede atender
16,7. Su cola crece sin límite (642 en espera) y el p95 llega a 32 s. Los algoritmos que tienen en
cuenta la capacidad (Weighted) o la carga real (Least Connections, P2C) mantienen el p95 por debajo
de 130 ms con la misma infraestructura. Por eso Container Apps asigna a **todas las réplicas de una
revisión el mismo tamaño** (0,25 vCPU / 0,5 GiB): con réplicas homogéneas, el round robin de Envoy
es óptimo. Además, el reparto por pesos se aprovecha entre revisiones, en el canary.

## En Azure
| Capa | Algoritmo | Dónde se ve |
|---|---|---|
| Ingress de Container Apps (Envoy) → réplicas de una revisión | Round robin | `tfm-load distribution …/api/events/_info` muestra el reparto por réplica |
| Ingress → revisiones de `ms-events` | Reparto por pesos (Weighted) | Portal → ms-events → **Revisions and replicas** → columna *Traffic* |
| Gateway nginx (docker compose) | DNS round robin (re-resuelve cada 10 s) | [`gateway/default.conf.template`](../../../gateway/default.conf.template) |

Pruebas unitarias: `RoundRobin_recorre_en_orden_circular`, `WeightedRoundRobin_respeta_pesos_e_intercala`,
`LeastConnections_evita_el_backend_ocupado` y `Simulacion_round_robin_degrada_con_replicas_heterogeneas`.

## Capturas para la presentación
1. Respuesta JSON de `/api/lab/load-balancing` en el navegador (comparación de p95).
2. Salida de `tfm-load distribution` con el reparto real entre réplicas ([`evidencias/01`](evidencias/01-balanceo-de-carga.txt)).
3. Portal → `ms-events` → **Revisions and replicas** → pestaña *Replicas* con varias réplicas *Running*.
