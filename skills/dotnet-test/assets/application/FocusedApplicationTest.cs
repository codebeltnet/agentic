using Codebelt.Extensions.Xunit;
using Codebelt.Extensions.Xunit.Hosting;
using Microsoft.Extensions.DependencyInjection;
using Xunit;

namespace {APPLICATION_NAMESPACE};

public class {BEHAVIOR}Test : Test
{
    public {BEHAVIOR}Test(ITestOutputHelper output) : base(output)
    {
    }

    [Fact]
    public void Should{EXPECTED}_When{CONDITION}()
    {
        using var application = ApplicationTestFactory.Create<{ENTRY_POINT}>(builder =>
        {
            {PRESERVED_HOST_CONFIGURATION}
        }, new ManagedApplicationFixture<{ENTRY_POINT}>());

        var actual = application.Host.Services.GetRequiredService<{SOURCE_GROUNDED_SERVICE}>();

        Assert.Equal({SOURCE_GROUNDED_EXPECTED}, actual.{SOURCE_GROUNDED_MEMBER});
    }
}
