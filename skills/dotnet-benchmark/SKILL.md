---
name: dotnet-benchmark
description: >
  Discover, prioritize, and author trustworthy BenchmarkDotNet performance experiments for a .NET type while following codebelt engineering conventions and using the Codebelt.Extensions.BenchmarkDotNet Console runner. Use whenever a user wants to benchmark, micro-benchmark, performance-test, profile, optimize, compare implementations, investigate allocations or contention, or find likely bottlenecks in a .NET type or method. The skill inspects source and usage evidence, ranks high-value operations instead of every public member, selects representative workloads, rejects misleading microbenchmarks, creates or reuses the tuning/ and tooling/ harness, preflights existing-report skips, semantic-preflights workload correctness, validates discovery, and keeps full runs human-initiated. When the user says yolo, it auto-accepts routine defaults and proceeds through safe validation without confirmation churn.
---

# Evidence-Driven .NET Benchmarking

Create the smallest benchmark suite that can answer the most valuable performance questions about the supplied type. Follow the repository's established conventions first, then apply the codebelt `tuning/` benchmark project and `tooling/` runner layout where the repository has no stronger local pattern.

## Critical benchmark contract

- Treat a benchmark as an experiment, not as public-member coverage. Do not benchmark every constructor, property, or method merely because it exists.
- A microbenchmark measures a suspected cost under a defined workload; it does not prove that the type is an application bottleneck. Prefer production telemetry or a CPU/allocation/contention profile when the user asks where an application is slow. If only a type is provided, perform source-informed candidate discovery and label the result as an exploratory benchmark plan.
- Rank candidates using evidence from the implementation, call sites, tests, documentation, existing benchmark results, and profiles. Never invent usage frequency, input distributions, or a competing implementation.
- Compare only operations that produce equivalent observable work. Do not use construction as the baseline for formatting, equality, hashing, parsing, or another unrelated operation.
- Use `Baseline = true` only when at least two benchmark methods form a meaningful comparison group. A single-operation scaling or regression benchmark needs no fabricated baseline. When a class has several comparison groups, assign categories and one baseline inside each category.
- Before accepting `Baseline = true`, answer: do the baseline and candidate perform equivalent consumer-visible work over identical logical input? If not, remove the baseline or split the experiment.
- Before build or dry validation, inspect benchmark attributes for internal coherence: `Baseline = true` only on equivalent observable work, `[GroupBenchmarksBy(BenchmarkLogicalGroupRule.ByCategory)]` only with meaningful `[BenchmarkCategory]` values, every baseline category has an equivalent peer, single-operation characterization benchmarks have no fabricated baseline, benchmark descriptions name the real measured terminal operation, and decorative grouping attributes are removed.
- Keep correctness outside the timed path but inside the verification workflow. Every scenario must define the input, intended operation, exact expected observable result, how that result was derived independently of the measured API path, and any promised workload characteristic such as selectivity, hit rate, type mix, or branch distribution. Successful execution is not a correctness oracle. Every parameter or scenario case needs exact observable-result validation for count, value, status, exception behavior, output contents, or mutation unless the domain explicitly defines approximation. Valid zero-match cases stay valid; if a zero result is unintended, fix the workload before measurement.
- When one parameter only scales size, payload, or another magnitude, keep selectivity, hit/miss ratio, valid/invalid ratio, branch distribution, collision rate, string shape/encoding, type mix, entropy, and cache state stable unless one of them is intentionally exposed as a named scenario or parameter.
- A benchmark is invalid for performance interpretation until the complete BenchmarkDotNet summary shows the full intended method/job/parameter matrix without `NA`, `Benchmarks with issues`, setup/cleanup exceptions, validation errors, failed jobs/runtimes, or missing combinations. Report the exact failing method, job, and parameter case, do not treat surviving rows as a completed benchmark, fix only benchmark-owned causes, rerun build/list/dry validation, and require fresh explicit human authority before any replacement full run.
- Treat deferred pipeline creation, terminal operations such as `Count()`, `Any()`, or `First()`, explicit full enumeration, and materialization through `ToArray()` or `ToList()` as different workloads. Inspect fast paths such as `List<T>.Count` before describing a benchmark as enumeration or using it as the baseline for predicate traversal.
- Keep external I/O, network latency, database latency, sleeps, logging, and random data generation out of measured microbenchmark methods. Recommend profiling, a macrobenchmark, or a load test when those effects are the actual question.
- Always distinguish code that was built, smoke-executed, or fully measured. Never report performance numbers from a build, discovery listing, dry run, or unexecuted benchmark.
- Start a full performance run only after an explicit human instruction to run it now. Never infer that authority from yolo mode, defaults, plan acceptance, an agent recommendation, or the existence of a runnable benchmark.
- When a Codebelt runner appears to list or execute nothing, inspect `SkipBenchmarksWithReports` and matching `reports/tuning/` artifacts before changing benchmark code. An existing report is an expected skip condition, not a reason to rename a lean class or add diagnosers.

