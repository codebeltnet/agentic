# Agent Instructions for {SOLUTION_NAME}

This document provides guidance for AI agents working in this repository.

## Project Overview

{SOLUTION_NAME} is a .NET solution targeting {TARGET_FRAMEWORKS}.

## Coding Standards

- **Text encoding:** UTF-8 for text files (enforced via `.editorconfig`)
- **Template rewrites:** Preserve UTF-8 explicitly when scripts or tools rewrite text files; avoid locale-dependent encoding defaults
- **Namespaces:** File-scoped namespaces are required (enforced via `.editorconfig`)
- **Top-level statements:** Not allowed (enforced via `.editorconfig`)
- **Language version:** Always use the latest C# features (`LangVersion=latest`)
- **Nullable:** Enable nullable reference types in all new code
- **XML documentation:** All public APIs must have XML documentation comments
- **Testing:** Use xUnit v3 with Codebelt.Extensions.Xunit.App base classes

## Project Structure

- `src/` — Production source code
- `test/` — Unit and integration tests (project names end with `Tests`)
- `tuning/` — Benchmark projects and benchmark source code
- `tooling/` — Solution-level executable tooling such as the benchmark runner host
- `reports/` — Benchmark reports and tuning output produced by tooling
- `.nuget/` — Per-package NuGet metadata (icon, README, release notes)
- `.docfx/` — DocFX documentation configuration
- `.github/` — CI/CD workflows, contributing guidelines, Copilot instructions

## Test Conventions

- Test project names must end with `Tests` (e.g. `{PROJECT_NAME}.Tests`)
- Test classes should inherit from the appropriate base class in `Codebelt.Extensions.Xunit`
- Use `Microsoft.Testing.Platform` as the test runner (`UseMicrosoftTestingPlatformRunner=true`)
- All tests are executable (`OutputType=Exe`)

## Build & CI

- Centralized package versions via `Directory.Packages.props`
- Resolve new or updated `Directory.Packages.props` versions from NuGet.org and keep them on the latest stable listed releases
- Centralized build configuration via `Directory.Build.props`
- MinVer for semantic versioning from Git tags
- Strong-name signing is enabled in CI environments (`CI=true`)
- Keep `.github/dependabot.yml` enabled at the repo root so central NuGet package management stays current

## .bot/ Folder

If a `.bot/` folder exists at the root, it contains **confidential, local-only** working material for AI agents — product requirement documents (PRDs), design proposals, agentic loop state, and brainstorming outputs. This folder is gitignored and never committed.

When starting creative or design work (new features, architecture decisions, PRD drafts), use the [brainstorming skill](https://skills.sh/obra/superpowers/brainstorming) and save outputs to `.bot/`. Only move finalized, non-confidential instructions into `AGENTS.md` or `.github/copilot-instructions.md`.
