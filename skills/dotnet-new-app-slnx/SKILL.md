---
name: dotnet-new-app-slnx
description: >
  Scaffold a new .NET standalone application solution following codebelt engineering conventions.
  Use this skill when the user wants to create a new .NET application — Console, Web,
  or Worker service. Also use when the user mentions "new app", "new console app",
  "new web api", "new mvc app", "new razor app", "new web app", "new worker service",
  "scaffold app", "dotnet new web", "dotnet new webapi", "dotnet new mvc",
  "dotnet new webapp", "dotnet new worker", "dotnet new console", or wants a .NET
  application project with CI/CD pipeline, functional tests, and code quality tooling.
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

Treat `Web` as the host family. When `Web` is selected, collect exactly one `web_variant`. If the user already said `web api`, `mvc`, `razor`, or `web app`, preselect the matching `web_variant` instead of asking them to repeat it.

For each selected host type, derive `{AppType}` as follows:

- `Console` host type → `{AppType} = Console`
- `Web` + `Empty Web` → `{AppType} = Web`
- `Web` + `Web API` → `{AppType} = Api`
- `Web` + `MVC` → `{AppType} = Mvc`
- `Web` + `Web App / Razor` → `{AppType} = WebApp`
- `Worker` host type → `{AppType} = Worker`

Use only one web-family variant per scaffold run. The solution may still include `Console` and/or `Worker` alongside that one web-family project.

## Step 2: Load the Variant Guide

Read `references/app.md` for the app-specific project structure, template file mapping, hosting patterns (Startup vs Minimal), `.slnx` format, and per-host-type NuGet packages.

## Step 3: Resolve Dynamic Dependency Versions

Before writing `Directory.Packages.props`, resolve every `*_VERSION` placeholder in that file to the latest stable listed version for its matching package ID on NuGet.org.

- Use the NuGet V3 service index at `https://api.nuget.org/v3/index.json` to discover the package metadata endpoints
- Prefer registration metadata so you can ignore unlisted versions and prerelease builds
- If registration metadata is unavailable, fall back to the package base address versions list from the same service index and still exclude prerelease versions
- Resolve each package independently by package ID; never reuse one generic "latest" value across multiple packages
- Never hardcode version numbers from stale examples, screenshots, or prior scaffolds

This includes shared and host-specific app packages such as:

- `Codebelt.Extensions.Xunit.App`
- `Microsoft.NET.Test.Sdk`
- `MinVer`
- `coverlet.collector`
- `coverlet.msbuild`
- `xunit.v3`
- `xunit.v3.runner.console`
- `xunit.runner.visualstudio`
- `BenchmarkDotNet`
- `Codebelt.Bootstrapper.Console`
- `Codebelt.Bootstrapper.Web`
- `Codebelt.Bootstrapper.Worker`
- `Codebelt.SharedKernel`
- `Microsoft.AspNetCore.OpenApi`
- `Microsoft.AspNetCore.Mvc.Razor.RuntimeCompilation`
- `Microsoft.Extensions.Hosting`

## Step 4: Apply the Substitution Map

When copying template files, replace these placeholders in file contents:

| Placeholder | Value |
|-------------|-------|
| `{SOLUTION_NAME}` | Solution name (e.g. `PaymentService`) |
| `{ROOT_NAMESPACE}` | Root namespace prefix (e.g. `Acme`) |
| `{REPO_SLUG}` | Derived from solution name (lowercased, e.g. `PaymentService` → `paymentservice`) |
| `{TARGET_FRAMEWORK}` | e.g. `net10.0` (single target) |
| `{AppType}` | Per-host-type output suffix: `Console`, `Web`, `Api`, `Mvc`, `WebApp`, or `Worker` |
| `{UBUNTU_TESTRUNNER_TAG}` | Docker runner image tag derived from `{TARGET_FRAMEWORK}`, e.g. `codebeltnet/ubuntu-testrunner:10` |

`Directory.Packages.props` also contains package-specific placeholders such as `{CODEBELT_BOOTSTRAPPER_WEB_VERSION}`, `{MICROSOFT_ASPNETCORE_OPENAPI_VERSION}`, `{MICROSOFT_ASPNETCORE_MVC_RAZOR_RUNTIMECOMPILATION_VERSION}`, `{MICROSOFT_EXTENSIONS_HOSTING_VERSION}`, and `{MICROSOFT_NET_TEST_SDK_VERSION}`. Resolve each of them from NuGet.org in Step 3 before writing the final file.

