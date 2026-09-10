function New-CopilotBoundaryContext {
    param(
        [Parameter(Mandatory = $true)][object]$RunData,
        [AllowEmptyString()][string]$PackageRoot = '',
        [AllowEmptyString()][string]$SourceRepositoryRoot = ''
    )

    $executionRole = if ($RunData.PSObject.Properties.Name -contains 'ExecutionRole' -and -not [string]::IsNullOrWhiteSpace([string]$RunData.ExecutionRole)) {
        [string]$RunData.ExecutionRole
    } else {
        'eval_arm'
    }
    return [pscustomobject]@{
        PackageRoot = $PackageRoot
        SourceRepositoryRoot = $SourceRepositoryRoot
        RunRoot = [string]$RunData.RunRoot
        WorkingDirectoryRoot = [string]$RunData.WorkingDirectoryPath
        ExecutionRole = $executionRole
    }
}

function Add-CopilotBoundaryValueCandidate {
    param(
        [AllowNull()][object]$Value,
        [Parameter(Mandatory = $true)][string]$PropertyPath,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][System.Collections.Generic.List[object]]$Candidates
    )

    if ($null -eq $Value) { return }
    if ($Value -is [string]) {
        $leaf = [regex]::Replace($PropertyPath, '.*[.\[]', '').TrimEnd(']')
        if ([string]::IsNullOrWhiteSpace($leaf)) { return }
        $kind = if ($leaf -match '^(?i)(command|cmd)$') {
            'command'
        } elseif ($leaf -match '^(?i)(path|paths|file|files|filepath|filepaths|directory|cwd|root|target|targets)$') {
            'path'
        } else {
            $null
        }
        if ($null -ne $kind) {
            $Candidates.Add([pscustomobject]@{
                    kind = $kind
                    source = $PropertyPath
                    value = [string]$Value
                })
        }
        return
    }
    if ($Value -is [System.Collections.IDictionary]) {
        foreach ($key in @($Value.Keys)) {
            Add-CopilotBoundaryValueCandidate -Value $Value[$key] -PropertyPath ([string]::Concat($PropertyPath, '.', [string]$key)) -Candidates $Candidates
        }
        return
    }
    if ($Value -is [System.Collections.IEnumerable] -and $Value -isnot [string]) {
        $index = 0
        foreach ($item in $Value) {
            Add-CopilotBoundaryValueCandidate -Value $item -PropertyPath ([string]::Concat($PropertyPath, '[', $index, ']')) -Candidates $Candidates
            $index++
        }
        return
    }
    foreach ($property in @($Value.PSObject.Properties)) {
        Add-CopilotBoundaryValueCandidate -Value $property.Value -PropertyPath ([string]::Concat($PropertyPath, '.', [string]$property.Name)) -Candidates $Candidates
    }
}

function Get-CopilotBoundaryValueCandidates {
    param([AllowNull()][object]$Data)

    $candidates = [System.Collections.Generic.List[object]]::new()
    Add-CopilotBoundaryValueCandidate -Value $Data -PropertyPath 'data' -Candidates $candidates
    return @($candidates.ToArray())
}

function Test-CopilotBoundaryPairedArmPath {
    param(
        [Parameter(Mandatory = $true)][string]$ResolvedPath,
        [Parameter(Mandatory = $true)][object]$Boundary
    )

    $runRoot = [string](Get-JsonProperty -Object $Boundary -Name 'RunRoot' -Default '')
    $packageRoot = [string](Get-JsonProperty -Object $Boundary -Name 'PackageRoot' -Default '')
    if ([string]::IsNullOrWhiteSpace($packageRoot) -or -not (Test-ObservedPathInside -BasePath $packageRoot -CandidatePath $ResolvedPath)) { return $false }
    if (-not [string]::IsNullOrWhiteSpace($runRoot) -and (Test-ObservedPathInside -BasePath $runRoot -CandidatePath $ResolvedPath)) { return $false }
    return ($ResolvedPath -replace '\\', '/') -match '(?i)(?:^|/)(arm-\d+-(?:with_skill|without_skill)|with_skill|without_skill)(?:/|$)'
}