## Workflow

### 1. Resolve intent with minimal questioning

Read `FORMS.md` and use its one-field-at-a-time interaction only for information that is not already clear. A named type plus a request such as “find the likely bottlenecks” is sufficient to start inspection. Do not make the user choose an implementation tier or BenchmarkDotNet attributes.

Default to automatic candidate discovery, the runner's existing/default runtime, and build plus discovery and dry execution validation. Ask about extra runtimes only when cross-runtime comparison is part of the request. Require an explicit human instruction before a full benchmark run because it can be long and machine-sensitive.

#### Yolo mode

Activate yolo mode only when the current request explicitly says `yolo`, `yolo mode`, `auto-proceed`, or an equally clear instruction to use defaults without routine confirmation. The mode applies to the current benchmark task only; do not persist it into later requests.

In yolo mode:

- infer automatic candidate discovery unless the user already supplied a more specific performance intent;
- use the strongest defensible workload and repository conventions from source, call sites, tests, profiles, and existing benchmarks, recording material assumptions instead of asking the user to approve a 99%-certain default;
- present the compact experiment plan as a progress update and continue immediately without asking `candidate_plan_confirmation`;
- select build, discovery listing, and dry execution as the default validation depth without asking `execution_depth`;
- stop and ask only when a missing fact creates material correctness/design risk and no safe repo-derived choice exists, or when new authority is required;
- preserve all benchmark-quality, repository, and safety gates. Yolo is a convenience mode, not permission to invent workloads, ignore blockers, run unrelated operations, commit, push, or make external changes.

Yolo never authorizes a full performance run. Start the full benchmark only when the human explicitly asks to run or measure it fully now; otherwise stop after build/list/dry validation. An agent must not promote its own recommendation into that authority.

### 2. Inspect the repository and harness

Run the bundled read-only detector before changing files:

```console
pwsh -NoProfile -File <skill-root>/scripts/check-benchmark-requirements.ps1 -RepoRoot <repo-root>
```

If `pwsh` 7+ is unavailable, report that blocker instead of falling back to legacy Windows PowerShell.

Also inspect applicable `AGENTS.md`, solution/project files, `Directory.Build.props`, `Directory.Packages.props`, existing `tuning/` and `tooling/` projects, and nearby benchmark styles. Reuse an existing runner and benchmark project when they fit. Read `references/onboarding.md` only when the detector finds missing or partial harness infrastructure.

When investigating a benchmark that builds but is not listed or executed, read `references/runner-preflight.md` before inspecting or rewriting the benchmark class. Rerun the detector with `-BenchmarkType <Namespace.TypeBenchmark>` and inspect the reported runner program, `SkipBenchmarksWithReports` setting, slim/runtime jobs, `reports/tuning/` files, and `wouldSkipRequestedBenchmark`. If a matching existing report explains the skip, preserve the runner and benchmark unchanged, report the matching file, and stop diagnostic escalation. Do not add disassembly, rename the class, disable report skipping, or churn through tools to evade the filter.

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
- representative cases, including typical, boundary, scaling, and adverse-but-valid inputs where relevant, plus any named workload characteristic such as selectivity, hit rate, type mix, or branch distribution;
- setup/reset strategy and correctness oracle, including how each exact expected result is derived independently of the benchmark method;
- candidates deliberately rejected and why;
- whether the result will be exploratory or grounded in profile/telemetry evidence.

Follow the confirmation flow in `FORMS.md` in interactive mode. In yolo mode, post the plan as a concise progress update and proceed without confirmation. If the user already named exact members, inputs, and implementations, confirm only material corrections or risks rather than repeating settled choices.

### 6. Design the experiment

Read `references/experiment-design.md` and `references/benchmarkdotnet-essentials.md`. Choose one of these shapes:

1. **Equivalent implementation comparison.** Use separate benchmark methods for current/reference and candidate implementations, feed them identical state, check equivalent results in setup, and mark the current production or established reference method as the baseline. Start from `assets/comparison-benchmark.cs`.
2. **Single-operation characterization.** Use one benchmark method across meaningful cases or sizes when the goal is absolute cost, scaling, allocation characterization, or future regression tracking and no honest competing implementation exists. Do not add a baseline solely to obtain a ratio column. Start from `assets/operation-benchmark.cs`.
3. **Independent operation groups.** Split unrelated operations into separate benchmark classes when practical. If a cohesive class contains multiple alternative pairs, use `[BenchmarkCategory]`, group by category, and assign one baseline per category. Never compare ratios across different semantic work.

