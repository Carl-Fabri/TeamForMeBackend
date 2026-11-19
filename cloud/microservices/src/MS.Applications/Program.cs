using System.Collections.Concurrent;
using System.Net;
using System.Net.Mail;
using Prometheus;
using TeamForMe.Shared;

// MS.Applications — postulaciones a equipos y su resolución asíncrona.
// Flujo: POST → reserva cupo en MS.Teams → registro "pending" → tras N segundos un worker
// la resuelve (accepted / rejected) → avisa a MS.Notifications y, si se rechaza, libera el cupo.
var builder = WebApplication.CreateBuilder(args);
builder.AddCloudDefaults("ms-applications");

builder.Services.AddSingleton<ApplicationStore>();
builder.Services.AddHostedService<ApplicationResolver>();

// Clientes HTTP con resiliencia (TeamForMe.Shared/Resilience.cs): timeouts, reintentos con
// backoff exponencial + jitter y circuit breaker. Los reintentos se desactivan para POST
// porque no son idempotentes.
builder.Services.AddHttpClient<TeamsClient>((sp, client) =>
    {
        var config = sp.GetRequiredService<IConfiguration>();
        client.BaseAddress = new Uri(config["Services:Teams"] ?? "http://ms-teams:8080");
        InternalApiKey.AttachInternalKey(client, config);
    })
    .AddTeamForMeResilience("ms-teams");

builder.Services.AddHttpClient<NotificationsClient>((sp, client) =>
    {
        var config = sp.GetRequiredService<IConfiguration>();
        client.BaseAddress = new Uri(config["Services:Notifications"] ?? "http://ms-notifications:8080");
        InternalApiKey.AttachInternalKey(client, config);
    })
    .AddTeamForMeResilience("ms-notifications");

var app = builder.Build();
app.MapCloudDefaults();

app.MapPost("/applications", (CreateApplicationInput input, HttpRequest req, TeamsClient teams, ApplicationStore store, CancellationToken ct) =>
    ApplicationEndpoints.Create(input, req, teams, store, ct))
    .WithTags("Postulaciones")
    .WithSummary("Crear una postulación")
    .WithDescription("Reserva un cupo en el equipo `teamId` y crea la postulación en estado `pending`. Usuario: cabecera X-User-Id (por defecto u-1).")
    .Produces<ApplicationModel>(StatusCodes.Status201Created)
    .ProducesValidationProblem()
    .Produces(StatusCodes.Status404NotFound)
    .Produces(StatusCodes.Status409Conflict);

app.MapPost("/teams/{teamId}/applications", (string teamId, CreateApplicationInput input, HttpRequest req, TeamsClient teams, ApplicationStore store, CancellationToken ct) =>
    ApplicationEndpoints.Create(input with { TeamId = teamId }, req, teams, store, ct))
    .WithTags("Postulaciones")
    .WithSummary("Postularse a un equipo")
    .WithDescription("Igual que `POST /applications`, con el equipo en la ruta. 409 `team_full` si no quedan cupos; a los segundos pasa a `accepted` o `rejected`.")
    .Produces<ApplicationModel>(StatusCodes.Status201Created)
    .ProducesValidationProblem()
    .Produces(StatusCodes.Status404NotFound)
    .Produces(StatusCodes.Status409Conflict);

app.MapGet("/applications/{id}", (string id, ApplicationStore store) =>
    store.Find(id) is { } found ? Results.Ok(found) : Results.NotFound())
    .WithTags("Postulaciones")
    .WithSummary("Estado de una postulación")
    .WithDescription("Consultar periódicamente (polling) hasta que `status` deje de ser `pending`.")
    .Produces<ApplicationModel>()
    .Produces(StatusCodes.Status404NotFound);

app.Run();

public sealed record CreateApplicationInput(string TeamId, string FullName, string Email, string Role, string Motivation);

public sealed record ApplicationModel(
    string Id, string TeamId, string UserId, string FullName, string Email,
    string Role, string Motivation, string Status, string CreatedAt);

