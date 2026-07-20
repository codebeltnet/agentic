# Implementation

Load for coding and refactoring tasks.

## Discipline

- **Inspect before editing.** Read the file, its neighbours, and the tests it affects. Understand the existing style and contracts first.
- **Make the smallest coherent change.** Complete and correct, but not broader than the task requires.
- **Preserve public behaviour** unless changing it is the explicit goal.
- **Name meaningfully.** Names should reveal intent and match surrounding conventions.
- **Keep dependency direction clear.** Do not introduce cycles or upward dependencies for convenience.
- **Handle errors appropriately.** Fail where you can act; propagate context where you cannot.
- **Propagate cancellation** where the platform supports it and the operation can be cancelled.
- **Handle resources deterministically.** Acquire late, release reliably, avoid leaks.
- **Avoid speculative abstraction.** Do not add interfaces, options, or extensibility for hypothetical futures. Add them when a second concrete case exists.
- **Update tests and documentation** proportionally to the change.

## Do not

- DO NOT rewrite unrelated code, reformat untouched regions, or "improve" adjacent style.
- DO NOT silently broaden scope; if you discover necessary adjacent work, name it.
- DO NOT optimize for fewer lines at the expense of API clarity or correctness.
- DO NOT remove pre-existing code that is unrelated to your change; if it looks dead, mention it rather than delete it.

## Orphan cleanup

When your change makes an import, variable, parameter, or helper unused, remove **that** orphan. Do not extend cleanup to pre-existing dead code unless the task asks for it.

## Refactoring

- Keep behaviour identical unless the task states otherwise; rely on tests to prove it.
- Prefer a sequence of small, verifiable steps over one large rewrite.
- Ensure tests pass before and after. If there is no test covering the behaviour you are about to change, add one first.

## The test for every changed line

Every line you change should trace directly to the user's request or to a correctness need created by it. If it does not, revert it.
