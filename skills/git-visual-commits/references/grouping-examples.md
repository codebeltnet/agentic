# Commit grouping examples

#### Release-adjacent splitting rule

Do not treat "all of this supports the release" as one commit. Release-adjacent work often spans different audiences and lifecycle roles that deserve separate history:

- **Dependency/version baselines** — version alignment or runner baseline changes
- **Community health/release communication** — changelogs and human-facing repo health docs
- **Package/publish metadata** — package release-note definitions, `.nuget/*/PackageReleaseNotes.txt`, and publish targets; this bucket normally maps to `📦`
- **Documentation publishing** — DocFX navigation, branding, or publishing assets
- **CI/automation** — workflows and helper scripts used only by automation

These buckets are examples, not a fixed file map. The rule is the abstraction: split by purpose and audience, not by the fact that the changes landed together.

Concrete example: if one diff updates `Directory.Build.targets`, `Directory.Packages.props`, or `testenvironments.json`, another diff updates CI scripts or workflow files such as `bump-nuget.py` or `.github/workflows/*.yml`, and another diff updates `CHANGELOG.md` plus `.nuget/*/PackageReleaseNotes.txt`, that is at least three intents:

- **Build system / dependency baseline**
- **CI or automation**
- **Release communication plus package metadata**

Do not collapse those into one commit, even if they were edited in the same round and all support the same release. Keep `.nuget/*/PackageReleaseNotes.txt` with the `📦` package/publish commit, not with the `💬` community-health commit.

#### Repo-aligned grouping example

When a repo like this one mixes skill changes, scaffold assets, validators, and repo docs, split them by intent:

- **New repo-managed skill** — a newly introduced `skills/<name>/` folder and its local `evals/` or `references/`
- **Existing skill refactor** — extracting shared rules, renaming sections, or reorganizing an existing skill
- **Skill contract files** — `SKILL.md`, `FORMS.md`, `references/`, `evals/`
- **Template/runtime files** — `assets/`, scaffold helper scripts
- **Validation/tooling** — validator scripts, repo checks
- **Repo docs/rules** — `README.md`, `AGENTS.md`, `CONTRIBUTING.md`

Do not merge these into one commit unless the diff is truly single-purpose and the explanation still fits one sentence without using "and".

If a commit both introduces a brand-new skill and refactors an existing skill to support it, prefer separate commits. "Related" is not enough — the repo history should make it obvious which commit added the capability and which commit reorganized existing behavior around it.


#### Commit body guidance

Unless **no-body mode** is active, every commit includes a body explaining the *why*:

- **Config/environment commits** → explain the operational intent (e.g. "Switch to shared-runner testing strategy with multi-image matrix")
- **Test assertion changes** → explain why the expectation changed (e.g. "net11 changed the default precision for DateTime, updating expected value")
- **Refactors** → explain what motivated the restructuring
- **New features** → explain the purpose and scope
- **Bug fixes** → explain what was broken and how this fixes it

Common groupings:
- New repo-managed skill or workflow introduction together
- Existing skill refactor or extraction together
- Dependency/version baseline updates together
- Package/publish metadata together
- Config/setup files together (app host, bootstrapping)
- Environment and infrastructure config together (test runners, CI matrix, container settings)
- Documentation publishing fixes together
- Community health or release communication docs together
- New feature or module code together
- Data contracts, types, and interfaces together
- Database models, migrations, and schema changes together
- Test logic and assertions together (when they share the same rationale)
- Documentation and inline comments together

When in doubt, one commit per "thing that changes" is better than one big commit.


## Good Examples

```
🎉 begin api project
✨ add submission endpoint module
🐛 handle null optional fields in dto
➕ add validation library
🐛 fix: handle null optional fields in dto   ← only when combo mode was requested
```

## Bad Examples (and why)

```
feat: add submission endpoint            ← "feat:" is not an allowed prefix
✨ Feat: Add Submission Module            ← uppercase, "Feat:" not allowed
💬 Update CHANGELOG for v10.0.10          ← uppercase description beginning
💬  update changelog for v10.0.10         ← more than one separator space
📋 update changelog for v10.0.10          ← emoji is absent from the approved reference table
🎉 initial commit with all files         ← vague, bundles everything
⚙️ config: setup api                     ← "config:" is not an allowed prefix
♻️ refactor: reorganize skill wording    ← bad default if the user did not ask for the combo
```