function Test-CopilotBoundaryForbiddenGradingPath {
    param(
        [Parameter(Mandatory = $true)][string]$ResolvedPath,
        [Parameter(Mandatory = $true)][object]$Boundary
    )

    $normalizedPath = $ResolvedPath -replace '\\', '/'
    if ($normalizedPath -match '(?i)(?:^|/)(eval-metadata\.json|grading\.json|execution-freeze\.json|orchestration-state\.json|benchmark\.(?:json|md)|(?:skill-creator-)?report\.html|RUN-THIS\.prompt\.md|\.external-handoff-started)$') {
        return $true
    }
    $packageRoot = [string](Get-JsonProperty -Object $Boundary -Name 'PackageRoot' -Default '')
    if ([string]::IsNullOrWhiteSpace($packageRoot) -or -not (Test-ObservedPathInside -BasePath $packageRoot -CandidatePath $ResolvedPath)) { return $false }
    $relative = if (Test-ObservedPathInside -BasePath $packageRoot -CandidatePath $ResolvedPath) {
        Get-ObservedRelativePath -BasePath $packageRoot -CandidatePath $ResolvedPath
    } else {
        ''
    }
    return $relative -match '(?i)(?:^|/)(eval-metadata\.json|grading\.json|execution-freeze\.json|orchestration-state\.json|benchmark\.(?:json|md)|(?:skill-creator-)?report\.html|RUN-THIS\.prompt\.md|\.external-handoff-started)(?:$|/)' -or
        $relative -match '^(?i)(results|tools|progress)(?:/|$)'
}

function Get-CopilotBoundaryAssessment {
    param([object]$Data, [object]$Boundary)

    # Structured tool arguments/commands can contradict projection isolation;
    # their absence never proves OS confinement.
    $executionRole = [string](Get-JsonProperty -Object $Boundary -Name 'ExecutionRole' -Default 'eval_arm')
    if ([string]::IsNullOrWhiteSpace($executionRole)) { $executionRole = 'eval_arm' }
    $workingDirectoryRoot = [string](Get-JsonProperty -Object $Boundary -Name 'WorkingDirectoryRoot' -Default (Get-JsonProperty -Object $Boundary -Name 'Root' -Default ''))
    $runRoot = [string](Get-JsonProperty -Object $Boundary -Name 'RunRoot' -Default $workingDirectoryRoot)
    $packageRoot = [string](Get-JsonProperty -Object $Boundary -Name 'PackageRoot' -Default '')
    $sourceRepositoryRoot = [string](Get-JsonProperty -Object $Boundary -Name 'SourceRepositoryRoot' -Default '')
    $contradictions = [System.Collections.Generic.List[string]]::new()
    $ownArmGradingVisible = $false
    $pairedArmVisible = $false
    $pairedOrPackageGradingVisible = $false

    foreach ($candidate in @(Get-CopilotBoundaryValueCandidates -Data $Data)) {
        $pathValues = if ([string]$candidate.kind -eq 'command') {
            if (Test-FileSystemCommandText -Text ([string]$candidate.value)) {
                @(Get-ObservedPathTokensFromCommandText -Text ([string]$candidate.value))
            } else {
                @()
            }
        } else {
            @([string]$candidate.value)
        }
        foreach ($pathValue in $pathValues) {
            $observed = Get-ObservedPathInfo -Path $pathValue -BasePath $workingDirectoryRoot
            if ($null -eq $observed) { continue }
            $resolvedPath = [string]$observed.FullPath
            $insideWorking = -not [string]::IsNullOrWhiteSpace($workingDirectoryRoot) -and (Test-ObservedPathInside -BasePath $workingDirectoryRoot -CandidatePath $resolvedPath)
            $insideRun = -not [string]::IsNullOrWhiteSpace($runRoot) -and (Test-ObservedPathInside -BasePath $runRoot -CandidatePath $resolvedPath)
            $insidePackage = -not [string]::IsNullOrWhiteSpace($packageRoot) -and (Test-ObservedPathInside -BasePath $packageRoot -CandidatePath $resolvedPath)
            $insideSource = -not [string]::IsNullOrWhiteSpace($sourceRepositoryRoot) -and (Test-ObservedPathInside -BasePath $sourceRepositoryRoot -CandidatePath $resolvedPath)
            if ($executionRole -eq 'phase2_analyzer') {
                if ($insideWorking) {
                    $relative = Get-ObservedRelativePath -BasePath $workingDirectoryRoot -CandidatePath $resolvedPath
                    if ($relative -in @('input-bundle.json', 'grader.md')) { $ownArmGradingVisible = $true }
                    continue
                }
                if ($insideRun) {
                    $contradictions.Add("Tool event references analyzer transport path '$pathValue' outside the staged repo bundle.")
                } elseif ($insidePackage) {
                    $contradictions.Add("Tool event references package path '$pathValue' outside the staged analyzer bundle.")
                } elseif ($insideSource) {
                    $contradictions.Add("Tool event references source repository path '$pathValue' outside the staged analyzer bundle.")
                } else {
                    $contradictions.Add("Tool event references path '$pathValue' outside the staged analyzer bundle.")
                }
            } else {
                if ($insideRun) {
                    continue
                }
                if ($insidePackage) {
                    $contradictions.Add("Tool event references forbidden package path '$pathValue'.")
                } elseif ($insideSource) {
                    $contradictions.Add("Tool event references forbidden source repository path '$pathValue'.")
                } else {
                    $contradictions.Add("Tool event references path '$pathValue' outside the physical projection.")
                }
            }
            if (Test-CopilotBoundaryPairedArmPath -ResolvedPath $resolvedPath -Boundary ([pscustomobject]@{ PackageRoot = $packageRoot; RunRoot = $runRoot })) { $pairedArmVisible = $true }
            if (Test-CopilotBoundaryForbiddenGradingPath -ResolvedPath $resolvedPath -Boundary ([pscustomobject]@{ PackageRoot = $packageRoot })) { $pairedOrPackageGradingVisible = $true }
        }
    }

    return [pscustomobject]@{
        Contradictions = @($contradictions | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } | Select-Object -Unique)
        OwnArmGradingMaterialVisible = $ownArmGradingVisible
        PairedArmVisible = $pairedArmVisible
        PairedOrPackageGradingMaterialVisible = $pairedOrPackageGradingVisible
    }
}

