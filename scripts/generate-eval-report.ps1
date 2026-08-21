<#
.SYNOPSIS
    Adapts this repository's portable eval results to Anthropic skill-creator's benchmark and viewer tools.

.DESCRIPTION
    This adapter mirrors the recorded portable results into skill-creator's eval workspace contract and invokes the
    upstream aggregator and viewer. It also writes a first-party side-by-side report.html with paired outputs,
    assertion evidence, optional run telemetry, transcripts, and human feedback. The exact upstream viewer is kept
    beside it as skill-creator-report.html for compatibility and comparison.

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

    if ($null -ne $Object -and $Object -is [System.Collections.IDictionary] -and $Object.Contains($Name) -and $null -ne $Object[$Name]) {
        return $Object[$Name]
    }

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

function Get-ReportMimeType {
    param([string]$Extension)

    switch ($Extension.ToLowerInvariant()) {
        '.png' { return 'image/png' }
        '.jpg' { return 'image/jpeg' }
        '.jpeg' { return 'image/jpeg' }
        '.gif' { return 'image/gif' }
        '.svg' { return 'image/svg+xml' }
        '.webp' { return 'image/webp' }
        default { return 'application/octet-stream' }
    }
}

function Get-ReportOutputFiles {
    param(
        [object]$Result,
        [string]$RunPackageDirectory,
        [string]$EvalDirectory,
        [string]$IterationPath
    )

    $textExtensions = @('.txt', '.md', '.json', '.csv', '.py', '.js', '.ts', '.tsx', '.jsx', '.yaml', '.yml', '.xml', '.html', '.css', '.sh', '.rb', '.go', '.rs', '.java', '.c', '.cpp', '.h', '.hpp', '.sql', '.r', '.toml')
    $imageExtensions = @('.png', '.jpg', '.jpeg', '.gif', '.svg', '.webp')
    $files = [System.Collections.Generic.List[object]]::new()
    $index = 0

    foreach ($recordedPath in @(Get-Property -Object $Result -Name 'output_files' -Default @())) {
        $relativePath = [string]$recordedPath
        if ([string]::IsNullOrWhiteSpace($relativePath) -or [System.IO.Path]::IsPathRooted($relativePath)) {
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

        $extension = [System.IO.Path]::GetExtension($source).ToLowerInvariant()
        $leaf = [System.IO.Path]::GetFileName($source)
        if ([string]::IsNullOrWhiteSpace($leaf)) {
            $leaf = "output-$index.bin"
        }

        if ($textExtensions -contains $extension) {
            $files.Add([ordered]@{
                name = $leaf
                type = 'text'
                content = [System.IO.File]::ReadAllText($source, $utf8NoBom)
            })
        } elseif ($imageExtensions -contains $extension) {
            $bytes = [System.IO.File]::ReadAllBytes($source)
            $files.Add([ordered]@{
                name = $leaf
                type = 'image'
                data_uri = "data:$(Get-ReportMimeType -Extension $extension);base64,$([Convert]::ToBase64String($bytes))"
            })
        } else {
            $bytes = [System.IO.File]::ReadAllBytes($source)
            $files.Add([ordered]@{
                name = $leaf
                type = 'binary'
                data_uri = "data:application/octet-stream;base64,$([Convert]::ToBase64String($bytes))"
            })
        }
        $index++
    }

    return @($files)
}

function Get-ReportGrades {
    param(
        [object]$Result,
        [string[]]$Assertions
    )

    $grading = @(Get-Property -Object $Result -Name 'grading' -Default @())
    $count = [Math]::Max($grading.Count, $Assertions.Count)
    $grades = [System.Collections.Generic.List[object]]::new()
    for ($index = 0; $index -lt $count; $index++) {
        $grade = if ($index -lt $grading.Count) { $grading[$index] } else { $null }
        $text = [string](Get-Property -Object $grade -Name 'text' -Default '')
        $generic = [string]::IsNullOrWhiteSpace($text) -or $text -match '^(Passed|Failed|Assertion\s+\d+)$'
        if ($generic -and $index -lt $Assertions.Count) {
            $text = [string]$Assertions[$index]
        }
        if ([string]::IsNullOrWhiteSpace($text)) {
            $text = 'Assertion'
        }

        $passed = Get-Property -Object $grade -Name 'passed' -Default $null
        $evidence = [string](Get-Property -Object $grade -Name 'evidence' -Default '')
        if ($null -eq $grade) {
            $evidence = 'Not graded.'
        }
        $grades.Add([ordered]@{
            text = $text
            passed = $passed
            evidence = $evidence
        })
    }

    return @($grades)
}

function Get-ReportMetric {
    param(
        [object]$Result,
        [string[]]$Names
    )

    foreach ($name in $Names) {
        $value = Get-Property -Object $Result -Name $name -Default $null
        if ($null -ne $value -and -not [string]::IsNullOrWhiteSpace([string]$value)) {
            return $value
        }
    }

    return $null
}

function Get-ReportRun {
    param(
        [object]$Result,
        [string]$Configuration,
        [string]$EvalName,
        [int]$EvalId,
        [string[]]$Assertions,
        [string]$RunPackageDirectory,
        [string]$EvalDirectory,
        [string]$IterationPath
    )

    if ($null -eq $Result) {
        return $null
    }

    $output = [string](Get-Property -Object $Result -Name 'output' -Default '')
    $outputFiles = @(Get-ReportOutputFiles -Result $Result -RunPackageDirectory $RunPackageDirectory -EvalDirectory $EvalDirectory -IterationPath $IterationPath)
    $grades = @(Get-ReportGrades -Result $Result -Assertions $Assertions)
    $metrics = [ordered]@{
        turns = Get-ReportMetric -Result $Result -Names @('turns', 'turn_count', 'total_turns')
        duration_seconds = Get-ReportMetric -Result $Result -Names @('duration_seconds')
        base_input_tokens = Get-ReportMetric -Result $Result -Names @('base_input_tokens', 'input_tokens')
        output_tokens = Get-ReportMetric -Result $Result -Names @('output_tokens', 'total_output_tokens')
        cache_read_tokens = Get-ReportMetric -Result $Result -Names @('cache_read_tokens')
        cache_write_tokens = Get-ReportMetric -Result $Result -Names @('cache_write_tokens')
        cache_write_1h_tokens = Get-ReportMetric -Result $Result -Names @('cache_write_1h_tokens')
        estimated_cost_usd = Get-ReportMetric -Result $Result -Names @('estimated_cost_usd', 'cost_usd')
        total_tokens = Get-ReportMetric -Result $Result -Names @('total_tokens')
        tool_calls = Get-ReportMetric -Result $Result -Names @('tool_calls')
    }

    return [ordered]@{
        configuration = $Configuration
        feedback_key = "eval-$EvalId-$Configuration"
        model = [string](Get-Property -Object $Result -Name 'model' -Default '')
        provider = [string](Get-Property -Object $Result -Name 'provider' -Default '')
        requested_model = [string](Get-Property -Object $Result -Name 'requested_model' -Default '')
        requested_provider = [string](Get-Property -Object $Result -Name 'requested_provider' -Default '')
        resolved_model = [string](Get-Property -Object $Result -Name 'resolved_model' -Default '')
        resolved_provider = [string](Get-Property -Object $Result -Name 'resolved_provider' -Default '')
        configuration_resolution_status = [string](Get-Property -Object $Result -Name 'configuration_resolution_status' -Default '')
        configuration_resolution_reason = [string](Get-Property -Object $Result -Name 'configuration_resolution_reason' -Default '')
        harness = [string](Get-Property -Object $Result -Name 'harness' -Default '')
        executed_utc = [string](Get-Property -Object $Result -Name 'executed_utc' -Default '')
        output = $output
        output_files = @($outputFiles)
        transcript = [string](Get-Property -Object $Result -Name 'transcript' -Default '')
        shell_commands = @(Get-Property -Object $Result -Name 'shell_commands' -Default @())
        files_read = @(Get-Property -Object $Result -Name 'files_read' -Default @())
        files_written = @(Get-Property -Object $Result -Name 'files_written' -Default @())
        stdout = [string](Get-Property -Object $Result -Name 'stdout' -Default '')
        stderr = [string](Get-Property -Object $Result -Name 'stderr' -Default '')
        exit_status = Get-Property -Object $Result -Name 'exit_status' -Default $null
        execution_status = Get-Property -Object $Result -Name 'execution_status' -Default $null
        execution_run_id = Get-Property -Object $Result -Name 'execution_run_id' -Default $null
        execution_result_file = Get-Property -Object $Result -Name 'execution_result_file' -Default $null
        metrics = $metrics
        isolation = Get-Property -Object $Result -Name 'isolation' -Default $null
        grades = @($grades)
        notes = Get-Property -Object $Result -Name 'notes' -Default ''
    }
}

function Get-ReportSkillStats {
    param(
        [object]$Manifest,
        [string]$IterationPath
    )

    $skillRoot = $null
    foreach ($entry in @($Manifest.evals)) {
        $candidate = Join-Path (Join-Path (Join-Path $IterationPath ([string]$entry.directory)) 'with_skill') ("skill/$($Manifest.skill_name)")
        if (Test-Path -LiteralPath $candidate -PathType Container) {
            $skillRoot = $candidate
            break
        }
    }

    $files = if ($null -ne $skillRoot) { @(Get-ChildItem -LiteralPath $skillRoot -Recurse -File -Force) } else { @() }
    $totalBytes = if ($files.Count -gt 0) { [int64](($files | Measure-Object -Property Length -Sum).Sum) } else { 0 }
    $inlinedBytes = Get-Property -Object $Manifest.skill_instructions -Name 'inlined_resource_bytes' -Default $null
    return [ordered]@{
        file_count = $files.Count
        total_bytes = $totalBytes
        inlined_bytes = $inlinedBytes
        token_count = Get-Property -Object $Manifest -Name 'skill_token_count' -Default $null
        hash = [string](Get-Property -Object $Manifest -Name 'skill_hash' -Default '')
    }
}

function Write-FirstPartyReport {
    param(
        [object]$Manifest,
        [string]$IterationPath,
        [string]$OutputPath,
        [object]$Benchmark
    )

    $evals = [System.Collections.Generic.List[object]]::new()
    $allModels = [System.Collections.Generic.List[string]]::new()
    $allProviders = [System.Collections.Generic.List[string]]::new()
    $completedRuns = 0
    foreach ($entry in @($Manifest.evals)) {
        $evalDirectory = Join-Path $IterationPath ([string]$entry.directory)
        $metadata = Read-JsonFile -Path (Join-Path $evalDirectory 'eval-metadata.json')
        $runMap = [ordered]@{}
        $assertions = @($metadata.assertions | ForEach-Object { [string]$_ })
        foreach ($configuration in @('with_skill', 'without_skill')) {
            $resultPath = Get-ResultPath -EvalDirectory $evalDirectory -Configuration $configuration
            $result = if (Test-Path -LiteralPath $resultPath) { Read-JsonFile -Path $resultPath } else { $null }
            if ($null -ne $result) {
                $run = Get-ReportRun -Result $result -Configuration $configuration -EvalName ([string]$entry.eval_name) -EvalId ([int]$metadata.eval_id) -Assertions $assertions -RunPackageDirectory (Join-Path $evalDirectory $configuration) -EvalDirectory $evalDirectory -IterationPath $IterationPath
                $runMap[$configuration] = $run
                $executionStatus = [string](Get-Property -Object $result -Name 'execution_status' -Default '')
                if (-not [string]::IsNullOrWhiteSpace([string]$run.output) -or @($run.output_files).Count -gt 0 -or ($executionStatus -and $executionStatus -ne 'unrun')) { $completedRuns++ }
                if (-not [string]::IsNullOrWhiteSpace([string]$run.model) -and -not $allModels.Contains([string]$run.model)) {
                    $allModels.Add([string]$run.model)
                }
                if (-not [string]::IsNullOrWhiteSpace([string]$run.provider) -and -not $allProviders.Contains([string]$run.provider)) {
                    $allProviders.Add([string]$run.provider)
                }
            } else {
                $runMap[$configuration] = $null
            }
        }
        $evals.Add([ordered]@{
            id = [int]$metadata.eval_id
            name = [string]$metadata.eval_name
            prompt = [string]$metadata.prompt
            expected_output = [string](Get-Property -Object $metadata -Name 'expected_output' -Default '')
            assertions = @($assertions)
            runs = $runMap
        })
    }

    $metadata = [ordered]@{
        model = if ($allModels.Count -gt 0) { $allModels -join ', ' } else { $null }
        provider = if ($allProviders.Count -gt 0) { $allProviders -join ', ' } else { $null }
        completed_runs = $completedRuns
        expected_runs = @($Manifest.evals).Count * 2
        generated_utc = [string](Get-Property -Object $Manifest -Name 'generated_utc' -Default '')
    }
    $reportData = [ordered]@{
        skill_name = [string]$Manifest.skill_name
        iteration = [int]$Manifest.iteration
        metadata = $metadata
        skill = Get-ReportSkillStats -Manifest $Manifest -IterationPath $IterationPath
        evals = @($evals)
        benchmark = $Benchmark
    }

    $templatePath = Join-Path (Split-Path -Parent $PSCommandPath) 'eval-report-template.html'
    if (-not (Test-Path -LiteralPath $templatePath)) {
        throw "Missing first-party eval report template '$templatePath'."
    }
    $template = [System.IO.File]::ReadAllText($templatePath, $utf8NoBom)
    $dataJson = ($reportData | ConvertTo-Json -Depth 100 -Compress)
    $dataJson = $dataJson -replace '(?i)</script', '<\\/script'
    $html = $template.Replace('__EVAL_DATA__', $dataJson)
    Write-TextFile -Path $OutputPath -Content $html
}

function Write-UpstreamGrading {
    param(
        [object]$Result,
        [string]$RunDirectory,
        [string[]]$Assertions
    )

    $grading = @(Get-ReportGrades -Result $Result -Assertions $Assertions)
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
    $exitStatus = Get-Property -Object $Result -Name 'exit_status' -Default $null
    $errorsEncountered = if ($null -eq $exitStatus -or [string]::IsNullOrWhiteSpace([string]$exitStatus)) { $null } elseif ([int]$exitStatus -eq 0) { 0 } else { 1 }

    $timing = [ordered]@{}
    if ($null -ne $duration -and -not [string]::IsNullOrWhiteSpace([string]$duration)) {
        $durationSeconds = [double]$duration
        $timing.duration_ms = [math]::Round($durationSeconds * 1000, 0)
        $timing.total_duration_seconds = $durationSeconds
    }
    if ($null -ne $tokens -and -not [string]::IsNullOrWhiteSpace([string]$tokens)) {
        $timing.total_tokens = [int64]$tokens
    }
    Write-JsonFile -Path (Join-Path $RunDirectory 'timing.json') -Value $timing

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
            errors_encountered = $errorsEncountered
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
            Write-UpstreamGrading -Result $result -RunDirectory $runDirectory -Assertions @($metadata.assertions | ForEach-Object { [string]$_ })
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
$upstreamHtmlOutputPath = Join-Path $iterationPath 'skill-creator-report.html'
$viewerArguments = @(
    $workspacePath,
    '--skill-name', [string]$manifest.skill_name,
    '--benchmark', $benchmarkOutputPath,
    '--static', $upstreamHtmlOutputPath
)
Invoke-PythonScript -PythonCommand $pythonCommand -ScriptPath $viewerPath -Arguments $viewerArguments

Write-FirstPartyReport -Manifest $manifest -IterationPath $iterationPath -OutputPath $htmlOutputPath -Benchmark $benchmark

Write-Host "Anthropic skill-creator tools: $skillCreatorPathResolved"
Write-Host "Anthropic viewer template: $viewerTemplatePath"
Write-Host "Wrote $benchmarkOutputPath"
Write-Host "Wrote $benchmarkMarkdownOutputPath"
Write-Host "Wrote $upstreamHtmlOutputPath"
Write-Host "Wrote $htmlOutputPath"
