param(
    [string]$ValidatorPath = (Join-Path $PSScriptRoot 'docfx.cs')
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
# The validator intentionally exits non-zero for fixtures that contain diagnostics and now writes
# append-only packet heartbeats to stderr. Opt out of native-command error promotion so a non-zero
# exit or a stderr heartbeat is not treated as a terminating PowerShell error when this script is
# invoked from another script (e.g. validate-skill-templates.ps1).
$PSNativeCommandUseErrorActionPreference = $false

$utf8NoBom = [System.Text.UTF8Encoding]::new($false)
$csproj = @'
<Project Sdk="Microsoft.NET.Sdk">
  <PropertyGroup>
    <TargetFramework>net10.0</TargetFramework>
  </PropertyGroup>
</Project>
'@
$agents = @'
<!-- dotnet-docfx-digest:start -->
Managed DocFX guidance.
<!-- dotnet-docfx-digest:end -->
'@

function Write-Utf8File {
    param([string]$Path, [string]$Content)
    $dir = Split-Path -Parent $Path
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    [System.IO.File]::WriteAllText($Path, $Content, $utf8NoBom)
}

function New-Workspace {
    Join-Path ([System.IO.Path]::GetTempPath()) ('dotnet-docfx-scope-' + [guid]::NewGuid().ToString('N'))
}

function Invoke-ValidatorRaw {
    param([string[]]$AllArgs)
    # Relax ErrorActionPreference around the native call so a non-zero exit (diagnostic fixtures)
    # and stderr packet heartbeats are never promoted to a terminating PowerShell error. Explicit
    # `throw` statements in scenarios still halt. Returns raw stdout text.
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $out = & dotnet run --file $ValidatorPath -- @AllArgs 2>$null
    } finally {
        $ErrorActionPreference = $prev
    }
    return ($out -join "`n")
}

function Invoke-Validator {
    param([string]$Workspace, [string[]]$ExtraArgs = @())
    $all = @('--repo-root', $Workspace, '--json') + $ExtraArgs
    return (ConvertFrom-ValidatorJson (Invoke-ValidatorRaw $all))
}

# The validator prints append-only packet heartbeats to stderr before the single JSON document on
# stdout. Slice from the first '{' (the start of the JSON object) to parse robustly.
function ConvertFrom-ValidatorJson {
    param([string]$Text)
    if ([string]::IsNullOrWhiteSpace($Text)) { throw 'Validator returned no output.' }
    $start = $Text.IndexOf('{')
    if ($start -lt 0) { throw "Validator returned no JSON document. Output: $Text" }
    return ($Text.Substring($start) | ConvertFrom-Json)
}

function Assert-Diagnostic {
    param([object]$Report, [string]$Code, [string]$Where = 'errors')
    $list = if ($Where -eq 'warnings') { $Report.warnings } else { $Report.errors }
    if (-not @($list | Where-Object code -eq $Code)) {
        throw "Expected '$Code' in $Where but it was absent."
    }
}

function Assert-NoDiagnostic {
    param([object]$Report, [string]$Code)
    if (@($Report.errors | Where-Object code -eq $Code)) { throw "Diagnostic '$Code' was unexpectedly present." }
}

function Initialize-GitRepo {
    param([string]$Workspace)
    Push-Location $Workspace
    try {
        & git init -q 2>$null | Out-Null
        & git config core.autocrlf false 2>$null | Out-Null
        & git config core.safecrlf false 2>$null | Out-Null
        & git -c user.email=t@e.com -c user.name=t add -A 2>$null | Out-Null
        & git -c user.email=t@e.com -c user.name=t commit -q -m base 2>$null | Out-Null
    } finally { Pop-Location }
}

