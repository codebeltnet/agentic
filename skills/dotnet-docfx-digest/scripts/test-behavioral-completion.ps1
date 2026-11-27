param(
    [string]$ValidatorPath = (Join-Path $PSScriptRoot 'docfx.cs'),
    [string]$AgentsPath = (Join-Path $PSScriptRoot 'agents.cs'),
    [string]$GeneratorPath = (Join-Path $PSScriptRoot 'generate-run-actions.ps1')
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$PSNativeCommandUseErrorActionPreference = $false

$utf8NoBom = [System.Text.UTF8Encoding]::new($false)
$workRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('dotnet-docfx-behavioral-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $workRoot -Force | Out-Null

$fileBasedAppHelper = Join-Path (Resolve-Path (Join-Path $PSScriptRoot '..\..\..')).Path 'scripts/file-based-app.ps1'
if (Test-Path -LiteralPath $fileBasedAppHelper -PathType Leaf) {
    . $fileBasedAppHelper
} else {
    function Get-FileBasedAppCommand { param([string]$SourcePath) [pscustomobject]@{ Executable = 'dotnet'; ArgumentPrefix = @('run', '--file', $SourcePath, '--'); Mode = 'dotnet-run'; Assembly = $null } }
}
$validatorApp = Get-FileBasedAppCommand -SourcePath $ValidatorPath
$agentsApp = Get-FileBasedAppCommand -SourcePath $AgentsPath
$hasDocfxCli = $null -ne (Get-Command docfx -ErrorAction SilentlyContinue)

function Write-Utf8File {
    param([string]$Path, [string]$Content)
    $dir = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
    [System.IO.File]::WriteAllText($Path, $Content, $utf8NoBom)
}

function Invoke-DocfxValidator {
    param(
        [string]$RepoRoot,
        [string[]]$ExtraArgs = @()
    )

    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $output = & $validatorApp.Executable @($validatorApp.ArgumentPrefix + @('--repo-root', $RepoRoot, '--json', '--quiet') + $ExtraArgs) 2>$null
        $exitCode = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $prev
    }

    $text = ($output -join "`n")
    $start = $text.IndexOf('{')
    if ($start -lt 0) { throw "DocFX validator returned no JSON document (exit=$exitCode). Output: $text" }
    return [pscustomobject]@{
        ExitCode = $exitCode
        Report = ($text.Substring($start) | ConvertFrom-Json)
    }
}

function Assert-CodePresent {
    param([object]$Report, [string]$Code, [string]$Context = '')
    if (-not @($Report.errors | Where-Object code -eq $Code)) {
        $codes = (@($Report.errors | ForEach-Object code | Sort-Object -Unique) -join ', ')
        throw "Expected diagnostic '$Code' $Context; actual error codes: [$codes]"
    }
}

function Assert-CodeAbsent {
    param([object]$Report, [string]$Code, [string]$Context = '')
    $matches = @($Report.errors | Where-Object code -eq $Code)
    if ($matches.Count -gt 0) {
        throw "Unexpected diagnostic '$Code' $Context; details: $($matches | ConvertTo-Json -Compress -Depth 4)"
    }
}

function Get-FileSha256 {
    param([string]$Path)
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash
}

function Save-LedgerJson {
    param([string]$Path, [object]$Ledger)
    Write-Utf8File $Path ($Ledger | ConvertTo-Json -Depth 20)
}

try {
    # =========================================================================
    # PART 1: Behavioral completion contract (Scenarios 1-10)
    # =========================================================================
    $repo = Join-Path $workRoot 'behavioral-repo'
    $ledgerDir = Join-Path $workRoot 'session-ledgers'
    New-Item -ItemType Directory -Path $repo, $ledgerDir -Force | Out-Null

    Write-Utf8File "$repo/Directory.Packages.props" @'
<Project>
  <PropertyGroup>
    <ManagePackageVersionsCentrally>false</ManagePackageVersionsCentrally>
  </PropertyGroup>
</Project>
'@
    Write-Utf8File "$repo/src/Acme.Demo/Acme.Demo.csproj" @'
<Project Sdk="Microsoft.NET.Sdk">
  <PropertyGroup>
    <TargetFramework>net10.0</TargetFramework>
    <GenerateDocumentationFile>true</GenerateDocumentationFile>
    <Version>1.2.3</Version>
  </PropertyGroup>
</Project>
'@
    Write-Utf8File "$repo/src/Acme.Demo/Calculator.cs" @'
namespace Acme.Demo;

/// <summary>Performs simple arithmetic calculations.</summary>
public sealed class Calculator
{
    /// <summary>Adds two integers and returns the sum.</summary>
    public int Add(int left, int right) => left + right;
}

/// <summary>Formats calculation labels for reports.</summary>
public sealed class LabelFormatter
{
    /// <summary>Formats a named value.</summary>
    public string Format(string name, int value) => $"{name}={value}";
}
'@
    Write-Utf8File "$repo/.docfx/docfx.json" @'
{
  "metadata": [
    {
      "src": [
        {
          "files": ["Acme.Demo/Acme.Demo.csproj"],
          "src": "../src"
        }
      ],
      "dest": "api"
    }
  ],
  "build": {
    "content": [
      {
        "files": ["api/**/*.yml"],
        "exclude": ["api/namespaces/**", "api/types/**"]
      }
    ],
    "overwrite": [
      {
        "files": ["api/namespaces/**/*.md", "api/types/**/*.md"]
      }
    ],
    "dest": "_site",
    "template": ["default", "modern"]
  }
}
'@
    Write-Utf8File "$repo/.docfx/includes/availability.md" "Available on .NET 10.0.`n"
    Write-Utf8File "$repo/.docfx/api/namespaces/Acme.Demo.md" @'
---
uid: Acme.Demo
summary: *content
---
The `Acme.Demo` namespace computes deterministic totals and formats human-readable labels for command-line reports. Use it when you need lightweight arithmetic and formatted output without external dependencies. Start with `Calculator` to compute totals and `LabelFormatter` to render them.

[!INCLUDE [availability](../../includes/availability.md)]
'@
    $calcPage = "$repo/.docfx/api/types/Acme.Demo.Calculator.md"
    $fmtPage = "$repo/.docfx/api/types/Acme.Demo.LabelFormatter.md"

    Write-Utf8File $calcPage @'
---
uid: Acme.Demo.Calculator
example:
- *content
---
The following standalone program creates a `Calculator`, adds two values, and prints the resulting sum `7` to standard output.

```csharp
// Program.cs
using System;
using Acme.Demo;

var calculator = new Calculator();
var total = calculator.Add(3, 4);
Console.WriteLine($"Total={total}");
```
'@
    Write-Utf8File $fmtPage @'
---
uid: Acme.Demo.LabelFormatter
example:
- *content
---
The following library class uses `LabelFormatter` to produce a labelled summary string for downstream reporting.

```csharp
using Acme.Demo;

namespace Acme.Samples;

public sealed class SummaryBuilder
{
    public string BuildTotal(int total)
    {
        var formatter = new LabelFormatter();
        return formatter.Format("Total", total);
    }
}
```
'@
    $calcSource = @'
// Program.cs
using System;
using Acme.Demo;

var calculator = new Calculator();
var total = calculator.Add(3, 4);
Console.WriteLine($"Total={total}");
'@.Replace("`r`n", "`n").TrimEnd("`n")
    $calcSourceHash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($calcSource)))
    Write-Utf8File "$repo/.docfx/run-actions.settings.json" (@{
        examples = @(
            @{
                uid = 'Acme.Demo.Calculator'
                exampleId = 'Acme.Demo.Calculator#1'
                fenceOrdinal = 1
                sourceSha256 = $calcSourceHash
                manifest = @{
                    schemaVersion = 1
                    mode = 'console'
                    framework = 'net10.0'
                    dependsOn = @()
                }
            }
        )
    } | ConvertTo-Json -Depth 10)

    # Seed AGENTS.md via bundled agents.cs
    & $agentsApp.Executable @($agentsApp.ArgumentPrefix + @('--repo-root', $repo)) | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "agents.cs failed on behavioral test repo (exit=$LASTEXITCODE)." }

    $finalGateArgs = @('--build-api-model', '--validate-samples')
    if ($hasDocfxCli) { $finalGateArgs += '--verify-docfx-build' }

    # Record original hashes of authored Markdown to verify Scenario 9 (already-correct examples remain unchanged).
    $calcOrigHash = Get-FileSha256 $calcPage
    $fmtOrigHash = Get-FileSha256 $fmtPage

    # Scenario 10: Ordinary non-repair validation retains its established semantics.
    $ordinary = Invoke-DocfxValidator -RepoRoot $repo -ExtraArgs $finalGateArgs
    if ($ordinary.ExitCode -ne 0 -or $ordinary.Report.errors.Count -ne 0) {
        throw "Ordinary validation failed unexpectedly: $($ordinary.Report.errors | ConvertTo-Json -Compress)"
    }
    if ($ordinary.Report.summary.behaviorReviewRequired) {
        throw 'Ordinary non-repair validation must report behaviorReviewRequired=false.'
    }
    if ($ordinary.Report.summary.operation -ne 'validate') {
        throw "Expected default operation='validate', got '$($ordinary.Report.summary.operation)'."
    }
    if ($hasDocfxCli -and (-not $ordinary.Report.summary.canClaimCompletion -or -not $ordinary.Report.summary.deterministicGatesPassed)) {
        throw "Ordinary full validation must allow completion: $($ordinary.Report.summary | ConvertTo-Json -Compress)"
    }

    # Scenario 1: Green deterministic validator with existing examples but no behavioral ledger cannot establish repair completion.
    $noLedger = Invoke-DocfxValidator -RepoRoot $repo -ExtraArgs (@('--operation', 'repair') + $finalGateArgs)
    if ($noLedger.ExitCode -ne 1 -or $noLedger.Report.summary.canClaimCompletion) {
        throw "Repair without behavioral ledger must fail completion: $($noLedger.Report.summary | ConvertTo-Json -Compress)"
    }
    if (-not $noLedger.Report.summary.behaviorReviewRequired -or $noLedger.Report.summary.examplesInScope -ne 2 -or $noLedger.Report.summary.examplesUnreviewed -ne 2) {
        throw "Unexpected missing-ledger counts: $($noLedger.Report.summary | ConvertTo-Json -Compress)"
    }
    if ($hasDocfxCli -and -not $noLedger.Report.summary.deterministicGatesPassed) {
        throw 'Deterministic gates passed must remain distinguishable from behavioral completion.'
    }
    Assert-CodePresent $noLedger.Report 'BEHAVIORAL_LEDGER_MISSING' 'when --operation repair has no ledger'

    # Scenario 2a: Empty ledger cannot establish repair completion.
    $emptyLedgerPath = Join-Path $ledgerDir 'empty.json'
    Save-LedgerJson $emptyLedgerPath @{ schemaVersion = 1; operation = 'repair'; docfxPath = '.docfx/docfx.json'; scopeMode = 'full'; changedOnly = $false; examples = @() }
    $emptyRes = Invoke-DocfxValidator -RepoRoot $repo -ExtraArgs @('--operation', 'repair', '--behavioral-ledger', $emptyLedgerPath)
    if ($emptyRes.ExitCode -ne 1 -or $emptyRes.Report.summary.canClaimCompletion -or $emptyRes.Report.summary.examplesUnreviewed -ne 2) {
        throw "Empty ledger must not pass: $($emptyRes.Report.summary | ConvertTo-Json -Compress)"
    }
    Assert-CodePresent $emptyRes.Report 'BEHAVIORAL_REVIEW_INCOMPLETE' 'for empty ledger'

    # Scenario 2b: Materialize authoritative ledger via --init-behavioral-ledger (all start unreviewed).
    $ledgerPath = Join-Path $ledgerDir 'behavioral-ledger.json'
    $initRes = Invoke-DocfxValidator -RepoRoot $repo -ExtraArgs @('--operation', 'repair-csrun', '--init-behavioral-ledger', $ledgerPath)
    if ($initRes.ExitCode -ne 1 -or $initRes.Report.summary.canClaimCompletion -or $initRes.Report.summary.examplesInScope -ne 2 -or $initRes.Report.summary.examplesUnreviewed -ne 2) {
        throw "Freshly initialized unreviewed ledger must keep repair incomplete: $($initRes.Report.summary | ConvertTo-Json -Compress)"
    }
    $ledger = Get-Content -LiteralPath $ledgerPath -Raw | ConvertFrom-Json
    if (@($ledger.examples).Count -ne 2) { throw "Expected 2 examples in materialized ledger, got $(@($ledger.examples).Count)." }
    $calcEntry = $ledger.examples | Where-Object exampleId -eq 'Acme.Demo.Calculator#1'
    $fmtEntry = $ledger.examples | Where-Object exampleId -eq 'Acme.Demo.LabelFormatter#1'
    if (-not $calcEntry -or $calcEntry.executionTopology -ne 'standalone-console' -or -not $calcEntry.executionApplicable) {
        throw "Calculator example must be classified standalone-console / executionApplicable: $($calcEntry | ConvertTo-Json -Compress)"
    }
    if (-not $fmtEntry -or $fmtEntry.executionTopology -ne 'library-snippet' -or $fmtEntry.executionApplicable) {
        throw "LabelFormatter example must be classified library-snippet / non-executable: $($fmtEntry | ConvertTo-Json -Compress)"
    }

    # Scenario 2c: Narrowed-scope ledger rejected for repository-wide repair.
    $narrowLedgerPath = Join-Path $ledgerDir 'narrow-scope.json'
    $narrowLedger = Get-Content -LiteralPath $ledgerPath -Raw | ConvertFrom-Json
    $narrowLedger.changedOnly = $true
    Save-LedgerJson $narrowLedgerPath $narrowLedger
    $narrowRes = Invoke-DocfxValidator -RepoRoot $repo -ExtraArgs @('--operation', 'repair', '--behavioral-ledger', $narrowLedgerPath)
    Assert-CodePresent $narrowRes.Report 'BEHAVIORAL_LEDGER_SCOPE_MISMATCH' 'when changedOnly ledger is passed to repo-wide repair'

    # Create a real non-empty runtime observation log file for Calculator.
    $evidenceLog = Join-Path $ledgerDir 'calculator-run.log'
    Write-Utf8File $evidenceLog "Total=7`n"

    # Scenario 7: Cached transport verification / exit-code-only observation cannot substitute for behavioral comparison.
    $transportOnlyLedgerPath = Join-Path $ledgerDir 'transport-only.json'
    $transportOnlyLedger = Get-Content -LiteralPath $ledgerPath -Raw | ConvertFrom-Json
    foreach ($ex in $transportOnlyLedger.examples) {
        $ex.documentedOperation = 'Calculator.Add(int, int)'
        $ex.consumerScenario = 'Adds 3 and 4 and prints the computed sum.'
        $ex.authoritativeEvidence = 'src/Acme.Demo/Calculator.cs'
        $ex.expectedObservation = 'Prints Total=7 to standard output.'
        if ($ex.exampleId -eq 'Acme.Demo.Calculator#1') {
            $ex.actualObservation = 'Process exited with exit code 0.'
            $ex.observationEvidencePath = $evidenceLog
            $ex.disposition = 'verified-behavior'
            $ex.transportStatus = @{ native = 'Verified'; docker = 'Verified' }
        } else {
            $ex.disposition = 'source-reviewed-only'
        }
    }
    Save-LedgerJson $transportOnlyLedgerPath $transportOnlyLedger
    $transportOnlyRes = Invoke-DocfxValidator -RepoRoot $repo -ExtraArgs @('--operation', 'repair-csrun', '--behavioral-ledger', $transportOnlyLedgerPath)
    if ($transportOnlyRes.ExitCode -ne 1 -or $transportOnlyRes.Report.summary.canClaimCompletion -or $transportOnlyRes.Report.summary.examplesBehaviorVerified -ne 0) {
        throw "Exit-code-only observation must not count as verified behavior: $($transportOnlyRes.Report.summary | ConvertTo-Json -Compress)"
    }
    Assert-CodePresent $transportOnlyRes.Report 'BEHAVIORAL_TRANSPORT_ONLY_REJECTED' 'when actualObservation only claims exit code 0'

    # Executable example marked source-reviewed-only must be rejected.
    $sourceOnlyExecPath = Join-Path $ledgerDir 'source-only-exec.json'
    $sourceOnlyExec = Get-Content -LiteralPath $transportOnlyLedgerPath -Raw | ConvertFrom-Json
    ($sourceOnlyExec.examples | Where-Object exampleId -eq 'Acme.Demo.Calculator#1').disposition = 'source-reviewed-only'
    Save-LedgerJson $sourceOnlyExecPath $sourceOnlyExec
    $sourceOnlyExecRes = Invoke-DocfxValidator -RepoRoot $repo -ExtraArgs @('--operation', 'repair', '--behavioral-ledger', $sourceOnlyExecPath)
    Assert-CodePresent $sourceOnlyExecRes.Report 'BEHAVIORAL_EXECUTION_REQUIRED' 'when executable example is only source-reviewed'
    if ($sourceOnlyExecRes.Report.summary.canClaimCompletion) { throw 'source-reviewed-only executable example must block completion.' }

    # Unavailable execution must never silently become verified behavior.
    $unavailPath = Join-Path $ledgerDir 'unavailable.json'
    $unavailLedger = Get-Content -LiteralPath $transportOnlyLedgerPath -Raw | ConvertFrom-Json
    $uCalc = $unavailLedger.examples | Where-Object exampleId -eq 'Acme.Demo.Calculator#1'
    $uCalc.disposition = 'unavailable-execution'
    $uCalc.actualObservation = 'Docker daemon is not running on this host.'
    Save-LedgerJson $unavailPath $unavailLedger
    $unavailRes = Invoke-DocfxValidator -RepoRoot $repo -ExtraArgs @('--operation', 'repair-csrun', '--behavioral-ledger', $unavailPath)
    Assert-CodePresent $unavailRes.Report 'BEHAVIORAL_EVIDENCE_UNAVAILABLE' 'when execution is unavailable'
    if ($unavailRes.Report.summary.canClaimCompletion -or $unavailRes.Report.summary.examplesBehaviorVerified -ne 0) {
        throw 'Unavailable execution must block unconditional completion and never count as verified.'
    }

    # Build a valid, complete ledger (Scenario 6).
    $completeLedgerPath = Join-Path $ledgerDir 'complete.json'
    $completeLedger = Get-Content -LiteralPath $ledgerPath -Raw | ConvertFrom-Json
    foreach ($ex in $completeLedger.examples) {
        if ($ex.exampleId -eq 'Acme.Demo.Calculator#1') {
            $ex.documentedOperation = 'Calculator.Add(int, int)'
            $ex.consumerScenario = 'Constructs Calculator, adds 3 and 4, and prints Total=7.'
            $ex.authoritativeEvidence = 'src/Acme.Demo/Calculator.cs (Calculator.Add returns left + right)'
            $ex.expectedObservation = 'Stdout emits Total=7 matching 3 + 4.'
            $ex.actualObservation = 'Observed stdout line Total=7, matching expected sum 7.'
            $ex.observationEvidencePath = $evidenceLog
            $ex.executionCommand = 'dotnet run --file Program.cs'
            $ex.disposition = 'verified-behavior'
            $ex.transportStatus = @{ native = 'Verified'; docker = 'Verified' }
            $ex.findings = @(
                @{ id = 'F-1'; status = 'repaired'; summary = 'Confirmed sum output matches implementation.' }
            )
        } else {
            $ex.documentedOperation = 'LabelFormatter.Format(string, int)'
            $ex.consumerScenario = 'Library helper invokes LabelFormatter.Format("Total", total) to produce name=value.'
            $ex.authoritativeEvidence = 'src/Acme.Demo/Calculator.cs (LabelFormatter.Format returns $"{name}={value}")'
            $ex.expectedObservation = 'BuildTotal(7) returns "Total=7".'
            $ex.disposition = 'source-reviewed-only'
        }
    }
    Save-LedgerJson $completeLedgerPath $completeLedger

    # Scenario 3: Duplicate records cannot inflate review coverage.
    $dupLedgerPath = Join-Path $ledgerDir 'duplicate.json'
    $dupLedger = Get-Content -LiteralPath $completeLedgerPath -Raw | ConvertFrom-Json
    $dupCalc = ($dupLedger.examples | Where-Object exampleId -eq 'Acme.Demo.Calculator#1')
    $dupLedger.examples = @($dupCalc, $dupCalc)
    Save-LedgerJson $dupLedgerPath $dupLedger
    $dupRes = Invoke-DocfxValidator -RepoRoot $repo -ExtraArgs @('--operation', 'repair-csrun', '--behavioral-ledger', $dupLedgerPath)
    Assert-CodePresent $dupRes.Report 'BEHAVIORAL_LEDGER_DUPLICATE' 'for duplicate exampleId entries'
    if ($dupRes.Report.summary.canClaimCompletion -or $dupRes.Report.summary.examplesReviewed -ne 0 -or $dupRes.Report.summary.examplesBehaviorVerified -ne 0) {
        throw "Duplicate records must not inflate review coverage: $($dupRes.Report.summary | ConvertTo-Json -Compress)"
    }

    # Scenario 5: Unresolved behavioral defect prevents completion (both disposition and open findings[]).
    $unresolvedPath = Join-Path $ledgerDir 'unresolved.json'
    $unresolvedLedger = Get-Content -LiteralPath $completeLedgerPath -Raw | ConvertFrom-Json
    ($unresolvedLedger.examples | Where-Object exampleId -eq 'Acme.Demo.Calculator#1').findings = @(
        @{ id = 'F-OPEN'; status = 'open'; summary = 'Output label contradicts documented formula.' }
    )
    Save-LedgerJson $unresolvedPath $unresolvedLedger
    $unresolvedRes = Invoke-DocfxValidator -RepoRoot $repo -ExtraArgs @('--operation', 'repair-csrun', '--behavioral-ledger', $unresolvedPath)
    Assert-CodePresent $unresolvedRes.Report 'BEHAVIORAL_FINDING_UNRESOLVED' 'for open finding'
    if ($unresolvedRes.Report.summary.canClaimCompletion -or $unresolvedRes.Report.summary.behavioralFindingsRemaining -ne 1) {
        throw "Open behavioral finding must prevent completion: $($unresolvedRes.Report.summary | ConvertTo-Json -Compress)"
    }

    # Unverified transport under repair-csrun blocks completion.
    $unverifiedTrPath = Join-Path $ledgerDir 'unverified-transport.json'
    $unverifiedTrLedger = Get-Content -LiteralPath $completeLedgerPath -Raw | ConvertFrom-Json
    ($unverifiedTrLedger.examples | Where-Object exampleId -eq 'Acme.Demo.Calculator#1').transportStatus = @{ native = 'Verified'; docker = 'Unverified' }
    Save-LedgerJson $unverifiedTrPath $unverifiedTrLedger
    $unverifiedTrRes = Invoke-DocfxValidator -RepoRoot $repo -ExtraArgs @('--operation', 'repair-csrun', '--behavioral-ledger', $unverifiedTrPath)
    Assert-CodePresent $unverifiedTrRes.Report 'BEHAVIORAL_TRANSPORT_UNVERIFIED' 'when Docker transport is Unverified under repair-csrun'

    # Scenario 6: Complete, current ledger with all applicable obligations satisfied permits completion.
    $completeRes = Invoke-DocfxValidator -RepoRoot $repo -ExtraArgs (@('--operation', 'repair-csrun', '--behavioral-ledger', $completeLedgerPath) + $finalGateArgs)
    if ($completeRes.ExitCode -ne 0 -or $completeRes.Report.errors.Count -ne 0) {
        throw "Complete behavioral ledger should pass: $($completeRes.Report.errors | ConvertTo-Json -Compress)"
    }
    $cs = $completeRes.Report.summary
    if (-not $cs.behaviorReviewRequired -or $cs.examplesInScope -ne 2 -or $cs.examplesReviewed -ne 2 -or
        $cs.examplesBehaviorVerified -ne 1 -or $cs.examplesSourceReviewedOnly -ne 1 -or $cs.examplesUnreviewed -ne 0 -or
        $cs.behavioralFindingsRemaining -ne 0 -or $cs.behavioralEvidenceMissing -ne 0 -or $cs.behavioralEvidenceStale -ne 0) {
        throw "Unexpected complete behavioral summary: $($cs | ConvertTo-Json -Compress)"
    }
    if ($hasDocfxCli -and (-not $cs.canClaimCompletion -or $cs.completionState -ne 'complete')) {
        throw "Complete repair-csrun must allow completion when all gates pass: $($cs | ConvertTo-Json -Compress)"
    }

    # Scenario 9: Already-correct examples remain byte-identical.
    if ((Get-FileSha256 $calcPage) -cne $calcOrigHash -or (Get-FileSha256 $fmtPage) -cne $fmtOrigHash) {
        throw 'Already-correct example pages were modified unexpectedly.'
    }

    # Scenario 4: Stale source, claim, dependency, and recipe evidence are all detected!
    $savedCalcText = [IO.File]::ReadAllText($calcPage)
    $savedCsprojText = [IO.File]::ReadAllText("$repo/src/Acme.Demo/Acme.Demo.csproj")
    $savedSettingsText = [IO.File]::ReadAllText("$repo/.docfx/run-actions.settings.json")

    # 4a. Stale source (code inside fence changed)
    try {
        Write-Utf8File $calcPage ($savedCalcText.Replace('calculator.Add(3, 4)', 'calculator.Add(3, 5)'))
        $staleSrc = Invoke-DocfxValidator -RepoRoot $repo -ExtraArgs @('--operation', 'repair-csrun', '--behavioral-ledger', $completeLedgerPath)
        Assert-CodePresent $staleSrc.Report 'BEHAVIORAL_EVIDENCE_STALE' 'when source code changes'
        if ($staleSrc.Report.summary.behavioralEvidenceStale -ne 1 -or $staleSrc.Report.summary.canClaimCompletion) {
            throw "Expected behavioralEvidenceStale=1 on source change: $($staleSrc.Report.summary | ConvertTo-Json -Compress)"
        }
        $staleSrcMsg = ($staleSrc.Report.errors | Where-Object code -eq 'BEHAVIORAL_EVIDENCE_STALE')[0].message
        if ($staleSrcMsg -notlike '*sourceSha256*') { throw "Expected sourceSha256 in stale message: $staleSrcMsg" }
    } finally {
        Write-Utf8File $calcPage $savedCalcText
    }

    # 4b. Stale claim (documentation prose changed while C# fence is byte-identical!)
    try {
        Write-Utf8File $calcPage ($savedCalcText.Replace('resulting sum `7`', 'resulting sum `99`'))
        $staleClaim = Invoke-DocfxValidator -RepoRoot $repo -ExtraArgs @('--operation', 'repair-csrun', '--behavioral-ledger', $completeLedgerPath)
        Assert-CodePresent $staleClaim.Report 'BEHAVIORAL_EVIDENCE_STALE' 'when documentation claim changes with identical code'
        $staleClaimMsg = ($staleClaim.Report.errors | Where-Object code -eq 'BEHAVIORAL_EVIDENCE_STALE')[0].message
        if ($staleClaimMsg -notlike '*claimSha256*') { throw "Expected claimSha256 in stale message: $staleClaimMsg" }
    } finally {
        Write-Utf8File $calcPage $savedCalcText
    }

    # 4c. Stale dependency (project version / dependency pin changed)
    try {
        Write-Utf8File "$repo/src/Acme.Demo/Acme.Demo.csproj" ($savedCsprojText.Replace('<Version>1.2.3</Version>', '<Version>2.0.0</Version>'))
        $staleDep = Invoke-DocfxValidator -RepoRoot $repo -ExtraArgs @('--operation', 'repair-csrun', '--behavioral-ledger', $completeLedgerPath)
        Assert-CodePresent $staleDep.Report 'BEHAVIORAL_EVIDENCE_STALE' 'when dependency/API version changes'
        $staleDepMsg = ($staleDep.Report.errors | Where-Object code -eq 'BEHAVIORAL_EVIDENCE_STALE')[0].message
        if ($staleDepMsg -notlike '*dependencySha256*') { throw "Expected dependencySha256 in stale message: $staleDepMsg" }
    } finally {
        Write-Utf8File "$repo/src/Acme.Demo/Acme.Demo.csproj" $savedCsprojText
    }

    # 4d. Stale recipe (run-actions.settings.json recipe changed)
    try {
        Write-Utf8File "$repo/.docfx/run-actions.settings.json" ($savedSettingsText.Replace('"net10.0"', '"net11.0"'))
        $staleRecipe = Invoke-DocfxValidator -RepoRoot $repo -ExtraArgs @('--operation', 'repair-csrun', '--behavioral-ledger', $completeLedgerPath)
        Assert-CodePresent $staleRecipe.Report 'BEHAVIORAL_EVIDENCE_STALE' 'when execution recipe changes'
        $staleRecipeMsg = ($staleRecipe.Report.errors | Where-Object code -eq 'BEHAVIORAL_EVIDENCE_STALE')[0].message
        if ($staleRecipeMsg -notlike '*recipeSha256*') { throw "Expected recipeSha256 in stale message: $staleRecipeMsg" }
    } finally {
        Write-Utf8File "$repo/.docfx/run-actions.settings.json" $savedSettingsText
    }

    Write-Host 'Behavioral completion contract regressions (Scenarios 1-7, 9, 10) passed.'

    # =========================================================================
    # PART 2: Run-action reporting semantics + PR #181 failure sequence (Scenario 8)
    # =========================================================================
    $pr181Repo = Join-Path $workRoot 'pr181-token-reader'
    $tokenReaderFixture = Join-Path $PSScriptRoot '../evals/files/token-reader'
    Copy-Item -LiteralPath $tokenReaderFixture -Destination $pr181Repo -Recurse
    & $agentsApp.Executable @($agentsApp.ArgumentPrefix + @('--repo-root', $pr181Repo)) | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'agents.cs failed on PR #181 token-reader fixture.' }

    # Populate local cache via mock engine, then run generate-run-actions.ps1 --summary-json WITHOUT --verify.
    $mockEngine = Join-Path $workRoot 'mock-csrun.ps1'
    Write-Utf8File $mockEngine "param([string]`$ManifestJson)`n[Console]::WriteLine('True')`n[Console]::WriteLine('Alice,30,New YorkE')"

    $verifyRun = (& $GeneratorPath -RepoRoot $pr181Repo --verify Native --engine-path $mockEngine --summary-json 2>$null) | ConvertFrom-Json
    if ($verifyRun.verification.executed -lt 1 -or $verifyRun.verified -lt 1 -or -not $verifyRun.verificationRequested -or
        $verifyRun.verification.freshNativeVerified -lt 1 -or -not $verifyRun.verification.transportOnly -or
        $verifyRun.verification.behavioralVerification -ne 'not-evaluated') {
        throw "Unexpected --verify Native summary JSON: $($verifyRun | ConvertTo-Json -Depth 5 -Compress)"
    }

    # Scenario 8: Generation without --verify must NOT report cached logs as fresh/invocation verification!
    $genOnly = (& $GeneratorPath -RepoRoot $pr181Repo --summary-json 2>$null) | ConvertFrom-Json
    if ($genOnly.verifyScope -ne 'none' -or $genOnly.verificationRequested -or $genOnly.verified -ne 0 -or
        $genOnly.verification.requested -or $genOnly.verification.executed -ne 0 -or $genOnly.verification.reused -ne 0 -or
        $genOnly.verification.nativeVerified -ne 0 -or $genOnly.verification.dockerVerified -ne 0 -or
        $genOnly.verification.freshNativeVerified -ne 0 -or $genOnly.verification.reusedNativeVerified -ne 0 -or
        $genOnly.verification.cachedNativeVerified -lt 1 -or $genOnly.cachedVerified -lt 1 -or
        -not $genOnly.verification.transportOnly -or $genOnly.verification.behavioralVerification -ne 'not-evaluated') {
        throw "Generation without --verify misrepresented cached transport status: $($genOnly | ConvertTo-Json -Depth 5 -Compress)"
    }
    $cachedExample = $genOnly.examples | Where-Object { $_.native -eq 'Verified' } | Select-Object -First 1
    if (-not $cachedExample -or $cachedExample.nativeVerificationSource -ne 'cached') {
        throw "Cached per-example transport must report nativeVerificationSource='cached': $($cachedExample | ConvertTo-Json -Compress)"
    }

    # Explicit --verify-changed reuse reports reusedNativeVerified >= 1, freshNativeVerified == 0, verified >= 1.
    $reuseRun = (& $GeneratorPath -RepoRoot $pr181Repo --verify-changed --engine-path $mockEngine --summary-json 2>$null) | ConvertFrom-Json
    if ($reuseRun.verifyScope -ne 'changed' -or -not $reuseRun.verificationRequested -or $reuseRun.verification.executed -ne 0 -or
        $reuseRun.verification.reused -lt 1 -or $reuseRun.verification.reusedNativeVerified -lt 1 -or
        $reuseRun.verification.freshNativeVerified -ne 0 -or $reuseRun.verified -lt 1) {
        throw "Explicit --verify-changed reuse reporting mismatch: $($reuseRun | ConvertTo-Json -Depth 5 -Compress)"
    }
    $reusedExample = $reuseRun.examples | Where-Object { $_.native -eq 'Verified' } | Select-Object -First 1
    if (-not $reusedExample -or $reusedExample.nativeVerificationSource -ne 'reused') {
        throw "Explicitly reused transport must report nativeVerificationSource='reused': $($reusedExample | ConvertTo-Json -Compress)"
    }

    # Real-world PR #181 failure sequence reproduction:
    # Deterministic docs/compile pass + cached transport green, but zero behavioral review occurred -> repair-csrun MUST fail closed!
    $pr181RepairCheck = Invoke-DocfxValidator -RepoRoot $pr181Repo -ExtraArgs @('--operation', 'repair-csrun', '--build-api-model', '--validate-samples')
    if ($pr181RepairCheck.ExitCode -ne 1 -or $pr181RepairCheck.Report.summary.canClaimCompletion -or
        -not $pr181RepairCheck.Report.summary.behaviorReviewRequired -or $pr181RepairCheck.Report.summary.examplesUnreviewed -lt 1) {
        throw "PR #181 failure-sequence regression must block repair-csrun completion when behavioral review has not occurred: $($pr181RepairCheck.Report.summary | ConvertTo-Json -Compress)"
    }
    Assert-CodePresent $pr181RepairCheck.Report 'BEHAVIORAL_LEDGER_MISSING' 'in PR #181 failure-sequence reproduction'

    Write-Host 'Run-action reporting semantics (Scenario 8) and PR #181 failure-sequence regression passed.'

    # =========================================================================
    # PART 3: Unrestricted multi-TFM API discovery & explicit --framework scope (Scenarios 11 & 12)
    # =========================================================================
    $multiRepo = Join-Path $workRoot 'multi-tfm-repo'
    New-Item -ItemType Directory -Path "$multiRepo/src/Demo.Kernel", "$multiRepo/src/Demo.AspNetCore", "$multiRepo/src/Demo.AspNetCore.Auth", "$multiRepo/.docfx/api/namespaces", "$multiRepo/.docfx/api/types" -Force | Out-Null

    Write-Utf8File "$multiRepo/Directory.Build.props" @'