function Find-CopilotBoundaryContradictions {
    param([object]$Data, [object]$Projection)

    return @((Get-CopilotBoundaryAssessment -Data $Data -Boundary $Projection).Contradictions)
}

# Conservative detector for a native Copilot skill activation of the evaluated candidate. The native skill tool is
# excluded and skill discovery roots are isolated, so a candidate skill tool call or a native skill-resolution result
# naming the candidate is an isolation violation in BOTH arms. It fires only on a native 'skill' tool identity or a
# native skill-resolution result (a skillSource marker) that also names the candidate, so an ordinary file read of the
# staged with_skill candidate copy or a mere text mention never trips it.
function Find-CopilotNativeSkillActivation {
    param([object]$Data, [string]$CandidateSkillName, [string]$EventType = '')
    if ($null -eq $Data -or [string]::IsNullOrWhiteSpace($CandidateSkillName)) { return }
    $json = ($Data | ConvertTo-Json -Depth 100 -Compress)
    $toolIdentity = $false
    foreach ($field in @('toolName', 'tool', 'name', 'tool_name')) {
        $value = [string](Get-JsonProperty -Object $Data -Name $field -Default '')
        if ($value -match '^(?i)skill$') { $toolIdentity = $true }
    }
    $skillResolution = $json -match '(?i)"skill[_]?[Ss]ource"'
    if (-not ($toolIdentity -or $skillResolution)) { return }
    if ($json -match ('(?i)(^|[^A-Za-z0-9._-])' + [regex]::Escape($CandidateSkillName) + '([^A-Za-z0-9._-]|$)')) {
        "Native Copilot skill activation referenced the candidate '$CandidateSkillName'; the candidate must never be available through the native skill mechanism."
    }
}

