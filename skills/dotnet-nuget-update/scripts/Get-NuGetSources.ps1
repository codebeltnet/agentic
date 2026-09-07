[CmdletBinding()]
param(
    [string]$RepoRoot,
    [switch]$AsJson
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-ConfigPath {
    param([string]$RepositoryRoot)

    if (-not [string]::IsNullOrWhiteSpace($RepositoryRoot)) {
        $candidate = Join-Path (Resolve-Path -LiteralPath $RepositoryRoot).Path 'NuGet.Config'
        if (Test-Path -LiteralPath $candidate) { return $candidate }
    }

    if ($IsWindows) {
        $userConfig = Join-Path $env:APPDATA 'NuGet\NuGet.Config'
    } else {
        $userConfig = Join-Path $HOME '.nuget/NuGet/NuGet.Config'
    }

    if (Test-Path -LiteralPath $userConfig) { return $userConfig }
    return $null
}

function Get-CredentialMap {
    param([xml]$Xml)

    $map = @{}
    $credentials = $Xml.configuration.packageSourceCredentials
    if (-not $credentials) { return $map }

    foreach ($sourceNode in @($credentials.ChildNodes | Where-Object { $_.NodeType -eq 'Element' })) {
        $username = $null
        $hasCredentials = $false
        foreach ($addNode in @($sourceNode.ChildNodes | Where-Object { $_.NodeType -eq 'Element' -and $_.Name -eq 'add' })) {
            $key = if ($addNode.Attributes['key']) { [string]$addNode.Attributes['key'].Value } else { $null }
            $value = if ($addNode.Attributes['value']) { [string]$addNode.Attributes['value'].Value } else { $null }
            if ($key -eq 'Username') { $username = $value }
            if ($key -in @('Username', 'Password', 'ClearTextPassword', 'ValidAuthenticationTypes')) { $hasCredentials = $true }
        }
        $map[$sourceNode.Name] = [pscustomobject]@{ username = $username; hasCredentials = $hasCredentials }
    }

    return $map
}

$configPath = Get-ConfigPath -RepositoryRoot $RepoRoot
if (-not $configPath) {
    $default = [pscustomobject]@{
        configPath = $null
        sources    = @([pscustomobject]@{
            key             = 'nuget.org'
            value           = 'https://api.nuget.org/v3/index.json'
            protocolVersion = $null
            username        = $null
            hasCredentials  = $false
        })
    }
    if ($AsJson) { $default | ConvertTo-Json -Depth 8 } else { $default }
    return
}

[xml]$xml = Get-Content -Raw -LiteralPath $configPath
$credentialMap = Get-CredentialMap -Xml $xml
$sources = [System.Collections.Generic.List[object]]::new()

foreach ($addNode in @($xml.configuration.packageSources.add)) {
    $key = if ($addNode.Attributes['key']) { [string]$addNode.Attributes['key'].Value } else { $null }
    $value = if ($addNode.Attributes['value']) { [string]$addNode.Attributes['value'].Value } else { $null }
    $protocolVersion = if ($addNode.Attributes['protocolVersion']) { [string]$addNode.Attributes['protocolVersion'].Value } else { $null }
    $credential = if ($key -and $credentialMap.ContainsKey($key)) { $credentialMap[$key] } else { $null }

    $sources.Add([pscustomobject]@{
        key             = $key
        value           = $value
        protocolVersion = $protocolVersion
        username        = if ($credential) { $credential.username } else { $null }
        hasCredentials  = if ($credential) { $credential.hasCredentials } else { $false }
    })
}

$result = [pscustomobject]@{
    configPath = $configPath
    sources    = @($sources)
}

if ($AsJson) {
    $result | ConvertTo-Json -Depth 8
} else {
    $result
}
