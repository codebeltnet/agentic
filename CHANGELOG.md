# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.4.5] - 2026-05-18

This is a minor release strengthening `git-repo-digest` with HTTP-validated documentation URL resolution and repository-owned product title discovery from project metadata. The runner now resolves documentation hosts from package URLs and project configuration, validates candidate documentation URLs with HTTP HEAD requests, falls back across multiple sources (root `PackageProjectUrl`, `.docfx/docfx.json`, README `## Documentation` links), and fails fast when no candidate returns `200 OK`. Repository titles for `result/Index.md` are now sourced from a root `Directory.Build.props` `<Product>` value, with fallback to the highest-referenced top-level packable `.csproj` `<Product>` when the root value is absent.

### Added

- HTTP-validated documentation URL resolution in `digest.cs` that accepts `PackageProjectUrl` as the primary candidate, probes package-specific API URLs derived from `.docfx/docfx.json`, falls back to `## Documentation` links in `README.md` and `.nuget/**/README.md`, and requires at least one `200 OK` response before generating digest prose,
- Repository product title discovery in `digest.cs` that reads `<Product>` from root `Directory.Build.props` first, then from the most-referenced top-level packable `.csproj` when the root value is absent, failing fast when no literal product metadata is available,
- `ResolveRepositoryProductTitle`, `ReadRootProduct`, `DiscoverProjectProductCandidates`, `ResolveDocumentationUrlAsync`, and `ResolveRepositoryPackageProjectUrl` methods in `digest.cs` to support robust title and documentation resolution,
- HTTP client with 10-second timeout for documentation URL validation in `digest.cs`,
- Evals 40, 41, and 42 covering repository product title resolution, HTTP-validated documentation URL fallback chains, and convenience package documentation linking behavior.

### Changed

- Enhanced `git-repo-digest` SKILL.md guidance to preserve generated `title` from repository-owned `<Product>` metadata instead of replacing it with invented prose, and to treat generated documentation links as already validated by the runner,
- Updated manifest documentation for `frontmatterHints` to clarify that documentation entries are validated HTTP URLs and that the overview `title` is repository-owned product metadata, not a URL-derived repository id,
- Updated eval 24 to use a direct documentation URL candidate instead of a generic documentation host, ensuring tests exercise the URL validation path.

## [0.4.3] - 2026-05-15

This is a patch release focused on strengthening `git-repo-digest` with external usage evidence collection, a deterministic `--validate-results` validation gate, Codebelt.Extensions.Xunit test shape enforcement, bounded validation repair discipline, enhanced output-root path labeling, and comprehensive eval coverage for all new capabilities. A Status Update Hygiene section is also added to `AGENTS.md` to keep agents focused on user-relevant outcomes rather than sandbox mechanics.

### Added

- External usage evidence collection in `digest.cs` that accepts user-provided public consumer repositories, clones them locally, rejects the digest repo itself, and writes reference-plus-code matches to `external-usage.xml` including direct package references and transitive graph matches where external projects reference the target package,
- `--validate-results --workspace <workspace>` entry point in `digest.cs` for deterministic API-shape checks, quality diagnostics for toy and greeting examples, non-Codebelt-style xUnit snippets, and malformed Basic usage sections, plus NuGet-backed executable xUnit tests for every Basic usage C# block,
- `CodebeltTestConstructorExpression`, `TestOutputExpression`, `FenceLineInsideCodeExpression`, `MarkdownHeadingInsideCodeExpression`, `FileScopedNamespaceExpression`, and `BlockScopedNamespaceExpression` regex constants in `digest.cs` for Codebelt xUnit shape detection,
- `ValidateCodebeltXunitShape`, `ValidateFileScopedNamespace`, `ValidateBasicUsageCodeBlockStructure`, `HasCodebeltTestBaseClass`, and `IsTestOrDerivedFromTest` validation functions in `digest.cs` that catch non-Codebelt-style snippets as blocking diagnostics and walk the source type graph for recursive base class resolution,
- Validation Repair Discipline section in the embedded digest prompt guiding agents to treat targeted `rg` searches as triage, create a concise repair ledger per diagnostic, inspect the exact failing line before theorizing, allow at most one hypothesis pass, and prefer one focused source-backed edit followed by rerun,
- Evals 24–39 covering YAML frontmatter authoring, `IsPackable` regression, fresh vs. reuse workspace behavior, positional URL mapping, API-shape validation with fixture types, indirect producer/consumer examples, executable xUnit validation, Codebelt xUnit shape, malformed fence boundaries, source-backed generic base class acceptance, and bounded validation repair loops,
- Status Update Hygiene section in `AGENTS.md` requiring agents to report user-relevant progress and evidence without narrating sandbox mechanics or retry plumbing.

