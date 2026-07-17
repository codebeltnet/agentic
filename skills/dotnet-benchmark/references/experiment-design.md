# Designing Trustworthy BenchmarkDotNet Experiments

Use this reference after candidate selection. Every benchmark method should answer a stated performance question with representative inputs and controlled conditions.

## Define the experiment before the attributes

Write down:

- the operation and consumer-visible behavior being measured;
- the primary metric: time/throughput, allocations, scaling, contention, cold start, or exception frequency;
- baseline and candidate implementations, if both exist;
- parameter cases and why each can change the result;
- setup/reset/disposal strategy;
- a correctness oracle;
- environmental variables that must remain fixed.

If these cannot be defined, more inspection is needed. Attributes do not rescue an ambiguous experiment.

## Comparison semantics

A baseline exists to create a meaningful ratio. Use the current production implementation or an established reference implementation as the baseline when all methods in the group perform equivalent observable work on identical input.

Do not compare unrelated operations. Construction, parsing, formatting, equality, hashing, copying, and validation answer different questions. Give them separate classes, or use explicit `[BenchmarkCategory]` groups with one baseline inside each group only when every category has alternatives.

For a single current implementation measured across sizes or scenarios, omit `Baseline = true`. The parameter columns and absolute time/allocation results already describe scaling. A fake baseline adds no evidence.

When comparing runtimes rather than implementations, use a job baseline and keep the measured method the same. Do not mix runtime and algorithm changes in one conclusion unless the full matrix is intentional.

## Configuration coherence

Before build, list, or dry validation, read the attributes back as a matrix:

- `Baseline = true` only where methods do equivalent observable work.
- `[GroupBenchmarksBy(BenchmarkLogicalGroupRule.ByCategory)]` only when meaningful `[BenchmarkCategory]` values exist.
- Every category with a baseline contains at least one equivalent comparison method.
- Single-operation characterization benchmarks do not invent a method baseline.
- `[Benchmark(Description = "...")]` names the real measured terminal operation or materialization step.
- Remove grouping attributes that do not improve interpretation.

## Representative inputs

Prefer cases grounded in real usage. Typical input should come first; add boundaries and adverse cases only when they exercise a distinct path.

Examples:

- Parsers: valid typical, valid large, invalid early, invalid late, escaped/culture-sensitive when supported.
- Match/search: hit early, hit late, miss, simple pattern, complex pattern, realistic lengths.
- Collections: empty/small/typical/large, hit/miss, collision-heavy only when plausible, pre-sized versus growth only if that is the question.
- Hash/codec/compression: representative size distribution and content entropy, not only zero-filled or arbitrary random buffers.
- Equality/hashing: equal, unequal-early, unequal-late, and actual dictionary/set usage when that is the consumer operation.
- Caches: warm hit, miss/fill, eviction, and contention as separate questions.

Use `[Params]` for independent scalar dimensions and `[ParamsSource]`/`[ArgumentsSource]` for coupled cases. Give complex case objects stable readable names through `ToString()` so reports are interpretable.

Keep the case count disciplined. Each parameter combination multiplies methods, jobs, launch count, and diagnoser runs. Three representative sizes usually tell more than a dense power-of-two sweep; add points only when they locate a threshold or crossover.

## Workload invariants

When one parameter only scales size, payload length, or another magnitude, keep other workload characteristics stable unless one is intentionally varied as its own named scenario. Common invariants include predicate selectivity or match percentage, hit/miss ratio, valid/invalid ratio, branch distribution, collision rate, string-length or encoding distribution, type distribution, entropy, and cache state.

If one of those characteristics should vary, make it an explicit scenario or parameter instead of letting it drift accidentally with size.

For predicate and filter benchmarks:

- state the intended selectivity;
- use deterministic data;
- prefer fixed-width or structurally stable inputs when digit length or formatting would otherwise move cases between branches;
- verify the exact expected match count for every scenario, including valid zero-match cases.

## Setup, state, and disposal

