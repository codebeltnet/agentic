# Parameter Form

`dotnet-benchmark` collects a small number of inputs. Present each field **one at a time** using the
host's native input mechanism (e.g. `ask_user` with `choices`) when available. If native structured
input is unavailable, use the deterministic plain-text fallback in the Presentation Rules below. Do
not bundle multiple fields into a single message.

Most fields have smart defaults derived from inspecting the repo and the target type, so a normal run
asks very little. Skip any field whose value is already unambiguous from the conversation (e.g. the
user already named the type).

## Fields

### sut_type
- **type:** text
- **prompt:** "Which type do you want to performance-test? (namespace-qualified if ambiguous)"
- **placeholder:** "e.g. Cuemon.DateSpan or Acme.Buffers.RingBuffer"
- **required:** true
- **description:** The System Under Test. Resolve it in the source tree to learn its namespace, owning
  `src/` project, and public surface. If the user already named a type, accept it and continue.

### benchmark_tier
- **type:** single-choice
- **prompt:** "How thorough should the benchmark be?"
- **choices:**
  - Auto — inspect the type and pick the best shape (Recommended)
  - Simple — member scenarios (construct / format / equals / hash)
  - Complex — sweep input sizes/variants with [Params] and GlobalSetup
- **default:** Auto — inspect the type and pick the best shape (Recommended)
- **description:** Auto uses the complexity heuristics in `references/codebelt-conventions.md`. State
  which tier you chose and why, then let the user override.

### target_runtimes
- **type:** multi-choice
- **prompt:** "Which runtimes should the benchmark jobs measure?"
- **choices:**
  - Runner default only (Recommended)
  - .NET 10 (CoreRuntime.Core10_0)
  - .NET 9 (CoreRuntime.Core90)
  - .NET 8 (CoreRuntime.Core80)
  - .NET Framework 4.8 (ClrRuntime.Net48, Windows only)
- **default:** Runner default only (Recommended)
- **description:** The runner host targets .NET 9/10, but BenchmarkDotNet **jobs** can measure other
  runtimes. Only offer runtimes the benchmark project can target (its `TargetFrameworks` must include
  the matching TFM). Adding extra runtimes multiplies run time.

### run_now
- **type:** single-choice
- **prompt:** "Run the benchmark now, or just wire it up and give you the command?"
- **choices:**
  - Just wire it up and give me the command (Recommended)
  - Run it now
- **default:** Just wire it up and give me the command (Recommended)
- **description:** BenchmarkDotNet runs are slow and heavy. Default is to verify the Release build and
  hand off the run command. Only run it when the user explicitly asks.

## Presentation Rules

1. Ask one field at a time — wait for the answer before presenting the next field.
2. Prefer the host's native structured input controls for every field when available.
3. If native controls are unavailable, use this plain-text fallback:
   - Start with `Field: <field-name>`
   - Repeat the field prompt verbatim
   - For choice fields, show a numbered option list; accept the number or exact option text
   - For `text` fields with a default, show `1. Use "<value>" (Recommended)` and `2. Enter a custom value`
   - After the user answers, restate the normalized value in one short line before moving on
4. When a field has a `default`, present it first and append "(Recommended)" if not already labeled.
5. Treat a blank response on a field that has a default as accepting that default — do not re-ask.
6. Skip a field entirely when its value is already clear from context (e.g. the user said "benchmark
   DateSpan" — `sut_type` is answered).
7. After collecting fields, briefly confirm the plan (type, tier, runtimes, run-or-not) before writing.
