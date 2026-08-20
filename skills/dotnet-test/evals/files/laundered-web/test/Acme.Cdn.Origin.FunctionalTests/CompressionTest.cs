using Xunit;

namespace Acme.Cdn.Origin;

public class CompressionTest
{
    [Fact]
    public async Task Get_ShouldNotCompress_WhenCompressionDisabled()
    {
        await using var application = CdnOriginTestApplication.Create();
        using var client = application.CreateClient();

        Assert.Equal("identity", await client.GetStringAsync("/compression"));
    }

    [Fact]
    public async Task Get_ShouldCompress_WhenEnabled()
    {
        await using var application = CdnOriginTestApplication.Create(new Dictionary<string, string?> { ["Compression:Enabled"] = "true" });
        using var client = application.CreateClient();

        Assert.Equal("br", await client.GetStringAsync("/compression"));
    }
}

