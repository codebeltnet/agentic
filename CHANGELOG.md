# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.9.0] - 2026-08-10

This is a minor release introducing the `dotnet-test` skill for lifecycle-aware xUnit test migration and the `dotnet-remote-testing` skill for deterministic remote testing in Docker containers, alongside foundational skill-benchmarking infrastructure with caching and workspace management. The release includes comprehensive test-role classification and managed-fixture patterns for `dotnet-test`, offline-safe release discovery for remote testing, deterministic caching and structured tracing in the `dotnet-test` resolver, and cross-platform execution support. Enhanced release-entity classification in `git-keep-a-changelog` and `git-nuget-release-notes` now distinguishes new-capability introductions from pre-existing refinements, preventing mis-categorized changelog entries when unreleased features are refined before first release. Repository validation tooling is strengthened with skill-content validation and resolver script enforcement.

### Added

- `dotnet-test` skill providing lifecycle-aware xUnit test migration and modernization guidance with role-specific patterns for ordinary unit tests, ASP.NET Core WebApplicationFactory elimination, and console/worker service functional-test bootstrapping,
- Comprehensive test-role classification in `dotnet-test` covering focused vs. shared fixtures, managed-fixture entrypoint composition, Generic Host seam preservation, and WebApplicationFactory elimination patterns without pipeline reconstruction,
- `dotnet-test` SKILL.md with step-by-step test-project inspection, xUnit v3 modernization paths, managed-fixture bootstrap hosts, role-specific reference-document guidance, structured parameter collection via FORMS.md, and test-package compatibility validation,
- Role-specific test assets in `dotnet-test/assets/` covering unit-test behavior patterns, focused and shared web-application fixtures, application-focused fixtures, and bootstrapper hosts for console and worker services in both minimal and traditional Program/Startup configurations,
- Comprehensive `dotnet-test` eval scenarios with paired test cases covering fresh xUnit unit-test projects, ASP.NET Core focused functional tests with managed fixtures, shared web-application functional tests, xUnit v2-to-v3 modernization, and worker service functional tests with GenericHost seams,
- `dotnet-test` reference documentation covering unit-test fundamentals, web-functional-test patterns, application-functional-test fixtures, bootstrapper-host programs for console and worker services, xUnit v3 modernization guidance, and migration-invariant preservation rules,
- `dotnet-test` package-compatibility resolver script `resolve-test-package-versions.ps1` validating combined package restore across selected NuGet candidates for multiple target frameworks, preventing incompatible package combinations in managed-fixture test projects,
- Test coverage for `dotnet-test` package-compatibility resolver via `test-resolve-test-package-versions.ps1` validating resolver behavior, compatibility detection, and framework coverage,
- `resolve-release-entity.ps1` script for `git-keep-a-changelog` enabling deterministic classification of base-to-HEAD change outcomes (`Added`, `Removed`, `Changed`, or `Unchanged`) at release boundaries, supporting per-entity classification separate from intermediate commit verbs,
- Test coverage for `git-keep-a-changelog` release-entity classification via `test-resolve-release-entity.ps1` validating classification outcomes and boundary handling,
- `dotnet-remote-testing` skill enabling deterministic remote testing of .NET projects in Docker containers using Microsoft's official SDK images, with support for `testenvironments.json` configuration or zero-config discovery from official release metadata,
- Docker-based remote test orchestration infrastructure including container setup, NuGet cache management, test execution, and result parsing transparently behind a reusable runner script,
- Offline-safe release metadata caching for remote testing: successful release metadata is cached outside the repository for offline reuse, and the form exposes the exact runner-computed target as a recommended option,
- Cross-platform dotnet execution support in the benchmark runner including a POSIX shell script shim alongside Windows batch files for non-Windows platforms,
- `run-skill-benchmark.ps1` as the preferred local entry point for skill benchmarking, managing a single persistent temp workspace, sharing benchmark-scoped caches, staging fixtures once, enforcing bounded parallelism and per-run timeouts, and prewarming expensive resolver work,
- Comprehensive `dotnet-remote-testing` skill documentation with step-by-step workflow guidance covering container selection, test environment configuration, offline discovery, and result parsing,
- Structured test-environment configuration via `testenvironments.json` support with configuration templates and validation for multiple target frameworks,
- `dotnet-remote-testing` eval scenarios covering zero-config discovery, configured environments, offline cache behavior, and unsupported-environment handling,
- Reference documentation for `dotnet-remote-testing` including Docker execution details, release discovery mechanics, and `testenvironments.json` schema and examples.

### Changed

