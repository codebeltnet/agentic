# dotnet-docfx-digest script reference

Two deterministic .NET 10 file-based apps back the skill so repository guidance and documentation rules are enforced by code instead of AI memory. Each script is a single `.cs` file with no `.csproj` and runs directly:

```bash
dotnet run --file <script>.cs -- <arguments>
dotnet build <script>.cs
```

Both scripts declare `#:property TargetFramework=net10.0` and `#:property PublishAot=false`, return deterministic exit codes, and emit machine-readable JSON with `--json`.

When invoking the scripts from an installed skill, resolve the script path from the loaded `dotnet-docfx-digest` skill directory and pass the target repository separately with `--repo-root <repo-root>`. Do not assume the target repository contains `skills/dotnet-docfx-digest/scripts/*.cs`. If the loaded skill directory cannot be resolved, a repo-managed source checkout may use the repo-relative `skills/dotnet-docfx-digest/scripts/*.cs` path after confirming it exists.

## agents.cs

Ensures the repository root `AGENTS.md` contains a marker-bounded DocFX documentation-maintenance block. It is idempotent, so repeated runs never duplicate the block. Content outside the markers is preserved, the host file's line endings are respected, and new files are written as UTF-8 without a BOM.

```bash
dotnet run --file agents.cs -- --repo-root .            # write (default)
dotnet run --file agents.cs -- --repo-root . --check    # CI enforcement
dotnet run --file agents.cs -- --repo-root . --dry-run  # preview
dotnet run --file agents.cs -- --repo-root . --json     # machine-readable
```

Markers:

```markdown
<!-- dotnet-docfx-digest:start -->
<!-- dotnet-docfx-digest:end -->
```

If both markers exist, only the content between them, inclusive, is replaced. If neither exists, the block is appended. If exactly one marker exists, the file is treated as corrupt and the script exits non-zero.

Exit codes:

| Code | Meaning |
|-----:|---------|
| 0 | Success; file already compliant or successfully updated |
| 1 | Validation failed in `--check` mode |
| 2 | Invalid arguments |
| 3 | Repository root does not exist |
| 4 | `AGENTS.md` contains a corrupt managed block |
| 5 | Write failed |

## docfx.cs

Validates the deterministic documentation requirements against the repository. By default it runs a **fast, no-build path**: it validates Markdown, prose, DocFX API-overwrite layout, encoding, namespace overview pages, extension-member tables, availability, and required per-type/extension-method examples **without compiling the product**. The default path never invokes `dotnet`, `msbuild`, `docfx`, or `gh`. A process guard enforces this: any attempt to launch one of those tools outside an explicitly enabled mode throws immediately, and every run ends with a `[processes] dotnet=… msbuild=… docfx=… gh=…` summary (mirrored in JSON under `summary.processes`) plus per-phase timings under `summary.phases`.

The public API model the fast path validates against is discovered without building, in this preference order: (1) existing DocFX ManagedReference YAML under the configured `metadata.dest` (typically `.docfx/api/**/*.yml`); (2) a conservative source scan of the `.cs` files in the projects referenced by `docfx.json` when no YAML metadata exists. The source scanner discovers public namespaces, public non-abstraction types that require examples, classic `this`-parameter extension methods, and static extension containers; it intentionally errs toward under-reporting and emits an `API_MODEL_SOURCE_SCANNER_LIMITED` warning noting that `--build-api-model` provides reflection-backed precision. The fast path never deletes existing YAML metadata.

Compilation and network access are strictly opt-in, and each option enables exactly one class of external process:

- `--validate-samples` compiles the generated C# documentation samples (`dotnet`). This is the only default-supported path that compiles samples. Every sample gets an isolated project with only the documented project(s) that own its namespace (and their transitive references resolved by MSBuild), never every documented library project. The validator writes those projects into one temporary `.slnx` and launches one graph build, so shared dependencies restore and build once while `--sample-parallelism` bounds MSBuild concurrency. Isolation preserves per-sample compiler diagnostics without paying for one `dotnet build` process per fence.
- `--build-api-model` (alias `--strict-api-discovery`) performs reflection-backed API discovery from compiled assemblies (`dotnet`). It builds only the documented project graph through a single temporary `.slnx` graph build rather than N per-project builds, then loads metadata through `System.Reflection.MetadataLoadContext`. Use it when conservative no-build discovery is not enough.
- `--verify-docfx-build` runs DocFX against a temp copy of the repository (`docfx`).
- `--search-examples` runs GitHub code search per documented package (`gh`).

