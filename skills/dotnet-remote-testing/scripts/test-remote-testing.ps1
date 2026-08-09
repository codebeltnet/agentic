#!/usr/bin/env pwsh
# Deterministic test harness for the dotnet-remote-testing runner.
#
# Runs the runner's built-in --self-test (pure-logic unit tests) and then exercises the command-line
# surface (list / plan / resolution / failure classification) against fixtures in a temp workspace using
# --offline and an injected release-index file. It never needs Docker or the network, and never writes
# inside this repository (eval isolation).

param(
    [string]$RunnerPath = (Join-Path $PSScriptRoot 'remote-test.cs')
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$PSNativeCommandUseErrorActionPreference = $false

$script:pass = 0
$script:fail = 0

function Write-Result {
    param([bool]$Ok, [string]$Name, [string]$Detail = '')
    if ($Ok) {
        $script:pass++
        Write-Host "[PASS] $Name"
    }
    else {
        $script:fail++
        Write-Host "[FAIL] $Name" -ForegroundColor Red
        if ($Detail) { Write-Host "       $Detail" -ForegroundColor Red }
    }
}

function Invoke-Runner {
    param([string[]]$RunnerArgs)
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $out = & dotnet run --file $RunnerPath -- @RunnerArgs 2>&1 | Out-String
    }
    finally {
        $ErrorActionPreference = $prev
    }
    return [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = $out }
}

function Get-Json {
    param([string]$Text)
    $start = $Text.IndexOf('{')
    if ($start -lt 0) { throw "No JSON object in runner output: $Text" }
    return ($Text.Substring($start) | ConvertFrom-Json)
}

if (-not (Test-Path $RunnerPath)) {
    throw "Runner not found at $RunnerPath"
}

