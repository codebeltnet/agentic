<#!
.SYNOPSIS
    Codex Eval Runner adapter.

.DESCRIPTION
    This is the only place where Codex CLI flags, CODEX_HOME handling, JSONL
    event parsing, and Codex isolation limitations are defined.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, Position = 0)]
    [ValidateSet('describe', 'preflight', 'execute')]
    [string]$Command,

    [string]$Run,
    [string]$Profile
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot '..\runner-common.ps1')

$descriptor = [ordered]@{
    schema = (Get-RunnerSchemaNames).Descriptor
    protocol_version = (Get-RunnerSchemaNames).Protocol
    name = 'codex'
    version = '0.9.1'
    platforms = @('windows', 'linux', 'macos')
    harness = [ordered]@{ name = 'OpenAI Codex CLI'; version = 'unavailable' }
    capabilities = [ordered]@{
        fresh_context = 'supported'
        isolated_home_config = 'supported'
        isolated_working_directory = 'supported'
        filesystem_confinement = 'conditional'
        ambient_candidate_skill_exclusion = 'supported'
        candidate_skill_exposure = 'supported'
        prompt_fidelity = 'supported'
        model_configuration_lock = 'supported'
        response_capture = 'supported'
        transcript_event_capture = 'supported'
        token_telemetry = 'conditional'
        cache_token_telemetry = 'conditional'
        tool_call_telemetry = 'supported'
        command_evidence = 'conditional'
        file_evidence = 'conditional'
        cost_telemetry = 'conditional'
        credential_child_filtering = 'supported'
        native_skill_activation_evidence = 'unsupported'
    }
    supported_telemetry = @('transcript_event_capture', 'token_telemetry', 'cache_token_telemetry', 'tool_call_telemetry', 'command_evidence', 'file_evidence', 'cost_telemetry')
    configuration_profiles = @('isolated-default')
    tool_profiles = @('default')
}

function Write-ProtocolError {
    param([string]$Message)

    [Console]::Error.WriteLine($Message)
    exit 2
}

function Resolve-CodexInputs {
    if ([string]::IsNullOrWhiteSpace($Run) -or [string]::IsNullOrWhiteSpace($Profile)) {
        throw 'preflight and execute require -Run and -Profile.'
    }
    return [pscustomobject]@{
        Run = Resolve-RunContract -RunPath $Run
        Profile = Resolve-ExecutionProfile -ProfilePath $Profile
    }
}

function Get-CodexAuthSource {
    param([Parameter(Mandatory = $true)][string]$Provider)

    $authVariables = @(Get-ProviderAuthenticationVariables -Provider $Provider)
    foreach ($name in $authVariables) {
        if (-not [string]::IsNullOrWhiteSpace([Environment]::GetEnvironmentVariable($name))) {
            return [pscustomobject]@{ Kind = 'environment'; Name = $name; Path = $null }
        }
    }

    $configuredHome = [Environment]::GetEnvironmentVariable('CODEX_HOME')
    $codexHome = if ([string]::IsNullOrWhiteSpace($configuredHome)) {
        Join-Path ([Environment]::GetFolderPath('UserProfile')) '.codex'
    } else {
        $configuredHome
    }
    $authPath = Join-Path $codexHome 'auth.json'
    if (Test-Path -LiteralPath $authPath -PathType Leaf) {
        return [pscustomobject]@{ Kind = 'file_unsupported'; Name = 'auth.json'; Path = (Resolve-Path -LiteralPath $authPath).Path }
    }

    return [pscustomobject]@{ Kind = 'missing'; Name = $null; Path = $null }
}

function Invoke-CodexCli {
    param(
        [Parameter(Mandatory = $true)][object]$CommandInfo,
        [Parameter(Mandatory = $true)][string[]]$Arguments,
        [Parameter(Mandatory = $true)][object]$Inputs,
        [System.Collections.IDictionary]$Environment,
        [byte[]]$InputBytes = @(),
        [int]$TimeoutSeconds = 60
    )

    $allArguments = @($CommandInfo.Prefix) + @($Arguments)
    return Invoke-RunnerProcess -FileName $CommandInfo.FileName -ArgumentList $allArguments -WorkingDirectory $Inputs.Run.WorkingDirectoryPath -Environment $Environment -InputBytes $InputBytes -TimeoutSeconds $TimeoutSeconds
}

function Get-CodexHelpResult {
    param(
        [Parameter(Mandatory = $true)][object]$CommandInfo,
        [Parameter(Mandatory = $true)][object]$Inputs,
        [string[]]$Arguments = @('--ask-for-approval', 'never', 'exec', '--help')
    )

    $environment = New-RunnerEnvironment -Run $Inputs.Run
    return Invoke-CodexCli -CommandInfo $CommandInfo -Arguments $Arguments -Inputs $Inputs -Environment $environment -TimeoutSeconds 30
}

