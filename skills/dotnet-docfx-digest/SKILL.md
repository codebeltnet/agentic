---
name: dotnet-docfx-digest
description: >
  Create and maintain developer-friendly DocFX documentation digests for .NET public APIs, including repo-wide no-input audits, namespace overview pages, extension-member documentation, overwrite files, examples, availability notes, AGENTS.md maintenance, and verification. Use when the user asks to document a .NET API, create or update DocFX documentation, write namespace overview pages, add extension-method tables, update XML documentation comments, add API examples, maintain DocFX overwrite files, or verify documentation builds. Treat requests like "use dotnet-docfx-digest", "update the DocFX docs", "complete missing documentation", "create namespace pages", "add examples for this type", "update the extension members table", or "verify the documentation builds" as automatic triggers. Also use whenever public .NET API surface changes and documentation needs to stay aligned with source code.
---

# .NET DocFX Digest Steward

## Description

Create and maintain developer-friendly DocFX documentation digests for .NET public APIs, including namespace overview pages, extension-member documentation, overwrite files, examples, availability notes, and verification. Preserve manual edits, document public API only, require buildable copy/paste-ready examples for concrete APIs, and keep documentation aligned with actual source code and tests.

## Activation Requirements

This skill is autonomous by default. If the user invokes the skill without naming a namespace, type, member, or changed API, do not ask what to document first. Treat the request as a repo-wide DocFX documentation audit and repair task:

1. Run the repository-instruction script.
2. Inspect repository guidance, `docfx.json`, source projects, generated metadata, tests, samples, existing overwrite files, namespace pages, and availability includes.
3. Run the validator to discover missing or stale complementary documentation.
4. Fill the missing DocFX pieces that can be derived from source evidence, including overwrite examples for concrete public types and public extension methods.
5. Ask a concise clarifying question only when inspection exposes a correctness-affecting choice that cannot be resolved from repository evidence.

When this skill is invoked against a repository, the agent must run the deterministic repository-instruction script before completing the task:

```bash
dotnet run --file skills/dotnet-docfx-digest/scripts/agents.cs -- --repo-root .
```

Before reporting completion, the agent must run the deterministic validator:

```bash
dotnet run --file skills/dotnet-docfx-digest/scripts/docfx.cs -- --repo-root .
```

If either script cannot run, the agent must report the exact command, exit code, and failure output. Do not claim repository instructions or documentation were verified unless the scripts ran successfully.

## Core Principles

Documentation is part of the public contract. When changing public .NET APIs, the agent must update the corresponding documentation in the same change set. This includes XML documentation comments, DocFX overwrite files, namespace overview pages, examples, extension-method listings, and availability information.

The documentation must reflect the actual code, not intended code. Do not invent APIs, overloads, target frameworks, behaviors, exceptions, or examples. Verify every documented claim against source code, tests, project files, generated metadata, or existing documentation.

Manual documentation is authoritative context. Preserve existing manual edits unless they are factually incorrect. Prefer additive changes. When information is stale, update the stale portion while retaining nearby human-written explanations, tone, and structure.

## Scope

Apply this skill to:

- Public .NET types,
- Public constructors,
- Public properties,
- Public methods,
- Public fields,
- Public events,
- Public delegates,
- Public enums and enum members,
- Public extension methods,
- Public namespaces containing public API,
- DocFX overwrite Markdown files,
- DocFX namespace overview Markdown files,
- XML documentation comments,
- API examples,
- availability includes or availability statements.

Do not document:

- Private types,
- Internal types,
- Private members,
- Internal members,
- Implementation-only helpers,
- Test-only fixtures unless they are part of a documented public test-support API,
- Namespaces that contain no public API.

If a namespace contains only private or internal types, do not create a namespace overview page for it.

## Repository Discovery

Before editing documentation, locate the DocFX workspace.

For Codebelt repositories, the DocFX workspace is always:

```text
.docfx
```

The DocFX configuration file is always:

```text
.docfx/docfx.json
```

