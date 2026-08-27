# Eval Runner protocol

## Native worker orchestration

The external handoff uses this topology:

```text
Eval Orchestrator
    |
    +-- Eval Worker -> one eval arm
    +-- Eval Worker -> one eval arm
    +-- Eval Worker -> one eval arm
    +-- ...
```

The Eval Orchestrator coordinates the manifest queue, native child creation,
terminal evidence, exact manifest destinations, and the phase boundary. It
does not execute an eval arm in its own model context. Each descriptor declares
`delegation.dispatch_owner`: `orchestrator` means the orchestrator creates the
declared native subagent/task, while `runner` means the orchestrator starts the
runner-owned native execution surface directly. One arm equals one fresh
native Eval Worker and one model-backed execution. A runner-owned process or
thread is that worker; it must not be nested inside an outer model session.

`orchestration.ps1` is the deterministic queue/state helper copied into every
package. It creates one worker envelope per exact manifest arm, keeps unrelated
arms dependency-free, exposes at most the requested
`execution-profile.json.concurrency` active slots, and leaves a capacity
rejection pending without incrementing the eval attempt count. Independent arms
must use at least two active slots when the requested concurrency and harness
capacity permit it. `Assert-OrchestrationConcurrency` rejects a serial run that
has no explicit capacity-limit evidence; `bridge-manifest-results.ps1
-RequireParallelDispatch` applies that gate before completion. It contains no
harness-specific concurrency ceiling. `Assert-NativeWorkerDelegation` is the
fail-closed handoff gate: an unavailable/unsupported native mechanism cannot
fall back to parent execution, while a conditional mechanism may dispatch only
when terminal evidence will be checked. The dispatch owner is part of the
same descriptor/preflight contract, so generic orchestration does not infer it
from a runner name.

For `delegation.dispatch_owner=runner`, the external handoff invokes
`invoke-runner-owned-arms.ps1` as the complete deterministic Phase 1 boundary.
It reads the manifest/profile, resolves the runner and descriptor, requires
`delegation.dispatch_owner=runner`, preflights every pending manifest run, and
invokes `Assert-NativeWorkerDelegation` for every preflight result. Any
incompatible preflight produces a concise machine-readable summary, starts zero
`execute` processes, and exits non-zero. Only after every preflight passes does
it use the exact orchestration-plan worker IDs and manifest-declared
execution-result paths, start runner-owned `execute` processes concurrently,
redirect each process's single JSON stdout directly to its declared path,
register the runner-produced session/result once, persist
`orchestration-state.json`, and enforce the parallel-dispatch gate. Child
processes are headless isolation boundaries: they start through
`fanout-process.ps1` with `CreateNoWindow` so no per-child console window
appears on Windows, and a freed slot is refilled as soon as ANY child completes
(not only the oldest), so a slow eval execution never blocks a faster sibling.
It is not called by preparation, validation, CI, hooks, or automatic completion
gates.
Behavioral evaluation for GitHub Copilot, Codex, and OpenCode is runner-owned:
each declares `delegation.dispatch_owner=runner`, is driven by
`invoke-runner-owned-arms.ps1`, and produces its own terminal
`execution-result.json`. The orchestrator-owned envelope and
`record-native-result.ps1` remain available for any runner that still declares
`dispatch_owner=orchestrator` (for example the deterministic conformance fake).

Phase 1 closes with `execution-freeze.json`. The shared freeze records the exact
manifest arm paths, runner/harness/model/session identity, terminal status, and
SHA-256 hashes for every raw `execution-result.json` and every referenced
transcript/event artifact. `bridge-manifest-results.ps1`, grading, and reporting
must validate that ledger; none of them can replace it or bless changed bytes.
If a raw result or referenced artifact changes, the package is corrupted and
requires a fresh Phase 1 execution.