<Project>
  <PropertyGroup>
    <TargetFrameworks>net10.0;netstandard2.0</TargetFrameworks>
    <LangVersion>latest</LangVersion>
  </PropertyGroup>
</Project>
'@
    # Inherits TargetFrameworks (net10.0;netstandard2.0) from Directory.Build.props + conditional public APIs.
    Write-Utf8File "$multiRepo/src/Demo.Kernel/Demo.Kernel.csproj" @'
<Project Sdk="Microsoft.NET.Sdk">
  <PropertyGroup>
    <GenerateDocumentationFile>true</GenerateDocumentationFile>
  </PropertyGroup>
</Project>
'@
    Write-Utf8File "$multiRepo/src/Demo.Kernel/Polyfill.cs" @'
namespace Demo.Kernel;

public sealed class CoreHelper
{
    public int Value => 1;
}

#if NETSTANDARD2_0
public sealed class NetStandardOnlyPolyfill
{
    public string Tag => "ns20";
}
#endif

#if NET10_0_OR_GREATER
public sealed class Net10OnlyFeature
{
    public string Tag => "net10";
}
#endif
'@
    # Direct FrameworkReference Microsoft.AspNetCore.App across two modern .NET TFMs (net11.0;net10.0) if net11 SDK is installed, else net10.0;net8.0.
    $installedSdks = (& dotnet --list-sdks) -join "`n"
    $aspNetSecondTfm = if ($installedSdks -match '(?m)^11\.0\.') { 'net11.0' } elseif ($installedSdks -match '(?m)^8\.0\.') { 'net8.0' } else { $null }
    $aspNetTfms = if ($aspNetSecondTfm) { "$aspNetSecondTfm;net10.0" } else { 'net10.0' }
    $secondDefine = if ($aspNetSecondTfm -eq 'net11.0') { 'NET11_0_OR_GREATER' } elseif ($aspNetSecondTfm -eq 'net8.0') { 'NET8_0' } else { 'NEVER_DEFINED' }

    Write-Utf8File "$multiRepo/src/Demo.AspNetCore/Demo.AspNetCore.csproj" @"
