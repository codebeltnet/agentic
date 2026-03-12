namespace {ROOT_NAMESPACE}.{AppType};

public class Program : MinimalWebProgram
{
    static Task Main(string[] args)
    {
        var builder = CreateHostBuilder(args);
        var app = builder.Build();
        app.UseRouting();
        return app.RunAsync();
    }
}
