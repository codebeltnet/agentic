using Codebelt.Bootstrapper.Console;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Hosting;

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
