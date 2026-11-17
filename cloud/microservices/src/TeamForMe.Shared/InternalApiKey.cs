using Microsoft.AspNetCore.Builder;
using Microsoft.AspNetCore.Http;
using Microsoft.AspNetCore.Routing;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.DependencyInjection;

namespace TeamForMe.Shared;

/// <summary>
/// Protección de los endpoints <c>/internal/*</c> (llamadas servicio a servicio).
/// El valor esperado es <c>Internal:ApiKey</c>, que en Azure proviene de Key Vault
/// (secreto <c>Internal--ApiKey</c>) y en local de la variable <c>Internal__ApiKey</c>.
/// </summary>
public static class InternalApiKey
{
    public const string HeaderName = "X-Internal-Key";

    public static RouteGroupBuilder MapInternalGroup(this IEndpointRouteBuilder app)
    {
        return app.MapGroup("/internal").AddEndpointFilter(async (context, next) =>
        {
            var config = context.HttpContext.RequestServices.GetRequiredService<IConfiguration>();
            // Se lee en cada petición para respetar la recarga periódica de Key Vault (rotación).
            var expected = config["Internal:ApiKey"];
            var provided = context.HttpContext.Request.Headers[HeaderName].ToString();

            if (string.IsNullOrEmpty(expected) || !string.Equals(expected, provided, StringComparison.Ordinal))
            {
                return Results.Unauthorized();
            }

            return await next(context);
        });
    }

    /// <summary>Agrega la cabecera interna a un <see cref="HttpClient"/> tipado.</summary>
    public static void AttachInternalKey(HttpClient client, IConfiguration config)
    {
        client.DefaultRequestHeaders.Remove(HeaderName);
        client.DefaultRequestHeaders.Add(HeaderName, config["Internal:ApiKey"] ?? string.Empty);
    }
}
