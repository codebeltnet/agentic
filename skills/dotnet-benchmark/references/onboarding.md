# Onboarding a Benchmark Harness Into an Existing Repo

Use this when Step 1 detection shows the harness is missing or partial. The goal is to add **only**
what is missing while matching whatever layout the repo already uses. Never restructure the repo,
rename its solution, or convert `.sln` to `.slnx`.

## Decision inputs (from `scripts/check-benchmark-requirements.ps1`)

| Signal | Why it matters |
|--------|----------------|
| `sdk` | Hard prerequisite. If absent, stop and ask the user to install the .NET SDK. |
| `solution` / `solutionFormat` | Determines how you wire new projects (`.slnx` XML vs `dotnet sln add`). |
| `centralPackageManagement` | Chooses `<PackageVersion>` in `Directory.Packages.props` vs versioned `<PackageReference>`. |
| `centralizesBenchmarkConventions` | If the root `Directory.Build.props` defines `IsBenchmarkProject`/`IsToolingProject`, project files stay minimal. |
| `benchmarkProjects` | Existing `tuning/*.Benchmarks` projects to reuse instead of recreating. |
| `runner` | Existing `tooling/` runner host (folder name + whether it references the Console package). Reuse it; do not add a second. |

## 1. Packages

Resolve the **latest stable listed** versions from NuGet.org at author time (never hardcode from an
example). Resolve each package ID independently:

- `BenchmarkDotNet`
- `BenchmarkDotNet.Diagnostics.Windows`
- `Codebelt.Extensions.BenchmarkDotNet.Console`

Resolution source: the NuGet V3 service index `https://api.nuget.org/v3/index.json`; prefer the
registration resource so you can skip unlisted and prerelease versions.

- **CPM repo** (`Directory.Packages.props` present): add `<PackageVersion Include="..." Version="..." />`
  entries, and reference the packages **without** a version in the project files.
- **Non-CPM repo**: put versioned `<PackageReference Include="..." Version="..." />` directly in the
  project files that need them (benchmark project needs the two `BenchmarkDotNet*` packages; runner
  needs the Console package).

## 2. Benchmark project (`tuning/{SutProject}.Benchmarks/`)

Create from `assets/benchmark.csproj`. Substitutions:

| Placeholder | Value |
|-------------|-------|
| `{ROOT_NAMESPACE}` | The SUT's root namespace (e.g. `Cuemon`), so benchmarks compile into the measured namespace. |
| `{SUT_PROJECT}` | The owning `src/` project name (e.g. `Cuemon.Core`). |

The default `assets/benchmark.csproj` is the **minimal** codebelt form and assumes the root
`Directory.Build.props` injects the benchmark TFMs and `BenchmarkDotNet*` packages (as codebelt repos
do). If `centralizesBenchmarkConventions` is **false**, make the project self-contained by adding:

```xml
  <PropertyGroup>
    <TargetFrameworks>net10.0;net9.0</TargetFrameworks>
    <IsPackable>false</IsPackable>
  </PropertyGroup>

  <ItemGroup>
    <PackageReference Include="BenchmarkDotNet" />
    <PackageReference Include="BenchmarkDotNet.Diagnostics.Windows" />
  </ItemGroup>
```

(Use versioned `<PackageReference>`s here if the repo is non-CPM.) Pick benchmark TFMs the SUT
actually supports; `net10.0;net9.0` matches `Codebelt.Extensions.BenchmarkDotNet` availability.

## 3. Runner host (`tooling/{runner}/`)

If `runner` already exists, **reuse it** — the wildcard `..\..\tuning\**\*.csproj` reference already
picks up new benchmark projects, so you usually change nothing here. Only create a runner when none
exists.

When creating one, default the folder name to `benchmark-runner` (matches the codebelt library
scaffold and `codebeltnet/xunit`). Copy `assets/benchmark-runner.csproj` and
`assets/benchmark-program.cs`. Substitutions:

| Placeholder | Value |
|-------------|-------|
| `{RUNNER_TARGET_FRAMEWORK}` | Highest supported non-preview executable TFM (`net10.0` or `net9.0`). |
| `{RUNNER_NAMESPACE}` | Runner folder name converted to a valid C# identifier (`benchmark-runner` -> `benchmark_runner`). |
| `{RUNTIME_USINGS}` | Empty for **Runner default only**. Otherwise emit `using Codebelt.Extensions.BenchmarkDotNet;`, `using BenchmarkDotNet.Configs;`, `using BenchmarkDotNet.Environments;`, and `using BenchmarkDotNet.Jobs;`, each terminated with a newline. The slim job and runtime-specific `AddJob` chain need all four namespaces. |
| `{RUNTIME_SETUP}` | Empty for **Runner default only**. Otherwise emit the indented `var slimJob = BenchmarkWorkspaceOptions.Slim;` declaration used by every configured runtime job. |
| `{RUNTIME_JOBS}` | Empty for **Runner default only** so the method stays `return c;`. Otherwise emit newline-prefixed chained `.AddJob(slimJob.WithRuntime(...))` calls, one per runtime to measure (see `benchmarkdotnet-essentials.md`). |

If the root `Directory.Build.props` does **not** mark tooling projects as executables, add
`<OutputType>Exe</OutputType>` and `<IsPackable>false</IsPackable>` to the runner `PropertyGroup`.

## 4. Solution wiring

- **`.slnx`**: add `<Project Path="tuning/{SutProject}.Benchmarks/{SutProject}.Benchmarks.csproj" />`
  under a `<Folder Name="/tuning/">` element, and the runner under `<Folder Name="/tooling/">`.
  Create the folders if absent. Example:

  ```xml
  <Folder Name="/tuning/">
    <Project Path="tuning/Acme.Core.Benchmarks/Acme.Core.Benchmarks.csproj" />
  </Folder>
  <Folder Name="/tooling/">
    <Project Path="tooling/benchmark-runner/benchmark-runner.csproj" />
  </Folder>
  ```

- **`.sln`**: run `dotnet sln <solution>.sln add <path-to-csproj>` for each new project. `dotnet`
  places them under solution folders automatically.

- **No solution file**: it is fine to leave projects unlisted; note it for the user. Do not fabricate
  a solution unless they ask.

## 5. `reports/` folder

Benchmark output is written under `reports/` by the Codebelt workspace. You do not need to pre-create
it; the runner creates it on first run. Mention it so the user knows where results land.

The standard runner sets `SkipBenchmarksWithReports = true`. Existing matching files under `reports/tuning/` deliberately filter their benchmark type from later list/dry/full invocations. Read `runner-preflight.md` before treating a skipped type as a benchmark-code defect.

## Guardrails

- Preserve UTF-8 (no BOM unless the source had one) when writing generated files; watch for mojibake.
- Do not commit or push; leave that to the user.
- If you cannot resolve a package version or cannot determine the SUT project, stop and report rather
  than guessing.
