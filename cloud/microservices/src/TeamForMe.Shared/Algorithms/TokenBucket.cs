namespace TeamForMe.Shared.Algorithms;

/// <summary>
/// Algoritmo <b>Token Bucket</b> (cubeta de fichas) para limitar la tasa de peticiones.
/// <para>
/// La cubeta tiene una capacidad máxima <c>C</c> (la ráfaga permitida) y se rellena de forma
/// continua a razón de <c>r</c> fichas por segundo. Cada petición consume una ficha; si no hay
/// fichas, la petición se rechaza (HTTP 429) y se informa cuándo habrá una disponible.
/// </para>
/// <code>
///   tokens(t) = min(C, tokens(t0) + r · (t − t0))      // relleno perezoso al consultar
///   permitir  ⇔ tokens(t) ≥ costo
///   retryAfter = (costo − tokens(t)) / r                // si se rechaza
/// </code>
/// Complejidad O(1) en tiempo y memoria por cliente: no guarda historial de peticiones,
/// solo dos números (fichas y último relleno).
/// </summary>
public sealed class TokenBucket
{
    private readonly object _gate = new();
    private readonly TimeProvider _clock;
    private double _tokens;
    private long _lastRefillTimestamp;

    public TokenBucket(double capacity, double refillPerSecond, TimeProvider? clock = null)
    {
        ArgumentOutOfRangeException.ThrowIfNegativeOrZero(capacity);
        ArgumentOutOfRangeException.ThrowIfNegativeOrZero(refillPerSecond);
        Capacity = capacity;
        RefillPerSecond = refillPerSecond;
        _clock = clock ?? TimeProvider.System;
        _tokens = capacity; // empieza llena: se permite una ráfaga inicial de C peticiones
        _lastRefillTimestamp = _clock.GetTimestamp();
    }

    public double Capacity { get; }
    public double RefillPerSecond { get; }

    /// <summary>Último instante en que se usó la cubeta (para liberar las inactivas).</summary>
    public long LastUsedTimestamp => Volatile.Read(ref _lastRefillTimestamp);

    /// <summary>Intenta consumir <paramref name="cost"/> fichas.</summary>
    public TokenBucketResult TryTake(double cost = 1)
    {
        lock (_gate)
        {
            Refill();
            if (_tokens >= cost)
            {
                _tokens -= cost;
                return new TokenBucketResult(true, _tokens, TimeSpan.Zero);
            }

            var missing = cost - _tokens;
            var retryAfter = TimeSpan.FromSeconds(missing / RefillPerSecond);
            return new TokenBucketResult(false, _tokens, retryAfter);
        }
    }

    /// <summary>Fichas disponibles en este instante (aplica el relleno pendiente).</summary>
    public double Available
    {
        get
        {
            lock (_gate)
            {
                Refill();
                return _tokens;
            }
        }
    }

    private void Refill()
    {
        var now = _clock.GetTimestamp();
        var elapsed = _clock.GetElapsedTime(_lastRefillTimestamp, now).TotalSeconds;
        if (elapsed > 0)
        {
            _tokens = Math.Min(Capacity, _tokens + elapsed * RefillPerSecond);
            _lastRefillTimestamp = now;
        }
    }
}

public readonly record struct TokenBucketResult(bool Allowed, double Remaining, TimeSpan RetryAfter);
