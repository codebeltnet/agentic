# .NET Compatibility Categories — Reference

Detailed, Microsoft-grounded definitions for the five compatibility categories and the full
catalog of special cases. `SKILL.md` carries the decision engine and summaries; consult this
file when a decision hinges on a nuanced category boundary or an uncommon change shape.

Normative sources:

- [Library change rules](https://learn.microsoft.com/en-us/dotnet/core/compatibility/library-change-rules)
- [Compatibility categories](https://learn.microsoft.com/en-us/dotnet/core/compatibility/categories)

## Table of contents

1. The five categories in depth
2. Why a change can be breaking even when it compiles
3. Special-case catalog
4. Worked classification examples

## 1. The five categories in depth

### Behavioral change

The public API surface is unchanged — it still compiles against and loads against existing
consumers — but the **observable behavior** differs. This is the category developers most often
under-weight, because nothing in the signature changed.

Observable behavior includes:

- Different return values for the same inputs.
- Different exceptions thrown, or exceptions thrown where none were before (and vice versa).
- Different input validation (stricter or looser).
- Different ordering of results (collections, enumerations, query output).
- Different equality or hash-code behavior.
- Different serialization, deserialization, or formatting output.
- Different side effects (files written, events raised, state mutated).
- Different threading, timing, caching, retry, or I/O behavior.

A behavioral change is breaking when consumers can reasonably depend on the old behavior. It can
be breaking even when binary and source compatibility are fully intact, which is why a "bug fix"
is not automatically a `Patch`.

### Binary compatibility

Existing **compiled** consumer assemblies must continue to run against the new version without
recompilation. A change is binary-incompatible when a previously compiled consumer could fail to
load or fail at runtime against the new assembly. Examples:

- Removing or renaming public members.
- Changing method signatures, return types, or parameter types.
- Changing assembly identity (name, version policy, strong name, public key).
- Changing the shape of a public field, property, event, or method.
- Changing base classes or interface contracts that compiled consumers rely on.

Binary incompatibility almost always implies `Major`.

### Source compatibility

Existing consumer **source code** must continue to compile against the new version without edits.
A change is source-incompatible when previously valid consumer code would no longer compile:

- Renamed or removed APIs.
- Changed signatures or required new arguments.
- New generic constraints.
- Newly ambiguous overloads (overload resolution now fails).
- Reduced accessibility (e.g., `public` → `internal`).
- Changed nullability annotations that break `<Nullable>enable</Nullable>` consumers, or
  analyzer behavior that breaks strict builds.
- A required higher C# language version or TFM.

Source incompatibility usually implies `Major`. Note the asymmetry: a change can be binary
compatible but source incompatible (e.g., adding an ambiguous overload), or source compatible
but binary incompatible. Evaluate both.

### Design-time compatibility

The change affects build, tooling, analyzers, source generators, the project system, the IDE
experience, package restore, or compile-time diagnostics — rather than runtime behavior:

- New analyzer diagnostics that are **errors by default**.
- Source generator output changes that alter or break generated code.
- Changes to MSBuild targets/props shipped in the package.
- Package restore behavior changes.
- New SDK, workload, or tooling requirements.
- Design-time build failures.

Design-time incompatibility may imply `Major` when existing consumers are broken by default
(for example, a build that previously succeeded now fails). Warnings-only changes that do not
break a default build are usually lower impact.

### Backwards compatibility

This is the synthesizing question, not a separate mechanism: **can an existing consumer of the
old version adopt the new version with no modifications and get equivalent behavior?** If the
consumer cannot compile, cannot run, fails at design time, or observes a breaking behavior
change, the release is not backwards compatible and usually requires `Major`. Use this category
to summarize the combined effect of the other four.

## 2. Why a change can be breaking even when it compiles

The most common misclassification is treating "the public API didn't change" as "this is safe".
Microsoft's guidance is explicit that behavioral changes are a first-class compatibility concern.
When evaluating any fix, refactor, or performance improvement, ask:

- Could a reasonable consumer have written code that depends on the **old** observable behavior?
- Is the old behavior documented, or is it an undocumented implementation detail?
- Does the change alter exceptions, ordering, equality, serialization, validation, timing, or
  side effects?

If the answer points to real consumer reliance, escalate from `Patch` toward `Major`, and
prefer explanation mode so the trade-off is visible.

## 3. Special-case catalog

### Dependency updates

Default `Patch`. Escalate when the dependency update:

- changes the library's own public API exposure (re-exported types, transitively visible APIs),
- changes supported TFMs or platforms,
- changes runtime behavior consumers can observe,
- introduces a binding or runtime incompatibility,
- forces consumers to update their own references to that dependency,
- removes compatibility with existing consumers.

If any apply, evaluate as `Minor` (additive, compatible) or `Major` (breaking).

### Bug fixes

Default `Patch`. But a bug fix that changes publicly observable behavior may be breaking even
though the fix is "correct". If the old behavior was clearly wrong yet observable, explain the
trade-off; depending on consumer reliance it may still require `Major`. The correctness of the
fix does not by itself make it non-breaking.

### New overloads

Usually `Minor`. The risk is **source compatibility**: a new overload can make a previously
unambiguous call ambiguous, or change overload resolution so existing source binds to a different
method or fails to compile. When that risk is real, consider `Major`.

### Interface changes

- Adding members to an existing public interface → usually `Major` (existing implementers fail to
  compile).
- Adding a brand-new interface → usually `Minor`.
- Adding a **default interface member** → lower source-break risk for implementers, but still
  carries source, design-time, and behavioral risk depending on language version, multiple
  inheritance of members, and runtime support. Do not treat it as automatically safe — evaluate
  and explain.

### Enum changes

- Adding enum values → usually `Minor`. But it can be behavioral or source-impacting if consumers
  exhaustively `switch` over the values (e.g., with no default arm) or if serialization contracts
  depend on the closed set.
- Removing or renaming enum values → usually `Major`.
- Changing the underlying numeric value of an existing member → usually `Major` (binary and
  serialization impact).

### Analyzer / source generator / build changes

- New diagnostics that are warnings only and do not break default builds → usually `Patch` or
  `Minor` depending on feature scope.
- Diagnostics promoted to errors by default → usually `Major` (breaks builds that previously
  succeeded).
- Source generator output changes that break or materially alter consumer-visible generated code
  → usually `Major`.

### TFM / platform support

- Adding support for a new TFM, platform, runtime, OS, or architecture → usually `Minor`.
- Removing support → usually `Major`.
- Raising the minimum supported runtime, SDK, C# language version, OS, or CPU architecture →
  usually `Major` when existing consumers are affected.

### Performance changes

Usually `Patch` when behavior is unchanged. Escalate toward `Major` when timing, ordering,
threading, concurrency, caching, resource lifetime, or other side effects become observable and
compatibility-sensitive (for example, a change from synchronous to lazy evaluation that alters
when exceptions surface).

## 4. Worked classification examples

**Example 1 — clear Major**
Input: "Removed the obsolete `LegacyClient.Connect(string)` overload and renamed `IParser.Read`
to `IParser.ReadAll`."
Output: `Major`. Removal plus a rename of a public interface member breaks binary and source
compatibility, and forces implementers to change code.

**Example 2 — clear Minor**
Input: "Added a new `RetryPolicy` class and a `WithRetry(...)` extension method; existing APIs
unchanged."
Output: `Minor`. Purely additive, backward-compatible public surface.

**Example 3 — clear Patch**
Input: "Fixed a NullReferenceException in an internal cache; no public API or observable behavior
change. Updated a transitive dependency patch version."
Output: `Patch`. Internal fix plus a compatible dependency bump.

**Example 4 — ambiguous, needs explanation**
Input: "Tightened `Parse` to reject empty strings instead of returning null."
This depends on whether `Parse` is public, whether returning null was documented, and whether
consumers rely on it. The deciding fact is the API's visibility and documented contract — surface
that in explanation mode rather than guessing.
