# API design and compatibility

Load for public APIs, HTTP APIs, libraries, contracts, serialization, versioning, and Semantic Versioning.

**Treat every public API as a long-lived consumer contract.** Someone will depend on it, and changing it later has a cost you cannot see from inside the library.

## Review checklist

- **Naming** — accurate, discoverable, consistent with the surrounding surface and platform conventions.
- **Discoverability** — can a consumer find the right entry point without reading the source?
- **Protocol semantics** — for HTTP, correct methods, status codes, and idempotency.
- **Nullability** — clear, enforced, and documented; no silent nulls across the boundary.
- **Overload ambiguity** — no additions that make existing call sites ambiguous or bind differently.
- **Exception contracts** — which exceptions are part of the contract, and when.
- **Serialization** — stable shapes; explicit handling of unknown/missing fields and versioning.
- **Compatibility** (evaluate all that apply):
  - source compatibility — existing consumer code still compiles;
  - binary compatibility — existing compiled consumers still load and run;
  - behavioural compatibility — observable behaviour is preserved;
  - wire compatibility — serialized/on-the-wire formats still interoperate;
  - configuration compatibility — existing configuration still works;
  - operational compatibility — deployment, monitoring, and runtime expectations still hold.
- **Versioning consequences** — what bump does the change require, and why.
- **Documentation and examples** — accurate, compiling where feasible, kept in step with the surface.

## Semantic Versioning

Choose the **highest** bump any change in the set requires:

- **Major** — any break to source, binary, behavioural, wire, configuration, or operational compatibility, or removal/reduction of supported platforms.
- **Minor** — backward-compatible additions.
- **Patch** — backward-compatible fixes with no new public surface.

A bug fix can still be breaking if consumers can reasonably depend on the old behaviour. In a repository with a dedicated change-impact or release policy, follow that policy; do not invent a parallel one.

## HTTP APIs

Respect HTTP semantics, and distinguish **resource design** from merely exposing controller methods over HTTP.

Where applicable, consider:

- content negotiation;
- media-type (or explicit) versioning over ad-hoc URL version sprawl;
- consistent, machine-readable error representations;
- caching (validators, cache-control) and its correctness;
- concurrency control (ETags / optimistic concurrency);
- pagination and filtering that are stable and discoverable;
- retry and idempotency semantics for unsafe operations;
- `202 Accepted` with a status resource for long-running/asynchronous processing;
- hypermedia controls **only where they provide actual value**, not as ceremony.

## Guidance

- DO design the surface you can defend supporting for years.
- DO NOT remove, rename, or narrow a public member, reduce accessibility, or change a serialized shape without treating it as breaking.
- AVOID leaking internal types, mutable statics, or implementation detail across the public boundary.
- CONSIDER additive, opt-in evolution (new overloads/endpoints/fields) over in-place breaking changes.
