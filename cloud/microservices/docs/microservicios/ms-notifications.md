# MS.Notifications — avisos al participante

**Código:** `microservices/src/MS.Notifications/Program.cs` · **Puerto:** 8080

## Responsabilidad
Generar y exponer las notificaciones de un usuario cuando su postulación llega a un estado final.

## Endpoints
| Método | Ruta | Respuesta |
|---|---|---|
| GET | `/users/{userId}/notifications` | `NotificationModel[]` (más reciente primero) |
| POST | `/internal/notifications` | 201 · requiere `X-Internal-Key` |

Evento interno recibido:
```json
{ "userId": "u-1", "applicationId": "app-1a2b...", "teamId": "team-cloud-cats", "status": "accepted" }
```
Notificación generada:
```json
{ "id": "ntf-...", "userId": "u-1", "type": "application_accepted",
  "message": "¡Tu postulación al equipo team-cloud-cats fue aceptada!", "createdAt": "2026-10-25T..." }
```

## Métricas
`teamforme_notifications_created_total{type}`.

## Escalado y evolución
1 réplica (estado en memoria). Evolución: suscribirse a un *topic* de Azure Service Bus
(`application-resolved`), persistir en Cosmos DB con TTL y enviar correo con
**Azure Communication Services** (credenciales en Key Vault).
