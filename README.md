# Agentic Skills

![Skills Applied](assets/hero.jpg)

A curated collection of [skills](https://skills.sh) — reusable instruction sets that teach AI agents how to follow specific workflows, conventions, and standards. Designed to work with any agent that supports the skills ecosystem: GitHub Copilot, Claude Code, Cursor, Codex, OpenCode, and [many more](https://skills.sh).

## What are skills?

Skills are Markdown files that an AI agent reads before responding. When a skill is active, the agent follows the rules it contains — consistently, across any tool or model that supports them. They're a lightweight way to encode your team's conventions once and apply them everywhere.

One repo-wide convention matters especially for scaffolding skills: prefer dynamic defaults over hardcoded values whenever a reliable source exists. Derive time-sensitive or environment-sensitive values from git metadata, repo state, or official machine-readable feeds so skills age gracefully instead of drifting.

Another repo rule is intentionally strict: every repo-managed skill ships with its own `evals/evals.json`. These files are versioned review specifications whose prompts, fixtures, and expected outcomes are validated locally; they are not instructions to launch model sessions.

Skill validation is local and deterministic. The Priority 1 **AI/LLM Evaluation Automation Prohibition** in `AGENTS.md` forbids repository scripts, CI jobs, runners, graders, optimizers, and custom hooks from using an authenticated Copilot, Claude, Codex, Gemini, or other model account. There is no repository opt-in switch. Model-backed candidate/baseline fan-out is not a completion gate.

One more consistency rule matters for form-driven skills: native input fields are treated as a host feature, not something a model can rely on. Skills in this repo must stay usable with or without UI widgets, and must fall back to the same deterministic one-field-at-a-time flow when the host only supports plain chat.

Repo-level agent guidance also keeps progress updates user-facing: agents should report meaningful progress, evidence, blockers, and next steps without narrating sandbox mechanics, approved command paths, or retry plumbing unless those details affect approval, reproducibility, validation, or the final outcome.

Completion gates are equally strict: if repository guidance, a loaded skill, or the conversation summary marks a script-backed step as pending, critical, or blocking, agents must treat it as an active checklist item and may not claim completion until that command has run or the exact external blocker has been reported. In the DocFX workflow, that means `scripts/agents.cs` and the build-backed `scripts/docfx.cs --build-api-model --validate-samples --verify-docfx-build` verification are completion gates, not optional cleanup after the documentation files look done. The validator now emits a deterministic completion contract: `summary.fullVerificationRan` must be `true`, `summary.canClaimCompletion` must be `true`, `summary.remainingWorkItems` must be `0`, both `summary.remainingGates` and `summary.remainingDiagnosticsByCode` must be empty, and both `summary.newlyIntroducedSkipMarkers` and `summary.interimArtifacts` must be `0`. A clean fast run reports `verification-required`, not completion. Pre-existing gaps, large diagnostic counts, sample failures, unresolved symbol ownership, and documentation-caused DocFX build failures remain repair work; they are not permission to stop after a partial digest. Context pressure, session length, task size, repetitive authoring, or a stable queue are not escape hatches either; agents must shrink the batch, regenerate deterministic queue state, or report a true blocker instead of ending with a follow-up handoff. Cross-assembly collisions are clearable: exact type-UID example mappings resolve `SYMBOL_COLLISION_UNRESOLVED`, and exact-owner receiver-style calls resolve `EXTENSION_OWNER_AMBIGUOUS`. (The plain `scripts/docfx.cs` run is fast and build-free for iteration; the build-backed flags are what make the final gate authoritative.)

DocFX prose, cleanup, unresolved ownership, and skip-marker diagnostics are not softer backlog either. `EXAMPLE_LEAD_MISSING`, `EXAMPLE_ADVANCED_LEAD_MISSING`, `FAMILY_ANCHOR_EXAMPLE_MISSING`, `SAMPLE_STRUCTURE_INVALID`, `INTERIM_ARTIFACT_IN_WORKTREE`, `SYMBOL_COLLISION_UNRESOLVED`, `EXTENSION_OWNER_AMBIGUOUS`, `SAMPLE_SKIP_NOT_ALLOWLISTED`, and `FAIL_NEW_SKIP_MARKER_INTRODUCED` stay in the active repair queue until the JSON completion contract is clean, even after sample compilation and DocFX build verification have succeeded. Final handoff-shaped summaries are equally blocked while that queue is dirty.

The DocFX validator also treats fallback `docfx.json` discovery conservatively: if a repo lacks a live root DocFX workspace, scaffold/template configs under skill assets are ignored unless their metadata globs resolve real projects. That keeps placeholder files like `skills/dotnet-new-lib-slnx/assets/library/.docfx/docfx.json` from masquerading as the active documentation workspace during repo-wide audits.

Local skill synchronization is verified efficiently: run deterministic tests against the repository source, copy touched files to the three local installs, and compare SHA-256 hashes across all four locations. Hash-identical copies are the same executable content, so agents do not repeat the same suites from an installed path unless install-path or loader behavior is specifically under test.

Resumed DocFX audits preserve every tracked and untracked documentation edit, regenerate the assessment work queue and example inventory, and process that queue in batches with a fast rerun after each batch. Encoding checks focus on actual damage: valid BOM-less UTF-8 is accepted, `ENCODING_BOM_MISSING` is not emitted, and audits do not create BOM-only or line-ending-only diffs.

DocFX guidance now also preserves working external links during prose rewrites unless a direct HTTP 404 justifies removal, keeps assessment/manifests/captured output/helper scripts in temp or session storage instead of the target repository, treats unexpected new repo-root or DocFX-workspace files that are not known skill deliverables as blocking cleanup work, and prefers inline or small sibling-batch prose repairs over slow per-page worker fan-out.

The DocFX validator now fails compiler-generated C# extension-block overwrite filenames at the layout gate and collapses literal, percent-encoded, and DocFX private-use `<G>$...` containers back to their authored outer static class in both YAML and reflection-backed API discovery. That prevents agents from creating or chasing unreadable synthetic files such as `EndpointConventionBuilderExtensions.G$6D0D8037DBBD61D10816ECA5F93B896F.md` after the readable declaring-class page already exists.

Final DocFX verification is machine-adaptive: `auto` selects a high-capacity profile above 8 available logical processors and 32 GiB available memory, overlaps isolated DocFX verification with API/sample work, and scales MSBuild workers up to half the available processors (capped at 16). Smaller machines stay conservative. Child-process timeout defaults to 30 minutes, and callers must allow at least 35 minutes so the validator can return its own timeout diagnostics. Long-running build, sample, and DocFX children also emit 10-second `stderr` heartbeats with phase, workload, runner count, PID, elapsed time, last-output age, and current output while keeping JSON stdout parseable; `--quiet` / `--no-heartbeat` suppresses start and heartbeat chatter when host stderr handling makes JSON inspection noisy, while retaining final child-process success/failure markers.

DocFX diagnostics favor repairable specificity: overwrite-layout errors now call out literal near-miss globs such as `api/namespaces/**.md` versus `api/namespaces/**/*.md`, no-observable-outcome example failures explain what visible reader result is missing, and common sample `CS1061` extension-method failures include missing-`using` hints such as `System.Linq` or `BenchmarkDotNet.Configs` when the compiler output points that way.

Use the metadata-only mode for the fastest feedback on every skill manifest, fixture path, and frontmatter description:

```powershell
pwsh -NoProfile -File ./scripts/validate-skill-templates.ps1 -MetadataOnly
```

During iteration, run the changed skill's bundled deterministic validator and focused regression scripts. Before completion, run `pwsh -NoProfile -File ./scripts/validate-skill-templates.ps1`; use `-Full` when the slower DocFX suites are relevant. GitHub Actions supplies the same deterministic safety net. This layered path catches structural and behavioral regressions quickly without hidden model traffic.

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
npx skills add https://github.com/codebeltnet/agentic --skill dotnet-change-impact
npx skills add https://github.com/codebeltnet/agentic --skill dotnet-docfx-digest
npx skills add https://github.com/codebeltnet/agentic --skill dotnet-test
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

| Skill | Description |
|-------|-------------|
| [git-visual-commits](skills/git-visual-commits/SKILL.md) | AI-driven git commit workflow with authoritative routing for `git bot commit`, `git commit`, and `git our commit`, including the exact `Please do a git bot commit yolo` form. It locks the requested identity, treats yolo/auto only as scoped auto-approval modifiers, never as the commit message, and does not hand commit execution to changelog or release-note skills. It uses deterministically validated emoji-first subjects, optional conventional prefixes only on explicit request, full-worktree semantic grouping unless narrowed, a visible multi-file single-category quality gate, commit bodies by default, and post-commit identity/body verification. Multi-file plans that initially collapse to one category also require a visible full-context quality gate; one-file changes keep the fast path. Stack-agnostic. |
| [git-keep-a-changelog](skills/git-keep-a-changelog/SKILL.md) | Git-aware Keep a Changelog companion selected only for explicit changelog or release-note intent. Bare yolo/auto and commit-execution requests such as `git bot commit yolo` do not activate it; those words modify autonomy only after changelog intent is established. Bundled deterministic resolvers separate branch-unique commit history from merge-base-to-`HEAD` net diffs, exclude the previous-release or comparison boundary, fail on base-history bleed, and classify explicit path-backed release entities as `Added`, `Removed`, `Changed`, or `Unchanged`. The skill establishes each user-facing release entity against the base before section classification. It asks a mandatory `Yes / No / Custom` question before including pending worktree changes in ordinary concrete-release drafts, includes staged, unstaged, and untracked work automatically only in scoped yolo/auto mode, creates missing changelogs, writes SemVer-aware highlights, maintains compare-link footers, preserves natural prose wrapping, and curates surviving outcomes instead of dumping raw commit logs. |
| [git-nuget-release-notes](skills/git-nuget-release-notes/SKILL.md) | Git-aware NuGet release-notes companion for .NET repos that keep cumulative `.nuget/{ProjectName}/PackageReleaseNotes.txt` files. Discovers packable `src/` projects, resolves concrete package version and availability, creates missing files when needed, reduces each package to its surviving base-to-`HEAD` delta before classifying history, and establishes each package capability against the base so pre-release refinements and fixes to a new capability remain one `ADDED` New Feature. It writes per-package `ALM` / `Breaking Changes` / `New Features` / `Improvements` / `Bug Fixes` style notes from final package state plus supporting commit context instead of dumping commit subjects. |
| [git-nuget-readme](skills/git-nuget-readme/SKILL.md) | Git-aware NuGet README companion for .NET repos that advertise a package from `src/`. Resolves the real packable project the README should sell, combines git history with actual package metadata, source capabilities, and relevant tests when feasible, preserves honest badge/docs/contributing sections, and writes a forthcoming, adoption-friendly `README.md` with repo-derived branding, clear value, install, framework-support, and quick-start guidance. |
| [git-visual-squash-summary](skills/git-visual-squash-summary/SKILL.md) | Non-mutating grouped-summary companion to `git-visual-commits`. Turns the full current feature branch into a curated set of compact lowercase-start summary lines for PR or squash-and-merge contexts by default, comparing against the repository base branch rather than a same-named tracking remote, including commits from all authors unless explicitly narrowed, reducing the cumulative base-to-`HEAD` delta first so reverted churn disappears, preserving technical identifiers, merging overlap, keeping surviving dependency/version changes separate from build/refactor work when the final diff still shows them, and avoiding changelog-style wording, unsupported claims, yolo prompts, needless commit-range questions, or commit-selection UI for ordinary branch-level squash requests. |
| [skill-creator-agnostic](skills/skill-creator-agnostic/SKILL.md) | **⚠️ Deprecated** — no longer maintained and retained only for backward compatibility until **1.0.0**. Do not use it for new skill-authoring work; use Anthropic `skill-creator` together with this repository's `AGENTS.md`. |
| [markdown-illustrator](skills/markdown-illustrator/SKILL.md) | Reads a markdown file and answers directly in chat with one document-wide Visual Brief plus one compiled prompt. Infers a compact visual strategy by default, keeps follow-up questions near zero, and only branches when the user explicitly asks for added specificity. |
| [git-repo-digest](skills/git-repo-digest/SKILL.md) | Turns any full repository URL into a deterministic digest workspace using the bundled .NET file-based runner `scripts/digest.cs`. Requires explicit `--repo-url`, resolves omitted output paths to `<active-workspace>/.bot/digests` and passes that as `--output-root`, maps multiple positional URLs the same way for slash commands, bare pasted URLs, and natural-language requests by treating the first URL as the digest repo and every later URL as repeated `--external-repo-url`, always writes into `{output-root}/{repo-id}/{yyyyMMdd-HHmmssZ}`, accepts repeated curated public consumer repos, derives `{repo-id}`, fixes `result/`, performs shallow git clones, packs local tracked files with the bundled C# packer using `git ls-files`, separates XML evidence into `source.xml`, `tests.xml`, `projects.xml`, editorial `readmes.xml`, and scenario-only `external-usage.xml`, writes package and conceptual overview prompts under `prompts/`, emits public API summaries, engineering signals, evidence indexes, ordered XML chunks, referenced-package evidence maps for aggregate examples, and manifest-backed frontmatter hints, treats previous digest prose as contamination during fresh generation, then guides the agent to fully read the current phase's required evidence before writing package digests and a concept-led `result/Index.md` with YAML frontmatter containing Product-derived overview title metadata, validated documentation URLs resolved from PackageProjectUrl, documentation-host-filtered exact `.nuget/<PackageName>/README.md` documentation links including emoji-prefixed Documentation headings and "More documentation..." blocks, DocFX `metadata[].dest` API paths, and source namespace page candidates from `src/<PackageName>/**/*.cs`, target frameworks, package/library counts, external links, package-family links, and context glyphs, and validates authored result examples with `--validate-results` as a deterministic API-shape, Codebelt.Extensions.Xunit shape, PascalCase `MethodName_Scenario_ExpectedBehavior` test-method naming, Basic usage quality, and optimized NuGet-backed executable test gate with bounded parallelism. |
| [dotnet-new-lib-slnx](skills/dotnet-new-lib-slnx/SKILL.md) | Scaffold a new .NET NuGet library solution following codebeltnet engineering conventions. Dynamic defaults for TFM/repository metadata, latest-stable NuGet package resolution, tuning projects plus a tooling-based benchmark runner, TFM-aware test environments, strong-name signing, NuGet packaging, DocFX documentation, CI/CD pipeline, and code quality tooling. |
| [dotnet-new-app-slnx](skills/dotnet-new-app-slnx/SKILL.md) | Scaffold a new .NET standalone application solution following codebeltnet engineering conventions. Supports Console, Web, and Worker host families with Startup or Minimal hosting patterns; Web expands into Empty Web, Web API, MVC, or Web App / Razor, plus functional tests and a simplified CI pipeline. |
| [trunk-first-repo](skills/trunk-first-repo/SKILL.md) | Initialize a git repository following [scaled trunk-based development](https://trunkbaseddevelopment.com/#scaled-trunk-based-development). Seeds an empty `main` branch, creates a versioned feature branch (`v0.1.0/init`), confirms configured remotes in its post-init summary, and supports a guarded later `push remote <url>` mode that checks the feature-branch/empty-main state before pushing `main` ahead of the first feature branch so content still reaches main only through peer-reviewed pull requests. |
| [dotnet-strong-name-signing](skills/dotnet-strong-name-signing/SKILL.md) | Generate a strong name key (`.snk`) file for signing .NET assemblies using pure .NET cryptography — no Visual Studio Developer PowerShell or `sn.exe` required. Works in any terminal. Defaults to 1024-bit RSA (matching `sn.exe`), with 2048 and 4096 available as options. |
| [git-remote-release](skills/git-remote-release/SKILL.md) | Generate GitHub release notes by summarizing all commits and pull requests between two Git tags or branches in a remote GitHub repository. Accepts a compare URL or separate owner/repo, previous ref, and current ref values; falls back to comparing the current branch against the upstream default branch when no input is provided. Produces a human-friendly `## What's Changed` summary with optional GitHub alert blocks, a `Sources:` section preserving PR and commit references, and a full changelog compare link. |
| [dotnet-change-impact](skills/dotnet-change-impact/SKILL.md) | Classify .NET library or NuGet package changes and recommend the correct release bump — `Major`, `Minor`, or `Patch` — for both Semantic Versioning (`MAJOR.MINOR.PATCH`) and .NET assembly/file versioning (`Major.Minor.Build.Revision`), grounded in Microsoft's official .NET compatibility rules. Uses the current Git branch by default when no explicit change details or compare range are provided, resolving it against the upstream/default base branch with local read-only git state. Always returns structured behavioral/binary/source/design-time/backwards compatibility reasoning with the recommendation, even when the bump is clear. |
| [dotnet-docfx-digest](skills/dotnet-docfx-digest/SKILL.md) | Create and maintain developer-friendly DocFX documentation for .NET public APIs, including repo-wide no-input audits that inspect source, tests, DocFX config, DocFX `build.content` and `build.overwrite` Markdown inputs, namespace pages, and availability includes before asking for clarification, while treating bare direct skill invocations as autonomous repo-wide runs rather than human-driven checkpoint sessions. Enforces the workflow with two bundled .NET 10 file-based scripts resolved from the loaded skill directory, falling back to the repo-managed source path only when present: `scripts/agents.cs` writes an idempotent, marker-bounded DocFX maintenance block into the repository `AGENTS.md`; `scripts/docfx.cs` is **fast and build-free by default** — it validates Markdown, prose, DocFX overwrite layout, namespace overview pages, `Extension Members` tables, decorated receiver signatures such as `IDecorator<Type>`, generic method displays such as `As<T>`, purpose-first summaries, and required per-type/extension examples without invoking `dotnet`, `msbuild`, `docfx`, or `gh`, discovering the public API from existing DocFX YAML metadata or a conservative source scan and ending every run with a `[processes] dotnet=0 msbuild=0 docfx=0 gh=0` summary plus per-phase timings. Compilation and network access are strictly opt-in: `--validate-samples` compiles each C# sample in an isolated project while batching all sample projects into one temporary `.slnx` graph build with bounded MSBuild parallelism and scoped references, `--build-api-model` (alias `--strict-api-discovery`) does reflection-backed discovery from compiled metadata via `MetadataLoadContext` through a single scoped `.slnx` graph build, `--verify-docfx-build` runs the DocFX CLI in a temp copy, and `--search-examples` runs `gh` code search. Final verification adapts to available processors and memory, overlaps isolated DocFX work on high-capacity machines, uses a 30-minute child timeout, and emits 10-second `stderr` heartbeats with active phase, workload, runner count, PID, elapsed time, last-output age, and current child output while preserving machine-readable JSON on `stdout`. Honors a single DocFX metadata `TargetFramework` when `--framework` is omitted, collapses C# 14 extension-block compiler containers such as `<G>$...` back to the authored outer static class in both fast DocFX-YAML discovery and build-backed reflection discovery, validates namespace fly-ins that explain the problem solved/when to use/where to start plus example fly-ins before every C# fence, the Codebelt namespace-and-type-folder overwrite layout (`.docfx/api/namespaces/**/*.md` and `.docfx/api/types/**/*.md` under `build.overwrite` only), keeps `--changed-only` validation scoped to affected docs and APIs while still including brand-new untracked overwrite Markdown, uses the root Codebelt `.snk` when present and falls back to `-p:SkipSignAssembly=true` for keyless strong-name build verification, drains child stdout and stderr concurrently to avoid verbose-build deadlocks, writes deterministic `--assessment-queue` Markdown work queues for noisy audits, preserves working URL references unless a verified HTTP 404 justifies removal, treats unexpected new repo-root or DocFX-workspace files that are not known `dotnet-docfx-digest` deliverables as blocking cleanup diagnostics, keeps assessment/manifests/captured output/helper scripts in temp or session storage instead of the target repository, requires a namespace-first pass across the active queue before net-new type/example authoring during full audits, keeps deeper `EXTENSION_METHOD_MISSING` and `EXTENSION_METHOD_SIGNATURE_MISSING` follow-on diagnostics in that same namespace-layer table-repair phase when they appear after `EXTENSION_SECTION_MISSING` drops, preserves existing BOM and line-ending state while flagging actual mojibake instead of creating encoding-only diffs, and leaves generated DocFX YAML metadata untouched unless `--clean-generated-metadata` is explicitly requested (which runs only after the API model is built, never deleting metadata the run relied on). Documents public API only, uses bundled reference docs for overwrite rules, workflow details, and script behavior, keeps authored API overwrite Markdown under `.docfx/api/namespaces/` and `.docfx/api/types/`, moves legacy authored `.docfx/api/*.md` overwrite files there instead of widening the glob to `api/**/*.md`, teaches namespace and API prose to orient newcomers around purpose instead of inventorying contents, prefers inline or small sibling-batch prose repairs over slow per-page worker fan-out, makes examples start from package-ID usage evidence before type/member-only searches and requires each example to introduce the consumer task before the code, allows multi-type Microsoft Learn-style scenario samples when they better explain the consumer workflow, keeps extension-method examples on readable declaring-class type pages under `.docfx/api/types/` instead of synthetic method-UID filenames or namespace pages that mix extra `uid:` / `example:` blocks into the overview, flags weak skip-compile reasons, requires deterministic `.docfx/skip-compile-allowlist.json` entries for any pre-existing approved skip waivers, treats newly introduced or unallowlisted skip markers as fail-level diagnostics that do not suppress compilation, establishes reflection-backed packets with `--build-api-model --project-manifest` before full-run authoring, forces mid-audit continuations to name that manifest or the sequential assessment/namespace-first fallback explicitly, requires those continuations to restate the fast `docfx.cs --json` rerun cadence, the exact final `docfx.cs --build-api-model --validate-samples --verify-docfx-build --json` gate, and the clean JSON completion contract instead of generic “verify later” prose, treats batch size only as rerun cadence rather than permission to stop, runs a completion repair loop that treats every diagnostic as active work regardless of age or volume, treats newly surfaced follow-on diagnostics as the next repair queue instead of a stop point, reruns packet discovery with `--build-api-model --project-manifest` when fast source-scan packets are unnamed or zero-project, falls back to sequential namespace-first or assessment work queue order when packet discovery is still unusable, treats `EXAMPLE_MISSING`, `EXAMPLE_LEAD_MISSING`, `EXAMPLE_ADVANCED_LEAD_MISSING`, `FAMILY_ANCHOR_EXAMPLE_MISSING`, `SAMPLE_STRUCTURE_INVALID`, `FAIL_NEW_SKIP_MARKER_INTRODUCED`, `SAMPLE_SKIP_NOT_ALLOWLISTED`, and `INTERIM_ARTIFACT_IN_WORKTREE` queues as core work rather than checkpoints or quality backlog, drives large example and lead queues through a concrete fast-path micro-loop (next item or next 3-5 items → rerun → continue), suppresses progress-table/checkpoint output until the completion contract is clean or a real external blocker is reported, treats premature completion-shaped handoffs as execution-protocol failures while the queue is still dirty, reserves the final `--build-api-model --validate-samples --verify-docfx-build` verification for the real end of the queue, exposes `summary.fullVerificationRan`, `summary.canClaimCompletion`, `summary.remainingWorkItems`, `summary.remainingDiagnosticsByCode`, `summary.newlyIntroducedSkipMarkers`, and `summary.interimArtifacts` as machine-readable final gates, reruns the fast `docfx.cs --json` after edits until the queue is empty, then runs the build-backed verification before completion, preserves manual edits and authored Markdown during cleanup, skips recursive generated-output cleanup when a target directory contains documentation or source files, and returns deterministic exit codes plus `--json` reports (including process counts, phase timings, warning counts, and skip-marker accounting) so CI can gate on real failures instead of AI claims. |
| [dotnet-test](skills/dotnet-test/SKILL.md) | Bootstraps and refactors xUnit projects to Codebelt conventions. It deterministically inspects project roles, target frameworks, xUnit generation, package ownership, inheritance, application entry points—including Bootstrapper `MinimalConsoleProgram`, `MinimalWorkerProgram`, and `MinimalWebProgram` hosts—and every selected `WebApplicationFactory` usage; classifies ordinary unit, ASP.NET Core functional, and console/worker functional tests; modernizes xUnit v2 projects to xUnit v3 plus Microsoft Testing Platform without moving package ownership or changing frameworks; and resolves current stable compatible packages through NuGet-backed isolated compatibility-project restores, including the selected combined package set. Focused web tests use `WebApplicationTestFactory` with an explicit entrypoint-owned `ManagedWebApplicationFixture`, directly or through a narrow `Test`-derived harness; shared web fixtures use `WebApplicationTest` with `ManagedWebApplicationFixture`; focused console/worker tests use `ApplicationTestFactory` with `ManagedApplicationFixture`; and shared non-web fixtures use `ApplicationTest` with `ManagedApplicationFixture`. Deprecated blocking fixtures are migration inputs only and are never emitted because they are scheduled for removal. Functional migrations fail closed unless the chosen Codebelt pattern and managed fixture are present, the legacy or blocking fixture is absent, and test code does not reconstruct the production composition root with its own `WebApplication`, `TestServer`, or `HostBuilder`. Migrations preserve entrypoint-owned startup, host configuration, lazy start, clients, services, configuration, sync/async disposal, isolation, and existing test names, while fresh bootstraps add source-grounded behavior tests. Non-web tests stay in-process and require a resolvable Generic Host; test-only scope reports the exact production adaptation instead of silently rewriting startup or launching a process. |
| [dotnet-benchmark](skills/dotnet-benchmark/SKILL.md) | Discovers, prioritizes, and authors trustworthy BenchmarkDotNet experiments for a .NET type following codebelt conventions and using the `Codebelt.Extensions.BenchmarkDotNet.Console` runner. It inspects implementation code, call sites, tests, existing benchmarks, and available profiles instead of benchmarking every public member; ranks likely high-impact operations; selects representative typical, boundary, scaling, and adverse cases; and rejects external-I/O or service-level questions that need profiling, macrobenchmarks, or load tests. It creates fair current-versus-candidate comparisons only when observable work is equivalent, uses baseline-free single-operation characterization when no honest comparator exists, prevents unrelated construction/formatting/equality/hash ratios, requires exact per-case correctness oracles plus a semantic preflight for truthful workload labels, hard-gates interpretation on a complete valid BenchmarkDotNet summary, preserves workload invariants such as selectivity and hit/miss ratios as sizes scale, distinguishes deferred pipeline creation from terminal/materialization work, and performs Release build, discovery listing, and dry execution before any explicit full run. Explicit `yolo` mode auto-accepts routine repo-derived defaults and the proposed plan, then proceeds through build/list/dry validation without confirmation churn; only a separate explicit human instruction can start a full performance run. Its runner preflight recognizes the standard Slim/runtime setup and explains when `SkipBenchmarksWithReports = true` plus a matching `reports/tuning/` artifact deliberately filters a benchmark, preventing needless class renames, disassembly, or tool thrash; after the first valid full result it stops unless deeper diagnostics could change a real engineering decision. Harness setup remains adaptive: it detects `.slnx`/`.sln`, CPM, existing `tuning/` projects, and a reusable `tooling/` runner, onboards only missing pieces, resolves package versions dynamically, and keeps the benchmark class in the SUT namespace. |
| [dotnet-remote-testing](skills/dotnet-remote-testing/SKILL.md) | Run .NET tests inside a resolved remote Docker environment and return concise, structured results — Visual Studio's Remote Testing experience (choose an environment → run tests → see results) with the container plumbing hidden behind a deterministic runner (`scripts/remote-test.cs`) the skill orchestrates instead of composing ad-hoc `docker run` commands. It honors Microsoft's existing `testenvironments.json` version-1 contract (`name`, `localRoot`, `dockerImage`, `dockerFile`, with the either/or Docker-source rule), treats that file as authoritative when present, and reports WSL/SSH/unknown types as unsupported rather than converting or silently ignoring them. When no `testenvironments.json` exists it provides a zero-configuration experience built exclusively on official `mcr.microsoft.com/dotnet/sdk` images, discovering the currently supported LTS and STS channels plus the current preview from Microsoft's live `releases-index.json` using `support-phase`/`release-type` (never hardcoded version numbers or even/odd assumptions) and caching that metadata outside the repository for offline reuse. It prefers an exact `latest-sdk` image tag (stripping preview build metadata), validates the tag against Microsoft's registry, and pins each execution to the resolved immutable digest so results are reproducible across environment, image, digest, SDK, and architecture. Execution stages the source into an isolated workspace so container builds never leave Linux `bin`/`obj` in the working tree, mounts a persistent NuGet cache outside the repo, runs restore → build → test with structured TRX collection, classifies failures into distinct kinds (configuration, unsupported environment, Docker unavailable, image resolution, SDK incompatibility, staging, restore, compilation, test-host, test failure, result-processing, cleanup, cancellation, release-metadata) so infrastructure problems are never reported as failing unit tests, and always cleans up transient Docker resources. It never generates a `Dockerfile`, dev container, compose file, or editor configuration (an existing configured `dockerFile` is honored, never created), never runs privileged containers or mounts the Docker socket, and never silently falls back to running tests on the host. Docker is the only transport for now, designed so WSL/SSH can be added later without disturbing the deterministic Docker path, which is covered by a comprehensive built-in `--self-test` plus a PowerShell harness. |
| [dotnet-segregated-assets](skills/dotnet-segregated-assets/SKILL.md) | Migrate or configure ASP.NET Core static delivery with `codebeltnet/web-cdn-origin:2.0.0` while keeping `wwwroot` as the authoring root. The deterministic runner inspects and verifies topology, publish exclusion, Static Web Assets risks, Cuemon signals, competing `AppAssetOptions`-style abstractions, actual `app-*`/`cdn-*` markup, and scheme-safe local origins; the agent performs semantic edits. For an existing Cuemon package reference, its plan resolves the highest stable version from NuGet.org at execution time, preserves Central Package Management versus inline ownership, excludes prereleases, and fails rather than copying an old fixture or example version. It reuses Cuemon `AppTagHelperOptions`/`CdnTagHelperOptions`, `BaseUrlMode`, and the public `app-link`, `app-script`, `app-img`, `cdn-link`, `cdn-script`, and `cdn-img` helpers when already available, otherwise reuses a suitable project abstraction without adding Cuemon. It keeps App and shared CDN ownership separate, preserves ordinary Project-based Development, adds opt-in segregated Development through a root Docker Compose profile, and makes `compose.assets.yml` directly build artifact-first `LocalDevelopment.Dockerfile` and `Assets.Dockerfile` images. Production CI publishes the same application artifact for the shell-less runtime `Dockerfile`. The skill excludes app-owned `wwwroot` with targeted MSBuild metadata, preserves `_content`/`_framework` and generated Static Web Assets, and proves publish/local invariants deterministically and idempotently. |
| [agent-smith](skills/agent-smith/SKILL.md) | Apply a rigorous, consistent, evidence-driven software-craftsmanship standard across a whole engineering task. Invoke explicitly as `/agent-smith <task>` or let it auto-trigger for design, architecture, implementation, refactoring, code review, public API review, compatibility and Semantic Versioning analysis, testing, benchmarking, performance, skill authoring, documentation, security and DevSecOps, CI/CD, delivery, repository governance, and engineering assessment. Skill-authoring mode grounds instructions in real execution, requires an explicit bounded-concurrency assessment so independent data retrieval and eval work do not remain sequential by habit, favors reusable C#/.NET scripts and validators against the dynamically resolved latest supported LTS when local constraints do not decide, and follows the Agent Skills guidance for progressive disclosure, description optimization, candidate-versus-baseline evaluation, aggregation, and human review. Its optional .NET EditorConfig conformance mode handles targeted IDE/CA diagnostic remediation and full informational-or-higher `dotnet format` conformance without treating a clean build as proof of policy compliance: user-defined diagnostic IDs remain task-supplied data; target, path, and severity scope remains authoritative; informational workflows explicitly preserve `--severity info` because the formatter defaults to `warn`; targeted IDE and analyzer checks use category-specific formatter subcommands; every formatter invocation is read-only via `--verify-no-changes`; `--no-restore` is never treated as a conformance fallback; fixes are deliberate source edits; repeated multi-target findings are de-duplicated by physical file, diagnostic, and span; and the bundled `repair-roslyn-multiproject-artifacts.ps1` detects conflict artifacts independently of diagnostic ID, preflights directory repairs without partial writes, repairs only proven structural patterns, and refuses unrecognized shapes. Completion requires the same scoped formatter gate plus an artifact scan before affected builds and relevant tests. Technology-neutral work remains unaffected. Performs the requested work (not just a review), loads only relevant `references/`, respects repository conventions, scales process depth without lowering the standard, and reports evidence and risk honestly in concise feedback that may sacrifice grammar but never required evidence. Governing principle: consistency is key. | Invoke explicitly as `/agent-smith <task>` or let it auto-trigger for design, architecture, implementation, refactoring, code review, public API review, compatibility and Semantic Versioning analysis, testing, benchmarking, performance, skill authoring, documentation, security and DevSecOps, CI/CD, delivery, repository governance, and engineering assessment. Skill-authoring mode grounds instructions in real execution, requires an explicit bounded-concurrency assessment so independent data retrieval and eval work do not remain sequential by habit, favors reusable C#/.NET scripts and validators against the dynamically resolved latest supported LTS when local constraints do not decide, and follows the Agent Skills guidance for progressive disclosure, description optimization, candidate-versus-baseline evaluation, aggregation, and human review. Its optional .NET EditorConfig conformance mode handles targeted IDE/CA diagnostic remediation and full informational-or-higher `dotnet format` conformance without treating a clean build as proof of policy compliance: user-defined diagnostic IDs remain task-supplied data; target, path, and severity scope remains authoritative; informational workflows explicitly preserve `--severity info` because the formatter defaults to `warn`; targeted IDE and analyzer checks use category-specific formatter subcommands; every formatter invocation is read-only via `--verify-no-changes`; `--no-restore` is never treated as a conformance fallback; fixes are deliberate source edits; repeated multi-target findings are de-duplicated by physical file, diagnostic, and span; and the bundled `repair-roslyn-multiproject-artifacts.ps1` detects conflict artifacts independently of diagnostic ID, preflights directory repairs without partial writes, repairs only proven structural patterns, and refuses unrecognized shapes. Completion requires the same scoped formatter gate plus an artifact scan before affected builds and relevant tests. Technology-neutral work remains unaffected. Performs the requested work (not just a review), loads only relevant `references/`, respects repository conventions, scales process depth without lowering the standard, and reports evidence and risk honestly in concise feedback that may sacrifice grammar but never required evidence. Governing principle: consistency is key. |

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
npx skills add https://github.com/codebeltnet/agentic --skill dotnet-benchmark
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

Sometimes the history is already written and the only thing you need is the final grouped summary. A long branch with fixups, rename follow-ups, review nits, and repeated attempts often contains a few real change themes buried inside a messy chronological story. That is where **git-visual-squash-summary** fits: it reads the real history and diff, then compresses them into a small set of truthful grouped lines.

- **Same visual language** — reuses the same emoji-first wording rules as `git-visual-commits`, including lowercase descriptions after the emoji unless a leading technical identifier requires original casing
- **Grouped-lines only** — returns compact grouped lines only, not a title or body
- **Non-mutating by design** — drafts the wording only and does not touch git state
- **Whole-branch by default** — for squash-and-merge requests, uses the full current feature branch from merge-base to `HEAD` instead of asking which branch commits to include
- **All authors included** — branch-level summaries treat branch topology as the scope and include every contributor's commits unless the user explicitly asks for an author-filtered summary
- **Bare invocation means summarize now** — calling `git-visual-squash-summary` directly should resolve the current branch scope automatically and return the grouped lines, not a "what do you want me to summarize?" question
- **Base branch, not tracking copy** — a feature branch that is in sync with `origin/<current-branch>` is still summarized against `origin/HEAD`, `origin/main`, `origin/master`, `main`, or `master` before declaring there is nothing to summarize
- **No yolo prompt** — the skill is read-only, so it acts directly without asking for auto-approval language from mutating workflows
- **No commit-picker UX** — ordinary branch-level squash requests do not become commit-selection questions or widgets; the skill resolves the branch scope and writes the summary
- **Distinct efforts stay distinct** — preserves meaningful change groups instead of forcing one umbrella line
- **Final-state first** — computes the cumulative base-to-`HEAD` delta before reading chronology, so reverted experiments and temporary implementations disappear
- **Surviving dependency truth** — package/version changes stay explicit when they survive in the final diff and disappear entirely when they return to the base value
- **Intent over chronology** — collapses noisy commit stacks into the retained grouped effort
- **Low-signal noise gets dropped** — typo-only and trivial fixup churn do not deserve their own lines
- **Late release-prep commits stay in scope** — changelog, version-bump, and release-finalization follow-ups are treated as part of the branch by default and then merged or dropped during semantic collapsing
- **Identifier-safe wording** — preserves technical names, paths, flags, and types where possible
- **Readable in GitHub and terminals** — optimized for compact PR and squash-summary views
- **Strict 72-char lines** — every summary line stays compact and scannable
- **Not a changelog** — avoids release-note phrasing and commit-subject dumps
- **No unsupported claims** — summarizes only what the inspected diff can justify

### Why git-keep-a-changelog?

Writing `CHANGELOG.md` well is harder than it looks. Raw commit subjects are too noisy, PR titles often miss migration context, and release notes get much better when the writer actually reads the commit bodies and understands the net diff. That is where **git-keep-a-changelog** fits: it turns the current branch into a curated Keep a Changelog entry and creates or updates the file directly for review.

- **Keep a Changelog first** — writes `Added`, `Changed`, `Deprecated`, `Removed`, `Fixed`, and `Security` sections in the expected style
- **Full-commit context** — reads complete commit messages and the net diff before writing
- **History is evidence, result is truth** — reduces the selected range to surviving base-to-`HEAD` outcomes before section classification, so reverted work disappears and one surviving capability is described once
- **Unreleased draft rewrites** — if a version-branch heading already exists but its tag does not, the skill regenerates that draft from git truth so new-capability refinements stay under `Added` until release
- **Deterministic release isolation** — resolves the real comparison branch, excludes its merge boundary, and verifies that no commit already on the base branch can bleed into the new release
- **PR-complete history** — keeps every branch-unique commit from every contributor while avoiding a same-name feature tracking ref as the comparison base
- **Cumulative dependency coverage** — when version manifests changed across the release range, diffs them from base to `HEAD` so the changelog reflects the surviving package/version story instead of only per-commit fragments
- **Whole-branch by default** — treats the selected branch or range as author-agnostic scope, so all contributors' commits are in play unless you explicitly narrow by author
- **Version-aware by branch** — uses a branch prefix like `v0.3.0/...` as the release heading hint when present
- **Mandatory pending-worktree gate** — when a concrete release has uncommitted changes, the skill must ask a short `Yes / No / Custom` confirmation question before folding them into the changelog draft, with a `FORMS.md` definition that compatible hosts can render as native choices
- **Trigger isolation** — yolo/auto modifies an explicit changelog request but never activates this skill for `git bot commit yolo` or another commit-execution request
- **Scope-safe yolo mode** — includes staged, unstaged, and untracked work automatically without changing the committed-history boundary
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
- **Concrete package metadata** — resolves `Version:` and `Availability:` from the branch/project instead of inventing placeholders
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

`skill-creator-agnostic` is now a legacy compatibility artifact, not an active skill-authoring workflow. It is **⚠️ Deprecated**, no longer maintained, and scheduled for removal in **1.0.0**.

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

> [!NOTE]
> These scaffolds are not speculative starter kits. They capture conventions already exercised across Codebelt repositories and turn them into a repeatable methodology for new solutions.

- **Convention over configuration** — opinionated defaults that match real production setups
- **Focused skills** — library and app concerns are fully separated, no variant confusion
- **Lower cognitive load** — the library scaffold defaults the main project name from the solution name, pre-fills the repository URL from the repo root folder name, and lets the package website reuse that value unless you override it
- **Default-friendly prompts** — when a scaffold form already shows a recommended value such as `root_namespace = solution_name`, leaving the field blank should accept that default instead of sending the agent into a follow-up loop
- **Structured-input fallback stays consistent** — when a host does not render native form widgets, the scaffold skills now fall back to a deterministic one-field-at-a-time plain-text format instead of improvising the UX
- **Explicit host prompts stay on rails** — if you already asked for `Console`, `Worker`, `Web API`, `MVC`, or `Razor`, the scaffold flow should preselect that host choice and move straight to the remaining fields instead of asking you to restate it
- **Modern TFM choices** — the .NET scaffold skills compute active target framework quick-picks from the official .NET releases index, offering every supported non-preview LTS and STS channel plus an expanded multi-target preset where applicable
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

### Why git-remote-release?

Writing release notes is tedious. Raw commit logs are too noisy, PR titles often lack context, and the best release notes explain what changed and why it matters — not just what was merged. That gap between "here are the commits" and "here is what this release means for you" is where **git-remote-release** fits.

**git-remote-release** reads all commits and pull requests between two tags or branches in a remote GitHub repository and produces a polished, paste-ready release note.

- **Remote-first workflow** that works entirely through GitHub's API, with no local clone required,
- **Compare URL awareness** where a pasted GitHub compare URL is used to extract the owner, repository, and both tags,
- **Pull request-preferred analysis** that uses rich PR metadata when available and gracefully falls back to raw commits,
- **Default-branch-aware comparisons** that resolve the upstream base and collect only commits on the current branch,
- **Effect-oriented summaries** that explain what users and maintainers can expect from the release, not just what code was merged,
- **Thematic grouping** where related changes are discussed together instead of listed chronologically,
- **GitHub alert blocks** that use `NOTE`, `TIP`, `IMPORTANT`, `WARNING`, and `CAUTION` alerts sparingly and only when the release data supports the attention level,
- **Source preservation** where every release note includes a `Sources:` section with the original PR and commit references,
- **Strict format** that always starts with `## What's Changed` and always ends with the full changelog compare link,
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

### Why dotnet-docfx-digest?

API documentation rots the moment code changes. A new public type ships without a namespace page, an extension method never makes it into the `Extension Members` table, a copy/paste example silently stops compiling, and "availability" drifts away from the real target frameworks. The usual fix — telling an agent to "remember to update the docs" — relies on AI memory, which is exactly the thing that fails on the next change.

**dotnet-docfx-digest** moves the rules from prose into deterministic .NET 10 tooling, so guidance persists and verification is real.

- **No-input audits by default** — `Use dotnet-docfx-digest` means inspect the repository, DocFX config, public API, tests, samples, overwrite files, namespace pages, and availability includes, then repair missing complementary documentation that can be derived from evidence before asking any clarifying questions. A host that later re-enters with a bare `dotnet-docfx-digest` call and no extra arguments is still the same autonomous repo-wide continuation, not a fresh checkpoint,
- **Fast by default, builds only on demand** — a plain `scripts/docfx.cs` run validates Markdown, prose, DocFX overwrite layout, namespace pages, extension tables, and required examples **without invoking `dotnet`, `msbuild`, `docfx`, or `gh`**, discovering the public API from existing DocFX YAML metadata or a conservative source scan and proving it with a `[processes] dotnet=0 msbuild=0 docfx=0 gh=0` summary plus per-phase timings on every run. Five clearly separated paths layer on cost only when asked: fast Markdown validation (default), `--validate-samples` for C# sample compilation, `--build-api-model` for reflection-backed API discovery, `--verify-docfx-build` for the DocFX build, and `--search-examples` for GitHub usage search,
- **Persistent guidance by script, not memory** — `scripts/agents.cs` is resolved from the loaded skill directory, with a repo-managed source fallback when present, then writes an idempotent, marker-bounded DocFX maintenance block into the target repository `AGENTS.md`; that block preserves the full `--build-api-model --validate-samples --verify-docfx-build` completion gate so sample compilation cannot be skipped, running it twice never duplicates the block, and `--check` gates it in CI,
- **DocFX overwrite grounding** — the skill includes a concise `references/docfx-overwrite-files.md` summary of the official overwrite-file and `docfx.json` rules agents need when creating namespace fly-ins, summaries, examples, remarks, and extension-member documentation,
- **Verification without a build, precision on demand** — by default `scripts/docfx.cs` discovers public API, namespaces, required public non-abstraction type targets (including public static classes), and extension methods without compiling: it reads existing DocFX ManagedReference YAML under `metadata.dest` when present, otherwise runs a conservative source scan over the projects referenced by `docfx.json`, and warns (`API_MODEL_SOURCE_SCANNER_LIMITED`) that the precise path is opt-in. Adding `--build-api-model` (alias `--strict-api-discovery`) builds only the documented project graph through a single scoped `.slnx` graph build and discovers from compiled metadata via `MetadataLoadContext` with project-output, project-reference, project-asset, deps-file, and framework-pack dependency resolution. Project-output resolution scans only the selected framework's direct output directory, preventing cross-TFM and `runtimes/` assemblies from entering the resolver,
- **Codebelt signing-key aware** — strong-name signed Codebelt repositories use the root `.snk` file when it is present, while keyless checkouts and temp workspaces verify with `-p:SkipSignAssembly=true` so missing local author keys do not look like documentation drift,
- **Decision-useful namespace checks** — uid front matter, availability, and `Extension Members` tables are validated against the actual public surface, while semantic gates reject inventory-only prose, weak inventory leads left intact beneath an appended start-here sentence, and mechanical prose templates shared across pages, requiring concrete when-to-use and start-here guidance with diagnostics such as `NAMESPACE_PROSE_INVENTORY_ONLY`, `NAMESPACE_APPEND_ONLY_REPAIR`, `NAMESPACE_PROSE_TEMPLATE_REPETITION`, `NAMESPACE_USAGE_GUIDANCE_MISSING`, and `NAMESPACE_START_HERE_MISSING`,
- **Less templated namespace prose** — start-here wording is reserved for namespaces where readers need to choose among multiple entry points; single-entry namespaces should describe the direct action and outcome instead of formulaic `Start with X on Y to register Z conventions` prose,
- **Source-backed extension tables** — `Extension Members` tables are checked in both directions: missing real extension methods still fail, and invented or stale method names now fail with `EXTENSION_METHOD_UNKNOWN` instead of letting plausible package-derived setup names such as `AddCuemonTextJson` slip into namespace prose and tables,
- **Deterministic assessment work queues** — `scripts/docfx.cs --assessment-queue <path>` converts noisy validation output into a grouped Markdown work queue with repository guidance, namespace/table repairs, a required-example inventory that follows the namespace-first repair pass, sample failures, cleanup gates, no-broad-restore rules, related-namespace coverage, and diff-review completion checks so agents do not update one namespace and forget the rest,
- **Known-file cleanup gate** — interim artifacts never belong in the target repository. New working-tree files must be recognizable `dotnet-docfx-digest` deliverables: the managed `AGENTS.md` block, the active `docfx.json`, the deterministic `skip-compile-allowlist.json` waiver file when one is genuinely required, or DocFX-authored namespace/type Markdown that maps to real public API. The validator auto-detects generic-arity type families and skips redundant sibling examples from the public API surface alone, so no family-skip manifest is ever written into the repository. Anything else is a blocking cleanup diagnostic and belongs in `%TEMP%`/session storage instead,
- **Continuation-safe large-queue behavior** — a first rerun that still reports hundreds or thousands of repairable diagnostics is not a reason to stop, summarize, or ask permission. The next response must treat that output as the active queue, name the packet-manifest or sequential namespace-first fallback being used, restate the fast `docfx.cs --json` rerun cadence, and keep the exact final completion gate explicit,
- **No premature handoff** — while `summary.canClaimCompletion` is false, `summary.remainingWorkItems` is non-zero, `summary.remainingGates` is non-empty, `summary.fullVerificationRan` is false, fail-level diagnostics remain, or skip/interim counts are non-zero, the next action must be more remediation, a validator rerun, a validator/tooling fix, or a true blocker with exact evidence — never a final report, completion summary, audit handoff, or “next steps” menu,
- **Context-exhaustion-safe continuation** — context pressure is not a completion condition; while work remains, the only valid next actions are smaller deterministic repair batches, queue/manifest regeneration with concrete temp/session paths, validation reruns, validator/tooling fixes, or a true blocker with exact evidence. Stopping because of context size, session length, task size, repetitive authoring, a stable queue, or "better suited for a follow-up" is a protocol failure (`FAIL_CONTEXT_HANDOFF_WITH_REMAINING_WORK`), not a digest result,
- **No quality-backlog escape hatch** — compile success, sample counts, or a verified DocFX build do not make remaining prose, cleanup, ownership, or skip-marker diagnostics optional. `EXAMPLE_LEAD_MISSING`, `EXAMPLE_ADVANCED_LEAD_MISSING`, `FAMILY_ANCHOR_EXAMPLE_MISSING`, `SAMPLE_STRUCTURE_INVALID`, `FAIL_NEW_SKIP_MARKER_INTRODUCED`, `SAMPLE_SKIP_NOT_ALLOWLISTED`, `INTERIM_ARTIFACT_IN_WORKTREE`, `SYMBOL_COLLISION_UNRESOLVED`, and `EXTENSION_OWNER_AMBIGUOUS` require direct repair in small batches with fast reruns until the completion contract is clean,
- **Managed-reference-safe overwrite layout** — public non-abstraction types and public extension methods must have examples in DocFX overwrite content included by `build.overwrite`; the validator discovers Markdown from configured DocFX inputs instead of scanning the whole repository when `docfx.json` is at the root, concrete-type examples are tracked through an explicit inventory and created in readable authored files under `.docfx/api/types/`, legacy authored `.docfx/api/*.md` overwrite files move into `api/namespaces/` or `api/types/` instead of widening the glob to `api/**/*.md`, both overwrite trees stay excluded from `build.content`, C# extension-block compiler containers such as `<G>$...` are collapsed back to the authored outer static class, extension-method examples default to readable declaring-class type pages under `.docfx/api/types/` instead of URL-encoded method-UID filenames or namespace pages that mix overview and member UIDs, namespace pages fail validation when they embed secondary `uid:` / `example:` sections, and agents must rerun the completion repair loop until diagnostics and overwrite-layout failures are fixed or exact blockers are reported,
- **Concept-led namespace quality** — moving concrete examples to type pages must not hollow out namespace pages; namespace pages still need newcomer-oriented fly-ins that explain the problem solved, when to use the namespace, where to start, type-family context, extension-method group explanations, availability, and pointers to representative type pages, and nearby type/member summaries should stay purpose-first too,
- **Examples that teach a real workflow** — examples start from package IDs and package-level evidence before falling back to type/member-only searches, prefer README, package docs, tooling, tuning, functional-test, and external GitHub usage when available, may include multiple related public types when that is what makes the consumer scenario understandable, keep extension-container prose focused on what callers can do with the receiver instead of on declaration syntax, discover public acquisition paths from signatures, docs, tests, and other evidence instead of assuming direct construction from implementation details, and rewrite copied test evidence into lean consumer-facing code rather than dragging obvious framework FQNs into the sample body,
- **Examples arrive with context** — every validated C# example needs a human-written fly-in immediately before the fence, and larger or setup-heavy examples need a deeper lead that explains setup, prerequisites, or workflow outcome, so example pages read like intentional guidance rather than code dropped onto a page,
- **Semantic example quality gates** — compilation-valid filler no longer passes: the validator rejects duplicate UID mappings, `Type.GetType`/assembly metadata scaffolds, runtime implementation names presented as outcomes (`EXAMPLE_RUNTIME_TYPE_NAME_OUTCOME`), empty local `Program` stubs in conventionally named application-entry-point samples such as `AppFactory`, `WebTestFactory`, or `HostFixture` (`EXAMPLE_EMPTY_ENTRY_POINT_STUB`) while excluding unrelated names such as `ApplicationRepositoryFactory`, generic `DocumentedTypeExample`/`Describe()` templates, type examples that never use the target in code, extension examples that mention a method only in prose instead of invoking it, examples without a human fly-in (`EXAMPLE_LEAD_MISSING`), advanced examples with shallow setup context (`EXAMPLE_ADVANCED_LEAD_MISSING`), `default!`/`null!` holder properties (`EXAMPLE_DEFAULT_PLACEHOLDER`), classes that only construct or return the target with no observable result (`EXAMPLE_NO_OBSERVABLE_OUTCOME`), mass-forwarding shells of one-line pass-throughs (`EXAMPLE_FORWARDING_SCAFFOLD`), one normalized code skeleton reused across three or more unrelated targets (`EXAMPLE_TEMPLATE_REPETITION`), and avoidable `System.*` / `Microsoft.*` fully qualified framework references in executable sample code (`EXAMPLE_FULLY_QUALIFIED_FRAMEWORK_TYPE`),
- **Key-entry-point storytelling** — namespace guidance starts from release notes, package documentation, public factories/builders, and strong functional tests so new product-defining APIs are not buried beneath naming conventions. When a package complements an upstream framework type, the skill compares acquisition, customization, lifecycle, sharing, and observable outcomes from current official guidance instead of making unsupported replacement claims,
- **Correct source discovery** — the no-build source scanner correctly handles block namespaces whose opening brace is on the next line, so public types are no longer silently under-reported; when a declaration cannot be paired with its brace it warns (`API_MODEL_SOURCE_SCANNER_INCOMPLETE`) and points to a build-backed audit,
- **Project-scoped packets and voluntary representative dry runs** — documentation is processed in bounded project packets grouped by DocFX `metadata[].dest`, with ownership of namespaces, targets, overwrite files, and git-dirty paths. A normal run always preserves the user's requested scope and continues packet-by-packet until the global completion contract is clean. Only an explicitly requested `--dry-run --build-api-model --project-manifest <path>` selects one **clean** project per destination group and writes both the initial baseline and a sibling changed-page review template; after evidence-based authoring and page-by-page review, `--resume-project-manifest <path> --review-report <path> --build-api-model --validate-samples --verify-docfx-build` verifies the same packets without mistaking new files for pre-existing work. Missing evidence, purpose/outcome, observable-result, or sibling-pattern review entries block dry-run completion. `--write-overwrite` preserves BOM/line endings and refuses dirty or duplicate-UID writes,
- **Build-backed scope and output-driven quality** — authoring scope must be reflection-precise: a `source-scan` model is `provisional` and raises `BUILD_BACKED_SCOPE_REQUIRED` until `--build-api-model` (or DocFX YAML) confirms it. Deterministic diagnostics evaluate the authored prose, examples, ownership, compilation, and DocFX build; target volume and diagnostic count never alter scope or select dry-run,
- **Symbol-aware ownership and auto-detected generic-arity family skips** — duplicate type names across assemblies block with `SYMBOL_COLLISION_UNRESOLVED` until every colliding type has an exact-UID C# example, and cross-assembly extension containers block with `EXTENSION_OWNER_AMBIGUOUS` until every affected method has receiver-style evidence under its exact declaring-type or method UID. Both diagnostics clear deterministically instead of remaining permanent warnings; unresolved type forwarding (`TYPE_FORWARDING_UNRESOLVED`) stays informational when ownership cannot be attributed safely. A generic-arity type series (UIDs sharing one base name that differ only by arity) is auto-detected from the public API surface and replaces redundant per-type examples with one validated anchor example plus deep namespace guidance, with no manifest written into the repository,
- **Examples that actually compile** — under the opt-in `--validate-samples` path, every `csharp`/`cs` documentation fence is compiled in its own isolated project; all sample projects are batched into one temporary `.slnx` graph build so shared dependencies restore and build once, `--sample-parallelism` bounds MSBuild concurrency, each sample references only the documented project(s) that own its namespace rather than every library project, and failures report the file, fence index, line, exit code, and compiler diagnostics,
- **Asset-aware conditional API validation** — executable tests target the runtime that selects the package/project asset containing the documented API. APIs guarded by `NETSTANDARD2_0` or `NETSTANDARD2_0_OR_GREATER` use `net48` (or another supported .NET Framework target from `net462` onward) when modern package assets omit them, `netstandard*` is never treated as a runnable target, and a newer `netX.0` target is rejected when it resolves to an asset without the API,
- **Honest opt-outs only** — a sample can skip compilation solely with `// dotnet-docfx-digest:skip-compile - <reason>` when that exact marker was already present before the run and matches a deterministic `.docfx/skip-compile-allowlist.json` entry containing `diagnosticCode`, `filePath`, `uid` or `symbol`, `reason`, `approval`, and `lifetime`; a missing reason, unallowlisted marker, or newly introduced marker is fail-level and does not suppress compilation,
- **Public API only** — internal and private members, and namespaces with no public API, are deliberately left undocumented,
- **Preserves manual edits** — additive by default, correcting stale or contradictory statements rather than overwriting hand-written documentation,
- **Cleanup keeps authored docs and is opt-in** — generated-metadata cleanup runs only when `--clean-generated-metadata` is explicitly passed, and even then only after the API model is built so it never deletes YAML the run relied on; `.docfx/**/*.md` overwrite files, namespace pages, includes, and config are documentation outputs, not disposable build artifacts, and cleanup is limited to known metadata files and safe site-output directories that contain no authored documentation or source files,
- **CI-friendly** — deterministic exit codes plus `--json` reports let pipelines fail on actual documentation drift instead of trusting an agent's claim that it checked.

### Why dotnet-test?

Test-project refactoring is deceptively lifecycle-sensitive. A `WebApplicationFactory` wrapper may own temporary directories, defer host startup until the first client, replace services in a specific order, or isolate settings per test. Console and worker tests have a different boundary: they need a resolvable in-process Generic Host, not a child process hidden behind a test helper.

**dotnet-test** begins with machine-readable inspection, then chooses the Codebelt pattern that matches the selected project's role and ownership model. It preserves package ownership and frameworks, migrates xUnit v2 to v3/Microsoft Testing Platform when needed, and makes the chosen focused/shared web or application pattern, entrypoint-owned managed fixture, zero remaining selected `WebApplicationFactory` usages, zero deprecated blocking fixtures, zero replacement composition roots, and restore/build/test explicit gates.

- **Three explicit roles** — ordinary unit, ASP.NET Core functional, and console/worker functional tests route to separate references and assets,
- **Lifecycle-preserving functional migration** — focused factories or narrow `Test`-derived harnesses and shared managed fixtures retain configuration, lazy start, client/service access, synchronous/asynchronous disposal, and isolation,
- **Real entry-point coverage** — focused and shared postconditions reject test-owned `WebApplication`/`TestServer` pipelines that can pass while the production `Program` is broken,
- **Generic Host boundary** — non-web tests use `ApplicationTestFactory` or `ApplicationTest`; missing host seams are reported precisely unless production adaptation is authorized,
- **Bootstrapper host fidelity** — Startup-based hosts and `MinimalConsoleProgram`, `MinimalWorkerProgram`, or `MinimalWebProgram` hosts remain in their established family instead of being rewritten for test convenience,
- **Dynamic compatibility** — stable package versions come from NuGet and must pass isolated compatibility-project restores, including the selected combined package set and target frameworks,
- **Source-grounded bootstrap** — new projects receive at least one behavior test derived from real source instead of a placeholder,
- **Deterministic evidence** — inspection JSON reports roles, frameworks, xUnit generation, package owners, inheritance, migrations, recommendations, and blockers before mutation.

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
- **Offline-safe discovery and explicit scoping** — successful release metadata is cached outside the repo for offline reuse, and when a project choice is needed the form exposes the exact runner-computed target as the recommended option alongside a custom path
- **Official images, pinned to a digest** — auto-generated environments use only `mcr.microsoft.com/dotnet/sdk`, prefer the exact `latest-sdk` tag (preview build metadata stripped), validate the tag against Microsoft's registry, and resolve an immutable digest so a run is reproducible across environment, image, digest, SDK, and architecture
- **Tests run in Docker, the host stays clean** — source is staged into an isolated workspace so container builds never leave Linux `bin`/`obj` in the working tree, a persistent NuGet cache lives outside the repo, and it never silently falls back to running tests locally
- **Honest failure classification** — configuration, unsupported environment, Docker-unavailable, image-resolution, SDK-incompatibility, staging, restore, compilation, test-host, test-failure, result-processing, cleanup, cancellation, and release-metadata failures are distinct, so a container problem is never reported as a failing unit test
- **No plumbing added, ever** — never generates a `Dockerfile`, dev container, compose file, or editor configuration (an existing configured `dockerFile` is honored, never created), never runs privileged containers or mounts the Docker socket, and always cleans up transient Docker resources — reporting exact identifiers if any remain
- **Target-framework aware** — inspects the projects and `global.json`, refuses to pick an SDK that cannot build the requested target framework, and reports incompatibilities instead of editing the repository to force them
- **Deterministic and tested** — the runner ships a comprehensive built-in `--self-test` plus a PowerShell harness covering configuration discovery, release parsing, environment selection, unsupported handling, image resolution, command planning, result parsing, failure classification, cancellation, and cleanup
### Why dotnet-segregated-assets?

`wwwroot` is where every ASP.NET Core developer expects to author static files — editors, hot reload, and the SDK all assume it. But shipping those files inside the deployed web application couples static delivery to business logic, bloats the app artifact, and puts asset caching on the wrong surface. The right shape is architectural: keep authoring in `wwwroot`, but let a separate, hardened static-content host serve the files in production.

**dotnet-segregated-assets** keeps that split honest. The skill is the orchestration layer — it understands intent, reads the repository's real conventions, and makes the edits — while the bundled deterministic runner (`scripts/segregate-assets.cs`) inspects the static-asset topology, classifies it, and *proves* the outcome instead of trusting a declaration that merely looks right.

- **`wwwroot` stays the authoring root** — developers keep editing where they always did, while `/cdnroot` remains the container content root for the asset host
- **App is not CDN** — app-owned assets (authored in `wwwroot`, served from a per-app asset host) are separated from shared CDN assets (reusable across applications, never duplicated into any app's `wwwroot`), and the skill always asks whether a CDN equivalent exists
- **Targeted app-owned publish handling** — `<Content Update="wwwroot/**" CopyToPublishDirectory="Never" />` removes application-owned files while preserving Razor Class Library (`_content`), framework (`_framework`), and generated Static Web Assets
- **Proven, not assumed** — `verify --run-publish` publishes to an isolated temp directory and asserts app-owned `wwwroot` files are absent from the artifact; verification output never touches the repository
- **Safety guardrail over broken migrations** — Blazor, Blazor WebAssembly, Razor Class Library, scoped CSS, component JavaScript modules, and frontend-build scenarios are detected and escalated rather than blindly excluded; stopping to request an explicit generated-static-assets design is a successful outcome, not a failure
- **Scheme-safe local topology** — the `http-segregated-assets` profile points App URLs at an `http://localhost:<port>` origin, never a protocol-relative or `https://localhost` URL that an HTTPS page would break against an HTTP-only origin
- **Hardened local origin** — the local `web-cdn-origin:2.0.0` service mounts `wwwroot` into `/cdnroot` read-only as a non-root user, with a read-only root filesystem, no privileged mode, no Docker socket, and only the required port exposed
- **Docker naming aligned** — the derived production asset image uses the Docker-documented `<something>.Dockerfile` form with PascalCase `Assets.Dockerfile`, selected explicitly when a non-default Dockerfile is built
- **Compose naming aligned** — a dedicated local origin topology uses `compose.assets.yml`, paired with `Assets.Dockerfile`; existing repository orchestration is extended when present
- **Visual Studio orchestration is explicit** — ordinary Development keeps the existing Project profile and serves `wwwroot` directly. For one-click segregated F5, the skill registers `compose.assets.yml` through a `Microsoft.Docker.Sdk` `.dcproj` and root `DockerCompose` profile. Compose directly builds the web app with `LocalDevelopment.Dockerfile` and the origin with `Assets.Dockerfile`; it does not use a redundant project-level segregated profile. When Visual Studio injects the web debugger bootstrap into the build-backed asset service, a narrow `docker-compose.vs.release.yml` restores only the origin entrypoint and never selects Dockerfiles. The web `.csproj` owns `LocalPublishDirectory`; local builds and CI publish the same artifact. Production `Dockerfile` copies it into the shell-less DHI ASP.NET runtime. The `-dev` image is not an SDK, none of the Dockerfiles compile the app, and completion requires a real F5 attachment check rather than only MSBuild and Compose CLI evidence
- **Architectural motivation, stated honestly** — segregation of duties, independent deployment and scaling, explicit cache behavior, and origin/CDN offloading
- **Adapts, never imposes** — it reuses Cuemon `AppTagHelperOptions`/`CdnTagHelperOptions` when already present and the application's own base-URL setting otherwise, and never adds a Cuemon dependency just to migrate
- **Current packages, resolved deterministically** — when a real Cuemon package reference already exists, `plan` discovers NuGet's V3 package endpoint, selects the highest stable version, emits the exact version and source, preserves `Directory.Packages.props` ownership when CPM is active, and fails closed instead of recycling an old literal
- **Uses the existing asset model** — when Cuemon is detected from package/project references, namespace imports, options, `_ViewImports.cshtml`, or actual custom-element markup, it migrates App/CDN ownership to the public `app-*`/`cdn-*` helpers, uses `BaseUrlMode` for Automatic App resolution versus explicitly Configured CDN locations, and removes a redundant `AppAssetOptions`-style abstraction only after its consumers are gone
- **Reports, never rewrites** — the runner exposes Cuemon, competing-abstraction, legacy-syntax, and cache-busting interface/registration evidence for the agent to act on; it never rewrites Razor or C# source and never creates a live-model evaluation workflow
- **Idempotent and deterministic** — re-running reconciles existing segregation instead of duplicating MSBuild items, launch profiles, Compose services, or Dockerfiles, and the runner ships a built-in `--self-test` plus a PowerShell harness
- **Fail-closed verification and planning** — local verification requires both the matching HTTP launch profile and origin Compose service, generated-asset risks override existing-segregation detection, and a no-`wwwroot` project can still produce CDN-only work when a shared equivalent exists
### Why agent-smith?

**agent-smith** applies one coherent engineering standard — *consistency is key* — across a whole task instead of bolting a review onto the end. Invoke it explicitly as `/agent-smith <task>`; it also auto-triggers for engineering work such as architecture, implementation, code review, public API and compatibility analysis, testing, performance, skill authoring, security and DevSecOps, CI/CD, delivery, and governance.

- **Performs the work, not just advice** — it discovers, designs, implements, tests, documents, validates, and reports to the standard, rather than implementing normally and reviewing afterward.
- **Technology-neutral core** — .NET, Git, GitHub, CI/CD, REST, and software-supply-chain guidance load only when the task calls for them, and are never imposed on non-.NET work.
- **Progressive disclosure** — `SKILL.md` stays focused on posture, workflow, and mode routing; deep guidance lives in `references/` and loads only for the selected modes.
- **Faster skill workflows** — skill authoring always maps independent retrieval, execution, validation, and grading for batching or bounded concurrency, while preserving required ordering, rate limits, deterministic results, and failure attribution. Reusable scripts and validators favor C#/.NET with a dynamically resolved supported LTS unless repository or host constraints justify another choice.
- **Agent Skills lifecycle** — skill changes follow the linked Agent Skills guidance for real-task grounding, concise intent-based descriptions, realistic trigger tests, clean-context candidate-versus-baseline evals, objective grading, timing, aggregation, and human review.
- **Evidence over confidence** — never invents APIs, results, or file contents; labels conclusions (Confirmed, Assumption, Requires validation) and refuses to claim validation it did not run.
- **Safe multi-target conformance** — informational workflows keep `--severity info` explicit through discovery and final verification because omission falls back to `warn`; repeated Roslyn findings are de-duplicated by physical file, diagnostic ID, and source span; source is corrected once; mutating formatter passes are forbidden; and the diagnostic-neutral Roslyn artifact tool detects every `Unmerged change from project` signature while repairing only a registered structural pattern. Its first handler retains one complete namespace-conversion document only when the partial `After` branch is an exact prefix; all unrecognized shapes fail closed. The repair-tool check and conflict-artifact scan must both be clean before builds or tests.
- **Respects repository precedence** — local conventions and instructions override generic preferences; a recommended deviation must explain the current convention, why it is inadequate, and how consistency is restored.
- **Scales, never lowers, the standard** — a trivial change gets proportional process with no architecture ceremony; a system design gets full boundary analysis.
- **Concise, honest reporting** — feedback may sacrifice grammar for concision, but findings retain severity, evidence, compatibility/migration impact, validation limits, blockers, and material risk. Completion remains gated on a real checklist.

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
