# Windows and PowerShell Benchmarking Notes

Use this reference when building or repairing skill benchmarks on
Windows, especially from PowerShell.

## UTF-8 Without BOM

Python JSON loaders and the Anthropic benchmark scripts expect normal
UTF-8 text. PowerShell defaults are not always safe for that.

Prefer explicit writes such as:

```powershell
$utf8NoBom = [System.Text.UTF8Encoding]::new($false)
[System.IO.File]::WriteAllText($path, $json, $utf8NoBom)
```

Do not assume `Set-Content`, redirection, or the shell default encoding
will produce no-BOM UTF-8 on every machine or shell version.

## Count Pipeline Results Safely

When using `Where-Object` followed by `.Count`, wrap the pipeline in
`@(...)` so the count is stable for zero, one, or many results.

```powershell
$passed = @($items | Where-Object { $_.passed }).Count
```

## Resolve Provider Paths Before .NET File APIs

If you feed PowerShell provider paths directly into .NET file APIs,
normalize them first:

```powershell
$resolved = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($path)
```

That avoids surprises when the working directory or provider path is not
what you think it is.

## Treat Native stderr Carefully

Some CLIs write warnings to stderr even when the exit code is zero.

- Capture the actual exit code.
- Do not assume "stderr means failure".
- If needed, invoke through a wrapper that preserves stdout/stderr and
  exposes the real process exit code.

## Keep Temp Paths Short

Deep temp paths plus nested benchmark folders can hit Windows path
limits. Use short workspace names such as:

```powershell
$workspace = Join-Path $env:TEMP 'skill-creator-agnostic-workspace'
```

## Common Failure Symptoms

- `aggregate_benchmark.py` shows zero runs:
  check `run-N/` layout first.
- `aggregate_benchmark.py` loads runs but reports zero pass rate:
  check `grading.json.summary`.
- Python throws JSON decode errors on otherwise normal files:
  suspect BOM or wrong encoding.
- The viewer shows outputs but the benchmark panel is empty:
  suspect aggregation inputs, not the viewer.
