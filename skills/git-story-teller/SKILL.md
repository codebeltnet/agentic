---
name: git-story-teller
description: >
  Generate source-grounded repository story markdown from deterministic ContentSync context bundles. Use when the user asks to create, refresh, or complete repo/package stories, family or project overview pages, .bot/stories output, ContentSync story workflows, or result/Index.md plus result/{TargetName}.md files for any repository URL. The skill runs its bundled .NET file-based context generator, writes target stories first, then writes the overview from completed target stories, and enforces grounding, context-budget, and no-invention rules.
---

# Git Story Teller

![Git Story Teller](assets/hero.jpg)

Use this skill to turn a deterministic story workspace into website-ready or docs-ready Markdown. The bundled `scripts/story.cs` runner owns repository access, evidence gathering, target discovery, context packing, and generated instructions. The agent owns reading that evidence, writing the story files, and validating that every claim is grounded.

## Critical

- Treat generated output as the source of truth. If `manifest.json`, `instructions.md`, or `*.context.md` files disagree with this skill, follow the generated files unless they are internally inconsistent.
- Keep the workflow generic. The runner input is a full repository URL, not an implied owner/slug convention.
- Require both `--repo-url` and `--output-root`. Do not invent defaults silently.
- If a `.bot` folder exists in the workspace the agent is working from, recommend `<workspace>/.bot/stories` as the output root.
- Do not make `repo-id` customizable. It is derived from the final repository URL path segment.
- Do not make the result directory customizable. It is always `result`.
- Do not assume GitHub owner, repository host, organization, package prefix, website path, or docs domain from memory.
- Do not call an LLM provider from the runner. The calling agent is the brain that writes prose.
- Process one target context at a time. Do not load all target contexts into the same prompt unless the generated manifest explicitly requires it.
- Write target result files before the overview result file.
- Do not invent APIs, target relationships, examples, dependencies, support statements, performance claims, or architectural claims not supported by the target context.
- If required deterministic files are missing, stale, contradictory, or too large to use safely, stop and report the blocking issue instead of guessing.
- Do not copy results into a website or documentation tree unless the user explicitly asks for publication or sync.

## Runner Contract

The skill bundles a .NET 10 file-based app:

```text
scripts/story.cs
```

Run it with `dotnet run --file` so it is not confused with a nearby project file:

```powershell
dotnet run --file <skill-root>/scripts/story.cs -- --repo-url <repo-url> --output-root <output-root>
```

Required inputs:

```text
--repo-url      Fully qualified git repository URL
--output-root   Directory where the story workspace will be written
```

Fixed conventions:

```text
repo-id      Derived from the final repository URL path segment, with .git removed
result dir   result
```

The runner requires the .NET 10 SDK or newer and `git`. It prefers Repomix through `npx repomix` for high-fidelity packing, because Repomix provides the canonical XML shape, ignore handling, token-aware metadata, and security checks. If `npx`/Repomix cannot start or npm registry access is unavailable, the runner tries the same public Repomix web API used by `https://repomix.com/` for GitHub HTTPS repository URLs. If both Repomix paths are unavailable, it falls back to its built-in .NET text packer so the workspace can still be generated.

Fallback notes:

- The Repomix web API fallback posts the repository URL, output format, and include patterns to `https://api.repomix.com/api/pack`; use it only for public GitHub repositories or repositories the user is comfortable sending to that service.
- The built-in .NET fallback is local-only and packs only files matching the runner's include patterns.
- The built-in .NET fallback does not provide Repomix token counts, Secretlint checks, compression, or exact gitignore semantics.
- If `.NET 10` or `git` is unavailable, stop and report the missing dependency.
- If Repomix runs and rejects content, do not bypass that result manually with a fallback unless the user explicitly accepts the lower-fidelity path.

Do not scrape or drive the browser UI. If a web fallback is needed, call the Repomix API endpoint directly and keep the lower-fidelity .NET fallback available in case the public service changes or is unreachable.

## Expected Workspace

The story root is chosen by the caller. For repositories that already use `.bot`, recommend:

```text
.bot/stories
```

Generated shape:

```text
{output-root}/{repo-id}/
  manifest.json
  instructions.md
  overview.context.md
  {TargetName}.context.md
  result/
    Index.md
    {TargetName}.md
```

The manifest is authoritative after generation. Always follow the manifest for concrete target names, context paths, result paths, and phase order.

## Workflow

### Step 1: Resolve Inputs

Collect or infer only these two runner inputs:

