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

Expected output:

```text
Total=7
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

    # 4b. Stale claim (documentation prose AND non-C# expected output fences both invalidate claimSha256 while C# fence is byte-identical!)
    try {
        Write-Utf8File $calcPage ($savedCalcText.Replace('resulting sum `7`', 'resulting sum `99`'))
        $staleClaim = Invoke-DocfxValidator -RepoRoot $repo -ExtraArgs @('--operation', 'repair-csrun', '--behavioral-ledger', $completeLedgerPath)
        Assert-CodePresent $staleClaim.Report 'BEHAVIORAL_EVIDENCE_STALE' 'when documentation claim changes with identical code'
        $staleClaimMsg = ($staleClaim.Report.errors | Where-Object code -eq 'BEHAVIORAL_EVIDENCE_STALE')[0].message
        if ($staleClaimMsg -notlike '*claimSha256*') { throw "Expected claimSha256 in stale message: $staleClaimMsg" }

        $claimRefreshPath = Join-Path $ledgerDir 'claim-refresh.json'
        Copy-Item -LiteralPath $completeLedgerPath -Destination $claimRefreshPath
        $claimRefresh = Invoke-DocfxValidator -RepoRoot $repo -ExtraArgs @('--operation', 'repair-csrun', '--init-behavioral-ledger', $claimRefreshPath)
        Assert-CodePresent $claimRefresh.Report 'BEHAVIORAL_REVIEW_INCOMPLETE' 'after refreshing the ledger for a prose-only edit'
        $before = (Get-Content -LiteralPath $completeLedgerPath -Raw | ConvertFrom-Json).examples
        $after = (Get-Content -LiteralPath $claimRefreshPath -Raw | ConvertFrom-Json).examples
        $beforeCalc = $before | Where-Object exampleId -eq 'Acme.Demo.Calculator#1'
        $afterCalc = $after | Where-Object exampleId -eq $beforeCalc.exampleId
        if ($afterCalc.sourceSha256 -ne $beforeCalc.sourceSha256 -or $afterCalc.claimSha256 -eq $beforeCalc.claimSha256 -or
            $afterCalc.disposition -ne 'unreviewed' -or $afterCalc.actualObservation) {
            throw 'A prose-only edit must reset the comparison while keeping the source identity.'
        }
        $unchanged = @($before | Where-Object disposition -eq 'source-reviewed-only')
        if ($unchanged.Count -eq 0) { throw 'Expected an unchanged reviewed example as a control.' }
        foreach ($entry in $unchanged) {
            $current = $after | Where-Object exampleId -eq $entry.exampleId
            if ($current.disposition -ne $entry.disposition -or $current.expectedObservation -cne $entry.expectedObservation -or
                $current.claimSha256 -ne $entry.claimSha256) {
                throw "A prose-only edit reset the current comparison for '$($entry.exampleId)'."
            }
        }
    } finally {
        Write-Utf8File $calcPage $savedCalcText
    }

    try {
        $editedOutputText = $savedCalcText.Replace('Total=7', 'Total=99')
        if ($editedOutputText -ceq $savedCalcText) { throw 'Expected output fence marker Total=7 was not found in Acme.Demo.Calculator.md.' }
        Write-Utf8File $calcPage $editedOutputText
        $staleOutputFence = Invoke-DocfxValidator -RepoRoot $repo -ExtraArgs @('--operation', 'repair-csrun', '--behavioral-ledger', $completeLedgerPath)
        Assert-CodePresent $staleOutputFence.Report 'BEHAVIORAL_EVIDENCE_STALE' 'when expected output fenced block changes with identical C# code'
        $staleOutputMsg = ($staleOutputFence.Report.errors | Where-Object code -eq 'BEHAVIORAL_EVIDENCE_STALE')[0].message
        if ($staleOutputMsg -notlike '*claimSha256*') { throw "Expected claimSha256 in stale output-fence message: $staleOutputMsg" }
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

    # 4c-impl. Stale implementation (library C# implementation changed with identical .csproj, docs, and recipe!)
    $calcImplPath = "$repo/src/Acme.Demo/Calculator.cs"
    $savedCalcImplText = [IO.File]::ReadAllText($calcImplPath)
    try {
        Write-Utf8File $calcImplPath ($savedCalcImplText.Replace('left + right', 'left - right'))
        $staleImpl = Invoke-DocfxValidator -RepoRoot $repo -ExtraArgs @('--operation', 'repair-csrun', '--behavioral-ledger', $completeLedgerPath)
        Assert-CodePresent $staleImpl.Report 'BEHAVIORAL_EVIDENCE_STALE' 'when library C# implementation changes without editing .csproj or docs'
        $staleImplMsg = ($staleImpl.Report.errors | Where-Object code -eq 'BEHAVIORAL_EVIDENCE_STALE')[0].message
        if ($staleImplMsg -notlike '*dependencySha256*') { throw "Expected dependencySha256 in stale implementation message: $staleImplMsg" }
    } finally {
        Write-Utf8File $calcImplPath $savedCalcImplText
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

    # 4e. Re-initializing a stale ledger preserves recorded findings while clearing stale execution evidence.
    $preserveFindingsPath = Join-Path $ledgerDir 'preserve-findings.json'
    $preserveSeed = Get-Content -LiteralPath $completeLedgerPath -Raw | ConvertFrom-Json
    ($preserveSeed.examples | Where-Object exampleId -eq 'Acme.Demo.Calculator#1').findings = @(
        @{ id = '4713030185'; status = 'open'; summary = 'Verify repaired output after implementation edit.' }
    )
    Save-LedgerJson $preserveFindingsPath $preserveSeed
    try {
        Write-Utf8File $calcPage ($savedCalcText.Replace('calculator.Add(3, 4)', 'calculator.Add(3, 5)'))
        $reinitRes = Invoke-DocfxValidator -RepoRoot $repo -ExtraArgs @('--operation', 'repair-csrun', '--init-behavioral-ledger', $preserveFindingsPath)
        if ($reinitRes.ExitCode -ne 1 -or $reinitRes.Report.summary.canClaimCompletion) {
            throw 'Re-initialized stale ledger must remain incomplete.'
        }
        $reinitLedger = Get-Content -LiteralPath $preserveFindingsPath -Raw | ConvertFrom-Json
        $reinitCalc = $reinitLedger.examples | Where-Object exampleId -eq 'Acme.Demo.Calculator#1'
        if ($reinitCalc.disposition -ne 'unreviewed' -or
            -not [string]::IsNullOrEmpty([string]$reinitCalc.actualObservation) -or
            -not [string]::IsNullOrEmpty([string]$reinitCalc.observationEvidencePath) -or
            $reinitCalc.transportStatus.native -ne 'Unverified') {
            throw "Re-initializing stale entry must clear stale execution evidence and reset disposition: $($reinitCalc | ConvertTo-Json -Compress)"
        }
        $preservedIds = @($reinitCalc.findings | ForEach-Object { [string]$_.id })
        if ('4713030185' -notin $preservedIds) {
            throw "Re-initializing stale entry dropped recorded findings: $($reinitCalc | ConvertTo-Json -Compress)"
        }
        Assert-CodePresent $reinitRes.Report 'BEHAVIORAL_FINDING_UNRESOLVED' 'because preserved open finding must still block completion'
    } finally {
        Write-Utf8File $calcPage $savedCalcText
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

    # Issue 4 regression: stale bin/obj DLL from a previously removed TFM must NOT be resurrected when project.assets.json has current TFMs.
    $staleTfmBinDir = "$multiRepo/src/Demo.Kernel/bin/Release/net6.0"
    New-Item -ItemType Directory -Path $staleTfmBinDir -Force | Out-Null
    Copy-Item -LiteralPath "$multiRepo/src/Demo.Kernel/bin/Release/net10.0/Demo.Kernel.dll" -Destination "$staleTfmBinDir/Demo.Kernel.dll" -Force
    $afterStaleDll = Invoke-DocfxValidator -RepoRoot $multiRepo -ExtraArgs @('--build-api-model')
    Assert-CodeAbsent $afterStaleDll.Report 'PUBLIC_API_DISCOVERY_FAILED' 'when stale dropped-TFM DLL sits in bin/'
    if ('net6.0' -in @($afterStaleDll.Report.summary.discoveredFrameworks)) {
        throw "Stale bin/Release/net6.0 DLL was resurrected despite authoritative project.assets.json: $($afterStaleDll.Report.summary.discoveredFrameworks -join ', ')"
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

    # =========================================================================
    # PART 4: Precise --uid scope, Cuemon & Eval #135 regression scenarios,
    #         dirty-project handling, and run-actions --uid scoping
    # =========================================================================
    $uidRepo = Join-Path $workRoot 'uid-scoped-repo'
    $uidLedgerDir = Join-Path $workRoot 'uid-ledgers'
    New-Item -ItemType Directory -Path "$uidRepo/src/Demo.Data", "$uidRepo/src/Demo.Mvc", "$uidRepo/src/Demo.Pipeline", "$uidRepo/.docfx/api/namespaces", "$uidRepo/.docfx/api/types", $uidLedgerDir -Force | Out-Null

    Write-Utf8File "$uidRepo/Directory.Packages.props" @'
<Project>
  <PropertyGroup>
    <ManagePackageVersionsCentrally>false</ManagePackageVersionsCentrally>
  </PropertyGroup>
</Project>
'@
    Write-Utf8File "$uidRepo/src/Demo.Data/Demo.Data.csproj" @'
<Project Sdk="Microsoft.NET.Sdk">
  <PropertyGroup>
    <TargetFramework>net10.0</TargetFramework>
    <GenerateDocumentationFile>true</GenerateDocumentationFile>
    <Version>1.0.0</Version>
  </PropertyGroup>
</Project>
'@
    Write-Utf8File "$uidRepo/src/Demo.Data/DataTypes.cs" @'
namespace Demo.Data;

/// <summary>Builds delimited records incrementally.</summary>
public sealed class TokenBuilder
{
    private readonly System.Text.StringBuilder _sb = new();
    /// <summary>Appends a token.</summary>
    public TokenBuilder Append(string token) { if (_sb.Length > 0) _sb.Append(','); _sb.Append(token); return this; }
    /// <summary>Returns the built record.</summary>
    public override string ToString() => _sb.ToString();
}

/// <summary>Reads delimiter-separated values.</summary>
public sealed class DsvDataReader
{
    /// <summary>Splits a CSV line.</summary>
    public string[] ReadRow(string line) => line.Split(',');
}

/// <summary>Unrelated type whose example intentionally fails compilation if compiled out of scope.</summary>
public sealed class BrokenUnrelated
{
    /// <summary>Returns a tag.</summary>
    public string Tag => "broken";
}

/// <summary>Colliding simple type name in Demo.Data.</summary>
public sealed class SharedResult
{
    /// <summary>Result code.</summary>
    public int Code => 1;
}
'@
    Write-Utf8File "$uidRepo/src/Demo.Mvc/Demo.Mvc.csproj" @'
<Project Sdk="Microsoft.NET.Sdk">
  <PropertyGroup>
    <TargetFramework>net10.0</TargetFramework>
    <GenerateDocumentationFile>true</GenerateDocumentationFile>
    <Version>1.0.0</Version>
  </PropertyGroup>
</Project>
'@
    Write-Utf8File "$uidRepo/src/Demo.Mvc/MvcTypes.cs" @'
namespace Demo.Mvc.Filters.Diagnostics;

/// <summary>Records request server timing metrics.</summary>
public sealed class ServerTimingFilter
{
    /// <summary>Formats a timing header value.</summary>
    public string FormatHeader(string name, double ms) => $"{name};dur={ms:F1}";
}

/// <summary>Unrelated MVC filter whose example intentionally fails compilation if compiled out of scope.</summary>
public sealed class UnrelatedFilter
{
    /// <summary>Returns filter name.</summary>
    public string Name => "unrelated";
}

/// <summary>Colliding simple type name in Demo.Mvc.Filters.Diagnostics.</summary>
public sealed class SharedResult
{
    /// <summary>Result code.</summary>
    public int Code => 2;
}
'@
    Write-Utf8File "$uidRepo/src/Demo.Pipeline/Demo.Pipeline.csproj" @'
<Project Sdk="Microsoft.NET.Sdk">
  <PropertyGroup>
    <TargetFramework>net10.0</TargetFramework>
    <GenerateDocumentationFile>true</GenerateDocumentationFile>
    <Version>1.0.0</Version>
  </PropertyGroup>
</Project>
'@
    Write-Utf8File "$uidRepo/src/Demo.Pipeline/PipelineExtensions.cs" @'
namespace Demo.Extensions.Authentication
{
    /// <summary>Represents a minimal application pipeline builder.</summary>
    public sealed class PipelineBuilder
    {
        /// <summary>Registered middleware steps.</summary>
        public System.Collections.Generic.List<string> Steps { get; } = new();
    }

    /// <summary>Authentication extension methods for PipelineBuilder.</summary>
    public static class ApplicationBuilderExtensions
    {
        /// <summary>Registers Basic authentication on the pipeline.</summary>
        public static PipelineBuilder UseBasicAuthentication(this PipelineBuilder builder)
        {
            builder.Steps.Add("Basic");
            return builder;
        }
    }
}

namespace Demo.Extensions.Mvc.Formatters.Xml
{
    /// <summary>Represents an MVC formatter builder.</summary>
    public sealed class FormatterBuilder
    {
        /// <summary>Whether XML output is indented.</summary>
        public bool Indent { get; set; }
    }

    /// <summary>XML formatter extension methods for FormatterBuilder.</summary>
    public static class MvcBuilderExtensions
    {
        /// <summary>Configures XML serialization formatters.</summary>
        public static FormatterBuilder AddXmlSerializationFormatters(this FormatterBuilder builder, bool indent = false)
        {
            builder.Indent = indent;
            return builder;
        }
    }

    /// <summary>Unrelated pipeline type with intentionally broken example.</summary>
    public sealed class UnrelatedMiddleware
    {
        /// <summary>Returns step label.</summary>
        public string Label => "noop";
    }
}
'@
    Write-Utf8File "$uidRepo/.docfx/docfx.json" @'
{
  "metadata": [
    {
      "src": [
        {
          "files": ["Demo.Data/Demo.Data.csproj", "Demo.Mvc/Demo.Mvc.csproj", "Demo.Pipeline/Demo.Pipeline.csproj"],
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
    Write-Utf8File "$uidRepo/.docfx/includes/availability.md" "Available on .NET 10.0.`n"
    Write-Utf8File "$uidRepo/.docfx/api/namespaces/Demo.Data.md" @'
