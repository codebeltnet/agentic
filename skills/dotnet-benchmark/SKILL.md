---
name: dotnet-benchmark
description: >
  Discover, prioritize, and author trustworthy BenchmarkDotNet performance experiments for a .NET type while following codebelt engineering conventions and using the Codebelt.Extensions.BenchmarkDotNet Console runner. Use whenever a user wants to benchmark, micro-benchmark, performance-test, profile, optimize, compare implementations, investigate allocations or contention, or find likely bottlenecks in a .NET type or method. The skill inspects implementation code, call sites, tests, existing benchmarks, and available profiling evidence; ranks high-value operations instead of benchmarking every public member; selects representative workloads; rejects misleading microbenchmarks; creates or reuses the tuning/ and tooling/ harness; validates correctness and benchmark discovery; and keeps full performance runs explicit.
---

# Evidence-Driven .NET Benchmarking

Create the smallest benchmark suite that can answer the most valuable performance questions about the supplied type. Follow the repository's established conventions first, then apply the codebelt `tuning/` benchmark project and `tooling/` runner layout where the repository has no stronger local pattern.

## Critical benchmark contract

- Treat a benchmark as an experiment, not as public-member coverage. Do not benchmark every constructor, property, or method merely because it exists.
- A microbenchmark measures a suspected cost under a defined workload; it does not prove that the type is an application bottleneck. Prefer production telemetry or a CPU/allocation/contention profile when the user asks where an application is slow. If only a type is provided, perform source-informed candidate discovery and label the result as an exploratory benchmark plan.
- Rank candidates using evidence from the implementation, call sites, tests, documentation, existing benchmark results, and profiles. Never invent usage frequency, input distributions, or a competing implementation.
- Compare only operations that produce equivalent observable work. Do not use construction as the baseline for formatting, equality, hashing, parsing, or another unrelated operation.
- Use `Baseline = true` only when at least two benchmark methods form a meaningful comparison group. A single-operation scaling or regression benchmark needs no fabricated baseline. When a class has several comparison groups, assign categories and one baseline inside each category.
- Keep correctness outside the timed path but inside the verification workflow. Equivalent implementations must be checked on every benchmark case before a full run.
- Keep external I/O, network latency, database latency, sleeps, logging, and random data generation out of measured microbenchmark methods. Recommend profiling, a macrobenchmark, or a load test when those effects are the actual question.
- Always distinguish code that was built, smoke-executed, or fully measured. Never report performance numbers from a build, discovery listing, dry run, or unexecuted benchmark.

## Workflow

### 1. Resolve intent with minimal questioning

Read `FORMS.md` and use its one-field-at-a-time interaction only for information that is not already clear. A named type plus a request such as “find the likely bottlenecks” is sufficient to start inspection. Do not make the user choose an implementation tier or BenchmarkDotNet attributes.

Default to automatic candidate discovery, the runner's existing/default runtime, and build plus discovery and dry execution validation. Ask about extra runtimes only when cross-runtime comparison is part of the request. Require explicit user intent before a full benchmark run because it can be long and machine-sensitive.

### 2. Inspect the repository and harness