Final verification is machine-adaptive. `--execution-profile auto` is the default. It selects `high-capacity` when `Environment.ProcessorCount` reports more than 8 processors available to the process and `GC.GetGCMemoryInfo().TotalAvailableMemoryBytes` reports more than 32 GiB. In that profile, DocFX verification starts in its isolated temp copy while the primary lane builds the documented project graph, discovers API, and compiles samples; the sample phase still follows API discovery because project-scoped sample references depend on the discovered namespace-to-project map. Build and sample MSBuild parallelism default to half the available processors, capped at 16. Other machines use `conservative`, which keeps final phases sequential and defaults to at most 2 workers. Force a profile with `--execution-profile` or `DOCFX_DIGEST_EXECUTION_PROFILE`; override workers with `--build-parallelism`, `DOCFX_DIGEST_BUILD_PARALLELISM`, `--sample-parallelism`, or `DOCFX_DIGEST_SAMPLE_PARALLELISM`.

External child processes have a 30-minute default timeout. Override it with `--process-timeout-minutes` or `DOCFX_DIGEST_PROCESS_TIMEOUT_MINUTES` (1-180). The calling agent/tool must use an outer command timeout at least five minutes longer than the validator timeout; otherwise the caller can terminate the validator before it kills the child process and emits `DOCFX_BUILD_FAILED` or another deterministic diagnostic.

API builds, sample graph builds, and DocFX verification emit append-only progress events to `stderr`. The validator writes `[ ]` when a child starts, another `[ ]` heartbeat every 10 seconds, and `[✓]` or `[x]` when it completes. Each heartbeat includes the phase, project/sample workload, runner count, child PID, elapsed time, time since the child last wrote output, and the latest non-empty output line when available. This makes a quiet restore/build distinguishable from a stale process without corrupting `--json`, which remains exclusively on `stdout`. Redirected logs use plain markers; interactive terminals color the completion marker when ANSI color is available.

For Codebelt strong-name signed repositories, build and sample paths use the root `.snk` when present and automatically pass `-p:SkipSignAssembly=true` when no root `.snk` exists, so missing local signing keys do not masquerade as documentation failures.

```bash
dotnet run --file docfx.cs -- --repo-root .                                  # fast, no-build (default)
dotnet run --file docfx.cs -- --repo-root . --json
dotnet run --file docfx.cs -- --repo-root . --validate-samples              # compile C# samples (dotnet)
dotnet run --file docfx.cs -- --repo-root . --build-api-model               # reflection-backed API discovery (dotnet)
dotnet run --file docfx.cs -- --repo-root . --changed-only
dotnet run --file docfx.cs -- --repo-root . --verify-docfx-build            # DocFX build verification (docfx)
dotnet run --file docfx.cs -- --repo-root . --json --repair-plan /tmp/docfx-repair-plan.md
dotnet run --file docfx.cs -- --repo-root . --json --repair-plan /tmp/docfx-repair-plan.md --search-examples
dotnet run --file docfx.cs -- --repo-root . --validate-samples --sample-reference-mode package
dotnet run --file docfx.cs -- --repo-root . --build-api-model --configuration Debug --framework net10.0
```