---
uid: Demo.Data
summary: *content
---
The `Demo.Data` namespace builds and reads delimited records for structured data exchange. Use it when you need lightweight token assembly or CSV row parsing. Start with `TokenBuilder` or `DsvDataReader`.

[!INCLUDE [availability](../../includes/availability.md)]
'@
    Write-Utf8File "$uidRepo/.docfx/api/namespaces/Demo.Mvc.Filters.Diagnostics.md" @'
---
uid: Demo.Mvc.Filters.Diagnostics
summary: *content
---
The `Demo.Mvc.Filters.Diagnostics` namespace captures server-side timing metrics for diagnostic HTTP headers. Use it when profiling MVC actions. Start with `ServerTimingFilter`.

[!INCLUDE [availability](../../includes/availability.md)]
'@
    Write-Utf8File "$uidRepo/.docfx/api/namespaces/Demo.Extensions.Authentication.md" @'
---
uid: Demo.Extensions.Authentication
summary: *content
---
The `Demo.Extensions.Authentication` namespace configures authentication steps on a pipeline builder. Use it when protecting endpoints with pluggable schemes. Start with `UseBasicAuthentication`.

[!INCLUDE [availability](../../includes/availability.md)]

### Extension Members

|Type|Ext|Methods|
|--:|:-:|---|
|PipelineBuilder|⬇️|`UseBasicAuthentication`|
'@
    Write-Utf8File "$uidRepo/.docfx/api/namespaces/Demo.Extensions.Mvc.Formatters.Xml.md" @'
