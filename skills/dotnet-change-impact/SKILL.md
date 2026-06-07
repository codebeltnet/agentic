---
name: dotnet-change-impact
description: >
  Classifies proposed .NET library or NuGet package changes and recommends the correct release bump: Major, Minor, or Patch. Applies both Semantic Versioning (MAJOR.MINOR.PATCH) and .NET assembly/file versioning (Major.Minor.Build.Revision), grounded in Microsoft’s official .NET library compatibility rules. Use when evaluating breaking changes, API diffs, public API changes, dependency updates, TFM/platform support, interface or enum changes, overloads, analyzers, source generators, or binary/source/behavioral/design-time/backwards compatibility. Outputs only Major, Minor, or Patch when clear; otherwise provides structured compatibility reasoning.
---

# .NET Change Impact

Classify a proposed change to a .NET library or NuGet package and recommend the correct
release bump. This skill exists to stop accidental breaking releases from being shipped as
a patch or minor, while staying practical enough not to label every internal refactor as
breaking.

It answers one question:

> Given these changes, should I bump **Major**, **Minor**, or **Patch**?

The authority for every decision is Microsoft's official .NET compatibility guidance:

- https://learn.microsoft.com/en-us/dotnet/core/compatibility/library-change-rules
- https://learn.microsoft.com/en-us/dotnet/core/compatibility/categories

Treat those two sources as normative. When the deep category definitions or the long tail of
special cases matter, read `references/compatibility-categories.md`.

## Critical: choose the output mode first

Before answering, decide which mode applies. This choice is the most important behavior of the
skill, because the two modes look completely different to the user.

### Deterministic mode

Use this when the change is clear and unambiguous and a single bump obviously applies. Output
**exactly one** of the following words and **nothing else** — no markdown, no preamble, no
explanation, no trailing punctuation:

```text
Major
```

```text
Minor
```

```text
Patch
```

The value of deterministic mode is that it can be dropped straight into a release pipeline,
a commit, or a script. Any extra prose defeats that purpose, so resist the urge to justify a
clear answer.

### Explanation mode

Use this when the answer is genuinely not clear-cut. Switch to explanation mode whenever any
of these is true:

- The user asks for an explanation or asks "why".
- The input is ambiguous, incomplete, or mixed (several unrelated changes at once).
- More than one category is plausible and the deciding fact is missing.
- The decision depends on whether an API is **public or internal**.
- The decision depends on **consumer reliance**, or on documented vs. undocumented behavior.
- The decision depends on whether downstream projects treat **warnings as errors**.
- The user appears to be steering toward a lower bump than the change warrants.

In explanation mode, do not collapse to a bare word. Surface the trade-off so the developer
can make an informed, deliberate call. Use the template in **Explanation output format** below.

When in genuine doubt about which mode applies, prefer explanation mode. A bare word that hides
a real compatibility risk is worse than a short, honest analysis.

## Internal analysis process

Run this analysis internally for every request, regardless of which mode you output. Do **not**
print this checklist when deterministic output is possible — it is reasoning scaffolding, not
part of the answer.

1. Identify all public contract changes (types, members, signatures, accessibility, contracts).
2. Identify all observable behavior changes (return values, exceptions, ordering, serialization).
3. Identify all source compatibility risks (would existing consumer code still compile?).
4. Identify all binary compatibility risks (would existing compiled consumers still load/run?).
5. Identify all design-time compatibility risks (analyzers, generators, build, tooling, restore).
6. Determine whether existing consumers remain backwards compatible end to end.
7. Determine the highest required bump across every change present.
8. If the result is clear, produce deterministic output.
9. If the result is ambiguous or an explanation was requested, produce explanatory output.

## Version bump rules

### Major — breaking or potentially breaking

Recommend `Major` when the change can break, or plausibly break, existing consumers. A change
is breaking if it can affect backwards, binary, source, or design-time compatibility, or change
observable behavior that consumers can reasonably depend on.

Changes that usually require `Major`:

- Removing a public type, member, constructor, property, method, event, field, enum value,
  attribute, or interface member.
- Renaming public APIs, or changing public method signatures.
- Changing parameter order, parameter types, return types, generic constraints, nullability
  contracts, accessibility, or inheritance behavior.
- Making a public API less accessible.
- Making previously valid consumer code fail to compile, or previously compiled consumer
  binaries fail at runtime.