### Changed

- Refactored `git-repo-digest` output-root path labeling to use `{output-root}/{repo-id}/{yyyyMMdd-HHmmssZ}`, with explicit guidance for recommending `.bot/digests` only when a `.bot` folder exists and no output path was supplied,
- Enhanced evidence-precedence hierarchy in `digest.cs`: source files are authoritative for APIs and method signatures, tests for usage patterns, and project files for dependencies and package relationships,
- Strengthened validation rules for C# Basic usage examples with explicit rejection of helper methods, fake services, missing namespaces, and unverified inheritance or signature claims,
- Expanded Basic usage guidance to distinguish normal packages (single focused example) from convenience and aggregate packages (one focused example per referenced code package with subheadings),
- Clarified positional URL mapping in `git-repo-digest` SKILL.md so slash commands, bare pasted URLs, and prose invocations all follow the same first-URL-is-digest-repo rule,
- Added YAML frontmatter contract requirement for every authored result file and introduced `frontmatterHints` in package manifest entries and the overview prompt,
- Strengthened result-edit discipline in `git-repo-digest` SKILL.md and the embedded prompt: read the file before editing, replace whole sections including fences, verify fence balance after every edit, and rerun `--validate-results` after the final write,
- Strengthened metadata guidance in package digests to reject framework claims, dependency lists, and repository facts from Overview sections,
- Updated README to reflect external usage evidence, URL mapping, frontmatter contract, Codebelt.Extensions.Xunit snippet requirements, deterministic validation gate, and validation repair discipline.

### Fixed

- Fixed `CSharpCodeBlockExpression` regex in `digest.cs` to correctly handle info strings after the `csharp` language tag and enforce strict line endings on the closing fence, preventing false matches on adjacent code blocks,
- Fixed `ClassDeclarationExpression` regex in `digest.cs` to match `sealed`, `abstract`, and `partial` class modifiers that were previously missed, causing false negatives in class declaration detection.

## [0.4.2] - 2026-05-05

This is a minor release focused on simplifying `git-story-teller` architecture, removing external dependencies, consolidating on deterministic local context packing, and renaming the skill to `git-repo-digest` for improved clarity. The skill no longer depends on Node/npm, Repomix, or public packing services; instead, it performs a shallow git clone and uses the bundled C# packer to extract tracked files via `git ls-files`, making the skill fully self-contained and deterministic.

### Changed

