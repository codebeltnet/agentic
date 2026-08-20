# testenvironments.json — the configuration contract

Remote testing honors Microsoft's existing [`testenvironments.json`](https://learn.microsoft.com/en-us/visualstudio/test/remote-testing?view=visualstudio) file rather than inventing a competing format. The runner searches for it at the workspace/solution/repository root and then in ancestor directories, or you can point at it explicitly with `--config-path`.

The skill never modifies `testenvironments.json` unless the user explicitly asks.

## Version

Only `version` `"1"` is supported. Any other version is reported (`UNSUPPORTED_VERSION`) instead of guessed.

```json
{
  "version": "1",
  "environments": [
    {
      "name": "dotnet-10",
      "type": "docker",
      "dockerImage": "mcr.microsoft.com/dotnet/sdk:10.0"
    }
  ]
}
```

## Environment properties

The runner recognizes Microsoft's version-1 properties:

| Property | Support | Notes |
|---|---|---|
| `name` | Supported | Unique, user-friendly name shown in listings and selected with `--environment`. |
| `type` | `docker` supported | `wsl` and `ssh` are recognized and reported as unsupported (Docker only for now). Unknown types are reported too. |
| `dockerImage` | Supported | Name/tag of a Docker image. Required for a `docker` environment that does not use `dockerFile`. |
| `dockerFile` | Supported | Path to an existing Dockerfile (relative to the solution/repo root), built into a local image. Never generated. |
| `localRoot` | Honored | Local path projected into the environment. When set, it becomes the source root that is staged. Defaults to the repo/solution root. |
| `wslDistribution` | Reported unsupported | Present only so WSL environments are surfaced, not run. |
| `remoteUri` | Reported unsupported | Present only so SSH environments are surfaced, not run. |

### Docker source rule

Following Microsoft's rule, a `docker` environment must specify **either** `dockerImage` **or** `dockerFile`, never both:

- Both present → `CONFLICTING_DOCKER_SOURCE` and the environment is not usable.
- Neither present → `MISSING_DOCKER_SOURCE`.

### Configured images are deliberate

An explicit `dockerImage` in `testenvironments.json` is intentional repository configuration, so the runner uses it as written (after pulling and resolving its digest) whatever its publisher. Auto-generated environments come from the two recommended publishers instead: `mcr.microsoft.com/dotnet/sdk` for a single .NET major, and `codebeltnet/ubuntu-testrunner` when the repository multi-targets several majors and needs all their runtimes in one image.

### Configured Dockerfiles are honored, never created

If an environment points at `dockerFile`, the runner builds that existing Dockerfile into a local image and runs against it. The skill will **never** create a Dockerfile (or `docker-compose.yml`, `.devcontainer/`, editor config, or other plumbing) to make remote testing work. The distinction is intentional:

```
Existing configured Dockerfile: supported.
Skill-generated Dockerfile:     prohibited.
```

## Authoritative precedence

When `testenvironments.json` exists it is authoritative — the runner does not silently supplement it with Microsoft-derived environments. Resolution precedence is:

1. An environment explicitly named by the user.
2. An applicable Docker environment from `testenvironments.json`.
3. Microsoft-derived environments only when no `testenvironments.json` exists.

If multiple configured Docker environments exist and none is named, the runner lists them and asks for a selection rather than guessing. If exactly one applies, it is used.

## Unsupported environments

WSL/SSH/unknown environments are reported clearly (with the offending type) instead of being silently ignored or converted. Naming an unsupported environment returns an `UnsupportedEnvironment` result, not a "not found".