For other repositories, locate `docfx.json` before making DocFX-specific changes.

Inspect `docfx.json` to understand:

- Content roots,
- API metadata inputs,
- Overwrite file locations,
- Include file locations,
- Resource paths,
- Output conventions.

Do not assume paths beyond the repository's actual DocFX configuration, except for Codebelt repositories where `.docfx/docfx.json` is the convention.

When creating or repairing overwrite files, read `references/docfx-overwrite-files.md` for the DocFX overwrite and `docfx.json` rules that matter most to agents.

## AGENTS.md Maintenance

Persistent repository guidance is enforced by script, not by AI memory. When this skill is invoked, run:

```bash
dotnet run --file skills/dotnet-docfx-digest/scripts/agents.cs -- --repo-root .
```

The script must create or update a marker-bounded DocFX documentation maintenance section in the repository root `AGENTS.md`. Do not manually duplicate this section. If the script fails, report the failure and do not claim `AGENTS.md` was updated.

## Public API Rule

Only public API is documented. Before adding or updating documentation, determine whether the item is public from source code or generated metadata.

A type is documentable only when it is externally visible. A member is documentable only when it is public and belongs to a documentable public type.

Do not add documentation pages for namespaces that contain no public types. Do not add extension-method documentation for non-public extension methods.

## Required Documentation Updates

When a public API is added or materially changed, update all relevant documentation surfaces:

1. XML documentation comments in source code.
2. DocFX overwrite files when manual API documentation exists or is needed.
3. Namespace overview page.
4. Extension members table when extension methods are involved.
5. Availability information.
6. At least one usage example in DocFX overwrite content unless the documented item is an abstraction.
7. Verification artifacts or commands proving the documentation remains buildable and accurate.

A "material change" includes:

- New public API,
- Removed public API,
- Changed public signature,
- Changed behavior,
- Changed exception behavior,
- Changed generic constraints,
- Changed nullability contract,
- Changed target framework availability,
- Changed platform availability,
- Changed extension-method availability,
- Changed obsolete/deprecation status,
- Changed default values,
- Changed thread-safety or lifecycle expectations.

## Examples Are Mandatory

Every automatically documented concrete public type and every public extension method must include at least one example showing how to use it. A namespace overview fly-in or `Extension Members` table is not enough.

Create or repair DocFX overwrite content for missing examples. If an overwrite section for the target `uid` does not exist, create one in a Markdown file included by `build.overwrite` in `docfx.json`. Do not stop after editing namespace pages when concrete public types or public extension methods still lack examples.

For concrete public types, prefer an overwrite section whose `uid` is the generated type UID. For public extension methods, add the example to the generated method UID when known; otherwise add it to the extension class UID or the namespace page, but the example must name and demonstrate the extension method.

An example may be omitted only when the item is an abstraction, such as:

- Interface,
- Abstract class,
- Abstract member,
- Attribute intended only for framework discovery,
- Marker type with no direct usage,
- Pure contract type where concrete usage belongs on implementations.

When omitting an example for an abstraction, the documentation must make that reason clear.

Preferred source for examples:

1. Existing unit tests,
2. Existing functional tests,
3. Existing integration tests,
4. Existing samples,
5. Minimal new sample derived from actual public API behavior.

Examples derived from tests must be converted into real-life usage. Do not paste raw assertion-heavy test code as documentation unless the documentation is specifically explaining testing. Convert Arrange/Act/Assert test structure into developer-oriented sample code.

The example must be:

- Realistic,
- Minimal,
- Deterministic,
- Copy/paste-ready,
- Buildable in a normal consuming project,
- Free of hidden repository-specific helpers unless those helpers are also public and documented,
- Free of pseudo-code,
- Free of ellipses inside code blocks,
- Free of unexplained magic values,
- Valid for the documented target framework availability.

Bad example pattern:

```csharp
// Arrange
var sut = new Foo();

// Act
var actual = sut.Bar();

// Assert
Assert.Equal("baz", actual);
```

