<#!
.SYNOPSIS
    Deterministic conformance suite for the common Eval Runner protocol.

.DESCRIPTION
    Creates ephemeral packages under the system temp directory, invokes the
    deterministic fake runner and recorded fake CLI processes, and checks the
    contracts and recorded event fixtures. It never invokes a real harness or
    a live model.
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

function Invoke-AdapterJson {
    param(
        [Parameter(Mandatory = $true)][string]$RunnerPath,
        [Parameter(Mandatory = $true)][string]$Command,
        [Parameter(Mandatory = $true)][string]$RunPath,
        [Parameter(Mandatory = $true)][string]$ProfilePath
    )

    $output = & pwsh -NoProfile -File $RunnerPath $Command -Run $RunPath -Profile $ProfilePath
    if ($LASTEXITCODE -ne 0) { throw "Recorded runner '$Command' failed for '$RunnerPath': $([string]::Join(' ', @($output)))" }
    $json = [string]::Join([Environment]::NewLine, @($output))
    if ([string]::IsNullOrWhiteSpace($json)) { throw "Recorded runner '$Command' returned no JSON for '$RunnerPath'." }
    return $json | ConvertFrom-Json
}

function Invoke-RecordedRunnerTests {
    $recordedRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('agentic-recorded-runner-' + [Guid]::NewGuid().ToString('N'))
$recordedOldPath = $env:PATH
$recordedOldOpenAi = $env:OPENAI_API_KEY
$recordedOldCodexHome = $env:CODEX_HOME
$recordedOldGlobalSecret = $env:AGENTIC_GLOBAL_SECRET
$recordedOldProjectDisable = $env:OPENCODE_DISABLE_PROJECT_CONFIG
try {
    $fakeBin = Join-Path $recordedRoot 'bin'
    New-Item -ItemType Directory -Path $fakeBin -Force | Out-Null
    $recordedIteration = Join-Path $recordedRoot 'iteration-1'
    New-Item -ItemType Directory -Path $recordedIteration -Force | Out-Null
    $with = New-TestRun -IterationDirectory $recordedIteration -Configuration with_skill
    $without = New-TestRun -IterationDirectory $recordedIteration -Configuration without_skill
    [System.IO.File]::WriteAllText((Join-Path $with.Root 'repo\opencode.json'), '{"fixture_project_config":true}', [System.Text.UTF8Encoding]::new($false))
    [System.IO.File]::WriteAllText((Join-Path $without.Root 'repo\opencode.json'), '{"fixture_project_config":true}', [System.Text.UTF8Encoding]::new($false))
    $fakeCli = @'
[CmdletBinding()]
param([Parameter(ValueFromRemainingArguments = $true)][string[]]$RemainingArguments)
$harness = [System.IO.Path]::GetFileNameWithoutExtension($MyInvocation.MyCommand.Path)
$logPath = Join-Path (Get-Location).Path ("{0}-fake-cli-log.jsonl" -f $harness)
$arguments = @($RemainingArguments | ForEach-Object { [string]$_ })
$authNames = @('OPENAI_API_KEY', 'ANTHROPIC_API_KEY', 'GOOGLE_API_KEY', 'GEMINI_API_KEY', 'OPENROUTER_API_KEY', 'XAI_API_KEY', 'MISTRAL_API_KEY', 'CLINE_API_KEY')
$authPresent = @($authNames | Where-Object { -not [string]::IsNullOrWhiteSpace([Environment]::GetEnvironmentVariable($_)) })
$record = [ordered]@{
    args = $arguments
    working_directory = (Get-Location).Path
    home = [Environment]::GetEnvironmentVariable('HOME')
    userprofile = [Environment]::GetEnvironmentVariable('USERPROFILE')
    auth_names_present = $authPresent
    unrelated_present = -not [string]::IsNullOrWhiteSpace([Environment]::GetEnvironmentVariable('AGENTIC_GLOBAL_SECRET'))
    disable_project_config_present = -not [string]::IsNullOrWhiteSpace([Environment]::GetEnvironmentVariable('OPENCODE_DISABLE_PROJECT_CONFIG'))
    project_config_visible = Test-Path -LiteralPath (Join-Path (Get-Location).Path 'opencode.json') -PathType Leaf
    stdin_received = $false
}
if ($arguments -contains '--version') {
    $version = switch ($harness) { 'codex' { 'recorded-codex 9.1' } 'opencode' { 'recorded-opencode 9.2' } default { 'recorded-cline 9.3' } }
    [IO.File]::AppendAllText($logPath, (($record | ConvertTo-Json -Compress) + [Environment]::NewLine), [Text.UTF8Encoding]::new($false))
    Write-Output $version
    exit 0
}
if ($arguments -contains '--help') {
    $help = switch ($harness) {
        'codex' { '--ask-for-approval never --ephemeral --ignore-user-config --ignore-rules --json --output-last-message --sandbox --cd --model --config --approve-for-me' }
        'opencode' { '--format --dir --model --auto --pure --continue --session' }
        default { '--json --auto-approve --cwd --config --data-dir --hooks-dir --provider --model --thinking --timeout --retries --id' }
    }
    [IO.File]::AppendAllText($logPath, (($record | ConvertTo-Json -Compress) + [Environment]::NewLine), [Text.UTF8Encoding]::new($false))
    Write-Output $help
    exit 0
}
$stdinText = [Console]::In.ReadToEnd()
$record.stdin_received = -not [string]::IsNullOrEmpty($stdinText)
$probeCommand = '$result = [ordered]@{ provider_visible = -not [string]::IsNullOrWhiteSpace([Environment]::GetEnvironmentVariable(''OPENAI_API_KEY'')); auth_file_visible = Test-Path -LiteralPath (Join-Path ([Environment]::GetEnvironmentVariable(''HOME'')) ''.codex/auth.json''); global_secret_visible = -not [string]::IsNullOrWhiteSpace([Environment]::GetEnvironmentVariable(''AGENTIC_GLOBAL_SECRET'')); project_disable_visible = -not [string]::IsNullOrWhiteSpace([Environment]::GetEnvironmentVariable(''OPENCODE_DISABLE_PROJECT_CONFIG'')) }; $result | ConvertTo-Json -Compress'
$probeInfo = [Diagnostics.ProcessStartInfo]::new()
$probeInfo.FileName = (Get-Command pwsh).Source
$probeInfo.UseShellExecute = $false
$probeInfo.CreateNoWindow = $true
$probeInfo.RedirectStandardOutput = $true
$probeInfo.RedirectStandardError = $true
$probeInfo.WorkingDirectory = (Get-Location).Path
$probeInfo.ArgumentList.Add('-NoProfile')
$probeInfo.ArgumentList.Add('-Command')
$probeInfo.ArgumentList.Add($probeCommand)
$probeInfo.Environment.Clear()
$probeInfo.Environment['PATH'] = [Environment]::GetEnvironmentVariable('PATH')
$probeInfo.Environment['HOME'] = [Environment]::GetEnvironmentVariable('HOME')
$probeInfo.Environment['USERPROFILE'] = [Environment]::GetEnvironmentVariable('USERPROFILE')
if ($harness -ne 'codex') { $probeInfo.Environment['OPENAI_API_KEY'] = [Environment]::GetEnvironmentVariable('OPENAI_API_KEY') }
$probe = [Diagnostics.Process]::new()
$probe.StartInfo = $probeInfo
try {
    [void]$probe.Start()
    $probeOutput = $probe.StandardOutput.ReadToEnd()
    $probeError = $probe.StandardError.ReadToEnd()
    $probe.WaitForExit()
    if ($probe.ExitCode -ne 0) { throw "worker credential probe failed: $probeError" }
    $probeResult = $probeOutput | ConvertFrom-Json
    $record.worker_provider_visible = [bool]$probeResult.provider_visible
    $record.worker_auth_file_visible = [bool]$probeResult.auth_file_visible
    $record.worker_global_secret_visible = [bool]$probeResult.global_secret_visible
    $record.worker_project_disable_visible = [bool]$probeResult.project_disable_visible
} finally {
    $probe.Dispose()
}
[IO.File]::AppendAllText($logPath, (($record | ConvertTo-Json -Compress) + [Environment]::NewLine), [Text.UTF8Encoding]::new($false))
if ($harness -eq 'codex') {
    $outputIndex = [Array]::IndexOf([string[]]$arguments, '--output-last-message')
    if ($outputIndex -ge 0 -and $outputIndex + 1 -lt $arguments.Count) {
        $outputPath = $arguments[$outputIndex + 1]
        New-Item -ItemType Directory -Path (Split-Path -Parent $outputPath) -Force | Out-Null
        [IO.File]::WriteAllText($outputPath, 'recorded Codex final response', [Text.UTF8Encoding]::new($false))
    }
    Write-Output '{"type":"thread.started","thread_id":"recorded-thread"}'
    Write-Output '{"type":"item.completed","item":{"type":"agent_message","text":"recorded Codex final response"}}'
    Write-Output '{"type":"turn.completed","usage":{"input_tokens":2,"output_tokens":3}}'
    Write-Output '{"type":"future.event.v99","payload":"fixture"}'
} elseif ($harness -eq 'opencode') {
    Write-Output '{"type":"text","text":"recorded OpenCode final response"}'
    Write-Output '{"type":"step_finish","part":{"tokens":{"input":2,"output":3},"cost":0.01}}'
    Write-Output '{"type":"future.event.v99","payload":"fixture"}'
} else {
    Write-Output '{"type":"say","say":"text","text":"recorded Cline progress","partial":false}'
    Write-Output '{"type":"say","say":"tool","name":"read_file","text":"fixture.md","partial":false}'
    Write-Output '{"type":"say","say":"completion_result","text":"recorded Cline final response","partial":false}'
    Write-Output '{"type":"say","say":"api_req_finished","text":"{\"inputTokens\":2,\"outputTokens\":3,\"totalTokens\":5}"}'
    Write-Output '{"type":"future.event.v99","payload":"fixture"}'
}
'@
    foreach ($harness in @('codex', 'opencode', 'cline')) {
        [System.IO.File]::WriteAllText((Join-Path $fakeBin "$harness.ps1"), $fakeCli, [System.Text.UTF8Encoding]::new($false))
    }
    $env:PATH = "$fakeBin$([System.IO.Path]::PathSeparator)$recordedOldPath"
    $env:OPENAI_API_KEY = 'recorded-canary-not-logged'
    $env:AGENTIC_GLOBAL_SECRET = 'recorded-unrelated-canary-not-logged'
    $env:OPENCODE_DISABLE_PROJECT_CONFIG = '1'
    $recordedProfiles = [ordered]@{}
    foreach ($runnerName in @('codex', 'opencode', 'cline')) {
        $profilePath = Join-Path $recordedRoot "$runnerName-profile.json"
        Write-TestJson -Path $profilePath -Value ([ordered]@{
            schema = (Get-RunnerSchemaNames).Profile
            runner = $runnerName
            provider = 'openai'
            model = 'fixture-model'
            reasoning_effort = 'medium'
            configuration_profile = 'isolated-default'
            tool_profile = 'default'
            timeout_seconds = 30
            concurrency = 1
        })
        $recordedProfiles[$runnerName] = $profilePath
    }
    $resolvedRecordedCodex = Resolve-ExternalCommand -Name 'codex'
    Assert-Equal (Join-Path $fakeBin 'codex.ps1') $resolvedRecordedCodex.Source 'recorded Codex command is selected before the installed CLI'
    $recordedVersion = Get-ExternalCommandVersion -CommandInfo $resolvedRecordedCodex -WorkingDirectory (Join-Path $with.Root 'repo')
    if (-not $recordedVersion.Available) { throw "recorded Codex --version is not observable (exit=$($recordedVersion.Process.ExitCode), timed_out=$($recordedVersion.Process.TimedOut), stdout='$($recordedVersion.Process.Stdout)', stderr='$($recordedVersion.Process.Stderr)')" }
    Assert-Equal 'recorded-codex 9.1' $recordedVersion.Version 'recorded Codex exact version helper'
    foreach ($runnerName in @('codex', 'opencode', 'cline')) {
        $runnerPath = Join-Path $runnerRoot "$runnerName\runner.ps1"
        $description = Invoke-AdapterJson -RunnerPath $runnerPath -Command describe -RunPath $with.Path -ProfilePath $recordedProfiles[$runnerName]
        [void](Assert-RunnerDescriptor -Descriptor $description)
        $expectedVersion = switch ($runnerName) { 'codex' { 'recorded-codex 9.1' } 'opencode' { 'recorded-opencode 9.2' } default { 'recorded-cline 9.3' } }
        Assert-Equal $expectedVersion $description.harness.version "$runnerName exact describe version"
        $preflightWith = Invoke-AdapterJson -RunnerPath $runnerPath -Command preflight -RunPath $with.Path -ProfilePath $recordedProfiles[$runnerName]
        $preflightWithout = Invoke-AdapterJson -RunnerPath $runnerPath -Command preflight -RunPath $without.Path -ProfilePath $recordedProfiles[$runnerName]
        Assert-Equal 'compatible' $preflightWith.status "$runnerName with_skill pragmatic preflight"
        Assert-Equal 'compatible' $preflightWithout.status "$runnerName without_skill pragmatic preflight"
        Assert-Equal $expectedVersion $preflightWith.harness.version "$runnerName exact preflight version"
        Assert-Equal 'pragmatic' $preflightWith.isolation.level "$runnerName pragmatic preflight level"
        if ($runnerName -ne 'codex') {
            Assert-True (@($preflightWith.warnings | Where-Object { $_ -match 'child-tool environment filter' }).Count -gt 0) "$runnerName reports the child credential-filter limitation"
        }
        $resultWith = Invoke-AdapterJson -RunnerPath $runnerPath -Command execute -RunPath $with.Path -ProfilePath $recordedProfiles[$runnerName]
        $resultWithout = Invoke-AdapterJson -RunnerPath $runnerPath -Command execute -RunPath $without.Path -ProfilePath $recordedProfiles[$runnerName]
        foreach ($result in @($resultWith, $resultWithout)) {
            [void](Assert-ExecutionResult -Result $result)
            Assert-Equal 'completed' $result.status "$runnerName recorded completion"
            Assert-Equal $expectedVersion $result.harness.version "$runnerName exact execution version"
            Assert-Equal 'accepted_request' $result.resolved.status "$runnerName accepted configuration provenance"
            Assert-True ($null -eq $result.resolved.model) "$runnerName does not claim concrete model resolution"
            Assert-Equal 'pragmatic' $result.isolation.level "$runnerName pragmatic execution level"
            Assert-True (-not $result.isolation.hard_filesystem_confinement) "$runnerName pragmatic execution has no hard confinement"
            Assert-Equal 1 $result.attempt_count "$runnerName one semantic attempt"
            Assert-Equal 'available' $result.final_response.status "$runnerName captures final response"
            $resultRoot = if ($result.run.configuration -eq 'with_skill') { $with.Root } else { $without.Root }
            foreach ($artifact in @($result.artifacts)) {
                Assert-True ($artifact.path -notmatch '(^|/|\\)\.\.(/|\\|$)') "$runnerName artifact path remains relative"
                Assert-True (Test-Path -LiteralPath (Join-Path $resultRoot ($artifact.path -replace '/', [System.IO.Path]::DirectorySeparatorChar)) -PathType Leaf) "$runnerName artifact exists inside its run"
            }
        }
        $logPath = Join-Path $with.Root "repo\$runnerName-fake-cli-log.jsonl"
        Assert-True (Test-Path -LiteralPath $logPath -PathType Leaf) "$runnerName recorded process log exists"
        $records = @(Get-Content -LiteralPath $logPath | ForEach-Object { $_ | ConvertFrom-Json })
        $executionRecords = @($records | Where-Object { $_.stdin_received -eq $true })
        Assert-Equal 1 $executionRecords.Count "$runnerName one execution process per checked arm"
        $execution = $executionRecords[0]
        Assert-True (-not $execution.unrelated_present) "$runnerName does not pass unrelated credential canary"
        Assert-True (-not $execution.disable_project_config_present) "$runnerName does not pass ambient project-disable override"
        Assert-True (-not $execution.worker_auth_file_visible) "$runnerName worker probe cannot read a copied Codex auth file"
        Assert-True (-not $execution.worker_global_secret_visible) "$runnerName worker probe cannot read the parent/global canary"
        Assert-True (-not $execution.worker_project_disable_visible) "$runnerName worker probe cannot read the parent project-disable variable"
        if ($runnerName -eq 'codex') {
            Assert-True (-not $execution.worker_provider_visible) 'Codex shell policy hides the provider API-key variable from the worker probe'
        } else {
            Assert-True $execution.worker_provider_visible "$runnerName credential visibility limitation is recorded by the worker probe"
        }
        $args = @($execution.args)
        foreach ($forbidden in @('--continue', '--session', '--resume')) { Assert-True ($args -notcontains $forbidden) "$runnerName does not pass '$forbidden'" }
        if ($runnerName -eq 'codex') {
            Assert-True ($args -contains '--ask-for-approval') 'Codex uses explicit approval policy'
            Assert-True ($args -contains 'never') 'Codex approval policy is never'
            Assert-True ($args -contains '--sandbox' -and $args -contains 'workspace-write') 'Codex retains workspace-write sandbox'
            Assert-True ($args -notcontains '--approve-for-me') 'Codex avoids the conflicting approve-for-me flag'
            $outputIndex = [Array]::IndexOf([string[]]$args, '--output-last-message')
            Assert-Equal (Join-Path $with.Root 'evidence\codex-final.txt') $args[$outputIndex + 1] 'Codex output path is host-visible on Windows'
        } elseif ($runnerName -eq 'opencode') {
            Assert-True ($args -notcontains '--pure') 'OpenCode preserves repository-owned project configuration'
            Assert-True ($args -contains '--auto') 'OpenCode is noninteractive'
            Assert-True $execution.project_config_visible 'OpenCode paired arm retains repository-owned project configuration'
        } else {
            $retryIndex = [Array]::IndexOf([string[]]$args, '--retries')
            Assert-Equal '0' $args[$retryIndex + 1] 'Cline disables internal retries'
            Assert-True ($args -notcontains '--id') 'Cline does not resume a session'
            Assert-True ($args -contains '--json') 'Cline uses structured output'
            $configIndex = [Array]::IndexOf([string[]]$args, '--config')
            Assert-True ($args[$configIndex + 1] -match '(?i)[\\/]\.cline$') 'Cline uses the documented isolated config root'
            $dataIndex = [Array]::IndexOf([string[]]$args, '--data-dir')
            Assert-True ($args[$dataIndex + 1] -match '(?i)[\\/]\.cline[\\/]data$') 'Cline data-dir is the isolated data root'
            Assert-Equal 'available' $resultWith.telemetry.tool_calls.status 'Cline reports available tool-call telemetry'
            Assert-True ([int]$resultWith.telemetry.tool_calls.value -ge 1) 'Cline parses documented tool events'
        }
        $logText = [System.IO.File]::ReadAllText($logPath, [System.Text.UTF8Encoding]::new($false))
        Assert-True ($logText -notmatch 'recorded-canary|recorded-unrelated-canary') "$runnerName logs do not contain credential values"
        $withoutLogPath = Join-Path $without.Root "repo\$runnerName-fake-cli-log.jsonl"
        Assert-True (Test-Path -LiteralPath $withoutLogPath -PathType Leaf) "$runnerName baseline process log exists"
        $withoutRecords = @(Get-Content -LiteralPath $withoutLogPath | ForEach-Object { $_ | ConvertFrom-Json })
        Assert-Equal 1 @($withoutRecords | Where-Object { $_.stdin_received -eq $true }).Count "$runnerName baseline has one execution process"
        $withoutLogText = [System.IO.File]::ReadAllText($withoutLogPath, [System.Text.UTF8Encoding]::new($false))
        Assert-True ($withoutLogText -notmatch 'recorded-canary|recorded-unrelated-canary') "$runnerName baseline log does not contain credential values"
    }
    $staleCli = $fakeCli.Replace("'opencode' { '--format --dir --model --auto --pure --continue --session' }", "'opencode' { '--format --dir --model --pure --continue --session' }")
    [System.IO.File]::WriteAllText((Join-Path $fakeBin 'opencode.ps1'), $staleCli, [System.Text.UTF8Encoding]::new($false))
    $stalePreflight = Invoke-AdapterJson -RunnerPath (Join-Path $runnerRoot 'opencode\runner.ps1') -Command preflight -RunPath $with.Path -ProfilePath $recordedProfiles['opencode']
    Assert-Equal 'incompatible' $stalePreflight.status 'stale OpenCode help contract is rejected during preflight'
    Assert-True (@($stalePreflight.reasons | Where-Object { $_ -match '--auto' }).Count -gt 0) 'stale OpenCode option failure identifies the missing flag'
    [System.IO.File]::WriteAllText((Join-Path $fakeBin 'opencode.ps1'), $fakeCli, [System.Text.UTF8Encoding]::new($false))
    $fileAuthHome = Join-Path $recordedRoot 'codex-file-auth'
    New-Item -ItemType Directory -Path $fileAuthHome -Force | Out-Null
    [System.IO.File]::WriteAllText((Join-Path $fileAuthHome 'auth.json'), '{"canary":"not-logged"}', [System.Text.UTF8Encoding]::new($false))
    $env:OPENAI_API_KEY = $null
    $env:CODEX_HOME = $fileAuthHome
    $fileAuthPreflight = Invoke-AdapterJson -RunnerPath (Join-Path $runnerRoot 'codex\runner.ps1') -Command preflight -RunPath $with.Path -ProfilePath $recordedProfiles['codex']
    Assert-Equal 'incompatible' $fileAuthPreflight.status 'Codex file-only authentication is fail-closed'
    Assert-True (@($fileAuthPreflight.reasons | Where-Object { $_ -match 'auth\.json' }).Count -gt 0) 'Codex file-auth limitation is explicit'
    $env:OPENAI_API_KEY = 'recorded-canary-not-logged'
    $env:CODEX_HOME = $recordedOldCodexHome
    Write-Output 'Real runner deterministic adapter conformance: PASS'
} finally {
    $env:PATH = $recordedOldPath
    $env:OPENAI_API_KEY = $recordedOldOpenAi
    $env:CODEX_HOME = $recordedOldCodexHome
    $env:AGENTIC_GLOBAL_SECRET = $recordedOldGlobalSecret
    $env:OPENCODE_DISABLE_PROJECT_CONFIG = $recordedOldProjectDisable
    if (Test-Path -LiteralPath $recordedRoot) { Remove-Item -LiteralPath $recordedRoot -Recurse -Force }
}
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

    $resolvedWith = Resolve-RunContract -RunPath $with.Path
    $resolvedProfile = Resolve-ExecutionProfile -ProfilePath $profilePath
    $mandatoryCapabilities = [ordered]@{
        fresh_context = 'supported'
        isolated_home_config = 'supported'
        isolated_working_directory = 'supported'
        ambient_candidate_skill_exclusion = 'supported'
        candidate_skill_exposure = 'supported'
        prompt_fidelity = 'supported'
        model_configuration_lock = 'supported'
        response_capture = 'supported'
    }
    $pragmaticCapabilities = [ordered]@{}
    foreach ($name in $mandatoryCapabilities.Keys) { $pragmaticCapabilities[$name] = $mandatoryCapabilities[$name] }
    $pragmaticCapabilities['filesystem_confinement'] = 'unsupported'
    $strictCapabilities = [ordered]@{}
    foreach ($name in $mandatoryCapabilities.Keys) { $strictCapabilities[$name] = $mandatoryCapabilities[$name] }
    $strictCapabilities['filesystem_confinement'] = 'supported'
    $pragmaticResult = New-ExecutionResult -Descriptor $descriptor -Profile $resolvedProfile -Run $resolvedWith -Status completed -FinalResponse 'pragmatic response' -ExitStatus ([Nullable[int]]0) -IsolationCapabilities $pragmaticCapabilities -AttemptCount 1
    [void](Assert-ExecutionResult -Result $pragmaticResult)
    Assert-Equal 'completed' $pragmaticResult.status 'pragmatic completed result remains usable'
    Assert-Equal 'pragmatic' $pragmaticResult.isolation.level 'missing hard confinement downgrades confidence'
    Assert-True (-not $pragmaticResult.isolation.hard_filesystem_confinement) 'pragmatic result does not claim hard confinement'
    $strictResult = New-ExecutionResult -Descriptor $descriptor -Profile $resolvedProfile -Run $resolvedWith -Status completed -FinalResponse 'strict response' -ExitStatus ([Nullable[int]]0) -IsolationCapabilities $strictCapabilities -AttemptCount 1
    [void](Assert-ExecutionResult -Result $strictResult)
    Assert-Equal 'strict' $strictResult.isolation.level 'proven hard confinement reports strict isolation'
    Assert-True $strictResult.isolation.hard_filesystem_confinement 'strict result claims hard confinement'
    $failedResult = New-ExecutionResult -Descriptor $descriptor -Profile $resolvedProfile -Run $resolvedWith -Status failed -ExitStatus ([Nullable[int]]17) -Failure (New-ExecutionFailure -Code 'fixture_failure' -Message 'fixture failure') -IsolationCapabilities $pragmaticCapabilities -AttemptCount 1
    [void](Assert-ExecutionResult -Result $failedResult)
    Assert-Equal 'failed' $failedResult.status 'failed execution keeps proven pragmatic isolation'
    Assert-Equal 'verified' $failedResult.isolation.status 'failed execution retains control verification'
    $timedOutResult = New-ExecutionResult -Descriptor $descriptor -Profile $resolvedProfile -Run $resolvedWith -Status timed_out -IsolationCapabilities $strictCapabilities -AttemptCount 1
    [void](Assert-ExecutionResult -Result $timedOutResult)
    Assert-Equal 'timed_out' $timedOutResult.status 'timed out execution keeps proven strict isolation'
    $missingCapability = [ordered]@{}
    foreach ($name in $mandatoryCapabilities.Keys) { $missingCapability[$name] = $mandatoryCapabilities[$name] }
    $missingCapability.Remove('response_capture')
    $rejectedResult = New-ExecutionResult -Descriptor $descriptor -Profile $resolvedProfile -Run $resolvedWith -Status completed -FinalResponse 'must be rejected' -IsolationCapabilities $missingCapability -AttemptCount 1
    [void](Assert-ExecutionResult -Result $rejectedResult)
    Assert-Equal 'incompatible' $rejectedResult.status 'unproven mandatory control rejects completion'
    Assert-Equal 'unverified' $rejectedResult.isolation.status 'rejected completion is unverified'
    Assert-Equal 'unsupported' $rejectedResult.isolation.level 'rejected completion has unsupported isolation'
    $preflightRejected = New-ExecutionResult -Descriptor $descriptor -Profile $resolvedProfile -Run $resolvedWith -Status incompatible -FinalResponseReason 'preflight_incompatible' -IsolationCapabilities ([ordered]@{}) -AttemptCount 1
    [void](Assert-ExecutionResult -Result $preflightRejected)
    Assert-Equal 'unverified' $preflightRejected.isolation.status 'preflight incompatibility is unverified'
    Assert-Equal 'unsupported' $preflightRejected.isolation.level 'preflight incompatibility is unsupported'
    $translated = Get-SandboxVisiblePath -HostPath (Join-Path $with.Root 'repo\file.txt') -RunRoot $with.Root -Platform 'linux'
    Assert-Equal '/run/repo/file.txt' $translated 'Linux hard sandbox paths use the child namespace'
    $macPath = Get-SandboxVisiblePath -HostPath (Join-Path $with.Root 'repo\file.txt') -RunRoot $with.Root -Platform 'macos'
    Assert-Equal ([System.IO.Path]::GetFullPath((Join-Path $with.Root 'repo\file.txt'))) $macPath 'macOS sandbox paths remain host-visible'
    Assert-Equal 'recorded-cli 1.2.3' (Get-ObservableVersionFromText "`nrecorded-cli 1.2.3`n") 'observable version capture keeps the exact line'
    Assert-True ($null -eq (Get-ObservableVersionFromText "`n `n")) 'empty version output has no observable value'

    foreach ($fixture in @('codex-events.jsonl', 'opencode-events.jsonl')) {
        $fixturePath = Join-Path $PSScriptRoot "fixtures\$fixture"
        $parsed = ConvertFrom-JsonLines -Text ([System.IO.File]::ReadAllText($fixturePath, [System.Text.UTF8Encoding]::new($false)))
        Assert-Equal 0 $parsed.Errors.Count "recorded $fixture has valid JSONL"
        Assert-True ($parsed.Events.Count -ge 4) "recorded $fixture has events"
        Assert-True (@($parsed.Events | Where-Object { $_.type -eq 'future.event.v99' }).Count -eq 1) "recorded $fixture includes an unknown event"
    }
    $clineFixture = ConvertFrom-JsonLines -Text ([System.IO.File]::ReadAllText((Join-Path $PSScriptRoot 'fixtures\cline-events.jsonl'), [System.Text.UTF8Encoding]::new($false)))
    Assert-Equal 0 $clineFixture.Errors.Count 'recorded cline fixture has valid JSONL'
    Assert-True ($clineFixture.Events.Count -ge 9) 'recorded cline fixture has events'
    Assert-True (@($clineFixture.Events | Where-Object { $_.type -eq 'say' -and $_.say -eq 'tool' }).Count -eq 1) 'recorded cline fixture includes documented tool output'
    Assert-True (@($clineFixture.Events | Where-Object { $_.type -eq 'say' -and $_.say -eq 'completion_result' }).Count -eq 1) 'recorded cline fixture includes documented completion_result output'
    Assert-True (@($clineFixture.Events | Where-Object { $_.type -eq 'future.event.v99' }).Count -eq 1) 'recorded cline fixture includes an unknown event'

    $prepareText = [System.IO.File]::ReadAllText((Join-Path $repoRoot 'scripts\prepare-skill-evals.ps1'), [System.Text.UTF8Encoding]::new($false))
    $reportText = [System.IO.File]::ReadAllText((Join-Path $repoRoot 'scripts\generate-eval-report.ps1'), [System.Text.UTF8Encoding]::new($false))
    Assert-True ($prepareText -notmatch '(?i)codex\s+exec|opencode\s+run|cline\s+--') 'portable preparation must not contain harness-specific CLI invocations'
    Assert-True ($reportText -notmatch '(?i)codex\s+exec|opencode\s+run|cline\s+--') 'reporting must not contain harness-specific branches'

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
    Assert-Equal 'strict' $portable.isolation.level 'bridge carries isolation confidence level'
    Assert-Equal 'verified' $portable.isolation.status 'bridge carries isolation verification status'
    Assert-True (@($portable.isolation.mechanisms).Count -gt 0) 'bridge carries isolation mechanisms'
    Assert-True (@($portable.output_files).Count -gt 0) 'bridge carries confined evidence paths'

    $acceptedBridgeResult = $bridgeResult | ConvertTo-Json -Depth 100 | ConvertFrom-Json
    $acceptedBridgeResult.resolved.status = 'accepted_request'
    $acceptedBridgeResult.resolved.provider = $null
    $acceptedBridgeResult.resolved.model = $null
    $acceptedBridgeResult.resolved.reason = 'fixture accepted the requested alias without exposing backend resolution.'
    Write-TestJson -Path $rawPath -Value $acceptedBridgeResult
    $acceptedBridgeOutput = & pwsh -NoProfile -File $bridgePath -Run $with.Path -ExecutionResult $rawPath -Result $resultPath
    if ($LASTEXITCODE -ne 0) { throw "accepted-configuration bridge failed: $([string]::Join(' ', @($acceptedBridgeOutput)))" }
    $acceptedPortable = Get-Content -LiteralPath $resultPath -Raw | ConvertFrom-Json
    Assert-Equal 'fixture-model' $acceptedPortable.model 'bridge keeps requested model compatibility label'
    Assert-Equal 'fixture-model' $acceptedPortable.requested_model 'bridge records requested model separately'
    Assert-True ([string]::IsNullOrWhiteSpace([string]$acceptedPortable.resolved_model)) 'bridge does not invent a resolved model'
    Assert-Equal 'accepted_request' $acceptedPortable.configuration_resolution_status 'bridge carries configuration provenance'
    Assert-True ([string]$acceptedPortable.notes -match 'configuration_resolution=accepted_request') 'bridge notes configuration provenance'

    Write-Output 'Eval Runner conformance: PASS'
} finally {
    [Environment]::SetEnvironmentVariable('AGENTIC_FAKE_GLOBAL_RULES', $null, 'Process')
    [Environment]::SetEnvironmentVariable('AGENTIC_FAKE_MEMORY', $null, 'Process')
    [Environment]::SetEnvironmentVariable('AGENTIC_FAKE_PLUGINS', $null, 'Process')
    if (Test-Path -LiteralPath $testRoot) { Remove-Item -LiteralPath $testRoot -Recurse -Force }
}

Invoke-RecordedRunnerTests
