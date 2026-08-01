# Skill authoring

Load when creating, modifying, reviewing, describing, or evaluating agent skills.

## Critical

- Ground instructions in real tasks, repository artifacts, execution traces, corrections, and failure cases. Generic advice adds little value.
- Inspect the current skill, applicable repository instructions, execution traces, repeated helper work, and failures before choosing changes. When artifacts are unavailable, make this the first required action instead of treating a hypothetical design as confirmed.
- Always map the task graph. Identify independent reads, searches, API calls, executor runs, validators, and graders. Suggest bounded parallel execution and encode it when safe.
- Keep true dependencies, shared-file mutations, rate-limited operations, and fragile ordered workflows sequential. Parallelism must preserve deterministic outputs, stable ordering, error attribution, cancellation, and service limits.
- Batch independent retrieval through one multi-call request where the tool supports it. Otherwise fan out with an explicit concurrency bound. Avoid sequential fetching by habit.
- Measure the result. Compare elapsed time, tokens/cost, error rate, and output quality; do not assume concurrency improved the workflow.

## .NET-first bundled scripts

Choose C# and .NET by default for non-trivial reusable scripts, deterministic validators, data transformation, and orchestration in this .NET-first skill collection. Perceived cross-repository portability alone does not justify retaining or introducing Python, Bash, or PowerShell.

1. Inspect repository SDK pins, target frameworks, existing script conventions, and supported execution hosts.
2. If no compatible local constraint decides the version, resolve the latest supported LTS from [Microsoft's official .NET support policy](https://dotnet.microsoft.com/platform/support/policy/dotnet-core). Do not hardcode a release that will drift.
3. Prefer a small C# file-based app when the supported SDK and host make it practical; use a minimal project only when dependencies or build behavior require one.
4. Preserve bounded concurrency, cancellation, deterministic ordering, actionable errors, and non-zero failure exits in script design.
5. Use another language only when an observed repository standard, host limitation, vendor SDK, or materially simpler native tool makes it the better engineering choice. State the evidence.

Do not turn a one-line native command into a C# program. The preference applies where a bundled script provides reusable value.

## Required authoring feedback

Keep the response compact, but cover every item:

- **Evidence** — inspected skill, repository rules, traces/repeated work, and failures; name anything unavailable.
- **Parallelism** — independent operations, concurrency bound, sequential constraints, deterministic ordering, failure attribution, cancellation, and rate limits.
- **Scripts** — C#/.NET default or the concrete evidence for an exception; SDK/target-framework resolution and validation behavior.
- **Description** — concise imperative user intent, trigger boundaries, 1,024-character gate, realistic positive and near-miss trigger tests, repeated runs, and fixed train/validation split.
- **Evaluation** — clean-context candidate-versus-original baseline, objective assertions, deterministic mechanical grading, timing/cost/error/quality metrics, aggregation, and human review.
- **Status** — commands and evidence actually produced; blockers, compatibility impact, validation limits, and material risk.

## Skill content

- Keep `SKILL.md` focused on instructions required on every activation. Move detailed, conditional material into directly linked references.
- Add what the agent would otherwise miss: domain procedures, project conventions, gotchas, defaults, failure handling, and validation loops.
- Prefer concise procedures over declarations. Give a clear default and a reasoned escape hatch instead of an unranked menu.
- Match control to fragility. Explain intent where judgment is safe; use exact commands and fail-closed gates where sequence or correctness is fragile.
- Bundle a tested script when execution traces show agents repeatedly recreating the same deterministic logic.

See [Best practices for skill creators](https://agentskills.io/skill-creation/best-practices) for deeper guidance on real-task grounding, context economy, progressive disclosure, calibrated control, reusable scripts, and validation loops.

## Descriptions

Treat the frontmatter `description` as the activation contract:

- use imperative phrasing;
- describe user intent and trigger contexts, not internal mechanics;
- include realistic positive contexts and precise near-miss boundaries;
- remain concise and within the specification's 1,024-character limit;
- test triggering with realistic should-trigger and should-not-trigger queries;
- run queries repeatedly because activation is nondeterministic;
- keep a fixed train/validation split while iterating to avoid overfitting.

See [Optimizing skill descriptions](https://agentskills.io/skill-creation/optimizing-descriptions) for query design, repeated trigger testing, train/validation splits, and the optimization loop.

## Evaluation

1. Start with a small varied set of realistic prompts, expected outcomes, and required fixtures.
2. Run each case in a clean context with the candidate skill and a baseline: no skill for a new capability, or the original/previous skill for an update.
3. Run independent paired executors concurrently when resources allow. Do the same for independent deterministic grading. Do not let configurations share mutable state.
4. Add objective assertions after inspecting initial outputs. Use scripts for mechanical checks and concrete evidence for every pass.
5. Capture timing and token/cost data. Aggregate quality and performance deltas; inspect non-discriminating, always-failing, and high-variance assertions.
6. Generate the standard human-review artifact. Review qualitative output and benchmark data before sign-off.
7. Revise, rerun, and compare until the skill improves without overfitting.

See [Evaluating skill output quality](https://agentskills.io/skill-creation/evaluating-skills) for workspace structure, paired runs, assertions, grading, aggregation, analysis, and human review.
