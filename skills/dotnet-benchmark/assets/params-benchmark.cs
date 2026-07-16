using System;
using System.Collections.Generic;
using BenchmarkDotNet.Attributes;
using BenchmarkDotNet.Configs;

namespace {SUT_NAMESPACE}
{
    // Complex-tier template: sweep input sizes and/or implementation variants with [Params], build
    // deterministic payloads once in [GlobalSetup], and compare candidates against a baseline. Use
    // this shape for size- or variant-sensitive types (hashing, parsing, buffers, algorithms).
    // Replace Variant, the payload sizes, and the measured calls with the real API of {SUT_TYPE}.
    [MemoryDiagnoser]
    [GroupBenchmarksBy(BenchmarkLogicalGroupRule.ByParams)]
    public class {SUT_TYPE}Benchmark
    {
        public enum Variant
        {
            Baseline,
            Candidate
        }

        [Params(Variant.Baseline, Variant.Candidate)]
        public Variant Implementation { get; set; }

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
