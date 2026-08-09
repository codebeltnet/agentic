# WebApplicationFactory migration invariants

Before editing, create an inventory for every selected factory type and call site.

## Host construction

- the production entry point remains the composition root under test;
- environment name and content root;
- configuration sources, order, and key values;
- service additions, removals, replacement order, and scopes;
- TestServer configuration and any custom host builder behavior;
- whether host creation is lazy until `CreateClient`, `Server`, or `Services` is first used.
- whether the application entry point invokes and owns startup; do not treat a host that bypasses `Program.Main` as equivalent merely because endpoint tests pass.

Do not preserve behavior by copying the production composition root into the test project. `WebApplication.CreateBuilder`, `WebHostBuilder`, `HostBuilder`, `UseTestServer`, copied service registrations, or copied middleware are not substitutes for bootstrapping `TEntryPoint` through the chosen Codebelt abstraction.

## Client behavior

- base address;
- redirect and cookie handling;
- default headers;
- custom handlers;
- one client per test versus shared clients.

## Resource ownership

- sync/async factory disposal;
- client and response disposal;
- temporary directories/files;
- database/container/message-broker fixtures;
- environment variables or static state;
- fixture/collection parallelization boundaries.

## Selection rule

Prefer focused `WebApplicationTestFactory` ownership when the old test constructed a factory per method, passed varying settings, or owned temporary resources per test. Repeated focused setup may live in a narrow `Test`-derived harness when that harness preserves the same per-instance isolation and disposes its `IHostTest` and resources correctly. Prefer `WebApplicationTest<...>` when the old project used `IClassFixture<WebApplicationFactory<TEntryPoint>>` and its shared lifecycle is intentional.

For either ownership shape, use the entrypoint-owned `ManagedWebApplicationFixture<TEntryPoint>` and pass it explicitly to factories. Migrate deprecated `BlockingManagedWebApplicationFixture<TEntryPoint>` input; never emit it as a target.

After migration, search the authorized scope. Zero selected `WebApplicationFactory` identifiers is a completion gate, but it is not sufficient by itself: the chosen Codebelt pattern must be present, direct replacement-host construction must be absent, restore/build/test must pass, and lifecycle invariants must still hold. Enforce the web-pattern checks by rerunning `inspect-dotnet-tests.ps1` with `-ExpectedWebPattern Focused` or `-ExpectedWebPattern Shared`.
