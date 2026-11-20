#requires -Version 7.0
# Documentation describes console.json (42), but this existing wrapper has drifted.
$manifest = @'
{
  "schemaVersion": 1,
  "mode": "console",
  "framework": "net10.0",
  "source": "using System;\nConsole.WriteLine(43);"
}
'@
$OutputEncoding = [Text.UTF8Encoding]::new($false)
$manifest | docker run --rm -i codebeltnet/csrun:10
$code = $LASTEXITCODE
if ($code -ne 0) { throw "csrun execution failed with exit code $code." }
