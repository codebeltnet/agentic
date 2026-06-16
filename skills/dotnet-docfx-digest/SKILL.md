---
name: dotnet-docfx-digest
description: >
  Create and maintain developer-friendly DocFX documentation digests for .NET public APIs, including repo-wide no-input audits, concept-led namespace overview pages, purpose-first type/member summaries, extension-member documentation, overwrite files, examples, availability notes, AGENTS.md maintenance, and verification. Use when the user asks to document a .NET API, create or update DocFX documentation, write namespace overview pages, improve API summaries, add extension-method tables, update XML documentation comments, add API examples, maintain DocFX overwrite files, or verify documentation builds. Treat requests like "use dotnet-docfx-digest", "update the DocFX docs", "complete missing documentation", "create namespace pages", "improve these API summaries", "add examples for this type", "update the extension members table", or "verify the documentation builds" as automatic triggers. Also use whenever public .NET API surface changes and documentation needs to stay aligned with source code.
---

# .NET DocFX Digest Steward

## Description

Create and maintain developer-friendly DocFX documentation digests for .NET public APIs. Keep namespace pages, generated API pages, examples, availability notes, and verification aligned with the actual source code and tests.

## Critical

- This skill is autonomous by default. If the user invokes it without naming a namespace, type, member, or changed API — including a bare direct skill call with no parsed arguments, a host-initiated continuation, or a host re-entry that invokes `dotnet-docfx-digest` directly with no extra arguments after the skill already auto-triggered — assume non-human/autonomous execution, treat the request as a repo-wide DocFX audit and repair task, and do not ask startup scoping or approval-to-continue questions.
- Resolve bundled scripts from the loaded `dotnet-docfx-digest` skill directory first. If that install path is unavailable and the target repository contains the repo-managed source copy, fall back to `skills/dotnet-docfx-digest/scripts/*.cs`. Do not claim the scripts are unavailable until both locations have been checked.
- `docfx.cs` is fast by default: a plain run validates Markdown, prose, DocFX overwrite layout, namespace pages, extension tables, and required examples **without building, restoring, or running DocFX/gh**. Use it freely during iteration — it discovers the public API from existing DocFX YAML metadata or a conservative source scan, and ends with a `[processes] dotnet=0 msbuild=0 docfx=0 gh=0` summary. Compilation and network access are opt-in.
- Iterate quickly with the fast path, reading diagnostics as the next work queue:

```bash
dotnet run --file <resolved-skill-dir>/scripts/docfx.cs -- --repo-root <repo-root> --json
```

- Before claiming completion, run `agents.cs`, then a thorough build-backed verification that compiles samples, uses reflection-backed API discovery, and verifies the DocFX build:

```bash
dotnet run --file <resolved-skill-dir>/scripts/agents.cs -- --repo-root <repo-root>
dotnet run --file <resolved-skill-dir>/scripts/docfx.cs -- --repo-root <repo-root> --build-api-model --validate-samples --verify-docfx-build
```

- `--build-api-model` makes API discovery reflection-precise (the fast source-scan path is conservative and may under-report), `--validate-samples` compiles every C# documentation sample through isolated projects in one temporary `.slnx` graph build with bounded MSBuild parallelism, and `--verify-docfx-build` confirms the DocFX build succeeds. Treat `API_MODEL_SOURCE_SCANNER_LIMITED` in a fast run as a reminder to run the build-backed verification before completion, not as a failure.
- For noisy audits, write and read a deterministic assessment work queue with `--assessment-queue`. This works on the fast path; add `--search-examples` to embed real GitHub usage:

```bash
dotnet run --file docfx.cs -- --repo-root <repo-root> --json --assessment-queue <temp-path> --search-examples
```

Resolve `<temp-path>` outside the target repository working tree (for example, `$env:TEMP\docfx-assessment-queue.md` on Windows or `/tmp/docfx-assessment-queue.md` on Unix).

The assessment work queue includes a "GitHub Example Sources" section with pre-computed `gh search code` commands and GitHub search URLs for each documented package. Read that section before writing any new example — do not write examples from memory or invention when real source evidence is available. If `--search-examples` is provided and `gh` is authenticated, actual search results are embedded; otherwise, the search commands are ready to run.
- While diagnostics remain, the only valid mid-run behaviors are: keep repairing, or report a genuine external blocker with the exact command, exit code, and failure output. Do not emit progress tables, checkpoint summaries, review pauses, "Would you like me to continue?" prompts, or focus/verify menus just because a batch finished, the queue is large, or the session has been long.

- For repo-wide or other full authoring runs, establish a bounded write queue before authoring new examples or overwrite rewrites:

```bash
dotnet run --file <resolved-skill-dir>/scripts/docfx.cs -- --repo-root <repo-root> --build-api-model --project-manifest <temp-path> --json
```

