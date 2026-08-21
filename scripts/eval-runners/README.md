# Eval Runner protocol

This directory contains the package-local implementation of the v0.9.1 Eval
Runner protocol. It is copied into prepared packages so the external Eval
Orchestrator can use the same runner implementation that was validated with the
package. It is not a model executor used by repository automation.

The boundary has three documents:

```text
run.json + execution-profile.json -> runner -> execution-result.json
```

`run.json` is the existing portable one-arm contract. It owns the prompt,
working directory, isolated home, staged candidate skill, and required
experimental controls. Its `filesystemIsolationRequired` and
`mustNotReadOutsideSandbox` fields describe the staged worker-facing package
boundary; they do not claim that the host has a hard OS filesystem sandbox.
`execution-profile.json` selects the runner and
execution configuration. It contains no credentials or secrets.
`execution-result.json` normalizes one blind execution and keeps grading
separate from raw evidence.

Every runner exposes the same process surface:

```text
runner.ps1 describe
runner.ps1 preflight -Run <run.json> -Profile <execution-profile.json>
runner.ps1 execute -Run <run.json> -Profile <execution-profile.json>
```

The commands emit one JSON document. `describe` and `preflight` do not consume
model tokens. `execute` runs exactly one arm, never resumes a session, never
grades or retries for answer quality, and returns a normalized result even for
refusals, timeouts, failures, and incompatibility.

The package resolver selects a named child directory under this directory. It
does not guess a runner and does not fall back to an improvised worker. A
selected runner that cannot satisfy the required contract returns
`incompatible`. Hard OS-level filesystem confinement is a confidence signal,
not a universal prerequisite: a run with all mandatory experimental controls
proven reports `strict` isolation when hard confinement is proven and
`pragmatic` isolation when it is not. A missing fresh context, controlled skill
boundary, prompt fidelity, result capture, or other mandatory control remains
incompatible.

The fake runner is deterministic and is the conformance reference. GitHub
Copilot, Codex, OpenCode, and Cline are thin harness-specific adapters. Their
native CLI flags, environment setup, event parsing, authentication injection,
and isolation checks stay inside their own directories. Windows is supported in
pragmatic mode when the native CLI satisfies the mandatory controls.

`github-copilot` with `claude-haiku-4.5` is the Codebelt reference evaluation
configuration: a stable, economical pairing for routine skill comparison. It is
a repository convention, not an Anthropic default, and the model stays
configurable through `execution-profile.json`, so any Copilot-served model can
be selected. Cross-runner and cross-model numbers are never blended into one
score; a paired `with_skill` versus `without_skill` comparison is only
meaningful within one identical runner, model, and configuration stratum.

GitHub Copilot uses `copilot -C <working-directory> --model <model>
--output-format json --allow-all-tools --no-ask-user --disable-builtin-mcps
--no-color --log-level none --no-auto-update
--secret-env-vars=COPILOT_GITHUB_TOKEN,GH_TOKEN,GITHUB_TOKEN` with the exact
prepared prompt bytes delivered once through stdin. It passes no `--prompt`/`-p`,
`--resume`, `--continue`, `--session-id`, or `--connect`, and it does not use
the blanket `--yolo`, `--allow-all`, `--allow-all-paths`, or `--allow-all-urls`
switches. `--allow-all-tools` is a broad tool-approval grant required for
noninteractive execution; it does not disable path or URL verification.
Repository-owned custom instructions remain enabled and are staged identically
in both paired arms. Personal Copilot configuration is excluded by run-local
`COPILOT_HOME`, `COPILOT_CACHE_HOME`, `HOME`, `USERPROFILE`, and XDG roots;
the runner does not copy the normal `.copilot` directory. Authentication follows
Copilot's normal order: explicit `COPILOT_GITHUB_TOKEN`, `GH_TOKEN`, or
`GITHUB_TOKEN`, then the OS credential store, then GitHub CLI fallback through a
host-derived `GH_CONFIG_DIR` when available. `--secret-env-vars` removes every
listed token variable from shell and MCP child environments. Preflight does not
make a model request and therefore reports native keychain/service readiness as
conditional rather than claiming successful remote authentication. Codex uses
`--ask-for-approval never` with `exec --sandbox
workspace-write`; it does not combine explicit sandbox selection with
`--approve-for-me`. OpenCode uses `run --format json --auto` with isolated
global/config roots and preserves repository-owned project configuration; it
does not depend on `OPENCODE_DISABLE_PROJECT_CONFIG` or use `--pure`. Cline uses
`--json`, `--auto-approve true`, `--retries 0`, `--config <run-home>`,
`--data-dir <run-home>/.cline/data`, and run-local hooks; it passes no session
id. Each captures an exact observable CLI version and passes only documented
environment credentials when the selected runner supports them. None copies a
global skill directory,
memory store, plugin set, or normal agent profile into a run.

Freebuff is currently documented as planned/blocked. Its supported CLI remains
TUI-oriented and does not provide the required one-prompt, noninteractive,
machine-readable fresh-session transport, so no Freebuff runner is advertised.
