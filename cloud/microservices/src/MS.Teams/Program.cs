using Prometheus;
using TeamForMe.Shared;

// MS.Teams — equipos de cada evento y control de aforo.
// Guarda estado mutable (cupos ocupados) en memoria, por lo que se ejecuta con UNA réplica
// (escalado vertical). Para escalar horizontalmente habría que mover el estado a una base
// de datos compartida (ver microservices/docs/microservicios/ms-teams.md).
var builder = WebApplication.CreateBuilder(args);
builder.AddCloudDefaults("ms-teams");
builder.Services.AddSingleton<TeamStore>();

var app = builder.Build();
app.MapCloudDefaults();

app.MapGet("/events/{eventId}/teams", (string eventId, TeamStore store) =>
    Results.Ok(store.ByEvent(eventId).Select(TeamModel.FromState)));

app.MapGet("/teams/{teamId}", (string teamId, TeamStore store) =>
    store.Find(teamId) is { } team ? Results.Ok(TeamModel.FromState(team)) : Results.NotFound());

// --- API interna (servicio a servicio, protegida con X-Internal-Key desde Key Vault) ---
var internalApi = app.MapInternalGroup();

internalApi.MapPost("/teams/{teamId}/reserve", (string teamId, TeamStore store) => store.Reserve(teamId) switch
{
    ReserveResult.Reserved r => Results.Ok(r.Seat),
    ReserveResult.Full => Results.Conflict(new { error = "team_full", message = "Equipo lleno", teamId }),
    _ => Results.NotFound(),
});

internalApi.MapPost("/teams/{teamId}/release", (string teamId, TeamStore store) =>
    store.Release(teamId) ? Results.NoContent() : Results.NotFound());

app.Run();

public sealed record TeamMember(string UserId, string Initials, string AvatarColor);

/// <summary>Contrato público: igual al <c>TeamModel</c> del frontend.</summary>
public sealed record TeamModel(
    string Id, string EventId, string Name, string Tag,
    int Capacity, int Filled, bool IsPrivate, IReadOnlyList<TeamMember> Members)
{
    // Regla FR-009: un equipo privado nunca expone a sus integrantes.
    public static TeamModel FromState(TeamState s) =>
        new(s.Id, s.EventId, s.Name, s.Tag, s.Capacity, s.Filled, s.IsPrivate, s.IsPrivate ? [] : s.Members);
}

public sealed class TeamState
{
    public required string Id { get; init; }
    public required string EventId { get; init; }
    public required string Name { get; init; }
    public required string Tag { get; init; }
    public required int Capacity { get; init; }
    public int Filled { get; set; }
    public bool IsPrivate { get; init; }
    public IReadOnlyList<TeamMember> Members { get; init; } = [];
    /// <summary>Solo para demo: las postulaciones a este equipo siempre se rechazan.</summary>
    public bool AlwaysRejects { get; init; }
}

public sealed record SeatReservation(string TeamId, int Filled, int Capacity, bool AlwaysRejects);

public abstract record ReserveResult
{
    public sealed record Reserved(SeatReservation Seat) : ReserveResult;
    public sealed record Full : ReserveResult;
    public sealed record NotFound : ReserveResult;
}

public sealed class TeamStore
{
    private static readonly Gauge SeatsFilled = Metrics.CreateGauge(
        "teamforme_team_seats_filled", "Cupos ocupados por equipo.", "team_id", "event_id");
    private static readonly Gauge SeatsCapacity = Metrics.CreateGauge(
        "teamforme_team_seats_capacity", "Cupos totales por equipo.", "team_id", "event_id");

    private readonly Lock _gate = new();
    private readonly Dictionary<string, TeamState> _teams;

    public TeamStore()
    {
        _teams = Seed().ToDictionary(t => t.Id);
        foreach (var t in _teams.Values)
        {
            Publish(t);
        }
    }

    public IReadOnlyList<TeamState> ByEvent(string eventId)
    {
        lock (_gate)
        {
            return _teams.Values.Where(t => t.EventId == eventId).ToList();
        }
    }

    public TeamState? Find(string id)
    {
        lock (_gate)
        {
            return _teams.GetValueOrDefault(id);
        }
    }

    /// <summary>Reserva atómica: <c>filled</c> nunca supera <c>capacity</c> (FR-014 / SC-009).</summary>
    public ReserveResult Reserve(string id)
    {
        lock (_gate)
        {
            if (!_teams.TryGetValue(id, out var team))
            {
                return new ReserveResult.NotFound();
            }
            if (team.Filled >= team.Capacity)
            {
                return new ReserveResult.Full();
            }
            team.Filled++;
            Publish(team);
            return new ReserveResult.Reserved(new SeatReservation(team.Id, team.Filled, team.Capacity, team.AlwaysRejects));
        }
    }

    /// <summary>Libera el cupo cuando una postulación termina rechazada.</summary>
    public bool Release(string id)
    {
        lock (_gate)
        {
            if (!_teams.TryGetValue(id, out var team))
            {
                return false;
            }
            team.Filled = Math.Max(0, team.Filled - 1);
            Publish(team);
            return true;
        }
    }

    private static void Publish(TeamState t)
    {
        SeatsFilled.WithLabels(t.Id, t.EventId).Set(t.Filled);
        SeatsCapacity.WithLabels(t.Id, t.EventId).Set(t.Capacity);
    }

    /// <summary>Datos semilla equivalentes a <c>teams.mock.ts</c> del frontend.</summary>
    private static IEnumerable<TeamState> Seed() =>
    [
        new() { Id = "team-cloud-cats", EventId = "evt-hackcloud-2026", Name = "Cloud Cats", Tag = "Backend Cloud",
            Capacity = 5, Filled = 3,
            Members = [new("u-2", "ML", "#7C5CFF"), new("u-3", "JR", "#2DDDA6"), new("u-4", "AC", "#F5B14C")] },
        new() { Id = "team-pixel-forge", EventId = "evt-hackcloud-2026", Name = "Pixel Forge", Tag = "Diseño UX/UI",
            Capacity = 4, Filled = 4,
            Members = [new("u-5", "SD", "#FF5D72"), new("u-6", "KP", "#7C5CFF"), new("u-7", "BN", "#2DDDA6"), new("u-8", "TQ", "#F5B14C")] },
        new() { Id = "team-stealth", EventId = "evt-hackcloud-2026", Name = "Stealth Startup", Tag = "Producto",
            Capacity = 6, Filled = 2, IsPrivate = true },
        new() { Id = "team-hard-pass", EventId = "evt-hackcloud-2026", Name = "Hard Pass", Tag = "Machine Learning",
            Capacity = 5, Filled = 1, AlwaysRejects = true,
            Members = [new("u-9", "RV", "#5B3FE0")] },
        new() { Id = "team-open-data", EventId = "evt-datathon-med", Name = "Open Data Collective", Tag = "Data Engineering",
            Capacity = 5, Filled = 2,
            Members = [new("u-10", "FG", "#2DDDA6"), new("u-11", "LM", "#F5B14C")] },
    ];
}
