using Codebelt.Extensions.Xunit;
using Xunit;

namespace {SUT_NAMESPACE};

public class {SUT_TYPE}Test : Test
{
    public {SUT_TYPE}Test(ITestOutputHelper output) : base(output)
    {
    }

    [Fact]
    public void Should{EXPECTED}_When{CONDITION}()
    {
        var sut = {SOURCE_GROUNDED_ARRANGE};

        var actual = {SOURCE_GROUNDED_ACT};

        Assert.Equal({SOURCE_GROUNDED_EXPECTED}, actual);
    }
}

