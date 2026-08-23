Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'runner-common.ps1')

function Resolve-ManifestDeclaredPath {
    param(
        [Parameter(Mandatory = $true)][string]$IterationDirectory,
        [Parameter(Mandatory = $true)][string]$RelativePath,
        [Parameter(Mandatory = $true)][string]$FieldName,
        [ValidateSet('Any', 'File', 'Directory')][string]$Kind = 'Any',
        [switch]$RequireExists
    )

    Assert-SafeRelativePath -RelativePath $RelativePath -FieldName $FieldName
    $resolvedIteration = (Resolve-Path -LiteralPath $IterationDirectory -ErrorAction Stop).Path
    $candidate = [System.IO.Path]::GetFullPath((Join-Path $resolvedIteration ($RelativePath -replace '/', [System.IO.Path]::DirectorySeparatorChar)))
    if (-not (Test-PathInside -BasePath $resolvedIteration -CandidatePath $candidate)) {
        throw "$FieldName resolves outside the prepared iteration package."
    }

    $exists = switch ($Kind) {
        'File' { Test-Path -LiteralPath $candidate -PathType Leaf }
        'Directory' { Test-Path -LiteralPath $candidate -PathType Container }
        default { Test-Path -LiteralPath $candidate }
    }
    if ($RequireExists -and -not $exists) {
        throw "$FieldName '$RelativePath' does not exist in the prepared iteration package."
    }

    if ($exists) {
        $resolvedCandidate = (Resolve-Path -LiteralPath $candidate -ErrorAction Stop).Path
        if (-not (Test-PathInside -BasePath $resolvedIteration -CandidatePath $resolvedCandidate)) {
            throw "$FieldName resolves through a link outside the prepared iteration package."
        }
        return $resolvedCandidate
    }

    return $candidate
}

function Get-ManifestConfigurations {
    param([Parameter(Mandatory = $true)][object]$Manifest)

    $configurations = @(Get-JsonProperty -Object $Manifest -Name 'configurations' -Default @())
    if ($configurations.Count -eq 0) {
        throw 'manifest.json must declare at least one configuration arm.'
    }

    $seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $result = [System.Collections.Generic.List[string]]::new()
    foreach ($value in $configurations) {
        $configuration = [string]$value
        if ([string]::IsNullOrWhiteSpace($configuration)) {
            throw 'manifest.json contains an empty configuration arm.'
        }
        if (-not $seen.Add($configuration)) {
            throw "manifest.json declares configuration arm '$configuration' more than once."
        }
        $result.Add($configuration)
    }

    return @($result)
}

