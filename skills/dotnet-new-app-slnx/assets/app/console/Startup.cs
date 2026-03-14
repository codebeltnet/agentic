namespace {ROOT_NAMESPACE}.{AppType};

public class Startup : ConsoleStartup
{
    public Startup(IConfiguration configuration, IHostEnvironment environment) : base(configuration, environment)
    {
    }

    public override void ConfigureServices(IServiceCollection services)
    {
    }

    public override async Task RunAsync(IServiceProvider serviceProvider, CancellationToken cancellationToken)
    {
    }
}