- Refactored `git-story-teller` to remove Repomix-first architecture with web API and .NET fallback paths in favor of a single local C# packer,
- Updated `story.cs` to perform deterministic tracked-file discovery using `git ls-files -z` instead of filesystem enumeration, eliminating gitignore parsing and directory scanning variance,
- Removed HTTP client dependency and all Repomix integration code (`PackWithRepomixAsync`, `PackWithRepomixWebApiAsync`, `CanUseRepomixWebApi`, `BuildRepomixWebOptions`) from `story.cs`,
- Updated XML repository-context metadata to reflect the new "git-story-teller-local-packer" source and emit deterministic generation notes instead of fallback disclaimers,
- Updated SKILL.md description and runtime notes to document the shift from Repomix-first with fallbacks to single local packing path,
- Updated eval contract (eval 6) to verify that the runner no longer requires Node/npm, Repomix, or public packing services and recognizes the C# packer as the primary deterministic strategy,
- Added `.vs` to `.gitignore` to exclude Visual Studio settings folder,
- Updated README.md to reflect deterministic local file packing with `git ls-files` instead of external packing dependencies,
- Renamed `git-story-teller` skill to `git-repo-digest` across all references, README, and installation instructions,
- Renamed runner script from `scripts/story.cs` to `scripts/digest.cs` to align with the new skill name,
- Updated all SKILL.md terminology from "story"/"storyteller"/"target stories" to "digest"/"repo-digest"/"package digests",
- Updated eval contracts to reference "digest" generation and package digest workflows instead of story generation,
- Updated README.md table, install examples, and "Why git-repo-digest?" section to reflect the renamed skill and digest-focused narrative,
- Clarified `git-repo-digest` test project discovery to use Codebelt conventions: source projects from `src/`, owned tests from `test/`, matching `.Tests` or `.FunctionalTests` suffixes, avoiding generic `tests/` roots or broader suffix variants,
- Updated `git-repo-digest` README description and "Why" section to document Codebelt-shaped include patterns and Codebelt test ownership strategy,
- Corrected `git-repo-digest` bad output characteristics to reference a separate `.NET project` instead of legacy `ContentSync` terminology,
- Added context index chunk label inference to `git-repo-digest` context index generation, replacing `(none)` placeholders with deterministic inferred labels based on packed file paths,
- Implemented `BuildInferredChunkHeading()` and `ClassifyPackedFilePath()` in `digest.cs` to assign meaningful labels such as Source Code, Test Coverage, NuGet Documentation, Project Metadata, and Documentation based on chunk file composition,
- Added eval 12 to validate deterministic chunk label assignment for headingless packed-content chunks, ensuring agents can navigate large evidence sets with meaningful descriptions.

### Removed

- Repomix integration and all fallback-detection logic from `story.cs`,
- HTTP-based communication with the public Repomix web API,
- Node/npm executable resolution and `npx` invocation for `repomix` command execution,
- Optional Repomix token counts, Secretlint checks, and compression features from the packer output.

## [0.4.1] - 2026-05-04

This is a minor release focused on strengthening `git-story-teller` with complete-read grounding rules, optional subagent delegation, evidence-based language validation, and enhanced deterministic output artifacts, plus clarifying `git-visual-squash-summary` emoji-first output conventions with explicit lowercase-start guidance. The `git-story-teller` skill now enforces that agents read full context and target stories as primary sources, supports delegation of independent target contexts to subagents, and provides tooling to detect and prevent unmeasured frequency or behavior claims without source evidence. The `git-visual-squash-summary` skill clarifies its emoji-first output rule to start descriptions lowercase after the emoji unless a leading technical identifier requires original casing.

### Added

- Complete-read grounding rules in `git-story-teller` requiring agents to fully inspect target contexts and overview sources, with explicit guidance on using chunk indices and range reads to handle truncated output,
- Optional subagent strategy in `git-story-teller` for delegating independent target contexts to isolated subagents, reducing prompt budget contention while maintaining strict grounding requirements,
- Evidence-based language validation patterns and regex detection in `git-story-teller` to distinguish structural facts from unmeasured behavior claims, with explicit guidance on conditional language like "if you only need X, aggregate adds Y" instead of "most common" or "developers often" without evidence,
- Public API summary generation in `story.cs` to help agents orient around consumer-facing types, inheritance chains, and key members before reading raw source,
- Engineering signal map in `story.cs` highlighting source-backed validation guards, lifecycle callbacks, factories, hosting styles, and test evidence for narrative-driven explanations instead of mechanical API lists,
- Conservative test ownership mapping in `story.cs` preferring dedicated test projects with matching names over downstream package tests, only using direct references as fallback, and leaving Test path undiscovered when no unambiguous match exists,
- Chunked context navigation in `story.cs` with `*.context.index.md` and ordered `*.context.chunks/*.md` files alongside full contexts for robust reading even when tools cap single-file output,
- Explicit lowercase-start guidance in `git-visual-squash-summary` for emoji-first output, clarifying that descriptions should start lowercase unless a leading technical identifier requires original casing,
- Eval test coverage for `git-visual-squash-summary` lowercase-start rule including preservation of case-sensitive identifiers and distinction from conventional-commit prefixes.

### Changed

