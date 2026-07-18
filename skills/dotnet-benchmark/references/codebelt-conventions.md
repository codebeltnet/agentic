# Codebelt Benchmark Conventions

Follow these repository conventions so benchmark projects remain discoverable and consistent across codebelt repositories. Experiment validity takes precedence over forcing a template shape.

## Naming and placement

- Benchmark projects live under `tuning/` and are named `{SutProject}.Benchmarks`, such as `Cuemon.Core.Benchmarks`.
- A benchmark class name ends with `Benchmark` and names the measured question or type, such as `DateSpanFormattingBenchmark` or `Sha512256ComparisonBenchmark`.
- The benchmark class uses the same namespace as the type it measures; do not append `.Benchmarks`. The project overrides `RootNamespace` to the SUT root.
- Method names distinguish implementations or scenarios and every `[Benchmark]` has a readable `Description`.
- One `tooling/` runner host discovers all `tuning/` projects through the existing wildcard project reference.

## Default instrumentation

Every codebelt benchmark class uses `[MemoryDiagnoser]`. Add `[GroupBenchmarksBy]` when the class has multiple methods/params and the grouping makes the report clearer. Use `[GlobalSetup]` when state or correctness checks must be prepared outside measurement; do not add an empty setup merely for visual consistency.

Baselines follow experiment semantics:

- A current/reference implementation is `Baseline = true` when one or more equivalent alternatives are compared.
- A single-operation characterization benchmark has no baseline.
- Unrelated operations do not share a baseline.
- A cohesive class with several alternative pairs uses `[BenchmarkCategory]`, grouping by category, and one baseline per category.

This refines the older “exactly one baseline per class” shortcut. BenchmarkDotNet ratios are useful only when the grouped methods perform comparable work.

## Experiment shapes

### Equivalent implementation comparison

Use `assets/comparison-benchmark.cs` when the same consumer operation has a current/reference and candidate implementation. Keep inputs and wrappers symmetric, validate equivalent results in setup, and sweep only dimensions that can change the comparison.

### Single-operation characterization

Use `assets/operation-benchmark.cs` when there is no honest competing implementation. This shape characterizes time, allocations, and scaling for one operation across representative cases without inventing a baseline.

### Multiple independent questions

Prefer separate focused classes. If existing repository convention keeps them together, use categories that prevent unrelated ratios. Construction, formatting, equality, hashing, parsing, and matching are not automatically comparable merely because they belong to one type.

## Deterministic inputs

Build inputs outside measured methods. Use fixed seeds only when pseudo-random data matches the domain. Prefer structured inputs for parsers, matchers, collections, caches, and serializers. Parameter cases should have readable report labels.

Do not use network, disk, database, logging, or sleep calls inside a microbenchmark. When external behavior is the point, select profiling, load testing, or a macrobenchmark and preserve codebelt project placement only if it remains useful.

## Runner and reports

The runner calls `Codebelt.Extensions.BenchmarkDotNet.Console.BenchmarkProgram.Run`, reuses the repository's existing name such as `benchmark-runner` or `bdn-runner`, and writes artifacts under `reports/`. Codebelt libraries normally keep `SkipBenchmarksWithReports = true`; a matching file under `reports/tuning/` intentionally filters that benchmark type on later invocations. Run the `runner-preflight.md` checks before diagnosing benchmark code.

Default runtime configuration stays plain `return c;`. For explicit runtime jobs, assign `BenchmarkWorkspaceOptions.Slim` once to `slimJob`, then add `slimJob.WithRuntime(...)` for each supported TFM. The TFM list is the expected repository-specific difference; preserve the surrounding lean runner shape.

## Reference implementations

Repository precedents include:

- `codebeltnet/cuemon/tuning/Cuemon.Core.Benchmarks/DateSpanBenchmark.cs`
- `codebeltnet/cuemon/tuning/Cuemon.Security.Cryptography.Benchmarks/Sha512256Benchmark.cs`
- `codebeltnet/xunit/tuning/Codebelt.Extensions.Xunit.Benchmarks/TestBenchmark.cs`
- the `tooling/bdn-runner` or `tooling/benchmark-runner` hosts in those repositories

Use these for placement and runner conventions, not as authority to preserve a misleading experiment. Adapt the benchmark design to the actual performance question.
