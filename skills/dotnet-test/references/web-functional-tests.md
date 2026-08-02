# ASP.NET Core functional tests

Codebelt xUnit provides two application-entry-point patterns. Choose by ownership and sharing, not by test size.

## Focused factory ownership

Use `WebApplicationTestFactory` when a test or test method owns a separately configured application:

```csharp
using var application = WebApplicationTestFactory.Create<Program>(builder =>
{
    builder.UseEnvironment(Environments.Production);
    builder.ConfigureAppConfiguration((_, configuration) => configuration.AddInMemoryCollection(settings));
});
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
});
using var client = application.Host.GetTestClient();
```

The test must bootstrap the real `Program` entry point. Do not reproduce `Program` with `WebApplication.CreateBuilder`, `UseTestServer`, copied service registrations, or copied middleware in a test helper. Such a helper tests its own composition root and can remain green when the deployed entry point no longer works. A shared helper may prepare configuration values or temporary resources, but the test remains the visible owner of `WebApplicationTestFactory` and the returned host test.

## Shared xUnit fixture ownership

Use `WebApplicationTest<TEntryPoint,TFixture>` when all tests in a class share one initialized host:

```csharp
public class HealthTest : WebApplicationTest<Program, BlockingManagedWebApplicationFixture<Program>>
{
    public HealthTest(BlockingManagedWebApplicationFixture<Program> hostFixture, ITestOutputHelper output) : base(hostFixture, output)
    {
    }

    protected override void ConfigureWebHost(IWebHostBuilder builder)
    {
        builder.UseEnvironment(Environments.Production);
    }
}
```

`BlockingManagedWebApplicationFixture<TEntryPoint>` starts the resolved application host synchronously so `TestServer` is ready after fixture initialization. Configuration must be established before first start; do not rely on per-test mutation of a shared host.

## `WebApplicationFactory` mapping

| Existing surface | Codebelt focused mapping | Codebelt shared mapping |
|---|---|---|
| `ConfigureWebHost` override | `WebApplicationTestFactory.Create` callback | test `ConfigureWebHost` override or derived blocking fixture |
| `CreateClient()` | `application.Host.GetTestClient()` | `Host.GetTestClient()` or `Server.CreateClient()` |
| `Services` | `application.Host.Services` | `Host.Services` / `Server.Services` |
| factory disposal | dispose returned host test | xUnit disposes the class fixture |
| per-test settings | callback plus per-test owned state | separate fixture type/collection or keep focused ownership |

Do not force a shared fixture onto tests whose isolation depends on a fresh host or fresh temporary resource per method.

After migration, run `inspect-dotnet-tests.ps1` with `-ExpectedWebPattern Focused` or `-ExpectedWebPattern Shared` for the selected project. A non-zero exit is a migration failure even when restore, build, and tests pass.
