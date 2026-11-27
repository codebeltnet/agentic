---
name: dotnet-docfx-digest
description: >
  Use when the user wants to create, repair, audit, or complete DocFX docs for .NET public APIs, or has changed public API that needs namespace pages, XML comments, overwrite files, extension-member tables, examples, or build verification. Also use when the user wants Native and Docker run actions for DocFX examples. Exclude private/internal APIs.
---

# .NET DocFX Digest Steward

![.NET DocFX Digest](https://raw.githubusercontent.com/codebeltnet/agentic/main/skills/dotnet-docfx-digest/assets/hero.jpg)

Maintain DocFX documentation for the public .NET API exposed by the target checkout. Ground each page in the API a consumer can call, the problem it solves and the result the reader can observe.

## Resolve the operation

| Invocation | Work |
| --- | --- |
| `dotnet-docfx-digest` | Audit and repair the repository, including existing examples. Resume an in-flight audit on a bare host re-entry. |
| `dotnet-docfx-digest repair` | Inspect and correct existing documentation. Review examples with missing or stale behavioral evidence even when they build, run and have zero validator diagnostics. |
| `dotnet-docfx-digest csrun` | Inventory the selected fences, preserve their consumer scenarios through conversion and generate synchronized run actions. Follow the requested runtime verification policy. |
| `dotnet-docfx-digest repair csrun` | Discover, establish expectations, inspect and execute, repair, regenerate, verify behavior and delivery, then close the documentation gates in this invocation. |

Treat `repair` and `csrun` as independent modifiers. `csrun repair` selects the same work as `repair csrun`. `generate-run-actions` is an alias for `csrun`. For the composed operation verify affected runnable examples on each supported transport, reusing current matching evidence. A repository-wide repair need not regenerate assets unless run actions were requested.

Honor an explicit namespace, public type/member, project, changed API, page, dry run or toolbar-only request. Without a target, operate repository-wide. A narrower question about a command or diagnostic needs only its pertinent reference. On continuation recover the previous scope, modes, tracked and untracked edits, packet and evidence from the session and working tree.

## Load guidance at the decision that needs it

| When | Read |
| --- | --- |
| Authoring pages, auditing a project, choosing packets, or running a representative dry run | [Documentation workflow](references/workflow.md). Use the relevant targeted, repository-wide or dry-run procedure. |
| Repairing existing docs, checking a review finding, or reviewing a new, changed or converted fence | [Behavioral repair](references/repair.md). Apply its queue and observation checks before closing the example. |
| Designing or converting a scenario, identifying the owning package, or resolving the execution context | [Example architecture](references/example-architecture.md). Determine the required dependencies, application boundary and observation before writing code. |
| Generating, repairing or refreshing run actions, recipes, template assets or copy controls | [Run actions](references/run-actions.md). Use the existing generator for inventory, planning, validation, apply and synchronization. |
| Constructing or executing a compatible standalone program or xUnit test, or selecting a repository-backed alternative | [csrun composition](references/csrun-composition.md). Use the installed engine and its existing v1 contract. |
| Looking up script invocations, diagnostics, exit codes, reporting fields, timeout or execution profiles | [Script reference](references/scripts.md). Resolve bundled tools from the loaded skill directory. Fall back to the repository-managed skill path only if present. |
| Placing or changing UID mappings, overwrite front matter or section order | [DocFX overwrites](references/docfx-overwrite-files.md). |
| Selecting links for deeper reading about a scenario | [Contextual source references](references/contextual-source-references.md). |
| Delivering paired execution instructions or running a pinned integration test in its real project graph | [One-shot examples](references/one-shot-examples.md). |

## Establish scope before edits

1. Locate the repository root and inspect `git status --short`, relevant diffs and the active DocFX configuration. Run the bundled `agents.cs` against that root and read the resulting root `AGENTS.md`. Preserve content outside its managed block. Check the configuration's metadata inputs, content, overwrites, includes and destination. Codebelt uses `.docfx/docfx.json`.
2. Document public namespaces, types, delegates, members and extension methods. Keep XML comments, framework availability, namespace overviews and generated type pages consistent with the public contract. Work from the package's actual consumer entry points. Preserve supported APIs, target frameworks and assembly identities.
3. For an audit, run the fast `docfx.cs --json` and build the example inventory. Establish reflection-backed project packets with `--build-api-model --project-manifest <temp-path>` before repository-wide authoring. A source scan can miss APIs. If the resulting packets remain unusable, work sequentially from the assessment queue in namespace order and retain the build-backed final gate.
4. Finish safety, encoding, scope and overwrite-layout repairs first. Repair namespace orientation, availability and extension tables before adding missing type/member examples. Work through each packet's existing examples as well as its diagnostics. Changed files help prioritize a full audit. Only an explicit scope restriction limits coverage.
5. Read authored files before editing. Preserve in-flight work, hand-written prose, working links, related references, BOM and line endings. Only remove a historical URL after confirming a direct 404 or a replacement. Keep authored API Markdown inside the configured API overwrite locations (Codebelt `.docfx/api/namespaces/` and `.docfx/api/types/`). Availability includes belong on namespace pages. Keep Markdown paragraphs on single physical lines.
6. Keep queues, captures, evidence, draft requests and helpers in session storage or OS temp. Classify generated output before cleanup. Preserve authored files, config, source, project files and signing keys. Avoid broad restore or directory deletion. Only explicitly requested metadata cleanup may remove generated metadata the run relied on.

## Keep the documentation contract intact

Every public non-abstraction type and every public extension method needs a consumer example on the appropriate generated page. Use the existing generic-arity anchor rules for eligible families. Match the actual receiver signature and overload. Let DocFX render the Example heading from its mapping. Check the example lead and expected observation in the rendered order.

Unbound fences are complete library compilation units or explicitly labelled `// Program.cs` programs. Bind partial sources to their maintained context. Show the program or test that runs; identify a related pinned repository test separately. Preserve the supported Native and Docker delivery options together. Keep tests as evidence for consumer examples; leave test source and application startup under their existing ownership.

Use only pre-existing, approved and allowlisted compilation waivers. A missing dependency, difficult setup or empty example is repair work. If no source-backed example can be written, explain the omission and retain its unresolved inventory entry.

## Work to completion

After each small batch rerun fast `docfx.cs --json` and take the next repairable item. Resolve newly surfaced diagnostics and behavioral findings. Keep going through independent packets if one needs deeper investigation, then return to it. An interruption, large queue or context limit calls for rebuilding the temporary queue from evidence. A host continuation uses the active packet manifest or the sequential assessment/namespace fallback, the same fast rerun cadence and the final command and criteria below. A user pause or an external blocker after concrete attempts can end an incomplete run. Record the exact failing command, exit code, evidence and remaining scope.

For a documentation completion claim, inspect the touched diff, build and test the target repository. Use its root signing key when present or `-p:SkipSignAssembly=true` for a keyless Codebelt build/test. Record unrelated infrastructure failures separately and continue documentation work. Run the bundled scripts with the actual repository root:

```sh
dotnet run --file "<skill-dir>/scripts/agents.cs" -- --repo-root "<repo-root>"
dotnet run --file "<skill-dir>/scripts/docfx.cs" -- --repo-root "<repo-root>" --build-api-model --validate-samples --verify-docfx-build --json
```

Use the final build-backed report. Require `summary.fullVerificationRan` and `summary.canClaimCompletion` true, `summary.remainingWorkItems` zero, empty `summary.remainingGates` and `summary.remainingDiagnosticsByCode`, no new skip markers and no interim artifacts. Honor the scoped/dry-run reporting contract. Report warnings and unexecuted checks accurately.

Distinguish the evidence for each requested outcome:

| Dimension | Evidence |
| --- | --- |
| Structure | Correct UID ownership, overwrite mapping, namespace coverage, extension signatures and clean validator gates. |
| Compilation | The final displayed C# compiles against its intended framework, package or maintained project. |
| Execution | Exact command/source, prerequisites and observed process or test outcome. |
| Behavior | Source-backed expectation compared with an observation caused by the documented operation. Record expected-only, failed and verified claims separately. |
| Presentation | The lead, readable code, order, labels and expected output tell the same consumer story. |
| Run-action delivery | Matching fence, recipe, manifest and generated assets, paired controls and independent Native/Docker statuses. |

Unresolved behavioral defects keep the active repair incomplete even with green deterministic gates. If execution is unavailable, name the missing prerequisite and the claim that remains unverified. Inspect final status for scratch artifacts. Report the scope covered, relevant commands and results, and any remaining limitations.
