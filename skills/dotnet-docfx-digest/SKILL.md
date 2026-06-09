---
name: dotnet-docfx-digest
description: >
  Create and maintain developer-friendly DocFX documentation digests for .NET public APIs, including repo-wide no-input audits, concept-led namespace overview pages, purpose-first type/member summaries, extension-member documentation, overwrite files, examples, availability notes, AGENTS.md maintenance, and verification. Use when the user asks to document a .NET API, create or update DocFX documentation, write namespace overview pages, improve API summaries, add extension-method tables, update XML documentation comments, add API examples, maintain DocFX overwrite files, or verify documentation builds. Treat requests like "use dotnet-docfx-digest", "update the DocFX docs", "complete missing documentation", "create namespace pages", "improve these API summaries", "add examples for this type", "update the extension members table", or "verify the documentation builds" as automatic triggers. Also use whenever public .NET API surface changes and documentation needs to stay aligned with source code.
---

# .NET DocFX Digest Steward

## Description

Create and maintain developer-friendly DocFX documentation digests for .NET public APIs, including concept-led namespace overview pages, purpose-first type/member summaries, extension-member documentation, overwrite files, examples, availability notes, and verification. Preserve manual edits, document public API only, require buildable copy/paste-ready examples for concrete APIs, and keep documentation aligned with actual source code and tests.

## Activation Requirements

This skill is autonomous by default. If the user invokes the skill without naming a namespace, type, member, or changed API, do not ask what to document first. Treat the request as a repo-wide DocFX documentation audit and repair task:

1. Run the repository-instruction script.
2. Inspect repository guidance, `docfx.json`, source projects, generated metadata, tests, samples, existing overwrite files, namespace pages, and availability includes.
3. Run the validator to discover missing or stale complementary documentation.
4. Fill the missing DocFX pieces that can be derived from source evidence, including type-page overwrite examples for public non-abstraction types and public extension methods.
5. Ask a concise clarifying question only when inspection exposes a correctness-affecting choice that cannot be resolved from repository evidence.

When this skill is invoked against a repository, resolve the target repository root and bundled script paths before running any validation. Prefer the loaded `dotnet-docfx-digest` skill directory as the script source, for example `<skill-dir>/scripts/agents.cs` and `<skill-dir>/scripts/docfx.cs`. If the loaded skill directory is unavailable and the target repository contains the repo-managed source copy, use `skills/dotnet-docfx-digest/scripts/*.cs`. Do not conclude a script is unavailable until both locations have been checked.

Run the deterministic repository-instruction script before completing the task:

```bash
dotnet run --file <resolved-skill-dir>/scripts/agents.cs -- --repo-root <repo-root>
```

Before reporting completion, the agent must run the deterministic validator:

```bash
dotnet run --file <resolved-skill-dir>/scripts/docfx.cs -- --repo-root <repo-root> --verify-docfx-build
```

## Completion Repair Loop

Do not stop at namespace pages, extension-member tables, or a first-pass documentation edit. Those surfaces are useful discovery aids, but they do not prove that generated type pages have the required examples. Before deeming a DocFX documentation request complete, run a closure loop:

1. Run `docfx.cs --json` after edits and read the remaining diagnostics.
2. If diagnostics include `EXAMPLE_MISSING`, missing namespace pages, stale extension-member tables, sample compile failures, missing availability, or overwrite inclusion problems, treat them as the next work queue rather than final notes.
3. For every `EXAMPLE_MISSING` public non-abstraction type, create or update the type-page overwrite file for that type UID, such as `.docfx/api/ApplicationHostFactory.md`, and put the example in that file or another overwrite section that targets the type UID directly.
4. For every required example file, verify `build.overwrite` includes the file path or a glob that reaches it. Widen namespace-only overwrite globs when needed.
5. Update the example inventory so each required public non-abstraction type and public extension method maps to the exact example file and UID.
6. Rerun the validator and repeat the loop until required diagnostics are gone, or stop and report the exact blocker, command, exit code, and remaining diagnostic codes.

