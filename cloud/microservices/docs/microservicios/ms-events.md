# MS.Events — catálogo de eventos e ideas

**Código:** `microservices/src/MS.Events/Program.cs` · **Puerto:** 8080 · **Kubernetes:** `k8s/ms-events/`

## Responsabilidad
Publicar la lista de eventos (nombre, fecha, lugar, coordenadas para el mapa, descripción).
Es la puerta de entrada del producto (historia de usuario 1) y el endpoint más consultado.

## Endpoints
| Método | Ruta | Respuesta |
|---|---|---|
| GET | `/events` | `EventModel[]` |
| GET | `/events/{id}` | `EventModel` o 404 |

```json
{ "id": "evt-hackcloud-2026", "name": "HackCloud 2026", "date": "2026-09-19T09:00:00-05:00",
  "location": "Bogotá, Colombia", "coords": { "lat": 4.6533, "lng": -74.0836 },
  "description": "Cuarenta y ocho horas...", "themeGradient": "radial-gradient(...)" }
```
Un evento sin `coords` (evento remoto) es válido: el frontend oculta el mapa.

## Datos
Catálogo inmutable en memoria (`EventCatalog`), equivalente a `events.mock.ts`.
Evolución: Azure Cosmos DB (API NoSQL, partición por `id`) + caché en Azure Cache for Redis.

## Configuración
| Variable | Descripción |
|---|---|
| `KeyVault__Uri` | URI del vault (vacío = sin Key Vault) |
| `AZURE_CLIENT_ID` | Client id de la identidad administrada |
| `Cors__AllowedOrigins` | Orígenes permitidos |

## Escalado (módulo elegido para Kubernetes)
Al no tener estado es el candidato ideal para **escalado horizontal**:

| Plataforma | Mecanismo | Rango |
|---|---|---|
| Docker Compose | `deploy.replicas: 2` / `--scale ms-events=N` | manual |
| Container Apps | Regla HTTP (KEDA): 30 peticiones concurrentes por réplica | 0 – 5 (scale to zero) |
| AKS | HPA CPU 60 % / memoria 75 % + VPA (recomendación) + Cluster Autoscaler | 2 – 10 pods, 1 – 2 nodos |

Recursos por réplica en Kubernetes: requests `50m CPU / 96Mi`, limits `500m / 256Mi` (QoS *Burstable*).
Ver [orquestación y Kubernetes](../cloud/05-orquestacion-y-kubernetes.md).

## Métricas
Métricas HTTP estándar: `http_requests_received_total`, `http_request_duration_seconds`.
