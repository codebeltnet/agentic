# Validate proposed sections

Section checks establish where an outcome belongs, not whether its description is accurate. For each proposed bullet, verify its subject, change verb, versions, affected scope, and stated effect against the working evidence record. Apply the same review to the release highlight and retained draft clauses. If a compound sentence contains an unsupported claim, remove or correct that clause even when the rest of the sentence is true.

For dependencies inside surviving manifests, read `dependency-removals.md`. Validate package-level existence and scope from the manifest delta; the containing file's `Changed` classification does not classify its added or removed entries. A surviving incoming package belongs under `Added`, and an outgoing direct package belongs under `Removed`; use `Changed` only for an independently evidenced migration effect.

For switches between package identifiers, verify rename and upgrade claims separately. If the outgoing package survives transitively, qualify `Removed` as removal of its direct reference and require dependency metadata or graph evidence for that retention claim.

For changed source files, validate user-facing sub-outcomes separately from the file's path classification. A pre-existing type can contain a new `Added` capability; keep its integral headers, protocol negotiation, lifecycle operations, examples, and configuration validation with that capability. Name a public configuration member with its declared type when the type determines the supported modes. The resolver classifies the containing file as `Changed`; validate it with `-Section Changed` and place the new capability bullet under `Added` from symbol-level before/after evidence. A `Changed` path classification never vetoes an `Added` sub-outcome and never requires the resolver to list `Added` in `allowed_sections` for that path.

In yolo/auto, pending changes are already included. Pass `-IncludeWorktree` during section validation as well as initial classification so pending-only additions and deletions are checked against the same effective final state. Reading untracked contents and reconciling pending manifest entries remain required even when the committed range is empty.

Validate each path-entity boundary before writing it. Reuse the full release scope from Step 1 and the entity boundary from Step 4e, including its supporting files. Pass the path's own section to the resolver (for example, `Changed` for a modified pre-existing file); validate semantic `Added` or `Removed` sub-outcomes inside a `Changed` path from their own before/after evidence instead of requiring the containing path to allow that section:

```powershell
pwsh -NoProfile -File <skill-root>/scripts/resolve-release-entity.ps1 -Repository . -BaseCommit <merge_base> -HeadCommit <head_commit> -EntityPath <entity-path> -Section <proposed-section>
```

Use `-IncludeWorktree` for approved pending changes as in Step 4e. A nonzero exit blocks that bullet. Correct its section and consolidate the outcome, then validate again. Keep the same baseline on a subsequent invocation: the previous changelog edit, latest fix commit, and earlier invocation are draft checkpoints, not release boundaries. Re-resolve the complete branch scope even when the conversation already contains an earlier draft.

For example, a new package-update capability followed by scoped-property, XML-decoding, conflict-routing, and encoding fixes still has only `Added` in `allowed_sections`. Summarize its final usable behavior in one `Added` bullet. A separate pre-existing capability is checked against its own entity path. Before writing, reconcile every bullet against these checked outcomes, with each distinct outcome appearing once across all sections.

