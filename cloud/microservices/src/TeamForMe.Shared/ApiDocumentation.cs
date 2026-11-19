using Microsoft.AspNetCore.Builder;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.OpenApi;
using Scalar.AspNetCore;

namespace TeamForMe.Shared;

/// <summary>
/// Documentación de la API de cada microservicio:
/// <list type="bullet">
///   <item>Especificación OpenAPI generada por ASP.NET Core en <c>/openapi/v1.json</c>.</item>
///   <item>Referencia interactiva de Scalar en <c>/scalar</c>.</item>
/// </list>
/// El gateway reúne las cinco especificaciones en una sola página (<c>/docs</c>). Por eso el
/// primer servidor del documento es <c>OpenApi:ServerUrl</c> (por defecto <c>/api</c>, la ruta
/// del gateway) y el segundo, <c>/</c>, sirve para llamar al servicio directamente.
/// Las rutas <c>/internal/*</c>, <c>/info</c>, salud y métricas no se documentan.
/// </summary>
public static class ApiDocumentation
{
    private static readonly Dictionary<string, string> Descriptions = new()
    {
        ["ms-events"] = "Catálogo de eventos e ideas en búsqueda de grupo.",
        ["ms-teams"] = "Equipos de cada evento y control de aforo (los equipos privados no exponen integrantes).",
        ["ms-applications"] = "Postulaciones a equipos y su resolución asíncrona (pending → accepted | rejected).",
        ["ms-users"] = "Perfiles de participantes. Sin autenticación en esta fase: el usuario actual sale de X-User-Id.",
        ["ms-notifications"] = "Avisos al participante cuando su postulación se resuelve.",
    };

    public static IServiceCollection AddApiDocumentation(this IServiceCollection services, IConfiguration config, string serviceName)
    {
        services.AddOpenApi(options => options.AddDocumentTransformer((document, _, _) =>
        {
            document.Info = new OpenApiInfo
            {
                Title = $"TeamForMe · {serviceName}",
                Version = config["APP_VERSION"] ?? "v1",
                Description = Descriptions.GetValueOrDefault(serviceName, ""),
            };
            document.Servers =
            [
                new OpenApiServer { Url = config["OpenApi:ServerUrl"] ?? "/api", Description = "A través del API Gateway" },
                new OpenApiServer { Url = "/", Description = "Directo al servicio" },
            ];
            return Task.CompletedTask;
        }));
        return services;
    }

    public static WebApplication MapApiDocumentation(this WebApplication app, string serviceName)
    {
        app.MapOpenApi();
        app.MapScalarApiReference(options => options.WithTitle($"TeamForMe · {serviceName}"));
        return app;
    }
}
