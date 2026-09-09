Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not (Get-Command Get-RunnerSchemaNames -ErrorAction SilentlyContinue)) {
    . (Join-Path $PSScriptRoot 'runner-common.ps1')
}
if (-not (Get-Command Get-ManifestRunRecords -ErrorAction SilentlyContinue)) {
    . (Join-Path $PSScriptRoot 'manifest-paths.ps1')
}
if (-not (Get-Command Assert-ExecutionFreeze -ErrorAction SilentlyContinue)) {
    . (Join-Path $PSScriptRoot 'execution-freeze.ps1')
}

$script:Phase2Schema = 'codebeltnet/agentic/eval-phase2-state/1'
$script:GradingFreezeSchema = 'codebeltnet/agentic/eval-grading-freeze/1'
$script:AnalyzerProfileSchema = 'codebeltnet/agentic/eval-analyzer-profile/1'
$script:AnalyzerResultSchema = 'codebeltnet/agentic/eval-analyzer-result/1'
$script:ValidatorResultSchema = 'codebeltnet/agentic/eval-validator-result/1'

function Get-Phase2SchemaNames {
    return [ordered]@{
        Phase2State = $script:Phase2Schema
        GradingFreeze = $script:GradingFreezeSchema
        AnalyzerProfile = $script:AnalyzerProfileSchema
        AnalyzerResult = $script:AnalyzerResultSchema
        ValidatorResult = $script:ValidatorResultSchema
        RootGrading = (Get-RunnerSchemaNames).Grading
    }
}

function Get-AssertionText {
    param([Parameter(Mandatory = $true)][object]$Assertion)

    if ($Assertion -is [string]) { return [string]$Assertion }
    $text = [string](Get-JsonProperty -Object $Assertion -Name 'assertion' -Default (Get-JsonProperty -Object $Assertion -Name 'text' -Default ''))
    if ([string]::IsNullOrWhiteSpace($text)) { throw 'Assertion text must be non-empty.' }
    return $text
}

function Normalize-EvalAssertion {
    param(
        [Parameter(Mandatory = $true)][object]$Assertion,
        [Parameter(Mandatory = $true)][int]$Index
    )

    if ($Assertion -is [string]) {
        $text = [string]$Assertion
        if ([string]::IsNullOrWhiteSpace($text)) { throw "Assertion $Index is empty." }
        return [ordered]@{
            assertion = $text
            evidence_domain = 'output'
            validator = $null
        }
    }

    $text = [string](Get-JsonProperty -Object $Assertion -Name 'assertion' -Default (Get-JsonProperty -Object $Assertion -Name 'text' -Default ''))
    if ([string]::IsNullOrWhiteSpace($text)) { throw "Assertion $Index is missing assertion text." }
    $domain = [string](Get-JsonProperty -Object $Assertion -Name 'evidence_domain' -Default 'output')
    if ($domain -notin @('output', 'transcript', 'validator')) { throw "Assertion $Index evidence_domain '$domain' is unsupported." }
    $validator = Get-JsonProperty -Object $Assertion -Name 'validator' -Default $null
    if ($domain -eq 'validator' -and [string]::IsNullOrWhiteSpace([string]$validator)) { throw "Assertion $Index with evidence_domain=validator must declare validator." }
    if ($domain -ne 'validator' -and -not [string]::IsNullOrWhiteSpace([string]$validator)) { throw "Assertion $Index declares validator for non-validator evidence_domain '$domain'." }

    return [ordered]@{
        assertion = $text
        evidence_domain = $domain
        validator = if ($null -eq $validator -or [string]::IsNullOrWhiteSpace([string]$validator)) { $null } else { [string]$validator }
    }
}

function Get-NormalizedAssertions {
    param([Parameter(Mandatory = $true)][object[]]$Assertions)

    $normalized = [System.Collections.Generic.List[object]]::new()
    for ($index = 0; $index -lt @($Assertions).Count; $index++) {
        $normalized.Add((Normalize-EvalAssertion -Assertion $Assertions[$index] -Index $index))
    }
    if ($normalized.Count -eq 0) { throw 'Each eval must declare at least one assertion.' }
    return @($normalized.ToArray())
}

