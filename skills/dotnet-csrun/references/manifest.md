# Manifest construction

Contract inspected against [csrun source and README](https://github.com/codebeltnet/csrun), released `v0.2.1`, on 2026-11-16. Recheck upstream for changed contracts rather than extending this schema locally.

| Field | Engine contract |
| --- | --- |
| schemaVersion | Required integer 1. |
| mode | Required console or test (case insensitive). |
| source | Required nonempty complete C# source string. |
| framework | Optional supported .NET 10+ TFM; explicit values preserved. Platform TFMs require platform support. Omission selects highest supported GA LTS, not newest installed SDK. |
| dependsOn | Optional array of PackageId@ExactVersion strings; three or four numeric components, optional prerelease. No floating, ranges, or missing versions. Conflicting duplicates fail. |
| sdk | Optional Microsoft.NET.Sdk or Microsoft.NET.Sdk.Web; never inferred from imports. |
| frameworkReferences | Optional framework names; console supports Microsoft.AspNetCore.App only with explicitly selected Microsoft.NET.Sdk.Web, through its implicit reference. Test mode emits explicit references. |

Unknown fields fail. There are no project references or arbitrary MSBuild settings. Existing source directives must match the manifest and occupy the supported leading preamble; do not rewrite or independently parse directives. Delegate manifest validation, SDK selection, dependency resolution, compilation, discovery, and exit status to csrun.

Test mode currently defaults to `xunit.v3@4.0.3`, using Microsoft.Testing.Platform. For reproducible examples explicitly pin that version; supported overrides are stable 4.0 patch versions >= 4.0.3. Do not introduce xUnit v2 or another runner. csrun creates and cleans its own temporary test project; developers create none.

Resolve requested API versions from the source repository and published NuGet metadata. An exact direct pin does not freeze all transitive resolution. If unpublished local code or unsupported build customization is essential, report the source-model gap and use an appropriate project workflow separately; do not disguise it with a different package version.
