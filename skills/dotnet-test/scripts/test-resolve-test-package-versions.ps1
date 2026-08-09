[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$resolver = Join-Path $PSScriptRoot 'resolve-test-package-versions.ps1'
$serviceIndexUri = 'https://api.nuget.org/v3/index.json'
$packageBaseAddress = 'https://mock.nuget/flatcontainer/'

function Reset-ResolverMock {
    $global:DotnetTestResolverVersions = @{}
    $global:DotnetTestResolverRestoreRequests = [System.Collections.Generic.List[object]]::new()
    $global:DotnetTestResolverFailureMode = 'Success'
    $global:DotnetTestResolverFailurePackageId = $null
    $global:DotnetTestResolverFailureVersion = $null
    $global:DotnetTestResolverFailureCombination = $null
    $global:LASTEXITCODE = 0
}

function Set-TestPackageVersions {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Id,

        [Parameter(Mandatory = $true)]
        [string[]]$Versions
    )

    $global:DotnetTestResolverVersions[$Id.ToLowerInvariant()] = @($Versions)
}

function Invoke-RestMethod {
    param([Parameter(Mandatory = $true)][string]$Uri)

    if ($Uri -eq $serviceIndexUri) {
        return [pscustomobject]@{
            resources = @([pscustomobject]@{
                '@type' = 'PackageBaseAddress/3.0.0'
                '@id' = $packageBaseAddress
            })
        }
    }

    if ($Uri.StartsWith($packageBaseAddress, [System.StringComparison]::Ordinal)) {
        $segments = $Uri.TrimEnd('/') -split '/'
        $id = $segments[$segments.Count - 2]
        if (-not $global:DotnetTestResolverVersions.ContainsKey($id)) {
            throw "Unexpected package lookup: $Uri"
        }

        return [pscustomobject]@{ versions = @($global:DotnetTestResolverVersions[$id]) }
    }

    throw "Unexpected HTTP lookup: $Uri"
}

function dotnet {
    param(
        [string]$Command,
        [string]$ProjectPath,
        [Parameter(ValueFromRemainingArguments = $true)]
        [object[]]$Arguments
    )

    [xml]$project = [System.IO.File]::ReadAllText($ProjectPath)
    $references = @($project.SelectNodes('/Project/ItemGroup/PackageReference') | ForEach-Object {
        [pscustomobject]@{
            id = $_.GetAttribute('Include')
            version = $_.GetAttribute('Version')
        }
    })
    $referenceKey = ($references | ForEach-Object { '{0}={1}' -f $_.id, $_.version } | Sort-Object) -join ';'
    $global:DotnetTestResolverRestoreRequests.Add([pscustomobject]@{
        references = @($references)
        key = $referenceKey
    })

    $failure = $null
    if ($global:DotnetTestResolverFailureMode -eq 'FailAll') {
        $failure = 'NU_TEST_RESTORE_FAILURE: forced restore failure.'
    } elseif ($global:DotnetTestResolverFailureMode -eq 'FailPackageVersion' -and
        @($references | Where-Object { $_.id -eq $global:DotnetTestResolverFailurePackageId -and $_.version -eq $global:DotnetTestResolverFailureVersion }).Count -gt 0) {
        $failure = 'NU_TEST_RESTORE_FAILURE: forced candidate failure.'
    } elseif ($global:DotnetTestResolverFailureMode -eq 'FailCombination' -and $referenceKey -eq $global:DotnetTestResolverFailureCombination) {
        $failure = 'NU_TEST_RESTORE_FAILURE: forced combined-package failure.'
    }

    if ($null -ne $failure) {
        $global:LASTEXITCODE = 1
        Write-Output $failure
        return
    }

    $global:LASTEXITCODE = 0
    Write-Output 'restore succeeded'
}

function Invoke-TestResolver {
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$PackageId,

        [Parameter(Mandatory = $true)]
        [int]$MaximumCandidates
    )

    $output = @()
    $caught = $false
    try {
        $output = @(& $resolver -TargetFramework net10.0 -Role Unit -PackageId $PackageId -MaximumCandidates $MaximumCandidates 2>&1)
    } catch {
        $caught = $true
        $output += $_
    }

    $text = ($output | ForEach-Object { $_.ToString() }) -join [Environment]::NewLine
    $exitCode = [int]$global:LASTEXITCODE
    $json = $null
    if (-not $caught -and $exitCode -eq 0) {
        try {
            $json = $text | ConvertFrom-Json
        } catch {
            throw "Resolver returned invalid JSON: $text"
        }
    }

    return [pscustomobject]@{
        exitCode = $exitCode
        text = $text
        json = $json
    }
}

function Assert-Equal {
    param(
        [Parameter(Mandatory = $true)]$Actual,
        [Parameter(Mandatory = $true)]$Expected,
        [Parameter(Mandatory = $true)][string]$Because
    )

    if ("$Actual" -ne "$Expected") {
        throw "Assertion failed: $Because. Expected '$Expected', got '$Actual'."
    }
}