- Changing observable behavior consumers can reasonably depend on: serialization, wire format,
  persisted data format, exception behavior, ordering, equality, hashing, parsing, formatting,
  validation, or default values, in a breaking way.
- Removing or reducing platform, TFM, runtime, OS, architecture, or dependency support.
- Introducing stricter validation that rejects previously accepted inputs — unless it is an
  explicitly documented bug fix that is extremely unlikely to affect valid consumers.
- Changing public abstractions or interfaces so implementers must change code.
- Changing package identity, assembly identity, strong name, namespace, or binding expectations
  in a way that affects existing consumers.

### Minor — backward-compatible additions

Recommend `Minor` when the change adds functionality without breaking source, binary,
design-time, or behavioral compatibility.

Changes that usually require `Minor`:

- Adding a new public type, method, property, constructor, overload, event, enum type, or
  extension method that does not break existing compilation or behavior.
- Adding optional, opt-in capabilities, or new behavior behind opt-in configuration.
- Adding support for a new TFM, platform, runtime, OS, architecture, or dependency version
  without removing existing support.
- Adding new package features while preserving existing contracts.
- Improving performance with no observable semantic breakage.
- Adding diagnostics, analyzers, or source generators that do not break builds by default.

Be conservative with interfaces: adding members to an existing public interface is usually
breaking for implementers and therefore usually `Major`. Default interface implementations
reduce but do not eliminate source, design-time, and behavioral risk — evaluate them, do not
wave them through.

### Patch — backward-compatible, no new public surface

Recommend `Patch` when the change preserves the public contract and adds no new public
functionality.

Changes that usually require `Patch`:

- Bug fixes that preserve the intended public contract.
- Dependency updates that do not change the public API, supported TFMs, runtime behavior, or
  compatibility guarantees.
- Security fixes that preserve compatibility.
- Internal implementation changes and refactoring with no public or behavioral impact.
- Documentation updates; build, packaging, CI, test, or housekeeping changes.
- Non-breaking performance improvements; non-breaking analyzer or warning changes.

Key nuance: a bug fix can still be breaking. If the fix changes observable behavior, exception
behavior, serialization, validation, ordering, equality, formatting, parsing, threading,
timing, or side effects that consumers may depend on, evaluate it as a potential `Major`.

## Precedence rules

When several changes ship together, choose the **highest** required bump:

```text
Major > Minor > Patch
```

- One breaking change plus several bug fixes → `Major`.
- One backward-compatible feature plus several patches → `Minor`.
- Only housekeeping and bug fixes → `Patch`.

## Conservative decision policy

When uncertain, prefer the safer classification:

- If a change might break existing consumers, recommend `Major`.
- If a change only adds backward-compatible functionality, recommend `Minor`.
- If a change only fixes or maintains existing behavior, recommend `Patch`.

But do not inflate every behavior change to `Major`. First decide whether the behavior is
actually observable, documented, reasonably relied upon, or compatibility-sensitive. An
internal or non-observable change is not a breaking change just because something changed.

## Compatibility classification

When you produce an explanation, classify the impact using these five categories. Full,
Microsoft-grounded definitions and examples live in `references/compatibility-categories.md`;
the summary here is enough for most decisions.

- **Behavioral change** — the API still compiles and loads, but observable behavior differs
  (return values, exceptions, validation, ordering, equality/hash, serialization, formatting,
  side effects, threading/timing/caching). Can be breaking even when binary and source
  compatibility are intact.
- **Binary compatibility** — existing compiled assemblies may fail against the new version
  without recompilation (removed members, changed signatures, changed assembly identity,
  changed type shape). Usually implies `Major`.
- **Source compatibility** — existing source must change to compile (renames, signature
  changes, removals, new constraints, ambiguous overloads, changed accessibility/nullability,
  required language/TFM bumps). Usually implies `Major`.
- **Design-time compatibility** — build, tooling, analyzers, generators, project system, IDE,
  or restore behavior changes (new default-on analyzer errors, changed generator output,
  build/props/targets changes, SDK/tooling requirements). May imply `Major` if it breaks
  existing consumers by default.
- **Backwards compatibility** — the end-to-end test: can existing consumers of the old version
  use the new version unmodified, with equivalent behavior? If they cannot compile, run, or
  build, or they observe a breaking behavior change, it is not backwards compatible and usually
  requires `Major`.

## Special cases

These recur often enough to call out directly. The full catalog is in
`references/compatibility-categories.md`.

