#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Deterministic regression tests for scripts/validate-local.ps1.

.DESCRIPTION
    Exercises the local full-validation scheduler against fixture workflows and fixture suites so
    that scheduling, failure propagation, silent-skip detection, timeout handling, process-tree
    teardown, cancellation, concurrency bounding, complete coverage, and output-root safety are all
    verified without depending on the real validation suites or on any model.

    Every scenario runs the real scheduler in a child process against an isolated fixture
    repository under the user temp directory, so nothing here touches the working tree.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
# Fixture suites intentionally exit non-zero and the scheduler reports failures on stderr; never
# promote native command output into a terminating error in this harness.
$PSNativeCommandUseErrorActionPreference = $false

$scheduler = Join-Path (Resolve-Path (Join-Path $PSScriptRoot '..')).Path 'validate-local.ps1'
$root = Join-Path ([System.IO.Path]::GetTempPath()) ('validate-local-tests-' + [Guid]::NewGuid().ToString('N'))
$utf8NoBom = [System.Text.UTF8Encoding]::new($false)
$failures = [System.Collections.Generic.List[string]]::new()

function Write-FixtureFile {
    param([string]$Path, [string]$Content)

    $directory = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $directory)) {
        New-Item -ItemType Directory -Path $directory -Force | Out-Null
    }
    [System.IO.File]::WriteAllText($Path, $Content, $utf8NoBom)
}

# ---------------------------------------------------------------------------
# Fixture repository. Script names mirror the real matrix paths so the scheduler
# applies the same terminal-marker expectations it uses in production.
# ---------------------------------------------------------------------------

$fixtureTemplateValidator = @'
param(
    [ValidateSet('All', 'Good', 'Bad', 'Silent', 'Hang', 'SlowA', 'SlowB', 'SlowC', 'SlowD', 'Sleepy', 'Tree', 'Skip')]
    [string]$Suite = 'All'
)

$ErrorActionPreference = 'Stop'
$probe = $env:VALIDATION_TEST_PROBE_DIR

