# Architecture

Load for system design, boundaries, distributed systems, integration, DDD, CQRS, event-driven architecture, deployment topology, and migration strategy.

## Reason Outside-In

Start from actors and use cases, then work inward to components and data. Let the required behaviour and boundaries drive the structure — not a template of folders.

Focus on the boundaries that actually govern behaviour:

- actors and use cases;
- system boundaries;
- ownership boundaries (who is the source of truth);
- trust boundaries (where authorization and validation must happen);
- consistency boundaries (where strong vs eventual consistency applies);
- transactional boundaries (what commits together);
- failure boundaries (what can fail independently);
- deployment boundaries (what ships and scales together);
- dependency direction (which way dependencies are allowed to point).

## Distributed and integration concerns

When components communicate across a process or network boundary, address explicitly:

- idempotency;
- retries and their safety;
- ordering guarantees (and their absence);
- duplicate delivery;
- timeouts;
- backpressure;
- partial failure;
- observability (logs, metrics, traces, correlation);
- recovery and compensation.

A design that ignores duplicate delivery, partial failure, or timeouts is incomplete, not simpler.

## Patterns are structure, not decoration

DO NOT use Onion, Clean, Hexagonal, DDD, CQRS, or event-driven architecture as **decorative folder structures**. Adopt a pattern only when its problem is present, and then honour its actual invariants:

- **Layered/Onion/Clean/Hexagonal** — the point is dependency direction and testable boundaries, not a folder named `Domain`. If dependencies still point the wrong way, the pattern is cosmetic.
- **DDD** — earns its place when the domain is complex enough to need a shared model and language. Aggregates exist to protect invariants and transactional boundaries, not to rename entities.
- **CQRS** — separate read and write models only when their requirements genuinely diverge. It adds moving parts; do not adopt it for symmetry.
- **Event-driven** — choose it for decoupling, buffering, or integration, and then design for ordering, duplication, replay, and schema evolution. Events are a contract.

## Migration and topology

- Prefer reversible, incremental migration over big-bang rewrites when existing consumers or data are at stake.
- Make deployment topology follow failure and scaling boundaries, not org-chart convenience.
- Justify every new distributed component, queue, cache, or datastore against the requirement it serves. A monolith with clear internal boundaries is often the correct answer.

CONSIDER writing a short decision record (see `decision-framework.md`) for boundary choices that are expensive to reverse.
