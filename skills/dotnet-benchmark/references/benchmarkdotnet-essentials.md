# BenchmarkDotNet Essentials

A compact toolbox for authoring benchmarks. Full docs: https://benchmarkdotnet.org/articles/overview.html

## Core attributes

| Attribute | Purpose |
|-----------|---------|
| `[Benchmark]` | Marks a measured method. Add `Baseline = true` on the reference method and `Description = "..."` for readable reports. |
| `[MemoryDiagnoser]` | Captures allocations and GC counts. Always include it — codebelt benchmarks care about allocations, not just time. |
| `[GroupBenchmarksBy(BenchmarkLogicalGroupRule.ByCategory)]` | Groups related methods so comparisons read cleanly. Use `ByParams` when the story is "same operation across sizes/variants". |
| `[Params(...)]` | Sweeps input values (sizes, enum variants). BenchmarkDotNet runs every method once per combination. |
| `[ParamsSource(nameof(...))]` | Use when the parameter set is computed rather than literal. |
| `[GlobalSetup]` | One-time initialization that is **not** measured. Build payloads and instances here. |
| `[IterationSetup]` / `[IterationCleanup]` | Per-iteration hooks; use sparingly (they add overhead) for state that must reset each iteration. |
| `[Arguments(...)]` | Passes literal arguments to a benchmark method — lighter than `[Params]` for a few fixed cases. |

## Choosing what to measure

- Keep each `[Benchmark]` method to a **single logical operation**; move setup out of the measured path.
- Return a value from the method (or consume inputs) so the JIT cannot optimize the work away.
- Use deterministic, in-memory data. No network, disk, or database in measured methods — they destroy
  repeatability and are not micro-benchmarks.
- Name methods for the scenario (`Parse_Short`, `ComputeHash_Large`, `Match_ComplexWildcard`) so the
  report is self-describing.

## Diagnosers worth knowing

- `[MemoryDiagnoser]` — allocations (default for codebelt).
- `[DisassemblyDiagnoser]` — emitted asm; heavy, opt-in for deep dives.
- `BenchmarkDotNet.Diagnostics.Windows` (`[EtwProfiler]`, native counters) — Windows-only; referenced
  by codebelt benchmark projects but enable specific diagnosers only when needed.

## Jobs and runtimes

A **job** describes how to run a benchmark. The Codebelt runner starts from `BenchmarkWorkspaceOptions.Slim`
and you add jobs fluently in the runner's `Program.cs`:

```csharp
return c
    .AddJob(slimJob.WithRuntime(ClrRuntime.Net48))
    .AddJob(slimJob.WithRuntime(CoreRuntime.Core90))
    .AddJob(slimJob.WithRuntime(CoreRuntime.Core10_0));
```

Although `Codebelt.Extensions.BenchmarkDotNet` itself targets .NET 9/10, the **jobs** can measure
older and newer runtimes. Runtime moniker map:

| Target | Job runtime |
|--------|-------------|
| .NET Framework 4.8 | `ClrRuntime.Net48` (Windows only) |
| .NET 8 | `CoreRuntime.Core80` |
| .NET 9 | `CoreRuntime.Core90` |
| .NET 10 | `CoreRuntime.Core10_0` |
| Mono | `MonoRuntime.Default` |

Only add runtimes the benchmark project actually targets (its `TargetFrameworks` must include the
matching TFM, e.g. `net48` for `ClrRuntime.Net48`). Docs: https://benchmarkdotnet.org/articles/configs/jobs.html

Other useful job knobs (usually leave BenchmarkDotNet's smart defaults alone): `RunStrategy`
(`Throughput`/`ColdStart`/`Monitoring`), `WarmupCount`, `IterationCount`, `LaunchCount`, `Platform`,
`GcMode.Server`. Set these only for a specific reason.

## Running

BenchmarkDotNet requires a **Release** build. Through the Codebelt console runner:

```powershell
dotnet run -c Release --project tooling/{runner} -- --filter *{TypeName}Benchmark*
```

Common runner/BDN switches passed after `--`:

- `--filter <glob>` — select benchmarks by full name (`*DateSpanBenchmark*`, `*.Parse_*`).
- `--list flat` — list discovered benchmarks without running.
- `--job short` — a faster, less precise job for smoke checks.

Reports are written under `reports/`.