## Step 5: Generate All Files

Generate files in this order:

### 1. Copy shared templates
Copy every file from `assets/shared/` to the project root, preserving directory structure. Apply placeholder substitution (Step 4) to all file contents during the copy.

Do this as a recursive, dotfile-aware copy. Hidden folders and files under `assets/shared/` are part of the scaffold and must not be skipped. In particular, copy `assets/shared/.bot/README.md` as a real file in the generated repo; do not replace it with a synthetic `.gitkeep` or placeholder note.

Exception: update `testenvironments.json` with the derived `{UBUNTU_TESTRUNNER_TAG}` instead of leaving a hardcoded runner image tag in place. Keep the `WSL-Ubuntu` entry and use the Docker major-tag convention documented for the shared Ubuntu test runner images.

Exception: if the user selected multiple host types, rewrite the root `README.md` running section to list one `dotnet run --project ...` command per generated host project instead of leaving a single `{AppType}` placeholder example.

### 2. Copy app `Directory.Build.props`
Copy `assets/app/Directory.Build.props` to the project root, applying placeholder substitution.

### 3. Copy app CI pipeline
Overwrite the shared CI pipeline with `assets/app/.github/workflows/ci-pipeline.yml`. Apps have a simplified pipeline (build + test only).

### 4. Generate app-specific files
Follow the variant guide (Step 2) for the remaining files. **Do not write these files from scratch** — use the asset templates in `assets/app/` as the source of truth:

- **`.csproj` files** → copy from `assets/app/{type}.csproj` for Console and Worker, or from the selected web variant asset (`assets/app/web.csproj`, `assets/app/web-api.csproj`, `assets/app/web-mvc.csproj`, or `assets/app/webapp.csproj`)
- **`Program.cs`** → copy from the matching asset folder's `Program.minimal.cs` (Minimal pattern) or `Program.startup.cs` (Startup pattern)
- **`Startup.cs`** → copy from the matching asset folder's `Startup.cs` (Startup pattern only)
- **`Worker.cs`** → copy from `assets/app/worker/Worker.cs` whenever generating a Worker host type
- **MVC starter UI** → copy `Controllers/` plus `Views/` from `assets/app/web-mvc/` whenever generating the MVC variant
- **Razor starter UI** → copy `Pages/` from `assets/app/webapp/` whenever generating the Web App / Razor variant
- **Test `.csproj`** → copy from `assets/app/test.csproj`

Apply placeholder substitution (Step 4) to all copied files. The user's business logic, endpoints, and service registrations go into `Startup.cs` (Startup pattern), the `Program.cs` configure methods (Minimal pattern), the MVC controller/view starter, the Razor Pages starter, or the default `Worker.cs` loop for Worker services — but the bootstrapper base classes must remain intact.

Generate the `.slnx` solution file and functional test project structure per the variant guide.

## Step 6: Post-Generation Checklist

After generating, verify:

- [ ] `.slnx` references all generated src/ and test/ projects
- [ ] `Directory.Packages.props` lists all `<PackageReference>` packages used in the solution (including host-type-specific packages)
- [ ] `Directory.Packages.props` contains concrete version numbers with no unresolved `*_VERSION` placeholders
- [ ] `ci-pipeline.yml` has the correct settings (build + test only)
- [ ] Root governance docs exist: `README.md`, `CHANGELOG.md`, `.github/CODE_OF_CONDUCT.md`, `.github/CONTRIBUTING.md`
- [ ] `.editorconfig` is present with file-scoped namespace enforcement
- [ ] `AGENTS.md` references `.bot/` and coding guidelines
- [ ] `.github/copilot-instructions.md` has project-specific patterns
- [ ] `.bot/` folder exists and is listed in `.gitignore`
- [ ] `.bot/README.md` exists in the generated repo and came from the shared asset template
- [ ] `testenvironments.json` uses the major-tag `codebeltnet/ubuntu-testrunner:{major}` convention for the selected target framework
- [ ] Correct hosting pattern files generated (`Program.cs` only for Minimal, `Program.cs` + `Startup.cs` for Startup)
- [ ] `Web API` is the default `web_variant` when the user asked for a generic `Web` app
- [ ] `Empty Web` uses the `Web` suffix, `Web API` uses `Api`, `MVC` uses `Mvc`, and `Web App / Razor` uses `WebApp`
- [ ] MVC and Razor variants include their starter UI assets
- [ ] Worker projects include `Worker.cs`

Summarize what was generated and note any manual steps.
