# dotnet-docfx-digest workflow reference

Use this reference when you need the full step-by-step workflow, example inventory shape, ready-to-adapt templates, or the final completion checklist.

## Example inventory shape

Build a small example inventory from validator output and source evidence before writing examples. Treat it as a work queue, not as final-response prose.

```markdown
| UID | Kind | Required example location | Source evidence | Scenario | Status |
|---|---|---|---|---|---|
| Codebelt.Extensions.Xunit.Hosting.ApplicationHostFactory | Type | .docfx/api/types/Codebelt.Extensions.Xunit.Hosting.ApplicationHostFactory.md | Package README, ApplicationHostFactoryTest | Host a test server and create a client | Missing |
```

Do not mark an item complete until the evidence cell names concrete repository paths, the scenario states a consumer task, the overwrite section targets the correct UID or approved extension-method location, the file is included by `build.overwrite`, the sample compiles under `docfx.cs --validate-samples` (or has a justified skip marker), and `docfx.cs --json` no longer reports any missing, placeholder, reflection-only, target-use, invocation, duplicate-UID, lead, advanced-lead, family-anchor, symbol-ownership, sample-structure, or interim-artifact diagnostic.

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

Lead-writing diagnostics are not a lesser class of work. `EXAMPLE_LEAD_MISSING` means the code fence needs a direct consumer-task fly-in. `EXAMPLE_ADVANCED_LEAD_MISSING` means the sample is large, multi-block, setup-heavy, async, host/DI/configuration-oriented, or otherwise complex enough to need a multi-sentence lead that explains setup, prerequisite context, and workflow outcome. Fix these directly in the implicated overwrite files, in small batches if needed, then rerun the fast validator. Do not call them "quality backlog", "pre-existing prose", or "too large for this run."

Ownership diagnostics are clearable example obligations, not permanent facts about duplicate names. For `SYMBOL_COLLISION_UNRESOLVED`, map a C# example to every exact colliding type UID. For `EXTENSION_OWNER_AMBIGUOUS`, map the example to the exact declaring-type or method UID and invoke the method through receiver syntax such as `value.Normalize()`; a namespace-level example or static `Extensions.Normalize(value)` call does not prove the owner. Rerun until both diagnostics disappear from `summary.remainingDiagnosticsByCode`.

## Targeted workflow

Use this path when the user names a changed API or namespace.