Use `[GlobalSetup]` for deterministic state that is not part of the operation: payload creation, parsing expected results, object construction for instance methods, and correctness checks. BenchmarkDotNet runs global setup for each benchmark method and parameter combination, so setup must not rely on another benchmark method having run first.

Use `[GlobalCleanup]` for resources owned by the benchmark. Avoid external I/O resources in microbenchmarks; cleanup does not remove their measurement noise.

Mutating operations need equivalent starting state. Options include:

- create or clone state inside every benchmark method when that creation is genuinely part of the compared operation and both sides pay the same cost;
- benchmark a representative batch/sequence over prebuilt state and use `OperationsPerInvoke` when per-operation normalization remains honest;
- use iteration setup only for macro-scale operations where forced single-invocation behavior will not dominate.

`[IterationSetup]` forces one invocation/unroll factor and can distort tiny operations. Do not use it reflexively to reset a nanosecond-scale benchmark.

Avoid state leakage between methods, params, warmup, and measurement. Never depend on benchmark execution order.

## Correctness oracle

An optimization benchmark without correctness validation can reward wrong code. Before a full run:

1. Execute baseline and candidate for every scenario outside the timed method.
2. Compare exact observable results with the domain's real equivalence rule, including counts, values, status codes, exceptions, output buffers, mutations, and side effects.
3. Fail setup or a focused test when results differ.
4. Keep the assertion/check out of the timed path.

Approximate checks are acceptable only when approximation is part of the domain semantics and the benchmark documents that rule. A valid boundary case that produces zero matches must still pass; only unexpected zero results should fail setup and force workload redesign.

For non-equivalent APIs, do not force a comparison. Characterize them separately and state the semantic difference.

BenchmarkDotNet's `ReturnValueValidator` can supplement this for compatible return values, but it does not replace domain-aware correctness checks.

## Prevent dead-code elimination and accidental work

Return the computed result whenever practical. For `void`, ref-like, or multi-output work, consume observable outputs with `BenchmarkDotNet.Engines.Consumer` or return a stable derived value. Do not return a precomputed field while discarding the measured call.

Keep logging, assertions, `Random`, fixture construction, reflection discovery, and string formatting used only to label cases out of timed methods. Avoid closures and LINQ in the benchmark wrapper unless they are the subject under test.

Do not add a manual loop merely to make a tiny method measurable; BenchmarkDotNet chooses invocation counts and subtracts overhead. Use an in-method loop only when a batch is the real workload or state reset requires a defined sequence, then declare `OperationsPerInvoke` accurately.

## Deferred execution and terminal operations

LINQ-style pipelines and iterators can measure different work:

- query or iterator creation only;
- a terminal operation such as `Count()`, `Any()`, or `First()`;
- explicit full enumeration, such as a `foreach`;
- materialization through `ToArray()` or `ToList()`.

Benchmark names, descriptions, and conclusions must say which one is measured. Inspect optimized terminal-operation paths before calling a result "enumeration." `List<T>.Count` can be an O(1) collection fast path while `Where(...).Count()` enumerates the filtered pipeline; they are not interchangeable baselines.

## Fair comparisons

- Feed identical logical inputs and starting state to every implementation.
- Match API semantics, validation, culture, encoding, comparer, error handling, and output ownership.
- Do not let one side reuse cached/precompiled state while the other recreates it unless the experiment explicitly compares those consumer strategies.
- Keep wrapper overhead symmetric. If one API requires an adapter, decide whether the adapter is part of real consumer cost and document it.
- Do not compare a scalar API with a batched/vectorized API per invocation without normalizing per item and explaining the workload difference.
- Keep compiler settings, runtime, architecture, GC mode, environment variables, and affinity consistent unless one of them is the experimental variable.

## Specialized workloads

### Async

Return and await the real `Task` or `ValueTask`. Never use `.Result`/`.Wait()`. Separate synchronous completion from genuinely asynchronous completion when both occur in production. A fake completed task measures the fake, not the I/O path. Use macro/load testing for external async I/O.

### Concurrency and contention

