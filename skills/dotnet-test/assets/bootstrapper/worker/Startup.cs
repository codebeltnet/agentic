using Codebelt.Bootstrapper.Worker;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Hosting;

namespace {APPLICATION_NAMESPACE};

public sealed class Startup : WorkerStartup
{
    public Startup(IConfiguration configuration, IHostEnvironment environment) : base(configuration, environment)
    {
    }

    public override void ConfigureServices(IServiceCollection services)
    {
        services.AddHostedService<Worker>();
        {PRESERVED_SERVICE_REGISTRATIONS}
    }
}