Arguments: `--repo-root`, `--docfx`, `--configuration` (default `Release`, only used by build/sample paths), `--framework`, `--validate-samples` / `--no-validate-samples` (default off — opt-in), `--sample-reference-mode <project|package>` (default `project`), `--sample-parallelism <n>` (1-16, adaptive default; env `DOCFX_DIGEST_SAMPLE_PARALLELISM`; passed as the maximum node count for the batched sample graph build), `--build-parallelism <n>` (1-16, adaptive default; env `DOCFX_DIGEST_BUILD_PARALLELISM`), `--execution-profile <auto|conservative|high-capacity>` (env `DOCFX_DIGEST_EXECUTION_PROFILE`), `--process-timeout-minutes <n>` (1-180, default 30; env `DOCFX_DIGEST_PROCESS_TIMEOUT_MINUTES`), `--build-api-model` / `--strict-api-discovery` (default off — opt-in), `--changed-only`, `--verify-docfx-build`, `--repair-plan <path>`, `--search-examples`, `--clean-generated-metadata` / `--no-clean-generated-metadata` (default off — opt-in), `--json`, `--help`. When `--framework` is omitted and `docfx.json` declares a single `metadata.properties.TargetFramework`, that framework is used as the validation target.

Project-scoped authoring arguments: `--project <hint>` (repeatable; resolves against project path, file name, assembly name, or package id and must match exactly one project), `--dry-run` (select a representative working-tree run), `--seed <integer>` (reproducible dry-run selection; reported when generated), `--project-manifest <path>` (write a deterministic BOM-less packet manifest, initial dirty baseline, and sibling review template), `--resume-project-manifest <path>` (resume exactly those selected packets after authoring), `--review-report <path>` (required on resume; validates page-specific evidence, purpose/outcome, observable result, and pattern comparison), `--write-overwrite <path>` (safe structured overwrite-writer command), `--allow-high-risk` (proceed past the quality-risk pilot stop as an explicit decision), `--risk-standalone-threshold <n>` (default 100), `--risk-extension-threshold <n>` (default 100), and `--risk-missing-ratio-threshold <x>` (default 10). These appear in the report under `scope` and `qualityRisk`.

```bash
dotnet run --file docfx.cs -- --repo-root . --dry-run --build-api-model --project-manifest /tmp/dry-run.json
                                                                            # select one clean project per dest group
dotnet run --file docfx.cs -- --repo-root . --dry-run --seed 1234 --build-api-model --project-manifest /tmp/dry-run.json
                                                                            # reproduce and persist selection
dotnet run --file docfx.cs -- --repo-root . --project Cuemon.Core            # scoped run (no random selection)
dotnet run --file docfx.cs -- --repo-root . --dry-run --project Cuemon.Core --project src/Cuemon.Net/Cuemon.Net.csproj --build-api-model --project-manifest /tmp/dry-run.json
dotnet run --file docfx.cs -- --repo-root . --resume-project-manifest /tmp/dry-run.json --review-report /tmp/dry-run.review.json --build-api-model --validate-samples --verify-docfx-build --json
dotnet run --file docfx.cs -- --repo-root . --build-api-model --project-manifest /tmp/packets.json
dotnet run --file docfx.cs -- --repo-root . --write-overwrite /tmp/overwrite-request.json
```

The scanner correctly handles block namespaces whose opening brace is on the next line; when it cannot pair a declaration with its brace it warns `API_MODEL_SOURCE_SCANNER_INCOMPLETE`. Project discovery groups projects by their DocFX metadata destination (`metadata[].dest`, default `api`): a group is a sampling unit, and distinct destinations are never collapsed into one ownership-free list. A run is `full`, `scoped` (explicit `--project` hints), or `dry-run` (seeded one-per-group selection). When the API model is `source-scan` and authoring scope is requested, `summary.scopeState` is `provisional` and `BUILD_BACKED_SCOPE_REQUIRED` fires; DocFX YAML or `--build-api-model` make scope `authoritative`. A `dry-run`/`scoped` run never sets `summary.canClaimCompletion`; `*-passed` requires zero diagnostics and all three final gates (`--build-api-model`, `--validate-samples`, `--verify-docfx-build`), otherwise it is `*-failed`. Dirty related paths (staged, unstaged, renamed, deleted, untracked) mark a packet dirty so initial dry-run selection skips it (`DRY_RUN_GROUP_UNSELECTED` when a group has no clean candidate). A resumed manifest reuses only the initial dirty baseline, allowing newly authored files to be verified while continuing to protect pre-existing work; invalid manifests fail closed.

