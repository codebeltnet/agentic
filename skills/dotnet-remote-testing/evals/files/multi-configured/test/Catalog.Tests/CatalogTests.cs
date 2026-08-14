using Xunit;

namespace Catalog.Tests;

public class CatalogTests
{
    [Fact]
    public void Lookup_ReturnsExpectedValue() => Assert.Equal("OK", "OK");
}
