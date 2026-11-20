#requires -Version 7.0
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'sample-tools.ps1')
$root = Split-Path $PSScriptRoot -Parent
$fakeEngine = Join-Path ([IO.Path]::GetTempPath()) ('csrun-fake-' + [guid]::NewGuid().ToString('N') + '.ps1')
[IO.File]::WriteAllText($fakeEngine, "param([string]`$ManifestJson)`n[Console]::Write(`$ManifestJson)")
$checks = 0
function Assert-True($Condition, [string] $Message) {
    if (-not $Condition) { throw $Message }
    $script:checks++
}
function Assert-Throws([scriptblock] $Action, [string] $Message) {
    $threw = $false
    try { & $Action | Out-Null } catch { $threw = $true }
    Assert-True $threw $Message
}

$published = Get-Content (Join-Path $root 'references/standalone-example.md') -Raw
$publishedBlocks = [regex]::Matches($published, '(?s)```powershell\r?\n(.*?)\r?\n```')
$hostJson = Get-Content (Join-Path $root 'evals/files/standalone-host.json') -Raw
$hostIdentity = Get-CsrunSampleIdentity $hostJson
$hostPair = New-CsrunExecutionPair $hostJson -Image 'codebeltnet/csrun:10'
Assert-True ($publishedBlocks.Count -eq 2) 'Standalone example must offer two independent blocks.'
for ($index = 0; $index -lt 2; $index++) {
    $block = $publishedBlocks[$index].Groups[1].Value
    $expected = @($hostPair.Native, $hostPair.Docker)[$index]
    Assert-True ($block.Replace("`r`n", "`n").TrimEnd("`n") -ceq $expected.Replace("`r`n", "`n").TrimEnd("`n")) 'Published standalone block drifted.'
    Assert-True ((Get-CsrunSampleIdentity (Get-CsrunWrapperManifest $block)).ManifestSha256 -ceq $hostIdentity.ManifestSha256) 'Published standalone dependency/source parity failed.'
}
$publishedSource = [regex]::Match($published, '(?s)```csharp\r?\n(.*?)\r?\n```').Groups[1].Value
Assert-True ($publishedSource.Replace("`r`n", "`n") -ceq $hostIdentity.Source.Replace("`r`n", "`n")) 'Displayed C# differs from executed standalone source.'

foreach ($file in Get-ChildItem (Join-Path $root 'evals/files') -Filter '*.json') {
    $json = [IO.File]::ReadAllText($file.FullName)
    $item = ConvertFrom-Json $json -AsHashtable
    if (-not $item.Contains('source')) { continue }
    $pair = New-CsrunExecutionPair $json -Image 'codebeltnet/csrun:10' -EnginePath $fakeEngine
    foreach ($block in @($pair.Native, $pair.Docker)) {
        $tokens = $null; $parseErrors = $null
        $ast = [Management.Automation.Language.Parser]::ParseInput($block, [ref]$tokens, [ref]$parseErrors)
        Assert-True (-not $parseErrors.Count -and $ast.EndBlock.Statements[0] -is [Management.Automation.Language.PipelineAst] -and $ast.EndBlock.Statements[0].Extent.Text.StartsWith('& {')) 'Complete wrapper is not parsed as one outer script block.'
        $actual = Get-CsrunSampleIdentity (Get-CsrunWrapperManifest $block)
        Assert-True ($actual.ManifestSha256 -ceq $pair.ManifestSha256) "Manifest semantics drifted: $($file.Name)"
        Assert-True ($actual.Source -ceq $item.source) "Source drifted: $($file.Name)"
    }
}

