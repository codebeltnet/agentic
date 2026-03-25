---
name: git-keep-a-changelog
description: >
  Create or update CHANGELOG.md from git history using Keep a Changelog 1.1.0 style. Use when the user asks to create/update changelog, draft release notes, or mentions SemVer-aware summaries. Trigger phrases: "finalize", "ready to release", "rtr", "release" (especially with version branches like v0.3.1/...). Reads full commit bodies and diffs, creates compliant structure with required SemVer highlights, infers versions from branches, must ask a mandatory Yes / No / Custom confirmation question before including pending staged, unstaged, or untracked worktree changes in a concrete release draft, edits directly for review, preserves prose wrapping, avoids commit-log dumps.
---

# Git Keep A Changelog

This skill creates or updates `CHANGELOG.md` directly using the Keep a Changelog 1.1.0 structure. It is git-aware, changelog-focused, and optimized for a human-readable release summary rather than generated release-note noise.

Read `FORMS.md` when pending worktree changes require user confirmation and the host supports native structured input controls. If native structured input is unavailable, use the deterministic plain-text fallback defined there.

## Non-Negotiable Rules

- Create or update `CHANGELOG.md` directly, then stop for user review.
- If `CHANGELOG.md` does not exist, create a compliant one before populating it.
- Read full commit subjects and bodies before writing the changelog.
- Inspect the net diff too; do not infer the release from subjects alone.
- If the current branch starts with a version hint such as `v0.3.0/`, use that to target a concrete release heading.
- Otherwise, target `## [Unreleased]`.
- Always write a release highlight immediately below the target heading.
- The release highlight must explicitly classify the release as `major`, `minor`, or `patch`.
- Use the standard Keep a Changelog section order: `Added`, `Changed`, `Deprecated`, `Removed`, `Fixed`, `Security`.
- Omit empty sections instead of emitting placeholders.
- Always maintain the Keep a Changelog compare-link footer at the bottom of the file.
- Preserve natural line breaks and readable prose. Do not apply any fixed column limit or artificial hard wrapping to changelog paragraphs or bullets.
- End each bullet with `,` and end the last bullet in each section with `.`.
- If pending worktree changes exist for a concrete release draft, do not silently include or exclude them. Ask the user first with a short `Yes / No / Custom` prompt.
- Do not dump commit subjects verbatim into the changelog.
- Do not invent unsupported changes, risks, or migration guidance.

## Mandatory Checkpoints

These checkpoints cannot be skipped or bypassed, even when the user's opening request sounds like a shortcut.

1. Step 3 confirmation gate: if pending worktree changes exist for a concrete release such as `## [1.2.3]`, present the confirmation question before drafting or writing the changelog entry.
2. Release highlight contract: every concrete release entry must include a release highlight paragraph that explicitly classifies the release as `major`, `minor`, or `patch`.
3. Bullet punctuation: all bullets must end with `,` except the final bullet in each populated section, which must end with `.` Do not finish the edit until this is consistent.

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

### Why this matters

Silent inclusion of pending changes in a changelog is a production risk. The gate ensures the release scope is intentional, visible, and explicitly confirmed before the draft becomes part of the project's recorded release history.

## Workflow

### Step 1: Resolve the source range

Use the most explicit range the user gave you.

- If the user named a range, branch comparison, base branch, or PR range, use that.
- Otherwise, compare the current branch to its upstream merge-base.
- If no upstream is configured, try `main`, then `master`.
- If no safe comparison point can be established, stop and ask for a base branch or range instead of guessing.

Helpful commands:

```bash
git status --short --branch
git rev-parse --abbrev-ref HEAD
git rev-parse --abbrev-ref --symbolic-full-name @{upstream}
git merge-base HEAD @{upstream}
git merge-base HEAD main
git merge-base HEAD master
```

### Step 2: Resolve the changelog target

Determine whether to write a concrete release section or update `[Unreleased]`.