The normal post-execution boundary is deterministic: the external Grader writes
only the package-root `grading.json` artifact (`codebeltnet/agentic/eval-grading/1`)
with exact assertion identities and `passed`/`evidence` decisions. The shared
`apply-eval-grading.ps1` helper projects those decisions onto canonical
`result.json` files and verifies that every non-grading field is unchanged.
`finalize-eval-package.ps1` then validates the freeze, bridge, canonical results,
and complete grading, invokes the existing report adapter, and fails unless
`report.html`, `skill-creator-report.html`, `benchmark.json`, and `benchmark.md`
are all non-empty. A prose success message cannot substitute for its JSON
success summary.

The delegation contract has three distinct evidence levels:

```text
descriptor        advertised harness capability
preflight         locally observable readiness
terminal evidence proof for the actual delegated Eval Worker
```

Descriptor fields describe a possible native mechanism; they do not prove an
individual child. Preflight may prove that the installed API, plugin, or CLI
surface is present, but child-specific model, cwd, HOME/config, fresh-session,
prompt, exclusion, and result facts remain `conditional` until terminal
evidence arrives. A worker is accepted only when `evidence.delegation` proves
the requested model, exact arm identity, exact run working directory, exact
isolated home/config boundary, prompt hash/fidelity, terminal capture, paired
arm/grading exclusion, fresh worker/session identity, and exactly one model
execution. Missing or mismatched evidence makes the arm `incompatible`; it is
never a reason to invoke the parent or a different transport.

For `dispatch_owner=orchestrator`, the harness-native transport returns a
terminal envelope with schema `codebeltnet/agentic/eval-native-worker-result/1`.
The envelope declares `capture.source = harness_native_transport`,
`capture.terminal = true`, and `capture.worker_authored = false`; the model
worker's answer is data inside the envelope, never its author. The
orchestrator preserves that envelope and invokes `record-native-result.ps1`.
For `dispatch_owner=runner`, the runner's one-arm native execution surface
produces the canonical `execution-result.json` directly; the orchestrator does
not invoke the recorder, manufacture an envelope, or copy assistant text into
transport evidence. In both modes, transport-owned timestamps, identity,
isolation observations, prompt fidelity, terminal completion, and a hashed raw
transcript/event artifact are mandatory. A parent-created summary or repaired
result is incompatible. Native bridging also checks the result's runner
identity, the descriptor's exact delegation mechanism, and the hashed artifact.
An `incompatible` arm is diagnostic-only: it is never gradeable and fails the
completion/benchmark gate.

The descriptor's `delegation` object records the dispatch owner, native mechanism, worker role,
advertised full-capability/model-lock/working-directory/result-capture
properties, harness-authoritative capacity, and the invariant
`nested_model_execution = false`. The direct `execute` process surface is the
runner-owned native worker surface when `dispatch_owner=runner`; for
orchestrator-owned runners it remains a compatibility/conformance surface and
must not be invoked inside the native subagent.

Native delegation mechanisms:

- GitHub Copilot: runner-owned behavioral transport. The runner starts one
  fresh Copilot CLI session per eval execution (`copilot -C <working-directory>
  --model <model> --output-format json`, prompt on stdin) and captures that
  session's own JSONL events as terminal evidence for its model, cwd, isolated
  `COPILOT_HOME`, fresh session, prompt hash, and transcript. Copilot's native
  `task` tool with a full-capability `general-purpose` child remains an
  advertised harness capability but is not the benchmark transport. When an
  `interaction.json` sidecar is present, the runner first proves from the
  installed help that an explicit session-id continuation flag is available,
  captures the first session id from structured events, and adds only that
  exact id on later turns; it never resumes the most recent session.
- Codex: the installed CLI's runner-owned app-server child-session surface,
  `thread/start` followed by `turn/start`, with supplemental post-completion
  `thread/read` when available, and the arm's `cwd`, selected model, and
  ephemeral/fresh session settings. The schema/feature probe is preflight
  readiness only; terminal evidence must prove the actual thread. Subscription
  auth uses a temporary auth-only `CODEX_HOME` containing only `auth.json`; the
  runner physically projects only the arm's `repo/`, `home/`, and candidate
  `skill/` outside the source-repository ancestor chain, does not copy ambient
  config, skills, agents, sessions, memories, plugins, MCP configuration, or
  AGENTS.md, and removes the projection/home in `finally`. `model/rerouted`
  and instruction sources outside that physical arm boundary are incompatible.
  Do not wrap a native Codex app-server worker in another Codex subagent.
