---
name: dotnet-csrun
description: >
  Use when creating runnable C# examples, verifying documentation snippets or API behavior, turning snippets into isolated xUnit tests, or reproducing .NET problems without a project. Excludes repository test infrastructure, integration suites, and benchmarks.
---

# Executable C# evidence with csrun

Make the smallest complete example, execute it through `csrun`, and share the exact program that ran. Use .NET/C# for substantive supporting logic and PowerShell 7 for orchestration. Never substitute another execution engine or create a competing manifest format.

## Workflow

1. Inspect supplied source, documentation, dependency pins, and repository context. A bare invocation uses that context; proceed when the behavior is clear. Ask only for facts that materially affect correctness. Use `dotnet-test` for repository testing infrastructure, `dotnet-remote-testing` for existing test workloads, and `dotnet-benchmark` for performance experiments.
2. Establish the expected observation before execution: output values, stable invariants, meaningful assertions, or a deliberate failure with its diagnostic and exit status. Choose console mode for observable demonstrations and test mode for assertions. If both are explicitly requested and useful, provide independently executable examples with identical dependency versions and assumptions.
3. Before manifest construction, assess feasibility: **Compatible**, **Adaptable** through a justified semantics-preserving change, **Unsupported** by the current execution model, or **Undetermined** pending inspection/execution. Trivial console programs and ordinary facts proceed directly. Inspect explicit `Main`, top-level test statements, application-entrypoint fixtures, project/assembly dependencies, platform and service prerequisites using [feasibility and recovery](references/feasibility.md). DI and hosting APIs alone are compatible; needing the identity or startup of a separate application assembly is the distinction. Avoid predictable unsupported attempts unless requested or needed for diagnosis; an inconclusive assessment may proceed to execution.
4. Choose the compatible execution path, then write complete source, including imports and an entry point or discoverable public xUnit test class. Use async tests returning `Task` when appropriate. Do not simulate assertions or test results with printed messages. Read [manifest construction](references/manifest.md) before constructing the schema version 1 manifest. Verify package versions in repository pins and the package's authoritative published feed; never invent or silently change them.
5. Read [execution environments](references/execution.md). Prefer official disposable Docker execution when available and appropriate; native execution is first class. Preserve the requested framework and choose a compatible environment explicitly. If neither environment can execute it, name the concrete missing prerequisite and deliver an **Unverified** example. Never silently retarget, install a different engine, or fabricate output.
6. Execute the exact manifest through the actual engine. Capture stdout, stderr, exit code immediately, framework, SDK/runtime environment, engine identity, and package pins. For console examples compare actual output with the declared expectation. For tests require positive discovery/execution evidence, meaningful assertions, and matching MTP status; exit zero alone is insufficient. Zero tests is never a passing test run.
7. Classify the cause before repair: example-owned defect, environment problem, execution-model limitation, or insufficient evidence. Preserve diagnostics; repair justified example-owned causes and rerun every changed example. Preserve source/framework for environment problems; explain model limitations and investigate uncertain package behavior before concluding unsupported. A deliberate negative is verified only when both the expected failure diagnostics and exit status match; describe the test itself as failing.
8. Follow [presentation and evidence](references/presentation.md): deliver one readable PowerShell Copy & Run block where practical, then concise actual evidence and necessary caveats. Publish the same source that was executed. If showing C# separately, derive it from the manifest's source instead of maintaining a second variation.

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

For “show a runnable .NET 10 example that prints 42”, construct and execute this block, check the actual output and exit status, then share it. The output described here is an expectation until execution establishes it.

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

$OutputEncoding = [System.Text.UTF8Encoding]::new($false)
$manifest | docker run --rm -i codebeltnet/csrun:10
$code = $LASTEXITCODE
if ($code -ne 0) { throw "csrun execution failed with exit code $code." }
```

For tests, use the [passing fixture](evals/files/passing.json) as a small source reference, not a replacement test engine. The fixtures also cover deliberate failures, no discovered tests, invalid source, exact packages, and Unicode/raw strings. Repository maintainers can run `scripts/validate-dotnet-csrun.ps1` for deterministic artifact checks; optional engine execution is documented in [verification](references/verification.md).