function Get-EvalMetadataAssertionObjects {
    param([Parameter(Mandatory = $true)][object]$Record)

    $metadata = Read-RunnerJson -Path $Record.MetadataPath
    $assertions = @(Get-JsonProperty -Object $metadata -Name 'assertions' -Default @())
    return @(Get-NormalizedAssertions -Assertions $assertions)
}

function Get-ArmKey {
    param([Parameter(Mandatory = $true)][int]$EvalId, [Parameter(Mandatory = $true)][string]$Configuration)

    return ('arm-{0}-{1}' -f $EvalId, $Configuration)
}

function Get-ArmOutputLines {
    param([Parameter(Mandatory = $true)][string]$Output)

    $lines = $Output -split "`r?`n", -1
    return @($lines)
}

function New-OutputEvidenceRef {
    param(
        [Parameter(Mandatory = $true)][object]$Record,
        [Parameter(Mandatory = $true)][string]$Output,
        [Parameter(Mandatory = $true)][string]$Quote
    )

    $lines = @(Get-ArmOutputLines -Output $Output)
    if ([string]::IsNullOrWhiteSpace($Quote)) { throw 'Output evidence quote must be non-empty.' }
    for ($index = 0; $index -lt $lines.Count; $index++) {
        $line = [string]$lines[$index]
        if ($line.Contains($Quote, [StringComparison]::Ordinal)) {
            return [ordered]@{
                artifact = [string]$Record.ResultRelative
                domain = 'output'
                start_line = $index + 1
                end_line = $index + 1
                quote = $Quote
            }
        }
    }
    throw 'Output evidence quote is absent from the frozen canonical output.'
}

function Test-CommandText {
    param([object]$Command)

    $text = [string](Get-JsonProperty -Object $Command -Name 'command' -Default (Get-JsonProperty -Object $Command -Name 'tool' -Default ''))
    return $text
}

function Get-NormalizedCommandEvidence {
    param([Parameter(Mandatory = $true)][object]$Canonical)

    $commands = [System.Collections.Generic.List[object]]::new()
    foreach ($command in @(Get-JsonProperty -Object $Canonical -Name 'shell_commands' -Default @())) {
        $text = Test-CommandText -Command $command
        if ([string]::IsNullOrWhiteSpace($text)) { continue }
        $commands.Add([ordered]@{
            command = $text
            status = Get-JsonProperty -Object $command -Name 'status' -Default $null
            exit_code = Get-JsonProperty -Object $command -Name 'exit_code' -Default $null
        })
    }
    return @($commands.ToArray())
}

function Test-CommandMatches {
    param(
        [Parameter(Mandatory = $true)][object[]]$Commands,
        [Parameter(Mandatory = $true)][string[]]$Patterns
    )

    foreach ($command in @($Commands)) {
        $text = [string](Get-JsonProperty -Object $command -Name 'command' -Default '')
        foreach ($pattern in @($Patterns)) {
            if ($text -match $pattern) { return $command }
        }
    }
    return $null
}

function New-ValidatorEvidenceRef {
    param(
        [Parameter(Mandatory = $true)][object]$Record,
        [Parameter(Mandatory = $true)][string]$Rule,
        [Parameter(Mandatory = $true)][bool]$Passed,
        [object]$Evidence = $null
    )

    return [ordered]@{
        artifact = [string]$Record.ResultRelative
        domain = 'validator'
        rule = $Rule
        version = 1
        passed = $Passed
        event = if ($null -eq $Evidence) { $null } else { Get-JsonProperty -Object $Evidence -Name 'command' -Default $null }
    }
}

