# {SOLUTION_NAME}

[![Build Status](https://github.com/{REPO_OWNER}/{REPO_SLUG}/actions/workflows/ci-pipeline.yml/badge.svg?branch=main)](https://github.com/{REPO_OWNER}/{REPO_SLUG}/actions/workflows/ci-pipeline.yml)
[![codecov](https://codecov.io/gh/{REPO_OWNER}/{REPO_SLUG}/graph/badge.svg)](https://codecov.io/gh/{REPO_OWNER}/{REPO_SLUG})
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

> Brief one-line description of what {SOLUTION_NAME} does.

## Features

- Feature 1
- Feature 2

## Getting Started

### Installation

```bash
dotnet add package {PROJECT_NAME}
```

### Usage

```csharp
// Add a usage example here
```

## Documentation

Full documentation is available at [{PACKAGE_PROJECT_URL}]({PACKAGE_PROJECT_URL}).

## Testing

Use a supported non-preview .NET 10+ SDK; root `global.json` selects Microsoft.Testing.Platform. Tests use xUnit v4 (`xunit.v3` 4.x), Codebelt xUnit v12, and `Codebelt.Coverlet.MTP`. Run `dotnet test --project test/{PROJECT_NAME}.Tests/{PROJECT_NAME}.Tests.csproj -c Release --results-directory TestResults -- --report-xunit-trx --coverlet --coverlet-output-format opencover`. Validate each executable TFM and verify nonzero discovery plus nonempty TRX/OpenCover files.

## Contributing

Contributions are welcome! Please read [CONTRIBUTING.md](.github/CONTRIBUTING.md).

## License

This project is licensed under the MIT License — see [LICENSE](LICENSE).
