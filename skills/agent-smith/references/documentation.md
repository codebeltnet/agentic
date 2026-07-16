# Documentation

Load for public API documentation, README files, architecture documentation, guides, release notes, examples, and DocFX.

**Documentation is part of the product.** Wrong documentation is worse than none, because it is trusted.

## Requirements

Documentation must be:

- **accurate** — consistent with actual behaviour, not aspirational;
- **audience-aware** — written for the reader (consumer, operator, contributor), at their level;
- **concise** — no filler; respect the reader's time;
- **navigable** — findable, with structure and links that lead somewhere;
- **example-driven** — show real usage, not just prose;
- **version-aware** — states what version/behaviour it describes and flags version-specific notes;
- **consistent with the surface** — updated in the same change as the code it documents.

## Examples

- Examples must use **real APIs** and **compile where technically feasible**.
- DO NOT invent members, overloads, or options to make an example look cleaner. A compiling, honest example beats an elegant, fictional one.
- Show the consumer task the example solves before the code, so the reader knows why they would use it.

## Reference documentation

- DO NOT merely repeat the signature in prose. Explain **defaults, constraints, lifecycle, side effects, compatibility, and exceptions** where relevant.
- Document nullability, thread-safety, ownership/disposal, and cancellation where they matter.

## READMEs, guides, release notes

- A README should orient a newcomer: what it is, why they would use it, how to install, and a quick start that works.
- Guides should follow a real task end to end.
- Release notes should state what changed and, critically, **what consumers must do** — especially for breaking changes.

## Consistency

Match the repository's documentation conventions (tone, formatting, wrapping, DocFX layout). If the repo mandates natural paragraph flow, do not hard-wrap; if it uses a specific overwrite/layout structure, follow it rather than inventing a parallel one.
