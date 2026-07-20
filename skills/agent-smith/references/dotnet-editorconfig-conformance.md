# .NET EditorConfig conformance

Load this reference only when the user explicitly requests .NET EditorConfig, code-style, informational IDE, named diagnostic, or formatter-supported analyzer conformance or remediation. Do not turn every ordinary .NET implementation into a repository-wide formatting pass.

## Governing contract

Treat every enabled and fixable `.editorconfig` diagnostic within the user-defined scope as enforceable repository policy, even when `dotnet build` does not emit it. Visual Studio can surface informational diagnostics while a build remains clean; the build result does not make those configured findings optional.

`dotnet format` defaults to severity `warn`. For informational diagnostics, informational-or-higher conformance, and any conformance task that does not explicitly set a different minimum, omitting `--severity info` silently changes the verification scope and can produce a false clean result. Treat the explicit severity as part of the scope identity: carry it through discovery, investigation, recovery retries, and final verification without omission. Use `warn` or `error` only when the user explicitly requests that narrower minimum and it does not exclude a requested diagnostic; otherwise stop and resolve the conflict.

Keep these checks distinct:

- `dotnet format ... --verify-no-changes` verifies formatter, code-style, and supported analyzer conformance within the selected scope.
- `dotnet build` verifies compilation and build diagnostics.
- `dotnet test` verifies behavior.

The default completion order is scoped conformance, affected build, relevant tests, then final diff review.

## Record the authoritative scope

Before discovery, state a compact scope record:

- **Mode:** targeted remediation or full conformance.
- **Diagnostics:** the exact requested IDs, or all formatter-supported findings when full conformance was requested without IDs.
- **Target:** the selected solution, solution filter, project, and any included directories or files.
- **Minimum severity:** `info` unless the user explicitly requests a narrower `warn`- or `error`-only scope that does not exclude a requested diagnostic.
- **Validation:** the affected build target and relevant tests.

Resolve scope in this order:

1. Explicit diagnostic IDs.
2. Explicit files, directories, projects, solutions, or solution filters.
3. Explicit severity.
4. Explicit wording requesting full repository or solution conformance.
5. Repository instructions and the established primary build target.
6. Conservative inference from the task.

Explicit diagnostic IDs select targeted mode even when the user says "all occurrences." Do not broaden a request for one or more named IDs into other IDE or CA cleanup, and do not fail that task merely because unrelated findings remain. If no IDs are supplied and the user requests general conformance, use full-conformance mode.

## Resolve the target deterministically

Use the first applicable source of truth:

1. The target explicitly named by the user.
2. The target established by applicable repository instructions.
3. The target used by primary build or test automation.
4. The documented primary solution.
5. The single discoverable `.sln`, `.slnx`, or `.slnf` target.
6. The single discoverable project.

When the user names a directory or file, resolve the solution or project that owns it and carry the path as `--include`; a source file is not itself a `dotnet format` project-or-solution target. Do not select the first search result when multiple plausible targets exist. Inspect build scripts, solution filters, and repository documentation, then ask only if materially different targets remain.

Respect `global.json`, multi-targeting, central build files, `Directory.Packages.props`, nested projects, generated-code conventions, and nested `.editorconfig` precedence. Do not bypass normal SDK selection, restore, dependency, or analyzer configuration.

## Read-only formatter rule

Use `dotnet format` only for discovery, investigation, and verification. Every invocation in this workflow must include:

```text
--verify-no-changes
```

Never invoke it in mutating mode. Make fixes through deliberate source edits that you inspect and understand. Write JSON reports and optional binary logs to a temporary or already-ignored artifact directory; do not commit them unless the user explicitly requests it.

Every invocation must also state the resolved `--severity` explicitly. Do not rely on the formatter default. If `--no-restore` is justified during investigation, add it without removing `--severity`, `--verify-no-changes`, the diagnostic filters, target, includes, or report output; it is a restore switch, not a conformance fallback.

Record the pre-existing Git working-tree state before running discovery. Preserve every user change and distinguish it from files changed for the remediation.

## Canonical PowerShell commands

Adapt quoting and line continuation to the active shell without changing command semantics. Use a temporary report directory outside the working tree where practical.

### One requested diagnostic

Use the category-specific subcommand so a targeted code-style or analyzer task does not silently include unrelated whitespace findings.

For an IDE code-style diagnostic:

```powershell
dotnet format style "<solution-or-project>" `
    --diagnostics "<diagnostic-id>" `
    --severity info `
    --verify-no-changes `
    --report "<temporary-report-directory>"
```

For a CA or third-party analyzer diagnostic:

```powershell
dotnet format analyzers "<solution-or-project>" `
    --diagnostics "<diagnostic-id>" `
    --severity info `
    --verify-no-changes `
    --report "<temporary-report-directory>"
```

### Multiple requested diagnostics

