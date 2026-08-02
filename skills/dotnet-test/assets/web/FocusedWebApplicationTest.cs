using Codebelt.Extensions.Xunit;
using Codebelt.Extensions.Xunit.Hosting.AspNetCore;
using Microsoft.AspNetCore.TestHost;
using Xunit;

namespace {APPLICATION_NAMESPACE};

public class {BEHAVIOR}Test : Test
{
    public {BEHAVIOR}Test(ITestOutputHelper output) : base(output)
    {
    }

    [Fact]
    public async Task Should{EXPECTED}_When{CONDITION}()
    {
        using var application = WebApplicationTestFactory.Create<{ENTRY_POINT}>(builder =>
        {
            {PRESERVED_WEB_HOST_CONFIGURATION}
        });
        using var client = application.Host.GetTestClient();

        using var response = await client.GetAsync("{SOURCE_GROUNDED_ROUTE}").ConfigureAwait(false);

        Assert.Equal({SOURCE_GROUNDED_STATUS}, response.StatusCode);
    }
}

