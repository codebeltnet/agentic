# Repair existing documentation and verify behavior

## Assemble the packet queue

Use the existing inventory in temporary/session storage. Key work by project, UID, page and fence ordinal. For every selected packet take the union of:

- Current validator diagnostics, including follow-on diagnostics after structural fixes.
- Documentation, sample, API or dependency changes since the task's base (for a PR use its merge base with the target branch), plus staged, unstaged and untracked work. Inspect the previous scenario before converting it.
- Every supplied review finding. Map each finding to its affected fence, including duplicates. Record repaired, already resolved or inapplicable with concrete evidence, or unresolved.
- Every in-scope example lacking a current passing behavioral comparison. Enumerate existing fences from the packet inventory, including untouched files. A compile result, timestamp or previous transport pass alone supplies no comparison.

Deduplicate inspections, retaining all reasons and finding identities. Prioritize changes within packets. A missing baseline or empty diff still leaves the inventory and findings available. Reuse a comparison only when the displayed source, API version/dependency pins, execution recipe, topology and relevant claim still match; recheck changed prose even when the script hash is identical.

## Check one example

1. Read the lead, fence, output comments and associated recipe. Name the documented operation, consumer scenario, inputs and observable result. Derive the expected result for this version and overload from its implementation, public contract, relevant tests and maintained usage. Record concrete source paths. For variable data use a stable property or relationship.
2. Trace from the actual entry point. Check every promised branch runs, loops have the correct nesting and counts, and state is observed while valid. Follow data from the call through to the returned object, response, stream, emitted event or assertion. Would the example still appear successful if the documented operation were removed? If yes, inspect what the output actually measures.
3. Execute the existing example where supported using its established topology. Compare values, cardinality, order and labels against the expectation. A middleware header comes from the response after the request traverses the pipeline. Authentication evidence comes from exercising the handler. Options, inputs and expected constants alone cannot show these effects.
4. Correct the smallest part that restores the consumer scenario. Preserve required host/runner and assembly boundaries. Exercise missing operations before considering a prose change. Correct inaccurate labels or expected results from evidence. Check acquisition, ownership, disposal, formatting and indentation in the rendered fence. Keep a console demonstration concise; use a test runner when it is part of the scenario.
5. Re-execute the final displayed code. Record the expectation, observation, source identity, command and status in the inventory; distinguish source inspection from execution. For composed repair regenerate affected recipes/assets and compare each supported transport's result. Keep already-correct source intact. Resolve or carry forward every finding before applying the completion contract.
