using Azure.Extensions.AspNetCore.Configuration.Secrets;
using Azure.Identity;
using Microsoft.AspNetCore.Builder;
using Microsoft.Extensions.Configuration;

namespace TeamForMe.Shared;

/// <summary>
/// Integra Azure Key Vault como proveedor de configuración.
///
/// Si <c>KeyVault:Uri</c> (variable de entorno <c>KeyVault__Uri</c>) está definido, los secretos
/// del vault se cargan en <see cref="IConfiguration"/> y sobrescriben appsettings/variables de
/// entorno. La convención de nombres de Key Vault usa <c>--</c> como separador de sección:
/// el secreto <c>Internal--ApiKey</c> se lee como <c>Internal:ApiKey</c>.
///
/// La autenticación usa <see cref="DefaultAzureCredential"/>, que prueba en orden: variables de
/// entorno, Workload Identity (AKS), Managed Identity (Container Apps / VM) y Azure CLI (local).
/// Ningún secreto ni credencial vive en el código ni en la imagen del contenedor.
/// </summary>
public static class KeyVaultConfiguration
{
    public static WebApplicationBuilder AddAzureKeyVaultIfConfigured(this WebApplicationBuilder builder)
    {
        var vaultUri = builder.Configuration["KeyVault:Uri"];
        if (string.IsNullOrWhiteSpace(vaultUri))
        {
            return builder;
        }

        var credential = new DefaultAzureCredential(new DefaultAzureCredentialOptions
        {
            // Con una identidad administrada asignada por el usuario hay que indicar su client id.
            ManagedIdentityClientId = builder.Configuration["AZURE_CLIENT_ID"],
        });

        builder.Configuration.AddAzureKeyVault(
            new Uri(vaultUri),
            credential,
            new AzureKeyVaultConfigurationOptions
            {
                // Rotación de secretos sin reiniciar: se vuelve a leer el vault cada 5 minutos.
                ReloadInterval = TimeSpan.FromMinutes(5),
            });

        return builder;
    }
}
