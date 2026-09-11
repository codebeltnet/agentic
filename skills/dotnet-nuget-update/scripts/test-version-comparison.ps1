Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. "$PSScriptRoot/_common.ps1"

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..\..')).Path
$workspace = Join-Path $repoRoot ('.bot\dotnet-nuget-update-tests\version-' + [Guid]::NewGuid().ToString('N'))
$utf8NoBom = [System.Text.UTF8Encoding]::new($false)

function Write-File {
    param([string]$Path, [string]$Content)
    $directory = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $directory)) { New-Item -ItemType Directory -Path $directory -Force | Out-Null }
    [System.IO.File]::WriteAllText($Path, $Content, $utf8NoBom)
}

function Assert-Equal {
    param([string]$Name, $Actual, $Expected)
    if ($Actual -ne $Expected) {
        throw "$Name failed. Expected '$Expected' but found '$Actual'."
    }
}

New-Item -ItemType Directory -Path $workspace -Force | Out-Null
try {
    $sourceRoot = Join-Path $workspace 'nuget-fixtures'
    Write-File -Path (Join-Path $sourceRoot 'newtonsoft.json\index.json') -Content '{ "versions": ["12.0.0","13.0.0","13.0.1","13.0.2","13.0.3","13.0.4","14.0.0"] }'
    Write-File -Path (Join-Path $sourceRoot 'awssdk.core\index.json') -Content '{ "versions": ["3.7.0.0","3.7.0.1","3.7.100.0","4.0.0.0","4.0.100.6","4.0.100.8"] }'
    Write-File -Path (Join-Path $sourceRoot 'xunit.v3\index.json') -Content '{ "versions": ["1.0.0","1.1.0","2.0.0-pre.1","2.0.0-pre.2"] }'
    Write-File -Path (Join-Path $sourceRoot 'somepackage.prerelease\index.json') -Content '{ "versions": ["1.0.0-rc.1","1.0.0-rc.2","2.0.0-rc.1"] }'

    $resolveStable = & pwsh -NoProfile -File (Join-Path $PSScriptRoot 'Resolve-NuGetVersion.ps1') -Id 'xunit.v3' -Source $sourceRoot -AsJson | ConvertFrom-Json
    Assert-Equal 'stable latest ignores prerelease' $resolveStable.latest '1.1.0'
    Assert-Equal 'latestStable reports stable version' $resolveStable.latestStable '1.1.0'
    Assert-Equal 'latestAny reports prerelease version' $resolveStable.latestAny '2.0.0-pre.2'

    $resolveAny = & pwsh -NoProfile -File (Join-Path $PSScriptRoot 'Resolve-NuGetVersion.ps1') -Id 'somepackage.prerelease' -Source $sourceRoot -IncludePrerelease -AsJson | ConvertFrom-Json
    Assert-Equal 'prerelease source reports latest prerelease' $resolveAny.latest '2.0.0-rc.1'

    $sorted = Sort-NuGetVersion -Version @('13.0.4', '13.0.2', '13.0.3')
    Assert-Equal 'Sort-NuGetVersion uses semantic ordering' ($sorted -join ',') '13.0.2,13.0.3,13.0.4'

    $prereleaseVsRelease = & pwsh -NoProfile -File (Join-Path $PSScriptRoot 'Compare-Version.ps1') -A '1.0.0-rc.2' -B '1.0.0' -AsJson | ConvertFrom-Json
    Assert-Equal 'prerelease sorts below release' $prereleaseVsRelease.relation 'lt'

    $releaseVsPrerelease = & pwsh -NoProfile -File (Join-Path $PSScriptRoot 'Compare-Version.ps1') -A '1.0.0' -B '1.0.0-rc.2' -AsJson | ConvertFrom-Json
    Assert-Equal 'release sorts above prerelease' $releaseVsPrerelease.relation 'gt'

    Assert-Equal 'no bump when versions equal' (Get-NuGetVersionBump -From '13.0.3' -To '13.0.3') 'none'
    Assert-Equal 'patch bump classification' (Get-NuGetVersionBump -From '13.0.3' -To '13.0.4') 'patch'
    Assert-Equal 'minor bump classification' (Get-NuGetVersionBump -From '13.0.0' -To '13.1.0') 'minor'
    Assert-Equal 'major bump classification' (Get-NuGetVersionBump -From '13.0.3' -To '14.0.0') 'major'
    Assert-Equal 'revision bump classification' (Get-NuGetVersionBump -From '4.0.100.6' -To '4.0.100.8') 'revision'
    Assert-Equal 'prerelease bump classification' (Get-NuGetVersionBump -From '1.0.0-rc.1' -To '1.0.0-rc.2') 'prerelease'

    Write-Host 'test-version-comparison.ps1: PASS'
}
finally {
    if (Test-Path -LiteralPath $workspace) { Remove-Item -LiteralPath $workspace -Recurse -Force -ErrorAction SilentlyContinue }
}
