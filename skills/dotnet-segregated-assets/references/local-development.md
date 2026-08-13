# Local development topology

Preserve the ordinary fast edit/run/debug loop and add a second, opt-in, production-like topology. Developers keep authoring in `wwwroot`.

## Two launch surfaces, one source folder

Keep the application's existing `commandName: Project` profile unchanged. In ordinary Development, the web application serves `wwwroot` directly. For Cuemon, use `AppTagHelperOptions.BaseUrlMode = TagHelperBaseUrlMode.Automatic` with no external App `BaseUrl`, so the current request supplies the location.

The segregated launch surface owns the whole topology. Add a root `launchSettings.json` profile named `<ordinary-project-profile>.Assets` with `commandName: DockerCompose`; for example, `BingeKinLanding.WebApp` becomes `BingeKinLanding.WebApp.Assets`. Prefer the exact project-name `commandName: Project` profile, otherwise use the sole Project profile, and fall back to the `.csproj` stem when no unambiguous ordinary profile exists. Do not add a second project-level profile with the same name. Put the segregated App/CDN settings in the Compose web service environment. For Cuemon App assets, use `BaseUrlMode=Automatic`, host-only `BaseUrl=localhost:<app-port>`, and `Scheme=Http`. Configure a separate CDN origin only when a shared equivalent exists.

The local application and asset origin are HTTP. Never use protocol-relative `//localhost:<port>` or `https://localhost:<port>` values for an HTTP-only origin.

## Where every file goes

File placement is part of the contract, not a preference. The three Dockerfiles are Visual Studio Container Tools artifacts and live **beside the web `.csproj`**, exactly where `dotnet new` and the Container Tools "Add > Docker Support" gesture put them. The orchestration files live at the repository root because Compose builds from the root context and Visual Studio resolves the Compose launch surface there.

| File | Location | Required when |
| --- | --- | --- |
| `Dockerfile` | `<project-directory>/` | Always (artifact-first production image) |
| `LocalDevelopment.Dockerfile` | `<project-directory>/` | Always (`compose.assets.yml` builds the web service from it) |
| `Assets.Dockerfile` | `<project-directory>/` | Always (asset image; sits beside the `wwwroot` it copies) |
| `compose.assets.yml` | repository root | Always |
| `.dockerignore` | repository root | Always (the web build context is the repository root) |
| `docker-compose.dcproj` | repository root | Visual Studio one-click Compose only |
| `launchSettings.json` | repository root | Visual Studio one-click Compose only |

Never place a Dockerfile at the repository root for this topology. A root `Dockerfile` competes with Visual Studio Container Tools discovery, forces `Assets.Dockerfile` to reach across directories into the project's `wwwroot`, and breaks the per-service build contexts described below.

`docker-compose.dcproj` and the root `launchSettings.json` are a pair: the profile is what Visual Studio launches and the `.dcproj` is what makes Visual Studio read it, so add both or neither. `verify --check-local` reports a launch profile without a Compose project — and a Compose project without a launch profile — as an incomplete registration, and it also requires the segregated profile itself, so a repository that skips the pair entirely runs the topology from the command line and accepts that finding.

## Literal templates

The `assets/` directory holds the real file content. Read each template, substitute the placeholders, and write it to the location in the table above. Do not improvise these files from memory — the failure mode this prevents is an agent falling back to the familiar `mcr.microsoft.com/dotnet/sdk` multi-stage pattern, which is wrong for this topology.

| Template | Target |
| --- | --- |
| `assets/Dockerfile` | `<project-directory>/Dockerfile` |
| `assets/LocalDevelopment.Dockerfile` | `<project-directory>/LocalDevelopment.Dockerfile` |
| `assets/Assets.Dockerfile` | `<project-directory>/Assets.Dockerfile` |
| `assets/compose.assets.yml` | `compose.assets.yml` |
| `assets/.dockerignore` | `.dockerignore` |
| `assets/docker-compose.dcproj` | `docker-compose.dcproj` |
| `assets/launchSettings.json` | `launchSettings.json` |
| `assets/LocalPublishTarget.targets` | merged into the repository's `Directory.Build.targets` |
| `assets/ci-artifact-jobs.yml` | appended to the repository's CI workflow `jobs:` |

Placeholders resolve from repository evidence:

| Placeholder | Source | Example |
| --- | --- | --- |
| `{ProjectName}` | web project / assembly name | `BingeKinLanding.WebApp` |
| `{ProjectDirectory}` | repository-root-relative project directory, forward slashes | `src/BingeKinLanding.WebApp` |
| `{DotNetMajor}` | major version of the project's `TargetFramework` | `10` |
| `{AlpineVersion}` | Alpine version of the newest `dhi.io/aspnetcore:{DotNetMajor}-alpine<version>` tag available to the organization; the `alpine-base` stage uses the same value | `3.23` |
| `{WebImageName}` | lowercased, punctuation-stripped project name | `bingekinlandingwebapp` |
| `{AssetImageName}` | lowercased asset-image name derived from the same stem | `bingekinlandingassets` |
| `{WebHostPort}` | HTTP port of the ordinary Project profile's `applicationUrl` | `51642` |
| `{AppOriginPort}` | `app_origin_port` from `FORMS.md` | `8080` |
| `{ConfigSection}` | double-underscore form of the bound App options section | `SegregatedAssets__App` |
| `{SegregatedProfileName}` | `<ordinary-project-profile>.Assets` | `BingeKinLanding.WebApp.Assets` |
| `{ProjectGuid}` | a newly generated GUID | `c3a15218-20b0-467d-a20c-bba26e41f2a6` |

## Artifact-first Dockerfiles

Use three Dockerfiles with distinct responsibilities:

1. `Dockerfile` packages the CI-published application artifact into the newest compatible shell-less `dhi.io/aspnetcore` Alpine runtime. It is the production application image.
2. `LocalDevelopment.Dockerfile` packages the same artifact into the matching `dhi.io/aspnetcore:<channel>-alpine<version>-dev` runtime. The ASP.NET `-dev` image supplies development utilities and debugger prerequisites but is not a .NET SDK; host publishing is still required.
3. `Assets.Dockerfile` packages `wwwroot` into `codebeltnet/web-cdn-origin:2.0.0`. It is the asset image for local segregation and deployment.

Neither application Dockerfile compiles source. Both consist of `FROM`, `WORKDIR`, `COPY`, and `ENTRYPOINT` over an already-published artifact. Concretely, an application Dockerfile in this topology must not contain any of the following, and their presence is a defect rather than a style difference:

- a `FROM mcr.microsoft.com/dotnet/sdk...` (or any other SDK) stage, or a `dotnet restore`, `dotnet build`, or `dotnet publish` invocation;
- a `RUN addgroup`/`RUN adduser`/`RUN useradd` block — the DHI base images already run as UID `65532`, and the shell-less production base cannot execute `RUN` at all;
- an `mcr.microsoft.com/dotnet/aspnetcore` runtime tag, which is not the hardened base this topology targets and publishes no `-dev` variant;
- a `USER root` escalation, or an override of the base image's port, working directory, or runtime user without demonstrated evidence.

The production template keeps a small `dhi.io/alpine-base` stage whose only job is to assert that a CA certificate bundle exists and to hand it to the shell-less runtime, which has no shell to verify it in place.

Define `LocalPublishDirectory` in the web `.csproj` and add or reuse a guarded non-CI, non-design-time post-build publish target so an ordinary local build materializes the artifact both Dockerfiles copy. CI publishes to the same artifact path before building `Dockerfile`. The web project properties are:

```xml
<PropertyGroup>
  <DockerDefaultTargetOS>Linux</DockerDefaultTargetOS>
  <DockerComposeProjectPath>..\..\docker-compose.dcproj</DockerComposeProjectPath>
  <DockerfileContext>..\..</DockerfileContext>
  <LocalPublishDirectory>$([System.IO.Path]::GetFullPath('$(MSBuildProjectDirectory)\..\..\artifacts\publish\'))</LocalPublishDirectory>
</PropertyGroup>
```

The `..\..` segments are the relative path from the project directory back to the repository root; recompute them for the actual depth rather than copying two levels blindly. `DockerComposeProjectPath` and `DockerDefaultTargetOS` belong to the Visual Studio Compose path only, alongside a `Microsoft.VisualStudio.Azure.Containers.Tools.Targets` package reference. `LocalPublishDirectory` and `DockerfileContext` apply whenever `compose.assets.yml` exists, because the local web image is artifact-first regardless of which client starts it.

Add `artifacts/` to `.gitignore` so the local publish output stays out of version control, and do **not** add it to `.dockerignore` — both application Dockerfiles copy `artifacts/publish/` out of the build context.

## Compose owns local segregation

`compose.assets.yml` directly selects the local images. The web service builds `LocalDevelopment.Dockerfile`; the asset service builds `Assets.Dockerfile`. Do not introduce `DockerfileFile` or `BuildingInsideVisualStudio` to switch images indirectly.

The two services deliberately use **different build contexts**. The web service builds from the repository root so `COPY artifacts/publish/ .` resolves, and names its Dockerfile by repository-relative path. The asset service builds from the project directory so `COPY ./wwwroot/ /cdnroot/` resolves, and names its Dockerfile by bare filename.