Read the reflection-backed packets from that manifest or from `scope.packets`. If build-backed packet discovery still fails or remains unusable, fall back to sequential assessment-work-queue or namespace-first order instead of authoring from the raw global count alone.
- In any mid-audit continuation after a rerun, name the active queue source explicitly. If a reflection-backed packet manifest has not already been confirmed, the next step must explicitly be `--build-api-model --project-manifest <path>` before more large-scale example authoring. Do not talk generically about "working packet-by-packet" without naming how those packets are obtained.
- In every continuation response while diagnostics remain, include an explicit completion-gate sentence that names the final command family and contract, for example: `Completion gate remains docfx.cs --build-api-model --validate-samples --verify-docfx-build --json; do not claim completion until summary.canClaimCompletion = true, summary.remainingWorkItems = 0, summary.remainingGates is empty, and summary.remainingDiagnosticsByCode is empty.` Shorter "verify later" wording is not sufficient.
- In that same continuation response, explicitly state the fast rerun cadence for the active queue, for example: `After each small batch, rerun fast docfx.cs --json and continue.` Do not rely on implicit phrases like "micro-loop" or "packet-by-packet" alone.
- A host may re-enter the skill by invoking `dotnet-docfx-digest` directly with no extra arguments after the first rerun. Treat that no-argument re-entry as the same repo-wide continuation, not as a fresh human checkpoint. If hundreds or thousands of repairable diagnostics remain, they are still the active work queue; keep repairing instead of pausing for approval, review, or scope confirmation.
- Existing Markdown links, `Related:` entries, and historical URL references are documentation evidence. Preserve them during prose rewrites. Remove or replace a URL only after directly verifying that the current destination returns HTTP 404. Timeouts, 403s, rate limits, DNS failures, and other lookup problems are not removal evidence.
- Keep interim artifacts out of the target repository. Assessment queues, project manifests, review reports, captured validator output, progress notes, and one-off helper scripts belong in temp or session storage. If `docfx.cs` reports `INTERIM_ARTIFACT_IN_WORKTREE`, treat those files as blocking cleanup work before completion.
- Namespace/prose-only repairs are latency-sensitive. Prefer direct edits or small sibling batches in the main agent. Use fresh workers only for example-heavy or source-heavy packets. If a prose-focused worker has not produced a concrete diff within about 45 seconds, or it goes quiet after producing its assigned file, inspect the diff, stop delegating that class of work, and continue inline. A quiet or "needs attention" worker is not a stop condition for the overall digest.

