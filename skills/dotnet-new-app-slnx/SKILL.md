---
name: dotnet-new-app-slnx
description: >
  Scaffold a new .NET standalone application solution following codebelt engineering conventions.
  Use this skill when the user wants to create a new .NET application — Console, Web API,
  or Worker service. Also use when the user mentions "new app", "new console app",
  "new web api", "new worker service", "scaffold app", "dotnet new web", "dotnet new worker",
  "dotnet new console", or wants a .NET application project with CI/CD pipeline,
  functional tests, and code quality tooling.
  ALWAYS use this skill when asked to scaffold or create a new .NET application solution.
---

# .NET Application Solution Setup (Codebelt Conventions)

Scaffold new .NET standalone application solutions following the codebeltnet engineering conventions — the same pattern used across [codebeltnet](https://github.com/codebeltnet). Produces a fully wired solution with CI pipeline, centralized build config, semantic versioning, code quality tooling, and proper folder structure.

## Step 1: Collect Parameters

Ask the user for all parameters before generating anything. Present them as a structured list and wait for all answers:

| Parameter | Prompt | Default / Notes |
|-----------|--------|-----------------|
| **Solution name** | "Solution/product name? (e.g. `PaymentService`)" | Required |
| **Root namespace** | "Root namespace prefix? (e.g. `Acme`, `MyCompany`)" | Defaults to solution name |
| **App host type(s)** | "App host type(s)? (`Console`, `Web API`, `Worker` — can be multiple)" | At least one required |
| **Hosting pattern** | "Hosting pattern: **Startup** (aka Classic Hosting — Program.cs + Startup.cs) or **Minimal** (aka Minimal Hosting — Program.cs only)?" | Default: **Minimal**. Do not assume — always ask this explicitly. |
| **Author** | "Author name (for git)?" | Required |
| **Company** | "Company name (for copyright)?" | Required |
| **Copyright year** | "Copyright year?" | Current year (from system time) |
| **Package URL** | "Product/documentation URL?" | `https://github.com/{owner}/{repo}` |
| **Repository URL** | "GitHub repository URL?" | Required |
| **SonarCloud org** | "SonarCloud organization slug? (skip if not using SonarCloud)" | Optional |
| **SonarCloud key** | "SonarCloud project key?" | Optional |

## Step 2: Load the Variant Guide

Read `references/app.md` for the app-specific project structure, template file mapping, hosting patterns (Startup vs Minimal), `.slnx` format, and per-host-type NuGet packages.

## Step 3: Apply the Substitution Map

When copying template files, replace these placeholders in file contents:

| Placeholder | Value |
|-------------|-------|
| `{SOLUTION_NAME}` | Solution name (e.g. `PaymentService`) |
| `{ROOT_NAMESPACE}` | Root namespace prefix (e.g. `Acme`) |
| `{AUTHOR}` | Author name |
| `{COMPANY}` | Company name |
| `{COPYRIGHT_YEAR}` | Copyright year (e.g. `2026`) |
| `{PACKAGE_URL}` | Product/docs URL |
| `{REPOSITORY_URL}` | Full GitHub URL |
| `{REPO_OWNER}` | GitHub org/user (from URL) |
| `{REPO_SLUG}` | Repo name (last URL segment, lowercased) |
| `{TARGET_FRAMEWORK}` | e.g. `net10.0` (single target) |
| `{SONARCLOUD_ORG}` | SonarCloud org slug (or omit job if skipped) |
| `{SONARCLOUD_KEY}` | SonarCloud project key |

## Step 4: Generate All Files

Generate files in this order:

### 1. Copy shared templates
Copy every file from `templates/shared/` to the project root, preserving directory structure. Apply placeholder substitution (Step 3) to all file contents during the copy.

### 2. Copy app `Directory.Build.props`
Copy `templates/app/Directory.Build.props` to the project root, applying placeholder substitution.

### 3. Copy app CI pipeline
Overwrite the shared CI pipeline with `templates/app/.github/workflows/ci-pipeline.yml`. Apps have a simplified pipeline (build + test only, no pack/deploy/codecov/codeql). SonarCloud is commented out — uncomment if needed.

### 4. Generate app-specific files
Follow the variant guide (Step 2) for the remaining files: project structure per host type, `.csproj` files, `Program.cs` (and `Startup.cs` if startup pattern), functional test projects, and the `.slnx` solution file.

## Step 5: Post-Generation Checklist

After generating, verify:

- [ ] `.slnx` references all generated src/ and test/ projects
- [ ] `Directory.Packages.props` lists all `<PackageReference>` packages used in the solution (including host-type-specific packages)
- [ ] `ci-pipeline.yml` has the correct settings (build + test only)
- [ ] Root governance docs exist: `README.md`, `CHANGELOG.md`, `LICENSE`, `.github/CODE_OF_CONDUCT.md`, `.github/CONTRIBUTING.md`
- [ ] `.editorconfig` is present with file-scoped namespace enforcement
- [ ] `AGENTS.md` references `.bot/` and coding guidelines
- [ ] `.github/copilot-instructions.md` has project-specific patterns
- [ ] `.bot/` folder exists and is listed in `.gitignore`
- [ ] Correct hosting pattern files generated (`Program.cs` only for Minimal, `Program.cs` + `Startup.cs` for Startup)

Summarize what was generated and note any manual steps (e.g. registering with SonarCloud).
