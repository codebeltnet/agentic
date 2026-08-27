<#!
.SYNOPSIS
    Applies the external Grader's grading-only artifact to canonical results.

.DESCRIPTION
    The Grader is allowed to author only package-root grading.json. This
    deterministic command validates its exact assertion identities, verifies
    the immutable Phase 1 freeze, and changes only canonical grading fields.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$IterationDirectory,
    [string]$GradingPath = 'grading.json'
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

. (Join-Path $PSScriptRoot 'runner-common.ps1')
. (Join-Path $PSScriptRoot 'manifest-paths.ps1')
. (Join-Path $PSScriptRoot 'execution-freeze.ps1')

$utf8NoBom = [System.Text.UTF8Encoding]::new($false)

function Write-GradingResultJson {
    param([Parameter(Mandatory = $true)][string]$Path, [Parameter(Mandatory = $true)][object]$Value)

    [System.IO.File]::WriteAllText($Path, (($Value | ConvertTo-Json -Depth 100) + [Environment]::NewLine), $utf8NoBom)
}

function Get-GradingEntryKey {
    param([Parameter(Mandatory = $true)][object]$Entry)

    return "$(Get-JsonProperty -Object $Entry -Name 'eval_id' -Default 0)|$(Get-JsonProperty -Object $Entry -Name 'configuration' -Default '')|$(Get-JsonProperty -Object $Entry -Name 'assertion_index' -Default -1)"
}

function Get-MetadataAssertions {
    param([Parameter(Mandatory = $true)][object]$Record)

    $metadata = Read-RunnerJson -Path $Record.MetadataPath
    $assertions = @(Get-JsonProperty -Object $metadata -Name 'assertions' -Default @())
    if ($assertions.Count -eq 0) { throw "Metadata for '$($Record.EvalName)' declares no assertions." }
    return @($assertions | ForEach-Object { [string]$_ })
}

