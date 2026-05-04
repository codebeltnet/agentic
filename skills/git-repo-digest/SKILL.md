---
name: git-repo-digest
description: >
  Generate source-grounded repository digest markdown from deterministic local context bundles. Use when the user asks to create, refresh, or complete repo/package digests, family or project overview pages, .bot/digests output, digest workspace workflows, or result/Index.md plus result/{PackageName}.md files for any repository URL. The skill runs its bundled .NET file-based context generator over a git clone, emits public API and engineering signal summaries plus chunked context indexes, writes package digests first, then writes the overview from completed package digests, and enforces complete-read grounding and no-invention rules even when file output is capped.
---

# Git Repo Digest

![Git Repo Digest](assets/hero.jpg)

Use this skill to turn a deterministic digest workspace into website-ready or docs-ready Markdown. The bundled `scripts/digest.cs` runner owns repository access, evidence gathering, package discovery, context packing, and generated instructions. The agent owns reading that evidence, writing the digest files, and validating that every claim is grounded.

## Critical

- Treat generated output as the source of truth. If `manifest.json`, `instructions.md`, `*.context.md`, `*.context.index.md`, or `*.context.chunks/*.md` files disagree with this skill, follow the generated files unless they are internally inconsistent.
- Keep the workflow generic. The runner input is a full repository URL, not an implied owner/slug convention.
- Require both `--repo-url` and `--output-root`. Do not invent defaults silently.
- If a `.bot` folder exists in the workspace the agent is working from, recommend `<workspace>/.bot/digests` as the output root.
- Do not make `repo-id` customizable. It is derived from the final repository URL path segment.
- Do not make the result directory customizable. It is always `result`.
- Do not assume GitHub owner, repository host, organization, package prefix, website path, or docs domain from memory.
- Do not call an LLM provider from the runner. The calling agent is the brain that writes prose.
- Process one package context at a time. Do not load all package contexts into the same prompt unless the generated manifest explicitly requires it.
- When the runtime supports subagents and the manifest has multiple independent package contexts, prefer one subagent per package context. Give each subagent only its assigned package context, `instructions.md`, the relevant manifest entry, and the complete-read contract. Subagents reduce context pressure; they do not reduce grounding requirements.
- Complete reads are mandatory for the files used in the current phase. For a package digest, read that package's entire context before writing. For the overview, read the entire overview context and every completed package result file required by the manifest or generated instructions before writing. The generated index and chunks are a safer way to finish reading a large context; they are not permission to skip sections.
- Each generated context has three forms: the full `*.context.md` file, a deterministic `*.context.index.md` navigation file, and ordered raw-evidence chunks under `*.context.chunks/*.md`.
- Context indexes summarize each chunk in a `Contents` column. They list all real Markdown section headings found in that chunk and add stable packed-path labels such as `Source Code`, `Test Coverage`, `NuGet Documentation`, or `Project Metadata` when XML `<file path="...">` entries are present.
- If a tool caps, truncates, summarizes, or partially displays a required full context file, read its `*.context.index.md` file and then read every chunk listed in numeric order. If the chunk reads are also capped or incomplete, continue by ranges or stop and report the blocker instead of writing from a subset.
- Do not use a context index as evidence for digest claims. It is a navigation aid; the full context file or all ordered chunks are the source evidence.
- Package contexts may include generated `PUBLIC API SUMMARY` and `ENGINEERING SIGNALS` sections. Use them to focus attention on likely public types, lifecycle contracts, validation guards, factories, callbacks, and package-boundary clues, but verify every claim against the raw source and tests.
- Write package result files before the overview result file.
- For the overview, explicitly read every completed package result file listed by the manifest or `overview.context.md`. Reading only `overview.context.md` is an incomplete overview workflow because the package digests are the primary editorial source.
- Do not invent APIs, package relationships, examples, dependencies, support statements, performance claims, or architectural claims not supported by the package context.
- Do not turn a source-backed structural risk into an unmeasured behavior claim. Phrases such as "most common mistake", "developers often", "users frequently", "popular choice", "widely used", or "typical failure" require explicit evidence such as package analytics, issue history, docs that say so, telemetry, survey data, or examples in the generated context. Without that evidence, describe the risk conditionally: "If you install X in a project that only needs Y, it adds Z."
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

