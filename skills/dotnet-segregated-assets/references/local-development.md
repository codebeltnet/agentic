# Local development topology

The goal is to preserve the ordinary fast edit/run/debug loop and add a second, opt-in way to run the application against the segregated production-like topology. Developers keep editing `wwwroot`; nothing about their normal Development profile changes.

## Two profiles, one source folder

Keep the application's existing Development launch profile exactly as it is. Add a new profile — `http-segregated-assets` (or the repository's equivalent naming pattern if one already exists) — that keeps the application in the Development environment but points App asset URLs at the local Static Content Provider instead of back at the application.

Prefer an **HTTP** application profile because the local origin is exposed over HTTP. That avoids the protocol-relative and mixed-content traps described in `references/app-vs-cdn.md`: an HTTP page requesting an `http://localhost:<port>` origin is consistent, whereas an HTTPS page requesting a protocol-relative `//localhost:<port>` URL becomes an HTTPS request against an HTTP-only origin and fails.

Example `Properties/launchSettings.json` profile (adapt the environment-variable keys to the application's real asset abstraction — the keys below are illustrative for an app without Cuemon):

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

For a Cuemon application, set the equivalent App options instead (`AppTagHelperOptions.BaseUrl = localhost:8080`, `Scheme = Http`), bound from these environment variables. When a CDN equivalent exists, add the matching CDN variables pointing at the second origin (`http://localhost:8081`).

A `commandName: Project` profile only launches the application and sets configuration; it does **not** start sidecar containers. Keep process orchestration explicit and deterministic — start the local origin separately (below). Do not claim the profile itself spins up the origin.

## Local Static Content Provider

Use the published image directly for local development — do not rebuild an asset image on every source edit. Mount the application's existing `wwwroot` into `/cdnroot` **read-only** so edits are visible immediately (the image serves physical files from `/cdnroot`, and its `CdnOrigin:ContentRoot` already defaults to `/cdnroot`).

Prefer a tiny dedicated Compose file when repository conventions permit, because relative bind mounts give a cross-platform, repeatable developer command. Name that dedicated file `compose.assets.yml` so it pairs with the derived `Assets.Dockerfile`. If the repository already has an established orchestration mechanism that can express the same topology cleanly, extend that instead of adding Compose.

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

When a CDN equivalent exists and its content is available locally, provision a **second** origin instance on a different host port from its own shared-asset root:

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

Resolve port collisions from the repository's existing configuration rather than blindly overwriting ports. If `8080`/`8081` are already used, pick free ports and keep the launch profile, Compose file, and any documentation consistent.

## Validating the local topology

`segregate-assets.cs verify --check-local` parses `launchSettings.json` and the Compose file and reports whether the segregated profile is HTTP, points at an `http://localhost:<port>` origin, avoids protocol-relative/`https://localhost` URLs, and whether the origin service uses the published image, a read-only `/cdnroot` mount, a read-only root filesystem, no privileged mode, and no Docker socket. Fix any finding it reports before considering the local topology done.
