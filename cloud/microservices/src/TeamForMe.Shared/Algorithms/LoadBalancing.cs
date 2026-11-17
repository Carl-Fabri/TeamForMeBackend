namespace TeamForMe.Shared.Algorithms;

/// <summary>Réplica / servidor de destino al que un balanceador puede enviar tráfico.</summary>
public sealed class Backend(string name, int weight = 1)
{
    private int _active;

    public string Name { get; } = name;

    /// <summary>Peso relativo (capacidad). Una réplica con peso 3 debe recibir ~3× tráfico.</summary>
    public int Weight { get; } = weight > 0 ? weight : throw new ArgumentOutOfRangeException(nameof(weight));

    /// <summary>Conexiones / peticiones en curso (lo que mira Least Connections).</summary>
    public int ActiveConnections => Volatile.Read(ref _active);

    internal void Acquire() => Interlocked.Increment(ref _active);
    internal void Release() => Interlocked.Decrement(ref _active);
}

/// <summary>Reserva de un backend: al liberarla se descuenta la conexión activa.</summary>
public readonly struct BackendLease(Backend backend) : IDisposable
{
    public Backend Backend { get; } = backend;
    public void Dispose() => Backend.Release();
}

/// <summary>
/// Base de los algoritmos de balanceo de carga. <see cref="Select"/> elige el destino y
/// <see cref="Acquire"/> además contabiliza la conexión hasta que se libera el lease.
/// </summary>
public abstract class LoadBalancer
{
    protected LoadBalancer(IReadOnlyList<Backend> backends)
    {
        if (backends.Count == 0) throw new ArgumentException("Se necesita al menos un backend.", nameof(backends));
        Backends = backends;
    }

    public IReadOnlyList<Backend> Backends { get; }
    public abstract string Name { get; }
    public abstract Backend Select();

    public BackendLease Acquire()
    {
        var backend = Select();
        backend.Acquire();
        return new BackendLease(backend);
    }

    public static LoadBalancer Create(string strategy, IReadOnlyList<Backend> backends) => strategy.ToLowerInvariant() switch
    {
        "round-robin" or "rr" => new RoundRobinBalancer(backends),
        "weighted" or "weighted-round-robin" or "wrr" => new SmoothWeightedRoundRobinBalancer(backends),
        "least-connections" or "lc" => new LeastConnectionsBalancer(backends),
        "p2c" or "power-of-two" => new PowerOfTwoChoicesBalancer(backends),
        _ => throw new ArgumentException($"Estrategia desconocida: {strategy}", nameof(strategy)),
    };

    public static readonly string[] Strategies = ["round-robin", "weighted", "least-connections", "p2c"];
}

/// <summary>
/// <b>Round Robin</b>: recorre los backends en orden circular, i = (contador++) mod n.
/// Es el algoritmo que usa Envoy en Azure Container Apps entre réplicas de una revisión.
/// O(1), sin estado salvo un contador atómico. Ignora capacidad y carga actual.
/// </summary>
public sealed class RoundRobinBalancer(IReadOnlyList<Backend> backends) : LoadBalancer(backends)
{
    private uint _next = uint.MaxValue;
    public override string Name => "round-robin";

    public override Backend Select()
    {
        var i = Interlocked.Increment(ref _next);
        return Backends[(int)(i % (uint)Backends.Count)];
    }
}

/// <summary>
/// <b>Smooth Weighted Round Robin</b> (el algoritmo de nginx). En cada elección:
/// <code>
///   para cada i: actual[i] += peso[i]
///   elegido = argmax(actual)
///   actual[elegido] -= Σ pesos
/// </code>
/// Respeta los pesos (5:1:1 → 5/7, 1/7, 1/7) y además los intercala: con pesos {5,1,1}
/// produce a a b a c a a en lugar de a a a a a b c, evitando ráfagas sobre un solo nodo.
/// Es el mismo principio que el reparto de tráfico por pesos entre revisiones (canary).
/// </summary>
public sealed class SmoothWeightedRoundRobinBalancer : LoadBalancer
{
    private readonly object _gate = new();
    private readonly int[] _current;
    private readonly int _totalWeight;

    public SmoothWeightedRoundRobinBalancer(IReadOnlyList<Backend> backends) : base(backends)
    {
        _current = new int[backends.Count];
        _totalWeight = backends.Sum(b => b.Weight);
    }

    public override string Name => "weighted";

    public override Backend Select()
    {
        lock (_gate)
        {
            var best = 0;
            for (var i = 0; i < Backends.Count; i++)
            {
                _current[i] += Backends[i].Weight;
                if (_current[i] > _current[best]) best = i;
            }
            _current[best] -= _totalWeight;
            return Backends[best];
        }
    }
}

/// <summary>
/// <b>Least Connections (ponderado)</b>: envía al backend con menor carga relativa
/// activas / peso. Se adapta a peticiones de duración desigual: un backend lento acumula
/// conexiones y deja de recibir tráfico nuevo. Los empates se rompen en orden circular
/// para no sesgar siempre hacia el primero. O(n) por elección.
/// </summary>
public sealed class LeastConnectionsBalancer(IReadOnlyList<Backend> backends) : LoadBalancer(backends)
{
    private uint _offset;
    public override string Name => "least-connections";

    public override Backend Select()
    {
        var n = Backends.Count;
        var start = (int)(Interlocked.Increment(ref _offset) % (uint)n);
        Backend best = Backends[start];
        var bestLoad = Load(best);
        for (var k = 1; k < n; k++)
        {
            var candidate = Backends[(start + k) % n];
            var load = Load(candidate);
            if (load < bestLoad)
            {
                best = candidate;
                bestLoad = load;
            }
        }
        return best;
    }

    private static double Load(Backend b) => (double)b.ActiveConnections / b.Weight;
}

/// <summary>
/// <b>Power of Two Choices (P2C)</b>: elige dos backends al azar y se queda con el menos
/// cargado. Con O(1) por elección logra casi el mismo equilibrio que Least Connections y
/// evita el "efecto manada" de que todos los balanceadores elijan a la vez el mismo nodo
/// vacío. Lo usan Envoy (LEAST_REQUEST), Linkerd y gRPC.
/// </summary>
public sealed class PowerOfTwoChoicesBalancer(IReadOnlyList<Backend> backends, Random? random = null) : LoadBalancer(backends)
{
    private readonly Random _random = random ?? Random.Shared;
    public override string Name => "p2c";

    public override Backend Select()
    {
        var n = Backends.Count;
        if (n == 1) return Backends[0];
        var a = _random.Next(n);
        var b = _random.Next(n - 1);
        if (b >= a) b++; // dos índices distintos
        var x = Backends[a];
        var y = Backends[b];
        return (double)x.ActiveConnections / x.Weight <= (double)y.ActiveConnections / y.Weight ? x : y;
    }
}
