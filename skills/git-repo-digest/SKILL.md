---
name: git-repo-digest
description: >
  Generate source-grounded repository digest markdown from deterministic local evidence bundles. Use when the user asks to create, refresh, or complete repo/package digests, family or project overview pages, .bot/digests output, digest workspace workflows, or result/Index.md plus result/{PackageName}.md files for any repository URL. The skill runs its bundled .NET file-based evidence generator over a git clone, separates authoritative XML evidence from Markdown prompts and reading aids, writes package digests first, then writes the overview from completed package digests, and enforces complete-read grounding and no-invention rules even when file output is capped.
---

# Git Repo Digest

![Git Repo Digest](assets/hero.jpg)

Use this skill to turn a deterministic digest workspace into website-ready or docs-ready Markdown. The bundled `scripts/digest.cs` runner owns repository access, evidence gathering, package discovery, evidence packing, prompt generation, and generated instructions. The agent owns reading that evidence, writing the digest files, and validating that every claim is grounded.

## Critical

- Treat generated output as the source of truth. If `manifest.json`, `instructions.md`, `prompts/*.prompt.md`, or `evidence/**/*.xml` files disagree with this skill, follow the generated files unless they are internally inconsistent.
- Every authored `result/*.md` file must start with the YAML frontmatter contract from its generated prompt. Preserve generated static metadata such as package counts, library counts, target framework monikers, external links, family links, internal `.md` family URLs, and link glyphs unless raw evidence proves the hint wrong.
- For `result/Index.md`, preserve the generated `title` hint exactly unless raw evidence proves the product metadata is wrong. The runner resolves that title from a literal root `Directory.Build.props` `<Product>` value, then from a literal `<Product>` on the most-referenced top-level packable `.csproj`; it fails generation when no product can be resolved instead of falling back to `repo-id`.
- Preserve generated documentation links as validated static metadata. The runner resolves documentation hosts from `PackageProjectUrl` first, falls back to `README.md` / `.nuget/**/README.md` `## Documentation` links when package-specific URLs are not `200 OK`, derives normal package API paths from `.docfx/**/docfx.json`, links packages with no DocFX API entry to the same docs root as `result/Index.md`, and fails before prose is written when no documentation URL returns `200 OK`.
- Keep the workflow generic. The runner input is a full repository URL, not an implied owner/slug convention.
- Require both runner inputs `--repo-url` and `--output-root`. Do not invent defaults silently.
- Accept curated external usage repositories from the user's natural invocation when present, then pass each one to the runner with a repeated `--external-repo-url` flag.
- Map repository URLs and optional output paths positionally, regardless of whether the user typed a slash command, pasted bare URLs, or wrote a natural-language request. First URL is always the digest `repo-url`; a second value is `output-root` only when it is not a URL; every URL after the first is an `external-repo-url`.
- A bare list of two or more URLs is not ambiguous: treat it as one digest target plus external usage repositories. Do not reinterpret later URLs as separate digest targets unless the user explicitly says to digest multiple repositories independently, for example "digest both repos", "create separate digests", or "run one digest per URL".
- Do not second-guess URL mapping from repository names, package names, topical similarity, or whether an external repository seems likely to consume the digest repository. The runner is responsible for finding reference-plus-code matches or reporting that no external usage matches were found.
- A bare repository URL means generate a fresh workspace with the runner after `output-root` is known. Do not search for or reuse the latest existing `{output-root}/{repo-id}/{run-id}` merely because it exists.
- Reuse an existing digest workspace only when the user explicitly provides a workspace path or asks to reuse, continue, inspect, validate, or repair existing output.
- If a `.bot` folder exists and the user did not provide an output path, recommend `<workspace>/.bot/digests` as the output root so the workspace becomes `<workspace>/.bot/digests/{repo-id}/{run-id}`.
- If the user provides an output path, pass that value as `--output-root`; the runner still appends `{repo-id}/{run-id}`.
- Do not make `repo-id` customizable. It is derived from the final repository URL path segment.
- Do not make `run-id` customizable. It is always generated in UTC as `yyyyMMdd-HHmmssZ`.
- Do not make the result directory customizable. It is always `result`.
- Do not assume GitHub owner, repository host, organization, package prefix, website path, or docs domain from memory.
- Do not call an LLM provider from the runner. The calling agent is the brain that writes prose.
- Process one package evidence set at a time. Do not load all package evidence sets into the same prompt unless the generated manifest explicitly requires it.
- When the runtime supports subagents and the manifest has multiple independent package evidence sets, prefer one subagent per package. Give each subagent only its assigned package prompt, evidence files, `instructions.md`, the relevant manifest entry, and the complete-read contract. Subagents reduce context pressure; they do not reduce grounding requirements.
- Complete reads are mandatory for the files used in the current phase. For a package digest, read that package's prompt plus its required evidence files before writing. For the overview, read `prompts/overview.prompt.md` and every completed package result file required by the manifest before writing. The generated evidence indexes and chunks are a safer way to finish reading large evidence files; they are not permission to skip sections.
- Raw package evidence lives under `evidence/{PackageName}/` as `source.xml`, `tests.xml`, `projects.xml`, `readmes.xml`, and `external-usage.xml`. Markdown prompts are task instructions; indexes are navigation aids only.
- Evidence indexes summarize chunks in a `Contents` column. They list stable packed-path labels such as `Source Code`, `Test Coverage`, `NuGet Documentation`, or `Project Metadata` when XML `<file path="...">` entries are present.
- If a tool caps, truncates, summarizes, or partially displays a required full evidence file, read its `*.index.md` file and then read every chunk listed in numeric order. If the chunk reads are also capped or incomplete, continue by ranges or stop and report the blocker instead of writing from a subset.
- Do not use an evidence index as evidence for digest claims. It is a navigation aid; the full evidence file or all ordered chunks are the source evidence.
- Package evidence includes generated `api-summary.md` and `engineering-signals.md` reading aids. Use them to focus attention on likely public types, abstractions, extension points, lifecycle contracts, validation guards, factories, callbacks, and package-boundary clues, but verify every claim against raw source, tests, and project evidence.
- Write package result files before the overview result file.
- For the overview, explicitly read every completed package result file listed by the manifest. Reading only project/readme evidence is an incomplete overview workflow because the package digests are the primary editorial source.
- Do not invent APIs, package relationships, examples, dependencies, support statements, performance claims, or architectural claims not supported by the package evidence.
- Treat external usage evidence as curated consumer-usage inspiration, not API authority. It can shape `## Basic usage` when current source evidence validates the APIs.
- Do not turn a source-backed structural risk into an unmeasured behavior claim. Phrases such as "most common mistake", "developers often", "users frequently", "popular choice", "widely used", or "typical failure" require explicit evidence such as package analytics, issue history, docs that say so, telemetry, survey data, or examples in the generated evidence. Without that evidence, describe the risk conditionally: "If you install X in a project that only needs Y, it adds Z."
- If required deterministic files are missing, stale, contradictory, or too large to use safely, stop and report the blocking issue instead of guessing.
- Do not copy results into a website or documentation tree unless the user explicitly asks for publication or sync.

