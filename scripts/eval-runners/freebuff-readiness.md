# Freebuff runner readiness

Status: planned and blocked. No Freebuff Eval Runner is shipped or advertised
until the official Freebuff CLI provides a supported noninteractive transport.

The current upstream [Freebuff README](https://github.com/CodebuffAI/freebuff/blob/main/README.md)
documents the `freebuff` TUI. The current upstream
[headless CLI request](https://github.com/CodebuffAI/freebuff/issues/947) asks
for a print/headless mode with machine-readable output; it is evidence that
the required transport is not currently part of the supported CLI contract.
The locally installed CLI was also inspected without a model request:
`freebuff --version` reported `0.0.150`, and its help exposed `login`,
`--continue`, `--cwd`, and `--version`, but no prompt argument, print mode,
JSON/NDJSON output mode, or supported noninteractive session protocol.

The missing capability is therefore the complete one-prompt-in,
machine-readable-result-out, fresh-session transport. TUI keystroke
automation, screen scraping, PTY emulation, private transport use, and the
paid Codebuff SDK are not substitutes for that capability.

Freebuff becomes ready only when the supported official CLI can demonstrate all
of the following without a human TTY:

1. Accept exactly one task/prompt deterministically.
2. Start a fresh independent session without resume or reuse.
3. Select or identify the requested model and configuration.
4. Return the complete final result and any available structured events.
5. Expose a timeout and an enforceable run-local HOME/config/workspace setup.
6. Permit the common Eval Runner contract to keep grading material and paired
   arm data out of the worker.

At that point a runner may be added under `freebuff/runner.ps1` using the
unchanged `describe`, `preflight`, and `execute` protocol. Until then, the
absence of a runner is intentional.
