# Repair existing documentation and verify behavior

## Assemble the packet queue

Before editing, materialize the machine-readable behavioral review ledger in temporary/session storage with `docfx.cs --repo-root <root> --operation <repair|repair-csrun> --init-behavioral-ledger <temp-ledger> --json` (adding explicit scope flags only when the user restricted scope). The tooling enumerates every in-scope example from the authoritative inventory — including untouched pages with zero deterministic diagnostics, passing compilation or cached transport logs — and tags `changedPriority` without narrowing a repository-wide invocation. Key work by project, UID, page and fence ordinal. For every selected packet take the union of:

- Current validator diagnostics, including follow-on diagnostics after structural fixes.
- Documentation, sample, API or dependency changes since the task's base (for a PR use its merge base with the target branch), plus staged, unstaged and untracked work. Inspect the previous scenario before converting it.
- Every supplied review finding. Map each finding to its affected fence, including duplicates. Record repaired, already resolved or inapplicable with concrete evidence, or unresolved.
- Every in-scope example lacking a current passing behavioral comparison. Enumerate existing fences from the materialized ledger, including untouched files. A compile result, timestamp or previous transport pass alone supplies no comparison.

Deduplicate inspections, retaining all reasons and finding identities. Prioritize `changedPriority` entries within packets without dropping untouched examples. A missing baseline or empty diff still leaves the inventory and findings available.

## Check one example

1. Read the lead, fence, output comments and associated recipe. Before opening runtime captures or executing the example, record the intended consumer scenario, inputs and expected observations from the implementation, public contract or maintained tests for this version and overload. Cite concrete source paths. For variable data use a stable property or relationship. Revise an expectation only when authoritative evidence establishes the original expectation was wrong, and record the reason with that evidence.
2. Trace from the actual entry point. Check every promised branch runs, loops have the correct nesting and counts, and state is observed while valid. Follow data from the call through to the returned object, response, stream, emitted event or assertion. Would the example still appear successful if the documented operation were removed? If yes, inspect what the output actually measures.
3. Execute the example in a representative context or inspect a current capture. Compare values, cardinality, order and labels against the expectation. Inspect the promised response body, state changes and side effects as applicable. Confirm that the intended operation completes, including successful requests in an authentication scenario. Ignored configuration, truncated values, unexpected failures and incomplete scenarios are findings even with exit code 0.
4. Make the smallest correction that restores the original consumer scenario. Preserve host, runner and assembly boundaries. Never rewrite the lead, comments or expected output to accommodate defective execution. Apply [consumer engineering checks](example-architecture.md#preserve-responsibilities) to changed code and any formerly dormant branch the repair activates. Keep already-correct examples intact.

## Critically review the final repair

Once a small, coherent packet is repaired, review its modified examples in a distinct pass before assigning a passing disposition. Prefer an independent reviewer context where supported and authorized, otherwise switch from authoring to a distinct critical review. Read the final diff, documented claims, authoritative evidence and actual observations together. Ask whether the repair introduced a defect, weakened the scenario or demonstrates usage a consumer should avoid. Return failures to repair and review again. Apply this pass to modified examples, including prose-only repairs.

## Reconcile evidence after edits

Keep a comparison tied to the revision actually reviewed. After editing source, prose, expected output, dependencies, recipes or execution topology, reconcile against the live inventory before carrying forward any passing disposition. Refresh the inventory with `--init-behavioral-ledger` to reset stale entries while preserving their findings, or reconcile the existing ledger with `--behavioral-ledger` to see stale diagnostics. Never copy fresh hashes onto an earlier comparison. Reassess known relevant edits even if they fall outside the inventory fingerprints.

Compare the execution inputs independently of the claim. A prose-only change invalidates the comparison, but a capture can be reused when its provenance, source, dependencies, recipe and execution topology still match and it actually measures the current claim. If those execution inputs changed or the capture cannot answer the claim, obtain new evidence. Regenerate affected assets for `repair csrun` and verify each applicable transport independently.

Record the final `documentedOperation`, `consumerScenario`, `authoritativeEvidence`, `expectedObservation`, `actualObservation`, `observationEvidencePath` (or `executionCommand`), `transportStatus` and `findings` in the existing ledger. Assign `verified-behavior` after a passing comparison and applicable final review. Use `source-reviewed-only` for eligible non-executable/project-bound topologies, `unresolved-finding` for defects and `unavailable-execution` for blocked runtime checks. After the last edits, reconcile through `docfx.cs --repo-root <root> --operation <repair|repair-csrun> --behavioral-ledger <temp-ledger> --build-api-model --validate-samples --verify-docfx-build --json` before claiming completion.