The completion loop is the guard against the common failure where an agent finishes namespace overview pages but forgets per-type API overwrite pages. Namespace-level examples do not satisfy `EXAMPLE_MISSING` for public non-abstraction types.

## Complementary Documentation Surfaces

Do not trade one documentation surface for the other. Namespace pages and per-type pages have different jobs, and both must remain useful:

- Namespace pages explain the package or namespace shape: what problem the namespace solves, when to use it, important type families, extension-method groups, availability, and links or references to representative type pages.
- Per-type pages explain what a specific public concrete type is for, when a developer would reach for it, and how to use it with copy/paste-ready examples.
- Extension-method examples normally live on the declaring extension class page or the namespace page, but the namespace page must still read like curated API documentation, not a dumping ground for examples.

When per-type examples are added, revisit the related namespace page and keep its fly-in well-versed and developer-friendly. Moving examples out of the namespace page must not leave the namespace page as a generic sentence plus table. Preserve or improve the curated namespace overview that helps readers choose the right type before they drill into generated type pages.

## Conceptual Orientation

Namespace pages, type summaries, and member summaries should orient a developer to purpose, not just inventory API shape. Use an inverted-pyramid writing order:

1. Lead with the biggest idea: what problem this namespace, type, or member solves, or what outcome it enables.
2. Follow with when a developer would use it in normal work.
3. Give quick orientation such as "If you're trying to do X, start with Y" when an entry-point type, option type, or extension method helps readers choose where to go next.
4. Then add structural detail such as important type families, representative members, or constraints.

Write for a developer who is new to the domain, not for someone who already knows why the API exists. A strong summary should answer "why would I care?" before it answers "what names live here?"

Avoid filing-cabinet labels such as "contains types and extension methods for..." or generic blurbs such as "represents options..." and "adds services..." when they are not followed by concrete purpose. Those phrases are acceptable only when the rest of the sentence explains the real job of the API.

Bad namespace summary:

```markdown
The `Acme.OpenApi.ModelContextProtocol` namespace contains types and extension methods for MCP integration.
```

Better namespace summary:

```markdown
The `Acme.OpenApi.ModelContextProtocol` namespace bridges Model Context Protocol servers with OpenAPI documentation. Use it when you want MCP-enabled services to stay discoverable through standard Swagger/OpenAPI tooling. If you're wiring the integration into an ASP.NET Core app, start with `AddMcpServer`.
```

Bad type/member summaries:

```csharp
/// <summary>
/// Represents options for the server.
/// </summary>

/// <summary>
/// Adds MCP server services.
/// </summary>
```

Better type/member summaries:

```csharp
/// <summary>
/// Configures how the MCP server is exposed through the application's OpenAPI pipeline.
/// </summary>

/// <summary>
/// Registers the MCP/OpenAPI integration during service configuration so MCP endpoints appear in generated API documentation.
/// </summary>
```

## Type-Page Example Gate

Before editing examples, build a small example inventory from validator output and source evidence. This inventory is the task queue, not a summary for the final response. Each required item should have this shape:

```markdown
| UID | Kind | Required example location | Source evidence | Status |
|---|---|---|---|---|
| Codebelt.Extensions.Xunit.Hosting.ApplicationHostFactory | Type | .docfx/api/Codebelt.Extensions.Xunit.Hosting.ApplicationHostFactory.md | ApplicationHostFactoryTest | Missing |
```

For every public non-abstraction type, the required example location is a type UID overwrite section. In Codebelt repositories, default to a separate file named `.docfx/api/{TypeUid}.md`. For example, when the missing type is `ApplicationHostFactory`, create `.docfx/api/Codebelt.Extensions.Xunit.Hosting.ApplicationHostFactory.md` or the exact UID path reported by the validator. Do not put the only example in `.docfx/api/namespaces/*.md`, because that improves the namespace page while leaving the generated type page incomplete.

