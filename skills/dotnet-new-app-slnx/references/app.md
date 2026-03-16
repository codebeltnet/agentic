# Standalone Application Variant Reference

Slim guide for runnable applications. All file templates live in `assets/app/`.

## Folder Structure

```
{REPO_SLUG}/
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
└── {REPO_SLUG}.slnx
```

No `.nuget/` folder or `.snk` file (uncommon for apps).

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

Resolve each package-specific `*_VERSION` placeholder in `Directory.Packages.props` from NuGet.org before writing the final file. Do not leave generic `{LATEST}` or unresolved version tokens in the generated repo.

## Test Environments

Generate `testenvironments.json` from the selected target framework instead of keeping a hardcoded SDK patch tag.

- Always include the `WSL-Ubuntu` entry
- Add one `Docker-Ubuntu` entry using `codebeltnet/ubuntu-testrunner:{major}` where `{major}` comes from `{TARGET_FRAMEWORK}`
- Example: `net10.0` → `codebeltnet/ubuntu-testrunner:10`

## Multiple App Types

A single solution can host more than one app type (e.g. Web + Worker or Console + Worker).

- Add a `src/` project and `test/` project **per host type**.
- If `Web` is selected, generate exactly one web-family project using the chosen `web_variant`.
- Add all projects to the `.slnx` under the appropriate solution folders.
- Merge the NuGet packages from each variant into `Directory.Packages.props`.
