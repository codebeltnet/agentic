using Codebelt.Bootstrapper.Console;
using Microsoft.Extensions.Hosting;

namespace {ROOT_NAMESPACE}.{AppType};

public class Program : MinimalConsoleProgram
{
    static Task Main(string[] args)
    {
        var builder = CreateHostBuilder(args);
        var host = builder.Build();
        return host.RunAsync();
    }

    public override async Task RunAsync(IServiceProvider serviceProvider, CancellationToken cancellationToken)
    {
    }
}