function Get-ManifestRunRecords {
    param(
        [Parameter(Mandatory = $true)][string]$IterationDirectory,
        [Parameter(Mandatory = $true)][object]$Manifest
    )

    $records = [System.Collections.Generic.List[object]]::new()
    $seenPaths = @{}
    $configurations = @(Get-ManifestConfigurations -Manifest $Manifest)
    $evals = @(Get-JsonProperty -Object $Manifest -Name 'evals' -Default @())
    if ($evals.Count -eq 0) {
        throw 'manifest.json must declare at least one eval case.'
    }

    foreach ($entry in $evals) {
        $evalName = [string](Get-JsonProperty -Object $entry -Name 'eval_name' -Default '')
        $evalId = [int](Get-JsonProperty -Object $entry -Name 'eval_id' -Default 0)
        $directoryRelative = [string](Get-JsonProperty -Object $entry -Name 'directory' -Default '')
        $metadataRelative = [string](Get-JsonProperty -Object $entry -Name 'metadata' -Default '')
        if ([string]::IsNullOrWhiteSpace($evalName) -or $evalId -lt 1) {
            throw 'Each manifest eval entry must declare a non-empty eval_name and positive eval_id.'
        }

        $evalDirectory = Resolve-ManifestDeclaredPath `
            -IterationDirectory $IterationDirectory `
            -RelativePath $directoryRelative `
            -FieldName "$evalName.directory" `
            -Kind Directory `
            -RequireExists
        $metadataPath = Resolve-ManifestDeclaredPath `
            -IterationDirectory $IterationDirectory `
            -RelativePath $metadataRelative `
            -FieldName "$evalName.metadata" `
            -Kind File `
            -RequireExists
        $runContainer = Get-JsonProperty -Object $entry -Name 'runs' -Default $null
        if ($null -eq $runContainer) {
            throw "$evalName manifest entry must declare runs."
        }

        foreach ($configuration in $configurations) {
            $runEntry = Get-JsonProperty -Object $runContainer -Name $configuration -Default $null
            if ($null -eq $runEntry) {
                throw "$evalName manifest entry is missing runs.$configuration."
            }

            $declaredPaths = [ordered]@{}
            foreach ($field in @('run_manifest', 'execution_result', 'result')) {
                if (-not (Test-JsonProperty -Object $runEntry -Name $field)) {
                    throw "$evalName/$configuration manifest entry must declare '$field'."
                }
                $relative = [string](Get-JsonProperty -Object $runEntry -Name $field -Default '')
                if ([string]::IsNullOrWhiteSpace($relative)) {
                    throw "$evalName/$configuration manifest field '$field' must be non-empty."
                }
                $declaredPaths[$field] = $relative
            }

            $runManifestPath = Resolve-ManifestDeclaredPath `
                -IterationDirectory $IterationDirectory `
                -RelativePath $declaredPaths.run_manifest `
                -FieldName "$evalName/$configuration.run_manifest" `
                -Kind File `
                -RequireExists
            $runManifest = Read-RunnerJson -Path $runManifestPath
            $runEvalId = [int](Get-JsonProperty -Object $runManifest -Name 'evalId' -Default 0)
            $runEvalName = [string](Get-JsonProperty -Object $runManifest -Name 'evalName' -Default '')
            $runMode = [string](Get-JsonProperty -Object $runManifest -Name 'mode' -Default '')
            if ($runEvalId -ne $evalId -or $runEvalName -ne $evalName -or $runMode -ne $configuration) {
                throw "$evalName/$configuration run_manifest '$($declaredPaths.run_manifest)' identifies evalId='$runEvalId', evalName='$runEvalName', mode='$runMode'; it does not match the manifest arm."
            }
            $executionResultPath = Resolve-ManifestDeclaredPath `
                -IterationDirectory $IterationDirectory `
                -RelativePath $declaredPaths.execution_result `
                -FieldName "$evalName/$configuration.execution_result" `
                -Kind File
            $resultPath = Resolve-ManifestDeclaredPath `
                -IterationDirectory $IterationDirectory `
                -RelativePath $declaredPaths.result `
                -FieldName "$evalName/$configuration.result" `
                -Kind File `
                -RequireExists

            $mode = [string](Get-JsonProperty -Object $runEntry -Name 'mode' -Default '')
            if (-not [string]::IsNullOrWhiteSpace($mode) -and $mode -ne $configuration) {
                throw "$evalName/$configuration manifest mode '$mode' does not match its arm key."
            }

            foreach ($path in @(
                    [pscustomobject]@{ Field = 'run_manifest'; FullPath = $runManifestPath }
                    [pscustomobject]@{ Field = 'execution_result'; FullPath = $executionResultPath }
                    [pscustomobject]@{ Field = 'result'; FullPath = $resultPath }
                )) {
                $pathKey = [System.IO.Path]::GetFullPath($path.FullPath)
                if ($seenPaths.ContainsKey($pathKey)) {
                    $previous = $seenPaths[$pathKey]
                    throw "$evalName/$configuration.$($path.Field) duplicates $($previous.EvalName)/$($previous.Configuration).$($previous.Field)."
                }
                $seenPaths[$pathKey] = [pscustomobject]@{
                    EvalName = $evalName
                    Configuration = $configuration
                    Field = $path.Field
                }
            }

            $records.Add([pscustomobject]@{
                EvalId = $evalId
                EvalName = $evalName
                Configuration = $configuration
                EvalDirectory = $evalDirectory
                MetadataPath = $metadataPath
                RunEntry = $runEntry
                RunManifestRelative = $declaredPaths.run_manifest
                ExecutionResultRelative = $declaredPaths.execution_result
                ResultRelative = $declaredPaths.result
                RunManifestPath = $runManifestPath
                ExecutionResultPath = $executionResultPath
                ResultPath = $resultPath
            })
        }
    }

    return @($records)
}

