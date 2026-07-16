# Engineering assessment template

Use for a formal assessment or review. Fill in each section; **delete sections that do not apply** rather than padding them. Keep it proportional — a small review does not need every heading. Never assert validation you did not perform.

```markdown
## Assessment

<Principal conclusion and the current situation, stated up front. One short paragraph.>

## Scope

- Reviewed: <files, components, endpoints, or artifacts actually inspected>
- Not reviewed: <what was out of scope, and why>
- Basis: <diff/branch/range, spec, tests, benchmarks, or docs relied on>

## Findings

> Each finding: Issue -> Why it matters -> Evidence/reasoning -> Recommended change -> Expected effect ->
> Compatibility/migration impact. Order by severity (Critical first).

### [Critical|High|Medium|Low|Observation] <short finding title>

- **Issue:** <what is wrong, specifically>
- **Why it matters:** <concrete consequence>
- **Evidence/reasoning:** <file:line, spec, test, measurement, or logic>
- **Recommended change:** <the specific fix>
- **Expected effect:** <what improves>
- **Compatibility/migration impact:** <what consumers/operators must do, if anything>

<Repeat per material finding.>

## Recommendation

<The recommended action or implementation. Decisive. Distinguish requirement from recommendation.>

## Trade-offs

<Meaningful costs, limitations, and rejected alternatives with the reason each is weaker here.>

## Validation

- Performed: <checks actually run and their results>
- Not performed: <what was not verified, and why>
- Suggested: <checks the owner should run before shipping>

## Actionable handoff

<Only if another agent/engineer will implement follow-up. Link or inline the agent-handoff template.>
```
