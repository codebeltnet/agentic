<#
.SYNOPSIS
    Adapts this repository's portable eval results to Anthropic skill-creator's benchmark and viewer tools.

.DESCRIPTION
    This is an adapter, not a replacement report implementation. It mirrors the recorded portable results into
    skill-creator's eval workspace contract, invokes aggregate_benchmark.py, and invokes eval-viewer's
    generate_review.py in static mode. The generated report therefore uses the upstream skill-creator viewer.

    No model or grader is started by this script. Grading must already be present in the portable result files or
    must have been performed by the user-directed external evaluator before this adapter is called.

.PARAMETER IterationDirectory
    Prepared eval iteration containing manifest.json and the eval-case result files.

.PARAMETER OutputPath
    Optional HTML path. Defaults to report.html at the iteration root.

.PARAMETER BenchmarkPath
    Optional benchmark JSON path. Defaults to benchmark.json at the iteration root.

.PARAMETER BenchmarkMarkdownPath
    Optional benchmark Markdown path. Defaults to benchmark.md at the iteration root.

.PARAMETER SkillCreatorPath
    Optional skill-creator installation or package-local tools/skill-creator path. The package-local path is the
    default so a prepared package remains self-contained after preparation.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, Position = 0)]
    [string]$IterationDirectory,

    [string]$OutputPath,

    [string]$BenchmarkPath,

    [string]$BenchmarkMarkdownPath,

    [string]$SkillCreatorPath
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$utf8NoBom = [System.Text.UTF8Encoding]::new($false)

function Read-JsonFile {
    param([string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        throw "Missing JSON file '$Path'."
    }

    return [System.IO.File]::ReadAllText($Path, $utf8NoBom) | ConvertFrom-Json
}

function Write-JsonFile {
    param(
        [string]$Path,
        [object]$Value
    )

    $directory = Split-Path -Parent $Path
    if (-not [string]::IsNullOrWhiteSpace($directory)) {
        New-Item -ItemType Directory -Path $directory -Force | Out-Null
    }

    [System.IO.File]::WriteAllText($Path, (($Value | ConvertTo-Json -Depth 30) + [Environment]::NewLine), $utf8NoBom)
}

function Write-TextFile {
    param(
        [string]$Path,
        [string]$Content
    )

    $directory = Split-Path -Parent $Path
    if (-not [string]::IsNullOrWhiteSpace($directory)) {
        New-Item -ItemType Directory -Path $directory -Force | Out-Null
    }

    [System.IO.File]::WriteAllText($Path, (($Content -replace "`r`n", "`n" -replace "`r", "`n") + [Environment]::NewLine), $utf8NoBom)
}

function Get-Property {
    param(
        [object]$Object,
        [string]$Name,
        [object]$Default = $null
    )

    if ($null -ne $Object -and $Object.PSObject.Properties.Name -contains $Name -and $null -ne $Object.$Name) {
        return $Object.$Name
    }

    return $Default
}

function Get-SafeSegment {
    param([string]$Value)

    $safe = $Value -replace '[^A-Za-z0-9._-]+', '-'
    $safe = $safe.Trim('-')
    if ([string]::IsNullOrWhiteSpace($safe)) {
        return 'eval'
    }

    return $safe
}

function Resolve-SkillCreatorPath {
    param([string]$RequestedPath)

    $candidates = [System.Collections.Generic.List[string]]::new()
    if (-not [string]::IsNullOrWhiteSpace($RequestedPath)) {
        $candidates.Add($RequestedPath)
    }

    $packagePath = Join-Path $iterationPath 'tools/skill-creator'
    $candidates.Add($packagePath)

    if (-not [string]::IsNullOrWhiteSpace($env:SKILL_CREATOR_PATH)) {
        $candidates.Add($env:SKILL_CREATOR_PATH)
    }

    if (-not [string]::IsNullOrWhiteSpace($env:USERPROFILE)) {
        $candidates.Add((Join-Path $env:USERPROFILE '.agents/skills/skill-creator'))
        $candidates.Add((Join-Path $env:USERPROFILE '.claude/skills/skill-creator'))
        $candidates.Add((Join-Path $env:USERPROFILE '.gemini/antigravity-cli/skills/skill-creator'))
    }

    foreach ($candidate in $candidates) {
        if ((Test-Path -LiteralPath (Join-Path $candidate 'scripts/aggregate_benchmark.py')) -and
            (Test-Path -LiteralPath (Join-Path $candidate 'eval-viewer/generate_review.py')) -and
            (Test-Path -LiteralPath (Join-Path $candidate 'eval-viewer/viewer.html'))) {
            return (Resolve-Path -LiteralPath $candidate).Path
        }
    }

    throw "Anthropic skill-creator eval tools were not found. Prepare the package with skill-creator available, or pass -SkillCreatorPath / set SKILL_CREATOR_PATH. Expected scripts/aggregate_benchmark.py and eval-viewer/generate_review.py."
}

function Resolve-PythonCommand {
    $python = Get-Command python -ErrorAction SilentlyContinue
    if ($null -ne $python) {
        return $python.Source
    }

    $pythonLauncher = Get-Command py -ErrorAction SilentlyContinue
    if ($null -ne $pythonLauncher) {
        return $pythonLauncher.Source
    }

    throw 'Python is required to run Anthropic skill-creator aggregation and the eval viewer.'
}

function Invoke-PythonScript {
    param(
        [string]$PythonCommand,
        [string]$ScriptPath,
        [string[]]$Arguments
    )

    $output = & $PythonCommand $ScriptPath @Arguments 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "Python script '$ScriptPath' failed with exit code ${LASTEXITCODE}:`n$($output -join [Environment]::NewLine)"
    }

    foreach ($line in @($output)) {
        Write-Host $line
    }
}

