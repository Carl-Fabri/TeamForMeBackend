namespace TeamForMe.Shared.Algorithms;

/// <summary>Réplica simulada: peso declarado y tiempo medio de servicio (ms).</summary>
public sealed record SimulatedBackend(string Name, int Weight, double ServiceMs);

public sealed record BackendStats(string Name, int Weight, int Requests, double SharePercent, int MaxActive, double AvgLatencyMs);

public sealed record SimulationResult(
    string Strategy, int Requests, double ArrivalRatePerSecond,
    double AvgLatencyMs, double P95LatencyMs, double P99LatencyMs,
    IReadOnlyList<BackendStats> Backends);

/// <summary>
/// Simulación de eventos discretos para comparar los algoritmos de balanceo sobre las
/// MISMAS peticiones (misma semilla): llegadas de Poisson y réplicas heterogéneas, cada una
/// atiende en orden FIFO con un tiempo de servicio variable (±50 %).
/// <para>
/// Sirve para mostrar en la presentación por qué Round Robin degrada la latencia cuando las
/// réplicas no son iguales, y cómo Weighted / Least Connections / P2C lo corrigen.
/// </para>
/// </summary>
public static class LoadBalancingSimulator
{
    public static readonly IReadOnlyList<SimulatedBackend> DefaultBackends =
    [
        new("replica-a (1 vCPU)", 3, 20),
        new("replica-b (0.5 vCPU)", 2, 30),
        new("replica-c (0.25 vCPU)", 1, 60),
    ];

    public static SimulationResult Run(
        string strategy, int requests, double arrivalRatePerSecond,
        IReadOnlyList<SimulatedBackend>? spec = null, int seed = 42)
    {
        spec ??= DefaultBackends;
        var backends = spec.Select(s => new Backend(s.Name, s.Weight)).ToArray();
        var index = backends.Select((b, i) => (b, i)).ToDictionary(x => x.b, x => x.i);
        var random = new Random(seed);
        var balancer = strategy is "p2c" or "power-of-two"
            ? new PowerOfTwoChoicesBalancer(backends, new Random(seed + 1))
            : LoadBalancer.Create(strategy, backends);

        var freeAt = new double[backends.Length];
        var count = new int[backends.Length];
        var maxActive = new int[backends.Length];
        var latencySum = new double[backends.Length];
        var latencies = new double[requests];
        var inFlight = new PriorityQueue<BackendLease, double>();
        var meanGapMs = 1000.0 / arrivalRatePerSecond;
        var now = 0.0;

        for (var r = 0; r < requests; r++)
        {
            now += -meanGapMs * Math.Log(1 - random.NextDouble()); // llegada de Poisson

            // Liberar las peticiones que ya terminaron antes de esta llegada.
            while (inFlight.TryPeek(out _, out var finish) && finish <= now)
            {
                inFlight.Dequeue().Dispose();
            }

            var lease = balancer.Acquire();
            var i = index[lease.Backend];
            var service = spec[i].ServiceMs * (0.5 + random.NextDouble());
            var start = Math.Max(now, freeAt[i]);
            var end = start + service;
            freeAt[i] = end;
            inFlight.Enqueue(lease, end);

            var latency = end - now;
            latencies[r] = latency;
            latencySum[i] += latency;
            count[i]++;
            maxActive[i] = Math.Max(maxActive[i], lease.Backend.ActiveConnections);
        }

        Array.Sort(latencies);
        var stats = backends.Select((b, i) => new BackendStats(
            b.Name, b.Weight, count[i],
            Math.Round(100.0 * count[i] / requests, 1),
            maxActive[i],
            count[i] == 0 ? 0 : Math.Round(latencySum[i] / count[i], 1))).ToArray();

        return new SimulationResult(
            balancer.Name, requests, arrivalRatePerSecond,
            Math.Round(latencies.Average(), 1),
            Math.Round(Percentile(latencies, 0.95), 1),
            Math.Round(Percentile(latencies, 0.99), 1),
            stats);
    }

    private static double Percentile(double[] sorted, double p) =>
        sorted[Math.Clamp((int)Math.Ceiling(p * sorted.Length) - 1, 0, sorted.Length - 1)];
}
