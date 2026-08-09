using Codebelt.Extensions.Xunit.Hosting;
using Microsoft.Extensions.DependencyInjection;
using Xunit;

namespace Acme.QueuePump;

public class QueuePumpTest : ApplicationTest<Program, BlockingManagedApplicationFixture<Program>>
{
    public QueuePumpTest(BlockingManagedApplicationFixture<Program> hostFixture, ITestOutputHelper output) : base(hostFixture, output)
    {
    }

    [Fact]
    public void ShouldResolveMarker_WhenApplicationStarts()
    {
        Assert.Equal("queue-pump", Host.Services.GetRequiredService<QueuePumpMarker>().Value);
    }
}