- Refined `git-story-teller` SKILL.md with explicit complete-read contract, mandatory target-story sourcing for overview phase, subagent orchestration patterns, and conservative test mapping rules,
- Enhanced `story.cs` to emit complete context files, public API summaries, engineering signal maps, conservative test ownership logic, context indexes, and ordered chunk files for improved agent navigation and grounding,
- Updated README description and "Why git-story-teller?" section to document full output artifacts, public-API-first orientation, engineering signals, conservative test mapping, chunked navigation, and complete-read grounding,
- Updated README description and "Why git-visual-squash-summary?" section to clarify lowercase-start rule and technical identifier preservation in emoji-first output,
- Expanded `git-visual-squash-summary` SKILL.md formatting rules and good/bad characteristics sections with explicit lowercase-start guidance and case-sensitive identifier handling,
- Expanded AGENTS.md with four-way skill sync guidance including Gemini Antigravity install location and folder-name requirements,
- Refined eval contracts for complete-read patterns, subagent coordination, evidence-based prose, target-story-sourced overview synthesis, conservative test ownership mapping, and emoji-first lowercase output conventions.

### Fixed

- Clarified validator and documentation alignment to enforce complete-read requirements, evidence-based language rules, and target-story sourcing for overview workflows,
- Refined conservative test project matching to use exact suffix matching instead of stripping, preventing false positives when project names contain partial test-suffix overlap,
- Updated eval 11 expectations to clarify handling of dedicated test projects with explicit "Tests" suffix patterns,
- Standardized `git-visual-squash-summary` output guidance across SKILL.md, references/commit-language.md, and eval contracts to enforce consistent lowercase-start and technical-identifier preservation rules.

## [0.4.0] - 2026-05-03

This is a minor release focused on deterministic repository story generation and foundational agent guidelines. It introduces a new `git-story-teller` skill with a bundled .NET context extractor, enhanced bot workspace management, and Karpathy programming principles for LLM agents.

### Added

- `git-story-teller` skill that reads a repository URL and generates a deterministic story overview and per-package target stories from grounded evidence,
- Bundled C# context packer (`scripts/story.cs`) that clones repositories, discovers package targets, extracts grounded evidence via Repomix, and stages deterministic fixtures for story generation,
- Karpathy rules in `AGENTS.md` for LLM-driven coding: think before implementing, favor simplicity, make surgical changes, and execute goal-driven with clear verification criteria,
- `.bot/` workspace pattern to `.gitignore` for local agentic workspaces and ephemeral state.

### Changed

- Updated README to document `git-story-teller` installation, usage, and bundled C# runner approach,
- Implemented Repomix web API and .NET packer fallbacks in `git-story-teller` for robust context extraction when network or CLI tools are unavailable.

## [0.3.4] - 2026-04-24

This is a patch release that hardens the .NET scaffold guidance around hidden asset recovery and makes `git-keep-a-changelog` safer in yolo/auto mode. Incomplete `npx skills add` installs now pivot immediately to an upstream restore path driven by the shared asset manifest, while the changelog skill treats yolo/auto as an explicit full-autonomy mode instead of asking for scope confirmation.

### Changed

- Clarified `dotnet-new-app-slnx` and `dotnet-new-lib-slnx` so missing required or dot-prefixed files in an installed skill copy immediately trigger the manifest-driven restore path from upstream before generation continues,
- Aligned the app and library variant references, `AGENTS.md`, and `README.md` with the same hidden-asset recovery rule so incomplete `npx skills add` copies get repaired consistently across the repo,
- Expanded `git-keep-a-changelog` with an explicit yolo/auto mode that skips the pending-change confirmation gate and folds staged, unstaged, and untracked worktree changes into the draft automatically.

### Fixed

- Tightened `scripts/validate-skill-templates.ps1` so it now asserts the shared hidden-asset recovery wording in both scaffold references, keeping the validator synchronized with the documented install-fallback behavior,
- Added validator coverage for the new manifest-driven restore guidance and the yolo/auto changelog bypass contract.

## [0.3.3] - 2026-03-25

