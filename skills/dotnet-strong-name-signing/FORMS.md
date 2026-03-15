# Parameter Form

Compute all defaults, present a single summary, and ask for confirmation. Only prompt for individual fields if the user wants to change something.

## Fields

### key_name
- **type:** text
- **computed_default:** Git repository root folder name (via `Split-Path -Leaf (git rev-parse --show-toplevel)`). Falls back to current folder name if not in a git repo.
- **description:** The `.snk` extension is added automatically. Typically matches the repository name.

### key_size
- **type:** single-choice
- **choices:** 1024 (default, matches sn.exe), 2048, 4096
- **default:** 1024

### output_dir
- **type:** text
- **computed_default:** Git repository root directory (via `git rev-parse --show-toplevel`). Falls back to current working directory if not in a git repo.
- **description:** Typically the repository root, so the key file lives alongside the solution file.

## Presentation Rules

1. Compute all defaults silently — do not ask each field one at a time.
2. Present a single summary showing all computed values and ask for confirmation:
   ```
   Ready to generate strong name key:
     File:     {key_name}.snk
     Key size: {key_size}-bit RSA
     Location: {output_dir}
   ```
3. If the user confirms, proceed immediately.
4. If the user wants to change a value, ask only for that specific field, then re-confirm.
