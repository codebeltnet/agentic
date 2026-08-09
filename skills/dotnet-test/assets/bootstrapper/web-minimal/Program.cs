using Codebelt.Bootstrapper.Web;
using Microsoft.Extensions.Hosting;

namespace {APPLICATION_NAMESPACE};

public sealed class Program : MinimalWebProgram
{
    public static Task Main(string[] args)
    {
        var builder = CreateHostBuilder(args);
        {PRESERVED_SERVICE_REGISTRATIONS}

        var app = builder.Build();
        {PRESERVED_WEB_PIPELINE_AND_ENDPOINTS}
        return app.RunAsync();
    }
}
