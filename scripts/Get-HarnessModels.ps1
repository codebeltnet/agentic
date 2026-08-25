<#
.SYNOPSIS
    Lists current model selectors for a supported eval harness.

.DESCRIPTION
    Discovers runner-native model selectors without executing model requests. GitHub Copilot and Codex return every
    model the harness exposes. OpenCode returns only models whose current catalog metadata proves free
    availability. Discovery failures are local to the selected harness and never fall back to stale hardcoded catalogs.

.PARAMETER Runner
    Internal Eval Runner id: github-copilot, codex, or opencode.

.PARAMETER CatalogPath
    Optional deterministic catalog fixture used by tests. When supplied, no harness command is invoked.

.PARAMETER RequireModel
    Optional model selector that must exist in the discovered list.

.PARAMETER Refresh
    For harnesses that support explicit catalog refresh, request a refresh before listing. This never executes a model
    prompt.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('github-copilot', 'codex', 'opencode')]
    [string]$Runner,

    [string]$CatalogPath,

    [string]$RequireModel,

    [switch]$Refresh
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$runnerCommon = Join-Path $PSScriptRoot 'eval-runners/runner-common.ps1'
. $runnerCommon

$utf8NoBom = [System.Text.UTF8Encoding]::new($false)

function Get-HarnessDisplayName {
    param([Parameter(Mandatory = $true)][string]$RunnerName)

    switch ($RunnerName) {
        'github-copilot' { return 'GitHub Copilot CLI' }
        'codex' { return 'Codex CLI' }
        'opencode' { return 'OpenCode' }
        default { return $RunnerName }
    }
}

function Get-PolicyName {
    param([Parameter(Mandatory = $true)][string]$RunnerName)

    if ($RunnerName -eq 'opencode') {
        return 'free'
    }
    return 'all'
}

