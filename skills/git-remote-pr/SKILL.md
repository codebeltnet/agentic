---
name: git-remote-pr
description: >
  Use when the user asks to create, open, make, or refresh a GitHub pull request for the current branch, including `git remote pr`. Do not use for commits, squash summaries, or release notes.
---

# Git Remote PR

Open or maintain one GitHub pull request for the entire committed current branch. Use Git, `gh`, and GitHub APIs. Never use GitHub Copilot, `gh copilot`, browser automation, GitHub's generated PR description, or another model-backed GitHub service. The agent reading this skill writes concise reviewer-oriented prose from collected evidence; bundled scripts collect and verify facts only. Use PowerShell 7 (`pwsh`) on Windows, Linux, and macOS.

## Routing and authorization

- Trigger on an explicit request to create, open, make, or refresh a GitHub PR, or `git remote pr`. `/git-remote-pr` may force selection where supported. Bare `yolo` or `auto` never triggers this skill.
- The explicit PR request authorizes read-only preparation. In normal mode, show the preview below and **stop for the exact `approve APR-...` phrase displayed in that preview before any remote write**. Approval for Preview A can execute only Plan A.
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
   - Many changed files MUST collapse into shared reviewer statements: `changed file -> internal theme -> reviewer statement`, never a required filename in the body. Complete evidence coverage does not require prose enumeration.
4. Inspect `template.md` when present. The default repository template takes precedence. Preserve required headings and checklist structure. Fill those sections with the same concise reviewer-oriented synthesis; do not append a duplicate fallback summary or file inventory below the template. Mark only verified facts; leave unsupported checks unchecked. Do not invent issue links or `Closes`/`Fixes`/`Resolves`. If several named templates have no default, ask which PR type to use. Do not restart other preparation.
5. Derive the default title from the effective remote head branch: replace branch word hyphens with spaces, preserve slash, periods, numbers, and meaningful internal casing, then uppercase only the first character of the complete title. Examples: `v0.10.2/service-update` → `V0.10.2/service update`; `v12.0.2/chore-work` → `V12.0.2/chore work`; `v0.10.0/dotnet-nuget-update` → `V0.10.0/dotnet nuget update`. Honor an explicit repository title convention if it supersedes this default.
6. Write a UTF-8 LF `body.md` in the same temp directory. Unless a repository PR template requires another structure, the default body MUST have this shape:

   ```markdown
   This pull request <concise purpose and major outcomes in 2-3 sentences>.

   **<Reviewer theme>:**

   - <Outcome or behavior>
   - <Outcome or behavior>

   **<Reviewer theme>:**

   - <Outcome or behavior>
   - <Outcome or behavior>
   ```

   - MUST use exactly one opening prose paragraph, then only `**...:**` thematic headings and one or more `-` bullets beneath each. DO NOT use prose paragraphs after the first heading or append a concluding summary, including `Changes Summary`. `make-plan.ps1` rejects malformed default bodies before preview; regenerate the body in the same workspace.
   - Open with the PR purpose, primary capability, and major supporting outcomes. Prefer `This pull request introduces ...`; DO NOT use release-note framing such as `Release v0.11.0 introduces ...`. Mention a version only when versioning itself matters.
   - Derive coarse reviewer themes from the changeset. Aim for 2-3 opening sentences, approximately 3-6 sections for a large PR, and 1-3 bullets per section. These are density guidance, not quotas or fixed headings; small PRs may use one section.
   - Describe outcomes, not the evidence inventory. Collapse helpers into workflow guarantees, tests into regression coverage, references into guidance, portfolio formatting into consistency, and hero assets into visual identification. DO NOT enumerate helper scripts, test mechanics, filenames, or affected skills; name an item only when its identity matters to the reviewer.
   - Use neutral, factual language. DO NOT repeat the commit log, use filler, hard-wrap prose, use em dashes, fabricate `diffhunk://` links, or add AI attribution. Claim successful validation only for commands that actually passed in this session; added tests are coverage, not proof of execution.
7. An existing open PR for the effective head/base pair means **UPDATE**, never another create. Regenerate its complete body from the current full diff even if the previous body looks polished. **Body ownership policy:** for this workflow, the whole PR body is generated and replaceable, matching the historical Codebelt generated-body convention. An unmarked existing body, including manual edits, will be replaced in full. Show that replacement explicitly in the preview; do not preserve stale prose as an appendix or silently switch policies. Preserve unrelated GitHub metadata. If the title/body already match, assignment exists, and no push is needed, verify and report already up to date without a metadata write.
8. Create a normal ready PR unless the user explicitly requested draft. Do not add reviewers, labels, milestones, projects, linked issues, auto-merge, or a merge method without explicit direction. After the complete body and coverage map are ready, run the read-only plan helper with the exact title to be previewed. It renders the complete preview with `{{APPROVAL_ID}}` in its two generated approval fields, hashes those exact normalized bytes as `review_hash`, and derives a deterministic SHA-256 approval ID from the complete write intent (including artifact paths that scope it to this workspace) plus `review_hash`. It fills only those two slots, hashes the exact final preview as `preview_hash`, and produces the exact planned writes plus `preview.md` containing the full proposed title and body. Read `plan.json` and check `preview.md` before linking the preview. Add `-Draft` only for an explicitly requested new draft.

   ```text
   pwsh -NoProfile -NonInteractive -File <skill>/scripts/make-plan.ps1 -EvidenceFile <temp-directory>/evidence.json -BodyFile <temp-directory>/body.md -Title <exact-title>
   ```

