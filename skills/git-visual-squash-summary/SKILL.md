---
name: git-visual-squash-summary
description: >
  Turn many commits into a curated grouped squash summary compatible with the opinionated wording style of git-visual-commits. Use when the user asks to squash a branch into a concise summary, write a squash-and-merge summary, summarize this branch, summarize a commit range or PR as grouped lines, clean up noisy commit history, or asks for a curated summary without committing. For normal squash-and-merge requests, default to the full current feature branch from merge-base to HEAD without asking the user to choose among commits already on that branch. This skill is non-mutating: it inspects git history and diffs, returns grouped summary lines only, preserves technical identifiers, merges overlap, drops low-signal noise, keeps lines at or below 72 characters, and avoids unsupported claims or changelog wording.
---

# Git Visual Squash Summary

This skill turns a stack of commits into a curated grouped summary without touching the index, the worktree, or git history. It is the wording companion to `git-visual-commits`: same emoji-first language, with conventional prefixes only when the user explicitly asks for that combo, but non-mutating and optimized for the grouped summary shown beneath a PR title or in a squash-and-merge description field.

This skill is non-mutating: it inspects history and diffs, then returns grouped summary lines only.

This skill has one job: produce a ready-to-paste squash-and-merge summary for the full current feature branch unless the user explicitly asked for a narrower range.

## Non-Negotiable Rules

- Never stage, commit, amend, rebase, or otherwise mutate git state.
- Read `references/commit-language.md` before choosing any emoji or optional prefix.
- Keep `references/commit-language.md` byte-for-byte aligned with the `git-visual-commits` copy; the validator and CI both enforce that sync contract.
- Preserve technical identifiers exactly where possible.
- Group by intent, not chronology.
- Retain only distinct high-signal change groups.
- Merge repetition and overlapping commits into their parent group.
- Drop low-signal noise such as typo-only, fixup-only, and trivial follow-up commits unless they materially change a retained group.
- Prefer strong concrete verbs and concise phrasing.
- Favor readable GitHub and terminal output over cleverness.
- Avoid vague filler such as "various improvements".
- Do not treat the result as a changelog entry or a dump of commit subjects.
- Do not invent unsupported changes.
- Return grouped lines only, never a title or body.
- Keep every output line at or below 72 characters.
- For squash-and-merge requests that target the current branch, default to the full feature branch range from merge-base to `HEAD`.
- Do not collect commit-set parameters through follow-up questions, widgets, or choice UIs for ordinary squash-and-merge requests.
- Do not ask the user to choose between earlier branch commits and later branch commits such as changelog, version-bump, or release-finalization follow-ups. They are part of the branch unless the user explicitly narrows scope.

## Workflow

### Step 1: Resolve the commit set

Resolve the commit set in this order:

1. If the user explicitly provided a commit range, branch comparison, PR branch, or base branch, use that.
2. Otherwise, for normal squash-and-merge or "summarize this branch" requests, use the full current branch against its upstream merge-base.
3. If no upstream is configured, try `main`, then `master` automatically.
4. If you still cannot determine a safe comparison point after those silent fallbacks, stop and ask for the range or base branch instead of guessing.

Never turn steps 2 or 3 into a user-facing choice. Resolve them automatically and continue.
Do not stop to ask whether the latest branch commit "should count". If it is on the branch, it is in scope by default.

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

Do not summarize from commit subjects alone when the range is noisy or long. Inspect both history and net effect so the final message reflects what actually changed.

Helpful read-only commands:

```bash
git log --reverse --oneline <range>
git log --reverse --stat --format=medium <range>
git diff --stat <base>..HEAD
git diff <base>..HEAD
```

### Step 3: Collapse to semantic intent

Before drafting the summary, reduce the range into the smallest truthful set of retained groups:

- Collapse repeated fixups into the group they support.
- Merge overlapping commits into the clearest final intent.
- Prefer the net effect over the path taken to get there.
- Drop typo-only, whitespace-only, and other low-signal cleanup unless it materially changes a retained group.
- Keep documentation-only work separate in your reasoning, but include it only when it represents a meaningful unique change.
- Treat late changelog, version-bump, or release-finalization commits as part of the branch by default, then decide here whether they deserve a retained summary line or should be merged into a stronger parent group.
- Highlight distinct meaningful efforts instead of forcing one dominant umbrella theme.

Ask yourself: "If I had to explain the real work in 2-5 compact lines, what are the distinct changes that mattered?"

### Step 4: Draft the grouped summary

Use this exact output shape:

```text
<emoji> <short summary line>
<emoji> <short summary line>
<emoji> <short summary line>
```

Formatting rules:

- Return grouped lines only. Do not prepend a title.
- Use one line per retained high-signal group.
- Keep every line at or below 72 characters.
- Default to emoji plus description only. Use `<emoji> <prefix>: ...` only when the user explicitly asked to mirror conventional-commit prefixes.
- Use the shared prefix and emoji guidance in `references/commit-language.md`.
- Do not add bullets, numbering, a body, rationale paragraph, or chronology recap.
- Do not append weak glue like "with", "plus", or "and" just to force several top-level intents into one line.
- Favor clean lines that scan well in GitHub and terminal views.
- Condense to the real grouped effort without dropping important identifiers.

### Step 5: Return the grouped lines only

Output the finished grouped summary lines and stop. Do not run `git commit`, `git bot commit`, `git add`, or any other mutating command.

## Good Output Characteristics

- Reads like a curated grouped summary, not a stitched list of commits.
- Reads like a curated, human-written condensed history.
- Uses the same emoji-first language as `git-visual-commits`, with prefixes only on explicit request.
- Keeps distinct meaningful efforts on separate lines.
- Drops noisy fixups and typo-only churn instead of preserving them.
- Fits naturally beneath a PR title or in compact GitHub and terminal views.
- Includes only claims supported by the inspected diff.
- Preserves names such as commands, types, files, APIs, flags, and paths.
- Keeps each line compact enough to scan at a glance.
- Uses the whole current feature branch by default for squash-and-merge requests instead of asking needless range questions.
- Produces the GitHub-ready squash summary directly instead of turning commit-set resolution into a mini interview.

## Bad Output Characteristics

- Changelog-like wording or release-note phrasing.
- Chronological narration of each commit in order.
- Dumping raw commit subjects line by line.
- Asking the user to choose among commits that are all on the current feature branch when they asked for a squash summary of that branch.
- Presenting commit-selection widgets or multiple-choice prompts for ordinary branch-level squash requests.
- Collapsing several unique top-level efforts into one stitched sentence.
- Filler such as "misc cleanup", "various improvements", or "updates".
- Losing or renaming important technical identifiers unnecessarily.
- Inventing refactors, fixes, or docs changes not supported by the diff.
- Adding a title, body, bullets, or numbered outline.
- Exceeding 72 characters on any output line.
