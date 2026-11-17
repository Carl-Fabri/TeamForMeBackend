using Microsoft.AspNetCore.Builder;
using Microsoft.AspNetCore.Diagnostics.HealthChecks;
using Microsoft.AspNetCore.Http;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Diagnostics.HealthChecks;
using Microsoft.Extensions.Hosting;
using Prometheus;

namespace TeamForMe.Shared;

/// <summary>
/// Comportamiento "cloud-native" común a todos los microservicios:
/// <list type="bullet">
///   <item>Configuración desde Azure Key Vault (si está configurado).</item>
///   <item>Health checks de vida (<c>/health/live</c>) y disponibilidad (<c>/health/ready</c>)
///         que usan Kubernetes y Container Apps para reiniciar o sacar réplicas del balanceo.</item>
///   <item>Métricas en formato Prometheus en <c>/metrics</c> (series temporales).</item>
///   <item>Limitación de tasa por cliente con Token Bucket (sección <c>RateLimit</c>).</item>
///   <item>Apagado ordenado: al reducir réplicas (scale-in) se drenan las peticiones en curso.</item>
///   <item><c>/info</c> con el nombre de la instancia, para observar el balanceo entre réplicas.</item>
/// </list>
/// </summary>
public static class CloudDefaults
{
    public static WebApplicationBuilder AddCloudDefaults(this WebApplicationBuilder builder, string serviceName)
    {
        builder.AddAzureKeyVaultIfConfigured();

        builder.Services.AddSingleton(new ServiceIdentity(serviceName));
        builder.Services.AddProblemDetails();

        builder.Services.AddTokenBucketRateLimiting(builder.Configuration);

        builder.Services.AddHealthChecks()
            .AddCheck("self", () => HealthCheckResult.Healthy(), tags: ["live"]);

        builder.Services.AddCors(options => options.AddDefaultPolicy(policy =>
        {
            var origins = builder.Configuration["Cors:AllowedOrigins"];
            if (string.IsNullOrWhiteSpace(origins) || origins == "*")
            {
                policy.AllowAnyOrigin();
            }
            else
            {
                policy.WithOrigins(origins.Split(',', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries));
            }
            policy.AllowAnyHeader().AllowAnyMethod();
        }));

        // Kubernetes envía SIGTERM y espera terminationGracePeriodSeconds (30 s por defecto).
        builder.Services.Configure<HostOptions>(o => o.ShutdownTimeout = TimeSpan.FromSeconds(20));

        return builder;
    }

    public static WebApplication MapCloudDefaults(this WebApplication app)
    {
        app.UseExceptionHandler();
        app.UseCors();
        app.UseTokenBucketRateLimiting();
        app.UseChaosInjection(app.Configuration); // inactivo salvo Chaos__FailureRate > 0

        // Histograma de duración y contador de peticiones HTTP por endpoint/código.
        app.UseHttpMetrics();
        app.MapMetrics("/metrics");

        app.MapHealthChecks("/health/live", new HealthCheckOptions { Predicate = c => c.Tags.Contains("live") });
        app.MapHealthChecks("/health/ready");

        app.MapGet("/info", (ServiceIdentity id, IHostEnvironment env, IConfiguration config) => Results.Ok(new
        {
            service = id.Name,
            instance = Environment.MachineName,
            environment = env.EnvironmentName,
            version = config["APP_VERSION"] ?? "dev",
            keyVault = !string.IsNullOrWhiteSpace(config["KeyVault:Uri"]),
            processorCount = Environment.ProcessorCount,
            startedAt = id.StartedAt,
        }));

        return app;
    }
}

public sealed record ServiceIdentity(string Name)
{
    public DateTimeOffset StartedAt { get; } = DateTimeOffset.UtcNow;
}
