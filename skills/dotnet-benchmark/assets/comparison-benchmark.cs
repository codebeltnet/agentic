using System;
using BenchmarkDotNet.Attributes;
using BenchmarkDotNet.Configs;

namespace {SUT_NAMESPACE};

// Structural example only. Replace every placeholder and adapt cases, state, calls, return types,
// equivalence checks, and names to the real consumer operation. Remove unused using directives.
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

        var expected = {BASELINE_CALL};
        var actual = {CANDIDATE_CALL};
        if (!{EQUIVALENCE_CHECK})
        {
            throw new InvalidOperationException("Baseline and candidate results differ for the current benchmark case.");
        }
    }

    [Benchmark(Baseline = true, Description = "{BASELINE_DESCRIPTION}")]
    public {RETURN_TYPE} Current() => {BASELINE_CALL};

    [Benchmark(Description = "{CANDIDATE_DESCRIPTION}")]
    public {RETURN_TYPE} Candidate() => {CANDIDATE_CALL};
}
