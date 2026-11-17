# 3 · Despliegue progresivo: canary y blue-green con rollback automático

## Problema
Reemplazar de golpe la versión en producción (*big bang*) expone al 100 % de los usuarios a
cualquier error de la versión nueva. Un despliegue progresivo expone primero a una fracción
pequeña, **mide** y solo avanza si la versión nueva se comporta bien.

## El algoritmo
Código: [`scripts/azure/canary.ps1`](../../../scripts/azure/canary.ps1)

```text
estable  ← revisión con el 100 % del tráfico (azul)
nueva    ← crear revisión con 0 % (verde)              ← blue-green: ambas activas
para w en [10, 50, 100]:
    tráfico ← { estable: 100 − w, nueva: w }           ← Envoy reparte por pesos
    esperar a que se propague
    m ← enviar N peticiones reales por el gateway
    errorCanary ← errores(nueva) / respuestas(nueva)   ← análisis canary
    si errorCanary > 2 % o p95 > presupuesto:
        tráfico ← { estable: 100 }; desactivar nueva   ← ROLLBACK automático
        terminar con error
desactivar estable (salvo -KeepOldRevision)            ← promoción
```

### Detalle: por qué se mide el error del canary y no el global
Con el 10 % del tráfico en la versión nueva, un canary que falla en el 30 % de las peticiones
apenas sube el error **global** a ≈ 3 %, que puede confundirse con ruido. Por eso cada respuesta
trae la versión que la atendió (`/info` y también las respuestas de error), y la puerta de calidad
calcula el error **solo sobre las respuestas de la versión nueva**:

```powershell
$newCount  = $m.versions.$Version          # respuestas atendidas por la revisión nueva
$newErrors = $m.versionErrors.$Version     # cuántas de ellas fueron 5xx
$canaryErrorRate = $newErrors / $newCount
$passed = ($newCount -gt 0) -and ($canaryErrorRate -le $MaxErrorRate) -and ($m.latencyMs.p95 -le $P95BudgetMs)
```

### Operaciones de Azure que usa
| Paso | Comando |
|---|---|
| Habilitar varias revisiones activas | `az containerapp revision set-mode --mode multiple` |
| Fijar el tráfico en la estable | `az containerapp ingress traffic set --revision-weight <estable>=100` |
| Crear la revisión nueva | `az containerapp update --revision-suffix v2-… --set-env-vars APP_VERSION=v2` |
| Repartir por pesos | `az containerapp ingress traffic set --revision-weight <estable>=90 <nueva>=10` |
| Rollback | `… --revision-weight <estable>=100 <nueva>=0` + `az containerapp revision deactivate` |

En Bicep, `ms-events` se declara con `activeRevisionsMode: 'Multiple'`
([`containerapps.bicep`](../../../infra/modules/containerapps.bicep)).

## Inyección de fallos para demostrar el rollback
[`ChaosInjection.cs`](../../src/TeamForMe.Shared/ChaosInjection.cs): con
`Chaos__FailureRate=0.3`, el 30 % de las peticiones responde 500. Vale 0 por defecto, y el script
solo lo activa en la revisión nueva cuando se pasa `-SimulateFailure`. Los health checks quedan
excluidos: la idea es que el fallo lo detecte la **puerta de calidad** del canary, no la plataforma.

## Ejecución
```powershell
./scripts/azure/canary.ps1 -Version v2                       # promoción completa
./scripts/azure/canary.ps1 -Version v3 -SimulateFailure       # versión defectuosa → rollback
```
Resultados: [`evidencias/05-canary.txt`](evidencias/05-canary.txt) y
[`evidencias/06-canary-rollback.txt`](evidencias/06-canary-rollback.txt).

## Relación con los otros algoritmos
- El reparto 90/10 entre revisiones es **balanceo ponderado** (algoritmo 1) aplicado a versiones.
- Cada revisión **autoescala por separado** (algoritmo 2): la revisión canary arranca en 0
  réplicas y KEDA la activa cuando recibe su porcentaje de tráfico.

## Capturas para la presentación
1. Portal → `ms-events` → **Revisions and replicas**: dos revisiones activas con *Traffic* 90 % / 10 % (durante el paso de 10 %).
2. La misma vista tras la promoción: la nueva con 100 % y la anterior *Inactive*.
3. La misma vista tras el rollback: la estable con 100 % y la defectuosa *Inactive*.
4. Terminal con la tabla de pasos del script (Peso, Observado, Error canary, Puerta).
5. Portal → `ms-events` → **Log stream** o **Logs**: errores `chaos` solo en la revisión defectuosa.