Reuse this one workspace for drafting and corrections **before presenting a preview**. A nonzero exit is a failure: read the diagnostics before retrying. Errors are emitted to stdout and stderr; successful stdout remains JSON. Theme failures list every missing theme with its affected paths, so fix them together instead of rerunning once per file. A rejected draft plan removes stale `plan.json` and `preview.md`. Do not recollect evidence, create a fresh workspace, or reread the unchanged patch for a prose/theme correction. Once a preview is presented, preserve its evidence, body, plan, and preview. Any material change ends that approval transaction; follow the hard-stop rule below.

## Approval preview

Before any `git push`, `gh pr create`, `gh pr edit`, assignee change, or equivalent remote write, provide a clickable absolute-path Markdown link such as `[Preview proposed PR](<absolute-temp-path>/preview.md)`. This file is the concrete review artifact; a summary of what the agent will do is not a preview. No special UI renderer or inline duplication is needed. The linked file must contain:

- Action `CREATE` or `UPDATE`; repository; `base <- head` including the fork owner when relevant.
- Proposed **title** and the **complete exact body** that will be submitted, preserving Markdown headings, bullets, and checklists. Never substitute a synopsis, excerpt, or promise to show the body later.
- Commit count, changed-file count, authenticated assignee, and whether a normal branch push is required.
- Existing PR URL on update, plus whether its **entire current body** will be replaced and whether title/body/assignment need changes.
- Exact planned writes: optional normal push to the already-tracked head branch, create or edit the intended PR, and add the authenticated assignee if absent. Include ready/draft state.
- A prominent `Approval ID: APR-...` and the final instruction `To approve this exact preview, reply: approve APR-...`, using the same ID as `plan.json.approval_id`.

In normal mode give the preview link and its exact approval phrase, then stop. Bare `approved`, `yes`, `go ahead`, or `looks good` does not authorize execution. Re-present the **existing preview link** and ask for the exact displayed phrase; do not regenerate anything or infer, fill in, or manufacture the user's approval ID. With same-request `yolo`/`auto`, give the same preview link and phrase as status, then pass that just-presented plan's ID without waiting for another message. No approval is inferred from a prior unrelated `yolo`/`auto`.

## Phase 2: execute and verify

After approval (or the same-request auto modifier), run:

```text
pwsh -NoProfile -NonInteractive -File <skill>/scripts/execute-pr.ps1 -PlanFile <temp-directory>/plan.json -ApprovalId <exact-approved-APR-ID>
```

The helper matches the supplied approval ID, checks the exact final preview hash, normalizes only the two generated approval-ID slots back to `{{APPROVAL_ID}}`, verifies `review_hash`, and recomputes the approval ID from the complete write intent plus that review hash. It then checks evidence/body hashes and independently rechecks the material snapshot, and fails before a write when any check differs. Changed local `HEAD`, worktree, base, remote head, authenticated user, PR title/body/state, template, changed-file inventory, or approved artifact invalidates approval.

**Hard stop after invalidation, in both modes:** preserve the original `evidence.json`, `body.md`, `plan.json`, and `preview.md`; report the approved-versus-current facts available from the diagnostic, including HEAD/base and commit/file counts when known; terminate and return control to the user. State that no remote writes occurred only when true. Do not recollect evidence, rewrite the description, generate Plan B or Preview B, ask for another approval, retry execution, or reuse the invalidated ID in that recovery sequence. End with: `If this change is intentional, ask me to refresh the PR preview.` A generic approval after invalidation cannot revive the transaction.

Only an explicit subsequent `refresh` / `retry with new state` request starts another transaction: use a **new scratch workspace**, collect fresh evidence, write a fresh body, and create a fresh plan and preview with a new ID. Keep the previous artifacts unchanged. Present the new preview link and exact new approval phrase; normal mode waits for that new phrase. Approval ID A cannot execute Plan B. The same-request `yolo`/`auto` exception applies only if attached to this new refresh request.

Never force push. A non-fast-forward/diverged branch fails closed. The helper pushes normally only if required, verifies remote SHA, rechecks the comparison after push, writes the PR and assignment, then fetches GitHub metadata and every PR file page. It verifies base, head, title, full body, draft/ready state, assignee, head SHA, and changed-file statuses, including rename sources. Do not declare success if any check fails. If a push or PR creation succeeded before a later failure, report the partial state and URL when available and stop; do not regenerate or retry automatically.

The legacy `-Approved` switch is insufficient. Pass an ID only from the user's exact approval phrase or the scoped same-request `yolo`/`auto` exception. Keep approval artifacts outside the working tree or under ignored `.bot/` and retain them at handoff and on failure. No live PR creation or model-backed eval execution is part of skill validation.

On success return the PR URL, created/updated/already-up-to-date state, title, `base <- head`, assignee, commit count, changed-file count, and the preview link. Do not paste the full body unless requested.
