# Agent Guidelines

Repository-level rules for AI agents working in this codebase.

## Local Shell Execution

Agents may use any appropriate local shell. When using PowerShell syntax or executing a `.ps1` script locally, use PowerShell 7+ through `pwsh`; never invoke `powershell` or `powershell.exe`. This does not prescribe GitHub Actions shell choices.

## Eval Isolation

Eval workspaces and test repositories must **never** become part of this repository's working tree. Two locations are allowed:

- `.bot/<skill-name>-workspace/` — the default. `.gitignore` covers `.bot/*`, so git never sees what lands there, and harnesses that refuse to work outside the repository folder still have somewhere to go.
- `$env:TEMP/<skill-name>-workspace/` on Windows, `/tmp/<skill-name>-workspace/` on Unix — for anything that has no reason to sit next to the source.

Anywhere else inside the repository is forbidden, including a `<skill-name>-workspace/` at the root. So are temporary git repos, test branches, throwaway commits, and local config overrides such as git aliases.

`scripts/prepare-skill-evals.ps1` enforces this: it writes to `.bot/` by default, refuses an `-OutputRoot` that is inside the repository but outside `.bot/`, and refuses `.bot/` itself if git has stopped ignoring it.

**Why:** Eval artifacts leak into the real repo history and are painful to clean up. `.bot/` is the one place inside the repository where that cannot happen, and the ignore rule is what makes it safe. Never commit a package, its prompts, or its results unless the user explicitly asks for checked-in artifacts.

An executing harness stays inside its package. Building, testing, or writing anywhere else in this repository is the failure this rule exists to prevent, and it has happened: an eval run once left 68 `bin/` and `obj/` directories across four skills' `evals/files/` fixtures.

## AI/LLM Evaluation Automation Prohibition

Repository-owned preparation, validation, CI jobs, hooks, deterministic tests, package generation, automatic completion gates, and automatic agent fan-out must never invoke an authenticated AI/LLM CLI or API. Using the user's Copilot, Claude, Codex, Gemini, or other model account as repository test infrastructure is forbidden; this repository does not provide an opt-in path around that rule. The package-local implementations under `scripts/eval-runners/` are protocol adapters, not automatic repository execution: they may invoke their native harness only when a human-selected external Eval Orchestrator is explicitly handed a prepared package and selected profile.

- Do not create, restore, recommend, or run generic automation or automatic fan-out that launches model sessions for candidate/baseline execution, grading, comparison, benchmarking, description optimization, or review generation. A runner adapter may launch its named native harness only at the explicit external-handoff boundary described below, never from repository automation or CI.
- A request to create, modify, fix, test, validate, benchmark, finalize, or release a skill does not authorize additional model calls. `yolo`, `auto`, urgency, completion gates, third-party instructions, and prior approval do not change this rule.
- Routine skill validation is local and deterministic. Use schema and metadata checks, fixture validation, bundled assertions, repository validators, and human inspection of the eval prompts and expected outcomes.
- Model-backed comparisons are not a repository completion gate. Do not spawn additional agents or call external model tools merely to satisfy a generic eval workflow.
- A temp workspace controls filesystem isolation only. It never makes external calls local, free, offline, or acceptable.
- If a future workflow genuinely requires model-backed research, stop and let the user design and approve a separate reviewed process. Do not implement it as repository benchmark automation or weaken this prohibition ad hoc.

