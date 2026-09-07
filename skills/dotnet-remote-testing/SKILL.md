---
name: dotnet-remote-testing
description: >
  Use when the user wants to run, list, or plan .NET tests in Docker remote-test environments, including `testenvironments.json` or a requested SDK/container. Do not use to write or refactor tests, create Dockerfiles, use WSL/SSH, or run tests on the host.
compatibility: >
  Requires the .NET 10 SDK or later (`dotnet run --file`), a running Docker daemon, and PowerShell 7+. Zero-config discovery needs network access; a cache enables offline reuse.
---

# .NET Remote Testing

## Do this now

**You were invoked. That is the request. Run the tests.**

Your first action is this command — not a question, not a menu, not a summary of what you could do:

```
dotnet run --file "<skill-root>/scripts/remote-test.cs" -- run --repo-root "<repo-root>"
```

Run it immediately, then report the result. This holds for a bare `/dotnet-remote-testing` with no other words, and for "remote test this repo", "run my tests in Docker", or any equivalent. There is nothing to clarify first: the runner resolves the environment, the target, and the configuration by itself, and it is the *only* thing that decides whether a question is needed.

**Forbidden as a first response:** listing your capabilities; "here are the typical workflows"; offering `list` / `plan` / `run` as choices; asking which project, environment, .NET version, or filter to use; asking for confirmation. If you are about to write "What would you like me to do?", you have already failed — run the command instead.

