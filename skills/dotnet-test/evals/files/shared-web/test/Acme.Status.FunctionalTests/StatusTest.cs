using Microsoft.AspNetCore.Hosting;
using Microsoft.AspNetCore.Mvc.Testing;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Hosting;
using Xunit;

namespace Acme.Status;

public class StatusTest : IClassFixture<WebApplicationFactory<Program>>
{
    private readonly WebApplicationFactory<Program> _application;

    public StatusTest(WebApplicationFactory<Program> application)
    {
        _application = application.WithWebHostBuilder(builder =>
        {
            builder.UseEnvironment(Environments.Staging);
            builder.ConfigureAppConfiguration((_, configuration) => configuration.AddInMemoryCollection(new Dictionary<string, string?> { ["Status:Lane"] = "shared" }));
        });
    }

    [Fact]
    public async Task GetStatus_ShouldReturnConfiguredStatus()
    {
        using var client = _application.CreateClient();
        Assert.Equal("ready|shared|Staging", await client.GetStringAsync("/status"));
    }

    [Fact]
    public void Services_ShouldExposeStatusMarker()
    {
        Assert.Equal("ready", _application.Services.GetRequiredService<StatusMarker>().Value);
    }
}

