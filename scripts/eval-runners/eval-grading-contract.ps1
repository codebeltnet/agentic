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
if (-not (Get-Command Normalize-EvalAssertion -ErrorAction SilentlyContinue)) {
    . (Join-Path $PSScriptRoot 'phase2-grading.ps1')
}

function Get-EvalGradingSkeleton {
    return [ordered]@{
        schema = (Get-RunnerSchemaNames).Grading
        grading = @()
    }
}

function Get-EvalGradingEntryKey {
    param([Parameter(Mandatory = $true)][object]$Entry)

    return "$(Get-JsonProperty -Object $Entry -Name 'eval_id' -Default 0)|$(Get-JsonProperty -Object $Entry -Name 'configuration' -Default '')|$(Get-JsonProperty -Object $Entry -Name 'assertion_index' -Default -1)"
}

function Get-EvalMetadataAssertions {
    param([Parameter(Mandatory = $true)][object]$Record)

    return @(Get-EvalMetadataAssertionObjects -Record $Record)
}

function Assert-EvalGradingEntryShape {
    param([Parameter(Mandatory = $true)][object]$Entry)

    $allowed = @('eval_id', 'eval_name', 'configuration', 'assertion_index', 'assertion', 'passed', 'evidence', 'evidence_domain', 'evidence_refs', 'reason', 'source')
    foreach ($name in @(Get-JsonPropertyNames -Object $Entry)) {
        if ($allowed -notcontains $name) { throw "grading.json entry contains unsupported field '$name'." }
    }
    foreach ($name in @('eval_id', 'eval_name', 'configuration', 'assertion_index', 'assertion', 'passed', 'evidence', 'evidence_domain', 'evidence_refs', 'reason')) {
        if (-not (Test-JsonProperty -Object $Entry -Name $name)) { throw "grading.json entry is missing '$name'." }
    }
    $evalId = 0
    try { $evalId = [int]$Entry.eval_id } catch { throw 'grading.json eval_id must be an integer.' }
    if ($evalId -lt 1) { throw 'grading.json eval_id must be positive.' }
    $index = 0
    try { $index = [int]$Entry.assertion_index } catch { throw 'grading.json assertion_index must be an integer.' }
    if ($index -lt 0 -or [double]$Entry.assertion_index -ne $index) { throw 'grading.json assertion_index must be a non-negative integer.' }
    if ([string]$Entry.configuration -notin @('with_skill', 'without_skill')) { throw "grading.json configuration '$($Entry.configuration)' is unsupported." }
    if ([string]::IsNullOrWhiteSpace([string]$Entry.eval_name) -or [string]::IsNullOrWhiteSpace([string]$Entry.assertion)) { throw 'grading.json eval_name and assertion must be non-empty strings.' }
    if ($Entry.passed -isnot [bool]) { throw 'grading.json passed must be a boolean; incomplete grading is not finalizable.' }
    if ($Entry.evidence -isnot [string]) { throw 'grading.json evidence must be a string.' }
    if ([string]::IsNullOrWhiteSpace($Entry.evidence)) { throw 'grading.json evidence must be non-empty.' }
    if ([string]$Entry.evidence_domain -notin @('output', 'transcript', 'validator')) { throw "grading.json evidence_domain '$($Entry.evidence_domain)' is unsupported." }
    $refs = @(Get-JsonProperty -Object $Entry -Name 'evidence_refs' -Default @())
    if ($refs.Count -eq 0) { throw 'grading.json evidence_refs must be a non-empty array.' }
    if ([string]::IsNullOrWhiteSpace([string]$Entry.reason)) { throw 'grading.json reason must be non-empty.' }
    if ((Test-JsonProperty -Object $Entry -Name 'source') -and [string]$Entry.source -notin @('analyzer', 'validator')) {
        throw "grading.json source '$($Entry.source)' is unsupported."
    }
}