- `ENCODING_CORRUPTION` in the JSON output means a documentation file has double-encoded UTF-8 (mojibake). Restore with `git checkout HEAD -- <file>` if the committed version was correct, or use the edit tool or byte-level operations to rewrite the file safely. Never pipe content through `Get-Content` + `Set-Content` or `[System.Text.Encoding]::UTF8.GetBytes()` on documentation files that contain multi-byte characters or emoji.
- `EXTENSION_TABLE_ENCODING` means the ⬇️ emoji (U+2B07) is missing or corrupted in an Extension Members table data row. Use the literal `⬇️` character, not HTML entities or text substitutes.
- `EXTENSION_RECEIVER_MISMATCH` and `EXTENSION_METHOD_SIGNATURE_MISSING` mean the table collapsed the real extension signature. Keep decorated receivers such as `IDecorator<Type>` in the Type column, and keep generic method arity such as `As<T>` or `Configure<TOptions>` in the Methods column instead of flattening them to bare names or wrapped inner types.
- `EXTENSION_METHOD_MISSING` and `EXTENSION_METHOD_SIGNATURE_MISSING` are still namespace-layer repair work. If they appear right after `EXTENSION_SECTION_MISSING` drops, that means the validator can finally inspect table contents; keep repairing `Extension Members` tables across the active queue before resuming net-new type/example authoring.
- If either script cannot run, report the exact command, exit code, and failure output. Do not claim repository guidance or documentation was verified unless the scripts actually ran successfully.
- Treat validator errors as the repo-wide repair queue, not as evidence that the repository is "blocked." A diagnostic being old, pre-existing, numerous, or outside the first files edited does not remove it from scope. A run with 1,228 `EXAMPLE_MISSING` findings means 1,228 documentation items remain; repairing one type page is a partial result, not a digest.
- A rerun that clears a coarse diagnostic and reveals a more specific one is progress, not a blocker. If `EXTENSION_SECTION_MISSING` drops and `EXTENSION_METHOD_MISSING` appears, or namespace/table repairs expose more `EXAMPLE_MISSING` targets, treat the newly surfaced codes as the next deterministic queue and keep repairing.
- Expect queue expansion after structural repairs. Example: `EXTENSION_SECTION_MISSING` can drop from 62 to 13 while `EXTENSION_METHOD_MISSING` jumps from 0 to 157 because the validator can finally inspect table contents. Total counts may rise; that is still progress. Continue repairing the newly exposed queue.
- While `summary.remainingWorkItems` is greater than zero, `summary.canClaimCompletion` is `false`, or `completionState` is not the final clean state, do not emit formatted progress tables, before/after counts, file-count summaries, "remaining work" dashboards, or "Next Steps" lists. The only valid outputs are more repair work, or a genuine external blocker reported with the exact command, exit code, and failure output.
- Do not turn partial progress into a decision menu. While repairable diagnostics remain, never stop to ask whether to continue, focus a subset, or "just run verification." Only ask the user to choose when inspection exposes a real correctness-affecting decision or a genuine external blocker stops further execution.
- `EXAMPLE_MISSING` is the core authoring queue, not optional backlog. Even when it is the only remaining diagnostic family and the count is in the hundreds or thousands, the digest is still incomplete. Do not stop for a checkpoint, completion report, approval pause, dry-run suggestion, or next-step menu; keep creating compiling examples until `EXAMPLE_MISSING` reaches zero.
- Treat the next unaddressed `EXAMPLE_MISSING` diagnostic as the only thing that exists. Work it, rerun, then work the next. Counts, percentages, and "remaining work" numbers are progress indicators, not decision points.
- Use this strict repair order for repo-wide and other full audits: (1) safety, encoding, overwrite-layout, and scope-establishing blockers; (2) a namespace-first pass across the active queue — namespace pages, namespace prose, availability/start-here guidance, embedded-overwrite cleanup, and `Extension Members` tables; (3) once that namespace layer is globally clean or the rerun shows only example-driven work remains, `EXAMPLE_MISSING` plus example-quality and extension-invocation diagnostics, processed packet by packet or namespace by namespace; (4) remaining warnings. Do not start net-new type/example authoring while namespace-layer diagnostics still remain elsewhere in the active queue, except when moving misplaced namespace-embedded examples into type-targeted files is itself the namespace repair.
- Passing compilation is necessary but not sufficient. `EXAMPLE_PLACEHOLDER`, `EXAMPLE_REFLECTION_ONLY`, `EXAMPLE_TARGET_NOT_USED`, `EXTENSION_EXAMPLE_NOT_INVOKED`, `EXAMPLE_DEFAULT_PLACEHOLDER`, `EXAMPLE_NO_OBSERVABLE_OUTCOME`, `EXAMPLE_FORWARDING_SCAFFOLD`, `EXAMPLE_TEMPLATE_REPETITION`, and `EXAMPLE_UID_DUPLICATE` are blocking quality failures. Never satisfy the inventory with `Type.GetType`, assembly metadata inspection, `DocumentedTypeExample`, `DocumentedExtensionExample`, generic `Describe()` helpers, repeated UID sections, prose that merely names the target, a `default!`/`null!` holder property that only parks the type, a class that just constructs or returns the target with no observable result, a mass-forwarding shell of one-line pass-through members, or one normalized code skeleton reused across unrelated types.
- Namespace prose must be decision-useful. `NAMESPACE_PROSE_INVENTORY_ONLY`, `NAMESPACE_APPEND_ONLY_REPAIR`, `NAMESPACE_PROSE_TEMPLATE_REPETITION`, `NAMESPACE_USAGE_GUIDANCE_MISSING`, and `NAMESPACE_START_HERE_MISSING` mean the page still needs a problem/outcome opening, a cohesively rewritten lead instead of a weak inventory sentence with guidance appended below it, an opening written from the namespace's own purpose rather than a shared template, concrete "when to use" guidance, and a named starting API when the namespace has multiple entry points.
- Namespace overview files are single-UID deliverables. `NAMESPACE_EMBEDDED_OVERWRITE_SECTION` means the page mixed namespace guidance with secondary `uid:` / `example:` mappings after the overview, often below `Extension Members`. Move those type/member examples to readable type-targeted files under `.docfx/api/types/`, usually the declaring extension class page, and keep the namespace page limited to the namespace fly-in, availability, related links, and optional `Extension Members` table.
- Use the JSON completion contract as the final authority: completion requires `summary.canClaimCompletion` to be `true`, `summary.remainingWorkItems` to be `0`, `summary.remainingGates` and `summary.remainingDiagnosticsByCode` to be empty, and the build-backed command to succeed. A clean fast run reports `completionState: verification-required`; it is an iteration checkpoint, not completion. Never describe `status: failed`, `completionState: incomplete`, or `completionState: verification-required` as completed work.
- When you defer completion, name the exact endgame command `--build-api-model --validate-samples --verify-docfx-build` and the final JSON completion contract (`summary.canClaimCompletion = true`, `summary.remainingWorkItems = 0`, empty `summary.remainingGates`, empty `summary.remainingDiagnosticsByCode`). Do not replace that with generic "verify later" language.
- Treat that sentence as mandatory even in short follow-up replies that only explain the next queue. A compact response is fine; omitting the explicit completion gate is not.
- Continue documentation repair when `dotnet test` fails for an unrelated environmental dependency such as an unavailable database. Report that test failure separately. It is a blocker only if it prevents the documentation validator, source inspection, or required sample compilation from running.
- Valid BOM-less UTF-8 is compliant. The validator must not emit `ENCODING_BOM_MISSING` (that diagnostic is intentionally unsupported), and an audit must not add/remove BOMs or normalize line endings solely for consistency. BOM presence has no documentation value; preserve the file's existing state and continue detecting actual `ENCODING_CORRUPTION` and `EXTENSION_TABLE_ENCODING` damage.
- Final verification uses adaptive execution. In `auto`, machines with more than 8 available logical processors and more than 32 GiB available memory select `high-capacity`: DocFX verification runs concurrently in its isolated temp copy while the main lane builds/discovers API and then compiles samples, and MSBuild worker counts scale up to half the available processors (capped at 16). Smaller machines select `conservative` and keep the phases sequential with low worker counts. Override with `--execution-profile conservative|high-capacity` or `DOCFX_DIGEST_EXECUTION_PROFILE`.
- Child processes time out after 30 minutes by default, configurable with `--process-timeout-minutes` or `DOCFX_DIGEST_PROCESS_TIMEOUT_MINUTES`. Set the host/tool command timeout at least five minutes higher (35 minutes for the default) so the validator can kill a timed-out child and return a deterministic diagnostic instead of being terminated by the caller first.
- Long-running API builds, sample compilation, and DocFX verification write progress to `stderr`: an initial `[ ]` line, a heartbeat every 10 seconds, and a final `[✓]` or `[x]` line. Heartbeats name the active phase, workload size, runner count, PID, elapsed time, time since the child last produced output, and its latest output line when available. Do not suppress `stderr` during interactive runs; `--json` remains a single parseable document on `stdout`.
- When reporting adaptive execution, include the selected profile, processor and memory inputs, build/sample worker counts, timeout, concurrent/sequential choice, process counts, and phase timings from JSON. State that sample compilation follows API discovery because scoped references depend on the namespace-to-project map. Name CLI and environment overrides for profile, worker counts, and timeout when the user asks how to tune the run.
- When reporting heartbeat behavior, state the complete contract: append-only `stderr`, no cursor-rewritten table, start and 10-second heartbeat events, final success/failure marker for all three long phases, latest non-empty child-output line when available, and plain redirected-log markers that do not depend on ANSI color. When reporting encoding safety, explicitly confirm the diff contains neither BOM-only nor line-ending-only changes.
- Read `references/workflow.md` when you need the detailed targeted/audit workflows, namespace and example templates, the verification checklist, or the completion response shape.
- Prefer bounded project packets over one repository-sized authoring context. Discover packets with `docfx.cs --json` (`scope.packets`) or persist them with `--project-manifest <path>`; process one packet at a time while keeping the user's requested scope unchanged. For repo-wide or other full authoring runs, create or refresh a reflection-backed manifest with `--build-api-model --project-manifest <path>` before the first new example or overwrite rewrite and treat that packet set as the active queue. Repair packet-local diagnostics before moving on when practical. If one diagnostic remains difficult after concrete attempts, record it, continue independent packets, and return to it; never turn one repairable packet failure into a reason to stop a full-repository run. When `summary.scopeState` is `provisional` and `BUILD_BACKED_SCOPE_REQUIRED` fires, the source-scan inventory may drive markdown triage only; it must not authorize a full authoring run.
- If a fast `--project-manifest` or `scope.packets` result contains unnamed packets, zero projects, or `metadataGroup: unknown`, that is a provisional source-scan artifact. Immediately rerun packet discovery with `--build-api-model --project-manifest <temp-path>` (or use generated DocFX YAML) and continue from the reflection-backed packet set. Do not treat weak fast-packet metadata as a blocker or as justification to stop.
- If build-backed packet discovery still fails or remains unusable, fall back to sequential repair instead of stopping. Use the assessment work queue order or namespace-first order: clear namespace-layer diagnostics first, then work the remaining `EXAMPLE_MISSING` diagnostics in namespace order, rerunning the fast validator after each small batch.
- A rerun that leaves `EXAMPLE_MISSING` high while surfacing `EXTENSION_METHOD_MISSING` or `EXTENSION_METHOD_SIGNATURE_MISSING` is still in the namespace-first phase, not the example-only phase. Finish those table repairs first, rerun fast validation, and only then return to the example micro-loop.
- Repository size, target count, diagnostic volume, context pressure, and model usage limits never change the user's requested scope. An explicit or default repo-wide run continues across every packet until the global completion contract is clean.
- Context limits, queue size, and estimates like "this would take multiple sessions" are internal execution concerns, not user-facing stop conditions. Break the work into packets and keep going until the completion contract is clean unless the user explicitly pauses or a real external blocker prevents further progress.
- Final build-backed verification (`--build-api-model --validate-samples --verify-docfx-build`) is for claiming completion, not for blocking incremental progress. While `summary.remainingWorkItems` is greater than zero or any diagnostics remain, stay on the fast `docfx.cs --json` loop and keep authoring.
- Dry run is a voluntary mode used only when the user explicitly asks for `dry-run`, a representative sample, or a quality pilot. Never infer it from repository size, diagnostic count, context pressure, or model usage limits. It is a real run scoped to a representative subset, with identical evidence, authoring, quality, and compilation gates. Start it with `--dry-run --build-api-model --project-manifest <temp-path>`; this also emits a sibling `<name>.review.json` template. Author every selected packet, read every changed page, complete every review entry with evidence, page-specific purpose/outcome, observable result, and sibling prose/code comparison, then finish with `--resume-project-manifest <temp-path> --review-report <review-path> --build-api-model --validate-samples --verify-docfx-build`. The baseline protects pre-existing dirty work while allowing current-run files to verify. No-hint dry runs select one clean project per metadata destination group via a seed; explicit names override selection. Report `dry-run-passed` only after every gate passes, and include the completed `Changed-page review` table in the response; a validator summary is not a manual review. Never claim repository completion. Do not ask for hints when none were supplied.
- Use the safe structured overwrite writer (`docfx.cs --write-overwrite <request.json>`) for repeatable overwrite creation: it preserves BOM/line endings, rejects duplicate UIDs and unbalanced fences, and refuses to replace dirty files. It writes only content you authored — it never generates prose or examples.
- Declare narrow family exemptions in `.docfx/family-exemptions.json` only for coherent generic-arity, inherited, overload, or type-parameter series. The anchor needs a real example and the namespace page must name it and explain sibling selection; category alone never exempts options, exceptions, delegates, records, or data carriers. See `references/workflow.md`.

