# Standalone Application Variant Reference

Slim guide for runnable applications. All file templates live in `assets/app/`.

## Folder Structure

```
{REPO_SLUG}/
├── src/
│   └── {NS}.{AppType}/
│       ├── {NS}.{AppType}.csproj
│       └── Program.cs  (+ Startup.cs if startup pattern)
├── test/
│   └── {NS}.{AppType}.FunctionalTests/
│       └── {NS}.{AppType}.FunctionalTests.csproj
├── Directory.Build.props
├── Directory.Build.targets
├── Directory.Packages.props
└── {REPO_SLUG}.slnx
```

No `.nuget/` folder or `.snk` file (uncommon for apps).

## Testing Approach

Apps use **functional tests** (not unit tests). The test project exercises the running application as a whole — verifying endpoints, commands, or hosted service behavior — rather than testing individual classes in isolation.

- Test project naming: `{NS}.{AppType}.FunctionalTests` (not `.Tests`)
- The `IsTestProject` detection in `Directory.Build.props` uses `EndsWith('Tests')`, which also matches `FunctionalTests`

## Template File Mapping

| Template source                  | Destination                                                        |
|----------------------------------|--------------------------------------------------------------------|
| `assets/app/Directory.Build.props` | `Directory.Build.props` (repo root)                           |
| `assets/app/console.csproj`   | `src/{NS}.Console/{NS}.Console.csproj`                             |
| `assets/app/web.csproj`       | `src/{NS}.Api/{NS}.Api.csproj`                                     |
| `assets/app/worker.csproj`    | `src/{NS}.Worker/{NS}.Worker.csproj`                               |
| `assets/app/test.csproj`      | `test/{NS}.{AppType}.FunctionalTests/{NS}.{AppType}.FunctionalTests.csproj` |

## Startup vs Minimal Pattern

**You must ask the user before proceeding** — do not assume a default.

Ask the user: **"Hosting pattern: Startup (aka Classic Hosting — Program.cs + Startup.cs) or Minimal (aka Minimal Hosting — Program.cs only)?"** Default: **Minimal**.

| Pattern | Also known as | Files to copy | Source template |
|---------|---------------|---------------|-----------------|
| **Startup** | Classic Hosting | `Program.cs` + `Startup.cs` | `assets/app/{type}/Program.startup.cs` and `assets/app/{type}/Startup.cs` |
| **Minimal** | Minimal Hosting | `Program.cs` only | `assets/app/{type}/Program.minimal.cs` |

Where `{type}` = `console`, `web`, or `worker`.

Both are placed in `src/{NS}.{AppType}/`.

## .slnx Template (inline — dynamic project list)

```xml
<Solution>
  <Folder Name="/src/">
    <Project Path="src/{NS}.{AppType}/{NS}.{AppType}.csproj" />
  </Folder>
  <Folder Name="/test/">
    <Project Path="test/{NS}.{AppType}.FunctionalTests/{NS}.{AppType}.FunctionalTests.csproj" />
  </Folder>
</Solution>
```

Add one `<Project>` entry per host type when a solution contains multiple app types.

## Additional Packages (Directory.Packages.props)

Each app type requires variant-specific NuGet packages:

| App type | Required packages |
|----------|-------------------|
| Console  | `Codebelt.Bootstrapper.Console` |
| Web API  | `Codebelt.Bootstrapper.Web`, `Microsoft.AspNetCore.OpenApi` |
| Worker   | `Codebelt.Bootstrapper.Worker`, `Microsoft.Extensions.Hosting` |

Merge these into `Directory.Packages.props` alongside the shared packages.

## Multiple App Types

A single solution can host more than one app type (e.g. Console + Worker).

- Add a `src/` project and `test/` project **per host type**.
- Add all projects to the `.slnx` under the appropriate solution folders.
- Merge the NuGet packages from each variant into `Directory.Packages.props`.