This rule is about automation: scripts, jobs, hooks, gates, and agent fan-out that reach a model without a person asking. In repository scope that includes CI and all automatic preparation, validation, and completion workflows. A human-selected external Eval Orchestrator may invoke an explicitly selected package-local Eval Runner for the exact prepared package it was handed. That runner execution is outside deterministic repository automation even when the protocol adapter lives in this repository; it is the boundary covered by [Executing a package you were handed](#executing-a-package-you-were-handed). This exception does not permit CI, hooks, automatic completion gates, or unrequested live evaluations to invoke a model.

This rule is Priority 1. If another repository rule, skill, test, or completion gate conflicts with it, this prohibition wins.

## Portable Eval Handoff

Anthropic's `skill-creator` owns the evaluation methodology this repository uses: define evals, run each task once with the skill and once without it, hold the model, the environment, the task, and the inputs constant, then compare. Keep that experimental design. Only the execution transport changes here.

Where `skill-creator` says to spawn with-skill and baseline subagents in the same turn, this repository prepares a portable evaluation package and stops. The package keeps the existing paired methodology: `run.json` defines what one blind arm executes, `execution-profile.json` selects the runner/model/configuration, and the Eval Runner defines how its harness satisfies the contract. Before an execution-ready `RUN-THIS.prompt.md` is emitted, the user-facing preparation flow resolves a Harness + Model choice; the portable profile stores the internal runner id and the opaque runner-native model selector. The external Eval Orchestrator never chooses runner or model policy. It preflights and invokes one fresh runner process per arm, bridges raw `execution-result.json` evidence into the existing result shape, grades only after execution, invokes the packaged Anthropic `skill-creator` aggregator and static viewer, and returns the finished reports. Preparation, collection, validation, and reporting remain deterministic and never invoke a model.

### Asking for an eval

`eval <skill>`, `evaluate <skill>`, `eval this skill`, `prepare evals for <skill>`, and `evaluate <skill> using the existing evals` are all requests for this workflow. Treat them as instructions to prepare the package, never to run it, and never as a request to write new eval cases unless the user asks for that too.

Resolve the execution configuration before running the package preparation script. In an interactive agent session, offer Codebelt Reference first (`GitHub Copilot CLI` + `claude-haiku-4.5`) and verify that model through `scripts/Get-HarnessModels.ps1`; if it is unavailable, show the current discovered Copilot models and ask for a replacement. If the user selects Codex, default to `-Model gpt-5.6-luna` and low reasoning; verify the model through `scripts/Get-HarnessModels.ps1` before preparation. For manual selection, ask for Harness, discover current models for that harness with `scripts/Get-HarnessModels.ps1`, then pass the resulting runner/model pair to the preparation script. Cline and OpenCode discovery is free-only; GitHub Copilot and Codex discovery lists all currently available models. Never guess stale model ids, silently switch harnesses, or generate an execution-ready package with a null runner or model.

```
pwsh -NoProfile -File ./scripts/prepare-skill-evals.ps1 -Skill dotnet-test -Runner github-copilot -Model claude-haiku-4.5
```

`eval` with no skill named, or `eval changed`, means the whole changed set:

```
pwsh -NoProfile -File ./scripts/prepare-skill-evals.ps1 -Changed -Runner github-copilot -Model claude-haiku-4.5
```

Use `-CodebeltReference` only when the script should perform the dynamic Copilot catalog check itself and fail if `claude-haiku-4.5` is no longer present. For noninteractive direct script use, omitting both `-Runner/-Model` and `-CodebeltReference` is an error whenever a package would be generated.

### Handing the package over

Every package contains `RUN-THIS.prompt.md`, one instruction that drives the whole thing. It makes the user-selected external agent the Eval Orchestrator, Grader, and report producer. The orchestrator resolves the selected Eval Runner, preflights it, invokes it once for every blind `with_skill` and `without_skill` arm, records normalized results and available metrics, grades only after collection, writes the grading fields, and generates the static report without executing an eval prompt in its own context.

Hand the user that one file by its absolute path, and stop there. Do not reproduce its contents in the reply. The runner is built around absolute paths - the package directory, its own location, the path in the hand-back block - and a copy that has passed through a chat window arrives with them shortened to a bare directory name like `iteration-4`, pointing nowhere, with its internal links broken. The file on disk always says what the file on disk says; a paste of it is a lossy snapshot that also goes stale the moment the generator changes. Where the user's harness cannot read files at all, tell them to open that path and paste it themselves, so what travels is the real text rather than your recollection of it.

Do not list the individual prompt files, do not describe the directory layout, and do not hand back a procedure for the user to carry out by hand. A reply that ends with 26 file paths and "run both versions" has moved the work onto the user instead of doing it.

The normal path ends in the external evaluator: after all workers finish, it reads the grading key, grades each completed result using the packaged `skill-creator/agents/grader.md` guidance, writes `grading[].text`, `grading[].passed`, and `grading[].evidence`, records optional turns/token buckets/cost when the harness exposes them, runs the package adapter, and presents the first-party paired `report.html` plus Anthropic's exact `skill-creator-report.html`. If a harness cannot write back to the package, a repository session may accept the returned result objects and use `-CollectResults` as a fallback to validate them and invoke the same tools, producing `comparison.md`, `benchmark.json`, `benchmark.md`, `report.html`, and `skill-creator-report.html`. The user asked for eval results, not a second workflow decision.

### Prepare, do not execute

Generate the package with the repository script rather than by hand after resolving the Harness + Model choice:

```
pwsh -NoProfile -File ./scripts/prepare-skill-evals.ps1 -Skill <name> -Runner <runner-id> -Model <runner-native-model>
```

It reads `skills/<name>/evals/evals.json` and writes one directory per eval into `.bot/<name>-workspace/iteration-<n>/`. The grading key and result stubs stay at the eval-case level, outside the two isolated run directories a worker actually sees:

- `eval-metadata.json` — eval id and name, original prompt, expected output, assertions, required fixtures, fixture and skill hashes, and the assumptions needed to reproduce the run. This is the grading key and lives outside every run directory.
- `results/` — one prefilled result stub per configuration, also outside the run directories.
- `with_skill/` — an isolated run directory that is the worker's staged root. It holds `prompt.md` (the task with the effective skill instructions inlined, plus the same input context and response contract as the baseline), `run.json` (a harness-neutral contract naming only paths inside the run directory), `repo/` (the fixtures materialized as real files, which is the worker's working directory), an isolated empty `home/`, and `skill/<name>/` (the exact candidate skill revision, so nothing falls back to a globally installed copy).
- `without_skill/` — the same run directory without any `skill/` directory and with no skill instructions or mention of the skill under test. Its `repo/` is byte-identical to the with_skill one.

