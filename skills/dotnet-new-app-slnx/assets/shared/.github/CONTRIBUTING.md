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
dotnet test
```

## Code Standards

- Use file-scoped namespaces
- Follow the existing code style (enforced via `.editorconfig`)
- All public APIs must have XML documentation comments
- New features require corresponding unit tests

## Pull Request Guidelines

- Keep PRs focused on a single concern
- Update `CHANGELOG.md` under `[Unreleased]`
- Ensure all CI checks pass before requesting review
