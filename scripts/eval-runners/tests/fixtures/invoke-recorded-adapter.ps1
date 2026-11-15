<#!
.SYNOPSIS
    Runs a recorded adapter fixture without host-dependent OS sandbox discovery.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$RunnerPath,
    [Parameter(Mandatory = $true)][string]$Command,
    [Parameter(Mandatory = $true)][string]$Run,
    [Parameter(Mandatory = $true)][string]$Profile
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# These fixtures exercise pragmatic isolation and compare host-visible paths.
# Keep the real adapter entry point, but make external sandbox availability an
# explicit fixture input, independent of installed Linux/macOS utilities.
function Get-Command {
    [CmdletBinding()]
    param(
        [Parameter(Position = 0)][string[]]$Name,
        [System.Management.Automation.CommandTypes]$CommandType
    )

    $visibleNames = @($Name | Where-Object { $_ -notmatch '^(bwrap|sandbox-exec)(\.(ps1|cmd|exe))?$' })
    if ($visibleNames.Count -eq 0) { return }
    $PSBoundParameters['Name'] = $visibleNames
    Microsoft.PowerShell.Core\Get-Command @PSBoundParameters
}

$LASTEXITCODE = 0
& $RunnerPath $Command -Run $Run -Profile $Profile
exit $LASTEXITCODE
