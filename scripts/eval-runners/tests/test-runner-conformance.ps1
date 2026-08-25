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
$recordedOldCopilotToken = $env:COPILOT_GITHUB_TOKEN
$recordedOldGhToken = $env:GH_TOKEN
$recordedOldGithubToken = $env:GITHUB_TOKEN
$recordedOldCopilotHome = $env:COPILOT_HOME
$recordedOldGhConfigDir = $env:GH_CONFIG_DIR
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
param([Parameter(ValueFromRemainingArguments = $true)][string[]]$RemainingArguments)
$harness = [System.IO.Path]::GetFileNameWithoutExtension($MyInvocation.MyCommand.Path)
$logPath = Join-Path (Get-Location).Path ("{0}-fake-cli-log.jsonl" -f $harness)
$arguments = @($RemainingArguments | ForEach-Object { [string]$_ })
$authNames = @('OPENAI_API_KEY', 'ANTHROPIC_API_KEY', 'GOOGLE_API_KEY', 'GEMINI_API_KEY', 'OPENROUTER_API_KEY', 'XAI_API_KEY', 'MISTRAL_API_KEY')
$authPresent = @($authNames | Where-Object { -not [string]::IsNullOrWhiteSpace([Environment]::GetEnvironmentVariable($_)) })
$copilotAuthNames = @('COPILOT_GITHUB_TOKEN', 'GH_TOKEN', 'GITHUB_TOKEN')
$copilotAuthPresent = @($copilotAuthNames | Where-Object { -not [string]::IsNullOrWhiteSpace([Environment]::GetEnvironmentVariable($_)) })
$copilotHome = [Environment]::GetEnvironmentVariable('COPILOT_HOME')
$repositoryAgentsPath = Join-Path (Get-Location).Path 'AGENTS.md'
$repositoryCopilotInstructionsPath = Join-Path (Get-Location).Path '.github\copilot-instructions.md'
$candidateSkillPath = Join-Path (Split-Path -Parent (Get-Location).Path) 'skill'
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
    custom_instructions_disabled = ($arguments -contains '--no-custom-instructions')
    builtin_mcps_disabled = ($arguments -contains '--disable-builtin-mcps')
    repository_agents_visible = Test-Path -LiteralPath $repositoryAgentsPath -PathType Leaf
    repository_copilot_instructions_visible = Test-Path -LiteralPath $repositoryCopilotInstructionsPath -PathType Leaf
    repository_instruction_marker_visible = $repositoryInstructionMarkerVisible
    candidate_skill_staged = Test-Path -LiteralPath $candidateSkillPath -PathType Container
    ambient_copilot_instructions_visible = if ([string]::IsNullOrWhiteSpace($copilotHome)) { $false } else { Test-Path -LiteralPath (Join-Path $copilotHome 'copilot-instructions.md') -PathType Leaf }
    secret_env_vars_arg = @($arguments | Where-Object { $_ -like '--secret-env-vars=*' })
}
if ($harness -eq 'codex' -and $arguments -contains 'app-server' -and $arguments -contains 'generate-json-schema') {
    $outArgument = @($arguments | Where-Object { $_ -like '--out=*' } | Select-Object -First 1)
    if ($outArgument.Count -eq 0) { exit 2 }
    $schemaDirectory = [IO.Path]::GetFullPath((Join-Path (Get-Location).Path ([string]$outArgument[0].Substring(6))))
    New-Item -ItemType Directory -Path $schemaDirectory -Force | Out-Null
    $schemaFiles = [ordered]@{
        'ThreadStartParams.json' = '{"title":"ThreadStartParams","type":"object","properties":{"model":{"type":"string"},"cwd":{"type":"string"},"approvalPolicy":{"type":"string"},"sandbox":{"$ref":"#/definitions/SandboxMode"},"ephemeral":{"type":"boolean"}},"definitions":{"SandboxMode":{"type":"string","enum":["read-only","workspace-write","danger-full-access"]}}}'
        'ThreadStartResponse.json' = '{"title":"ThreadStartResponse","type":"object","required":["approvalPolicy","approvalsReviewer","cwd","model","modelProvider","sandbox","thread"],"properties":{"cwd":{"type":"string"},"model":{"type":"string"},"instructionSources":{"type":"array","items":{"$ref":"#/definitions/LegacyAppPathString"}},"thread":{"$ref":"#/definitions/Thread"}},"definitions":{"LegacyAppPathString":{"type":"string"},"Thread":{"type":"object","required":["id","cwd","ephemeral","sessionId","turns"],"properties":{"id":{"type":"string"},"cwd":{"type":"string"},"ephemeral":{"type":"boolean"},"sessionId":{"type":"string"},"turns":{"type":"array"}}}}}'
        'TurnStartParams.json' = '{"title":"TurnStartParams","type":"object","required":["input","threadId"],"properties":{"threadId":{"type":"string"},"input":{"type":"array"},"cwd":{"type":"string"},"model":{"type":"string"},"effort":{"type":"string"},"approvalPolicy":{"type":"string"},"sandboxPolicy":{"type":"object"}}}'
        'TurnStartResponse.json' = '{"title":"TurnStartResponse","type":"object","required":["turn"],"properties":{"turn":{"$ref":"#/definitions/Turn"}},"definitions":{"Turn":{"type":"object","required":["id","items","status"],"properties":{"id":{"type":"string"},"items":{"type":"array"},"status":{"type":"string"}}}}}'
        'ThreadReadParams.json' = '{"title":"ThreadReadParams","type":"object","required":["threadId"],"properties":{"threadId":{"type":"string"},"includeTurns":{"type":"boolean"}}}'
        'ThreadReadResponse.json' = '{"title":"ThreadReadResponse","type":"object","required":["thread"],"properties":{"thread":{"$ref":"#/definitions/Thread"}},"definitions":{"Thread":{"type":"object","required":["id","cwd","ephemeral","sessionId","turns"],"properties":{"id":{"type":"string"},"cwd":{"type":"string"},"ephemeral":{"type":"boolean"},"sessionId":{"type":"string"},"turns":{"type":"array"}}}}}'
        'ModelReroutedNotification.json' = '{"title":"ModelReroutedNotification","type":"object","required":["fromModel","reason","threadId","toModel","turnId"],"properties":{"fromModel":{"type":"string"},"reason":{"type":"string","enum":["highRiskCyberActivity"]},"threadId":{"type":"string"},"toModel":{"type":"string"},"turnId":{"type":"string"}}}'
    }
    foreach ($schemaName in $schemaFiles.Keys) { [IO.File]::WriteAllText((Join-Path $schemaDirectory $schemaName), [string]$schemaFiles[$schemaName], [Text.UTF8Encoding]::new($false)) }
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
if ($arguments -contains '--version') {
    $version = switch ($harness) { 'codex' { 'recorded-codex 9.1' } 'opencode' { 'recorded-opencode 9.2' } 'copilot' { 'GitHub Copilot CLI recorded-1.0.80' } default { 'recorded-unknown 9.3' } }
    [IO.File]::AppendAllText($logPath, (($record | ConvertTo-Json -Compress) + [Environment]::NewLine), [Text.UTF8Encoding]::new($false))
    Write-Output $version
    exit 0
}
if ($arguments -contains '--help') {
    $help = switch ($harness) {
        'codex' { '--ask-for-approval never --ephemeral --ignore-user-config --ignore-rules --json --output-last-message --sandbox --cd --model --config --approve-for-me' }
        'opencode' { '--format --dir --model --auto --pure --continue --session' }
        'copilot' { '--prompt --output-format --model --allow-all-tools --no-ask-user --no-custom-instructions --disable-builtin-mcps --no-color --log-level --secret-env-vars --no-auto-update -C --resume --continue --session-id --connect --yolo --allow-all --allow-all-paths --allow-all-urls' }
        default { '--json --auto-approve --cwd --config --data-dir --hooks-dir --provider --model --thinking --timeout --retries --id' }
    }
    [IO.File]::AppendAllText($logPath, (($record | ConvertTo-Json -Compress) + [Environment]::NewLine), [Text.UTF8Encoding]::new($false))
    Write-Output $help
    exit 0
}
$stdinMemory = [IO.MemoryStream]::new()
[Console]::OpenStandardInput().CopyTo($stdinMemory)
$stdinBytes = $stdinMemory.ToArray()
$stdinHash = [Convert]::ToHexString(([Security.Cryptography.SHA256]::HashData($stdinBytes))).ToLowerInvariant()
$expectedPromptHashPath = Join-Path ([Environment]::GetEnvironmentVariable('HOME')) 'expected-prompt-sha256.txt'
$expectedPromptHash = if (Test-Path -LiteralPath $expectedPromptHashPath -PathType Leaf) { [IO.File]::ReadAllText($expectedPromptHashPath, [Text.UTF8Encoding]::new($false)).Trim() } else { $stdinHash }
$record.stdin_received = $stdinBytes.Length -gt 0
$record.stdin_delivery_count = if ($stdinBytes.Length -gt 0) { 1 } else { 0 }
$record.stdin_byte_length = $stdinBytes.Length
$record.stdin_sha256 = $stdinHash
$record.stdin_exact = $stdinHash -eq $expectedPromptHash
$record.stdin_expected_sha256 = $expectedPromptHash
$record.stdin_utf8_round_trip = $record.stdin_sha256 -eq $expectedPromptHash
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
    $probe.WaitForExit()
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
[IO.File]::AppendAllText($logPath, (($record | ConvertTo-Json -Compress) + [Environment]::NewLine), [Text.UTF8Encoding]::new($false))
if ($harness -eq 'copilot' -and $copilotAuthenticationSource -eq 'unavailable') {
    [Console]::Error.WriteLine('deterministic fixture: no Copilot authentication mechanism is available')
    exit 17
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
    foreach ($runnerName in @('codex', 'opencode', 'copilot')) {
        $runnerDir = if ($runnerName -eq 'copilot') { 'github-copilot' } else { $runnerName }
        $runnerPath = Join-Path $runnerRoot "$runnerDir\runner.ps1"
        $description = Invoke-AdapterJson -RunnerPath $runnerPath -Command describe -RunPath $with.Path -ProfilePath $recordedProfiles[$runnerName]
        [void](Assert-RunnerDescriptor -Descriptor $description)
        Assert-True ($description.PSObject.Properties.Name -contains 'delegation') "$runnerName descriptor declares native delegation"
        $expectedDispatchOwner = if ($runnerName -eq 'codex') { 'runner' } else { 'orchestrator' }
        Assert-Equal $expectedDispatchOwner $description.delegation.dispatch_owner "$runnerName descriptor declares its native dispatch owner"
        Assert-True (-not [bool]$description.delegation.nested_model_execution) "$runnerName descriptor forbids nested model execution"
        Assert-True (-not [string]::IsNullOrWhiteSpace([string]$description.delegation.mechanism)) "$runnerName descriptor records its native delegation mechanism"
        Assert-Equal 'conditional' $description.capabilities.native_worker_delegation "$runnerName descriptor does not present native delegation as terminal proof"
        Assert-Equal 'conditional' $description.delegation.model_lock "$runnerName descriptor leaves child model resolution conditional"
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
        if ($runnerName -eq 'copilot') {
            Assert-True (@($preflightWith.checks | Where-Object { $_.name -eq 'authentication' -and $_.status -eq 'passed' }).Count -eq 1) 'Copilot preflight accepts explicit environment authentication'
            Assert-True (@($preflightWith.mechanisms | Where-Object { $_ -eq '--allow-all-tools broad tool approval' }).Count -eq 1) 'Copilot preflight describes --allow-all-tools as broad tool approval'
            Assert-True (@($preflightWith.mechanisms | Where-Object { $_ -eq 'path and URL verification preserved (no --allow-all-paths/--allow-all-urls)' }).Count -eq 1) 'Copilot preflight records preserved path and URL verification'
        }
        if ($runnerName -eq 'opencode') {
            Assert-True (@($preflightWith.checks | Where-Object { $_.name -eq 'parallel_dispatch' -and $_.status -eq 'passed' }).Count -eq 1) 'OpenCode preflight requires bounded concurrent dispatch'
            Assert-True (@($preflightWith.mechanisms | Where-Object { $_ -eq 'bounded concurrent native-worker dispatch required' }).Count -eq 1) 'OpenCode preflight records the concurrency requirement'
        }
        if ($runnerName -eq 'opencode') {
            Assert-True (@($preflightWith.warnings | Where-Object { $_ -match 'child-tool environment filter' }).Count -gt 0) "$runnerName reports the child credential-filter limitation"
        }
        if ($runnerName -eq 'codex') {
            Assert-True (-not [bool]$preflightWith.protocol_observations.allow_provider_model_fallback) 'Codex installed schema reports that provider fallback control is unavailable'
            Assert-True (@($preflightWith.checks | Where-Object { $_.name -eq 'native_worker_delegation' -and $_.detail -match 'structurally proves' }).Count -eq 1) 'Codex preflight uses structural app-server schema validation'
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
    Assert-Equal 'completed' $fileAuthResult.status 'Codex subscription app-server execution completes'
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
    Assert-Equal $fileAuthResult.evidence.execution_paths.physical_working_directory $fileAuthResult.evidence.delegation.observed_working_directory 'Codex native evidence uses the runner-declared physical cwd'
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
        [ValidateSet('with_skill', 'without_skill')][string]$Configuration,
        [string]$EvalName = 'conformance'
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
    $prompt = "# task`r`n`r`nByte fidelity: Δ and emoji 🚀.`r`n" + ("large-prompt-line-0123456789`r`n" * 4096)
    [System.IO.File]::WriteAllBytes((Join-Path $runRoot 'prompt.md'), [System.Text.UTF8Encoding]::new($false).GetBytes($prompt))
    [System.IO.File]::WriteAllText((Join-Path $homeDirectory 'expected-prompt-sha256.txt'), (Get-Sha256HexFromFile -Path (Join-Path $runRoot 'prompt.md')), [System.Text.UTF8Encoding]::new($false))
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
    $commonText = [System.IO.File]::ReadAllText((Join-Path $runnerRoot 'runner-common.ps1'), [System.Text.UTF8Encoding]::new($false))
    $orchestrationText = [System.IO.File]::ReadAllText((Join-Path $runnerRoot 'orchestration.ps1'), [System.Text.UTF8Encoding]::new($false))
    Assert-True ($prepareText -notmatch '(?i)codex\s+exec|opencode\s+run|copilot\s+-p|copilot\s+--prompt|Profile\.Provider') 'portable preparation must not contain harness-specific CLI invocations or provider-field branches'
    Assert-True ($orchestrationText -notmatch '(?i)capture-native-results\.ps1|synthesize|worker_authored') 'generic orchestration must not manufacture native terminal envelopes'
    Assert-True ($reportText -notmatch '(?i)codex\s+exec|opencode\s+run|copilot\s+-p|copilot\s+--prompt|Profile\.Provider') 'reporting must not contain harness-specific or provider-field branches'
    Assert-True ($bridgeText -notmatch '(?i)codex\s+exec|opencode\s+run|copilot\s+-p|copilot\s+--prompt|Profile\.Provider') 'the raw-to-portable bridge must remain runner-neutral'
    Assert-True ($prepareText.Contains('bridge-manifest-results.ps1')) 'handoff preparation must use the deterministic package-level manifest bridge'
    Assert-True ($prepareText.Contains('runs.<arm>.run_manifest') -and $prepareText.Contains('runs.<arm>.execution_result') -and $prepareText.Contains('runs.<arm>.result')) 'handoff preparation must require every exact manifest arm path'
    Assert-True ($prepareText.Contains('Do not derive, normalize, rename, hyphenate, underscore, or otherwise reconstruct any run, execution-result, or result path.')) 'handoff preparation must prohibit reconstructed paths'
    Assert-True ($prepareText.Contains('Read `delegation.dispatch_owner` from the selected runner descriptor and preflight.')) 'handoff preparation must make native dispatch ownership explicit'
    Assert-True ($prepareText.Contains('One arm equals one fresh native Eval Worker and one model-backed eval execution.')) 'handoff preparation must state the one-arm one-model invariant'
    Assert-True ($prepareText.Contains('For `runner`, do not spawn a model subagent first.')) 'handoff preparation must forbid an outer runner-owned model worker'
    Assert-True ($prepareText.Contains('do not invoke `record-native-result.ps1`, manufacture a native envelope')) 'runner-owned handoff must preserve runner capture without synthetic envelopes'
    Assert-True ($prepareText -notmatch '(?i)capture-native-results\.ps1') 'handoff preparation must not contain a synthetic capture helper'
    Assert-True ($prepareText.Contains('Assert-NativeWorkerDelegation')) 'handoff preparation must invoke the native delegation gate'
    Assert-True ($prepareText.Contains('Require terminal evidence for the exact selected model, exact arm identity, working directory, isolated HOME/config boundary, prompt fidelity, terminal result capture')) 'handoff preparation must require worker control evidence'
    Assert-True ($prepareText.Contains('-RequireComplete -RequireNativeDelegation -RequireParallelDispatch')) 'handoff preparation must revalidate native terminal and parallel-dispatch evidence during the manifest bridge'
    Assert-True ($prepareText.Contains('min(execution-profile.json.concurrency, remaining arms)')) 'handoff preparation must state requested concurrency fan-out'
    Assert-True ($prepareText.Contains('DISPATCH IS AN ACTION, NOT A CONFIRMATION STEP.')) 'handoff preparation must forbid confirmation pauses before native dispatch'
    Assert-True ($prepareText.Contains('sibling `Task` tool calls') -and $prepareText.Contains('same assistant turn before any result is awaited')) 'OpenCode handoff preparation must require same-turn sibling Task dispatch'
    Assert-True ($prepareText.Contains('Want me to re-dispatch...')) 'OpenCode handoff preparation must reject deferred re-dispatch questions'
    Assert-True ($prepareText.Contains('Assert-OrchestrationConcurrency') -and $prepareText.Contains('orchestration-state.json')) 'handoff preparation must persist and validate orchestration concurrency state'
    Assert-True ($prepareText.Contains('rejected before the worker starts') -and $prepareText.Contains('record no eval attempt')) 'handoff preparation must queue capacity rejections without counting attempts'
    Assert-True ($prepareText.Contains('Register each worker acceptance and terminal result exactly once') -and $prepareText.Contains('incompatibility is diagnostic-only') -and $prepareText.Contains('Do not grade incompatible arms')) 'handoff preparation must make duplicate registration and incompatible-arm handling fail closed'
    Assert-True ($prepareText.Contains('Skipping report generation because the completion gate failed') -and $prepareText.Contains('Diagnostic comparison (incomplete)')) 'incomplete collection must remain diagnostic and skip report generation'
    Assert-True ($prepareText.Contains('capture.worker_authored') -and $prepareText.Contains('Do not ask any worker or parent to author, hand-write, normalize, or repair terminal evidence.')) 'handoff preparation must require transport-produced native evidence rather than worker-authored summaries'
    Assert-True ($bridgeText.Contains('Get-PackageRunnerDescriptor') -and $bridgeText.Contains('Assert-NativeTerminalCaptureArtifact') -and $bridgeText.Contains('ExpectedMechanism')) 'native bridge must require runner-produced terminal evidence'
    Assert-True ($recordText.Contains('eval-native-worker-result/1') -and $recordText.Contains('New-ExecutionResult')) 'native terminal recording must use the runner-owned result builder'
    Assert-True ($commonText.Contains('exit.status must be a JSON number or null')) 'execution results must reject textual exit statuses'
    Assert-True ($commonText.Contains('requested.timeout_seconds') -and $commonText.Contains('execution-result.json run.$field')) 'raw execution results must retain the complete run and requested configuration contract'
    Assert-True ($prepareText.Contains('orchestration.ps1')) 'handoff preparation must load the deterministic orchestration helper'
    Assert-True ($prepareText -notmatch '<result-file>') 'handoff preparation must not expose an unconstrained result-file placeholder'
    Assert-True ($reportText -notmatch 'function Get-ResultPath') 'reporting must not contain a configuration-derived result path helper'
    Assert-True ($manifestBridgeText.Contains('Get-ManifestRunRecords') -and $manifestBridgeText.Contains('$record.ResultPath')) 'package-level bridge must resolve exact manifest records'
    Assert-True ($manifestBridgeText -notmatch 'with[-_]skill\.result\.json|without[-_]skill\.result\.json') 'package-level bridge must not encode arm-derived result filenames'

    $rawPath = Join-Path $iteration 'conformance\results\with-skill.execution-result.json'
    $resultPath = Join-Path $iteration 'conformance\results\with-skill.result.json'
    New-Item -ItemType Directory -Path (Split-Path -Parent $rawPath) -Force | Out-Null
    Write-TestJson -Path $resultPath -Value ([ordered]@{
        schema = (Get-RunnerSchemaNames).PortableResult
        eval_id = 1
        configuration = 'with_skill'
        grading = @([ordered]@{ text = 'preserved assertion'; passed = $null; evidence = '' })
    })
    $bridgeResult = Invoke-Fake -FakePath $fakePath -Command execute -Run $with.Path -Profile $profilePath

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
    Assert-Equal '2024-01-01T00:00:00.000Z' ([DateTime]$recordedResult.started_utc).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ss.fffZ') 'native terminal recording writes canonical started_utc'
    Assert-True ($recordedResult.telemetry.transcript.status -eq 'available') 'native terminal recording preserves transcript evidence'
    Assert-Equal 'harness_native_transport' $recordedResult.evidence.capture.source 'native terminal recording preserves capture provenance'
    Assert-True (-not [bool]$recordedResult.evidence.capture.worker_authored) 'native terminal recording rejects worker-authored capture provenance'

    $legacyNativeInputPath = Join-Path $iteration 'conformance\results\legacy-summary.json'
    Write-TestJson -Path $legacyNativeInputPath -Value $bridgeResult
    $legacyOutput = & pwsh -NoProfile -File $recordPath -Runner codex -Run $with.Path -Profile $codexProfilePath -NativeResult $legacyNativeInputPath -Output $nativeOutputPath 2>&1
    Assert-True ($LASTEXITCODE -ne 0) 'legacy summary-shaped worker output is rejected by the native recording boundary'
    Assert-True (([string]::Join(' ', @($legacyOutput))) -match 'eval-native-worker-result/1') 'legacy summary rejection identifies the required native envelope'

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

    $manifestStatePath = Join-Path $manifestPackage 'orchestration-state.json'
    $manifestState = [ordered]@{
        schema = 'codebeltnet/agentic/eval-orchestration-state/1'
        requested_concurrency = 2
        parallel_dispatch_required = $true
        minimum_parallel_workers = 2
        capacity_limit_reported = $false
        max_observed_active = 1
        pending_worker_ids = @()
        active = [ordered]@{}
        completed = [ordered]@{}
        delegation_rejections = [ordered]@{}
        eval_attempts = [ordered]@{ 'arm-1-with_skill' = 1; 'arm-1-without_skill' = 1 }
    }
    Write-TestJson -Path $manifestStatePath -Value $manifestState
    $serialBridgeOutput = & pwsh -NoProfile -File $manifestBridgePath -IterationDirectory $manifestPackage -RequireComplete -RequireParallelDispatch 2>&1
    Assert-True ($LASTEXITCODE -ne 0) 'manifest bridge rejects serial orchestration without capacity evidence'
    Assert-True (([string]::Join(' ', @($serialBridgeOutput))) -match 'serial|parallel') 'serial bridge rejection explains the concurrency requirement'
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

    $staleReplacement = Get-Content -LiteralPath $manifestWithExecution -Raw | ConvertFrom-Json
    $staleReplacement.run_id = 'replacement-terminal-result'
    $staleReplacement.final_response.text = 'replacement terminal output'
    Write-TestJson -Path $manifestWithExecution -Value $staleReplacement
    $replacementBridgeOutput = & pwsh -NoProfile -File $manifestBridgePath -IterationDirectory $manifestPackage -RequireComplete -RequireParallelDispatch 2>&1
    if ($LASTEXITCODE -ne 0) { throw "replacement manifest path bridge failed: $([string]::Join(' ', @($replacementBridgeOutput)))" }
    $canonicalAfterReplacement = Get-Content -LiteralPath $manifestWithResult -Raw | ConvertFrom-Json
    Assert-Equal 'replacement-terminal-result' $canonicalAfterReplacement.execution_run_id 'manifest bridge revalidates and replaces stale canonical execution evidence'
    Assert-Equal 'replacement terminal output' $canonicalAfterReplacement.output 'manifest bridge does not skip a changed raw terminal result'
    Assert-True ($null -eq $canonicalAfterReplacement.grading[0].passed) 'raw replacement clears grading tied to a prior execution run'
    Assert-True ([string]::IsNullOrWhiteSpace([string]$canonicalAfterReplacement.grading[0].evidence)) 'raw replacement clears stale grading evidence'

    $invalidExitPath = Join-Path $manifestEval 'results\invalid-exit.execution-result.json'
    $invalidExitResult = $bridgeResult | ConvertTo-Json -Depth 100 | ConvertFrom-Json
    $invalidExitResult.exit.status = 'completed'
    Write-TestJson -Path $invalidExitPath -Value $invalidExitResult
    $invalidExitOutput = & pwsh -NoProfile -File $bridgePath -Run $with.Path -ExecutionResult $invalidExitPath -Result $resultPath 2>&1
    Assert-True ($LASTEXITCODE -ne 0) 'one-arm bridge rejects a textual exit status'
    Assert-True (([string]::Join(' ', @($invalidExitOutput))) -match 'JSON number or null') 'textual exit rejection explains the numeric contract'

    $acceptedBridgeResult = $bridgeResult | ConvertTo-Json -Depth 100 | ConvertFrom-Json
    $acceptedBridgeResult.resolved.status = 'accepted_request'
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
