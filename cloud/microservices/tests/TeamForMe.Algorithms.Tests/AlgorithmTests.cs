using Microsoft.Extensions.Time.Testing;
using TeamForMe.Shared.Algorithms;
using Xunit;

namespace TeamForMe.Algorithms.Tests;

public class TokenBucketTests
{
    [Fact]
    public void Permite_la_rafaga_y_rechaza_al_agotarse()
    {
        var clock = new FakeTimeProvider();
        var bucket = new TokenBucket(capacity: 5, refillPerSecond: 1, clock);

        for (var i = 0; i < 5; i++) Assert.True(bucket.TryTake().Allowed);

        var rejected = bucket.TryTake();
        Assert.False(rejected.Allowed);
        Assert.Equal(1, rejected.RetryAfter.TotalSeconds, precision: 3);
    }

    [Fact]
    public void Se_rellena_con_el_tiempo_sin_superar_la_capacidad()
    {
        var clock = new FakeTimeProvider();
        var bucket = new TokenBucket(capacity: 10, refillPerSecond: 2, clock);
        for (var i = 0; i < 10; i++) bucket.TryTake();

        clock.Advance(TimeSpan.FromSeconds(2));
        Assert.Equal(4, bucket.Available, precision: 3);

        clock.Advance(TimeSpan.FromMinutes(1));
        Assert.Equal(10, bucket.Available, precision: 3);
    }
}

public class LoadBalancerTests
{
    private static Backend[] Make(params int[] weights) =>
        weights.Select((w, i) => new Backend(((char)('a' + i)).ToString(), w)).ToArray();

    [Fact]
    public void RoundRobin_recorre_en_orden_circular()
    {
        var lb = new RoundRobinBalancer(Make(1, 1, 1));
        var picks = string.Concat(Enumerable.Range(0, 6).Select(_ => lb.Select().Name));
        Assert.Equal("abcabc", picks);
    }

    [Fact]
    public void WeightedRoundRobin_respeta_pesos_e_intercala()
    {
        var lb = new SmoothWeightedRoundRobinBalancer(Make(5, 1, 1));
        var picks = string.Concat(Enumerable.Range(0, 7).Select(_ => lb.Select().Name));
        Assert.Equal("aabacaa", picks);
    }

    [Fact]
    public void LeastConnections_evita_el_backend_ocupado()
    {
        var backends = Make(1, 1);
        var lb = new LeastConnectionsBalancer(backends);
        backends[0].Acquire();
        backends[0].Acquire(); // "a" con 2 peticiones en curso, "b" libre

        for (var i = 0; i < 4; i++) Assert.Equal("b", lb.Select().Name);

        using (lb.Acquire()) Assert.Equal(1, backends[1].ActiveConnections);
        Assert.Equal(0, backends[1].ActiveConnections); // el lease libera la conexión
    }

    [Fact]
    public void Simulacion_round_robin_degrada_con_replicas_heterogeneas()
    {
        var rr = LoadBalancingSimulator.Run("round-robin", 3000, 80);
        var weighted = LoadBalancingSimulator.Run("weighted", 3000, 80);
        var lc = LoadBalancingSimulator.Run("least-connections", 3000, 80);

        // La réplica lenta (capacidad 16,7 rps) recibe 26,7 rps con RR: su cola crece sin límite.
        Assert.True(rr.P95LatencyMs > 10 * weighted.P95LatencyMs);
        Assert.True(lc.P95LatencyMs < rr.P95LatencyMs);
        Assert.Equal(50, weighted.Backends[0].SharePercent, precision: 0);
    }
}

public class HorizontalAutoscalerTests
{
    private static readonly DateTimeOffset T0 = DateTimeOffset.UnixEpoch;

    [Theory]
    [InlineData(2, 90, 3)]   // 90 concurrentes / 30 = 3 réplicas
    [InlineData(3, 200, 7)]  // ⌈3 · (66,7/30)⌉ = ⌈6,67⌉ = 7
    [InlineData(4, 125, 4)]  // ratio 1,04 dentro de la tolerancia del 10 %
    public void Calcula_replicas_deseadas_con_la_formula_del_HPA(int current, double load, int expected)
    {
        var hpa = new HorizontalAutoscaler(new AutoscalerOptions { TargetPerReplica = 30, MaxReplicas = 20 });
        Assert.Equal(expected, hpa.Evaluate(T0, current, load).FinalReplicas);
    }

    [Fact]
    public void Escala_desde_cero_y_respeta_el_maximo()
    {
        var hpa = new HorizontalAutoscaler(new AutoscalerOptions { TargetPerReplica = 30, MaxReplicas = 5 });
        Assert.Equal(5, hpa.Evaluate(T0, 0, 1000).FinalReplicas);
    }

    [Fact]
    public void Politica_de_subida_limita_el_crecimiento_por_paso()
    {
        var hpa = new HorizontalAutoscaler(new AutoscalerOptions { TargetPerReplica = 10, MaxReplicas = 100 });
        // 1 réplica con 200 concurrentes pediría 20; la política permite máx(1+4, 1·2) = 5.
        Assert.Equal(5, hpa.Evaluate(T0, 1, 200).FinalReplicas);
    }

    [Fact]
    public void Estabilizacion_retrasa_la_bajada_cinco_minutos()
    {
        var o = new AutoscalerOptions { TargetPerReplica = 30, MinReplicas = 0, MaxReplicas = 10 };
        var hpa = new HorizontalAutoscaler(o);
        Assert.Equal(5, hpa.Evaluate(T0, 0, 150).FinalReplicas);

        // El tráfico cae a cero: durante la ventana se mantienen 5 réplicas.
        Assert.Equal(5, hpa.Evaluate(T0.AddMinutes(1), 5, 0).FinalReplicas);
        Assert.Equal(5, hpa.Evaluate(T0.AddMinutes(4), 5, 0).FinalReplicas);
        // Pasada la ventana, la recomendación alta caduca y se escala a cero.
        Assert.Equal(0, hpa.Evaluate(T0.AddMinutes(10), 5, 0).FinalReplicas);
    }
}
