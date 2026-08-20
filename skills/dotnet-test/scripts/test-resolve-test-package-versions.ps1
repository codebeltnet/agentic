[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$resolver = Join-Path $PSScriptRoot 'resolve-test-package-versions.ps1'
$serviceIndexUri = 'https://api.nuget.org/v3/index.json'
$packageBaseAddress = 'https://mock.nuget/flatcontainer/'

function Reset-ResolverMock {
    $global:DotnetTestResolverVersions = @{}
    $global:DotnetTestResolverNuspecs = @{}
    $global:DotnetTestResolverRestoreRequests = [System.Collections.Generic.List[object]]::new()
    $global:DotnetTestResolverHttpRequests = [System.Collections.Generic.List[string]]::new()
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

function Set-TestPackageNuspec {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Id,

        [Parameter(Mandatory = $true)]
        [string]$Version,

        [Parameter(Mandatory = $true)]
        [hashtable]$Dependencies
    )

    $entries = (@($Dependencies.GetEnumerator() | Sort-Object Key) | ForEach-Object {
        '<dependency id="{0}" version="{1}" exclude="Build,Analyzers" />' -f $_.Key, $_.Value
    }) -join ''
    # Real nuspecs repeat the same dependency once per target-framework group, so the mock does too.
    $groups = (@('net10.0', 'net9.0') | ForEach-Object { '<group targetFramework="{0}">{1}</group>' -f $_, $entries }) -join ''
    $xml = '<?xml version="1.0" encoding="utf-8"?><package xmlns="http://schemas.microsoft.com/packaging/2013/05/nuspec.xsd"><metadata><id>{0}</id><version>{1}</version><dependencies>{2}</dependencies></metadata></package>' -f $Id, $Version, $groups
    $global:DotnetTestResolverNuspecs[('{0}/{1}' -f $Id.ToLowerInvariant(), $Version.ToLowerInvariant())] = $xml
}

function Invoke-RestMethod {
    param([Parameter(Mandatory = $true)][string]$Uri)

    $global:DotnetTestResolverHttpRequests.Add($Uri)

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
        if ($Uri.EndsWith('.nuspec', [System.StringComparison]::OrdinalIgnoreCase)) {
            $nuspecKey = '{0}/{1}' -f $segments[$segments.Count - 3], $segments[$segments.Count - 2]
            if (-not $global:DotnetTestResolverNuspecs.ContainsKey($nuspecKey)) {
                throw "Unexpected nuspec lookup: $Uri"
            }

            return [xml]$global:DotnetTestResolverNuspecs[$nuspecKey]
        }

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

        [int]$MaximumCandidates,

        [string]$CacheDirectory,

        [string]$XunitAnchorVersion,

        [switch]$UseDefaultCandidateLimit
    )

    $output = @()
    $caught = $false
    try {
        if ($UseDefaultCandidateLimit) {
            if ([string]::IsNullOrWhiteSpace($CacheDirectory)) {
                $output = @(& $resolver -TargetFramework net10.0 -Role Unit -PackageId $PackageId 2>&1)
            } else {
                $output = @(& $resolver -TargetFramework net10.0 -Role Unit -PackageId $PackageId -CacheDirectory $CacheDirectory 2>&1)
            }
        } elseif (-not [string]::IsNullOrWhiteSpace($XunitAnchorVersion)) {
            $output = @(& $resolver -TargetFramework net10.0 -Role Unit -PackageId $PackageId -MaximumCandidates $MaximumCandidates -XunitAnchorVersion $XunitAnchorVersion 2>&1)
        } elseif ([string]::IsNullOrWhiteSpace($CacheDirectory)) {
            $output = @(& $resolver -TargetFramework net10.0 -Role Unit -PackageId $PackageId -MaximumCandidates $MaximumCandidates 2>&1)
        } else {
            $output = @(& $resolver -TargetFramework net10.0 -Role Unit -PackageId $PackageId -MaximumCandidates $MaximumCandidates -CacheDirectory $CacheDirectory 2>&1)
        }
    } catch {
        $caught = $true
        $output += $_
    }

    $text = ($output | ForEach-Object { $_.ToString() }) -join [Environment]::NewLine
    $exitCode = if ($caught -and [int]$global:LASTEXITCODE -eq 0) { 1 } else { [int]$global:LASTEXITCODE }
    $json = $null
    $jsonText = $null
    $jsonStart = $text.IndexOf('{')
    if ($jsonStart -ge 0) {
        $jsonText = $text.Substring($jsonStart)
        try {
            $json = $jsonText | ConvertFrom-Json
        } catch {
            if (-not $caught -and $exitCode -eq 0) {
                throw "Resolver returned invalid JSON: $text"
            }
        }
    }

    return [pscustomobject]@{
        exitCode = $exitCode
        text = $text
        json = $json
    }
}

