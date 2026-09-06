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

    $metadata = Read-RunnerJson -Path $Record.MetadataPath
    $assertions = @(Get-JsonProperty -Object $metadata -Name 'assertions' -Default @())
    if ($assertions.Count -eq 0) { throw "Metadata for '$($Record.EvalName)' declares no assertions." }
    return @($assertions | ForEach-Object { [string]$_ })
}

function Assert-EvalGradingEntryShape {
    param([Parameter(Mandatory = $true)][object]$Entry)

    $allowed = @('eval_id', 'eval_name', 'configuration', 'assertion_index', 'assertion', 'passed', 'evidence')
    foreach ($name in @(Get-JsonPropertyNames -Object $Entry)) {
        if ($allowed -notcontains $name) { throw "grading.json entry contains unsupported field '$name'." }
    }
    foreach ($name in $allowed) {
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
    $topLevelAllowed = @('schema', 'grading')
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
            $key = "$($record.EvalId)|$($record.Configuration)|$index"
            $expected[$key] = [ordered]@{
                eval_id = [int]$record.EvalId
                eval_name = [string]$record.EvalName
                configuration = [string]$record.Configuration
                assertion_index = $index
                assertion = [string]$assertions[$index]
            }
        }
    }
    if ($submitted.Count -ne $expected.Count) {
        throw "grading.json assertion cardinality $($submitted.Count) does not match the required $($expected.Count)."
    }

    $validated = @{}
    foreach ($entry in $submitted) {
        Assert-EvalGradingEntryShape -Entry $entry
        $key = Get-EvalGradingEntryKey -Entry $entry
        if (-not $expected.ContainsKey($key)) { throw "grading.json identifies an unknown eval/configuration/assertion '$key'." }
        if ($validated.ContainsKey($key)) { throw "grading.json contains duplicate grading entry '$key'." }
        $target = $expected[$key]
        if ([string]$entry.eval_name -ne [string]$target.eval_name -or [string]$entry.assertion -ne [string]$target.assertion) {
            throw "grading.json assertion identity '$key' does not match eval-metadata.json exactly."
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
