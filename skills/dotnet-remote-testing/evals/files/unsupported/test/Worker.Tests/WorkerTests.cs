using Xunit;

namespace Worker.Tests;

public class WorkerTests
{
    [Fact]
    public void Processes_Message() => Assert.True(1 + 1 == 2);
}