# Exercise quotes, raw strings, CRLF, Unicode, dollars, and a PowerShell terminator inside C#.
$source = "using System;`r`nConsole.WriteLine(`"`"`"`r`n'@`r`n`$value æøå 世界 `"C#`"`r`n`"`"`" );"
$json = @{ schemaVersion=1; mode='console'; framework='net10.0'; source=$source; sdk='Microsoft.NET.Sdk.Web'; frameworkReferences=@('Microsoft.AspNetCore.App'); dependsOn=@('xunit.v3@4.0.3') } | ConvertTo-Json -Depth 8
$pair = New-CsrunExecutionPair $json -Image 'codebeltnet/csrun:10'
Assert-True ((Get-CsrunSampleIdentity (Get-CsrunWrapperManifest $pair.Native)).Source -ceq $source) 'Special source text was corrupted.'
$reordered = ($json | ConvertFrom-Json -AsHashtable)
$reordered.source += ' '
Assert-True ((Get-CsrunSampleIdentity ($reordered | ConvertTo-Json -Depth 8)).SourceSha256 -cne $pair.SourceSha256) 'Changed source reused an identity.'
$reordered.source = $source
$reordered.framework = 'net11.0'
Assert-True ((Get-CsrunSampleIdentity ($reordered | ConvertTo-Json -Depth 8)).ManifestSha256 -cne $pair.ManifestSha256) 'Changed framework reused an identity.'
$reordered.framework = 'net10.0'
$reordered.dependsOn = @('xunit.v3@4.0.4')
Assert-True ((Get-CsrunSampleIdentity ($reordered | ConvertTo-Json -Depth 8)).ManifestSha256 -cne $pair.ManifestSha256) 'Changed dependencies reused an identity.'
$reordered.dependsOn = @('xunit.v3@4.0.3')
$reordered.sdk = 'Microsoft.NET.Sdk'
Assert-True ((Get-CsrunSampleIdentity ($reordered | ConvertTo-Json -Depth 8)).ManifestSha256 -cne $pair.ManifestSha256) 'Changed SDK reused an identity.'
$reordered.sdk = 'Microsoft.NET.Sdk.Web'
$reordered.frameworkReferences = @()
Assert-True ((Get-CsrunSampleIdentity ($reordered | ConvertTo-Json -Depth 8)).ManifestSha256 -cne $pair.ManifestSha256) 'Changed references reused an identity.'
$console = [IO.File]::ReadAllText((Join-Path $root 'evals/files/console.json'))
$pair = New-CsrunExecutionPair $console -Image 'codebeltnet/csrun:10' -EnginePath $fakeEngine
$orderedDifferently = [ordered]@{ source=($console | ConvertFrom-Json).source; mode='console'; schemaVersion=1; framework='net10.0' } | ConvertTo-Json -Compress
Assert-True ((Get-CsrunSampleIdentity $orderedDifferently).ManifestSha256 -ceq $pair.ManifestSha256) 'Property order or JSON whitespace changed semantic identity.'
foreach ($change in @(@{schemaVersion=2}, @{mode='test'})) {
    $item = $console | ConvertFrom-Json -AsHashtable
    foreach ($key in $change.Keys) { $item[$key] = $change[$key] }
    Assert-True ((Get-CsrunSampleIdentity ($item | ConvertTo-Json)).ManifestSha256 -cne $pair.ManifestSha256) 'Changed schema/mode reused an identity.'
}
$diverged = $pair.Docker.Replace('WriteLine(42)', 'WriteLine(43)')
Assert-True ((Get-CsrunSampleIdentity (Get-CsrunWrapperManifest $diverged)).SourceSha256 -cne $pair.SourceSha256) 'Wrapper divergence went undetected.'
Assert-Throws { Get-CsrunWrapperManifest '$manifest = $(throw "must never execute")' } 'Nonliteral wrapper was accepted.'
Assert-Throws { Get-CsrunWrapperManifest ($pair.Native + "`n`$manifest = '{}'" ) } 'Multiple manifest assignments were accepted.'

Assert-True ($pair.Docker.Contains('$containerInput | & docker run --rm -i')) 'Docker no longer streams the manifest to the release script.'
Assert-True ($pair.Native.Contains("'-ManifestJson'")) 'Native invocation no longer uses the published parameter.'

