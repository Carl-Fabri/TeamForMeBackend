using Microsoft.AspNetCore.Builder;
using Microsoft.AspNetCore.Http;
using Microsoft.Extensions.Configuration;

namespace TeamForMe.Shared;

/// <summary>
/// Inyección de fallos (chaos engineering) controlada por configuración:
/// <c>Chaos__FailureRate=0.3</c> hace que el 30 % de las peticiones respondan 500.
/// <para>
/// Vale 0 por defecto. Se usa para demostrar que el despliegue canary detecta una versión
/// defectuosa y hace rollback automático (<c>scripts/azure/canary.ps1 -SimulateFailure</c>):
/// solo la revisión nueva recibe la variable, así que solo ella falla.
/// </para>
/// Los health checks quedan fuera para que la plataforma no reinicie la réplica: el objetivo es
/// que el fallo lo detecte la puerta de calidad del canary, no el liveness probe.
/// </summary>
public static class ChaosInjection
{
    public static IApplicationBuilder UseChaosInjection(this IApplicationBuilder app, IConfiguration configuration)
    {
        var rate = configuration.GetValue("Chaos:FailureRate", 0.0);
        if (rate <= 0) return app;
        var version = configuration["APP_VERSION"] ?? "dev";

        return app.Use(async (context, next) =>
        {
            if (!context.Request.Path.StartsWithSegments("/health")
                && !context.Request.Path.StartsWithSegments("/metrics")
                && Random.Shared.NextDouble() < rate)
            {
                context.Response.StatusCode = StatusCodes.Status500InternalServerError;
                // Se incluye la versión para que el análisis canary atribuya el error a su revisión.
                await context.Response.WriteAsJsonAsync(new
                {
                    error = "chaos",
                    message = "Fallo inyectado (Chaos:FailureRate).",
                    instance = Environment.MachineName,
                    version,
                });
                return;
            }
            await next(context);
        });
    }
}