---
uid: Demo.Extensions.Mvc.Formatters.Xml
summary: *content
---
The `Demo.Extensions.Mvc.Formatters.Xml` namespace registers XML serialization formatters with indentation control. Use it when endpoints serve XML payloads. Start with `AddXmlSerializationFormatters`.

[!INCLUDE [availability](../../includes/availability.md)]

### Extension Members

|Type|Ext|Methods|
|--:|:-:|---|
|FormatterBuilder|⬇️|`AddXmlSerializationFormatters`|
'@
    $tokenBuilderPage = "$uidRepo/.docfx/api/types/Demo.Data.TokenBuilder.md"
    Write-Utf8File $tokenBuilderPage @'
---
uid: Demo.Data.TokenBuilder
example:
- *content
---
The following two standalone console programs require the `Demo.Data` package and demonstrate how `TokenBuilder` assembles comma-delimited records step by step: the first builds a person record and prints `Alice,30`, and the second builds a product record and prints `Widget,49.99`.

```csharp
// Program.cs
using System;
using Demo.Data;

var person = new TokenBuilder().Append("Alice").Append("30").ToString();
Console.WriteLine(person);
```

```csharp
// Program.cs
using System;
using Demo.Data;

var product = new TokenBuilder().Append("Widget").Append("49.99").ToString();
Console.WriteLine(product);
```
'@
    $dsvPage = "$uidRepo/.docfx/api/types/Demo.Data.DsvDataReader.md"
    Write-Utf8File $dsvPage @'