This is a patch release focused on strengthening all git workflow skills with concrete eval contracts, enhanced validator enforcement, and comprehensive documentation alignment across the skill suite. Evaluations now cover semantic intent classification, emoji/prefix consistency, bot identity handling, and cross-runner compatibility. The pending-worktree confirmation checkpoint in `git-keep-a-changelog` is now explicitly mandatory for concrete releases, with documentation and validator enforcement to prevent bypass. Compare-link footer maintenance is now explicitly required for both changelog create and update paths, with validator assertions and eval coverage.

### Changed

- Tightened `git-visual-commits` classification and grouping guidance so same-round edits do not collapse into one umbrella commit and release-adjacent work is split by purpose and audience,
- Clarified `git-visual-commits` prefix behavior to default to emoji-first subjects with no prefix, and only allow emoji plus conventional-commit prefix combos when the user explicitly requests that form,
- Hardened `git-visual-commits` bot-commit execution guidance to prefer direct git paths, fail fast when wrapper tools cannot honor aliases, and recover conservatively after wrong-author attempts,
- Refined `git-visual-commits` and `git-visual-squash-summary` skill descriptions and critical rules for consistency and clarity around semantic intent, identity modes, and reference documentation,
- Reorganized `git-visual-commits`, `git-visual-squash-summary`, and `git-keep-a-changelog` skills with explicit workflow steps, clarified parameter forms, and synchronized emoji/prefix reference contract,
- Enhanced `skill-creator-agnostic` for eval directory structure, Codex CLI Windows benchmarking, and runner-agnostic parity validation,
- Clarified `git-keep-a-changelog` pending-worktree confirmation gate as mandatory for concrete releases with new "Mandatory Checkpoints" and "User Intent vs. Mandatory Gates" sections that distinguish between optional scope refinements and required safety checkpoints,
- Strengthened `git-keep-a-changelog` compare-link footer rules to explicitly document insertion, verification, and repair on every edit path.

### Fixed

- Extended `validate-skill-templates.ps1` to enforce release-adjacent grouping rules, direct git execution guidance, fail-fast tool-path checks, non-destructive recovery rules, refined prefix behavior, and commit-language consistency across all git skills,
- Updated the README skill summary so the published repo guidance reflects stronger semantic grouping, direct bot-path execution, conservative commit-repair workflow, clarified prefix defaults, and updated skill entry documentation,
- Added concrete eval contracts with test cases for all git workflow skills: `git-visual-commits` (six tests), `git-visual-squash-summary` (five tests), and `git-keep-a-changelog` (six tests, including pending-worktree gate bypass validation), covering plan review, identity handling, emoji/prefix preservation, SemVer classification, prose wrapping, and consistency validation,
- Added per-skill eval coverage for `markdown-illustrator` and strengthened `skill-creator-agnostic` with benchmark contract reference and Windows PowerShell benchmarking guidance,
- Hardened skill-template validators to enforce the mandatory pending-worktree gate documentation in `git-keep-a-changelog`, requiring SKILL.md sections on mandatory checkpoints, FORMS.md gate emphasis, and evals.json test expectations for gate enforcement,
- Extended validator assertions for `git-keep-a-changelog` to enforce compare-link footer documentation and require eval test case for missing-footer insertion behavior.

## [0.3.2] - 2026-03-23

This is a minor release introducing the markdown-illustrator skill for visualization-first document analysis, with expanded repository branding, comprehensive skill documentation, and foundational eval fixture file infrastructure across the skill suite.

### Added

- `markdown-illustrator` skill that reads markdown files and generates a document-wide Visual Brief plus one compiled diffusion-ready prompt, with zero follow-up questions and inferred visual strategy defaults (hero-focused cinematic editorial by default, steerable toward whiteboard, blackboard, isometric, or blueprint styles),
- Hero image assets for repository branding at `/assets/hero.jpg` and for individual skills (`trunk-first-repo/assets/hero.jpg`),
- Optional `files` array support in eval infrastructure (`evals/evals.json`) to stage skill-relative fixture paths into temporary eval workspaces for both `with_skill` and `without_skill` runs,
- Eval fixtures for `markdown-illustrator` with real-world examples (microservices architecture, product launch, transformers explanation),
- Benchmark contract reference documentation in `skill-creator-agnostic` with fixture guidance patterns.

