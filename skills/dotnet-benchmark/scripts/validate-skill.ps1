#requires -Version 5.1
<#
.SYNOPSIS
    Deterministically validates the dotnet-benchmark skill package and its read-only harness detector.

.PARAMETER SkillRoot
    Root of the dotnet-benchmark skill. Defaults to the parent of this script's directory.
#>
[CmdletBinding()]
param(
    [string]$SkillRoot
)

$ErrorActionPreference = 'Stop'
$failures = [System.Collections.Generic.List[string]]::new()

if ([string]::IsNullOrWhiteSpace($SkillRoot)) {
    $SkillRoot = Split-Path -Parent $PSScriptRoot
}

function Add-Failure {
    param([string]$Message)
    $failures.Add($Message)
}

function Assert-Contains {
    param([string]$Name, [string]$Content, [string]$Needle)
    if (-not $Content.Contains($Needle)) {
        Add-Failure "$Name is missing required content: $Needle"
    }
}

function Assert-File {
    param([string]$RelativePath)
    $path = Join-Path $SkillRoot $RelativePath
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        Add-Failure "Missing required file: $RelativePath"
    }
}

$SkillRoot = (Resolve-Path -LiteralPath $SkillRoot).Path
Write-Verbose "Validating skill root: $SkillRoot"

$requiredFiles = @(
    'SKILL.md',
    'FORMS.md',
    'assets/benchmark.csproj',
    'assets/benchmark-program.cs',
    'assets/benchmark-runner.csproj',
    'assets/comparison-benchmark.cs',
    'assets/operation-benchmark.cs',
    'references/benchmarkdotnet-essentials.md',
    'references/candidate-selection.md',
    'references/codebelt-conventions.md',
    'references/experiment-design.md',
    'references/onboarding.md',
    'references/runner-preflight.md',
    'scripts/check-benchmark-requirements.ps1',
    'evals/evals.json'
)

foreach ($file in $requiredFiles) {
    Assert-File $file
}
Write-Verbose 'Required file checks completed.'

