# NuGet Library Variant Reference

Slim guide for scaffolding a NuGet library solution. All file templates live in `templates/library/`.

---

## Folder Structure

```
{REPO_SLUG}/
├── .nuget/
│   └── {PROJECT_NAME}/
│       ├── PackageReleaseNotes.txt
│       ├── icon.png                ← placeholder 128×128 PNG
│       └── README.md
├── src/
│   └── {PROJECT_NAME}/
│       └── {PROJECT_NAME}.csproj
├── test/
│   └── {PROJECT_NAME}.Tests/
│       └── {PROJECT_NAME}.Tests.csproj
├── tuning/
│   └── {PROJECT_NAME}.Benchmarks/
│       └── {PROJECT_NAME}.Benchmarks.csproj
├── Directory.Build.props
├── {REPO_SLUG}.slnx
└── (shared skeleton files — see shared-files.md)
```

---

## Template File Mapping

| Template                                  | Destination                                                        |
|-------------------------------------------|--------------------------------------------------------------------|
| `templates/library/Directory.Build.props` | `Directory.Build.props` (repo root)                                |
| `templates/library/source.csproj`         | `src/{PROJECT_NAME}/{PROJECT_NAME}.csproj`                         |
| `templates/library/test.csproj`           | `test/{PROJECT_NAME}.Tests/{PROJECT_NAME}.Tests.csproj`            |
| `templates/library/benchmark.csproj`      | `tuning/{PROJECT_NAME}.Benchmarks/{PROJECT_NAME}.Benchmarks.csproj`|
| `templates/library/PackageReleaseNotes.txt` | `.nuget/{PROJECT_NAME}/PackageReleaseNotes.txt`                  |
| `templates/library/nuget-readme.md`       | `.nuget/{PROJECT_NAME}/README.md`                                  |
| *(create manually)*                       | `.nuget/{PROJECT_NAME}/icon.png` — 128×128 PNG placeholder         |

---

## .slnx Template (inline — content varies per solution)

```xml
<Solution>
  <Folder Name="/src/">
    <Project Path="src/{PROJECT_NAME}/{PROJECT_NAME}.csproj" />
  </Folder>
  <Folder Name="/test/">
    <Project Path="test/{PROJECT_NAME}.Tests/{PROJECT_NAME}.Tests.csproj" />
  </Folder>
  <Folder Name="/tuning/">
    <Project Path="tuning/{PROJECT_NAME}.Benchmarks/{PROJECT_NAME}.Benchmarks.csproj" />
  </Folder>
</Solution>
```

Add a `/tooling/` folder when tooling projects exist.

---

## Additional Packages

Add library-specific packages to `Directory.Packages.props` (beyond the shared skeleton). Use framework-conditional groups for packages that ship different versions per TFM:

```xml
<ItemGroup Condition="$(TargetFramework.StartsWith('net9'))">
  <PackageVersion Include="Microsoft.Extensions.DependencyInjection.Abstractions" Version="{LATEST_9x}" />
</ItemGroup>
<ItemGroup Condition="$(TargetFramework.StartsWith('net10'))">
  <PackageVersion Include="Microsoft.Extensions.DependencyInjection.Abstractions" Version="{LATEST_10x}" />
</ItemGroup>
```

Always resolve `{LATEST_Nx}` from NuGet.org — never hardcode versions.

---

## Multi-project Guidance

For multiple library projects (e.g. core + extensions), repeat per project:

1. `src/{PROJECT_NAME}/` — source project (from `source.csproj` template)
2. `test/{PROJECT_NAME}.Tests/` — test project (from `test.csproj` template)
3. `tuning/{PROJECT_NAME}.Benchmarks/` — benchmark project (from `benchmark.csproj` template)
4. `.nuget/{PROJECT_NAME}/` — NuGet metadata (release notes, readme, icon)
5. Add each project to the `.slnx` under the appropriate folder

---

## Project References

- **Test → Source:** `<ProjectReference Include="..\..\src\{PROJECT_NAME}\{PROJECT_NAME}.csproj" />`
- **Benchmark → Source:** `<ProjectReference Include="..\..\src\{PROJECT_NAME}\{PROJECT_NAME}.csproj" />`
- **Extension → Core:** extension projects reference the core project via `<ProjectReference>`
