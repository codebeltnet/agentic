using Microsoft.AspNetCore.Hosting;
using Microsoft.AspNetCore.Mvc.Testing;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.Hosting;

namespace Acme.Cdn.Origin;

public sealed class CdnOriginTestApplication : WebApplicationFactory<Program>
{
    private readonly Dictionary<string, string?> _settings;

    public CdnOriginTestApplication(IDictionary<string, string?>? settings = null)
    {
        Content = new TempContent();
        _settings = settings is null ? new() : new(settings);
    }

    public TempContent Content { get; }

    protected override void ConfigureWebHost(IWebHostBuilder builder)
    {
        builder.UseEnvironment(Environments.Production);
        builder.ConfigureAppConfiguration((_, configuration) => configuration.AddInMemoryCollection(_settings));
    }

    protected override void Dispose(bool disposing)
    {
        base.Dispose(disposing);
        if (disposing) { Content.Dispose(); }
    }
}

