param(
    [string]$ValidatorPath = (Join-Path $PSScriptRoot 'docfx.cs')
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
# The validator exits non-zero for fixtures that contain diagnostics and writes append-only packet
# heartbeats to stderr; opt out of native-command error promotion so neither is treated as a
# terminating error when this script is invoked from validate-skill-templates.ps1.
$PSNativeCommandUseErrorActionPreference = $false

$utf8NoBom = [System.Text.UTF8Encoding]::new($false)
$workspace = Join-Path ([System.IO.Path]::GetTempPath()) ('dotnet-docfx-quality-' + [guid]::NewGuid().ToString('N'))

function Write-Utf8File {
    param([string]$Path, [string]$Content)

    $directory = Split-Path -Parent $Path
    if (-not (Test-Path $directory)) {
        New-Item -ItemType Directory -Path $directory -Force | Out-Null
    }

    [System.IO.File]::WriteAllText($Path, $Content, $utf8NoBom)
}

function Invoke-Validator {
    param([string]$Workspace = $workspace)

    # Run the native validator with ErrorActionPreference relaxed so its non-zero exit and stderr
    # packet heartbeats are never promoted to a terminating PowerShell error (explicit `throw`
    # statements below still halt the test). This keeps behavior identical whether the script is run
    # directly or invoked from validate-skill-templates.ps1, which sets [Console]::OutputEncoding.
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $output = & dotnet run --file $ValidatorPath -- --repo-root $Workspace --json 2>$null
    } finally {
        $ErrorActionPreference = $prev
    }

    $text = ($output -join "`n")
    if ([string]::IsNullOrWhiteSpace($text)) {
        throw 'DocFX validator returned no JSON output.'
    }

    $start = $text.IndexOf('{')
    if ($start -lt 0) { throw "DocFX validator returned no JSON document. Output: $text" }
    return ($text.Substring($start) | ConvertFrom-Json)
}

function Assert-Diagnostic {
    param([object]$Report, [string]$Code)

    if (-not @($Report.errors | Where-Object code -eq $Code)) {
        throw "Expected diagnostic '$Code' was not reported."
    }
}

function Assert-NoDiagnostic {
    param([object]$Report, [string]$Code)

    if (@($Report.errors | Where-Object code -eq $Code)) {
        throw "Diagnostic '$Code' was reported but the fixture expected it to be absent."
    }
}

