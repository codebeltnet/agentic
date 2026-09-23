# API design and compatibility

Load for public APIs, HTTP APIs, libraries, contracts, serialization, versioning, and Semantic Versioning.

**Treat every public API as a long-lived consumer contract.** Someone will depend on it, and changing it later has a cost you cannot see from inside the library.

## Consumer capability before implementation shape

> Design the contract from the consumer's required capability, not from the shape of the database, domain entity, upstream payload, or implementation model.

Apply Outside-In reasoning and Interface Segregation: identify the consumer's use case, then expose the smallest useful and coherent contract that supports it. Consumers should not depend on unrelated capabilities merely because one implementation happens to provide them. Narrow does not mean cryptic or fragmented into unusable pieces.

Every public field, property, endpoint, member, event, configuration option, and serialized element creates compatibility surface that may need support for years. Do not expose information merely because the backing system contains it. Map backing data into intention-revealing consumer contracts so the implementation or source system can change without unnecessary consumer disruption.

For example, a source with hundreds of customer fields does not justify a public customer mirror when a consumer needs only an identifier, display name, and eligibility result. Keep mapping and source-specific data internal. Validate the serialized and public surface as well as the happy-path behavior; a locally passing implementation can still establish an unnecessary permanent contract.

Before adding surface, name its present consumer and required capability. Once published, do not remove accidental exposure casually: apply compatibility analysis and an explicit migration/versioning policy. Additive evolution is preferable to a break when a real requirement warrants it; additive does not mean cost-free or automatically justified.

## Review checklist

- **Naming** - accurate, discoverable, consistent with the surrounding surface and platform conventions.
- **Discoverability** - can a consumer find the right entry point without reading the source?
- **Protocol semantics** - for HTTP, correct methods, status codes, and idempotency.
- **Nullability** - clear, enforced, and documented; no silent nulls across the boundary.
- **Overload ambiguity** - no additions that make existing call sites ambiguous or bind differently.
- **Exception contracts** - which exceptions are part of the contract, and when.
- **Serialization** - stable shapes; explicit handling of unknown/missing fields and versioning.
- **Compatibility** (evaluate all that apply):
  - source compatibility - existing consumer code still compiles;
  - binary compatibility - existing compiled consumers still load and run;
  - behavioural compatibility - observable behaviour is preserved;
  - wire compatibility - serialized/on-the-wire formats still interoperate;
  - configuration compatibility - existing configuration still works;
  - operational compatibility - deployment, monitoring, and runtime expectations still hold.
- **Versioning consequences** - what bump does the change require, and why.
- **Documentation and examples** - accurate, compiling where feasible, kept in step with the surface.

## Semantic Versioning

Choose the **highest** bump any change in the set requires:

- **Major** - any break to source, binary, behavioural, wire, configuration, or operational compatibility, or removal/reduction of supported platforms.
- **Minor** - backward-compatible additions.
- **Patch** - backward-compatible fixes with no new public surface.

A bug fix can still be breaking if consumers can reasonably depend on the old behaviour. In a repository with a dedicated change-impact or release policy, follow that policy; do not invent a parallel one.

## HTTP APIs

Respect HTTP semantics for every HTTP API. Describe the intended architecture accurately: HTTP and JSON alone do not make an interface REST. An RPC-style or resource-over-HTTP interface can be appropriate without being called REST.

When designing or describing an API as REST, honor the Uniform Interface constraint: resource identification, manipulation through representations, self-descriptive messages, and hypermedia as the engine of application state. Define media types, link relations, and controls that let clients discover valid transitions from representations. Where application state transitions and discoverability are part of the intended REST architecture, hypermedia cannot be dismissed as optional ceremony. Assess the other REST constraints as well; satisfying one constraint does not establish the whole style. See [REST's Uniform Interface constraint](https://ics.uci.edu/~fielding/pubs/dissertation/rest_arch_style.htm#sec_5_1_5).

Do not insist on HATEOAS for every HTTP API. If the requirements favor fixed operation calls or a simpler resource interface, describe that choice accurately and explain the coupling trade-off.

Where applicable, consider:

- content negotiation;
- media-type (or explicit) versioning over ad-hoc URL version sprawl;
- consistent, machine-readable error representations;
- caching (validators, cache-control) and its correctness;
- concurrency control (ETags / optimistic concurrency);
- pagination and filtering that are stable and discoverable;
- retry and idempotency semantics for unsafe operations;
- `202 Accepted` with a status resource for long-running/asynchronous processing.

## Guidance

- DO design the surface you can defend supporting for years.
- DO NOT remove, rename, or narrow a public member, reduce accessibility, or change a serialized shape without treating it as breaking.
- AVOID leaking internal types, mutable statics, or implementation detail across the public boundary.
- CONSIDER additive, opt-in evolution (new overloads/endpoints/fields) over in-place breaking changes.