1. Run `agents.cs`.
2. Run the safety gates: inspect `git status --short`, identify existing documentation work, and avoid broad restore or recovery commands.
3. Inspect the changed public API and determine affected namespaces.
4. Determine whether public extension methods are involved.
5. Inspect `.docfx/docfx.json` or the repository-specific DocFX config.
6. Locate existing overwrite files, namespace pages, availability includes, tests, and samples.
7. Run `docfx.cs --json --assessment-queue <temp-path> --search-examples` and read the assessment work queue. Resolve `<temp-path>` outside the repository working tree (for example, `$env:TEMP\docfx-assessment-queue.md` on Windows or `/tmp/docfx-assessment-queue.md` on Unix). The "GitHub Example Sources" section contains pre-computed `gh search code` commands and URLs; use those results as evidence before writing examples.
8. Convert test usage into consumer-oriented examples when relevant, and normalize obvious `System.*` / `Microsoft.*` framework qualifications into matching `using` directives when that keeps the final sample lean.
9. Update XML documentation comments where purpose-first summaries are needed.
10. Update or create namespace overview pages whose opening names the developer problem and outcome, followed by concrete when-to-use and start-here guidance.
11. Inspect sibling namespace pages in the same public API family and repair each affected page consistently.
12. Update `Extension Members` tables when public extension methods are involved. Use the literal `⬇️` (U+2B07 U+FE0F) in the Ext column — the validator now rejects corrupted or missing emoji with `EXTENSION_TABLE_ENCODING`. Keep the real receiver signature in the Type column (`IDecorator<Type>`, `IEnumerable<T>`, etc.) and preserve generic method arity in the Methods column (`As<T>`, `Configure<TOptions>`, `Parse<T>`).
13. Update or create overwrite content, including type-page examples for public non-abstraction types and explicit examples for public extension methods. Put a short human fly-in before every C# fence; when an example is large, multi-block, or setup-heavy, make the lead explain the setup/prerequisite and workflow outcome. Keep extension-container openings focused on the caller outcome and receiver scenario rather than C# declaration trivia unless a DocFX limitation genuinely needs a note.
14. Build or refresh the example inventory.
15. Preserve manual edits, working `Related:` links, and historical URL references. Remove or replace a URL only after directly verifying that the current destination returns HTTP 404. Timeouts, 403s, rate limits, DNS failures, and other lookup problems are not removal evidence.
16. Keep scratch assessment queues, manifests, review reports, captured validator output, progress notes, and helper scripts in temp or session storage instead of the repository. New working-tree files are only legitimate when they are the managed `AGENTS.md` block, the active `docfx.json`, or DocFX-authored namespace/type Markdown that maps to real public API. The validator auto-detects generic-arity type families and skips redundant sibling examples from the public API surface alone, so no skip manifest is ever written into the repository.
17. Run `git diff` for touched documentation paths and confirm the diff is intentional.
18. Run `dotnet build`, or `dotnet build -p:SkipSignAssembly=true` when a Codebelt repository has no root `.snk`.
19. Run `dotnet test`, or `dotnet test -p:SkipSignAssembly=true` when a Codebelt repository has no root `.snk`.
20. Run the Completion Repair Loop by rerunning the fast `docfx.cs --json`, repairing every remaining diagnostic, and updating the example inventory until `summary.canClaimCompletion` is `true`. Diagnostic age, volume, prose-only status, and pre-existing status are not blockers.
21. Run the build-backed completion verification `docfx.cs --build-api-model --validate-samples --verify-docfx-build` so samples compile, API discovery is reflection-precise, and DocFX builds in a temp copy.
22. Inspect `git status` and confirm no disposable generated DocFX output or scratch artifacts remained in the working tree.
23. Report verification results and any remaining deterministic findings.

## Repo-wide audit workflow

Use this path when the user invokes the skill without naming a specific API or namespace, including host auto-triggered runs that later re-enter by invoking `dotnet-docfx-digest` directly with no extra arguments.