function Assert-True {
    param(
        [Parameter(Mandatory = $true)][bool]$Condition,
        [Parameter(Mandatory = $true)][string]$Because
    )

    if (-not $Condition) { throw "Assertion failed: $Because." }
}

function Assert-ContainsText {
    param(
        [Parameter(Mandatory = $true)][string]$Text,
        [Parameter(Mandatory = $true)][string]$Expected,
        [Parameter(Mandatory = $true)][string]$Because
    )

    if (-not $Text.Contains($Expected, [System.StringComparison]::Ordinal)) {
        throw "Assertion failed: $Because. Missing '$Expected'. Actual output:`n$Text"
    }
}

try {
    Reset-ResolverMock

    Set-TestPackageVersions -Id 'Stable.Package' -Versions @('11.0.0-rc.1', '10.0.0', '9.99.0', '9.98.0')
    $stable = Invoke-TestResolver -PackageId 'Stable.Package' -MaximumCandidates 2
    Assert-Equal -Actual $stable.exitCode -Expected 0 -Because 'stable candidate resolution should succeed'
    Assert-Equal -Actual $stable.json.packages[0].version -Expected '10.0.0' -Because 'stable versions must be numerically ordered and prereleases excluded'

    Reset-ResolverMock
    Set-TestPackageVersions -Id 'Fallback.Package' -Versions @('3.0.0', '2.0.0')
    $global:DotnetTestResolverFailureMode = 'FailPackageVersion'
    $global:DotnetTestResolverFailurePackageId = 'Fallback.Package'
    $global:DotnetTestResolverFailureVersion = '3.0.0'
    $fallback = Invoke-TestResolver -PackageId 'Fallback.Package' -MaximumCandidates 2
    Assert-Equal -Actual $fallback.exitCode -Expected 0 -Because 'an older restorable candidate should be selected'
    Assert-Equal -Actual $fallback.json.packages[0].version -Expected '2.0.0' -Because 'candidate fallback should continue after a restore failure'
    Assert-Equal -Actual $global:DotnetTestResolverRestoreRequests.Count -Expected 2 -Because 'the failed newest candidate and fallback candidate should both be tested'

    Reset-ResolverMock
    Set-TestPackageVersions -Id 'Package.A' -Versions @('2.0.0', '1.0.0')
    Set-TestPackageVersions -Id 'Package.B' -Versions @('2.0.0', '1.0.0')
    $global:DotnetTestResolverFailureMode = 'FailCombination'
    $global:DotnetTestResolverFailureCombination = 'Package.A=2.0.0;Package.B=2.0.0'
    $combined = Invoke-TestResolver -PackageId @('Package.A', 'Package.B') -MaximumCandidates 2
    Assert-Equal -Actual $combined.exitCode -Expected 0 -Because 'the resolver should recover from an incompatible combined package set'
    Assert-Equal -Actual (($combined.json.packages | Where-Object packageId -eq 'Package.A').version) -Expected '2.0.0' -Because 'the compatible first package candidate should be retained'
    Assert-Equal -Actual (($combined.json.packages | Where-Object packageId -eq 'Package.B').version) -Expected '1.0.0' -Because 'the incompatible newest second package candidate should fall back'
    Assert-True -Condition (@($global:DotnetTestResolverRestoreRequests | Where-Object { $_.references.Count -eq 2 }).Count -gt 0) -Because 'compatibility must be tested with the combined package set'
    Assert-Equal -Actual ($combined.json.packages | Where-Object packageId -eq 'Package.A').compatibility -Expected 'combined restore passed' -Because 'the output must describe the compatibility actually validated'

    Reset-ResolverMock
    Set-TestPackageVersions -Id 'Failure.Package' -Versions @('2.0.0', '1.0.0')
    $global:DotnetTestResolverFailureMode = 'FailAll'
    $failure = Invoke-TestResolver -PackageId 'Failure.Package' -MaximumCandidates 2
    Assert-True -Condition ($failure.exitCode -ne 0) -Because 'resolver restore failure must fail closed'
    Assert-ContainsText -Text $failure.text -Expected "No stable 'Failure.Package' version" -Because 'failure output must identify the package and candidate scope'
    Assert-ContainsText -Text $failure.text -Expected 'NU_TEST_RESTORE_FAILURE' -Because 'failure output must preserve restore evidence'

    Write-Output 'resolve-test-package-versions.ps1 regression: PASS'
} finally {
    foreach ($name in @(
        'DotnetTestResolverVersions',
        'DotnetTestResolverRestoreRequests',
        'DotnetTestResolverFailureMode',
        'DotnetTestResolverFailurePackageId',
        'DotnetTestResolverFailureVersion',
        'DotnetTestResolverFailureCombination'
    )) {
        Remove-Variable -Scope Global -Name $name -ErrorAction SilentlyContinue
    }
}
