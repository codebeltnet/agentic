# Agentic Skills

A curated collection of [skills](https://skills.sh) — reusable instruction sets that teach AI agents how to follow specific workflows, conventions, and standards. Designed to work with any agent that supports the skills ecosystem: GitHub Copilot, Claude Code, Cursor, Codex, OpenCode, and [many more](https://skills.sh).

## What are skills?

Skills are Markdown files that an AI agent reads before responding. When a skill is active, the agent follows the rules it contains — consistently, across any tool or model that supports them. They're a lightweight way to encode your team's conventions once and apply them everywhere.

## Install a skill

Skills are published to [skills.sh](https://skills.sh) — the open agent skills ecosystem. Install any skill with a single command:

```bash
npx skillsadd codebeltnet/agentic/<skill-name>
```

For example:

```bash
npx skillsadd codebeltnet/agentic/agent-commits
```

Then activate it in your agent. For example, in GitHub Copilot CLI:

```
Use the skill tool to invoke the "<skill-name>" skill.
```

## Always-on skills

Skills installed via `npx skillsadd` are placed in `~/.claude/skills/` and **automatically loaded in every session** — no manual invocation needed. The agent reads the skill's description and activates it when relevant (e.g. you say "commit this" and the `agent-commits` skill kicks in).

If you want a bundle of skills always available, just install them all:

```bash
npx skillsadd codebeltnet/agentic/agent-commits
npx skillsadd codebeltnet/agentic/trunk-first-repo
# npx skillsadd codebeltnet/agentic/another-skill
```

### Scoping options

| Location | Scope | When to use |
|----------|-------|-------------|
| `~/.claude/skills/` | All sessions, all projects | Your personal defaults — always on everywhere |
| `.claude/skills/` (in a repo) | Project-scoped | Shared team conventions for a specific codebase |
| `.github/skills/` (in a repo) | GitHub Copilot / VS Code | When your team uses Copilot agent mode in the IDE |

> **Tip:** You can mix scopes. Install your personal favorites globally, and add project-specific skills to the repo so your whole team gets them.

## Available Skills

| Skill | Description |
|-------|-------------|
| [agent-commits](skills/agent-commits/SKILL.md) | AI-driven git commit workflow with emoji (gitmoji-first), conventional prefixes, and three identity modes: bot-attributed (`git bot commit`), human-attributed (`git commit`), and collaborative (`git our commit` — agent analyzes authorship, human picks attribution). The agent does all the work either way. Stack-agnostic. |
| [dotnet-solution-setup](skills/dotnet-solution-setup/SKILL.md) | Scaffold new .NET solutions following codebeltnet engineering conventions. Supports NuGet library and standalone application variants. Generates all project files, CI pipeline, MSBuild configuration, and code quality tooling. |
| [trunk-first-repo](skills/trunk-first-repo/SKILL.md) | Initialize a git repository following [scaled trunk-based development](https://trunkbaseddevelopment.com/#scaled-trunk-based-development). Seeds an empty `main` branch and creates a versioned feature branch (`v0.1.0/init`), enforcing a PR-first workflow where content only reaches main through peer-reviewed pull requests. |

### Why agent-commits?

Commit messages are the most-read documentation in any codebase — yet they're usually an afterthought. "fix stuff", "wip", "address PR feedback" tells you nothing six months later. Writing good commits takes discipline, and when you're in flow, it's the first thing that slips.

**agent-commits** handles the entire commit workflow — staging, diffing, crafting the message, choosing the right emoji — so every commit is consistent and meaningful without breaking your flow. Whether the agent authors the commit (`git bot commit`), you do (`git commit`), or you worked on it together (`git our commit`), the quality is the same.

- **Gitmoji-first** — visual commit categories that are scannable at a glance
- **Conventional prefixes** — `fix`, `feat`, `refactor` as fallback when gitmoji isn't available
- **Three identity modes** — bot, human, or collaborative — the agent does the work either way, you choose who gets credit
- **Stack-agnostic** — works with any language, framework, or project type
- **Squash-and-merge friendly** — structured commits make PR squash summaries read like a changelog

### Why dotnet-solution-setup?

Starting a new .NET solution "from scratch" usually means copying from your last project, deleting half of it, and spending an hour wiring up CI, MSBuild props, versioning, and code quality tooling. Every new repo drifts slightly from the last one. Six months later, no two solutions look the same.

**dotnet-solution-setup** encodes the full codebeltnet convention into a repeatable scaffold — from `Directory.Build.props` to CI pipelines to DocFX. Every solution starts identical, and every deviation is intentional.

- **Convention over configuration** — opinionated defaults that match real production setups
- **Variant-aware** — NuGet library and standalone app have different needs; the skill knows the difference
- **Complete from the start** — CI pipeline, code quality, test infrastructure, and governance docs on day one
- **Template-driven** — real files, not generated strings, so you can inspect and evolve the templates

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
    SKILL.md          # The skill itself — loaded by the AI
    evals/            # Optional: test prompts used to validate the skill
```

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) for how to add a new skill or improve an existing one.

## License

[MIT](LICENSE)