function Assert-GradingEntryShape {
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

try {
    $iteration = (Resolve-Path -LiteralPath $IterationDirectory -ErrorAction Stop).Path
    Assert-SafeRelativePath -RelativePath $GradingPath -FieldName 'grading path'
    $gradingFullPath = Resolve-ContainedPath -BasePath $iteration -RelativePath $GradingPath -FieldName 'grading path' -Kind File
    if (-not (Test-Path -LiteralPath $gradingFullPath -PathType Leaf)) {
        throw "Grading is incomplete: grading-only artifact '$GradingPath' is missing."
    }

    $freezeValidation = Assert-ExecutionFreeze -IterationDirectory $iteration -RequireOrchestrationState
    $manifest = $freezeValidation.Manifest
    $declaredGradingPath = [string](Get-JsonProperty -Object $manifest -Name 'grading' -Default '')
    if ([string]::IsNullOrWhiteSpace($declaredGradingPath) -or $declaredGradingPath -ne $GradingPath) {
        throw "grading path '$GradingPath' does not match manifest.grading '$declaredGradingPath'."
    }
    $bridgeScript = Join-Path $PSScriptRoot 'bridge-manifest-results.ps1'
    if (-not (Test-Path -LiteralPath $bridgeScript -PathType Leaf)) {
        throw "Package-local manifest bridge is missing at '$bridgeScript'."
    }
    $bridgeOutput = & pwsh -NoProfile -File $bridgeScript -IterationDirectory $iteration -RequireComplete 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "Canonical result validation failed before grading application: $([string]::Join(' ', @($bridgeOutput | ForEach-Object { [string]$_ })))"
    }

    $records = @(Get-ManifestRunRecords -IterationDirectory $iteration -Manifest $manifest | Sort-Object EvalId, Configuration)
    $gradingDocument = Read-RunnerJson -Path $gradingFullPath
    $schemas = Get-RunnerSchemaNames
    if ([string](Get-JsonProperty -Object $gradingDocument -Name 'schema' -Default '') -ne $schemas.Grading) {
        throw "grading.json must declare '$($schemas.Grading)'."
    }
    $topLevelAllowed = @('schema', 'grading')
    foreach ($name in @(Get-JsonPropertyNames -Object $gradingDocument)) {
        if ($topLevelAllowed -notcontains $name) { throw "grading.json contains unsupported field '$name'; the Grader may author only grading entries." }
    }
    $submitted = @(Get-JsonProperty -Object $gradingDocument -Name 'grading' -Default @())
    $expected = @{}
    $canonicalByKey = @{}
    foreach ($record in $records) {
        $assertions = @(Get-MetadataAssertions -Record $record)
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
        Assert-GradingEntryShape -Entry $entry
        $key = Get-GradingEntryKey -Entry $entry
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

    $updates = [System.Collections.Generic.List[object]]::new()
    foreach ($record in $records) {
        $canonical = $canonicalByKey["$($record.EvalId)|$($record.Configuration)"]
        if (-not (Test-JsonProperty -Object $canonical -Name 'grading')) { throw "Canonical result '$($record.ResultRelative)' is missing its grading array." }
        $newGrading = [System.Collections.Generic.List[object]]::new()
        $assertions = @(Get-MetadataAssertions -Record $record)
        for ($index = 0; $index -lt $assertions.Count; $index++) {
            $entry = $validated["$($record.EvalId)|$($record.Configuration)|$index"]
            $newGrading.Add([ordered]@{ text = [string]$entry.assertion; passed = [bool]$entry.passed; evidence = [string]$entry.evidence })
        }
        $beforeNonGrading = Get-JsonFingerprint -Object (Get-JsonWithoutProperty -Object $canonical -PropertyName 'grading')
        # Keep the parsed canonical values as-is. ConvertFrom-Json reparses
        # ISO timestamp strings into DateTime values and ConvertTo-Json then
        # changes their lexical precision (for example .650Z -> .65Z), which
        # would make a grading-only update look like non-grading tampering.
        $candidate = [ordered]@{}
        foreach ($property in @($canonical.PSObject.Properties)) {
            $candidate[[string]$property.Name] = $property.Value
        }
        $candidate.grading = @($newGrading.ToArray())
        $afterNonGrading = Get-JsonFingerprint -Object (Get-JsonWithoutProperty -Object $candidate -PropertyName 'grading')
        if ($beforeNonGrading -ne $afterNonGrading) {
            throw "Canonical non-grading field changed while applying '$($record.ResultRelative)'."
        }
        $updates.Add([pscustomobject]@{ Path = $record.ResultPath; Before = $canonical; Candidate = $candidate; Changed = (Get-JsonFingerprint -Object $canonical) -ne (Get-JsonFingerprint -Object $candidate) })
    }

    foreach ($update in $updates) {
        if ($update.Changed) { Write-GradingResultJson -Path $update.Path -Value $update.Candidate }
    }
    [void](Assert-ExecutionFreeze -IterationDirectory $iteration -RequireOrchestrationState)
    foreach ($update in $updates) {
        $after = Read-RunnerJson -Path $update.Path
        $beforeFingerprint = Get-JsonFingerprint -Object (Get-JsonWithoutProperty -Object $update.Before -PropertyName 'grading')
        $afterFingerprint = Get-JsonFingerprint -Object (Get-JsonWithoutProperty -Object $after -PropertyName 'grading')
        if ($beforeFingerprint -ne $afterFingerprint) { throw "Canonical non-grading field changed after applying '$($update.Path)'." }
    }

    Write-RunnerJson -Value ([ordered]@{
        schema = 'codebeltnet/agentic/eval-grading-application/1'
        status = 'applied'
        grading_file = $gradingFullPath
        canonical_results = $updates.Count
        graded_assertions = $expected.Count
        changed_results = @($updates | Where-Object { $_.Changed }).Count
        execution_freeze = $freezeValidation.Path
    }) -AsOutput
} catch {
    [Console]::Error.WriteLine($_.Exception.Message)
    exit 2
}
