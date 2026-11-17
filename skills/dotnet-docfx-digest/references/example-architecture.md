# Design examples around the developer task

Read this before writing application integration, testing-framework, multi-file/project examples, or partial excerpts. Keep package-ID-first discovery and the existing project packets. A compilation success is one kind of evidence, not approval of the example's architecture.

## Design contract

Before source generation, establish these facts from public contracts, implementation, tests, package READMEs, or maintained consumer examples. Record them briefly in the existing example inventory, not in a new manifest:

- **Intention:** the concrete question the developer wants answered, such as verifying a worker application's service registration.
- **Required context:** actual target framework/asset, package and namespace, application type, DI/configuration, host/infrastructure, project references, and which project owns each file. Distinguish published packages from unpublished source references; do not invent pins or assume ASP.NET Core merely because an API uses hosting.
- **Behavior:** a returned value, resolved application service, configuration value, HTTP response, assertion, lifecycle event, or relevant failure that answers that question. Construction, runtime type names, metadata, and decorative logging are insufficient.
- **Reproduction:** the exact build/run/test command, prerequisites, and observation to check. Identify the evidence as compilation only, executed behavior, or unverified. Retain failures and unavailable prerequisites; never turn them into success by weakening the scenario.

Use the sequence **Discover API → Understand consumer task → Determine execution topology → Find authoritative usage → Design example → Write source → Validate → Improve explanation → Publish**. The reader should understand why, what must exist, how to use it, what happens, and how to check it, without requiring five headings on every page.

## Choose the execution model

| Classification | Presentation and verification |
| --- | --- |
| Standalone executable | Complete source, with `// Program.cs` for an ordinary executable DocFX fence. Use csrun for compatible console or genuine xUnit v3 execution; do not simulate test execution. |
| Ordinary library usage | Concise namespace/type-based consumer code, necessary imports/setup, and meaningful result. Existing isolated library compilation stays the default. |
| Multi-file or multi-project | Label each file and project, describe assembly relationships and dependencies, and verify the maintained project graph. Multiple fences can form one scenario; they are not automatically separate programs. |
| Framework/application integration | Explain who builds/starts/disposes the host, application lifecycle and infrastructure, then verify with its real application/test workflow. |
| Intentionally partial excerpt | Say what is omitted and where it belongs. Bind to its maintained compiling source context; do not claim standalone execution. A missing context is unresolved work, not an automatic waiver. |

Prefer a real repository sample/test over generating new projects. When setup would overwhelm an API page, show essential usage and link directly to the maintained integration example and its project. A link supplements the local API example; it does not satisfy target-use or compilation requirements by itself. Include minimal valid project setup only where it is actually needed for reproduction and backed by evidence.

## Preserve responsibilities

Review architecture as well as source shape. Check executable entry points and assembly identity; application-owned versus test-owned DI registration; framework-owned versus application-owned initialization; async and disposal lifetimes; Options binding/validation; fixture/factory initialization; real services versus doubles; and reference/asset selection. For middleware, preserve registration, pipeline order (including authentication/authorization/routing where required), and the request/response that demonstrates the effect.

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

The fast path verifies both files exist inside the repository and the displayed source matches a complete maintained file or a nonempty contiguous whole-line excerpt. Only line-ending differences and outer blank lines are ignored. Missing paths, source drift and unsupported linked paths produce `SAMPLE_CONTEXT_INVALID` with repair guidance. No network, compilation or MSBuild evaluation occurs on the fast path.

With `--validate-samples`, the validator copies the repository to temp (excluding generated directories and `.bot`), checks the selected framework is declared by each bound project, evaluates `Compile` membership for that framework/configuration, and builds the declared projects together through the existing bounded sample graph build. Dependencies and separate assembly identities come from those projects, not concatenated fences. An excluded source file, unavailable dependency, invalid project graph, or failed build remains a failure. Use `--framework` for the actual runnable asset; do not silently retarget a maintained project. `--sample-reference-mode package` does not rewrite an explicitly bound project graph. Unsupported generated Compile items or external project dependencies require a supported maintained context; they are not accepted as success. Disposable context builds ignore persistent build servers so a node cannot supply another workspace's package-root environment or retain its test-runner task assemblies.

