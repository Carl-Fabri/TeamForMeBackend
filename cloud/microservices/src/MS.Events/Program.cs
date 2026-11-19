using TeamForMe.Shared;

// MS.Events — catálogo de eventos e ideas en búsqueda de grupo.
// Servicio de solo lectura y sin estado mutable: cada réplica es idéntica, por eso es el
// candidato ideal para escalado horizontal automático (HPA en Kubernetes / reglas HTTP en
// Container Apps).
var builder = WebApplication.CreateBuilder(args);
builder.AddCloudDefaults("ms-events");
builder.Services.AddInfrastructureLab();

var app = builder.Build();
app.MapCloudDefaults();
app.MapInfrastructureLab(); // /lab/*: algoritmos de infraestructura (InfrastructureLab.cs)

app.MapGet("/events", () => Results.Ok(EventCatalog.All))
    .WithTags("Eventos")
    .WithSummary("Listar eventos")
    .WithDescription("Devuelve todos los eventos e ideas en búsqueda de grupo.")
    .Produces<IReadOnlyList<EventModel>>();

app.MapGet("/events/{id}", (string id) =>
    EventCatalog.All.FirstOrDefault(e => e.Id == id) is { } found
        ? Results.Ok(found)
        : Results.NotFound())
    .WithTags("Eventos")
    .WithSummary("Obtener un evento")
    .WithDescription("Detalle de un evento. Si no tiene coordenadas, `coords` es null (evento remoto).")
    .Produces<EventModel>()
    .Produces(StatusCodes.Status404NotFound);

app.Run();

public sealed record Coords(double Lat, double Lng);

public sealed record EventModel(
    string Id,
    string Name,
    string Date,
    string Location,
    Coords? Coords,
    string? Description,
    string? ThemeGradient = null);

/// <summary>Datos semilla equivalentes a <c>events.mock.ts</c> del frontend.</summary>
public static class EventCatalog
{
    public static readonly IReadOnlyList<EventModel> All =
    [
        new("evt-hackcloud-2026", "HackCloud 2026", "2026-09-19T09:00:00-05:00", "Bogotá, Colombia",
            new Coords(4.6533, -74.0836),
            "Cuarenta y ocho horas construyendo soluciones cloud-native con equipos multidisciplinarios.",
            "radial-gradient(circle at 20% 0%, var(--violet-soft), transparent 60%)"),
        new("evt-datathon-med", "Datathon Medellín", "2026-10-03T08:30:00-05:00", "Medellín, Colombia",
            new Coords(6.2447, -75.5748),
            "Reto de datos abiertos para movilidad urbana."),
        new("evt-ux-online", "UX Sprint Online", "2026-11-14T13:00:00Z", "Evento remoto",
            null,
            "Sprint de diseño de producto completamente en línea."),
    ];
}
