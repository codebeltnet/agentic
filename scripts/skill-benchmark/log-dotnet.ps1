param(
    [Parameter(Mandatory = $true)]
    [string]$RealDotnet,

    [Parameter(Mandatory = $true)]
    [string]$LogDirectory,

    [Parameter(Mandatory = $true)]
    [string]$StdoutPath,

    [Parameter(Mandatory = $true)]
    [string]$StderrPath,

    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$Arguments
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$utf8NoBom = [System.Text.UTF8Encoding]::new($false)
[Console]::InputEncoding = $utf8NoBom
[Console]::OutputEncoding = $utf8NoBom
$OutputEncoding = $utf8NoBom

New-Item -ItemType Directory -Path $LogDirectory -Force | Out-Null

$start = [DateTimeOffset]::UtcNow
$stdoutLines = [System.Collections.Generic.List[string]]::new()
$stderrLines = [System.Collections.Generic.List[string]]::new()

$stdoutWriter = [System.IO.StreamWriter]::new($StdoutPath, $false, $utf8NoBom)
$stderrWriter = [System.IO.StreamWriter]::new($StderrPath, $false, $utf8NoBom)

try {
    $psi = [System.Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = $RealDotnet
    $psi.WorkingDirectory = (Get-Location).Path
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    foreach ($argument in @($Arguments)) {
        [void]$psi.ArgumentList.Add($argument)
    }

    $process = [System.Diagnostics.Process]::new()
    $process.StartInfo = $psi
    $process.EnableRaisingEvents = $true

    $process.add_OutputDataReceived({
        param($sender, $eventArgs)

        if ($null -eq $eventArgs.Data) { return }
        $stdoutLines.Add($eventArgs.Data)
        $stdoutWriter.WriteLine($eventArgs.Data)
        [Console]::Out.WriteLine($eventArgs.Data)
    })

    $process.add_ErrorDataReceived({
        param($sender, $eventArgs)

        if ($null -eq $eventArgs.Data) { return }
        $stderrLines.Add($eventArgs.Data)
        $stderrWriter.WriteLine($eventArgs.Data)
        [Console]::Error.WriteLine($eventArgs.Data)
    })

    if (-not $process.Start()) {
        throw "Unable to start '$RealDotnet'."
    }

    $process.BeginOutputReadLine()
    $process.BeginErrorReadLine()
    $process.WaitForExit()
    $process.WaitForExit()

    $end = [DateTimeOffset]::UtcNow
    $duration = [math]::Round(($end - $start).TotalSeconds, 3)
    $command = if (@($Arguments).Count -gt 0) { $Arguments[0] } else { '' }
    $logPath = Join-Path $LogDirectory ('dotnet-' + $start.ToUnixTimeMilliseconds() + '.json')

    [ordered]@{
        startedAt = $start.ToString('O')
        endedAt = $end.ToString('O')
        durationSeconds = $duration
        workingDirectory = (Get-Location).Path
        realDotnet = $RealDotnet
        arguments = @($Arguments)
        command = $command
        exitCode = $process.ExitCode
        stdoutPath = $StdoutPath
        stderrPath = $StderrPath
    } | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $logPath -Encoding utf8

    exit $process.ExitCode
} finally {
    $stdoutWriter.Dispose()
    $stderrWriter.Dispose()
}