## Runner Contract

The skill bundles a .NET 10 file-based app:

```text
scripts/digest.cs
```

Run it with `dotnet run --file` so it is not confused with a nearby project file:

```powershell
dotnet run --file <skill-root>/scripts/digest.cs -- --repo-url <repo-url> --output-root <output-root>
```

Required inputs:

```text
--repo-url      Fully qualified git repository URL
--output-root   Directory where the digest workspace will be written
```

Optional repeated input:

```text
--external-repo-url  Public repository URL to clone and search locally for curated consumer usage
```

Fixed conventions:

```text
repo-id      Derived from the final repository URL path segment, with .git removed
run-id       Derived from current UTC time
result dir   result
```

The runner requires the .NET 10 SDK or newer and `git`. It performs one shallow git clone for the repository under digest, optionally performs one shallow clone per provided external usage repository, discovers packages from the digest clone, and packs evidence with its bundled C# packer. The packer uses `git ls-files` for deterministic tracked-file membership, applies the runner's evidence classifiers, skips generated or low-signal paths, keeps text files only, and writes stable XML evidence files under `evidence/{PackageName}/`.

The runner also supports deterministic result validation for authored workspaces:

```powershell
dotnet run --file <skill-root>/scripts/digest.cs -- --validate-results --workspace <workspace>
```

Use this as a deterministic gate after authoring result files. It reports unsupported package-owned API member access in C# examples, low-signal Basic usage patterns, non-Codebelt-style xUnit snippets, and Basic usage snippets that do not compile and pass as temporary Codebelt.Extensions.Xunit tests. For executable validation, the runner creates a temp test project, installs the page's NuGet package plus xUnit test packages and `Codebelt.Extensions.Xunit`, and runs `dotnet test`. The agent must revise from source evidence and rerun until validation passes.

Any result-file edit after a validation pass invalidates that pass. Rerun `--validate-results` after the final write to `result/*.md`, including after small copy edits, regenerated Basic usage snippets, or manual repairs.

Packing notes:

- The evidence packer is local-only. It does not call Node/npm, Repomix, browser automation, or a public packing service.
- The evidence packer does not emit third-party token counts, compression summaries, public GitHub search results, or external Secretlint results. Treat source, tests, project files, README files, and curated external usage files as the grounding surface. Treat generated public API summaries and engineering signals as reading aids only.
- External usage evidence is gathered only from user-provided repository URLs. The runner does not search GitHub.
- If any provided external usage repository cannot be cloned or inspected, the runner fails fast before digest prose is written.
- The runner rejects external usage URLs that normalize to the same repository as `--repo-url`.
- External usage selection uses a reference-plus-code rule: an external project must reference the current package, or a discovered package that transitively references the current package, either in its `.csproj` or nearest ancestor `Directory.Build.props` / `Directory.Build.targets`; selected C# files can come from source or test projects, but must contain a strong current-package marker such as the package id or namespace before public-symbol matches affect ranking.
- The runner does not try to evaluate MSBuild conditions on external package references. It uses references as a broad candidate signal and relies on strong code matches to decide what external source or test files are worth packing.
- The runner filters known low-signal files such as `GlobalSuppressions.cs` from packed evidence. Do not recreate or infer digest claims from those files.
- The runner follows Codebelt repository conventions for discovery: source projects live under `src/`, owned tests live under `test/`, and owned test projects are named after the package plus `.Tests` for libraries or `.FunctionalTests` for apps. It does not scan generic `tests/` roots or broader suffix variants such as `.UnitTests` or `.IntegrationTests`. Within the fixed `test/` root, it prefers a dedicated owned test project, then a single unambiguous direct project reference. If only downstream package tests match a shared base package prefix, the runner leaves `Test path` undiscovered instead of assigning another package's tests.
- Source files are source evidence even when their type or file names end in `Test`, such as framework abstractions named `WebHostTest`. Test evidence is limited to files under the discovered owned `test/` path.
- If `.NET 10` or `git` is unavailable, stop and report the missing dependency.

## Expected Workspace

The digest root is chosen by the caller. For repositories that already use `.bot` and where the user did not supply an output path, the conventional staging root is:

```text
.bot/digests
```

When that conventional root is used by default, the generated workspace is:

```text
.bot/digests/{repo-id}/{yyyyMMdd-HHmmssZ}
```

If the user supplies an output path, use that value as the root while keeping the same generated child shape:

```text
{output-root}/{repo-id}/{yyyyMMdd-HHmmssZ}
```

Generated shape:

```text
{output-root}/{repo-id}/
  manifest.json
  instructions.md
  prompts/
    {PackageName}.prompt.md
    overview.prompt.md
  evidence/
    {PackageName}/
      source.xml
      tests.xml
      projects.xml
      readmes.xml
      external-usage.xml
      api-summary.md
      engineering-signals.md
      source.index.md
      source.chunks/
        0001.xml
  result/
    Index.md
    {PackageName}.md
```

The manifest is authoritative after generation. Always follow the manifest for concrete package names, prompt paths, evidence paths, evidence index paths, evidence chunk paths, result paths, and phase order.
Manifest targets also include `frontmatterHints`, which are generated metadata values for the YAML frontmatter required in each result file. For the overview target, `frontmatterHints.title` is repository-owned product metadata, not a URL-derived repository id. Documentation entries in `frontmatterHints.links` are validated URLs only; the runner does not emit repository `#readme` documentation fallbacks.

## Workflow

### Step 1: Resolve Inputs

Collect or infer these runner inputs:

- `repo-url`: required. Ask for it if the user gives only a slug or a repository nickname.
- `output-root`: required. If the active workspace has a `.bot` directory and the user did not provide an output path, recommend `<workspace>/.bot/digests`; otherwise ask for the path.
- `external-repo-url`: optional and repeatable. Use only public repository URLs the user supplied as curated usage sources.

Apply this positional mapping to slash commands, pasted bare values, and natural-language invocations alike:

```text
<digest-repo-url> <optional-output-folder> <optional-external-url> <optional-external-url>
```

Map them as follows:

- First URL: `repo-url`.
- Second value: `output-root` only when it is not a URL.
- Every URL after the first, including the second value when it is a URL: repeated `external-repo-url` values.
- If the second value is a URL and no output root was supplied, keep it as `external-repo-url` and ask for `output-root` or recommend `.bot/digests` when the active workspace has `.bot`.
- Do not ask whether later URLs should be independent digest targets. That question is already answered by the positional mapping unless the user explicitly asks for multiple independent digests.
- Do not reject or question an `external-repo-url` because the repository name or domain seems unrelated. Pass the user-supplied URL to the runner and let deterministic external usage selection decide whether it contributes evidence.

Examples:

- `https://github.com/example/library https://github.com/example/consumer` maps to `--repo-url https://github.com/example/library --external-repo-url https://github.com/example/consumer`; output root still needs to be supplied or recommended.
- `/git-repo-digest https://github.com/example/library .bot/digests https://github.com/example/consumer` maps to `--repo-url https://github.com/example/library --output-root .bot/digests --external-repo-url https://github.com/example/consumer`.
- `generate a digest for https://github.com/example/library using https://github.com/example/consumer as evidence` uses the same mapping: first URL is the digest repo, second URL is external usage evidence.
- `digest both https://github.com/example/library and https://github.com/example/other-library separately` is different because the user explicitly requested independent digests; handle that as separate digest runs.

Do not ask for `repo-id`, `run-id`, or result directory.

### Step 2: Generate or Locate the Digest Workspace

Choose the workspace mode from the user's input, not from folders you happen to discover:

- Generate fresh when the user provides a repository URL and does not explicitly ask to reuse existing output.
- Generate fresh even when `{output-root}/{repo-id}` already contains prior run folders; the runner appends a new UTC `{run-id}`.
- Locate existing only when the user explicitly provides a digest workspace path such as `{output-root}/{repo-id}` or `{output-root}/{repo-id}/{run-id}`, or asks to reuse, continue, inspect, validate, or repair existing output.
- If the user provides `{output-root}/{repo-id}` as an existing-workspace path and does not name a run-id, inspect the folder and ask before choosing among prior run folders unless the user asked for the latest run.

For a fresh run, execute the bundled runner from this skill:

```powershell
dotnet run --file <skill-root>/scripts/digest.cs -- --repo-url <repo-url> --output-root <output-root> [--external-repo-url <external-url>]...
```

The runner writes deterministic evidence files, prompt files, and the `result` folder. It does not call an LLM and does not overwrite existing `result/*.md` files.

### Step 3: Read the Run Contract

Read only these root files first:

```text
manifest.json
instructions.md
```

From `manifest.json`, identify:

- repository URL
- repository identifier
- output directory
- package phase entries
- overview phase entry
- each package prompt path
- each evidence file path
- each evidence index path
- each ordered evidence chunk path
- each external usage evidence path, index path, and ordered chunk path
- each result file path
- each target's `frontmatterHints` values
- dependency order

If there is no manifest, infer the package list only from `prompts/*.prompt.md` and `evidence/*/` folders and stop to tell the user the manifest is missing. Continue only if the user explicitly accepts the degraded workflow.

### Step 4: Write Package Digests

For each package in the first phase:

