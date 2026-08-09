# Codebelt Bootstrapper host patterns

Use these patterns for fresh console/worker functional testing or when production bootstrap adaptation is explicitly authorized. Adapt the assets to repository conventions and behavior; asset files are literal examples with placeholders, not templates processed automatically.

## Console

- Startup model: `Program : ConsoleProgram<Startup>` and `Startup : ConsoleStartup`.
- Minimal model: `Program : MinimalConsoleProgram<Program>` (or the established non-generic `MinimalConsoleProgram`) and override `RunAsync`.
- The entry point builds and runs the host returned by `CreateHostBuilder(args)`.

Use `assets/bootstrapper/console/Program.cs` and `Startup.cs` for the Startup model.
Use `assets/bootstrapper/console-minimal/Program.cs` for the minimal model. Preserve the existing generic or non-generic base shape rather than changing it solely for tests.

## Worker

- Startup model: `Program : WorkerProgram<Startup>` and `Startup : WorkerStartup`.
- Minimal model: `Program : MinimalWorkerProgram`, register hosted services on the builder, build, and run.

Use `assets/bootstrapper/worker/Program.cs`, `Startup.cs`, and `Worker.cs` for the Startup model.
Use `assets/bootstrapper/worker-minimal/Program.cs` and adapt the existing worker registration for the minimal model.

## Web

- Startup model: preserve an established `WebProgram<TStartup>` and its existing web-startup pipeline.
- Minimal model: `Program : MinimalWebProgram`, configure the returned `WebApplicationBuilder`, build the application, map the existing pipeline/endpoints, and run it.

Use `assets/bootstrapper/web-minimal/Program.cs` for the minimal model. A `MinimalWebProgram` application is still an ASP.NET Core functional-test role: use the focused or shared web pattern, not `ApplicationTestFactory`.

## Pattern selection

Treat `MinimalConsoleProgram`, `MinimalWorkerProgram`, and `MinimalWebProgram` as complete Codebelt Generic Host seams. Do not rewrite them into Startup-based `ConsoleProgram`, `WorkerProgram`, or `WebProgram` applications merely to make tests possible. Likewise, do not convert an established Startup-based host to a minimal program as test cleanup.

## Scope boundary

Adopting a Bootstrapper NuGet package is a production application decision. Preserve an existing compatible Generic Host when it already satisfies Codebelt xUnit discovery. Add or change Bootstrapper packages only when application adaptation is explicitly in scope and the repository does not already establish another compatible Codebelt host pattern.
