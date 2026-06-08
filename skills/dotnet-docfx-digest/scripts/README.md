# dotnet-docfx-digest scripts

Two deterministic .NET 10 file-based apps back the skill so that repository
guidance and documentation rules are enforced by code, not by AI memory. Each
script is a single `.cs` file with no `.csproj` and runs directly:

```bash
dotnet run --file <script>.cs -- <arguments>
dotnet build <script>.cs
```

Both declare `#:property TargetFramework=net10.0` and `#:property PublishAot=false`,
return deterministic exit codes, and emit machine-readable JSON with `--json`.

## agents.cs

Ensures the repository root `AGENTS.md` contains a marker-bounded DocFX
documentation-maintenance block. Idempotent: running it repeatedly never
duplicates the block. Content outside the markers is preserved, the host file's
line endings are respected, and new files are written as UTF-8 without a BOM.

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

If both markers exist, only the content between them (inclusive) is replaced.
If neither exists, the block is appended. If exactly one marker exists, the file
is treated as corrupt and the script exits non-zero.

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

Validates the deterministic documentation requirements against the *compiled*
repository, not against text in `SKILL.md`. It builds the solution, discovers
public API from compiled assemblies (preferring reference assemblies) via
`System.Reflection.MetadataLoadContext`, then checks namespace overview pages,
extension-member tables, availability, required type-page overwrite examples for
public non-abstraction types and public extension methods, and compiles every C# documentation
sample as a file-based app.

```bash
dotnet run --file docfx.cs -- --repo-root .
dotnet run --file docfx.cs -- --repo-root . --json
dotnet run --file docfx.cs -- --repo-root . --no-validate-samples
dotnet run --file docfx.cs -- --repo-root . --changed-only
dotnet run --file docfx.cs -- --repo-root . --configuration Debug --framework net10.0
```

Arguments: `--repo-root`, `--docfx`, `--configuration` (default `Release`),
`--framework`, `--validate-samples` / `--no-validate-samples` (default on),
`--changed-only`, `--json`, `--help`.

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

Error codes emitted in JSON include `AGENTS_BLOCK_MISSING`,
`DOCFX_CONFIG_MISSING`, `BUILD_FAILED`, `PUBLIC_API_DISCOVERY_FAILED`,
`NAMESPACE_PAGE_MISSING`, `NAMESPACE_UID_MISSING`, `NAMESPACE_UID_MISMATCH`,
`NAMESPACE_SUMMARY_MISSING`, `NAMESPACE_FLYIN_MISSING`, `AVAILABILITY_MISSING`,
`EXTENSION_SECTION_MISSING`, `EXTENSION_TABLE_MISSING`, `EXTENSION_METHOD_MISSING`,
`EXAMPLE_MISSING`, `SAMPLE_COMPILE_FAILED`, and `SAMPLE_SKIP_REASON_MISSING`.

### Sample opt-out

A C# fence may opt out of compilation only with a mandatory reason:

```csharp
// dotnet-docfx-digest:skip-compile - requires a configured database connection
```

A skip marker without a reason is reported as `SAMPLE_SKIP_REASON_MISSING`.

### Extension-method detection note

Extension methods are detected from compiled metadata: a public static method,
carrying `System.Runtime.CompilerServices.ExtensionAttribute`, declared on a
public static non-generic class, with at least one parameter. The first
parameter's type is recorded as the extended type. (The C# compiler marks the
method — not the first parameter — with `ExtensionAttribute`, so detection keys
off the method attribute to match real metadata.)
