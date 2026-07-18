using BenchmarkDotNet.Attributes;

namespace Acme.Core;

[MemoryDiagnoser]
public class ParserBenchmark
{
    private readonly Parser _parser = new();

    [Benchmark]
    public int ParseTypical() => _parser.Parse("42");
}

public sealed class Parser
{
    public int Parse(string value) => int.Parse(value, System.Globalization.CultureInfo.InvariantCulture);
}
