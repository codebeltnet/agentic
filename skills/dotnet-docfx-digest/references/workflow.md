# Author and audit DocFX pages

## Targeted authoring

Start from the selected public symbol, its owning project and package, related namespace pages, XML comments and existing overwrites. Inspect affected siblings when the change alters a shared entry point, extension family or framework availability. For a member change, limit edits to documentation surfaces whose claims or coverage changed.

## Key entry-point and upstream comparison pass

Before finalizing namespace prose, inspect recent release notes or changelog entries, package READMEs, public factories/builders, and the strongest functional tests to identify the APIs that carry the current product story. Name those key entry points in the namespace page and give readers a compact choice among them. Naming conventions remain supporting detail, not the opening narrative.

When a package is positioned as an alternative to an upstream framework type, inspect current official upstream documentation and compare concrete workflow differences: acquisition model, customization, lifecycle ownership, sharing/reuse, and the observable result exposed to tests. Call the API a replacement only when it is actually drop-in compatible; otherwise describe it as an alternative or convenience and state the tradeoffs.

A scenario example is still concise. It should show one coherent task, not a tour of every member. If a compile-valid scenario cannot be produced from evidence, omit the example with the documented omission comment rather than inventing a plausible workflow. That omission comment is explanatory prose only; it does not suppress diagnostics or act as a skip waiver.

Cover parameters, return values, exceptions, type parameters, nullability and lifecycle in XML where relevant. Put longer examples on generated type pages. Introduce each fence with the consumer task and outcome. For larger examples explain the necessary setup first. Use the exact type UID for colliding names and receiver syntax on the declaring type or method UID for extensions.

## Repository-wide audit

1. Generate the assessment queue with `--assessment-queue <temp-path> --search-examples` when search is available. Inspect its package-level usage sources. Use the project manifest and existing example inventory to assign every public non-abstraction type and extension method to a page. Record UID, owning project, location, exact source/test evidence, scenario and status.
2. Work namespace-first within the established scope. Orient newcomers to the problem and a real starting API. Where a namespace has alternatives, explain how to choose. Keep availability consistent with project conditions and package assets. In extension tables preserve the literal ⬇️, decorated receiver type and generic method signature. Fill individual missing methods after adding a missing section.
3. Ensure namespace and type overwrite globs appear in `build.overwrite` only, with both folders excluded from `build.content`. Migrate legacy API-root pages to their proper folder. Keep one namespace UID per overview and put examples on type-targeted pages. Use the overwrite reference for mappings, the structured writer and generic-arity family coverage.
4. Complete the packet's repair queue and example inventory before closing it. Prefer inline prose edits and small sibling batches. Validate and inspect diffs as you go. An example-heavy packet can be divided by UID while keeping one owner per file. Run the entry point's completion contract after the requested scope is covered.

### Working-tree dry run

Dry run is a limited real run that writes useful documentation directly to the working tree. The validator selects and verifies; the agent performs the evidence-based authoring between those invocations:

