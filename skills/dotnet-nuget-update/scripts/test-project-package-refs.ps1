Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..\..')).Path
$workspace = Join-Path $repoRoot ('.bot\dotnet-nuget-update-tests\project-' + [Guid]::NewGuid().ToString('N'))
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
    $repoPath = Join-Path $workspace 'repo'
    Write-File -Path (Join-Path $repoPath 'src\App\App.csproj') -Content @'
<Project Sdk="Microsoft.NET.Sdk">
  <PropertyGroup>
    <TargetFramework>net10.0</TargetFramework>
  </PropertyGroup>
  <ItemGroup>
    <PackageReference Include="Newtonsoft.Json" Version="13.0.3" />
    <PackageReference Include="Asp.Versioning.Http" Version="8.1.0" />
  </ItemGroup>
</Project>
'@
    Write-File -Path (Join-Path $repoPath 'Directory.Build.props') -Content '<Project />'

    $updates = '[{"id":"Newtonsoft.Json","condition":null,"from":"13.0.3","to":"13.0.4"},{"id":"Asp.Versioning.Http","condition":null,"from":"8.1.0","to":"8.1.1"}]'
    $result = & pwsh -NoProfile -File (Join-Path $PSScriptRoot 'Apply-PackageUpdates.ps1') -RepoRoot $repoPath -Updates $updates -AsJson | ConvertFrom-Json

    Assert-Equal 'project-level mode is selected' $result.mode 'project'
    Assert-Equal 'project-level updates applied' (@($result.results | Where-Object { $_.outcome -eq 'applied' }).Count) 2

    $projectText = Get-Content -Raw -LiteralPath (Join-Path $repoPath 'src\App\App.csproj')
    if ($projectText -notmatch 'Newtonsoft\.Json" Version="13\.0\.4"' -or $projectText -notmatch 'Asp\.Versioning\.Http" Version="8\.1\.1"') {
        throw 'Project-level PackageReference versions were not updated.'
    }

    Write-Host 'test-project-package-refs.ps1: PASS'
}
finally {
    if (Test-Path -LiteralPath $workspace) { Remove-Item -LiteralPath $workspace -Recurse -Force -ErrorAction SilentlyContinue }
}
