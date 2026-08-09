---
name: dotnet-remote-testing
description: >
  Run .NET tests inside a resolved remote Docker environment and return structured results — Visual Studio's Remote Testing experience (choose an environment, run tests, see results) without hand-writing container plumbing. Use when asked to remote test, run tests in Docker or a container, run tests against a specific .NET SDK, list or select test environments, or honor an existing testenvironments.json. Honors testenvironments.json Docker environments or derives zero-config environments from Microsoft's live .NET release index (LTS, STS, preview) using official mcr.microsoft.com/dotnet/sdk images via the bundled runner scripts/remote-test.cs. Docker only; WSL and SSH are reported unsupported. Do NOT use to author or refactor test code, choose a testing framework, generate Dockerfiles, or run tests on the host.
compatibility: >
  Requires the .NET SDK, Docker, and PowerShell 7+. Zero-config discovery needs network access to Microsoft's release index and mcr.microsoft.com; a cache enables offline reuse.
---

# .NET Remote Testing

Give developers the experience Visual Studio's experimental [Remote Testing](https://learn.microsoft.com/en-us/visualstudio/test/remote-testing?view=visualstudio) was meant to provide:

> **Choose a test environment → run tests → see results.**

Everything between those two actions — configuration discovery, .NET release discovery, image resolution, source staging, NuGet caching, restore, build, test execution, result collection, cancellation, and cleanup — is infrastructure that belongs *behind* the abstraction. Your job is orchestration: understand what the developer means, then hand the work to the deterministic runner. Do not turn a routine "run my tests in .NET 10" into a Docker tutorial, and never compose ad-hoc `docker run` command lines yourself.

## Architecture: you orchestrate, the runner executes

The bundled .NET file-based program `scripts/remote-test.cs` is the **execution layer**. It is deterministic and self-tested. You are the **orchestration layer**. Always route execution through it instead of driving Docker directly:

```
dotnet run --file "<skill-root>/scripts/remote-test.cs" -- <command> [options]
```

Commands: `list` (show environments), `plan` (resolve an environment + image and print the execution plan without running), `run` (execute restore/build/test in the resolved container), and `--self-test` (built-in deterministic tests). Add `--json` to any command for machine-readable output.

## Critical

- **Never run tests on the host and never silently fall back to local.** If remote testing was requested, tests must execute in the resolved Docker environment. If Docker is unavailable, report that (the runner exits `DockerUnavailable`) — do not run `dotnet test` locally instead.
- **`testenvironments.json` is the configuration contract.** Honor Microsoft's existing version-1 schema. Do not invent a competing format, and do not modify `testenvironments.json` unless explicitly asked.
- **Do not generate container plumbing.** Never create a `Dockerfile`, `docker-compose.yml`/`compose.yml`, `.devcontainer/`, `.vscode/`, `Directory.Build.*`, or throwaway scripts to make remote testing work. Zero-configuration testing uses official Microsoft SDK images directly. An *existing* configured `dockerFile` is honored because it is deliberate repository intent.
- **Do not hardcode .NET versions.** Supported LTS/STS channels and the current preview channel are discovered from Microsoft's release metadata at runtime. `.NET 10`/`.NET 11` are examples, never constants.
- **Do not modify the repository to make tests pass.** Never edit `global.json`, project files, target frameworks, or test packages. Report incompatibilities instead.
- **Report infrastructure failures as infrastructure, not as failing unit tests.** The runner classifies each phase distinctly; preserve that distinction when you summarize.

## Step 1: Understand intent and inputs

Read `FORMS.md` and infer everything you can from the request and repository. Most invocations need no questions at all — "remote test this solution" against a repo with one applicable environment is fully determined. Only ask (one field at a time) when a genuine choice remains, such as which environment when several apply. Resolve the workspace/solution root (`--repo-root`, default: current directory).

Typical intents map directly to a command:

| The developer says… | You run… |
|---|---|
| "What environments can I test in?" / "list remote environments" | `list` |
| "Show me the plan / which image will you use?" | `plan` |
| "Remote test this solution" / "run these tests in .NET 10" | `run` |

## Step 2: List and resolve the environment

Resolution is deterministic and follows this precedence, which the runner enforces — do not second-guess it:

1. An environment the user names explicitly (`--environment <name>`).
2. An applicable Docker environment from `testenvironments.json` (authoritative when the file exists — never supplement it with invented environments).
3. Microsoft-derived environments when no `testenvironments.json` exists.

Run `list` to show the choices. When exactly one applicable Docker environment exists, use it. When several exist and the user has not chosen, present the names concisely and let them pick — do not guess intent:

```
dotnet run --file "<skill-root>/scripts/remote-test.cs" -- list --repo-root "<root>"
```