function Write-Probe {
    param([string]$Suffix, [string]$Value = '')
    if ([string]::IsNullOrWhiteSpace($probe)) { return }
    New-Item -ItemType Directory -Path $probe -Force | Out-Null
    $text = if ([string]::IsNullOrEmpty($Value)) { [string][DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() } else { $Value }
    [System.IO.File]::WriteAllText((Join-Path $probe ("$Suite-$Suffix")), $text)
}

if ($Suite -eq 'Skip') {
    Write-Host '[SKIP] fixture suite skipped'
    exit 0
}

Write-Probe 'start'

switch -Regex ($Suite) {
    '^Good$' {
        Write-Host 'Passed: 3'
        Write-Host 'Failed: 0'
        Write-Probe 'end'
        exit 0
    }
    '^Bad$' {
        Write-Host '[FAIL] fixture check failed'
        Write-Host 'Passed: 1'
        Write-Host 'Failed: 1'
        Write-Probe 'end'
        exit 1
    }
    '^Silent$' {
        Write-Probe 'end'
        exit 0
    }
    '^Sleepy$' {
        Start-Sleep -Milliseconds 400
        Write-Host 'Passed: 2'
        Write-Host 'Failed: 0'
        Write-Probe 'end'
        exit 0
    }
    '^Slow' {
        # Prove real overlap without depending on wall-clock luck. Staying open until a peer suite
        # is also running makes concurrency structural: a scheduler that serialized independent
        # suites could never satisfy this, so the overlap assertion detects the bug instead of a
        # startup-time race. The wait is bounded and never changes the suite's own duration logic.
        if (-not [string]::IsNullOrWhiteSpace($probe)) {
            $rendezvousDeadline = (Get-Date).AddSeconds(20)
            while ((Get-Date) -lt $rendezvousDeadline) {
                $startedCount = @(Get-ChildItem -LiteralPath $probe -Filter '*-start' -ErrorAction SilentlyContinue).Count
                $finishedCount = @(Get-ChildItem -LiteralPath $probe -Filter '*-end' -ErrorAction SilentlyContinue).Count
                if (($startedCount - $finishedCount) -ge 2) { break }
                Start-Sleep -Milliseconds 25
            }
        }
        Start-Sleep -Milliseconds 400
        Write-Host 'Passed: 2'
        Write-Host 'Failed: 0'
        Write-Probe 'end'
        exit 0
    }
    '^Tree$' {
        $child = Start-Process -FilePath (Join-Path $PSHOME 'pwsh') -PassThru -WindowStyle Hidden -ArgumentList @(
            '-NoProfile', '-NonInteractive', '-Command', 'Start-Sleep -Seconds 180'
        )
        Write-Probe 'child.pid' ([string]$child.Id)
        Start-Sleep -Seconds 180
        exit 0
    }
    '^Hang$' {
        Start-Sleep -Seconds 180
        exit 0
    }
}
'@

$fixtureConformance = @'
param(
    [ValidateSet('All', 'Protocol')]
    [string]$Suite = 'All'
)
Write-Host "Real runner deterministic adapter conformance ($Suite): PASS"
'@

$fixtureIntegrity = @'
param(
    [ValidateSet('All', 'Bridge')]
    [string]$Suite = 'All'
)
Write-Host "Eval package integrity and finalization: PASS ($Suite)"
'@

function New-FixtureMatrix {
    param([object[]]$Entries)

    $lines = @('matrix:', '  include:')
    foreach ($entry in $Entries) {
        $lines += ('    - {{ name: {0}, script: {1}, suite: {2} }}' -f $entry.Name, $entry.Script, $entry.Suite)
    }
    return ($lines -join [Environment]::NewLine) + [Environment]::NewLine
}

function New-FixtureRepo {
    param(
        [string]$Name,
        [object[]]$Entries
    )

    $repo = Join-Path $root ('repo-' + $Name)
    Write-FixtureFile -Path (Join-Path $repo 'scripts/validate-skill-templates.ps1') -Content $fixtureTemplateValidator
    Write-FixtureFile -Path (Join-Path $repo 'scripts/eval-runners/tests/test-runner-conformance.ps1') -Content $fixtureConformance
    Write-FixtureFile -Path (Join-Path $repo 'scripts/eval-runners/tests/test-integrity-finalization.ps1') -Content $fixtureIntegrity
    $workflow = Join-Path $root ('workflow-' + $Name + '.yml')
    Write-FixtureFile -Path $workflow -Content (New-FixtureMatrix -Entries $Entries)

    return [pscustomobject]@{
        RepositoryRoot = $repo
        WorkflowPath   = $workflow
        OutputRoot     = Join-Path $root ('out-' + $Name)
        ProbeRoot      = Join-Path $root ('probe-' + $Name)
    }
}

function Invoke-Scheduler {
    param(
        [object]$Fixture,
        [int]$MaxConcurrency = 4,
        [int]$TimeoutSeconds = 30,
        [int]$DeadlineSeconds = 0
    )

    $arguments = @(
        '-NoProfile', '-NonInteractive', '-File', $scheduler,
        '-RepositoryRoot', $Fixture.RepositoryRoot,
        '-WorkflowPath', $Fixture.WorkflowPath,
        '-OutputRoot', $Fixture.OutputRoot,
        '-MaxConcurrency', [string]$MaxConcurrency,
        '-TimeoutSeconds', [string]$TimeoutSeconds,
        '-DeadlineSeconds', [string]$DeadlineSeconds
    )

    $previousProbe = $env:VALIDATION_TEST_PROBE_DIR
    $previousErrorAction = $ErrorActionPreference
    $env:VALIDATION_TEST_PROBE_DIR = $Fixture.ProbeRoot
    $ErrorActionPreference = 'Continue'
    try {
        $output = & pwsh @arguments 2>&1
        $exitCode = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $previousErrorAction
        $env:VALIDATION_TEST_PROBE_DIR = $previousProbe
    }

    $summaryPath = Get-ChildItem -LiteralPath $Fixture.OutputRoot -Directory -ErrorAction SilentlyContinue |
        ForEach-Object { Join-Path $_.FullName 'summary.json' } |
        Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } |
        Select-Object -First 1

    $summary = if ($null -ne $summaryPath) {
        [System.IO.File]::ReadAllText($summaryPath, $utf8NoBom) | ConvertFrom-Json -Depth 8
    } else {
        $null
    }

    return [pscustomobject]@{
        ExitCode = $exitCode
        Output   = ($output | ForEach-Object { [string]$_ })
        Summary  = $summary
        Path     = $summaryPath
    }
}

