param(
    [Parameter(Mandatory = $true)]
    [string[]]$TargetFramework,

    [Parameter(Mandatory = $true)]
    [ValidateSet('Unit', 'WebFunctional', 'ApplicationFunctional')]
    [string]$Role,

    [string[]]$PackageId,

    [ValidateRange(1, 100)]
    [int]$MaximumCandidates = 30
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$utf8NoBom = [System.Text.UTF8Encoding]::new($false)
[Console]::OutputEncoding = $utf8NoBom
$OutputEncoding = $utf8NoBom

function Get-VersionKey {
    param([string]$Version)
    $parts = $Version.Split('.')
    return [pscustomobject]@{
        major = if ($parts.Count -gt 0) { [int]$parts[0] } else { 0 }
        minor = if ($parts.Count -gt 1) { [int]$parts[1] } else { 0 }
        patch = if ($parts.Count -gt 2) { [int]$parts[2] } else { 0 }
        revision = if ($parts.Count -gt 3) { [int]$parts[3] } else { 0 }
        text = $Version
    }
}

function Test-PackageCompatibility {
    param([object[]]$Packages, [string[]]$Frameworks, [string]$Workspace)

    $projectPath = Join-Path $Workspace 'compatibility.csproj'
    $frameworkElement = if ($Frameworks.Count -eq 1) {
        "<TargetFramework>$($Frameworks[0])</TargetFramework>"
    } else {
        "<TargetFrameworks>$($Frameworks -join ';')</TargetFrameworks>"
    }
    $packageReferences = @(
        foreach ($package in @($Packages)) {
            '    <PackageReference Include="{0}" Version="{1}" />' -f $package.packageId, $package.version
        }
    ) -join [Environment]::NewLine
    $xml = @"
<Project Sdk="Microsoft.NET.Sdk">
  <PropertyGroup>
    $frameworkElement
    <RestorePackagesPath>$(Join-Path $Workspace 'packages')</RestorePackagesPath>
  </PropertyGroup>
  <ItemGroup>
$packageReferences
  </ItemGroup>
</Project>
"@
    [System.IO.File]::WriteAllText($projectPath, $xml, $utf8NoBom)
    $output = @(& dotnet restore $projectPath --nologo --verbosity quiet --force-evaluate 2>&1)
    return [pscustomobject]@{
        compatible = $LASTEXITCODE -eq 0
        output = ($output -join [Environment]::NewLine)
    }
}

foreach ($framework in $TargetFramework) {
    if ($framework -notmatch '^net(?:standard)?\d+(?:\.\d+)+$|^net\d{2,3}$') {
        throw "Unsupported target framework syntax: '$framework'."
    }
}

$packageIds = if ($PackageId -and $PackageId.Count -gt 0) {
    @($PackageId)
} else {
    $codebeltPackage = if ($Role -eq 'Unit') { 'Codebelt.Extensions.Xunit' } else { 'Codebelt.Extensions.Xunit.App' }
    @('Microsoft.NET.Test.Sdk', 'xunit.v3', 'xunit.v3.runner.console', 'xunit.runner.visualstudio', $codebeltPackage)
}

$serviceIndex = Invoke-RestMethod -Uri 'https://api.nuget.org/v3/index.json'
$packageBaseAddress = $serviceIndex.resources |
    Where-Object { $_.'@type' -eq 'PackageBaseAddress/3.0.0' } |
    Select-Object -First 1 -ExpandProperty '@id'
if ([string]::IsNullOrWhiteSpace($packageBaseAddress)) { throw 'NuGet service index did not expose PackageBaseAddress/3.0.0.' }

$workspace = Join-Path ([System.IO.Path]::GetTempPath()) ('dotnet-test-package-resolution-' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $workspace -Force | Out-Null

try {
    $packageCandidates = [System.Collections.Generic.List[object]]::new()
    foreach ($id in @($packageIds | Sort-Object -Unique)) {
        $indexUrl = '{0}{1}/index.json' -f $packageBaseAddress, $id.ToLowerInvariant()
        try { $index = Invoke-RestMethod -Uri $indexUrl } catch { throw "NuGet lookup failed for '$id' at '$indexUrl': $($_.Exception.Message)" }
        $candidates = @($index.versions |
            Where-Object { $_ -match '^\d+(?:\.\d+){1,3}$' } |
            ForEach-Object { Get-VersionKey -Version $_ } |
            Sort-Object major, minor, patch, revision -Descending |
            Select-Object -First $MaximumCandidates)
        if ($candidates.Count -eq 0) { throw "NuGet returned no stable versions for '$id'." }
        $packageCandidates.Add([pscustomobject]@{ packageId = $id; source = $indexUrl; candidates = $candidates })
    }

    function Resolve-PackageSet {
        param([int]$Index, [object[]]$Selected)

        if ($Index -ge $packageCandidates.Count) {
            return [pscustomobject]@{
                compatible = $true
                packages = @($Selected)
            }
        }

        $package = $packageCandidates[$Index]
        $lastFailure = $null
        foreach ($candidate in @($package.candidates)) {
            $packageWorkspace = Join-Path $workspace ([System.IO.Path]::GetRandomFileName())
            New-Item -ItemType Directory -Path $packageWorkspace -Force | Out-Null
            $selectedPackage = [pscustomobject]@{
                packageId = $package.packageId
                version = $candidate.text
                source = $package.source
            }
            $trial = @($Selected) + $selectedPackage
            $compatibility = Test-PackageCompatibility -Packages $trial -Frameworks $TargetFramework -Workspace $packageWorkspace
            if (-not $compatibility.compatible) {
                $lastFailure = $compatibility.output
                continue
            }

            $resolution = Resolve-PackageSet -Index ($Index + 1) -Selected $trial
            if ($resolution.compatible) {
                return $resolution
            }
            $lastFailure = $resolution.output
        }

        return [pscustomobject]@{
            compatible = $false
            packageId = $package.packageId
            candidateCount = @($package.candidates).Count
            output = $lastFailure
        }
    }

    $resolution = Resolve-PackageSet -Index 0 -Selected @()
    if (-not $resolution.compatible) {
        throw "No stable '$($resolution.packageId)' version among the newest $($resolution.candidateCount) candidates restored with a compatible package set for '$($TargetFramework -join ';')'. Last restore output:`n$($resolution.output)"
    }

    $resolved = [System.Collections.Generic.List[object]]::new()
    foreach ($package in @($resolution.packages)) {
        $resolved.Add([pscustomobject]@{
            packageId = $package.packageId
            version = $package.version
            source = $package.source
            compatibility = 'combined restore passed'
        })
    }

    [ordered]@{
        role = $Role
        targetFrameworks = @($TargetFramework)
        packages = @($resolved | Sort-Object packageId)
    } | ConvertTo-Json -Depth 5
} finally {
    if (Test-Path -LiteralPath $workspace) { Remove-Item -LiteralPath $workspace -Recurse -Force }
}
