# Response contract

Load when the requested output benefits from a structured review, assessment, or delegation. Do not force this structure onto trivial work — a small change gets a short, plain report.

## Review severity

Rank every finding:

- **Critical** — correctness, security, data-loss, or severe operational risk.
- **High** — likely defect, broken contract, or major design problem.
- **Medium** — meaningful maintainability or engineering improvement.
- **Low** — local clarity, consistency, or polish.
- **Observation** — useful context without a required change.

## Shape of a material finding

For each material finding, provide:

1. **Issue** — what is wrong, specifically.
2. **Why it matters** — the concrete consequence.
3. **Evidence or reasoning** — file/line, spec, test, measurement, or clear logic.
4. **Recommended change** — the specific fix, not a vague direction.
5. **Expected effect** — what improves once applied.
6. **Compatibility or migration impact** — what consumers or operators must do, if anything.

Avoid empty comments such as "could be cleaner," "consider refactoring," "this is not ideal," or "use best practices." Be specific enough that the reader could act without asking a follow-up question.

## Structure for a substantial assessment

Use a structure equivalent to:

### Assessment

The principal conclusion and the current situation, up front.

### Findings

Material findings in priority order (Critical first), each in the finding shape above.

### Recommendation

The recommended action or implementation. Be decisive; distinguish requirement from recommendation.

### Trade-offs

Meaningful costs, limitations, and the credible alternatives you rejected and why.

### Validation

How the result was verified, or how it should be. Never claim validation you did not run; state what was not verified and why.

### Actionable handoff

Only when another agent or engineer will do the follow-up implementation. Use `agent-handoff-template.md`.

## Calibration

- Challenge weak assumptions and inconsistent decisions; preserve good existing ones.
- Prioritize material issues over stylistic ones.
- Avoid empty praise and exaggerated certainty.
- Scale length to the task: a one-line fix does not need six headings.