function Get-Result {
    param([object]$Summary, [string]$Name)

    return @($Summary.Results | Where-Object { $_.Name -eq $Name })[0]
}

function Assert-True {
    param([bool]$Condition, [string]$Message)

    if (-not $Condition) {
        throw $Message
    }
}

function Invoke-Case {
    param([string]$Name, [scriptblock]$Body)

    try {
        & $Body
        Write-Host "[PASS] $Name"
    } catch {
        Write-Host "[FAIL] $Name"
        Write-Host "       $($_.Exception.Message)"
        $failures.Add($Name)
    }
}

New-Item -ItemType Directory -Path $root -Force | Out-Null

try {
    Invoke-Case 'all-passing suites report complete verified coverage' {
        $fixture = New-FixtureRepo -Name 'allpass' -Entries @(
            [pscustomobject]@{ Name = 'alpha'; Script = 'scripts/validate-skill-templates.ps1'; Suite = 'Good' }
            [pscustomobject]@{ Name = 'beta'; Script = 'scripts/validate-skill-templates.ps1'; Suite = 'Sleepy' }
            [pscustomobject]@{ Name = 'gamma'; Script = 'scripts/eval-runners/tests/test-runner-conformance.ps1'; Suite = 'Protocol' }
        )
        $result = Invoke-Scheduler -Fixture $fixture -MaxConcurrency 3

        Assert-True -Condition ($result.ExitCode -eq 0) -Message "expected exit 0, got $($result.ExitCode)"
        Assert-True -Condition ($result.Summary.Coverage.Expected -eq 3) -Message 'expected 3 scheduled suites'
        Assert-True -Condition ($result.Summary.Coverage.Executed -eq 3) -Message 'expected 3 executed suites'
        Assert-True -Condition ($result.Summary.Coverage.Passed -eq 3) -Message 'expected 3 passing suites'
        Assert-True -Condition ($result.Summary.Coverage.Verified) -Message 'expected coverage to be marked verified'
        foreach ($name in @('alpha', 'beta', 'gamma')) {
            $entry = Get-Result -Summary $result.Summary -Name $name
            Assert-True -Condition ($entry.Status -eq 'PASS') -Message "expected $name to pass"
            Assert-True -Condition (Test-Path -LiteralPath $entry.Log -PathType Leaf) -Message "expected a log for $name"
        }
    }

    Invoke-Case 'a failing suite fails the run without cancelling the others' {
        $fixture = New-FixtureRepo -Name 'failure' -Entries @(
            [pscustomobject]@{ Name = 'alpha'; Script = 'scripts/validate-skill-templates.ps1'; Suite = 'Good' }
            [pscustomobject]@{ Name = 'beta'; Script = 'scripts/validate-skill-templates.ps1'; Suite = 'Bad' }
            [pscustomobject]@{ Name = 'gamma'; Script = 'scripts/validate-skill-templates.ps1'; Suite = 'Sleepy' }
        )
        $result = Invoke-Scheduler -Fixture $fixture -MaxConcurrency 3

        Assert-True -Condition ($result.ExitCode -eq 1) -Message 'expected a non-zero exit'
        Assert-True -Condition ((Get-Result -Summary $result.Summary -Name 'beta').Status -eq 'FAIL') -Message 'expected the failing suite to be reported FAIL'
        Assert-True -Condition ((Get-Result -Summary $result.Summary -Name 'alpha').Status -eq 'PASS') -Message 'expected the independent suite to still pass'
        Assert-True -Condition ((Get-Result -Summary $result.Summary -Name 'gamma').Status -eq 'PASS') -Message 'expected the independent suite to still pass'
        Assert-True -Condition ($result.Summary.Coverage.Verified -eq $false) -Message 'coverage must not be reported verified'
    }

    Invoke-Case 'a suite that exits zero without its terminal markers is not a pass' {
        $fixture = New-FixtureRepo -Name 'silent' -Entries @(
            [pscustomobject]@{ Name = 'silent'; Script = 'scripts/validate-skill-templates.ps1'; Suite = 'Silent' }
        )
        $result = Invoke-Scheduler -Fixture $fixture -MaxConcurrency 1

        Assert-True -Condition ($result.ExitCode -eq 1) -Message 'expected silent skipping to fail the run'
        $entry = Get-Result -Summary $result.Summary -Name 'silent'
        Assert-True -Condition ($entry.Status -eq 'FAIL') -Message 'expected FAIL for a suite with no terminal marker'
        Assert-True -Condition ($entry.Verified -eq $false) -Message 'expected the suite to be unverified'
    }

    Invoke-Case 'a suite that reports a skipped check is not a pass' {
        $fixture = New-FixtureRepo -Name 'skipped' -Entries @(
            [pscustomobject]@{ Name = 'skipped'; Script = 'scripts/validate-skill-templates.ps1'; Suite = 'Skip' }
        )
        $result = Invoke-Scheduler -Fixture $fixture -MaxConcurrency 1

        Assert-True -Condition ($result.ExitCode -eq 1) -Message 'expected a skipped suite to fail the run'
        Assert-True -Condition ((Get-Result -Summary $result.Summary -Name 'skipped').Status -eq 'FAIL') -Message 'expected FAIL for a skipped suite'
    }

    Invoke-Case 'a hanging suite times out and its process tree is killed' {
        $fixture = New-FixtureRepo -Name 'timeout' -Entries @(
            [pscustomobject]@{ Name = 'longrunner'; Script = 'scripts/validate-skill-templates.ps1'; Suite = 'Tree' }
            [pscustomobject]@{ Name = 'alpha'; Script = 'scripts/validate-skill-templates.ps1'; Suite = 'Good' }
        )
        $started = [DateTimeOffset]::UtcNow
        $result = Invoke-Scheduler -Fixture $fixture -MaxConcurrency 2 -TimeoutSeconds 3
        $elapsed = ([DateTimeOffset]::UtcNow - $started).TotalSeconds

        Assert-True -Condition ($result.ExitCode -eq 1) -Message 'expected a timeout to fail the run'
        $entry = Get-Result -Summary $result.Summary -Name 'longrunner'
        Assert-True -Condition ($entry.Status -eq 'TIMEOUT') -Message "expected TIMEOUT, got $($entry.Status)"
        Assert-True -Condition ($result.Summary.Coverage.TimedOut -eq 1) -Message 'expected one timed-out suite'
        Assert-True -Condition ($elapsed -lt 30) -Message "timeout was not enforced promptly ($elapsed seconds)"
        Assert-True -Condition ((Get-Result -Summary $result.Summary -Name 'alpha').Status -eq 'PASS') -Message 'expected the healthy suite to complete'

        $childPidFile = Join-Path $fixture.ProbeRoot 'Tree-child.pid'
        Assert-True -Condition (Test-Path -LiteralPath $childPidFile -PathType Leaf) -Message 'expected the fixture to record its grandchild process'
        $childPid = [int]([System.IO.File]::ReadAllText($childPidFile))
        $survivor = $true
        for ($attempt = 0; $attempt -lt 40 -and $survivor; $attempt++) {
            Start-Sleep -Milliseconds 100
            $survivor = $null -ne (Get-Process -Id $childPid -ErrorAction SilentlyContinue)
        }
        Assert-True -Condition (-not $survivor) -Message "grandchild process $childPid survived the timeout"
    }

    Invoke-Case 'a deadline cancels the run, reports survivors, and still writes a summary' {
        $fixture = New-FixtureRepo -Name 'deadline' -Entries @(
            [pscustomobject]@{ Name = 'alpha'; Script = 'scripts/validate-skill-templates.ps1'; Suite = 'Hang' }
            [pscustomobject]@{ Name = 'beta'; Script = 'scripts/validate-skill-templates.ps1'; Suite = 'Hang' }
            [pscustomobject]@{ Name = 'gamma'; Script = 'scripts/validate-skill-templates.ps1'; Suite = 'Hang' }
        )
        $result = Invoke-Scheduler -Fixture $fixture -MaxConcurrency 1 -TimeoutSeconds 60 -DeadlineSeconds 3

        Assert-True -Condition ($result.ExitCode -eq 1) -Message 'expected a cancelled run to fail'
        Assert-True -Condition ($result.Summary.Interrupted) -Message 'expected the summary to record the interruption'
        Assert-True -Condition ($result.Summary.Coverage.Expected -eq 3) -Message 'expected all scheduled suites to be accounted for'
        Assert-True -Condition ($result.Summary.Coverage.Passed -eq 0) -Message 'no suite may be reported as passing'
        Assert-True -Condition (-not $result.Summary.Coverage.Verified) -Message 'an incomplete run must not be verified'
        Assert-True -Condition (@($result.Summary.Results).Count -eq 3) -Message 'expected one result row per scheduled suite'
        Assert-True -Condition (@($result.Summary.Results | Where-Object { $_.Status -eq 'NOT RUN' }).Count -ge 1) -Message 'expected at least one suite to be reported as not run'
    }

    Invoke-Case 'concurrency is bounded and independent suites actually overlap' {
        $fixture = New-FixtureRepo -Name 'concurrency' -Entries @(
            [pscustomobject]@{ Name = 'omega1'; Script = 'scripts/validate-skill-templates.ps1'; Suite = 'SlowA' }
            [pscustomobject]@{ Name = 'omega2'; Script = 'scripts/validate-skill-templates.ps1'; Suite = 'SlowB' }
            [pscustomobject]@{ Name = 'omega3'; Script = 'scripts/validate-skill-templates.ps1'; Suite = 'SlowC' }
            [pscustomobject]@{ Name = 'omega4'; Script = 'scripts/validate-skill-templates.ps1'; Suite = 'SlowD' }
        )
        $result = Invoke-Scheduler -Fixture $fixture -MaxConcurrency 2 -TimeoutSeconds 30

        Assert-True -Condition ($result.ExitCode -eq 0) -Message 'expected the bounded run to pass'

        $intervals = foreach ($suite in @('SlowA', 'SlowB', 'SlowC', 'SlowD')) {
            $startPath = Join-Path $fixture.ProbeRoot "$suite-start"
            $endPath = Join-Path $fixture.ProbeRoot "$suite-end"
            Assert-True -Condition ((Test-Path -LiteralPath $startPath) -and (Test-Path -LiteralPath $endPath)) -Message "expected $suite to record a run interval"
            [pscustomobject]@{
                Start = [long]([System.IO.File]::ReadAllText($startPath))
                End   = [long]([System.IO.File]::ReadAllText($endPath))
            }
        }
        Assert-True -Condition (@($intervals).Count -eq 4) -Message 'expected four run intervals'

        # Reconstruct the maximum number of suites that were executing at the same instant.
        $events = foreach ($interval in $intervals) {
            [pscustomobject]@{ At = $interval.Start; Delta = 1 }
            [pscustomobject]@{ At = $interval.End; Delta = -1 }
        }
        $running = 0
        $maxOverlap = 0
        foreach ($event in @($events | Sort-Object At, Delta)) {
            $running += $event.Delta
            if ($running -gt $maxOverlap) { $maxOverlap = $running }
        }

        Assert-True -Condition ($maxOverlap -le 2) -Message "concurrency bound was exceeded (observed $maxOverlap)"
        Assert-True -Condition ($maxOverlap -ge 2) -Message "independent suites never overlapped (observed $maxOverlap)"
        foreach ($interval in $intervals) {
            $duration = [Math]::Round(($interval.End - $interval.Start) / 1000.0, 2)
            Assert-True -Condition ($duration -ge 0.35) -Message "expected the fixture to honour its programmed duration (got $duration)"
        }
        Assert-True -Condition (@($result.Summary.Results | Where-Object { $_.Seconds -lt 0 }).Count -eq 0) -Message 'suite timings must be non-negative'
    }

    Invoke-Case 'output inside the repository is refused outside .bot' {
        $fixture = New-FixtureRepo -Name 'guard' -Entries @(
            [pscustomobject]@{ Name = 'alpha'; Script = 'scripts/validate-skill-templates.ps1'; Suite = 'Good' }
        )
        $repoRoot = Resolve-Path (Join-Path $PSScriptRoot '..\..')
        $output = & pwsh -NoProfile -NonInteractive -File $scheduler `
            -RepositoryRoot $repoRoot.Path `
            -OutputRoot (Join-Path $repoRoot.Path 'scripts/validate-local-output') 2>&1
        $exitCode = $LASTEXITCODE

        Assert-True -Condition ($exitCode -ne 0) -Message 'expected an unauthorized output root to be refused'
        Assert-True -Condition ((($output | ForEach-Object { [string]$_ }) -join ' ') -match 'must stay under') -Message 'expected an explanatory refusal message'
    }

    Invoke-Case 'matrix problems are rejected before any suite runs' {
        $duplicate = New-FixtureRepo -Name 'duplicate' -Entries @(
            [pscustomobject]@{ Name = 'alpha'; Script = 'scripts/validate-skill-templates.ps1'; Suite = 'Good' }
            [pscustomobject]@{ Name = 'alpha'; Script = 'scripts/validate-skill-templates.ps1'; Suite = 'Slow' }
        )
        $duplicateRun = Invoke-Scheduler -Fixture $duplicate -MaxConcurrency 2
        Assert-True -Condition ($duplicateRun.ExitCode -ne 0) -Message 'expected duplicate suite names to be rejected'
        Assert-True -Condition ($null -eq $duplicateRun.Summary) -Message 'no summary should be produced for an invalid matrix'

        $missing = New-FixtureRepo -Name 'missing' -Entries @(
            [pscustomobject]@{ Name = 'ghost'; Script = 'scripts/does-not-exist.ps1'; Suite = 'Good' }
        )
        $missingRun = Invoke-Scheduler -Fixture $missing -MaxConcurrency 1
        Assert-True -Condition ($missingRun.ExitCode -ne 0) -Message 'expected a missing script to be rejected'

        $emptyRoot = Join-Path $root 'empty'
        New-Item -ItemType Directory -Path $emptyRoot -Force | Out-Null
        $emptyWorkflow = Join-Path $root 'workflow-empty.yml'
        Write-FixtureFile -Path $emptyWorkflow -Content ("matrix:" + [Environment]::NewLine + "  include: []" + [Environment]::NewLine)
        $emptyOutput = & pwsh -NoProfile -NonInteractive -File $scheduler -RepositoryRoot $emptyRoot -WorkflowPath $emptyWorkflow -OutputRoot (Join-Path $root 'out-empty') 2>&1
        Assert-True -Condition ($LASTEXITCODE -ne 0) -Message 'expected an empty matrix to be rejected'
        Assert-True -Condition ((($emptyOutput | ForEach-Object { [string]$_ }) -join ' ') -match 'no suite entries') -Message 'expected an explanatory empty-matrix message'
    }

    Invoke-Case 'the matrix matches the checked-in CI workflow' {
        $repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
        $listed = & pwsh -NoProfile -NonInteractive -File $scheduler -RepositoryRoot $repoRoot -ListSuites 2>&1
        Assert-True -Condition ($LASTEXITCODE -eq 0) -Message 'expected suite listing to succeed'
        $entries = @($listed | Where-Object { [string]$_ -match ' -> ' })
        Assert-True -Condition ($entries.Count -ge 1) -Message 'expected at least one CI suite'
        foreach ($entry in $entries) {
            $parts = [string]$entry -split ' -> '
            $scriptArguments = $parts[1] -split ' -Suite '
            $scriptPath = Join-Path $repoRoot $scriptArguments[0]
            Assert-True -Condition (Test-Path -LiteralPath $scriptPath -PathType Leaf) -Message "missing scheduled script $($scriptArguments[0])"
        }
    }
} finally {
    if (Test-Path -LiteralPath $root) {
        Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
    }
}

if ($failures.Count -gt 0) {
    Write-Host ''
    Write-Host ("Failed cases: {0}" -f ($failures -join ', '))
    exit 1
}

Write-Host ''
Write-Host 'Local validation scheduler: PASS'