1. Open only that package's prompt, evidence artifacts, and `instructions.md` if needed.
2. Try to read each required evidence file completely. If a read output is capped or truncated, open the manifest-declared evidence index and then read every manifest-declared chunk in numeric order until the whole evidence file has been inspected.
3. Confirm the package result path is `result/{PackageName}.md` or the manifest's declared equivalent.
4. Start the result with the generated YAML frontmatter schema, replacing editorial placeholders for `title`, `description`, and `lede` with grounded package-specific prose.
5. Write the exact required sections from the generated package prompt.
6. Ground Key APIs prose and examples in source, tests, project files, README files, external usage files, or metadata found in the evidence.
7. For `## Basic usage`, prefer representative external usage when it exists, validates against current source evidence, and gives a clearer consumer scenario than owned tests.
8. Use generated summaries and engineering signals to revisit likely design invariants, lifecycle contracts, callback wiring, factory boundaries, generic type constraints, exception guards, and package-boundary decisions in the raw source.
9. Do not document non-public members as APIs, but do inspect internal implementation when it explains public lifecycle behavior, validation, callback flow, or package boundaries.
10. Keep examples compact and use real namespaces, type names, method names, and constructor signatures from the evidence.
11. If the evidence proves the package is a convenience, aggregate, or metadata-only package with no source of its own, write that honestly instead of inventing APIs.

Do not use another package's evidence to fill gaps unless the current prompt explicitly includes it or the manifest marks that relationship as required.

When editing an existing package result:

- Read the affected file immediately before editing. Do not rely on memory, stale subagent output, or a previously displayed excerpt.
- When replacing a named section such as `## Basic usage`, select from the section heading through the complete section body. Do not start the replacement inside the section or inside a fenced code block.
- If replacing a code example, include the opening fence, the entire code block, the closing fence, and any section-specific explanatory prose in the replacement boundary.
- After every result-file edit, re-read the affected section and verify the heading appears exactly once, every fenced code block has a matching closing fence, and no old fragment survived above or below the replacement.
- Rerun `--validate-results` after the final result-file edit. A previous validation pass is stale after any result-file change.

### Optional Subagent Strategy

If the agent runtime can delegate work, use subagents to keep each package evidence set isolated and roomy:

- Spawn at most one subagent per package from the current package phase.
- Give each subagent a narrow task: completely read its assigned prompt and evidence set, using evidence indexes and ordered chunks if a full evidence file is capped, follow `instructions.md`, write or draft only its assigned `result/{PackageName}.md`, and report any unreadable or contradictory evidence.
- Do not give one subagent multiple package evidence sets unless the manifest says those packages are dependent.
- Do not ask a subagent to write `result/Index.md` until all required package result files exist.
- The main agent is the orchestrator and final editor. It gathers each subagent's completed package result file, reported caveats, and validation notes, then authors `result/Index.md` itself from those completed digests plus `prompts/overview.prompt.md` and supplementary project/readme evidence as needed.
- The coordinating agent remains responsible for manifest order, final file placement, overview synthesis, validation, and final reporting.

Subagent summaries and caveats are useful handoff material for the orchestrator, but they are not a replacement for the completed package result files required by the overview phase.

### Step 5: Write the Overview

Write `result/Index.md` only after package digests exist.

Open and completely read `prompts/overview.prompt.md` and every completed package result file listed by the manifest or by the generated required package-digest source section. Treat the completed package result files as the required package-digest source for `result/Index.md`; treat project/readme evidence as supplementary repository evidence for relationships, project metadata, README framing, and package inventory. Reading only project/readme evidence is not sufficient when package result files exist.

If package digests were produced by subagents, collect their reported caveats and validation notes before drafting the overview. Use those notes to avoid overclaiming, but ground the overview in the completed package result files, `prompts/overview.prompt.md`, and supplementary project/readme evidence as needed.

The overview should help readers understand the repository's concepts before they open package-specific pages. It should not behave like a package inventory, repeat package-page summaries, or amplify unsupported claims.

Write `result/Index.md` as a conceptual overview:

- Start with the generated YAML frontmatter schema, preserving the generated `title` because it comes from repository-owned `<Product>` metadata, and replacing editorial placeholders for `description` and `lede` with grounded repository-level prose.
- Keep NuGet URLs inside `links`, with the index NuGet link queryable and package-page NuGet links package-exact. Keep generated repository, releases, issues, documentation, NuGet, and `familyLinks` entries when they are present in `frontmatterHints`.
- Treat generated documentation links as already validated by the runner. Do not replace them with repository README anchors or invented docs paths.
- Use the generated overview prompt's exact required headings, currently `## Overview`, `## Concepts`, and `## Usage guidance`.
- Start `## Concepts` with a short introductory paragraph before the first concept heading.
- Use concept subsection headings for ideas, patterns, boundaries, responsibilities, or trade-offs, not package names.
- Derive concept candidates from every completed package digest's `## Overview`, `## Key APIs`, `## Basic usage`, and `## Usage guidance` sections, then connect package responsibilities and APIs across layers where the evidence supports it.
- Build concepts from coverage first, then merge only true duplicates. A concept should survive when ignoring it would hide a substantial package-owned capability, extension model, boundary, or trade-off.
- Preserve distinct capability domains represented by package-owned APIs even when they share the same lower-level pattern, dependency, or factory model.
- Before writing, do a coverage pass against completed package names and Key APIs; any package-owned domain that disappears needs either its own concept or an explicit merge into a named related concept.
- Include as many concept subsections as the completed package digests genuinely support; do not force a fixed concept count.
- Link to package pages only as inline relative Markdown links such as `[Package.Name](Package.Name.md)`.
- For single-package repositories, skip package-selection framing entirely and still explain the real concepts the package introduces.
- For multi-package repositories, explain package coverage inside concept prose instead of creating package tables or one subsection per package.
- Do not repeat Basic usage examples, API inventories, installation commands, or package-specific overview paragraphs from package pages.

For usage guidance, separate evidence from inference:

- It is grounded to say a meta-package brings in referenced packages or framework references when the project files show that relationship.
- It is grounded to recommend the smaller package first when the generated instructions ask for "use less" guidance and the package boundaries support that recommendation.
- It is not grounded to call that situation "the most common mistake" or describe actual developer behavior unless the evidence includes frequency evidence.
- Prefer neutral phrasing such as "Avoid installing the aggregate package when..." or "Choose the aggregate package only when..." over popularity or frequency claims.

If any package digest is missing, decide from the manifest:

- If the overview depends on all package digests, stop and report the missing files.
- If partial overview generation is explicitly allowed, name the missing package digests in the final response.

### Step 6: Validate Grounding and Shape

Run the deterministic result validator and require a pass before reporting completion:

```powershell
dotnet run --file <skill-root>/scripts/digest.cs -- --validate-results --workspace <workspace>
```

This validator catches C# Basic usage member accesses on package-owned receiver types that do not exist in source evidence, non-Codebelt-style xUnit snippets, malformed Basic usage sections, low-signal Basic usage examples, and snippets that fail an executable Codebelt.Extensions.Xunit harness. It intentionally does not guess replacement APIs. If it reports an error, revise the example from source evidence and rerun validation until it passes.

Treat validation as a final-state check, not a milestone from earlier in the session. If any `result/*.md` file changes after `--validate-results` passes, rerun validation before reporting completion.

Use a tight repair loop when validation fails:

- Treat targeted `rg` searches as triage only. A search hit is not automatically a defect; decide from context and source evidence, for example `HttpStatusCode.OK` is not the same as a toy literal response body.
- Create a short repair ledger for each validation diagnostic: result file, exact diagnostic, affected Basic usage block, source evidence needed, and planned edit.
- Inspect the failing snippet and the exact failing line before speculating about framework internals, overload resolution, dependency injection, logger categories, or validator behavior.
- Allow at most one quick hypothesis pass. If the cause is not confirmed from source, tests, or the executable failure line, replace the example from source-backed evidence instead of continuing an open-ended investigation.
- Prefer one focused edit per diagnostic, then rerun `--validate-results`. Do not treat unrelated preflight search hits as reasons to rewrite passing examples.

Before finishing, verify:

