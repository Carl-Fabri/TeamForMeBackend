namespace TeamForMe.Shared.Algorithms;

/// <summary>Parámetros del autoescalador (equivalentes a un HPA de Kubernetes / regla KEDA).</summary>
public sealed record AutoscalerOptions
{
    /// <summary>Valor objetivo de la métrica POR RÉPLICA (p. ej. 30 peticiones concurrentes).</summary>
    public double TargetPerReplica { get; init; } = 30;
    public int MinReplicas { get; init; } = 0;
    public int MaxReplicas { get; init; } = 10;

    /// <summary>Banda muerta: si |ratio − 1| ≤ tolerancia no se escala (evita oscilar). K8s: 0,1.</summary>
    public double Tolerance { get; init; } = 0.1;

    /// <summary>Ventana de estabilización al reducir. K8s: 300 s; Container Apps: 300 s de cooldown.</summary>
    public TimeSpan ScaleDownStabilization { get; init; } = TimeSpan.FromMinutes(5);

    /// <summary>Política de subida por evaluación: máx(+N réplicas, +P %). K8s: máx(4, 100 %).</summary>
    public int ScaleUpMaxPods { get; init; } = 4;
    public double ScaleUpMaxPercent { get; init; } = 100;
}

public sealed record ScalingDecision(
    DateTimeOffset At, int CurrentReplicas, double TotalMetric, double MetricPerReplica,
    int RawDesired, int StabilizedDesired, int FinalReplicas, string Reason);

/// <summary>
/// Algoritmo del <b>Horizontal Pod Autoscaler</b> de Kubernetes, el mismo que KEDA aplica
/// en Azure Container Apps para las reglas de escalado:
/// <code>
///   ratio    = métricaPorRéplica / objetivo
///   deseadas = ⌈ réplicasActuales · ratio ⌉   =   ⌈ métricaTotal / objetivo ⌉
///   si |ratio − 1| ≤ tolerancia  → no cambiar               (banda muerta)
///   subida   ≤ máx(actual + 4, actual · 2)                  (política de scale-up)
///   bajada   = máx(recomendaciones de los últimos 300 s)    (estabilización)
///   final    = clamp(deseadas, mín, máx)
/// </code>
/// Con mín = 0 se obtiene "scale to zero": sin tráfico no hay réplicas; la primera petición
/// activa 1 réplica (activación de KEDA) y desde ahí aplica la fórmula.
/// </summary>
public sealed class HorizontalAutoscaler(AutoscalerOptions options)
{
    private readonly Queue<(DateTimeOffset At, int Desired)> _recommendations = new();

    public AutoscalerOptions Options { get; } = options;

    public ScalingDecision Evaluate(DateTimeOffset now, int currentReplicas, double totalMetric)
    {
        var o = Options;
        int raw;
        string reason;

        if (currentReplicas == 0)
        {
            // Activación: de 0 a N en cuanto hay métrica (KEDA "activation").
            raw = totalMetric > 0 ? (int)Math.Ceiling(totalMetric / o.TargetPerReplica) : 0;
            reason = totalMetric > 0 ? "activación desde cero" : "sin tráfico (escalado a cero)";
        }
        else
        {
            var perReplica = totalMetric / currentReplicas;
            var ratio = perReplica / o.TargetPerReplica;
            if (Math.Abs(ratio - 1) <= o.Tolerance)
            {
                raw = currentReplicas;
                reason = $"dentro de la tolerancia (ratio {ratio:0.00})";
            }
            else
            {
                raw = (int)Math.Ceiling(currentReplicas * ratio);
                reason = $"ratio {ratio:0.00} → ⌈{currentReplicas}·{ratio:0.00}⌉ = {raw}";
            }
        }

        // Estabilización de bajada: se recuerda cada recomendación y, al reducir, se toma la
        // MAYOR de la ventana. Así un valle momentáneo de tráfico no elimina réplicas.
        _recommendations.Enqueue((now, raw));
        while (_recommendations.Count > 0 && now - _recommendations.Peek().At > o.ScaleDownStabilization)
        {
            _recommendations.Dequeue();
        }

        var stabilized = raw;
        if (raw < currentReplicas)
        {
            stabilized = Math.Min(currentReplicas, _recommendations.Max(r => r.Desired));
            if (stabilized > raw) reason += $"; estabilización retiene {stabilized}";
        }

        // Política de subida: no crecer más de lo permitido por evaluación.
        if (stabilized > currentReplicas && currentReplicas > 0)
        {
            var limit = Math.Max(currentReplicas + o.ScaleUpMaxPods,
                (int)Math.Ceiling(currentReplicas * (1 + o.ScaleUpMaxPercent / 100)));
            if (stabilized > limit)
            {
                reason += $"; política de subida limita a {limit}";
                stabilized = limit;
            }
        }

        var final = Math.Clamp(stabilized, o.MinReplicas, o.MaxReplicas);
        if (final != stabilized) reason += $"; acotado a [{o.MinReplicas}, {o.MaxReplicas}]";

        return new ScalingDecision(now, currentReplicas, totalMetric,
            currentReplicas == 0 ? totalMetric : Math.Round(totalMetric / currentReplicas, 1),
            raw, stabilized, final, reason);
    }

    /// <summary>
    /// Ejecuta el autoescalador sobre un perfil de carga (peticiones concurrentes en el tiempo)
    /// evaluando cada <paramref name="interval"/> (KEDA en Container Apps: 30 s; HPA: 15 s).
    /// </summary>
    public static IReadOnlyList<ScalingDecision> Simulate(
        AutoscalerOptions options, IReadOnlyList<double> concurrentLoad, TimeSpan interval, int initialReplicas = 0)
    {
        var autoscaler = new HorizontalAutoscaler(options);
        var t0 = DateTimeOffset.UnixEpoch;
        var replicas = initialReplicas;
        var timeline = new List<ScalingDecision>(concurrentLoad.Count);
        for (var step = 0; step < concurrentLoad.Count; step++)
        {
            var decision = autoscaler.Evaluate(t0 + interval * step, replicas, concurrentLoad[step]);
            timeline.Add(decision);
            replicas = decision.FinalReplicas;
        }
        return timeline;
    }

    /// <summary>Perfiles de carga de ejemplo, un valor por intervalo de evaluación.</summary>
    public static IReadOnlyList<double> Profile(string name) => name.ToLowerInvariant() switch
    {
        // Pico súbito: reposo, salto a 150 concurrentes, meseta, caída y reposo.
        "spike" => [0, 0, 150, 150, 150, 150, 150, 150, 40, 40, 10, 10, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0],
        // Rampa gradual de subida y bajada.
        "ramp" => [0, 10, 25, 40, 60, 80, 100, 120, 140, 160, 140, 120, 100, 80, 60, 40, 25, 10, 0, 0, 0, 0, 0, 0],
        // Tráfico ruidoso alrededor del objetivo: la tolerancia y la estabilización evitan oscilar.
        "noisy" => [60, 64, 57, 62, 58, 66, 55, 61, 63, 30, 62, 59, 64, 56, 61, 60, 58, 63, 57, 62, 0, 0, 0, 0],
        _ => throw new ArgumentException($"Perfil desconocido: {name} (spike, ramp, noisy)"),
    };
}
