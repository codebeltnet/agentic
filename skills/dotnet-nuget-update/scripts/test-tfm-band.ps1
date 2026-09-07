Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. "$PSScriptRoot/_common.ps1"

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..\..')).Path
$workspace = Join-Path $repoRoot ('.bot\dotnet-nuget-update-tests\tfm-' + [Guid]::NewGuid().ToString('N'))
$utf8NoBom = [System.Text.UTF8Encoding]::new($false)

function Write-File {
    param([string]$Path, [string]$Content)
    $directory = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $directory)) { New-Item -ItemType Directory -Path $directory -Force | Out-Null }
    [System.IO.File]::WriteAllText($Path, $Content, $utf8NoBom)
}

function Assert-Equal {
    param([string]$Name, $Actual, $Expected)
    if ($Actual -ne $Expected) { throw "$Name failed. Expected '$Expected' but found '$Actual'." }
}

New-Item -ItemType Directory -Path $workspace -Force | Out-Null
try {
    $sourceRoot = Join-Path $workspace 'nuget-fixtures'
    Write-File -Path (Join-Path $sourceRoot 'microsoft.extensions.logging\index.json') -Content '{ "versions": ["9.0.0","9.0.5","10.0.0","10.0.2","11.0.0-preview.1"] }'
    Write-File -Path (Join-Path $sourceRoot 'microsoft.entityframeworkcore\index.json') -Content '{ "versions": ["10.0.0","10.0.7","11.0.0-preview.1"] }'
    Write-File -Path (Join-Path $sourceRoot 'asp.versioning.http\index.json') -Content '{ "versions": ["8.0.0","8.1.0","8.1.1","9.0.0"] }'

    Write-File -Path (Join-Path $workspace 'repo\Directory.Packages.props') -Content @'
<Project>
  <PropertyGroup>
    <ManagePackageVersionsCentrally>true</ManagePackageVersionsCentrally>
  </PropertyGroup>
  <ItemGroup Condition="$(TargetFramework.StartsWith('net9'))">
    <PackageVersion Include="Microsoft.Extensions.Logging" Version="9.0.0" />
    <PackageVersion Include="Asp.Versioning.Http" Version="8.1.0" />
  </ItemGroup>
  <ItemGroup Condition="$(TargetFramework.StartsWith('net10'))">
    <PackageVersion Include="Microsoft.Extensions.Logging" Version="10.0.0" />
  </ItemGroup>
  <ItemGroup Condition="$(TargetFramework.StartsWith('net10')) OR $(TargetFramework.StartsWith('net11'))">
    <PackageVersion Include="Microsoft.EntityFrameworkCore" Version="10.0.0" />
  </ItemGroup>
</Project>
'@
    Write-File -Path (Join-Path $workspace 'repo\Directory.Build.props') -Content @'
<Project>
  <PropertyGroup>
    <TargetFrameworks>net9.0;net10.0;net11.0</TargetFrameworks>
  </PropertyGroup>
</Project>
'@

    Assert-Equal 'net9 band extraction' ((Get-TfmBand -Condition '$(TargetFramework.StartsWith(''net9''))') -join ',') '9'
    Assert-Equal 'combined band extraction keeps both bands' ((Get-TfmBand -Condition '$(TargetFramework.StartsWith(''net10'')) OR $(TargetFramework.StartsWith(''net11''))') -join ',') '10,11'

    $audit = & pwsh -NoProfile -File (Join-Path $PSScriptRoot 'Get-DependencyAudit.ps1') -RepoRoot (Join-Path $workspace 'repo') -Source $sourceRoot -AsJson | ConvertFrom-Json

    $net9Logging = $audit.rows | Where-Object { $_.id -eq 'Microsoft.Extensions.Logging' -and $_.condition -eq '$(TargetFramework.StartsWith(''net9''))' }
    Assert-Equal 'net9 package stays in 9.x band' $net9Logging.candidate '9.0.5'
    Assert-Equal 'net9 package reports band 9' $net9Logging.band 9

    $net10Logging = $audit.rows | Where-Object { $_.id -eq 'Microsoft.Extensions.Logging' -and $_.condition -eq '$(TargetFramework.StartsWith(''net10''))' }
    Assert-Equal 'net10 package stays in 10.x band' $net10Logging.candidate '10.0.2'
    Assert-Equal 'net10 package reports band 10' $net10Logging.band 10

    $aspVersioning = $audit.rows | Where-Object { $_.id -eq 'Asp.Versioning.Http' }
    Assert-Equal 'mismatched major infers no band' $aspVersioning.band $null
    Assert-Equal 'mismatched major can select 9.0.0' $aspVersioning.candidate '9.0.0'

    $efCore = $audit.rows | Where-Object { $_.id -eq 'Microsoft.EntityFrameworkCore' }
    Assert-Equal 'combined condition chooses band 10' $efCore.band 10
    Assert-Equal 'combined condition stays in 10.x' $efCore.candidate '10.0.7'

    Write-Host 'test-tfm-band.ps1: PASS'
}
finally {
    if (Test-Path -LiteralPath $workspace) { Remove-Item -LiteralPath $workspace -Recurse -Force -ErrorAction SilentlyContinue }
}
