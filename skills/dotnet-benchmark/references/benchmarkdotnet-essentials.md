# BenchmarkDotNet Essentials

Use this as a compact API and validation reference after the experiment question is defined. Official documentation: <https://benchmarkdotnet.org/articles/toc.html>.

## Core attributes

| Attribute | Purpose |
|---|---|
| `[Benchmark]` | Marks measured work. Add `Baseline = true` only inside an equivalent comparison group and use `Description` to name the real measured terminal operation or materialization step. |
| `[MemoryDiagnoser]` | Reports managed allocations and GC counts. Always include it for codebelt benchmarks. |
| `[BenchmarkCategory("...")]` | Labels logical comparison groups when one class contains multiple alternative pairs. |
| `[GroupBenchmarksBy(...)]` | Groups report rows by category, params, or a deliberate combination. Use it only when the grouping is meaningful for interpretation; remove decorative grouping. |
| `[Params(...)]` | Sweeps independent compile-time-constant values. Multiple params properties create a Cartesian product. |
| `[ParamsSource(nameof(...))]` | Supplies computed or coupled scenario objects with readable names. |
| `[Arguments(...)]` / `[ArgumentsSource]` | Supplies method arguments, useful for explicit scenario sets. |
| `[GlobalSetup]` / `[GlobalCleanup]` | Prepares and releases per-method/per-parameter state outside measurement. |
| `[IterationSetup]` / `[IterationCleanup]` | Resets per iteration but forces single invocation/unroll; avoid for tiny microbenchmarks. |

## Baselines

A method baseline adds a ratio distribution against equivalent methods. BenchmarkDotNet allows category-specific baselines when benchmarks are grouped by category, but every baseline category still needs at least one equivalent peer. Do not attach a baseline to an unrelated member or a lone benchmark just to satisfy a template.

Runtime comparisons can use a job baseline. Keep method, inputs, and implementation fixed when attributing a difference to runtime.

## Prevent invalid measurements

- Use Release builds and run without an attached debugger.
- Return or consume results to prevent dead-code elimination.
- Keep setup and correctness checks outside timed methods.
- Do not rely on execution order or shared mutation between methods.
- Avoid manual loops unless batching is the real workload; BenchmarkDotNet selects invocation counts automatically.
- Inspect all validation and environment warnings before reading result tables.
- Compare the discovered and reported method, job, and parameter matrix with the intended design; missing combinations are validation failures.
- Keep the machine powered and quiet for full runs unless the noisy/throttled environment is the intended target.

## Validators

BenchmarkDotNet always validates duplicate baselines. `ExecutionValidator` can smoke-execute cases and `ReturnValueValidator` can compare compatible return values, but domain-specific correctness checks remain necessary for every parameter and scenario case. Prefer exact checks for counts, values, status, exceptions, output contents, or mutations; use approximation only when the domain itself defines approximation. A Release build plus `--job dry` provides practical wiring and lifecycle validation through the codebelt runner, but zero-match boundary cases are still valid when the workload intends them.

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

`BenchmarkWorkspaceOptions.Slim` is the codebelt repository's deliberately shortened developer-oriented job. Report its active settings accurately instead of saying BenchmarkDotNet chose a fully adaptive warmup or iteration plan. In the current codebelt runner shape, Slim fixes one warmup iteration plus controlled iteration counts; that can characterize ordinary repository workloads, but one warmup may be insufficient for tiered-compilation, tiered-PGO, LINQ, or other JIT-sensitive runtime comparisons.

Do not silently replace the repository runner configuration. Use a more stable diagnostic job only when the runtime or JIT comparison is itself material and explicitly in scope. Short and dry jobs still validate or iterate quickly; they do not replace a valid full run for performance conclusions.

## Deferred pipelines and terminal operations

Distinguish between:

- query or iterator creation only;
- a terminal operation such as `Count()`, `Any()`, or `First()`;
- explicit full enumeration;
- materialization through `ToArray()` or `ToList()`.

Name the benchmark and its conclusion accordingly. Inspect collection fast paths before describing a result as enumeration. `List<T>.Count` can be O(1) while `Where(...).Count()` enumerates the filtered pipeline, so the former is not an honest baseline for the latter.

## Result-validity gate

After a dry execution and after any full run, inspect the complete BenchmarkDotNet summary before interpreting numbers. Treat the run as invalid for performance interpretation when any intended case has an `NA` measurement, appears under `Benchmarks with issues`, throws in setup or cleanup, triggers a validation error, fails a job or runtime, or is missing from the intended matrix.

If that happens, report the exact failing method, job, and parameter case. Do not let the surviving rows stand in for the completed benchmark. Correct benchmark-owned causes, rerun build, discovery, and dry validation, and require fresh human authority before any replacement full measurement run.

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

## Interpreting a full run

Read warnings before tables. Compare mean, error, standard deviation, median when distributions are skewed, ratio distributions within valid groups, allocated bytes, GC counts, and specialized diagnoser columns for the exact workload and environment.

After the first valid full result, answer three questions: is the result reproducible, is the absolute cost material for observed or plausible usage, and would a deeper diagnostic change a concrete engineering decision? Stop when the answer is no. Do not escalate automatically to repeated reruns, tiered-PGO variants, disassembly, EventPipe or ETW tracing, alternative implementations, or runtime-source archaeology. Escalate only when the result is reproducible, material, the next diagnostic can distinguish concrete competing explanations, and the user requested it or it is necessary to answer the original decision.

## Primary sources

- BenchmarkDotNet good practices: <https://benchmarkdotnet.org/articles/guides/good-practices.html>
- Parameterization: <https://benchmarkdotnet.org/articles/features/parameterization.html>
- Setup and cleanup: <https://benchmarkdotnet.org/articles/features/setup-and-cleanup.html>
- Baselines: <https://benchmarkdotnet.org/articles/features/baselines.html>
- Diagnosers: <https://benchmarkdotnet.org/articles/configs/diagnosers.html>
- Validators: <https://benchmarkdotnet.org/articles/configs/validators.html>
- .NET diagnostics overview: <https://learn.microsoft.com/dotnet/core/diagnostics/>
