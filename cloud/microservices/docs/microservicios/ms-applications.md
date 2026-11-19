# MS.Applications — postulaciones

**Código:** `microservices/src/MS.Applications/Program.cs` · **Puerto:** 8080

## Responsabilidad
Recibir postulaciones, validarlas, reservar el cupo en MS.Teams y resolverlas de forma
**asíncrona** (`pending → accepted | rejected`, transición única y terminal).

## Endpoints
| Método | Ruta | Respuesta |
|---|---|---|
| POST | `/teams/{teamId}/applications` | 201 `ApplicationModel` · 400 validación · 404 equipo · 409 `team_full` |
| POST | `/applications` | igual, con `teamId` en el cuerpo |
| GET | `/applications/{id}` | `ApplicationModel` o 404 |

Cuerpo (`CreateApplicationInput`, idéntico al del frontend):
```json
{ "teamId": "team-cloud-cats", "fullName": "Ana Participante", "email": "ana@example.com",
  "role": "Backend", "motivation": "Quiero aprender Kubernetes" }
```
Errores de validación: `ValidationProblem` (RFC 7807) con `errors.email = ["Email inválido."]`, etc.

## Resolución asíncrona
- `ApplicationStore` guarda cada postulación con su `DueAt = ahora + ResolveDelaySeconds`.
- `ApplicationResolver` (`BackgroundService` + `PeriodicTimer` de 1 s) resuelve las vencidas.
  Regla determinista: equipos con `alwaysRejects` → `rejected`; el resto → `accepted`.
- `TryResolve` usa `ConcurrentDictionary.TryUpdate` (compare-and-swap) para que la transición
  ocurra exactamente una vez.
- Tras resolver: `POST /internal/notifications` en MS.Notifications y, si se rechazó,
  `POST /internal/teams/{id}/release` en MS.Teams para liberar el cupo.

## Resiliencia (adaptabilidad)
Los `HttpClient` tipados (`TeamsClient`, `NotificationsClient`) usan
`AddStandardResilienceHandler()`:

| Estrategia | Valor por defecto | Para qué |
|---|---|---|
| Timeout total | 30 s | No colgar peticiones |
| Reintentos | 3, backoff exponencial + jitter | Fallos transitorios (réplica reiniciando) |
| Circuit breaker | abre si ≥ 10 % de fallos en 30 s | No martillar un servicio caído |
| Timeout por intento | 10 s | — |

Los reintentos están **desactivados para POST** (`DisableForUnsafeHttpMethods`) porque reservar un
cupo no es idempotente: un reintento podría reservar dos.

## Configuración
| Variable | Por defecto | Descripción |
|---|---|---|
| `Services__Teams` | `http://ms-teams:8080` | En Container Apps: `https://ms-teams.<defaultDomain>` (URL pública: express no tiene descubrimiento interno) |
| `Services__Notifications` | `http://ms-notifications:8080` | En Container Apps: `https://ms-notifications.<defaultDomain>` |
| `Applications__ResolveDelaySeconds` | `6` | Tiempo hasta resolver |
| `Internal__ApiKey` | — | Viene de Key Vault (`Internal--ApiKey`) |

## Métricas de negocio
| Métrica | Tipo | Significado |
|---|---|---|
| `teamforme_applications_created_total{team_id}` | counter | Postulaciones creadas |
| `teamforme_applications_team_full_total{team_id}` | counter | Rechazos inmediatos por aforo |
| `teamforme_applications_resolved_total{status}` | counter | Resueltas por estado |
| `teamforme_applications_pending` | gauge | **Longitud de la cola** de trabajo |

## Escalado y evolución
Hoy: 1 réplica (estado en memoria + worker). Evolución recomendada:
1. Publicar `ApplicationCreated` en **Azure Service Bus** (cola).
2. Separar el worker en una Container App/Job propio con **regla KEDA `azure-servicebus`**:
   réplicas = mensajes en cola / 10. Escala a 0 cuando no hay postulaciones.
3. Persistir en Cosmos DB. La API queda sin estado y escala horizontalmente.