Group the requested IDs by formatter category. Run `dotnet format style` for the exact IDE code-style IDs and `dotnet format analyzers` for the exact CA or third-party analyzer IDs, each with `--severity info`, `--verify-no-changes`, and a separate temporary report directory. Preserve the complete requested diagnostic list across the category commands. Do not replace them with a broad top-level command after editing; top-level `dotnet format` also runs whitespace formatting and can introduce unrelated findings into a targeted task.

### Explicit directory or file scope

```powershell
dotnet format style "<solution-or-project>" `
    --diagnostics "<diagnostic-id>" `
    --include "<relative-path>" `
    --severity info `
    --verify-no-changes `
    --report "<temporary-report-directory>"
```

This example is for an IDE code-style rule; use `dotnet format analyzers` for an analyzer rule. Pass multiple relative paths after `--include` when the user names more than one. Do not invent exclusions or narrow include paths merely to make verification pass.

### Full conformance

```powershell
dotnet format "<solution-or-project>" `
    --severity info `
    --verify-no-changes `
    --report "<temporary-report-directory>"
```

Use this unfiltered diagnostic gate only in full-conformance mode. Retain an explicit `--include` path restriction if the user requested conformance only within named directories or files.

For targeted remediation, `dotnet format style` and `dotnet format analyzers` are the final category-specific gates. For full-conformance mode, they may isolate a category during investigation but do not replace the final broad top-level command. Every invocation must retain the resolved explicit severity and `--verify-no-changes`.

## Interpret results, including non-zero exits

Read both command output and the JSON report. Capture where available:

- diagnostic ID and message;
- source file, line, and column;
- affected project;
- suggested or inferred remediation category.

Group findings by diagnostic, project, and source area. A non-zero exit with `--verify-no-changes` can mean that source changes would be required; that is an ordinary conformance result, not automatically a tooling failure. Conversely, do not assume every non-zero exit represents findings.

Separate conformance findings from restore failures, missing or incompatible SDKs, invalid `global.json`, project or solution load failures, analyzer load failures, inaccessible paths, invalid arguments, unsupported targets, compilation failures required for analyzer execution, and unexpected tool crashes. When needed, increase verbosity or capture `--binarylog` in temporary storage without weakening target, diagnostic, include, or severity scope.

## Multi-targeted project guardrail

A multi-targeted project can expose the same physical source file as multiple Roslyn project documents, so the JSON report may repeat a diagnostic for each target framework.

Before planning edits, de-duplicate findings by normalized physical file path, diagnostic ID, and source span. Treat identical tuples as one logical finding. Retain the affected project and target-framework contexts as evidence, but apply the deliberate correction once to the physical file. Do not count or edit the same physical occurrence once per target framework.

Never invoke `dotnet format` in mutating mode to apply bulk code fixes to a multi-targeted project or solution. Roslyn may be unable to merge overlapping changes from different target-framework project contexts and can insert `Unmerged change from project` conflict annotations into source files.

If a previous mutating formatter invocation already inserted those annotations, stop invoking the formatter and recover before continuing:

1. Record the current working-tree state and inspect the complete diff so pre-existing user changes remain distinguishable.
2. Run the bundled Roslyn multi-project artifact tool in non-mutating check mode. The tool name and detection contract are diagnostic-neutral because the merge failure is not unique to one formatter rule:

   ```powershell
   pwsh -NoProfile -File "<skill-root>/scripts/repair-roslyn-multiproject-artifacts.ps1" -Path "<scoped-source-path>"
   ```

3. Inspect its JSON. Detection is generic: any `Unmerged change from project` signature is an artifact. Automatic repair is handler-based and currently accepts only the `whole-document-namespace-conversion` pattern: one complete current-format Roslyn block whose `Before` branch is block-scoped namespace form, whose partial `After` branch is file-scoped namespace form for the same namespace, and whose partial `After` lines are an exact prefix of the retained complete document. It reports `unsafe` with pattern `unrecognized` and exits `2` for mismatches, legacy comment artifacts, localized conflicts, multiple blocks, or any other unsupported shape.
4. Only when every artifact is `recoverable`, apply the preflighted repair:

   ```powershell
   pwsh -NoProfile -File "<skill-root>/scripts/repair-roslyn-multiproject-artifacts.ps1" -Path "<scoped-source-path>" -Apply
   ```

   Directory application is all-or-nothing at preflight: if any scanned artifact is unsafe, the tool writes no files. It preserves UTF-8 BOM state, uses the formatter-produced complete tail as the source of truth, collapses each proven duplicate once, and ignores `bin` and `obj`.
5. Do not infer recoverability from a diagnostic ID. A new artifact grammar needs its own evidence and deterministic handler before automatic repair is safe. Do not merely delete marker lines while leaving both bodies, and do not use `git reset`, `git checkout`, or `git restore` to erase the working tree. If the tool refuses a file, inspect it deliberately and report a blocker when the intended source cannot be distinguished safely.
6. Re-run the artifact tool; repaired files must now report `clean`. Then re-run the original scoped formatter command with the same target, category, diagnostic filters if any, explicit severity, includes, `--verify-no-changes`, and report path, followed by the artifact gate below. Only proceed to build and tests when all three gates are clean.

