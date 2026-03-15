# NuGet Library Variant Reference

Slim guide for scaffolding a NuGet library solution. All file templates live in `assets/library/`.

---

## Folder Structure

```
{REPO_SLUG}/
├── .nuget/
│   └── {PROJECT_NAME}/
│       ├── PackageReleaseNotes.txt
│       ├── icon.png                ← placeholder 128×128 PNG
│       └── README.md
├── src/
│   └── {PROJECT_NAME}/
│       └── {PROJECT_NAME}.csproj
├── test/
│   └── {PROJECT_NAME}.Tests/
│       └── {PROJECT_NAME}.Tests.csproj
├── tuning/
│   └── {PROJECT_NAME}.Benchmarks/
│       └── {PROJECT_NAME}.Benchmarks.csproj
├── tooling/
│   └── {BENCHMARK_RUNNER_PROJECT_NAME}/
│       ├── {BENCHMARK_RUNNER_PROJECT_NAME}.csproj
│       └── Program.cs
├── reports/
│   └── tuning/
│       └── (benchmark reports and tuning output)
├── Directory.Build.props
├── {REPO_SLUG}.slnx
└── (shared skeleton files — see shared-files.md)
```

---

## Template File Mapping

| Template                                  | Destination                                                        |
|-------------------------------------------|--------------------------------------------------------------------|
| `assets/library/Directory.Build.props` | `Directory.Build.props` (repo root)                                |
| `assets/library/source.csproj`         | `src/{PROJECT_NAME}/{PROJECT_NAME}.csproj`                         |
| `assets/library/test.csproj`           | `test/{PROJECT_NAME}.Tests/{PROJECT_NAME}.Tests.csproj`            |
| `assets/library/benchmark.csproj`      | `tuning/{PROJECT_NAME}.Benchmarks/{PROJECT_NAME}.Benchmarks.csproj` |
| `assets/library/benchmark-runner.csproj` | `tooling/{BENCHMARK_RUNNER_PROJECT_NAME}/{BENCHMARK_RUNNER_PROJECT_NAME}.csproj` |
| `assets/library/benchmark-program.cs`  | `tooling/{BENCHMARK_RUNNER_PROJECT_NAME}/Program.cs`               |
| `assets/library/PackageReleaseNotes.txt` | `.nuget/{PROJECT_NAME}/PackageReleaseNotes.txt`                  |
| `assets/library/nuget-readme.md`       | `.nuget/{PROJECT_NAME}/README.md`                                  |
| *(create manually)*                       | `.nuget/{PROJECT_NAME}/icon.png` — 128×128 PNG placeholder         |
| `assets/shared/testenvironments.json`  | Generate dynamically at `testenvironments.json` based on selected TFMs |

---

## .slnx Template (inline — content varies per solution)

```xml
<Solution>
  <Folder Name="/src/">
    <Project Path="src/{PROJECT_NAME}/{PROJECT_NAME}.csproj" />
  </Folder>
  <Folder Name="/test/">
    <Project Path="test/{PROJECT_NAME}.Tests/{PROJECT_NAME}.Tests.csproj" />
  </Folder>
  <Folder Name="/tuning/">
    <Project Path="tuning/{PROJECT_NAME}.Benchmarks/{PROJECT_NAME}.Benchmarks.csproj" />
  </Folder>
  <Folder Name="/tooling/">
    <Project Path="tooling/{BENCHMARK_RUNNER_PROJECT_NAME}/{BENCHMARK_RUNNER_PROJECT_NAME}.csproj" />
  </Folder>
</Solution>
```

Benchmark reports are written under `reports/`, not under the `tuning/` project folder.

---

## Additional Packages

Add library-specific packages to `Directory.Packages.props` (beyond the shared skeleton). Use framework-conditional groups for packages that ship different versions per TFM:

```xml
<ItemGroup Condition="$(TargetFramework.StartsWith('net9'))">
  <PackageVersion Include="Microsoft.Extensions.DependencyInjection.Abstractions" Version="{LATEST_9x}" />
</ItemGroup>
<ItemGroup Condition="$(TargetFramework.StartsWith('net10'))">
  <PackageVersion Include="Microsoft.Extensions.DependencyInjection.Abstractions" Version="{LATEST_10x}" />
</ItemGroup>
```

Always resolve `{LATEST_Nx}` from NuGet.org — never hardcode versions.

---

## Shared NuGet Package Version Policy

`assets/shared/Directory.Packages.props` is a dynamic template, not a frozen version snapshot.

Hard rule:

1. Resolve every `*_VERSION` placeholder to the latest stable listed version for that exact package ID on NuGet.org at generation time
2. Exclude prerelease versions even if they are newer
3. Exclude unlisted versions when the metadata source exposes listing status
4. Resolve each package independently; never reuse one generic "latest" token across multiple packages
5. Never copy package versions from stale screenshots, older repos, or prior scaffold output