---
uid: Demo.Data.DsvDataReader
example:
- *content
---
The following standalone program parses a comma-separated row with `DsvDataReader` and prints the column count.

```csharp
// Program.cs
using System;
using Demo.Data;

var columns = new DsvDataReader().ReadRow("Alice,30,Engineer");
Console.WriteLine(columns.Length);
```
'@
    Write-Utf8File "$uidRepo/.docfx/api/types/Demo.Data.BrokenUnrelated.md" @'
---
uid: Demo.Data.BrokenUnrelated
example:
- *content
---
The following broken example intentionally fails compilation to verify out-of-scope fences are not compiled.

```csharp
// Program.cs
using Demo.Data;

var broken = new BrokenUnrelated();
THIS_SYMBOL_DOES_NOT_EXIST_DATA(broken.Tag);
```
'@
    Write-Utf8File "$uidRepo/.docfx/api/types/Demo.Data.SharedResult.md" @'
---
uid: Demo.Data.SharedResult
example:
- *content
---
The following standalone program prints the result code from `Demo.Data.SharedResult`.

```csharp
// Program.cs
using System;
using Demo.Data;

Console.WriteLine(new SharedResult().Code);
```
'@
    $serverTimingPage = "$uidRepo/.docfx/api/types/Demo.Mvc.Filters.Diagnostics.ServerTimingFilter.md"
    Write-Utf8File $serverTimingPage @'
---
uid: Demo.Mvc.Filters.Diagnostics.ServerTimingFilter
example:
- *content
---
The following standalone program formats a `Server-Timing` metric using `ServerTimingFilter` and prints the header value.

```csharp
// Program.cs
using System;
using Demo.Mvc.Filters.Diagnostics;

var filter = new ServerTimingFilter();
Console.WriteLine(filter.FormatHeader("db", 12.5));
```
'@
    Write-Utf8File "$uidRepo/.docfx/api/types/Demo.Mvc.Filters.Diagnostics.UnrelatedFilter.md" @'
---
uid: Demo.Mvc.Filters.Diagnostics.UnrelatedFilter
example:
- *content
---
The following broken example intentionally fails compilation to verify out-of-scope MVC fences are not compiled.

```csharp
// Program.cs
using Demo.Mvc.Filters.Diagnostics;

var filter = new UnrelatedFilter();
THIS_SYMBOL_DOES_NOT_EXIST_MVC(filter.Name);
```
'@
    Write-Utf8File "$uidRepo/.docfx/api/types/Demo.Mvc.Filters.Diagnostics.SharedResult.md" @'
---
uid: Demo.Mvc.Filters.Diagnostics.SharedResult
example:
- *content
---
The following standalone program prints the result code from `Demo.Mvc.Filters.Diagnostics.SharedResult`.

```csharp
// Program.cs
using System;
using Demo.Mvc.Filters.Diagnostics;

Console.WriteLine(new SharedResult().Code);
```
'@
    Write-Utf8File "$uidRepo/.docfx/api/types/Demo.Extensions.Authentication.PipelineBuilder.md" @'
---
uid: Demo.Extensions.Authentication.PipelineBuilder
example:
- *content
---
The following standalone program creates a `PipelineBuilder`, registers a middleware step, and prints the configured count.

```csharp
// Program.cs
using System;
using Demo.Extensions.Authentication;

var pipeline = new PipelineBuilder();
pipeline.Steps.Add("Auth");
Console.WriteLine(pipeline.Steps.Count);
```
'@
    Write-Utf8File "$uidRepo/.docfx/api/types/Demo.Extensions.Authentication.ApplicationBuilderExtensions.md" @'
---
uid: Demo.Extensions.Authentication.ApplicationBuilderExtensions
example:
- *content
---
The following standalone program registers Basic authentication with `UseBasicAuthentication` and prints the configured step.

```csharp
// Program.cs
using System;
using Demo.Extensions.Authentication;

var pipeline = new PipelineBuilder().UseBasicAuthentication();
Console.WriteLine(string.Join(",", pipeline.Steps));
```
'@
    Write-Utf8File "$uidRepo/.docfx/api/types/Demo.Extensions.Mvc.Formatters.Xml.MvcBuilderExtensions.md" @'
---
uid: Demo.Extensions.Mvc.Formatters.Xml.MvcBuilderExtensions
example:
- *content
---
The following standalone program configures indented XML formatting via `AddXmlSerializationFormatters` and prints the setting.

```csharp
// Program.cs
using System;
using Demo.Extensions.Mvc.Formatters.Xml;

var builder = new FormatterBuilder().AddXmlSerializationFormatters(indent: true);
Console.WriteLine($"Indent={builder.Indent}");
```
'@
    Write-Utf8File "$uidRepo/.docfx/api/types/Demo.Extensions.Mvc.Formatters.Xml.UnrelatedMiddleware.md" @'
---
uid: Demo.Extensions.Mvc.Formatters.Xml.UnrelatedMiddleware
example:
- *content
---
The following broken example intentionally fails compilation to verify unrelated pipeline examples are not compiled.

