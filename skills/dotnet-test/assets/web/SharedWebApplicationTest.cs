using Codebelt.Extensions.Xunit.Hosting.AspNetCore;
using Microsoft.AspNetCore.Hosting;
using Microsoft.AspNetCore.TestHost;
using Xunit;

namespace {APPLICATION_NAMESPACE};

public class {BEHAVIOR}Test : WebApplicationTest<{ENTRY_POINT}, BlockingManagedWebApplicationFixture<{ENTRY_POINT}>>
{
    public {BEHAVIOR}Test(BlockingManagedWebApplicationFixture<{ENTRY_POINT}> hostFixture, ITestOutputHelper output) : base(hostFixture, output)
    {
    }

    [Fact]
    public async Task Should{EXPECTED}_When{CONDITION}()
    {
        using var client = Host.GetTestClient();

        using var response = await client.GetAsync("{SOURCE_GROUNDED_ROUTE}").ConfigureAwait(false);

        Assert.Equal({SOURCE_GROUNDED_STATUS}, response.StatusCode);
    }

    protected override void ConfigureWebHost(IWebHostBuilder builder)
    {
        {PRESERVED_SHARED_WEB_HOST_CONFIGURATION}
    }
}

