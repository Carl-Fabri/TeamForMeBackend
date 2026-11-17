using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Http.Resilience;
using Microsoft.Extensions.Logging;
using Polly;
using Prometheus;

namespace TeamForMe.Shared;

/// <summary>
/// Pipeline de resiliencia para las llamadas HTTP entre microservicios (Polly v8), con los
/// parámetros explícitos para poder explicarlos y ajustarlos. Orden de las estrategias, de
/// fuera hacia dentro:
/// <code>
///   Timeout total (15 s)
///    └─ Reintento: backoff exponencial + jitter     espera ≈ base · 2^intento ± aleatorio
///        └─ Circuit breaker                          Cerrado → Abierto → Semiabierto
///            └─ Timeout por intento (3 s)
/// </code>
/// <para><b>Backoff exponencial con jitter</b>: tras el fallo n se espera ~200 ms · 2ⁿ
/// (200, 400, 800 ms) con una variación aleatoria. Duplicar la espera evita saturar a un
/// servicio que se está recuperando, y el jitter evita que todas las réplicas reintenten en el
/// mismo instante (tormenta de reintentos sincronizada).</para>
/// <para><b>Circuit breaker</b>: si en una ventana de 30 s hay al menos 10 llamadas y el 50 %
/// falla, el circuito se ABRE y durante 15 s las llamadas fallan al instante sin tocar la red
/// (fail fast). Pasado ese tiempo queda SEMIABIERTO: deja pasar una llamada de prueba; si
/// funciona se CIERRA, si falla vuelve a abrirse.</para>
/// Los reintentos se desactivan para POST/PUT/PATCH/DELETE porque no son idempotentes.
/// </summary>
public static class ResilienceExtensions
{
    private static readonly Gauge CircuitState = Metrics.CreateGauge(
        "teamforme_circuit_breaker_state", "Estado del circuit breaker: 0 cerrado, 1 semiabierto, 2 abierto.", "client");

    private static readonly Counter Retries = Metrics.CreateCounter(
        "teamforme_http_retries_total", "Reintentos de llamadas HTTP entre servicios.", "client");

    public static IHttpClientBuilder AddTeamForMeResilience(this IHttpClientBuilder builder, string clientName)
    {
        builder.AddStandardResilienceHandler()
            .Configure((HttpStandardResilienceOptions o, IServiceProvider sp) =>
            {
                var logger = sp.GetRequiredService<ILoggerFactory>().CreateLogger("Resilience." + clientName);

                o.TotalRequestTimeout.Timeout = TimeSpan.FromSeconds(15);
                o.AttemptTimeout.Timeout = TimeSpan.FromSeconds(3);

                o.Retry.MaxRetryAttempts = 3;
                o.Retry.BackoffType = DelayBackoffType.Exponential;
                o.Retry.UseJitter = true;
                o.Retry.Delay = TimeSpan.FromMilliseconds(200);
                o.Retry.DisableForUnsafeHttpMethods();
                o.Retry.OnRetry = args =>
                {
                    Retries.WithLabels(clientName).Inc();
                    logger.LogWarning("Reintento {Attempt} hacia {Client} en {Delay} ms (causa: {Cause})",
                        args.AttemptNumber + 1, clientName, (int)args.RetryDelay.TotalMilliseconds,
                        args.Outcome.Exception?.GetType().Name ?? $"HTTP {(int?)args.Outcome.Result?.StatusCode}");
                    return default;
                };

                // SamplingDuration debe ser ≥ 2 × AttemptTimeout (lo valida la librería).
                o.CircuitBreaker.SamplingDuration = TimeSpan.FromSeconds(30);
                o.CircuitBreaker.FailureRatio = 0.5;
                o.CircuitBreaker.MinimumThroughput = 10;
                o.CircuitBreaker.BreakDuration = TimeSpan.FromSeconds(15);
                o.CircuitBreaker.OnOpened = args =>
                {
                    CircuitState.WithLabels(clientName).Set(2);
                    logger.LogError("Circuit breaker ABIERTO hacia {Client} durante {Seconds} s",
                        clientName, args.BreakDuration.TotalSeconds);
                    return default;
                };
                o.CircuitBreaker.OnHalfOpened = _ =>
                {
                    CircuitState.WithLabels(clientName).Set(1);
                    logger.LogWarning("Circuit breaker SEMIABIERTO hacia {Client}: llamada de prueba", clientName);
                    return default;
                };
                o.CircuitBreaker.OnClosed = _ =>
                {
                    CircuitState.WithLabels(clientName).Set(0);
                    logger.LogInformation("Circuit breaker CERRADO hacia {Client}", clientName);
                    return default;
                };
            });
        return builder;
    }
}