# Reject generic, templated, or tautological PASS reasons. A reason must explain HOW the cited observation establishes
# the specific assertion, not restate that the assertion passed or that the output was "evaluated". Iteration 9 passed
# 76 assertions with reasons equivalent to "Assertion evaluated against output"; that class must fail closed.
function Test-GenericGradingReason {
    param([string]$Reason, [string]$Assertion)
    $normalized = ([regex]::Replace([string]$Reason, '\s+', ' ')).Trim().TrimEnd('.', '!').Trim()
    if ([string]::IsNullOrWhiteSpace($normalized)) { return $true }
    if ($normalized -eq (([regex]::Replace([string]$Assertion, '\s+', ' ')).Trim().TrimEnd('.', '!').Trim())) { return $true }
    $genericPatterns = @(
        '^(?i)eval(?:uation)? completed(?: with output)?$',
        '^(?i)(?:the )?(?:assertion|requirement|expectation|condition|criteri(?:on|a))(?: is| was| has been)?(?: fully| clearly)? (?:met|satisfied|passed|verified|confirmed|evaluated|true|correct|valid|present|fulfilled|checked|held|holds|passes)$',
        '(?i)evaluated against (?:the )?(?:output|transcript|response|result|evidence|assertion)',
        '(?i)(?:output|response|transcript|result) (?:was |is )?(?:evaluated|matches|meets|satisfies|supports|confirms|contains) (?:the )?(?:assertion|requirement|expectation)',
        '^(?i)(?:passed|verified|confirmed|as expected|done|looks good|correct|ok|success(?:ful)?|valid|complete)$',
        '^(?i)(?:this )?(?:matches|meets|satisfies|establishes|proves|confirms)(?: the)?(?: assertion| requirement| expectation)?$'
    )
    foreach ($pattern in $genericPatterns) { if ($normalized -match $pattern) { return $true } }
    return $false
}

function Assert-EvalPassEvidence {
    param([object]$Entry, [object]$Canonical, [object]$Expected)

    $transcriptArtifacts = $null
    if ([string](Get-JsonProperty -Object $Entry -Name 'evidence_domain' -Default '') -eq 'transcript') {
        $transcriptArtifacts = @(Get-CanonicalTranscriptArtifacts -Record $Expected.record -Canonical $Canonical)
    }
    [void](Test-GradeEvidenceReference -Grade $Entry -Expected $Expected -Canonical $Canonical -TranscriptArtifacts $transcriptArtifacts)
    if (-not $Entry.passed) { return }
    $reason = [string](Get-JsonProperty -Object $Entry -Name 'reason' -Default '')
    if (Test-GenericGradingReason -Reason $reason -Assertion ([string]$Entry.assertion)) {
        throw 'PASS evidence must explain how the cited observation establishes this assertion, not restate that it passed or was evaluated.'
    }
}