1. Run `agents.cs`.
2. Run the safety gates: inspect `git status --short`, identify existing documentation work, and avoid broad restore or recovery commands.
3. Read repository guidance, especially root `AGENTS.md`.
4. Inspect `.docfx/docfx.json` or the repository-specific DocFX config.
5. Read `references/docfx-overwrite-files.md`.
6. Run `docfx.cs --json --assessment-queue <temp-path> --search-examples` and read the assessment work queue. Resolve `<temp-path>` outside the repository working tree (for example, `$env:TEMP\docfx-assessment-queue.md` on Windows or `/tmp/docfx-assessment-queue.md` on Unix). That queue is the authoritative work queue. The "GitHub Example Sources" section contains pre-computed `gh search code` commands and URLs for each documented package — run or open these searches before writing any new example.
7. For repo-wide or other full authoring runs, run `docfx.cs --build-api-model --project-manifest <temp-path> --json` before writing new examples or overwrite rewrites, then use the reflection-backed packets as the bounded work queue. If build-backed packet discovery is still unusable, fall back to sequential assessment-work-queue or namespace-first order instead of authoring from the raw global count alone.
8. In any continuation response after a rerun, explicitly name that active queue source. If the reflection-backed manifest is not yet confirmed, the next step must say so and name `--build-api-model --project-manifest <temp-path>` directly; do not just say "work packet-by-packet."
9. In that same continuation response, restate the fast rerun cadence (`docfx.cs --json` after each small batch), the exact endgame command `docfx.cs --build-api-model --validate-samples --verify-docfx-build --json`, and the clean completion contract (`summary.canClaimCompletion = true`, `summary.remainingWorkItems = 0`, empty `summary.remainingGates`, empty `summary.remainingDiagnosticsByCode`). Do not shorten this to generic "verify later" prose, even in a brief reply.
10. If the first rerun still leaves hundreds or thousands of repairable diagnostics, treat that output as the active repair queue, not as a checkpoint. A host re-entry that invokes `dotnet-docfx-digest` directly with no extra arguments is still the same repo-wide continuation.
11. If the validator fails before producing documentation diagnostics, inspect source projects, DocFX config, existing overwrite files, generated metadata when available, tests, and samples manually.
12. Check for `ENCODING_CORRUPTION` or `EXTENSION_TABLE_ENCODING` diagnostics first; restore affected files from git before doing any further editing.
13. Determine every namespace containing public API and whether each namespace exposes public extension methods.
14. Determine every public non-abstraction type and every public extension method that requires an example.
15. Ensure `docfx.json` includes both `api/namespaces/**/*.md` and `api/types/**/*.md` under `build.overwrite`, excludes both `api/namespaces/**` and `api/types/**` from `build.content`, and moves legacy authored `.docfx/api/*.md` files into either `api/namespaces/` (namespace pages) or `api/types/` (type pages).
16. Create or update missing namespace overview pages with a problem/outcome opening, concrete when-to-use guidance, and a named starting API. Inventory-only prose is unfinished.
17. Audit related namespace pages together so fixes are consistent across the public API family.
18. Add or repair `Extension Members` tables for namespaces with public extension methods. Use the literal `⬇️` (U+2B07 U+FE0F) in the Ext column. If `EXTENSION_METHOD_MISSING` or `EXTENSION_METHOD_SIGNATURE_MISSING` appears after `EXTENSION_SECTION_MISSING` drops, treat that as the same namespace-layer queue getting more specific: finish table contents and signature fidelity before resuming net-new examples.
19. Finish the namespace-layer pass across the active queue before net-new type/example authoring: repair namespace prose, availability/start-here guidance, and `NAMESPACE_EMBEDDED_OVERWRITE_SECTION` ownership problems, moving misplaced type/member examples into readable type-targeted files under `.docfx/api/types/` when needed. Rerun the fast validator until namespace-layer diagnostics are gone or only example-driven work remains.
20. Add or repair overwrite content for public API items that need examples, remarks, corrected summaries, availability notes, or exact ownership evidence. For colliding type names, target every exact type UID. For colliding extension containers, target the exact declaring-type or method UID and use receiver syntax. Put a short human fly-in before every C# fence; when an example is large, multi-block, or setup-heavy, make the lead explain the setup/prerequisite and workflow outcome. Keep extension-container openings focused on the caller outcome and receiver scenario rather than C# declaration trivia unless a DocFX limitation genuinely needs a note.
21. Create separate type-page overwrite files for public non-abstraction types that have no example yet, under `.docfx/api/types/{TypeUid}.md` in Codebelt repositories.
22. Create explicit examples for public extension methods that still have none.
23. Build or refresh the example inventory.
24. Preserve manual edits, working `Related:` links, and historical URL references. Remove or replace a URL only after directly verifying that the current destination returns HTTP 404. Timeouts, 403s, rate limits, DNS failures, and other lookup problems are not removal evidence.
25. Keep scratch assessment queues, manifests, review reports, captured validator output, progress notes, and helper scripts in temp or session storage instead of the repository. New working-tree files are only legitimate when they are the managed `AGENTS.md` block, the active `docfx.json`, or DocFX-authored namespace/type Markdown that maps to real public API. The validator auto-detects generic-arity type families and skips redundant sibling examples from the public API surface alone, so no skip manifest is ever written into the repository.
26. Run `git diff` for touched documentation paths and confirm the diff is intentional.
27. Run `dotnet build`, or `dotnet build -p:SkipSignAssembly=true` when a Codebelt repository has no root `.snk`.
28. Run `dotnet test`, or `dotnet test -p:SkipSignAssembly=true` when a Codebelt repository has no root `.snk`.
29. Run the Completion Repair Loop by rerunning the fast `docfx.cs --json`, repairing every remaining diagnostic, and updating the example inventory until `summary.canClaimCompletion` is `true`. A large queue is still the task, not a reason to stop; this includes lead-writing, sample-structure, family-anchor, and interim-artifact cleanup queues.
30. Keep the exact endgame command explicit in continuation responses: `docfx.cs --build-api-model --validate-samples --verify-docfx-build --json`, plus the clean completion contract. Do not replace it with generic "verify later" language.
31. Run the build-backed completion verification `docfx.cs --build-api-model --validate-samples --verify-docfx-build` so samples compile, API discovery is reflection-precise, and DocFX builds in a temp copy.
32. Inspect `git status` and confirm no disposable generated DocFX output or scratch artifacts remained in the working tree.
33. Only after `summary.canClaimCompletion` is `true`, `summary.remainingWorkItems` is `0`, `summary.remainingGates` is empty, and `summary.remainingDiagnosticsByCode` is empty, report completion. If a genuine external blocker stops the run first, report the exact command, exit code, blocker, and that the digest remains incomplete.