For public extension methods, the inventory must name the method and the section that demonstrates it. Prefer a readable overwrite file for the declaring extension class UID, or the namespace page when that is the existing extension-method documentation surface. Method UIDs can contain signatures, generic parameters, hashes, or URL-encoded characters — **never create filenames that mirror these synthetic UIDs** (e.g., `MyExtensions.-G-6D0D8037DBBD61D10816ECA5F93B896F.md` or `MyExtensions.%3CT%3E...md`). Always use the declaring extension class UID in front matter and keep the file at the readable class path. See the "Hash-Suffix Filenames Are Prohibited" section. The example must explicitly call the extension method.

Do not mark the inventory item complete until all of these are true:

- The overwrite section targets the required type UID or an allowed extension-method location such as the declaring extension class UID or namespace UID.
- `build.overwrite` includes the file by exact path or a glob such as `api/**/*.md`.
- The example code fence compiles or carries an explicit, justified skip marker.
- A rerun of `docfx.cs --json` no longer reports `EXAMPLE_MISSING` for that UID.

For repo-wide audits or any validation run that produces more than a small number of diagnostics, the agent must also ask the validator to write a deterministic repair plan and use that plan as the authoritative work queue:

```bash
dotnet run --file <resolved-skill-dir>/scripts/docfx.cs -- --repo-root <repo-root> --json --repair-plan <temp-path>/docfx-repair-plan.md
```

If either script cannot run, the agent must report the exact command, exit code, and failure output. Do not claim repository instructions or documentation were verified unless the scripts ran successfully.

Read `references/scripts.md` when you need the exact CLI surface, exit codes, JSON diagnostics, or validator behavior for `agents.cs` and `docfx.cs`.

## Core Principles

Documentation is part of the public contract. When changing public .NET APIs, the agent must update the corresponding documentation in the same change set. This includes XML documentation comments, DocFX overwrite files, namespace overview pages, examples, extension-method listings, and availability information.

The documentation must reflect the actual code, not intended code. Do not invent APIs, overloads, target frameworks, behaviors, exceptions, or examples. Verify every documented claim against source code, tests, project files, generated metadata, or existing documentation.

Manual documentation is authoritative context. Preserve existing manual edits unless they are factually incorrect. Prefer additive changes. When information is stale, update the stale portion while retaining nearby human-written explanations, tone, and structure.

## Safety Gates

Before making documentation changes, capture the current repository state:

1. Run `git status --short` and identify modified, staged, and untracked documentation files.
2. If source documentation files already have uncommitted changes, treat them as user work. Do not overwrite, restore, reformat, or regenerate them wholesale.
3. Read each affected Markdown file before editing it.
4. For cleanup candidates, list the exact files or directories first and classify them as generated metadata, generated site output, build artifacts, or authored documentation.

Before any git operation that can discard or overwrite content, stop and report the exact files that would be affected. Do not run broad `git restore`, `git checkout --`, `git reset`, or whole-directory recovery commands on documentation source directories. If recovery is needed, recover only the specific generated or accidentally removed file after inspecting `git status` and `git diff`.

