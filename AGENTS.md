# Agent Guidelines

Repository-level rules for AI agents working in this codebase.

## Eval Isolation

Eval workspaces and test repositories must **never** be created inside this repository. This includes:

- `<skill-name>-workspace/` directories
- Temporary git repos for testing skills
- Test branches, throwaway commits, or config overrides (e.g. git aliases)

When running evals or testing skills, create all workspaces in a temp location:

- **Windows**: `$env:TEMP/<skill-name>-workspace/`
- **Unix**: `/tmp/<skill-name>-workspace/`

**Why:** Eval artifacts — branches, commits, local git config — leak into the real repo history and are painful to clean up. The skill source lives in a git repo; eval output does not belong here.

## Per-Skill Evals

Every repo-managed skill must include its own `evals/evals.json` file at `skills/<name>/evals/evals.json`.

- Treat this as a required artifact for every first-party skill in this repo
- Eval entries may include an optional `files` array of skill-relative fixture paths such as `evals/files/example.md`
- When `files` is present, keep the paths relative to `skills/<name>/` and stage those fixtures into the temp eval workspace for both `with_skill` and `without_skill` runs
- Run evals **per skill**, not as one shared repo-level eval file
- Run evals from a temp workspace such as `$env:TEMP/<skill-name>-workspace/`, never from inside this repository
- When creating or modifying a repo-managed skill, run the full per-skill test from that temp workspace before the work is considered complete. Full test means both `with_skill` and `without_skill` comparison executions, grading both runs, aggregating `benchmark.json`, and opening the review viewer. A reasoning-only smoke test does not count as full test.
- For a brand-new skill, the baseline is `without_skill`; for an existing skill, use either `without_skill` or the previous/original skill version as the baseline, matching the `skill-creator` benchmark flow
- Generate the human-review artifacts too: aggregate the comparison into `benchmark.json` and launch `eval-viewer/generate_review.py` from the installed Anthropic `skill-creator` copy (typically under `~/.agents/skills/skill-creator/` or `~/.claude/skills/skill-creator/`) so the user can inspect `Outputs` and `Benchmark` before sign-off
- Deterministic scaffold/template skills must keep local deterministic validators as well; evals supplement validators, they do not replace them

If you add a new skill or modify an existing repo-managed skill, update that skill's `evals/evals.json` before considering the work complete. Do not commit temp workspaces, benchmark outputs, or generated review files into this repository unless the user explicitly asks for checked-in artifacts.

## Git Identity

Never set or override `git user.name`, `git user.email`, or `alias.bot` in the **local** git config of this repository. Always use the global config. Local overrides silently shadow global settings and produce commits with the wrong author.

## Skill Creation

Always use the `skill-creator` skill (by Anthropic) when creating new skills, modifying existing skills, or running evals. It enforces best practices for structure, description quality, testing, and progressive disclosure. Do not create or edit skills manually without invoking it first.

## Third-Party Skills

Never modify skills maintained by others (e.g. `skill-creator` by Anthropic). If a third-party skill needs repo-specific behavior, add the rule here in `AGENTS.md` — not in the skill file itself. Upstream updates will overwrite local edits without warning.

## Local Install Sync

Repo-managed skills live in four places that must stay in sync:

- `skills/<name>/` — source control (and source of truth for edits)
- `~/.claude/skills/<name>/` — local Claude install
- `~/.agents/skills/<name>/` — local global agent install
- `~/.gemini/antigravity/skills/<name>/` — local Gemini Antigravity install

Changes often start in `~/.claude/skills/<name>/`, then get mirrored to the repo and the global install:

- **Claude local → repo** (persist changes to source control):
  ```powershell
  Copy-Item "$HOME/.claude/skills/<name>/<file>" "skills/<name>/<file>" -Force
  ```
- **Claude local → global agent install** (keep `~/.agents` current):
  ```powershell
  Copy-Item "$HOME/.claude/skills/<name>/<file>" "$HOME/.agents/skills/<name>/<file>" -Force
  ```
- **Repo → both local installs** (after pulling changes or cloning fresh):
  ```powershell
  Copy-Item "skills/<name>/<file>" "$HOME/.claude/skills/<name>/<file>" -Force
  Copy-Item "skills/<name>/<file>" "$HOME/.agents/skills/<name>/<file>" -Force
  Copy-Item "skills/<name>/<file>" "$HOME/.gemini/antigravity/skills/<name>/<file>" -Force
  ```

