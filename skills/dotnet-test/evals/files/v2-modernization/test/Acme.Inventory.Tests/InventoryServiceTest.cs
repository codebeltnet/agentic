using Xunit;
using Xunit.Abstractions;

namespace Acme.Inventory;

public class InventoryServiceTest
{
    private readonly ITestOutputHelper _output;

    public InventoryServiceTest(ITestOutputHelper output)
    {
        _output = output;
    }

    [Fact]
    public void GetAvailableCount_ReturnsOnlyAvailableItems()
    {
        var sut = new InventoryService();
        _output.WriteLine("Counting available items.");

        var actual = sut.GetAvailableCount(new[] { true, false, true });

        Assert.Equal(2, actual);
    }
}

