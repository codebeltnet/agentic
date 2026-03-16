using Codebelt.Bootstrapper.Web;

namespace {ROOT_NAMESPACE}.{AppType};

public class Program : MinimalWebProgram
{
    static Task Main(string[] args)
    {
        var builder = CreateHostBuilder(args);
        builder.Services.AddAuthorization();
        builder.Services.AddEndpointsApiExplorer();
        var app = builder.Build();
        app.UseHttpsRedirection();
        app.UseAuthorization();
        app.MapGet("/", () => Results.Ok(new { message = "Hello World!", timestamp = DateTime.UtcNow }));
        return app.RunAsync();
    }
}
