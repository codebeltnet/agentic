# Agent handoff template

Use to delegate follow-up implementation to another engineering agent or engineer. The prompt must be **self-contained**: executable without any hidden conversational context. Fill in what applies and delete the rest.

```markdown
# Task: <concise objective>

## Objective
<What must be accomplished, in one or two sentences. The end state, not the steps.>

## Repository context
- Repository: <name / URL>
- Branch or working state: <branch, base, or worktree state>
- Relevant stack/tooling: <languages, frameworks, build/test commands>
- Applicable instructions: <AGENTS.md and any nested guidance the agent must follow>

## Problem statement
<The concrete problem, with enough background to act without prior conversation.>

## Constraints
<Hard limits: compatibility, performance budgets, security, deadlines, dependencies, conventions.>

## Non-goals
<What is explicitly out of scope, to prevent scope creep.>

## Files or areas to inspect first
<Paths, modules, or symbols to read before editing. Include adjacent implementations and tests.>

## Required changes
<What must change, at the behaviour level. Be specific about contracts and expected results.>

## Compatibility expectations
<Public API / wire / serialization / configuration compatibility to preserve or explicitly change,
and the required version bump if applicable.>

## Testing requirements
<Which tests to add or update; the behaviour they must prove; the tier (unit/integration/contract).>

## Documentation requirements
<Docs, README, XML/API docs, or release notes to update; examples that must compile.>

## Performance requirements
<Workload, objective, baseline, and how improvement must be measured — if performance is in scope.>

## Validation commands
<Exact commands to run: format, lint, build, test, docs build, benchmark, package validation.>

## Completion criteria
<Objective conditions that make the task done and verifiable, per the completion checklist.>

## Prohibited shortcuts
- Do not invent APIs, members, switches, behaviour, or results.
- Do not claim validation that was not run; report exactly what was and was not verified.
- Do not broaden scope, rewrite unrelated code, or commit/push without explicit approval.
- Do not weaken tests or assertions to force a pass.
```
