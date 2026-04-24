# Standalone Application Variant Reference

Slim guide for runnable applications. All file templates live in `assets/app/`.

## Folder Structure

```
.
├── src/
│   └── {ROOT_NAMESPACE}.{AppType}/
│       ├── {ROOT_NAMESPACE}.{AppType}.csproj
│       └── Program.cs  (+ Startup.cs if startup pattern)
├── test/
│   └── {ROOT_NAMESPACE}.{AppType}.FunctionalTests/
│       └── {ROOT_NAMESPACE}.{AppType}.FunctionalTests.csproj
├── Directory.Build.props
├── Directory.Build.targets
├── Directory.Packages.props
└── {SOLUTION_NAME}.slnx
```

The tree is shown **relative to the current working directory**. Generate these files directly in the folder the user is already in; do not create an extra solution-named wrapper folder unless they explicitly ask for one.

Preserve the solution/product name casing for the solution file itself. Use `{SOLUTION_NAME}.slnx` exactly as provided by the user, typically in `PascalCase`. Do **not** derive the `.slnx` filename from `{REPO_SLUG}` or any lowercased variant.

Treat the files shown in this tree as required output, not aspirational examples. A single-host scaffold still requires `{SOLUTION_NAME}.slnx`, one `src/` project, one `test/` project, `Directory.Build.props`, `Directory.Build.targets`, `Directory.Packages.props`, and `testenvironments.json`.

No `.nuget/` folder or `.snk` file (uncommon for apps).

## Required Shared Asset Inventory

Copy the complete contents of `assets/shared/` into the generated repo root, preserving relative paths.

If the installation path drops dot-prefixed entries, treat that as an incomplete copy. Verify the upstream repository contents, then manually restore the missing files directly from the repository source tree into the matching relative paths before finalizing the scaffold.

Do not cherry-pick only the files that feel essential. The shared scaffold contract includes:

- `.editorconfig`
- `.gitattributes`
- `.gitignore`
- `AGENTS.md`
- `CHANGELOG.md`
- `Directory.Build.targets`
- `Directory.Packages.props`
- `README.md`
- `testenvironments.json`
- `.bot/README.md`
- `.github/CODE_OF_CONDUCT.md`
- `.github/CONTRIBUTING.md`
- `.github/copilot-instructions.md`
- `.github/dependabot.yml`

Treat missing files from this shared inventory as scaffold defects, not optional omissions.

## Testing Approach

Apps use **functional tests** (not unit tests). The test project exercises the running application as a whole — verifying endpoints, commands, or hosted service behavior — rather than testing individual classes in isolation.

- Test project naming: `{ROOT_NAMESPACE}.{AppType}.FunctionalTests` (not `.Tests`)
- The `IsTestProject` detection in `Directory.Build.props` uses `EndsWith('Tests')`, which also matches `FunctionalTests`

## Template File Mapping

| Template source                  | Destination                                                        |
|----------------------------------|--------------------------------------------------------------------|
| `assets/app/Directory.Build.props` | `Directory.Build.props` (repo root)                           |
| `assets/app/console.csproj`   | `src/{ROOT_NAMESPACE}.Console/{ROOT_NAMESPACE}.Console.csproj`     |
| `assets/app/web.csproj`       | `src/{ROOT_NAMESPACE}.Web/{ROOT_NAMESPACE}.Web.csproj`             |
| `assets/app/web-api.csproj`   | `src/{ROOT_NAMESPACE}.Api/{ROOT_NAMESPACE}.Api.csproj`             |
| `assets/app/web-mvc.csproj`   | `src/{ROOT_NAMESPACE}.Mvc/{ROOT_NAMESPACE}.Mvc.csproj`             |
| `assets/app/webapp.csproj`    | `src/{ROOT_NAMESPACE}.WebApp/{ROOT_NAMESPACE}.WebApp.csproj`       |
| `assets/app/worker.csproj`    | `src/{ROOT_NAMESPACE}.Worker/{ROOT_NAMESPACE}.Worker.csproj`       |
| `assets/app/worker/Worker.cs` | `src/{ROOT_NAMESPACE}.Worker/Worker.cs`                            |
| `assets/app/test.csproj`      | `test/{ROOT_NAMESPACE}.{AppType}.FunctionalTests/{ROOT_NAMESPACE}.{AppType}.FunctionalTests.csproj` |

## Startup vs Minimal Pattern

**You must ask the user before proceeding** — do not assume a default.

Ask the user: **"Hosting pattern: Startup (aka Classic Hosting — Program.cs + Startup.cs) or Minimal (aka Minimal Hosting — Program.cs only)?"** Default: **Minimal**.

| Pattern | Also known as | Files to copy | Source template |
|---------|---------------|---------------|-----------------|
| **Startup** | Classic Hosting | `Program.cs` + `Startup.cs` | `assets/app/{type}/Program.startup.cs` and `assets/app/{type}/Startup.cs` |
| **Minimal** | Minimal Hosting | `Program.cs` only | `assets/app/{type}/Program.minimal.cs` |

Where `{type}` = `console`, `worker`, or the selected web asset folder: `web`, `web-api`, `web-mvc`, or `webapp`.

Where `{AppType}` maps to the emitted project suffix:

- `console` → `Console`
- `web` (`Empty Web`) → `Web`
- `web-api` (`Web API`) → `Api`
- `web-mvc` (`MVC`) → `Mvc`
- `webapp` (`Web App / Razor`) → `WebApp`
- `worker` → `Worker`

Both are placed in `src/{ROOT_NAMESPACE}.{AppType}/`.

