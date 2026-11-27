# Build inputs

This focused .NET 10 site uses the TokenBuilder implementation and example from Cuemon commit `544d368fb1d29effa30295fdfbe09dac26b9d0ec`. Published execution uses Cuemon.Data 11.0.0. The implementation is available locally for project-backed verification.

The documentation action generator imports `dotnet-csrun/scripts/sample-tools.ps1` beside its skill directory. For an isolated tool installation, use a private tools folder with the generator's skill tree and that sibling path. The helper is available as a single [pinned source file](https://raw.githubusercontent.com/codebeltnet/agentic/d45e6a658c657012d1ac049ffaed094814de9d12/skills/dotnet-csrun/scripts/sample-tools.ps1). Its SHA-256 before newline conversion is `a97726a331a5dd3b4430d470c48a5cf2fb5b5d110e179ec3232a819955a137d2`. Keep tool downloads outside the authored site.