function Resolve-SandboxCommand {
    param([Parameter(Mandatory = $true)][string]$Name)

    return Resolve-ExternalCommand -Name $Name
}

function Get-CodexDescriptor {
    $copy = [ordered]@{}
    foreach ($key in $descriptor.Keys) { $copy[$key] = $descriptor[$key] }
    $commandInfo = Resolve-ExternalCommand -Name 'codex'
    $version = 'unavailable'
    if ($null -ne $commandInfo) {
        $observation = Get-ExternalCommandVersion -CommandInfo $commandInfo
        $version = [string]$observation.Version
    }
    $copy.harness = [ordered]@{ name = 'OpenAI Codex CLI'; version = $version }
    return $copy
}

function New-CodexCliArguments {
    param(
        [Parameter(Mandatory = $true)][object]$Inputs,
        [Parameter(Mandatory = $true)][string]$LastResponsePath,
        [ValidateSet('windows', 'linux', 'macos', 'unknown')][string]$VisiblePlatform = (Get-PlatformName)
    )

    $directoryArgument = Get-SandboxVisiblePath -HostPath $Inputs.Run.WorkingDirectoryPath -RunRoot $Inputs.Run.RunRoot -Platform $VisiblePlatform
    $outputArgument = Get-SandboxVisiblePath -HostPath $LastResponsePath -RunRoot $Inputs.Run.RunRoot -Platform $VisiblePlatform
    $arguments = [System.Collections.Generic.List[string]]::new()
    foreach ($argument in @('--ask-for-approval', 'never', 'exec', '--ephemeral', '--ignore-user-config', '--ignore-rules', '--skip-git-repo-check', '--json', '--color', 'never', '--cd', $directoryArgument, '--model', $Inputs.Profile.Model, '--sandbox', 'workspace-write', '--config', 'shell_environment_policy.inherit=none', '--output-last-message', $outputArgument)) {
        $arguments.Add([string]$argument)
    }
    if (-not [string]::IsNullOrWhiteSpace([string]$Inputs.Profile.ReasoningEffort)) {
        $arguments.Add('-c')
        $arguments.Add("model_reasoning_effort=$($Inputs.Profile.ReasoningEffort)")
    }
    $arguments.Add('-')
    return @($arguments)
}

function Get-CodexCapabilityMap {
    param(
        [Parameter(Mandatory = $true)][object]$Inputs,
        [bool]$HardFilesystemConfinement = $false
    )

    $capabilities = [ordered]@{}
    foreach ($capabilityName in @(Get-JsonPropertyNames -Object $descriptor.capabilities)) {
        $capabilities[$capabilityName] = [string](Get-JsonProperty -Object $descriptor.capabilities -Name $capabilityName)
    }
    $capabilities['filesystem_confinement'] = if ($HardFilesystemConfinement) { 'supported' } else { 'unsupported' }
    $capabilities['candidate_skill_exposure'] = if ($Inputs.Run.CandidateSkillExposed) { 'supported' } else { 'excluded' }
    return $capabilities
}

