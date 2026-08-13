# Local development topology

Preserve the ordinary fast edit/run/debug loop and add a second, opt-in, production-like topology. Developers keep authoring in `wwwroot`.

## Two launch surfaces, one source folder

Keep the application's existing `commandName: Project` profile unchanged. In ordinary Development, the web application serves `wwwroot` directly. For Cuemon, use `AppTagHelperOptions.BaseUrlMode = TagHelperBaseUrlMode.Automatic` with no external App `BaseUrl`, so the current request supplies the location.

The segregated launch surface owns the whole topology. Add a root `launchSettings.json` profile named `<ordinary-project-profile>.Assets` with `commandName: DockerCompose`; for example, `BingeKinLanding.WebApp` becomes `BingeKinLanding.WebApp.Assets`. Prefer the exact project-name `commandName: Project` profile, otherwise use the sole Project profile, and fall back to the `.csproj` stem when no unambiguous ordinary profile exists. Do not add a second project-level profile with the same name. Put the segregated App/CDN settings in the Compose web service environment. For Cuemon App assets, use `BaseUrlMode=Automatic`, host-only `BaseUrl=localhost:<app-port>`, and `Scheme=Http`. Configure a separate CDN origin only when a shared equivalent exists.

The local application and asset origin are HTTP. Never use protocol-relative `//localhost:<port>` or `https://localhost:<port>` values for an HTTP-only origin.

## Artifact-first Dockerfiles

Use three Dockerfiles with distinct responsibilities:

1. `Dockerfile` packages the CI-published application artifact into the newest compatible shell-less `dhi.io/aspnetcore` Alpine runtime. It is the production application image.
2. `LocalDevelopment.Dockerfile` packages the same artifact into the matching `dhi.io/aspnetcore:<channel>-alpine<version>-dev` runtime. The ASP.NET `-dev` image supplies development utilities and debugger prerequisites but is not a .NET SDK; host publishing is still required.
3. `Assets.Dockerfile` packages `wwwroot` into `codebeltnet/web-cdn-origin:2.0.0`. It is the asset image for local segregation and deployment.

Neither application Dockerfile compiles source. Define `LocalPublishDirectory` in the web `.csproj` and add or reuse a guarded non-CI, non-design-time post-build publish target. CI publishes to the same artifact path before building `Dockerfile`.

## Compose owns local segregation

`compose.assets.yml` directly selects the local images. The web service builds `LocalDevelopment.Dockerfile`; the asset service builds `Assets.Dockerfile`. Do not introduce `DockerfileFile` or `BuildingInsideVisualStudio` to switch images indirectly.

```yaml
services:
  web-app:
    build:
      context: .
      dockerfile: src/Web/LocalDevelopment.Dockerfile
    depends_on:
      - app-assets
    environment:
      ASPNETCORE_ENVIRONMENT: Development
      ASPNETCORE_HTTP_PORTS: 8080
      SegregatedAssets__App__BaseUrl: localhost:8080
      SegregatedAssets__App__BaseUrlMode: Automatic
      SegregatedAssets__App__Scheme: Http
    ports:
      - "5080:8080"

  app-assets:
    build:
      context: ./src/Web
      dockerfile: Assets.Dockerfile
    labels:
      com.microsoft.visual-studio.project-name: ""
    read_only: true
    cap_drop:
      - ALL
    security_opt:
      - no-new-privileges:true
    ports:
      - "8080:8080"
```

Building `Assets.Dockerfile` deliberately snapshots `wwwroot`; rebuild Compose after asset edits. Use the ordinary Project profile when the fastest live-edit loop matters.

## Visual Studio Docker Compose launch

Register the topology with a `Microsoft.Docker.Sdk` `.dcproj`, set `DockerComposeBaseFilePath` to `compose.assets`, set `DockerDevelopmentMode` to `Regular`, associate the web project through `DockerComposeProjectPath`, and add the Compose project to the solution. Preserve an existing Compose project and its conventions rather than adding a second one.

Root launch settings:

```json
{
  "profiles": {
    "Web.Assets": {
      "commandName": "DockerCompose",
      "commandVersion": "1.0",
      "composeLaunchAction": "LaunchBrowser",
      "composeLaunchServiceName": "web-app",
      "composeLaunchUrl": "http://localhost:5080",
      "serviceActions": {
        "web-app": "StartDebugging",
        "app-assets": "StartWithoutDebugging"
      }
    }
  }
}
```

Set the Compose project as the startup project and select the derived `.Assets` profile for segregated F5. Set the web project as the startup project for ordinary non-containerized Development. Do not add a custom `vsdbg` volume when the development image lets Visual Studio resolve `/remote_debugger/linux-musl-x64/vsdbg` itself.

The empty `com.microsoft.visual-studio.project-name` label deliberately prevents Visual Studio from associating `app-assets` with the web project. Without it, Visual Studio can apply the web project's debugger bootstrap to every build-backed service, including one marked `StartWithoutDebugging`; a read-only Static Content Provider can then fail while the helper writes under `/tmp`, followed by a misleading attach error. Inspect the generated resolved Compose file under `obj/Docker` and confirm it contains the web service's debugger configuration but no generated override for `app-assets`. Do not add `docker-compose.vs.release.yml` for this topology.

Validate with a normal project build, `docker compose -f compose.assets.yml config`, installed Visual Studio MSBuild, and a two-container smoke test. For one-click debugging, also run F5 and require Visual Studio Run mode, `vsdbg --interpreter=vscode` with the application as its child, and HTTP 200 from both the web app and asset origin. A `.dcproj` build or Compose CLI smoke test alone is not IDE proof.

## Command-line use

The same full topology works outside Visual Studio:

```text
docker compose -f compose.assets.yml up --build
```

There is no separate project-level segregated profile. The Compose web service carries the required Development and origin configuration.

## Second origin for shared CDN assets

When a shared/CDN equivalent exists locally, build or mount it through a second hardened origin on another host port and configure `CdnTagHelperOptions` explicitly. Never let CDN helpers fall back to the App origin or copy shared content into application `wwwroot`. Resolve port collisions from repository evidence.

## Deterministic verification

`segregate-assets.cs verify --check-local` derives the root Docker Compose launch profile name from the ordinary Project profile and validates `compose.assets.yml`. It proves that the launch URL is HTTP, Compose supplies a scheme-safe localhost asset origin, the web service builds `LocalDevelopment.Dockerfile`, the asset service uses `Assets.Dockerfile` or an explicit read-only `/cdnroot` source, the asset service has the empty Visual Studio project-association label, and the origin is non-privileged without a Docker socket. `inspect` also reports when the only `wwwroot` source is ignored or untracked, because a clean checkout could not reproduce the asset image. The runner does not rewrite project or Compose files.