<Project Sdk="Microsoft.NET.Sdk">
  <PropertyGroup>
    <TargetFrameworks>$aspNetTfms</TargetFrameworks>
    <GenerateDocumentationFile>true</GenerateDocumentationFile>
  </PropertyGroup>
  <ItemGroup>
    <FrameworkReference Include="Microsoft.AspNetCore.App" />
  </ItemGroup>
</Project>
"@
    Write-Utf8File "$multiRepo/src/Demo.AspNetCore/WebHelper.cs" @"
using Microsoft.AspNetCore.Http;

namespace Demo.AspNetCore;

public sealed class WebHelper
{
    public PathString Path => new("/ok");
}

#if $secondDefine
public sealed class SecondTfmWebFeature
{
    public string Version => "$aspNetSecondTfm";
}
#endif
"@
    # Transitive ASP.NET Core framework reference + AuthenticationHandler base class + AuthenticationBuilder extension method.
    Write-Utf8File "$multiRepo/src/Demo.AspNetCore.Auth/Demo.AspNetCore.Auth.csproj" @"
<Project Sdk="Microsoft.NET.Sdk">
  <PropertyGroup>
    <TargetFrameworks>$aspNetTfms</TargetFrameworks>
    <GenerateDocumentationFile>true</GenerateDocumentationFile>
  </PropertyGroup>
  <ItemGroup>
    <ProjectReference Include="..\Demo.AspNetCore\Demo.AspNetCore.csproj" />
  </ItemGroup>