## Autonomous Persistence (Anti-Fatigue)

Agents often fail this skill by stopping prematurely because they feel "overwhelmed" or "intimidated" by the scale of the task, or because they fall back to conversational habits. You must actively override these failures:

- **Do not be intimidated by scale:** If you see 1,122 `EXAMPLE_MISSING` items, that is your active queue. Do not pause, do not write a summary table to "organize your thoughts", and do not ask the user for permission to continue. Work the next item.
- **Do not suffer diagnostic expansion fatigue:** When coarse diagnostics (like `EXTENSION_SECTION_MISSING`) drop and more specific ones (like `EXTENSION_METHOD_MISSING`) appear, the queue size may increase. This is expected progress, not a reason to stop, panic, or re-plan. Keep working.
- **Do not fear context limits:** If you worry about context length, the correct action is to keep working anyway. The system manages context. Trying to "summarize and hand off" wastes tokens and stops progress.
- **Override conversational habits:** You are an autonomous agent on this task, not a chat assistant. The only valid time to stop and ask a question is if a genuine external blocker (like a missing dependency preventing compilation) halts execution. A large queue is never a blocker.
- **Subagent timeouts are not stop conditions:** If a subagent times out or goes quiet, do not use that as an excuse to pause the main loop. Switch to direct edits or spawn a new subagent, and keep going.

