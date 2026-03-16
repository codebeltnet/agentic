# Contributing

Thanks for wanting to add or improve a skill. Here's what to know.

## Skill structure

Each skill lives in its own folder:

```
skills/
  <skill-name>/
    SKILL.md          # Required — the skill content
    FORMS.md          # Optional — structured input collection for agents
    assets/           # Optional — literal templates and static files
    scripts/          # Optional — executable helpers
    references/       # Optional — deeper docs loaded on demand
    evals/            # Required for repo-managed skills — test prompts for validation
      evals.json
```

## Local sync

Repo-managed skills should be mirrored across all three locations:

- `skills/<name>/` in this repo
- `~/.claude/skills/<name>/`
- `~/.agents/skills/<name>/`

If you edit a local install copy first, copy the changed files back into the repo and into the other local install so every agent sees the same skill version.

## SKILL.md format

Every `SKILL.md` must start with a YAML front matter block:

```yaml
---
name: your-skill-name
description: >
  One or two sentences describing what this skill does and when the AI
  should automatically invoke it. Be specific about trigger phrases and
  use cases — this description is what the AI reads to decide whether
  to load the skill.
---
```

The rest of the file is free-form Markdown. Include:

- **When to use** — what scenarios or requests trigger this skill
- **Rules / conventions** — the core content the AI should follow
- **Examples** — good and bad, so the AI can calibrate
- **Prerequisites** — anything the human needs to set up first (tools, config, etc.)

## Naming

- Skill folder and `name` field: `kebab-case`
- Be specific — `git-bot-commits` is better than `git` or `commits`
- Avoid version numbers in names; use the description to note maturity

## Writing good descriptions (the front matter field)

The `description` is the most important field — it's how the AI decides to load the skill. Include:

- What the skill enables
- Specific trigger phrases (e.g. "Use when user says 'commit this' or 'stage changes'")
- What it enforces or prevents

## Adding evals (required for repo-managed skills)

Evals let you verify the skill works and measure improvement over a baseline. Every repo-managed skill in this repository must include `evals/evals.json`:

```json
{
  "skill_name": "your-skill-name",
  "evals": [
    {
      "id": 0,
      "prompt": "The user message to test against",
      "expected_output": "What a correct response looks like — used for manual or automated grading"
    }
  ]
}
```

Aim for 3–5 evals that cover distinct scenarios: happy path, edge cases, and cases where the skill should *not* do something.

Run evals from a temp workspace, not from this repository:

```powershell
$workspace = Join-Path $env:TEMP '<skill-name>-workspace'
```

For scaffold/template skills, keep deterministic validators alongside evals. In this repo, `evals/evals.json` is mandatory, and validators like `scripts/validate-skill-templates.ps1` are additional protection.

## Prefer dynamic defaults

When a skill needs defaults for versions, paths, repository names, or support windows, prefer deriving them from a reliable source instead of baking in values that will drift.

- Good sources: git metadata, repo folder names, environment values, official JSON feeds, vendor docs APIs
- Use hardcoded examples as examples only — not as the real defaulting mechanism — when the value can be computed

## Template validation

Use the repo validation harness before submitting scaffold or template changes:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\validate-skill-templates.ps1
```

To compare a change against the initial imported version, run the same harness against a git ref:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\validate-skill-templates.ps1 -Ref HEAD
```

## Checklist before submitting

- [ ] `SKILL.md` has valid front matter with `name` and `description`
- [ ] Skill is stack-agnostic (or clearly scoped to a specific tech in the name/description)
- [ ] Examples are generic — no personal emails, usernames, or project-specific identifiers
- [ ] At least one eval in `evals/evals.json`
- [ ] The skill's `evals/evals.json` exists and its `skill_name` matches the folder/frontmatter name
- [ ] `scripts/validate-skill-templates.ps1` passes for the current working tree when changing scaffold or template behavior
- [ ] Skill evals are intended to run from `$env:TEMP/<skill-name>-workspace/`, not from inside the repo
- [ ] Changed skill files are synced across `skills/<name>/`, `~/.claude/skills/<name>/`, and `~/.agents/skills/<name>/`
- [ ] Skill added to the table in `README.md`
