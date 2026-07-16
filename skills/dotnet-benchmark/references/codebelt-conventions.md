# Codebelt Benchmark Conventions

These rules mirror the pasted "Writing Performance Tests in Cuemon" guidance and the real
implementations in `codebeltnet/cuemon` and `codebeltnet/xunit`. Follow them so benchmarks stay
consistent, discoverable, and comparable across repos.

## Naming and placement

- Benchmark projects live under `tuning/` and are named `{SutProject}.Benchmarks`
  (e.g. `Cuemon.Core.Benchmarks`, `Codebelt.Extensions.Xunit.Benchmarks`).
- A benchmark class name **ends with `Benchmark`** (e.g. `DateSpanBenchmark`, `Sha512256Benchmark`).
- The class lives in the **same namespace as the type it measures** — do **not** append `.Benchmarks`.
  The benchmark project overrides `RootNamespace` to the SUT root so this compiles:

  ```xml
  <PropertyGroup>
    <RootNamespace>Cuemon</RootNamespace>
  </PropertyGroup>
  ```

  So `Cuemon.Security.Cryptography.SHA512256` is benchmarked by a `Sha512256Benchmark` class declared
  in `namespace Cuemon.Security.Cryptography`, inside the `Cuemon.Security.Cryptography.Benchmarks`
  assembly.
- Method names are descriptive scenarios (`Parse_Short`, `ComputeHash_Large`, `Match_ComplexWildcard`).

## Always-on attributes

Every codebelt benchmark class carries:

- `[MemoryDiagnoser]`
- `[GroupBenchmarksBy(...)]` — `ByCategory` for member-scenario suites, `ByParams` for size/variant sweeps
- a `[GlobalSetup]` that prepares deterministic state
- exactly one `[Benchmark(Baseline = true, ...)]` anchor, with `Description` on each method

## Tier 1 — Simple type (member scenarios)

For value-like types with no size-sensitive input, benchmark the meaningful members as discrete
scenarios. This is the `DateSpanBenchmark` shape:

```csharp
namespace Cuemon
{
    [MemoryDiagnoser]
    [GroupBenchmarksBy(BenchmarkLogicalGroupRule.ByCategory)]
    public class DateSpanBenchmark
    {
        private DateSpan _shortSpan;

        [GlobalSetup]
        public void Setup() => _shortSpan = new DateSpan(DateTime.UtcNow, DateTime.UtcNow.AddHours(36));

        [Benchmark(Baseline = true, Description = "Ctor (short span)")]
        public DateSpan Construct_Short() => new DateSpan(DateTime.UtcNow, DateTime.UtcNow.AddHours(36));

        [Benchmark(Description = "ToString (short)")]
        public string ToString_Short() => _shortSpan.ToString();

        [Benchmark(Description = "GetWeeks (short)")]
        public int GetWeeks_Short() => _shortSpan.GetWeeks();
    }
}
```

Cover construction, parsing/formatting, equality, hashing, and any hot instance methods. Template:
`assets/simple-benchmark.cs`.

## Tier 2 — Complex / size- or variant-sensitive type

For hashing, parsing, buffers, or anything whose cost scales with input or has competing
implementations, sweep with `[Params]` and prepare payloads in `[GlobalSetup]`. Two real shapes:

`Sha512256Benchmark` (variant + size, `ByParams`, compares custom vs built-in):

```csharp
[MemoryDiagnoser]
[GroupBenchmarksBy(BenchmarkLogicalGroupRule.ByParams)]
public class Sha512256Benchmark
{
    public enum AlgorithmVariant { CustomSHA512_256, SHA512_Truncated }

    [Params(AlgorithmVariant.CustomSHA512_256, AlgorithmVariant.SHA512_Truncated)]
    public AlgorithmVariant Variant { get; set; }

    private byte[] _smallInput;   // 64 bytes
    private byte[] _largeInput;   // 1 MB

    [GlobalSetup]
    public void GlobalSetup() { /* seeded Random(42) fills deterministic payloads */ }

    [Benchmark(Baseline = true, Description = "Custom SHA-512/256 - small")]
    public byte[] CustomSHA512256_Small() { /* ... */ }
}
```

`TestBenchmark` (size sweep via `[Params(8, 256, 4096)]`, `ByCategory`):

```csharp
[MemoryDiagnoser]
[GroupBenchmarksBy(BenchmarkLogicalGroupRule.ByCategory)]
public class TestBenchmark
{
    [Params(8, 256, 4096)]
    public int Length { get; set; }

    [GlobalSetup]
    public void Setup() { /* build patterns/inputs from Length */ }

    [Benchmark(Baseline = true, Description = "Match - exact string")]
    public bool Match_Exact() => Test.Match(_shortPattern, _shortActual);
}
```

Template: `assets/params-benchmark.cs`. Prefer seeded RNG (`new Random(42)`) and fixed sizes so runs
are deterministic. Choose micro / mid / macro sizes to reveal trends.

## How to pick a tier

Lean Tier 2 when the type: takes a collection/stream/buffer/string whose length matters, has multiple
implementations worth comparing, exposes an algorithm with a size parameter, or is on a documented hot
path. Otherwise Tier 1 is enough. When unsure, ask the user which members and input sizes matter most —
they know the hot paths.

## Reference files (source of truth)

- `codebeltnet/cuemon/tuning/Cuemon.Core.Benchmarks/DateSpanBenchmark.cs`
- `codebeltnet/cuemon/tuning/Cuemon.Security.Cryptography.Benchmarks/Sha512256Benchmark.cs`
- `codebeltnet/xunit/tuning/Codebelt.Extensions.Xunit.Benchmarks/TestBenchmark.cs`
- `codebeltnet/cuemon/tooling/bdn-runner/Program.cs` and
  `codebeltnet/xunit/tooling/benchmark-runner/Program.cs` (runner + multi-runtime jobs)