function Get-ResultPath {
    param(
        [string]$EvalDirectory,
        [string]$Configuration
    )

    $fileName = if ($Configuration -eq 'with_skill') { 'with-skill.result.json' } else { 'without-skill.result.json' }
    return Join-Path (Join-Path $EvalDirectory 'results') $fileName
}

function Copy-RecordedOutputFiles {
    param(
        [object]$Result,
        [string]$RunPackageDirectory,
        [string]$EvalDirectory,
        [string]$IterationPath,
        [string]$OutputDirectory
    )

    $index = 0
    foreach ($recordedPath in @(Get-Property -Object $Result -Name 'output_files' -Default @())) {
        if ([string]::IsNullOrWhiteSpace([string]$recordedPath)) {
            continue
        }

        $relativePath = [string]$recordedPath
        if ([System.IO.Path]::IsPathRooted($relativePath)) {
            continue
        }

        $source = $null
        foreach ($candidate in @(
                (Join-Path $RunPackageDirectory $relativePath),
                (Join-Path $EvalDirectory $relativePath),
                (Join-Path $IterationPath $relativePath))) {
            if (Test-Path -LiteralPath $candidate -PathType Leaf) {
                $source = (Resolve-Path -LiteralPath $candidate).Path
                break
            }
        }

        if ($null -eq $source) {
            continue
        }

        $leaf = [System.IO.Path]::GetFileName($relativePath)
        if ([string]::IsNullOrWhiteSpace($leaf)) {
            $leaf = "output-$index.bin"
        }

        $destination = Join-Path $OutputDirectory ("{0:D2}-{1}" -f $index, $leaf)
        Copy-Item -LiteralPath $source -Destination $destination -Force
        $index++
    }
}

function Write-UpstreamGrading {
    param(
        [object]$Result,
        [string]$RunDirectory
    )

    $grading = @(Get-Property -Object $Result -Name 'grading' -Default @())
    $graded = @($grading | Where-Object { $null -ne (Get-Property -Object $_ -Name 'passed') })
    if ($grading.Count -eq 0 -or $graded.Count -eq 0) {
        return
    }

    $expectations = foreach ($grade in $grading) {
        [ordered]@{
            text = [string](Get-Property -Object $grade -Name 'text' -Default 'Assertion')
            passed = Get-Property -Object $grade -Name 'passed' -Default $null
            evidence = [string](Get-Property -Object $grade -Name 'evidence' -Default 'No evidence recorded.')
        }
    }

    $passed = @($grading | Where-Object { $true -eq (Get-Property -Object $_ -Name 'passed') }).Count
    $failed = @($grading | Where-Object { $false -eq (Get-Property -Object $_ -Name 'passed') }).Count
    $total = $grading.Count
    $duration = Get-Property -Object $Result -Name 'duration_seconds' -Default $null
    $tokens = Get-Property -Object $Result -Name 'total_tokens' -Default $null
    $toolCalls = Get-Property -Object $Result -Name 'tool_calls' -Default $null

    $durationSeconds = if ($null -eq $duration) { 0.0 } else { [double]$duration }
    $totalTokens = if ($null -eq $tokens) { 0 } else { [int64]$tokens }
    Write-JsonFile -Path (Join-Path $RunDirectory 'timing.json') -Value ([ordered]@{
        total_tokens = $totalTokens
        duration_ms = [math]::Round($durationSeconds * 1000, 0)
        total_duration_seconds = $durationSeconds
    })

    $gradingDocument = [ordered]@{
        expectations = @($expectations)
        summary = [ordered]@{
            passed = $passed
            failed = $failed
            total = $total
            pass_rate = if ($total -eq 0) { $null } else { [math]::Round($passed / $total, 4) }
        }
        execution_metrics = [ordered]@{
            total_tool_calls = $toolCalls
            errors_encountered = if ([int](Get-Property -Object $Result -Name 'exit_status' -Default 0) -eq 0) { 0 } else { 1 }
        }
        # The upstream aggregator reads timing.json when grading.json does not claim a duration. Keep the
        # portable run's timing in that sibling file so both elapsed time and token usage survive aggregation.
        claims = @()
        user_notes_summary = [ordered]@{
            uncertainties = @()
            needs_review = @()
            workarounds = @()
        }
    }

    Write-JsonFile -Path (Join-Path $RunDirectory 'grading.json') -Value $gradingDocument
}

