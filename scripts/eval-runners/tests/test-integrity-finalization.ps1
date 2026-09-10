<#!
.SYNOPSIS
    Deterministic frozen-evidence, grading-isolation, and finalization tests.

.DESCRIPTION
    Builds a package around the repository's model-free runner fixture. The
    fixture produces six native terminal results, including one scripted
    interaction case. This suite deliberately simulates the latest Copilot
    failure by writing grading into a raw execution result after Phase 1 and
    verifies that no later bridge or finalizer can bless or repair it.
#>
[CmdletBinding()]
param(
    [ValidateSet('All', 'Bridge', 'Grading', 'Application', 'Finalization')]
    [string]$Suite = 'All'
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$runnerRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$repositoryRoot = (Resolve-Path (Join-Path $runnerRoot '..')).Path
. (Join-Path $runnerRoot 'runner-common.ps1')
. (Join-Path $runnerRoot 'manifest-paths.ps1')
. (Join-Path $runnerRoot 'orchestration.ps1')
. (Join-Path $runnerRoot 'execution-freeze.ps1')
. (Join-Path $runnerRoot 'phase2-grading.ps1')
. (Join-Path $runnerRoot 'package-integrity.ps1')
. (Join-Path $runnerRoot 'fanout-process.ps1')
$invokePhase2AnalyzerPath = Join-Path $runnerRoot 'invoke-phase2-analyzer.ps1'
$invokePhase2Tokens = $null
$invokePhase2Errors = $null
$invokePhase2Ast = [Management.Automation.Language.Parser]::ParseFile($invokePhase2AnalyzerPath, [ref]$invokePhase2Tokens, [ref]$invokePhase2Errors)
if ($invokePhase2Errors.Count -gt 0) { throw "Cannot parse invoke-phase2-analyzer.ps1: $invokePhase2Errors" }
foreach ($definition in $invokePhase2Ast.EndBlock.Statements) {
    if ($definition -is [Management.Automation.Language.FunctionDefinitionAst]) {
        Invoke-Expression $definition.Extent.Text
    }
}

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw "ASSERT: $Message" }
}

function Assert-Equal {
    param([object]$Expected, [object]$Actual, [string]$Message)
    if ([string]$Expected -cne [string]$Actual) {
        throw "ASSERT: $Message (expected '$Expected', got '$Actual')"
    }
}

function Assert-Contains {
    param([string]$Text, [string]$Expected, [string]$Message)
    if ($Text.IndexOf($Expected, [System.StringComparison]::OrdinalIgnoreCase) -lt 0) {
        throw "ASSERT: $Message (missing '$Expected')"
    }
}

function Write-TestJson {
    param([Parameter(Mandatory = $true)][string]$Path, [Parameter(Mandatory = $true)][object]$Value)

    Write-RunnerJsonFile -Path $Path -Value $Value
}

function Read-TestJson {
    param([Parameter(Mandatory = $true)][string]$Path)
    return [System.IO.File]::ReadAllText($Path, [System.Text.UTF8Encoding]::new($false)) | ConvertFrom-Json -Depth 100
}

function Remove-TestProperty {
    param(
        [Parameter(Mandatory = $true)][object]$Object,
        [Parameter(Mandatory = $true)][string]$Name
    )

    if ($Object -is [System.Collections.IDictionary]) {
        [void]$Object.Remove($Name)
    } else {
        [void]$Object.PSObject.Properties.Remove($Name)
    }
}

function Invoke-TestTool {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string[]]$Arguments
    )

    $output = & pwsh -NoProfile -NonInteractive -File $Path @Arguments 2>&1
    $exitCode = $LASTEXITCODE
    return [pscustomobject]@{
        ExitCode = $exitCode
        Text = [string]::Join([Environment]::NewLine, @($output | ForEach-Object { [string]$_ }))
    }
}

function Invoke-ForegroundPhaseOne {
    param([Parameter(Mandatory = $true)][string]$Path, [Parameter(Mandatory = $true)][string]$IterationDirectory)

    # STDOUT is the machine protocol; STDERR is live observability. Capture them
    # separately so relayed heartbeats never contaminate the terminal JSON.
    $stderrPath = Join-Path ([System.IO.Path]::GetTempPath()) ('phase1-stderr-' + [Guid]::NewGuid().ToString('N') + '.log')
    try {
        $output = & pwsh -NoProfile -NonInteractive -File $Path -IterationDirectory $IterationDirectory 2>$stderrPath
        $exitCode = $LASTEXITCODE
        $text = [string]::Join([Environment]::NewLine, @($output | ForEach-Object { [string]$_ }))
        $stderr = if (Test-Path -LiteralPath $stderrPath -PathType Leaf) { [System.IO.File]::ReadAllText($stderrPath, [System.Text.UTF8Encoding]::new($false)) } else { '' }
    } finally {
        Remove-Item -LiteralPath $stderrPath -Force -ErrorAction SilentlyContinue
    }
    $document = $text | ConvertFrom-Json -Depth 100
    return [pscustomobject]@{ ExitCode = $exitCode; Text = $text; Stderr = $stderr; Document = $document }
}

function Assert-ToolPasses {
    param([Parameter(Mandatory = $true)][object]$Invocation, [Parameter(Mandatory = $true)][string]$Description)
    if ([int]$Invocation.ExitCode -ne 0) { throw "ASSERT: $Description failed: $($Invocation.Text)" }
}

function Assert-ToolFails {
    param(
        [Parameter(Mandatory = $true)][object]$Invocation,
        [Parameter(Mandatory = $true)][string]$Description,
        [string]$ExpectedText = ''
    )
    if ([int]$Invocation.ExitCode -eq 0) { throw "ASSERT: $Description unexpectedly passed: $($Invocation.Text)" }
    if (-not [string]::IsNullOrWhiteSpace($ExpectedText)) { Assert-Contains -Text $Invocation.Text -Expected $ExpectedText -Message $Description }
}

function New-TestRun {
    param(
        [Parameter(Mandatory = $true)][string]$IterationDirectory,
        [Parameter(Mandatory = $true)][int]$EvalId,
        [Parameter(Mandatory = $true)][string]$EvalName,
        [Parameter(Mandatory = $true)][string]$Configuration,
        [object]$Interaction = $null
    )

    $evalDirectory = Join-Path $IterationDirectory $EvalName
    $runDirectory = Join-Path $evalDirectory $Configuration
    $repoDirectory = Join-Path $runDirectory 'repo'
    $homeDirectory = Join-Path $runDirectory 'home'
    New-Item -ItemType Directory -Path $repoDirectory, $homeDirectory -Force | Out-Null
    [System.IO.File]::WriteAllText((Join-Path $homeDirectory 'execute-delay-ms'), '0', [System.Text.UTF8Encoding]::new($false))
    [System.IO.File]::WriteAllText((Join-Path $runDirectory 'prompt.md'), "deterministic fixture prompt for $EvalName/$Configuration`n", [System.Text.UTF8Encoding]::new($false))

    $skillDirectory = $null
    if ($Configuration -eq 'with_skill') {
        $skillDirectory = Join-Path $runDirectory 'skill/test-skill'
        New-Item -ItemType Directory -Path $skillDirectory -Force | Out-Null
        [System.IO.File]::WriteAllText((Join-Path $skillDirectory 'SKILL.md'), '# deterministic fixture skill`n', [System.Text.UTF8Encoding]::new($false))
    }

    $interactionFile = $null
    $interactionHash = $null
    if ($null -ne $Interaction) {
        $interactionFile = Join-Path $runDirectory 'interaction.json'
        Write-TestJson -Path $interactionFile -Value $Interaction
        $interactionHash = Get-Sha256HexFromFile -Path $interactionFile
    }

    $candidateInstructionHash = $null
    if ($Configuration -eq 'with_skill') {
        $promptContent = "deterministic fixture prompt for $EvalName/$Configuration`n"
        $candidateInstructionHash = ([Convert]::ToHexString([System.Security.Cryptography.SHA256]::HashData([System.Text.Encoding]::UTF8.GetBytes($promptContent)))).ToLowerInvariant()
    }

    $run = [ordered]@{
        schema = (Get-RunnerSchemaNames).Run
        evalId = $EvalId
        evalName = $EvalName
        candidateSkillName = 'test-skill'
        skillName = if ($Configuration -eq 'with_skill') { 'test-skill' } else { $null }
        iteration = 1
        mode = $Configuration
        promptFile = 'prompt.md'
        workingDirectory = 'repo'
        homeDirectory = 'home'
        skillDirectory = if ($Configuration -eq 'with_skill') { 'skill/test-skill' } else { $null }
        freshContextRequired = $true
        filesystemIsolationRequired = $true
        isolatedHomeRequired = $true
        gitWorkspace = $false
        inputFiles = @()
        fixtureHash = ('a' * 64)
        skillHash = if ($Configuration -eq 'with_skill') { ('b' * 64) } else { $null }
        candidateInstructionHash = $candidateInstructionHash
        contract = [ordered]@{
            sandboxRoot = '.'
            workingDirectory = 'repo'
            homeDirectory = 'home'
            mustNotReadOutsideSandbox = $true
            mustNotExposeGlobalSkillsOrConfig = $true
        }
    }
    if ($null -ne $interactionFile) {
        $run.interactionFile = 'interaction.json'
        $run.interactionHash = $interactionHash
    }
    Write-TestJson -Path (Join-Path $runDirectory 'run.json') -Value $run

    if ($EvalId -eq 2) {
        [System.IO.File]::WriteAllText((Join-Path $homeDirectory 'extra-transcript-artifacts'), "1`n", [System.Text.UTF8Encoding]::new($false))
    }

    return [pscustomobject]@{
        Directory = $runDirectory
        RunPath = Join-Path $runDirectory 'run.json'
        InteractionPath = $interactionFile
    }
}

function Get-GradingEntry {
    param(
        [Parameter(Mandatory = $true)][object]$Document,
        [Parameter(Mandatory = $true)][int]$EvalId,
        [Parameter(Mandatory = $true)][string]$Configuration,
        [Parameter(Mandatory = $true)][int]$AssertionIndex
    )

    return @($Document.grading | Where-Object {
            [int]$_.eval_id -eq $EvalId -and
            [string]$_.configuration -eq $Configuration -and
            [int]$_.assertion_index -eq $AssertionIndex
        } | Select-Object -First 1)[0]
}

