using Microsoft.Extensions.Hosting;
using Microsoft.Extensions.Logging;

namespace {APPLICATION_NAMESPACE};

public sealed class Worker(ILogger<Worker> logger) : BackgroundService
{
    protected override async Task ExecuteAsync(CancellationToken stoppingToken)
    {
        {SOURCE_GROUNDED_WORKER_BEHAVIOR}
        await Task.CompletedTask.ConfigureAwait(false);
    }
}

