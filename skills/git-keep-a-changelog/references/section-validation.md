# Validate proposed sections

Validate each proposed path-backed outcome before writing it. Reuse the full release scope from Step 1 and the entity boundary from Step 4e, including its supporting files. Pass the intended section to the resolver:

```powershell
pwsh -NoProfile -File <skill-root>/scripts/resolve-release-entity.ps1 -Repository . -BaseCommit <merge_base> -HeadCommit <head_commit> -EntityPath <entity-path> -Section <proposed-section>
```

Use `-IncludeWorktree` for approved pending changes as in Step 4e. A nonzero exit blocks that bullet. Correct its section and consolidate the outcome, then validate again. Keep the same baseline on a subsequent invocation: the previous changelog edit, latest fix commit, and earlier invocation are draft checkpoints, not release boundaries. Re-resolve the complete branch scope even when the conversation already contains an earlier draft.

For example, a new package-update capability followed by scoped-property, XML-decoding, conflict-routing, and encoding fixes still has only `Added` in `allowed_sections`. Summarize its final usable behavior in one `Added` bullet. A separate pre-existing capability is checked against its own entity path. Before writing, reconcile every bullet against these checked outcomes, with each distinct outcome appearing once across all sections.

