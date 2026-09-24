---
name: git-remote-pr
description: >
  Use when the user asks to create, open, make, or refresh a GitHub pull request for the current branch, including `git remote pr`. Do not use for commits, squash summaries, or release notes.
---

# Git Remote PR

Open or maintain one GitHub pull request for the entire committed current branch. Use Git, `gh`, and GitHub APIs. Never use GitHub Copilot, `gh copilot`, browser automation, GitHub's generated PR description, or another model-backed GitHub service. The agent reading this skill writes concise reviewer-oriented prose from collected evidence; bundled scripts collect and verify facts only. Use PowerShell 7 (`pwsh`) on Windows, Linux, and macOS.

## Routing and authorization

- Trigger on an explicit request to create, open, make, or refresh a GitHub PR, or `git remote pr`. `/git-remote-pr` may force selection where supported. Bare `yolo` or `auto` never triggers this skill.
- The explicit PR request authorizes read-only preparation. In normal mode, show the preview below and **stop for explicit approval before any remote write**. A later approval applies only to that prepared plan.
- `yolo` or `auto` attached to the same explicit PR request authorizes the narrow write phase after displaying the same preview as status. Continue without a second question. Neither mode authorizes force push, rebase, reset, amend, merge, branch deletion, auto-merge, or unrelated writes.
- A dirty worktree, including untracked files, blocks both modes. Explain that a PR contains committed changes only. Do not stage, commit, stash, discard, or automatically invoke `git-visual-commits`.
- A missing upstream tracking branch, or a local/upstream branch-name mismatch, also blocks both modes. The skill never guesses a PR head after a rename or silent tracking drift; fix tracking first, then rerun the workflow.
- Commit requests belong to `git-visual-commits`; squash wording belongs to `git-visual-squash-summary`; release notes belong to `git-remote-release`; changelogs belong to `git-keep-a-changelog`. This skill independently reads the complete PR comparison.

## Phase 1: prepare

1. Check `git` and `gh` are available. Run the read-only collector from the current working directory, with an absolute skill path. Use a unique operating-system temp directory, or ignored `.bot/` when needed. The collector fails closed for detached `HEAD`, the base branch, dirty worktree, missing or mismatched upstream tracking, missing auth/assignee eligibility, empty comparison, diverged remote head, and ambiguous templates. It discovers the GitHub repository, authenticated account, actual default branch, fork parent when applicable, upstream head branch, open PR, and push need. If the local branch was renamed or never tracked, repair the upstream first with `git push --set-upstream origin HEAD` or `git branch --set-upstream-to=origin/<branch>` after the remote branch name is correct. Supply `-Repository owner/repo` or `-Base branch` only when explicitly chosen or needed to resolve real ambiguity.

   ```text
   pwsh -NoProfile -NonInteractive -File <skill>/scripts/prepare-pr.ps1 -OutputDirectory <temp-directory>
   ```

2. Read **all** of `evidence.json` and `final.patch` from the returned paths, not truncated tool output. The evidence includes every commit SHA and complete subject/body, every changed path and status, additions/deletions or a binary marker, the merge base, remote state, and existing PR details. The patch is the final net text diff from the merge base to local `HEAD` (`base...head`), with binary change markers. Never include binary contents or encoded payloads in evidence or model context, and never request `git diff --binary`. Binary files are supporting assets: account for their paths, statuses, and metadata under the relevant theme. If output is too large for one read, read it in bounded chunks until every text change is covered; batch independent reads where supported. Stop if textual evidence is incomplete. Commit text supplies intent; final diff decides what ships. Discard claims reverted by later commits.
3. Choose the coarse reviewer-oriented headings once, then reuse their wording as the **theme** on every entry in `evidence.json.files`, including renames, deletions, generated files, and binaries. Save the updated JSON in the same temp directory. Before writing the body, inspect the distinct themes with `(Get-Content <temp-directory>/evidence.json -Raw | ConvertFrom-Json).files | Group-Object theme | Select-Object Name, Count`. Every theme must appear in the body; matching ignores case and surrounding whitespace, so `New skill` matches `**New Skill:**`. Internal spelling and punctuation still matter. Group mechanical files under an honest theme; do not hide them. The plan helper enforces this coverage map. Themes are coarse reviewer-facing categories, not descriptions of individual files.
   - Reuse the same theme across all files that contribute to the same reviewer concern or outcome.
   - Different directories, filenames, helpers, references, evals, assets, README changes, or validation files do not require separate themes when they support the same change.
   - Large sets of related SKILL.md, reference, eval, asset, README, or validation updates may share one theme.
   - Mechanical or supporting changes usually belong under one honest theme instead of separate entries.
   - Maintain the invariant **complete evidence coverage != complete prose enumeration**. The changed-file inventory remains evidence for correctness and verification. A file earns prose coverage by belonging to a represented theme, not by being named individually. File count determines how much evidence to inspect, not how much prose to emit.
