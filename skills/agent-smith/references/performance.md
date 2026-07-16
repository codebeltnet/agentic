# Performance

Load for benchmarking, profiling, optimization, latency, throughput, allocation analysis, and scalability.

## Never optimize without evidence

Require, before accepting a performance change:

1. **A defined workload** — representative inputs and conditions, not a toy loop.
2. **An objective** — latency, throughput, allocations, memory, cold start, or tail latency, stated.
3. **A baseline** — measured, reproducible numbers for the current state.
4. **Bottleneck identification** — profile or reason from evidence about where time/allocations go.
5. **Measured comparison** — before vs after under the same conditions.
6. **Correctness validation** — the optimization must not change observable behaviour (or the change is explicit and tested).
7. **Complexity and maintenance assessment** — is the speed-up worth the readability cost?

## What to consider

- algorithmic complexity (fix the O(n^2) before shaving constants);
- allocations, boxing, closures;
- reflection on hot paths;
- parsing and string handling;
- synchronization and contention;
- I/O and batching;
- caching (and its invalidation/correctness cost);
- cold start;
- tail latency (p95/p99), not just the average.

## Interpreting results honestly

Distinguish:

- **statistically meaningful improvement** from run-to-run **noise**;
- **workload-specific benefit** from general benefit;
- **regression risk** introduced elsewhere;
- **maintenance cost** added by the change.

Report the workload, the numbers, and the variance. Do not present a single lucky run as a result, and do not claim a benchmark you did not run.

## Guidance

- DO fix the dominant bottleneck first; secondary tuning rarely matters until it dominates.
- DO NOT report benchmark or profiling numbers you did not measure.
- AVOID unmeasured micro-optimizations that materially reduce clarity — reject them by default.
- CONSIDER leaving a clear, slightly slower implementation in place when the measured gain is within noise.