Preferred data source:

- NuGet V3 service index: `https://api.nuget.org/v3/index.json`
- From there, prefer the registration resource so you can inspect package versions with listing metadata

Fallback data source:

- NuGet package base address resource from the same service index
- Use its versions list only when the registration resource is unavailable, and still filter out prerelease versions before picking the highest stable semantic version

Practical guidance:

- `BenchmarkDotNet` should resolve separately from `Microsoft.NET.Test.Sdk`
- `BenchmarkDotNet.Diagnostics.Windows` should resolve separately from `BenchmarkDotNet`
- `Codebelt.Extensions.BenchmarkDotNet.Console` should resolve separately from the test and bootstrapper packages
- Leave Dependabot enabled after scaffolding so the repo keeps tracking newer stable packages over time

The generated `.github/dependabot.yml` should watch the repo root (`directory: "/"`) because both `Directory.Packages.props` and `Directory.Build.props` live there.

---

## Target Framework Default

Default new libraries to a single target framework using the newest generally supported .NET LTS.

Resolve this from the official releases index:

- Source: `https://raw.githubusercontent.com/dotnet/core/refs/heads/main/release-notes/releases-index.json`
- Include entries where `product` is `.NET`
- Keep entries where `support-phase` is `active` or `maintenance`
- Ignore preview and `eol` entries
- Pick the highest `release-type: lts` channel and format it as `net{major}.0`

As of March 15, 2026, that yields `net10.0`. This will naturally change as support windows roll forward. Only expand to multiple TFMs when the user explicitly needs compatibility with older supported runtimes or package consumers require it.

Offer this broader opt-in preset when the user wants expanded support without custom TFM planning:

- Build it from all generally supported non-preview `.NET` channels in the same releases index, sorted newest to oldest and formatted as semicolon-separated TFMs
- As of March 15, 2026, that yields `net10.0;net9.0;net8.0`

Treat that preset as a convenience option, not the default.

---

## Test Environments Generation

Generate `testenvironments.json` from the selected TFMs instead of copying a static Docker image tag.

Rules:

1. Always include the `WSL-Ubuntu` environment
2. Add one `Docker-Ubuntu` environment per selected TFM
3. Use Docker image `codebeltnet/ubuntu-testrunner:{major}` where `{major}` is the target framework major version
4. Validate generated Docker tags against Docker Hub before finalizing the file

Validation source:

- Human page: `https://hub.docker.com/r/codebeltnet/ubuntu-testrunner/tags`
- Machine-readable tags API: `https://hub.docker.com/v2/repositories/codebeltnet/ubuntu-testrunner/tags?page_size=100`

Examples:

- `net10.0`
  Produces one Docker entry with `dockerImage: "codebeltnet/ubuntu-testrunner:10"`
- `net9.0;net10.0`
  Produces two Docker entries with tags `9` and `10`

Example structure:

```json
{
  "version": "1",
  "environments": [
    {
      "name": "WSL-Ubuntu",
      "type": "wsl",
      "wslDistribution": "Ubuntu-24.04"
    },
    {
      "name": "Docker-Ubuntu",
      "type": "docker",
      "dockerImage": "codebeltnet/ubuntu-testrunner:9"
    },
    {
      "name": "Docker-Ubuntu",
      "type": "docker",
      "dockerImage": "codebeltnet/ubuntu-testrunner:10"
    }
  ]
}
```

Keep the Docker entries in the same order as the selected TFMs.

As of March 15, 2026, the major tags `8`, `9`, and `10` are present and active in the Docker Hub tags API.

---

## Default Project Naming

Default to a single library project and set `{PROJECT_NAME}` equal to `{SOLUTION_NAME}`.

Default the benchmark runner tooling project to `{BENCHMARK_RUNNER_PROJECT_NAME} = benchmark-runner`.

Derive its namespace separately from the library namespace by converting the tooling project name into a valid C# identifier, for example:

- `benchmark-runner` → `benchmark_runner`

Example:

- Solution: `Codebelt.Agentic`
- Source project: `src/Codebelt.Agentic/Codebelt.Agentic.csproj`
- Test project: `test/Codebelt.Agentic.Tests/Codebelt.Agentic.Tests.csproj`
- Tuning benchmark project: `tuning/Codebelt.Agentic.Benchmarks/Codebelt.Agentic.Benchmarks.csproj`
- Tooling benchmark runner: `tooling/benchmark-runner/benchmark-runner.csproj`
- Benchmark reports: `reports/`

Only switch to multiple project names when the user explicitly asks for a multi-project solution such as core + extensions or multiple NuGet packages.

