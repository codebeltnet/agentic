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
    & (Get-Command $app.Executable -CommandType Application).Source @($app.ArgumentPrefix + @($args | Select-Object -Skip ([Array]::IndexOf($args, '--repo-root'))))
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
    -not $nativeScript.Groups['script'].Value.StartsWith('#requires -Version 7.0') -or
    -not $dockerScript.Groups['script'].Value.StartsWith('#requires -Version 7.0')) {
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
[IO.File]::WriteAllText("$work/docfx.json", '{"build":{"content":[{"files":["docs/*.md"]}],"template":["default","modern","template"],"dest":"_site"}}')
[IO.File]::WriteAllText("$work/docs/test.md", "# Test`n`n``````csharp`nusing Xunit;`npublic class ExampleTest { [Fact] public void ParsesInventoryCount() { Assert.Equal(42, int.Parse(`"42`")); } }`n```````n")
$packageSource = @'
using Codebelt.Extensions.Xunit;
using Cuemon.Messaging;
using Microsoft.Extensions.DependencyInjection;

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
    harness=@{members='public sealed class RunExample { [Xunit.Fact] public void ResolvesTaggedInventory() { Xunit.Assert.Equal("inventory", new CorrelationStore().Resolve()); } }'}
    explanation='The test runs the displayed method and checks the correlation identifier returned from the DI container.'
}
$settingsPath = "$work/run-actions.settings.json"
[IO.File]::WriteAllText($settingsPath, (@{examples=@($packageRecipe)} | ConvertTo-Json -Depth 20))
$first = (& $generator -RepoRoot $work) | ConvertFrom-Json
if ($LASTEXITCODE -ne 2 -or @($first | Where-Object coverage -eq 'Paired').Count -ne 5 -or @($first | Where-Object coverage -eq 'Unresolved').Count -ne 1) { throw "Unexpected generation: $($first | ConvertTo-Json -Depth 10)" }
$resolved = $first | Where-Object uid -ceq $packageUid
$manifests = @(foreach ($transport in @('native','docker')) {
    $scriptText = Get-Content "$work/run-actions/$($resolved.id)/$transport.ps1" -Raw
    if (-not $scriptText.Contains('-RequirePassingTests') -or $scriptText -cmatch '\$testOutput|Test run summary') {
        throw "The generated $transport test script must delegate strict verification to csrun."
    }
    Get-CsrunWrapperManifest $scriptText
})
$resolvedManifest = $manifests[0] | ConvertFrom-Json
if ($manifests[0] -cne $manifests[1] -or $resolved.sourceSha256 -cne $packageExample.sourceSha256 -or
    $resolved.executionSourceSha256 -ceq $resolved.sourceSha256 -or -not $resolvedManifest.source.StartsWith($packageSource.Replace("`r`n", "`n"), [StringComparison]::Ordinal) -or
    -not $resolvedManifest.source.Contains('Xunit.Assert.Equal("inventory", new CorrelationStore().Resolve())') -or
    ($resolvedManifest.dependsOn -join '|') -cne (($packagePins + 'xunit.v3@4.0.3') -join '|')) { throw 'The harness changed the displayed operation or lost exact source, pins or transport parity.' }
if ([IO.File]::ReadAllText("$work/docs/partial.md") -cne $partial) { throw 'An unsupported page with mixed line endings changed.' }
$consoleWithAssociation = [IO.File]::ReadAllText("$work/docs/console.md")
if (-not $consoleWithAssociation.StartsWith($console + "`n`n<!-- docfx-run-actions:start -->", [StringComparison]::Ordinal)) {
    throw 'An association changed existing mixed line endings or did not follow the final fence.'
}
$entry = $first | Where-Object { $_.uid -like '*ManagedApplicationFixture*' -and $_.file -match '[\\/]docs[\\/]integration.md$' }
foreach ($transport in @('native','docker')) {
    $script = Get-Content "$work/run-actions/$($entry.id)/$transport.ps1" -Raw
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
$files = @(Get-ChildItem $work -Recurse -File)
$before = @{}
foreach ($file in $files) { $before[$file.FullName] = @((Get-FileHash $file.FullName).Hash, $file.LastWriteTimeUtc.Ticks) }
$second = (& $generator -RepoRoot $work) | ConvertFrom-Json
if (@($second | Where-Object status -eq 'unchanged').Count -ne 5) { throw 'Incremental generation failed.' }
foreach ($file in Get-ChildItem $work -Recurse -File) {
    if ($before[$file.FullName][0] -cne (Get-FileHash $file.FullName).Hash -or $before[$file.FullName][1] -ne $file.LastWriteTimeUtc.Ticks) { throw "Second run changed $($file.FullName)" }
}
# Mock only the fresh-process result to exercise independent status bookkeeping without running generated code.
function pwsh {
    $fileIndex = [Array]::IndexOf($args, '-File')
    if ($fileIndex -lt 0 -or [string]$args[$fileIndex + 1] -notmatch '[\\/]native\.ps1$') { throw 'The focused verification should invoke Native only.' }
    $global:LASTEXITCODE = 0
}
try {
    $nativeOnly = (& $generator -RepoRoot $work -Verify Native) | ConvertFrom-Json
}
finally { Remove-Item Function:\pwsh -ErrorAction SilentlyContinue }
$nativeOnlyEntry = $nativeOnly | Where-Object id -eq $entry.id
if ($nativeOnlyEntry.native -ne 'Verified' -or $nativeOnlyEntry.docker -ne 'Unverified') {
    throw 'Successful Native verification must not mark the unexecuted Docker transport Verified.'
}
# Actual DocFX render checks tilde links, publishing, modern template composition and C# fidelity.
& (Get-Command docfx -CommandType Application).Source build "$work/docfx.json" --disableGitFeatures *> "$work/build.log"
if ($LASTEXITCODE -ne 0) { throw "DocFX render failed: $work/build.log" }
$html = Get-Content "$work/_site/docs/integration.html" -Raw
if (-not $html.Contains('data-example-id=') -or -not $html.Contains('View Native Script') -or -not $html.Contains('View Docker Script') -or
    -not (Test-Path "$work/_site/run-actions/$($entry.id)/native.ps1") -or -not (Test-Path "$work/_site/run-actions/$($entry.id)/docker.ps1")) {
    throw 'The rendered sample must deliver links to both published script assets.'
}
if (-not (Get-Content "$work/_site/public/main.js" -Raw).Contains("import './run-actions.js'")) { throw 'Modern template module not published.' }
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
if ($limitedEntry.coverage -ne 'Partially supported' -or $limitedEntry.docker -ne 'Unsupported' -or -not (Test-Path "$work/run-actions/$($entry.id)/native.ps1") -or (Test-Path "$work/run-actions/$($entry.id)/docker.ps1")) { throw 'Single-transport limitation was misrepresented.' }
if ((Get-Content "$work/docs/integration.md" -Raw).Contains('View Docker Script')) { throw 'Unsupported Docker still has a control.' }
$limitedAgain = (& $generator -RepoRoot $work) | ConvertFrom-Json
if (($limitedAgain | Where-Object id -eq $entry.id).status -ne 'unchanged') { throw 'Single-transport cache requires the unsupported script.' }
# Mutating the principal source invalidates its recipe and removes both associations and owned scripts.
[IO.File]::WriteAllText("$work/docs/integration.md", $updated.Replace('Bootstrapper Minimal Worker', 'Changed assertion'))
$third = (& $generator -RepoRoot $work) | ConvertFrom-Json
if ((Test-Path "$work/run-actions/$($entry.id)/native.ps1") -or (Get-Content "$work/docs/integration.md" -Raw).Contains('data-example-id')) { throw 'Stale recipe/assets survived source change.' }

# An invalid harness is a failed recipe, while a recorded intrinsic limitation has no assets.
$invalidRecipe = $packageRecipe | ConvertTo-Json -Depth 20 | ConvertFrom-Json -AsHashtable
$invalidRecipe.harness = @{members=42}
$partialResult = $discovery | Where-Object { $_.file -match '[\\/]partial\.md$' }
$intrinsic = @{uid=$partialResult.uid; sourceSha256=$partialResult.sourceSha256; intrinsicLimitation='Synthetic limitation for coverage classification.'}
$customSettings = "$work/custom-settings.json"
[IO.File]::WriteAllText($customSettings, (@{examples=@($invalidRecipe,$intrinsic)} | ConvertTo-Json -Depth 20))
$classified = (& $generator -RepoRoot $work -Settings $customSettings) | ConvertFrom-Json
$invalid = $classified | Where-Object id -eq $resolved.id
$limitedPartial = $classified | Where-Object id -eq $partialResult.id
if ($LASTEXITCODE -ne 1 -or $invalid.coverage -ne 'Unresolved' -or $invalid.reason -notlike '*C# must be a string*' -or
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
Write-Host "Run-action delivery passed: paired console, test, dependency-backed harness and repository test; exact pins and source, coverage classifications, independent verification state, incremental assets, stale cleanup and modern DocFX render. Fixture: $work"
