<#!
.SYNOPSIS
    Deterministic, model-free tests for console progress coalescing.

.DESCRIPTION
    Proves that nested relay progress coalesces correctly at the human operator
    rendering boundary without modifying the structured JSONL evidence stream.
    All tests use synthetic child processes and are model-free, network-free,
    and authentication-free. No test may hang: every scenario is bounded.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$runnerRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
. (Join-Path $runnerRoot 'runner-common.ps1')
. (Join-Path $runnerRoot 'runner-progress.ps1')
. (Join-Path $runnerRoot 'fanout-process.ps1')

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw "ASSERT: $Message" }
}

function Assert-Equal {
    param([object]$Expected, [object]$Actual, [string]$Message)
    if ([string]$Expected -ne [string]$Actual) { throw "ASSERT: $Message (expected '$Expected', got '$Actual')" }
}

$pwshPath = [string]((Get-Command pwsh -CommandType Application -ErrorAction Stop | Select-Object -First 1).Source)
$testRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('agentic-coalescing-' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $testRoot -Force | Out-Null
Initialize-RunnerActivityType

function New-SyntheticScript {
    param([Parameter(Mandatory = $true)][string]$Name, [Parameter(Mandatory = $true)][string]$Body)
    $path = Join-Path $testRoot ($Name + '.ps1')
    [System.IO.File]::WriteAllText($path, $Body, [System.Text.UTF8Encoding]::new($false))
    return $path
}

function Invoke-CoalescingChild {
    <#
      Runs one synthetic child through the process primitive and returns the
      captured operator STDERR (human console lines), the JSONL events, and the
      exit code.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$ScriptPath,
        [Parameter(Mandatory = $true)][string]$WorkerId,
        [int]$TimeoutSeconds = 30,
        [double]$HeartbeatSeconds = 0.25
    )

    $workDirectory = Join-Path $testRoot ('work-' + [Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $workDirectory -Force | Out-Null
    $stdoutPath = Join-Path $workDirectory 'result.json'
    $stderrPath = Join-Path $workDirectory 'child.stderr'
    $logPath = Join-Path $workDirectory 'progress.jsonl'
    $operatorErrorWriter = [System.IO.StringWriter]::new([Globalization.CultureInfo]::InvariantCulture)
    $originalErrorWriter = [Console]::Error
    try {
        [Console]::SetError($operatorErrorWriter)
        $child = Start-RunnerChildProcess -FilePath $pwshPath -ArgumentList @('-NoProfile', '-File', $ScriptPath) -WorkingDirectory $workDirectory -StdoutPath $stdoutPath -StderrPath $stderrPath -TimeoutSeconds $TimeoutSeconds -Runner 'relay-test' -WorkerId $WorkerId -EvalId 1 -Configuration 'with_skill' -Phase 'model-cli' -ProgressLogPath $logPath -HeartbeatSeconds $HeartbeatSeconds
        $running = [System.Collections.Generic.List[object]]::new()
        $running.Add([pscustomobject]@{ worker_id = $WorkerId; child = $child; Process = $child.Process })
        [void](Wait-AnyRunnerChild -Running $running)
        $exitCode = Complete-RunnerChildProcess -Child $child
    } finally {
        try { [Console]::Error.Flush() } catch { }
        [Console]::SetError($originalErrorWriter)
    }
    $events = @()
    if (Test-Path -LiteralPath $logPath -PathType Leaf) {
        $events = @(Get-Content -LiteralPath $logPath | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | ForEach-Object { $_ | ConvertFrom-Json })
    }
    $operatorLines = @(([string]$operatorErrorWriter.ToString()) -split "`r?`n" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    return [pscustomobject]@{
        ExitCode = $exitCode
        Events = $events
        OperatorLines = $operatorLines
        LogPath = $logPath
    }
}

function Get-ParentPeriodicLines {
    <# Parent periodic heartbeat lines (running state, no special detail). #>
    param([string[]]$Lines)
    return @($Lines | Where-Object { ($_ -match '\brelay-test\b') -and ($_ -match ' running ') -and (-not ($_ -match '\(relay\)')) -and (-not ($_ -match 'process launched|first\s+\w+\s+activity|process exited|watchdog')) })
}

function Get-RelayConsoleLines {
    <# Relay events visible on the console (have '(relay)' in text). #>
    param([string[]]$Lines)
    return @($Lines | Where-Object { ($_ -match '\brelay-test\b') -and ($_ -match '\(relay\)') })
}

function Get-ParentPeriodicLogEvents {
    <# Parent periodic heartbeat events in JSONL (origin=parent, state=running). #>
    param([object[]]$Events)
    return @($Events | Where-Object { [string]$_.state -eq 'running' -and [string]$_.origin -eq 'parent' })
}

function Get-RelayLogEvents {
    <# Relay events in JSONL (origin=relay). #>
    param([object[]]$Events)
    return @($Events | Where-Object { [string]$_.origin -eq 'relay' })
}

function Invoke-CapturedHeartbeatTick {
    param([Parameter(Mandatory = $true)][object]$Child)

    $operatorErrorWriter = [System.IO.StringWriter]::new([Globalization.CultureInfo]::InvariantCulture)
    $originalErrorWriter = [Console]::Error
    try {
        [Console]::SetError($operatorErrorWriter)
        Invoke-RunnerChildHeartbeatTick -Child $Child
    } finally {
        try { [Console]::Error.Flush() } catch { }
        [Console]::SetError($originalErrorWriter)
    }

    return @(($operatorErrorWriter.ToString() -split "`r?`n") | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
}

try {
    # ------------------------------------------------------------------
    # Test 1 - Meaningful transitions always visible: start, first activity,
    # completion, and state transitions remain on the console regardless of
    # relay activity.
    # ------------------------------------------------------------------
    $transitionScript = New-SyntheticScript -Name 'transitions' -Body @'
for ($i = 0; $i -lt 6; $i++) {
    [Console]::Error.WriteLine("@@AGENTIC-PROGRESS@@ {""state"":""running"",""phase"":""relay-test"",""turn"":$i}")
    Start-Sleep -Milliseconds 80
}
[Console]::Out.Write('{"status":"completed"}')
'@
    $transition = Invoke-CoalescingChild -ScriptPath $transitionScript -WorkerId 'arm-1-transition' -HeartbeatSeconds 0.25
    Assert-Equal 0 $transition.ExitCode 'Test 1: transition child exits cleanly'
    $launchLine = @($transition.OperatorLines | Where-Object { $_ -match 'process launched' })
    Assert-True ($launchLine.Count -ge 1) 'Test 1: "process launched" start event is always visible on console'
    $completedLine = @($transition.OperatorLines | Where-Object { $_ -match 'process exited' })
    Assert-True ($completedLine.Count -ge 1) 'Test 1: "process exited" completion event is always visible on console'
    $relayLines = @(Get-RelayConsoleLines -Lines $transition.OperatorLines)
    Assert-True ($relayLines.Count -ge 4) "Test 1: relay events are visible on console (got $($relayLines.Count))"

    # ------------------------------------------------------------------
    # Test 2 - Quiet worker liveness: a genuinely quiet child with no relay
    # still produces periodic parent heartbeat lines on the console.
    # ------------------------------------------------------------------
    $quietScript = New-SyntheticScript -Name 'quiet-coalesce' -Body @'
Start-Sleep -Milliseconds 1200
[Console]::Out.Write('{"status":"completed"}')
'@
    $quiet = Invoke-CoalescingChild -ScriptPath $quietScript -WorkerId 'arm-2-quiet' -HeartbeatSeconds 0.25
    Assert-Equal 0 $quiet.ExitCode 'Test 2: quiet child exits cleanly'
    $quietParentLines = @(Get-ParentPeriodicLines -Lines $quiet.OperatorLines)
    Assert-True ($quietParentLines.Count -ge 2) "Test 2: quiet worker still emits parent periodic heartbeats on console (got $($quietParentLines.Count))"
    $quietRelayLines = @(Get-RelayConsoleLines -Lines $quiet.OperatorLines)
    Assert-Equal 0 $quietRelayLines.Count 'Test 2: quiet worker has no relay lines on console'

    # ------------------------------------------------------------------
    # Test 3 - Active relay coalescing: when a nested relay is producing
    # frequent progress, parent periodic heartbeat lines are suppressed from
    # the console but remain in the JSONL evidence.
    # ------------------------------------------------------------------
    $activeRelayScript = New-SyntheticScript -Name 'active-relay' -Body @'
for ($i = 0; $i -lt 14; $i++) {
    [Console]::Error.WriteLine("@@AGENTIC-PROGRESS@@ {""state"":""running"",""phase"":""relay-test"",""turn"":$i}")
    Start-Sleep -Milliseconds 80
}
[Console]::Out.Write('{"status":"completed"}')
'@
    $activeRelay = Invoke-CoalescingChild -ScriptPath $activeRelayScript -WorkerId 'arm-3-active-relay' -HeartbeatSeconds 0.25
    Assert-Equal 0 $activeRelay.ExitCode 'Test 3: active relay child exits cleanly'
    $activeRelayConsoleLines = @(Get-RelayConsoleLines -Lines $activeRelay.OperatorLines)
    Assert-True ($activeRelayConsoleLines.Count -ge 8) "Test 3: relay events appear on console (got $($activeRelayConsoleLines.Count))"
    # The async child reader can be delayed by host load. Heartbeats emitted
    # before its first relay is observed are correct, so test the policy below
    # with controlled activity timestamps instead of asserting a wall-clock line
    # count for this subprocess scenario.
    $activeParentLogEvents = @(Get-ParentPeriodicLogEvents -Events $activeRelay.Events)
    $activeRelayLogEvents = @(Get-RelayLogEvents -Events $activeRelay.Events)
    Assert-True ($activeParentLogEvents.Count -ge 2) "Test 3: parent periodic events are retained in JSONL (got $($activeParentLogEvents.Count))"
    Assert-True ($activeRelayLogEvents.Count -ge 8) "Test 3: relay events in JSONL (got $($activeRelayLogEvents.Count))"

    # Test 3b - Deterministic coalescing policy: a recent relay suppresses only
    # the console heartbeat while retaining JSONL evidence; once relay activity
    # is stale, the parent heartbeat is visible again.
    $policyStartedUtc = [DateTime]::UtcNow.AddSeconds(-5)
    $policyLogPath = Join-Path $testRoot 'coalescing-policy.jsonl'
    $policyChild = [pscustomobject]@{
        Runner = 'relay-test'
        WorkerId = 'arm-3-policy'
        EvalId = 1
        Configuration = 'with_skill'
        ProcessId = 12345
        Phase = 'model-cli'
        Turn = $null
        ProgressLogPath = $policyLogPath
        HeartbeatSeconds = 0.25
        ProgressEnabled = $true
        StartedUtc = $policyStartedUtc
        DeadlineUtc = $policyStartedUtc.AddSeconds(30)
        StdoutActivity = $null
        StderrActivity = $null
        LastHeartbeatUtc = [DateTime]::UtcNow.AddSeconds(-1)
        LastRelayActivityUtc = [DateTime]::UtcNow
        FirstStdoutSeen = $true
        FirstStderrSeen = $true
        LifecycleState = 'running'
    }
    $recentRelayConsoleLines = @(Invoke-CapturedHeartbeatTick -Child $policyChild)
    Assert-Equal 0 $recentRelayConsoleLines.Count 'Test 3b: recent relay activity suppresses the console heartbeat'
    $recentRelayLogEvents = @(Get-Content -LiteralPath $policyLogPath | ForEach-Object { $_ | ConvertFrom-Json })
    $recentRelayParentEvents = @(Get-ParentPeriodicLogEvents -Events $recentRelayLogEvents)
    Assert-Equal 1 $recentRelayParentEvents.Count 'Test 3b: suppressed heartbeat remains in JSONL'

    $policyChild.LastHeartbeatUtc = [DateTime]::UtcNow.AddSeconds(-1)
    $policyChild.LastRelayActivityUtc = [DateTime]::UtcNow.AddSeconds(-1)
    $staleRelayConsoleLines = @(Invoke-CapturedHeartbeatTick -Child $policyChild)
    $staleRelayParentLines = @(Get-ParentPeriodicLines -Lines $staleRelayConsoleLines)
    Assert-Equal 1 $staleRelayParentLines.Count 'Test 3b: heartbeat resumes on the console after relay activity goes stale'
    $allPolicyLogEvents = @(Get-Content -LiteralPath $policyLogPath | ForEach-Object { $_ | ConvertFrom-Json })
    $allPolicyParentEvents = @(Get-ParentPeriodicLogEvents -Events $allPolicyLogEvents)
    Assert-Equal 2 $allPolicyParentEvents.Count 'Test 3b: visible heartbeat also remains in JSONL'

    # ------------------------------------------------------------------
    # Test 4 - Relay stops, parent resumes: after relay goes quiet, parent
    # periodic heartbeat lines must resume on the console.
    # ------------------------------------------------------------------
    $relayThenQuietScript = New-SyntheticScript -Name 'relay-then-quiet' -Body @'
# Phase 1: relay active for ~500ms (6 events at 80ms intervals).
for ($i = 0; $i -lt 6; $i++) {
    [Console]::Error.WriteLine("@@AGENTIC-PROGRESS@@ {""state"":""running"",""phase"":""relay-phase"",""turn"":$i}")
    Start-Sleep -Milliseconds 80
}
# Phase 2: relay stops, worker stays alive.
Start-Sleep -Milliseconds 700
[Console]::Out.Write('{"status":"completed"}')
'@
    $relayThenQuiet = Invoke-CoalescingChild -ScriptPath $relayThenQuietScript -WorkerId 'arm-4-relay-then-quiet' -HeartbeatSeconds 0.25
    Assert-Equal 0 $relayThenQuiet.ExitCode 'Test 4: relay-then-quiet child exits cleanly'
    $rtqParentLines = @(Get-ParentPeriodicLines -Lines $relayThenQuiet.OperatorLines)
    $rtqRelayLines = @(Get-RelayConsoleLines -Lines $relayThenQuiet.OperatorLines)
    Assert-True ($rtqRelayLines.Count -ge 4) "Test 4: relay phase events visible on console (got $($rtqRelayLines.Count))"
    Assert-True ($rtqParentLines.Count -ge 1) "Test 4: parent periodic heartbeats resume on console after relay stops (got $($rtqParentLines.Count))"

    # ------------------------------------------------------------------
    # Test 5 - Terminal events never suppressed: completion, failure, and
    # timeout diagnostic lines must always appear on the console regardless
    # of relay activity.
    # ------------------------------------------------------------------
    # Completion (relay active up to exit)
    $activeRelayCompleteScript = New-SyntheticScript -Name 'active-relay-complete' -Body @'
for ($i = 0; $i -lt 10; $i++) {
    [Console]::Error.WriteLine("@@AGENTIC-PROGRESS@@ {""state"":""running"",""phase"":""relay-test"",""turn"":$i}")
    Start-Sleep -Milliseconds 80
}
[Console]::Out.Write('{"status":"completed"}')
'@
    $terminalComplete = Invoke-CoalescingChild -ScriptPath $activeRelayCompleteScript -WorkerId 'arm-5-complete' -HeartbeatSeconds 0.25
    Assert-Equal 0 $terminalComplete.ExitCode 'Test 5: active-relay-complete exits cleanly'
    Assert-True (@($terminalComplete.OperatorLines | Where-Object { $_ -match 'process exited' }).Count -ge 1) 'Test 5: completion diagnostic always visible even during active relay'

    # Failure (relay active up to exit)
    $activeRelayFailScript = New-SyntheticScript -Name 'active-relay-fail' -Body @'
for ($i = 0; $i -lt 8; $i++) {
    [Console]::Error.WriteLine("@@AGENTIC-PROGRESS@@ {""state"":""running"",""phase"":""relay-test"",""turn"":$i}")
    Start-Sleep -Milliseconds 80
}
exit 7
'@
    $terminalFail = Invoke-CoalescingChild -ScriptPath $activeRelayFailScript -WorkerId 'arm-5-fail' -HeartbeatSeconds 0.25
    Assert-Equal 7 $terminalFail.ExitCode 'Test 5: active-relay-fail exits with correct code'
    Assert-True (@($terminalFail.OperatorLines | Where-Object { $_ -match 'failed|exitCode=7' }).Count -ge 1) 'Test 5: failure diagnostic always visible even during active relay'

    # Timeout (relay active during timeout)
    $activeRelayHangScript = New-SyntheticScript -Name 'active-relay-hang' -Body @'
for ($i = 0; $i -lt 1000; $i++) {
    [Console]::Error.WriteLine("@@AGENTIC-PROGRESS@@ {""state"":""running"",""phase"":""relay-test"",""turn"":$i}")
    Start-Sleep -Milliseconds 80
}
'@
    $terminalTimeout = Invoke-CoalescingChild -ScriptPath $activeRelayHangScript -WorkerId 'arm-5-timeout' -TimeoutSeconds 2 -HeartbeatSeconds 0.25
    Assert-True (@($terminalTimeout.Events).Count -gt 0) 'Test 5: timeout child produced events'
    Assert-True (@($terminalTimeout.OperatorLines | Where-Object { $_ -match 'timed-out|terminating|terminationObserved' }).Count -ge 1) 'Test 5: timeout diagnostic always visible even during active relay'

    # ------------------------------------------------------------------
    # Test 6 - Structured JSONL completeness: both parent and relay events
    # are present in the JSONL even when the console shows fewer lines.
    # ------------------------------------------------------------------
    $jsonlCompletenessScript = New-SyntheticScript -Name 'jsonl-completeness' -Body @'
for ($i = 0; $i -lt 12; $i++) {
    [Console]::Error.WriteLine("@@AGENTIC-PROGRESS@@ {""state"":""running"",""phase"":""relay-test"",""turn"":$i}")
    Start-Sleep -Milliseconds 80
}
[Console]::Out.Write('{"status":"completed"}')
'@
    $jsonlTest = Invoke-CoalescingChild -ScriptPath $jsonlCompletenessScript -WorkerId 'arm-6-jsonl' -HeartbeatSeconds 0.25
    Assert-Equal 0 $jsonlTest.ExitCode 'Test 6: JSONL completeness child exits cleanly'
    $jsonlParentEvents = @(Get-ParentPeriodicLogEvents -Events $jsonlTest.Events)
    $jsonlRelayEvents = @(Get-RelayLogEvents -Events $jsonlTest.Events)
    $jsonlConsoleParentLines = @(Get-ParentPeriodicLines -Lines $jsonlTest.OperatorLines)
    Assert-True ($jsonlParentEvents.Count -ge 2) "Test 6: parent periodic events in JSONL (got $($jsonlParentEvents.Count))"
    Assert-True ($jsonlRelayEvents.Count -ge 8) "Test 6: relay events in JSONL (got $($jsonlRelayEvents.Count))"
    Assert-True ($jsonlParentEvents.Count -gt $jsonlConsoleParentLines.Count) "Test 6: JSONL has more parent events than human console rendered (JSONL=$($jsonlParentEvents.Count), console=$($jsonlConsoleParentLines.Count))"
    # All JSONL events must have timestamps and worker attribution.
    $unatributed = @($jsonlTest.Events | Where-Object { [string]::IsNullOrWhiteSpace([string]$_.worker) })
    Assert-Equal 0 $unatributed.Count 'Test 6: every JSONL event has worker attribution'
    $noTimestamp = @($jsonlTest.Events | Where-Object { [string]::IsNullOrWhiteSpace([string]$_.ts) })
    Assert-Equal 0 $noTimestamp.Count 'Test 6: every JSONL event has a timestamp'

    Write-Output 'Progress coalescing: PASS'
} finally {
    if (Test-Path -LiteralPath $testRoot) {
        Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}
