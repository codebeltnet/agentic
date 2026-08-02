using Codebelt.Bootstrapper.Console;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Hosting;

namespace {APPLICATION_NAMESPACE};

public sealed class Startup : ConsoleStartup
{
    public Startup(IConfiguration configuration, IHostEnvironment environment) : base(configuration, environment)
    {
    }

    public override void ConfigureServices(IServiceCollection services)
    {
        {PRESERVED_SERVICE_REGISTRATIONS}
    }

    public override void ConfigureConsole(IServiceProvider serviceProvider)
    {
        {PRESERVED_CONSOLE_CONFIGURATION}
    }

    public override Task RunAsync(IServiceProvider serviceProvider, CancellationToken cancellationToken)
    {
        return {APPLICATION_RUN_TASK};
    }
}

