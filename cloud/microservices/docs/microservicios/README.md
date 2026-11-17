# Microservicios de TeamForMe

| Servicio | Responsabilidad | Estado | Escalado | Doc |
|---|---|---|---|---|
| **MS.Events** | Catálogo de eventos e ideas en búsqueda de grupo | Sin estado (solo lectura) | Horizontal automático (0–5 en ACA, 2–10 en AKS) | [ms-events.md](ms-events.md) |
| **MS.Teams** | Equipos y control de aforo | Con estado (cupos) | Vertical (1 réplica) | [ms-teams.md](ms-teams.md) |
| **MS.Applications** | Postulaciones y resolución asíncrona | Con estado + worker | Vertical (1 réplica) | [ms-applications.md](ms-applications.md) |
| **MS.Users** | Perfiles de participantes | Sin estado (solo lectura) | Horizontal automático (0–3) | [ms-users.md](ms-users.md) |
| **MS.Notifications** | Avisos al participante | Con estado | Vertical (1 réplica) | [ms-notifications.md](ms-notifications.md) |
| Gateway | Enrutamiento `/api/*` y frontend | Sin estado | Horizontal (1–5) | [gateway.md](gateway.md) |
| TeamForMe.Shared | Librería transversal (Key Vault, métricas, health) | — | — | [shared.md](shared.md) |

## Estructura del código

```text
microservices/
├── Directory.Build.props        # net10.0, nullable, GC ajustado para contenedores
├── Dockerfile                   # multi-stage único: --build-arg SERVICE=MS.Xxx
├── TeamForMe.Microservices.slnx
└── src/
    ├── TeamForMe.Shared/        # CloudDefaults, KeyVaultConfiguration, InternalApiKey
    ├── MS.Events/Program.cs
    ├── MS.Teams/Program.cs
    ├── MS.Applications/Program.cs
    ├── MS.Users/Program.cs
    └── MS.Notifications/Program.cs
```

## Endpoints comunes (todos los servicios)

| Ruta | Uso |
|---|---|
| `GET /health/live` | Liveness: ¿el proceso responde? Si falla, el orquestador **reinicia** el contenedor. |
| `GET /health/ready` | Readiness: ¿puede recibir tráfico? Si falla, se **saca del balanceo**. |
| `GET /metrics` | Métricas Prometheus (HTTP, proceso .NET, negocio). |
| `GET /info` | Servicio, **instancia** (hostname), versión, si usa Key Vault. Útil para ver el balanceo entre réplicas. |

## Ejecutar un servicio de forma aislada

```bash
docker build --build-arg SERVICE=MS.Events -t teamforme/ms-events:local microservices
```

```bash
docker run --rm -p 5001:8080 teamforme/ms-events:local
```

Luego `curl http://localhost:5001/events`. Con el SDK .NET 10 instalado también sirve
`dotnet run --project microservices/src/MS.Events`.

## ¿Por qué unos servicios escalan horizontalmente y otros no?

Escalar horizontalmente exige que **cualquier réplica pueda atender cualquier petición**. MS.Events
y MS.Users solo leen datos inmutables, así que N copias son equivalentes. MS.Teams,
MS.Applications y MS.Notifications guardan estado en memoria: con 2 réplicas cada una tendría
su propio contador de cupos y se podría sobrevender un equipo. Por eso se fijan en 1 réplica y
crecen **verticalmente** (más CPU/RAM). El camino para hacerlos horizontales está documentado en
cada servicio: mover el estado a **Azure Cosmos DB / PostgreSQL Flexible Server** y los eventos
a **Azure Service Bus**.
