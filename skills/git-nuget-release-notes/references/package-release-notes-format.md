# Package Release Notes Blueprint

This reference captures the normalized `PackageReleaseNotes.txt` shape used across the linked codebelt repositories.

## Core Shape

Each file is a cumulative history ordered newest first. Each release block uses this normalized structure:

```text
Version: 0.3.1
Availability: .NET 10, .NET 9 and .NET Standard 2.0

# ALM
- CHANGED Dependencies have been upgraded to the latest compatible versions for all supported target frameworks (TFMs)

# Breaking Changes
- REMOVED ...

# New Features
- ADDED ...

# Improvements
- EXTENDED ...

# Bug Fixes
- FIXED ...

# References
- Package.One
- Package.Two
```

## Section Order

Use sections in this order and omit empty ones:

1. `# ALM`
2. `# Breaking Changes`
3. `# New Features`
4. `# Improvements`
5. `# Bug Fixes`
6. `# References`

## Section Intent

`# ALM` - Release-engineering and package-maintenance facts. - Typical bullets cover dependency upgrades, supported TFM additions, or TFM removals. - ALM-only releases are normal and should not be padded with weaker sections.

`# Breaking Changes` - Consumer-visible incompatibilities. - Typical verbs: `REMOVED`, `RENAMED`, `MOVED`, `CHANGED`.

`# New Features` - Additive API or capability work. - Typical verb: `ADDED`.

`# Improvements` - Non-breaking enhancements and refinements. - Typical verbs: `CHANGED`, `EXTENDED`, `OPTIMIZED`, `DEPRECATED`, `REFACTORED`.

`# Bug Fixes` - Corrections to incorrect prior behavior. - Typical verb: `FIXED`.

`# References` - Plain package IDs only. - Use this only for umbrella/meta packages or when the repo already uses a references section for that package.

## Wording Pattern

- Start every bullet with an all-caps action verb.
- Follow the verb with the concrete subject: package, type, member, namespace, or behavior that changed.
- Prefer exact technical identifiers over vague prose.
- Avoid punctuation-heavy embellishment and avoid copying commit subjects verbatim.

Examples:

- `- ADDED AssemblyContext class in the Cuemon.Reflection namespace that provides filtered discovery of assemblies in the current application domain`
- `- CHANGED Dependencies have been upgraded to the latest compatible versions for all supported target frameworks (TFMs)`
- `- FIXED World class in the Cuemon.Globalization namespace where retrieving countries by code in GetStatisticalRegion was not included`

## Availability Rendering

Render frameworks in a human-readable list based on project order:

- `net10.0` -> `.NET 10`
- `net9.0` -> `.NET 9`
- `net8.0` -> `.NET 8`
- `netstandard2.1` -> `.NET Standard 2.1`
- `netstandard2.0` -> `.NET Standard 2.0`
- `net48` -> `.NET Framework 4.8`

Combine them with commas and `and`:

- `.NET 10 and .NET 9`
- `.NET 10, .NET 9 and .NET Standard 2.0`

## Historical Whitespace

Some historical files contain odd spaces or inconsistent `Version` headers. Treat those as legacy formatting noise.

- Normalize the block you are writing to `Version:` and `Availability:`
- Do not rewrite older blocks solely to clean up whitespace unless the user asked for a formatting pass
- Preserve older history below the new block to avoid unnecessary churn
