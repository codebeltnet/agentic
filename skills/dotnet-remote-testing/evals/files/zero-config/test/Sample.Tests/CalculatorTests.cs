using Sample;
using Xunit;

namespace Sample.Tests;

public class CalculatorTests
{
    [Fact]
    public void Add_ReturnsSum() => Assert.Equal(4, Calculator.Add(2, 2));

    [Fact]
    public void Multiply_ReturnsProduct() => Assert.Equal(6, Calculator.Multiply(2, 3));
}
