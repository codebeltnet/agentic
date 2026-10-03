[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$validator = Join-Path $PSScriptRoot 'validate-commit-subject.ps1'
$failures = [System.Collections.Generic.List[string]]::new()
$passes = 0

function Invoke-SubjectCase {
    param(
        [Parameter(Mandatory)]
        [string] $Name,

        [Parameter(Mandatory)]
        [string] $Subject,

        [ValidateSet('Forbidden', 'Required')]
        [string] $PrefixMode = 'Forbidden',

        [Parameter(Mandatory)]
        [bool] $ShouldPass,

        [string[]] $ExpectedError = @()
    )

    $succeeded = $false
    $output = ''
    try {
        $output = (& $validator -Subject $Subject -PrefixMode $PrefixMode 2>&1 | Out-String).Trim()
        $succeeded = $true
    }
    catch {
        $output = $_.Exception.Message
    }

    if ($succeeded -ne $ShouldPass) {
        $script:failures.Add("$Name expected pass=$ShouldPass but pass=$succeeded. Output: $output")
        return
    }

    foreach ($needle in $ExpectedError) {
        if (-not $output.Contains($needle, [System.StringComparison]::OrdinalIgnoreCase)) {
            $script:failures.Add("$Name did not report expected text '$needle'. Output: $output")
            return
        }
    }

    $script:passes++
}

Invoke-SubjectCase -Name 'valid default subject' -Subject '💬 update changelog for v10.0.10' -ShouldPass $true
Invoke-SubjectCase -Name 'valid description with identifier' -Subject '🐛 handle OAuth callback failure' -ShouldPass $true
Invoke-SubjectCase -Name 'valid opt-in prefix' -Subject '🐛 fix: handle missing release tag' -PrefixMode 'Required' -ShouldPass $true
Invoke-SubjectCase -Name 'valid exact maximum' -Subject ("💬 " + ('a' * 68)) -ShouldPass $true
foreach ($emoji in @('💰', '🪙', '💴', '💵', '💶', '💷', '💸', '💳', '🧾', '💹', '📋', '🧑🏽‍💻', '🇩🇰', '1️⃣', '⚡')) {
    Invoke-SubjectCase -Name "extended Unicode emoji $emoji" -Subject "$emoji update finance records" -ShouldPass $true
}
Invoke-SubjectCase -Name 'text instead of emoji' -Subject 'money update budget' -ShouldPass $false -ExpectedError 'one Unicode emoji or symbol sequence'
Invoke-SubjectCase -Name 'shortcode instead of emoji' -Subject ':moneybag: update budget' -ShouldPass $false -ExpectedError 'one Unicode emoji or symbol sequence'
Invoke-SubjectCase -Name 'multiple emoji' -Subject '💰💸 update budget' -ShouldPass $false -ExpectedError 'one Unicode emoji or symbol sequence'
Invoke-SubjectCase -Name 'reported screenshot regression' -Subject '📋 Update CHANGELOG for v10.0.10 with dependency and tooling updates' -ShouldPass $false -ExpectedError @('lowercase letter')
Invoke-SubjectCase -Name 'approved emoji with uppercase description' -Subject '💬 Update changelog' -ShouldPass $false -ExpectedError 'lowercase letter'
Invoke-SubjectCase -Name 'double separator' -Subject '💬  update changelog' -ShouldPass $false -ExpectedError 'exactly one ASCII space'
Invoke-SubjectCase -Name 'overlong subject' -Subject ("💬 " + ('a' * 69)) -ShouldPass $false -ExpectedError 'the maximum is 70'
Invoke-SubjectCase -Name 'unexpected conventional prefix' -Subject '💬 docs: update changelog' -ShouldPass $false -ExpectedError 'prefix is forbidden'
Invoke-SubjectCase -Name 'invalid conventional prefix' -Subject '🐛 feat: handle missing release tag' -PrefixMode 'Required' -ShouldPass $false -ExpectedError "Prefix 'feat:' is not allowed"

if ($failures.Count -gt 0) {
    throw ("Commit-subject validation failed:`n- " + ($failures -join "`n- "))
}

"Commit-subject validation passed: $passes cases."
