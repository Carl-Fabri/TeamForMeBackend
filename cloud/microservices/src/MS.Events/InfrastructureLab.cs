using System.Diagnostics;
using Polly.CircuitBreaker;
using Prometheus;
using TeamForMe.Shared;
using TeamForMe.Shared.Algorithms;

/// <summary>
/// Laboratorio de algoritmos de infraestructura, expuesto en <c>/api/lab/*</c> a través del
/// gateway. Ejecuta las implementaciones de <c>TeamForMe.Shared/Algorithms</c> y devuelve
/// resultados medibles para la demostración:
/// <list type="bullet">
///   <item><c>/lab/load-balancing</c>: compara Round Robin, Weighted, Least Connections y P2C.</item>
///   <item><c>/lab/load-balancing/sequence</c>: orden de elección (intercalado del WRR suave).</item>
///   <item><c>/lab/autoscaler</c>: línea de tiempo del algoritmo HPA/KEDA ante un perfil de carga.</item>
///   <item><c>/lab/work</c>: retiene la petición N ms para generar concurrencia REAL y que
///         Container Apps escale ms-events (regla KEDA HTTP).</item>
///   <item><c>/lab/resilience</c>: llamadas a un endpoint inestable con reintentos + circuit breaker.</item>
/// </list>
/// </summary>
public static class InfrastructureLab
{
    private static readonly Gauge InFlight = Metrics.CreateGauge(
        "teamforme_lab_work_inflight", "Peticiones /lab/work en curso en esta réplica.");

    private static long _flakyHits;

    public static IServiceCollection AddInfrastructureLab(this IServiceCollection services)
    {
        services.AddHttpClient("lab-flaky", (sp, client) =>
            {
                var config = sp.GetRequiredService<IConfiguration>();
                client.BaseAddress = new Uri(config["Lab:SelfUrl"] ?? "http://localhost:8080");
            })
            .AddTeamForMeResilience("lab-flaky");
        return services;
    }

