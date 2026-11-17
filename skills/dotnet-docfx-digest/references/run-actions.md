# Generated run actions (opt-in)

`dotnet-docfx-digest generate-run-actions` enriches the active DocFX repository in one invocation. It does not invoke an AI agent per file or execute examples during generation. Resolve the loaded skill directory and invoke:

```powershell
pwsh -NoProfile -File <skill-dir>/scripts/generate-run-actions.ps1 -RepoRoot <repository> [-Docfx <docfx.json>]
```

The command uses `docfx.cs --run-action-inventory`, sharing discovery from `build.content`/`build.overwrite`, fence extraction, UID ownership and source-context validation with compilation. It generates `run-actions/<identity>/native.ps1` and `docker.ps1` beside the active configuration and adds these as DocFX static resources. A small HTML association immediately follows the unchanged C# fence. UID, document identity and maintained source path (or source hash for inline examples) determine its identity; fence ordinals do not. Owned associations and assets are replaced when their source changes or disappears. Keep this directory and the generated template assets as intentional documentation source, not scratch output. The normal fast validator does not regenerate or execute them.

Standalone programs with resolvable platform references and simple xUnit examples are discovered automatically. Their exact source is passed to the existing `New-CsrunExecutionPair`; manifest v1 and the engine are unchanged. The defaults are `-Framework net10.0` and `-CsrunImage codebeltnet/csrun:10`; select a reviewed compatible image/tag for publishing. The existing csrun native wrapper downloads the publisher's mutable latest engine. These defaults are not immutable execution provenance; inspect scripts before running them. Dependency-rich examples need explicit source-bound settings rather than guessed package versions. Partial fragments, unavailable dependencies and genuine assembly boundaries are reported as unsupported when no faithful recipe exists.

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

The generator fills `manifest.source` from the original example; if supplied, it must match. Inspect pinned source, original runner version/report switches and project dependencies before adding a repository recipe; this generator supports the existing xUnit v3/MTP XML protocol only. A recipe may supply `"unsupportedTransports": { "docker": "<precise platform limitation>" }` (or `native`) to publish only the faithful transport and record the limitation; environment unavailability during authoring is never a platform limitation. A different runner, Windows-only dependency or external service may require a separate maintained reproduction. Do not publish a substitute merely to add buttons. Preserve contextual GitHub implementation, usage and test links and explain any unsupported execution limitation in the authoring pass.

Each supported example gets one association immediately after its C# fence containing both the Native and Docker asset links; the assets therefore belong to the same sample. The reusable `assets/run-actions.js` module adds **Copy Native** and **Copy Docker** controls to that sample together, with tooltips, accessible names, keyboard focus and hover visibility. Each click fetches the whole corresponding script and writes it to the clipboard; it never evaluates the response. Ordinary **View Native Script**/**View Docker Script** links remain available without JavaScript and on copy failure. A genuinely unsupported transport is omitted from the association with its reason retained in `index.json`. Generated imports compose with the last existing modern template `public/main.js`, retaining its exports/start hook and Context7 behavior. If none exists, the command adds a small template layer. Review the configuration/template diff before publishing; use the modern template. Clipboard writes require a secure browser context and permission.

Generation reports `generated`, `unchanged`, `unsupported` and `failed` cases in JSON. `index.json` records source/script fingerprints and separate Native/Docker states. Unchanged fingerprints reuse intact assets, preserving bytes and modification times. `Unverified` means generation only. Explicitly pass `-Verify Native`, `-Verify Docker` or `-Verify Both` to execute each selected script in an independent fresh PowerShell process and retain separate exit outcomes/log paths under OS temp. Standalone test wrappers require a successful runner summary with at least one test executed and every test passing. Skipped tests and missing summaries fail verification. Verification status is per transport: verifying Native alone must leave Docker `Unverified`, and verifying Docker alone must leave Native `Unverified`. Verification runs trusted repository/package code and may restore/build/pull images; do not enable it for a large repository merely to generate assets. A changed source/recipe/tool fingerprint invalidates previous verification. Failed execution returns nonzero; missing Docker or SDK affects verification, never valid artifact generation.

Run the focused deterministic regression with `pwsh -NoProfile -File <skill-dir>/scripts/test-run-actions.ps1`. It builds the shared inventory once, checks the direct paired-delivery rule, complete Native/Docker reference scripts, same-sample links and copy controls, independent verification status, source/pin parity, unsupported cases, second-run bytes/timestamps, stale cleanup and a real DocFX modern render in OS temp. Existing `test-integration-example.ps1` checks exact execution/failure semantics with offline doubles. These checks do not assert live native/Docker integration execution. Normal authoring and the `agents.cs` plus `docfx.cs --build-api-model --validate-samples --verify-docfx-build` completion requirements remain unchanged when editing an actual documentation repository.

For the browser check, install Playwright through your usual development environment, optionally set `PLAYWRIGHT_MODULE` to its module path, and run `node <skill-dir>/scripts/test-run-actions-browser.cjs <fixture>/_site` against the fixture path printed by the deterministic regression. It checks the actual modern page, both complete clipboard payloads, keyboard activation, Context7 startup, idempotent controls, no-JavaScript links and fetch failure. Windows clipboard newline conversion is compared separately from the exact payload passed to the Clipboard API.
