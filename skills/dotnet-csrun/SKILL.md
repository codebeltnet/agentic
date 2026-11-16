---
name: dotnet-csrun
description: >
  Use when creating, verifying, repairing, or auditing C# examples and documentation snippets, running isolated xUnit v3 tests, or reproducing .NET problems without a project. Excludes repository test infrastructure and benchmarks.
---

# Executable C# evidence with csrun

Make the smallest complete example, execute it through `csrun`, and share the exact program that ran. Use .NET/C# for substantive supporting logic and PowerShell 7 for orchestration. Never substitute another execution engine or create a competing manifest format.

## Choose the intention

| Logical command | Authorized behavior |
| --- | --- |
| `create` | Construct a new complete console sample or genuine xUnit v3 test, execute it, and deliver both transports. |
| `verify` | Inspect and execute existing source without editing it; report defects and limitations. |
| `repair` | Establish intent, preserve failure evidence, make the smallest semantics-preserving correction, execute, and deliver both transports. |
| `audit` | Discover and classify examples within the specified scope; read-only unless repair is explicitly requested or already authorized by the parent workflow. |

These are agent intentions, not binary commands or manifest fields. Infer a bare invocation from context: existing source plus “does it work?” means `verify`; a request for a new example means `create`. `audit --fix` authorizes relevant sample repairs, not application refactoring. Do not introduce a command parser, menu, or clarification when intent is clear. Read [existing samples, repair, and audit](references/lifecycle.md) for these operations and [DocFX composition](references/docfx.md) during documentation work.

## Workflow

1. Inspect supplied source, documentation, dependency pins, and repository context. A bare invocation uses that context; proceed when the behavior is clear. Ask only for facts that materially affect correctness. Use `dotnet-test` for repository testing infrastructure, `dotnet-remote-testing` for existing test workloads, and `dotnet-benchmark` for performance experiments.
2. Establish the expected observation before execution: output values, stable invariants, meaningful assertions, or a deliberate failure with its diagnostic and exit status. Choose console mode for observable demonstrations and test mode for assertions. If both are explicitly requested and useful, provide independently executable examples with identical dependency versions and assumptions.
3. Before manifest construction, assess feasibility: **Compatible**, **Adaptable** through a justified semantics-preserving change, **Unsupported** by the current execution model, or **Undetermined** pending inspection/execution. Trivial console programs and ordinary facts proceed directly. Inspect explicit `Main`, top-level test statements, application-entrypoint fixtures, project/assembly dependencies, platform and service prerequisites using [feasibility and recovery](references/feasibility.md). DI and hosting APIs alone are compatible; needing the identity or startup of a separate application assembly is the distinction. Avoid predictable unsupported attempts unless requested or needed for diagnosis; an inconclusive assessment may proceed to execution.
4. Choose the compatible execution path. For `create` or authorized `repair`, write complete source, including imports and an entry point or discoverable public xUnit test class; for `verify`, retain supplied source unchanged. Use async tests returning `Task` when appropriate. Do not simulate assertions or test results with printed messages. Read [manifest construction](references/manifest.md) before constructing the schema version 1 manifest. Verify package versions in repository pins and the package's authoritative published feed; never invent or silently change them.
5. Read [execution environments](references/execution.md). Select the available compatible native or Docker transport; neither requires the other's prerequisites. When both are available, verify both where practical, especially for quoting, Unicode, and transport parity. Preserve the requested framework. If neither can execute it, name the concrete missing prerequisites and deliver both runnable templates as **Unverified**. Never silently retarget, install a different engine, or fabricate output.
6. Execute the exact manifest through the actual engine. Capture stdout, stderr, exit code immediately, framework, SDK/runtime environment, engine identity, and package pins. For console examples compare actual output with the declared expectation. For tests require positive discovery/execution evidence, meaningful assertions, and matching MTP status; exit zero alone is insufficient. Zero tests is never a passing test run.
7. Classify the cause before repair: example-owned defect, environment problem, execution-model limitation, or insufficient evidence. Preserve diagnostics; edit only when repair is authorized, then rerun every changed example. A `verify` request never becomes a silent edit. Preserve source/framework for environment problems; explain model limitations and investigate uncertain package behavior before concluding unsupported. A deliberate negative is verified only when both the expected failure diagnostics and exit status match; describe the test itself as failing.
8. Follow [presentation and evidence](references/presentation.md): every compatible completed sample includes **two fully self-contained PowerShell blocks**, native and disposable Docker, generated from one canonical manifest. Use [artifact helpers](scripts/sample-tools.ps1) to prevent drift. Report each transport's verification status independently. Derive separately displayed C# from the manifest source; never publish a verification claim for different code.

**Never make a sample pass by changing what it was supposed to prove.** Preserve supplied code when explaining limitations. Distinguish exact behavior, semantics-preserving adaptation, reduced demonstration, and alternative behavior; only the first two support the original verification claim. Removing `Main`, selecting a startup object, replacing an entrypoint fixture with a manually built host, or switching to console mode is not an equivalent repair without evidence.

## Evidence classification

| Classification | Required evidence |
| --- | --- |
| Verified | Exact example executed with declared runtime/dependencies; actual observations match expectations. |
| Compiled only | Compilation succeeded but requested runtime behavior was not exercised. |
| Unverified | Execution blocked, unavailable, or not performed. |
| Failed | Execution occurred and observations did not match expectations. |

Feasibility and execution evidence are separate. Unsupported preflight means **Unverified**, with the unavailable capability and recovery path. An attempted CS0017 build is **Failed** execution, not proof of an API defect, failed assertion, or the original application's correctness/incorrectness. Model confidence is never evidence. Published-package execution proves that exact package version, not unpublished checkout changes. An isolated example does not establish application integration correctness. Keep prior unexpected failures visible even after a repaired example succeeds.

## Full developer journey

For “show a runnable .NET 10 example that prints 42”, construct the canonical manifest below. Generate both complete execution blocks using [presentation](references/presentation.md), execute the available transports, and compare output with the expected `42`. This construction is a maintainer example, not the two developer deliverables.

```powershell
$manifest = @{
    schemaVersion = 1
    mode = 'console'
    framework = 'net10.0'
    source = @'
using System;
Console.WriteLine(42);
'@
} | ConvertTo-Json -Depth 8
```

For tests, use the [passing fixture](evals/files/passing.json) as a small source reference, not a replacement test engine. The fixtures also cover deliberate failures, no discovered tests, invalid source, exact packages, and Unicode/raw strings. Repository maintainers can run `scripts/validate-dotnet-csrun.ps1` for deterministic artifact checks; optional engine execution is documented in [verification](references/verification.md).