public static class ApplicationEndpoints
{
    private static readonly Counter Created = Metrics.CreateCounter(
        "teamforme_applications_created_total", "Postulaciones creadas.", "team_id");
    private static readonly Counter RejectedFull = Metrics.CreateCounter(
        "teamforme_applications_team_full_total", "Postulaciones rechazadas al instante por equipo lleno.", "team_id");

    public static async Task<IResult> Create(
        CreateApplicationInput input, HttpRequest req, TeamsClient teams, ApplicationStore store, CancellationToken ct)
    {
        var errors = Validate(input);
        if (errors.Count > 0)
        {
            return Results.ValidationProblem(errors);
        }

        var seat = await teams.ReserveAsync(input.TeamId, ct);
        switch (seat.Outcome)
        {
            case ReserveOutcome.NotFound:
                return Results.NotFound(new { error = "team_not_found", teamId = input.TeamId });
            case ReserveOutcome.Full:
                RejectedFull.WithLabels(input.TeamId).Inc();
                return Results.Conflict(new { error = "team_full", message = "Equipo lleno", teamId = input.TeamId });
        }

        var userId = req.Headers["X-User-Id"].FirstOrDefault() ?? "u-1";
        var created = store.Add(input, userId, seat.AlwaysRejects);
        Created.WithLabels(input.TeamId).Inc();
        return Results.Created($"/applications/{created.Id}", created);
    }

    private static Dictionary<string, string[]> Validate(CreateApplicationInput i)
    {
        var errors = new Dictionary<string, string[]>();
        void Require(string field, string? value)
        {
            if (string.IsNullOrWhiteSpace(value)) errors[field] = ["Campo obligatorio."];
        }
        Require("teamId", i.TeamId);
        Require("fullName", i.FullName);
        Require("email", i.Email);
        Require("role", i.Role);
        Require("motivation", i.Motivation);
        if (!errors.ContainsKey("email") && !MailAddress.TryCreate(i.Email, out _))
        {
            errors["email"] = ["Email inválido."];
        }
        return errors;
    }
}

public sealed class ApplicationStore
{
    private static readonly Gauge Pending = Metrics.CreateGauge(
        "teamforme_applications_pending", "Postulaciones pendientes de resolución (cola de trabajo).");

    private readonly ConcurrentDictionary<string, Entry> _entries = new();
    private readonly TimeSpan _resolveDelay;

    public ApplicationStore(IConfiguration config)
    {
        _resolveDelay = TimeSpan.FromSeconds(config.GetValue("Applications:ResolveDelaySeconds", 6));
    }

    public ApplicationModel Add(CreateApplicationInput input, string userId, bool alwaysRejects)
    {
        var model = new ApplicationModel(
            $"app-{Guid.NewGuid():N}"[..16], input.TeamId, userId, input.FullName.Trim(), input.Email.Trim(),
            input.Role.Trim(), input.Motivation.Trim(), "pending", DateTimeOffset.UtcNow.ToString("O"));
        _entries[model.Id] = new Entry(model, DateTimeOffset.UtcNow + _resolveDelay, alwaysRejects);
        Pending.Inc();
        return model;
    }

    public ApplicationModel? Find(string id) => _entries.TryGetValue(id, out var e) ? e.Model : null;

    public IReadOnlyList<Entry> DuePending(DateTimeOffset now) =>
        _entries.Values.Where(e => e.Model.Status == "pending" && e.DueAt <= now).ToList();

    /// <summary>Transición única pending → accepted|rejected; los estados finales no cambian.</summary>
    public bool TryResolve(Entry entry, string status)
    {
        var resolved = entry with { Model = entry.Model with { Status = status } };
        if (_entries.TryUpdate(entry.Model.Id, resolved, entry))
        {
            Pending.Dec();
            return true;
        }
        return false;
    }

