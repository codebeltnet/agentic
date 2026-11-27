# Agentic Skills

Repository scratch files belong in a task-specific OS temporary directory by default, or under ignored `.bot/` when repository-local storage is needed. API snapshots, intermediate JSON/text, logs, drafts, caches, and temporary workspaces must never be written elsewhere in the working tree. Maintained source files and test fixtures remain in their intended locations. See [Scratch File Isolation](AGENTS.md#scratch-file-isolation).

![Skills Applied](assets/hero.jpg)

A curated collection of [skills](https://skills.sh) — reusable instruction sets that teach AI agents how to follow specific workflows, conventions, and standards. Designed to work with any agent that supports the skills ecosystem: GitHub Copilot, Claude Code, Cursor, Codex, OpenCode, and [many more](https://skills.sh).

## What are skills?

Skills are Markdown files that an AI agent reads before responding. When a skill is active, the agent follows the rules it contains — consistently, across any tool or model that supports them. They're a lightweight way to encode your team's conventions once and apply them everywhere.

One repo-wide convention matters especially for scaffolding skills: prefer dynamic defaults over hardcoded values whenever a reliable source exists. Derive time-sensitive or environment-sensitive values from git metadata, repo state, or official machine-readable feeds so skills age gracefully instead of drifting.

Another repo rule is intentionally strict: every repo-managed skill ships with its own `evals/evals.json`. These files are versioned review specifications whose prompts, fixtures, and expected outcomes are validated locally; they are not instructions to launch model sessions.

Skill validation is local and deterministic. The Priority 1 **AI/LLM Evaluation Automation Prohibition** in `AGENTS.md` forbids repository preparation, validation, CI, hooks, deterministic tests, automatic fan-out, graders, and completion gates from using an authenticated Copilot, Claude, Codex, Gemini, or other model account. There is no repository opt-in switch. A human-selected external Eval Orchestrator may invoke an explicitly selected package-local Eval Runner for a package it was handed; that boundary never authorizes live model execution in CI or automatic repository workflows.

Evaluation keeps Anthropic's `skill-creator` methodology and portable paired-run conventions while replacing only the execution transport. `run.json` remains the runner-neutral one-arm contract; `execution-profile.json` selects the runner/model/configuration; and `delegation.dispatch_owner` declares whether the orchestrator dispatches a native subagent/task or starts the runner-owned native execution surface directly. Orchestrator-owned envelopes pass through `record-native-result.ps1`; runner-owned transports produce `execution-result.json` directly before the existing `eval-result/2` bridge and reports. The user-facing preparation flow normalizes explicit harness intent before emitting `RUN-THIS.prompt.md`; the portable profile stores the internal runner id and the opaque runner-native model selector, with no provider field. The conforming real runners are Codex and OpenCode, with a deterministic fake runner used for conformance. Codex CLI with `gpt-6-luna` and high reasoning is the Codebelt Reference evaluation configuration and the Codex preparation default. Package preparation validates the resolved model against the current harness catalog before writing the profile. OpenCode discovery mirrors every model exposed by all configured providers, preserves exact `provider/model` selectors, and retains availability only as presentation metadata; it never filters paid or unknown models. When OpenCode is selected without an explicit model, the user must choose from the discovered selectors before package preparation, and no first/free/recommended/previous model may be selected automatically. Codex discovery lists all currently available models. The repository prepares the paired candidate and baseline inputs as a portable package and stops; the external Eval Orchestrator resolves, preflights, follows the selected dispatch owner, then grades and reports. Runners grant full operational permission inside each isolated behavioral harness configuration so the evaluated agent can perform ordinary engineering work noninteractively. Hard filesystem confinement is a separate optional outer capability: it raises reported isolation confidence from pragmatic to strict when proven, but it is not a universal platform prerequisite, so Windows is a first-class pragmatic target; mandatory experimental controls remain fail-closed. Native skill activation is not evaluated in v0.9.1. Package preparation is optional and happens only when the user explicitly asks for an evaluation, such as `eval <skill>`, `evaluate <skill>`, or `please do an eval`; changing a skill alone does not require choosing a harness or preparing a package:

Phase 1 closes by writing an immutable `execution-freeze.json` ledger with the exact manifest result paths and hashes of every runner-produced execution result and referenced raw transcript/event artifact. The bridge, grading application, and report adapter validate that ledger and never re-bless changed bytes. The external Grader writes only package-root `grading.json` (`codebeltnet/agentic/eval-grading/1`); `apply-eval-grading.ps1` projects only `passed` and `evidence` decisions onto canonical results. `finalize-eval-package.ps1` owns the deterministic completion boundary and succeeds only after validating the freeze, bridge, complete grading, and all four report artifacts. A changed raw file requires a fresh Phase 1 execution, and prose cannot substitute for finalizer success. Optional scripted `interaction.json` sidecars provide deterministic same-session user turns only when the selected runner advertises and preflights that capability; ordinary single-turn runs remain unchanged.

```powershell
pwsh -NoProfile -NonInteractive -File ./scripts/prepare-skill-evals.ps1 -Changed -Runner codex
```

That resolves every skill the branch changed and prepares a package for each. `-Skill <name>` prepares one on demand, but execution selection must already be resolved to a runner; `-Runner codex` uses the Codex default, and `-Runner opencode` requires an explicit discovered `provider/model` selector. Direct noninteractive use without `-Runner` or `-CodebeltReference` fails before a handoff is generated. `scripts/Get-HarnessModels.ps1 -Runner <runner-id>` lists current model selectors for the selected harness and fails immediately with the supported runner IDs when `-Runner` is omitted. Use `-CodebeltReference` only when you want the script to select Codex CLI + `gpt-6-luna` with high reasoning; if that model is absent, the script fails and prints the current choices rather than substituting another model. Packages land in the gitignored `.bot/<skill>-workspace/`, so a harness that refuses to work outside the repository folder can still reach them without anything entering the working tree.

Each eval becomes a directory holding the grading key (`eval-metadata.json` with the expected output, assertions, and fixture and skill hashes) and prefilled result stubs, plus two paired run directories. `with_skill/` is a self-contained run root: a `prompt.md` with the effective skill instructions inlined, a `run.json` contract naming only paths inside the run, a `repo/` working tree materialized from the fixtures as real files, an isolated empty `home/`, and a `skill/<name>/` copy of the exact candidate revision. `without_skill/` is the same run with a byte-identical `repo/`, no `skill/` directory, and no mention of the skill. The grading key and results sit outside both run directories, so workers are not intentionally given them. Neither prompt identifies itself as an eval or names its configuration. `RUN-THIS.prompt.md` makes the user-selected agent the Eval Orchestrator: it reads the profile and selected runner descriptor. For runner-owned dispatch, it invokes the foreground `invoke-runner-owned-arms.ps1` Phase 1 command exactly once and sets the caller shell/tool timeout to at least the package-computed allowance. That helper owns the long-running preflight/fan-out/freeze implementation: it preflights every arm before execution, starts zero model executions when any preflight is incompatible, honors runner concurrency/backpressure, applies bounded child-process timeouts, registers terminal runner-produced evidence, and writes the immutable `execution-freeze.json` before grading. A caller timeout or interrupted conversation is not permission to rerun Phase 1; without a valid freeze the iteration is incomplete and requires a fresh package. For orchestrator-owned dispatch, the orchestrator uses the declared native worker transport. It preserves transport-owned raw evidence and uses `record-native-result.ps1` only for orchestrator-owned envelopes. After a successful Phase 1 freeze, the Grader writes only the grading artifact, then the deterministic application helper and finalizer perform the bridge, canonical projection, upstream aggregation/viewer compatibility, and first-party report generation. Missing telemetry is displayed as unavailable rather than estimated. A runner that cannot satisfy the mandatory experimental controls returns `incompatible`; lack of hard filesystem confinement downgrades the result to pragmatic isolation. If the selected external process cannot write valid runner-produced execution results at the manifest-declared paths, the evaluation is incomplete and fails closed; no response-only or reconstructed result is accepted. Packages land in gitignored `.bot/` storage by default and are not committed.

The four roles are intentionally separate: the Eval Runner is the harness-specific executor for one blind arm; the Eval Orchestrator coordinates the external handoff; the Grader assesses results only after execution; and the Human Reviewer remains the final evaluator. Behavioral evaluation is portable across supported runners. Native activation is harness-specific and out of scope for v0.9.1. Anthropic is the methodology and compatibility reference, not a required Claude runtime.

One more consistency rule matters for form-driven skills: native input fields are treated as a host feature, not something a model can rely on. Skills in this repo must stay usable with or without UI widgets, and must fall back to the same deterministic one-field-at-a-time flow when the host only supports plain chat.

Repo-level agent guidance also keeps progress updates user-facing: agents should report meaningful progress, evidence, blockers, and next steps without narrating sandbox mechanics, approved command paths, or retry plumbing unless those details affect approval, reproducibility, validation, or the final outcome.

Completion gates are equally strict: if repository guidance, a loaded skill, or the conversation summary marks a script-backed step as pending, critical, or blocking, agents must treat it as an active checklist item and may not claim completion until that command has run or the exact external blocker has been reported. In the DocFX workflow, that means `scripts/agents.cs` and the build-backed `scripts/docfx.cs --build-api-model --validate-samples --verify-docfx-build` verification are completion gates, not optional cleanup after the documentation files look done. The validator now emits a deterministic completion contract: `summary.fullVerificationRan` must be `true`, `summary.canClaimCompletion` must be `true`, `summary.remainingWorkItems` must be `0`, both `summary.remainingGates` and `summary.remainingDiagnosticsByCode` must be empty, and both `summary.newlyIntroducedSkipMarkers` and `summary.interimArtifacts` must be `0`. A clean fast run reports `verification-required`, not completion. Pre-existing gaps, large diagnostic counts, sample failures, unresolved symbol ownership, and documentation-caused DocFX build failures remain repair work; they are not permission to stop after a partial digest. Context pressure, session length, task size, repetitive authoring, or a stable queue are not escape hatches either; agents must shrink the batch, regenerate deterministic queue state, or report a true blocker instead of ending with a follow-up handoff. Cross-assembly collisions are clearable: exact type-UID example mappings resolve `SYMBOL_COLLISION_UNRESOLVED`, and exact-owner receiver-style calls resolve `EXTENSION_OWNER_AMBIGUOUS`. (The plain `scripts/docfx.cs` run is fast and build-free for iteration; the build-backed flags are what make the final gate authoritative.)

DocFX prose, cleanup, unresolved ownership, and skip-marker diagnostics are not softer backlog either. `EXAMPLE_LEAD_MISSING`, `EXAMPLE_ADVANCED_LEAD_MISSING`, `FAMILY_ANCHOR_EXAMPLE_MISSING`, `SAMPLE_STRUCTURE_INVALID`, `INTERIM_ARTIFACT_IN_WORKTREE`, `SYMBOL_COLLISION_UNRESOLVED`, `EXTENSION_OWNER_AMBIGUOUS`, `SAMPLE_SKIP_NOT_ALLOWLISTED`, and `FAIL_NEW_SKIP_MARKER_INTRODUCED` stay in the active repair queue until the JSON completion contract is clean, even after sample compilation and DocFX build verification have succeeded. Final handoff-shaped summaries are equally blocked while that queue is dirty. Repair and audit invocations (`--operation repair`, `--operation repair-csrun`, `--operation audit`) also enforce behavioral review accounting through a temporary/session ledger (`--init-behavioral-ledger` / `--behavioral-ledger`) reconciled independently against the authoritative example inventory, keeping `summary.canClaimCompletion` false while examples remain unreviewed, stale, transport-only, or unresolved; unrestricted multi-TFM `--build-api-model` isolates `MetadataLoadContext` per evaluated target framework so conditional APIs and transitive framework references resolve accurately, explicit `--framework` narrowing cannot satisfy a multi-TFM repository completion contract, and `generate-run-actions.ps1 --summary-json` separates previously cached transport status from fresh execution, explicit reuse, and behavioral verification.

The DocFX validator also treats fallback `docfx.json` discovery conservatively: if a repo lacks a live root DocFX workspace, scaffold/template configs under skill assets are ignored unless their metadata globs resolve real projects. That keeps placeholder files like `skills/dotnet-new-lib-slnx/assets/library/.docfx/docfx.json` from masquerading as the active documentation workspace during repo-wide audits.

Local skill synchronization is verified efficiently and mechanically: run deterministic tests against the repository source, then run `pwsh -NoProfile -File ./scripts/sync-skill-install.ps1 -Skill <name>` as the final step, which copies the whole skill tree to the three local installs and compares SHA-256 hashes across all four locations, exiting non-zero on any difference. Syncing a remembered list of touched files is not enough — that list goes stale on the next edit — and a sync claim must be backed by that command's output rather than an earlier run. Hash-identical copies are the same executable content, so agents do not repeat the same suites from an installed path unless install-path or loader behavior is specifically under test.

Resumed DocFX audits preserve every tracked and untracked documentation edit, regenerate the assessment work queue and example inventory, and process that queue in batches with a fast rerun after each batch. Encoding checks focus on actual damage: valid BOM-less UTF-8 is accepted, `ENCODING_BOM_MISSING` is not emitted, and audits do not create BOM-only or line-ending-only diffs.

DocFX guidance now also preserves working external links during prose rewrites unless a direct HTTP 404 justifies removal, keeps assessment/manifests/captured output/helper scripts in temp or session storage instead of the target repository, treats unexpected new repo-root or DocFX-workspace files that are not known skill deliverables as blocking cleanup work, and prefers inline or small sibling-batch prose repairs over slow per-page worker fan-out.

The DocFX validator now fails compiler-generated C# extension-block overwrite filenames at the layout gate and collapses literal, percent-encoded, and DocFX private-use `<G>$...` containers back to their authored outer static class in both YAML and reflection-backed API discovery. That prevents agents from creating or chasing unreadable synthetic files such as `EndpointConventionBuilderExtensions.G$6D0D8037DBBD61D10816ECA5F93B896F.md` after the readable declaring-class page already exists.

Final DocFX verification is machine-adaptive: `auto` selects a high-capacity profile above 8 available logical processors and 32 GiB available memory, overlaps isolated DocFX verification with API/sample work, and scales MSBuild workers up to half the available processors (capped at 16). Smaller machines stay conservative. Child-process timeout defaults to 30 minutes, and callers must allow at least 35 minutes so the validator can return its own timeout diagnostics. Long-running build, sample, and DocFX children also emit 10-second `stderr` heartbeats with phase, workload, runner count, PID, elapsed time, last-output age, and current output while keeping JSON stdout parseable; `--quiet` / `--no-heartbeat` suppresses start and heartbeat chatter when host stderr handling makes JSON inspection noisy, while retaining final child-process success/failure markers.

DocFX diagnostics favor repairable specificity: overwrite-layout errors now call out literal near-miss globs such as `api/namespaces/**.md` versus `api/namespaces/**/*.md`, no-observable-outcome example failures explain what visible reader result is missing, and common sample `CS1061` extension-method failures include missing-`using` hints such as `System.Linq` or `BenchmarkDotNet.Configs` when the compiler output points that way.

Use the metadata-only mode for the fastest feedback on every skill manifest, fixture path, and frontmatter description:

```powershell
pwsh -NoProfile -File ./scripts/validate-skill-templates.ps1 -MetadataOnly
```

During iteration, run the changed skill's bundled deterministic validator and focused regression scripts, overlapping independent checks. Only after explicit human approval for that full local run, run the whole CI matrix with the parallel scheduler:

```powershell
pwsh -NoProfile -File ./scripts/validate-local.ps1
```

The scheduler reads every suite from `.github/workflows/validate-skill-templates.yml`, so local and CI coverage stay aligned, and runs each one in a separate PowerShell 7 process with bounded concurrency, a streamed per-suite log, isolated fixtures, and per-suite exit codes. It enforces a per-suite timeout by killing the whole process tree, keeps running the remaining suites after a failure so one run reports every problem, and writes `summary.json` with the coverage counts next to the logs. It exits non-zero unless every CI-matrix suite exited zero and printed its terminal success marker, so a timeout or a silently skipped check is never reported as a pass. Use `-ListSuites` to print the resolved matrix, and `-MaxConcurrency`, `-TimeoutSeconds`, and `-DeadlineSeconds` to tune a run. Sequentially invoking the aggregate script or looping over the matrix one entry at a time is not permitted for agent-driven validation. If concurrent execution is unavailable, report the limitation. An explicit user instruction to skip or stop testing suspends validation for that session; report the work as unvalidated.

CI runs the complete validation set in 14 independent jobs with a five-minute budget per job. Template checks, PR workflow regressions, package preparation, runner regressions, and DocFX have separate jobs; runner conformance is split by transport and integrity tests by phase. Every job uses isolated temporary fixtures, and the existing `validate-skill-templates` required check passes only when every job succeeds. New commits cancel obsolete runs for the same pull request. Each job records its elapsed time in the Actions summary. For focused local validation, `-Suite Templates`, `-Suite Pr`, `-Suite Preparation`, or `-Suite Runners` selects a group, and `-Full -Suite Docfx` selects DocFX. The conformance and integrity test scripts also accept the `-Suite` values listed in the workflow. Agents default to focused checks for the changed skill or component. Each full local run of `scripts/validate-local.ps1` requires explicit human approval after its scope and cost are explained. Generic requests to test or finalize work do not grant that approval. Focused checks satisfy the local completion gate when a full run has not been approved. This partition changes scheduling, not the model-free validation contract.

## Install a skill

Install any skill directly from this repository with a single command:

```bash
npx skills add https://github.com/codebeltnet/agentic --skill <skill-name>
```

If an install path ever drops required files or dot-prefixed paths from a skill tree, treat that as an incomplete copy, verify the upstream repository contents, and manually restore the missing entries directly from the repository source tree before using the skill.

For example:

```bash
npx skills add https://github.com/codebeltnet/agentic --skill git-visual-commits
```

Then activate it in your agent. For example, in GitHub Copilot CLI:

```
Use the skill tool to invoke the "<skill-name>" skill.
```

## Always-on skills

Depending on the agent runtime, skills installed via `npx skills add` may live in `~/.claude/skills/`, `~/.agents/skills/`, and/or `~/.gemini/antigravity-cli/skills/`. Treat these as personal global skill folders: if you use multiple toolchains, keep repo-authored skills mirrored between them so each agent sees the same version. Either way, installed skills are **automatically loaded in every session** — no manual invocation needed. The agent reads the skill's description and activates it when relevant (e.g. you say "commit this" and the `git-visual-commits` skill kicks in).

If you want a bundle of skills always available, just install them all:

```bash
npx skills add https://github.com/codebeltnet/agentic --skill git-visual-commits
npx skills add https://github.com/codebeltnet/agentic --skill git-keep-a-changelog
npx skills add https://github.com/codebeltnet/agentic --skill git-nuget-release-notes
npx skills add https://github.com/codebeltnet/agentic --skill git-nuget-readme
npx skills add https://github.com/codebeltnet/agentic --skill git-visual-squash-summary
npx skills add https://github.com/codebeltnet/agentic --skill markdown-illustrator
npx skills add https://github.com/codebeltnet/agentic --skill git-repo-digest
npx skills add https://github.com/codebeltnet/agentic --skill trunk-first-repo
npx skills add https://github.com/codebeltnet/agentic --skill dotnet-strong-name-signing
npx skills add https://github.com/codebeltnet/agentic --skill dotnet-new-app-slnx
npx skills add https://github.com/codebeltnet/agentic --skill dotnet-new-lib-slnx
npx skills add https://github.com/codebeltnet/agentic --skill git-remote-release
npx skills add https://github.com/codebeltnet/agentic --skill git-remote-pr
npx skills add https://github.com/codebeltnet/agentic --skill dotnet-change-impact
npx skills add https://github.com/codebeltnet/agentic --skill dotnet-docfx-digest
npx skills add https://github.com/codebeltnet/agentic --skill dotnet-test
npx skills add https://github.com/codebeltnet/agentic --skill dotnet-csrun
npx skills add https://github.com/codebeltnet/agentic --skill dotnet-benchmark
npx skills add https://github.com/codebeltnet/agentic --skill dotnet-remote-testing
npx skills add https://github.com/codebeltnet/agentic --skill dotnet-segregated-assets
npx skills add https://github.com/codebeltnet/agentic --skill agent-smith
# npx skills add https://github.com/codebeltnet/agentic --skill another-skill
```

`skill-creator-agnostic` is intentionally omitted from the recommended always-on install list. It is **⚠️ Deprecated**, no longer maintained, and scheduled for removal in **1.0.0**; use Anthropic `skill-creator` plus this repository's `AGENTS.md` instead.

### Scoping options

| Location | Scope | When to use |
|----------|-------|-------------|
| `~/.agents/skills/` | All sessions, all projects | Global skills for agents that read the shared `~/.agents` install |
| `~/.claude/skills/` | All sessions, all projects | Your personal defaults — always on everywhere |
| `~/.gemini/antigravity-cli/skills/` | All sessions, all projects | Gemini Antigravity skills kept in sync with repo-authored skill copies |
| `.claude/skills/` (in a repo) | Project-scoped | Shared team conventions for a specific codebase |
| `.github/skills/` (in a repo) | GitHub Copilot / VS Code | When your team uses Copilot agent mode in the IDE |

> **Tip:** You can mix scopes. Install your personal favorites globally, and add project-specific skills to the repo so your whole team gets them. If you use multiple personal skill folders, mirror repo-authored skills to each one so sessions stay consistent.

## Available Skills

Each `SKILL.md` description is lean activation metadata. The catalog below explains what happens after a skill is selected.

When repo-managed skills author Markdown, each prose paragraph and list item stays on one physical line; rely on soft wrapping instead of fixed-width hard wraps.

| Skill | Description |
|-------|-------------|
| [git-visual-commits](skills/git-visual-commits/SKILL.md) | AI-driven git commit workflow with authoritative routing for `git bot commit`, `git commit`, and `git our commit`, including the exact `Please do a git bot commit yolo` form. It locks the requested identity, treats yolo/auto only as scoped auto-approval modifiers, never as the commit message, and does not hand commit execution to changelog or release-note skills. It uses deterministically validated emoji-first subjects, optional conventional prefixes only on explicit request, full-worktree semantic grouping unless narrowed, a visible multi-file single-category quality gate, commit bodies by default, and post-commit identity/body verification. Multi-file plans that initially collapse to one category also require a visible full-context quality gate; one-file changes keep the fast path. Stack-agnostic. |
| [git-keep-a-changelog](skills/git-keep-a-changelog/SKILL.md) | Git-aware Keep a Changelog companion selected only for explicit changelog or release-note intent. Bare yolo/auto and commit-execution requests such as `git bot commit yolo` do not activate it; both keywords enable identical autonomy and omit the `[Unreleased]` heading and footer link only after changelog intent is established, requiring an explicit version or version-prefixed branch. Bundled deterministic resolvers separate branch-unique commit history from merge-base-to-`HEAD` net diffs, exclude the previous-release or comparison boundary, fail on base-history bleed, and classify explicit path-backed release entities as `Added`, `Removed`, `Changed`, or `Unchanged`. The skill establishes each user-facing release entity against the base before section classification. It asks a mandatory `Yes / No / Custom` question before including pending worktree changes in ordinary concrete-release drafts, includes staged, unstaged, and untracked work automatically only in scoped yolo/auto mode, creates missing changelogs, writes SemVer-aware highlights, maintains compare-link footers, preserves natural prose wrapping, and curates surviving outcomes instead of dumping raw commit logs. |
| [git-nuget-release-notes](skills/git-nuget-release-notes/SKILL.md) | Git-aware NuGet release-notes companion for .NET repos that keep cumulative `.nuget/{ProjectName}/PackageReleaseNotes.txt` files. Uses the full current branch against its integration branch by default, treats same-named tracking branches as sync targets, and honors explicit ranges. A version-only invocation covers every packable `src/` project, including unchanged packages: each gets a complete version/availability block and non-empty ALM, using the required default text when no specific ALM outcomes exist. It creates missing files, reduces each package to its surviving base-to-`HEAD` delta before classifying history, and establishes each package capability against the base so pre-release refinements and fixes to a new capability remain one `ADDED` New Feature. It regenerates existing target-version blocks and verifies complete package coverage before handing the notes back for review. |
| [git-nuget-readme](skills/git-nuget-readme/SKILL.md) | Git-aware NuGet README companion for .NET repos that advertise a package from `src/`. Resolves the real packable project the README should sell, combines git history with actual package metadata, source capabilities, and relevant tests when feasible, preserves honest badge/docs/contributing sections, and writes a forthcoming, adoption-friendly `README.md` with repo-derived branding, clear value, install, framework-support, and quick-start guidance. |
| [git-visual-squash-summary](skills/git-visual-squash-summary/SKILL.md) | Non-mutating grouped-summary companion to `git-visual-commits`. Covers every surviving change on the full current feature branch across all contributors, using the merge-base with the repository base branch. Inventories every changed path and distinct outcome, recovers truncated diffs, and reconciles coverage before returning compact lowercase-start lines. No total line cap. Merges overlap and removes reverted churn while preserving small independent corrections, technical identifiers, and distinct dependency/version changes. Returns the summary directly without unnecessary scope or approval questions. |
| [skill-creator-agnostic](skills/skill-creator-agnostic/SKILL.md) | **⚠️ Deprecated** — no longer maintained and retained only for backward compatibility until **1.0.0**. Do not use it for new skill-authoring work; use Anthropic `skill-creator` together with this repository's `AGENTS.md`. |
| [markdown-illustrator](skills/markdown-illustrator/SKILL.md) | Reads a markdown file and answers directly in chat with one document-wide Visual Brief plus one compiled prompt. Infers a compact visual strategy by default, keeps follow-up questions near zero, and only branches when the user explicitly asks for added specificity. |
| [git-repo-digest](skills/git-repo-digest/SKILL.md) | Turns any full repository URL into a deterministic digest workspace using the bundled .NET file-based runner `scripts/digest.cs`. Requires explicit `--repo-url`, resolves omitted output paths to `<active-workspace>/.bot/digests` and passes that as `--output-root`, maps multiple positional URLs the same way for slash commands, bare pasted URLs, and natural-language requests by treating the first URL as the digest repo and every later URL as repeated `--external-repo-url`, always writes into `{output-root}/{repo-id}/{yyyyMMdd-HHmmssZ}`, accepts repeated curated public consumer repos, derives `{repo-id}`, fixes `result/`, performs shallow git clones, packs local tracked files with the bundled C# packer using `git ls-files`, separates XML evidence into `source.xml`, `tests.xml`, `projects.xml`, editorial `readmes.xml`, and scenario-only `external-usage.xml`, writes package and conceptual overview prompts under `prompts/`, emits public API summaries, engineering signals, evidence indexes, ordered XML chunks, referenced-package evidence maps for aggregate examples, and manifest-backed frontmatter hints, treats previous digest prose as contamination during fresh generation, then guides the agent to fully read the current phase's required evidence before writing package digests and a concept-led `result/Index.md` with YAML frontmatter containing Product-derived overview title metadata, validated documentation URLs resolved from PackageProjectUrl, documentation-host-filtered exact `.nuget/<PackageName>/README.md` documentation links including emoji-prefixed Documentation headings and "More documentation..." blocks, DocFX `metadata[].dest` API paths, and source namespace page candidates from `src/<PackageName>/**/*.cs`, target frameworks, package/library counts, external links, package-family links, and context glyphs, and validates authored result examples with `--validate-results` as a deterministic API-shape, Codebelt.Extensions.Xunit shape, PascalCase `MethodName_Scenario_ExpectedBehavior` test-method naming, Basic usage quality, and optimized NuGet-backed executable test gate with bounded parallelism. |
| [dotnet-new-lib-slnx](skills/dotnet-new-lib-slnx/SKILL.md) | Scaffold a new .NET NuGet library solution following codebeltnet engineering conventions. Dynamic defaults for TFM/repository metadata, latest-stable NuGet package resolution, tuning projects plus a tooling-based benchmark runner, TFM-aware test environments, xUnit v4 / Codebelt v12 tests with native MTP and Codebelt Coverlet coverage, strong-name signing, NuGet packaging, DocFX documentation, CI/CD pipeline, and code quality tooling. |
| [dotnet-new-app-slnx](skills/dotnet-new-app-slnx/SKILL.md) | Scaffold a new .NET standalone application solution following codebeltnet engineering conventions. Supports Console, Web, and Worker host families with Startup or Minimal hosting patterns; Web expands into Empty Web, Web API, MVC, or Web App / Razor, plus xUnit v4 / Codebelt v12 functional tests, native MTP with Codebelt Coverlet coverage, and a simplified CI pipeline. |
| [trunk-first-repo](skills/trunk-first-repo/SKILL.md) | Initialize a git repository following [scaled trunk-based development](https://trunkbaseddevelopment.com/#scaled-trunk-based-development). Seeds an empty `main` branch, creates a versioned feature branch (`v0.1.0/init`), confirms configured remotes in its post-init summary, and supports a guarded later `push remote <url>` mode that checks the feature-branch/empty-main state before pushing `main` ahead of the first feature branch so content still reaches main only through peer-reviewed pull requests. |
| [dotnet-strong-name-signing](skills/dotnet-strong-name-signing/SKILL.md) | Generate a strong name key (`.snk`) file for signing .NET assemblies using pure .NET cryptography — no Visual Studio Developer PowerShell or `sn.exe` required. Works in any terminal. Defaults to 1024-bit RSA (matching `sn.exe`), with 2048 and 4096 available as options. |
| [git-remote-release](skills/git-remote-release/SKILL.md) | Generate GitHub release notes by summarizing all commits and pull requests between two Git tags or branches in a remote GitHub repository. Accepts a compare URL or separate owner/repo, previous ref, and current ref values; falls back to comparing the current branch against the upstream default branch when no input is provided. Produces a human-friendly `## What's Changed` section whose first summary line begins `This release `, follows it with curated dash bullets using bold lead-ins and actual explanatory prose, optionally inserts supported GitHub alert blocks, preserves exact verified `Sources:` entries with contributor-complete GitHub logins, keeps em-dash bans scoped to authored prose rather than verbatim source titles, recognizes verified first-time contributors in a rich `## New Contributors` section immediately before Full Changelog, and ends with a compare link or the current-ref commits link for an initial release. Saves the notes as a Markdown file in a temporary working directory outside the repository and returns only an absolute Markdown file link. |
| [git-remote-pr](skills/git-remote-pr/SKILL.md) | Create or refresh a GitHub PR from the complete committed `base...head` changeset. Read-only preparation links a Markdown preview containing the exact proposed title and complete description, assignee, push need, and planned writes before approval; normal execution requires the exact displayed `approve APR-...` phrase and rechecks the write intent, approval-bound normalized review hash, and final preview hash. Material drift ends the approval transaction without regeneration; an explicit refresh starts a new workspace and approval ID. Same-request `yolo`/`auto` still shows the preview but skips the approval wait, executing only the just-presented ID. Existing PR bodies are rebuilt from the current final text diff into concise thematic summaries, with binary assets represented only by paths, statuses, and metadata. Case-insensitive theme coverage reports all mismatches together, and failures remain visible in noninteractive hosts. Draft corrections reuse one workspace. Untracked branches preview publication to GitHub origin (or the sole GitHub remote) under the current branch name, then establish tracking during execution. Dirty worktrees, ambiguous remotes, incomplete or mismatched tracking, divergent branches, and failed post-write checks block completion. Uses Git and `gh`, without Copilot or a browser. |
| [dotnet-change-impact](skills/dotnet-change-impact/SKILL.md) | Classify .NET library or NuGet package changes and recommend the correct release bump — `Major`, `Minor`, or `Patch` — for both Semantic Versioning (`MAJOR.MINOR.PATCH`) and .NET assembly/file versioning (`Major.Minor.Build.Revision`), grounded in Microsoft's official .NET compatibility rules. Uses the current Git branch by default when no explicit change details or compare range are provided, resolving it against the upstream/default base branch with local read-only git state. Always returns structured behavioral/binary/source/design-time/backwards compatibility reasoning with the recommendation, even when the bump is clear. |
| [dotnet-nuget-update](skills/dotnet-nuget-update/SKILL.md) | Audits and updates NuGet dependencies in .NET repositories with complete declaration accounting before any edit. It supports both `Directory.Packages.props` and project-level `PackageReference` versions, preserves XML structure and line endings, deduplicates package IDs, resolves independent live or offline flat-container version feeds with bounded parallel lookups and per-process memoization, uses bounded network timeouts, and merges results deterministically. Its single-process update runner keeps the audit, in-memory safe-update plan, and structural apply together for fast yolo passes. It keeps stable pins on stable candidates unless prerelease intent is explicit, and applies the TFM-band rule so conditional `net9`/`net10` package declarations stay within their matching major when that major is the compatibility signal rather than jumping to the newest overall release. Normal mode auto-applies revision/patch/minor and same-major prerelease updates, then batches majors for one approval decision; yolo mode applies only the auto classes and reports held majors without asking. |
| [dotnet-docfx-digest](skills/dotnet-docfx-digest/SKILL.md) | Audit and repair public .NET API documentation, verify example behavior, and optionally generate and verify Native and Docker run actions. |
| [dotnet-test](skills/dotnet-test/SKILL.md) | Moves xUnit projects onto Codebelt's entrypoint-owned test hosts, replacing Microsoft's ASP.NET-only `WebApplicationFactory`—and the hand-rolled `HostBuilder` that console and worker tests reach for because Microsoft ships no equivalent—with one family of abstractions where the application's own entry point owns startup. Invocation is the request: it inspects and refactors immediately instead of opening with a menu or a questionnaire. It deterministically inspects project roles, target frameworks, xUnit generation, package ownership, inheritance, application entry points—including Bootstrapper `MinimalConsoleProgram`, `MinimalWorkerProgram`, and `MinimalWebProgram` hosts—and every selected `WebApplicationFactory` usage; classifies ordinary unit, ASP.NET Core functional, and console/worker functional tests; modernizes xUnit v2 projects to xUnit v3 plus Microsoft Testing Platform without moving package ownership or changing frameworks; and resolves current stable compatible packages through NuGet-backed isolated compatibility-project restores, including the selected combined package set. Focused web tests use `WebApplicationTestFactory` with an explicit entrypoint-owned `ManagedWebApplicationFixture`, directly or through a narrow `Test`-derived harness; shared web fixtures use `WebApplicationTest` with `ManagedWebApplicationFixture`; focused console/worker tests use `ApplicationTestFactory` with `ManagedApplicationFixture`; and shared non-web fixtures use `ApplicationTest` with `ManagedApplicationFixture`. Deprecated blocking fixtures are migration inputs only and are never emitted because they are scheduled for removal. Functional migrations fail closed unless the chosen Codebelt pattern and managed fixture are present, the legacy or blocking fixture is absent, and test code does not reconstruct the production composition root with its own `WebApplication`, `TestServer`, or `HostBuilder`. Migrations preserve entrypoint-owned startup, host configuration, lazy start, clients, services, configuration, sync/async disposal, isolation, and existing test names, while fresh bootstraps add source-grounded behavior tests. Non-web tests stay in-process and require a resolvable Generic Host; test-only scope reports the exact production adaptation instead of silently rewriting startup or launching a process. |
| [dotnet-csrun](skills/dotnet-csrun/SKILL.md) | Creates, verifies, repairs, and audits C# examples and genuine xUnit v3 tests, with paired Native and Docker commands from one manifest, exact package pins, and source-linked execution evidence. Published commands verify and run the latest stable csrun release from GitHub, while skill-driven verification and multi-example sweeps resolve and cache the SHA-256-verified `csrun.ps1` locally once (`Resolve-CsrunEngine` + `-EnginePath`) with ETag revalidation and rate-limit fallback to avoid exhausting GitHub's unauthenticated REST quota. |
| [dotnet-benchmark](skills/dotnet-benchmark/SKILL.md) | Discovers, prioritizes, and authors trustworthy BenchmarkDotNet experiments for a .NET type following codebelt conventions and using the `Codebelt.Extensions.BenchmarkDotNet.Console` runner. It inspects implementation code, call sites, tests, existing benchmarks, and available profiles instead of benchmarking every public member; ranks likely high-impact operations; selects representative typical, boundary, scaling, and adverse cases; and rejects external-I/O or service-level questions that need profiling, macrobenchmarks, or load tests. It creates fair current-versus-candidate comparisons only when observable work is equivalent, uses baseline-free single-operation characterization when no honest comparator exists, prevents unrelated construction/formatting/equality/hash ratios, requires exact per-case correctness oracles plus a semantic preflight for truthful workload labels, hard-gates interpretation on a complete valid BenchmarkDotNet summary, preserves workload invariants such as selectivity and hit/miss ratios as sizes scale, distinguishes deferred pipeline creation from terminal/materialization work, and performs Release build, discovery listing, and dry execution before any explicit full run. Explicit `yolo` mode auto-accepts routine repo-derived defaults and the proposed plan, then proceeds through build/list/dry validation without confirmation churn; only a separate explicit human instruction can start a full performance run. Its runner preflight recognizes the standard Slim/runtime setup and explains when `SkipBenchmarksWithReports = true` plus a matching `reports/tuning/` artifact deliberately filters a benchmark, preventing needless class renames, disassembly, or tool thrash; after the first valid full result it stops unless deeper diagnostics could change a real engineering decision. Harness setup remains adaptive: it detects `.slnx`/`.sln`, CPM, existing `tuning/` projects, and a reusable `tooling/` runner, onboards only missing pieces, resolves package versions dynamically, and keeps the benchmark class in the SUT namespace. |
| [dotnet-remote-testing](skills/dotnet-remote-testing/SKILL.md) | Run .NET tests inside a resolved remote Docker environment and return concise, structured results — Visual Studio's Remote Testing experience (choose an environment → run tests → see results) with the container plumbing hidden behind a deterministic runner (`scripts/remote-test.cs`) the skill orchestrates instead of composing ad-hoc `docker run` commands. Invoking it is the request: with one applicable Docker environment it runs immediately — no capability menu, no parameter questionnaire, no confirmation — and when several channels are derived, the repository's own highest target framework selects the matching one and the choice is reported. The runner decides when a question is unavoidable, exiting `SelectionRequired` (16) with the exact candidates, and every exit code maps to exactly one next action so behavior is identical across models. It honors Microsoft's existing `testenvironments.json` version-1 contract (`name`, `localRoot`, `dockerImage`, `dockerFile`, with the either/or Docker-source rule), treats that file as authoritative when present, and reports WSL/SSH/unknown types as unsupported rather than converting or silently ignoring them. When no `testenvironments.json` exists it provides a zero-configuration experience built exclusively on official `mcr.microsoft.com/dotnet/sdk` images, discovering the currently supported LTS and STS channels plus the current preview from Microsoft's live `releases-index.json` using `support-phase`/`release-type` (never hardcoded version numbers or even/odd assumptions) and caching that metadata outside the repository for offline reuse. It prefers an exact `latest-sdk` image tag (stripping preview build metadata), validates the tag against Microsoft's registry, and pins each execution to the resolved immutable digest so results are reproducible across environment, image, digest, SDK, and architecture. Execution stages the source into an isolated workspace so container builds never leave Linux `bin`/`obj` in the working tree, mounts a persistent NuGet cache outside the repo, runs restore → build → test with structured TRX collection, classifies failures into distinct kinds (configuration, unsupported environment, Docker unavailable, image resolution, SDK incompatibility, staging, restore, compilation, test-host, test failure, result-processing, cleanup, cancellation, release-metadata) so infrastructure problems are never reported as failing unit tests, and always cleans up transient Docker resources. It never generates a `Dockerfile`, dev container, compose file, or editor configuration (an existing configured `dockerFile` is honored, never created), never runs privileged containers or mounts the Docker socket, and never silently falls back to running tests on the host. Docker is the only transport for now, designed so WSL/SSH can be added later without disturbing the deterministic Docker path, which is covered by a comprehensive built-in `--self-test` plus a PowerShell harness. |
| [dotnet-segregated-assets](skills/dotnet-segregated-assets/SKILL.md) | Migrate or configure ASP.NET Core static delivery with `codebeltnet/web-cdn-origin:2.0.0` while keeping `wwwroot` as the authoring root. The deterministic runner inspects and verifies topology, publish exclusion, Static Web Assets risks, Cuemon signals, competing `AppAssetOptions`-style abstractions, actual `app-*`/`cdn-*` markup, and scheme-safe local origins; the agent performs semantic edits. For an existing Cuemon package reference, its plan resolves the highest stable version from NuGet.org at execution time, preserves Central Package Management versus inline ownership, excludes prereleases, and fails rather than copying an old fixture or example version. It reuses Cuemon `AppTagHelperOptions`/`CdnTagHelperOptions`, `BaseUrlMode`, and the public `app-link`, `app-script`, `app-img`, `cdn-link`, `cdn-script`, and `cdn-img` helpers when already available, otherwise reuses a suitable project abstraction without adding Cuemon. It keeps App and shared CDN ownership separate, preserves ordinary Project-based Development, adds opt-in segregated Development through a root Docker Compose profile, and makes `compose.assets.yml` directly build artifact-first `LocalDevelopment.Dockerfile` and `Assets.Dockerfile` images. Every generated file comes from a literal template in `assets/` and lands in one fixed location — the three Dockerfiles beside the web `.csproj`, orchestration at the repository root — and `verify --check-local` proves that placement along with the artifact-first contract: no SDK stage or `dotnet publish` inside an application image, a `.dockerignore` that still carries `artifacts/`, `LocalPublishDirectory` behind a guarded post-build target, Compose host ports derived from the ordinary Project profile, and a CI job that produces the artifact those images copy. Production CI publishes the same application artifact for the shell-less runtime `Dockerfile`. The skill excludes app-owned `wwwroot` with targeted MSBuild metadata, preserves `_content`/`_framework` and generated Static Web Assets, and proves publish/local invariants deterministically and idempotently. |
| [agent-smith](skills/agent-smith/SKILL.md) | Apply a coherent, evidence-driven engineering operating model: consistency, quality, vigilance, due diligence, narrow consumer contracts, explicit failure over false success, immutable artifact promotion, and proportional automation. Includes deliberate AI capability selection and bounded orchestration. | Invoke `/agent-smith <task>` or use for architecture, implementation, API compatibility, testing, performance, security/DevSecOps, CI/CD, documentation, governance, skill authoring, agentic engineering, and .NET EditorConfig remediation. Local policy wins; specialized procedures load through references. |

### Copyable Install Commands

If your Markdown viewer supports code-block copy buttons, each command below should be directly copyable.

`git-visual-commits`

```bash
npx skills add https://github.com/codebeltnet/agentic --skill git-visual-commits
```

`git-keep-a-changelog`

```bash
npx skills add https://github.com/codebeltnet/agentic --skill git-keep-a-changelog
```

`git-nuget-release-notes`

```bash
npx skills add https://github.com/codebeltnet/agentic --skill git-nuget-release-notes
```

`git-nuget-readme`

```bash
npx skills add https://github.com/codebeltnet/agentic --skill git-nuget-readme
```

`git-visual-squash-summary`

```bash
npx skills add https://github.com/codebeltnet/agentic --skill git-visual-squash-summary
```

`skill-creator-agnostic` **⚠️ Deprecated — legacy compatibility only**

```bash
npx skills add https://github.com/codebeltnet/agentic --skill skill-creator-agnostic
```

No longer maintained. Scheduled for removal in **1.0.0**. Do not install it for new work; use Anthropic `skill-creator` and apply the repository rules in `AGENTS.md`.

`markdown-illustrator`

```bash
npx skills add https://github.com/codebeltnet/agentic --skill markdown-illustrator
```

`git-repo-digest`

```bash
npx skills add https://github.com/codebeltnet/agentic --skill git-repo-digest
```

`dotnet-new-lib-slnx`

```bash
npx skills add https://github.com/codebeltnet/agentic --skill dotnet-new-lib-slnx
```

`dotnet-new-app-slnx`

```bash
npx skills add https://github.com/codebeltnet/agentic --skill dotnet-new-app-slnx
```

`trunk-first-repo`

```bash
npx skills add https://github.com/codebeltnet/agentic --skill trunk-first-repo
```

`dotnet-strong-name-signing`

```bash
npx skills add https://github.com/codebeltnet/agentic --skill dotnet-strong-name-signing
```

`git-remote-release`

```bash
npx skills add https://github.com/codebeltnet/agentic --skill git-remote-release
```

`git-remote-pr`

```bash
npx skills add https://github.com/codebeltnet/agentic --skill git-remote-pr
```

`dotnet-change-impact`

```bash
npx skills add https://github.com/codebeltnet/agentic --skill dotnet-change-impact
```

`dotnet-docfx-digest`

```bash
npx skills add https://github.com/codebeltnet/agentic --skill dotnet-docfx-digest
```

`dotnet-benchmark`

```bash
npx skills add https://github.com/codebeltnet/agentic --skill dotnet-csrun
npx skills add https://github.com/codebeltnet/agentic --skill dotnet-benchmark
```
`dotnet-nuget-update`

```bash
npx skills add https://github.com/codebeltnet/agentic --skill dotnet-nuget-update
```
`dotnet-test`

```bash
npx skills add https://github.com/codebeltnet/agentic --skill dotnet-test
```
`dotnet-remote-testing`

```bash
npx skills add https://github.com/codebeltnet/agentic --skill dotnet-remote-testing
```
`dotnet-segregated-assets`

```bash
npx skills add https://github.com/codebeltnet/agentic --skill dotnet-segregated-assets
```
`agent-smith`

```bash
npx skills add https://github.com/codebeltnet/agentic --skill agent-smith
```

### Why git-visual-commits?

Commit messages are the most-read documentation in any codebase — yet they're usually an afterthought. "fix stuff", "wip", "address PR feedback" tells you nothing six months later. Writing good commits takes discipline, and when you're in flow, it's the first thing that slips.

**git-visual-commits** handles the entire commit workflow— staging, diffing, crafting the message, choosing the right emoji — so every commit is consistent and meaningful without breaking your flow. Whether the agent authors the commit (`git bot commit`), you do (`git commit`), or you worked on it together (`git our commit`), the quality is the same.

- **Gitmoji-first** — visual commit categories that are scannable at a glance
- **Read-through-EOF lock first** — the first critical rule requires the agent to finish truncated or partial SKILL.md reads before staging or committing
- **Deterministic subject gate** — a bundled PowerShell validator blocks unapproved emoji, wrong separator spacing, uppercase description beginnings, and subjects longer than 70 characters before the plan and again before Git
- **Emoji-first by default** — the normal subject shape is `<emoji> <description>`, not `<emoji> <prefix>: ...`
- **Conventional-prefix combo is opt-in** — `init`, `content`, `style`, `fix`, `refactor`, and `docs` are available only when you explicitly ask to combine emoji with conventional-commit prefixes
- **Three identity modes** — bot, human, or collaborative — the agent does the work either way, you choose who gets credit
- **Authoritative command routing** — `Please do a git bot commit yolo` always selects this workflow, locks bot identity, and treats yolo as auto-approval rather than a message or changelog trigger
- **CLI override remains deterministic** — `/git-visual-commits git bot commit yolo` bypasses automatic skill selection when explicit invocation is preferred
- **Identity lock stays honest** — `git bot commit` means bot attribution, not just "AI did the work", and the flow now verifies the resulting author after commit
- **Direct git execution for bot identity** — identity-sensitive commit paths should use direct shell/terminal git commands, not wrappers that may bypass aliases
- **Large-diff review stays bounded** — starts with diff stats, narrows to path-specific or other bounded reads, and uses verified OS temp storage outside the repo only as a cleanup-verified fallback
- **Clarifies before correcting** — vague feedback like "4 is wrong" triggers a short question, not a guessed revert or regrouping
- **Evidence-backed explanations** — emoji and grouping justifications stay tied to references actually inspected in the session
- **Reference-validated emoji choices** — the workflow reads the bundled `commit-language.md` skill resource before proposing commit subjects and does not treat a missing repo-root `references/` folder as the same thing as a missing skill reference
- **Community health uses `💬`** — changelogs and repo-health / release-status communication are treated as human-facing messaging, not generic `📝` or `📚` docs by default
- **Skill refactors map to refactor intent** — reorganizing an existing skill's wording or eval contract should land on `♻️`, not a guessed new-feature or config emoji
- **Auto-approval** — say "yolo" or "auto" within a commit request to skip the review gate when you trust the agent's judgment
- **No `yolo`, no commit** — without `yolo` / `auto` or an already-enabled auto mode, the workflow must stop at the plan and wait for approval before it commits anything
- **Yolo skips confirmation, not discipline** — auto-approval still requires semantic grouping, mixed-scope checks, and a visible commit plan summary before committing
- **Full worktree by default** — plain `git bot commit yolo` means "commit everything currently in git status and group it correctly", not "guess a narrower slice"
- **Commit body by default** — every commit explains *why*, not just *what* — opt out with "tmi" or "no-body"
- **Commit bodies are verified after write** — the workflow now checks the stored commit body so literal escape sequences like `\n` do not leak into history
- **Short bodies stay readable** — the workflow no longer hard-wraps short commit bodies at 72 characters, treats mid-sentence wrapping as a verification failure, and repairs the commit instead of leaving noisy prose in history
- **Repo capability additions stay explicit** — adding a brand-new skill is grouped separately from refactoring an existing skill to support it
- **Shared wording rules stay in lockstep** — the duplicated `commit-language.md` reference is kept byte-for-byte identical across both git-visual skills and checked locally plus in CI
- **Semantic intent splitting** — groups commits by rationale, not just file type — config and test logic are always separate
- **Single-category context gate** — when more than one file initially appears to fit one category, the agent must visibly re-confirm the full skill read, full diff review, and per-file rationale before retaining that category; a one-file change keeps the fast path
- **Same-round edits are not one commit by default** — temporal proximity never outranks semantic intent when grouping changes
- **Release-adjacent work still splits cleanly** — dependency baselines, package metadata, community health docs, doc publishing fixes, and CI automation can belong in separate commits even when they land together
- **Package release notes are `📦` work** — `.nuget/*/PackageReleaseNotes.txt` belongs with package/publish metadata, not with `💬` community-health communication
- **Tool-path failures fail fast** — a wrong-author first attempt means switch execution path immediately instead of retrying the same broken wrapper
- **Recovery stays conservative** — prefer inspecting git state and stashing before broad restore/reset commands when commit repair goes sideways
- **Umbrella commits are rejected** — mixed diffs spanning skill instructions, templates, validators, and repo docs must be split into separate commits instead of bundled into one blob
- **Stack-agnostic** — works with any language, framework, or project type
- **Squash-and-merge friendly** — structured commits make PR squash summaries read like a changelog

### Why git-visual-squash-summary?

Sometimes the history is already written and the only thing you need is the final grouped summary. `git-visual-squash-summary` inspects the complete branch diff across every contributor and accounts for every surviving change in grouped lines. It merges repeated work without dropping independent corrections, and adds as many lines as complete coverage requires.

- **Same visual language** — reuses the same emoji-first wording rules as `git-visual-commits`, including lowercase descriptions after the emoji unless a leading technical identifier requires original casing
- **Grouped-lines only** — returns compact grouped lines only, not a title or body
- **Non-mutating by design** — drafts the wording only and does not touch git state
- **Whole-branch by default** — for squash-and-merge requests, uses the full current feature branch from merge-base to `HEAD` instead of asking which branch commits to include
- **All authors included** — branch-level summaries treat branch topology as the scope and include every contributor's commits unless the user explicitly asks for an author-filtered summary
- **Bare invocation means summarize now** — calling `git-visual-squash-summary` directly should resolve the current branch scope automatically and return the grouped lines, not a "what do you want me to summarize?" question
- **The summary is the acknowledgment** — the first response is the grouped lines themselves, never an "I understand the instructions" recap followed by "would you like me to generate it now?"
- **Base branch, not tracking copy** — a feature branch that is in sync with `origin/<current-branch>` is still summarized against `origin/HEAD`, `origin/main`, `origin/master`, `main`, or `master` before declaring there is nothing to summarize
- **No yolo prompt** — the skill is read-only, so it acts directly without asking for auto-approval language from mutating workflows
- **No commit-picker UX** — ordinary branch-level squash requests do not become commit-selection questions or widgets; the skill resolves the branch scope and writes the summary
- **Distinct efforts stay distinct** — preserves meaningful change groups instead of forcing one umbrella line
- **Final-state first** — computes the cumulative base-to-`HEAD` delta before reading chronology, so reverted experiments and temporary implementations disappear
- **Surviving dependency truth** — package/version changes stay explicit when they survive in the final diff and disappear entirely when they return to the base value
- **Intent over chronology** — collapses noisy commit stacks into the retained grouped effort
- **Complete coverage** — checks every changed path and distinct outcome against the summary, retrieving missing portions of truncated diffs before finishing
- **Small changes count** — independent typo fixes, tests, CI, configuration, assets, and file-mode changes remain represented, even when larger features dominate the branch
- **Late release-prep commits stay in scope** — surviving changelog, version-bump, and release-finalization changes get explicit coverage in a related group or their own line
- **Identifier-safe wording** — preserves technical names, paths, flags, and types where possible
- **Readable in GitHub and terminals** — optimized for compact PR and squash-summary views
- **Strict 72-char lines** — every summary line stays compact and scannable, with no total line cap
- **Not a changelog** — avoids release-note phrasing and commit-subject dumps
- **No unsupported claims** — summarizes only what the inspected diff can justify

### Why git-keep-a-changelog?

On repeated runs, the entity resolver checks each proposed bullet section against the full release baseline. A new unreleased capability permits only `Added`, so later fixes and refinements stay within its introduction instead of accumulating under `Changed` or `Fixed`.

Writing `CHANGELOG.md` well is harder than it looks. Raw commit subjects are too noisy, PR titles often miss migration context, and release notes get much better when the writer actually reads the commit bodies and understands the net diff. That is where **git-keep-a-changelog** fits: it turns the current branch into a curated Keep a Changelog entry and creates or updates the file directly for review.

The skill establishes each outcome's identity, scope, before/after state, and supporting evidence before drafting. It then reviews every factual clause in the written entry, including retained draft text and the release highlight. Commit wording and existing prose cannot substitute for evidence of a rename, version upgrade, behavioral change, or dependency relationship.

- **Keep a Changelog first** — writes `Added`, `Changed`, `Deprecated`, `Removed`, `Fixed`, and `Security` sections in the expected style
- **Full-commit context** — reads complete commit messages and the net diff before writing
- **History is evidence, result is truth** — reduces the selected range to surviving base-to-`HEAD` outcomes before section classification, so reverted work disappears and one surviving capability is described once
- **Unreleased draft rewrites** — if a version-branch heading already exists but its tag does not, the skill regenerates that draft from git truth so new-capability refinements stay under `Added` until release
- **Deterministic release isolation** — resolves the real comparison branch, excludes its merge boundary, and verifies that no commit already on the base branch can bleed into the new release
- **PR-complete history** — keeps every branch-unique commit from every contributor while avoiding a same-name feature tracking ref as the comparison base
- **Cumulative dependency coverage** — when version manifests changed across the release range, diffs them from base to `HEAD` so the changelog reflects the surviving package/version story instead of only per-commit fragments
- **Explicit dependency removals** — names outgoing packages under `Removed`, including test/build tooling, while retaining useful replacement context under `Changed`; distinguishes actual removals from moved references, reverted changes, and runtime impact
- **Whole-branch by default** — treats the selected branch or range as author-agnostic scope, so all contributors' commits are in play unless you explicitly narrow by author
- **Version-aware by branch** — uses a branch prefix like `v0.3.0/...` as the release heading hint when present
- **Mandatory pending-worktree gate** — when a concrete release has uncommitted changes, the skill must ask a short `Yes / No / Custom` confirmation question before folding them into the changelog draft, with a `FORMS.md` definition that compatible hosts can render as native choices
- **Trigger isolation** — yolo/auto modifies an explicit changelog request but never activates this skill for `git bot commit yolo` or another commit-execution request
- **Scope-safe yolo/auto mode** — both keywords include staged, unstaged, and untracked work automatically without changing the committed-history boundary; omit the `[Unreleased]` heading and footer link on creation, updates, and reruns, while preserving concrete-version compare links and safely reconciling existing entries. Requires an explicit version or version-prefixed branch
- **SemVer-aware highlight** — always writes a short release TL;DR that explicitly says `major`, `minor`, or `patch`
- **Creates the file when needed** — seeds a compliant `CHANGELOG.md` if the repo does not have one yet
- **Natural prose** — preserves human-readable line breaks without any fixed-width wrapping target
- **Predictable bullet punctuation** — bullets end with `,` and the last bullet in each section ends with `.`
- **Direct file edit** — creates or updates `CHANGELOG.md` directly, then stops for human review
- **Compare-link aware** — can update bottom-of-file compare links when a concrete release heading is added
- **Not a commit dump** — curates the release story instead of copying git log output into Markdown

### Why git-nuget-release-notes?

Repo-wide changelogs are useful, but NuGet packages often need package-scoped release notes that match the package actually being published. In codebelt-style repos, that means cumulative `.nuget/{ProjectName}/PackageReleaseNotes.txt` files with a very specific shape: concrete version and availability lines, `# ALM` first, and only the sections that the package really earned.

**git-nuget-release-notes** reads the actual git history and net diff per packable `src/` project, resolves the package version and target framework availability, then updates the package-note files directly for review.

- **Per-package, not repo-wide** — writes one truthful release block per publishable assembly/package
- **Complete release coverage** — version-only requests update every packable `src/` project, including unchanged packages; each gets resolved availability and non-empty ALM with the required default text when needed
- **Concrete package metadata** — resolves `Version:` and `Availability:` from the branch/project instead of inventing placeholders
- **Full branch by default** — compares against the integration branch instead of only the unpushed commits; a version-only invocation edits the notes without an unnecessary range question
- **Draft regeneration** — recomputes an existing target-version block from the entire resolved delta while preserving older released blocks; explicit ranges still override the default
- **Package delta first** — resolves public APIs, dependency versions, TFMs, and package metadata from base to `HEAD` before using history as supporting context
- **Reverted churn disappears** — temporary upgrades, removed-then-restored APIs, and other cancelled work do not reach the final release block
- **Current codebelt format** — follows the established `ALM`, `Breaking Changes`, `New Features`, `Improvements`, `Bug Fixes`, and optional `References` blueprint
- **Missing-file aware** — can create `.nuget/{ProjectName}/PackageReleaseNotes.txt` when a packable project should be represented
- **History-aware** — preserves cumulative newest-first package history instead of overwriting older entries
- **Not a commit dump** — uses full commit bodies plus the net diff and avoids line-by-line subject replay

### Why git-nuget-readme?

Choosing a NuGet package often happens fast: a developer lands on the README, scans the first screen, checks whether the package fits the problem, and looks for install guidance, supported frameworks, docs, and a quick example. If those signals are vague or buried, the package loses the moment even when the code is good.

**git-nuget-readme** uses the actual git history, project metadata, and source-level capabilities of the advertised package to refresh the README into something that is both truthful and easier to adopt.

- **Package-first README focus** — centers the README on the real packable project the repo is advertising
- **Devex-led structure** — pulls value proposition, installation, framework support, docs, and quick-start guidance closer to the top
- **Grounded sales copy** — improves the package pitch without inventing features, benchmarks, badges, or docs URLs
- **Source-backed examples** — prefers real namespaces, package IDs, capability areas, and test-backed usage hints from the codebase
- **Repo-derived identity** — uses the current repo's own naming and branding conventions instead of importing a `by <brand>` pattern from another package family
- **Preserve the good parts** — keeps accurate badges, docs links, contributing guidance, and license sections when they are already working
- **Not a changelog in disguise** — uses git history for context but writes adoption-oriented README copy instead of replaying commit subjects

### Why skill-creator-agnostic is deprecated

`skill-creator-agnostic` is now a legacy compatibility artifact, not an active skill-authoring workflow. It is **⚠️ Deprecated**, no longer maintained, and scheduled for removal in **1.0.0**. Its references are retained for backward compatibility only; they do not replace Anthropic's supported `skill-creator` workflow.

For new skill creation, modification, and benchmarking:

- Use Anthropic `skill-creator` directly
- Apply this repository's skill-authoring, eval, sync, and validation rules from `AGENTS.md`
- Do not treat `skill-creator-agnostic` as a fallback, overlay, or parallel implementation

### Why git-repo-digest?

Repository digest generation works best when deterministic evidence gathering is separated from AI-authored prose. **git-repo-digest** owns that split: its bundled .NET file-based runner creates the manifest, instructions, XML evidence files, Markdown prompts, public API summaries, engineering signal maps, evidence indexes, and ordered XML chunk files; the agent writes the package digests and overview.

- **Bundled C# runner** - ships `scripts/digest.cs`, run with `dotnet run --file`, so the skill is self-contained without a full project file
- **Single local packing path** - performs one shallow `git clone`, then packs tracked files from that clone with the bundled C# packer instead of calling Node/npm, Repomix, browser automation, or a public packing service
- **Deterministic file membership** - uses `git ls-files`, evidence classifiers, text-file detection, generated-directory skips, and low-signal filtering so the evidence source is transparent and repeatable
- **Repository-generic input** - starts from a full repository URL and an explicit or skill-defaulted output root instead of assuming an owner/slug convention
- **KISS contract** - `--repo-url` is required, `--output-root` is always passed explicitly and defaults to `<active-workspace>/.bot/digests` when omitted, `--external-repo-url` is optional and repeatable, `{repo-id}` is derived, `{run-id}` is generated as `yyyyMMdd-HHmmssZ`, and `result/` is fixed
- **Unambiguous URL mapping** - treats the first repository URL as the digest target and every later URL as curated external usage evidence whether the user writes a slash command, pastes bare URLs, or phrases the request in prose; only a non-URL second value can become `output-root`, and independent multi-repo digests require explicit wording such as "digest both repos separately"
- **Codebelt-flavored staging root** - uses `<active-workspace>/.bot/digests` when no output path was supplied, producing `.bot/digests/{repo-id}/{yyyyMMdd-HHmmssZ}` without a follow-up prompt; explicit output paths are still respected as the root of `{output-root}/{repo-id}/{yyyyMMdd-HHmmssZ}`
- **Fresh evidence by default** - treats a bare repository URL as a new runner execution even when `{output-root}/{repo-id}` already contains older run folders; existing workspaces are reused only when the user explicitly provides a workspace path or asks to reuse, continue, inspect, validate, or repair prior output, and previous digest prose from sibling runs, website copies, docs copies, or other folders is contamination rather than evidence during fresh generation
- **Tool output is authoritative** - reads `manifest.json`, `instructions.md`, and one package evidence set at a time instead of reconstructing scope from memory
- **YAML frontmatter contract** - records `frontmatterHints` in manifest targets and generated prompts so `Index.md` and package pages begin with metadata for title, description, lede, target framework names and monikers, license, package/library counts, important external links with context glyphs, and `familyLinks` entries for every package page using internal `.md` URLs plus glyphs derived from `.nuget/*/README.md` Related Packages sections when available; the `Index.md` title comes from repository-owned `<Product>` metadata in root `Directory.Build.props` or the most-referenced top-level packable `.csproj`, documentation links come from `PackageProjectUrl` first, documentation-host-filtered exact `.nuget/<PackageName>/README.md` documentation links second including emoji-prefixed Documentation headings and package-local "More documentation..." blocks, `.docfx/**/docfx.json` `metadata[].dest` API paths when package metadata names the package, and source namespace page candidates from `src/<PackageName>/**/*.cs`, while packages without DocFX API entries reuse the overview docs root, and generation fails instead of falling back to the URL-derived repo id or broken documentation links when required metadata cannot be resolved
- **Public API first** - adds a generated public API summary so agents can orient around consumer-facing types, inheritance chains, and likely key members before reading the raw source
- **Engineering signal map** - highlights source-backed places to inspect for validation guards, abstractions, extension points, lifecycle callbacks, factories, hosting styles, and owned test evidence so package digests can explain the engineering decisions instead of listing APIs mechanically
- **Codebelt test ownership** - discovers packages from `src/` and owned tests from `test/`, mapping only Codebelt-style `.Tests` and `.FunctionalTests` projects or one unambiguous direct project reference instead of scanning generic `tests/` roots or broader suffix variants
- **Low-signal filtering** - removes `GlobalSuppressions.cs` from packed evidence while keeping internals available when they explain public behavior
- **Authority-separated evidence** - writes `source.xml` for API shape, `tests.xml` only from the discovered owned `test/` path for intended usage, `projects.xml` for project metadata and package relationships, and `readmes.xml` as editorial context only
- **Curated external usage** - accepts user-provided public consumer repositories, clones them locally, rejects the digest repo itself, fails fast when a provided external repo cannot be cloned, and writes reference-plus-code matches to `external-usage.xml`, including package references declared in project files or nearest ancestor `Directory.Build.props` / `Directory.Build.targets`, plus generic package-graph matches where an external project references a discovered package that transitively includes the current package and source or test code uses the current package's namespace or package id
- **Usage-realistic examples** - lets `## Basic usage` prefer source-valid external usage scenarios when they are clearer than maintainer-owned tests, requires normal package examples to be complete Codebelt.Extensions.Xunit snippets with file-scoped namespaces that inherit from `Test` directly or through source-backed Codebelt test bases discovered from the evidence type graph, wire `ITestOutputHelper` through the base constructor, and use `TestOutput.Write`, `WriteLine`, or `WriteLines` for human-friendly context instead of top-level smoke tests, showcases package-owned base classes and lifecycle hooks when they are the intended extension model, steers collector/logger/store/fixture/factory/host examples toward indirect producer-consumer or pipeline scenarios, avoids greeting/message/sample filler, keeps convenience-package examples direct but distinct, gives aggregate packages referenced-package evidence paths, and keeps the declaring package's current source evidence authoritative for every API call and property access
- **Deterministic result validation** - adds `--validate-results --workspace <workspace>` so authored result examples are checked against package-owned source evidence; unsupported member access is reported as a blocking API-shape error, malformed Basic usage sections, non-Codebelt-style xUnit snippets, non-PascalCase `MethodName_Scenario_ExpectedBehavior` test-method names, and low-signal Basic usage patterns such as toy/greeting examples or direct write-then-read helper round-trips are reported as deterministic quality diagnostics, and each Basic usage C# block is run in a temporary Codebelt.Extensions.Xunit project with direct package references for `Codebelt.Extensions.Xunit`, xUnit, and the page's NuGet package before `dotnet test`; executable validation uses bounded parallelism and can be tuned with `GIT_REPO_DIGEST_VALIDATE_PARALLELISM`; the agent must revise from evidence and rerun validation after the final result-file edit until it passes
- **Disciplined validation repair** - treats preflight `rg` hits as triage rather than automatic defects, records each validator diagnostic with the affected file, snippet, evidence need, and planned edit, inspects the exact failing line before theorizing about framework internals, limits open-ended hypothesis loops, and prefers one source-backed repair followed by another `--validate-results` run
- **Chunked evidence navigation** - emits `*.index.md` and ordered `*.chunks/*.xml` files beside oversized evidence files so agents can read large evidence sets even when a tool caps single-file output; each chunk row has a complete `Contents` summary with packed-path labels such as `Source Code`, `Test Coverage`, `NuGet Documentation`, or `Project Metadata`
- **Complete-read grounding** - treats capped or truncated evidence output as an unfinished read, requiring the agent to use the index and every ordered chunk, or range reads for older workspaces, until the current package evidence set, overview prompt, and required package digests have been fully inspected
- **Subagent-friendly packages** - when the runtime supports delegation, assigns at most one independent package evidence set to each subagent so large evidence sets do not compete for the same prompt budget, while the main agent orchestrates, gathers caveats, and authors the final overview
- **Package-first workflow** - writes `result/{PackageName}.md` files before synthesizing `result/Index.md`
- **Digest-sourced overview** - requires the overview phase to open the completed package digest files as the primary source instead of relying on project/readme evidence alone
- **Concept-led overview** - requires `result/Index.md` to use `## Concepts`, open that section with a short framing paragraph, build concept candidates from every completed package digest's Overview, Key APIs, Basic usage, and Usage guidance sections, preserve substantial package-owned capability domains instead of collapsing them into a short polished list, connect related packages where the evidence supports it, and link package pages inline only when a concept needs a signpost
- **Phase-scoped reading** - processes package evidence sets separately and uses completed package digests for the overview without letting token limits justify skipped evidence
- **Grounded prose** - forbids invented APIs, relationships, examples, broad marketing claims, definition-list-style Key APIs entries, and unmeasured frequency claims such as "most common mistake" unless the generated evidence supports them with concrete evidence
- **Publication stays explicit** - leaves staged files in `{output-root}/{repo-id}/{yyyyMMdd-HHmmssZ}/result` unless the user asks to sync them into a consuming site
### Why markdown-illustrator?

Markdown-heavy documents often need one image that sells the whole idea fast: a conference opener, article cover, pitch-slide hero, or visual hook that makes the audience want to keep reading. The problem with many prompt workflows is that they branch immediately into model menus, theme toggles, and style comparisons before the document has even been understood.

**markdown-illustrator** keeps the job focused. It reads the markdown, distills the whole document into a visualization-first Visual Brief, silently infers a compact visual strategy from the request, and turns that shared brief into one compiled prompt returned directly in chat. If you explicitly ask for a named model or a narrower aesthetic, it honors that request without dragging you through a selection workflow.

- **Visual-Brief first** — distills the document into subject, narrative, visual opportunity, mood, and must-show elements before prompting
- **One shared Visual Brief, one committed result** — optimized for covers, keynote slides, and "capture the essence" illustration requests where decisiveness matters more than variants
- **Prompt-compiler behavior** — translates abstract meaning into concrete visual structure, readable composition, physical medium cues, and explicit failure-mode control
- **Infer, don't interrogate** — defaults to a strong non-interactive strategy instead of turning intent, treatment, abstraction, and label density into follow-up questions
- **Hero-first defaults** — when the request is underspecified, the skill defaults toward `hero + cinematic editorial + concept-led + minimal labels + 16:9 (or 3:2 when it composes better)` rather than a dry explainer graphic
- **Cross-diffuser by design** — prefers strong natural-language prompting over vendor-specific branching unless the user asks
- **Text-safe prompting** — steers away from dense embedded copy, fake words, and fragile readable text unless very short labels are truly necessary
- **Anti-repetition by default** — avoids repeated labels, bullets, steps, callouts, mirrored panels, and echoed document fragments so the image reads like one authoritative artifact rather than many near-duplicates
- **No selection detours** — skips file creation, model-family, style, theme, and scope menus so the workflow stays fast and focused
- **User steerable when needed** — the skill stays minimal, but users can still explicitly steer toward directions like `whiteboard`, `blackboard`, `isometric`, or `blueprint`
- **Board styles use color intentionally** — `whiteboard` and `blackboard` keep their authentic marker/chalk base, but the skill now biases toward selective colored accents for arrows, icons, checks, and highlights instead of leaving every emphasis mark monochrome

#### Inferred Defaults For markdown-illustrator

The skill should not ask the user to configure these unless the request is genuinely ambiguous in a way that affects correctness. It infers a compact strategy and proceeds.

- **Intent** — infer `hero`, `digest`, `diagram`, or `cover` from the user's phrasing; if there is no stronger signal, default to `hero`
- **Visual treatment** — preserve explicit styles such as `whiteboard`, `blackboard`, `scientific`, `hand-drawn`, `isometric`, or `minimal`; otherwise default to `cinematic editorial`
- **Abstraction level** — use `concept-led` for spectacle and interest-raising requests, `balanced` for explanatory or onboarding requests, and `literal` only when the user explicitly asks for strict fidelity
- **Label density** — default to `minimal`, move toward `none` for hero or infographic-first requests, and use `academic` only for scientific or textbook-style requests
- **Aspect ratio** — honor explicit ratios, otherwise default to a wide frame: prefer `16:9`, use `3:2` when the composition is more editorial or object-centered, and avoid square by default

#### Good Trigger Examples For markdown-illustrator

These phrasings reliably signal the skill's intent: a markdown file goes in, and one document-wide visual direction comes back.

- `Use markdown-illustrator on SKILL.md and return the Visual Brief plus one final prompt.`
- `Read roadmap.md and create one strong visual direction that captures the whole document.`
- `Create a visual digest for onboarding-notes.md.`
- `Turn launch-plan.md into a keynote opener image prompt.`
- `Use markdown-illustrator on systems.md and keep it blackboard style.`
- `Turn product-brief.md into a single Flux-ready hero-image prompt.`

#### Common Visual Directions For markdown-illustrator

These are reference directions for users, not built-in branches in the skill. If you want one of them, ask for it explicitly in the prompt.

`whiteboard`

- Pros: approachable, collaborative, strong for brainstorming, product planning, workshops, and messy human energy
- Cons: can feel too casual or cluttered for polished keynote or editorial uses
- Guidance: ask for this when the document is about ideation, strategy sessions, or product thinking; expect a mostly marker-based board with selective colored accents for emphasis marks instead of pure black-only linework

`blackboard`

- Pros: dramatic, intellectual, layered, great for systems thinking and technical storytelling
- Cons: can become visually noisy if the source material is already dense
- Guidance: ask for this when the document is about architecture, strategy, layered concepts, or technical explanation; expect a chalkboard base with restrained colored chalk accents for arrows, highlights, and key icons instead of all-white chalk marks

`isometric`

- Pros: excellent for platforms, ecosystems, infrastructure, and layered technical worlds
- Cons: weaker for abstract or emotional narratives that need symbolism more than structure
- Guidance: ask for this when the document describes systems, services, stacks, networks, or architectural relationships

`blueprint`

- Pros: precise, engineered, authoritative, strong for protocols, design intent, and technical rigor
- Cons: can feel cold or overly schematic for marketing or human-centered subjects
- Guidance: ask for this when the document should feel exact, technical, and intentionally designed

`editorial illustration`

- Pros: expressive, conceptual, and strong for article covers, essays, and symbolic storytelling
- Cons: less literal, so it may underperform when the image must explain concrete architecture
- Guidance: ask for this when the document needs metaphor, mood, or a polished publication-style visual

`cinematic`

- Pros: emotional, aspirational, high-impact, strong for keynote heroes and launch moments
- Cons: can become too grand if the source material really needs clarity over spectacle
- Guidance: ask for this when the image should feel premium, dramatic, and audience-grabbing

`minimal poster`

- Pros: high signal-to-noise, memorable, clean, and strong for one dominant idea
- Cons: can oversimplify documents with important operational or technical nuance
- Guidance: ask for this when the document has one central idea that can be reduced to a powerful symbol

### Why dotnet-new-lib-slnx and dotnet-new-app-slnx?

Starting a new .NET solution "from scratch" usually means copying from your last project, deleting half of it, and spending an hour wiring up CI, MSBuild props, versioning, and code quality tooling. Every new repo drifts slightly from the last one. Six months later, no two solutions look the same.

**dotnet-new-lib-slnx** and **dotnet-new-app-slnx** encode the full codebeltnet convention into repeatable scaffolds — from `Directory.Build.props` to CI pipelines to DocFX. Each skill is focused on its domain: libraries get multi-target frameworks, signing, and NuGet packaging; apps get host family selection, a conditional web-variant choice when needed, hosting patterns, and functional tests.

Library scaffolds keep the source framework matrix separate from executable test and benchmark targets, excluding source-only frameworks such as `netstandard2.0` from those projects. The app package resolver marks version selections as provisional until package metadata inspection and combined restore/build validation establish compatibility for the selected framework.

> [!NOTE]
> These scaffolds are not speculative starter kits. They capture conventions already exercised across Codebelt repositories and turn them into a repeatable methodology for new solutions.

- **Vendor-neutral agent guidance** — generated repositories use root `AGENTS.md` as their single agent-instruction contract, preserving the complete coding, testing, coverage, benchmarking, XML documentation, and `.bot/` workspace contract, including code examples, rationale, alternatives, and applicability conditions
- **Convention over configuration** — opinionated defaults that match real production setups
- **Focused skills** — library and app concerns are fully separated, no variant confusion
- **Lower cognitive load** — the library scaffold defaults the main project name from the solution name, pre-fills the repository URL from the repo root folder name, and lets the package website reuse that value unless you override it
- **Default-friendly prompts** — when a scaffold form already shows a recommended value such as `root_namespace = solution_name`, leaving the field blank should accept that default instead of sending the agent into a follow-up loop
- **Structured-input fallback stays consistent** — when a host does not render native form widgets, the scaffold skills now fall back to a deterministic one-field-at-a-time plain-text format instead of improvising the UX
- **Explicit host prompts stay on rails** — if you already asked for `Console`, `Worker`, `Web API`, `MVC`, or `Razor`, the scaffold flow should preselect that host choice and move straight to the remaining fields instead of asking you to restate it
- **Modern TFM choices** — the .NET scaffold skills compute active target framework quick-picks from the official .NET releases index, offering every supported non-preview LTS and STS channel plus an expanded multi-target preset where applicable
- **Native MTP test stack** — both scaffolds use the live-resolved compatible Codebelt xUnit 12.x and `xunit.v3` 4.x lines, ship root `global.json` selecting `Microsoft.Testing.Platform`, and require a supported non-preview .NET 10+ SDK even for older target runtimes; shared test references use `Codebelt.Coverlet.MTP` instead of legacy Coverlet integrations, include HangDump, and validate real test discovery plus TRX/OpenCover output through xUnit's built-in reporter, preserving the original `Codebelt.Extensions.Xunit.App` package choice without a separate TRX provider or .NET 8-specific workaround
- **Latest stable dependencies** — `Directory.Packages.props` is generated from NuGet.org package metadata at scaffold time instead of carrying stale hardcoded NuGet package versions
- **Central package management stays authoritative** — app scaffolds keep NuGet versions in `Directory.Packages.props` and do not “repair” restore issues by inlining versions into generated project files
- **Deterministic package resolution beats memory** — the app scaffold now ships a NuGet resolver script so agents can fetch current per-package versions instead of guessing from stale remembered examples
- **Resolver script is non-interactive by default** — the app package resolver now defaults to the skill’s own `Directory.Packages.props`, so agents do not have to remember an extra template path argument during normal scaffolds
- **Library-only package set** — the library scaffold no longer carries leftover app/bootstrapper package placeholders that do not belong in class library templates
- **Structured benchmarking** — the scaffold now keeps actual benchmark projects under `tuning/`, generates a solution-level `tooling/benchmark-runner` host with BenchmarkDotNet jobs derived from the selected TFMs, targets the runner itself at the highest selected supported runtime, and writes output to `reports/`
- **Hidden shared assets preserved** — recursive scaffold copy includes dot-folders such as `.bot/`, so the generated repo gets the real `.bot/README.md` template instead of an improvised placeholder
- **UTF-8 by default** — the scaffold explicitly tells generating agents to preserve UTF-8 when copying and writing text templates, matching the generated `.editorconfig`
- **Explicit encoding guidance** — rewritten templates now call for byte-preserving copy when possible, explicit UTF-8 APIs when not, and a quick mojibake sanity check before scaffolding is considered done
- **TFM-aware test runners** — generated `testenvironments.json` Docker entries now follow the selected target frameworks instead of using a hardcoded runner tag
- **Shared test environments are required** — `testenvironments.json` is part of the app scaffold contract and should never be silently skipped
- **Source-backed runner tags** — Docker runner tags can be validated against the `codebeltnet/ubuntu-testrunner` Docker Hub tags feed instead of being assumed
- **Root-aware Dependabot** — the generated repo watches `/` for NuGet updates so central package management keeps moving after day one
- **App scaffolds resolve package versions per dependency** — generated `Directory.Packages.props` files use package-specific placeholders that are resolved from NuGet.org instead of leaking a generic `{LATEST}` token
- **ASP.NET package versions stay TFM-aligned** — `net9.0` app scaffolds resolve framework-aligned ASP.NET packages to the latest stable `9.x` line instead of accidentally pulling incompatible `10.x` packages
- **Web-family scaffolds stay explicit** — generic `Web` requests expand into `Empty Web`, `Web API`, `MVC`, or `Web App / Razor`, with variant-specific project suffixes like `.Web`, `.Api`, `.Mvc`, and `.WebApp`
- **Current-folder scaffolding** — both .NET scaffold skills generate directly into the folder you are already in unless you explicitly ask for a nested solution folder
- **PascalCase solution filenames** — generated `.slnx` files keep the user-facing solution/product name instead of silently lowercasing it
- **Required artifacts stay required** — the app scaffold treats `.slnx`, `testenvironments.json`, `Directory.Packages.props`, and the per-host `src/` + `test/` projects as non-optional outputs, even for single-host scaffolds
- **Shared scaffold assets are copied as a complete set** — app scaffolds preserve the full `assets/shared/` inventory, including dotfiles, `.github/`, and `.bot/`, instead of cherry-picking only the files that seem important
- **Target framework stays centralized** — generated app and test projects inherit `TargetFramework` from the root `Directory.Build.props` instead of patching individual `.csproj` files
- **MinVer stays wired in** — .NET scaffolds preserve MinVer-based semantic versioning from git tags as a repo-level invariant
- **MinVer bootstrap warnings are expected** — in non-git or untagged folders, an initial `0.0.0-alpha.0` style version is expected until the repo is initialized and tagged
- **Worker scaffolds build immediately** — Worker apps now include a starter `Worker.cs` template so the generated project compiles before custom logic is added
- **Bootstrapper imports are explicit** — app templates now include the required `Codebelt.Bootstrapper.*` namespace imports instead of relying on missing implicit usings
- **Clear NuGet metadata mapping** — prompts and placeholders line up with package metadata such as `PackageProjectUrl`
- **Solo-friendly defaults** — company/publisher metadata can default straight from the author name for individual maintainers
- **Complete from the start** — CI pipeline, code quality, test infrastructure, and governance docs on day one
- **Template-driven** — real files with placeholders in `assets/`, not generated strings, so you can inspect and evolve them

### Why dotnet-strong-name-signing?

Generating a `.snk` file traditionally requires `sn.exe`, which is only available in the Visual Studio Developer PowerShell — a common pain point for developers using VS Code, Rider, or plain terminals. This skill uses `RSACryptoServiceProvider` from the .NET runtime itself, so it works in **any PowerShell or terminal** without special tooling.

- **No `sn.exe` dependency** — uses pure .NET crypto available in any PowerShell session
- **Matches `sn.exe` defaults** — 1024-bit RSA by default, with 2048 and 4096 as options
- **Cross-platform** — works on Windows, macOS, and Linux with PowerShell 7+ or .NET runtime
- **Identity, not security** — [Microsoft's guidance](https://github.com/dotnet/runtime/blob/main/docs/project/strong-name-signing.md) is clear: strong names are about assembly identity, not cryptographic security

### Why trunk-first?

Most repositories start with `git init` followed by committing everything directly to `main`. This works — until someone force-pushes to main, or a half-finished feature lands without review. By the time you add branch protection, the history is already messy.

**trunk-first-repo** flips this: main starts empty and stays clean from the very first commit. Every piece of content enters through a pull request, and the skill now branches cleanly depending on when `origin` becomes available: configure it during setup and later you only push `HEAD`; add it later with `push remote <url>` and the skill first verifies the feature-branch/empty-main state before publishing. This gives you:

- **Review from day one** — no "we'll add branch protection later" that never happens
- **Clean, meaningful history** — main tells the story of reviewed, approved changes
- **Version-aware branches** — `v0.0.1/spike-auth` vs `v1.0.0/release-prep` signals project maturity at a glance
- **Safer first push** — if `origin` is ready during setup, the summary points straight to `git push -u origin HEAD`; if not, invoke `push remote <url>` to verify the branch state, push `main` by ref from the feature branch, then push the feature branch without manually deleting files or checking out `main`
- **Zero-friction setup** — one skill invocation, not a 10-step checklist

### Why git-remote-pr?

**git-remote-pr** prepares a reviewable pull request from every committed change between the resolved base branch and the current head. It inventories commits, changed paths, renames, binaries, and the final patch, then collapses that evidence into a concise opening paragraph followed by bold thematic headings with trailing colons and compact bullets. Related helpers, validation cases, references, formatting changes, and assets become shared reviewer-facing outcomes; complete internal file coverage does not require a prose inventory. The planner rejects malformed default bodies before preview: exactly one opening paragraph, bold colon-ended themes, dash bullets under every theme, and no concluding summary. A deterministic approval ID binds the complete prepared write intent plus the SHA-256 hash of the complete preview with only its two generated approval-ID fields normalized to `{{APPROVAL_ID}}`. A separate SHA-256 hash checks the exact final `preview.md`, including its approval instruction; changing that hash cannot authorize altered preview text. Normal mode requires `approve APR-...` for that preview; generic approval cannot execute or regenerate it. Same-request `yolo`/`auto` still shows the preview but treats that approval phrase as status only, continuing without asking for or waiting on another reply. State drift permanently invalidates the transaction and preserves its artifacts. Only an explicit refresh request starts fresh preparation in a new workspace with a new approval ID. Repository templates retain precedence. It uses `git` and `gh` without GitHub Copilot or browser assistance.

Normal requests stop after showing the proposed title, reviewer-oriented description summary, assignee, push requirement, and exact remote writes. A `yolo` or `auto` attached to the same PR request still shows that preview, but it does not ask for or wait on `approve APR-...`; it proceeds immediately with the just-presented plan. Existing open PRs are refreshed from the current complete changeset, and the coverage checks still require every changed file to map to a theme represented in the body even when many files collapse into a few sections. Execution refuses plans whose approved title, ready/draft state, body, evidence, or repository snapshot changed after approval. Post-write checks verify the title, body, draft state, assignment, head SHA, and GitHub file inventory. A branch that has never been pushed needs no preliminary tracking setup: preparation compares local HEAD against the base and previews a normal push to GitHub origin (or the sole GitHub remote) under the current branch name, including upstream tracking. Same-request `create yolo` executes that publication and PR creation without another reply. Dirty worktrees, ambiguous publication remotes, incomplete tracking, renamed-branch tracking mismatches, and divergent remote branches still block the workflow. Commit creation remains a separate `git-visual-commits` request; release-note writing remains `git-remote-release`.

### Why git-remote-release?

Writing release notes is tedious. Raw commit logs are too noisy, PR titles often lack context, and the best release notes explain what changed and why it matters — not just what was merged. That gap between "here are the commits" and "here is what this release means for you" is where **git-remote-release** fits.

**git-remote-release** reads all commits and pull requests between two tags or branches in a remote GitHub repository and produces a polished, paste-ready release note.

Its bundled Python collector uses authenticated `gh` REST reads and read-only GraphQL queries to expand squash merges into original PR commits, resolve co-author accounts, verify commit and file counts, and generate source lines with every recorded contributor. Draft verification rejects missing contributors, incomplete evidence, malformed `This release ...` openings, missing highlight bullets, punctuation-only highlights, plain blockquotes or unsupported alert markers after the summary, and em dashes in authored release-note prose while still preserving exact source titles. The model writes the summary from the final file changes and original commit messages, then checks that it covers the meaningful changes. Newcomer discovery includes verified GitHub `User` accounts from PRs, original commits, and co-author mappings, comparing against complete prior history including original squash PR commits for later releases. For tagged releases, GitHub's generate-notes response can supplement collection through `--generated-notes`; an omitted account does not override verified history. The collector validates newcomer PR membership and exact API identities, and the verifier checks recognition placement and completeness. Generation uses GitHub's non-persisting POST endpoint and never publishes a release. `--initial-release` collects all reachable commits and the final tree without inventing a comparison base. Collection and source verification are deterministic and never invoke a model.

- **Remote-first workflow** that works entirely through GitHub's API, with no local clone required,
- **Compare URL awareness** where a pasted GitHub compare URL is used to extract the owner, repository, and both tags,
- **Pull request-preferred analysis** that uses rich PR metadata when available and gracefully falls back to raw commits,
- **Default-branch-aware comparisons** that resolve the upstream base and collect only commits on the current branch,
- **Effect-oriented summaries** that inspect original PR commits and final diffs so later changes survive stale automated PR descriptions,
- **Release-story structure** where the summary always opens with `This release ...` and then shifts into curated bold-lead highlight bullets,
- **Thematic grouping** where related changes are discussed together instead of listed chronologically,
- **GitHub alert blocks** that use only supported `NOTE`, `TIP`, `IMPORTANT`, `WARNING`, and `CAUTION` markers sparingly and only when the release data supports the attention level,
- **Source preservation** where verified merged PRs replace their covered commits, all verified PR commit contributors share the source line with exact GitHub logins, and unresolved lookups are reported as incomplete,
- **Markdown file delivery** that saves and checks `release-notes.md` in a temporary working directory outside the repository, retains the file, and returns only an absolute Markdown link without duplicating the notes in console output,
- **New contributor recognition** that includes verified first-time GitHub users who authored PRs, original commits, or co-authored commits, including usernames containing `bot`, checks prior commits, PR membership, and authors including original squash PR commits to exclude returning contributors without requiring historical trees or PR file inventories, and places bold handles with PR or direct-commit links immediately before Full Changelog,
- **Initial release support** that includes the root commit and all reachable history when no previous release tag exists, with `/commits/{currentRef}` as the final changelog link,
- **Strict format** that always starts with `## What's Changed`, forbids em dashes in the authored release-note prose while preserving verbatim source titles, and always ends with the appropriate full changelog link,
- **No invented claims** so every statement in the summary is backed by the commits and pull requests collected,
- **Read-only operation** that never mutates repository state.

### Why dotnet-change-impact?

Picking the wrong version number is one of the easiest ways to break downstream consumers. A "bug fix" that quietly changes exception behavior, an "innocent" new overload that makes existing calls ambiguous, or a dependency bump that drops a target framework — any of these can be a breaking change shipped as a patch. Conversely, teams sometimes panic and burn a major version on a purely internal refactor. **dotnet-change-impact** brings Microsoft's official .NET compatibility model to that decision.

**dotnet-change-impact** reads the current Git branch by default, comparing it against the upstream/default base branch with local read-only git state, and recommends `Major`, `Minor`, or `Patch` for both SemVer and .NET `Major.Minor.Build.Revision` versioning. Explicit change descriptions, API diffs, PR summaries, and compare ranges still override the default branch resolution.

- **Reasoned output by default** — always puts the recommendation first, then explains the key changes, compatibility impact, reasoning, and deterministic decision so the version call is reviewable,
- **Current-branch default** — when no explicit input is supplied, resolves the current branch against the upstream/default base branch, collects commits plus the net diff, and classifies that branch instead of asking for change details first,
- **Grounded in Microsoft guidance** — decisions follow the official [library change rules](https://learn.microsoft.com/en-us/dotnet/core/compatibility/library-change-rules) and [compatibility categories](https://learn.microsoft.com/en-us/dotnet/core/compatibility/categories),
- **Five-category compatibility lens** — behavioral, binary, source, design-time, and backwards compatibility are evaluated explicitly,
- **Conservative by default** — a change that might break existing consumers is treated as breaking, so accidental breaking releases don't ship as a patch or minor,
- **But not alarmist** — internal, non-observable refactors are not inflated to major just because something changed,
- **Precedence-aware** — mixed releases take the highest required bump,
- **Special-case savvy** — dependency updates, bug fixes, new overloads, interface and enum changes, analyzers/source generators, TFM/platform support, and performance changes each get the right default and the right escalation triggers.

### Why dotnet-nuget-update?

Dependency updates look simple until a repository encodes compatibility in its package graph. A `Directory.Packages.props` file can pin the same package differently for `net9` and `net10`, hold a package back with an inline comment because a newer release dropped a target framework, or mix stable and prerelease intent on purpose. A shallow “latest package wins” pass breaks those repos quietly.

**dotnet-nuget-update** makes the complete audit the first-class artifact. It enumerates every declaration before editing, keeps `current + auto + approval + unresolved == declared` as a hard invariant, resolves versions from a live or offline flat-container feed with per-process memoization, and preserves XML comments, spacing, encoding, and line endings when it writes changes back.

- **Complete graph first** — every `<PackageVersion>` declaration, and explicit project-level `PackageReference` when CPM is absent, becomes an audit row before any update is applied,
- **TFM-band aware** — a package pinned under `net9` or `net10` stays inside that matching major when the pinned major itself is the compatibility signal, while mismatched majors remain free to move,
- **Stable/prerelease intent inference** — stable pins stay on stable candidates; prerelease pins may move within prerelease lines; same-major prerelease movement is auto, not approval,
- **History-first notes** — adjacent XML comments surface as `note` fields, and note-bearing auto updates are explicitly marked `READ THE NOTE before applying`,
- **Normal and yolo modes** — normal mode batches majors into one approval decision after the full audit, while yolo mode applies only the safe classes and reports held majors without asking,
- **Structural edits only** — version updates touch only the targeted attribute or element and leave comments, blank lines, unrelated files, and existing line endings intact,
- **Offline-testable** — the bundled scripts accept filesystem flat-container fixtures so audit, comparison, and update logic can be regression-tested without network dependency.

### Why dotnet-docfx-digest?

A bare invocation audits and repairs public API documentation across the repository. An explicit target limits the work to its affected pages. Host re-entry resumes the active audit.

- `dotnet-docfx-digest repair` inspects existing examples, including green builds with no review comments. It uses project packets to reconcile diagnostics, changes, findings and missing or stale behavioral evidence.
- `dotnet-docfx-digest csrun` (alias `generate-run-actions`) preserves consumer scenarios during conversion and generates synchronized execution assets.
- `dotnet-docfx-digest repair csrun` (also `csrun repair`) discovers and repairs examples, regenerates affected assets, verifies supported transports independently and runs the documentation gates in one invocation.

The [skill entry point](skills/dotnet-docfx-digest/SKILL.md) routes each operation to its authoring, repair, example design, execution or script reference. Behavioral review compares observations with source-backed expectations established before execution. A distinct final pass checks modified examples for introduced defects and verifies that they still demonstrate recommended consumer usage.

### Why dotnet-test?

Test-project refactoring is deceptively lifecycle-sensitive. A `WebApplicationFactory` wrapper may own temporary directories, defer host startup until the first client, replace services in a specific order, or isolate settings per test. Console and worker tests have a different boundary: they need a resolvable in-process Generic Host, not a child process hidden behind a test helper.

The skill has one job: the test host comes from Codebelt, not from Microsoft, and not from a builder written in the test project. `WebApplicationFactory` covers ASP.NET Core and nothing else, so console and worker tests end up hand-rolling a host that no deployed process ever runs. Codebelt closes both gaps with `WebApplicationTestFactory`, `WebApplicationTest`, `ApplicationTestFactory`, and `ApplicationTest`.

**dotnet-test** begins with machine-readable inspection, then chooses the Codebelt pattern that matches the selected project's role and ownership model. Because that inspection already answers which project, role, and ownership apply, the skill acts on the evidence instead of asking the developer to retype what the JSON says. It preserves package ownership and frameworks, migrates xUnit v2 to v3/Microsoft Testing Platform when needed, and makes the chosen focused/shared web or application pattern, entrypoint-owned managed fixture, zero remaining selected `WebApplicationFactory` usages, zero deprecated blocking fixtures, zero replacement composition roots, and restore/build/test explicit gates.

The hardest failure to catch is the migration that only looks like one. Wrapping `WebApplicationFactory` in a private nested class, renaming a constructor to a static `Create`, or bumping package pins all produce a substantial diff while Microsoft's host still starts the application and every test stays green. `verify-dotnet-test-migration.ps1` closes the run with a verdict instead of a self-assessment: it re-checks the expected pattern and adds the post-edit checks for a surviving factory base type, a retained `Microsoft.AspNetCore.Mvc.Testing` reference, `xunit*` pins past the major the restored Codebelt package declares, and files changed under the project while the target pattern appears nowhere in it.

- **Evidence before questions** — the bundled inspector resolves project, role, mode, host ownership, and package owner, so a bare invocation starts working instead of returning a capability menu,
- **Managed-fixture version floor** — inspection flags a Codebelt xUnit package pinned below 11.1.0, where the managed fixtures do not exist yet, before the pattern is written rather than after it fails to compile,
- **Three explicit roles** — ordinary unit, ASP.NET Core functional, and console/worker functional tests route to separate references and assets,
- **Lifecycle-preserving functional migration** — focused factories or narrow `Test`-derived harnesses and shared managed fixtures retain configuration, lazy start, client/service access, synchronous/asynchronous disposal, and isolation,
- **Real entry-point coverage** — focused and shared postconditions reject test-owned `WebApplication`/`TestServer` pipelines that can pass while the production `Program` is broken,
- **Generic Host boundary** — non-web tests use `ApplicationTestFactory` or `ApplicationTest`; missing host seams are reported precisely unless production adaptation is authorized,
- **Bootstrapper host fidelity** — Startup-based hosts and `MinimalConsoleProgram`, `MinimalWorkerProgram`, or `MinimalWebProgram` hosts remain in their established family instead of being rewritten for test convenience,
- **Dynamic compatibility** — stable package versions come from NuGet and must pass isolated compatibility-project restores, including the selected combined package set and target frameworks,
- **Source-grounded bootstrap** — new projects receive at least one behavior test derived from real source instead of a placeholder,
- **Deterministic evidence** — inspection JSON reports roles, frameworks, xUnit generation, package owners, inheritance, migrations, recommendations, and blockers before mutation,
- **A verdict, not a summary** — the migration gate exits `PASSED` or `FAILED` with numbered violations and their file and line, so a wrapped, renamed, or repackaged factory is reported as an unfinished migration rather than a completed one,
- **Anchored xUnit versions** — the gate reads the restored Codebelt package's own declared dependencies from `project.assets.json`, so an after-the-fact bump past that xUnit generation is caught offline instead of at the next compile.

### Why dotnet-csrun?

Documentation examples earn trust when the exact source executes and its observations match expectations. dotnet-csrun supports the complete sample lifecycle: create, read-only verify, semantics-preserving repair, and scoped audit. It generates independent Native and disposable Docker PowerShell commands from one manifest, verifies the latest stable csrun release in both, records source identities, and reports verification per transport. It composes with dotnet-docfx-digest for compatible runtime evidence while preserving project-aware sample compilation and DocFX completion gates. It creates no developer-managed project and does not replace repository tests or benchmarks.

### Why dotnet-benchmark?

Setting up a benchmark "properly" is only half the problem. A benchmark can compile and still answer the wrong question: public members get measured because they are visible, unrelated operations share a meaningless baseline, random inputs miss real branches, setup leaks into the timed path, or a disk/service bottleneck is disguised as a microbenchmark. The result looks scientific but gives an engineer little trustworthy optimization evidence.

**dotnet-benchmark** combines codebelt harness conventions with an evidence-driven performance investigation. It inspects the type, callers, tests, existing benchmarks, and available profiles; ranks the operations most likely to matter; selects a small set of representative experiments; and explicitly rejects misleading measurements. When no profile exists, it labels the result as source-informed exploration rather than claiming to have found an application bottleneck.

- **Works on existing repos** — detects your solution format, package-management style, and any runner you already have (`benchmark-runner`, `bdn-runner`, …) and reuses it instead of forcing a new layout
- **Codebelt convention by default** — `tuning/` benchmark projects, a single `tooling/` runner host, and `reports/` output, mirroring `codebeltnet/cuemon` and `codebeltnet/xunit`
- **Evidence-backed candidate selection** — ranks operations from call-site frequency, input scaling, allocations, contention, optimization leverage, and measurement fitness instead of treating public-member coverage as thoroughness
- **Honest experiment shapes** — creates equivalent current-versus-candidate comparisons, baseline-free single-operation characterization, or profiling/macrobenchmark guidance; unrelated construction, formatting, equality, and hashing never receive misleading ratios
- **Hard validity gate** — reads the complete BenchmarkDotNet summary after dry execution and after any full run, treating `NA`, `Benchmarks with issues`, failed jobs, setup/cleanup exceptions, validation errors, or a partial matrix as invalid rather than letting surviving rows stand in for the whole experiment
- **Representative workloads** — derives typical, boundary, scaling, hit/miss, valid/invalid, and other adverse-but-real cases from repository evidence, uses coupled scenario sources instead of accidental parameter Cartesian products, and keeps selectivity, branch mix, and other workload invariants stable unless they are explicit scenarios
- **Correctness before speed** — validates exact outputs, counts, status, exception behavior, and state transitions for every case outside the measured path before a full performance run, while still allowing intended zero-match boundaries
- **Semantic preflight** — checks the full method/job/parameter/scenario matrix before build/list/dry/full interpretation, proves independently derived exact expected results, verifies workload labels such as selectivity, hit rate, and type mix, and rejects accidental fast paths or fake type-filter workloads
- **Terminal-operation honesty** — distinguishes deferred query creation, terminal operators such as `Count()`/`Any()`/`First()`, explicit enumeration, and materialization, so a `List<T>.Count` fast path is never sold as predicate traversal
- **Specialized investigations** — handles mutation, async, contention, cold start, and exception paths explicitly, routing `ThreadingDiagnoser`, `ExceptionDiagnoser`, disassembly, or EventPipe only when each answers the stated question
- **Namespace-correct** — the `*Benchmark` class lives in the same namespace as the code it measures, via a `RootNamespace` override, so type discovery and reports stay clean
- **Allocations always measured** — `[MemoryDiagnoser]` is on by default
- **Multi-runtime aware** — the runner host runs on .NET 9/10, but its BenchmarkDotNet jobs can compare `net48`, `net8.0`, `net9.0`, and `net10.0`
- **Latest stable packages** — `BenchmarkDotNet`, `BenchmarkDotNet.Diagnostics.Windows`, and `Codebelt.Extensions.BenchmarkDotNet.Console` versions are resolved from NuGet, not hardcoded
- **Layered validation** — verifies the Release build, lists discovered cases, dry-executes lifecycle and correctness wiring, and reruns build/list/dry after benchmark-owned validity fixes; it never turns that smoke check into a performance claim or launches the full machine-sensitive run unless asked
- **Yolo mode without permission creep** — saying `yolo` auto-accepts evidence-backed defaults, skips routine plan/execution confirmations, and continues through build/list/dry validation; only an explicit human instruction can start a full benchmark run, and the mode never implies a commit, push, or unrelated external action
- **Proportional escalation** — after the first valid full result, it asks whether the issue is reproducible, material, and likely to change a real engineering decision before suggesting disassembly, EventPipe/ETW, repeated reruns, or alternative implementations
- **Honest Slim reporting** — reports the active `BenchmarkWorkspaceOptions.Slim` job accurately, including when its one-warmup developer-oriented shape limits runtime- or JIT-sensitive conclusions, instead of silently swapping the runner configuration
- **Report-aware runner preflight** — inspects the canonical `BenchmarkWorkspaceOptions.Slim` runtime jobs, `SkipBenchmarksWithReports`, and matching `reports/tuning/` artifacts before touching benchmark code, so an intentional existing-report skip is explained instead of triggering disassembly, renaming, or speculative rewrites
### Why dotnet-remote-testing?

Cross-platform .NET developers usually get Linux test feedback the slow way: push to CI and wait. Visual Studio's experimental Remote Testing promised something better — run those tests locally in a container — but left the bulk of provisioning to the developer, so "run my tests in .NET 10" too easily turns into writing Dockerfiles, wiring mounts, and debugging container plumbing. The right shape is: choose an environment, run tests, see results. Everything in between is infrastructure and belongs behind the abstraction.

**dotnet-remote-testing** keeps that principle by splitting the work in two: the skill is the orchestration layer that understands intent and which environment the developer means, and the bundled deterministic runner (`scripts/remote-test.cs`) is the execution layer that resolves configuration, discovers releases, resolves images, stages source, caches packages, runs the tests, collects results, and cleans up. The AI never composes ad-hoc Docker commands, and Docker complexity is never exposed just because Docker is the current transport.

- **Microsoft's contract, not a new one** — honors the existing `testenvironments.json` version-1 schema (`name`, `localRoot`, `dockerImage`, `dockerFile`, either/or Docker source), treats it as authoritative when present, and never modifies it unless asked
- **Zero-configuration by default** — with no `testenvironments.json`, it derives environments from Microsoft's live `releases-index.json` (supported LTS/STS channels plus the current preview) using `support-phase`/`release-type`, so no files are added to the repo and `.NET 10`/`.NET 11` are never hardcoded
- **Runs instead of asking** — invoking the skill *is* the request, so a repository with one applicable Docker environment goes straight to a test run with no menu, no questionnaire, and no confirmation; when several environments are derived, the repository's own target frameworks select one and the runner explains the choice
- **Whole matrix in one container** — a Microsoft SDK image ships a single runtime, so a repository targeting `net9.0;net10.0` builds there and then cannot execute the lower TFM; multi-targeted repositories resolve instead to a `codebeltnet/ubuntu-testrunner` combined tag (e.g. `8-9-10-11`) discovered from its live tag feed, running every target framework in one pass. Pointing a multi-targeted repo at a single-SDK image is reported as an SDK incompatibility naming the remedy, and `--framework` narrows the environment choice along with the run
- **One question, only when there is a real one** — the runner decides when a choice remains and exits `SelectionRequired` (16) with the exact candidates, so the single unavoidable question is precise and never expands into an intake form
- **Offline-safe discovery and explicit scoping** — successful release metadata is cached outside the repo for offline reuse, and when a project choice is needed the form exposes the exact runner-computed target as the recommended option alongside a custom path
- **Recommended images, pinned to a digest** — auto-generated environments come from `mcr.microsoft.com/dotnet/sdk` for a single .NET major or `codebeltnet/ubuntu-testrunner` for several, prefer the exact `latest-sdk` tag (preview build metadata stripped), validate the tag against the registry, and resolve an immutable digest so a run is reproducible across environment, image, digest, SDK, and architecture; other images are never substituted on the runner's own initiative
- **Tests run in Docker, the host stays clean** — source is staged into an isolated workspace so container builds never leave Linux `bin`/`obj` in the working tree, a persistent NuGet cache lives outside the repo, and it never silently falls back to running tests locally
- **Honest failure classification** — configuration, unsupported environment, Docker-unavailable, image-resolution, SDK-incompatibility, staging, restore, compilation, test-host, test-failure, result-processing, cleanup, cancellation, release-metadata, and selection-required outcomes are distinct exit codes mapped to exactly one next action each, so behavior is the same whichever model is driving and a container problem is never reported as a failing unit test
- **Timing you can trust** — reports test duration and total wall clock separately, so a fast suite behind a slow image pull is never presented as an instant run
- **No plumbing added, ever** — never generates a `Dockerfile`, dev container, compose file, or editor configuration (an existing configured `dockerFile` is honored, never created), never runs privileged containers or mounts the Docker socket, and always cleans up transient Docker resources — reporting exact identifiers if any remain
- **Target-framework aware** — inspects the projects and `global.json`, refuses to pick an SDK that cannot build the requested target framework, and reports incompatibilities instead of editing the repository to force them
- **Deterministic and tested** — the runner ships a comprehensive built-in `--self-test` plus a PowerShell harness covering configuration discovery, release parsing, environment selection (including unattended target-framework selection and the cases that must still ask), unsupported handling, image resolution, command planning, result parsing, failure classification, cancellation, and cleanup
### Why dotnet-segregated-assets?

`wwwroot` is where every ASP.NET Core developer expects to author static files — editors, hot reload, and the SDK all assume it. But shipping those files inside the deployed web application couples static delivery to business logic, bloats the app artifact, and puts asset caching on the wrong surface. The right shape is architectural: keep authoring in `wwwroot`, but let a separate, hardened static-content host serve the files in production.

**dotnet-segregated-assets** keeps that split honest. The skill is the orchestration layer — it understands intent, reads the repository's real conventions, and makes the edits — while the bundled deterministic runner (`scripts/segregate-assets.cs`) inspects the static-asset topology, classifies it, and *proves* the outcome instead of trusting a declaration that merely looks right.

- **`wwwroot` stays the authoring root** — developers keep editing where they always did, while `/cdnroot` remains the container content root for the asset host
- **App is not CDN** — app-owned assets (authored in `wwwroot`, served from a per-app asset host) are separated from shared CDN assets (reusable across applications, never duplicated into any app's `wwwroot`), and the skill always asks whether a CDN equivalent exists
- **Targeted app-owned publish handling** — `<Content Update="wwwroot/**" CopyToPublishDirectory="Never" />` removes application-owned files while preserving Razor Class Library (`_content`), framework (`_framework`), and generated Static Web Assets
- **Proven, not assumed** — `verify --run-publish` publishes to an isolated temp directory and asserts app-owned `wwwroot` files are absent from the artifact; verification output never touches the repository
- **Safety guardrail over broken migrations** — Blazor, Blazor WebAssembly, Razor Class Library, scoped CSS, component JavaScript modules, and frontend-build scenarios are detected and escalated rather than blindly excluded; stopping to request an explicit generated-static-assets design is a successful outcome, not a failure
- **Convention-aligned local topology** — the root Docker Compose profile appends `.Assets` to the ordinary Project profile name, and it points App URLs at an `http://localhost:<port>` origin, never a protocol-relative or `https://localhost` URL that an HTTPS page would break against an HTTP-only origin
- **Hardened local origin** — the local `web-cdn-origin:2.0.0` service mounts `wwwroot` into `/cdnroot` read-only as a non-root user, with a read-only root filesystem, no privileged mode, no Docker socket, and only the required port exposed
- **Docker naming aligned** — the derived production asset image uses the Docker-documented `<something>.Dockerfile` form with PascalCase `Assets.Dockerfile`, selected explicitly when a non-default Dockerfile is built
- **Compose naming aligned** — a dedicated local origin topology uses `compose.assets.yml`, paired with `Assets.Dockerfile`; existing repository orchestration is extended when present
- **Every file has one correct location** — `Dockerfile`, `LocalDevelopment.Dockerfile`, and `Assets.Dockerfile` are written beside the web `.csproj` where Visual Studio Container Tools expects them, never at the repository root; `compose.assets.yml`, `.dockerignore`, `docker-compose.dcproj`, and the Compose `launchSettings.json` are written at the root. `verify --check-local` fails on a misplaced Dockerfile instead of leaving it to review
- **Literal templates, not recollection** — `assets/` ships the real content for every generated file, so the agent substitutes placeholders instead of reconstructing a Dockerfile from the familiar `mcr.microsoft.com/dotnet/sdk` multi-stage pattern that is wrong for this topology
- **Artifact-first images, enforced** — both application Dockerfiles package an already-published `artifacts/publish/` directory and never compile source. The runner rejects an SDK stage, a `dotnet build`/`dotnet publish` step, a `RUN adduser` block, an `mcr.microsoft.com` runtime, or a missing artifact copy, and it requires `LocalPublishDirectory` behind a guarded non-CI post-build target, a root `.dockerignore` that still carries `artifacts/`, and a CI job that actually produces the artifact the image copies
- **Ports derived, not invented** — the Compose web service publishes on the ordinary Project profile's HTTP `applicationUrl` port, so bookmarks, redirect registrations, and cookie scopes survive the switch between ordinary and segregated Development
- **Visual Studio orchestration is explicit** — ordinary Development keeps the existing Project profile and serves `wwwroot` directly. For one-click segregated F5, the skill registers `compose.assets.yml` through a `Microsoft.Docker.Sdk` `.dcproj` and a root `<ordinary-profile>.Assets` `DockerCompose` profile. Compose directly builds the web app with `LocalDevelopment.Dockerfile` and the origin with `Assets.Dockerfile`, using the repository root as the web build context and the project directory as the asset build context; it does not use a redundant project-level segregated profile. The asset service sets `com.microsoft.visual-studio.project-name: ""`, preventing Visual Studio from associating it with the web project and injecting the web debugger bootstrap, so no `docker-compose.vs.release.yml` repair is needed. The web `.csproj` owns `LocalPublishDirectory`; local builds and CI publish the same artifact. Production `Dockerfile` copies it into the shell-less DHI ASP.NET runtime. The `-dev` image is not an SDK, none of the Dockerfiles compile the app, and completion requires a real F5 attachment check rather than only MSBuild and Compose CLI evidence
- **Reproducible source is mandatory** — the asset image input must exist in a clean checkout or come from a pinned immutable artifact. The skill flags an ignored or wholly untracked `wwwroot`; a tracked repository-level asset root is supported as an explicit design only when the ordinary web root, Docker context, CI inputs, and verification move together
- **Both deployment images reach CI** — when repository Actions already build the web application image, the skill also requires a build or validation of `Assets.Dockerfile` from the same commit
- **The artifact-first image always gets a producer** — an image whose only instruction is `COPY artifacts/publish/ .` is inert without a CI job that publishes there, so the skill closes that gap rather than waiting to be asked: it extends the existing GitHub Actions workflow, or creates one from a complete template when the repository has none, and names which it did. A workflow that only builds and tests still counts as missing a producer, and `verify` fails on it
- **Architectural motivation, stated honestly** — segregation of duties, independent deployment and scaling, explicit cache behavior, and origin/CDN offloading
- **Adapts, never imposes** — it reuses Cuemon `AppTagHelperOptions`/`CdnTagHelperOptions` when already present and the application's own base-URL setting otherwise, and never adds a Cuemon dependency just to migrate
- **Current packages, resolved deterministically** — when a real Cuemon package reference already exists, `plan` discovers NuGet's V3 package endpoint, selects the highest stable version, emits the exact version and source, preserves `Directory.Packages.props` ownership when CPM is active, and fails closed instead of recycling an old literal
- **Uses the existing asset model** — when Cuemon is detected from package/project references, namespace imports, options, `_ViewImports.cshtml`, or actual custom-element markup, it migrates App/CDN ownership to the public `app-*`/`cdn-*` helpers, uses `BaseUrlMode` for Automatic App resolution versus explicitly Configured CDN locations, and removes a redundant `AppAssetOptions`-style abstraction only after its consumers are gone
- **Reports, never rewrites** — the runner exposes Cuemon, competing-abstraction, legacy-syntax, and cache-busting interface/registration evidence for the agent to act on; it never rewrites Razor or C# source and never creates a live-model evaluation workflow
- **Idempotent and deterministic** — re-running reconciles existing segregation instead of duplicating MSBuild items, launch profiles, Compose services, or Dockerfiles, and the runner ships a built-in `--self-test` plus a PowerShell harness
- **Fail-closed verification and planning** — local verification requires both the matching HTTP launch profile and origin Compose service, generated-asset risks override existing-segregation detection, and a no-`wwwroot` project can still produce CDN-only work when a shared equivalent exists
### Why agent-smith?

**agent-smith** applies one coherent engineering operating model across software engineering and AI-assisted work. Consistency is key. Invoke it as `/agent-smith <task>` or let engineering intent select it automatically. Its guidance expresses engineering judgement through decisions and evidence.

- **Clear decision precedence:** explicit task constraints; local repository policy, established conventions, and observed repository evidence; operating defaults; then generic ecosystem convention. Shared configuration, workflows, and supported-host requirements remain concrete repository evidence.
- **Observable values:** consistency preserves coherent patterns; quality starts Outside-In from consumer needs; vigilance looks for hidden failures and accidental precedent; due diligence verifies assumptions in proportion to risk.
- **Explicit failure over false success:** required conditions need positive verification. Unsupported, unvalidated, skipped, failed, and successful states stay distinct, and failures remain actionable.
- **Narrow contracts:** every public member, event, option, and serialized element carries a compatibility cost. HTTP guidance distinguishes REST and its Uniform Interface constraint from generic HTTP APIs.
- **Distinct delivery lifecycles:** Package and Application guidance separates PR validation, immutable release artifacts, and application deployment. Deployments consume the same artifact without rebuilding. Greenfield branching defaults to scaled trunk-based development where policy is silent.
- **Proportional automation:** use a sufficient native command, PowerShell 7 for small focused scripts, and C#/.NET where substantial reusable automation benefits from structure, testing, cancellation, and diagnostics. Local conventions and host constraints remain authoritative.
- **Deliberate agentic engineering:** select the least expensive adequate capability, escalate with uncertainty and consequence, map dependencies before delegation, bound independent work, serialize shared mutations, and measure total value. Guidance never authorizes unrequested model calls or evaluations.
- **Preserved specialist safeguards:** .NET conformance and Roslyn recovery remain fail-closed, scoped, and read-only during formatter discovery and verification. Detailed procedures live in required references; missing guidance blocks improvisation.
- **Honest evidence and natural writing:** concise, precise prose preserves grammar, validation limits, compatibility impact, and material risks. Progressive disclosure keeps the entry point focused; focused deterministic checks and decision-oriented eval specifications cover the operating model without claiming measured model behavior.

## Repository structure

```
skills/
  <skill-name>/
    SKILL.md          # Required — the skill definition (loaded by the AI)
    FORMS.md          # Optional — structured form fields for parameter collection
    assets/           # Optional — file templates, fonts, icons used in output
    scripts/          # Optional — executable code (Python, Bash, etc.)
    references/       # Optional — detailed reference docs
    evals/            # Required for repo-managed skills — per-skill evals/evals.json
      files/          # Optional — eval fixture inputs referenced by evals/evals.json files[]
```

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) for how to add a new skill or improve an existing one.

## License

[MIT](LICENSE)