The JSON `scope` object contains `mode`, `seed`, `scopeState`, `metadataGroups` (with the `selectedProject` per group), `selectedProjects`, `skippedProjects`, `packets` (project identity, metadata groups, owned/shared namespaces, target counts, overwrite paths, review paths, dirty related paths, per-packet diagnostic counts), `dirty`, `familyExemptions`, `reproduceCommand`, and, after manifest creation, `resumeCommand`. The top-level report includes `reviewReportPath`. `--project-manifest` writes the packet evidence and initial git baseline as schema version 2 plus a sibling schema-version-1 review template. The resumed run requires every changed selected page to have non-placeholder `evidence`, `purpose`, `observableOutcome`, and `patternComparison` fields before `dry-run-passed` or `scoped-passed` is possible.

`--write-overwrite <path>` reads a JSON request (`file`, `uid`, `mapping` of `example`/`summary`/`remarks`, optional `prose`, optional `fence`), validates the YAML and balanced fences, refuses duplicate UIDs (`OVERWRITE_UID_DUPLICATE`), unbalanced fences (`OVERWRITE_FENCE_UNBALANCED`), and replacing a pre-existing dirty file (`OVERWRITE_DIRTY_REFUSED`), preserves the target's existing BOM and line endings, and prints a change preview. It only writes structured content the agent already authored; it never generates prose, selects members, or synthesizes examples.

`--changed-only` scopes namespace-page, required-example, and sample validation to the changed documentation or source inputs that affect those checks. It still does not build by default: Markdown/overwrite-only changes are validated against the no-build API model, and it uses `git` (read-only) to discover changes. It includes both tracked changes from `git diff` and untracked documentation files from `git ls-files --others --exclude-standard`, so brand-new overwrite Markdown still has its C# samples compiled (under `--validate-samples`) before the file is staged. New or changed public APIs must still surface `EXAMPLE_MISSING` diagnostics when their supporting overwrite examples are absent.

`--repair-plan <path>` writes a deterministic Markdown work queue derived from the same diagnostics emitted in JSON/console output. Use it for repo-wide audits or noisy validation runs before editing documentation. The plan groups repository guidance failures, encoding repairs, namespace and extension-table repairs, a required-example inventory with GitHub search commands, sample compilation repairs, other errors, and warnings, then adds completion gates that preserve authored Markdown, require generated-artifact cleanup paths to be listed before deletion, forbid broad restore/checkout recovery, require related namespace pages to be repaired together, and require `git diff` review before final verification. The required-example inventory includes missing examples and semantic failures such as duplicate UID mappings, placeholders, `default!`/`null!` holders, no-observable-outcome and mass-forwarding scaffolds, repeated code templates across unrelated targets, reflection-only scaffolds, target types that are never used, and extension methods that are never invoked. For public non-abstraction types, it names the expected type-targeting overwrite path such as `.docfx/api/types/X.Y.Z.Class1.md`; namespace overview examples and `Extension Members` tables do not complete those items. For extension methods, the plan points agents toward the declaring extension class or namespace page rather than odd URL-encoded method-UID filenames, and config/layout diagnostics require both `api/namespaces/**/*.md` and `api/types/**/*.md` under `build.overwrite` while moving legacy `.docfx/api/*.md` authored overwrite files into the appropriate subdirectory. Write the plan to a temp path unless the user explicitly wants a checked-in artifact. The plan always includes a "GitHub Example Sources" section with `gh search code` commands and GitHub search URLs for each documented package, even when no `EXAMPLE_MISSING` diagnostics are present.

`--search-examples` runs `gh search code` for each discovered package ID and embeds the top matching file paths in the repair plan under "GitHub Search Results". Requires the `gh` CLI to be authenticated. Combine with `--repair-plan` so results are written to a file the agent can read. If `gh` is unavailable or returns no results, the plan still includes the pre-computed search URLs and CLI commands.

`--verify-docfx-build` copies the repository to a temp workspace, resolves the DocFX CLI from `PATH`, runs it against the resolved `docfx.json` there, and removes the temp workspace afterward. Use it instead of running `docfx .docfx/docfx.json` directly from the working tree so generated API YAML, manifest files, and site output such as a configured `build.dest` folder do not flood git status. The temp copy preserves a root `.snk` when the source checkout has one; otherwise the DocFX process receives `SkipSignAssembly=true` in its environment so Codebelt signed projects can still build in keyless workspaces.

