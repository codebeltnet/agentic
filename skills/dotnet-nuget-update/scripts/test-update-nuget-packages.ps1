Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..\..')).Path
$workspace = Join-Path $repoRoot ('.bot\dotnet-nuget-update-tests\update-' + [Guid]::NewGuid().ToString('N'))
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
    Write-File -Path (Join-Path $sourceRoot 'safe.package\index.json') -Content '{ "versions": ["1.0.0","1.0.1"] }'
    Write-File -Path (Join-Path $sourceRoot 'note.package\index.json') -Content '{ "versions": ["1.0.0","1.0.1"] }'
    Write-File -Path (Join-Path $sourceRoot 'major.package\index.json') -Content '{ "versions": ["1.0.0","2.0.0"] }'

    $repoPath = Join-Path $workspace 'repo'
    Write-File -Path (Join-Path $repoPath 'Directory.Packages.props') -Content @'
<Project>
  <PropertyGroup>
    <ManagePackageVersionsCentrally>true</ManagePackageVersionsCentrally>
  </PropertyGroup>
  <ItemGroup>
    <PackageVersion Include="Safe.Package" Version="1.0.0" />
    <!-- Hold until downstream package catches up -->
    <PackageVersion Include="Note.Package" Version="1.0.0" />
    <PackageVersion Include="Major.Package" Version="1.0.0" />
  </ItemGroup>
</Project>
'@

    $runner = Join-Path $PSScriptRoot 'Update-NuGetPackages.ps1'
    $originalText = Get-Content -Raw -LiteralPath (Join-Path $repoPath 'Directory.Packages.props')
    $preview = & pwsh -NoProfile -File $runner -RepoRoot $repoPath -Yolo -Source $sourceRoot -DryRun -AsJson | ConvertFrom-Json
    Assert-Equal 'dry-run plans one safe update' @($preview.updates).Count 1
    Assert-Equal 'dry-run reports its preview outcome' $preview.apply.results[0].outcome 'dry-run'
    Assert-Equal 'dry-run counts no applied updates' $preview.appliedCount 0
    Assert-Equal 'dry-run leaves pending updates incomplete' $preview.applyComplete $false
    Assert-Equal 'dry-run preserves the package file' (Get-Content -Raw -LiteralPath (Join-Path $repoPath 'Directory.Packages.props')) $originalText

    $result = & pwsh -NoProfile -File $runner -RepoRoot $repoPath -Yolo -Source $sourceRoot -AsJson | ConvertFrom-Json
    Assert-Equal 'yolo mode is reported' $result.mode 'yolo'
    Assert-Equal 'one safe update is applied' $result.appliedCount 1
    Assert-Equal 'safe update completes' $result.applyComplete $true
    Assert-Equal 'major is held' @($result.heldMajors).Count 1
    Assert-Equal 'note-bearing auto candidate is held' @($result.noteHeld).Count 1

    $updatedText = Get-Content -Raw -LiteralPath (Join-Path $repoPath 'Directory.Packages.props')
    if ($updatedText -notmatch 'Safe\.Package" Version="1\.0\.1"') { throw 'Safe package was not updated.' }
    if ($updatedText -notmatch 'Note\.Package" Version="1\.0\.0"') { throw 'Note-bearing package was changed unexpectedly.' }
    if ($updatedText -notmatch 'Major\.Package" Version="1\.0\.0"') { throw 'Major package was changed unexpectedly.' }

    $dryRun = & pwsh -NoProfile -File $runner -RepoRoot $repoPath -Yolo -Source $sourceRoot -DryRun -AsJson | ConvertFrom-Json
    Assert-Equal 'dry-run reports no write for current repository' $dryRun.appliedCount 0
    Assert-Equal 'dry-run remains complete' $dryRun.applyComplete $true

    Write-Host 'test-update-nuget-packages.ps1: PASS'
}
finally {
    if (Test-Path -LiteralPath $workspace) { Remove-Item -LiteralPath $workspace -Recurse -Force -ErrorAction SilentlyContinue }
}
