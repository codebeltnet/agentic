Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$skillRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$skillName = Split-Path -Leaf $skillRoot

$requiredFiles = @(
    'SKILL.md',
    'evals/evals.json',
    'scripts/_common.ps1',
    'scripts/Get-PackageGraph.ps1',
    'scripts/Get-DependencyAudit.ps1',
    'scripts/Get-TargetFrameworks.ps1',
    'scripts/Resolve-NuGetVersion.ps1',
    'scripts/Compare-Version.ps1',
    'scripts/Apply-PackageUpdates.ps1',
    'scripts/Update-NuGetPackages.ps1',
    'scripts/Get-NuGetSources.ps1',
    'scripts/run-tests.ps1',
    'scripts/validate-skill.ps1',
    'scripts/test-version-comparison.ps1',
    'scripts/test-tfm-band.ps1',
    'scripts/test-package-graph.ps1',
    'scripts/test-dependency-audit.ps1',
    'scripts/test-apply-updates.ps1',
    'scripts/test-project-package-refs.ps1',
    'scripts/test-update-nuget-packages.ps1'
)

foreach ($relativePath in $requiredFiles) {
    if (-not (Test-Path -LiteralPath (Join-Path $skillRoot $relativePath) -PathType Leaf)) {
        throw "Missing required file: $relativePath"
    }
}

$skillText = [System.IO.File]::ReadAllText((Join-Path $skillRoot 'SKILL.md'))
$frontmatter = [regex]::Match($skillText, '(?s)^---\r?\n(.*?)\r?\n---\r?\n')
if (-not $frontmatter.Success) {
    throw 'SKILL.md must start with YAML frontmatter.'
}

$nameMatch = [regex]::Match($frontmatter.Groups[1].Value, '(?m)^name:\s*(.+)$')
if (-not $nameMatch.Success) {
    throw 'SKILL.md frontmatter must contain a name field.'
}

if ($nameMatch.Groups[1].Value.Trim() -ne $skillName) {
    throw "SKILL.md frontmatter name must match folder name '$skillName'."
}

$scriptReferences = [regex]::Matches($skillText, 'scripts/[A-Za-z0-9._-]+\.ps1') |
    ForEach-Object { $_.Value.Replace('/', '\') } |
    Sort-Object -Unique
foreach ($reference in $scriptReferences) {
    if (-not (Test-Path -LiteralPath (Join-Path $skillRoot $reference) -PathType Leaf)) {
        throw "SKILL.md references a missing script: $reference"
    }
}

$evals = Get-Content -Raw -LiteralPath (Join-Path $skillRoot 'evals/evals.json') | ConvertFrom-Json
if ($evals.skill_name -ne $skillName) {
    throw "evals/evals.json skill_name must equal '$skillName'."
}

foreach ($eval in @($evals.evals)) {
    foreach ($relativePath in @($eval.files)) {
        if (-not (Test-Path -LiteralPath (Join-Path $skillRoot $relativePath) -PathType Leaf)) {
            throw "Missing eval fixture: $relativePath"
        }
    }
}

$commonPath = Join-Path $skillRoot 'scripts/_common.ps1'
& pwsh -NoProfile -Command ". '$commonPath'"
if ($LASTEXITCODE -ne 0) {
    throw "_common.ps1 failed to load with exit code $LASTEXITCODE."
}

foreach ($testScript in Get-ChildItem -LiteralPath (Join-Path $skillRoot 'scripts') -Filter 'test-*.ps1' -File) {
    $tokens = $null
    $errors = $null
    [System.Management.Automation.Language.Parser]::ParseFile($testScript.FullName, [ref]$tokens, [ref]$errors) | Out-Null
    if ($errors.Count -gt 0) {
        $message = $errors | Select-Object -First 1 | ForEach-Object { $_.Message }
        throw "$($testScript.Name) has a syntax error: $message"
    }
}

Write-Host 'dotnet-nuget-update skill validation: PASS'
