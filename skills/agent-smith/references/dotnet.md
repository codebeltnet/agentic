# .NET

Load **only when .NET or C# is relevant.** Never impose this guidance on non-.NET work.

Follow the repository's own conventions first (target frameworks, analyzers, nullable settings, test framework, naming). This reference supplements those; it does not override them.

## API and language

- Follow established .NET API design conventions (naming, `Try`-patterns, `Async` suffixes, argument validation, `IDisposable`/`IAsyncDisposable` where ownership transfers).
- Enable and honour **nullable reference types**; do not annotate to silence warnings without meaning it.
- Prefer **immutable state** where practical; use records/`readonly` where they express intent.
- Use **parameter objects** when a method accumulates too many parameters or boolean flags.
- Use **extension methods** to enrich a type's usage, not to hide missing design.
- Apply **dependency injection at composition boundaries**, not as a reflex around every collaborator.

## Async, cancellation, disposal

- **Async correctness:** do not block on async (`.Result`, `.Wait()`); flow `async`/`await` end to end.
- **Cancellation:** accept and honour `CancellationToken` on I/O and long-running operations.
- **Disposal:** dispose what you own; use `using`/`await using`; do not dispose what you do not own.
- DO NOT add fake asynchronous implementations (e.g. `Task.FromResult` wrappers over synchronous work) without justification.

## Correctness and behaviour

- Preserve **public API compatibility**; evaluate source, binary, and behavioural impact (see `api-design-and-compatibility.md`).
- Respect **exception semantics**: throw the right type, preserve stack traces (`throw;`), and do not use exceptions for control flow.
- DO NOT catch exceptions without recovery, translation, a policy, or added meaningful context.
- Be explicit about **thread safety**: state it, and back it up; avoid shared mutable state without synchronization.

## Performance-adjacent

- Be aware of **allocation behaviour** on hot paths (boxing, closures, LINQ in tight loops, needless string concatenation), but do not micro-optimize without measurement (see `performance.md`).

## Documentation and examples

- Write **XML documentation** for public members: purpose, parameters, returns, exceptions, and defaults — not a restatement of the signature.
- Examples must use **real APIs** and compile where technically feasible. DO NOT invent members to make an example look nicer.

## Testing

- Prefer **xUnit** where the repository has not established another framework.
- Use the **Microsoft Testing Platform** where it aligns with repository policy.
- DO NOT wrap every dependency behind an interface solely to enable mocking; test real collaborations where practical (see `testing.md`).
