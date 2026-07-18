using System.Linq;
using Xunit;

namespace Acme.Search;

public class LegacyAliasQueryTests
{
    [Fact]
    public void CountLegacyAliases_ReturnsAllFixedWidthAliases()
    {
        var aliases = Enumerable.Range(0, 8).Select(i => $"USR{i:D3}");
        Assert.Equal(8, LegacyAliasQuery.CountLegacyAliases(aliases));
    }

    [Fact]
    public void CountLegacyAliases_AllowsZeroMatchesWhenScenarioIsNonLegacy()
    {
        var aliases = new[] { "NEW0001", "NEW0002", "NEW0003" };
        Assert.Equal(0, LegacyAliasQuery.CountLegacyAliases(aliases));
    }
}