Fixed conventions:

```text
repo-id      Derived from the final repository URL path segment, with .git removed
result dir   result
```

The runner requires the .NET 10 SDK or newer and `git`. It performs one shallow git clone, discovers packages from that local clone, and packs context with its bundled C# packer. The packer uses `git ls-files` for deterministic tracked-file membership, applies the runner's include patterns, skips generated or low-signal paths, keeps text files only, and writes a stable XML repository-context block into each generated `*.context.md` file.

Packing notes:

- The context packer is local-only. It does not call Node/npm, Repomix, browser automation, or a public packing service.
- The context packer does not emit third-party token counts, compression summaries, or external Secretlint results. Treat source, tests, project files, README files, and generated public API / engineering signal sections as the grounding surface.
- The runner filters known low-signal files such as `GlobalSuppressions.cs` from packed context. Do not recreate or infer digest claims from those files.
- The runner follows Codebelt repository conventions for discovery: source projects live under `src/`, owned tests live under `test/`, and owned test projects are named after the package plus `.Tests` for libraries or `.FunctionalTests` for apps. It does not scan generic `tests/` roots or broader suffix variants such as `.UnitTests` or `.IntegrationTests`. Within the fixed `test/` root, it prefers a dedicated owned test project, then a single unambiguous direct project reference. If only downstream package tests match a shared base package prefix, the runner leaves `Test path` undiscovered instead of assigning another package's tests.
- If `.NET 10` or `git` is unavailable, stop and report the missing dependency.

## Expected Workspace

The digest root is chosen by the caller. For repositories that already use `.bot`, recommend:

```text
.bot/digests
```

Generated shape:

```text
{output-root}/{repo-id}/
  manifest.json
  instructions.md
  overview.context.md
  overview.context.index.md
  overview.context.chunks/
    0001.md
    0002.md
  {PackageName}.context.md
  {PackageName}.context.index.md
  {PackageName}.context.chunks/
    0001.md
    0002.md
  result/
    Index.md
    {PackageName}.md
```

The manifest is authoritative after generation. Always follow the manifest for concrete package names, full context paths, context index paths, context chunk paths, result paths, and phase order.

## Workflow

### Step 1: Resolve Inputs

Collect or infer only these two runner inputs:

- `repo-url`: required. Ask for it if the user gives only a slug or a repository nickname.
- `output-root`: required. If the active workspace has a `.bot` directory, recommend `<workspace>/.bot/digests`; otherwise ask for the path.

Do not ask for `repo-id` or result directory. If two repositories would collide because they share the same final URL path segment, ask the user for a different `output-root`.

### Step 2: Generate or Locate the Digest Workspace

If the user points to an existing `{output-root}/{repo-id}` folder, inspect it first.

If the workspace does not exist or the user asks to regenerate context, run the bundled runner from this skill:

```powershell
dotnet run --file <skill-root>/scripts/digest.cs -- --repo-url <repo-url> --output-root <output-root>
```

The runner writes deterministic context files and creates the `result` folder. It does not call an LLM and does not overwrite existing `result/*.md` files.

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
- each context file path
- each context index path
- each ordered context chunk path
- each result file path
- dependency order

If there is no manifest, infer the package list only from `*.context.md` files and stop to tell the user the manifest is missing. Continue only if the user explicitly accepts the degraded workflow.

### Step 4: Write Package Digests

For each package in the first phase:

1. Open only that package's context artifacts plus `instructions.md` if needed.
2. Try to read the package context file completely. If the read output is capped or truncated, open the manifest-declared context index and then read every manifest-declared chunk in numeric order until the whole context has been inspected.
3. Confirm the package result path is `result/{PackageName}.md` or the manifest's declared equivalent.
4. Write the exact required sections from the generated context.
5. Ground API lists and examples in source, tests, project files, README files, or metadata found in the context.
6. Use generated summaries and engineering signals to revisit likely design invariants, lifecycle contracts, callback wiring, factory boundaries, generic type constraints, exception guards, and package-boundary decisions in the raw source.
7. Do not document non-public members as APIs, but do inspect internal implementation when it explains public lifecycle behavior, validation, callback flow, or package boundaries.
8. Keep examples compact and use real namespaces, type names, method names, and constructor signatures from the context.
9. If the context proves the package is a convenience, aggregate, or metadata-only package with no source of its own, write that honestly instead of inventing APIs.

