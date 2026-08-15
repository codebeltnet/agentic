# Deterministic Docker execution model

The runner (`scripts/remote-test.cs`) owns the entire container lifecycle so remote testing stays reproducible and never leaks infrastructure concerns to the caller. The AI orchestration layer never composes `docker run` commands directly.

## Lifecycle

Every `run` follows the same deterministic sequence:

1. Validate Docker availability. If unavailable, exit `DockerUnavailable` — never fall back to the host.
2. Resolve the environment (configured or Microsoft-derived).
3. Resolve the image and pin it to an immutable digest.
4. Ensure the image carries the build tooling (see [Image preparation](#image-preparation)).
5. Establish an isolated, disposable staged workspace.
6. Prepare deterministic mounts and caches.
7. Execute restore → build → test.
8. Collect structured results (TRX).
9. Clean up transient resources.

Cleanup is mandatory after success, test failure, build failure, restore failure, cancellation, and exceptions. If cleanup fails, the exact remaining Docker resource identifiers are reported.

## Repository isolation

Container execution must not pollute or mutate the developer's working tree. The runner stages the source (respecting `localRoot`) into an isolated temporary workspace and mounts *that*, so container builds write Linux `bin`/`obj` into the disposable copy — never next to the developer's native Windows build outputs. When the source is a git repository, staging enumerates tracked and untracked-but-not-ignored files so ignored build artifacts stay out of the staged copy.

The runner never creates `Dockerfile`, `docker-compose.yml`/`compose.yml`, `.devcontainer/`, `.vscode/`, `Directory.Build.*`, temporary scripts, or generated test configuration in the repository.

## Image preparation

The container runs the *build*, not only the tests, and a .NET build routinely shells out to host tooling: MinVer, Nerdbank.GitVersioning, GitInfo and SourceLink all invoke `git` during build. An image without it fails the build — MinVer reports `MINVER1007: "git" is not present in PATH` — even though the code is perfectly fine, which surfaces a missing tool as if it were a repository problem.

Microsoft's SDK images ship `git`; a minimal runner image may not. So after the image is resolved and pinned, the runner probes it (`command -v git`) and, when the tooling is missing, derives a single layer from the resolved base:

```dockerfile
FROM <resolved base image>
USER root
RUN … install git with whichever package manager the base image ships (apt-get / apk / microdnf / dnf / yum)
USER <the base image's configured user, when it sets one>
```

This preparation layer is:

- **outside the repository** — the Dockerfile is written into the run's own temporary directory, never into the working tree, so the "never generate container plumbing" rule is intact;
- **content-addressed and cached** — tagged `dotnet-remote-testing/prepared:git-<base-digest>`, so it is built once per base image and reused by every later run (`Reused prepared image providing git.`);
- **transparent** — the reported `Image`/`Digest` remain the resolved base image (reproducibility identity), with the preparation reported separately;
- **identity-preserving** — installing packages needs root, but the image's own `USER` is restored afterwards, so a base image that runs as a non-root user keeps doing so and file ownership and permission-sensitive tests behave as they do in the configured image;
- **best effort** — if the tooling cannot be added (no package manager, `--offline`, no network), the base image is used anyway and the reason is reported, because a repository that never invokes `git` runs fine without it.

## Git metadata in the workspace

The repository's `.git` directory is copied into the staged workspace alongside the source. The copy is disposable, so the container may write to it freely; the developer's real repository is never mounted and never touched.

This matters because staging the source without its git metadata is not a neutral omission — it changes observable build and test behavior:

| Consumer | Without `.git` |
|---|---|
| MinVer / Nerdbank.GitVersioning / GitInfo | Silently fall back to `0.0.0`, so the container builds differently-versioned assemblies than the host |
| SourceLink | Stops embedding repository information |
| Repository-root probes (`walk up until a .git directory exists`) | Resolve to a different directory, changing every path derived from them — including paths the tests under it read |

The third row is the subtle one: a suite that passes under Visual Studio's Remote Testing and fails here, for reasons unrelated to the container, is very often a repository-root probe landing somewhere else. Installing `git` into the image (above) and staging `.git` are two halves of one guarantee: the build tooling is present *and* the metadata it reads is present.

A linked worktree or submodule stores `.git` as a `gitdir: <path>` pointer file; the runner resolves the pointer and stages the real directory, because the path it names does not exist inside the container. A linked worktree's git directory is only half a repository — it holds per-worktree state (`HEAD`, `index`, logs) and points at a shared `commondir` that holds the objects, refs and config — so the runner stages the shared half first, layers the per-worktree files over it, and drops the `commondir`/`gitdir` pointers. The staged copy is then an ordinary standalone repository, which is what git-based versioning and SourceLink need; staging the near half alone would leave a git directory git cannot read, and versioning would fall back to `0.0.0` exactly as if `.git` had been skipped. A source tree with no git metadata at all stages normally and silently — that is an ordinary case, not a degraded one.

`--no-git-metadata` opts out for a repository whose `.git` is large enough that copying it dominates the run. The run then reports the fidelity loss rather than hiding it.

## Mounts

Three bind mounts, nothing more:

| Mount | Container path | Purpose | Persists? |
|---|---|---|---|
| Staged workspace | `/workspace` | Disposable copy of the source under test | No (removed after the run) |
| NuGet cache | `/nuget` | Persistent package cache owned outside the repository | Yes |
| Results | `/results` | TRX output read back by the host | No (removed after the run) |

The dependency cache (`/nuget`, via `NUGET_PACKAGES`) is deliberately separated from the per-execution build/test workspace: the immutable, reusable dependency cache may persist for fast feedback, while the build/test workspace is isolated per execution so results never depend on stale source. `NUGET_PACKAGES` is exported with a trailing slash (`/nuget/`) because NuGet's package root becomes an MSBuild `SourceRoot`, and SourceLink fails the build on a `SourceRoot` that does not end in a separator.

## In-container phases

The entrypoint runs three ordered phases and emits a machine-readable marker with each phase's exit code:

```
dotnet restore <target>
dotnet build   <target> -c <config> --no-restore
dotnet test    <target> -c <config> --no-build [--filter …] [--framework …] [--collect "XPlat Code Coverage"] --results-directory /results --logger trx
```

`restore` and `build` stop the run on failure; `test` always runs to completion so a TRX is produced even when tests fail. The runner works with the repository's configured .NET testing infrastructure; it does not install or alter test packages, and it does not assume a single testing framework.

## Test scope

Supported through options that pass straight into the phases: entire solution, a project, an individual test or class (`--test`/`--filter`), configuration (`--configuration`), a single TFM of a multi-targeted project (`--framework`), and coverage (`--coverage`, only when the project already supports it).

## Result collection and classification

The runner parses every TRX in `/results` into a single structured result, at the granularity `dotnet test` itself reports:

- **Per test assembly and target framework** — a multi-targeted project emits one TRX per TFM, and the assembly path recorded in the TRX is the only thing that distinguishes them. Each becomes its own `Passed!`/`Failed!` line with its own counts and duration, so a failure is attributable to one test project under one TFM instead of a pooled total.
- **Aggregate counts and duration** across every assembly.
- **Per failing test**: fully-qualified name, owning class, target framework, elapsed time, assertion message, stack trace, and anything the test wrote to its own output helper. Detail is capped (15 failures, 10 stack frames, 15 output lines) so a wholesale failure stays readable; `--json` always carries the complete set.

Pull/restore/build noise is suppressed on success. `--show-log` prints the container log in full when the summarized detail is not enough.

Failures are classified into distinct kinds so a container/infrastructure problem is never misreported as a failing unit test: `Configuration`, `UnsupportedEnvironment`, `DockerUnavailable`, `ImageResolution`, `SdkIncompatibility`, `SourceStaging`, `Restore`, `Compilation`, `TestHost`, `TestFailure`, `ResultProcessing`, `Cleanup`, `Cancelled`, `ReleaseMetadataUnavailable`. A non-zero `dotnet test` exit with a TRX containing failures is a `TestFailure`; a non-zero exit with no failing results (crash, no discovered tests, missing adapter) is a `TestHost` failure.

Each phase emits a machine-readable end marker, so the log between two markers is exactly that phase's output. An infrastructure failure is reported with *its own* phase's log rather than a tail of everything — a build failure names the offending file and compiler error instead of trailing test-runner chatter. Any failing tests already recorded in a TRX are reported first even when the phase failed for another reason, so an assertion failure followed by a test-host crash does not disappear behind the crash.

## Cancellation and cleanup

The container is given a deterministic, knowable name so it can always be targeted for cleanup — even after Ctrl+C or a `--timeout`. On cancellation the runner force-removes the container and deletes the staged workspace and results directory; the persistent NuGet cache and any cached preparation image are kept — both are reusable assets, not leftovers. `docker run --rm` also auto-removes the container on normal completion.

## Security posture

The runner deliberately avoids risky Docker practices and the orchestration layer must not add them:

- no privileged containers (`--privileged`);
- the Docker socket is never mounted into the test container;
- the whole user profile is never mounted;
- host credentials are not forwarded indiscriminately;
- TLS validation is never disabled;
- no ports are published;
- NuGet credentials are not leaked and secrets are not printed.

Private package-source authentication, when needed, must use an explicit and ephemeral mechanism; host credentials are never assumed to be injectable into containers.
