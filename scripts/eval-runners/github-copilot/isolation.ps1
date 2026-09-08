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

function Assert-CopilotCapturedBoundary {
    param([object]$Raw, [object]$RunData)
    if ($Raw.runner.name -ne 'github-copilot' -or $Raw.status -ne 'completed') { return }
    $paths = Get-JsonProperty -Object $Raw.evidence -Name execution_paths -Default $null
    if (-not [bool](Get-JsonProperty -Object $paths -Name projection_proven -Default $false)) { throw 'Completed Copilot execution lacks a proven physical projection.' }
    $package = Split-Path -Parent (Split-Path -Parent $RunData.RunRoot)
    $source = [string](Get-JsonProperty -Object $paths -Name source_repository_root -Default '')
    $physical = [string](Get-JsonProperty -Object $paths -Name physical_run_root -Default '')
    if ([string]::IsNullOrWhiteSpace($physical) -or (Test-PathInside -BasePath $package -CandidatePath $physical) -or ($source -and (Test-PathInside -BasePath $source -CandidatePath $physical))) { throw 'Invalid Copilot physical projection boundary.' }
    $proof = [pscustomobject]@{ PackageRoot = $package; SourceRepositoryRoot = $source }
    $transcript = @($Raw.artifacts | Where-Object { $_.scope -eq 'run' -and $_.path -eq 'evidence/copilot-events.jsonl' })
    if ($transcript.Count -ne 1) { throw 'Copilot native transcript is missing.' }
    $path = Resolve-ContainedPath -BasePath $RunData.RunRoot -RelativePath $transcript[0].path -FieldName 'Copilot transcript' -Kind File
    $parsed = ConvertFrom-JsonLines -Text ([IO.File]::ReadAllText($path))
    if (@($parsed.Errors).Count) { throw 'Copilot transcript contains unparseable events; boundary inspection is incomplete.' }
    foreach ($event in $parsed.Events) {
        if ([string](Get-JsonProperty -Object $event -Name type -Default '') -match '^(tool\.|command\.)') {
            if (@(Find-CopilotBoundaryContradictions -Data (Get-JsonProperty -Object $event -Name data -Default $null) -Projection $proof).Count) { throw 'Copilot transcript contradicts claimed isolation; grading is forbidden.' }
        }
    }
}
