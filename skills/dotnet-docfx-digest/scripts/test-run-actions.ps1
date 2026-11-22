#requires -Version 7.0
param([string] $OutputRoot)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '../../../scripts/file-based-app.ps1')
. (Join-Path $PSScriptRoot '../../dotnet-csrun/scripts/sample-tools.ps1')
Set-StrictMode -Off
$app = Get-FileBasedAppCommand -SourcePath (Join-Path $PSScriptRoot 'docfx.cs')
function dotnet {
    if ($inventoryOverride) { $global:LASTEXITCODE = 0; return $inventoryOverride }
    # Cache the file-based inventory build once; every inventory assertion still executes.
    & (Get-Command $app.Executable -CommandType Application | Select-Object -First 1).Source @($app.ArgumentPrefix + @($args | Select-Object -Skip ([Array]::IndexOf($args, '--repo-root'))))
    $global:LASTEXITCODE = $LASTEXITCODE
}
$work = if ($OutputRoot) { $OutputRoot } else { Join-Path ([IO.Path]::GetTempPath()) ('docfx-actions-' + [guid]::NewGuid().ToString('N')) }
$null = New-Item -ItemType Directory -Path "$work/docs" -Force
$reference = Get-Content (Join-Path $PSScriptRoot '../references/one-shot-examples.md') -Raw
$skill = Get-Content (Join-Path $PSScriptRoot '../SKILL.md') -Raw
if (-not $skill.Contains('Whenever a runnable example is delivered, surface both complete Native and Docker execution options together') -or
    -not $skill.Contains('never extract `## Native` alone when the corresponding `## Docker` option exists')) {
    throw 'The direct Codex delivery contract must require both complete supported transports.'
}
if (-not $reference.Contains('Whenever DocFX Digest delivers a runnable example, deliver the complete Native and Docker options together') -or
    -not $reference.Contains('Keep verification independent: mark a transport `Verified` only after that transport passes')) {
    throw 'The one-shot reference must preserve paired delivery and independent verification status.'
}
$nativeSection = [regex]::Match($reference, '(?ms)^## Native:[^\r\n]*\r?\n.*?(?=^## Docker:)')
$dockerSection = [regex]::Match($reference, '(?ms)^## Docker:[^\r\n]*\r?\n.*?(?=^## Further exploration)')
$nativeScript = [regex]::Match($nativeSection.Value, '(?s)```powershell\r?\n(?<script>.*?)\r?\n```')
$dockerScript = [regex]::Match($dockerSection.Value, '(?s)```powershell\r?\n(?<script>.*?)\r?\n```')
if (-not $nativeSection.Success -or -not $dockerSection.Success -or
    -not $nativeScript.Success -or -not $dockerScript.Success -or
    $nativeScript.Groups['script'].Value -cnotmatch '\A& \{\r?\n#requires -Version 7\.0\r?\n' -or
    $dockerScript.Groups['script'].Value -cnotmatch '\A& \{\r?\n#requires -Version 7\.0\r?\n') {
    throw 'The paired reference example must contain complete, independently runnable Native and Docker scripts.'
}
foreach ($scriptText in @($nativeScript.Groups['script'].Value, $dockerScript.Groups['script'].Value)) {
    $tokens = $null; $parseErrors = $null
    $null = [Management.Automation.Language.Parser]::ParseInput($scriptText, [ref]$tokens, [ref]$parseErrors)
    if ($parseErrors.Count) { throw "A paired reference execution script is not valid PowerShell: $parseErrors" }
}
$source = [regex]::Match($reference, '(?s)```csharp\r?\n(.*?)\r?\n```').Groups[1].Value
$page = "---`nuid: Codebelt.Extensions.Xunit.Hosting.ManagedApplicationFixture``1`n---`n# Actual worker startup`n`nMaintained functional test and [entry point](https://github.com/codebeltnet/xunit/blob/84b13767cb9484f8f3a36a71875662edfdb3e511/app/Codebelt.Extensions.Xunit.Hosting.BootstrapperMinimalWorker.App/Program.cs).`n`n``````csharp`n$source`n```````n"
[IO.File]::WriteAllText("$work/docs/integration.md", $page)
$console = "# Console`r`n`n``````csharp`n// Program.cs`r`nSystem.Console.WriteLine(42);`n``````"
$partial = "# Partial`r`n`n``````csharp`nvar fixture = new ManagedApplicationFixture<Program>();`r`n```````n"
[IO.File]::WriteAllText("$work/docs/console.md", $console)
[IO.File]::WriteAllText("$work/docs/partial.md", $partial)
$null = New-Item -ItemType Directory "$work/template/public" -Force
[IO.File]::WriteAllText("$work/template/public/main.js", "// Context7 customization`nexport default { start() { window.context7 = true; } };`n")
[IO.File]::WriteAllText("$work/BuildDocfxImage.ps1", "`$version = minver -i -t v -v w`ndocfx metadata docfx.json`ndocker buildx build -t xunit-docfx:`$version --platform linux/arm64,linux/amd64 --load -f Dockerfile.docfx .`nget-childItem -recurse -path api -include *.yml, .manifest | remove-item`n")
[IO.File]::WriteAllText("$work/docfx.json", '{"build":{"content":[{"files":["docs/*.md"]}],"template":["default","modern","template"],"dest":"_site"}}')
[IO.File]::WriteAllText("$work/docs/test.md", "# Test`n`n``````csharp`nusing Xunit;`npublic class ExampleTest { [Fact] public void ParsesInventoryCount() { Assert.Equal(42, int.Parse(`"42`")); } }`n```````n")
$packageSource = @'
using Codebelt.Extensions.Xunit;
using Cuemon.Messaging;
using Microsoft.Extensions.DependencyInjection;
using Xunit;

namespace Samples;

public class CorrelationStore
{
    public string Resolve()
    {
        var services = new ServiceCollection();
        var store = new InMemoryTestStore<CorrelationToken>();
        store.Add(new CorrelationToken("inventory"));
        services.AddSingleton(store);
        using var provider = services.BuildServiceProvider();
        return System.Linq.Enumerable.Single(provider.GetRequiredService<InMemoryTestStore<CorrelationToken>>().Query()).CorrelationId;
    }
}
'@
$packageSource += "`n`n" + @'
public sealed class CorrelationStoreTests
{
    [Fact]
    public void ResolvesTaggedInventory()
    {
        Assert.Equal("inventory", new CorrelationStore().Resolve());
    }
}
'@
$packageUid = 'Samples.CorrelationStore'
[IO.File]::WriteAllText("$work/docs/packages.md", "---`nuid: $packageUid`n---`n# Correlation store`n`n``````csharp`n$packageSource`n```````n")
$null = New-Item -ItemType Directory "$work/src" -Force
[IO.File]::WriteAllText("$work/src/Samples.csproj", @'
<Project Sdk="Microsoft.NET.Sdk">
  <PropertyGroup><TargetFramework>net10.0</TargetFramework></PropertyGroup>
  <ItemGroup>
    <PackageReference Include="Codebelt.Extensions.Xunit" />
    <PackageReference Include="Cuemon.Core" />
    <PackageReference Include="Microsoft.Extensions.DependencyInjection" />
    <PackageReference Include="xunit.v3.assert" />
  </ItemGroup>
</Project>
'@)
[IO.File]::WriteAllText("$work/Directory.Packages.props", @'
<Project>
  <PropertyGroup><ManagePackageVersionsCentrally>true</ManagePackageVersionsCentrally></PropertyGroup>
  <ItemGroup>
    <PackageVersion Include="Codebelt.Extensions.Xunit" Version="13.0.0" />
    <PackageVersion Include="Cuemon.Core" Version="11.0.0" />
    <PackageVersion Include="Microsoft.Extensions.DependencyInjection" Version="10.0.15" />
    <PackageVersion Include="xunit.v3.assert" Version="4.0.3" />
  </ItemGroup>
</Project>
'@)
[IO.File]::WriteAllText("$work/src/CorrelationStore.cs", $packageSource)
$null = New-Item -ItemType Directory -Path "$work/api/types" -Force
$uid = 'Codebelt.Extensions.Xunit.Hosting.ManagedApplicationFixture`1'
$overwrite = "---`nuid: $uid`nexample:`n  - *content`n---`n`n``````csharp`n$source`n```````n`nRead the maintained functional test and application sources."
# Exercise localized edits with an existing UTF-8 BOM and CRLF overwrite document.
[IO.File]::WriteAllText("$work/api/types/ManagedApplicationFixture-1.md", $overwrite.Replace("`r`n", "`n").Replace("`n", "`r`n"), [Text.UTF8Encoding]::new($true))
[IO.File]::WriteAllText("$work/api/fixture.yml", "### YamlMime:ManagedReference`nitems:`n- uid: $uid`n  id: ManagedApplicationFixture``1`n  name: ManagedApplicationFixture<TEntryPoint>`n  fullName: $uid`n  type: Class`n  langs:`n  - csharp`n  syntax:`n    content: public class ManagedApplicationFixture<TEntryPoint>`n")
$config = Get-Content "$work/docfx.json" -Raw | ConvertFrom-Json -AsHashtable
$config.metadata = @(@{src=@(@{files=@('src/Samples.csproj')});properties=@{TargetFramework='net10.0'}})
$config.build.content += @{ files=@('api/*.yml') }
$config.build.overwrite = @(@{ files=@('api/types/*.md') })
[IO.File]::WriteAllText("$work/docfx.json", ($config | ConvertTo-Json -Depth 20))
$generator = Join-Path $PSScriptRoot 'generate-run-actions.ps1'
$inventory = (dotnet --repo-root $work --run-action-inventory) | ConvertFrom-Json
$packageExample = $inventory.examples | Where-Object uid -ceq $packageUid
if ($packageExample.ownerProjects -cnotcontains 'src/Samples.csproj' -or $inventory.projects[0].buildInputs -cnotcontains 'Directory.Packages.props') {
    throw 'The dependency investigation must expose the source-owning project and central version file.'
}
$discovery = (& $generator -RepoRoot $work) | ConvertFrom-Json
if ($LASTEXITCODE -ne 2 -or @($discovery | Where-Object coverage -eq 'Unresolved').Count -ne 2) { throw 'Unresolved examples must keep generation incomplete.' }
$projectReferences = ([xml](Get-Content "$work/src/Samples.csproj" -Raw)).Project.ItemGroup.PackageReference.Include
$packagePins = @(([xml](Get-Content "$work/Directory.Packages.props" -Raw)).Project.ItemGroup.PackageVersion |
    Where-Object { $_.Include -in $projectReferences -and $_.Include -ne 'xunit.v3.assert' } | ForEach-Object { "$($_.Include)@$($_.Version)" })
$packageRecipe = [ordered]@{
    uid=$packageUid; sourceSha256=$packageExample.sourceSha256
    manifest=@{schemaVersion=1; mode='test'; framework='net10.0'; dependsOn=$packagePins + 'xunit.v3@4.0.3'}
    explanation='The test runs the displayed method and checks the correlation identifier returned from the DI container.'
}
$settingsPath = "$work/run-actions.settings.json"
[IO.File]::WriteAllText($settingsPath, (@{examples=@($packageRecipe)} | ConvertTo-Json -Depth 20))
$first = (& $generator -RepoRoot $work) | ConvertFrom-Json
if ($LASTEXITCODE -ne 2 -or @($first | Where-Object coverage -eq 'Paired').Count -ne 5 -or @($first | Where-Object coverage -eq 'Unresolved').Count -ne 1) { throw "Unexpected generation: $($first | ConvertTo-Json -Depth 10)" }
if (Test-Path -LiteralPath "$work/run-actions") { throw 'Generator must not physically create run-actions/ in the working tree; BuildRunActions.ps1 owns materialization.' }
$global:LASTEXITCODE = 0
& "$work/BuildRunActions.ps1" | Out-Null
if ($LASTEXITCODE -ne 0) { throw 'BuildRunActions.ps1 failed to materialize scripts from run-actions.manifest.json.' }
$resolved = $first | Where-Object uid -ceq $packageUid
# The same envelope assets/run-actions.js accepts: one complete paste unit, so execution and verification run together.
$completeScript = '\A& \{\r?\n#requires -Version 7\.0\r?\n[\s\S]*\r?\n\}\r?\n?\z'
$manifests = @(foreach ($transport in @('native','docker')) {
    $scriptText = Get-Content "$work/run-actions/$($resolved.id)/$transport.ps1" -Raw
    if ($scriptText -cnotmatch $completeScript) { throw "The generated $transport csrun script is not one complete script block." }
    if (-not $scriptText.Contains('Assert-CsrunTestOutput') -or $scriptText -cmatch 'RequirePassingTests|ManifestStdin') {
        throw "The generated $transport test script must verify MTP output without unsupported engine parameters."
    }
    Get-CsrunWrapperManifest $scriptText
})
$resolvedManifest = $manifests[0] | ConvertFrom-Json
if ($manifests[0] -cne $manifests[1] -or $resolved.sourceSha256 -cne $packageExample.sourceSha256 -or
    $resolved.executionSourceSha256 -cne $resolved.sourceSha256 -or $resolvedManifest.source -cne $packageSource.Replace("`r`n", "`n") -or
    -not $resolvedManifest.source.Contains('Assert.Equal("inventory", new CorrelationStore().Resolve())') -or
    ($resolvedManifest.dependsOn -join '|') -cne (($packagePins + 'xunit.v3@4.0.3') -join '|')) { throw 'The generated scripts changed the displayed C#, package pins or transport parity.' }
if ([IO.File]::ReadAllText("$work/docs/partial.md") -cne $partial) { throw 'An unsupported page with mixed line endings changed.' }
$consoleWithAssociation = [IO.File]::ReadAllText("$work/docs/console.md")
if (-not $consoleWithAssociation.StartsWith($console + "`n`n<!-- docfx-run-actions:start -->", [StringComparison]::Ordinal)) {
    throw 'An association changed existing mixed line endings or did not follow the final fence.'
}
$entry = $first | Where-Object { $_.uid -like '*ManagedApplicationFixture*' -and $_.file -match '[\\/]docs[\\/]integration.md$' }
foreach ($transport in @('native','docker')) {
    $script = Get-Content "$work/run-actions/$($entry.id)/$transport.ps1" -Raw
    if ($script -cnotmatch $completeScript) { throw "The generated $transport integration script is not one complete script block." }
    if (-not $script.Contains('84b13767cb9484f8f3a36a71875662edfdb3e511') -or -not $script.Contains('ShouldBootstrapMinimalWorkerProgram')) { throw 'Wrong pinned test.' }
    if ($entry.$transport -ne 'Unverified') { throw 'Generation claimed runtime verification.' }
}
$updated = Get-Content "$work/docs/integration.md" -Raw
if (-not $updated.Contains($source) -or -not $updated.Contains('[entry point]')) { throw 'Source/prose lost.' }
$association = [regex]::Match($updated, ('(?s)<div class="docfx-run-actions" data-example-id="' + [regex]::Escape($entry.id) + '">(?<links>.*?)</div>'))
$transports = @([regex]::Matches($association.Groups['links'].Value, 'data-transport="(native|docker)"') | ForEach-Object { $_.Groups[1].Value })
if (-not $association.Success -or $transports.Count -ne 2 -or 'native' -notin $transports -or 'docker' -notin $transports) {
    throw 'Both runnable assets must be delivered in one association with the same C# sample.'
}
if (-not (Get-Content "$work/template/public/main.js" -Raw).Contains('window.context7 = true')) { throw 'Existing template was overwritten.' }
$buildImageText = Get-Content "$work/BuildDocfxImage.ps1" -Raw
$expectedBuildImage = @(
    '$version = minver -i -t v -v w'
    'docfx metadata docfx.json'
    "& (Join-Path `$PSScriptRoot 'BuildRunActions.ps1')"
    'try {'
    '    docker buildx build -t xunit-docfx:$version --platform linux/arm64,linux/amd64 --load -f Dockerfile.docfx .'
    '}'
    'finally {'
    '    get-childItem -recurse -path api -include *.yml, .manifest | remove-item'
    "    if (Test-Path -LiteralPath (Join-Path `$PSScriptRoot 'run-actions')) {"
    "        Remove-Item -LiteralPath (Join-Path `$PSScriptRoot 'run-actions') -Recurse -Force"
    '    }'
    '}'
) -join "`n"
if ($buildImageText -cne ($expectedBuildImage + "`n")) {
    throw "Generator must rewrite an uncustomized BuildDocfxImage.ps1 to run BuildRunActions.ps1 and clean up run-actions in finally. Actual:`n$buildImageText"
}
$buildImageTokens = $null; $buildImageParseErrors = $null
$null = [Management.Automation.Language.Parser]::ParseInput($buildImageText, [ref]$buildImageTokens, [ref]$buildImageParseErrors)
if ($buildImageParseErrors.Count) { throw "Rewritten BuildDocfxImage.ps1 is not valid PowerShell: $buildImageParseErrors" }
$files = @(Get-ChildItem $work -Recurse -File)
$before = @{}
foreach ($file in $files) { $before[$file.FullName] = @((Get-FileHash $file.FullName).Hash, $file.LastWriteTimeUtc.Ticks) }
$second = (& $generator -RepoRoot $work) | ConvertFrom-Json
if (@($second | Where-Object status -eq 'unchanged').Count -ne 5) { throw 'Incremental generation failed.' }
foreach ($file in Get-ChildItem $work -Recurse -File) {
    if ($before[$file.FullName][0] -cne (Get-FileHash $file.FullName).Hash -or $before[$file.FullName][1] -ne $file.LastWriteTimeUtc.Ticks) { throw "Second run changed $($file.FullName)" }
}
# Mock only the fresh-process result and GitHub HTTP responses to exercise independent status bookkeeping and single-fetch engine caching offline.
$mockCacheDir = Join-Path $work 'mock-csrun-cache'
$previousCacheEnv = $env:CSRUN_CACHE_DIR
$env:CSRUN_CACHE_DIR = $mockCacheDir
$mockEngineContent = "param([string]`$ManifestJson)`n[Console]::Write(`$ManifestJson)"
$mockEngineSha = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($mockEngineContent))).ToLowerInvariant()
$mockVerifyState = @{
    ApiCalls = 0
    AssetCalls = 0
    StandaloneScripts = [Collections.Generic.List[string]]::new()
}
function Invoke-WebRequest {
    param([string] $Uri, [hashtable] $Headers, [switch] $SkipHttpErrorCheck, [string] $OutFile)
    if ($OutFile) {
        $mockVerifyState.AssetCalls++
        [IO.File]::WriteAllText($OutFile, $mockEngineContent, [Text.UTF8Encoding]::new($false))
        return
    }
    $mockVerifyState.ApiCalls++
    $body = @{
        tag_name = 'v0.2.1'
        assets = @(@{
            name = 'csrun.ps1'
            digest = "sha256:$mockEngineSha"
            browser_download_url = 'https://example.invalid/csrun.ps1'
        })
    } | ConvertTo-Json -Depth 5
    return [pscustomobject]@{ StatusCode = 200; Headers = @{ ETag = @('"mock-etag"') }; Content = $body }
}
function pwsh {
    $fileIndex = [Array]::IndexOf($args, '-File')
    if ($fileIndex -lt 0 -or [string]$args[$fileIndex + 1] -notmatch '-native-[a-f0-9]{32}\.ps1$') { throw 'The focused verification should invoke Native only.' }
    $executedText = [IO.File]::ReadAllText([string]$args[$fileIndex + 1])
    if ($executedText.Contains('Assert-CsrunTestOutput')) {
        $mockVerifyState.StandaloneScripts.Add($executedText)
    }
    $global:LASTEXITCODE = 0
}
try {
    $nativeOnly = (& $generator -RepoRoot $work -Verify Native) | ConvertFrom-Json
}
finally {
    Remove-Item Function:\pwsh -ErrorAction SilentlyContinue
    Remove-Item Function:\Invoke-WebRequest -ErrorAction SilentlyContinue
    $env:CSRUN_CACHE_DIR = $previousCacheEnv
    if (Test-Path -LiteralPath $mockCacheDir) { Remove-Item -LiteralPath $mockCacheDir -Recurse -Force }
}
if ($mockVerifyState.ApiCalls -ne 1 -or $mockVerifyState.AssetCalls -ne 1) {
    throw "Expected exactly one GitHub release lookup and one asset download across all standalone examples; got api=$($mockVerifyState.ApiCalls), asset=$($mockVerifyState.AssetCalls)."
}
if ($mockVerifyState.StandaloneScripts.Count -lt 3) {
    throw "Expected at least 3 standalone verification executions; got $($mockVerifyState.StandaloneScripts.Count)."
}
foreach ($executedStandalone in $mockVerifyState.StandaloneScripts) {
    if ($executedStandalone.Contains('api.github.com/repos/codebeltnet/csrun/releases/latest') -or -not $executedStandalone.Contains('csrun.ps1')) {
        throw 'Standalone verification script should execute the cached local csrun.ps1 rather than querying GitHub per example.'
    }
}
$publishedConsoleScript = Get-Content "$work/run-actions/$(($nativeOnly | Where-Object { $_.file -like '*console.md' }).id)/native.ps1" -Raw
if (-not $publishedConsoleScript.Contains('https://api.github.com/repos/codebeltnet/csrun/releases/latest')) {
    throw 'Published run-action script must still reference GitHub.'
}
$nativeOnlyEntry = $nativeOnly | Where-Object id -eq $entry.id
if ($nativeOnlyEntry.native -ne 'Verified' -or $nativeOnlyEntry.docker -ne 'Unverified') {
    throw 'Successful Native verification must not mark the unexecuted Docker transport Verified.'
}
$toolbarSource = Join-Path $PSScriptRoot '../assets/run-actions.js'
$toolbarModule = "$work/template/public/run-actions.js"
$toolbarHash = (Get-FileHash $toolbarSource).Hash
[IO.File]::WriteAllText($toolbarModule, '// Stale toolbar from a previous skill revision.')
$refresh = (& $generator -RepoRoot $work) | ConvertFrom-Json
if ((Get-FileHash $toolbarModule).Hash -cne $toolbarHash -or
    @($refresh | Where-Object status -eq 'unchanged').Count -ne 5) {
    throw 'Refreshing a stale toolbar must preserve the manifest payloads.'
}
$refreshEntry = $refresh | Where-Object id -eq $entry.id
if ($refreshEntry.native -ne 'Verified' -or $refreshEntry.docker -ne 'Unverified' -or
    $refreshEntry.nativeEvidence -cne $nativeOnlyEntry.nativeEvidence -or -not (Test-Path -LiteralPath $refreshEntry.nativeEvidence)) {
    throw 'Toolbar refresh lost independent verification evidence.'
}
$cacheDirectory = Split-Path $refreshEntry.nativeEvidence -Parent
$cacheRecord = Get-ChildItem -LiteralPath $cacheDirectory -Filter "*-$($entry.id)-native-$($refreshEntry.nativeSha256).json" |
    Where-Object { ([IO.File]::ReadAllText($_.FullName) | ConvertFrom-Json).log -eq (Split-Path $refreshEntry.nativeEvidence -Leaf) } |
    Select-Object -First 1
if (-not $cacheRecord) { throw 'Verification record and log must share the private cache.' }
$consoleVerifiedEntry = $refresh | Where-Object { $_.file -like '*console.md' }
$consoleCacheRecord = Get-ChildItem -LiteralPath $cacheDirectory -Filter "*-$($consoleVerifiedEntry.id)-native-$($consoleVerifiedEntry.nativeSha256).json" |
    Where-Object { ([IO.File]::ReadAllText($_.FullName) | ConvertFrom-Json).log -eq (Split-Path $consoleVerifiedEntry.nativeEvidence -Leaf) } |
    Select-Object -First 1
$consoleEvidenceMeta = if ($consoleCacheRecord) { [IO.File]::ReadAllText($consoleCacheRecord.FullName) | ConvertFrom-Json } else { $null }
if (-not $consoleEvidenceMeta -or $consoleEvidenceMeta.engineTag -cne 'v0.2.1' -or $consoleEvidenceMeta.engineSha256 -cne $mockEngineSha.ToUpperInvariant()) {
    throw 'Standalone verification evidence must record the verified cached engine tag and SHA-256.'
}
$originalRecord = [IO.File]::ReadAllText($cacheRecord.FullName)
$outsideLog = Join-Path $work (Split-Path $refreshEntry.nativeEvidence -Leaf)
[IO.File]::WriteAllText($outsideLog, 'untrusted verification log')
try {
    [IO.File]::WriteAllText($cacheRecord.FullName, (@{ state = 'Verified'; log = $outsideLog } | ConvertTo-Json))
    $untrusted = ((& $generator -RepoRoot $work) | ConvertFrom-Json) | Where-Object id -eq $entry.id
    if ($untrusted.native -ne 'Unverified' -or $untrusted.nativeEvidence) { throw 'Verification trusted a log outside the private cache.' }

    [IO.File]::WriteAllText($cacheRecord.FullName, $originalRecord)
    $linkedLog = Join-Path $cacheDirectory ('linked-' + [guid]::NewGuid().ToString('N') + '.log')
    $null = New-Item -ItemType HardLink -Path $linkedLog -Target $refreshEntry.nativeEvidence
    try {
        $untrusted = ((& $generator -RepoRoot $work) | ConvertFrom-Json) | Where-Object id -eq $entry.id
        if ($untrusted.native -ne 'Unverified' -or $untrusted.nativeEvidence) { throw 'Verification trusted a hard-linked log.' }
    } finally { [IO.File]::Delete($linkedLog) }
} finally { [IO.File]::WriteAllText($cacheRecord.FullName, $originalRecord) }
# Explicit -EnginePath runs standalone verification with zero GitHub API calls.
$explicitEnginePath = Join-Path $work 'explicit-csrun.ps1'
[IO.File]::WriteAllText($explicitEnginePath, $mockEngineContent, [Text.UTF8Encoding]::new($false))
$explicitVerifyState = @{ ApiCalls = 0 }
function Invoke-WebRequest { $explicitVerifyState.ApiCalls++; throw 'Explicit -EnginePath must not contact GitHub.' }
function pwsh {
    $fileIndex = [Array]::IndexOf($args, '-File')
    $executedText = [IO.File]::ReadAllText([string]$args[$fileIndex + 1])
    if ($executedText.Contains('Assert-CsrunTestOutput') -and -not $executedText.Contains($explicitEnginePath)) {
        throw 'Explicit -EnginePath was not passed to standalone verification.'
    }
    $global:LASTEXITCODE = 0
}
try {
    $null = (& $generator -RepoRoot $work -Verify Native -EnginePath $explicitEnginePath) | ConvertFrom-Json
}
finally {
    Remove-Item Function:\pwsh -ErrorAction SilentlyContinue
    Remove-Item Function:\Invoke-WebRequest -ErrorAction SilentlyContinue
    if (Test-Path -LiteralPath $explicitEnginePath) { Remove-Item -LiteralPath $explicitEnginePath -Force }
}
if ($explicitVerifyState.ApiCalls -ne 0) { throw 'Explicit -EnginePath contacted GitHub.' }
foreach ($script in Get-ChildItem "$work/run-actions" -Filter '*.ps1' -Recurse -File) {
    if ($before[$script.FullName][0] -cne (Get-FileHash $script.FullName).Hash -or
        $before[$script.FullName][1] -ne $script.LastWriteTimeUtc.Ticks) {
        throw "Toolbar refresh rewrote $($script.FullName)"
    }
}
# Actual DocFX render checks tilde links, publishing, modern template composition and C# fidelity.
& (Get-Command docfx -CommandType Application | Select-Object -First 1).Source build "$work/docfx.json" --disableGitFeatures *> "$work/build.log"
if ($LASTEXITCODE -ne 0) { throw "DocFX render failed: $work/build.log" }
$html = Get-Content "$work/_site/docs/integration.html" -Raw
if (-not $html.Contains('data-example-id=') -or -not $html.Contains('View Native Script') -or -not $html.Contains('View Docker Script') -or
    -not (Test-Path "$work/_site/run-actions/$($entry.id)/native.ps1") -or -not (Test-Path "$work/_site/run-actions/$($entry.id)/docker.ps1")) {
    throw 'The rendered sample must deliver links to both published script assets.'
}
if (-not (Get-Content "$work/_site/public/main.js" -Raw).Contains("import './run-actions.js'")) { throw 'Modern template module not published.' }
if ((Get-FileHash "$work/_site/public/run-actions.js").Hash -cne $toolbarHash) { throw 'Refreshed toolbar module not published.' }
$apiHtml = Get-ChildItem "$work/_site/api" -Filter '*.html' | Select-Object -First 1 | Get-Content -Raw
if (-not $apiHtml.Contains('View Native Script') -or -not $apiHtml.Contains('View Docker Script') -or -not $apiHtml.Contains('ShouldBootstrapMinimalWorkerProgram')) { throw 'Paired overwrite example association did not survive API rendering.' }
$overwriteBytes = [IO.File]::ReadAllBytes("$work/api/types/ManagedApplicationFixture-1.md")
if ([Convert]::ToHexString($overwriteBytes[0..2]) -ne 'EFBBBF') { throw 'Overwrite BOM lost.' }
$overwriteText = [IO.File]::ReadAllText("$work/api/types/ManagedApplicationFixture-1.md")
if ($overwriteText.Replace("`r`n", '').Contains("`n") -or -not $overwriteText.Contains("example:`r`n  - *content")) { throw 'Overwrite mapping/line endings changed.' }
# A real platform limitation may suppress only Docker, without suppressing valid native generation.
$settings = [ordered]@{ examples=@($packageRecipe, [ordered]@{
    uid=$entry.uid; sourceSha256=$entry.sourceSha256; repository='codebeltnet/xunit'; commit='84b13767cb9484f8f3a36a71875662edfdb3e511'
    project='test/Codebelt.Extensions.Xunit.Hosting.FunctionalTests/Codebelt.Extensions.Xunit.Hosting.FunctionalTests.csproj'
    test='Codebelt.Extensions.Xunit.Hosting.BootstrapperMinimalWorkerApplicationTestTest.ShouldBootstrapMinimalWorkerProgram'
    framework='net11.0'; image='mcr.microsoft.com/dotnet/sdk:11.0'
    unsupportedTransports=@{ docker='Synthetic platform limitation for deterministic transport-selection regression.' }
}) }
[IO.File]::WriteAllText("$work/run-actions.settings.json", ($settings | ConvertTo-Json -Depth 20))
$limited = (& $generator -RepoRoot $work) | ConvertFrom-Json
$limitedEntry = $limited | Where-Object id -eq $entry.id
$global:LASTEXITCODE = 0
& "$work/BuildRunActions.ps1" | Out-Null
if ($LASTEXITCODE -ne 0) { throw 'BuildRunActions.ps1 failed after single-transport update.' }
if ($limitedEntry.coverage -ne 'Partially supported' -or $limitedEntry.docker -ne 'Unsupported' -or -not (Test-Path "$work/run-actions/$($entry.id)/native.ps1") -or (Test-Path "$work/run-actions/$($entry.id)/docker.ps1")) { throw 'Single-transport limitation was misrepresented.' }
if ((Get-Content "$work/docs/integration.md" -Raw).Contains('View Docker Script')) { throw 'Unsupported Docker still has a control.' }
$limitedAgain = (& $generator -RepoRoot $work) | ConvertFrom-Json
if (($limitedAgain | Where-Object id -eq $entry.id).status -ne 'unchanged') { throw 'Single-transport cache requires the unsupported script.' }

# Standalone BuildRunActions.ps1 materializes byte-identical native/docker scripts from run-actions.manifest.json
# (including recipe-provided standalone manifests with custom package pins and single-transport examples) and prunes stale generated scripts.
if (-not (Test-Path "$work/run-actions.manifest.json") -or -not (Test-Path "$work/BuildRunActions.ps1")) {
    throw 'Generator must emit run-actions.manifest.json and BuildRunActions.ps1 beside docfx.json.'
}
$expectedHashes = @{}
foreach ($example in $limitedAgain) {
    foreach ($transport in @('native', 'docker')) {
        $hash = $example."${transport}Sha256"
        if ($hash) { $expectedHashes["$($example.id)/$transport.ps1"] = $hash }
    }
}
if (-not $expectedHashes.ContainsKey("$($resolved.id)/native.ps1") -or
    -not $expectedHashes.ContainsKey("$($resolved.id)/docker.ps1") -or
    -not $expectedHashes.ContainsKey("$($entry.id)/native.ps1") -or
    $expectedHashes.ContainsKey("$($entry.id)/docker.ps1")) {
    throw 'Expected recipe-backed standalone scripts and single-transport repository script before testing standalone materializer.'
}
$assetsOnlyPage = "$work/docs/console.md"
$pageBefore = [IO.File]::ReadAllText($assetsOnlyPage)
$configBefore = [IO.File]::ReadAllText("$work/docfx.json")
Get-ChildItem -LiteralPath "$work/run-actions" -Directory | Remove-Item -Recurse -Force
$staleExampleDir = "$work/run-actions/deadbeefdeadbeefdeadbeef"
$null = [IO.Directory]::CreateDirectory($staleExampleDir)
[IO.File]::WriteAllText("$staleExampleDir/native.ps1", '# stale example native')
[IO.File]::WriteAllText("$staleExampleDir/docker.ps1", '# stale example docker')
$staleTransportDir = "$work/run-actions/$($entry.id)"
$null = [IO.Directory]::CreateDirectory($staleTransportDir)
$staleTransportPath = "$staleTransportDir/docker.ps1"
[IO.File]::WriteAllText($staleTransportPath, '# stale transport')
$unrelatedRootFile = "$work/run-actions/unrelated.txt"
[IO.File]::WriteAllText($unrelatedRootFile, 'keep root')
$unrelatedDir = "$work/run-actions/custom"
$null = [IO.Directory]::CreateDirectory($unrelatedDir)
$unrelatedDirScript = "$unrelatedDir/native.ps1"
[IO.File]::WriteAllText($unrelatedDirScript, '# unrelated script')
$mixedExampleDir = "$work/run-actions/0123456789abcdef01234567"
$null = [IO.Directory]::CreateDirectory($mixedExampleDir)
[IO.File]::WriteAllText("$mixedExampleDir/native.ps1", '# stale mixed native')
$mixedKeepFile = "$mixedExampleDir/keep.txt"
[IO.File]::WriteAllText($mixedKeepFile, 'keep inside example dir')
$global:LASTEXITCODE = 0
& "$work/BuildRunActions.ps1" | Out-Null
if ($LASTEXITCODE -ne 0) { throw 'Standalone BuildRunActions.ps1 failed.' }
if ((Test-Path -LiteralPath $staleExampleDir) -or
    (Test-Path -LiteralPath $staleTransportPath) -or
    (Test-Path -LiteralPath "$mixedExampleDir/native.ps1")) {
    throw 'BuildRunActions.ps1 left stale generated scripts or empty stale directories behind.'
}
if (-not (Test-Path -LiteralPath $unrelatedRootFile) -or
    -not (Test-Path -LiteralPath $unrelatedDirScript) -or
    -not (Test-Path -LiteralPath $mixedKeepFile)) {
    throw 'BuildRunActions.ps1 deleted unrelated files.'
}
Remove-Item -LiteralPath $unrelatedRootFile, $unrelatedDir, $mixedExampleDir -Recurse -Force
$actualFiles = @(Get-ChildItem -Path "$work/run-actions" -Recurse -Filter '*.ps1')
if ($actualFiles.Count -ne $expectedHashes.Count) { throw "BuildRunActions.ps1 produced $($actualFiles.Count) scripts; expected $($expectedHashes.Count)." }
foreach ($psFile in $actualFiles) {
    $rel = [IO.Path]::GetRelativePath("$work/run-actions", $psFile.FullName).Replace('\', '/')
    $actualHash = (Get-FileHash -LiteralPath $psFile.FullName -Algorithm SHA256).Hash
    if ($expectedHashes[$rel] -cne $actualHash) { throw "BuildRunActions.ps1 drifted from generator output for $rel." }
}
if ([IO.File]::ReadAllText($assetsOnlyPage) -cne $pageBefore -or [IO.File]::ReadAllText("$work/docfx.json") -cne $configBefore) {
    throw 'BuildRunActions.ps1 must not modify Markdown or docfx.json.'
}
$noManifestDir = Join-Path $work 'no-manifest'
$null = [IO.Directory]::CreateDirectory($noManifestDir)
Copy-Item -LiteralPath "$work/BuildRunActions.ps1" -Destination (Join-Path $noManifestDir 'BuildRunActions.ps1')
$global:LASTEXITCODE = 0
& (Join-Path $noManifestDir 'BuildRunActions.ps1') | Out-Null
if ($LASTEXITCODE -ne 0 -or (Test-Path (Join-Path $noManifestDir 'run-actions'))) {
    throw 'BuildRunActions.ps1 must no-op cleanly when no default run-actions.manifest.json exists.'
}

# A changed script under the same example ID must discard that transport's verification.
$retargeted = (& $generator -RepoRoot $work -Framework net9.0) | ConvertFrom-Json
$verifiedConsole = $nativeOnly | Where-Object { $_.file -like '*console.md' }
$retargetedConsole = $retargeted | Where-Object id -eq $verifiedConsole.id
if (-not $retargetedConsole.nativeSha256 -or $retargetedConsole.nativeSha256 -ceq $verifiedConsole.nativeSha256 -or
    $retargetedConsole.native -ne 'Unverified' -or $retargetedConsole.nativeEvidence) {
    throw 'A changed Native script reused stale verification evidence.'
}

# Mutating the principal source invalidates its recipe and removes both associations and manifest entries.
[IO.File]::WriteAllText("$work/docs/integration.md", $updated.Replace('Bootstrapper Minimal Worker', 'Changed assertion'))
$third = (& $generator -RepoRoot $work) | ConvertFrom-Json
$global:LASTEXITCODE = 0
& "$work/BuildRunActions.ps1" | Out-Null
if ((Test-Path "$work/run-actions/$($entry.id)/native.ps1") -or (Get-Content "$work/docs/integration.md" -Raw).Contains('data-example-id')) { throw 'Stale recipe/assets survived source change.' }

# Deleting the only fence must remove its association even when the page no longer has inventory entries.
$consolePage = "$work/docs/console.md"
$consoleWithActions = [IO.File]::ReadAllText($consolePage)
[IO.File]::WriteAllText($consolePage, [regex]::Replace($consoleWithActions, '(?s)\x60{3}csharp.*?\x60{3}', ''))
$withoutConsole = (& $generator -RepoRoot $work) | ConvertFrom-Json
if (($withoutConsole | Where-Object file -eq $consolePage) -or [IO.File]::ReadAllText($consolePage).Contains('docfx-run-actions:start')) {
    throw 'Removing the last C# fence left a stale association.'
}
[IO.File]::WriteAllText($consolePage, $consoleWithActions)

# A legacy hidden harness is a failed recipe, while an intrinsic limitation has no assets.
$invalidRecipe = $packageRecipe | ConvertTo-Json -Depth 20 | ConvertFrom-Json -AsHashtable
$invalidRecipe.harness = @{members='public sealed class HiddenTest { [Fact] public void Hidden() {} }'}
$partialResult = $discovery | Where-Object { $_.file -match '[\\/]partial\.md$' }
$intrinsic = @{uid=$partialResult.uid; sourceSha256=$partialResult.sourceSha256; intrinsicLimitation='Synthetic limitation for coverage classification.'}
$customSettings = "$work/custom-settings.json"
[IO.File]::WriteAllText($customSettings, (@{examples=@($invalidRecipe,$intrinsic)} | ConvertTo-Json -Depth 20))
$classified = (& $generator -RepoRoot $work -Settings $customSettings) | ConvertFrom-Json
$classifiedExit = $LASTEXITCODE
$global:LASTEXITCODE = 0
& "$work/BuildRunActions.ps1" | Out-Null
$invalid = $classified | Where-Object id -eq $resolved.id
$limitedPartial = $classified | Where-Object id -eq $partialResult.id
if ($classifiedExit -ne 1 -or $invalid.coverage -ne 'Unresolved' -or $invalid.reason -notlike '*Move the executable C# into the displayed sample*' -or
    (Test-Path "$work/run-actions/$($resolved.id)/native.ps1") -or (Test-Path "$work/run-actions/$($resolved.id)/docker.ps1") -or
    $limitedPartial.coverage -ne 'Intrinsically non-executable' -or $limitedPartial.native -ne 'Unsupported' -or
    $limitedPartial.docker -ne 'Unsupported' -or (Test-Path "$work/run-actions/$($limitedPartial.id)/native.ps1")) {
    throw 'A malformed recipe or demonstrated intrinsic limitation was misclassified.'
}

# Model discovery through an external DocFX source mapping, with a case-only sibling path.
$guardRoot = Join-Path $work 'repo'
$otherRoot = Join-Path $work 'Repo'
$null = [IO.Directory]::CreateDirectory($guardRoot)
$null = [IO.Directory]::CreateDirectory($otherRoot)
$guardConfig = Join-Path $guardRoot 'docfx.json'
$externalPage = Join-Path $otherRoot 'external.md'
[IO.File]::WriteAllText($guardConfig, '{"build":{"template":["default","modern"]}}')
[IO.File]::WriteAllText($externalPage, $console)
$inventoryOverride = @{
    config = $guardConfig
    examples = @(@{ file = $externalPage; code = 'System.Console.WriteLine(42);'; startLine = 3; standalone = $true; eligible = $true })
} | ConvertTo-Json -Depth 5
try {
    try {
        $null = & $generator -RepoRoot $guardRoot
        throw 'The case-mismatched inventory path was accepted.'
    } catch {
        if ($_.Exception.Message -cne "Path outside requested repository: $externalPage") { throw }
    }
    if ([IO.File]::ReadAllText($externalPage) -cne $console) { throw 'Rejected inventory changed the external page.' }
} finally { $inventoryOverride = $null }

# Verify BuildDocfxImage.ps1 variants: standard try/finally, partially-wired CRLF flat script, customized scripts (flat, existing try/finally, try/catch, multiline docker build), and non-docker wrapper preservation.
$buildImageVariants = @(
    @{
        Name = 'already-try-finally'
        Input = "`$version = minver -i -t v -v w`ndocfx metadata docfx.json`ntry {`n    docker buildx build -t sample-docfx:`$version --platform linux/arm64,linux/amd64 --load -f Dockerfile.docfx .`n}`nfinally {`n    Get-ChildItem -Recurse -Path api -Include *.yml, .manifest | Remove-Item`n}`n"
        Expected = @(
            '$version = minver -i -t v -v w'
            'docfx metadata docfx.json'
            "& (Join-Path `$PSScriptRoot 'BuildRunActions.ps1')"
            'try {'
            '    docker buildx build -t sample-docfx:$version --platform linux/arm64,linux/amd64 --load -f Dockerfile.docfx .'
            '}'
            'finally {'
            '    Get-ChildItem -Recurse -Path api -Include *.yml, .manifest | Remove-Item'
            "    if (Test-Path -LiteralPath (Join-Path `$PSScriptRoot 'run-actions')) {"
            "        Remove-Item -LiteralPath (Join-Path `$PSScriptRoot 'run-actions') -Recurse -Force"
            '    }'
            '}'
        ) -join "`n"
        Trailing = "`n"
    }
    @{
        Name = 'partially-wired-crlf'
        Input = "`$version = minver -i -t v -v w`r`ndocfx metadata docfx.json`r`n& (Join-Path `$PSScriptRoot 'BuildRunActions.ps1')`r`ndocker buildx build -t xunit-docfx:`$version --platform linux/arm64,linux/amd64 --load -f Dockerfile.docfx .`r`nget-childItem -recurse -path api -include *.yml, .manifest | remove-item`r`n"
        Expected = @(
            '$version = minver -i -t v -v w'
            'docfx metadata docfx.json'
            "& (Join-Path `$PSScriptRoot 'BuildRunActions.ps1')"
            'try {'
            '    docker buildx build -t xunit-docfx:$version --platform linux/arm64,linux/amd64 --load -f Dockerfile.docfx .'
            '}'
            'finally {'
            '    get-childItem -recurse -path api -include *.yml, .manifest | remove-item'
            "    if (Test-Path -LiteralPath (Join-Path `$PSScriptRoot 'run-actions')) {"
            "        Remove-Item -LiteralPath (Join-Path `$PSScriptRoot 'run-actions') -Recurse -Force"
            '    }'
            '}'
        ) -join "`r`n"
        Trailing = "`r`n"
    }
    @{
        Name = 'customized-flat'
        Input = "param([string] `$Registry = 'ghcr.io/example')`n`$version = minver -i -t v -v w`nWrite-Host `"Building `$Registry/docs:`$version`"`n# & (Join-Path `$PSScriptRoot 'BuildRunActions.ps1')`ndocfx metadata docfx.json`ndocker buildx build -t `"`$Registry/docs:`$version`" -f Dockerfile.docfx .`nget-childItem -recurse -path api -include *.yml, .manifest | remove-item`n"
        Expected = @(
            "param([string] `$Registry = 'ghcr.io/example')"
            '$version = minver -i -t v -v w'
            'Write-Host "Building $Registry/docs:$version"'
            "# & (Join-Path `$PSScriptRoot 'BuildRunActions.ps1')"
            'docfx metadata docfx.json'
            "& (Join-Path `$PSScriptRoot 'BuildRunActions.ps1')"
            'try {'
            '    docker buildx build -t "$Registry/docs:$version" -f Dockerfile.docfx .'
            '}'
            'finally {'
            '    get-childItem -recurse -path api -include *.yml, .manifest | remove-item'
            "    if (Test-Path -LiteralPath (Join-Path `$PSScriptRoot 'run-actions')) {"
            "        Remove-Item -LiteralPath (Join-Path `$PSScriptRoot 'run-actions') -Recurse -Force"
            '    }'
            '}'
        ) -join "`n"
        Trailing = "`n"
    }
    @{
        Name = 'customized-try-finally'
        Input = "param([string] `$Tag = 'dev')`ndocfx metadata docfx.json`ntry {`n    Write-Host `"Start `$Tag`"`n    docker buildx build -t `"custom:`$Tag`" -f Dockerfile.docfx .`n}`nfinally {`n    get-childItem -recurse -path api -include *.yml, .manifest | remove-item`n    Write-Host 'Done'`n}`n"
        Expected = @(
            "param([string] `$Tag = 'dev')"
            'docfx metadata docfx.json'
            "& (Join-Path `$PSScriptRoot 'BuildRunActions.ps1')"
            'try {'
            '    Write-Host "Start $Tag"'
            '    docker buildx build -t "custom:$Tag" -f Dockerfile.docfx .'
            '}'
            'finally {'
            '    get-childItem -recurse -path api -include *.yml, .manifest | remove-item'
            "    Write-Host 'Done'"
            "    if (Test-Path -LiteralPath (Join-Path `$PSScriptRoot 'run-actions')) {"
            "        Remove-Item -LiteralPath (Join-Path `$PSScriptRoot 'run-actions') -Recurse -Force"
            '    }'
            '}'
        ) -join "`n"
        Trailing = "`n"
    }
    @{
        Name = 'customized-try-catch'
        Input = "`$version = minver -i -t v -v w`ndocfx metadata docfx.json`ntry {`n    docker buildx build -t custom-docfx:`$version -f Dockerfile.docfx .`n}`ncatch {`n    Write-Error `$_`n    throw`n}`n"
        Expected = @(
            '$version = minver -i -t v -v w'
            'docfx metadata docfx.json'
            "& (Join-Path `$PSScriptRoot 'BuildRunActions.ps1')"
            'try {'
            '    docker buildx build -t custom-docfx:$version -f Dockerfile.docfx .'
            '}'
            'catch {'
            '    Write-Error $_'
            '    throw'
            '}'
            'finally {'
            "    if (Test-Path -LiteralPath (Join-Path `$PSScriptRoot 'run-actions')) {"
            "        Remove-Item -LiteralPath (Join-Path `$PSScriptRoot 'run-actions') -Recurse -Force"
            '    }'
            '}'
        ) -join "`n"
        Trailing = "`n"
    }
    @{
        Name = 'customized-multiline-poststep'
        Input = "param([string] `$Tag = 'latest')`ndocfx metadata docfx.json`ndocker buildx build ```n    -t `"custom-docs:`$Tag`" ```n    -f Dockerfile.docfx .`nWrite-Host `"Built `$Tag`"`n"
        Expected = @(
            "param([string] `$Tag = 'latest')"
            'docfx metadata docfx.json'
            "& (Join-Path `$PSScriptRoot 'BuildRunActions.ps1')"
            'try {'
            '    docker buildx build `'
            '        -t "custom-docs:$Tag" `'
            '        -f Dockerfile.docfx .'
            '}'
            'finally {'
            "    if (Test-Path -LiteralPath (Join-Path `$PSScriptRoot 'run-actions')) {"
            "        Remove-Item -LiteralPath (Join-Path `$PSScriptRoot 'run-actions') -Recurse -Force"
            '    }'
            '}'
            'Write-Host "Built $Tag"'
        ) -join "`n"
        Trailing = "`n"
    }
    @{
        Name = 'customized-non-docker'
        Input = "param([string] `$Env = 'prod')`n& (Join-Path `$PSScriptRoot 'CustomPipeline.ps1') -Env `$Env`n"
        Expected = "param([string] `$Env = 'prod')`n& (Join-Path `$PSScriptRoot 'CustomPipeline.ps1') -Env `$Env"
        Trailing = "`n"
    }
)
foreach ($variant in $buildImageVariants) {
    $variantRoot = Join-Path $work ("build-image-" + $variant.Name)
    $null = [IO.Directory]::CreateDirectory($variantRoot)
    $variantConfig = Join-Path $variantRoot 'docfx.json'
    $variantScript = Join-Path $variantRoot 'BuildDocfxImage.ps1'
    [IO.File]::WriteAllText($variantConfig, '{"build":{"template":["default","modern"]}}')
    [IO.File]::WriteAllText($variantScript, $variant.Input)
    $inventoryOverride = @{ config = $variantConfig; examples = @() } | ConvertTo-Json -Depth 5
    try {
        $null = & $generator -RepoRoot $variantRoot
        if ($LASTEXITCODE -ne 0) { throw "Generator failed for BuildDocfxImage variant $($variant.Name)." }
        $actualVariant = [IO.File]::ReadAllText($variantScript)
        if ($actualVariant -cne ($variant.Expected + $variant.Trailing)) {
            throw "BuildDocfxImage variant $($variant.Name) did not match expected output. Actual:`n$actualVariant"
        }
        $vTokens = $null; $vErrors = $null
        $null = [Management.Automation.Language.Parser]::ParseInput($actualVariant, [ref]$vTokens, [ref]$vErrors)
        if ($vErrors.Count) { throw "BuildDocfxImage variant $($variant.Name) produced invalid PowerShell: $vErrors" }
        $beforeHash = (Get-FileHash $variantScript).Hash
        $beforeTicks = (Get-Item $variantScript).LastWriteTimeUtc.Ticks
        $null = & $generator -RepoRoot $variantRoot
        if ($LASTEXITCODE -ne 0 -or (Get-FileHash $variantScript).Hash -cne $beforeHash -or (Get-Item $variantScript).LastWriteTimeUtc.Ticks -ne $beforeTicks) {
            throw "BuildDocfxImage variant $($variant.Name) was not idempotent on second run."
        }
    } finally { $inventoryOverride = $null }
}

# Template ordering: templates/modern must come before templates/ms-style, with templates/ms-style always last.
$templateOrderCases = @(
    @{
        Name = 'ms-style-without-modern'
        Initial = @('default', 'modern', 'templates/ms-style')
        CreateModernMain = $false
        Expected = @('default', 'modern', 'templates/modern', 'templates/ms-style')
    }
    @{
        Name = 'ms-style-before-existing-modern'
        Initial = @('default', 'modern', 'templates/ms-style', 'templates/modern')
        CreateModernMain = $true
        Expected = @('default', 'modern', 'templates/modern', 'templates/ms-style')
    }
)
foreach ($case in $templateOrderCases) {
    $caseRoot = Join-Path $work ("template-order-" + $case.Name)
    $null = [IO.Directory]::CreateDirectory($caseRoot)
    $caseConfig = Join-Path $caseRoot 'docfx.json'
    [IO.File]::WriteAllText($caseConfig, (@{ build = @{ template = $case.Initial } } | ConvertTo-Json -Depth 5 -Compress))
    if ($case.CreateModernMain) {
        $modernPublic = Join-Path $caseRoot 'templates/modern/public'
        $null = [IO.Directory]::CreateDirectory($modernPublic)
        [IO.File]::WriteAllText((Join-Path $modernPublic 'main.js'), "export default {};`n")
    }
    $inventoryOverride = @{ config = $caseConfig; examples = @() } | ConvertTo-Json -Depth 5
    try {
        $null = & $generator -RepoRoot $caseRoot
        if ($LASTEXITCODE -ne 0) { throw "Generator failed for template-order case $($case.Name)." }
        $actualTemplates = @((Get-Content $caseConfig -Raw | ConvertFrom-Json).build.template)
        if (($actualTemplates -join ',') -cne ($case.Expected -join ',')) {
            throw "Template order case $($case.Name) expected [$($case.Expected -join ', ')], got [$($actualTemplates -join ', ')]."
        }
    } finally { $inventoryOverride = $null }
}

# ===========================================================================
# Deterministic run-action workflow regression (all 8 blockers & CLI surface)
# ===========================================================================
$detRoot = Join-Path $work 'deterministic-workflow'
$null = [IO.Directory]::CreateDirectory("$detRoot/docs")
$null = [IO.Directory]::CreateDirectory("$detRoot/src/Acme.Net")
$null = [IO.Directory]::CreateDirectory("$detRoot/src/Acme.Internal")
$null = [IO.Directory]::CreateDirectory("$detRoot/src/Acme.Xml")
$null = [IO.Directory]::CreateDirectory("$detRoot/src/Acme.AppSubtree")

[IO.File]::WriteAllText("$detRoot/Directory.Packages.props", @'
<Project>
  <PropertyGroup><ManagePackageVersionsCentrally>true</ManagePackageVersionsCentrally></PropertyGroup>
  <ItemGroup>
    <PackageVersion Include="Shared.Telemetry" Version="2.1.0" />
  </ItemGroup>
</Project>
'@)

[IO.File]::WriteAllText("$detRoot/src/Acme.AppSubtree/Directory.Build.props", @'
<Project>
  <PropertyGroup>
    <IsPackable>false</IsPackable>
    <Version>99.0.0</Version>
  </PropertyGroup>
</Project>
'@)
[IO.File]::WriteAllText("$detRoot/src/Acme.AppSubtree/Directory.Packages.props", @'
<Project>
  <PropertyGroup><ManagePackageVersionsCentrally>true</ManagePackageVersionsCentrally></PropertyGroup>
  <ItemGroup>
    <PackageVersion Include="Shared.Telemetry" Version="9.9.9" />
  </ItemGroup>
</Project>
'@)
[IO.File]::WriteAllText("$detRoot/src/Acme.AppSubtree/Acme.AppSubtree.csproj", @'
<Project Sdk="Microsoft.NET.Sdk">
  <PropertyGroup>
    <TargetFramework>net10.0</TargetFramework>
  </PropertyGroup>
  <ItemGroup>
    <PackageReference Include="Shared.Telemetry" />
  </ItemGroup>
</Project>
'@)
[IO.File]::WriteAllText("$detRoot/src/Acme.AppSubtree/AppOnlyHelper.cs", @'
namespace Acme.AppSubtree;
public sealed class AppOnlyHelper { }
'@)

[IO.File]::WriteAllText("$detRoot/src/Acme.Net/Acme.Net.csproj", @'
<Project Sdk="Microsoft.NET.Sdk">
  <PropertyGroup>
    <TargetFramework>net10.0</TargetFramework>
    <PackageId>Acme.Net</PackageId>
    <Version>11.0.0</Version>
  </PropertyGroup>
  <ItemGroup>
    <PackageReference Include="Shared.Telemetry" />
  </ItemGroup>
</Project>
'@)
[IO.File]::WriteAllText("$detRoot/src/Acme.Net/HttpManager.cs", @'
namespace Acme.Net.Http;
public sealed class HttpManager { }
'@)

[IO.File]::WriteAllText("$detRoot/src/Acme.Internal/Acme.Internal.csproj", @'
<Project Sdk="Microsoft.NET.Sdk">
  <PropertyGroup>
    <TargetFramework>net10.0</TargetFramework>
    <IsPackable>false</IsPackable>
  </PropertyGroup>
</Project>
'@)
[IO.File]::WriteAllText("$detRoot/src/Acme.Internal/SecretHelper.cs", @'
namespace Acme.Internal;
public sealed class SecretHelper { }
'@)

[IO.File]::WriteAllText("$detRoot/src/Acme.Xml/Acme.Xml.csproj", @'
<Project Sdk="Microsoft.NET.Sdk">
  <PropertyGroup>
    <TargetFramework>net10.0</TargetFramework>
    <PackageId>Acme.Xml</PackageId>
    <Version>11.0.0</Version>
  </PropertyGroup>
</Project>
'@)
[IO.File]::WriteAllText("$detRoot/src/Acme.Xml/XmlConvert.cs", @'
namespace Acme.Xml.Serialization;
public static class XmlConvert { }
'@)

[IO.File]::WriteAllText("$detRoot/docfx.json", (@{
    metadata = @(@{
        src = @(@{ files = @('src/Acme.Net/Acme.Net.csproj', 'src/Acme.Internal/Acme.Internal.csproj', 'src/Acme.Xml/Acme.Xml.csproj') })
        properties = @{ TargetFramework = 'net10.0' }
    })
    build = @{
        content = @(@{ files = @('docs/*.md') })
        template = @('default', 'modern')
        dest = '_site'
    }
} | ConvertTo-Json -Depth 10))

$cleanWrapperMd = @"
---
uid: Demo.WrapperClean
---
# Clean wrapper

``````csharp
using System;

public sealed class CleanExample
{
    public void Demonstrate()
    {
        Console.WriteLine("clean ok");
    }
}
``````
"@
[IO.File]::WriteAllText("$detRoot/docs/WrapperClean.md", $cleanWrapperMd)

$asyncExprWrapperMd = @"
---
uid: Demo.AsyncExprWrapper
---
# Async expression-bodied wrapper

``````csharp
using System;
using System.Threading.Tasks;

public sealed class AsyncExprExample
{
    public async Task<int> DemonstrateAsync() => await Task.FromResult(42);
}
``````
"@
[IO.File]::WriteAllText("$detRoot/docs/AsyncExprWrapper.md", $asyncExprWrapperMd)

$webConsoleMd = @"
---
uid: Demo.WebConsole
---
# Non-blocking ASP.NET Core console sample

``````csharp
using System;
using Microsoft.AspNetCore.Http;

var context = new DefaultHttpContext();
context.Request.Method = HttpMethods.Get;
Console.WriteLine(context.Request.Method);
``````
"@
[IO.File]::WriteAllText("$detRoot/docs/WebConsole.md", $webConsoleMd)

$membersWrapperMd = @"
---
uid: Demo.WrapperMembers
---
# Wrapper with members

``````csharp
using System;

namespace Demo;

public sealed class MemberExample
{
    private readonly string _msg = "members-ok";
    public void Demonstrate() => Console.WriteLine(Format());
    private string Format() => _msg;
}
``````
"@
[IO.File]::WriteAllText("$detRoot/docs/WrapperMembers.md", $membersWrapperMd)

$hostParamMd = @"
---
uid: Demo.HostParam
---
# Parameterized host method

``````csharp
using Microsoft.Extensions.DependencyInjection;

public sealed class StartupExample
{
    public void ConfigureServices(IServiceCollection services)
    {
    }
}
``````
"@
[IO.File]::WriteAllText("$detRoot/docs/HostParam.md", $hostParamMd)

$noEntryMd = @"
---
uid: Demo.NoEntry
---
# Options model without entry

``````csharp
public sealed class JustOptions
{
    public int Timeout { get; set; } = 30;
}
``````
"@
[IO.File]::WriteAllText("$detRoot/docs/NoEntry.md", $noEntryMd)

$silentConsoleMd = @"
---
uid: Demo.SilentConsole
---
# Silent console

``````csharp
var x = 1 + 1;
``````
"@
[IO.File]::WriteAllText("$detRoot/docs/SilentConsole.md", $silentConsoleMd)

$hostBlockingMd = @"
---
uid: Demo.AppTagHelperOptions
---
# Blocking ASP.NET Core host

``````csharp
var builder = WebApplication.CreateBuilder(args);
var app = builder.Build();
app.MapGet("/", () => "host-harness-ok");
app.Run();
``````
"@
[IO.File]::WriteAllText("$detRoot/docs/HostBlocking.md", $hostBlockingMd)

$splitPkgMd = @"
---
uid: Acme.Net.Http.HttpManager
---
# Split package type ownership

``````csharp
using Acme.Net.Http;
using Shared.Telemetry;

var mgr = new HttpManager();
``````
"@
[IO.File]::WriteAllText("$detRoot/docs/SplitPkg.md", $splitPkgMd)

$unpublishedMd = @"
---
uid: Acme.Internal.SecretHelper
---
# Unpublished project ownership

``````csharp
using Acme.Internal;

var helper = new SecretHelper();
``````
"@
[IO.File]::WriteAllText("$detRoot/docs/Unpublished.md", $unpublishedMd)

$ambiguousMd = @"
---
uid: Acme.Xml.Serialization.XmlConvert
---
# Ambiguous type collision

``````csharp
using System.Xml;
using Acme.Xml.Serialization;

var t = typeof(XmlConvert);
``````
"@
[IO.File]::WriteAllText("$detRoot/docs/Ambiguous.md", $ambiguousMd)

$multiFenceMd = @"
---
uid: Demo.MultiFence
---
# Multi-fence page

First example:

``````csharp
using System;
Console.WriteLine("fence-one");
``````

Second example:

``````csharp
using System;
Console.WriteLine("fence-two");
``````
"@
[IO.File]::WriteAllText("$detRoot/docs/MultiFence.md", $multiFenceMd)

$intrinsicMd = @"
---
uid: Demo.IntrinsicOnly
---
# Intrinsic only

``````csharp
public interface IMarkerOnly { }
``````
"@
[IO.File]::WriteAllText("$detRoot/docs/Intrinsic.md", $intrinsicMd)
$intrinsicHash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes('public interface IMarkerOnly { }')))
$fenceTwoHash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes("using System;`nConsole.WriteLine(`"fence-two`");")))
[IO.File]::WriteAllText("$detRoot/run-actions.settings.json", (@{
    examples = @(
        @{ uid = 'Demo.IntrinsicOnly'; exampleId = 'Demo.IntrinsicOnly#1'; fenceOrdinal = 1; sourceSha256 = $intrinsicHash; intrinsicLimitation = 'Marker interface with no observable runtime behavior.' }
        @{ uid = 'Demo.MultiFence'; exampleId = 'Demo.MultiFence#2'; fenceOrdinal = 2; sourceSha256 = $fenceTwoHash; manifest = @{ schemaVersion = 1; mode = 'console'; framework = 'net10.0'; dependsOn = @() } }
    )
} | ConvertTo-Json -Depth 15))

# 1. --run-action-plan --json and --explain <uid>
$planJson = (& $generator -RepoRoot $detRoot --run-action-plan --json) | ConvertFrom-Json
if ($LASTEXITCODE -ne 0 -or $planJson.schemaVersion -ne 2) { throw 'Expected --run-action-plan --json to succeed with schemaVersion 2.' }
$planById = @{}
foreach ($item in $planJson.examples) { $planById[$item.exampleId] = $item }
if ($planById['Demo.WrapperClean#1'].category -ne 'wrapper-clean' -or -not $planById['Demo.WrapperClean#1'].convertible -or $planById['Demo.WrapperClean#1'].blockingConstruct -notlike '*CleanExample*') {
    throw "wrapper-clean classification failed: $($planById['Demo.WrapperClean#1'] | ConvertTo-Json -Compress)"
}
if ($planById['Demo.WrapperMembers#1'].category -ne 'wrapper-members' -or -not $planById['Demo.WrapperMembers#1'].convertible -or $planById['Demo.WrapperMembers#1'].blockingConstruct -notlike '*_msg*') {
    throw "wrapper-members classification failed: $($planById['Demo.WrapperMembers#1'] | ConvertTo-Json -Compress)"
}
if ($planById['Demo.HostParam#1'].category -ne 'host-parameterized' -or $planById['Demo.HostParam#1'].convertible -or $planById['Demo.HostParam#1'].blockingConstruct -notlike '*ConfigureServices*') {
    throw "host-parameterized classification failed: $($planById['Demo.HostParam#1'] | ConvertTo-Json -Compress)"
}
if ($planById['Demo.NoEntry#1'].category -ne 'no-entry' -or $planById['Demo.NoEntry#1'].convertible) {
    throw "no-entry classification failed: $($planById['Demo.NoEntry#1'] | ConvertTo-Json -Compress)"
}
if ($planById['Demo.AppTagHelperOptions#1'].category -ne 'host-blocking' -or -not $planById['Demo.AppTagHelperOptions#1'].convertible -or $planById['Demo.AppTagHelperOptions#1'].suggestedMode -ne 'host') {
    throw "host-blocking classification failed: $($planById['Demo.AppTagHelperOptions#1'] | ConvertTo-Json -Compress)"
}
if ($planById['Demo.IntrinsicOnly#1'].category -ne 'intrinsic' -or $planById['Demo.IntrinsicOnly#1'].convertible) {
    throw "intrinsic classification failed: $($planById['Demo.IntrinsicOnly#1'] | ConvertTo-Json -Compress)"
}
if (-not $planById.ContainsKey('Demo.MultiFence#1') -or -not $planById.ContainsKey('Demo.MultiFence#2')) {
    throw 'Multi-fence page must emit stable uid#1 and uid#2 exampleIds.'
}
$explainText = (& $generator -RepoRoot $detRoot --explain Demo.HostParam) -join "`n"
if ($LASTEXITCODE -ne 0 -or $explainText -notlike '*host-parameterized*' -or $explainText -notlike '*ConfigureServices*') {
    throw "--explain prose output was incomplete: $explainText"
}

# 2. --resolve-dependencies <uid> (split package, subtree Directory.Build.props / Directory.Packages.props isolation, unpublished project, CS0104 ambiguity)
$splitDep = (& $generator -RepoRoot $detRoot --resolve-dependencies Acme.Net.Http.HttpManager) | ConvertFrom-Json
if ($LASTEXITCODE -ne 0 -or -not $splitDep.preflightPassed -or
    ($splitDep.dependsOn -notcontains 'Acme.Net@11.0.0') -or ($splitDep.dependsOn -contains 'Acme.Net.Http@11.0.0') -or
    ($splitDep.dependsOn -notcontains 'Shared.Telemetry@2.1.0') -or ($splitDep.dependsOn -contains 'Shared.Telemetry@9.9.9')) {
    throw "Split-package or subtree-scoped dependency resolution failed: $($splitDep | ConvertTo-Json -Compress)"
}
$unpubDep = (& $generator -RepoRoot $detRoot --resolve-dependencies Acme.Internal.SecretHelper) | ConvertFrom-Json
if ($LASTEXITCODE -ne 1 -or $unpubDep.preflightPassed -or -not (@($unpubDep.errors | Where-Object { $_ -like 'missing-package: SecretHelper -> Acme.Internal*' }).Count)) {
    throw "Unpublished project preflight must fail with missing-package: $($unpubDep | ConvertTo-Json -Compress)"
}
$ambigDep = (& $generator -RepoRoot $detRoot --resolve-dependencies Acme.Xml.Serialization.XmlConvert) | ConvertFrom-Json
if ($LASTEXITCODE -ne 1 -or $ambigDep.preflightPassed -or -not (@($ambigDep.errors | Where-Object { $_ -like 'ambiguous-type: XmlConvert ->*System.Xml.XmlConvert*' -and $_ -like '*Acme.Xml.Serialization.XmlConvert*' }).Count)) {
    throw "Ambiguous type preflight must fail with ambiguous-type: $($ambigDep | ConvertTo-Json -Compress)"
}

# 3. --validate-run-action and guarded --apply-run-action (with real dotnet run --file and host harness!)
$refusedApply = (& $generator -RepoRoot $detRoot --apply-run-action Demo.WrapperClean) | ConvertFrom-Json
if ($LASTEXITCODE -ne 1 -or $refusedApply.applied -or $refusedApply.reasonCode -ne 'validation-required') {
    throw "--apply-run-action must refuse when validation has not passed: $($refusedApply | ConvertTo-Json -Compress)"
}
if ([IO.File]::ReadAllText("$detRoot/docs/WrapperClean.md") -cne $cleanWrapperMd) {
    throw 'Refused --apply-run-action must not modify the Markdown file.'
}
$silentVal = (& $generator -RepoRoot $detRoot --validate-run-action Demo.SilentConsole) | ConvertFrom-Json
if ($LASTEXITCODE -ne 1 -or $silentVal.validated -or $silentVal.reasonCode -ne 'empty-console-output') {
    throw "Console validation must reject empty stdout: $($silentVal | ConvertTo-Json -Compress)"
}
$cleanVal = (& $generator -RepoRoot $detRoot --validate-run-action Demo.WrapperClean) | ConvertFrom-Json
if ($LASTEXITCODE -ne 0 -or -not $cleanVal.validated -or -not $cleanVal.converted -or $cleanVal.stdout -notlike '*clean ok*' -or -not $cleanVal.recipeSha256) {
    throw "wrapper-clean validation failed: $($cleanVal | ConvertTo-Json -Compress)"
}
if ([IO.File]::ReadAllText("$detRoot/docs/WrapperClean.md") -cne $cleanWrapperMd) {
    throw '--validate-run-action must not edit repository files.'
}
$cleanApplied = (& $generator -RepoRoot $detRoot --apply-run-action Demo.WrapperClean) | ConvertFrom-Json
if ($LASTEXITCODE -ne 0 -or -not $cleanApplied.applied -or -not $cleanApplied.fenceUpdated -or $cleanApplied.recipeSha256 -cne $cleanVal.recipeSha256) {
    throw "--apply-run-action failed after validation: $($cleanApplied | ConvertTo-Json -Compress)"
}
$asyncExprVal = (& $generator -RepoRoot $detRoot --validate-run-action Demo.AsyncExprWrapper) | ConvertFrom-Json
if ($LASTEXITCODE -ne 0 -or -not $asyncExprVal.validated -or -not $asyncExprVal.converted -or $asyncExprVal.stdout.Trim() -cne '42') {
    throw "Async expression-bodied wrapper validation failed (must not emit double await): $($asyncExprVal | ConvertTo-Json -Compress)"
}
$asyncExprApplied = (& $generator -RepoRoot $detRoot --apply-run-action Demo.AsyncExprWrapper) | ConvertFrom-Json
if ($LASTEXITCODE -ne 0 -or -not $asyncExprApplied.applied -or ([IO.File]::ReadAllText("$detRoot/docs/AsyncExprWrapper.md") -match 'await\s+await')) {
    throw "Async expression-bodied wrapper apply failed or emitted double await: $($asyncExprApplied | ConvertTo-Json -Compress)"
}
$webConsoleVal = (& $generator -RepoRoot $detRoot --validate-run-action Demo.WebConsole) | ConvertFrom-Json
if ($LASTEXITCODE -ne 0 -or -not $webConsoleVal.validated -or $webConsoleVal.stdout.Trim() -cne 'GET') {
    throw "Web SDK standalone console validation failed: $($webConsoleVal | ConvertTo-Json -Compress)"
}
$webConsoleApplied = (& $generator -RepoRoot $detRoot --apply-run-action Demo.WebConsole) | ConvertFrom-Json
if ($LASTEXITCODE -ne 0 -or -not $webConsoleApplied.applied) {
    throw "Web SDK standalone console apply failed: $($webConsoleApplied | ConvertTo-Json -Compress)"
}
$webSavedRecipe = ((Get-Content "$detRoot/run-actions.settings.json" -Raw | ConvertFrom-Json).examples | Where-Object uid -eq 'Demo.WebConsole' | Select-Object -First 1)
if (-not $webSavedRecipe -or $webSavedRecipe.manifest.sdk -cne 'Microsoft.NET.Sdk.Web' -or ($webSavedRecipe.manifest.frameworkReferences -notcontains 'Microsoft.AspNetCore.App')) {
    throw "Saved standalone recipe dropped sdk or frameworkReferences: $($webSavedRecipe | ConvertTo-Json -Depth 10 -Compress)"
}
$membersVal = (& $generator -RepoRoot $detRoot --validate-run-action Demo.WrapperMembers) | ConvertFrom-Json
if ($LASTEXITCODE -ne 0 -or -not $membersVal.validated -or $membersVal.stdout -notlike '*members-ok*') {
    throw "wrapper-members validation failed: $($membersVal | ConvertTo-Json -Compress)"
}
$membersApplied = (& $generator -RepoRoot $detRoot --apply-run-action Demo.WrapperMembers) | ConvertFrom-Json
if ($LASTEXITCODE -ne 0 -or -not $membersApplied.applied) {
    throw "--apply-run-action failed for wrapper-members: $($membersApplied | ConvertTo-Json -Compress)"
}

# 4. Multi-fence apply safety & --check-recipes --json (moved, duplicate-uid, whitespace-only vs semantic orphan)
$ambigFenceVal = (& $generator -RepoRoot $detRoot --validate-run-action Demo.MultiFence) | ConvertFrom-Json
if ($LASTEXITCODE -ne 3 -or $ambigFenceVal.reasonCode -ne 'ambiguous-multi-fence-uid') {
    throw 'Bare multi-fence UID must exit 3 with explicit uid#ordinal candidates.'
}
$mf1Val = (& $generator -RepoRoot $detRoot --validate-run-action Demo.MultiFence#1) | ConvertFrom-Json
if ($LASTEXITCODE -ne 0 -or -not $mf1Val.validated) { throw "MultiFence#1 validation failed: $($mf1Val | ConvertTo-Json -Compress)" }
$mf1Applied = (& $generator -RepoRoot $detRoot --apply-run-action Demo.MultiFence#1) | ConvertFrom-Json
if ($LASTEXITCODE -ne 0 -or -not $mf1Applied.applied) { throw "MultiFence#1 apply failed: $($mf1Applied | ConvertTo-Json -Compress)" }
$settingsAfterMf1 = (Get-Content "$detRoot/run-actions.settings.json" -Raw | ConvertFrom-Json).examples
if (-not (@($settingsAfterMf1 | Where-Object { $_.uid -eq 'Demo.MultiFence' -and $_.sourceSha256 -ceq $fenceTwoHash }).Count)) {
    throw 'Applying a recipe for fence #1 must NEVER overwrite an existing recipe matching fence #2.'
}

# 5. Host harness (Blocker 8): real ASP.NET Core host validation, apply, generation, and BuildRunActions.ps1 parity
$hostVal = (& $generator -RepoRoot $detRoot --validate-run-action Demo.AppTagHelperOptions) | ConvertFrom-Json
if ($LASTEXITCODE -ne 0 -or -not $hostVal.validated -or $hostVal.mode -ne 'host' -or $hostVal.stdout -notlike '*host-harness-ok*') {
    throw "Host harness validation failed: $($hostVal | ConvertTo-Json -Compress)"
}
$hostApplied = (& $generator -RepoRoot $detRoot --apply-run-action Demo.AppTagHelperOptions) | ConvertFrom-Json
if ($LASTEXITCODE -ne 0 -or -not $hostApplied.applied) { throw "Host harness apply failed: $($hostApplied | ConvertTo-Json -Compress)" }

# Clean recipe check before mutating fences for negative tests
$cleanCheck = (& $generator -RepoRoot $detRoot --check-recipes --json) | ConvertFrom-Json
if ($LASTEXITCODE -ne 0 -or $cleanCheck.issues.Count -ne 0 -or $cleanCheck.normalization.lineEndings -ne 'LF') {
    throw "Expected clean --check-recipes --json: $($cleanCheck | ConvertTo-Json -Depth 10)"
}

# Generate manifest & materialize BuildRunActions.ps1 (including host strategy!)
$detGenSummary = (& $generator -RepoRoot $detRoot --summary-json) | ConvertFrom-Json
if ($LASTEXITCODE -ne 2 -or $detGenSummary.schemaVersion -ne 2 -or $detGenSummary.intrinsic -ne 1 -or $detGenSummary.unresolved -lt 1 -or -not $detGenSummary.'skipped-by-category') {
    throw "Unexpected --summary-json output: $($detGenSummary | ConvertTo-Json -Depth 5)"
}
$hostGenEntry = $detGenSummary.examples | Where-Object exampleId -ceq 'Demo.AppTagHelperOptions#1'
if (-not $hostGenEntry -or $hostGenEntry.strategy -ne 'host' -or $hostGenEntry.coverage -ne 'Paired') {
    throw "Expected paired host strategy entry: $($hostGenEntry | ConvertTo-Json -Compress)"
}
$global:LASTEXITCODE = 0
& "$detRoot/BuildRunActions.ps1" | Out-Null
if ($LASTEXITCODE -ne 0) { throw 'BuildRunActions.ps1 failed for host strategy manifest.' }
foreach ($t in @('native', 'docker')) {
    $hostScriptPath = "$detRoot/run-actions/$($hostGenEntry.id)/$t.ps1"
    if (-not (Test-Path -LiteralPath $hostScriptPath)) { throw "BuildRunActions.ps1 did not materialize host $t.ps1" }
    $actualHostHash = (Get-FileHash -LiteralPath $hostScriptPath -Algorithm SHA256).Hash
    if ($actualHostHash -cne $hostGenEntry."${t}Sha256") { throw "BuildRunActions.ps1 host $t.ps1 hash drifted from generator." }
}

$webGenEntry = $detGenSummary.examples | Where-Object exampleId -ceq 'Demo.WebConsole#1'
if (-not $webGenEntry -or $webGenEntry.strategy -ne 'standalone') {
    throw "Expected standalone WebConsole entry: $($webGenEntry | ConvertTo-Json -Compress)"
}
$webNativeScript = Get-Content "$detRoot/run-actions/$($webGenEntry.id)/native.ps1" -Raw
$webNativeManifest = (Get-CsrunWrapperManifest $webNativeScript) | ConvertFrom-Json
if ($webNativeManifest.sdk -cne 'Microsoft.NET.Sdk.Web' -or ($webNativeManifest.frameworkReferences -notcontains 'Microsoft.AspNetCore.App')) {
    throw "Materialized csrun manifest dropped sdk or frameworkReferences: $($webNativeManifest | ConvertTo-Json -Compress)"
}

# 6. Negative recipe health checks: moved, duplicate-uid, whitespace-only orphan, string-literal whitespace change (semantic!), semantic orphan
$savedSettingsRaw = [IO.File]::ReadAllText("$detRoot/run-actions.settings.json")
$savedMultiRaw = [IO.File]::ReadAllText("$detRoot/docs/MultiFence.md")
$savedCleanRaw = [IO.File]::ReadAllText("$detRoot/docs/WrapperClean.md")
try {
    # Moved: swap fence-one and fence-two in MultiFence.md
    [IO.File]::WriteAllText("$detRoot/docs/MultiFence.md", $savedMultiRaw.Replace('fence-one', '__TMP__').Replace('fence-two', 'fence-one').Replace('__TMP__', 'fence-two'))
    $movedCheck = (& $generator -RepoRoot $detRoot --check-recipes --json) | ConvertFrom-Json
    if ($LASTEXITCODE -ne 1 -or -not (@($movedCheck.issues | Where-Object kind -eq 'moved').Count)) {
        throw "Expected moved recipe detection: $($movedCheck | ConvertTo-Json -Depth 10)"
    }
    [IO.File]::WriteAllText("$detRoot/docs/MultiFence.md", $savedMultiRaw)

    # Whitespace-only orphan: append trailing spaces to Console.WriteLine("clean ok");
    [IO.File]::WriteAllText("$detRoot/docs/WrapperClean.md", $savedCleanRaw.Replace('Console.WriteLine("clean ok");', 'Console.WriteLine("clean ok");   '))
    $wsCheck = (& $generator -RepoRoot $detRoot --check-recipes --json) | ConvertFrom-Json
    $wsIssue = $wsCheck.issues | Where-Object { $_.kind -eq 'orphaned' -and $_.uid -eq 'Demo.WrapperClean' } | Select-Object -First 1
    if ($LASTEXITCODE -ne 1 -or -not $wsIssue -or $wsIssue.diffKind -ne 'whitespace-only' -or -not $wsIssue.currentSourceSha256 -or $wsIssue.suggestedUpdate.action -ne 'update-source-sha256') {
        throw "Expected whitespace-only orphan classification: $($wsCheck | ConvertTo-Json -Depth 10)"
    }

    # String-literal whitespace change ("clean ok" -> "cleanok") MUST be classified as semantic, NOT whitespace-only!
    [IO.File]::WriteAllText("$detRoot/docs/WrapperClean.md", $savedCleanRaw.Replace('clean ok', 'cleanok'))
    $litWsCheck = (& $generator -RepoRoot $detRoot --check-recipes --json) | ConvertFrom-Json
    $litWsIssue = $litWsCheck.issues | Where-Object { $_.kind -eq 'orphaned' -and $_.uid -eq 'Demo.WrapperClean' } | Select-Object -First 1
    if ($LASTEXITCODE -ne 1 -or -not $litWsIssue -or $litWsIssue.diffKind -ne 'semantic' -or $litWsIssue.suggestedUpdate.action -ne 're-validate-and-apply') {
        throw "Whitespace change inside a string literal must be classified as semantic: $($litWsCheck | ConvertTo-Json -Depth 10)"
    }

    # Semantic orphan: change printed string
    [IO.File]::WriteAllText("$detRoot/docs/WrapperClean.md", $savedCleanRaw.Replace('clean ok', 'changed-semantics'))
    $semCheck = (& $generator -RepoRoot $detRoot --check-recipes --json) | ConvertFrom-Json
    $semIssue = $semCheck.issues | Where-Object { $_.kind -eq 'orphaned' -and $_.uid -eq 'Demo.WrapperClean' } | Select-Object -First 1
    if ($LASTEXITCODE -ne 1 -or -not $semIssue -or $semIssue.diffKind -ne 'semantic' -or $semIssue.suggestedUpdate.action -ne 're-validate-and-apply') {
        throw "Expected semantic orphan classification: $($semCheck | ConvertTo-Json -Depth 10)"
    }
    [IO.File]::WriteAllText("$detRoot/docs/WrapperClean.md", $savedCleanRaw)

    # Duplicate-uid check
    $dupDoc = $savedSettingsRaw | ConvertFrom-Json
    $dupExamples = @($dupDoc.examples) + @($dupDoc.examples | Where-Object uid -eq 'Demo.WrapperClean' | Select-Object -First 1)
    [IO.File]::WriteAllText("$detRoot/run-actions.settings.json", (@{ examples = $dupExamples } | ConvertTo-Json -Depth 20))
    $dupCheck = (& $generator -RepoRoot $detRoot --check-recipes --json) | ConvertFrom-Json
    if ($LASTEXITCODE -ne 1 -or -not (@($dupCheck.issues | Where-Object kind -eq 'duplicate-uid').Count)) {
        throw "Expected duplicate-uid detection: $($dupCheck | ConvertTo-Json -Depth 10)"
    }
} finally {
    [IO.File]::WriteAllText("$detRoot/run-actions.settings.json", $savedSettingsRaw)
    [IO.File]::WriteAllText("$detRoot/docs/MultiFence.md", $savedMultiRaw)
    [IO.File]::WriteAllText("$detRoot/docs/WrapperClean.md", $savedCleanRaw)
}

# 7. Blocker 6: Verification failure (GitHub 403, no cached engine) preserves previous manifest and pages atomically!
$manifestBefore403 = [IO.File]::ReadAllText("$detRoot/run-actions.manifest.json")
$pageBefore403 = [IO.File]::ReadAllText("$detRoot/docs/WrapperClean.md")
$emptyCache403 = Join-Path $work 'empty-cache-403'
$prevCache403 = $env:CSRUN_CACHE_DIR
$env:CSRUN_CACHE_DIR = $emptyCache403
function Invoke-WebRequest {
    param([string] $Uri, [hashtable] $Headers, [switch] $SkipHttpErrorCheck, [string] $OutFile)
    return [pscustomobject]@{ StatusCode = 403; Headers = @{}; Content = '{"message":"API rate limit exceeded"}' }
}
try {
    $fail403 = (& $generator -RepoRoot $detRoot --verify Native --summary-json) | ConvertFrom-Json
    $exit403 = $LASTEXITCODE
} finally {
    Remove-Item Function:\Invoke-WebRequest -ErrorAction SilentlyContinue
    $env:CSRUN_CACHE_DIR = $prevCache403
    if (Test-Path -LiteralPath $emptyCache403) { Remove-Item -LiteralPath $emptyCache403 -Recurse -Force }
}
if ($exit403 -ne 1 -or $fail403.failureReason -ne 'github-403-no-cached-engine' -or -not $fail403.manifestPreserved) {
    throw "GitHub 403 verification failure must exit 1 with github-403-no-cached-engine: $($fail403 | ConvertTo-Json -Compress)"
}
if ([IO.File]::ReadAllText("$detRoot/run-actions.manifest.json") -cne $manifestBefore403 -or
    [IO.File]::ReadAllText("$detRoot/docs/WrapperClean.md") -cne $pageBefore403) {
    throw 'Failed verification destroyed or mutated the previous manifest or Markdown associations!'
}

# 8. Blocker 7: --verify Native --engine-path, --verify-changed reuse + engine hash invalidation, runtime-failure manifest preservation, and --verify --id <uid>
$detEngine = Join-Path $work 'det-csrun.ps1'
$detEngineB = Join-Path $work 'det-csrun-b.ps1'
[IO.File]::WriteAllText($detEngine, $mockEngineContent, [Text.UTF8Encoding]::new($false))
[IO.File]::WriteAllText($detEngineB, ($mockEngineContent + "`n# engine-b"), [Text.UTF8Encoding]::new($false))
$detVerifyCalls = [Collections.Generic.List[string]]::new()
$detFailFirst = $false
function pwsh {
    $fileIndex = [Array]::IndexOf($args, '-File')
    $detVerifyCalls.Add([string]$args[$fileIndex + 1])
    if ($detFailFirst -and $detVerifyCalls.Count -eq 1) {
        $global:LASTEXITCODE = 1
    } else {
        $global:LASTEXITCODE = 0
    }
}
try {
    $vAll = (& $generator -RepoRoot $detRoot --verify Native --engine-path $detEngine --summary-json) | ConvertFrom-Json
    $vAllCount = $detVerifyCalls.Count
    $detVerifyCalls.Clear()

    $vChanged = (& $generator -RepoRoot $detRoot --verify-changed --engine-path $detEngine --summary-json) | ConvertFrom-Json
    $vChangedCount = $detVerifyCalls.Count
    $detVerifyCalls.Clear()

    # Switching to a different engine (different SHA-256) must re-execute standalone examples under --verify-changed!
    $vChangedEngineB = (& $generator -RepoRoot $detRoot --verify-changed --engine-path $detEngineB --summary-json) | ConvertFrom-Json
    $vChangedEngineBCount = $detVerifyCalls.Count
    $detVerifyCalls.Clear()

    # A runtime verification failure with non-zero manifest entries must preserve the previous manifest and page associations!
    $manifestBeforeRuntimeFail = [IO.File]::ReadAllText("$detRoot/run-actions.manifest.json")
    $pageBeforeRuntimeFail = [IO.File]::ReadAllText("$detRoot/docs/WrapperClean.md")
    $savedCleanBeforeRuntimeFail = $pageBeforeRuntimeFail
    try {
        [IO.File]::WriteAllText("$detRoot/docs/WrapperClean.md", $pageBeforeRuntimeFail.Replace('Console.WriteLine("clean ok");', 'Console.WriteLine("failing-update");'))
        $detFailFirst = $true
        $vRuntimeFail = (& $generator -RepoRoot $detRoot --verify Native --engine-path $detEngineB --summary-json) | ConvertFrom-Json
        $vRuntimeFailExit = $LASTEXITCODE
        $detFailFirst = $false
        $detVerifyCalls.Clear()
        if ($vRuntimeFailExit -ne 1 -or -not $vRuntimeFail.manifestPreserved) {
            throw "Runtime verification failure must exit 1 and preserve manifest: $($vRuntimeFail | ConvertTo-Json -Depth 5 -Compress)"
        }
        if ([IO.File]::ReadAllText("$detRoot/run-actions.manifest.json") -cne $manifestBeforeRuntimeFail) {
            throw 'Runtime verification failure overwrote the last good run-actions.manifest.json!'
        }
    } finally {
        $detFailFirst = $false
        [IO.File]::WriteAllText("$detRoot/docs/WrapperClean.md", $savedCleanBeforeRuntimeFail)
    }

    $vSingle = (& $generator -RepoRoot $detRoot --verify --id Demo.WrapperMembers#1 --engine-path $detEngineB --summary-json) | ConvertFrom-Json
    $vSingleCount = $detVerifyCalls.Count
    $detVerifyCalls.Clear()

    $vMissing = (& $generator -RepoRoot $detRoot --verify --id Does.Not.Exist --engine-path $detEngineB --summary-json)
    $vMissingExit = $LASTEXITCODE
} finally {
    Remove-Item Function:\pwsh -ErrorAction SilentlyContinue
    if (Test-Path -LiteralPath $detEngine) { Remove-Item -LiteralPath $detEngine -Force }
    if (Test-Path -LiteralPath $detEngineB) { Remove-Item -LiteralPath $detEngineB -Force }
}
if ($vAllCount -lt 5 -or $vAll.verified -lt 5) {
    throw "Expected full --verify Native run to execute >=5 examples; executed=$vAllCount verified=$($vAll.verified)"
}
if ($vChangedCount -ne 0 -or $vChanged.verification.reused -lt 5 -or $vChanged.verifyScope -ne 'changed') {
    throw "Expected --verify-changed to reuse all unchanged verified examples; executed=$vChangedCount reused=$($vChanged.verification.reused)"
}
if ($vChangedEngineBCount -lt 4) {
    throw "Expected --verify-changed with a different engine SHA-256 to re-execute all standalone examples; executed=$vChangedEngineBCount"
}
if ($vSingleCount -ne 1 -or $vSingle.verifyScope -ne 'id') {
    throw "Expected --verify --id to execute exactly 1 example; executed=$vSingleCount scope=$($vSingle.verifyScope)"
}
$manifestAfterSingle = (Get-Content "$detRoot/run-actions.manifest.json" -Raw | ConvertFrom-Json).examples
if ($manifestAfterSingle.Count -lt 5) {
    throw 'Scoped --verify --id must preserve all other entries in run-actions.manifest.json.'
}
if ($vMissingExit -ne 3) {
    throw "Expected unmatched --id selector to exit 3; got $vMissingExit"
}

# 9. Issue 7: Host harness build deadline bounds stalled dotnet build and kills its process tree.
. (Join-Path $PSScriptRoot 'integration-example.ps1')
$stalledPair = New-HostExamplePair -Source 'Console.WriteLine("never");' -Framework 'net10.0' -Sdk 'Microsoft.NET.Sdk.Web' -TimeoutSeconds 3
$pwshExe = (Get-Command pwsh -CommandType Application | Select-Object -First 1).Source
$childPidFile = Join-Path $work 'stalled-child.pid'
$buildArgsPattern = "foreach (`$a in @('build', `$csprojPath, '-c', 'Release', '--nologo', '-v', 'quiet')) { `$buildStartInfo.ArgumentList.Add(`$a) }"
if (-not $stalledPair.Native.Contains($buildArgsPattern)) {
    throw 'Host runner script no longer launches dotnet build via bounded ProcessStartInfo.'
}
$escapedPwsh = $pwshExe.Replace("'", "''")
$escapedPidFile = $childPidFile.Replace("'", "''")
$stallCmd = "`$c = Start-Process -FilePath '$escapedPwsh' -ArgumentList @('-NoProfile','-NonInteractive','-Command','Start-Sleep -Seconds 30') -PassThru; [IO.File]::WriteAllText('$escapedPidFile', [string]`$c.Id); Start-Sleep -Seconds 30"
$escapedStallCmd = $stallCmd.Replace("'", "''")
$stalledScript = $stalledPair.Native.Replace(
    $buildArgsPattern,
    "`$buildStartInfo.FileName = '$escapedPwsh'; foreach (`$a in @('-NoProfile', '-NonInteractive', '-Command', '$escapedStallCmd')) { `$buildStartInfo.ArgumentList.Add(`$a) }"
)
$stalledScriptPath = Join-Path $work 'stalled-host.ps1'
[IO.File]::WriteAllText($stalledScriptPath, $stalledScript, [Text.UTF8Encoding]::new($false))
$sw = [Diagnostics.Stopwatch]::StartNew()
$stalledOut = & $pwshExe -NoProfile -NonInteractive -File $stalledScriptPath 2>&1 | Out-String
$stalledExit = $LASTEXITCODE
$sw.Stop()
if ($stalledExit -eq 0 -or $stalledOut -notlike '*Host sample build timed out after 3s*' -or $sw.Elapsed.TotalSeconds -ge 15) {
    throw "Stalled host build was not bounded by timeoutSeconds (exit=$stalledExit, elapsed=$([Math]::Round($sw.Elapsed.TotalSeconds,2))s): $stalledOut"
}
if (Test-Path -LiteralPath $childPidFile) {
    $childPid = [int]([IO.File]::ReadAllText($childPidFile).Trim())
    Start-Sleep -Milliseconds 300
    $stillRunning = Get-Process -Id $childPid -ErrorAction SilentlyContinue
    if ($stillRunning) {
        try { Stop-Process -Id $childPid -Force -ErrorAction SilentlyContinue } catch {}
        throw "Timed-out host build did not kill its child process tree (PID $childPid survived)."
    }
}

# 10. Empty probePath must fail with timeout when full startupDelayMs cannot finish before deadline (and match BuildRunActions.ps1).
$runArgsPattern = "foreach (`$a in @('run','--no-build','-c','Release','--project',`$csprojPath)) { `$startInfo.ArgumentList.Add(`$a) }"
$truncatedDelayPair = New-HostExamplePair -Source 'Console.WriteLine("worker");' -Framework 'net10.0' -Sdk 'Microsoft.NET.Sdk.Worker' -ProbePath '' -TimeoutSeconds 3 -StartupDelayMs 10000
if (-not $truncatedDelayPair.Native.Contains($runArgsPattern)) {
    throw 'Host runner script no longer launches dotnet run via ProcessStartInfo.'
}
$truncatedDelayScript = $truncatedDelayPair.Native.Replace(
    $buildArgsPattern,
    "`$buildStartInfo.FileName = '$escapedPwsh'; foreach (`$a in @('-NoProfile', '-NonInteractive', '-Command', 'Start-Sleep -Milliseconds 500')) { `$buildStartInfo.ArgumentList.Add(`$a) }"
).Replace(
    $runArgsPattern,
    "`$startInfo.FileName = '$escapedPwsh'; foreach (`$a in @('-NoProfile', '-NonInteractive', '-Command', 'Start-Sleep -Seconds 30')) { `$startInfo.ArgumentList.Add(`$a) }"
)
$truncatedDelayScriptPath = Join-Path $work 'truncated-delay-host.ps1'
[IO.File]::WriteAllText($truncatedDelayScriptPath, $truncatedDelayScript, [Text.UTF8Encoding]::new($false))
$swDelay = [Diagnostics.Stopwatch]::StartNew()
$truncatedDelayOut = & $pwshExe -NoProfile -NonInteractive -File $truncatedDelayScriptPath 2>&1 | Out-String
$truncatedDelayExit = $LASTEXITCODE
$swDelay.Stop()
if ($truncatedDelayExit -eq 0 -or $truncatedDelayOut -notlike '*Host startup observation (10000ms) timed out after 3s*' -or $truncatedDelayOut -like '*Host started cleanly*' -or $swDelay.Elapsed.TotalSeconds -ge 15) {
    throw "Truncated startupDelayMs observation window did not fail with timeout (exit=$truncatedDelayExit, elapsed=$([Math]::Round($swDelay.Elapsed.TotalSeconds,2))s): $truncatedDelayOut"
}

$fullDelayPair = New-HostExamplePair -Source 'Console.WriteLine("worker");' -Framework 'net10.0' -Sdk 'Microsoft.NET.Sdk.Worker' -ProbePath '' -TimeoutSeconds 5 -StartupDelayMs 200
$fullDelayScript = $fullDelayPair.Native.Replace(
    $buildArgsPattern,
    "`$buildStartInfo.FileName = '$escapedPwsh'; foreach (`$a in @('-NoProfile', '-NonInteractive', '-Command', 'exit 0')) { `$buildStartInfo.ArgumentList.Add(`$a) }"
).Replace(
    $runArgsPattern,
    "`$startInfo.FileName = '$escapedPwsh'; foreach (`$a in @('-NoProfile', '-NonInteractive', '-Command', 'Start-Sleep -Seconds 30')) { `$startInfo.ArgumentList.Add(`$a) }"
)
$fullDelayScriptPath = Join-Path $work 'full-delay-host.ps1'
[IO.File]::WriteAllText($fullDelayScriptPath, $fullDelayScript, [Text.UTF8Encoding]::new($false))
$fullDelayOut = & $pwshExe -NoProfile -NonInteractive -File $fullDelayScriptPath 2>&1 | Out-String
$fullDelayExit = $LASTEXITCODE
if ($fullDelayExit -ne 0 -or $fullDelayOut -notlike '*Host started cleanly and ran for 200ms.*') {
    throw "Full startupDelayMs observation window did not succeed cleanly (exit=$fullDelayExit): $fullDelayOut"
}

$emptyProbeDir = Join-Path $work 'empty-probe-parity'
$null = [IO.Directory]::CreateDirectory($emptyProbeDir)
$emptyProbeManifest = [ordered]@{
    schemaVersion = 1
    examples = @([ordered]@{
        id = 'abcdef0123456789abcdef01'
        strategy = 'host'
        source = 'Console.WriteLine("worker");'
        image = 'codebeltnet/csrun:10'
        transports = @('native', 'docker')
        hostHarness = [ordered]@{
            sdk = 'Microsoft.NET.Sdk.Worker'
            framework = 'net10.0'
            probePath = ''
            timeoutSeconds = 3
            startupDelayMs = 10000
        }
    })
}
$emptyProbeManifestPath = Join-Path $emptyProbeDir 'run-actions.manifest.json'
$emptyProbeOutRoot = Join-Path $emptyProbeDir 'run-actions'
[IO.File]::WriteAllText($emptyProbeManifestPath, ($emptyProbeManifest | ConvertTo-Json -Depth 10), [Text.UTF8Encoding]::new($false))
$global:LASTEXITCODE = 0
& (Join-Path $PSScriptRoot '../assets/BuildRunActions.ps1') -ManifestPath $emptyProbeManifestPath -OutputRoot $emptyProbeOutRoot | Out-Null
if ($LASTEXITCODE -ne 0) { throw 'BuildRunActions.ps1 failed for empty-probePath host parity check.' }
foreach ($t in @('native', 'docker')) {
    $expectedProp = if ($t -eq 'native') { 'Native' } else { 'Docker' }
    $expectedNorm = $truncatedDelayPair.$expectedProp.Replace("`r`n", "`n").TrimEnd("`n", "`r")
    $actualNorm = ([IO.File]::ReadAllText((Join-Path $emptyProbeOutRoot "abcdef0123456789abcdef01/$t.ps1"))).Replace("`r`n", "`n").TrimEnd("`n", "`r")
    if ($actualNorm -cne $expectedNorm) {
        throw "BuildRunActions.ps1 drifted from integration-example.ps1 for empty-probePath host $t transport."
    }
}

# 11. Bounded parallel verification, append-only stderr progress/heartbeat, --no-heartbeat / --quiet, --verify-changed reuse, and atomic manifest preservation on parallel failure.
$paraRoot = Join-Path $work 'parallel-verify'
$null = [IO.Directory]::CreateDirectory("$paraRoot/docs")
[IO.File]::WriteAllText("$paraRoot/docfx.json", (@{
    build = @{
        content = @(@{ files = @('docs/*.md') })
        template = @('default', 'modern')
        dest = '_site'
    }
} | ConvertTo-Json -Depth 10))
foreach ($label in @('One', 'Two', 'Three', 'Four')) {
    $md = "---`nuid: Para.$label`n---`n# Parallel $label`n`n``````csharp`nSystem.Console.WriteLine(`"para-$label`");`n```````n"
    [IO.File]::WriteAllText("$paraRoot/docs/$label.md", $md)
}
$paraTraceDir = Join-Path $work 'parallel-trace'
$null = [IO.Directory]::CreateDirectory($paraTraceDir)
$escapedTraceDir = $paraTraceDir.Replace("'", "''")
$paraEngine = Join-Path $work 'parallel-csrun.ps1'
[IO.File]::WriteAllText($paraEngine, @"
param([string]`$ManifestJson)
`$startTicks = [DateTimeOffset]::UtcNow.UtcTicks
Start-Sleep -Milliseconds 400
`$endTicks = [DateTimeOffset]::UtcNow.UtcTicks
`$traceFile = Join-Path '$escapedTraceDir' ([guid]::NewGuid().ToString('N') + '.txt')
[IO.File]::WriteAllText(`$traceFile, "`$startTicks|`$endTicks", [Text.UTF8Encoding]::new(`$false))
[Console]::Write('ok')
"@, [Text.UTF8Encoding]::new($false))

function Invoke-GeneratorSubprocess([string[]] $ExtraArgs) {
    $psi = [Diagnostics.ProcessStartInfo]::new($pwshExe)
    foreach ($a in @('-NoProfile', '-NonInteractive', '-File', $generator, '-RepoRoot', $paraRoot)) { $psi.ArgumentList.Add($a) }
    foreach ($a in $ExtraArgs) { $psi.ArgumentList.Add($a) }
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.UseShellExecute = $false
    $proc = [Diagnostics.Process]::new()
    $proc.StartInfo = $psi
    try {
        if (-not $proc.Start()) { throw 'Could not start generate-run-actions.ps1 subprocess.' }
        $outTask = $proc.StandardOutput.ReadToEndAsync()
        $errTask = $proc.StandardError.ReadToEndAsync()
        if (-not $proc.WaitForExit(120000)) {
            try { $proc.Kill($true) } catch {}
            throw 'generate-run-actions.ps1 subprocess timed out.'
        }
        return [pscustomobject]@{
            ExitCode = $proc.ExitCode
            Stdout = $outTask.GetAwaiter().GetResult()
            Stderr = $errTask.GetAwaiter().GetResult()
        }
    } finally {
        $proc.Dispose()
    }
}

$paraRun = Invoke-GeneratorSubprocess @('--verify', 'Native', '--max-parallel', '4', '--engine-path', $paraEngine, '--summary-json')
if ($paraRun.ExitCode -ne 0) {
    throw "Parallel --verify Native failed (exit=$($paraRun.ExitCode)). Stdout: $($paraRun.Stdout)`nStderr: $($paraRun.Stderr)"
}
$paraSummary = $paraRun.Stdout | ConvertFrom-Json
if ($paraSummary.schemaVersion -ne 2 -or $paraSummary.verified -ne 4 -or $paraSummary.verification.executed -ne 4 -or $paraSummary.verification.maxParallel -ne 4) {
    throw "Unexpected parallel summary JSON: $($paraRun.Stdout)"
}
$paraErrLines = @($paraRun.Stderr -split '\r?\n' | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
$paraProgressLines = @($paraErrLines | Where-Object { $_ -cmatch '^\[\d+/4\] Verifying Para\.(One|Two|Three|Four)#1 \(Native\) -> Verified \(\d+\.\ds\)$' })
if ($paraProgressLines.Count -ne 4) {
    throw "Expected 4 append-only stderr progress lines; got $($paraProgressLines.Count). Stderr:`n$($paraRun.Stderr)"
}
$traceIntervals = @(Get-ChildItem -LiteralPath $paraTraceDir -Filter '*.txt' | ForEach-Object {
    $parts = ([IO.File]::ReadAllText($_.FullName).Trim()) -split '\|'
    [pscustomobject]@{ Start = [int64]$parts[0]; End = [int64]$parts[1] }
})
if ($traceIntervals.Count -ne 4) { throw "Expected 4 parallel execution traces; got $($traceIntervals.Count)." }
$overlapFound = $false
for ($a = 0; $a -lt $traceIntervals.Count; $a++) {
    for ($b = $a + 1; $b -lt $traceIntervals.Count; $b++) {
        if ($traceIntervals[$a].Start -lt $traceIntervals[$b].End -and $traceIntervals[$b].Start -lt $traceIntervals[$a].End) {
            $overlapFound = $true; break
        }
    }
    if ($overlapFound) { break }
}
if (-not $overlapFound) { throw 'Parallel verification did not execute workers concurrently.' }
$paraManifestAfterGood = [IO.File]::ReadAllText("$paraRoot/run-actions.manifest.json")
if (@(($paraManifestAfterGood | ConvertFrom-Json).examples).Count -ne 4) {
    throw 'Parallel verification did not write all 4 entries atomically to run-actions.manifest.json.'
}

# --verify-changed skips all 4 cached Verified examples without re-executing or emitting progress lines.
$paraChangedRun = Invoke-GeneratorSubprocess @('--verify-changed', '--max-parallel', '4', '--engine-path', $paraEngine, '--summary-json')
if ($paraChangedRun.ExitCode -ne 0) { throw "Parallel --verify-changed failed (exit=$($paraChangedRun.ExitCode)): $($paraChangedRun.Stderr)" }
$paraChangedSummary = $paraChangedRun.Stdout | ConvertFrom-Json
if ($paraChangedSummary.verification.executed -ne 0 -or $paraChangedSummary.verification.reused -ne 4) {
    throw "Expected --verify-changed to reuse all 4 cached Verified examples: $($paraChangedRun.Stdout)"
}
if ($paraChangedRun.Stderr -match 'Verifying Para\.') {
    throw "Expected no Verifying lines on full cache reuse; got: $($paraChangedRun.Stderr)"
}

# Heartbeat, --no-heartbeat, and --quiet behavior on a slow verification run.
$slowEngine = Join-Path $work 'slow-csrun.ps1'
[IO.File]::WriteAllText($slowEngine, "param([string]`$ManifestJson)`nStart-Sleep -Milliseconds 1300`n[Console]::Write('slow-ok')", [Text.UTF8Encoding]::new($false))
$hbRun = Invoke-GeneratorSubprocess @('--verify', 'Native', '--id', 'Para.One#1', '--engine-path', $slowEngine, '--heartbeat-seconds', '1', '--summary-json')
if ($hbRun.ExitCode -ne 0) { throw "Heartbeat verification run failed: $($hbRun.Stderr)" }
$hbSummary = $hbRun.Stdout | ConvertFrom-Json
if ($hbSummary.verification.executed -ne 1 -or $hbRun.Stderr -notmatch '\[heartbeat\] Verification progress:' -or $hbRun.Stderr -notmatch '\[1/1\] Verifying Para\.One#1 \(Native\) -> Verified') {
    throw "Expected both heartbeat and completion lines on stderr with clean JSON stdout. Stderr:`n$($hbRun.Stderr)"
}

$noHbRun = Invoke-GeneratorSubprocess @('--verify', 'Native', '--id', 'Para.One#1', '--engine-path', $slowEngine, '--heartbeat-seconds', '1', '--no-heartbeat', '--summary-json')
if ($noHbRun.ExitCode -ne 0) { throw "--no-heartbeat run failed: $($noHbRun.Stderr)" }
$null = $noHbRun.Stdout | ConvertFrom-Json
if ($noHbRun.Stderr -match '\[heartbeat\]' -or $noHbRun.Stderr -notmatch '\[1/1\] Verifying Para\.One#1 \(Native\) -> Verified') {
    throw "--no-heartbeat must suppress heartbeat lines while keeping completion lines. Stderr:`n$($noHbRun.Stderr)"
}

$quietRun = Invoke-GeneratorSubprocess @('--verify', 'Native', '--id', 'Para.One#1', '--engine-path', $slowEngine, '--heartbeat-seconds', '1', '--quiet', '--summary-json')
if ($quietRun.ExitCode -ne 0) { throw "--quiet run failed: $($quietRun.Stderr)" }
$null = $quietRun.Stdout | ConvertFrom-Json
if (-not [string]::IsNullOrWhiteSpace($quietRun.Stderr)) {
    throw "--quiet must suppress all stderr progress and heartbeat output. Stderr:`n$($quietRun.Stderr)"
}

# Parallel partial failure must preserve the last good run-actions.manifest.json atomically.
$partialFailEngine = Join-Path $work 'partial-fail-csrun.ps1'
[IO.File]::WriteAllText($partialFailEngine, "param([string]`$ManifestJson)`nif (`$ManifestJson -like '*para-Two*') { exit 1 }`n[Console]::Write('ok')", [Text.UTF8Encoding]::new($false))
$savedOneMd = [IO.File]::ReadAllText("$paraRoot/docs/One.md")
try {
    [IO.File]::WriteAllText("$paraRoot/docs/One.md", $savedOneMd.Replace('para-One', 'para-One-modified'))
    $paraFailRun = Invoke-GeneratorSubprocess @('--verify', 'Native', '--max-parallel', '4', '--engine-path', $partialFailEngine, '--summary-json')
    if ($paraFailRun.ExitCode -ne 1) { throw "Expected parallel partial failure to exit 1; got $($paraFailRun.ExitCode)" }
    $paraFailSummary = $paraFailRun.Stdout | ConvertFrom-Json
    if (-not $paraFailSummary.manifestPreserved -or $paraFailSummary.verification.failed -ne 1 -or $paraFailRun.Stderr -notmatch 'Para\.Two#1 \(Native\) -> Failed') {
        throw "Parallel partial failure did not report manifestPreserved/failed status cleanly. Stdout: $($paraFailRun.Stdout)`nStderr: $($paraFailRun.Stderr)"
    }
    if ([IO.File]::ReadAllText("$paraRoot/run-actions.manifest.json") -cne $paraManifestAfterGood) {
        throw 'Parallel verification failure overwrote the last good run-actions.manifest.json!'
    }
} finally {
    [IO.File]::WriteAllText("$paraRoot/docs/One.md", $savedOneMd)
}

# Invalid --max-parallel exits 3.
$invalidParallelRun = Invoke-GeneratorSubprocess @('--verify', 'Native', '--max-parallel', '0', '--engine-path', $paraEngine, '--summary-json')
if ($invalidParallelRun.ExitCode -ne 3) {
    throw "Expected --max-parallel 0 to exit 3; got $($invalidParallelRun.ExitCode)"
}

$global:LASTEXITCODE = 0
Write-Host "Run-action delivery passed: paired console, test, dependency-backed test, repository test and host harness; deterministic plan/explain, type-owned dependency resolution/preflight, validation-gated apply, multi-fence uid#ordinal identity, whitespace/semantic recipe check, atomic manifest preservation, bounded parallel verification and append-only stderr progress/heartbeat, --summary-json/--verify-changed/--verify --id, exact pins and source, coverage classifications, independent verification state, incremental assets, stale cleanup, standalone BuildRunActions.ps1 materialization and modern DocFX render. Fixture: $work"
exit 0
