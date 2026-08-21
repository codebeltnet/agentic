Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-RunnerSchemaNames {
    return [ordered]@{
        Protocol = 'codebeltnet/agentic/eval-runner-protocol/1'
        Descriptor = 'codebeltnet/agentic/eval-runner-descriptor/1'
        Preflight = 'codebeltnet/agentic/eval-runner-preflight/1'
        Profile = 'codebeltnet/agentic/eval-execution-profile/1'
        Result = 'codebeltnet/agentic/eval-execution-result/1'
        PortableResult = 'codebeltnet/agentic/eval-result/2'
        Run = 'codebeltnet/agentic/eval-run/1'
    }
}

function Get-JsonProperty {
    param(
        [object]$Object,
        [string]$Name,
        [object]$Default = $null
    )

    if ($null -ne $Object -and $Object -is [System.Collections.IDictionary] -and $Object.Contains($Name)) {
        if ($null -ne $Object[$Name]) {
            return $Object[$Name]
        }
        return $Default
    }

    if ($null -ne $Object -and $Object.PSObject.Properties.Name -contains $Name -and $null -ne $Object.$Name) {
        return $Object.$Name
    }

    return $Default
}

function Get-JsonPropertyNames {
    param([object]$Object)

    if ($null -eq $Object) {
        return @()
    }
    if ($Object -is [System.Collections.IDictionary]) {
        return @($Object.Keys | ForEach-Object { [string]$_ })
    }
    return @($Object.PSObject.Properties.Name)
}

function Test-JsonProperty {
    param(
        [object]$Object,
        [Parameter(Mandatory = $true)][string]$Name
    )

    return (Get-JsonPropertyNames -Object $Object) -contains $Name
}

function Read-RunnerJson {
    param([Parameter(Mandatory = $true)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "JSON file '$Path' does not exist."
    }

    return [System.IO.File]::ReadAllText((Resolve-Path -LiteralPath $Path).Path, [System.Text.UTF8Encoding]::new($false)) | ConvertFrom-Json
}

function Write-RunnerJson {
    param(
        [Parameter(Mandatory = $true)][object]$Value,
        [switch]$AsOutput
    )

    $json = ((ConvertTo-Json -InputObject $Value -Depth 100) + [Environment]::NewLine)
    if ($AsOutput) {
        [Console]::Out.Write($json)
        return
    }

    return $json
}

function Get-Sha256HexFromBytes {
    param([Parameter(Mandatory = $true)][byte[]]$Bytes)

    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        return ([Convert]::ToHexString($sha.ComputeHash($Bytes))).ToLowerInvariant()
    } finally {
        $sha.Dispose()
    }
}

function Get-Sha256HexFromFile {
    param([Parameter(Mandatory = $true)][string]$Path)

    $resolved = (Resolve-Path -LiteralPath $Path -ErrorAction Stop).Path
    return Get-Sha256HexFromBytes -Bytes ([System.IO.File]::ReadAllBytes($resolved))
}

function Test-Sha256 {
    param([string]$Value)

    return -not [string]::IsNullOrWhiteSpace($Value) -and $Value -match '^[0-9a-fA-F]{64}$'
}

