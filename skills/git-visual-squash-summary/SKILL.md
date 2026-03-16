---
name: git-visual-squash-summary
description: >
  Turn many commits into one polished squash-ready subject line that
  stays compatible with the opinionated wording style of
  git-visual-commits. Use this skill whenever the user asks to squash a
  branch into one message, write a squash-and-merge summary, summarize a
  commit range or PR as one commit, clean up noisy commit history, or asks
  for the subject only without actually committing. Treat phrases
  like "squash summary", "squash commit message", "summarize this branch",
  "turn these commits into one", "rewrite these 10+ commits", or "draft
  the squash message" as automatic triggers. This skill is non-mutating:
  it inspects git history and diffs, then returns one subject line only. It
  detects the dominant theme, preserves technical identifiers where
  possible, groups by intent rather than chronology, merges overlapping
  commits, uses strong concrete verbs, favors readable GitHub and terminal
  output, keeps the subject at or below 72 characters, and does not invent
  unsupported changes or drift into changelog wording.
---

# Git Visual Squash Summary

This skill turns a stack of commits into one squash-ready subject line
without touching the index, the worktree, or git history. It is the
wording companion to `git-visual-commits`: same opinionated emoji and
prefix language, but non-mutating and optimized for squash-and-merge
subjects and the GitHub squash merge commit field.

## Non-Negotiable Rules

- Never stage, commit, amend, rebase, or otherwise mutate git state.
- Read `references/commit-language.md` before choosing any emoji or prefix.
- Keep `references/commit-language.md` byte-for-byte aligned with the
  `git-visual-commits` copy; the validator and CI both enforce that sync
  contract.
- Detect and center the dominant theme of the commit stack.
- Preserve technical identifiers exactly where possible.
- Group by intent, not chronology.
- Merge repetition and overlapping commits into one clear summary.
- Prefer strong concrete verbs and concise phrasing.
- Favor readable GitHub and terminal output over cleverness.
- Avoid vague filler such as "various improvements".
- Do not treat the result as a changelog entry or bullet-list summary.
- Do not invent unsupported changes.
- Return a subject line only, never a body.
- Keep the subject at or below 72 characters.

## Workflow

### Step 1: Resolve the commit set

Use the most explicit source the user gave you:

- If the user provided a commit range, branch comparison, PR branch, or
  base branch, use that.
- Otherwise, try the current branch against its upstream merge-base.
- If no upstream is configured, try `main`, then `master`.
- If you still cannot determine a safe comparison point, stop and ask for
  the range or base branch instead of guessing.

Helpful read-only commands:

```bash
git status --short --branch
git rev-parse --abbrev-ref HEAD
git rev-parse --abbrev-ref --symbolic-full-name @{upstream}
git merge-base HEAD @{upstream}
git merge-base HEAD main
git merge-base HEAD master
```

### Step 2: Inspect the actual changes

Do not summarize from commit subjects alone when the range is noisy or
long. Inspect both history and net effect so the final message reflects
what actually changed.

Helpful read-only commands:

```bash
git log --reverse --oneline <range>
git log --reverse --stat --format=medium <range>
git diff --stat <base>..HEAD
git diff <base>..HEAD
```

### Step 3: Collapse to semantic intent

Before drafting the message, reduce the range into the smallest truthful
set of intents:

- Detect the dominant theme and make it the center of the subject.
- Merge repeated fixups into the final intent they support.
- Prefer the net effect over the path taken to get there.
- Keep documentation-only work separate in your reasoning, but include it
  in the final summary only when it materially belongs in the squash.
- Favor the dominant user-facing or maintainer-facing change over internal
  churn.

Ask yourself: "If this history became one reviewed commit, what is the one
sentence explanation of why these changes belong together?"

### Step 4: Draft the final squash subject

Use this exact output shape:

```text
<emoji> <optional-prefix> <short description>
```

Formatting rules:

- The first line is the squash commit subject.
- The subject must fit within 72 characters.
- Use the shared prefix and emoji guidance in
  `references/commit-language.md`.
- Do not add a body, bullets, rationale paragraph, or chronology recap.
- Do not output a changelog fragment, mini-outline, or stacked clauses.
- Favor a clean subject that scans well in GitHub and terminal views.
- Condense to the net effect without dropping important identifiers.

### Step 5: Return the message only

Output the finished squash-ready subject line and stop. Do not run
`git commit`, `git bot commit`, `git add`, or any other mutating command.

## Good Output Characteristics

- Reads like one polished squash subject, not a stitched list of commits.
- Reads like a curated, human-written condensed history.
- Uses the same emoji and prefix language as `git-visual-commits`.
- Centers the dominant theme instead of enumerating subtopics.
- Makes the primary change obvious within the first line.
- Fits naturally in the squash merge commit field on GitHub.
- Includes only claims supported by the inspected diff.
- Preserves names such as commands, types, files, APIs, flags, and paths.

## Bad Output Characteristics

- Changelog-like wording or release-note phrasing.
- Chronological narration of each commit in order.
- Enumerating multiple subthemes instead of picking the dominant one.
- Filler such as "misc cleanup", "various improvements", or "updates".
- Losing or renaming important technical identifiers unnecessarily.
- Inventing refactors, fixes, or docs changes not supported by the diff.
- Adding a body or multi-line explanation.
- Exceeding 72 characters in the subject.
