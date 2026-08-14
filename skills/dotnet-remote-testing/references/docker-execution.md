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
```

This preparation layer is:

- **outside the repository** — the Dockerfile is written into the run's own temporary directory, never into the working tree, so the "never generate container plumbing" rule is intact;
- **content-addressed and cached** — tagged `dotnet-remote-testing/prepared:git-<base-digest>`, so it is built once per base image and reused by every later run (`Reused prepared image providing git.`);
- **transparent** — the reported `Image`/`Digest` remain the resolved base image (reproducibility identity), with the preparation reported separately;
- **best effort** — if the tooling cannot be added (no package manager, `--offline`, no network), the base image is used anyway and the reason is reported, because a repository that never invokes `git` runs fine without it.

`.git` itself is not staged into the workspace. Version-deriving tools therefore fall back to their default version (MinVer: `0.0.0-alpha.0`, a warning) instead of failing, which is the right trade for a test run.

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

The runner parses every TRX in `/results` (multi-targeted projects emit one per TFM) into a single structured result: passed, skipped, failed counts, duration, and actionable failure detail (test name, class, message, location). It prioritizes machine-readable results and suppresses pull/restore/build noise on success.

Failures are classified into distinct kinds so a container/infrastructure problem is never misreported as a failing unit test: `Configuration`, `UnsupportedEnvironment`, `DockerUnavailable`, `ImageResolution`, `SdkIncompatibility`, `SourceStaging`, `Restore`, `Compilation`, `TestHost`, `TestFailure`, `ResultProcessing`, `Cleanup`, `Cancelled`, `ReleaseMetadataUnavailable`. A non-zero `dotnet test` exit with a TRX containing failures is a `TestFailure`; a non-zero exit with no failing results (crash, no discovered tests, missing adapter) is a `TestHost` failure.

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
