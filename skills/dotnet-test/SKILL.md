---
name: dotnet-test
description: >
  Move .NET xUnit test projects onto Codebelt's entrypoint-owned test hosts, replacing Microsoft's WebApplicationFactory and hand-rolled host plumbing with WebApplicationTestFactory, WebApplicationTest, ApplicationTestFactory, and ApplicationTest — for ASP.NET Core, console, and worker applications alike. Invoking this skill IS the request: inspect the repository and refactor immediately, never opening with a menu, a capability list, or a questionnaire. Use for WebApplicationFactory migration, xUnit v2-to-v3 modernization, Microsoft Testing Platform adoption, managed fixtures, reusable functional-test harnesses, in-process console or worker tests, and unit-test bootstrap. Preserve behavior, test names, and package ownership, then validate restore/build/test. Do NOT use for NUnit/MSTest-only work, production refactoring without a test-project goal, or process-launching end-to-end harnesses.
compatibility: >
  Requires .NET SDK, PowerShell 7+, and network access to NuGet for dynamic package resolution.
---

# .NET Test

Bootstrap and refactor xUnit projects using the tested patterns from [Codebelt xUnit](https://github.com/codebeltnet/xunit) and the matching application-host patterns from [Codebelt Bootstrapper](https://github.com/codebeltnet/bootstrapper).

## This skill has one job

**The test host comes from Codebelt, not from Microsoft, and not from a builder you write in the test project.**

Microsoft ships `WebApplicationFactory<TEntryPoint>`, and it only covers ASP.NET Core. Everything else — console apps, workers, hosted services — has no Microsoft equivalent, so teams hand-roll a `HostBuilder` in the test project and end up testing a composition root that no deployed process ever runs. Codebelt xUnit closes both gaps with one family of abstractions where the application's own entry point owns startup:

| What the test needs | Codebelt gives you | Instead of |
|---|---|---|
| One host per test / per narrow harness (web) | `WebApplicationTestFactory.Create<TEntryPoint>(..., new ManagedWebApplicationFixture<TEntryPoint>())` | `new MyFactory() : WebApplicationFactory<Program>` |
| One host shared by a test class (web) | `WebApplicationTest<TEntryPoint, ManagedWebApplicationFixture<TEntryPoint>>` | `IClassFixture<WebApplicationFactory<Program>>` |
| One host per test / per narrow harness (console, worker) | `ApplicationTestFactory.Create<TEntryPoint>(..., new ManagedApplicationFixture<TEntryPoint>())` | a hand-built `HostBuilder` in the test project |
| One host shared by a test class (console, worker) | `ApplicationTest<TEntryPoint, ManagedApplicationFixture<TEntryPoint>>` | a static host cached in a test helper |

That substitution is the deliverable. A run that leaves `WebApplicationFactory` in place, or that swaps the type while quietly rebuilding the host in test code, has not done the job no matter how green the test run looks.

### What finishing looks like

One thing has to be true at the end: the Codebelt abstraction constructs the host, and nothing in the selected project derives from `WebApplicationFactory` any more. How you get there — file names, helper shapes, where settings come from — is yours to choose.

These rewrites feel like migrations and change nothing:

- **Wrapping the factory.** Keeping `WebApplicationFactory<Program>` as a private nested class, a renamed facade, or a field inside a new `...TestApplication` type. Microsoft's host still starts the application; the wrapper only hides that from the diff.
- **Renaming the seam.** Turning `new CdnOriginTestApplication()` into `CdnOriginTestApplication.Create()` across every test file. Every call site changes and the composition root does not.
- **Importing the namespace.** Adding `using Codebelt.Extensions.Xunit;` without ever calling `WebApplicationTestFactory.Create<TEntryPoint>` or deriving from `WebApplicationTest<,>`.
- **Bumping packages instead.** Raising `xunit*` or unrelated pins produces a busy diff that reads as effort. It is not the deliverable, and moving `xunit*` past the anchor in [Step 3](#step-3-resolve-packages-without-hardcoding-latest) breaks the very API you are migrating onto.

Every one of these shipped from a real run of this skill and was reported back as a successful migration, which is the point: from inside the run, a wrapper looks like progress, and the tests stay green because the host never changed. That is why [Step 7](#step-7-validate-and-loop) ends in a verdict a script produces rather than a summary you write. Either `WebApplicationTestFactory`, `WebApplicationTest<,>`, `ApplicationTestFactory`, or `ApplicationTest<,>` appears in the project's own source, or the migration did not happen.

## Do this now

**You were invoked. That is the request.** Your first action is the inspector in [Step 1](#step-1-gather-evidence-before-asking-anything) — not a question, not a menu, not a plan.

The inspector answers, from the repository itself, essentially every question you might be tempted to ask: which test projects exist, what role each one plays, whether it is already on xUnit v3 and Microsoft Testing Platform, who owns each package version, every `WebApplicationFactory` and managed-fixture usage with file and line, whether the referenced application has a Generic Host seam, and what the recommended migration is. Asking the developer to hand-type answers the JSON already contains costs them a turn and tells you nothing new.

**Forbidden as a first response:** a numbered menu of things this skill could do; "bootstrap vs refactor vs improve coverage"; "would you like me to run a diagnostic scan first?"; listing capabilities; asking which project, role, or host ownership to use before the inspector has run. If you are about to write "What do you want to do?", run the inspector instead — its output makes the question obsolete.

There is exactly one shape of legitimate question, and it comes *after* the evidence: the inspector reported a real blocker, or its evidence genuinely contradicts what the request asked for. See [Step 1](#step-1-gather-evidence-before-asking-anything).

## Critical

- Inspect before editing. Run `scripts/inspect-dotnet-tests.ps1` against the selected project and treat its role, package ownership, `WebApplicationFactory` inventory, and blockers as the starting contract.
- Classify every selected project as exactly one of: **Ordinary unit test**, **ASP.NET Core functional test**, or **Console or worker functional test**.
- Treat the selected Codebelt host abstraction as an output contract. Removing `WebApplicationFactory` is not a migration unless focused web tests use `WebApplicationTestFactory` or shared web tests use `WebApplicationTest<TEntryPoint, T>`.
- Use entrypoint-owned `ManagedWebApplicationFixture<TEntryPoint>` and `ManagedApplicationFixture<TEntryPoint>` for new and migrated functional tests. Do not emit their deprecated blocking variants; they are scheduled for removal.
- Do not reconstruct an application entry point inside test code with `WebApplication.CreateBuilder`, `WebHostBuilder`, `HostBuilder`, `UseTestServer`, copied service registrations, or copied middleware. That creates a second composition root which can pass while the real `Program` is broken.
- Preserve target frameworks, central package management, unrelated MSBuild configuration, existing test names, and test isolation.
- Never take an `xunit*` package past the major the Codebelt xUnit release depends on. The resolver anchors that ceiling in [Step 3](#step-3-resolve-packages-without-hardcoding-latest); newest-on-NuGet is not it.
- Edit files you are actually changing, in place. Rewriting a file wholesale flips its line endings and makes `git status` report churn that reviewers must read to discover it means nothing; a file with no semantic change must not appear in the diff at all.
- Replace every selected `WebApplicationFactory` usage. A partial migration that leaves a selected usage or package reference behind is incomplete, and a usage moved inside a wrapper type is still a usage.
- Finish on the verdict from `scripts/verify-dotnet-test-migration.ps1`, quoted as it printed. Reporting a migration complete without it leaves the one claim that matters unverified.
- Keep functional testing in-process. Never add a process-launching fallback for console or worker applications.
- If a selected executable has no Generic Host, adapt production startup only when application adaptation is explicitly in scope. Otherwise report the exact missing host seam and stop before changing production startup.
- During bootstrap, add at least one test derived from real source behavior. Placeholder assertions such as `Assert.True(true)` do not satisfy the task.
- When the request requires restore/build/test, `dotnet test` must discover the expected non-zero test count and report zero failures. An MTP executable run may supplement that gate but never replaces it; if `dotnet test` discovers zero tests, add or restore the repository-appropriate `xunit.runner.visualstudio` adapter and rerun.

## Step 1: Gather evidence before asking anything

Run the inspector first. Omit `-ProjectPath` when the request did not name a project — the inspector then discovers and classifies every test project itself:

```powershell
pwsh -NoProfile -File "<skill-root>/scripts/inspect-dotnet-tests.ps1" -RepoRoot "<repo-root>" [-ProjectPath "<project-path>"]
```

`<skill-root>` is the directory containing this `SKILL.md`; quote both paths. Keep stdout as JSON. A non-zero exit or a reported blocker is a real stop condition.

Now read the JSON and resolve the `FORMS.md` fields from it. Almost always, all of them resolve and you proceed straight to Step 2 without asking anything:

| `FORMS.md` field | Resolved by | Ask only when |
|---|---|---|
| `project_selection` | the request naming a project, or `projects[]` containing exactly one | `projects[]` has several and the request does not narrow them |
| `operation_mode` | tests present in the selected project → refactor; none → bootstrap | never — this is a fact about the repository, not a preference |
| `test_role` | `projects[].role` | `role` contradicts what the request explicitly asked for |
| `application_adaptation` | `referencedApplications[].genericHost` is `true` → not applicable | a missing-Generic-Host blocker is reported |
| `host_ownership` | a factory constructed per test method → focused; `IClassFixture` or one shared host → shared | usage is genuinely mixed and the request does not say |
| `confirmation` | the request itself | mutation would exceed the scope the request authorized |

Read `FORMS.md` only when a row above actually lands in its "ask" column; it is the fallback for genuine ambiguity, not an intake wizard to run up front. When you do ask, ask that one field alone, state the evidence that made it ambiguous, and carry every already-resolved field forward silently.

Do not broaden a single-project request to every test project.

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
pwsh -NoProfile -File "<skill-root>/scripts/resolve-test-package-versions.ps1" -TargetFramework <tfm> -Role <Unit|WebFunctional|ApplicationFunctional> [-XunitAnchorVersion <codebelt-xunit-version>]
```

The resolver queries NuGet stable versions, tries newer candidates first, and verifies each candidate against the selected package set through isolated compatibility-project restores; it emits only a set whose combined package restore passes. If it fails, report the package, target frameworks, and restore evidence instead of guessing.

**Newest is not the ceiling for `xunit*`.** xUnit versions its own packages on its own schedule — `xunit.v3` and `xunit.runner.visualstudio` are both past 4.0.0 while [Codebelt xUnit](https://github.com/codebeltnet/xunit) still builds against the 3.x line — so "latest stable" would push a test project a whole xUnit generation past the Codebelt API it is supposed to use. The resolver therefore anchors every `xunit*` id to the Codebelt package for the role (`Codebelt.Extensions.Xunit` for `Unit`, `Codebelt.Extensions.Xunit.App` otherwise), reading the anchor's own published nuspec dependencies:

- an id the anchor declares — today `xunit.v3.assert` and `xunit.v3.extensibility.core` — resolves **1:1** to the exact version the anchor declares;
- every other `xunit*` id resolves to the newest minor/patch **at or below the anchor's major**;
- nothing else is capped, and the anchored evidence is reported back under `xunitAnchor` plus a per-package `constraint`.

Pass `-XunitAnchorVersion` with the `Codebelt.Extensions.Xunit*` version the repository already references — the inspector reports it under `packageOwnership` — whenever that pin is being kept, so the resolved xUnit generation matches the Codebelt release actually in use rather than the newest one on NuGet. Omit it to anchor on the newest Codebelt release. Never hand-pick an `xunit*` version above the reported anchor major; if a project genuinely needs the next xUnit generation, the Codebelt package has to move there first.

When a benchmark or smoke harness provides `DOTNET_TEST_MAXIMUM_CANDIDATES`, `DOTNET_TEST_RESOLVER_CACHE_DIR`, or `DOTNET_TEST_RESOLVER_TRACE_FILE`, honor that measured scope instead of widening the live search again. Use a small explicit candidate limit for ordinary eval smoke runs; fallback and combined-package behavior stay covered by `scripts/test-resolve-test-package-versions.ps1`.

The managed fixtures this skill targets do not exist below Codebelt xUnit **11.1.0**. A project pinned under that floor restores and builds fine today and then fails to compile the moment you write the pattern, so treat the inspector's version-floor recommendation as a prerequisite edit rather than advice — raise it in the owning props file before Step 4.

Apply the smallest change that makes the target pattern compile. The resolver returns a complete latest-compatible set because it verifies the set as a whole, not because every member needs to move; adopting all of it turns a test-host migration into a repo-wide dependency bump the request never asked for. Bump what the pattern requires, leave working pins alone, and mention the rest as available rather than applying it.

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

For a migration, run the gate before anything expensive — it is static analysis and it fails in seconds, so there is no reason to spend a restore and a full test run discovering that the host never moved:

```powershell
pwsh -NoProfile -File "<skill-root>/scripts/verify-dotnet-test-migration.ps1" -RepoRoot "<repo-root>" -ProjectPath "<project-path>" -ExpectedWebPattern <Focused|Shared>
```

Use `-ExpectedApplicationPattern <Focused|Shared>` instead for a console or worker migration. The gate reruns the inspector under that postcondition and adds the checks that can only exist once the edits do: a type still deriving from `WebApplicationFactory`, a retained `Microsoft.AspNetCore.Mvc.Testing` reference, `xunit*` pins past the major the restored Codebelt package declares, and files changed under the project while the target pattern appears zero times. Exit 0 prints `PASSED`, exit 1 prints `FAILED` with numbered violations and their file and line, and exit 2 means the gate itself could not run.

Treat `FAILED` as the answer to "is this done", not as advice. Each violation names what to change; fix them and rerun. Do not restate the verdict in your own words, and do not move on to the completion report while it still says `FAILED`.

Then run the narrowest authoritative sequence that covers the selected change:

1. restore the selected test project;
2. build the selected test project;
3. run `dotnet test` when restore/build/test was requested and confirm the expected non-zero test count with zero failures; a zero-discovery exit code is a failure and `dotnet run` is not a substitute;
4. inspect the final diff for target-framework, package-owner, test-name, and unrelated-change drift;
5. rerun the gate as the last action, after the final edit. An earlier `PASSED` describes an earlier state of the files, and the verdict you quote has to describe the ones you are handing over.

If tests expose a migration regression, repair the preserved lifecycle or configuration behavior rather than weakening assertions.

## Completion report

Report:

- selected project and classified role;
- mode and whether production application adaptation was in scope;
- package ownership and resolved versions, including the Codebelt xUnit anchor that bounded the `xunit*` versions;
- preserved migration invariants;
- behavior test added or existing tests retained;
- exact restore/build/test results;
- the verdict block from the final `verify-dotnet-test-migration.ps1` run, pasted as it printed. It is the evidence for the migration claim, so a paraphrase or a remembered result from earlier in the session does not stand in for it;
- blockers or validation limits.