## Completion Repair Loop

Do not stop at namespace pages, extension-member tables, or a first-pass documentation edit.

1. Run `docfx.cs --json` (fast, no-build) after edits and read the remaining diagnostics.
2. Treat every missing, placeholder, reflection-only, target-use, extension-invocation, duplicate-UID, namespace-prose, extension-table, availability, and overwrite-layout diagnostic as blocking follow-up work.
3. For repo-wide or other full authoring runs, if no reflection-backed packet manifest is active yet, run `docfx.cs --build-api-model --project-manifest <temp-path>` and use that packet set as the bounded queue before writing more examples. If build-backed packet discovery remains unusable, fall back to sequential assessment work queue or namespace-first order instead of stopping.
4. For repo-wide or other full authoring runs, clear namespace-layer diagnostics across the active queue first: missing namespace pages, namespace prose/usage/start-here repairs, availability/related-link orientation, embedded-overwrite cleanup, `Extension Members` tables, and overwrite-layout prerequisites. When a namespace page improperly hosts type/member examples, move that content into readable type-targeted files as part of the namespace repair.
5. Once the namespace layer is globally clean or the fast rerun shows only example-driven work remains, create or update type-targeting overwrite files under `.docfx/api/types/` for missing public concrete-type examples.
6. For each missing extension-method example, document it on the declaring extension class page or another readable type-targeted overwrite file under `.docfx/api/types/`, and explicitly demonstrate the method call. Do not append secondary `uid:` / `example:` blocks to the namespace page.
7. Treat the next `EXAMPLE_MISSING` diagnostic as the current task. Read the target's public API surface and one relevant test or usage source, write a consumer-facing example to the correct type-targeted overwrite file, rerun the fast validator, then move to the next diagnostic.
8. Use small internal batches (for example 3-5 examples) only to decide when to rerun the fast validator. After each rerun, continue immediately with the next batch. A batch boundary is never permission to emit a progress report, completion summary, or stop menu while diagnostics remain.
9. In any continuation response after a rerun, explicitly state all three of these items: (a) the active queue source — reflection-backed packet manifest, or sequential assessment-work-queue / namespace-first order if the manifest is still unusable; (b) the fast rerun cadence — `docfx.cs --json` after each small batch; and (c) the eventual endgame command `docfx.cs --build-api-model --validate-samples --verify-docfx-build --json` plus the clean completion contract (`summary.canClaimCompletion = true`, `summary.remainingWorkItems = 0`, empty `summary.remainingGates`, empty `summary.remainingDiagnosticsByCode`). Generic "packet-by-packet" or "verify later" wording is insufficient.
10. When only `EXAMPLE_MISSING` remains, that is still the main digest work, not a checkpoint. Keep authoring type and extension examples packet by packet; do not replace the queue with a completion summary, progress report, user choice menu, or final verification pass.
11. Rerun the fast validator until the required diagnostics are gone, then run the build-backed completion verification (`docfx.cs --build-api-model --validate-samples --verify-docfx-build`) to surface `SAMPLE_COMPILE_FAILED` and reflection-precise API gaps; resolve those too and rerun until the JSON completion contract is clean.
12. Do not convert repairable diagnostics into a blocker report. A stubborn diagnostic is a debugging task: inspect the complete implicated UID/path set, validator normalization, source evidence, and related examples; fix either the content or a proven validator defect, then rerun. Continue unrelated packets while investigating when doing so preserves quality. Stop incomplete only when the user pauses the task or a genuine external condition prevents further execution; report the exact command, exit code, and blocker without claiming completion.