You may ask a question in exactly one situation: the command exited `16` (`SelectionRequired`), which means a genuine choice remains. Then ask one question listing only the `candidates` it returned, and rerun with `-e <name>`. Every other exit code is an outcome to report, never a question. The full mapping is in [Failure handling](#failure-handling).

Resolve the two placeholders exactly once and reuse them verbatim:

- `<skill-root>` is the directory containing this `SKILL.md`. Build the path from it; do not guess a relative path from the working directory and do not copy `<skill-root>` through literally.
- `<repo-root>` is the workspace/solution root — the current directory unless the developer named another. Always pass it explicitly rather than relying on the process default, and always quote both paths (Windows paths contain backslashes and often spaces).

Prerequisites, and the exact way each one fails:

| Requirement | Why | If missing |
|---|---|---|
| .NET 10 SDK or later | `dotnet run --file` (file-based apps) | The CLI rejects `--file`; report the SDK requirement — do not rewrite the runner into a project |
| Docker, running | Test execution | The runner exits `DockerUnavailable` (`5`); report it, never fall back to the host |
| Network (first run) | Release metadata, image pull | Use `--offline` with `--cache-root` when a cache exists; otherwise exit `15` explains it |

## Why this skill exists

Visual Studio's experimental [Remote Testing](https://learn.microsoft.com/en-us/visualstudio/test/remote-testing?view=visualstudio) promised:

> **Choose a test environment → run tests → see results.**

Everything between those actions — configuration discovery, .NET release discovery, image resolution, source staging, NuGet caching, restore, build, test execution, result collection, cancellation, and cleanup — is infrastructure that belongs *behind* the abstraction. A developer who reached for this skill has already chosen remote testing; handing that choice back as a questionnaire is the friction this skill exists to remove. Do not turn a routine "run my tests in .NET 10" into a Docker tutorial, and never compose ad-hoc `docker run` command lines yourself.

## Architecture: you orchestrate, the runner executes

The bundled .NET file-based program `scripts/remote-test.cs` is the **execution layer**. It is deterministic and self-tested (`--self-test`). You are the **orchestration layer**. Always route execution through it instead of driving Docker directly:

```
dotnet run --file "<skill-root>/scripts/remote-test.cs" -- <command> [options]
```

Commands: `run` (execute restore/build/test in the resolved container — the default action above), `list` (show environments, when the developer asks to *see* them), `plan` (resolve an environment + image and print the execution plan without running, when the developer asks what *would* happen), and `--self-test`. Add `--json` to any command for machine-readable output.

These are your commands, not a menu for the developer. Never present them as options to choose from.

## Critical

- **Never run tests on the host and never silently fall back to local.** If remote testing was requested, tests must execute in the resolved Docker environment. If Docker is unavailable, report that (the runner exits `DockerUnavailable`) — do not run `dotnet test` locally instead.
- **`testenvironments.json` is the configuration contract.** Honor Microsoft's existing version-1 schema. Do not invent a competing format, and do not modify `testenvironments.json` unless explicitly asked.
- **Do not generate container plumbing.** Never create a `Dockerfile`, `docker-compose.yml`/`compose.yml`, `.devcontainer/`, `.vscode/`, `Directory.Build.*`, or throwaway scripts to make remote testing work. Zero-configuration testing uses official Microsoft SDK images directly. An *existing* configured `dockerFile` is honored because it is deliberate repository intent. The runner may derive a cached preparation layer for build tooling the image lacks (see [Build tooling in the image](#build-tooling-in-the-image)) — that happens inside the runner, outside the repository, and is never something you author.
- **Do not hardcode .NET versions.** Supported LTS/STS channels and the current preview channel are discovered from Microsoft's release metadata at runtime. `.NET 10`/`.NET 11` are examples, never constants.
- **Do not modify the repository to make tests pass.** Never edit `global.json`, project files, target frameworks, or test packages. Report incompatibilities instead.
- **Report infrastructure failures as infrastructure, not as failing unit tests.** The runner classifies each phase distinctly; preserve that distinction when you summarize.

## Default action: run the tests

This restates [Do this now](#do-this-now) because it is the rule most often broken. Autonomy is the default, and the runner — not you — decides when a question is unavoidable:

- **Resolution succeeds → run, silently.** A single Docker entry in `testenvironments.json`, a single derived environment, or the derived environment matching the repository's own target frameworks — with the auto-resolved target, `Debug`, and no coverage. No questions, no confirmation, no preflight commentary.
- **`SelectionRequired` (exit `16`) → ask exactly one question.** The runner returns the `candidates` it could not choose between. Present those names and nothing else, then rerun with `-e <name>`.
- **Any other failure → report it.** A resolution or infrastructure failure is an outcome to report, not a question to ask.

Scope, configuration, framework, and coverage are options the developer volunteers — never fields you collect up front. Pass through only what was actually asked for.

## Step 1: Understand intent and inputs

Infer everything you can from the request and the repository, and resolve the workspace/solution root (`--repo-root`, default: current directory). Then go straight to the command. Read `FORMS.md` only when the runner reported `SelectionRequired` or the developer explicitly asked to choose options; it defines *how* to ask, not a checklist to work through.

Typical intents map directly to a command:

| The developer says… | You run… |
|---|---|
| A bare invocation / "remote test this solution" / "run these tests in .NET 10" | `run` |
| "What environments can I test in?" / "list remote environments" | `list` |
| "Show me the plan / which image will you use?" | `plan` |

## Step 2: List and resolve the environment

Resolution is deterministic and follows this precedence, which the runner enforces — do not second-guess it:

1. An environment the user names explicitly (`--environment <name>`).
2. An applicable Docker environment from `testenvironments.json` (authoritative when the file exists — never supplement it with invented environments). A single Docker entry is selected outright.
3. A derived environment when no `testenvironments.json` exists. A single derived environment is selected outright; otherwise the repository's own target frameworks choose one:
   - **One .NET major** → the Microsoft SDK channel matching it.
   - **Several .NET majors** → a Codebelt multi-SDK runner (`codebeltnet/ubuntu-testrunner`, tags like `8-9-10-11`) that provides every one of them.

That third rule is what makes zero-configuration testing unattended: the source already answered the question. The runner reports the choice (`Selected automatically: …`) so an unattended selection stays auditable, and it deliberately does not approximate — no .NET target framework, two channels for the same major, or no runner covering the required set all fall through to a question rather than guessing an SDK the repository never asked for.

### Why multi-targeting needs a different image

A Microsoft SDK image ships exactly **one** runtime: `mcr.microsoft.com/dotnet/sdk:10.0` contains only `Microsoft.NETCore.App 10.0.x`. A repository targeting `net9.0;net10.0` therefore *builds* both there and then fails to execute the `net9.0` tests — there is no .NET 9 runtime in the image. The Codebelt runner carries several SDKs at once, so the whole target-framework matrix runs in a single container instead of one container per TFM.

The runner enforces this rather than leaving it to judgment: pointing a multi-targeted repository at a single-SDK image is reported as `SdkIncompatibility` (`7`) naming the unrunnable frameworks and the remedy. Narrowing the run with `-f/--framework` narrows the environment choice too, so `-f net10.0` on a multi-targeted repository resolves to the ordinary `10` channel.

The runner performs all of this inside `run` itself, so **do not call `list` as a preflight before running**. When a choice genuinely remains, `run` stops with `SelectionRequired` and hands you the `candidates` — present those names concisely and let the developer pick, then rerun with `-e <name>`. Do not guess between them, and do not ask before the runner says a choice is needed.

Use `list` when the developer wants to *see* the environments:

```
dotnet run --file "<skill-root>/scripts/remote-test.cs" -- list --repo-root "<root>"
```

Absence of `testenvironments.json` is **not** an error. In that case the runner derives environments from Microsoft's live release index (`mcr.microsoft.com/dotnet/sdk` images for each supported LTS/STS channel plus the current preview), so no files need to be added to the repository. Environment names look like `dotnet-10-lts`, `dotnet-9-sts`, `dotnet-11-preview`; for a multi-targeted repository a multi-SDK runner named `ubuntu-testrunner-8-9-10-11` is offered alongside them. The exact set comes from live metadata and the publisher's tag feed at runtime — never a hardcoded list.

If the user names a WSL or SSH environment, the runner reports it as unsupported (Docker only for now). Relay that clearly instead of trying to convert it.

## Step 3: Plan when transparency helps

`plan` is for when the developer asks what will happen — not a gate in front of a run they already asked for. Do not insert it before an unambiguous `run`. When it is called for, it resolves the environment, validates the image tag against Microsoft's registry, pre-resolves the immutable digest, inspects target frameworks for SDK compatibility, and prints the deterministic execution plan without touching Docker:

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
- `-f, --framework <tfm>` — restrict a multi-targeted test project to one TFM. This also narrows environment resolution, so the run lands on that TFM's single-SDK channel instead of a multi-SDK runner.
- `--coverage` — collect coverage when the project already supports it (never add packages to enable it).
- `--timeout <seconds>` — abort the run after N seconds; the runner still cleans up.

The runner establishes an isolated staged workspace (so container builds never leave Linux `bin`/`obj` in the working tree), mounts a persistent NuGet cache outside the repository, pins the image to its digest, runs restore → build → test, collects TRX results, and removes all transient Docker resources afterward. You do not manage any of that.

Two diagnostic options exist for when a result needs explaining, not for routine runs:

- `--show-log` — print the container's full restore/build/test log. Use it when the summarized failure detail is not enough, never by default.
- `--no-git-metadata` — skip staging `.git` (see [The staged workspace is still a repository](#the-staged-workspace-is-still-a-repository)). Only for a repository whose `.git` is large enough that copying it dominates the run, and only when the developer accepts the fidelity loss.

### The staged workspace is still a repository

The staged copy includes the repository's `.git` directory. This is not incidental: a .NET build and the code under test both read it.

- MinVer, Nerdbank.GitVersioning and GitInfo derive the assembly version from git history. Without `.git` they silently fall back to `0.0.0`, so the container builds a differently-versioned assembly than the host.
- SourceLink stops embedding repository information.
- Application and test code commonly locates the repository root by walking up until a `.git` directory exists. Without it, that probe resolves somewhere else — and every path derived from it changes.

That last one is why a suite can pass in Visual Studio's remote testing and fail here for reasons that have nothing to do with the container. If a run reports a failure that looks path-dependent, the staged workspace being a real repository is already accounted for; do not "fix" it by editing the repository.

The runner installs `git` into the image when the image lacks it (see [Build tooling in the image](#build-tooling-in-the-image)) — the two halves belong together: the tooling and the metadata it reads.

### Build tooling in the image

The container runs the *build*, not just the tests, and a .NET build routinely shells out to `git` — MinVer, Nerdbank.GitVersioning, GitInfo and SourceLink all do. Microsoft's SDK images ship it; a minimal runner image may not, and the build then fails with `MINVER1007: "git" is not present in PATH` even though nothing is wrong with the code.

The runner handles this: it probes the resolved image and, when the tooling is missing, layers it on in a cached image tagged `dotnet-remote-testing/prepared:git-<base-digest>` — built in the runner's own temp directory, never in the repository, and reused by every later run against the same base image. The reported `Image`/`Digest` stay the base image; preparation is reported on its own `Tools:` line. If it cannot be added (no package manager, `--offline`), the run proceeds on the base image and says so.

Relay that line when present, but do not act on it: it is not a repository problem and never a reason to edit `testenvironments.json`, author a `Dockerfile`, or fall back to the host. A recurring `Added git to the image` for a repository's own image is worth mentioning once — the durable fix belongs in that image, not here.

## Step 5: Report results concisely

Lead with the outcome, not the infrastructure. Mirror the runner's result and suppress pull/restore/build log noise unless something failed. The runner already reports at the granularity `dotnet test` does — one line per test assembly and target framework, then the totals:

```
Remote Test: dotnet-10-lts
Selected automatically: the only environment matching the repository's target framework 'net10.0'.

Image:  mcr.microsoft.com/dotnet/sdk:10.0.302
Digest: sha256:...
SDK:    10.0.302

Passed!  Cuemon.Core.Tests.dll (net10.0)  —  1842 passed, 3 skipped, 0 failed, 21.8 s

Tests:  1842 passed, 3 skipped, 0 failed
Time:   21.8 s (tests)
Total:  96.4 s (including image pull, restore and build)
```

Report both durations as the runner does. `Time` is the test execution time from the TRX; `Total` is wall clock for the whole operation. Collapsing them into one number misrepresents a fast suite behind a slow image pull. When the runner explains an automatic environment selection, relay that line — it is what makes an unattended choice auditable.

When tests fail, relay the runner's failure detail as it stands. It is deliberately shaped like `dotnet test` output — fully-qualified test name, the target framework it failed under, the assertion message, the stack trace and anything the test wrote itself — because that is what makes a red test fixable without a second run:

```
Failed!  Cuemon.Text.Tests.dll (net10.0)  —  110 passed, 0 skipped, 1 failed, 2.0 s
Passed!  Cuemon.Text.Tests.dll (net9.0)   —  111 passed, 0 skipped, 0 failed, 1.9 s

1 test failed:

  Failed Cuemon.Text.Tests.StringUtilityTest.Sanitize_WithUnicode_ReturnsExpectedValue [net10.0] (314 ms)
    Assert.Equal() Failure: Values differ
    Expected: 16
    Actual:   2
    Stack trace:
      at Cuemon.Text.Tests.StringUtilityTest.Sanitize_WithUnicode_ReturnsExpectedValue() in /workspace/test/…/StringUtilityTest.cs:line 321
```

Do not compress this into a bare count. "1 test failed" without the name, the TFM and the message forces the developer to rerun the suite to learn what you already know. Note which target framework failed when a multi-targeted project fails under one TFM and passes under another — that asymmetry is usually the diagnosis. If the detail is still not enough, rerun with `--show-log` rather than guessing.

A run is reproducible in terms of environment, requested image, resolved digest, SDK, architecture, and runner version; include the image and digest so the result can be reproduced.

## Failure handling

**Branch on the exit code, never on the prose.** The exit code is the contract; log text is not. Every outcome maps to exactly one next action, so the same repository produces the same behavior regardless of which model is driving:

| Exit | `failureKind` | What it means | Your next action |
|---:|---|---|---|
| `0` | — | Tests passed | Report the result |
| `1` | `TestFailure` | Real failing tests | Report the failures — this is **not** an infrastructure problem |
| `2` | — | Invalid arguments | Fix your command line; do not report it as a repository problem |
| `3` | `Configuration` | `testenvironments.json` unusable | Report the diagnostic; never repair the file unprompted |
| `4` | `UnsupportedEnvironment` | WSL/SSH environment named | Report Docker-only; never convert it |
| `5` | `DockerUnavailable` | Docker missing or not running | Report it; **never** fall back to the host |
| `6` | `ImageResolution` | Tag/digest/pull failed | Report the image and the registry error |
| `7` | `SdkIncompatibility` | SDK cannot build the target frameworks | Report the reason; never edit the repository to force it |
| `8` | `SourceStaging` | Workspace could not be staged | Report it as infrastructure |
| `9` | `Restore` | `dotnet restore` failed in the container | Report the restore error, not "tests failed" |
| `10` | `Compilation` | Build failed in the container | Report the compiler errors, not "tests failed" |
| `11` | `TestHost` | Test host crashed | Report as infrastructure with the output tail |
| `12` | `ResultProcessing` | Results unreadable | Report it; results are unknown, not passing |
| `13` | `Cleanup` | Transient resources left behind | Report the exact identifiers the runner names |
| `14` | `Cancelled` | Timeout or interrupt | Report how far it got |
| `15` | `ReleaseMetadataUnavailable` | Release index unreachable, no cache | Report it; suggest `--offline --cache-root` or a named environment |
| `16` | `SelectionRequired` | A real choice remains | **Ask one question** from `candidates`, then rerun with `-e <name>` |

`SelectionRequired` is the only exit code that is a question rather than a report. Every other non-zero code is an outcome you relay honestly:

- A container/infrastructure problem (image pull, restore, build, test-host crash) is **not** a failing unit test — say which phase failed.
- If cleanup leaves resources behind, relay the exact resource identifiers the runner reports.
- If Microsoft's release index is unreachable and no cache exists, automatic discovery fails with an explanation; an explicit `testenvironments.json` environment with a resolvable image still works offline.

## What this skill must never do

- Generate a `Dockerfile`, dev container, editor config, or any repository-specific plumbing. (Honor an *existing* configured `dockerFile`; never create one. The runner's own cached preparation layer is not repository plumbing and is not yours to write.)
- Run privileged containers, mount the Docker socket, mount the whole user profile, forward host credentials indiscriminately, disable TLS validation, expose ports, or print secrets. The runner already avoids these; do not add them.
- Answer an invocation with a menu of its own capabilities, a "what would you like me to help you with?" opener, or a confirmation prompt for a run the developer already asked for.
- Reach for an arbitrary image when a recommended one fits. Auto-generated environments use `mcr.microsoft.com/dotnet/sdk` for a single .NET major and `codebeltnet/ubuntu-testrunner` for several; an explicit `dockerImage` in `testenvironments.json` is deliberate intent and is used exactly as written. Other images are permitted but must be a deliberate, stated choice — never a substitution you make on your own.
- Fall back to running tests locally.

## References

Consult these only when you need the detail:

- `references/testenvironments-json.md` — Microsoft's version-1 schema, supported/unsupported properties, and how the runner honors them.
- `references/release-discovery.md` — how supported channels and image tags are derived from Microsoft's release index, plus offline/cache behavior.
- `references/docker-execution.md` — the deterministic execution model: staging, mounts, caching, security posture, lifecycle, and cleanup.
