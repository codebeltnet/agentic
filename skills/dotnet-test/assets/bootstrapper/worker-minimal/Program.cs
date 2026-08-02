using Codebelt.Bootstrapper.Worker;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Hosting;

namespace {APPLICATION_NAMESPACE};

public sealed class Program : MinimalWorkerProgram
{
    public static Task Main(string[] args)
    {
        var builder = CreateHostBuilder(args);
        builder.Services.AddHostedService<{WORKER_TYPE}>();
        {PRESERVED_SERVICE_REGISTRATIONS}
        return builder.Build().RunAsync();
    }
}
