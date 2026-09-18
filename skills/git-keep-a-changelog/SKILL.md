---
name: git-keep-a-changelog
description: >
  Use when the user wants to create or update `CHANGELOG.md`, follow Keep a Changelog, or finalize a versioned changelog. Treat `ready to release` or `rtr` as triggers only with version context. Do not trigger for GitHub releases, NuGet package notes, commit execution, or bare `yolo`/`auto`.
compatibility: >
  Requires Git and PowerShell 7+ for deterministic branch-scope resolution.
---

# Git Keep A Changelog

![Git Keep A Changelog](assets/hero.jpg)

This skill creates or updates `CHANGELOG.md` directly using the Keep a Changelog 1.1.0 structure. It is git-aware, changelog-focused, and optimized for a human-readable release summary rather than generated release-note noise.

## Writing contract

Explain what changed for the reader using verified differences between the release base and final state. Establish facts before choosing release language. A plausible description is insufficient: every factual clause in a bullet or highlight must be supported by inspected evidence.

For each surviving outcome, establish the entity and scope, its before and after state, the evidence location, and the supported effect. Keep this compact working record in context; no additional repository artifact is required. Use it to draft the entry, then review the actual written text against it. Existing changelog prose and commit messages are claims to check, not facts to carry forward.

Use the most specific wording the evidence supports. When a reason, identity relationship, or user impact is unknown, describe the observed change without that explanation. Investigate further when the missing fact affects classification; otherwise omit the unsupported clause. Do not fill gaps from naming similarities or familiar migration patterns.

Before drafting prose, build a complete evidence ledger in working context. Give every changed, staged, unstaged, and included untracked path a base state, final state, user-facing outcome or evidence-backed omission, and proposed section. For manifests, add a separate row for every package identity and direct declaration. For changed source and public documentation, split the file into its user-facing sub-outcomes — public members and types, routes, HTTP headers, protocol versions, examples, validation, and documented behavior — instead of reducing the whole file to one broad label. Do not start writing until this inventory is reconciled against the final state.

Read `FORMS.md` when pending worktree changes require user confirmation and the host supports native structured input controls. If native structured input is unavailable, use the deterministic plain-text fallback defined there. `FORMS.md` is not used in yolo/auto mode — see **Yolo / Auto Mode** below.

## Yolo / Auto Mode

Only after this skill has been selected by explicit changelog or release-note intent, `yolo` or `auto` in that same request (case-insensitive) enables full-autonomy mode. Bare `yolo` / `auto`, `git bot commit yolo`, and other commit-execution requests do not activate this skill:

- **Skip Step 3's confirmation only.** Do not ask the confirmation question. Do not present the `Yes / No / Custom` gate. Still discover and inspect every pending change in Step 4.
- **Include all pending changes automatically.** Staged, unstaged, and untracked files are all treated as part of the release scope without asking.
- **Keep committed history isolated.** Yolo changes only the pending-worktree decision; use the same resolved branch ranges and bleed guard as every other invocation.
- **Make all scope decisions independently.** The user has explicitly delegated judgment. Do not pause for input at any point in the workflow.
- All other quality rules remain in force: the release highlight is still required, the SemVer classification is still required, bullet punctuation still applies, and the compare-link footer must still be maintained.

## Non-Negotiable Rules

