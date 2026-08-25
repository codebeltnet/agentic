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
does not execute an eval arm itself. One arm equals one fresh delegated
harness-native worker and one model-backed execution. The delegated worker
executes the prepared prompt directly; it must not call the runner's
model-spawning `execute` command or start another model session.

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
when terminal evidence will be checked.

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
never a reason to invoke the parent or the compatibility `runner.ps1 execute`
transport.

The harness-native transport returns a terminal envelope with schema
`codebeltnet/agentic/eval-native-worker-result/1`. The envelope declares
`capture.source = harness_native_transport`, `capture.terminal = true`, and
`capture.worker_authored = false`; the model worker's answer is data inside the
envelope, never its author. If the selected harness exposes only assistant text
or a worker-authored summary, the arm is incompatible. After the worker is
terminal, the orchestrator writes only that captured envelope to a package-local
temporary path and invokes `record-native-result.ps1`. That deterministic
package-runner helper derives the exact run/profile identity, timestamps,
requested configuration, runner/harness identity, and `eval-execution-result/1`
shape, then validates the native evidence before writing the manifest-declared
raw result. The parent may persist only that helper-produced result; it must not
replace it with a worker summary, hand-write `execution-result.json`, or
synthesize a normalized result.
Native bridging also checks the result's runner identity, the descriptor's exact
delegation mechanism, and a hashed transcript/event artifact. An `incompatible`
arm is diagnostic-only: it is never gradeable and fails the completion/benchmark
gate.

The descriptor's `delegation` object records the native mechanism, worker role,
advertised full-capability/model-lock/working-directory/result-capture
properties, harness-authoritative capacity, and the invariant
`nested_model_execution = false`. The direct `execute` process surface remains
for compatibility and deterministic conformance; the external orchestrator
must use only `describe`, `preflight`, and the harness-native delegation
surface for the actual eval arms.

Native delegation mechanisms:

- GitHub Copilot: the CLI's native `task` tool with an explicit
  full-capability `general-purpose` child agent for each arm. Fleet/subagent
  lifecycle is harness-owned; Codebelt supplies the already-known one-arm
  decomposition and requires terminal child evidence. The direct CLI
  `-C`/`--model`/HOME compatibility transport does not prove the child.
- Codex: the installed CLI's native app-server child-session surface,
  `thread/start` followed by `turn/start`, with the arm's `cwd`, selected
  model, and ephemeral/fresh session settings. The schema/feature probe is
  preflight readiness only; terminal evidence must prove the actual child.
  Do not wrap a native Codex child in another `codex exec` invocation.
- OpenCode: the native Task tool with the full-capability built-in `General`
  subagent. Task/General availability is preflight readiness only;
  `Explore`/`Scout` read-only agents are not valid for a mutable eval arm.
  When more than one arm is pending, the external orchestrator must emit the
  sibling Task calls for the first batch in one assistant turn and must not ask
  for confirmation or wait between calls. A client that cannot do that is
  incompatible; available-capacity serial dispatch is not a fallback.
This directory contains the package-local implementation of the v0.9.1 Eval
Runner protocol. It is copied into prepared packages so the external Eval
Orchestrator can use the same runner implementation that was validated with the
package. It is not a model executor used by repository automation.

The boundary has a native terminal envelope plus the runner-owned raw result:

```text
run.json + execution-profile.json -> native worker envelope -> record-native-result.ps1 -> execution-result.json
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
`null`, never a textual lifecycle label such as `completed`.

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
model. The direct `execute` command remains the compatibility/conformance
transport; native delegation must not invoke it because that would create a
second model execution.

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

The following CLI details describe the compatibility `execute` transport only;
they are not a second model layer for native worker orchestration. The native
worker mechanisms above are authoritative for the external handoff.

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
the runner does not copy the normal `.copilot` directory. Authentication prefers
explicit `COPILOT_GITHUB_TOKEN`, `GH_TOKEN`, or `GITHUB_TOKEN`; when none is
present, the trusted runner may resolve `gh auth token` outside the worker and
inject only that token as a protected environment variable. Host `GH_CONFIG_DIR`
is never forwarded into the evaluated worker. `--secret-env-vars` removes every
listed token variable from shell and MCP child environments. Preflight does not
make a model request and therefore reports native keychain/service readiness as
conditional rather than claiming successful remote authentication. Codex uses
`--ask-for-approval never` with `exec --sandbox
workspace-write`; it does not combine explicit sandbox selection with
`--approve-for-me`. OpenCode uses `run --format json --auto --model
<runner-native-model>` with isolated global/config roots and preserves
repository-owned project configuration; it does not depend on
`OPENCODE_DISABLE_PROJECT_CONFIG` or use `--pure`.

Each captures an exact observable
CLI version and passes only documented environment credentials when the selected
runner supports them. None copies a global skill directory, memory store, plugin
set, or normal agent profile into a run.

Model discovery lives in `scripts/Get-HarnessModels.ps1`. It uses the current local harness catalog where available: Copilot through the installed CLI SDK help-visible model list, Codex through `codex debug models`, OpenCode through `opencode models opencode --verbose`. OpenCode discovery returns only models with current metadata proving free availability; zero free models is a clear local failure, not a fallback to paid models.

Freebuff is currently documented as planned/blocked. Its supported CLI remains
TUI-oriented and does not provide the required one-prompt, noninteractive,
machine-readable fresh-session transport, so no Freebuff runner is advertised.