- OpenCode: runner-owned behavioral transport. The runner starts one fresh
  OpenCode session per eval execution (`opencode run --format json --auto
  --model <model>`, prompt on stdin) and captures that session's structured
  events as terminal evidence. Scripted interactions use only help-proven
  `--session <exact-session-id>` continuation after turn 1; `--continue` is
  never used. Parallelism comes from the deterministic
  runner-owned process fan-out (`invoke-runner-owned-arms.ps1`), not from an
  orchestrator emitting sibling Task calls in one assistant turn. OpenCode's
  native Task/General subagent (and read-only `Explore`/`Scout`) remain
  advertised harness capabilities but are not the benchmark transport.
This directory contains the package-local implementation of the v0.9.1 Eval
Runner protocol. It is copied into prepared packages so the external Eval
Orchestrator can use the same runner implementation that was validated with the
package. It is not a model executor used by repository automation.

The boundary is owner-dependent:

```text
dispatch_owner=orchestrator: run.json + execution-profile.json -> native worker envelope -> record-native-result.ps1 -> execution-result.json
dispatch_owner=runner:       run.json + execution-profile.json -> runner-owned native execute -> execution-result.json
```

`run.json` is the existing portable one-arm contract. It owns the prompt,
working directory, isolated home, staged candidate skill, and required
experimental controls. Its `filesystemIsolationRequired` and
`mustNotReadOutsideSandbox` fields describe the staged worker-facing package
boundary; they do not claim that the host has a hard OS filesystem sandbox.
`execution-profile.json` selects the runner, runner-native model selector, and
execution configuration. The model string is opaque to the portable layer: a
runner may pass it through unchanged or split it internally when its native CLI
requires separate provider/model arguments. The profile contains no credentials,
secrets, or portable provider field.
`execution-result.json` normalizes one blind execution and keeps grading
separate from raw evidence. Its `exit.status` is a numeric process exit code or
`null`, never a textual lifecycle label such as `completed`. Ordinary runs are
single-turn; an optional package-local `interaction.json` sidecar can request
scripted user turns, but only a runner that advertises and preflights
`scripted_multi_turn_same_session` may continue one fresh session. The runner
captures ordered user/assistant turns, the shared session/thread identity,
timestamps when available, and the complete final transcript/event artifact.

Every runner exposes the same process surface:

```text
runner.ps1 describe
runner.ps1 preflight -Run <run.json> -Profile <execution-profile.json>
runner.ps1 execute -Run <run.json> -Profile <execution-profile.json>
```

The native handoff additionally uses:

```text
record-native-result.ps1 -Runner <runner> -Run <run.json> -Profile <execution-profile.json> -NativeResult <native-worker-result.json> -Output <execution-result.json>
```

`record-native-result.ps1` is deterministic and never starts a harness or a
model; it is used only for orchestrator-owned native envelopes. The direct
`execute` command runs exactly one arm and is the runner-owned native transport
when the descriptor says `dispatch_owner=runner`. It must not be nested inside
an outer model worker. A scripted interaction still uses one `execute` process
and one exact native session identity; later turns are runner-owned
continuation invocations, never fresh sessions or implicit last-session resumes.

The commands emit one JSON document. `describe` and `preflight` do not consume
model tokens. `execute` runs exactly one arm, never grades or retries for answer
quality, and returns a normalized result even for refusals, timeouts, failures,
and incompatibility. Single-turn execution always starts a fresh session;
scripted continuation is an explicit capability-gated exception inside that
same runner-owned execution.

The package resolver selects a named child directory under this directory. It
does not guess a runner and does not fall back to an improvised worker. A
selected runner that cannot satisfy the required contract returns
`incompatible`. Hard OS-level filesystem confinement is a confidence signal,
not a universal prerequisite: a run with all mandatory experimental controls
proven reports `strict` isolation when hard confinement is proven and
`pragmatic` isolation when it is not. A missing fresh context, controlled skill
boundary, prompt fidelity, result capture, or other mandatory control remains
incompatible.

