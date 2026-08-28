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
. (Join-Path $runnerRoot 'manifest-paths.ps1')
. (Join-Path $runnerRoot 'execution-freeze.ps1')

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw "ASSERT: $Message" }
}

function Get-OpenCodeRunnerAst {
    $tokens = $null
    $errors = $null
    $runnerPath = Join-Path $runnerRoot 'opencode\runner.ps1'
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($runnerPath, [ref]$tokens, [ref]$errors)
    if ($errors.Count -gt 0) { throw 'OpenCode runner regression fixture could not parse runner.ps1.' }
    return $ast
}

function Import-OpenCodeRunnerFunctions {
    if ($null -ne (Get-Command Invoke-OpenCodeHttpRequest -CommandType Function -ErrorAction SilentlyContinue)) { return }

    $ast = Get-OpenCodeRunnerAst
    $functionAsts = @($ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true) | Sort-Object { $_.Extent.StartOffset })
    foreach ($functionAst in $functionAsts) {
        $definition = [regex]::Replace($functionAst.Extent.Text, ('(?im)^function\s+' + [regex]::Escape($functionAst.Name) + '\b'), ('function script:' + $functionAst.Name), 1)
        Invoke-Expression $definition
    }
}

function New-TestChildEnvironment {
    param([Parameter(Mandatory = $true)][string]$HomePath)

    $environment = [ordered]@{}
    foreach ($variable in @(Get-ChildItem Env:)) { $environment[$variable.Name] = [string]$variable.Value }
    $homeFullPath = [System.IO.Path]::GetFullPath($HomePath)
    $homeDrive = [System.IO.Path]::GetPathRoot($homeFullPath).TrimEnd('\')
    $homePathPart = $homeFullPath.Substring($homeDrive.Length)
    $environment['HOME'] = $homeFullPath
    $environment['USERPROFILE'] = $homeFullPath
    $environment['HOMEDRIVE'] = $homeDrive
    $environment['HOMEPATH'] = if ([string]::IsNullOrWhiteSpace($homePathPart)) { '\' } else { $homePathPart }
    $environment['APPDATA'] = Join-Path $homeFullPath 'appdata'
    $environment['LOCALAPPDATA'] = Join-Path $homeFullPath 'localappdata'
    $environment['XDG_CONFIG_HOME'] = Join-Path $homeFullPath '.config'
    $environment['XDG_DATA_HOME'] = Join-Path $homeFullPath '.local\share'
    $environment['XDG_CACHE_HOME'] = Join-Path $homeFullPath '.cache'
    foreach ($directory in @($environment['APPDATA'], $environment['LOCALAPPDATA'], $environment['XDG_CONFIG_HOME'], $environment['XDG_DATA_HOME'], $environment['XDG_CACHE_HOME'])) {
        New-Item -ItemType Directory -Path $directory -Force | Out-Null
    }
    return $environment
}

function Invoke-GeneratedRunnerPrompt {
    $preparePath = Join-Path $repoRoot 'scripts\prepare-skill-evals.ps1'
    $tokens = $null
    $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($preparePath, [ref]$tokens, [ref]$errors)
    if ($errors.Count -gt 0) { throw 'Generated handoff regression could not parse prepare-skill-evals.ps1.' }
    $functionAst = @($ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'New-RunnerPrompt' }, $true) | Select-Object -First 1)
    if ($functionAst.Count -ne 1) { throw 'Generated handoff function New-RunnerPrompt was not found.' }
    $evalRunnerToolRelativePath = 'tools/eval-runners'
    Invoke-Expression $functionAst[0].Extent.Text
    $selection = [pscustomobject]@{ Harness = 'OpenCode CLI'; Runner = 'opencode'; Model = 'opencode/muse-spark-1.2-contributor-free'; Preset = '' }
    $generatedRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('agentic-generated-handoff-' + [Guid]::NewGuid().ToString('N'))
    try {
        $metadataPath = Join-Path $generatedRoot 'eval-01\eval-metadata.json'
        Write-TestJson -Path $metadataPath -Value ([ordered]@{
            interaction = [ordered]@{ turns = @(
                [ordered]@{ role = 'user'; content = 'first' }
                [ordered]@{ role = 'user'; content = 'second' }
            ) }
        })
        $manifestEval = [pscustomobject]@{ metadata = 'eval-01/eval-metadata.json' }
        return New-RunnerPrompt -IterationDirectory $generatedRoot -IterationNumber 1 -ManifestEvals @($manifestEval) -ExecutionSelection $selection -RequestedConcurrency 2 -PerArmTimeoutSeconds 7 -RunnerGraceSeconds 3
    } finally {
        if (Test-Path -LiteralPath $generatedRoot) { Remove-Item -LiteralPath $generatedRoot -Recurse -Force -ErrorAction SilentlyContinue }
    }
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

function Invoke-OpenCodeHttpTimeoutRegression {
    param([Parameter(Mandatory = $true)][string]$RecordedRoot)

    Import-OpenCodeRunnerFunctions
    $commandInfo = Resolve-ExternalCommand -Name 'opencode'
    if ($null -eq $commandInfo) { throw 'OpenCode timeout regression requires the recorded opencode fixture on PATH.' }

    $timeoutRoot = Join-Path $RecordedRoot 'opencode-http-timeout'
    New-Item -ItemType Directory -Path $timeoutRoot -Force | Out-Null

    function Invoke-OpenCodeTimeoutScenario {
        param(
            [Parameter(Mandatory = $true)][string]$ScenarioName,
            [Parameter(Mandatory = $true)][string]$DelayMarkerName,
            [Parameter(Mandatory = $true)][int]$DelayMilliseconds,
            [Parameter(Mandatory = $true)][int]$RequestTimeoutSeconds
        )

        $scenarioRoot = Join-Path $timeoutRoot $ScenarioName
        New-Item -ItemType Directory -Path $scenarioRoot -Force | Out-Null
        $scenarioRun = New-TestRun -IterationDirectory $scenarioRoot -Configuration with_skill -EvalName $ScenarioName
        $environment = New-TestChildEnvironment -HomePath (Join-Path $scenarioRun.Root 'home')
        $inputs = [pscustomobject]@{ Run = [pscustomobject]@{ WorkingDirectoryPath = (Join-Path $scenarioRun.Root 'repo') } }
        $delayMarkerPath = Join-Path $scenarioRun.Root ("home\{0}" -f $DelayMarkerName)
        $server = $null
        $startupStarted = [DateTime]::UtcNow
        try {
            $server = Start-OpenCodeServer -CommandInfo $commandInfo -Inputs $inputs -Environment $environment -Platform 'windows' -SandboxInfo $null -ExpectedVersion 'recorded-opencode 9.2' -StartupTimeoutSeconds 1 -StdoutPath (Join-Path $scenarioRun.Root 'evidence\opencode-http-timeout-server-stdout.txt') -StderrPath (Join-Path $scenarioRun.Root 'evidence\opencode-http-timeout-server-stderr.txt')
            $startupDurationSeconds = ([DateTime]::UtcNow - $startupStarted).TotalSeconds
            Assert-Equal ([string][System.Threading.Timeout]::InfiniteTimeSpan) ([string]$server.Client.Timeout) 'OpenCode server HttpClient timeout is infinite so startup timeout is never a hidden global request timeout'
            Assert-True ($startupDurationSeconds -lt 1.0) 'OpenCode fake server starts within the 1-second startup timeout'
            Assert-True ($server.HealthResponse.Succeeded -and -not [bool]$server.HealthResponse.TimedOut) 'OpenCode health probe succeeds within its startup probe budget'
            Assert-True ($server.DocResponse.Succeeded -and -not [bool]$server.DocResponse.TimedOut) 'OpenCode OpenAPI probe succeeds within its document probe budget'

            $createPath = [string]$server.Contract.SessionCreatePath
            $createPath += Get-OpenCodeDirectoryQuery -Operation $server.Contract.SessionCreateOperation -Directory ([string]$inputs.Run.WorkingDirectoryPath)
            $createResponse = Invoke-OpenCodeHttpRequest -Server $server -Method POST -Path $createPath -Body ([ordered]@{ model = [ordered]@{ id = 'muse-spark-1.2-contributor-free'; providerID = 'opencode' } }) -TimeoutSeconds 5
            Assert-True ($createResponse.Succeeded -and -not [bool]$createResponse.TimedOut) 'OpenCode session creation stays under the per-request profile timeout'
            $createdSession = $createResponse.Body | ConvertFrom-Json -Depth 50
            $sessionId = [string]$createdSession.id
            Assert-True ($sessionId -match '^ses') 'OpenCode timeout regression captures an exact session id before turn execution'

            $messagePath = ([string]$server.Contract.SessionMessagePath).Replace('{sessionID}', [Uri]::EscapeDataString($sessionId))
            $messagePath += Get-OpenCodeDirectoryQuery -Operation $server.Contract.SessionMessageOperation -Directory ([string]$inputs.Run.WorkingDirectoryPath)
            $messageBody = [ordered]@{
                model = [ordered]@{ providerID = 'opencode'; modelID = 'muse-spark-1.2-contributor-free' }
                parts = @([ordered]@{ type = 'text'; text = 'delayed timeout regression turn' })
            }

            [System.IO.File]::WriteAllText($delayMarkerPath, [string]$DelayMilliseconds, [System.Text.UTF8Encoding]::new($false))
            $requestStarted = [DateTime]::UtcNow
            $response = Invoke-OpenCodeHttpRequest -Server $server -Method POST -Path $messagePath -Body $messageBody -TimeoutSeconds $RequestTimeoutSeconds
            $requestElapsedSeconds = ([DateTime]::UtcNow - $requestStarted).TotalSeconds
            return [pscustomobject]@{
                Response = $response
                RequestElapsedSeconds = $requestElapsedSeconds
                StartupDurationSeconds = $startupDurationSeconds
            }
        } finally {
            if (Test-Path -LiteralPath $delayMarkerPath -PathType Leaf) { Remove-Item -LiteralPath $delayMarkerPath -Force -ErrorAction SilentlyContinue }
            if ($null -ne $server) { Stop-OpenCodeServer -Server $server }
        }
    }

    $delayedSuccess = Invoke-OpenCodeTimeoutScenario -ScenarioName 'delayed-success' -DelayMarkerName 'opencode-turn-1-response-delay-ms' -DelayMilliseconds 1500 -RequestTimeoutSeconds 5
    Assert-True ($delayedSuccess.Response.Succeeded -and -not [bool]$delayedSuccess.Response.TimedOut) 'OpenCode delayed turn stays alive beyond startup timeout and succeeds before the profile timeout'
    Assert-True ($delayedSuccess.Response.DurationSeconds -ge 1.3 -and $delayedSuccess.Response.DurationSeconds -lt 5.0) 'OpenCode delayed turn duration proves the per-turn request outlives the 1-second startup timeout without hitting a hidden client timeout'

    $responseTimeout = Invoke-OpenCodeTimeoutScenario -ScenarioName 'response-timeout' -DelayMarkerName 'opencode-turn-1-response-delay-ms' -DelayMilliseconds 2200 -RequestTimeoutSeconds 1
    Assert-True ($responseTimeout.Response.TimedOut -and -not [bool]$responseTimeout.Response.Succeeded) 'OpenCode response-task cancellation is classified as TimedOut = true'
    Assert-Equal 'HTTP request exceeded timeout_seconds.' $responseTimeout.Response.Error 'OpenCode response-task timeout preserves the request-timeout classification'
    Assert-True ($responseTimeout.RequestElapsedSeconds -lt 2.0) 'OpenCode response-task timeout returns within a bounded wall-clock interval'

    $bodyTimeout = Invoke-OpenCodeTimeoutScenario -ScenarioName 'body-timeout' -DelayMarkerName 'opencode-turn-1-body-delay-ms' -DelayMilliseconds 2200 -RequestTimeoutSeconds 1
    Assert-True ($bodyTimeout.Response.TimedOut -and -not [bool]$bodyTimeout.Response.Succeeded) 'OpenCode response-body cancellation is classified as TimedOut = true'
    Assert-Equal 'HTTP response body exceeded timeout_seconds.' $bodyTimeout.Response.Error 'OpenCode response-body timeout preserves the body-timeout classification'
    Assert-True ($bodyTimeout.RequestElapsedSeconds -lt 2.5) 'OpenCode response-body timeout returns within a bounded wall-clock interval'
}

function Invoke-RecordedRunnerTests {
    $recordedRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('agentic-recorded-runner-' + [Guid]::NewGuid().ToString('N'))
$recordedOldPath = $env:PATH
$recordedOldOpenAi = $env:OPENAI_API_KEY
$recordedOldCodexHome = $env:CODEX_HOME
$recordedOldGlobalSecret = $env:AGENTIC_GLOBAL_SECRET
$recordedOldProjectDisable = $env:OPENCODE_DISABLE_PROJECT_CONFIG
$recordedOldCopilotToken = $env:COPILOT_GITHUB_TOKEN
$recordedOldGhToken = $env:GH_TOKEN
$recordedOldGithubToken = $env:GITHUB_TOKEN
$recordedOldCopilotHome = $env:COPILOT_HOME
$recordedOldGhConfigDir = $env:GH_CONFIG_DIR
$recordedOldFixtures = $env:AGENTIC_RECORDED_FIXTURES
try {
    $fakeBin = Join-Path $recordedRoot 'bin'
    New-Item -ItemType Directory -Path $fakeBin -Force | Out-Null
    $fakeAmbientUserRoot = Join-Path $fakeBin '.fake-user'
    $fakeAmbientCandidateRoots = @(
        (Join-Path $fakeAmbientUserRoot '.agents\skills\dotnet-strong-name-signing'),
        (Join-Path $fakeAmbientUserRoot '.claude\skills\dotnet-strong-name-signing'),
        (Join-Path $fakeAmbientUserRoot '.config\opencode\skills\dotnet-strong-name-signing')
    )
    foreach ($fakeAmbientCandidateRoot in $fakeAmbientCandidateRoots) {
        New-Item -ItemType Directory -Path $fakeAmbientCandidateRoot -Force | Out-Null
        [System.IO.File]::WriteAllText((Join-Path $fakeAmbientCandidateRoot 'SKILL.md'), 'CODEBELT_OPENCODE_GLOBAL_SKILL_LEAK_CANARY_8F43D1A7`nfake ambient fact: this value is not in the task prompt.', [System.Text.UTF8Encoding]::new($false))
        [System.IO.File]::WriteAllText((Join-Path $fakeAmbientCandidateRoot 'FORMS.md'), 'CODEBELT_OPENCODE_GLOBAL_SKILL_LEAK_CANARY_8F43D1A7`nfake ambient form fact.', [System.Text.UTF8Encoding]::new($false))
    }
    Assert-True (Test-Path -LiteralPath (Join-Path $fakeAmbientUserRoot '.agents\skills\dotnet-strong-name-signing\SKILL.md') -PathType Leaf) 'OpenCode fake .agents ambient candidate fixture exists'
    Assert-True (Test-Path -LiteralPath (Join-Path $fakeAmbientUserRoot '.claude\skills\dotnet-strong-name-signing\FORMS.md') -PathType Leaf) 'OpenCode fake .claude ambient candidate FORMS.md fixture exists'
    Assert-True (Test-Path -LiteralPath (Join-Path $fakeAmbientUserRoot '.config\opencode\skills\dotnet-strong-name-signing\SKILL.md') -PathType Leaf) 'OpenCode fake native global ambient candidate fixture exists'
    # The OpenCode isolation regression deliberately places a candidate skill,
    # FORMS.md, and project instructions in the source-repository ancestry.
    # A logical run under this directory would expose them; a physical
    # projection outside it must not.
    New-Item -ItemType Directory -Path (Join-Path $recordedRoot '.git'), (Join-Path $recordedRoot 'skills\dotnet-strong-name-signing'), (Join-Path $recordedRoot '.github') -Force | Out-Null
    [System.IO.File]::WriteAllText((Join-Path $recordedRoot 'skills\dotnet-strong-name-signing\SKILL.md'), 'CODEBELT_BASELINE_LEAK_CANARY_7C9E4AF2', [System.Text.UTF8Encoding]::new($false))
    [System.IO.File]::WriteAllText((Join-Path $recordedRoot 'skills\dotnet-strong-name-signing\FORMS.md'), 'CODEBELT_BASELINE_FORMS_CANARY_7C9E4AF2', [System.Text.UTF8Encoding]::new($false))
    [System.IO.File]::WriteAllText((Join-Path $recordedRoot 'AGENTS.md'), 'CODEBELT_SOURCE_ANCESTOR_AGENTS_CANARY_7C9E4AF2', [System.Text.UTF8Encoding]::new($false))
    [System.IO.File]::WriteAllText((Join-Path $recordedRoot '.github\copilot-instructions.md'), 'CODEBELT_SOURCE_ANCESTOR_COPILOT_CANARY_7C9E4AF2', [System.Text.UTF8Encoding]::new($false))
    Assert-True (Test-Path -LiteralPath (Join-Path $recordedRoot 'skills\dotnet-strong-name-signing\SKILL.md') -PathType Leaf) 'OpenCode baseline canary source skill fixture exists'
    Assert-True (Test-Path -LiteralPath (Join-Path $recordedRoot 'skills\dotnet-strong-name-signing\FORMS.md') -PathType Leaf) 'OpenCode baseline canary FORMS.md fixture exists'
    $recordedFixtureRoot = (Resolve-Path (Join-Path $PSScriptRoot 'fixtures')).Path
    $env:AGENTIC_RECORDED_FIXTURES = $recordedFixtureRoot
    Copy-Item -LiteralPath $recordedFixtureRoot -Destination (Join-Path $fakeBin 'fixtures') -Recurse -Force
    $recordedIteration = Join-Path $recordedRoot 'iteration-1'
    New-Item -ItemType Directory -Path $recordedIteration -Force | Out-Null
    $with = New-TestRun -IterationDirectory $recordedIteration -Configuration with_skill
    $without = New-TestRun -IterationDirectory $recordedIteration -Configuration without_skill
    [System.IO.File]::WriteAllText((Join-Path $with.Root 'repo\opencode.json'), '{"fixture_project_config":true}', [System.Text.UTF8Encoding]::new($false))
    [System.IO.File]::WriteAllText((Join-Path $without.Root 'repo\opencode.json'), '{"fixture_project_config":true}', [System.Text.UTF8Encoding]::new($false))
    Assert-Equal (Get-TestTreeHash -Root (Join-Path $with.Root 'repo')) (Get-TestTreeHash -Root (Join-Path $without.Root 'repo')) 'OpenCode paired logical fixture repositories remain byte-identical'
    $fakeCli = @'
param([Parameter(ValueFromRemainingArguments = $true)][string[]]$RemainingArguments)
$harness = [System.IO.Path]::GetFileNameWithoutExtension($MyInvocation.MyCommand.Path)
$logPath = Join-Path (Get-Location).Path ("{0}-fake-cli-log.jsonl" -f $harness)
$arguments = @($RemainingArguments | ForEach-Object { [string]$_ })
$serverMode = $harness -eq 'opencode' -and $arguments -contains 'serve' -and $arguments -notcontains '--help'
if ($harness -eq 'opencode' -and $arguments -contains 'serve' -and $arguments -contains '--help') {
    [Console]::Out.WriteLine('opencode serve --hostname <host> --port <port>')
    [IO.File]::AppendAllText($logPath, (([ordered]@{ invocation_kind = 'serve_help_probe'; args = $arguments } | ConvertTo-Json -Compress) + [Environment]::NewLine), [Text.UTF8Encoding]::new($false))
    exit 0
}
if ($serverMode) {
    $portIndex = [Array]::IndexOf([string[]]$arguments, '--port')
    $hostnameIndex = [Array]::IndexOf([string[]]$arguments, '--hostname')
    $port = if ($portIndex -ge 0 -and $portIndex + 1 -lt $arguments.Count) { [int]$arguments[$portIndex + 1] } else { 0 }
    $hostname = if ($hostnameIndex -ge 0 -and $hostnameIndex + 1 -lt $arguments.Count) { [string]$arguments[$hostnameIndex + 1] } else { '' }
    $listener = [System.Net.HttpListener]::new()
    $listener.Prefixes.Add("http://$hostname`:$port/")
    $sessionId = 'ses-recorded-opencode-server'
    $messageCount = 0
    $stopRequested = $false
    $fakeHome = [Environment]::GetEnvironmentVariable('HOME')
    $noSessionFirst = -not [string]::IsNullOrWhiteSpace($fakeHome) -and (Test-Path -LiteralPath (Join-Path $fakeHome 'scripted-no-session-first') -PathType Leaf)
    $mismatchSession = -not [string]::IsNullOrWhiteSpace($fakeHome) -and (Test-Path -LiteralPath (Join-Path $fakeHome 'scripted-session-mismatch') -PathType Leaf)
    $noTerminalFirst = -not [string]::IsNullOrWhiteSpace($fakeHome) -and (Test-Path -LiteralPath (Join-Path $fakeHome 'scripted-no-terminal-first') -PathType Leaf)
    function Get-DelayFromHome {
        param([Parameter(Mandatory = $true)][string]$Name)

        if ([string]::IsNullOrWhiteSpace($fakeHome)) { return 0 }
        $path = Join-Path $fakeHome $Name
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return 0 }
        $raw = [IO.File]::ReadAllText($path, [Text.UTF8Encoding]::new($false)).Trim()
        $value = 0
        if (-not [int]::TryParse($raw, [ref]$value)) { throw "Invalid fake delay marker '$Name': '$raw'" }
        return [Math]::Max(0, $value)
    }
    $assistantSchema = [ordered]@{ type = 'object'; properties = [ordered]@{ id = [ordered]@{ type = 'string'; pattern = '^msg' }; sessionID = [ordered]@{ type = 'string'; pattern = '^ses' }; role = [ordered]@{ type = 'string'; enum = @('assistant') }; time = [ordered]@{ type = 'object' }; parentID = [ordered]@{ type = 'string' }; modelID = [ordered]@{ type = 'string' }; providerID = [ordered]@{ type = 'string' }; mode = [ordered]@{ type = 'string' }; agent = [ordered]@{ type = 'string' }; path = [ordered]@{ type = 'object' }; cost = [ordered]@{ type = 'number' }; tokens = [ordered]@{ type = 'object' } }; required = @('id', 'sessionID', 'role', 'time', 'parentID', 'modelID', 'providerID', 'mode', 'agent', 'path', 'cost', 'tokens'); additionalProperties = $false }
    $openApi = [ordered]@{
        openapi = '3.0.0'
        info = [ordered]@{ title = 'recorded-opencode'; version = '1.0.0' }
        paths = [ordered]@{
            '/global/health' = [ordered]@{ get = [ordered]@{ operationId = 'global.health'; responses = [ordered]@{ '200' = [ordered]@{ content = [ordered]@{ 'application/json' = [ordered]@{ schema = [ordered]@{ type = 'object' } } } } } } }
            '/session' = [ordered]@{ post = [ordered]@{ operationId = 'session.create'; parameters = @([ordered]@{ name = 'directory'; in = 'query'; required = $false; schema = [ordered]@{ type = 'string' } }); requestBody = [ordered]@{ content = [ordered]@{ 'application/json' = [ordered]@{ schema = [ordered]@{ type = 'object'; properties = [ordered]@{ model = [ordered]@{ type = 'object'; properties = [ordered]@{ id = [ordered]@{ type = 'string' }; providerID = [ordered]@{ type = 'string' } }; required = @('id', 'providerID') } }; additionalProperties = $false } } } }; responses = [ordered]@{ '200' = [ordered]@{ content = [ordered]@{ 'application/json' = [ordered]@{ schema = [ordered]@{ '$ref' = '#/components/schemas/Session' } } } } } } }
            '/session/{sessionID}/message' = [ordered]@{ post = [ordered]@{ operationId = 'session.prompt'; parameters = @([ordered]@{ name = 'sessionID'; in = 'path'; required = $true; schema = [ordered]@{ type = 'string'; pattern = '^ses' } }, [ordered]@{ name = 'directory'; in = 'query'; required = $false; schema = [ordered]@{ type = 'string' } }); requestBody = [ordered]@{ content = [ordered]@{ 'application/json' = [ordered]@{ schema = [ordered]@{ type = 'object'; properties = [ordered]@{ model = [ordered]@{ type = 'object'; properties = [ordered]@{ providerID = [ordered]@{ type = 'string' }; modelID = [ordered]@{ type = 'string' } }; required = @('providerID', 'modelID') }; parts = [ordered]@{ type = 'array'; items = [ordered]@{ anyOf = @([ordered]@{ '$ref' = '#/components/schemas/TextPartInput' }) } } }; required = @('parts'); additionalProperties = $false } } } }; responses = [ordered]@{ '200' = [ordered]@{ content = [ordered]@{ 'application/json' = [ordered]@{ schema = [ordered]@{ type = 'object'; properties = [ordered]@{ info = [ordered]@{ '$ref' = '#/components/schemas/AssistantMessage' }; parts = [ordered]@{ type = 'array' } }; required = @('info', 'parts') } } } } } } }
            '/session/{sessionID}/abort' = [ordered]@{ post = [ordered]@{ operationId = 'session.abort'; responses = [ordered]@{ '204' = [ordered]@{} } } }
            '/instance/dispose' = [ordered]@{ post = [ordered]@{ operationId = 'instance.dispose'; responses = [ordered]@{ '200' = [ordered]@{ content = [ordered]@{ 'application/json' = [ordered]@{ schema = [ordered]@{ type = 'boolean' } } } } } } }
        }
        components = [ordered]@{ schemas = [ordered]@{
            Session = [ordered]@{ type = 'object'; properties = [ordered]@{ id = [ordered]@{ type = 'string'; pattern = '^ses' }; slug = [ordered]@{ type = 'string' }; projectID = [ordered]@{ type = 'string' }; directory = [ordered]@{ type = 'string' }; title = [ordered]@{ type = 'string' }; version = [ordered]@{ type = 'string' }; time = [ordered]@{ type = 'object' } }; required = @('id', 'slug', 'projectID', 'directory', 'title', 'version', 'time') }
            AssistantMessage = $assistantSchema
            TextPartInput = [ordered]@{ type = 'object'; properties = [ordered]@{ type = [ordered]@{ type = 'string'; enum = @('text') }; text = [ordered]@{ type = 'string' } }; required = @('type', 'text') }
        } }
    }
    function Write-ServerJson {
        param(
            [Parameter(Mandatory = $true)][object]$Value,
            [int]$StatusCode = 200,
            [int]$ResponseDelayMilliseconds = 0,
            [int]$BodyDelayMilliseconds = 0
        )

        if ($ResponseDelayMilliseconds -gt 0) { Start-Sleep -Milliseconds $ResponseDelayMilliseconds }
        $json = $Value | ConvertTo-Json -Depth 100 -Compress
        $bytes = [Text.UTF8Encoding]::new($false).GetBytes($json)
        $context.Response.StatusCode = $StatusCode
        $context.Response.ContentType = 'application/json'
        $context.Response.ContentLength64 = $bytes.Length
        if ($BodyDelayMilliseconds -gt 0 -and $bytes.Length -gt 1) {
            $context.Response.OutputStream.Write($bytes, 0, 1)
            $context.Response.OutputStream.Flush()
            Start-Sleep -Milliseconds $BodyDelayMilliseconds
            $context.Response.OutputStream.Write($bytes, 1, $bytes.Length - 1)
            $context.Response.Close()
            return
        }
        $context.Response.OutputStream.Write($bytes, 0, $bytes.Length)
        $context.Response.Close()
    }
    try {
        $listener.Start()
        [IO.File]::AppendAllText($logPath, (([ordered]@{ invocation_kind = 'server_start'; hostname = $hostname; port = $port; server_arguments = $arguments } | ConvertTo-Json -Compress) + [Environment]::NewLine), [Text.UTF8Encoding]::new($false))
        while (-not $stopRequested) {
            $context = $listener.GetContext()
            $path = $context.Request.Url.AbsolutePath
            $method = $context.Request.HttpMethod
            $requestText = ''
            if ($context.Request.HasEntityBody) { $requestText = [IO.StreamReader]::new($context.Request.InputStream).ReadToEnd() }
            if ($method -eq 'GET' -and $path -eq '/global/health') {
                Write-ServerJson -Value ([ordered]@{ healthy = $true; version = 'recorded-opencode 9.2' })
            } elseif ($method -eq 'GET' -and $path -eq '/doc') {
                Write-ServerJson -Value $openApi
            } elseif ($method -eq 'POST' -and $path -eq '/session') {
                $requested = if ([string]::IsNullOrWhiteSpace($requestText)) { [ordered]@{} } else { $requestText | ConvertFrom-Json -Depth 50 }
                $requestedModel = $requested.model
                $createdSessionId = if ($noSessionFirst) { '' } else { $sessionId }
                Write-ServerJson -Value ([ordered]@{ id = $createdSessionId; slug = 'recorded'; projectID = 'recorded-project'; directory = (Get-Location).Path; title = 'recorded'; version = '1.0.0'; time = [ordered]@{ created = 1; updated = 1 }; model = [ordered]@{ id = [string]$requestedModel.id; providerID = [string]$requestedModel.providerID } }) -ResponseDelayMilliseconds (Get-DelayFromHome -Name 'opencode-session-create-response-delay-ms') -BodyDelayMilliseconds (Get-DelayFromHome -Name 'opencode-session-create-body-delay-ms')
            } elseif ($method -eq 'POST' -and $path -match '^/session/([^/]+)/message$') {
                $messageCount++
                $requested = $requestText | ConvertFrom-Json -Depth 50
                if ($messageCount -eq 1) {
                    New-Item -ItemType Directory -Path (Join-Path (Get-Location).Path '.opencode\node_modules') -Force | Out-Null
                    [IO.File]::WriteAllText((Join-Path (Get-Location).Path '.opencode\node_modules\runtime-only.txt'), 'runtime', [Text.UTF8Encoding]::new($false))
                    [IO.File]::WriteAllText((Join-Path (Get-Location).Path '.opencode\.gitignore'), 'runtime', [Text.UTF8Encoding]::new($false))
                    [IO.File]::WriteAllText((Join-Path (Get-Location).Path 'normal-task-output.snk'), 'task-output', [Text.UTF8Encoding]::new($false))
                }
                $requestedPartText = [string]$requested.parts[0].text
                $responseDelayMilliseconds = Get-DelayFromHome -Name ("opencode-turn-{0}-response-delay-ms" -f $messageCount)
                $bodyDelayMilliseconds = Get-DelayFromHome -Name ("opencode-turn-{0}-body-delay-ms" -f $messageCount)
                [IO.File]::AppendAllText($logPath, (([ordered]@{ invocation_kind = 'server_message'; message_number = $messageCount; path = $path; request_text = $requestedPartText; request_model = $requested.model; session_id = $Matches[1]; response_delay_milliseconds = $responseDelayMilliseconds; body_delay_milliseconds = $bodyDelayMilliseconds } | ConvertTo-Json -Depth 50 -Compress) + [Environment]::NewLine), [Text.UTF8Encoding]::new($false))
                $responseSessionId = if ($mismatchSession -and $messageCount -eq 1) { 'ses-recorded-opencode-mismatch' } else { $sessionId }
                $responseParts = if ($noTerminalFirst -and $messageCount -eq 1) { @() } else { @([ordered]@{ type = 'text'; text = "recorded synchronous turn ${messageCount}: $requestedPartText" }) }
                Write-ServerJson -Value ([ordered]@{ info = [ordered]@{ id = "msg-recorded-$messageCount"; sessionID = $responseSessionId; role = 'assistant'; time = [ordered]@{ created = $messageCount; completed = $messageCount }; parentID = "msg-parent-$messageCount"; modelID = [string]$requested.model.modelID; providerID = [string]$requested.model.providerID; mode = 'build'; agent = 'build'; path = [ordered]@{ cwd = (Get-Location).Path; root = (Get-Location).Path }; cost = 0; tokens = [ordered]@{ input = 2; output = 3; reasoning = 0; cache = [ordered]@{ read = 0; write = 0 } } }; parts = $responseParts }) -ResponseDelayMilliseconds $responseDelayMilliseconds -BodyDelayMilliseconds $bodyDelayMilliseconds
            } elseif ($method -eq 'POST' -and $path -eq '/instance/dispose') {
                Write-ServerJson -Value $true
                $stopRequested = $true
            } elseif (($method -eq 'GET' -and $path -eq '/session/status') -or [string]$context.Request.Headers['Accept'] -match '(?i)text/event-stream') {
                # Deliberately never return from the legacy idle/SSE surface.
                # The selected synchronous transport must complete without
                # touching either endpoint; an accidental dependency times out
                # and fails the execution instead of masking a hang.
                Start-Sleep -Seconds 60
            } else {
                Write-ServerJson -Value ([ordered]@{ error = 'not found' }) -StatusCode 404
            }
        }
    } finally {
        try { $listener.Stop() } catch { }
        try { $listener.Close() } catch { }
    }
    exit 0
}
$fixtureRoot = [Environment]::GetEnvironmentVariable('AGENTIC_RECORDED_FIXTURES')
if ([string]::IsNullOrWhiteSpace($fixtureRoot)) { $fixtureRoot = Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) 'fixtures' }
$fixtureHome = [Environment]::GetEnvironmentVariable('HOME')
$fakeAmbientUserRoot = Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) '.fake-user'
function Test-FixtureMarker {
    param([Parameter(Mandatory = $true)][string]$Name)
    if ([string]::IsNullOrWhiteSpace($fixtureHome)) { return $false }
    return Test-Path -LiteralPath (Join-Path $fixtureHome $Name) -PathType Leaf
}
$scriptedFixture = Test-FixtureMarker -Name 'scripted-session-fixture'
$exactSessionHelpFixture = Test-FixtureMarker -Name ("{0}-exact-session-help" -f $harness)
$noExactSessionHelpFixture = Test-FixtureMarker -Name ("{0}-no-exact-session-help" -f $harness)
$timingFixture = Test-FixtureMarker -Name ("{0}-timing-fixture" -f $harness)
$fakeHomeFixture = Test-FixtureMarker -Name 'opencode-fake-home'
$noSessionFirstFixture = Test-FixtureMarker -Name 'scripted-no-session-first'
$noTerminalFirstFixture = Test-FixtureMarker -Name 'scripted-no-terminal-first'
$mismatchSessionFixture = Test-FixtureMarker -Name 'scripted-session-mismatch'
$continuationFlag = $null
foreach ($candidate in @('--resume', '--session-id', '--session')) {
    if ($arguments -contains $candidate -or @($arguments | Where-Object { [string]$_ -like ($candidate + '=*') }).Count -gt 0) {
        $continuationFlag = $candidate
        break
    }
}
$continuationSessionId = $null
if (-not [string]::IsNullOrWhiteSpace([string]$continuationFlag)) {
    $continuationIndex = [Array]::IndexOf([string[]]$arguments, [string]$continuationFlag)
    if ($continuationIndex -ge 0 -and $continuationIndex + 1 -lt $arguments.Count -and $arguments[$continuationIndex + 1] -notmatch '^--') {
        $continuationSessionId = [string]$arguments[$continuationIndex + 1]
    } else {
        $continuationAssignment = @($arguments | Where-Object { $_ -like (([string]$continuationFlag) + '=*') } | Select-Object -First 1)
        if ($continuationAssignment.Count -eq 1) { $continuationSessionId = [string]$continuationAssignment[0].Substring(([string]$continuationFlag).Length + 1) }
    }
}
$authNames = @('OPENAI_API_KEY', 'ANTHROPIC_API_KEY', 'GOOGLE_API_KEY', 'GEMINI_API_KEY', 'OPENROUTER_API_KEY', 'XAI_API_KEY', 'MISTRAL_API_KEY')
$authPresent = @($authNames | Where-Object { -not [string]::IsNullOrWhiteSpace([Environment]::GetEnvironmentVariable($_)) })
$copilotAuthNames = @('COPILOT_GITHUB_TOKEN', 'GH_TOKEN', 'GITHUB_TOKEN')
$copilotAuthPresent = @($copilotAuthNames | Where-Object { -not [string]::IsNullOrWhiteSpace([Environment]::GetEnvironmentVariable($_)) })
$copilotHome = [Environment]::GetEnvironmentVariable('COPILOT_HOME')
$repositoryAgentsPath = Join-Path (Get-Location).Path 'AGENTS.md'
$repositoryCopilotInstructionsPath = Join-Path (Get-Location).Path '.github\copilot-instructions.md'
$candidateSkillPath = if ($harness -eq 'opencode') { Join-Path (Get-Location).Path '.opencode\skills\candidate' } else { Join-Path (Split-Path -Parent (Get-Location).Path) 'skill' }
$sourceAncestorCanaryVisible = $false
$sourceFormsCanaryVisible = $false
$sourceAncestorAgentsVisible = $false
$sourceAncestorCopilotVisible = $false
$stagedCandidateSkillVisible = Test-Path -LiteralPath $candidateSkillPath -PathType Container
$stagedCandidateSkillHash = $null
$candidatePathInArguments = $false
$candidatePathInEnvironment = $false
function Test-CanaryUnder {
    param([Parameter(Mandatory = $true)][string]$Root)

    if (-not (Test-Path -LiteralPath $Root -PathType Container)) { return $false }
    foreach ($file in @(Get-ChildItem -LiteralPath $Root -Recurse -File -Force -ErrorAction SilentlyContinue)) {
        $text = [IO.File]::ReadAllText($file.FullName, [Text.UTF8Encoding]::new($false))
        if ($text -match 'CODEBELT_BASELINE_LEAK_CANARY_|CODEBELT_BASELINE_FORMS_CANARY_|CODEBELT_OPENCODE_GLOBAL_SKILL_LEAK_CANARY_') { return $true }
    }
    return $false
}
$homeRoots = @([Environment]::GetEnvironmentVariable('HOME'), [Environment]::GetEnvironmentVariable('USERPROFILE')) | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } | Select-Object -Unique
$ambientAgentsSkillVisible = @($homeRoots | Where-Object { Test-CanaryUnder -Root (Join-Path ([string]$_) '.agents\skills\dotnet-strong-name-signing') }).Count -gt 0
$ambientClaudeSkillVisible = @($homeRoots | Where-Object { Test-CanaryUnder -Root (Join-Path ([string]$_) '.claude\skills\dotnet-strong-name-signing') }).Count -gt 0
$configRoots = @([Environment]::GetEnvironmentVariable('XDG_CONFIG_HOME')) + @($homeRoots | ForEach-Object { Join-Path ([string]$_) '.config' }) | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } | Select-Object -Unique
$ambientOpenCodeSkillVisible = @($configRoots | Where-Object { Test-CanaryUnder -Root (Join-Path ([string]$_) 'opencode\skills\dotnet-strong-name-signing') }).Count -gt 0
$fakeAmbientCandidateFixtureVisible = Test-CanaryUnder -Root $fakeAmbientUserRoot
$stagedRepoCanaryVisible = Test-CanaryUnder -Root (Get-Location).Path
$homeCanaryVisible = Test-CanaryUnder -Root $fixtureHome
$configRoot = [Environment]::GetEnvironmentVariable('OPENCODE_CONFIG_DIR')
$configCanaryVisible = if ([string]::IsNullOrWhiteSpace($configRoot)) { $false } else { Test-CanaryUnder -Root $configRoot }
$ancestor = [System.IO.Path]::GetFullPath((Get-Location).Path)
while ($true) {
    $ancestorSkillRoot = Join-Path $ancestor 'skills'
    if (Test-Path -LiteralPath $ancestorSkillRoot -PathType Container) {
        foreach ($ancestorSkillFile in @(Get-ChildItem -LiteralPath $ancestorSkillRoot -Recurse -File -Force -ErrorAction SilentlyContinue)) {
            $ancestorSkillText = [IO.File]::ReadAllText($ancestorSkillFile.FullName, [Text.UTF8Encoding]::new($false))
            if ($ancestorSkillText -match 'CODEBELT_BASELINE_LEAK_CANARY_') { $sourceAncestorCanaryVisible = $true }
            if ($ancestorSkillText -match 'CODEBELT_BASELINE_FORMS_CANARY_') { $sourceFormsCanaryVisible = $true }
        }
    }
    $ancestorAgentsPath = Join-Path $ancestor 'AGENTS.md'
    if ((Test-Path -LiteralPath $ancestorAgentsPath -PathType Leaf) -and ([IO.File]::ReadAllText($ancestorAgentsPath, [Text.UTF8Encoding]::new($false)) -match 'CODEBELT_SOURCE_ANCESTOR_AGENTS_CANARY_')) { $sourceAncestorAgentsVisible = $true }
    $ancestorCopilotPath = Join-Path $ancestor '.github\copilot-instructions.md'
    if ((Test-Path -LiteralPath $ancestorCopilotPath -PathType Leaf) -and ([IO.File]::ReadAllText($ancestorCopilotPath, [Text.UTF8Encoding]::new($false)) -match 'CODEBELT_SOURCE_ANCESTOR_COPILOT_CANARY_')) { $sourceAncestorCopilotVisible = $true }
    $parent = Split-Path -Parent $ancestor
    if ([string]::IsNullOrWhiteSpace($parent) -or [string]::Equals($parent, $ancestor, [StringComparison]::OrdinalIgnoreCase)) { break }
    $ancestor = $parent
}
if ($stagedCandidateSkillVisible) {
    $stagedSkillFiles = @(Get-ChildItem -LiteralPath $candidateSkillPath -Recurse -File -Force -ErrorAction SilentlyContinue)
    $stagedCandidateSkillHash = [string]::Join('|', @($stagedSkillFiles | Sort-Object FullName | ForEach-Object { "$( [IO.Path]::GetRelativePath($candidateSkillPath, $_.FullName) ):$( [Convert]::ToHexString(([Security.Cryptography.SHA256]::HashData([IO.File]::ReadAllBytes($_.FullName)))).ToLowerInvariant())" }))
}
$candidatePathInArguments = @($arguments | Where-Object { [string]$_ -match '(?i)CODEBELT_BASELINE_LEAK_CANARY_|CODEBELT_OPENCODE_GLOBAL_SKILL_LEAK_CANARY_|dotnet-strong-name-signing|[\\/]skill[\\/]candidate|[\\/]\.opencode[\\/]skills[\\/]candidate' }).Count -gt 0
$candidatePathInEnvironment = @(Get-ChildItem Env: | Where-Object { [string]$_.Value -match '(?i)CODEBELT_BASELINE_LEAK_CANARY_|CODEBELT_BASELINE_FORMS_CANARY_|CODEBELT_OPENCODE_GLOBAL_SKILL_LEAK_CANARY_|dotnet-strong-name-signing|[\\/]skill[\\/]candidate|[\\/]\.opencode[\\/]skills[\\/]candidate' }).Count -gt 0
$candidateCanaryInEnvironment = @(Get-ChildItem Env: | Where-Object { [string]$_.Value -match '(?i)CODEBELT_OPENCODE_GLOBAL_SKILL_LEAK_CANARY_' }).Count -gt 0
$invocationKind = if ($arguments -contains 'debug' -and $arguments -contains 'config') { 'debug_config_probe' } elseif ($arguments -contains 'debug' -and $arguments -contains 'paths') { 'debug_paths_probe' } elseif ($arguments -contains 'debug' -and $arguments -contains '--help') { 'debug_help_probe' } elseif ($arguments -contains '--version') { 'version_probe' } elseif ($arguments -contains '--help') { 'help_probe' } elseif ($scriptedFixture -and -not [string]::IsNullOrWhiteSpace([string]$continuationSessionId)) { 'explicit_session_resume' } else { 'native_execution' }
$fakeDelayMilliseconds = if (-not $timingFixture) { 0 } else { switch ($invocationKind) { 'version_probe' { 20 } 'help_probe' { 30 } 'explicit_session_resume' { 50 } default { 40 } } }
$repositoryInstructionMarkerVisible = $false
if (Test-Path -LiteralPath $repositoryCopilotInstructionsPath -PathType Leaf) {
    $repositoryInstructionMarkerVisible = [IO.File]::ReadAllText($repositoryCopilotInstructionsPath, [Text.UTF8Encoding]::new($false)).Contains('repo-owned-copilot-instruction')
}
$copilotAuthenticationSource = if ($copilotAuthPresent.Count -gt 0) {
    'explicit_environment'
} elseif (-not [string]::IsNullOrWhiteSpace($copilotHome) -and (Test-Path -LiteralPath (Join-Path $copilotHome 'fixture-os-keychain-available') -PathType Leaf)) {
    'os_keychain'
} elseif (-not [string]::IsNullOrWhiteSpace([Environment]::GetEnvironmentVariable('GH_CONFIG_DIR')) -and (Test-Path -LiteralPath ([Environment]::GetEnvironmentVariable('GH_CONFIG_DIR')) -PathType Container)) {
    'github_cli'
} else {
    'unavailable'
}
$record = [ordered]@{
    args = $arguments
    working_directory = (Get-Location).Path
    home = [Environment]::GetEnvironmentVariable('HOME')
    userprofile = [Environment]::GetEnvironmentVariable('USERPROFILE')
    homedrive = [Environment]::GetEnvironmentVariable('HOMEDRIVE')
    homepath = [Environment]::GetEnvironmentVariable('HOMEPATH')
    appdata = [Environment]::GetEnvironmentVariable('APPDATA')
    local_appdata = [Environment]::GetEnvironmentVariable('LOCALAPPDATA')
    xdg_config_home = [Environment]::GetEnvironmentVariable('XDG_CONFIG_HOME')
    node_path = [Environment]::GetEnvironmentVariable('NODE_PATH')
    config_directory = [Environment]::GetEnvironmentVariable('OPENCODE_CONFIG_DIR')
    config_file = [Environment]::GetEnvironmentVariable('OPENCODE_CONFIG')
    disable_external_skills = [Environment]::GetEnvironmentVariable('OPENCODE_DISABLE_EXTERNAL_SKILLS')
    disable_claude_code_skills = [Environment]::GetEnvironmentVariable('OPENCODE_DISABLE_CLAUDE_CODE_SKILLS')
    node_homedir = $null
    skill_permission = $null
    auth_names_present = $authPresent
    copilot_auth_names_present = $copilotAuthPresent
    copilot_authentication_source = $copilotAuthenticationSource
    unrelated_present = -not [string]::IsNullOrWhiteSpace([Environment]::GetEnvironmentVariable('AGENTIC_GLOBAL_SECRET'))
    disable_project_config_present = -not [string]::IsNullOrWhiteSpace([Environment]::GetEnvironmentVariable('OPENCODE_DISABLE_PROJECT_CONFIG'))
    project_config_visible = Test-Path -LiteralPath (Join-Path (Get-Location).Path 'opencode.json') -PathType Leaf
    stdin_received = $false
    prompt_via_arg = @($arguments | Where-Object { $_ -eq '--prompt' -or $_ -eq '-p' -or $_ -like '--prompt=*' }).Count -gt 0
    prompt_arg_count = @($arguments | Where-Object { $_ -eq '--prompt' -or $_ -eq '-p' -or $_ -like '--prompt=*' }).Count
    copilot_home = $copilotHome
    copilot_cache_home = [Environment]::GetEnvironmentVariable('COPILOT_CACHE_HOME')
    gh_config_dir = [Environment]::GetEnvironmentVariable('GH_CONFIG_DIR')
    fixture_mode = if ($scriptedFixture) { 'scripted' } else { 'single_turn' }
    continuation_flag = $continuationFlag
    continuation_session_id = $continuationSessionId
    custom_instructions_disabled = ($arguments -contains '--no-custom-instructions')
    builtin_mcps_disabled = ($arguments -contains '--disable-builtin-mcps')
    repository_agents_visible = Test-Path -LiteralPath $repositoryAgentsPath -PathType Leaf
    repository_copilot_instructions_visible = Test-Path -LiteralPath $repositoryCopilotInstructionsPath -PathType Leaf
    repository_instruction_marker_visible = $repositoryInstructionMarkerVisible
    candidate_skill_staged = Test-Path -LiteralPath $candidateSkillPath -PathType Container
    source_ancestor_candidate_skill_visible = $sourceAncestorCanaryVisible
    source_ancestor_forms_visible = $sourceFormsCanaryVisible
    source_ancestor_agents_visible = $sourceAncestorAgentsVisible
    source_ancestor_copilot_visible = $sourceAncestorCopilotVisible
    staged_repo_canary_visible = $stagedRepoCanaryVisible
    home_canary_visible = $homeCanaryVisible
    config_canary_visible = $configCanaryVisible
    fake_ambient_candidate_fixture_visible = $fakeAmbientCandidateFixtureVisible
    ambient_agents_skill_visible = $ambientAgentsSkillVisible
    ambient_claude_skill_visible = $ambientClaudeSkillVisible
    ambient_opencode_skill_visible = $ambientOpenCodeSkillVisible
    staged_candidate_skill_visible = $stagedCandidateSkillVisible
    staged_candidate_skill_hash = $stagedCandidateSkillHash
    candidate_skill_path_in_arguments = $candidatePathInArguments
    candidate_skill_path_in_environment = $candidatePathInEnvironment
    candidate_canary_in_environment = $candidateCanaryInEnvironment
    candidate_skill_exposure = if ($stagedCandidateSkillVisible) { 'included' } else { 'excluded' }
    invocation_kind = $invocationKind
    fake_delay_milliseconds = $fakeDelayMilliseconds
    ambient_copilot_instructions_visible = if ([string]::IsNullOrWhiteSpace($copilotHome)) { $false } else { Test-Path -LiteralPath (Join-Path $copilotHome 'copilot-instructions.md') -PathType Leaf }
    secret_env_vars_arg = @($arguments | Where-Object { $_ -like '--secret-env-vars=*' })
}
if ($harness -eq 'opencode') {
    try {
        $nodeHomeOutput = @(& node -p 'require("os").homedir()' 2>$null | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } | Select-Object -First 1)
        if ($nodeHomeOutput.Count -eq 1) { $record.node_homedir = ([string]$nodeHomeOutput[0]).Trim() }
    } catch { }
    if (-not [string]::IsNullOrWhiteSpace([string]$record.config_file) -and (Test-Path -LiteralPath $record.config_file -PathType Leaf)) {
        try {
            $recordedConfig = [IO.File]::ReadAllText($record.config_file, [Text.UTF8Encoding]::new($false)) | ConvertFrom-Json -Depth 50
            $record.skill_permission = $recordedConfig.permission.skill
        } catch { }
    }
}
if ($harness -eq 'codex' -and $arguments -contains 'app-server' -and $arguments -contains 'generate-json-schema') {
    $outArgument = @($arguments | Where-Object { $_ -like '--out=*' } | Select-Object -First 1)
    if ($outArgument.Count -eq 0) { exit 2 }
    $schemaDirectory = [IO.Path]::GetFullPath((Join-Path (Get-Location).Path ([string]$outArgument[0].Substring(6))))
    New-Item -ItemType Directory -Path $schemaDirectory -Force | Out-Null
    foreach ($existingSchemaFile in @(Get-ChildItem -LiteralPath $schemaDirectory -Force -ErrorAction SilentlyContinue)) {
        Remove-Item -LiteralPath $existingSchemaFile.FullName -Recurse -Force
    }
    $schema = 'http://json-schema.org/draft-07/schema#'
    $definitions = [ordered]@{
        AbsolutePathBuf = [ordered]@{ type = 'string' }
        LegacyAppPathString = [ordered]@{ type = 'string' }
        SandboxMode = [ordered]@{ type = 'string'; enum = @('read-only', 'workspace-write', 'danger-full-access') }
        AskForApproval = [ordered]@{ oneOf = @([ordered]@{ type = 'string'; enum = @('untrusted', 'on-request', 'never') }) }
        ReasoningEffort = [ordered]@{ type = 'string'; minLength = 1 }
        ModelRerouteReason = [ordered]@{ type = 'string'; enum = @('highRiskCyberActivity') }
        TurnStatus = [ordered]@{ type = 'string'; enum = @('inProgress', 'completed', 'failed', 'interrupted') }
        UserInput = [ordered]@{ oneOf = @([ordered]@{ type = 'object'; required = @('text', 'type'); properties = [ordered]@{ type = [ordered]@{ type = 'string'; enum = @('text') }; text = [ordered]@{ type = 'string' } } }) }
        SandboxPolicy = [ordered]@{ oneOf = @(
            [ordered]@{ type = 'object'; required = @('type'); properties = [ordered]@{ type = [ordered]@{ type = 'string'; enum = @('dangerFullAccess') } } }
            [ordered]@{ type = 'object'; required = @('type'); properties = [ordered]@{ type = [ordered]@{ type = 'string'; enum = @('readOnly') }; networkAccess = [ordered]@{ type = 'boolean' } } }
            [ordered]@{ type = 'object'; required = @('type'); properties = [ordered]@{ type = [ordered]@{ type = 'string'; enum = @('workspaceWrite') }; writableRoots = [ordered]@{ type = 'array'; items = [ordered]@{ '$ref' = '#/definitions/AbsolutePathBuf' } }; networkAccess = [ordered]@{ type = 'boolean' } } }
        ) }
        Thread = [ordered]@{ type = 'object'; required = @('id', 'cwd', 'ephemeral', 'sessionId', 'turns'); properties = [ordered]@{ id = [ordered]@{ type = 'string' }; cwd = [ordered]@{ allOf = @([ordered]@{ '$ref' = '#/definitions/AbsolutePathBuf' }) }; ephemeral = [ordered]@{ type = 'boolean' }; sessionId = [ordered]@{ type = 'string' }; turns = [ordered]@{ type = 'array' } } }
        Turn = [ordered]@{ type = 'object'; required = @('id', 'items', 'status'); properties = [ordered]@{ id = [ordered]@{ type = 'string' }; items = [ordered]@{ type = 'array' }; status = [ordered]@{ '$ref' = '#/definitions/TurnStatus' } } }
    }
    $definitions.ThreadStartParams = [ordered]@{
        '$schema' = $schema
        title = 'ThreadStartParams'
        type = 'object'
        properties = [ordered]@{
            model = [ordered]@{ type = @('string', 'null') }
            cwd = [ordered]@{ type = @('string', 'null') }
            approvalPolicy = [ordered]@{ anyOf = @([ordered]@{ '$ref' = '#/definitions/AskForApproval' }, [ordered]@{ type = 'null' }) }
            sandbox = [ordered]@{ anyOf = @([ordered]@{ '$ref' = '#/definitions/SandboxMode' }, [ordered]@{ type = 'null' }) }
            ephemeral = [ordered]@{ type = @('boolean', 'null') }
        }
    }
    $definitions.ThreadStartResponse = [ordered]@{
        '$schema' = $schema
        title = 'ThreadStartResponse'
        type = 'object'
        required = @('approvalPolicy', 'approvalsReviewer', 'cwd', 'model', 'modelProvider', 'sandbox', 'thread')
        properties = [ordered]@{
            approvalPolicy = [ordered]@{ '$ref' = '#/definitions/AskForApproval' }
            cwd = [ordered]@{ '$ref' = '#/definitions/AbsolutePathBuf' }
            instructionSources = [ordered]@{ type = 'array'; items = [ordered]@{ '$ref' = '#/definitions/LegacyAppPathString' } }
            model = [ordered]@{ type = 'string' }
            sandbox = [ordered]@{ allOf = @([ordered]@{ '$ref' = '#/definitions/SandboxPolicy' }) }
            thread = [ordered]@{ '$ref' = '#/definitions/Thread' }
        }
    }
    $definitions.TurnStartParams = [ordered]@{
        '$schema' = $schema
        title = 'TurnStartParams'
        type = 'object'
        required = @('input', 'threadId')
        properties = [ordered]@{
            threadId = [ordered]@{ type = 'string' }
            input = [ordered]@{ type = 'array'; items = [ordered]@{ '$ref' = '#/definitions/UserInput' } }
            cwd = [ordered]@{ type = @('string', 'null') }
            model = [ordered]@{ type = @('string', 'null') }
            effort = [ordered]@{ anyOf = @([ordered]@{ '$ref' = '#/definitions/ReasoningEffort' }, [ordered]@{ type = 'null' }) }
            approvalPolicy = [ordered]@{ anyOf = @([ordered]@{ '$ref' = '#/definitions/AskForApproval' }, [ordered]@{ type = 'null' }) }
            sandboxPolicy = [ordered]@{ anyOf = @([ordered]@{ '$ref' = '#/definitions/SandboxPolicy' }, [ordered]@{ type = 'null' }) }
        }
    }
    $definitions.TurnStartResponse = [ordered]@{
        '$schema' = $schema
        title = 'TurnStartResponse'
        type = 'object'
        required = @('turn')
        properties = [ordered]@{ turn = [ordered]@{ '$ref' = '#/definitions/Turn' } }
    }
    $definitions.ThreadReadParams = [ordered]@{
        '$schema' = $schema
        title = 'ThreadReadParams'
        type = 'object'
        required = @('threadId')
        properties = [ordered]@{ threadId = [ordered]@{ type = 'string' }; includeTurns = [ordered]@{ type = 'boolean' } }
    }
    $definitions.ThreadReadResponse = [ordered]@{
        '$schema' = $schema
        title = 'ThreadReadResponse'
        type = 'object'
        required = @('thread')
        properties = [ordered]@{ thread = [ordered]@{ '$ref' = '#/definitions/Thread' } }
    }
    $definitions.ModelReroutedNotification = [ordered]@{
        '$schema' = $schema
        title = 'ModelReroutedNotification'
        type = 'object'
        required = @('fromModel', 'reason', 'threadId', 'toModel', 'turnId')
        properties = [ordered]@{
            fromModel = [ordered]@{ type = 'string' }
            reason = [ordered]@{ '$ref' = '#/definitions/ModelRerouteReason' }
            threadId = [ordered]@{ type = 'string' }
            toModel = [ordered]@{ type = 'string' }
            turnId = [ordered]@{ type = 'string' }
        }
    }
    $fixtureHome = [Environment]::GetEnvironmentVariable('HOME')
    $schemaMode = if (-not [string]::IsNullOrWhiteSpace($fixtureHome) -and (Test-Path -LiteralPath (Join-Path $fixtureHome 'codex-schema-individual-v2') -PathType Leaf)) { 'individual-v2' } else { '' }
    $missingSchema = if (-not [string]::IsNullOrWhiteSpace($fixtureHome) -and (Test-Path -LiteralPath (Join-Path $fixtureHome 'codex-schema-missing-ThreadStartParams') -PathType Leaf)) { 'ThreadStartParams' } else { '' }
    $missingRequiredSchemas = -not [string]::IsNullOrWhiteSpace($fixtureHome) -and (Test-Path -LiteralPath (Join-Path $fixtureHome 'codex-schema-missing-required') -PathType Leaf)
    $withoutThreadRead = -not [string]::IsNullOrWhiteSpace($fixtureHome) -and (Test-Path -LiteralPath (Join-Path $fixtureHome 'codex-schema-without-thread-read') -PathType Leaf)
    if (-not [string]::IsNullOrWhiteSpace($missingSchema)) { [void]$definitions.Remove($missingSchema) }
    if ($missingRequiredSchemas) {
        [void]$definitions.Remove('ThreadStartParams')
        [void]$definitions.Remove('TurnStartResponse')
    }
    if ($withoutThreadRead) {
        [void]$definitions.Remove('ThreadReadParams')
        [void]$definitions.Remove('ThreadReadResponse')
    }
    $schemaFiles = [ordered]@{
        'codex_app_server_protocol.v2.schemas.json' = [ordered]@{ '$schema' = $schema; title = 'codex_app_server_protocol.v2.schemas'; type = 'object'; definitions = $definitions }
    }
    foreach ($schemaName in @('ThreadStartParams', 'ThreadStartResponse', 'TurnStartParams', 'TurnStartResponse', 'ThreadReadParams', 'ThreadReadResponse', 'ModelReroutedNotification')) {
        if ($definitions.Contains($schemaName)) {
            $source = $definitions[$schemaName]
            $individual = [ordered]@{ '$schema' = $schema }
            foreach ($propertyName in @('title', 'type', 'properties', 'required')) {
                if ($source.Contains($propertyName)) { $individual[$propertyName] = $source[$propertyName] }
            }
            $individual.definitions = $definitions
            $schemaFiles[('v2\{0}.json' -f $schemaName)] = $individual
        }
    }
    if ($schemaMode -eq 'individual-v2') { [void]$schemaFiles.Remove('codex_app_server_protocol.v2.schemas.json') }
    foreach ($schemaName in $schemaFiles.Keys) {
        $schemaPath = Join-Path $schemaDirectory $schemaName
        New-Item -ItemType Directory -Path (Split-Path -Parent $schemaPath) -Force | Out-Null
        [IO.File]::WriteAllText($schemaPath, ([string]($schemaFiles[$schemaName] | ConvertTo-Json -Depth 100)), [Text.UTF8Encoding]::new($false))
    }
    [IO.File]::AppendAllText($logPath, (($record | ConvertTo-Json -Compress) + [Environment]::NewLine), [Text.UTF8Encoding]::new($false))
    exit 0
}
if ($harness -eq 'codex' -and $arguments -contains 'app-server' -and $arguments -contains '--help') {
    [IO.File]::AppendAllText($logPath, (($record | ConvertTo-Json -Compress) + [Environment]::NewLine), [Text.UTF8Encoding]::new($false))
    Write-Output 'generate-json-schema'
    exit 0
}
if ($harness -eq 'codex' -and $arguments -contains 'features' -and $arguments -contains 'list') {
    [IO.File]::AppendAllText($logPath, (($record | ConvertTo-Json -Compress) + [Environment]::NewLine), [Text.UTF8Encoding]::new($false))
    Write-Output 'multi_agent stable true'
    exit 0
}
if ($harness -eq 'codex' -and $arguments -contains 'app-server') {
    function Read-AppServerMessage {
        $line = [Console]::In.ReadLine()
        if ($null -eq $line) { throw 'recorded app-server reached EOF before the expected request' }
        return ($line | ConvertFrom-Json -Depth 50)
    }
    function Write-AppServerMessage {
        param([Parameter(Mandatory = $true)][object]$Value)
        [Console]::Out.WriteLine(($Value | ConvertTo-Json -Depth 50 -Compress))
        [Console]::Out.Flush()
    }

    $initialize = Read-AppServerMessage
    Write-AppServerMessage ([ordered]@{ jsonrpc = '2.0'; id = $initialize.id; result = [ordered]@{ serverInfo = [ordered]@{ name = 'recorded-codex'; version = '9.1' } } })
    $initialized = Read-AppServerMessage
    $threadStart = Read-AppServerMessage
    $fixtureReroute = Test-Path -LiteralPath (Join-Path ([Environment]::GetEnvironmentVariable('HOME')) 'codex-reroute') -PathType Leaf
    $fixtureAmbientInstruction = Test-Path -LiteralPath (Join-Path ([Environment]::GetEnvironmentVariable('HOME')) 'codex-ambient-instruction') -PathType Leaf
    $fixtureThreadReadUnavailable = Test-Path -LiteralPath (Join-Path ([Environment]::GetEnvironmentVariable('HOME')) 'codex-thread-read-unavailable') -PathType Leaf
    $instructionSources = if ($fixtureAmbientInstruction) { @('C:\ambient\AGENTS.md') } else { @($repositoryAgentsPath) }
    $threadObject = [ordered]@{
        id = 'recorded-subscription-thread'
        sessionId = 'recorded-subscription-session'
        ephemeral = $true
        cwd = (Get-Location).Path
        cliVersion = '9.1'
        createdAt = 1
        updatedAt = 1
        modelProvider = 'recorded-provider'
        preview = $false
        projectId = $null
        source = 'startup'
        status = [ordered]@{ type = 'idle' }
        turns = @()
    }
    $threadStartResult = [ordered]@{
        approvalPolicy = 'never'
        approvalsReviewer = 'user'
        cwd = (Get-Location).Path
        model = 'gpt-5.6-luna'
        modelProvider = 'recorded-provider'
        sandbox = [ordered]@{ type = 'readOnly' }
        instructionSources = $instructionSources
        thread = $threadObject
    }
    Write-AppServerMessage ([ordered]@{ jsonrpc = '2.0'; id = $threadStart.id; result = $threadStartResult })
    Write-AppServerMessage ([ordered]@{ jsonrpc = '2.0'; method = 'thread/started'; params = [ordered]@{ thread = [ordered]@{ id = 'recorded-subscription-thread' } } })
    $turnStart = Read-AppServerMessage
    if ($fixtureReroute) {
        # This notification deliberately arrives before turn/start's response
        # so the recorded transport proves reroute capture while waiting for a
        # JSON-RPC response, not only in the terminal event loop.
        Write-AppServerMessage ([ordered]@{ jsonrpc = '2.0'; method = 'model/rerouted'; params = [ordered]@{ threadId = 'recorded-subscription-thread'; turnId = 'recorded-subscription-turn'; fromModel = 'gpt-5.6-luna'; toModel = 'gpt-5.6-other'; reason = 'highRiskCyberActivity' } })
    }
    Write-AppServerMessage ([ordered]@{ jsonrpc = '2.0'; id = $turnStart.id; result = [ordered]@{ turn = [ordered]@{ id = 'recorded-subscription-turn'; status = 'inProgress'; items = @() } } })

    $promptText = [string]$turnStart.params.input[0].text
    $promptBytes = [Text.Encoding]::UTF8.GetBytes($promptText)
    $expectedPromptHashPath = Join-Path ([Environment]::GetEnvironmentVariable('HOME')) 'expected-prompt-sha256.txt'
    $expectedPromptHash = if (Test-Path -LiteralPath $expectedPromptHashPath -PathType Leaf) { [IO.File]::ReadAllText($expectedPromptHashPath, [Text.UTF8Encoding]::new($false)).Trim() } else { [Convert]::ToHexString(([Security.Cryptography.SHA256]::HashData([byte[]]$promptBytes))).ToLowerInvariant() }
    $record.stdin_received = $promptBytes.Length -gt 0
    $record.stdin_delivery_count = if ($promptBytes.Length -gt 0) { 1 } else { 0 }
    $record.stdin_byte_length = $promptBytes.Length
    $record.stdin_sha256 = [Convert]::ToHexString(([Security.Cryptography.SHA256]::HashData($promptBytes))).ToLowerInvariant()
    $record.stdin_expected_sha256 = $expectedPromptHash
    $record.stdin_exact = $record.stdin_sha256 -eq $expectedPromptHash
    $record.stdin_utf8_round_trip = $record.stdin_exact
    $record.worker_provider_visible = $false
    $record.worker_copilot_token_visible = $false
    $record.worker_gh_token_visible = $false
    $record.worker_github_token_visible = $false
    $record.worker_auth_file_visible = $false
    $record.worker_global_secret_visible = $false
    $record.worker_project_disable_visible = $false
    $record.parent_codex_home = [Environment]::GetEnvironmentVariable('CODEX_HOME')
    $record.parent_auth_file_visible = Test-Path -LiteralPath (Join-Path $record.parent_codex_home 'auth.json') -PathType Leaf
    $record.parent_config_file_visible = Test-Path -LiteralPath (Join-Path $record.parent_codex_home 'config.toml') -PathType Leaf
    $record.parent_skills_directory_visible = Test-Path -LiteralPath (Join-Path $record.parent_codex_home 'skills') -PathType Container
    $record.parent_agents_directory_visible = Test-Path -LiteralPath (Join-Path $record.parent_codex_home 'agents') -PathType Container
    $record.parent_sessions_directory_visible = Test-Path -LiteralPath (Join-Path $record.parent_codex_home 'sessions') -PathType Container
    $record.parent_memories_directory_visible = Test-Path -LiteralPath (Join-Path $record.parent_codex_home 'memories') -PathType Container
    $record.parent_plugins_directory_visible = Test-Path -LiteralPath (Join-Path $record.parent_codex_home 'plugins') -PathType Container
    $record.parent_mcp_configuration_visible = (Test-Path -LiteralPath (Join-Path $record.parent_codex_home 'mcp.json') -PathType Leaf) -or (Test-Path -LiteralPath (Join-Path $record.parent_codex_home 'mcp') -PathType Container)
    $record.parent_agents_file_visible = Test-Path -LiteralPath (Join-Path $record.parent_codex_home 'AGENTS.md') -PathType Leaf
    $record.auth_only_home = [bool]$record.parent_auth_file_visible -and -not [bool]$record.parent_config_file_visible -and -not [bool]$record.parent_skills_directory_visible -and -not [bool]$record.parent_agents_directory_visible -and -not [bool]$record.parent_sessions_directory_visible -and -not [bool]$record.parent_memories_directory_visible -and -not [bool]$record.parent_plugins_directory_visible -and -not [bool]$record.parent_mcp_configuration_visible -and -not [bool]$record.parent_agents_file_visible
    $record.rpc_methods = @($initialize.method, $initialized.method, $threadStart.method, $turnStart.method, 'thread/read')
    $record.thread_params = $threadStart.params
    $record.turn_params = $turnStart.params
    [IO.File]::AppendAllText($logPath, (($record | ConvertTo-Json -Depth 50 -Compress) + [Environment]::NewLine), [Text.UTF8Encoding]::new($false))

    Write-AppServerMessage ([ordered]@{ jsonrpc = '2.0'; method = 'item/completed'; params = [ordered]@{ threadId = 'recorded-subscription-thread'; turnId = 'recorded-subscription-turn'; completedAtMs = 1; item = [ordered]@{ type = 'commandExecution'; id = 'command-1'; command = 'recorded command'; commandActions = @(); cwd = (Get-Location).Path; status = 'completed'; exitCode = 0; aggregatedOutput = 'recorded output' } } })
    Write-AppServerMessage ([ordered]@{ jsonrpc = '2.0'; method = 'item/completed'; params = [ordered]@{ threadId = 'recorded-subscription-thread'; turnId = 'recorded-subscription-turn'; completedAtMs = 2; item = [ordered]@{ type = 'fileChange'; id = 'file-1'; status = 'completed'; changes = @([ordered]@{ path = 'recorded.txt'; kind = [ordered]@{ type = 'add' } }) } } })
    Write-AppServerMessage ([ordered]@{ jsonrpc = '2.0'; method = 'item/completed'; params = [ordered]@{ threadId = 'recorded-subscription-thread'; turnId = 'recorded-subscription-turn'; completedAtMs = 3; item = [ordered]@{ type = 'agentMessage'; id = 'message-1'; text = 'recorded subscription response' } } })
    Write-AppServerMessage ([ordered]@{ jsonrpc = '2.0'; method = 'thread/tokenUsage/updated'; params = [ordered]@{ threadId = 'recorded-subscription-thread'; turnId = 'recorded-subscription-turn'; tokenUsage = [ordered]@{ total = [ordered]@{ inputTokens = 2; cachedInputTokens = 1; outputTokens = 3; reasoningOutputTokens = 1; totalTokens = 6 }; last = [ordered]@{ inputTokens = 2; cachedInputTokens = 1; outputTokens = 3; reasoningOutputTokens = 1; totalTokens = 6 } } } })
    Write-AppServerMessage ([ordered]@{ jsonrpc = '2.0'; method = 'turn/completed'; params = [ordered]@{ threadId = 'recorded-subscription-thread'; turn = [ordered]@{ id = 'recorded-subscription-turn'; status = 'completed'; items = @() } } })
    $threadRead = Read-AppServerMessage
    if (-not $fixtureThreadReadUnavailable) { Write-AppServerMessage ([ordered]@{ jsonrpc = '2.0'; id = $threadRead.id; result = [ordered]@{ thread = $threadObject } }) }
    exit 0
}
if ($harness -eq 'opencode' -and $arguments -contains 'debug' -and $arguments -contains 'config') {
    if ($fakeDelayMilliseconds -gt 0) { Start-Sleep -Milliseconds $fakeDelayMilliseconds }
    [IO.File]::AppendAllText($logPath, (($record | ConvertTo-Json -Compress) + [Environment]::NewLine), [Text.UTF8Encoding]::new($false))
    if ([string]::IsNullOrWhiteSpace([string]$record.config_file) -or -not (Test-Path -LiteralPath $record.config_file -PathType Leaf)) {
        [Console]::Error.WriteLine('recorded OpenCode debug config has no config file')
        exit 31
    }
    Write-Output ([IO.File]::ReadAllText($record.config_file, [Text.UTF8Encoding]::new($false)))
    exit 0
}
if ($harness -eq 'opencode' -and $arguments -contains 'debug' -and $arguments -contains 'paths') {
    if ($fakeDelayMilliseconds -gt 0) { Start-Sleep -Milliseconds $fakeDelayMilliseconds }
    [IO.File]::AppendAllText($logPath, (($record | ConvertTo-Json -Compress) + [Environment]::NewLine), [Text.UTF8Encoding]::new($false))
    $debugHome = if ($fakeHomeFixture) { $fakeAmbientUserRoot } else { [Environment]::GetEnvironmentVariable('HOME') }
    Write-Output ('home ' + $debugHome)
    Write-Output ('config ' + [Environment]::GetEnvironmentVariable('OPENCODE_CONFIG_DIR'))
    exit 0
}
if ($harness -eq 'opencode' -and $arguments -contains 'debug' -and $arguments -contains '--help') {
    if ($fakeDelayMilliseconds -gt 0) { Start-Sleep -Milliseconds $fakeDelayMilliseconds }
    [IO.File]::AppendAllText($logPath, (($record | ConvertTo-Json -Compress) + [Environment]::NewLine), [Text.UTF8Encoding]::new($false))
    Write-Output 'config paths skill'
    exit 0
}
if ($arguments -contains '--version') {
    $version = switch ($harness) { 'codex' { 'recorded-codex 9.1' } 'opencode' { 'recorded-opencode 9.2' } 'copilot' { 'GitHub Copilot CLI recorded-1.0.80' } default { 'recorded-unknown 9.3' } }
    if ($fakeDelayMilliseconds -gt 0) { Start-Sleep -Milliseconds $fakeDelayMilliseconds }
    [IO.File]::AppendAllText($logPath, (($record | ConvertTo-Json -Compress) + [Environment]::NewLine), [Text.UTF8Encoding]::new($false))
    Write-Output $version
    exit 0
}
if ($arguments -contains '--help') {
    $help = switch ($harness) {
        'codex' { '--ask-for-approval never --ephemeral --ignore-user-config --ignore-rules --json --output-last-message --sandbox --cd --model --config --approve-for-me' }
        'opencode' { '--format --dir --model --auto --pure --continue --session' }
        'copilot' {
            if ($exactSessionHelpFixture -and -not [string]::IsNullOrWhiteSpace($fixtureRoot)) { [IO.File]::ReadAllText((Join-Path $fixtureRoot 'copilot-help-exact-session.txt'), [Text.UTF8Encoding]::new($false)) }
            elseif ($noExactSessionHelpFixture -and -not [string]::IsNullOrWhiteSpace($fixtureRoot)) { [IO.File]::ReadAllText((Join-Path $fixtureRoot 'copilot-help-no-exact-session.txt'), [Text.UTF8Encoding]::new($false)) }
            else { '--prompt --output-format --model --allow-all-tools --no-ask-user --no-custom-instructions --disable-builtin-mcps --no-color --log-level --secret-env-vars --no-auto-update -C --resume --continue --session-id --connect --yolo --allow-all --allow-all-paths --allow-all-urls' }
        }
        default { '--json --auto-approve --cwd --config --data-dir --hooks-dir --provider --model --thinking --timeout --retries --id' }
    }
    if ($fakeDelayMilliseconds -gt 0) { Start-Sleep -Milliseconds $fakeDelayMilliseconds }
    [IO.File]::AppendAllText($logPath, (($record | ConvertTo-Json -Compress) + [Environment]::NewLine), [Text.UTF8Encoding]::new($false))
    Write-Output $help
    exit 0
}
$stdinMemory = [IO.MemoryStream]::new()
[Console]::OpenStandardInput().CopyTo($stdinMemory)
$stdinBytes = $stdinMemory.ToArray()
$stdinHash = [Convert]::ToHexString(([Security.Cryptography.SHA256]::HashData($stdinBytes))).ToLowerInvariant()
$expectedPromptHashPath = Join-Path ([Environment]::GetEnvironmentVariable('HOME')) 'expected-prompt-sha256.txt'
$expectedPromptHash = if ($scriptedFixture) { $stdinHash } elseif (Test-Path -LiteralPath $expectedPromptHashPath -PathType Leaf) { [IO.File]::ReadAllText($expectedPromptHashPath, [Text.UTF8Encoding]::new($false)).Trim() } else { $stdinHash }
$record.stdin_received = $stdinBytes.Length -gt 0
$record.stdin_delivery_count = if ($stdinBytes.Length -gt 0) { 1 } else { 0 }
$record.stdin_byte_length = $stdinBytes.Length
$record.stdin_sha256 = $stdinHash
$record.stdin_exact = $stdinHash -eq $expectedPromptHash
$record.stdin_expected_sha256 = $expectedPromptHash
$record.stdin_utf8_round_trip = $record.stdin_sha256 -eq $expectedPromptHash
$record.candidate_canary_in_stdin = ([Text.Encoding]::UTF8.GetString($stdinBytes) -match 'CODEBELT_BASELINE_LEAK_CANARY_|CODEBELT_BASELINE_FORMS_CANARY_|CODEBELT_OPENCODE_GLOBAL_SKILL_LEAK_CANARY_')
$probeCommand = '$result = [ordered]@{ provider_visible = -not [string]::IsNullOrWhiteSpace([Environment]::GetEnvironmentVariable(''OPENAI_API_KEY'')); copilot_token_visible = -not [string]::IsNullOrWhiteSpace([Environment]::GetEnvironmentVariable(''COPILOT_GITHUB_TOKEN'')); gh_token_visible = -not [string]::IsNullOrWhiteSpace([Environment]::GetEnvironmentVariable(''GH_TOKEN'')); github_token_visible = -not [string]::IsNullOrWhiteSpace([Environment]::GetEnvironmentVariable(''GITHUB_TOKEN'')); auth_file_visible = Test-Path -LiteralPath (Join-Path ([Environment]::GetEnvironmentVariable(''HOME'')) ''.codex/auth.json''); global_secret_visible = -not [string]::IsNullOrWhiteSpace([Environment]::GetEnvironmentVariable(''AGENTIC_GLOBAL_SECRET'')); project_disable_visible = -not [string]::IsNullOrWhiteSpace([Environment]::GetEnvironmentVariable(''OPENCODE_DISABLE_PROJECT_CONFIG'')) }; $result | ConvertTo-Json -Compress'
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
    if (-not $probe.WaitForExit(5000)) { throw 'worker credential probe exceeded its finite test wait.' }
    if ($probe.ExitCode -ne 0) { throw "worker credential probe failed: $probeError" }
    $probeResult = $probeOutput | ConvertFrom-Json
    $record.worker_provider_visible = [bool]$probeResult.provider_visible
    $record.worker_copilot_token_visible = [bool]$probeResult.copilot_token_visible
    $record.worker_gh_token_visible = [bool]$probeResult.gh_token_visible
    $record.worker_github_token_visible = [bool]$probeResult.github_token_visible
    $record.worker_auth_file_visible = [bool]$probeResult.auth_file_visible
    $record.worker_global_secret_visible = [bool]$probeResult.global_secret_visible
    $record.worker_project_disable_visible = [bool]$probeResult.project_disable_visible
} finally {
    $probe.Dispose()
}
if ($fakeDelayMilliseconds -gt 0) { Start-Sleep -Milliseconds $fakeDelayMilliseconds }
[IO.File]::AppendAllText($logPath, (($record | ConvertTo-Json -Compress) + [Environment]::NewLine), [Text.UTF8Encoding]::new($false))
if ($harness -eq 'copilot' -and $copilotAuthenticationSource -eq 'unavailable') {
    [Console]::Error.WriteLine('deterministic fixture: no Copilot authentication mechanism is available')
    exit 17
}
if ($scriptedFixture -and -not [string]::IsNullOrWhiteSpace($fixtureRoot) -and $harness -in @('copilot', 'opencode')) {
    $turnNumber = if ([string]::IsNullOrWhiteSpace([string]$continuationSessionId)) { 1 } else { 2 }
    $fixturePath = Join-Path $fixtureRoot ("{0}-scripted-turn-{1}-events.jsonl" -f $harness, $turnNumber)
    if (-not (Test-Path -LiteralPath $fixturePath -PathType Leaf)) {
        [Console]::Error.WriteLine("recorded scripted fixture is missing: $fixturePath")
        exit 23
    }
    $fixtureText = [IO.File]::ReadAllText($fixturePath, [Text.UTF8Encoding]::new($false))
    if ($turnNumber -eq 1 -and $noSessionFirstFixture) {
        if ($harness -eq 'copilot') { $fixtureText = $fixtureText.Replace('"sessionId":"fixture-copilot-session"', '"sessionId":null') }
        if ($harness -eq 'opencode') { $fixtureText = $fixtureText.Replace('"sessionID":"fixture-opencode-session"', '"sessionID":null') }
    }
    if ($turnNumber -eq 1 -and $noTerminalFirstFixture) {
        $terminalEventPattern = if ($harness -eq 'copilot') { 'session.task_complete' } else { 'step_finish' }
        $fixtureText = [string]::Join("`n", @($fixtureText -split "`r?`n" | Where-Object { $_ -notmatch [regex]::Escape($terminalEventPattern) }))
    }
    if ($turnNumber -gt 1 -and $mismatchSessionFixture) {
        if ($harness -eq 'copilot') { $fixtureText = $fixtureText.Replace('fixture-copilot-session', 'fixture-copilot-mismatch') }
        if ($harness -eq 'opencode') { $fixtureText = $fixtureText.Replace('fixture-opencode-session', 'fixture-opencode-mismatch') }
    }
    if ($harness -eq 'opencode' -and ($sourceAncestorCanaryVisible -or $sourceFormsCanaryVisible -or $sourceAncestorAgentsVisible -or $sourceAncestorCopilotVisible -or $ambientAgentsSkillVisible -or $ambientClaudeSkillVisible -or $ambientOpenCodeSkillVisible)) {
        $leakMarker = if ($ambientAgentsSkillVisible -or $ambientClaudeSkillVisible -or $ambientOpenCodeSkillVisible) { 'CODEBELT_OPENCODE_GLOBAL_SKILL_LEAK_CANARY_8F43D1A7' } else { 'CODEBELT_BASELINE_LEAK_CANARY_7C9E4AF2' }
        Write-Output ('{"type":"text","text":"' + $leakMarker + '"}')
        Write-Output '{"type":"step_finish"}'
        exit 0
    }
    foreach ($fixtureLine in @($fixtureText -split "`r?`n")) {
        if (-not [string]::IsNullOrWhiteSpace([string]$fixtureLine)) { Write-Output $fixtureLine }
    }
    exit 0
}
if ($harness -eq 'codex') {
    $outputIndex = [Array]::IndexOf([string[]]$arguments, '--output-last-message')
    if ($outputIndex -ge 0 -and $outputIndex + 1 -lt $arguments.Count) {
        $outputPath = $arguments[$outputIndex + 1]
        $outputParent = Split-Path -Parent $outputPath
        if (-not (Test-Path -LiteralPath $outputParent -PathType Container)) {
            [Console]::Error.WriteLine("recorded Codex requires the output parent directory to exist: $outputParent")
            exit 19
        }
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
} elseif ($harness -eq 'copilot') {
    Write-Output '{"type":"session.start","id":"e1","parentId":null,"data":{"sessionId":"recorded"}}'
    Write-Output '{"type":"assistant.message","id":"e2","parentId":"e1","data":{"messageId":"m1","model":"claude-haiku-4.5","content":"recorded Copilot progress"}}'
    Write-Output '{"type":"tool.execution_start","id":"e3","parentId":"e2","data":{"callId":"t1","toolName":"str_replace_editor"}}'
    Write-Output '{"type":"tool.execution_complete","id":"e4","parentId":"e3","data":{"callId":"t1","status":"success"}}'
    Write-Output '{"type":"assistant.message","id":"e5","parentId":"e4","data":{"messageId":"m2","model":"claude-haiku-4.5","content":"recorded Copilot final response"}}'
    Write-Output '{"type":"assistant.usage","id":"e6","parentId":"e5","ephemeral":true,"data":{"model":"claude-haiku-4.5","inputTokens":2,"outputTokens":3,"cacheReadTokens":1,"numToolCalls":1,"cost":0.2}}'
    Write-Output '{"type":"session.task_complete","id":"e7","parentId":"e6","data":{}}'
    Write-Output '{"type":"future.event.v99","payload":"fixture"}'
}
'@
    foreach ($harness in @('codex', 'opencode', 'copilot')) {
        [System.IO.File]::WriteAllText((Join-Path $fakeBin "$harness.ps1"), $fakeCli, [System.Text.UTF8Encoding]::new($false))
    }
    $fakeGh = @'
[CmdletBinding()]
param([Parameter(ValueFromRemainingArguments = $true)][string[]]$RemainingArguments)
if ($RemainingArguments.Count -eq 2 -and $RemainingArguments[0] -eq 'auth' -and $RemainingArguments[1] -eq 'token') {
    $config = [Environment]::GetEnvironmentVariable('GH_CONFIG_DIR')
    if (-not [string]::IsNullOrWhiteSpace($config) -and (Test-Path -LiteralPath (Join-Path $config 'auth-marker.txt') -PathType Leaf)) {
        Write-Output 'recorded-gh-fallback-token-not-logged'
        exit 0
    }
    [Console]::Error.WriteLine('not logged in')
    exit 1
}
[Console]::Error.WriteLine('unsupported gh fixture command')
exit 2
'@
    [System.IO.File]::WriteAllText((Join-Path $fakeBin 'gh.ps1'), $fakeGh, [System.Text.UTF8Encoding]::new($false))
    $env:PATH = "$fakeBin$([System.IO.Path]::PathSeparator)$recordedOldPath"
    $env:OPENAI_API_KEY = 'recorded-canary-not-logged'
    $env:AGENTIC_GLOBAL_SECRET = 'recorded-unrelated-canary-not-logged'
    $env:OPENCODE_DISABLE_PROJECT_CONFIG = '1'
    $env:COPILOT_GITHUB_TOKEN = 'recorded-copilot-canary-not-logged'
    $env:GH_TOKEN = 'recorded-gh-canary-not-logged'
    $env:GITHUB_TOKEN = 'recorded-github-canary-not-logged'
    $recordedGhConfig = Join-Path $recordedRoot 'github-cli-auth'
    New-Item -ItemType Directory -Path $recordedGhConfig -Force | Out-Null
    [System.IO.File]::WriteAllText((Join-Path $recordedGhConfig 'auth-marker.txt'), 'fixture auth state without a credential value', [System.Text.UTF8Encoding]::new($false))
    $env:GH_CONFIG_DIR = $recordedGhConfig
    $ambientCopilotHome = Join-Path $recordedRoot 'ambient-copilot-home'
    New-Item -ItemType Directory -Path $ambientCopilotHome -Force | Out-Null
    [System.IO.File]::WriteAllText((Join-Path $ambientCopilotHome 'copilot-instructions.md'), '# ambient-personal-instruction-not-logged', [System.Text.UTF8Encoding]::new($false))
    [System.IO.File]::WriteAllText((Join-Path $ambientCopilotHome 'config.json'), '{"loggedInUsers":[{"login":"ambient-profile-not-logged"}]}', [System.Text.UTF8Encoding]::new($false))
    $env:COPILOT_HOME = $ambientCopilotHome
    $recordedProfiles = [ordered]@{}
    foreach ($runnerName in @('codex', 'opencode', 'copilot')) {
        $profilePath = Join-Path $recordedRoot "$runnerName-profile.json"
        $profileModel = switch ($runnerName) {
            'copilot' { 'claude-haiku-4.5' }
            'codex' { 'gpt-5.6-luna' }
            'opencode' { 'opencode/muse-spark-1.2-contributor-free' }
        }
        Write-TestJson -Path $profilePath -Value ([ordered]@{
            schema = (Get-RunnerSchemaNames).Profile
            runner = if ($runnerName -eq 'copilot') { 'github-copilot' } else { $runnerName }
            model = $profileModel
            reasoning_effort = 'medium'
            configuration_profile = 'isolated-default'
            tool_profile = 'default'
            timeout_seconds = 30
            concurrency = if ($runnerName -eq 'opencode') { 2 } else { 1 }
        })
        $recordedProfiles[$runnerName] = $profilePath
    }
    $resolvedRecordedCodex = Resolve-ExternalCommand -Name 'codex'
    Assert-Equal (Join-Path $fakeBin 'codex.ps1') $resolvedRecordedCodex.Source 'recorded Codex command is selected before the installed CLI'
    $recordedVersion = Get-ExternalCommandVersion -CommandInfo $resolvedRecordedCodex -WorkingDirectory (Join-Path $with.Root 'repo')
    if (-not $recordedVersion.Available) { throw "recorded Codex --version is not observable (exit=$($recordedVersion.Process.ExitCode), timed_out=$($recordedVersion.Process.TimedOut), stdout='$($recordedVersion.Process.Stdout)', stderr='$($recordedVersion.Process.Stderr)')" }
    Assert-Equal 'recorded-codex 9.1' $recordedVersion.Version 'recorded Codex exact version helper'
    foreach ($fixtureName in @(
            'copilot-scripted-turn-1-events.jsonl',
            'copilot-scripted-turn-2-events.jsonl',
            'opencode-scripted-turn-1-events.jsonl',
            'opencode-scripted-turn-2-events.jsonl'
        )) {
        $fixturePath = Join-Path $recordedFixtureRoot $fixtureName
        Assert-True (Test-Path -LiteralPath $fixturePath -PathType Leaf) "recorded scripted fixture exists: $fixtureName"
        $fixtureEvents = [System.Collections.Generic.List[object]]::new()
        foreach ($line in @(Get-Content -LiteralPath $fixturePath)) {
            if ([string]::IsNullOrWhiteSpace([string]$line)) { continue }
            try { $fixtureEvents.Add(($line | ConvertFrom-Json -Depth 100)) }
            catch { throw "recorded scripted fixture '$fixtureName' contains invalid JSON: $($_.Exception.Message)" }
        }
        Assert-True ($fixtureEvents.Count -ge 3) "recorded scripted fixture has structured events: $fixtureName"
        Assert-True (@($fixtureEvents | Where-Object { [string]$_.type -in @('assistant.message', 'text') }).Count -ge 1) "recorded scripted fixture has an assistant message: $fixtureName"
    }
    $debugConfigFixturePath = Join-Path $recordedFixtureRoot 'opencode-debug-config.json'
    $debugConfigFixture = [IO.File]::ReadAllText($debugConfigFixturePath, [Text.UTF8Encoding]::new($false)) | ConvertFrom-Json -Depth 50
    Assert-Equal 'deny' ([string]$debugConfigFixture.permission.skill) 'Recorded OpenCode debug config fixture preserves deny-all skill policy syntax'
    foreach ($runnerName in @('codex', 'opencode', 'copilot')) {
        $runnerDir = if ($runnerName -eq 'copilot') { 'github-copilot' } else { $runnerName }
        $runnerPath = Join-Path $runnerRoot "$runnerDir\runner.ps1"
        $description = Invoke-AdapterJson -RunnerPath $runnerPath -Command describe -RunPath $with.Path -ProfilePath $recordedProfiles[$runnerName]
        [void](Assert-RunnerDescriptor -Descriptor $description)
        Assert-True ($description.PSObject.Properties.Name -contains 'delegation') "$runnerName descriptor declares native delegation"
        $expectedDispatchOwner = 'runner'
        Assert-Equal $expectedDispatchOwner $description.delegation.dispatch_owner "$runnerName descriptor declares its native dispatch owner"
        Assert-True (-not [bool]$description.delegation.nested_model_execution) "$runnerName descriptor forbids nested model execution"
        Assert-True (-not [string]::IsNullOrWhiteSpace([string]$description.delegation.mechanism)) "$runnerName descriptor records its native delegation mechanism"
        Assert-Equal 'conditional' $description.capabilities.native_worker_delegation "$runnerName descriptor does not present native delegation as terminal proof"
        Assert-Equal 'conditional' $description.delegation.model_lock "$runnerName descriptor leaves child model resolution conditional"
        if ($runnerName -in @('copilot', 'opencode')) {
            Assert-Equal 'conditional' $description.capabilities.scripted_multi_turn_same_session "$runnerName descriptor gates scripted continuation on installed capability proof"
        }
        $expectedVersion = switch ($runnerName) { 'codex' { 'recorded-codex 9.1' } 'opencode' { 'recorded-opencode 9.2' } 'copilot' { 'GitHub Copilot CLI recorded-1.0.80' } default { 'recorded-unknown 9.3' } }
        Assert-Equal $expectedVersion $description.harness.version "$runnerName exact describe version"
        $preflightWith = Invoke-AdapterJson -RunnerPath $runnerPath -Command preflight -RunPath $with.Path -ProfilePath $recordedProfiles[$runnerName]
        $preflightWithout = Invoke-AdapterJson -RunnerPath $runnerPath -Command preflight -RunPath $without.Path -ProfilePath $recordedProfiles[$runnerName]
        Assert-Equal 'compatible' $preflightWith.status "$runnerName with_skill pragmatic preflight: $([string]::Join('; ', @($preflightWith.reasons)))"
        Assert-Equal 'compatible' $preflightWithout.status "$runnerName without_skill pragmatic preflight"
        Assert-Equal $expectedVersion $preflightWith.harness.version "$runnerName exact preflight version"
        Assert-Equal 'pragmatic' $preflightWith.isolation.level "$runnerName pragmatic preflight level"
        Assert-Equal 'conditional' $preflightWith.delegation.status "$runnerName native delegation preflight requires terminal evidence"
        Assert-Equal $expectedDispatchOwner $preflightWith.delegation.dispatch_owner "$runnerName preflight preserves native dispatch ownership"
        Assert-True ([bool]$preflightWith.delegation.terminal_evidence_required) "$runnerName preflight requires terminal delegation evidence"
        if ($runnerName -in @('copilot', 'opencode')) {
            Assert-Equal 'conditional' $preflightWith.resolved_capabilities.scripted_multi_turn_same_session "$runnerName single-turn preflight leaves scripted capability conditional"
        }
        if ($runnerName -eq 'copilot') {
            Assert-True (@($preflightWith.checks | Where-Object { $_.name -eq 'authentication' -and $_.status -eq 'passed' }).Count -eq 1) 'Copilot preflight accepts explicit environment authentication'
            Assert-True (@($preflightWith.mechanisms | Where-Object { $_ -eq '--allow-all-tools broad tool approval' }).Count -eq 1) 'Copilot preflight describes --allow-all-tools as broad tool approval'
            Assert-True (@($preflightWith.mechanisms | Where-Object { $_ -eq 'path and URL verification preserved (no --allow-all-paths/--allow-all-urls)' }).Count -eq 1) 'Copilot preflight records preserved path and URL verification'
        }
        if ($runnerName -eq 'opencode') {
            Assert-True (@($preflightWith.checks | Where-Object { $_.name -eq 'parallel_dispatch' -and $_.status -eq 'passed' }).Count -eq 1) 'OpenCode preflight requires bounded concurrent dispatch'
            Assert-True (@($preflightWith.mechanisms | Where-Object { $_ -eq 'deterministic runner-owned concurrent fan-out' }).Count -eq 1) 'OpenCode preflight records the runner-owned concurrent fan-out'
            Assert-True (@($preflightWith.checks | Where-Object { $_.name -eq 'effective_home' -and $_.status -eq 'passed' }).Count -eq 1) 'OpenCode preflight proves the effective runtime home'
            Assert-True (@($preflightWith.checks | Where-Object { $_.name -eq 'skill_isolation_policy' -and $_.status -eq 'passed' }).Count -eq 1) 'OpenCode preflight proves the arm skill policy'
            Assert-True (@($preflightWith.checks | Where-Object { $_.name -eq 'skill_permission_debug' -and $_.status -eq 'passed' }).Count -eq 1) 'OpenCode preflight proves the installed debug config permission layer'
            Assert-Equal 'node.os.homedir' $preflightWith.protocol_observations.effective_home.effective_runtime_home_source 'OpenCode preflight uses the model-free Node homedir proof'
            Assert-True ([bool]$preflightWith.protocol_observations.effective_home.windows_profile_parts_coherent) 'OpenCode preflight proves coherent Windows profile parts'
            Assert-Equal 'supported_and_verified' $preflightWith.protocol_observations.skill_isolation.permission_layer 'OpenCode preflight records verified native skill permission support'
        }
        if ($runnerName -eq 'opencode') {
            Assert-True (@($preflightWith.warnings | Where-Object { $_ -match 'child-tool environment filter' }).Count -gt 0) "$runnerName reports the child credential-filter limitation"
        }
        if ($runnerName -eq 'codex') {
            Assert-True (-not [bool]$preflightWith.protocol_observations.allow_provider_model_fallback) 'Codex installed schema reports that provider fallback control is unavailable'
            Assert-True (@($preflightWith.checks | Where-Object { $_.name -eq 'native_worker_delegation' -and $_.detail -match 'structurally proves' }).Count -eq 1) 'Codex preflight uses structural app-server schema validation'
            Assert-Equal 'aggregate_v2_bundle' $preflightWith.protocol_observations.schema_source_kind 'Codex fixture resolves the aggregate v2 schema bundle'
            Assert-True ([string]$preflightWith.protocol_observations.schema_source -match 'codex_app_server_protocol\.v2\.schemas\.json$') 'Codex fixture records the aggregate v2 schema source'
            Assert-Equal 'read-only,workspace-write,danger-full-access' ([string]::Join(',', @($preflightWith.protocol_observations.sandbox_modes))) 'Codex fixture validates the installed sandbox enum'

            $individualSchemaMarker = Join-Path $with.Root 'home\codex-schema-individual-v2'
            [IO.File]::WriteAllText($individualSchemaMarker, 'fixture', [Text.UTF8Encoding]::new($false))
            try {
                $individualPreflight = Invoke-AdapterJson -RunnerPath $runnerPath -Command preflight -RunPath $with.Path -ProfilePath $recordedProfiles[$runnerName]
                Assert-Equal 'compatible' $individualPreflight.status 'Codex recursively discovers namespaced individual v2 schemas'
                Assert-Equal 'recursive_individual_files' $individualPreflight.protocol_observations.schema_source_kind 'Codex records recursive individual schema discovery'
            } finally {
                Remove-Item -LiteralPath $individualSchemaMarker -Force
            }

            $withoutThreadReadMarker = Join-Path $with.Root 'home\codex-schema-without-thread-read'
            [IO.File]::WriteAllText($withoutThreadReadMarker, 'fixture', [Text.UTF8Encoding]::new($false))
            try {
                $withoutThreadReadPreflight = Invoke-AdapterJson -RunnerPath $runnerPath -Command preflight -RunPath $with.Path -ProfilePath $recordedProfiles[$runnerName]
                Assert-Equal 'compatible' $withoutThreadReadPreflight.status 'Codex accepts a protocol without the supplemental thread/read method'
                Assert-True (-not [bool]$withoutThreadReadPreflight.protocol_observations.thread_read_schema_available) 'Codex records absent supplemental thread/read schemas as unavailable'
                $withoutThreadReadDelegationCheck = @($withoutThreadReadPreflight.checks | Where-Object { $_.name -eq 'native_worker_delegation' }) | Select-Object -First 1
                Assert-True ([string]$withoutThreadReadDelegationCheck.detail -match 'thread/read is supplemental and not advertised') 'Codex reports the supplemental thread/read decision deterministically'
            } finally {
                Remove-Item -LiteralPath $withoutThreadReadMarker -Force
            }

            $missingSchemaMarker = Join-Path $with.Root 'home\codex-schema-missing-ThreadStartParams'
            [IO.File]::WriteAllText($missingSchemaMarker, 'fixture', [Text.UTF8Encoding]::new($false))
            try {
                $missingPreflight = Invoke-AdapterJson -RunnerPath $runnerPath -Command preflight -RunPath $with.Path -ProfilePath $recordedProfiles[$runnerName]
                Assert-Equal 'incompatible' $missingPreflight.status 'Codex missing schema is a controlled incompatible preflight'
                $missingText = [string]($missingPreflight | ConvertTo-Json -Depth 100)
                Assert-True ($missingText -match 'Installed Codex app-server schema is missing required v2 schema: ThreadStartParams\.') 'Codex reports the exact missing logical schema'
                Assert-True ($missingText -notmatch 'Cannot bind argument to parameter .Schema. because it is null') 'Codex missing schema never emits a null-binding exception'
            } finally {
                Remove-Item -LiteralPath $missingSchemaMarker -Force
            }

            $multipleMissingSchemaMarker = Join-Path $with.Root 'home\codex-schema-missing-required'
            [IO.File]::WriteAllText($multipleMissingSchemaMarker, 'fixture', [Text.UTF8Encoding]::new($false))
            try {
                $multipleMissingPreflight = Invoke-AdapterJson -RunnerPath $runnerPath -Command preflight -RunPath $with.Path -ProfilePath $recordedProfiles[$runnerName]
                Assert-Equal 'incompatible' $multipleMissingPreflight.status 'Codex reports multiple missing schemas as a controlled incompatible preflight'
                $multipleMissingText = [string]($multipleMissingPreflight | ConvertTo-Json -Depth 100)
                Assert-True ($multipleMissingText -match 'Installed Codex app-server schemas are missing required v2 schemas: ThreadStartParams, TurnStartResponse\.') 'Codex reports all missing logical schemas in one deterministic message'
                Assert-True ($multipleMissingText -notmatch 'Cannot bind argument to parameter .Schema. because it is null') 'Codex multiple missing schemas never emits a null-binding exception'
            } finally {
                Remove-Item -LiteralPath $multipleMissingSchemaMarker -Force
            }
        }
        $resultWith = Invoke-AdapterJson -RunnerPath $runnerPath -Command execute -RunPath $with.Path -ProfilePath $recordedProfiles[$runnerName]
        $resultWithout = Invoke-AdapterJson -RunnerPath $runnerPath -Command execute -RunPath $without.Path -ProfilePath $recordedProfiles[$runnerName]
        foreach ($result in @($resultWith, $resultWithout)) {
            [void](Assert-ExecutionResult -Result $result)
            Assert-Equal 'completed' $result.status "$runnerName recorded completion: $([string](Get-JsonProperty -Object $result.exit.failure -Name 'message' -Default ''))"
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
            # Runner-owned convergence: Copilot and OpenCode behavioral transport
            # now emits transport-owned terminal evidence for its own fresh
            # session, with no orchestrator-authored reconstruction. Codex's
            # runner-owned app-server evidence is validated in its dedicated
            # subscription block below; its API-key `codex exec` compatibility
            # path is intentionally not the runner-owned behavioral transport.
            if ($runnerName -in @('copilot', 'opencode')) {
                Assert-Equal 'runner' ([string]$result.evidence.delegation.dispatch_owner) "$runnerName execution evidence is runner-owned"
                Assert-Equal 'harness_native_transport' ([string]$result.evidence.capture.source) "$runnerName capture provenance is transport-owned"
                Assert-True (-not [bool]$result.evidence.capture.worker_authored) "$runnerName capture is not orchestrator/worker-authored"
                Assert-Equal ([string]$result.session.id) ([string]$result.evidence.delegation.worker_session_id) "$runnerName terminal evidence binds to the fresh session id"
                $convergenceRunPath = if ($result.run.configuration -eq 'with_skill') { $with.Path } else { $without.Path }
                $convergenceRun = Resolve-RunContract -RunPath $convergenceRunPath
                $convergenceEvidence = Test-NativeWorkerTerminalEvidence -ExecutionEvidence $result -Run $convergenceRun -RequestedModel ([string]$result.requested.model) -ExpectedWorkerSessionId ([string]$result.session.id) -ExpectedMechanism ([string]$description.delegation.mechanism)
                Assert-True $convergenceEvidence.Valid "$runnerName produces valid runner-owned terminal evidence: $([string]::Join(', ', @($convergenceEvidence.Failures)))"
            }
        }
        $logPath = Join-Path $with.Root "repo\$runnerName-fake-cli-log.jsonl"
        Assert-True (Test-Path -LiteralPath $logPath -PathType Leaf) "$runnerName recorded process log exists"
        $records = @(Get-Content -LiteralPath $logPath | ForEach-Object { $_ | ConvertFrom-Json })
        $executionRecords = @($records | Where-Object { $_.stdin_received -eq $true -or $_.prompt_via_arg -eq $true })
        Assert-Equal 1 $executionRecords.Count "$runnerName one execution process per checked arm"
        $execution = $executionRecords[0]
        Assert-True $execution.stdin_received "$runnerName receives a non-empty stdin prompt"
        Assert-Equal 1 $execution.stdin_delivery_count "$runnerName delivers one prompt through stdin"
        $promptDiagnostic = if ($runnerName -eq 'codex') { " ($($execution | ConvertTo-Json -Depth 20 -Compress))" } else { '' }
        Assert-True $execution.stdin_exact "$runnerName fake CLI received the exact staged prompt bytes$promptDiagnostic"
        Assert-True $execution.stdin_utf8_round_trip "$runnerName preserves arbitrary UTF-8 prompt content"
        Assert-True (-not $execution.unrelated_present) "$runnerName does not pass unrelated credential canary"
        Assert-True (-not $execution.disable_project_config_present) "$runnerName does not pass ambient project-disable override"
        Assert-True (-not $execution.worker_auth_file_visible) "$runnerName worker probe cannot read a copied Codex auth file"
        Assert-True (-not $execution.worker_global_secret_visible) "$runnerName worker probe cannot read the parent/global canary"
        Assert-True (-not $execution.worker_project_disable_visible) "$runnerName worker probe cannot read the parent project-disable variable"
        if ($runnerName -eq 'codex') {
            Assert-True (-not $execution.worker_provider_visible) 'Codex shell policy hides the provider API-key variable from the worker probe'
        } elseif ($runnerName -eq 'copilot') {
            Assert-True (-not $execution.worker_copilot_token_visible) 'Copilot secret COPILOT_GITHUB_TOKEN is unavailable to the worker probe'
            Assert-True (-not $execution.worker_gh_token_visible) 'Copilot secret GH_TOKEN is unavailable to the worker probe'
            Assert-True (-not $execution.worker_github_token_visible) 'Copilot secret GITHUB_TOKEN is unavailable to the worker probe'
        } else {
            Assert-True (-not $execution.worker_provider_visible) "$runnerName free-model fixture does not require a provider API key"
        }
        $args = @($execution.args)
        foreach ($forbidden in @('--continue', '--session', '--resume')) { Assert-True ($args -notcontains $forbidden) "$runnerName does not pass '$forbidden'" }
        if ($runnerName -eq 'codex') {
            Assert-True ($args -contains '--ask-for-approval') 'Codex uses explicit approval policy'
            Assert-True ($args -contains 'never') 'Codex approval policy is never'
            Assert-True ($args -contains '--sandbox' -and $args -contains 'workspace-write') 'Codex retains workspace-write sandbox'
            Assert-True ($args -notcontains '--approve-for-me') 'Codex avoids the conflicting approve-for-me flag'
            $modelIndex = [Array]::IndexOf([string[]]$args, '--model')
            Assert-Equal 'gpt-5.6-luna' $args[$modelIndex + 1] 'Codex opaque model selector propagates to the CLI invocation'
            $outputIndex = [Array]::IndexOf([string[]]$args, '--output-last-message')
            Assert-Equal (Join-Path $resultWith.evidence.execution_paths.physical_run_root 'evidence\codex-final.txt') $args[$outputIndex + 1] 'Codex output path uses the runner-declared physical projection'
        } elseif ($runnerName -eq 'opencode') {
            Assert-True ($args -notcontains '--pure') 'OpenCode preserves repository-owned project configuration'
            Assert-True ($args -contains '--auto') 'OpenCode is noninteractive'
            Assert-True $execution.project_config_visible 'OpenCode paired arm retains repository-owned project configuration'
            Assert-True (-not (Test-PathInside -BasePath $recordedRoot -CandidatePath ([string]$execution.working_directory))) 'OpenCode physical execution cwd is outside the source-repository fixture ancestry'
            Assert-True (-not (Test-PathInside -BasePath $recordedRoot -CandidatePath ([string]$execution.home))) 'OpenCode physical HOME is outside the source-repository fixture ancestry'
            Assert-True (-not (Test-PathInside -BasePath $recordedRoot -CandidatePath ([string]$execution.appdata))) 'OpenCode APPDATA is outside the source-repository fixture ancestry'
            Assert-True (-not (Test-PathInside -BasePath $recordedRoot -CandidatePath ([string]$execution.local_appdata))) 'OpenCode LOCALAPPDATA is outside the source-repository fixture ancestry'
            Assert-True ([string]::IsNullOrWhiteSpace([string]$execution.node_path)) 'OpenCode does not inherit NODE_PATH from the ambient environment'
            Assert-True (-not (Test-PathInside -BasePath $recordedRoot -CandidatePath ([string]$execution.config_directory))) 'OpenCode config directory is outside the source-repository fixture ancestry'
            Assert-True (-not (Test-PathInside -BasePath $recordedRoot -CandidatePath ([string]$execution.config_file))) 'OpenCode config file is outside the source-repository fixture ancestry'
            Assert-Equal ([string]$execution.home) ([string]$execution.node_homedir) 'OpenCode Node runtime resolves the isolated HOME'
            Assert-Equal ([string]$execution.home) ([string]$execution.userprofile) 'OpenCode USERPROFILE matches the isolated HOME'
            Assert-Equal ([string]$execution.home) ([string]$execution.homedrive + [string]$execution.homepath) 'OpenCode HOMEDRIVE/HOMEPATH resolve the isolated HOME'
            Assert-True (Test-PathInside -BasePath ([string]$execution.home) -CandidatePath ([string]$execution.xdg_config_home)) 'OpenCode XDG_CONFIG_HOME is isolated'
            Assert-Equal '1' $execution.disable_external_skills 'OpenCode disables external skill discovery'
            Assert-Equal '1' $execution.disable_claude_code_skills 'OpenCode disables Claude/agents skill discovery'
            Assert-True (-not [bool]$execution.source_ancestor_candidate_skill_visible) 'OpenCode execution cannot discover the source-repository candidate skill canary through projected ancestry'
            Assert-True (-not [bool]$execution.source_ancestor_forms_visible) 'OpenCode execution cannot discover the source-repository FORMS.md canary through projected ancestry'
            Assert-True (-not [bool]$execution.source_ancestor_agents_visible) 'OpenCode execution cannot discover source-repository ancestor AGENTS.md through projected ancestry'
            Assert-True (-not [bool]$execution.source_ancestor_copilot_visible) 'OpenCode execution cannot discover source-repository ancestor copilot instructions through projected ancestry'
            Assert-True (-not [bool]$execution.staged_repo_canary_visible) 'OpenCode staged repository contains no source candidate canary'
            Assert-True (-not [bool]$execution.home_canary_visible) 'OpenCode isolated HOME contains no source candidate canary'
            Assert-True (-not [bool]$execution.config_canary_visible) 'OpenCode isolated config contains no source candidate canary'
            Assert-True ([bool]$execution.fake_ambient_candidate_fixture_visible) 'OpenCode ambient-skill canary fixture exists outside the isolated boundary'
            Assert-True (-not [bool]$execution.ambient_agents_skill_visible) 'OpenCode hides fake global .agents skills'
            Assert-True (-not [bool]$execution.ambient_claude_skill_visible) 'OpenCode hides fake global .claude skills'
            Assert-True (-not [bool]$execution.ambient_opencode_skill_visible) 'OpenCode hides fake global native OpenCode skills'
            Assert-True ([bool]$execution.staged_candidate_skill_visible) 'OpenCode with_skill projection contains the intended staged candidate skill'
            Assert-Equal 'included' $execution.candidate_skill_exposure 'OpenCode with_skill execution records candidate-skill exposure as included'
            Assert-True (-not [bool]$execution.candidate_skill_path_in_arguments) 'OpenCode does not receive a candidate-skill path through arguments'
            Assert-True (-not [bool]$execution.candidate_skill_path_in_environment) 'OpenCode does not receive a candidate-skill path through environment variables'
            Assert-True (-not [bool]$execution.candidate_canary_in_environment) 'OpenCode environment contains no ambient-skill canary marker'
            Assert-True (-not [bool]$execution.candidate_canary_in_stdin) 'OpenCode with_skill stdin does not receive the source-repository canary material'
            Assert-Equal 'deny' (Get-JsonProperty -Object $execution.skill_permission -Name '*' -Default '') 'OpenCode with_skill denies all ambient skill names by default'
            Assert-Equal 'allow' (Get-JsonProperty -Object $execution.skill_permission -Name 'candidate' -Default '') 'OpenCode with_skill allows only the prepared candidate skill name'
            Assert-True ([bool]$resultWith.evidence.execution_paths.physical_cwd_outside_source_repository) 'OpenCode result records the physical cwd ancestry boundary'
            Assert-True ([bool]$resultWith.evidence.execution_paths.physical_home_outside_source_repository) 'OpenCode result records the physical HOME ancestry boundary'
            Assert-True (-not (Test-PathInside -BasePath $recordedRoot -CandidatePath ([string]$resultWith.evidence.execution_paths.physical_config_directory))) 'OpenCode result records a physical config directory outside the source-repository ancestry'
            Assert-True (-not (Test-PathInside -BasePath $recordedRoot -CandidatePath ([string]$resultWith.evidence.execution_paths.physical_config_file))) 'OpenCode result records a physical config file outside the source-repository ancestry'
            Assert-True ([bool]$resultWith.evidence.candidate_skill_exposure.hash_match) 'OpenCode result proves the projected candidate skill hash matches the prepared skill hash'
            Assert-Equal 1 $resultWith.evidence.skill_isolation.candidate_skill_count 'OpenCode result exposes exactly one native candidate skill'
            Assert-Equal 0 $resultWith.evidence.skill_isolation.ambient_skill_count 'OpenCode result exposes no ambient skill roots with_skill'
            Assert-Equal 'removed' $resultWith.evidence.execution_paths.projection_cleanup 'OpenCode removes the physical projection after evidence capture'
            Assert-True (-not (Test-Path -LiteralPath ([string]$resultWith.evidence.execution_paths.physical_projection_root))) 'OpenCode physical projection is cleaned up by default'
            Assert-True ([string]$resultWith.evidence.candidate_skill_exposure.physical_path -match '(?i)[\\/]\.opencode[\\/]skills[\\/]candidate$') 'OpenCode evidence identifies the intended native projected candidate skill location'
            Assert-True ([bool]$resultWith.evidence.effective_home.valid) 'OpenCode result proves effective runtime home isolation'
            Assert-True ([bool]$resultWith.evidence.effective_home.windows_profile_parts_coherent) 'OpenCode result proves coherent Windows profile-part isolation'
            Assert-True ([bool]$resultWith.evidence.ambient_skill_policy.ambient_skill_roots_hidden) 'OpenCode result proves ambient skill roots remain hidden during with_skill'
            Assert-True ($resultWith.evidence.timing.turns[0].PSObject.Properties.Name -notcontains 'event_timing') 'OpenCode omits unavailable structured event timing instead of zero-filling it'
            $modelIndex = [Array]::IndexOf([string[]]$args, '--model')
            Assert-Equal 'opencode/muse-spark-1.2-contributor-free' $args[$modelIndex + 1] 'OpenCode opaque model selector propagates to the CLI invocation'
        } elseif ($runnerName -eq 'copilot') {
            Assert-True (@($args | Where-Object { $_ -eq '--prompt' -or $_ -eq '-p' -or $_ -like '--prompt=*' }).Count -eq 0) 'Copilot does not place the prompt in argv'
            Assert-Equal 0 $execution.prompt_arg_count 'Copilot has no prompt argument'
            Assert-True $execution.stdin_received 'Copilot reads the prompt from stdin'
            Assert-True ($args -contains '--output-format' -and $args -contains 'json') 'Copilot uses structured JSONL output'
            $modelIndex = [Array]::IndexOf([string[]]$args, '--model')
            Assert-Equal 'claude-haiku-4.5' $args[$modelIndex + 1] 'Copilot reference model claude-haiku-4.5 propagates to the CLI invocation'
            Assert-True ($args -contains '--allow-all-tools') 'Copilot grants broad tool approval for noninteractive execution'
            Assert-True ($args -contains '--no-ask-user') 'Copilot does not pause for interactive questions'
            Assert-True ($args -notcontains '--no-custom-instructions') 'Copilot preserves repository-owned custom instructions'
            Assert-True ($args -contains '--disable-builtin-mcps') 'Copilot disables ambient built-in MCP servers'
            foreach ($broad in @('--yolo', '--allow-all', '--allow-all-paths', '--allow-all-urls', '--session-id', '--connect', '-r')) { Assert-True ($args -notcontains $broad) "Copilot avoids the over-broad or session option '$broad'" }
            Assert-Equal 1 (@($args | Where-Object { $_ -like '--secret-env-vars=*' }).Count) 'Copilot filters protected variables with --secret-env-vars'
            Assert-Equal 'COPILOT_GITHUB_TOKEN,GH_TOKEN,GITHUB_TOKEN' ([string]($args | Where-Object { $_ -like '--secret-env-vars=*' }) -replace '^--secret-env-vars=', '') 'Copilot protects every forwarded token variable'
            Assert-True (-not $execution.custom_instructions_disabled -and $execution.builtin_mcps_disabled) 'Copilot preserves repository instructions while disabling built-in MCPs'
            Assert-True ($execution.repository_agents_visible -and $execution.repository_copilot_instructions_visible -and $execution.repository_instruction_marker_visible) 'Copilot sees staged repository-owned instructions'
            Assert-True $execution.candidate_skill_staged 'Copilot with_skill arm retains the staged candidate skill independently of repository instructions'
            Assert-True (-not $execution.ambient_copilot_instructions_visible) 'Copilot does not see the ambient personal instruction file'
            Assert-Equal 'explicit_environment' $execution.copilot_authentication_source 'Copilot uses explicit environment authentication in the token fixture'
            Assert-Equal 3 @($execution.copilot_auth_names_present).Count 'Copilot process receives all protected token variables without logging values'
            Assert-True ([string]::IsNullOrWhiteSpace([string]$execution.gh_config_dir)) 'Copilot explicit-token path does not forward host GH_CONFIG_DIR'
            Assert-True (Test-PathInside -BasePath (Join-Path $with.Root 'home') -CandidatePath ([string]$execution.copilot_cache_home)) 'Copilot cache is run-local'
            Assert-True (Test-PathInside -BasePath (Join-Path $with.Root 'home') -CandidatePath ([string]$execution.copilot_home)) 'Copilot COPILOT_HOME is the run''s isolated home'
            Assert-Equal 'stdin' $resultWith.evidence.prompt_delivery 'Copilot result records stdin prompt delivery'
            Assert-Equal 'COPILOT_GITHUB_TOKEN' $resultWith.evidence.credential.github_token_variable 'Copilot follows explicit token precedence'
            Assert-True (-not $resultWith.evidence.credential.github_cli_config_forwarded) 'Copilot result records that GH_CONFIG_DIR was not forwarded with an explicit token'
            Assert-Equal 'supported' $resultWith.isolation.capabilities.credential_child_filtering 'Copilot documents protected child-environment filtering'
            Assert-Equal 'shell,mcp' ([string]::Join(',', @($resultWith.evidence.credential.secret_env_var_scope))) 'Copilot evidence names the documented filtering scope'
            Assert-Equal 'recorded Copilot final response' $resultWith.final_response.text 'Copilot final response is the last assistant message, not an intermediate one'
            Assert-Equal 'claude-haiku-4.5' $resultWith.requested.model 'Copilot requested model is preserved as the Codebelt reference model'
            Assert-True ($null -eq $resultWith.resolved.model) 'Copilot does not claim a distinct backend model resolution'
            Assert-Equal 'claude-haiku-4.5' $resultWith.evidence.observed_model 'Copilot observed model is captured separately from the requested model'
            Assert-Equal 'available' $resultWith.telemetry.tokens.status 'Copilot reports available token telemetry'
            Assert-Equal 2 ([int]$resultWith.telemetry.tokens.value.input_tokens) 'Copilot input tokens are parsed from assistant.usage'
            Assert-Equal 3 ([int]$resultWith.telemetry.tokens.value.output_tokens) 'Copilot output tokens are parsed from assistant.usage'
            Assert-Equal 'available' $resultWith.telemetry.tool_calls.status 'Copilot reports available tool-call telemetry'
            Assert-True ([int]$resultWith.telemetry.tool_calls.value -ge 1) 'Copilot parses documented tool.execution events'
            Assert-Equal 'unavailable' $resultWith.telemetry.cost.status 'Copilot does not estimate a currency cost'
        }
        $logText = [System.IO.File]::ReadAllText($logPath, [System.Text.UTF8Encoding]::new($false))
        Assert-True ($logText -notmatch 'recorded-canary|recorded-unrelated-canary|recorded-copilot-canary|recorded-gh-canary|recorded-github-canary|recorded-gh-fallback-token') "$runnerName logs do not contain credential values"
        Assert-True (($resultWith | ConvertTo-Json -Depth 100) -notmatch 'recorded-canary|recorded-unrelated-canary|recorded-copilot-canary|recorded-gh-canary|recorded-github-canary|recorded-gh-fallback-token') "$runnerName result evidence does not contain credential values"
        $withoutLogPath = Join-Path $without.Root "repo\$runnerName-fake-cli-log.jsonl"
        Assert-True (Test-Path -LiteralPath $withoutLogPath -PathType Leaf) "$runnerName baseline process log exists"
        $withoutRecords = @(Get-Content -LiteralPath $withoutLogPath | ForEach-Object { $_ | ConvertFrom-Json })
        $withoutExecution = @($withoutRecords | Where-Object { $_.stdin_received -eq $true -or $_.prompt_via_arg -eq $true })
        Assert-Equal 1 $withoutExecution.Count "$runnerName baseline has one execution process"
        if ($runnerName -eq 'opencode') {
            Assert-True (-not (Test-PathInside -BasePath $recordedRoot -CandidatePath ([string]$withoutExecution[0].working_directory))) 'OpenCode without_skill physical cwd is outside the source-repository fixture ancestry'
            Assert-True (-not (Test-PathInside -BasePath $recordedRoot -CandidatePath ([string]$withoutExecution[0].appdata))) 'OpenCode without_skill APPDATA is outside the source-repository fixture ancestry'
            Assert-True (-not (Test-PathInside -BasePath $recordedRoot -CandidatePath ([string]$withoutExecution[0].local_appdata))) 'OpenCode without_skill LOCALAPPDATA is outside the source-repository fixture ancestry'
            Assert-True ([string]::IsNullOrWhiteSpace([string]$withoutExecution[0].node_path)) 'OpenCode without_skill does not inherit NODE_PATH from the ambient environment'
            Assert-True (-not (Test-PathInside -BasePath $recordedRoot -CandidatePath ([string]$withoutExecution[0].config_directory))) 'OpenCode without_skill config directory is outside the source-repository fixture ancestry'
            Assert-True (-not (Test-PathInside -BasePath $recordedRoot -CandidatePath ([string]$withoutExecution[0].config_file))) 'OpenCode without_skill config file is outside the source-repository fixture ancestry'
            Assert-Equal ([string]$withoutExecution[0].home) ([string]$withoutExecution[0].node_homedir) 'OpenCode without_skill Node runtime resolves the isolated HOME'
            Assert-Equal ([string]$withoutExecution[0].home) ([string]$withoutExecution[0].userprofile) 'OpenCode without_skill USERPROFILE matches the isolated HOME'
            Assert-Equal ([string]$withoutExecution[0].home) ([string]$withoutExecution[0].homedrive + [string]$withoutExecution[0].homepath) 'OpenCode without_skill HOMEDRIVE/HOMEPATH resolve the isolated HOME'
            Assert-True (Test-PathInside -BasePath ([string]$withoutExecution[0].home) -CandidatePath ([string]$withoutExecution[0].xdg_config_home)) 'OpenCode without_skill XDG_CONFIG_HOME is isolated'
            Assert-Equal '1' $withoutExecution[0].disable_external_skills 'OpenCode without_skill disables external skill discovery'
            Assert-Equal '1' $withoutExecution[0].disable_claude_code_skills 'OpenCode without_skill disables Claude/agents skill discovery'
            Assert-True ([bool]$withoutExecution[0].fake_ambient_candidate_fixture_visible) 'OpenCode without_skill ambient-skill canary fixture exists outside the isolated boundary'
            Assert-True (-not [bool]$withoutExecution[0].ambient_agents_skill_visible) 'OpenCode without_skill hides fake global .agents skills'
            Assert-True (-not [bool]$withoutExecution[0].ambient_claude_skill_visible) 'OpenCode without_skill hides fake global .claude skills'
            Assert-True (-not [bool]$withoutExecution[0].ambient_opencode_skill_visible) 'OpenCode without_skill hides fake global native OpenCode skills'
            Assert-Equal 'deny' ([string]$withoutExecution[0].skill_permission) 'OpenCode without_skill denies every skill name'
            Assert-True (-not [bool]$withoutExecution[0].candidate_canary_in_environment) 'OpenCode without_skill environment contains no ambient-skill canary marker'
            Assert-True (-not [bool]$withoutExecution[0].source_ancestor_candidate_skill_visible) 'OpenCode without_skill cannot discover the source candidate skill canary through projected ancestors'
            Assert-True (-not [bool]$withoutExecution[0].source_ancestor_forms_visible) 'OpenCode without_skill cannot discover the FORMS.md canary through projected ancestors'
            Assert-True (-not [bool]$withoutExecution[0].source_ancestor_agents_visible) 'OpenCode without_skill cannot discover source ancestor AGENTS.md through projected ancestors'
            Assert-True (-not [bool]$withoutExecution[0].source_ancestor_copilot_visible) 'OpenCode without_skill cannot discover source ancestor copilot instructions through projected ancestors'
            Assert-True (-not [bool]$withoutExecution[0].staged_repo_canary_visible) 'OpenCode without_skill staged repo contains no source candidate canary'
            Assert-True (-not [bool]$withoutExecution[0].home_canary_visible) 'OpenCode without_skill HOME contains no source candidate canary'
            Assert-True (-not [bool]$withoutExecution[0].config_canary_visible) 'OpenCode without_skill config contains no source candidate canary'
            Assert-True (-not [bool]$withoutExecution[0].staged_candidate_skill_visible) 'OpenCode without_skill projection contains no candidate skill'
            Assert-Equal 'excluded' $withoutExecution[0].candidate_skill_exposure 'OpenCode without_skill execution records candidate-skill exposure as excluded'
            Assert-True (-not [bool]$withoutExecution[0].candidate_skill_path_in_arguments) 'OpenCode without_skill has no candidate-skill path in arguments'
            Assert-True (-not [bool]$withoutExecution[0].candidate_skill_path_in_environment) 'OpenCode without_skill has no candidate-skill path in environment'
            Assert-True (-not [bool]$withoutExecution[0].candidate_canary_in_stdin) 'OpenCode without_skill stdin contains no candidate canary material'
            Assert-True (-not ([string]($resultWithout | ConvertTo-Json -Depth 100) -match 'CODEBELT_BASELINE_LEAK_CANARY_|CODEBELT_BASELINE_FORMS_CANARY_')) 'OpenCode without_skill result contains no baseline canary material'
            Assert-Equal 'excluded' $resultWithout.evidence.candidate_skill_exposure.status 'OpenCode without_skill result records candidate-skill exposure as excluded'
            Assert-True ([string]::IsNullOrWhiteSpace([string]$resultWithout.evidence.candidate_skill_exposure.physical_path)) 'OpenCode without_skill result has no projected candidate skill path'
            Assert-Equal 'removed' $resultWithout.evidence.execution_paths.projection_cleanup 'OpenCode without_skill removes the physical projection after evidence capture'
            Assert-True (-not (Test-Path -LiteralPath ([string]$resultWithout.evidence.execution_paths.physical_projection_root))) 'OpenCode without_skill physical projection is cleaned up by default'
            Assert-True ([bool]$resultWithout.evidence.effective_home.valid) 'OpenCode without_skill result proves effective runtime home isolation'
            Assert-Equal 'deny' ([string]$resultWithout.evidence.skill_policy.configured_permission_skill) 'OpenCode without_skill result records deny-all skill policy'
            Assert-Equal 0 $resultWithout.evidence.skill_isolation.discovered_skills.Count 'OpenCode without_skill result discovers zero candidate or ambient skills'
            Assert-True ([bool]$resultWithout.evidence.ambient_skill_policy.ambient_skill_roots_hidden) 'OpenCode without_skill result proves ambient skill roots remain hidden'
            Assert-True ([string]$resultWithout.evidence.execution_paths.physical_working_directory -notmatch [regex]::Escape($recordedRoot)) 'OpenCode without_skill result physical cwd does not point into the source repository'
            Assert-True (-not (Test-PathInside -BasePath $recordedRoot -CandidatePath ([string]$resultWithout.evidence.execution_paths.physical_config_directory))) 'OpenCode without_skill result records a physical config directory outside the source-repository ancestry'
            Assert-True (-not (Test-PathInside -BasePath $recordedRoot -CandidatePath ([string]$resultWithout.evidence.execution_paths.physical_config_file))) 'OpenCode without_skill result records a physical config file outside the source-repository ancestry'
        }
        $withoutLogText = [System.IO.File]::ReadAllText($withoutLogPath, [System.Text.UTF8Encoding]::new($false))
        Assert-True ($withoutLogText -notmatch 'recorded-canary|recorded-unrelated-canary|recorded-copilot-canary|recorded-gh-canary|recorded-github-canary|recorded-gh-fallback-token') "$runnerName baseline log does not contain credential values"
        Assert-True $withoutExecution[0].stdin_exact "$runnerName baseline receives exact prompt bytes"
        if ($runnerName -eq 'copilot') {
            Assert-True $withoutExecution[0].repository_agents_visible 'Copilot baseline sees the same staged AGENTS.md instruction'
            Assert-True $withoutExecution[0].repository_copilot_instructions_visible 'Copilot baseline sees the same staged repository instruction'
            Assert-True (-not $withoutExecution[0].candidate_skill_staged) 'Copilot baseline does not receive the candidate skill directory'
            Assert-True (-not $withoutExecution[0].ambient_copilot_instructions_visible) 'Copilot baseline excludes the ambient personal instruction'
            Assert-True (($resultWithout | ConvertTo-Json -Depth 100) -notmatch 'recorded-canary|recorded-unrelated-canary|recorded-copilot-canary|recorded-gh-canary|recorded-github-canary|recorded-gh-fallback-token') 'Copilot baseline result evidence does not contain credential values'
        }
    }
    $scriptedInteraction = [ordered]@{
        schema = (Get-RunnerSchemaNames).Interaction
        mode = 'scripted'
        turns = @(
            [ordered]@{ role = 'user'; content = 'recorded scripted turn one' }
            [ordered]@{ role = 'user'; source = 'future-turn/turn-2.txt' }
        )
    }
    foreach ($runnerName in @('copilot', 'opencode')) {
        $scriptedIteration = Join-Path $recordedRoot ("scripted-{0}" -f $runnerName)
        New-Item -ItemType Directory -Path $scriptedIteration -Force | Out-Null
        $scriptedWith = New-TestRun -IterationDirectory $scriptedIteration -Configuration with_skill -EvalName 'scripted-conformance' -Interaction $scriptedInteraction
        $scriptedWithout = New-TestRun -IterationDirectory $scriptedIteration -Configuration without_skill -EvalName 'scripted-conformance' -Interaction $scriptedInteraction
        foreach ($scriptedRun in @($scriptedWith, $scriptedWithout)) {
            [IO.File]::WriteAllText((Join-Path $scriptedRun.Root 'home\scripted-session-fixture'), 'fixture', [Text.UTF8Encoding]::new($false))
            if ($runnerName -eq 'copilot') { [IO.File]::WriteAllText((Join-Path $scriptedRun.Root 'home\copilot-exact-session-help'), 'fixture', [Text.UTF8Encoding]::new($false)) }
            if ($runnerName -eq 'opencode') { [IO.File]::WriteAllText((Join-Path $scriptedRun.Root 'home\opencode-timing-fixture'), 'fixture', [Text.UTF8Encoding]::new($false)) }
            Add-TestInteractionSources -TestRun $scriptedRun
        }
        if ($runnerName -eq 'opencode') {
            $preexistingOpenCodeIgnore = Join-Path $scriptedWith.Root 'repo\.opencode\.gitignore'
            New-Item -ItemType Directory -Path (Split-Path -Parent $preexistingOpenCodeIgnore) -Force | Out-Null
            [IO.File]::WriteAllText($preexistingOpenCodeIgnore, 'fixture-existing', [Text.UTF8Encoding]::new($false))
        }
        $scriptedRunnerRelativePath = if ($runnerName -eq 'copilot') { 'github-copilot\runner.ps1' } else { 'opencode\runner.ps1' }
        $scriptedRunnerPath = Join-Path $runnerRoot $scriptedRunnerRelativePath
        $scriptedPreflight = Invoke-AdapterJson -RunnerPath $scriptedRunnerPath -Command preflight -RunPath $scriptedWith.Path -ProfilePath $recordedProfiles[$runnerName]
        Assert-Equal 'compatible' $scriptedPreflight.status "$runnerName scripted preflight: $([string]::Join('; ', @($scriptedPreflight.reasons)))"
        Assert-Equal 'supported' $scriptedPreflight.resolved_capabilities.scripted_multi_turn_same_session "$runnerName scripted same-session capability is supported only after deterministic proof"
        Assert-True ([bool]$scriptedPreflight.protocol_observations.scripted_multi_turn_same_session.available) "$runnerName records deterministic scripted same-session proof"
        Assert-True (-not [bool]$scriptedPreflight.protocol_observations.scripted_multi_turn_same_session.implicit_continuation) "$runnerName rejects implicit continuation in the protocol observation"
        $scriptedResult = Invoke-AdapterJson -RunnerPath $scriptedRunnerPath -Command execute -RunPath $scriptedWith.Path -ProfilePath $recordedProfiles[$runnerName]
        [void](Assert-ExecutionResult -Result $scriptedResult)
        Assert-Equal 'completed' $scriptedResult.status "$runnerName exact-session scripted execution completes"
        [void](Assert-InteractionResultEvidence -ExecutionResult $scriptedResult -RunData (Resolve-RunContract -RunPath $scriptedWith.Path))
        Assert-True ([bool]$scriptedResult.evidence.interaction.same_session) "$runnerName scripted result proves one same session"
        Assert-Equal 2 @($scriptedResult.evidence.interaction.native_turns).Count "$runnerName records both native turns"
        Assert-Equal ([string]$scriptedResult.session.id) ([string]$scriptedResult.evidence.interaction.session_id) "$runnerName shared interaction evidence uses the result session id"
        Assert-True ([bool]$scriptedResult.evidence.capture.complete_structured_transcript) "$runnerName records a complete structured multi-turn transcript"
        Assert-Equal 1 $scriptedResult.evidence.delegation.model_execution_count "$runnerName keeps one runner-owned model execution worker across scripted invocations"
        $nativeTurns = @($scriptedResult.evidence.interaction.native_turns)
        $firstNativeTurn = $nativeTurns[0]
        $secondNativeTurn = $nativeTurns[1]
        if ($runnerName -eq 'opencode') {
            Assert-True ($scriptedResult.evidence.PSObject.Properties.Name -notcontains 'exact_session_continuation') 'OpenCode scripted result removes the broken CLI continuation evidence shape'
            Assert-Equal 'opencode-server-synchronous-http' $scriptedResult.evidence.interaction.transport 'OpenCode scripted result records server transport'
            Assert-Equal '127.0.0.1' $scriptedResult.evidence.server.bind 'OpenCode server binds only to loopback'
            Assert-True (-not [bool]$scriptedResult.evidence.future_turn_secrecy.interaction_json_projected) 'OpenCode interaction.json is absent from the physical projection'
            Assert-True (-not [bool]$scriptedResult.evidence.future_turn_secrecy.future_source_files_projected) 'OpenCode future source files are absent from the physical projection'
            Assert-True (-not [bool]$scriptedResult.evidence.future_turn_secrecy.canary_in_physical_projection) 'OpenCode future-turn canary is absent from the physical projection'
            Assert-True (-not [bool]$scriptedResult.evidence.future_turn_secrecy.canary_in_environment) 'OpenCode future-turn canary is absent from the server environment'
            Assert-True (-not [bool]$scriptedResult.evidence.future_turn_secrecy.canary_in_server_arguments) 'OpenCode future-turn canary is absent from server arguments'
            Assert-True (-not [bool]$scriptedResult.evidence.future_turn_secrecy.turn_1_request_contains_future_canary) 'OpenCode turn 1 request cannot discover the future-turn canary'
            Assert-True ([bool]$scriptedResult.evidence.future_turn_secrecy.turn_2_sent_only_after_turn_1_http_completed) 'OpenCode turn 2 is sent only after turn 1 HTTP completion'
            Assert-Equal ([string]$scriptedResult.session.id) ([string]$firstNativeTurn.exact_session_id) 'OpenCode turn 1 uses the created exact session'
            Assert-Equal ([string]$firstNativeTurn.exact_session_id) ([string]$secondNativeTurn.exact_session_id) 'OpenCode all scripted turns use one exact session'
            Assert-Equal ([string]$firstNativeTurn.session_id) ([string]$secondNativeTurn.session_id) 'OpenCode response session identity remains stable'
            Assert-True ([bool]$firstNativeTurn.session_id_match -and [bool]$secondNativeTurn.session_id_match) 'OpenCode validates response session identity on every turn'
            Assert-True ([bool]$firstNativeTurn.terminal_http_response -and [bool]$secondNativeTurn.terminal_http_response) 'OpenCode synchronous HTTP responses are terminal turn evidence'
            Assert-Equal ([string]$firstNativeTurn.requested_model) ([string]$secondNativeTurn.requested_model) 'OpenCode supplies the exact requested model on every turn'
            Assert-Equal 'opencode/muse-spark-1.2-contributor-free' $firstNativeTurn.requested_model 'OpenCode preserves the complete provider/model selector'
            Assert-Equal 'opencode' $firstNativeTurn.requested_provider 'OpenCode supplies the provider selector on turn 1'
            Assert-Equal 'muse-spark-1.2-contributor-free' $firstNativeTurn.requested_model_id 'OpenCode supplies the model id on turn 1'
            Assert-Equal $firstNativeTurn.requested_model $firstNativeTurn.observed_model 'OpenCode proves the observed model on turn 1'
            Assert-Equal $secondNativeTurn.requested_model $secondNativeTurn.observed_model 'OpenCode proves the observed model on turn 2'
            Assert-True (-not [bool]$firstNativeTurn.request_contains_future_canary) 'OpenCode turn 1 request body excludes future input'
            Assert-True ([bool]$secondNativeTurn.assistant_text -and [bool]$secondNativeTurn.request_contains_future_canary) 'OpenCode turn 2 request carries only its now-visible future input'
            Assert-True ([string]$firstNativeTurn.path -match ('/session/' + [regex]::Escape([string]$scriptedResult.session.id) + '/message')) 'OpenCode turn 1 targets the exact session message path'
            Assert-True ([string]$secondNativeTurn.path -match ('/session/' + [regex]::Escape([string]$scriptedResult.session.id) + '/message')) 'OpenCode turn 2 targets the exact session message path'
            Assert-Equal 'fresh_session_http' $scriptedResult.evidence.timing.turns[0].invocation 'OpenCode timing labels turn 1 as a fresh session HTTP request'
            Assert-Equal 'same_session_http' $scriptedResult.evidence.timing.turns[1].invocation 'OpenCode timing labels turn 2 as same-session HTTP'
            Assert-True ($scriptedResult.evidence.interaction.sse_dependency -eq $false -and $scriptedResult.evidence.interaction.session_status_dependency -eq $false) 'OpenCode completion does not depend on SSE or session idle status'
            $scriptedLogPath = Join-Path $scriptedWith.Root 'repo\opencode-fake-cli-log.jsonl'
            $scriptedRecords = @(Get-Content -LiteralPath $scriptedLogPath | ForEach-Object { $_ | ConvertFrom-Json })
            Assert-Equal 1 @($scriptedRecords | Where-Object { $_.invocation_kind -eq 'server_start' }).Count 'OpenCode starts exactly one owned server per scripted execution'
            Assert-Equal 2 @($scriptedRecords | Where-Object { $_.invocation_kind -eq 'server_message' }).Count 'OpenCode sends exactly two synchronous server messages'
            Assert-True (@($scriptedRecords | Where-Object { $_.invocation_kind -eq 'server_message' -and $_.request_text -match 'CODEBELT_FUTURE_TURN_CANARY_' }).Count -eq 1) 'OpenCode fake server observes the future canary only in turn 2'
            Assert-True (@($scriptedRecords | Where-Object { $_.invocation_kind -eq 'server_message' -and $_.request_model.providerID -eq 'opencode' -and $_.request_model.modelID -eq 'muse-spark-1.2-contributor-free' }).Count -eq 2) 'OpenCode fake server observes exact model fields on every turn'
            Assert-True (@($scriptedRecords | Where-Object { $_.invocation_kind -eq 'server_message' -and $_.session_id -eq [string]$scriptedResult.session.id }).Count -eq 2) 'OpenCode fake server observes one exact session id on every turn'
            Assert-True (-not (@($scriptedRecords | Where-Object { $_.invocation_kind -eq 'server_start' } | ForEach-Object { $_.server_arguments } | Where-Object { $_ -contains '--session' })) ) 'OpenCode server startup never receives CLI session continuation'
            Assert-True (-not (Test-Path -LiteralPath (Join-Path $scriptedWith.Root 'repo\.opencode\node_modules') -PathType Container)) 'OpenCode runtime node_modules does not leak into the logical fixture'
            Assert-True (Test-Path -LiteralPath (Join-Path $scriptedWith.Root 'repo\.opencode\.gitignore') -PathType Leaf) 'OpenCode pre-existing .opencode/.gitignore remains in the logical fixture'
            Assert-Equal 'runtime' (Get-Content -LiteralPath (Join-Path $scriptedWith.Root 'repo\.opencode\.gitignore') -Raw).Trim() 'OpenCode legitimate pre-existing .opencode mutation synchronizes into the logical fixture'
            Assert-True (-not (Test-Path -LiteralPath (Join-Path $scriptedWith.Root 'repo\.opencode\skills\candidate') -PathType Container)) 'OpenCode candidate skill is removed before copy-back'
            Assert-True (-not (Test-Path -LiteralPath (Join-Path $scriptedWithout.Root 'repo\.opencode\.gitignore') -PathType Leaf)) 'OpenCode newly generated .opencode/.gitignore is excluded from copy-back when absent initially'
            Assert-True (Test-Path -LiteralPath (Join-Path $scriptedWith.Root 'repo\normal-task-output.snk') -PathType Leaf) 'OpenCode normal task output synchronizes into the logical fixture'

            # Repeat the same server transport against the baseline arm. The
            # future-input boundary and runtime copy-back rules must hold with
            # and without the candidate skill.
            $baselinePreflight = Invoke-AdapterJson -RunnerPath $scriptedRunnerPath -Command preflight -RunPath $scriptedWithout.Path -ProfilePath $recordedProfiles[$runnerName]
            Assert-Equal 'compatible' $baselinePreflight.status 'OpenCode baseline scripted preflight is compatible'
            Assert-Equal 'supported' $baselinePreflight.resolved_capabilities.scripted_multi_turn_same_session 'OpenCode baseline advertises server scripted capability'
            $baselineResult = Invoke-AdapterJson -RunnerPath $scriptedRunnerPath -Command execute -RunPath $scriptedWithout.Path -ProfilePath $recordedProfiles[$runnerName]
            [void](Assert-ExecutionResult -Result $baselineResult)
            Assert-Equal 'completed' $baselineResult.status 'OpenCode baseline scripted execution completes'
            [void](Assert-InteractionResultEvidence -ExecutionResult $baselineResult -RunData (Resolve-RunContract -RunPath $scriptedWithout.Path))
            Assert-True ([bool]$baselineResult.evidence.interaction.same_session) 'OpenCode baseline proves one same session'
            Assert-Equal 2 @($baselineResult.evidence.interaction.native_turns).Count 'OpenCode baseline records both native turns'
            Assert-True (-not [bool]$baselineResult.evidence.future_turn_secrecy.interaction_json_projected -and
                -not [bool]$baselineResult.evidence.future_turn_secrecy.future_source_files_projected -and
                -not [bool]$baselineResult.evidence.future_turn_secrecy.canary_in_physical_projection -and
                -not [bool]$baselineResult.evidence.future_turn_secrecy.canary_in_environment -and
                -not [bool]$baselineResult.evidence.future_turn_secrecy.canary_in_server_arguments -and
                -not [bool]$baselineResult.evidence.future_turn_secrecy.turn_1_request_contains_future_canary) 'OpenCode baseline keeps future input out of repo/home/config/env/args and turn 1'
            Assert-True ([bool]$baselineResult.evidence.future_turn_secrecy.turn_2_sent_only_after_turn_1_http_completed) 'OpenCode baseline sends turn 2 only after turn 1 HTTP completion'
            $baselineLogPath = Join-Path $scriptedWithout.Root 'repo\opencode-fake-cli-log.jsonl'
            $baselineRecords = @(Get-Content -LiteralPath $baselineLogPath | ForEach-Object { $_ | ConvertFrom-Json })
            Assert-Equal 1 @($baselineRecords | Where-Object { $_.invocation_kind -eq 'server_start' }).Count 'OpenCode baseline starts exactly one owned server'
            Assert-Equal 2 @($baselineRecords | Where-Object { $_.invocation_kind -eq 'server_message' }).Count 'OpenCode baseline sends exactly two synchronous messages'
            Assert-True (@($baselineRecords | Where-Object { $_.invocation_kind -eq 'server_message' -and $_.request_text -match 'CODEBELT_FUTURE_TURN_CANARY_' }).Count -eq 1) 'OpenCode baseline exposes the future canary only in turn 2'
            Assert-True (@($baselineRecords | Where-Object { $_.invocation_kind -eq 'server_message' -and $_.request_model.providerID -eq 'opencode' -and $_.request_model.modelID -eq 'muse-spark-1.2-contributor-free' }).Count -eq 2) 'OpenCode baseline supplies exact model fields on every turn'
            Assert-True (@($baselineRecords | Where-Object { $_.invocation_kind -eq 'server_message' -and $_.session_id -eq [string]$baselineResult.session.id }).Count -eq 2) 'OpenCode baseline keeps one exact session id on every turn'
            Assert-True (-not (Test-Path -LiteralPath (Join-Path $scriptedWithout.Root 'repo\.opencode\node_modules') -PathType Container)) 'OpenCode baseline runtime node_modules does not leak into the logical fixture'
            Assert-True (-not (Test-Path -LiteralPath (Join-Path $scriptedWithout.Root 'repo\.opencode\.gitignore') -PathType Leaf)) 'OpenCode baseline generated .opencode/.gitignore is excluded from copy-back'
            Assert-True (Test-Path -LiteralPath (Join-Path $scriptedWithout.Root 'repo\normal-task-output.snk') -PathType Leaf) 'OpenCode baseline normal task output synchronizes into the logical fixture'
        } else {
            Assert-Equal ([string]$scriptedResult.session.id) ([string]$scriptedResult.evidence.exact_session_continuation.exact_session_id) "$runnerName exact continuation evidence uses the captured session id"
            Assert-True ([bool]$scriptedResult.evidence.exact_session_continuation.turns_started_after_prior_terminal) "$runnerName starts continuation only after a terminal first turn"
            Assert-Equal 'fresh' $firstNativeTurn.invocation "$runnerName turn 1 is fresh"
            Assert-Equal 'explicit_session_resume' $secondNativeTurn.invocation "$runnerName turn 2 explicitly resumes"
            Assert-Equal ([string]$firstNativeTurn.session_id) ([string]$secondNativeTurn.session_id) "$runnerName native turn evidence has one session id"
            Assert-True (-not [string]::IsNullOrWhiteSpace([string]$firstNativeTurn.session_id)) "$runnerName captures an exact session id from turn 1 structured events"
            Assert-Equal ([string]$firstNativeTurn.session_id) ([string]$secondNativeTurn.target_session_id) "$runnerName turn 2 targets turn 1's exact session id"
            Assert-True ([bool]$secondNativeTurn.target_session_match) "$runnerName turn 2 native session identity matches its target"
            Assert-Equal ([string]$firstNativeTurn.working_directory) ([string]$secondNativeTurn.working_directory) "$runnerName preserves the working directory across turns"
            Assert-Equal ([string]$firstNativeTurn.home) ([string]$secondNativeTurn.home) "$runnerName preserves the isolated home across turns"
            Assert-Equal ([string]$firstNativeTurn.requested_model) ([string]$secondNativeTurn.requested_model) "$runnerName preserves the requested model across turns"
            Assert-True (@($firstNativeTurn.observed_models | Where-Object { [string]$_ -eq [string]$firstNativeTurn.requested_model }).Count -gt 0) "$runnerName records the requested model in first-turn structured evidence"
            Assert-True (@($secondNativeTurn.observed_models | Where-Object { [string]$_ -eq [string]$secondNativeTurn.requested_model }).Count -gt 0) "$runnerName records the requested model in resumed-turn structured evidence"
            Assert-Equal 0 $firstNativeTurn.exit_code "$runnerName first turn exits cleanly"
            Assert-Equal 0 $secondNativeTurn.exit_code "$runnerName resumed turn exits cleanly"
            Assert-True ([bool]$firstNativeTurn.terminal -and [bool]$secondNativeTurn.terminal) "$runnerName records terminal native turn evidence"
            Assert-True ([bool]$firstNativeTurn.terminal_assistant_response -and [bool]$firstNativeTurn.terminal_event_observed) "$runnerName proves turn 1 has a terminal assistant response before continuation"
            Assert-True ([bool]$secondNativeTurn.terminal_assistant_response -and [bool]$secondNativeTurn.terminal_event_observed) "$runnerName proves the resumed turn has a terminal assistant response"
            Assert-True ([DateTime]::Compare([DateTime]$firstNativeTurn.finished_utc, [DateTime]$secondNativeTurn.started_utc) -le 0) "$runnerName starts turn 2 after turn 1 finishes"
            Assert-True @($firstNativeTurn.event_timestamps).Count -gt 0 "$runnerName records first-turn event timestamps"
            Assert-True @($secondNativeTurn.event_timestamps).Count -gt 0 "$runnerName records second-turn event timestamps"
            Assert-Equal ([string]$firstNativeTurn.copilot_home) ([string]$secondNativeTurn.copilot_home) "$runnerName preserves the isolated COPILOT_HOME across turns"
            $firstArgs = @($firstNativeTurn.arguments)
            $secondArgs = @($secondNativeTurn.arguments)
            Assert-True ($firstArgs -notcontains '--resume') "$runnerName fresh turn does not carry a continuation flag"
            Assert-True ($secondArgs -contains '--resume') "$runnerName resumed turn carries its explicit continuation flag"
            Assert-True ($firstArgs -notcontains '--continue' -and $secondArgs -notcontains '--continue') "$runnerName never uses implicit last-session continuation"
            $continuationIndex = [Array]::IndexOf([string[]]$secondArgs, '--resume')
            Assert-Equal ([string]$firstNativeTurn.session_id) ([string]$secondArgs[$continuationIndex + 1]) "$runnerName resumed invocation passes the exact captured session id"
        }
        if ($runnerName -eq 'opencode') {
            $scriptedLogPath = Join-Path $scriptedWith.Root 'repo\opencode-fake-cli-log.jsonl'
            $scriptedRecords = @(Get-Content -LiteralPath $scriptedLogPath | ForEach-Object { $_ | ConvertFrom-Json })
        } else {
            $scriptedLogPath = Join-Path $scriptedWith.Root ("repo\{0}-fake-cli-log.jsonl" -f $runnerName)
            $scriptedRecords = @(Get-Content -LiteralPath $scriptedLogPath | ForEach-Object { $_ | ConvertFrom-Json })
            $scriptedExecutions = @($scriptedRecords | Where-Object { $_.stdin_received -eq $true })
            Assert-Equal 2 $scriptedExecutions.Count "$runnerName scripted transport starts exactly two recorded invocations"
            Assert-Equal ([string]$firstNativeTurn.session_id) ([string]$scriptedExecutions[1].continuation_session_id) "$runnerName recorded transport receives the exact session id on turn 2"
            Assert-True ([bool]$scriptedExecutions[0].stdin_exact -and [bool]$scriptedExecutions[1].stdin_exact) "$runnerName sends both scripted turn inputs through stdin"
        }
        $scriptedFailureValidation = Test-NativeWorkerTerminalEvidence -ExecutionEvidence $scriptedResult -Run (Resolve-RunContract -RunPath $scriptedWith.Path) -RequestedModel ([string]$scriptedResult.requested.model) -ExpectedWorkerSessionId ([string]$scriptedResult.session.id) -ExpectedMechanism ([string]$scriptedResult.evidence.delegation.mechanism)
        Assert-True ([bool]$scriptedFailureValidation.Valid) "$runnerName scripted result satisfies the shared native terminal evidence contract"
        if ($runnerName -eq 'opencode') {
            Assert-Equal 'authoritative_cached_preflight' $scriptedResult.evidence.timing.preflight_source 'OpenCode scripted execution reuses the authoritative same-run preflight observation'
            Assert-Equal 6 $scriptedResult.evidence.timing.preflight.probe_count 'OpenCode preflight records version, effective-home, run-help, debug-help, debug-config, and serve-help probes'
            Assert-True ([double]$scriptedResult.evidence.timing.preflight.version_probe_duration_seconds -gt 0) 'OpenCode preflight records version probe duration'
            Assert-True ([double]$scriptedResult.evidence.timing.preflight.help_probe_duration_seconds -gt 0) 'OpenCode preflight records help probe duration'
            Assert-Equal 2 @($scriptedResult.evidence.timing.turns).Count 'OpenCode timing evidence records both scripted turns'
            $firstTiming = @($scriptedResult.evidence.timing.turns)[0]
            $secondTiming = @($scriptedResult.evidence.timing.turns)[1]
            Assert-Equal 'fresh_session_http' $firstTiming.invocation 'OpenCode timing evidence labels turn 1 as a fresh session HTTP request'
            Assert-Equal 'same_session_http' $secondTiming.invocation 'OpenCode timing evidence labels turn 2 as same-session HTTP'
            Assert-True ([double]$firstTiming.http_duration_seconds -ge 0 -and [double]$secondTiming.http_duration_seconds -ge 0) 'OpenCode timing evidence records both synchronous HTTP durations'
            $timingRecords = @(Get-Content -LiteralPath (Join-Path $scriptedWith.Root 'repo\opencode-fake-cli-log.jsonl') | ForEach-Object { $_ | ConvertFrom-Json })
            Assert-Equal 1 @($timingRecords | Where-Object { $_.invocation_kind -eq 'version_probe' }).Count 'OpenCode performs one version probe for the preflight/execute pair'
            Assert-Equal 1 @($timingRecords | Where-Object { $_.invocation_kind -eq 'help_probe' }).Count 'OpenCode performs one help probe for the preflight/execute pair'
            Assert-Equal 1 @($timingRecords | Where-Object { $_.invocation_kind -eq 'serve_help_probe' }).Count 'OpenCode performs one serve-help probe for the preflight/execute pair'
            Assert-Equal 1 @($timingRecords | Where-Object { $_.invocation_kind -eq 'debug_help_probe' }).Count 'OpenCode performs one model-free debug-help probe for the preflight/execute pair'
            Assert-Equal 1 @($timingRecords | Where-Object { $_.invocation_kind -eq 'debug_config_probe' }).Count 'OpenCode performs one model-free debug-config probe for the preflight/execute pair'
        }
    }
    $isolatedHomeFailureIteration = Join-Path $recordedRoot 'opencode-isolation-failure'
    New-Item -ItemType Directory -Path $isolatedHomeFailureIteration -Force | Out-Null
    $isolatedHomeFailureRun = New-TestRun -IterationDirectory $isolatedHomeFailureIteration -Configuration without_skill -EvalName 'opencode-isolation-failure'
    [IO.File]::WriteAllText((Join-Path $isolatedHomeFailureRun.Root 'home\opencode-fake-home'), 'fixture', [Text.UTF8Encoding]::new($false))
    $failureOldPath = $env:PATH
    $recordedNodeCommand = Resolve-ExternalCommand -Name 'node'
    $recordedNodeDirectory = if ($null -eq $recordedNodeCommand) { $null } else { Split-Path -Parent ([string]$recordedNodeCommand.Source) }
    $failurePathParts = @($failureOldPath -split [regex]::Escape([string][IO.Path]::PathSeparator) | Where-Object {
            -not [string]::IsNullOrWhiteSpace([string]$_) -and
            ([string]::IsNullOrWhiteSpace([string]$recordedNodeDirectory) -or -not [string]::Equals(
                ([IO.Path]::GetFullPath([string]$_)).TrimEnd([char[]]@('\', '/')),
                ([IO.Path]::GetFullPath([string]$recordedNodeDirectory)).TrimEnd([char[]]@('\', '/')),
                [StringComparison]::OrdinalIgnoreCase
            ))
        })
    $env:PATH = [string]::Join([IO.Path]::PathSeparator, @($fakeBin) + @($failurePathParts))
    try {
        $failedPreflight = Invoke-AdapterJson -RunnerPath (Join-Path $runnerRoot 'opencode\runner.ps1') -Command preflight -RunPath $isolatedHomeFailureRun.Path -ProfilePath $recordedProfiles['opencode']
        Assert-Equal 'incompatible' $failedPreflight.status 'OpenCode fails preflight when the model-free runtime-home probe resolves the fake ambient profile'
        Assert-True (@($failedPreflight.checks | Where-Object { $_.name -eq 'effective_home' -and $_.status -eq 'failed' }).Count -eq 1) 'OpenCode marks the effective-home check failed for the fake profile'
        $failedResult = Invoke-AdapterJson -RunnerPath (Join-Path $runnerRoot 'opencode\runner.ps1') -Command execute -RunPath $isolatedHomeFailureRun.Path -ProfilePath $recordedProfiles['opencode']
        Assert-Equal 'incompatible' $failedResult.status 'OpenCode execution remains incompatible after effective-home failure'
        Assert-Equal 'preflight_incompatible' $failedResult.final_response.reason 'OpenCode reports the fail-closed preflight isolation reason'
        $failedLogPath = Join-Path $isolatedHomeFailureRun.Root 'repo\opencode-fake-cli-log.jsonl'
        if (Test-Path -LiteralPath $failedLogPath -PathType Leaf) {
            $failedRecords = @(Get-Content -LiteralPath $failedLogPath | ForEach-Object { $_ | ConvertFrom-Json })
            Assert-Equal 0 @($failedRecords | Where-Object { $_.stdin_received -eq $true }).Count 'OpenCode effective-home failure starts zero model executions'
        }
    } finally {
        $env:PATH = $failureOldPath
    }
    Invoke-OpenCodeHttpTimeoutRegression -RecordedRoot $recordedRoot
    foreach ($runnerName in @('copilot')) {
        $unsupportedIteration = Join-Path $recordedRoot ("unsupported-scripted-{0}" -f $runnerName)
        New-Item -ItemType Directory -Path $unsupportedIteration -Force | Out-Null
        $unsupportedRun = New-TestRun -IterationDirectory $unsupportedIteration -Configuration with_skill -EvalName 'unsupported-scripted' -Interaction $scriptedInteraction
        Add-TestInteractionSources -TestRun $unsupportedRun
        [IO.File]::WriteAllText((Join-Path $unsupportedRun.Root 'home\scripted-session-fixture'), 'fixture', [Text.UTF8Encoding]::new($false))
        [IO.File]::WriteAllText((Join-Path $unsupportedRun.Root 'home\copilot-no-exact-session-help'), 'fixture', [Text.UTF8Encoding]::new($false))
        $unsupportedRunnerRelativePath = if ($runnerName -eq 'copilot') { 'github-copilot\runner.ps1' } else { 'opencode\runner.ps1' }
        $unsupportedRunnerPath = Join-Path $runnerRoot $unsupportedRunnerRelativePath
        $unsupportedPreflight = Invoke-AdapterJson -RunnerPath $unsupportedRunnerPath -Command preflight -RunPath $unsupportedRun.Path -ProfilePath $recordedProfiles[$runnerName]
        Assert-Equal 'incompatible' $unsupportedPreflight.status "$runnerName unsupported exact-session help fails preflight"
        Assert-Equal 'unsupported' $unsupportedPreflight.resolved_capabilities.scripted_multi_turn_same_session "$runnerName unsupported continuation is not advertised as supported"
        Assert-True (@($unsupportedPreflight.checks | Where-Object { $_.name -eq 'scripted_multi_turn_same_session' -and $_.status -eq 'failed' }).Count -eq 1) "$runnerName records a failed scripted continuation preflight check"
        Assert-True (([string]$unsupportedPreflight.protocol_observations.scripted_multi_turn_same_session.reason) -match '(?i)explicit|session|implicit') "$runnerName explains why implicit or ambiguous continuation is rejected"
        $unsupportedResult = Invoke-AdapterJson -RunnerPath $unsupportedRunnerPath -Command execute -RunPath $unsupportedRun.Path -ProfilePath $recordedProfiles[$runnerName]
        [void](Assert-ExecutionResult -Result $unsupportedResult)
        Assert-Equal 'incompatible' $unsupportedResult.status "$runnerName unsupported continuation never executes"
        $unsupportedLogPath = Join-Path $unsupportedRun.Root ("repo\{0}-fake-cli-log.jsonl" -f $runnerName)
        $unsupportedRecords = @(Get-Content -LiteralPath $unsupportedLogPath | ForEach-Object { $_ | ConvertFrom-Json })
        Assert-Equal 0 @($unsupportedRecords | Where-Object { $_.stdin_received -eq $true }).Count "$runnerName unsupported continuation starts zero model invocations"
    }
    foreach ($runnerName in @('copilot', 'opencode')) {
        foreach ($failureMarker in @('scripted-no-session-first', 'scripted-session-mismatch', 'scripted-no-terminal-first')) {
            $failureIteration = Join-Path $recordedRoot ("scripted-failure-{0}-{1}" -f $runnerName, ($failureMarker -replace '^scripted-', ''))
            New-Item -ItemType Directory -Path $failureIteration -Force | Out-Null
            $failureRun = New-TestRun -IterationDirectory $failureIteration -Configuration with_skill -EvalName 'scripted-failure' -Interaction $scriptedInteraction
            Add-TestInteractionSources -TestRun $failureRun
            [IO.File]::WriteAllText((Join-Path $failureRun.Root 'home\scripted-session-fixture'), 'fixture', [Text.UTF8Encoding]::new($false))
            if ($runnerName -eq 'copilot') { [IO.File]::WriteAllText((Join-Path $failureRun.Root 'home\copilot-exact-session-help'), 'fixture', [Text.UTF8Encoding]::new($false)) }
            [IO.File]::WriteAllText((Join-Path $failureRun.Root ("home\{0}" -f $failureMarker)), 'fixture', [Text.UTF8Encoding]::new($false))
            $failureRunnerRelativePath = if ($runnerName -eq 'copilot') { 'github-copilot\runner.ps1' } else { 'opencode\runner.ps1' }
            $failureRunnerPath = Join-Path $runnerRoot $failureRunnerRelativePath
            $failureResult = Invoke-AdapterJson -RunnerPath $failureRunnerPath -Command execute -RunPath $failureRun.Path -ProfilePath $recordedProfiles[$runnerName]
            [void](Assert-ExecutionResult -Result $failureResult)
            Assert-Equal 'incompatible' $failureResult.status "$runnerName $failureMarker fails closed"
            $expectedFailureCode = if ($runnerName -eq 'opencode' -and $failureMarker -eq 'scripted-no-terminal-first') { 'terminal_response_invalid' } else { switch ($failureMarker) { 'scripted-no-session-first' { 'session_id_unobservable' } 'scripted-session-mismatch' { 'session_identity_mismatch' } 'scripted-no-terminal-first' { 'terminal_turn_status' } } }
            Assert-True (@($failureResult.evidence.native_worker_evidence_failures | Where-Object { $_ -eq $expectedFailureCode }).Count -gt 0) "$runnerName $failureMarker records the native interaction failure"
            $failureLogPath = Join-Path $failureRun.Root ("repo\{0}-fake-cli-log.jsonl" -f $runnerName)
            $failureRecords = @(Get-Content -LiteralPath $failureLogPath | ForEach-Object { $_ | ConvertFrom-Json })
            if ($runnerName -eq 'opencode') {
                $failureMessages = @($failureRecords | Where-Object { $_.invocation_kind -eq 'server_message' })
                $expectedFailureMessages = if ($failureMarker -eq 'scripted-no-session-first') { 0 } else { 1 }
                Assert-Equal 1 @($failureRecords | Where-Object { $_.invocation_kind -eq 'server_start' }).Count "OpenCode $failureMarker starts one owned server"
                Assert-Equal $expectedFailureMessages $failureMessages.Count "OpenCode $failureMarker stops after the first unproven server response"
            } else {
                $failureExecutions = @($failureRecords | Where-Object { $_.stdin_received -eq $true })
                $expectedFailureExecutions = if ($failureMarker -eq 'scripted-session-mismatch') { 2 } else { 1 }
                Assert-Equal $expectedFailureExecutions $failureExecutions.Count "$runnerName $failureMarker does not continue after an unproven first turn"
            }
        }
    }
    $serialOpenCodeProfile = Join-Path $recordedRoot 'opencode-serial-profile.json'
    $serialOpenCodeData = Read-RunnerJson -Path $recordedProfiles['opencode']
    $serialOpenCodeData.concurrency = 1
    Write-TestJson -Path $serialOpenCodeProfile -Value $serialOpenCodeData
    $serialOpenCodePreflight = Invoke-AdapterJson -RunnerPath (Join-Path $runnerRoot 'opencode\runner.ps1') -Command preflight -RunPath $with.Path -ProfilePath $serialOpenCodeProfile
    Assert-Equal 'incompatible' $serialOpenCodePreflight.status 'OpenCode rejects a serial execution profile'
    Assert-True (@($serialOpenCodePreflight.reasons | Where-Object { $_ -match 'concurrency >= 2|Sequential dispatch' }).Count -gt 0) 'OpenCode serial-profile failure explains the concurrency requirement'
    $staleCli = $fakeCli.Replace("'opencode' { '--format --dir --model --auto --pure --continue --session' }", "'opencode' { '--format --dir --model --pure --continue --session' }")
    [System.IO.File]::WriteAllText((Join-Path $fakeBin 'opencode.ps1'), $staleCli, [System.Text.UTF8Encoding]::new($false))
    $stalePreflight = Invoke-AdapterJson -RunnerPath (Join-Path $runnerRoot 'opencode\runner.ps1') -Command preflight -RunPath $with.Path -ProfilePath $recordedProfiles['opencode']
    Assert-Equal 'incompatible' $stalePreflight.status 'stale OpenCode help contract is rejected during preflight'
    Assert-True (@($stalePreflight.reasons | Where-Object { $_ -match '--auto' }).Count -gt 0) 'stale OpenCode option failure identifies the missing flag'
    [System.IO.File]::WriteAllText((Join-Path $fakeBin 'opencode.ps1'), $fakeCli, [System.Text.UTF8Encoding]::new($false))
    $fileAuthHome = Join-Path $recordedRoot 'codex-file-auth'
    New-Item -ItemType Directory -Path $fileAuthHome -Force | Out-Null
    [System.IO.File]::WriteAllText((Join-Path $fileAuthHome 'auth.json'), '{"canary":"not-logged"}', [System.Text.UTF8Encoding]::new($false))
    [System.IO.File]::WriteAllText((Join-Path $fileAuthHome 'config.toml'), 'model = "ambient-not-used"', [System.Text.UTF8Encoding]::new($false))
    New-Item -ItemType Directory -Path (Join-Path $fileAuthHome 'skills'), (Join-Path $fileAuthHome 'agents'), (Join-Path $fileAuthHome 'sessions'), (Join-Path $fileAuthHome 'memories'), (Join-Path $fileAuthHome 'plugins'), (Join-Path $fileAuthHome 'mcp') -Force | Out-Null
    [System.IO.File]::WriteAllText((Join-Path $fileAuthHome 'skills\ambient.md'), 'ambient skill must not be copied', [System.Text.UTF8Encoding]::new($false))
    [System.IO.File]::WriteAllText((Join-Path $fileAuthHome 'agents\ambient.md'), 'ambient agent must not be copied', [System.Text.UTF8Encoding]::new($false))
    [System.IO.File]::WriteAllText((Join-Path $fileAuthHome 'mcp.json'), '{"ambient":true}', [System.Text.UTF8Encoding]::new($false))
    [System.IO.File]::WriteAllText((Join-Path $fileAuthHome 'AGENTS.md'), 'ambient instructions must not be copied', [System.Text.UTF8Encoding]::new($false))
    $env:OPENAI_API_KEY = $null
    $env:CODEX_HOME = $fileAuthHome
    $fileAuthPreflight = Invoke-AdapterJson -RunnerPath (Join-Path $runnerRoot 'codex\runner.ps1') -Command preflight -RunPath $with.Path -ProfilePath $recordedProfiles['codex']
    Assert-Equal 'compatible' $fileAuthPreflight.status 'Codex subscription auth is accepted through app-server'
    Assert-True (@($fileAuthPreflight.checks | Where-Object { $_.name -eq 'authentication' -and $_.status -eq 'passed' }).Count -eq 1) 'Codex subscription authentication is explicit in preflight'
    $fileAuthResult = Invoke-AdapterJson -RunnerPath (Join-Path $runnerRoot 'codex\runner.ps1') -Command execute -RunPath $with.Path -ProfilePath $recordedProfiles['codex']
    Assert-Equal 'completed' $fileAuthResult.status ("Codex subscription app-server execution completes (native_failures={0}; failure={1})" -f ([string]::Join(',', @($fileAuthResult.evidence.native_worker_evidence_failures))), ([string](Get-JsonProperty -Object $fileAuthResult.exit.failure -Name 'message' -Default '')))
    Assert-Equal 'recorded subscription response' $fileAuthResult.final_response.text 'Codex app-server captures the final agent message'
    Assert-Equal 'recorded-subscription-thread' $fileAuthResult.session.id 'Codex app-server preserves thread identity'
    Assert-Equal 'recorded-subscription-turn' $fileAuthResult.evidence.turn_id 'Codex app-server preserves turn identity'
    Assert-Equal 'available' $fileAuthResult.telemetry.tokens.status 'Codex app-server maps token usage notifications'
    Assert-Equal 2 ([int]$fileAuthResult.telemetry.tokens.value.input_tokens) 'Codex app-server maps input token usage'
    Assert-Equal 3 ([int]$fileAuthResult.telemetry.tokens.value.output_tokens) 'Codex app-server maps output token usage'
    Assert-Equal 2 ([int]$fileAuthResult.telemetry.tool_calls.value) 'Codex app-server counts command and file-change evidence'
    Assert-Equal 1 @($fileAuthResult.evidence.commands).Count 'Codex app-server preserves command evidence'
    Assert-Equal 1 @($fileAuthResult.evidence.files).Count 'Codex app-server preserves file-change evidence'
    Assert-Equal 'runner' $fileAuthResult.evidence.delegation.dispatch_owner 'Codex native evidence identifies runner-owned dispatch'
    Assert-Equal 'gpt-5.6-luna' $fileAuthResult.evidence.delegation.observed_model 'Codex native evidence uses observed thread/start model'
    Assert-True (Test-ExactObservedPath -Expected $fileAuthResult.evidence.execution_paths.physical_working_directory -Observed $fileAuthResult.evidence.delegation.observed_working_directory) 'Codex native evidence uses the runner-declared physical cwd'
    Assert-Equal (Join-Path $with.Root 'repo') $fileAuthResult.evidence.execution_paths.logical_working_directory 'Codex evidence preserves the logical package cwd'
    Assert-True ([bool]$fileAuthResult.evidence.delegation.fresh_worker) 'Codex native evidence proves ephemeral fresh worker'
    Assert-True ([bool]$fileAuthResult.evidence.delegation.home_config_isolated) 'Codex native evidence proves auth-only home cleanup'
    Assert-True ([bool]$fileAuthResult.evidence.delegation.prompt_fidelity) 'Codex native evidence proves exact prompt hash'
    Assert-True ([bool]$fileAuthResult.evidence.delegation.terminal_result_capture) 'Codex native evidence proves turn completion capture'
    Assert-Equal 'harness_native_transport' $fileAuthResult.evidence.capture.source 'Codex capture provenance is app-server transport-owned'
    Assert-True ([bool]$fileAuthResult.evidence.capture.terminal -and -not [bool]$fileAuthResult.evidence.capture.worker_authored) 'Codex capture is terminal and not authored by the worker/orchestrator'
    Assert-True ([bool]$fileAuthResult.evidence.delegation.thread_read_observed) 'Codex native evidence records thread/read observation'
    Assert-Equal 'thread/start' $fileAuthResult.evidence.app_server.thread_start_request.method 'Codex evidence retains the exact thread/start request'
    Assert-Equal 'turn/start' $fileAuthResult.evidence.app_server.turn_start_request.method 'Codex evidence retains the exact turn/start request'
    Assert-Equal 'gpt-5.6-luna' $fileAuthResult.evidence.app_server.thread_start_request.params.model 'Codex exact thread/start request preserves model'
    Assert-Equal $fileAuthResult.evidence.execution_paths.physical_working_directory $fileAuthResult.evidence.app_server.turn_start_request.params.cwd 'Codex exact turn/start request preserves the physical cwd'
    Assert-Equal 'gpt-5.6-luna' $fileAuthResult.evidence.app_server.thread_start_response.result.model 'Codex evidence retains observed thread/start model'
    Assert-Equal 'recorded-subscription-thread' $fileAuthResult.evidence.app_server.thread_start_response.result.thread.id 'Codex parses the installed thread/start.result.thread shape'
    Assert-Equal 'recorded-subscription-turn' $fileAuthResult.evidence.app_server.turn_start_response.result.turn.id 'Codex parses the installed turn/start.result.turn shape'
    Assert-Equal 'completed' $fileAuthResult.evidence.app_server.terminal_turn.status 'Codex evidence retains terminal turn/completed status'
    Assert-Equal 'recorded-subscription-thread' $fileAuthResult.evidence.app_server.thread_read.request.threadId 'Codex evidence retains the thread/read request identity'
    Assert-Equal 'recorded-subscription-thread' $fileAuthResult.evidence.app_server.thread_read.response.id 'Codex parses the installed thread/read.result.thread shape'
    Assert-True ($fileAuthResult.evidence.app_server.thread_start_request.params.PSObject.Properties.Name -notcontains 'allowProviderModelFallback') 'Codex does not invent unsupported provider fallback control'
    Assert-True (@($fileAuthResult.evidence.app_server.thread_start.instruction_sources | Where-Object { (Test-PathInside -BasePath $fileAuthResult.evidence.execution_paths.physical_run_root -CandidatePath $_) }).Count -eq 1) 'allowed staged instruction source is inside the physical arm boundary'
    Assert-Equal 'physical_projection_boundary' $fileAuthResult.evidence.delegation.instruction_source_proof 'Codex records the independent physical instruction boundary proof'
    Assert-True (-not (Test-Path -LiteralPath $fileAuthResult.evidence.execution_paths.physical_run_root)) 'Codex removes the temporary physical projection after capture'
    $fileAuthEvidenceJson = ConvertTo-Json -InputObject $fileAuthResult -Depth 100
    Assert-True ($fileAuthEvidenceJson -notmatch 'recorded-canary|not-logged' -and $fileAuthEvidenceJson -notmatch [regex]::Escape($fileAuthHome)) 'Codex result evidence does not include the copied credential or auth path'
    $subscriptionLogPath = Join-Path $with.Root 'repo\codex-fake-cli-log.jsonl'
    $subscriptionRecord = Get-Content -LiteralPath $subscriptionLogPath | ForEach-Object { $_ | ConvertFrom-Json } | Where-Object { $_.PSObject.Properties.Name -contains 'rpc_methods' } | Select-Object -Last 1
    $codexNativeValidation = Test-NativeWorkerTerminalEvidence -ExecutionEvidence $fileAuthResult -Run (Resolve-RunContract -RunPath $with.Path) -RequestedModel 'gpt-5.6-luna' -ExpectedRunner 'codex' -ExpectedMechanism $fileAuthResult.evidence.delegation.mechanism
    Assert-True ([bool]$codexNativeValidation.Valid) 'Codex app-server result satisfies the common native terminal evidence contract'
    [void](Assert-NativeWorkerTerminalEvidence -ExecutionEvidence $fileAuthResult -Run (Resolve-RunContract -RunPath $with.Path) -RequestedModel 'gpt-5.6-luna' -ExpectedRunner 'codex' -ExpectedMechanism $fileAuthResult.evidence.delegation.mechanism)
    [void](Assert-NativeTerminalCaptureArtifact -ExecutionResult $fileAuthResult)
    $authHomePath = [string]$subscriptionRecord.parent_codex_home
    Assert-True (-not (Test-Path -LiteralPath $authHomePath)) 'Codex temporary auth-only home is removed after the arm completes'

    $threadReadUnavailableMarker = Join-Path $with.Root 'home\codex-thread-read-unavailable'
    [System.IO.File]::WriteAllText($threadReadUnavailableMarker, 'fixture', [System.Text.UTF8Encoding]::new($false))
    $threadReadUnavailableResult = Invoke-AdapterJson -RunnerPath (Join-Path $runnerRoot 'codex\runner.ps1') -Command execute -RunPath $with.Path -ProfilePath $recordedProfiles['codex']
    Assert-Equal 'completed' $threadReadUnavailableResult.status 'Optional thread/read absence does not invalidate a proven terminal turn'
    Assert-Equal 'unavailable_optional' $threadReadUnavailableResult.evidence.app_server.thread_read.observation 'Codex records missing thread/read as unavailable supplemental evidence'
    Assert-True (@($threadReadUnavailableResult.evidence.native_worker_evidence_failures | Where-Object { $_ -eq 'thread_read_metadata' }).Count -eq 0) 'Optional thread/read absence does not add a false incompatibility'
    Remove-Item -LiteralPath $threadReadUnavailableMarker -Force

    $rerouteMarker = Join-Path $with.Root 'home\codex-reroute'
    [System.IO.File]::WriteAllText($rerouteMarker, 'fixture', [System.Text.UTF8Encoding]::new($false))
    $reroutedResult = Invoke-AdapterJson -RunnerPath (Join-Path $runnerRoot 'codex\runner.ps1') -Command execute -RunPath $with.Path -ProfilePath $recordedProfiles['codex']
    Assert-Equal 'incompatible' $reroutedResult.status 'Codex model/rerouted notification fails closed'
    Assert-True (@($reroutedResult.evidence.native_worker_evidence_failures | Where-Object { $_ -eq 'model_rerouted' }).Count -eq 1) 'Codex reroute incompatibility is recorded as transport evidence'
    Assert-True ([string]$reroutedResult.exit.failure.message -match 'model_rerouted') 'Codex reroute reason survives in normalized exit failure'
    Remove-Item -LiteralPath $rerouteMarker -Force

    $ambientInstructionMarker = Join-Path $with.Root 'home\codex-ambient-instruction'
    [System.IO.File]::WriteAllText($ambientInstructionMarker, 'fixture', [System.Text.UTF8Encoding]::new($false))
    $ambientInstructionResult = Invoke-AdapterJson -RunnerPath (Join-Path $runnerRoot 'codex\runner.ps1') -Command execute -RunPath $with.Path -ProfilePath $recordedProfiles['codex']
    Assert-Equal 'incompatible' $ambientInstructionResult.status 'Codex unexpected instruction source fails closed'
    Assert-True (@($ambientInstructionResult.evidence.native_worker_evidence_failures | Where-Object { $_ -eq 'unexpected_instruction_sources' }).Count -eq 1) 'Codex ambient instruction rejection is recorded as transport evidence'
    Assert-True ([string]$ambientInstructionResult.exit.failure.message -match 'unexpected_instruction_sources') 'Codex instruction-source reason survives in normalized exit failure'
    Remove-Item -LiteralPath $ambientInstructionMarker -Force
    Assert-Equal 'initialize,initialized,thread/start,turn/start,thread/read' ([string]::Join(',', @($subscriptionRecord.rpc_methods))) 'Codex app-server follows the required handshake and post-completion read order'
    Assert-Equal 'gpt-5.6-luna' $subscriptionRecord.thread_params.model 'Codex app-server thread receives the requested model'
    Assert-True ([bool]$subscriptionRecord.thread_params.ephemeral) 'Codex app-server thread is ephemeral'
    Assert-Equal 'read-only' $subscriptionRecord.thread_params.sandbox 'Codex app-server thread uses the installed request enum'
    Assert-Equal 'gpt-5.6-luna' $subscriptionRecord.turn_params.model 'Codex app-server turn receives the requested model'
    Assert-Equal 'medium' $subscriptionRecord.turn_params.effort 'Codex app-server turn receives the requested reasoning effort'
    Assert-Equal $fileAuthResult.evidence.execution_paths.physical_working_directory $subscriptionRecord.turn_params.cwd 'Codex app-server turn receives the physical working directory'
    Assert-Equal 'never' $subscriptionRecord.turn_params.approvalPolicy 'Codex app-server turn rejects interactive approvals'
    Assert-Equal 'workspaceWrite' $subscriptionRecord.turn_params.sandboxPolicy.type 'Codex app-server turn receives workspace-write sandbox policy'
    Assert-True ($subscriptionRecord.parent_codex_home -ne $fileAuthHome) 'Codex app-server does not expose the ambient subscription CODEX_HOME'
    Assert-True ([bool]$subscriptionRecord.parent_auth_file_visible) 'Codex app-server parent can read the subscription auth file'
    Assert-True ([bool]$subscriptionRecord.auth_only_home) 'Codex app-server temporary CODEX_HOME contains auth.json only'
    Assert-True (-not [bool]$subscriptionRecord.parent_config_file_visible) 'Codex app-server temporary CODEX_HOME excludes config.toml'
    Assert-True (-not [bool]$subscriptionRecord.parent_skills_directory_visible) 'Codex app-server temporary CODEX_HOME excludes skills'
    Assert-True (-not [bool]$subscriptionRecord.parent_agents_directory_visible) 'Codex app-server temporary CODEX_HOME excludes agents'
    Assert-True (-not [bool]$subscriptionRecord.parent_sessions_directory_visible) 'Codex app-server temporary CODEX_HOME excludes sessions'
    Assert-True (-not [bool]$subscriptionRecord.parent_memories_directory_visible) 'Codex app-server temporary CODEX_HOME excludes memories'
    Assert-True (-not [bool]$subscriptionRecord.parent_plugins_directory_visible) 'Codex app-server temporary CODEX_HOME excludes plugins'
    Assert-True (-not [bool]$subscriptionRecord.parent_mcp_configuration_visible) 'Codex app-server temporary CODEX_HOME excludes MCP configuration'
    Assert-True (-not [bool]$subscriptionRecord.parent_agents_file_visible) 'Codex app-server temporary CODEX_HOME excludes AGENTS.md'
    Assert-True (-not [bool]$subscriptionRecord.unrelated_present) 'Codex app-server parent excludes unrelated inherited environment variables'
    Assert-True (-not [bool]$subscriptionRecord.worker_auth_file_visible) 'Codex app-server worker fixture does not receive auth.json'
    Assert-True (@($subscriptionRecord.args) -contains 'shell_environment_policy.inherit=none') 'Codex app-server disables child shell environment inheritance'
    $env:OPENAI_API_KEY = 'recorded-canary-not-logged'
    $env:CODEX_HOME = $recordedOldCodexHome
    # GitHub Copilot authentication: explicit env, OS-keychain, GitHub CLI, and
    # no-auth fixtures are all deterministic and contain no credential values.
    $env:COPILOT_GITHUB_TOKEN = $null
    $env:GH_TOKEN = $null
    $env:GITHUB_TOKEN = $null
    $missingGhConfig = Join-Path $recordedRoot 'missing-github-cli-auth'

    # The fixture marker is fake-CLI input only; it models a positive OS
    # keychain lookup without naming or reading a real credential-store file.
    $copilotKeychainHome = Join-Path $recordedRoot 'copilot-keychain-home'
    New-Item -ItemType Directory -Path $copilotKeychainHome -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $with.Root 'home\.copilot') -Force | Out-Null
    [System.IO.File]::WriteAllText((Join-Path $with.Root 'home\.copilot\fixture-os-keychain-available'), 'fixture marker only', [Text.UTF8Encoding]::new($false))
    $env:COPILOT_HOME = $copilotKeychainHome
    $env:GH_CONFIG_DIR = $missingGhConfig
    $copilotKeychainPreflight = Invoke-AdapterJson -RunnerPath (Join-Path $runnerRoot 'github-copilot\runner.ps1') -Command preflight -RunPath $with.Path -ProfilePath $recordedProfiles['copilot']
    Assert-Equal 'compatible' $copilotKeychainPreflight.status 'Copilot tokenless OS-keychain authentication remains compatible'
    Assert-True (@($copilotKeychainPreflight.checks | Where-Object { $_.name -eq 'authentication' -and $_.status -eq 'unavailable' }).Count -eq 1) 'Copilot preflight leaves native keychain readiness conditional'
    Assert-True (@($copilotKeychainPreflight.warnings | Where-Object { $_ -match 'cannot be proven' }).Count -gt 0) 'Copilot preflight explains the unverified keychain/service boundary'
    $copilotKeychainResult = Invoke-AdapterJson -RunnerPath (Join-Path $runnerRoot 'github-copilot\runner.ps1') -Command execute -RunPath $with.Path -ProfilePath $recordedProfiles['copilot']
    Assert-Equal 'completed' $copilotKeychainResult.status 'Copilot keychain fixture executes without an exported token'
    $keychainRecords = @(Get-Content -LiteralPath (Join-Path $with.Root 'repo\copilot-fake-cli-log.jsonl') | ForEach-Object { $_ | ConvertFrom-Json } | Where-Object { $_.copilot_authentication_source -eq 'os_keychain' })
    Assert-Equal 1 $keychainRecords.Count 'Copilot fake observes the simulated OS-keychain path'
    Remove-Item -LiteralPath (Join-Path $with.Root 'home\.copilot\fixture-os-keychain-available') -Force

    $copilotGhFallbackHome = Join-Path $recordedRoot 'copilot-gh-fallback-home'
    New-Item -ItemType Directory -Path $copilotGhFallbackHome -Force | Out-Null
    $copilotGhConfig = Join-Path $recordedRoot 'copilot-gh-config'
    New-Item -ItemType Directory -Path $copilotGhConfig -Force | Out-Null
    [System.IO.File]::WriteAllText((Join-Path $copilotGhConfig 'auth-marker.txt'), 'fixture auth state without a credential value', [Text.UTF8Encoding]::new($false))
    $env:COPILOT_HOME = $copilotGhFallbackHome
    $env:GH_CONFIG_DIR = $copilotGhConfig
    $copilotGhPreflight = Invoke-AdapterJson -RunnerPath (Join-Path $runnerRoot 'github-copilot\runner.ps1') -Command preflight -RunPath $with.Path -ProfilePath $recordedProfiles['copilot']
    Assert-Equal 'compatible' $copilotGhPreflight.status 'Copilot GitHub CLI fallback remains compatible'
    $copilotGhResult = Invoke-AdapterJson -RunnerPath (Join-Path $runnerRoot 'github-copilot\runner.ps1') -Command execute -RunPath $with.Path -ProfilePath $recordedProfiles['copilot']
    Assert-Equal 'completed' $copilotGhResult.status 'Copilot GitHub CLI fallback fixture executes without an exported token'
    Assert-True $copilotGhResult.evidence.credential.github_cli_token_resolved 'Copilot records GitHub CLI token fallback without storing the token value'
    Assert-True (-not $copilotGhResult.evidence.credential.github_cli_config_forwarded) 'Copilot GitHub CLI fallback does not forward host GH_CONFIG_DIR'
    $ghRecords = @(Get-Content -LiteralPath (Join-Path $with.Root 'repo\copilot-fake-cli-log.jsonl') | ForEach-Object { $_ | ConvertFrom-Json } | Where-Object { $_.stdin_received -eq $true -and @($_.copilot_auth_names_present).Count -eq 1 -and @($_.copilot_auth_names_present) -contains 'GH_TOKEN' -and [string]::IsNullOrWhiteSpace([string]$_.gh_config_dir) })
    Assert-Equal 1 $ghRecords.Count 'Copilot fake observes only the protected GH_TOKEN produced by trusted GitHub CLI fallback'

    $copilotNoAuthHome = Join-Path $recordedRoot 'copilot-no-auth-home'
    New-Item -ItemType Directory -Path $copilotNoAuthHome -Force | Out-Null
    $env:COPILOT_HOME = $copilotNoAuthHome
    $env:GH_CONFIG_DIR = $missingGhConfig
    $copilotNoAuthPreflight = Invoke-AdapterJson -RunnerPath (Join-Path $runnerRoot 'github-copilot\runner.ps1') -Command preflight -RunPath $with.Path -ProfilePath $recordedProfiles['copilot']
    Assert-Equal 'compatible' $copilotNoAuthPreflight.status 'Copilot preflight does not require an exported token when native auth is not observable'
    Assert-True (@($copilotNoAuthPreflight.warnings | Where-Object { $_ -match 'conditional' }).Count -gt 0) 'Copilot no-auth preflight is explicitly conditional'
    $copilotNoAuthResult = Invoke-AdapterJson -RunnerPath (Join-Path $runnerRoot 'github-copilot\runner.ps1') -Command execute -RunPath $with.Path -ProfilePath $recordedProfiles['copilot']
    Assert-Equal 'failed' $copilotNoAuthResult.status 'Copilot no-auth execution failure is captured without a model request'
    Assert-Equal 'copilot_os_keychain_or_github_cli_unverified' $copilotNoAuthResult.evidence.credential.source 'Copilot no-auth evidence does not claim authentication'
    Assert-True (($copilotNoAuthResult | ConvertTo-Json -Depth 100) -notmatch 'ambient-profile-not-logged|recorded-copilot-canary|recorded-gh-canary|recorded-github-canary') 'Copilot authentication fixtures never expose credential values'
    $env:COPILOT_HOME = $recordedOldCopilotHome
    Write-Output 'Real runner deterministic adapter conformance: PASS'
} finally {
    $env:PATH = $recordedOldPath
    $env:OPENAI_API_KEY = $recordedOldOpenAi
    $env:CODEX_HOME = $recordedOldCodexHome
    $env:AGENTIC_GLOBAL_SECRET = $recordedOldGlobalSecret
    $env:OPENCODE_DISABLE_PROJECT_CONFIG = $recordedOldProjectDisable
    $env:COPILOT_GITHUB_TOKEN = $recordedOldCopilotToken
    $env:GH_TOKEN = $recordedOldGhToken
    $env:GITHUB_TOKEN = $recordedOldGithubToken
    $env:COPILOT_HOME = $recordedOldCopilotHome
    $env:GH_CONFIG_DIR = $recordedOldGhConfigDir
    $env:AGENTIC_RECORDED_FIXTURES = $recordedOldFixtures
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

function Get-TestTreeHash {
    param([Parameter(Mandatory = $true)][string]$Root)

    $entries = foreach ($file in @(Get-ChildItem -LiteralPath $Root -Recurse -File -Force | Sort-Object FullName)) {
        $relative = [System.IO.Path]::GetRelativePath($Root, $file.FullName).Replace('\', '/')
        "$relative`:$((Get-Sha256HexFromFile -Path $file.FullName))"
    }
    $joined = [string]::Join("`n", @($entries | Sort-Object))
    return Get-Sha256HexFromBytes -Bytes ([System.Text.UTF8Encoding]::new($false).GetBytes($joined))
}

function New-TestRun {
    param(
        [string]$IterationDirectory,
        [ValidateSet('with_skill', 'without_skill')][string]$Configuration,
        [string]$EvalName = 'conformance',
        [object]$Interaction = $null
    )

    $evalDirectory = Join-Path $IterationDirectory 'conformance'
    $runRoot = Join-Path $evalDirectory $Configuration
    $repo = Join-Path $runRoot 'repo'
    $homeDirectory = Join-Path $runRoot 'home'
    New-Item -ItemType Directory -Path $repo,$homeDirectory -Force | Out-Null
    [System.IO.File]::WriteAllText((Join-Path $homeDirectory 'README.txt'), 'isolated home', [System.Text.UTF8Encoding]::new($false))
    New-Item -ItemType Directory -Path (Join-Path $repo '.github') -Force | Out-Null
    [System.IO.File]::WriteAllText((Join-Path $repo 'AGENTS.md'), '# repo-owned-agent-instruction', [System.Text.UTF8Encoding]::new($false))
    [System.IO.File]::WriteAllText((Join-Path $repo '.github\copilot-instructions.md'), '# repo-owned-copilot-instruction', [System.Text.UTF8Encoding]::new($false))
    [System.IO.File]::WriteAllText((Join-Path $repo 'opencode.json'), '{"fixture_project_config":true}', [System.Text.UTF8Encoding]::new($false))
    $prompt = "# task`r`n`r`nByte fidelity: Δ and emoji 🚀.`r`n" + ("large-prompt-line-0123456789`r`n" * 4096)
    [System.IO.File]::WriteAllBytes((Join-Path $runRoot 'prompt.md'), [System.Text.UTF8Encoding]::new($false).GetBytes($prompt))
    [System.IO.File]::WriteAllText((Join-Path $homeDirectory 'expected-prompt-sha256.txt'), (Get-Sha256HexFromFile -Path (Join-Path $runRoot 'prompt.md')), [System.Text.UTF8Encoding]::new($false))
    if ($Configuration -eq 'with_skill') {
        $skill = Join-Path $runRoot 'skill\candidate'
        New-Item -ItemType Directory -Path $skill -Force | Out-Null
        [System.IO.File]::WriteAllText((Join-Path $skill 'SKILL.md'), '# candidate', [System.Text.UTF8Encoding]::new($false))
        $skillDirectory = 'skill/candidate'
        $skillHash = Get-TestTreeHash -Root $skill
    } else {
        $skillDirectory = $null
        $skillHash = $null
    }
    $run = [ordered]@{
        schema = (Get-RunnerSchemaNames).Run
        evalId = 1
        evalName = $EvalName
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
        fixtureHash = Get-TestTreeHash -Root $repo
        skillHash = $skillHash
        contract = [ordered]@{
            sandboxRoot = '.'
            workingDirectory = 'repo'
            homeDirectory = 'home'
            mustNotReadOutsideSandbox = $true
            mustNotExposeGlobalSkillsOrConfig = $true
        }
    }
    if ($null -ne $Interaction) {
        $interactionPath = Join-Path $runRoot 'interaction.json'
        Write-TestJson -Path $interactionPath -Value $Interaction
        $run.interactionFile = 'interaction.json'
        $run.interactionHash = Get-Sha256HexFromFile -Path $interactionPath
    }
    $path = Join-Path $runRoot 'run.json'
    Write-TestJson -Path $path -Value $run
    return [pscustomobject]@{ Root = $runRoot; Path = $path; Contract = $run }
}

function Add-TestInteractionSources {
    param([Parameter(Mandatory = $true)][object]$TestRun)

    $runJson = Read-RunnerJson -Path $TestRun.Path
    $futureCanary = 'CODEBELT_FUTURE_TURN_CANARY_' + ([string]$runJson.interactionHash).Substring(0, 16).ToUpperInvariant()
    $interaction = Read-RunnerJson -Path (Join-Path $TestRun.Root ([string]$runJson.interactionFile))
    foreach ($turn in @($interaction.turns)) {
        $source = [string](Get-JsonProperty -Object $turn -Name 'source' -Default '')
        if ([string]::IsNullOrWhiteSpace($source)) { continue }
        $sourcePath = Join-Path $TestRun.Root ($source -replace '/', [IO.Path]::DirectorySeparatorChar)
        New-Item -ItemType Directory -Path (Split-Path -Parent $sourcePath) -Force | Out-Null
        [IO.File]::WriteAllText($sourcePath, "recorded scripted turn two $futureCanary", [Text.UTF8Encoding]::new($false))
    }
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
        model = 'fixture-model'
        reasoning_effort = $null
        configuration_profile = 'unsupported'
        tool_profile = 'default'
        timeout_seconds = 30
        concurrency = 1
    })
    $legacyProviderProfilePath = Join-Path $iteration 'legacy-provider-profile.json'
    Write-TestJson -Path $legacyProviderProfilePath -Value ([ordered]@{
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

    $with = New-TestRun -IterationDirectory $iteration -Configuration with_skill
    $without = New-TestRun -IterationDirectory $iteration -Configuration without_skill
    $fakePath = Join-Path $runnerRoot 'fake\runner.ps1'

    $descriptor = Invoke-Fake -FakePath $fakePath -Command describe -Run $with.Path -Profile $profilePath
    [void](Assert-RunnerDescriptor -Descriptor $descriptor)
    Assert-Equal 'fake' $descriptor.name 'descriptor identity'
    Assert-Equal (Get-RunnerSchemaNames).Protocol $descriptor.protocol_version 'descriptor protocol'
    Assert-Equal 'unsupported' $descriptor.capabilities.native_worker_delegation 'deterministic fake does not advertise a native delegation surface'
    Assert-Throws { Assert-RunnerDescriptor -Descriptor ([pscustomobject]@{ schema = $descriptor.schema; protocol_version = 'changed'; name = 'fake' }) } 'changed protocol must fail descriptor validation'
    Assert-Throws { Resolve-ExecutionProfile -ProfilePath $legacyProviderProfilePath } 'execution profile rejects the removed provider field'

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
        Assert-True ($result.requested.PSObject.Properties.Name -notcontains 'provider') 'portable execution result must not expose provider'
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

    foreach ($fixture in @('codex-events.jsonl', 'opencode-events.jsonl', 'copilot-events.jsonl')) {
        $fixturePath = Join-Path $PSScriptRoot "fixtures\$fixture"
        $parsed = ConvertFrom-JsonLines -Text ([System.IO.File]::ReadAllText($fixturePath, [System.Text.UTF8Encoding]::new($false)))
        Assert-Equal 0 $parsed.Errors.Count "recorded $fixture has valid JSONL"
        Assert-True ($parsed.Events.Count -ge 4) "recorded $fixture has events"
        Assert-True (@($parsed.Events | Where-Object { $_.type -eq 'future.event.v99' }).Count -eq 1) "recorded $fixture includes an unknown event"
    }
    $threadStartRejection = ConvertFrom-JsonLines -Text ([System.IO.File]::ReadAllText((Join-Path $PSScriptRoot 'fixtures\codex-thread-start-rejection.jsonl'), [System.Text.UTF8Encoding]::new($false)))
    Assert-Equal 0 $threadStartRejection.Errors.Count 'recorded Codex thread/start rejection fixture is valid JSONL'
    $threadStartError = @($threadStartRejection.Events | Where-Object { [int](Get-JsonProperty -Object (Get-JsonProperty -Object $_ -Name 'error' -Default $null) -Name 'code' -Default 0) -eq -32600 })[0]
    Assert-Equal -32600 $threadStartError.error.code 'recorded Codex thread/start rejection preserves JSON-RPC error code'
    Assert-True ($threadStartError.error.message -match 'read-only.*workspace-write.*danger-full-access') 'recorded Codex thread/start rejection preserves the installed sandbox enum'
    $copilotFixture = ConvertFrom-JsonLines -Text ([System.IO.File]::ReadAllText((Join-Path $PSScriptRoot 'fixtures\copilot-events.jsonl'), [System.Text.UTF8Encoding]::new($false)))
    Assert-True (@($copilotFixture.Events | Where-Object { $_.type -eq 'assistant.message' }).Count -ge 1) 'recorded copilot fixture includes documented assistant.message output'
    Assert-True (@($copilotFixture.Events | Where-Object { $_.type -eq 'assistant.usage' }).Count -eq 1) 'recorded copilot fixture includes documented assistant.usage output'
    Assert-True (@($copilotFixture.Events | Where-Object { $_.type -eq 'tool.execution_start' }).Count -eq 1) 'recorded copilot fixture includes documented tool.execution output'
    $prepareText = [System.IO.File]::ReadAllText((Join-Path $repoRoot 'scripts\prepare-skill-evals.ps1'), [System.Text.UTF8Encoding]::new($false))
    $reportText = [System.IO.File]::ReadAllText((Join-Path $repoRoot 'scripts\generate-eval-report.ps1'), [System.Text.UTF8Encoding]::new($false))
    $bridgeText = [System.IO.File]::ReadAllText((Join-Path $runnerRoot 'bridge-execution-result.ps1'), [System.Text.UTF8Encoding]::new($false))
    $recordText = [System.IO.File]::ReadAllText((Join-Path $runnerRoot 'record-native-result.ps1'), [System.Text.UTF8Encoding]::new($false))
    $manifestBridgeText = [System.IO.File]::ReadAllText((Join-Path $runnerRoot 'bridge-manifest-results.ps1'), [System.Text.UTF8Encoding]::new($false))
    $runnerOwnedText = [System.IO.File]::ReadAllText((Join-Path $runnerRoot 'invoke-runner-owned-arms.ps1'), [System.Text.UTF8Encoding]::new($false))
    $commonText = [System.IO.File]::ReadAllText((Join-Path $runnerRoot 'runner-common.ps1'), [System.Text.UTF8Encoding]::new($false))
    $orchestrationText = [System.IO.File]::ReadAllText((Join-Path $runnerRoot 'orchestration.ps1'), [System.Text.UTF8Encoding]::new($false))
    $opencodeRunnerText = [System.IO.File]::ReadAllText((Join-Path $runnerRoot 'opencode/runner.ps1'), [System.Text.UTF8Encoding]::new($false))
    Assert-True ($prepareText -notmatch '(?i)codex\s+exec|opencode\s+run|copilot\s+-p|copilot\s+--prompt|Profile\.Provider') 'portable preparation must not contain harness-specific CLI invocations or provider-field branches'
    Assert-True ($orchestrationText -notmatch '(?i)capture-native-results\.ps1|synthesize|worker_authored') 'generic orchestration must not manufacture native terminal envelopes'
    Assert-True ($reportText -notmatch '(?i)codex\s+exec|opencode\s+run|copilot\s+-p|copilot\s+--prompt|Profile\.Provider') 'reporting must not contain harness-specific or provider-field branches'
    Assert-True ($bridgeText -notmatch '(?i)codex\s+exec|opencode\s+run|copilot\s+-p|copilot\s+--prompt|Profile\.Provider') 'the raw-to-portable bridge must remain runner-neutral'
    Assert-True ($prepareText.Contains('execution-freeze.json') -and $prepareText.Contains('grading.json') -and $prepareText.Contains('apply-eval-grading.ps1') -and $prepareText.Contains('finalize-eval-package.ps1')) 'handoff preparation must expose the shared freeze, grading, and finalization boundaries'
    Assert-True ($prepareText.Contains('Read the selected runner descriptor and its `delegation.dispatch_owner`.') -and $prepareText.Contains('invoke this deterministic helper exactly once')) 'handoff preparation must make native dispatch ownership and one-shot Phase 1 explicit'
    Assert-True ($prepareText.Contains('Do not create outer workers') -and $prepareText.Contains('edit raw result/evidence files')) 'handoff preparation must forbid outer runner-owned workers and raw evidence edits'
    Assert-True ($prepareText.Contains('The Grader may author exactly one package-root `grading.json`') -and $prepareText.Contains('It must not edit raw execution results')) 'handoff preparation must isolate the Grader to the grading-only artifact'
    Assert-True ($prepareText.Contains('Return only its machine-readable JSON summary') -and $prepareText.Contains('Never repair, re-freeze, re-bridge a changed raw result')) 'handoff preparation must make finalizer success and fail-closed recovery explicit'
    Assert-True ($prepareText.Contains('evaluation is incomplete') -and $prepareText.Contains('Only persisted runner-produced evidence')) 'handoff preparation must fail closed when runner evidence cannot be persisted'
    Assert-True ($prepareText.Contains('fresh package/code fix is required') -and $prepareText.Contains('Never patch package-local runner code') -and $prepareText.Contains('delete execution results') -and $prepareText.Contains('delete or replace `execution-freeze.json`') -and $prepareText.Contains('rerun Phase 1') -and $prepareText.Contains('manually broaden a capability check')) 'generated handoff must forbid package-local repair, state deletion, retry, and manual capability broadening'
    $generatedHandoff = Invoke-GeneratedRunnerPrompt
    Assert-True ($generatedHandoff.Contains('evaluation is incomplete and a fresh package/code fix is required') -and $generatedHandoff.Contains('Never patch package-local runner code') -and $generatedHandoff.Contains('delete orchestration state') -and $generatedHandoff.Contains('delete execution results') -and $generatedHandoff.Contains('delete or replace `execution-freeze.json`') -and $generatedHandoff.Contains('rerun Phase 1') -and $generatedHandoff.Contains('manually broaden a capability check')) 'generated handoff output forbids package-local repair, state deletion, retry, and manual capability broadening'
    Assert-True ($generatedHandoff.Contains('allowance of 260 seconds (240-second serial preflight allowance for 2 arm(s) at the max(120, profile.timeout_seconds + runner grace) policy + 17-second longest child allowance + 3-second orchestration grace)') -and $generatedHandoff.Contains('not a default 120-second timeout') -and $generatedHandoff.Contains('must be started exactly once for this iteration') -and $generatedHandoff.Contains('if the original supervisor is alive, wait')) 'generated handoff computes serial preflight plus longest child allowance and no-rerun recovery'
    Assert-True ($prepareText -notmatch '(?i)runs\.<arm>|record-native-result\.ps1|Assert-NativeWorkerDelegation|Assert-OrchestrationConcurrency|capture\.worker_authored') 'runner-owned handoff must not teach manual orchestration, recorder, or evidence repair trivia'
    Assert-True ($bridgeText.Contains('Get-PackageRunnerDescriptor') -and $bridgeText.Contains('Assert-NativeTerminalCaptureArtifact') -and $bridgeText.Contains('ExpectedMechanism')) 'native bridge must require runner-produced terminal evidence'
    Assert-True ($recordText.Contains('eval-native-worker-result/1') -and $recordText.Contains('New-ExecutionResult')) 'native terminal recording must use the runner-owned result builder'
    Assert-True ($commonText.Contains('exit.status must be a JSON number or null')) 'execution results must reject textual exit statuses'
    Assert-True ($commonText.Contains('requested.timeout_seconds') -and $commonText.Contains('execution-result.json run.$field')) 'raw execution results must retain the complete run and requested configuration contract'
    Assert-True ($runnerOwnedText.Contains('Invoke-RunnerPreflight') -and $runnerOwnedText.Contains('Get-PreflightGateSummary') -and $runnerOwnedText.Contains('execution_started = $false')) 'runner-owned helper must gate all execute processes behind deterministic preflight'
    Assert-True ($prepareText -notmatch '<result-file>') 'handoff preparation must not expose an unconstrained result-file placeholder'
    Assert-True ($reportText -notmatch 'function Get-ResultPath') 'reporting must not contain a configuration-derived result path helper'
    Assert-True ($manifestBridgeText.Contains('Get-ManifestRunRecords') -and $manifestBridgeText.Contains('$record.ResultPath')) 'package-level bridge must resolve exact manifest records'
    Assert-True ($manifestBridgeText -notmatch 'with[-_]skill\.result\.json|without[-_]skill\.result\.json') 'package-level bridge must not encode arm-derived result filenames'
    Assert-Equal 1 ([regex]::Matches($opencodeRunnerText, '\$directoryArgument = Get-SandboxVisiblePath').Count) 'OpenCode CLI argument construction assigns the sandbox directory once'
    $opencodeAst = Get-OpenCodeRunnerAst
    $scriptedFunctionAst = @($opencodeAst.FindAll({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Invoke-OpenCodeScriptedExecute' }, $true) | Select-Object -First 1)
    $executeFunctionAst = @($opencodeAst.FindAll({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Invoke-OpenCodeExecute' }, $true) | Select-Object -First 1)
    $legacyFunctionAst = @($opencodeAst.FindAll({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Invoke-OpenCodeScriptedExecuteLegacy' }, $true))
    $continuationParserAst = @($opencodeAst.FindAll({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Get-OpenCodeContinuationCapability' }, $true))
    $continuationArgumentAst = @($opencodeAst.FindAll({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'New-OpenCodeContinuationArguments' }, $true))
    $legacyTurnProcessAst = @($opencodeAst.FindAll({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Invoke-OpenCodeTurnProcess' }, $true))
    Assert-Equal 1 $scriptedFunctionAst.Count 'OpenCode has one selected scripted execution function'
    Assert-Equal 1 $executeFunctionAst.Count 'OpenCode has one execution dispatcher'
    Assert-Equal 0 $legacyFunctionAst.Count 'OpenCode removes the dead legacy scripted continuation function'
    Assert-Equal 0 $continuationParserAst.Count 'OpenCode removes unused --session help parsing'
    Assert-Equal 0 $continuationArgumentAst.Count 'OpenCode removes unused --session argument construction'
    Assert-Equal 0 $legacyTurnProcessAst.Count 'OpenCode removes the unused CLI continuation turn-process helper'
    $scriptedFunctionText = [string]$scriptedFunctionAst[0].Extent.Text
    $executeFunctionText = [string]$executeFunctionAst[0].Extent.Text
    Assert-True ($scriptedFunctionText -notmatch '(?i)Invoke-OpenCodeTurnProcess|session/status|prompt_async|--session|--resume|--continue') 'selected OpenCode scripted transport cannot construct CLI session continuation or use SSE/session-status/async paths'
    Assert-True ($scriptedFunctionText.Contains('Start-OpenCodeServer') -and $scriptedFunctionText.Contains('SessionCreatePath') -and $scriptedFunctionText.Contains('SessionMessagePath') -and $scriptedFunctionText.Contains('Invoke-OpenCodeHttpRequest')) 'selected OpenCode scripted transport owns one server and synchronous HTTP session flow'
    Assert-True ($executeFunctionText.Contains('Invoke-OpenCodeScriptedExecute') -and $executeFunctionText -notmatch '(?i)Invoke-OpenCodeScriptedExecuteLegacy\s+-Inputs') 'OpenCode dispatcher selects server transport for interaction runs and never selects the legacy CLI continuation'

    $rawPath = Join-Path $iteration 'conformance\results\with-skill.execution-result.json'
    $withoutRawPath = Join-Path $iteration 'conformance\results\without-skill.execution-result.json'
    $resultPath = Join-Path $iteration 'conformance\results\with-skill.result.json'
    $withoutResultPath = Join-Path $iteration 'conformance\results\without-skill.result.json'
    New-Item -ItemType Directory -Path (Split-Path -Parent $rawPath) -Force | Out-Null
    Write-TestJson -Path $resultPath -Value ([ordered]@{
        schema = (Get-RunnerSchemaNames).PortableResult
        eval_id = 1
        eval_name = 'conformance'
        configuration = 'with_skill'
        execution_status = 'unrun'
        grading = @([ordered]@{ text = 'preserved assertion'; passed = $null; evidence = '' })
    })
    Write-TestJson -Path $withoutResultPath -Value ([ordered]@{
        schema = (Get-RunnerSchemaNames).PortableResult
        eval_id = 1
        eval_name = 'conformance'
        configuration = 'without_skill'
        execution_status = 'unrun'
        grading = @([ordered]@{ text = 'preserved assertion'; passed = $null; evidence = '' })
    })
    $bridgeResult = Invoke-Fake -FakePath $fakePath -Command execute -Run $with.Path -Profile $profilePath
    $withoutBridgeResult = Invoke-Fake -FakePath $fakePath -Command execute -Run $without.Path -Profile $profilePath
    Write-TestJson -Path $rawPath -Value $bridgeResult
    Write-TestJson -Path $withoutRawPath -Value $withoutBridgeResult
    Write-TestJson -Path (Join-Path $iteration 'conformance\eval-metadata.json') -Value ([ordered]@{
        schema = 'codebeltnet/agentic/eval-metadata/2'
        eval_id = 1
        eval_name = 'conformance'
        assertions = @('preserved assertion')
    })
    $oneArmManifest = [ordered]@{
        schema = 'codebeltnet/agentic/eval-package/2'
        configurations = @('with_skill', 'without_skill')
        execution_freeze = 'execution-freeze.json'
        evals = @([ordered]@{
            eval_id = 1
            eval_name = 'conformance'
            directory = 'conformance'
            metadata = 'conformance/eval-metadata.json'
            runs = [ordered]@{
                with_skill = [ordered]@{ mode = 'with_skill'; run_manifest = 'conformance/with_skill/run.json'; execution_result = 'conformance/results/with-skill.execution-result.json'; result = 'conformance/results/with-skill.result.json' }
                without_skill = [ordered]@{ mode = 'without_skill'; run_manifest = 'conformance/without_skill/run.json'; execution_result = 'conformance/results/without-skill.execution-result.json'; result = 'conformance/results/without-skill.result.json' }
            }
        })
    }
    Write-TestJson -Path (Join-Path $iteration 'manifest.json') -Value $oneArmManifest
    $oneArmManifestObject = Read-RunnerJson -Path (Join-Path $iteration 'manifest.json')
    $oneArmRecords = @(Get-ManifestRunRecords -IterationDirectory $iteration -Manifest $oneArmManifestObject)
    $oneArmProfile = Resolve-ExecutionProfile -ProfilePath $profilePath
    $oneArmStatePath = Join-Path $iteration 'orchestration-state.json'
    $oneArmState = [ordered]@{
        schema = 'codebeltnet/agentic/eval-orchestration-state/1'
        completed = [ordered]@{
            'arm-1-with_skill' = [ordered]@{ worker_id = 'arm-1-with_skill'; eval_id = 1; configuration = 'with_skill'; status = [string]$bridgeResult.status }
            'arm-1-without_skill' = [ordered]@{ worker_id = 'arm-1-without_skill'; eval_id = 1; configuration = 'without_skill'; status = [string]$withoutBridgeResult.status }
        }
        execution_freeze = $null
    }
    Write-TestJson -Path $oneArmStatePath -Value $oneArmState

    $codexProfilePath = Join-Path $iteration 'codex-native-profile.json'
    Write-TestJson -Path $codexProfilePath -Value ([ordered]@{
        schema = (Get-RunnerSchemaNames).Profile
        runner = 'codex'
        model = 'fixture-model'
        reasoning_effort = 'high'
        configuration_profile = 'isolated-default'
        tool_profile = 'default'
        timeout_seconds = 30
        concurrency = 1
    })
    $codexRunData = Resolve-RunContract -RunPath $with.Path
    $nativeEventRelativePath = 'evidence/native-worker-events.jsonl'
    $nativeEventPath = Join-Path $with.Root ($nativeEventRelativePath -replace '/', [System.IO.Path]::DirectorySeparatorChar)
    New-Item -ItemType Directory -Path (Split-Path -Parent $nativeEventPath) -Force | Out-Null
    [System.IO.File]::WriteAllText($nativeEventPath, '{"type":"terminal"}' + [Environment]::NewLine, [System.Text.UTF8Encoding]::new($false))
    $nativeArtifact = New-ArtifactReference -Run $codexRunData -Path $nativeEventRelativePath -Scope run -MediaType 'application/x-ndjson'
    $codexDescriptor = Get-PackageRunnerDescriptor -RunnerName 'codex'
    $nativeInputPath = Join-Path $iteration 'conformance\results\native-worker-result.json'
    $nativeOutputPath = Join-Path $iteration 'conformance\results\recorded.execution-result.json'
    $nativeEnvelope = [ordered]@{
        schema = 'codebeltnet/agentic/eval-native-worker-result/1'
        run_id = 'native-fixture-run'
        session = [ordered]@{ id = 'native-fixture-session'; fresh = $true; resumed = $false }
        status = 'completed'
        run = [ordered]@{ eval_id = 1; eval_name = 'conformance'; configuration = 'with_skill' }
        final_response = [ordered]@{ status = 'available'; text = 'native fixture response' }
        timing = [ordered]@{ started_utc = '2024-01-01T00:00:00Z'; finished_utc = '2024-01-01T00:00:01Z'; duration_seconds = 1 }
        exit = [ordered]@{ status = 0; failure = $null }
        isolation = [ordered]@{
            capabilities = [ordered]@{
                fresh_context = 'supported'
                isolated_home_config = 'supported'
                isolated_working_directory = 'supported'
                ambient_candidate_skill_exclusion = 'supported'
                candidate_skill_exposure = 'supported'
                prompt_fidelity = 'supported'
                model_configuration_lock = 'supported'
                response_capture = 'supported'
                filesystem_confinement = 'unavailable'
            }
            mechanisms = @('native-fixture-worker')
        }
        telemetry = [ordered]@{
            transcript = New-AvailableMetric -Value ([ordered]@{ artifact = $nativeEventRelativePath; complete = $true })
            tokens = New-UnavailableMetric -Reason 'fixture does not expose token telemetry'
            tool_calls = New-AvailableMetric -Value 0
            cost = New-UnavailableMetric -Reason 'fixture does not expose cost telemetry'
        }
        evidence = [ordered]@{
            delegation = [ordered]@{
                mechanism = [string]$codexDescriptor.delegation.mechanism
                worker_session_id = 'native-fixture-session'
                observed_model = 'fixture-model'
                observed_working_directory = $codexRunData.WorkingDirectoryPath
                observed_home = $codexRunData.HomeDirectoryPath
                fresh_worker = $true
                home_config_isolated = $true
                prompt_fidelity = $true
                prompt_sha256 = $codexRunData.PromptHash
                terminal_result_capture = $true
                paired_arm_visible = $false
                grading_material_visible = $false
                nested_model_execution = $false
                model_execution_count = 1
            }
        }
        capture = [ordered]@{
            source = 'harness_native_transport'
            terminal = $true
            worker_authored = $false
        }
        artifacts = @($nativeArtifact)
        warnings = @()
        compatibility_deviations = @()
        attempt_count = 1
        resolved = [ordered]@{ status = 'accepted_request'; reason = 'native fixture accepted the requested configuration'; observations = [ordered]@{ model = 'fixture-model'; reasoning_effort = 'high' } }
    }
    Write-TestJson -Path $nativeInputPath -Value $nativeEnvelope
    $recordPath = Join-Path $runnerRoot 'record-native-result.ps1'
    $recordOutput = & pwsh -NoProfile -File $recordPath -Runner codex -Run $with.Path -Profile $codexProfilePath -NativeResult $nativeInputPath -Output $nativeOutputPath 2>&1
    if ($LASTEXITCODE -ne 0) { throw "native terminal recording failed: $([string]::Join(' ', @($recordOutput)))" }
    $recordedResult = Read-RunnerJson -Path $nativeOutputPath
    [void](Assert-ExecutionResult -Result $recordedResult)
    Assert-Equal 'native-fixture-run' $recordedResult.run_id 'native terminal recording preserves the opaque worker run id'
    Assert-Equal 'conformance' $recordedResult.run.eval_name 'native terminal recording derives exact arm identity from run.json'
    Assert-Equal 'fixture-model' $recordedResult.requested.model 'native terminal recording derives model from execution-profile.json'
    Assert-Equal 30 $recordedResult.requested.timeout_seconds 'native terminal recording preserves the requested timeout'
    Assert-Equal '2024-01-01T00:00:00.000Z' ([DateTime]$recordedResult.started_utc).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ss.fffZ', [Globalization.CultureInfo]::InvariantCulture) 'native terminal recording writes canonical started_utc'
    Assert-True ($recordedResult.telemetry.transcript.status -eq 'available') 'native terminal recording preserves transcript evidence'
    Assert-Equal 'harness_native_transport' $recordedResult.evidence.capture.source 'native terminal recording preserves capture provenance'
    Assert-True (-not [bool]$recordedResult.evidence.capture.worker_authored) 'native terminal recording rejects worker-authored capture provenance'

    $legacyNativeInputPath = Join-Path $iteration 'conformance\results\legacy-summary.json'
    Write-TestJson -Path $legacyNativeInputPath -Value $bridgeResult
    $legacyOutput = & pwsh -NoProfile -File $recordPath -Runner codex -Run $with.Path -Profile $codexProfilePath -NativeResult $legacyNativeInputPath -Output $nativeOutputPath 2>&1
    Assert-True ($LASTEXITCODE -ne 0) 'legacy summary-shaped worker output is rejected by the native recording boundary'
    Assert-True (([string]::Join(' ', @($legacyOutput))) -match 'eval-native-worker-result/1') 'legacy summary rejection identifies the required native envelope'

    $oneArmFreeze = New-ExecutionFreezeDocument -IterationDirectory $iteration -Manifest $oneArmManifestObject -Records $oneArmRecords -Profile $oneArmProfile
    $oneArmFreezePath = Write-ExecutionFreezeDocument -IterationDirectory $iteration -Freeze $oneArmFreeze
    $oneArmState.execution_freeze = [ordered]@{ schema = (Get-RunnerSchemaNames).ExecutionFreeze; path = 'execution-freeze.json'; sha256 = Get-Sha256HexFromFile -Path $oneArmFreezePath }
    Write-TestJson -Path $oneArmStatePath -Value $oneArmState

    Write-TestJson -Path $rawPath -Value $bridgeResult
    $bridgePath = Join-Path $runnerRoot 'bridge-execution-result.ps1'
    $bridgeOutput = & pwsh -NoProfile -File $bridgePath -Run $with.Path -ExecutionResult $rawPath -Result $resultPath
    if ($LASTEXITCODE -ne 0) { throw "execution-result bridge failed: $([string]::Join(' ', @($bridgeOutput)))" }
    $portable = Get-Content -LiteralPath $resultPath -Raw | ConvertFrom-Json
    Assert-Equal 'codebeltnet/agentic/eval-result/2' $portable.schema 'bridge preserves existing result schema'
    Assert-Equal 'completed' $portable.execution_status 'bridge carries execution status'
    Assert-Equal 'fixture-model' $portable.model 'bridge carries resolved model'
    Assert-True ($portable.PSObject.Properties.Name -notcontains 'provider') 'bridge removes provider from portable result'
    Assert-True ($null -eq $portable.total_tokens) 'bridge keeps unavailable total tokens unavailable'
    Assert-Equal 0 $portable.tool_calls 'bridge carries available tool-call count'
    Assert-True $portable.isolation.transcript_captured 'bridge carries transcript availability'
    Assert-Equal 'strict' $portable.isolation.level 'bridge carries isolation confidence level'
    Assert-Equal 'verified' $portable.isolation.status 'bridge carries isolation verification status'
    Assert-True (@($portable.isolation.mechanisms).Count -gt 0) 'bridge carries isolation mechanisms'
    Assert-True (@($portable.output_files).Count -gt 0) 'bridge carries confined evidence paths'
    Assert-Equal 'preserved assertion' $portable.grading[0].text 'bridge preserves the canonical grading entry'
    Assert-True ($null -eq $portable.grading[0].passed) 'bridge preserves the canonical grading state before grading'

    $manifestPackage = Join-Path $iteration 'manifest-path-regression'
    $manifestEval = Join-Path $manifestPackage 'conformance'
    New-Item -ItemType Directory -Path $manifestEval -Force | Out-Null
    $manifestWith = New-TestRun -IterationDirectory $manifestPackage -Configuration with_skill -EvalName 'manifest-path-regression'
    $manifestWithout = New-TestRun -IterationDirectory $manifestPackage -Configuration without_skill -EvalName 'manifest-path-regression'
    $manifestMetadataPath = Join-Path $manifestEval 'eval-metadata.json'
    Write-TestJson -Path $manifestMetadataPath -Value ([ordered]@{
        schema = 'codebeltnet/agentic/eval-metadata/2'
        eval_id = 1
        eval_name = 'manifest-path-regression'
        assertions = @('preserved assertion', 'completed execution is bridged')
    })
    $manifestWithResult = Join-Path $manifestEval 'results\with-skill.result.json'
    $manifestWithoutResult = Join-Path $manifestEval 'results\without-skill.result.json'
    $manifestWithExecution = Join-Path $manifestEval 'results\with-skill.execution-result.json'
    $manifestWithoutExecution = Join-Path $manifestEval 'results\without-skill.execution-result.json'
    foreach ($resultPathForStub in @($manifestWithResult, $manifestWithoutResult)) {
        $configurationForStub = if ($resultPathForStub -eq $manifestWithResult) { 'with_skill' } else { 'without_skill' }
        Write-TestJson -Path $resultPathForStub -Value ([ordered]@{
            schema = (Get-RunnerSchemaNames).PortableResult
            eval_id = 1
            configuration = $configurationForStub
            execution_status = 'unrun'
            grading = @(
                [ordered]@{ text = 'preserved assertion'; passed = $null; evidence = '' }
                [ordered]@{ text = 'completed execution is bridged'; passed = $null; evidence = '' }
            )
        })
    }
    $manifest = [ordered]@{
        schema = 'codebeltnet/agentic/eval-package/2'
        configurations = @('with_skill', 'without_skill')
        execution_freeze = 'execution-freeze.json'
        evals = @([ordered]@{
            eval_id = 1
            eval_name = 'manifest-path-regression'
            directory = 'conformance'
            metadata = 'conformance/eval-metadata.json'
            runs = [ordered]@{
                with_skill = [ordered]@{
                    mode = 'with_skill'
                    run_manifest = 'conformance/with_skill/run.json'
                    execution_result = 'conformance/results/with-skill.execution-result.json'
                    result = 'conformance/results/with-skill.result.json'
                }
                without_skill = [ordered]@{
                    mode = 'without_skill'
                    run_manifest = 'conformance/without_skill/run.json'
                    execution_result = 'conformance/results/without-skill.execution-result.json'
                    result = 'conformance/results/without-skill.result.json'
                }
            }
        })
    }
    Write-TestJson -Path (Join-Path $manifestPackage 'manifest.json') -Value $manifest
    $parallelProfilePath = Join-Path $manifestPackage 'execution-profile.json'
    $parallelProfile = Read-RunnerJson -Path $profilePath
    $parallelProfile.concurrency = 2
    Write-TestJson -Path $parallelProfilePath -Value $parallelProfile
    $manifestWithExecutionResult = Invoke-Fake -FakePath $fakePath -Command execute -Run $manifestWith.Path -Profile $parallelProfilePath
    $manifestWithoutExecutionResult = Invoke-Fake -FakePath $fakePath -Command execute -Run $manifestWithout.Path -Profile $parallelProfilePath
    Write-TestJson -Path $manifestWithExecution -Value $manifestWithExecutionResult
    Write-TestJson -Path $manifestWithoutExecution -Value $manifestWithoutExecutionResult

    $manifestObject = Get-Content -LiteralPath (Join-Path $manifestPackage 'manifest.json') -Raw | ConvertFrom-Json
    $preBridgeValidation = Test-ManifestResults -IterationDirectory $manifestPackage -Manifest $manifestObject
    Assert-True (-not $preBridgeValidation.Success) 'terminal execution plus an unrun canonical result fails validation before bridging'
    Assert-True (@($preBridgeValidation.Errors | Where-Object { $_ -match 'remains unrun' }).Count -gt 0) 'pre-bridge validation reports the canonical unrun result'

    $incompatibleManifestResult = Invoke-Fake -FakePath $fakePath -Command execute -Run $manifestWithout.Path -Profile $parallelProfilePath -Scenario incompatible
    Write-TestJson -Path $manifestWithoutExecution -Value $incompatibleManifestResult
    $incompatibleValidation = Test-ManifestResults -IterationDirectory $manifestPackage -Manifest $manifestObject -RequireComplete
    Assert-True (-not $incompatibleValidation.Complete) 'incompatible execution evidence fails the completion gate'
    Assert-True (@($incompatibleValidation.Errors | Where-Object { $_ -match 'diagnostic only' }).Count -gt 0) 'incompatible completion rejection explains that the arm is diagnostic only'
    Write-TestJson -Path $manifestWithoutExecution -Value $manifestWithoutExecutionResult

    $manifestStatePath = Join-Path $manifestPackage 'orchestration-state.json'
    $manifestState = [ordered]@{
        schema = 'codebeltnet/agentic/eval-orchestration-state/1'
        requested_concurrency = 2
        parallel_dispatch_required = $true
        minimum_parallel_workers = 2
        capacity_limit_reported = $false
        max_observed_active = 2
        pending_worker_ids = @()
        active = [ordered]@{}
        completed = [ordered]@{
            'arm-1-with_skill' = [ordered]@{ worker_id = 'arm-1-with_skill'; eval_id = 1; configuration = 'with_skill'; status = 'completed' }
            'arm-1-without_skill' = [ordered]@{ worker_id = 'arm-1-without_skill'; eval_id = 1; configuration = 'without_skill'; status = 'completed' }
        }
        delegation_rejections = [ordered]@{}
        eval_attempts = [ordered]@{ 'arm-1-with_skill' = 1; 'arm-1-without_skill' = 1 }
        execution_freeze = $null
    }
    Write-TestJson -Path $manifestStatePath -Value $manifestState
    $manifestRecords = @(Get-ManifestRunRecords -IterationDirectory $manifestPackage -Manifest $manifestObject)
    $manifestProfileData = Resolve-ExecutionProfile -ProfilePath $parallelProfilePath
    $manifestFreeze = New-ExecutionFreezeDocument -IterationDirectory $manifestPackage -Manifest $manifestObject -Records $manifestRecords -Profile $manifestProfileData
    $manifestFreezePath = Write-ExecutionFreezeDocument -IterationDirectory $manifestPackage -Freeze $manifestFreeze
    $manifestState.execution_freeze = [ordered]@{ schema = (Get-RunnerSchemaNames).ExecutionFreeze; path = 'execution-freeze.json'; sha256 = Get-Sha256HexFromFile -Path $manifestFreezePath }
    Write-TestJson -Path $manifestStatePath -Value $manifestState

    $shadowPath = Join-Path $manifestEval 'results\with_skill.result.json'
    Write-TestJson -Path $shadowPath -Value ([ordered]@{
        schema = (Get-RunnerSchemaNames).PortableResult
        eval_id = 1
        configuration = 'with_skill'
        execution_status = 'completed'
        grading = @()
    })
    $manifestBridgePath = Join-Path $runnerRoot 'bridge-manifest-results.ps1'
    $shadowOutput = & pwsh -NoProfile -File $manifestBridgePath -IterationDirectory $manifestPackage -RequireComplete 2>&1
    $shadowExitCode = $LASTEXITCODE
    Assert-True ($shadowExitCode -ne 0) 'manifest bridge rejects an unreferenced underscore shadow result'
    Assert-True (([string]::Join(' ', @($shadowOutput))) -match 'unreferenced result-like sibling') 'shadow rejection explains the manifest collision'
    $canonicalBeforeBridge = Get-Content -LiteralPath $manifestWithResult -Raw | ConvertFrom-Json
    Assert-Equal 'unrun' $canonicalBeforeBridge.execution_status 'shadow result is never selected as the canonical result'
    Remove-Item -LiteralPath $shadowPath -Force

    $manifestState.max_observed_active = 1
    Write-TestJson -Path $manifestStatePath -Value $manifestState
    $serialBridgeOutput = & pwsh -NoProfile -File $manifestBridgePath -IterationDirectory $manifestPackage -RequireComplete -RequireParallelDispatch 2>&1
    Assert-True ($LASTEXITCODE -ne 0) 'manifest bridge rejects post-freeze orchestration mutation'
    Assert-True (([string]::Join(' ', @($serialBridgeOutput))) -match 'orchestration-state.json changed') 'state mutation rejection preserves the immutable concurrency ledger'
    $manifestState.max_observed_active = 2
    Write-TestJson -Path $manifestStatePath -Value $manifestState
    $manifestBridgeOutput = & pwsh -NoProfile -File $manifestBridgePath -IterationDirectory $manifestPackage -RequireComplete -RequireParallelDispatch 2>&1
    if ($LASTEXITCODE -ne 0) { throw "manifest path bridge failed: $([string]::Join(' ', @($manifestBridgeOutput)))" }
    $canonicalWith = Get-Content -LiteralPath $manifestWithResult -Raw | ConvertFrom-Json
    Assert-Equal 'completed' $canonicalWith.execution_status 'manifest bridge populates the canonical hyphen result'
    Assert-Equal 'fixture-model' $canonicalWith.model 'manifest bridge carries the model to the canonical result'
    Assert-Equal 'deterministic-fake 1' $canonicalWith.harness 'manifest bridge carries the harness to the canonical result'
    Assert-True (-not [string]::IsNullOrWhiteSpace([string]$canonicalWith.output)) 'manifest bridge carries output to the canonical result'
    Assert-Equal 'results/with-skill.execution-result.json' $canonicalWith.execution_result_file 'manifest bridge records the exact manifest execution path'
    Assert-Equal 2 @($canonicalWith.grading).Count 'manifest bridge preserves the canonical grading count'
    Assert-Equal 'preserved assertion' $canonicalWith.grading[0].text 'manifest bridge preserves the canonical grading text'

    $canonicalWith.grading[0].passed = $true
    $canonicalWith.grading[0].evidence = 'graded after the first bridge'
    Write-TestJson -Path $manifestWithResult -Value $canonicalWith
    $repeatBridgeOutput = & pwsh -NoProfile -File $manifestBridgePath -IterationDirectory $manifestPackage -RequireComplete -RequireParallelDispatch 2>&1
    if ($LASTEXITCODE -ne 0) { throw "repeat manifest path bridge failed: $([string]::Join(' ', @($repeatBridgeOutput)))" }
    $canonicalAfterRepeat = Get-Content -LiteralPath $manifestWithResult -Raw | ConvertFrom-Json
    Assert-True ([bool]$canonicalAfterRepeat.grading[0].passed) 'repeat manifest bridge preserves completed grading'
    Assert-Equal 'graded after the first bridge' $canonicalAfterRepeat.grading[0].evidence 'repeat manifest bridge preserves grading evidence'

    $frozenManifestRawBytes = [System.IO.File]::ReadAllBytes($manifestWithExecution)
    $canonicalBeforeIntegrityFailure = [System.IO.File]::ReadAllBytes($manifestWithResult)
    $staleReplacement = Get-Content -LiteralPath $manifestWithExecution -Raw | ConvertFrom-Json
    $staleReplacement.run_id = 'replacement-terminal-result'
    $staleReplacement.final_response.text = 'replacement terminal output'
    Write-TestJson -Path $manifestWithExecution -Value $staleReplacement
    $replacementBridgeOutput = & pwsh -NoProfile -File $manifestBridgePath -IterationDirectory $manifestPackage -RequireComplete -RequireParallelDispatch 2>&1
    Assert-True ($LASTEXITCODE -ne 0) 'manifest bridge rejects a raw execution result changed after the freeze'
    Assert-True (([string]::Join(' ', @($replacementBridgeOutput))) -match 'Execution integrity failure|requires fresh Phase 1 execution') 'raw mutation rejection identifies frozen evidence integrity'
    Assert-True ([Convert]::ToBase64String([System.IO.File]::ReadAllBytes($manifestWithResult)) -eq [Convert]::ToBase64String($canonicalBeforeIntegrityFailure)) 'raw integrity failure does not rewrite the canonical result'
    [System.IO.File]::WriteAllBytes($manifestWithExecution, $frozenManifestRawBytes)
    $restoredBridgeOutput = & pwsh -NoProfile -File $manifestBridgePath -IterationDirectory $manifestPackage -RequireComplete -RequireParallelDispatch 2>&1
    if ($LASTEXITCODE -ne 0) { throw "restored manifest path bridge failed: $([string]::Join(' ', @($restoredBridgeOutput)))" }

    $invalidExitPath = Join-Path $manifestEval 'results\invalid-exit.execution-result.json'
    $invalidExitResult = $bridgeResult | ConvertTo-Json -Depth 100 | ConvertFrom-Json
    $invalidExitResult.exit.status = 'completed'
    Write-TestJson -Path $invalidExitPath -Value $invalidExitResult
    $invalidExitThrew = $false
    try { [void](Assert-ExecutionResult -Result $invalidExitResult) } catch {
        $invalidExitThrew = $true
        Assert-True ($_.Exception.Message -match 'JSON number or null') 'textual exit rejection explains the numeric contract'
    }
    Assert-True $invalidExitThrew 'execution-result validator rejects a textual exit status'

    Write-Output 'Eval Runner conformance: PASS'
} finally {
    [Environment]::SetEnvironmentVariable('AGENTIC_FAKE_GLOBAL_RULES', $null, 'Process')
    [Environment]::SetEnvironmentVariable('AGENTIC_FAKE_MEMORY', $null, 'Process')
    [Environment]::SetEnvironmentVariable('AGENTIC_FAKE_PLUGINS', $null, 'Process')
    if (Test-Path -LiteralPath $testRoot) { Remove-Item -LiteralPath $testRoot -Recurse -Force }
}

Invoke-RecordedRunnerTests
