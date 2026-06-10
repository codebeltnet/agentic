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

Validates the deterministic documentation requirements against the compiled repository, not against text in `SKILL.md`. It builds the solution, discovers public API from compiled assemblies, prefers reference assemblies, loads metadata through `System.Reflection.MetadataLoadContext`, resolves dependencies from project assets, deps files, and installed .NET reference packs, then checks namespace overview pages, extension-member tables, availability, required per-type overwrite examples for public non-abstraction types and public extension methods, the Codebelt overwrite convention (`api/namespaces/**/*.md` for namespace pages and `api/types/**/*.md` for type pages, both under `build.overwrite` only), and compiles every C# documentation sample as a file-based app. For Codebelt strong-name signed repositories, repository and sample builds use the root `.snk` when present and automatically pass `-p:SkipSignAssembly=true` when no root `.snk` exists, so missing local signing keys do not masquerade as documentation failures.

```bash
dotnet run --file docfx.cs -- --repo-root .
dotnet run --file docfx.cs -- --repo-root . --json
dotnet run --file docfx.cs -- --repo-root . --no-validate-samples
dotnet run --file docfx.cs -- --repo-root . --changed-only
dotnet run --file docfx.cs -- --repo-root . --verify-docfx-build
dotnet run --file docfx.cs -- --repo-root . --json --repair-plan /tmp/docfx-repair-plan.md
dotnet run --file docfx.cs -- --repo-root . --configuration Debug --framework net10.0
```

Arguments: `--repo-root`, `--docfx`, `--configuration` (default `Release`), `--framework`, `--validate-samples` / `--no-validate-samples` (default on), `--changed-only`, `--verify-docfx-build`, `--repair-plan <path>`, `--clean-generated-metadata` / `--no-clean-generated-metadata` (default on), `--json`, `--help`. When `--framework` is omitted and `docfx.json` declares a single `metadata.properties.TargetFramework`, that framework is used as the validation target.

`--changed-only` scopes namespace-page, required-example, and sample validation to the changed documentation or source inputs that affect those checks. It includes both tracked changes from `git diff` and untracked documentation files from `git ls-files --others --exclude-standard`, so brand-new overwrite Markdown still has its C# samples compiled before the file is staged. New or changed public APIs must still surface `EXAMPLE_MISSING` diagnostics when their supporting overwrite examples are absent.

`--repair-plan <path>` writes a deterministic Markdown work queue derived from the same diagnostics emitted in JSON/console output. Use it for repo-wide audits or noisy validation runs before editing documentation. The plan groups repository guidance failures, namespace and extension-table repairs, a required-example inventory, sample compilation repairs, other errors, and warnings, then adds completion gates that preserve authored Markdown, require generated-artifact cleanup paths to be listed before deletion, forbid broad restore/checkout recovery, require related namespace pages to be repaired together, and require `git diff` review before final verification. The required-example inventory is a concrete work queue: for public non-abstraction types, it names the expected type-targeting overwrite path such as `.docfx/api/types/X.Y.Z.Class1.md`; namespace overview examples and `Extension Members` tables do not complete those items. For extension methods, the plan points agents toward the declaring extension class or namespace page rather than odd URL-encoded method-UID filenames, and config/layout diagnostics require both `api/namespaces/**/*.md` and `api/types/**/*.md` under `build.overwrite` while moving legacy `.docfx/api/*.md` authored overwrite files into the appropriate subdirectory. Write the plan to a temp path unless the user explicitly wants a checked-in artifact.

`--verify-docfx-build` copies the repository to a temp workspace, resolves the DocFX CLI from `PATH`, runs it against the resolved `docfx.json` there, and removes the temp workspace afterward. Use it instead of running `docfx .docfx/docfx.json` directly from the working tree so generated API YAML, manifest files, and site output such as a configured `build.dest` folder do not flood git status. The temp copy preserves a root `.snk` when the source checkout has one; otherwise the DocFX process receives `SkipSignAssembly=true` in its environment so Codebelt signed projects can still build in keyless workspaces. The default generated-output cleanup remains as a fallback for direct in-repo DocFX runs: it derives `metadata[].dest` and `build.dest` from `docfx.json`, removes generated `*.yml`, `.manifest`, and `*.manifest` files under metadata destinations, and removes the configured build output directory only when it is safely inside the repository and does not contain authored Markdown, source, project, solution, or DocFX configuration files. Authored `.md` overwrite files, namespace pages, and type pages are documentation output, not cleanup targets.