Namespace pages and `Extension Members` tables complement type-page examples; they do not replace them. Both namespace pages (`api/namespaces/`) and type pages (`api/types/`) are required deliverables. Generating only one is incomplete work.

### Restarting Partial Audits

When continuing after another agent stopped with diagnostics remaining:

1. Inspect `git status --short --untracked-files=all`, enumerate the stated counts and paths, and preserve every existing tracked and untracked documentation edit, not only the newly created namespace/type files. Do not collapse a concrete inventory such as “8 namespace pages and 1 type page” into a generic promise to preserve work.
2. Rerun the fast validator with `--json --assessment-queue <temp-path>` and read the generated queue.
3. Use the assessment work queue and example inventory as the active queue. Finish the namespace-layer repairs across all affected namespaces first, then return to type pages, extension classes, and extension methods.
4. If no reflection-backed packet manifest is active yet, write one with `--build-api-model --project-manifest <temp-path>` before more example authoring and use it as the bounded queue. If the build-backed packet set is still unusable, fall back to sequential example repair in assessment work queue or namespace-first order.
5. If only `EXAMPLE_MISSING` remains, keep going. That queue is not a stopping point.
6. Repair small batches, rerun the fast validator after each batch so the queue measurably shrinks, and continue immediately. Do not stop after a representative subset, and do not emit progress tables, remaining-work dashboards, or next-step lists while repairable diagnostics remain.
7. If the host re-enters by invoking `dotnet-docfx-digest` directly with no extra arguments, treat that as a continuation of the same repo-wide run. Do not reset to scoping questions, review menus, or approval prompts just because the host surfaced the skill name again.
8. In the next response after each rerun, explicitly name the active queue source (reflection-backed packet manifest, or sequential assessment-work-queue / namespace-first order if the manifest still is not usable), the fast rerun cadence (`docfx.cs --json` after each small batch), and the final endgame command `docfx.cs --build-api-model --validate-samples --verify-docfx-build --json` plus the clean completion contract (`summary.canClaimCompletion = true`, `summary.remainingWorkItems = 0`, empty `summary.remainingGates`, empty `summary.remainingDiagnosticsByCode`). Do not rely on generic "packet-by-packet" or "verify later" wording.
9. Run the exact final command `docfx.cs --build-api-model --validate-samples --verify-docfx-build --json` only when you are ready to claim completion, and continue until the completion contract is clean.
10. If a rerun replaces one diagnostic family with a more specific follow-on family, keep going. Do not convert that newly exposed queue into a progress summary or a request for approval to continue.

## Core Principles

Documentation is part of the public contract. When public .NET API changes, update the corresponding XML comments, DocFX overwrite content, namespace pages, examples, availability notes, and verification steps in the same change set.

Document only what the code actually exposes. Do not invent APIs, overloads, target frameworks, behaviors, exceptions, or examples. Verify claims against source code, generated metadata, project files, tests, or existing documentation.

Manual documentation is authoritative context. Preserve hand-written Markdown and overwrite content unless it is stale or incorrect. Prefer additive edits, but fix contradictions instead of appending conflicting prose.

Preserve working Markdown links, `Related:` references, and historical URL citations unless you verified a direct HTTP 404 at the current destination or have a confirmed replacement URL. Timeouts, 403s, rate limits, DNS failures, and other lookup problems are not removal evidence. Do not drop those references just because you rewrote the surrounding prose.

Namespace pages and type pages have different jobs. Namespace pages orient readers to the problem space and where to start; generated type pages explain concrete public APIs and must carry concrete examples for public non-abstraction types.

Write with an inverted-pyramid structure. Lead with the problem solved, explain when to use the API, give a short “start here” cue when helpful, then add structural detail.

## Safety Gates

Before editing documentation:

1. Run `git status --short` and identify modified, staged, and untracked documentation files.
2. Treat existing uncommitted documentation changes as user work.
3. Read each Markdown file before editing it.
4. Classify any cleanup candidate as generated metadata, generated site output, build artifacts, or authored documentation before deleting anything.
5. Choose temp or session-storage paths for assessment queues, manifests, review reports, captured validator output, and helper scripts before generating them. Do not place scratch artifacts in the target repository.

Do not use broad `git restore`, `git checkout --`, `git reset`, or whole-directory recovery commands on documentation source directories. If recovery is needed, recover only the specific generated or accidentally removed file after inspecting `git status` and `git diff`.

After modifications, inspect `git diff` for touched documentation paths and confirm the diff contains only intended changes.

## File Encoding Safety