Preferred documentation pattern:

```csharp
using My.Library;

var formatter = new Foo();
string value = formatter.Bar();
Console.WriteLine(value);
```

If assertions are useful, use them only when the sample is explicitly framed as a test sample and can compile in that test context.

## Example Verification

Every code sample added or changed must be verified. A C# code sample must compile.

The deterministic validator compiles C# documentation samples as .NET 10 file-based apps. Run:

```bash
dotnet run --file skills/dotnet-docfx-digest/scripts/docfx.cs -- --repo-root .
```

A sample may opt out only when the code fence includes:

```csharp
// dotnet-docfx-digest:skip-compile - <reason>
```

The reason is mandatory. Do not use silent opt-outs.

Do not claim a sample compiles unless the validator or an equivalent repository verification command has compiled it successfully.

## Namespace Overview Pages

Every namespace containing public API must have a namespace overview Markdown page.

The namespace overview page must be named after the namespace:

```text
X.Y.Z.md
```

The page must live in the appropriate DocFX documentation folder for namespace overwrite/custom content. For Codebelt repositories, place namespace overview pages under the `.docfx` documentation structure according to the existing repository layout.

The namespace page must use DocFX overwrite front matter with the namespace UID:

```markdown
---
uid: X.Y.Z
summary: *content
---
```

The page must provide a developer-friendly fly-in explaining what the namespace is for. The fly-in should be similar in usefulness and tone to Microsoft .NET API documentation:

- Start with what the namespace contains.
- Explain the developer problem it solves.
- Explain when to use it.
- Mention important concepts or type families.
- Avoid marketing language.
- Avoid restating type names without explaining purpose.
- Keep the explanation accurate to the public API.

Minimum namespace overview structure:

```markdown
---
uid: X.Y.Z
summary: *content
---
The `X.Y.Z` namespace contains types that ...

[!INCLUDE [availability-default](../../includes/availability-default.md)]
```

If the namespace contains extension methods, include an `Extension Members` section.

## Extension Method Documentation

Extension methods must be documented at namespace level.

If any public type exposes public extension members in namespace `X.Y.Z`, then the DocFX documentation must include:

```text
X.Y.Z.md
```

This file must contain an `Extension Members` section. The section must list public extension methods exposed by that namespace.

Required table format:

```markdown
### Extension Members

|Type|Ext|Methods|
|--:|:-:|---|
|ITestOutputHelper|⬇️|`WriteLines`|
|String|⬇️|`ReplaceLineEndings` (TFM netstandard2.0)|
```

Rules for the table:

- `Type` is the extended type, not the static extension class.
- `Ext` must use `⬇️`.
- `Methods` lists public extension methods.
- Use backticks around method names.
- Include TFM-specific availability when a method is conditional.
- Group overloads under the same method name unless overload distinction is essential.
- Do not include internal/private extension methods.
- Do not include extension classes as the primary documentation target unless the class itself has relevant public API beyond extension methods.

Example:

```markdown
### Extension Members

|Type|Ext|Methods|
|--:|:-:|---|
|String|⬇️|`ToSlug`, `NormalizeLineEndings`|
|IEnumerable<T>|⬇️|`ForEach`, `Batch`|
```

## Availability Documentation

Availability information must be present for public API documentation.

Availability can be documented in either of two ways:

1. By referencing an existing include file.
2. By writing explicit availability text when no suitable include exists.

Prefer include files when the repository has an `includes` folder with Markdown files that define availability.

Example include:

```markdown
[!INCLUDE [availability-default](../../includes/availability-default.md)]
```

Example explicit availability:

```markdown
Availability: .NET 10, .NET 9 and .NET Standard 2.0.
```

If a suitable include exists, reference it instead of duplicating availability text. If no suitable include exists, explicit availability is acceptable.

Do not add redundant availability text if the page already references an availability include that covers the same API surface.

When availability differs by type, member, target framework, or platform, document the difference close to the affected item.

