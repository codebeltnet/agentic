# Benchmark Contract

Use this reference whenever a skill benchmark must be reproducible across
different agents or runtimes.

## Required Workspace Layout

```text
iteration-N/
  eval-1-name/
    eval_metadata.json
    with_skill/
      run-1/
        grading.json
        timing.json
        outputs/
    without_skill/
      run-1/
        grading.json
        timing.json
        outputs/
```

Key rules:

- `aggregate_benchmark.py` walks `run-*` directories. If files live
  directly under `with_skill/` or `without_skill/`, the benchmark will
  discover zero runs.
- `eval_metadata.json` belongs at the `eval-*` directory level, not
  inside each run directory.
- `outputs/` may contain files, diffs, transcripts, or other evidence
  the reviewer should inspect.

## Required Files

### eval_metadata.json

Minimum contract:

```json
{
  "eval_id": 1,
  "eval_name": "descriptive-name",
  "prompt": "User-style prompt under test",
  "assertions": [
    "Expectation one",
    "Expectation two"
  ]
}
```

### grading.json

Minimum contract:

```json
{
  "expectations": [
    {
      "text": "Expectation one",
      "passed": true,
      "evidence": "Why it passed"
    }
  ],
  "summary": {
    "passed": 1,
    "failed": 0,
    "total": 1,
    "pass_rate": 1.0
  }
}
```

Important:

- `expectations[].text`, `expectations[].passed`, and
  `expectations[].evidence` should be present for every assertion.
- `summary` is required for meaningful aggregation. Without it,
  `aggregate_benchmark.py` falls back to zeros even if qualitative output
  exists.

### timing.json

Minimum contract:

```json
{
  "total_duration_seconds": 12.3,
  "total_tokens": 4567,
  "duration_ms": 12300
}
```

Use real numbers for `MEASURED` runs. For `SIMULATED` runs, either omit
  unsupported fields or provide clearly synthetic values and document
  that they are synthetic.

## Generated Files

These must be produced by the Anthropic tooling, not authored manually:

- `benchmark.json` from `scripts/aggregate_benchmark.py`
- `benchmark.md` from `scripts/aggregate_benchmark.py`
- review HTML or served viewer output from
  `eval-viewer/generate_review.py`

If `benchmark.json` was hand-written, the benchmark is not trustworthy
as an aggregation result.

## Benchmark Modes

### MEASURED

Use `MEASURED` when a callable runner can actually execute paired
`with_skill` and `without_skill` runs.

Expected properties:

- real outputs
- real timings
- real token counts when available
- real transcripts or command logs when available

This is the preferred benchmark mode when the environment supports it.

### SIMULATED

Use `SIMULATED` only when the environment cannot perform real paired
agent executions or when you are validating the benchmark pipeline
itself.

Expected properties:

- hand-authored or scripted expected outputs
- explicit `SIMULATED` labeling in logs and summary
- clear statement that the result validates pipeline correctness, not
  model superiority

Never present `SIMULATED` outputs as if they were independently
generated model runs.

## Aggregation and Review Commands

Typical flow:

```powershell
python "$HOME/.agents/skills/skill-creator/scripts/aggregate_benchmark.py" `
  "$workspace/iteration-1" --skill-name "<skill-name>"
```

```powershell
python "$HOME/.agents/skills/skill-creator/eval-viewer/generate_review.py" `
  "$workspace/iteration-1" --skill-name "<skill-name>" `
  --benchmark "$workspace/iteration-1/benchmark.json" `
  --static "$workspace/review.html"
```

If the viewer renders outputs but the benchmark delta is zero or the run
list is empty, inspect the workspace layout and `grading.json.summary`
before anything else.
