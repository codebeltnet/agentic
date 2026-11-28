# Generated run actions (opt-in)

The logical command `dotnet-docfx-digest csrun` covers the active DocFX repository in one skill invocation. Resolve the loaded skill directory and start with the deterministic generator:

```powershell
pwsh -NoProfile -File <skill-dir>/scripts/generate-run-actions.ps1 -RepoRoot <repository> [-Docfx <docfx.json>] [--uid <uid-or-uid#ordinal> ...]
```

The command uses `docfx.cs --run-action-inventory`, sharing discovery from `build.content`/`build.overwrite`, fence extraction, UID ownership, Roslyn AST classification, type/assembly ownership resolution, and source-context validation with compilation. It generates `run-actions.manifest.json` atomically (temp file + rename, preserving the previous manifest whenever a verification run fails before completion) and syncs the self-contained deterministic materializer `BuildRunActions.ps1` beside `docfx.json`, without physically creating `run-actions/` in the working tree. When a `BuildDocfxImage.ps1` exists beside `docfx.json`, the generator also wires `& (Join-Path $PSScriptRoot 'BuildRunActions.ps1')` before `try { docker buildx build ... }` and removes the generated `run-actions` directory in `finally`, updating uncustomized scripts into the standard `try`/`finally` shape and surgically patching customized scripts around their Docker build step without breaking existing customizations. A small HTML association immediately follows the unchanged C# fence. Every fence has a stable `exampleId` including its 1-based per-UID fence ordinal (`<uid>#<ordinal>`, for example `My.Namespace.ServiceCollectionExtensions#2`) persisted across inventory, manifest entries, and recipes, alongside its 24-hex asset slug `id`. Owned associations and manifest entries are replaced when their source changes or disappears. Keep `run-actions.settings.json`, `run-actions.manifest.json`, `BuildRunActions.ps1`, the Markdown associations, `docfx.json`, and the generated template assets as committed documentation source; ignore the build-time `run-actions/` directory in `.gitignore` (for example `/.docfx/run-actions/`) and invoke `BuildRunActions.ps1` at DocFX build time (for example in `BuildDocfxImage.ps1` right before `try { docker buildx build ... }`, with no AI or skill dependency) so duplicated `.ps1` wrapper scripts are never created during authoring, committed to Git, or flagged by static analysis. The normal fast validator does not regenerate or execute them.

```powershell
pwsh -NoProfile -File <docfx-dir>/BuildRunActions.ps1
```

`BuildRunActions.ps1` is 100% deterministic and self-contained: it reads `run-actions.manifest.json` and materializes `run-actions/<identity>/{native,docker}.ps1` for `standalone`, `repository`, and `host` strategies without modifying Markdown pages, `docfx.json`, or requiring any external skill installation.

Programs that resolve against the platform and simple xUnit examples can generate immediately through `New-CsrunExecutionPair` and manifest v1. Defaults are `net10.0` and `codebeltnet/csrun:10`. A recipe can set `csrunImage` for a different reviewed tag. Both wrappers download and verify the publisher's latest stable csrun release at execution time. Docker uses the selected image for its SDK and PowerShell.

### Legacy `.NET Framework` (`net48`) Native-only recipes for conditional `netstandard2.0` APIs

In multi-targeted libraries (for example `net11.0;net10.0;netstandard2.0`), some public types or members are compiled only when `NETSTANDARD2_0` is defined or `NETCOREAPP3_0_OR_GREATER` is absent (such as polyfills like `System.Runtime.CompilerServices.CallerArgumentExpressionAttribute`). Do **not** fall back to `net10.0` for these examples — `net10.0` selects `lib/net10.0`, omits the library's conditional type, and resolves the .NET BCL type instead — and do **not** mark them `intrinsicLimitation` when a legacy `.NET Framework` Native run action can execute them.

Instead, set `manifest.framework` (or `hostHarness.framework`) to a `csrun`-supported `.NET Framework` TFM (`net471`, `net472`, `net48`, or `net481`, typically `net48`), which consumes the package's `lib/netstandard2.0` asset natively on Windows (`csrun` v0.3.0+ falls back to an isolated temporary SDK-style `.csproj` with `LangVersion=latest` and `Microsoft.NETFramework.ReferenceAssemblies`, without changing manifest `schemaVersion` 1):

```json
{
  "uid": "System.Runtime.CompilerServices.CallerArgumentExpressionAttribute",
  "exampleId": "System.Runtime.CompilerServices.CallerArgumentExpressionAttribute#1",
  "fenceOrdinal": 1,
  "sourceSha256": "<exact displayed source hash>",
  "manifest": {
    "schemaVersion": 1,
    "mode": "console",
    "framework": "net48",
    "dependsOn": ["Cuemon.Kernel@11.0.0"]
  }
}
```

