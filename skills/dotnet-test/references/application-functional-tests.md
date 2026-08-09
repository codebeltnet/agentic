# Console and worker functional tests

Use Codebelt's Generic Host application-entry-point abstraction. The application must expose a host that `ApplicationHostFactory` can resolve in-process.

## Focused factory ownership

Keep the test derived from `Test` and use:

```csharp
using var application = ApplicationTestFactory.Create<Program>(builder =>
{
    builder.ConfigureAppConfiguration((_, configuration) => configuration.AddInMemoryCollection(settings));
}, new ManagedApplicationFixture<Program>());

var service = application.Host.Services.GetRequiredService<WorkerMarker>();
```

Use this when a test needs its own configured host or isolated state.

## Shared fixture ownership

Derive from:

```csharp
ApplicationTest<Program, ManagedApplicationFixture<Program>>
```

Pass the fixture and `ITestOutputHelper` to the base constructor. Override `ConfigureHost(IHostBuilder)` for configuration that must exist before the host starts.

Pass `ManagedApplicationFixture<Program>` explicitly for focused tests and use it as the shared fixture type. This keeps startup owned by the application entry point. Migrate any deprecated `BlockingManagedApplicationFixture<Program>` input; it is scheduled for removal and is never a valid generated target.

A repeated focused setup may be encapsulated in a narrow `Test`-derived harness. It must accept `ITestOutputHelper`, retain the `IHostTest`, and dispose that host test plus every owned resource in both the synchronous and asynchronous `Test` disposal hooks.

After migration, run `inspect-dotnet-tests.ps1` with `-ExpectedApplicationPattern Focused` or `-ExpectedApplicationPattern Shared`. A non-zero exit is a migration failure even when restore, build, and tests pass.

## Host seam gate

Acceptable evidence includes Codebelt Bootstrapper `ConsoleProgram<TStartup>`, `MinimalConsoleProgram`, `WorkerProgram<TStartup>`, or `MinimalWorkerProgram`, or another entry point that builds an `IHost`/`IHostBuilder` discoverable by the Codebelt application host factory.

Do not introduce `Process.Start`, `dotnet run`, shell execution, port polling, or redirected console-process management as a fallback. When only tests are in scope and the executable has no Generic Host, report:

1. the current entry point and why no resolvable host exists;
2. the matching Codebelt Bootstrapper host base;
3. the production files that would need adaptation;
4. the test pattern that becomes available after adaptation.
