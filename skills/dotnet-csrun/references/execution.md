# One manifest, two transports

Check Docker daemon availability, selected image SDK/runtime inventory, and engine labels before promising execution. [Docker documentation](https://hub.docker.com/r/codebeltnet/csrun) and [upstream container guidance](https://github.com/codebeltnet/csrun#disposable-container-execution) describe official images. Registry tags inspected on 2026-11-16 include `10`, `11`, and `10-11`; these identify environments, not engine releases.

| Target | Suitable environment |
| --- | --- |
| net10.0 | :10 or :10-11 |
| net11.0 | :11 or :10-11 |
| Omitted framework | Engine's supported GA LTS default; currently net10.0. :11 alone cannot supply its runtime. |
| Windows-specific code | Compatible native Windows environment; Linux images cannot establish Windows behavior. |

Never fix a mismatch by changing the target. The engine validates support against Microsoft's release metadata; unavailable metadata and a stale/missing cache can block execution. It installs no SDKs and performs no implicit runtime roll-forward.

Use `$OutputEncoding = [System.Text.UTF8Encoding]::new($false)` before piping the JSON string to `docker run --rm -i codebeltnet/csrun:10`. No TTY, clone, bind mount, host .NET SDK, or persistent generated files is required. PowerShell 7 and Docker with Linux containers suffice. Metadata and uncached NuGet restores need network access.

Record `docker image inspect codebeltnet/csrun:10 --format '{{json .Config.Labels}}'` and `docker image inspect codebeltnet/csrun:10 --format '{{json .RepoDigests}}'` where reproducibility matters. Tags are mutable and cached images persist until updated. A registry-confirmed digest pin improves identity; never invent one. Engine release/hash labels and SDK/runtime inventories are separate identities. Use `docker run --rm --entrypoint dotnet codebeltnet/csrun:10 --list-sdks` and `--list-runtimes` to inspect them.

For justified tighter isolation, retain executable temporary storage: `docker run --rm -i --read-only --tmpfs /tmp:rw,exec,nosuid,nodev,size=1g,mode=1777 --cap-drop=ALL --security-opt=no-new-privileges --cpus=2 --memory=2g --pids-limit=256 codebeltnet/csrun:10`. Adjust resource bounds transparently. Do not add `noexec` to build storage. Docker is not a hardened hostile-code service: dependencies/build assets, outbound access, resource exhaustion, and daemon vulnerabilities remain trust concerns. Decline ordinary execution of high-risk unknown source when isolation is inadequate. Never automatically forward credentials/environment, mount the Docker socket or arbitrary host directories, add privileges, or run third-party setup scripts.

## Native alternative

Prefer a previously obtained, reviewed local engine: `& ./csrun.ps1 -ManifestJson $manifest`. Native execution requires PowerShell 7 and the appropriate installed SDK/runtime; applicable `global.json` can influence SDK selection. When a remote option is useful, explain that downloading and running the publisher's script and C#/NuGet build inputs grants them the developer's permissions. It is not sandboxed.

```powershell
& ([scriptblock]::Create((irm 'https://github.com/codebeltnet/csrun/releases/latest/download/csrun.ps1'))) -ManifestJson $manifest
$code = $LASTEXITCODE
if ($code -ne 0) { throw "csrun execution failed with exit code $code." }
```

This replaces only the transport line in a complete manifest block. Do not use `irm | iex` to pass parameters. Latest is mutable; retain a trusted release asset/hash for stronger reproduction. No global tool, template, or new CLI is required.

A compatible SDK/container cannot fix a source topology that needs separate application and test assemblies. Distinguish this execution-model limitation from environment prerequisites using [feasibility and recovery](feasibility.md); preserve source and framework in either diagnosis.