### Changed

- Enhanced README with markdown-illustrator installation snippet and comprehensive "Why markdown-illustrator?" section explaining visual-brief anchoring, inferred defaults, good trigger examples, and reference visual directions for users,
- Extended AGENTS.md with detailed eval fixture file documentation, explaining the optional `files` property and fixture staging workflow for skill evaluation,
- Updated CONTRIBUTING.md with eval fixture guidance and temp-workspace isolation setup instructions,
- Improved validation script (`validate-skill-templates.ps1`) to enforce fixture file path checks and consistency across skills,
- Applied fixture guidance pattern to `skill-creator-agnostic` with benchmark contract examples and reference documentation.

## [0.3.1] - 2026-03-19

This is a patch release introducing three new NuGet-focused skills and runner-agnostic benchmark tooling, with enhanced release automation, comprehensive documentation standardization, and skill refinements.

### Added

- `git-nuget-release-notes` skill that creates or updates per-package `.nuget/{ProjectName}/PackageReleaseNotes.txt` files from git history for .NET repositories, with per-skill evals and extracted package release-notes format reference,
- `git-nuget-readme` skill that writes package-facing NuGet READMEs from actual project metadata, git history, and source-backed capability cues, with per-skill evals and README blueprint reference,
- `skill-creator-agnostic` skill that adds runner-agnostic guardrails on top of Anthropic's skill-creator for creating, modifying, and benchmarking skills across Codex, GitHub Copilot, Opus, and similar agents, with enforced temp-workspace isolation and valid benchmark layout.

### Changed

- Enhanced `git-keep-a-changelog` with explicit release-intent trigger words ("finalize", "ready to release", "rtr", "release") that automatically extract and use versions from branch names, streamlining release finalization without manual version input,
- Tightened `git-visual-commits` commit body repair checks to treat short prose bodies wrapped mid-sentence as verification failures that must be repaired before success is reported, with targeted eval coverage,
- Clarified that unscoped `git bot commit` requests apply to the entire worktree unless the user explicitly narrows scope, with eval coverage ensuring yolo mode still groups the full diff,
- Standardized documentation across AGENTS.md, CONTRIBUTING.md, and README.md to explicitly instruct users to resolve the installed Anthropic skill-creator path (typically under `~/.agents/skills/skill-creator/` or `~/.claude/skills/skill-creator/`) before running benchmark and review tools,
- Updated benchmark layout specification from `eval-N` pattern to `iteration-N/eval-name/{config}/run-N/` for clarity and consistency, with PowerShell resolver logic that probes both skill-creator install locations,
- Normalized line wrapping and formatting across all SKILL.md, FORMS.md, and references/ files for improved readability and consistent presentation, removing extra blank lines and compacting multi-line YAML descriptions,
- Normalized line wrapping in shared asset templates including .github/copilot-instructions.md, asset CHANGELOG.md bootstrap files, and package documentation templates,
- Refreshed README catalog to reflect the current skill set and commit-behavior guidance, with updated benchmark and eval workflow documentation.

## [0.3.0] - 2026-03-17

This is a minor release that introduces two complementary git workflow skills, extracts a shared commit-language reference, and backs the whole skill suite with pull-request validation plus stricter skill metadata checks.

### Added

- `git-visual-squash-summary` skill that turns a noisy commit stack into grouped summary lines — preserving distinct high-signal efforts, merging overlapping commits, and dropping low-signal noise — without mutating git state,
- `git-keep-a-changelog` skill that creates or updates `CHANGELOG.md` directly from the current branch, reads full commit message bodies for context, infers release headings from branch version hints, and writes a required SemVer-aware release highlight with natural prose,
- GitHub Actions workflow that runs `validate-skill-templates.ps1` on pull requests as the merge safety net,
- Per-skill `evals/evals.json` coverage for `git-visual-squash-summary` and `git-keep-a-changelog`.

### Changed

