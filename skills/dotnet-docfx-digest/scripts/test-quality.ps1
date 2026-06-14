param(
    [string]$ValidatorPath = (Join-Path $PSScriptRoot 'docfx.cs')
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

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
    $output = & dotnet run --file $ValidatorPath -- --repo-root $workspace --json 2>$null
    if ([string]::IsNullOrWhiteSpace(($output -join "`n"))) {
        throw 'DocFX validator returned no JSON output.'
    }

    return (($output -join "`n") | ConvertFrom-Json)
}

function Assert-Diagnostic {
    param([object]$Report, [string]$Code)

    if (-not @($Report.errors | Where-Object code -eq $Code)) {
        throw "Expected diagnostic '$Code' was not reported."
    }
}

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
