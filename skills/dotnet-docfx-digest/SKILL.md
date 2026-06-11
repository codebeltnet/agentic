---
name: dotnet-docfx-digest
description: >
  Create and maintain developer-friendly DocFX documentation digests for .NET public APIs, including repo-wide no-input audits, concept-led namespace overview pages, purpose-first type/member summaries, extension-member documentation, overwrite files, examples, availability notes, AGENTS.md maintenance, and verification. Use when the user asks to document a .NET API, create or update DocFX documentation, write namespace overview pages, improve API summaries, add extension-method tables, update XML documentation comments, add API examples, maintain DocFX overwrite files, or verify documentation builds. Treat requests like "use dotnet-docfx-digest", "update the DocFX docs", "complete missing documentation", "create namespace pages", "improve these API summaries", "add examples for this type", "update the extension members table", or "verify the documentation builds" as automatic triggers. Also use whenever public .NET API surface changes and documentation needs to stay aligned with source code.
---

# .NET DocFX Digest Steward

## Description

Create and maintain developer-friendly DocFX documentation digests for .NET public APIs. Keep namespace pages, generated API pages, examples, availability notes, and verification aligned with the actual source code and tests.

## Critical

- This skill is autonomous by default. If the user invokes it without naming a namespace, type, member, or changed API, treat the request as a repo-wide DocFX audit and repair task instead of asking what to document first.
- Resolve bundled scripts from the loaded `dotnet-docfx-digest` skill directory first. If that install path is unavailable and the target repository contains the repo-managed source copy, fall back to `skills/dotnet-docfx-digest/scripts/*.cs`. Do not claim the scripts are unavailable until both locations have been checked.
- Before claiming completion, run:

```bash
dotnet run --file <resolved-skill-dir>/scripts/agents.cs -- --repo-root <repo-root>
dotnet run --file <resolved-skill-dir>/scripts/docfx.cs -- --repo-root <repo-root> --verify-docfx-build
```

- After edits, run `docfx.cs --json` and treat any remaining diagnostics as the next work queue, not as final notes. For noisy audits, also write and read a deterministic `--repair-plan`.
- If either script cannot run, report the exact command, exit code, and failure output. Do not claim repository guidance or documentation was verified unless the scripts actually ran successfully.
- Read `references/workflow.md` when you need the detailed targeted/audit workflows, namespace and example templates, the verification checklist, or the completion response shape.

## Completion Repair Loop

Do not stop at namespace pages, extension-member tables, or a first-pass documentation edit.

1. Run `docfx.cs --json` after edits and read the remaining diagnostics.
2. If diagnostics include `EXAMPLE_MISSING`, missing namespace pages, stale extension-member tables, sample compile failures, missing availability, or overwrite inclusion problems, treat them as blocking follow-up work.
3. For each missing public concrete-type example, create or update a type-targeting overwrite file under `.docfx/api/types/`.
4. For each missing extension-method example, document it on the declaring extension class page or the namespace page, and explicitly demonstrate the method call.
5. Rerun the validator until the required diagnostics are gone, or stop and report the exact blocker, command, exit code, and remaining diagnostic codes.

Namespace pages and `Extension Members` tables complement type-page examples; they do not replace them. Both namespace pages (`api/namespaces/`) and type pages (`api/types/`) are required deliverables. Generating only one is incomplete work.

## Core Principles

Documentation is part of the public contract. When public .NET API changes, update the corresponding XML comments, DocFX overwrite content, namespace pages, examples, availability notes, and verification steps in the same change set.

Document only what the code actually exposes. Do not invent APIs, overloads, target frameworks, behaviors, exceptions, or examples. Verify claims against source code, generated metadata, project files, tests, or existing documentation.

Manual documentation is authoritative context. Preserve hand-written Markdown and overwrite content unless it is stale or incorrect. Prefer additive edits, but fix contradictions instead of appending conflicting prose.

Namespace pages and type pages have different jobs. Namespace pages orient readers to the problem space and where to start; generated type pages explain concrete public APIs and must carry concrete examples for public non-abstraction types.

