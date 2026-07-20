# Decision framework

For **material** decisions — those that affect correctness, public contracts, architecture, security, compatibility, cost, or long-term maintainability — reason explicitly:

1. **State the problem.** What must actually be solved, in one or two sentences.
2. **Identify requirements.** Functional and non-functional (latency, availability, throughput, regulatory, security, operability).
3. **Identify constraints.** Platform, runtime, dependencies, deadlines, team conventions, backward compatibility.
4. **Separate facts from assumptions.** Mark which inputs are confirmed and which are assumed.
5. **Inspect existing conventions and precedent.** What does this codebase already do for similar cases?
6. **Identify credible alternatives.** At least the obvious options; do not strawman.
7. **Compare meaningful trade-offs.** Correctness, complexity, performance, compatibility, operability, maintenance cost, and risk — not popularity.
8. **Recommend one option.** Be decisive.
9. **Explain why rejected options are weaker in this context.** Context-specific, not generic.
10. **Define how the recommendation will be validated.** Tests, benchmarks, review, or a reversible
    rollout.

## Proportionality

Do **not** force a formal decision record onto trivial choices. A variable name, a small refactor, or an obvious bug fix does not need a ten-point analysis. Reserve the full framework for decisions that are expensive to reverse or that set precedent.

- DO write down the decisive reasoning for choices that future maintainers will question.
- AVOID decision theatre — long analyses that restate the obvious and delay the work.

## When facts are missing

- Prefer repository inspection, specifications, and reproducible experiments over asking.
- If a decision genuinely depends on a fact you cannot obtain, state the assumption, choose the safer default, and make the dependency explicit so it can be corrected.
- Do not stall a reversible decision waiting for certainty that inspection can provide.