function Get-CodexPreflight {
    param([Parameter(Mandatory = $true)][object]$Inputs)

    $checks = [System.Collections.Generic.List[object]]::new()
    $reasons = [System.Collections.Generic.List[string]]::new()
    $warnings = [System.Collections.Generic.List[string]]::new()
    $profile = $Inputs.Profile
    $run = $Inputs.Run
    $commandInfo = Resolve-ExternalCommand -Name 'codex'
    $platform = Get-PlatformName
    $sandboxName = switch ($platform) {
        'linux' { 'bwrap' }
        'macos' { 'sandbox-exec' }
        default { $null }
    }
    $sandboxInfo = if ([string]::IsNullOrWhiteSpace([string]$sandboxName)) { $null } else { Resolve-SandboxCommand -Name $sandboxName }
    $versionObservation = $null

    if ($profile.Runner -ne 'codex') {
        $reasons.Add("execution-profile.json selects '$($profile.Runner)' rather than codex.")
    } else {
        $checks.Add((New-PreflightCheck -Name 'runner_selection' -Status passed -Detail 'The selected runner is codex.'))
    }
    if ([string]::IsNullOrWhiteSpace($profile.Provider) -or $profile.Provider.ToLowerInvariant() -notin @('openai', 'chatgpt')) {
        $reasons.Add("Codex requires provider 'openai' or 'chatgpt'; received '$($profile.Provider)'.")
    } else {
        $checks.Add((New-PreflightCheck -Name 'provider' -Status passed -Detail $profile.Provider))
    }
    if ([string]::IsNullOrWhiteSpace($profile.Model)) {
        $reasons.Add('Codex requires a model in execution-profile.json.')
    } else {
        $checks.Add((New-PreflightCheck -Name 'model' -Status passed -Detail $profile.Model))
    }
    if ($profile.ConfigurationProfile -ne 'isolated-default') {
        $reasons.Add("configuration_profile '$($profile.ConfigurationProfile)' is unsupported by codex.")
    }
    if ($profile.ToolProfile -ne 'default') {
        $reasons.Add("tool_profile '$($profile.ToolProfile)' is unsupported by codex.")
    }

    if ($null -eq $commandInfo) {
        $reasons.Add('The Codex CLI executable is not available on PATH.')
    } else {
        $checks.Add((New-PreflightCheck -Name 'harness_executable' -Status passed -Detail $commandInfo.Source))
        try {
            $versionObservation = Get-ExternalCommandVersion -CommandInfo $commandInfo -WorkingDirectory $run.WorkingDirectoryPath -Environment (New-RunnerEnvironment -Run $run) -TimeoutSeconds 30
            if (-not $versionObservation.Available) {
                $reasons.Add('The Codex CLI did not expose an exact observable version through --version.')
                $checks.Add((New-PreflightCheck -Name 'harness_version' -Status unavailable -Detail 'codex --version did not return a usable version string.'))
            } else {
                $checks.Add((New-PreflightCheck -Name 'harness_version' -Status passed -Detail ([string]$versionObservation.Version)))
            }

            $globalHelp = Get-CodexHelpResult -CommandInfo $commandInfo -Inputs $Inputs -Arguments @('--help')
            $help = Get-CodexHelpResult -CommandInfo $commandInfo -Inputs $Inputs
            if ($globalHelp.TimedOut -or $globalHelp.ExitCode -ne 0) {
                $reasons.Add("Codex --help failed with exit status $($globalHelp.ExitCode).")
            }
            if ($help.TimedOut -or $help.ExitCode -ne 0) {
                $reasons.Add("Codex --ask-for-approval never exec --help failed with exit status $($help.ExitCode).")
            } else {
                $helpText = [string]::Join("`n", @($globalHelp.Stdout, $globalHelp.Stderr, $help.Stdout, $help.Stderr))
                foreach ($flag in @('--ask-for-approval', '--ephemeral', '--ignore-user-config', '--ignore-rules', '--json', '--output-last-message', '--sandbox', '--cd', '--model', '--config')) {
                    if ($helpText -notmatch [regex]::Escape($flag)) {
                        $reasons.Add("The installed Codex CLI does not advertise required flag '$flag'.")
                    }
                }
                $visiblePlatform = if ($platform -eq 'linux' -and $null -ne $sandboxInfo) { 'linux' } else { $platform }
                $constructed = New-CodexCliArguments -Inputs $Inputs -LastResponsePath (Join-Path $run.RunRoot 'evidence/codex-final.txt') -VisiblePlatform $visiblePlatform
                if (@($constructed) -contains '--approve-for-me') {
                    $reasons.Add('The constructed Codex invocation must not combine --approve-for-me with explicit --sandbox selection.')
                }
                $sandboxIndex = [Array]::IndexOf([string[]]$constructed, '--sandbox')
                $approvalIndex = [Array]::IndexOf([string[]]$constructed, '--ask-for-approval')
                $execIndex = [Array]::IndexOf([string[]]$constructed, 'exec')
                if ($approvalIndex -lt 0 -or $execIndex -lt 0 -or $approvalIndex -gt $execIndex -or $sandboxIndex -lt 0) {
                    $reasons.Add('The constructed Codex invocation must set --ask-for-approval never before exec and retain --sandbox workspace-write.')
                }
                if ($reasons.Count -eq 0) {
                    $checks.Add((New-PreflightCheck -Name 'harness_contract' -Status passed -Detail 'Codex accepts the constructed noninteractive invocation: --ask-for-approval never, exec, --sandbox workspace-write, ephemeral JSON output, and isolated configuration controls.'))
                }
            }
        } catch {
            $reasons.Add("Could not inspect Codex CLI capabilities: $($_.Exception.Message)")
        }
    }

    $auth = Get-CodexAuthSource -Provider ([string]$profile.Provider)
    if ($auth.Kind -eq 'missing') {
        $reasons.Add('No narrow Codex provider API-key environment variable is available.')
    } elseif ($auth.Kind -eq 'file_unsupported') {
        $reasons.Add('Codex auth.json cannot be copied into the worker HOME: the evaluated agent could read that credential file. Set the provider API-key environment variable instead.')
    } else {
        $checks.Add((New-PreflightCheck -Name 'authentication' -Status passed -Detail "Authentication is available through the narrow $($auth.Name) environment variable; the child shell policy is set to inherit=none."))
    }

    if ($null -eq $sandboxName) {
        $checks.Add((New-PreflightCheck -Name 'filesystem_confinement' -Status not_applicable -Detail "Platform '$platform' has no configured external hard-confinement mechanism; pragmatic isolation remains available."))
        $warnings.Add("Platform '$platform' has no external hard filesystem confinement in this adapter; execution will report pragmatic isolation.")
    } elseif ($null -eq $sandboxInfo) {
        $checks.Add((New-PreflightCheck -Name 'filesystem_confinement' -Status unavailable -Detail "External '$sandboxName' is unavailable; pragmatic isolation remains available."))
        $warnings.Add("External '$sandboxName' was unavailable; execution will report pragmatic isolation.")
    } else {
        $checks.Add((New-PreflightCheck -Name 'filesystem_confinement' -Status passed -Detail "External $sandboxName confines Codex to the staged run and required system runtime paths; Codex sandbox=workspace-write remains enabled inside it."))
    }

    $checks.Add((New-PreflightCheck -Name 'fresh_session' -Status passed -Detail 'The adapter uses --ephemeral and never supplies a resume, continue, or session identifier.'))
    $checks.Add((New-PreflightCheck -Name 'ambient_configuration' -Status passed -Detail 'The adapter uses an isolated CODEX_HOME plus --ignore-user-config and --ignore-rules; unrelated inherited environment variables are removed.'))
    $checks.Add((New-PreflightCheck -Name 'run_paths' -Status passed -Detail "--cd $($run.WorkingDirectoryPath); CODEX_HOME under $($run.HomeDirectoryPath)"))
    $checks.Add((New-PreflightCheck -Name 'credential_boundary' -Status passed -Detail 'Only the selected provider API-key variable is passed to Codex; auth files are never copied into the worker HOME.'))

    $hardConfinement = $null -ne $sandboxInfo -and $platform -in @('linux', 'macos')
    $capabilities = Get-CodexCapabilityMap -Inputs $Inputs -HardFilesystemConfinement $hardConfinement
    $harnessVersion = if ($null -eq $versionObservation) { 'unavailable' } else { [string]$versionObservation.Version }
    $descriptorCopy = [ordered]@{}
    foreach ($key in $descriptor.Keys) { $descriptorCopy[$key] = $descriptor[$key] }
    $descriptorCopy.harness = [ordered]@{ name = 'OpenAI Codex CLI'; version = $harnessVersion }
    $mechanisms = [System.Collections.Generic.List[string]]::new()
    foreach ($mechanism in @('--ask-for-approval never', 'codex exec --ephemeral', '--ignore-user-config', '--ignore-rules', '--sandbox workspace-write', 'shell_environment_policy.inherit=none', 'isolated CODEX_HOME', 'prompt on stdin', 'no session continuation')) { $mechanisms.Add($mechanism) }
    if ($hardConfinement) { $mechanisms.Add("external $sandboxName filesystem sandbox") } else { $mechanisms.Add('pragmatic process/environment isolation without hard filesystem confinement') }
    return New-PreflightDocument -Descriptor $descriptorCopy -Profile $profile -Run $run -Compatible ($reasons.Count -eq 0) -Checks @($checks) -Mechanisms @($mechanisms) -ResolvedCapabilities $capabilities -Warnings @($warnings) -Reasons @($reasons)
}

