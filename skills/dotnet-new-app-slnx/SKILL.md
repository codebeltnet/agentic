---
name: dotnet-new-app-slnx
description: >
  Scaffold a new .NET standalone application solution following codebelt engineering conventions. Use this skill when the user wants to create a new .NET application — Console, Web, or Worker service. Also use when the user mentions "new app", "new console app", "new web api", "new mvc app", "new razor app", "new web app", "new worker service", "scaffold app", "dotnet new web", "dotnet new webapi", "dotnet new mvc", "dotnet new webapp", "dotnet new worker", "dotnet new console", or wants a .NET application project with CI/CD pipeline, functional tests, and code quality tooling. ALWAYS use this skill when asked to scaffold or create a new .NET application solution.
---

# .NET Application Solution Setup (Codebelt Conventions)

Scaffold new .NET standalone application solutions following the codebeltnet engineering conventions — the same pattern used across [codebeltnet](https://github.com/codebeltnet). Produces a fully wired solution with CI pipeline, centralized build config, semantic versioning, code quality tooling, and proper folder structure.

> **CRITICAL:** All application projects **must** use the `Codebelt.Bootstrapper.*` framework — never vanilla `WebApplication.CreateBuilder()` or raw `Host.CreateDefaultBuilder()`. The bootstrapper provides a uniform, convention-driven `Program.cs` (and `Startup.cs` for classic hosting). The asset templates in `assets/app/` already wire this up correctly — **always copy from templates, never write Program.cs from scratch**.

> If a generated app fails because a bootstrapper type from the copied asset template does not resolve, first verify the copied template imports the correct `Codebelt.Bootstrapper.*` namespace and that the matching package reference is present. If the bootstrapper type still cannot be resolved, halt and report the template/package mismatch. Do **not** substitute vanilla .NET hosting code as a workaround.

## Scope

This skill produces a **complete solution scaffold** — project structure, build config, CI pipeline, governance docs, and bootstrapper-wired entry points. It does **not** generate application logic (endpoints, services, controllers, middleware). The scaffold is the foundation; the user adds their code on top.

Generate the scaffold **in the user's current working directory**. Do not create an extra top-level `{REPO_SLUG}` or `{SOLUTION_NAME}` folder unless the user explicitly asks for a nested output folder.

## Non-Negotiable Output Contract

The scaffold is incomplete unless it produces all required artifacts for the selected host types. These are not optional, and they must not be silently skipped:

- the solution file named `{SOLUTION_NAME}.slnx` with the original user-facing casing preserved
- the selected `src/` project or projects
- one functional test project per selected host type under `test/`
- `Directory.Build.props`
- `Directory.Packages.props`
- `testenvironments.json`
- the shared governance/docs assets copied from `assets/shared/`

If you cannot generate any required artifact from the documented templates and rules, halt and report the mismatch instead of improvising, omitting the file, or substituting a weaker fallback.

Treat the scaffold as a fidelity copy of the documented template set, not a "best effort" approximation. Do not cherry-pick only the files that seem important, and do not patch over structural problems by pushing configuration down into individual project files.

**When to use this skill:** The user wants a properly structured .NET solution from scratch — with conventions, CI, and tooling baked in from day one.

**When NOT to use this skill:** The user wants a quick, throwaway backend or a thin adapter layer. If the request is for a minimal placeholder (e.g. "just a basic API proxy"), do not invoke this skill — use standard .NET CLI tooling instead (`dotnet new web`) and let the user decide if they want to upgrade to a full scaffold later.

## Step 1: Collect Parameters

Read `FORMS.md` and collect all parameters by presenting each field to the user one at a time using the agent's native input mechanism when the host supports it. If the host does not render native form controls, follow the deterministic plain-text fallback defined in `FORMS.md` instead of improvising your own questioning style. Do not proceed to Step 2 until all required fields are collected and the user confirms the summary.

For fields that already present a recommended `default` or `computed_default`, treat a blank response as accepting that shown value. Do not get stuck in a clarification loop for `root_namespace`, `target_framework`, or any other defaultable field just because the user did not type over the recommended choice.

Consistency matters more than creativity during parameter collection. Do not paraphrase field prompts, merge questions, or switch interaction styles mid-flow.

Treat `Web` as the host family. When `Web` is selected, collect exactly one `web_variant`. If the user already said `web api`, `mvc`, `razor`, or `web app`, preselect the matching `web_variant` instead of asking them to repeat it.

If the user already said `console` or `worker`, preselect that host type and continue with the next unresolved field instead of re-asking `app_host_types`. In plain-text fallback mode, begin each step directly with the next `Field: <field-name>` block from `FORMS.md`; do not add extra conversational lead-ins between fields.

For `target_framework`, compute one quick-pick per generally supported non-preview `.NET` channel from `https://raw.githubusercontent.com/dotnet/core/refs/heads/main/release-notes/releases-index.json`, sorted newest to oldest before free text.

- Mark the newest supported LTS channel as the recommended choice
- Include every other supported LTS and STS channel as additional first-class choices
- Label each quick-pick with its support track so the user can choose knowingly

Filter to `.NET` entries whose `support-phase` is `active` or `maintenance`, exclude preview channels, and let the user choose any currently supported LTS or STS track.

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

When PowerShell is available, prefer the deterministic helper in `scripts/resolve-package-versions.ps1` over manual lookup. By default it resolves placeholders from this skill's own `assets/shared/Directory.Packages.props`, so a normal scaffold run only needs `-TargetFramework`. Treat its JSON output as the source of truth for package placeholders.

- Use the NuGet V3 service index at `https://api.nuget.org/v3/index.json` to discover the package metadata endpoints
- Prefer registration metadata so you can ignore unlisted versions and prerelease builds
- If registration metadata is unavailable, fall back to the package base address versions list from the same service index and still exclude prerelease versions
- Resolve each package independently by package ID; never reuse one generic "latest" value across multiple packages
- Never hardcode version numbers from stale examples, screenshots, or prior scaffolds
- For framework-aligned ASP.NET packages such as `Microsoft.AspNetCore.OpenApi` and `Microsoft.AspNetCore.Mvc.Razor.RuntimeCompilation`, resolve the latest stable version whose **major** matches the selected `{TARGET_FRAMEWORK}` major. Example: `net9.0` must not get `10.x` ASP.NET packages.
- `Directory.Packages.props` is the authoritative source of NuGet package versions for the generated app scaffold. Do **not** inline `Version=` attributes into `.csproj` files or `Directory.Build.props` as a workaround for restore or build issues.
- Never substitute remembered, example, or previously seen package versions when this lookup step is available. If the lookup step fails, halt and report it instead of guessing.

This includes shared and host-specific app packages such as:

- `Codebelt.Extensions.Xunit.App`
- `Microsoft.NET.Test.Sdk`
- `MinVer`
- `coverlet.collector`
- `coverlet.msbuild`
- `xunit.v3`
- `xunit.v3.runner.console`
- `xunit.runner.visualstudio`
- `Codebelt.Bootstrapper.Console`
- `Codebelt.Bootstrapper.Web`
- `Codebelt.Bootstrapper.Worker`
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

For generated solution filenames, preserve the user-facing `{SOLUTION_NAME}` casing exactly. The solution file must be named `{SOLUTION_NAME}.slnx`, not `{REPO_SLUG}.slnx` and not any lowercased variant.

`Directory.Packages.props` also contains package-specific placeholders such as `{CODEBELT_BOOTSTRAPPER_WEB_VERSION}`, `{MICROSOFT_ASPNETCORE_OPENAPI_VERSION}`, `{MICROSOFT_ASPNETCORE_MVC_RAZOR_RUNTIMECOMPILATION_VERSION}`, `{MICROSOFT_EXTENSIONS_HOSTING_VERSION}`, and `{MICROSOFT_NET_TEST_SDK_VERSION}`. Resolve each of them from NuGet.org in Step 3 before writing the final file.

For `Microsoft.AspNetCore.OpenApi` and `Microsoft.AspNetCore.Mvc.Razor.RuntimeCompilation`, the resolved stable version must stay aligned with the selected `{TARGET_FRAMEWORK}` major version instead of blindly using the latest stable overall.

Keep `Directory.Packages.props` limited to packages that are actually referenced by the copied app and test templates for the selected host types, plus the shared `MinVer` package used for app versioning. Do not carry unused library-only or benchmark-only package versions into app scaffolds.

If restore/build fails, fix the central package management inputs instead of bypassing them. Do **not** replace centralized package versions with ad-hoc inline versions in generated project files.

`TargetFramework` belongs in the generated root `Directory.Build.props`, not in the generated app or test `.csproj` files. Do **not** "repair" framework resolution by adding `<TargetFramework>` to `src/**/*.csproj` or `test/**/*.csproj`; if framework resolution fails, fix the copied root build props or halt and report the mismatch.

After writing `Directory.Packages.props`, re-check the generated versions against the Step 3 lookup output before finalizing the scaffold. Do not assume an earlier guess was correct just because the project restores.

## Step 5: Generate All Files

Generate files in this order:

### 1. Copy shared templates
Copy every file from `assets/shared/` to the project root, preserving directory structure. Treat the **current working directory** as that project root. Apply placeholder substitution (Step 4) to all file contents during the copy.

Do this as a recursive, dotfile-aware copy. Hidden folders and files under `assets/shared/` are part of the scaffold and must not be skipped. In particular, copy `assets/shared/.bot/README.md` as a real file in the generated repo; do not replace it with a synthetic `.gitkeep` or placeholder note.

Do not selectively copy only "key" shared files. The intended output includes the complete shared asset inventory, including `.gitignore`, `.gitattributes`, `AGENTS.md`, `CHANGELOG.md`, `.github/`, and `.bot/`, in addition to the build and package-management files.

Exception: update `testenvironments.json` with the derived `{UBUNTU_TESTRUNNER_TAG}` instead of leaving a hardcoded runner image tag in place. Keep the `WSL-Ubuntu` entry and use the Docker major-tag convention documented for the shared Ubuntu test runner images.

`testenvironments.json` is a required shared scaffold asset. Do **not** silently omit it. If you cannot generate it from the shared template plus `{UBUNTU_TESTRUNNER_TAG}`, halt and report the mismatch instead of skipping the file.

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

The `.slnx` file is required even for single-host scaffolds. Do not skip it just because the generated solution only contains one `src/` project and one `test/` project.

## Step 6: Post-Generation Checklist

After generating, verify:

- [ ] `.slnx` references all generated src/ and test/ projects
- [ ] The generated solution filename is `{SOLUTION_NAME}.slnx` with the original user-facing casing preserved
- [ ] Every file from `assets/shared/` exists in the generated repo with the same relative path, including dotfiles and dotfolders such as `.gitignore`, `.gitattributes`, `.bot/README.md`, and `.github/*`
- [ ] `Directory.Packages.props` lists all `<PackageReference>` packages used in the solution (including host-type-specific packages)
- [ ] `Directory.Packages.props` contains concrete version numbers with no unresolved `*_VERSION` placeholders
- [ ] No generated `.csproj` file or `Directory.Build.props` contains ad-hoc inline `Version=` attributes for packages that are supposed to be centrally managed by `Directory.Packages.props`
- [ ] No generated app or test `.csproj` file introduces `<TargetFramework>`; framework selection stays centralized in the generated root `Directory.Build.props`
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

If the scaffold is generated outside a git-initialized and tagged repository, expect MinVer to report a placeholder pre-release version such as `0.0.0-alpha.0` until the user initializes git and adds a version tag. Treat that as expected bootstrap state, not as a reason to remove MinVer or change the generated versioning setup.

Summarize what was generated, note any manual steps, and mention the expected MinVer bootstrap behavior when the scaffold was created outside an initialized/tagged git repo.