</Project>
"@
    Write-Utf8File "$multiRepo/src/Demo.AspNetCore.Auth/CustomAuthHandler.cs" @'
using System.Text.Encodings.Web;
using System.Threading.Tasks;
using Microsoft.AspNetCore.Authentication;
using Microsoft.Extensions.Logging;
using Microsoft.Extensions.Options;

namespace Demo.AspNetCore.Auth;

public sealed class CustomAuthHandler : AuthenticationHandler<AuthenticationSchemeOptions>
{
    public CustomAuthHandler(
        IOptionsMonitor<AuthenticationSchemeOptions> options,
        ILoggerFactory logger,
        UrlEncoder encoder)
        : base(options, logger, encoder)
    {
    }

    protected override Task<AuthenticateResult> HandleAuthenticateAsync() =>
        Task.FromResult(AuthenticateResult.NoResult());
}

public static class AuthBuilderExtensions
{
    public static AuthenticationBuilder AddCustomScheme(this AuthenticationBuilder builder) => builder;
}
'@
    Write-Utf8File "$multiRepo/.docfx/docfx.json" @'
{
  "metadata": [
    {
      "src": [
        {
          "files": ["**.csproj"],
          "src": "../src"
        }
      ],
      "dest": "api"
    }
  ],
  "build": {
    "content": [
      {
        "files": ["api/**/*.yml"],
        "exclude": ["api/namespaces/**", "api/types/**"]
      }
    ],
    "overwrite": [
      {
        "files": ["api/namespaces/**/*.md", "api/types/**/*.md"]
      }
    ],
    "dest": "_site"
  }
}
'@
    & $agentsApp.Executable @($agentsApp.ArgumentPrefix + @('--repo-root', $multiRepo)) | Out-Null

    # Scenario 11: Unrestricted multi-TFM discovery succeeds without PUBLIC_API_DISCOVERY_FAILED and preserves conditional APIs across all TFMs!
    $unrestricted = Invoke-DocfxValidator -RepoRoot $multiRepo -ExtraArgs @('--build-api-model')
    Assert-CodeAbsent $unrestricted.Report 'PUBLIC_API_DISCOVERY_FAILED' 'during unrestricted multi-TFM discovery'
    if ($unrestricted.Report.summary.frameworkScope -ne 'all-target-frameworks' -or
        $null -ne $unrestricted.Report.summary.PSObject.Properties['requestedFramework'] -or
        $null -ne $unrestricted.Report.summary.PSObject.Properties['omittedFrameworks']) {
        throw "Unexpected unrestricted frameworkScope summary: $($unrestricted.Report.summary | ConvertTo-Json -Compress)"
    }
    $discovered = @($unrestricted.Report.summary.discoveredFrameworks)
    if ('net10.0' -notin $discovered -or 'netstandard2.0' -notin $discovered) {
        throw "Unrestricted discovery missed evaluated TFMs. Discovered: $($discovered -join ', ')"
    }
    if ($aspNetSecondTfm -and ($aspNetSecondTfm -notin $discovered)) {
        throw "Unrestricted discovery missed second modern TFM '$aspNetSecondTfm'. Discovered: $($discovered -join ', ')"
    }
    $missingMessages = (@($unrestricted.Report.errors | Where-Object code -eq 'EXAMPLE_MISSING' | ForEach-Object message) -join "`n")
    foreach ($expectedSymbol in @('CoreHelper', 'NetStandardOnlyPolyfill', 'Net10OnlyFeature', 'WebHelper', 'CustomAuthHandler', 'AuthBuilderExtensions', 'AddCustomScheme')) {
        if ($missingMessages -notlike "*$expectedSymbol*") {
            throw "Unrestricted multi-TFM discovery failed to discover required public API '$expectedSymbol'."
        }
    }
    if ($aspNetSecondTfm -and ($missingMessages -notlike '*SecondTfmWebFeature*')) {
        throw "Unrestricted multi-TFM discovery failed to discover conditional API 'SecondTfmWebFeature' for '$aspNetSecondTfm'."
    }

    # Scenario 12: Explicit --framework invocation reports explicit framework-scoped status and cannot satisfy repository-wide multi-TFM completion!
    $scopedNet10 = Invoke-DocfxValidator -RepoRoot $multiRepo -ExtraArgs @('--build-api-model', '--framework', 'net10.0')
    Assert-CodeAbsent $scopedNet10.Report 'PUBLIC_API_DISCOVERY_FAILED' 'during explicit --framework net10.0 discovery'
    if ($scopedNet10.Report.summary.frameworkScope -ne 'explicit-framework' -or
        $scopedNet10.Report.summary.requestedFramework -ne 'net10.0' -or
        (@($scopedNet10.Report.summary.discoveredFrameworks) -join ',') -ne 'net10.0' -or
        'netstandard2.0' -notin @($scopedNet10.Report.summary.omittedFrameworks) -or
        'unrestricted-multi-tfm' -notin @($scopedNet10.Report.summary.remainingGates) -or
        $scopedNet10.Report.summary.canClaimCompletion -or
        $scopedNet10.Report.summary.completionState -notlike 'framework-scoped-*') {
        throw "Explicit --framework net10.0 on multi-TFM repo was not reported as framework-scoped: $($scopedNet10.Report.summary | ConvertTo-Json -Compress)"
    }

    Write-Host 'Multi-TFM discovery and explicit framework-scope regressions (Scenarios 11 & 12) passed.'
    Write-Host 'All behavioral completion, reporting, and multi-TFM regressions passed.'
} finally {
    if (Test-Path -LiteralPath $workRoot) {
        Remove-Item -LiteralPath $workRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}
exit 0
