# Agent Instructions for {SOLUTION_NAME}

This document provides guidance for AI agents working in this repository.

## Project Overview

{SOLUTION_NAME} is a .NET application targeting {TARGET_FRAMEWORK}.

## Coding Standards

- **Namespaces:** File-scoped namespaces are required (enforced via `.editorconfig`)
- **Top-level statements:** Not allowed (enforced via `.editorconfig`)
- **Language version:** Always use the latest C# features (`LangVersion=latest`)
- **Nullable:** Enable nullable reference types in all new code
- **XML documentation:** All public APIs must have XML documentation comments
- **Testing:** Use xUnit v4 (`xunit.v3` 4.x packages) with Codebelt.Extensions.Xunit.App v12 base classes

## Markdown Prose Formatting

Do not hard-wrap prose to a fixed column width. Keep paragraphs and Markdown list items on continuous natural lines regardless of their length. Do not insert line breaks merely to satisfy 80, 100, 120, or any other column-width limit; rely on editor soft wrapping for visual presentation. Insert physical line breaks only where Markdown structure requires them, such as between paragraphs, headings, list items, code blocks, and tables. When modifying existing Markdown, remove unnecessary hard wrapping from the prose you touch.

## Project Structure

- `src/` — Production source code
- `test/` — Functional tests (project names end with `FunctionalTests`)
- `.github/` — CI/CD workflows, contributing guidelines, Copilot instructions

## Test Conventions

- Test project names must end with `FunctionalTests` (e.g. `{ROOT_NAMESPACE}.Console.FunctionalTests`)
- Tests are **functional tests** that exercise the running application as a whole
- Test classes should inherit from the appropriate base class in `Codebelt.Extensions.Xunit`
- Use `Microsoft.Testing.Platform` as the test runner (root `global.json` selects `test.runner`; `UseMicrosoftTestingPlatformRunner=true` enables project integration)
- Use a supported non-preview .NET 10+ SDK even for older target runtimes
- Test-only shared references supply `Codebelt.Coverlet.MTP` and `Microsoft.Testing.Extensions.HangDump`; keep versions central and do not duplicate inherited references
- Run `dotnet test --project <test-project> -c Release --results-directory <results> -- --report-xunit-trx --coverlet --coverlet-output-format opencover`; verify nonzero discovery, TRX and OpenCover output
- Use managed application fixtures with deferred entrypoint-owned startup, not removed blocking application fixtures
- All tests are executable (`OutputType=Exe`)

## Build & CI

- Centralized package versions via `Directory.Packages.props`
- Centralized build configuration via `Directory.Build.props`
- MinVer for semantic versioning from Git tags
- Simplified CI pipeline (build + test only)

## .bot/ Folder

If a `.bot/` folder exists at the root, it contains **confidential, local-only** working material for AI agents — product requirement documents (PRDs), design proposals, agentic loop state, and brainstorming outputs. This folder is gitignored and never committed.

When starting creative or design work (new features, architecture decisions, PRD drafts), use the [brainstorming skill](https://skills.sh/obra/superpowers/brainstorming) and save outputs to `.bot/`. Only move finalized, non-confidential instructions into `AGENTS.md` or `.github/copilot-instructions.md`.

## Git Operations Safeguards

Agents must never automatically commit code changes or push to remote repositories. Both actions require explicit user approval:

- **Commits**: Always request confirmation from the user before staging and committing code. Present a clear summary of the changes and wait for approval before executing the commit.
- **Remote Operations**: Do not push, pull, fetch, or interact with `origin` or any remote repository without explicit user instruction. These operations modify repository history and can cause data loss if performed unexpectedly.

**Rationale:** Automatic commits can clutter history with incomplete work, temporary debugging code, or unintended changes. Unexpected remote operations risk overwriting or losing commits on shared branches. Always require explicit user approval before performing these actions.