function Read-CatalogJson {
    param([Parameter(Mandatory = $true)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Catalog fixture '$Path' does not exist."
    }
    return [System.IO.File]::ReadAllText((Resolve-Path -LiteralPath $Path).Path, $utf8NoBom) | ConvertFrom-Json
}

function Get-FirstPropertyValue {
    param(
        [object]$Object,
        [string[]]$Names
    )

    foreach ($name in $Names) {
        $value = Get-JsonProperty -Object $Object -Name $name -Default $null
        if ($null -ne $value -and -not [string]::IsNullOrWhiteSpace([string]$value)) {
            return [string]$value
        }
    }
    return $null
}

function Get-NumericPropertyValues {
    param([object]$Object)

    $values = [System.Collections.Generic.List[double]]::new()
    if ($null -eq $Object) {
        return @()
    }

    if ($Object -is [System.Collections.IEnumerable] -and -not ($Object -is [string]) -and -not ($Object -is [System.Collections.IDictionary]) -and -not ($Object -is [pscustomobject])) {
        foreach ($item in $Object) {
            foreach ($child in @(Get-NumericPropertyValues -Object $item)) { $values.Add([double]$child) }
        }
        return @($values)
    }

    if ($Object -is [System.Collections.IDictionary]) {
        $propertyNames = @($Object.Keys)
        foreach ($name in $propertyNames) {
            $value = $Object[$name]
            if ($value -is [int] -or $value -is [long] -or $value -is [double] -or $value -is [decimal]) {
                $values.Add([double]$value)
            } elseif ($null -ne $value -and -not ($value -is [string]) -and -not ($value -is [System.ValueType]) -and ($value -is [System.Collections.IDictionary] -or $value -is [pscustomobject] -or $value -is [System.Collections.IEnumerable])) {
                foreach ($child in @(Get-NumericPropertyValues -Object $value)) { $values.Add([double]$child) }
            }
        }
        return @($values)
    }

    foreach ($property in @($Object.PSObject.Properties)) {
        $value = $property.Value
        if ($value -is [int] -or $value -is [long] -or $value -is [double] -or $value -is [decimal]) {
            $values.Add([double]$value)
        } elseif ($null -ne $value -and -not ($value -is [string]) -and -not ($value -is [System.ValueType]) -and ($value -is [System.Collections.IDictionary] -or $value -is [pscustomobject] -or $value -is [System.Collections.IEnumerable])) {
            foreach ($child in @(Get-NumericPropertyValues -Object $value)) { $values.Add([double]$child) }
        }
    }
    return @($values)
}

function Get-ModelAvailability {
    param([object]$Model)

    $explicit = Get-FirstPropertyValue -Object $Model -Names @('availability', 'billing', 'usageCostDisplay')
    if (-not [string]::IsNullOrWhiteSpace($explicit)) {
        $normalized = $explicit.ToLowerInvariant()
        if ($normalized -eq 'free') { return 'free' }
        if ($normalized -in @('paid', 'subscription', 'metered')) { return 'paid' }
    }

    foreach ($name in @('free', 'isFree')) {
        $value = Get-JsonProperty -Object $Model -Name $name -Default $null
        if ($null -eq $value) {
            continue
        }
        if ([bool]$value) { return 'free' }
        return 'paid'
    }

    foreach ($propertyName in @('pricing', 'cost')) {
        $price = Get-JsonProperty -Object $Model -Name $propertyName -Default $null
        $numbers = @(Get-NumericPropertyValues -Object $price)
        if ($numbers.Count -gt 0) {
            if (@($numbers | Where-Object { [double]$_ -gt 0 }).Count -gt 0) {
                return 'paid'
            }
            return 'free'
        }
    }

    return 'unknown'
}

function Test-TextModel {
    param([object]$Model)

    $operation = [string](Get-JsonProperty -Object $Model -Name 'operation' -Default '')
    if (-not [string]::IsNullOrWhiteSpace($operation) -and $operation -notin @('language', 'chat', 'completion')) {
        return $false
    }
    return $true
}

function ConvertTo-ModelChoice {
    param(
        [Parameter(Mandatory = $true)][object]$Model,
        [Parameter(Mandatory = $true)][string]$RunnerName,
        [string]$Source,
        [string]$ExplicitSelector
    )

    if (-not (Test-TextModel -Model $Model)) {
        return $null
    }

    $id = if ([string]::IsNullOrWhiteSpace($ExplicitSelector)) {
        Get-FirstPropertyValue -Object $Model -Names @('id', 'slug', 'model', 'modelId', 'model_id')
    } else {
        $ExplicitSelector
    }
    if ([string]::IsNullOrWhiteSpace($id)) {
        return $null
    }

    $provider = Get-FirstPropertyValue -Object $Model -Names @('providerID', 'providerId', 'provider')
    if ($RunnerName -eq 'opencode' -and $id -notmatch '/' -and -not [string]::IsNullOrWhiteSpace($provider)) {
        $id = "$provider/$id"
    }

    $displayName = Get-FirstPropertyValue -Object $Model -Names @('display_name', 'displayName', 'name')
    if ([string]::IsNullOrWhiteSpace($displayName)) {
        $displayName = $id
    }

    return [pscustomobject][ordered]@{
        id = $id
        display_name = $displayName
        availability = Get-ModelAvailability -Model $Model
        source = $Source
    }
}

function ConvertTo-ModelChoices {
    param(
        [Parameter(Mandatory = $true)][object]$Catalog,
        [Parameter(Mandatory = $true)][string]$RunnerName,
        [Parameter(Mandatory = $true)][string]$Source
    )

    $rawModels = [System.Collections.Generic.List[object]]::new()
    if ($Catalog -is [array]) {
        foreach ($model in $Catalog) { $rawModels.Add($model) }
    } elseif (Test-JsonProperty -Object $Catalog -Name 'models') {
        foreach ($model in @($Catalog.models)) { $rawModels.Add($model) }
    } else {
        foreach ($propertyName in @(Get-JsonPropertyNames -Object $Catalog)) {
            $value = Get-JsonProperty -Object $Catalog -Name $propertyName -Default $null
            if ($null -ne $value -and @($value.PSObject.Properties).Count -gt 0) {
                if (-not (Test-JsonProperty -Object $value -Name 'id')) {
                    $value | Add-Member -NotePropertyName id -NotePropertyValue $propertyName -Force
                }
                $rawModels.Add($value)
            }
        }
    }

    $choices = [System.Collections.Generic.List[object]]::new()
    foreach ($model in $rawModels) {
        $choice = ConvertTo-ModelChoice -Model $model -RunnerName $RunnerName -Source $Source
        if ($null -ne $choice) {
            $choices.Add($choice)
        }
    }
    $seen = @{}
    $deduped = [System.Collections.Generic.List[object]]::new()
    foreach ($choice in @($choices | Sort-Object id)) {
        if (-not $seen.ContainsKey([string]$choice.id)) {
            $seen[[string]$choice.id] = $true
            $deduped.Add($choice)
        }
    }
    return @($deduped)
}

function Select-ModelsByPolicy {
    param(
        [object[]]$Models,
        [Parameter(Mandatory = $true)][string]$RunnerName
    )

    $policy = Get-PolicyName -RunnerName $RunnerName
    if ($policy -eq 'free') {
        $freeModels = @($Models | Where-Object { [string]$_.availability -eq 'free' })
        if ($freeModels.Count -eq 0) {
            throw "No free $((Get-HarnessDisplayName -RunnerName $RunnerName)) models are currently available from discovery. Choose another harness or update the harness catalog."
        }
        return @($freeModels)
    }

    return @($Models)
}

function Invoke-JsonCommand {
    param(
        [Parameter(Mandatory = $true)][object]$CommandInfo,
        [Parameter(Mandatory = $true)][string[]]$Arguments,
        [int]$TimeoutSeconds = 60
    )

    $work = Join-Path ([System.IO.Path]::GetTempPath()) ('agentic-model-discovery-' + [Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $work -Force | Out-Null
    try {
        $environment = New-RunnerProbeEnvironment
        foreach ($name in @('HOME', 'USERPROFILE', 'APPDATA', 'LOCALAPPDATA', 'XDG_CONFIG_HOME')) {
            $value = [Environment]::GetEnvironmentVariable($name)
            if (-not [string]::IsNullOrWhiteSpace($value)) {
                $environment[$name] = $value
            }
        }
        $process = Invoke-RunnerProcess -FileName $CommandInfo.FileName -ArgumentList (@($CommandInfo.Prefix) + @($Arguments)) -WorkingDirectory $work -Environment $environment -TimeoutSeconds $TimeoutSeconds
        if ($process.TimedOut) {
            throw "Command '$($CommandInfo.Source)' timed out during model discovery."
        }
        if ($process.ExitCode -ne 0) {
            $detail = [string]::Join("`n", @($process.Stdout, $process.Stderr)).Trim()
            throw "Command '$($CommandInfo.Source) $($Arguments -join ' ')' failed during model discovery with exit code $($process.ExitCode). $detail"
        }
        return [pscustomobject]@{ Stdout = $process.Stdout; Stderr = $process.Stderr }
    } finally {
        if (Test-Path -LiteralPath $work) {
            Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

function ConvertFrom-OpenCodeTextCatalog {
    param([Parameter(Mandatory = $true)][string]$Text)

    $models = [System.Collections.Generic.List[object]]::new()
    $lines = $Text -split "`r?`n"
    $currentSelector = $null
    $buffer = [System.Collections.Generic.List[string]]::new()
    $depth = 0
    foreach ($line in $lines) {
        $trimmed = $line.Trim()
        if ([string]::IsNullOrWhiteSpace($trimmed)) {
            continue
        }
        if ($depth -eq 0 -and $trimmed -match '^[^\s/]+/.+$') {
            $currentSelector = $trimmed
            continue
        }
        if ($trimmed.StartsWith('{') -or $depth -gt 0) {
            $buffer.Add($line)
            $depth += ([regex]::Matches($line, '\{')).Count
            $depth -= ([regex]::Matches($line, '\}')).Count
            if ($depth -le 0 -and $buffer.Count -gt 0) {
                $json = [string]::Join("`n", @($buffer))
                $object = $json | ConvertFrom-Json
                $choice = ConvertTo-ModelChoice -Model $object -RunnerName 'opencode' -Source 'opencode models --verbose' -ExplicitSelector $currentSelector
                if ($null -ne $choice) { $models.Add($choice) }
                $buffer.Clear()
                $depth = 0
                $currentSelector = $null
            }
        }
    }
    return @($models)
}

function Resolve-CopilotSdkPath {
    $command = Resolve-ExternalCommand -Name 'copilot'
    if ($null -eq $command) {
        throw 'GitHub Copilot CLI executable is not available on PATH.'
    }

    $source = [string]$command.Source
    $directory = Split-Path -Parent $source
    $candidates = [System.Collections.Generic.List[string]]::new()
    $optionalRoot = Join-Path $directory 'node_modules/@github/copilot/node_modules/@github'
    if (Test-Path -LiteralPath $optionalRoot -PathType Container) {
        foreach ($package in @(Get-ChildItem -LiteralPath $optionalRoot -Directory -Filter 'copilot-*' -Force)) {
            $candidates.Add((Join-Path $package.FullName 'sdk/index.js'))
        }
    }
    $candidates.Add((Join-Path $directory 'node_modules/@github/copilot/node_modules/@github/copilot-win32-x64/sdk/index.js'))
    $candidates.Add((Join-Path $directory 'node_modules/@github/copilot/node_modules/@github/copilot-win32-arm64/sdk/index.js'))
    $candidates.Add((Join-Path $directory 'node_modules/@github/copilot/node_modules/@github/copilot-linux-x64/sdk/index.js'))
    $candidates.Add((Join-Path $directory 'node_modules/@github/copilot/node_modules/@github/copilot-linux-arm64/sdk/index.js'))
    $candidates.Add((Join-Path $directory 'node_modules/@github/copilot/node_modules/@github/copilot-darwin-x64/sdk/index.js'))
    $candidates.Add((Join-Path $directory 'node_modules/@github/copilot/node_modules/@github/copilot-darwin-arm64/sdk/index.js'))
    foreach ($candidate in $candidates) {
        $full = [System.IO.Path]::GetFullPath($candidate)
        if (Test-Path -LiteralPath $full -PathType Leaf) {
            return $full
        }
    }

    throw 'GitHub Copilot CLI does not expose a package-local SDK model listing surface in this installation.'
}

function Get-CodexModels {
    $command = Resolve-ExternalCommand -Name 'codex'
    if ($null -eq $command) {
        throw 'Codex CLI executable is not available on PATH.'
    }
    $result = Invoke-JsonCommand -CommandInfo $command -Arguments @('debug', 'models') -TimeoutSeconds 60
    $catalog = $result.Stdout | ConvertFrom-Json
    return ConvertTo-ModelChoices -Catalog $catalog -RunnerName 'codex' -Source 'codex debug models'
}

function Get-OpenCodeModels {
    $command = Resolve-ExternalCommand -Name 'opencode'
    if ($null -eq $command) {
        throw 'OpenCode CLI executable is not available on PATH.'
    }
    $arguments = @('models', 'opencode', '--verbose')
    if ($Refresh) { $arguments += '--refresh' }
    $result = Invoke-JsonCommand -CommandInfo $command -Arguments $arguments -TimeoutSeconds 180
    return ConvertFrom-OpenCodeTextCatalog -Text $result.Stdout
}

function Get-CopilotModels {
    $sdkPath = Resolve-CopilotSdkPath
    $node = Resolve-ExternalCommand -Name 'node'
    if ($null -eq $node) {
        throw 'Node.js is required to read the GitHub Copilot CLI model registry.'
    }

    $script = @'
import { pathToFileURL } from "node:url";
const sdkPath = process.argv[1];
const mod = await import(pathToFileURL(sdkPath).href);
const ids = Array.isArray(mod.HELP_VISIBLE_MODELS)
  ? mod.HELP_VISIBLE_MODELS
  : Object.keys(mod.SUPPORTED_MODELS || {});
console.log(JSON.stringify({ models: ids.map((id) => ({ id, name: id, operation: "language" })) }));
'@
    $result = Invoke-JsonCommand -CommandInfo $node -Arguments @('--input-type=module', '-e', $script, $sdkPath) -TimeoutSeconds 90
    $catalog = $result.Stdout | ConvertFrom-Json
    return ConvertTo-ModelChoices -Catalog $catalog -RunnerName 'github-copilot' -Source 'GitHub Copilot CLI help-visible model catalog'
}

try {
    $rawModels = if (-not [string]::IsNullOrWhiteSpace($CatalogPath)) {
        ConvertTo-ModelChoices -Catalog (Read-CatalogJson -Path $CatalogPath) -RunnerName $Runner -Source $CatalogPath
    } else {
        switch ($Runner) {
            'github-copilot' { Get-CopilotModels }
            'codex' { Get-CodexModels }
            'opencode' { Get-OpenCodeModels }
        }
    }
    $models = @(Select-ModelsByPolicy -Models @($rawModels) -RunnerName $Runner)
    if ($models.Count -eq 0) {
        throw "No models were returned for $((Get-HarnessDisplayName -RunnerName $Runner))."
    }

    if (-not [string]::IsNullOrWhiteSpace($RequireModel) -and @($models | Where-Object { [string]$_.id -eq $RequireModel }).Count -eq 0) {
        $available = [string]::Join(', ', @($models | Select-Object -ExpandProperty id))
        throw "Required model '$RequireModel' was not returned by current $((Get-HarnessDisplayName -RunnerName $Runner)) discovery. Available models: $available"
    }

    [ordered]@{
        schema = 'codebeltnet/agentic/harness-models/1'
        runner = $Runner
        harness = Get-HarnessDisplayName -RunnerName $Runner
        policy = Get-PolicyName -RunnerName $Runner
        models = @($models)
    } | ConvertTo-Json -Depth 20
} catch {
    [Console]::Error.WriteLine($_.Exception.Message)
    exit 2
}
