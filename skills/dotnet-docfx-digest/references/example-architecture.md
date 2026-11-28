# Design examples around the developer task

Read this before reviewing, modifying, or writing examples involving framework integration, dependency injection, authentication, middleware, hosting, testing frameworks, multi-file/project graphs, or partial excerpts. Keep package-ID-first discovery and the existing project packets. A compilation success is one kind of evidence, not approval of the example's architecture.

## Design contract

Before source generation, establish these facts from public contracts, implementation, tests, package READMEs, or maintained consumer examples. Record them briefly in the existing example inventory, not in a new manifest:

- **Intention:** the concrete question the developer wants answered, such as verifying a worker application's service registration.
- **Required context:** actual target framework/asset, package and namespace, application type, DI/configuration, host/infrastructure, project references, and which project owns each file. Distinguish published packages from unpublished source references; do not invent pins or assume ASP.NET Core merely because an API uses hosting.
- **Behavior:** a returned value, resolved application service, configuration value, HTTP response, assertion, lifecycle event, or relevant failure that answers that question. Construction, runtime type names, metadata, and decorative logging are insufficient.
- **Reproduction:** the exact build/run/test command, prerequisites, and observation to check. Identify the evidence as compilation only, executed behavior, or unverified. Retain failures and unavailable prerequisites; never turn them into success by weakening the scenario.

Use the sequence **Discover API → Understand consumer task → Determine execution topology → Find authoritative usage → Design example → Write source → Validate → Improve explanation → Publish**. The reader should understand why, what must exist, how to use it, what happens, and how to check it, without requiring five headings on every page.

During that same discovery, consider optional [contextual source references](contextual-source-references.md) for useful integration or lifecycle depth. Explain the additional knowledge each link offers after the self-sufficient example, outcome and execution guidance. This applies to successfully runnable examples as well as partial illustrations; source browsing never replaces the primary learning experience.

## Discover consumer usage

Before writing a type or extension-method example, choose the smallest real task that explains the API in context. Prefer authoritative C# source and maintained consumer examples when establishing intended API usage; retain reflection and metadata discovery for public API surfaces and framework availability, and do not introduce IL analysis or decompilation when authoritative source is available. Start from package-level evidence, then narrow to type-level evidence:

1. Resolve the documented UID to its declaring type, owning project and package ID using the existing public API inventory and project packets. Confirm package identity from packable projects, `.nuget/*/README.md`, package release notes, `Directory.Packages.props`, or `PackageReference` usage as needed.
2. Search local evidence for the exact package ID first, including README files, package docs, samples, tooling projects, tuning projects, functional tests, and generated package documentation.
3. When internet or GitHub search is available and allowed, search for the exact package ID and prefer consumer repositories outside the target repository. Treat self-repo hits as package-authored docs or samples, not independent usage proof.
4. After inspecting package-ID evidence, search the owning project and the projects that reference it. When the source repository is available, use its existing project graph, package identities, public API inventory, reverse project dependencies (`ProjectReference` edges), tests, samples and consumer applications to discover complementary APIs; check direct dependents first, then follow relevant transitive dependents when the scenario calls for it, including relevant projects outside the DocFX metadata inputs and evaluated references when imports or conditions affect the graph. For external NuGet dependencies, prefer authoritative source matching the consumed package version; where necessary and available, use package repository metadata and SourceLink information to locate the exact revision and acquire it on demand through a shallow, revision-pinned checkout rather than downloading unnecessary Git history. Apply progressive disclosure to source exploration: search broadly with inexpensive, targeted queries within candidate projects and maintained usage sites, and read only relevant files. Inspection can cross project boundaries while the requested UID and repair scope still govern edits and verification.
5. Search by namespace, type and member name for public extension methods, factories, builders, registration, configuration, acquisition and other convenience APIs that use or compose the type. Inspect signatures, including return types and generic arguments, and follow method bodies and delegated implementation code. The documented type may appear only in a registration or factory implementation. Follow related abstractions such as service interfaces and options to their owning projects and check their dependents or companion packages for complementary setup.
6. Confirm the intended call sequence and its observed behavior in maintained tests, samples or consumer applications. When the ecosystem provides established public registration, configuration, acquisition, factory, builder or convenience APIs for the documented consumer scenario—including APIs from published companion packages even when documenting a type in a lower-level package—use those APIs rather than manually reconstructing equivalent infrastructure. Minimizing package dependencies must not take precedence over idiomatic consumer usage: a necessary companion package is a legitimate dependency once you verify its package availability, version compatibility, target frameworks, required namespace imports and supporting project or framework dependencies. Lower-level composition is appropriate only when no suitable higher-level API exists or when the documented scenario specifically demonstrates customization, infrastructure internals or container-independent usage.
7. Pick a scenario that connects the documented type to the package workflow. A good sample can include multiple related public types, a small local helper type, dependency-injection setup, host setup, options configuration, file/path setup, or result inspection when that is what a real caller would do.
8. Determine execution topology before generating source: standalone, library consumer, multi-file/project, framework/application integration, or partial excerpt. Remove incidental test scaffolding for ordinary APIs; retain real `[Fact]` methods, fixture constructors, assertions and runner semantics when the documented API is a testing abstraction. Keep meaningful setup and result inspection.
9. Prefer domain-specific names such as `BenchmarkRunner`, `WorkspaceUsage`, or `HttpRetryExample` over `Consumer` and `MyNamespace` when the package domain is clear.
10. Reject metadata-only substitutes before writing: `Type.GetType`, assembly lookup, `typeof`/`nameof` as the only operation, generic `Describe()` helpers, and repeated UID sections do not demonstrate a consumer task.
11. Confirm the C# fence itself uses the documented type or invokes the documented extension method. Mentions outside the fence do not count.
12. Reject runtime-type-name substitutes such as `host.Services.GetType().Name` or `service.GetType().FullName`. These reveal implementation metadata rather than the application behavior the API enables.
13. For entry-point factories and fixtures, never declare an empty local `Program` merely to satisfy compilation. Show a real entry point or name the application-project prerequisite, then make the example's result depend on a service, configuration value, endpoint, or lifecycle event supplied by that application.
14. Preserve application-owned startup and service registration. Explain executable versus test-runner entry points, references, lifecycle and infrastructure. Use labelled source files bound to maintained projects for a coherent multi-file scenario; never concatenate unrelated fences or independently compile fragments to manufacture success. If a type page becomes unwieldy, keep its essential usage and link directly to a maintained integration test or conceptual walkthrough.