# The wrapper verifies the published engine's ordinary output and status contract.
$testManifest = @{ schemaVersion = 1; mode = 'test'; source = 'using Xunit;' } | ConvertTo-Json
$testPair = New-CsrunExecutionPair $testManifest -Image 'codebeltnet/csrun:10' -EnginePath $fakeEngine
$remotePair = New-CsrunExecutionPair $testManifest -Image 'codebeltnet/csrun:10'
foreach ($transport in @('Native', 'Docker')) {
    Assert-True ($remotePair.$transport.Contains('releases/latest') -and $remotePair.$transport.Contains('Get-FileHash')) "$transport does not verify the latest release asset."
}
Assert-True ($remotePair.Docker.Contains('--entrypoint pwsh') -and $remotePair.Docker.Contains('WriteAllBytes($enginePath, $engineBytes)') -and $remotePair.Docker.Contains('& $enginePath -ManifestJson')) 'Docker does not execute the verified release asset.'
foreach ($transport in @('Native', 'Docker')) {
    Assert-True ($testPair.$transport.Contains('Assert-CsrunTestOutput')) "$transport lacks generated verification."
    Assert-True ($testPair.$transport -cnotmatch 'RequirePassingTests|ManifestStdin') "$transport uses undocumented parameters."
    Assert-True ((Get-CsrunWrapperManifest $testPair.$transport) -ceq $testPair.ManifestJson) "$transport changed manifest v1."
}
foreach ($output in @(
    'Passed! - Failed: 0, Passed: 1, Skipped: 0, Total: 1',
    'Passed! - Failed: 1, Passed: 0, Skipped: 0, Total: 1',
    'Passed! - Failed: 0, Passed: 0, Skipped: 1, Total: 1',
    'Passed! - Failed: 0, Passed: 0, Skipped: 0, Total: 0',
    'Passed! - Failed: 0, Passed: 1, Skipped: 0, Total: 1' + "`n" + 'Passed! - Failed: 0, Passed: 1, Skipped: 0, Total: 1',
    'build failed'
)) {
    $valid = $output -match '(?m)^Passed!.*Failed: 0, Passed: 1, Skipped: 0, Total: 1$' -and $output -notmatch '(?m)^Passed!.*(?:Failed: [1-9]|Skipped: [1-9]|Total: 0)'
    Assert-True ($valid -eq ($output -ceq 'Passed! - Failed: 0, Passed: 1, Skipped: 0, Total: 1')) 'Test-summary acceptance boundary failed.'
}# No prerequisites: generation/extraction still works; no engine is contacted or status fabricated.
Assert-True ((Get-CsrunWrapperManifest (New-CsrunExecutionPair $console -Image 'codebeltnet/csrun:10').Native) -eq $pair.ManifestJson) 'Template generation requires an execution environment.'

$temp = Join-Path ([IO.Path]::GetTempPath()) ('csrun-edit-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory $temp | Out-Null
try {
    $original = [IO.File]::ReadAllText((Join-Path $root 'evals/files/repair.md')).Replace("`r`n", "`n").Replace("`n", "`r`n")
    foreach ($encoding in @([Text.UTF8Encoding]::new($true), [Text.UTF8Encoding]::new($false), [Text.UnicodeEncoding]::new($false, $true), [Text.UnicodeEncoding]::new($true, $true))) {
        $path = Join-Path $temp 'sample.md'
        [IO.File]::WriteAllText($path, $original, $encoding)
        $old = 'Console.WriteLine(DateTime.UnixEpoch.Year)'
        $new = 'Console.WriteLine(DateTime.UnixEpoch.Year);'
        $start = $original.IndexOf($old, [StringComparison]::Ordinal)
        Set-CsrunSourceRegion -Path $path -Start $start -ExpectedSource $old -ReplacementSource $new
        $expected = $original.Replace($old, $new)
        $expectedBytes = [byte[]] ($encoding.GetPreamble() + $encoding.GetBytes($expected))
        Assert-True ([Convert]::ToBase64String($expectedBytes) -ceq [Convert]::ToBase64String([IO.File]::ReadAllBytes($path))) 'Repair changed surrounding content, BOM, encoding, or CRLF.'
        $snapshot = [IO.File]::ReadAllBytes($path)
        Assert-Throws { Set-CsrunSourceRegion -Path $path -Start $start -ExpectedSource 'stale source' -ReplacementSource $new } 'A stale repair overwrote source.'
        Assert-True ([Convert]::ToBase64String($snapshot) -ceq [Convert]::ToBase64String([IO.File]::ReadAllBytes($path))) 'Rejected repair modified the document.'
    }
} finally {
    # A unique OS-temporary directory, resolved and checked before recursive removal.
    $resolved = [IO.Path]::GetFullPath($temp)
    if (-not $resolved.StartsWith([IO.Path]::GetFullPath([IO.Path]::GetTempPath()), [StringComparison]::OrdinalIgnoreCase)) { throw 'Unsafe cleanup path.' }
    Remove-Item -LiteralPath $resolved -Recurse -Force
}
Write-Host "dotnet-csrun sample tools passed: $checks checks (offline transport doubles are not sample verification)."