# Independent, bridge-side re-verification of the candidate-instruction identity proof. with_skill must embed the exact
# frozen candidate instruction bytes (prompt prefix before the working-environment marker) whose hash equals the frozen
# candidateInstructionHash; without_skill must carry neither a hash nor an embedded candidate instruction section. This
# never trusts a runner boolean: it recomputes from the staged prompt bytes and run.json.
function Assert-CopilotCandidateInstructionBoundary {
    param([object]$RunData)
    $boundary = "`n`n# Working environment"
    $promptText = ([Text.Encoding]::UTF8.GetString([byte[]]$RunData.PromptBytes)) -replace "`r`n", "`n" -replace "`r", "`n"
    $markerIndex = $promptText.IndexOf($boundary, [StringComparison]::Ordinal)
    if ($RunData.Mode -eq 'with_skill') {
        $expected = [string]$RunData.CandidateInstructionHash
        if ([string]::IsNullOrWhiteSpace($expected)) { throw 'with_skill run must carry candidateInstructionHash; candidate identity is unproven.' }
        if ($markerIndex -lt 0) { throw 'with_skill prompt has no working-environment boundary; the injected candidate instructions cannot be isolated for hashing.' }
        $instruction = $promptText.Substring(0, $markerIndex)
        $actual = ([Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($instruction)))).ToLowerInvariant()
        if ($actual -ne $expected) { throw 'with_skill injected candidate instructions do not hash to the frozen candidateInstructionHash; candidate identity is unproven.' }
        if ($instruction -notmatch '(?im)^##\s*Skill:') { throw 'with_skill prompt prefix does not contain the candidate instruction section.' }
    } else {
        if (-not [string]::IsNullOrWhiteSpace([string]$RunData.CandidateInstructionHash)) { throw 'without_skill must not declare candidateInstructionHash.' }
        $prefix = if ($markerIndex -lt 0) { $promptText } else { $promptText.Substring(0, $markerIndex) }
        if ($prefix -match '(?im)^##\s*Skill:') { throw 'without_skill prompt embeds a candidate instruction section; the baseline must receive no candidate instructions.' }
    }
}

function Assert-CopilotCapturedBoundary {
    param([object]$Raw, [object]$RunData)
    if ($Raw.runner.name -ne 'github-copilot' -or $Raw.status -ne 'completed') { return }
    $paths = Get-JsonProperty -Object $Raw.evidence -Name execution_paths -Default $null
    if (-not [bool](Get-JsonProperty -Object $paths -Name projection_proven -Default $false)) { throw 'Completed Copilot execution lacks a proven physical projection.' }
    $package = Split-Path -Parent (Split-Path -Parent $RunData.RunRoot)
    $source = [string](Get-JsonProperty -Object $paths -Name source_repository_root -Default '')
    $physical = [string](Get-JsonProperty -Object $paths -Name physical_run_root -Default '')
    if ([string]::IsNullOrWhiteSpace($physical) -or (Test-PathInside -BasePath $package -CandidatePath $physical) -or ($source -and (Test-PathInside -BasePath $source -CandidatePath $physical))) { throw 'Invalid Copilot physical projection boundary.' }
    Assert-CopilotCandidateInstructionBoundary -RunData $RunData
    $proof = New-CopilotBoundaryContext -RunData $RunData -PackageRoot $package -SourceRepositoryRoot $source
    $candidateSkillName = [string]$RunData.CandidateSkillName
    $transcript = @($Raw.artifacts | Where-Object { $_.scope -eq 'run' -and $_.path -eq 'evidence/copilot-events.jsonl' })
    if ($transcript.Count -ne 1) { throw 'Copilot native transcript is missing.' }
    $path = Resolve-ContainedPath -BasePath $RunData.RunRoot -RelativePath $transcript[0].path -FieldName 'Copilot transcript' -Kind File
    $parsed = ConvertFrom-JsonLines -Text ([IO.File]::ReadAllText($path))
    if (@($parsed.Errors).Count) { throw 'Copilot transcript contains unparseable events; boundary inspection is incomplete.' }
    foreach ($event in $parsed.Events) {
        $eventType = [string](Get-JsonProperty -Object $event -Name type -Default '')
        $data = Get-JsonProperty -Object $event -Name data -Default $null
        if ($eventType -match '^(tool\.|command\.)') {
            if (@((Get-CopilotBoundaryAssessment -Data $data -Boundary $proof).Contradictions).Count) { throw 'Copilot transcript contradicts claimed isolation; grading is forbidden.' }
            if (@(Find-CopilotNativeSkillActivation -Data $data -CandidateSkillName $candidateSkillName -EventType $eventType).Count) { throw 'Copilot transcript shows native candidate skill activation; grading is forbidden.' }
        }
    }
}
