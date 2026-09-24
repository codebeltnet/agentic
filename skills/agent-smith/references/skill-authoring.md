# Skill authoring

Load when creating, modifying, reviewing, describing, or evaluating agent skills.

## Critical

- Ground instructions in real tasks, repository artifacts, execution traces, corrections, and failure cases. Generic advice adds little value.
- Inspect the current skill, applicable repository instructions, execution traces, repeated helper work, and failures before choosing changes. When artifacts are unavailable, make this the first required action instead of treating a hypothetical design as confirmed.
- Always map the task graph. Identify independent reads, searches, API calls, validators, and any explicitly authorized executors or graders. Suggest bounded parallel execution only when beneficial and permitted; mapping work does not authorize model calls or delegation.
- Keep true dependencies, shared-file mutations, rate-limited operations, and fragile ordered workflows sequential. Parallelism must preserve deterministic outputs, stable ordering, error attribution, cancellation, and service limits.
- Batch independent retrieval through one multi-call request where the tool supports it. Otherwise fan out with an explicit concurrency bound. Avoid sequential fetching by habit.
- Measure the result. Compare elapsed time, tokens/cost, error rate, and output quality; do not assume concurrency improved the workflow.

## Proportional bundled automation

Load `automation.md` before choosing or changing a bundled script runtime. It defines the default decision order: a sufficient native command, PowerShell 7 for small focused scripts, then C#/.NET when complexity, reuse, or growth benefits from application structure. Preserve a sound small script; justify migrating substantial automation by maintainability and validation evidence. Use `agentic-engineering.md` when designing model selection or worker orchestration.

## Required authoring feedback

Keep the response compact, but cover every item:

- **Evidence** - inspected skill, repository rules, traces/repeated work, and failures; name anything unavailable.
- **Parallelism** - independent operations, concurrency bound, sequential constraints, deterministic ordering, failure attribution, cancellation, and rate limits.
- **Scripts** - proportional runtime choice, repository/host evidence, and validation behavior; SDK/target-framework resolution when .NET is selected.
- **Description** - concise imperative user intent, trigger boundaries, 1,024-character gate, and realistic positive and near-miss cases; distinguish inspected cases from measured trigger behavior.
- **Evaluation** - updated objective assertions and deterministic checks; distinguish these from authorized clean-context comparisons, timing/cost/error/quality metrics, aggregation, and human review that actually occurred.
- **Status** - commands and evidence actually produced; blockers, compatibility impact, validation limits, and material risk.

## Skill content

- Keep `SKILL.md` focused on instructions required on every activation. Move detailed, conditional material into directly linked references.
- Add what the agent would otherwise miss: domain procedures, project conventions, gotchas, defaults, failure handling, and validation loops.
- Prefer concise procedures over declarations. Give a clear default and a reasoned escape hatch instead of an unranked menu.
- Match control to fragility. Explain intent where judgment is safe; use exact commands and fail-closed gates where sequence or correctness is fragile.
- Bundle a tested script when execution traces show agents repeatedly recreating the same deterministic logic.

When authoring or editing Markdown skill files, keep each prose paragraph and list item on one physical line regardless of length. Do not hard-wrap at a fixed column width; rely on editor soft wrapping and insert physical line breaks only between Markdown structures. Rejoin unnecessary hard wraps in prose you touch.

See [Best practices for skill creators](https://agentskills.io/skill-creation/best-practices) for deeper guidance on real-task grounding, context economy, progressive disclosure, calibrated control, reusable scripts, and validation loops.

## Descriptions

Treat the frontmatter `description` as the activation contract:

- use imperative phrasing;
- describe user intent and trigger contexts, not internal mechanics;
- include realistic positive contexts and precise near-miss boundaries;
- remain concise and within the specification's 1,024-character limit;
- test triggering with realistic should-trigger and should-not-trigger queries;
- when model-backed trigger testing is explicitly authorized, run queries repeatedly because activation is nondeterministic and keep a fixed train/validation split while iterating to avoid overfitting.

See [Optimizing skill descriptions](https://agentskills.io/skill-creation/optimizing-descriptions) for query design, repeated trigger testing, train/validation splits, and the optimization loop.

## Evaluation

First follow repository authorization and execution rules. Editing a skill does not authorize model-backed runs, description optimization, or agent fan-out. Where the repository requires deterministic checks and a separate portable handoff, update eval specifications, run focused deterministic validation, and prepare a package only when explicitly requested. Never execute a package you prepared or claim behavioral improvement from content checks alone. The comparison process below applies only at an authorized execution boundary; it is not an automatic completion gate.

1. Start with a small varied set of realistic prompts, expected outcomes, and required fixtures.
2. Use the repository's baseline protocol in clean contexts. For a skill-effect comparison, vary only skill presence; for an explicitly designed revision comparison, use the original/previous skill. Hold model, configuration, inputs, and environment constant, and disable cross-session memory.
3. Run independent paired executors concurrently when resources allow. Do the same for independent deterministic grading. Do not let configurations share mutable state.
4. Add objective assertions after inspecting initial outputs. Use scripts for mechanical checks and concrete evidence for every pass.
5. Capture timing and token/cost data. Aggregate quality and performance deltas; inspect non-discriminating, always-failing, and high-variance assertions.
6. Generate the standard human-review artifact. Review qualitative output and benchmark data before sign-off.
7. Revise, rerun, and compare until the skill improves without overfitting.

See [Evaluating skill output quality](https://agentskills.io/skill-creation/evaluating-skills) for workspace structure, paired runs, assertions, grading, aggregation, analysis, and human review.