After modifications, run `git diff` for the touched documentation paths and verify the diff contains only intended documentation changes. If the work cannot be completed without partial, inconsistent, or unverifiable documentation, stop and report the limitation instead of proceeding partially.

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
dotnet run --file <resolved-skill-dir>/scripts/agents.cs -- --repo-root <repo-root>
```

The script must create or update a marker-bounded DocFX documentation maintenance section in the repository root `AGENTS.md`. Resolve `<repo-root>` from the actual repository being documented, not from a temp workspace or the skill install folder. If the current working directory is already the target repository root, `<repo-root>` may be `.` after confirming it with repository evidence such as `git rev-parse --show-toplevel` or equivalent path inspection. Do not manually duplicate this section. If the script fails, report the exact command, exit code, and output, and do not claim `AGENTS.md` was updated.

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

Every automatically documented public non-abstraction type and every public extension method must include at least one example showing how to use it. A namespace overview fly-in or `Extension Members` table is not enough.

Do not treat an `Extension Members` table as documentation completion. A table answers "what exists"; an example answers "how a consumer uses it." For each public extension method discovered or listed in a namespace page, create or verify an example before moving to final verification. If several related namespace pages are updated together, build an example inventory that maps every public extension method and every public non-abstraction type to the exact overwrite file and UID where its example lives.

Create or repair DocFX overwrite content for missing examples. If an overwrite section for the target `uid` does not exist, create a separate per-type Markdown overwrite file by default. For Codebelt repositories, the default type example file is:

```text
.docfx/api/{TypeUid}.md
```

For example, create `.docfx/api/Codebelt.Bootstrapper.ProgramRoot.md` for uid `Codebelt.Bootstrapper.ProgramRoot`. If `build.overwrite` does not include the chosen per-type file path, update `docfx.json` so the overwrite glob includes both namespace pages and per-type API overwrite files, such as `api/**/*.md`. Do not hide type examples in namespace pages because the current overwrite glob only includes namespace files.

For public non-abstraction types, the example must belong to the generated type page/overwrite section for that type `uid`. For example, if `Class1` is public and not an abstraction, add an `Examples` section to the DocFX overwrite content for `Class1` so the example appears on `Class1.md` at the bottom of the generated API page. A namespace page example does not satisfy the type-page example requirement for `Class1`.

For public extension methods, add the example to the declaring extension class UID or the namespace page by default, but the example must name and demonstrate the extension method. Add a generated method UID section only when the exact UID is verified and it can be kept in a readable overwrite file. Do not create URL-encoded or hash-like filenames just to mirror a method UID; DocFX cares about the `uid` in front matter, not that the filename repeats the UID.

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

The deterministic validator compiles C# documentation samples as .NET 10 file-based apps. When completing DocFX documentation work, also ask it to verify the DocFX build in a temporary copy of the repository so generated metadata and site output stay outside the working tree. Run:

```bash
dotnet run --file <resolved-skill-dir>/scripts/docfx.cs -- --repo-root <repo-root> --verify-docfx-build
```

A sample may opt out only when the code fence includes:

```csharp
// dotnet-docfx-digest:skip-compile - <reason>
```

The reason is mandatory. Do not use silent opt-outs.

Use skip markers sparingly. A reason such as "shows the framework pattern", "full example requires X package", or "example only" is not enough; it explains intent or setup, not why compilation is impossible. Prefer making the sample compile by adding normal public setup code, public package imports already available to the repository, or a smaller example. Reserve skip markers for samples that cannot be compiled deterministically by the validator, such as snippets that require a live external service, generated credentials, an OS-specific runtime service, or a host environment the file-based sample compiler cannot provide.

Do not claim a sample compiles unless the validator or an equivalent repository verification command has compiled it successfully.

## Codebelt Signing Keys

Codebelt solutions are normally strong-name signed with a `.snk` file in the repository root on the main author's codespace. When building a Codebelt repository or a temporary copy of one, preserve and copy the root `.snk` file when it is present. If the target repository or temp copy does not have a root `.snk`, run build and test verification with signing disabled:

```bash
dotnet build -p:SkipSignAssembly=true
dotnet test -p:SkipSignAssembly=true
```

Use the same MSBuild property for any equivalent repository build that documentation validation performs. This avoids reporting signing-key failures as documentation failures while preserving normal signed builds when the key is available.

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

- Lead with the developer problem or outcome the namespace exists for.
- Explain when to use it.
- Give quick orientation for a newcomer, such as "If you're trying to do X, start with Y."
- Mention important concepts or type families.
- Mention representative concrete types or extension-method groups when that helps readers choose where to go next.
- Link or refer to type pages that carry detailed examples when examples are intentionally kept out of the namespace page.
- Avoid marketing language.
- Avoid inventory-only wording that merely restates type names without explaining purpose.
- Keep the explanation accurate to the public API.
- Use the inverted-pyramid structure from the Conceptual Orientation section before falling back to structural detail.

Minimum namespace overview structure:

```markdown
---
uid: X.Y.Z
summary: *content
---
The `X.Y.Z` namespace helps you ...
Use it when ...
If you're trying to ..., start with `PrimaryType` or `PrimaryExtensions`.

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