function Invoke-GradingValidatorRule {
    param(
        [Parameter(Mandatory = $true)][string]$Rule,
        [Parameter(Mandatory = $true)][object]$Canonical,
        [Parameter(Mandatory = $true)][object]$Record
    )

    $commands = @(Get-NormalizedCommandEvidence -Canonical $Canonical)
    $filesWritten = @(Get-JsonProperty -Object $Canonical -Name 'files_written' -Default @())
    $candidateSkill = 'dotnet-change-impact'
    $matched = $null
    $passed = $false
    $reason = ''
    switch ($Rule) {
        'git.current_branch_observed' {
            $matched = Test-CommandMatches -Commands $commands -Patterns @('(?i)\bgit\b.*\b(branch\s+--show-current|rev-parse\s+--abbrev-ref\s+HEAD|status\b)')
            $passed = $null -ne $matched
            $reason = if ($passed) { 'A structured command event observed the current branch.' } else { 'No structured command event observed current-branch resolution.' }
        }
        'git.default_branch_resolved' {
            $matched = Test-CommandMatches -Commands $commands -Patterns @('(?i)\bgit\b.*\b(symbolic-ref\s+refs/remotes/origin/HEAD|remote\s+show\s+origin|merge-base\b|rev-parse\s+origin/(HEAD|main|master|trunk))')
            $passed = $null -ne $matched
            $reason = if ($passed) { 'A structured command event resolved a local base/default branch.' } else { 'No structured command event resolved a local base/default branch.' }
        }
        'git.branch_commits_collected' {
            $matched = Test-CommandMatches -Commands $commands -Patterns @('(?i)\bgit\b.*\b(log|rev-list)\b.*(\.\.|origin/HEAD|trunk|main|master)')
            $passed = $null -ne $matched
            $reason = if ($passed) { 'A structured command event collected branch-only commits.' } else { 'No structured command event collected branch-only commits.' }
        }
        'git.three_dot_diff_observed' {
            $matched = Test-CommandMatches -Commands $commands -Patterns @('(?i)\bgit\b.*\bdiff\b.*\.\.\.')
            $passed = $null -ne $matched
            $reason = if ($passed) { 'A structured command event collected a three-dot net diff.' } else { 'No structured command event collected a three-dot net diff.' }
        }
        'skill.no_candidate_package_search' {
            $matched = Test-CommandMatches -Commands $commands -Patterns @("(?i)\b(search|find|list)\b.*$([regex]::Escape($candidateSkill))", "(?i)\b(dotnet|npm|pip|winget|choco|brew)\b.*\b(search|list)\b.*$([regex]::Escape($candidateSkill))")
            $passed = $null -eq $matched
            $reason = if ($passed) { 'No structured command event searched for the candidate skill as a package or tool.' } else { 'A structured command event searched for the candidate skill as a package or tool.' }
        }
        'skill.no_candidate_install_attempt' {
            $matched = Test-CommandMatches -Commands $commands -Patterns @("(?i)\b(install|add)\b.*$([regex]::Escape($candidateSkill))", "(?i)\b(dotnet|npm|pip|winget|choco|brew)\b.*\b(install|add)\b.*$([regex]::Escape($candidateSkill))")
            $passed = $null -eq $matched
            $reason = if ($passed) { 'No structured command event attempted to install the candidate skill as a package or tool.' } else { 'A structured command event attempted to install the candidate skill as a package or tool.' }
        }
        'workspace.no_unnecessary_mutation' {
            $matched = Test-CommandMatches -Commands $commands -Patterns @('(?i)\b(dotnet\s+(add|new|tool\s+install|restore)|npm\s+install|pip\s+install|git\s+(commit|checkout|switch|merge|rebase|reset)|Set-Content|Out-File|New-Item|Remove-Item)\b')
            $passed = ($null -eq $matched -and $filesWritten.Count -eq 0)
            $reason = if ($passed) { 'No structured file-write evidence or mutation command was captured for this read-only classification task.' } else { 'Mutation evidence was captured for this read-only classification task.' }
        }
        default { throw "Unsupported validator rule '$Rule'." }
    }

    return [ordered]@{
        schema = $script:ValidatorResultSchema
        rule = $Rule
        version = 1
        eval_id = [int]$Record.EvalId
        eval_name = [string]$Record.EvalName
        configuration = [string]$Record.Configuration
        passed = [bool]$passed
        reason = $reason
        evidence_refs = @((New-ValidatorEvidenceRef -Record $Record -Rule $Rule -Passed ([bool]$passed) -Evidence $matched))
    }
}