`--clean-generated-metadata` is opt-in and disabled by default, so the fast path never deletes existing DocFX YAML metadata it may have read for API discovery. When enabled, cleanup runs only after the API model has been built and all validation has completed, so it never removes metadata the current run depended on and never deletes-then-rebuilds. It derives `metadata[].dest` and `build.dest` from `docfx.json`, removes generated `*.yml`, `.manifest`, and `*.manifest` files under metadata destinations, and removes the configured build output directory only when it is safely inside the repository and does not contain authored Markdown, source, project, solution, or DocFX configuration files. Authored `.md` overwrite files, namespace pages, and type pages are documentation output, not cleanup targets.

Process execution drains stdout and stderr concurrently so verbose `dotnet build` or DocFX runs cannot deadlock on a full pipe while the validator waits for exit.

Exit codes:

| Code | Meaning |
|-----:|---------|
| 0 | Validation passed |
| 1 | Validation failed |
| 2 | Invalid arguments |
| 3 | Repository root does not exist |
| 4 | DocFX configuration file not found |
| 5 | Build failed (only reachable with `--build-api-model`) |
| 6 | Public API discovery failed (only reachable with `--build-api-model`) |
| 7 | Sample compilation failed (only reachable with `--validate-samples`) |
| 8 | Unexpected internal error |

Every run records a process tally, per-phase timings, and execution settings. Non-JSON output prints a `[processes] dotnet=… msbuild=… docfx=… gh=…` line and `[phase] <name>: <seconds>s` lines; JSON output exposes the same data under `summary.processes`, `summary.phases`, and `summary.execution`. Long-running child progress is intentionally written to `stderr`, not embedded in the JSON report. The execution object reports profile, logical processors, available memory bytes, build/sample parallelism, process timeout, and whether DocFX verification used the concurrent lane. `summary.validationMode` is `fast-markdown` or `build-backed-api-model`, and `summary.apiModelSource` is `docfx-yaml`, `source-scan`, or `build-backed`. For a default fast run on any repository, the process counts for `dotnet`, `msbuild`, `docfx`, and `gh` are all `0`.

Every report also carries a deterministic completion contract. `summary.completionState` is `complete` only when there are no errors and the run enabled `--build-api-model`, `--validate-samples`, and `--verify-docfx-build`. A clean fast run reports `verification-required`. `summary.canClaimCompletion` must be `true`; `summary.remainingWorkItems` must be `0`; and both `summary.remainingGates` and `summary.remainingDiagnosticsByCode` must be empty before an agent can claim a full digest. Any other result is an active repair or verification queue. Diagnostic age, pre-existing status, and volume do not convert repair work into an external blocker.