- Every manifest package has a corresponding result file.
- `result/Index.md` exists when the manifest includes an overview entry.
- Result filenames match manifest paths.
- Evidence index and chunk paths in the manifest exist for every generated evidence file.
- Required headings from the generated package prompt are present verbatim.
- Required headings from the generated overview prompt are present verbatim.
- Every result file begins with YAML frontmatter before the first Markdown heading.
- Frontmatter includes `title`, `description`, `lede`, `pageKind`, `packageCount`, `libraryCount`, `targetFrameworks`, `targetFrameworkMonikers`, `license`, `links`, and `familyLinks`; package pages also include `packageId`.
- The `links` array contains NuGet entries: package pages point to exact package URLs, while `result/Index.md` uses the generated queryable NuGet URL.
- The `familyLinks` array appears on both `result/Index.md` and package pages, links to every package page with relative `PackageName.md` URLs, and keeps package-context glyphs unless evidence supports a better glyph.
- Prefer generated family glyphs derived from `.nuget/{PackageName}/README.md` Related Packages sections when available; otherwise keep the generated package-name heuristic glyph.
- Link entries preserve context-specific glyphs for NuGet, repository, releases, issues, and documentation links when those links are available.
- No frontmatter value still contains placeholder wording such as "Write a source-grounded" or "Write a short lede".
- `result/Index.md` has an introductory paragraph after `## Concepts` and before the first concept subsection.
- `result/Index.md` uses concept headings instead of package-named subsections.
- `result/Index.md` concepts synthesize completed package `## Overview`, `## Key APIs`, `## Basic usage`, and `## Usage guidance` sections instead of ignoring package-level APIs or scenarios.
- Every completed package digest contributes to at least one concept subsection or is intentionally merged with a named related concept because it makes the same point.
- Distinct package-owned capability domains are not collapsed into a generic umbrella concept when separate subsections would better reveal important work.
- `result/Index.md` connects related packages in concept prose where package responsibilities, dependencies, or APIs show a relationship.
- `result/Index.md` does not contain a package-selection table unless a future generated prompt explicitly asks for one.
- Package links in `result/Index.md` are inline relative Markdown links such as `[Package.Name](Package.Name.md)`.
- No result file contains analysis notes, citations, XML, JSON, confidence scores, or chat commentary unless the generated prompt explicitly asks for them.
- Code examples mention only APIs visible in the relevant evidence.
- Basic usage examples pass API-shape validation: every namespace, type, constructor, method, extension method, override, generic constraint, and property access used in the snippet exists on the declaring type in source evidence or on the framework type shown by the snippet's static type.
- Basic usage examples pass Codebelt xUnit validation: every C# test snippet includes `using Codebelt.Extensions.Xunit;` and `using Xunit;`, uses a file-scoped consumer namespace such as `namespace MyProject.Tests;`, omits `using Xunit.Abstractions;`, declares a public test class inheriting from `Test` or a source-backed Codebelt test base class that the evidence shows derives from `Test`, defines a constructor that accepts `ITestOutputHelper output` and passes that output helper to the base constructor, and uses `TestOutput.Write`, `TestOutput.WriteLine`, or `TestOutput.WriteLines` for concise human-friendly scenario output.
- Basic usage examples pass executable validation: the validator writes each Basic usage C# block to a temporary Codebelt.Extensions.Xunit project, installs the page's NuGet package plus xUnit test packages and `Codebelt.Extensions.Xunit`, runs `dotnet test`, and treats any compile or test failure as blocking.
- Basic usage sections are structurally valid: package pages have one top-level `## Basic usage` section, headings inside fenced code blocks do not count as Markdown section boundaries, and every Basic usage section contains at least one complete fenced C# code block.
- If executable validation fails, rewrite the example from source, tests, and source-valid external usage, then rerun `--validate-results` until the workspace passes.
- Basic usage examples inspired by external usage validate every API call, constructor, namespace, and extension method against current source evidence.
- Basic usage examples for convenience, aggregate, metadata-only, or no-assembly packages validate referenced-package API shape against the referenced package's source evidence, not the aggregate package's empty or metadata-only evidence.
- Property accesses in C# examples are API-shape claims. For any real package-owned type, fixture, base class, builder, options object, context, factory result, or service object, verify that the accessed member is declared by the relevant source evidence or by a known framework type used with the correct static type.
- External usage evidence may shape the consumer scenario, but stale external code does not override current source or test evidence.
- For normal code packages, `## Basic usage` contains exactly one C# fenced code block unless the generated prompt explicitly allows more.
- For normal code packages, the Basic usage C# example is a complete Codebelt-style test snippet with explicit `using` statements, a file-scoped consumer namespace, a public test class inheriting from `Test` or a source-backed Codebelt test base class that the evidence shows derives from `Test`, a constructor with `ITestOutputHelper output` passed to the base constructor, useful `TestOutput.Write`, `TestOutput.WriteLine`, or `TestOutput.WriteLines` output, and exactly one `[Fact]` or `[Theory]` method unless the generated prompt explicitly allows more.
- For normal code packages, the Basic usage example demonstrates a realistic consumer task where the package API changes how the code is written, not just a smoke test that calls one method with a literal value.
- For normal code packages, the Basic usage example shows a system under test interacting through the package API when the package supports DI, pipelines, handlers, factories, lifecycle hooks, loggers, collectors, stores, recorders, fixtures, providers, or test hosts.
- For normal code packages, the two-sentence Basic usage explanation describes only what the example actually demonstrates.
- For convenience, aggregate, metadata-only, or no-assembly packages that reference code packages, `## Basic usage` contains one C# fenced code block per referenced code package.
- For convenience packages, each Basic usage example is introduced by a third-level heading naming the referenced package, for example `### Codebelt.Extensions.Xunit`.
- For convenience packages, each referenced-package example follows the same Codebelt-style xUnit shape and contains exactly one `[Fact]` or `[Theory]` method.
- For convenience packages, the Basic usage section includes a final paragraph explaining that the convenience package provides the single package reference and that the APIs come from the referenced packages.
- Convenience-package examples must not reuse individual package Basic usage examples verbatim.
- Convenience-package examples must not describe referenced APIs as if they are implemented by the convenience package itself.
- Convenience-package examples should be shorter and use-case-oriented. They should complement, not duplicate, the normal package pages.
- Every C# Basic usage example includes necessary `using` statements, prefers explicit imports, uses a file-scoped consumer namespace, and includes at least one assertion or observable result plus human-friendly `TestOutput` context.
- Every C# Basic usage example is small but complete enough to understand without hidden files, hidden helpers, hidden services, or unexplained setup.
- Basic usage examples do not contain placeholder comments, ellipses, TODOs, or magic helper calls.
- Basic usage examples do not introduce fake services, middleware, controllers, repositories, options, validators, domain types, or helper methods unless those types are defined inside the snippet or exist in the package evidence.
- Basic usage examples avoid toy/greeting-oriented names and literal-only assertions such as `Greeting`, `MessageService`, `Hello World`, `OK`, `Foo`, `Bar`, `Sample`, or `Dummy` unless the evidence proves those terms are real and central.
- Basic usage examples for collector, logger, store, sink, recorder, fixture, factory, host, or provider APIs use indirect observation when feasible: a producer, handler, pipeline, service, lifecycle hook, or hosted component creates the observable artifact, and the test asserts it afterward.
- Basic usage examples do not directly write to a package-owned helper and then read the same helper back when source, tests, or external usage support a richer producer/consumer scenario.
- Basic usage examples do not override lifecycle or cleanup hooks unless they clean up a real resource used by the example.
- Basic usage examples do not override lifecycle or cleanup hooks only to call the base implementation.
- Basic usage examples do not open external files, network resources, databases, environment variables, or machine-specific resources.
- Before finalizing `## Basic usage`, make an internal receiver/member pass over every C# code block. If `foo.Bar` appears, identify what `foo` is, what static type it has, and where `Bar` is declared. If the declaration cannot be found in source evidence or a known framework type, revise the example.
- For ASP.NET Core examples, prefer inline middleware such as `app.Run(...)` or `app.Use(...)` over `UseMiddleware<T>` unless `T` exists in the package evidence or is defined in the snippet.
- For hosting examples, avoid plumbing-heavy examples where manual fixture/service-provider wiring is more prominent than the package API unless the evidence proves that wiring is the intended basic usage.
- Public API and engineering-depth claims are verified against source or tests, not copied from generated summaries alone.
- API shape claims are verified against source code, not README text.
- Inheritance claims are verified against source declarations.
- Required override claims are verified against abstract/virtual source declarations.
- Constructor signatures and generic constraints are verified against source declarations.
- Factory method names, overloads, callback parameters, and return types are verified against source declarations.
- For referenced-package examples, member access patterns on variables such as fixtures, contexts, builders, factories, clients, services, and options are checked against the referenced package's source before finalizing.
- Target framework claims are verified against project files, not README text.
- Package dependency and transitive-reference claims are verified against project files, not README text.
- README, package README, catalog metadata, generated public API summaries, and engineering signals are not treated as authoritative evidence when source or project files are available.
- README/readme evidence is not authoritative for API shape.
- If README and source disagree, source wins.
- If external usage and source disagree, source wins.
- If README examples and tests disagree, tests win.
- If README and source disagree, the result follows source. If the disagreement materially affects the page, mention the validation risk in the final response rather than writing the stale README claim.
- Package digests do not make broad claims such as robust, seamless, powerful, or comprehensive unless immediately grounded in concrete evidence.
- Results do not contain unmeasured frequency, popularity, adoption, or mistake-rate claims. Search for wording such as most common, often, frequently, usually, typical, popular, and widely, then keep it only when the evidence provides support for that exact kind of claim.

