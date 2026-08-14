# .NET release discovery and image selection

When no `testenvironments.json` exists, remote testing provides a zero-configuration experience built exclusively on official Microsoft .NET SDK container images. The available channels are discovered from Microsoft's authoritative release metadata at runtime — never hardcoded.

## Source of truth

The runner fetches and parses Microsoft's release index:

```
https://raw.githubusercontent.com/dotnet/core/refs/heads/main/release-notes/releases-index.json
```

It uses the explicit lifecycle fields rather than any assumption about version numbers. Never encode patterns such as "even versions are LTS", "odd versions are STS", or "highest version is preview" — those are not the contract.

Relevant fields per channel: `channel-version`, `latest-release`, `latest-release-date`, `latest-runtime`, `latest-sdk`, `support-phase`, `release-type`, and `eol-date`.

## Which channels become environments

- **Supported stable channels** — `support-phase` is not `eol` and not `preview`, and `release-type` is `lts` or `sts`. These become environments named `dotnet-<major>-lts` or `dotnet-<major>-sts`.
- **Current preview channel** — `support-phase` is `preview` (or `go-live`). This becomes `dotnet-<major>-preview`.
- **EOL channels are excluded** entirely.

The exact set is whatever the metadata says today. When .NET 12, 13, or later eventually occupy these roles, they are discovered automatically with no skill change. `.NET 10`/`.NET 11` in any example are illustrative only.

## Image selection

Auto-generated environments always use Microsoft's official SDK repository:

```
mcr.microsoft.com/dotnet/sdk
```

The runner prefers an **exact SDK-version image tag** derived from `latest-sdk` over a moving channel tag, so an execution pins to a specific SDK:

- Stable: `latest-sdk` `10.0.302` → tag `10.0.302`.
- Preview: `latest-sdk` `11.0.100-preview.6.26359.118` → tag `11.0.100-preview.6` (build metadata is stripped because Microsoft's preview image tags do not include it).

Because a version string does not always transform mechanically into a valid tag, the selected tag is validated against Microsoft's official SDK image metadata (the `mcr.microsoft.com` registry) before execution. If the exact tag is unavailable, the channel tag (`10.0`) is tried as a fallback candidate.

Auto-generated environments use one of the two recommended publishers — `mcr.microsoft.com/dotnet/sdk` for a single .NET major, or `codebeltnet/ubuntu-testrunner` when several majors must be present at once (see below). Other images are not forbidden, but they are never substituted on the runner's own initiative: an image outside those two comes from an explicit `dockerImage` in `testenvironments.json`, which is deliberate configuration and is used as written. `plan` reports `image.recommendedPublisher` so the provenance of any image is visible.

## Multi-SDK runners for multi-targeted repositories

A Microsoft SDK image contains exactly one runtime. `mcr.microsoft.com/dotnet/sdk:10.0` provides `Microsoft.NETCore.App 10.0.x` and nothing else, so a repository targeting `net9.0;net10.0` compiles both target frameworks there and then cannot execute the `net9.0` tests. Building is not running.

`codebeltnet/ubuntu-testrunner` publishes combined tags carrying several SDKs — `8-9-10-11` provides .NET 8, 9, 10 and 11 in a single image — so the whole target-framework matrix runs in one container rather than one container per TFM.

- Tags are discovered at runtime from the publisher's tag feed (`https://hub.docker.com/v2/repositories/codebeltnet/ubuntu-testrunner/tags`), cached outside the repository like release metadata, and overridable with `--multi-sdk-tags-file` for offline or deterministic runs.
- Only the **major-only combined form** (`8-9-10-11`) is used. Single-major tags are already covered by Microsoft's images, and pinned combination forms move with each patch.
- The **tightest covering tag wins**: the fewest extra SDKs that still provide every required major, breaking ties on the tag name so resolution is stable.
- A multi-SDK environment declares its majors explicitly, and compatibility is judged on that list rather than on a single SDK version.
- Pointing a multi-targeted repository at a single-SDK image is reported as an SDK incompatibility naming the unrunnable target frameworks and the remedy, instead of starting a run that cannot finish.
- `--framework` narrows the environment choice as well as the run, so restricting to one TFM resolves the ordinary single-SDK channel.

## Immutable image identity

A tag is a convenient selector but not an immutable identity. For every execution the runner:

1. resolves/pulls the requested image,
2. determines its immutable image digest,
3. executes against that resolved identity, and
4. reports both the human-readable image/tag and the resolved digest.

The image identity never changes mid-execution, so a result is reproducible in terms of environment, requested image, resolved digest, .NET SDK, architecture, and runner version.

## Target-framework awareness

The runner inspects the solution/projects being tested and will not select an SDK that cannot build the requested target framework:

- A channel SDK builds its own major and every lower one; it cannot build a newer runtime major.
- A Linux .NET SDK container cannot build .NET Framework (`net4x`) targets.
- An existing `global.json` pin is respected (never modified). If the repository requires an SDK that no supported Microsoft image can satisfy, the incompatibility is reported.

Multi-targeted projects are accounted for. The runner never edits `global.json`, project files, or target frameworks to make remote testing succeed.

### Target frameworks also resolve the environment

Compatibility is not the only use of this inspection. When several environments are derived and the caller named no environment, the repository's own target frameworks select one outright, so zero-configuration testing runs unattended instead of stopping to ask which .NET to use.

- **One .NET major** → the derived channel matching it exactly.
- **Several .NET majors** → the multi-SDK runner providing all of them, because every runtime must be present for the tests to execute.

The rule is exact-match by design and never approximates:

| Repository targets | Available | Outcome |
|---|---|---|
| `net10.0` | channels 8, 9, 10, 11-preview | `dotnet-10-lts` selected automatically |
| `net11.0` | channels 8, 9, 10, 11-preview | `dotnet-11-preview` selected |
| `net9.0;net10.0` | channels + runner tags `9-10`, `8-9-10-11` | `ubuntu-testrunner-9-10` selected (tightest cover) |
| `net8.0;net10.0` | channels + runner tag `8-9-10-11` | `ubuntu-testrunner-8-9-10-11` selected |
| `net9.0;net10.0` with `-f net10.0` | channels 8, 9, 10, 11-preview | `dotnet-10-lts` — the run was narrowed to one TFM |
| `net8.0;net10.0` | no covering runner tag | `SelectionRequired` — never a single-SDK image that cannot run both |
| `net7.0` (EOL) | channels 8, 9, 10, 11-preview | `SelectionRequired` — no matching channel |
| `netstandard2.0` only | channels 8, 9, 10, 11-preview | `SelectionRequired` — no .NET target to match |
| `net10.0` | two channels for major 10 | `SelectionRequired` — the match is not unique |

The selection is reported in both human and JSON output (`environment.selectionReason`) so an unattended choice remains auditable. This applies only to derived environments; a `testenvironments.json` with several Docker entries is deliberate developer intent and always asks.

## Offline behavior and caching

Successfully retrieved release metadata is cached outside the repository together with the retrieval timestamp. When Microsoft cannot be reached:

- the most recently validated cache is used, and the result clearly states that cached metadata is in use;
- current release information is never fabricated.

If no authoritative metadata and no valid cache exist, automatic environment discovery fails with a useful explanation. Explicit `testenvironments.json` environments remain usable without release-index discovery whenever their Docker image can be resolved. Pass `--offline` to force cache-only behavior, or `--releases-index-file <path>` to supply metadata from a local file.