    public static WebApplication MapInfrastructureLab(this WebApplication app)
    {
        var lab = app.MapGroup("/lab");

        // ---------------------------------------------------------------- Balanceo de carga
        lab.MapGet("/load-balancing", (string? strategy, int? requests, double? rate, int? seed) =>
        {
            var n = Math.Clamp(requests ?? 5000, 100, 50_000);
            var arrival = Math.Clamp(rate ?? 80, 1, 1000);
            var strategies = string.IsNullOrWhiteSpace(strategy) || strategy == "all"
                ? LoadBalancer.Strategies
                : [strategy];
            var results = strategies.Select(s => LoadBalancingSimulator.Run(s, n, arrival, seed: seed ?? 42)).ToArray();
            var capacity = LoadBalancingSimulator.DefaultBackends.Sum(b => 1000.0 / b.ServiceMs);
            return Results.Ok(new
            {
                scenario = new
                {
                    description = "Réplicas heterogéneas; llegadas de Poisson; mismas peticiones para todos los algoritmos.",
                    backends = LoadBalancingSimulator.DefaultBackends,
                    totalCapacityRps = Math.Round(capacity, 1),
                    arrivalRps = arrival,
                    utilizationPercent = Math.Round(100 * arrival / capacity, 1),
                    requests = n,
                },
                best = results.MinBy(r => r.P95LatencyMs)!.Strategy,
                results,
            });
        });

        lab.MapGet("/load-balancing/sequence", (string? strategy, string? weights, int? n) =>
        {
            var w = (weights ?? "5,1,1").Split(',').Select(int.Parse).ToArray();
            var backends = w.Select((weight, i) => new Backend(((char)('a' + i)).ToString(), weight)).ToArray();
            var balancer = LoadBalancer.Create(strategy ?? "weighted", backends);
            var picks = Enumerable.Range(0, Math.Clamp(n ?? w.Sum() * 2, 1, 200)).Select(_ => balancer.Select().Name).ToArray();
            return Results.Ok(new
            {
                strategy = balancer.Name,
                weights = backends.ToDictionary(b => b.Name, b => b.Weight),
                sequence = string.Join(" ", picks),
                counts = picks.GroupBy(p => p).OrderBy(g => g.Key).ToDictionary(g => g.Key, g => g.Count()),
            });
        });

        // ---------------------------------------------------------------- Autoescalado
        lab.MapGet("/autoscaler", (string? profile, double? target, int? min, int? max, int? intervalSeconds) =>
        {
            var options = new AutoscalerOptions
            {
                TargetPerReplica = target ?? 30,
                MinReplicas = min ?? 0,
                MaxReplicas = max ?? 10,
            };
            var interval = TimeSpan.FromSeconds(intervalSeconds ?? 30);
            var timeline = HorizontalAutoscaler.Simulate(options, HorizontalAutoscaler.Profile(profile ?? "spike"), interval);
            return Results.Ok(new
            {
                algorithm = "desired = ceil(total / target), tolerancia 10 %, estabilización de bajada 300 s, subida máx(+4, ×2)",
                options,
                intervalSeconds = interval.TotalSeconds,
                timeline = timeline.Select(d => new
                {
                    t = $"{(int)(d.At - DateTimeOffset.UnixEpoch).TotalSeconds}s",
                    load = d.TotalMetric,
                    replicasBefore = d.CurrentReplicas,
                    perReplica = d.MetricPerReplica,
                    rawDesired = d.RawDesired,
                    replicasAfter = d.FinalReplicas,
                    d.Reason,
                }),
            });
        });

        // Carga real para el autoescalado de Container Apps: cada petición ocupa una "conexión
        // concurrente" durante ms milisegundos (simula E/S lenta sin gastar CPU).
        lab.MapGet("/work", async (int? ms, IConfiguration config, CancellationToken ct) =>
        {
            var delay = Math.Clamp(ms ?? 1000, 0, 10_000);
            using (InFlight.TrackInProgress())
            {
                await Task.Delay(delay, ct);
            }
            return Results.Ok(new { instance = Environment.MachineName, version = config["APP_VERSION"] ?? "dev", workedMs = delay });
        }).SkipTokenBucketRateLimit(); // la prueba de carga supera a propósito el límite por cliente

        // ---------------------------------------------------------------- Resiliencia
        // Endpoint inestable: falla con probabilidad failureRate (503).
        lab.MapGet("/flaky", (double? failureRate) =>
        {
            Interlocked.Increment(ref _flakyHits);
            return Random.Shared.NextDouble() < Math.Clamp(failureRate ?? 0.5, 0, 1)
                ? Results.StatusCode(StatusCodes.Status503ServiceUnavailable)
                : Results.Ok(new { ok = true });
        }).SkipTokenBucketRateLimit();

        // Hace "calls" llamadas secuenciales a /lab/flaky con el pipeline de resiliencia y
        // reporta, por llamada, cuántos intentos hubo y si el circuito estaba abierto.
        // pauseMs > 0 deja pasar el tiempo entre llamadas para observar Abierto → Semiabierto → Cerrado.
        lab.MapGet("/resilience", async (double? failureRate, int? calls, int? pauseMs, IHttpClientFactory factory, CancellationToken ct) =>
        {
            var client = factory.CreateClient("lab-flaky");
            var rate = Math.Clamp(failureRate ?? 0.7, 0, 1);
            var pause = Math.Clamp(pauseMs ?? 0, 0, 5000);
            var log = new List<object>();
            var started = Stopwatch.StartNew();
            for (var i = 1; i <= Math.Clamp(calls ?? 20, 1, 60); i++)
            {
                if (i > 1 && pause > 0) await Task.Delay(pause, ct);
                var before = Interlocked.Read(ref _flakyHits);
                var sw = Stopwatch.StartNew();
                string outcome;
                try
                {
                    using var response = await client.GetAsync($"/lab/flaky?failureRate={rate.ToString(System.Globalization.CultureInfo.InvariantCulture)}", ct);
                    outcome = $"HTTP {(int)response.StatusCode}";
                }
                catch (BrokenCircuitException)
                {
                    outcome = "circuito ABIERTO (fail fast)";
                }
                catch (Exception ex) when (ex is HttpRequestException or TimeoutException or Polly.Timeout.TimeoutRejectedException)
                {
                    outcome = ex.GetType().Name;
                }
                var attempts = Interlocked.Read(ref _flakyHits) - before;
                log.Add(new { call = i, atSecond = Math.Round(started.Elapsed.TotalSeconds, 1), outcome, networkAttempts = attempts, elapsedMs = sw.ElapsedMilliseconds });
            }
            return Results.Ok(new
            {
                failureRate = rate,
                policy = "3 reintentos con backoff exponencial (200 ms·2ⁿ + jitter); breaker abre con ≥50 % de fallos en 30 s (mín. 10 llamadas) durante 15 s",
                calls = log,
            });
        });

        return app;
    }
}
