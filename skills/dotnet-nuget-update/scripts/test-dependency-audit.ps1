Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..\..')).Path
$workspace = Join-Path $repoRoot ('.bot\dotnet-nuget-update-tests\audit-' + [Guid]::NewGuid().ToString('N'))
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
    Write-File -Path (Join-Path $sourceRoot 'microsoft.extensions.logging\index.json') -Content '{ "versions": ["9.0.0","9.0.1","10.0.0","11.0.0-preview.1"] }'
    Write-File -Path (Join-Path $sourceRoot 'newtonsoft.json\index.json') -Content '{ "versions": ["12.0.0","13.0.0","13.0.1","13.0.2","13.0.3"] }'
    Write-File -Path (Join-Path $sourceRoot 'asp.versioning.http\index.json') -Content '{ "versions": ["8.0.0","8.1.0","8.1.1","9.0.0"] }'
    Write-File -Path (Join-Path $sourceRoot 'somepackage\index.json') -Content '{ "versions": ["1.0.0","1.0.1"] }'

    Write-File -Path (Join-Path $workspace 'repo\Directory.Packages.props') -Content @'
<Project>
  <PropertyGroup>
    <ManagePackageVersionsCentrally>true</ManagePackageVersionsCentrally>
  </PropertyGroup>
  <ItemGroup Condition="$(TargetFramework.StartsWith('net9'))">
    <PackageVersion Include="Microsoft.Extensions.Logging" Version="9.0.0" />
  </ItemGroup>
  <ItemGroup>
    <PackageVersion Include="Newtonsoft.Json" Version="13.0.3" />
    <!-- Broken until downstream package catches up -->
    <PackageVersion Include="SomePackage" Version="1.0.0" />
    <PackageVersion Include="Asp.Versioning.Http" Version="8.1.0" />
    <PackageVersion Include="Unresolvable.Pkg" Version="1.0.0" />
  </ItemGroup>
</Project>
'@
    Write-File -Path (Join-Path $workspace 'repo\Directory.Build.props') -Content @'
<Project>
  <PropertyGroup>
    <TargetFramework>net9.0</TargetFramework>
  </PropertyGroup>
</Project>
'@

    $audit = & pwsh -NoProfile -File (Join-Path $PSScriptRoot 'Get-DependencyAudit.ps1') -RepoRoot (Join-Path $workspace 'repo') -Source $sourceRoot -AsJson | ConvertFrom-Json

    $logging = $audit.rows | Where-Object { $_.id -eq 'Microsoft.Extensions.Logging' }
    Assert-Equal 'net9 logging stays auto within band' $logging.action 'auto'
    Assert-Equal 'net9 logging resolves to newest 9.x' $logging.candidate '9.0.1'

    $asp = $audit.rows | Where-Object { $_.id -eq 'Asp.Versioning.Http' }
    Assert-Equal 'major candidate remains approval' $asp.action 'approval'
    Assert-Equal 'major candidate resolves newest overall' $asp.candidate '9.0.0'

    $somePackage = $audit.rows | Where-Object { $_.id -eq 'SomePackage' }
    Assert-Equal 'note field is populated' $somePackage.note 'Broken until downstream package catches up'
    Assert-Equal 'note-bearing auto update stays auto' $somePackage.action 'auto'
    if ($somePackage.reason -notmatch 'READ THE NOTE before applying') {
        throw 'Expected note-bearing auto update reason to include READ THE NOTE before applying.'
    }

    $unresolved = $audit.rows | Where-Object { $_.id -eq 'Unresolvable.Pkg' }
    Assert-Equal 'unresolvable package becomes unresolved row' $unresolved.action 'unresolved'
    Assert-Equal 'audit continues after unresolved package' $audit.summary.declared 5

    $total = $audit.summary.current + $audit.summary.auto + $audit.summary.approval + $audit.summary.unresolved
    Assert-Equal 'summary arithmetic closes' $total $audit.summary.declared

    Write-Host 'test-dependency-audit.ps1: PASS'
}
finally {
    if (Test-Path -LiteralPath $workspace) { Remove-Item -LiteralPath $workspace -Recurse -Force -ErrorAction SilentlyContinue }
}