function New-CodexEnvironment {
    param(
        [Parameter(Mandatory = $true)][object]$Inputs,
        [Parameter(Mandatory = $true)][object]$Auth
    )

    $codexHome = Join-Path $Inputs.Run.HomeDirectoryPath '.codex'
    New-Item -ItemType Directory -Path $codexHome -Force | Out-Null
    $environment = New-RunnerEnvironment -Run $Inputs.Run -AuthenticationVariables @(Get-ProviderAuthenticationVariables -Provider ([string]$Inputs.Profile.Provider)) -Additional @{ CODEX_HOME = $codexHome }
    if ($Auth.Kind -ne 'environment') {
        throw 'Codex execution requires a provider environment credential; file credentials are not safe to expose in the worker HOME.'
    }
    return $environment
}

function Get-LinuxCodexSandboxArguments {
    param(
        [Parameter(Mandatory = $true)][object]$Inputs,
        [Parameter(Mandatory = $true)][object]$CommandInfo,
        [Parameter(Mandatory = $true)][System.Collections.IDictionary]$Environment
    )

    $args = [System.Collections.Generic.List[string]]::new()
    foreach ($argument in @('--die-with-parent', '--new-session', '--unshare-pid')) { $args.Add($argument) }
    foreach ($path in @('/usr', '/usr/local', '/bin', '/sbin', '/lib', '/lib64', '/libexec', '/etc', '/opt')) {
        if (Test-Path -LiteralPath $path) {
            $args.Add('--ro-bind'); $args.Add($path); $args.Add($path)
        }
    }
    $args.Add('--proc'); $args.Add('/proc')
    $args.Add('--dev'); $args.Add('/dev')
    $args.Add('--tmpfs'); $args.Add('/tmp')
    $args.Add('--bind'); $args.Add($Inputs.Run.RunRoot); $args.Add('/run')
    $commandSource = [string]$CommandInfo.Source
    $commandDirectory = Split-Path -Parent $commandSource
    if (-not ($commandSource.StartsWith('/usr/', [System.StringComparison]::Ordinal) -or $commandSource.StartsWith('/bin/', [System.StringComparison]::Ordinal) -or $commandSource.StartsWith('/opt/', [System.StringComparison]::Ordinal))) {
        if (Test-Path -LiteralPath $commandDirectory -PathType Container) {
            $args.Add('--ro-bind'); $args.Add($commandDirectory); $args.Add($commandDirectory)
        }
    }
    $args.Add('--chdir'); $args.Add('/run/repo')
    $insideEnvironment = [ordered]@{
        HOME = '/run/home'
        USERPROFILE = '/run/home'
        XDG_CONFIG_HOME = '/run/home/.config'
        XDG_DATA_HOME = '/run/home/.local/share'
        XDG_CACHE_HOME = '/run/home/.cache'
        TEMP = '/run/home/tmp'
        TMP = '/run/home/tmp'
        CODEX_HOME = '/run/home/.codex'
        PATH = '/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin'
        CI = '1'
        NO_COLOR = '1'
    }
    foreach ($authName in @(Get-ProviderAuthenticationVariables -Provider ([string]$Inputs.Profile.Provider))) {
        if ($Environment.Contains($authName) -and -not [string]::IsNullOrWhiteSpace([string]$Environment[$authName])) {
            $insideEnvironment[$authName] = [string]$Environment[$authName]
        }
    }
    foreach ($key in @($insideEnvironment.Keys)) {
        $args.Add('--setenv'); $args.Add($key); $args.Add([string]$insideEnvironment[$key])
    }
    $args.Add('--')
    $args.Add($CommandInfo.FileName)
    foreach ($prefix in @($CommandInfo.Prefix)) { $args.Add($prefix) }
    return @($args)
}

