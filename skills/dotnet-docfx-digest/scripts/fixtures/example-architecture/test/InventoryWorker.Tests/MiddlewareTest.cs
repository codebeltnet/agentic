using System.Linq;
using System.Net.Http;
using System.Threading.Tasks;
using Microsoft.AspNetCore.Builder;
using Microsoft.AspNetCore.Http;
using Xunit;

namespace InventoryWorker.Tests;

public sealed class MiddlewareTest
{
    [Fact]
    public async Task Pipeline_AddsInventoryHeader()
    {
        var cancellationToken = TestContext.Current.CancellationToken;
        var builder = WebApplication.CreateBuilder();
        await using var app = builder.Build();
        app.Urls.Add("http://127.0.0.1:0");
        app.Use(async (context, next) =>
        {
            context.Response.Headers["X-Inventory"] = "ready";
            await next(context);
        });
        app.MapGet("/inventory", () => "42");
        await app.StartAsync(cancellationToken);
        using var client = new HttpClient();
        using var response = await client.GetAsync(app.Urls.Single() + "/inventory", cancellationToken);
        response.EnsureSuccessStatusCode();
        Assert.Equal("42", await response.Content.ReadAsStringAsync(cancellationToken));
        Assert.Equal("ready", response.Headers.GetValues("X-Inventory").Single());
        await app.StopAsync(cancellationToken);
    }
}
