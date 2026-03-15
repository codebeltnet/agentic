---
name: dotnet-new-lib-slnx
description: >
  Scaffold a new .NET NuGet library solution following codebelt engineering conventions.
  Use this skill when the user wants to create a new NuGet library, class library, or
  reusable .NET package. Also use when the user mentions "new library", "new NuGet package",
  "scaffold library", "class library solution", "dotnet new classlib", or wants a .NET
  library project with multi-target frameworks, strong-name signing, NuGet packaging,
  DocFX documentation, CI/CD pipeline, and code quality tooling.
  ALWAYS use this skill when asked to scaffold or create a new .NET library solution.
---

# .NET Library Solution Setup (Codebelt Conventions)

Scaffold new .NET NuGet library solutions following the codebeltnet engineering conventions — the same pattern used across [codebeltnet](https://github.com/codebeltnet). Produces a fully wired solution with multi-target framework support, strong-name signing, NuGet packaging, DocFX documentation, CI pipeline, centralized build config, semantic versioning, and code quality tooling.

## Step 1: Collect Parameters

Read `FORMS.md` and collect all parameters by presenting each field to the user one at a time using the agent's native input mechanism. Follow the presentation rules defined in the form. Do not proceed to Step 2 until all required fields are collected and the user confirms the summary.

Assume the default shape is a single packable library project whose project name matches `solution_name`. Do not ask for separate library project names unless the user explicitly asks for a multi-project solution or names additional packages/modules.

Collect `repository_url` before `package_project_url` so the package website field can present the repository URL as the recommended default and let the user either accept it or replace it with a dedicated site/docs URL.

Default `target_frameworks` to the newest generally supported .NET LTS for new libraries by reading `https://raw.githubusercontent.com/dotnet/core/refs/heads/main/release-notes/releases-index.json`. Filter to `.NET` entries whose `support-phase` is `active` or `maintenance`, then choose the highest LTS channel and format it as `net{major}.0`. Exclude preview channels. Only suggest multiple TFMs when the user explicitly asks for compatibility across older runtimes or there is a clear support requirement.

When presenting `target_frameworks`, compute two presets from that same releases index before free text:

- Recommended: newest generally supported LTS only
- Expanded scope: all generally supported `.NET` channels, newest to oldest, excluding preview channels

## Step 2: Load the Variant Guide

Read `references/library.md` for the library-specific project structure, template file mapping, `.slnx` format, multi-project guidance, and project reference conventions.

## Step 3: Resolve Dynamic Dependency Versions

Before writing `Directory.Packages.props`, resolve every `*_VERSION` placeholder in that file to the latest stable listed version for its matching package ID on NuGet.org.

- Use the NuGet V3 service index at `https://api.nuget.org/v3/index.json` to discover the package metadata endpoints
- Prefer registration metadata so you can ignore unlisted versions and prerelease builds
- If registration metadata is unavailable, fall back to the package base address versions list from the same service index and still exclude prerelease versions
- Resolve each package independently by package ID; never reuse one generic "latest" value across multiple packages
- Never hardcode version numbers from stale examples, screenshots, or prior scaffolds

## Step 4: Apply the Substitution Map

When copying template files, replace these placeholders in file contents:

| Placeholder | Value |
|-------------|-------|
| `{SOLUTION_NAME}` | Solution name (e.g. `MyLibrary`) |
| `{ROOT_NAMESPACE}` | Root namespace prefix (e.g. `Acme`) |
| `{AUTHOR}` | Author name |
| `{AUTHOR_EMAIL}` | Author email |
| `{COMPANY_OR_PERSON}` | Company name or individual publisher name for copyright/NuGet metadata |
| `{COPYRIGHT_YEAR}` | Copyright year (e.g. `2026`) |
| `{PACKAGE_PROJECT_URL}` | Public package website or docs URL shown as `Project website` on NuGet |
| `{REPOSITORY_URL}` | Source repository URL shown as `Source repository` on NuGet |
| `{REPO_OWNER}` | GitHub org/user (from URL) |
| `{REPO_SLUG}` | Repo name (last URL segment, lowercased) |
| `{TARGET_FRAMEWORKS}` | Computed from the official .NET releases index; default to newest generally supported LTS, or use all generally supported non-preview channels for broader scope |
| `{SNK_FILE}` | e.g. `{repo-slug}.snk` |
| `{SONARCLOUD_ORG}` | SonarCloud org slug (or omit job if skipped) |
| `{SONARCLOUD_KEY}` | SonarCloud project key |

`Directory.Packages.props` also contains package-specific placeholders such as `{BENCHMARKDOTNET_VERSION}` and `{MICROSOFT_NET_TEST_SDK_VERSION}`. Resolve each of them from NuGet.org in Step 3 before writing the final file.

## Step 5: Generate All Files

Generate files in this order:

### 1. Copy shared templates
Copy every file from `assets/shared/` to the project root, preserving directory structure. Apply placeholder substitution (Step 4) to all file contents during the copy.

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

### 4. Generate library-specific files
Follow the variant guide (Step 2) for the remaining files: project structure, `.csproj` files, `.nuget/{ProjectName}/` metadata folders (per packable project), and the `.slnx` solution file.

For the default single-project case, use `solution_name` as `{PROJECT_NAME}` everywhere. Only branch into multiple `{PROJECT_NAME}` values when the user explicitly wants multiple library packages in the same solution.

## Step 6: Post-Generation Checklist

After generating, verify:

- [ ] `.slnx` references all generated src/, test/, and tuning/ projects
- [ ] `Directory.Build.props` references the correct `.snk` filename
- [ ] Each packable project has a `.nuget/{ProjectName}/` folder with `PackageReleaseNotes.txt`, `icon.png` (placeholder), and `README.md`
- [ ] `Directory.Packages.props` lists all `<PackageReference>` packages used in the solution
- [ ] `Directory.Packages.props` contains concrete version numbers with no unresolved `*_VERSION` placeholders
- [ ] Every `Directory.Packages.props` version was resolved from the latest stable listed NuGet.org package version at generation time
- [ ] `ci-pipeline.yml` has the correct SNK and SonarCloud settings
- [ ] Root governance docs exist: `README.md`, `CHANGELOG.md`, `LICENSE`, `.github/CODE_OF_CONDUCT.md`, `.github/CONTRIBUTING.md`
- [ ] `.docfx/docfx.json` lists all source projects and has correct metadata
- [ ] `.editorconfig` is present with file-scoped namespace enforcement
- [ ] `AGENTS.md` references `.bot/` and coding guidelines
- [ ] `.github/copilot-instructions.md` has project-specific patterns
- [ ] `.bot/` folder exists and is listed in `.gitignore`
- [ ] `.github/dependabot.yml` watches the repo root so central NuGet package management stays current after scaffolding

Summarize what was generated and note any manual steps (e.g. registering with SonarCloud, populating `.docfx/images/` with logo/favicon).

## Step 7: Generate Strong Name Key

After scaffolding is complete, invoke the `dotnet-strong-name-signing` skill to generate the `.snk` file. The skill will default the key name to the repository folder name and place it at the repo root — which is exactly where `Directory.Build.props` expects it via `{SNK_FILE}`.