Write with an inverted-pyramid structure. Lead with the problem solved, explain when to use the API, give a short “start here” cue when helpful, then add structural detail.

## Safety Gates

Before editing documentation:

1. Run `git status --short` and identify modified, staged, and untracked documentation files.
2. Treat existing uncommitted documentation changes as user work.
3. Read each Markdown file before editing it.
4. Classify any cleanup candidate as generated metadata, generated site output, build artifacts, or authored documentation before deleting anything.

Do not use broad `git restore`, `git checkout --`, `git reset`, or whole-directory recovery commands on documentation source directories. If recovery is needed, recover only the specific generated or accidentally removed file after inspecting `git status` and `git diff`.

After modifications, inspect `git diff` for touched documentation paths and confirm the diff contains only intended changes.

## Scope

Apply this skill to:

- public .NET namespaces that contain public API
- public types and delegates
- public constructors, properties, methods, fields, events, and enum members
- public extension methods
- DocFX overwrite Markdown files
- namespace overview pages
- XML documentation comments
- API examples
- availability includes or availability statements

Do not document private or internal API, implementation-only helpers, or namespaces that contain no public API.

## DocFX Discovery and Script Usage

For Codebelt repositories, the DocFX workspace is `.docfx` and the configuration file is `.docfx/docfx.json`. For other repositories, locate `docfx.json` before making DocFX-specific changes.

Inspect `docfx.json` before editing so you understand content roots, overwrite file locations, include paths, metadata inputs, and output conventions. When creating or repairing overwrite files, read `references/docfx-overwrite-files.md`. When you need exact CLI arguments, exit codes, JSON diagnostics, or validator behavior for `agents.cs` and `docfx.cs`, read `references/scripts.md`.

Run `agents.cs` against the actual repository root being documented, not a temp workspace or the skill install directory. The script manages a marker-bounded DocFX maintenance block in the repository root `AGENTS.md`; do not hand-edit or duplicate that block.

## Required Documentation Surfaces

When public API is added or materially changed, update every relevant surface:

1. XML documentation comments in source code.
2. Namespace overview pages for namespaces that contain public API, under `.docfx/api/namespaces/`.
3. `Extension Members` tables for namespaces that expose public extension methods.
4. Type-targeting overwrite content for public non-abstraction types that require examples or richer guidance, under `.docfx/api/types/`.
5. Extension-method examples on the declaring extension class page or the namespace page.
6. Availability information.
7. Verification commands or artifacts that prove the documentation remains accurate and buildable.

Namespace pages and type pages are both required deliverables in the same run. Do not generate namespace pages without type pages or vice versa.

Material changes include new or removed public API, signature or nullability changes, behavioral changes, exception changes, changed availability, conditional extension-method availability, deprecation changes, default-value changes, or meaningful lifecycle and thread-safety changes.

## Examples and Overwrites

Every public non-abstraction type and every public extension method needs at least one realistic, minimal, copy/paste-ready example. A namespace fly-in or `Extension Members` table alone is not enough.

**Tests are evidence, not output.** Do not add `ShowUsage`, `Usage`, `Example`, or documentation-only methods to test files. Use tests to understand the documented type's behavior, then transform that knowledge into consumer-facing DocFX overwrite examples.

Every generated `csharp` code block is a complete, copy/paste-ready compilation unit. The default is always a compilable unit (option 1). Only use intentionally incomplete excerpts (option 2) when explicitly requested by the user, and label them clearly.

**Complete C# example contract:**

- Includes all required `using` directives.
- Declares a file-scoped namespace (e.g., `namespace X.Y;`).
- Declares at least one concrete class, struct, or record containing the usage.
- Does **not** use top-level statements unless the example is explicitly labelled `// Program.cs` at the very top of the code block.
- Does **not** invent placeholder services, interfaces, classes, methods, or overloads that are not defined inside the same code block.
- Does **not** derive from an abstract or generic base type without supplying the correct concrete type arguments.
- Does **not** call members that do not exist on the resolved public API surface.
- Compiles in a minimal class library verification project referencing the documented assemblies.