- Enhanced `git-keep-a-changelog` SKILL.md with improved release-entity classification guidance using the new `resolve-release-entity.ps1` helper for deterministic base-state analysis, eliminating mis-categorization of pre-existing capability refinements as `Changed` or `Fixed` when they should remain under `Added` for new capabilities,
- Updated `git-keep-a-changelog` Step 4e guidance to run the bundled release-entity classifier for path-backed entities, treating its emitted classification as authoritative and avoiding commit-verb-based category inference,
- Enhanced `git-keep-a-changelog` deterministic reduction model with improved reconciliation rules and examples showing how surviving-outcome classification prevents duplicate changelog entries when unreleased drafts are refined with multiple commits before first release,
- Improved `git-keep-a-changelog` bad-output-characteristics section with explicit warnings about placing pre-release refinements under `Changed` or `Fixed` instead of preserving them under the initial `Added` outcome,
- Enhanced `git-nuget-release-notes` SKILL.md with improved release-entity classification guidance aligned with `git-keep-a-changelog` enhancements, including per-package classification and cumulative-package-set reduction patterns,
- Updated repository validation to enforce `resolve-release-entity.ps1` presence in git-keep-a-changelog and validate adoption of entity-classification patterns in release-notes skills,
- README.md skill inventory and descriptions updated to reflect `dotnet-test` and `dotnet-remote-testing` capabilities, enhanced release-entity classification in `git-keep-a-changelog` and `git-nuget-release-notes`, and improved validation tooling,
- Enhanced `scripts/validate-skill-templates.ps1` with deterministic skill-content validation, release-entity classifier enforcement, git-keep-a-changelog trigger validation, and resolver-script presence checks,
- Enhanced README.md documentation of the benchmark runner as the preferred local workflow, explaining structured result parsing and failure classification.

## [0.8.2] - 2026-08-07

This is a patch release focused on skill refinement and documentation hardening. The release significantly expands `git-keep-a-changelog` with step-by-step workflow improvements, strengthens `git-nuget-release-notes` and `git-visual-squash-summary` skills, deprecates `skill-creator-agnostic` in favor of the upstream Anthropic `skill-creator`, enhances skill validation tooling, and improves repository guidance documentation in `AGENTS.md` and `README.md`.

### Added

- Comprehensive step-by-step workflow sections in `git-keep-a-changelog` covering release-scope resolution, changelog-target determination, pending-worktree-change confirmation gates, cumulative-result inspection, release classification, content curation, and careful changelog editing,
- Deterministic reduction model in `git-keep-a-changelog` for semantic-delta analysis using cumulative manifests and net diffs before commit-body interpretation, with detailed reconciliation rules to avoid duplicate or conflicting changelog entries,
- Release highlight contract in `git-keep-a-changelog` requiring every concrete release entry to open with a human-written paragraph that explicitly classifies the release as `major`, `minor`, or `patch`, with optional warning callouts for migration risk,
- Mandatory checkpoint enforcement in `git-keep-a-changelog` including release-isolation verification, base-history-bleed detection, release-highlight presence, and bullet-punctuation consistency before completing edits,
- Enhanced `git-keep-a-changelog` good and bad output characteristics sections documenting silent-boundary inclusion as a critical failure mode, proper use of `history_range` and `diff_range`, comprehensive commit-body reading, and complete changelog maintenance,
- Expanded `git-keep-a-changelog` user-intent vs. gates guidance clarifying that yolo/auto mode bypasses the Step 3 confirmation gate but never widens committed history or changes Git range inclusivity,
- New eval coverage for `git-keep-a-changelog` including deterministic reduction model validation, reconciliation rule verification, manifest-diff prioritization, pending-change handling, and step-by-step workflow validation,
- Enhanced `git-nuget-release-notes` skill with improved guidance on per-package release notes generation from git history and manifest deltas,
- Expanded `git-nuget-release-notes` eval coverage documenting package discovery, release version resolution, cumulative-history preservation, and per-assembly changelog generation patterns,
- Enhanced `git-visual-squash-summary` skill documentation with improved commit-language reference compliance and semantic-grouping guidance,
- Expanded `git-visual-squash-summary` eval coverage documenting author-neutral scope, base-branch resolution, commit-grouping validation, and curated-summary quality standards,
- Enhanced `scripts/validate-skill-templates.ps1` with improved skill content validation, SKILL.md structure verification, and asset consistency checking,
- Deprecation notice for `skill-creator-agnostic` with clear redirect to Anthropic's `skill-creator` and repository-specific `AGENTS.md` guidance.

### Changed

