# Agentic Skills

![Skills Applied](assets/hero.jpg)

A curated collection of [skills](https://skills.sh) — reusable instruction sets that teach AI agents how to follow specific workflows, conventions, and standards. Designed to work with any agent that supports the skills ecosystem: GitHub Copilot, Claude Code, Cursor, Codex, OpenCode, and [many more](https://skills.sh).

## What are skills?

Skills are Markdown files that an AI agent reads before responding. When a skill is active, the agent follows the rules it contains — consistently, across any tool or model that supports them. They're a lightweight way to encode your team's conventions once and apply them everywhere.

One repo-wide convention matters especially for scaffolding skills: prefer dynamic defaults over hardcoded values whenever a reliable source exists. Derive time-sensitive or environment-sensitive values from git metadata, repo state, or official machine-readable feeds so skills age gracefully instead of drifting.

Another repo rule is intentionally strict: every repo-managed skill ships with its own `evals/evals.json`, and those evals are run per skill from a temp workspace instead of from inside this repository.

Another part of that workflow is now mandatory too: when a repo-managed skill is created or modified, the author must run the full per-skill test from a temp workspace. Full test means both `with_skill` and `without_skill` comparison executions, grading both runs, aggregating the results into `benchmark.json`, and opening `eval-viewer/generate_review.py` from the installed Anthropic `skill-creator` copy, typically under `~/.agents/skills/skill-creator/` or `~/.claude/skills/skill-creator/`, so a human can review both the `Outputs` and `Benchmark` views before sign-off. For new skills the baseline is `without_skill`; for existing skills it can be `without_skill` or the previous/original skill version, matching the `skill-creator` benchmark flow. A reasoning-only smoke test does not count. When the available runner supports sub-agents or equivalent background tasks, the measured benchmark should fan out paired executor runs in parallel and parallelize independent grading work too, rather than running evals serially by habit.

One more consistency rule matters for form-driven skills: native input fields are treated as a host feature, not something a model can rely on. Skills in this repo must stay usable with or without UI widgets, and must fall back to the same deterministic one-field-at-a-time flow when the host only supports plain chat.

Validation follows the same philosophy: run `scripts/validate-skill-templates.ps1` locally for the fast feedback loop, and let GitHub Actions rerun that same script on pull requests as the safety net. That validator also checks skill frontmatter metadata such as per-skill `evals/evals.json` files, optional eval fixture paths declared through `files`, and the 1024-character YAML description limit; it does not replace the paired benchmark review workflow.

## Install a skill

Install any skill directly from this repository with a single command:

```bash
npx skills add https://github.com/codebeltnet/agentic --skill <skill-name>
```

If an install path ever drops required files or dot-prefixed paths from a skill tree, treat that as an incomplete copy, verify the upstream repository contents, and manually restore the missing entries directly from the repository source tree before using the skill.

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
npx skills add https://github.com/codebeltnet/agentic --skill git-nuget-release-notes
npx skills add https://github.com/codebeltnet/agentic --skill git-nuget-readme
npx skills add https://github.com/codebeltnet/agentic --skill git-visual-squash-summary
npx skills add https://github.com/codebeltnet/agentic --skill skill-creator-agnostic
npx skills add https://github.com/codebeltnet/agentic --skill markdown-illustrator
npx skills add https://github.com/codebeltnet/agentic --skill git-story-teller
npx skills add https://github.com/codebeltnet/agentic --skill trunk-first-repo
npx skills add https://github.com/codebeltnet/agentic --skill dotnet-strong-name-signing
npx skills add https://github.com/codebeltnet/agentic --skill dotnet-new-app-slnx
npx skills add https://github.com/codebeltnet/agentic --skill dotnet-new-lib-slnx
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
| [git-visual-commits](skills/git-visual-commits/SKILL.md) | AI-driven git commit workflow with emoji-first subjects (gitmoji-first), optional conventional prefixes only on explicit request, and three identity modes: bot-attributed (`git bot commit`), human-attributed (`git commit`), and collaborative (`git our commit` — agent analyzes authorship, human picks attribution). Includes commit body by default (opt out with `no-body`), semantic intent splitting, bundled `commit-language.md` validation from the skill resource path rather than repo-root guesses, clarification-before-correction safety, and auto-approval mode (`yolo` / `auto`). The agent does all the work either way. Stack-agnostic. |
| [git-keep-a-changelog](skills/git-keep-a-changelog/SKILL.md) | Git-aware Keep a Changelog companion that creates or updates `CHANGELOG.md` from the current branch by default. Reads full commit subjects and bodies plus the net diff, infers a release heading from a branch version hint like `v0.3.0/...` when available, must ask a mandatory `Yes / No / Custom` confirmation question before including pending staged, unstaged, or untracked worktree changes in a concrete release draft, now backed by `FORMS.md` so compatible hosts can render a native choice UI while preserving the same text fallback, creates a compliant changelog if the file does not exist yet, writes a required SemVer-aware release highlight, maintains or inserts the Keep a Changelog compare-link footer on both create and update paths, preserves natural prose wrapping, and curates `Added` / `Changed` / `Fixed` style sections instead of dumping raw commit logs. |
| [git-nuget-release-notes](skills/git-nuget-release-notes/SKILL.md) | Git-aware NuGet release-notes companion for .NET repos that keep cumulative `.nuget/{ProjectName}/PackageReleaseNotes.txt` files. Discovers packable `src/` projects, resolves concrete package version and availability, creates missing files when needed, and writes per-package `ALM` / `Breaking Changes` / `New Features` / `Improvements` / `Bug Fixes` style notes from full commit context plus the net diff instead of dumping commit subjects. |
| [git-nuget-readme](skills/git-nuget-readme/SKILL.md) | Git-aware NuGet README companion for .NET repos that advertise a package from `src/`. Resolves the real packable project the README should sell, combines git history with actual package metadata, source capabilities, and relevant tests when feasible, preserves honest badge/docs/contributing sections, and writes a forthcoming, adoption-friendly `README.md` with repo-derived branding, clear value, install, framework-support, and quick-start guidance. |
| [git-visual-squash-summary](skills/git-visual-squash-summary/SKILL.md) | Non-mutating grouped-summary companion to `git-visual-commits`. Turns the full current feature branch into a curated set of compact summary lines for PR or squash-and-merge contexts by default, preserving technical identifiers, merging overlap, dropping low-signal noise, highlighting distinct meaningful efforts, and avoiding changelog-style wording, unsupported claims, needless commit-range questions, or commit-selection UI for ordinary branch-level squash requests. |
| [skill-creator-agnostic](skills/skill-creator-agnostic/SKILL.md) | Runner-agnostic overlay for Anthropic `skill-creator`. Adds repo and environment guardrails for skill authoring and benchmarking: temp-workspace isolation, `iteration-N/eval-name/{config}/run-N/` benchmark layout, valid `grading.json` summaries, generated `benchmark.json`, honest `MEASURED` vs `SIMULATED` labeling, and sync/README discipline for repo-managed skills. |
| [markdown-illustrator](skills/markdown-illustrator/SKILL.md) | Reads a markdown file and answers directly in chat with one document-wide Visual Brief plus one compiled prompt. Infers a compact visual strategy by default, keeps follow-up questions near zero, and only branches when the user explicitly asks for added specificity. |
| [git-story-teller](skills/git-story-teller/SKILL.md) | Turns any full repository URL into a deterministic story workspace using the bundled .NET file-based runner `scripts/story.cs`. Requires explicit `--repo-url` and `--output-root`, derives `{repo-id}`, fixes `result/`, packs context with local Repomix when available, the public Repomix web API for GitHub URLs when Node/npm is unavailable, or a lower-fidelity built-in .NET fallback as the last resort, writes full contexts plus public API summaries, engineering signals, context indexes, and ordered chunk files, then guides the agent to fully read the current phase's required context before writing target stories and `result/Index.md`, optionally using one subagent per independent target context and using completed package stories as the primary source for the package-facing `## Package selection` overview. |
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

`git-nuget-release-notes`

```bash
npx skills add https://github.com/codebeltnet/agentic --skill git-nuget-release-notes
```

`git-nuget-readme`

```bash
npx skills add https://github.com/codebeltnet/agentic --skill git-nuget-readme
```

`git-visual-squash-summary`

```bash
npx skills add https://github.com/codebeltnet/agentic --skill git-visual-squash-summary
```

`skill-creator-agnostic`

```bash
npx skills add https://github.com/codebeltnet/agentic --skill skill-creator-agnostic
```

`markdown-illustrator`

```bash
npx skills add https://github.com/codebeltnet/agentic --skill markdown-illustrator
```

`git-story-teller`

```bash
npx skills add https://github.com/codebeltnet/agentic --skill git-story-teller
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
- **Emoji-first by default** — the normal subject shape is `<emoji> <description>`, not `<emoji> <prefix>: ...`
- **Conventional-prefix combo is opt-in** — `init`, `content`, `style`, `fix`, `refactor`, and `docs` are available only when you explicitly ask to combine emoji with conventional-commit prefixes
- **Three identity modes** — bot, human, or collaborative — the agent does the work either way, you choose who gets credit
- **Identity lock stays honest** — `git bot commit` means bot attribution, not just "AI did the work", and the flow now verifies the resulting author after commit
- **Direct git execution for bot identity** — identity-sensitive commit paths should use direct shell/terminal git commands, not wrappers that may bypass aliases
- **Clarifies before correcting** — vague feedback like "4 is wrong" triggers a short question, not a guessed revert or regrouping
- **Evidence-backed explanations** — emoji and grouping justifications stay tied to references actually inspected in the session
- **Reference-validated emoji choices** — the workflow reads the bundled `commit-language.md` skill resource before proposing commit subjects and does not treat a missing repo-root `references/` folder as the same thing as a missing skill reference
- **Community health uses `💬`** — changelogs and repo-health / release-status communication are treated as human-facing messaging, not generic `📝` or `📚` docs by default
- **Skill refactors map to refactor intent** — reorganizing an existing skill's wording or eval contract should land on `♻️`, not a guessed new-feature or config emoji
- **Auto-approval** — say "yolo" or "auto" to skip the review gate when you trust the agent's judgment
- **No `yolo`, no commit** — without `yolo` / `auto` or an already-enabled auto mode, the workflow must stop at the plan and wait for approval before it commits anything
- **Yolo skips confirmation, not discipline** — auto-approval still requires semantic grouping, mixed-scope checks, and a visible commit plan summary before committing
- **Full worktree by default** — plain `git bot commit yolo` means "commit everything currently in git status and group it correctly", not "guess a narrower slice"
- **Commit body by default** — every commit explains *why*, not just *what* — opt out with "tmi" or "no-body"
- **Commit bodies are verified after write** — the workflow now checks the stored commit body so literal escape sequences like `\n` do not leak into history
- **Short bodies stay readable** — the workflow no longer hard-wraps short commit bodies at 72 characters, treats mid-sentence wrapping as a verification failure, and repairs the commit instead of leaving noisy prose in history
- **Repo capability additions stay explicit** — adding a brand-new skill is grouped separately from refactoring an existing skill to support it
- **Shared wording rules stay in lockstep** — the duplicated `commit-language.md` reference is kept byte-for-byte identical across both git-visual skills and checked locally plus in CI
- **Semantic intent splitting** — groups commits by rationale, not just file type — config and test logic are always separate
- **Same-round edits are not one commit by default** — temporal proximity never outranks semantic intent when grouping changes
- **Release-adjacent work still splits cleanly** — dependency baselines, package metadata, community health docs, doc publishing fixes, and CI automation can belong in separate commits even when they land together
- **Package release notes are `📦` work** — `.nuget/*/PackageReleaseNotes.txt` belongs with package/publish metadata, not with `💬` community-health communication
- **Tool-path failures fail fast** — a wrong-author first attempt means switch execution path immediately instead of retrying the same broken wrapper
- **Recovery stays conservative** — prefer inspecting git state and stashing before broad restore/reset commands when commit repair goes sideways
- **Umbrella commits are rejected** — mixed diffs spanning skill instructions, templates, validators, and repo docs must be split into separate commits instead of bundled into one blob
- **Stack-agnostic** — works with any language, framework, or project type
- **Squash-and-merge friendly** — structured commits make PR squash summaries read like a changelog

### Why git-visual-squash-summary?

Sometimes the history is already written and the only thing you need is the final grouped summary. A long branch with fixups, rename follow-ups, review nits, and repeated attempts often contains a few real change themes buried inside a messy chronological story. That is where **git-visual-squash-summary** fits: it reads the real history and diff, then compresses them into a small set of truthful grouped lines.

- **Same visual language** — reuses the same emoji-first wording rules as `git-visual-commits`
- **Grouped-lines only** — returns compact grouped lines only, not a title or body
- **Non-mutating by design** — drafts the wording only and does not touch git state
- **Whole-branch by default** — for squash-and-merge requests, uses the full current feature branch from merge-base to `HEAD` instead of asking which branch commits to include
- **Bare invocation means summarize now** — calling `git-visual-squash-summary` directly should resolve the current branch scope automatically and return the grouped lines, not a "what do you want me to summarize?" question
- **No commit-picker UX** — ordinary branch-level squash requests do not become commit-selection questions or widgets; the skill resolves the branch scope and writes the summary
- **Distinct efforts stay distinct** — preserves meaningful change groups instead of forcing one umbrella line
- **Dependency updates stay explicit** — package/version baseline changes keep their own dependency-focused line instead of getting absorbed into generic build-system or refactor wording
- **Intent over chronology** — collapses noisy commit stacks into the retained grouped effort
- **Low-signal noise gets dropped** — typo-only and trivial fixup churn do not deserve their own lines
- **Late release-prep commits stay in scope** — changelog, version-bump, and release-finalization follow-ups are treated as part of the branch by default and then merged or dropped during semantic collapsing
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
- **Mandatory pending-worktree gate** — when a concrete release has uncommitted changes, the skill must ask a short `Yes / No / Custom` confirmation question before folding them into the changelog draft, with a `FORMS.md` definition that compatible hosts can render as native choices
- **SemVer-aware highlight** — always writes a short release TL;DR that explicitly says `major`, `minor`, or `patch`
- **Creates the file when needed** — seeds a compliant `CHANGELOG.md` if the repo does not have one yet
- **Natural prose** — preserves human-readable line breaks without any fixed-width wrapping target
- **Predictable bullet punctuation** — bullets end with `,` and the last bullet in each section ends with `.`
- **Direct file edit** — creates or updates `CHANGELOG.md` directly, then stops for human review
- **Compare-link aware** — can update bottom-of-file compare links when a concrete release heading is added
- **Not a commit dump** — curates the release story instead of copying git log output into Markdown

### Why git-nuget-release-notes?

Repo-wide changelogs are useful, but NuGet packages often need package-scoped release notes that match the package actually being published. In codebelt-style repos, that means cumulative `.nuget/{ProjectName}/PackageReleaseNotes.txt` files with a very specific shape: concrete version and availability lines, `# ALM` first, and only the sections that the package really earned.

**git-nuget-release-notes** reads the actual git history and net diff per packable `src/` project, resolves the package version and target framework availability, then updates the package-note files directly for review.

- **Per-package, not repo-wide** — writes one truthful release block per publishable assembly/package
- **Concrete package metadata** — resolves `Version:` and `Availability:` from the branch/project instead of inventing placeholders
- **Current codebelt format** — follows the established `ALM`, `Breaking Changes`, `New Features`, `Improvements`, `Bug Fixes`, and optional `References` blueprint
- **Missing-file aware** — can create `.nuget/{ProjectName}/PackageReleaseNotes.txt` when a packable project should be represented
- **History-aware** — preserves cumulative newest-first package history instead of overwriting older entries
- **Not a commit dump** — uses full commit bodies plus the net diff and avoids line-by-line subject replay

### Why git-nuget-readme?

Choosing a NuGet package often happens fast: a developer lands on the README, scans the first screen, checks whether the package fits the problem, and looks for install guidance, supported frameworks, docs, and a quick example. If those signals are vague or buried, the package loses the moment even when the code is good.

**git-nuget-readme** uses the actual git history, project metadata, and source-level capabilities of the advertised package to refresh the README into something that is both truthful and easier to adopt.

- **Package-first README focus** — centers the README on the real packable project the repo is advertising
- **Devex-led structure** — pulls value proposition, installation, framework support, docs, and quick-start guidance closer to the top
- **Grounded sales copy** — improves the package pitch without inventing features, benchmarks, badges, or docs URLs
- **Source-backed examples** — prefers real namespaces, package IDs, capability areas, and test-backed usage hints from the codebase
- **Repo-derived identity** — uses the current repo's own naming and branding conventions instead of importing a `by <brand>` pattern from another package family
- **Preserve the good parts** — keeps accurate badges, docs links, contributing guidance, and license sections when they are already working
- **Not a changelog in disguise** — uses git history for context but writes adoption-oriented README copy instead of replaying commit subjects

### Why skill-creator-agnostic?

Anthropic's `skill-creator` is an excellent base workflow, but the day-to-day friction usually comes from the environment around it: different runners, Windows/PowerShell encoding traps, benchmark layout mistakes, and the temptation to present a synthetic pipeline check as if it were a measured model benchmark.

**skill-creator-agnostic** keeps the upstream workflow intact and adds the parts teams actually trip over when they want the same skill to hold up across Codex, GitHub Copilot, Opus, and similar agents.

- **Overlay, not fork** — treats Anthropic `skill-creator` as the base and layers repo/runtime guardrails on top
- **Runner-agnostic by design** — chooses from available execution capability instead of assuming one vendor CLI
- **Benchmark-contract aware** — enforces `iteration-N/eval-name/{config}/run-N/`, valid `grading.json.summary`, and generated `benchmark.json`
- **Tool-path explicit** — points authors to the installed Anthropic `skill-creator` copy that provides `scripts/aggregate_benchmark.py` and `eval-viewer/generate_review.py`
- **Honest benchmark modes** — keeps `MEASURED` and `SIMULATED` runs clearly separated so pipeline validation never masquerades as model quality
- **PowerShell-safe** — calls out UTF-8 no BOM, `PYTHONUTF8`, stable counting, provider-path normalization, prompt-passing pitfalls, and other Windows-specific benchmark traps
- **Codex-friendly benchmarking** — treats Codex CLI as a valid real runner when present, preserves `MEASURED` parity honestly, uses raw event output as fallback evidence when convenience files are missing, and prefers parallel paired runs when the runner supports sub-agents
- **Repo-managed discipline** — keeps per-skill evals, local-install sync, and README updates in scope for first-party skills

### Why git-story-teller?

Repository story generation works best when deterministic context gathering is separated from AI-authored prose. **git-story-teller** owns that split: its bundled .NET file-based runner creates the manifest, instructions, full context files, public API summaries, engineering signal maps, context indexes, and ordered chunk files; the agent writes the target stories and overview.

- **Bundled C# runner** - ships `scripts/story.cs`, run with `dotnet run --file`, so the skill is self-contained without a full project file
- **Repomix-first packing** - uses `npx repomix` for the canonical XML context, ignore handling, token metadata, and security checks when Node/npm access is available
- **Web API fallback** - if local Repomix cannot start and the input is a public GitHub HTTPS URL, posts the same pack request shape used by `https://repomix.com/` to the public Repomix API
- **Local fallback path** - if both Repomix paths are unavailable, uses a simple built-in .NET text packer so public/non-sensitive story work can still proceed
- **Repository-generic input** - starts from a full repository URL and an explicit output root instead of assuming an owner/slug convention
- **KISS contract** - only `--repo-url` and `--output-root` are inputs; `{repo-id}` is derived and `result/` is fixed
- **Codebelt-flavored default** - recommends `.bot/stories` when the active workspace already contains a `.bot` folder
- **Tool output is authoritative** - reads `manifest.json`, `instructions.md`, and one target context at a time instead of reconstructing scope from memory
- **Public API first** - adds a generated public API summary so agents can orient around consumer-facing types, inheritance chains, and likely key members before reading the raw source
- **Engineering signal map** - highlights source-backed places to inspect for validation guards, lifecycle callbacks, factories, hosting styles, and test evidence so stories can explain the engineering decisions instead of listing APIs mechanically
- **Low-signal filtering** - removes `GlobalSuppressions.cs` from packed context while keeping internals available when they explain public behavior
- **Chunked context navigation** - emits `*.context.index.md` and ordered `*.context.chunks/*.md` files beside each full context so agents can read large evidence sets even when a tool caps single-file output
- **Complete-read grounding** - treats capped or truncated context output as an unfinished read, requiring the agent to use the index and every ordered chunk, or range reads for older workspaces, until the current target context, overview context, and required target stories have been fully inspected
- **Subagent-friendly targets** - when the runtime supports delegation, assigns at most one independent target context to each subagent so large contexts do not compete for the same prompt budget, while the main agent orchestrates, gathers caveats, and authors the final overview
- **Target-first workflow** - writes `result/{TargetName}.md` files before synthesizing `result/Index.md`
- **Story-sourced overview** - requires the overview phase to open the completed target story files as the primary source instead of relying on `overview.context.md` alone
- **Package-facing overview** - requires `result/Index.md` to use `## Package selection` for the reader-facing selection section
- **Phase-scoped reading** - processes target contexts separately and uses completed target stories for the overview without letting token limits justify skipped evidence
- **Grounded prose** - forbids invented APIs, relationships, examples, broad marketing claims, and unmeasured frequency claims such as "most common mistake" unless the generated context supports them with concrete evidence
- **Publication stays explicit** - leaves staged files in `{output-root}/{repo-id}/result` unless the user asks to sync them into a consuming site
### Why markdown-illustrator?

Markdown-heavy documents often need one image that sells the whole idea fast: a conference opener, article cover, pitch-slide hero, or visual hook that makes the audience want to keep reading. The problem with many prompt workflows is that they branch immediately into model menus, theme toggles, and style comparisons before the document has even been understood.

**markdown-illustrator** keeps the job focused. It reads the markdown, distills the whole document into a visualization-first Visual Brief, silently infers a compact visual strategy from the request, and turns that shared brief into one compiled prompt returned directly in chat. If you explicitly ask for a named model or a narrower aesthetic, it honors that request without dragging you through a selection workflow.

- **Visual-Brief first** — distills the document into subject, narrative, visual opportunity, mood, and must-show elements before prompting
- **One shared Visual Brief, one committed result** — optimized for covers, keynote slides, and "capture the essence" illustration requests where decisiveness matters more than variants
- **Prompt-compiler behavior** — translates abstract meaning into concrete visual structure, readable composition, physical medium cues, and explicit failure-mode control
- **Infer, don't interrogate** — defaults to a strong non-interactive strategy instead of turning intent, treatment, abstraction, and label density into follow-up questions
- **Hero-first defaults** — when the request is underspecified, the skill defaults toward `hero + cinematic editorial + concept-led + minimal labels + 16:9 (or 3:2 when it composes better)` rather than a dry explainer graphic
- **Cross-diffuser by design** — prefers strong natural-language prompting over vendor-specific branching unless the user asks
- **Text-safe prompting** — steers away from dense embedded copy, fake words, and fragile readable text unless very short labels are truly necessary
- **Anti-repetition by default** — avoids repeated labels, bullets, steps, callouts, mirrored panels, and echoed document fragments so the image reads like one authoritative artifact rather than many near-duplicates
- **No selection detours** — skips file creation, model-family, style, theme, and scope menus so the workflow stays fast and focused
- **User steerable when needed** — the skill stays minimal, but users can still explicitly steer toward directions like `whiteboard`, `blackboard`, `isometric`, or `blueprint`
- **Board styles use color intentionally** — `whiteboard` and `blackboard` keep their authentic marker/chalk base, but the skill now biases toward selective colored accents for arrows, icons, checks, and highlights instead of leaving every emphasis mark monochrome

#### Inferred Defaults For markdown-illustrator

The skill should not ask the user to configure these unless the request is genuinely ambiguous in a way that affects correctness. It infers a compact strategy and proceeds.

- **Intent** — infer `hero`, `digest`, `diagram`, or `cover` from the user's phrasing; if there is no stronger signal, default to `hero`
- **Visual treatment** — preserve explicit styles such as `whiteboard`, `blackboard`, `scientific`, `hand-drawn`, `isometric`, or `minimal`; otherwise default to `cinematic editorial`
- **Abstraction level** — use `concept-led` for spectacle and interest-raising requests, `balanced` for explanatory or onboarding requests, and `literal` only when the user explicitly asks for strict fidelity
- **Label density** — default to `minimal`, move toward `none` for hero or infographic-first requests, and use `academic` only for scientific or textbook-style requests
- **Aspect ratio** — honor explicit ratios, otherwise default to a wide frame: prefer `16:9`, use `3:2` when the composition is more editorial or object-centered, and avoid square by default

#### Good Trigger Examples For markdown-illustrator

These phrasings reliably signal the skill's intent: a markdown file goes in, and one document-wide visual direction comes back.

- `Use markdown-illustrator on SKILL.md and return the Visual Brief plus one final prompt.`
- `Read roadmap.md and create one strong visual direction that captures the whole document.`
- `Create a visual digest for onboarding-notes.md.`
- `Turn launch-plan.md into a keynote opener image prompt.`
- `Use markdown-illustrator on systems.md and keep it blackboard style.`
- `Turn product-brief.md into a single Flux-ready hero-image prompt.`

#### Common Visual Directions For markdown-illustrator

These are reference directions for users, not built-in branches in the skill. If you want one of them, ask for it explicitly in the prompt.

`whiteboard`

- Pros: approachable, collaborative, strong for brainstorming, product planning, workshops, and messy human energy
- Cons: can feel too casual or cluttered for polished keynote or editorial uses
- Guidance: ask for this when the document is about ideation, strategy sessions, or product thinking; expect a mostly marker-based board with selective colored accents for emphasis marks instead of pure black-only linework

`blackboard`

- Pros: dramatic, intellectual, layered, great for systems thinking and technical storytelling
- Cons: can become visually noisy if the source material is already dense
- Guidance: ask for this when the document is about architecture, strategy, layered concepts, or technical explanation; expect a chalkboard base with restrained colored chalk accents for arrows, highlights, and key icons instead of all-white chalk marks

`isometric`

- Pros: excellent for platforms, ecosystems, infrastructure, and layered technical worlds
- Cons: weaker for abstract or emotional narratives that need symbolism more than structure
- Guidance: ask for this when the document describes systems, services, stacks, networks, or architectural relationships

`blueprint`

- Pros: precise, engineered, authoritative, strong for protocols, design intent, and technical rigor
- Cons: can feel cold or overly schematic for marketing or human-centered subjects
- Guidance: ask for this when the document should feel exact, technical, and intentionally designed

`editorial illustration`

- Pros: expressive, conceptual, and strong for article covers, essays, and symbolic storytelling
- Cons: less literal, so it may underperform when the image must explain concrete architecture
- Guidance: ask for this when the document needs metaphor, mood, or a polished publication-style visual

`cinematic`

- Pros: emotional, aspirational, high-impact, strong for keynote heroes and launch moments
- Cons: can become too grand if the source material really needs clarity over spectacle
- Guidance: ask for this when the image should feel premium, dramatic, and audience-grabbing

`minimal poster`

- Pros: high signal-to-noise, memorable, clean, and strong for one dominant idea
- Cons: can oversimplify documents with important operational or technical nuance
- Guidance: ask for this when the document has one central idea that can be reduced to a powerful symbol

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
      files/          # Optional — eval fixture inputs referenced by evals/evals.json files[]
```

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) for how to add a new skill or improve an existing one.

## License

[MIT](LICENSE)