When the user asks for a generic `Web` project, collect exactly one `web_variant` and default it to `Web API`.

## Web Variant Starter Assets

When `app_host_types` includes `Web`, generate exactly one web-family project using the selected `web_variant`:

| Web variant | Asset stem/folder | Emitted suffix | Extra starter assets |
|-------------|-------------------|----------------|----------------------|
| `Empty Web` | `web` | `Web` | none |
| `Web API` | `web-api` | `Api` | none |
| `MVC` | `web-mvc` | `Mvc` | `Controllers/` and `Views/` |
| `Web App / Razor` | `webapp` | `WebApp` | `Pages/` |

## .slnx Template (inline — dynamic project list)

```xml
<Solution>
  <Folder Name="/src/">
    <Project Path="src/{ROOT_NAMESPACE}.{AppType}/{ROOT_NAMESPACE}.{AppType}.csproj" />
  </Folder>
  <Folder Name="/test/">
    <Project Path="test/{ROOT_NAMESPACE}.{AppType}.FunctionalTests/{ROOT_NAMESPACE}.{AppType}.FunctionalTests.csproj" />
  </Folder>
</Solution>
```

Add one `<Project>` entry per host type when a solution contains multiple app types.

The solution file name itself must be `{SOLUTION_NAME}.slnx`, preserving the original user-facing casing.

Even when there is only one host type, still generate the `.slnx` file and include both the `src/` and `test/` project entries.

## Additional Packages (Directory.Packages.props)

Each app type requires variant-specific NuGet packages:

| App type | Required packages |
|----------|-------------------|
| Console  | `Codebelt.Bootstrapper.Console` |
| Empty Web  | `Codebelt.Bootstrapper.Web` |
| Web API  | `Codebelt.Bootstrapper.Web`, `Microsoft.AspNetCore.OpenApi` |
| MVC  | `Codebelt.Bootstrapper.Web`, `Microsoft.AspNetCore.Mvc.Razor.RuntimeCompilation` |
| Web App / Razor  | `Codebelt.Bootstrapper.Web`, `Microsoft.AspNetCore.Mvc.Razor.RuntimeCompilation` |
| Worker   | `Codebelt.Bootstrapper.Worker`, `Microsoft.Extensions.Hosting` |

Merge these into `Directory.Packages.props` alongside the shared packages.

The generated `Directory.Packages.props` should include only packages that are actually referenced by the copied `assets/app/**/*.csproj` templates for the selected host types plus the shared test/build packages and `MinVer` for app versioning. Do not leave unused library-only or benchmark-only package versions in app scaffolds.

Resolve each package-specific `*_VERSION` placeholder in `Directory.Packages.props` from NuGet.org before writing the final file. Do not leave generic `{LATEST}` or unresolved version tokens in the generated repo.

`Directory.Packages.props` is the authoritative version source for app scaffolds. Keep the generated `PackageReference` items versionless and centrally managed; do **not** repair restore/build issues by inlining `Version=` attributes into `.csproj` files or `Directory.Build.props`.

Keep target-framework selection centralized too: the generated root `Directory.Build.props` owns `<TargetFramework>{TARGET_FRAMEWORK}</TargetFramework>` for source and test projects. Do **not** duplicate `<TargetFramework>` inside the generated app or test `.csproj` files as a workaround.

When PowerShell is available, prefer `scripts/resolve-package-versions.ps1` to produce the package placeholder map for this skill. The script defaults to this skill's own `assets/shared/Directory.Packages.props`, so the normal path only needs `{TARGET_FRAMEWORK}`. Its output should drive the final substitutions instead of remembered version numbers.

For framework-aligned ASP.NET packages, keep the selected target framework major in mind when resolving the final version:

- `Microsoft.AspNetCore.OpenApi` should use the latest stable version whose major matches `{TARGET_FRAMEWORK}`
- `Microsoft.AspNetCore.Mvc.Razor.RuntimeCompilation` should use the latest stable version whose major matches `{TARGET_FRAMEWORK}`
- Example: a `net9.0` app should resolve these packages to the latest stable `9.x` version, not `10.x`
- If the lookup step fails, stop and report the failure instead of guessing with stale package versions from prior runs

## Test Environments

Generate `testenvironments.json` from the selected target framework instead of keeping a hardcoded SDK patch tag.

- Always include the `WSL-Ubuntu` entry
- Add one `Docker-Ubuntu` entry using `codebeltnet/ubuntu-testrunner:{major}` where `{major}` comes from `{TARGET_FRAMEWORK}`
- Example: `net10.0` → `codebeltnet/ubuntu-testrunner:10`

`testenvironments.json` is required output for the scaffold. If you cannot render it from the shared template plus `{UBUNTU_TESTRUNNER_TAG}`, stop and report the issue instead of silently omitting the file.

## MinVer Bootstrap Behavior

App scaffolds keep `MinVer` wired in from day one.

- In a fresh folder that is not yet a git repository, or in a git repo without version tags, MinVer may report a bootstrap pre-release such as `0.0.0-alpha.0`
- Treat that as expected initial state rather than a template defect
- Do not remove MinVer or replace it with hardcoded package/app versions just to suppress that warning
- Once the user initializes git and adds a version tag, MinVer will produce the intended semantic version values

## Multiple App Types

A single solution can host more than one app type (e.g. Web + Worker or Console + Worker).

- Add a `src/` project and `test/` project **per host type**.
- If `Web` is selected, generate exactly one web-family project using the chosen `web_variant`.
- Add all projects to the `.slnx` under the appropriate solution folders.
- Merge the NuGet packages from each variant into `Directory.Packages.props`.