function Assert-EvalGradingContract {
    param(
        [Parameter(Mandatory = $true)][string]$IterationDirectory,
        [string]$GradingPath = 'grading.json'
    )

    $iteration = (Resolve-Path -LiteralPath $IterationDirectory -ErrorAction Stop).Path
    Assert-SafeRelativePath -RelativePath $GradingPath -FieldName 'grading path'
    $gradingFullPath = Resolve-ContainedPath -BasePath $iteration -RelativePath $GradingPath -FieldName 'grading path' -Kind File
    if (-not (Test-Path -LiteralPath $gradingFullPath -PathType Leaf)) {
        throw "Grading is incomplete: grading-only artifact '$GradingPath' is missing."
    }

    $gradingDocument = Read-RunnerJson -Path $gradingFullPath
    $schemas = Get-RunnerSchemaNames
    if ([string](Get-JsonProperty -Object $gradingDocument -Name 'schema' -Default '') -ne $schemas.Grading) {
        throw "grading.json must declare '$($schemas.Grading)'."
    }
    $topLevelAllowed = @('schema', 'grading', 'metadata')
    foreach ($name in @(Get-JsonPropertyNames -Object $gradingDocument)) {
        if ($topLevelAllowed -notcontains $name) { throw "grading.json contains unsupported field '$name'; the Grader may author only grading entries." }
    }
    if (-not (Test-JsonProperty -Object $gradingDocument -Name 'grading')) {
        throw "grading.json is missing 'grading'."
    }
    $submittedValue = Get-JsonProperty -Object $gradingDocument -Name 'grading' -Default $null
    if ($null -eq $submittedValue -or $submittedValue -is [string] -or -not ($submittedValue -is [System.Collections.IEnumerable])) {
        throw 'grading.json grading must be an array.'
    }
    $submitted = @($submittedValue)
    foreach ($entry in $submitted) {
        Assert-EvalGradingEntryShape -Entry $entry
    }

    $freezeValidation = Assert-ExecutionFreeze -IterationDirectory $iteration -RequireOrchestrationState
    $manifest = $freezeValidation.Manifest
    $declaredGradingPath = [string](Get-JsonProperty -Object $manifest -Name 'grading' -Default '')
    if ([string]::IsNullOrWhiteSpace($declaredGradingPath) -or $declaredGradingPath -ne $GradingPath) {
        throw "grading path '$GradingPath' does not match manifest.grading '$declaredGradingPath'."
    }

    $records = @(Get-ManifestRunRecords -IterationDirectory $iteration -Manifest $manifest | Sort-Object EvalId, Configuration)
    $expected = @{}
    $canonicalByKey = @{}
    foreach ($record in $records) {
        $assertions = @(Get-EvalMetadataAssertions -Record $record)
        $canonical = Read-RunnerJson -Path $record.ResultPath
        if ([int]$canonical.eval_id -ne [int]$record.EvalId -or [string]$canonical.eval_name -ne [string]$record.EvalName -or [string]$canonical.configuration -ne [string]$record.Configuration) {
            throw "Canonical result '$($record.ResultRelative)' does not match its exact manifest identity."
        }
        if ([string]$canonical.execution_status -ne 'completed') {
            throw "Grading is incomplete: '$($record.EvalName)/$($record.Configuration)' is not a completed execution."
        }
        $canonicalByKey["$($record.EvalId)|$($record.Configuration)"] = $canonical
        for ($index = 0; $index -lt $assertions.Count; $index++) {
            $assertion = $assertions[$index]
            $key = "$($record.EvalId)|$($record.Configuration)|$index"
            $expected[$key] = [ordered]@{
                eval_id = [int]$record.EvalId
                eval_name = [string]$record.EvalName
                configuration = [string]$record.Configuration
                assertion_index = $index
                assertion = [string]$assertion.assertion
                evidence_domain = [string]$assertion.evidence_domain
                validator = Get-JsonProperty -Object $assertion -Name 'validator' -Default $null
                record = $record
            }
        }
    }
    if ($submitted.Count -ne $expected.Count) {
        throw "grading.json assertion cardinality $($submitted.Count) does not match the required $($expected.Count)."
    }

    $validated = @{}
    $passEvidence = @{}
    foreach ($entry in $submitted) {
        Assert-EvalGradingEntryShape -Entry $entry
        $key = Get-EvalGradingEntryKey -Entry $entry
        if (-not $expected.ContainsKey($key)) { throw "grading.json identifies an unknown eval/configuration/assertion '$key'." }
        if ($validated.ContainsKey($key)) { throw "grading.json contains duplicate grading entry '$key'." }
        $target = $expected[$key]
        if ([string]$entry.eval_name -ne [string]$target.eval_name -or [string]$entry.assertion -ne [string]$target.assertion -or [string]$entry.evidence_domain -ne [string]$target.evidence_domain) {
            throw "grading.json assertion identity '$key' does not match eval-metadata.json exactly."
        }
        $armKey = "$($entry.eval_id)|$($entry.configuration)"
        $record = @($records | Where-Object { $_.EvalId -eq $entry.eval_id -and $_.Configuration -eq $entry.configuration })[0]
        Assert-EvalPassEvidence -Entry $entry -Canonical $canonicalByKey[$armKey] -Expected $target
        if ($entry.passed) {
            $evidenceKey = $armKey + '|' + ([regex]::Replace($entry.evidence.Trim(), '\s+', ' ')).ToLowerInvariant()
            if ($passEvidence.ContainsKey($evidenceKey)) { throw 'Repeated PASS evidence across assertions is not assertion-specific.' }
            $passEvidence[$evidenceKey] = $true
        }
        $validated[$key] = $entry
    }
    foreach ($key in $expected.Keys) {
        if (-not $validated.ContainsKey($key)) { throw "grading.json is missing required grading entry '$key'." }
    }

    return [pscustomobject]@{
        IterationDirectory = $iteration
        GradingPath = $GradingPath
        GradingFullPath = $gradingFullPath
        GradingDocument = $gradingDocument
        FreezeValidation = $freezeValidation
        Manifest = $manifest
        Records = @($records)
        Expected = $expected
        Validated = $validated
        CanonicalByKey = $canonicalByKey
        GradedAssertions = $expected.Count
    }
}
