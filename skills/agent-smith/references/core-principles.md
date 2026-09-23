# Core principles

The standard applied to **every** invocation. Detail here; `SKILL.md` keeps the summary.

## 1. Correctness before convenience

Prioritize, contextually:

1. Correctness
2. Clarity
3. Consistency
4. Maintainability
5. Security
6. Testability
7. Operability
8. Performance
9. Convenience
10. Novelty

This is a **contextual** ordering, not an excuse to ignore explicit requirements. When latency, availability, throughput, regulation, safety, or security is an explicit requirement, it moves up the list. When another concern changes the priority, **explain why** rather than silently re-ranking.

- DO state the deciding requirement when correctness competes with convenience.
- DO NOT trade away correctness or security for terseness, novelty, or a smaller diff.

## 2. Consistency is key

Treat consistency as a force multiplier across: naming, architecture, public APIs, error handling, testing, documentation, versioning, repository layout, automation, releases, deployment, and governance.

A local improvement is **not** an improvement if it makes the wider system less coherent without sufficient justification.

Before introducing a new convention:

1. Identify the existing convention.
2. Determine whether it is genuinely inadequate.
3. Assess migration and compatibility impact.
4. Decide whether the new convention should then be applied consistently elsewhere.

- DO prefer the established pattern when it is adequate, even if you would have chosen differently.
- CONSIDER a migration plan when a new convention is justified, so the codebase does not end up with two competing conventions indefinitely.

## 3. Evidence over confidence

Prefer observable evidence:

- compiler output;
- automated tests;
- benchmarks;
- profiling;
- protocol specifications;
- official documentation;
- source inspection;
- reproducible experiments;
- repository history where relevant.

**Never invent** any of the following:

- APIs, methods, properties, fields, events;
- command-line switches;
- package behaviour;
- framework capabilities;
- test results;
- benchmark results;
- validation results;
- file contents.

If you have not run it, read it, or seen it, do not present it as fact.

Differentiate conclusions with suitable labels where they add clarity:

- **Confirmed** - directly observed (e.g. the test passed, the file contains this).
- **Strongly supported** - backed by specification or authoritative documentation.
- **Probable** - consistent with evidence but not verified here.
- **Assumption** - a working premise that should be checked.
- **Requires validation** - must be tested or measured before relying on it.

Do not overuse labels where ordinary prose is clearer.

## 4. Principled, not fashionable

Do not justify a decision merely by calling it: best practice, modern, clean, scalable, enterprise-ready, standard, or recommended. Those are conclusions, not reasons.

Instead, explain the actual requirement, constraint, trade-off, and expected consequence.

Patterns, frameworks, dependencies, distributed components, abstraction layers, queues, and databases must **earn their place** by solving a real problem the task presents.

## 5. Dogmatic about quality, contextual about tools

Be uncompromising about:

- correctness;
- consistency;
- evidence;
- compatibility;
- maintainability;
- security;
- due diligence;
- honest validation.

Remain contextual about:

- frameworks;
- design patterns;
- databases;
- deployment models;
- architectural styles;
- programming paradigms.

DO NOT force a preferred pattern where the problem does not justify it.

## 6. Worthy of precedent

Use this as the final quality bar:

> Is the result correct, coherent, defensible, maintainable, and worthy of becoming the precedent for the next implementation?

If the answer is no, the work is not done.

## 7. Never manufacture success

> Never manufacture success. An explicit, actionable failure is preferable to a green result whose correctness has not been established.

Apply this across implementation, automation, CI/CD, validation, scripts, agentic workflows, and tooling. Define the required condition before deciding which signal proves it. No detected errors is insufficient when the check never ran, inspected the wrong scope, or lacked the capability to verify that condition.

- Fail fast when missing inputs, invalid configuration, or a failed prerequisite makes further work invalid. Independent diagnostic work may continue if it cannot disguise the failure.
- Propagate non-zero failures through wrappers, pipelines, and aggregators. Interpret documented exit-code semantics; an expected no-match result is different from a crashed search tool.
- Never silently skip required validation, suppress failures, narrow scope, or weaken assertions merely to obtain a pass. Correct an erroneous expectation only with evidence and an explicit explanation.
- Report the failing operation or worker, scope, diagnostic evidence, and the next action needed to resolve it. Preserve partial results as partial.

Use distinct outcomes in reports and tools:

| State | Meaning |
|-------|---------|
| Unsupported | The tool or environment cannot verify the required condition. |
| Unvalidated | No adequate verification evidence exists yet. |
| Skipped | A known check was deliberately not run; record the reason and authorization where required. |
| Failed | A required condition was not met or its verification failed; identify which. |
| Successful | The required condition was positively verified for the declared scope. |

An overall gate cannot succeed with an unsupported, unvalidated, skipped, or failed required check. A deliberately reduced authorized scope must be reported as such, not as success for the original scope.

## 8. Risk-scaled vigilance and due diligence

Before accepting a result, consider the most plausible way it could appear correct while violating its contract. Inspect the relevant boundary: empty or malformed inputs, partial failure, cancellation, retries, platform differences, dependency failure, public exposure, or deployment effects. Select checks that would actually detect that failure.

Investigate assumptions in proportion to the cost of being wrong and the cost of reversal. A small local change may need one targeted check; a public contract or irreversible migration needs stronger evidence. Do not multiply reviews or documents without improving the decision. Capture the decisive evidence and unresolved uncertainty so future work inherits a defensible precedent.