When a repository has namespace overview files but no per-type overwrite files, create the per-type files. Do not treat the absence of existing type files as a signal to skip examples. For Codebelt repositories, place new type files beside generated API metadata under `.docfx/api/` and update `build.overwrite` if it currently points only at `.docfx/api/namespaces/**/*.md`.

## Namespace Coverage

When one namespace page in a public API family needs repair, audit the sibling namespace pages before finishing. For example, if `Codebelt.Bootstrapper.md` is touched, also inspect related namespace pages such as `Codebelt.Bootstrapper.Console.md`, `Codebelt.Bootstrapper.Web.md`, and `Codebelt.Bootstrapper.Worker.md` when they exist. Apply the same correctness rules to every affected namespace page: accurate fly-in, availability, extension-member table, and required examples.

Do not update only the first namespace file that exposes the problem. If only one namespace is intentionally changed, state why the other related namespace pages were inspected and left unchanged.

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

The opening summary sentence should explain the API's job in consumer terms. Lead with purpose and likely use, especially for entry-point extension methods, option types, factories, builders, and orchestration types. Prefer "what this enables and when to call it" over empty structural labels.

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

Bad:

```csharp
/// <summary>
/// Represents options for the server.
/// </summary>

/// <summary>
/// Adds MCP server services.
/// </summary>
```

Better:

```csharp
/// <summary>
/// Configures how the MCP server is exposed through the application's OpenAPI pipeline.
/// </summary>

/// <summary>
/// Registers the MCP/OpenAPI integration during service configuration so MCP endpoints appear in generated API documentation.
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

## Cleanup Boundary

Authored DocFX Markdown is documentation output, not disposable build output. This includes namespace overview pages, per-type overwrite files, conceptual pages, includes, and Markdown files created earlier in the same run. Do not delete `.md` or `.mdoc` files, `docfx.json`, `toc.yml`, includes, images, examples, or directories that contain authored documentation while cleaning generated artifacts unless the user explicitly asks for that deletion.

Prefer `docfx.cs --verify-docfx-build` because it runs DocFX in a temp copy and removes that temp workspace itself. After verification, do not run broad manual cleanup commands such as deleting DocFX directories by name. If `git status` shows remaining files, classify each path first:

- Generated metadata cleanup is limited to DocFX-generated `*.yml`, `.manifest`, and `*.manifest` files under configured metadata destinations.
- Generated site cleanup is limited to the configured `build.dest` directory when it is clearly generated output and contains no authored Markdown, source, project, solution, or DocFX configuration files.
- Build artifacts such as `bin/` and `obj/` directories may be cleanup candidates only after confirming they are build output and not documentation source.
- Authored documentation changes, especially Markdown files included by `build.content` or `build.overwrite`, must be kept and reported as created or updated documentation.

If a cleanup candidate is ambiguous, leave it in place and report the ambiguity instead of deleting it.

If a cleanup command accidentally deletes authored documentation, stop and inspect `git status` and `git diff` before attempting recovery. Do not run broad `git restore`, `git checkout --`, or equivalent whole-directory restores to hide the mistake. Those commands can discard already checked-out documentation work and make the final files worse than before. Recover only the exact files that were incorrectly removed, preserve any edits made earlier in the run, and report the recovery steps honestly.

## Style Rules

Use developer-friendly documentation style.

Prefer:

- Direct explanations,
- Practical examples,
- Concrete behavior,
- Accurate terminology,
- Small complete samples,
- Links to related APIs when useful,
- Namespace-level fly-ins that explain purpose,
- Purpose-first type/member summaries that explain why a developer would use the API.

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
- Restating the namespace name without explaining its purpose,
- Filing-cabinet summaries that only say what a namespace or type contains,
- Generic verbs like "represents", "provides", or "adds" when they do not explain the API's real role.

## Documentation Workflow

When the user names a changed API or namespace:

1. Run `agents.cs`.
2. Run the safety gates: capture `git status`, identify existing documentation changes, and avoid broad restore/recovery commands.
3. Inspect the changed public API.
4. Determine affected namespaces.
5. Determine whether public extension methods are involved.
6. Locate `.docfx/docfx.json` or repository-specific DocFX config.
7. Locate existing overwrite files and namespace pages.
8. Locate availability include files.
9. Locate relevant tests that demonstrate the API.
10. Convert test usage into real-life documentation examples.
11. Update XML documentation where needed, especially purpose-first type/member summaries for public entry points and high-traffic APIs.
12. Update or create namespace overview pages with conceptual orientation and start-here cues.
13. Inspect sibling namespace pages in the same public API family and repair each affected page consistently.
14. Update extension-member tables.
15. Update or create overwrite files, including type-page example sections for public non-abstraction types and example sections for public extension methods.
16. Build an example inventory that maps each required public type and extension method to its example location.
17. Preserve manual edits.
18. Run `git diff` for touched documentation paths and confirm the diff is intentional.
19. Run `dotnet build`, or `dotnet build -p:SkipSignAssembly=true` when a Codebelt repository has no root `.snk`.
20. Run `dotnet test`, or `dotnet test -p:SkipSignAssembly=true` when a Codebelt repository has no root `.snk`.
21. Run the Completion Repair Loop: rerun `docfx.cs --json`, read remaining diagnostics, repair missing per-type examples and overwrite inclusion issues, update the example inventory, and repeat until required diagnostics are gone or a precise blocker is reported.
22. Run `docfx.cs --verify-docfx-build` so the DocFX CLI runs against a temp copy of the repository.
23. Inspect `git status` and confirm no disposable generated DocFX metadata or build output remained in the working tree; preserve authored Markdown and other documentation files.
24. Report verification results.

When no specific API or namespace is named:

1. Run `agents.cs`.
2. Run the safety gates: capture `git status`, identify existing documentation changes, and avoid broad restore/recovery commands.
3. Read repository guidance, especially root `AGENTS.md`.
4. Locate `.docfx/docfx.json` or repository-specific DocFX config.
5. Read `references/docfx-overwrite-files.md`.
6. Run `dotnet run --file <resolved-skill-dir>/scripts/docfx.cs -- --repo-root <repo-root> --json` to collect deterministic missing-doc findings when the repository is buildable.
7. If the validator reports multiple diagnostics, rerun it with `--repair-plan <temp-path>/docfx-repair-plan.md`, read that plan, and treat it as the work queue.
8. If the validator fails before documentation diagnostics can be produced, inspect source projects, DocFX config, existing overwrite files, generated metadata when available, tests, and samples manually.
9. Determine every namespace containing public API and whether each namespace exposes public extension methods.
10. Determine every public non-abstraction type and every public extension method that requires an example.
11. Create or update missing namespace overview pages using DocFX overwrite front matter and developer-friendly fly-ins that lead with purpose, use case, and start-here guidance.
12. Audit related namespace pages together so fixes are consistent across the public API family.
13. Add or repair `Extension Members` tables for namespaces with public extension methods.
14. Add or repair overwrite content for public API items that need examples, remarks, corrected summaries, or availability notes.
15. Create separate type-page overwrite files for public non-abstraction types that have no example yet, using `.docfx/api/{TypeUid}.md` in Codebelt repositories unless the repo has a stronger existing convention.
16. Ensure `build.overwrite` includes the per-type overwrite files you create; update a namespace-only overwrite glob to include API overwrite files when needed.
17. Create example sections for public extension methods that have no example yet.
18. Build an example inventory that maps each required public type and extension method to its example location.
19. Preserve manual edits and correct stale contradictions instead of replacing whole files.
20. Run `git diff` for touched documentation paths and confirm the diff is intentional.
21. Run `dotnet build`, or `dotnet build -p:SkipSignAssembly=true` when a Codebelt repository has no root `.snk`.
22. Run `dotnet test`, or `dotnet test -p:SkipSignAssembly=true` when a Codebelt repository has no root `.snk`.
23. Run the Completion Repair Loop: rerun `docfx.cs --json`, read remaining diagnostics, repair missing per-type examples and overwrite inclusion issues, update the example inventory, and repeat until required diagnostics are gone or a precise blocker is reported.
24. Run `docfx.cs --verify-docfx-build` so the DocFX CLI runs against a temp copy of the repository.
25. Inspect `git status` and confirm no disposable generated DocFX metadata or build output remained in the working tree; preserve authored Markdown and other documentation files.
26. Report verification results and any remaining findings.

## Namespace Page Template

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

Remove the `Extension Members` section when the namespace has no public extension methods. Adjust the include path based on the actual file location. Mirror the same purpose-first narrative in any nearby type summaries or entry-point member summaries you touch so the namespace page and generated API pages orient readers consistently.

## Type Example Template

Use this shape for public non-abstraction type examples. The overwrite file **must** begin with YAML front matter that maps the body to the `example` property using `example:\n- *content`. This maps the Markdown body to the first slot in the `example` array, which DocFX renders as the "Examples" section **alongside** the auto-generated content (constructors, methods, etc.).

**Critical**: Do NOT use `summary: *content` and do NOT omit the property mapping. Without `example:\n- *content`, the Markdown body maps to the `conceptual` property. In managed reference pages this suppresses the auto-generated API members, leaving only the custom content on the rendered page.

**Do not include a `### Examples` heading inside the body.** DocFX renders the "Examples" section header automatically from the `example` property; adding one manually creates a redundant nested heading.

