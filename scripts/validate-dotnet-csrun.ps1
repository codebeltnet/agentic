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
& pwsh -NoProfile -NonInteractive -File (Join-Path $root 'scripts/test-sample-tools.ps1')
if ($LASTEXITCODE -ne 0) { throw 'Sample artifact helper regressions failed.' }
if (-not $EnginePath -and -not $Docker) { return }
if ($EnginePath) { $EnginePath = (Resolve-Path $EnginePath).Path }
. (Join-Path $root 'scripts/sample-tools.ps1')
$evidence = Join-Path ([IO.Path]::GetTempPath()) ('dotnet-csrun-evidence-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory $evidence | Out-Null
$OutputEncoding = [Text.UTF8Encoding]::new($false)
[Console]::OutputEncoding = $OutputEncoding
$cases = @(
    @('console', 0, '(?m)^42\s*$'),
    @('passing', 0, '(?is)total:\s*1.*failed:\s*0.*succeeded:\s*1.*skipped:\s*0'),
    @('failing', 2, 'Assert.Equal\(\) Failure'),
    @('empty', 8, '(?i)(zero tests|no tests|total:\s*0)'),
    @('invalid', -1, 'CS0103'),
    @('package', 0, '(?m)^273\s*$'),
    @('unicode', 0, 'Hello "C#" — æøå 世界\r?\nsecond line'),
    @('standalone-host', 0, '(?is)total:\s*1.*failed:\s*0.*succeeded:\s*1.*skipped:\s*0'),
    @('safe-adaptation', -1, 'CS0246'),
    @('safe-adaptation-corrected', 0, '(?is)total:\s*1.*failed:\s*0.*succeeded:\s*1.*skipped:\s*0'),
    @('inventory-worker', -1, 'CS0017'),
    @('multiple-entrypoints', -1, 'CS0017'),
    @('incorrect-package', -1, 'NU1101'),
    @('markdown-before', -1, 'CS1002'),
    @('markdown-after', 0, '(?m)^1970\s*$')
)
$environment = if ($Docker) {
    $images = @{}
    foreach ($tag in @('10', '11')) {
        $image = "codebeltnet/csrun:$tag"
        # Inventory first so docker run can pull an image that is not cached locally.
        $sdks = docker run --rm --entrypoint dotnet $image --list-sdks
        if ($LASTEXITCODE -ne 0) { throw "SDK inventory failed: $image" }
        $inspect = docker image inspect $image --format '{{json .}}' | ConvertFrom-Json
        if ($LASTEXITCODE -ne 0) { throw "Inspect failed: $image" }
        $runtimes = docker run --rm --entrypoint dotnet $image --list-runtimes
        if ($LASTEXITCODE -ne 0) { throw "Runtime inventory failed: $image" }
        $images[$image] = @{ imageId=$inspect.Id; digests=$inspect.RepoDigests; labels=$inspect.Config.Labels; os=$inspect.Os; architecture=$inspect.Architecture; sdks=$sdks; runtimes=$runtimes }
    }
    $images
} else {
    $info = dotnet --info
    if ($LASTEXITCODE -ne 0) { throw 'Native SDK inventory failed.' }
    @{ engineSha256=(Get-FileHash $EnginePath).Hash; dotnetInfo=$info; runtimes=@(dotnet --list-runtimes) }
}
$environment | ConvertTo-Json -Depth 20 | Set-Content (Join-Path $evidence 'environment.json') -Encoding utf8
Write-Host "Evidence directory: $evidence"
foreach ($case in $cases) {
    $name, $expectedExit, $pattern = $case
    if ($name -like 'markdown-*') {
        # Explicit inspected first-fence region; the partial second fence remains untouched.
        $document = [IO.File]::ReadAllText((Join-Path $root 'evals/files/repair.md'))
        $opening = '```csharp'
        $start = $document.IndexOf($opening, [StringComparison]::Ordinal) + $opening.Length
        $start = $document.IndexOf("`n", $start) + 1
        $end = $document.IndexOf('```', $start, [StringComparison]::Ordinal)
        $source = $document.Substring($start, $end - $start).TrimEnd("`r", "`n")
        $path = Join-Path $evidence 'repair.md'
        if ($name -eq 'markdown-before') { [IO.File]::WriteAllText($path, $document) }
        else {
            Set-CsrunSourceRegion -Path $path -Start $start -ExpectedSource $source -ReplacementSource ($source + ';')
            $source += ';'
        }
        $json = @{ schemaVersion=1; mode='console'; framework='net10.0'; source=$source } | ConvertTo-Json
    } else {
        $json = Get-Content (Join-Path $root "evals/files/$name.json") -Raw
    }
    $image = if (($json | ConvertFrom-Json).framework -eq 'net11.0') { 'codebeltnet/csrun:11' } else { 'codebeltnet/csrun:10' }
    $pair = New-CsrunExecutionPair -ManifestJson $json -Image $image -EnginePath $EnginePath
    $pair.ManifestJson | Set-Content (Join-Path $evidence "$name.manifest.json") -Encoding utf8
    $pair.Native | Set-Content (Join-Path $evidence "$name.native.ps1") -Encoding utf8
    $pair.Docker | Set-Content (Join-Path $evidence "$name.docker.ps1") -Encoding utf8
    $stderrPath = Join-Path $evidence "$name.stderr.log"
    if ($expectedExit -eq 0) {
        # Positive fixtures exercise the complete generated copy/paste artifact in a fresh process.
        $transport = if ($Docker) { 'docker' } else { 'native' }
        $stdout = & pwsh -NoProfile -NonInteractive -File (Join-Path $evidence "$name.$transport.ps1") 2> $stderrPath | Out-String
    } elseif ($Docker) {
        $stdout = $pair.ManifestJson | & docker run --rm -i $image 2> $stderrPath | Out-String
    } else {
        $stdout = & pwsh -NoProfile -NonInteractive -File $EnginePath -ManifestJson $pair.ManifestJson 2> $stderrPath | Out-String
    }
    $code = $LASTEXITCODE
    $stderr = Get-Content -LiteralPath $stderrPath -Raw
    $output = $stdout + $stderr
    $stdout | Set-Content (Join-Path $evidence "$name.stdout.log") -Encoding utf8
    $output | Set-Content (Join-Path $evidence "$name.log") -Encoding utf8
    @{ fixture=$name; exitCode=$code; transport=$(if ($Docker) {$image} else {$EnginePath}); sourceSha256=$pair.SourceSha256; manifestSha256=$pair.ManifestSha256; expectedExit=$expectedExit; expectedObservation=$pattern; observedUtc=[DateTime]::UtcNow.ToString('O'); environment='environment.json'; stdout="$name.stdout.log"; stderr="$name.stderr.log" } | ConvertTo-Json | Set-Content (Join-Path $evidence "$name.evidence.json")
    $plain = $output -replace '\x1B\[[0-?]*[ -/]*[@-~]', ''
    if (($expectedExit -eq -1 -and $code -eq 0) -or ($expectedExit -ne -1 -and $code -ne $expectedExit) -or $plain -notmatch $pattern) {
        throw "$name did not match expected exit/observation (exit $code). See $evidence/$name.log"
    }
    $observation = if ($name -in @('inventory-worker', 'multiple-entrypoints')) { 'expected compiler failure; no xUnit test executed' } else { 'expected observation matched' }
    Write-Host "PASS $name (exit $code; $observation)"
}
Write-Host "dotnet-csrun execution checks passed: $($cases.Count)"