- Refactored `git-keep-a-changelog` SKILL.md with new mandatory workflow sections (Steps 1–8) replacing implicit procedures with explicit, checkpointed guidance for all changelog-generation paths,
- Enhanced `git-keep-a-changelog` yolo/auto mode documentation to clarify that full autonomy applies only to pending-worktree decisions, never to committed-history scope or range inclusivity,
- Restructured `git-keep-a-changelog` non-negotiable rules to emphasize deterministic scope resolution, git-history authority, author-agnostic scope by default, and mandatory release highlights,
- Updated `git-keep-a-changelog` Step 3 confirmation-gate guidance to clarify plain-text fallback paths when native structured input is unavailable, with mandatory `Yes / No / Custom` meaning preserved across both paths,
- Expanded `git-keep-a-changelog` Step 3b release-isolation verification to require explicit base-history-bleed detection and boundary-commit validation before proceeding,
- Reorganized `git-keep-a-changelog` Step 4 into explicit sub-steps (4a–4f) with clear sequencing: base-commit inspection, manifest detection, cumulative manifest-diff inspection, approved pending-change inspection, surviving-outcome determination, and chronological commit-body reading,
- Enhanced `git-keep-a-changelog` reconciliation rules with detailed examples showing how churn elimination and surviving-outcome classification prevent duplicate changelog entries,
- Updated README.md descriptions for `git-keep-a-changelog`, `git-nuget-release-notes`, and `git-visual-squash-summary` to reflect enhanced skill guidance and workflow improvements,
- Simplified `skill-creator-agnostic` SKILL.md to a deprecation shim with only redirect guidance, removing all deprecated workflow documentation,
- Updated AGENTS.md with explicit deprecation notice for `skill-creator-agnostic` and clear directive to use Anthropic's `skill-creator` with repository `AGENTS.md` rules,
- Enhanced AGENTS.md third-party-skills guidance to clarify that companion overlays around third-party skills must not be created; instead, document repo-specific behavior in `AGENTS.md` itself.

### Deprecated

- `skill-creator-agnostic` is now explicitly deprecated, no longer maintained, and retained only for backward compatibility until **1.0.0**; new skill creation, modification, and benchmarking should use Anthropic's `skill-creator` directly together with the repository rules in `AGENTS.md`.

## [0.8.1] - 2026-08-01

This is a patch release focused on agent-smith refinement, skill-validator hardening, and improved git-visual-commits quality gating. The release refactors agent-smith guidance for conciseness and parallelism, introduces skill-template validators to the repository, hardens the git-visual-commits single-category quality gate, and clarifies auto-approval triggering behavior with new eval coverage.

### Added

- Skill template validators in `scripts/validate-skill-templates.ps1` that check skill directory structure, SKILL.md frontmatter, description completeness, FORMS.md usage patterns, eval coverage, and cross-reference consistency,
- Deterministic skill content validation including presence of required `name` and `description` fields, YAML frontmatter correctness, file-extension consistency, and description character-count verification,
- New `skills/agent-smith/references/skill-authoring.md` reference document providing comprehensive skill-creation guidance covering real-task grounding, repository inspection, parallelism mapping, sequential-constraint identification, script-language selection with .NET-first defaults, evaluation workflow, and required authoring-feedback elements,
- Eval cases documenting skill validation behavior, template consistency checking, and edge-case handling across repo-managed skills,
- Enhanced eval coverage for `agent-smith` and `git-visual-commits` including new single-category quality-gate scenarios, auto-approval edge cases, and subject-validation lock verification.

### Changed

- Refactored `agent-smith` SKILL.md with improved guidance on conciseness, parallelism identification, task-graph mapping, and sequential-vs-concurrent constraint analysis,
- Enhanced `agent-smith` section organization for clearer progressive disclosure of domain-specific guidance across engineering disciplines,
- Refined `git-visual-commits` SKILL.md with improved single-category quality gate documentation, clarifying when multi-file changes collapse to one semantic category and when the gate requires full-context review,
- Enhanced `git-visual-commits` auto-approval triggering documentation to explicitly document yolo/auto mode and when auto-approval bypasses confirmation steps,
- Updated README.md with improved descriptions for `agent-smith` and `git-visual-commits` highlighting new skill-validation capabilities and quality-gate refinements.

## [0.8.0] - 2026-07-18

This is a minor release introducing the `agent-smith` skill for rigorous software-craftsmanship standards across design, architecture, implementation, testing, performance, security, DevSecOps, and CI/CD, alongside the `dotnet-benchmark` skill for evidence-driven performance testing. The release resolves a critical git-keep-a-changelog bug that could silently include already-released commits when determining scope boundaries, replaces implicit caret notation with deterministic branch-derived scope validation, and introduces deterministic commit-subject validation infrastructure to `git-visual-commits` with a bundled PowerShell validator and full-skill-read gating. PowerShell execution is standardized to pwsh 7+, and skill validation tooling is strengthened across the repository.

### Added

