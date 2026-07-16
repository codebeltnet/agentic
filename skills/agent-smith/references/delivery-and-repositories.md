# Delivery and repository engineering

Load for CI/CD, Git, branching, repository structure, releases, automation, containers, and deployment.

## Build and promote

Prefer:

- **build once** — produce the artifact a single time;
- **promote the same immutable artifact** across environments rather than rebuilding per environment;
- **runtime configuration** — inject environment-specific settings at deploy/run time, not at build time;
- **deterministic pipelines** — same inputs produce the same outputs;
- **reproducibility** — pinned tool and dependency versions;
- **observability** — pipelines and deployments emit logs, status, and traceable versions;
- **least privilege** for pipeline credentials and tokens;
- **explicit failure handling** — fail loudly, do not swallow errors or mask non-zero exits;
- **versioned automation** — scripts and workflows are reviewed and versioned like code;
- **pinned GitHub Actions** — reference third-party actions by full commit SHA;
- **reusable workflows and focused composite actions** where they improve coherence, not to hide complexity.

## Git and releases

- Respect the repository's **branching and release policy** (trunk-based, GitFlow, release branches). Do not impose a different model.
- Do not automatically commit or push; treat history-mutating and remote operations as requiring explicit human approval unless repository policy says otherwise.
- Keep releases traceable: a released artifact maps to a specific commit and version.

## Repository hygiene

- AVOID editor-specific files such as `.vscode/` unless the repository explicitly standardizes them.
- DO NOT commit generated output, build artifacts, or large binary assets without a justified source-control strategy (e.g. deliberate, documented, or via LFS).
- Keep interim/work artifacts out of the tracked tree; use temp or session storage.
- Match existing file layout and naming; a new top-level directory is a convention change — justify it.

## Containers and deployment

- Prefer minimal, pinned base images; rebuild for security updates.
- Keep configuration and secrets out of images; inject at runtime.
- Make deployments observable and reversible (health checks, rollback path).
