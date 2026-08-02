using Codebelt.Extensions.Xunit.Hosting;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Hosting;
using Xunit;

namespace {APPLICATION_NAMESPACE};

public class {BEHAVIOR}Test : ApplicationTest<{ENTRY_POINT}, BlockingManagedApplicationFixture<{ENTRY_POINT}>>
{
    public {BEHAVIOR}Test(BlockingManagedApplicationFixture<{ENTRY_POINT}> hostFixture, ITestOutputHelper output) : base(hostFixture, output)
    {
    }

    [Fact]
    public void Should{EXPECTED}_When{CONDITION}()
    {
        var actual = Host.Services.GetRequiredService<{SOURCE_GROUNDED_SERVICE}>();

        Assert.Equal({SOURCE_GROUNDED_EXPECTED}, actual.{SOURCE_GROUNDED_MEMBER});
    }

    protected override void ConfigureHost(IHostBuilder builder)
    {
        {PRESERVED_SHARED_HOST_CONFIGURATION}
    }
}