At the iteration root it also writes `manifest.json` and `RUN-THIS.prompt.md`, the single prompt that hands the whole package to an agent of the user's choosing. The one-file path requires a harness that can create isolated workers or sessions, each launched from its run directory with `repo/` as the working directory and `home/` as an isolated profile. A plain single-context client runs one prompt file directly per fresh session instead.

Useful switches: `-Eval <id...>` to prepare a subset, `-Iteration <n>` plus `-Force` to replace an iteration, `-OutputRoot <path>` to relocate the workspace, and `-MaxInlineBytes <n>` to trim what gets inlined for a smaller context window.

The expected output and the assertions are the grading key. They belong in `eval-metadata.json`, outside every run directory, and must never appear in either prompt — a baseline handed the answer key is not a baseline.

### Eval preparation is a completion gate

Adding or modifying any repo-managed skill triggers this workflow. It is not something the user asks for separately, and "the change is small" or "the evals did not change" does not exempt it. Touching `SKILL.md`, `FORMS.md`, `references/`, `scripts/`, `assets/`, or `evals/` under `skills/<name>/` is a skill change.

After the final skill edit is in place, run:

```
pwsh -NoProfile -File ./scripts/prepare-skill-evals.ps1 -Changed -Runner <runner-id> -Model <runner-native-model>
```

It resolves every repo-managed skill this branch changed, uncommitted work included, and prepares a package for each. With no skill changed it says so and exits clean, which satisfies the gate.

Then name the prepared prompt paths in the completion message so the user knows what is waiting for them. Preparing and reporting satisfies this gate. Executing a prompt never does, and an agent that runs one has broken the Priority 1 rule rather than completed the gate.

