# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.3.0] - 2026-03-17

This is a minor release that introduces two complementary git workflow skills, extracts a shared commit-language reference, and backs the whole skill suite with CI-enforced template validation.

### Added

- `git-visual-squash-summary` skill that turns a noisy commit stack into grouped summary lines — preserving distinct high-signal efforts, merging overlapping commits, and dropping low-signal noise — without mutating git state,
- `git-keep-a-changelog` skill that creates or updates `CHANGELOG.md` directly from the current branch, reads full commit message bodies for context, infers release headings from branch version hints, and writes a required SemVer-aware release highlight with natural prose,
- GitHub Actions workflow that runs `validate-skill-templates.ps1` on pull requests as the merge safety net,
- Per-skill `evals/evals.json` coverage for `git-visual-squash-summary` and `git-keep-a-changelog`.

### Changed

- Extracted the shared commit-language guidance into `references/commit-language.md`, used by both `git-visual-commits` and `git-visual-squash-summary`, so prefix, emoji, and wording rules have one maintained source,
- Tightened `git-visual-commits` grouping rules to classify new repo capabilities, existing-skill refactors, and shared-reference sync as separate intents, with eval coverage for mixed-diff cases,
- Hardened `validate-skill-templates.ps1` with UTF-8 and BOM handling, grouped squash summary rule checks, changelog formatting enforcement, and consistent behavior across Windows PowerShell and CI,
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

[Unreleased]: https://github.com/codebeltnet/agentic/compare/v0.3.0...HEAD
[0.3.0]: https://github.com/codebeltnet/agentic/compare/v0.2.0...v0.3.0
[0.2.0]: https://github.com/codebeltnet/agentic/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/codebeltnet/agentic/compare/7eaf364...v0.1.0