```csharp
// Program.cs
using Demo.Extensions.Mvc.Formatters.Xml;

var m = new UnrelatedMiddleware();
THIS_SYMBOL_DOES_NOT_EXIST_PIPELINE(m.Label);
```
'@
    & $agentsApp.Executable @($agentsApp.ArgumentPrefix + @('--repo-root', $uidRepo)) | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'agents.cs failed on uid-scoped test repo.' }

    # Initialize git so dirty-project and --changed-only behaviors are real.
    Push-Location $uidRepo
    try {
        & git init -q 2>$null | Out-Null
        & git config core.autocrlf false 2>$null | Out-Null
        & git config core.safecrlf false 2>$null | Out-Null
        & git -c user.email=t@e.com -c user.name=t add -A 2>$null | Out-Null
        & git -c user.email=t@e.com -c user.name=t commit -q -m base 2>$null | Out-Null
    } finally { Pop-Location }

    # 13a. Targeted two-UID Cuemon-shaped scenario across two projects:
    #      creates ONLY their 3 behavioral obligations (2 fences on TokenBuilder + 1 on ServerTimingFilter),
    #      compiles ONLY those 3 samples (skipping all 3 intentionally broken unrelated examples!),
    #      preserves shared API discovery & dependency builds, and scopes the assessment queue.
    $twoUidLedger = Join-Path $uidLedgerDir 'two-uid-ledger.json'
    $twoUidQueue = Join-Path $uidLedgerDir 'two-uid-queue.md'
    $twoUidArgs = @(
        '--operation', 'repair',
        '--uid', 'Demo.Data.TokenBuilder',
        '--uid', 'Demo.Mvc.Filters.Diagnostics.ServerTimingFilter'
    )
    $twoUidInit = Invoke-DocfxValidator -RepoRoot $uidRepo -ExtraArgs ($twoUidArgs + @('--init-behavioral-ledger', $twoUidLedger, '--assessment-queue', $twoUidQueue) + $finalGateArgs)
    if ($twoUidInit.ExitCode -ne 1 -or $twoUidInit.Report.summary.canClaimCompletion) {
        throw "Unreviewed UID-scoped repair must fail completion: $($twoUidInit.Report.summary | ConvertTo-Json -Compress)"
    }
    Assert-CodeAbsent $twoUidInit.Report 'SAMPLE_COMPILE_FAILED' 'because unrelated broken examples must not be compiled under --uid'
    Assert-CodePresent $twoUidInit.Report 'BEHAVIORAL_REVIEW_INCOMPLETE' 'for unreviewed two-UID ledger'
    $s2 = $twoUidInit.Report.summary
    if ($s2.operation -ne 'repair' -or -not $s2.behaviorReviewRequired -or $s2.runMode -ne 'scoped' -or
        $s2.examplesInScope -ne 3 -or $s2.examplesUnreviewed -ne 3 -or $s2.samplesCompiled -ne 3 -or
        (@($s2.selectedUids) -join ',') -ne 'Demo.Data.TokenBuilder,Demo.Mvc.Filters.Diagnostics.ServerTimingFilter') {
        throw "Unexpected two-UID summary: $($s2 | ConvertTo-Json -Compress)"
    }
    if ($twoUidInit.Report.scope.scopeKind -ne 'uid' -or
        $twoUidInit.Report.scope.sharedValidation.apiDiscovery -ne 'repository' -or
        $twoUidInit.Report.scope.sharedValidation.dependencyBuild -ne 'repository' -or
        $twoUidInit.Report.scope.sharedValidation.sampleCompilation -ne 'uid-scoped' -or
        $twoUidInit.Report.scope.sharedValidation.behavioralReview -ne 'uid-scoped') {
        throw "Shared vs repair scope not cleanly distinguished: $($twoUidInit.Report.scope | ConvertTo-Json -Depth 5 -Compress)"
    }
    $twoUidLedgerDoc = Get-Content -LiteralPath $twoUidLedger -Raw | ConvertFrom-Json
    if ($twoUidLedgerDoc.scopeMode -ne 'scoped' -or $twoUidLedgerDoc.scopeKind -ne 'uid' -or
        (@($twoUidLedgerDoc.selectedUids) -join ',') -ne 'Demo.Data.TokenBuilder,Demo.Mvc.Filters.Diagnostics.ServerTimingFilter' -or
        @($twoUidLedgerDoc.examples).Count -ne 3) {
        throw "Unexpected two-UID ledger structure: $($twoUidLedgerDoc | ConvertTo-Json -Depth 5 -Compress)"
    }
    $queueText = [IO.File]::ReadAllText($twoUidQueue)
    if (-not $queueText.Contains('Operation: `repair`') -or -not $queueText.Contains('Demo.Data.TokenBuilder') -or
        -not $queueText.Contains('Behavioral Review Obligations') -or $queueText.Contains('BrokenUnrelated') -or
        -not $queueText.Contains('scoped-passed')) {
        throw "Assessment queue did not reflect exact UID scope: $queueText"
    }

    # 13b. Individual example selection via uid#ordinal selects ONLY that fence.
    $singleFenceLedger = Join-Path $uidLedgerDir 'single-fence.json'
    $singleFenceRes = Invoke-DocfxValidator -RepoRoot $uidRepo -ExtraArgs @(
        '--operation', 'repair', '--uid', 'Demo.Data.TokenBuilder#2',
        '--init-behavioral-ledger', $singleFenceLedger, '--validate-samples')
    if ($singleFenceRes.Report.summary.examplesInScope -ne 1 -or $singleFenceRes.Report.summary.samplesCompiled -ne 1 -or
        (@($singleFenceRes.Report.summary.selectedUids) -join ',') -ne 'Demo.Data.TokenBuilder#2') {
        throw "uid#ordinal selection did not isolate fence #2: $($singleFenceRes.Report.summary | ConvertTo-Json -Compress)"
    }
    $sfDoc = Get-Content -LiteralPath $singleFenceLedger -Raw | ConvertFrom-Json
    if (@($sfDoc.examples).Count -ne 1 -or $sfDoc.examples[0].exampleId -ne 'Demo.Data.TokenBuilder#2') {
        throw "uid#ordinal ledger did not contain solely Demo.Data.TokenBuilder#2: $($sfDoc | ConvertTo-Json -Depth 5 -Compress)"
    }

    # 13c. Unknown and ambiguous UIDs fail clearly and NEVER expand repository-wide.
    $badLedger = Join-Path $uidLedgerDir 'should-not-exist.json'
    $unknownUid = Invoke-DocfxValidator -RepoRoot $uidRepo -ExtraArgs @('--operation', 'repair', '--uid', 'Demo.Data.DoesNotExist', '--init-behavioral-ledger', $badLedger)
    Assert-CodePresent $unknownUid.Report 'UID_SELECTOR_NOT_FOUND' 'for unknown UID'
    if ($unknownUid.ExitCode -ne 1 -or $unknownUid.Report.summary.canClaimCompletion -or @($unknownUid.Report.scope.selectedProjects).Count -ne 0 -or (Test-Path -LiteralPath $badLedger)) {
        throw "Unknown UID expanded scope or created a bogus ledger: $($unknownUid.Report.summary | ConvertTo-Json -Compress)"
    }
    $ambiguousUid = Invoke-DocfxValidator -RepoRoot $uidRepo -ExtraArgs @('--operation', 'repair', '--uid', 'SharedResult')
    Assert-CodePresent $ambiguousUid.Report 'UID_SELECTOR_AMBIGUOUS' 'for ambiguous short name matching two types'
    if ($ambiguousUid.ExitCode -ne 1 -or $ambiguousUid.Report.summary.canClaimCompletion -or @($ambiguousUid.Report.scope.selectedProjects).Count -ne 0) {
        throw "Ambiguous UID expanded scope: $($ambiguousUid.Report.summary | ConvertTo-Json -Compress)"
    }
    $badOrdinal = Invoke-DocfxValidator -RepoRoot $uidRepo -ExtraArgs @('--operation', 'repair', '--uid', 'Demo.Data.TokenBuilder#99')
    Assert-CodePresent $badOrdinal.Report 'UID_SELECTOR_NOT_FOUND' 'for out-of-range uid#ordinal'

    # 13d. Eval #135 pipeline scenario: two extension-class UIDs across two namespaces create exactly 2 obligations.
    $eval135Ledger = Join-Path $uidLedgerDir 'eval135-ledger.json'
    $eval135Res = Invoke-DocfxValidator -RepoRoot $uidRepo -ExtraArgs @(
        '--operation', 'repair',
        '--uid', 'Demo.Extensions.Authentication.ApplicationBuilderExtensions',
        '--uid', 'Demo.Extensions.Mvc.Formatters.Xml.MvcBuilderExtensions',
        '--init-behavioral-ledger', $eval135Ledger,
        '--build-api-model', '--validate-samples')
    Assert-CodeAbsent $eval135Res.Report 'SAMPLE_COMPILE_FAILED' 'in eval #135 UID-scoped scenario'
    if ($eval135Res.Report.summary.examplesInScope -ne 2 -or $eval135Res.Report.summary.samplesCompiled -ne 2 -or $eval135Res.Report.summary.canClaimCompletion) {
        throw "Eval #135 two-UID scenario produced wrong obligation/compile counts: $($eval135Res.Report.summary | ConvertTo-Json -Compress)"
    }

    # 13e. Explicitly selected unchanged examples stay in scope even with --changed-only,
    #      AND modifying an authored documentation page never causes PROJECT_DIRTY_SKIPPED in non-dry-run verification!
    $savedTokenText = [IO.File]::ReadAllText($tokenBuilderPage)
    try {
        Write-Utf8File $tokenBuilderPage ($savedTokenText.Replace('assembles comma-delimited records', 'builds comma-delimited records'))
        $changedWithUid = Invoke-DocfxValidator -RepoRoot $uidRepo -ExtraArgs ($twoUidArgs + @('--changed-only', '--behavioral-ledger', $twoUidLedger, '--validate-samples'))
        if ($changedWithUid.Report.summary.examplesInScope -ne 3 -or $changedWithUid.Report.summary.samplesCompiled -ne 3) {
            throw "Explicitly selected unchanged ServerTimingFilter was dropped under --changed-only: $($changedWithUid.Report.summary | ConvertTo-Json -Compress)"
        }
        if (@($changedWithUid.Report.warnings | Where-Object code -eq 'PROJECT_DIRTY_SKIPPED').Count -gt 0) {
            throw 'UID-scoped verification emitted PROJECT_DIRTY_SKIPPED after doc edit.'
        }

        # Non-dry-run --project verification after doc edit must NOT skip the edited project.
        $projAfterEdit = Invoke-DocfxValidator -RepoRoot $uidRepo -ExtraArgs @('--project', 'Demo.Data')
        if (@($projAfterEdit.Report.warnings | Where-Object code -eq 'PROJECT_DIRTY_SKIPPED').Count -gt 0 -or
            @($projAfterEdit.Report.scope.selectedProjects).Count -ne 1) {
            throw "Non-dry-run --project excluded edited project with PROJECT_DIRTY_SKIPPED: $($projAfterEdit.Report.warnings | ConvertTo-Json -Compress)"
        }

        # Dry-run --project selection MUST preserve the dirty-project safeguard!
        $dryRunDirty = Invoke-DocfxValidator -RepoRoot $uidRepo -ExtraArgs @('--dry-run', '--project', 'Demo.Data')
        if (@($dryRunDirty.Report.warnings | Where-Object code -eq 'PROJECT_DIRTY_SKIPPED').Count -eq 0 -or
            @($dryRunDirty.Report.scope.selectedProjects).Count -ne 0) {
            throw "Dry-run --project lost PROJECT_DIRTY_SKIPPED safeguard: $($dryRunDirty.Report.warnings | ConvertTo-Json -Compress)"
        }
    } finally {
        Write-Utf8File $tokenBuilderPage $savedTokenText
    }

    # 13f. Scope consistency between ledger initialization and reconciliation.
    $mismatchOneUid = Invoke-DocfxValidator -RepoRoot $uidRepo -ExtraArgs @('--operation', 'repair', '--uid', 'Demo.Data.TokenBuilder', '--behavioral-ledger', $twoUidLedger)
    Assert-CodePresent $mismatchOneUid.Report 'BEHAVIORAL_LEDGER_SCOPE_MISMATCH' 'when reconciling 2-UID ledger against 1-UID scope'
    $mismatchRepoWide = Invoke-DocfxValidator -RepoRoot $uidRepo -ExtraArgs @('--operation', 'repair', '--behavioral-ledger', $twoUidLedger)
    Assert-CodePresent $mismatchRepoWide.Report 'BEHAVIORAL_LEDGER_SCOPE_MISMATCH' 'when reconciling 2-UID ledger against repo-wide scope'

    # 13g. Complete UID-scoped behavioral evidence passes with scoped-passed and canClaimCompletion=false (never repo-wide!).
    $uidEvidenceLog = Join-Path $uidLedgerDir 'uid-run.log'
    Write-Utf8File $uidEvidenceLog "Alice,30`nWidget,49.99`ndb;dur=12.5`n"
    $completeTwoUidPath = Join-Path $uidLedgerDir 'two-uid-complete.json'
    $completeTwoUid = Get-Content -LiteralPath $twoUidLedger -Raw | ConvertFrom-Json
    foreach ($ex in $completeTwoUid.examples) {
        $ex.documentedOperation = "$($ex.uid) primary operation"
        $ex.consumerScenario = "Executes $($ex.exampleId) and verifies printed consumer output."
        $ex.authoritativeEvidence = "src/ implementation for $($ex.uid)"
        $ex.expectedObservation = "Emits the exact formatted consumer output for $($ex.exampleId)."
        $ex.actualObservation = "Observed exact output line matching $($ex.exampleId) expectation."
        $ex.observationEvidencePath = $uidEvidenceLog
        $ex.executionCommand = 'dotnet run --file Program.cs'
        $ex.disposition = 'verified-behavior'
        $ex.transportStatus = @{ native = 'Verified'; docker = 'Verified' }
    }
    Save-LedgerJson $completeTwoUidPath $completeTwoUid

    $twoUidPassed = Invoke-DocfxValidator -RepoRoot $uidRepo -ExtraArgs ($twoUidArgs + @('--behavioral-ledger', $completeTwoUidPath) + $finalGateArgs)
    if ($twoUidPassed.ExitCode -ne 0 -or $twoUidPassed.Report.errors.Count -ne 0) {
        throw "Complete two-UID repair failed unexpectedly: $($twoUidPassed.Report.errors | ConvertTo-Json -Compress)"
    }
    $sp = $twoUidPassed.Report.summary
    if ($sp.canClaimCompletion -or $sp.examplesInScope -ne 3 -or $sp.examplesReviewed -ne 3 -or
        $sp.examplesBehaviorVerified -ne 3 -or $sp.examplesUnreviewed -ne 0 -or $sp.samplesCompiled -ne 3) {
        throw "Unexpected two-UID passing summary: $($sp | ConvertTo-Json -Compress)"
    }
    if ($hasDocfxCli -and $sp.completionState -ne 'scoped-passed') {
        throw "Expected scoped-passed for complete UID-scoped repair, got '$($sp.completionState)'."
    }

    # Stale claim on one selected UID blocks completion again.
    try {
        Write-Utf8File $tokenBuilderPage ($savedTokenText.Replace('assembles comma-delimited records', 'emits a changed claim'))
        $uidStale = Invoke-DocfxValidator -RepoRoot $uidRepo -ExtraArgs ($twoUidArgs + @('--behavioral-ledger', $completeTwoUidPath))
        Assert-CodePresent $uidStale.Report 'BEHAVIORAL_EVIDENCE_STALE' 'when selected UID prose changes after review'
        if ($uidStale.ExitCode -ne 1 -or $uidStale.Report.summary.completionState -ne 'scoped-failed') {
            throw "Stale UID evidence must fail scoped completion: $($uidStale.Report.summary | ConvertTo-Json -Compress)"
        }
    } finally {
        Write-Utf8File $tokenBuilderPage $savedTokenText
    }

    # Shared cross-reference validation remains intact under --uid scope.
    try {
        Write-Utf8File $tokenBuilderPage ($savedTokenText + "`nSee [Append](xref:Demo.Data.TokenBuilder.Append(System.String)).`n")
        $xrefCheck = Invoke-DocfxValidator -RepoRoot $uidRepo -ExtraArgs ($twoUidArgs + @('--behavioral-ledger', $completeTwoUidPath))
        Assert-CodePresent $xrefCheck.Report 'XREF_MEMBER_LINK' 'shared cross-reference validation must stay active under --uid'
    } finally {
        Write-Utf8File $tokenBuilderPage $savedTokenText
    }

    # Namespace UID selection remains compatible.
    $nsUidRes = Invoke-DocfxValidator -RepoRoot $uidRepo -ExtraArgs @('--uid', 'Demo.Extensions.Authentication', '--validate-samples')
    if ($nsUidRes.ExitCode -ne 0 -or $nsUidRes.Report.summary.namespacePagesValidated -ne 1 -or $nsUidRes.Report.summary.samplesCompiled -ne 2) {
        throw "Namespace UID selection failed: $($nsUidRes.Report.summary | ConvertTo-Json -Compress)"
    }

    # 13h. Run-actions --uid planning, generation, verification, manifest/sibling preservation, and invalid selector rejection.
    $raPlanOut = (& $GeneratorPath -RepoRoot $uidRepo --run-action-plan --uid Demo.Data.TokenBuilder --uid Demo.Mvc.Filters.Diagnostics.ServerTimingFilter --json 2>$null) | ConvertFrom-Json
    if ($LASTEXITCODE -ne 0 -or $raPlanOut.scopeMode -ne 'uid' -or $raPlanOut.summary.total -ne 3) {
        throw "Run-actions --run-action-plan --uid did not scope to 3 examples: $($raPlanOut | ConvertTo-Json -Depth 5 -Compress)"
    }

    $null = & $GeneratorPath -RepoRoot $uidRepo --run-action-plan --uid Demo.DoesNotExist --json 2>$null
    if ($LASTEXITCODE -ne 3) { throw "Expected exit 3 for unknown run-actions --uid; got $LASTEXITCODE" }
    $null = & $GeneratorPath -RepoRoot $uidRepo --run-action-plan --uid SharedResult --json 2>$null
    if ($LASTEXITCODE -ne 3) { throw "Expected exit 3 for ambiguous run-actions --uid; got $LASTEXITCODE" }

    # Clean 3-example repo for run-actions --uid generation + verification + manifest/sibling preservation.
    $raUidRepo = Join-Path $workRoot 'ra-uid-repo'
    New-Item -ItemType Directory -Path "$raUidRepo/docs" -Force | Out-Null
    Write-Utf8File "$raUidRepo/docfx.json" @'
{
  "build": {
    "content": [{ "files": ["docs/*.md"] }],
    "template": ["default", "modern"],
    "dest": "_site"
  }
}
'@
    Write-Utf8File "$raUidRepo/docs/Alpha.md" @'