function Get-ManifestShadowResultFiles {
    param([Parameter(Mandatory = $true)][object[]]$Records)

    $shadows = [System.Collections.Generic.List[object]]::new()
    $groups = @($Records | Group-Object { Split-Path -Parent ([string]$_.ResultPath) })
    foreach ($group in $groups) {
        $canonical = @($group.Group)
        $canonicalPaths = @{}
        $canonicalNames = @{}
        foreach ($record in $canonical) {
            $fullPath = [System.IO.Path]::GetFullPath([string]$record.ResultPath)
            $canonicalPaths[$fullPath] = $record
            $normalizedName = ([System.IO.Path]::GetFileName($fullPath)).ToLowerInvariant() -replace '[-_]', ''
            $canonicalNames[$normalizedName] = $record
        }

        $resultDirectory = [string]$group.Name
        if (-not (Test-Path -LiteralPath $resultDirectory -PathType Container)) {
            continue
        }
        foreach ($candidate in @(Get-ChildItem -LiteralPath $resultDirectory -File -Filter '*.result.json' -Force)) {
            $candidatePath = [System.IO.Path]::GetFullPath($candidate.FullName)
            if ($canonicalPaths.ContainsKey($candidatePath)) {
                continue
            }
            $normalizedName = $candidate.Name.ToLowerInvariant() -replace '[-_]', ''
            if ($canonicalNames.ContainsKey($normalizedName)) {
                $record = $canonicalNames[$normalizedName]
                $shadows.Add([pscustomobject]@{
                    Path = $candidatePath
                    CanonicalPath = [string]$record.ResultPath
                    EvalName = [string]$record.EvalName
                    Configuration = [string]$record.Configuration
                })
            }
        }
    }

    return @($shadows)
}