- `repo-url`: required. Ask for it if the user gives only a slug or a repository nickname.
- `output-root`: required. If the active workspace has a `.bot` directory, recommend `<workspace>/.bot/stories`; otherwise ask for the path.

Do not ask for `repo-id` or result directory. If two repositories would collide because they share the same final URL path segment, ask the user for a different `output-root`.

### Step 2: Generate or Locate the Story Workspace

If the user points to an existing `{output-root}/{repo-id}` folder, inspect it first.

If the workspace does not exist or the user asks to regenerate context, run the bundled runner from this skill:

```powershell
dotnet run --file <skill-root>/scripts/story.cs -- --repo-url <repo-url> --output-root <output-root>
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
- target phase entries
- overview phase entry
- each context file path
- each result file path
- dependency order

If there is no manifest, infer the target list only from `*.context.md` files and stop to tell the user the manifest is missing. Continue only if the user explicitly accepts the degraded workflow.

### Step 4: Write Target Stories

For each target in the first phase:

1. Open only that target's context file plus `instructions.md` if needed.
2. Confirm the target result path is `result/{TargetName}.md` or the manifest's declared equivalent.
3. Write the exact required sections from the generated context.
4. Ground API lists and examples in source, tests, project files, README files, or metadata found in the context.
5. Keep examples compact and use real namespaces, type names, method names, and constructor signatures from the context.
6. If the context proves the target is a convenience, aggregate, or metadata-only package with no source of its own, write that honestly instead of inventing APIs.

Do not use another target's context to fill gaps unless the current context explicitly includes it or the manifest marks that relationship as required.

### Step 5: Write the Overview

Write `result/Index.md` only after target stories exist.

Use the overview context and the completed target result files as the main editorial input. The overview should help readers choose between packages or understand the repository's shape. It should not repeat every target page or amplify unsupported claims.

If any target story is missing, decide from the manifest:

- If the overview depends on all target stories, stop and report the missing files.
- If partial overview generation is explicitly allowed, name the missing target stories in the final response.

### Step 6: Validate Grounding and Shape

Before finishing, verify:

- Every manifest target has a corresponding result file.
- `result/Index.md` exists when the manifest includes an overview target.
- Result filenames match manifest paths.
- Required headings from the generated context are present verbatim.
- No result file contains analysis notes, citations, XML, JSON, confidence scores, or chat commentary unless the generated prompt explicitly asks for them.
- Code examples mention only APIs visible in the relevant context.
- Target stories do not make broad claims such as robust, seamless, powerful, or comprehensive unless immediately grounded in concrete evidence.

Use targeted searches instead of rereading everything:

```powershell
rg -n "TODO|TBD|confidence|citation|analysis notes|I cannot|as an AI" <workspace>/result
rg -n "robust|seamless|powerful|comprehensive" <workspace>/result
```

Explain any remaining risk, especially missing tests, ambiguous APIs, oversized context, or targets whose purpose is unclear from source.

## Context Budget Rules

- Open target contexts one at a time.
- Prefer manifest summaries, target result files, and overview context for the overview instead of reopening every target context.
- If a single target context is too large for the active model, split the work by evidence type: project metadata first, public source second, tests third, README last.
- Never silently omit evidence because it is large. State the limitation and use the generated instructions to choose the smallest safe subset.

## Publication

The story workspace is staging output. A consuming website or docs system may map staged files into its own content tree. For the current Codebelt website, the conventional mapping is:

```text
src/Codebelt.Website.WebApp/Content/Markdown/{repo-id}/Index.md
src/Codebelt.Website.WebApp/Content/Markdown/{repo-id}/{TargetName}.md
```

Do not copy staged results there unless the user asks for website sync, publication, or integration.

## Good Output Characteristics

- Target pages are concrete, source-backed, and useful to experienced developers.
- The overview includes a `## Package selection` section that explains package selection, repository boundaries, and relationships.
- The writing is restrained and developer-facing, not marketing-heavy.
- The agent follows the generated manifest instead of improvising the run order.
- The final response names the result files written and any validation gaps.

## Bad Output Characteristics

- Running a separate ContentSync project instead of the bundled `scripts/story.cs` runner.
- Choosing provider/model/reasoning flags from memory.
- Passing only a repository slug when the runner requires a full URL.
- Assuming a fixed organization such as `codebeltnet` or a fixed repository host such as GitHub.
- Loading the entire repository context for every target story.
- Writing `Index.md` before target stories exist.
- Inventing usage examples from plausible framework patterns rather than supplied source and tests.
- Copying staged files into website content without an explicit user request.
