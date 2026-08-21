<#!
.SYNOPSIS
    Deterministic conformance suite for the common Eval Runner protocol.

.DESCRIPTION
    Creates an ephemeral package under the system temp directory, invokes only
    the fake runner, and checks the contracts and recorded event fixtures. It
    never invokes Codex, OpenCode, or a live model.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$runnerRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..\..')).Path
. (Join-Path $runnerRoot 'runner-common.ps1')

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw "ASSERT: $Message" }
}

function Assert-Equal {
    param([object]$Expected, [object]$Actual, [string]$Message)
    if ([string]$Expected -ne [string]$Actual) { throw "ASSERT: $Message (expected '$Expected', got '$Actual')" }
}

function Assert-Throws {
    param([scriptblock]$Action, [string]$Message)
    $thrown = $false
    try { & $Action } catch { $thrown = $true }
    if (-not $thrown) { throw "ASSERT: $Message" }
}

function Write-TestJson {
    param([string]$Path, [object]$Value)
    New-Item -ItemType Directory -Path (Split-Path -Parent $Path) -Force | Out-Null
    [System.IO.File]::WriteAllText($Path, ((ConvertTo-Json -InputObject $Value -Depth 100) + [Environment]::NewLine), [System.Text.UTF8Encoding]::new($false))
}

function Invoke-Fake {
    param(
        [string]$FakePath,
        [string]$Command,
        [string]$RunPath,
        [string]$ProfilePath,
        [string]$Scenario = ''
    )

    $arguments = @('-NoProfile', '-File', $FakePath, $Command, '-Run', $RunPath, '-Profile', $ProfilePath)
    if (-not [string]::IsNullOrWhiteSpace($Scenario)) { $arguments += @('-Scenario', $Scenario) }
    $output = & pwsh @arguments
    if ($LASTEXITCODE -ne 0) { throw "Fake runner '$Command' failed: $([string]::Join(' ', @($output)))" }
    $json = [string]::Join([Environment]::NewLine, @($output))
    if ([string]::IsNullOrWhiteSpace($json)) { throw "Fake runner '$Command' returned no JSON." }
    return $json | ConvertFrom-Json
}

function New-TestRun {
    param(
        [string]$IterationDirectory,
        [ValidateSet('with_skill', 'without_skill')][string]$Configuration
    )

    $evalDirectory = Join-Path $IterationDirectory 'conformance'
    $runRoot = Join-Path $evalDirectory $Configuration
    $repo = Join-Path $runRoot 'repo'
    $homeDirectory = Join-Path $runRoot 'home'
    New-Item -ItemType Directory -Path $repo,$homeDirectory -Force | Out-Null
    [System.IO.File]::WriteAllText((Join-Path $homeDirectory 'README.txt'), 'isolated home', [System.Text.UTF8Encoding]::new($false))
    $prompt = "# task`r`n`r`nByte fidelity: Δ and emoji 🚀.`r`n"
    [System.IO.File]::WriteAllBytes((Join-Path $runRoot 'prompt.md'), [System.Text.UTF8Encoding]::new($false).GetBytes($prompt))
    if ($Configuration -eq 'with_skill') {
        $skill = Join-Path $runRoot 'skill\candidate'
        New-Item -ItemType Directory -Path $skill -Force | Out-Null
        [System.IO.File]::WriteAllText((Join-Path $skill 'SKILL.md'), '# candidate', [System.Text.UTF8Encoding]::new($false))
        $skillDirectory = 'skill/candidate'
        $skillHash = ('b' * 64)
    } else {
        $skillDirectory = $null
        $skillHash = $null
    }
    $run = [ordered]@{
        schema = (Get-RunnerSchemaNames).Run
        evalId = 1
        evalName = 'conformance'
        skillName = if ($Configuration -eq 'with_skill') { 'candidate' } else { $null }
        iteration = 1
        mode = $Configuration
        promptFile = 'prompt.md'
        workingDirectory = 'repo'
        homeDirectory = 'home'
        skillDirectory = $skillDirectory
        freshContextRequired = $true
        filesystemIsolationRequired = $true
        isolatedHomeRequired = $true
        gitWorkspace = $false
        inputFiles = @()
        fixtureHash = ('a' * 64)
        skillHash = $skillHash
        contract = [ordered]@{
            sandboxRoot = '.'
            workingDirectory = 'repo'
            homeDirectory = 'home'
            mustNotReadOutsideSandbox = $true
            mustNotExposeGlobalSkillsOrConfig = $true
        }
    }
    $path = Join-Path $runRoot 'run.json'
    Write-TestJson -Path $path -Value $run
    return [pscustomobject]@{ Root = $runRoot; Path = $path; Contract = $run }
}

$testRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('agentic-runner-conformance-' + [Guid]::NewGuid().ToString('N'))
try {
    $iteration = Join-Path $testRoot 'iteration-1'
    New-Item -ItemType Directory -Path $iteration -Force | Out-Null
    $canaryPath = Join-Path $testRoot 'eval-metadata.json'
    [System.IO.File]::WriteAllText($canaryPath, 'grading-key-canary', [System.Text.UTF8Encoding]::new($false))
    $globalRoot = Join-Path $testRoot 'seeded-global-profile'
    New-Item -ItemType Directory -Path $globalRoot -Force | Out-Null
    [System.IO.File]::WriteAllText((Join-Path $globalRoot 'same-name-SKILL.md'), 'must remain invisible', [System.Text.UTF8Encoding]::new($false))
    [Environment]::SetEnvironmentVariable('AGENTIC_FAKE_GLOBAL_RULES', $globalRoot, 'Process')
    [Environment]::SetEnvironmentVariable('AGENTIC_FAKE_MEMORY', 'seeded-memory', 'Process')
    [Environment]::SetEnvironmentVariable('AGENTIC_FAKE_PLUGINS', 'seeded-plugins', 'Process')

    $profilePath = Join-Path $iteration 'execution-profile.json'
    Write-TestJson -Path $profilePath -Value ([ordered]@{
        schema = (Get-RunnerSchemaNames).Profile
        runner = 'fake'
        provider = 'fixture-provider'
        model = 'fixture-model'
        reasoning_effort = 'high'
        configuration_profile = 'isolated-default'
        tool_profile = 'default'
        timeout_seconds = 30
        concurrency = 1
    })
    $unsupportedProfilePath = Join-Path $iteration 'unsupported-profile.json'
    Write-TestJson -Path $unsupportedProfilePath -Value ([ordered]@{
        schema = (Get-RunnerSchemaNames).Profile
        runner = 'fake'
        provider = 'fixture-provider'
        model = 'fixture-model'
        reasoning_effort = $null
        configuration_profile = 'unsupported'
        tool_profile = 'default'
        timeout_seconds = 30
        concurrency = 1
    })

    $with = New-TestRun -IterationDirectory $iteration -Configuration with_skill
    $without = New-TestRun -IterationDirectory $iteration -Configuration without_skill
    $fakePath = Join-Path $runnerRoot 'fake\runner.ps1'

    $descriptor = Invoke-Fake -FakePath $fakePath -Command describe -Run $with.Path -Profile $profilePath
    [void](Assert-RunnerDescriptor -Descriptor $descriptor)
    Assert-Equal 'fake' $descriptor.name 'descriptor identity'
    Assert-Equal (Get-RunnerSchemaNames).Protocol $descriptor.protocol_version 'descriptor protocol'
    Assert-Throws { Assert-RunnerDescriptor -Descriptor ([pscustomobject]@{ schema = $descriptor.schema; protocol_version = 'changed'; name = 'fake' }) } 'changed protocol must fail descriptor validation'

    $unsupported = Invoke-Fake -FakePath $fakePath -Command preflight -Run $with.Path -Profile $unsupportedProfilePath
    Assert-Equal 'incompatible' $unsupported.status 'unsupported capability/profile must fail during preflight'
    Assert-True (@($unsupported.reasons).Count -gt 0) 'incompatible preflight must explain its reason'

    $withResult = Invoke-Fake -FakePath $fakePath -Command execute -Run $with.Path -Profile $profilePath
    $withoutResult = Invoke-Fake -FakePath $fakePath -Command execute -Run $without.Path -Profile $profilePath
    foreach ($result in @($withResult, $withoutResult)) {
        [void](Assert-ExecutionResult -Result $result)
        Assert-Equal 'completed' $result.status 'normal completion status'
        Assert-True $result.session.fresh 'fresh session flag'
        Assert-True (-not $result.session.resumed) 'resume must be false'
        Assert-Equal 1 $result.attempt_count 'answer-quality retry is forbidden'
        Assert-Equal 'fixture-provider' $result.requested.provider 'provider must pass unchanged'
        Assert-Equal 'fixture-model' $result.requested.model 'model must pass unchanged'
        Assert-Equal 'high' $result.requested.reasoning_effort 'reasoning effort must pass unchanged'
        Assert-Equal 'isolated-default' $result.requested.configuration_profile 'configuration profile must pass unchanged'
        Assert-Equal 'default' $result.requested.tool_profile 'tool profile must pass unchanged'
        Assert-Equal 'unavailable' $result.telemetry.tokens.status 'missing token telemetry must be explicit'
        Assert-True ($result.telemetry.tokens.PSObject.Properties.Name -notcontains 'value') 'missing token telemetry must not contain a zero placeholder'
        foreach ($artifact in @($result.artifacts)) {
            Assert-True ($artifact.path -notmatch '(^|/|\\)\.\.(/|\\|$)') 'artifact path must not escape the run'
            $artifactPath = Join-Path $($with.Root) ($artifact.path -replace '/', [System.IO.Path]::DirectorySeparatorChar)
            if ($result.run.configuration -eq 'without_skill') { $artifactPath = Join-Path $($without.Root) ($artifact.path -replace '/', [System.IO.Path]::DirectorySeparatorChar) }
            Assert-True (Test-Path -LiteralPath $artifactPath -PathType Leaf) 'artifact must exist inside its run'
            Assert-Equal $artifact.sha256 ((Get-FileHash -Algorithm SHA256 -LiteralPath $artifactPath).Hash.ToLowerInvariant()) 'artifact hash'
            Assert-Equal $artifact.size (Get-Item -LiteralPath $artifactPath).Length 'artifact size'
            Assert-True (-not [string]::IsNullOrWhiteSpace($artifact.media_type)) 'artifact media type'
        }
    }
    Assert-True ($withResult.session.id -ne $withoutResult.session.id) 'paired arms must have distinct session ids'
    Assert-True ($withResult.run.configuration -ne $withoutResult.run.configuration) 'paired arms must retain distinct configurations'

    $withPromptEvidence = Get-Content (Join-Path $with.Root 'evidence\prompt-delivery.json') -Raw | ConvertFrom-Json
    $withoutPromptEvidence = Get-Content (Join-Path $without.Root 'evidence\prompt-delivery.json') -Raw | ConvertFrom-Json
    foreach ($pair in @(
            [pscustomobject]@{ Run = $with; Evidence = $withPromptEvidence; Result = $withResult }
            [pscustomobject]@{ Run = $without; Evidence = $withoutPromptEvidence; Result = $withoutResult }
        )) {
        $promptBytes = [System.IO.File]::ReadAllBytes((Join-Path $pair.Run.Root 'prompt.md'))
        Assert-Equal (Get-Sha256HexFromBytes -Bytes $promptBytes) $pair.Evidence.first_task_input_sha256 'prompt must be the first task input byte-for-byte'
        Assert-Equal $promptBytes.Length $pair.Evidence.first_task_input_bytes 'prompt byte length'
        Assert-True $pair.Evidence.byte_exact 'prompt fidelity evidence'
        Assert-Equal (Join-Path $pair.Run.Root 'repo') $pair.Evidence.working_directory 'working directory'
        Assert-Equal (Join-Path $pair.Run.Root 'home') $pair.Evidence.home_directory 'isolated home'
        Assert-True (-not $pair.Evidence.global_rules_visible -and -not $pair.Evidence.global_memory_visible -and -not $pair.Evidence.global_plugins_visible -and -not $pair.Evidence.global_same_name_skill_visible) 'seeded ambient rules/memory/plugins/skill must remain invisible'
    }
    Assert-True $withPromptEvidence.candidate_skill_exposed 'candidate skill is exposed only for with_skill'
    Assert-True (-not $withoutPromptEvidence.candidate_skill_exposed) 'candidate skill is excluded for without_skill'
    Assert-True (Test-Path -LiteralPath (Join-Path $with.Root 'skill\candidate\SKILL.md')) 'with_skill has staged skill'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $without.Root 'skill'))) 'without_skill has no staged skill'

    $escape = Invoke-Fake -FakePath $fakePath -Command execute -Run $with.Path -Profile $profilePath -Scenario escape
    $escapeEvidence = Get-Content (Join-Path $with.Root 'evidence\boundary-probes.json') -Raw | ConvertFrom-Json
    Assert-True $escapeEvidence.read_outside_run.attempted 'read escape probe was exercised'
    Assert-True $escapeEvidence.read_outside_run.blocked 'read escape probe was blocked'
    Assert-True $escapeEvidence.write_outside_run.attempted 'write escape probe was exercised'
    Assert-True $escapeEvidence.write_outside_run.blocked 'write escape probe was blocked'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $testRoot 'escape-write.txt'))) 'escape write did not create a file'

    $refusal = Invoke-Fake -FakePath $fakePath -Command execute -Run $without.Path -Profile $profilePath -Scenario refusal
    Assert-Equal 'completed' $refusal.status 'refusal is a completed captured response'
    Assert-True $refusal.final_response.text.Contains('cannot') 'refusal response is retained'
    $timeout = Invoke-Fake -FakePath $fakePath -Command execute -Run $without.Path -Profile $profilePath -Scenario timeout
    Assert-Equal 'timed_out' $timeout.status 'timeout normalization'
    Assert-Equal 'unavailable' $timeout.final_response.status 'timeout has no final response'
    Assert-True ($null -eq $timeout.exit.status) 'timeout exit status is unavailable'
    $failure = Invoke-Fake -FakePath $fakePath -Command execute -Run $without.Path -Profile $profilePath -Scenario failure
    Assert-Equal 'failed' $failure.status 'harness failure normalization'
    Assert-Equal 17 $failure.exit.status 'harness failure exit status'
    $incompatible = Invoke-Fake -FakePath $fakePath -Command execute -Run $without.Path -Profile $profilePath -Scenario incompatible
    Assert-Equal 'incompatible' $incompatible.status 'incompatible normalization'
    $unknown = Invoke-Fake -FakePath $fakePath -Command execute -Run $without.Path -Profile $profilePath -Scenario unknown-event
    Assert-True (@($unknown.warnings | Where-Object { $_ -match 'future\.event\.v99' }).Count -gt 0) 'unknown events produce explicit warnings'

    foreach ($fixture in @('codex-events.jsonl', 'opencode-events.jsonl')) {
        $fixturePath = Join-Path $PSScriptRoot "fixtures\$fixture"
        $parsed = ConvertFrom-JsonLines -Text ([System.IO.File]::ReadAllText($fixturePath, [System.Text.UTF8Encoding]::new($false)))
        Assert-Equal 0 $parsed.Errors.Count "recorded $fixture has valid JSONL"
        Assert-True ($parsed.Events.Count -ge 4) "recorded $fixture has events"
        Assert-True (@($parsed.Events | Where-Object { $_.type -eq 'future.event.v99' }).Count -eq 1) "recorded $fixture includes an unknown event"
    }

    $prepareText = [System.IO.File]::ReadAllText((Join-Path $repoRoot 'scripts\prepare-skill-evals.ps1'), [System.Text.UTF8Encoding]::new($false))
    $reportText = [System.IO.File]::ReadAllText((Join-Path $repoRoot 'scripts\generate-eval-report.ps1'), [System.Text.UTF8Encoding]::new($false))
    Assert-True ($prepareText -notmatch '(?i)codex\s+exec|opencode\s+run') 'portable preparation must not contain harness-specific CLI invocations'
    Assert-True ($reportText -notmatch '(?i)codex\s+exec|opencode\s+run') 'reporting must not contain harness-specific branches'

    $rawPath = Join-Path $iteration 'conformance\results\with-skill.execution-result.json'
    $resultPath = Join-Path $iteration 'conformance\results\with-skill.result.json'
    New-Item -ItemType Directory -Path (Split-Path -Parent $rawPath) -Force | Out-Null
    $bridgeResult = Invoke-Fake -FakePath $fakePath -Command execute -Run $with.Path -Profile $profilePath
    Write-TestJson -Path $rawPath -Value $bridgeResult
    $bridgePath = Join-Path $runnerRoot 'bridge-execution-result.ps1'
    $bridgeOutput = & pwsh -NoProfile -File $bridgePath -Run $with.Path -ExecutionResult $rawPath -Result $resultPath
    if ($LASTEXITCODE -ne 0) { throw "execution-result bridge failed: $([string]::Join(' ', @($bridgeOutput)))" }
    $portable = Get-Content -LiteralPath $resultPath -Raw | ConvertFrom-Json
    Assert-Equal 'codebeltnet/agentic/eval-result/2' $portable.schema 'bridge preserves existing result schema'
    Assert-Equal 'completed' $portable.execution_status 'bridge carries execution status'
    Assert-Equal 'fixture-model' $portable.model 'bridge carries resolved model'
    Assert-Equal 'fixture-provider' $portable.provider 'bridge carries resolved provider'
    Assert-True ($null -eq $portable.total_tokens) 'bridge keeps unavailable total tokens unavailable'
    Assert-Equal 0 $portable.tool_calls 'bridge carries available tool-call count'
    Assert-True $portable.isolation.transcript_captured 'bridge carries transcript availability'
    Assert-True (@($portable.output_files).Count -gt 0) 'bridge carries confined evidence paths'

    Write-Output 'Eval Runner conformance: PASS'
} finally {
    [Environment]::SetEnvironmentVariable('AGENTIC_FAKE_GLOBAL_RULES', $null, 'Process')
    [Environment]::SetEnvironmentVariable('AGENTIC_FAKE_MEMORY', $null, 'Process')
    [Environment]::SetEnvironmentVariable('AGENTIC_FAKE_PLUGINS', $null, 'Process')
    if (Test-Path -LiteralPath $testRoot) { Remove-Item -LiteralPath $testRoot -Recurse -Force }
}
