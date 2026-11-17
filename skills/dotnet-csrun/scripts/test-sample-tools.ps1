#requires -Version 7.0
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'sample-tools.ps1')
$root = Split-Path $PSScriptRoot -Parent
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
    Assert-True ($block.Replace("`r`n", "`n") -ceq $expected.Replace("`r`n", "`n")) 'Published standalone block drifted.'
    Assert-True ((Get-CsrunSampleIdentity (Get-CsrunWrapperManifest $block)).ManifestSha256 -ceq $hostIdentity.ManifestSha256) 'Published standalone dependency/source parity failed.'
}
$publishedSource = [regex]::Match($published, '(?s)```csharp\r?\n(.*?)\r?\n```').Groups[1].Value
Assert-True ($publishedSource.Replace("`r`n", "`n") -ceq $hostIdentity.Source.Replace("`r`n", "`n")) 'Displayed C# differs from executed standalone source.'

foreach ($file in Get-ChildItem (Join-Path $root 'evals/files') -Filter '*.json') {
    $json = [IO.File]::ReadAllText($file.FullName)
    $item = ConvertFrom-Json $json -AsHashtable
    if (-not $item.Contains('source')) { continue }
    $pair = New-CsrunExecutionPair $json -Image 'codebeltnet/csrun:10' -EnginePath "C:/reviewed engine's/csrun.ps1"
    foreach ($block in @($pair.Native, $pair.Docker)) {
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
$pair = New-CsrunExecutionPair $console -Image 'codebeltnet/csrun:10' -EnginePath '/reviewed/csrun.ps1'
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

# Test the generated blocks themselves in independent scopes, without real engine prerequisites.
# These are transport contract doubles, never behavioral sample execution evidence.
foreach ($transport in @('Native', 'Docker')) {
    $received = & {
        param($Block, $Transport)
        function dotnet { throw 'The Docker host must not need dotnet.' }
        function docker {
            if ($Transport -ne 'Docker') { throw 'Native block must not need Docker.' }
            $lines = @($input)
            $script:captured = $lines -join "`n"
            if (($args -join ' ') -cne 'run --rm -i codebeltnet/csrun:10') { throw 'Unexpected Docker flags.' }
            $global:LASTEXITCODE = 0
        }
        function pwsh {
            if ($Transport -ne 'Native') { throw 'Docker block must not need native engine.' }
            $index = [Array]::IndexOf($args, '-ManifestJson')
            if ($index -lt 0) { throw 'Missing native manifest.' }
            $script:captured = $args[$index + 1]
            $global:LASTEXITCODE = 0
        }
        $script:captured = $null
        & ([scriptblock]::Create($Block))
        $script:captured
    } $pair.$transport $transport
    Assert-True ((Get-CsrunSampleIdentity $received).ManifestSha256 -ceq $pair.ManifestSha256) "$transport block was not independently executable."
}
Assert-Throws {
    & {
        function docker { $input | Out-Null; $global:LASTEXITCODE = 2 }
        & ([scriptblock]::Create($pair.Docker))
    }
} 'Generated block silently swallowed an engine failure.'

# The engine owns test verification and the wrappers pass its output through.
$testManifest = @{ schemaVersion = 1; mode = 'test'; source = 'using Xunit;' } | ConvertTo-Json
$testPair = New-CsrunExecutionPair $testManifest -Image 'codebeltnet/csrun:10' -EnginePath '/reviewed/csrun.ps1' -RequirePassingTests
$remotePair = New-CsrunExecutionPair $testManifest -Image 'codebeltnet/csrun:10' -RequirePassingTests
Assert-True ($remotePair.Native.Contains('-ManifestJson $manifest -RequirePassingTests')) 'Downloaded engine was not asked to verify tests.'
$ordinaryPair = New-CsrunExecutionPair $testManifest -Image 'codebeltnet/csrun:10'
foreach ($transport in @('Native', 'Docker')) {
    Assert-True (-not $ordinaryPair.$transport.Contains('-RequirePassingTests')) "$transport opted ordinary callers into strict verification."
    Assert-True ($testPair.$transport -cnotmatch '\$testOutput|\[regex\]|Test run summary') "$transport still interprets console output."
    Assert-True ((Get-CsrunWrapperManifest $testPair.$transport) -ceq $testPair.ManifestJson) "$transport changed the manifest for strict verification."
    $wrapper = [scriptblock]::Create($testPair.$transport)
    function pwsh {
        if ($args[-1] -cne '-RequirePassingTests') { throw 'Missing native strict verification option.' }
        $global:LASTEXITCODE = $runnerCode
        'Runner output in any format'
    }
    function docker {
        $input | Out-Null
        if (($args -join ' ') -cne 'run --rm -i --entrypoint pwsh codebeltnet/csrun:10 -NoProfile -NonInteractive -File /opt/csrun/csrun.ps1 -ManifestStdin -RequirePassingTests') {
            throw 'Unexpected strict Docker command.'
        }
        $global:LASTEXITCODE = $runnerCode
        'Runner output in any format'
    }
    $runnerCode = 0
    Assert-True ((& $wrapper) -ceq 'Runner output in any format') "$transport did not preserve arbitrary runner output."
    $runnerCode = 23
    Assert-Throws { & $wrapper } "$transport swallowed a nonzero engine status."
    Remove-Item Function:\pwsh, Function:\docker
}
# No prerequisites: generation/extraction still works; no engine is contacted or status fabricated.
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
