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

Ask the user for all parameters before generating anything. Present them as a structured list and wait for all answers:

| Parameter | Prompt | Default / Notes |
|-----------|--------|-----------------|
| **Solution name** | "Solution/product name? (e.g. `MyLibrary`)" | Required |
| **Root namespace** | "Root namespace prefix? (e.g. `Acme`, `MyCompany`)" | Defaults to solution name |
| **Project names** | "Library project name(s)? (e.g. `{Namespace}`, `{Namespace}.Extensions.Logging`)" | At least one required |
| **Author** | "Author name (for NuGet metadata and git)?" | Required |
| **Company** | "Company name (for copyright and NuGet metadata)?" | Required |
| **Copyright year** | "Copyright year?" | Current year (from system time) |
| **Package URL** | "Product/documentation URL?" | `https://github.com/{owner}/{repo}` |
| **Repository URL** | "GitHub repository URL?" | Required |
| **Target frameworks** | "Target frameworks? (semicolon-separated)" | `net10.0;net9.0` |
| **Strong-name signing** | "Enable assembly signing (.snk)? Signing requires committing a key file." | `yes` |
| **SonarCloud org** | "SonarCloud organization slug? (skip if not using SonarCloud)" | Optional |
| **SonarCloud key** | "SonarCloud project key?" | Optional |

## Step 2: Load the Variant Guide

Read `references/library.md` for the library-specific project structure, template file mapping, `.slnx` format, multi-project guidance, and project reference conventions.

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
| `{TARGET_FRAMEWORKS}` | e.g. `net10.0;net9.0` (multi-target) |
| `{SNK_FILE}` | e.g. `{repo-slug}.snk` |
| `{SONARCLOUD_ORG}` | SonarCloud org slug (or omit job if skipped) |
| `{SONARCLOUD_KEY}` | SonarCloud project key |

## Step 4: Generate All Files

Generate files in this order:

### 1. Copy shared templates
Copy every file from `templates/shared/` to the project root, preserving directory structure. Apply placeholder substitution (Step 3) to all file contents during the copy.

### 2. Copy library `Directory.Build.props`
Copy `templates/library/Directory.Build.props` to the project root, applying placeholder substitution.

### 3. Copy DocFX templates
Copy `templates/library/.docfx/` to the project root, applying placeholder substitution. DocFX generates API reference documentation for NuGet packages.

### 4. Generate library-specific files
Follow the variant guide (Step 2) for the remaining files: project structure, `.csproj` files, `.nuget/{ProjectName}/` metadata folders (per packable project), and the `.slnx` solution file.

## Step 5: Post-Generation Checklist

After generating, verify:

- [ ] `.slnx` references all generated src/, test/, and tuning/ projects
- [ ] `Directory.Build.props` references the correct `.snk` filename
- [ ] Each packable project has a `.nuget/{ProjectName}/` folder with `PackageReleaseNotes.txt`, `icon.png` (placeholder), and `README.md`
- [ ] `Directory.Packages.props` lists all `<PackageReference>` packages used in the solution
- [ ] `ci-pipeline.yml` has the correct SNK and SonarCloud settings
- [ ] Root governance docs exist: `README.md`, `CHANGELOG.md`, `LICENSE`, `.github/CODE_OF_CONDUCT.md`, `.github/CONTRIBUTING.md`
- [ ] `.docfx/docfx.json` lists all source projects and has correct metadata
- [ ] `.editorconfig` is present with file-scoped namespace enforcement
- [ ] `AGENTS.md` references `.bot/` and coding guidelines
- [ ] `.github/copilot-instructions.md` has project-specific patterns
- [ ] `.bot/` folder exists and is listed in `.gitignore`

Summarize what was generated and note any manual steps (e.g. creating the `.snk` file, registering with SonarCloud, populating `.docfx/images/` with logo/favicon).
