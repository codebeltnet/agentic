# Parameter Form

Use this form only when pending worktree changes are detected and the skill must ask whether they belong in the changelog draft. Present each field **one at a time** using the host's native structured input controls when available. If native controls are unavailable, use the deterministic plain-text fallback below. Do not use this form when there are no pending changes to confirm.

## Fields

### include_pending_changes
- **type:** single-choice
- **prompt:** "I found pending uncommitted changes for release `{release_label}`: `{staged_count}` staged, `{unstaged_count}` unstaged, `{untracked_count}` untracked. Include them in the changelog draft?"
- **choices:**
  - Yes
  - No
  - Custom
- **required:** true
- **description:** `Yes` includes the pending staged, unstaged, and untracked changes in addition to the committed range. `No` uses committed history only. `Custom` lets the user narrow the pending scope.

### custom_pending_scope
- **type:** text
- **prompt:** "Which pending changes should I include?"
- **placeholder:** "e.g. staged only, exclude untracked"
- **required:** true
- **description:** Ask this field only when `include_pending_changes` is `Custom`.

## Presentation Rules

1. Compute the dynamic prompt values from the actual repo state before showing the form:
   - `{release_label}` = the visible changelog target such as `1.2.3` or `Unreleased`
   - `{staged_count}` = count of staged changes
   - `{unstaged_count}` = count of unstaged tracked changes
   - `{untracked_count}` = count of untracked files
2. Ask one field at a time — wait for the answer before presenting the next field.
3. Prefer the host's native structured input controls for the `include_pending_changes` field when they are available.
4. If native structured input controls are unavailable, use this exact plain-text fallback for the first field:
   ```text
   Field: include_pending_changes
   I found pending uncommitted changes for release {release_label}: {staged_count} staged, {unstaged_count} unstaged, {untracked_count} untracked. Include them in the changelog draft?
   1. Yes
   2. No
   3. Custom
   ```
5. In the plain-text fallback, allow the user to answer with either the number or the exact option text, then restate the normalized value in one short line before moving on.
6. Ask `custom_pending_scope` only when the chosen value is `Custom`.
7. Keep the meaning stable across both input modes:
   - `Yes` = include all pending staged, unstaged, and untracked changes in addition to the committed range
   - `No` = use committed history only
   - `Custom` = collect a narrower pending-change scope such as `staged only`
8. After all fields are collected, present this short summary and ask for confirmation before proceeding:
   ```text
   Pending change handling:
     Release:   {release_label}
     Staged:    {staged_count}
     Unstaged:  {unstaged_count}
     Untracked: {untracked_count}
     Decision:  {resolved_scope}

   Proceed with this changelog scope?
   ```