$workspace = Join-Path ([System.IO.Path]::GetTempPath()) ('dotnet-remote-testing-harness-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $workspace -Force | Out-Null

# A representative release index: one active LTS, one maintenance STS, one preview, and one EOL channel.
$indexPath = Join-Path $workspace 'releases-index.json'
@'
{
  "releases-index": [
    { "channel-version": "11.0", "latest-sdk": "11.0.100-preview.6.26359.118", "support-phase": "preview", "release-type": "sts" },
    { "channel-version": "10.0", "latest-sdk": "10.0.302", "support-phase": "active", "release-type": "lts", "eol-date": "2028-11-14" },
    { "channel-version": "9.0", "latest-sdk": "9.0.316", "support-phase": "maintenance", "release-type": "sts", "eol-date": "2026-11-10" },
    { "channel-version": "7.0", "latest-sdk": "7.0.410", "support-phase": "eol", "release-type": "sts" }
  ]
}
'@ | Set-Content -Path $indexPath -Encoding utf8

try {
    Write-Host '== 1. Built-in self-test (pure logic) =='
    $selfTest = Invoke-Runner @('--self-test')
    $selfOk = $selfTest.ExitCode -eq 0 -and $selfTest.Output -match 'Self-test: (\d+) passed, 0 failed'
    Write-Result $selfOk 'runner --self-test passes' ("exit=$($selfTest.ExitCode)")
    if ($selfTest.Output -match 'Self-test: (\d+) passed, (\d+) failed') {
        Write-Host ("       {0} pure-logic assertions passed" -f $matches[1])
    }

    Write-Host ''
    Write-Host '== 2. Zero-configuration list from injected release metadata (offline) =='
    $emptyRoot = Join-Path $workspace 'empty'
    New-Item -ItemType Directory -Path $emptyRoot -Force | Out-Null
    $list = Invoke-Runner @('list', '--repo-root', $emptyRoot, '--offline', '--releases-index-file', $indexPath, '--json')
    $listJson = Get-Json $list.Output
    $names = @($listJson.environments | ForEach-Object { $_.name })
    Write-Result ($names -contains 'dotnet-10-lts') 'derives LTS environment name' ($names -join ',')
    Write-Result ($names -contains 'dotnet-9-sts') 'derives STS environment name'
    Write-Result ($names -contains 'dotnet-11-preview') 'derives preview environment name'
    Write-Result (-not ($names -contains 'dotnet-7-sts')) 'excludes EOL channel'
    $img = ($listJson.environments | Where-Object { $_.name -eq 'dotnet-11-preview' }).image
    Write-Result ($img -eq 'mcr.microsoft.com/dotnet/sdk:11.0.100-preview.6') 'preview image tag strips build metadata' $img
    Write-Result (($listJson.environments | Where-Object { $_.name -eq 'dotnet-10-lts' }).image -eq 'mcr.microsoft.com/dotnet/sdk:10.0.302') 'stable image uses exact SDK tag'

    Write-Host ''
    Write-Host '== 3. Zero-configuration is not an error =='
    Write-Result ($list.ExitCode -eq 0) 'absent testenvironments.json is not an error' ("exit=$($list.ExitCode)")

    Write-Host ''
    Write-Host '== 4. testenvironments.json is authoritative and reports unsupported types =='
    $cfgRoot = Join-Path $workspace 'configured'
    New-Item -ItemType Directory -Path $cfgRoot -Force | Out-Null
    @'
{
  "version": "1",
  "environments": [
    { "name": "ci-docker", "type": "docker", "dockerImage": "mcr.microsoft.com/dotnet/sdk:10.0" },
    { "name": "wsl-env", "type": "wsl", "wslDistribution": "Ubuntu" }
  ]
}
'@ | Set-Content -Path (Join-Path $cfgRoot 'testenvironments.json') -Encoding utf8
    $cfgList = Invoke-Runner @('list', '--repo-root', $cfgRoot, '--json')
    $cfgJson = Get-Json $cfgList.Output
    $cfgNames = @($cfgJson.environments | ForEach-Object { $_.name })
    Write-Result ($cfgNames.Count -eq 1 -and $cfgNames[0] -eq 'ci-docker') 'lists only configured docker environments' ($cfgNames -join ',')
    Write-Result (-not ($cfgNames -contains 'dotnet-10-lts')) 'does not supplement config with generated envs'
    $unsupportedNames = @($cfgJson.unsupported | ForEach-Object { $_.name })
    Write-Result ($unsupportedNames -contains 'wsl-env') 'reports WSL as unsupported'

    Write-Host ''
    Write-Host '== 5. Naming an unsupported environment is reported, not converted =='
    $named = Invoke-Runner @('plan', '--repo-root', $cfgRoot, '-e', 'wsl-env', '--offline', '--json')
    $namedJson = Get-Json $named.Output
    Write-Result ($namedJson.failureKind -eq 'UnsupportedEnvironment') 'unsupported named env -> UnsupportedEnvironment' ("kind=$($namedJson.failureKind) exit=$($named.ExitCode)")

    Write-Host ''
    Write-Host '== 6. plan derives the image offline without pulling =='
    $projDir = Join-Path $emptyRoot 'test\Foo'
    New-Item -ItemType Directory -Path $projDir -Force | Out-Null
    '<Project><PropertyGroup><TargetFramework>net10.0</TargetFramework></PropertyGroup></Project>' | Set-Content -Path (Join-Path $projDir 'Foo.csproj') -Encoding utf8
    $plan = Invoke-Runner @('plan', '--repo-root', $emptyRoot, '-e', 'dotnet-10-lts', '--offline', '--releases-index-file', $indexPath, '--json')
    $planJson = Get-Json $plan.Output
    Write-Result ($planJson.image.reference -eq 'mcr.microsoft.com/dotnet/sdk:10.0.302') 'plan resolves the SDK image reference' $planJson.image.reference
    Write-Result ($planJson.dockerRunArgs -contains '--rm' -and ($planJson.dockerRunArgs -notcontains '--privileged')) 'plan run args are --rm and not privileged'
    Write-Result (@($planJson.dockerRunArgs) -notcontains '/var/run/docker.sock' -and -not ($plan.Output -match 'docker\.sock')) 'plan never mounts the docker socket'

    Write-Host ''
    Write-Host '== 7. Conflicting docker source is a configuration failure =='
    $badRoot = Join-Path $workspace 'bad'
    New-Item -ItemType Directory -Path $badRoot -Force | Out-Null
    @'
{ "version": "1", "environments": [ { "name": "x", "type": "docker", "dockerImage": "a", "dockerFile": "b" } ] }
'@ | Set-Content -Path (Join-Path $badRoot 'testenvironments.json') -Encoding utf8
    $bad = Invoke-Runner @('list', '--repo-root', $badRoot, '--json')
    $badJson = Get-Json $bad.Output
    $codes = @($badJson.configDiagnostics | ForEach-Object { $_.Code })
    Write-Result ($codes -contains 'CONFLICTING_DOCKER_SOURCE') 'reports CONFLICTING_DOCKER_SOURCE' ($codes -join ',')
}
finally {
    Remove-Item $workspace -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host ''
Write-Host ("Harness: {0} passed, {1} failed." -f $script:pass, $script:fail)
if ($script:fail -gt 0) { exit 1 } else { exit 0 }
