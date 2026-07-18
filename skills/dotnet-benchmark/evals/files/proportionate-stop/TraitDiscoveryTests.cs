using Xunit;

namespace Acme.Testing;

public class TraitDiscoveryTests
{
    [Fact]
    public void SelectIntegrationTraits_FiltersDeterministically()
    {
        var traits = new[]
        {
            "integration:postgres",
            "unit:formatter",
            "integration:redis",
            "unit:validator"
        };

        var selected = new TraitDiscovery().SelectIntegrationTraits(traits);

        Assert.Equal(new[] { "integration:postgres", "integration:redis" }, selected);
    }
}