If you edit the `~/.agents/skills/<name>/` copy first, mirror it back to the repo and to `~/.claude/skills/<name>/` and `~/.gemini/antigravity/skills/<name>/` using the same pattern.

When renaming a skill, update **all four** locations — the repo folder, the local Claude install folder, the local global agent install folder, and the local Gemini Antigravity install folder. The folder name and the `name:` field in the SKILL.md frontmatter must match. A mismatch causes the skill to disappear from tooling or show stale instructions.

A sync mismatch means one side runs a stale version, which leads to confusing eval results and wasted iterations.

After changing any repo-managed skill, sync the touched files across the repo copy, `~/.claude/skills/<name>/`, `~/.agents/skills/<name>/`, and `~/.gemini/antigravity/skills/<name>/` before considering the task done.

## Skill Directory Structure

Every skill follows this layout:

```
skills/<name>/
├── SKILL.md              # Required — the skill definition (loaded by Claude)
├── FORMS.md              # Optional — structured form fields for parameter collection
├── assets/               # Optional — file templates, fonts, icons used in output
│   └── <variant>/        # Group by variant when a skill supports multiple (e.g. library/, app/)
├── scripts/              # Optional — executable code (Python, Bash, etc.)
├── references/           # Optional — detailed reference docs the agent consults during generation
└── evals/                # Required for repo-managed skills — per-skill eval prompts and expectations
    └── files/            # Optional — input fixtures referenced by evals/evals.json files[]
```

- `SKILL.md` is the entry point — it contains the workflow, conventions, and step-by-step instructions
- `assets/` holds file templates, fonts, icons, and other static content used in output (the agent reads and substitutes placeholders)
- `references/` holds detailed specs that `SKILL.md` references but are too long to inline
- `evals/` holds the per-skill `evals.json` definitions used to verify that the skill still works after changes
- `evals/files/` holds optional skill-local fixture inputs referenced by `evals/evals.json` when a benchmark needs attached source material

## Template Files Are Literal

Asset files in `assets/` are **not** processed by a templating engine. They contain real file content with placeholder values (e.g. `{ProjectName}`, `{TargetFramework}`) that the agent must read, understand, and substitute during generation. Agents should never copy asset files blindly — always read the content and adapt it to the user's specific parameters.

## Prefer Dynamic Defaults

When a skill needs time-sensitive or environment-sensitive values, prefer computing them from a reliable source instead of hardcoding them into prompts, defaults, or examples.

- Prefer repo state, git metadata, official APIs, or vendor-maintained machine-readable feeds over date-stamped literals
- Use hardcoded fallback examples only when a dynamic source is unavailable or would add unreasonable complexity
- When a dynamic default exists, describe both the source and the fallback behavior in `FORMS.md` / `SKILL.md`
- If a value changes over time (supported frameworks, current versions, generated paths, repo-derived names), assume hardcoding will drift and design for refreshable computation

## Scaffold Invariants

For repo-managed .NET scaffolding skills, preserve semantic versioning infrastructure unless you are replacing it end-to-end in the same change.

- App and library scaffolds rely on `MinVer` for versioning from git tags
- Do not remove `MinVer`, its package version, or its MSBuild hooks from scaffold templates unless a complete replacement workflow is implemented and validated in the same change
- Preserve the user-facing solution/product name in `PascalCase` for generated solution filenames such as `.slnx`; do not silently lowercase the solution filename
- Only derive lowercase values for fields that explicitly require them, such as repo slugs, package feeds, or Docker/image-style identifiers

## Commit Discipline

When committing changes to this repo, group by technology and logical purpose — don't mix unrelated changes. For example:

- Skill instruction changes (`SKILL.md`) get their own commit
- Template files (`.csproj`, `.yml`, `.cs`) get their own commit(s)
- Documentation updates (`README.md`, `CONTRIBUTING.md`) get their own commit

## README Sync

After modifying any skill (`SKILL.md`, `FORMS.md`) or repo-level config (`AGENTS.md`), **always update `README.md` before considering the task done**. This is a mandatory gate — not a nice-to-have. The README's "Available Skills" table, install examples, and "Why" sections must reflect the current state of all skills. A new skill without a README entry is incomplete work.