---
uid: Demo.Alpha
example: *content
---
Alpha fences.

```csharp
using System;
Console.WriteLine("alpha-1");
```

```csharp
using System;
Console.WriteLine("alpha-2");
```
'@
    Write-Utf8File "$raUidRepo/docs/Beta.md" @'
---
uid: Demo.Beta
example: *content
---
Beta fence.

```csharp
using System;
Console.WriteLine("beta-1");
```
'@
    $raMockEngine = Join-Path $workRoot 'ra-uid-mock-csrun.ps1'
    Write-Utf8File $raMockEngine "param([string]`$ManifestJson)`n[Console]::WriteLine('ok')"

    # Generate full repo first (3 entries in manifest).
    $raFull = (& $GeneratorPath -RepoRoot $raUidRepo --summary-json 2>$null) | ConvertFrom-Json
    if ($LASTEXITCODE -ne 0 -or $raFull.total -ne 3) { throw "Initial run-actions generation failed: $($raFull | ConvertTo-Json -Compress)" }
    $betaHashBefore = Get-FileSha256 "$raUidRepo/docs/Beta.md"
    $alphaTextBefore = [IO.File]::ReadAllText("$raUidRepo/docs/Alpha.md")
    if (([regex]::Matches($alphaTextBefore, '<!-- docfx-run-actions:start -->')).Count -ne 2) {
        throw 'Expected 2 run-action associations on Alpha.md after full generation.'
    }

    # Edit ONLY Alpha#1 and regenerate + verify ONLY --uid Demo.Alpha#1.
    Write-Utf8File "$raUidRepo/docs/Alpha.md" ($alphaTextBefore.Replace('alpha-1', 'alpha-1-updated'))
    $raScoped = (& $GeneratorPath -RepoRoot $raUidRepo --uid 'Demo.Alpha#1' --verify Native --engine-path $raMockEngine --summary-json 2>$null) | ConvertFrom-Json
    if ($LASTEXITCODE -ne 0 -or $raScoped.scopeMode -ne 'uid' -or $raScoped.verifyScope -ne 'uid' -or
        $raScoped.total -ne 1 -or $raScoped.verification.executed -ne 1 -or $raScoped.verified -ne 1 -or
        (@($raScoped.selectedUids) -join ',') -ne 'Demo.Alpha#1') {
        throw "Scoped run-actions --uid Demo.Alpha#1 summary mismatch: $($raScoped | ConvertTo-Json -Depth 5 -Compress)"
    }
    if ((Get-FileSha256 "$raUidRepo/docs/Beta.md") -cne $betaHashBefore) {
        throw 'Out-of-scope Beta.md was modified during --uid Demo.Alpha#1 generation.'
    }
    $alphaTextAfter = [IO.File]::ReadAllText("$raUidRepo/docs/Alpha.md")
    if (([regex]::Matches($alphaTextAfter, '<!-- docfx-run-actions:start -->')).Count -ne 2) {
        throw 'Partial-page --uid Demo.Alpha#1 stripped sibling Demo.Alpha#2 association!'
    }
    $mergedManifestDoc = Get-Content -LiteralPath "$raUidRepo/run-actions.manifest.json" -Raw | ConvertFrom-Json
    if (@($mergedManifestDoc.examples).Count -ne 3) {
        throw "Scoped --uid generation dropped out-of-scope entries from run-actions.manifest.json (count=$(@($mergedManifestDoc.examples).Count))."
    }

    Write-Host 'UID-scoped repair, eval #135, dirty-project, and run-action UID regressions passed.'
    Write-Host 'All behavioral completion, reporting, and multi-TFM regressions passed.'
} finally {
    if (Test-Path -LiteralPath $workRoot) {
        Remove-Item -LiteralPath $workRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}
exit 0