function New-CodexMacosSandboxProfile {
    param(
        [Parameter(Mandatory = $true)][object]$Inputs,
        [Parameter(Mandatory = $true)][object]$CommandInfo
    )

    $profilePath = Join-Path $Inputs.Run.HomeDirectoryPath 'codex-sandbox.sb'
    $runRoot = $Inputs.Run.RunRoot.Replace('\', '/')
    $commandDirectory = (Split-Path -Parent ([string]$CommandInfo.Source)).Replace('\', '/')
    $readRoots = @('/usr', '/usr/local', '/bin', '/sbin', '/lib', '/libexec', '/System', '/Library', '/opt', '/private/var/db', $commandDirectory)
    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add('(version 1)')
    $lines.Add('(deny default)')
    $lines.Add('(allow process*)')
    $lines.Add('(allow network*)')
    foreach ($root in $readRoots | Sort-Object -Unique) {
        if (-not [string]::IsNullOrWhiteSpace($root) -and (Test-Path -LiteralPath $root -PathType Container)) {
            $escapedRoot = $root.Replace('\', '/').Replace('"', '\"')
            $lines.Add(('(allow file-read* (subpath "{0}"))' -f $escapedRoot))
        }
    }
    $escapedRunRoot = $runRoot.Replace('"', '\"')
    $lines.Add(('(allow file-read* (subpath "{0}"))' -f $escapedRunRoot))
    $lines.Add(('(allow file-write* (subpath "{0}"))' -f $escapedRunRoot))
    $lines.Add('(allow file-read* (subpath "/dev"))')
    $lines.Add('(allow file-write* (subpath "/dev/null"))')
    [System.IO.File]::WriteAllText($profilePath, ([string]::Join("`n", $lines) + "`n"), [System.Text.UTF8Encoding]::new($false))
    return $profilePath
}

function Write-CodexCapture {
    param(
        [Parameter(Mandatory = $true)][object]$RunData,
        [Parameter(Mandatory = $true)][string]$RelativePath,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Text
    )

    $path = Join-Path $RunData.Run.RunRoot ($RelativePath -replace '/', [System.IO.Path]::DirectorySeparatorChar)
    $parent = Split-Path -Parent $path
    New-Item -ItemType Directory -Path $parent -Force | Out-Null
    [System.IO.File]::WriteAllText($path, $Text, [System.Text.UTF8Encoding]::new($false))
    return New-ArtifactReference -Run $RunData.Run -Path $RelativePath -Scope run -MediaType (Get-MediaType -Path $RelativePath)
}

function Invoke-CodexExecute {
    param([Parameter(Mandatory = $true)][object]$Inputs)

    $preflight = Get-CodexPreflight -Inputs $Inputs
    $started = [DateTime]::UtcNow
    $sessionId = [Guid]::NewGuid().ToString('D')
    $executionDescriptor = [ordered]@{}
    foreach ($key in $descriptor.Keys) { $executionDescriptor[$key] = $descriptor[$key] }
    $executionDescriptor.harness = $preflight.harness
    if ($preflight.status -ne 'compatible') {
        $finished = [DateTime]::UtcNow
        $failureText = [string]::Join('; ', @($preflight.reasons))
        return New-ExecutionResult -Descriptor $executionDescriptor -Profile $Inputs.Profile -Run $Inputs.Run -Status incompatible -FinalResponseReason 'preflight_incompatible' -StartedUtc $started.ToString('o') -FinishedUtc $finished.ToString('o') -DurationSeconds ($finished - $started).TotalSeconds -Failure (New-ExecutionFailure -Code 'incompatible' -Message $failureText) -SessionId $sessionId -IsolationCapabilities ([ordered]@{}) -IsolationMechanisms @('preflight-only') -Evidence ([ordered]@{ preflight = $preflight; resume = $false }) -AttemptCount 1
    }

    $commandInfo = Resolve-ExternalCommand -Name 'codex'
    $auth = Get-CodexAuthSource -Provider ([string]$Inputs.Profile.Provider)
    $environment = New-CodexEnvironment -Inputs $Inputs -Auth $auth
    $lastResponsePath = 'evidence/codex-final.txt'
    New-Item -ItemType Directory -Path (Join-Path $Inputs.Run.RunRoot 'evidence') -Force | Out-Null
    $platform = Get-PlatformName
    $sandboxInfo = if ($platform -eq 'linux') { Resolve-SandboxCommand -Name 'bwrap' } elseif ($platform -eq 'macos') { Resolve-SandboxCommand -Name 'sandbox-exec' } else { $null }
    $hardFilesystem = $null -ne $sandboxInfo -and $platform -in @('linux', 'macos')
    $visiblePlatform = if ($hardFilesystem) { $platform } elseif ($platform -eq 'linux') { 'unknown' } else { $platform }
    $arguments = New-CodexCliArguments -Inputs $Inputs -LastResponsePath (Join-Path $Inputs.Run.RunRoot ($lastResponsePath -replace '/', [System.IO.Path]::DirectorySeparatorChar)) -VisiblePlatform $visiblePlatform

    if ($platform -eq 'linux' -and $hardFilesystem) {
        $sandboxArguments = Get-LinuxCodexSandboxArguments -Inputs $Inputs -CommandInfo $commandInfo -Environment $environment
        $process = Invoke-RunnerProcess -FileName $sandboxInfo.FileName -ArgumentList (@($sandboxArguments) + @($arguments)) -WorkingDirectory $Inputs.Run.WorkingDirectoryPath -Environment $environment -InputBytes $Inputs.Run.PromptBytes -TimeoutSeconds $Inputs.Profile.TimeoutSeconds
    } elseif ($platform -eq 'macos' -and $hardFilesystem) {
        $sandboxProfile = New-CodexMacosSandboxProfile -Inputs $Inputs -CommandInfo $commandInfo
        $sandboxArguments = @('-f', $sandboxProfile, '--', $commandInfo.FileName) + @($commandInfo.Prefix) + @($arguments)
        $process = Invoke-RunnerProcess -FileName $sandboxInfo.FileName -ArgumentList $sandboxArguments -WorkingDirectory $Inputs.Run.WorkingDirectoryPath -Environment $environment -InputBytes $Inputs.Run.PromptBytes -TimeoutSeconds $Inputs.Profile.TimeoutSeconds
    } else {
        $process = Invoke-CodexCli -CommandInfo $commandInfo -Arguments $arguments -Inputs $Inputs -Environment $environment -InputBytes $Inputs.Run.PromptBytes -TimeoutSeconds $Inputs.Profile.TimeoutSeconds
    }
    $stdoutArtifact = Write-CodexCapture -RunData $Inputs -RelativePath 'evidence/codex-events.jsonl' -Text $process.Stdout
    $stderrArtifact = Write-CodexCapture -RunData $Inputs -RelativePath 'evidence/codex-stderr.txt' -Text $process.Stderr
    $artifacts = [System.Collections.Generic.List[object]]::new()
    $artifacts.Add($stdoutArtifact)
    $artifacts.Add($stderrArtifact)

    $parsed = ConvertFrom-JsonLines -Text $process.Stdout
    $warnings = [System.Collections.Generic.List[string]]::new()
    foreach ($parseError in @($parsed.Errors)) { $warnings.Add("Codex event parse error: $parseError") }
    $finalText = $null
    $threadId = $null
    $turnFailure = $null
    $usage = $null
    $toolCalls = 0
    $commands = [System.Collections.Generic.List[object]]::new()
    $files = [System.Collections.Generic.List[object]]::new()
    $eventCounts = @{}
    foreach ($event in @($parsed.Events)) {
        $eventType = [string](Get-JsonProperty -Object $event -Name 'type' -Default '')
        if ([string]::IsNullOrWhiteSpace($eventType)) {
            $warnings.Add('Codex emitted an event without a type; it was ignored.')
            continue
        }
        if ($eventCounts.ContainsKey($eventType)) { $eventCounts[$eventType]++ } else { $eventCounts[$eventType] = 1 }
        switch ($eventType) {
            'thread.started' { $threadId = [string](Get-JsonProperty -Object $event -Name 'thread_id' -Default '') }
            'item.completed' {
                $item = Get-JsonProperty -Object $event -Name 'item' -Default $null
                $itemType = [string](Get-JsonProperty -Object $item -Name 'type' -Default '')
                if ($itemType -eq 'agent_message') {
                    $candidate = [string](Get-JsonProperty -Object $item -Name 'text' -Default '')
                    if (-not [string]::IsNullOrWhiteSpace($candidate)) { $finalText = $candidate }
                } elseif ($itemType -in @('command_execution', 'mcp_tool_call', 'file_change')) {
                    $toolCalls++
                    if ($itemType -eq 'command_execution') {
                        $commands.Add([ordered]@{ type = $itemType; command = Get-JsonProperty -Object $item -Name 'command'; exit_code = Get-JsonProperty -Object $item -Name 'exit_code' })
                    } else {
                        $files.Add([ordered]@{ type = $itemType; item = $itemType })
                    }
                }
            }
            'turn.completed' {
                $usage = Get-JsonProperty -Object $event -Name 'usage' -Default $null
            }
            'turn.failed' { $turnFailure = Get-JsonProperty -Object $event -Name 'error' -Default 'Codex turn failed.' }
            'error' { $turnFailure = Get-JsonProperty -Object $event -Name 'message' -Default 'Codex emitted an error.' }
            { $_ -in @('turn.started', 'item.started', 'item.updated') } { }
            default { $warnings.Add("Unknown Codex event '$eventType' was preserved as a warning.") }
        }
    }
    if (Test-Path -LiteralPath (Join-Path $Inputs.Run.RunRoot ($lastResponsePath -replace '/', [System.IO.Path]::DirectorySeparatorChar)) -PathType Leaf) {
        $lastArtifact = New-ArtifactReference -Run $Inputs.Run -Path $lastResponsePath -Scope run -MediaType 'text/plain; charset=utf-8'
        $artifacts.Add($lastArtifact)
        if ([string]::IsNullOrWhiteSpace($finalText)) {
            $finalText = [System.IO.File]::ReadAllText((Join-Path $Inputs.Run.RunRoot ($lastResponsePath -replace '/', [System.IO.Path]::DirectorySeparatorChar)), [System.Text.UTF8Encoding]::new($false))
        }
    }

    $status = 'completed'
    $reason = $null
    $failure = $null
    $exitStatus = if ($process.TimedOut) { $null } else { [Nullable[int]]$process.ExitCode }
    if ($process.TimedOut) {
        $status = 'timed_out'
        $reason = 'codex_timeout'
        $failure = New-ExecutionFailure -Code 'timed_out' -Message 'Codex did not finish before timeout_seconds.'
    } elseif ($process.ExitCode -ne 0 -or $null -ne $turnFailure) {
        $status = 'failed'
        $reason = 'codex_failure'
        $failure = New-ExecutionFailure -Code 'codex_failure' -Message ([string]$turnFailure)
    } elseif ([string]::IsNullOrWhiteSpace($finalText)) {
        $warnings.Add('Codex exited successfully without a final agent message.')
        $reason = 'codex_did_not_return_final_response'
    }

    $tokenMetric = if ($null -eq $usage) {
        New-UnavailableMetric -Reason 'codex_did_not_expose_turn_usage'
    } else {
        $usageValue = [ordered]@{}
        foreach ($name in @('input_tokens', 'cached_input_tokens', 'output_tokens', 'reasoning_output_tokens')) {
            $value = Get-JsonProperty -Object $usage -Name $name -Default $null
            if ($null -ne $value) { $usageValue[$name] = $value }
        }
        if ($usageValue.Count -eq 0) { New-UnavailableMetric -Reason 'codex_usage_event_had_no_supported_buckets' } else { New-AvailableMetric -Value $usageValue }
    }
    $telemetry = [ordered]@{
        transcript = New-AvailableMetric -Value ([ordered]@{ artifact = 'evidence/codex-events.jsonl'; complete = $true })
        tokens = $tokenMetric
        tool_calls = New-AvailableMetric -Value $toolCalls
        cost = New-UnavailableMetric -Reason 'codex_runner_does_not_estimate_cost'
    }
    $finished = [DateTime]::UtcNow
    $sessionResultId = if ([string]::IsNullOrWhiteSpace($threadId)) { $sessionId } else { $threadId }
    $capabilities = Get-CodexCapabilityMap -Inputs $Inputs -HardFilesystemConfinement $hardFilesystem
    $mechanisms = [System.Collections.Generic.List[string]]::new()
    foreach ($mechanism in @('--ask-for-approval never', 'codex exec --ephemeral', '--ignore-user-config', '--ignore-rules', '--sandbox workspace-write', 'shell_environment_policy.inherit=none', 'isolated CODEX_HOME', 'prompt on stdin', 'no session continuation')) { $mechanisms.Add($mechanism) }
    if ($hardFilesystem) { $mechanisms.Add("external $($sandboxInfo.Source) filesystem sandbox") } else { $mechanisms.Add('pragmatic process/environment isolation without hard filesystem confinement') }
    if (-not $hardFilesystem) { $warnings.Add('Hard filesystem confinement was unavailable; the completed arm is reported as pragmatic isolation.') }
    $sandboxEvidence = if (-not $hardFilesystem) { 'unavailable' } elseif ($platform -eq 'linux') { 'bwrap' } else { 'sandbox-exec' }
    $credentialEvidence = [ordered]@{
        source = $auth.Kind
        provider_environment_variable = $auth.Name
        unrelated_environment_excluded = $true
        child_tool_visibility = 'codex_shell_environment_policy_inherit_none'
        value_observed = $false
    }
    return New-ExecutionResult -Descriptor $executionDescriptor -Profile $Inputs.Profile -Run $Inputs.Run -Status $status -FinalResponse $finalText -FinalResponseReason $reason -StartedUtc $process.StartedUtc.ToString('o') -FinishedUtc $finished.ToString('o') -DurationSeconds $process.DurationSeconds -ExitStatus $exitStatus -Failure $failure -SessionId $sessionResultId -IsolationCapabilities $capabilities -IsolationMechanisms @($mechanisms) -ResolvedConfiguration ([ordered]@{ status = 'accepted_request'; reason = 'Codex accepted the requested provider, model, and configuration but did not expose concrete backend resolution.'; observations = [ordered]@{ provider = $Inputs.Profile.Provider; model = $Inputs.Profile.Model; reasoning_effort = $Inputs.Profile.ReasoningEffort } }) -Telemetry $telemetry -Artifacts @($artifacts) -Warnings @($warnings) -Evidence ([ordered]@{ thread_id = $threadId; event_counts = $eventCounts; commands = @($commands); files = @($files); prompt_first_input = $true; resume = $false; stdout_exit_code = $process.ExitCode; sandbox = $sandboxEvidence; output_last_message_argument = (Get-SandboxVisiblePath -HostPath (Join-Path $Inputs.Run.RunRoot ($lastResponsePath -replace '/', [System.IO.Path]::DirectorySeparatorChar)) -RunRoot $Inputs.Run.RunRoot -Platform $visiblePlatform); credential = $credentialEvidence }) -AttemptCount 1
}

try {
    [void](Assert-RunnerDescriptor -Descriptor $descriptor)
    switch ($Command) {
        'describe' { Write-RunnerJson -Value (Get-CodexDescriptor) -AsOutput }
        'preflight' {
            $inputs = Resolve-CodexInputs
            Write-RunnerJson -Value (Get-CodexPreflight -Inputs $inputs) -AsOutput
        }
        'execute' {
            $inputs = Resolve-CodexInputs
            $result = Invoke-CodexExecute -Inputs $inputs
            [void](Assert-ExecutionResult -Result $result)
            Write-RunnerJson -Value $result -AsOutput
        }
    }
} catch {
    Write-ProtocolError -Message $_.Exception.Message
}
