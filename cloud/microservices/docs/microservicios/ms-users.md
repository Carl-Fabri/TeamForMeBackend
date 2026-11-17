# MS.Users — participantes

**Código:** `microservices/src/MS.Users/Program.cs` · **Puerto:** 8080

## Responsabilidad
Entregar el perfil del participante (nombre, email, color de avatar). En esta fase no hay
autenticación: el "usuario actual" es `u-1` o el indicado en la cabecera `X-User-Id`.

## Endpoints
| Método | Ruta | Respuesta |
|---|---|---|
| GET | `/users/me` | `UserModel` (usa `X-User-Id` si viene) |
| GET | `/users/{id}` | `UserModel` o 404 |

```json
{ "id": "u-1", "fullName": "Ana Participante", "email": "ana@example.com", "avatarColor": "#7C5CFF" }
```

## Datos
Directorio en memoria equivalente a `users.mock.ts`.

## Escalado
Sin estado, así que escala horizontalmente: Container Apps 0–3 réplicas con regla HTTP.

## Evolución
Autenticación con **Microsoft Entra External ID** (OIDC): el gateway o los servicios validarían
el JWT y el `userId` saldría del claim `sub` en lugar de `X-User-Id`.