function Get-GraderContractPath {
    param([Parameter(Mandatory = $true)][string]$IterationDirectory)

    $path = Join-Path $IterationDirectory 'tools/skill-creator/agents/grader.md'
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "Packaged grader contract is missing at '$path'." }
    return $path
}

function Resolve-AnalyzerProfile {
    param(
        [Parameter(Mandatory = $true)][string]$IterationDirectory,
        [Parameter(Mandatory = $true)][object]$Manifest
    )

    $relative = [string](Get-JsonProperty -Object $Manifest -Name 'analyzer_profile' -Default 'analyzer-profile.json')
    $path = Resolve-ManifestDeclaredPath -IterationDirectory $IterationDirectory -RelativePath $relative -FieldName 'analyzer_profile' -Kind File -RequireExists
    $profile = Read-RunnerJson -Path $path
    $schemas = Get-Phase2SchemaNames
    if ([string](Get-JsonProperty -Object $profile -Name 'schema' -Default '') -ne $schemas.AnalyzerProfile) { throw 'analyzer-profile.json has an unsupported schema.' }
    foreach ($name in @('contract_version', 'runner', 'harness', 'model', 'selection_source')) {
        if ([string]::IsNullOrWhiteSpace([string](Get-JsonProperty -Object $profile -Name $name -Default ''))) { throw "analyzer-profile.json must declare non-empty '$name'." }
    }
    if ([string](Get-JsonProperty -Object $profile -Name 'contract_version' -Default '') -ne $schemas.RootGrading) { throw 'analyzer-profile.json contract_version does not match the grading schema.' }
    $source = [string](Get-JsonProperty -Object $profile -Name 'selection_source' -Default '')
    if ($source -notin @('codebelt-reference', 'explicit')) { throw "analyzer-profile.json selection_source '$source' is unsupported." }
    $runner = [string](Get-JsonProperty -Object $profile -Name 'runner' -Default '')
    if ($runner -notmatch '^[a-z0-9][a-z0-9-]*$') { throw 'analyzer-profile.json runner must be a safe lowercase runner id.' }
    return [pscustomobject]@{
        Path = $path
        RelativePath = $relative
        Profile = $profile
        Hash = Get-Sha256HexFromFile -Path $path
        Runner = $runner
        Model = [string](Get-JsonProperty -Object $profile -Name 'model' -Default '')
        ReasoningEffort = Get-JsonProperty -Object $profile -Name 'reasoning_effort' -Default $null
        Harness = [string](Get-JsonProperty -Object $profile -Name 'harness' -Default '')
        SelectionSource = $source
    }
}

function Get-ExpectedGradeRecords {
    param(
        [Parameter(Mandatory = $true)][string]$IterationDirectory,
        [Parameter(Mandatory = $true)][object]$Manifest
    )

    $records = @(Get-ManifestRunRecords -IterationDirectory $IterationDirectory -Manifest $Manifest | Sort-Object EvalId, Configuration)
    $expected = [System.Collections.Generic.List[object]]::new()
    foreach ($record in $records) {
        $assertions = @(Get-EvalMetadataAssertionObjects -Record $record)
        for ($index = 0; $index -lt $assertions.Count; $index++) {
            $assertion = $assertions[$index]
            $expected.Add([ordered]@{
                eval_id = [int]$record.EvalId
                eval_name = [string]$record.EvalName
                configuration = [string]$record.Configuration
                assertion_index = $index
                assertion = [string]$assertion.assertion
                evidence_domain = [string]$assertion.evidence_domain
                validator = Get-JsonProperty -Object $assertion -Name 'validator' -Default $null
                record = $record
            })
        }
    }
    return @($expected.ToArray())
}