After remediation and before build or test validation, run this mandatory artifact gate:

```powershell
git grep -n -F 'Unmerged change from project'
```

Any match is a failed remediation. Correct every artifact deliberately, then re-run both the same scoped read-only formatter verification and this artifact gate before proceeding to build or test validation. Exit code `1` with no output means no tracked match; any other non-zero result is a tooling failure that must be diagnosed rather than reported as a clean gate.

## Remediation loop

1. Record the pre-existing working-tree state.
2. Resolve and state the scope record.
3. Run the matching read-only discovery command.
4. Inspect command output and the JSON report.
5. Group findings, de-duplicate multi-target repeats by physical file path, diagnostic ID, and source span, and inspect representative occurrences before bulk edits.
6. Research unfamiliar or semantically meaningful rules.
7. Apply deliberate edits in small, reviewable groups where practical.
8. Re-run the same scoped read-only command, including the same explicit severity, after each logical group.
9. Continue until it succeeds or a legitimate blocker is established.
10. Run the formatter-conflict artifact gate and correct any matches.
11. Build the affected solution or projects.
12. Run relevant tests.
13. Review the final diff for behavior, scope, accidental churn, policy changes, and preservation of pre-existing work.

Keep the final verification command semantically identical to discovery: same target, diagnostic filters, include paths, minimum severity, and effective SDK environment. Never switch to a narrower verification after making edits.

## Research and semantic safety

Use official Microsoft documentation for `dotnet format`, IDE code-style rules, and CA code-quality rules. When a requested diagnostic is unfamiliar or the transformation can affect semantics:

- `dotnet format`: https://learn.microsoft.com/en-us/dotnet/core/tools/dotnet-format
- Code-style rule index: https://learn.microsoft.com/en-us/dotnet/fundamentals/code-analysis/style-rules/
- Code-quality rule index: https://learn.microsoft.com/en-us/dotnet/fundamentals/code-analysis/quality-rules/

1. Read the individual official rule page.
2. Identify applicable languages and minimum language version.
3. Identify the controlling EditorConfig option when documented.
4. Understand the proposed transformation.
5. Inspect repository conventions, call sites, and tests.
6. Apply only behavior-preserving changes within scope.

For third-party diagnostics, use the analyzer publisher's official documentation. Do not infer a rule from its identifier alone.

Treat each rule as its own source transformation rather than assuming that all formatter-supported fixes are mechanically interchangeable. Confirm the effective option and file context even for style-only rules. When a transformation can affect symbol shape, member modifiers, initialization, control flow, mutability, inheritance, dependency injection, serialization, reflection, documentation, or tests, inspect the relevant declarations, call sites, and behavioral coverage before editing. Preserve public behavior and externally significant contracts. If a configured finding cannot be remediated safely, report the exact blocker instead of weakening policy.

## Generated code and prohibited shortcuts

Generated files normally remain untouched. Determine whether a reported file is intentionally included, identify its generator or source template, correct the template when appropriate, and respect established exclusions. Do not silently rewrite generated output or add a new exclusion only to make verification pass.

Do not resolve findings by:

- changing `.editorconfig`, analyzer configuration, or analyzer packages;
- lowering severity, disabling rules, adding suppressions, or adding `NoWarn`;
- excluding paths, projects, target frameworks, or generated files without explicit scope or repository justification;
- invoking a mutating formatter;
- applying broad unrelated cleanup;
- changing public behavior to satisfy style;
- replacing targeted remediation with full-repository cleanup;
- claiming success from `dotnet build` alone.

Any exception requires an explicit repository requirement or direct user approval.

## Completion and report

A targeted task is complete only when the exact scoped verification succeeds, requested findings are gone within the selected target/path/severity, the formatter-conflict artifact gate is clean, unrelated diagnostics were not silently fixed, affected builds and relevant tests pass, policy was not weakened, unrelated files were not changed, and pre-existing work remains intact. Describe the outcome as:

> All fixable findings considered by `dotnet format` for the requested diagnostic IDs, target, paths, and severity have been remediated.

Do not claim full repository conformance.

A full-conformance task is complete only when the broad verification succeeds at the selected target and severity, the formatter-conflict artifact gate is clean, affected builds and tests pass, policy was not weakened, unrelated files were not changed, and pre-existing work remains intact. Describe the outcome as:

> All fixable findings considered by `dotnet format` at severity `info` or higher for the selected solution or project under its effective analyzer and EditorConfig configuration have been remediated.

Do not promise an exact one-to-one match with the Visual Studio Error List; IDE state, SDK versions, target frameworks, generated files, unsupported fixes, and IDE-only diagnostics can differ.

Report the mode, selected target and path scope, diagnostic IDs if any, minimum severity, initial logical counts by ID after multi-target de-duplication, deliberately changed files, unresolved findings and reasons, exact final verification command, formatter-conflict artifact gate result, build and test results, unrelated findings intentionally left outside scope, and confirmation that no policy configuration, severity, exclusions, or suppressions changed.