When resuming a partial repo-wide audit, begin by inventorying all tracked and untracked documentation changes and preserving them as in-flight work. Regenerate the deterministic assessment work queue and example inventory, refresh or create a reflection-backed project manifest for bounded packets, and use those artifacts as the authoritative queue. Keep those artifacts in temp or session storage rather than the repository. Finish the namespace-layer pass across the affected namespaces before returning to net-new type/example authoring. If the host re-enters with a bare `dotnet-docfx-digest` invocation and the first rerun still leaves hundreds of repairable diagnostics, that is still the same continuation and the same active queue. If the remaining diagnostics are mostly `EXAMPLE_ADVANCED_LEAD_MISSING`, `EXAMPLE_LEAD_MISSING`, `FAMILY_ANCHOR_EXAMPLE_MISSING`, `SAMPLE_STRUCTURE_INVALID`, or `INTERIM_ARTIFACT_IN_WORKTREE`, treat them as the current repair queue and keep editing or cleaning. In the next response after each rerun, explicitly name whether the active queue is that manifest or the sequential assessment-work-queue / namespace-first fallback, restate the fast rerun cadence, and restate the exact final command plus clean completion contract. Work in small internal batches with a fast validator rerun after every batch, but do not treat a batch boundary as a reporting boundary. The exact final command is `docfx.cs --build-api-model --validate-samples --verify-docfx-build --json`; descriptive references to those activities do not replace running the flags together.

For the final command, let `auto` choose the execution profile unless the user requests a specific resource policy. High-capacity machines run the isolated DocFX verification lane concurrently with API/sample work; conservative machines remain sequential. Give the outer command a timeout at least five minutes above the validator's child-process timeout (35 minutes with the default 30-minute setting) so timeout diagnostics can be returned normally.

Keep `stderr` visible during the final command. API build, sample compilation, and DocFX verification print a start event, 10-second heartbeats, and a final success/failure event there. Use the phase, PID, elapsed time, last-output age, and current output line to decide whether work is progressing or a child appears stale. Capturing `stdout` for `--json` is safe because progress never enters the JSON stream.

## Project-scoped packets and representative dry runs

A repository-sized authoring queue degrades quality as the target count grows. Process documentation in bounded **project packets** instead, where each packet is one resolved `.csproj` with its metadata group, owned and shared namespaces, public API targets, existing overwrite files, related dirty paths, and scoped diagnostics. Discover packets with `docfx.cs --json` (the `scope.packets` array) or persist them with `docfx.cs --project-manifest <path>`.

Full and dry runs use **identical** evidence, authoring instructions, semantic-quality gates, and sample compilation. The only difference is which packets are selected.

### Build-backed scope is a prerequisite for authoring

The conservative source scanner is for fast Markdown iteration, not authoritative scope. When `summary.apiModelSource` is `source-scan`, scope is `provisional` and the validator emits `BUILD_BACKED_SCOPE_REQUIRED`. Before authoring a full run or a selected dry-run packet, establish reflection-precise scope with `--build-api-model` (or generate DocFX managed-reference YAML). In a repo-wide audit, do this before the first new example or overwrite rewrite, not after a partial fast-path cleanup. Treat a material fast/build-backed discrepancy as a blocker, not a rounding error.

A fast `--project-manifest` result that yields unnamed packets, `projects: []`, or `metadataGroup: unknown` is not a usable plan for large example queues. That is still provisional source-scan scope. Immediately rerun packet discovery with `--build-api-model --project-manifest <temp-path>` (or use generated DocFX YAML) before planning example authoring, then continue from the reflection-backed packet set.

