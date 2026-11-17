# MS.Teams — equipos y aforo

**Código:** `microservices/src/MS.Teams/Program.cs` · **Puerto:** 8080

## Responsabilidad
Administrar los equipos de cada evento y **garantizar el aforo**: `filled` nunca supera
`capacity` (FR-014 / SC-009). Aplica la regla de privacidad: un equipo privado nunca expone a
sus integrantes (FR-009).

## Endpoints públicos
| Método | Ruta | Respuesta |
|---|---|---|
| GET | `/events/{eventId}/teams` | `TeamModel[]` (privados con `members: []`) |
| GET | `/teams/{teamId}` | `TeamModel` o 404 |

## Endpoints internos (requieren `X-Internal-Key`)
| Método | Ruta | Respuesta | Lo usa |
|---|---|---|---|
| POST | `/internal/teams/{id}/reserve` | 200 `{teamId, filled, capacity, alwaysRejects}` · 409 `team_full` · 404 | MS.Applications al crear una postulación |
| POST | `/internal/teams/{id}/release` | 204 · 404 | MS.Applications cuando una postulación se rechaza |

## Concurrencia
`TeamStore.Reserve` comprueba y aumenta el contador dentro de un `lock` (`System.Threading.Lock`):
la operación *check-then-act* es atómica, de modo que dos postulaciones simultáneas al último
cupo no pueden pasar las dos.

## Datos semilla
Equivalentes a `teams.mock.ts`: un equipo con cupo, uno lleno (`team-pixel-forge`), uno privado
(`team-stealth`) y uno que siempre rechaza (`team-hard-pass`, solo para demo).

## Métricas de negocio
| Métrica | Tipo | Etiquetas |
|---|---|---|
| `teamforme_team_seats_filled` | gauge | `team_id`, `event_id` |
| `teamforme_team_seats_capacity` | gauge | `team_id`, `event_id` |

El dashboard de Grafana calcula la ocupación con `filled / capacity` (verde < 80 %, naranja, rojo = lleno).

## Escalado
**Vertical** (1 réplica): el estado vive en memoria. Para subir capacidad se aumenta CPU/RAM de la
réplica (`cpu: 0.25 → 0.5`, `memory: 0.5Gi → 1Gi` en Container Apps).

### Cómo hacerlo horizontal
1. Persistir equipos en **Azure Database for PostgreSQL Flexible Server** (o Cosmos DB).
2. Reemplazar el `lock` por una actualización condicional atómica en la base de datos:
   ```sql
   UPDATE teams SET filled = filled + 1
   WHERE id = @id AND filled < capacity
   RETURNING filled, capacity;
   ```
   (en Cosmos DB: *optimistic concurrency* con `ETag`).
3. Quitar `max: 1` en `infra/modules/containerapps.bicep` y añadir una regla HTTP.
