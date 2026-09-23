# Delivery and repository engineering

Load for CI/CD, Git, branching, repository structure, releases, automation, containers, and deployment.

## Classify the delivery archetype first

Identify **Package** or **Application** before defining lifecycle boundaries. For a repository containing both, classify each deliverable separately; do not force one lifecycle onto the whole repository.

| Responsibility | Package | Application |
|----------------|---------|-------------|
| PR | Build, full tests, coverage, static analysis, and compatibility validation as applicable | Build, full tests, coverage, and static analysis |
| Release | Version, package, publish the immutable package artifact, and generate/publish documentation where applicable | Create/version the immutable deployable artifact and record its provenance |
| Deploy | Normally absent; consumers acquire the published package | Consume the already-produced release artifact and apply environment-specific runtime configuration; never compile or rebuild the product |

Keep build, release, and deploy as distinct responsibilities even if one workflow coordinates them. PR builds validate proposed changes; they are not automatically the release artifact. Build the release artifact once from the selected source, or promote an eligible PR artifact when policy and provenance permit. Test and identify the exact artifact that is published or deployed; never rebuild it separately per environment.

For packages, documentation hosting or an accompanying application may have its own deployment, but publishing a package does not imply a product deployment phase. Local task validation remains scoped to the requested change and repository authorization; this lifecycle table does not authorize an agent to run a full local test matrix.

## Build and promote

Prefer:

- **build once** - produce the artifact a single time;
- **promote the same immutable artifact** across environments rather than rebuilding per environment;
- **runtime configuration** - inject environment-specific settings at deploy/run time, not at build time;
- **deterministic pipelines** - same inputs produce the same outputs;
- **reproducibility** - pinned tool and dependency versions;
- **observability** - pipelines and deployments emit logs, status, and traceable versions;
- **least privilege** for pipeline credentials and tokens;
- **explicit failure handling** - fail loudly, do not swallow errors or mask non-zero exits;
- **versioned automation** - scripts and workflows are reviewed and versioned like code;
- **pinned GitHub Actions** - reference third-party actions by full commit SHA;
- **reusable workflows and focused composite actions** where they improve coherence, not to hide complexity.

Trace artifact identity by immutable version/digest and source commit. Verify it at each promotion, retain rollback artifacts, and fail if the expected artifact or required evidence is missing. A successful build log cannot substitute for tests, coverage, analysis, or compatibility checks that were skipped or suppressed. Apply the false-success principle from `core-principles.md` to every required stage.

## Git and releases

- Respect the repository's **branching and release policy** (trunk-based, GitFlow, release branches). Do not impose a different model.
- Where no repository policy exists, prefer **scaled trunk-based development**: a protected mainline, short-lived branches, small PRs, required checks, and frequent integration. Add release/support branches only for a concrete maintenance need. GitFlow is an established-policy option, not an equally preferred greenfield default.
- Do not automatically commit or push; treat history-mutating and remote operations as requiring explicit human approval unless repository policy says otherwise.
- Keep releases traceable: a released artifact maps to a specific commit and version.

## Repository-family scope and supported hosts

Use family conventions only when repository instructions, shared workflows, maintained templates, or documented ownership establish that the repository belongs to that family. Inspect the actual source of the rule; similarity of technology or naming alone is insufficient. Explicit local constraints remain more specific than family defaults.

Preserve required OS and runtime support through build, test, release, and automation choices. If the applicable family workflow promises Windows and Linux, a Linux-only replacement does not establish compliance even when it passes. Restore the required coverage or report the unsupported host and the policy decision needed. Do not invent a universal OS matrix or impose this family's tooling on unrelated repositories.

For automation runtime decisions, load `automation.md`; use its proportional command, PowerShell 7, and .NET defaults only after checking applicable policy and host constraints.

## Repository hygiene

- AVOID editor-specific files such as `.vscode/` unless the repository explicitly standardizes them.
- DO NOT commit generated output, build artifacts, or large binary assets without a justified source-control strategy (e.g. deliberate, documented, or via LFS).
- Keep interim/work artifacts out of the tracked tree; use temp or session storage.
- Match existing file layout and naming; a new top-level directory is a convention change - justify it.

## Containers and deployment

- Prefer minimal, pinned base images; security updates produce a new validated release artifact rather than a rebuild during deployment.
- Keep configuration and secrets out of images; inject at runtime.
- Make deployments observable and reversible (health checks, rollback path).