### Scope stability

Target counts, diagnostic volume, ownership complexity, context pressure, and model usage limits never change the requested scope. A full run remains full regardless of queue size. Use project packets to keep authoring context bounded, continue through independent packets when one packet needs more debugging, and return to every unresolved diagnostic before final verification. Use dry-run only when the user explicitly requests a dry run, representative subset, or quality pilot.

Reruns often replace a coarse queue with a more specific one: for example, `EXTENSION_SECTION_MISSING` may shrink only for `EXTENSION_METHOD_MISSING` or `EXTENSION_METHOD_SIGNATURE_MISSING` to appear once the tables exist, or namespace repairs may surface the next layer of `EXAMPLE_MISSING` work. Treat that handoff as expected progress. Do not stop to summarize partial progress, ask whether to continue, or offer a "focus this area vs. just verify" menu while repairable diagnostics remain.

An example-only, example-quality-only, or unresolved-ownership-only queue is still incomplete. When `EXAMPLE_MISSING`, `EXAMPLE_LEAD_MISSING`, `EXAMPLE_ADVANCED_LEAD_MISSING`, `SYMBOL_COLLISION_UNRESOLVED`, or `EXTENSION_OWNER_AMBIGUOUS` is the only remaining diagnostic family — even hundreds of them — the correct next step is more example authoring, lead repair, or ownership disambiguation, not a completion report, checkpoint, final verification pass, dry-run suggestion, or user choice menu. Internal worries like "this is massive", "this will take multiple sessions", "these are pre-existing", "these are just warnings", "this is just prose", or "this may exceed context limits" are not user-facing stop conditions; solve them with packets and keep going.

### Example and lead micro-loop

When the queue is dominated by `EXAMPLE_MISSING`, `EXAMPLE_LEAD_MISSING`, or `EXAMPLE_ADVANCED_LEAD_MISSING`, shrink your mental scope to the next concrete target instead of the total count.

1. Take the next example or lead diagnostic from the assessment work queue or current fast-validator output.
2. Read that target's public API surface, the existing overwrite prose/code, and one relevant test, sample, or usage source.
3. Write one consumer-facing example to the correct type-targeted overwrite file, or add the missing fly-in/advanced lead that explains the consumer task, setup, prerequisite, and expected outcome for the existing example.
4. Rerun the fast validator.
5. Repeat for the next 3-5 examples or leads, rerun the fast validator, and continue immediately while diagnostics remain.

A "batch" does not need to be an architecturally complete namespace, packet, or package. A batch is any set of examples you can finish confidently before rerunning validation. Completeness emerges from iteration. Batch size is a validator-rerun cadence, not a checkpoint or reporting boundary.

While `remainingWorkItems > 0` or `canClaimCompletion` is false, do not emit before/after tables, file-count summaries, "remaining work" dashboards, or "Next Steps" lists. Keep repairing, or report a genuine external blocker with the exact command and exit code. When you do describe the next repair step, name the active queue source, the fast rerun cadence, the exact endgame command, and the clean completion contract rather than referring to them abstractly.

If packet discovery stays weak even after `--build-api-model`, fall back to sequential repair in assessment work queue order or alphabetical namespace-first order. Clear the next namespace's namespace-layer diagnostics first, then its remaining examples (or the next 3-5 examples in it), rerun, and continue. A tool limitation is not a decision point.

Final verification with `--build-api-model --validate-samples --verify-docfx-build` is reserved for the moment you intend to claim completion. While `remainingWorkItems > 0` or any diagnostics remain, stay on the fast `docfx.cs --json` loop and keep authoring.

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

### Packet authoring loop

