[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$A,
    [Parameter(Mandatory)][string]$B,
    [switch]$AsJson
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. "$PSScriptRoot/_common.ps1"

$compare = Compare-NuGetVersion -A $A -B $B
$relation = switch ($compare) {
    -1 { 'lt' }
    0 { 'eq' }
    1 { 'gt' }
}
$result = [pscustomobject]@{
    a        = $A
    b        = $B
    compare  = $compare
    relation = $relation
    newer    = if ($compare -gt 0) { $A } elseif ($compare -lt 0) { $B } else { $A }
}

if ($AsJson) {
    $result | ConvertTo-Json -Depth 6
} else {
    $result
}