Prefer examples derived from existing unit, functional, or integration tests as behavioral evidence, then from samples, then from a minimal new example based on actual public behavior. Convert Arrange/Act/Assert test structure into consumer-oriented sample code instead of pasting raw test assertions, mocks, or fixture setup.

For public non-abstraction types, put the example on the generated type page by targeting the type UID in DocFX overwrite content. In Codebelt repositories, keep authored type overwrite Markdown under `.docfx/api/types/`, typically as `.docfx/api/types/{TypeUid}.md`.

For public extension methods, place examples on the declaring extension class page or the namespace page. The example must explicitly call the method.

Never mirror synthetic method UIDs that contain hashes, encoding, or generated suffixes in filenames. Keep filenames readable and let the YAML `uid` decide what DocFX model the content targets.

Keep `api/namespaces/**/*.md` and `api/types/**/*.md` under `build.overwrite` only. Exclude both `api/namespaces/**` and `api/types/**` from `build.content`. Do not widen either entry to `api/**/*.md`. Move legacy authored `.docfx/api/*.md` overwrite files into either `api/namespaces/` (for namespace pages) or `api/types/` (for type pages) instead of widening the glob.

For managed reference pages, map type and extension-method examples to the `example` property rather than to `summary` or implicit conceptual content. Read `references/docfx-overwrite-files.md` for the exact front-matter shape.

## Example Verification

Every added or changed `csharp` code block must pass two validation gates before it is written to a markdown file. Do not write any `csharp` fence without first verifying both gates pass.

**Gate 1 — Static structure (`SAMPLE_STRUCTURE_INVALID`):**

Before attempting compilation, the validator rejects code that:

- Contains top-level statements without a `// Program.cs` comment label at the top.
- Lacks a namespace declaration.
- Lacks a type declaration (class, struct, or record).

A code block labelled `// Program.cs` at the very top passes Gate 1 and is compiled as a file-based app.

**Gate 2 — Compilation (`SAMPLE_COMPILE_FAILED`):**

Class-based examples that pass Gate 1 are compiled as a class library project referencing all assemblies from `docfx.json`. If compilation fails, the example is rejected. Either repair and re-run, or omit the example and add:

```markdown
<!-- No compile-valid example could be generated for this type. -->
```

**Example generation source priority:**

Derive examples from these sources, in order:

1. Public API surface and XML documentation comments — establish the supported constructor signatures, method signatures, and types.
2. Existing unit or functional tests that reference the documented type or member — use as behavioral evidence only; do not copy Arrange/Act/Assert structure, test fixtures, mocks, or test helper patterns into the final example unless the public API is specifically about testing.
3. README, package documentation, samples, or existing conceptual docs in the repository.
4. Implementation source, only when the public surface alone is insufficient to construct a valid calling example.
5. Official upstream documentation when the library wraps an external framework or library.
6. Synthesized examples only when all of the above confirm the full public API shape and the synthesized sample compiles.
7. Omit the example entirely if none of the above yields a compile-valid, consumer-facing example.

Final examples must be consumer-facing, realistic, and compile. They must read like production calling code, not test scaffolding.

**Reflection and API-shape requirements:**

Resolve constructors, generic arity, abstractness, constraints, and public members before writing examples:

- Generic types: supply concrete type arguments (e.g., `Repository<Product>`, not `Repository<T>`).
- Abstract types: do not instantiate directly; derive with a concrete class that supplies all required generic parameters.
- Extension methods: show a valid receiver type.
- Do not assume parameterless constructors or methods not present in the reflected API surface.
- Do not invent members; if a member cannot be confirmed, omit the example.

**Skip marker (last resort only):**

```csharp
// dotnet-docfx-digest:skip-compile - <reason>
```

The reason is mandatory. Package requirements, "full example needs X", or "shows the framework pattern" are rejected. Prefer making the example compile. Do not claim an example compiles unless the validator actually ran it successfully.