Process one packet at a time so the packet is the active context and write-ownership boundary. Fresh workers are optional, not default: use them only when a packet is example-heavy or source-heavy enough to benefit from isolated context. For namespace prose, availability, related links, start-here guidance, and `Extension Members` table repairs, prefer direct edits in the main agent or batch 2-4 sibling pages per worker. If a prose-focused worker has not produced a concrete diff within about 45 seconds, or it goes quiet after writing the assigned file, inspect the output, stop delegating that class of work, and continue inline. For each packet: read the manifest and scoped diagnostics, read related Markdown before editing, read exact source/test/sample/package evidence, build an evidence ledger mapping each decision to a source path, classify targets into standalone-example or family-covered obligations, author namespace prose and overwrites, run the scoped semantic and sample gates, and review the diff. Repair mechanical output immediately. If a packet retains a difficult diagnostic after concrete debugging attempts, record its exact UID/path set and continue independent packets; return to the failed packet before global verification. Do not end a full run while any repairable diagnostic remains.

### Symbol ownership

Duplicate simple type names and repeated extension-container names are valid API shapes; unresolved documentation ownership is not. `SYMBOL_COLLISION_UNRESOLVED` is a blocking error only while one or more colliding types lack a C# example under the exact type UID. `EXTENSION_OWNER_AMBIGUOUS` is a blocking error only while one or more affected methods lack receiver-style invocation evidence under the exact declaring-type or method UID. Both clear after those deterministic conditions are met and remain in `summary.remainingDiagnosticsByCode` until then. `TYPE_FORWARDING_UNRESOLVED` remains an informational warning when the source declaration cannot be attributed safely; report it rather than inventing an owner.

### Generic-arity family skips (auto-detected)

A generic-arity type series — public types whose UIDs share one base name and differ only by the trailing arity suffix (for example MutableTuple from arity 1 through 20, or TesterFunc from arity 2 through 18) — may replace redundant standalone sibling examples with one anchor example plus deep namespace guidance. `docfx.cs` auto-detects these families from the public API surface; no file is written into the repository to declare or persist them.

Detection groups non-abstraction type targets by their arity-stripped base key. Only types whose UID carries a trailing backtick-N arity suffix (N >= 1) are candidates; a non-generic type that merely shares the base name keeps its own standalone-example obligation. The lowest-arity member is the anchor; every other member is a covered sibling that is removed from standalone-example obligations while keeping accurate purpose-first prose that relates it to the anchor.

The anchor must carry a real, behavioral example (`FAMILY_ANCHOR_EXAMPLE_MISSING` otherwise), and the namespace page must name the anchor and explain how consumers choose among the arity siblings (`FAMILY_NAMESPACE_GUIDANCE_MISSING` otherwise). The auto-detected families appear in the JSON scope output as `skippedFamilies` (with `familyId`, `namespaceUid`, `anchorUid`, `coveredUids`, `rationale` of `generic-arity`, and `valid`) so the decision is reviewable without leaving an artifact in the repository. Only arity-detectable series are auto-skipped; overload, inherited-specialization, or type-parameter series that do not differ by arity are not skipped and each member keeps its own example obligation.

### Safe overwrite writer

For repeatable overwrite creation, hand authored content to the structured writer instead of improvising fenced Markdown with ad-hoc scripts: write a request file with `file`, `uid`, `mapping` (`example`/`summary`/`remarks`), `prose`, and `fence`, then run `docfx.cs --write-overwrite <request.json>`. The writer validates YAML, rejects duplicate UIDs and unbalanced fences, preserves the file's BOM and line endings, refuses to replace a pre-existing dirty file, and prints a change preview. It never generates prose, selects members, or synthesizes examples — that remains your evidence-grounded editorial work.

### Evidence-grounded scenario patterns

These are search directions, not templates to emit verbatim. Confirm every pattern against packet-local source, tests, samples, or package documentation before writing, and reject generic `Workflow`, `Current`, `Consumer`, and mass-forwarding shells when they are not real concepts in the package:

- **Options configuration** — bind or build an options object, then show the operation that consumes it.
- **Middleware / DI registration** — register the service on a builder, then show the request or resolution it enables.
- **Authentication header construction** — build the credential/header, then attach it to a request.
- **MVC filters / results** — apply the filter or return the result, then show the observable response.
- **Stream processing / compression** — wrap or transform a stream, then read or write the transformed bytes.
- **Formatter setup** — configure the formatter, then serialize or deserialize a payload.
- **Delegate / factory pipelines** — register the factory, then invoke it to produce a configured instance.
- **Discoverable acquisition paths** — when public signatures, tests, docs, or samples show that another public API returns or acquires the target type, build the example around that path and then inspect or use the returned instance. Do not manually construct the target unless the public evidence shows direct construction is the intended entry point.

