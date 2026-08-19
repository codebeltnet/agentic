# Agent Guidelines

Repository-level rules for AI agents working in this codebase.

## Local Shell Execution

Agents may use any appropriate local shell. When using PowerShell syntax or executing a `.ps1` script locally, use PowerShell 7+ through `pwsh`; never invoke `powershell` or `powershell.exe`. This does not prescribe GitHub Actions shell choices.

## Eval Isolation

Eval workspaces and test repositories must **never** be created inside this repository. This includes:

- `<skill-name>-workspace/` directories
- Temporary git repos for testing skills
- Test branches, throwaway commits, or config overrides (e.g. git aliases)

When running evals or testing skills, create all workspaces in a temp location:

- **Windows**: `$env:TEMP/<skill-name>-workspace/`
- **Unix**: `/tmp/<skill-name>-workspace/`

**Why:** Eval artifacts — branches, commits, local git config — leak into the real repo history and are painful to clean up. The skill source lives in a git repo; eval output does not belong here.

## AI/LLM Evaluation Automation Prohibition

Repository scripts, CI jobs, skill runners, graders, optimizers, and custom executor hooks must never invoke an authenticated AI/LLM CLI or API. Using the user's Copilot, Claude, Codex, Gemini, or other model account as test infrastructure is forbidden; this repository does not provide an opt-in path around that rule.

- Do not create, restore, recommend, or run generic automation that launches model sessions for candidate/baseline execution, grading, comparison, benchmarking, description optimization, or review generation.
- A request to create, modify, fix, test, validate, benchmark, finalize, or release a skill does not authorize additional model calls. `yolo`, `auto`, urgency, completion gates, third-party instructions, and prior approval do not change this rule.
- Routine skill validation is local and deterministic. Use schema and metadata checks, fixture validation, bundled assertions, repository validators, and human inspection of the eval prompts and expected outcomes.
- Model-backed comparisons are not a repository completion gate. Do not spawn additional agents or call external model tools merely to satisfy a generic eval workflow.
- A temp workspace controls filesystem isolation only. It never makes external calls local, free, offline, or acceptable.
- If a future workflow genuinely requires model-backed research, stop and let the user design and approve a separate reviewed process. Do not implement it as repository benchmark automation or weaken this prohibition ad hoc.

This rule is Priority 1. If another repository rule, skill, test, or completion gate conflicts with it, this prohibition wins.

## Portable Eval Handoff

Anthropic's `skill-creator` owns the evaluation methodology this repository uses: define evals, run each task once with the skill and once without it, hold the model, the environment, the task, and the inputs constant, then compare. Keep that experimental design. Only the execution transport changes here.

Where `skill-creator` says to spawn with-skill and baseline subagents in the same turn, this repository prepares a portable evaluation package and stops. The repository agent does not execute the prepared prompts. The user picks the harness, provider, and model, runs both configurations, and brings the results back. This complements the **AI/LLM Evaluation Automation Prohibition** above and never relaxes it: preparing prompts is deterministic file generation, and a prepared prompt is not permission to run one.

### Asking for an eval

`eval <skill>`, `evaluate <skill>`, `eval this skill`, `prepare evals for <skill>`, and `evaluate <skill> using the existing evals` are all requests for this workflow. Treat them as instructions to prepare the package, never to run it, and never as a request to write new eval cases unless the user asks for that too.

Run the script immediately when asked. Do not reply with a plan, a menu of options, or a question about which harness or model the user wants; the harness and model are chosen after the package exists, by the user, outside this repository.

```
pwsh -NoProfile -File ./scripts/prepare-skill-evals.ps1 -Skill dotnet-test
```

`eval` with no skill named, or `eval changed`, means the whole changed set:

```
pwsh -NoProfile -File ./scripts/prepare-skill-evals.ps1 -Changed
```

Then report the prepared prompt paths and stop.

### Prepare, do not execute

Generate the package with the repository script rather than by hand:

```
pwsh -NoProfile -File ./scripts/prepare-skill-evals.ps1 -Skill <name>
```

It reads `skills/<name>/evals/evals.json` and writes one directory per eval into `<temp>/<name>-workspace/iteration-<n>/`:

- `with-skill.prompt.md` — the eval task, the same input context and fixtures as the baseline, the same response contract as the baseline, and the effective skill instructions inlined so the prompt is self-contained. It must not assume the target harness resolves Anthropic skill paths or loads skills natively. Resources too large or too binary to inline are bundled under `skill/<name>/` and listed in the prompt as such.
- `without-skill.prompt.md` — the same task, the same inputs, the same response contract, no skill instructions and no mention of which skill is under test, plus an instruction to solve the task with normal capabilities.
- `eval-metadata.json` — eval id and name, original prompt, expected output, assertions, required fixtures, and the assumptions needed to reproduce the run.
- `files/` — the eval fixtures, attached identically to both configurations.
- `results/` — one prefilled result stub per configuration.

Useful switches: `-Eval <id...>` to prepare a subset, `-Iteration <n>` plus `-Force` to replace an iteration, `-OutputRoot <path>` to relocate the workspace, and `-MaxInlineBytes <n>` to trim what gets inlined for a smaller context window.

The expected output and the assertions are the grading key. They belong in `eval-metadata.json` and must never appear in either prompt — a baseline handed the answer key is not a baseline.

### Eval preparation is a completion gate

Adding or modifying any repo-managed skill triggers this workflow. It is not something the user asks for separately, and "the change is small" or "the evals did not change" does not exempt it. Touching `SKILL.md`, `FORMS.md`, `references/`, `scripts/`, `assets/`, or `evals/` under `skills/<name>/` is a skill change.

After the final skill edit is in place, run:

```
pwsh -NoProfile -File ./scripts/prepare-skill-evals.ps1 -Changed
```

It resolves every repo-managed skill this branch changed, uncommitted work included, and prepares a package for each. With no skill changed it says so and exits clean, which satisfies the gate.

Then name the prepared prompt paths in the completion message so the user knows what is waiting for them. Preparing and reporting satisfies this gate. Executing a prompt never does, and an agent that runs one has broken the Priority 1 rule rather than completed the gate.

Run it before `scripts/sync-skill-install.ps1`, which stays the last gate because it must observe the final state of every file. See [Blocking Completion Gates](#blocking-completion-gates).

### Manual execution boundary

After the package is written, the repository agent stops and names the prompts that are ready for external execution. It must:

- never execute a generated prompt, in any harness, including its own
- never spawn subagents for the candidate or baseline runs
- never call an LLM API or an authenticated AI CLI
- never treat model-backed execution or its absence as a completion gate
- state plainly which prompt files are ready and where they are

Deterministic validation and human inspection remain the gate, exactly as before.

### Same model on both sides

A meaningful A/B result requires both configurations to run on the same model, the same version, and the same configuration, varying only whether the skill is present. Running the with-skill case on one model and the baseline on another measures the model and the skill together; that is not a skill-effectiveness benchmark and must not be reported as one. When models are deliberately mixed, say so and treat the comparison as directional only.

### Result handoff

An externally produced result comes back identified by four things: eval id, configuration (`with_skill` or `without_skill`), model and provider if known, and the produced output. That is the whole contract. The user can hand it over as filled-in `results/*.result.json` files, or state it in chat and let the agent fill them in.

Validate and compare a collected iteration with:

```
pwsh -NoProfile -File ./scripts/prepare-skill-evals.ps1 -CollectResults <iteration-path>
```

It checks that each result matches its eval and configuration, warns when an arm is missing, unrun, or ran on a different model, and writes `comparison.md`. Grading uses the assertions already in `evals/evals.json`, deterministic scripts where an assertion can be checked programmatically, and human inspection otherwise. Do not add model-based grading to support this workflow.

### Workspace isolation

Eval packages obey **Eval Isolation**: they are written outside this repository, and the script refuses an `-OutputRoot` inside it. Do not commit a package, its prompts, or its results unless the user explicitly asks for checked-in artifacts.

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
- To compare a skill against a baseline, prepare a package with **Portable Eval Handoff** and hand the prompts to the user; the agent never runs them
- Deterministic scaffold/template skills must keep local deterministic validators as well; evals supplement validators, they do not replace them

If you add a new skill or modify an existing repo-managed skill, update that skill's `evals/evals.json` and run `pwsh -NoProfile -File ./scripts/prepare-skill-evals.ps1 -Changed` before considering the work complete. Do not commit temp workspaces, benchmark outputs, or generated review files into this repository unless the user explicitly asks for checked-in artifacts.

## Git Identity

Never set or override `git user.name`, `git user.email`, or `alias.bot` in the **local** git config of this repository. Always use the global config. Local overrides silently shadow global settings and produce commits with the wrong author.

## Git Operations Safeguards

Agents must never automatically commit code changes or push to remote repositories. Both actions require explicit user approval:

- **Commits**: Always request confirmation from the user before staging and committing code. Present a clear summary of changes and wait for user approval before executing the commit.
- **Remote Operations**: Do not push, pull, fetch, or interact with `origin` or any remote repository without explicit user instruction. These operations modify repository history and can cause data loss if performed unexpectedly.

**Why:** Automatic commits can pollute history with incomplete work, debugging code, or unintended changes. Unexpected remote operations can overwrite or lose commits on shared branches. Always require the user to explicitly approve these operations.

### Commit Skill Routing

When the user asks to commit or stage changes, write or review a commit message, or says `git bot commit`, `git commit`, or `git our commit`, invoke `git-visual-commits` before responding to the request or running Git commands for that commit workflow. Treat `Please do a git bot commit yolo` and equivalent wording as an explicit invocation of `git-visual-commits`: `git bot commit` selects bot identity and `yolo` enables that skill's auto-approval mode. Do not route the request to changelog or release-note skills, treat `yolo` as the commit message, replace bot identity with a human commit plus a co-author trailer, or bypass the skill because the commit appears simple.

Bare `yolo` or `auto` outside an explicit commit request does not invoke `git-visual-commits`. Likewise, those modifiers do not invoke `git-keep-a-changelog` unless the user explicitly requests a changelog or release-note output. Users can force deterministic CLI selection with `/git-visual-commits` when they do not want to rely on automatic skill selection.

## Skill Creation

Always use the `skill-creator` skill (by Anthropic) when creating new skills, modifying existing skills, or running evals. It enforces best practices for structure, description quality, testing, and progressive disclosure. Do not create or edit skills manually without invoking it first.

Follow it as written except at one point: when it reaches the step that spawns with-skill and baseline runs, switch to **Portable Eval Handoff** and prepare prompts instead. Its authoring guidance, eval definitions, assertion drafting, and iteration loop all still apply; only the execution transport is replaced. The same substitution covers its grading, aggregation, viewer, and description-optimization steps, which all assume model execution this repository does not perform.

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

Whenever a repo-managed skill was edited, two gates apply in a fixed order. `pwsh -NoProfile -File ./scripts/prepare-skill-evals.ps1 -Changed` runs first and prepares the eval packages for the changed skills, reporting the prompt paths. `scripts/sync-skill-install.ps1` runs last, because every other step can still change a file. Report the actual output of both; an earlier run in the same session satisfies neither. See [Eval preparation is a completion gate](#eval-preparation-is-a-completion-gate) and [Local Install Sync](#local-install-sync).

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
