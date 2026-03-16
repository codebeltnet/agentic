using Codebelt.Bootstrapper.Web;

namespace {ROOT_NAMESPACE}.{AppType};

public class Program : MinimalWebProgram
{
    static Task Main(string[] args)
    {
        var builder = CreateHostBuilder(args);
        var app = builder.Build();
        app.UseHttpsRedirection();
        app.UseRouting();
        app.MapGet("/", () => "Hello from {ROOT_NAMESPACE}.{AppType}.");
        return app.RunAsync();
    }
}