function New-DocfxJson {
    param([string[]]$ProjectFiles)

    $files = ($ProjectFiles | ForEach-Object { "`"$_`"" }) -join ', '
    return @"
{
  "metadata": [{
    "src": [{ "src": "../", "files": [$files] }],
    "dest": "api",
    "properties": { "TargetFramework": "net10.0" }
  }],
  "build": {
    "content": [{ "files": ["*.md"], "exclude": ["api/namespaces/**", "api/types/**"] }],
    "overwrite": [{ "files": ["api/namespaces/**/*.md", "api/types/**/*.md"] }],
    "dest": "_site"
  }
}
"@
}

$projectCsproj = @'
<Project Sdk="Microsoft.NET.Sdk">
  <PropertyGroup>
    <TargetFramework>net10.0</TargetFramework>
  </PropertyGroup>
</Project>
'@

try {
    $arrow = "$([char]0x2B07)$([char]0xFE0F)"
    Write-Utf8File (Join-Path $workspace 'AGENTS.md') @'
<!-- dotnet-docfx-digest:start -->
Managed DocFX guidance.
<!-- dotnet-docfx-digest:end -->
'@
    Write-Utf8File (Join-Path $workspace 'src/Acme.Core.csproj') @'
<Project Sdk="Microsoft.NET.Sdk">
  <PropertyGroup>
    <TargetFramework>net10.0</TargetFramework>
  </PropertyGroup>
</Project>
'@
    Write-Utf8File (Join-Path $workspace 'src/Api.cs') @'
namespace Acme.Core;

public sealed class Options
{
    public int Attempts { get; set; }
}

public static class StringExtensions
{
    public static string Normalize(this string value)
    {
        return value.Trim().ToUpperInvariant();
    }
}
'@
    Write-Utf8File (Join-Path $workspace '.docfx/docfx.json') @'
{
  "metadata": [{
    "src": [{ "src": "../", "files": ["src/Acme.Core.csproj"] }],
    "dest": "api",
    "properties": { "TargetFramework": "net10.0" }
  }],
  "build": {
    "content": [{ "files": ["*.md"], "exclude": ["api/namespaces/**", "api/types/**"] }],
    "overwrite": [{ "files": ["api/namespaces/**/*.md", "api/types/**/*.md"] }],
    "dest": "_site"
  }
}
'@

    Write-Utf8File (Join-Path $workspace '.docfx/api/namespaces/Acme.Core.md') @"
---
uid: Acme.Core
summary: *content
---
The Acme.Core namespace contains types and extension methods for common work.

Availability: `Acme.Core`

## Extension Members

|Type|Ext|Methods|
|---|---|---|
|String|$arrow|``Normalize``|
"@
    Write-Utf8File (Join-Path $workspace '.docfx/api/types/Acme.Core.Options.md') @'
---
uid: Acme.Core.Options
example: *content
---
```csharp
namespace Samples;

public static class MetadataLookup
{
    public static Type? Find() => Type.GetType("Acme.Core.Options, Acme.Core");
}
```
'@
    Write-Utf8File (Join-Path $workspace '.docfx/api/namespaces/Acme.Core.StringExtensions.md') @'
---
uid: Acme.Core.StringExtensions
example: *content
---
The documented extension method is available at runtime.

```csharp
namespace Cuemon.DocFxExamples;

public static class DocumentedExtensionExample
{
    public static string Describe() => "Normalize";
}
```

---
uid: Acme.Core.StringExtensions
example: *content
---
The documented type is an extension surface.

```csharp
namespace Cuemon.DocFxExamples;

public static class DocumentedTypeExample
{
    public static string Describe() => "StringExtensions";
}
```
'@

    $bad = Invoke-Validator
    foreach ($code in @(
        'NAMESPACE_PROSE_INVENTORY_ONLY',
        'NAMESPACE_USAGE_GUIDANCE_MISSING',
        'NAMESPACE_START_HERE_MISSING',
        'EXAMPLE_UID_DUPLICATE',
        'EXAMPLE_REFLECTION_ONLY',
        'EXAMPLE_PLACEHOLDER'
    )) {
        Assert-Diagnostic -Report $bad -Code $code
    }

    Write-Utf8File (Join-Path $workspace '.docfx/api/namespaces/Acme.Core.md') @"
---
uid: Acme.Core
summary: *content
---
Use ``Options`` when a caller needs to keep retry policy values together before configuring a client. It gives validation and composition code one explicit object to pass across boundaries.

Start with ``Options`` for policy values; use ``Normalize`` at text-ingress boundaries when identifiers need stable casing and whitespace before comparison or storage.

Availability: `Acme.Core`

## Extension Members

|Type|Ext|Methods|
|---|---|---|
|String|$arrow|``Normalize``|
"@
    Write-Utf8File (Join-Path $workspace '.docfx/api/types/Acme.Core.Options.md') @'
---
uid: Acme.Core.Options
example: *content
---
```csharp
namespace Samples;

using Acme.Core;

public static class RetryConfiguration
{
    public static Options Create() => new() { Attempts = 3 };
}
```
'@
    Write-Utf8File (Join-Path $workspace '.docfx/api/namespaces/Acme.Core.StringExtensions.md') @'
---
uid: Acme.Core.StringExtensions
example: *content
---
```csharp
namespace Samples;

using Acme.Core;

public static class IdentifierInput
{
    public static string Prepare(string value) => value.Normalize();
}
```
'@

    $good = Invoke-Validator
    $qualityCodes = @(
        'NAMESPACE_FLYIN_MISSING',
        'NAMESPACE_PROSE_INVENTORY_ONLY',
        'NAMESPACE_USAGE_GUIDANCE_MISSING',
        'NAMESPACE_START_HERE_MISSING',
        'EXAMPLE_UID_DUPLICATE',
        'EXAMPLE_PLACEHOLDER',
        'EXAMPLE_REFLECTION_ONLY',
        'EXAMPLE_TARGET_NOT_USED',
        'EXTENSION_EXAMPLE_NOT_INVOKED',
        'EXAMPLE_MISSING'
    )
    $remaining = @($good.errors | Where-Object { $_.code -in $qualityCodes })
    if ($remaining.Count -gt 0) {
        throw "Scenario-led fixture still has quality diagnostics: $($remaining.code -join ', ')"
    }

    Write-Host 'DocFX semantic quality regression passed.'
} finally {
    if (Test-Path $workspace) {
        Remove-Item -Path $workspace -Recurse -Force
    }
}

# ----------------------------------------------------------------------
# Scenario: source discovery for Cuemon-style next-line namespace braces.
# A block namespace whose opening brace is on the following line must not
# hide its public types. Before the scanner fix the validator discovered
# ~0 targets here; the fixture fails if discovery collapses to one target.
# ----------------------------------------------------------------------
$discovery = Join-Path ([System.IO.Path]::GetTempPath()) ('dotnet-docfx-discovery-' + [guid]::NewGuid().ToString('N'))
try {
    Write-Utf8File (Join-Path $discovery 'AGENTS.md') @'
<!-- dotnet-docfx-digest:start -->
Managed DocFX guidance.
<!-- dotnet-docfx-digest:end -->
'@
    Write-Utf8File (Join-Path $discovery 'src/Acme.Widgets.csproj') $projectCsproj
    Write-Utf8File (Join-Path $discovery 'src/Widgets.cs') @'
namespace Acme.Widgets
{
    public sealed class Gadget
    {
        public int Size { get; set; }
    }

    public sealed class Sprocket
    {
        public int Teeth { get; set; }
    }

    public sealed class Cog
    {
        public int Radius { get; set; }
    }

    public static class WidgetExtensions
    {
        public static string Describe(this Gadget gadget) => gadget.Size.ToString();
    }
}
'@
    Write-Utf8File (Join-Path $discovery '.docfx/docfx.json') (New-DocfxJson -ProjectFiles @('src/Acme.Widgets.csproj'))

    $discoveryReport = Invoke-Validator -Workspace $discovery
    if ([int]$discoveryReport.summary.requiredExampleTargets -lt 4) {
        throw "Next-line namespace brace discovery under-reported targets: expected >= 4, got $($discoveryReport.summary.requiredExampleTargets)."
    }
    if (-not @($discoveryReport.errors | Where-Object { $_.code -eq 'EXAMPLE_MISSING' -and $_.namespace -eq 'Acme.Widgets' })) {
        throw 'Discovery fixture did not surface Acme.Widgets targets through the source scanner.'
    }

    Write-Host 'DocFX next-line namespace discovery passed.'
} finally {
    if (Test-Path $discovery) {
        Remove-Item -Path $discovery -Recurse -Force
    }
}

# ----------------------------------------------------------------------
# Scenario: known-bad example quality patterns observed in the Cuemon run.
# Each anti-pattern must raise its dedicated diagnostic.
# ----------------------------------------------------------------------
$quality = Join-Path ([System.IO.Path]::GetTempPath()) ('dotnet-docfx-examples-' + [guid]::NewGuid().ToString('N'))
try {
    Write-Utf8File (Join-Path $quality 'AGENTS.md') @'
<!-- dotnet-docfx-digest:start -->
Managed DocFX guidance.
<!-- dotnet-docfx-digest:end -->
'@
    Write-Utf8File (Join-Path $quality 'src/Acme.Demo.csproj') $projectCsproj
    Write-Utf8File (Join-Path $quality 'src/Demo.cs') @'
namespace Acme.Demo;

public sealed class Holder { public int Value { get; set; } }
public sealed class Outcome { public int Value { get; set; } }
public sealed class Forwarder { public int Value { get; set; } }
public sealed class RepA { public int Value { get; set; } }
public sealed class RepB { public int Value { get; set; } }
public sealed class RepC { public int Value { get; set; } }
'@
    Write-Utf8File (Join-Path $quality '.docfx/docfx.json') (New-DocfxJson -ProjectFiles @('src/Acme.Demo.csproj'))

    # Weak inventory lead left intact with appended start-here guidance.
    Write-Utf8File (Join-Path $quality '.docfx/api/namespaces/Acme.Demo.md') @'
---
uid: Acme.Demo
summary: *content
---
The Acme.Demo namespace contains types and helpers that enable common demo work across the package.

Start with `Holder` to keep state together; reach for `Forwarder` when callers need pass-through access.

Availability: `Acme.Demo`
'@

    # default! holder property.
    Write-Utf8File (Join-Path $quality '.docfx/api/types/Acme.Demo.Holder.md') @'
---
uid: Acme.Demo.Holder
example: *content
---
```csharp
namespace Samples;

using Acme.Demo;

public static class HolderState
{
    public static Holder Current { get; } = default!;
}
```
'@

    # Construction with no observable next action.
    Write-Utf8File (Join-Path $quality '.docfx/api/types/Acme.Demo.Outcome.md') @'
---
uid: Acme.Demo.Outcome
example: *content
---
```csharp
namespace Samples;

using Acme.Demo;

public static class UseOutcome
{
    public static Outcome Build()
    {
        var result = new Outcome();
        return result;
    }
}
```
'@

    # Mass forwarding shell.
    Write-Utf8File (Join-Path $quality '.docfx/api/types/Acme.Demo.Forwarder.md') @'
---
uid: Acme.Demo.Forwarder
example: *content
---
```csharp
namespace Samples;

using Acme.Demo;

public static class ForwarderFacade
{
    public static int Read(Forwarder source) => source.Read();
    public static int Peek(Forwarder source) => source.Peek();
    public static int Count(Forwarder source) => source.Count();
}
```
'@

    # Three structurally identical examples differing only by identifiers.
    foreach ($name in @('RepA', 'RepB', 'RepC')) {
        Write-Utf8File (Join-Path $quality ".docfx/api/types/Acme.Demo.$name.md") @"
---
uid: Acme.Demo.$name
example: *content
---
``````csharp
namespace Samples;

using Acme.Demo;

public static class Use$name
{
    public static $name Create()
    {
        var item = new $name();
        item.Apply(1);
        return item;
    }
}
``````
"@
    }

    $badQuality = Invoke-Validator -Workspace $quality
    foreach ($code in @(
        'EXAMPLE_DEFAULT_PLACEHOLDER',
        'EXAMPLE_NO_OBSERVABLE_OUTCOME',
        'EXAMPLE_FORWARDING_SCAFFOLD',
        'EXAMPLE_TEMPLATE_REPETITION',
        'NAMESPACE_APPEND_ONLY_REPAIR'
    )) {
        Assert-Diagnostic -Report $badQuality -Code $code
    }

    Write-Host 'DocFX example quality regression passed.'
} finally {
    if (Test-Path $quality) {
        Remove-Item -Path $quality -Recurse -Force
    }
}

# ----------------------------------------------------------------------
# Scenario: one authored extension-container example may satisfy several extension targets.
# The section is one authored scenario and must not be counted once per covered method.
# ----------------------------------------------------------------------
$sharedExtension = Join-Path ([System.IO.Path]::GetTempPath()) ('dotnet-docfx-shared-extension-' + [guid]::NewGuid().ToString('N'))
try {
    $arrow = "$([char]0x2B07)$([char]0xFE0F)"
    Write-Utf8File (Join-Path $sharedExtension 'AGENTS.md') @'
<!-- dotnet-docfx-digest:start -->
Managed DocFX guidance.
<!-- dotnet-docfx-digest:end -->
'@
    Write-Utf8File (Join-Path $sharedExtension 'src/Acme.Extensions.csproj') $projectCsproj
    Write-Utf8File (Join-Path $sharedExtension 'src/Extensions.cs') @'
namespace Acme.Extensions;

public static class TextExtensions
{
    public static string Trimmed(this string value) => value.Trim();
    public static string Uppercase(this string value) => value.ToUpperInvariant();
    public static int WordCount(this string value) => value.Split(' ', System.StringSplitOptions.RemoveEmptyEntries).Length;
}
'@
    Write-Utf8File (Join-Path $sharedExtension '.docfx/docfx.json') (New-DocfxJson -ProjectFiles @('src/Acme.Extensions.csproj'))
    Write-Utf8File (Join-Path $sharedExtension '.docfx/api/namespaces/Acme.Extensions.md') @"
---
uid: Acme.Extensions
summary: *content
---
Choose these text operations when input needs small, explicit transformations before display or comparison. `TextExtensions` keeps each operation available directly on the source string.

## Extension Members

|Type|Ext|Methods|
|---|---|---|
|String|$arrow|``Trimmed``, ``Uppercase``, ``WordCount``|

Availability: ``Acme.Extensions``
"@
    Write-Utf8File (Join-Path $sharedExtension '.docfx/api/types/Acme.Extensions.TextExtensions.md') @'
---
uid: Acme.Extensions.TextExtensions
example: *content
---
This example prepares a user-entered title and reports the resulting word count.

```csharp
using System;
using Acme.Extensions;

namespace Samples;

public static class TextPreparationExample
{
    public static void PrintPreparedTitle()
    {
        const string input = "  release notes  ";
        var prepared = input.Trimmed().Uppercase();

        Console.WriteLine(prepared);
        Console.WriteLine(prepared.WordCount());
    }
}
```
'@

    $sharedReport = Invoke-Validator -Workspace $sharedExtension
    Assert-NoDiagnostic -Report $sharedReport -Code 'EXAMPLE_TEMPLATE_REPETITION'
    Assert-NoDiagnostic -Report $sharedReport -Code 'EXAMPLE_MISSING'

    Write-Host 'DocFX shared extension example fingerprint regression passed.'
} finally {
    if (Test-Path $sharedExtension) {
        Remove-Item -Path $sharedExtension -Recurse -Force
    }
}

# ----------------------------------------------------------------------
# Scenario: mechanical namespace prose repeated across unrelated pages.
# Three namespaces that share one normalized prose skeleton must fail. Two unrelated pages using
# the distinctive "namespace helps you / Use it when / Start with" cadence must also fail even
# when their domain vocabulary is otherwise different.
# ----------------------------------------------------------------------
$prose = Join-Path ([System.IO.Path]::GetTempPath()) ('dotnet-docfx-prose-' + [guid]::NewGuid().ToString('N'))
try {
    Write-Utf8File (Join-Path $prose 'AGENTS.md') @'
<!-- dotnet-docfx-digest:start -->
Managed DocFX guidance.
<!-- dotnet-docfx-digest:end -->
'@
    Write-Utf8File (Join-Path $prose 'src/Acme.Families.csproj') $projectCsproj
    Write-Utf8File (Join-Path $prose 'src/Families.cs') @'
namespace Alpha
{
    public sealed class AlphaType { public int Value { get; set; } }
}

namespace Beta
{
    public sealed class BetaType { public int Value { get; set; } }
}

namespace Gamma
{
    public sealed class GammaType { public int Value { get; set; } }
}
'@
    Write-Utf8File (Join-Path $prose '.docfx/docfx.json') (New-DocfxJson -ProjectFiles @('src/Acme.Families.csproj'))

    foreach ($pair in @(@('Alpha', 'AlphaType'), @('Beta', 'BetaType'), @('Gamma', 'GammaType'))) {
        $ns = $pair[0]
        $type = $pair[1]
        Write-Utf8File (Join-Path $prose ".docfx/api/namespaces/$ns.md") @"
---
uid: $ns
summary: *content
---
Use ``$type`` when callers need a single entry point for the workflow. It keeps configuration explicit and easy to pass across boundaries.

Availability: ``$ns``
"@
    }

    $proseReport = Invoke-Validator -Workspace $prose
    Assert-Diagnostic -Report $proseReport -Code 'NAMESPACE_PROSE_TEMPLATE_REPETITION'

    # Replace the three exact skeletons with two lexically different pages that retain the same
    # mechanical rhetorical frame. Gamma remains independently written and must not be required
    # to trigger the diagnostic.
    Write-Utf8File (Join-Path $prose '.docfx/api/namespaces/Alpha.md') @'
---
uid: Alpha
summary: *content
---
The `Alpha` namespace helps you retry transient work without scattering recovery bookkeeping across call sites.

Use it when a caller owns the retry decision and needs a bounded attempt count. If you are defining the recovery policy, begin with `AlphaType` to execute the protected operation.

Availability: `Alpha`
'@
    Write-Utf8File (Join-Path $prose '.docfx/api/namespaces/Beta.md') @'
---
uid: Beta
summary: *content
---
The `Beta` namespace helps you divide a large import into predictable processing windows.

Use it when workers need bounded ranges instead of hand-maintained indexes. If you are dividing a new workload, start with `BetaType` to plan each assignment.

Availability: `Beta`
'@
    Write-Utf8File (Join-Path $prose '.docfx/api/namespaces/Gamma.md') @'
---
uid: Gamma
summary: *content
---
Choose `GammaType` when a boundary needs one explicit value that can be inspected before work begins. It keeps the decision local to the caller rather than hiding it in shared state.

Availability: `Gamma`
'@

    $rhetoricalReport = Invoke-Validator -Workspace $prose
    Assert-Diagnostic -Report $rhetoricalReport -Code 'NAMESPACE_PROSE_TEMPLATE_REPETITION'

    Write-Utf8File (Join-Path $prose '.docfx/api/namespaces/Alpha.md') @'
---
uid: Alpha
summary: *content
---
Use the `Alpha` namespace when operations can fail transiently and callers need bounded retries. The namespace separates recovery policy from the work itself.

Start with `AlphaType` to define the attempt budget, then execute the protected operation. Choose this namespace when retry behavior belongs to application flow.

Availability: `Alpha`
'@
    Write-Utf8File (Join-Path $prose '.docfx/api/namespaces/Beta.md') @'
---
uid: Beta
summary: *content
---
Use the `Beta` namespace when imports need predictable windows instead of handwritten indexes. The namespace keeps range planning in one place.

Start with `BetaType` to select the window size, then create each assignment. Choose this namespace when the caller controls batching directly.

Availability: `Beta`
'@

    $imperativeReport = Invoke-Validator -Workspace $prose
    Assert-Diagnostic -Report $imperativeReport -Code 'NAMESPACE_PROSE_TEMPLATE_REPETITION'

    # Vary the lead paragraphs while retaining the repeated navigation paragraph that escaped
    # the earlier signatures during the representative forward test.
    Write-Utf8File (Join-Path $prose '.docfx/api/namespaces/Alpha.md') @'
---
uid: Alpha
summary: *content
---
The `Alpha` namespace turns transient failures into bounded recovery attempts without spreading retry bookkeeping across call sites. Use it when application code owns the recovery decision.

Start with `AlphaType` to choose the attempt budget, then pass that policy to the operation that performs the work.

Availability: `Alpha`
'@
    Write-Utf8File (Join-Path $prose '.docfx/api/namespaces/Beta.md') @'
---
uid: Beta
summary: *content
---
The `Beta` namespace divides large imports into predictable processing windows for workers and queues. It is useful when callers need bounded ranges instead of handwritten indexes.

Start with `BetaType` to select the window size, then use the resulting assignments in the processing loop.

Availability: `Beta`
'@

    $navigationReport = Invoke-Validator -Workspace $prose
    Assert-Diagnostic -Report $navigationReport -Code 'NAMESPACE_PROSE_TEMPLATE_REPETITION'

    Write-Host 'DocFX namespace prose repetition regression passed.'
} finally {
    if (Test-Path $prose) {
        Remove-Item -Path $prose -Recurse -Force
    }
}

# The validator returns a non-zero exit code for fixtures that intentionally contain
# diagnostics. Success here is determined by the assertions above not throwing, so reset
# the process exit code for callers (e.g. validate-skill-templates.ps1) that inspect it.
exit 0
