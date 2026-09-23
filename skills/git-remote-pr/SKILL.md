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

2. Read **all** of `evidence.json` and `final.patch` from the returned paths, not truncated tool output. The evidence includes every commit SHA and complete subject/body, every changed path and status, additions/deletions or a binary marker, the merge base, remote state, and existing PR details. The patch is the final net diff from the merge base to local `HEAD` (`base...head`). If output is too large for one read, read it in bounded chunks until every part is covered. Inspect binary and patch-unavailable entries through file metadata or another read-only route. Stop if evidence is incomplete. Commit text supplies intent; final diff decides what ships. Discard claims reverted by later commits.
3. Assign a concise reviewer-oriented **theme** to every entry in `evidence.json.files`, including renames, deletions, generated files, and binaries. Save the updated JSON in the same temp directory. Every theme must appear in the body. Group mechanical files under an honest theme; do not hide them. The plan helper enforces this coverage map. Themes are coarse reviewer-facing categories, not descriptions of individual files.
   - Reuse the same theme across all files that contribute to the same reviewer concern or outcome.
   - Different directories, filenames, helpers, references, evals, assets, README changes, or validation files do not require separate themes when they support the same change.
   - Large sets of related SKILL.md, reference, eval, asset, README, or validation updates may share one theme.
   - Mechanical or supporting changes usually belong under one honest theme instead of separate entries.
   - The changed-file inventory remains evidence for correctness and verification. A file earns prose coverage by belonging to a represented theme, not by being named individually.
4. Inspect `template.md` when present. The default repository template takes precedence. Preserve required headings and checklist structure. Fill those sections with the same concise reviewer-oriented synthesis; do not append a duplicate fallback summary or file inventory below the template. Mark only verified facts; leave unsupported checks unchecked. Do not invent issue links or `Closes`/`Fixes`/`Resolves`. If several named templates have no default, ask which PR type to use. Do not restart other preparation.
5. Derive the default title from the effective remote head branch: replace branch word hyphens with spaces, preserve slash, periods, numbers, and meaningful internal casing, then uppercase only the first character of the complete title. Examples: `v0.10.2/service-update` → `V0.10.2/service update`; `v12.0.2/chore-work` → `V12.0.2/chore work`; `v0.10.0/dotnet-nuget-update` → `V0.10.0/dotnet nuget update`. Honor an explicit repository title convention if it supersedes this default.
6. Write a UTF-8 LF `body.md` in the same temp directory. Start with a short natural-language opening paragraph that explains the PR purpose and major outcome. Then summarize the evidence with reviewer-oriented thematic sections rather than a file inventory. Unless a repository template requires a different frame, prefer one opening paragraph, bold headings such as `**New skill: git-remote-pr**` instead of a tall stack of `##` sections, 2-5 themes for a normal or large PR, and concise `-` bullets beneath each theme with roughly 2-5 bullets where practical. Small PRs may use one focused section. The body should answer what the PR is trying to accomplish, what the important changes are, and what behavior or engineering characteristics the reviewer should care about. It should not try to explain what changed in every individual file. Describe outcomes and behavior before implementation inventory. Combine related changes into one bullet when they serve the same purpose. Mention paths, scripts, or identifiers only when they materially help the reviewer. Keep unrelated efforts separate. Do not repeat the commit log, use filler, hard-wrap prose, use em dashes, fabricate `diffhunk://` links, add AI attribution, append a duplicate `Changes Summary`, or write paragraphs that are effectively comma-separated file inventories such as `X updates (file.md)`. Add validation only for commands that actually ran successfully in the current session; otherwise omit it unless a template requires it. Do not infer tests from test-file changes or claim CI passed before PR creation.
7. An existing open PR for the effective head/base pair means **UPDATE**, never another create. Regenerate its complete body from the current full diff even if the previous body looks polished. **Body ownership policy:** for this workflow, the whole PR body is generated and replaceable, matching the historical Codebelt generated-body convention. An unmarked existing body, including manual edits, will be replaced in full. Show that replacement explicitly in the preview; do not preserve stale prose as an appendix or silently switch policies. Preserve unrelated GitHub metadata. If the title/body already match, assignment exists, and no push is needed, verify and report already up to date without a metadata write.
8. Create a normal ready PR unless the user explicitly requested draft. Do not add reviewers, labels, milestones, projects, linked issues, auto-merge, or a merge method without explicit direction. After the complete body and coverage map are ready, run the read-only plan helper with the exact title to be previewed. It records hashes of the evidence and body, binds the approved title and ready/draft state to the plan, and produces the exact planned writes. Read `plan.json` before presenting the preview. Add `-Draft` only for an explicitly requested new draft.

   ```text
   pwsh -NoProfile -NonInteractive -File <skill>/scripts/make-plan.ps1 -EvidenceFile <temp-directory>/evidence.json -BodyFile <temp-directory>/body.md -Title <exact-title>
   ```

## Approval preview

Before any `git push`, `gh pr create`, `gh pr edit`, assignee change, or equivalent remote write, show:

- Action `CREATE` or `UPDATE`; repository; `base <- head` including the fork owner when relevant.
- Proposed **title** and concise description preview, with the complete body available at its temp path on request.
- Commit count, changed-file count, authenticated assignee, and whether a normal branch push is required.
- Existing PR URL on update, plus whether its **entire current body** will be replaced and whether title/body/assignment need changes.
- Exact planned writes: optional normal push to the already-tracked head branch, create or edit the intended PR, and add the authenticated assignee if absent. Include ready/draft state.

In normal mode ask for explicit approval and stop. With same-request `yolo`/`auto`, display the preview as status and proceed. No approval is inferred from a prior unrelated `yolo`/`auto`.

## Phase 2: execute and verify

After approval (or the same-request auto modifier), run:

```text
pwsh -NoProfile -NonInteractive -File <skill>/scripts/execute-pr.ps1 -PlanFile <temp-directory>/plan.json -Approved
```

The helper verifies the plan's evidence/body hashes and the approved title/draft write intent, independently reruns preparation, and compares the material snapshot before a write. Changed local `HEAD`, worktree, base, remote head, authenticated user, PR title/body/state, template, or changed-file inventory invalidates approval. Rebuild evidence, body, plan, and preview, then seek approval again in normal mode. Never force push. A non-fast-forward/diverged branch fails closed. The helper pushes normally only if required, verifies remote SHA, rechecks the comparison after push, writes the PR and assignment, then fetches GitHub metadata and every PR file page. It verifies base, head, title, full body, draft/ready state, assignee, head SHA, and changed-file statuses, including rename sources. Do not declare success if any check fails. If a push or PR creation succeeded before a later failure, report the partial state and URL when available.

Do not treat `-Approved` as permission by itself: pass it only after actual user approval or scoped `yolo`/`auto`. Keep evidence and body outside the working tree or under ignored `.bot/`; clean disposable temp files when practical. No live PR creation or model-backed eval execution is part of skill validation.

On success return only the PR URL, created/updated/already-up-to-date state, title, `base <- head`, assignee, commit count, and changed-file count. Do not paste the full body unless requested.