For new, revised and converted examples, apply the observation checks in [behavioral repair](repair.md#check-one-example).

## Choose the execution model

| Classification | Presentation and verification |
| --- | --- |
| Standalone executable | Complete source, with `// Program.cs` for an ordinary executable DocFX fence. Use csrun for compatible console or genuine xUnit v3 execution; do not simulate test execution. |
| Ordinary library usage | Concise namespace/type-based consumer code, necessary imports/setup, and meaningful result. Existing isolated library compilation stays the default. |
| Multi-file or multi-project | Label each file and project, describe assembly relationships and dependencies, and verify the maintained project graph. Multiple fences can form one scenario; they are not automatically separate programs. |
| Framework/application integration | Explain who builds/starts/disposes the host, application lifecycle and infrastructure, then verify with its real application/test workflow. |
| Intentionally partial excerpt | Say what is omitted and where it belongs. Bind to its maintained compiling source context; do not claim standalone execution. A missing context is unresolved work, not an automatic waiver. |

Prefer a real repository sample/test over generating new projects. When setup would overwhelm an API page, show essential usage, link directly to the maintained integration example and its project, and provide a complete pinned-snapshot command that executes the relevant test without manual assembly. Follow [one-shot examples](one-shot-examples.md). Source links alone are the fallback only when neither faithful standalone execution nor a working repository-backed command is available; explain the blocker and prerequisites, and keep the illustration truthful and explicitly unverified. Links and runtime commands do not waive target-use, source-bound compilation or documentation gates.

## Preserve responsibilities

Check entry points and assembly identity, initialization ownership, DI lifetimes and request scopes, async and resource disposal, and options binding, registration order and effective values where the consumer uses them. Review security-sensitive operations using the same standards as application code, including any dormant branch the repair makes reachable.

Use a maintained integration test or representative host when behavior depends on hosting, request scopes, pipeline order or response lifecycle. A manually assembled context can exercise isolated logic, but cannot prove semantics it omits, such as headers becoming read-only when the response starts. Exercise the intended route to completion and inspect relevant response content, status, headers and resulting state.

Remove incidental test scaffolding when documenting ordinary libraries. For testing APIs, `[Fact]`, fixture constructor injection, assertions and the real runner can be essential consumer usage. Do not strip them to make a console-shaped example. A test that builds another host, overrides the service it claims the application registered, or merely asserts a test double's behavior proves a different contract. No static heuristic establishes that the prose and assertion mean the same thing: inspect authoritative usage and execute the relevant test when claiming runtime results.

## Bind a fence to maintained source

Unbound C# fences keep their existing structure and isolated compilation rules. For a file/excerpt that requires its real project, put these two comments first, using repository-relative paths:

````markdown
**Application project: `InventoryWorker`**, file `Program.cs`. This executable owns startup and registration; it is not part of the test assembly.

```csharp
// docfx-context: app/InventoryWorker/InventoryWorker.csproj
// docfx-source: app/InventoryWorker/Program.cs
<exact maintained source or contiguous whole-line excerpt>
```
````

The angle-bracket line above describes the binding syntax; it is not publishable C#. Use the same two comments on the test fence, pointing to the actual test project and source file. Name the application `ProjectReference`, package dependencies, runner and command in prose or link to their maintained project definitions. These comments identify compilation context; they do not replace readable project/file labels or prerequisites.

The fast path verifies both files exist inside the repository and the displayed source matches a complete maintained file or a nonempty contiguous whole-line excerpt. Only line-ending differences and outer blank lines are ignored. Missing paths, source drift and unsupported linked paths produce `SAMPLE_CONTEXT_INVALID` with repair guidance. With `--changed-only`, a page is selected when its Markdown, bound source, or bound project changes, including removed/moved binding inputs. No network, compilation or MSBuild evaluation occurs on the fast path.

With `--validate-samples`, the validator copies the repository to temp (excluding generated directories and `.bot`), checks the selected framework is declared by each bound project, evaluates `Compile` membership for that framework/configuration, and builds the declared projects together through the existing bounded sample graph build. Dependencies and separate assembly identities come from those projects, not concatenated fences. An excluded source file, unavailable dependency, invalid project graph, or failed build remains a failure. Use `--framework` for the actual runnable asset; do not silently retarget a maintained project. `--sample-reference-mode package` does not rewrite an explicitly bound project graph. Unsupported generated Compile items or external project dependencies require a supported maintained context; they are not accepted as success. Disposable context builds ignore persistent build servers so a node cannot supply another workspace's package-root environment or retain its test-runner task assemblies.

The context build writes a disposable native MSBuild binary log, read through `MSBuild.StructuredLogger`; it adds no separate compiler or public manifest. The validator uses actual Csc command lines and native project terminal results, preserving project-scoped errors when another sample fails the batch. A project not reached by the build remains unverified rather than inheriting an unrelated compilation failure. Missing, incomplete or unusable compiler evidence cannot count as success.

A bound excerpt must occur in an active region under that compiler invocation's framework/configuration symbols, including SDK-generated symbols, target-added constants, nested guards, and preceding file-local `#define`/`#undef`. Excluded displayed code produces `SAMPLE_CONTEXT_INVALID` and is not counted in `samplesCompiled`. Choose an active excerpt or validate the configuration/framework containing the intended code. If a displayed file includes several conditional branches, scope it to the intended active region; compiling one branch does not validate the others.

This is **compilation evidence for the displayed active region in its containing source/project**, not proof that an excerpt executed, its omitted initialization was invoked, or its assertion establishes the prose's claim. Run the real test/application separately and record command, framework/dependencies, observations and source identity before claiming execution. Do not use the context comments as a substitute for strict skip approvals, and never use an unrelated compiling project to validate a fence.

## Principal regression: ManagedApplicationFixture

Evidence pinned to [codebeltnet/xunit revision 84b13767](https://github.com/codebeltnet/xunit/tree/84b13767cb9484f8f3a36a71875662edfdb3e511):

- [ManagedApplicationFixture.ConfigureHost](https://github.com/codebeltnet/xunit/blob/84b13767cb9484f8f3a36a71875662edfdb3e511/src/Codebelt.Extensions.Xunit.Hosting/ManagedApplicationFixture.cs) passes `typeof(TEntryPoint).Assembly` to the deferred host factory. `TEntryPoint` identifies an application assembly; it is not a replacement host builder.
- [DeferredHostFactory](https://github.com/codebeltnet/xunit/blob/84b13767cb9484f8f3a36a71875662edfdb3e511/src/Codebelt.Extensions.Xunit.Hosting/Internal/DeferredHostFactory.cs) resolves that assembly's entry point. [ApplicationTest](https://github.com/codebeltnet/xunit/blob/84b13767cb9484f8f3a36a71875662edfdb3e511/src/Codebelt.Extensions.Xunit.Hosting/ApplicationTest.cs) wires fixture initialization through the base constructor.
- [Minimal worker Program](https://github.com/codebeltnet/xunit/blob/84b13767cb9484f8f3a36a71875662edfdb3e511/app/Codebelt.Extensions.Xunit.Hosting.BootstrapperMinimalWorker.App/Program.cs) owns service registration, host construction and `RunAsync`. The [functional test](https://github.com/codebeltnet/xunit/blob/84b13767cb9484f8f3a36a71875662edfdb3e511/test/Codebelt.Extensions.Xunit.Hosting.FunctionalTests/BootstrapperMinimalWorkerApplicationTestTest.cs) resolves the application's marker service and asserts its value. Its [project](https://github.com/codebeltnet/xunit/blob/84b13767cb9484f8f3a36a71875662edfdb3e511/test/Codebelt.Extensions.Xunit.Hosting.FunctionalTests/Codebelt.Extensions.Xunit.Hosting.FunctionalTests.csproj) references the application separately.

Recommended correction to the [published InventoryWorker example](https://xunit.codebelt.net/api/Codebelt.Extensions.Xunit.Hosting.ManagedApplicationFixture-1.html): show the smallest meaningful excerpt from the maintained Bootstrapper worker test, explain its separate application assembly, link its original application/test/project, and offer the [verified one-shot native and Docker commands](one-shot-examples.md). Do not dump both projects into the API page or require developers to assemble them manually. If retaining InventoryWorker domain names, first maintain a faithful working split sample; do not publish bindings to invented paths. Never remove Main, choose a startup object, or re-register the marker inside the test. This skill change does not edit the xunit repository.

`EXAMPLE_APPLICATION_ASSEMBLY_COLLAPSED` is narrowly scoped to the exact Codebelt `ManagedApplicationFixture<TEntryPoint>`/`ApplicationTest<TEntryPoint,T>` UID and a local fixture entry-point type in one C# source unit. Roslyn syntax/local symbol evidence avoids matching comments, strings, or unrelated multiple-class samples. Separate bound files are not merged for this check. Aliased or otherwise unresolved usages require build-backed verification and architectural review. The diagnostic is not a universal C# architecture analyzer and does not certify registration ownership, pipeline ordering, runtime success, or prose truth.


## Conditional API framework selection

Treat preprocessor symbols as asset-selection evidence, not as executable target frameworks. Before validating a sample for a conditionally compiled API, inspect the declaration, project TFMs, package `lib/` assets, and the asset selected for the consumer. Choose a runnable consumer TFM that forces selection of the assembly containing the API.

- For `NETSTANDARD2_0` or `NETSTANDARD2_0_OR_GREATER`, if the package also contains modern `lib/netX.0/` assets, use `net48` (or another supported .NET Framework TFM from `net462` onward). That consumer selects the compatible `lib/netstandard2.0/` asset instead of a modern asset that may omit the API.
- Do not target `netstandard*` for an executable test. It describes an API surface and cannot run by itself.
- Do not target a modern `netX.0` runtime merely because it is newer. Reject it when restore/build evidence shows that it resolves to an asset without the documented API.
- For other TFM guards, identify which built asset contains the API and select a compatible runtime target that consumes that asset. Verify the chosen asset through restore/build output or `project.assets.json`.

Pass the resulting runnable TFM through `docfx.cs --framework <tfm>`. Add `--sample-reference-mode package` when the test must prove installed-package asset selection. Use separate scoped validation runs when no single runnable TFM can select every conditional API asset in the documentation scope.
