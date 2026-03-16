using Codebelt.Bootstrapper.Web;
using Microsoft.Extensions.Hosting;

namespace {ROOT_NAMESPACE}.{AppType};

public class Program : WebProgram<Startup>
{
    static async Task Main(string[] args)
    {
        await CreateHostBuilder(args)
            .Build()
            .RunAsync()
            .ConfigureAwait(false);
    }
}
