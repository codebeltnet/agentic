using Codebelt.Bootstrapper.Console;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Hosting;

namespace {APPLICATION_NAMESPACE};

public sealed class Program : MinimalConsoleProgram<Program>
{
    public static Task Main(string[] args)
    {
        var builder = CreateHostBuilder(args);
        {PRESERVED_SERVICE_REGISTRATIONS}
        return builder.Build().RunAsync();
    }

    public override Task RunAsync(IServiceProvider serviceProvider, CancellationToken cancellationToken)
    {
        return {APPLICATION_RUN_TASK};
    }
}
