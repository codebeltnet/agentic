# WebApplicationFactory migration invariants

Before editing, create an inventory for every selected factory type and call site.

## Host construction

- environment name and content root;
- configuration sources, order, and key values;
- service additions, removals, replacement order, and scopes;
- TestServer configuration and any custom host builder behavior;
- whether host creation is lazy until `CreateClient`, `Server`, or `Services` is first used.

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

Prefer focused `WebApplicationTestFactory` ownership when the old test constructed a factory per method, passed varying settings, or owned temporary resources per test. Prefer `WebApplicationTest<...>` when the old project used `IClassFixture<WebApplicationFactory<TEntryPoint>>` and its shared lifecycle is intentional.

After migration, search the authorized scope. Zero selected `WebApplicationFactory` identifiers is a completion gate, but it is not sufficient by itself: restore/build/test must also pass and lifecycle invariants must still hold.

