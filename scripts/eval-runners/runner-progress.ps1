<#!
.SYNOPSIS
    Shared live-observability primitives for every eval runner.

.DESCRIPTION
    The runner-owned fan-out and the shared process primitives can run for a long
    time while producing no terminal result yet. Without live feedback a slow but
    healthy runner is indistinguishable from a hung one. This module centralizes
    that observability so every runner inherits it automatically:

      * a mandatory heartbeat cadence for actively running work,
      * a small generic lifecycle vocabulary,
      * a byte/line activity tracker that tees captured output to its evidence
        file while exposing safe activity metadata (counts, last-activity age)
        and relaying structured child progress,
      * a single STDERR-only progress writer that never contaminates the machine
        readable STDOUT protocol and never prints secrets or model content.

    STDOUT is reserved for the machine protocol. Everything here writes to STDERR
    and, when configured, appends structured JSON to a persisted progress log so a
    failed or detached run can be inspected afterwards. This file is dot-sourced
    by runner-common.ps1, fanout-process.ps1, and the orchestration tests. It
    never invokes a model.
#>
Set-StrictMode -Version Latest

# Recognizable, ASCII-only marker a child process writes to its own STDERR so a
# parent that captures that STDERR can relay the structured event without echoing
# arbitrary model output. Kept deliberately distinctive and stable.
$script:RunnerProgressSentinel = '@@AGENTIC-PROGRESS@@'

# Generic lifecycle vocabulary shared by all runners. Adapts existing concepts;
# it is a labeling vocabulary, not a state machine.
$script:RunnerProgressStates = @(
    'queued', 'preflight', 'starting', 'running', 'active', 'idle',
    'completing', 'completed', 'failed', 'timed-out', 'terminating', 'terminated'
)

function Get-RunnerProgressSentinel {
    return $script:RunnerProgressSentinel
}

