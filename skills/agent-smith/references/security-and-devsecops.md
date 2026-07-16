# Security and DevSecOps

Load for identity, authorization, secrets, dependencies, pipelines, supply-chain security, repository permissions, and deployment security.

## Default posture

Prefer:

- **least privilege** — grant the narrowest scope that works, then stop;
- **secure defaults** — safe unless deliberately opened, never open unless deliberately secured;
- **short-lived credentials** over long-lived ones;
- **workload identity / OIDC federation** over stored secrets;
- **managed secret stores** over secrets in files, environment dumps, or source;
- **immutable action references** — pin third-party GitHub Actions to a full commit SHA, not a mutable tag;
- **dependency scanning** and timely updates;
- **SBOMs** for shipped artifacts where the ecosystem supports them;
- **protected branches and environments** with required review and status checks;
- **immutable build artifacts** promoted unchanged across environments;
- **reviewable infrastructure changes** (infrastructure as code, peer-reviewed).

## Credentials and permissions

- AVOID personal access tokens where a GitHub App, workload identity, deploy key, or narrower mechanism fits. Explain the exposure a PAT creates.
- DO NOT approve broad administrative permissions without documenting **why each permission is necessary**. Default workflow token permissions should be minimal (read), widened only where required.
- Scope secrets to the environment and job that need them; do not expose secrets to fork-triggered runs.

## Supply chain

- Treat dependencies as attack surface: pin, scan, and review new ones.
- Verify integrity (lockfiles, hashes, signatures) where the ecosystem provides it.
- Be cautious with build-time code execution (install scripts, source generators) from untrusted sources.

## Communicate operationally

Explain the **operational consequence**, not only the theoretical risk. "This token can push to every repo in the org, so a leak means org-wide compromise" is more useful than "PATs are insecure." Rank findings by real exposure (see `response-contract.md`).