function ConvertTo-GradingEntry {
    param(
        [Parameter(Mandatory = $true)][object]$Expected,
        [Parameter(Mandatory = $true)][bool]$Passed,
        [Parameter(Mandatory = $true)][string]$Reason,
        [Parameter(Mandatory = $true)][object[]]$EvidenceRefs,
        [string]$Source = 'analyzer',
        [string]$Evidence = ''
    )

    if ([string]::IsNullOrWhiteSpace($Evidence)) {
        $Evidence = $Reason
    }
    return [ordered]@{
        eval_id = [int]$Expected.eval_id
        eval_name = [string]$Expected.eval_name
        configuration = [string]$Expected.configuration
        assertion_index = [int]$Expected.assertion_index
        assertion = [string]$Expected.assertion
        passed = [bool]$Passed
        evidence_domain = [string]$Expected.evidence_domain
        evidence_refs = @($EvidenceRefs)
        reason = $Reason
        evidence = $Evidence
        source = $Source
    }
}

function Get-GradeKey {
    param([Parameter(Mandatory = $true)][object]$Grade)

    return ('{0}|{1}|{2}' -f [int](Get-JsonProperty -Object $Grade -Name 'eval_id' -Default 0), [string](Get-JsonProperty -Object $Grade -Name 'configuration' -Default ''), [int](Get-JsonProperty -Object $Grade -Name 'assertion_index' -Default -1))
}

function Test-GradeEvidenceReference {
    param(
        [Parameter(Mandatory = $true)][object]$Grade,
        [Parameter(Mandatory = $true)][object]$Expected,
        [Parameter(Mandatory = $true)][object]$Canonical
    )

    $domain = [string](Get-JsonProperty -Object $Grade -Name 'evidence_domain' -Default '')
    if ($domain -ne [string]$Expected.evidence_domain) { throw "grade '$((Get-GradeKey -Grade $Grade))' evidence_domain does not match the assertion." }
    $refs = @(Get-JsonProperty -Object $Grade -Name 'evidence_refs' -Default @())
    if ($refs.Count -eq 0) { throw "grade '$((Get-GradeKey -Grade $Grade))' must declare evidence_refs." }
    foreach ($ref in $refs) {
        $refDomain = [string](Get-JsonProperty -Object $ref -Name 'domain' -Default $domain)
        if ($refDomain -ne $domain) { throw "grade '$((Get-GradeKey -Grade $Grade))' has a mismatched evidence ref domain." }
        $artifact = [string](Get-JsonProperty -Object $ref -Name 'artifact' -Default '')
        if ([string]::IsNullOrWhiteSpace($artifact)) { throw "grade '$((Get-GradeKey -Grade $Grade))' has an empty evidence artifact ref." }
        if ($domain -eq 'output') {
            if ($artifact -ne [string]$Expected.record.ResultRelative) { throw 'output evidence must cite this arm canonical result only.' }
            $line = [int](Get-JsonProperty -Object $ref -Name 'start_line' -Default 0)
            $endLine = [int](Get-JsonProperty -Object $ref -Name 'end_line' -Default $line)
            $lines = @(Get-ArmOutputLines -Output ([string]$Canonical.output))
            if ($line -lt 1 -or $endLine -lt $line -or $endLine -gt $lines.Count) { throw 'output evidence line range is outside the frozen output.' }
            $quote = [string](Get-JsonProperty -Object $ref -Name 'quote' -Default '')
            if (-not [string]::IsNullOrWhiteSpace($quote)) {
                $span = [string]::Join("`n", @($lines[($line - 1)..($endLine - 1)]))
                if (-not $span.Contains($quote, [StringComparison]::Ordinal)) { throw 'output evidence quote is absent from the referenced frozen output lines.' }
            }
        } elseif ($domain -eq 'validator') {
            $rule = [string](Get-JsonProperty -Object $ref -Name 'rule' -Default '')
            if ($rule -ne [string]$Expected.validator) { throw 'validator evidence must cite the assertion validator rule.' }
        } elseif ($domain -eq 'transcript') {
            if ($artifact -eq [string]$Expected.record.ResultRelative) { throw 'transcript evidence must not cite final output prose.' }
            $allowed = @(Get-JsonProperty -Object $Canonical -Name 'output_files' -Default @())
            if ($allowed -notcontains $artifact -and $artifact -ne [string]$Canonical.execution_result_file) { throw 'transcript evidence must cite a frozen transcript/artifact for the same arm.' }
        }
    }
    return $true
}

