---
name: git-keep-a-changelog
description: >
  Create or update CHANGELOG.md from git history using Keep a Changelog
  1.1.0 style. Use this skill whenever the user asks to create or update
  the changelog, draft release notes from the current branch, summarize commits into
  Added/Changed/Fixed style sections, or mentions Keep a Changelog,
  CHANGELOG.md, release highlights, or SemVer-aware release summaries.
  Treat requests like "create the changelog", "update the changelog",
  "write release notes from git", "draft the changelog for this branch",
  or "summarize these commits into CHANGELOG.md" as automatic triggers.
  This skill reads full commit subjects and bodies plus the net diff,
  infers a version heading from the branch when possible, creates a
  compliant changelog when missing, writes a required SemVer-aware
  release highlight, edits CHANGELOG.md directly for review, preserves
  natural prose wrapping, and avoids raw commit-log dumps or unsupported
  claims.
---

# Git Keep A Changelog

This skill creates or updates `CHANGELOG.md` directly using the Keep a
Changelog 1.1.0 structure. It is git-aware, changelog-focused, and
optimized for a human-readable release summary rather than generated
release-note noise.

## Non-Negotiable Rules

- Create or update `CHANGELOG.md` directly, then stop for user review.
- If `CHANGELOG.md` does not exist, create a compliant one before
  populating it.
- Read full commit subjects and bodies before writing the changelog.
- Inspect the net diff too; do not infer the release from subjects alone.
- If the current branch starts with a version hint such as `v0.3.0/`,
  use that to target a concrete release heading.
- Otherwise, target `## [Unreleased]`.
- Always write a release highlight immediately below the target heading.
- The release highlight must explicitly classify the release as `major`,
  `minor`, or `patch`.
- Use the standard Keep a Changelog section order:
  `Added`, `Changed`, `Deprecated`, `Removed`, `Fixed`, `Security`.
- Omit empty sections instead of emitting placeholders.
- Preserve natural line breaks and readable prose. Do not apply any fixed
  column limit or artificial hard wrapping to changelog paragraphs or
  bullets.
- End each bullet with `,` and end the last bullet in each section with
  `.`.
- Do not dump commit subjects verbatim into the changelog.
- Do not invent unsupported changes, risks, or migration guidance.

## Release Highlight Contract

Every updated changelog entry must begin with a short human-written
highlight paragraph directly below the heading.

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

When the history clearly carries migration risk or upgrade caveats, add
an advisory block such as:

```md
> [!WARNING]
> Upgrading to this release requires ...
```

Only add callouts when the commits or diff justify them.

## Workflow

### Step 1: Resolve the source range

Use the most explicit range the user gave you.

- If the user named a range, branch comparison, base branch, or PR range,
  use that.
- Otherwise, compare the current branch to its upstream merge-base.
- If no upstream is configured, try `main`, then `master`.
- If no safe comparison point can be established, stop and ask for a
  base branch or range instead of guessing.

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

Determine whether to write a concrete release section or update
`[Unreleased]`.

- If the branch name starts with a version prefix such as
  `v0.3.0/feature-name`, target `## [0.3.0] - YYYY-MM-DD`.
- Strip the leading `v` from the visible changelog heading, but keep tag
  comparisons in `vX.Y.Z` form.
- If no version hint exists, target `## [Unreleased]`.
- If the target heading already exists, update it in place instead of
  duplicating it.

### Step 3: Read the full history and net effect

Read enough git history to understand what the release actually changed.

- Read the full commit message bodies, not just `--oneline`.
- Inspect the net diff so fixups and partial reversals do not distort the
  changelog.
- Prefer the final user-visible or maintainer-meaningful outcome over the
  implementation path.

Helpful commands:

```bash
git log --reverse --format=medium <range>
git log --reverse --stat --format=medium <range>
git diff --stat <base>..HEAD
git diff <base>..HEAD
```

### Step 4: Classify the release

Infer the SemVer class from the actual change set.

- `major` when the release includes breaking removals, required migration,
  incompatible contract changes, or other true breaking behavior.
- `minor` when the release adds meaningful new capabilities without
  breaking existing consumers.
- `patch` when the release is primarily fixes, service updates, docs,
  validation, maintenance, dependency work, or other non-breaking
  refinement.

Do not over-classify from dramatic wording in a commit subject. The net
effect matters more than the phrasing of one commit.

### Step 5: Curate the changelog content

Write the release highlight first, then the populated sections.

- Map the net effect into `Added`, `Changed`, `Deprecated`, `Removed`,
  `Fixed`, and `Security`.
- Keep bullets curated and human-written.
- Merge overlapping commits into one bullet when they describe the same
  real outcome.
- Drop low-signal churn such as typo-only commits, trivial fixups, or
  mechanical follow-ups unless they materially change the release story.
- Use natural prose line breaks. Keep paragraphs and bullets readable, but
  do not column-wrap them artificially or target a fixed line width.
- End each bullet with `,` except the final bullet in a populated section,
  which must end with `.`.

### Step 6: Update CHANGELOG.md carefully

Preserve the file's existing structure while editing.

- If `CHANGELOG.md` is missing, create it with the standard title,
  intro paragraph, `## [Unreleased]`, and compare-link footer before
  inserting release content.
- Keep the introduction and existing release history intact.
- If writing a concrete release section, insert it below `## [Unreleased]`
  and above older releases.
- If writing to `## [Unreleased]`, keep the heading and update only its
  content.
- Update compare links at the bottom when adding a concrete version:
  `[Unreleased]` should compare from the new version to `HEAD`, and the
  new version should compare from the previous version tag to the new tag.
- Do not remove existing links or historical entries unless they are
  demonstrably wrong.

### Step 7: Stop after the edit

After updating `CHANGELOG.md`, stop and let the user review the file.
Do not commit, tag, push, or create a release unless the user asks.

## Good Output Characteristics

- Reads like a curated release narrative, not a generated log dump.
- Uses the Keep a Changelog section order consistently.
- Includes a required SemVer-aware release highlight.
- Creates a compliant `CHANGELOG.md` scaffold when the file is missing.
- Reflects the meaning of full commit bodies and the net diff.
- Preserves natural prose wrapping with no fixed column-width target.
- Keeps bullets specific, concrete, non-repetitive, and consistently
  punctuated.
- Preserves existing compare-link structure when updating versions.

## Bad Output Characteristics

- Copying commit subjects line by line into the changelog.
- Omitting the release highlight.
- Failing to classify the release as major, minor, or patch.
- Refusing to proceed just because `CHANGELOG.md` does not exist yet.
- Using any artificial fixed-width wrapping for changelog prose.
- Mixing bullet punctuation or leaving section bullets without the
  required trailing `,` / final `.` pattern.
- Emitting empty `Added` / `Changed` / `Fixed` headings.
- Claiming breaking changes, fixes, or security work not supported by git.
