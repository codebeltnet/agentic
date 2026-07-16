# Governance

Load for policies, standards, compliance, metrics, enterprise repository governance, and engineering guardrails.

## Connect every rule through a chain

    Intent → Drivers → Metrics → Actions

Governance recommendations must:

- **state the intended outcome** (Intent) — what good looks like;
- **identify why it matters** (Drivers) — the risk, cost, or requirement behind it;
- **define measurable indicators** (Metrics) — how compliance is observed;
- **specify what action follows from the metric** (Actions) — what happens when it is met or missed;
- distinguish **compliant**, **non-compliant**, and **ungoverned** states where useful;
- avoid metrics that have no decision or action attached.

A metric with no action is a dashboard ornament. If nothing changes based on the number, do not collect it as governance.

## Guardrails over gates where possible

- Prefer automated guardrails (defaults, checks, templates) that make the right thing easy over manual gates that slow everyone and are bypassed under pressure.
- Make policy **enforceable and observable**; an unenforced policy is documentation, not governance.
- Scope guardrails to real risk; do not impose enterprise ceremony on low-risk work.

## Examples of the chain

- **Intent:** third-party actions cannot be silently swapped. **Driver:** supply-chain compromise. **Metric:** percentage of actions pinned to a full SHA. **Action:** CI fails on unpinned actions.
- **Intent:** breaking changes ship deliberately. **Driver:** downstream breakage and support cost. **Metric:** releases with a declared compatibility impact. **Action:** release blocked until impact is classified.

## Guidance

- DO tie each governance rule to a driver and an action.
- DO NOT propose a policy whose only effect is producing a number nobody acts on.
- AVOID governance that cannot be measured or enforced; it erodes trust in the rules that can be.
- CONSIDER the compliance cost; a rule that is routinely bypassed is worse than an honest, narrower rule.
