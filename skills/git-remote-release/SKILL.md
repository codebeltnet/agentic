---
name: git-remote-release
description: >
  Generate GitHub release notes by summarizing all commits and pull requests between two Git tags, branches, or the current branch and the upstream default branch. Use when the user asks to write release notes, generate release notes, draft a GitHub release, create release notes from tags, summarize changes between versions, summarize the current branch, or provides a GitHub compare URL. Trigger phrases: "release notes", "generate release notes", "what changed between", "summarize changes from v1 to v2", "GitHub release", "summarize this branch", compare URLs like "github.com/owner/repo/compare/v1...v2". When no explicit input is given, detects the current branch and compares against the upstream default branch automatically.
---

# Git Remote Release

This skill generates polished GitHub release notes from the commits and pull requests between two tags, two branches, or the current branch and the upstream default branch. It produces a human-friendly summary optimized for release notes, not a raw commit log.

When explicit tags or a compare URL are provided, the skill works entirely through GitHub's API — no local clone is needed. When no input is provided, the skill detects the current Git working repository and resolves the comparison range from local branch and remote state.

## Input

The skill accepts input in three ways, checked in this order:

**1. Compare URL:**

When the user provides a GitHub compare URL like `https://github.com/codebeltnet/agentic/compare/v1.0.0...v1.0.1`, extract the owner, repository, previous ref, and current ref from it.

**2. Separate values:**

- Repository in `owner/repo` format (e.g. `codebeltnet/agentic`)
- Previous ref — a tag (e.g. `v1.0.0`) or branch name
- Current ref — a tag (e.g. `v1.0.1`) or branch name

**3. Default resolution (no input provided):**

When the user does not provide an explicit repository, tag range, compare URL, or branch name, the skill operates on the current Git working repository. See **Default Resolution Behavior** below.

If any required value is missing and cannot be inferred or resolved, ask the user for it before proceeding.

## Default Resolution Behavior

If the user does not provide an explicit repository, tag range, compare URL, branch name, or release range, the skill must operate on the current Git working repository.

In that case, the skill must:

1. Detect the current branch.
2. Detect the upstream remote for the repository.
3. Detect the upstream repository's default branch — usually `main`, but do not assume `main` if the remote default branch can be resolved.
4. Compare the current branch against the upstream remote default branch.
5. Include all commits on the current branch that are not present in the upstream remote default branch.
6. Include all contributors represented by those commits or associated pull requests.
7. Generate the release-note optimized summary from that comparison.

The default comparison should be conceptually equivalent to:

```text
upstream/default-branch...current-branch
```

For example, if the current branch is `feature/git-remote-release` and the upstream default branch is `main`, the comparison should be treated as:

```text
upstream/main...feature/git-remote-release
```

If the repository uses `origin` as the upstream remote, use:

```text
origin/main...current-branch
```

If the repository has both `origin` and `upstream`, prefer the remote that represents the canonical source repository. In fork-based workflows, this is usually `upstream`. In single-repository workflows, this is usually `origin`.

The skill must not silently assume the wrong base branch. If the default branch cannot be resolved, fall back in this order:

1. `origin/HEAD`
2. `upstream/HEAD`
3. `origin/main`
4. `origin/master`
5. `upstream/main`
6. `upstream/master`

If none of these can be resolved, ask the user to provide the base branch or compare URL.

Useful commands for default resolution:

```bash
git rev-parse --abbrev-ref HEAD
git remote
git symbolic-ref refs/remotes/origin/HEAD --short
git symbolic-ref refs/remotes/upstream/HEAD --short
git merge-base HEAD origin/HEAD
git log --oneline origin/main...HEAD
```

## Contributor Handling

Contributor attribution should be based on available GitHub metadata when possible. If GitHub metadata is unavailable, use Git commit author information.

The `Sources:` section must preserve contributor attribution using this format when a GitHub username is available:

```
* <title> by @<author> in <pull-request-or-commit-url>
```

If a GitHub username is unavailable, use the commit author name without the `@` prefix:

```
* <title> by <author-name> in <commit-url-or-sha>
```

When using the current branch default behavior, the skill must include all contributors involved in the detected commits and pull requests. Do not collapse contributor attribution in a way that hides who contributed to the release.

## Workflow

### Step 1: Resolve the input parameters

Determine which input path applies:

- **Compare URL provided:** Extract owner, repository, previous ref, and current ref from the URL.
- **Separate values provided:** Use the supplied repository, previous ref, and current ref.
- **No input provided:** Follow the Default Resolution Behavior to detect the current branch, upstream remote, and base branch from the local Git working repository.