Error codes emitted in JSON include `AGENTS_BLOCK_MISSING`, `DOCFX_CONFIG_MISSING`, `API_OVERWRITE_CONFIG_INVALID`, `API_OVERWRITE_FILE_MISPLACED`, `BUILD_FAILED`, `PUBLIC_API_DISCOVERY_FAILED`, `NAMESPACE_PAGE_MISSING`, `NAMESPACE_UID_MISSING`, `NAMESPACE_UID_MISMATCH`, `NAMESPACE_SUMMARY_MISSING`, `NAMESPACE_FLYIN_MISSING`, `NAMESPACE_PROSE_INVENTORY_ONLY`, `NAMESPACE_APPEND_ONLY_REPAIR`, `NAMESPACE_PROSE_TEMPLATE_REPETITION`, `NAMESPACE_USAGE_GUIDANCE_MISSING`, `NAMESPACE_START_HERE_MISSING`, `AVAILABILITY_MISSING`, `EXTENSION_SECTION_MISSING`, `EXTENSION_TABLE_MISSING`, `EXTENSION_TABLE_ENCODING`, `EXTENSION_METHOD_MISSING`, `ENCODING_CORRUPTION`, `EXAMPLE_MISSING`, `EXAMPLE_UID_DUPLICATE`, `EXAMPLE_PLACEHOLDER`, `EXAMPLE_DEFAULT_PLACEHOLDER`, `EXAMPLE_NO_OBSERVABLE_OUTCOME`, `EXAMPLE_FORWARDING_SCAFFOLD`, `EXAMPLE_TEMPLATE_REPETITION`, `EXAMPLE_REFLECTION_ONLY`, `EXAMPLE_TARGET_NOT_USED`, `EXTENSION_EXAMPLE_NOT_INVOKED`, `SAMPLE_COMPILE_FAILED`, `SAMPLE_SKIP_REASON_MISSING`, `SAMPLE_SKIP_REASON_INSUFFICIENT`, `DOCFX_BUILD_FAILED`, `GENERATED_METADATA_CLEANUP_FAILED`, `GENERATED_METADATA_CLEANUP_SKIPPED`, `GENERATED_OUTPUT_CLEANUP_FAILED`, and `GENERATED_OUTPUT_CLEANUP_SKIPPED`. Project-scoped error codes are `PROJECT_HINT_NOT_FOUND` and `PROJECT_HINT_AMBIGUOUS` for `--project` hints, `FAMILY_EXEMPTION_INVALID`, `FAMILY_ANCHOR_EXAMPLE_MISSING`, and `FAMILY_NAMESPACE_GUIDANCE_MISSING` for `.docfx/family-exemptions.json`, and `OVERWRITE_UID_DUPLICATE`, `OVERWRITE_FENCE_UNBALANCED`, `OVERWRITE_DIRTY_REFUSED`, `OVERWRITE_REQUEST_MISSING`, and `OVERWRITE_REQUEST_INVALID` for the `--write-overwrite` writer. The semantic example codes reject the filler patterns that pass a naive token match: `EXAMPLE_DEFAULT_PLACEHOLDER` for a target parked in a `default!`/`null!` holder property or field, `EXAMPLE_NO_OBSERVABLE_OUTCOME` for an example that only holds, returns, or constructs the target with no visible result, `EXAMPLE_FORWARDING_SCAFFOLD` for a shell dominated by one-line pass-through members, and `EXAMPLE_TEMPLATE_REPETITION` for one normalized code skeleton reused across three or more unrelated targets. `NAMESPACE_APPEND_ONLY_REPAIR` flags an inventory-led opening left intact while usage or start-here guidance is appended below it (rewrite the opening cohesively instead), and `NAMESPACE_PROSE_TEMPLATE_REPETITION` flags three or more namespace overviews that share one normalized prose skeleton. Warnings include `API_MODEL_SOURCE_SCANNER_LIMITED` when the no-build source scanner is the API-model source (run `--build-api-model` for reflection-backed precision), `API_MODEL_SOURCE_SCANNER_INCOMPLETE` when the scanner cannot pair a block namespace declaration with its opening brace and may under-report public types, `BUILD_BACKED_SCOPE_REQUIRED` when authoring scope is requested on the provisional source-scan model, `PROJECT_DIRTY_SKIPPED` when an explicitly selected project has pre-existing related changes, `DRY_RUN_GROUP_UNSELECTED` when a metadata group has no clean project to sample, `QUALITY_RISK_REVIEW_REQUIRED` when the queue size or symbol complexity requires a pilot review, `SYMBOL_COLLISION_UNRESOLVED` / `TYPE_FORWARDING_UNRESOLVED` / `EXTENSION_OWNER_AMBIGUOUS` for unresolved symbol ownership, `API_MODEL_EMPTY` when no-build discovery found no public API (Markdown, encoding, and overwrite-layout checks still run; `--build-api-model` is required for namespace and required-example validation), `DOCFX_EXTENSION_BLOCK_UNSUPPORTED` when C# 14 extension blocks are detected in the public API (see DocFX issue #11010), and `API_OVERWRITE_CONFIG_UNREADABLE` when the validator cannot parse the DocFX config well enough to inspect the overwrite layout.

