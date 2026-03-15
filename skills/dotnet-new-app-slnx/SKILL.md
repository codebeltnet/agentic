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

> **CRITICAL:** All application projects **must** use the `Codebelt.Bootstrapper.*` framework — never vanilla `WebApplication.CreateBuilder()` or raw `Host.CreateDefaultBuilder()`. The bootstrapper provides a uniform, convention-driven `Program.cs` (and `Startup.cs` for classic hosting). The asset templates in `assets/app/` already wire this up correctly — **always copy from templates, never write Program.cs from scratch**.

## Scope

This skill produces a **complete solution scaffold** — project structure, build config, CI pipeline, governance docs, and bootstrapper-wired entry points. It does **not** generate application logic (endpoints, services, controllers, middleware). The scaffold is the foundation; the user adds their code on top.

**When to use this skill:** The user wants a properly structured .NET solution from scratch — with conventions, CI, and tooling baked in from day one.

**When NOT to use this skill:** The user wants a quick, throwaway backend or a thin adapter layer. If the request is for a minimal placeholder (e.g. "just a basic API proxy"), do not invoke this skill — use standard .NET CLI tooling instead (`dotnet new web`) and let the user decide if they want to upgrade to a full scaffold later.

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
Copy every file from `assets/shared/` to the project root, preserving directory structure. Apply placeholder substitution (Step 3) to all file contents during the copy.

### 2. Copy app `Directory.Build.props`
Copy `assets/app/Directory.Build.props` to the project root, applying placeholder substitution.

### 3. Copy app CI pipeline
Overwrite the shared CI pipeline with `assets/app/.github/workflows/ci-pipeline.yml`. Apps have a simplified pipeline (build + test only).

### 4. Generate app-specific files
Follow the variant guide (Step 2) for the remaining files. **Do not write these files from scratch** — use the asset templates in `assets/app/` as the source of truth:

- **`.csproj` files** → copy from `assets/app/{type}.csproj` (already includes `Codebelt.Bootstrapper.*` package reference)
- **`Program.cs`** → copy from `assets/app/{type}/Program.minimal.cs` (Minimal pattern) or `assets/app/{type}/Program.startup.cs` (Startup pattern)
- **`Startup.cs`** → copy from `assets/app/{type}/Startup.cs` (Startup pattern only)
- **Test `.csproj`** → copy from `assets/app/test.csproj`

Apply placeholder substitution (Step 3) to all copied files. The user's business logic, endpoints, and service registrations go into `Startup.cs` (Startup pattern) or the `Program.cs` configure methods (Minimal pattern) — but the bootstrapper base classes must remain intact.

Generate the `.slnx` solution file and functional test project structure per the variant guide.

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