- `agent-smith` skill with comprehensive workflow guidance for rigorous software-craftsmanship standards across engineering tasks, including design, architecture, implementation, refactoring, code review, public API analysis, testing, benchmarking, performance, security, DevSecOps, CI/CD, delivery, and repository governance,
- Detailed reference documentation for agent-smith covering core principles, decision frameworks, architecture guidelines, implementation patterns, testing strategies, performance considerations, security and DevSecOps guidance, CI/CD workflows, delivery discipline, repository governance, engineering assessment templates, and agent handoff protocols,
- Eval coverage for `agent-smith` including discipline verification, review scenarios, and governance application across multiple engineering contexts,
- README updates with `agent-smith` installation snippet, capability showcase, and "Why agent-smith?" section explaining technology-neutral core, progressive disclosure, evidence-driven reporting, local-convention respect, and honest completion gates,
- `dotnet-benchmark` skill with evidence-driven workflow for identifying high-value benchmark targets, designed to avoid low-signal performance testing and over-measurement; includes step-by-step discovery phases from intent resolution through experiment planning,
- Discovery-focused FORMS.md parameter collection for `dotnet-benchmark` reducing implementation-tier choice friction by deferring tier selection to workflow inspection,
- New template assets `operation-benchmark.cs` and `comparison-benchmark.cs` providing refined structural guidance for single-operation and comparative-implementation benchmarks,
- `candidate-selection.md` reference documenting evidence ladders, call-site inspection, profiling integration, and candidate-ranking heuristics to drive the discovery phase,
- `experiment-design.md` reference detailing performance questions, workload selection, semantic preflight and correctness oracle validation, measurement fitness assessment, and early-stop conditions,
- Mandatory semantic preflight validation gate in `dotnet-benchmark` SKILL.md requiring deterministic correctness oracle derivation before accepting full-run results, preventing false-positive baseline misinterpretation,
- Proportionate-stopping decision logic in `dotnet-benchmark` recognizing when measurement is complete and cost does not justify deeper investigation; includes case studies and selectivity-drift repair guidance,
- Yolo mode support in `dotnet-benchmark` for autonomous candidate selection and progress-update-only planning when user intent is explicit,
- Report-aware runner preflight in `dotnet-benchmark` recognizing when SkipBenchmarksWithReports plus matching reports/tuning/ artifacts intentionally filter a benchmark type, preserving benchmark code unchanged,
- Comprehensive eval coverage for `dotnet-benchmark` with 12 test cases covering discovery workflow, candidate selection, evidence gathering, cost-signal analysis, implementation-comparison patterns, semantic preflight validation, selectivity-drift repair, proportionate stopping, yolo mode, and report-aware preflight; includes fixture code supporting five representative benchmark scenarios,
- Enhanced `check-benchmark-requirements.ps1` and new `validate-skill.ps1` tooling supporting discovery workflow validation and template-asset consistency checking,
- Deterministic release-scope resolver script `scripts/resolve-release-scope.ps1` for git-keep-a-changelog providing bleed-guard validation and branch-unique commit identification with JSON output,
- Base history bleed validation guard in git-keep-a-changelog ensuring that only commits unique to the selected branch are included in changelog entries, preventing accidental duplication of already-released work,
- Deterministic commit-subject validator `scripts/validate-commit-subject.ps1` for git-visual-commits enforcing emoji presence in bundled reference table, exactly one ASCII space separator, lowercase description beginning, opt-in conventional-prefix contract, and 70-character maximum,
- Comprehensive test coverage for deterministic subject validation via `scripts/test-commit-subject.ps1` covering validator behavior, error cases, and edge conditions,
- Full-skill-read and subject-validation gates in git-visual-commits requiring complete SKILL.md read before any Git command, bundled deterministic validator invocation before plan display and before commit, and subject validation lock that bypasses `yolo`/`auto` mode.
- Deterministic `repair-roslyn-multiproject-artifacts.ps1` recovery for `agent-smith` that detects Roslyn merge artifacts independently of diagnostic ID, collapses only the registered whole-document namespace-conversion pattern, fails closed on differing or unrecognized candidates, preflights directory repairs before writing, and includes fixture-backed tests for encoding, idempotence, unsupported localized artifacts, and partial-write prevention.

### Changed

- Hardened `agent-smith` EditorConfig conformance guidance so informational workflows preserve explicit `--severity info` across discovery, recovery, and final verification, targeted checks use category-specific formatter subcommands, Roslyn multi-project recovery is based on proven artifact structure rather than diagnostic ID, and `--no-restore` cannot be mistaken for conformance evidence,
- Standardized local PowerShell execution to `pwsh` 7+ while preserving Bash and workflow-specific shell choices; updated all local command examples and contributor guidance accordingly,
- Refactored git-keep-a-changelog scope resolution from implicit caret-notation to deterministic branch-derived ranges using the bundled `resolve-release-scope.ps1` resolver, providing explicit separation between `history_range` (for commits) and `diff_range` (for manifest diffs),
- Enhanced git-keep-a-changelog Step 1 guidance to use the resolver script for all branch-derived scope, eliminating manual range construction and the risk of incorrect inclusivity or boundary drift,
- Improved skill-template validator to recognize and validate git-keep-a-changelog's new deterministic resolver behavior and bleed-guard validation requirements,
- Restructured git-visual-commits SKILL.md with new Critical Rules section documenting full-skill-read requirement, deterministic subject validation lock, identity lock, direct Git execution rule, fail-fast tool validation, auto-approval guard, default scope rule, recovery safety rule, and approval-and-clarification lock,
- Enhanced git-visual-commits description to highlight deterministic validation, full-skill-read requirement, and exact subject format enforcement (approved emoji, one space, lowercase beginning, 70-character maximum),
- Updated repo validator to check git-visual-commits subject-validation infrastructure presence including validate-commit-subject.ps1, test-commit-subject.ps1, and SKILL.md documentation of full-skill-read and subject-validation gates,
- Updated README with documentation of git-visual-commits deterministic subject validation gating and rejection criteria.