Use UTF-8 for DocFX documentation, but treat the BOM as optional. DocFX does not need a UTF-8 BOM, and adding or removing one across existing files creates noisy diffs with no documentation value. Preserve each file's existing BOM and line-ending state unless the user explicitly requests normalization.

- **Never use an encoding-ambiguous `Get-Content` / `Set-Content` round-trip.** Legacy Windows PowerShell can interpret BOM-less UTF-8 through an ANSI code page. Multi-byte UTF-8 sequences, including ⬇️ in `Extension Members` tables, can become mojibake even though the original file was valid.
- **Prefer the `edit` tool** for all Markdown content edits; it preserves bytes correctly and avoids encoding round-trip issues entirely.
- **Check `git status` before any encoding-rewriting operation.** If bytes are corrupted and the file was committed, `git checkout HEAD -- <file>` restores the committed version — but discards any uncommitted in-flight changes. Do not use that recovery if there are unsaved edits.
- **Do not normalize encoding or line endings as part of a documentation audit.** A BOM-only or line-ending-only diff obscures substantive work. The validator reports actual corruption such as `ENCODING_CORRUPTION`; it does not report BOM absence.

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

Run `agents.cs` against the actual repository root being documented, not a temp workspace or the skill install directory. The script manages a marker-bounded DocFX maintenance block in the repository root `AGENTS.md`; do not hand-edit or duplicate that block. After running the script, explicitly read the repository root `AGENTS.md` to load those documentation rules into your context before proceeding.

When examples or workflows say `<temp-path>`, resolve that path outside the repository root (for example, under `$env:TEMP` on Windows or `/tmp` on Unix) so scratch artifacts never pollute the target worktree.

## Required Documentation Surfaces

When public API is added or materially changed, update every relevant surface:

1. XML documentation comments in source code.
2. Namespace overview pages for namespaces that contain public API, under `.docfx/api/namespaces/`.
3. `Extension Members` tables for namespaces that expose public extension methods.
4. Type-targeting overwrite content for public non-abstraction types that require examples or richer guidance, under `.docfx/api/types/`.
5. Extension-method examples on the declaring extension class page or another readable type-targeted overwrite file under `.docfx/api/types/`.
6. Availability information.
7. Verification commands or artifacts that prove the documentation remains accurate and buildable.

Namespace pages and type pages are both required deliverables in the same run. Do not generate namespace pages without type pages or vice versa.

Material changes include new or removed public API, signature or nullability changes, behavioral changes, exception changes, changed availability, conditional extension-method availability, deprecation changes, default-value changes, or meaningful lifecycle and thread-safety changes.

## Examples and Overwrites

Every public non-abstraction type and every public extension method needs at least one realistic, copy/paste-ready example. A namespace fly-in or `Extension Members` table alone is not enough.

Prefer scenario examples over isolated constructor or method-call snippets. A strong type-page example shows the documented API inside the workflow a consumer is trying to complete, even when that means including nearby public types, a small local helper type, dependency-injection setup, configuration objects, or a short host entry point. The example should still be compact, but it should carry enough context that a developer can understand why the type exists and how it cooperates with the package.

Before writing examples for a package, identify the package ID or IDs from packable project metadata, `.nuget/*/README.md`, package release notes, `Directory.Packages.props`, or `PackageReference` usage. Search local repository evidence by package ID first, then by namespace/type/member name. When internet or GitHub search is available and the user has not forbidden it, search for the exact package ID and exclude the target repository or treat self-repo hits as lower-priority evidence. Package-ID searches often find real `Program.cs`, `PackageReference`, README, and package-documentation usage that type-name searches miss.

For each repair batch, maintain an evidence ledger in the example inventory: record the exact test, package README, sample, XML comment, or source path inspected and the consumer task derived from it. Do not mark a scenario ready when its evidence cell contains only a type name, generated metadata, or the overwrite file being repaired.

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
- Uses the documented type or invokes the documented extension method inside the C# fence. A target name in prose, comments, or string literals does not count.
- Shows a consumer-visible operation, result, configuration, or next action. Reflection-only discovery and metadata inspection do not count as usage.
- Contains one coherent example mapping per UID. Merge related calls into one scenario instead of repeating `example: *content` sections for the same UID.
- Compiles in a minimal class library verification project referencing the documented assemblies.

Prefer examples derived from existing unit, functional, or integration tests as behavioral evidence, then from package-level usage evidence, samples, README content, and real consumer usage, then from a minimal new example based on actual public behavior. Convert Arrange/Act/Assert test structure into consumer-oriented sample code instead of pasting raw test assertions, mocks, or fixture setup. When the best evidence spells obvious framework calls as `System.*` or `Microsoft.*`, add the matching `using` directives in the final sample so the call site stays focused on the documented API unless qualification is genuinely needed to disambiguate.

For public non-abstraction types, put the example on the generated type page by targeting the type UID in DocFX overwrite content. In Codebelt repositories, keep authored type overwrite Markdown under `.docfx/api/types/`, typically as `.docfx/api/types/{TypeUid}.md`.

