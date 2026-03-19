---
name: git-visual-commits
description: >
  Structured git commit workflow with emoji prefixes and identity-aware modes: `git bot commit`, regular `git commit`, and `git our commit`. Use this skill whenever the user asks to commit changes, stage files, write a commit message, or review what should be committed. Also use it when the user says "commit this", "make a commit", "commit your changes", "commit what you just did", "what should my commit message be", "stage and commit", "git bot commit", "git our commit", or combines a commit request with "yolo" or "auto". Treat commit wording as an automatic trigger for this skill, not as a casual hint. Supports auto-approval mode and enforces emoji plus lowercase prefixes, max 70 chars, one logical change per commit, technology-aware grouping, and post-commit identity verification.
---

# Git Visual Commits

This skill drives the entire git commit workflow — reviewing changes, grouping them logically, composing messages with the right emoji and prefix, and running the commit. It supports three identity modes: bot-attributed (`git bot commit`), human-attributed (`git commit`), and collaborative (`git our commit`).

## Critical Rules

### Identity Lock

- If the user asked for `git bot commit`, you must use `git bot commit`.
- If the user asked for `git commit`, you must use `git commit`.
- If the user asked for `git our commit`, follow the attribution workflow and then use the matching command per group.
- Never silently downgrade a requested `git bot commit` to `git commit`.
- If the required `git bot` alias is unavailable, halt and report that exact blocker instead of falling back to human identity.

### Auto-Approval Guard

`yolo` / `auto` skips user confirmation only. It never skips:

- skill activation
- identity selection
- semantic grouping
- mixed-scope validation
- post-commit author verification

### Default Scope Rule

If the user says `git bot commit`, `git commit`, or `git our commit` without narrowing language, treat the request as covering the full current worktree.

- The default scope is **all current changes visible in git status**.
- Your job is to group that full worktree into the right number of commits by semantic intent.
- Never silently narrow the scope to "just the files from the last thing I worked on", "just the files I touched", or "just the newest skill" unless the user explicitly said to do that.
- `yolo` keeps this same full-worktree default. It removes the approval wait; it does not narrow scope.

Narrow scope only when the user explicitly does one of these:

- names a specific path, file, module, project, or technology slice
- says `just`, `only`, `for this`, `for X`, `commit the README changes`, or equivalent limiting language
- asks for a review/plan for a subset before committing

If the user did not narrow scope, do not invent a narrower scope on their behalf.

### Post-Commit Verification

After every commit, run:

```bash
git log -1 --format="%an <%ae>"
```

Confirm that the author matches the requested identity mode. If the author is wrong, treat the commit as invalid and repair it before reporting success.

Then verify the stored commit message body too:

```bash
git log -1 --format=%B
```

If the body contains literal escape sequences such as `\n` instead of real line breaks, treat the commit message as invalid and repair it before reporting success.

Also reject a stored short prose body when it was split across lines only to chase a 72-column habit. If a non-empty body line ends mid-sentence and the next non-empty line simply continues that same sentence, treat the commit message as invalid and repair it before reporting success. A single short paragraph should usually stay as one natural prose line; add manual line breaks only for real paragraphing, lists, quotes, or readability-driven separation.

### Umbrella Commit Rejection

Reject a single umbrella commit when the diff spans multiple intents such as:

- skill instructions (`SKILL.md`, `FORMS.md`, `references/`, `evals/`)
- scaffold/template/runtime files (`assets/`, scaffold helper scripts)
- validation/tooling (`scripts/`, repo validators)
- repo docs or repo policy (`README.md`, `AGENTS.md`, `CONTRIBUTING.md`)

`yolo`, small file count, or "the changes are related" are not valid reasons to collapse these into one commit.

## Prerequisites

The `git bot commit` command requires a one-time alias setup in your global git config. Run this once per machine:

```bash
git config --global alias.bot '!git -c user.name="<bot-name>" -c user.email="<bot-email>"'
```

Replace `<bot-name>` and `<bot-email>` with the identity you want AI-authored commits to appear under.

Verify it works:

```bash
git bot commit --allow-empty -m "test bot identity"
git log -1 --format="%an <%ae>"   # should show bot name and email
git reset HEAD~1                   # undo the test commit
```

If `git config --global --get alias.bot` returns nothing when the user asked for `git bot commit`, stop and report that the bot alias is missing. Do not proceed with `git commit` as a fallback.

---

## When to use `git bot commit` vs `git commit` vs `git our commit`

In all cases, **the AI does all the work** — reviewing changes, grouping them logically, composing the message, staging files, and running the command. The only difference is which identity the commit is attributed to.

| | `git bot commit` | `git commit` | `git our commit` |
|---|---|---|---|
| **When** | User asks the AI to commit (e.g. "commit your changes", "do a git bot commit") | User asks to commit under their own identity (e.g. "please do a git commit") | User says "our commit" or the work was collaborative (both human and agent edited files) |
| **Who gets credit** | Bot alias (e.g. `aicia[bot]`) | Human's default git profile | Agent analyzes authorship, human picks attribution |
| **Command** | `git bot commit -m "..."` | `git commit -m "..."` | Either, based on human's choice |

### How `git our commit` works

When the user says "our commit" (or similar), the agent attributes each commit to whoever authored the files in it:

1. **Analyze the diff** — review all changed files and determine which were modified by the agent during the current session vs which were edited by the human outside the session
2. **Present the breakdown** — show the user a summary:
   ```
   🤖 Agent-authored:  src/UserService.cs, src/UserController.cs
   👤 Human-authored:  README.md, appsettings.json
   🤝 Mixed/unclear:  src/Startup.cs
   ```
3. **Group into commits** (Step 2 of the main workflow) — then assign attribution per group:
   - If all files in a group are agent-authored → `git bot commit`
   - If all files in a group are human-authored → `git commit`
   - If a group has mixed/unclear files → ask: **"Who should be the author for this group — you or bot?"**
4. **Present the commit plan with attribution already assigned** — show which commits use which identity:
   ```
   1. 🙈 add gitignore                          (👤 you)
      Files: .gitignore
   2. 🦾 init: add agent agreements              (🤖 bot)
      Files: AGENTS.md
   3. 🍱 add photo and hero image assets         (👤 you)
      Files: assets/dj-photo.jpg, assets/hero.png
   ```
   The user confirms or adjusts the plan — they can override any attribution.