function Get-ResolverJsonObject {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Text
    )

    $jsonStart = $Text.IndexOf('{')
    if ($jsonStart -lt 0) {
        throw "Resolver output did not contain JSON.`n$Text"
    }
    return ($Text.Substring($jsonStart) | ConvertFrom-Json)
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

function Assert-False {
    param(
        [Parameter(Mandatory = $true)][bool]$Condition,
        [Parameter(Mandatory = $true)][string]$Because
    )

    if ($Condition) { throw "Assertion failed: $Because." }
}

try {
    Reset-ResolverMock

    Set-TestPackageVersions -Id 'Stable.Package' -Versions @('11.0.0-rc.1', '10.0.0', '9.99.0', '9.98.0')
    $stable = Invoke-TestResolver -PackageId 'Stable.Package' -MaximumCandidates 2
    $stableResult = Get-ResolverJsonObject -Text $stable.text
    $stablePackages = @($stableResult.packages)
    Assert-Equal -Actual $stable.exitCode -Expected 0 -Because 'stable candidate resolution should succeed'
    Assert-Equal -Actual $stablePackages[0].version -Expected '10.0.0' -Because 'stable versions must be numerically ordered and prereleases excluded'

    Reset-ResolverMock
    Set-TestPackageVersions -Id 'Fallback.Package' -Versions @('3.0.0', '2.0.0')
    $global:DotnetTestResolverFailureMode = 'FailPackageVersion'
    $global:DotnetTestResolverFailurePackageId = 'Fallback.Package'
    $global:DotnetTestResolverFailureVersion = '3.0.0'
    $fallback = Invoke-TestResolver -PackageId 'Fallback.Package' -MaximumCandidates 2
    $fallbackResult = Get-ResolverJsonObject -Text $fallback.text
    $fallbackPackages = @($fallbackResult.packages)
    Assert-Equal -Actual $fallback.exitCode -Expected 0 -Because 'an older restorable candidate should be selected'
    Assert-Equal -Actual $fallbackPackages[0].version -Expected '2.0.0' -Because 'candidate fallback should continue after a restore failure'
    Assert-Equal -Actual $global:DotnetTestResolverRestoreRequests.Count -Expected 2 -Because 'the failed newest candidate and fallback candidate should both be tested'

    Reset-ResolverMock
    Set-TestPackageVersions -Id 'Package.A' -Versions @('2.0.0', '1.0.0')
    Set-TestPackageVersions -Id 'Package.B' -Versions @('2.0.0', '1.0.0')
    $global:DotnetTestResolverFailureMode = 'FailCombination'
    $global:DotnetTestResolverFailureCombination = 'Package.A=2.0.0;Package.B=2.0.0'
    $combined = Invoke-TestResolver -PackageId @('Package.A', 'Package.B') -MaximumCandidates 2
    $combinedResult = Get-ResolverJsonObject -Text $combined.text
    $combinedPackages = @($combinedResult.packages)
    Assert-Equal -Actual $combined.exitCode -Expected 0 -Because 'the resolver should recover from an incompatible combined package set'
    Assert-Equal -Actual (($combinedPackages | Where-Object packageId -eq 'Package.A').version) -Expected '2.0.0' -Because 'the compatible first package candidate should be retained'
    Assert-Equal -Actual (($combinedPackages | Where-Object packageId -eq 'Package.B').version) -Expected '1.0.0' -Because 'the incompatible newest second package candidate should fall back'
    Assert-True -Condition (@($global:DotnetTestResolverRestoreRequests | Where-Object { $_.references.Count -eq 2 }).Count -gt 0) -Because 'compatibility must be tested with the combined package set'
    Assert-Equal -Actual ($combinedPackages | Where-Object packageId -eq 'Package.A').compatibility -Expected 'combined restore passed' -Because 'the output must describe the compatibility actually validated'

    Reset-ResolverMock
    Set-TestPackageVersions -Id 'Failure.Package' -Versions @('2.0.0', '1.0.0')
    $global:DotnetTestResolverFailureMode = 'FailAll'
    $failure = Invoke-TestResolver -PackageId 'Failure.Package' -MaximumCandidates 2
    Assert-True -Condition ($failure.exitCode -ne 0) -Because 'resolver restore failure must fail closed'
    Assert-ContainsText -Text $failure.text -Expected "No stable 'Failure.Package' version" -Because 'failure output must identify the package and candidate scope'
    Assert-ContainsText -Text $failure.text -Expected 'NU_TEST_RESTORE_FAILURE' -Because 'failure output must preserve restore evidence'

    Reset-ResolverMock
    Set-TestPackageVersions -Id 'Cached.Package' -Versions @('5.0.0', '4.0.0')
    $cacheRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('dotnet-test-resolver-cache-' + [Guid]::NewGuid().ToString('N'))
    try {
        $first = Invoke-TestResolver -PackageId 'Cached.Package' -MaximumCandidates 1 -CacheDirectory $cacheRoot
        $firstResult = Get-ResolverJsonObject -Text $first.text
        $firstPackages = @($firstResult.packages)
        Assert-Equal -Actual $first.exitCode -Expected 0 -Because 'cache seed should succeed'
        Assert-False -Condition ([bool]$firstResult.cache.hit) -Because 'first cached resolution should be live'
        Assert-Equal -Actual $firstPackages[0].version -Expected '5.0.0' -Because 'cache seed should still expose the resolved package set'
        $restoreCount = $global:DotnetTestResolverRestoreRequests.Count
        $httpCount = $global:DotnetTestResolverHttpRequests.Count

        $second = Invoke-TestResolver -PackageId 'Cached.Package' -MaximumCandidates 1 -CacheDirectory $cacheRoot
        $secondResult = Get-ResolverJsonObject -Text $second.text
        $secondPackages = @($secondResult.packages)
        Assert-Equal -Actual $second.exitCode -Expected 0 -Because 'cache reuse should succeed'
        Assert-True -Condition ([bool]$secondResult.cache.hit) -Because 'second cached resolution should be served from cache'
        Assert-Equal -Actual $secondPackages[0].version -Expected '5.0.0' -Because 'cache reuse should preserve the cached package data'
        Assert-Equal -Actual $global:DotnetTestResolverRestoreRequests.Count -Expected $restoreCount -Because 'cache reuse should skip compatibility restores'
        Assert-Equal -Actual $global:DotnetTestResolverHttpRequests.Count -Expected $httpCount -Because 'cache reuse should skip NuGet HTTP lookups'
    } finally {
        if (Test-Path -LiteralPath $cacheRoot) { Remove-Item -LiteralPath $cacheRoot -Recurse -Force }
    }

    Reset-ResolverMock
    Set-TestPackageVersions -Id 'Limited.Package' -Versions @('4.0.0', '3.0.0')
    $global:DotnetTestResolverFailureMode = 'FailPackageVersion'
    $global:DotnetTestResolverFailurePackageId = 'Limited.Package'
    $global:DotnetTestResolverFailureVersion = '4.0.0'
    $env:DOTNET_TEST_MAXIMUM_CANDIDATES = '1'
    try {
        $limited = Invoke-TestResolver -PackageId 'Limited.Package' -UseDefaultCandidateLimit
        Assert-True -Condition ($limited.exitCode -ne 0) -Because 'the env candidate limit should constrain default resolver breadth'
        Assert-ContainsText -Text $limited.text -Expected "newest 1 candidates" -Because 'failure output should reflect the env-driven candidate limit'
    } finally {
        Remove-Item Env:DOTNET_TEST_MAXIMUM_CANDIDATES -ErrorAction SilentlyContinue
    }

    # xUnit shipped stable 4.0.0 packages while Codebelt.Extensions.Xunit still declared 3.2.2, so "newest stable"
    # silently jumped the test project a whole xUnit generation past the Codebelt API it targets.
    Reset-ResolverMock
    Set-TestPackageVersions -Id 'Codebelt.Extensions.Xunit' -Versions @('11.2.1', '11.1.0')
    Set-TestPackageNuspec -Id 'Codebelt.Extensions.Xunit' -Version '11.2.1' -Dependencies @{ 'xunit.v3.assert' = '3.2.2'; 'xunit.v3.extensibility.core' = '3.2.2' }
    Set-TestPackageVersions -Id 'xunit.v3.assert' -Versions @('4.0.0', '3.3.0', '3.2.2')
    Set-TestPackageVersions -Id 'xunit.v3' -Versions @('4.0.0', '3.3.0', '3.2.2')
    $anchored = Invoke-TestResolver -PackageId @('Codebelt.Extensions.Xunit', 'xunit.v3', 'xunit.v3.assert') -MaximumCandidates 1
    $anchoredResult = Get-ResolverJsonObject -Text $anchored.text
    $anchoredPackages = @($anchoredResult.packages)
    Assert-Equal -Actual $anchored.exitCode -Expected 0 -Because 'anchored resolution should succeed'
    Assert-Equal -Actual $anchoredResult.xunitAnchor.packageId -Expected 'Codebelt.Extensions.Xunit' -Because 'the unit role must anchor to the Codebelt xUnit package'
    Assert-Equal -Actual $anchoredResult.xunitAnchor.major -Expected 3 -Because 'the xUnit ceiling must come from the Codebelt package dependency major'
    Assert-Equal -Actual (($anchoredPackages | Where-Object packageId -eq 'xunit.v3.assert').version) -Expected '3.2.2' -Because 'an id the anchor declares must match it 1:1 even when a newer same-major version exists'
    Assert-ContainsText -Text (($anchoredPackages | Where-Object packageId -eq 'xunit.v3.assert').constraint) -Expected 'matched 1:1' -Because 'the output must report the 1:1 anchor match'
    Assert-Equal -Actual (($anchoredPackages | Where-Object packageId -eq 'xunit.v3').version) -Expected '3.3.0' -Because 'an id the anchor does not declare may take the newest minor or patch below the anchored major'
    Assert-Equal -Actual (($anchoredPackages | Where-Object packageId -eq 'Codebelt.Extensions.Xunit').version) -Expected '11.2.1' -Because 'the anchor package itself stays unconstrained'
    Assert-True -Condition (@($global:DotnetTestResolverRestoreRequests | Where-Object { @($_.references | Where-Object { $_.version -eq '4.0.0' }).Count -gt 0 }).Count -eq 0) -Because 'no candidate above the anchored major may reach a restore'

    # Anchoring has to precede the candidate trim, otherwise a package whose newest versions are all above the ceiling
    # arrives at resolution with nothing left to try.
    Reset-ResolverMock
    Set-TestPackageVersions -Id 'Codebelt.Extensions.Xunit' -Versions @('11.2.1')
    Set-TestPackageNuspec -Id 'Codebelt.Extensions.Xunit' -Version '11.2.1' -Dependencies @{ 'xunit.v3.assert' = '3.2.2' }
    Set-TestPackageVersions -Id 'xunit.v3' -Versions @('4.0.1', '4.0.0', '3.2.2')
    $trimmed = Invoke-TestResolver -PackageId @('Codebelt.Extensions.Xunit', 'xunit.v3') -MaximumCandidates 2
    $trimmedResult = Get-ResolverJsonObject -Text $trimmed.text
    Assert-Equal -Actual $trimmed.exitCode -Expected 0 -Because 'the candidate limit must apply after the anchored ceiling'
    Assert-Equal -Actual ((@($trimmedResult.packages) | Where-Object packageId -eq 'xunit.v3').version) -Expected '3.2.2' -Because 'the newest candidate below the anchored major must survive the candidate trim'

    Reset-ResolverMock
    Set-TestPackageVersions -Id 'Codebelt.Extensions.Xunit' -Versions @('11.2.1')
    Set-TestPackageNuspec -Id 'Codebelt.Extensions.Xunit' -Version '11.2.1' -Dependencies @{ 'xunit.v3.assert' = '3.2.2' }
    Set-TestPackageVersions -Id 'xunit.runner.visualstudio' -Versions @('4.0.0')
    $ceiling = Invoke-TestResolver -PackageId @('Codebelt.Extensions.Xunit', 'xunit.runner.visualstudio') -MaximumCandidates 2
    Assert-True -Condition ($ceiling.exitCode -ne 0) -Because 'an xunit package with no version below the anchored major must fail closed'
    Assert-ContainsText -Text $ceiling.text -Expected 'at or below major 3' -Because 'the ceiling failure must name the anchored major'

    # A repository that deliberately pins an older Codebelt xUnit must resolve the xUnit generation that release declared.
    Reset-ResolverMock
    Set-TestPackageVersions -Id 'Codebelt.Extensions.Xunit' -Versions @('12.0.0', '11.2.1')
    Set-TestPackageNuspec -Id 'Codebelt.Extensions.Xunit' -Version '12.0.0' -Dependencies @{ 'xunit.v3.assert' = '4.0.0' }
    Set-TestPackageNuspec -Id 'Codebelt.Extensions.Xunit' -Version '11.2.1' -Dependencies @{ 'xunit.v3.assert' = '3.2.2' }
    Set-TestPackageVersions -Id 'xunit.v3' -Versions @('4.0.0', '3.2.2')
    $pinned = Invoke-TestResolver -PackageId @('xunit.v3') -MaximumCandidates 1 -XunitAnchorVersion '11.2.1'
    $pinnedResult = Get-ResolverJsonObject -Text $pinned.text
    Assert-Equal -Actual $pinned.exitCode -Expected 0 -Because 'an explicit anchor version should resolve'
    Assert-Equal -Actual $pinnedResult.xunitAnchor.version -Expected '11.2.1' -Because 'the explicit anchor version must be honored over the newest anchor release'
    Assert-Equal -Actual ((@($pinnedResult.packages) | Where-Object packageId -eq 'xunit.v3').version) -Expected '3.2.2' -Because 'the ceiling must follow the pinned anchor release rather than the newest one'

    Write-Output 'resolve-test-package-versions.ps1 regression: PASS'
} finally {
    foreach ($name in @(
        'DotnetTestResolverVersions',
        'DotnetTestResolverNuspecs',
        'DotnetTestResolverRestoreRequests',
        'DotnetTestResolverHttpRequests',
        'DotnetTestResolverFailureMode',
        'DotnetTestResolverFailurePackageId',
        'DotnetTestResolverFailureVersion',
        'DotnetTestResolverFailureCombination'
    )) {
        Remove-Variable -Scope Global -Name $name -ErrorAction SilentlyContinue
    }
}