## User Input UX

When a skill collects parameters from the user, define the form in a dedicated `FORMS.md` file (Level 3 resource) rather than inlining field definitions in `SKILL.md`. This separates form structure from workflow logic and gives agents a parseable format to present fields correctly.

Native input widgets are a **host/runtime feature**, not a guaranteed model capability. Treat them as an enhancement, not a dependency.

- Skills must remain fully usable whether the host renders native fields or not
- When native fields are unavailable, the agent must follow a deterministic plain-text fallback defined in `FORMS.md` instead of improvising the interaction
- The fallback path must preserve the same field order, defaults, recommended choices, and final confirmation flow as the native-field path
- Do not switch interaction styles mid-collection unless the host explicitly upgrades from plain text to native controls
- Favor consistency and low-friction UX over conversational variety during parameter collection

`FORMS.md` defines each field with:
- **type** — `text`, `single-choice`, or `multi-choice`
- **prompt** — the question to ask
- **choices** — options for choice types
- **default** — pre-filled value (mark as Recommended)
- **required** — whether the field is mandatory

Presentation rules (enforced in every `FORMS.md`):
- Ask one field at a time — never bundle multiple questions
- Use selectable choices for `single-choice` and `multi-choice` fields — not free text
- When a default exists, present it first and append "(Recommended)"
- For `text` fields with a computed default, offer the computed value as a selectable choice alongside free text
- After all fields are collected, present a summary and ask for confirmation

This applies to all skills that collect user input, not just scaffolding skills.

## Anthropic Skill Authoring Reference