5. **Commit** each group with its assigned identity — no `Co-authored-by` trailer (GitHub's PR flow already tracks collaboration)

The commit message format, emoji conventions, grouping strategy, and everything else is **identical** for both. The profile is the only thing that changes.

Never add or modify git remotes. Never set `git user.name` or `git user.email` locally.

---

## Commit Message Format

```
<emoji> <prefix>: <short description>

<body>
```

- **Emoji** comes first — picked from `references/commit-language.md`
- **Prefix** is lowercase (see `references/commit-language.md`) — **never use `feat:`**
- **Description** is lowercase, imperative, max 70 characters total (including emoji and prefix)
- **Body** is included by default — a short paragraph explaining *why* the change was made, not just *what* changed. Separate from the subject with a blank line. Do **not** hard-wrap commit bodies at 72 characters; keep short bodies as normal prose and add line breaks only when they improve readability. Can be suppressed with `no-body` (see below).
- **Body repair rule** — if verification shows the stored body was split mid-sentence just to fit an arbitrary width, amend the commit before reporting success.
- One logical change per commit — don't bundle unrelated things

### Prefix and Emoji Reference

Read `references/commit-language.md` before choosing a prefix or emoji. It contains the allowed prefixes, the gitmoji-first table, and the extended emoji fallback guidance shared with `git-visual-squash-summary`. Keep that duplicated reference byte-for-byte aligned with the `git-visual-squash-summary` copy; the validator and CI both enforce that sync contract.

---

## Auto-Approval Mode

By default, the agent presents a commit plan and waits for user confirmation before staging and committing (Step 4). Auto-approval mode skips this wait — the plan is still displayed for transparency, but the agent proceeds immediately.

**What auto-approval skips:** user confirmation only. **What auto-approval never skips:** classification (Step 2), grouping validation (Step 3), and the mixed-scope guard. These self-checks run unconditionally — they exist to catch bad groupings before they become commits, regardless of whether a human is reviewing the plan.

### Per-request activation

Include the word **"yolo"** or **"auto"** anywhere in your request:

- "yolo commit this"
- "auto commit my changes"
- "do a git bot commit, yolo"

The agent will show a one-line commit plan summary and proceed without waiting. Example:

```
Auto-committing: 🔧 build/toolchain → 🚚 moved types → 💥 breaking shim removal → 📝 release notes
```

### Session-level activation

Say **"enable yolo mode"** or **"enable auto mode"** to activate auto-approval for the rest of the session. All subsequent commits skip the approval gate until the user says **"disable yolo mode"** or **"disable auto mode"**.

> **Note:** Auto-approval applies to all three identity modes (`git commit`, `git bot commit`, `git our commit`). For `git our commit`, the agent still presents the authorship breakdown and attribution — but proceeds with its best-guess attribution without waiting for confirmation. The user can always say "undo" or "reset" if the result isn't right.

---

## No-Body Mode

By default, every commit includes a body paragraph explaining *why* the change was made. This can be suppressed when only a subject line is desired.

### Per-request activation

Include **"no-body"** or **"tmi"** anywhere in your request:

- "git bot commit, no-body"
- "commit this tmi"
- "yolo tmi" (combines both modes)

### Session-level activation

Say **"enable no-body mode"** or **"enable tmi mode"** to suppress commit bodies for the rest of the session. All subsequent commits will be subject-only until the user says **"disable no-body mode"** or **"disable tmi mode"**.

> **Note:** No-body mode suppresses the body paragraph only. The subject line, emoji, prefix, classification, and grouping rules all still apply.

---

## Commit Workflow

### Step 1: Review changes

Run `git status` and `git diff` (and `git diff --staged` if there are staged changes) to understand what has changed.

Unless the user explicitly narrowed scope, inspect the **entire current worktree** and build the commit plan from that full set of changes. Do not default to the last task only.

Don't commit blindly — understand what each file is doing before grouping.

### Step 2: Classify changes

Before composing any commit message, bucket every changed file by its **semantic intent** — not just its file type. Read the actual diff for each file and ask: *"What is this change trying to accomplish?"* Two files of the same type (e.g. two test files) may have completely different intents and belong in separate commits.

Derive categories from the actual diff — don't assume a fixed set. Common categories include:

- **New repo capabilities** — introducing a new repo-managed skill, workflow, or top-level capability
- **Existing skill refactors** — restructuring or extracting shared rules from an already existing skill
- **Project/solution files** — build system metadata that defines project structure
- **Preprocessor/build-only changes** — conditional compilation, build-target switches
- **Build/tooling** — CI workflows, container definitions, build scripts
- **Environment/configuration** — test environment config, connection strings, runner settings, infra setup
- **Source moves/renames** — renamed files, moved namespaces, updated imports
- **Breaking removals** — removed public types, deleted forwarding attributes, dropped compatibility shims
- **Documentation** — readmes, changelogs, contributing guides, release notes, inline doc comments
- **Application code** — new features, bug fixes, refactors, business logic
- **Test logic** — changed assertions, updated expectations, new test cases, modified test behavior

**Critical distinction:** "Environment/configuration" and "Test logic" are separate categories even when both live under a test project. A test environment config file (`testenvironments.json`, `appsettings.test.json`) describes *how tests run*. A test assertion file describes *what tests verify*. These are different intents.

**Repo-skill distinction:** Adding a brand-new skill folder is a **new repo capability**. Extracting shared wording, tightening an existing skill, or adding validator coverage for that skill is a different intent. Even when all of that work is related, do not collapse "new skill introduced" and "existing skill refactored" into one commit.

This classification drives grouping in Step 3. Files with different semantic intents almost never belong in the same commit.

### Step 3: Group into logical commits

Group changes by **semantic intent**, not just by file type or directory. Ask yourself: *"Could I explain each commit in one sentence without using the word 'and'?"* If you need "and" to describe what a commit does, it's likely two commits.

#### Semantic intent splitting

For every proposed commit, verify that all files share the same *rationale*. Prefer multiple commits when:

- One change is **environment/configuration** and another is **test logic or code behavior** — even if both are "test-related"
- The **explanation for why each file changed** differs materially
- One file changed because of an **operational/infrastructure decision** and another because of a **framework or API change**

When only two files changed but their rationales differ, **explicitly state that two commits are warranted** in the commit plan. Small file count does not justify bundling.

#### Commit body guidance

Unless **no-body mode** is active, every commit includes a body explaining the *why*:

- **Config/environment commits** → explain the operational intent (e.g. "Switch to shared-runner testing strategy with multi-image matrix")
- **Test assertion changes** → explain why the expectation changed (e.g. "net11 changed the default precision for DateTime, updating expected value")
- **Refactors** → explain what motivated the restructuring
- **New features** → explain the purpose and scope
- **Bug fixes** → explain what was broken and how this fixes it

Common groupings:
- New repo-managed skill or workflow introduction together
- Existing skill refactor or extraction together
- Config/setup files together (app host, bootstrapping)
- Environment and infrastructure config together (test runners, CI matrix, container settings)
- New feature or module code together
- Data contracts, types, and interfaces together
- Database models, migrations, and schema changes together
- Test logic and assertions together (when they share the same rationale)
- Documentation and inline comments together

When in doubt, one commit per "thing that changes" is better than one big commit.

#### Mixed-scope guard

After grouping, validate each proposed commit. If a single commit contains files from **three or more different categories** from Step 2 (e.g. docs + package props + solution files + API removals), **force a split**. A commit that touches documentation, build configuration, and source code at the same time is almost always an umbrella commit that should be broken apart.

This guard runs unconditionally — including in auto-approval mode.

#### Documentation separation rule

Documentation files (`CHANGELOG.md`, `AGENTS.md`, `README.md`, `CONTRIBUTING.md`, release notes) are **separate-by-default**. They only belong in the same commit as non-doc files when the commit is explicitly documentation-focused (e.g. `📝 docs: add api usage guide` where the docs are the point, not a side effect).

#### Repo-aligned grouping example

When a repo like this one mixes skill changes, scaffold assets, validators, and repo docs, split them by intent:

- **New repo-managed skill** — a newly introduced `skills/<name>/` folder and its local `evals/` or `references/`
- **Existing skill refactor** — extracting shared rules, renaming sections, or reorganizing an existing skill
- **Skill contract files** — `SKILL.md`, `FORMS.md`, `references/`, `evals/`
- **Template/runtime files** — `assets/`, scaffold helper scripts
- **Validation/tooling** — validator scripts, repo checks
- **Repo docs/rules** — `README.md`, `AGENTS.md`, `CONTRIBUTING.md`

Do not merge these into one commit unless the diff is truly single-purpose and the explanation still fits one sentence without using "and".

If a commit both introduces a brand-new skill and refactors an existing skill to support it, prefer separate commits. "Related" is not enough — the repo history should make it obvious which commit added the capability and which commit reorganized existing behavior around it.

#### Rename vs removal distinction

Treat **renamed/moved source files** and **removed type-forwarding or compatibility metadata** as different signals — never group them together:

- **Renames** (file moved, namespace changed, `using` updated) → move/refactor commit (`🚚` or `♻️`)
- **Removed forwarding** (deleted `[TypeForwardedTo]`, removed public-API compatibility shims, dropped re-exports) → breaking-change commit (`💥`)

Even when renames and removals happen in the same PR, they represent different intents and must be separate commits.

### Step 4: Present commit plan for review

Before staging or committing anything, present the full commit plan to the user. For each proposed commit, show:

```
1. 🚚 rename auth module to identity
   Files: src/Auth/ → src/Identity/, README.md

2. ✅ add integration tests for identity module
   Files: tests/Identity.Tests/
```

**If auto-approval is active** (via "yolo"/"auto" keyword or session-level setting), display a one-line summary and proceed immediately to Step 5:

```
Auto-committing: 🔧 build config → 🚚 rename auth to identity → ✅ identity tests → 📝 update changelog
```

Even in auto-approval mode, surface the commit buckets explicitly before committing. Auto-approval removes the wait, not the planning step.

If the user did not narrow scope, the plan you surface must account for the full worktree rather than an arbitrarily chosen subset.

**Otherwise**, wait for the user to confirm or adjust. They may say things like:
- "Looks good" → proceed to stage and commit
- "Change #1 to ♻️" → swap the emoji and re-present
- "Merge 1 and 2 into one commit" → regroup and re-present
- "Use refactor: prefix on #1" → adjust and re-present

Only proceed to Step 5 after the user approves the plan.

#### Commit-message validation

Before committing, validate each message against its file list:

- **Breaking-change check:** If the commit subject contains "breaking" or uses 💥, verify that the majority of files in that commit directly implement or document the breaking change. Build-matrix files, CI config, environment files, and unrelated tooling changes **fail this check** — move them to a separate commit.
- **Scope consistency:** The commit message should accurately describe what the files do. If the message says "rename" but the commit includes deletions of compatibility shims, split them.

### Step 5: Stage and commit each group

For each group:
1. `git add <specific files>` — be precise, don't use `git add .` unless everything belongs in one commit
2. Compose the commit message (see format above)
3. Run the appropriate commit command:
   - `git bot commit -m "<subject>"` — if the user asked the AI to commit (bot identity)
   - `git commit -m "<subject>"` — if the user asked to commit under their own identity
   - For `git our commit` — use whichever command matches the attribution the human chose
   - **With body:** use `-m "<subject>" -m "<body>"` to add the optional description paragraph

When a commit body spans multiple lines, use real multiline input such as multiple `-m` arguments or a shell construct that preserves actual line breaks. Do not pass literal `\n` escape sequences and assume the shell will rewrite them. Prefer grammatical sentence and paragraph breaks over column-based hard wrapping.

When the body is just one short explanatory paragraph, prefer a single natural prose line in the stored commit message. Do not press Enter mid-sentence to satisfy an arbitrary width target.

### Step 6: Verify

After committing, run `git log --oneline -5` to confirm the commit looks right. Then always run `git log -1 --format="%an <%ae>"` and verify that the author matches the requested identity mode before reporting success. Also run `git log -1 --format=%B` and verify the stored body contains readable prose with real line breaks, not literal escape sequences such as `\n`, and is not hard-wrapped mid-sentence just to satisfy a column limit. If that verification fails, amend the commit immediately instead of merely warning about it.

---

## Good Examples

Subject-only (when the change is self-explanatory):
```
🎉 init: begin api project
✨ add submission endpoint module
🐛 fix: handle null optional fields in dto
➕ add validation library
```

With body (when context adds value):
```
🚚 rename templates/ to assets/ per Anthropic skill conventions

Align with the official skill directory structure: SKILL.md, scripts/, references/, and assets/. Updates all path references in SKILL.md, reference docs, and AGENTS.md for both app and library skills.
```

```
♻️ refactor: streamline app skill with FORMS.md wizard

Replace inline parameter table with structured FORMS.md form definition.
Step 1 now references FORMS.md instead of listing 12 fields inline.
```

With body repair after a bad first attempt:
```
📝 docs: add git release-note guidance

Clarify when the repo should keep release-note docs separate from code changes so commit history stays easier to scan and review.
```

## Bad Examples (and why)

```
feat: add submission endpoint            ← "feat:" is not an allowed prefix
✨ Feat: Add Submission Module            ← uppercase, "Feat:" not allowed
🎉 initial commit with all files         ← vague, bundles everything
⚙️ config: setup api                     ← "config:" is not an allowed prefix
```

```
📝 docs: add git release-note guidance

Clarify when the repo should keep release-note docs separate
from code changes so commit history stays easier to scan and review.
                                         ← bad wrap: short prose split mid-sentence for width only
```

---

## Branching (for reference)

Branch format: `[version]/[description]`

Examples:
- `v1.0.0/mvp` — initial MVP
- `v1.1.0/validation` — adding validation
- `v1.2.0/admin-dashboard` — adding a new feature area

Don't create, rename, or delete branches unless the user explicitly asks.
