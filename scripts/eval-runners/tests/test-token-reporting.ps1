<# Deterministic telemetry normalization and report adapter regression; no harness calls. #>
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$runnerRoot = Split-Path -Parent $PSScriptRoot
. (Join-Path $runnerRoot 'runner-common.ps1')

function Import-TestFunction {
    param([string]$Path, [string[]]$Names)
    $parseTokens = $null
    $errors = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile($Path, [ref]$parseTokens, [ref]$errors)
    if ($errors.Count) { throw "Cannot parse $Path" }
    foreach ($name in $Names) {
        $definition = $ast.Find({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name }, $true)
        if ($null -eq $definition) { throw "Missing $name" }
        . ([scriptblock]::Create($definition.Extent.Text.Replace("function $name {", "function script:$name {")))
    }
}
function Assert-Value {
    param($Expected, $Actual, [string]$Message)
    if ($Expected -cne $Actual) { throw "ASSERT: $Message (expected '$Expected', got '$Actual')" }
}

Import-TestFunction (Join-Path $runnerRoot 'bridge-execution-result.ps1') @('Get-NormalizedTotalTokens')
Import-TestFunction (Join-Path (Split-Path $runnerRoot -Parent) 'generate-eval-report.ps1') @('Set-BenchmarkTokenMetrics', 'Read-JsonFile', 'Get-Property')
$utf8NoBom = [Text.UTF8Encoding]::new($false)
$buckets = [ordered]@{ input_tokens = 18245; cached_input_tokens = 17152; output_tokens = 200; reasoning_output_tokens = 43 }
Assert-Value 18445 (Get-NormalizedTotalTokens $buckets) 'derive input plus output only'
$buckets.total_tokens = 99
Assert-Value 99 (Get-NormalizedTotalTokens $buckets) 'explicit total is authoritative'
$buckets.total_tokens = 0
Assert-Value 0 (Get-NormalizedTotalTokens $buckets) 'explicit zero is valid'
$buckets.total_tokens = -1
Assert-Value 18445 (Get-NormalizedTotalTokens $buckets) 'invalid explicit total falls back to valid buckets'
foreach ($invalid in @($null, @{}, @{ input_tokens = 18245 }, @{ output_tokens = 200 }, @{ input_tokens = -1; output_tokens = 200 }, @{ input_tokens = '18245'; output_tokens = 200 }, @{ input_tokens = [double]::NaN; output_tokens = 200 }, @{ input_tokens = [double]::PositiveInfinity; output_tokens = 200 }, @{ input_tokens = $true; output_tokens = 200 })) {
    Assert-Value $null (Get-NormalizedTotalTokens $invalid) 'unavailable or invalid buckets remain null'
}

$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('agentic-token-reporting-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $testRoot | Out-Null
try {
    $records = foreach ($configuration in @('with_skill', 'without_skill')) {
        $resultPath = Join-Path $testRoot "$configuration.json"
        [IO.File]::WriteAllText($resultPath, '{"total_tokens":18445}', $utf8NoBom)
        [pscustomobject]@{ EvalId = 1; Configuration = $configuration; ResultPath = $resultPath }
    }
    $benchmark = '{"runs":[{"eval_id":1,"configuration":"with_skill","result":{"tokens":0}},{"eval_id":1,"configuration":"without_skill","result":{"tokens":0}}],"run_summary":{"with_skill":{"tokens":{}},"without_skill":{"tokens":{}},"delta":{"tokens":"+0"}}}' | ConvertFrom-Json
    $row = Set-BenchmarkTokenMetrics $benchmark $records
    $jsonPath = Join-Path $testRoot 'benchmark.json'
    [IO.File]::WriteAllText($jsonPath, ($benchmark | ConvertTo-Json -Depth 20), $utf8NoBom)
    $persisted = Read-JsonFile $jsonPath
    Assert-Value 18445 $persisted.runs[0].result.tokens 'benchmark JSON retains derived tokens'
    Assert-Value 18445 $persisted.run_summary.with_skill.tokens.mean 'benchmark summary retains nonzero tokens'
    Assert-Value '| Tokens | 18445 ± 0 | 18445 ± 0 | +0 |' $row 'benchmark Markdown retains derived totals'
    $markdownPath = Join-Path $testRoot 'benchmark.md'
    $markdown = [regex]::Replace("| Tokens | 0 ± 0 | 0 ± 0 | +0 |`n", '(?m)^\| Tokens \|.*$', $row)
    [IO.File]::WriteAllText($markdownPath, $markdown, $utf8NoBom)
    Assert-Value ($row + "`n") ([IO.File]::ReadAllText($markdownPath, $utf8NoBom)) 'persisted benchmark Markdown uses canonical token totals'
    [IO.File]::WriteAllText($records[1].ResultPath, '{"total_tokens":null}', $utf8NoBom)
    $row = Set-BenchmarkTokenMetrics $benchmark $records
    Assert-Value $null $benchmark.runs[1].result.tokens 'missing benchmark usage remains null'
    Assert-Value $null $benchmark.run_summary.without_skill.tokens 'missing summary usage remains null and the unchanged upstream viewer can render it'
    Assert-Value $null $benchmark.run_summary.delta.tokens 'missing comparison remains null'
    Assert-Value '| Tokens | 18445 ± 0 | unavailable | unavailable |' $row 'Markdown explicitly reports unavailable telemetry'
    [IO.File]::WriteAllText($jsonPath, ($benchmark | ConvertTo-Json -Depth 20), $utf8NoBom)
    Assert-Value $null (Read-JsonFile $jsonPath).runs[1].result.tokens 'persisted benchmark JSON preserves null'
    Write-Host '[PASS] Token normalization and benchmark JSON/Markdown preserve available and unavailable telemetry.'
} finally {
    if ([IO.Path]::GetFullPath($testRoot).StartsWith([IO.Path]::GetTempPath(), [StringComparison]::OrdinalIgnoreCase)) {
        Remove-Item -LiteralPath $testRoot -Recurse -Force
    }
}
