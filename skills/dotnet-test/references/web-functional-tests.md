# ASP.NET Core functional tests

Codebelt xUnit provides two application-entry-point patterns. Choose by ownership and sharing, not by test size.

## Focused factory ownership

Use `WebApplicationTestFactory` when a test or test method owns a separately configured application:

```csharp
using var application = WebApplicationTestFactory.Create<Program>(builder =>
{
    builder.UseEnvironment(Environments.Production);
    builder.ConfigureAppConfiguration((_, configuration) => configuration.AddInMemoryCollection(settings));
}, new ManagedWebApplicationFixture<Program>());
using var client = application.Host.GetTestClient();
```

This maps naturally from tests that previously created a new `WebApplicationFactory<Program>` per method. Keep the test class derived from `Test`.

When a test also owns temporary content or another per-test resource, keep that resource beside the factory rather than replacing the factory with a custom host:

```csharp
using var content = new TempContent();
using var application = WebApplicationTestFactory.Create<Program>(builder =>
{
    builder.UseEnvironment(Environments.Production);
    builder.ConfigureAppConfiguration((_, configuration) => configuration.AddInMemoryCollection(CreateSettings(content.Root)));
}, new ManagedWebApplicationFixture<Program>());
using var client = application.Host.GetTestClient();
```

Pass `ManagedWebApplicationFixture<Program>` explicitly. Current factory defaults may preserve a deprecated blocking path that does not give `Program.Main` ownership of startup; a passing HTTP assertion does not prove the deployed entry point was exercised.

The test must bootstrap the real `Program` entry point. Do not reproduce `Program` with `WebApplication.CreateBuilder`, `UseTestServer`, copied service registrations, or copied middleware in a test helper. Such a helper tests its own composition root and can remain green when the deployed entry point no longer works.

When setup is repeated across many focused tests, a narrow `Test`-derived harness may own the factory result and temporary resources. Accept `ITestOutputHelper`, keep one harness per intended isolation scope, and expose a client/host rather than a second composition root. Override both `OnDisposeManagedResources` and `OnDisposeManagedResourcesAsync`: dispose the `IHostTest` and owned resources in each matching path, then call the base hook. Overriding only the synchronous hook is insufficient when callers use `await using`.

## Shared xUnit fixture ownership

Use `WebApplicationTest<TEntryPoint,TFixture>` when all tests in a class share one initialized host:

```csharp
public class HealthTest : WebApplicationTest<Program, ManagedWebApplicationFixture<Program>>
{
    public HealthTest(ManagedWebApplicationFixture<Program> hostFixture, ITestOutputHelper output) : base(hostFixture, output)
    {
    }

    protected override void ConfigureWebHost(IWebHostBuilder builder)
    {
        builder.UseEnvironment(Environments.Production);
    }
}
```

`ManagedWebApplicationFixture<TEntryPoint>` captures the host created by the application entry point and starts the deferred host when it is consumed. Configuration must be established before first consumption; do not rely on per-test mutation of a shared host. Migrate any deprecated `BlockingManagedWebApplicationFixture<TEntryPoint>` input; it is scheduled for removal and is never a valid generated target.

## `WebApplicationFactory` mapping

| Existing surface | Codebelt focused mapping | Codebelt shared mapping |
|---|---|---|
| `ConfigureWebHost` override | `WebApplicationTestFactory.Create` callback | test `ConfigureWebHost` override or derived managed fixture |
| `CreateClient()` | `application.Host.GetTestClient()` | `Host.GetTestClient()` or `Server.CreateClient()` |
| `Services` | `application.Host.Services` | `Host.Services` / `Server.Services` |
| factory disposal | dispose returned host test | xUnit disposes the class fixture |
| per-test settings | callback plus per-test owned state | separate fixture type/collection or keep focused ownership |

Do not force a shared fixture onto tests whose isolation depends on a fresh host or fresh temporary resource per method.

After migration, run `inspect-dotnet-tests.ps1` with `-ExpectedWebPattern Focused` or `-ExpectedWebPattern Shared` for the selected project. A non-zero exit is a migration failure even when restore, build, and tests pass.
