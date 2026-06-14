# dotnet-docfx-digest workflow reference

Use this reference when you need the full step-by-step workflow, example inventory shape, ready-to-adapt templates, or the final completion checklist.

## Example inventory shape

Build a small example inventory from validator output and source evidence before writing examples. Treat it as a work queue, not as final-response prose.

```markdown
| UID | Kind | Required example location | Source evidence | Scenario | Status |
|---|---|---|---|---|---|
| Codebelt.Extensions.Xunit.Hosting.ApplicationHostFactory | Type | .docfx/api/types/Codebelt.Extensions.Xunit.Hosting.ApplicationHostFactory.md | Package README, ApplicationHostFactoryTest | Host a test server and create a client | Missing |
```

Do not mark an item complete until the evidence cell names concrete repository paths, the scenario states a consumer task, the overwrite section targets the correct UID or approved extension-method location, the file is included by `build.overwrite`, the sample compiles under `docfx.cs --validate-samples` (or has a justified skip marker), and `docfx.cs --json` no longer reports any missing, placeholder, reflection-only, target-use, invocation, or duplicate-UID diagnostic.

## Scenario example design

Before writing a type or extension-method example, choose the smallest real task that explains the API in context. Start from package-level evidence, then narrow to type-level evidence:

1. Determine the NuGet package ID or IDs from packable projects, `.nuget/*/README.md`, package release notes, `Directory.Packages.props`, or `PackageReference` usage.
2. Search local evidence for the exact package ID first, including README files, package docs, samples, tooling projects, tuning projects, functional tests, and generated package documentation.
3. When internet or GitHub search is available and allowed, search for the exact package ID and prefer consumer repositories outside the target repository. Treat self-repo hits as package-authored docs or samples, not independent usage proof.
4. Search by namespace, type, and member name only after package-ID evidence has been inspected.
5. Pick a scenario that connects the documented type to the package workflow. A good sample can include multiple related public types, a small local helper type, dependency-injection setup, host setup, options configuration, file/path setup, or result inspection when that is what a real caller would do.
6. Remove test-only structure, raw assertions, mocks, fixture base classes, and unused locals. Keep meaningful setup and result inspection.
7. Prefer domain-specific names such as `BenchmarkRunner`, `WorkspaceUsage`, or `HttpRetryExample` over `Consumer` and `MyNamespace` when the package domain is clear.
8. Reject metadata-only substitutes before writing: `Type.GetType`, assembly lookup, `typeof`/`nameof` as the only operation, generic `Describe()` helpers, and repeated UID sections do not demonstrate a consumer task.
9. Confirm the C# fence itself uses the documented type or invokes the documented extension method. Mentions outside the fence do not count.

A scenario example is still concise. It should show one coherent task, not a tour of every member. If a compile-valid scenario cannot be produced from evidence, omit the example with the documented omission comment rather than inventing a plausible workflow.

## Targeted workflow

Use this path when the user names a changed API or namespace.

1. Run `agents.cs`.
2. Run the safety gates: inspect `git status --short`, identify existing documentation work, and avoid broad restore or recovery commands.
3. Inspect the changed public API and determine affected namespaces.
4. Determine whether public extension methods are involved.
5. Inspect `.docfx/docfx.json` or the repository-specific DocFX config.
6. Locate existing overwrite files, namespace pages, availability includes, tests, and samples.
7. Run `docfx.cs --json --repair-plan /tmp/docfx-repair-plan.md --search-examples` and read the repair plan. The "GitHub Example Sources" section contains pre-computed `gh search code` commands and URLs; use those results as evidence before writing examples.
8. Convert test usage into consumer-oriented examples when relevant.
9. Update XML documentation comments where purpose-first summaries are needed.
10. Update or create namespace overview pages whose opening names the developer problem and outcome, followed by concrete when-to-use and start-here guidance.
11. Inspect sibling namespace pages in the same public API family and repair each affected page consistently.
12. Update `Extension Members` tables when public extension methods are involved. Use the literal `⬇️` (U+2B07 U+FE0F) in the Ext column — the validator now rejects corrupted or missing emoji with `EXTENSION_TABLE_ENCODING`.
13. Update or create overwrite content, including type-page examples for public non-abstraction types and explicit examples for public extension methods.
14. Build or refresh the example inventory.
15. Preserve manual edits and correct stale contradictions instead of replacing whole files.
16. Run `git diff` for touched documentation paths and confirm the diff is intentional.
17. Run `dotnet build`, or `dotnet build -p:SkipSignAssembly=true` when a Codebelt repository has no root `.snk`.
18. Run `dotnet test`, or `dotnet test -p:SkipSignAssembly=true` when a Codebelt repository has no root `.snk`.
19. Run the Completion Repair Loop by rerunning the fast `docfx.cs --json`, repairing every remaining diagnostic, and updating the example inventory until `summary.canClaimCompletion` is `true`. Diagnostic age and volume are not blockers.
20. Run the build-backed completion verification `docfx.cs --build-api-model --validate-samples --verify-docfx-build` so samples compile, API discovery is reflection-precise, and DocFX builds in a temp copy.
21. Inspect `git status` and confirm no disposable generated DocFX output remained in the working tree.
22. Report verification results and any remaining deterministic findings.