### Fixed

- Resolved critical git-keep-a-changelog bug where implicit caret notation and loose range handling could inadvertently include already-released commits in new changelog entries, causing silent duplication of previous release content; now requires explicit bleed-guard validation via the deterministic resolver,
- Corrected skill-validator behavior to account for git-keep-a-changelog's updated scope-resolution contract and bleed-guard validation requirements.

## [0.7.5] - 2026-07-15

This is a patch release focused on extending `trunk-first-repo` with a push-remote workflow mode that safely handles first-time remote pushes by pushing `main` before feature branches, ensuring the remote defaults to the correct branch while maintaining the PR-first workflow philosophy.

### Added

- Push Remote Workflow mode in `trunk-first-repo` for safely pushing to a newly-established remote without manually switching branches or checking out `main`, allowing `push remote <url>` invocation from the feature branch to send `main` by ref (`main:main`) before the feature branch,
- Enhanced eval coverage for `trunk-first-repo` documenting push-remote workflow and Step 0 mode selection behavior,
- Updated README description for `trunk-first-repo` to document safe first-push capability and `push remote <url>` mode alongside the Initialize Workflow.

### Changed

- Extended `trunk-first-repo` SKILL.md with Step 0 mode selector to distinguish between Initialize Workflow (repository creation) and Push Remote Workflow (remote establishment),
- Refined README guidance to emphasize that `push remote <url>` can be invoked later from the feature branch for safer first-push without switching branches,
- Added explicit push-remote documentation to trunk-first-repo "Why?" section explaining safer first-push behavior and benefits of sending `main` by ref.

## [0.7.4] - 2026-07-03

This is a patch release focused on strengthening `git-keep-a-changelog` with mandatory Step 4a base-commit inspection for concrete releases, ensuring that foundational version bumps, release-prep changes, and dependency baseline updates are never omitted from release narratives. The skill now requires explicit inspection of the base commit before manifest diffs and commit bodies, with output verification and structured reporting.

### Added
- Step 4a mandatory checkpoint in `git-keep-a-changelog` that inspects and explicitly reports the base commit for concrete releases (e.g., `## [X.Y.Z]`), showing changed files, identifying dependency/version manifests, and confirming release-prep file modifications before proceeding to Step 4b manifest diffs,
- Explicit base-commit-inclusion enforcement using `<base>^..HEAD` (with caret) throughout Step 4 for concrete releases, ensuring the base commit itself is included in the changelog narrative,
- Verification and confirmation gates in Step 4a requiring agents to show full base commit output, identify manifests, and explicitly state whether manifests or release-prep files were touched before proceeding to 4b,
- Detailed comparison matrix in Step 3b distinguishing between `base^..HEAD` (for concrete releases, inclusive of base) and `base..HEAD` (for [Unreleased], exclusive of base),
- Eval coverage validating base-commit inclusion, manifest detection, and Step 4a output verification for concrete release scenarios.
### Changed

- Restructured `git-keep-a-changelog` Step 4 into explicit sub-steps (4a through 4f) with clear sequencing: base-commit inspection first (4a), manifest detection (4b), manifest diff inspection (4c), commit-body reading (4d), net-diff inspection (4e), and pending-change integration (4f),
- Enhanced `git-keep-a-changelog` SKILL.md with critical range-extension guidance for concrete releases, emphasizing that `<base>^..HEAD` (with caret) must be used consistently to include the base commit itself,
- Strengthened "Bad Output Characteristics" section with **CRITICAL** emphasis on the consequences of omitting the base commit: silently-wrong output that breaks release narratives and loses foundational version bumps,
- Updated README with enhanced description of `git-keep-a-changelog` base-commit enforcement and Step 4a mandatory checkpoint.
## [0.7.3] - 2026-07-01

This is a patch release focused on skill refinement and documentation improvements, including xref member-link validation enhancements to dotnet-docfx-digest, structural improvements to git-keep-a-changelog's manifest-diff reading, and emoji discipline improvements across git-visual skills.

### Added

- xref member link validator to docfx diagnostic engine for precise cross-assembly reference validation,
- Expanded test coverage in docfx-digest `test-quality.ps1` for xref member-link scenarios.

### Changed

- git-keep-a-changelog: restructured Step 4 to read manifest diffs before commit bodies, ensuring the full cumulative dependency picture when multiple commits touched version files,
- git-keep-a-changelog: added mandatory Step 4a for concrete releases to inspect the base commit before reading manifests, capturing foundational release-prep changes and version bumps,
- dotnet-docfx-digest: enhanced SKILL.md documentation to cover xref member link validation rules for interface and abstract types,
- git-visual-commits and git-visual-squash-summary: improved emoji discipline and alignment across commit-language references,
- README: updated skill inventory and capability summaries to reflect enhanced xref validation and changelog-automation improvements.

