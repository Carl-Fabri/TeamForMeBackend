# TeamForMe · Backend de microservicios e infraestructura en Azure

Esta carpeta reúne los microservicios, la infraestructura como código y los algoritmos de
infraestructura con los que se lanzó TeamForMe en Azure Container Apps. La plantilla gRPC
original está en la raíz de este repositorio y no depende de `cloud/`.

```text
cloud/
├── microservices/         5 microservicios .NET 10 + librería, pruebas y herramienta de carga
├── gateway/               API Gateway (nginx)
├── observability/         Prometheus (TSDB) + Grafana
├── k8s/ms-events/         Módulo MS.Events en Kubernetes (Kustomize)
├── infra/                 Infraestructura Azure (Bicep)
├── scripts/azure/         Despliegue, canary, demos de algoritmos y control de costos
└── docker-compose.yml     Entorno local completo
```

> **Frontend:** vive en su propio repositorio (`Carl-Fabri/TeamForMe`). `docker-compose.yml` y
> `scripts/azure/deploy.ps1` esperan encontrarlo en `cloud/TeamForMeFrontend/`: clónalo ahí antes
> de levantar el entorno completo, o usa `deploy.ps1 -SkipImages` si su imagen ya está en ACR.

## Algoritmos de infraestructura
Balanceo de carga, autoescalado HPA/KEDA, despliegue canary con rollback automático, token bucket,
backoff exponencial con jitter y circuit breaker. Hay un documento por algoritmo, con el código,
la configuración en Azure y la evidencia de cada uno:
[microservices/docs/algoritmos/](microservices/docs/algoritmos/README.md)

```bash
dotnet test microservices/tests/TeamForMe.Algorithms.Tests
```

## Inicio rápido (local)
```bash
cp .env.example .env
```
```bash
docker compose up -d --build
```
App y API en http://localhost:8080 (`/api/events`), Prometheus en http://localhost:9090 y
Grafana en http://localhost:3000.

## Azure (Azure for Students)
```powershell
az login
```
```powershell
./scripts/azure/deploy.ps1 -ResourceGroup rg-teamforme -ResourceLocation centralus -UseAcrBuild
```
```powershell
./scripts/azure/demo-algoritmos.ps1
```
```powershell
./scripts/azure/canary.ps1 -Version v2
```

Guía completa: [microservices/docs/despliegue/GUIA-AZURE-STUDENTS.md](microservices/docs/despliegue/GUIA-AZURE-STUDENTS.md)

## Documentación
| Tema | Documento |
|---|---|
| Backend de microservicios, nube y despliegue | [microservices/docs/](microservices/docs/README.md) |
| Algoritmos de infraestructura | [microservices/docs/algoritmos/](microservices/docs/algoritmos/README.md) |
| Plantilla gRPC (raíz del repo) | [../docs/](../docs/README.md) |
