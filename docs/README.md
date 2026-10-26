# Documentación · TeamForMeBackend

Solución .NET 10 generada con la plantilla **ASP.NET Core gRPC Service**. Es el punto de partida
original del backend; la funcionalidad de negocio vive en la solución
[`microservices/`](../../microservices/docs/README.md).

## Contenido
| Archivo | Qué es |
|---|---|
| `Program.cs` | Registra gRPC (`AddGrpc`) y publica `GreeterService`; `GET /` devuelve un texto informativo |
| `Protos/greet.proto` | Contrato `greet.Greeter` con el RPC `SayHello(HelloRequest) → HelloReply` |
| `Services/GreeterService.cs` | Implementación: responde `"Hello " + name` y registra el nombre recibido |
| `appsettings.json` | Kestrel solo con **HTTP/2** (`Protocols: Http2`), necesario para gRPC |
| `Dockerfile` | Imagen multi-stage generada por Visual Studio (puertos 8080/8081) |
| `Properties/launchSettings.json` | Perfiles `http` (5056), `https` (7179) y `Container (Dockerfile)` |

## Ejecutar
Con el SDK .NET 10:
```bash
dotnet run --project TeamForMeBackend.csproj
```
Con Docker, desde esta carpeta:
```bash
docker build -t teamforme/grpc-backend:local .
```
```bash
docker run --rm -p 5056:8080 teamforme/grpc-backend:local
```
Probar el RPC con [grpcurl](https://github.com/fullstorydev/grpcurl) (el servicio no tiene
*reflection* habilitada, así que se le pasa el `.proto`):
```bash
grpcurl -plaintext -proto Protos/greet.proto -d '{"name":"TeamForMe"}' localhost:5056 greet.Greeter/SayHello
```

## Relación con los microservicios
| Aspecto | TeamForMeBackend (gRPC) | microservices/ (REST) |
|---|---|---|
| Protocolo | gRPC sobre HTTP/2, binario (Protobuf) | HTTP/JSON |
| Consumidor natural | Otros servicios (tráfico interno) | Navegador y gateway |
| Estado | Plantilla de ejemplo | 5 servicios con lógica de negocio |
| Despliegue | No incluido en `docker-compose.yml` ni en Azure | Compose, Container Apps y AKS |

### Evolución propuesta
La comunicación interna (`/internal/*`) entre MS.Applications, MS.Teams y MS.Notifications hoy
usa HTTP/JSON. Se podría migrar a gRPC tomando esta solución como base:

1. Definir el contrato, por ejemplo `teams.proto` con `rpc Reserve(ReserveRequest) returns (ReserveReply)`.
2. Implementar el servidor en MS.Teams con `Grpc.AspNetCore` y el cliente en MS.Applications con
   `Grpc.Net.ClientFactory` (`AddGrpcClient<T>()`, que admite el mismo `AddStandardResilienceHandler`).
3. En Container Apps, configurar el ingress interno de MS.Teams con `transport: 'http2'`.

Ventajas: contrato fuerte y versionado, mensajes más pequeños y *streaming* (útil para que el
estado de una postulación se empuje en lugar de consultarlo con *polling*).

## Pendiente si se mantiene esta solución
- Agregar `/health` y `/metrics` con la librería `TeamForMe.Shared` para alinearla con el resto del backend.
- Habilitar `Grpc.AspNetCore.Server.Reflection` solo en desarrollo.
- Integrarla en `docker-compose.yml` y en `infra/modules/containerapps.bicep` con ingress `http2`.
