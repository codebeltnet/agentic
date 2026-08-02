# Console and worker functional tests

Use Codebelt's Generic Host application-entry-point abstraction. The application must expose a host that `ApplicationHostFactory` can resolve in-process.

## Focused factory ownership

Keep the test derived from `Test` and use:

```csharp
using var application = ApplicationTestFactory.Create<Program>(builder =>
{
    builder.ConfigureAppConfiguration((_, configuration) => configuration.AddInMemoryCollection(settings));
});

var service = application.Host.Services.GetRequiredService<WorkerMarker>();
```

Use this when a test needs its own configured host or isolated state.

## Shared fixture ownership

Derive from:

```csharp
ApplicationTest<Program, BlockingManagedApplicationFixture<Program>>
```

Pass the fixture and `ITestOutputHelper` to the base constructor. Override `ConfigureHost(IHostBuilder)` for configuration that must exist before the host starts.

## Host seam gate

Acceptable evidence includes Codebelt Bootstrapper `ConsoleProgram<TStartup>`, `MinimalConsoleProgram`, `WorkerProgram<TStartup>`, or `MinimalWorkerProgram`, or another entry point that builds an `IHost`/`IHostBuilder` discoverable by the Codebelt application host factory.

Do not introduce `Process.Start`, `dotnet run`, shell execution, port polling, or redirected console-process management as a fallback. When only tests are in scope and the executable has no Generic Host, report:

1. the current entry point and why no resolvable host exists;
2. the matching Codebelt Bootstrapper host base;
3. the production files that would need adaptation;
4. the test pattern that becomes available after adaptation.