### Fixed

- xref member-link false positives for interface and abstract types in docfx diagnostic engine,
- manifest inspection steps documentation in git-keep-a-changelog to reflect new Step 4a–4b–4c sequencing for concrete releases.

## [0.7.2] - 2026-06-29

This is a minor release that further refines adaptive execution profiles, enhances heartbeat suppression options, strengthens parallel skill validation support, and expands evaluation coverage for git-visual-squash-summary.

### Added

- Enhanced eval coverage for git-visual-squash-summary documenting semantic grouping, commit language reference compliance, and attribution workflows,
- Parallel skill validation in `validate-skill-templates.ps1` using ThreadJob/Start-Job with adaptive throttling based on processor count, `-Full` flag for comprehensive validation suites, and improved timing/result tracking.

### Changed

- Refined docfx-digest `docfx.cs` with expanded adaptive profile selection logic, multi-phase coordination improvements, and enhanced worker-count scaling,
- Extended docfx-digest SKILL.md with refined adaptive execution profile documentation, heartbeat configuration guidance, and process timeout tuning,
- Enhanced validation workflow in `scripts/validate-skill-templates.ps1` with parallel execution support, per-test timing metrics, and comprehensive `-Full` mode for extended test suites,
- Improved README with current skill capability inventory reflecting validation tooling enhancements and adaptive execution features.

### Fixed

- Corrected heartbeat output suppression in docfx-digest to support `--quiet` and `--no-heartbeat` flags for cleaner output when heartbeats obscure JSON inspection.

## [0.7.1] - 2026-06-25

This is a minor release introducing adaptive execution profiles for long-running operations, comprehensive test coverage expansion, and enhanced docfx-digest skill documentation.

### Added

- Adaptive execution profiles in docfx-digest that select between `conservative` (sequential phases, low worker counts) and `high-capacity` (concurrent phases, scaled workers) based on available processors and memory, with runtime selection heuristics and `--execution-profile` override support,
- Progress heartbeat protocol in docfx-digest with 10-second intervals, elapsed-time tracking, phase context, and optional `--quiet` / `--no-heartbeat` suppression for cleaner output when heartbeats obscure JSON inspection,
- Eval cases covering entry-point detection refinement, test-quality validation scenarios, and enhanced diagnostic guidance in docfx-digest,
- Expanded `test-quality.ps1` comprehensive test validator with extended coverage for quality gates, diagnostic categories, timeout handling, and multi-phase execution scenarios.

### Changed

- Refined entry-point detection logic in docfx-digest with improved test coverage and diagnostic accuracy,
- Enhanced SKILL.md documentation for docfx-digest with clarified validation workflows, completion contract enforcement, and adaptive execution profile guidance,
- Expanded validation scripts and diagnostics in docfx-digest `docfx.cs` and supporting utilities for better failure detection and reporting,
- Extended `references/scripts.md` and `references/workflow.md` with detailed validation guidance, edge-case handling, and heartbeat configuration documentation.

## [0.7.0] - 2026-06-20

This is a minor release adding scope-aware ownership validation, completion contract enforcement, and enhanced conditional API validation guidance to the dotnet-docfx-digest skill.

### Added

- Scope-aware ownership validation in dotnet-docfx-digest that requires exact-UID examples or receiver-style examples to resolve cross-assembly collisions, converting SYMBOL_COLLISION_UNRESOLVED and EXTENSION_OWNER_AMBIGUOUS from warnings to blocking errors,
- Blocking completion contract enforcement: diagnostics such as EXAMPLE_LEAD_MISSING, EXAMPLE_ADVANCED_LEAD_MISSING, FAMILY_ANCHOR_EXAMPLE_MISSING, SAMPLE_STRUCTURE_INVALID, and INTERIM_ARTIFACT_IN_WORKTREE are now blocking repair items rather than optional quality backlog,
- Enhanced conditional API validation guidance for selecting executable test frameworks from the asset containing a conditionally compiled API, with specific rules for NETSTANDARD2_0, modern asset variants, and framework selection via asset resolution confirmation,
- Eval cases 106, 107, and 108 covering completion contract enforcement, scope-aware ownership validation, and conditional API framework selection.

### Changed

- Extended dotnet-docfx-digest SKILL.md with completion contract details, scope-aware ownership validation rules, and conditional API framework selection logic,
- Enhanced docfx.cs help text and agents.cs prompt guidance with ownership validation and conditional API framework selection documentation,
- Expanded workflow.md and scripts.md references with scope-aware validation logic and framework selection rules.

## [0.6.0] - 2026-06-08

This is a minor release introducing the `dotnet-change-impact` skill for classifying .NET library and NuGet package changes against Microsoft's official compatibility rules. The skill automatically resolves the current branch against the upstream default branch, compares commits and diffs, and recommends the correct SemVer release bump (Major, Minor, or Patch) along with structured compatibility reasoning.

### Added