Run the bundled read-only detector before changing files:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/check-benchmark-requirements.ps1 -RepoRoot <repo-root>
```

Also inspect applicable `AGENTS.md`, solution/project files, `Directory.Build.props`, `Directory.Packages.props`, existing `tuning/` and `tooling/` projects, and nearby benchmark styles. Reuse an existing runner and benchmark project when they fit. Read `references/onboarding.md` only when the detector finds missing or partial harness infrastructure.

The .NET SDK is the only hard harness prerequisite. If detector status is `not-found`, report that blocker instead of generating unverified project files. If the probe is `timed-out`, `start-failed`, or `failed`, report the probe failure distinctly and verify the SDK through a safe direct check before concluding that it is absent.

### 3. Resolve the type and gather performance evidence

Locate the exact declaration, owning `src/` project, namespace, interfaces/base types, and target frameworks. Then read the complete implementation and inspect its collaborators, tests, call sites, documentation, existing benchmarks, and any profiling artifacts available in the repository or supplied by the user.

Read `references/candidate-selection.md` whenever the user has not already specified the exact operation and workload. Build an evidence-backed candidate matrix and select at most three performance questions for one benchmark class; prefer one focused question when it is clearly dominant.

Look beyond public methods. Private loops, repeated conversions, allocation-heavy helpers, hashing/equality used by collections, reflection, regex construction, buffer copies, parsing branches, locks, task scheduling, exception-heavy paths, and deferred enumeration can dominate the cost exposed by one public operation. Benchmark the public or internal entry point that represents the real consumer operation, not an arbitrary private helper, unless isolating that helper is the explicit experiment.

### 4. Decide whether BenchmarkDotNet is the right instrument

Use a microbenchmark when the work is deterministic, repeatable, isolatable, and small enough to execute many times. If the suspected cost is end-to-end I/O, request concurrency across a service, startup of a whole application, distributed latency, or an unknown application-wide hotspot, explain why a microbenchmark would mislead and propose the narrowest useful next instrument instead.

When profiling evidence exists, use it to choose the benchmark target. When it does not, state that selection is based on source and usage evidence rather than measured hotspot data. Do not silently turn a hypothesis into a claim.

### 5. Present the experiment plan

Before authoring code, present a compact plan with:

- the performance question and metric: latency/throughput, allocated bytes, scaling, contention, cold start, or exception frequency;
- the selected operation and the evidence that made it important;
- the baseline and candidate, if a fair comparison exists;
- representative cases, including typical, boundary, scaling, and adverse-but-valid inputs where relevant;
- setup/reset strategy and correctness oracle;
- candidates deliberately rejected and why;
- whether the result will be exploratory or grounded in profile/telemetry evidence.

Follow the confirmation flow in `FORMS.md`. If the user already named exact members, inputs, and implementations, confirm only material corrections or risks rather than repeating settled choices.

### 6. Design the experiment

Read `references/experiment-design.md` and `references/benchmarkdotnet-essentials.md`. Choose one of these shapes:

1. **Equivalent implementation comparison.** Use separate benchmark methods for current/reference and candidate implementations, feed them identical state, check equivalent results in setup, and mark the current production or established reference method as the baseline. Start from `assets/comparison-benchmark.cs`.
2. **Single-operation characterization.** Use one benchmark method across meaningful cases or sizes when the goal is absolute cost, scaling, allocation characterization, or future regression tracking and no honest competing implementation exists. Do not add a baseline solely to obtain a ratio column. Start from `assets/operation-benchmark.cs`.
3. **Independent operation groups.** Split unrelated operations into separate benchmark classes when practical. If a cohesive class contains multiple alternative pairs, use `[BenchmarkCategory]`, group by category, and assign one baseline per category. Never compare ratios across different semantic work.

Do not copy an asset blindly. The assets are structural examples with placeholders; adapt namespaces, types, cases, lifecycle, return consumption, correctness checks, and attributes to the real API.

### 7. Author the benchmark

Place the class under `tuning/{SutProject}.Benchmarks/`. Name it for the performance question and end the class name with `Benchmark`. Keep it in the SUT namespace rather than adding `.Benchmarks`; the benchmark project `RootNamespace` supports this codebelt convention.

Every benchmark should use deterministic state and `[MemoryDiagnoser]`. Add other diagnosers only when they answer the question: `[ThreadingDiagnoser]` for lock/thread-pool signals, `[ExceptionDiagnoser]` for intentional exception paths, `[DisassemblyDiagnoser]` for JIT/code-generation investigations, or EventPipe/ETW profiling for a targeted deep dive. Extra diagnosers often cause extra runs and platform constraints, so do not add them decoratively.

Keep setup outside the measured method unless setup is part of the consumer-visible operation. Return a result or consume it so the JIT cannot eliminate the work. Avoid independent `[Params]` axes that create meaningless Cartesian products; use a scenario object from `[ParamsSource]` or `[ArgumentsSource]` when inputs must vary together.

For mutating operations, ensure every measurement observes equivalent starting state without allowing reset cost to dominate a tiny operation. For async APIs, await the real `Task`/`ValueTask`; do not substitute `.Result` or benchmark a completed fake. For concurrency, measure a defined worker/contention scenario and avoid accidentally measuring task creation when shared-state throughput is the actual question.

### 8. Onboard only missing harness pieces

If the detector found missing infrastructure, follow `references/onboarding.md`. Resolve current stable package versions dynamically from NuGet.org, preserve central package management when present, reuse existing solution and folder conventions, create at most one runner, and avoid restructuring unrelated repository content.

### 9. Validate in layers

First validate the benchmark's correctness through existing tests or a setup-time oracle for every parameter case. Then build the benchmark project in Release:

```powershell
dotnet build -c Release tuning/{SutProject}.Benchmarks/{SutProject}.Benchmarks.csproj
```

Verify runner discovery without measuring:

```powershell
dotnet run -c Release --project tooling/{runner} -- --list flat --filter *{BenchmarkClass}*
```

Unless execution is impossible or the user declines, run a dry execution smoke check and inspect all BenchmarkDotNet validation warnings. A dry run proves executable wiring and basic lifecycle, not performance:

```powershell
dotnet run -c Release --project tooling/{runner} -- --job dry --filter *{BenchmarkClass}*
```

Run the full benchmark only when the user explicitly asks. Use an unplugged laptop, debugger, busy CI worker, VM, or power-throttled environment only if that environment is itself the target; otherwise warn that the results may not be stable or representative.

### 10. Report the outcome

Summarize the selected and rejected candidates, benchmark question, cases, correctness oracle, diagnosers, generated files, and validation commands/results. If a full run occurred, report environment, mean/median where relevant, error and standard deviation, ratios only within valid comparison groups, allocations/GC, warnings, and the workload-specific conclusion. Recommend an optimization only when measurements identify a meaningful opportunity and correctness remains protected.

## Completion checklist

- [ ] Candidate selection is supported by implementation, usage, tests, telemetry, or profiling evidence.
- [ ] The suite answers one to three explicit performance questions and excludes low-value member coverage.
- [ ] Baselines compare equivalent work; single operations and unrelated members have no misleading ratio.
- [ ] Cases represent realistic, boundary, scaling, and adverse paths without useless Cartesian products.
- [ ] Setup, mutation, async, concurrency, disposal, and result consumption are handled correctly.
- [ ] Equivalent implementations pass a correctness oracle for every case.
- [ ] `[MemoryDiagnoser]` is present and every additional diagnoser has a stated purpose.
- [ ] Harness changes preserve repository conventions and reuse existing projects/runner where possible.
- [ ] Release build, benchmark discovery, and dry execution succeed, or exact blockers are reported.
- [ ] Full-run performance claims are made only from an actual full run in a described environment.
- [ ] Generated files are UTF-8 without mojibake, and no unrelated files were changed.
