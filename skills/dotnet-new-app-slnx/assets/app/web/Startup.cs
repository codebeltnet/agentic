namespace {ROOT_NAMESPACE}.{AppType};

public class Startup : WebStartup
{
    public Startup(IConfiguration configuration, IHostEnvironment environment) : base(configuration, environment)
    {
    }

    public override void ConfigureServices(IServiceCollection services)
    {
    }

    public override void ConfigurePipeline(IApplicationBuilder app)
    {
        app.UseRouting();
    }
}