Use targeted searches instead of rereading everything:

```powershell
rg -n "TODO|TBD|confidence|citation|analysis notes|I cannot|as an AI|\\.\\.\\.|placeholder" <workspace>/result
rg -n "Write a source-grounded|Write a short lede" <workspace>/result
rg -n "Greeting|MessageService|Hello World|Hello, World|Hello from DI|\\bOK\\b|GenerateReport|CreateService|BuildHost|FormatInvoice|CreateClient|SampleMiddleware|MyService|IMyService|MyRepository|FakeRepository|MyController|SampleController|\\bFoo\\b|\\bBar\\b|\\bDummy\\b" <workspace>/result
rg -n "base\\.OnDispose|dispose managed resources here|test-data\\.bin|File\\.Open|Environment\\.GetEnvironmentVariable|localhost|127\\.0\\.0\\.1" <workspace>/result
rg -n "UseMiddleware<|file class|file record|file struct" <workspace>/result
```

Explain any remaining risk, especially missing tests, ambiguous APIs, oversized context, or packages whose purpose is unclear from source.

## Complete-Read Rules

- Open package evidence sets one at a time.
- Use subagents for independent package evidence sets when available so each set can be read completely without competing for the same prompt budget.
- Prefer manifest summaries, package result files, and overview prompt for the overview instead of reopening every package evidence set.
- For the overview, package result files are compact source material. Read those files directly before writing `Index.md` instead of relying on their path list inside `prompts/overview.prompt.md`.
- Do not treat tool or token limits as permission to sample. The required file set for the current phase must be read completely.
- If a single evidence file is too large for one tool response, prefer the manifest-declared `*.index.md` file plus every ordered file under `*.chunks/`. If chunks are unavailable in an older workspace, split the full evidence read into ranges or sections and continue until the entire file has been inspected. Track where you left off so no section is skipped.
- Treat `*.index.md` as a table of contents, not as source evidence. It can tell you which chunks and packed files exist, but digest claims must come from the full evidence file or the complete ordered chunk set.
- Treat generated public API summaries and engineering signals the same way: they identify where to look, but they do not replace source, tests, project files, external usage files, README files, or metadata as grounding.
- Treat external usage as scenario evidence only. It does not replace complete reads of source evidence or validation against current source declarations.
- Use targeted searches only after the complete read, as a validation aid or to revisit specific evidence. Searches do not replace reading the required evidence.
- If the active model or available tools cannot read the full required file set for the current phase, stop and report the limitation. Do not write a digest from partial evidence.

## Publication

The digest workspace is staging output. A consuming website or docs system may map staged files into its own content tree. For the current Codebelt website, the conventional mapping is:

```text
src/Codebelt.Website.WebApp/Content/Markdown/{repo-id}/Index.md
src/Codebelt.Website.WebApp/Content/Markdown/{repo-id}/{PackageName}.md
```

Do not copy staged results there unless the user asks for website sync, publication, or integration.

## Good Output Characteristics

- Package pages are concrete, source-backed, and useful to experienced developers.
- Package pages and the index start with YAML frontmatter that carries source-backed page metadata, target framework monikers, important links with context glyphs, package-family links with internal `.md` URLs and package-context glyphs, and grounded `title`, `description`, and `lede` text.
- Independent package evidence sets may be handled by separate subagents, with each subagent fully reading one assigned set before drafting.
- Package pages are written only after the full package evidence set has been read, either directly or through the complete ordered chunk set, including any portions hidden by capped or truncated tool output.
- Evidence indexes are used to plan reading and verify chunk coverage, not as a replacement for source evidence.
- Public API summaries and engineering signals help the agent notice fine-grained library design, but every final claim is still backed by raw evidence.
- Non-public implementation details are used only to explain public behavior, not listed as consumer APIs.
- The overview includes a `## Concepts` section that explains repository concepts, boundaries, and relationships without becoming a package inventory.
- The `## Concepts` section opens with a short paragraph before concept subsections.
- The overview synthesis clearly uses the completed package result files as source material, not just project/readme evidence.
- The overview concepts incorporate package-page `## Key APIs`, Basic usage scenarios, and Usage guidance at a conceptual level and connect related packages where the evidence supports a relationship.
- The overview is granular enough that substantial package-owned domains do not disappear into generic architecture language.
- Package links in the overview appear as inline relative Markdown links inside concept prose.
- Single-package overviews skip package-selection framing and avoid redundant package summaries.
- Multi-package overviews group ideas by concept rather than creating one subsection per package.
- The overview avoids repeating package-page API lists, Basic usage examples, installation commands, and package-specific overview paragraphs.
- Tradeoff guidance distinguishes structural evidence from behavioral frequency; it avoids "most common" style claims unless the evidence includes measurement or explicit source support.
- The writing is restrained and developer-facing, not marketing-heavy.
- The agent follows the generated manifest instead of improvising the run order.
- The final response names the result files written and any validation gaps.
- Normal package Basic usage sections contain one focused C# example.
- Normal package Basic usage examples prefer representative external usage when available, source-valid, and clearer than owned test code.
- Convenience package Basic usage sections contain one focused C# example per referenced code package.
- Convenience package examples are introduced by referenced-package subheadings and make API ownership clear.
- Convenience package examples complement the individual package pages instead of repeating their Basic usage examples verbatim.
- Basic usage examples are small but complete: imports, file-scoped namespace, Codebelt.Extensions.Xunit `Test` inheritance directly or through a source-backed derived Codebelt test base class, output helper wiring, one focused `[Fact]` or `[Theory]`, useful `TestOutput` context, and an observable assertion/result.
- Basic usage examples are copy/paste ready enough to pass the generated temporary Codebelt.Extensions.Xunit project during post-validation.
- Basic usage examples avoid top-level statements; assertions live inside the single test method.
- Basic usage examples model real engineering roles instead of greeting/message/sample scenarios; package-owned stores, loggers, collectors, fixtures, factories, and hosts are demonstrated through a producer/consumer, pipeline, service, or lifecycle interaction when the evidence supports one.
- Foundational package examples may combine central validation, configuration, decorator, option, or lifecycle patterns when that better reveals the package's actual consumer value.
- API shape, inheritance, generic constraints, required overrides, factory overloads, and lifecycle claims are verified against source declarations.
- Package-page `## Key APIs` entries read as short prose paragraphs that start with the API name in code formatting instead of definition-list entries such as `` `Type` - description``.
- External usage influences examples without overriding current source declarations.
- README content is used for tone and positioning only, unless source code is unavailable.
- When README examples are stale, the generated page follows the current source and tests instead.

