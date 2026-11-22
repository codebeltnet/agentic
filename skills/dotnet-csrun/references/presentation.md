# Readable examples and honest evidence

Deliver two complete PowerShell 7 blocks for every compatible completed sample: native (SDK/runtime and trusted engine, no Docker) and disposable Docker (Linux containers and compatible image, no host SDK). Each includes its own full manifest construction, UTF-8 transport setup, invocation, and immediate exit capture. Do not require variables, helper scripts, downloads of fixtures, or execution of the other block. An unavailable transport is still delivered but labeled **Not executed / Unverified**.

Generate both from the same canonical manifest using the bundled helper. This maintainer operation produces the standalone strings to present; the developer does not need the helper:

```powershell
. '<resolved-skill-dir>/scripts/sample-tools.ps1'
# $manifest is the single JSON manifest already constructed from the inspected source.
# Confirm the selected image exists and supports the framework before using it.
$pair = New-CsrunExecutionPair -ManifestJson $manifest -Image 'codebeltnet/csrun:10'
$pair.Native
$pair.Docker
```

Pass `-EnginePath '<absolute-reviewed-csrun.ps1>'` (or `-EnginePath (Resolve-CsrunEngine).Path` during skill verification sweeps) to execute against a locally verified engine without hitting GitHub per example. Always omit `-EnginePath` when generating delivered or published blocks: by default, the generated Native and Docker blocks query GitHub at runtime for the latest stable release and verify the downloaded script against the SHA-256 digest in that release's asset metadata. Both this release selection and SDK-oriented Docker tags can change over time. The helper generates the blocks without making network requests or executing samples. Its JSON literal preserves multiline C#, Unicode, quotes, raw strings, dollars, and PowerShell here-string terminators. [csrun source and releases](https://github.com/codebeltnet/csrun)

Use `Get-CsrunSampleIdentity` to obtain exact UTF-8 source SHA-256 and the canonical JSON manifest SHA-256. Canonicalization sorts object keys and preserves arrays and every value, including source line endings; JSON whitespace/property order alone does not invalidate identity. `Get-CsrunWrapperManifest` safely reads a generated block's literal assignment through the PowerShell AST without running it. Compare both decoded manifests and the documented source before publication; reject divergence, including dependencies, SDK or framework references. Other wrapper formats need manual inspection rather than execution for extraction. Ordinary interactive developers do not manage hashes themselves.

Lead with the behavior, then Copy & Run, Verification, and only necessary requirements/caveats. Combine behavior and wrapper for small examples. Do not require helper scripts or fixture downloads in the developer-facing command. Show expected output explicitly as expected until observed. Derive separately displayed C# from the same source string used for execution.

Record source/manifest identity, transport, framework, actual SDK/runtime/platform, engine release/hash or container digest when available, exact pins and resolved assets when reuse matters, expected observations, actual stdout/stderr, exit status, discovered/executed/passed/failed counts, and classification. Store evidence outside tracked source. Preserve raw diagnostics; summarize only relevant lines to the user. Do not estimate unavailable metrics. For repairs, retain before/after source and manifest identities, meaningful diff, failure evidence and corrected execution evidence. Never promote native success to Docker success or vice versa.

Current engine outcomes: success 0; validation/prerequisite failure 1; assertion failure MTP 2; no discovered tests MTP 8. Compiler/runtime failures preserve child status, so do not assume every non-test failure is 1. Compare diagnostics as well as status. Skips do not prove assertions executed. An intentional failing assertion can be **Verified expected failure**, while clearly stating that the test failed; an unexpected failure is **Failed**. Never classify zero tests as passing.

For nondeterministic behavior verify stable invariants instead of incidental timestamps/order. When runtime is missing, state **Unverified**, name the missing SDK/runtime or unavailable Docker daemon/image, and offer a compatible environment without retargeting. Do not claim complete determinism with mutable tags, transitive dependencies, platform differences, or external services.

Report feasibility separately from execution classification. For unsupported preflight, give Unsupported / Unverified, the missing capability and the appropriate verification path; omit a known-failing copy block. For an attempted incompatible build, report Failed with its real diagnostic/exit and no test execution. This does not decide the application's correctness. Label exact behavior, semantics-preserving adaptation, reduced demonstration or alternative behavior explicitly when adapting source; only the first two substantiate the original claim. See [feasibility and recovery](feasibility.md).
