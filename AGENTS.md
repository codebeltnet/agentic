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

## Git Identity

Never set or override `git user.name`, `git user.email`, or `alias.bot` in the **local** git config of this repository. Always use the global config. Local overrides silently shadow global settings and produce commits with the wrong author.

## Third-Party Skills

Never modify skills maintained by others (e.g. `skill-creator` by Anthropic). If a third-party skill needs repo-specific behavior, add the rule here in `AGENTS.md` — not in the skill file itself. Upstream updates will overwrite local edits without warning.

## Local Install Sync

Skills are developed in `~/.claude/skills/<name>/` (where agents load them) and persisted in `skills/<name>/` (source control). These two locations must stay in sync — changes typically start local and get copied to the repo:

- **Local → repo** (primary flow — persist changes to source control):
  ```powershell
  Copy-Item "$HOME/.claude/skills/<name>/<file>" "skills/<name>/<file>" -Force
  ```
- **Repo → local** (after pulling changes or cloning fresh):
  ```powershell
  Copy-Item "skills/<name>/<file>" "$HOME/.claude/skills/<name>/<file>" -Force
  ```

When renaming a skill, update **both** locations — the repo folder and the local install folder under `~/.claude/skills/`. The folder name and the `name:` field in the SKILL.md frontmatter must match. A mismatch causes the skill to not appear in IDE tooling.

A sync mismatch means one side runs a stale version, which leads to confusing eval results and wasted iterations.

## Skill Directory Structure

Every skill follows this layout:

```
skills/<name>/
├── SKILL.md              # Required — the skill definition (loaded by Claude)
├── FORMS.md              # Optional — structured form fields for parameter collection
├── assets/               # Optional — file templates, fonts, icons used in output
│   └── <variant>/        # Group by variant when a skill supports multiple (e.g. library/, app/)
├── scripts/              # Optional — executable code (Python, Bash, etc.)
└── references/           # Optional — detailed reference docs the agent consults during generation
```

- `SKILL.md` is the entry point — it contains the workflow, conventions, and step-by-step instructions
- `assets/` holds file templates, fonts, icons, and other static content used in output (the agent reads and substitutes placeholders)
- `references/` holds detailed specs that `SKILL.md` references but are too long to inline

## Template Files Are Literal

Asset files in `assets/` are **not** processed by a templating engine. They contain real file content with placeholder values (e.g. `{ProjectName}`, `{TargetFramework}`) that the agent must read, understand, and substitute during generation. Agents should never copy asset files blindly — always read the content and adapt it to the user's specific parameters.

## Commit Discipline

When committing changes to this repo, group by technology and logical purpose — don't mix unrelated changes. For example:

- Skill instruction changes (`SKILL.md`) get their own commit
- Template files (`.csproj`, `.yml`, `.cs`) get their own commit(s)
- Documentation updates (`README.md`, `CONTRIBUTING.md`) get their own commit

## README Sync

After modifying any skill (`SKILL.md`, `FORMS.md`) or repo-level config (`AGENTS.md`), **always check if `README.md` needs updating**. The README's "Available Skills" table and feature bullet lists describe each skill's capabilities — if those capabilities changed, the README must reflect it. Treat this as a mandatory post-change step, not an afterthought.

## User Input UX

When a skill collects parameters from the user, define the form in a dedicated `FORMS.md` file (Level 3 resource) rather than inlining field definitions in `SKILL.md`. This separates form structure from workflow logic and gives agents a parseable format to present fields correctly.

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

