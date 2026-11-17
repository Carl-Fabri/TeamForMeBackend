using System.Collections.Concurrent;
using System.Diagnostics;
using System.Net;
using System.Text.Json;

// tfm-load: generador de carga de TeamForMe.
//
//   load          N trabajadores concurrentes durante S segundos (autoescalado KEDA).
//   burst         N peticiones disparadas a la vez (token bucket → 429).
//   distribution  N peticiones y conteo por réplica / versión (balanceo y canary).
//
// Ejemplos:
//   tfm-load load https://<gateway>/api/lab/work?ms=2000 --concurrency 150 --duration 240
//   tfm-load burst https://<gateway>/api/users/u-1 --count 400
//   tfm-load distribution https://<gateway>/api/events/_info --count 200 --json
if (args.Length < 2 || args[0] is "-h" or "--help")
{
    Console.WriteLine("uso: tfm-load <load|burst|distribution> <url> [--concurrency N] [--duration S] [--count N] [--parallel P] [--json]");
    return 2;
}

var mode = args[0];
var url = args[1];
int Opt(string name, int fallback) =>
    Array.IndexOf(args, name) is var i and >= 0 && i + 1 < args.Length ? int.Parse(args[i + 1]) : fallback;
var json = args.Contains("--json");

using var http = new HttpClient(new SocketsHttpHandler
{
    MaxConnectionsPerServer = 1000,
    PooledConnectionLifetime = TimeSpan.FromSeconds(15), // re-resuelve DNS / reparte entre réplicas
})
{ Timeout = TimeSpan.FromSeconds(30) };

var results = new ConcurrentBag<Sample>();

async Task<Sample> Send()
{
    var sw = Stopwatch.StartNew();
    try
    {
        using var response = await http.GetAsync(url);
        var body = await response.Content.ReadAsStringAsync();
        string? instance = null, version = null;
        if (body.StartsWith('{'))
        {
            try
            {
                using var doc = JsonDocument.Parse(body);
                if (doc.RootElement.TryGetProperty("instance", out var i)) instance = i.GetString();
                if (doc.RootElement.TryGetProperty("version", out var v)) version = v.GetString();
            }
            catch (JsonException) { }
        }
        var retryAfter = response.Headers.RetryAfter?.Delta?.TotalSeconds;
        return new Sample((int)response.StatusCode, sw.Elapsed.TotalMilliseconds, instance, version, retryAfter);
    }
    catch (Exception ex) when (ex is HttpRequestException or TaskCanceledException)
    {
        return new Sample(0, sw.Elapsed.TotalMilliseconds, null, null, null);
    }
}

var total = Stopwatch.StartNew();
switch (mode)
{
    case "load":
    {
        var concurrency = Opt("--concurrency", 50);
        var duration = TimeSpan.FromSeconds(Opt("--duration", 60));
        Console.WriteLine($"[load] {concurrency} trabajadores durante {duration.TotalSeconds} s → {url}");
        using var cts = new CancellationTokenSource(duration);
        var progress = Task.Run(async () =>
        {
            var last = 0;
            while (!cts.IsCancellationRequested)
            {
                try { await Task.Delay(10_000, cts.Token); } catch (TaskCanceledException) { break; }
                var snapshot = results.ToArray();
                var window = snapshot.Length - last;
                last = snapshot.Length;
                var instances = snapshot.Where(s => s.Instance != null).Select(s => s.Instance).Distinct().Count();
                Console.WriteLine($"  t={total.Elapsed.TotalSeconds,5:0}s  peticiones={snapshot.Length,6}  rps={window / 10.0,6:0.0}  réplicas distintas vistas={instances}");
            }
        });
        var workers = Enumerable.Range(0, concurrency).Select(async _ =>
        {
            while (!cts.IsCancellationRequested) results.Add(await Send());
        });
        await Task.WhenAll(workers);
        await progress;
        break;
    }
    case "burst":
    {
        var count = Opt("--count", 300);
        Console.WriteLine($"[burst] {count} peticiones simultáneas → {url}");
        var samples = await Task.WhenAll(Enumerable.Range(0, count).Select(_ => Send()));
        foreach (var s in samples) results.Add(s);
        break;
    }
    case "distribution":
    {
        var count = Opt("--count", 100);
        var parallel = Opt("--parallel", 4);
        if (!json) Console.WriteLine($"[distribution] {count} peticiones ({parallel} en paralelo) → {url}");
        await Parallel.ForEachAsync(Enumerable.Range(0, count), new ParallelOptions { MaxDegreeOfParallelism = parallel },
            async (_, _) => results.Add(await Send()));
        break;
    }
    default:
        Console.Error.WriteLine($"Modo desconocido: {mode}");
        return 2;
}
total.Stop();