function New-UpstreamWorkspace {
    param(
        [object]$Manifest,
        [string]$IterationPath,
        [string]$WorkspacePath
    )

    New-Item -ItemType Directory -Path $WorkspacePath -Force | Out-Null
    $workspaceEntries = [System.Collections.Generic.List[object]]::new()

    foreach ($entry in @($Manifest.evals)) {
        $evalDirectory = Join-Path $IterationPath ([string]$entry.directory)
        $metadata = Read-JsonFile -Path (Join-Path $evalDirectory 'eval-metadata.json')
        $evalFolder = Join-Path $WorkspacePath ("eval-{0}-{1}" -f $entry.eval_id, (Get-SafeSegment -Value ([string]$entry.eval_name)))
        New-Item -ItemType Directory -Path $evalFolder -Force | Out-Null

        $upstreamMetadata = [ordered]@{
            eval_id = [int]$metadata.eval_id
            eval_name = [string]$metadata.eval_name
            prompt = [string]$metadata.prompt
            expected_output = [string](Get-Property -Object $metadata -Name 'expected_output' -Default '')
            expectations = @($metadata.assertions)
        }
        Write-JsonFile -Path (Join-Path $evalFolder 'eval_metadata.json') -Value $upstreamMetadata
        $workspaceEntries.Add([pscustomobject]@{ EvalId = [int]$entry.eval_id; EvalName = [string]$entry.eval_name })

        foreach ($configuration in @('with_skill', 'without_skill')) {
            $configurationDirectory = Join-Path $evalFolder $configuration
            $runDirectory = Join-Path $configurationDirectory 'run-1'
            $outputsDirectory = Join-Path $runDirectory 'outputs'
            New-Item -ItemType Directory -Path $outputsDirectory -Force | Out-Null
            Write-JsonFile -Path (Join-Path $configurationDirectory 'eval_metadata.json') -Value $upstreamMetadata

            $resultPath = Get-ResultPath -EvalDirectory $evalDirectory -Configuration $configuration
            if (-not (Test-Path -LiteralPath $resultPath)) {
                continue
            }

            $result = Read-JsonFile -Path $resultPath
            $output = [string](Get-Property -Object $result -Name 'output' -Default '')
            if (-not [string]::IsNullOrWhiteSpace($output)) {
                Write-TextFile -Path (Join-Path $outputsDirectory 'response.txt') -Content $output
            }

            $transcript = [string](Get-Property -Object $result -Name 'transcript' -Default '')
            if (-not [string]::IsNullOrWhiteSpace($transcript)) {
                Write-TextFile -Path (Join-Path $outputsDirectory 'transcript.md') -Content $transcript
            }

            $isolation = Get-Property -Object $result -Name 'isolation' -Default $null
            if ($null -ne $isolation) {
                Write-JsonFile -Path (Join-Path $outputsDirectory 'isolation.json') -Value $isolation
            }

            Copy-RecordedOutputFiles -Result $result -RunPackageDirectory (Join-Path $evalDirectory $configuration) -EvalDirectory $evalDirectory -IterationPath $IterationPath -OutputDirectory $outputsDirectory
            Write-UpstreamGrading -Result $result -RunDirectory $runDirectory
        }
    }

    return @($workspaceEntries)
}