## Repo-wide audit workflow

Use this path when the user invokes the skill without naming a specific API or namespace.

1. Run `agents.cs`.
2. Run the safety gates: inspect `git status --short`, identify existing documentation work, and avoid broad restore or recovery commands.
3. Read repository guidance, especially root `AGENTS.md`.
4. Inspect `.docfx/docfx.json` or the repository-specific DocFX config.
5. Read `references/docfx-overwrite-files.md`.
6. Run `docfx.cs --json --repair-plan /tmp/docfx-repair-plan.md --search-examples` and read the repair plan. The plan is the authoritative work queue. The "GitHub Example Sources" section contains pre-computed `gh search code` commands and URLs for each documented package — run or open these searches before writing any new example.
7. If the validator fails before producing documentation diagnostics, inspect source projects, DocFX config, existing overwrite files, generated metadata when available, tests, and samples manually.
8. Check for `ENCODING_CORRUPTION` or `EXTENSION_TABLE_ENCODING` diagnostics first; restore affected files from git before doing any further editing.
9. Determine every namespace containing public API and whether each namespace exposes public extension methods.
10. Determine every public non-abstraction type and every public extension method that requires an example.
11. Create or update missing namespace overview pages with a problem/outcome opening, concrete when-to-use guidance, and a named starting API. Inventory-only prose is unfinished.
12. Audit related namespace pages together so fixes are consistent across the public API family.
13. Add or repair `Extension Members` tables for namespaces with public extension methods. Use the literal `⬇️` (U+2B07 U+FE0F) in the Ext column.
14. Add or repair overwrite content for public API items that need examples, remarks, corrected summaries, or availability notes.
15. Create separate type-page overwrite files for public non-abstraction types that have no example yet, under `.docfx/api/types/{TypeUid}.md` in Codebelt repositories.
16. Ensure `docfx.json` includes both `api/namespaces/**/*.md` and `api/types/**/*.md` under `build.overwrite`, excludes both `api/namespaces/**` and `api/types/**` from `build.content`, and moves legacy authored `.docfx/api/*.md` files into either `api/namespaces/` (namespace pages) or `api/types/` (type pages).
17. Create explicit examples for public extension methods that still have none.
18. Build or refresh the example inventory.
19. Preserve manual edits and correct stale contradictions instead of replacing whole files.
20. Run `git diff` for touched documentation paths and confirm the diff is intentional.
21. Run `dotnet build`, or `dotnet build -p:SkipSignAssembly=true` when a Codebelt repository has no root `.snk`.
22. Run `dotnet test`, or `dotnet test -p:SkipSignAssembly=true` when a Codebelt repository has no root `.snk`.
23. Run the Completion Repair Loop by rerunning the fast `docfx.cs --json`, repairing every remaining diagnostic, and updating the example inventory until `summary.canClaimCompletion` is `true`. A large queue is still the task, not a reason to stop.
24. Run the build-backed completion verification `docfx.cs --build-api-model --validate-samples --verify-docfx-build` so samples compile, API discovery is reflection-precise, and DocFX builds in a temp copy.
25. Inspect `git status` and confirm no disposable generated DocFX output remained in the working tree.
26. Report verification results and any remaining deterministic findings.

