function New-EvalOwnedProcess {
    if (-not $IsWindows) { return [System.Diagnostics.Process]::new() }
    if (-not ('Agentic.Evals.WindowsOwnedProcess' -as [type])) {
        Add-Type -Path (Join-Path $PSScriptRoot 'windows-owned-process.cs')
    }
    return [Agentic.Evals.WindowsOwnedProcess]::new()
}

function Stop-EvalOwnedProcess {
    param([Parameter(Mandatory = $true)][object]$Process)
    $windowsProcessType = 'Agentic.Evals.WindowsOwnedProcess' -as [type]
    if ($null -ne $windowsProcessType -and $windowsProcessType.IsInstanceOfType($Process)) {
        $Process.StopOwnedProcesses(5000)
    } elseif (-not $Process.HasExited) {
        $Process.Kill($true)
        if (-not $Process.WaitForExit(5000)) {
            throw 'Process termination grace expired before the launcher exited.'
        }
    }
}