`ENCODING_CORRUPTION` fires when a documentation file contains the byte sequence `C3 A2 C2 AC` — the UTF-8 re-encoding of the `â¬` pair produced by a Windows-1252 round-trip of `U+2B07` (⬇, the Extension Members table arrow). Restore the affected file with `git checkout HEAD -- <file>` if the committed version was correct, or rewrite the content using the edit tool or byte-level operations. Never use `Get-Content` / `Set-Content` or `[System.Text.Encoding]::UTF8.GetBytes(Get-Content)` to rewrite documentation files that contain multi-byte characters.

`EXTENSION_TABLE_ENCODING` fires when a data row in an Extension Members table is missing the `U+2B07` (⬇️) character in the Ext column, indicating that the emoji is either absent or has been corrupted. The correct literal is `⬇️`, not an HTML entity, a Unicode escape, or a look-alike character.

UTF-8 BOM presence is not validated. `ENCODING_BOM_MISSING` is intentionally not emitted. The BOM is optional for DocFX and has no documentation value by itself, so the validator preserves existing BOM and line-ending state rather than creating encoding-only diffs. `ENCODING_CORRUPTION` and `EXTENSION_TABLE_ENCODING` remain active checks because they detect damaged content rather than a harmless encoding marker difference.

### Sample opt-out

A C# fence may opt out of compilation only with a mandatory reason:

```csharp
// dotnet-docfx-digest:skip-compile - requires a configured database connection
```

A skip marker without a reason is reported as `SAMPLE_SKIP_REASON_MISSING`.

A skip marker with a weak reason such as "full example requires X package" or "example shows the framework pattern" is reported as `SAMPLE_SKIP_REASON_INSUFFICIENT`. Package requirements and framework setup belong in the documentation around a compiling sample; they are not enough to skip compilation by themselves.

Reasons involving missing compile-time references are also rejected as insufficient. These include wording such as "transitive assembly", "transitive dependency", "sample worker does not include", "missing assembly", "referenced assembly", "does not include that assembly", "public signature includes", or "base class from a transitive assembly". Ordinary NuGet package references, project references, framework references, base classes, and extension-method dependencies all resolve correctly because sample worker projects reference documented library projects via `ProjectReference` items, which gives the full compile-time dependency closure. If a sample fails to compile because a dependency type is unresolved, that is a validator defect or a sample authoring error to fix — not a valid skip reason. Fix the example, or fix the validator worker setup; do not add `dotnet-docfx-digest:skip-compile` to hide the gap.

### Example detection

The validator first locates example code in one of:

- A DocFX front-matter anchor (`example: *content` or the list form `example:\n- *content`) followed by a body that contains a fenced `csharp`/`cs` block; **or**
- A `## Example` / `### Example` heading in the body followed by a fenced `csharp`/`cs` block.

The first form is preferred for type pages and extension-class pages. Add a `### Examples` heading only when the front matter anchors the body to `summary` and you intend the heading to delimit the embedded example. Locating a fence is only the structural gate. The validator then rejects duplicate example mappings for the same UID, generated placeholder phrases and helper names, reflection-only metadata lookup, type examples that never use the target in C# code, and extension examples that never invoke the method. It additionally rejects examples that name the target but never exercise it: `default!`/`null!` holder properties, classes whose only interaction is holding or returning the target with no observable result, mass-forwarding shells of one-line pass-through members, and a single normalized code skeleton reused across three or more unrelated targets. Prose, comments, and string literals do not prove target use.

### Extension-method detection note

Extension methods are detected from compiled metadata: a public static method carrying `System.Runtime.CompilerServices.ExtensionAttribute`, declared on a public class (which may be generic or a static extension container) with at least one parameter. The first parameter's type is recorded as the extended type. The C# compiler marks the method, not the first parameter, with `ExtensionAttribute`, so detection keys off the method attribute to match real metadata. Generic declaring classes and generic extension methods are both valid targets and are not excluded.

C# 14 extension-block types are collapsed back to their authored outer static class so that synthetic compiler-generated nested types such as `<G>$...` are never treated as standalone documentation targets. When C# 14 extension blocks are detected the validator emits a `DOCFX_EXTENSION_BLOCK_UNSUPPORTED` warning noting that DocFX issue #11010 means generated API metadata for those members may be missing. Classic `this`-parameter extension methods remain fully supported and unaffected.
