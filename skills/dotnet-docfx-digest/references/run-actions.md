# Generated run actions (opt-in)

The logical command `dotnet-docfx-digest generate-run-actions` covers the active DocFX repository in one skill invocation. Resolve the loaded skill directory and start with the deterministic generator:

```powershell
pwsh -NoProfile -File <skill-dir>/scripts/generate-run-actions.ps1 -RepoRoot <repository> [-Docfx <docfx.json>]
```

The command uses `docfx.cs --run-action-inventory`, sharing discovery from `build.content`/`build.overwrite`, fence extraction, UID ownership and source-context validation with compilation. It generates `run-actions/<identity>/native.ps1` and `docker.ps1` beside the active configuration and adds these as DocFX static resources. A small HTML association immediately follows the unchanged C# fence. UID, document identity and maintained source path (or source hash for inline examples) determine its identity; fence ordinals do not. Owned associations and assets are replaced when their source changes or disappears. Keep this directory and the generated template assets as intentional documentation source, not scratch output. The normal fast validator does not regenerate or execute them.

Programs that resolve against the platform and simple xUnit examples can generate immediately through `New-CsrunExecutionPair` and manifest v1. Defaults are `net10.0` and `codebeltnet/csrun:10`. A recipe can set `csrunImage` for a different reviewed tag. The Native wrapper downloads the publisher's current release and Docker tags can change.

## Resolve the outstanding examples

1. Review each `Unresolved` result with `docfx.cs --repo-root <repository> --run-action-inventory`. Pass the same `--docfx` or `--run-action-settings <path>` if applicable. The inventory includes C#, UID, maintained source context, owner project candidates, metadata frameworks and shared build input paths.
2. Work in small batches grouped by owner project and execution context. Evaluate the project references and target framework with MSBuild, including central package management, conditional imports and shared framework references. Check published NuGet metadata and compatible assets for the exact version implementing the documented operation. Use imports as leads for investigation.
3. Persist a source-bound recipe in `run-actions.settings.json`. Prefer published dependencies with unchanged C#. For a library excerpt, supply the inputs and either print its result or assert a behavior. Check the maintained source and tests when execution needs the original application assembly, runner or unpublished implementation.
4. Regenerate after each project batch. Continue in this invocation until every example is paired or its technical limitation has evidence. For each exception report the UID, specific limitation and recommended documentation treatment. The generator has no model execution or per-file sessions.

For repository-backed execution, the generalized `New-RepositoryExamplePair` accepts a commit-pinned GitHub repository, project, exact xUnit v3/MTP method, framework and official SDK image. It downloads the original graph and requires an XML report proving exactly that method passed. It never synthesizes an application or test host. The inspected ManagedApplicationFixture source fingerprint has a bundled recipe for the original pinned worker functional test. A changed assertion invalidates that recipe, preserving the C# and source links while removing stale controls.

Optional `run-actions.settings.json` beside docfx.json (or `-Settings <path>`) supplies inspected recipes for other examples. Each entry matches both `uid` and the uppercase SHA-256 of LF-normalized C# without outer trailing newlines or the two source-context lines. The generator reports that hash for unsupported cases. This is DocFX generation configuration, not an extension to the csrun manifest:

```json
{
  "examples": [
    {
      "uid": "Example.Api",
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
      "sourceSha256": "<exact displayed source hash>",
      "harness": {
        "members": "public sealed class RunExample { [Xunit.Fact] public void ParsesStock() { Xunit.Assert.Equal(42, new StockExample().ReadQuantity(\"42\")); } }"
      },
      "explanation": "The test passes a stock quantity to the displayed method and checks the parsed result.",
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

A supplied `manifest.source` must match the excerpt. A `harness` can supply `members`, such as a console entry point or an xUnit class that calls the displayed method. Roslyn checks the excerpt and declarations before composition. Appended members follow an existing file-scoped namespace. In the narrow console case where the original entry point type must support discovery (for example, `CreateHostBuilder`), `harness.entryPointStatements` can supply the body of the existing static `Main`. Preserve the operation under discussion and explain the added context or replacement with the recipe's `explanation`. The generator supplies the same composed source to both scripts. `sourceSha256` identifies the excerpt and `executionSourceSha256` identifies standalone executable C#.

Use the pinned repository path for the original application startup or assembly graph. Check the maintained runner, report switches and exact test. For a recipe backed by a different maintained test, explain the relationship to the displayed source and link to the original. A recipe can declare `"unsupportedTransports": { "docker": "<precise platform limitation>" }` (or `native`) to deliver the other transport. Use `"intrinsicLimitation": "<specific evidence>"` without an execution recipe only after demonstrating that faithful one-shot execution is impossible. A missing local SDK or Docker installation affects runtime verification.

Each supported C# fence is followed by an association with its own Native and Docker assets. In the modern template, `assets/run-actions.js` places **Copy Native run script** and **Copy Docker run script** beside DocFX's copy icon. The controls appear on hover and keyboard focus and stay visible on touch devices. Activating either control fetches the complete PowerShell script and copies it to the clipboard. Shift-click, right-click or Shift+Enter opens the full script in an in-page preview. The fallback asset links are visible until the toolbar is enhanced. A genuinely unsupported transport is omitted from the association with its reason retained in `index.json`. Generated imports compose with the last existing modern template `public/main.js`, retaining its exports, start hook and Context7 behavior. If none exists, the command adds a small template layer. Clipboard writes require a secure browser context and permission.

Each JSON result and `index.json` entry includes `coverage` alongside generation `status` and independent Native/Docker states. `Paired` means both scripts were generated. `Partially supported` requires a documented transport limitation. `Unresolved` includes missing dependency evidence, invalid recipes and source context errors. `Intrinsically non-executable` requires a limitation bound to the source. Exit 2 means unresolved coverage remains. Exit 1 takes precedence for recipe, generation or runtime failures. Unchanged fingerprints reuse intact assets and retain verification evidence.

Explicitly pass `-Verify Native`, `-Verify Docker` or `-Verify Both` to run the selected scripts in separate PowerShell processes and record exit outcomes and log paths under OS temp. Standalone tests require an executed-test summary with every test passing and zero skips. Unrun transports stay `Unverified`. Changes to source, recipe or generator invalidate previous verification. Regular DocFX completion requirements still apply when editing documentation.

Run the focused deterministic regression with `pwsh -NoProfile -File <skill-dir>/scripts/test-run-actions.ps1`. It builds the shared inventory once, checks the direct paired-delivery rule, complete Native/Docker reference scripts, same-sample links and copy controls, independent verification status, source/pin parity, unsupported cases, second-run bytes/timestamps, stale cleanup and a real DocFX modern render in OS temp. Existing `test-integration-example.ps1` checks exact execution/failure semantics with offline doubles. These checks do not assert live native/Docker integration execution. Normal authoring and the `agents.cs` plus `docfx.cs --build-api-model --validate-samples --verify-docfx-build` completion requirements remain unchanged when editing an actual documentation repository.

For the browser check, install Playwright through your usual development environment, optionally set `PLAYWRIGHT_MODULE` to its module path, and run `node <skill-dir>/scripts/test-run-actions-browser.cjs <fixture>/_site` against the fixture path printed by the deterministic regression. The check covers alignment, the C# and PowerShell clipboard payloads, pointer and keyboard interactions, touch, preview, feedback, Context7 startup, idempotence and the no-JavaScript fallback. It detects navigation, new pages and downloads even when the server marks the scripts as attachments. Pass an additional built xUnit site directory to check the `TestOutputHelperAccessor` API example and set `DOCFX_ACTIONS_SCREENSHOT` to capture its toolbar.