if ($failures.Count -eq 0) {
    $skillPath = Join-Path $SkillRoot 'SKILL.md'
    $skill = [System.IO.File]::ReadAllText($skillPath)
    $skillLines = [System.IO.File]::ReadAllLines($skillPath)
    $benchmarkEssentials = [System.IO.File]::ReadAllText((Join-Path $SkillRoot 'references/benchmarkdotnet-essentials.md'))
    $lineCount = $skillLines.Count
    if ($lineCount -gt 500) {
        Add-Failure "SKILL.md must stay at or below 500 lines; found $lineCount"
    }

    $frontmatterEnd = [Array]::IndexOf($skillLines, '---', 1)
    $nameLine = $skillLines | Select-Object -First $frontmatterEnd | Where-Object { $_ -match '^name:\s*' } | Select-Object -First 1
    $descriptionStart = [Array]::IndexOf($skillLines, 'description: >')
    if ($skillLines[0] -ne '---' -or $frontmatterEnd -lt 1 -or $nameLine -ne 'name: dotnet-benchmark' -or $descriptionStart -lt 1 -or $descriptionStart -ge $frontmatterEnd) {
        Add-Failure 'SKILL.md frontmatter is missing the expected name and folded description'
    } else {
        $description = [string]::Join(' ', @($skillLines[($descriptionStart + 1)..($frontmatterEnd - 1)] | ForEach-Object { $_.Trim() } | Where-Object { $_ }))
        if ($description.Length -gt 1024) {
            Add-Failure "SKILL.md description exceeds 1024 characters; found $($description.Length)"
        }
    }
    Write-Verbose 'Frontmatter checks completed.'

    Assert-Contains 'SKILL.md' $skill 'Read `references/candidate-selection.md`'
    Assert-Contains 'SKILL.md' $skill 'Read `references/experiment-design.md`'
    Assert-Contains 'SKILL.md' $skill 'Do not use construction as the baseline for formatting, equality, hashing, parsing, or another unrelated operation.'
    Assert-Contains 'SKILL.md' $skill '--list flat'
    Assert-Contains 'SKILL.md' $skill '--job dry'
    Assert-Contains 'SKILL.md' $skill 'Never report performance numbers from a build, discovery listing, dry run, or unexecuted benchmark.'
    Assert-Contains 'SKILL.md' $skill '#### Yolo mode'
    Assert-Contains 'SKILL.md' $skill 'Start a full performance run only after an explicit human instruction to run it now.'
    Assert-Contains 'SKILL.md' $skill 'Yolo never authorizes a full performance run.'
    Assert-Contains 'SKILL.md' $skill 'read `references/runner-preflight.md`'
    Assert-Contains 'SKILL.md' $skill '-BenchmarkType <Namespace.TypeBenchmark>'
    Assert-Contains 'SKILL.md' $skill 'reports.wouldSkipRequestedBenchmark'
    Assert-Contains 'SKILL.md' $skill 'complete BenchmarkDotNet summary'
    Assert-Contains 'SKILL.md' $skill 'When a parameter is only size or payload'
    Assert-Contains 'SKILL.md' $skill 'After the first valid full result'

    $forms = [System.IO.File]::ReadAllText((Join-Path $SkillRoot 'FORMS.md'))
    Assert-Contains 'FORMS.md' $forms '## Yolo mode override'
    Assert-Contains 'FORMS.md' $forms 'skip `candidate_plan_confirmation`'
    Assert-Contains 'FORMS.md' $forms 'explicit human instruction to start a full performance run'

    $comparison = [System.IO.File]::ReadAllText((Join-Path $SkillRoot 'assets/comparison-benchmark.cs'))
    $operation = [System.IO.File]::ReadAllText((Join-Path $SkillRoot 'assets/operation-benchmark.cs'))
    foreach ($required in @('[MemoryDiagnoser]', '[GlobalSetup]', '[Params(', 'Baseline = true', '{EQUIVALENCE_CHECK}')) {
        Assert-Contains 'assets/comparison-benchmark.cs' $comparison $required
    }
    if (($comparison.Split(@('Baseline = true'), [System.StringSplitOptions]::None).Count - 1) -ne 1) {
        Add-Failure 'assets/comparison-benchmark.cs must contain exactly one Baseline = true marker'
    }
    foreach ($required in @('[MemoryDiagnoser]', '[GlobalSetup]', '[Params(', '{SUT_CALL}')) {
        Assert-Contains 'assets/operation-benchmark.cs' $operation $required
    }
    if ($operation -match '\[Benchmark\([^\]]*Baseline\s*=\s*true') {
        Add-Failure 'assets/operation-benchmark.cs must not fabricate a baseline'
    }

    $runner = [System.IO.File]::ReadAllText((Join-Path $SkillRoot 'assets/benchmark-program.cs'))
    Assert-Contains 'assets/benchmark-program.cs' $runner 'return c{RUNTIME_JOBS};'
    Assert-Contains 'assets/benchmark-program.cs' $runner '{RUNTIME_USINGS}'
    Assert-Contains 'assets/benchmark-program.cs' $runner '{RUNTIME_SETUP}'
    Assert-Contains 'assets/benchmark-program.cs' $runner 'public class Program'

    $runnerPreflight = [System.IO.File]::ReadAllText((Join-Path $SkillRoot 'references/runner-preflight.md'))
    Assert-Contains 'references/runner-preflight.md' $runnerPreflight 'SkipBenchmarksWithReports = true'
    Assert-Contains 'references/runner-preflight.md' $runnerPreflight 'reports/tuning/'
    Assert-Contains 'references/runner-preflight.md' $runnerPreflight 'Anti-thrashing rule'
    Assert-Contains 'references/experiment-design.md' ([System.IO.File]::ReadAllText((Join-Path $SkillRoot 'references/experiment-design.md'))) '## Workload invariants'
    Assert-Contains 'references/experiment-design.md' ([System.IO.File]::ReadAllText((Join-Path $SkillRoot 'references/experiment-design.md'))) '## Benchmark validity gate'
    Assert-Contains 'references/experiment-design.md' ([System.IO.File]::ReadAllText((Join-Path $SkillRoot 'references/experiment-design.md'))) '## Deferred execution and terminal operations'
    Assert-Contains 'references/benchmarkdotnet-essentials.md' $benchmarkEssentials 'one warmup iteration plus controlled iteration counts'
    Assert-Contains 'references/benchmarkdotnet-essentials.md' $benchmarkEssentials '## Deferred pipelines and terminal operations'
    Assert-Contains 'references/benchmarkdotnet-essentials.md' $benchmarkEssentials '## Result-validity gate'

    try {
        $evals = Get-Content -LiteralPath (Join-Path $SkillRoot 'evals/evals.json') -Raw | ConvertFrom-Json
        if ($evals.skill_name -ne 'dotnet-benchmark') {
            Add-Failure 'evals/evals.json skill_name must be dotnet-benchmark'
        }
        if ($evals.evals.Count -lt 11) {
            Add-Failure 'evals/evals.json must include at least eleven diverse evals'
        }
        if (-not ($evals.evals | Where-Object { $_.prompt -match '(?i)yolo' })) {
            Add-Failure 'evals/evals.json must include a yolo-mode interaction eval'
        }
        if (-not ($evals.evals | Where-Object { $_.prompt -match 'LegacyAliasQuery' })) {
            Add-Failure 'evals/evals.json must include the invalid parameter-matrix and drifting-selectivity eval'
        }
        if (-not ($evals.evals | Where-Object { $_.prompt -match 'TraitFilter helper only runs in test discovery' })) {
            Add-Failure 'evals/evals.json must include the proportionate-stopping eval'
        }
        $ids = @($evals.evals | ForEach-Object { $_.id })
        if (($ids | Sort-Object -Unique).Count -ne $ids.Count) {
            Add-Failure 'evals/evals.json contains duplicate eval IDs'
        }
        foreach ($eval in $evals.evals) {
            if ([string]::IsNullOrWhiteSpace($eval.prompt) -or [string]::IsNullOrWhiteSpace($eval.expected_output) -or $eval.expectations.Count -lt 1) {
                Add-Failure "Eval $($eval.id) must include a prompt, expected_output, and expectations"
            }
            foreach ($fixture in @($eval.files) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }) {
                $fixturePath = Join-Path $SkillRoot $fixture
                if (-not (Test-Path -LiteralPath $fixturePath -PathType Leaf)) {
                    Add-Failure "Eval $($eval.id) references missing fixture: $fixture"
                }
            }
        }
    } catch {
        Add-Failure "evals/evals.json is invalid: $($_.Exception.Message)"
    }
    $evalFixtureRoot = Join-Path $SkillRoot 'evals/files'
    if (Test-Path -LiteralPath $evalFixtureRoot) {
        Get-ChildItem -LiteralPath $evalFixtureRoot -Recurse -Directory -Force |
            Where-Object { $_.Name -in @('obj', 'bin', 'BenchmarkDotNet.Artifacts') } |
            ForEach-Object {
                $relativePath = $_.FullName.Substring($SkillRoot.Length).TrimStart('\')
                Add-Failure "Eval fixtures must not contain generated artifact directories: $relativePath"
            }
    }
    Write-Verbose 'Template and eval checks completed.'
}

