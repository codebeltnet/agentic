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
pwsh -NoProfile -NonInteractive -File ./scripts/prepare-skill-evals.ps1 -Changed -Runner github-copilot
```

Run it after the last skill edit and before `scripts/sync-skill-install.ps1`, which stays last. For a single skill on demand, use:

```console
pwsh -NoProfile -NonInteractive -File ./scripts/prepare-skill-evals.ps1 -Skill <skill-name> -Runner <runner-id> -Model <runner-native-model>
```

Before running the script, choose a Harness + Model when the user did not already do so. Normalize explicit harness wording immediately: `Codex` maps to `codex`; `GitHub Copilot`, `GitHub Copilot CLI`, and `Copilot` map to `github-copilot`; `OpenCode` maps to `opencode`; matching is case-insensitive. Use `scripts/Get-HarnessModels.ps1 -Runner <runner-id>` to list current selectors; it fails immediately with the supported runner IDs when `-Runner` is omitted. OpenCode mirrors every model exposed by all configured providers, with availability retained as metadata only, while GitHub Copilot and Codex list all currently available models. When OpenCode is selected without an explicit model, present the discovered exact `provider/model` selectors, ask the user to choose one, and wait; never select the first, free, recommended, previous-iteration, previous-successful, or previous-failed model automatically. Preserve an explicitly supplied OpenCode selector verbatim in `execution-profile.json`; discovery failure or incomplete metadata must not substitute another model. The Codebelt Reference shortcut is GitHub Copilot CLI + `claude-haiku-4.5`, and Codex defaults to `gpt-5.6-luna` with low reasoning; package preparation validates the resolved model against current discovery before writing `execution-profile.json`. The script writes `.bot/<skill-name>-workspace/iteration-<n>/` with one directory per eval. Each holds the grading key `eval-metadata.json` and result stubs under `results/` at the eval-case level, plus two paired run directories, `with_skill/` and `without_skill/`. A run directory is the worker's run root: `prompt.md`, a `run.json` contract, a `repo/` working tree materialized from the fixtures, an isolated `home/`, and - for `with_skill` only - a `skill/<name>/` copy of the candidate. The grading key and results sit outside both run directories. At the root it writes `manifest.json`, `execution-profile.json`, the package-local Eval Runner protocol, the package report adapter, the exact Anthropic skill-creator grader/aggregator/viewer assets, and `RUN-THIS.prompt.md`, the one prompt you hand to the external Eval Orchestrator. That orchestrator resolves and preflights the selected runner, reads `delegation.dispatch_owner`, and either dispatches the declared orchestrator-owned native worker or starts the declared runner-owned one-arm native surface directly. It stores genuine transport-produced `execution-result.json` evidence, bridges the results, grades only after execution, and runs the adapter, which invokes `aggregate_benchmark.py` and `eval-viewer/generate_review.py --static`. It never runs an eval prompt in the coordinator context, never chooses runner/model policy, and never reuses a worker. Both worker prompts carry the same task, materialized repository, and response contract; only the operating instructions and the presence of `skill/` differ, and neither prompt identifies itself as an eval. `.gitignore` covers `.bot/*`, so nothing there reaches git. The script refuses an `-OutputRoot` inside the repository but outside `.bot/`; pass an explicit temp path when the harness does not need repository-local storage.

Repository preparation, validation, CI, hooks, deterministic tests, and automatic completion gates never run those prompts or invoke a model. That boundary is the Priority 1 rule in `AGENTS.md`, and preparing a prompt is not permission to execute one. A human-selected external Eval Orchestrator handed a specific package may invoke the selected package-local Eval Runner; this explicit handoff boundary does not weaken the repository prohibition or authorize CI/live evals.

Run both configurations on the same model, same version, and same configuration. Independent arms must be dispatched concurrently up to `execution-profile.json.concurrency` when the harness permits it. For any selected runner whose descriptor says `delegation.dispatch_owner=runner`, invoke `invoke-runner-owned-arms.ps1` exactly once as a foreground Phase 1 command with the caller shell/tool timeout set to at least the package-computed allowance. The foreground helper performs every preflight before execution, owns fan-out, state, result registration, and freeze creation, and starts zero model executions when any preflight is incompatible. Never create outer native subagents/tasks for runner-owned arms or hand-author preflight, fan-out, state, or result bookkeeping. Copilot task/general-purpose workers, OpenCode Task/General workers, and Codex native mechanisms remain harness capabilities only; they are not the behavioral transport for runner-owned evaluation. A with-skill run on one model against a baseline on another measures the model as much as the skill and is not a skill-effectiveness result.

For an orchestrator-owned worker, preserve its `codebeltnet/agentic/eval-native-worker-result/1` terminal envelope and pass it to `record-native-result.ps1` with the exact `run.json`, `execution-profile.json`, and manifest-declared output path. For a runner-owned worker, preserve the runner-produced `execution-result.json` directly at the exact manifest-declared path and do not invoke the recorder or synthesize an envelope. In either mode, the generated result must carry the protocol/schema, opaque run and fresh session ids, status, complete final response or explicit unavailability, runner/harness identity, requested and resolved model selection, timestamps and duration, exit/failure state, prompt/run/profile hashes, resolved isolation mechanisms, warnings, and artifact references. Include token, cache, cost, tool, command, file, and transcript evidence only when the harness exposes it; unavailable values remain explicitly unavailable and are never estimated. The deterministic bridge then writes the existing `results/*.result.json` shape, after which grading may add `grading[].passed` and evidence. Assertions about tool, shell, or file behavior are only gradeable from a run that captured that evidence. If the selected external process cannot write valid runner-produced execution results back into the package, the evaluation is incomplete and must fail closed; no response-only or reconstructed result is accepted.

An explicitly authorized forensic recovery of an old or broken package may validate an existing iteration with:

```console
pwsh -NoProfile -NonInteractive -File ./scripts/prepare-skill-evals.ps1 -CollectResults <iteration-path>
```

It may write a diagnostic `comparison.md` while flagging missing arms, unrun configurations, incompatible evidence, and mixed models, but it exits non-zero and does not write benchmark/report artifacts until the required completion gate is satisfied. Those diagnostic artifacts must not present an incomplete or unrun package as a successfully completed evaluation. The normal external Eval Orchestrator grades in the same handoff using deterministic checks for mechanical assertions and evidence-backed judgement where an assertion is genuinely qualitative. Repository automation remains deterministic and never invokes a model. Codex, OpenCode, and GitHub Copilot are the conforming real runners; the deterministic fake runner is the CI conformance harness. Runners grant full operational permission inside each isolated behavioral harness configuration, while hard filesystem confinement is reported as strict versus pragmatic confidence only when an existing outer platform mechanism proves it. Native skill activation, portability scoring, and additional runners are not part of v0.9.1.

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
- [ ] `pwsh -NoProfile -NonInteractive -File ./scripts/prepare-skill-evals.ps1 -Changed -Runner <runner-id> -Model <runner-native-model>` or `-CodebeltReference` was run after the last skill edit, and the prepared prompt paths were reported
- [ ] If an external evaluation was run, each result includes the producing model and the package contains the first-party `report.html`, exact upstream `skill-creator-report.html`, `benchmark.json`, and `benchmark.md`; use `-CollectResults` only for explicitly authorized forensic recovery of an existing package
- [ ] `scripts/validate-skill-templates.ps1` passes for the current working tree when changing scaffold or template behavior
- [ ] If CI is enabled for the branch, the GitHub Actions validation job passes too
- [ ] Eval packages live in `.bot/<skill-name>-workspace/` or a temp path, never anywhere else in the working tree
- [ ] Changed skill files are synced across `skills/<name>/`, `~/.claude/skills/<name>/`, and `~/.agents/skills/<name>/`
- [ ] Skill added to the table in `README.md`
