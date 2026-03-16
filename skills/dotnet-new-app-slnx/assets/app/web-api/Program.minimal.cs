namespace {ROOT_NAMESPACE}.{AppType};

public class Program : MinimalWebProgram
{
    static Task Main(string[] args)
    {
        var builder = CreateHostBuilder(args);
        builder.Services.AddControllers();
        var app = builder.Build();
        app.UseHttpsRedirection();
        app.UseRouting();
        app.UseAuthorization();
        app.MapControllers();
        return app.RunAsync();
    }
}
