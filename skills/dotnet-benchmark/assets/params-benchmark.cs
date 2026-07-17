using System;
using BenchmarkDotNet.Attributes;
using BenchmarkDotNet.Configs;

namespace {SUT_NAMESPACE}
{
    // Complex-tier template: sweep representative input sizes, build deterministic payloads once in
    // [GlobalSetup], and compare a candidate implementation against a baseline. Use this shape for
    // size- or variant-sensitive types (hashing, parsing, buffers, algorithms). If you need an
    // implementation enum as a [Params] dimension, collapse the measured work into one dispatching
    // [Benchmark] method instead of keeping separate benchmark methods and an unused parameter.
    // Replace the payload sizes and the measured calls with the real API of {SUT_TYPE}.
    [MemoryDiagnoser]
    [GroupBenchmarksBy(BenchmarkLogicalGroupRule.ByParams)]
    public class {SUT_TYPE}Benchmark
    {
        // Sweep representative micro / mid / macro sizes so trends are visible.
        [Params(64, 4096, 1_048_576)]
        public int Size { get; set; }

        private byte[] _payload;

        [GlobalSetup]
        public void Setup()
        {
            // Seeded RNG keeps payloads deterministic across runs.
            var rng = new Random(42);
            _payload = new byte[Size];
            rng.NextBytes(_payload);
        }

        [Benchmark(Baseline = true, Description = "Process (baseline)")]
        public int Process_Baseline() => {SUT_TYPE}.Process(_payload);

        [Benchmark(Description = "Process (candidate)")]
        public int Process_Candidate() => {SUT_TYPE}.ProcessOptimized(_payload);
    }
}