---

## Benchmark Runner

Generate one tuning benchmark project per primary source project and one solution-level benchmark runner in `tooling/{BENCHMARK_RUNNER_PROJECT_NAME}/`.

Purpose split:

- `tuning/` holds the actual benchmark projects and benchmark types
- `tooling/` holds executable tooling projects such as the benchmark runner host
- `reports/` holds the reports and benchmark output produced by those tools

`Program.cs` should follow this shape:

```csharp
using Codebelt.Extensions.BenchmarkDotNet;
using Codebelt.Extensions.BenchmarkDotNet.Console;
using BenchmarkDotNet.Environments;

namespace {BENCHMARK_RUNNER_NAMESPACE}
{
    public class Program
    {
        public static void Main(string[] args)
        {
            BenchmarkProgram.Run(args, o =>
            {
                o.AllowDebugBuild = BenchmarkProgram.IsDebugBuild;
                o.SkipBenchmarksWithReports = true;
                o.ConfigureBenchmarkDotNet(c =>
                {
                    var slimJob = BenchmarkWorkspaceOptions.Slim;
                    return c
{BENCHMARK_RUNTIME_JOBS};
                });
            });
        }
    }
}
```

Generate `{BENCHMARK_RUNTIME_JOBS}` from the selected executable TFMs:

- `net48` → `.AddJob(slimJob.WithRuntime(ClrRuntime.Net48))`
- `net9.0` → `.AddJob(slimJob.WithRuntime(CoreRuntime.Core90))`
- `net10.0` → `.AddJob(slimJob.WithRuntime(CoreRuntime.Core10_0))`

Keep the jobs in the same order as `target_frameworks` after filtering out non-executable TFMs such as `netstandard*`.

The benchmark runner project should:

- live under `tooling/`
- reference the default tuning benchmark project by default
- rely on central package management for `BenchmarkDotNet` and `Codebelt.Extensions.BenchmarkDotNet.Console`
- target the highest selected LTS TFM from `target_frameworks` so the runner itself stays on an LTS runtime by default
- if the selected TFMs do not include an LTS runtime, require a manual runner TFM decision instead of guessing

The tuning benchmark project should:

- live under `tuning/`
- reference the main source project
- rely on central package management for `BenchmarkDotNet` and `BenchmarkDotNet.Diagnostics.Windows`
- keep benchmark types in the same namespace as the production code they measure

If the user later wants more benchmark coverage, add benchmark classes to the tuning projects or make the runner reference additional tuning projects without changing the role split between `tuning/`, `tooling/`, and `reports/`.

---

## Package Website Vs Repository

Keep these URLs distinct in generated metadata:

- `{PACKAGE_PROJECT_URL}` maps to NuGet `PackageProjectUrl` and should point to the public project website or documentation site when one exists
- `{REPOSITORY_URL}` maps to the source repository and should point to the code host, typically GitHub

They can be the same URL for simple packages, but they do not have to be.

Example:

- `{PACKAGE_PROJECT_URL}` → `https://www.savvyio.net/`
- `{REPOSITORY_URL}` → `https://github.com/codebeltnet/savvyio`

Prefer the public site for `{PACKAGE_PROJECT_URL}` when the library has one. Fall back to `{REPOSITORY_URL}` only when there is no separate website or docs host.

When collecting parameters, ask for `{REPOSITORY_URL}` first and then present that value as the default for `{PACKAGE_PROJECT_URL}`.

---

## Multi-project Guidance

For multiple library projects (e.g. core + extensions), repeat per project:

1. `src/{PROJECT_NAME}/` — source project (from `source.csproj` template)
2. `test/{PROJECT_NAME}.Tests/` — test project (from `test.csproj` template)
3. `tuning/{PROJECT_NAME}.Benchmarks/` — benchmark project (from `benchmark.csproj` template)
4. Reuse one solution-level benchmark runner under `tooling/{BENCHMARK_RUNNER_PROJECT_NAME}/`
5. `.nuget/{PROJECT_NAME}/` — NuGet metadata (release notes, readme, icon)
6. Add each project to the `.slnx` under the appropriate folder

---

## Project References

- **Test → Source:** `<ProjectReference Include="..\..\src\{PROJECT_NAME}\{PROJECT_NAME}.csproj" />`
- **Benchmark → Source:** `<ProjectReference Include="..\..\src\{PROJECT_NAME}\{PROJECT_NAME}.csproj" />`
- **Benchmark runner → Benchmark:** `<ProjectReference Include="..\..\tuning\{PROJECT_NAME}.Benchmarks\{PROJECT_NAME}.Benchmarks.csproj" />`
- **Extension → Core:** extension projects reference the core project via `<ProjectReference>`
