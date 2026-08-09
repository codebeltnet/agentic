using Microsoft.Extensions.Hosting;

namespace Acme.QueuePump;

public sealed class QueuePumpWorker : BackgroundService
{
    protected override Task ExecuteAsync(CancellationToken stoppingToken)
    {
        return Task.CompletedTask;
    }
}

