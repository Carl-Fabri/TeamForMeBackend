using System.Collections.Concurrent;
using System.Globalization;
using Microsoft.AspNetCore.Builder;
using Microsoft.AspNetCore.Http;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Logging;
using Prometheus;
using TeamForMe.Shared.Algorithms;

namespace TeamForMe.Shared;

/// <summary>Configuración "RateLimit" (appsettings, variables RateLimit__* o Key Vault).</summary>
public sealed class RateLimitOptions
{
    public bool Enabled { get; set; } = true;

    /// <summary>Ráfaga máxima por cliente (capacidad de la cubeta).</summary>
    public double Capacity { get; set; } = 100;

    /// <summary>Peticiones por segundo sostenidas por cliente (velocidad de relleno).</summary>
    public double RefillPerSecond { get; set; } = 50;
}

/// <summary>
/// Middleware de limitación de tasa por cliente con <see cref="TokenBucket"/>.
/// <list type="bullet">
///   <item>Clave del cliente: primera IP de <c>X-Forwarded-For</c> (la que puso el ingress de
///         Azure / nginx) o, si no existe, la IP de la conexión.</item>
///   <item>Respuesta al exceder: <c>429 Too Many Requests</c> con <c>Retry-After</c>.</item>
///   <item>Cabeceras informativas <c>X-RateLimit-Limit</c> y <c>X-RateLimit-Remaining</c>.</item>
///   <item>Health checks, métricas, /info e /internal quedan exentos.</item>
///   <item>Las cubetas inactivas se liberan periódicamente: memoria acotada al nº de clientes activos.</item>
/// </list>
/// El estado vive en memoria de cada réplica: con N réplicas el límite efectivo es ≈ N × r.
/// Para un límite global exacto se movería la cubeta a Redis (siguiente hito).
/// </summary>
public sealed class TokenBucketRateLimitingMiddleware(
    RequestDelegate next, RateLimitOptions options, ILogger<TokenBucketRateLimitingMiddleware> logger)
{
    private static readonly Counter Decisions = Metrics.CreateCounter(
        "teamforme_rate_limit_decisions_total", "Decisiones del token bucket por resultado.", "result");

    // /internal es tráfico servicio a servicio (ya protegido por la clave interna y no expuesto
    // por el gateway): limitarlo por IP penalizaría a toda una réplica de MS.Applications.
    private static readonly string[] ExemptPrefixes = ["/health", "/metrics", "/info", "/internal"];
    private static readonly TimeSpan IdleEviction = TimeSpan.FromMinutes(2);

    private readonly ConcurrentDictionary<string, TokenBucket> _buckets = new();
    private long _requestsSinceSweep;

    public async Task InvokeAsync(HttpContext context)
    {
        if (!options.Enabled
            || ExemptPrefixes.Any(p => context.Request.Path.StartsWithSegments(p))
            || context.GetEndpoint()?.Metadata.GetMetadata<SkipRateLimitMetadata>() is not null)
        {
            await next(context);
            return;
        }

        var client = ClientKey(context);
        var bucket = _buckets.GetOrAdd(client, _ => new TokenBucket(options.Capacity, options.RefillPerSecond));
        var result = bucket.TryTake();

        context.Response.Headers["X-RateLimit-Limit"] = options.Capacity.ToString(CultureInfo.InvariantCulture);
        context.Response.Headers["X-RateLimit-Remaining"] = Math.Floor(result.Remaining).ToString(CultureInfo.InvariantCulture);

        if (Interlocked.Increment(ref _requestsSinceSweep) % 1000 == 0) Sweep();

        if (result.Allowed)
        {
            Decisions.WithLabels("allowed").Inc();
            await next(context);
            return;
        }

        Decisions.WithLabels("limited").Inc();
        var retryAfter = Math.Max(1, (int)Math.Ceiling(result.RetryAfter.TotalSeconds));
        logger.LogWarning("Rate limit excedido para {Client} en {Path}; Retry-After {RetryAfter}s",
            client, context.Request.Path, retryAfter);
        context.Response.StatusCode = StatusCodes.Status429TooManyRequests;
        context.Response.Headers.RetryAfter = retryAfter.ToString(CultureInfo.InvariantCulture);
        await context.Response.WriteAsJsonAsync(new
        {
            error = "rate_limited",
            message = $"Demasiadas peticiones. Reintenta en {retryAfter} s.",
            limit = options.Capacity,
            refillPerSecond = options.RefillPerSecond,
        });
    }

    private static string ClientKey(HttpContext context)
    {
        var forwarded = context.Request.Headers["X-Forwarded-For"].FirstOrDefault();
        if (!string.IsNullOrWhiteSpace(forwarded))
        {
            var first = forwarded.Split(',')[0].Trim();
            if (first.Length > 0) return first;
        }
        return context.Connection.RemoteIpAddress?.ToString() ?? "unknown";
    }

    private void Sweep()
    {
        var now = TimeProvider.System.GetTimestamp();
        foreach (var (key, bucket) in _buckets)
        {
            if (TimeProvider.System.GetElapsedTime(bucket.LastUsedTimestamp, now) > IdleEviction)
            {
                _buckets.TryRemove(key, out _);
            }
        }
    }
}

/// <summary>Marca un endpoint como exento del token bucket.</summary>
public sealed class SkipRateLimitMetadata;

public static class RateLimitingExtensions
{
    /// <summary>
    /// Excluye el endpoint del rate limiting (p. ej. el generador de carga del laboratorio de
    /// autoescalado, que debe poder superar el límite por cliente a propósito).
    /// </summary>
    public static TBuilder SkipTokenBucketRateLimit<TBuilder>(this TBuilder builder) where TBuilder : IEndpointConventionBuilder =>
        builder.WithMetadata(new SkipRateLimitMetadata());

    public static IServiceCollection AddTokenBucketRateLimiting(this IServiceCollection services, IConfiguration configuration)
    {
        var options = new RateLimitOptions();
        configuration.GetSection("RateLimit").Bind(options);
        return services.AddSingleton(options);
    }

    public static IApplicationBuilder UseTokenBucketRateLimiting(this IApplicationBuilder app) =>
        app.UseMiddleware<TokenBucketRateLimitingMiddleware>();
}