This is **compilation evidence for the containing source/project**, not proof that an excerpt executed, its omitted initialization was invoked, or its assertion establishes the prose's claim. Run the real test/application separately and record command, framework/dependencies, observations and source identity before claiming execution. Do not use the context comments as a substitute for strict skip approvals, and never use an unrelated compiling project to validate a fence.

## Principal regression: ManagedApplicationFixture

Evidence pinned to [codebeltnet/xunit revision 84b13767](https://github.com/codebeltnet/xunit/tree/84b13767cb9484f8f3a36a71875662edfdb3e511):

- [ManagedApplicationFixture.ConfigureHost](https://github.com/codebeltnet/xunit/blob/84b13767cb9484f8f3a36a71875662edfdb3e511/src/Codebelt.Extensions.Xunit.Hosting/ManagedApplicationFixture.cs) passes `typeof(TEntryPoint).Assembly` to the deferred host factory. `TEntryPoint` identifies an application assembly; it is not a replacement host builder.
- [DeferredHostFactory](https://github.com/codebeltnet/xunit/blob/84b13767cb9484f8f3a36a71875662edfdb3e511/src/Codebelt.Extensions.Xunit.Hosting/Internal/DeferredHostFactory.cs) resolves that assembly's entry point. [ApplicationTest](https://github.com/codebeltnet/xunit/blob/84b13767cb9484f8f3a36a71875662edfdb3e511/src/Codebelt.Extensions.Xunit.Hosting/ApplicationTest.cs) wires fixture initialization through the base constructor.
- [Minimal worker Program](https://github.com/codebeltnet/xunit/blob/84b13767cb9484f8f3a36a71875662edfdb3e511/app/Codebelt.Extensions.Xunit.Hosting.BootstrapperMinimalWorker.App/Program.cs) owns service registration, host construction and `RunAsync`. The [functional test](https://github.com/codebeltnet/xunit/blob/84b13767cb9484f8f3a36a71875662edfdb3e511/test/Codebelt.Extensions.Xunit.Hosting.FunctionalTests/BootstrapperMinimalWorkerApplicationTestTest.cs) resolves the application's marker service and asserts its value. Its [project](https://github.com/codebeltnet/xunit/blob/84b13767cb9484f8f3a36a71875662edfdb3e511/test/Codebelt.Extensions.Xunit.Hosting.FunctionalTests/Codebelt.Extensions.Xunit.Hosting.FunctionalTests.csproj) references the application separately.

Recommended correction to the [published InventoryWorker example](https://xunit.codebelt.net/api/Codebelt.Extensions.Xunit.Hosting.ManagedApplicationFixture-1.html): put `WorkerProgram.Main`, `WorkerIdentity` and registration in application project `InventoryWorker`; put `InventoryWorkerTest`, `[Fact]`, injected fixture and assertion in `InventoryWorker.Tests`, referencing the executable application and the actual xUnit v3 runner. Label both source files and explain the project/package references. Prefer reusing the existing Bootstrapper application/test graph linked above. If retaining the InventoryWorker domain names, first maintain a working split sample; do not publish bindings to invented paths. Keep the API page concise by linking that working integration sample and its application. Do not remove Main, choose a startup object, or manually re-register `WorkerIdentity` in the test. This skill change does not edit the xunit repository.

`EXAMPLE_APPLICATION_ASSEMBLY_COLLAPSED` is narrowly scoped to the exact Codebelt `ManagedApplicationFixture<TEntryPoint>`/`ApplicationTest<TEntryPoint,T>` UID and a local fixture entry-point type in one C# source unit. Roslyn syntax/local symbol evidence avoids matching comments, strings, or unrelated multiple-class samples. Separate bound files are not merged for this check. Aliased or otherwise unresolved usages require build-backed verification and architectural review. The diagnostic is not a universal C# architecture analyzer and does not certify registration ownership, pipeline ordering, runtime success, or prose truth.
