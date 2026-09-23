# Proportional automation

Load for script-runtime choices, reusable tooling, validators, or growing automation. Apply the operating profile from `SKILL.md` first: explicit constraints and established repository or applicable family conventions take precedence over these defaults. This reference does not prescribe the product's implementation language.

## Default decision order

1. Use a simple native command when it fully expresses the operation and preserves diagnostics and exit status.
2. Use PowerShell 7 for small, focused orchestration or scripting. A few tool invocations, path operations, or straightforward JSON transformations rarely justify a program.
3. Use C#/.NET for substantial, reusable, deterministic, complex, or growing automation when structure, type safety, testing, concurrency, cancellation, diagnostics, maintainability, or cross-platform behavior provides meaningful value.

Judge complexity by responsibilities and failure modes, not a line-count threshold. Reuse or determinism alone does not require rewriting a small, sound script. Conversely, a PowerShell, Bash, or Python script that has become an application with scheduling, state, retries, schemas, or multiple subsystems deserves a maintainable .NET design. Explain the concrete benefit and migration cost.

Do not turn a simple native operation into a program to satisfy a language preference. Python is not the default fallback in this .NET-first operating profile. A repository standard, constrained host, vendor SDK, or materially simpler existing tool may justify another language; state the evidence. Do not migrate working automation solely for stylistic uniformity.

## Runtime and implementation

- Inspect SDK pins, target frameworks, script conventions, supported operating systems, and deployment hosts before choosing a runtime.
- When .NET is chosen and compatible repository pins or explicit constraints do not decide the version, resolve the latest supported LTS from [Microsoft's official .NET support policy](https://dotnet.microsoft.com/platform/support/policy/dotnet-core). Do not hardcode a drifting release.
- Prefer a small C# file-based app when the supported SDK and host make it practical; use a minimal project when dependencies or build behavior require one.
- Preserve deterministic output, bounded concurrency, cancellation, actionable diagnostics, and failure exits in every language. In PowerShell, check native command exit codes explicitly when the host does not propagate them.
- Validate actual supported hosts. Cross-platform intent or a successful run on one OS does not prove the required support matrix.
