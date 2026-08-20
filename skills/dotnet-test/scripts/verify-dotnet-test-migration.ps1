<#
.SYNOPSIS
    Blocking completion gate for dotnet-test migrations.

.DESCRIPTION
    Answers one question with evidence instead of narration: did this run actually move the selected
    test project onto the Codebelt entrypoint-owned host, or did it only rearrange code around the
    host it was supposed to replace?

    The inspector already knows how to recognize the target pattern, so this wraps
    inspect-dotnet-tests.ps1 rather than reimplementing its regexes, then adds the checks that only
    make sense after the edits exist: the xUnit anchor the resolver established, retained legacy
    packages, laundered WebApplicationFactory facades, and edits that produced churn without
    conversion. It renders one verdict a reviewer can read without parsing JSON.
#>
param(
    [string]$RepoRoot = (Get-Location).Path,
    [Parameter(Mandatory)]
    [string]$ProjectPath,
    [ValidateSet('Focused', 'Shared')]
    [string]$ExpectedWebPattern,
    [ValidateSet('Focused', 'Shared')]
    [string]$ExpectedApplicationPattern,
    [switch]$Json
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$utf8NoBom = [System.Text.UTF8Encoding]::new($false)
[Console]::OutputEncoding = $utf8NoBom
$OutputEncoding = $utf8NoBom

# Usage problems exit 2 so a caller can tell "the gate could not run" from "the migration failed".
# Write-Error would terminate under the Stop preference above and surface as exit 1, collapsing that
# distinction into the failure code.
function Exit-WithUsageError {
    param([string]$Message)
    [Console]::Error.WriteLine($Message)
    exit 2
}

if ([string]::IsNullOrWhiteSpace($ExpectedWebPattern) -and [string]::IsNullOrWhiteSpace($ExpectedApplicationPattern)) {
    Exit-WithUsageError 'Specify -ExpectedWebPattern or -ExpectedApplicationPattern. The gate verifies a named target pattern; without one there is nothing to verify.'
}
if (-not [string]::IsNullOrWhiteSpace($ExpectedWebPattern) -and -not [string]::IsNullOrWhiteSpace($ExpectedApplicationPattern)) {
    Exit-WithUsageError 'ExpectedWebPattern and ExpectedApplicationPattern are mutually exclusive.'
}

$violations = [System.Collections.Generic.List[object]]::new()
$warnings = [System.Collections.Generic.List[object]]::new()

function Add-Violation {
    param([string]$Code, [string]$Message, [string]$Evidence)
    $violations.Add([pscustomobject]@{ code = $Code; message = $Message; evidence = $Evidence })
}

function Add-Warning {
    param([string]$Code, [string]$Message, [string]$Evidence)
    $warnings.Add([pscustomobject]@{ code = $Code; message = $Message; evidence = $Evidence })
}

function Get-MajorVersion {
    param([string]$Version)
    if ([string]::IsNullOrWhiteSpace($Version)) { return $null }
    $core = ($Version -split '-', 2)[0]
    $first = ($core -split '\.')[0]
    $parsed = 0
    if ([int]::TryParse($first, [ref]$parsed)) { return $parsed }
    return $null
}

$repoRootPath = (Resolve-Path -LiteralPath $RepoRoot).Path
$scriptRoot = Split-Path -Path $PSCommandPath -Parent
$inspector = Join-Path $scriptRoot 'inspect-dotnet-tests.ps1'
if (-not (Test-Path -LiteralPath $inspector -PathType Leaf)) {
    Exit-WithUsageError "The inspector was not found next to this gate: $inspector"
}

# --- Run the inspector under the expected-pattern postcondition -------------------------------
$inspectorArguments = @('-NoProfile', '-File', $inspector, '-RepoRoot', $repoRootPath, '-ProjectPath', $ProjectPath)
if (-not [string]::IsNullOrWhiteSpace($ExpectedWebPattern)) { $inspectorArguments += @('-ExpectedWebPattern', $ExpectedWebPattern) }
if (-not [string]::IsNullOrWhiteSpace($ExpectedApplicationPattern)) { $inspectorArguments += @('-ExpectedApplicationPattern', $ExpectedApplicationPattern) }

$inspectorOutput = @(& pwsh @inspectorArguments 2>&1)
$inspectorExit = $LASTEXITCODE
$inspectorText = ($inspectorOutput -join [Environment]::NewLine)
$report = $null
try {
    $report = ($inspectorText | ConvertFrom-Json).projects[0]
} catch {
    Write-Output '================ DOTNET-TEST MIGRATION VERDICT ================'
    Write-Output "project  : $ProjectPath"
    Write-Output 'result   : ERROR - the inspector did not return parseable JSON'
    Write-Output ''
    Write-Output $inspectorText
    Write-Output '==============================================================='
    exit 2
}

foreach ($blocker in @($report.blockers)) {
    $code = switch -Regex ($blocker) {
        'still contains WebApplicationFactory' { 'WAF-RETAINED'; break }
        'constructs a replacement host' { 'REPLACEMENT-HOST'; break }
        'deprecated Blocking' { 'BLOCKING-FIXTURE'; break }
        'must explicitly use Managed' { 'FIXTURE-MISSING'; break }
        'does not dispose it through both' { 'DISPOSAL-INCOMPLETE'; break }
        'postcondition requires' { 'PATTERN-MISSING'; break }
        'cannot be applied because' { 'ROLE-MISMATCH'; break }
        default { 'INSPECTOR-BLOCKER' }
    }
    Add-Violation -Code $code -Message $blocker -Evidence 'inspect-dotnet-tests.ps1'
}

# --- Laundered facade -------------------------------------------------------------------------
# Wrapping the legacy factory in a new type - a private nested subclass, a renamed facade, a
# constructor turned into a static Create - keeps the Microsoft host in charge while the diff looks
# like a migration. Name it separately from the generic retained-usage blocker so the report says
# what actually happened rather than leaving the reader to infer it from a line number.
foreach ($declaration in @($report.inheritance)) {
    if ($declaration.baseTypes -match '\bWebApplicationFactory\s*<') {
        Add-Violation -Code 'LAUNDERED-FACADE' `
            -Message "Type '$($declaration.type)' still derives from WebApplicationFactory. Wrapping, nesting, or renaming the legacy factory keeps Microsoft's host in charge; the deliverable is that the Codebelt abstraction owns the host instead." `
            -Evidence "$($declaration.path):$($declaration.line)"
    }
}

# --- Retained legacy packages -----------------------------------------------------------------
$legacyWebPackages = @('Microsoft.AspNetCore.Mvc.Testing')
if (-not [string]::IsNullOrWhiteSpace($ExpectedWebPattern)) {
    foreach ($package in @($report.packageOwnership)) {
        if ($legacyWebPackages -notcontains $package.id) { continue }
        Add-Violation -Code 'LEGACY-PACKAGE-RETAINED' `
            -Message "$($package.id) is still referenced. It exists to supply WebApplicationFactory; keeping it after the migration leaves the replaced host one using directive away from returning." `
            -Evidence "$($package.referenceOwner) (version owner: $($package.versionOwner))"
    }
}

# --- xUnit anchor breach ----------------------------------------------------------------------
# The resolver anchors xunit* to the Codebelt release in use. Nothing re-checks that after the
# edits, so a well-meant "bump everything to latest" can silently push the project a whole xUnit
# generation past the API it was migrated onto. project.assets.json records the anchor's own
# declared dependencies, which makes this verifiable offline from what actually restored.
$projectFullPath = if ([System.IO.Path]::IsPathRooted($ProjectPath)) { $ProjectPath } else { Join-Path $repoRootPath $ProjectPath }
$assetsPath = Join-Path (Split-Path -Path $projectFullPath -Parent) 'obj/project.assets.json'
$anchorId = $null
$anchorVersion = $null
$anchorMajor = $null
$anchorDeclared = @{}
if (Test-Path -LiteralPath $assetsPath -PathType Leaf) {
    try {
        $assets = [System.IO.File]::ReadAllText($assetsPath, $utf8NoBom) | ConvertFrom-Json
        foreach ($targetProperty in $assets.targets.PSObject.Properties) {
            foreach ($libraryProperty in $targetProperty.Value.PSObject.Properties) {
                if ($libraryProperty.Name -notmatch '^Codebelt\.Extensions\.Xunit(?:\.App)?/(?<version>.+)$') { continue }
                $library = $libraryProperty.Value
                if ($null -eq $library.PSObject.Properties['dependencies']) { continue }
                foreach ($dependency in $library.dependencies.PSObject.Properties) {
                    if ($dependency.Name -notlike 'xunit*') { continue }
                    $anchorId = ($libraryProperty.Name -split '/')[0]
                    $anchorVersion = $Matches['version']
                    $anchorDeclared[$dependency.Name] = [string]$dependency.Value
                }
            }
        }
    } catch {
        Add-Warning -Code 'XUNIT-ANCHOR-UNREADABLE' -Message "project.assets.json could not be parsed, so the xUnit anchor was not verified: $($_.Exception.Message)" -Evidence $assetsPath
    }
}

if ($anchorDeclared.Count -gt 0) {
    $anchorMajor = Get-MajorVersion -Version (@($anchorDeclared.Values)[0])
    foreach ($package in @($report.packageOwnership)) {
        if ($package.id -notlike 'xunit*') { continue }
        $major = Get-MajorVersion -Version $package.version
        if ($null -eq $major) { continue }
        if ($anchorDeclared.ContainsKey($package.id)) {
            $expected = $anchorDeclared[$package.id]
            if ($package.version -ne $expected) {
                Add-Violation -Code 'XUNIT-ANCHOR-BREACH' `
                    -Message "$($package.id) is pinned to $($package.version) but $anchorId $anchorVersion declares $expected. An id the anchor names resolves 1:1 to the version it declares." `
                    -Evidence $package.versionOwner
            }
        } elseif ($null -ne $anchorMajor -and $major -gt $anchorMajor) {
            Add-Violation -Code 'XUNIT-ANCHOR-BREACH' `
                -Message "$($package.id) is pinned to $($package.version), past major $anchorMajor of the $anchorId $anchorVersion anchor. Newest-on-NuGet is not the ceiling; the Codebelt package has to move to the next xUnit generation first." `
                -Evidence $package.versionOwner
        }
    }
} else {
    Add-Warning -Code 'XUNIT-ANCHOR-UNVERIFIED' `
        -Message 'No restored Codebelt.Extensions.Xunit anchor was found, so xunit* versions were not bounded. Restore the project and rerun this gate to verify them.' `
        -Evidence $assetsPath
}

# --- Churn without conversion -----------------------------------------------------------------
# The most honest single signal that a run produced motion instead of migration: files under the
# selected project changed, yet not one line of the target pattern exists. Renaming a constructor
# to a static factory method reads as progress in a summary and as nothing at all in a diff.
$patternUsageCount = if (-not [string]::IsNullOrWhiteSpace($ExpectedWebPattern)) {
    @($report.focusedWebApplicationTestFactoryUsages).Count + @($report.sharedWebApplicationTestUsages).Count
} else {
    @($report.focusedApplicationTestFactoryUsages).Count + @($report.sharedApplicationTestUsages).Count
}
$projectDirectoryRelative = Split-Path -Path $report.project -Parent
if ($patternUsageCount -eq 0 -and -not [string]::IsNullOrWhiteSpace($projectDirectoryRelative)) {
    $changed = @()
    try {
        $changed = @(& git -C $repoRootPath status --porcelain -- $projectDirectoryRelative 2>$null | Where-Object { $_ -notmatch '[\\/](bin|obj)[\\/]' })
    } catch {
        $changed = @()
    }
    if ($changed.Count -gt 0) {
        Add-Violation -Code 'CHURN-WITHOUT-CONVERSION' `
            -Message "$($changed.Count) file(s) under the selected project changed, yet the target pattern appears zero times. Edits that rename, wrap, or reformat the existing host produce a reviewable diff without performing the migration." `
            -Evidence (($changed | Select-Object -First 8) -join '; ')
    }
}

# --- Verdict ----------------------------------------------------------------------------------
$result = if ($violations.Count -eq 0) { 'PASSED' } else { 'FAILED' }
$expectation = if (-not [string]::IsNullOrWhiteSpace($ExpectedWebPattern)) {
    "$ExpectedWebPattern ASP.NET Core web pattern"
} else {
    "$ExpectedApplicationPattern console/worker application pattern"
}

Write-Output '================ DOTNET-TEST MIGRATION VERDICT ================'
Write-Output "project  : $($report.project)"
Write-Output "role     : $($report.role)"
Write-Output "expected : $expectation"
if ($null -ne $anchorId) { Write-Output "anchor   : $anchorId $anchorVersion (xunit major $anchorMajor)" }
Write-Output "result   : $result ($($violations.Count) violation(s), $($warnings.Count) warning(s))"
if ($violations.Count -gt 0) {
    Write-Output ''
    Write-Output 'VIOLATIONS'
    $index = 1
    foreach ($violation in $violations) {
        Write-Output ("  {0}. [{1}] {2}" -f $index, $violation.code, $violation.message)
        Write-Output ("     evidence: {0}" -f $violation.evidence)
        $index++
    }
}
if ($warnings.Count -gt 0) {
    Write-Output ''
    Write-Output 'WARNINGS'
    $index = 1
    foreach ($warning in $warnings) {
        Write-Output ("  {0}. [{1}] {2}" -f $index, $warning.code, $warning.message)
        Write-Output ("     evidence: {0}" -f $warning.evidence)
        $index++
    }
}
Write-Output '==============================================================='

if ($Json) {
    Write-Output ([ordered]@{
        project = $report.project
        role = $report.role
        expected = $expectation
        result = $result
        inspectorExitCode = $inspectorExit
        xunitAnchor = [ordered]@{ id = $anchorId; version = $anchorVersion; major = $anchorMajor; declared = $anchorDeclared }
        violations = @($violations)
        warnings = @($warnings)
    } | ConvertTo-Json -Depth 6)
}

if ($violations.Count -gt 0) { exit 1 }
exit 0