- Extracted the shared commit-language guidance into `references/commit-language.md`, used by both `git-visual-commits` and `git-visual-squash-summary`, so prefix, emoji, and wording rules have one maintained source,
- Tightened git skill metadata so frontmatter descriptions stay within the repo limit and `git-visual-commits` points directly at `references/commit-language.md` instead of stale in-file “below” references,
- Tightened `git-visual-commits` grouping rules to classify new repo capabilities, existing-skill refactors, and shared-reference sync as separate intents, with eval coverage for mixed-diff cases,
- Hardened `validate-skill-templates.ps1` with UTF-8 and BOM handling, grouped squash summary rule checks, changelog formatting enforcement, repo-wide frontmatter description-length enforcement, and consistent behavior across Windows PowerShell and CI,
- Updated `CONTRIBUTING.md` to explain the local-first validation workflow: run the script locally for fast feedback while GitHub Actions reruns the same checks as the safety net.

## [0.2.0] - 2026-03-16

### Added

- Added per-skill `evals/evals.json` coverage across the repo, including deterministic validation for scaffold behavior and skill contracts.
- Expanded `dotnet-new-app-slnx` with explicit web-family variants for Empty Web, Web API, MVC, and Web App / Razor scaffolds.
- Introduced a NuGet-backed app package resolver so generated `Directory.Packages.props` files use current compatible versions.

### Changed

- Hardened the .NET app and library scaffold skills around required outputs, current-folder generation, supported TFM choices, and clearer usage guidance.
- Tightened repo documentation and local skill-sync guidance so README, policy, and install expectations stay aligned.
- Strengthened `git-visual-commits` with identity lock, `yolo` guardrails, post-commit verification, and clearer umbrella-commit rejection rules.

### Fixed

- Improved scaffold fidelity so generated assets stay complete, shared files remain synchronized, and emitted app templates are validation- and compile-ready.

## [0.1.0] - 2026-03-15

### Added

- Launched the initial skill suite with `git-visual-commits`, `trunk-first-repo`, `dotnet-strong-name-signing`, `dotnet-new-lib-slnx`, and `dotnet-new-app-slnx`.
- Added repo governance and contributor guidance, including the initial `README`, `CONTRIBUTING`, `AGENTS.md`, license, and ignore rules.
- Added shared scaffold assets for CI, packaging, documentation, benchmarking, and TFM-aware test environments for the .NET skills.

### Changed

- Split the original combined .NET scaffolder into dedicated app and library skills with clearer scope boundaries and lower-friction prompts.
- Refined scaffold defaults to derive more metadata from repo state, official .NET support data, and current package feeds instead of stale hardcoded values.
- Evolved `git-visual-commits` from a basic commit helper into an opinionated workflow with reviewable commit plans, collaborative attribution modes, richer gitmoji coverage, and body-by-default support.

### Fixed

- Improved scaffold fidelity with hidden `.bot` asset preservation, explicit UTF-8 and BOM handling, and checks aimed at preventing mojibake or incomplete generated output.

[Unreleased]: https://github.com/codebeltnet/agentic/compare/v0.4.5...HEAD
[0.4.5]: https://github.com/codebeltnet/agentic/compare/v0.4.3...v0.4.5
[0.4.3]: https://github.com/codebeltnet/agentic/compare/v0.4.2...v0.4.3
[0.4.2]: https://github.com/codebeltnet/agentic/compare/v0.4.1...v0.4.2
[0.4.1]: https://github.com/codebeltnet/agentic/compare/v0.4.0...v0.4.1
[0.4.0]: https://github.com/codebeltnet/agentic/compare/v0.3.4...v0.4.0
[0.3.4]: https://github.com/codebeltnet/agentic/compare/v0.3.3...v0.3.4
[0.3.3]: https://github.com/codebeltnet/agentic/compare/v0.3.2...v0.3.3
[0.3.2]: https://github.com/codebeltnet/agentic/compare/v0.3.1...v0.3.2
[0.3.1]: https://github.com/codebeltnet/agentic/compare/v0.3.0...v0.3.1
[0.3.0]: https://github.com/codebeltnet/agentic/compare/v0.2.0...v0.3.0
[0.2.0]: https://github.com/codebeltnet/agentic/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/codebeltnet/agentic/compare/7eaf364...v0.1.0