function Test-ManifestResults {
    param(
        [Parameter(Mandatory = $true)][string]$IterationDirectory,
        [Parameter(Mandatory = $true)][object]$Manifest,
        [object[]]$Records,
        [switch]$RequireComplete
    )

    $manifestRecords = if ($null -eq $Records -or $Records.Count -eq 0) {
        @(Get-ManifestRunRecords -IterationDirectory $IterationDirectory -Manifest $Manifest)
    } else {
        @($Records)
    }
    $errors = [System.Collections.Generic.List[string]]::new()
    $warnings = [System.Collections.Generic.List[string]]::new()
    $terminalStatuses = @('completed', 'failed', 'timed_out', 'cancelled', 'incompatible')
    $terminalExecutionResults = 0
    $bridgedResults = 0

    foreach ($shadow in @(Get-ManifestShadowResultFiles -Records $manifestRecords)) {
        $errors.Add("$($shadow.EvalName)/$($shadow.Configuration) has an unreferenced result-like sibling '$($shadow.Path)'; the manifest canonical result is '$($shadow.CanonicalPath)'.")
    }

    foreach ($record in $manifestRecords) {
        $rawExists = Test-Path -LiteralPath $record.ExecutionResultPath -PathType Leaf
        $canonicalExists = Test-Path -LiteralPath $record.ResultPath -PathType Leaf
        if (-not $canonicalExists) {
            $errors.Add("$($record.EvalName)/$($record.Configuration) is missing its manifest-declared result '$($record.ResultRelative)'.")
            continue
        }

        $raw = $null
        $rawStatus = ''
        if ($rawExists) {
            try {
                $raw = Read-RunnerJson -Path $record.ExecutionResultPath
                $rawStatus = [string](Get-JsonProperty -Object $raw -Name 'status' -Default '')
            } catch {
                $errors.Add("$($record.EvalName)/$($record.Configuration) manifest-declared execution result '$($record.ExecutionResultRelative)' is invalid: $($_.Exception.Message)")
                continue
            }

            if ($terminalStatuses -notcontains $rawStatus) {
                $errors.Add("$($record.EvalName)/$($record.Configuration) execution result has non-terminal status '$rawStatus'.")
            } else {
                $terminalExecutionResults++
            }
        } elseif ($RequireComplete) {
            $errors.Add("$($record.EvalName)/$($record.Configuration) is missing its manifest-declared execution result '$($record.ExecutionResultRelative)'.")
        } else {
            $warnings.Add("$($record.EvalName)/$($record.Configuration) has no execution result at the exact manifest path '$($record.ExecutionResultRelative)'.")
        }

        $canonical = $null
        try {
            $canonical = Read-RunnerJson -Path $record.ResultPath
        } catch {
            $errors.Add("$($record.EvalName)/$($record.Configuration) manifest-declared result '$($record.ResultRelative)' is invalid: $($_.Exception.Message)")
            continue
        }

        if ([string]$canonical.configuration -ne $record.Configuration) {
            $errors.Add("$($record.EvalName)/$($record.Configuration) canonical result declares configuration '$($canonical.configuration)'.")
        }
        if ([int]$canonical.eval_id -ne $record.EvalId) {
            $errors.Add("$($record.EvalName)/$($record.Configuration) canonical result declares eval_id '$($canonical.eval_id)'.")
        }

        $metadata = $null
        try {
            $metadata = Read-RunnerJson -Path $record.MetadataPath
        } catch {
            $errors.Add("$($record.EvalName) manifest-declared metadata '$($record.MetadataPath)' is invalid: $($_.Exception.Message)")
        }
        $assertionCount = if ($null -eq $metadata) { -1 } else { @((Get-JsonProperty -Object $metadata -Name 'assertions' -Default @())).Count }
        $grading = @(Get-JsonProperty -Object $canonical -Name 'grading' -Default @())
        if ($assertionCount -ge 0 -and $grading.Count -ne $assertionCount) {
            $errors.Add("$($record.EvalName)/$($record.Configuration) canonical result grading count $($grading.Count) does not match the $assertionCount manifest assertions.")
        }

        $canonicalStatus = [string](Get-JsonProperty -Object $canonical -Name 'execution_status' -Default '')
        if ($rawExists -and $terminalStatuses -contains $rawStatus) {
            if ($canonicalStatus -eq 'unrun') {
                $errors.Add("$($record.EvalName)/$($record.Configuration) has a terminal execution result but its canonical manifest result remains unrun.")
            } elseif ($canonicalStatus -ne $rawStatus) {
                $errors.Add("$($record.EvalName)/$($record.Configuration) canonical execution_status '$canonicalStatus' does not match raw status '$rawStatus'.")
            }

            foreach ($field in @('model', 'harness', 'execution_status', 'execution_run_id', 'execution_result_file')) {
                if (-not (Test-JsonProperty -Object $canonical -Name $field) -or [string]::IsNullOrWhiteSpace([string](Get-JsonProperty -Object $canonical -Name $field -Default ''))) {
                    $errors.Add("$($record.EvalName)/$($record.Configuration) canonical result is missing populated '$field'.")
                }
            }
            $expectedExecutionFile = [System.IO.Path]::GetRelativePath($record.EvalDirectory, $record.ExecutionResultPath).Replace('\', '/')
            $actualExecutionFile = [string](Get-JsonProperty -Object $canonical -Name 'execution_result_file' -Default '')
            if ($actualExecutionFile -ne $expectedExecutionFile) {
                $errors.Add("$($record.EvalName)/$($record.Configuration) canonical execution_result_file '$actualExecutionFile' does not match the manifest execution_result path '$($record.ExecutionResultRelative)'.")
            }
            if ($canonicalStatus -eq $rawStatus -and $grading.Count -eq $assertionCount) {
                $bridgedResults++
            }
        } elseif (-not $rawExists -and $RequireComplete -and $canonicalStatus -ne 'unrun') {
            $errors.Add("$($record.EvalName)/$($record.Configuration) canonical result is populated without a manifest-declared execution result proving the bridge.")
        }
    }

    if ($RequireComplete -and $terminalExecutionResults -ne $manifestRecords.Count) {
        $errors.Add("Completion gate expected $($manifestRecords.Count) terminal execution results but found $terminalExecutionResults.")
    }
    if ($RequireComplete -and $bridgedResults -ne $manifestRecords.Count) {
        $errors.Add("Completion gate expected $($manifestRecords.Count) bridged canonical results but found $bridgedResults.")
    }

    return [pscustomobject]@{
        Records = @($manifestRecords)
        Errors = @($errors)
        Warnings = @($warnings)
        ExpectedArmCount = $manifestRecords.Count
        TerminalExecutionResults = $terminalExecutionResults
        BridgedResults = $bridgedResults
        Complete = $errors.Count -eq 0 -and $terminalExecutionResults -eq $manifestRecords.Count -and $bridgedResults -eq $manifestRecords.Count
        Success = $errors.Count -eq 0
    }
}
