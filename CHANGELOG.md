# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.3.3] - 2026-03-24

This is a patch release focused on strengthening all git workflow skills with concrete eval contracts, enhanced validator enforcement, and comprehensive documentation alignment across the skill suite. Evaluations now cover semantic intent classification, emoji/prefix consistency, bot identity handling, and cross-runner compatibility. The pending-worktree confirmation checkpoint in `git-keep-a-changelog` is now explicitly mandatory for concrete releases, with documentation and validator enforcement to prevent bypass.

### Changed

- Tightened `git-visual-commits` classification and grouping guidance so same-round edits do not collapse into one umbrella commit and release-adjacent work is split by purpose and audience,
- Clarified `git-visual-commits` prefix behavior to default to emoji-first subjects with no prefix, and only allow emoji plus conventional-commit prefix combos when the user explicitly requests that form,
- Hardened `git-visual-commits` bot-commit execution guidance to prefer direct git paths, fail fast when wrapper tools cannot honor aliases, and recover conservatively after wrong-author attempts,
- Refined `git-visual-commits` and `git-visual-squash-summary` skill descriptions and critical rules for consistency and clarity around semantic intent, identity modes, and reference documentation,
- Reorganized `git-visual-commits`, `git-visual-squash-summary`, and `git-keep-a-changelog` skills with explicit workflow steps, clarified parameter forms, and synchronized emoji/prefix reference contract,
- Enhanced `skill-creator-agnostic` for eval directory structure, Codex CLI Windows benchmarking, and runner-agnostic parity validation,
- Clarified `git-keep-a-changelog` pending-worktree confirmation gate as mandatory for concrete releases with new "Mandatory Checkpoints" and "User Intent vs. Mandatory Gates" sections that distinguish between optional scope refinements and required safety checkpoints.

### Fixed

- Extended `validate-skill-templates.ps1` to enforce release-adjacent grouping rules, direct git execution guidance, fail-fast tool-path checks, non-destructive recovery rules, refined prefix behavior, and commit-language consistency across all git skills,
- Updated the README skill summary so the published repo guidance reflects stronger semantic grouping, direct bot-path execution, conservative commit-repair workflow, clarified prefix defaults, and updated skill entry documentation,
- Added concrete eval contracts with test cases for all git workflow skills: `git-visual-commits` (six tests), `git-visual-squash-summary` (five tests), and `git-keep-a-changelog` (six tests, including pending-worktree gate bypass validation), covering plan review, identity handling, emoji/prefix preservation, SemVer classification, prose wrapping, and consistency validation,
- Added per-skill eval coverage for `markdown-illustrator` and strengthened `skill-creator-agnostic` with benchmark contract reference and Windows PowerShell benchmarking guidance,
- Hardened skill-template validators to enforce the mandatory pending-worktree gate documentation in `git-keep-a-changelog`, requiring SKILL.md sections on mandatory checkpoints, FORMS.md gate emphasis, and evals.json test expectations for gate enforcement.

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

[Unreleased]: https://github.com/codebeltnet/agentic/compare/v0.3.3...HEAD
[0.3.3]: https://github.com/codebeltnet/agentic/compare/v0.3.2...v0.3.3
[0.3.2]: https://github.com/codebeltnet/agentic/compare/v0.3.1...v0.3.2
[0.3.1]: https://github.com/codebeltnet/agentic/compare/v0.3.0...v0.3.1
[0.3.0]: https://github.com/codebeltnet/agentic/compare/v0.2.0...v0.3.0
[0.2.0]: https://github.com/codebeltnet/agentic/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/codebeltnet/agentic/compare/7eaf364...v0.1.0
