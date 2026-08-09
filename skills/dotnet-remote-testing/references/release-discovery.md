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

Third-party images, unofficial Docker Hub images, and locally discovered look-alike images are never substituted for auto-generated environments. An explicit `dockerImage` in `testenvironments.json` is the only exception, because it is deliberate configuration.

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

## Offline behavior and caching

Successfully retrieved release metadata is cached outside the repository together with the retrieval timestamp. When Microsoft cannot be reached:

- the most recently validated cache is used, and the result clearly states that cached metadata is in use;
- current release information is never fabricated.

If no authoritative metadata and no valid cache exist, automatic environment discovery fails with a useful explanation. Explicit `testenvironments.json` environments remain usable without release-index discovery whenever their Docker image can be resolved. Pass `--offline` to force cache-only behavior, or `--releases-index-file <path>` to supply metadata from a local file.