- Create or update `CHANGELOG.md` directly, then stop for user review.
- If `CHANGELOG.md` does not exist, create a compliant one before populating it.
- Read full commit subjects and bodies before writing the changelog.
- Inspect the net diff too; do not infer the release from subjects alone.
- Classify each user-facing release entity from whether it existed at the resolved base before considering intermediate commits or individual files.
- Treat branch or range topology as the changelog scope source of truth, not author identity.
- For branch-derived scope, exclude every commit already reachable from the comparison branch. A merge-base is a boundary, not a release commit.
- Run `scripts/resolve-release-scope.ps1` for branch-derived scope and use its emitted ranges without widening them.
- For every path-backed release entity, run `scripts/resolve-release-entity.ps1` with the emitted `merge_base` and `head_commit`; use its classification instead of inferring `Added`, `Removed`, or `Changed` from commit verbs.
- Before writing each path-backed outcome, rerun that resolver with `-Section <proposed-section>` and require success. Its `allowed_sections` bind the final bullet, including on subsequent runs.
- Never change range inclusivity because the changelog target is a concrete version instead of `[Unreleased]`.
- Include commits from every author/contributor in the selected scope. Do not filter to the current git user, current contributor, bot identity, configured author, or "my changes" unless the user explicitly asks for an author-filtered changelog.
- If the current branch starts with a version hint such as `v0.3.0/`, use that to target a concrete release heading.
- If a concrete target heading already exists but its matching `vX.Y.Z` tag does not, treat that heading as an unreleased draft and regenerate it from the resolved git result instead of preserving stale bullets as a second baseline.
- Otherwise, target `## [Unreleased]`.
- Always write a release highlight immediately below the target heading.
- The release highlight must explicitly classify the release as `major`, `minor`, or `patch`.
- Use the standard Keep a Changelog section order: `Added`, `Changed`, `Deprecated`, `Removed`, `Fixed`, `Security`.
- Explicitly name removed dependencies under `Removed`, including test/build tooling, even when `Changed` explains their replacement. Read `references/dependency-removals.md` for classification and verification.
- A switch between package identifiers is not proof of a rename or version upgrade. Verify package identity, version changes, and direct versus transitive scope separately using that reference.
- When a final manifest introduces a package identifier that was absent at the base, classify that incoming dependency under `Added`; classify an outgoing direct identifier that is absent from the final declarations under `Removed`. If the incoming package provides a newly evidenced integration capability, describe that capability under `Added` and the outgoing direct-reference scope under `Removed`; do not collapse the two package-level outcomes into a generic `Changed` switch.
- Package-level outcomes are independent of the containing file's classification: one changed manifest can carry `Added` incoming packages, `Changed` identity-preserving upgrades, and `Removed` outgoing packages at the same time. Account for each surviving package identity separately.
- An included untracked configuration file is an `Added` outcome when it is absent at the base and present in the final state. Read its contents and describe the behavior it configures; do not omit it because it has no committed diff.
- Omit empty sections instead of emitting placeholders.
- Always maintain the Keep a Changelog compare-link footer at the bottom of the file.
- **Never hard-wrap changelog prose.** Keep every paragraph and bullet item on one physical line, regardless of length. Do not insert line breaks to satisfy 80, 100, 120, or any other column width; rely on editor soft wrapping. Insert physical line breaks only between Markdown structures, and rejoin unnecessary wraps in prose you touch. Treat any arbitrary line break inside a paragraph or bullet as a formatting failure that must be corrected before completion.
- End each bullet with `,` and end the last bullet in each section with `.`.
- If pending worktree changes exist for a concrete release draft, do not silently include or exclude them. Ask the user first with a short `Yes / No / Custom` prompt. **Exception: in yolo/auto mode, include all pending changes automatically without asking.**
- Yolo/auto changes pending-worktree handling only. It never widens committed history or includes the comparison boundary.
- Do not dump commit subjects verbatim into the changelog.
- Do not treat the current contents of the target heading as a release-classification baseline; git state is the baseline.
- Do not invent unsupported changes, risks, or migration guidance.

## Mandatory Checkpoints

These checkpoints cannot be skipped or bypassed, even when the user's opening request sounds like a shortcut.

1. Step 3 confirmation gate: if pending worktree changes exist for a concrete release such as `## [1.2.3]`, present the confirmation question before drafting or writing the changelog entry. **Bypassed in yolo/auto mode — all pending changes are included automatically.**
2. Release isolation: for branch-derived scope, run the bundled resolver and require `base_history_bleed` to be `false`. The `excluded_boundary_commit` must not appear in `selected_commits`.
3. Release highlight contract: every concrete release entry must include a release highlight paragraph that explicitly classifies the release as `major`, `minor`, or `patch`.
4. Bullet punctuation: all bullets must end with `,` except the final bullet in each populated section, which must end with `.` Do not finish the edit until this is consistent.
5. Factual review: reread the written target entry and verify every factual clause against the before/after evidence, including clauses retained from an existing draft. Section validation alone does not establish that the prose is true.

