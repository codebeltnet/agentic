<#!
.SYNOPSIS
    Resolves one package-local Eval Runner without guessing or falling back.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, Position = 0)]
    [string]$Runner
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

. (Join-Path $PSScriptRoot 'runner-common.ps1')

$protocol = (Get-RunnerSchemaNames).Protocol
if ($Runner -notmatch '^[a-z0-9][a-z0-9-]*$') {
    throw "Runner name '$Runner' is not a safe package-local runner name."
}

$runnerPath = Join-Path (Join-Path $PSScriptRoot $Runner) 'runner.ps1'
if (-not (Test-Path -LiteralPath $runnerPath -PathType Leaf)) {
    throw "Selected Eval Runner '$Runner' is unavailable in this package."
}

$resolved = (Resolve-Path -LiteralPath $runnerPath).Path
$root = (Resolve-Path -LiteralPath $PSScriptRoot).Path
$relative = [System.IO.Path]::GetRelativePath($root, $resolved).Replace('\', '/')

Write-RunnerJson -Value ([ordered]@{
    schema = 'codebeltnet/agentic/eval-runner-resolution/1'
    protocol_version = $protocol
    runner = $Runner
    path = $relative
}) -Depth 10 -Compress -AsOutput