$tempRoot = [System.IO.Path]::GetFullPath([System.IO.Path]::GetTempPath())
$fixtureRoot = Join-Path $tempRoot ("dotnet-benchmark-validator-" + [guid]::NewGuid().ToString('N'))
Write-Verbose "Creating detector fixture: $fixtureRoot"
try {
    New-Item -ItemType Directory -Path (Join-Path $fixtureRoot 'tuning/Acme.Core.Benchmarks') -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $fixtureRoot 'tooling/bdn-runner') -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $fixtureRoot 'reports/tuning') -Force | Out-Null
    [System.IO.File]::WriteAllText((Join-Path $fixtureRoot 'Acme.sln'), '')
    [System.IO.File]::WriteAllText((Join-Path $fixtureRoot 'Directory.Packages.props'), '<Project><ItemGroup><PackageVersion Include="BenchmarkDotNet" Version="1.0.0" /></ItemGroup></Project>')
    [System.IO.File]::WriteAllText((Join-Path $fixtureRoot 'Directory.Build.props'), '<Project><PropertyGroup><IsBenchmarkProject>false</IsBenchmarkProject><IsToolingProject>false</IsToolingProject></PropertyGroup></Project>')
    [System.IO.File]::WriteAllText((Join-Path $fixtureRoot 'tuning/Acme.Core.Benchmarks/Acme.Core.Benchmarks.csproj'), '<Project Sdk="Microsoft.NET.Sdk" />')
    [System.IO.File]::WriteAllText((Join-Path $fixtureRoot 'tooling/bdn-runner/bdn-runner.csproj'), '<Project Sdk="Microsoft.NET.Sdk"><ItemGroup><PackageReference Include="Codebelt.Extensions.BenchmarkDotNet.Console" /></ItemGroup></Project>')
    [System.IO.File]::WriteAllText((Join-Path $fixtureRoot 'tooling/bdn-runner/Program.cs'), 'using Codebelt.Extensions.BenchmarkDotNet; using Codebelt.Extensions.BenchmarkDotNet.Console; using BenchmarkDotNet.Environments; public class Program { public static void Main(string[] args) { BenchmarkProgram.Run(args, o => { o.SkipBenchmarksWithReports = true; o.ConfigureBenchmarkDotNet(c => { var slimJob = BenchmarkWorkspaceOptions.Slim; return c.AddJob(slimJob.WithRuntime(CoreRuntime.Core90)); }); }); } }')
    [System.IO.File]::WriteAllText((Join-Path $fixtureRoot 'reports/tuning/Acme.Core.WidgetBenchmark-report-github.md'), '# existing report')

    $detectorPath = Join-Path $SkillRoot 'scripts/check-benchmark-requirements.ps1'
    if (Test-Path -LiteralPath $detectorPath) {
        try {
            $detected = & powershell -NoProfile -ExecutionPolicy Bypass -File $detectorPath -RepoRoot $fixtureRoot -BenchmarkType Acme.Core.WidgetBenchmark -SkipSdkCheck | ConvertFrom-Json
            if ($detected.solutionFormat -ne 'sln' -or -not $detected.centralPackageManagement -or -not $detected.centralizesBenchmarkConventions) {
                Add-Failure 'Harness detector did not recognize the fixture solution, CPM, and centralized conventions'
            }
            if ($detected.sdk.status -ne 'skipped') {
                Add-Failure 'Harness detector did not report the intentional skipped SDK probe distinctly'
            }
            if ($detected.benchmarkProjects.Count -ne 1 -or $detected.runner.name -ne 'bdn-runner' -or -not $detected.harnessReady) {
                Add-Failure 'Harness detector did not recognize the existing benchmark project and runner'
            }
            if (-not $detected.runner.skipBenchmarksWithReports -or -not $detected.runner.usesSlimJob -or @($detected.runner.configuredRuntimes) -notcontains 'CoreRuntime.Core90') {
                Add-Failure 'Harness detector did not recognize report skipping, the Slim job, and configured runtime'
            }
            if (-not $detected.reports.wouldSkipRequestedBenchmark -or @($detected.reports.matchingReportFiles).Count -ne 1) {
                Add-Failure 'Harness detector did not identify the matching report that suppresses the requested benchmark type'
            }
        } catch {
            Add-Failure "Harness detector failed on the deterministic fixture: $($_.Exception.Message)"
        }
    }
} finally {
    $resolvedFixture = [System.IO.Path]::GetFullPath($fixtureRoot)
    if ($resolvedFixture.StartsWith($tempRoot, [System.StringComparison]::OrdinalIgnoreCase) -and (Test-Path -LiteralPath $resolvedFixture)) {
        Remove-Item -LiteralPath $resolvedFixture -Recurse -Force
    }
}
Write-Verbose 'Harness detector fixture checks completed.'

if ($failures.Count -gt 0) {
    foreach ($failure in $failures) {
        Write-Host "[FAIL] $failure" -ForegroundColor Red
    }
    exit 1
}

Write-Host '[PASS] dotnet-benchmark skill structure, templates, eval fixtures, and harness detector are valid.' -ForegroundColor Green
