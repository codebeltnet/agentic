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
- Keep the workflow generic. The runner input is a full repository URL, not an implied owner/slug convention.
- Require both runner inputs `--repo-url` and `--output-root`. Do not invent defaults silently.
- Accept curated external usage repositories from the user's natural invocation when present, then pass each one to the runner with a repeated `--external-repo-url` flag.
- If the user invokes `/git-repo-digest <digest-repo-url> <optional-output-folder> <optional-external-url>...`, treat the first URL as the digest repo, treat the second value as `output-root` only when it is not a URL, and treat later URLs as external usage repositories.
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
- Package evidence includes generated `api-summary.md` and `engineering-signals.md` reading aids. Use them to focus attention on likely public types, lifecycle contracts, validation guards, factories, callbacks, and package-boundary clues, but verify every claim against raw source, tests, and project evidence.
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

## Workflow

### Step 1: Resolve Inputs

Collect or infer these runner inputs:

- `repo-url`: required. Ask for it if the user gives only a slug or a repository nickname.
- `output-root`: required. If the active workspace has a `.bot` directory and the user did not provide an output path, recommend `<workspace>/.bot/digests`; otherwise ask for the path.
- `external-repo-url`: optional and repeatable. Use only public repository URLs the user supplied as curated usage sources.

If the user invokes this skill with positional slash-command style arguments:

```text
/git-repo-digest <digest-repo-url> <optional-output-folder> <optional-external-url> <optional-external-url>
```

Map them as follows:

- First URL: `repo-url`.
- Second value: `output-root` only when it is not a URL.
- Any later URLs: repeated `external-repo-url` values.
- If the second value is a URL and no output root was supplied, ask for `output-root` or recommend `.bot/digests` when the active workspace has `.bot`.

Do not ask for `repo-id`, `run-id`, or result directory.

### Step 2: Generate or Locate the Digest Workspace

If the user points to an existing `{output-root}/{repo-id}` or `{output-root}/{repo-id}/{run-id}` folder, inspect it first.

If the workspace does not exist or the user asks to regenerate evidence, run the bundled runner from this skill:

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
- dependency order

If there is no manifest, infer the package list only from `prompts/*.prompt.md` and `evidence/*/` folders and stop to tell the user the manifest is missing. Continue only if the user explicitly accepts the degraded workflow.

### Step 4: Write Package Digests

For each package in the first phase:

1. Open only that package's prompt, evidence artifacts, and `instructions.md` if needed.
2. Try to read each required evidence file completely. If a read output is capped or truncated, open the manifest-declared evidence index and then read every manifest-declared chunk in numeric order until the whole evidence file has been inspected.
3. Confirm the package result path is `result/{PackageName}.md` or the manifest's declared equivalent.
4. Write the exact required sections from the generated package prompt.
5. Ground API lists and examples in source, tests, project files, README files, external usage files, or metadata found in the evidence.
6. For `## Basic usage`, prefer representative external usage when it exists, validates against current source evidence, and gives a clearer consumer scenario than owned tests.
7. Use generated summaries and engineering signals to revisit likely design invariants, lifecycle contracts, callback wiring, factory boundaries, generic type constraints, exception guards, and package-boundary decisions in the raw source.
8. Do not document non-public members as APIs, but do inspect internal implementation when it explains public lifecycle behavior, validation, callback flow, or package boundaries.
9. Keep examples compact and use real namespaces, type names, method names, and constructor signatures from the evidence.
10. If the evidence proves the package is a convenience, aggregate, or metadata-only package with no source of its own, write that honestly instead of inventing APIs.

Do not use another package's evidence to fill gaps unless the current prompt explicitly includes it or the manifest marks that relationship as required.

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

- Use the generated overview prompt's exact required headings, currently `## Overview`, `## Concepts`, and `## Usage guidance`.
- Start `## Concepts` with a short introductory paragraph before the first concept heading.
- Use concept subsection headings for ideas, patterns, boundaries, responsibilities, or trade-offs, not package names.
- Derive concept candidates from every completed package digest's `## Overview`, `## Key APIs`, `## Basic usage`, and `## Usage guidance` sections, then connect package responsibilities and APIs across layers where the evidence supports it.
- Build concepts from coverage first, then merge only true duplicates. A concept should survive when ignoring it would hide a substantial package-owned capability, extension model, boundary, or trade-off.
- Preserve distinct capability domains represented by package-owned APIs even when they share the same lower-level pattern, dependency, or factory model.
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

Before finishing, verify:

- Every manifest package has a corresponding result file.
- `result/Index.md` exists when the manifest includes an overview entry.
- Result filenames match manifest paths.
- Evidence index and chunk paths in the manifest exist for every generated evidence file.
- Required headings from the generated package prompt are present verbatim.
- Required headings from the generated overview prompt are present verbatim.
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
- Basic usage examples inspired by external usage validate every API call, constructor, namespace, and extension method against current source evidence.
- External usage evidence may shape the consumer scenario, but stale external code does not override current source or test evidence.
- For normal code packages, `## Basic usage` contains exactly one C# fenced code block unless the generated prompt explicitly allows more.
- For normal code packages, the Basic usage C# example contains exactly one `[Fact]` or `[Theory]` method unless the generated prompt explicitly allows more.
- For normal code packages, the two-sentence Basic usage explanation describes only what the example actually demonstrates.
- For convenience, aggregate, metadata-only, or no-assembly packages that reference code packages, `## Basic usage` contains one C# fenced code block per referenced code package.
- For convenience packages, each Basic usage example is introduced by a third-level heading naming the referenced package, for example `### Codebelt.Extensions.Xunit`.
- For convenience packages, each referenced-package example contains exactly one `[Fact]` or `[Theory]` method.
- For convenience packages, the Basic usage section includes a final paragraph explaining that the convenience package provides the single package reference and that the APIs come from the referenced packages.
- Convenience-package examples must not reuse individual package Basic usage examples verbatim.
- Convenience-package examples must not describe referenced APIs as if they are implemented by the convenience package itself.
- Convenience-package examples should be shorter and use-case-oriented. They should complement, not duplicate, the normal package pages.
- Every C# Basic usage example includes necessary `using` statements, prefers explicit imports, uses a consumer namespace, and includes at least one assertion or observable result.
- Every C# Basic usage example is small but complete enough to understand without hidden files, hidden helpers, hidden services, or unexplained setup.
- Basic usage examples do not contain placeholder comments, ellipses, TODOs, or magic helper calls.
- Basic usage examples do not introduce fake services, middleware, controllers, repositories, options, validators, domain types, or helper methods unless those types are defined inside the snippet or exist in the package evidence.
- Basic usage examples do not override lifecycle or cleanup hooks unless they clean up a real resource used by the example.
- Basic usage examples do not override lifecycle or cleanup hooks only to call the base implementation.
- Basic usage examples do not open external files, network resources, databases, environment variables, or machine-specific resources.
- For ASP.NET Core examples, prefer inline middleware such as `app.Run(...)` or `app.Use(...)` over `UseMiddleware<T>` unless `T` exists in the package evidence or is defined in the snippet.
- For hosting examples, avoid plumbing-heavy examples where manual fixture/service-provider wiring is more prominent than the package API unless the evidence proves that wiring is the intended basic usage.
- Public API and engineering-depth claims are verified against source or tests, not copied from generated summaries alone.
- API shape claims are verified against source code, not README text.
- Inheritance claims are verified against source declarations.
- Required override claims are verified against abstract/virtual source declarations.
- Constructor signatures and generic constraints are verified against source declarations.
- Factory method names, overloads, callback parameters, and return types are verified against source declarations.
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
rg -n "GenerateReport|CreateService|BuildHost|FormatInvoice|CreateClient|SampleMiddleware|MyService|IMyService|MyRepository|FakeRepository|MyController|SampleController" <workspace>/result
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
- Basic usage examples are small but complete: imports, namespace, one focused `[Fact]` or `[Theory]`, and an observable assertion/result.
- API shape, inheritance, generic constraints, required overrides, factory overloads, and lifecycle claims are verified against source declarations.
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
- Starting `## Concepts` immediately with a third-level heading and no introductory paragraph.
- Writing concepts that ignore completed package `## Key APIs` details.
- Collapsing distinct package-owned domains into one polished but lossy umbrella concept.
- Describing related packages in isolation when their responsibilities or APIs clearly connect.
- Creating one overview subsection per package instead of concept-led subsections.
- Repeating package-page API lists, Basic usage examples, installation commands, or overview paragraphs in `Index.md`.
- Using package names as concept headings.
- Inventing usage examples from plausible framework patterns rather than supplied source and tests.
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
- Repeating stale README examples without verifying method names, required overrides, inheritance, or constructor signatures against source.
- Claiming that a type requires an override, implements an interface, inherits another type, or exposes a property without checking the source declaration.
- Claiming package target frameworks or dependencies from README text instead of project files.