function New-TestTranscriptEvidenceRef {
    param(
        [Parameter(Mandatory = $true)][object]$Record,
        [Parameter(Mandatory = $true)][object]$Canonical,
        [ValidateSet('Events', 'Lines')][string]$Kind = 'Events',
        [string]$Artifact = ''
    )

    $transcripts = @(Get-CanonicalTranscriptArtifacts -Record $Record -Canonical $Canonical)
    if ([string]::IsNullOrWhiteSpace($Artifact)) {
        $entry = if ($Kind -eq 'Events') {
            @($transcripts | Where-Object { Test-JsonProperty -Object $_ -Name 'events' } | Select-Object -First 1)
        } else {
            @($transcripts | Where-Object { Test-JsonProperty -Object $_ -Name 'lines' } | Select-Object -First 1)
        }
    } else {
        $entry = @($transcripts | Where-Object { [string]$_.artifact -eq $Artifact } | Select-Object -First 1)
    }
    if ($entry.Count -ne 1 -and [string]::IsNullOrWhiteSpace($Artifact) -and $Kind -eq 'Events') {
        $entry = @((Get-TranscriptArtifactSnapshot -Record $Record -Artifact ("$([string]$Record.Configuration)/evidence/fixture-events.jsonl")).Entry)
    }
    if ($entry.Count -ne 1) {
        throw "Missing $Kind transcript artifact '$Artifact' for deterministic grading coverage."
    }
    if ($Kind -eq 'Events') {
        if (-not (Test-JsonProperty -Object $entry[0] -Name 'events')) {
            throw "Transcript artifact '$([string]$entry[0].artifact)' does not expose events."
        }
        $event = @(Get-JsonProperty -Object $entry[0] -Name 'events' -Default @() | Select-Object -First 1)
        if ($event.Count -ne 1) {
            throw "Transcript artifact '$([string]$entry[0].artifact)' has no event content."
        }
        return [ordered]@{
            artifact = [string](Get-JsonProperty -Object $entry[0] -Name 'artifact' -Default '')
            domain = 'transcript'
            event_index = [int](Get-JsonProperty -Object $event[0] -Name 'event_index' -Default 0)
            quote = [string](Get-JsonProperty -Object $event[0] -Name 'source_text' -Default (Get-JsonProperty -Object $event[0] -Name 'content' -Default ''))
        }
    }

    if (-not (Test-JsonProperty -Object $entry[0] -Name 'lines')) {
        throw "Transcript artifact '$([string]$entry[0].artifact)' does not expose line content."
    }
    $lines = @(Get-JsonProperty -Object $entry[0] -Name 'lines' -Default @() | Select-Object -First 2)
    if ($lines.Count -lt 1) {
        throw "Transcript artifact '$([string]$entry[0].artifact)' has no line content."
    }
    return [ordered]@{
        artifact = [string](Get-JsonProperty -Object $entry[0] -Name 'artifact' -Default '')
        domain = 'transcript'
        start_line = [int](Get-JsonProperty -Object $lines[0] -Name 'line' -Default 1)
        end_line = [int](Get-JsonProperty -Object $lines[$lines.Count - 1] -Name 'line' -Default 1)
        quote = [string]::Join("`n", @($lines | ForEach-Object { [string](Get-JsonProperty -Object $_ -Name 'text' -Default '') }))
    }
}

function New-TestGradingDocument {
    param([Parameter(Mandatory = $true)][object[]]$Records)

    $entries = [System.Collections.Generic.List[object]]::new()
    foreach ($record in @($Records | Sort-Object EvalId, Configuration)) {
        $metadata = Read-TestJson -Path $record.MetadataPath
        $assertions = @($metadata.assertions)
        $canonical = Read-TestJson -Path $record.ResultPath
        for ($index = 0; $index -lt $assertions.Count; $index++) {
            $assertionText = if ($assertions[$index] -is [string]) { [string]$assertions[$index] } elseif ($assertions[$index].PSObject.Properties.Name -contains 'assertion') { [string]$assertions[$index].assertion } else { [string]$assertions[$index] }
            $domain = if ($assertions[$index] -isnot [string] -and $assertions[$index].PSObject.Properties.Name -contains 'evidence_domain') { [string]$assertions[$index].evidence_domain } else { 'output' }
            $validator = if ($assertions[$index] -isnot [string] -and $assertions[$index].PSObject.Properties.Name -contains 'validator') { [string]$assertions[$index].validator } else { $null }
            $output = [string]$canonical.output
            $refs = if ($domain -eq 'validator') {
                @([ordered]@{
                    artifact = [string]$record.ResultRelative
                    domain = 'validator'
                    rule = $validator
                    version = 1
                    passed = $true
                    event = 'deterministic fixture validator evidence'
                })
            } elseif ($domain -eq 'transcript') {
                @((New-TestTranscriptEvidenceRef -Record $record -Canonical $canonical -Kind Events))
            } else {
                @([ordered]@{
                    artifact = [string]$record.ResultRelative
                    domain = 'output'
                    start_line = 1
                    end_line = 1
                    quote = $output
                })
            }
            $entries.Add([ordered]@{
                eval_id = [int]$record.EvalId
                eval_name = [string]$record.EvalName
                configuration = [string]$record.Configuration
                assertion_index = $index
                assertion = $assertionText
                passed = $true
                evidence_domain = $domain
                evidence_refs = @($refs)
                reason = "The captured fixture response establishes assertion $index for this deterministic transport case."
                evidence = "The captured fixture response establishes assertion $index for this deterministic transport case."
                source = 'analyzer'
            })
        }
    }
    return [ordered]@{ schema = (Get-RunnerSchemaNames).Grading; grading = @($entries.ToArray()) }
}

function Remove-TestReportArtifacts {
    param([Parameter(Mandatory = $true)][string]$IterationDirectory)
    foreach ($relative in @('report.html', 'skill-creator-report.html', 'benchmark.json', 'benchmark.md')) {
        $path = Join-Path $IterationDirectory $relative
        if (Test-Path -LiteralPath $path -PathType Leaf) { Remove-Item -LiteralPath $path -Force }
    }
}

function New-ProblematicProtocolString {
    return [string]::Concat('prefix:', [char]0x1A, [char]0x00, [char]0x09, [char]0x0D, [char]0x0A, [char]0x22, [char]0x5C, ':suffix')
}

function Assert-ProblematicProtocolString {
    param([Parameter(Mandatory = $true)][string]$Value)

    foreach ($codePoint in @(0x1A, 0x00, 0x09, 0x0D, 0x0A, 0x22, 0x5C)) {
        Assert-True ($Value.IndexOf([char]$codePoint) -ge 0) ("problematic protocol string contains literal 0x{0:X2}" -f $codePoint)
    }
}

function Get-StrictJsonString {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string[]]$PropertyPath
    )

    $json = [System.IO.File]::ReadAllText($Path, [System.Text.UTF8Encoding]::new($false))
    $document = [System.Text.Json.JsonDocument]::Parse($json)
    try {
        $element = $document.RootElement
        foreach ($segment in $PropertyPath) {
            if ($element.ValueKind -eq [System.Text.Json.JsonValueKind]::Array) {
                $element = $element[[int]$segment]
            } else {
                $element = $element.GetProperty($segment)
            }
        }
        return $element.GetString()
    } finally {
        $document.Dispose()
    }
}

function Assert-StrictJsonRoundTrip {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string[]]$PropertyPath,
        [Parameter(Mandatory = $true)][string]$Expected,
        [Parameter(Mandatory = $true)][string]$Message
    )

    $actual = Get-StrictJsonString -Path $Path -PropertyPath $PropertyPath
    if ($Expected -cne $actual) {
        throw "ASSERT: $Message did not round-trip through strict JSON parsing"
    }
}

function Assert-ProtocolJsonSerializationRoundTrip {
    param([Parameter(Mandatory = $true)][string]$Root)

    $problematic = New-ProblematicProtocolString
    Assert-ProblematicProtocolString -Value $problematic
    $jsonPath = Join-Path $Root 'strict-json\protocol-owned-artifact.json'
    Write-RunnerJsonFile -Path $jsonPath -Value ([ordered]@{
        schema = 'codebeltnet/agentic/eval-protocol-json-roundtrip-test/1'
        payload = [ordered]@{
            text = $problematic
            diagnostics = @([ordered]@{ message = $problematic })
        }
    })
    Assert-StrictJsonRoundTrip -Path $jsonPath -PropertyPath @('payload', 'text') -Expected $problematic -Message 'protocol-owned JSON string with control characters'
    Assert-StrictJsonRoundTrip -Path $jsonPath -PropertyPath @('payload', 'diagnostics', '0', 'message') -Expected $problematic -Message 'nested protocol-owned JSON diagnostic string with control characters'
}

function Assert-ExecutionResultSerializationRoundTrip {
    param([Parameter(Mandatory = $true)][string]$Root)

    $problematic = New-ProblematicProtocolString
    Assert-ProblematicProtocolString -Value $problematic
    $executionRoot = Join-Path $Root 'strict-json\execution-result-path'
    New-Item -ItemType Directory -Path $executionRoot -Force | Out-Null
    $runJson = Join-Path $executionRoot 'run.json'
    $promptPath = Join-Path $executionRoot 'prompt.md'
    $childScript = Join-Path $executionRoot 'write-execution-result.ps1'
    $executionResultPath = Join-Path $executionRoot 'model-output.execution-result.json'
    $stderrPath = Join-Path $executionRoot 'model-output.stderr.txt'
    [System.IO.File]::WriteAllText($runJson, '{}', [System.Text.UTF8Encoding]::new($false))
    [System.IO.File]::WriteAllText($promptPath, 'strict JSON production path prompt', [System.Text.UTF8Encoding]::new($false))
    $childScriptText = @'
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$CommonPath,
    [Parameter(Mandatory = $true)][string]$RunRoot,
    [Parameter(Mandatory = $true)][string]$RunPath,
    [Parameter(Mandatory = $true)][string]$PromptHash
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
. $CommonPath
$problematic = [string]::Concat('prefix:', [char]0x1A, [char]0x00, [char]0x09, [char]0x0D, [char]0x0A, [char]0x22, [char]0x5C, ':suffix')
$hash = '0000000000000000000000000000000000000000000000000000000000000000'
$descriptor = [ordered]@{ name = 'strict-json-fixture'; version = '1'; harness = [ordered]@{ name = 'strict-json-fixture'; version = '1' } }
$profile = [pscustomobject]@{ Model = 'fixture-model'; ReasoningEffort = ''; ConfigurationProfile = 'isolated-default'; ToolProfile = 'default'; TimeoutSeconds = 1; Hash = $hash }
$run = [pscustomobject]@{ EvalId = 1; EvalName = 'strict-json'; Mode = 'with_skill'; PromptHash = $PromptHash; RunPath = $RunPath; RunRoot = $RunRoot; CandidateSkillExposed = $false }
$result = New-ExecutionResult -Descriptor $descriptor -Profile $profile -Run $run -Status completed -FinalResponse $problematic -StartedUtc ([DateTime]::UtcNow.ToString('o')) -FinishedUtc ([DateTime]::UtcNow.ToString('o')) -DurationSeconds 0 -ExitStatus 0 -Failure $null -SessionId 'strict-json-session' -IsolationCapabilities ([ordered]@{ fresh_context = 'supported'; isolated_home_config = 'supported'; isolated_working_directory = 'supported'; ambient_candidate_skill_exclusion = 'supported'; candidate_skill_exposure = 'excluded'; prompt_fidelity = 'supported'; model_configuration_lock = 'supported'; response_capture = 'supported'; filesystem_confinement = 'unsupported' }) -IsolationMechanisms @('strict-json-production-path') -Warnings @($problematic) -Evidence ([ordered]@{ diagnostic = $problematic }) -AttemptCount 1
Write-RunnerJson -Value $result -AsOutput
'@
    [System.IO.File]::WriteAllText($childScript, $childScriptText, [System.Text.UTF8Encoding]::new($false))
    $pwshPath = [string]((Get-Command pwsh -CommandType Application -ErrorAction Stop | Select-Object -First 1).Source)
    $child = Start-RunnerChildProcess -FilePath $pwshPath -ArgumentList @('-NoProfile', '-NonInteractive', '-File', $childScript, '-CommonPath', (Join-Path $runnerRoot 'runner-common.ps1'), '-RunRoot', $executionRoot, '-RunPath', $runJson, '-PromptHash', (Get-Sha256HexFromFile -Path $promptPath)) -WorkingDirectory $executionRoot -StdoutPath $executionResultPath -StderrPath $stderrPath -TimeoutSeconds 30
    $exitCode = Complete-RunnerChildProcess -Child $child
    Assert-Equal 0 $exitCode 'execution-result child writer exits successfully'
    Assert-StrictJsonRoundTrip -Path $executionResultPath -PropertyPath @('final_response', 'text') -Expected $problematic -Message 'execution-result final response with control characters'
    Assert-StrictJsonRoundTrip -Path $executionResultPath -PropertyPath @('warnings', '0') -Expected $problematic -Message 'execution-result warning with control characters'
    Assert-StrictJsonRoundTrip -Path $executionResultPath -PropertyPath @('evidence', 'diagnostic') -Expected $problematic -Message 'execution-result evidence with control characters'
}

