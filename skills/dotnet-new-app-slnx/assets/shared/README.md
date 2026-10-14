# {SOLUTION_NAME}

> Brief one-line description of what {SOLUTION_NAME} does.

## Features

- Feature 1
- Feature 2

## Getting Started

### Prerequisites

- A supported non-preview .NET 10+ SDK; `global.json` selects the native Microsoft.Testing.Platform runner even when the app targets an older runtime

### Running

For a single-host solution, run the generated project directly:

```bash
dotnet run --project src/{ROOT_NAMESPACE}.{AppType}/{ROOT_NAMESPACE}.{AppType}.csproj
```

If you generated multiple host types, replace this section with one command per generated project under `src/` instead of leaving a single ambiguous `{AppType}` value.

## Testing

Tests use xUnit v4 (`xunit.v3` 4.x), Codebelt xUnit v12, and `Codebelt.Coverlet.MTP`. Run each functional test project with `dotnet test --project <test-project> -c Release --results-directory TestResults -- --report-xunit-trx --coverlet --coverlet-output-format opencover`. Verify nonzero discovery and nonempty TRX/OpenCover output.

## Contributing

Contributions are welcome! Please read [CONTRIBUTING.md](.github/CONTRIBUTING.md).
