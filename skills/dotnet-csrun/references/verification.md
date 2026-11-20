# Maintainer verification

From the agentic repository root, `pwsh -NoProfile -File scripts/validate-dotnet-csrun.ps1` uses the existing file-based application build cache to run the C# artifact validator, then the PowerShell sample-tool regressions. It checks fixture intent, serialization preservation, resource links, published-source parity, semantics-preserving repair pairs, generated blocks and source/manifest identities. These offline checks neither validate the engine schema nor execute C#. Repository metadata validation discovers eval specifications and fixtures. The Templates suite also runs the sample-tool regressions.

Optional focused integration: `pwsh -NoProfile -File scripts/validate-dotnet-csrun.ps1 -EnginePath <trusted-local-csrun.ps1>` or `-Docker`. These execute fifteen cases through the actual engine, preserve separate stdout/stderr, canonical manifests, both generated blocks, source/manifest hashes, engine and SDK/runtime identity, expected observations and exit status under a unique OS temporary directory. Positive cases execute the generated copy/paste block in a fresh PowerShell process; negative cases call the engine directly to retain the original compiler/MTP status. No engine download is automated. Docker uses :10 for .NET 10 and :11 for .NET 11. Expected failures are engine observations, not passing tests. This maintainer validator needs an SDK for its C# artifact checks; developer-facing Docker blocks and the offline PowerShell helper tests do not need a host SDK. Network access and genuine selected-transport prerequisites remain necessary for integration.

The eval specification includes representative user tasks covering native-only, Docker-only, both/neither available, repair, partial excerpts, semantic rejection, wrapper divergence, scoped audit, unpublished-project composition and repository-backed handoff. Inspect these deterministically; model-backed execution is not a validator or completion gate. Follow portable handoff rules only when explicitly asked for an evaluation. Full repository validation requires separate approval; focused checks suffice here.

The transport-double tests execute generated blocks in independent scopes with the opposite transport made unavailable; these prove invocation/manifest independence, not C# behavior. Actual engine runs prove observed behavior. Template generation with neither environment does not invent a successful status. Editing tests compare entire resulting byte arrays for UTF-8 with/without BOM and UTF-16 little/big endian with BOM and CRLF, preserving unrelated Markdown, frontmatter, links, directives and partial fences; stale edits fail without changing bytes. The original InventoryWorker hash and repair-pair source comparisons prevent manufactured semantic success. Instruction/activation/effectiveness claims remain unmeasured without separately authorized behavioral evaluation.

## Observed implementation verification, 2026-11-16

All seven fixtures matched expected observations on native Windows (installed SDK 11.0.100, .NET 10.0.15/11.0.0 runtimes) and official Linux Docker images. Both transports used released engine v0.2.1, SHA256 `6609acb7ac9df5cbbbf70d58b3dbc40f2d242e34831f89c7b42d7069015db802`. The inspected upstream commit was `1e96747d26b68eea81483ecc7eefe1fdd4c34b18`.

| Fixture | Observed result on both transports |
| --- | --- |
| console | 42; exit 0 |
| passing | total 1, succeeded 1, failed/skipped 0; exit 0 |
| failing | Assert.Equal failure, expected 42 / actual 41; exit 2 |
| empty | no discovered tests; exit 8 |
| invalid | CS0103 for missingValue; exit 1 |
| package | Cuemon.Kernel@11.0.0 DateSpan prints 273; exit 0 |
| unicode | Quotes, æøå 世界, and two source lines preserved; exit 0 |

Docker :10 used SDK 10.0.404 with observed RepoDigest `sha256:98d937e36e9221f352fa960ca8906560a33422b1519bc3c5f25942438cef1b81`; :11 used SDK 11.0.100 with RepoDigest `sha256:88f4f061ef93e8439ecc392f712a0a90c1a2c2a44d2553b300eeb836043ac968`. These are recorded observations, not promises about future mutable tags. The artifact validator also rejected a temporary copy whose console result was changed to 43. No model-backed activation or paired effectiveness measurement was performed.

## Feasibility regression verification, 2026-11-16

Focused Docker execution of all eleven fixtures passed with released engine v0.2.1 (same SHA256 above); :10 reported SDK 10.0.404. The original seven observations remain unchanged. New standalone-host and the then-corrected safe-adaptation fixtures each executed one test, succeeded one, failed/skipped zero, exit 0. The fixture split now retains the missing import in `safe-adaptation.json` as the eval input and its exact correction in `safe-adaptation-corrected.json`; this does not change the historical observation of the corrected source. The unchanged inventory-worker and multiple-entrypoints fixtures each produced CS0017 and exit 1 before test execution. These last two are expected compiler-failure observations, not passing xUnit tests and not verification of the application's behavior. The artifact validator locks the original InventoryWorker source identity and regression manifest fields, targets and pins. The eval specifications cover genuine application startup, compatible hosting, multiple entrypoints, safe import adaptation, false repairs, local project limitations and top-level test source. They are review specifications, not measured agent effectiveness.

## Lifecycle verification, 2026-11-17

All fifteen focused cases matched their expected observations independently on native Windows and Linux Docker with engine v0.2.1 (same engine hash and container digests recorded above). Native used SDK 11.0.100 with .NET 10.0.15/11.0.0 runtimes; Docker :10/:11 used SDKs 10.0.404/11.0.100. All corresponding source/manifest identities and exit statuses matched across transports. Positive cases ran the generated complete blocks in fresh PowerShell processes. Separate stdout/stderr, canonical manifests, both blocks and environment/evidence JSON remain in the run's unique OS temporary directories.

| Repair pair | Before | After, same intended behavior |
| --- | --- | --- |
| Missing Xunit import | CS0246, exit 1 | Added import; one succeeded test, zero failed/skipped, exit 0 |
| Misspelled exact package ID | NU1101, exit 1 | Cuemon.Kernel@11.0.0; unchanged source prints 273, exit 0 |
| Complete Markdown sample missing semicolon | CS1002, exit 1 | Localized semicolon; prints 1970, exit 0; partial fence retained |

The original InventoryWorker still produces CS0017 before discovery; application startup remains unverified. Eighty-four offline artifact/helper assertions and all forty-two Templates checks passed. No full repository matrix, model-backed behavioral evaluation, activation measurement, or skill-effectiveness comparison was run. The independent transport runs used bounded concurrency of two; source mutations and final installation synchronization stayed sequential.

## One-shot refinement verification, 2026-11-17

The [published standalone host example](standalone-example.md) ran as complete independent native and Docker PowerShell blocks: each exited 0 with total 1, succeeded 1, failed/skipped 0. The displayed C# and both embedded manifests match `standalone-host.json`, including Codebelt.Extensions.Xunit.App 13.0.0 and xunit.v3 4.0.3. Engine v0.2.1/hash and Docker :10 digest match the observations above; native used SDK 11.0.100 with .NET 10 runtime, Docker used SDK 10.0.404. Complete console and arithmetic-test blocks were also rerun successfully on both transports. Published-source/manifest/dependency/block parity now has focused deterministic helper coverage.

Separately, DocFX's pinned codebeltnet/xunit repository-backed commands executed the original Bootstrapper minimal worker test successfully on native and official SDK Docker. This verifies that maintained integration test through its actual project graph; it does not make the merged InventoryWorker manifest runnable or establish that its different source executed. No schema or engine change, model-backed evaluation or trigger-effectiveness measurement occurred.
