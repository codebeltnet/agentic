---
name: dotnet-benchmark
description: >
  Set up and author BenchmarkDotNet performance tests for a specific .NET type following codebelt
  engineering conventions, using Codebelt.Extensions.BenchmarkDotNet and its Console runner. Use this
  skill whenever the user wants to benchmark, micro-benchmark, performance-test, profile throughput or
  allocations, or measure the speed of a .NET type or method, in new or existing projects. It first
  checks that the benchmark harness and prerequisites exist and sets up anything missing in place
  (tuning/ benchmark project, tooling/ runner host, package references, solution wiring), then inspects
  the target type and picks a complexity-appropriate strategy, authoring the benchmark class in the same
  namespace as the code it measures. Trigger phrases include "add a benchmark", "benchmark this class",
  "set up BenchmarkDotNet", "performance test", "micro-benchmark", or "measure allocations". Also use it
  when a repo already has a tuning/ or *.Benchmarks project and wants more benchmarks.
---

# .NET Benchmark Setup (Codebelt Conventions)

Make it easy to performance-test a .NET **type** with [BenchmarkDotNet](https://benchmarkdotnet.org/)
the codebelt way, wiring the benchmark into the same `tuning/` + `tooling/` layout used across
[codebeltnet](https://github.com/codebeltnet). This skill works for a repo that already has a
benchmark harness *and* one that has none: it detects what exists and adds only what is missing.

The two reference implementations this skill mirrors are `codebeltnet/cuemon` and
`codebeltnet/xunit`. When in doubt about a convention, default to how those repos do it. The
[`Codebelt.Extensions.BenchmarkDotNet`](https://benchmarkdotnet.codebelt.net/api/Codebelt.Extensions.BenchmarkDotNet.html)
namespace and its `.Console` companion supply the runner host (`BenchmarkProgram.Run`), so you never
hand-roll a `BenchmarkSwitcher`.

## Why this layout

Benchmarks are split across three sibling folders so they never leak into shippable output:

- `tuning/{SutProject}.Benchmarks/` holds the benchmark **projects and classes** that reference the
  code under test.
- `tooling/{runner}/` holds one executable **runner host** that discovers every `tuning/` project
  and runs it through the Codebelt console bootstrapper.
- `reports/` receives the generated benchmark artifacts.

Keeping the runner in `tooling/` and the benchmarks in `tuning/` means the packable `src/` projects
stay clean, and a single runner can drive many benchmark projects.

## Workflow

Do the steps in order. Each step explains *why* so you can adapt when a repo does not match the
happy path — real existing repos rarely do.

### Step 1: Check requirements

Run the detection script to learn the repo's current state in one pass instead of guessing:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/check-benchmark-requirements.ps1 -RepoRoot <repo-root>
```

It reports, as JSON: whether the .NET SDK is available (and version), the solution file(s) and their
format (`.slnx` vs `.sln`), whether Central Package Management (`Directory.Packages.props`) is used,
whether the root `Directory.Build.props` already centralizes benchmark/tooling conventions
(`IsBenchmarkProject` / `IsToolingProject`), any existing `tuning/*.Benchmarks` projects, and any
existing `tooling/` runner host (its folder name and whether it references
`Codebelt.Extensions.BenchmarkDotNet.Console`).

The one hard prerequisite is the **.NET SDK**. If it is missing, stop and ask the user to install it
(the runner host targets .NET 9 or .NET 10, matching `Codebelt.Extensions.BenchmarkDotNet`
availability). Everything else in the harness this skill can create for them.

### Step 2: Onboard the missing harness (in place)

Add only what Step 1 found missing, matching the repo's existing layout. Do not restructure a repo or
convert its solution format. Read `references/onboarding.md` for the detailed decision tree; the
essentials:

- **Packages.** Resolve the latest stable listed versions from NuGet.org (never hardcode) for
  `BenchmarkDotNet`, `BenchmarkDotNet.Diagnostics.Windows`, and
  `Codebelt.Extensions.BenchmarkDotNet.Console`. If the repo uses Central Package Management, add
  `<PackageVersion>` entries to `Directory.Packages.props` and reference them without versions;
  otherwise put versioned `<PackageReference>`s directly in the project files.
- **Benchmark project.** Create `tuning/{SutProject}.Benchmarks/{SutProject}.Benchmarks.csproj` from
  `assets/benchmark.csproj`, referencing the SUT `src/` project and overriding `RootNamespace` to the
  SUT root namespace (so the benchmark lives in the measured namespace, not a `.Benchmarks` one).
- **Runner host.** If no `tooling/` runner exists, create one from `assets/benchmark-runner.csproj`
  and `assets/benchmark-program.cs`. Default its folder name to `benchmark-runner`; if the repo
  already has a runner (e.g. cuemon's `bdn-runner`), reuse it — do not add a second one.
- **Central conventions vs plain repo.** If the root `Directory.Build.props` already centralizes
  `IsBenchmarkProject`/`IsToolingProject` (as codebelt repos do), keep the benchmark `.csproj`
  minimal and let the props inject TFMs and BDN packages. If it does not, the project files must
  declare their own `TargetFrameworks` and package references — `references/onboarding.md` shows both.
- **Solution wiring.** Add the new projects to the detected solution: for `.slnx`, add
  `<Project Path="..." />` entries under `/tuning/` and `/tooling/` folders; for `.sln`, use
  `dotnet sln <file> add <csproj>`.

### Step 3: Resolve the target type

Ask which type to performance-test if the user has not already named one. Then locate it in the
source tree to learn its namespace, owning `src/` project, and public surface (constructors,
methods, properties, and any obvious size- or variant-sensitive inputs). You need the namespace to
place the benchmark correctly and the surface to choose meaningful scenarios.

### Step 4: Choose a strategy by complexity

The user asked for a *thorough* performance test, so pick the approach that fits the type instead of
applying one rigid template. Read `references/benchmarkdotnet-essentials.md` for the attribute and
job toolbox and `references/codebelt-conventions.md` for the two default tiers:

- **Simple type** (value-like, no size-sensitive input): benchmark the meaningful members as
  discrete scenarios with a clear `Baseline = true` anchor, grouped
  `[GroupBenchmarksBy(BenchmarkLogicalGroupRule.ByCategory)]`. Template: `assets/simple-benchmark.cs`
  (mirrors cuemon `DateSpanBenchmark`).
- **Complex / size- or variant-sensitive type** (hashing, parsing, buffers, algorithm variants): use
  `[Params]` to sweep input sizes and/or variants, prepare deterministic payloads in `[GlobalSetup]`,
  and compare implementations against a baseline. Template: `assets/params-benchmark.cs` (mirrors
  cuemon `Sha512256Benchmark` and xunit `TestBenchmark`).

Briefly tell the user which tier you chose and why, then let them adjust (e.g. specific methods,
input sizes, or a competing implementation to compare against). Every benchmark uses
`[MemoryDiagnoser]` so allocations are always captured.

### Step 5: Author and wire the benchmark class

Write the benchmark into `tuning/{SutProject}.Benchmarks/` following codebelt naming exactly, because
these rules keep type discovery and reports consistent:

- Class name ends with `Benchmark` (e.g. `DateSpanBenchmark`).
- Namespace is the **same** as the SUT — never suffix `.Benchmarks`. The `RootNamespace` override in
  the project file is what makes this compile cleanly.
- Methods use descriptive scenario names (`Parse_Short`, `ComputeHash_Large`) and a `Description` for
  readable reports; mark the reference method `Baseline = true`.
- Use deterministic data and no external systems (no network, disk, or DB) so runs are repeatable.

If the type belongs to a `src/` project that has no `tuning/{SutProject}.Benchmarks` yet, create that
project (Step 2 rules) before adding the class, then make sure the runner discovers it (the wildcard
`..\..\tuning\**\*.csproj` reference already covers new projects) and the solution lists it.

### Step 6: Verify the build, then hand off the run

Confirm the benchmark compiles in Release, since BenchmarkDotNet only runs Release builds:

```powershell
dotnet build -c Release tuning/{SutProject}.Benchmarks/{SutProject}.Benchmarks.csproj
```

Do **not** run the benchmark by default — real runs are slow and heavy. Offer to run it, and give the
exact command so the user can run it when ready. The runner is a console app that accepts BenchmarkDotNet
filters:

```powershell
dotnet run -c Release --project tooling/{runner} -- --filter *{TypeName}Benchmark*
```

Reports land under `reports/`. Only run it yourself if the user explicitly asks.

### Multi-runtime jobs (optional)

`Codebelt.Extensions.BenchmarkDotNet` runs on .NET 9/10, but its BenchmarkDotNet **jobs** can measure
other runtimes. If the user wants to compare across runtimes, add jobs in the runner's `Program.cs`
using `slimJob.WithRuntime(...)` — e.g. `ClrRuntime.Net48` (older .NET Framework),
`CoreRuntime.Core80/90/10_0`. xunit's runner does exactly this. See
`references/benchmarkdotnet-essentials.md` for the moniker map.

## Conventions checklist

Before finishing, verify:

- [ ] `.NET SDK` present; runner host targets net9.0 or net10.0
- [ ] Benchmark class ends with `Benchmark` and lives in the SUT's namespace (no `.Benchmarks` suffix)
- [ ] Benchmark project sets `<RootNamespace>` to the SUT root and references the SUT `src/` project
- [ ] `[MemoryDiagnoser]` present; a `Baseline = true` method anchors the comparison
- [ ] Deterministic data only — no network/disk/DB in measured methods
- [ ] Packages resolved from NuGet.org (no hardcoded versions); CPM vs `PackageReference` matches the repo
- [ ] Exactly one `tooling/` runner host; new benchmark project added to the detected `.slnx`/`.sln`
- [ ] Release build succeeds; run command provided (benchmark not run unless requested)
- [ ] Generated files are UTF-8 with no mojibake