- `dotnet-change-impact` skill that classifies .NET library changes and recommends version bumps according to Microsoft's official .NET library compatibility model, supporting breaking changes, API diffs, public API changes, dependency updates, TFM and platform support changes, interface and enum modifications, overloads, analyzers, and source generators,
- Automatic default-branch resolution in `dotnet-change-impact` when no explicit change details or compare range are provided; the skill inspects the current Git branch and compares against the upstream default branch, with fallback to `main` or `master`,
- Comprehensive compatibility-categories reference documentation in `references/compatibility-categories.md` covering Major (breaking changes, removals, contract modifications), Minor (new capabilities without breaking changes), and Patch (fixes, maintenance, non-breaking refinement) classifications,
- Per-skill evals coverage for `dotnet-change-impact` including current-branch detection, breaking-change scenarios, API compatibility assessments, dependency updates, and SemVer classification validation,
- `dotnet-change-impact` registered in README skill index with install snippet and detailed "Why dotnet-change-impact?" section explaining Microsoft compatibility grounding and key capabilities,
- Hero image asset for `dotnet-change-impact`.

### Changed

- Enhanced README with `dotnet-change-impact` installation guidance and capability showcase, including examples of breaking changes, API diffs, and compatibility assessment workflows,
- Improved prose readability in `dotnet-change-impact` SKILL.md by removing artificial line breaks to enhance natural reading flow.

## [0.5.0] - 2026-06-07

This is a minor release introducing the `git-remote-release` skill for generating GitHub release notes by summarizing commits and pull requests between git tags or branches. This complements the existing changelog and release-notes workflow by providing a GitHub-specific release entry point.

### Added

- `git-remote-release` skill that reads a commit range or github.com compare URL, summarizes all commits and pull requests between two git references, and generates GitHub release notes with proper markdown formatting,
- `FORMS.md` for `git-remote-release` with structured input collection for branch/tag range specification,
- Hero image asset for `git-remote-release`,
- Evals coverage for `git-remote-release` release notes generation.

### Changed

- Expanded README with `git-remote-release` installation snippet and capability showcase documenting release notes generation from commits, PRs, and branch comparisons.

## [0.4.6] - 2026-06-07

This is a patch release focused on strengthening scaffolding templates with safeguards and coverage guidance, plus clarifying the author-neutral scope of `git-visual-squash-summary` to prevent stale same-named tracking branches from hiding work.

### Added

- Safeguards and coverage guidance in `dotnet-new-app-slnx` and `dotnet-new-lib-slnx` shared assets (`AGENTS.md` and `.github/copilot-instructions.md`) documenting bot workspace management, eval isolation discipline, and git identity rules,
- Eval coverage for `git-visual-squash-summary` documenting author-neutral scope and base-branch resolution behavior.

### Changed

- Enhanced `git-visual-squash-summary` SKILL.md guidance to clarify author-neutral scope and to explicitly document how the skill compares against repository base branches rather than same-named tracking remotes, preventing stale tracking copies from masking real work,
- Updated `git-visual-squash-summary` shared documentation in scaffold templates to reflect author-neutral behavior and base-branch-first resolution.

## [0.4.5] - 2026-05-31

This is a patch release focused on improving `git-repo-digest` documentation link extraction and validation logic, expanding eval coverage, and establishing explicit git operations safeguards policy for agent-driven repositories. The skill now validates documentation URLs with HTTP HEAD requests before accepting them, provides fallback chains across multiple documentation sources, and fails fast when no valid URL is found.

### Added

- Enhanced `git-repo-digest` documentation URL resolution with HTTP validation, probing multiple fallback sources (package URLs, `.docfx/docfx.json` hints, `README.md` links) and requiring at least one `200 OK` response before generating digest prose,
- Evals 43–45 covering HTTP-validated documentation URL fallback chains, convenience package documentation linking, and edge cases,
- Git Operations Safeguards section in `AGENTS.md` establishing mandatory approval gates for agent-driven commits and remote operations, explicitly forbidding automatic pushes, pulls, or fetches without user instruction,
- Additional safeguards context in README and AGENTS.md clarifying that automatic commits pollute history and unexpected remote operations risk data loss.

### Changed

- Refined `git-repo-digest` SKILL.md guidance to preserve generated `title` from repository-owned `<Product>` metadata instead of replacing with invented prose, and to treat generated documentation links as validated HTTP URLs,
- Enhanced `git-repo-digest` `digest.cs` with robust HTTP client setup, 10-second timeout for documentation validation, improved error handling for failed URL validation requests, and clear retry guidance when candidates fail,
- Updated manifest documentation for `frontmatterHints` to clarify that documentation entries are validated HTTP URLs and that overview `title` comes from repository metadata,
- Expanded eval contracts and test case documentation to cover HTTP validation failures, timeout behavior, and fallback chain exhaustion,
- Updated README.md guidance to highlight HTTP-validated documentation URL resolution and documented git operations safeguards.

## [0.4.4] - 2026-05-18

