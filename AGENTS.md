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

Skills are developed in `skills/<name>/` but Claude loads them from `~/.claude/skills/<name>/`. These two locations must stay in sync — changes can originate from either side:

- **Repo → local** (after editing in the repo during development):
  ```powershell
  Copy-Item "skills/<name>/<file>" "$HOME/.claude/skills/<name>/<file>" -Force
  ```
- **Local → repo** (after tweaking a skill during a session):
  ```powershell
  Copy-Item "$HOME/.claude/skills/<name>/<file>" "skills/<name>/<file>" -Force
  ```

When renaming a skill, update **both** locations — the repo folder and the local install folder under `~/.claude/skills/`. The folder name and the `name:` field in the SKILL.md frontmatter must match. A mismatch causes the skill to not appear in IDE tooling.

A sync mismatch means one side runs a stale version, which leads to confusing eval results and wasted iterations.

## Skill Directory Structure

Every skill follows this layout:

```
skills/<name>/
├── SKILL.md              # Required — the skill definition (loaded by Claude)
├── templates/            # Optional — literal file templates the agent generates from
│   └── <variant>/        # Group by variant when a skill supports multiple (e.g. library/, app/)
└── references/           # Optional — detailed reference docs the agent consults during generation
```

- `SKILL.md` is the entry point — it contains the workflow, conventions, and step-by-step instructions
- `templates/` holds actual file content with placeholders (not a templating engine — the agent reads and substitutes)
- `references/` holds detailed specs that `SKILL.md` references but are too long to inline

## Template Files Are Literal

Template files in `templates/` are **not** processed by a templating engine. They contain real file content with placeholder values (e.g. `{ProjectName}`, `{TargetFramework}`) that the agent must read, understand, and substitute during generation. Agents should never copy template files blindly — always read the content and adapt it to the user's specific parameters.

## Commit Discipline

When committing changes to this repo, group by technology and logical purpose — don't mix unrelated changes. For example:

- Skill instruction changes (`SKILL.md`) get their own commit
- Template files (`.csproj`, `.yml`, `.cs`) get their own commit(s)
- Documentation updates (`README.md`, `CONTRIBUTING.md`) get their own commit