Put this on the generated type page/overwrite section for the type `uid`; for a public `Class1`, the example belongs on the `Class1` API page, not only on the namespace page. When no type overwrite file exists yet, create a separate per-type file such as `.docfx/api/X.Y.Z.Class1.md` and ensure `build.overwrite` includes that file.

````markdown
---
uid: X.Y.Z.MyType
example:
- *content
---
The following example shows how to use `MyType` in a consuming application.

```csharp
using X.Y.Z;

var value = new MyType();
Console.WriteLine(value);
```
````

The sample must compile. Do not include `using` directives for namespaces that do not exist. Do not use APIs that are internal to the repository unless the sample is explicitly for contributors and not public API consumers.

## Extension Method Example Template

Use this shape for extension-method examples. Apply the same YAML front matter rule as type examples: use `example:\n- *content` so the body maps to the `example` property and not to `conceptual`. Do not include a `### Examples` heading in the body.

````markdown
---
uid: X.Y.Z.MyExtensions
example:
- *content
---
The following example shows how to call `NormalizeLineEndings` on a string.

```csharp
using X.Y.Z;

string text = "first\r\nsecond";
string normalized = text.NormalizeLineEndings();
Console.WriteLine(normalized);
```
````

The namespace containing the extension method must be imported. The sample must compile in a consuming project.

## Hash-Suffix Filenames Are Prohibited

DocFX generates synthetic UIDs for generic or overloaded extension methods that contain hash fragments, encoding characters, or computed suffixes. These UIDs look like:

```
Codebelt.Extensions.Carter.EndpointConventionBuilderExtensions.-G-6D0D8037DBBD61D10816ECA5F93B896F
Codebelt.Extensions.Carter.EndpointConventionBuilderExtensions.%3CT%3EWithResponseNegotiator...
```

**Never create an overwrite file whose name mirrors such a synthetic UID.** That means never creating filenames such as:

- `EndpointConventionBuilderExtensions.-G-6D0D8037DBBD61D10816ECA5F93B896F.md`
- `EndpointConventionBuilderExtensions.%3CT%3E....md`

DocFX resolves overwrites by the `uid` value in front matter, not by filename. Place the extension method example in the **declaring extension class** overwrite file (e.g., `.docfx/api/X.Y.Z.EndpointConventionBuilderExtensions.md`) or the namespace page, and use the class or namespace UID in front matter. If a validator reports a hash-suffix method UID, document that method's example in the declaring class file using the class UID — never create a per-method file with the encoded or hashed UID as the filename.

## Verification Checklist

Before completing documentation work, verify:

- [ ] `agents.cs` has run successfully.
- [ ] `AGENTS.md` contains the managed DocFX documentation maintenance block.
- [ ] Initial `git status --short` was inspected and existing documentation changes were treated as user work.
- [ ] For multi-diagnostic audits, `docfx.cs --repair-plan` was written, read, and used as the authoritative work queue.
- [ ] Only public API is documented.
- [ ] Every namespace with public API has a namespace overview page.
- [ ] Related namespace pages in the same public API family were inspected and updated consistently, or intentionally left unchanged with a reason.
- [ ] Namespaces with public extension methods have an `Extension Members` section.
- [ ] Extension methods are documented by extended type, not extension class.
- [ ] Public non-abstraction types have at least one type-page example.
- [ ] Public extension methods have at least one example, not only a table entry.
- [ ] An example inventory maps every required public type and extension method to its example file and UID.
- [ ] Missing examples are added through DocFX overwrite content included by `build.overwrite`.
- [ ] The Completion Repair Loop was run after edits, and remaining `EXAMPLE_MISSING` or overwrite inclusion diagnostics were fixed or reported as exact blockers.
- [ ] Abstractions without examples have a clear reason.
- [ ] Examples are realistic and copy/paste-ready.
- [ ] Examples compile.
- [ ] Examples are preferably derived from passing tests.
- [ ] Availability is included or explicitly stated.
- [ ] Availability matches actual target frameworks and conditions.
- [ ] Existing manual edits are preserved.
- [ ] Stale documentation is corrected.
- [ ] No contradictory documentation remains.
- [ ] `git diff` for touched documentation paths was inspected before final verification.
- [ ] `dotnet build` has been run, using `-p:SkipSignAssembly=true` when a Codebelt repository has no root `.snk`, or the failure is reported.
- [ ] `dotnet test` has been run, using `-p:SkipSignAssembly=true` when a Codebelt repository has no root `.snk`, or the failure is reported.
- [ ] `docfx.cs --verify-docfx-build` has run successfully, including the temp-workspace DocFX build, or the failure is reported.
- [ ] Generated DocFX metadata files and build output directories did not remain in the working tree after verification, and authored Markdown or documentation assets were not deleted as cleanup.
- [ ] No broad restore or checkout command discarded authored documentation changes.

## Completion Response

When reporting completion, include:

- Public APIs documented,
- Namespace pages added or updated,
- Extension-member tables added or updated,
- Examples added, their source test/sample when applicable, and the example inventory by public type or extension method,
- Availability handling,
- Related namespace pages inspected and whether each was updated or left unchanged,
- `AGENTS.md` created, updated, already compliant, or failed,
- Signing-key handling: whether a root `.snk` was used/copied or `-p:SkipSignAssembly=true` was used because no root `.snk` was present,
- Verification commands run,
- Any verification failures or skipped checks.

Do not claim documentation was verified unless the relevant command actually ran successfully.