## Deterministic Reduction Model

When the comparison scope is resolved, use this model:

```text
Result = semantic_delta(Base, HEAD [+ approved pending changes])
History = provenance used to explain Result
```

History is evidence; the resulting state is truth.

When pending changes are included, every `HEAD` endpoint in the classification rules below means the effective final state: committed content overlaid with the selected staged, unstaged, and untracked changes. Pending changes can remove or undo committed outcomes; they are not merely extra bullets. An empty committed diff does not mean an empty release draft.

The current contents of the target heading are cached output, not a release baseline. When rerunning on an unreleased version branch whose matching tag is absent, discard the prior draft narrative and regenerate the heading from the resolved base-to-`HEAD` result so later refinements to the same new capability remain part of its `Added` outcome.

Reduce first. Interpret second. Summarize last.

Establish the classification baseline at the user-facing release-entity boundary, not independently for every changed file. For a repo-managed skill, the entity is the skill capability together with its dedicated files and inseparable registration, catalog, documentation, validation, and eval wiring. If that entity is absent at the base and present at `HEAD`, its introduction is `Added`; intermediate commits that refine, fix, document, or validate it cannot create `Changed` or `Fixed` outcomes for that same new entity. A change to a separately pre-existing shared capability remains its own outcome and is classified from its own base state.

### Layered Capability Classification

Do not use a top-level directory or the first framework commit as the only release entity. Classify at the smallest independently selectable user-facing boundary. For layered eval tooling, the protocol/framework and each selectable runner, CLI, TUI, or harness adapter can have different release states.

- A child adapter absent at the resolved base and present at `HEAD` is `Added` even when its parent directory already existed at the base or was introduced earlier in the branch. Run the entity resolver for the parent and each independent child path when the diff supports that decomposition.
- Keep implementation, fixtures, conformance tests, and wiring with the capability they introduce. Do not repeat an adapter in a parent `Added` bullet and again in `Changed` as “added to the lineup.”
- Refinements to a pre-existing adapter or framework are `Changed` or `Fixed` from their final delta. A defect repaired before first release of a base-absent capability remains part of that capability's `Added` outcome.
- A planned, blocked, or unsupported CLI/TUI/harness is not support and must not be listed as an `Added` adapter.

Use the final state, not commit verbs: newly usable execution support belongs under `Added`; changes to existing runner, orchestration, report, telemetry, or package behavior belong under `Changed`; and distinct supported repairs belong under `Fixed`. For example, a new framework followed by GitHub Copilot and OpenCode adapters gets `Added` outcomes for the framework and adapters, while changes to an existing Codex adapter are classified separately.

1. Inspect cumulative manifest and version deltas across `diff_range`.
2. Inspect the cumulative base-to-`HEAD` diff.
3. Inspect any approved pending worktree changes that are part of the draft.
4. Determine which changes actually survive at the final state.
5. Read chronological commit subjects and bodies as supporting context.
6. Use history to explain the surviving outcomes, then map them into Keep a Changelog sections.

Do not summarize commits one by one and deduplicate the prose afterward. Classify only surviving release outcomes.

Reconciliation rules:

- Base absent and `HEAD` absent -> omit it.
- Release entity absent at base and present at `HEAD` -> one surviving `Added` outcome in its final form. Do not emit `Changed` or `Fixed` outcomes for refinements within that same introduction cycle.
- Base present and `HEAD` absent -> one surviving `Removed` outcome.
- Base present and identical `HEAD` state -> omit it.
- Base present and changed `HEAD` state -> one surviving modification whose section is derived from the final delta.
- Equivalent entity at path A in base and path B in `HEAD` -> treat it as a rename or move when the cumulative diff supports that, not `Added` plus `Removed`.

