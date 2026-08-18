# xUnit v3 and Microsoft Testing Platform modernization

Modernize the selected project without rewriting unrelated project infrastructure.

## Required project shape

- Replace xUnit v2 packages with `xunit.v3` and the repository's runner packages, at the versions the Step 3 resolver anchored to the Codebelt xUnit release. "v3" names the package, not the version: `xunit.v3` has its own majors above 3, and this modernization targets the one Codebelt xUnit depends on.
- Set test projects to executable output when not inherited: `<OutputType>Exe</OutputType>`.
- Enable Microsoft Testing Platform: `<UseMicrosoftTestingPlatformRunner>true</UseMicrosoftTestingPlatformRunner>`.
- Remove `Xunit.Abstractions`; import `Xunit` for `ITestOutputHelper`.
- Keep `Microsoft.NET.Test.Sdk` and `xunit.v3.runner.console`. Retain an established shared `xunit.runner.visualstudio` reference; otherwise add it with `PrivateAssets="all"` when the required `dotnet test` validation needs the adapter, matching the Codebelt xUnit project shape.
- Preserve coverage packages and their `PrivateAssets`/`IncludeAssets` metadata.

## Package ownership

Do not move versions between project and central files merely because the Codebelt source repo uses Central Package Management. Preserve the selected repository's ownership model. When central management is active, add versions to the owning `Directory.Packages.props` and keep project references versionless.

## Source compatibility

Preserve test names. Update only v2 API breaks, such as `using Xunit.Abstractions;`. Do not rewrite assertions or method names as modernization cleanup.

Run restore, build, and test after the project-file change before doing optional source cleanup. A zero-discovery test command is not a successful test run: require the expected non-zero test count and zero failures. If `dotnet test` discovers no tests from an executable MTP project, add or restore the repository-appropriate adapter instead of reporting the MTP executable run as proof that the requested `dotnet test` gate passed.
