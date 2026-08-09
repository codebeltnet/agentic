---
name: dotnet-test
description: >
  Bootstrap or refactor .NET xUnit test projects to Codebelt conventions. Use for unit-test setup, xUnit v2-to-v3 modernization, Microsoft Testing Platform adoption, ASP.NET Core WebApplicationFactory migration, entrypoint-owned managed fixtures, reusable functional-test harnesses, and in-process console or worker tests. Classify the selected project, preserve behavior and test names, resolve compatible stable packages from NuGet, and validate restore/build/test. Do not use for NUnit/MSTest-only work, production refactoring without a test-project goal, or process-launching end-to-end harnesses.
compatibility: >
  Requires .NET SDK, PowerShell 7+, and network access to NuGet for dynamic package resolution.
---

# .NET Test

Bootstrap and refactor xUnit projects using the tested patterns from [Codebelt xUnit](https://github.com/codebeltnet/xunit) and the matching application-host patterns from [Codebelt Bootstrapper](https://github.com/codebeltnet/bootstrapper).

## Critical

- Inspect before editing. Run `scripts/inspect-dotnet-tests.ps1` against the selected project and treat its role, package ownership, `WebApplicationFactory` inventory, and blockers as the starting contract.
- Classify every selected project as exactly one of: **Ordinary unit test**, **ASP.NET Core functional test**, or **Console or worker functional test**.
- Treat the selected Codebelt host abstraction as an output contract. Removing `WebApplicationFactory` is not a migration unless focused web tests use `WebApplicationTestFactory` or shared web tests use `WebApplicationTest<TEntryPoint, T>`.
- Use entrypoint-owned `ManagedWebApplicationFixture<TEntryPoint>` and `ManagedApplicationFixture<TEntryPoint>` for new and migrated functional tests. Do not emit their deprecated blocking variants; they are scheduled for removal.
- Do not reconstruct an application entry point inside test code with `WebApplication.CreateBuilder`, `WebHostBuilder`, `HostBuilder`, `UseTestServer`, copied service registrations, or copied middleware. That creates a second composition root which can pass while the real `Program` is broken.
- Preserve target frameworks, central package management, unrelated MSBuild configuration, existing test names, and test isolation.
- Replace every selected `WebApplicationFactory` usage. A partial migration that leaves a selected usage or package reference behind is incomplete.
- Keep functional testing in-process. Never add a process-launching fallback for console or worker applications.
- If a selected executable has no Generic Host, adapt production startup only when application adaptation is explicitly in scope. Otherwise report the exact missing host seam and stop before changing production startup.
- During bootstrap, add at least one test derived from real source behavior. Placeholder assertions such as `Assert.True(true)` do not satisfy the task.
- When the request requires restore/build/test, `dotnet test` must discover the expected non-zero test count and report zero failures. An MTP executable run may supplement that gate but never replaces it; if `dotnet test` discovers zero tests, add or restore the repository-appropriate `xunit.runner.visualstudio` adapter and rerun.

## Step 1: Resolve scope and inputs

Read `FORMS.md`. Infer fields already answered by the request or repository. Ask only for unresolved fields, one at a time, and confirm the final summary before mutation.

Resolve the repository root and selected `.csproj` path. Do not broaden a single-project request to every test project.

Run:

```powershell
pwsh -NoProfile -File "<skill-root>/scripts/inspect-dotnet-tests.ps1" -RepoRoot "<repo-root>" -ProjectPath "<project-path>"
```

Keep stdout as JSON. Treat a non-zero exit or a reported blocker as a real stop condition.

## Step 2: Classify the project

Use the inspection evidence, then read only the matching role reference:

| Role | Evidence | Required reference |
|---|---|---|
| Ordinary unit test | No application entry-point hosting boundary is exercised | `references/unit-tests.md` |
| ASP.NET Core functional test | HTTP pipeline, `WebApplicationFactory`, TestHost, or an ASP.NET Core entry point is exercised | `references/web-functional-tests.md` |
| Console or worker functional test | A Generic Host console/worker entry point or hosted service is exercised without an ASP.NET Core HTTP pipeline | `references/application-functional-tests.md` |

If the evidence conflicts with the requested role, report the conflict and ask before applying a materially different pattern.

## Step 3: Resolve packages without hardcoding latest

Run the resolver for the selected target frameworks and role:

```powershell
pwsh -NoProfile -File "<skill-root>/scripts/resolve-test-package-versions.ps1" -TargetFramework <tfm> -Role <Unit|WebFunctional|ApplicationFunctional>
```

The resolver queries NuGet stable versions, tries newer candidates first, and verifies each candidate against the selected package set through isolated compatibility-project restores; it emits only a set whose combined package restore passes. If it fails, report the package, target frameworks, and restore evidence instead of guessing.

Preserve package ownership:

- Central Package Management: update or add `PackageVersion` in the owning `Directory.Packages.props`; keep project `PackageReference` items versionless.
- Project-owned versions: update only the selected `.csproj` unless the user expands scope.
- Imported/shared ownership: edit the actual owning props file only when it is inside the authorized scope; otherwise report the required owner change.

Read `references/xunit-v3-modernization.md` whenever inspection reports xUnit v2 or Microsoft Testing Platform is not active.

## Step 4: Apply the role pattern

### Ordinary unit tests

- Inherit `Test` or the repository's established `Test`-derived base.
- Accept `ITestOutputHelper output` and pass it to the base constructor.
- Keep the SUT namespace; use file-scoped namespaces for new files.
- Preserve existing test method names during refactoring.
- Name new tests `Should{Expected}_When{Condition}`.

### Focused ASP.NET Core functional tests

- Keep the test class derived from `Test`.
- Use `WebApplicationTestFactory.Create<TEntryPoint>(..., new ManagedWebApplicationFixture<TEntryPoint>())` per focused test or per deliberately owned test scope. Pass the managed fixture explicitly so the application entry point owns startup instead of silently taking the factory's deprecated blocking default.
- Keep the production entry point as `TEntryPoint`; configure its host through the factory callback instead of building a replacement `WebApplication` in the test project.
- Create the client from `application.Host.GetTestClient()` or the returned `TestServer` as appropriate.
- Dispose the factory result, clients, responses, and owned external resources at the same effective lifecycle as before.

### Shared ASP.NET Core fixtures

- Derive the test class from `WebApplicationTest<TEntryPoint, ManagedWebApplicationFixture<TEntryPoint>>`, or from an established fixture derived from `ManagedWebApplicationFixture<TEntryPoint>` that preserves entrypoint-owned startup.
- Accept the fixture and `ITestOutputHelper` in the constructor and pass both to the base.
- Put shared host customization in `ConfigureWebHost` or a narrowly derived fixture when configuration must exist before the first host start.

### Focused console or worker functional tests

- Keep the test class derived from `Test`.
- Use `ApplicationTestFactory.Create<TEntryPoint>(..., new ManagedApplicationFixture<TEntryPoint>())` and inspect services/configuration through the returned host test. Pass the fixture explicitly so `Main` remains the startup owner.

### Shared console or worker fixtures

- Derive from `ApplicationTest<TEntryPoint, ManagedApplicationFixture<TEntryPoint>>`, or from an established fixture derived from `ManagedApplicationFixture<TEntryPoint>` with the same lifecycle.
- Accept the fixture and `ITestOutputHelper` in the constructor and pass both to the base.
- Put host customization in `ConfigureHost`.

Treat `BlockingManagedWebApplicationFixture<TEntryPoint>` and `BlockingManagedApplicationFixture<TEntryPoint>` only as deprecated input to migrate away from. Never emit them in generated or refactored code.

For fresh console or worker applications, read `references/bootstrapper-hosts.md` and adapt the matching assets. Do not substitute a vanilla process runner.

Preserve an existing Bootstrapper host family. `MinimalConsoleProgram`, `MinimalWorkerProgram`, and `MinimalWebProgram` are valid Generic Host seams; do not convert them to their Startup-based counterparts merely to enable tests.

## Step 5: Migrate behavior, not just types

For any `WebApplicationFactory` migration, read `references/migration-invariants.md` before editing. Inventory and preserve:

- host and application configuration;
- environment selection;
- service replacement and registration order;
- lazy-start or first-client behavior;
- client options, base address, handlers, and cookies;
- direct host, server, services, and configuration access;
- sync and async disposal;
- temporary files, ports, databases, and other isolation boundaries.

Delete `Microsoft.AspNetCore.Mvc.Testing` only when no selected code or remaining authorized project surface needs it. After edits, search the selected scope for both `WebApplicationFactory` and `Microsoft.AspNetCore.Mvc.Testing`.

A helper may prepare settings and temporary resources. When many focused tests repeat the same application setup, a narrow `Test`-derived harness may own `WebApplicationTestFactory.Create<TEntryPoint>` or `ApplicationTestFactory.Create<TEntryPoint>`, accept `ITestOutputHelper`, expose only the host/client and domain-specific resources the tests need, and preserve one harness instance per intended isolation scope. It must dispose both the returned `IHostTest` and every owned resource through the matching synchronous and asynchronous `Test` disposal hooks. It must not build, start, stop, or dispose a replacement host, and must not replay statements from `Program`.

## Step 6: Bootstrap a behavior test

Read the selected production source, its public behavior, and nearby tests. Choose the lowest-cost deterministic behavior that could catch a real defect. Adapt the matching asset rather than copying it literally:

- `assets/unit/BehaviorTest.cs`
- `assets/web/FocusedWebApplicationTest.cs`
- `assets/web/SharedWebApplicationTest.cs`
- `assets/application/FocusedApplicationTest.cs`
- `assets/application/SharedApplicationTest.cs`

Replace every placeholder with repository evidence. Do not invent an endpoint, service, configuration key, or expected result.

## Step 7: Validate and loop

Run the narrowest authoritative sequence that covers the selected change:

1. rerun `inspect-dotnet-tests.ps1`; for a web migration, pass `-ExpectedWebPattern Focused` or `-ExpectedWebPattern Shared`; for a console/worker migration, pass `-ExpectedApplicationPattern Focused` or `-ExpectedApplicationPattern Shared`. These gates require the selected Codebelt pattern with an entrypoint-owned managed fixture and reject legacy factories, deprecated blocking fixtures, and direct replacement-host construction;
2. restore the selected test project;
3. build the selected test project;
4. run `dotnet test` when restore/build/test was requested and confirm the expected non-zero test count with zero failures; a zero-discovery exit code is a failure and `dotnet run` is not a substitute;
5. for migrations, search the selected scope and confirm zero remaining `WebApplicationFactory` usages; do not treat that zero count as sufficient without the expected-pattern postcondition;
6. inspect the final diff for target-framework, package-owner, test-name, and unrelated-change drift.

If tests expose a migration regression, repair the preserved lifecycle or configuration behavior rather than weakening assertions.

## Completion report

Report:

- selected project and classified role;
- mode and whether production application adaptation was in scope;
- package ownership and resolved versions;
- preserved migration invariants;
- behavior test added or existing tests retained;
- exact restore/build/test and zero-usage-search results;
- blockers or validation limits.
