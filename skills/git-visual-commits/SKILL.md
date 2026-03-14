---
name: git-visual-commits
description: >
  Rules and workflow for creating well-structured git commits using emoji
  prefixes (gitmoji and beyond), with support for git bot commit
  (AI-authored), regular git commit (human-authored), and git our commit
  (collaborative — agent analyzes authorship and human picks attribution).
  Use this skill whenever the user asks to commit changes, stage files,
  write a commit message, or review what should be committed. Also use it
  when the user says things like "commit this", "make a commit", "commit
  your changes", "commit what you just did", "what should my commit
  message be", "stage and commit", or any time git commit workflows come
  up. Supports auto-approval mode — when the user says "yolo" or "auto"
  in their request, or enables it for the session, the agent shows the
  commit plan but proceeds without waiting for confirmation. Enforces
  conventions with emoji plus lowercase prefix (init, content, style, fix,
  refactor, docs), max 70 chars, one logical change per commit, grouped
  by technology type.
---

# Git Visual Commits

This skill drives the entire git commit workflow — reviewing changes, grouping them logically, composing messages with the right emoji and prefix, and running the commit. It supports three identity modes: bot-attributed (`git bot commit`), human-attributed (`git commit`), and collaborative (`git our commit`).

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

- **Emoji** comes first — picked from the technology/type tables below
- **Prefix** is lowercase (see allowed prefixes below) — **never use `feat:`**
- **Description** is lowercase, imperative, max 70 characters total (including emoji and prefix)
- **Body** is included by default — a short paragraph (2–4 lines) explaining *why* the change was made, not just *what* changed. Separate from the subject with a blank line. Wrap at 72 characters. Can be suppressed with `no-body` (see below).
- One logical change per commit — don't bundle unrelated things

### Allowed Prefixes

Prefixes are **optional** — only include one when it adds clarity beyond what the emoji already conveys. Many commits need no prefix at all (e.g. `🚚 rename auth module to identity`, `➕ add validation library`). When you do use a prefix, pick from this list:

| Prefix | Use When |
|--------|----------|
| `init:` | Initial setup or configuration of something new |
| `content:` | Endpoint definitions, DTOs, contracts, data shapes |
| `style:` | Code formatting, cleanup, aesthetic changes |
| `fix:` | Bug fixes |
| `refactor:` | Restructuring without behavior change |
| `docs:` | Documentation, XML comments, OpenAPI annotations |

### Emoji Selection — Gitmoji First, Fallback Second