When resuming a partial repo-wide audit, begin by inventorying all tracked and untracked documentation changes and preserving them as in-flight work. Regenerate the deterministic repair plan and example inventory, use both as the authoritative queue, and work in batches with a fast validator rerun after every batch. The exact final command is `docfx.cs --build-api-model --validate-samples --verify-docfx-build --json`; descriptive references to those activities do not replace running the flags together.

For the final command, let `auto` choose the execution profile unless the user requests a specific resource policy. High-capacity machines run the isolated DocFX verification lane concurrently with API/sample work; conservative machines remain sequential. Give the outer command a timeout at least five minutes above the validator's child-process timeout (35 minutes with the default 30-minute setting) so timeout diagnostics can be returned normally.

Keep `stderr` visible during the final command. API build, sample compilation, and DocFX verification print a start event, 10-second heartbeats, and a final success/failure event there. Use the phase, PID, elapsed time, last-output age, and current output line to decide whether work is progressing or a child appears stale. Capturing `stdout` for `--json` is safe because progress never enters the JSON stream.

## Namespace page template

Use this template when creating a new namespace overview page:

```markdown
---
uid: X.Y.Z
summary: *content
---
The `X.Y.Z` namespace helps you ...
Use it when ...
If you're trying to ..., start with `PrimaryType` or `PrimaryExtensions`.

[!INCLUDE [availability-default](../../includes/availability-default.md)]

### Extension Members

|Type|Ext|Methods|
|--:|:-:|---|
|String|⬇️|`ExampleMethod`|
```

Remove the `Extension Members` section when the namespace has no public extension methods. Adjust the include path to match the actual file location.

## Type example shape

> **DocFX overwrite Markdown only.** This shape is for writing DocFX overwrite content. Do not create tests from it. Tests are evidence, not output — use tests to understand behavior, then transform that knowledge into consumer-facing examples.

For public non-abstraction types, begin the overwrite file with front matter that maps the body to the `example` property:

````markdown
---
uid: X.Y.Z.MyType
example:
- *content
---
The following schematic shows the overwrite shape only. Replace it with a source-backed consumer task; do not copy the generic names into product documentation.

```csharp
using X.Y.Z;

namespace MyProject.Workflows;

public class WidgetFactory
{
    public MyType Create()
    {
        return new MyType();
    }
}
```
````

Do not include a manual `### Examples` heading in the body. DocFX renders that heading automatically for the `example` property. Every `csharp` code block must include a file-scoped namespace and at least one class declaration; top-level statements are not allowed unless the block is labelled `// Program.cs`.

## Extension method example template

Apply the same `example: - *content` rule for extension-method examples:

````markdown
---
uid: X.Y.Z.MyExtensions
example:
- *content
---
The following example normalizes text before persisting it, making the operation and its next step visible.

```csharp
using X.Y.Z;

namespace TextImport;

public class ImportedNote
{
    public string PrepareForStorage(string text)
    {
        return text.NormalizeLineEndings();
    }
}
```
````

The namespace containing the extension method must be imported, the receiver type must be valid, and the sample must compile in a class library verification project.

## Synthetic hash-suffix filenames are prohibited

DocFX can generate synthetic method UIDs for generic or overloaded extension methods that contain hashes, encoding characters, or computed suffixes. Never mirror those UIDs directly in filenames.

Bad examples:

- `EndpointConventionBuilderExtensions.-G-6D0D8037DBBD61D10816ECA5F93B896F.md`
- `EndpointConventionBuilderExtensions.%3CT%3E...md`

Keep the filename readable, place the example in the declaring extension class file or the namespace page, and let the YAML `uid` determine what model receives the content.

## Verification checklist

Before completing documentation work, verify:

