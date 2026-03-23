---
name: skill-creator-agnostic
description: >
  Adds runner-agnostic guardrails on top of Anthropic's skill-creator for creating, modifying, and benchmarking skills across Codex, GitHub Copilot, Opus, and similar agents. Use whenever skill work must follow temp-workspace isolation, valid `iteration-N/eval-name/{config}/run-N/` benchmark layout, honest measured-vs-simulated labeling, UTF-8-safe artifact generation, and repo-managed skill sync/README update rules. Treat requests like "turn this workflow into a skill", "benchmark this skill", "compare with_skill and without_skill", "why is aggregate_benchmark.py showing zeros", or "make this skill robust across agents" as automatic triggers.
---

# Skill Creator Agnostic

This skill is a thin overlay on Anthropic's `skill-creator`. It does not replace the upstream workflow; it adds cross-runner and repo-level guardrails so skill work stays reliable across Codex, Copilot, Opus, and similar agents.

Before benchmarking, read `references/benchmark-contract.md`.

On Windows or when running from PowerShell, also read `references/windows-powershell-benchmarking.md`.

## Critical

- Start from Anthropic's `skill-creator` workflow. Use this skill to add environment and repo guardrails, not to fork or replace the upstream skill.
- Do not edit third-party skills such as Anthropic's `skill-creator` to encode repo-specific behavior. Keep those rules in repo-managed files and companion skills instead.
- Do not assume any specific runner CLI exists. Choose the benchmark runner from what is actually available in the current environment.
- Keep all eval workspaces under a temp root such as `$env:TEMP/<skill-name>-workspace/`, never inside the source repo.
- For repo-managed skills, keep `skills/<name>/`, `~/.claude/skills/<name>/`, and `~/.agents/skills/<name>/` in sync before calling the work done.
- Every repo-managed skill must keep a per-skill `evals/evals.json`.
- If an eval entry declares `files`, treat those paths as skill-relative fixtures and stage them into the temp workspace for both benchmark configurations.
- Benchmark directories must follow `iteration-N/eval-name/{config}/run-N/` exactly, and the eval directory itself must start with `eval-`; do not flatten files directly under `with_skill/` or `without_skill/`.
- `grading.json` must include both `expectations` and a populated `summary` object with `passed`, `failed`, `total`, and `pass_rate`.
- Generate `benchmark.json` through `skill-creator/scripts/aggregate_benchmark.py`; never hand-author it.
- Generate the human review artifact through `skill-creator/eval-viewer/generate_review.py`; do not build custom HTML when the upstream viewer already fits.
- Write JSON as UTF-8 without BOM so Python tooling can load it reliably.
- Distinguish benchmark modes explicitly: `MEASURED` for real model executions, `SIMULATED` for hand-authored or scripted expected outputs. Never present simulated outputs as measured.
- A `MEASURED` benchmark may still show zero delta or parity between configurations. That is a valid measured result, not a reason to relabel the run as simulated.

## Workflow

### Step 1: Classify the skill task

Decide which of these modes the user is asking for:

- new skill creation
- existing skill modification
- skill benchmark repair/debugging
- benchmark interpretation or review

Load Anthropic's `skill-creator` for the base workflow, then apply this overlay for cross-runner and repo-specific execution discipline.

### Step 2: Inspect the local environment before choosing the runner

Choose the benchmark execution path from actual available capabilities, not from memory or assumptions.

- Check whether a callable agent runner is available.
- If one exists, prefer a real `MEASURED` benchmark.
- If no callable runner exists, you may still validate the pipeline with a `SIMULATED` benchmark, but label it clearly as such.
- Explain the chosen mode up front whenever the distinction matters to the user.
- If the callable runner is Codex CLI on Windows, verify the exact invocation shape with a tiny smoke run before spawning the full benchmark harness.

Do not frame the workflow around one vendor-specific CLI unless that CLI is actually present.

### Step 3: Set up the benchmark workspace

Create the workspace under temp and keep it isolated from the real repo.

- Use a short path such as `$env:TEMP/<skill-name>-workspace/`.
- Put fixture repos, test branches, transcripts, and benchmark outputs there.
- Never commit workspace artifacts back into the source repository unless the user explicitly asked for checked-in examples or harnesses.

### Step 4: Build the eval contract before running anything

Read or create the per-skill `evals/evals.json`, then ensure each eval has a corresponding workspace shape:

