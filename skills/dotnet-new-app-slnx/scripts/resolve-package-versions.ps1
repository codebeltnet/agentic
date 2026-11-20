param(
    [string]$TemplatePath,

    [Parameter(Mandatory = $true)]
    [string]$TargetFramework
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($TemplatePath)) {
    $TemplatePath = Join-Path $PSScriptRoot '../assets/shared/Directory.Packages.props'
}

[xml]$template = Get-Content -LiteralPath $TemplatePath -Raw
$packageNodes = $template.SelectNodes('/Project/ItemGroup/PackageVersion[@Include and @Version]')
if ($packageNodes.Count -eq 0) {
    throw "No PackageVersion entries found in $TemplatePath"
}

$serviceIndex = Invoke-RestMethod -Uri 'https://api.nuget.org/v3/index.json'
$registrationBase = $serviceIndex.resources |
    Where-Object { $_.'@type' -eq 'RegistrationsBaseUrl/3.6.0' } |
    Select-Object -First 1 -ExpandProperty '@id'

if ([string]::IsNullOrWhiteSpace($registrationBase)) {
    throw 'Could not locate RegistrationsBaseUrl/3.6.0 in the NuGet service index.'
}

$result = [ordered]@{}
foreach ($node in $packageNodes) {
    $packageId = [string]$node.Include
    $placeholder = [string]$node.Version
    $indexUrl = '{0}/{1}/index.json' -f $registrationBase.TrimEnd('/'), $packageId.ToLowerInvariant()
    $index = Invoke-RestMethod -Uri $indexUrl
    $versions = @(
        foreach ($page in $index.items) {
            $leaves = if ($null -ne $page.PSObject.Properties['items']) {
                $page.items
            } else {
                (Invoke-RestMethod -Uri $page.'@id').items
            }

            foreach ($leaf in $leaves) {
                $entry = $leaf.catalogEntry
                if ($entry.listed -eq $true -and $entry.version.Split('+', 2)[0] -notmatch '-') {
                    $entry.version
                }
            }
        }
    )
    $versions = @($versions | Sort-Object { [version]($_.Split('+', 2)[0]) } -Descending)
    if ($versions.Count -eq 0) {
        throw "No stable listed versions returned for $packageId from $indexUrl"
    }

    $result[$placeholder] = [ordered]@{
        package_id = $packageId
        version = $versions[0]
        candidate_versions = $versions
        target_framework = $TargetFramework
        compatibility_status = 'provisional'
    }
}

Write-Warning 'Inspect package assets and dependency ranges, then restore and build the combined scaffold for the selected framework before accepting a candidate.'
$result | ConvertTo-Json -Depth 4