4. Inspect `template.md` when present. The default repository template takes precedence. Preserve required headings and checklist structure. Fill those sections with the same concise reviewer-oriented synthesis; do not append a duplicate fallback summary or file inventory below the template. Mark only verified facts; leave unsupported checks unchecked. Do not invent issue links or `Closes`/`Fixes`/`Resolves`. If several named templates have no default, ask which PR type to use. Do not restart other preparation.
5. Derive the default title from the effective remote head branch: replace branch word hyphens with spaces, preserve slash, periods, numbers, and meaningful internal casing, then uppercase only the first character of the complete title. Examples: `v0.10.2/service-update` → `V0.10.2/service update`; `v12.0.2/chore-work` → `V12.0.2/chore work`; `v0.10.0/dotnet-nuget-update` → `V0.10.0/dotnet nuget update`. Honor an explicit repository title convention if it supersedes this default.
6. Write a UTF-8 LF `body.md` in the same temp directory. Synthesize a scan-friendly PR review summary, not release notes or technical documentation. Apply these presentation rules unless a repository template requires a different frame:
   - Open with one concise paragraph of approximately 2-4 sentences explaining the PR purpose, most important outcomes, and major areas affected.
   - Follow with approximately 3-6 coarse reviewer-oriented thematic sections. Use bold headings with a trailing colon inside the bold text, such as `**Workflow safety:**`, followed by a blank line and concise `-` bullets. Derive headings from this changeset; do not hard-code a standard set.
   - Prefer 1-3 bullets per section; add more only when a distinct reviewer concern requires it. After the introduction, use a structured bullet summary rather than narrative paragraphs beneath headings. Small PRs may use one focused section. For a large heterogeneous PR, normally aim for 4-6 headings and roughly 8-12 bullets total. These are density guidelines, not quotas: do not pad a small change or expand prose merely because many files changed.
   - Describe reviewer-relevant outcomes and behavior. Collapse several helpers implementing one workflow into one bullet about that workflow, for example: "Added a deterministic PR workflow with read-only evidence collection, approval-gated remote writes, safe push handling, and post-write verification." Do not explain each helper's responsibilities.
   - Compress validation cases into the guarantees tested, related reference documents into expanded guidance, formatting edits across skills into repository-wide consistency, and hero images into visual identification assets. Summarize regression coverage without cataloging individual scenarios. Mention README or CHANGELOG updates only when they represent a meaningful reviewer concern; routine supporting updates remain covered by their shared theme.
   - Do not create separate bullets merely because separate files exist. Keep unrelated outcomes separate, but mention individual paths, scripts, classes, skills, or reference documents only when their identity materially helps the reviewer. A bullet containing a long comma-separated inventory is still an inventory.
   - Use neutral, factual verbs such as Added, Introduced, Updated, Restructured, Extended, Standardized, and Refined. Avoid promotional language and unnecessary adjectives such as comprehensive, powerful, robust, significant, extensive, or major unless the evidence requires the distinction.
   - Before planning, compress repeated or overly detailed bullets and recheck that every internal coverage theme remains represented. Do not repeat the commit log, add a redundant final summary (including `Changes Summary`), use filler, hard-wrap prose, use em dashes, fabricate `diffhunk://` links, or add AI attribution.
   - Distinguish added test coverage from executed validation. Report successful validation only for commands that actually ran successfully in the current session; otherwise omit execution claims unless a template requires a validation status. Do not infer test execution from test-file changes or claim CI passed before PR creation.
