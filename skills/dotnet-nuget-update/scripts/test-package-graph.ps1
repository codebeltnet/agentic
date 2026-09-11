Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..\..')).Path
$workspace = Join-Path $repoRoot ('.bot\dotnet-nuget-update-tests\graph-' + [Guid]::NewGuid().ToString('N'))
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
    Write-File -Path (Join-Path $workspace 'repo\Directory.Packages.props') -Content @'
<Project>
  <PropertyGroup>
    <ManagePackageVersionsCentrally>true</ManagePackageVersionsCentrally>
  </PropertyGroup>
  <ItemGroup Condition="$(TargetFramework.StartsWith('net9'))">
    <PackageVersion Include="Microsoft.Extensions.Logging" Version="9.0.0" />
  </ItemGroup>
  <ItemGroup Condition="$(TargetFramework.StartsWith('net10'))">
    <PackageVersion Include="Microsoft.Extensions.Logging" Version="10.0.0" />
    <!-- Pinned until downstream package catches up -->
    <PackageVersion Include="SomePackage" Version="1.0.0" />
    <PackageVersion Include="Newtonsoft.Json" Version="13.0.3" />
  </ItemGroup>
</Project>
'@

    $graph = & pwsh -NoProfile -File (Join-Path $PSScriptRoot 'Get-PackageGraph.ps1') -RepoRoot (Join-Path $workspace 'repo') -AsJson | ConvertFrom-Json
    Assert-Equal 'graph reports file found' $graph.found $true
    Assert-Equal 'graph counts all declarations' $graph.packageCount 4
    Assert-Equal 'same package under multiple conditions yields two rows' (@($graph.packages | Where-Object { $_.id -eq 'Microsoft.Extensions.Logging' }).Count) 2

    $somePackage = $graph.packages | Where-Object { $_.id -eq 'SomePackage' }
    Assert-Equal 'adjacent xml comment is preserved' $somePackage.note 'Pinned until downstream package catches up'

    $filtered = & pwsh -NoProfile -File (Join-Path $PSScriptRoot 'Get-PackageGraph.ps1') -RepoRoot (Join-Path $workspace 'repo') -Package 'Microsoft.Extensions.Logging' -AsJson | ConvertFrom-Json
    Assert-Equal 'package filter keeps both conditional declarations' $filtered.packageCount 2

    Write-Host 'test-package-graph.ps1: PASS'
}
finally {
    if (Test-Path -LiteralPath $workspace) { Remove-Item -LiteralPath $workspace -Recurse -Force -ErrorAction SilentlyContinue }
}
