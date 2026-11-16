# Maintainer verification

From the agentic repository root, `pwsh -NoProfile -File scripts/validate-dotnet-csrun.ps1` uses the existing file-based application build cache to run the C# artifact validator. It checks fixture intent, serialization preservation, resource links, and published-source parity. It neither validates the engine schema nor executes source. Repository metadata validation automatically discovers this skill's eval specification and fixture paths.

Optional focused integration: `pwsh -NoProfile -File scripts/validate-dotnet-csrun.ps1 -EnginePath <trusted-local-csrun.ps1>` or `-Docker`. These execute eleven fixtures through the actual engine, preserve output and manifest hashes under a unique OS temporary directory, and fail on mismatched status or observations. No engine download is automated. Docker uses :10 for .NET 10 and :11 for the .NET 11 package example. Run both transports to check parity when available. Expected failures are assertions about engine observations, not passing tests. Network access and genuine SDK/runtime prerequisites remain necessary.

The eval specification includes sixteen representative user tasks. Inspect these deterministically; model-backed eval execution is not part of this validator or a completion gate. Follow repository portable handoff rules only when explicitly asked for an evaluation. Full repository validation requires separate approval; focused checks suffice here.

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

Focused Docker execution of all eleven fixtures passed with released engine v0.2.1 (same SHA256 above); :10 reported SDK 10.0.404. The original seven observations remain unchanged. New standalone-host and safe-adaptation fixtures each executed one test, succeeded one, failed/skipped zero, exit 0. The unchanged inventory-worker and multiple-entrypoints fixtures each produced CS0017 and exit 1 before test execution. These last two are expected compiler-failure observations, not passing xUnit tests and not verification of the application's behavior. The artifact validator locks the original InventoryWorker source identity and the four new fixtures' manifest fields, targets and pins. The new eval specifications cover genuine application startup, compatible hosting, multiple entrypoints, safe import adaptation, false repairs, local project limitations and top-level test source. They are review specifications, not measured agent effectiveness.