    public sealed record Entry(ApplicationModel Model, DateTimeOffset DueAt, bool AlwaysRejects);
}

/// <summary>
/// Worker que simula el broker: cada segundo resuelve las postulaciones vencidas.
/// En producción se reemplazaría por una cola (Azure Service Bus / RabbitMQ) y el
/// número de workers escalaría según la longitud de la cola (KEDA).
/// </summary>
public sealed class ApplicationResolver(
    ApplicationStore store, IServiceScopeFactory scopes, ILogger<ApplicationResolver> logger) : BackgroundService
{
    private static readonly Counter Resolved = Metrics.CreateCounter(
        "teamforme_applications_resolved_total", "Postulaciones resueltas por estado.", "status");

    protected override async Task ExecuteAsync(CancellationToken stoppingToken)
    {
        using var timer = new PeriodicTimer(TimeSpan.FromSeconds(1));
        while (await timer.WaitForNextTickAsync(stoppingToken))
        {
            foreach (var entry in store.DuePending(DateTimeOffset.UtcNow))
            {
                // Regla determinista: los equipos marcados "alwaysRejects" rechazan; el resto acepta.
                var status = entry.AlwaysRejects ? "rejected" : "accepted";
                if (!store.TryResolve(entry, status))
                {
                    continue;
                }
                Resolved.WithLabels(status).Inc();
                await NotifyAsync(entry.Model with { Status = status }, stoppingToken);
            }
        }
    }

    private async Task NotifyAsync(ApplicationModel app, CancellationToken ct)
    {
        using var scope = scopes.CreateScope();
        try
        {
            await scope.ServiceProvider.GetRequiredService<NotificationsClient>().ApplicationResolvedAsync(app, ct);
            if (app.Status == "rejected")
            {
                await scope.ServiceProvider.GetRequiredService<TeamsClient>().ReleaseAsync(app.TeamId, ct);
            }
        }
        // Fallos de red, timeouts o circuito abierto: la postulación ya quedó resuelta,
        // solo se pierde el efecto secundario (se registra para observabilidad).
        catch (Exception ex) when (!ct.IsCancellationRequested)
        {
            logger.LogWarning(ex, "No se pudo propagar la resolución de {ApplicationId}", app.Id);
        }
    }
}

public enum ReserveOutcome { Reserved, Full, NotFound }

public sealed record SeatResult(ReserveOutcome Outcome, bool AlwaysRejects);

public sealed class TeamsClient(HttpClient http)
{
    private sealed record SeatReservation(string TeamId, int Filled, int Capacity, bool AlwaysRejects);

    public async Task<SeatResult> ReserveAsync(string teamId, CancellationToken ct)
    {
        using var res = await http.PostAsync($"/internal/teams/{Uri.EscapeDataString(teamId)}/reserve", null, ct);
        switch (res.StatusCode)
        {
            case HttpStatusCode.Conflict:
                return new SeatResult(ReserveOutcome.Full, false);
            case HttpStatusCode.NotFound:
                return new SeatResult(ReserveOutcome.NotFound, false);
        }
        res.EnsureSuccessStatusCode();
        var seat = await res.Content.ReadFromJsonAsync<SeatReservation>(ct);
        return new SeatResult(ReserveOutcome.Reserved, seat?.AlwaysRejects ?? false);
    }

    public async Task ReleaseAsync(string teamId, CancellationToken ct)
    {
        using var res = await http.PostAsync($"/internal/teams/{Uri.EscapeDataString(teamId)}/release", null, ct);
        res.EnsureSuccessStatusCode();
    }
}

public sealed class NotificationsClient(HttpClient http)
{
    public async Task ApplicationResolvedAsync(ApplicationModel app, CancellationToken ct)
    {
        using var res = await http.PostAsJsonAsync("/internal/notifications",
            new { userId = app.UserId, applicationId = app.Id, teamId = app.TeamId, status = app.Status }, ct);
        res.EnsureSuccessStatusCode();
    }
}
