using System;
using BenchmarkDotNet.Attributes;
using BenchmarkDotNet.Configs;

namespace {SUT_NAMESPACE};

// Structural example for one operation with no honest competing implementation. Replace every
// placeholder and adapt the cases, data shape, return consumption, and names to the real workload.
// Do not add Baseline = true merely to produce a ratio column. Remove unused using directives.
[MemoryDiagnoser]
[GroupBenchmarksBy(BenchmarkLogicalGroupRule.ByParams)]
public class {BENCHMARK_CLASS}
{
    [Params(64, 4_096, 1_048_576)]
    public int Size { get; set; }

    private byte[] _input = null!;

    [GlobalSetup]
    public void Setup()
    {
        _input = new byte[Size];
        new Random(42).NextBytes(_input);
    }

    [Benchmark(Description = "{OPERATION_DESCRIPTION}")]
    public {RETURN_TYPE} Measure() => {SUT_CALL};
}