```text
iteration-N/
  eval-1-name/
    eval_metadata.json
    fixtures/
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

Keep `eval_metadata.json` at the eval-directory level. Put run artifacts under `run-N/` so `aggregate_benchmark.py` can discover them.
If `evals/evals.json` declares `files`, copy those skill-relative fixtures into `fixtures/` at the eval-directory level and make them available to both runs.
Do not invent custom eval directory names such as `dependency-upgrades-vs-build-refactor/` without the `eval-` prefix. Anthropic's aggregation tooling discovers `eval-*` directories, not arbitrary names.

### Step 5: Run paired benchmarks

Run each eval in paired configurations:

- `with_skill`: the skill under test is active
- `without_skill`: baseline with no skill for new skills, or a previous/ original version for existing skills

For `MEASURED` runs:

- save the real outputs
- save transcripts or command logs when available
- keep timings and token counts tied to the actual run
- use the same staged fixture files for both `with_skill` and `without_skill` runs when the eval declares `files`
- if the runner accepts prompts positionally, pass the prompt as a single argument or via stdin instead of relying on shell-quoted fragments that can be reparsed as CLI flags or extra arguments
- if the runner offers JSONL or event-stream output, keep that raw event file in `outputs/`; it is the fallback source of truth when a convenience output file such as `last-message.txt` is missing

For `SIMULATED` runs:

- write clearly labeled expected outputs
- use them only to validate layout, grading, aggregation, and viewer integration
- never claim the result measures model quality

### Step 6: Grade each run deterministically when possible

Prefer scripts or direct file/diff checks over impressionistic grading.

Each `grading.json` must minimally look like this:

```json
{
  "expectations": [
    {
      "text": "Uses iteration-N/eval-name/{config}/run-N/ layout",
      "passed": true,
      "evidence": "Found run-1/grading.json and run-1/timing.json"
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

If `summary` is missing or empty, the aggregation output is not trustworthy.

### Step 7: Aggregate and generate the review artifacts

After the paired runs are graded:

1. Resolve the installed Anthropic `skill-creator` root first, usually under `~/.agents/skills/skill-creator/` or `~/.claude/skills/skill-creator/`.
2. Run `scripts/aggregate_benchmark.py` from that resolved `skill-creator` root.
3. Verify that the generated `benchmark.json` contains discovered runs and a non-empty `run_summary`.
4. Run `eval-viewer/generate_review.py` from that same resolved `skill-creator` root to create the human review artifact.

If the viewer shows outputs but the benchmark metrics are zero, suspect run layout or `grading.json.summary` before blaming the viewer.

### Step 8: Interpret results honestly

Summarize benchmark outcomes with plain language:

- pass-rate delta
- time and token tradeoffs
- whether the benchmark is `MEASURED` or `SIMULATED`
- which assertions are discriminating versus weak/non-discriminating

Call out benchmark limitations directly. For example:

- fixture gaps that leave an assertion only partially tested
- synthetic outputs used for pipeline validation
- missing transcripts or token counts in a measured run
- parity results where both configurations pass, meaning the eval validates the artifact pipeline but does not yet discriminate skill value

### Step 9: Finish repo-managed skill work cleanly

For repo-managed skills:

- sync changed skill files across the repo copy, `~/.claude`, and `~/.agents`
- update `README.md`
- run `scripts/validate-skill-templates.ps1`
- keep benchmark artifacts in temp unless the user explicitly wants them checked in

## Good Output Characteristics

- Treats Anthropic's `skill-creator` as the base workflow and this skill as the overlay.
- Talks about available runner capability instead of assuming one product-specific CLI.
- Resolves the installed `skill-creator` path before calling benchmark scripts or the review viewer.
- Produces valid benchmark artifacts that `aggregate_benchmark.py` and `generate_review.py` consume without repair work.
- Labels synthetic benchmarks as `SIMULATED` and live executions as `MEASURED`.
- Treats measured parity as an honest outcome instead of overclaiming improvement.
- Explains why a benchmark failed in terms of layout, grading schema, encoding, or environment reality instead of hand-waving.

## Bad Output Characteristics

- Presenting hand-authored outputs as if they were independent model runs.
- Hand-writing `benchmark.json` instead of generating it.
- Flattening files directly under `with_skill/` or `without_skill/`.
- Naming eval directories without the `eval-*` prefix and then blaming the aggregator for finding zero runs.
- Saying "use the Claude CLI" or any other vendor tool when the environment has not shown that capability.
- Relabeling a real but parity-only run as `SIMULATED` just because the delta is zero.
- Treating a viewer with qualitative outputs as proof that the numeric benchmark is valid.