## Namespace and Summary Style

Namespace overview pages must explain what problem the namespace solves, when to use it, and where a newcomer should start. Avoid inventory-only blurbs such as “contains types and extension methods for...”

Type and member summaries should explain the API’s job in consumer terms. Prefer purpose-first summaries for entry points, builders, factories, options, and extension methods. Avoid empty labels such as “represents options” or “adds services” unless the rest of the sentence explains the actual outcome enabled.

If one namespace page in a public API family needs repair, inspect sibling namespace pages in that family before finishing and keep them consistent. If you intentionally leave a sibling page unchanged, say why.

## XML Documentation Comments

Public API should have useful XML comments. Keep source summaries concise and move longer examples or remarks into DocFX overwrite content when that keeps the source readable.

XML comments should cover purpose, parameters, return value, exceptions, type parameters, important behavior, nullability expectations, and lifecycle or thread-safety details when relevant.

## Cleanup Boundary

Authored DocFX Markdown is documentation output, not disposable build output. Do not delete `.md` or `.mdoc` files, `docfx.json`, `toc.yml`, includes, images, examples, or directories that contain authored documentation while cleaning generated artifacts unless the user explicitly asks for that deletion.

Prefer `docfx.cs --verify-docfx-build` because it builds DocFX in a temp copy and cleans that workspace itself. If `git status` still shows leftover generated files afterward, classify each path before deleting it. Generated metadata cleanup is limited to DocFX-generated `*.yml`, `.manifest`, and `*.manifest` files under configured metadata destinations. Generated site cleanup is limited to the configured build output directory when that directory is clearly generated output and contains no authored Markdown, source, project, solution, or DocFX configuration files.

If a cleanup candidate is ambiguous, leave it in place and report the ambiguity instead of deleting it.

## Codebelt Signing Keys

Codebelt solutions are normally strong-name signed with a repository-root `.snk` file. Preserve and copy that file when it exists. If a Codebelt repository or temp copy does not contain the root `.snk`, use the skip-sign fallback for verification commands:

```bash
dotnet build -p:SkipSignAssembly=true
dotnet test -p:SkipSignAssembly=true
```

Use the same fallback for equivalent builds triggered by documentation validation so missing local signing keys do not masquerade as documentation failures.

## Workflow Summary

When the user names a changed API or namespace:

1. Run `agents.cs`.
2. Run the safety gates and inspect existing documentation edits.
3. Inspect the changed public API, affected namespaces, availability inputs, tests, samples, and current overwrite files.
4. Update XML comments, namespace pages, extension-member tables, examples, and availability notes as required.
5. Build an example inventory for required public concrete types and extension methods.
6. Preserve manual edits, inspect `git diff`, run `dotnet build`, run `dotnet test`, run the Completion Repair Loop, then run `docfx.cs --verify-docfx-build`.

When the user does not name a specific target:

1. Run `agents.cs`.
2. Run the safety gates and inspect repository guidance.
3. Inspect DocFX configuration, overwrite files, tests, samples, and current documentation state.
4. Run `docfx.cs --json`, and for multi-diagnostic output rerun with `--repair-plan` and use that plan as the work queue.
5. Repair missing namespace pages, extension-member tables, examples, overwrite layout, summaries, and availability notes that can be derived from evidence.
6. Preserve manual edits, inspect `git diff`, run `dotnet build`, run `dotnet test`, run the Completion Repair Loop, then run `docfx.cs --verify-docfx-build`.

Read `references/workflow.md` before creating new namespace pages, writing type or extension examples, preparing the final verification checklist, or shaping the completion response.

## Reference Files

- `references/workflow.md` — detailed targeted/audit workflows, example inventory shape, templates, verification checklist, and completion response.
- `references/docfx-overwrite-files.md` — overwrite-file model rules, `example: - *content` usage, and Codebelt overwrite layout guidance.
- `references/scripts.md` — exact `agents.cs` and `docfx.cs` commands, arguments, exit codes, diagnostics, and validator behavior.