Process execution drains stdout and stderr concurrently so verbose `dotnet build` or DocFX runs cannot deadlock on a full pipe while the validator waits for exit.

Exit codes:

| Code | Meaning |
|-----:|---------|
| 0 | Validation passed |
| 1 | Validation failed |
| 2 | Invalid arguments |
| 3 | Repository root does not exist |
| 4 | DocFX configuration file not found |
| 5 | Build failed |
| 6 | Public API discovery failed |
| 7 | Sample compilation failed |
| 8 | Unexpected internal error |

Error codes emitted in JSON include `AGENTS_BLOCK_MISSING`, `DOCFX_CONFIG_MISSING`, `API_OVERWRITE_CONFIG_INVALID`, `API_OVERWRITE_FILE_MISPLACED`, `BUILD_FAILED`, `PUBLIC_API_DISCOVERY_FAILED`, `NAMESPACE_PAGE_MISSING`, `NAMESPACE_UID_MISSING`, `NAMESPACE_UID_MISMATCH`, `NAMESPACE_SUMMARY_MISSING`, `NAMESPACE_FLYIN_MISSING`, `AVAILABILITY_MISSING`, `EXTENSION_SECTION_MISSING`, `EXTENSION_TABLE_MISSING`, `EXTENSION_METHOD_MISSING`, `EXAMPLE_MISSING`, `SAMPLE_COMPILE_FAILED`, `SAMPLE_SKIP_REASON_MISSING`, `SAMPLE_SKIP_REASON_INSUFFICIENT`, `DOCFX_BUILD_FAILED`, `GENERATED_METADATA_CLEANUP_FAILED`, `GENERATED_METADATA_CLEANUP_SKIPPED`, `GENERATED_OUTPUT_CLEANUP_FAILED`, and `GENERATED_OUTPUT_CLEANUP_SKIPPED`. Warnings include `DOCFX_EXTENSION_BLOCK_UNSUPPORTED` when C# 14 extension blocks are detected in the public API (see DocFX issue #11010). Validation warnings can also include `API_OVERWRITE_CONFIG_UNREADABLE` when the validator cannot parse the DocFX config well enough to inspect the overwrite layout.

### Sample opt-out

A C# fence may opt out of compilation only with a mandatory reason:

```csharp
// dotnet-docfx-digest:skip-compile - requires a configured database connection
```

A skip marker without a reason is reported as `SAMPLE_SKIP_REASON_MISSING`.

A skip marker with a weak reason such as "full example requires X package" or "example shows the framework pattern" is reported as `SAMPLE_SKIP_REASON_INSUFFICIENT`. Package requirements and framework setup belong in the documentation around a compiling sample; they are not enough to skip compilation by themselves.

### Example detection

The validator recognizes a complete example as one of:

- A DocFX front-matter anchor (`example: *content` or the list form `example:\n- *content`) followed by a body that contains a fenced `csharp`/`cs` block; **or**
- A `## Example` / `### Example` heading in the body followed by a fenced `csharp`/`cs` block.

The first form is preferred for type pages and extension-class pages. Add a `### Examples` heading only when the front matter anchors the body to `summary` and you intend the heading to delimit the embedded example. The validator reports `EXAMPLE_MISSING` only when neither form is present. A run that reports `EXAMPLE_MISSING` while the rendered page clearly shows an example indicates a front-matter / heading mismatch — verify the YAML anchor before adding a body heading.

### Extension-method detection note

Extension methods are detected from compiled metadata: a public static method carrying `System.Runtime.CompilerServices.ExtensionAttribute`, declared on a public class (which may be generic or a static extension container) with at least one parameter. The first parameter's type is recorded as the extended type. The C# compiler marks the method, not the first parameter, with `ExtensionAttribute`, so detection keys off the method attribute to match real metadata. Generic declaring classes and generic extension methods are both valid targets and are not excluded.

C# 14 extension-block types are collapsed back to their authored outer static class so that synthetic compiler-generated nested types such as `<G>$...` are never treated as standalone documentation targets. When C# 14 extension blocks are detected the validator emits a `DOCFX_EXTENSION_BLOCK_UNSUPPORTED` warning noting that DocFX issue #11010 means generated API metadata for those members may be missing. Classic `this`-parameter extension methods remain fully supported and unaffected.