## Bad Output Characteristics

- Running a separate .NET project instead of the bundled `scripts/digest.cs` runner.
- Passing only a repository slug when the runner requires a full URL.
- Passing user-provided external usage repositories as implicit runner positional arguments instead of repeated `--external-repo-url` flags.
- Assuming a fixed organization such as `codebeltnet` or a fixed repository host such as GitHub.
- Searching GitHub for external usage when the runner only supports user-provided external repository URLs.
- Loading every package evidence set for every package digest.
- Sending multiple unrelated package evidence sets to the same subagent when they can be processed independently.
- Treating a subagent's summary as a substitute for a completed package result file during overview synthesis.
- Treating capped, truncated, summarized, or partial evidence output as enough to write from.
- Treating `*.index.md` as a summary that can replace reading the full evidence file or every chunk.
- Treating generated public API summaries or engineering signals as final evidence instead of prompts for source-backed inspection.
- Reading only the first few chunks because the index looked sufficient.
- Using tool limits, token limits, or "strategic reading" as a reason to skip part of a required package evidence set or overview source file.
- Claiming a mistake is common, most common, frequent, typical, popular, or widely observed based only on package structure or an inferred best practice.
- Writing `Index.md` before package digests exist.
- Writing `Index.md` after reading only project/readme evidence and not the completed package result files.
- Writing `Index.md` as a package-selection table or package inventory when the generated prompt asks for concepts.
- Writing package-page `## Key APIs` entries as definition-list bullets such as `` `Type` - description`` or using colons and dashes as hard separators when natural prose is possible.
- Starting `## Concepts` immediately with a third-level heading and no introductory paragraph.
- Writing concepts that ignore completed package `## Key APIs` details.
- Collapsing distinct package-owned domains into one polished but lossy umbrella concept.
- Describing related packages in isolation when their responsibilities or APIs clearly connect.
- Creating one overview subsection per package instead of concept-led subsections.
- Repeating package-page API lists, Basic usage examples, installation commands, or overview paragraphs in `Index.md`.
- Using package names as concept headings.
- Inventing usage examples from plausible framework patterns rather than supplied source and tests.
- Writing top-level-statement Basic usage snippets for normal packages when the prompt requires a complete test-style example.
- Choosing a thin literal round-trip smoke test when source or tests support a more representative consumer scenario.
- Writing greeting/message/sample examples or asserting `Hello World` / `OK` literals when source or usage evidence supports a more meaningful engineering scenario.
- Demonstrating a package-owned collector, store, logger, sink, recorder, fixture, factory, host, or provider by directly writing to it and reading it back instead of showing an indirect producer/consumer interaction.
- Copying external usage that no longer validates against the current package source.
- Treating external usage as proof of API shape, current method signatures, package ownership, popularity, or frequency.
- Copying staged files into website content without an explicit user request.
- Using only a bash installation command as Basic usage for a convenience package when referenced code packages can be demonstrated.
- Giving a convenience package fewer Basic usage examples than the number of referenced code packages.
- Reusing the individual package Basic usage examples verbatim on the convenience package page.
- Presenting referenced-package APIs as if they are owned by the convenience package.
- Writing convenience-package examples without referenced-package subheadings.
- Writing convenience-package examples that lack `[Fact]` or `[Theory]` methods.
- Treating README or package README as authoritative when source code is available.
- Omitting YAML frontmatter, leaving generated placeholder text in frontmatter, adding a redundant top-level `nugetUrl`, changing exact package NuGet links into search links, changing the index NuGet search link into a single package link, omitting `familyLinks`, or stripping `.md` from `familyLinks.url`.
- Repeating stale README examples without verifying method names, required overrides, inheritance, or constructor signatures against source.
- Claiming that a type requires an override, implements an interface, inherits another type, or exposes a property without checking the source declaration.
- Claiming package target frameworks or dependencies from README text instead of project files.
