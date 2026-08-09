param(
    [Parameter(Mandatory = $true)]
    [string]$SkillPath,

    [string]$WorkspaceRoot,

    [string]$BaselineSkillPath,

    [int]$MaxParallel = 4,

    [int]$MaxGradeParallel = 4,

    [ValidateRange(30, 3600)]
    [int]$RunTimeoutSeconds = 240,

    [ValidateRange(30, 1800)]
    [int]$GradeTimeoutSeconds = 120,

    [string]$Model = 'gpt-5.4',

    [string]$GraderModel,

    [int]$BenchmarkCandidateLimit = 5,

    [string]$ExecutorCommand,

    [string]$GraderCommand,

    [string[]]$EvalId,

    [switch]$CompareWithLegacy,

    [switch]$SkipSkillValidation,

    [switch]$SkipReview
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$utf8NoBom = [System.Text.UTF8Encoding]::new($false)
[Console]::InputEncoding = $utf8NoBom
[Console]::OutputEncoding = $utf8NoBom
$OutputEncoding = $utf8NoBom

function Write-JsonFile {
    param(
        [Parameter(Mandatory = $true)] [string]$Path,
        [Parameter(Mandatory = $true)] $Value
    )

    $directory = Split-Path -Path $Path -Parent
    if (-not [string]::IsNullOrWhiteSpace($directory)) {
        New-Item -ItemType Directory -Path $directory -Force | Out-Null
    }
    $Value | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $Path -Encoding utf8
}

function Write-TextFile {
    param(
        [Parameter(Mandatory = $true)] [string]$Path,
        [AllowEmptyString()] [string]$Content
    )

    $directory = Split-Path -Path $Path -Parent
    if (-not [string]::IsNullOrWhiteSpace($directory)) {
        New-Item -ItemType Directory -Path $directory -Force | Out-Null
    }
    [System.IO.File]::WriteAllText($Path, $Content, $utf8NoBom)
}

function Get-RepoRoot {
    return (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
}

function Get-ResolvedPath {
    param([Parameter(Mandatory = $true)] [string]$Path)
    return $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath((Resolve-Path -LiteralPath $Path).Path)
}

function Get-SkillMetadata {
    param([Parameter(Mandatory = $true)] [string]$ResolvedSkillPath)

    $skillMdPath = Join-Path $ResolvedSkillPath 'SKILL.md'
    if (-not (Test-Path -LiteralPath $skillMdPath -PathType Leaf)) {
        throw "Missing SKILL.md at '$skillMdPath'."
    }

    $content = [System.IO.File]::ReadAllText($skillMdPath, $utf8NoBom)
    $match = [regex]::Match($content, '^\s*name:\s*(?<name>[a-z0-9-]+)\s*$', [System.Text.RegularExpressions.RegexOptions]::Multiline)
    if (-not $match.Success) {
        throw "Unable to resolve skill name from '$skillMdPath'."
    }

    return [pscustomobject]@{
        Name = $match.Groups['name'].Value
        SkillMdPath = $skillMdPath
        Content = $content
    }
}

function Get-EvalDefinitions {
    param(
        [Parameter(Mandatory = $true)] [string]$ResolvedSkillPath,
        [string[]]$SelectedEvalId
    )

    $evalPath = Join-Path $ResolvedSkillPath 'evals\evals.json'
    if (-not (Test-Path -LiteralPath $evalPath -PathType Leaf)) {
        throw "Missing eval file '$evalPath'."
    }

    $evals = Get-Content -LiteralPath $evalPath -Raw | ConvertFrom-Json
    $items = @($evals.evals)
    if ($SelectedEvalId -and $SelectedEvalId.Count -gt 0) {
        $selected = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
        foreach ($id in $SelectedEvalId) { [void]$selected.Add([string]$id) }
        $items = @($items | Where-Object { $selected.Contains([string]$_.id) })
    }

    return @($items | Sort-Object id)
}

function Get-Slug {
    param([Parameter(Mandatory = $true)] [string]$Text)

    $slug = ($Text.ToLowerInvariant() -replace '[^a-z0-9]+', '-') -replace '(^-+|-+$)', ''
    if ([string]::IsNullOrWhiteSpace($slug)) { return 'eval' }
    return $slug
}

function Resolve-SkillCreatorRoot {
    $candidates = @(
        (Join-Path $HOME '.agents\skills\skill-creator'),
        (Join-Path $HOME '.claude\skills\skill-creator')
    ) | Where-Object { Test-Path -LiteralPath $_ -PathType Container }
    if (@($candidates).Count -eq 0) {
        throw "Install Anthropic's skill-creator before running the benchmark viewer."
    }
    return (Resolve-Path -LiteralPath $candidates[0]).Path
}

function Get-RealDotnetPath {
    $command = Get-Command dotnet -CommandType Application | Select-Object -First 1
    if ($null -eq $command) {
        throw 'dotnet was not found on PATH.'
    }
    return $command.Source
}

function Get-CopilotScriptPath {
    $command = Get-Command copilot -ErrorAction Stop
    return $command.Source
}

function Initialize-DotnetShim {
    param(
        [Parameter(Mandatory = $true)] [string]$Workspace,
        [Parameter(Mandatory = $true)] [string]$RealDotnet
    )

    $shimRoot = Join-Path (Join-Path $Workspace '.benchmark') 'dotnet'
    New-Item -ItemType Directory -Path $shimRoot -Force | Out-Null

    $shimCommandPath = Join-Path $shimRoot 'dotnet.cmd'
    $shimScriptPath = Join-Path (Join-Path $PSScriptRoot 'skill-benchmark') 'log-dotnet.ps1'
    $shimContent = @"
@echo off
pwsh -NoProfile -File "$shimScriptPath" -RealDotnet "%SKILL_BENCHMARK_DOTNET_REAL%" -LogDirectory "%SKILL_BENCHMARK_DOTNET_LOG_DIR%" -StdoutPath "%SKILL_BENCHMARK_DOTNET_STDOUT%" -StderrPath "%SKILL_BENCHMARK_DOTNET_STDERR%" %*
exit /b %ERRORLEVEL%
"@
    Write-TextFile -Path $shimCommandPath -Content $shimContent

    $unixShimPath = Join-Path $shimRoot 'dotnet'
    $posixShimScriptPath = "'" + $shimScriptPath.Replace("'", "'\''", [System.StringComparison]::Ordinal) + "'"
    $unixShimContent = @'
#!/usr/bin/env sh
exec pwsh -NoProfile -File __SHIM_SCRIPT_PATH__ -RealDotnet "$SKILL_BENCHMARK_DOTNET_REAL" -LogDirectory "$SKILL_BENCHMARK_DOTNET_LOG_DIR" -StdoutPath "$SKILL_BENCHMARK_DOTNET_STDOUT" -StderrPath "$SKILL_BENCHMARK_DOTNET_STDERR" "$@"
'@.Replace('__SHIM_SCRIPT_PATH__', $posixShimScriptPath).Replace("`r`n", "`n")
    Write-TextFile -Path $unixShimPath -Content $unixShimContent

    if (-not [System.OperatingSystem]::IsWindows()) {
        & chmod +x -- $unixShimPath
        if ($LASTEXITCODE -ne 0) {
            throw "Unable to mark the Unix dotnet shim executable: $unixShimPath"
        }
    }

    return $shimRoot
}

function New-RunManifest {
    param(
        [Parameter(Mandatory = $true)] [string]$RepoRoot,
        [Parameter(Mandatory = $true)] [string[]]$ExcludedPrefixes
    )

    $manifest = @{}
    $files = Get-ChildItem -LiteralPath $RepoRoot -Recurse -File -Force | Where-Object {
        $relative = [System.IO.Path]::GetRelativePath($RepoRoot, $_.FullName).Replace('\', '/')
        foreach ($prefix in $ExcludedPrefixes) {
            if ($relative.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)) { return $false }
        }
        return $true
    }

    foreach ($file in $files) {
        $relative = [System.IO.Path]::GetRelativePath($RepoRoot, $file.FullName).Replace('\', '/')
        $manifest[$relative] = [pscustomobject]@{
            path = $file.FullName
            hash = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash
        }
    }
    return $manifest
}

function Get-ChangedFiles {
    param(
        [Parameter(Mandatory = $true)] [string]$BaselineRoot,
        [Parameter(Mandatory = $true)] [string]$CurrentRoot,
        [Parameter(Mandatory = $true)] [hashtable]$BaselineManifest,
        [Parameter(Mandatory = $true)] [string[]]$ExcludedPrefixes
    )

    $currentManifest = New-RunManifest -RepoRoot $CurrentRoot -ExcludedPrefixes $ExcludedPrefixes
    $changes = [System.Collections.Generic.List[object]]::new()

    foreach ($relative in ($BaselineManifest.Keys + $currentManifest.Keys | Sort-Object -Unique)) {
        $before = if ($BaselineManifest.ContainsKey($relative)) { $BaselineManifest[$relative] } else { $null }
        $after = if ($currentManifest.ContainsKey($relative)) { $currentManifest[$relative] } else { $null }
        if ($null -eq $before) {
            $changes.Add([pscustomobject]@{ path = $relative; change = 'added'; before = $null; after = $after.path })
            continue
        }
        if ($null -eq $after) {
            $changes.Add([pscustomobject]@{ path = $relative; change = 'deleted'; before = $before.path; after = $null })
            continue
        }
        if ($before.hash -ne $after.hash) {
            $changes.Add([pscustomobject]@{ path = $relative; change = 'modified'; before = $before.path; after = $after.path })
        }
    }

    return @($changes | Sort-Object path)
}

function Invoke-GitNoPager {
    param(
        [Parameter(Mandatory = $true)] [string[]]$Arguments
    )

    $output = & git --no-pager @Arguments 2>&1
    return [pscustomobject]@{
        ExitCode = $LASTEXITCODE
        Output = @($output)
    }
}

function Write-ChangeArtifacts {
    param(
        [AllowEmptyCollection()] [object[]]$Changes,
        [Parameter(Mandatory = $true)] [string]$OutputsPath
    )

    $summaryLines = [System.Collections.Generic.List[string]]::new()
    $summaryLines.Add('# Changed Files')
    $summaryLines.Add('')
    if (@($Changes).Count -eq 0) {
        $summaryLines.Add('No source changes were detected.')
    } else {
        foreach ($change in @($Changes)) {
            $summaryLines.Add("- $($change.change): $($change.path)")
        }
    }
    Write-TextFile -Path (Join-Path $OutputsPath 'changed-files.md') -Content ($summaryLines -join [Environment]::NewLine)

    $diffParts = [System.Collections.Generic.List[string]]::new()
    foreach ($change in @($Changes)) {
        switch ($change.change) {
            'modified' {
                $diff = Invoke-GitNoPager -Arguments @('diff', '--no-index', '--', $change.before, $change.after)
                $diffParts.Add(($diff.Output -join [Environment]::NewLine))
            }
            'added' {
                $addedContent = Get-Content -LiteralPath $change.after -Raw
                $addedText = @('+++ ' + $change.path, $addedContent) -join [Environment]::NewLine
                $diffParts.Add($addedText)
            }
            'deleted' {
                $deletedContent = Get-Content -LiteralPath $change.before -Raw
                $deletedText = @('--- ' + $change.path, $deletedContent) -join [Environment]::NewLine
                $diffParts.Add($deletedText)
            }
        }
    }
    Write-TextFile -Path (Join-Path $OutputsPath 'repo.diff') -Content (($diffParts -join [Environment]::NewLine + [Environment]::NewLine).Trim())

    $snapshotsRoot = Join-Path $OutputsPath 'snapshots'
    if (@($Changes).Count -gt 0) {
        New-Item -ItemType Directory -Path $snapshotsRoot -Force | Out-Null
        foreach ($change in @($Changes)) {
            if ($null -eq $change.after) { continue }
            $destination = Join-Path $snapshotsRoot ($change.path -replace '/', '\')
            $destinationDir = Split-Path -Path $destination -Parent
            New-Item -ItemType Directory -Path $destinationDir -Force | Out-Null
            Copy-Item -LiteralPath $change.after -Destination $destination -Force
        }
    }
}

function Parse-CopilotEvents {
    param([Parameter(Mandatory = $true)] [string]$JsonlPath)

    if (-not (Test-Path -LiteralPath $JsonlPath -PathType Leaf)) { return @() }

    $events = [System.Collections.Generic.List[object]]::new()
    foreach ($line in Get-Content -LiteralPath $JsonlPath) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        try {
            [void]$events.Add(($line | ConvertFrom-Json))
        } catch {
        }
    }
    return @($events)
}

function Get-PowerShellCommandDurations {
    param(
        [AllowEmptyCollection()] [object[]]$Events
    )

    $started = @{}
    $summary = [ordered]@{
        restoreSeconds = 0.0
        buildSeconds = 0.0
        testSeconds = 0.0
        resolverSeconds = 0.0
    }

    foreach ($event in @($Events)) {
        if ($event.type -eq 'tool.execution_start' -and [string]$event.data.toolName -eq 'powershell') {
            $started[[string]$event.data.toolCallId] = $event
            continue
        }
        if ($event.type -ne 'tool.execution_complete') {
            continue
        }

        $toolCallId = [string]$event.data.toolCallId
        if (-not $started.ContainsKey($toolCallId)) { continue }

        $startEvent = $started[$toolCallId]
        if ([string]$startEvent.data.toolName -ne 'powershell') { continue }
        $durationSeconds = [math]::Round(([DateTimeOffset]::Parse([string]$event.timestamp) - [DateTimeOffset]::Parse([string]$startEvent.timestamp)).TotalSeconds, 3)
        $command = [string]$startEvent.data.arguments.command

        if ($command -match '(^|[;\s])dotnet\s+restore(\s|$)') {
            $summary.restoreSeconds += $durationSeconds
        }
        if ($command -match '(^|[;\s])dotnet\s+build(\s|$)') {
            $summary.buildSeconds += $durationSeconds
        }
        if ($command -match '(^|[;\s])dotnet\s+test(\s|$)') {
            $summary.testSeconds += $durationSeconds
        }
        if ($command -match 'resolve-test-package-versions\.ps1') {
            $summary.resolverSeconds += $durationSeconds
        }
    }

    return [ordered]@{
        restoreSeconds = [math]::Round([double]$summary.restoreSeconds, 3)
        buildSeconds = [math]::Round([double]$summary.buildSeconds, 3)
        testSeconds = [math]::Round([double]$summary.testSeconds, 3)
        resolverSeconds = [math]::Round([double]$summary.resolverSeconds, 3)
    }
}

function Get-CopilotMetrics {
    param(
        [AllowEmptyCollection()] [object[]]$Events,
        [Parameter(Mandatory = $true)] [string]$TranscriptPath,
        [Parameter(Mandatory = $true)] [string]$OutputsPath
    )

    $toolCalls = @{}
    $errors = 0
    foreach ($event in @($Events)) {
        if ($event.type -eq 'tool.execution_start') {
            $toolName = [string]$event.data.toolName
            if (-not $toolCalls.ContainsKey($toolName)) { $toolCalls[$toolName] = 0 }
            $toolCalls[$toolName]++
        }
        if ($event.type -eq 'tool.execution_complete' -and -not [bool]$event.data.success) {
            $errors++
        }
    }

    $transcriptChars = if (Test-Path -LiteralPath $TranscriptPath) { (Get-Content -LiteralPath $TranscriptPath -Raw).Length } else { 0 }
    $outputChars = 0
    if (Test-Path -LiteralPath $OutputsPath -PathType Container) {
        foreach ($file in Get-ChildItem -LiteralPath $OutputsPath -Recurse -File -Force) {
            $outputChars += $file.Length
        }
    }

    $toolCallTotal = @($toolCalls.Keys | ForEach-Object { $toolCalls[$_] } | Measure-Object -Sum).Sum
    if ($null -eq $toolCallTotal) { $toolCallTotal = 0 }

    return [ordered]@{
        tool_calls = $toolCalls
        total_tool_calls = $toolCallTotal
        total_steps = @($Events | Where-Object type -eq 'assistant.turn_end').Count
        errors_encountered = $errors
        output_chars = $outputChars
        transcript_chars = $transcriptChars
    }
}

function Kill-ProcessTree {
    param([Parameter(Mandatory = $true)] [System.Diagnostics.Process]$Process)

    if ($Process.HasExited) {
        return [pscustomobject]@{
            attempted = $false
            completed = $true
            exitCode = $Process.ExitCode
        }
    }

    try {
        $Process.Kill($true)
        $Process.WaitForExit(5000) | Out-Null
        return [pscustomobject]@{
            attempted = $true
            completed = $Process.HasExited
            exitCode = if ($Process.HasExited) { $Process.ExitCode } else { $null }
        }
    } catch {
        return [pscustomobject]@{
            attempted = $true
            completed = $false
            error = $_.Exception.Message
        }
    }
}

function Write-TranscriptFallback {
    param(
        [Parameter(Mandatory = $true)] [string]$TranscriptPath,
        [Parameter(Mandatory = $true)] [string]$Prompt,
        [AllowEmptyCollection()] [object[]]$Events,
        [string]$StderrText
    )

    if (Test-Path -LiteralPath $TranscriptPath -PathType Leaf) { return }

    $assistantMessages = @($Events | Where-Object type -eq 'assistant.message' | ForEach-Object { [string]$_.data.content })
    $content = @(
        '# Copilot CLI Session (Fallback)'
        ''
        '## Eval Prompt'
        ''
        $Prompt
        ''
        '## Assistant Output'
        ''
        if (@($assistantMessages).Count -gt 0) { ($assistantMessages -join [Environment]::NewLine + [Environment]::NewLine) } else { '(No final assistant message was captured.)' }
    )
    if (-not [string]::IsNullOrWhiteSpace($StderrText)) {
        $content += @(
            '',
            '## stderr',
            '',
            '```text',
            $StderrText.Trim(),
            '```'
        )
    }
    Write-TextFile -Path $TranscriptPath -Content ($content -join [Environment]::NewLine)
}

function Get-CopilotFinalMessage {
    param([AllowEmptyCollection()] [object[]]$Events)

    $message = $Events | Where-Object type -eq 'assistant.message' | Select-Object -Last 1
    if ($null -eq $message) { return $null }
    return [string]$message.data.content
}

function Get-UsageResult {
    param([AllowEmptyCollection()] [object[]]$Events)

    $result = $Events | Where-Object type -eq 'result' | Select-Object -Last 1
    if ($null -eq $result) { return $null }
    return $result
}

function Summarize-DotnetLogs {
    param(
        [Parameter(Mandatory = $true)] [string]$LogDirectory,
        [Parameter(Mandatory = $true)] [string]$OutputsPath
    )

    if (-not (Test-Path -LiteralPath $LogDirectory -PathType Container)) {
        return [ordered]@{
            totals = [ordered]@{
                restoreSeconds = 0
                buildSeconds = 0
                testSeconds = 0
            }
            commands = @()
        }
    }

    $entries = @(
        Get-ChildItem -LiteralPath $LogDirectory -Filter 'dotnet-*.json' -File -Force |
            Sort-Object Name |
            ForEach-Object { Get-Content -LiteralPath $_.FullName -Raw | ConvertFrom-Json }
    )

    $restoreSeconds = 0.0
    $buildSeconds = 0.0
    $testSeconds = 0.0
    $summaryLines = [System.Collections.Generic.List[string]]::new()
    $summaryLines.Add('# dotnet command summary')
    $summaryLines.Add('')
    foreach ($entry in @($entries)) {
        switch ([string]$entry.command) {
            'restore' { $restoreSeconds += [double]$entry.durationSeconds }
            'build' { $buildSeconds += [double]$entry.durationSeconds }
            'test' { $testSeconds += [double]$entry.durationSeconds }
        }
        $summaryLines.Add("- $($entry.command) exit $($entry.exitCode) in $($entry.durationSeconds)s")
    }
    Write-TextFile -Path (Join-Path $OutputsPath 'dotnet-summary.md') -Content ($summaryLines -join [Environment]::NewLine)

    return [ordered]@{
        totals = [ordered]@{
            restoreSeconds = [math]::Round($restoreSeconds, 3)
            buildSeconds = [math]::Round($buildSeconds, 3)
            testSeconds = [math]::Round($testSeconds, 3)
        }
        commands = @($entries)
    }
}

function Summarize-ResolverTrace {
    param(
        [Parameter(Mandatory = $true)] [string]$TracePath,
        [Parameter(Mandatory = $true)] [string]$OutputsPath
    )

    if (-not (Test-Path -LiteralPath $TracePath -PathType Leaf)) {
        return [ordered]@{
            durationSeconds = 0
            cacheHits = 0
            calls = 0
        }
    }

    $events = [System.Collections.Generic.List[object]]::new()
    foreach ($line in Get-Content -LiteralPath $TracePath) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        try { [void]$events.Add(($line | ConvertFrom-Json)) } catch { }
    }

    $summaryLines = [System.Collections.Generic.List[string]]::new()
    $summaryLines.Add('# resolver summary')
    $summaryLines.Add('')
    foreach ($event in @($events)) {
        $summaryLines.Add("- role $($event.role) tfms $($event.targetFrameworks -join ';') cacheHit $($event.cacheHit) duration $($event.durationSeconds)s")
    }
    Write-TextFile -Path (Join-Path $OutputsPath 'resolver-summary.md') -Content ($summaryLines -join [Environment]::NewLine)

    return [ordered]@{
        durationSeconds = [math]::Round((@($events | ForEach-Object { [double]$_.durationSeconds } | Measure-Object -Sum).Sum), 3)
        cacheHits = @($events | Where-Object cacheHit).Count
        calls = @($events).Count
        events = @($events)
    }
}

function Write-FallbackGrading {
    param(
        [Parameter(Mandatory = $true)] [string]$GradingPath,
        [Parameter(Mandatory = $true)] [object[]]$Expectations,
        [Parameter(Mandatory = $true)] [string]$Reason,
        [Parameter(Mandatory = $true)] $Timing,
        [Parameter(Mandatory = $true)] $Metrics
    )

    $entries = foreach ($expectation in @($Expectations)) {
        [ordered]@{
            text = [string]$expectation
            passed = $false
            evidence = $Reason
        }
    }
    $total = @($entries).Count
    Write-JsonFile -Path $GradingPath -Value ([ordered]@{
        expectations = @($entries)
        summary = [ordered]@{
            passed = 0
            failed = $total
            total = $total
            pass_rate = 0
        }
        execution_metrics = $Metrics
        timing = $Timing
        claims = @()
        user_notes_summary = [ordered]@{
            uncertainties = @()
            needs_review = @()
            workarounds = @($Reason)
        }
    })
}

function New-CopilotProcessArguments {
    param(
        [Parameter(Mandatory = $true)] [string]$Prompt,
        [Parameter(Mandatory = $true)] [string]$WorkingDirectory,
        [Parameter(Mandatory = $true)] [string]$ModelName,
        [string]$SharePath,
        [switch]$DisableSkillTool
    )

    $arguments = [System.Collections.Generic.List[string]]::new()
    foreach ($argument in @(
        '-p', $Prompt,
        '--allow-all',
        '--no-ask-user',
        '--output-format', 'json',
        '--no-custom-instructions',
        '--disable-builtin-mcps',
        '--disable-mcp-server', 'openart.ai',
        '--disable-mcp-server', 'sonarqube',
        '--disable-mcp-server', 'github-mcp-server',
        '--model', $ModelName,
        '-C', $WorkingDirectory
    )) {
        [void]$arguments.Add($argument)
    }
    if ($DisableSkillTool) {
        [void]$arguments.Add('--excluded-tools')
        [void]$arguments.Add('skill')
    }
    if (-not [string]::IsNullOrWhiteSpace($SharePath)) {
        [void]$arguments.Add('--share')
        [void]$arguments.Add($SharePath)
    }
    return @($arguments)
}

function New-CopilotWrapperScript {
    param(
        [Parameter(Mandatory = $true)] [string]$WrapperPath,
        [Parameter(Mandatory = $true)] [string]$CopilotPowerShellPath,
        [Parameter(Mandatory = $true)] [string]$Prompt,
        [Parameter(Mandatory = $true)] [string]$WorkingDirectory,
        [Parameter(Mandatory = $true)] [string]$ModelName,
        [string]$SharePath,
        [switch]$DisableSkillTool
    )

    $content = @(
        '$prompt = @'''
        $Prompt
        '''@'
        '$arguments = [System.Collections.Generic.List[string]]::new()'
        '$arguments.Add(''-p'')'
        '$arguments.Add($prompt)'
        '$arguments.Add(''--allow-all'')'
        '$arguments.Add(''--no-ask-user'')'
        '$arguments.Add(''--output-format'')'
        '$arguments.Add(''json'')'
        '$arguments.Add(''--no-custom-instructions'')'
        '$arguments.Add(''--disable-builtin-mcps'')'
        '$arguments.Add(''--disable-mcp-server'')'
        '$arguments.Add(''openart.ai'')'
        '$arguments.Add(''--disable-mcp-server'')'
        '$arguments.Add(''sonarqube'')'
        '$arguments.Add(''--disable-mcp-server'')'
        '$arguments.Add(''github-mcp-server'')'
        ('$arguments.Add(''' + '--model' + ''')')
        ('$arguments.Add(''' + $ModelName.Replace("'", "''") + ''')')
        ('$arguments.Add(''' + '-C' + ''')')
        ('$arguments.Add(''' + $WorkingDirectory.Replace("'", "''") + ''')')
        if ($DisableSkillTool) {
            '$arguments.Add(''--excluded-tools'')'
            '$arguments.Add(''skill'')'
        }
        if (-not [string]::IsNullOrWhiteSpace($SharePath)) {
            ('$arguments.Add(''' + '--share' + ''')')
            ('$arguments.Add(''' + $SharePath.Replace("'", "''") + ''')')
        }
        ("& '{0}' @arguments" -f $CopilotPowerShellPath.Replace("'", "''"))
        'exit $LASTEXITCODE'
    ) -join [Environment]::NewLine

    Write-TextFile -Path $WrapperPath -Content ($content + [Environment]::NewLine)
}

function Start-CommandProcess {
    param(
        [Parameter(Mandatory = $true)] [string]$FilePath,
        [Parameter(Mandatory = $true)] [string[]]$Arguments,
        [Parameter(Mandatory = $true)] [string]$WorkingDirectory,
        [Parameter(Mandatory = $true)] [hashtable]$Environment,
        [Parameter(Mandatory = $true)] [string]$StdoutPath,
        [Parameter(Mandatory = $true)] [string]$StderrPath
    )

    $mergedEnvironment = @{}
    foreach ($entry in Get-ChildItem Env:) {
        $mergedEnvironment[$entry.Name] = $entry.Value
    }
    foreach ($key in $Environment.Keys) {
        $mergedEnvironment[$key] = [string]$Environment[$key]
    }

    $startInfo = @{
        FilePath = $FilePath
        ArgumentList = @($Arguments)
        WorkingDirectory = $WorkingDirectory
        RedirectStandardOutput = $StdoutPath
        RedirectStandardError = $StderrPath
        PassThru = $true
        NoNewWindow = $true
        Environment = $mergedEnvironment
    }

    try {
        $process = Start-Process @startInfo
    } catch {
        throw "Unable to start '$FilePath' in '$WorkingDirectory'. stdout='$StdoutPath' stderr='$StderrPath'. $($_.Exception.Message)"
    }
    return [pscustomobject]@{
        Process = $process
    }
}

function Invoke-SkillValidation {
    param(
        [Parameter(Mandatory = $true)] [string]$ResolvedSkillPath,
        [Parameter(Mandatory = $true)] [string]$Workspace
    )

    $validateScript = Join-Path $ResolvedSkillPath 'scripts\validate-skill.ps1'
    if (-not (Test-Path -LiteralPath $validateScript -PathType Leaf)) {
        return [ordered]@{
            ran = $false
            exitCode = $null
            durationSeconds = 0
        }
    }

    $logPath = Join-Path $Workspace '.benchmark\skill-validation.log'
    New-Item -ItemType Directory -Path (Split-Path -Path $logPath -Parent) -Force | Out-Null
    $start = [DateTimeOffset]::UtcNow
    $output = & pwsh -NoProfile -File $validateScript 2>&1
    $exitCode = $LASTEXITCODE
    Write-TextFile -Path $logPath -Content (($output -join [Environment]::NewLine) + [Environment]::NewLine)
    return [ordered]@{
        ran = $true
        exitCode = $exitCode
        durationSeconds = [math]::Round(([DateTimeOffset]::UtcNow - $start).TotalSeconds, 3)
        logPath = $logPath
    }
}

function Get-DotnetTestContexts {
    param(
        [Parameter(Mandatory = $true)] [object[]]$Evals,
        [Parameter(Mandatory = $true)] [string]$ResolvedSkillPath
    )

    $inspectScript = Join-Path $ResolvedSkillPath 'scripts\inspect-dotnet-tests.ps1'
    if (-not (Test-Path -LiteralPath $inspectScript -PathType Leaf)) { return @() }

    $contexts = [System.Collections.Generic.List[object]]::new()
    foreach ($eval in @($Evals)) {
        $files = @($eval.files)
        if (@($files).Count -eq 0) { continue }

        $roots = @($files | ForEach-Object { ($_ -replace '/', '\').Split('\')[2] } | Sort-Object -Unique)
        if (@($roots).Count -ne 1) { continue }
        $fixtureRoot = Join-Path $ResolvedSkillPath (Join-Path 'evals\files' $roots[0])
        $testProject = @($files | Where-Object { $_ -match 'test/.+\.csproj$' } | Select-Object -First 1)
        if ([string]::IsNullOrWhiteSpace($testProject)) {
            $testProject = @($files | Where-Object { $_ -match '\.csproj$' } | Select-Object -First 1)
        }
        if ([string]::IsNullOrWhiteSpace($testProject)) { continue }

        $relativeProject = ($testProject -replace '^evals/files/[^/]+/', '') -replace '/', '\'
        $result = & pwsh -NoProfile -File $inspectScript -RepoRoot $fixtureRoot -ProjectPath $relativeProject 2>&1
        if ($LASTEXITCODE -ne 0) { continue }

        try {
            $json = ($result -join [Environment]::NewLine) | ConvertFrom-Json
        } catch {
            continue
        }
        $project = @($json.projects | Select-Object -First 1)
        if ($null -eq $project) { continue }

        $role = switch ([string]$project.role) {
            'Ordinary unit test' { 'Unit' }
            'ASP.NET Core functional test' { 'WebFunctional' }
            'Console or worker functional test' { 'ApplicationFunctional' }
            default { $null }
        }
        if ($null -eq $role) { continue }

        $key = '{0}|{1}' -f $role, (@($project.frameworks) -join ';')
        $contexts.Add([pscustomobject]@{
            key = $key
            role = $role
            targetFrameworks = @($project.frameworks)
        })
    }

    return @($contexts | Sort-Object key -Unique)
}

function Invoke-DotnetTestPrewarm {
    param(
        [Parameter(Mandatory = $true)] [object[]]$Contexts,
        [Parameter(Mandatory = $true)] [string]$ResolvedSkillPath,
        [Parameter(Mandatory = $true)] [string]$CacheDirectory,
        [Parameter(Mandatory = $true)] [string]$TracePath,
        [Parameter(Mandatory = $true)] [int]$CandidateLimit
    )

    if (@($Contexts).Count -eq 0) {
        return [ordered]@{
            ran = $false
            durationSeconds = 0
            contexts = @()
        }
    }

    $resolver = Join-Path $ResolvedSkillPath 'scripts\resolve-test-package-versions.ps1'
    $start = [DateTimeOffset]::UtcNow
    $records = [System.Collections.Generic.List[object]]::new()
    foreach ($context in @($Contexts)) {
        $invocationStart = [DateTimeOffset]::UtcNow
        $output = & pwsh -NoProfile -File $resolver -TargetFramework $context.targetFrameworks -Role $context.role -MaximumCandidates $CandidateLimit -CacheDirectory $CacheDirectory -TraceFile $TracePath 2>&1
        $records.Add([ordered]@{
            role = $context.role
            targetFrameworks = @($context.targetFrameworks)
            exitCode = $LASTEXITCODE
            durationSeconds = [math]::Round(([DateTimeOffset]::UtcNow - $invocationStart).TotalSeconds, 3)
            output = ($output -join [Environment]::NewLine)
        })
        if ($LASTEXITCODE -ne 0) {
            throw "Dotnet-test prewarm failed for role '$($context.role)'."
        }
    }

    return [ordered]@{
        ran = $true
        durationSeconds = [math]::Round(([DateTimeOffset]::UtcNow - $start).TotalSeconds, 3)
        contexts = @($records)
    }
}

function Get-CopilotGraderPrompt {
    param(
        [Parameter(Mandatory = $true)] [string]$SkillCreatorRoot,
        [Parameter(Mandatory = $true)] [string]$TranscriptPath,
        [Parameter(Mandatory = $true)] [string]$OutputsPath,
        [Parameter(Mandatory = $true)] [string]$TimingPath,
        [Parameter(Mandatory = $true)] [string[]]$Expectations
    )

    $graderInstructions = [System.IO.File]::ReadAllText((Join-Path $SkillCreatorRoot 'agents\grader.md'), $utf8NoBom)
    $expectationsJson = ($Expectations | ConvertTo-Json)
    return @"
$graderInstructions

Read these artifacts, then output only the grading JSON object:
- transcript: $TranscriptPath
- outputs directory: $OutputsPath
- timing: $TimingPath

Expectations:
$expectationsJson

Do not edit any files. Output JSON only.
"@
}

function Start-BenchmarkRun {
    param(
        [Parameter(Mandatory = $true)] $RunPlan,
        [Parameter(Mandatory = $true)] [string]$SkillName,
        [Parameter(Mandatory = $true)] [string]$ResolvedSkillPath,
        [AllowNull()] [string]$ResolvedBaselineSkillPath,
        [Parameter(Mandatory = $true)] [string]$ModelName,
        [Parameter(Mandatory = $true)] [string]$Workspace,
        [Parameter(Mandatory = $true)] [string]$DotnetShimRoot,
        [Parameter(Mandatory = $true)] [string]$RealDotnet,
        [Parameter(Mandatory = $true)] [string]$CopilotScriptPath,
        [Parameter(Mandatory = $true)] [string]$SharedNugetPackages,
        [Parameter(Mandatory = $true)] [bool]$UseOptimizedDotnetMode,
        [AllowNull()] [string]$ExecutorCommandPath
    )

    $runRoot = $RunPlan.runRoot
    $repoRoot = Join-Path $runRoot 'repo'
    $outputsPath = Join-Path $runRoot 'outputs'
    New-Item -ItemType Directory -Path $repoRoot,$outputsPath,(Join-Path $runRoot '.benchmark') -Force | Out-Null

    $excludedPrefixes = @('.agents/', '.claude/', '.benchmark/', '.git/', 'bin/', 'obj/')

    if (Test-Path -LiteralPath $RunPlan.fixtureRoot -PathType Container) {
        foreach ($item in Get-ChildItem -LiteralPath $RunPlan.fixtureRoot -Force) {
            Copy-Item -LiteralPath $item.FullName -Destination $repoRoot -Recurse -Force
        }
    }

    if ($RunPlan.configuration -eq 'with_skill') {
        foreach ($skillDirectory in @('.agents\skills', '.claude\skills')) {
            $destination = Join-Path $repoRoot (Join-Path $skillDirectory $SkillName)
            New-Item -ItemType Directory -Path (Split-Path -Path $destination -Parent) -Force | Out-Null
            Copy-Item -LiteralPath $ResolvedSkillPath -Destination $destination -Recurse -Force
        }
    } elseif (-not [string]::IsNullOrWhiteSpace($ResolvedBaselineSkillPath)) {
        foreach ($skillDirectory in @('.agents\skills', '.claude\skills')) {
            $destination = Join-Path $repoRoot (Join-Path $skillDirectory $SkillName)
            New-Item -ItemType Directory -Path (Split-Path -Path $destination -Parent) -Force | Out-Null
            Copy-Item -LiteralPath $ResolvedBaselineSkillPath -Destination $destination -Recurse -Force
        }
    }

    $initialManifest = New-RunManifest -RepoRoot $repoRoot -ExcludedPrefixes $excludedPrefixes
    Write-JsonFile -Path (Join-Path $runRoot '.benchmark\initial-manifest.json') -Value $initialManifest

    $context = [ordered]@{
        eval_id = [int]$RunPlan.eval.id
        eval_name = $RunPlan.evalName
        prompt = [string]$RunPlan.eval.prompt
        expected_output = [string]$RunPlan.eval.expected_output
        expectations = @($RunPlan.eval.expectations)
        configuration = $RunPlan.configuration
        run_root = $runRoot
        repo_root = $repoRoot
        outputs_root = $outputsPath
        skill_name = $SkillName
        model = $ModelName
        profile = $RunPlan.profileName
    }
    $contextPath = Join-Path $runRoot '.benchmark\run-context.json'
    Write-JsonFile -Path $contextPath -Value $context

    $prompt = if ($RunPlan.configuration -eq 'with_skill') {
@"
Use the skill tool to invoke only the "$SkillName" skill before you begin. Do not invoke any other skill.
Work only in the current directory.
Do not ask the user questions; make reasonable assumptions and finish the task.
The current directory already contains any attached fixture files for this eval.

Task:
$($RunPlan.eval.prompt)
"@
    } else {
@"
This is the baseline run without the skill tool.
Work only in the current directory.
Do not ask the user questions; make reasonable assumptions and finish the task.
The current directory already contains any attached fixture files for this eval.

Task:
$($RunPlan.eval.prompt)
"@
    }

    $transcriptPath = Join-Path $runRoot 'transcript.md'
    $resultSummaryPath = Join-Path $runRoot 'result-summary.md'
    $stdoutPath = Join-Path $runRoot '.benchmark\executor.stdout.jsonl'
    $stderrPath = Join-Path $runRoot '.benchmark\executor.stderr.log'
    $sharePath = $transcriptPath

    $environment = @{
        PYTHONUTF8 = '1'
        SKILL_BENCHMARK_DOTNET_REAL = $RealDotnet
        SKILL_BENCHMARK_DOTNET_LOG_DIR = (Join-Path $runRoot '.benchmark\dotnet')
        SKILL_BENCHMARK_DOTNET_STDOUT = (Join-Path $runRoot '.benchmark\dotnet.stdout.log')
        SKILL_BENCHMARK_DOTNET_STDERR = (Join-Path $runRoot '.benchmark\dotnet.stderr.log')
        PATH = $DotnetShimRoot + [System.IO.Path]::PathSeparator + $env:PATH
        NUGET_PACKAGES = $SharedNugetPackages
        NUGET_HTTP_CACHE_PATH = (Join-Path $Workspace '.nuget\http-cache')
    }

    if ($UseOptimizedDotnetMode) {
        $environment['DOTNET_TEST_RESOLVER_CACHE_DIR'] = (Join-Path $Workspace '.benchmark\resolver-cache')
        $environment['DOTNET_TEST_RESOLVER_TRACE_FILE'] = (Join-Path $runRoot '.benchmark\resolver-trace.jsonl')
        $environment['DOTNET_TEST_MAXIMUM_CANDIDATES'] = [string]$BenchmarkCandidateLimit
    }

    $handle = if ([string]::IsNullOrWhiteSpace($ExecutorCommandPath)) {
        $wrapperPath = Join-Path $runRoot '.benchmark\invoke-copilot-executor.ps1'
        New-CopilotWrapperScript -WrapperPath $wrapperPath -CopilotPowerShellPath $CopilotScriptPath -Prompt $prompt -WorkingDirectory $repoRoot -ModelName $ModelName -SharePath $sharePath -DisableSkillTool:($RunPlan.configuration -ne 'with_skill')
        Start-CommandProcess -FilePath 'pwsh' -Arguments @('-NoProfile', '-File', $wrapperPath) -WorkingDirectory $repoRoot -Environment $environment -StdoutPath $stdoutPath -StderrPath $stderrPath
    } else {
        Start-CommandProcess -FilePath 'pwsh' -Arguments @('-NoProfile', '-File', $ExecutorCommandPath, '-ContextPath', $contextPath, '-RunRoot', $runRoot, '-TranscriptPath', $transcriptPath, '-ResultSummaryPath', $resultSummaryPath, '-OutputsPath', $outputsPath) -WorkingDirectory $repoRoot -Environment $environment -StdoutPath $stdoutPath -StderrPath $stderrPath
    }

    return [pscustomobject]@{
        plan = $RunPlan
        handle = $handle
        context = $context
        contextPath = $contextPath
        repoRoot = $repoRoot
        outputsPath = $outputsPath
        transcriptPath = $transcriptPath
        resultSummaryPath = $resultSummaryPath
        stdoutPath = $stdoutPath
        stderrPath = $stderrPath
        startedAt = [DateTimeOffset]::UtcNow
        initialManifest = $initialManifest
        useOptimizedDotnetMode = $UseOptimizedDotnetMode
    }
}

function Finalize-BenchmarkRun {
    param(
        [Parameter(Mandatory = $true)] $ActiveRun,
        [Parameter(Mandatory = $true)] [bool]$TimedOut
    )

    $runRoot = $ActiveRun.plan.runRoot
    $cleanup = if ($TimedOut) { Kill-ProcessTree -Process $ActiveRun.handle.Process } else { [ordered]@{ attempted = $false; completed = $true; exitCode = $ActiveRun.handle.Process.ExitCode } }
    $ActiveRun.handle.Process.WaitForExit()

    $stderrText = if (Test-Path -LiteralPath $ActiveRun.stderrPath) { (Get-Content -LiteralPath $ActiveRun.stderrPath -Raw) } else { '' }
    $stdoutEvents = @(Parse-CopilotEvents -JsonlPath $ActiveRun.stdoutPath)
    Write-TranscriptFallback -TranscriptPath $ActiveRun.transcriptPath -Prompt $ActiveRun.context.prompt -Events $stdoutEvents -StderrText $stderrText

    $assistantResponsePath = Join-Path $ActiveRun.outputsPath 'assistant-response.md'
    $finalMessage = Get-CopilotFinalMessage -Events $stdoutEvents
    if ([string]::IsNullOrWhiteSpace($finalMessage) -and (Test-Path -LiteralPath $assistantResponsePath -PathType Leaf)) {
        $finalMessage = (Get-Content -LiteralPath $assistantResponsePath -Raw)
    }
    if ([string]::IsNullOrWhiteSpace($finalMessage)) {
        $finalMessage = if ($TimedOut) { 'The executor timed out before producing a final assistant message.' } elseif ($ActiveRun.handle.Process.ExitCode -ne 0) { "The executor exited with code $($ActiveRun.handle.Process.ExitCode)." } else { 'The executor completed without a final assistant message.' }
    }
    Write-TextFile -Path $assistantResponsePath -Content ($finalMessage.Trim() + [Environment]::NewLine)
    if (-not (Test-Path -LiteralPath $ActiveRun.resultSummaryPath)) {
        Write-TextFile -Path $ActiveRun.resultSummaryPath -Content ($finalMessage.Trim() + [Environment]::NewLine)
    }

    $changes = @(Get-ChangedFiles -BaselineRoot $ActiveRun.plan.fixtureRoot -CurrentRoot $ActiveRun.repoRoot -BaselineManifest $ActiveRun.initialManifest -ExcludedPrefixes @('.agents/', '.claude/', '.benchmark/', '.git/', 'bin/', 'obj/'))
    Write-ChangeArtifacts -Changes $changes -OutputsPath $ActiveRun.outputsPath

    $dotnetSummary = Summarize-DotnetLogs -LogDirectory (Join-Path $runRoot '.benchmark\dotnet') -OutputsPath $ActiveRun.outputsPath
    $commandDurations = Get-PowerShellCommandDurations -Events $stdoutEvents
    $resolverSummary = Summarize-ResolverTrace -TracePath (Join-Path $runRoot '.benchmark\resolver-trace.jsonl') -OutputsPath $ActiveRun.outputsPath
    $metrics = Get-CopilotMetrics -Events $stdoutEvents -TranscriptPath $ActiveRun.transcriptPath -OutputsPath $ActiveRun.outputsPath
    Write-JsonFile -Path (Join-Path $ActiveRun.outputsPath 'metrics.json') -Value $metrics

    $resultEvent = Get-UsageResult -Events $stdoutEvents
    $endedAt = [DateTimeOffset]::UtcNow
    $cleanupError = if ($cleanup.PSObject.Properties.Name -contains 'error') { $cleanup.error } else { $null }
    $timing = [ordered]@{
        executor = [ordered]@{
            startedAt = $ActiveRun.startedAt.ToString('O')
            endedAt = $endedAt.ToString('O')
            durationSeconds = [math]::Round(($endedAt - $ActiveRun.startedAt).TotalSeconds, 3)
            exitCode = if ($ActiveRun.handle.Process.HasExited) { $ActiveRun.handle.Process.ExitCode } else { $null }
            result = $resultEvent
        }
        cleanup = [ordered]@{
            timedOut = $TimedOut
            attempted = [bool]$cleanup.attempted
            completed = [bool]$cleanup.completed
            exitCode = $cleanup.exitCode
            error = $cleanupError
        }
        dotnet = $dotnetSummary.totals
        resolver = [ordered]@{
            durationSeconds = if ([double]$commandDurations.resolverSeconds -gt 0) { $commandDurations.resolverSeconds } else { $resolverSummary.durationSeconds }
            cacheHits = $resolverSummary.cacheHits
            calls = $resolverSummary.calls
        }
        commandDurations = $commandDurations
        total_duration_seconds = [math]::Round(($endedAt - $ActiveRun.startedAt).TotalSeconds, 3)
        duration_ms = [int][math]::Round(($endedAt - $ActiveRun.startedAt).TotalMilliseconds)
        total_tokens = 0
    }
    if ([double]$commandDurations.restoreSeconds -gt 0) { $timing.dotnet.restoreSeconds = $commandDurations.restoreSeconds }
    if ([double]$commandDurations.buildSeconds -gt 0) { $timing.dotnet.buildSeconds = $commandDurations.buildSeconds }
    if ([double]$commandDurations.testSeconds -gt 0) { $timing.dotnet.testSeconds = $commandDurations.testSeconds }
    Write-JsonFile -Path (Join-Path $runRoot 'timing.json') -Value $timing

    return [pscustomobject]@{
        runRoot = $runRoot
        transcriptPath = $ActiveRun.transcriptPath
        outputsPath = $ActiveRun.outputsPath
        timing = $timing
        metrics = $metrics
        context = $ActiveRun.context
        stdoutPath = $ActiveRun.stdoutPath
        completedAt = $endedAt
    }
}

function Invoke-Profile {
    param(
        [Parameter(Mandatory = $true)] [string]$ProfileName,
        [Parameter(Mandatory = $true)] [string]$ResolvedSkillPath,
        [AllowNull()] [string]$ResolvedBaselineSkillPath,
        [Parameter(Mandatory = $true)] [object[]]$Evals,
        [Parameter(Mandatory = $true)] [object]$SkillMetadata,
        [Parameter(Mandatory = $true)] [string]$Workspace,
        [Parameter(Mandatory = $true)] [int]$ExecutorParallelism,
        [Parameter(Mandatory = $true)] [int]$GraderParallelism,
        [Parameter(Mandatory = $true)] [bool]$EnableOptimizations,
        [Parameter(Mandatory = $true)] [string]$CopilotScriptPath,
        [AllowNull()] [string]$ExecutorCommandPath,
        [AllowNull()] [string]$GraderCommandPath,
        [Parameter(Mandatory = $true)] [string]$SkillCreatorRootPath,
        [Parameter(Mandatory = $true)] $ValidationResult,
        [Parameter(Mandatory = $true)] $PrewarmResult,
        [Parameter(Mandatory = $true)] [int]$RunTimeout,
        [Parameter(Mandatory = $true)] [int]$GradeTimeout,
        [Parameter(Mandatory = $true)] [string]$ModelName,
        [Parameter(Mandatory = $true)] [string]$GraderModelName
    )

    $iterationRoot = Join-Path $Workspace ('iteration-' + $ProfileName)
    if (Test-Path -LiteralPath $iterationRoot) {
        Remove-Item -LiteralPath $iterationRoot -Recurse -Force
    }
    New-Item -ItemType Directory -Path $iterationRoot -Force | Out-Null

    $profileStart = [DateTimeOffset]::UtcNow

    $realDotnet = Get-RealDotnetPath
    $sharedNugetPackages = Join-Path $Workspace '.nuget\packages'
    New-Item -ItemType Directory -Path $sharedNugetPackages,(Join-Path $Workspace '.nuget\http-cache') -Force | Out-Null
    $dotnetShimRoot = Initialize-DotnetShim -Workspace $Workspace -RealDotnet $realDotnet

    $plans = [System.Collections.Generic.Queue[object]]::new()
    foreach ($eval in @($Evals)) {
        $evalSlug = Get-Slug -Text ([string]$eval.prompt)
        if ($evalSlug.Length -gt 24) {
            $evalSlug = $evalSlug.Substring(0, 24).Trim('-')
        }
        if ([string]::IsNullOrWhiteSpace($evalSlug)) {
            $evalSlug = 'eval'
        }
        $evalName = 'eval-{0:D2}-{1}' -f [int]$eval.id, $evalSlug
        $evalRoot = Join-Path $iterationRoot $evalName
        $fixtureRoot = Join-Path $evalRoot 'fixtures'
        New-Item -ItemType Directory -Path $fixtureRoot -Force | Out-Null
        foreach ($file in @($eval.files)) {
            $source = Join-Path $ResolvedSkillPath ($file -replace '/', '\')
            $relative = ($file -replace '^evals/files/[^/]+/', '') -replace '/', '\'
            $destination = Join-Path $fixtureRoot $relative
            New-Item -ItemType Directory -Path (Split-Path -Path $destination -Parent) -Force | Out-Null
            Copy-Item -LiteralPath $source -Destination $destination -Force
        }

        Write-JsonFile -Path (Join-Path $evalRoot 'eval_metadata.json') -Value ([ordered]@{
            eval_id = [int]$eval.id
            eval_name = $evalName
            prompt = [string]$eval.prompt
            assertions = @($eval.expectations)
        })

        foreach ($configuration in @('with_skill', 'without_skill')) {
            $runRoot = Join-Path $evalRoot (Join-Path $configuration 'run-1')
            New-Item -ItemType Directory -Path $runRoot -Force | Out-Null
            $plans.Enqueue([pscustomobject]@{
                eval = $eval
                evalName = $evalName
                evalRoot = $evalRoot
                fixtureRoot = $fixtureRoot
                configuration = $configuration
                runRoot = $runRoot
                profileName = $ProfileName
            })
        }
    }

    $activeRuns = [System.Collections.Generic.List[object]]::new()
    $completedRuns = [System.Collections.Generic.List[object]]::new()
    $maxConcurrentExecutors = 0

    while ($plans.Count -gt 0 -or $activeRuns.Count -gt 0) {
        while ($plans.Count -gt 0 -and $activeRuns.Count -lt $ExecutorParallelism) {
            $plan = $plans.Dequeue()
            $activeRuns.Add((Start-BenchmarkRun -RunPlan $plan -SkillName $SkillMetadata.Name -ResolvedSkillPath $ResolvedSkillPath -ResolvedBaselineSkillPath $ResolvedBaselineSkillPath -ModelName $ModelName -Workspace $Workspace -DotnetShimRoot $dotnetShimRoot -RealDotnet $realDotnet -CopilotScriptPath $CopilotScriptPath -SharedNugetPackages $sharedNugetPackages -UseOptimizedDotnetMode $EnableOptimizations -ExecutorCommandPath $ExecutorCommandPath))
            if ($activeRuns.Count -gt $maxConcurrentExecutors) { $maxConcurrentExecutors = $activeRuns.Count }
        }

        foreach ($activeRun in @($activeRuns)) {
            $elapsed = ([DateTimeOffset]::UtcNow - $activeRun.startedAt).TotalSeconds
            if ($activeRun.handle.Process.HasExited) {
                $activeRuns.Remove($activeRun) | Out-Null
                $completedRuns.Add((Finalize-BenchmarkRun -ActiveRun $activeRun -TimedOut $false))
                continue
            }
            if ($elapsed -ge $RunTimeout) {
                $activeRuns.Remove($activeRun) | Out-Null
                $completedRuns.Add((Finalize-BenchmarkRun -ActiveRun $activeRun -TimedOut $true))
            }
        }
        if ($activeRuns.Count -gt 0) {
            Start-Sleep -Milliseconds 250
        }
    }

    $gradeQueue = [System.Collections.Generic.Queue[object]]::new()
    foreach ($run in @($completedRuns)) { $gradeQueue.Enqueue($run) }
    $activeGraders = [System.Collections.Generic.List[object]]::new()
    $maxConcurrentGraders = 0

    while ($gradeQueue.Count -gt 0 -or $activeGraders.Count -gt 0) {
        while ($gradeQueue.Count -gt 0 -and $activeGraders.Count -lt $GraderParallelism) {
            $run = $gradeQueue.Dequeue()
            $gradingPath = Join-Path $run.runRoot 'grading.json'
            $stdoutPath = Join-Path $run.runRoot '.benchmark\grader.stdout.jsonl'
            $stderrPath = Join-Path $run.runRoot '.benchmark\grader.stderr.log'
            if ([string]::IsNullOrWhiteSpace($GraderCommandPath)) {
                $prompt = Get-CopilotGraderPrompt -SkillCreatorRoot $SkillCreatorRootPath -TranscriptPath $run.transcriptPath -OutputsPath $run.outputsPath -TimingPath (Join-Path $run.runRoot 'timing.json') -Expectations @($run.context.expectations)
                $wrapperPath = Join-Path $run.runRoot '.benchmark\invoke-copilot-grader.ps1'
                New-CopilotWrapperScript -WrapperPath $wrapperPath -CopilotPowerShellPath $CopilotScriptPath -Prompt $prompt -WorkingDirectory $run.runRoot -ModelName $GraderModelName -DisableSkillTool
                $handle = Start-CommandProcess -FilePath 'pwsh' -Arguments @('-NoProfile', '-File', $wrapperPath) -WorkingDirectory $run.runRoot -Environment @{} -StdoutPath $stdoutPath -StderrPath $stderrPath
                $activeGraders.Add([pscustomobject]@{
                    run = $run
                    gradingPath = $gradingPath
                    startedAt = [DateTimeOffset]::UtcNow
                    kind = 'copilot'
                    handle = $handle
                    stdoutPath = $stdoutPath
                    stderrPath = $stderrPath
                })
            } else {
                $handle = Start-CommandProcess -FilePath 'pwsh' -Arguments @('-NoProfile', '-File', $GraderCommandPath, '-ContextPath', (Join-Path $run.runRoot '.benchmark\run-context.json'), '-TranscriptPath', $run.transcriptPath, '-OutputsPath', $run.outputsPath, '-TimingPath', (Join-Path $run.runRoot 'timing.json'), '-GradingPath', $gradingPath) -WorkingDirectory $run.runRoot -Environment @{} -StdoutPath $stdoutPath -StderrPath $stderrPath
                $activeGraders.Add([pscustomobject]@{
                    run = $run
                    gradingPath = $gradingPath
                    startedAt = [DateTimeOffset]::UtcNow
                    kind = 'command'
                    handle = $handle
                    stdoutPath = $stdoutPath
                    stderrPath = $stderrPath
                })
            }
            if ($activeGraders.Count -gt $maxConcurrentGraders) { $maxConcurrentGraders = $activeGraders.Count }
        }

        foreach ($grader in @($activeGraders)) {
            $elapsed = ([DateTimeOffset]::UtcNow - $grader.startedAt).TotalSeconds
            if ($grader.handle.Process.HasExited) {
                $grader.handle.Process.WaitForExit()
                if ($grader.kind -eq 'copilot') {
                    try {
                        if ($grader.handle.Process.ExitCode -ne 0) {
                            throw "Copilot grader exited with code $($grader.handle.Process.ExitCode)."
                        }
                        $events = Parse-CopilotEvents -JsonlPath $grader.stdoutPath
                        $jsonText = Get-CopilotFinalMessage -Events $events
                        if ([string]::IsNullOrWhiteSpace($jsonText)) {
                            throw 'Copilot grader did not return a JSON message.'
                        }
                        $parsed = $jsonText | ConvertFrom-Json
                        Write-JsonFile -Path $grader.gradingPath -Value $parsed
                    } catch {
                        Write-FallbackGrading -GradingPath $grader.gradingPath -Expectations @($grader.run.context.expectations) -Reason $_.Exception.Message -Timing $grader.run.timing -Metrics $grader.run.metrics
                    }
                } elseif ($grader.handle.Process.ExitCode -ne 0 -or -not (Test-Path -LiteralPath $grader.gradingPath -PathType Leaf)) {
                    Write-FallbackGrading -GradingPath $grader.gradingPath -Expectations @($grader.run.context.expectations) -Reason "Custom grader exited with code $($grader.handle.Process.ExitCode)." -Timing $grader.run.timing -Metrics $grader.run.metrics
                }
                Update-TimingWithGrader -TimingPath (Join-Path $grader.run.runRoot 'timing.json') -GraderStartedAt $grader.startedAt -GraderEndedAt ([DateTimeOffset]::UtcNow)
                $grader.run.timing = Get-Content -LiteralPath (Join-Path $grader.run.runRoot 'timing.json') -Raw | ConvertFrom-Json
                $activeGraders.Remove($grader) | Out-Null
                continue
            }
            if ($elapsed -ge $GradeTimeout) {
                [void](Kill-ProcessTree -Process $grader.handle.Process)
                Write-FallbackGrading -GradingPath $grader.gradingPath -Expectations @($grader.run.context.expectations) -Reason 'The grader timed out.' -Timing $grader.run.timing -Metrics $grader.run.metrics
                Update-TimingWithGrader -TimingPath (Join-Path $grader.run.runRoot 'timing.json') -GraderStartedAt $grader.startedAt -GraderEndedAt ([DateTimeOffset]::UtcNow)
                $grader.run.timing = Get-Content -LiteralPath (Join-Path $grader.run.runRoot 'timing.json') -Raw | ConvertFrom-Json
                $activeGraders.Remove($grader) | Out-Null
            }
        }
        if ($activeGraders.Count -gt 0) {
            Start-Sleep -Milliseconds 200
        }
    }

    $aggregateScript = Join-Path $SkillCreatorRootPath 'scripts\aggregate_benchmark.py'
    $viewerScript = Join-Path $SkillCreatorRootPath 'eval-viewer\generate_review.py'
    $previousPythonUtf8 = $env:PYTHONUTF8
    $env:PYTHONUTF8 = '1'
    $benchmarkOutput = & python $aggregateScript $iterationRoot --skill-name $SkillMetadata.Name --skill-path $ResolvedSkillPath 2>&1
    if ($LASTEXITCODE -ne 0) {
        if ($null -eq $previousPythonUtf8) { Remove-Item Env:PYTHONUTF8 -ErrorAction SilentlyContinue } else { $env:PYTHONUTF8 = $previousPythonUtf8 }
        throw "Benchmark aggregation failed for profile '$ProfileName'.`n$($benchmarkOutput -join [Environment]::NewLine)"
    }
    Update-BenchmarkMetadata -BenchmarkPath (Join-Path $iterationRoot 'benchmark.json') -ExecutorModel $ModelName -AnalyzerModel $GraderModelName -RunsPerConfiguration 1

    $reviewPath = Join-Path $Workspace ('review-' + $ProfileName + '.html')
    if (-not $SkipReview) {
        $viewerOutput = & python $viewerScript $iterationRoot --skill-name $SkillMetadata.Name --benchmark (Join-Path $iterationRoot 'benchmark.json') --static $reviewPath 2>&1
        if ($null -eq $previousPythonUtf8) { Remove-Item Env:PYTHONUTF8 -ErrorAction SilentlyContinue } else { $env:PYTHONUTF8 = $previousPythonUtf8 }
        if ($LASTEXITCODE -ne 0) {
            throw "Static review generation failed for profile '$ProfileName'.`n$($viewerOutput -join [Environment]::NewLine)"
        }
    } else {
        if ($null -eq $previousPythonUtf8) { Remove-Item Env:PYTHONUTF8 -ErrorAction SilentlyContinue } else { $env:PYTHONUTF8 = $previousPythonUtf8 }
    }

    $profileEnd = [DateTimeOffset]::UtcNow
    $summary = [ordered]@{
        profile = $ProfileName
        skill = $SkillMetadata.Name
        iterationRoot = $iterationRoot
        startedAt = $profileStart.ToString('O')
        endedAt = $profileEnd.ToString('O')
        totalWallClockSeconds = [math]::Round(($profileEnd - $profileStart).TotalSeconds, 3)
        validation = $ValidationResult
        prewarm = $PrewarmResult
        maxConcurrentExecutorsObserved = $maxConcurrentExecutors
        maxConcurrentGradersObserved = $maxConcurrentGraders
        runCount = @($completedRuns).Count
        timedOutRuns = @($completedRuns | Where-Object { $_.timing.cleanup.timedOut }).Count
        cleanupFailures = @($completedRuns | Where-Object { -not $_.timing.cleanup.completed }).Count
        totalResolverSeconds = [math]::Round((@($completedRuns | ForEach-Object { [double]$_.timing.resolver.durationSeconds } | Measure-Object -Sum).Sum), 3)
        totalRestoreSeconds = [math]::Round((@($completedRuns | ForEach-Object { [double]$_.timing.dotnet.restoreSeconds } | Measure-Object -Sum).Sum), 3)
        totalBuildSeconds = [math]::Round((@($completedRuns | ForEach-Object { [double]$_.timing.dotnet.buildSeconds } | Measure-Object -Sum).Sum), 3)
        totalTestSeconds = [math]::Round((@($completedRuns | ForEach-Object { [double]$_.timing.dotnet.testSeconds } | Measure-Object -Sum).Sum), 3)
        runs = @($completedRuns | ForEach-Object {
            [ordered]@{
                evalId = $_.context.eval_id
                configuration = $_.context.configuration
                runRoot = $_.runRoot
                totalDurationSeconds = $_.timing.total_duration_seconds
                timedOut = $_.timing.cleanup.timedOut
                cleanupCompleted = $_.timing.cleanup.completed
                exitCode = $_.timing.executor.exitCode
                resolverSeconds = $_.timing.resolver.durationSeconds
                restoreSeconds = $_.timing.dotnet.restoreSeconds
                buildSeconds = $_.timing.dotnet.buildSeconds
                testSeconds = $_.timing.dotnet.testSeconds
            }
        })
        benchmarkPath = (Join-Path $iterationRoot 'benchmark.json')
        reviewPath = $reviewPath
    }
    Write-JsonFile -Path (Join-Path $iterationRoot 'runner-summary.json') -Value $summary

    return $summary
}

function Write-ComparisonArtifacts {
    param(
        [Parameter(Mandatory = $true)] [string]$Workspace,
        [Parameter(Mandatory = $true)] $ValidationResult,
        [Parameter(Mandatory = $true)] $OptimizedPrewarmResult,
        [Parameter(Mandatory = $true)] $Legacy,
        [Parameter(Mandatory = $true)] $Optimized
    )

    $legacyWorkflowSeconds = [math]::Round([double]$ValidationResult.durationSeconds + [double]$Legacy.totalWallClockSeconds, 3)
    $optimizedWorkflowSeconds = [math]::Round([double]$ValidationResult.durationSeconds + [double]$OptimizedPrewarmResult.durationSeconds + [double]$Optimized.totalWallClockSeconds, 3)
    $saved = [math]::Round($legacyWorkflowSeconds - $optimizedWorkflowSeconds, 3)
    $percent = if ($legacyWorkflowSeconds -gt 0) {
        [math]::Round(($saved / $legacyWorkflowSeconds) * 100, 2)
    } else {
        0
    }

    $comparison = [ordered]@{
        skill = $Legacy.skill
        workspace = $Workspace
        sharedValidation = $ValidationResult
        optimizedPrewarm = $OptimizedPrewarmResult
        legacy = $Legacy
        optimized = $Optimized
        delta = [ordered]@{
            legacyWorkflowSeconds = $legacyWorkflowSeconds
            optimizedWorkflowSeconds = $optimizedWorkflowSeconds
            wallClockSecondsSaved = $saved
            percentFaster = $percent
            resolverSecondsSaved = [math]::Round([double]$Legacy.totalResolverSeconds - [double]$Optimized.totalResolverSeconds, 3)
            restoreSecondsSaved = [math]::Round([double]$Legacy.totalRestoreSeconds - [double]$Optimized.totalRestoreSeconds, 3)
            buildSecondsSaved = [math]::Round([double]$Legacy.totalBuildSeconds - [double]$Optimized.totalBuildSeconds, 3)
            testSecondsSaved = [math]::Round([double]$Legacy.totalTestSeconds - [double]$Optimized.totalTestSeconds, 3)
        }
    }
    Write-JsonFile -Path (Join-Path $Workspace 'comparison.json') -Value $comparison

    $lines = @(
        '# Skill Benchmark Comparison',
        '',
        '| Metric | Legacy | Optimized | Delta |',
        '|--------|--------|-----------|-------|',
        ('| Validation (shared) | {0}s | {0}s | {1:+0.###;-0.###;0}s |' -f $ValidationResult.durationSeconds, 0),
        ('| Resolver prewarm | 0s | {0}s | {1:+0.###;-0.###;0}s |' -f $OptimizedPrewarmResult.durationSeconds, (-1 * [double]$OptimizedPrewarmResult.durationSeconds)),
        ('| Workflow total | {0}s | {1}s | {2:+0.###;-0.###;0}s |' -f $legacyWorkflowSeconds, $optimizedWorkflowSeconds, $saved),
        ('| Resolver time | {0}s | {1}s | {2:+0.###;-0.###;0}s |' -f $Legacy.totalResolverSeconds, $Optimized.totalResolverSeconds, $comparison.delta.resolverSecondsSaved),
        ('| Restore time | {0}s | {1}s | {2:+0.###;-0.###;0}s |' -f $Legacy.totalRestoreSeconds, $Optimized.totalRestoreSeconds, $comparison.delta.restoreSecondsSaved),
        ('| Build time | {0}s | {1}s | {2:+0.###;-0.###;0}s |' -f $Legacy.totalBuildSeconds, $Optimized.totalBuildSeconds, $comparison.delta.buildSecondsSaved),
        ('| Test time | {0}s | {1}s | {2:+0.###;-0.###;0}s |' -f $Legacy.totalTestSeconds, $Optimized.totalTestSeconds, $comparison.delta.testSecondsSaved),
        ('| Timed out runs | {0} | {1} | {2:+0;-0;0} |' -f $Legacy.timedOutRuns, $Optimized.timedOutRuns, ($Legacy.timedOutRuns - $Optimized.timedOutRuns)),
        ('| Cleanup failures | {0} | {1} | {2:+0;-0;0} |' -f $Legacy.cleanupFailures, $Optimized.cleanupFailures, ($Legacy.cleanupFailures - $Optimized.cleanupFailures))
    )
    Write-TextFile -Path (Join-Path $Workspace 'comparison.md') -Content ($lines -join [Environment]::NewLine)
}

function Update-TimingWithGrader {
    param(
        [Parameter(Mandatory = $true)] [string]$TimingPath,
        [Parameter(Mandatory = $true)] [DateTimeOffset]$GraderStartedAt,
        [Parameter(Mandatory = $true)] [DateTimeOffset]$GraderEndedAt
    )

    if (-not (Test-Path -LiteralPath $TimingPath -PathType Leaf)) { return }

    $timing = Get-Content -LiteralPath $TimingPath -Raw | ConvertFrom-Json
    $graderDuration = [math]::Round(($GraderEndedAt - $GraderStartedAt).TotalSeconds, 3)

    $timing | Add-Member -NotePropertyName grader -NotePropertyValue ([pscustomobject]@{}) -Force
    $timing.grader | Add-Member -NotePropertyName startedAt -NotePropertyValue $GraderStartedAt.ToString('O') -Force
    $timing.grader | Add-Member -NotePropertyName endedAt -NotePropertyValue $GraderEndedAt.ToString('O') -Force
    $timing.grader | Add-Member -NotePropertyName durationSeconds -NotePropertyValue $graderDuration -Force

    $totalDuration = [math]::Round([double]$timing.executor.durationSeconds + $graderDuration, 3)
    $timing.total_duration_seconds = $totalDuration
    $timing.duration_ms = [long][math]::Round($totalDuration * 1000)

    Write-JsonFile -Path $TimingPath -Value $timing
}

function Update-BenchmarkMetadata {
    param(
        [Parameter(Mandatory = $true)] [string]$BenchmarkPath,
        [Parameter(Mandatory = $true)] [string]$ExecutorModel,
        [Parameter(Mandatory = $true)] [string]$AnalyzerModel,
        [Parameter(Mandatory = $true)] [int]$RunsPerConfiguration
    )

    if (-not (Test-Path -LiteralPath $BenchmarkPath -PathType Leaf)) { return }

    $benchmark = Get-Content -LiteralPath $BenchmarkPath -Raw | ConvertFrom-Json
    if ($null -eq $benchmark.metadata) {
        $benchmark | Add-Member -NotePropertyName metadata -NotePropertyValue ([pscustomobject]@{}) -Force
    }
    $benchmark.metadata | Add-Member -NotePropertyName executor_model -NotePropertyValue $ExecutorModel -Force
    $benchmark.metadata | Add-Member -NotePropertyName analyzer_model -NotePropertyValue $AnalyzerModel -Force
    $benchmark.metadata | Add-Member -NotePropertyName runs_per_configuration -NotePropertyValue $RunsPerConfiguration -Force
    Write-JsonFile -Path $BenchmarkPath -Value $benchmark
}

$repoRoot = Get-RepoRoot
$resolvedSkillPath = Get-ResolvedPath -Path $SkillPath
$baselineSkillPath = if ([string]::IsNullOrWhiteSpace($BaselineSkillPath)) { $null } else { Get-ResolvedPath -Path $BaselineSkillPath }
$skillMetadata = Get-SkillMetadata -ResolvedSkillPath $resolvedSkillPath
$skillCreatorRoot = Resolve-SkillCreatorRoot
$evals = Get-EvalDefinitions -ResolvedSkillPath $resolvedSkillPath -SelectedEvalId $EvalId
if (@($evals).Count -eq 0) {
    throw 'No evals matched the selected criteria.'
}

if ([string]::IsNullOrWhiteSpace($WorkspaceRoot)) {
    $WorkspaceRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('sb-' + $skillMetadata.Name + '-' + [DateTimeOffset]::UtcNow.ToString('yyyyMMdd-HHmmss'))
}
$workspace = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($WorkspaceRoot)
New-Item -ItemType Directory -Path $workspace -Force | Out-Null

$copilotScriptPath = Get-CopilotScriptPath
$executorPath = if ([string]::IsNullOrWhiteSpace($ExecutorCommand)) { $null } else { Get-ResolvedPath -Path $ExecutorCommand }
$graderPath = if ([string]::IsNullOrWhiteSpace($GraderCommand)) { $null } else { Get-ResolvedPath -Path $GraderCommand }
$shouldRunValidation = -not $SkipSkillValidation
if ([string]::IsNullOrWhiteSpace($GraderModel)) {
    $GraderModel = $Model
}

$validationResult = if ($shouldRunValidation) { Invoke-SkillValidation -ResolvedSkillPath $resolvedSkillPath -Workspace $workspace } else { [ordered]@{ ran = $false; exitCode = $null; durationSeconds = 0 } }
if ($validationResult.ran -and $validationResult.exitCode -ne 0) {
    throw 'Skill validation failed before benchmark execution.'
}

$optimizedPrewarm = [ordered]@{ ran = $false; durationSeconds = 0; contexts = @() }
if ($skillMetadata.Name -eq 'dotnet-test') {
    $contexts = Get-DotnetTestContexts -Evals $evals -ResolvedSkillPath $resolvedSkillPath
    if (@($contexts).Count -gt 0) {
        $optimizedPrewarm = Invoke-DotnetTestPrewarm -Contexts $contexts -ResolvedSkillPath $resolvedSkillPath -CacheDirectory (Join-Path $workspace '.benchmark\resolver-cache') -TracePath (Join-Path $workspace '.benchmark\resolver-prewarm.jsonl') -CandidateLimit $BenchmarkCandidateLimit
    }
}

$optimized = Invoke-Profile -ProfileName 'optimized' -ResolvedSkillPath $resolvedSkillPath -ResolvedBaselineSkillPath $baselineSkillPath -Evals $evals -SkillMetadata $skillMetadata -Workspace $workspace -ExecutorParallelism $MaxParallel -GraderParallelism $MaxGradeParallel -EnableOptimizations $true -CopilotScriptPath $copilotScriptPath -ExecutorCommandPath $executorPath -GraderCommandPath $graderPath -SkillCreatorRootPath $skillCreatorRoot -ValidationResult $validationResult -PrewarmResult $optimizedPrewarm -RunTimeout $RunTimeoutSeconds -GradeTimeout $GradeTimeoutSeconds -ModelName $Model -GraderModelName $GraderModel

if ($CompareWithLegacy) {
    $legacy = Invoke-Profile -ProfileName 'legacy' -ResolvedSkillPath $resolvedSkillPath -ResolvedBaselineSkillPath $baselineSkillPath -Evals $evals -SkillMetadata $skillMetadata -Workspace $workspace -ExecutorParallelism 1 -GraderParallelism 1 -EnableOptimizations $false -CopilotScriptPath $copilotScriptPath -ExecutorCommandPath $executorPath -GraderCommandPath $graderPath -SkillCreatorRootPath $skillCreatorRoot -ValidationResult $validationResult -PrewarmResult ([ordered]@{ ran = $false; durationSeconds = 0; contexts = @() }) -RunTimeout $RunTimeoutSeconds -GradeTimeout $GradeTimeoutSeconds -ModelName $Model -GraderModelName $GraderModel
    Write-ComparisonArtifacts -Workspace $workspace -ValidationResult $validationResult -OptimizedPrewarmResult $optimizedPrewarm -Legacy $legacy -Optimized $optimized
}

Write-TextFile -Path (Join-Path $workspace 'latest-profile.txt') -Content ('optimized' + [Environment]::NewLine)
Write-Output ("Benchmark workspace: {0}" -f $workspace)
Write-Output ("Optimized benchmark: {0}" -f $optimized.benchmarkPath)
Write-Output ("Optimized review: {0}" -f $optimized.reviewPath)
if ($CompareWithLegacy) {
    Write-Output ("Legacy benchmark: {0}" -f $legacy.benchmarkPath)
    Write-Output ("Legacy review: {0}" -f $legacy.reviewPath)
    Write-Output ("Comparison summary: {0}" -f (Join-Path $workspace 'comparison.json'))
}
