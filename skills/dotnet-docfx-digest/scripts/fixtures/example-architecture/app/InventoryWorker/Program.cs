using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Hosting;

namespace InventoryWorker;

public sealed record WorkerIdentity(string Name);

public sealed class WorkerProgram
{
    public static bool MainInvoked { get; private set; }

    public static void Main(string[] args)
    {
        MainInvoked = true;
        var builder = Host.CreateApplicationBuilder(args);
        builder.Services.AddSingleton(new WorkerIdentity("Inventory worker"));
        using var host = builder.Build();
        host.Run();
    }
}