Availability must reflect actual project files, conditional compilation, target frameworks, package metadata, and source code.

## DocFX Overwrite Files

Use DocFX overwrite files to modify or add content for generated API items without editing generated metadata directly.

Overwrite files must include YAML front matter with the target `uid`. Example:

```markdown
---
uid: X.Y.Z.MyType
summary: *content
---
```

The `uid` must match the generated DocFX UID. Do not guess UIDs. Verify them from generated metadata, existing API pages, source conventions, or DocFX output.

Use overwrite files for:

- Namespace overview pages,
- Additional conceptual remarks,
- Examples,
- Corrected summaries,
- Extension-method namespace documentation,
- Availability notes,
- Developer-oriented usage guidance.

Do not use overwrite files to conceal inaccurate XML documentation. Correct the source XML documentation when it is wrong.

When the validator reports `EXAMPLE_MISSING`, create or update DocFX overwrite content for the reported UID instead of treating the missing example as a prose-only issue.

## XML Documentation Comments

Public API should have useful XML documentation comments. Prefer concise source-level XML comments and richer examples/remarks in DocFX overwrite files when documentation becomes long.

XML documentation should describe:

- Purpose,
- Parameters,
- Return value,
- Exceptions,
- Type parameters,
- Important behavior,
- Nullability expectations,
- Thread-safety or lifecycle behavior when relevant.

Do not use empty boilerplate summaries.

Bad:

```csharp
/// <summary>
/// Gets or sets the value.
/// </summary>
```

Better:

```csharp
/// <summary>
/// Gets or sets the normalized name used when matching configuration keys.
/// </summary>
```

## Preservation Rules

Manual edits must be preserved.

Before editing an existing Markdown file:

1. Read the entire file.
2. Identify manually written sections.
3. Preserve structure and tone where possible.
4. Add new information in the most appropriate existing section.
5. Avoid replacing the whole file unless the file is clearly generated or corrupt.
6. Keep existing includes, admonitions, links, and examples unless they are stale.
7. Update stale statements instead of appending contradictory new statements.

Documentation must stay current. If additive-only editing would leave conflicting or stale information, update the stale information. Accuracy is more important than blindly appending content. Never leave two conflicting descriptions of the same API behavior.

## Style Rules

Use developer-friendly documentation style.

Prefer:

- Direct explanations,
- Practical examples,
- Concrete behavior,
- Accurate terminology,
- Small complete samples,
- Links to related APIs when useful,
- Namespace-level fly-ins that explain purpose.

Avoid:

- Marketing language,
- Placeholder text,
- "Simply",
- "Just",
- "Obviously",
- Pseudo-code,
- Incomplete snippets,
- Unverified claims,
- Duplicating generated API signatures manually,
- Restating the namespace name without explaining its purpose.

## Documentation Workflow

When the user names a changed API or namespace:

1. Run `agents.cs`.
2. Inspect the changed public API.
3. Determine affected namespaces.
4. Determine whether public extension methods are involved.
5. Locate `.docfx/docfx.json` or repository-specific DocFX config.
6. Locate existing overwrite files and namespace pages.
7. Locate availability include files.
8. Locate relevant tests that demonstrate the API.
9. Convert test usage into real-life documentation examples.
10. Update XML documentation where needed.
11. Update or create namespace overview pages.
12. Update extension-member tables.
13. Update or create overwrite files, including example sections for concrete public types and public extension methods.
14. Preserve manual edits.
15. Run `dotnet build`.
16. Run `dotnet test`.
17. Run `docfx .docfx/docfx.json`.
18. Run `docfx.cs`.
19. Report verification results.

When no specific API or namespace is named:

1. Run `agents.cs`.
2. Read repository guidance, especially root `AGENTS.md`.
3. Locate `.docfx/docfx.json` or repository-specific DocFX config.
4. Read `references/docfx-overwrite-files.md`.
5. Run `dotnet run --file skills/dotnet-docfx-digest/scripts/docfx.cs -- --repo-root . --json` to collect deterministic missing-doc findings when the repository is buildable.
6. If the validator fails before documentation diagnostics can be produced, inspect source projects, DocFX config, existing overwrite files, generated metadata when available, tests, and samples manually.
7. Determine every namespace containing public API and whether each namespace exposes public extension methods.
8. Determine every concrete public type and every public extension method that requires an example.
9. Create or update missing namespace overview pages using DocFX overwrite front matter and developer-friendly fly-ins.
10. Add or repair `Extension Members` tables for namespaces with public extension methods.
11. Add or repair overwrite content for public API items that need examples, remarks, corrected summaries, or availability notes.
12. Create overwrite example sections for concrete public types and public extension methods that have no example yet.
13. Preserve manual edits and correct stale contradictions instead of replacing whole files.
14. Run `dotnet build`.
15. Run `dotnet test`.
16. Run `docfx .docfx/docfx.json`.
17. Run `docfx.cs`.
18. Report verification results and any remaining findings.

## Namespace Page Template

Use this template when creating a new namespace overview page:

```markdown
---
uid: X.Y.Z
summary: *content
---
The `X.Y.Z` namespace contains types that ...

[!INCLUDE [availability-default](../../includes/availability-default.md)]

### Extension Members

|Type|Ext|Methods|
|--:|:-:|---|
|String|⬇️|`ExampleMethod`|
```

Remove the `Extension Members` section when the namespace has no public extension methods. Adjust the include path based on the actual file location.

## Type Example Template

Use this shape for concrete public type examples:

````markdown
### Examples

The following example shows how to use `MyType` in a consuming application.

```csharp
using X.Y.Z;

var value = new MyType();
Console.WriteLine(value);
```
````

The sample must compile. Do not include `using` directives for namespaces that do not exist. Do not use APIs that are internal to the repository unless the sample is explicitly for contributors and not public API consumers.

## Extension Method Example Template

Use this shape for extension-method examples:

````markdown
### Examples

The following example shows how to call `NormalizeLineEndings` on a string.

```csharp
using X.Y.Z;

string text = "first\r\nsecond";
string normalized = text.NormalizeLineEndings();
Console.WriteLine(normalized);
```
````

The namespace containing the extension method must be imported. The sample must compile in a consuming project.

## Verification Checklist

Before completing documentation work, verify:

- [ ] `agents.cs` has run successfully.
- [ ] `AGENTS.md` contains the managed DocFX documentation maintenance block.
- [ ] Only public API is documented.
- [ ] Every namespace with public API has a namespace overview page.
- [ ] Namespaces with public extension methods have an `Extension Members` section.
- [ ] Extension methods are documented by extended type, not extension class.
- [ ] Concrete public APIs have at least one example.
- [ ] Public extension methods have at least one example, not only a table entry.
- [ ] Missing examples are added through DocFX overwrite content included by `build.overwrite`.
- [ ] Abstractions without examples have a clear reason.
- [ ] Examples are realistic and copy/paste-ready.
- [ ] Examples compile.
- [ ] Examples are preferably derived from passing tests.
- [ ] Availability is included or explicitly stated.
- [ ] Availability matches actual target frameworks and conditions.
- [ ] Existing manual edits are preserved.
- [ ] Stale documentation is corrected.
- [ ] No contradictory documentation remains.
- [ ] `dotnet build` has been run or the failure is reported.
- [ ] `dotnet test` has been run or the failure is reported.
- [ ] `docfx .docfx/docfx.json` has been run or the failure is reported.
- [ ] `docfx.cs` has run successfully or the failure is reported.

## Completion Response

When reporting completion, include:

- Public APIs documented,
- Namespace pages added or updated,
- Extension-member tables added or updated,
- Examples added and their source test/sample when applicable,
- Availability handling,
- `AGENTS.md` created, updated, already compliant, or failed,
- Verification commands run,
- Any verification failures or skipped checks.

Do not claim documentation was verified unless the relevant command actually ran successfully.
