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
# npx skillsadd codebeltnet/agentic/another-skill
# npx skillsadd codebeltnet/agentic/yet-another
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
| [agent-commits](skills/agent-commits/SKILL.md) | AI-driven git commit workflow with emoji (gitmoji-first), conventional prefixes, and support for both bot-attributed (`git bot commit`) and human-attributed (`git commit`) commits. The agent does all the work either way. Stack-agnostic. |
| [dotnet-solution-setup](skills/dotnet-solution-setup/SKILL.md) | Scaffold new .NET solutions following codebeltnet engineering conventions. Supports NuGet library and standalone application variants. Generates all project files, CI pipeline, MSBuild configuration, and code quality tooling. |

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