function Get-TestFileHashSnapshot {
    param([Parameter(Mandatory = $true)][string[]]$Paths)

    $snapshot = @{}
    foreach ($path in @($Paths | Sort-Object -Unique)) {
        $snapshot[$path] = if (Test-Path -LiteralPath $path -PathType Leaf) { Get-Sha256HexFromFile -Path $path } else { '<missing>' }
    }
    return $snapshot
}

function Assert-TestFileHashSnapshot {
    param(
        [Parameter(Mandatory = $true)][hashtable]$Expected,
        [Parameter(Mandatory = $true)][string]$Message
    )

    foreach ($path in @($Expected.Keys)) {
        $actual = if (Test-Path -LiteralPath $path -PathType Leaf) { Get-Sha256HexFromFile -Path $path } else { '<missing>' }
        Assert-Equal $Expected[$path] $actual "$Message preserves $path"
    }
}

function Get-GradingValidationSideEffectPaths {
    param(
        [Parameter(Mandatory = $true)][string]$IterationDirectory,
        [Parameter(Mandatory = $true)][object[]]$Records
    )

    $paths = [System.Collections.Generic.List[string]]::new()
    foreach ($record in $Records) {
        $paths.Add([string]$record.ExecutionResultPath)
        $paths.Add([string]$record.ResultPath)
    }
    foreach ($relative in @('orchestration-state.json', 'execution-freeze.json', 'report.html', 'skill-creator-report.html', 'benchmark.json', 'benchmark.md')) {
        $paths.Add((Join-Path $IterationDirectory $relative))
    }
    return @($paths.ToArray())
}

function Copy-TestGradingDocument {
    param([Parameter(Mandatory = $true)][object]$Document)

    return ConvertTo-RunnerJson -Value $Document -Depth 100 | ConvertFrom-Json -Depth 100
}

function New-AnalyzerSemanticFixture {
    param([Parameter(Mandatory = $true)][string]$Root)

    $fixtureRoot = Join-Path $Root 'phase2-analyzer-direct'
    $resultsDirectory = Join-Path $fixtureRoot 'results'
    New-Item -ItemType Directory -Path $resultsDirectory -Force | Out-Null
    $canonicalPath = Join-Path $resultsDirectory 'with-skill.result.json'
    $metadataPath = Join-Path $fixtureRoot 'eval-metadata.json'
    $canonical = [ordered]@{
        output = "alpha line`nbeta line"
        output_files = @('with_skill/evidence/opencode-events.jsonl', 'with_skill/evidence/opencode-stderr.txt')
    }
    Write-TestJson -Path $canonicalPath -Value $canonical
    Write-TestJson -Path $metadataPath -Value ([ordered]@{
            expected_output = 'alpha line'
            assertions = @(
                [ordered]@{ assertion = 'alpha line is present'; evidence_domain = 'output' }
                [ordered]@{ assertion = 'beta line is present'; evidence_domain = 'output' }
            )
        })
    $record = [pscustomobject]@{
        EvalDirectory = $fixtureRoot
        ResultPath = $canonicalPath
        MetadataPath = $metadataPath
        ResultRelative = 'with_skill.result.json'
    }
    $assertions = @(
        [ordered]@{ eval_id = 1; eval_name = 'phase2-direct'; configuration = 'with_skill'; assertion_index = 0; assertion = 'alpha line is present'; evidence_domain = 'output'; validator = $null; record = $record }
        [ordered]@{ eval_id = 1; eval_name = 'phase2-direct'; configuration = 'with_skill'; assertion_index = 1; assertion = 'beta line is present'; evidence_domain = 'output'; validator = $null; record = $record }
    )
    return [pscustomobject]@{
        Root = $fixtureRoot
        Canonical = Read-RunnerJson -Path $canonicalPath
        Record = $record
        Worker = [pscustomobject]@{
            worker_id = 'arm-1-with_skill'
            eval_id = 1
            eval_name = 'phase2-direct'
            configuration = 'with_skill'
            record = $record
            assertions = $assertions
        }
        AnalyzerProfile = [pscustomobject]@{
            Hash = ('f' * 64)
            Runner = 'fixture'
            Model = 'fixture-model'
            ReasoningEffort = $null
        }
    }
}

function Assert-AnalyzerResponseAccepted {
    param(
        [Parameter(Mandatory = $true)][string]$Text,
        [Parameter(Mandatory = $true)][string]$ExpectedNormalization,
        [Parameter(Mandatory = $true)][object]$Fixture,
        [Parameter(Mandatory = $true)][string]$Description
    )

    $response = ConvertFrom-AnalyzerResponse -Text $Text
    Assert-Equal $ExpectedNormalization ([string]$response.TransportNormalization) "$Description normalization"
    $grades = @(Confirm-AnalyzerFragment -Fragment $response.Fragment -Worker $Fixture.Worker -Canonical $Fixture.Canonical)
    Assert-Equal 2 $grades.Count "$Description semantic grading entry count"
}

function Assert-ActionRejected {
    param(
        [Parameter(Mandatory = $true)][scriptblock]$Action,
        [Parameter(Mandatory = $true)][string]$Pattern,
        [Parameter(Mandatory = $true)][string]$Description
    )

    $failed = $false
    try {
        & $Action | Out-Null
    } catch {
        $failed = $true
        Assert-True ($_.Exception.Message -match $Pattern) "$Description unexpected failure: $($_.Exception.Message)"
    }
    Assert-True $failed "$Description unexpectedly passed"
}

$testRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('agentic-integrity-finalization-' + [Guid]::NewGuid().ToString('N'))
$oldReportMode = [Environment]::GetEnvironmentVariable('AGENTIC_TEST_REPORT_MODE')
try {
    Assert-ProtocolJsonSerializationRoundTrip -Root $testRoot
    Assert-ExecutionResultSerializationRoundTrip -Root $testRoot

    $iteration = Join-Path $testRoot 'iteration-1'
    $packageTools = Join-Path $iteration 'tools/eval-runners'
    New-Item -ItemType Directory -Path $packageTools -Force | Out-Null

    # The package receives the same runner tree a prepared package would carry;
    # the selected fixture is deterministic and never calls a model.
    foreach ($item in @(Get-ChildItem -LiteralPath $runnerRoot -Force)) {
        Copy-Item -LiteralPath $item.FullName -Destination $packageTools -Recurse -Force
    }
    $fixtureDirectory = Join-Path $packageTools 'fixture'
    New-Item -ItemType Directory -Path $fixtureDirectory -Force | Out-Null
    Copy-Item -LiteralPath (Join-Path $runnerRoot 'tests/fixtures/runner-owned-fixture.ps1') -Destination (Join-Path $fixtureDirectory 'runner.ps1') -Force
    $graderContractDirectory = Join-Path $iteration 'tools/skill-creator/agents'
    New-Item -ItemType Directory -Path $graderContractDirectory -Force | Out-Null
    [System.IO.File]::WriteAllText((Join-Path $graderContractDirectory 'grader.md'), "# Deterministic grader contract`nGrade against frozen evidence only.`n", [System.Text.UTF8Encoding]::new($false))

    $reportScript = Join-Path $iteration 'tools/test-report.ps1'
    $reportScriptText = @'
[CmdletBinding()]
param([Parameter(Mandatory = $true)][string]$IterationDirectory, [switch]$RequireComplete)
$ErrorActionPreference = 'Stop'
$mode = [Environment]::GetEnvironmentVariable('AGENTIC_TEST_REPORT_MODE')
if ($mode -eq 'failure') { throw 'deterministic report fixture failure' }
$files = @('report.html', 'skill-creator-report.html', 'benchmark.json', 'benchmark.md')
$count = if ($mode -eq 'missing') { 3 } else { 4 }
for ($index = 0; $index -lt $count; $index++) {
    $path = Join-Path $IterationDirectory $files[$index]
    $content = if ($files[$index] -eq 'benchmark.json') { '{"schema":"deterministic-report-fixture/1","status":"completed"}' } else { "deterministic report fixture: $($files[$index])`n" }
    [System.IO.File]::WriteAllText($path, $content, [System.Text.UTF8Encoding]::new($false))
}
'@
    [System.IO.File]::WriteAllText($reportScript, $reportScriptText, [System.Text.UTF8Encoding]::new($false))

    $interaction = [ordered]@{
        schema = (Get-RunnerSchemaNames).Interaction
        mode = 'scripted'
        turns = @(
            [ordered]@{ role = 'user'; source = 'prompt.md' }
            [ordered]@{ role = 'user'; content = 'Yes, proceed.' }
        )
    }

    $manifestEvals = [System.Collections.Generic.List[object]]::new()
    for ($evalId = 1; $evalId -le 3; $evalId++) {
        $evalName = if ($evalId -eq 2) { 'dotnet-strong-name-signing-confirmation' } else { 'integrity-eval-{0:d2}' -f $evalId }
        $evalDirectory = Join-Path $iteration $evalName
        New-Item -ItemType Directory -Path $evalDirectory -Force | Out-Null
        $assertions = if ($evalId -eq 2) {
            @(
                [ordered]@{
                    assertion = 'the protected operation is absent before confirmation and occurs only after the same-session confirmation turn'
                    evidence_domain = 'transcript'
                }
                'the response contains the fixture completion content'
            )
        } elseif ($evalId -eq 3) {
            @(
                [ordered]@{ assertion = 'current Git branch was resolved'; evidence_domain = 'validator'; validator = 'git.current_branch_observed' }
                [ordered]@{ assertion = 'base/default branch was resolved using local Git state'; evidence_domain = 'validator'; validator = 'git.default_branch_resolved' }
                [ordered]@{ assertion = 'branch-only commits were collected'; evidence_domain = 'validator'; validator = 'git.branch_commits_collected' }
                [ordered]@{ assertion = 'three-dot net diff was collected'; evidence_domain = 'validator'; validator = 'git.three_dot_diff_observed' }
                [ordered]@{ assertion = 'no candidate package search was performed'; evidence_domain = 'validator'; validator = 'skill.no_candidate_package_search' }
                [ordered]@{ assertion = 'no candidate install attempt was performed'; evidence_domain = 'validator'; validator = 'skill.no_candidate_install_attempt' }
                [ordered]@{ assertion = 'no unnecessary project package or tool mutation was performed'; evidence_domain = 'validator'; validator = 'workspace.no_unnecessary_mutation' }
            )
        } else {
            @('the deterministic terminal response is captured', 'the response contains the fixture completion content')
        }
        Write-TestJson -Path (Join-Path $evalDirectory 'eval-metadata.json') -Value ([ordered]@{
            schema = 'codebeltnet/agentic/eval-metadata/1'
            eval_id = $evalId
            eval_name = $evalName
            prompt = "fixture prompt $evalId"
            expected_output = 'fixture output'
            assertions = @($assertions)
        })
        $runs = [ordered]@{}
        foreach ($configuration in @('with_skill', 'without_skill')) {
            $interactionForRun = if ($evalId -eq 2) { $interaction } else { $null }
            $run = New-TestRun -IterationDirectory $iteration -EvalId $evalId -EvalName $evalName -Configuration $configuration -Interaction $interactionForRun
            $resultName = "$configuration.result.json"
            $executionName = "$configuration.execution-result.json"
            $stubGrading = @($assertions | ForEach-Object {
                [ordered]@{
                    text = if ($_ -is [string]) { [string]$_ } elseif ($_.PSObject.Properties.Name -contains 'assertion') { [string]$_.assertion } else { [string]$_ }
                    passed = $null
                    evidence = ''
                    evidence_domain = if ($_ -isnot [string] -and $_.PSObject.Properties.Name -contains 'evidence_domain') { [string]$_.evidence_domain } else { 'output' }
                    evidence_refs = @()
                    reason = ''
                }
            })
            Write-TestJson -Path (Join-Path $evalDirectory "results/$resultName") -Value ([ordered]@{
                schema = (Get-RunnerSchemaNames).PortableResult
                eval_id = $evalId
                eval_name = $evalName
                configuration = $configuration
                execution_status = 'unrun'
                grading = @($stubGrading)
            })
            $runs[$configuration] = [ordered]@{
                mode = $configuration
                run_manifest = "$evalName/$configuration/run.json"
                execution_result = "$evalName/results/$executionName"
                result = "$evalName/results/$resultName"
            }
        }
        $manifestEvals.Add([ordered]@{
            eval_id = $evalId
            eval_name = $evalName
            directory = $evalName
            metadata = "$evalName/eval-metadata.json"
            runs = $runs
        })
    }

    $toolIntegrity = Get-PackageTreeIntegrity -Root $packageTools
    $manifest = [ordered]@{
        schema = 'codebeltnet/agentic/eval-package/2'
        configurations = @('with_skill', 'without_skill')
        execution_selection = [ordered]@{ harness = 'Deterministic runner-owned fixture'; runner = 'fixture'; model = 'fixture-model'; preset = 'Integrity fixture' }
        execution_profile = 'execution-profile.json'
        runner_tools = 'tools/eval-runners'
        runner_tools_integrity = [ordered]@{ schema = 'codebeltnet/agentic/package-tree-integrity/1'; path = 'tools/eval-runners'; sha256 = $toolIntegrity.Sha256; file_count = $toolIntegrity.FileCount }
        execution_freeze = 'execution-freeze.json'
        grading = 'grading.json'
        report = [ordered]@{ tool = 'tools/test-report.ps1' }
        evals = @($manifestEvals.ToArray())
    }
    $profile = [ordered]@{
        schema = (Get-RunnerSchemaNames).Profile
        runner = 'fixture'
        model = 'fixture-model'
        reasoning_effort = $null
        configuration_profile = 'isolated-default'
        tool_profile = 'default'
        timeout_seconds = 60
        concurrency = 3
    }
    $analyzerProfile = [ordered]@{
        schema = (Get-RunnerSchemaNames).AnalyzerProfile
        contract_version = (Get-RunnerSchemaNames).Grading
        runner = 'fixture'
        harness = 'deterministic runner-owned fixture'
        model = 'fixture-model'
        reasoning_effort = $null
        selection_source = 'explicit'
    }
    Write-TestJson -Path (Join-Path $iteration 'manifest.json') -Value $manifest
    Write-TestJson -Path (Join-Path $iteration 'execution-profile.json') -Value $profile
    Write-TestJson -Path (Join-Path $iteration 'analyzer-profile.json') -Value $analyzerProfile
    $manifest.analyzer_profile = 'analyzer-profile.json'
    $manifest.analyzer_profile_sha256 = Get-Sha256HexFromFile -Path (Join-Path $iteration 'analyzer-profile.json')
    $manifest.analyzer_selection = [ordered]@{
        runner = 'fixture'
        harness = 'deterministic runner-owned fixture'
        model = 'fixture-model'
        reasoning_effort = $null
        selection_source = 'explicit'
        contract_version = (Get-RunnerSchemaNames).Grading
        analyzer_profile_sha256 = [string]$manifest.analyzer_profile_sha256
    }
    $manifest.phase2_controller = 'tools/eval-runners/invoke-phase2-analyzer.ps1'
    $manifest.phase2_state = 'phase2-state.json'
    $manifest.grading_freeze = 'grading-freeze.json'
    Write-TestJson -Path (Join-Path $iteration 'manifest.json') -Value $manifest

    $fanoutScript = Join-Path $packageTools 'invoke-runner-owned-arms.ps1'
    $fanout = Invoke-ForegroundPhaseOne -Path $fanoutScript -IterationDirectory $iteration
    Assert-ToolPasses -Invocation $fanout -Description 'runner-owned fixture Phase 1'
    $fanoutSummary = $fanout.Document
    Assert-Equal 'completed' $fanoutSummary.status 'six deterministic fixture arms complete'
    Assert-Equal 6 $fanoutSummary.execution_count 'six raw execution results are registered'
    Assert-True (Test-Path -LiteralPath (Join-Path $iteration 'execution-freeze.json') -PathType Leaf) 'Phase 1 writes an execution freeze'

    $freeze = Assert-ExecutionFreeze -IterationDirectory $iteration -RequireOrchestrationState
    Assert-Equal 6 @($freeze.Freeze.executions).Count 'execution freeze contains all six arms'
    Assert-Equal 'arm-1-with_skill' $freeze.Freeze.executions[0].worker_id 'freeze ordering is deterministic'
    Assert-Equal 'arm-3-without_skill' $freeze.Freeze.executions[5].worker_id 'freeze ordering includes the final arm'
    Assert-True (Test-Sha256 -Value ([string]$freeze.Freeze.orchestration_state_sha256)) 'freeze anchors the terminal orchestration ledger'

    $records = @(Get-ManifestRunRecords -IterationDirectory $iteration -Manifest (Read-TestJson -Path (Join-Path $iteration 'manifest.json')) | Sort-Object EvalId, Configuration)
    $rawBeforeSecondPhase = @{}
    foreach ($record in $records) { $rawBeforeSecondPhase[$record.ExecutionResultPath] = Get-Sha256HexFromFile -Path $record.ExecutionResultPath }
    $secondPhaseOne = Invoke-TestTool -Path (Join-Path $packageTools 'fixture/runner.ps1') -Arguments @('execute', '-Run', $records[0].RunManifestPath, '-Profile', (Join-Path $iteration 'execution-profile.json'))
    Assert-ToolFails -Invocation $secondPhaseOne -Description 'runner refuses execution after the raw-evidence freeze' -ExpectedText 'already frozen'
    foreach ($record in $records) { Assert-Equal $rawBeforeSecondPhase[$record.ExecutionResultPath] (Get-Sha256HexFromFile -Path $record.ExecutionResultPath) 'post-freeze runner refusal leaves raw evidence unchanged' }
    foreach ($record in $records) {
        $raw = Read-TestJson -Path $record.ExecutionResultPath
        [void](Assert-ExecutionResult -Result $raw)
        if ($record.EvalId -eq 2) {
            [void](Assert-InteractionResultEvidence -ExecutionResult $raw -RunData (Resolve-RunContract -RunPath $record.RunManifestPath))
            $turns = @($raw.evidence.interaction.turns)
            Assert-Equal 4 $turns.Count 'strong-name confirmation fixture preserves two user/assistant pairs'
            Assert-Equal ([string]$turns[0].session_id) ([string]$turns[3].session_id) 'scripted fixture preserves one session identity'
            $eventPath = Join-Path (Split-Path -Parent $record.RunManifestPath) 'evidence/fixture-events.jsonl'
            $events = @(Get-Content -LiteralPath $eventPath | ForEach-Object { $_ | ConvertFrom-Json })
            Assert-Equal 5 $events.Count 'strong-name confirmation fixture records the protected operation event'
            Assert-Equal 'user.dispatched' $events[0].type 'first scripted event is the user dispatch'
            Assert-Equal 'assistant.terminal' $events[1].type 'second scripted event is the first assistant terminal response'
            Assert-Equal 'user.dispatched' $events[2].type 'follow-up dispatch waits for first terminal response'
            Assert-Equal 'protected.operation' $events[3].type 'protected operation occurs after the confirmation dispatch'
            Assert-Equal 'assistant.terminal' $events[4].type 'final scripted event is the second assistant terminal response'
            Assert-True ([int]$events[3].sequence -gt [int]$events[2].sequence) 'protected operation follows the confirmation user turn'
            Assert-True ((@($events | Where-Object { $_.type -eq 'protected.operation' -and [int]$_.sequence -le [int]$events[2].sequence }).Count) -eq 0) 'protected operation evidence cannot appear before confirmation'
        }
    }

    $bridgeScript = Join-Path $packageTools 'bridge-manifest-results.ps1'
    $bridgeArguments = @('-IterationDirectory', $iteration, '-RequireComplete', '-RequireParallelDispatch')
    Assert-ToolPasses -Invocation (Invoke-TestTool -Path $bridgeScript -Arguments $bridgeArguments) -Description 'initial frozen manifest bridge'
    $selectedRecord = $records[0]
    $selectedRawHash = Get-Sha256HexFromFile -Path $selectedRecord.ExecutionResultPath
    $finalizerScript = Join-Path $packageTools 'finalize-eval-package.ps1'
    $finalizerArguments = @('-IterationDirectory', $iteration, '-GradingPath', 'grading.json')
    $applyScript = Join-Path $packageTools 'apply-eval-grading.ps1'
    $applyArguments = @('-IterationDirectory', $iteration, '-GradingPath', 'grading.json')
    if ($Suite -in @('All', 'Bridge')) {
        Assert-ToolPasses -Invocation (Invoke-TestTool -Path $bridgeScript -Arguments $bridgeArguments) -Description 'unchanged idempotent manifest bridge'

        $statePath = Join-Path $iteration 'orchestration-state.json'
        $stateBytes = [System.IO.File]::ReadAllBytes($statePath)
        $tamperedState = Read-TestJson -Path $statePath
        $tamperedState.max_observed_active = 1
        Write-TestJson -Path $statePath -Value $tamperedState
        $tamperedStateBridge = Invoke-TestTool -Path $bridgeScript -Arguments $bridgeArguments
        Assert-ToolFails -Invocation $tamperedStateBridge -Description 'bridge rejects post-freeze orchestration-state mutation' -ExpectedText 'orchestration-state.json changed'
        [System.IO.File]::WriteAllBytes($statePath, $stateBytes)
        Assert-ToolPasses -Invocation (Invoke-TestTool -Path $bridgeScript -Arguments $bridgeArguments) -Description 'bridge passes after exact orchestration-state restoration'

        $selectedRawBytes = [System.IO.File]::ReadAllBytes($selectedRecord.ExecutionResultPath)
        $selectedRaw = Read-TestJson -Path $selectedRecord.ExecutionResultPath
        $selectedRaw | Add-Member -NotePropertyName grading -NotePropertyValue @([ordered]@{ passed = $true })
        Write-TestJson -Path $selectedRecord.ExecutionResultPath -Value $selectedRaw
        $corruptedBridge = Invoke-TestTool -Path $bridgeScript -Arguments $bridgeArguments
        Assert-ToolFails -Invocation $corruptedBridge -Description 'bridge rejects raw grading mutation' -ExpectedText 'Execution integrity failure'
        Assert-Contains -Text $corruptedBridge.Text -Expected 'requires fresh Phase 1 execution' -Message 'raw mutation requires fresh Phase 1 execution'
        $freezeAfterRawMutation = Read-TestJson -Path (Join-Path $iteration 'execution-freeze.json')
        Assert-Equal $selectedRawHash (Get-JsonProperty -Object $freezeAfterRawMutation.executions[0] -Name 'execution_result_sha256') 'freeze hash is not re-blessed after raw mutation'
        [System.IO.File]::WriteAllBytes($selectedRecord.ExecutionResultPath, $selectedRawBytes)
        Assert-Equal $selectedRawHash (Get-Sha256HexFromFile -Path $selectedRecord.ExecutionResultPath) 'exact raw bytes are restored'
        Assert-ToolPasses -Invocation (Invoke-TestTool -Path $bridgeScript -Arguments $bridgeArguments) -Description 'bridge passes after exact raw restoration'

        $artifactPath = Join-Path (Split-Path -Parent $selectedRecord.RunManifestPath) 'evidence/fixture-events.jsonl'
        $artifactBytes = [System.IO.File]::ReadAllBytes($artifactPath)
        [System.IO.File]::WriteAllBytes($artifactPath, $artifactBytes + [byte[]](0x20))
        $corruptedArtifactBridge = Invoke-TestTool -Path $bridgeScript -Arguments $bridgeArguments
        Assert-ToolFails -Invocation $corruptedArtifactBridge -Description 'bridge rejects referenced artifact mutation' -ExpectedText 'Execution integrity failure'
        [System.IO.File]::WriteAllBytes($artifactPath, $artifactBytes)
        Assert-ToolPasses -Invocation (Invoke-TestTool -Path $bridgeScript -Arguments $bridgeArguments) -Description 'bridge passes after exact artifact restoration'

    }
    $gradingPath = Join-Path $iteration 'grading.json'
    $validGrading = New-TestGradingDocument -Records $records
    $transcriptEvalId = 2
    $transcriptAssertionIndex = 0
    $transcriptRecord = @($records | Where-Object { $_.EvalId -eq $transcriptEvalId -and $_.Configuration -eq 'with_skill' } | Select-Object -First 1)[0]
    $transcriptCanonical = Read-TestJson -Path $transcriptRecord.ResultPath
    $transcriptArtifacts = @(Get-CanonicalTranscriptArtifacts -Record $transcriptRecord -Canonical $transcriptCanonical)
    $collisionEventArtifacts = @($transcriptArtifacts | Where-Object { [string]$_.artifact -like 'with_skill/evidence/*/events.jsonl' } | Sort-Object artifact)
    $lineTranscriptArtifact = @($transcriptArtifacts | Where-Object { [string]$_.artifact -eq 'with_skill/evidence/logs/transcript.txt' } | Select-Object -First 1)[0]
    Assert-Equal 2 $collisionEventArtifacts.Count 'fixture exposes two same-basename transcript artifacts'
    Assert-True ($null -ne $lineTranscriptArtifact) 'fixture exposes a line-based transcript artifact'
    $validationScript = Join-Path $packageTools 'validate-eval-grading.ps1'
    $validationArguments = @('-IterationDirectory', $iteration, '-GradingPath', 'grading.json')
    $validationSideEffectPaths = Get-GradingValidationSideEffectPaths -IterationDirectory $iteration -Records $records
    $validationSnapshot = Get-TestFileHashSnapshot -Paths $validationSideEffectPaths

    if ($Suite -in @('All', 'Grading')) {
        $directAnalyzerFixture = New-AnalyzerSemanticFixture -Root $testRoot
        $validAnalyzerFragment = [ordered]@{
            schema = 'codebeltnet/agentic/eval-analyzer-fragment/1'
            eval_id = 1
            configuration = 'with_skill'
            grading = @(
                [ordered]@{
                    assertion_index = 0
                    passed = $true
                    reason = 'alpha line is present in the frozen output.'
                    evidence_refs = @([ordered]@{
                            artifact = 'with_skill.result.json'
                            domain = 'output'
                            start_line = 1
                            end_line = 1
                            quote = 'alpha line'
                        })
                }
                [ordered]@{
                    assertion_index = 1
                    passed = $true
                    reason = 'beta line is present in the frozen output.'
                    evidence_refs = @([ordered]@{
                            artifact = 'with_skill.result.json'
                            domain = 'output'
                            start_line = 1
                            end_line = 1
                            quote = 'beta line'
                        })
                }
            )
        }
        $validAnalyzerJson = ConvertTo-RunnerJson -Value $validAnalyzerFragment -Depth 100
        $fencedAnalyzerJson = [string]::Join([Environment]::NewLine, @('```json', $validAnalyzerJson, '```'))
        $fencedAnalyzerJsonWithProse = [string]::Join([Environment]::NewLine, @('The grading fragment follows.', '```json', $validAnalyzerJson, '```'))
        $duplicateFencedAnalyzerJson = [string]::Join([Environment]::NewLine, @('```json', $validAnalyzerJson, '```', '', '```json', $validAnalyzerJson, '```'))
        Assert-AnalyzerResponseAccepted -Text $validAnalyzerJson -ExpectedNormalization 'raw_json' -Fixture $directAnalyzerFixture -Description 'raw analyzer JSON'
        Assert-AnalyzerResponseAccepted -Text $fencedAnalyzerJson -ExpectedNormalization 'fenced_json' -Fixture $directAnalyzerFixture -Description 'fenced analyzer JSON'
        Assert-AnalyzerResponseAccepted -Text $fencedAnalyzerJsonWithProse -ExpectedNormalization 'fenced_json_with_surrounding_text' -Fixture $directAnalyzerFixture -Description 'fenced analyzer JSON with prose'
        Assert-ActionRejected -Description 'empty analyzer response rejected' -Pattern 'empty response' -Action { ConvertFrom-AnalyzerResponse -Text '   ' | Out-Null }
        Assert-ActionRejected -Description 'malformed analyzer JSON rejected' -Pattern 'malformed JSON' -Action { ConvertFrom-AnalyzerResponse -Text '```json`n{"schema":`n```' | Out-Null }
        Assert-ActionRejected -Description 'multiple analyzer JSON candidates rejected' -Pattern 'multiple (fenced blocks|JSON candidates)' -Action { ConvertFrom-AnalyzerResponse -Text $duplicateFencedAnalyzerJson | Out-Null }
        $wrongSchemaFragment = Copy-TestGradingDocument -Document $validAnalyzerFragment
        $wrongSchemaFragment.schema = 'wrong/schema'
        Assert-ActionRejected -Description 'wrong analyzer fragment schema rejected' -Pattern 'unsupported schema' -Action {
            $response = ConvertFrom-AnalyzerResponse -Text (ConvertTo-RunnerJson -Value $wrongSchemaFragment -Depth 100)
            Confirm-AnalyzerFragment -Fragment $response.Fragment -Worker $directAnalyzerFixture.Worker -Canonical $directAnalyzerFixture.Canonical | Out-Null
        }
        $wrongEvalFragment = Copy-TestGradingDocument -Document $validAnalyzerFragment
        $wrongEvalFragment.eval_id = 2
        Assert-ActionRejected -Description 'wrong analyzer eval id rejected' -Pattern 'does not match the requested eval arm' -Action {
            $response = ConvertFrom-AnalyzerResponse -Text (ConvertTo-RunnerJson -Value $wrongEvalFragment -Depth 100)
            Confirm-AnalyzerFragment -Fragment $response.Fragment -Worker $directAnalyzerFixture.Worker -Canonical $directAnalyzerFixture.Canonical | Out-Null
        }
        $wrongConfigurationFragment = Copy-TestGradingDocument -Document $validAnalyzerFragment
        $wrongConfigurationFragment.configuration = 'without_skill'
        Assert-ActionRejected -Description 'wrong analyzer configuration rejected' -Pattern 'does not match the requested eval arm' -Action {
            $response = ConvertFrom-AnalyzerResponse -Text (ConvertTo-RunnerJson -Value $wrongConfigurationFragment -Depth 100)
            Confirm-AnalyzerFragment -Fragment $response.Fragment -Worker $directAnalyzerFixture.Worker -Canonical $directAnalyzerFixture.Canonical | Out-Null
        }
        $missingAssertionFragment = Copy-TestGradingDocument -Document $validAnalyzerFragment
        $missingAssertionFragment.grading = @($missingAssertionFragment.grading[0])
        Assert-ActionRejected -Description 'missing analyzer assertion index rejected' -Pattern 'grade cardinality' -Action {
            $response = ConvertFrom-AnalyzerResponse -Text (ConvertTo-RunnerJson -Value $missingAssertionFragment -Depth 100)
            Confirm-AnalyzerFragment -Fragment $response.Fragment -Worker $directAnalyzerFixture.Worker -Canonical $directAnalyzerFixture.Canonical | Out-Null
        }
        $duplicateAssertionFragment = Copy-TestGradingDocument -Document $validAnalyzerFragment
        $duplicateAssertionFragment.grading[1].assertion_index = 0
        Assert-ActionRejected -Description 'duplicate analyzer assertion index rejected' -Pattern 'duplicates assertion_index' -Action {
            $response = ConvertFrom-AnalyzerResponse -Text (ConvertTo-RunnerJson -Value $duplicateAssertionFragment -Depth 100)
            Confirm-AnalyzerFragment -Fragment $response.Fragment -Worker $directAnalyzerFixture.Worker -Canonical $directAnalyzerFixture.Canonical | Out-Null
        }
        $phase2BundleRoot = Join-Path $testRoot 'phase2-bundle-direct'
        New-Item -ItemType Directory -Path $phase2BundleRoot -Force | Out-Null
        $directBundle = New-AnalyzerRunBundle -Phase2Root $phase2BundleRoot -Worker $directAnalyzerFixture.Worker -AnalyzerProfile $directAnalyzerFixture.AnalyzerProfile -AnalyzerExecutionProfilePath (Join-Path $phase2BundleRoot 'analyzer-execution-profile.json') -GraderContractText '# deterministic grader'
        $directBundleDocument = Read-TestJson -Path $directBundle.BundlePath
        Assert-Equal 'with_skill.result.json,with_skill/evidence/opencode-events.jsonl,with_skill/evidence/opencode-stderr.txt' ([string]::Join(',', @($directBundleDocument.allowed_artifacts))) 'allowed_artifacts preserves individual array entries'
        $directBundleRun = Resolve-RunContract -RunPath $directBundle.RunPath
        Assert-Equal 'phase2_analyzer' ([string]$directBundleRun.ExecutionRole) 'Phase 2 analyzer run declares its transport role explicitly'
        Assert-Equal 'without_skill' ([string]$directBundleRun.Mode) 'Phase 2 analyzer transport stays without_skill'
        Assert-Equal 'with_skill' ([string]$directBundleDocument.configuration) 'Phase 2 bundle preserves the graded subject configuration independently of transport mode'

        $skeleton = Invoke-TestTool -Path $validationScript -Arguments @('-ShowSkeleton')
        Assert-ToolPasses -Invocation $skeleton -Description 'grading skeleton emission'
        $skeletonDocument = $skeleton.Text | ConvertFrom-Json -Depth 100
        Assert-Equal (Get-RunnerSchemaNames).Grading ([string]$skeletonDocument.schema) 'grading skeleton uses the authoritative grading schema'
        Assert-Equal 0 @($skeletonDocument.grading).Count 'grading skeleton exposes an empty grading array'
        Assert-Equal 'schema,grading' ([string]::Join(',', @($skeletonDocument.PSObject.Properties.Name))) 'grading skeleton exposes only the grading envelope'
        Assert-TestFileHashSnapshot -Expected $validationSnapshot -Message 'grading skeleton emission'

        [System.IO.File]::WriteAllText($gradingPath, '{', [System.Text.UTF8Encoding]::new($false))
        $malformedValidation = Invoke-TestTool -Path $validationScript -Arguments $validationArguments
        Assert-ToolFails -Invocation $malformedValidation -Description 'malformed grading JSON validation'
        Assert-True (-not [string]::IsNullOrWhiteSpace($malformedValidation.Text)) 'malformed grading validation emits a diagnostic'
        $malformedValidationAgain = Invoke-TestTool -Path $validationScript -Arguments $validationArguments
        Assert-ToolFails -Invocation $malformedValidationAgain -Description 'repeated malformed grading JSON validation'
        Assert-TestFileHashSnapshot -Expected $validationSnapshot -Message 'repeated invalid grading validation'

        Write-TestJson -Path $gradingPath -Value ([ordered]@{ grading = @() })
        Assert-ToolFails -Invocation (Invoke-TestTool -Path $validationScript -Arguments $validationArguments) -Description 'missing grading schema validation' -ExpectedText 'must declare'
        Write-TestJson -Path $gradingPath -Value ([ordered]@{ schema = 'wrong/schema'; grading = @() })
        Assert-ToolFails -Invocation (Invoke-TestTool -Path $validationScript -Arguments $validationArguments) -Description 'wrong grading schema validation' -ExpectedText 'must declare'
        Write-TestJson -Path $gradingPath -Value ([ordered]@{ schema = (Get-RunnerSchemaNames).Grading; grading = [ordered]@{} })
        Assert-ToolFails -Invocation (Invoke-TestTool -Path $validationScript -Arguments $validationArguments) -Description 'wrong grading envelope validation' -ExpectedText 'grading must be an array'
        $invalidEntry = Copy-TestGradingDocument -Document $validGrading
        $invalidEntry.grading[0].passed = 'yes'
        Write-TestJson -Path $gradingPath -Value $invalidEntry
        Assert-ToolFails -Invocation (Invoke-TestTool -Path $validationScript -Arguments $validationArguments) -Description 'invalid grading entry validation' -ExpectedText 'passed must be a boolean'
        Assert-TestFileHashSnapshot -Expected $validationSnapshot -Message 'invalid grading validation'

        foreach ($badEvidence in @('', " `t`n")) {
            $bad = Copy-TestGradingDocument -Document $validGrading
            $bad.grading[0].evidence = $badEvidence
            Write-TestJson -Path $gradingPath -Value $bad
            Assert-ToolFails -Invocation (Invoke-TestTool -Path $validationScript -Arguments $validationArguments) -Description 'non-evidentiary PASS rejected'
            Assert-TestFileHashSnapshot -Expected $validationSnapshot -Message 'evidence rejection preserves frozen execution'
        }
        foreach ($badReason in @('Evaluation completed with output', 'Assertion evaluated against output', 'The assertion is met', 'Output matches the assertion')) {
            $bad = Copy-TestGradingDocument -Document $validGrading
            $bad.grading[0].reason = $badReason
            $bad.grading[0].evidence = $badReason
            Write-TestJson -Path $gradingPath -Value $bad
            Assert-ToolFails -Invocation (Invoke-TestTool -Path $validationScript -Arguments $validationArguments) -Description 'generic PASS reason rejected'
            Assert-TestFileHashSnapshot -Expected $validationSnapshot -Message 'reason rejection preserves frozen execution'
        }
        $badQuote = Copy-TestGradingDocument -Document $validGrading
        $badQuote.grading[0].evidence_refs[0].quote = 'fabricated unavailable observation'
        Write-TestJson -Path $gradingPath -Value $badQuote
        Assert-ToolFails -Invocation (Invoke-TestTool -Path $validationScript -Arguments $validationArguments) -Description 'missing output quote rejected' -ExpectedText 'quote is absent'

        $badDomain = Copy-TestGradingDocument -Document $validGrading
        $badDomain.grading[0].evidence_domain = 'transcript'
        Write-TestJson -Path $gradingPath -Value $badDomain
        Assert-ToolFails -Invocation (Invoke-TestTool -Path $validationScript -Arguments $validationArguments) -Description 'wrong evidence domain rejected' -ExpectedText 'assertion identity'

        $validTranscriptEvent = Copy-TestGradingDocument -Document $validGrading
        $validTranscriptEventEntry = Get-GradingEntry -Document $validTranscriptEvent -EvalId $transcriptEvalId -Configuration 'with_skill' -AssertionIndex $transcriptAssertionIndex
        $validTranscriptEventEntry.evidence_refs = @((New-TestTranscriptEvidenceRef -Record $transcriptRecord -Canonical $transcriptCanonical -Kind Events -Artifact ([string]$collisionEventArtifacts[0].artifact)))
        Write-TestJson -Path $gradingPath -Value $validTranscriptEvent
        Assert-ToolPasses -Invocation (Invoke-TestTool -Path $validationScript -Arguments $validationArguments) -Description 'valid transcript event_index grading validation'
        Assert-TestFileHashSnapshot -Expected $validationSnapshot -Message 'valid transcript event-index grading validation'

        $missingTranscriptLocator = Copy-TestGradingDocument -Document $validGrading
        $missingTranscriptLocatorEntry = Get-GradingEntry -Document $missingTranscriptLocator -EvalId $transcriptEvalId -Configuration 'with_skill' -AssertionIndex $transcriptAssertionIndex
        Remove-TestProperty -Object $missingTranscriptLocatorEntry.evidence_refs[0] -Name 'event_index'
        Remove-TestProperty -Object $missingTranscriptLocatorEntry.evidence_refs[0] -Name 'quote'
        Write-TestJson -Path $gradingPath -Value $missingTranscriptLocator
        Assert-ToolFails -Invocation (Invoke-TestTool -Path $validationScript -Arguments $validationArguments) -Description 'artifact-only transcript evidence rejected' -ExpectedText 'must declare event_index or start_line/end_line'
        Assert-TestFileHashSnapshot -Expected $validationSnapshot -Message 'artifact-only transcript evidence rejection'

        $quotedWithoutTranscriptLocator = Copy-TestGradingDocument -Document $validGrading
        $quotedWithoutTranscriptLocatorEntry = Get-GradingEntry -Document $quotedWithoutTranscriptLocator -EvalId $transcriptEvalId -Configuration 'with_skill' -AssertionIndex $transcriptAssertionIndex
        Remove-TestProperty -Object $quotedWithoutTranscriptLocatorEntry.evidence_refs[0] -Name 'event_index'
        $quotedWithoutTranscriptLocatorEntry.evidence_refs[0].quote = 'some text'
        Write-TestJson -Path $gradingPath -Value $quotedWithoutTranscriptLocator
        Assert-ToolFails -Invocation (Invoke-TestTool -Path $validationScript -Arguments $validationArguments) -Description 'quoted transcript evidence without locator rejected' -ExpectedText 'must declare event_index or start_line/end_line'
        Assert-TestFileHashSnapshot -Expected $validationSnapshot -Message 'quoted transcript evidence without locator rejection'

        $invalidEventIndex = Copy-TestGradingDocument -Document $validGrading
        $invalidEventIndexEntry = Get-GradingEntry -Document $invalidEventIndex -EvalId $transcriptEvalId -Configuration 'with_skill' -AssertionIndex $transcriptAssertionIndex
        $invalidEventIndexEntry.evidence_refs = @([ordered]@{
                artifact = [string]$collisionEventArtifacts[0].artifact
                domain = 'transcript'
                event_index = 9
            })
        Write-TestJson -Path $gradingPath -Value $invalidEventIndex
        Assert-ToolFails -Invocation (Invoke-TestTool -Path $validationScript -Arguments $validationArguments) -Description 'out-of-range transcript event_index rejected' -ExpectedText 'event_index 9 is outside'
        Assert-TestFileHashSnapshot -Expected $validationSnapshot -Message 'transcript event-index bounds rejection'

        $validTranscriptLines = Copy-TestGradingDocument -Document $validGrading
        $validTranscriptLinesEntry = Get-GradingEntry -Document $validTranscriptLines -EvalId $transcriptEvalId -Configuration 'with_skill' -AssertionIndex $transcriptAssertionIndex
        $validTranscriptLinesEntry.evidence_refs = @((New-TestTranscriptEvidenceRef -Record $transcriptRecord -Canonical $transcriptCanonical -Kind Lines -Artifact ([string]$lineTranscriptArtifact.artifact)))
        Write-TestJson -Path $gradingPath -Value $validTranscriptLines
        Assert-ToolPasses -Invocation (Invoke-TestTool -Path $validationScript -Arguments $validationArguments) -Description 'valid transcript line-range grading validation'
        Assert-TestFileHashSnapshot -Expected $validationSnapshot -Message 'valid transcript line-range grading validation'

        $invalidTranscriptLines = Copy-TestGradingDocument -Document $validGrading
        $invalidTranscriptLinesEntry = Get-GradingEntry -Document $invalidTranscriptLines -EvalId $transcriptEvalId -Configuration 'with_skill' -AssertionIndex $transcriptAssertionIndex
        $invalidTranscriptLinesEntry.evidence_refs = @([ordered]@{
                artifact = [string]$lineTranscriptArtifact.artifact
                domain = 'transcript'
                start_line = 9
                end_line = 9
                quote = 'alpha frozen transcript line'
            })
        Write-TestJson -Path $gradingPath -Value $invalidTranscriptLines
        Assert-ToolFails -Invocation (Invoke-TestTool -Path $validationScript -Arguments $validationArguments) -Description 'out-of-range transcript line range rejected' -ExpectedText 'line range is outside'
        Assert-TestFileHashSnapshot -Expected $validationSnapshot -Message 'transcript line-range bounds rejection'

        $missingTranscriptEndLine = Copy-TestGradingDocument -Document $validGrading
        $missingTranscriptEndLineEntry = Get-GradingEntry -Document $missingTranscriptEndLine -EvalId $transcriptEvalId -Configuration 'with_skill' -AssertionIndex $transcriptAssertionIndex
        $missingTranscriptEndLineEntry.evidence_refs = @([ordered]@{
                artifact = [string]$lineTranscriptArtifact.artifact
                domain = 'transcript'
                start_line = 1
                quote = 'alpha frozen transcript line'
            })
        Write-TestJson -Path $gradingPath -Value $missingTranscriptEndLine
        Assert-ToolFails -Invocation (Invoke-TestTool -Path $validationScript -Arguments $validationArguments) -Description 'partial transcript line locator rejected' -ExpectedText 'line locator must declare both start_line and end_line'
        Assert-TestFileHashSnapshot -Expected $validationSnapshot -Message 'partial transcript line locator rejection'

        $lineArtifactEventLocator = Copy-TestGradingDocument -Document $validGrading
        $lineArtifactEventLocatorEntry = Get-GradingEntry -Document $lineArtifactEventLocator -EvalId $transcriptEvalId -Configuration 'with_skill' -AssertionIndex $transcriptAssertionIndex
        $lineArtifactEventLocatorEntry.evidence_refs = @([ordered]@{
                artifact = [string]$lineTranscriptArtifact.artifact
                domain = 'transcript'
                event_index = 0
                quote = 'alpha frozen transcript line'
            })
        Write-TestJson -Path $gradingPath -Value $lineArtifactEventLocator
        Assert-ToolFails -Invocation (Invoke-TestTool -Path $validationScript -Arguments $validationArguments) -Description 'event locator on line-based transcript rejected' -ExpectedText 'uses event_index but the frozen artifact has line-based content'
        Assert-TestFileHashSnapshot -Expected $validationSnapshot -Message 'line-based transcript event locator rejection'

        $eventArtifactLineLocator = Copy-TestGradingDocument -Document $validGrading
        $eventArtifactLineLocatorEntry = Get-GradingEntry -Document $eventArtifactLineLocator -EvalId $transcriptEvalId -Configuration 'with_skill' -AssertionIndex $transcriptAssertionIndex
        $eventArtifactLineLocatorEntry.evidence_refs = @([ordered]@{
                artifact = [string]$collisionEventArtifacts[0].artifact
                domain = 'transcript'
                start_line = 1
                end_line = 1
                quote = 'artifact-a exact frozen quote'
            })
        Write-TestJson -Path $gradingPath -Value $eventArtifactLineLocator
        Assert-ToolFails -Invocation (Invoke-TestTool -Path $validationScript -Arguments $validationArguments) -Description 'line locator on event-based transcript rejected' -ExpectedText 'uses start_line/end_line but the frozen artifact has event-based content'
        Assert-TestFileHashSnapshot -Expected $validationSnapshot -Message 'event-based transcript line locator rejection'

        $crossArtifactQuote = Copy-TestGradingDocument -Document $validGrading
        $crossArtifactQuoteEntry = Get-GradingEntry -Document $crossArtifactQuote -EvalId $transcriptEvalId -Configuration 'with_skill' -AssertionIndex $transcriptAssertionIndex
        $crossArtifactQuoteEntry.evidence_refs = @([ordered]@{
                artifact = [string]$collisionEventArtifacts[0].artifact
                domain = 'transcript'
                event_index = 0
                quote = 'artifact-b exact frozen quote'
            })
        Write-TestJson -Path $gradingPath -Value $crossArtifactQuote
        Assert-ToolFails -Invocation (Invoke-TestTool -Path $validationScript -Arguments $validationArguments) -Description 'cross-artifact transcript quote rejected' -ExpectedText 'quote is absent from the referenced frozen event'
        Assert-TestFileHashSnapshot -Expected $validationSnapshot -Message 'cross-artifact transcript quote rejection'

        $repeated = Copy-TestGradingDocument -Document $validGrading
        $repeated.grading[1].evidence = $repeated.grading[0].evidence
        Write-TestJson -Path $gradingPath -Value $repeated
        Assert-ToolFails -Invocation (Invoke-TestTool -Path $validationScript -Arguments $validationArguments) -Description 'repeated PASS evidence rejected' -ExpectedText 'Repeated PASS evidence'

        Write-TestJson -Path $gradingPath -Value $validGrading
        $validValidation = Invoke-TestTool -Path $validationScript -Arguments $validationArguments
        Assert-ToolPasses -Invocation $validValidation -Description 'valid grading validation'
        $validValidationAgain = Invoke-TestTool -Path $validationScript -Arguments $validationArguments
        Assert-ToolPasses -Invocation $validValidationAgain -Description 'repeated valid grading validation'
        Assert-TestFileHashSnapshot -Expected $validationSnapshot -Message 'repeated valid grading validation'

    }
    Write-TestJson -Path $gradingPath -Value $validGrading
    if ($Suite -in @('All', 'Application', 'Finalization')) {
        $manualNoFreezeFinalizer = Invoke-TestTool -Path $finalizerScript -Arguments $finalizerArguments
        Assert-ToolFails -Invocation $manualNoFreezeFinalizer -Description 'finalizer rejects handcrafted grading without Phase 2 freeze' -ExpectedText 'grading-freeze.json is missing'
        $phase2Script = Join-Path $packageTools 'invoke-phase2-analyzer.ps1'
        $phase2 = Invoke-TestTool -Path $phase2Script -Arguments @('-IterationDirectory', $iteration, '-Concurrency', '3', '-TimeoutSeconds', '60')
        Assert-ToolPasses -Invocation $phase2 -Description 'fixture Phase 2 analyzer controller'
        Assert-True (Test-Path -LiteralPath (Join-Path $iteration 'phase2-state.json') -PathType Leaf) 'Phase 2 writes phase2-state.json'
        Assert-True (Test-Path -LiteralPath (Join-Path $iteration 'grading-freeze.json') -PathType Leaf) 'Phase 2 writes grading-freeze.json'
        $phase2State = Read-TestJson -Path (Join-Path $iteration 'phase2-state.json')
        Assert-True (@($phase2State.expected_worker_ids | Where-Object { [string]$_ -like 'arm-3-*' }).Count -eq 0) 'validator-only eval arms must require zero analyzer workers'
        Assert-Equal 14 @($phase2State.validator_results).Count 'validator-only paired arms resolve process assertions deterministically'
        Assert-Equal 4 @($phase2State.expected_worker_ids).Count 'semantic worker cardinality derives from unresolved assertions, not manifest arm count'
        $phase2BundlePath = Join-Path $iteration 'phase2\work\arm-2-with_skill\repo\input-bundle.json'
        $phase2Bundle = Read-TestJson -Path $phase2BundlePath
        $stagedCollisionEntries = @($phase2Bundle.frozen_transcripts | Where-Object { [string]$_.artifact -like 'with_skill/evidence/*/events.jsonl' } | Sort-Object artifact)
        Assert-Equal 2 $stagedCollisionEntries.Count 'Phase 2 stages both same-basename transcript artifacts'
        Assert-True ([string]$stagedCollisionEntries[0].staged_artifact -cne [string]$stagedCollisionEntries[1].staged_artifact) 'same-basename transcript artifacts must stage to unique paths'
        $phase2BundleRepo = Join-Path $iteration 'phase2\work\arm-2-with_skill\repo'
        $stagedCollisionContents = [System.Collections.Generic.List[string]]::new()
        foreach ($entry in $stagedCollisionEntries) {
            $sourcePath = Resolve-TranscriptArtifactSourcePath -Record $transcriptRecord -Artifact ([string]$entry.artifact)
            $stagedPath = Resolve-ContainedPath -BasePath $phase2BundleRepo -RelativePath ([string]$entry.staged_artifact) -FieldName 'staged transcript artifact' -Kind File
            Assert-Equal ([string]$entry.source_sha256) (Get-Sha256HexFromFile -Path $sourcePath) "bundle preserves the source hash for $([string]$entry.artifact)"
            Assert-Equal ([string]$entry.staged_sha256) (Get-Sha256HexFromFile -Path $stagedPath) "bundle preserves the staged hash for $([string]$entry.artifact)"
            $sourceContent = [System.IO.File]::ReadAllText($sourcePath, [System.Text.UTF8Encoding]::new($false))
            $stagedContent = [System.IO.File]::ReadAllText($stagedPath, [System.Text.UTF8Encoding]::new($false))
            Assert-Equal $sourceContent $stagedContent "staged transcript preserves the frozen content for $([string]$entry.artifact)"
            $stagedCollisionContents.Add($stagedContent)
        }
        Assert-True ([string]$stagedCollisionContents[0] -cne [string]$stagedCollisionContents[1]) 'same-basename transcript artifacts keep distinct staged content'
        $rootGradingAfterPhase2 = Read-TestJson -Path $gradingPath
        Assert-Equal 22 @($rootGradingAfterPhase2.grading).Count 'root grading cardinality derives from normalized assertions'
        Assert-True (@($rootGradingAfterPhase2.grading | Where-Object { [string]$_.evidence_domain -eq 'validator' -and [string]$_.source -eq 'validator' }).Count -eq 14) 'validator assertions are resolved by deterministic validator results, not analyzer prose'
        $validGrading = Read-TestJson -Path $gradingPath
        # Fix 2: second invocation must return already_frozen, exit 0, perform zero new analyzer work.
        $freezeBytes = [System.IO.File]::ReadAllBytes((Join-Path $iteration 'grading-freeze.json'))
        $stateBytes = [System.IO.File]::ReadAllBytes((Join-Path $iteration 'phase2-state.json'))
        $gradingBytes = [System.IO.File]::ReadAllBytes($gradingPath)
        $phase2AnalyzerWorkerDirCountBefore = @(Get-ChildItem -LiteralPath (Join-Path $iteration 'phase2\work') -Directory -ErrorAction SilentlyContinue).Count
        $phase2Again = Invoke-TestTool -Path $phase2Script -Arguments @('-IterationDirectory', $iteration, '-Concurrency', '3', '-TimeoutSeconds', '60')
        Assert-ToolPasses -Invocation $phase2Again -Description 'second Phase 2 invocation succeeds (already_frozen)'
        $phase2AgainOutput = $phase2Again.Text | ConvertFrom-Json -ErrorAction SilentlyContinue
        Assert-Equal 'already_frozen' ([string]$phase2AgainOutput.status) 'second Phase 2 invocation must report already_frozen status'
        $freezeBytesAfter = [System.IO.File]::ReadAllBytes((Join-Path $iteration 'grading-freeze.json'))
        $stateBytesAfter = [System.IO.File]::ReadAllBytes((Join-Path $iteration 'phase2-state.json'))
        $gradingBytesAfter = [System.IO.File]::ReadAllBytes($gradingPath)
        Assert-True ([System.Linq.Enumerable]::SequenceEqual($freezeBytes, $freezeBytesAfter)) 'grading-freeze.json must be byte-identical after second Phase 2 invocation'
        Assert-True ([System.Linq.Enumerable]::SequenceEqual($stateBytesAfter, $stateBytes)) 'phase2-state.json must be byte-identical after second Phase 2 invocation'
        Assert-True ([System.Linq.Enumerable]::SequenceEqual($gradingBytesAfter, $gradingBytes)) 'grading.json must be byte-identical after second Phase 2 invocation'
        $phase2AnalyzerWorkerDirCountAfter = @(Get-ChildItem -LiteralPath (Join-Path $iteration 'phase2\work') -Directory -ErrorAction SilentlyContinue).Count
        Assert-Equal $phase2AnalyzerWorkerDirCountBefore $phase2AnalyzerWorkerDirCountAfter 'second Phase 2 invocation must create zero new analyzer worker directories'
        # Tampered grading-freeze.json must fail rather than rerun.
        $freezePath = Join-Path $iteration 'grading-freeze.json'
        $originalFreezeBytes = [System.IO.File]::ReadAllBytes($freezePath)
        $tamperedFreeze = Read-TestJson -Path $freezePath
        $tamperedFreeze.grading_sha256 = ('0' * 64)
        Write-TestJson -Path $freezePath -Value $tamperedFreeze
        $phase2Tampered = Invoke-TestTool -Path $phase2Script -Arguments @('-IterationDirectory', $iteration, '-Concurrency', '3', '-TimeoutSeconds', '60')
        Assert-ToolFails -Invocation $phase2Tampered -Description 'tampered grading-freeze.json fails Phase 2 instead of rerunning'
        [System.IO.File]::WriteAllBytes($freezePath, $originalFreezeBytes)
        # Orphaned phase2-state.json without a valid freeze must fail closed.
        $statePath = Join-Path $iteration 'phase2-state.json'
        $originalStateBytes = [System.IO.File]::ReadAllBytes($statePath)
        Remove-Item -LiteralPath $freezePath -Force
        $phase2Orphaned = Invoke-TestTool -Path $phase2Script -Arguments @('-IterationDirectory', $iteration, '-Concurrency', '3', '-TimeoutSeconds', '60')
        Assert-ToolFails -Invocation $phase2Orphaned -Description 'orphaned phase2-state.json without freeze fails closed'
        Assert-True ([string]$phase2Orphaned.Text -match 'duplicate|fresh package|grading freeze') 'orphaned state must explain the retry is forbidden'
        [System.IO.File]::WriteAllBytes($freezePath, $originalFreezeBytes)
    }
    if ($Suite -in @('All', 'Application')) {
        $invalidDirectFinalizer = Copy-TestGradingDocument -Document $validGrading
        $invalidDirectFinalizer.grading[0].evidence = 123
        Write-TestJson -Path $gradingPath -Value $invalidDirectFinalizer
        $directInvalidFinalizer = Invoke-TestTool -Path $finalizerScript -Arguments $finalizerArguments
        Assert-ToolFails -Invocation $directInvalidFinalizer -Description 'finalizer rejects post-freeze grading mutation' -ExpectedText 'Root grading.json was changed'
        Assert-True (-not (Test-Path -LiteralPath (Join-Path $iteration 'report.html') -PathType Leaf)) 'invalid direct finalizer produces no report'

        Write-TestJson -Path $gradingPath -Value $validGrading
        Assert-ToolPasses -Invocation (Invoke-TestTool -Path $validationScript -Arguments $validationArguments) -Description 'valid grading validation before application'
        $canonicalBeforeGrading = @{}
        foreach ($record in $records) { $canonicalBeforeGrading[$record.ResultPath] = Get-JsonFingerprint -Object (Get-JsonWithoutProperty -Object (Read-TestJson -Path $record.ResultPath) -PropertyName 'grading') }
        Assert-ToolPasses -Invocation (Invoke-TestTool -Path $applyScript -Arguments $applyArguments) -Description 'allowed grading-only artifact application'
        foreach ($record in $records) {
            $canonical = Read-TestJson -Path $record.ResultPath
            Assert-Equal $canonicalBeforeGrading[$record.ResultPath] (Get-JsonFingerprint -Object (Get-JsonWithoutProperty -Object $canonical -PropertyName 'grading')) 'grading application leaves canonical non-grading fields unchanged'
        }

        $invalidGrading = [ordered]@{ schema = (Get-RunnerSchemaNames).Grading; grading = @($validGrading.grading); output = 'raw output is forbidden here' }
        Write-TestJson -Path $gradingPath -Value $invalidGrading
        $invalidApply = Invoke-TestTool -Path $applyScript -Arguments $applyArguments
        Assert-ToolFails -Invocation $invalidApply -Description 'grading artifact with raw output is rejected' -ExpectedText 'Root grading.json was changed'

        $forbiddenGradingFields = @('model', 'harness', 'execution_result_sha256', 'session_id', 'telemetry')
        foreach ($forbiddenField in $forbiddenGradingFields) {
            $forbiddenEntries = @($validGrading.grading | ForEach-Object {
                $copy = [ordered]@{}
                foreach ($name in @('eval_id', 'eval_name', 'configuration', 'assertion_index', 'assertion', 'passed', 'evidence', 'evidence_domain', 'evidence_refs', 'reason', 'source')) {
                    $copy[$name] = Get-JsonProperty -Object $_ -Name $name
                }
                $copy[$forbiddenField] = 'forbidden'
                $copy
            })
            Write-TestJson -Path $gradingPath -Value ([ordered]@{ schema = (Get-RunnerSchemaNames).Grading; grading = $forbiddenEntries })
            $forbiddenApply = Invoke-TestTool -Path $applyScript -Arguments $applyArguments
            Assert-ToolFails -Invocation $forbiddenApply -Description "grading artifact with $forbiddenField is rejected" -ExpectedText 'Root grading.json was changed'
        }
        Write-TestJson -Path $gradingPath -Value $validGrading
    }
    if ($Suite -in @('All', 'Finalization')) {
        $canonicalPath = $records[0].ResultPath
        $canonicalBytes = [System.IO.File]::ReadAllBytes($canonicalPath)
        $tamperedCanonical = Read-TestJson -Path $canonicalPath
        $tamperedCanonical.output = 'manual canonical tampering'
        Write-TestJson -Path $canonicalPath -Value $tamperedCanonical
        $canonicalTamperFinalizer = Invoke-TestTool -Path $finalizerScript -Arguments $finalizerArguments
        Assert-ToolFails -Invocation $canonicalTamperFinalizer -Description 'finalizer rejects canonical non-grading mutation' -ExpectedText 'Execution integrity failure'
        Remove-TestReportArtifacts -IterationDirectory $iteration
        [System.IO.File]::WriteAllBytes($canonicalPath, $canonicalBytes)

        $canonicalApplyTamperBytes = [System.IO.File]::ReadAllBytes($canonicalPath)
        $canonicalApplyTamper = Read-TestJson -Path $canonicalPath
        $canonicalApplyTamper.output = 'direct application tampering'
        Write-TestJson -Path $canonicalPath -Value $canonicalApplyTamper
        $canonicalApplyTamperResult = Invoke-TestTool -Path $applyScript -Arguments $applyArguments
        Assert-ToolFails -Invocation $canonicalApplyTamperResult -Description 'grading application rejects canonical non-grading mutation before applying' -ExpectedText 'Execution integrity failure'
        [System.IO.File]::WriteAllBytes($canonicalPath, $canonicalApplyTamperBytes)

        # Exact reproduction of the latest Copilot mistake: grading is written to
        # execution-result.json after a valid bridge. The finalizer must fail closed
        # and must not repair the bytes or create report artifacts.
        $copilotMistakeBytes = [System.IO.File]::ReadAllBytes($selectedRecord.ExecutionResultPath)
        $copilotMistakeRaw = Read-TestJson -Path $selectedRecord.ExecutionResultPath
        $copilotMistakeRaw | Add-Member -NotePropertyName grading -NotePropertyValue @([ordered]@{ text = 'wrong location' })
        Write-TestJson -Path $selectedRecord.ExecutionResultPath -Value $copilotMistakeRaw
        Remove-TestReportArtifacts -IterationDirectory $iteration
        $copilotMistakeFinalizer = Invoke-TestTool -Path $finalizerScript -Arguments $finalizerArguments
        Assert-ToolFails -Invocation $copilotMistakeFinalizer -Description 'finalizer rejects Copilot raw-result grading mistake' -ExpectedText 'Execution integrity failure'
        Assert-True (-not (Test-Path -LiteralPath (Join-Path $iteration 'report.html') -PathType Leaf)) 'corrupted package produces no report'
        [System.IO.File]::WriteAllBytes($selectedRecord.ExecutionResultPath, $copilotMistakeBytes)
        Assert-Equal $selectedRawHash (Get-Sha256HexFromFile -Path $selectedRecord.ExecutionResultPath) 'Copilot mistake restoration returns exact frozen bytes'

        [Environment]::SetEnvironmentVariable('AGENTIC_TEST_REPORT_MODE', 'missing')
        Remove-TestReportArtifacts -IterationDirectory $iteration
        $missingReportFinalizer = Invoke-TestTool -Path $finalizerScript -Arguments $finalizerArguments
        Assert-ToolFails -Invocation $missingReportFinalizer -Description 'finalizer rejects missing report artifact'
        [Environment]::SetEnvironmentVariable('AGENTIC_TEST_REPORT_MODE', 'failure')
        Remove-TestReportArtifacts -IterationDirectory $iteration
        $failedReportFinalizer = Invoke-TestTool -Path $finalizerScript -Arguments $finalizerArguments
        Assert-ToolFails -Invocation $failedReportFinalizer -Description 'finalizer rejects report generator failure' -ExpectedText 'Report generation failed'

        [Environment]::SetEnvironmentVariable('AGENTIC_TEST_REPORT_MODE', '')
        Remove-TestReportArtifacts -IterationDirectory $iteration
        Write-TestJson -Path $gradingPath -Value $validGrading
        Assert-ToolPasses -Invocation (Invoke-TestTool -Path $validationScript -Arguments $validationArguments) -Description 'correctly validated grading before finalization'
        $successfulFinalizer = Invoke-TestTool -Path $finalizerScript -Arguments $finalizerArguments
        Assert-ToolPasses -Invocation $successfulFinalizer -Description 'deterministic finalizer success'
        $finalSummary = $successfulFinalizer.Text | ConvertFrom-Json -Depth 100 | Select-Object -Last 1
        Assert-Equal 'completed' $finalSummary.status 'finalizer returns machine-readable completed status'
        foreach ($relative in @('report.html', 'skill-creator-report.html', 'benchmark.json', 'benchmark.md')) {
            $artifact = Join-Path $iteration $relative
            Assert-True (Test-Path -LiteralPath $artifact -PathType Leaf) "finalizer creates $relative"
            Assert-True ((Get-Item -LiteralPath $artifact).Length -gt 0) "$relative is non-empty"
        }

    }
    Write-Output "Eval package integrity and finalization: PASS ($Suite)"
} finally {
    [Environment]::SetEnvironmentVariable('AGENTIC_TEST_REPORT_MODE', $oldReportMode)
    if (Test-Path -LiteralPath $testRoot) {
        Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}
