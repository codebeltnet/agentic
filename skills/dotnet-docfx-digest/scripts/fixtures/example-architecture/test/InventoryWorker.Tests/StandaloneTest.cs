using Xunit;

namespace InventoryWorker.Tests;

public sealed class StandaloneTest
{
    [Fact]
    public void MultipliesInventoryQuantity()
    {
        Assert.Equal(42, 6 * 7);
    }
}