function New-Docfx {
    param([object[]]$Groups)
    $entries = ($Groups | ForEach-Object {
        $files = ($_.Files | ForEach-Object { "`"$_`"" }) -join ', '
        "{ `"src`": [{ `"src`": `"../`", `"files`": [$files] }], `"dest`": `"$($_.Dest)`" }"
    }) -join ",`n    "
    return @"
{
  "metadata": [
    $entries
  ],
  "build": {
    "content": [{ "files": ["*.md"], "exclude": ["api/namespaces/**", "api/types/**"] }],
    "overwrite": [
      { "files": ["api/namespaces/**/*.md"] },
      { "files": ["api/types/**/*.md"] }
    ],
    "dest": "_site"
  }
}
"@
}

$failures = 0
function Run-Scenario {
    param([string]$Name, [scriptblock]$Body)
    $ws = New-Workspace
    try {
        & $Body $ws
        Write-Host "[PASS] $Name"
    } catch {
        $script:failures++
        Write-Host "[FAIL] $Name :: $($_.Exception.Message)"
    } finally {
        if (Test-Path $ws) { Remove-Item $ws -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

# ----------------------------------------------------------------------
Run-Scenario 'Dry-run selects one clean project per metadata group; seed reproduces' {
    param($ws)
    Write-Utf8File (Join-Path $ws 'AGENTS.md') $agents
    Write-Utf8File (Join-Path $ws 'src/Core/Acme.Core.csproj') $csproj
    Write-Utf8File (Join-Path $ws 'src/Net/Acme.Net.csproj') $csproj
    Write-Utf8File (Join-Path $ws 'src/Core/Core.cs') "namespace Acme.Core`n{`n    public sealed class Widget { public int N { get; set; } }`n}`n"
    Write-Utf8File (Join-Path $ws 'src/Net/Net.cs') "namespace Acme.Net`n{`n    public sealed class Client { public int N { get; set; } }`n}`n"
    Write-Utf8File (Join-Path $ws '.docfx/docfx.json') (New-Docfx @(
        @{ Dest = 'api/core'; Files = @('src/Core/Acme.Core.csproj') },
        @{ Dest = 'api/net';  Files = @('src/Net/Acme.Net.csproj') }))
    Initialize-GitRepo $ws

    $r1 = Invoke-Validator $ws @('--dry-run', '--seed', '7')
    if ($r1.summary.runMode -ne 'dry-run') { throw "runMode=$($r1.summary.runMode)" }
    if ($r1.summary.seed -ne 7) { throw "seed=$($r1.summary.seed)" }
    if ($r1.summary.scopeState -ne 'provisional') { throw "scopeState=$($r1.summary.scopeState)" }
    if ($r1.scope.metadataGroups.Count -ne 2) { throw "groups=$($r1.scope.metadataGroups.Count)" }
    foreach ($g in $r1.scope.metadataGroups) {
        if (-not $g.selectedProject) { throw "group $($g.id) had no selection" }
    }
    Assert-Diagnostic -Report $r1 -Code 'BUILD_BACKED_SCOPE_REQUIRED' -Where 'warnings'
    if ($r1.summary.completionState -notlike 'dry-run-*') { throw "completion=$($r1.summary.completionState)" }
    if ($r1.summary.canClaimCompletion) { throw 'dry-run must not claim completion' }

    $r2 = Invoke-Validator $ws @('--dry-run', '--seed', '7')
    $s1 = ($r1.scope.selectedProjects | Sort-Object) -join '|'
    $s2 = ($r2.scope.selectedProjects | Sort-Object) -join '|'
    if ($s1 -ne $s2) { throw "seed not reproducible: '$s1' vs '$s2'" }
}

# ----------------------------------------------------------------------
Run-Scenario 'Explicit hint scopes validation and never claims repo completion' {
    param($ws)
    Write-Utf8File (Join-Path $ws 'AGENTS.md') $agents
    Write-Utf8File (Join-Path $ws 'src/Core/Acme.Core.csproj') $csproj
    Write-Utf8File (Join-Path $ws 'src/Net/Acme.Net.csproj') $csproj
    Write-Utf8File (Join-Path $ws 'src/Core/Core.cs') "namespace Acme.Core`n{`n    public sealed class Widget { public int N { get; set; } }`n}`n"
    Write-Utf8File (Join-Path $ws 'src/Net/Net.cs') "namespace Acme.Net`n{`n    public sealed class Client { public int N { get; set; } }`n}`n"
    Write-Utf8File (Join-Path $ws '.docfx/docfx.json') (New-Docfx @(
        @{ Dest = 'api/core'; Files = @('src/Core/Acme.Core.csproj') },
        @{ Dest = 'api/net';  Files = @('src/Net/Acme.Net.csproj') }))
    Initialize-GitRepo $ws

    $r = Invoke-Validator $ws @('--project', 'Acme.Core')
    if ($r.summary.runMode -ne 'scoped') { throw "runMode=$($r.summary.runMode)" }
    if ($r.summary.canClaimCompletion) { throw 'scoped run must not claim completion' }
    # Only the Acme.Core namespace should be in scope: Acme.Net diagnostics must be absent.
    $netErrors = @($r.errors | Where-Object { $_.PSObject.Properties['namespace'] -and $_.namespace -eq 'Acme.Net' })
    if ($netErrors.Count -gt 0) { throw "out-of-scope Acme.Net diagnostics leaked: $($netErrors.Count)" }
    $coreErrors = @($r.errors | Where-Object { $_.PSObject.Properties['namespace'] -and $_.namespace -eq 'Acme.Core' })
    if ($coreErrors.Count -eq 0) { throw 'expected in-scope Acme.Core diagnostics' }
}

# ----------------------------------------------------------------------
Run-Scenario 'Unknown and ambiguous project hints fail before editing' {
    param($ws)
    Write-Utf8File (Join-Path $ws 'AGENTS.md') $agents
    Write-Utf8File (Join-Path $ws 'src/A/Dup.csproj') $csproj
    Write-Utf8File (Join-Path $ws 'src/B/Dup.csproj') $csproj
    Write-Utf8File (Join-Path $ws 'src/A/A.cs') "namespace Dup.A`n{`n    public sealed class One { public int N { get; set; } }`n}`n"
    Write-Utf8File (Join-Path $ws 'src/B/B.cs') "namespace Dup.B`n{`n    public sealed class Two { public int N { get; set; } }`n}`n"
    Write-Utf8File (Join-Path $ws '.docfx/docfx.json') (New-Docfx @(
        @{ Dest = 'api'; Files = @('src/A/Dup.csproj', 'src/B/Dup.csproj') }))
    Initialize-GitRepo $ws

    $notFound = Invoke-Validator $ws @('--project', 'DoesNotExist')
    Assert-Diagnostic -Report $notFound -Code 'PROJECT_HINT_NOT_FOUND'

    $ambiguous = Invoke-Validator $ws @('--project', 'Dup')
    Assert-Diagnostic -Report $ambiguous -Code 'PROJECT_HINT_AMBIGUOUS'
}

# ----------------------------------------------------------------------
Run-Scenario 'Dry-run skips dirty candidate, falls through to clean, and reports unselected group' {
    param($ws)
    Write-Utf8File (Join-Path $ws 'AGENTS.md') $agents
    Write-Utf8File (Join-Path $ws 'src/P1/P1.csproj') $csproj
    Write-Utf8File (Join-Path $ws 'src/P2/P2.csproj') $csproj
    Write-Utf8File (Join-Path $ws 'src/Q1/Q1.csproj') $csproj
    Write-Utf8File (Join-Path $ws 'src/P1/P1.cs') "namespace Grp.P1`n{`n    public sealed class A { public int N { get; set; } }`n}`n"
    Write-Utf8File (Join-Path $ws 'src/P2/P2.cs') "namespace Grp.P2`n{`n    public sealed class B { public int N { get; set; } }`n}`n"
    Write-Utf8File (Join-Path $ws 'src/Q1/Q1.cs') "namespace Grp.Q1`n{`n    public sealed class C { public int N { get; set; } }`n}`n"
    Write-Utf8File (Join-Path $ws '.docfx/docfx.json') (New-Docfx @(
        @{ Dest = 'api/grp'; Files = @('src/P1/P1.csproj', 'src/P2/P2.csproj') },
        @{ Dest = 'api/q';   Files = @('src/Q1/Q1.csproj') }))
    Initialize-GitRepo $ws

    # Make P1 dirty (modify tracked file) and the entire Q group dirty.
    [System.IO.File]::WriteAllText((Join-Path $ws 'src/P1/P1.cs'), "namespace Grp.P1`n{`n    public sealed class A { public int N { get; set; } public int M { get; set; } }`n}`n", $utf8NoBom)
    [System.IO.File]::WriteAllText((Join-Path $ws 'src/Q1/Q1.cs'), "namespace Grp.Q1`n{`n    public sealed class C { public int N { get; set; } public int M { get; set; } }`n}`n", $utf8NoBom)

    $r = Invoke-Validator $ws @('--dry-run', '--seed', '3')
    $grp = $r.scope.metadataGroups | Where-Object id -eq 'api/grp'
    if (-not $grp.selectedProject) { throw 'grp group should select the clean P2' }
    if ($grp.selectedProject -notlike '*P2*') { throw "grp selected dirty project: $($grp.selectedProject)" }
    Assert-Diagnostic -Report $r -Code 'DRY_RUN_GROUP_UNSELECTED' -Where 'warnings'
}

# ----------------------------------------------------------------------
Run-Scenario 'Valid family exemption removes covered siblings; invalid variants are rejected' {
    param($ws)
    Write-Utf8File (Join-Path $ws 'AGENTS.md') $agents
    Write-Utf8File (Join-Path $ws 'src/Fam/Fam.csproj') $csproj
    Write-Utf8File (Join-Path $ws 'src/Fam/Fam.cs') @'
namespace Fam.Tuples
{
    public sealed class MutableTuple { public int N { get; set; } }
    public sealed class MutableTupleTwo { public int N { get; set; } }
    public sealed class MutableTupleThree { public int N { get; set; } }
    public sealed class Unrelated { public int N { get; set; } }
}
'@
    Write-Utf8File (Join-Path $ws '.docfx/docfx.json') (New-Docfx @(@{ Dest = 'api'; Files = @('src/Fam/Fam.csproj') }))

    # Namespace page that names the anchor and explains selection.
    Write-Utf8File (Join-Path $ws '.docfx/api/namespaces/Fam.Tuples.md') @'
---
uid: Fam.Tuples
summary: *content
---
Use `MutableTuple` when you need a small mutable carrier for positional values. Choose the member by arity: the anchor demonstrates the shared workflow and the higher-arity siblings differ only by how many values they carry.

Availability: `Fam.Tuples`
'@
    # Anchor has a real example.
    Write-Utf8File (Join-Path $ws '.docfx/api/types/Fam.Tuples.MutableTuple.md') @'
---
uid: Fam.Tuples.MutableTuple
example: *content
---
```csharp
namespace Samples;

using Fam.Tuples;

public static class TupleUsage
{
    public static MutableTuple Build()
    {
        var t = new MutableTuple { N = 1 };
        return t;
    }
}
```
'@
    # Unrelated still needs an example.
    Write-Utf8File (Join-Path $ws '.docfx/family-exemptions.json') @'
{
  "families": [
    {
      "familyId": "tuple-arity",
      "namespaceUid": "Fam.Tuples",
      "anchorUid": "Fam.Tuples.MutableTuple",
      "rationale": "generic-arity",
      "coveredUids": ["Fam.Tuples.MutableTupleTwo", "Fam.Tuples.MutableTupleThree"]
    }
  ]
}
'@
    Initialize-GitRepo $ws

    $r = Invoke-Validator $ws
    $fam = $r.scope.familyExemptions | Where-Object familyId -eq 'tuple-arity'
    if (-not $fam) { throw 'family not reported' }
    if (-not $fam.valid) { throw 'family should be valid' }
    # Covered siblings must NOT be required examples anymore.
    $coveredMissing = @($r.errors | Where-Object { $_.code -eq 'EXAMPLE_MISSING' -and ($_.message -match 'MutableTupleTwo' -or $_.message -match 'MutableTupleThree') })
    if ($coveredMissing.Count -gt 0) { throw 'covered siblings were still required' }
    Assert-NoDiagnostic -Report $r -Code 'FAMILY_EXEMPTION_INVALID'

    # Invalid: covers a type outside the namespace / unrelated.
    Write-Utf8File (Join-Path $ws '.docfx/family-exemptions.json') @'
{
  "families": [
    {
      "familyId": "bad",
      "namespaceUid": "Fam.Tuples",
      "anchorUid": "Fam.Tuples.MutableTuple",
      "rationale": "generic-arity",
      "coveredUids": ["Fam.Tuples.DoesNotExist"]
    }
  ]
}
'@
    $bad = Invoke-Validator $ws
    Assert-Diagnostic -Report $bad -Code 'FAMILY_EXEMPTION_INVALID'
}

# ----------------------------------------------------------------------
Run-Scenario 'Family without anchor example or namespace guidance is flagged' {
    param($ws)
    Write-Utf8File (Join-Path $ws 'AGENTS.md') $agents
    Write-Utf8File (Join-Path $ws 'src/Fam/Fam.csproj') $csproj
    Write-Utf8File (Join-Path $ws 'src/Fam/Fam.cs') @'
namespace Fam.Tuples
{
    public sealed class MutableTuple { public int N { get; set; } }
    public sealed class MutableTupleTwo { public int N { get; set; } }
}
'@
    Write-Utf8File (Join-Path $ws '.docfx/docfx.json') (New-Docfx @(@{ Dest = 'api'; Files = @('src/Fam/Fam.csproj') }))
    # Weak namespace page that neither names the anchor nor explains selection.
    Write-Utf8File (Join-Path $ws '.docfx/api/namespaces/Fam.Tuples.md') @'
---
uid: Fam.Tuples
summary: *content
---
This area is available for general use across the package and helps applications get work done.

Availability: `Fam.Tuples`
'@
    Write-Utf8File (Join-Path $ws '.docfx/family-exemptions.json') @'
{
  "families": [
    {
      "familyId": "tuple-arity",
      "namespaceUid": "Fam.Tuples",
      "anchorUid": "Fam.Tuples.MutableTuple",
      "rationale": "generic-arity",
      "coveredUids": ["Fam.Tuples.MutableTupleTwo"]
    }
  ]
}
'@
    Initialize-GitRepo $ws
    $r = Invoke-Validator $ws
    Assert-Diagnostic -Report $r -Code 'FAMILY_ANCHOR_EXAMPLE_MISSING'
    Assert-Diagnostic -Report $r -Code 'FAMILY_NAMESPACE_GUIDANCE_MISSING'
}

# ----------------------------------------------------------------------
Run-Scenario 'Normal target volume never changes full-run scope' {
    param($ws)
    Write-Utf8File (Join-Path $ws 'AGENTS.md') $agents
    Write-Utf8File (Join-Path $ws 'src/Risk/Risk.csproj') $csproj
    $types = (1..6 | ForEach-Object { "    public sealed class T$_ { public int N { get; set; } }" }) -join "`n"
    Write-Utf8File (Join-Path $ws 'src/Risk/Risk.cs') "namespace Risk.Surface`n{`n$types`n}`n"
    Write-Utf8File (Join-Path $ws '.docfx/docfx.json') (New-Docfx @(@{ Dest = 'api'; Files = @('src/Risk/Risk.csproj') }))
    Initialize-GitRepo $ws

    $r = Invoke-Validator $ws
    if ($r.PSObject.Properties.Name -contains 'qualityRisk') { throw 'qualityRisk metadata must not be emitted' }
    if ($r.summary.runMode -ne 'full') { throw "runMode=$($r.summary.runMode); normal execution must remain full" }
    if (@($r.scope.selectedProjects).Count -ne 1) { throw "selectedProjects=$(@($r.scope.selectedProjects).Count); full scope should include the project" }
}

# ----------------------------------------------------------------------
Run-Scenario 'Duplicate type names across assemblies and ambiguous extension owners are flagged' {
    param($ws)
    Write-Utf8File (Join-Path $ws 'AGENTS.md') $agents
    Write-Utf8File (Join-Path $ws 'src/One/One.csproj') $csproj
    Write-Utf8File (Join-Path $ws 'src/Two/Two.csproj') $csproj
    Write-Utf8File (Join-Path $ws 'src/One/One.cs') @'
namespace Pkg.One
{
    public sealed class Result { public int N { get; set; } }

    public static class Helpers
    {
        public static string Describe(this string value) => value.Trim();
    }
}
'@
    Write-Utf8File (Join-Path $ws 'src/Two/Two.cs') @'
namespace Pkg.Two
{
    public sealed class Result { public int N { get; set; } }

    public static class Helpers
    {
        public static string Summarize(this string value) => value.ToUpperInvariant();
    }
}
'@
    Write-Utf8File (Join-Path $ws '.docfx/docfx.json') (New-Docfx @(
        @{ Dest = 'api/one'; Files = @('src/One/One.csproj') },
        @{ Dest = 'api/two'; Files = @('src/Two/Two.csproj') }))
    Initialize-GitRepo $ws

    $r = Invoke-Validator $ws
    Assert-Diagnostic -Report $r -Code 'SYMBOL_COLLISION_UNRESOLVED' -Where 'warnings'
    Assert-Diagnostic -Report $r -Code 'EXTENSION_OWNER_AMBIGUOUS' -Where 'warnings'
}

# ----------------------------------------------------------------------
Run-Scenario 'Unresolved type forwarding is flagged' {
    param($ws)
    Write-Utf8File (Join-Path $ws 'AGENTS.md') $agents
    Write-Utf8File (Join-Path $ws 'src/Fwd/Fwd.csproj') $csproj
    Write-Utf8File (Join-Path $ws 'src/Fwd/Fwd.cs') @'
using System.Runtime.CompilerServices;

[assembly: TypeForwardedTo(typeof(SomeMovedType))]

namespace Fwd.Surface
{
    public sealed class Local { public int N { get; set; } }
}

public sealed class SomeMovedType { }
'@
    Write-Utf8File (Join-Path $ws '.docfx/docfx.json') (New-Docfx @(@{ Dest = 'api'; Files = @('src/Fwd/Fwd.csproj') }))
    Initialize-GitRepo $ws

    $r = Invoke-Validator $ws
    Assert-Diagnostic -Report $r -Code 'TYPE_FORWARDING_UNRESOLVED' -Where 'warnings'
}

# ----------------------------------------------------------------------
Run-Scenario 'Project manifest is written deterministically with packets' {
    param($ws)
    Write-Utf8File (Join-Path $ws 'AGENTS.md') $agents
    Write-Utf8File (Join-Path $ws 'src/Core/Acme.Core.csproj') $csproj
    Write-Utf8File (Join-Path $ws 'src/Core/Core.cs') "namespace Acme.Core`n{`n    public sealed class Widget { public int N { get; set; } }`n}`n"
    Write-Utf8File (Join-Path $ws '.docfx/docfx.json') (New-Docfx @(@{ Dest = 'api'; Files = @('src/Core/Acme.Core.csproj') }))
    Initialize-GitRepo $ws

    $manifest = Join-Path $ws 'manifest.json'
    $r = Invoke-Validator $ws @('--project-manifest', $manifest)
    if (-not (Test-Path $manifest)) { throw 'manifest not written' }
    $m = [System.IO.File]::ReadAllText($manifest) | ConvertFrom-Json
    if ($m.schemaVersion -ne 2) { throw "schemaVersion=$($m.schemaVersion)" }
    if ($m.packets.Count -lt 1) { throw 'manifest has no packets' }
    if (-not ($m.packets[0].namespaces -contains 'Acme.Core')) { throw 'packet missing Acme.Core namespace' }
    $review = Join-Path $ws 'manifest.review.json'
    if (-not (Test-Path $review)) { throw 'review-report template not written' }
    $reviewTemplate = [System.IO.File]::ReadAllText($review) | ConvertFrom-Json
    if (-not @($reviewTemplate.pages | Where-Object path -eq '.docfx/api/namespaces/Acme.Core.md')) { throw 'review template missing namespace page' }
    if (-not @($reviewTemplate.pages | Where-Object path -eq '.docfx/api/types/Acme.Core.Widget.md')) { throw 'review template missing type page' }
    # No BOM.
    $bytes = [System.IO.File]::ReadAllBytes($manifest)
    if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) { throw 'manifest must be BOM-less' }
}

# ----------------------------------------------------------------------
Run-Scenario 'Dry-run manifest resumes authored files through every scoped completion gate' {
    param($ws)
    Write-Utf8File (Join-Path $ws 'AGENTS.md') $agents
    Write-Utf8File (Join-Path $ws 'src/Core/Acme.Core.csproj') $csproj
    Write-Utf8File (Join-Path $ws 'src/Core/Core.cs') @'
namespace Acme.Core
{
    public sealed class Widget
    {
        public int Capacity { get; set; }
    }
}
'@
    Write-Utf8File (Join-Path $ws '.docfx/docfx.json') (New-Docfx @(@{ Dest = 'api'; Files = @('src/Core/Acme.Core.csproj') }))
    Initialize-GitRepo $ws

    $manifest = Join-Path $ws '.docfx/dry-run-manifest.json'
    $initial = Invoke-Validator $ws @('--dry-run', '--seed', '17', '--build-api-model', '--project-manifest', $manifest)
    if (-not (Test-Path $manifest)) { throw 'initial dry-run manifest was not written' }
    if ($initial.scope.selectedProjects.Count -ne 1) { throw "selected=$($initial.scope.selectedProjects.Count)" }
    if (-not $initial.scope.resumeCommand) { throw 'resume command was not reported' }

    Write-Utf8File (Join-Path $ws '.docfx/api/namespaces/Acme.Core.md') @'
---
uid: Acme.Core
summary: *content
---
Use this namespace to configure small work units with an explicit capacity that callers can inspect before dispatch. `Widget` is the concrete entry point when the capacity belongs to one operation rather than shared application state.

Availability: `Acme.Core`
'@
    Write-Utf8File (Join-Path $ws '.docfx/api/types/Acme.Core.Widget.md') @'
---
uid: Acme.Core.Widget
example: *content
---
The example creates a bounded work unit and returns the configured capacity so the observable result can feed admission or batching logic.

```csharp
namespace Samples;

using System;
using Acme.Core;

public static class WidgetCapacity
{
    public static int ConfigureForBatch(int itemCount)
    {
        var widget = new Widget { Capacity = Math.Max(1, itemCount) };
        return widget.Capacity;
    }
}
```
'@

    $missingReview = Invoke-Validator $ws @('--resume-project-manifest', $manifest)
    Assert-Diagnostic -Report $missingReview -Code 'REVIEW_REPORT_MISSING'

    $review = Join-Path $ws '.docfx/dry-run-manifest.review.json'
    $reviewData = [System.IO.File]::ReadAllText($review) | ConvertFrom-Json
    foreach ($page in $reviewData.pages) {
        $page.evidence = if ($page.path -like '*namespaces*') { 'src/Core/Core.cs and README.md' } else { 'src/Core/Core.cs public Widget API' }
        $page.purpose = if ($page.path -like '*namespaces*') { 'Explains when bounded work-unit capacity belongs to one operation.' } else { 'Shows callers how to configure a bounded work unit before dispatch.' }
        $page.observableOutcome = if ($page.path -like '*namespaces*') { 'namespace guidance' } else { 'Returns the effective capacity used by batching logic.' }
        $page.patternComparison = 'Compared with every page in this one-packet pilot; wording and code are specific to Widget capacity.'
    }
    [System.IO.File]::WriteAllText($review, ($reviewData | ConvertTo-Json -Depth 10), $utf8NoBom)

    $final = Invoke-Validator $ws @(
        '--resume-project-manifest', $manifest,
        '--review-report', $review,
        '--build-api-model',
        '--validate-samples',
        '--verify-docfx-build')

    if ($final.summary.runMode -ne 'dry-run') { throw "runMode=$($final.summary.runMode)" }
    if ($final.summary.completionState -ne 'dry-run-passed') {
        $codes = (@($final.errors | ForEach-Object code) -join ',')
        $gates = (@($final.summary.remainingGates) -join ',')
        throw "completion=$($final.summary.completionState); errors=$codes; gates=$gates"
    }
    if ($final.summary.samplesCompiled -ne 1) { throw "samplesCompiled=$($final.summary.samplesCompiled)" }
    if ($final.summary.docfxBuildsVerified -ne 1) { throw "docfxBuildsVerified=$($final.summary.docfxBuildsVerified)" }
    if ($final.scope.selectedProjects.Count -ne 1) { throw 'resumed packet was not selected' }
    Assert-NoDiagnostic -Report $final -Code 'PROJECT_DIRTY_SKIPPED'
    Assert-NoDiagnostic -Report $final -Code 'PROJECT_MANIFEST_DIRTY_CONFLICT'
    Assert-NoDiagnostic -Report $final -Code 'REVIEW_REPORT_INCOMPLETE'
    Assert-NoDiagnostic -Report $final -Code 'EXAMPLE_MISSING'
    Assert-NoDiagnostic -Report $final -Code 'SAMPLE_COMPILE_FAILED'
}

# ----------------------------------------------------------------------
Run-Scenario 'Invalid resume manifest fails closed without selecting the full repository' {
    param($ws)
    Write-Utf8File (Join-Path $ws 'AGENTS.md') $agents
    Write-Utf8File (Join-Path $ws 'src/Core/Acme.Core.csproj') $csproj
    Write-Utf8File (Join-Path $ws 'src/Core/Core.cs') "namespace Acme.Core; public sealed class Widget { public int N { get; set; } }"
    Write-Utf8File (Join-Path $ws '.docfx/docfx.json') (New-Docfx @(@{ Dest = 'api'; Files = @('src/Core/Acme.Core.csproj') }))
    Initialize-GitRepo $ws

    $r = Invoke-Validator $ws @('--resume-project-manifest', (Join-Path $ws 'missing.json'))
    Assert-Diagnostic -Report $r -Code 'PROJECT_MANIFEST_INVALID'
    if ($r.scope.selectedProjects.Count -ne 0) { throw 'invalid manifest broadened into selected projects' }
}

# ----------------------------------------------------------------------
Run-Scenario 'Safe overwrite writer preserves encoding and refuses dirty/duplicate/unbalanced writes' {
    param($ws)
    Write-Utf8File (Join-Path $ws 'AGENTS.md') $agents
    Write-Utf8File (Join-Path $ws 'src/Core/Acme.Core.csproj') $csproj
    Write-Utf8File (Join-Path $ws 'src/Core/Core.cs') "namespace Acme.Core`n{`n    public sealed class Widget { public int N { get; set; } }`n}`n"
    Write-Utf8File (Join-Path $ws '.docfx/docfx.json') (New-Docfx @(@{ Dest = 'api'; Files = @('src/Core/Acme.Core.csproj') }))
    Initialize-GitRepo $ws

    # Write a new overwrite section (LF preserved).
    $req = Join-Path $ws 'req.json'
    $target = '.docfx/api/types/Acme.Core.Widget.md'
    $fence = @'
```csharp
var w = new Acme.Core.Widget { N = 1 };
```
'@
    $reqObj = @{ file = $target; uid = 'Acme.Core.Widget'; mapping = 'example'; prose = 'Build a widget.'; fence = $fence }
    [System.IO.File]::WriteAllText($req, ($reqObj | ConvertTo-Json -Depth 5), $utf8NoBom)
    $out = & dotnet run --file $ValidatorPath -- --repo-root $ws --write-overwrite $req --json 2>$null | Out-String | ForEach-Object { ConvertFrom-ValidatorJson $_ }
    if ($out.status -ne 'passed') { throw "writer status=$($out.status)" }
    $written = Join-Path $ws $target
    if (-not (Test-Path $written)) { throw 'overwrite file not written' }
    $content = [System.IO.File]::ReadAllText($written)
    if ($content -notmatch 'uid: Acme.Core.Widget') { throw 'uid missing' }
    if ($content -match "`r`n") { throw 'LF was not preserved (found CRLF)' }
    $bytes = [System.IO.File]::ReadAllBytes($written)
    if ($bytes[0] -eq 0xEF) { throw 'BOM-less file gained a BOM' }

    # Commit the new file so it is clean, then a duplicate UID write is refused.
    Push-Location $ws
    try {
        & git -c user.email=t@e.com -c user.name=t add -A 2>$null | Out-Null
        & git -c user.email=t@e.com -c user.name=t commit -q -m overwrite 2>$null | Out-Null
    } finally { Pop-Location }

    $dup = & dotnet run --file $ValidatorPath -- --repo-root $ws --write-overwrite $req --json 2>$null | Out-String | ForEach-Object { ConvertFrom-ValidatorJson $_ }
    if (-not @($dup.errors | Where-Object code -eq 'OVERWRITE_UID_DUPLICATE')) { throw 'duplicate UID was not refused' }

    # Unbalanced fence is refused (new file).
    $badReq = Join-Path $ws 'bad.json'
    $badFence = @'
```csharp
var x = 1;
'@
    $badObj = @{ file = '.docfx/api/types/Acme.Core.Other.md'; uid = 'Acme.Core.Other'; mapping = 'example'; fence = $badFence }
    [System.IO.File]::WriteAllText($badReq, ($badObj | ConvertTo-Json -Depth 5), $utf8NoBom)
    $bad = & dotnet run --file $ValidatorPath -- --repo-root $ws --write-overwrite $badReq --json 2>$null | Out-String | ForEach-Object { ConvertFrom-ValidatorJson $_ }
    if (-not @($bad.errors | Where-Object code -eq 'OVERWRITE_FENCE_UNBALANCED')) { throw 'unbalanced fence was not refused' }

    # Dirty-path refusal: modify the committed target then attempt a different UID write to it.
    [System.IO.File]::AppendAllText($written, "`n<!-- edit -->`n", $utf8NoBom)
    $req2 = Join-Path $ws 'req2.json'
    $req2Fence = @'
```csharp
var y = 2;
```
'@
    $req2Obj = @{ file = $target; uid = 'Acme.Core.Widget2'; mapping = 'example'; fence = $req2Fence }
    [System.IO.File]::WriteAllText($req2, ($req2Obj | ConvertTo-Json -Depth 5), $utf8NoBom)
    $dirty = & dotnet run --file $ValidatorPath -- --repo-root $ws --write-overwrite $req2 --json 2>$null | Out-String | ForEach-Object { ConvertFrom-ValidatorJson $_ }
    if (-not @($dirty.errors | Where-Object code -eq 'OVERWRITE_DIRTY_REFUSED')) { throw 'dirty path was not refused' }
}

# ----------------------------------------------------------------------
Run-Scenario 'Single JSON document on stdout while heartbeats stay on stderr' {
    param($ws)
    Write-Utf8File (Join-Path $ws 'AGENTS.md') $agents
    Write-Utf8File (Join-Path $ws 'src/Core/Acme.Core.csproj') $csproj
    Write-Utf8File (Join-Path $ws 'src/Core/Core.cs') "namespace Acme.Core`n{`n    public sealed class Widget { public int N { get; set; } }`n}`n"
    Write-Utf8File (Join-Path $ws '.docfx/docfx.json') (New-Docfx @(@{ Dest = 'api'; Files = @('src/Core/Acme.Core.csproj') }))
    Initialize-GitRepo $ws

    # Invoke-ValidatorRaw discards stderr (2>$null); the returned text must therefore be the single
    # clean JSON document, proving heartbeats stay off stdout.
    $stdout = Invoke-ValidatorRaw @('--repo-root', $ws, '--json')
    if ($stdout.TrimStart().Length -eq 0 -or $stdout.TrimStart()[0] -ne '{') {
        throw "stdout is not a clean single JSON document (starts with '$($stdout.TrimStart().Substring(0, [Math]::Min(40, $stdout.TrimStart().Length)))')"
    }
    $parsed = $stdout | ConvertFrom-Json
    if (-not $parsed.summary) { throw 'stdout did not parse as a single JSON report' }
}

if ($failures -gt 0) {
    throw "$failures project-scoped scenario(s) failed."
}

Write-Host 'DocFX project-scoped regression passed.'
exit 0