Each chosen scenario must still produce, configure, transform, register, send, store, or validate something a real caller observes.



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

Namespace overview files stay single-UID and stop after the fly-in, availability, related links, and optional `Extension Members` table. Do not append secondary `uid:` / `example:` mappings there; put extension-method examples on the declaring extension class page or another readable type-targeted file under `.docfx/api/types/`.

## Type example shape

> **DocFX overwrite Markdown only.** This shape is for writing DocFX overwrite content. Do not create tests from it. Tests are evidence, not output — use tests to understand behavior, then transform that knowledge into consumer-facing examples.

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
- `EndpointConventionBuilderExtensions.G$6D0D8037DBBD61D10816ECA5F93B896F.md`

Keep the filename readable, place the example in the declaring extension class file or another readable file under `.docfx/api/types/`, and let the YAML `uid` determine what model receives the content. Do not append member-level overwrite sections to the namespace page. If a compiler-generated C# extension-block container appears in DocFX YAML or build-backed reflection discovery, collapse it back to the authored outer static class before creating required-example targets; deleting the synthetic file after creation is cleanup, not success.

## Verification checklist

Before completing documentation work, verify:

- [ ] `agents.cs` ran successfully.
- [ ] `AGENTS.md` contains the managed DocFX maintenance block.
- [ ] Initial `git status --short` was inspected and existing documentation changes were treated as user work.
- [ ] For multi-diagnostic audits, `docfx.cs --assessment-queue` was written, read, and used as the work queue.
- [ ] Only public API is documented.
- [ ] Every namespace with public API has a namespace overview page.
- [ ] Related namespace pages in the same public API family were inspected and updated consistently, or intentionally left unchanged with a reason.
- [ ] Namespaces with public extension methods have an `Extension Members` section.
- [ ] Public non-abstraction types have at least one type-page example.
- [ ] Public extension methods have at least one explicit example, not only a table entry.
- [ ] Package IDs and package-level usage evidence were inspected before type/member-only sample synthesis.
- [ ] Every inventory row names exact evidence paths and a consumer task; generated metadata and the target overwrite file are not the sole evidence.
- [ ] The example inventory maps each required public type and extension method to its example file, UID, source evidence, and chosen scenario.
- [ ] Every example has a human-written fly-in immediately before the C# fence; advanced examples explain setup, prerequisites, or workflow outcome before the code.
- [ ] Examples show a coherent consumer workflow, use related public types when helpful, and avoid placeholder-only `Consumer`/`MyNamespace` shells when a domain name is available.
- [ ] No example is reflection-only, metadata-only, duplicated by UID, or built from `DocumentedTypeExample`, `DocumentedExtensionExample`, or generic `Describe()` scaffolding.
- [ ] The C# fence itself uses the documented type or invokes the documented extension method; prose, comments, and strings are not counted as usage.
- [ ] Missing examples are added through DocFX overwrite content included by `build.overwrite`. Namespace pages are under `api/namespaces/` and type pages are under `api/types/`.
- [ ] The Completion Repair Loop was run after edits, and the final report has zero missing/low-quality example, symbol-ownership, namespace-prose, extension, availability, overwrite-layout, sample, and DocFX-build diagnostics.
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

Use this section only after the completion contract is clean, or when a genuine external blocker has halted further progress after concrete attempts.

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

Do not claim documentation was verified unless the relevant command actually ran successfully, and do not emit a completion-shaped report while `summary.remainingWorkItems > 0`, `summary.canClaimCompletion` is false, or `completionState` is still `incomplete` or `verification-required`.

If work must stop incomplete, distinguish a true external blocker from repair work. Pre-existing documentation gaps, large diagnostic counts, sample compile failures, and `DOCFX_BUILD_FAILED` output caused by the documentation/configuration being repaired are active work items. Only a user pause or an external condition that still prevents progress after concrete attempts justifies stopping, and that response must say the digest remains incomplete.
