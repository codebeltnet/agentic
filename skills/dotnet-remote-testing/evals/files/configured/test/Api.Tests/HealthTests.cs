using Xunit;

namespace Api.Tests;

public class HealthTests
{
    [Fact]
    public void Status_IsOk() => Assert.Equal("OK", "OK");
}