Do not copy an asset blindly. The assets are structural examples with placeholders; adapt namespaces, types, cases, lifecycle, return consumption, correctness checks, and attributes to the real API.

When a parameter is only size or payload, preserve the other workload characteristics unless the experiment names them explicitly. For predicate or filter benchmarks, state the intended selectivity, use deterministic data, prefer fixed-width or otherwise structurally stable inputs when digit length or formatting would change the branch mix, and verify the exact expected match count for every scenario.

If a case label promises an exact percentage such as `10% selectivity`, make that statement true for every size under a documented rounding rule. Otherwise choose compatible sizes, define explicit scenario objects with exact expected counts, or rename the cases honestly with qualitative names such as `LowSelectivity`, `HalfMatches`, or `AllMatch`.

For LINQ and other deferred pipelines, decide whether the benchmark measures query or iterator creation, a terminal operation, explicit enumeration, or materialization. Encode that distinction in names, descriptions, baselines, and conclusions; `List<T>.Count` and `Where(...).Count()` are not interchangeable evidence.

For `QueryFor<T>`-style runtime-type filters, use deterministic heterogeneous input with exact matches, sibling nonmatches, derived types when exact-type versus assignability semantics matter, and nulls only when supported and relevant. Validate the exact expected count and, when it matters, insertion order and exact runtime types. Do not benchmark a homogeneous all-match store and call it type filtering unless that all-match path is the stated subject.

### 7. Author the benchmark

Place the class under `tuning/{SutProject}.Benchmarks/`. Name it for the performance question and end the class name with `Benchmark`. Keep it in the SUT namespace rather than adding `.Benchmarks`; the benchmark project `RootNamespace` supports this codebelt convention.

Every benchmark should use deterministic state and `[MemoryDiagnoser]`. Add other diagnosers only when they answer the question: `[ThreadingDiagnoser]` for lock/thread-pool signals, `[ExceptionDiagnoser]` for intentional exception paths, `[DisassemblyDiagnoser]` for JIT/code-generation investigations, or EventPipe/ETW profiling for a targeted deep dive. Extra diagnosers often cause extra runs and platform constraints, so do not add them decoratively.

Keep setup outside the measured method unless setup is part of the consumer-visible operation. Return a result or consume it so the JIT cannot eliminate the work. Avoid independent `[Params]` axes that create meaningless Cartesian products; use a scenario object from `[ParamsSource]` or `[ArgumentsSource]` when inputs must vary together.

For mutating operations, ensure every measurement observes equivalent starting state without allowing reset cost to dominate a tiny operation. For async APIs, await the real `Task`/`ValueTask`; do not substitute `.Result` or benchmark a completed fake. For concurrency, measure a defined worker/contention scenario and avoid accidentally measuring task creation when shared-state throughput is the actual question.

### 8. Onboard only missing harness pieces

If the detector found missing infrastructure, follow `references/onboarding.md`. Resolve current stable package versions dynamically from NuGet.org, preserve central package management when present, reuse existing solution and folder conventions, create at most one runner, and avoid restructuring unrelated repository content.

### 9. Validate in layers

Before the build, inspect the benchmark attributes for coherence and remove decorative configuration that no longer serves the question.

Run a semantic preflight across the full Cartesian set of benchmark methods, parameter values, runtime jobs, and scenario objects before build, discovery, dry execution, or any request for a full run. For every case verify that setup succeeds, the exact expected output is known independently, the actual output matches, the named workload characteristic is true, the intended code path is exercised, and the case does not collapse into a trivial fast path unless that fast path is the stated subject.

Semantic preflight
- Every scenario has an independently derived exact expected result.
- Every parameter combination satisfies that oracle.
- Benchmark names accurately describe the generated workload.
- Selectivity, hit rate, type mix, and other workload distributions are explicit and verified.
- Every benchmark exercises the intended path.
- Baselines compare equivalent observable work.

Successful execution is not a correctness oracle. After semantic preflight, validate the benchmark's correctness through existing tests or a setup-time oracle for every parameter case. The oracle should normally verify exact observable behavior rather than merely nonzero or approximate success unless that is the real domain contract. Then build the benchmark project in Release:

```console
dotnet build -c Release tuning/{SutProject}.Benchmarks/{SutProject}.Benchmarks.csproj
```

Before interpreting discovery or execution output, run the report-aware preflight for the exact class:

```console
pwsh -NoProfile -File <skill-root>/scripts/check-benchmark-requirements.ps1 -RepoRoot <repo-root> -BenchmarkType <Namespace.TypeBenchmark>
```

If `pwsh` 7+ is unavailable, report that blocker instead of falling back to legacy Windows PowerShell.

