# Documentación · Backend de microservicios (y nube)

Esta carpeta documenta la solución `microservices/` y la infraestructura que la despliega
(`gateway/`, `observability/`, `k8s/`, `infra/`, `scripts/`). Las rutas de código que aparecen en
los documentos son relativas a la raíz `TeamForMe/`.

Documentación de las otras soluciones:
- Frontend: [`TeamForMeFrontend/docs/`](../../TeamForMeFrontend/docs/README.md)
- Plantilla gRPC: [`TeamForMeBackend/docs/`](../../TeamForMeBackend/docs/README.md)

## Sistema
- [01 · Cómo funciona TeamForMe (arquitectura, flujos, contratos)](01-arquitectura.md)

## Microservicios
- [Índice y criterios de escalado](microservicios/README.md)
- [MS.Events](microservicios/ms-events.md) · [MS.Teams](microservicios/ms-teams.md) ·
  [MS.Applications](microservicios/ms-applications.md) · [MS.Users](microservicios/ms-users.md) ·
  [MS.Notifications](microservicios/ms-notifications.md)
- [API Gateway](microservicios/gateway.md) · [Librería TeamForMe.Shared](microservicios/shared.md)
- [Documentación de las APIs con OpenAPI y Scalar](microservicios/api-scalar.md) (página en vivo: `<gateway>/docs`)

## Conceptos cloud aplicados
| # | Tema | Implementación principal |
|---|---|---|
| 01 | [Asignación eficiente de recursos + Azure Key Vault](cloud/01-asignacion-de-recursos-y-key-vault.md) | `infra/modules/keyvault.bicep`, `TeamForMe.Shared/KeyVaultConfiguration.cs` |
| 02 | [Escalabilidad y elasticidad (vertical / horizontal)](cloud/02-escalabilidad-y-elasticidad.md) | `k8s/ms-events/base/hpa.yaml`, `tools/vpa.yaml`, `containerapps.bicep`, `vmss.bicep` |
| 03 | [Adaptabilidad, eficiencia y otras propiedades](cloud/03-adaptabilidad-y-eficiencia.md) | Probes, resiliencia HTTP, scale to zero, `costs.ps1` |
| 04 | [Bases de datos de series temporales y visualización de métricas](cloud/04-series-temporales-y-metricas.md) | `observability/` (Prometheus + Grafana) |
| 05 | [Tipos de sistemas de orquestación + Kubernetes](cloud/05-orquestacion-y-kubernetes.md) | `k8s/ms-events/`, `infra/modules/aks.bicep` |
| 06 | [Gerenciamiento de nubes privadas y públicas](cloud/06-nubes-privadas-y-publicas.md) | `infra/`, overlays `local` vs `aks` |
| 07 | [Máquinas virtuales](cloud/07-maquinas-virtuales.md) | `infra/modules/vm.bicep`, `vmss.bicep` |

## Algoritmos de infraestructura (lanzamiento en Azure)
| # | Algoritmo | Documento |
|---|---|---|
| — | Índice, mapa código ↔ Azure ↔ evidencia | [algoritmos/README.md](algoritmos/README.md) |
| 1 | Balanceo de carga (RR, Smooth WRR, Least Connections, P2C) | [01-balanceo-de-carga.md](algoritmos/01-balanceo-de-carga.md) |
| 2 | Autoescalado horizontal (algoritmo HPA / KEDA) | [02-autoescalado.md](algoritmos/02-autoescalado.md) |
| 3 | Despliegue canary / blue-green con rollback automático | [03-despliegue-canary.md](algoritmos/03-despliegue-canary.md) |
| 4 | Token bucket, backoff exponencial con jitter, circuit breaker | [04-resiliencia-y-rate-limiting.md](algoritmos/04-resiliencia-y-rate-limiting.md) |
| — | Guion de la presentación y lista de capturas | [GUIA-PRESENTACION.md](algoritmos/GUIA-PRESENTACION.md) |

## Despliegue
- [Guía de levantamiento con Azure for Students](despliegue/GUIA-AZURE-STUDENTS.md)
- [Documento de lanzamiento](despliegue/LANZAMIENTO.md)