Examples:

- Dependency `1.0 -> 2.0 -> 1.0` -> no changelog entry.
- Feature added, fixed three times, then removed -> no changelog entry.
- Existing behavior changed and then reverted exactly -> no changelog entry.
- File deleted and recreated identically -> no changelog entry.
- One capability added, revised, and still present -> usually one `Added` bullet describing its final form, not separate `Added`, `Changed`, and `Fixed` bullets.
- New `skills/dotnet-test/` capability added, then documented, validated, and refined before release -> `Added` only for the complete shipped capability. README registration and validator/eval wiring whose sole purpose is that introduction stay part of the added outcome.
- Existing `## [0.9.0]` draft with one `Added` bullet, then more commits refine the same unreleased `dotnet-test` capability -> rewrite the draft so `dotnet-test` stays under `Added`; do not append `Changed` or `Fixed` just because the earlier draft already exists.

## Release Highlight Contract

Every updated changelog entry must begin with a short human-written highlight paragraph directly below the heading.

That highlight must:

- act as the TL;DR for the release
- explicitly say whether this is a `major`, `minor`, or `patch` release
- summarize the net effect of the populated sections
- reflect the full commit bodies and net diff, not just the subjects

Example shape:

```md
## [0.3.0] - 2026-03-16

This is a minor release focused on grouped git visual summaries,
validator hardening, and clearer changelog automation guidance.

### Added
...
```

When the history clearly carries migration risk or upgrade caveats, add an advisory block such as:

```md
> [!WARNING]
> Upgrading to this release requires ...
```

Only add callouts when the commits or diff justify them.

## User Intent vs. Mandatory Gates

### User intent can refine scope after the gate

Explicit instructions such as `staged only`, `include unstaged changes`, or `exclude untracked` can refine the changelog scope after the Step 3 confirmation gate has been presented and answered.

### User intent cannot bypass the gate

- Do not skip Step 3 just because the user says `include everything`, `all changes`, `commit manually`, or `don't ask`.
- Do not omit the release highlight paragraph for a concrete release.
- Do not omit the explicit `major`, `minor`, or `patch` classification.

The Step 3 confirmation gate exists to prevent silent inclusion of worktree changes in a permanent release entry. It is a required safety checkpoint, not optional friction.

**Exception — scoped yolo/auto bypasses the gate by design.** When the user explicitly passes `yolo` or `auto` within an explicit changelog or release-note request, they are granting full autonomy for that changelog task. That is not a vague hint like `include everything` — it is a deliberate, recognized mode. Skip Step 3, include all pending changes, and proceed.

## Workflow

### Step 1: Resolve the source range

Use the most explicit scope the user gave you.

- If the user named a complete range, use that exact range. Do not silently add `^`, move its boundary, or reinterpret inclusivity.
- If the user named a base branch or PR target, pass it as `-BaseRef` to the bundled resolver.
- Otherwise, run the resolver without `-BaseRef`. It derives the remote's default branch from the current branch's tracking remote, then falls back to `origin/main`, `origin/master`, `main`, or `master` only when those refs exist locally.
- Never use the current feature branch's same-name tracking ref as its comparison base. For example, `origin/v1.2.3/service-update` tracks delivery of the feature branch; it is not the branch the PR changes are measured against.
- Do not fetch, pull, or contact a remote while resolving scope. Use local refs. If the correct PR target is not available locally, stop and ask for the base branch instead of guessing.

Never add `--author`, `--committer`, current-user, current-email, current-contributor, or identity-mode filters while resolving ordinary branch-level changelog scopes. Author metadata may help explain ownership, but it must not narrow the default release scope.
Do not stop to ask whether the latest branch commit, release-prep commit, or another contributor's commit "should count". If it is on the selected branch or range, it is in scope by default unless the user explicitly narrows the author or range.

For a branch-derived scope, run:

```powershell
pwsh -NoProfile -File <skill-root>/scripts/resolve-release-scope.ps1 -Repository .

# When the user named the PR target or base branch:
pwsh -NoProfile -File <skill-root>/scripts/resolve-release-scope.ps1 -Repository . -BaseRef origin/release/1.x
```

