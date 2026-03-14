namespace {ROOT_NAMESPACE}.{AppType};

public class Startup : WorkerStartup
{
    public Startup(IConfiguration configuration, IHostEnvironment environment) : base(configuration, environment)
    {
    }

    public override void ConfigureServices(IServiceCollection services)
    {
        services.AddHostedService<Worker>();
    }
}
