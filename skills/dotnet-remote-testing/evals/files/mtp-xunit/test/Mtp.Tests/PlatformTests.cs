using System;
using Xunit;

namespace Mtp.Tests;

public class PlatformTests
{
    [Fact]
    public void ShouldRunOnLinux() => Assert.True(OperatingSystem.IsLinux());

    [Fact]
    public void ShouldReportAnAssertionFailure() => Assert.Fail("Intentional failure to verify remote TRX reporting.");
}
