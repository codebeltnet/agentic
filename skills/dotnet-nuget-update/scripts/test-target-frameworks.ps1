Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$workspace = Join-Path ([System.IO.Path]::GetTempPath()) ('dotnet-nuget-update-workspace/' + [Guid]::NewGuid().ToString('N'))
function Write-Fixture {
    param([string]$Path, [string]$Content)
    $destination = Join-Path $workspace $Path
    New-Item -ItemType Directory -Path (Split-Path -Parent $destination) -Force | Out-Null
    [System.IO.File]::WriteAllText($destination, $Content)
}
try {
    Write-Fixture 'Directory.Build.props' '<Project><PropertyGroup><Framework>net8.0</Framework></PropertyGroup></Project>'
    Write-Fixture 'a/Directory.Build.props' '<Project><Import Project="../shared/first.props" /><PropertyGroup><Framework>net9.0</Framework></PropertyGroup></Project>'
    Write-Fixture 'shared/first.props' '<Project><Import Project="$(MSBuildThisFileDirectory)second.props" /></Project>'
    Write-Fixture 'shared/second.props' '<Project><PropertyGroup><ExtraFramework>netstandard2.0</ExtraFramework></PropertyGroup></Project>'
    Write-Fixture 'a/A.csproj' '<Project><PropertyGroup><TargetFrameworks>$(Framework);$(ExtraFramework)</TargetFrameworks></PropertyGroup></Project>'
    Write-Fixture 'b/Directory.Build.props' '<Project><PropertyGroup><Framework>net10.0</Framework></PropertyGroup></Project>'
    Write-Fixture 'b/B.csproj' '<Project><PropertyGroup><TargetFramework>$(Framework)</TargetFramework></PropertyGroup></Project>'
    Write-Fixture 'c/C.csproj' '<Project><PropertyGroup><TargetFramework>$(PrivateFramework)</TargetFramework></PropertyGroup></Project>'
    Write-Fixture 'unused.props' '<Project><PropertyGroup><PrivateFramework>net7.0</PrivateFramework></PropertyGroup></Project>'
    Write-Fixture 'd/D.csproj' '<Project><Import Project="local.props" /><PropertyGroup><TargetFramework>$(Framework)</TargetFramework></PropertyGroup></Project>'
    Write-Fixture 'd/local.props' '<Project><PropertyGroup><Framework>net6.0</Framework></PropertyGroup></Project>'
    Write-Fixture 'e/E.csproj' '<Project><Import Project="before.props" /><PropertyGroup><Framework>net5.0</Framework><TargetFramework>$(Framework)</TargetFramework></PropertyGroup><Import Project="after.targets" /></Project>'
    Write-Fixture 'e/before.props' '<Project><Import Project="before.props" /><PropertyGroup><Framework>net6.0</Framework></PropertyGroup></Project>'
    Write-Fixture 'e/after.targets' '<Project><PropertyGroup><Framework>net7.0</Framework></PropertyGroup></Project>'
    Write-Fixture 'e/Directory.Build.targets' '<Project><PropertyGroup><Framework>net9.0</Framework></PropertyGroup></Project>'
    $result = & "$PSScriptRoot/Get-TargetFrameworks.ps1" -RepoRoot $workspace
    foreach ($case in @(@('a/A.csproj', 'net9.0,netstandard2.0'), @('b/B.csproj', 'net10.0'), @('c/C.csproj', ''), @('d/D.csproj', 'net6.0'), @('e/E.csproj', 'net5.0'))) {
        $project = $result.projects | Where-Object { $_.path.Replace('\', '/') -eq $case[0] }
        if (($project.targetFrameworks -join ',') -ne $case[1]) { throw "Wrong frameworks for $($case[0]): $($project.targetFrameworks -join ',')" }
    }
    if ($result.unresolvedTokens -notcontains '$(PrivateFramework)') { throw 'Unimported property must remain unresolved.' }
    Write-Host 'test-target-frameworks.ps1: PASS'
}
finally {
    $resolvedWorkspace = [System.IO.Path]::GetFullPath($workspace)
    $allowedRoot = [System.IO.Path]::GetFullPath((Join-Path ([System.IO.Path]::GetTempPath()) 'dotnet-nuget-update-workspace')) + [System.IO.Path]::DirectorySeparatorChar
    if (-not $resolvedWorkspace.StartsWith($allowedRoot, [System.StringComparison]::OrdinalIgnoreCase)) { throw 'Unsafe fixture cleanup path.' }
    if (Test-Path -LiteralPath $resolvedWorkspace) { Remove-Item -LiteralPath $resolvedWorkspace -Recurse -Force }
}