Validate that the repository exists and both refs are reachable before continuing.

### Step 2: Collect commits in the comparison range

Fetch all commits included in the range `previousRef...currentRef` using the GitHub API or local Git commands. For each commit, collect:

- Commit SHA
- Commit message (subject and body)
- Author login

### Step 3: Collect pull requests

For each commit in the range, determine whether it belongs to a merged pull request. Prefer pull request metadata over raw commit data when available, because PRs carry richer context: descriptions, labels, review discussions, and linked issues.

For each pull request, collect:

- PR number and title
- Author login
- PR URL
- PR description/body
- Labels
- Files changed (when available and relevant)

Use commits directly only when:

- A commit is not associated with a pull request
- Pull request metadata is unavailable
- The change was committed directly to the release branch

### Step 4: Analyze and summarize

Read through all collected pull requests and commits. Understand what changed, why it matters, and how it affects users and maintainers. Group related changes together. Identify breaking changes, new features, bug fixes, dependency updates, CI/CD changes, documentation updates, and infrastructure work.

The summary should explain the effect of the changes, not just the implementation. A good release note tells users what they can expect from this version, not just what code was modified.

### Step 5: Compose the release notes

Follow the exact output format defined below. Every release note must start with `## What's Changed` and end with the full changelog link. Nothing may appear after the changelog link.

## Output Format

```markdown
## What's Changed

<optimized-summary>

<optional-alert-blocks>

Sources:

* <title> by @<author> in <url>
* <title> by @<author> in <url>

**Full Changelog**: https://github.com/{owner}/{repo}/compare/{previousRef}...{currentRef}
```

### The summary section

The summary is the heart of the release note. It must be:

- **Human-friendly** — written for someone scanning the release to understand what changed
- **Effect-oriented** — explains what users and maintainers can expect, not just what was modified
- **Evidence-backed** — every claim must be supported by the commits or pull requests collected
- **Grouped logically** — related changes are discussed together, not listed chronologically
- **Honest** — no invented impact, no unsupported claims, no vague filler like "various improvements"

For small releases (a handful of changes), prefer a concise paragraph or short bullet list.

For larger releases, prefer grouped bullets organized by theme: new features, fixes, infrastructure, breaking changes, etc.

Avoid simply repeating PR titles or commit messages unless they are already clear and release-note friendly. Rewrite them into prose that explains the effect.

### Key capabilities formatting (when included)

When the release note includes a "Key capabilities" section, each bullet must be written as a natural sentence with a bolded lead-in.

Do not use a bold label followed by an em dash, colon, or definition-style fragment.

Avoid this style:

```markdown
- **Thematic grouping** — Related changes are discussed together instead of listed chronologically
```

Use this style instead:

```markdown
- **Thematic grouping** where related changes are discussed together instead of listed chronologically,
```

The bold text should highlight the capability name, but the full bullet must read as one natural sentence.

Preferred pattern:

```markdown
- **<Capability name>** where/that/so/with <natural sentence continuation>,
```

End each bullet with `,` except the final bullet in a populated section, which must end with `.`.

### GitHub alert blocks (optional)

Alert blocks draw attention to information that deserves special notice. Use them sparingly — prefer zero to two per release. Only include alerts when the release data genuinely supports the attention level.

Alert blocks appear after the summary and before the `Sources:` section.

**When to use each alert type:**

`> [!NOTE]` — Helpful context, compatibility notes, clarifications for skimmers, non-breaking behavior explanations.

`> [!TIP]` — Recommended usage, easier migration paths, better ways to use a new or changed feature, practical follow-up actions.

`> [!IMPORTANT]` — New capabilities users should notice, required configuration changes, important behavior changes, major release highlights.

`> [!WARNING]` — Breaking changes, deprecated behavior that may affect users soon, changes that can cause builds, tests, runtime behavior, or integrations to fail if ignored.

`> [!CAUTION]` — Security-sensitive changes, data loss risks, removal of functionality, operational risks, changes where misuse can lead to negative outcomes.

Do not invent alerts. Do not add a `WARNING` or `CAUTION` unless the release data supports that level of attention. Breaking changes should normally use `WARNING`. Security-sensitive or risk-heavy changes should normally use `CAUTION`.

### The Sources section

The `Sources:` section preserves the original references that informed the summary. This gives readers a path to the raw details if the summary is not enough.

