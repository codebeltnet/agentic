# Codebelt Runner Preflight

Use this reference before diagnosing a benchmark that builds but is not listed or executed. Codebelt runners commonly enable `SkipBenchmarksWithReports`, so an existing report can make a healthy benchmark appear to do nothing.

## Canonical runner shape

The runtime list varies by repository TFMs; the surrounding setup should stay lean and recognizable:

```csharp
using Codebelt.Extensions.BenchmarkDotNet;
using Codebelt.Extensions.BenchmarkDotNet.Console;
using BenchmarkDotNet.Configs;
using BenchmarkDotNet.Environments;
using BenchmarkDotNet.Jobs;

namespace benchmark_runner;

public class Program
{
    public static void Main(string[] args)
    {
        BenchmarkProgram.Run(args, o =>
        {
            o.AllowDebugBuild = BenchmarkProgram.IsDebugBuild;
            o.SkipBenchmarksWithReports = true;
            o.ConfigureBenchmarkDotNet(c =>
            {
                var slimJob = BenchmarkWorkspaceOptions.Slim;
                return c
                    .AddJob(slimJob.WithRuntime(ClrRuntime.Net48))
                    .AddJob(slimJob.WithRuntime(CoreRuntime.Core90))
                    .AddJob(slimJob.WithRuntime(CoreRuntime.Core10_0));
            });
        });
    }
}
```

Default-runtime-only runners intentionally omit the runtime/job usings and `slimJob`, leaving `ConfigureBenchmarkDotNet` as `return c;`.

## Why a benchmark can be skipped

With `SkipBenchmarksWithReports = true`, the Codebelt console runner enumerates files under the configured BenchmarkDotNet artifacts path plus the tuning folder, normally `reports/tuning/`. For each report, it takes the filename portion before the first `-`, then the final dotted segment, and compares that value case-insensitively with loaded types whose names end in `Benchmark`. A matching report adds a filter that excludes that entire benchmark type.

For example, `reports/tuning/Acme.Core.ParserBenchmark-report-github.md` causes `ParserBenchmark` to be filtered. This is expected idempotent runner behavior, not evidence that the benchmark class, filter, diagnoser, namespace, or method name is wrong.

## Preflight sequence

1. Build the benchmark project in Release. Stop on a compiler error; report it directly.
2. Run the detector with the intended benchmark type:

   ```powershell
   powershell -NoProfile -ExecutionPolicy Bypass -File scripts/check-benchmark-requirements.ps1 -RepoRoot <repo-root> -BenchmarkType <Namespace.TypeBenchmark>
   ```

3. Inspect `runner.programPath`, `runner.skipBenchmarksWithReports`, `runner.usesSlimJob`, `runner.configuredRuntimes`, `reports.tuningPath`, `reports.matchingReportFiles`, and `reports.wouldSkipRequestedBenchmark`.
4. Verify that configured runtime jobs match the repository's supported TFMs. The TFM list is the normal variable; do not rewrite the runner merely to make it look different.
5. If `wouldSkipRequestedBenchmark` is true, explain that the existing report deliberately suppresses the type. Treat an empty list/dry/full invocation as accounted for and leave the benchmark class and runner unchanged.
6. Only investigate filters, discovery, class visibility, attributes, toolchains, or diagnosers when the report preflight does not explain the behavior.

## Rerun boundary

Do not delete, move, overwrite, or ignore reports automatically. Do not flip `SkipBenchmarksWithReports` to false or rename a benchmark to evade the filter. Those actions discard the runner's intentional idempotency and can create duplicate or misleading result history.

If the human explicitly requests a fresh full run, report the matching files and ask them to choose the repository's accepted report-retention action, such as archive/replace. After that explicit choice, preserve the canonical runner setup and rerun the same benchmark type. Yolo mode never supplies the human authorization for the full run or report replacement.

## Anti-thrashing rule

An existing matching report is a terminal explanation for runner-level skipping. Do not respond by adding `DisassemblyDiagnoser`, changing benchmark attributes, expanding tool calls, renaming a slim class, or rewriting a focused benchmark. Diagnostics and class changes must answer a separate evidence-backed performance question, not work around report filtering.