If `reports.wouldSkipRequestedBenchmark` is true, the runner is intentionally filtering the type because a prior report exists. Report that as the validation outcome; do not claim the list/dry run exercised the class and do not modify code to force it through. A fresh full run and any report archive/replacement require explicit human direction.

Verify runner discovery without measuring:

```console
dotnet run -c Release --project tooling/{runner} -- --list flat --filter *{BenchmarkClass}*
```

Compare the discovered method, job, and parameter matrix with the intended design. Missing or surprise combinations are validation failures, not report quirks.

Unless execution is impossible or the user declines, run a dry execution smoke check and inspect all BenchmarkDotNet validation warnings. A dry run proves executable wiring and basic lifecycle, not performance:

```console
dotnet run -c Release --project tooling/{runner} -- --job dry --filter *{BenchmarkClass}*
```

Inspect the complete BenchmarkDotNet summary after the dry run and before reading any numbers. If any intended case shows `NA`, appears under `Benchmarks with issues`, throws in setup or cleanup, triggers a validation error, fails a job or runtime, or is missing from the intended matrix, report the exact failing method, job, and parameter case. Do not interpret successful rows as the completed benchmark. Correct the benchmark design only when the cause is within the benchmark, then rerun build, discovery, and dry validation.

Run the full benchmark only when the human explicitly asks to start it. Use an unplugged laptop, debugger, busy CI worker, VM, or power-throttled environment only if that environment is itself the target; otherwise warn that the results may not be stable or representative.

After any full run, apply the same full-summary validity gate before interpreting the tables. If rerunning is necessary because of a benchmark-owned issue, preserve the human-authority rule and get explicit approval before starting another full measurement run.

### 10. Report the outcome

Summarize the selected and rejected candidates, benchmark question, cases, correctness oracle, diagnosers, generated files, and validation commands/results. If dry or full execution exposed an invalid case, report that invalid experiment instead of a performance conclusion.

If a full run occurred, report the environment, active job shape, mean/median where relevant, error and standard deviation, ratios only within valid comparison groups, allocations/GC, warnings, and the workload-specific conclusion. When the runner uses `BenchmarkWorkspaceOptions.Slim`, report that shortened job accurately and mention its warmup/iteration limits whenever they matter to interpretation, especially for runtime- or JIT-sensitive comparisons.

After the first valid full result, answer three questions: is the result reproducible, is the absolute cost material for observed or plausible usage, and would a deeper diagnostic change a concrete engineering decision? Stop when the answer does not justify further work. Do not automatically escalate to repeated full reruns, tiered-PGO variants, disassembly, EventPipe or ETW tracing, alternative implementations, or runtime-source archaeology. Escalate only when the result is reproducible, material, the next diagnostic can distinguish concrete competing explanations, and the user requested it or it is necessary to answer the original decision. For low-microsecond test-support utilities with no credible production change, prefer a concise "no change justified" conclusion.

## Completion checklist

- [ ] Candidate selection is supported by implementation, usage, tests, telemetry, or profiling evidence.
- [ ] The suite answers one to three explicit performance questions and excludes low-value member coverage.
- [ ] Baselines compare equivalent work; single operations and unrelated members have no misleading ratio.
- [ ] Cases represent realistic, boundary, scaling, and adverse paths without useless Cartesian products, and size-only sweeps keep other workload invariants stable unless explicitly named.
- [ ] Setup, mutation, async, concurrency, disposal, and result consumption are handled correctly.
- [ ] Exact correctness oracles cover every parameter and scenario case, including valid zero-match boundaries.
- [ ] A semantic preflight covered every method/param/job/scenario combination with independently derived expected results, truthful workload labels, intended code paths, and no accidental fast paths.
- [ ] Baselines, categories, grouping attributes, and descriptions are internally coherent and non-decorative.
- [ ] `[MemoryDiagnoser]` is present and every additional diagnoser has a stated purpose.
- [ ] Harness changes preserve repository conventions and reuse existing projects/runner where possible.
- [ ] Runner preflight accounts for `SkipBenchmarksWithReports`, configured slim/runtime jobs, and any matching `reports/tuning/` artifact before benchmark-code diagnosis.
- [ ] Release build, benchmark discovery, and dry execution succeed, or exact blockers are reported.
- [ ] The complete discovery/dry/full summary covers the full intended matrix with no `NA`, `Benchmarks with issues`, failed jobs, or missing cases before any performance interpretation.
- [ ] Full-run performance claims are made only from an actual full run in a described environment, and any Slim-job limitation or other warning is reported honestly.
- [ ] After the first valid full result, deeper diagnostics or reruns are justified by a reproducible, material, decision-changing question rather than sunk cost.
- [ ] Generated files are UTF-8 without mojibake, and no unrelated files were changed.
