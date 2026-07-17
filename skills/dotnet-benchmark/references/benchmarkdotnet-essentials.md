# BenchmarkDotNet Essentials

Use this as a compact API and validation reference after the experiment question is defined. Official documentation: <https://benchmarkdotnet.org/articles/toc.html>.

## Core attributes

| Attribute | Purpose |
|---|---|
| `[Benchmark]` | Marks measured work. Add `Baseline = true` only inside an equivalent comparison group and use `Description` for readable reports. |
| `[MemoryDiagnoser]` | Reports managed allocations and GC counts. Always include it for codebelt benchmarks. |
| `[BenchmarkCategory("...")]` | Labels logical comparison groups when one class contains multiple alternative pairs. |
| `[GroupBenchmarksBy(...)]` | Groups report rows by category, params, or a deliberate combination. Grouping changes presentation and baseline scope; choose it from the question. |
| `[Params(...)]` | Sweeps independent compile-time-constant values. Multiple params properties create a Cartesian product. |
| `[ParamsSource(nameof(...))]` | Supplies computed or coupled scenario objects with readable names. |
| `[Arguments(...)]` / `[ArgumentsSource]` | Supplies method arguments, useful for explicit scenario sets. |
| `[GlobalSetup]` / `[GlobalCleanup]` | Prepares and releases per-method/per-parameter state outside measurement. |
| `[IterationSetup]` / `[IterationCleanup]` | Resets per iteration but forces single invocation/unroll; avoid for tiny microbenchmarks. |

## Baselines

A method baseline adds a ratio distribution against equivalent methods. BenchmarkDotNet allows category-specific baselines when benchmarks are grouped by category. Do not attach a baseline to an unrelated member or a lone benchmark just to satisfy a template.

Runtime comparisons can use a job baseline. Keep method, inputs, and implementation fixed when attributing a difference to runtime.

## Prevent invalid measurements

- Use Release builds and run without an attached debugger.
- Return or consume results to prevent dead-code elimination.
- Keep setup and correctness checks outside timed methods.
- Do not rely on execution order or shared mutation between methods.
- Avoid manual loops unless batching is the real workload; BenchmarkDotNet selects invocation counts automatically.
- Inspect all validation and environment warnings before reading result tables.
- Keep the machine powered and quiet for full runs unless the noisy/throttled environment is the intended target.

## Validators

BenchmarkDotNet always validates duplicate baselines. `ExecutionValidator` can smoke-execute cases and `ReturnValueValidator` can compare compatible return values, but domain-specific correctness checks remain necessary. A Release build plus `--job dry` provides practical wiring/lifecycle validation through the codebelt runner.

## Diagnosers and profilers

- `[MemoryDiagnoser]`: allocations and GC, always enabled by this skill.
- `[ThreadingDiagnoser]`: completed thread-pool work items and monitor lock contention on .NET Core 3+.
- `[ExceptionDiagnoser]`: exception frequency for intentional exception-path experiments.
- `[DisassemblyDiagnoser]`: generated code; heavy and subject to toolchain/platform restrictions.
- EventPipe profiler: cross-platform CPU/GC/JIT trace artifacts for a targeted deep dive.
- ETW/native hardware diagnostics: Windows/privilege/toolchain restrictions; opt in only when needed.

Diagnosers may require separate runs and increase duration.

## Jobs and runtimes

The codebelt runner starts from `BenchmarkWorkspaceOptions.Slim`. Add runtime jobs only for an explicit cross-runtime question:

```csharp
var slimJob = BenchmarkWorkspaceOptions.Slim;
return c
    .AddJob(slimJob.WithRuntime(ClrRuntime.Net48))
    .AddJob(slimJob.WithRuntime(CoreRuntime.Core80))
    .AddJob(slimJob.WithRuntime(CoreRuntime.Core90))
    .AddJob(slimJob.WithRuntime(CoreRuntime.Core10_0));
```

| Target | Job runtime |
|---|---|
| .NET Framework 4.8 | `ClrRuntime.Net48` (Windows only) |
| .NET 8 | `CoreRuntime.Core80` |
| .NET 9 | `CoreRuntime.Core90` |
| .NET 10 | `CoreRuntime.Core10_0` |

Only add jobs that the SUT and benchmark toolchain can execute. Keep the runner-default-only template as `return c;` with no unused runtime `using` directives.

Let BenchmarkDotNet choose warmup, iteration, launch, and invocation counts unless the performance question requires cold start, monitoring, or another specific run strategy. Short/dry jobs validate or iterate quickly; they do not replace the default job for performance conclusions.

## Existing-report filtering

Codebelt library runners normally set `SkipBenchmarksWithReports = true`. The console runner filters a loaded `*Benchmark` type when a matching report already exists under the artifacts tuning folder, normally `reports/tuning/`. Therefore a successful build followed by an empty list/dry/full invocation can be expected behavior.

Run the bundled detector with `-BenchmarkType <Namespace.TypeBenchmark>` and inspect its runner/report fields before changing a benchmark or adding diagnostics. Read `runner-preflight.md` for the matching rule and the no-thrashing workflow. Never rename a class, add disassembly, or disable the option merely to evade an existing report.

## Runner commands

Build:

```powershell
dotnet build -c Release tuning/{SutProject}.Benchmarks/{SutProject}.Benchmarks.csproj
```

List cases without measuring:

```powershell
dotnet run -c Release --project tooling/{runner} -- --list flat --filter *{BenchmarkClass}*
```

Dry execution smoke:

```powershell
dotnet run -c Release --project tooling/{runner} -- --job dry --filter *{BenchmarkClass}*
```

Full default run:

```powershell
dotnet run -c Release --project tooling/{runner} -- --filter *{BenchmarkClass}*
```

Reports are written under `reports/`.

## Primary sources

- BenchmarkDotNet good practices: <https://benchmarkdotnet.org/articles/guides/good-practices.html>
- Parameterization: <https://benchmarkdotnet.org/articles/features/parameterization.html>
- Setup and cleanup: <https://benchmarkdotnet.org/articles/features/setup-and-cleanup.html>
- Baselines: <https://benchmarkdotnet.org/articles/features/baselines.html>
- Diagnosers: <https://benchmarkdotnet.org/articles/configs/diagnosers.html>
- Validators: <https://benchmarkdotnet.org/articles/configs/validators.html>
- .NET diagnostics overview: <https://learn.microsoft.com/dotnet/core/diagnostics/>
