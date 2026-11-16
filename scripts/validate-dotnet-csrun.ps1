#requires -Version 7.0
[CmdletBinding()]
param(
    [string] $EnginePath,
    [switch] $Docker
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
if ($EnginePath -and $Docker) { throw 'Choose native EnginePath or Docker.' }
$root = Join-Path $PSScriptRoot '../skills/dotnet-csrun'
. (Join-Path $PSScriptRoot 'file-based-app.ps1')
$app = Get-FileBasedAppCommand -SourcePath (Join-Path $root 'scripts/validate.cs')
& $app.Executable @($app.ArgumentPrefix + @($root))
if ($LASTEXITCODE -ne 0) { throw 'Skill artifact validation failed.' }
if (-not $EnginePath -and -not $Docker) { return }
if ($EnginePath) { $EnginePath = (Resolve-Path $EnginePath).Path }
$evidence = Join-Path ([IO.Path]::GetTempPath()) ('dotnet-csrun-evidence-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory $evidence | Out-Null
$OutputEncoding = [Text.UTF8Encoding]::new($false)
$cases = @(
    @('console', 0, '(?m)^42\s*$'),
    @('passing', 0, '(?is)total:\s*1.*failed:\s*0.*succeeded:\s*1.*skipped:\s*0'),
    @('failing', 2, 'Assert.Equal\(\) Failure'),
    @('empty', 8, '(?i)(zero tests|no tests|total:\s*0)'),
    @('invalid', -1, 'CS0103'),
    @('package', 0, '(?m)^273\s*$'),
    @('unicode', 0, 'Hello "C#" — æøå 世界\r?\nsecond line')
)
Write-Host "Evidence directory: $evidence"
foreach ($case in $cases) {
    $name, $expectedExit, $pattern = $case
    $json = Get-Content (Join-Path $root "evals/files/$name.json") -Raw
    if ($Docker) {
        $image = if ($name -eq 'package') { 'codebeltnet/csrun:11' } else { 'codebeltnet/csrun:10' }
        $output = $json | & docker run --rm -i $image 2>&1 | Out-String
    } else {
        $output = & pwsh -NoProfile -NonInteractive -File $EnginePath -ManifestJson $json 2>&1 | Out-String
    }
    $code = $LASTEXITCODE
    $output | Set-Content (Join-Path $evidence "$name.log") -Encoding utf8
    @{ fixture=$name; exitCode=$code; transport=$(if ($Docker) {$image} else {$EnginePath}); manifestSha256=(Get-FileHash (Join-Path $root "evals/files/$name.json")).Hash } | ConvertTo-Json | Set-Content (Join-Path $evidence "$name.evidence.json")
    $plain = $output -replace '\x1B\[[0-?]*[ -/]*[@-~]', ''
    if (($expectedExit -eq -1 -and $code -eq 0) -or ($expectedExit -ne -1 -and $code -ne $expectedExit) -or $plain -notmatch $pattern) {
        throw "$name did not match expected exit/observation (exit $code). See $evidence/$name.log"
    }
    Write-Host "PASS $name (exit $code; expected observation matched)"
}
Write-Host 'dotnet-csrun execution checks passed: 7'