function Test-PathInside {
    param(
        [Parameter(Mandatory = $true)][string]$BasePath,
        [Parameter(Mandatory = $true)][string]$CandidatePath
    )

    $base = ([System.IO.Path]::GetFullPath($BasePath)).TrimEnd([char[]]@('\', '/'))
    $candidate = ([System.IO.Path]::GetFullPath($CandidatePath)).TrimEnd([char[]]@('\', '/'))
    return $candidate -eq $base -or $candidate.StartsWith($base + [System.IO.Path]::DirectorySeparatorChar, [System.StringComparison]::OrdinalIgnoreCase)
}

function Assert-SafeRelativePath {
    param(
        [Parameter(Mandatory = $true)][string]$RelativePath,
        [Parameter(Mandatory = $true)][string]$FieldName
    )

    if ([string]::IsNullOrWhiteSpace($RelativePath) -or [System.IO.Path]::IsPathRooted($RelativePath) -or $RelativePath -match '^[A-Za-z]:') {
        throw "$FieldName must be a non-empty relative path."
    }

    $normalized = $RelativePath.Replace('\', '/')
    if (($normalized -split '/') -contains '..') {
        throw "$FieldName must not contain a parent-directory segment."
    }
}

function Resolve-ContainedPath {
    param(
        [Parameter(Mandatory = $true)][string]$BasePath,
        [Parameter(Mandatory = $true)][string]$RelativePath,
        [Parameter(Mandatory = $true)][string]$FieldName,
        [ValidateSet('Any', 'File', 'Directory')][string]$Kind = 'Any'
    )

    Assert-SafeRelativePath -RelativePath $RelativePath -FieldName $FieldName
    $resolvedBase = (Resolve-Path -LiteralPath $BasePath -ErrorAction Stop).Path
    $candidate = [System.IO.Path]::GetFullPath((Join-Path $resolvedBase ($RelativePath -replace '/', [System.IO.Path]::DirectorySeparatorChar)))
    if (-not (Test-PathInside -BasePath $resolvedBase -CandidatePath $candidate)) {
        throw "$FieldName resolves outside the run directory."
    }

    $exists = switch ($Kind) {
        'File' { Test-Path -LiteralPath $candidate -PathType Leaf }
        'Directory' { Test-Path -LiteralPath $candidate -PathType Container }
        default { Test-Path -LiteralPath $candidate }
    }
    if (-not $exists) {
        throw "$FieldName '$RelativePath' does not exist under '$resolvedBase'."
    }

    $resolvedCandidate = (Resolve-Path -LiteralPath $candidate -ErrorAction Stop).Path
    if (-not (Test-PathInside -BasePath $resolvedBase -CandidatePath $resolvedCandidate)) {
        throw "$FieldName resolves through a link outside the run directory."
    }
    return $resolvedCandidate
}

function Get-PlatformName {
    if ($IsWindows) { return 'windows' }
    if ($IsMacOS) { return 'macos' }
    if ($IsLinux) { return 'linux' }
    return 'unknown'
}

function Resolve-RunContract {
    param([Parameter(Mandatory = $true)][string]$RunPath)

    $resolvedRunPath = (Resolve-Path -LiteralPath $RunPath -ErrorAction Stop).Path
    $runRoot = Split-Path -Parent $resolvedRunPath
    $run = Read-RunnerJson -Path $resolvedRunPath
    $schemas = Get-RunnerSchemaNames

    if ([string]$run.schema -ne $schemas.Run) {
        throw "run.json must declare '$($schemas.Run)'."
    }
    if (-not [bool]$run.freshContextRequired -or -not [bool]$run.filesystemIsolationRequired -or -not [bool]$run.isolatedHomeRequired) {
        throw 'run.json must require fresh context, filesystem isolation, and isolated home.'
    }

    $mode = [string]$run.mode
    if ($mode -notin @('with_skill', 'without_skill')) {
        throw "run.json mode '$mode' is not with_skill or without_skill."
    }

    $promptPath = Resolve-ContainedPath -BasePath $runRoot -RelativePath ([string]$run.promptFile) -FieldName 'promptFile' -Kind File
    $workingPath = Resolve-ContainedPath -BasePath $runRoot -RelativePath ([string]$run.workingDirectory) -FieldName 'workingDirectory' -Kind Directory
    $homePath = Resolve-ContainedPath -BasePath $runRoot -RelativePath ([string]$run.homeDirectory) -FieldName 'homeDirectory' -Kind Directory

    $skillPath = $null
    if ($mode -eq 'with_skill') {
        if ([string]::IsNullOrWhiteSpace([string]$run.skillDirectory)) {
            throw 'with_skill run.json must declare skillDirectory.'
        }
        $skillPath = Resolve-ContainedPath -BasePath $runRoot -RelativePath ([string]$run.skillDirectory) -FieldName 'skillDirectory' -Kind Directory
        if (-not (Test-Path -LiteralPath (Join-Path $skillPath 'SKILL.md') -PathType Leaf)) {
            throw 'with_skill skillDirectory must contain SKILL.md.'
        }
    } else {
        if ($null -ne $run.skillDirectory -and -not [string]::IsNullOrWhiteSpace([string]$run.skillDirectory)) {
            throw 'without_skill run.json must not declare skillDirectory.'
        }
        $skillRoot = Join-Path $runRoot 'skill'
        if (Test-Path -LiteralPath $skillRoot) {
            throw 'without_skill run must not contain a skill directory.'
        }
    }

    $promptBytes = [System.IO.File]::ReadAllBytes($promptPath)
    $fixtureHash = [string](Get-JsonProperty -Object $run -Name 'fixtureHash' -Default '')
    if (-not (Test-Sha256 -Value $fixtureHash)) {
        throw 'run.json fixtureHash must be a SHA-256 value.'
    }
    if ($mode -eq 'with_skill' -and -not (Test-Sha256 -Value ([string]$run.skillHash))) {
        throw 'with_skill run.json skillHash must be a SHA-256 value.'
    }

    return [pscustomobject]@{
        RunPath = $resolvedRunPath
        RunRoot = $runRoot
        Contract = $run
        EvalId = [int]$run.evalId
        EvalName = [string]$run.evalName
        Mode = $mode
        PromptPath = $promptPath
        PromptBytes = $promptBytes
        PromptHash = Get-Sha256HexFromBytes -Bytes $promptBytes
        WorkingDirectoryPath = $workingPath
        HomeDirectoryPath = $homePath
        SkillDirectoryPath = $skillPath
        CandidateSkillExposed = $mode -eq 'with_skill'
        FixtureHash = $fixtureHash
        SkillHash = if ($mode -eq 'with_skill') { [string]$run.skillHash } else { $null }
    }
}

function Assert-ProfileHasNoSecrets {
    param([Parameter(Mandatory = $true)][object]$Profile)

    foreach ($property in @($Profile.PSObject.Properties)) {
        if ([string]$property.Name -match '(?i)(secret|token|password|credential|api[_-]?key|private[_-]?key)') {
            throw "execution-profile.json must not contain secret-bearing field '$($property.Name)'."
        }
    }
}

function Resolve-ExecutionProfile {
    param([Parameter(Mandatory = $true)][string]$ProfilePath)

    $resolvedProfilePath = (Resolve-Path -LiteralPath $ProfilePath -ErrorAction Stop).Path
    $profile = Read-RunnerJson -Path $resolvedProfilePath
    $schemas = Get-RunnerSchemaNames
    if ([string]$profile.schema -ne $schemas.Profile) {
        throw "execution-profile.json must declare '$($schemas.Profile)'."
    }
    Assert-ProfileHasNoSecrets -Profile $profile

    $allowedProperties = @('schema', 'runner', 'provider', 'model', 'reasoning_effort', 'configuration_profile', 'tool_profile', 'timeout_seconds', 'concurrency')
    foreach ($propertyName in @(Get-JsonPropertyNames -Object $profile)) {
        if ($allowedProperties -notcontains $propertyName) {
            throw "execution-profile.json contains unsupported field '$propertyName'."
        }
    }

    $timeout = [int](Get-JsonProperty -Object $profile -Name 'timeout_seconds' -Default 0)
    $concurrency = [int](Get-JsonProperty -Object $profile -Name 'concurrency' -Default 0)
    if ($timeout -lt 1 -or $timeout -gt 86400) {
        throw 'execution-profile.json timeout_seconds must be between 1 and 86400.'
    }
    if ($concurrency -lt 1) {
        throw 'execution-profile.json concurrency must be at least 1.'
    }
    if ([string]::IsNullOrWhiteSpace([string]$profile.configuration_profile) -or [string]::IsNullOrWhiteSpace([string]$profile.tool_profile)) {
        throw 'execution-profile.json must declare configuration_profile and tool_profile.'
    }

    $runnerValue = [string](Get-JsonProperty -Object $profile -Name 'runner' -Default '')
    $providerValue = [string](Get-JsonProperty -Object $profile -Name 'provider' -Default '')
    $modelValue = [string](Get-JsonProperty -Object $profile -Name 'model' -Default '')
    if (-not [string]::IsNullOrWhiteSpace($runnerValue) -and $runnerValue -notmatch '^[a-z0-9][a-z0-9-]*$') {
        throw 'execution-profile.json runner must be a safe lowercase runner name.'
    }
    return [pscustomobject]@{
        Path = $resolvedProfilePath
        Profile = $profile
        Hash = Get-Sha256HexFromFile -Path $resolvedProfilePath
        Runner = if ([string]::IsNullOrWhiteSpace($runnerValue)) { $null } else { $runnerValue }
        Provider = if ([string]::IsNullOrWhiteSpace($providerValue)) { $null } else { $providerValue }
        Model = if ([string]::IsNullOrWhiteSpace($modelValue)) { $null } else { $modelValue }
        ReasoningEffort = if ([string]::IsNullOrWhiteSpace([string]$profile.reasoning_effort)) { $null } else { [string]$profile.reasoning_effort }
        ConfigurationProfile = [string]$profile.configuration_profile
        ToolProfile = [string]$profile.tool_profile
        TimeoutSeconds = $timeout
        Concurrency = $concurrency
    }
}

function Assert-RunnerDescriptor {
    param([Parameter(Mandatory = $true)][object]$Descriptor)

    $schemas = Get-RunnerSchemaNames
    if ([string]$Descriptor.schema -ne $schemas.Descriptor) {
        throw "Runner descriptor must declare '$($schemas.Descriptor)'."
    }
    if ([string]$Descriptor.protocol_version -ne $schemas.Protocol) {
        throw "Runner descriptor protocol_version must be '$($schemas.Protocol)'."
    }
    foreach ($field in @('name', 'version', 'platforms', 'harness', 'capabilities', 'configuration_profiles', 'tool_profiles')) {
        if (-not (Test-JsonProperty -Object $Descriptor -Name $field)) {
            throw "Runner descriptor is missing '$field'."
        }
    }
    if ([string]::IsNullOrWhiteSpace([string]$Descriptor.name) -or [string]::IsNullOrWhiteSpace([string]$Descriptor.version)) {
        throw 'Runner descriptor name and version must be non-empty.'
    }
    if (-not (Test-JsonProperty -Object $Descriptor.harness -Name 'name') -or -not (Test-JsonProperty -Object $Descriptor.harness -Name 'version')) {
        throw 'Runner descriptor harness must declare name and version.'
    }

    foreach ($capabilityName in @(Get-JsonPropertyNames -Object $Descriptor.capabilities)) {
        $capabilityValue = Get-JsonProperty -Object $Descriptor.capabilities -Name $capabilityName
        if ([string]$capabilityValue -notin @('supported', 'conditional', 'unsupported')) {
            throw "Runner capability '$capabilityName' must be supported, conditional, or unsupported."
        }
    }

    $required = @(
        'fresh_context',
        'isolated_home_config',
        'isolated_working_directory',
        'filesystem_confinement',
        'ambient_candidate_skill_exclusion',
        'candidate_skill_exposure',
        'prompt_fidelity',
        'model_configuration_lock',
        'response_capture'
    )
    foreach ($name in $required) {
        if (-not (Test-JsonProperty -Object $Descriptor.capabilities -Name $name)) {
            throw "Runner descriptor is missing required capability '$name'."
        }
    }

    return $true
}

function New-PreflightCheck {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][ValidateSet('passed', 'failed', 'unavailable', 'not_applicable')][string]$Status,
        [Parameter(Mandatory = $true)][string]$Detail
    )

    return [ordered]@{ name = $Name; status = $Status; detail = $Detail }
}

function New-PreflightDocument {
    param(
        [Parameter(Mandatory = $true)][object]$Descriptor,
        [Parameter(Mandatory = $true)][object]$Profile,
        [Parameter(Mandatory = $true)][object]$Run,
        [Parameter(Mandatory = $true)][bool]$Compatible,
        [object[]]$Checks = @(),
        [string[]]$Mechanisms = @(),
        [object]$ResolvedCapabilities = $null,
        [string[]]$Warnings = @(),
        [string[]]$Reasons = @()
    )

    $schemas = Get-RunnerSchemaNames
    return [ordered]@{
        schema = $schemas.Preflight
        protocol_version = $schemas.Protocol
        status = if ($Compatible) { 'compatible' } else { 'incompatible' }
        runner = [ordered]@{ name = [string]$Descriptor.name; version = [string]$Descriptor.version }
        harness = $Descriptor.harness
        run = [ordered]@{ eval_id = $Run.EvalId; eval_name = $Run.EvalName; configuration = $Run.Mode }
        requested = [ordered]@{
            provider = $Profile.Provider
            model = $Profile.Model
            reasoning_effort = $Profile.ReasoningEffort
            configuration_profile = $Profile.ConfigurationProfile
            tool_profile = $Profile.ToolProfile
            timeout_seconds = $Profile.TimeoutSeconds
        }
        checks = @($Checks)
        resolved_capabilities = if ($null -eq $ResolvedCapabilities) { [ordered]@{} } else { $ResolvedCapabilities }
        mechanisms = @($Mechanisms)
        warnings = @($Warnings)
        reasons = @($Reasons)
    }
}

function New-UnavailableMetric {
    param([Parameter(Mandatory = $true)][string]$Reason)

    return [ordered]@{ status = 'unavailable'; reason = $Reason }
}

function New-AvailableMetric {
    param([Parameter(Mandatory = $true)][object]$Value)

    return [ordered]@{ status = 'available'; value = $Value }
}

function New-ExecutionFailure {
    param(
        [Parameter(Mandatory = $true)][string]$Code,
        [Parameter(Mandatory = $true)][string]$Message
    )

    return [ordered]@{ code = $Code; message = $Message }
}

function New-ExecutionResult {
    param(
        [Parameter(Mandatory = $true)][object]$Descriptor,
        [Parameter(Mandatory = $true)][object]$Profile,
        [Parameter(Mandatory = $true)][object]$Run,
        [Parameter(Mandatory = $true)][ValidateSet('completed', 'failed', 'timed_out', 'cancelled', 'incompatible')][string]$Status,
        [string]$FinalResponse,
        [string]$FinalResponseReason,
        [string]$StartedUtc,
        [string]$FinishedUtc,
        [double]$DurationSeconds = 0,
        [Nullable[int]]$ExitStatus,
        [object]$Failure,
        [string]$SessionId,
        [hashtable]$IsolationCapabilities,
        [string[]]$IsolationMechanisms = @(),
        [object]$Telemetry = $null,
        [object[]]$Artifacts = @(),
        [string[]]$Warnings = @(),
        [string[]]$CompatibilityDeviations = @(),
        [object]$Evidence = $null,
        [int]$AttemptCount = 1
    )

    $schemas = Get-RunnerSchemaNames
    $hasResponse = -not [string]::IsNullOrWhiteSpace($FinalResponse)
    $started = if ([string]::IsNullOrWhiteSpace($StartedUtc)) { [DateTime]::UtcNow } else { [DateTime]::Parse($StartedUtc).ToUniversalTime() }
    $finished = if ([string]::IsNullOrWhiteSpace($FinishedUtc)) { [DateTime]::UtcNow } else { [DateTime]::Parse($FinishedUtc).ToUniversalTime() }
    $isolation = [ordered]@{
        status = if ($Status -eq 'completed' -or $Status -eq 'failed' -or $Status -eq 'timed_out' -or $Status -eq 'cancelled') { 'verified' } else { 'unverified' }
        capabilities = if ($null -eq $IsolationCapabilities) { [ordered]@{} } else { $IsolationCapabilities }
        mechanisms = @($IsolationMechanisms)
    }

    return [ordered]@{
        schema = $schemas.Result
        protocol_version = $schemas.Protocol
        run_id = [Guid]::NewGuid().ToString('D')
        session = [ordered]@{
            id = if ([string]::IsNullOrWhiteSpace($SessionId)) { [Guid]::NewGuid().ToString('D') } else { $SessionId }
            fresh = $true
            resumed = $false
        }
        status = $Status
        run = [ordered]@{
            eval_id = $Run.EvalId
            eval_name = $Run.EvalName
            configuration = $Run.Mode
        }
        final_response = if ($hasResponse) {
            [ordered]@{ status = 'available'; text = $FinalResponse }
        } else {
            [ordered]@{ status = 'unavailable'; reason = if ([string]::IsNullOrWhiteSpace($FinalResponseReason)) { 'harness_did_not_return_a_final_response' } else { $FinalResponseReason } }
        }
        runner = [ordered]@{ name = [string]$Descriptor.name; version = [string]$Descriptor.version }
        harness = $Descriptor.harness
        requested = [ordered]@{
            provider = $Profile.Provider
            model = $Profile.Model
            reasoning_effort = $Profile.ReasoningEffort
            configuration_profile = $Profile.ConfigurationProfile
            tool_profile = $Profile.ToolProfile
        }
        resolved = [ordered]@{
            provider = $Profile.Provider
            model = $Profile.Model
            reasoning_effort = $Profile.ReasoningEffort
            configuration_profile = $Profile.ConfigurationProfile
            tool_profile = $Profile.ToolProfile
        }
        started_utc = $started.ToString('yyyy-MM-ddTHH:mm:ss.fffZ')
        finished_utc = $finished.ToString('yyyy-MM-ddTHH:mm:ss.fffZ')
        duration_seconds = [Math]::Max(0, [Math]::Round($DurationSeconds, 3))
        exit = [ordered]@{ status = $ExitStatus; failure = $Failure }
        input = [ordered]@{
            prompt_sha256 = $Run.PromptHash
            run_json_sha256 = Get-Sha256HexFromFile -Path $Run.RunPath
            profile_sha256 = $Profile.Hash
        }
        isolation = $isolation
        telemetry = if ($null -eq $Telemetry) {
            [ordered]@{
                transcript = New-UnavailableMetric -Reason 'harness_did_not_expose_transcript'
                tokens = New-UnavailableMetric -Reason 'harness_did_not_expose_usage'
                tool_calls = New-UnavailableMetric -Reason 'harness_did_not_expose_tool_calls'
                cost = New-UnavailableMetric -Reason 'harness_did_not_expose_cost'
            }
        } else { $Telemetry }
        evidence = if ($null -eq $Evidence) { [ordered]@{} } else { $Evidence }
        artifacts = @($Artifacts)
        warnings = @($Warnings)
        compatibility_deviations = @($CompatibilityDeviations)
        attempt_count = $AttemptCount
    }
}

function Assert-ExecutionResult {
    param([Parameter(Mandatory = $true)][object]$Result)

    $schemas = Get-RunnerSchemaNames
    if ([string]$Result.schema -ne $schemas.Result) {
        throw "execution-result.json must declare '$($schemas.Result)'."
    }
    if ([string]$Result.protocol_version -ne $schemas.Protocol) {
        throw "execution-result.json protocol_version must be '$($schemas.Protocol)'."
    }
    if ([string]$Result.status -notin @('completed', 'failed', 'timed_out', 'cancelled', 'incompatible')) {
        throw "execution-result.json status '$($Result.status)' is unsupported."
    }
    foreach ($field in @('run_id', 'runner', 'harness', 'requested', 'resolved', 'started_utc', 'finished_utc', 'duration_seconds', 'exit', 'final_response', 'input', 'isolation', 'telemetry', 'evidence', 'artifacts', 'warnings')) {
        if (-not (Test-JsonProperty -Object $Result -Name $field)) {
            throw "execution-result.json is missing '$field'."
        }
    }
    if ([string]::IsNullOrWhiteSpace([string]$Result.run_id)) {
        throw 'execution-result.json run_id must be non-empty.'
    }
    if (-not (Test-JsonProperty -Object $Result.session -Name 'id') -or
        -not [bool](Get-JsonProperty -Object $Result.session -Name 'fresh' -Default $false) -or
        [bool](Get-JsonProperty -Object $Result.session -Name 'resumed' -Default $true)) {
        throw 'execution-result.json must identify a fresh, non-resumed session.'
    }
    if ([int](Get-JsonProperty -Object $Result -Name 'attempt_count' -Default 0) -ne 1) {
        throw 'execution-result.json attempt_count must be exactly 1; quality retries are not allowed.'
    }
    foreach ($hashField in @('prompt_sha256', 'run_json_sha256', 'profile_sha256')) {
        if (-not (Test-Sha256 -Value ([string]$Result.input.$hashField))) {
            throw "execution-result.json input.$hashField must be a SHA-256 value."
        }
    }
    if ([double]$Result.duration_seconds -lt 0) {
        throw 'execution-result.json duration_seconds must not be negative.'
    }
    $responseStatus = [string]$Result.final_response.status
    if ($responseStatus -eq 'available') {
        if (-not (Test-JsonProperty -Object $Result.final_response -Name 'text')) {
            throw 'Available final_response must contain text.'
        }
    } elseif ($responseStatus -eq 'unavailable') {
        if ([string]::IsNullOrWhiteSpace([string]$Result.final_response.reason)) {
            throw 'Unavailable final_response must contain a reason.'
        }
    } else {
        throw "final_response status '$responseStatus' is unsupported."
    }

    foreach ($metricName in @(Get-JsonPropertyNames -Object $Result.telemetry)) {
        $metric = Get-JsonProperty -Object $Result.telemetry -Name $metricName
        $status = [string](Get-JsonProperty -Object $metric -Name 'status' -Default '')
        if ($status -notin @('available', 'unavailable')) {
            throw "Telemetry '$metricName' must declare available or unavailable status."
        }
        if ($status -eq 'unavailable' -and [string]::IsNullOrWhiteSpace([string](Get-JsonProperty -Object $metric -Name 'reason' -Default ''))) {
            throw "Unavailable telemetry '$metricName' must declare a reason."
        }
    }

    foreach ($artifact in @($Result.artifacts)) {
        $path = [string](Get-JsonProperty -Object $artifact -Name 'path' -Default '')
        $scope = [string](Get-JsonProperty -Object $artifact -Name 'scope' -Default '')
        Assert-SafeRelativePath -RelativePath $path -FieldName 'artifact.path'
        if ($scope -notin @('run', 'package')) {
            throw "artifact.scope '$scope' must be run or package."
        }
        if (-not (Test-Sha256 -Value ([string]$artifact.sha256))) {
            throw 'artifact.sha256 must be a SHA-256 value.'
        }
        if ([int64]$artifact.size -lt 0 -or [string]::IsNullOrWhiteSpace([string]$artifact.media_type)) {
            throw 'artifact must declare non-negative size and media_type.'
        }
    }

    return $true
}

function New-RunnerEnvironment {
    param(
        [Parameter(Mandatory = $true)][object]$Run,
        [string[]]$AuthenticationVariables = @(),
        [hashtable]$Additional = @{}
    )

    $environment = [ordered]@{}
    foreach ($name in @('PATH', 'SystemRoot', 'WINDIR', 'ComSpec', 'PATHEXT', 'LANG', 'LC_ALL', 'TZ', 'SSL_CERT_FILE', 'NODE_PATH')) {
        $value = [Environment]::GetEnvironmentVariable($name)
        if (-not [string]::IsNullOrWhiteSpace($value)) {
            $environment[$name] = $value
        }
    }

    $tempPath = Join-Path $Run.HomeDirectoryPath 'tmp'
    foreach ($directory in @($Run.HomeDirectoryPath, $tempPath, (Join-Path $Run.HomeDirectoryPath '.config'), (Join-Path $Run.HomeDirectoryPath '.local/share'), (Join-Path $Run.HomeDirectoryPath '.cache'))) {
        New-Item -ItemType Directory -Path $directory -Force | Out-Null
    }

    $environment['HOME'] = $Run.HomeDirectoryPath
    $environment['USERPROFILE'] = $Run.HomeDirectoryPath
    $environment['XDG_CONFIG_HOME'] = Join-Path $Run.HomeDirectoryPath '.config'
    $environment['XDG_DATA_HOME'] = Join-Path $Run.HomeDirectoryPath '.local/share'
    $environment['XDG_CACHE_HOME'] = Join-Path $Run.HomeDirectoryPath '.cache'
    $environment['TEMP'] = $tempPath
    $environment['TMP'] = $tempPath
    $environment['CI'] = '1'
    $environment['NO_COLOR'] = '1'

    foreach ($name in $AuthenticationVariables | Sort-Object -Unique) {
        $value = [Environment]::GetEnvironmentVariable($name)
        if (-not [string]::IsNullOrWhiteSpace($value)) {
            $environment[$name] = $value
        }
    }
    foreach ($key in $Additional.Keys) {
        $environment[$key] = [string]$Additional[$key]
    }

    return $environment
}

function Resolve-ExternalCommand {
    param([Parameter(Mandatory = $true)][string]$Name)

    $command = Get-Command $Name -ErrorAction SilentlyContinue
    if ($null -eq $command) {
        return $null
    }

    $source = [string]$command.Source
    $extension = [System.IO.Path]::GetExtension($source).ToLowerInvariant()
    if ($extension -eq '.ps1') {
        $pwsh = Get-Command pwsh -ErrorAction SilentlyContinue
        if ($null -eq $pwsh) {
            return $null
        }
        return [pscustomobject]@{ FileName = [string]$pwsh.Source; Prefix = @('-NoProfile', '-File', $source); Source = $source }
    }

    return [pscustomobject]@{ FileName = $source; Prefix = @(); Source = $source }
}

function Invoke-RunnerProcess {
    param(
        [Parameter(Mandatory = $true)][string]$FileName,
        [string[]]$ArgumentList = @(),
        [Parameter(Mandatory = $true)][string]$WorkingDirectory,
        [System.Collections.IDictionary]$Environment = @{},
        [byte[]]$InputBytes = @(),
        [int]$TimeoutSeconds = 900
    )

    $start = [DateTime]::UtcNow
    $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = $FileName
    $startInfo.WorkingDirectory = $WorkingDirectory
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardInput = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    foreach ($argument in @($ArgumentList)) {
        [void]$startInfo.ArgumentList.Add([string]$argument)
    }
    $startInfo.Environment.Clear()
    foreach ($key in $Environment.Keys) {
        $startInfo.Environment[$key] = [string]$Environment[$key]
    }

    $process = [System.Diagnostics.Process]::new()
    $process.StartInfo = $startInfo
    try {
        if (-not $process.Start()) {
            throw "Could not start '$FileName'."
        }

        if ($null -ne $InputBytes -and $InputBytes.Length -gt 0) {
            $process.StandardInput.BaseStream.Write($InputBytes, 0, $InputBytes.Length)
        }
        $process.StandardInput.Close()
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()
        $timeoutMilliseconds = [Math]::Min([int64]::MaxValue, [int64]$TimeoutSeconds * 1000)
        $exited = $process.WaitForExit([int]([Math]::Min($timeoutMilliseconds, [int]::MaxValue)))
        $timedOut = -not $exited
        if ($timedOut) {
            try { $process.Kill($true) } catch { }
            $process.WaitForExit()
        }
        $stdout = $stdoutTask.GetAwaiter().GetResult()
        $stderr = $stderrTask.GetAwaiter().GetResult()
        $finish = [DateTime]::UtcNow

        return [pscustomobject]@{
            ExitCode = if ($timedOut) { $null } else { $process.ExitCode }
            TimedOut = $timedOut
            Stdout = $stdout
            Stderr = $stderr
            StartedUtc = $start
            FinishedUtc = $finish
            DurationSeconds = [Math]::Round(($finish - $start).TotalSeconds, 3)
        }
    } finally {
        $process.Dispose()
    }
}

function Get-ProviderAuthenticationVariables {
    param([string]$Provider)

    $normalized = ([string]$Provider).ToLowerInvariant()
    switch -Regex ($normalized) {
        '^openai$|^chatgpt$' { return @('OPENAI_API_KEY') }
        '^anthropic$' { return @('ANTHROPIC_API_KEY') }
        '^google$|^google-vertex$|^gemini$' { return @('GOOGLE_API_KEY', 'GEMINI_API_KEY') }
        '^openrouter$' { return @('OPENROUTER_API_KEY') }
        '^xai$|^x-ai$' { return @('XAI_API_KEY') }
        '^mistral$' { return @('MISTRAL_API_KEY') }
        default { return @() }
    }
}

function Test-EnvironmentVariablePresent {
    param([string[]]$Names)

    foreach ($name in @($Names)) {
        if (-not [string]::IsNullOrWhiteSpace([Environment]::GetEnvironmentVariable($name))) {
            return $true
        }
    }
    return $false
}

function New-ArtifactReference {
    param(
        [Parameter(Mandatory = $true)][object]$Run,
        [Parameter(Mandatory = $true)][string]$Path,
        [ValidateSet('run', 'package')][string]$Scope = 'run',
        [string]$MediaType = 'application/octet-stream'
    )

    Assert-SafeRelativePath -RelativePath $Path -FieldName 'artifact.path'
    $base = if ($Scope -eq 'run') { $Run.RunRoot } else { Split-Path -Parent (Split-Path -Parent $Run.RunRoot) }
    $full = Resolve-ContainedPath -BasePath $base -RelativePath $Path -FieldName 'artifact.path' -Kind File
    return [ordered]@{
        path = $Path.Replace('\', '/')
        scope = $Scope
        sha256 = Get-Sha256HexFromFile -Path $full
        size = (Get-Item -LiteralPath $full).Length
        media_type = $MediaType
    }
}

function Get-MediaType {
    param([string]$Path)

    switch ([System.IO.Path]::GetExtension($Path).ToLowerInvariant()) {
        '.jsonl' { return 'application/x-ndjson' }
        '.json' { return 'application/json' }
        '.txt' { return 'text/plain; charset=utf-8' }
        '.md' { return 'text/markdown; charset=utf-8' }
        default { return 'application/octet-stream' }
    }
}

function ConvertFrom-JsonLines {
    param([Parameter(Mandatory = $true)][string]$Text)

    $events = [System.Collections.Generic.List[object]]::new()
    $errors = [System.Collections.Generic.List[string]]::new()
    $lineNumber = 0
    foreach ($line in ($Text -split "`r?`n")) {
        $lineNumber++
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        try {
            $events.Add(($line | ConvertFrom-Json))
        } catch {
            $errors.Add("line ${lineNumber}: $($_.Exception.Message)")
        }
    }
    return [pscustomobject]@{ Events = @($events); Errors = @($errors) }
}

function Get-OutputTextFromFinalResponse {
    param([object]$Result)

    if ([string](Get-JsonProperty -Object $Result.final_response -Name 'status' -Default '') -eq 'available') {
        return [string]$Result.final_response.text
    }
    return $null
}
