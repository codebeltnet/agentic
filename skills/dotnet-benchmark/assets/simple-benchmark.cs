using System;
using BenchmarkDotNet.Attributes;
using BenchmarkDotNet.Configs;

namespace {SUT_NAMESPACE}
{
    // Simple-tier template: benchmark the meaningful members of a value-like type as discrete
    // scenarios. Keep one method marked Baseline = true as the comparison anchor. Replace the
    // placeholder members below with the real API of {SUT_TYPE}.
    [MemoryDiagnoser]
    [GroupBenchmarksBy(BenchmarkLogicalGroupRule.ByCategory)]
    public class {SUT_TYPE}Benchmark
    {
        private {SUT_TYPE} _instance;

        [GlobalSetup]
        public void Setup()
        {
            // Deterministic, cheap-to-build state prepared once (never measured).
            _instance = new {SUT_TYPE}();
        }

        [Benchmark(Baseline = true, Description = "Construct")]
        public {SUT_TYPE} Construct() => new {SUT_TYPE}();

        [Benchmark(Description = "ToString")]
        public string ToStringScenario() => _instance.ToString();

        [Benchmark(Description = "GetHashCode")]
        public int GetHashCodeScenario() => _instance.GetHashCode();
    }
}
