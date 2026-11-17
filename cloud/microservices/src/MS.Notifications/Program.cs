using System.Collections.Concurrent;
using Prometheus;
using TeamForMe.Shared;

// MS.Notifications — avisos al participante cuando su postulación se resuelve.
// Recibe eventos internos de MS.Applications y los expone por usuario.
var builder = WebApplication.CreateBuilder(args);
builder.AddCloudDefaults("ms-notifications");
builder.Services.AddSingleton<NotificationStore>();

var app = builder.Build();
app.MapCloudDefaults();

app.MapGet("/users/{userId}/notifications", (string userId, NotificationStore store) =>
    Results.Ok(store.ForUser(userId)));

var internalApi = app.MapInternalGroup();

internalApi.MapPost("/notifications", (ApplicationResolvedEvent evt, NotificationStore store) =>
{
    var created = store.Add(evt);
    return Results.Created($"/users/{created.UserId}/notifications", created);
});

app.Run();

public sealed record ApplicationResolvedEvent(string UserId, string ApplicationId, string TeamId, string Status);

public sealed record NotificationModel(string Id, string UserId, string Type, string Message, string CreatedAt);

public sealed class NotificationStore
{
    private static readonly Counter Sent = Metrics.CreateCounter(
        "teamforme_notifications_created_total", "Notificaciones generadas por tipo.", "type");

    private readonly ConcurrentDictionary<string, ConcurrentQueue<NotificationModel>> _byUser = new();

    public NotificationModel Add(ApplicationResolvedEvent evt)
    {
        var (type, message) = evt.Status switch
        {
            "accepted" => ("application_accepted", $"¡Tu postulación al equipo {evt.TeamId} fue aceptada!"),
            "rejected" => ("application_rejected", $"Tu postulación al equipo {evt.TeamId} no fue aceptada esta vez."),
            _ => ("application_pending", $"Tu postulación al equipo {evt.TeamId} está pendiente."),
        };
        var model = new NotificationModel(
            $"ntf-{Guid.NewGuid():N}"[..16], evt.UserId, type, message, DateTimeOffset.UtcNow.ToString("O"));
        _byUser.GetOrAdd(evt.UserId, _ => new()).Enqueue(model);
        Sent.WithLabels(type).Inc();
        return model;
    }

    public IReadOnlyList<NotificationModel> ForUser(string userId) =>
        _byUser.TryGetValue(userId, out var queue) ? queue.Reverse().ToList() : [];
}