The JSON output separates two evidence surfaces:

- `history_range` is the commit-SHA-pinned equivalent of `<comparison-ref>..HEAD`. Use it for commit logs because it selects commits unique to the checked-out branch and excludes everything already reachable from the comparison branch.
- `diff_range` is the commit-SHA-pinned equivalent of `<merge-base>..HEAD`. Use it for manifest and net diffs because it measures the branch's resulting file changes from the common boundary without treating later base-only work as removals.

The comparison boundary is always excluded from a branch-derived release, even when it is tagged or the changelog target is a concrete version. If the previous release tag points at the merge-base, that confirms the commit belongs to the previous release; it is not a reason to include it.

`history_range` includes every branch-unique commit after the boundary, including the earliest PR commit and every contributor.

### Step 2: Resolve the changelog target

Determine whether to write a concrete release section or update `[Unreleased]`.

When the user asks to "finalize", "ready to release", "rtr", "release", "publish", or "ship" (or similar release-intent words):
- Extract the version from the current branch name if it starts with a version prefix such as `v0.3.0/feature-name`.
- When the target is `## [X.Y.Z]`, check whether `refs/tags/vX.Y.Z` exists locally. If it does not, any existing `## [X.Y.Z]` section is still a branch draft rather than released history.
- Target `## [X.Y.Z] - YYYY-MM-DD` (today's date) for that extracted version.

Otherwise:
- If the branch name starts with a version prefix such as `v0.3.0/feature-name`, target `## [0.3.0] - YYYY-MM-DD`.
- Strip the leading `v` from the visible changelog heading, but keep tag comparisons in `vX.Y.Z` form.
- If no version hint exists, target `## [Unreleased]`.
- If the target heading already exists, update it in place instead of duplicating it.
- For an existing concrete heading whose matching tag is absent, replace the release highlight and populated sections wholesale from the current resolved git evidence. Do not preserve an older `Added` bullet and then layer later pre-release refinements into `Changed` or `Fixed`.

### Step 3: Confirm Pending Worktree Changes (MANDATORY GATE)

This is a required checkpoint. Do not proceed to Step 4 until this step is complete.

After resolving the target heading, check whether the worktree contains changes that are not part of the committed history yet.

**If yolo/auto mode is active: skip the confirmation gate.** Include all pending changes (staged, unstaged, untracked) automatically and proceed to Step 4's complete inventory and content inspection.

- Count staged, unstaged, and untracked changes separately.
- If there are no pending changes, continue normally.
- If there are pending changes and the target is a concrete release heading such as `## [1.2.3]`, you must ask a direct confirmation question before drafting the changelog entry.
- User intent hints such as `all changes`, `include everything`, `commit manually`, or `don't ask` do not bypass this gate.
- When the host supports native structured input controls, use `FORMS.md` for this confirmation flow, but keep the prompt text and `Yes / No / Custom` meaning identical to the plain-text path.
- Present this question:

```text
I found pending changes not yet committed for release 1.2.3: 4 staged, 2 unstaged, 1 untracked. Include them in the changelog draft? Yes / No / Custom
```

- Do not skip this question.
- Keep the prompt short and concrete. Do not drift into commit-range jargon or enumerate scope rules unless the user chooses `Custom` or asks for detail.
- `Yes` means include the pending changes in addition to the committed range.
- `No` means use committed history only.
- `Custom` means let the user narrow the scope, for example `staged only` or `exclude untracked`.
- Keep the widget-backed path and the plain-text fallback semantically identical: same `Yes / No / Custom` order, same meaning, and the same follow-up scope question only when `Custom` is chosen.
- Wait for the user's explicit response before proceeding to Step 4.
- For `## [Unreleased]`, use the same short prompt when pending worktree changes are relevant to the user's request. Do not silently fold them into the draft unless the user explicitly asked for current worktree coverage.

Helpful commands:

```bash
git status --short --branch
git diff --cached --stat
git diff --stat
git ls-files --others --exclude-standard
```

### Step 3b: Verify Release Isolation

For branch-derived scope, inspect the resolver output before reading history or diffs:

1. Require `base_history_bleed` to be `false`.
2. Confirm `excluded_boundary_commit` is absent from `selected_commits`.
3. Confirm `comparison_ref` is the intended PR target or default branch, not the current feature branch's tracking ref.
4. Record `history_range` and `diff_range` exactly as emitted. Do not append `^` or widen either range for a concrete release.

If any check fails, stop without editing `CHANGELOG.md`. Report the resolved refs and ask for the correct base branch. This is a correctness failure, not a reason to guess another range.

### Step 4: Read the cumulative result before the chronology

Follow these sub-steps in order. Manifest detection and cumulative manifest diffs must run before commit-body interpretation.

**4a — Discover the complete changed-file inventory, then detect manifests.** Start with the emitted `diff_range`:

```bash
git diff --name-only <diff_range>
```

When pending changes are included (automatically in yolo/auto), union that inventory with the selected staged, unstaged, and untracked paths before detecting manifests:

```bash
git diff --cached --name-only
git diff --name-only
git ls-files --others --exclude-standard
```

Deduplicate paths, but retain deletions. Read the contents of included untracked files; listing their names is not inspection. Include manifests changed only in the worktree or newly untracked, even when `diff_range` is empty. Do not stage files to make Git show them. Independent file reads may run concurrently with bounded concurrency; reconcile the combined evidence before classifying or editing.

If any dependency or version manifest appears — `Directory.Packages.props`, `Directory.Build.props`, `*.csproj`, `*.fsproj`, `*.vbproj`, `package.json`, `pnpm-lock.yaml`, `yarn.lock`, `pom.xml`, `build.gradle`, `go.mod`, `go.sum`, or similar — proceed to 4b immediately. Do not read commit bodies first.

**4b — Diff each touched manifest.** For every manifest found in 4a, run its cumulative diff across the emitted `diff_range`:

```bash
git diff <diff_range> -- Directory.Packages.props
git diff <diff_range> -- package.json
# Repeat for every manifest identified in 4a.
```

When all pending changes are included, also compare each tracked manifest directly from the resolved base to its current working copy with `git diff <merge_base> -- <manifest-path>` (a single base endpoint, not `<diff_range>`). Read included untracked manifests directly and compare their package identities with the base and other final manifests. This catches references moved into new shared files without inventing removals. For a custom pending subset, reconstruct only that subset from committed content plus its selected deltas; do not use the full working copy for a staged-only scope.

Read `references/dependency-removals.md` for every dependency delta, including pending-only changes. First record each exact package identity, affected project/target, and base and final direct declarations and versions. Record resolved dependency relationships separately when evidence exists. A manifest diff proves declaration changes; it does not by itself prove package identity continuity, dependency graph changes, or newly used capabilities.

Only then classify the facts: a version change within one identity supports one `Changed` upgrade/downgrade outcome; an incoming identity absent at the base and present at the final state is one `Added` dependency outcome; an outgoing identity present at the base and absent from final direct declarations is one `Removed` outcome. Before drafting `Changed`, verify that every surviving same-identity version pair has been accounted for. Describe the relationship as a switch or replacement when the project evidence supports it, without adding a redundant `Changed` bullet. Call it a rename only with independent evidence of identity continuity. Additional capabilities or transitive retention require their own evidence. Do not compare version numbers belonging to different identities as if they formed one version history.

**4c — Inspect the cumulative diff before history.** Use the emitted `diff_range`:

```bash
git diff --name-status -M -C <diff_range>
git diff --stat <diff_range>
git diff <diff_range>
```

Resolve the cumulative file, config, dependency, and behavior deltas from base to `HEAD`. Do not derive the changelog by accumulating labels from individual commits.

**4d — Inspect approved pending changes when they are in scope.** When the user approved pending changes in Step 3, also inspect the selected worktree deltas. In yolo/auto mode, inspect all of them automatically:

```bash
git diff --cached
git diff
git ls-files --others --exclude-standard
```

Read the included untracked files, then reconcile all selected deltas against the same base. When all pending changes are included, `git diff <merge_base> --` shows the net tracked-file result, including cancellations between commits, index, and worktree; untracked content must still be inspected separately. Pending changes overlay committed state rather than forming an independent list of additions. They never justify widening `history_range` or `diff_range`.

**4e — Determine the surviving outcomes at the final state.**

- Identify each user-facing release entity and test its existence at the resolved base before classifying its child paths or commit verbs.
- For each path-backed entity, run the bundled classifier. Pass `-IncludeWorktree` on both classification and `-Section` validation whenever that entity's full pending state is included, including automatically in yolo/auto. Omitting it validates committed content only. Do not use it for a custom subset that excludes some changes to the entity; verify that subset's effective state separately instead of treating a HEAD-only result as final:

```powershell
pwsh -NoProfile -File <skill-root>/scripts/resolve-release-entity.ps1 -Repository . -BaseCommit <merge_base> -HeadCommit <head_commit> -EntityPath skills/dotnet-test
```

- Treat the emitted `classification` as authoritative for the path entity's own existence (`Added`, `Removed`, `Changed`, or `Unchanged`). The resolver classifies whole paths, not entries inside a manifest or symbols inside a source file. A `Changed` path can therefore carry `Added` or `Removed` sub-outcomes at package or capability level; validate those sub-outcomes from their own before/after evidence as described in `references/dependency-removals.md` and `references/section-validation.md`. Use semantic analysis to group paths into the correct user-facing entity and to choose among non-structural sections such as `Fixed` or `Security` when the entity already existed at the base.
- Eliminate exact reversions, temporary files/features, and dependency churn that returned to the base value.
- Merge intermediate add/change/fix churn into the final surviving capability or behavior.
- A new behavior introduced inside an existing source file is still an `Added` capability when that behavior was absent at the base. Validate the containing file itself as `Changed` via the resolver; place the new capability bullet under `Added` from symbol-level before/after evidence. Keep validation, protocol negotiation, required headers, lifecycle operations, and examples that make the same new capability usable together under `Added`; do not move an integral validation branch to `Fixed` merely because the containing type pre-existed.
- For every changed source file, compare the symbol-level before and after state and account for newly introduced public properties, declared types, methods, endpoints, headers, protocol constants, examples, and validation branches. When a configuration property's type carries the feature semantics, name both the property and its declared type, such as `SessionMode` of type `HttpServerSessionMode` on `McpDocumentOptions`.
- A pre-existing file that remains present but changes, including `CONTRIBUTING.md`, is `Changed` at the path level. A new capability documented in that file may be mentioned in the capability's `Added` outcome, but the file itself must not be described as newly introduced.
- Preserve rename/move as one surviving outcome when the cumulative diff supports it.
- Do not place one surviving outcome under multiple changelog sections merely because its lifecycle crossed several verbs during development.

**4f — Read the full branch-unique commit log.** Use the emitted `history_range`:

```bash
git log --reverse --format=medium <history_range>
git log --reverse --stat --format=medium <history_range>
```

Read every selected contributor's full subject and body. The boundary commit and any commit already reachable from the comparison branch are absent by construction and must remain absent.

Use history only to explain the surviving outcomes: investigate rationale, terminology, and intended relationships, then check those claims against the resulting files and relevant metadata. A commit that calls something a rename, upgrade, fix, or optimization does not establish that outcome. Never let an intermediate commit override contradictory final-state evidence.

### Step 5: Classify the release

Infer the SemVer class from the surviving change set.

- `major` when the release includes breaking removals, required migration, incompatible contract changes, or other true breaking behavior.
- `minor` when the release adds meaningful new capabilities without breaking existing consumers.
- `patch` when the release is primarily fixes, service updates, docs, validation, maintenance, dependency work, or other non-breaking refinement.

Do not over-classify from dramatic wording in a commit subject. The surviving delta matters more than the phrasing of one commit.

### Step 6: Curate the changelog content

Draft the populated sections from the verified outcomes, then write the release highlight to summarize them. Place the highlight before the sections in the file.

Read `references/section-validation.md` and validate every path-entity boundary with `-Section` matching its own path classification before writing. Do not require the resolver to list `Added` for a `Changed` file's new-capability sub-outcome; validate the containing file as `Changed` and place the semantic capability under `Added` from symbol-level evidence. Reuse the complete branch baseline on subsequent runs and consolidate each outcome once across all sections.

- Map only the surviving outcomes into `Added`, `Changed`, `Deprecated`, `Removed`, `Fixed`, and `Security`.
- Keep bullets curated and human-written.
- Merge overlapping commits into one bullet when they describe the same real outcome.
- A capability absent at the base and present at the final state appears under `Added`, even when later commits fixed, documented, validated, or refined it before release.
- Supporting catalog, documentation, validator, and eval changes whose sole purpose is introducing that new capability stay with its `Added` outcome. Classify a shared-file change separately only when it changes a pre-existing capability independently of the new introduction.
- A capability, file, or dependency change that returned to the base state stays out of the changelog entirely.
- Drop low-signal churn such as typo-only commits, trivial fixups, or mechanical follow-ups unless they materially change the release story.
- Choose each change verb from the verified before/after facts. A sentence combining several claims must support each one separately; remove any unsupported qualifier, explanation, or effect.
- Represent a package switch with separate `Added` and `Removed` outcomes when the incoming and outgoing identities have different base-to-final existence states; use `Changed` only for an independently evidenced migration effect or an identity-preserving version change.
- Before finalizing, reconcile the written entry against the evidence ledger: every included untracked file, every same-identity package version delta, every outgoing direct dependency, and every user-facing source-level addition must either appear in the appropriate section or have a recorded reason for omission. A broad summary is not a substitute for those surviving outcomes.
- Keep every changelog paragraph and bullet item on a continuous physical line. Break lines only between Markdown structures, and rejoin arbitrary wraps in prose you edit.
- End each bullet with `,` except the final bullet in a populated section, which must end with `.`.

### Step 7: Update CHANGELOG.md carefully

Preserve the file's existing structure while editing.

- If `CHANGELOG.md` is missing, create it with the standard title, intro paragraph, `## [Unreleased]`, and compare-link footer before inserting release content.
- Keep the introduction and existing release history intact.
- If writing a concrete release section, insert it below `## [Unreleased]` and above older releases.
- If writing to `## [Unreleased]`, keep the heading and update only its content.
- When updating an existing target heading, rebuild the release highlight and populated sections from the newly resolved surviving outcomes. Delete or rewrite stale bullets that no longer reflect the final release story instead of incrementally patching around them.
- On every edit, verify that the compare-link footer exists at the bottom of the file. If it is missing or incomplete, insert or repair it instead of leaving the changelog without diff ranges.
- When adding or updating a concrete version, `[Unreleased]` should compare from the newest released version to `HEAD`, and that released version should compare from the previous version tag to the new tag.
- Preserve valid historical compare links for older releases. Repair only the links that are missing, incomplete, or wrong.
- Do not remove existing links or historical entries unless they are demonstrably wrong.

### Step 8: Stop after the edit

Reread the target entry from disk, including its highlight and any retained text. For each factual clause, identify its supporting outcome and evidence. Check identity, versions, scope, behavior, and causal explanations independently. A valid section or successful resolver run does not validate these claims. Correct unsupported wording and repeat this review before handing the file back.

Inspect the entry's physical line layout before completing it. Each prose paragraph and each bullet must occupy one physical line unless the Markdown structure genuinely requires more than one. Rejoin every arbitrary wrap, regardless of line length. Any hard-wrapped paragraph or bullet means the edit is incomplete.

After updating `CHANGELOG.md`, stop and let the user review the file. Do not commit, tag, push, or create a release unless the user asks.