Do not use another package's context to fill gaps unless the current context explicitly includes it or the manifest marks that relationship as required.

### Optional Subagent Strategy

If the agent runtime can delegate work, use subagents to keep each package context isolated and roomy:

- Spawn at most one subagent per package context from the current package phase.
- Give each subagent a narrow task: completely read its assigned context, using the context index and ordered chunks if the full file is capped, follow `instructions.md`, write or draft only its assigned `result/{PackageName}.md`, and report any unreadable or contradictory evidence.
- Do not give one subagent multiple package contexts unless the manifest says those packages are dependent.
- Do not ask a subagent to write `result/Index.md` until all required package result files exist.
- The main agent is the orchestrator and final editor. It gathers each subagent's completed package result file, reported caveats, and validation notes, then authors `result/Index.md` itself from those completed digests plus `overview.context.md`.
- The coordinating agent remains responsible for manifest order, final file placement, overview synthesis, validation, and final reporting.

Subagent summaries and caveats are useful handoff material for the orchestrator, but they are not a replacement for the completed package result files required by the overview phase.

### Step 5: Write the Overview

Write `result/Index.md` only after package digests exist.

Open and completely read `overview.context.md`, or the overview context index plus every ordered overview chunk if the full file is capped, and every completed package result file listed by the manifest or by the generated required package-digest source section. Treat the completed package result files as the required package-digest source for `result/Index.md`; treat `overview.context.md` or its chunks as supplementary repository context for relationships, project metadata, README framing, and package inventory. Reading only `overview.context.md` is not sufficient when package result files exist.

If package digests were produced by subagents, collect their reported caveats and validation notes before drafting the overview. Use those notes to avoid overclaiming, but ground the overview in the completed package result files and `overview.context.md`.

The overview should help readers choose between packages or understand the repository's shape. It should not repeat every package page or amplify unsupported claims.

For usage guidance, separate evidence from inference:

- It is grounded to say a meta-package brings in referenced packages or framework references when the project files show that relationship.
- It is grounded to recommend the smaller package first when the generated instructions ask for "use less" guidance and the package boundaries support that recommendation.
- It is not grounded to call that situation "the most common mistake" or describe actual developer behavior unless the context includes frequency evidence.
- Prefer neutral phrasing such as "Avoid installing the aggregate package when..." or "Choose the aggregate package only when..." over popularity or frequency claims.

If any package digest is missing, decide from the manifest:

- If the overview depends on all package digests, stop and report the missing files.
- If partial overview generation is explicitly allowed, name the missing package digests in the final response.

### Step 6: Validate Grounding and Shape

Before finishing, verify:

- Every manifest package has a corresponding result file.
- `result/Index.md` exists when the manifest includes an overview entry.
- Result filenames match manifest paths.
- Context index and chunk paths in the manifest exist for every generated context.
- Required headings from the generated context are present verbatim.
- No result file contains analysis notes, citations, XML, JSON, confidence scores, or chat commentary unless the generated prompt explicitly asks for them.
- Code examples mention only APIs visible in the relevant context.
- Public API and engineering-depth claims are verified against source or tests, not copied from generated summaries alone.
- Package digests do not make broad claims such as robust, seamless, powerful, or comprehensive unless immediately grounded in concrete evidence.
- Results do not contain unmeasured frequency, popularity, adoption, or mistake-rate claims. Search for wording such as most common, often, frequently, usually, typical, popular, and widely, then keep it only when the context provides evidence for that exact kind of claim.

Use targeted searches instead of rereading everything:

```powershell
rg -n "TODO|TBD|confidence|citation|analysis notes|I cannot|as an AI" <workspace>/result
rg -n "robust|seamless|powerful|comprehensive" <workspace>/result
rg -n "most common|often|frequently|usually|typical|popular|widely|many developers|most developers" <workspace>/result
```