$iterationPath = (Resolve-Path -LiteralPath $IterationDirectory).Path
$manifest = Read-JsonFile -Path (Join-Path $iterationPath 'manifest.json')
$skillCreatorPathResolved = Resolve-SkillCreatorPath -RequestedPath $SkillCreatorPath
$pythonCommand = Resolve-PythonCommand
$workspacePath = Join-Path $iterationPath '.skill-creator-report'
$workspaceEntries = New-UpstreamWorkspace -Manifest $manifest -IterationPath $iterationPath -WorkspacePath $workspacePath

$aggregatePath = Join-Path $skillCreatorPathResolved 'scripts/aggregate_benchmark.py'
$viewerPath = Join-Path $skillCreatorPathResolved 'eval-viewer/generate_review.py'
$viewerTemplatePath = Join-Path $skillCreatorPathResolved 'eval-viewer/viewer.html'
$aggregateArguments = @($workspacePath, '--skill-name', [string]$manifest.skill_name)
Invoke-PythonScript -PythonCommand $pythonCommand -ScriptPath $aggregatePath -Arguments $aggregateArguments

$benchmarkWorkspacePath = Join-Path $workspacePath 'benchmark.json'
$benchmark = Read-JsonFile -Path $benchmarkWorkspacePath
$models = [System.Collections.Generic.List[string]]::new()
foreach ($entry in @($manifest.evals)) {
    foreach ($configuration in @('with_skill', 'without_skill')) {
        $resultPath = Get-ResultPath -EvalDirectory (Join-Path $iterationPath ([string]$entry.directory)) -Configuration $configuration
        if (Test-Path -LiteralPath $resultPath) {
            $model = [string](Get-Property -Object (Read-JsonFile -Path $resultPath) -Name 'model' -Default '')
            if (-not [string]::IsNullOrWhiteSpace($model) -and -not $models.Contains($model)) {
                $models.Add($model)
            }
        }
    }
}

$benchmark.metadata.runs_per_configuration = 1
$benchmark.metadata.executor_model = if ($models.Count -eq 0) { 'model not recorded' } else { $models -join ', ' }
$benchmark.metadata.analyzer_model = 'external skill-creator evaluator'
$benchmark.metadata.evals_run = @($workspaceEntries | ForEach-Object { $_.EvalId })
foreach ($run in @($benchmark.runs)) {
    $match = @($workspaceEntries | Where-Object { $_.EvalId -eq [int]$run.eval_id }) | Select-Object -First 1
    if ($null -ne $match) {
        $run | Add-Member -NotePropertyName eval_name -NotePropertyValue $match.EvalName -Force
    }
}

$benchmarkOutputPath = if ([string]::IsNullOrWhiteSpace($BenchmarkPath)) { Join-Path $iterationPath 'benchmark.json' } else { $BenchmarkPath }
$benchmarkMarkdownOutputPath = if ([string]::IsNullOrWhiteSpace($BenchmarkMarkdownPath)) { Join-Path $iterationPath 'benchmark.md' } else { $BenchmarkMarkdownPath }
Write-JsonFile -Path $benchmarkOutputPath -Value $benchmark

$benchmarkMarkdown = [System.IO.File]::ReadAllText((Join-Path $workspacePath 'benchmark.md'), $utf8NoBom)
$benchmarkMarkdown = $benchmarkMarkdown.Replace('3 runs each per configuration', '1 run each per configuration')
$benchmarkMarkdown = $benchmarkMarkdown.Replace('<model-name>', [string]$benchmark.metadata.executor_model)
Write-TextFile -Path $benchmarkMarkdownOutputPath -Content $benchmarkMarkdown

$htmlOutputPath = if ([string]::IsNullOrWhiteSpace($OutputPath)) { Join-Path $iterationPath 'report.html' } else { $OutputPath }
$viewerArguments = @(
    $workspacePath,
    '--skill-name', [string]$manifest.skill_name,
    '--benchmark', $benchmarkOutputPath,
    '--static', $htmlOutputPath
)
Invoke-PythonScript -PythonCommand $pythonCommand -ScriptPath $viewerPath -Arguments $viewerArguments

Write-Host "Anthropic skill-creator tools: $skillCreatorPathResolved"
Write-Host "Anthropic viewer template: $viewerTemplatePath"
Write-Host "Wrote $benchmarkOutputPath"
Write-Host "Wrote $benchmarkMarkdownOutputPath"
Write-Host "Wrote $htmlOutputPath"