Absence of `testenvironments.json` is **not** an error. In that case the runner derives environments from Microsoft's live release index (`mcr.microsoft.com/dotnet/sdk` images for each supported LTS/STS channel plus the current preview), so no files need to be added to the repository. Environment names look like `dotnet-10-lts`, `dotnet-9-sts`, `dotnet-11-preview`; the exact set comes from metadata at runtime.

If the user names a WSL or SSH environment, the runner reports it as unsupported (Docker only for now). Relay that clearly instead of trying to convert it.

## Step 3: Plan when transparency helps

Before a long run — or whenever the developer wants to see what will happen — `plan` resolves the environment, validates the image tag against Microsoft's registry, pre-resolves the immutable digest, inspects target frameworks for SDK compatibility, and prints the deterministic execution plan without touching Docker:

```
dotnet run --file "<skill-root>/scripts/remote-test.cs" -- plan --repo-root "<root>" -e <name> [-p <project>] [-c Release] --json
```

Use the plan's `compatibility` result to catch an SDK/target-framework mismatch early. If it is incompatible, report the reason — do not change the repository to force it.

## Step 4: Run the tests

```
dotnet run --file "<skill-root>/scripts/remote-test.cs" -- run --repo-root "<root>" [-e <name>] [options]
```

Common scoping options (pass through only what the developer asked for):

- `-p, --project <path>` — a specific solution or project (relative to the source root). When omitted, the runner resolves a root solution, a single solution, or a single project automatically.
- `--filter <expr>` — a `dotnet test --filter` expression (test class, trait, etc.).
- `--test <fqn>` — shortcut for a fully-qualified-name filter (a single test or class).
- `-c, --configuration <Debug|Release>` — build configuration.
- `-f, --framework <tfm>` — restrict a multi-targeted test project to one TFM.
- `--coverage` — collect coverage when the project already supports it (never add packages to enable it).
- `--timeout <seconds>` — abort the run after N seconds; the runner still cleans up.

The runner establishes an isolated staged workspace (so container builds never leave Linux `bin`/`obj` in the working tree), mounts a persistent NuGet cache outside the repository, pins the image to its digest, runs restore → build → test, collects TRX results, and removes all transient Docker resources afterward. You do not manage any of that.

## Step 5: Report results concisely

Lead with the outcome, not the infrastructure. Mirror the runner's concise result and suppress pull/restore/build log noise unless something failed:

```
Remote Test: dotnet-10-lts

Image:  mcr.microsoft.com/dotnet/sdk:10.0.302
Digest: sha256:...
SDK:    10.0.302

Tests:  1842 passed, 3 skipped, 0 failed
Time:   21.8 s
```

When tests fail, prioritize actionable detail — the failing test, its class, the expected/actual message, and location — over container startup output:

```
3 tests failed

Cuemon.Text.Tests.StringUtilityTest
  Sanitize_WithUnicode_ReturnsExpectedValue
  Expected: ... Actual: ...
```

A run is reproducible in terms of environment, requested image, resolved digest, SDK, architecture, and runner version; include the image and digest so the result can be reproduced.

## Failure handling

The runner distinguishes failure kinds via exit code and the `failureKind` field: `Configuration`, `UnsupportedEnvironment`, `DockerUnavailable`, `ImageResolution`, `SdkIncompatibility`, `SourceStaging`, `Restore`, `Compilation`, `TestHost`, `TestFailure`, `ResultProcessing`, `Cleanup`, `Cancelled`, and `ReleaseMetadataUnavailable`. Report the kind honestly:

- A container/infrastructure problem (image pull, restore, build, test-host crash) is **not** a failing unit test — say which phase failed.
- If cleanup leaves resources behind, relay the exact resource identifiers the runner reports.
- If Microsoft's release index is unreachable and no cache exists, automatic discovery fails with an explanation; an explicit `testenvironments.json` environment with a resolvable image still works offline.

## What this skill must never do

- Generate a `Dockerfile`, dev container, editor config, or any repository-specific plumbing. (Honor an *existing* configured `dockerFile`; never create one.)
- Run privileged containers, mount the Docker socket, mount the whole user profile, forward host credentials indiscriminately, disable TLS validation, expose ports, or print secrets. The runner already avoids these; do not add them.
- Substitute third-party or unofficial images for auto-generated environments (only `mcr.microsoft.com/dotnet/sdk`). An explicit `dockerImage` in `testenvironments.json` is exempt because it is deliberate.
- Fall back to running tests locally.

## References

Consult these only when you need the detail:

- `references/testenvironments-json.md` — Microsoft's version-1 schema, supported/unsupported properties, and how the runner honors them.
- `references/release-discovery.md` — how supported channels and image tags are derived from Microsoft's release index, plus offline/cache behavior.
- `references/docker-execution.md` — the deterministic execution model: staging, mounts, caching, security posture, lifecycle, and cleanup.
