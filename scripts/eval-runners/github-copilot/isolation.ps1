function Find-CopilotBoundaryContradictions {
    param([object]$Data, [object]$Projection)
    # Structured tool arguments/results can contradict projection isolation;
    # their absence never proves OS confinement.
    $text = ($Data | ConvertTo-Json -Depth 100 -Compress).Replace('\\', '/').Replace('\', '/')
    foreach ($root in @($Projection.PackageRoot, $Projection.SourceRepositoryRoot) | Where-Object { $_ }) {
        if ($text.IndexOf(([string]$root).Replace('\', '/'), [StringComparison]::OrdinalIgnoreCase) -ge 0) { 'Tool event references forbidden package/source path.' }
    }
    if ($text -match '(?i)(eval-metadata\.json|(?:^|[/"\s])(?:with_skill|without_skill)(?:[/"\s]|$)|(?:\.\./)+(?:results|tools|progress)(?:/|"|\s)|(?:execution-freeze|orchestration-state|grading|benchmark)\.(?:json|md)|(?:skill-creator-)?report\.html|RUN-THIS\.prompt\.md|\.external-handoff-started)') {
        'Tool event references forbidden grading, paired-arm, or orchestration material.'
    }
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
        if ([string]::IsNullOrWhiteSpace($expected)) { return }
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
    $proof = [pscustomobject]@{ PackageRoot = $package; SourceRepositoryRoot = $source }
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
            if (@(Find-CopilotBoundaryContradictions -Data $data -Projection $proof).Count) { throw 'Copilot transcript contradicts claimed isolation; grading is forbidden.' }
            if (@(Find-CopilotNativeSkillActivation -Data $data -CandidateSkillName $candidateSkillName -EventType $eventType).Count) { throw 'Copilot transcript shows native candidate skill activation; grading is forbidden.' }
        }
    }
}