function New-RootGradingDocument {
    param(
        [Parameter(Mandatory = $true)][object[]]$Grades,
        [object]$Metadata = $null
    )

    $ordered = @($Grades | Sort-Object @{ Expression = { [int](Get-JsonProperty -Object $_ -Name 'eval_id' -Default 0) } }, @{ Expression = { [string](Get-JsonProperty -Object $_ -Name 'configuration' -Default '') } }, @{ Expression = { [int](Get-JsonProperty -Object $_ -Name 'assertion_index' -Default 0) } })
    $document = [ordered]@{
        schema = (Get-RunnerSchemaNames).Grading
        grading = @($ordered)
    }
    if ($null -ne $Metadata) { $document.metadata = $Metadata }
    return $document
}

function Get-GradingMergeHash {
    param([Parameter(Mandatory = $true)][object]$Document)

    return Get-JsonFingerprint -Object $Document
}

function Get-Phase2StateHashForFreeze {
    param([Parameter(Mandatory = $true)][object]$State)

    return Get-JsonFingerprint -Object (Get-JsonWithoutProperty -Object $State -PropertyName 'grading_freeze')
}

function New-GradingFreezeDocument {
    param(
        [Parameter(Mandatory = $true)][string]$IterationDirectory,
        [Parameter(Mandatory = $true)][object]$Manifest,
        [Parameter(Mandatory = $true)][object]$State,
        [Parameter(Mandatory = $true)][object[]]$Grades,
        [object]$Metadata = $null
    )

    $analyzer = Resolve-AnalyzerProfile -IterationDirectory $IterationDirectory -Manifest $Manifest
    $graderPath = Get-GraderContractPath -IterationDirectory $IterationDirectory
    $expected = @(Get-ExpectedGradeRecords -IterationDirectory $IterationDirectory -Manifest $Manifest)
    $root = New-RootGradingDocument -Grades $Grades -Metadata $Metadata
    $validatorPaths = @(Get-JsonProperty -Object $State -Name 'validator_results' -Default @())
    $analyzerResults = @(Get-JsonProperty -Object $State -Name 'analyzer_results' -Default @())

    return [ordered]@{
        schema = $script:GradingFreezeSchema
        analyzer_profile = [ordered]@{ path = [string]$analyzer.RelativePath; sha256 = [string]$analyzer.Hash }
        analyzer_profile_sha256 = [string]$analyzer.Hash
        grader_contract = [ordered]@{ path = 'tools/skill-creator/agents/grader.md'; sha256 = Get-Sha256HexFromFile -Path $graderPath }
        assertions_sha256 = Get-JsonFingerprint -Object @($expected | ForEach-Object {
            [ordered]@{
                eval_id = [int]$_.eval_id
                eval_name = [string]$_.eval_name
                configuration = [string]$_.configuration
                assertion_index = [int]$_.assertion_index
                assertion = [string]$_.assertion
                evidence_domain = [string]$_.evidence_domain
                validator = Get-JsonProperty -Object $_ -Name 'validator' -Default $null
            }
        })
        validator_results = @($validatorPaths)
        analyzer_results = @($analyzerResults)
        phase2_state_sha256 = Get-Phase2StateHashForFreeze -State $State
        expected_grade_count = $expected.Count
        grading_sha256 = Get-GradingMergeHash -Document $root
        generated_utc = (Format-UtcTimestamp -Value ([DateTime]::UtcNow))
    }
}

