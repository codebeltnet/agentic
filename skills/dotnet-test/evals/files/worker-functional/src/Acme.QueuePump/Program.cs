using Codebelt.Bootstrapper.Worker;
using Microsoft.Extensions.Hosting;

namespace Acme.QueuePump;

public sealed class Program : WorkerProgram<Startup>
{
    public static Task Main(string[] args)
    {
        return CreateHostBuilder(args).Build().RunAsync();
    }
}

