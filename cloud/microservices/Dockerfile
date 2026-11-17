# Dockerfile único para los 5 microservicios (multi-stage).
# Uso:  docker build --build-arg SERVICE=MS.Events -t teamforme/ms-events .
#
# - Etapa build: SDK completo (~800 MB), solo existe durante la compilación.
# - Etapa final: runtime ASP.NET (~220 MB), usuario no-root, sin SDK ni código fuente.
#   Imágenes más pequeñas = arranque más rápido de réplicas nuevas (elasticidad).

FROM mcr.microsoft.com/dotnet/sdk:10.0 AS build
ARG SERVICE
WORKDIR /src
# Restaurar primero solo los .csproj aprovecha la caché de capas de Docker.
COPY Directory.Build.props ./
COPY src/TeamForMe.Shared/TeamForMe.Shared.csproj src/TeamForMe.Shared/
COPY src/${SERVICE}/${SERVICE}.csproj src/${SERVICE}/
RUN dotnet restore src/${SERVICE}/${SERVICE}.csproj
COPY src/TeamForMe.Shared/ src/TeamForMe.Shared/
COPY src/${SERVICE}/ src/${SERVICE}/
RUN dotnet publish src/${SERVICE}/${SERVICE}.csproj -c Release -o /app/publish /p:UseAppHost=false --no-restore

FROM mcr.microsoft.com/dotnet/aspnet:10.0 AS final
ARG SERVICE
ARG APP_VERSION=dev
ENV ASPNETCORE_HTTP_PORTS=8080 \
    APP_VERSION=${APP_VERSION} \
    SERVICE_DLL=${SERVICE}.dll \
    # El heap de .NET usa como máximo el 75 % (0x4B) del límite de memoria del contenedor.
    DOTNET_gcHeapHardLimitPercent=0x4B
WORKDIR /app
COPY --from=build /app/publish .
USER $APP_UID
EXPOSE 8080
ENTRYPOINT ["sh", "-c", "exec dotnet \"$SERVICE_DLL\""]