When the user asks to "finalize", "ready to release", "rtr", "release", "publish", or "ship" (or similar release-intent words):
- Extract the version from the current branch name if it starts with a version prefix such as `v0.3.0/feature-name`.
- Target `## [X.Y.Z] - YYYY-MM-DD` (today's date) for that extracted version.
- This is a strong signal that the user wants to finalize that specific release in the changelog.

Otherwise:
- If the branch name starts with a version prefix such as `v0.3.0/feature-name`, target `## [0.3.0] - YYYY-MM-DD`.
- Strip the leading `v` from the visible changelog heading, but keep tag comparisons in `vX.Y.Z` form.
- If no version hint exists, target `## [Unreleased]`.
- If the target heading already exists, update it in place instead of duplicating it.

### Step 3: Confirm Pending Worktree Changes (MANDATORY GATE)

This is a required checkpoint. Do not proceed to Step 4 until this step is complete.

After resolving the target heading, check whether the worktree contains changes that are not part of the committed history yet.

- Count staged, unstaged, and untracked changes separately.
- If there are no pending changes, continue normally.
- If there are pending changes and the target is a concrete release heading such as `## [1.2.3]`, You must ask a direct confirmation question before drafting the changelog entry.
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

### Step 4: Read the full history and net effect

Read enough git history to understand what the release actually changed.

- Read the full commit message bodies, not just `--oneline`.
- Inspect the net diff so fixups and partial reversals do not distort the changelog.
- When the user approved pending changes, inspect the selected staged, unstaged, and/or untracked worktree deltas too.
- Prefer the final user-visible or maintainer-meaningful outcome over the implementation path.

Helpful commands:

```bash
git log --reverse --format=medium <range>
git log --reverse --stat --format=medium <range>
git diff --stat <base>..HEAD
git diff <base>..HEAD
git diff --cached
git diff
git ls-files --others --exclude-standard
```

### Step 5: Classify the release

Infer the SemVer class from the actual change set.

- `major` when the release includes breaking removals, required migration, incompatible contract changes, or other true breaking behavior.
- `minor` when the release adds meaningful new capabilities without breaking existing consumers.
- `patch` when the release is primarily fixes, service updates, docs, validation, maintenance, dependency work, or other non-breaking refinement.

Do not over-classify from dramatic wording in a commit subject. The net effect matters more than the phrasing of one commit.

### Step 6: Curate the changelog content

Write the release highlight first, then the populated sections.

- Map the net effect into `Added`, `Changed`, `Deprecated`, `Removed`, `Fixed`, and `Security`.
- Keep bullets curated and human-written.
- Merge overlapping commits into one bullet when they describe the same real outcome.
- Drop low-signal churn such as typo-only commits, trivial fixups, or mechanical follow-ups unless they materially change the release story.
- Use natural prose line breaks. Keep paragraphs and bullets readable, but do not column-wrap them artificially or target a fixed line width.
- End each bullet with `,` except the final bullet in a populated section, which must end with `.`.

### Step 7: Update CHANGELOG.md carefully

Preserve the file's existing structure while editing.

- If `CHANGELOG.md` is missing, create it with the standard title, intro paragraph, `## [Unreleased]`, and compare-link footer before inserting release content.
- Keep the introduction and existing release history intact.
- If writing a concrete release section, insert it below `## [Unreleased]` and above older releases.
- If writing to `## [Unreleased]`, keep the heading and update only its content.
- On every edit, verify that the compare-link footer exists at the bottom of the file. If it is missing or incomplete, insert or repair it instead of leaving the changelog without diff ranges.
- When adding or updating a concrete version, `[Unreleased]` should compare from the newest released version to `HEAD`, and that released version should compare from the previous version tag to the new tag.
- Preserve valid historical compare links for older releases. Repair only the links that are missing, incomplete, or wrong.
- Do not remove existing links or historical entries unless they are demonstrably wrong.

### Step 8: Stop after the edit

After updating `CHANGELOG.md`, stop and let the user review the file. Do not commit, tag, push, or create a release unless the user asks.

## Good Output Characteristics

- Reads like a curated release narrative, not a generated log dump.
- Uses the Keep a Changelog section order consistently.
- Includes a required SemVer-aware release highlight.
- Creates a compliant `CHANGELOG.md` scaffold when the file is missing.
- Reflects the meaning of full commit bodies and the net diff.
- Treats Step 3 as a mandatory confirmation gate for concrete releases and asks the `Yes / No / Custom` question before including pending worktree changes.
- Maintains or inserts the compare-link footer at the bottom of the file on both create and update paths.
- Preserves natural prose wrapping with no fixed column-width target.
- Keeps bullets specific, concrete, non-repetitive, and consistently punctuated.
- Preserves existing compare-link structure when updating versions.

## Bad Output Characteristics

- Copying commit subjects line by line into the changelog.
- Omitting the release highlight.
- Failing to classify the release as major, minor, or patch.
- Refusing to proceed just because `CHANGELOG.md` does not exist yet.
- Silently including, silently ignoring, or otherwise bypassing the pending-worktree confirmation gate for a concrete release draft.
- Using any artificial fixed-width wrapping for changelog prose.
- Mixing bullet punctuation or leaving section bullets without the required trailing `,` / final `.` pattern.
- Emitting empty `Added` / `Changed` / `Fixed` headings.
- Updating an existing changelog entry but leaving the compare-link footer missing or stale.
- Claiming breaking changes, fixes, or security work not supported by git.
