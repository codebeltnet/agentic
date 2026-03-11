---
name: dotnet-solution-setup
description: >
  Scaffold a new .NET solution following codebelt engineering conventions.
  Use this skill when the user wants to create a new dotnet solution, start a new C# project,
  scaffold a NuGet library, or set up a new .NET application.
  Also use when the user mentions "codebelt conventions", "codebeltnet style",
  "new dotnet project", "scaffold .NET", "new NuGet package", "new library project",
  or wants a consistent .NET project structure with CI/CD, versioning, and quality tooling.
  ALWAYS use this skill when asked to scaffold, initialize, or create a new .NET solution.
---

# .NET Solution Setup (Codebelt Conventions)

Scaffold new .NET solutions following the codebeltnet engineering conventions — the same pattern used across [codebeltnet](https://github.com/codebeltnet). Produces a fully wired solution with CI pipeline, centralized build config, semantic versioning, code quality tooling, and proper folder structure.

## Step 1: Collect Parameters

Ask the user for all parameters before generating anything. Present them as a structured list and wait for all answers:

| Parameter | Prompt | Default / Notes |
|-----------|--------|-----------------|
| **Solution name** | "Solution/product name? (e.g. `MyLibrary`, `PaymentService`)" | Required |
| **Root namespace** | "Root namespace prefix? (e.g. `Acme`, `MyCompany`)" | Defaults to solution name |
| **Solution type** | See **Solution Types** below | Required |
| **Author** | "Author name (for NuGet metadata and git)?" | Required |
| **Company** | "Company name (for copyright and NuGet metadata)?" | Required |
| **Copyright year** | "Copyright year?" | Current year (from system time) |
| **Package URL** | "Product/documentation URL?" | `https://github.com/{owner}/{repo}` |
| **Repository URL** | "GitHub repository URL?" | Required |
| **Target frameworks** | "Target frameworks? (semicolon-separated)" | `net10.0;net9.0` |
| **Strong-name signing** | "Enable assembly signing (.snk)? Signing requires committing a key file." | `yes` |
| **SonarCloud org** | "SonarCloud organization slug? (skip if not using SonarCloud)" | Optional |
| **SonarCloud key** | "SonarCloud project key?" | Optional |

### Solution Types

After collecting the base parameters, ask: **"What type of solution are you creating?"**

1. **NuGet Library** — One or more reusable components published as NuGet packages.
   - Additionally ask: project names (e.g. `{Namespace}`, `{Namespace}.Extensions.Logging`)
   - Structure: `src/` + `test/` + `tuning/` + `tooling/` + `.nuget/` metadata per packable project

2. **Standalone Application** — A runnable app, not published as NuGet.
   - Additionally ask: app host type(s) — `Console`, `Web API`, `Worker` (can be multiple)
   - **You MUST ask**: "Hosting pattern: **Startup** (aka Classic Hosting — Program.cs + Startup.cs) or **Minimal** (aka Minimal Hosting — Program.cs only)?" Default: **Minimal**. Do not assume — always ask this explicitly.
   - Structure: `src/` + `test/` with host projects

## Step 2: Load the Variant Guide

Based on the solution type, read the corresponding slim reference file for project structure and logic:

- **NuGet Library** → Read `references/library.md`
- **Standalone Application** → Read `references/app.md`

These guides describe the variant-specific folder layout, which `.csproj` templates to use, conditional files (e.g. `Program.cs`, `Startup.cs`), and the `.slnx` structure (generated inline — too dynamic for a static template).

## Step 3: Apply the Substitution Map

When copying template files, replace these placeholders in file contents:

| Placeholder | Value |
|-------------|-------|
| `{SOLUTION_NAME}` | Solution name (e.g. `MyLibrary`) |
| `{ROOT_NAMESPACE}` | Root namespace prefix (e.g. `Acme`) |
| `{AUTHOR}` | Author name |
| `{COMPANY}` | Company name |
| `{COPYRIGHT_YEAR}` | Copyright year (e.g. `2026`) |
| `{PACKAGE_URL}` | Product/docs URL |
| `{REPOSITORY_URL}` | Full GitHub URL |
| `{REPO_OWNER}` | GitHub org/user (from URL) |
| `{REPO_SLUG}` | Repo name (last URL segment, lowercased) |
| `{TARGET_FRAMEWORKS}` | e.g. `net10.0;net9.0` (libraries — multi-target) |
| `{TARGET_FRAMEWORK}` | e.g. `net10.0` (apps — single target) |
| `{SNK_FILE}` | e.g. `{repo-slug}.snk` |
| `{SONARCLOUD_ORG}` | SonarCloud org slug (or omit job if skipped) |
| `{SONARCLOUD_KEY}` | SonarCloud project key |

## Step 4: Generate All Files

Generate files in this order:

### 1. Copy shared templates
Copy every file from `templates/shared/` to the project root, preserving directory structure. Apply placeholder substitution (Step 3) to all file contents during the copy.

### 2. Copy variant `Directory.Build.props`
Copy `Directory.Build.props` from the variant-specific template folder, applying placeholder substitution:
- **NuGet Library** → `templates/library/Directory.Build.props`
- **Standalone Application** → `templates/app/Directory.Build.props`

### 3. Copy DocFX templates (NuGet Library only)
If the solution type is **NuGet Library**, also copy `templates/library/.docfx/` to the project root. DocFX generates API reference documentation for NuGet packages — standalone apps don't need it.

### 4. Copy variant CI pipeline (Standalone Application only)
For **Standalone Application**, overwrite the shared CI pipeline with `templates/app/.github/workflows/ci-pipeline.yml`. Apps have a simplified pipeline (build + test only, no pack/deploy/codecov/codeql/GCP secrets). SonarCloud is commented out — uncomment if needed. Also remove `.github/codecov.yml`.

### 5. Generate variant-specific files
Follow the variant guide (Step 2) for the remaining files: project structure, `.csproj` files, conditional files (`Program.cs`, `Startup.cs`), `.nuget/` metadata folders, and the `.slnx` solution file.

## Step 5: Post-Generation Checklist

After generating, verify:

- [ ] `.slnx` references all generated src/ and test/ projects
- [ ] `Directory.Build.props` references the correct `.snk` filename
- [ ] Each packable project has a `.nuget/{ProjectName}/` folder with `PackageReleaseNotes.txt`, `icon.png` (placeholder), and `README.md`
- [ ] `Directory.Packages.props` lists all `<PackageReference>` packages used in the solution
- [ ] `ci-pipeline.yml` has the correct settings *(library: SNK, SonarCloud keys; apps: build + test only)*
- [ ] Root governance docs exist: `README.md`, `CHANGELOG.md`, `LICENSE`, `.github/CODE_OF_CONDUCT.md`, `.github/CONTRIBUTING.md`
- [ ] `.docfx/docfx.json` lists all source projects and has correct metadata *(NuGet Library only)*
- [ ] `.editorconfig` is present with file-scoped namespace enforcement
- [ ] `AGENTS.md` references `.bot/` and coding guidelines
- [ ] `.github/copilot-instructions.md` has project-specific patterns
- [ ] `.bot/` folder exists and is listed in `.gitignore`

Summarize what was generated and note any manual steps (e.g. creating the `.snk` file, registering with SonarCloud, populating `.docfx/images/` with logo/favicon).
