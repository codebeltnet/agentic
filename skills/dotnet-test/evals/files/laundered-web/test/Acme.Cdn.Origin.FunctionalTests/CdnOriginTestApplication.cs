using Codebelt.Extensions.Xunit;
using Microsoft.AspNetCore.Hosting;
using Microsoft.AspNetCore.Mvc.Testing;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.Hosting;

namespace Acme.Cdn.Origin;

/// <summary>
/// Hosts the real origin pipeline over an isolated temporary content directory.
/// Implements the Codebelt managed fixture pattern with entrypoint-owned startup.
/// </summary>
public sealed class CdnOriginTestApplication : IAsyncDisposable, IDisposable
{
    private readonly WebApplicationFactory<Program> _factory;
    private readonly TempContent _content;

    private CdnOriginTestApplication(WebApplicationFactory<Program> factory, TempContent content)
    {
        _factory = factory;
        _content = content;
    }

    public TempContent Content => _content;

    public static CdnOriginTestApplication Create(IDictionary<string, string?>? settings = null)
    {
        var content = new TempContent();
        var merged = settings is null ? new Dictionary<string, string?>() : new Dictionary<string, string?>(settings);
        return new CdnOriginTestApplication(new CdnOriginApplicationFactory(merged), content);
    }

    public HttpClient CreateClient() => _factory.CreateClient();

    public void Dispose()
    {
        _factory.Dispose();
        _content.Dispose();
    }

    public async ValueTask DisposeAsync()
    {
        if (_factory is IAsyncDisposable asyncDisposable)
        {
            await asyncDisposable.DisposeAsync().ConfigureAwait(false);
        }
        else
        {
            _factory.Dispose();
        }

        _content.Dispose();
    }

    private sealed class CdnOriginApplicationFactory : WebApplicationFactory<Program>
    {
        private readonly Dictionary<string, string?> _settings;

        public CdnOriginApplicationFactory(Dictionary<string, string?> settings)
        {
            _settings = settings;
        }

        protected override void ConfigureWebHost(IWebHostBuilder builder)
        {
            builder.UseEnvironment(Environments.Production);
            builder.ConfigureAppConfiguration((_, configuration) => configuration.AddInMemoryCollection(_settings));
        }
    }
}
