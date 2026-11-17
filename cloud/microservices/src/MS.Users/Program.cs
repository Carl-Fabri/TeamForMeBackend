using TeamForMe.Shared;

// MS.Users — perfiles de participantes. Sin autenticación en esta fase: el "usuario actual"
// se toma de la cabecera X-User-Id o, por defecto, del participante simulado u-1.
var builder = WebApplication.CreateBuilder(args);
builder.AddCloudDefaults("ms-users");

var app = builder.Build();
app.MapCloudDefaults();

app.MapGet("/users/me", (HttpRequest request) =>
{
    var id = request.Headers["X-User-Id"].FirstOrDefault() ?? UserDirectory.CurrentUserId;
    return UserDirectory.Find(id) is { } user ? Results.Ok(user) : Results.NotFound();
});

app.MapGet("/users/{id}", (string id) =>
    UserDirectory.Find(id) is { } user ? Results.Ok(user) : Results.NotFound());

app.Run();

public sealed record UserModel(string Id, string FullName, string Email, string AvatarColor);

/// <summary>Datos semilla equivalentes a <c>users.mock.ts</c> del frontend.</summary>
public static class UserDirectory
{
    public const string CurrentUserId = "u-1";

    private static readonly IReadOnlyList<UserModel> All =
    [
        new("u-1", "Ana Participante", "ana@example.com", "#7C5CFF"),
        new("u-2", "Mateo López", "mateo@example.com", "#2DDDA6"),
        new("u-3", "Julia Ramírez", "julia@example.com", "#F5B14C"),
    ];

    public static UserModel? Find(string id) => All.FirstOrDefault(u => u.Id == id);
}