1. The user may name projects: "Use dotnet-docfx-digest in dry-run mode for Cuemon.Core and src/Cuemon.Net/Cuemon.Net.csproj." Explicit hints override automatic selection and resolve against project path, file name, assembly name, or package id. An unknown hint raises `PROJECT_HINT_NOT_FOUND`; an ambiguous one raises `PROJECT_HINT_AMBIGUOUS`. Resolve both before editing.
2. With no hints ("Use dotnet-docfx-digest in dry-run mode."), the validator selects one **clean** project from every metadata destination group through a reported, reproducible seed. Do not ask for project hints when none were supplied.
3. Related files that were already staged, modified, renamed, deleted, or untracked before the run are never edited. A dirty first candidate is skipped for the next clean one; a group with no clean candidate is reported as `DRY_RUN_GROUP_UNSELECTED`.
4. Before editing, run `docfx.cs --repo-root <root> --dry-run --build-api-model --project-manifest <temp-manifest> --json` plus any supplied `--project` hints. Persist `<temp-manifest>` outside the repository working tree. Treat `scope.selectedProjects` and the persisted baseline as the complete write boundary. The command creates `<temp-manifest-name>.review.json` beside the manifest.
5. Author every selected packet with the same evidence and quality standard as a full run. Do not stop after selection or manifest generation. Read every changed namespace and type page after authoring, compare normalized prose and code patterns across the whole pilot, and complete every entry in the generated review JSON: `evidence`, page-specific `purpose`, `observableOutcome` (use `namespace guidance` only for namespace pages), and `patternComparison`. Also prepare the same information as a `Changed-page review` table for the final response. A file list or clean validator summary is not this review.
6. Resume the exact baseline with `docfx.cs --repo-root <root> --resume-project-manifest <temp-manifest> --review-report <temp-review> --build-api-model --validate-samples --verify-docfx-build --json`. This validates files created by the current run without reclassifying them as pre-existing dirty work. Missing, placeholder, or incomplete review entries raise `REVIEW_REPORT_MISSING`, `REVIEW_REPORT_INVALID`, or `REVIEW_REPORT_INCOMPLETE`; an invalid or stale manifest fails closed and selects no fallback projects.
7. Continue repairing the selected packets until the resumed command reports `dry-run-passed`, zero remaining gates, compiled samples, and a verified DocFX build. Any error or omitted final gate is `dry-run-failed`.
8. Dry run never claims the repository digest is complete. Report selected projects, seed, the complete changed-page review table, representative prose/examples, reproduction command, and resume command for human approval before a full run.

Use `--dry-run [--seed <n>]` for automatic selection, `--dry-run --project <hint> [--project <hint> ...]` for explicit selection, and always pair the initial `--project-manifest` invocation with the final `--resume-project-manifest` invocation. Use `--project <hint>` without `--dry-run` only for a scoped non-random validation; it still cannot claim repository completion.

## Page examples

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

Do not unwrap decorated receivers or flatten generic method names in this table. Keep signatures such as `IDecorator<Type>` and `As<T>` intact instead of rewriting them as `Type` or bare `As`.

Namespace overview files stay single-UID and stop after the fly-in, availability, related links, and optional `Extension Members` table. Do not append secondary `uid:` / `example:` mappings there; put extension-method examples on the declaring extension class page or another readable type-targeted file under `.docfx/api/types/`. Under `.docfx/api/`, `[!INCLUDE ...]` directives (including availability includes) are only allowed in `.docfx/api/namespaces/*` — never in `.docfx/api/types/*` or after examples — and Markdown edits must stay under `.docfx/api/`.

## Type example shape

> **DocFX overwrite Markdown only.** Use tests as evidence and transform ordinary API usage into consumer-facing examples. For testing abstractions, the consumer-facing example is a real framework test with its required fixture, runner, and assembly semantics.

For public non-abstraction types, begin the overwrite file with front matter that maps the body to the `example` property:

````markdown
---
uid: X.Y.Z.MyType
example:
- *content
---
The following schematic shows the overwrite shape only. Replace it with a source-backed consumer task and a short fly-in that tells the reader what the code is about to accomplish. If public evidence shows that another API usually returns or acquires `MyType`, show that discoverable path instead of `return new MyType()`.

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

Do not include a manual `## Example`, `### Example`, `## Examples`, or `### Examples` heading in the body when front matter maps `example` (`example: *content`, `example: [*content]`, or `example:\n- *content`). DocFX renders the `Examples` heading automatically for the `example` property, and `docfx.cs` rejects manual `Example`/`Examples` headings inside `example:`-mapped bodies with `EXAMPLE_REDUNDANT_HEADING`. Place only the complementary explanatory prose directly before the C# fence. Unbound fences retain the namespace/type or labelled `// Program.cs` structure rules. Project-bound source files and clearly contextualized excerpts use their maintained compilation context; see [example architecture](example-architecture.md). Multiple fences may describe one scenario, with each file's role and project identified.

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
- `EndpointConventionBuilderExtensions.G$6D0D8037DBBD61D10816ECA5F93B896F.md`

Keep the filename readable, place the example in the declaring extension class file or another readable file under `.docfx/api/types/`, and let the YAML `uid` determine what model receives the content. Do not append member-level overwrite sections to the namespace page. If a compiler-generated C# extension-block container appears in DocFX YAML or build-backed reflection discovery, collapse it back to the authored outer static class before creating required-example targets; deleting the synthetic file after creation is cleanup, not success.