When `manifest.framework` or `hostHarness.framework` matches `^net4\d+$`, `generate-run-actions.ps1` and `BuildRunActions.ps1` automatically treat `docker` as `Unsupported` (`.NET Framework targets require Windows and cannot execute in the Linux csrun container.`) unless `unsupportedTransports.docker` already supplies a more specific reason. `run-actions.manifest.json` records `transports: ["native"]`, `BuildRunActions.ps1` materializes only `native.ps1` (no `docker.ps1`), the Markdown association renders only the Native link, and `--summary-json` reports `docker: "Unsupported"` with exit code `0`. On Windows, `--validate-run-action` and `--verify Native` compile and execute the `.NET Framework` binary natively; on non-Windows hosts, `--verify Native` skips `.NET Framework` recipes cleanly (recording `native: "Unverified"` with the Windows platform prerequisite instead of failing or corrupting the manifest), and `--validate-run-action` fails fast with `windows-required-for-netframework`.

For classification categories, command examples, dependency and validation diagnostics, see the [generator command reference](scripts.md#run-action-command-reference).

## Host harness (`mode: host` / `hostHarness`)

Use a `mode: host` / `hostHarness` recipe for blocking ASP.NET Core or Generic Host examples (such as `WebApplication.CreateBuilder` + `app.Run()`) instead of marking them `intrinsicLimitation`. Reserve `intrinsicLimitation` strictly for code with no observable runtime behavior at all. A host recipe stays outside csrun manifest v1 (using `strategy: "host"` in `run-actions.manifest.json` and `BuildRunActions.ps1`), keeps the visible C# unchanged, binds an ephemeral loopback port, starts the host, executes the configured probe/action within `timeoutSeconds`, captures output/assertions, and cleanly shuts down the host process tree on both Native and Docker transports:

```json
{
  "uid": "Example.AppTagHelperOptions",
  "exampleId": "Example.AppTagHelperOptions#1",
  "fenceOrdinal": 1,
  "sourceSha256": "<exact displayed source hash>",
  "mode": "host",
  "hostHarness": {
    "sdk": "Microsoft.NET.Sdk.Web",
    "framework": "net10.0",
    "dependsOn": ["Example.AspNetCore@1.0.0"],
    "probePath": "/",
    "probeMethod": "GET",
    "timeoutSeconds": 15,
    "expectedStatusCode": 200,
    "expectedBodyContains": "expected-text"
  }
}
```

## Refresh an existing site's toolbar

Use the generator from the skill revision that contains the requested UI change. Its sibling `assets/run-actions.js` is the source copied into the target's effective template. Run the command above even when the C# examples and their recipes are already current. Each example's `unchanged` status describes its PowerShell payloads. The same run still refreshes the toolbar module beside the effective template's `public/main.js`.

Compare the skill asset with that generated template module, rebuild the active DocFX configuration, and verify that the built site's `public/run-actions.js` matches. For a browser check, reload the rebuilt site with caching disabled and exercise the changed control. Report the toolbar refresh separately from script generation and runtime verification. For a toolbar-only request, keep existing C#, recipes, intact scripts and their verification evidence.

## Resolve the outstanding examples

1. Start with `generate-run-actions.ps1 -RepoRoot <repository> --run-action-plan --json` and `--check-recipes --json` to get an exact, deterministic queue of convertible vs non-convertible fences and any orphaned/moved/duplicate recipes.
2. Work in small batches grouped by owner project and execution context. Run `--resolve-dependencies <uid>` to verify exact assembly/type ownership and catch `missing-package` / `ambiguous-type` issues before building.
3. For convertible examples, run `--validate-run-action <uid>` and then `--apply-run-action <uid>`. For blocking host examples, author a `mode: host` / `hostHarness` recipe. For examples requiring the original application assembly/runner, use a pinned `repository` recipe. For `no-entry` or `host-parameterized` examples, inspect the source/tests and author a concrete driver or manual harness.
4. Regenerate and verify with `--summary-json` (and `--verify-changed` or `--verify --id <uid>` with `--engine-path <csrun.ps1>`). Continue until every example is paired or has a demonstrated limitation with no observable behavior.

For repository-backed execution, the generalized `New-RepositoryExamplePair` accepts a commit-pinned GitHub repository, project, exact xUnit v3/MTP method, framework and official SDK image. It downloads the original graph and requires an XML report proving exactly that method passed. It never synthesizes an application or test host. The inspected ManagedApplicationFixture source fingerprint has a bundled recipe for the original pinned worker functional test. A changed assertion invalidates that recipe, preserving the C# and source links while removing stale controls.

Optional `run-actions.settings.json` beside docfx.json (or `-Settings <path>`) supplies inspected recipes for other examples. Each entry matches `uid` (plus optional `exampleId` and `fenceOrdinal` for multi-fence pages) and the uppercase SHA-256 of LF-normalized C# without outer trailing newlines or the two source-context lines, plus optional `whitespaceSha256` for whitespace-only orphan detection. This is DocFX generation configuration, not an extension to the csrun manifest:

```json
{
  "examples": [
    {
      "uid": "Example.Api",
      "exampleId": "Example.Api#1",
      "fenceOrdinal": 1,
      "sourceSha256": "<exact displayed source hash>",
      "repository": "owner/repository",
      "commit": "<40 hex commit>",
      "project": "test/FunctionalTests/FunctionalTests.csproj",
      "test": "Example.FunctionalTest.ShouldStart",
      "framework": "net10.0",
      "image": "mcr.microsoft.com/dotnet/sdk:10.0"
    },
    {
      "uid": "Example.OtherApi",
      "exampleId": "Example.OtherApi#1",
      "fenceOrdinal": 1,
      "sourceSha256": "<exact displayed source hash>",
      "manifest": {
        "schemaVersion": 1,
        "mode": "test",
        "framework": "net10.0",
        "dependsOn": ["xunit.v3@4.0.3", "Example.Package@1.2.3"]
      }
    }
  ]
}
```

For conversion, capture the original scenario and expected observations before transforming the fence. Apply [the behavioral check](repair.md#check-one-example) to the converted entry point. For composed repair, regenerate after correcting the visible source and any affected pins or recipe. Materialize the scripts with the existing build helper. Verify affected examples with explicit transport selectors below. Compare observations to the current claims even when a cached script execution can be reused. If one transport is unavailable, verify the other independently and identify the outstanding environment.

The generator uses the visible C# as the standalone manifest source, including source-context comments. A supplied `manifest.source` must match the fence after newline normalization. Legacy `harness` recipes fail generation until the executable code is moved into the fence and its recipe hash is updated.

Use the pinned repository path for the original application startup or assembly graph. Check the maintained runner, report switches and exact test. For a recipe backed by a different maintained test, explain the relationship to the displayed source and link to the original. A recipe can declare `"unsupportedTransports": { "docker": "<precise platform limitation>" }` (or `native`) to deliver the other transport. Use `"intrinsicLimitation": "<specific evidence>"` without an execution recipe only when the code has no observable runtime behavior at all and neither standalone, host, nor repository execution can faithfully demonstrate it. A missing local SDK or Docker installation affects runtime verification.

Each supported C# fence is followed by an association with its Native and Docker assets. Repository-backed associations explicitly name the pinned test; host-harness associations note the bounded host lifecycle. In the modern template, `assets/run-actions.js` places **Copy Native run script** and **Copy Docker run script** beside DocFX's copy icon. The controls appear on hover and keyboard focus and stay visible on touch devices. Activating either control fetches the complete PowerShell script and copies it to the clipboard. Shift-click, right-click or Shift+Enter opens the full script in an in-page preview. The fallback asset links are visible until the toolbar is enhanced. A genuinely unsupported transport is omitted from the association with its reason retained in the manifest. Generated imports compose with the last existing modern template `public/main.js`, retaining its exports, start hook and Context7 behavior. If none exists, the command adds a small template layer. Clipboard writes require a secure browser context and permission.

## Transport verification

See [generator diagnostics](scripts.md#run-action-generator-diagnostics) for exit codes, summary JSON and cache records. Generation without `--verify` reports `verifyScope: "none"`, `verificationRequested: false`, `verified: 0`, and previously cached transport counts separately under `cachedVerified` / `verification.cachedNativeVerified` / `verification.cachedDockerVerified`; transport verification never evaluates example behavior (`verification.behavioralVerification: "not-evaluated"`).

Explicitly pass `--verify Native`, `--verify Docker`, or `--verify Both` (or PowerShell `-Verify`) — optionally scoped with repeatable `--uid <uid-or-uid#ordinal>` (scopes planning, recipe checking, generation, Markdown association updates, and verification strictly to the selected UIDs or `uid#ordinal` fences while preserving out-of-scope `run-actions.manifest.json` entries and sibling fence associations; rejects unknown or ambiguous selectors with exit `3`), `--verify-changed` (skips re-executing transports that already have valid cached `Verified` evidence for an unchanged manifest entry), or `--id <uid-or-exampleId>` (verifies only the targeted example(s)) — plus `--engine-path <local-csrun.ps1>` (or `-EnginePath`). Verification runs concurrently with bounded parallelism (`ForEach-Object -Parallel`): Native concurrency defaults to `min(CPU count, 8)` and is configurable via `--max-parallel <n>` / `-MaxParallel` (`1`–`64`), while Docker concurrency uses a conservative cap of `min(native-parallel, 2)` by default (honoring explicit `--max-parallel` on Docker-only runs) and is separately configurable via `--max-docker-parallel <n>` / `-MaxDockerParallel` (`1`–`16`). Workers write isolated private-cache logs and atomic evidence records; all worker results are collected on the main thread before `run-actions.manifest.json` is written atomically once all workers finish, preserving the last good manifest and Markdown associations on any verification failure. During verification, append-only progress lines are emitted to `stderr` (`[12/425] Verifying <exampleId> (Native) -> Verified (1.8s)`) alongside a 10-second `[heartbeat]` line (configurable via `--heartbeat-seconds <n>`) so `--summary-json` on `stdout` stays clean and parseable; pass `--no-heartbeat` / `-NoHeartbeat` to suppress periodic heartbeats while keeping per-item lines, or `--quiet` / `-Quiet` to suppress all `stderr` progress and heartbeat lines. For standalone examples, `generate-run-actions.ps1` preflights and resolves the SHA-256-verified `csrun.ps1` once before touching any file or manifest. If engine resolution fails (for example GitHub HTTP 403/429 with no cached engine), the generator exits `1`, emits `failureReason` (`github-403-no-cached-engine` / `github-429-no-cached-engine` / `engine-path-not-found`), and leaves the previous `run-actions.manifest.json` and Markdown pages untouched. `run-actions.manifest.json` is always written atomically via temp file + rename and is never replaced with an empty manifest as a side effect of a failed verification. Do not run batch or parallel verification sweeps directly against materialized `run-actions/<identity>/{native,docker}.ps1` files, because each materialized script queries GitHub's unauthenticated REST API (`releases/latest`) and quickly hits the 60-requests/hour IP rate limit and abuse detection. Standalone tests require an executed-test summary with every test passing and zero skips. Unrun transports stay `Unverified`. Changes to source, recipe or generator invalidate previous verification. Follow the active operation's completion procedure in `SKILL.md` (`--operation repair-csrun` with `--behavioral-ledger` for `repair csrun`, or `--operation validate` for non-repair `csrun`) when editing documentation.

Run the focused deterministic regression with `pwsh -NoProfile -File <skill-dir>/scripts/test-run-actions.ps1`. It builds the shared inventory once, checks the direct paired-delivery rule, complete Native/Docker reference scripts, same-sample links and copy controls, independent verification status, source/pin parity, unsupported cases, second-run bytes/timestamps, stale cleanup, deterministic planning/explain, dependency ownership/ambiguity preflight, validation-gated apply, multi-fence identity and recipe health (`moved`, `duplicate-uid`, `orphaned` whitespace vs semantic), atomic manifest preservation on GitHub 403 and parallel runtime failures, bounded parallel verification with append-only `stderr` progress/heartbeat logging (`--max-parallel`, `--no-heartbeat`, `--quiet`), `--summary-json` / `--verify-changed` / `--verify --id` / `--uid` scoping, `mode: host` / `hostHarness`, and a real DocFX modern render in OS temp. Existing `test-integration-example.ps1` checks exact execution/failure semantics with offline doubles. These checks do not assert live native/Docker integration execution. Normal authoring and the active operation's completion procedure in `SKILL.md` apply when editing an actual documentation repository.

For the browser check, install Playwright through your usual development environment, optionally set `PLAYWRIGHT_MODULE` to its module path, and run `node <skill-dir>/scripts/test-run-actions-browser.cjs <fixture>/_site` against the fixture path printed by the deterministic regression. The check covers alignment, the C# and PowerShell clipboard payloads, pointer and keyboard interactions, touch, preview, feedback, Context7 startup, idempotence and the no-JavaScript fallback. It detects navigation, new pages and downloads even when the server marks the scripts as attachments. Pass an additional built xUnit site directory to check the `TestOutputHelperAccessor` API example and set `DOCFX_ACTIONS_SCREENSHOT` to capture its toolbar.