- [ ] `agents.cs` ran successfully.
- [ ] `AGENTS.md` contains the managed DocFX maintenance block.
- [ ] Initial `git status --short` was inspected and existing documentation changes were treated as user work.
- [ ] For multi-diagnostic audits, `docfx.cs --repair-plan` was written, read, and used as the work queue.
- [ ] Only public API is documented.
- [ ] Every namespace with public API has a namespace overview page.
- [ ] Related namespace pages in the same public API family were inspected and updated consistently, or intentionally left unchanged with a reason.
- [ ] Namespaces with public extension methods have an `Extension Members` section.
- [ ] Public non-abstraction types have at least one type-page example.
- [ ] Public extension methods have at least one explicit example, not only a table entry.
- [ ] Package IDs and package-level usage evidence were inspected before type/member-only sample synthesis.
- [ ] Every inventory row names exact evidence paths and a consumer task; generated metadata and the target overwrite file are not the sole evidence.
- [ ] The example inventory maps each required public type and extension method to its example file, UID, source evidence, and chosen scenario.
- [ ] Examples show a coherent consumer workflow, use related public types when helpful, and avoid placeholder-only `Consumer`/`MyNamespace` shells when a domain name is available.
- [ ] No example is reflection-only, metadata-only, duplicated by UID, or built from `DocumentedTypeExample`, `DocumentedExtensionExample`, or generic `Describe()` scaffolding.
- [ ] The C# fence itself uses the documented type or invokes the documented extension method; prose, comments, and strings are not counted as usage.
- [ ] Missing examples are added through DocFX overwrite content included by `build.overwrite`. Namespace pages are under `api/namespaces/` and type pages are under `api/types/`.
- [ ] The Completion Repair Loop was run after edits, and the final report has zero missing/low-quality example, namespace-prose, extension, availability, overwrite-layout, sample, and DocFX-build diagnostics.
- [ ] Examples are realistic, copy/paste-ready, and compile unless a justified skip marker is present.
- [ ] Generated C# examples include a file-scoped namespace and a type declaration (class, struct, or record), or are explicitly labelled `// Program.cs`.
- [ ] No generated C# example uses top-level statements without a `// Program.cs` label.
- [ ] No generated C# example derives from a generic base type without concrete type arguments.
- [ ] No generated C# example calls members that are not confirmed on the public API surface.
- [ ] Where no compile-valid example could be generated, the overwrite file contains the appropriate omission comment.
- [ ] Availability is included or explicitly stated and matches actual target frameworks and conditions.
- [ ] Existing manual edits are preserved, stale documentation is corrected, and no contradictory documentation remains.
- [ ] `git diff` for touched documentation paths was inspected before final verification.
- [ ] `dotnet build` has been run, using `-p:SkipSignAssembly=true` when a Codebelt repository has no root `.snk`, or the failure is reported.
- [ ] `dotnet test` has been run, using `-p:SkipSignAssembly=true` when a Codebelt repository has no root `.snk`, or the failure is reported.
- [ ] The build-backed completion verification `docfx.cs --build-api-model --validate-samples --verify-docfx-build` ran successfully, and final JSON reports `summary.canClaimCompletion: true`, `summary.remainingWorkItems: 0`, an empty `summary.remainingGates`, and an empty `summary.remainingDiagnosticsByCode`.
- [ ] Generated metadata files and build output directories did not remain in the working tree after verification, and authored Markdown or documentation assets were not deleted as cleanup.
- [ ] No broad restore or checkout command discarded authored documentation changes.

## Completion response

When reporting completion, include:

- public APIs documented
- namespace pages added or updated
- extension-member tables added or updated
- examples added, their source test or sample when applicable, and the example inventory by public type or extension method
- availability handling
- related namespace pages inspected and whether each was updated or left unchanged
- `AGENTS.md` created, updated, already compliant, or failed
- signing-key handling: whether a root `.snk` was used or `-p:SkipSignAssembly=true` was used because no root `.snk` was present
- verification commands run
- any verification failures or skipped checks

Do not claim documentation was verified unless the relevant command actually ran successfully.

If work must stop incomplete, distinguish a true external blocker from repair work. Pre-existing documentation gaps, large diagnostic counts, sample compile failures, and `DOCFX_BUILD_FAILED` output caused by the documentation/configuration being repaired are active work items. Only a user pause or an external condition that still prevents progress after concrete attempts justifies stopping, and that response must say the digest remains incomplete.