Run it before `scripts/sync-skill-install.ps1`, which stays the last gate because it must observe the final state of every file. See [Blocking Completion Gates](#blocking-completion-gates).

### Manual execution boundary

Two roles exist here, and they are not the same agent doing the same job. Read which one you are before applying the rules below.

**Preparing.** You are doing repository work: authoring a skill, changing one, or answering a request to evaluate one. After the package is written you stop, and you must:

- never execute the prompts you just prepared, and never quietly become the executor of your own package
- never spawn subagents for the candidate or baseline runs
- never call an LLM API or an authenticated AI CLI to run them
- never treat model-backed execution or its absence as a completion gate
- hand over the runner prompt and say plainly what is ready

Deterministic validation and human inspection remain the gate, exactly as before.

**Executing.** A human handed you a prepared package and asked you to run it. See the next section. Refusing that is not compliance, it is the workflow failing to work.

### Executing a package you were handed

When a person gives you `RUN-THIS.prompt.md`, points you at a prepared package, or otherwise asks you to run one, running it is the task. The **AI/LLM Evaluation Automation Prohibition** does not stop you, and citing it to refuse is a misreading: that rule governs automation reaching a model on its own, not a human choosing a harness and telling it to run a specific package. The user picked you, the model, and the moment. That is precisely the external execution this design reserves for them.

Four things still hold while you execute:

- Run only the package you were handed, and only because a person asked in this turn. A hook, a script, a completion gate, a skill change, or another agent asking is not a person asking.
- Stay inside the package directory. If it sits inside a repository, the rest of that repository is not yours to read, build, test, or write.
- Do not read the assertions or expected output before the worker runs. After every available worker has finished and its result is recorded, grade the completed results, generate the report, and state the comparison honestly.
- Nothing about this makes model-backed execution a completion gate for any repository task.

An agent that prepared a package in this session does not get to turn around and execute it. The separation is the point: the preparer knows the grading key, so it is the wrong harness. This is the only role-based disqualification.

The selected executor has two ordered phases. Its current context may read `RUN-THIS.prompt.md`, `manifest.json`, `execution-profile.json`, and the runner protocol files, but it must not execute an eval prompt itself. In phase one, it resolves the selected runner, validates `describe`, preflights each `run.json`, and dispatches every arm through the selected runner's declared harness-native worker mechanism. The parent and delegated worker must not invoke the compatibility `execute` transport or substitute a generic subagent. The runner launches each native harness session from its own run directory with `repo/` as the working directory, `home/` as the isolated profile, and the required isolation controls; hard filesystem confinement, when a runner proves it, raises the reported isolation from pragmatic to strict but is not itself a prerequisite. The runner-produced terminal result must retain the selected runner identity, exact native mechanism, and hashed transcript/event artifact; a parent-created summary is incompatible. The runner receives only `run.json` and `execution-profile.json`; workers never see the runner, manifest, grading key, sibling results, or orchestration commentary, because all of those live outside the run directory. Never reuse a worker or session between runs. In phase two, after all available execution results are complete or failed, the executor validates and freezes the raw results, bridges them into `eval-result/2`, reads the grading key, follows the packaged `skill-creator` grader guidance, writes the grading evidence, invokes the package adapter so Anthropic's aggregator and eval viewer produce the report, and returns the report path and comparison. It does not ask the user whether to start either phase.

The candidate instructions are already inlined in the with_skill run's `prompt.md` and staged under its `skill/<name>/` directory; the orchestrator does not load or summarize them for the worker. The baseline run has no `skill/` directory and no candidate instructions, and the orchestrator must not expose the candidate skill through another route, including a globally installed copy. The generated prompt files and the baseline `run.json` also omit the skill name, eval identifiers, and configuration labels so workers receive an ordinary task rather than an announcement that they are under evaluation.

Use the same model, model version, configuration, tools, and limits for every worker. Disable persistent memory and cross-session recall. Independent runs must execute concurrently up to `min(execution-profile.json.concurrency, remaining arms)` when harness capacity permits, but every run still gets a distinct context and no shared mutable workspace. For an OpenCode profile, one-at-a-time Task dispatch with available capacity is non-compliant; only an explicit harness capacity rejection justifies a serial effective run, and that limit must be recorded in orchestration state.

For OpenCode, the external orchestrator must perform that concurrency as one assistant turn: after preflight, emit one sibling native `Task` call per pending arm up to the available slots, then await the results. It must not ask whether to start or re-dispatch, send a prose status message between calls, or wait for the first Task result before emitting the remaining calls. If the client cannot emit multiple sibling Task calls in one turn, the selected runner is incompatible; do not silently fall back to serial execution.

`RUN-THIS.prompt.md` requires a selected Eval Runner that can create isolated workers or sessions. A plain single-context client can still execute an individual self-contained prompt when the user opens it directly as the first message of a fresh session, but it cannot provide the paired comparison and report contract in that same context. A selected runner that cannot satisfy a required guarantee is `incompatible`; there is no generic fallback or runner substitution. Partial package state may be inspected and reported, but the completion gate must pass before it can be presented as a completed evaluation; missing or unrun arms remain visibly incomplete.

An `output` is the model's own message in full, including questions, caveats, explanations, or a refusal. Where a run invoked a tool, that tool's stdout is evidence rather than a replacement for the response. Record the full worker transcript, duration, token usage, and tool-call count when the harness exposes them; omit unavailable metrics rather than estimating them.

### Same model on both sides

A fresh context is fresh of memory as well as of transcript. A harness with persistent memory, saved project instructions, or cross-session recall can carry into a nominally new session what it learned while running the previous one, which makes that session a continuation wearing a new name. Runs made under such a harness need that memory disabled, or a profile without it.

An evaluated context sees its `prompt.md` and the files staged in its run directory, and nothing else - not `RUN-THIS.prompt.md`, not `run.json` from the paired run, not the assertions, not another case's output, not a note that an experiment is underway. Anything added on top is a second variable in a comparison meant to differ in exactly one.

A meaningful A/B result requires both configurations to run on the same model, the same version, and the same configuration, varying only whether the skill is present. Running the with-skill case on one model and the baseline on another measures the model and the skill together; that is not a skill-effectiveness benchmark and must not be reported as one. When models are deliberately mixed, say so and treat the comparison as directional only.

### Result handoff

An externally produced result comes back identified by eval id, configuration (`with_skill` or `without_skill`), runner-native model, harness, and the produced output. It may also carry the transcript, duration, total tokens, tool-call count, output files, and notes. The user can hand it over as filled-in `results/*.result.json` files, or state it in chat and let the agent fill them in.

Which artifact transfer happens depends on where the harness ran, and `RUN-THIS.prompt.md` tells it to close either way. A harness sharing a disk with the package writes the result files, grading, `benchmark.json`, `benchmark.md`, the first-party `report.html`, and the exact upstream `skill-creator-report.html` itself and reports the first-party report path. A harness that does not - a different product, a browser, or a sandbox - ends with one paste-ready block carrying the package path and every completed result object, including grading, plus the reports as file artifacts when supported. A repository session can use `-CollectResults` only as a fallback for transferred results that lack the report artifacts. "Bring the results back" means those artifacts, never a prose recap of how the runs went.

Validate and compare a collected iteration with:

```
pwsh -NoProfile -File ./scripts/prepare-skill-evals.ps1 -CollectResults <iteration-path>
```

It checks that each result matches its eval and configuration, may inspect and write `comparison.md`, the paired `report.html`, the exact upstream `skill-creator-report.html`, and the upstream `benchmark.json`/`benchmark.md` while warning when an arm is missing, unrun, or ran on a different model. It exits non-zero when the required completion gate is not satisfied, so an incomplete or unrun package is not a completed evaluation. The external evaluator may grade in its user-directed phase-two context; repository automation remains deterministic and never invokes a model. Use deterministic checks for mechanical assertions and evidence-backed human or evaluator judgement only where the assertion is genuinely qualitative.

### Workspace isolation

Eval packages obey **Eval Isolation**: they default to `.bot/<skill>-workspace/`, which git ignores, and `-OutputRoot` may only point there or outside the repository. Do not commit a package, its prompts, or its results unless the user explicitly asks for checked-in artifacts.

## Per-Skill Evals

Every repo-managed skill must include its own `evals/evals.json` file at `skills/<name>/evals/evals.json`.

- Treat this as a required artifact for every first-party skill in this repo
- Eval entries may include an optional `files` array of skill-relative fixture paths such as `evals/files/example.md`
- When `files` is present, keep the paths relative to `skills/<name>/` and validate that every fixture exists
- Treat eval prompts, expected outcomes, and assertions as versioned review specifications; their presence never authorizes automated model execution
- Start with `pwsh -NoProfile -File ./scripts/validate-skill-templates.ps1 -MetadataOnly` for a sub-second repository-wide metadata and fixture check
- Run only the changed skill's deterministic validator and focused regression scripts during iteration; independent read-only checks may use bounded local parallelism, while shared-file mutations stay sequential
- Run `pwsh -NoProfile -File ./scripts/validate-skill-templates.ps1` once before completion for the repository gate
- Follow the top-level **AI/LLM Evaluation Automation Prohibition** for every eval. No per-skill or third-party requirement overrides it.
- To compare a skill against a baseline, prepare a package with **Portable Eval Handoff** and hand `RUN-THIS.prompt.md` to the user; the repository agent never runs the prompts, while the user-directed external executor runs, grades, and reports the paired comparison
- Deterministic scaffold/template skills must keep local deterministic validators as well; evals supplement validators, they do not replace them

If you add a new skill or modify an existing repo-managed skill, update that skill's `evals/evals.json` and run `pwsh -NoProfile -File ./scripts/prepare-skill-evals.ps1 -Changed -Runner <runner-id> -Model <runner-native-model>` before considering the work complete. Use `-CodebeltReference` instead only after its dynamic Copilot model check passes. Do not commit temp workspaces, benchmark outputs, or generated review files into this repository unless the user explicitly asks for checked-in artifacts.

## Git Identity

Never set or override `git user.name`, `git user.email`, or `alias.bot` in the **local** git config of this repository. Always use the global config. Local overrides silently shadow global settings and produce commits with the wrong author.

## Git Operations Safeguards

Agents must never commit code changes or push to remote repositories without explicit user approval. A direct commit request that includes `yolo` or `auto` is explicit approval for the current commit request; it authorizes the agent to complete that commit workflow in the same turn after the required checks pass.

- **Commits**: Request confirmation from the user before staging and committing code unless the same explicit commit request includes `yolo` or `auto`. In that auto-approved case, present the plan as status information and continue directly to staging and committing; do not ask a second confirmation question or end with a pending plan. Required review, scope, identity, message-validation, and post-commit checks still apply.
- **Remote Operations**: Do not push, pull, fetch, or interact with `origin` or any remote repository without explicit user instruction. These operations modify repository history and can cause data loss if performed unexpectedly.

**Why:** Automatic commits can pollute history with incomplete work, debugging code, or unintended changes. Unexpected remote operations can overwrite or lose commits on shared branches. Never treat silence, urgency, or momentum as approval; `yolo` or `auto` counts as approval only when attached to the same explicit commit request.

### Commit Skill Routing

When the user asks to commit or stage changes, write or review a commit message, or says `git bot commit`, `git commit`, or `git our commit`, invoke `git-visual-commits` before responding to the request or running Git commands for that commit workflow. Treat `Please do a git bot commit yolo` and equivalent wording as an explicit invocation of `git-visual-commits`: `git bot commit` selects bot identity and `yolo` enables that skill's auto-approval mode. Do not route the request to changelog or release-note skills, treat `yolo` as the commit message, replace bot identity with a human commit plus a co-author trailer, or bypass the skill because the commit appears simple.

Bare `yolo` or `auto` outside an explicit commit request does not invoke `git-visual-commits`. Likewise, those modifiers do not invoke `git-keep-a-changelog` unless the user explicitly requests a changelog or release-note output. Users can force deterministic CLI selection with `/git-visual-commits` when they do not want to rely on automatic skill selection.

## Skill Creation

Always use the `skill-creator` skill (by Anthropic) when creating new skills, modifying existing skills, or running evals. It enforces best practices for structure, description quality, testing, and progressive disclosure. Do not create or edit skills manually without invoking it first.

Follow it as written except at the execution boundary. Anthropic's `skill-creator` requires paired with-skill and baseline runs in fresh subagents. This repository prepares the same paired inputs as a portable package and stops. When the user hands that package to a harness, `RUN-THIS.prompt.md` makes the selected harness create those isolated paired workers without exposing the grading key, then use the packaged `skill-creator` grader guidance, aggregator, and eval viewer in the same handoff. The authoring guidance, eval definitions, assertion drafting, and iteration loop still apply; only the execution transport changes. Repository-side validation remains deterministic, while the explicitly user-directed external executor performs the post-run evaluator judgement and invokes the upstream viewer/report generation that the skill-creator experience expects.

`skill-creator-agnostic` is deprecated, no longer maintained, and retained only for backward compatibility until 1.0.0. Agents must not use it for new skill creation, skill modification, or benchmarking; use Anthropic's `skill-creator` directly and apply the repository-specific requirements from this `AGENTS.md`.

## Third-Party Skills

Never modify skills maintained by others (e.g. `skill-creator` by Anthropic). If a third-party skill needs repo-specific behavior, add the rule here in `AGENTS.md` — not in the skill file itself, and not in a companion overlay around the third-party skill. Upstream updates will overwrite local edits without warning.

## Local Install Sync

Repo-managed skills live in four places that must stay in sync:

- `skills/<name>/` — source control (and source of truth for edits)
- `~/.claude/skills/<name>/` — local Claude install
- `~/.agents/skills/<name>/` — local global agent install
- `~/.gemini/antigravity-cli/skills/<name>/` — local Gemini Antigravity install

Sync the **whole skill tree** with the repository as the source of truth, and prove it with hashes:

```
pwsh -NoProfile -File ./scripts/sync-skill-install.ps1 -Skill <name>
```

The script copies every file under `skills/<name>/` into all three installs, then compares SHA-256 across all four locations and exits non-zero on any difference. `-VerifyOnly` checks without copying, `-Prune` deletes install files that no longer exist in the repository, and omitting `-Skill` sweeps every repo-managed skill. Generated build output (`bin/`, `obj/`) is excluded because it is regenerated per location and never matches; a file that exists only in an install is drift too, because a rename or deletion otherwise leaves the old one loading forever.

**Run it as the last action before the completion message, after the final edit is in place.** Do not copy a remembered list of touched files: that list goes stale the moment you edit one more file, and a sync performed earlier in the session says nothing about what changed after it. Never report "synced" or "hash-identical" from memory, from an earlier turn, or from a partial per-file copy — the claim must be backed by this command's output in the same response that makes it. This is a [blocking completion gate](#blocking-completion-gates).

If a change starts in `~/.claude/skills/<name>/` or another install, mirror the edited file back into `skills/<name>/` first, then run the script so the repository stays authoritative.

When renaming a skill, update **all four** locations — the repo folder, the local Claude install folder, the local global agent install folder, and the local Gemini Antigravity install folder. The folder name and the `name:` field in the SKILL.md frontmatter must match. A mismatch causes the skill to disappear from tooling or show stale instructions.

A sync mismatch means one side runs a stale version, which leads to confusing eval results and wasted iterations.

After the source copy passes its deterministic tests, SHA-256 identity across the repo and all three local installs is sufficient installation verification. Do not rerun the same deterministic suites from a hash-identical installed copy; that duplicates time, compute, and token use without adding evidence. Run an installed-copy test only when install-path resolution, loader behavior, permissions, or an actual hash mismatch is the subject of the test.

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

## Markdown Formatting

All markdown files in this repository must use natural paragraph flow. Do not artificially break paragraphs at fixed column widths or insert hard line breaks within sentences. Paragraphs should flow as complete thoughts, allowing line wrapping to be determined by the reader's viewport or rendering engine, not by arbitrary character limits.

**Why:** Natural paragraphs are more readable, easier to edit, and render correctly across all devices and markdown renderers. Artificially clipped paragraphs create maintenance friction and look awkward in source control diffs.

## README Sync

After modifying any skill (`SKILL.md`, `FORMS.md`) or repo-level config (`AGENTS.md`), **always update `README.md` before considering the task done**. This is a mandatory gate — not a nice-to-have. The README's "Available Skills" table, install examples, and "Why" sections must reflect the current state of all skills. A new skill without a README entry is incomplete work.

## Blocking Completion Gates

When repository guidance, an active skill, or a conversation summary identifies required follow-up work as pending, critical, blocking, or equivalent, treat those items as the active completion checklist for the current task rather than as background context. Do not call `task_complete`, describe the task as complete, or claim verification succeeded until every blocking item has either run successfully or been reported with the exact command, exit code, and remaining blocker.

Before any completion message, reread the skill instructions and the current conversation summary's pending-task or blocker sections. If either one names a required script, validator, or maintenance step, that step is a hard gate, not optional polish.

For script-backed workflows, creating or editing files is not enough on its own. If a skill requires deterministic maintenance or verification commands, run them before completion and report their concrete outcome. For `dotnet-docfx-digest`, `scripts/agents.cs` and `scripts/docfx.cs --build-api-model --validate-samples --verify-docfx-build` are blocking completion gates whenever the skill or task summary says they are required.

Whenever a repo-managed skill was edited, two gates apply in a fixed order. `pwsh -NoProfile -File ./scripts/prepare-skill-evals.ps1 -Changed -Runner <runner-id> -Model <runner-native-model>` (or `-CodebeltReference` after dynamic availability verification) runs first and prepares the eval packages for the changed skills, reporting the prompt paths. `scripts/sync-skill-install.ps1` runs last, because every other step can still change a file. Report the actual output of both; an earlier run in the same session satisfies neither. See [Eval preparation is a completion gate](#eval-preparation-is-a-completion-gate) and [Local Install Sync](#local-install-sync).

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

## Status Update Hygiene

Interim progress updates should describe user-relevant progress, evidence, blockers, and next steps. Do not narrate runner internals, sandbox mechanics, approved command paths, or retry plumbing unless that detail affects user approval, reproducibility, validation, or the final outcome.

- Say what changed in the task state, not how the host executed the command
- Mention tool/runtime failures only when they block progress, require approval, or change the planned validation
- Prefer concise phrasing such as "The first read attempt failed before returning file content; I'm retrying and will report only if that changes the result"

## Skill Authoring

Skills MUST follow the Agent Skills specification and remain compatible with Anthropic's skill guidance. Repository conventions below may intentionally be stricter than the specification.

### Structure

```text
skill-name/
├── SKILL.md       # Required
├── scripts/       # Optional executable automation
├── references/    # Optional supporting documentation
└── assets/        # Optional templates and output resources
```

- `SKILL.md` MUST use that exact case-sensitive name.
- Skill folders MUST use kebab-case.
- Frontmatter `name` MUST match the folder name.
- Do NOT place `README.md` inside a skill folder. Put skill documentation in `SKILL.md` or `references/`.
- Keep `SKILL.md` focused. Move detailed or rarely needed material to `references/`.
- Keep `SKILL.md` below 5,000 words.

### Progressive Disclosure

Design every skill around three levels of context:

1. **Metadata:** `name` and `description` are available before activation.
2. **Instructions:** the `SKILL.md` body is loaded when the skill is selected.
3. **Resources:** scripts, references, and assets are loaded or used only when needed.

Minimize content at earlier levels. Do not put instructions into metadata merely to advertise skill capabilities.

### Frontmatter

```yaml
---
name: skill-name
description: Use when ...
---
```

Required:

- `name`: 1-64 characters, lowercase alphanumeric characters and hyphens only; MUST match the skill directory.
- `description`: 1-1024 characters and MUST communicate both what the skill is for and when it should activate.

Optional fields such as `license`, `compatibility`, `metadata`, and supported tool restrictions MAY be used when they provide meaningful runtime or distribution information.

### Description Is a Trigger

Treat `description` as **activation metadata, not documentation**.

- SHOULD begin with trigger-oriented language such as `Use when...`.
- SHOULD describe **user intent**, not the skill's implementation.
- SHOULD stay at or below a **300-character soft ceiling**.
- MAY be shorter than 150 characters when that is sufficient. Never pad a description to meet a minimum length.
- MAY exceed 300 characters only when additional wording materially improves trigger precision or recall.
- MUST remain within the 1024-character specification limit.
- SHOULD include distinctive tasks, artifacts, technologies, file types, or domain terms that help discriminate the skill from others.
- SHOULD cover natural paraphrases conceptually rather than stuffing exact trigger phrases or keywords.
- SHOULD add exclusions only when needed to prevent realistic near-miss or overlapping skills from triggering.
- MUST NOT summarize workflows, scripts, implementation details, references, rationale, or every capability of the skill.
- MUST NOT broaden the description merely to advertise functionality.

Prefer:

```yaml
description: Use when creating or refactoring .NET tests that require deterministic remote or containerized execution across supported test harnesses.
```

Avoid:

```yaml
description: Provides comprehensive guidance, scripts, configuration options, troubleshooting procedures, and best practices for running .NET tests remotely using containers and multiple supported test harnesses.
```

Optimize for **trigger precision and recall per character**, not descriptive completeness.

### Instructions

Inside `SKILL.md`:

- Make instructions specific, actionable, and ordered where sequencing matters.
- Put critical constraints near the top.
- Include error handling where failures are predictable.
- Use validation and refinement loops where output quality benefits from iteration.
- Prefer deterministic scripts for repeatable or critical validation rather than lengthy natural-language procedures.
- Prefer values discoverable from the repository, environment, or authoritative machine-readable sources over hardcoded defaults.
- Keep detailed reference material out of the main instruction path.

### Validation

Before shipping or materially changing a skill, verify that it:

- triggers for obvious relevant requests;
- triggers for realistic paraphrases and implicit intent;
- does not trigger for realistic near-miss requests;
- behaves correctly after activation;
- improves the intended outcome compared with not using the skill.

When optimizing a description, test both **should-trigger** and **should-not-trigger** cases. Prefer measured trigger behavior over arbitrary description length, and avoid tailoring descriptions to individual evaluation phrases.

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