Essential conventions from [The Complete Guide to Building Skills for Claude](https://resources.anthropic.com/hubfs/The-Complete-Guide-to-Building-Skill-for-Claude.pdf) (Anthropic, Jan 2026). All skills in this repo must follow these rules.

### File Structure

```
skill-name/
├── SKILL.md              # Required — exact spelling, case-sensitive
├── scripts/              # Optional — executable code (Python, Bash, etc.)
├── references/           # Optional — documentation loaded as needed
└── assets/               # Optional — templates, fonts, icons used in output
```

- **No `README.md`** inside the skill folder — all documentation goes in `SKILL.md` or `references/`
- Folder name must be **kebab-case** (no spaces, no underscores, no capitals)
- Folder name must match the `name:` field in YAML frontmatter

### Progressive Disclosure (Three Levels)

| Level | When loaded | Token cost | Content |
|-------|------------|------------|---------|
| **Level 1: Metadata** | Always (at startup) | ~100 tokens | `name` and `description` from YAML frontmatter |
| **Level 2: Instructions** | When skill is triggered | Under 5k tokens | SKILL.md body — workflows, steps, guidance |
| **Level 3: Resources** | As needed | Effectively unlimited | Linked files: scripts, references, assets, FORMS.md |

Keep SKILL.md under **500 lines / 5,000 words**. Move detailed content to `references/`. Keep references **one level deep** from SKILL.md — nested references cause partial reads.

### YAML Frontmatter

Required fields:

```yaml
---
name: kebab-case-name      # max 64 chars, lowercase + numbers + hyphens only
description: >              # max 1024 chars, must include WHAT + WHEN + triggers
  What it does. Use when user asks to [specific phrases].
---
```

Optional fields:

```yaml
license: MIT                # for open-source skills
compatibility: >            # max 500 chars — environment requirements
  Requires network access and Python 3.10+
metadata:                   # custom key-value pairs
  author: Company Name
  version: 1.0.0
  mcp-server: server-name
```

**Forbidden**: XML angle brackets (`< >`), names containing "claude" or "anthropic" (reserved).

### Description Field — The Most Important Part

Structure: `[What it does] + [When to use it] + [Key capabilities]`

```yaml
# ✅ Good — specific, actionable, includes triggers
description: >
  Manages Linear project workflows including sprint planning,
  task creation, and status tracking. Use when user mentions
  "sprint", "Linear tasks", "project planning", or asks to
  "create tickets".

# ❌ Bad — too vague, no triggers
description: Helps with projects.
```

- Include trigger phrases users would actually say
- Mention file types if relevant
- Add negative triggers to prevent over-triggering: `Do NOT use for simple data exploration`

### Writing Instructions

- Be **specific and actionable** — `Run scripts/validate.py --input {filename}` not `Validate the data`
- Include **error handling** — common errors, causes, and solutions
- Use **feedback loops** — run validator → fix errors → repeat
- Put **critical instructions at the top** — use `## Critical` or `## Important` headers
- For critical validations, **use scripts over language instructions** — code is deterministic
- Prefer **dynamic defaults over hardcoded values** when the source data is available from the repo, environment, or an official machine-readable feed

### Skill Categories

| Category | Purpose | Example |
|----------|---------|---------|
| **Document & Asset Creation** | Consistent, high-quality output (docs, code, designs) | `frontend-design`, `docx`, `xlsx` |
| **Workflow Automation** | Multi-step processes with validation gates | `skill-creator`, scaffolding skills |
| **MCP Enhancement** | Workflow guidance layered on top of MCP tool access | `sentry-code-review` |

### Common Patterns

1. **Sequential workflow** — explicit step ordering with dependencies and rollback
2. **Multi-MCP coordination** — phase separation, data passing between services
3. **Iterative refinement** — draft → validate → fix → repeat until quality threshold
4. **Context-aware selection** — decision trees for choosing the right tool/approach
5. **Domain-specific intelligence** — compliance checks, governance, audit trails

### Testing Checklist

Before shipping a skill, verify:

- [ ] Triggers on obvious tasks
- [ ] Triggers on paraphrased requests
- [ ] Does **not** trigger on unrelated topics
- [ ] Functional tests pass (correct outputs, error handling, edge cases)
- [ ] Performance improves over baseline (fewer messages, fewer errors, fewer tokens)

Debug triggering: ask Claude `"When would you use the [skill name] skill?"` — it will quote the description back.

### Troubleshooting Quick Reference

| Symptom | Likely cause | Fix |
|---------|-------------|-----|
| Skill won't upload | `SKILL.md` misspelled or YAML invalid | Exact case `SKILL.md`, check `---` delimiters |
| Skill never triggers | Description too vague | Add trigger phrases, mention file types |
| Skill triggers too often | Description too broad | Add negative triggers, narrow scope |
| Instructions not followed | Too verbose or ambiguous | Shorten, use bullets, move detail to `references/` |
| Slow / degraded responses | Too much content loaded | Keep SKILL.md under 5k words, use progressive disclosure |

## Karpathy Rules

Behavioral guidelines to reduce common LLM coding mistakes. Merge with project-specific instructions as needed.

### 1. Think Before Coding

**Don't assume. Don't hide confusion. Surface tradeoffs.**

Before implementing:
- State your assumptions explicitly. If uncertain, ask.
- If multiple interpretations exist, present them - don't pick silently.
- If a simpler approach exists, say so. Push back when warranted.
- If something is unclear, stop. Name what's confusing. Ask.
- When the root cause is uncertain, do not present hypotheses as facts. State the uncertainty explicitly and ask whether to investigate before applying a fix.

### 2. Simplicity First

**Minimum code that solves the problem. Nothing speculative.**

- No features beyond what was asked.
- No abstractions for single-use code.
- No "flexibility" or "configurability" that wasn't requested.
- No error handling for impossible scenarios.
- If you write 200 lines and it could be 50, rewrite it.

Ask yourself: "Would a senior engineer say this is overcomplicated?" If yes, simplify.

### 3. Surgical Changes

**Touch only what you must. Clean up only your own mess.**

When editing existing code:
- Don't "improve" adjacent code, comments, or formatting.
- Don't refactor things that aren't broken.
- Match existing style, even if you'd do it differently.
- If you notice unrelated dead code, mention it - don't delete it.

When your changes create orphans:
- Remove imports/variables/functions that YOUR changes made unused.
- Don't remove pre-existing dead code unless asked.

The test: Every changed line should trace directly to the user's request.

### 4. Goal-Driven Execution

**Define success criteria. Loop until verified.**

Transform tasks into verifiable goals:
- "Add validation" → "Write tests for invalid inputs, then make them pass"
- "Fix the bug" → "Write a test that reproduces it, then make it pass"
- "Refactor X" → "Ensure tests pass before and after"

For multi-step tasks, state a brief plan:
```
1. [Step] → verify: [check]
2. [Step] → verify: [check]
3. [Step] → verify: [check]
```

Strong success criteria let you loop independently. Weak criteria ("make it work") require constant clarification.