var all = results.ToArray();
var ok = all.Count(s => s.Status is >= 200 and < 400);
var errors = all.Count(s => s.Status is 0 or >= 500);
var latencies = all.Select(s => s.Ms).Order().ToArray();
double P(double p) => latencies.Length == 0 ? 0 : latencies[Math.Clamp((int)Math.Ceiling(p * latencies.Length) - 1, 0, latencies.Length - 1)];

var summary = new
{
    mode,
    url,
    requests = all.Length,
    seconds = Math.Round(total.Elapsed.TotalSeconds, 1),
    rps = Math.Round(all.Length / total.Elapsed.TotalSeconds, 1),
    ok,
    errors,
    errorRate = all.Length == 0 ? 0 : Math.Round((double)errors / all.Length, 4),
    status = all.GroupBy(s => s.Status).OrderBy(g => g.Key).ToDictionary(g => g.Key == 0 ? "error-red" : g.Key.ToString(), g => g.Count()),
    latencyMs = new { p50 = Math.Round(P(0.5)), p95 = Math.Round(P(0.95)), p99 = Math.Round(P(0.99)) },
    instances = all.Where(s => s.Instance != null).GroupBy(s => s.Instance!).OrderByDescending(g => g.Count()).ToDictionary(g => g.Key, g => g.Count()),
    versions = all.Where(s => s.Version != null).GroupBy(s => s.Version!).OrderByDescending(g => g.Count()).ToDictionary(g => g.Key, g => g.Count()),
    // Errores atribuidos a cada versión (análisis canary: comparar la nueva contra la estable).
    versionErrors = all.Where(s => s.Version != null).GroupBy(s => s.Version!)
        .ToDictionary(g => g.Key, g => g.Count(s => s.Status is 0 or >= 500)),
    retryAfterSeconds = all.Where(s => s.RetryAfter != null).Select(s => s.RetryAfter).FirstOrDefault(),
};

if (json)
{
    Console.WriteLine(JsonSerializer.Serialize(summary));
    return 0;
}

Console.WriteLine();
Console.WriteLine($"Peticiones: {summary.requests} en {summary.seconds} s ({summary.rps} rps) | OK {ok} | errores {errors} ({summary.errorRate:P2})");
Console.WriteLine("Códigos HTTP: " + string.Join("  ", summary.status.Select(kv => $"{kv.Key}={kv.Value}")));
Console.WriteLine($"Latencia: p50={summary.latencyMs.p50} ms  p95={summary.latencyMs.p95} ms  p99={summary.latencyMs.p99} ms");
if (summary.retryAfterSeconds is { } ra) Console.WriteLine($"Retry-After recibido: {ra} s");
if (summary.instances.Count > 0)
{
    Console.WriteLine($"Réplicas que respondieron ({summary.instances.Count}):");
    foreach (var (name, n) in summary.instances)
        Console.WriteLine($"  {name,-45} {n,6}  {100.0 * n / all.Length,5:0.0} %  {new string('█', (int)Math.Round(40.0 * n / all.Length))}");
}
if (summary.versions.Count > 0)
{
    Console.WriteLine("Versiones:");
    foreach (var (name, n) in summary.versions)
        Console.WriteLine($"  {name,-45} {n,6}  {100.0 * n / all.Length,5:0.0} %  {new string('█', (int)Math.Round(40.0 * n / all.Length))}  errores={summary.versionErrors[name]}");
}
return 0;

internal sealed record Sample(int Status, double Ms, string? Instance, string? Version, double? RetryAfter);