This is a minor release strengthening `git-repo-digest` with HTTP-validated documentation URL resolution and repository-owned product title discovery, plus clarifying `git-visual-squash-summary` base branch resolution behavior to prevent stale same-named tracking branches from hiding work. The `git-repo-digest` runner now resolves documentation hosts from package URLs and project configuration, validates candidate documentation URLs with HTTP HEAD requests, falls back across multiple sources (root `PackageProjectUrl`, `.docfx/docfx.json`, README `## Documentation` links), and fails fast when no candidate returns `200 OK`. Repository titles for `result/Index.md` are sourced from a root `Directory.Build.props` `<Product>` value, with fallback to the highest-referenced top-level packable `.csproj` `<Product>` when the root value is absent. The `git-visual-squash-summary` skill now explicitly avoids using a same-named tracking remote such as `origin/<current-branch>` as a squash base; instead it resolves against the repository's actual base branch such as `origin/main`, `origin/master`, `main`, or `master` before declaring there is nothing to summarize.

### Added

- HTTP-validated documentation URL resolution in `git-repo-digest` `digest.cs` that accepts `PackageProjectUrl` as the primary candidate, probes package-specific API URLs derived from `.docfx/docfx.json`, falls back to `## Documentation` links in `README.md` and `.nuget/**/README.md`, and requires at least one `200 OK` response before generating digest prose,
- Repository product title discovery in `git-repo-digest` `digest.cs` that reads `<Product>` from root `Directory.Build.props` first, then from the most-referenced top-level packable `.csproj` when the root value is absent, failing fast when no literal product metadata is available,
- `ResolveRepositoryProductTitle`, `ReadRootProduct`, `DiscoverProjectProductCandidates`, `ResolveDocumentationUrlAsync`, and `ResolveRepositoryPackageProjectUrl` methods in `git-repo-digest` `digest.cs` to support robust title and documentation resolution,
- HTTP client with 10-second timeout for documentation URL validation in `git-repo-digest` `digest.cs`,
- Evals 40, 41, and 42 covering repository product title resolution, HTTP-validated documentation URL fallback chains, and convenience package documentation linking behavior,
- Eval 13 for `git-visual-squash-summary` covering the case where a feature branch is in sync with a same-named tracking remote but has real changes versus the repository base branch, ensuring the skill compares against the base branch and not the tracking copy.

### Changed

- Enhanced `git-repo-digest` SKILL.md guidance to preserve generated `title` from repository-owned `<Product>` metadata instead of replacing it with invented prose, and to treat generated documentation links as already validated by the runner,
- Updated `git-repo-digest` manifest documentation for `frontmatterHints` to clarify that documentation entries are validated HTTP URLs and that the overview `title` is repository-owned product metadata, not a URL-derived repository id,
- Updated `git-repo-digest` eval 24 to use a direct documentation URL candidate instead of a generic documentation host, ensuring tests exercise the URL validation path,
- Refined `git-visual-squash-summary` SKILL.md to clarify base branch resolution order: prefer the remote default branch such as `origin/HEAD`, then `origin/main`, `origin/master`, local `main`, and local `master` automatically; treat a same-named tracking branch as a sync target only and never as a squash base unless explicitly requested,
- Updated `git-visual-squash-summary` README description to highlight base-branch-not-tracking-copy behavior and to remove outdated non-mutating language in favor of read-only clarity.

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

[Unreleased]: https://github.com/codebeltnet/agentic/compare/v0.8.2...HEAD
[0.9.0]: https://github.com/codebeltnet/agentic/compare/v0.8.2...v0.9.0
[0.8.2]: https://github.com/codebeltnet/agentic/compare/v0.8.1...v0.8.2
[0.8.1]: https://github.com/codebeltnet/agentic/compare/v0.8.0...v0.8.1
[0.8.0]: https://github.com/codebeltnet/agentic/compare/v0.7.5...v0.8.0
[0.7.5]: https://github.com/codebeltnet/agentic/compare/v0.7.4...v0.7.5
[0.7.4]: https://github.com/codebeltnet/agentic/compare/v0.7.3...v0.7.4
[0.7.3]: https://github.com/codebeltnet/agentic/compare/v0.7.2...v0.7.3
[0.7.2]: https://github.com/codebeltnet/agentic/compare/v0.7.1...v0.7.2
[0.7.1]: https://github.com/codebeltnet/agentic/compare/v0.7.0...v0.7.1
[0.7.0]: https://github.com/codebeltnet/agentic/compare/v0.6.0...v0.7.0
[0.6.0]: https://github.com/codebeltnet/agentic/compare/v0.5.0...v0.6.0
[0.5.0]: https://github.com/codebeltnet/agentic/compare/v0.4.6...v0.5.0
[0.4.6]: https://github.com/codebeltnet/agentic/compare/v0.4.5...v0.4.6
[0.4.5]: https://github.com/codebeltnet/agentic/compare/v0.4.4...v0.4.5
[0.4.4]: https://github.com/codebeltnet/agentic/compare/v0.4.3...v0.4.4
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