7. An existing open PR for the effective head/base pair means **UPDATE**, never another create. Regenerate its complete body from the current full diff even if the previous body looks polished. **Body ownership policy:** for this workflow, the whole PR body is generated and replaceable, matching the historical Codebelt generated-body convention. An unmarked existing body, including manual edits, will be replaced in full. Show that replacement explicitly in the preview; do not preserve stale prose as an appendix or silently switch policies. Preserve unrelated GitHub metadata. If the title/body already match, assignment exists, and no push is needed, verify and report already up to date without a metadata write.
8. Create a normal ready PR unless the user explicitly requested draft. Do not add reviewers, labels, milestones, projects, linked issues, auto-merge, or a merge method without explicit direction. After the complete body and coverage map are ready, run the read-only plan helper with the exact title to be previewed. It records hashes of the evidence and body, binds the approved title and ready/draft state to the plan, and produces the exact planned writes plus `preview.md` containing the full proposed title and body. Read `plan.json` and check `preview.md` before linking the preview. Add `-Draft` only for an explicitly requested new draft.

   ```text
   pwsh -NoProfile -NonInteractive -File <skill>/scripts/make-plan.ps1 -EvidenceFile <temp-directory>/evidence.json -BodyFile <temp-directory>/body.md -Title <exact-title>
   ```

Reuse this one workspace for drafting and corrections. A nonzero exit is a failure: read the diagnostics before retrying. Errors are emitted to stdout and stderr; successful stdout remains JSON. Theme failures list every missing theme with its affected paths, so fix them together instead of rerunning once per file. A rejected plan removes stale `plan.json` and `preview.md`. Do not recollect evidence, create a fresh workspace, or reread the unchanged patch for a prose/theme correction. Recollect only when material repository state changes or evidence is incomplete; execution still independently refreshes the snapshot before writing.

## Approval preview

Before any `git push`, `gh pr create`, `gh pr edit`, assignee change, or equivalent remote write, provide a clickable absolute-path Markdown link such as `[Preview proposed PR](<absolute-temp-path>/preview.md)`. This file is the concrete review artifact; a summary of what the agent will do is not a preview. No special UI renderer or inline duplication is needed. The linked file must contain:

- Action `CREATE` or `UPDATE`; repository; `base <- head` including the fork owner when relevant.
- Proposed **title** and the **complete exact body** that will be submitted, preserving Markdown headings, bullets, and checklists. Never substitute a synopsis, excerpt, or promise to show the body later.
- Commit count, changed-file count, authenticated assignee, and whether a normal branch push is required.
- Existing PR URL on update, plus whether its **entire current body** will be replaced and whether title/body/assignment need changes.
- Exact planned writes: optional normal push to the already-tracked head branch, create or edit the intended PR, and add the authenticated assignee if absent. Include ready/draft state.

In normal mode give the preview link, ask for explicit approval, and stop. With same-request `yolo`/`auto`, give the same preview link as status and proceed. Keep the linked artifact available for review; do not delete it at handoff. If the proposed title, body, or writes change, regenerate the plan and preview before approval. No approval is inferred from a prior unrelated `yolo`/`auto`.

## Phase 2: execute and verify

After approval (or the same-request auto modifier), run:

```text
pwsh -NoProfile -NonInteractive -File <skill>/scripts/execute-pr.ps1 -PlanFile <temp-directory>/plan.json -Approved
```

The helper verifies the plan's evidence/body hashes and the approved title/draft write intent, independently reruns preparation, and compares the material snapshot before a write. Changed local `HEAD`, worktree, base, remote head, authenticated user, PR title/body/state, template, or changed-file inventory invalidates approval. Rebuild evidence, body, plan, and preview, then seek approval again in normal mode. Never force push. A non-fast-forward/diverged branch fails closed. The helper pushes normally only if required, verifies remote SHA, rechecks the comparison after push, writes the PR and assignment, then fetches GitHub metadata and every PR file page. It verifies base, head, title, full body, draft/ready state, assignee, head SHA, and changed-file statuses, including rename sources. Do not declare success if any check fails. If a push or PR creation succeeded before a later failure, report the partial state and URL when available.

Do not treat `-Approved` as permission by itself: pass it only after actual user approval or scoped `yolo`/`auto`. Keep evidence and body outside the working tree or under ignored `.bot/`; clean disposable temp files when practical. No live PR creation or model-backed eval execution is part of skill validation.

On success return the PR URL, created/updated/already-up-to-date state, title, `base <- head`, assignee, commit count, changed-file count, and the preview link. Do not paste the full body unless requested.
