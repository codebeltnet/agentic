---
name: trunk-first-repo
description: >
  Initialize a folder as a git repository following scaled trunk-based development.
  Sets up an empty main branch (seed commit only), creates a versioned feature branch,
  and enforces a PR-first workflow where content only reaches main through pull requests.
  Use this skill when the user wants to initialize a git repo, set up a new repository,
  start a project with proper git workflow, or mentions "trunk-based", "PR workflow",
  "branch protection", "git init", or wants to follow GitHub PR best practices.
  ALWAYS use this skill when asked to initialize or set up a git repository.
---

# Trunk-First Repo

Initialize a folder as a git repository following [scaled trunk-based development](https://trunkbaseddevelopment.com/#scaled-trunk-based-development). The core principle: **main is sacred** — it starts empty and content only enters through peer-reviewed pull requests from short-lived feature branches.

This matters because it prevents accidental pushes to main, establishes a clean PR-based workflow from day one, and makes the git history meaningful by design rather than as an afterthought.

## Workflow

### Step 1: Collect Parameters

Ask the user for these parameters before doing anything:

| Parameter | Prompt | Default |
|-----------|--------|---------|
| **Version prefix** | "What stage is this project? `v0.0.1` (PoC/experimental), `v0.1.0` (MVP), or `v1.0.0` (production-grade)?" | `v0.1.0` |
| **Branch context** | "Short context for this feature branch? (e.g. `init-api`, `add-auth`, `setup-infra`)" | `init` |
| **Remote origin** | "Remote URL? (skip if not ready yet)" | Skip |

#### Version Prefix Guide

The version prefix signals the project's maturity and intent:

| Prefix | Stage | When to use |
|--------|-------|-------------|
| `v0.0.1` | PoC / Experimental | Throwaway prototype, exploring an idea, not meant for production |
| `v0.1.0` | MVP | Building something real but still finding its shape — the most common starting point |
| `v1.0.0` | Production-grade | Confident in the API/contracts, ready for consumers to depend on it |

### Step 2: Initialize the Repository

Run these commands in order. Each step is intentional — don't skip or reorder:

```bash
# 1. Initialize git in the current directory
git init

# 2. Create an orphan main branch (no parent commit, completely empty)
git checkout --orphan main

# 3. Make sure nothing is staged (the orphan checkout may auto-stage files)
git rm -rf --cached . 2>/dev/null || true

# 4. Seed main with an empty commit — this is the only direct commit to main, ever
git commit --allow-empty -m "🌱 seed empty main branch"

# 5. Create and switch to the feature branch
git checkout -b {VERSION_PREFIX}/{BRANCH_CONTEXT}
```

After step 5, the user is on the feature branch (e.g. `v0.1.0/init`) with all their project files unstaged and ready for their first real commit.

### Step 3: Set Remote Origin (optional)

If the user provided a remote URL:

```bash
git remote add origin {REMOTE_URL}
git push -u origin main
```

If skipped, remind the user they can add it later:
> When you're ready, run: `git remote add origin <url>` followed by `git push -u origin main`

### Step 4: Summary

After initialization, display a summary:

```
✅ Repository initialized with trunk-first workflow

  main branch:    🌱 seeded (empty — content enters only via PRs)
  feature branch: v0.1.0/init (current — start working here)
  remote:         not configured (add later with `git remote add origin <url>`)

  Next steps:
  1. Stage and commit your files on this branch
  2. Push the feature branch and open a PR to main
  3. After review, merge the PR — main stays clean
```

## Conventions

### Branch Naming

Feature branches follow the pattern `v{MAJOR.MINOR.PATCH}/{context}`:

```
v0.1.0/init              ← MVP, initial setup
v0.0.1/spike-auth        ← PoC, exploring authentication
v1.0.0/release-prep      ← Production, preparing first release
v0.1.0/add-user-api      ← MVP, adding user API endpoints
```

The version prefix groups branches by project maturity. The context should be short, lowercase, and hyphen-separated — descriptive enough to understand at a glance.

### The Golden Rule

**Never commit directly to main.** After the seed commit, all changes reach main exclusively through pull requests. This ensures:

- Every change is peer-reviewed before merging
- Main is always in a known-good state
- The PR history tells the story of how the project evolved
- CI/CD pipelines validate changes before they land

### Working with This Workflow

Once initialized, the day-to-day workflow is:

1. **Create a feature branch** from main: `git checkout -b v0.1.0/my-feature main`
2. **Work and commit** on the feature branch
3. **Push and open a PR** to main
4. **Review, approve, and merge** the PR
5. **Delete the feature branch** after merge
6. **Pull main** and create the next feature branch

Feature branches should be short-lived — ideally merged within hours or a few days, not weeks.