function Get-RunnerHeartbeatIntervalSeconds {
    <#
      No actively running arm should stay externally silent longer than this.
      Defaults to ~15 seconds; tests may shorten it (fractions allowed) through
      AGENTIC_RUNNER_HEARTBEAT_SECONDS so they stay fast and deterministic.
    #>
    $override = [Environment]::GetEnvironmentVariable('AGENTIC_RUNNER_HEARTBEAT_SECONDS')
    if (-not [string]::IsNullOrWhiteSpace($override)) {
        $parsed = 0.0
        if ([double]::TryParse($override, [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$parsed) -and $parsed -gt 0) {
            return [Math]::Max(0.05, $parsed)
        }
    }
    return 15.0
}

function Format-RunnerElapsed {
    param([double]$Seconds)

    if ($Seconds -lt 0) { $Seconds = 0 }
    $span = [TimeSpan]::FromSeconds($Seconds)
    $totalHours = [int][Math]::Floor($span.TotalHours)
    return ('{0:00}:{1:00}:{2:00}' -f $totalHours, $span.Minutes, $span.Seconds)
}

function Initialize-RunnerActivityType {
    <#
      Compiles the counting/relaying stream wrapper once per process. The wrapper
      forwards every byte to the real evidence stream (faithful capture) while
      tracking activity metadata and pulling structured progress lines out of the
      captured stream so they can be relayed without dumping raw output.
    #>
    if (([System.Management.Automation.PSTypeName]'Agentic.RunnerActivityStream').Type) { return }
    $definition = @'
using System;
using System.IO;
using System.Text;
using System.Threading;
using System.Threading.Tasks;
using System.Collections.Concurrent;

namespace Agentic
{
    public sealed class RunnerActivityStream : Stream
    {
        public const string SentinelToken = "@@AGENTIC-PROGRESS@@";
        private static readonly UTF8Encoding Utf8 = new UTF8Encoding(false, false);

        private readonly Stream _inner;
        private readonly bool _classifyProgress;
        private readonly StringBuilder _lineBuffer = new StringBuilder();
        private readonly object _lineLock = new object();
        private readonly ConcurrentQueue<string> _relay = new ConcurrentQueue<string>();

        private long _totalBytes;
        private long _realBytes;
        private long _realEvents;
        private long _progressEvents;
        private long _firstTicks;
        private long _lastRealTicks;

        public RunnerActivityStream(Stream inner, bool classifyProgress)
        {
            if (inner == null) { throw new ArgumentNullException("inner"); }
            _inner = inner;
            _classifyProgress = classifyProgress;
        }

        public long TotalBytes { get { return Interlocked.Read(ref _totalBytes); } }
        public long RealBytes { get { return Interlocked.Read(ref _realBytes); } }
        public long RealEvents { get { return Interlocked.Read(ref _realEvents); } }
        public long ProgressEvents { get { return Interlocked.Read(ref _progressEvents); } }
        public long FirstActivityTicks { get { return Interlocked.Read(ref _firstTicks); } }
        public long LastRealActivityTicks { get { return Interlocked.Read(ref _lastRealTicks); } }

        public bool TryDequeueRelay(out string line) { return _relay.TryDequeue(out line); }

        private void Observe(byte[] buffer, int offset, int count)
        {
            if (count <= 0) { return; }
            Interlocked.Add(ref _totalBytes, count);
            Interlocked.CompareExchange(ref _firstTicks, DateTime.UtcNow.Ticks, 0);
            string text = Utf8.GetString(buffer, offset, count);
            lock (_lineLock)
            {
                _lineBuffer.Append(text);
                int newlineLength;
                int index;
                while ((index = IndexOfNewline(_lineBuffer, out newlineLength)) >= 0)
                {
                    string line = _lineBuffer.ToString(0, index);
                    _lineBuffer.Remove(0, index + newlineLength);
                    ClassifyLine(line);
                }
            }
        }

        private void ClassifyLine(string line)
        {
            string trimmed = line.TrimStart();
            if (_classifyProgress && trimmed.StartsWith(SentinelToken, StringComparison.Ordinal))
            {
                string payload = trimmed.Substring(SentinelToken.Length).TrimStart();
                _relay.Enqueue(payload);
                Interlocked.Increment(ref _progressEvents);
                return;
            }
            if (line.Length == 0) { return; }
            Interlocked.Add(ref _realBytes, Utf8.GetByteCount(line));
            Interlocked.Increment(ref _realEvents);
            Interlocked.Exchange(ref _lastRealTicks, DateTime.UtcNow.Ticks);
        }

        private static int IndexOfNewline(StringBuilder builder, out int newlineLength)
        {
            for (int i = 0; i < builder.Length; i++)
            {
                char c = builder[i];
                if (c == '\n') { newlineLength = 1; return i; }
                if (c == '\r')
                {
                    if (i + 1 < builder.Length && builder[i + 1] == '\n') { newlineLength = 2; return i; }
                    newlineLength = 1;
                    return i;
                }
            }
            newlineLength = 0;
            return -1;
        }

        public void FinalizeActivity()
        {
            lock (_lineLock)
            {
                if (_lineBuffer.Length > 0)
                {
                    string line = _lineBuffer.ToString();
                    _lineBuffer.Clear();
                    ClassifyLine(line);
                }
            }
        }

        public override void Write(byte[] buffer, int offset, int count)
        {
            _inner.Write(buffer, offset, count);
            _inner.Flush();
            Observe(buffer, offset, count);
        }

        public override async Task WriteAsync(byte[] buffer, int offset, int count, CancellationToken cancellationToken)
        {
            await _inner.WriteAsync(buffer, offset, count, cancellationToken).ConfigureAwait(false);
            await _inner.FlushAsync(cancellationToken).ConfigureAwait(false);
            Observe(buffer, offset, count);
        }

        public override async ValueTask WriteAsync(ReadOnlyMemory<byte> buffer, CancellationToken cancellationToken = default(CancellationToken))
        {
            await _inner.WriteAsync(buffer, cancellationToken).ConfigureAwait(false);
            await _inner.FlushAsync(cancellationToken).ConfigureAwait(false);
            byte[] copy = buffer.ToArray();
            Observe(copy, 0, copy.Length);
        }

        public override void Flush() { _inner.Flush(); }
        public override bool CanRead { get { return false; } }
        public override bool CanSeek { get { return false; } }
        public override bool CanWrite { get { return true; } }
        public override long Length { get { return Interlocked.Read(ref _totalBytes); } }
        public override long Position
        {
            get { return Interlocked.Read(ref _totalBytes); }
            set { throw new NotSupportedException(); }
        }
        public override long Seek(long offset, SeekOrigin origin) { throw new NotSupportedException(); }
        public override void SetLength(long value) { throw new NotSupportedException(); }
        public override int Read(byte[] buffer, int offset, int count) { throw new NotSupportedException(); }
    }
}
'@
    Add-Type -TypeDefinition $definition -ErrorAction Stop
}

function New-RunnerActivityStream {
    <#
      Wraps a writable evidence stream. classifyProgress=true pulls sentinel
      progress lines out for relay; use it for a captured STDERR that may carry a
      child's structured progress. A captured STDOUT (the machine result) uses
      classifyProgress=false so its bytes are only ever counted, never echoed.
    #>
    param(
        [Parameter(Mandatory = $true)][System.IO.Stream]$Inner,
        [bool]$ClassifyProgress = $false
    )

    Initialize-RunnerActivityType
    return [Agentic.RunnerActivityStream]::new($Inner, $ClassifyProgress)
}

function Get-RunnerActivityAgeSeconds {
    <#
      Age in seconds of the most recent real (non-progress) output on a wrapped
      stream, or $null when the stream has produced no real output yet.
    #>
    param([object]$ActivityStream)

    if ($null -eq $ActivityStream) { return $null }
    $ticks = [int64]$ActivityStream.LastRealActivityTicks
    if ($ticks -le 0) { return $null }
    return [Math]::Max(0, ([DateTime]::UtcNow - [DateTime]::new($ticks, [DateTimeKind]::Utc)).TotalSeconds)
}

function ConvertTo-RunnerProgressText {
    <#
      Deterministic, side-effect-free renderer for one operator-facing progress
      line. Only known-safe fields are ever emitted; unknown or absent fields are
      skipped. Kept pure so tests can assert formatting without any process.
    #>
    param([Parameter(Mandatory = $true)][hashtable]$Event)

    $parts = [System.Collections.Generic.List[string]]::new()
    $runner = [string](Get-RunnerProgressField -Event $Event -Name 'runner')
    if (-not [string]::IsNullOrWhiteSpace($runner)) { [void]$parts.Add("[$runner]") }
    $worker = [string](Get-RunnerProgressField -Event $Event -Name 'worker')
    if (-not [string]::IsNullOrWhiteSpace($worker)) { [void]$parts.Add("[$worker]") }
    $origin = [string](Get-RunnerProgressField -Event $Event -Name 'origin')
    if ($origin -eq 'relay') { [void]$parts.Add('(relay)') }
    $state = [string](Get-RunnerProgressField -Event $Event -Name 'state')
    if (-not [string]::IsNullOrWhiteSpace($state)) { [void]$parts.Add($state) }

    foreach ($pair in @(
            @{ Name = 'pid'; Label = 'pid' },
            @{ Name = 'elapsed'; Label = 'elapsed' },
            @{ Name = 'timeoutRemaining'; Label = 'timeoutRemaining' },
            @{ Name = 'lastActivity'; Label = 'lastActivity' },
            @{ Name = 'phase'; Label = 'phase' },
            @{ Name = 'turn'; Label = 'turn' },
            @{ Name = 'stdoutEvents'; Label = 'stdoutEvents' },
            @{ Name = 'stderrEvents'; Label = 'stderrEvents' },
            @{ Name = 'stdoutBytes'; Label = 'stdoutBytes' },
            @{ Name = 'stderrBytes'; Label = 'stderrBytes' },
            @{ Name = 'exitCode'; Label = 'exitCode' }
        )) {
        $value = Get-RunnerProgressField -Event $Event -Name $pair.Name
        if ($null -ne $value -and -not [string]::IsNullOrWhiteSpace([string]$value)) {
            [void]$parts.Add(('{0}={1}' -f $pair.Label, [string]$value))
        }
    }
    $terminationRequested = Get-RunnerProgressField -Event $Event -Name 'terminationRequested'
    if ($terminationRequested -is [bool] -and $terminationRequested) { [void]$parts.Add('terminationRequested=true') }
    $terminationObserved = Get-RunnerProgressField -Event $Event -Name 'terminationObserved'
    if ($terminationObserved -is [bool]) { [void]$parts.Add(('terminationObserved={0}' -f ([string]$terminationObserved).ToLowerInvariant())) }
    $outputDrainCompleted = Get-RunnerProgressField -Event $Event -Name 'outputDrainCompleted'
    if ($outputDrainCompleted -is [bool]) { [void]$parts.Add(('outputDrainCompleted={0}' -f ([string]$outputDrainCompleted).ToLowerInvariant())) }
    $detail = [string](Get-RunnerProgressField -Event $Event -Name 'detail')
    if (-not [string]::IsNullOrWhiteSpace($detail)) { [void]$parts.Add("- $detail") }
    return [string]::Join(' ', $parts)
}

function Get-RunnerProgressField {
    param(
        [Parameter(Mandatory = $true)][hashtable]$Event,
        [Parameter(Mandatory = $true)][string]$Name
    )

    if ($Event.ContainsKey($Name)) { return $Event[$Name] }
    return $null
}

function New-RunnerProgressEvent {
    <#
      Assembles an ordered progress event from safe fields only. Never accepts or
      forwards environment values, prompt bytes, credentials, or model output.
    #>
    param([Parameter(Mandatory = $true)][hashtable]$Fields)

    $event = [ordered]@{ ts = [DateTime]::UtcNow.ToString('o') }
    foreach ($name in @(
            'runner', 'worker', 'eval', 'configuration', 'pid', 'state', 'phase',
            'elapsed', 'elapsedSeconds', 'timeoutRemaining', 'timeoutRemainingSeconds',
            'lastActivity', 'lastActivitySeconds', 'stdoutEvents', 'stderrEvents',
            'stdoutBytes', 'stderrBytes', 'turn', 'exitCode', 'terminationRequested',
            'outputDrainCompleted',
            'terminationObserved', 'origin', 'detail'
        )) {
        if ($Fields.ContainsKey($name)) {
            $value = $Fields[$name]
            if ($null -ne $value -and -not ($value -is [string] -and [string]::IsNullOrEmpty($value))) {
                $event[$name] = $value
            }
        }
    }
    return $event
}

function Write-RunnerProgress {
    <#
      Single progress sink. Writes only to STDERR (never STDOUT) and, when a log
      path is configured, appends the structured event as one JSON line for
      post-mortem inspection. Observability must never break execution, so every
      failure here is swallowed.

      Channel:
        Operator  - human-readable line for a foreground/operator STDERR.
        Relayable - sentinel-tagged compact JSON on a child's STDERR so a parent
                    that captures it can relay it verbatim; written as raw UTF-8
                    bytes so the parent's UTF-8 classifier always matches.

      LogOnly - when set, skip the STDERR/console write and only append to the
                JSONL log. Used for structured evidence of parent periodic
                heartbeats that are suppressed from the human console because a
                nested relay is already demonstrating liveness for the worker.
    #>
    param(
        [Parameter(Mandatory = $true)][hashtable]$Fields,
        [string]$LogPath,
        [ValidateSet('Operator', 'Relayable')][string]$Channel = 'Operator',
        [switch]$LogOnly
    )

    if (-not $LogOnly) {
        try {
            $event = New-RunnerProgressEvent -Fields $Fields
            if ($Channel -eq 'Relayable') {
                $compact = ($event | ConvertTo-Json -Depth 20 -Compress)
                $line = $script:RunnerProgressSentinel + ' ' + $compact
                $bytes = [System.Text.UTF8Encoding]::new($false).GetBytes($line + "`n")
                $stderr = [Console]::OpenStandardError()
                $stderr.Write($bytes, 0, $bytes.Length)
                $stderr.Flush()
            } else {
                $hashEvent = @{}
                foreach ($key in $event.Keys) { $hashEvent[$key] = $event[$key] }
                [Console]::Error.WriteLine((ConvertTo-RunnerProgressText -Event $hashEvent))
            }
        } catch { }
    }

    if (-not [string]::IsNullOrWhiteSpace($LogPath)) {
        try {
            $event = New-RunnerProgressEvent -Fields $Fields
            $directory = Split-Path -Parent $LogPath
            if (-not [string]::IsNullOrWhiteSpace($directory) -and -not (Test-Path -LiteralPath $directory)) {
                New-Item -ItemType Directory -Path $directory -Force | Out-Null
            }
            $json = ($event | ConvertTo-Json -Depth 20 -Compress)
            [System.IO.File]::AppendAllText($LogPath, $json + [Environment]::NewLine, [System.Text.UTF8Encoding]::new($false))
        } catch { }
    }
}

function ConvertFrom-RunnerRelayPayload {
    <#
      Parses a relayed sentinel payload back into a field hashtable so a parent can
      re-emit it as an operator line and persist it. Returns $null when the payload
      is not valid JSON, so a corrupt line can never break the relay loop.
    #>
    param([Parameter(Mandatory = $true)][string]$Payload)

    if ([string]::IsNullOrWhiteSpace($Payload)) { return $null }
    try {
        $parsed = $Payload | ConvertFrom-Json -Depth 20
    } catch {
        return $null
    }
    $fields = @{}
    foreach ($property in $parsed.PSObject.Properties) {
        if ($property.Name -eq 'ts') { continue }
        $fields[$property.Name] = $property.Value
    }
    return $fields
}

function Get-RunnerModelProgressContext {
    <#
      Shared opt-in progress context for a runner's model CLI process. Returns a
      relayable context only when the orchestration environment enables progress
      (AGENTIC_RUNNER_PROGRESS), so a runner invoked standalone or under the
      conformance tests stays silent and byte-identical, while a runner launched
      by the fan-out relays live model-process lifecycle and heartbeats through
      its own STDERR for the parent to surface. Never invents runner-specific
      heartbeat, timing, or lifecycle machinery; it only tags the shared one.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$Runner,
        [string]$Phase = 'model-cli'
    )

    $flag = [Environment]::GetEnvironmentVariable('AGENTIC_RUNNER_PROGRESS')
    if ([string]::IsNullOrWhiteSpace($flag)) { return $null }
    if (([string]$flag).Trim().ToLowerInvariant() -notin @('1', 'true', 'yes', 'on')) { return $null }
    return @{ enabled = $true; runner = $Runner; phase = $Phase; channel = 'Relayable' }
}
