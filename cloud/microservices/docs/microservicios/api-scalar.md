# Documentación de las APIs (OpenAPI + Scalar)

## Dónde verla
| Entorno | URL |
|---|---|
| **Azure** | https://gateway.greenfield-b6549157.centralus.azurecontainerapps.io/docs |
| Local (`docker compose` en `cloud/`) | http://localhost:8088/docs (o el `GATEWAY_PORT` de tu `.env`) |

La página reúne las cinco APIs en un selector (arriba a la izquierda): Eventos, Equipos,
Postulaciones, Usuarios y Notificaciones. Cada operación muestra parámetros, cuerpo, respuestas
(200, 201, 400, 404, 409) y modelos JSON, y el botón **Test Request** la ejecuta contra el gateway.

## Cómo funciona
```text
Navegador ──/docs──► gateway (nginx) ── sirve cloud/gateway/docs/index.html (Scalar standalone)
   │
   └──/api/<servicio>/openapi.json──► gateway ──► <servicio>/openapi/v1.json (generado por ASP.NET Core)
```

| Pieza | Archivo | Detalle |
|---|---|---|
| Generación OpenAPI | `src/TeamForMe.Shared/ApiDocumentation.cs` | `AddOpenApi()` + `MapOpenApi()` de .NET 10 (`Microsoft.AspNetCore.OpenApi` 10.0.15). OpenAPI 3.1. Título `TeamForMe · <servicio>` y versión = `APP_VERSION` (el tag desplegado) |
| Servidores del documento | idem | `OpenApi:ServerUrl` (por defecto `/api`, la ruta del gateway) y `/` (llamada directa al servicio) |
| Scalar por servicio | idem | `MapScalarApiReference()` (`Scalar.AspNetCore` 2.18.7) en `/scalar` de cada microservicio |
| Metadatos de cada endpoint | `src/MS.*/Program.cs` | `WithTags`, `WithSummary`, `WithDescription`, `Produces<T>`, `ProducesValidationProblem` |
| Excluido de la documentación | `InternalApiKey.cs`, `CloudDefaults.cs`, `MS.Events/InfrastructureLab.cs` | `/internal/*` (servicio a servicio), `/info`, `/lab/*` (no pasan por el gateway); salud y métricas no son endpoints de API |
| Rutas del gateway | `cloud/gateway/default.conf.template` | `= /api/<servicio>/openapi.json` → `/openapi/v1.json`; `= /docs` → página Scalar. Coincidencias exactas: tienen prioridad sobre las regex de `/api/*` |
| Página unificada | `cloud/gateway/docs/index.html` | `@scalar/api-reference` 1.76.4 desde jsDelivr, con `sources` para los cinco servicios |

## Especificaciones en crudo
| Servicio | Vía gateway | Directo al servicio |
|---|---|---|
| ms-events | `/api/events/openapi.json` | `http://ms-events:8080/openapi/v1.json` |
| ms-teams | `/api/teams/openapi.json` | `http://ms-teams:8080/openapi/v1.json` |
| ms-applications | `/api/applications/openapi.json` | `http://ms-applications:8080/openapi/v1.json` |
| ms-users | `/api/users/openapi.json` | `http://ms-users:8080/openapi/v1.json` |
| ms-notifications | `/api/notifications/openapi.json` | `http://ms-notifications:8080/openapi/v1.json` |

Sirven también para generar clientes (por ejemplo, con `openapi-generator` o NSwag).

## Agregar un endpoint nuevo a la documentación
Encadena los metadatos al mapear la ruta; el resto es automático:
```csharp
app.MapGet("/events/{id}/stats", (string id) => ...)
    .WithTags("Eventos")
    .WithSummary("Estadísticas de un evento")
    .Produces<EventStats>()
    .Produces(StatusCodes.Status404NotFound);
```
Para ocultarlo: `.ExcludeFromDescription()`.

## Verificación
Con el gateway y los servicios levantados en local:
- `/docs` y las cinco especificaciones responden 200.
- `ms-applications` documenta `POST /applications`, `POST /teams/{teamId}/applications` y
  `GET /applications/{id}` con respuestas 201/400/404/409 y los esquemas `ApplicationModel`,
  `CreateApplicationInput` y `HttpValidationProblemDetails`.
- Ninguna especificación contiene rutas `/internal`, `/lab`, `/info`, `/health` ni `/metrics`.
