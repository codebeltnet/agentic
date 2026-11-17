using Codebelt.Extensions.Xunit.Hosting;
using Microsoft.Extensions.DependencyInjection;
using Xunit;

namespace InventoryWorker.Tests;

public sealed class InventoryWorkerTest : ApplicationTest<WorkerProgram, ManagedApplicationFixture<WorkerProgram>>
{
    public InventoryWorkerTest(ManagedApplicationFixture<WorkerProgram> fixture, ITestOutputHelper output)
        : base(fixture, output)
    {
    }

    [Fact]
    public void Host_ContainsApplicationService()
    {
        var identity = Host.Services.GetRequiredService<WorkerIdentity>();
        Assert.Equal("Inventory worker", identity.Name);
        Assert.True(WorkerProgram.MainInvoked);
        Assert.NotEqual(typeof(WorkerProgram).Assembly, typeof(InventoryWorkerTest).Assembly);
    }
}
