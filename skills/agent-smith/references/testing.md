# Testing

Load for test design, test review, regression work, and functional, integration, or contract testing.

## Purpose

Tests exist to provide **confidence that behaviour is correct**, not to inflate coverage numbers. A test that cannot fail for a real defect is noise.

## Choose the lowest-cost test that can catch the defect

Prefer the cheapest test that reliably detects the relevant failure, while keeping enough boundary and functional coverage:

- unit tests for logic and edge cases;
- integration tests for real collaborations and wiring;
- contract tests for cross-boundary agreements;
- functional/end-to-end tests for the behaviour a user actually depends on.

Do not push everything to the slowest tier, and do not unit-test away a risk that only integration can catch.

## Qualities of a good test

- **Deterministic** — no reliance on timing, ordering, network flakiness, or ambient state.
- **Diagnostic** — when it fails, the failure message points at the cause.
- **Readable** — intent is obvious; the test documents the behaviour.
- **Explicit about intent** — arrange/act/assert (or given/when/then) is clear.
- **Isolated where appropriate** — independent of other tests' side effects.
- **Fast enough for its tier** — matched to how often it runs.

## Do not

- DO NOT over-mock. Mocking everything tests the mocks, not the system. Mock at real seams (I/O, time, external services), not every collaborator.
- DO NOT copy implementation logic into the test; assert against expected results, not a re-derivation.
- DO NOT weaken an assertion just to make a test pass. Change an assertion only when the **prior expectation was actually wrong**, and say so.

## Regression

A fixed defect should normally receive a regression test that fails before the fix and passes after. Write that test first when practical, so the fix is proven.

## Reviewing tests

Ask: What real defect would this catch? If the answer is "none," the test is decoration. Flag tests that assert on incidental detail (call counts, private state) rather than observable behaviour.
