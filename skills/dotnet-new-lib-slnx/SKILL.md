---
name: dotnet-new-lib-slnx
description: >
  Scaffold a new .NET NuGet library solution following codebelt engineering conventions. Use this skill when the user wants to create a new NuGet library, class library, or reusable .NET package. Also use when the user mentions "new library", "new NuGet package", "scaffold library", "class library solution", "dotnet new classlib", or wants a .NET library project with multi-target frameworks, strong-name signing, NuGet packaging, DocFX documentation, CI/CD pipeline, and code quality tooling. ALWAYS use this skill when asked to scaffold or create a new .NET library solution.
---

# .NET Library Solution Setup (Codebelt Conventions)

## Upstream Source

| Field | Value |
|-------|-------|
| **Repo** | `https://github.com/codebeltnet/agentic` |
| **Branch** | `main` |
| **Shared assets root** | `skills/dotnet-new-lib-slnx/assets/shared` |
| **Raw base URL** | `https://raw.githubusercontent.com/codebeltnet/agentic/main/skills/dotnet-new-lib-slnx/assets/shared` |
| **Asset manifest** | `assets/shared.manifest.json` |

This metadata is the single source of truth for restoring any file the installer may have dropped. Use it immediately — do not spend cycles confirming absence multiple ways first.

Scaffold new .NET NuGet library solutions following the codebeltnet engineering conventions — the same pattern used across [codebeltnet](https://github.com/codebeltnet). Produces a fully wired solution with multi-target framework support, strong-name signing, NuGet packaging, DocFX documentation, CI pipeline, centralized build config, semantic versioning, and code quality tooling.

Generate the scaffold **in the user's current working directory**. Do not create an extra top-level `{REPO_SLUG}` or `{SOLUTION_NAME}` folder unless the user explicitly asks for a nested output folder.

## Step 1: Collect Parameters

Read `FORMS.md` and collect all parameters by presenting each field to the user one at a time using the agent's native input mechanism when the host supports it. If the host does not render native form controls, follow the deterministic plain-text fallback defined in `FORMS.md` instead of improvising your own questioning style. Do not proceed to Step 2 until all required fields are collected and the user confirms the summary.

For fields that already present a recommended `default` or `computed_default`, treat a blank response as accepting that shown value. Do not get stuck in a clarification loop for `root_namespace`, `repository_url`, `package_project_url`, or other defaultable fields just because the user did not type over the recommended choice.

Consistency matters more than creativity during parameter collection. Do not paraphrase field prompts, merge questions, or switch interaction styles mid-flow.

Assume the default shape is a single packable library project whose project name matches `solution_name`. Do not ask for separate library project names unless the user explicitly asks for a multi-project solution or names additional packages/modules.

Collect `repository_url` before `package_project_url` so the package website field can present the repository URL as the recommended default and let the user either accept it or replace it with a dedicated site/docs URL.

Default `target_frameworks` to the newest generally supported .NET LTS for new libraries by reading `https://raw.githubusercontent.com/dotnet/core/refs/heads/main/release-notes/releases-index.json`. Filter to `.NET` entries whose `support-phase` is `active` or `maintenance`, then choose the highest LTS channel and format it as `net{major}.0`. Exclude preview channels. Also surface every other generally supported non-preview LTS and STS channel so the user can deliberately choose any actively supported track. Only suggest multiple TFMs when the user explicitly asks for compatibility across older runtimes or there is a clear support requirement.

When presenting `target_frameworks`, compute these quick-picks from that same releases index before free text:

- Recommended: newest generally supported LTS only
- Additional single-target choices: every other supported LTS or STS channel, sorted newest to oldest and labeled with its support track
- Expanded scope: all generally supported `.NET` channels, newest to oldest, excluding preview channels

Default `benchmark_runner_project_name` to `benchmark-runner`. Treat it as a solution-level tooling project name, not a per-library package name.

## Step 2: Load the Variant Guide

Read `references/library.md` for the library-specific project structure, template file mapping, `.slnx` format, multi-project guidance, and project reference conventions.

## Step 3: Resolve Dynamic Dependency Versions

Before writing `Directory.Packages.props`, resolve every `*_VERSION` placeholder in that file to the latest stable listed version for its matching package ID on NuGet.org.

- Use the NuGet V3 service index at `https://api.nuget.org/v3/index.json` to discover the package metadata endpoints
- Prefer registration metadata so you can ignore unlisted versions and prerelease builds
- If registration metadata is unavailable, fall back to the package base address versions list from the same service index and still exclude prerelease versions
- Resolve each package independently by package ID; never reuse one generic "latest" value across multiple packages
- Never hardcode version numbers from stale examples, screenshots, or prior scaffolds

This includes the benchmark-related packages:

- `BenchmarkDotNet`
- `BenchmarkDotNet.Diagnostics.Windows`
- `Codebelt.Extensions.BenchmarkDotNet.Console`

## Step 4: Apply the Substitution Map

When copying template files, replace these placeholders in file contents:

| Placeholder | Value |
|-------------|-------|
| `{SOLUTION_NAME}` | Solution name (e.g. `MyLibrary`) |
| `{ROOT_NAMESPACE}` | Root namespace prefix (e.g. `Acme`) |
| `{PROJECT_NAME}` | Packable project/package name. Default to `{SOLUTION_NAME}` for the single-project case |
| `{AUTHOR}` | Author name |
| `{AUTHOR_EMAIL}` | Author email |
| `{COMPANY_OR_PERSON}` | Company name or individual publisher name for copyright, NuGet metadata, and DocFX branding |
| `{COPYRIGHT_YEAR}` | Copyright year (e.g. `2026`) |
| `{PACKAGE_PROJECT_URL}` | Public package website or docs URL shown as `Project website` on NuGet |
| `{REPOSITORY_URL}` | Source repository URL shown as `Source repository` on NuGet |
| `{REPO_OWNER}` | GitHub org/user (from URL) |
| `{REPO_SLUG}` | Repo name (last URL segment, lowercased) |
| `{TARGET_FRAMEWORKS}` | Computed from the official .NET releases index; offer the newest generally supported LTS, every other supported LTS or STS single-target choice, or all generally supported non-preview channels for broader scope |
| `{DOCFX_TARGET_FRAMEWORK}` | Highest selected generally supported non-preview TFM used for DocFX metadata generation |
| `{BENCHMARK_RUNNER_PROJECT_NAME}` | Tooling project name for the benchmark host (default `benchmark-runner`) |
| `{BENCHMARK_RUNNER_NAMESPACE}` | Benchmark runner namespace derived from the tooling project name, replacing invalid identifier characters such as `-` with `_` |
| `{BENCHMARK_RUNNER_TARGET_FRAMEWORK}` | Highest selected generally supported non-preview executable TFM from `target_frameworks` |
| `{BENCHMARK_RUNTIME_JOBS}` | One `.AddJob(...)` line per selected executable benchmark runtime, derived from `target_frameworks` |
| `{SNK_FILE}` | e.g. `{repo-slug}.snk` |
| `{SONARCLOUD_ORG}` | SonarCloud org slug (or omit job if skipped) |
| `{SONARCLOUD_KEY}` | SonarCloud project key |

`Directory.Packages.props` also contains package-specific placeholders such as `{BENCHMARKDOTNET_VERSION}`, `{BENCHMARKDOTNET_DIAGNOSTICS_WINDOWS_VERSION}`, `{CODEBELT_EXTENSIONS_BENCHMARKDOTNET_CONSOLE_VERSION}`, and `{MICROSOFT_NET_TEST_SDK_VERSION}`. Resolve each of them from NuGet.org in Step 3 before writing the final file.

## Step 5: Generate All Files

Generate files in this order:

### 1. Copy shared templates
Copy every file from `assets/shared/` to the project root, preserving directory structure. Do **not** copy `assets/shared.manifest.json` — it is a skill-internal file used only for asset validation and restoration, and must never appear in a generated solution. Treat the **current working directory** as that project root. Apply placeholder substitution (Step 4) to all file contents during the copy.

Do this as a recursive, dotfile-aware copy. Hidden folders and files under `assets/shared/` are part of the scaffold and must not be skipped. In particular, copy `assets/shared/.bot/README.md` as a real file in the generated repo; do not replace it with a synthetic `.gitkeep` or placeholder note.

**Asset mismatch policy — pivot immediately to upstream.** The `npx skills add` installer silently strips dot-prefixed entries (`.bot/`, `.github/`, `.editorconfig`, `.gitattributes`, `.gitignore`). Do not spend time re-proving what is absent. The moment any entry from `assets/shared.manifest.json` is missing from the installed skill copy, run `pwsh -NoProfile -File "<skill-root>/scripts/restore-missing-shared-assets.ps1"` to fetch every missing file directly from the upstream repository in one step, then continue. If `pwsh` 7+ is unavailable, use the raw base URL in the **Upstream Source** table above to download each missing file manually. If upstream fetch fails, halt and report — do not substitute placeholders.

Preserve UTF-8 when reading, copying, and writing text files. Do not transcode templates to ANSI, OEM, Windows-1252, or any system-default code page during generation. The shared `.editorconfig` in the scaffold declares `charset = utf-8`, and generated text files should match it from the start.

When a text file does not need substitutions, prefer a byte-preserving file copy instead of read/transform/write.

When a text file does need substitutions, use explicit UTF-8 APIs end-to-end. In PowerShell, prefer .NET file APIs with an explicit `UTF8Encoding` instance rather than locale-dependent text cmdlets. For example:

```powershell
$utf8NoBom = [System.Text.UTF8Encoding]::new($false)
$content = [System.IO.File]::ReadAllText($src, $utf8NoBom)
$updated = Apply-Replacements -Content $content -Map $replaceMap
[System.IO.File]::WriteAllText($dest, $updated, $utf8NoBom)
```

Avoid `Get-Content` / `Set-Content` or other default-encoding text paths unless you have explicitly verified they preserve UTF-8 correctly for BOM-less templates.

Preserve the template's BOM policy by default. If the source template is UTF-8 without BOM, write UTF-8 without BOM unless the target file format or tool explicitly requires a BOM.

Exception: generate `testenvironments.json` instead of copying it verbatim. Always include the `WSL-Ubuntu` entry, then add one `Docker-Ubuntu` entry per selected target framework using the Docker image tag `codebeltnet/ubuntu-testrunner:{major}` where `{major}` comes from the TFM.

Exception: do not leave `Directory.Packages.props` with unresolved placeholder tokens. Resolve each package version placeholder to the latest stable listed NuGet.org version for that exact package ID before writing the file.

Before finalizing the Docker entries, validate that each generated tag exists in the Docker Hub tags feed for `codebeltnet/ubuntu-testrunner`. Prefer the machine-readable tags API over manual inspection:

- `https://hub.docker.com/v2/repositories/codebeltnet/ubuntu-testrunner/tags?page_size=100`

Examples:

- `net10.0` → `codebeltnet/ubuntu-testrunner:10`
- `net10.0;net9.0;net8.0` → three Docker entries with tags `10`, `9`, and `8`

### 2. Copy library `Directory.Build.props`
Copy `assets/library/Directory.Build.props` to the project root, applying placeholder substitution.

### 3. Copy DocFX templates
Copy `assets/library/.docfx/` to the project root, applying placeholder substitution. DocFX generates API reference documentation for NuGet packages.

Use `{PROJECT_NAME}` for the DocFX source project glob and `{DOCFX_TARGET_FRAMEWORK}` for metadata generation so the generated docs track the actual scaffolded project name and runtime instead of a hardcoded example.

### 4. Generate library-specific files
Follow the variant guide (Step 2) for the remaining files: project structure, `.csproj` files, tuning benchmark projects under `tuning/`, the solution-level benchmark runner under `tooling/`, `.nuget/{ProjectName}/` metadata folders (per packable project), and the `.slnx` solution file.

For the default single-project case, use `solution_name` as `{PROJECT_NAME}` everywhere. Only branch into multiple `{PROJECT_NAME}` values when the user explicitly wants multiple library packages in the same solution.

Generate benchmarking in two layers:

- Benchmark project: `tuning/{PROJECT_NAME}.Benchmarks/{PROJECT_NAME}.Benchmarks.csproj`
- Benchmark runner host: `tooling/{BENCHMARK_RUNNER_PROJECT_NAME}/{BENCHMARK_RUNNER_PROJECT_NAME}.csproj`
- Runner entry point: `tooling/{BENCHMARK_RUNNER_PROJECT_NAME}/Program.cs`
- Reports/output folder: `reports/`

The tuning benchmark project holds the actual benchmark types and references the source project. The tooling benchmark runner invokes those tuning projects.

`Program.cs` in the benchmark runner must call `BenchmarkProgram.Run(...)` and add one benchmark job per selected executable TFM from `target_frameworks`. Examples:

- `net48` → `.AddJob(slimJob.WithRuntime(ClrRuntime.Net48))`
- `net9.0` → `.AddJob(slimJob.WithRuntime(CoreRuntime.Core90))`
- `net10.0` → `.AddJob(slimJob.WithRuntime(CoreRuntime.Core10_0))`

Skip non-executable TFMs such as `netstandard*` when building the benchmark job list. If no executable runtime remains, note that the benchmark runner needs a manual runtime decision before it can be used.

Set the benchmark runner project `TargetFramework` to the highest selected generally supported non-preview executable TFM from `target_frameworks`. This keeps the runner aligned with the newest runtime the user chose, whether that supported track is LTS or STS.

## Step 6: Post-Generation Checklist

After generating, verify:

- [ ] `.slnx` references all generated src/, test/, tuning/, and tooling/ projects
- [ ] `Directory.Build.props` references the correct `.snk` filename
- [ ] Each packable project has a `.nuget/{ProjectName}/` folder with `PackageReleaseNotes.txt`, `icon.png` (placeholder), and `README.md`
- [ ] `Directory.Packages.props` lists all `<PackageReference>` packages used in the solution
- [ ] `Directory.Packages.props` contains concrete version numbers with no unresolved `*_VERSION` placeholders
- [ ] Every `Directory.Packages.props` version was resolved from the latest stable listed NuGet.org package version at generation time
- [ ] `tuning/{PROJECT_NAME}.Benchmarks/{PROJECT_NAME}.Benchmarks.csproj` references the main source project and relies on central package management
- [ ] `tooling/{BENCHMARK_RUNNER_PROJECT_NAME}/Program.cs` contains one runtime job per selected executable TFM
- [ ] `tooling/{BENCHMARK_RUNNER_PROJECT_NAME}/{BENCHMARK_RUNNER_PROJECT_NAME}.csproj` references the default tuning benchmark project and relies on central package management
- [ ] `ci-pipeline.yml` has the correct SNK and SonarCloud settings
- [ ] Root governance docs exist: `README.md`, `CHANGELOG.md`, `LICENSE`, `.github/CODE_OF_CONDUCT.md`, `.github/CONTRIBUTING.md`
- [ ] `.docfx/docfx.json` lists all source projects and has correct metadata
- [ ] `.editorconfig` is present, sets `charset = utf-8`, and keeps file-scoped namespace enforcement
- [ ] Generated text files do not contain common mojibake markers such as `â€”`, `â€“`, `â€`, or `�`
- [ ] `AGENTS.md` references `.bot/` and coding guidelines
- [ ] `.github/copilot-instructions.md` has project-specific patterns
- [ ] `.bot/` folder exists and is listed in `.gitignore`
- [ ] `.bot/README.md` exists in the generated repo and came from the shared asset template, not from a synthetic `.gitkeep` fallback
- [ ] Every file listed in `assets/shared.manifest.json` exists in the generated repo at its declared relative path (this covers all dotfiles and dotfolders)
- [ ] If any manifest entry was absent from the installed skill copy, `pwsh -NoProfile -File "<skill-root>/scripts/restore-missing-shared-assets.ps1"` was run (or files were fetched manually from the upstream raw URL) — not diagnosed iteratively
- [ ] No manifest entries were silently skipped; if the restore script reported failures, generation was halted rather than continuing with incomplete shared assets
- [ ] `.github/dependabot.yml` watches the repo root so central NuGet package management stays current after scaffolding

Summarize what was generated and note any manual steps (e.g. registering with SonarCloud, populating `.docfx/images/` with logo/favicon).

## Step 7: Generate Strong Name Key

After scaffolding is complete, invoke the `dotnet-strong-name-signing` skill to generate the `.snk` file. The skill will default the key name to the repository folder name and place it at the repo root — which is exactly where `Directory.Build.props` expects it via `{SNK_FILE}`.