For public extension methods, place examples on the declaring extension class page or another readable type-targeted overwrite file under `.docfx/api/types/`. The example must explicitly call the method. When the declaring page introduces an extension container, explain what the caller can do on the receiver and the outcome it enables; do not spend the lead sentence on whether the methods are declared with `this` parameters or C# extension blocks unless a tooling limitation must be called out explicitly. Namespace overview files stay single-UID; do not append secondary `uid:` / `example:` blocks after `Extension Members`.

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

1. Package IDs and package-family context — determine what a consumer installs and search local evidence for the exact package ID before narrowing to individual types.
2. Public API surface and XML documentation comments — establish the supported constructor signatures, method signatures, and types.
3. Existing unit, functional, or integration tests that reference the documented type or member — use as behavioral evidence only; do not copy Arrange/Act/Assert structure, test fixtures, mocks, or test helper patterns into the final example unless the public API is specifically about testing.
4. README, `.nuget/*/README.md`, package documentation, samples, tuning/tooling projects, or existing conceptual docs in the repository.
5. Real consumer usage found by exact package-ID search, preferring repositories other than the target repository when available; use self-repo hits only as package-authored documentation or sample evidence.
6. Implementation source, only when the public surface alone is insufficient to construct a valid calling example.
7. Official upstream documentation when the library wraps an external framework or library.
8. Synthesized examples only when all of the above confirm the full public API shape and the synthesized sample compiles.
9. Omit the example entirely if none of the above yields a compile-valid, consumer-facing example.

Final examples must be consumer-facing, realistic, and compile. They must read like production calling code or Microsoft Learn-style task examples, not test scaffolding, placeholder `Consumer` shells, or one-line smoke tests. Avoid unused locals, `MyNamespace` when a domain-specific namespace is obvious, fake "sample" values that obscure the workflow, examples that instantiate the documented type without showing the result or next step a real caller cares about, and avoidable `System.*` / `Microsoft.*` fully qualified framework references when a normal `using` keeps the code lean.

Compilation-valid metadata scaffolds are still failures. Never generate a family of examples that differs only by UID while calling `Type.GetType`, returning `Type.FullName`, or wrapping the lookup in `DocumentedTypeExample`, `DocumentedExtensionExample`, or `Describe()`. These patterns conceal missing product knowledge instead of teaching the API.

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

The reason is mandatory. Package requirements, "full example needs X", "shows the framework pattern", or missing assembly/transitive/referenced assembly reasons are all rejected — these are authoring or validator-setup problems, not genuine blockers. Prefer making the example compile. Do not claim an example compiles unless the validator actually ran it successfully.

## Namespace and Summary Style

Namespace overview pages must explain what problem the namespace solves, when to use it, and where a newcomer should start. Avoid inventory-only blurbs such as “contains types and extension methods for...”

The opening paragraph should name the developer problem and outcome. The next paragraph should identify a concrete starting type or method and distinguish nearby alternatives. Do not use a type inventory as a substitute for this guidance; tables and generated API lists already provide inventory.

Type and member summaries should explain the API’s job in consumer terms. Prefer purpose-first summaries for entry points, builders, factories, options, and extension methods. When the documented API is an extension container, describe the developer task and the receiver/result in consumer terms rather than foregrounding declaration syntax. Avoid empty labels such as “represents options” or “adds services” unless the rest of the sentence explains the actual outcome enabled.

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

1. Run `agents.cs` and explicitly read the repository root `AGENTS.md` to load current documentation rules.
2. Run the safety gates and inspect existing documentation edits.
3. Inspect the changed public API, affected namespaces, availability inputs, tests, samples, and current overwrite files.
4. Update XML comments, namespace pages, extension-member tables, examples, and availability notes as required.
5. Build an example inventory for required public concrete types and extension methods.
6. Preserve manual edits, inspect `git diff`, run `dotnet build`, run `dotnet test`, run the Completion Repair Loop, then run the build-backed completion verification (`docfx.cs --build-api-model --validate-samples --verify-docfx-build`).

When the user does not name a specific target:

1. Run `agents.cs` and explicitly read the repository root `AGENTS.md` to load current documentation rules.
2. Run the safety gates and inspect repository guidance.
3. Inspect DocFX configuration, overwrite files, tests, samples, and current documentation state.
4. Run `docfx.cs --json`, and for multi-diagnostic output rerun with `--assessment-queue` and use that queue as the work queue.
5. Repair missing namespace pages, extension-member tables, examples, overwrite layout, summaries, and availability notes that can be derived from evidence.
6. Preserve manual edits, inspect `git diff`, run `dotnet build`, run `dotnet test`, run the Completion Repair Loop, then run the build-backed completion verification (`docfx.cs --build-api-model --validate-samples --verify-docfx-build`).

Read `references/workflow.md` before creating new namespace pages, writing type or extension examples, preparing the final verification checklist, or shaping the completion response.

## Reference Files

- `references/workflow.md` — detailed targeted/audit workflows, example inventory shape, templates, verification checklist, and completion response.
- `references/docfx-overwrite-files.md` — overwrite-file model rules, `example: - *content` usage, and Codebelt overwrite layout guidance.
- `references/scripts.md` — exact `agents.cs` and `docfx.cs` commands, arguments, exit codes, diagnostics, and validator behavior.
