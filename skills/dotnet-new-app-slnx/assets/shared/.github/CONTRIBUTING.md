# Contributing to {SOLUTION_NAME}

Thank you for your interest in contributing!

## How to Contribute

1. Fork the repository
2. Create a feature branch (`git checkout -b feature/my-feature`)
3. Commit your changes following the project's commit conventions
4. Push to your branch and open a pull request against `main`

## Development Setup

```bash
dotnet restore
dotnet build
dotnet test --project test/{ROOT_NAMESPACE}.{AppType}.FunctionalTests/{ROOT_NAMESPACE}.{AppType}.FunctionalTests.csproj -c Release --results-directory TestResults -- --report-xunit-trx --coverlet --coverlet-output-format opencover
```

Use a supported non-preview .NET 10+ SDK with the root `global.json` MTP runner selection. For multiple hosts, run the command once per functional test project. Verify tests were discovered and the TRX/OpenCover files are nonempty.

## Code Standards

- Use file-scoped namespaces
- Follow the existing code style (enforced via `.editorconfig`)
- All public APIs must have XML documentation comments
- New features require corresponding unit tests

## Pull Request Guidelines

- Keep PRs focused on a single concern
- Update `CHANGELOG.md` under `[Unreleased]`
- Ensure all CI checks pass before requesting review