Define worker count, shared state, operation mix, synchronization start, and per-operation normalization. Avoid measuring task creation when lock/collection throughput is the question. Add `[ThreadingDiagnoser]` when completed work items or lock-contention counts help interpret the run. For service-level throughput, queueing, or tail latency, use a load test or profiler instead of a naive BenchmarkDotNet loop.

### Cold start and initialization

Keep cold-start experiments separate from steady-state throughput. Use a cold-start job only when process/JIT/initialization cost is the question, and define what is cold: process, type initializer, cache, parser, or application host.

### Exceptions and invalid inputs

Benchmark an exception path only when it is part of documented or observed behavior. Separate successful and throwing paths, add `[ExceptionDiagnoser]` when frequency matters, and do not use exceptions as a substitute for invalid-result checks.

### Extremely fast operations

Benchmark trivial getters/operators only with evidence of extreme frequency or a known regression. Ensure the result is consumed. Inspect disassembly when the question concerns inlining, bounds-check elimination, vectorization, or code generation.

## Diagnoser routing

`[MemoryDiagnoser]` is the codebelt default and belongs on every benchmark class. Add only what answers the question:

| Question | Diagnoser/tool | Notes |
|---|---|---|
| Managed allocations and GC | `[MemoryDiagnoser]` | Always on; interpret allocated bytes per operation. |
| Lock/thread-pool activity | `[ThreadingDiagnoser]` | .NET Core 3+; useful for contention experiments. |
| Thrown exception frequency | `[ExceptionDiagnoser]` | Use only for intentional exception-path analysis. |
| JIT/code generation | `[DisassemblyDiagnoser]` | Heavy; platform/toolchain limitations apply. |
| CPU/GC/JIT hot stacks | EventPipe profiler | Cross-platform targeted deep dive; creates separate profiling artifacts. |
| Windows ETW/native counters | ETW/hardware counter diagnosers | Platform/privilege restrictions; enable only when required. |

Diagnosers can create additional runs and change total duration. Do not combine every diagnoser into a default benchmark.

## Layered validation

1. Run existing correctness tests for the SUT where feasible.
2. Execute the benchmark's correctness oracle for every case.
3. Build the benchmark project in Release.
4. Run `--list flat` with a filter and confirm the expected case/method combinations without accidental Cartesian products.
5. Run a `--job dry` execution smoke and resolve BenchmarkDotNet validation warnings or runtime failures.
6. Run the full default job only with explicit user intent and a suitable environment.

A dry job has too few measurements for conclusions. It validates wiring and lifecycle only.

## Benchmark validity gate

After a dry execution and after any full run, inspect the complete BenchmarkDotNet summary before interpreting numbers. Treat the benchmark as invalid for performance interpretation when any intended case has an `NA` measurement, appears under `Benchmarks with issues`, throws in setup or cleanup, triggers a validation error, fails a job or runtime, or is missing from the intended matrix.

When that happens, report the exact failing method, job, and parameter case. Do not treat successful rows as a completed benchmark. Correct the benchmark only when the cause lies within the benchmark, then rerun build, discovery, and dry validation. Another full run still requires explicit human authority.

## Interpreting a full run

Report the benchmark environment and exact workload. Read warnings before tables. Compare mean, error, standard deviation, median when distributions are skewed, ratio distributions within valid groups, allocated bytes, GC counts, and specialized diagnoser columns.

Treat gains within noise as inconclusive. Check whether the result holds across representative cases and whether one case regresses. State the scope precisely: a result applies to the measured runtime, hardware, inputs, and configuration. Optimization value depends on application frequency and the maintenance/correctness cost of the change.

After the first valid full result, answer three questions: is the result reproducible, is the absolute cost material for observed or plausible usage, and would a deeper diagnostic change a concrete engineering decision? Stop when the answer is no. Do not escalate automatically to repeated reruns, tiered-PGO variants, disassembly, EventPipe or ETW tracing, alternative implementations, or runtime-source archaeology. Escalate only when the result is reproducible, material, the next diagnostic can distinguish concrete competing explanations, and the user requested it or it is necessary to answer the original decision. Low-microsecond test-support utilities often end with "no change justified."
