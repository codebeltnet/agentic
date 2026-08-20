using Xunit;

namespace Matrix.Tests;

public class MatrixTests
{
    [Fact]
    public void RunsOnEveryTargetFramework()
    {
        // This test passes under net10.0 and fails under net9.0 on purpose, so a remote run
        // surfaces a genuine, per-target-framework failure with a real assertion message and
        // stack trace to report - one TFM failing while the other passes.
        var expected = "net10.0";
#if NET9_0
        var actual = "net9.0";
#else
        var actual = "net10.0";
#endif
        Assert.Equal(expected, actual);
    }
}
