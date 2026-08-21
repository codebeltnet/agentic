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
isolation semantics. `execution-profile.json` selects the runner and execution
configuration. It contains no credentials or secrets. `execution-result.json`
normalizes one blind execution and keeps grading separate from raw evidence.

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
`incompatible`.

The fake runner is deterministic and is the conformance reference. The Codex
and OpenCode runners are thin harness-specific adapters. Their native CLI
flags, environment setup, event parsing, authentication injection, and
isolation checks stay inside their own directories.

The Codex adapter requires the current `codex exec` contract and an external
`bwrap` (Linux) or `sandbox-exec` (macOS) boundary in addition to Codex's
`workspace-write` sandbox. It fails closed on Windows because this slice does
not claim package-level filesystem read confinement there. The OpenCode
adapter uses the same platform split, `--pure`, isolated configuration roots,
and a narrowly selected provider credential; it also fails closed when its
external sandbox or credential requirement is unavailable. Neither adapter
copies a global skill directory, memory store, plugin set, or normal agent
profile into a run.