function Assert-GradingFreeze {
    param(
        [Parameter(Mandatory = $true)][string]$IterationDirectory,
        [string]$GradingPath = 'grading.json'
    )

    $iteration = (Resolve-Path -LiteralPath $IterationDirectory -ErrorAction Stop).Path
    $manifest = Read-RunnerJson -Path (Join-Path $iteration 'manifest.json')
    $statePath = Join-Path $iteration 'phase2-state.json'
    $freezePath = Join-Path $iteration 'grading-freeze.json'
    if (-not (Test-Path -LiteralPath $freezePath -PathType Leaf)) { throw 'grading-freeze.json is missing; handcrafted grading.json cannot finalize.' }
    if (-not (Test-Path -LiteralPath $statePath -PathType Leaf)) { throw 'Phase 2 state is missing.' }
    $state = Read-RunnerJson -Path $statePath
    $freeze = Read-RunnerJson -Path $freezePath
    if ([string](Get-JsonProperty -Object $state -Name 'schema' -Default '') -ne $script:Phase2Schema) { throw 'phase2-state.json has an unsupported schema.' }
    if ([string](Get-JsonProperty -Object $freeze -Name 'schema' -Default '') -ne $script:GradingFreezeSchema) { throw 'grading-freeze.json has an unsupported schema.' }
    if ([string](Get-JsonProperty -Object $state -Name 'status' -Default '') -ne 'completed') { throw 'phase2-state.json is not completed.' }
    if (@(Get-JsonProperty -Object $state -Name 'pending' -Default @()).Count -ne 0) { throw 'phase2-state.json still has pending analyzer workers.' }
    if (@(Get-JsonPropertyNames -Object (Get-JsonProperty -Object $state -Name 'active' -Default ([ordered]@{}))).Count -ne 0) { throw 'phase2-state.json still has active analyzer workers.' }
    $expectedWorkers = @(Get-JsonProperty -Object $state -Name 'expected_worker_ids' -Default @())
    $completedWorkers = Get-JsonProperty -Object $state -Name 'completed' -Default ([ordered]@{})
    if (@(Get-JsonPropertyNames -Object $completedWorkers).Count -ne $expectedWorkers.Count) { throw 'phase2-state.json terminal analyzer worker count does not match expected_worker_ids.' }
    $analyzerResultRefs = @(Get-JsonProperty -Object $state -Name 'analyzer_results' -Default @())
    if ($analyzerResultRefs.Count -ne $expectedWorkers.Count) { throw 'phase2-state.json analyzer result count does not match expected semantic worker count.' }
    $analyzer = Resolve-AnalyzerProfile -IterationDirectory $iteration -Manifest $manifest
    if ([string](Get-JsonProperty -Object $freeze -Name 'analyzer_profile_sha256' -Default '') -ne [string]$analyzer.Hash) { throw 'Analyzer profile changed after grading.' }
    if ([string](Get-JsonProperty -Object (Get-JsonProperty -Object $freeze -Name 'analyzer_profile' -Default $null) -Name 'sha256' -Default '') -ne [string]$analyzer.Hash) { throw 'grading-freeze.json analyzer_profile hash mismatch.' }
    $graderPath = Get-GraderContractPath -IterationDirectory $iteration
    if ([string](Get-JsonProperty -Object (Get-JsonProperty -Object $freeze -Name 'grader_contract' -Default $null) -Name 'sha256' -Default '') -ne (Get-Sha256HexFromFile -Path $graderPath)) { throw 'Packaged grader contract changed after Phase 2 freeze.' }
    $stateHash = Get-Phase2StateHashForFreeze -State $state
    if ([string](Get-JsonProperty -Object $freeze -Name 'phase2_state_sha256' -Default '') -ne $stateHash) { throw 'phase2-state.json changed after Phase 2 freeze.' }

    $gradingFullPath = Resolve-ManifestDeclaredPath -IterationDirectory $iteration -RelativePath $GradingPath -FieldName 'grading path' -Kind File -RequireExists
    $grading = Read-RunnerJson -Path $gradingFullPath
    if ([string](Get-JsonProperty -Object $freeze -Name 'grading_sha256' -Default '') -ne (Get-GradingMergeHash -Document $grading)) { throw 'Root grading.json was changed after deterministic Phase 2 merge.' }

    foreach ($validator in @(Get-JsonProperty -Object $freeze -Name 'validator_results' -Default @())) {
        $path = Resolve-ManifestDeclaredPath -IterationDirectory $iteration -RelativePath ([string]$validator.path) -FieldName 'validator result' -Kind File -RequireExists
        if ([string]$validator.sha256 -ne (Get-Sha256HexFromFile -Path $path)) { throw "Validator result '$($validator.path)' changed after Phase 2 freeze." }
    }
    $workerSessions = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
    foreach ($analyzerResult in @(Get-JsonProperty -Object $freeze -Name 'analyzer_results' -Default @())) {
        $path = Resolve-ManifestDeclaredPath -IterationDirectory $iteration -RelativePath ([string]$analyzerResult.path) -FieldName 'analyzer result' -Kind File -RequireExists
        if ([string]$analyzerResult.sha256 -ne (Get-Sha256HexFromFile -Path $path)) { throw "Analyzer result '$($analyzerResult.path)' changed after Phase 2 freeze." }
        $result = Read-RunnerJson -Path $path
        if ([string](Get-JsonProperty -Object $result -Name 'analyzer_profile_sha256' -Default '') -ne [string]$analyzer.Hash) { throw "Analyzer result '$($analyzerResult.path)' uses a different analyzer profile." }
        if ([string](Get-JsonProperty -Object $result -Name 'observed_model' -Default '') -ne [string]$analyzer.Model) { throw "Analyzer result '$($analyzerResult.path)' observed the wrong model." }
        if ([int](Get-JsonProperty -Object $result -Name 'attempt_count' -Default 0) -ne 1) { throw "Analyzer worker '$($analyzerResult.path)' was retried." }
        $sessionId = [string](Get-JsonProperty -Object $result -Name 'session_id' -Default '')
        if ([string]::IsNullOrWhiteSpace($sessionId) -or -not $workerSessions.Add($sessionId)) { throw 'Analyzer worker/session identity was reused.' }
        $rawPathValue = [string](Get-JsonProperty -Object $result -Name 'raw_execution_result' -Default '')
        $rawPath = Resolve-ManifestDeclaredPath -IterationDirectory $iteration -RelativePath $rawPathValue -FieldName 'analyzer raw execution result' -Kind File -RequireExists
        if ([string](Get-JsonProperty -Object $result -Name 'raw_execution_result_sha256' -Default '') -ne (Get-Sha256HexFromFile -Path $rawPath)) { throw "Analyzer raw transcript/evidence '$rawPathValue' changed after Phase 2 freeze." }
        $fragmentPathValue = [string](Get-JsonProperty -Object $result -Name 'grading_fragment' -Default '')
        $fragmentPath = Resolve-ManifestDeclaredPath -IterationDirectory $iteration -RelativePath $fragmentPathValue -FieldName 'analyzer grading fragment' -Kind File -RequireExists
        if ([string](Get-JsonProperty -Object $result -Name 'grading_fragment_sha256' -Default '') -ne (Get-Sha256HexFromFile -Path $fragmentPath)) { throw "Analyzer grading fragment '$fragmentPathValue' changed after Phase 2 freeze." }
    }

    return [pscustomobject]@{ Path = $freezePath; Freeze = $freeze; State = $state; Manifest = $manifest; Analyzer = $analyzer; Grading = $grading }
}
