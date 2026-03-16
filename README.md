# Agentic Skills

A curated collection of [skills](https://skills.sh) — reusable instruction sets that teach AI agents how to follow specific workflows, conventions, and standards. Designed to work with any agent that supports the skills ecosystem: GitHub Copilot, Claude Code, Cursor, Codex, OpenCode, and [many more](https://skills.sh).

## What are skills?

Skills are Markdown files that an AI agent reads before responding. When a skill is active, the agent follows the rules it contains — consistently, across any tool or model that supports them. They're a lightweight way to encode your team's conventions once and apply them everywhere.

One repo-wide convention matters especially for scaffolding skills: prefer dynamic defaults over hardcoded values whenever a reliable source exists. Derive time-sensitive or environment-sensitive values from git metadata, repo state, or official machine-readable feeds so skills age gracefully instead of drifting.

Another repo rule is intentionally strict: every repo-managed skill ships with its own `evals/evals.json`, and those evals are run per skill from a temp workspace instead of from inside this repository.

There is also an interim Codex compatibility workaround in [AGENTS.md](AGENTS.md): the repo mirrors the current `~/.codex/AGENTS.override.md` decision and code-change rules so they still apply even when a Codex build fails to auto-load that personal override file.

One more consistency rule matters for form-driven skills: native input fields are treated as a host feature, not something a model can rely on. Skills in this repo must stay usable with or without UI widgets, and must fall back to the same deterministic one-field-at-a-time flow when the host only supports plain chat.

Validation follows the same philosophy: run
`scripts/validate-skill-templates.ps1` locally for the fast feedback
loop, and let GitHub Actions rerun that same script on pushes and pull
requests as the safety net.

## Install a skill

Install any skill directly from this repository with a single command:

```bash
npx skills add https://github.com/codebeltnet/agentic --skill <skill-name>
```

For example:

```bash
npx skills add https://github.com/codebeltnet/agentic --skill git-visual-commits
```

Then activate it in your agent. For example, in GitHub Copilot CLI:

```
Use the skill tool to invoke the "<skill-name>" skill.
```

## Always-on skills

Depending on the agent runtime, skills installed via `npx skills add` may live in `~/.claude/skills/` and/or `~/.agents/skills/`. Treat both as personal global skill folders: if you use both toolchains, keep repo-authored skills mirrored between them so each agent sees the same version. Either way, installed skills are **automatically loaded in every session** — no manual invocation needed. The agent reads the skill's description and activates it when relevant (e.g. you say "commit this" and the `git-visual-commits` skill kicks in).

If you want a bundle of skills always available, just install them all:

```bash
npx skills add https://github.com/codebeltnet/agentic --skill git-visual-commits
npx skills add https://github.com/codebeltnet/agentic --skill git-keep-a-changelog
npx skills add https://github.com/codebeltnet/agentic --skill git-visual-squash-summary
npx skills add https://github.com/codebeltnet/agentic --skill trunk-first-repo
npx skills add https://github.com/codebeltnet/agentic --skill dotnet-strong-name-signing
# npx skills add https://github.com/codebeltnet/agentic --skill another-skill
```

### Scoping options

| Location | Scope | When to use |
|----------|-------|-------------|
| `~/.agents/skills/` | All sessions, all projects | Global skills for agents that read the shared `~/.agents` install |
| `~/.claude/skills/` | All sessions, all projects | Your personal defaults — always on everywhere |
| `.claude/skills/` (in a repo) | Project-scoped | Shared team conventions for a specific codebase |
| `.github/skills/` (in a repo) | GitHub Copilot / VS Code | When your team uses Copilot agent mode in the IDE |

> **Tip:** You can mix scopes. Install your personal favorites globally, and add project-specific skills to the repo so your whole team gets them. If you use both `~/.claude/skills/` and `~/.agents/skills/`, mirror repo-authored skills to both so sessions stay consistent.

## Available Skills

| Skill | Description |
|-------|-------------|
| [git-visual-commits](skills/git-visual-commits/SKILL.md) | AI-driven git commit workflow with emoji (gitmoji-first), conventional prefixes, and three identity modes: bot-attributed (`git bot commit`), human-attributed (`git commit`), and collaborative (`git our commit` — agent analyzes authorship, human picks attribution). Includes commit body by default (opt out with `no-body`), semantic intent splitting, and auto-approval mode (`yolo` / `auto`). The agent does all the work either way. Stack-agnostic. |
| [git-keep-a-changelog](skills/git-keep-a-changelog/SKILL.md) | Git-aware Keep a Changelog companion that creates or updates `CHANGELOG.md` from the current branch by default. Reads full commit subjects and bodies plus the net diff, infers a release heading from a branch version hint like `v0.3.0/...` when available, creates a compliant changelog if the file does not exist yet, writes a required SemVer-aware release highlight, preserves natural prose wrapping, and curates `Added` / `Changed` / `Fixed` style sections instead of dumping raw commit logs. |
| [git-visual-squash-summary](skills/git-visual-squash-summary/SKILL.md) | Non-mutating grouped-summary companion to `git-visual-commits`. Turns noisy commit stacks into a curated set of compact summary lines for PR or squash contexts, preserving technical identifiers, merging overlap, dropping low-signal noise, highlighting distinct meaningful efforts, and avoiding changelog-style wording or unsupported claims. |
| [dotnet-new-lib-slnx](skills/dotnet-new-lib-slnx/SKILL.md) | Scaffold a new .NET NuGet library solution following codebeltnet engineering conventions. Dynamic defaults for TFM/repository metadata, latest-stable NuGet package resolution, tuning projects plus a tooling-based benchmark runner, TFM-aware test environments, strong-name signing, NuGet packaging, DocFX documentation, CI/CD pipeline, and code quality tooling. |
| [dotnet-new-app-slnx](skills/dotnet-new-app-slnx/SKILL.md) | Scaffold a new .NET standalone application solution following codebeltnet engineering conventions. Supports Console, Web, and Worker host families with Startup or Minimal hosting patterns; Web expands into Empty Web, Web API, MVC, or Web App / Razor, plus functional tests and a simplified CI pipeline. |
| [trunk-first-repo](skills/trunk-first-repo/SKILL.md) | Initialize a git repository following [scaled trunk-based development](https://trunkbaseddevelopment.com/#scaled-trunk-based-development). Seeds an empty `main` branch and creates a versioned feature branch (`v0.1.0/init`), enforcing a PR-first workflow where content only reaches main through peer-reviewed pull requests. |
| [dotnet-strong-name-signing](skills/dotnet-strong-name-signing/SKILL.md) | Generate a strong name key (`.snk`) file for signing .NET assemblies using pure .NET cryptography — no Visual Studio Developer PowerShell or `sn.exe` required. Works in any terminal. Defaults to 1024-bit RSA (matching `sn.exe`), with 2048 and 4096 available as options. |

### Copyable Install Commands

If your Markdown viewer supports code-block copy buttons, each command below should be directly copyable.

`git-visual-commits`

```bash
npx skills add https://github.com/codebeltnet/agentic --skill git-visual-commits
```

`git-keep-a-changelog`

```bash
npx skills add https://github.com/codebeltnet/agentic --skill git-keep-a-changelog
```

`git-visual-squash-summary`

```bash
npx skills add https://github.com/codebeltnet/agentic --skill git-visual-squash-summary
```

`dotnet-new-lib-slnx`

```bash
npx skills add https://github.com/codebeltnet/agentic --skill dotnet-new-lib-slnx
```

`dotnet-new-app-slnx`

```bash
npx skills add https://github.com/codebeltnet/agentic --skill dotnet-new-app-slnx
```

`trunk-first-repo`

```bash
npx skills add https://github.com/codebeltnet/agentic --skill trunk-first-repo
```

`dotnet-strong-name-signing`

```bash
npx skills add https://github.com/codebeltnet/agentic --skill dotnet-strong-name-signing
```

### Why git-visual-commits?

Commit messages are the most-read documentation in any codebase — yet they're usually an afterthought. "fix stuff", "wip", "address PR feedback" tells you nothing six months later. Writing good commits takes discipline, and when you're in flow, it's the first thing that slips.

**git-visual-commits** handles the entire commit workflow— staging, diffing, crafting the message, choosing the right emoji — so every commit is consistent and meaningful without breaking your flow. Whether the agent authors the commit (`git bot commit`), you do (`git commit`), or you worked on it together (`git our commit`), the quality is the same.

- **Gitmoji-first** — visual commit categories that are scannable at a glance
- **Conventional prefixes** — `init`, `content`, `style`, `fix`, `refactor`, and `docs` as fallback when gitmoji isn't available
- **Three identity modes** — bot, human, or collaborative — the agent does the work either way, you choose who gets credit
- **Identity lock stays honest** — `git bot commit` means bot attribution, not just "AI did the work", and the flow now verifies the resulting author after commit
- **Auto-approval** — say "yolo" or "auto" to skip the review gate when you trust the agent's judgment
- **Yolo skips confirmation, not discipline** — auto-approval still requires semantic grouping, mixed-scope checks, and a visible commit plan summary before committing
- **Commit body by default** — every commit explains *why*, not just *what* — opt out with "tmi" or "no-body"
- **Commit bodies are verified after write** — the workflow now checks the stored commit body so literal escape sequences like `\n` do not leak into history
- **Short bodies stay readable** — the workflow no longer hard-wraps short commit bodies at 72 characters and instead prefers normal prose with sentence-level judgment
- **Repo capability additions stay explicit** — adding a brand-new skill is grouped separately from refactoring an existing skill to support it
- **Shared wording rules stay in lockstep** — the duplicated `commit-language.md` reference is kept byte-for-byte identical across both git-visual skills and checked locally plus in CI
- **Semantic intent splitting** — groups commits by rationale, not just file type — config and test logic are always separate
- **Umbrella commits are rejected** — mixed diffs spanning skill instructions, templates, validators, and repo docs must be split into separate commits instead of bundled into one blob
- **Stack-agnostic** — works with any language, framework, or project type
- **Squash-and-merge friendly** — structured commits make PR squash summaries read like a changelog

### Why git-visual-squash-summary?

Sometimes the history is already written and the only thing you need is
the final grouped summary. A long branch with fixups, rename follow-ups,
review nits, and repeated attempts often contains a few real change
themes buried inside a messy chronological story. That is where
**git-visual-squash-summary** fits: it reads the real history and diff,
then compresses them into a small set of truthful grouped lines.

- **Same visual language** — reuses the same prefix and emoji rules as `git-visual-commits`
- **Grouped-lines only** — returns compact grouped lines only, not a title or body
- **Non-mutating by design** — drafts the wording only and does not touch git state
- **Distinct efforts stay distinct** — preserves meaningful change groups instead of forcing one umbrella line
- **Intent over chronology** — collapses noisy commit stacks into the retained grouped effort
- **Low-signal noise gets dropped** — typo-only and trivial fixup churn do not deserve their own lines
- **Identifier-safe wording** — preserves technical names, paths, flags, and types where possible
- **Readable in GitHub and terminals** — optimized for compact PR and squash-summary views
- **Strict 72-char lines** — every summary line stays compact and scannable
- **Not a changelog** — avoids release-note phrasing and commit-subject dumps
- **No unsupported claims** — summarizes only what the inspected diff can justify

### Why git-keep-a-changelog?

Writing `CHANGELOG.md` well is harder than it looks. Raw commit subjects are too noisy, PR titles often miss migration context, and release notes get much better when the writer actually reads the commit bodies and understands the net diff. That is where **git-keep-a-changelog** fits: it turns the current branch into a curated Keep a Changelog entry and creates or updates the file directly for review.

- **Keep a Changelog first** — writes `Added`, `Changed`, `Deprecated`, `Removed`, `Fixed`, and `Security` sections in the expected style
- **Full-commit context** — reads complete commit messages and the net diff before writing
- **Version-aware by branch** — uses a branch prefix like `v0.3.0/...` as the release heading hint when present
- **SemVer-aware highlight** — always writes a short release TL;DR that explicitly says `major`, `minor`, or `patch`
- **Creates the file when needed** — seeds a compliant `CHANGELOG.md` if the repo does not have one yet
- **Natural prose** — preserves human-readable line breaks instead of hard-wrapping changelog text to narrow columns
- **Direct file edit** — creates or updates `CHANGELOG.md` directly, then stops for human review
- **Compare-link aware** — can update bottom-of-file compare links when a concrete release heading is added
- **Not a commit dump** — curates the release story instead of copying git log output into Markdown

### Why dotnet-new-lib-slnx and dotnet-new-app-slnx?

Starting a new .NET solution "from scratch" usually means copying from your last project, deleting half of it, and spending an hour wiring up CI, MSBuild props, versioning, and code quality tooling. Every new repo drifts slightly from the last one. Six months later, no two solutions look the same.

**dotnet-new-lib-slnx** and **dotnet-new-app-slnx** encode the full codebeltnet convention into repeatable scaffolds — from `Directory.Build.props` to CI pipelines to DocFX. Each skill is focused on its domain: libraries get multi-target frameworks, signing, and NuGet packaging; apps get host family selection, a conditional web-variant choice when needed, hosting patterns, and functional tests.

> [!NOTE]
> These scaffolds are not speculative starter kits. They capture conventions already exercised across Codebelt repositories and turn them into a repeatable methodology for new solutions.

- **Convention over configuration** — opinionated defaults that match real production setups
- **Focused skills** — library and app concerns are fully separated, no variant confusion
- **Lower cognitive load** — the library scaffold defaults the main project name from the solution name, pre-fills the repository URL from the repo root folder name, and lets the package website reuse that value unless you override it
- **Default-friendly prompts** — when a scaffold form already shows a recommended value such as `root_namespace = solution_name`, leaving the field blank should accept that default instead of sending the agent into a follow-up loop
- **Structured-input fallback stays consistent** — when a host does not render native form widgets, the scaffold skills now fall back to a deterministic one-field-at-a-time plain-text format instead of improvising the UX
- **Explicit host prompts stay on rails** — if you already asked for `Console`, `Worker`, `Web API`, `MVC`, or `Razor`, the scaffold flow should preselect that host choice and move straight to the remaining fields instead of asking you to restate it
- **Modern TFM choices** — the .NET scaffold skills compute active target framework quick-picks from the official .NET releases index, offering every supported non-preview LTS and STS channel plus an expanded multi-target preset where applicable
- **Latest stable dependencies** — `Directory.Packages.props` is generated from NuGet.org package metadata at scaffold time instead of carrying stale hardcoded NuGet package versions
- **Central package management stays authoritative** — app scaffolds keep NuGet versions in `Directory.Packages.props` and do not “repair” restore issues by inlining versions into generated project files
- **Deterministic package resolution beats memory** — the app scaffold now ships a NuGet resolver script so agents can fetch current per-package versions instead of guessing from stale remembered examples
- **Resolver script is non-interactive by default** — the app package resolver now defaults to the skill’s own `Directory.Packages.props`, so agents do not have to remember an extra template path argument during normal scaffolds
- **Library-only package set** — the library scaffold no longer carries leftover app/bootstrapper package placeholders that do not belong in class library templates
- **Structured benchmarking** — the scaffold now keeps actual benchmark projects under `tuning/`, generates a solution-level `tooling/benchmark-runner` host with BenchmarkDotNet jobs derived from the selected TFMs, targets the runner itself at the highest selected supported runtime, and writes output to `reports/`
- **Hidden shared assets preserved** — recursive scaffold copy includes dot-folders such as `.bot/`, so the generated repo gets the real `.bot/README.md` template instead of an improvised placeholder
- **UTF-8 by default** — the scaffold explicitly tells generating agents to preserve UTF-8 when copying and writing text templates, matching the generated `.editorconfig`
- **Explicit encoding guidance** — rewritten templates now call for byte-preserving copy when possible, explicit UTF-8 APIs when not, and a quick mojibake sanity check before scaffolding is considered done
- **TFM-aware test runners** — generated `testenvironments.json` Docker entries now follow the selected target frameworks instead of using a hardcoded runner tag
- **Shared test environments are required** — `testenvironments.json` is part of the app scaffold contract and should never be silently skipped
- **Source-backed runner tags** — Docker runner tags can be validated against the `codebeltnet/ubuntu-testrunner` Docker Hub tags feed instead of being assumed
- **Root-aware Dependabot** — the generated repo watches `/` for NuGet updates so central package management keeps moving after day one
- **App scaffolds resolve package versions per dependency** — generated `Directory.Packages.props` files use package-specific placeholders that are resolved from NuGet.org instead of leaking a generic `{LATEST}` token
- **ASP.NET package versions stay TFM-aligned** — `net9.0` app scaffolds resolve framework-aligned ASP.NET packages to the latest stable `9.x` line instead of accidentally pulling incompatible `10.x` packages
- **Web-family scaffolds stay explicit** — generic `Web` requests expand into `Empty Web`, `Web API`, `MVC`, or `Web App / Razor`, with variant-specific project suffixes like `.Web`, `.Api`, `.Mvc`, and `.WebApp`
- **Current-folder scaffolding** — both .NET scaffold skills generate directly into the folder you are already in unless you explicitly ask for a nested solution folder
- **PascalCase solution filenames** — generated `.slnx` files keep the user-facing solution/product name instead of silently lowercasing it
- **Required artifacts stay required** — the app scaffold treats `.slnx`, `testenvironments.json`, `Directory.Packages.props`, and the per-host `src/` + `test/` projects as non-optional outputs, even for single-host scaffolds
- **Shared scaffold assets are copied as a complete set** — app scaffolds preserve the full `assets/shared/` inventory, including dotfiles, `.github/`, and `.bot/`, instead of cherry-picking only the files that seem important
- **Target framework stays centralized** — generated app and test projects inherit `TargetFramework` from the root `Directory.Build.props` instead of patching individual `.csproj` files
- **MinVer stays wired in** — .NET scaffolds preserve MinVer-based semantic versioning from git tags as a repo-level invariant
- **MinVer bootstrap warnings are expected** — in non-git or untagged folders, an initial `0.0.0-alpha.0` style version is expected until the repo is initialized and tagged
- **Worker scaffolds build immediately** — Worker apps now include a starter `Worker.cs` template so the generated project compiles before custom logic is added
- **Bootstrapper imports are explicit** — app templates now include the required `Codebelt.Bootstrapper.*` namespace imports instead of relying on missing implicit usings
- **Clear NuGet metadata mapping** — prompts and placeholders line up with package metadata such as `PackageProjectUrl`
- **Solo-friendly defaults** — company/publisher metadata can default straight from the author name for individual maintainers
- **Complete from the start** — CI pipeline, code quality, test infrastructure, and governance docs on day one
- **Template-driven** — real files with placeholders in `assets/`, not generated strings, so you can inspect and evolve them

### Why dotnet-strong-name-signing?

Generating a `.snk` file traditionally requires `sn.exe`, which is only available in the Visual Studio Developer PowerShell — a common pain point for developers using VS Code, Rider, or plain terminals. This skill uses `RSACryptoServiceProvider` from the .NET runtime itself, so it works in **any PowerShell or terminal** without special tooling.

- **No `sn.exe` dependency** — uses pure .NET crypto available in any PowerShell session
- **Matches `sn.exe` defaults** — 1024-bit RSA by default, with 2048 and 4096 as options
- **Cross-platform** — works on Windows, macOS, and Linux with PowerShell 7+ or .NET runtime
- **Identity, not security** — [Microsoft's guidance](https://github.com/dotnet/runtime/blob/main/docs/project/strong-name-signing.md) is clear: strong names are about assembly identity, not cryptographic security

### Why trunk-first?

Most repositories start with `git init` followed by committing everything directly to `main`. This works — until someone force-pushes to main, or a half-finished feature lands without review. By the time you add branch protection, the history is already messy.

**trunk-first-repo** flips this: main starts empty and stays clean from the very first commit. Every piece of content enters through a pull request. This gives you:

- **Review from day one** — no "we'll add branch protection later" that never happens
- **Clean, meaningful history** — main tells the story of reviewed, approved changes
- **Version-aware branches** — `v0.0.1/spike-auth` vs `v1.0.0/release-prep` signals project maturity at a glance
- **Zero-friction setup** — one skill invocation, not a 10-step checklist

## Repository structure

```
skills/
  <skill-name>/
    SKILL.md          # Required — the skill definition (loaded by the AI)
    FORMS.md          # Optional — structured form fields for parameter collection
    assets/           # Optional — file templates, fonts, icons used in output
    scripts/          # Optional — executable code (Python, Bash, etc.)
    references/       # Optional — detailed reference docs
    evals/            # Required for repo-managed skills — per-skill evals/evals.json
```

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) for how to add a new skill or improve an existing one.

## License

[MIT](LICENSE)
