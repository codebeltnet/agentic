[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$RepoRoot,
    [switch]$Yolo,
    [switch]$ApplyAuto,
    [switch]$IncludePrerelease,
    [switch]$DryRun,
    [string[]]$Source = @('https://api.nuget.org/v3-flatcontainer'),
    [ValidateRange(1, 32)][int]$MaxConcurrency = 8,
    [ValidateRange(1, 300)][int]$TimeoutSec = 15,
    [switch]$AsJson
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not $Yolo -and -not $ApplyAuto) {
    throw 'Specify -Yolo for a silent safe-update pass or -ApplyAuto for an attended safe-update pass.'
}

$repoPath = (Resolve-Path -LiteralPath $RepoRoot).Path
$auditScript = Join-Path $PSScriptRoot 'Get-DependencyAudit.ps1'
$applyScript = Join-Path $PSScriptRoot 'Apply-PackageUpdates.ps1'

try {
    # Keep audit, plan construction, and structural apply in one PowerShell
    # process. The audit itself performs the only independent network fan-out;
    # file reads and writes remain ordered where they share repository state.
    $auditOutput = & $auditScript `
        -RepoRoot $repoPath `
        -IncludePrerelease:$IncludePrerelease `
        -Source $Source `
        -MaxConcurrency $MaxConcurrency `
        -TimeoutSec $TimeoutSec `
        -AsJson
    $audit = (($auditOutput -join [Environment]::NewLine) | ConvertFrom-Json)
}
catch {
    throw "Dependency audit failed: $($_.Exception.Message)"
}

$autoRows = @($audit.rows | Where-Object { $_.action -eq 'auto' })
$noteHeldRows = @($autoRows | Where-Object { -not [string]::IsNullOrWhiteSpace($_.note) })
$readyRows = @($autoRows | Where-Object { [string]::IsNullOrWhiteSpace($_.note) })
$updates = @(
    $readyRows | ForEach-Object {
        [pscustomobject]@{
            id         = $_.id
            condition  = $_.condition
            sourceFile = $_.sourceFile
            from       = $_.current
            to         = $_.candidate
        }
    }
)

$applyResult = [pscustomobject]@{
    skipped = $true
    reason  = if ($noteHeldRows.Count -gt 0) { 'no note-bearing auto candidates were applied automatically' } else { 'no safe updates were found' }
    results = @()
}

if ($updates.Count -gt 0) {
    $updatesJson = ($updates | ConvertTo-Json -Depth 8 -Compress)
    try {
        $applyOutput = & $applyScript `
            -RepoRoot $repoPath `
            -Updates $updatesJson `
            -DryRun:$DryRun `
            -AsJson
        $applyResult = (($applyOutput -join [Environment]::NewLine) | ConvertFrom-Json)
    }
    catch {
        throw "Safe package apply failed: $($_.Exception.Message)"
    }
}

$applyResults = @($applyResult.results)
$successfulApplyCount = @($applyResults | Where-Object { $_.outcome -eq 'applied' }).Count

$failedApplyResults = @($applyResults | Where-Object { $_.outcome -notin @('applied', 'dry-run') })

$result = [pscustomobject]@{
    repoRoot       = $audit.repoRoot
    management     = $audit.management
    mode           = if ($Yolo) { 'yolo' } else { 'apply-auto' }
    dryRun         = [bool]$DryRun
    audit          = $audit
    updates        = @($updates)
    appliedCount   = $successfulApplyCount
    applyComplete  = ($failedApplyResults.Count -eq 0 -and $successfulApplyCount -eq $updates.Count)
    apply          = $applyResult
    noteHeld       = @($noteHeldRows)
    heldMajors     = @($audit.rows | Where-Object { $_.action -eq 'approval' })
    unresolved     = @($audit.rows | Where-Object { $_.action -eq 'unresolved' })
}

if ($AsJson) {
    $result | ConvertTo-Json -Depth 16
} else {
    $result
}
