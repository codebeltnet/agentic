Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. "$PSScriptRoot/_common.ps1"

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..\..')).Path
$workspace = Join-Path $repoRoot ('.bot\dotnet-nuget-update-tests\apply-' + [Guid]::NewGuid().ToString('N'))
$utf8NoBom = [System.Text.UTF8Encoding]::new($false)

function Write-File {
    param([string]$Path, [string]$Content, [ValidateSet('LF', 'CRLF')][string]$LineEnding = 'LF')
    $directory = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $directory)) { New-Item -ItemType Directory -Path $directory -Force | Out-Null }
    $normalized = $Content -replace "`r`n", "`n" -replace "`r", "`n"
    $final = if ($LineEnding -eq 'CRLF') { $normalized -replace "`n", "`r`n" } else { $normalized }
    [System.IO.File]::WriteAllText($Path, $final, $utf8NoBom)
}

function Assert-Equal {
    param([string]$Name, $Actual, $Expected)
    if ($Actual -ne $Expected) { throw "$Name failed. Expected '$Expected' but found '$Actual'." }
}

New-Item -ItemType Directory -Path $workspace -Force | Out-Null
try {
    $repoPath = Join-Path $workspace 'repo'
    Write-File -Path (Join-Path $repoPath 'Directory.Packages.props') -LineEnding CRLF -Content @'
<Project>
  <PropertyGroup>
    <ManagePackageVersionsCentrally>true</ManagePackageVersionsCentrally>
  </PropertyGroup>
  <ItemGroup>
    <PackageVersion Include="Newtonsoft.Json" Version="13.0.3" />
    <!-- Keep this comment exactly where it is -->
    <PackageVersion Include="SomePackage" Version="1.0.0" />
    <PackageVersion Include="Asp.Versioning.Http" Version="8.1.0" />
  </ItemGroup>
</Project>
'@
    Write-File -Path (Join-Path $repoPath 'README.txt') -Content 'do not touch'

    $updates = '[{"id":"Newtonsoft.Json","condition":null,"from":"13.0.3","to":"13.0.4"},{"id":"Asp.Versioning.Http","condition":null,"from":"8.1.0","to":"8.1.1"}]'
    $result = & pwsh -NoProfile -File (Join-Path $PSScriptRoot 'Apply-PackageUpdates.ps1') -RepoRoot $repoPath -Updates $updates -AsJson | ConvertFrom-Json

    Assert-Equal 'two central updates applied' (@($result.results | Where-Object { $_.outcome -eq 'applied' }).Count) 2

    $updatedText = Get-Content -Raw -LiteralPath (Join-Path $repoPath 'Directory.Packages.props')
    if ($updatedText -notmatch 'Newtonsoft\.Json" Version="13\.0\.4"' -or $updatedText -notmatch 'Asp\.Versioning\.Http" Version="8\.1\.1"') {
        throw 'Updated package versions were not written back.'
    }
    if ($updatedText -notmatch '<!-- Keep this comment exactly where it is -->') {
        throw 'XML comment was not preserved.'
    }
    Assert-Equal 'CRLF line endings are preserved' (Get-FileLineEndingStyle -Path (Join-Path $repoPath 'Directory.Packages.props')) 'CRLF'
    Assert-Equal 'unrelated file stays untouched' (Get-Content -Raw -LiteralPath (Join-Path $repoPath 'README.txt')) 'do not touch'

    $conflict = & pwsh -NoProfile -File (Join-Path $PSScriptRoot 'Apply-PackageUpdates.ps1') -RepoRoot $repoPath -Updates '[{"id":"Newtonsoft.Json","condition":null,"from":"13.0.3","to":"13.0.5"}]' -AsJson | ConvertFrom-Json
    Assert-Equal 'conflict is reported when from no longer matches' $conflict.results[0].outcome 'conflict'

    Write-Host 'test-apply-updates.ps1: PASS'
}
finally {
    if (Test-Path -LiteralPath $workspace) { Remove-Item -LiteralPath $workspace -Recurse -Force -ErrorAction SilentlyContinue }
}