The fake runner is deterministic and is the conformance reference. It has no
harness-native delegation surface and its compatibility output is never proof
for a real harness. GitHub
Copilot, Codex, and OpenCode are thin harness-specific adapters. Their
native CLI flags, environment setup, event parsing, authentication injection,
and isolation checks stay inside their own directories. Windows is supported in
pragmatic mode when the native CLI satisfies the mandatory controls.

`github-copilot` with `claude-haiku-4.5` is the Codebelt Reference evaluation
configuration: a stable, economical pairing for routine skill comparison. It is
a repository convention, not an Anthropic default, and preparation verifies that
the model still appears in the current Copilot catalog before selecting it.
Cross-runner and cross-model numbers are never blended into one score; a paired
`with_skill` versus `without_skill` comparison is only meaningful within one
identical runner, model, and configuration stratum.

The following CLI details describe compatibility `execute` behavior where a
runner owns a different native surface; they are not a second model layer for
native worker orchestration. The native worker mechanisms above are
authoritative for the external handoff. A runner-owned runner may use its
`execute` command as that native surface; an orchestrator-owned runner must
keep `execute` out of the native subagent.

For a single-turn run, GitHub Copilot uses `copilot -C <working-directory> --model <model>
--output-format json --allow-all-tools --no-ask-user --disable-builtin-mcps
--no-color --log-level none --no-auto-update
--secret-env-vars=COPILOT_GITHUB_TOKEN,GH_TOKEN,GITHUB_TOKEN` with the exact
prepared prompt bytes delivered once through stdin. It passes no `--prompt`/`-p`,
`--resume`, `--continue`, `--session-id`, or `--connect` on this fresh
single-turn invocation, and it does not use
the blanket `--yolo`, `--allow-all`, `--allow-all-paths`, or `--allow-all-urls`
switches. `--allow-all-tools` is a broad tool-approval grant required for
noninteractive execution; it does not disable path or URL verification.
Repository-owned custom instructions remain enabled and are staged identically
in both paired arms. Personal Copilot configuration is excluded by run-local
`COPILOT_HOME`, `COPILOT_CACHE_HOME`, `HOME`, `USERPROFILE`, and XDG roots;
the runner does not copy the normal `.copilot` directory. Authentication prefers
explicit `COPILOT_GITHUB_TOKEN`, `GH_TOKEN`, or `GITHUB_TOKEN`; when none is
present, the trusted runner may resolve `gh auth token` outside the worker and
inject only that token as a protected environment variable. Host `GH_CONFIG_DIR`
is never forwarded into the evaluated worker. `--secret-env-vars` removes every
listed token variable from shell and MCP child environments. Preflight does not
make a model request and therefore reports native keychain/service readiness as
conditional rather than claiming successful remote authentication. Codex's
compatibility API-key path uses `--ask-for-approval never` with `exec --sandbox
workspace-write`; subscription eval arms use the runner-owned app-server path
described above. It does not combine explicit sandbox selection with
`--approve-for-me`. OpenCode single-turn execution uses `run --format json --auto --model
<runner-native-model>` with isolated global/config roots and preserves
repository-owned project configuration; it does not depend on
`OPENCODE_DISABLE_PROJECT_CONFIG` or use `--pure`. For a scripted interaction,
turn 1 uses those same arguments and later turns add the exact captured session
id using the installed-help-proven `--session` form; `--continue` is rejected.

Each captures an exact observable
CLI version and passes only documented environment credentials when the selected
runner supports them. None copies a global skill directory, memory store, plugin
set, or normal agent profile into a run.

Model discovery lives in `scripts/Get-HarnessModels.ps1`. It uses the current local harness catalog where available: Copilot through the installed CLI SDK help-visible model list, Codex through `codex debug models`, OpenCode through `opencode models opencode --verbose`. OpenCode discovery returns only models with current metadata proving free availability; zero free models is a clear local failure, not a fallback to paid models.

Freebuff is currently documented as planned/blocked. Its supported CLI remains
TUI-oriented and does not provide the required one-prompt, noninteractive,
machine-readable fresh-session transport, so no Freebuff runner is advertised.