```yaml
services:
  web-app:
    image: ${DOCKER_REGISTRY-}contosoweb
    build:
      context: .
      dockerfile: src/Contoso.Web/LocalDevelopment.Dockerfile
    depends_on:
      - app-assets
    environment:
      ASPNETCORE_ENVIRONMENT: Development
      ASPNETCORE_HTTP_PORTS: 8080
      SegregatedAssets__App__BaseUrl: localhost:8080
      SegregatedAssets__App__BaseUrlMode: Automatic
      SegregatedAssets__App__Scheme: Http
    ports:
      - "51642:8080"

  app-assets:
    labels:
      com.microsoft.visual-studio.project-name: ""
    image: ${DOCKER_REGISTRY-}contosoassets
    build:
      context: ./src/Contoso.Web
      dockerfile: Assets.Dockerfile
    read_only: true
    cap_drop:
      - ALL
    security_opt:
      - no-new-privileges:true
    ports:
      - "8080:8080"
```

Keep the service names `web-app` and `app-assets`; the `.dcproj`, the root launch profile's `serviceActions`, and the runner's checks all address services by those names. Omit the obsolete top-level `version:` key, which current Docker Compose warns about, and do not add a custom `networks:` block — Compose already places both services on a shared default network, and an extra network only adds a name to maintain.

### Deriving the ports

The Compose web service publishes on the **same host port as the ordinary Project profile's HTTP `applicationUrl`**. Ordinary Development and segregated Development then serve the application from one origin, so bookmarks, OAuth redirect registrations, cookie scopes, and `composeLaunchUrl` stay valid across both modes. Do not invent a round number such as `5000`.

The asset origin publishes on `app_origin_port` (`8080` by default) and a shared CDN origin, when one exists, on `cdn_origin_port` (`8081` by default). Resolve collisions against existing `launchSettings.json` and Compose files rather than shifting the application port.

Building `Assets.Dockerfile` deliberately snapshots `wwwroot`; rebuild Compose after asset edits. Use the ordinary Project profile when the fastest live-edit loop matters.

## Visual Studio Docker Compose launch

Register the topology with a `Microsoft.Docker.Sdk` `.dcproj`, set `DockerComposeBaseFilePath` to `compose.assets`, set `DockerDevelopmentMode` to `Regular`, associate the web project through `DockerComposeProjectPath`, and add the Compose project to the solution. Preserve an existing Compose project and its conventions rather than adding a second one.

Root launch settings:

```json
{
  "$schema": "https://json.schemastore.org/launchsettings.json",
  "profiles": {
    "Contoso.Web.Assets": {
      "commandName": "DockerCompose",
      "commandVersion": "1.0",
      "composeLaunchAction": "LaunchBrowser",
      "composeLaunchServiceName": "web-app",
      "composeLaunchUrl": "http://localhost:51642",
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

Because the web image is artifact-first, publish before the first Compose build when the local artifact does not exist yet:

```text
dotnet publish src/Contoso.Web/Contoso.Web.csproj -c Debug -o artifacts/publish
```

An ordinary `dotnet build` refreshes it afterwards through the guarded post-build target.

## Second origin for shared CDN assets

When a shared/CDN equivalent exists locally, build or mount it through a second hardened origin on another host port and configure `CdnTagHelperOptions` explicitly. Never let CDN helpers fall back to the App origin or copy shared content into application `wwwroot`. Resolve port collisions from repository evidence.

```yaml
  cdn-assets:
    labels:
      com.microsoft.visual-studio.project-name: ""
    image: ${DOCKER_REGISTRY-}contososharedassets
    build:
      context: ./shared-assets
      dockerfile: Assets.Dockerfile
    read_only: true
    cap_drop:
      - ALL
    security_opt:
      - no-new-privileges:true
    ports:
      - "8081:8080"
```

The web service then also carries `SegregatedAssets__Cdn__BaseUrl: localhost:8081`, `SegregatedAssets__Cdn__BaseUrlMode: Configured`, and `SegregatedAssets__Cdn__Scheme: Http`, and the root launch profile adds `"cdn-assets": "StartWithoutDebugging"`.

## Deterministic verification

`segregate-assets.cs verify --check-local` derives the root Docker Compose launch profile name from the ordinary Project profile and validates `compose.assets.yml`. In a multi-project repository it first correlates the Compose file to the selected project by the project directory its build entries name, and reports rather than borrows when the only asset-origin Compose files belong to sibling projects — a healthy topology next door must never stand in for the selected project's. It proves that the launch URL is HTTP, Compose supplies a scheme-safe localhost asset origin, the web service builds `LocalDevelopment.Dockerfile`, the asset service uses `Assets.Dockerfile` or an explicit read-only `/cdnroot` source, the asset service has the empty Visual Studio project-association label, and the origin is non-privileged without a Docker socket. It additionally proves the artifact-first contract: every Dockerfile sits beside the web project, no application Dockerfile carries an SDK stage or a `dotnet build`/`dotnet publish` step, a root `.dockerignore` exists without excluding `artifacts/`, the project declares `LocalPublishDirectory` with a guarded publish target behind it, Compose omits the obsolete `version:` key, and CI publishes the artifact both application Dockerfiles copy. `inspect` also reports when the only `wwwroot` source is ignored or untracked, because a clean checkout could not reproduce the asset image. The runner does not rewrite project or Compose files.
