# Local development topology

The goal is to preserve the ordinary fast edit/run/debug loop and add a second, opt-in way to run the application against a segregated production-like topology. Developers keep editing `wwwroot`; ordinary Development must not be changed merely to support segregation.

## Two profiles, one source folder

Keep the application's existing Development launch profile exactly as it is. For a Cuemon application, configure `AppTagHelperOptions.BaseUrlMode = TagHelperBaseUrlMode.Automatic` in ordinary Development and do not provide an external App `BaseUrl`. The same `<app-link>`, `<app-script>`, and `<app-image>` markup then resolves against the application that is serving the page. Cuemon does not inspect launch-profile names.

Add a new profile — `http-segregated-assets` (or the repository's established equivalent) — that keeps `ASPNETCORE_ENVIRONMENT` set to `Development` but changes only the values that distinguish the segregated topology. In a Cuemon application, bind the existing `AppTagHelperOptions` with `BaseUrlMode = TagHelperBaseUrlMode.Automatic`, host-only `BaseUrl = localhost:<app-port>`, and `Scheme = ProtocolUriScheme.Http`. Bind `CdnTagHelperOptions` with `BaseUrlMode = TagHelperBaseUrlMode.Configured`, a separate host-only `BaseUrl = localhost:<cdn-port>`, and `Scheme = ProtocolUriScheme.Http` only when a shared CDN equivalent exists. Do not create a second asset configuration section when the application already binds these options.

The local App origin is HTTP, so the segregated application profile should also use HTTP. Never use a protocol-relative `//localhost:<port>` or `https://localhost:<port>` URL for an HTTP-only origin.

For an application without Cuemon, adapt the keys below to the suitable existing project abstraction. The example is not a reason to introduce this configuration hierarchy when another one already exists:

```json
{
  "profiles": {
    "http-segregated-assets": {
      "commandName": "Project",
      "dotnetRunMessages": true,
      "launchBrowser": true,
      "applicationUrl": "http://localhost:5080",
      "environmentVariables": {
        "ASPNETCORE_ENVIRONMENT": "Development",
        "SegregatedAssets__App__BaseUrl": "http://localhost:8080",
        "SegregatedAssets__App__Scheme": "Http"
      }
    }
  }
}
```

A `commandName: Project` profile only launches the application and sets configuration; it does not start sidecar containers. Keep process orchestration explicit and deterministic — start the local origin separately below. Do not claim that the profile itself spins up the origin.

## Local Static Content Provider

Use the published image directly for local development — do not rebuild an asset image on every source edit. Mount the application's existing `wwwroot` into `/cdnroot` **read-only** so edits are visible immediately. The image serves physical files from `/cdnroot`, and its `CdnOrigin:ContentRoot` already defaults to `/cdnroot`.

Prefer a tiny dedicated Compose file when repository conventions permit, because relative bind mounts provide a cross-platform, repeatable developer command. Name that file `compose.assets.yml` so it pairs with the derived `Assets.Dockerfile`. If the repository already has an orchestration mechanism that expresses the same topology cleanly, extend that instead of adding Compose.

Preserve the security posture the image supports wherever Docker permits: non-root runtime (the image already runs as user `65532`), a read-only content mount, a read-only root filesystem where practical, no privileged mode, no Docker socket mount, no unnecessary capabilities, and only the required host port exposed.

Example `compose.assets.yml` (App only):

```yaml
services:
  app-assets:
    image: codebeltnet/web-cdn-origin:2.0.0
    read_only: true
    cap_drop:
      - ALL
    security_opt:
      - no-new-privileges:true
    ports:
      - "8080:8080"
    volumes:
      - ./src/Web/wwwroot:/cdnroot:ro
```

Run it with `docker compose -f compose.assets.yml up`, then launch the application with the `http-segregated-assets` profile. Adapt the relative `./src/Web/wwwroot` path to the actual web project location.

## Second origin for CDN assets

When a CDN equivalent exists and its content is available locally, provision a **second** origin instance on a different host port from its own shared-asset root. Point the Cuemon CDN options at this origin explicitly; do not let CDN helpers fall back to the App origin:

```text
localhost:8080 -> web-cdn-origin:2.0.0 -> <app>/wwwroot
localhost:8081 -> web-cdn-origin:2.0.0 -> <shared-cdn-root>
```

```yaml
services:
  app-assets:
    image: codebeltnet/web-cdn-origin:2.0.0
    read_only: true
    cap_drop: [ALL]
    security_opt: ["no-new-privileges:true"]
    ports: ["8080:8080"]
    volumes:
      - ./src/Web/wwwroot:/cdnroot:ro
  cdn-assets:
    image: codebeltnet/web-cdn-origin:2.0.0
    read_only: true
    cap_drop: [ALL]
    security_opt: ["no-new-privileges:true"]
    ports: ["8081:8080"]
    volumes:
      - ../shared-assets:/cdnroot:ro
```

Resolve port collisions from the repository's existing configuration rather than blindly overwriting ports. If `8080`/`8081` are already used, choose free ports and keep the launch profile, Compose file, and documentation consistent. If no shared equivalent exists, omit the second service and all CDN-origin configuration.

## Validating the local topology

`segregate-assets.cs verify --check-local` parses `launchSettings.json` and the Compose file and reports whether the segregated profile is HTTP, points at an `http://localhost:<port>` origin, avoids protocol-relative/`https://localhost` URLs, and whether the origin service uses the published image, a read-only `/cdnroot` mount, a read-only root filesystem, no privileged mode, and no Docker socket. It does not rewrite the launch profile or Compose file. Fix any finding it reports before considering the local topology done.