Each source entry follows this format:

```
* <title> by @<author> in <url>
```

For pull requests, use the PR title and PR URL:

```
* Add validation for skill templates by @gimlichael in https://github.com/codebeltnet/agentic/pull/19
```

For direct commits without a PR, use the commit subject and commit URL:

```
* Fix script path handling by @gimlichael in https://github.com/codebeltnet/agentic/commit/abc123def
```

List every pull request and direct commit that contributed to the release. Do not omit sources.

### The changelog link

The final line of the release note must always be:

```
**Full Changelog**: https://github.com/{owner}/{repo}/compare/{previousRef}...{currentRef}
```

When comparing tags, use the tag names (e.g. `v1.0.0...v1.0.1`). When comparing branches from default resolution, use the branch names (e.g. `main...feature/my-branch`).

Nothing may appear after this line.

## Non-Negotiable Rules

- The first line of the output is exactly `## What's Changed`.
- The summary covers all meaningful changes in the comparison range.
- The summary is optimized for GitHub release notes, not raw commit history.
- Alert blocks are included only when they add value and are supported by the release data.
- Alert severity matches the actual impact of the change.
- The `Sources:` section is always included.
- Source entries use the `* <title> by @<author> in <url>` format, falling back to `* <title> by <author-name> in <url>` when no GitHub username is available.
- The final line is the full changelog link in the exact format shown above.
- Nothing appears after the full changelog link.
- No unsupported claims are invented.
- Breaking changes, if any, are clearly identified.
- Vague wording like "various improvements" or "miscellaneous changes" is avoided.
- The skill prefers pull request metadata over raw commits when available.
- Direct commits are used only when PR metadata is unavailable or the change was committed directly.
- Related changes are grouped in the summary rather than listed chronologically.
- The summary explains the effect of changes, not just the implementation.
- Dependency, build, test, documentation, CI/CD, and infrastructure changes are included when meaningful.
- The skill does not mutate any repository state — it is entirely read-only.
- When no explicit input is provided, the skill follows the Default Resolution Behavior instead of asking the user for a repository or tag range.
- All contributors in the comparison range are represented in the Sources section.

## Data Collection Strategy

The skill uses GitHub's API and local Git commands to gather data. The preferred approach depends on the input path and what tools are available.

**When explicit tags or a compare URL are provided**, use GitHub's API. The preferred approach depends on what tools are available in the agent environment.

When GitHub MCP tools are available (such as `github_list_commits`, `github_get_commit`, `github_pull_request_read`), use them directly. They provide structured data without requiring shell access.

When `gh` CLI is available, use these commands:

```bash
gh api repos/{owner}/{repo}/compare/{previousRef}...{currentRef} --jq '.commits[]'
gh api repos/{owner}/{repo}/commits/{sha}/pulls --jq '.[]'
gh pr view {number} --repo {owner}/{repo} --json title,author,body,labels,files,url
```

**When using default resolution (no explicit input)**, combine local Git commands with GitHub API:

```bash
git rev-parse --abbrev-ref HEAD
git remote
git symbolic-ref refs/remotes/origin/HEAD --short
git log --oneline origin/main...HEAD
git log --format="%H %an %ae" origin/main...HEAD
```

Then use the GitHub API to enrich local commit data with pull request metadata, labels, and descriptions.

**When neither is available**, guide the user to install `gh` or authenticate with GitHub.

For each commit in the compare range, check whether it belongs to a pull request. GitHub's API can resolve this through the commit's associated pull requests endpoint. When a commit maps to a PR, use the PR's metadata (title, description, labels) as the primary source of truth for that change.

## Quality Checklist

Before returning the result, verify:

1. The first line is exactly `## What's Changed`.
2. The summary is human-friendly and optimized for GitHub release notes.
3. The summary covers the meaningful changes in the comparison range.
4. GitHub alert blocks are included only when they add value.
5. Alert severity matches the actual impact of the change.
6. Alert blocks are supported by the release data.
7. A `Sources:` section is included with all contributing PRs and commits.
8. Source entries use the `* <title> by @<author> in <url>` format, with fallback to author name when no GitHub username is available.
9. All contributors in the comparison range are represented in the Sources section.
10. The final line is the full changelog link.
11. Nothing appears after the full changelog link.
12. No unsupported claims were invented.
13. Breaking changes, if any, are clearly identified.
14. When using default resolution, the comparison range correctly reflects the current branch against the upstream default branch.
