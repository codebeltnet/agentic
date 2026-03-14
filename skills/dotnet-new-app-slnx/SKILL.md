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

Read `FORMS.md` and collect all parameters by presenting each field to the user one at a time using the agent's native input mechanism. Follow the presentation rules defined in the form. Do not proceed to Step 2 until all required fields are collected and the user confirms the summary.

## Step 2: Load the Variant Guide

Read `references/app.md` for the app-specific project structure, template file mapping, hosting patterns (Startup vs Minimal), `.slnx` format, and per-host-type NuGet packages.

## Step 3: Apply the Substitution Map

When copying template files, replace these placeholders in file contents:

| Placeholder | Value |
|-------------|-------|
| `{SOLUTION_NAME}` | Solution name (e.g. `PaymentService`) |
| `{ROOT_NAMESPACE}` | Root namespace prefix (e.g. `Acme`) |
| `{REPO_SLUG}` | Derived from solution name (lowercased, e.g. `PaymentService` → `paymentservice`) |
| `{TARGET_FRAMEWORK}` | e.g. `net10.0` (single target) |

## Step 4: Generate All Files

Generate files in this order:

### 1. Copy shared templates
Copy every file from `templates/shared/` to the project root, preserving directory structure. Apply placeholder substitution (Step 3) to all file contents during the copy.

### 2. Copy app `Directory.Build.props`
Copy `templates/app/Directory.Build.props` to the project root, applying placeholder substitution.

### 3. Copy app CI pipeline
Overwrite the shared CI pipeline with `templates/app/.github/workflows/ci-pipeline.yml`. Apps have a simplified pipeline (build + test only).

### 4. Generate app-specific files
Follow the variant guide (Step 2) for the remaining files: project structure per host type, `.csproj` files, `Program.cs` (and `Startup.cs` if startup pattern), functional test projects, and the `.slnx` solution file.

## Step 5: Post-Generation Checklist

After generating, verify:

- [ ] `.slnx` references all generated src/ and test/ projects
- [ ] `Directory.Packages.props` lists all `<PackageReference>` packages used in the solution (including host-type-specific packages)
- [ ] `ci-pipeline.yml` has the correct settings (build + test only)
- [ ] Root governance docs exist: `README.md`, `CHANGELOG.md`, `.github/CODE_OF_CONDUCT.md`, `.github/CONTRIBUTING.md`
- [ ] `.editorconfig` is present with file-scoped namespace enforcement
- [ ] `AGENTS.md` references `.bot/` and coding guidelines
- [ ] `.github/copilot-instructions.md` has project-specific patterns
- [ ] `.bot/` folder exists and is listed in `.gitignore`
- [ ] Correct hosting pattern files generated (`Program.cs` only for Minimal, `Program.cs` + `Startup.cs` for Startup)

Summarize what was generated and note any manual steps.