**Always prefer an official [gitmoji](https://gitmoji.dev) emoji** when the semantic meaning is a good fit. Only use a non-gitmoji emoji when no official entry matches well enough.

#### Primary: Gitmoji

| Emoji | Gitmoji code | Use when | Example |
|-------|-------------|----------|---------|
| 🎉 | `:tada:` | Begin a brand-new project | `🎉 init: begin api project` |
| ✨ | `:sparkles:` | Introduce new application code, modules, endpoints, features | `✨ add user submission endpoint` |
| 🎨 | `:art:` | Code style, formatting, structure cleanup | `🎨 style: format endpoint modules` |
| ⚡️ | `:zap:` | Improve performance | `⚡️ optimize query execution in repository` |
| 🐛 | `:bug:` | Fix a bug | `🐛 fix: handle null optional fields in dto` |
| 🩹 | `:adhesive_bandage:` | Simple fix for a non-critical issue | `🩹 fix: correct default value in config` |
| 🚑️ | `:ambulance:` | Critical hotfix | `🚑️ fix: patch auth bypass vulnerability` |
| ✏️ | `:pencil2:` | Fix typos | `✏️ fix: correct typo in error message` |
| ♻️ | `:recycle:` | Refactor code | `♻️ refactor: extract mapper to separate class` |
| 🚚 | `:truck:` | Move or rename files, folders, or resources | `🚚 rename auth module to identity` |
| 🔥 | `:fire:` | Remove code or files | `🔥 remove deprecated submission handler` |
| ⚰️ | `:coffin:` | Remove dead code | `⚰️ remove unused dto properties` |
| 🗑️ | `:wastebasket:` | Deprecate code that needs cleanup | `🗑️ deprecate v1 submission endpoint` |
| 📝 | `:memo:` | Documentation, inline comments, API annotations | `📝 docs: add inline docs to submission handler` |
| 💡 | `:bulb:` | Add or update inline comments | `💡 add comments to submission processing logic` |
| 💬 | `:speech_balloon:` | Add or update text and literals | `💬 update validation error messages` |
| 🔧 | `:wrench:` | Configuration files (app config, environment settings) | `🔧 init: configure swagger and versioning` |
| 🔨 | `:hammer:` | Add or update development scripts | `🔨 add build script for release packaging` |
| ➕ | `:heavy_plus_sign:` | Add a package dependency | `➕ add validation library` |
| ➖ | `:heavy_minus_sign:` | Remove a package dependency | `➖ remove unused logging package` |
| ⬆️ | `:arrow_up:` | Upgrade package dependencies | `⬆️ upgrade dependencies to latest` |
| ⬇️ | `:arrow_down:` | Downgrade dependencies | `⬇️ downgrade ef core to stable release` |
| 📌 | `:pushpin:` | Pin dependencies to specific versions | `📌 pin node version to 20 lts` |
| 🗃️ | `:card_file_box:` | Database changes, ORM models, migrations, entities | `🗃️ add submission entity and db context` |
| 🌱 | `:seedling:` | Add or update seed files | `🌱 add initial request table migration` |
| ✅ | `:white_check_mark:` | Add or update tests | `✅ add integration tests for submission api` |
| 🧪 | `:test_tube:` | Add a failing test (TDD red phase) | `🧪 add failing test for null notes field` |
| 🦺 | `:safety_vest:` | Validation code | `🦺 add submission dto validation rules` |
| 🥅 | `:goal_net:` | Catch errors | `🥅 add global exception handler middleware` |
| 👔 | `:necktie:` | Business logic, service layer, domain code | `👔 add submission processing service` |
| 🏷️ | `:label:` | Add or update types, interfaces, contracts (type-only) | `🏷️ content: add submission dto contracts` |
| 🔒️ | `:lock:` | Security or privacy fixes | `🔒️ fix: prevent open redirect in login` |
| 🔐 | `:closed_lock_with_key:` | Add or update secrets | `🔐 add key vault secret references` |
| 🛂 | `:passport_control:` | Authorization, roles, and permissions | `🛂 add role-based access policy` |
| 🚨 | `:rotating_light:` | Fix compiler or linter warnings | `🚨 fix: resolve nullable warnings in handler` |
| 💚 | `:green_heart:` | Fix CI build | `💚 fix: correct test runner config in pipeline` |
| 👷 | `:construction_worker:` | Add or update CI build system | `👷 add github actions workflow` |
| 🚀 | `:rocket:` | Deploy stuff | `🚀 deploy request api to staging` |
| 🏗️ | `:building_construction:` | Make architectural changes | `🏗️ refactor: restructure to clean architecture` |
| 🧱 | `:bricks:` | Infrastructure related changes | `🧱 add terraform modules for staging` |
| 📦️ | `:package:` | Add or update compiled files or packages | `📦️ update nuget package output config` |
| 💄 | `:lipstick:` | Add or update the UI and style files | `💄 style: update button styles` |
| ♿️ | `:wheelchair:` | Improve accessibility | `♿️ add aria labels to navigation` |
| 📱 | `:iphone:` | Work on responsive design | `📱 style: add mobile breakpoints` |
| 🌐 | `:globe_with_meridians:` | Internationalization and localization | `🌐 add resource files for localization` |
| 🔖 | `:bookmark:` | Release / version tags | `🔖 tag v1.2.0 release` |
| 💥 | `:boom:` | Introduce breaking changes | `💥 remove deprecated v1 api endpoints` |
| ⏪️ | `:rewind:` | Revert changes | `⏪️ revert submission handler refactor` |
| 🔀 | `:twisted_rightwards_arrows:` | Merge branches | `🔀 merge feature branch into main` |
| 📄 | `:page_facing_up:` | Add or update license | `📄 add mit license` |
| 🙈 | `:see_no_evil:` | Add or update a .gitignore file | `🙈 add build output to gitignore` |
| 🔊 | `:loud_sound:` | Add or update logs | `🔊 add request logging middleware` |
| 🔇 | `:mute:` | Remove logs | `🔇 remove verbose debug logging` |
| 🩺 | `:stethoscope:` | Add or update healthcheck | `🩺 add health endpoint for readiness probe` |
| 🚩 | `:triangular_flag_on_post:` | Add, update, or remove feature flags | `🚩 add feature flag for new search` |
| 👽️ | `:alien:` | Update code due to external API changes | `👽️ fix: adapt to new payment api contract` |
| 🧵 | `:thread:` | Multithreading or concurrency code | `🧵 add async processing pipeline` |
| 🍱 | `:bento:` | Add or update assets | `🍱 add logo and icon assets` |
| 🦖 | `:t-rex:` | Code that adds backwards compatibility | `🦖 add v1 compatibility shim` |
| ✈️ | `:airplane:` | Improve offline support | `✈️ add service worker for offline mode` |
| 🚸 | `:children_crossing:` | Improve user experience / usability | `🚸 simplify onboarding flow` |
| ⚗️ | `:alembic:` | Perform experiments | `⚗️ spike alternative caching strategy` |
| 🚧 | `:construction:` | Work in progress (avoid where possible) | `🚧 wip: partial submission module setup` |

#### Fallback: Extended Emoji Reference

When no gitmoji entry fits, consult **[this curated extended reference](https://gist.github.com/marcellodesales/aba1152a91d69f9b39745a08fd73a6f9)** — a multi-source collection covering languages, platforms, cloud infra, and programming strategies that gitmoji doesn't address.

Key entries from that reference, by category:

**Bootstrapping & infrastructure**

| Emoji | Use when | Example |
|-------|----------|---------|
| ⚙️ | App bootstrapping / host setup (distinct from 🔧 config files) | `⚙️ init: setup app host and middleware` |
| ☁️ | Cloud provider setup or changes | `☁️ add cloud secrets integration` |
| ☸️ | Kubernetes | `☸️ add k8s deployment manifests` |
| 🎡 | Helm charts | `🎡 add helm chart for api service` |
| 🧮 | Lambda / serverless functions | `🧮 add serverless function trigger` |

**Containers & deployment**

| Emoji | Use when | Example |
|-------|----------|---------|
| 🐳 | Docker | `🐳 add dockerfile for api deployment` |

**Data & storage**

| Emoji | Use when | Example |
|-------|----------|---------|
| 🛢 | General database (when 🗃️ feels too narrow) | `🛢 add request storage schema` |
| 🐘 | PostgreSQL-specific | `🐘 add postgres connection config` |

**Documentation**

| Emoji | Use when | Example |
|-------|----------|---------|
| 📚 | High-level docs, README, wiki (gitmoji's 📝 covers inline/XML docs) | `📚 docs: add api usage documentation` |

**Observability & runtime**

| Emoji | Use when | Example |
|-------|----------|---------|
| 🪵 | Structured logging setup | `🪵 add structured logging setup` |
| 📢 | Notifications or event publishing | `📢 add submission event notification` |
| 🏃 | Background workers or hosted services | `🏃 add background worker for processing` |

**Patterns & architecture**

| Emoji | Use when | Example |
|-------|----------|---------|
| 🧩 | Components, modules, DI registrations | `🧩 register services in di container` |
| 🏭 | Factory patterns | `🏭 add submission handler factory` |
| 📆 | Schedulers, cron, background jobs | `📆 add cron scheduler for cleanup job` |
| 🤖 | AI / ML integrations | `🤖 add openai client integration` |

**AI / tools (when relevant)**

| Emoji | Use when | Example |
|-------|----------|---------|
| 🦾 | AI prompt or agent code | `🦾 add ai prompt template for request triage` |
| 🧠 | LLM integrations | `🧠 integrate chatgpt for request classification` |

> When in doubt between two options, pick the emoji whose meaning most closely matches *what the change actually does*. If nothing fits, use 🎭 (`:performing_arts:`) as a last resort and note the intent in the message.

---

## Auto-Approval Mode

By default, the agent presents a commit plan and waits for user confirmation before staging and committing (Step 4). Auto-approval mode skips this wait — the plan is still displayed for transparency, but the agent proceeds immediately.

**What auto-approval skips:** user confirmation only.
**What auto-approval never skips:** classification (Step 2), grouping validation (Step 3), and the mixed-scope guard. These self-checks run unconditionally — they exist to catch bad groupings before they become commits, regardless of whether a human is reviewing the plan.

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

Run `git status` and `git diff` (and `git diff --staged` if there are staged changes) to understand what has changed. Don't commit blindly — understand what each file is doing before grouping.

### Step 2: Classify changes

Before composing any commit message, bucket every changed file by its **semantic intent** — not just its file type. Read the actual diff for each file and ask: *"What is this change trying to accomplish?"* Two files of the same type (e.g. two test files) may have completely different intents and belong in separate commits.

Derive categories from the actual diff — don't assume a fixed set. Common categories include:

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

### Step 6: Verify

After committing, run `git log --oneline -5` to confirm the commit looks right. Check the author with `git log -1 --format="%an <%ae>"` if needed.

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

Align with the official skill directory structure: SKILL.md, scripts/,
references/, and assets/. Updates all path references in SKILL.md,
reference docs, and AGENTS.md for both app and library skills.
```

```
♻️ refactor: streamline app skill with FORMS.md wizard

Replace inline parameter table with structured FORMS.md form definition.
Step 1 now references FORMS.md instead of listing 12 fields inline.
```

## Bad Examples (and why)

```
feat: add submission endpoint            ← "feat:" is not an allowed prefix
✨ Feat: Add Submission Module            ← uppercase, "Feat:" not allowed
🎉 initial commit with all files         ← vague, bundles everything
⚙️ config: setup api                     ← "config:" is not an allowed prefix
```

---

## Branching (for reference)

Branch format: `[version]/[description]`

Examples:
- `v1.0.0/mvp` — initial MVP
- `v1.1.0/validation` — adding validation
- `v1.2.0/admin-dashboard` — new feature area

Don't create, rename, or delete branches unless the user explicitly asks.
