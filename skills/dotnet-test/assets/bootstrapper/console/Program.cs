using Codebelt.Bootstrapper.Console;
using Microsoft.Extensions.Hosting;

namespace {APPLICATION_NAMESPACE};

public sealed class Program : ConsoleProgram<Startup>
{
    public static Task Main(string[] args)
    {
        return CreateHostBuilder(args).Build().RunAsync();
    }
}

