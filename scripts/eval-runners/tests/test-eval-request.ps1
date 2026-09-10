<# Deterministic request-to-handoff coverage: real preparation, fixture catalogs, fake host. No models. #>
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$scripts = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
. (Join-Path $scripts 'eval-request.ps1')
$workspace = Join-Path ([IO.Path]::GetTempPath()) ('eval-request-workspace/' + [guid]::NewGuid().ToString('N'))
[void](New-Item -ItemType Directory -Path $workspace -Force)
$script:dispatches = [Collections.Generic.List[string]]::new()
$utf8NoBom = [System.Text.UTF8Encoding]::new($false)

function Assert-True([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
}
function Read-PackageManifest([string]$PromptPath) {
    $manifestPath = Join-Path (Split-Path -Parent $PromptPath) 'manifest.json'
    return [System.IO.File]::ReadAllText($manifestPath, $utf8NoBom) | ConvertFrom-Json
}
function Write-PackageManifest([string]$PromptPath, [object]$Manifest) {
    $manifestPath = Join-Path (Split-Path -Parent $PromptPath) 'manifest.json'
    [System.IO.File]::WriteAllText($manifestPath, (($Manifest | ConvertTo-Json -Depth 100) + [Environment]::NewLine), $utf8NoBom)
}
function Assert-PreparedPromptBinding([string]$PromptPath, [string]$Description) {
    $manifest = Read-PackageManifest -PromptPath $PromptPath
    Assert-True ([string]$manifest.runner_prompt -ceq 'RUN-THIS.prompt.md') "$Description manifest.runner_prompt changed unexpectedly."
    $declaredHash = [string]$manifest.runner_prompt_sha256
    Assert-True ($declaredHash -match '^[0-9a-f]{64}$') "$Description manifest.runner_prompt_sha256 must be a lowercase SHA-256."
    Assert-True ($declaredHash -ceq (Get-Sha256HexFromFile -Path $PromptPath)) "$Description manifest.runner_prompt_sha256 must match RUN-THIS.prompt.md byte-for-byte."
}
function Invoke-FakeHost($Decision) {
    if ($Decision.action -eq 'external_handoff') {
        # The host's only input is the actual canonical handoff file, never an arm prompt.
        Assert-True (Test-Path -LiteralPath $Decision.prompt_path -PathType Leaf) 'Host received a missing handoff.'
        Assert-True ([IO.Path]::GetFileName($Decision.prompt_path) -ceq 'RUN-THIS.prompt.md') 'Host received an arm.'
        Assert-True (Test-Path -LiteralPath (Join-Path (Split-Path -Parent $Decision.prompt_path) '.external-handoff-started')) 'External handoff must be reserved before the host launch, for every runner.'
        $script:dispatches.Add($Decision.prompt_path)
    }
}
function New-Preparation([string]$Runner, [string]$Name) {
    return @{ Skill = 'dotnet-strong-name-signing'; Eval = @(1); Runner = $Runner
        OutputRoot = (Join-Path $workspace $Name); ModelCatalogPath = $catalog; AnalyzerModelCatalogPath = $catalog }
}
function Assert-Failure([hashtable]$Options, [string]$Pattern) {
    # The request must fail closed even in an ordinary interactive PowerShell caller.
    $ErrorActionPreference = 'Continue'
    $before = $script:dispatches.Count
    $failed = $false
    try {
        Invoke-EvalRequest -Preparation $Options -Yolo -CanDelegateFreshOrchestrator |
            ForEach-Object { Invoke-FakeHost $_ }
    } catch {
        $failed = $true
        Assert-True ($_.Exception.Message -match $Pattern) "Unexpected failure: $_"
    }
    Assert-True $failed 'Expected preparation failure.'
    Assert-True ($script:dispatches.Count -eq $before) 'Failed preparation dispatched an Orchestrator.'
}

function Assert-HandoffFailure([string]$PromptPath, [string]$Pattern, [string]$Description) {
    $before = $script:dispatches.Count
    $failed = $false
    $claim = Join-Path (Split-Path -Parent $PromptPath) '.external-handoff-started'
    $decision = $null
    try {
        $decision = Get-EvalHandoff -PromptPath $PromptPath -Yolo -CanDelegateFreshOrchestrator
        Invoke-FakeHost $decision
    } catch {
        $failed = $true
        Assert-True ($_.Exception.Message -match $Pattern) "Unexpected handoff failure for ${Description}: $($_.Exception.Message)"
    }
    Assert-True $failed "$Description unexpectedly passed handoff validation."
    Assert-True ($null -eq $decision -or $decision.action -ne 'external_handoff') "$Description returned external_handoff before failing."
    Assert-True ($script:dispatches.Count -eq $before) "$Description dispatched an Orchestrator."
    Assert-True (-not (Test-Path -LiteralPath $claim)) "$Description created .external-handoff-started before rejection."
}

try {
    $catalog = Join-Path $workspace 'models.json'
    @{ models = @(@{ id = 'gpt-5.6-luna' }, @{ id = 'claude-haiku-4.5' }, @{ id = 'claude-opus-4.7' }, @{ id = 'provider/Exact.Model' }) } |
        ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $catalog -Encoding utf8

    $normalOptions = New-Preparation 'Codex' 'normal'
    $normal = Invoke-EvalRequest -Preparation $normalOptions -CanDelegateFreshOrchestrator
    Assert-PreparedPromptBinding -PromptPath $normal.prompt_path -Description 'Normal preparation'
    Invoke-FakeHost $normal
    Assert-True ($normal.action -eq 'manual_handoff' -and $script:dispatches.Count -eq 0) 'Normal eval must stop at manual handoff.'
    Assert-True (-not (Test-Path (Join-Path (Split-Path $normal.prompt_path) '.external-handoff-started'))) 'Normal preparation reserved execution.'

    # Force may replace an unstarted package, but must preserve every started package.
    $normalOptions.Iteration = 1
    $normalOptions.Force = $true
    $replacement = Invoke-EvalRequest -Preparation $normalOptions
    Assert-True ($replacement.prompt_path -eq $normal.prompt_path) 'Force could not replace an unstarted package.'
    foreach ($marker in @('.external-handoff-started', 'orchestration-state.json', 'execution-freeze.json')) {
        $options = New-Preparation 'Codex' ([guid]::NewGuid().ToString('N'))
        $options.Iteration = 1
        $options.Force = $true
        if ($marker -eq '.external-handoff-started') {
            $reserved = Invoke-EvalRequest -Preparation $options -Yolo -CanDelegateFreshOrchestrator
            Invoke-FakeHost $reserved
        } else {
            $reserved = Invoke-EvalRequest -Preparation $options
            '{}' | Set-Content -LiteralPath (Join-Path (Split-Path $reserved.prompt_path) $marker)
        }
        $package = Split-Path $reserved.prompt_path
        $beforeFiles = @(Get-ChildItem -LiteralPath $package -Recurse -File -Force | Sort-Object FullName |
            ForEach-Object { $_.FullName + ':' + (Get-FileHash -LiteralPath $_.FullName).Hash })
        Assert-Failure $options 'handoff or execution has already started'
        $afterFiles = @(Get-ChildItem -LiteralPath $package -Recurse -File -Force | Sort-Object FullName |
            ForEach-Object { $_.FullName + ':' + (Get-FileHash -LiteralPath $_.FullName).Hash })
        Assert-True (($beforeFiles -join "`n") -ceq ($afterFiles -join "`n")) "Forced retry changed package protected by $marker."
        $again = Get-EvalHandoff -PromptPath $reserved.prompt_path -Yolo -CanDelegateFreshOrchestrator
        Assert-True ($again.action -eq 'already_started') "Forced retry erased $marker."
    }

    foreach ($case in @(
        @{ Name = 'codex-default'; Runner = 'CoDeX'; Expected = 'codex'; Model = 'gpt-5.6-luna' },
        @{ Name = 'copilot-default'; Runner = 'Copilot'; Expected = 'github-copilot'; Model = 'claude-haiku-4.5'; StrongerModel = 'claude-opus-4.7'; UseLegacyAvailabilityAlias = $true },
        @{ Name = 'copilot-explicit-model'; Runner = 'GitHub Copilot CLI'; Expected = 'github-copilot'; Model = 'gpt-5.6-luna'; Explicit = $true },
        @{ Name = 'opencode-explicit-model'; Runner = 'OpenCode'; Expected = 'opencode'; Model = 'provider/Exact.Model'; Explicit = $true }
    )) {
        $options = New-Preparation $case.Runner ([guid]::NewGuid().ToString('N'))
        if ($case.ContainsKey('Explicit')) { $options.Model = $case.Model }
        $decision = if ($case.ContainsKey('UseLegacyAvailabilityAlias')) {
            Invoke-EvalRequest -Preparation $options -Yolo -ExternalOrchestratorAvailable
        } else {
            Invoke-EvalRequest -Preparation $options -Yolo -CanDelegateFreshOrchestrator
        }
        Assert-PreparedPromptBinding -PromptPath $decision.prompt_path -Description $case.Name
        $profile = Get-Content -LiteralPath (Join-Path (Split-Path $decision.prompt_path) 'execution-profile.json') -Raw | ConvertFrom-Json
        Assert-True ($profile.runner -ceq $case.Expected -and $profile.model -ceq $case.Model) 'Wrong runner/model policy.'
        if ($case.ContainsKey('StrongerModel')) {
            Assert-True ($profile.model -cne $case.StrongerModel) 'Copilot replaced repository model policy with a subjective stronger-model choice.'
        }
        if ($case.Expected -eq 'codex') {
            Assert-True ($profile.reasoning_effort -eq 'low') 'Codex default reasoning changed.'
        }
        Assert-True ($decision.action -eq 'external_handoff') 'Yolo did not request external handoff.'
        $before = $script:dispatches.Count
        Invoke-FakeHost $decision
        Assert-True ($script:dispatches[$before] -ceq $decision.prompt_path) 'Host did not receive the exact generated RUN-THIS.prompt.md path.'
        $again = Get-EvalHandoff -PromptPath $decision.prompt_path -Yolo -CanDelegateFreshOrchestrator
        Invoke-FakeHost $again
        Assert-True ($again.action -eq 'already_started' -and $script:dispatches.Count -eq $before + 1) 'Duplicate handoff could invoke Phase 1 twice.'
        $unavailableAfterStart = Get-EvalHandoff -PromptPath $decision.prompt_path -Yolo
        Assert-True ($unavailableAfterStart.action -eq 'already_started') 'An uncertain launch incorrectly suggested a new manual execution.'
    }

    $reference = New-Preparation 'unused' 'reference'
    $reference.Remove('Runner')
    $reference.CodebeltReference = $true
    $reference.ReasoningEffort = 'high'
    $reference.ConfigurationProfile = 'fixture-profile'
    $reference.ToolProfile = 'fixture-tools'
    $reference.TimeoutSeconds = 123
    $reference.Concurrency = 3
    $referenceDecision = Invoke-EvalRequest -Preparation $reference -Yolo -CanDelegateFreshOrchestrator
    $profile = Get-Content (Join-Path (Split-Path $referenceDecision.prompt_path) 'execution-profile.json') -Raw | ConvertFrom-Json
    Assert-True ($profile.runner -eq 'github-copilot' -and $profile.model -eq 'claude-haiku-4.5') 'CodebeltReference changed.'
    Assert-True ($profile.reasoning_effort -eq 'high' -and $profile.configuration_profile -eq 'fixture-profile' -and $profile.tool_profile -eq 'fixture-tools' -and $profile.timeout_seconds -eq 123 -and $profile.concurrency -eq 3) 'Preparation options were not forwarded unchanged.'

    $unavailable = Invoke-EvalRequest -Preparation (New-Preparation 'Copilot' 'unavailable') -Yolo
    $before = $script:dispatches.Count
    Invoke-FakeHost $unavailable
    Assert-True ($unavailable.action -eq 'manual_handoff' -and $script:dispatches.Count -eq $before) 'Unavailable host executed a fallback.'
    Assert-True (Test-Path -LiteralPath $unavailable.prompt_path) 'Unavailable host lost the package.'
    # Existing execution state also blocks automatic handoff, even without a handoff receipt.
    '{}' | Set-Content (Join-Path (Split-Path $unavailable.prompt_path) 'orchestration-state.json')
    $started = Get-EvalHandoff -PromptPath $unavailable.prompt_path -Yolo -CanDelegateFreshOrchestrator
    Assert-True ($started.action -eq 'already_started') 'Existing Phase 1 could be invoked twice.'

    Assert-Failure (New-Preparation 'OpenCode' 'missing-model') 'explicit -Model'
    $invalid = New-Preparation 'GitHub Copilot' 'invalid-model'
    $invalid.Model = 'not-in-catalog'
    Assert-Failure $invalid "Runner 'github-copilot' model 'not-in-catalog' could not be verified"
    $invalid = New-Preparation 'Codex' 'invalid-default'
    $emptyCatalog = Join-Path $workspace 'empty-models.json'
    '{"models":[{"id":"unrelated-model"}]}' | Set-Content $emptyCatalog
    $invalid.ModelCatalogPath = $emptyCatalog
    Assert-Failure $invalid "Runner 'codex' model 'gpt-5.6-luna' could not be verified"
    $invalid = New-Preparation 'Codex' 'missing-skill'
    $invalid.Skill = 'no-such-skill'
    Assert-Failure $invalid 'skill|directory|path'

    $standaloneRoot = Join-Path $workspace 'standalone'
    [void](New-Item -ItemType Directory -Path $standaloneRoot -Force)
    $standalonePrompt = Join-Path $standaloneRoot 'RUN-THIS.prompt.md'
    [System.IO.File]::WriteAllText($standalonePrompt, '# forged handoff', [System.Text.UTF8Encoding]::new($false))
    Assert-HandoffFailure -PromptPath $standalonePrompt -Pattern 'valid prepared eval package' -Description 'standalone RUN-THIS.prompt.md'

    $pathMismatch = Invoke-EvalRequest -Preparation (New-Preparation 'Codex' 'path-mismatch')
    $pathMismatchManifest = Read-PackageManifest -PromptPath $pathMismatch.prompt_path
    $pathMismatchManifest.runner_prompt = 'README.md'
    $pathMismatchManifest.runner_prompt_sha256 = Get-Sha256HexFromFile -Path (Join-Path (Split-Path -Parent $pathMismatch.prompt_path) 'README.md')
    Write-PackageManifest -PromptPath $pathMismatch.prompt_path -Manifest $pathMismatchManifest
    Assert-HandoffFailure -PromptPath $pathMismatch.prompt_path -Pattern 'manifest-declared runner_prompt' -Description 'manifest runner_prompt path mismatch'

    $tamperedPrompt = Invoke-EvalRequest -Preparation (New-Preparation 'Codex' 'tampered-prompt')
    Assert-PreparedPromptBinding -PromptPath $tamperedPrompt.prompt_path -Description 'Prompt tamper fixture'
    [System.IO.File]::AppendAllText($tamperedPrompt.prompt_path, "`n# tampered prompt`n", $utf8NoBom)
    Assert-HandoffFailure -PromptPath $tamperedPrompt.prompt_path -Pattern 'runner_prompt_sha256|RUN-THIS\.prompt\.md bytes|Requires a fresh package' -Description 'tampered RUN-THIS.prompt.md'

    $missingPromptHash = Invoke-EvalRequest -Preparation (New-Preparation 'Codex' 'missing-prompt-hash')
    $missingPromptHashManifest = Read-PackageManifest -PromptPath $missingPromptHash.prompt_path
    [void]$missingPromptHashManifest.PSObject.Properties.Remove('runner_prompt_sha256')
    Write-PackageManifest -PromptPath $missingPromptHash.prompt_path -Manifest $missingPromptHashManifest
    Assert-HandoffFailure -PromptPath $missingPromptHash.prompt_path -Pattern 'runner_prompt_sha256' -Description 'missing runner_prompt_sha256'

    $malformedPromptHash = Invoke-EvalRequest -Preparation (New-Preparation 'Codex' 'malformed-prompt-hash')
    $malformedPromptHashManifest = Read-PackageManifest -PromptPath $malformedPromptHash.prompt_path
    $malformedPromptHashManifest.runner_prompt_sha256 = 'not-a-lowercase-sha256'
    Write-PackageManifest -PromptPath $malformedPromptHash.prompt_path -Manifest $malformedPromptHashManifest
    Assert-HandoffFailure -PromptPath $malformedPromptHash.prompt_path -Pattern 'runner_prompt_sha256' -Description 'malformed runner_prompt_sha256'

    $mismatchedPromptHash = Invoke-EvalRequest -Preparation (New-Preparation 'Codex' 'mismatched-prompt-hash')
    $mismatchedPromptHashManifest = Read-PackageManifest -PromptPath $mismatchedPromptHash.prompt_path
    $mismatchedPromptHashManifest.runner_prompt_sha256 = ('1' * 64)
    Write-PackageManifest -PromptPath $mismatchedPromptHash.prompt_path -Manifest $mismatchedPromptHashManifest
    Assert-HandoffFailure -PromptPath $mismatchedPromptHash.prompt_path -Pattern 'runner_prompt_sha256|RUN-THIS\.prompt\.md bytes|Requires a fresh package' -Description 'mismatched runner_prompt_sha256'

    $tampered = Invoke-EvalRequest -Preparation (New-Preparation 'Codex' 'tampered')
    $tamperedPackage = Split-Path -Parent $tampered.prompt_path
    [System.IO.File]::AppendAllText((Join-Path $tamperedPackage 'tools/eval-runners/resolve-runner.ps1'), "`n# tampered`n", [System.Text.UTF8Encoding]::new($false))
    Assert-HandoffFailure -PromptPath $tampered.prompt_path -Pattern 'valid prepared eval package|Requires a fresh package|changed after preparation' -Description 'tampered prepared package'

    # Check the real discovery call contract, not a mocked model resolver.
    $source = Get-Content (Join-Path $scripts 'prepare-skill-evals.ps1') -Raw
    Assert-True ($source.Contains("`$arguments = @('-Runner', `$RunnerName, '-RequireModel', `$ModelName)")) 'Model discovery must explicitly receive normalized runner and exact model.'
    $helper = Get-Content (Join-Path $scripts 'eval-request.ps1') -Raw
    Assert-True ($helper.Contains("[Alias('ExternalOrchestratorAvailable')][switch]`$CanDelegateFreshOrchestrator")) 'External orchestrator capability alias changed unexpectedly.'
    Assert-True (-not $helper.Contains('claude-haiku-4.5') -and -not $helper.Contains('gpt-5.6-luna') -and -not $helper.Contains('claude-opus-4.7')) 'Eval request helper must not embed model-selection policy.'
    Assert-True ($helper -notmatch 'invoke-runner-owned-arms|runner.ps1 execute|Start-Process|spawn_agent') 'Request helper must not implement execution.'
    Write-Host 'PASS: normal/yolo requests, Copilot delegation capability semantics, runner/model policy, failures, canonical handoff pathing, and duplicate dispatch guards (fake host only).'
} finally {
    # The absolute target is the unique child allocated under the external test workspace above.
    $allowed = [IO.Path]::GetFullPath((Join-Path ([IO.Path]::GetTempPath()) 'eval-request-workspace')) + [IO.Path]::DirectorySeparatorChar
    if (-not [IO.Path]::GetFullPath($workspace).StartsWith($allowed, [StringComparison]::OrdinalIgnoreCase)) { throw 'Unsafe test cleanup path.' }
    Remove-Item -LiteralPath $workspace -Recurse -Force
}