Explain any remaining risk, especially missing tests, ambiguous APIs, oversized context, or packages whose purpose is unclear from source.

## Complete-Read Rules

- Open package contexts one at a time.
- Use subagents for independent package contexts when available so each context can be read completely without competing for the same prompt budget.
- Prefer manifest summaries, package result files, and overview context for the overview instead of reopening every package context.
- For the overview, package result files are compact source material. Read those files directly before writing `Index.md` instead of relying on their path list inside `overview.context.md`.
- Do not treat context limits as permission to sample. The required file set for the current phase must be read completely.
- If a single package context is too large for one tool response, prefer the manifest-declared `*.context.index.md` file plus every ordered file under `*.context.chunks/`. If chunks are unavailable in an older workspace, split the full context read into ranges or sections and continue until the entire file has been inspected. Track where you left off so no section is skipped.
- Treat `*.context.index.md` as a table of contents, not as source evidence. It can tell you which chunks and packed files exist, but digest claims must come from the full context file or the complete ordered chunk set.
- Treat generated public API summaries and engineering signals the same way: they identify where to look, but they do not replace source, tests, project files, README files, or metadata as grounding.
- Use targeted searches only after the complete read, as a validation aid or to revisit specific evidence. Searches do not replace reading the required context.
- If the active model or available tools cannot read the full required file set for the current phase, stop and report the limitation. Do not write a digest from a partial context.

## Publication

The digest workspace is staging output. A consuming website or docs system may map staged files into its own content tree. For the current Codebelt website, the conventional mapping is:

```text
src/Codebelt.Website.WebApp/Content/Markdown/{repo-id}/Index.md
src/Codebelt.Website.WebApp/Content/Markdown/{repo-id}/{PackageName}.md
```

Do not copy staged results there unless the user asks for website sync, publication, or integration.

## Good Output Characteristics

- Package pages are concrete, source-backed, and useful to experienced developers.
- Independent package contexts may be handled by separate subagents, with each subagent fully reading one assigned context before drafting.
- Package pages are written only after the full package context has been read, either directly or through the complete ordered chunk set, including any portions hidden by capped or truncated tool output.
- Context indexes are used to plan reading and verify chunk coverage, not as a replacement for source evidence.
- Public API summaries and engineering signals help the agent notice fine-grained library design, but every final claim is still backed by raw context.
- Non-public implementation details are used only to explain public behavior, not listed as consumer APIs.
- The overview includes a `## Package selection` section that explains package selection, repository boundaries, and relationships.
- The overview synthesis clearly uses the completed package result files as source material, not just `overview.context.md`.
- Tradeoff guidance distinguishes structural evidence from behavioral frequency; it avoids "most common" style claims unless the context includes measurement or explicit source support.
- The writing is restrained and developer-facing, not marketing-heavy.
- The agent follows the generated manifest instead of improvising the run order.
- The final response names the result files written and any validation gaps.

## Bad Output Characteristics

- Running a separate .NET project instead of the bundled `scripts/digest.cs` runner.
- Choosing provider/model/reasoning flags from memory.
- Passing only a repository slug when the runner requires a full URL.
- Assuming a fixed organization such as `codebeltnet` or a fixed repository host such as GitHub.
- Loading the entire repository context for every package digest.
- Sending multiple unrelated package contexts to the same subagent when they can be processed independently.
- Treating a subagent's summary as a substitute for a completed package result file during overview synthesis.
- Treating capped, truncated, summarized, or partial context output as enough to write from.
- Treating `*.context.index.md` as a summary that can replace reading the full context or every chunk.
- Treating generated public API summaries or engineering signals as final evidence instead of prompts for source-backed inspection.
- Reading only the first few chunks because the index looked sufficient.
- Using context limits, token limits, or "strategic reading" as a reason to skip part of a required package context or overview source file.
- Claiming a mistake is common, most common, frequent, typical, popular, or widely observed based only on package structure or an inferred best practice.
- Writing `Index.md` before package digests exist.
- Writing `Index.md` after reading only `overview.context.md` and not the completed package result files.
- Inventing usage examples from plausible framework patterns rather than supplied source and tests.
- Copying staged files into website content without an explicit user request.
