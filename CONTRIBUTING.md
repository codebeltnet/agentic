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
      "expected_output": "What a correct response looks like — used for manual or automated grading",
      "files": ["evals/files/example.md"]
    }
  ]
}
```

`files` is optional. When present, list one or more fixture files relative to `skills/<name>/`. A common pattern is to store those fixtures under `evals/files/` so the eval package can attach the same source inputs to both the `with_skill` and `without_skill` prompt.

Aim for 3–5 evals that cover distinct scenarios: happy path, edge cases, and cases where the skill should *not* do something.

Evals are prepared, not executed, from this repository. Adding or modifying a repo-managed skill requires preparing the packages for every skill the branch touched, which is a completion gate rather than an optional extra:

```console
pwsh -NoProfile -File ./scripts/prepare-skill-evals.ps1 -Changed
```

Run it after the last skill edit and before `scripts/sync-skill-install.ps1`, which stays last. For a single skill on demand, use:

```console
pwsh -NoProfile -File ./scripts/prepare-skill-evals.ps1 -Skill <skill-name>
```

The script writes `.bot/<skill-name>-workspace/iteration-<n>/` with one directory per eval. Each holds the grading key `eval-metadata.json` and result stubs under `results/` at the eval-case level, plus two hermetic run directories, `with_skill/` and `without_skill/`. A run directory is the worker's sandbox root: `prompt.md`, a `run.json` contract, a `repo/` working tree materialized from the fixtures, an isolated `home/`, and - for `with_skill` only - a `skill/<name>/` copy of the candidate. The grading key and results sit outside both run directories. At the root it writes `manifest.json`, `execution-profile.json`, the package-local Eval Runner protocol, the package report adapter, the exact Anthropic skill-creator grader/aggregator/viewer assets, and `RUN-THIS.prompt.md`, the one prompt you hand to the external Eval Orchestrator. That orchestrator resolves and preflights the selected runner, invokes its common `describe`/`preflight`/`execute` surface once per fresh blind arm, stores raw `execution-result.json`, bridges the results, grades only after execution, and runs the adapter, which invokes `aggregate_benchmark.py` and `eval-viewer/generate_review.py --static`. It never runs an eval prompt in the coordinator context and never reuses a worker. Both worker prompts carry the same task, materialized repository, and response contract; only the operating instructions and the presence of `skill/` differ, and neither prompt identifies itself as an eval. `.gitignore` covers `.bot/*`, so nothing there reaches git. The script refuses an `-OutputRoot` inside the repository but outside `.bot/`; pass an explicit temp path when the harness does not need repository-local storage.

Repository preparation, validation, CI, hooks, deterministic tests, and automatic completion gates never run those prompts or invoke a model. That boundary is the Priority 1 rule in `AGENTS.md`, and preparing a prompt is not permission to execute one. A human-selected external Eval Orchestrator handed a specific package may invoke the selected package-local Eval Runner; this explicit handoff boundary does not weaken the repository prohibition or authorize CI/live evals.

Run both configurations on the same model, same version, and same configuration. A with-skill run on one model against a baseline on another measures the model as much as the skill and is not a skill-effectiveness result.

Record each external runner result in the matching `execution-result.json` first. It must carry the protocol/schema, opaque run and fresh session ids, status, complete final response or explicit unavailability, runner/harness identity, requested and resolved execution selection, timestamps and duration, exit/failure state, prompt/run/profile hashes, resolved isolation mechanisms, warnings, and artifact references. Include token, cache, cost, tool, command, file, and transcript evidence only when the harness exposes it; unavailable values remain explicitly unavailable and are never estimated. The deterministic bridge then writes the existing `results/*.result.json` shape, after which grading may add `grading[].passed` and evidence. Assertions about tool, shell, or file behavior are only gradeable from a run that captured that evidence. If the results were transferred without those report artifacts, validate and compare with:

```console
pwsh -NoProfile -File ./scripts/prepare-skill-evals.ps1 -CollectResults <iteration-path>
```

That writes `comparison.md`, the first-party side-by-side `report.html`, the exact upstream `skill-creator-report.html`, and the upstream `benchmark.json`/`benchmark.md`, while flagging missing arms, unrun configurations, and mixed models. The normal external Eval Orchestrator grades in the same handoff using deterministic checks for mechanical assertions and evidence-backed judgement where an assertion is genuinely qualitative. Repository automation remains deterministic and never invokes a model. Initial real runners are Codex and OpenCode; the deterministic fake runner is the CI conformance harness. Native skill activation, portability scoring, and additional runners are not part of v0.9.1.

The eval package is a temp artifact. Do not commit it, its prompts, or its results unless the change explicitly calls for checked-in examples.

For scaffold/template skills, keep deterministic validators alongside evals. In this repo, `evals/evals.json` is mandatory, and validators like `scripts/validate-skill-templates.ps1` are additional protection.

## Prefer dynamic defaults

When a skill needs defaults for versions, paths, repository names, or support windows, prefer deriving them from a reliable source instead of baking in values that will drift.

- Good sources: git metadata, repo folder names, environment values, official JSON feeds, vendor docs APIs
- Use hardcoded examples as examples only — not as the real defaulting mechanism — when the value can be computed

## Template validation

Use the repo validation harness before submitting scaffold or template changes:

```console
pwsh -NoProfile -File ./scripts/validate-skill-templates.ps1
```

Run the validator locally first for the fastest feedback loop. GitHub Actions also runs the same script on pull requests, but CI is the backstop, not the primary authoring loop.

To compare a change against the initial imported version, run the same harness against a git ref:

```console
pwsh -NoProfile -File ./scripts/validate-skill-templates.ps1 -Ref HEAD
```

## Checklist before submitting

- [ ] `SKILL.md` has valid front matter with `name` and `description`
- [ ] Skill is stack-agnostic (or clearly scoped to a specific tech in the name/description)
- [ ] Examples are generic — no personal emails, usernames, or project-specific identifiers
- [ ] At least one eval in `evals/evals.json`
- [ ] The skill's `evals/evals.json` exists and its `skill_name` matches the folder/frontmatter name
- [ ] Any optional `files` entries in `evals/evals.json` point to real fixture files under the same skill folder
- [ ] `pwsh -NoProfile -File ./scripts/prepare-skill-evals.ps1 -Changed` was run after the last skill edit, and the prepared prompt paths were reported
- [ ] If an external evaluation was run, each result includes the producing model and the package contains the first-party `report.html`, exact upstream `skill-creator-report.html`, `benchmark.json`, and `benchmark.md`; use `-CollectResults` only when transferred results need the repository-side fallback
- [ ] `scripts/validate-skill-templates.ps1` passes for the current working tree when changing scaffold or template behavior
- [ ] If CI is enabled for the branch, the GitHub Actions validation job passes too
- [ ] Eval packages live in `.bot/<skill-name>-workspace/` or a temp path, never anywhere else in the working tree
- [ ] Changed skill files are synced across `skills/<name>/`, `~/.claude/skills/<name>/`, and `~/.agents/skills/<name>/`
- [ ] Skill added to the table in `README.md`