- **Dependency updates** — default `Patch`. Escalate to `Minor` or `Major` only if the update
  changes public API exposure, supported TFMs/platforms, runtime behavior, introduces
  binding/runtime incompatibility, requires consumers to update their own dependencies, or
  drops compatibility with existing consumers.
- **Bug fixes** — default `Patch`. If the old, incorrect behavior was publicly observable and
  consumers may depend on it, explain the trade-off; it may still need `Major`.
- **New overloads** — usually `Minor`, but check for overload-resolution ambiguity. If existing
  source could bind differently or fail to compile, consider `Major`.
- **Interface changes** — adding members to a public interface is usually `Major` (implementers
  may fail to compile). Adding a brand-new interface is usually `Minor`. Default interface
  members still warrant caution and explanation.
- **Enum changes** — adding values is usually `Minor`, but may be behavioral or source-impacting
  if consumers exhaustively switch over values or serialization contracts are affected. Removing
  or renaming values is usually `Major`.
- **Analyzer / source generator / build changes** — warnings-only diagnostics that do not break
  default builds are usually `Patch` or `Minor` by scope. Diagnostics that become errors by
  default, or generated-code changes that break consumers, are usually `Major`.
- **TFM / platform support** — adding support is usually `Minor`; removing support is usually
  `Major`. Raising the minimum supported runtime, SDK, language version, OS, or CPU architecture
  is usually `Major` when existing consumers are affected.
- **Performance changes** — usually `Patch` when behavior is unchanged; may be `Major` when
  timing, ordering, threading, concurrency, caching, resource lifetime, or side effects are
  observable and compatibility-sensitive.

## SemVer and .NET version-number mapping

### Semantic Versioning — `MAJOR.MINOR.PATCH`

- `Major` → increment Major, reset Minor and Patch to `0`.
- `Minor` → increment Minor, reset Patch to `0`.
- `Patch` → increment Patch.

### .NET assembly/file versioning — `Major.Minor.Build.Revision`

- `Major` → increment Major. Reset or align Minor per project policy.
- `Minor` → increment Minor.
- `Patch` → normally maps to Build or Revision per project policy.
- `Build` and `Revision` are CI/build metadata. Never use them to hide a breaking change, and
  do not use them as a substitute for a SemVer Patch when NuGet package versioning is involved.

## Input interpretation

Input may arrive as release notes, git commits, PR summaries, API diffs, changelog entries,
dependency updates, bug-fix descriptions, or a stated release intent. Distinguish carefully
between: public API changes, internal implementation changes, consumer-visible behavior
changes, build/design-time changes, documentation-only changes, package/dependency changes,
and platform/TFM support changes. The bump follows the most impactful real change, not the
loudest commit subject.

## Explanation output format

When explanation mode applies, use exactly this structure:

```markdown
## Recommendation

<Major|Minor|Patch>

## Compatibility impact

- Behavioral change: <yes/no/possible> — <reason>
- Binary compatibility: <yes/no/possible> — <reason>
- Source compatibility: <yes/no/possible> — <reason>
- Design-time compatibility: <yes/no/possible> — <reason>
- Backwards compatibility: <yes/no/possible> — <reason>

## Reasoning

<Why this bump is recommended. Reference the official .NET compatibility principles,
especially whether existing consumers can compile, run, and observe equivalent behavior.>

## Deterministic decision

<The single fact that would make the answer deterministic if it is currently ambiguous —
for example, "Is `Parse` part of the public API or internal?" Once that fact is known, the
bump follows directly.>
```

## Good output characteristics

- Emits exactly one word in deterministic mode, with no decoration.
- Switches to the structured template the moment the decision is genuinely ambiguous or an
  explanation is requested.
- Picks the highest required bump when changes are mixed.
- Grounds every breaking-change call in whether existing consumers can compile, run, and
  observe equivalent behavior.
- Stays conservative on interface and behavioral risk without inflating internal-only changes.

## Bad output characteristics

- Adding prose, markdown, or punctuation around a clear one-word answer.
- Collapsing an ambiguous or mixed change into a bare word that hides a compatibility risk.
- Labeling a publicly observable behavior change as `Patch` just because it is "a fix".
- Calling an internal, non-observable refactor `Major`.
- Hiding a breaking change behind a Build/Revision bump.
- Inventing compatibility guarantees or migration steps the input does not support.
