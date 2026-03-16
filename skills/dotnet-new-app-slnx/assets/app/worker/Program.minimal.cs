using Codebelt.Bootstrapper.Worker;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Hosting;

namespace {ROOT_NAMESPACE}.{AppType};

public class Program : MinimalWorkerProgram
{
    static Task Main(string[] args)
    {
        var builder = CreateHostBuilder(args);
        builder.Services.AddHostedService<Worker>();
        var host = builder.Build();
        return host.RunAsync();
    }
}
