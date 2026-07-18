# Selecting High-Value Benchmark Candidates

Use this reference when the user supplies a type but does not already provide an exact performance hypothesis. The goal is to find a small set of operations whose measurement could plausibly guide an optimization decision. This is source-informed discovery, not proof that the operation dominates a deployed workload.

## Evidence ladder

Prefer evidence in this order:

1. Production telemetry, traces, allocation profiles, contention traces, or an existing performance regression.
2. Representative application benchmarks or load-test results that identify the type or call path.
3. Real call sites that reveal frequency, batching, concurrency, and input shape.
4. Tests and examples that reveal valid, boundary, failure, and compatibility scenarios.
5. Implementation inspection that reveals algorithmic scaling, allocations, synchronization, code generation, or repeated work.
6. Public API shape alone.

Do not promote weak evidence to a stronger label. When no profile exists, say that the candidate is selected from source and usage evidence.

## Inspection sequence

1. Read the complete type, including partial declarations and generated-source inputs where available.
2. Identify the public or internal consumer operations that enter the type. Include inherited/interface operations when call sites use them.
3. Search call sites across `src/`, tests, samples, tooling, and benchmarks. Note loop nesting, batch sizes, collection use, concurrency, and repeated calls.
4. Read focused tests and examples to learn realistic inputs, equivalence rules, error behavior, and boundary cases.
5. Follow the selected entry point into private helpers and important collaborators far enough to understand dominant work. Do not benchmark private helpers merely because they look expensive.
6. Inspect existing benchmarks and reports before adding another suite. Extend a compatible benchmark rather than duplicating it.
7. If profiling artifacts exist, use their hot stacks/allocation types/contention sites to confirm or reorder candidates.

Useful searches include the exact type name, constructed generic forms, interface/base-type names, factory methods, extension methods, and characteristic member names. Search aliases and static imports when a direct type search is sparse.

## Cost signals

Treat these as hypotheses that require measurement, not defects by themselves:

- Nested loops, repeated scans, recursion, sorting, hashing, or work whose complexity grows with input size.
- Per-call `new` allocations, boxing, closures, iterator state machines, LINQ materialization, array/string copies, interpolation, and repeated buffer growth.
- Repeated parsing, formatting, normalization, encoding/decoding, regular-expression construction, serialization, reflection, expression compilation, or metadata lookup.
- `GetHashCode` and `Equals` on types heavily used as dictionary/set keys, especially when they traverse fields, strings, collections, or normalized forms.
- Locks, concurrent collections, atomics, task scheduling, blocking waits, and shared mutable state used from multiple call sites.
- Exception construction or throwing on a documented/common path.
- Cache misses, lazy initialization, cold initialization, and expensive work that could be hoisted or reused.
- Span/array conversions, pinning, interop, crypto transforms, compression, and buffer pooling.
- Branch-heavy parsing/matching whose cost changes for success/failure, hit/miss, early/late match, or well/ill-shaped input.

Trivial getters, constant-returning properties, thin wrappers, and rarely used diagnostic formatting are low priority unless call-site evidence shows exceptional frequency or a regression specifically names them.

## Candidate matrix

Create a compact matrix before choosing benchmark methods:

| Candidate operation | Usage evidence | Cost/scaling signal | Representative cases | Comparison available | Measurement fitness | Decision |
|---|---|---|---|---|---|---|
| `TryParse` | Called for each imported record | Scans and allocates normalized strings | short/typical/large; valid/invalid | current vs span candidate | deterministic, in-memory | Select |
| `ToString` | Debug/logging only | one allocation | typical object | none | measurable but low impact | Reject |

Use a score only as a prioritization aid, never as a performance claim. A practical score is:

- 0–3 for observed frequency/importance;
- 0–3 for per-call cost or input scaling;
- 0–2 for allocation, contention, or cold-path significance;
- 0–2 for optimization leverage or a credible comparison;
- 0–2 for deterministic measurement fitness;
- subtract 0–3 for external noise, unresettable state, unrealistic isolation, or weak workload evidence.

Record the evidence behind each score. A high score based only on source appearance is still exploratory.

## Select the performance questions

Choose one to three questions that could change an engineering decision. Good questions are specific:

- Does the span-based parser reduce latency and allocations versus the current string parser for representative valid and invalid inputs?
- How does wildcard matching scale across path length and pattern complexity, and does the current method allocate per call?
- Under a fixed worker count and hit/miss mix, does cache lookup show lock contention?

Weak questions merely inventory members:

- How fast are all public methods?
- Is `ToString` faster than `GetHashCode`?
- What happens if every available enum and size is crossed with every method?

If several unrelated operations are genuinely important, prefer separate benchmark classes or explicit comparison categories so reports do not imply invalid ratios.

## Workload cases

Derive cases from call sites and tests. Include only dimensions that can change the conclusion:

- typical production-like case;
- small/empty boundary when valid;
- a scaling point large enough to expose complexity;
- adverse-but-valid case such as miss, late match, escaped content, collision, invalid parse, or cache miss;
- cold/warm state only when both are meaningful consumer modes.

Random bytes are appropriate for some codecs, hashes, and raw buffers, but not as a universal workload. Parsers, matchers, compressors, collections, and caches often need structured cases. Use fixed seeds only after choosing a representative distribution.

Avoid independent parameter properties when values are coupled. `[Params]` creates the Cartesian product of every axis. Use a scenario record/class with a readable `ToString()` supplied through `[ParamsSource]`, or use `[ArgumentsSource]`, to enumerate only meaningful combinations.

## Profiling-first gate

Recommend profiling or a macrobenchmark before writing a microbenchmark when:

- the user asks what makes an application or endpoint slow but provides no hotspot evidence;
- the type mainly coordinates network, disk, database, process, UI, or distributed work;
- the important behavior is request concurrency, queueing, thread-pool starvation, or tail latency across components;
- startup/JIT/module loading for a whole application is the target;
- state cannot be reset reproducibly or isolation changes the behavior under investigation.

A useful response still narrows the next step: name the entry point, workload, and signal to collect. After profiling identifies a controllable code path, return to BenchmarkDotNet to compare implementations under a reproducible workload.

## Candidate rejection rules

Reject or defer a candidate when it has no plausible consumer impact, duplicates a selected operation, cannot be isolated without changing semantics, measures mostly test scaffolding, crosses unrelated work, depends on uncontrolled external systems, or has no representative workload. Report the reason so the user can correct missing context.
