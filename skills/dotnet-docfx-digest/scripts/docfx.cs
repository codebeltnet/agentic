#:property TargetFramework=net10.0
#:property Nullable=enable
#:property LangVersion=latest
#:property PublishAot=false
#:package System.Reflection.MetadataLoadContext@9.0.0

using System.Diagnostics;
using System.Reflection;
using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;
using System.Text.RegularExpressions;
using System.Threading.Tasks;
using System.Xml.Linq;

return DocfxValidator.Run(args);

internal static class DocfxValidator
{
    private const string ScriptId = "validate-docfx-digest";
    private const string StartMarker = "<!-- dotnet-docfx-digest:start -->";
    private const string EndMarker = "<!-- dotnet-docfx-digest:end -->";
    private const string ExtensionAttributeFullName = "System.Runtime.CompilerServices.ExtensionAttribute";
    private const string SkipMarker = "dotnet-docfx-digest:skip-compile";

    private static readonly string[] IgnoredDirectorySegments = ["bin", "obj", "_site", ".git", ".vs", ".vscode", ".idea", "node_modules"];
    private static readonly TimeSpan ProcessTimeout = TimeSpan.FromMinutes(10);
    private static readonly TimeSpan ProcessStreamDrainTimeout = TimeSpan.FromSeconds(5);

    private static readonly JsonSerializerOptions JsonOptions = new()
    {
        WriteIndented = true,
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
        DefaultIgnoreCondition = JsonIgnoreCondition.WhenWritingNull
    };

    public static int Run(string[] args)
    {
        Options options;
        try
        {
            if (!TryParse(args, out options, out var parseError, out var wantHelp))
            {
                if (wantHelp)
                {
                    PrintUsage();
                    return 0;
                }

                Console.Error.WriteLine($"{ScriptId}: {parseError}");
                return (int)ExitCode.InvalidArguments;
            }

            if (options.Help)
            {
                PrintUsage();
                return 0;
            }
        }
        catch (Exception ex)
        {
            Console.Error.WriteLine($"{ScriptId}: argument parsing failed: {ex.Message}");
            return (int)ExitCode.InvalidArguments;
        }

        try
        {
            return Validate(options);
        }
        catch (Exception ex)
        {
            if (options.Json)
            {
                var report = new Report { Script = ScriptId, Status = "failed" };
                report.Errors.Add(new Diagnostic("INTERNAL_ERROR", null, null, $"Unexpected internal error: {ex.Message}"));
                Console.WriteLine(JsonSerializer.Serialize(report, JsonOptions));
            }
            else
            {
                Console.Error.WriteLine($"{ScriptId}: unexpected internal error: {ex}");
            }

            return (int)ExitCode.InternalError;
        }
    }

    private static int Validate(Options options)
    {
        var report = new Report { Script = ScriptId };

        // 1. Resolve repository root.
        string repoRoot;
        try
        {
            repoRoot = Path.GetFullPath(string.IsNullOrWhiteSpace(options.RepoRoot) ? "." : options.RepoRoot);
        }
        catch (Exception ex)
        {
            return Emit(options, report, ExitCode.RepoRootMissing, $"Invalid repository root: {ex.Message}");
        }

        report.RepoRoot = repoRoot;
        if (!Directory.Exists(repoRoot))
        {
            return Emit(options, report, ExitCode.RepoRootMissing, $"Repository root does not exist: {repoRoot}");
        }

        // 2. Locate the DocFX configuration file.
        var docfxPath = ResolveDocfxPath(repoRoot, options.DocfxPath);
        if (docfxPath is null)
        {
            report.Errors.Add(new Diagnostic("DOCFX_CONFIG_MISSING", null, null,
                "No DocFX configuration file (docfx.json) was found. Looked under .docfx/docfx.json and the repository root."));
            return Emit(options, report, ExitCode.DocfxConfigMissing, "DocFX configuration file not found.");
        }

        report.DocfxPath = docfxPath;
        var docfxWorkspace = Path.GetDirectoryName(docfxPath)!;
        options.Framework ??= ResolveDefaultFramework(docfxPath, report);
        CleanupGeneratedMetadata(repoRoot, docfxPath, docfxWorkspace, options, report);
        ValidateApiOverwriteLayout(repoRoot, docfxPath, docfxWorkspace, report);

        // 3. Verify AGENTS.md contains the managed block.
        var agentsPath = Path.Combine(repoRoot, "AGENTS.md");
        if (!AgentsBlockPresent(agentsPath))
        {
            report.Errors.Add(new Diagnostic("AGENTS_BLOCK_MISSING", agentsPath, null,
                "AGENTS.md does not contain the dotnet-docfx-digest managed block. Run scripts/agents.cs first."));
        }

        // Optional changed-only scoping.
        HashSet<string>? changedFiles = null;
        if (options.ChangedOnly)
        {
            changedFiles = GetChangedFiles(repoRoot, report);
            if (changedFiles is null)
            {
                report.Warnings.Add(new Diagnostic("CHANGED_ONLY_FALLBACK", null, null,
                    "git was unavailable or the repository has no HEAD; falling back to full validation."));
            }
        }

        // 4. Build the repository before metadata inspection.
        var (buildOk, buildOutput) = BuildRepository(repoRoot, options.Configuration);
        if (!buildOk)
        {
            report.Errors.Add(new Diagnostic("BUILD_FAILED", null, null,
                $"dotnet build failed (configuration {options.Configuration}).\n{Trim(buildOutput)}"));
            return Emit(options, report, ExitCode.BuildFailed, "Build failed.");
        }

        // 5-7. Discover public API, namespaces and extension methods from compiled metadata.
        var projects = DiscoverProjects(repoRoot);
        var libraryProjects = projects.Where(p => !p.IsTest).ToList();
        ApiModel api;
        try
        {
            api = DiscoverApi(libraryProjects, options.Configuration, options.Framework, report);
        }
        catch (Exception ex)
        {
            report.Errors.Add(new Diagnostic("PUBLIC_API_DISCOVERY_FAILED", null, null,
                $"Public API discovery failed: {ex.Message}"));
            return Emit(options, report, ExitCode.PublicApiDiscoveryFailed, "Public API discovery failed.");
        }

        if (api.Namespaces.Count == 0)
        {
            report.Errors.Add(new Diagnostic("PUBLIC_API_DISCOVERY_FAILED", null, null,
                "No public API could be discovered from the compiled library assemblies. Ensure the repository builds and exposes public types."));
            return Emit(options, report, ExitCode.PublicApiDiscoveryFailed, "Public API discovery failed.");
        }

        report.Summary.PublicNamespaces = api.Namespaces.Count;
        report.Summary.RequiredExampleTargets = api.RequiredExampleTargets.Count;
        report.Summary.ExtensionMethods = api.Namespaces.Sum(n => n.ExtensionMethods.Count);

        // 8. Discover DocFX Markdown files from the DocFX build inputs.
        var markdownFiles = DiscoverMarkdown(repoRoot, docfxPath, docfxWorkspace, report);

        // 9-11. Validate namespace overview pages, extension tables and availability.
        foreach (var ns in api.Namespaces.OrderBy(n => n.Name, StringComparer.Ordinal))
        {
            var page = markdownFiles.FirstOrDefault(f =>
                string.Equals(Path.GetFileNameWithoutExtension(f), ns.Name, StringComparison.Ordinal));

            if (page is null)
            {
                report.Errors.Add(new Diagnostic("NAMESPACE_PAGE_MISSING", null, ns.Name,
                    $"Missing namespace overview page for namespace {ns.Name}. Expected a file named {ns.Name}.md under {Rel(repoRoot, docfxWorkspace)}."));
                continue;
            }

            if (options.ChangedOnly && changedFiles is not null && !ShouldValidateNamespacePage(page, changedFiles))
            {
                continue;
            }

            ValidateNamespacePage(repoRoot, page, ns, report);
            report.Summary.NamespacePagesValidated++;
        }

        // 12. Verify mandatory examples exist before compiling the examples that were found.
        ValidateRequiredExamples(repoRoot, docfxWorkspace, markdownFiles, api, options, changedFiles, report);

        // 13. Extract and compile C# documentation samples.
        if (options.ValidateSamples)
        {
            ValidateSamples(repoRoot, markdownFiles, libraryProjects, options, changedFiles, report);
        }

        // Optional DocFX build verification happens in a temp copy so generated output never lands in the working tree.
        if (options.VerifyDocfxBuild)
        {
            VerifyDocfxBuild(repoRoot, docfxPath, report);
        }

        // 14-15. Produce report and return a deterministic exit code.
        bool hasSampleError = report.Errors.Any(e => e.Code is "SAMPLE_COMPILE_FAILED");
        bool hasOtherError = report.Errors.Any(e => e.Code is not "SAMPLE_COMPILE_FAILED");

        report.Status = report.Errors.Count == 0 ? "passed" : "failed";
        report.Summary.Errors = report.Errors.Count;
        report.Summary.Warnings = report.Warnings.Count;

        if (hasOtherError)
        {
            return Emit(options, report, ExitCode.ValidationFailed, "Validation failed.");
        }

        if (hasSampleError)
        {
            return Emit(options, report, ExitCode.SampleCompilationFailed, "Sample compilation failed.");
        }

        return Emit(options, report, ExitCode.Success, "Validation passed.");
    }

    // ----------------------------------------------------------------------
    // DocFX discovery
    // ----------------------------------------------------------------------

    private static string? ResolveDocfxPath(string repoRoot, string? explicitPath)
    {
        if (!string.IsNullOrWhiteSpace(explicitPath))
        {
            var full = Path.GetFullPath(explicitPath, repoRoot);
            return File.Exists(full) ? full : null;
        }

        var conventional = Path.Combine(repoRoot, ".docfx", "docfx.json");
        if (File.Exists(conventional))
        {
            return conventional;
        }

        var atRoot = Path.Combine(repoRoot, "docfx.json");
        if (File.Exists(atRoot))
        {
            return atRoot;
        }

        // Fall back to the first docfx.json found anywhere under the repo (excluding build output).
        foreach (var file in EnumerateFiles(repoRoot, "docfx.json"))
        {
            return file;
        }

        return null;
    }

    private static void ValidateApiOverwriteLayout(string repoRoot, string docfxPath, string docfxWorkspace, Report report)
    {
        var apiDirectory = Path.Combine(docfxWorkspace, "api");
        var namespacesDirectory = Path.Combine(apiDirectory, "namespaces");
        bool shouldValidateConvention =
            PathsEqual(docfxWorkspace, Path.Combine(repoRoot, ".docfx")) ||
            Directory.Exists(namespacesDirectory) ||
            Directory.Exists(apiDirectory);

        if (!shouldValidateConvention)
        {
            return;
        }

        JsonDocument doc;
        try
        {
            doc = JsonDocument.Parse(File.ReadAllText(docfxPath), new JsonDocumentOptions
            {
                AllowTrailingCommas = true,
                CommentHandling = JsonCommentHandling.Skip
            });
        }
        catch (Exception ex) when (ex is IOException or JsonException)
        {
            report.Warnings.Add(new Diagnostic("API_OVERWRITE_CONFIG_UNREADABLE", docfxPath, null,
                $"Unable to validate the DocFX overwrite layout: {ex.Message}"));
            return;
        }

        using (doc)
        {
            if (!doc.RootElement.TryGetProperty("build", out var build) || build.ValueKind != JsonValueKind.Object)
            {
                return;
            }

            var contentFiles = ReadDocfxBuildPatterns(build, "content", "files");
            var contentExclude = ReadDocfxBuildPatterns(build, "content", "exclude");
            var overwriteFiles = ReadDocfxBuildPatterns(build, "overwrite", "files");

            var configProblems = new List<string>();
            if (contentFiles.Any(pattern => DocfxPatternEquals(pattern, "api/**/*.md") || DocfxPatternEquals(pattern, "api/namespaces/**/*.md")))
            {
                configProblems.Add("Do not include `api/**/*.md` or `api/namespaces/**/*.md` under `build.content`.");
            }

            if (!contentExclude.Any(pattern => DocfxPatternEquals(pattern, "api/namespaces/**")))
            {
                configProblems.Add("Add `api/namespaces/**` to the `build.content` exclusions.");
            }

            if (!overwriteFiles.Any(pattern => DocfxPatternEquals(pattern, "api/namespaces/**/*.md")))
            {
                configProblems.Add("Include `api/namespaces/**/*.md` under `build.overwrite`.");
            }

            if (overwriteFiles.Any(pattern => DocfxPatternEquals(pattern, "api/**/*.md")))
            {
                configProblems.Add("Do not include `api/**/*.md` under `build.overwrite`.");
            }

            if (configProblems.Count > 0)
            {
                report.Errors.Add(new Diagnostic("API_OVERWRITE_CONFIG_INVALID", docfxPath, null,
                    $"DocFX API overwrite Markdown must use the namespace-folder convention so overwrite content merges into managed API pages without being treated as normal content. {string.Join(" ", configProblems)}"));
            }
        }

        if (!Directory.Exists(apiDirectory))
        {
            return;
        }

        foreach (var file in Directory.EnumerateFiles(apiDirectory, "*.md", SearchOption.TopDirectoryOnly)
                     .Where(path => !string.Equals(Path.GetFileName(path), "toc.md", StringComparison.OrdinalIgnoreCase)))
        {
            var destination = Rel(repoRoot, Path.Combine(namespacesDirectory, Path.GetFileName(file)));
            report.Errors.Add(new Diagnostic("API_OVERWRITE_FILE_MISPLACED", file, null,
                $"Authored API overwrite Markdown must not live directly under `{Rel(repoRoot, apiDirectory)}`. Move this file to `{destination}` and keep its YAML front matter and Markdown content intact. Do not move generated `.yml` metadata files."));
        }
    }

    private static List<string> ReadDocfxBuildPatterns(JsonElement build, string propertyName, string nestedPropertyName)
    {
        var patterns = new List<string>();
        if (!build.TryGetProperty(propertyName, out var entries))
        {
            return patterns;
        }

        foreach (var entry in EnumerateDocfxFileMappingEntries(entries))
        {
            if (entry.ValueKind == JsonValueKind.String)
            {
                if (string.Equals(nestedPropertyName, "files", StringComparison.Ordinal))
                {
                    patterns.Add(entry.GetString() ?? string.Empty);
                }

                continue;
            }

            if (entry.ValueKind == JsonValueKind.Object &&
                entry.TryGetProperty(nestedPropertyName, out var nested))
            {
                patterns.AddRange(ReadDocfxGlobPatterns(nested));
            }
        }

        return patterns;
    }

    private static bool DocfxPatternEquals(string actual, string expected)
    {
        return string.Equals(NormalizeDocfxPattern(actual), NormalizeDocfxPattern(expected), StringComparison.OrdinalIgnoreCase);
    }

    private static string NormalizeDocfxPattern(string pattern)
    {
        return (pattern ?? string.Empty)
            .Replace('\\', '/')
            .Trim();
    }

    private static string? ResolveDefaultFramework(string docfxPath, Report report)
    {
        try
        {
            using var doc = JsonDocument.Parse(File.ReadAllText(docfxPath), new JsonDocumentOptions
            {
                AllowTrailingCommas = true,
                CommentHandling = JsonCommentHandling.Skip
            });

            if (!doc.RootElement.TryGetProperty("metadata", out var metadata))
            {
                return null;
            }

            var frameworks = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
            foreach (var entry in EnumerateMetadataEntries(metadata))
            {
                if (entry.ValueKind != JsonValueKind.Object ||
                    !entry.TryGetProperty("properties", out var properties) ||
                    properties.ValueKind != JsonValueKind.Object ||
                    !properties.TryGetProperty("TargetFramework", out var tfm) ||
                    tfm.ValueKind != JsonValueKind.String)
                {
                    continue;
                }

                var value = tfm.GetString();
                if (!string.IsNullOrWhiteSpace(value))
                {
                    frameworks.Add(value.Trim());
                }
            }

            if (frameworks.Count == 1)
            {
                return frameworks.First();
            }

            if (frameworks.Count > 1)
            {
                report.Warnings.Add(new Diagnostic("FRAMEWORK_DEFAULT_SKIPPED", docfxPath, null,
                    "DocFX metadata declares multiple TargetFramework values; pass --framework explicitly to validate one target framework."));
            }
        }
        catch (Exception ex) when (ex is IOException or JsonException)
        {
            report.Warnings.Add(new Diagnostic("FRAMEWORK_DEFAULT_SKIPPED", docfxPath, null,
                $"Unable to read DocFX metadata TargetFramework default: {ex.Message}"));
        }

        return null;
    }

    private static void CleanupGeneratedMetadata(string repoRoot, string docfxPath, string docfxWorkspace, Options options, Report report)
    {
        if (!options.CleanGeneratedMetadata)
        {
            return;
        }

        foreach (var metadataPath in ResolveMetadataDestinations(docfxPath, docfxWorkspace, report)
                     .Distinct(StringComparer.OrdinalIgnoreCase))
        {
            if (!Directory.Exists(metadataPath))
            {
                continue;
            }

            if (!IsInsideDirectory(metadataPath, repoRoot) ||
                string.Equals(Path.GetFullPath(metadataPath).TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar),
                    Path.GetFullPath(repoRoot).TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar),
                    StringComparison.OrdinalIgnoreCase))
            {
                report.Warnings.Add(new Diagnostic("GENERATED_METADATA_CLEANUP_SKIPPED", metadataPath, null,
                    "Generated metadata cleanup was skipped because the resolved metadata destination is outside the repository root or is the repository root."));
                continue;
            }

            foreach (var file in EnumerateGeneratedMetadataFiles(metadataPath))
            {
                try
                {
                    File.Delete(file);
                    report.Summary.GeneratedMetadataFilesRemoved++;
                }
                catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
                {
                    report.Warnings.Add(new Diagnostic("GENERATED_METADATA_CLEANUP_FAILED", file, null,
                        $"Unable to remove generated DocFX metadata file: {ex.Message}"));
                }
            }
        }

        foreach (var buildOutputPath in ResolveBuildOutputDestinations(docfxPath, docfxWorkspace, report)
                     .Distinct(StringComparer.OrdinalIgnoreCase))
        {
            if (!Directory.Exists(buildOutputPath))
            {
                continue;
            }

            if (!IsSafeGeneratedOutputDirectory(buildOutputPath, repoRoot))
            {
                report.Warnings.Add(new Diagnostic("GENERATED_OUTPUT_CLEANUP_SKIPPED", buildOutputPath, null,
                    "Generated output cleanup was skipped because the resolved DocFX build destination is outside the repository root or is the repository root."));
                continue;
            }

            if (ContainsAuthoredOrSourceFiles(buildOutputPath))
            {
                report.Warnings.Add(new Diagnostic("GENERATED_OUTPUT_CLEANUP_SKIPPED", buildOutputPath, null,
                    "Generated output cleanup was skipped because the resolved DocFX build destination contains Markdown, source, project, solution, or DocFX configuration files. These may be authored documentation or repository source files."));
                continue;
            }

            try
            {
                Directory.Delete(buildOutputPath, recursive: true);
                report.Summary.GeneratedOutputDirectoriesRemoved++;
            }
            catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
            {
                report.Warnings.Add(new Diagnostic("GENERATED_OUTPUT_CLEANUP_FAILED", buildOutputPath, null,
                    $"Unable to remove generated DocFX build output directory: {ex.Message}"));
            }
        }
    }

    private static IEnumerable<string> ResolveMetadataDestinations(string docfxPath, string docfxWorkspace, Report report)
    {
        JsonDocument doc;
        try
        {
            doc = JsonDocument.Parse(File.ReadAllText(docfxPath), new JsonDocumentOptions
            {
                AllowTrailingCommas = true,
                CommentHandling = JsonCommentHandling.Skip
            });
        }
        catch (Exception ex) when (ex is IOException or JsonException)
        {
            report.Warnings.Add(new Diagnostic("GENERATED_METADATA_CLEANUP_FAILED", docfxPath, null,
                $"Unable to read DocFX metadata destinations for cleanup: {ex.Message}"));
            yield break;
        }

        using (doc)
        {
            if (!doc.RootElement.TryGetProperty("metadata", out var metadata))
            {
                yield break;
            }

            var foundDest = false;
            foreach (var entry in EnumerateMetadataEntries(metadata))
            {
                if (entry.ValueKind != JsonValueKind.Object ||
                    !entry.TryGetProperty("dest", out var destElement) ||
                    destElement.ValueKind != JsonValueKind.String)
                {
                    continue;
                }

                var dest = destElement.GetString();
                if (string.IsNullOrWhiteSpace(dest))
                {
                    continue;
                }

                foundDest = true;
                yield return Path.GetFullPath(dest, docfxWorkspace);
            }

            if (!foundDest)
            {
                yield return Path.GetFullPath("api", docfxWorkspace);
            }
        }
    }

    private static IEnumerable<string> ResolveBuildOutputDestinations(string docfxPath, string docfxWorkspace, Report report)
    {
        JsonDocument doc;
        try
        {
            doc = JsonDocument.Parse(File.ReadAllText(docfxPath), new JsonDocumentOptions
            {
                AllowTrailingCommas = true,
                CommentHandling = JsonCommentHandling.Skip
            });
        }
        catch (Exception ex) when (ex is IOException or JsonException)
        {
            report.Warnings.Add(new Diagnostic("GENERATED_OUTPUT_CLEANUP_FAILED", docfxPath, null,
                $"Unable to read DocFX build destination for cleanup: {ex.Message}"));
            yield break;
        }

        using (doc)
        {
            if (!doc.RootElement.TryGetProperty("build", out var build) ||
                build.ValueKind != JsonValueKind.Object ||
                !build.TryGetProperty("dest", out var destElement) ||
                destElement.ValueKind != JsonValueKind.String)
            {
                yield break;
            }

            var dest = destElement.GetString();
            if (!string.IsNullOrWhiteSpace(dest))
            {
                yield return Path.GetFullPath(dest, docfxWorkspace);
            }
        }
    }

    private static IEnumerable<JsonElement> EnumerateMetadataEntries(JsonElement metadata)
    {
        if (metadata.ValueKind == JsonValueKind.Array)
        {
            foreach (var entry in metadata.EnumerateArray())
            {
                yield return entry;
            }
        }
        else
        {
            yield return metadata;
        }
    }

    private static IEnumerable<string> EnumerateGeneratedMetadataFiles(string metadataPath)
    {
        return EnumerateFiles(metadataPath, "*.yml")
            .Concat(EnumerateFiles(metadataPath, ".manifest"))
            .Concat(EnumerateFiles(metadataPath, "*.manifest"))
            .Select(Path.GetFullPath)
            .Distinct(StringComparer.OrdinalIgnoreCase);
    }

    private static bool IsInsideDirectory(string path, string directory)
    {
        var fullPath = Path.GetFullPath(path).TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar) +
                       Path.DirectorySeparatorChar;
        var fullDirectory = Path.GetFullPath(directory).TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar) +
                             Path.DirectorySeparatorChar;
        return fullPath.StartsWith(fullDirectory, StringComparison.OrdinalIgnoreCase);
    }

    private static bool PathsEqual(string left, string right)
    {
        return string.Equals(
            Path.GetFullPath(left).TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar),
            Path.GetFullPath(right).TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar),
            StringComparison.OrdinalIgnoreCase);
    }

    private static bool IsSafeGeneratedOutputDirectory(string path, string repoRoot)
    {
        return IsInsideDirectory(path, repoRoot) &&
               !string.Equals(Path.GetFullPath(path).TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar),
                   Path.GetFullPath(repoRoot).TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar),
                   StringComparison.OrdinalIgnoreCase);
    }

    private static bool ContainsAuthoredOrSourceFiles(string path)
    {
        string[] patterns = ["*.md", "*.mdoc", "docfx.json", "toc.yml", "toc.md", "*.cs", "*.csproj", "*.sln", "*.slnx"];
        return patterns.Any(pattern => EnumerateFiles(path, pattern).Any());
    }

    private static List<string> DiscoverMarkdown(string repoRoot, string docfxPath, string docfxWorkspace, Report report)
    {
        var configuredFiles = DiscoverMarkdownFromDocfxConfig(docfxPath, docfxWorkspace, report)
            .Distinct(StringComparer.OrdinalIgnoreCase)
            .OrderBy(p => p, StringComparer.OrdinalIgnoreCase)
            .ToList();

        if (configuredFiles.Count > 0)
        {
            return configuredFiles;
        }

        if (!PathsEqual(repoRoot, docfxWorkspace))
        {
            return EnumerateFiles(docfxWorkspace, "*.md")
                .Select(Path.GetFullPath)
                .Distinct(StringComparer.OrdinalIgnoreCase)
                .OrderBy(p => p, StringComparer.OrdinalIgnoreCase)
                .ToList();
        }

        report.Warnings.Add(new Diagnostic("DOCFX_MARKDOWN_DISCOVERY_SKIPPED", docfxPath, null,
            "No Markdown inputs were resolved from build.content or build.overwrite, and docfx.json is at the repository root. Skipped the legacy full-repository Markdown scan to avoid treating unrelated repository Markdown as DocFX overwrite content."));
        return new List<string>();
    }

    private static IEnumerable<string> DiscoverMarkdownFromDocfxConfig(string docfxPath, string docfxWorkspace, Report report)
    {
        JsonDocument doc;
        try
        {
            doc = JsonDocument.Parse(File.ReadAllText(docfxPath), new JsonDocumentOptions
            {
                AllowTrailingCommas = true,
                CommentHandling = JsonCommentHandling.Skip
            });
        }
        catch (Exception ex) when (ex is IOException or JsonException)
        {
            report.Warnings.Add(new Diagnostic("DOCFX_MARKDOWN_DISCOVERY_FAILED", docfxPath, null,
                $"Unable to read DocFX Markdown inputs: {ex.Message}"));
            yield break;
        }

        using (doc)
        {
            if (!doc.RootElement.TryGetProperty("build", out var build) || build.ValueKind != JsonValueKind.Object)
            {
                yield break;
            }

            foreach (var propertyName in new[] { "content", "overwrite" })
            {
                if (!build.TryGetProperty(propertyName, out var entries))
                {
                    continue;
                }

                foreach (var file in ResolveDocfxMarkdownInputFiles(entries, docfxWorkspace))
                {
                    yield return file;
                }
            }
        }
    }

    private static IEnumerable<string> ResolveDocfxMarkdownInputFiles(JsonElement entries, string docfxWorkspace)
    {
        foreach (var entry in EnumerateDocfxFileMappingEntries(entries))
        {
            var src = docfxWorkspace;
            var includePatterns = new List<string>();
            var excludePatterns = new List<string>();

            if (entry.ValueKind == JsonValueKind.String)
            {
                includePatterns.Add(entry.GetString() ?? string.Empty);
            }
            else if (entry.ValueKind == JsonValueKind.Object)
            {
                if (entry.TryGetProperty("src", out var srcElement) &&
                    srcElement.ValueKind == JsonValueKind.String &&
                    !string.IsNullOrWhiteSpace(srcElement.GetString()))
                {
                    src = Path.GetFullPath(srcElement.GetString()!, docfxWorkspace);
                }

                if (entry.TryGetProperty("files", out var files))
                {
                    includePatterns.AddRange(ReadDocfxGlobPatterns(files));
                }

                if (entry.TryGetProperty("exclude", out var exclude))
                {
                    excludePatterns.AddRange(ReadDocfxGlobPatterns(exclude));
                }
            }

            foreach (var file in ResolveMarkdownGlobPatterns(src, includePatterns, excludePatterns))
            {
                yield return file;
            }
        }
    }

    private static IEnumerable<JsonElement> EnumerateDocfxFileMappingEntries(JsonElement entries)
    {
        if (entries.ValueKind == JsonValueKind.Array)
        {
            foreach (var entry in entries.EnumerateArray())
            {
                yield return entry;
            }
        }
        else
        {
            yield return entries;
        }
    }

    private static IEnumerable<string> ReadDocfxGlobPatterns(JsonElement element)
    {
        if (element.ValueKind == JsonValueKind.String)
        {
            yield return element.GetString() ?? string.Empty;
            yield break;
        }

        if (element.ValueKind != JsonValueKind.Array)
        {
            yield break;
        }

        foreach (var item in element.EnumerateArray())
        {
            if (item.ValueKind == JsonValueKind.String)
            {
                yield return item.GetString() ?? string.Empty;
            }
        }
    }

    private static IEnumerable<string> ResolveMarkdownGlobPatterns(string srcRoot, IEnumerable<string> includePatterns, IEnumerable<string> excludePatterns)
    {
        var excludes = excludePatterns
            .Where(IsMarkdownGlob)
            .Select(GlobToRegex)
            .ToList();

        foreach (var pattern in includePatterns.Where(IsMarkdownGlob))
        {
            var searchRoot = ResolveGlobSearchRoot(srcRoot, pattern);
            if (!Directory.Exists(searchRoot))
            {
                var exactFile = Path.GetFullPath(pattern, srcRoot);
                if (File.Exists(exactFile))
                {
                    yield return exactFile;
                }

                continue;
            }

            var includeRegex = GlobToRegex(pattern);
            foreach (var file in EnumerateFiles(searchRoot, "*.md"))
            {
                var relative = NormalizeDocfxPath(Path.GetRelativePath(srcRoot, file));
                if (includeRegex.IsMatch(relative) && !excludes.Any(exclude => exclude.IsMatch(relative)))
                {
                    yield return Path.GetFullPath(file);
                }
            }
        }
    }

    private static bool IsMarkdownGlob(string pattern)
    {
        if (string.IsNullOrWhiteSpace(pattern))
        {
            return false;
        }

        var extension = Path.GetExtension(pattern);
        return string.Equals(extension, ".md", StringComparison.OrdinalIgnoreCase) ||
               (string.IsNullOrEmpty(extension) && pattern.IndexOfAny(['*', '?', '[']) >= 0);
    }

    private static string ResolveGlobSearchRoot(string srcRoot, string pattern)
    {
        var normalized = NormalizeDocfxPath(pattern);
        var wildcardIndex = normalized.IndexOfAny(['*', '?', '[']);
        if (wildcardIndex < 0)
        {
            var exactDirectory = Path.GetDirectoryName(Path.GetFullPath(normalized, srcRoot));
            return string.IsNullOrWhiteSpace(exactDirectory) ? srcRoot : exactDirectory;
        }

        var prefix = normalized[..wildcardIndex];
        var slashIndex = prefix.LastIndexOf('/');
        if (slashIndex < 0)
        {
            return srcRoot;
        }

        return Path.GetFullPath(prefix[..slashIndex], srcRoot);
    }

    private static Regex GlobToRegex(string pattern)
    {
        var normalized = NormalizeDocfxPath(pattern);
        var sb = new StringBuilder("^");
        for (var i = 0; i < normalized.Length; i++)
        {
            var c = normalized[i];
            if (c == '*')
            {
                if (i + 1 < normalized.Length && normalized[i + 1] == '*')
                {
                    i++;
                    if (i + 1 < normalized.Length && normalized[i + 1] == '/')
                    {
                        i++;
                        sb.Append("(?:.*/)?");
                    }
                    else
                    {
                        sb.Append(".*");
                    }
                }
                else
                {
                    sb.Append("[^/]*");
                }

                continue;
            }

            sb.Append(c == '?' ? "[^/]" : Regex.Escape(c.ToString()));
        }

        sb.Append('$');
        return new Regex(sb.ToString(), RegexOptions.IgnoreCase | RegexOptions.CultureInvariant);
    }

    private static string NormalizeDocfxPath(string path)
    {
        return path.Replace(Path.DirectorySeparatorChar, '/').Replace(Path.AltDirectorySeparatorChar, '/');
    }

    private static IEnumerable<string> EnumerateFiles(string root, string pattern)
    {
        var stack = new Stack<string>();
        stack.Push(root);
        while (stack.Count > 0)
        {
            var dir = stack.Pop();
            string[] entries;
            try
            {
                entries = Directory.GetDirectories(dir);
            }
            catch
            {
                continue;
            }

            foreach (var sub in entries)
            {
                var name = Path.GetFileName(sub);
                if (IgnoredDirectorySegments.Contains(name, StringComparer.OrdinalIgnoreCase))
                {
                    continue;
                }

                stack.Push(sub);
            }

            string[] files;
            try
            {
                files = Directory.GetFiles(dir, pattern);
            }
            catch
            {
                continue;
            }

            foreach (var f in files)
            {
                yield return f;
            }
        }
    }

    private static void VerifyDocfxBuild(string repoRoot, string docfxPath, Report report)
    {
        var docfxExecutable = ResolveDocfxExecutable();
        if (docfxExecutable is null)
        {
            report.Errors.Add(new Diagnostic("DOCFX_BUILD_FAILED", docfxPath, null,
                "Unable to find the DocFX CLI on PATH. Install the docfx .NET tool or make docfx.exe available on PATH."));
            return;
        }

        var tempRoot = Path.Combine(Path.GetTempPath(), "docfx-digest-build-" + Guid.NewGuid().ToString("N"));
        try
        {
            CopyDirectory(repoRoot, tempRoot);
            var relativeDocfxPath = Path.GetRelativePath(repoRoot, docfxPath);
            var tempDocfxPath = Path.Combine(tempRoot, relativeDocfxPath);
            var environment = HasRootStrongNameKey(tempRoot)
                ? null
                : new Dictionary<string, string> { ["SkipSignAssembly"] = "true" };
            var result = RunProcess(docfxExecutable, $"\"{tempDocfxPath}\"", tempRoot, environment);
            if (result.ExitCode != 0)
            {
                report.Errors.Add(new Diagnostic("DOCFX_BUILD_FAILED", docfxPath, null,
                    $"DocFX build failed in a temp workspace (exit {result.ExitCode}).\n{Trim(result.StdOut + result.StdErr)}"));
                return;
            }

            report.Summary.DocfxBuildsVerified++;
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
        {
            report.Errors.Add(new Diagnostic("DOCFX_BUILD_FAILED", docfxPath, null,
                $"Unable to verify DocFX build in a temp workspace: {ex.Message}"));
        }
        finally
        {
            TryDeleteDirectory(tempRoot);
        }
    }

    private static string? ResolveDocfxExecutable()
    {
        var currentProcess = Environment.ProcessPath;
        var path = Environment.GetEnvironmentVariable("PATH");
        if (string.IsNullOrWhiteSpace(path))
        {
            return null;
        }

        var extensions = OperatingSystem.IsWindows()
            ? (Environment.GetEnvironmentVariable("PATHEXT") ?? ".COM;.EXE;.BAT;.CMD")
                .Split(';', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries)
            : [string.Empty];

        foreach (var directory in path.Split(Path.PathSeparator, StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries))
        {
            foreach (var extension in extensions)
            {
                var candidate = Path.Combine(directory, OperatingSystem.IsWindows() ? "docfx" + extension.ToLowerInvariant() : "docfx");
                if (!File.Exists(candidate))
                {
                    continue;
                }

                var full = Path.GetFullPath(candidate);
                if (currentProcess is not null && string.Equals(full, currentProcess, StringComparison.OrdinalIgnoreCase))
                {
                    continue;
                }

                return full;
            }
        }

        return null;
    }

    private static void CopyDirectory(string sourceDirectory, string destinationDirectory)
    {
        Directory.CreateDirectory(destinationDirectory);

        foreach (var file in Directory.GetFiles(sourceDirectory))
        {
            File.Copy(file, Path.Combine(destinationDirectory, Path.GetFileName(file)), overwrite: true);
        }

        foreach (var directory in Directory.GetDirectories(sourceDirectory))
        {
            var name = Path.GetFileName(directory);
            if (IgnoredDirectorySegments.Contains(name, StringComparer.OrdinalIgnoreCase))
            {
                continue;
            }

            CopyDirectory(directory, Path.Combine(destinationDirectory, name));
        }
    }

    private static bool AgentsBlockPresent(string agentsPath)
    {
        if (!File.Exists(agentsPath))
        {
            return false;
        }

        var text = File.ReadAllText(agentsPath);
        return text.Contains(StartMarker, StringComparison.Ordinal) && text.Contains(EndMarker, StringComparison.Ordinal);
    }

    // ----------------------------------------------------------------------
    // Build
    // ----------------------------------------------------------------------

    private static (bool Ok, string Output) BuildRepository(string repoRoot, string configuration)
    {
        // Build a solution if one is present, otherwise let dotnet resolve the project in the repo root.
        var target = Directory.GetFiles(repoRoot, "*.slnx").Concat(Directory.GetFiles(repoRoot, "*.sln")).FirstOrDefault();
        var signingProperty = HasRootStrongNameKey(repoRoot) ? string.Empty : " -p:SkipSignAssembly=true";
        var args = target is null
            ? $"build -c {configuration} --nologo{signingProperty}"
            : $"build \"{target}\" -c {configuration} --nologo{signingProperty}";
        var result = RunProcess("dotnet", args, repoRoot);
        return (result.ExitCode == 0, result.StdOut + result.StdErr);
    }

    private static bool HasRootStrongNameKey(string repoRoot)
    {
        try
        {
            return Directory.EnumerateFiles(repoRoot, "*.snk", SearchOption.TopDirectoryOnly).Any();
        }
        catch
        {
            return false;
        }
    }

    // ----------------------------------------------------------------------
    // Project + API discovery
    // ----------------------------------------------------------------------

    private static List<ProjectInfo> DiscoverProjects(string repoRoot)
    {
        var projects = new List<ProjectInfo>();
        var srcPath = Path.Combine(repoRoot, "src");
        if (!Directory.Exists(srcPath))
        {
            return projects;
        }
        foreach (var proj in EnumerateFiles(srcPath, "*.csproj"))
        {
            var info = ReadProject(proj);
            projects.Add(info);
        }
        return projects;
    }

    private static ProjectInfo ReadProject(string projectPath)
    {
        string? assemblyName = null;
        var tfms = new List<string>();
        bool isTest = false;

        try
        {
            var doc = XDocument.Load(projectPath);
            foreach (var el in doc.Descendants())
            {
                switch (el.Name.LocalName)
                {
                    case "AssemblyName":
                        assemblyName = el.Value.Trim();
                        break;
                    case "TargetFramework":
                        if (!string.IsNullOrWhiteSpace(el.Value))
                        {
                            tfms.Add(el.Value.Trim());
                        }

                        break;
                    case "TargetFrameworks":
                        tfms.AddRange(el.Value.Split(';', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries));
                        break;
                    case "IsTestProject":
                        if (bool.TryParse(el.Value.Trim(), out var b) && b)
                        {
                            isTest = true;
                        }

                        break;
                    case "PackageReference":
                        var include = el.Attribute("Include")?.Value ?? string.Empty;
                        if (include.Contains("Microsoft.NET.Test.Sdk", StringComparison.OrdinalIgnoreCase) ||
                            include.Contains("xunit", StringComparison.OrdinalIgnoreCase) ||
                            include.StartsWith("NUnit", StringComparison.OrdinalIgnoreCase) ||
                            include.Contains("MSTest", StringComparison.OrdinalIgnoreCase))
                        {
                            isTest = true;
                        }

                        break;
                }
            }
        }
        catch
        {
            // Ignore malformed project files; they simply contribute no metadata.
        }

        assemblyName ??= Path.GetFileNameWithoutExtension(projectPath);

        // Path-based heuristic: anything under a test/tests folder or named *Test(s).
        var segments = projectPath.Split(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar);
        if (segments.Any(s => string.Equals(s, "test", StringComparison.OrdinalIgnoreCase) ||
                              string.Equals(s, "tests", StringComparison.OrdinalIgnoreCase)))
        {
            isTest = true;
        }

        var fileName = Path.GetFileNameWithoutExtension(projectPath);
        if (fileName.EndsWith("Test", StringComparison.OrdinalIgnoreCase) ||
            fileName.EndsWith("Tests", StringComparison.OrdinalIgnoreCase))
        {
            isTest = true;
        }

        return new ProjectInfo(projectPath, assemblyName, tfms, isTest);
    }

    private static ApiModel DiscoverApi(List<ProjectInfo> libraryProjects, string configuration, string? framework, Report report)
    {
        var assemblyPaths = new List<string>();
        foreach (var proj in libraryProjects)
        {
            var dll = FindAssembly(proj, configuration, framework);
            if (dll is not null)
            {
                assemblyPaths.Add(dll);
            }
        }

        if (assemblyPaths.Count == 0)
        {
            return new ApiModel(new List<NamespaceInfo>(), new List<ApiTargetInfo>());
        }

        // Resolve dependencies from the runtime directory and the assemblies' own output folders.
        var resolverPaths = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        var runtimeDir = System.Runtime.InteropServices.RuntimeEnvironment.GetRuntimeDirectory();
        foreach (var dll in Directory.GetFiles(runtimeDir, "*.dll"))
        {
            resolverPaths.Add(dll);
        }

        AddDotNetPackResolverPaths(runtimeDir, framework, resolverPaths);

        foreach (var dll in assemblyPaths)
        {
            var dir = Path.GetDirectoryName(dll)!;
            foreach (var sibling in Directory.GetFiles(dir, "*.dll"))
            {
                resolverPaths.Add(sibling);
            }
        }

        foreach (var proj in libraryProjects)
        {
            var dll = assemblyPaths.FirstOrDefault(p =>
                string.Equals(Path.GetFileNameWithoutExtension(p), proj.AssemblyName, StringComparison.OrdinalIgnoreCase));
            if (dll is not null)
            {
                AddProjectDependencyResolverPaths(proj, dll, configuration, framework, resolverPaths);
            }
        }

        var resolver = new PathAssemblyResolver(DistinctResolverPaths(resolverPaths));
        using var mlc = new MetadataLoadContext(resolver, "System.Private.CoreLib");

        var namespaces = new Dictionary<string, NamespaceInfo>(StringComparer.Ordinal);
        foreach (var dll in assemblyPaths)
        {
            Assembly asm;
            try
            {
                asm = mlc.LoadFromAssemblyPath(dll);
            }
            catch
            {
                continue;
            }

            Type[] types;
            try
            {
                types = asm.GetTypes();
            }
            catch (ReflectionTypeLoadException rtle)
            {
                types = rtle.Types.Where(t => t is not null).Cast<Type>().ToArray();
            }
            catch
            {
                continue;
            }

            foreach (var type in types)
            {
                if (type is null || !IsExternallyVisible(type))
                {
                    continue;
                }

                var nsName = type.Namespace;
                if (string.IsNullOrEmpty(nsName))
                {
                    continue;
                }

                if (!namespaces.TryGetValue(nsName, out var info))
                {
                    info = new NamespaceInfo(nsName);
                    namespaces[nsName] = info;
                }

                CollectApiTargets(type, info);
                CollectExtensionMethods(type, info);
            }
        }

        var requiredExampleTargets = namespaces.Values
            .SelectMany(ns => ns.RequiredExampleTargets)
            .OrderBy(t => t.Uid, StringComparer.Ordinal)
            .ToList();

        return new ApiModel(namespaces.Values.ToList(), requiredExampleTargets);
    }

    private static List<string> DistinctResolverPaths(IEnumerable<string> paths)
    {
        var byIdentity = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        var fallback = new List<string>();
        foreach (var path in paths)
        {
            try
            {
                var identity = AssemblyName.GetAssemblyName(path).FullName;
                byIdentity.TryAdd(identity, path);
            }
            catch
            {
                fallback.Add(path);
            }
        }

        return byIdentity.Values.Concat(fallback).ToList();
    }

    private static void AddDotNetPackResolverPaths(string runtimeDir, string? framework, HashSet<string> resolverPaths)
    {
        if (string.IsNullOrWhiteSpace(framework))
        {
            return;
        }

        var dotnetRoot = Directory.GetParent(runtimeDir.TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar))?
            .Parent?
            .Parent?
            .FullName;
        if (dotnetRoot is null)
        {
            return;
        }

        var packsRoot = Path.Combine(dotnetRoot, "packs");
        if (!Directory.Exists(packsRoot))
        {
            return;
        }

        foreach (var pack in Directory.GetDirectories(packsRoot))
        {
            if (string.Equals(Path.GetFileName(pack), "Microsoft.NETCore.App.Ref", StringComparison.OrdinalIgnoreCase))
            {
                continue;
            }

            var refDir = Directory.GetDirectories(pack)
                .Select(version => Path.Combine(version, "ref", framework))
                .Where(Directory.Exists)
                .OrderByDescending(path => path, StringComparer.OrdinalIgnoreCase)
                .FirstOrDefault();

            if (refDir is null)
            {
                continue;
            }

            foreach (var dll in Directory.GetFiles(refDir, "*.dll"))
            {
                resolverPaths.Add(dll);
            }
        }
    }

    private static void AddProjectDependencyResolverPaths(ProjectInfo project, string assemblyPath, string configuration,
        string? framework, HashSet<string> resolverPaths)
    {
        var projectFramework = framework ?? DetectFrameworkFromAssemblyPath(project, assemblyPath);
        AddProjectAssetsResolverPaths(project, projectFramework, resolverPaths);
        AddDepsJsonResolverPaths(project, assemblyPath, configuration, projectFramework, resolverPaths);
    }

    private static string? DetectFrameworkFromAssemblyPath(ProjectInfo project, string assemblyPath)
    {
        if (project.TargetFrameworks.Count == 0)
        {
            return null;
        }

        var segments = Path.GetFullPath(assemblyPath)
            .Split(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar);

        return project.TargetFrameworks.FirstOrDefault(tfm =>
            segments.Any(s => string.Equals(s, tfm, StringComparison.OrdinalIgnoreCase)));
    }

    private static void AddProjectAssetsResolverPaths(ProjectInfo project, string? framework, HashSet<string> resolverPaths)
    {
        var projectDir = Path.GetDirectoryName(project.Path)!;
        var assetsPath = Path.Combine(projectDir, "obj", "project.assets.json");
        if (!File.Exists(assetsPath))
        {
            return;
        }

        try
        {
            using var doc = JsonDocument.Parse(File.ReadAllText(assetsPath), new JsonDocumentOptions
            {
                AllowTrailingCommas = true,
                CommentHandling = JsonCommentHandling.Skip
            });

            if (!doc.RootElement.TryGetProperty("targets", out var targets) ||
                targets.ValueKind != JsonValueKind.Object)
            {
                return;
            }

            var packageFolders = ReadPackageFolders(doc.RootElement);
            foreach (var target in targets.EnumerateObject())
            {
                if (!IsMatchingAssetsTarget(target.Name, framework))
                {
                    continue;
                }

                foreach (var dependency in target.Value.EnumerateObject())
                {
                    AddAssetGroupResolverPaths(dependency, "compile", packageFolders, resolverPaths);
                    AddAssetGroupResolverPaths(dependency, "runtime", packageFolders, resolverPaths);
                }
            }
        }
        catch (Exception ex) when (ex is IOException or JsonException)
        {
            // Missing asset details should not block metadata discovery when output-folder resolution is enough.
        }
    }

    private static List<string> ReadPackageFolders(JsonElement root)
    {
        var packageFolders = new List<string>();
        if (!root.TryGetProperty("packageFolders", out var folders) ||
            folders.ValueKind != JsonValueKind.Object)
        {
            return packageFolders;
        }

        foreach (var folder in folders.EnumerateObject())
        {
            if (!string.IsNullOrWhiteSpace(folder.Name))
            {
                packageFolders.Add(folder.Name);
            }
        }

        return packageFolders;
    }

    private static bool IsMatchingAssetsTarget(string targetName, string? framework)
    {
        if (string.IsNullOrWhiteSpace(framework))
        {
            return true;
        }

        return string.Equals(targetName, framework, StringComparison.OrdinalIgnoreCase) ||
               targetName.StartsWith(framework + "/", StringComparison.OrdinalIgnoreCase);
    }

    private static void AddAssetGroupResolverPaths(JsonProperty dependency, string groupName, List<string> packageFolders,
        HashSet<string> resolverPaths)
    {
        if (dependency.Value.ValueKind != JsonValueKind.Object ||
            !dependency.Value.TryGetProperty("type", out var typeElement) ||
            typeElement.ValueKind != JsonValueKind.String ||
            !string.Equals(typeElement.GetString(), "package", StringComparison.OrdinalIgnoreCase) ||
            !dependency.Value.TryGetProperty(groupName, out var group) ||
            group.ValueKind != JsonValueKind.Object)
        {
            return;
        }

        var slash = dependency.Name.IndexOf('/');
        if (slash <= 0 || slash == dependency.Name.Length - 1)
        {
            return;
        }

        var packageId = dependency.Name[..slash];
        var version = dependency.Name[(slash + 1)..];
        foreach (var asset in group.EnumerateObject())
        {
            if (!asset.Name.EndsWith(".dll", StringComparison.OrdinalIgnoreCase) ||
                asset.Name.EndsWith("/_._", StringComparison.OrdinalIgnoreCase))
            {
                continue;
            }

            foreach (var packageFolder in packageFolders)
            {
                var packageRoot = Path.Combine(packageFolder, packageId.ToLowerInvariant(), version.ToLowerInvariant());
                var fullPath = Path.GetFullPath(asset.Name.Replace('/', Path.DirectorySeparatorChar), packageRoot);
                if (File.Exists(fullPath))
                {
                    resolverPaths.Add(fullPath);
                    break;
                }

                packageRoot = Path.Combine(packageFolder, packageId, version);
                fullPath = Path.GetFullPath(asset.Name.Replace('/', Path.DirectorySeparatorChar), packageRoot);
                if (File.Exists(fullPath))
                {
                    resolverPaths.Add(fullPath);
                    break;
                }
            }
        }
    }

    private static void AddDepsJsonResolverPaths(ProjectInfo project, string assemblyPath, string configuration,
        string? framework, HashSet<string> resolverPaths)
    {
        var projectDir = Path.GetDirectoryName(project.Path)!;
        var outputDir = Path.GetDirectoryName(assemblyPath)!;
        var depsName = Path.GetFileNameWithoutExtension(assemblyPath) + ".deps.json";
        var candidates = new List<string> { Path.Combine(outputDir, depsName) };

        if (!string.IsNullOrWhiteSpace(framework))
        {
            candidates.Add(Path.Combine(projectDir, "bin", configuration, framework, depsName));
        }

        foreach (var depsPath in candidates.Distinct(StringComparer.OrdinalIgnoreCase))
        {
            if (!File.Exists(depsPath))
            {
                continue;
            }

            AddDepsJsonPackagePaths(depsPath, resolverPaths);
        }
    }

    private static void AddDepsJsonPackagePaths(string depsPath, HashSet<string> resolverPaths)
    {
        try
        {
            using var doc = JsonDocument.Parse(File.ReadAllText(depsPath), new JsonDocumentOptions
            {
                AllowTrailingCommas = true,
                CommentHandling = JsonCommentHandling.Skip
            });

            if (!doc.RootElement.TryGetProperty("targets", out var targets) ||
                targets.ValueKind != JsonValueKind.Object)
            {
                return;
            }

            var packageFolders = ResolveNuGetPackageFolders();
            foreach (var target in targets.EnumerateObject())
            {
                foreach (var dependency in target.Value.EnumerateObject())
                {
                    AddDepsRuntimeResolverPaths(dependency, packageFolders, resolverPaths);
                }
            }
        }
        catch (Exception ex) when (ex is IOException or JsonException)
        {
            // project.assets.json is the primary package resolver; deps.json only supplements it.
        }
    }

    private static List<string> ResolveNuGetPackageFolders()
    {
        var folders = new List<string>();
        var userProfile = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
        if (!string.IsNullOrWhiteSpace(userProfile))
        {
            folders.Add(Path.Combine(userProfile, ".nuget", "packages"));
        }

        var packages = Environment.GetEnvironmentVariable("NUGET_PACKAGES");
        if (!string.IsNullOrWhiteSpace(packages))
        {
            folders.Insert(0, packages);
        }

        return folders.Where(Directory.Exists).Distinct(StringComparer.OrdinalIgnoreCase).ToList();
    }

    private static void AddDepsRuntimeResolverPaths(JsonProperty dependency, List<string> packageFolders,
        HashSet<string> resolverPaths)
    {
        if (dependency.Value.ValueKind != JsonValueKind.Object ||
            !dependency.Value.TryGetProperty("runtime", out var runtime) ||
            runtime.ValueKind != JsonValueKind.Object)
        {
            return;
        }

        var slash = dependency.Name.IndexOf('/');
        if (slash <= 0 || slash == dependency.Name.Length - 1)
        {
            return;
        }

        var packageId = dependency.Name[..slash];
        var version = dependency.Name[(slash + 1)..];
        foreach (var asset in runtime.EnumerateObject())
        {
            if (!asset.Name.EndsWith(".dll", StringComparison.OrdinalIgnoreCase) ||
                asset.Name.EndsWith("/_._", StringComparison.OrdinalIgnoreCase))
            {
                continue;
            }

            foreach (var packageFolder in packageFolders)
            {
                var packageRoot = Path.Combine(packageFolder, packageId.ToLowerInvariant(), version.ToLowerInvariant());
                var fullPath = Path.GetFullPath(asset.Name.Replace('/', Path.DirectorySeparatorChar), packageRoot);
                if (File.Exists(fullPath))
                {
                    resolverPaths.Add(fullPath);
                    break;
                }
            }
        }
    }

    private static void CollectApiTargets(Type type, NamespaceInfo ns)
    {
        var typeUid = TypeUid(type);
        if (typeUid is null)
        {
            return;
        }

        if (IsExampleRequiredType(type))
        {
            ns.RequiredExampleTargets.Add(new ApiTargetInfo(typeUid, ns.Name, ApiTargetKind.Type, SimpleTypeName(type)));
        }

        MethodInfo[] methods;
        try
        {
            methods = type.GetMethods(BindingFlags.Public | BindingFlags.Static | BindingFlags.DeclaredOnly);
        }
        catch
        {
            return;
        }

        foreach (var method in methods)
        {
            if (!method.IsPublic || method.IsSpecialName || method.IsAbstract || !HasExtensionAttribute(method))
            {
                continue;
            }

            ns.RequiredExampleTargets.Add(new ApiTargetInfo(MethodUid(typeUid, method), ns.Name, ApiTargetKind.ExtensionMethod, method.Name, typeUid));
        }
    }

    private static void CollectExtensionMethods(Type type, NamespaceInfo ns)
    {
        // A public extension method lives on a public static (abstract+sealed) non-generic class.
        if (!type.IsClass || !type.IsAbstract || !type.IsSealed || type.IsGenericType || !type.IsPublic)
        {
            return;
        }

        MethodInfo[] methods;
        try
        {
            methods = type.GetMethods(BindingFlags.Public | BindingFlags.Static | BindingFlags.DeclaredOnly);
        }
        catch
        {
            return;
        }

        foreach (var method in methods)
        {
            if (!method.IsStatic || !method.IsPublic)
            {
                continue;
            }

            if (!HasExtensionAttribute(method))
            {
                continue;
            }

            var parameters = method.GetParameters();
            if (parameters.Length == 0)
            {
                continue;
            }

            var extendedType = SimpleTypeName(parameters[0].ParameterType);
            ns.ExtensionMethods.Add(new ExtensionMethodInfo(method.Name, extendedType, type.Name));
        }
    }

    private static bool HasExtensionAttribute(MemberInfo member)
    {
        try
        {
            foreach (var attr in member.GetCustomAttributesData())
            {
                if (string.Equals(attr.AttributeType.FullName, ExtensionAttributeFullName, StringComparison.Ordinal))
                {
                    return true;
                }
            }
        }
        catch
        {
            // ignore
        }

        return false;
    }

    private static bool IsExternallyVisible(Type type)
    {
        try
        {
            if (type.IsNested)
            {
                return type.IsNestedPublic && type.DeclaringType is not null && IsExternallyVisible(type.DeclaringType);
            }

            return type.IsPublic;
        }
        catch
        {
            return false;
        }
    }

    private static bool IsExampleRequiredType(Type type)
    {
        if (type.IsInterface || type.IsAbstract)
        {
            return false;
        }

        return true;
    }

    private static string? TypeUid(Type type)
    {
        var fullName = type.FullName;
        if (string.IsNullOrWhiteSpace(fullName))
        {
            return null;
        }

        return fullName.Replace('+', '.');
    }

    private static string MethodUid(string typeUid, MethodInfo method)
    {
        var parameters = method.GetParameters()
            .Select(p => TypeUid(p.ParameterType) ?? SimpleTypeName(p.ParameterType));

        return typeUid + "." + method.Name + "(" + string.Join(",", parameters) + ")";
    }

    private static string SimpleTypeName(Type type)
    {
        var name = type.Name;
        var tick = name.IndexOf('`');
        return tick >= 0 ? name[..tick] : name;
    }

    private static string? FindAssembly(ProjectInfo project, string configuration, string? framework)
    {
        var projDir = Path.GetDirectoryName(project.Path)!;
        var dllName = project.AssemblyName + ".dll";

        // Prefer reference assemblies (ref/) when present, then regular output. Honor --framework.
        var roots = new[] { Path.Combine(projDir, "bin", configuration), Path.Combine(projDir, "obj", configuration) };
        string? fallback = null;

        foreach (var root in roots)
        {
            if (!Directory.Exists(root))
            {
                continue;
            }

            IEnumerable<string> candidates;
            try
            {
                candidates = Directory.GetFiles(root, dllName, SearchOption.AllDirectories);
            }
            catch
            {
                continue;
            }

            foreach (var candidate in candidates)
            {
                if (framework is not null && !candidate.Replace('\\', '/').Contains($"/{framework}/", StringComparison.OrdinalIgnoreCase))
                {
                    continue;
                }

                var isRef = candidate.Replace('\\', '/').Contains("/ref/", StringComparison.OrdinalIgnoreCase);
                if (isRef)
                {
                    return candidate;
                }

                fallback ??= candidate;
            }
        }

        return fallback;
    }

    // ----------------------------------------------------------------------
    // Namespace page validation
    // ----------------------------------------------------------------------

    private static void ValidateNamespacePage(string repoRoot, string page, NamespaceInfo ns, Report report)
    {
        var rel = Rel(repoRoot, page);
        string text;
        try
        {
            text = File.ReadAllText(page);
        }
        catch (Exception ex)
        {
            report.Errors.Add(new Diagnostic("NAMESPACE_PAGE_MISSING", rel, ns.Name, $"Unable to read namespace page: {ex.Message}"));
            return;
        }

        var (frontMatter, body) = SplitFrontMatter(text);

        // uid
        var uid = ReadYamlScalar(frontMatter, "uid");
        if (uid is null)
        {
            report.Errors.Add(new Diagnostic("NAMESPACE_UID_MISSING", rel, ns.Name,
                $"Namespace page is missing a 'uid' in its DocFX overwrite front matter."));
        }
        else if (!string.Equals(uid, ns.Name, StringComparison.Ordinal))
        {
            report.Errors.Add(new Diagnostic("NAMESPACE_UID_MISMATCH", rel, ns.Name,
                $"Namespace page uid '{uid}' does not match the namespace '{ns.Name}'."));
        }

        // summary
        if (ReadYamlScalar(frontMatter, "summary") is null)
        {
            report.Errors.Add(new Diagnostic("NAMESPACE_SUMMARY_MISSING", rel, ns.Name,
                "Namespace page front matter is missing a 'summary' key (expected 'summary: *content')."));
        }

        // fly-in paragraph
        if (!HasFlyIn(body))
        {
            report.Errors.Add(new Diagnostic("NAMESPACE_FLYIN_MISSING", rel, ns.Name,
                "Namespace page has no human-written fly-in paragraph, or contains only placeholder text."));
        }

        // availability
        if (!HasAvailability(body))
        {
            report.Errors.Add(new Diagnostic("AVAILABILITY_MISSING", rel, ns.Name,
                "Namespace page has no availability information (expected an availability include or explicit 'Availability:' text)."));
        }

        // extension members
        if (ns.ExtensionMethods.Count > 0)
        {
            ValidateExtensionSection(rel, body, ns, report);
        }
    }

    private static void ValidateExtensionSection(string rel, string body, NamespaceInfo ns, Report report)
    {
        var sectionMatch = Regex.Match(body, @"(?im)^#{2,4}\s+Extension\s+Members\s*$");
        if (!sectionMatch.Success)
        {
            report.Errors.Add(new Diagnostic("EXTENSION_SECTION_MISSING", rel, ns.Name,
                $"Namespace {ns.Name} exposes public extension methods but the page has no 'Extension Members' section."));
            return;
        }

        var section = body[sectionMatch.Index..];
        // Stop at the next heading of equal-or-higher level.
        var nextHeading = Regex.Match(section[sectionMatch.Length..], @"(?im)^#{1,4}\s+\S");
        if (nextHeading.Success)
        {
            section = section[..(sectionMatch.Length + nextHeading.Index)];
        }

        if (!Regex.IsMatch(section, @"\|\s*Type\s*\|\s*Ext\s*\|\s*Methods\s*\|", RegexOptions.IgnoreCase))
        {
            report.Errors.Add(new Diagnostic("EXTENSION_TABLE_MISSING", rel, ns.Name,
                $"The 'Extension Members' section for namespace {ns.Name} is missing the '|Type|Ext|Methods|' table header."));
            return;
        }

        // Every discovered extension method name must appear (backticked) in the section.
        foreach (var group in ns.ExtensionMethods.GroupBy(m => m.MethodName, StringComparer.Ordinal))
        {
            var methodName = group.Key;
            var pattern = "`" + Regex.Escape(methodName);
            if (!Regex.IsMatch(section, pattern + @"[`(]"))
            {
                report.Errors.Add(new Diagnostic("EXTENSION_METHOD_MISSING", rel, ns.Name,
                    $"Extension method `{methodName}` (extending {group.First().ExtendedType}) is not listed in the 'Extension Members' table for namespace {ns.Name}."));
            }
        }
    }

    private static bool HasFlyIn(string body)
    {
        foreach (var raw in body.Split('\n'))
        {
            var line = raw.Trim();
            if (line.Length == 0)
            {
                continue;
            }

            if (line.StartsWith('#') || line.StartsWith('|') || line.StartsWith("[!INCLUDE", StringComparison.OrdinalIgnoreCase) ||
                line.StartsWith("```", StringComparison.Ordinal) || line.StartsWith("---", StringComparison.Ordinal))
            {
                continue;
            }

            // Reject template placeholders like "contains types that ..." or bare ellipses / TODO.
            if (line.Contains("...", StringComparison.Ordinal) || line.Contains("TODO", StringComparison.OrdinalIgnoreCase) ||
                line.EndsWith("contains types that", StringComparison.OrdinalIgnoreCase))
            {
                continue;
            }

            if (line.Length >= 20)
            {
                return true;
            }
        }

        return false;
    }

    private static bool HasAvailability(string body)
    {
        if (body.Contains("[!INCLUDE", StringComparison.OrdinalIgnoreCase))
        {
            return true;
        }

        return Regex.IsMatch(body, @"(?im)^\s*Availability\s*:");
    }

    // ----------------------------------------------------------------------
    // Required example validation
    // ----------------------------------------------------------------------

    private static void ValidateRequiredExamples(string repoRoot, string docfxWorkspace, List<string> markdownFiles, ApiModel api,
        Options options, HashSet<string>? changedFiles, Report report)
    {
        var sections = new List<OverwriteSection>();
        foreach (var md in markdownFiles)
        {
            sections.AddRange(ExtractOverwriteSections(md));
        }

        foreach (var target in api.RequiredExampleTargets)
        {
            if (options.ChangedOnly && changedFiles is not null &&
                !ShouldValidateRequiredExampleTarget(target, changedFiles))
            {
                continue;
            }

            var candidates = sections.Where(s => IsExampleCandidate(s, target)).ToList();
            if (candidates.Any(s => HasExampleForTarget(s, target)))
            {
                report.Summary.RequiredExamples++;
                continue;
            }

            var expectedUid = target.Kind == ApiTargetKind.Type
                ? target.Uid
                : target.DeclaringTypeUid ?? target.Uid;
            var expectedPath = target.Kind == ApiTargetKind.Type
                ? Rel(repoRoot, Path.Combine(docfxWorkspace, "api", "namespaces", $"{target.Uid}.md"))
                : target.DeclaringTypeUid is null
                    ? null
                    : Rel(repoRoot, Path.Combine(docfxWorkspace, "api", "namespaces", $"{target.DeclaringTypeUid}.md"));

            var message = target.Kind == ApiTargetKind.Type
                ? $"Public non-abstraction type `{target.DisplayName}` requires a type-page DocFX overwrite example. Add an Examples section with a C# code fence to uid `{target.Uid}` in `{expectedPath}` or another overwrite file under `api/namespaces/` that targets this exact type UID. Namespace overview examples do not satisfy this diagnostic. Keep `api/namespaces/**/*.md` under `build.overwrite`, exclude `api/namespaces/**` from `build.content`, and do not use `api/**/*.md` under either section."
                : $"Public extension method `{target.DisplayName}` requires a DocFX overwrite example. Add an Examples section with a C# code fence to the declaring extension class uid `{expectedUid}` or the namespace page `{target.Namespace}` by default. The example must explicitly call `{target.DisplayName}`. Do not create URL-encoded or hash-like method UID filenames; use a method UID section only when the exact generated UID is verified and can live in a readable overwrite file.";

            report.Errors.Add(new Diagnostic("EXAMPLE_MISSING", expectedPath, target.Namespace, message));
        }
    }

    private static bool ShouldValidateNamespacePage(string page, HashSet<string> changedFiles)
    {
        return changedFiles.Contains(Path.GetFullPath(page)) || changedFiles.Any(IsChangedDocfxConfig);
    }

    private static bool ShouldValidateRequiredExampleTarget(ApiTargetInfo target, HashSet<string> changedFiles)
    {
        foreach (var changedFile in changedFiles)
        {
            if (IsChangedExampleCandidateFile(changedFile, target) || ChangedSourceTouchesTarget(changedFile, target))
            {
                return true;
            }
        }

        return false;
    }

    private static bool IsChangedExampleCandidateFile(string path, ApiTargetInfo target)
    {
        if (IsChangedDocfxConfig(path))
        {
            return true;
        }

        if (!string.Equals(Path.GetExtension(path), ".md", StringComparison.OrdinalIgnoreCase))
        {
            return false;
        }

        var stem = Path.GetFileNameWithoutExtension(path);
        if (string.Equals(stem, target.Namespace, StringComparison.Ordinal) ||
            string.Equals(stem, target.Uid, StringComparison.Ordinal))
        {
            return true;
        }

        return target.Kind == ApiTargetKind.ExtensionMethod &&
               string.Equals(stem, target.DeclaringTypeUid, StringComparison.Ordinal);
    }

    private static bool IsChangedDocfxConfig(string path)
    {
        return string.Equals(Path.GetFileName(path), "docfx.json", StringComparison.OrdinalIgnoreCase);
    }

    private static bool ChangedSourceTouchesTarget(string path, ApiTargetInfo target)
    {
        if (!string.Equals(Path.GetExtension(path), ".cs", StringComparison.OrdinalIgnoreCase))
        {
            return false;
        }

        string sourceText;
        try
        {
            sourceText = File.ReadAllText(path);
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
        {
            return false;
        }

        if (!Regex.IsMatch(sourceText, $@"(?m)^\s*namespace\s+{Regex.Escape(target.Namespace)}(?:\s*;|\s*\{{)"))
        {
            return false;
        }

        if (target.Kind == ApiTargetKind.Type)
        {
            return Regex.IsMatch(sourceText,
                $@"(?m)\b(?:class|struct|interface|enum|delegate|record(?:\s+class|\s+struct)?)\s+{Regex.Escape(target.DisplayName)}\b");
        }

        return Regex.IsMatch(sourceText, $@"(?s)\b{Regex.Escape(target.DisplayName)}\s*\([^)]*\bthis\b");
    }

    private static bool IsExampleCandidate(OverwriteSection section, ApiTargetInfo target)
    {
        if (string.Equals(section.Uid, target.Uid, StringComparison.Ordinal))
        {
            return true;
        }

        if (target.Kind == ApiTargetKind.ExtensionMethod)
        {
            return string.Equals(section.Uid, target.DeclaringTypeUid, StringComparison.Ordinal) ||
                   string.Equals(section.Uid, target.Namespace, StringComparison.Ordinal);
        }

        return false;
    }

    private static bool HasExampleForTarget(OverwriteSection section, ApiTargetInfo target)
    {
        if (!HasExampleSectionWithCSharpFence(section.Body))
        {
            return false;
        }

        if (target.Kind == ApiTargetKind.ExtensionMethod &&
            !section.Body.Contains(target.DisplayName, StringComparison.Ordinal))
        {
            return false;
        }

        return true;
    }

    private static bool HasExampleSectionWithCSharpFence(string body)
    {
        var match = Regex.Match(body, @"(?im)^#{2,5}\s+Examples?\s*$");
        if (!match.Success)
        {
            return false;
        }

        var section = body[match.Index..];
        var nextHeading = Regex.Match(section[match.Length..], @"(?im)^#{1,5}\s+\S");
        if (nextHeading.Success)
        {
            section = section[..(match.Length + nextHeading.Index)];
        }

        return Regex.IsMatch(section, @"(?im)^```\s*(csharp|cs)\s*$");
    }

    // ----------------------------------------------------------------------
    // Sample validation
    // ----------------------------------------------------------------------

    private static void ValidateSamples(string repoRoot, List<string> markdownFiles, List<ProjectInfo> libraryProjects,
        Options options, HashSet<string>? changedFiles, Report report)
    {
        var samples = new List<SampleFence>();
        foreach (var md in markdownFiles)
        {
            if (options.ChangedOnly && changedFiles is not null && !changedFiles.Contains(Path.GetFullPath(md)))
            {
                continue;
            }

            samples.AddRange(ExtractFences(md));
        }

        if (samples.Count == 0)
        {
            return;
        }

        var tempRoot = Path.Combine(Path.GetTempPath(), "docfx-digest-samples-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(tempRoot);
        try
        {
            int index = 0;
            foreach (var sample in samples)
            {
                index++;
                var skip = FindSkip(sample.Code);
                if (skip.Found)
                {
                    if (string.IsNullOrWhiteSpace(skip.Reason))
                    {
                        report.Errors.Add(new Diagnostic("SAMPLE_SKIP_REASON_MISSING", Rel(repoRoot, sample.File), null,
                            $"A C# sample at fence #{sample.FenceIndex} (line {sample.StartLine}) uses the skip-compile marker without a mandatory reason."));
                    }
                    else if (IsInsufficientSkipReason(skip.Reason))
                    {
                        report.Errors.Add(new Diagnostic("SAMPLE_SKIP_REASON_INSUFFICIENT", Rel(repoRoot, sample.File), null,
                            $"A C# sample at fence #{sample.FenceIndex} (line {sample.StartLine}) uses a weak skip-compile reason: '{skip.Reason}'. Package requirements, framework-pattern explanations, or full-example notes are documentation work, not a compile opt-out. Make the sample compile, document the package requirement outside the code fence, or use a deterministic blocker such as an external service or host environment that the sample compiler cannot provide."));
                    }
                    else
                    {
                        report.Summary.SamplesSkipped++;
                    }

                    continue;
                }

                var (ok, diagnostics, exitCode) = CompileSample(tempRoot, index, sample, libraryProjects, options.Configuration, repoRoot);
                if (ok)
                {
                    report.Summary.SamplesCompiled++;
                }
                else
                {
                    report.Errors.Add(new Diagnostic("SAMPLE_COMPILE_FAILED", Rel(repoRoot, sample.File), null,
                        $"C# sample at fence #{sample.FenceIndex} (line {sample.StartLine}) failed to compile (exit {exitCode}).\n{Trim(diagnostics)}"));
                }
            }
        }
        finally
        {
            TryDeleteDirectory(tempRoot);
        }
    }

    private static (bool Ok, string Diagnostics, int ExitCode) CompileSample(string tempRoot, int index, SampleFence sample,
        List<ProjectInfo> libraryProjects, string configuration, string repoRoot)
    {
        var dir = Path.Combine(tempRoot, "sample_" + index);
        Directory.CreateDirectory(dir);
        var file = Path.Combine(dir, "sample.cs");

        var sb = new StringBuilder();
        sb.Append("#:property TargetFramework=net10.0\n");
        sb.Append("#:property PublishAot=false\n");
        sb.Append("#:property Nullable=enable\n");
        foreach (var proj in libraryProjects)
        {
            sb.Append("#:project ").Append(proj.Path).Append('\n');
        }

        sb.Append('\n');
        sb.Append(sample.Code);
        if (!sample.Code.EndsWith('\n'))
        {
            sb.Append('\n');
        }

        File.WriteAllText(file, sb.ToString(), new UTF8Encoding(false));

        var signingProperty = HasRootStrongNameKey(repoRoot) ? string.Empty : " -p:SkipSignAssembly=true";
        var result = RunProcess("dotnet", $"build \"{file}\" -c {configuration} --nologo{signingProperty}", dir);
        return (result.ExitCode == 0, result.StdOut + result.StdErr, result.ExitCode);
    }

    private static List<SampleFence> ExtractFences(string mdFile)
    {
        var fences = new List<SampleFence>();
        string[] lines;
        try
        {
            lines = File.ReadAllLines(mdFile);
        }
        catch
        {
            return fences;
        }

        int fenceIndex = 0;
        for (int i = 0; i < lines.Length; i++)
        {
            var trimmed = lines[i].TrimStart();
            if (!trimmed.StartsWith("```", StringComparison.Ordinal))
            {
                continue;
            }

            var info = trimmed.TrimStart('`').Trim().ToLowerInvariant();
            int start = i;
            int j = i + 1;
            var content = new StringBuilder();
            while (j < lines.Length && !lines[j].TrimStart().StartsWith("```", StringComparison.Ordinal))
            {
                content.Append(lines[j]).Append('\n');
                j++;
            }

            if (info is "csharp" or "cs")
            {
                fenceIndex++;
                fences.Add(new SampleFence(mdFile, fenceIndex, start + 1, content.ToString()));
            }

            i = j; // continue after the closing fence
        }

        return fences;
    }

    private static List<OverwriteSection> ExtractOverwriteSections(string mdFile)
    {
        var sections = new List<OverwriteSection>();
        string text;
        try
        {
            text = File.ReadAllText(mdFile);
        }
        catch
        {
            return sections;
        }

        var normalized = text.Replace("\r\n", "\n").Replace("\r", "\n");
        var matches = Regex.Matches(normalized, @"(?ms)^---\s*\n(?<yaml>.*?)^---\s*$");
        for (var i = 0; i < matches.Count; i++)
        {
            var match = matches[i];
            var yaml = match.Groups["yaml"].Value;
            var uid = ReadYamlScalar(yaml, "uid");
            if (string.IsNullOrWhiteSpace(uid))
            {
                continue;
            }

            var bodyStart = match.Index + match.Length;
            if (bodyStart < normalized.Length && normalized[bodyStart] == '\n')
            {
                bodyStart++;
            }

            var bodyEnd = i + 1 < matches.Count ? matches[i + 1].Index : normalized.Length;
            var body = bodyEnd > bodyStart ? normalized[bodyStart..bodyEnd] : string.Empty;
            sections.Add(new OverwriteSection(mdFile, uid, body));
        }

        return sections;
    }

    private static (bool Found, string Reason) FindSkip(string code)
    {
        foreach (var line in code.Split('\n'))
        {
            var idx = line.IndexOf(SkipMarker, StringComparison.Ordinal);
            if (idx < 0)
            {
                continue;
            }

            var after = line[(idx + SkipMarker.Length)..].Trim();
            if (after.StartsWith('-'))
            {
                after = after[1..].Trim();
            }

            return (true, after);
        }

        return (false, string.Empty);
    }

    private static bool IsInsufficientSkipReason(string reason)
    {
        if (Regex.IsMatch(reason, @"(?i)\b(full\s+)?example\s+(shows|demonstrates|requires)\b"))
        {
            return true;
        }

        if (Regex.IsMatch(reason, @"(?i)\brequires\b.*\b(package|nuget|reference|dependency)\b"))
        {
            return true;
        }

        if (Regex.IsMatch(reason, @"(?i)\b(package|nuget)\b.*\b(required|dependency|reference)\b"))
        {
            return true;
        }

        return false;
    }

    // ----------------------------------------------------------------------
    // git changed-only
    // ----------------------------------------------------------------------

    private static HashSet<string>? GetChangedFiles(string repoRoot, Report report)
    {
        var result = RunProcess("git", "rev-parse --verify HEAD", repoRoot);
        if (result.ExitCode != 0)
        {
            return null;
        }

        var diff = RunProcess("git", "diff --name-only --diff-filter=ACMRTUXB HEAD", repoRoot);
        if (diff.ExitCode != 0)
        {
            return null;
        }

        var set = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        foreach (var line in diff.StdOut.Split('\n', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries))
        {
            set.Add(Path.GetFullPath(Path.Combine(repoRoot, line)));
        }

        return set;
    }

    // ----------------------------------------------------------------------
    // YAML / markdown helpers
    // ----------------------------------------------------------------------

    private static (string FrontMatter, string Body) SplitFrontMatter(string text)
    {
        var normalized = text.Replace("\r\n", "\n").Replace("\r", "\n");
        if (!normalized.StartsWith("---\n", StringComparison.Ordinal))
        {
            return (string.Empty, normalized);
        }

        var end = normalized.IndexOf("\n---", 3, StringComparison.Ordinal);
        if (end < 0)
        {
            return (string.Empty, normalized);
        }

        var frontMatter = normalized[4..end];
        var afterIdx = normalized.IndexOf('\n', end + 1);
        var body = afterIdx >= 0 ? normalized[(afterIdx + 1)..] : string.Empty;
        return (frontMatter, body);
    }

    private static string? ReadYamlScalar(string frontMatter, string key)
    {
        foreach (var raw in frontMatter.Split('\n'))
        {
            var line = raw.Trim();
            if (line.StartsWith(key + ":", StringComparison.Ordinal))
            {
                var value = line[(key.Length + 1)..].Trim();
                return value.Length == 0 ? null : value;
            }
        }

        return null;
    }

    // ----------------------------------------------------------------------
    // Process + output helpers
    // ----------------------------------------------------------------------

    private static ProcessResult RunProcess(string fileName, string arguments, string workingDirectory,
        IReadOnlyDictionary<string, string>? environment = null)
    {
        var psi = new ProcessStartInfo
        {
            FileName = fileName,
            Arguments = arguments,
            WorkingDirectory = workingDirectory,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            UseShellExecute = false,
            CreateNoWindow = true
        };

        if (environment is not null)
        {
            foreach (var (key, value) in environment)
            {
                psi.Environment[key] = value;
            }
        }

        try
        {
            using var process = Process.Start(psi);
            if (process is null)
            {
                return new ProcessResult(-1, string.Empty, $"Failed to start process '{fileName}'.");
            }

            var stdoutTask = Task.Run(() => process.StandardOutput.ReadToEnd());
            var stderrTask = Task.Run(() => process.StandardError.ReadToEnd());
            if (!process.WaitForExit(ProcessTimeout))
            {
                try
                {
                    process.Kill(entireProcessTree: true);
                }
                catch
                {
                    // ignore
                }

                process.WaitForExit(ProcessStreamDrainTimeout);
                Task.WaitAll([stdoutTask, stderrTask], ProcessStreamDrainTimeout);
                var stdout = stdoutTask.IsCompletedSuccessfully ? stdoutTask.Result : string.Empty;
                var stderr = stderrTask.IsCompletedSuccessfully ? stderrTask.Result : string.Empty;
                return new ProcessResult(-1, stdout, stderr + $"\nProcess '{fileName}' timed out after {ProcessTimeout.TotalMinutes} minutes.");
            }

            Task.WaitAll([stdoutTask, stderrTask]);
            return new ProcessResult(process.ExitCode, stdoutTask.Result, stderrTask.Result);
        }
        catch (Exception ex)
        {
            return new ProcessResult(-1, string.Empty, $"Failed to run '{fileName} {arguments}': {ex.Message}");
        }
    }

    private static void TryDeleteDirectory(string path)
    {
        try
        {
            if (Directory.Exists(path))
            {
                Directory.Delete(path, recursive: true);
            }
        }
        catch
        {
            // best effort
        }
    }

    private static string Rel(string root, string path)
    {
        try
        {
            return Path.GetRelativePath(root, path).Replace('\\', '/');
        }
        catch
        {
            return path;
        }
    }

    private static string Trim(string text)
    {
        const int max = 4000;
        text = text.Trim();
        return text.Length <= max ? text : text[..max] + "\n... (truncated)";
    }

    private static int Emit(Options options, Report report, ExitCode code, string consoleMessage)
    {
        if (report.Status is null)
        {
            report.Status = code == ExitCode.Success ? "passed" : "failed";
        }

        WriteRepairPlanIfRequested(options, report);

        report.Summary.Errors = report.Errors.Count;
        report.Summary.Warnings = report.Warnings.Count;

        if (options.Json)
        {
            Console.WriteLine(JsonSerializer.Serialize(report, JsonOptions));
        }
        else
        {
            Console.WriteLine($"{ScriptId}: {report.Status}: {consoleMessage}");
            foreach (var error in report.Errors)
            {
                Console.WriteLine($"  ERROR  [{error.Code}] {Describe(error)}");
            }

            foreach (var warning in report.Warnings)
            {
                Console.WriteLine($"  WARN   [{warning.Code}] {Describe(warning)}");
            }

            Console.WriteLine(
                $"  Summary: namespaces={report.Summary.PublicNamespaces}, pages={report.Summary.NamespacePagesValidated}, " +
                $"requiredExampleTargets={report.Summary.RequiredExampleTargets}, requiredExamples={report.Summary.RequiredExamples}, " +
                $"extMethods={report.Summary.ExtensionMethods}, samplesCompiled={report.Summary.SamplesCompiled}, " +
                $"samplesSkipped={report.Summary.SamplesSkipped}, generatedMetadataRemoved={report.Summary.GeneratedMetadataFilesRemoved}, " +
                $"generatedOutputDirectoriesRemoved={report.Summary.GeneratedOutputDirectoriesRemoved}, " +
                $"docfxBuildsVerified={report.Summary.DocfxBuildsVerified}, errors={report.Summary.Errors}, warnings={report.Summary.Warnings}");
        }

        return (int)code;
    }

    private static string Describe(Diagnostic d)
    {
        var location = d.Namespace is not null ? $"({d.Namespace}) " : string.Empty;
        var path = d.Path is not null ? $"{d.Path}: " : string.Empty;
        return $"{path}{location}{d.Message}";
    }

    private static void WriteRepairPlanIfRequested(Options options, Report report)
    {
        if (string.IsNullOrWhiteSpace(options.RepairPlanPath))
        {
            return;
        }

        try
        {
            var basePath = Directory.Exists(report.RepoRoot) ? report.RepoRoot : Directory.GetCurrentDirectory();
            var planPath = Path.GetFullPath(options.RepairPlanPath, basePath);
            var directory = Path.GetDirectoryName(planPath);
            if (!string.IsNullOrWhiteSpace(directory))
            {
                Directory.CreateDirectory(directory);
            }

            File.WriteAllText(planPath, BuildRepairPlan(report), new UTF8Encoding(false));
            report.RepairPlanPath = planPath;
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException or ArgumentException or NotSupportedException)
        {
            report.Warnings.Add(new Diagnostic("REPAIR_PLAN_WRITE_FAILED", options.RepairPlanPath, null,
                $"Unable to write repair plan: {ex.Message}"));
        }
    }

    private static string BuildRepairPlan(Report report)
    {
        var sb = new StringBuilder();
        sb.AppendLine("# DocFX Repair Plan");
        sb.AppendLine();
        sb.AppendLine($"Repository: `{report.RepoRoot}`");
        if (!string.IsNullOrWhiteSpace(report.DocfxPath))
        {
            sb.AppendLine($"DocFX config: `{report.DocfxPath}`");
        }

        sb.AppendLine($"Status: `{report.Status ?? "unknown"}`");
        sb.AppendLine();
        sb.AppendLine("## Summary");
        sb.AppendLine();
        sb.AppendLine($"- Public namespaces: {report.Summary.PublicNamespaces}");
        sb.AppendLine($"- Namespace pages validated: {report.Summary.NamespacePagesValidated}");
        sb.AppendLine($"- Required example targets: {report.Summary.RequiredExampleTargets}");
        sb.AppendLine($"- Required examples found: {report.Summary.RequiredExamples}");
        sb.AppendLine($"- Extension methods: {report.Summary.ExtensionMethods}");
        sb.AppendLine($"- Samples compiled: {report.Summary.SamplesCompiled}");
        sb.AppendLine($"- DocFX builds verified: {report.Summary.DocfxBuildsVerified}");
        sb.AppendLine($"- Errors: {report.Errors.Count}");
        sb.AppendLine($"- Warnings: {report.Warnings.Count}");
        sb.AppendLine();
        sb.AppendLine("## Execution Gates");
        sb.AppendLine();
        sb.AppendLine("- Do not use broad restore or checkout commands to recover documentation files.");
        sb.AppendLine("- Before deleting generated artifacts, list the exact paths and verify they are generated metadata, generated site output, or build artifacts.");
        sb.AppendLine("- Preserve authored `.md` and `.mdoc` files, including files created earlier in the run.");
        sb.AppendLine("- Treat uncommitted documentation changes as user work; stop and report them if they cannot be preserved.");
        sb.AppendLine("- Treat `Extension Members` tables as incomplete until required examples exist.");
        sb.AppendLine("- Repair related namespace pages together; do not update only the first page that exposes a shared issue.");
        sb.AppendLine("- After edits, inspect `git diff` for the touched documentation paths before final verification.");
        sb.AppendLine("- If examples cannot be sourced or compiled, report the limitation instead of claiming completion.");
        sb.AppendLine("- Rerun validation with `--verify-docfx-build` before claiming completion.");
        sb.AppendLine();

        AppendDiagnostics(sb, "Repository Guidance", report.Errors.Where(e => e.Code is "AGENTS_BLOCK_MISSING"));
        AppendDiagnostics(sb, "Namespace And Extension Table Repairs", report.Errors.Where(e =>
            e.Code.StartsWith("NAMESPACE_", StringComparison.Ordinal) ||
            e.Code.StartsWith("EXTENSION_", StringComparison.Ordinal)));
        AppendRequiredExampleDiagnostics(sb, report.Errors.Where(e => e.Code is "EXAMPLE_MISSING"));
        AppendDiagnostics(sb, "Sample Compilation Repairs", report.Errors.Where(e =>
            e.Code is "SAMPLE_COMPILE_FAILED" or "SAMPLE_SKIP_REASON_MISSING" or "SAMPLE_SKIP_REASON_INSUFFICIENT"));
        AppendDiagnostics(sb, "Other Errors", report.Errors.Where(e =>
            e.Code is not "AGENTS_BLOCK_MISSING" &&
            !e.Code.StartsWith("NAMESPACE_", StringComparison.Ordinal) &&
            !e.Code.StartsWith("EXTENSION_", StringComparison.Ordinal) &&
            e.Code is not "EXAMPLE_MISSING" &&
            e.Code is not "SAMPLE_COMPILE_FAILED" and not "SAMPLE_SKIP_REASON_MISSING" and not "SAMPLE_SKIP_REASON_INSUFFICIENT"));
        AppendDiagnostics(sb, "Warnings", report.Warnings);

        sb.AppendLine("## Completion Checklist");
        sb.AppendLine();
        sb.AppendLine("- [ ] `agents.cs` has run successfully when `AGENTS_BLOCK_MISSING` appears.");
        sb.AppendLine("- [ ] Every namespace diagnostic above has been resolved or intentionally excluded with evidence.");
        sb.AppendLine("- [ ] Every `EXAMPLE_MISSING` diagnostic above maps to a concrete example location.");
        sb.AppendLine("- [ ] Changed C# examples compile.");
        sb.AppendLine("- [ ] Authored Markdown files still exist after generated-artifact cleanup.");
        sb.AppendLine("- [ ] Final validation command and exit code are reported.");

        return sb.ToString();
    }

    private static void AppendDiagnostics(StringBuilder sb, string title, IEnumerable<Diagnostic> diagnostics)
    {
        var items = diagnostics
            .OrderBy(d => d.Namespace ?? string.Empty, StringComparer.Ordinal)
            .ThenBy(d => d.Path ?? string.Empty, StringComparer.Ordinal)
            .ThenBy(d => d.Code, StringComparer.Ordinal)
            .ThenBy(d => d.Message, StringComparer.Ordinal)
            .ToList();

        sb.AppendLine($"## {title}");
        sb.AppendLine();
        if (items.Count == 0)
        {
            sb.AppendLine("None.");
            sb.AppendLine();
            return;
        }

        foreach (var group in items.GroupBy(d => d.Namespace ?? "(repository)", StringComparer.Ordinal))
        {
            sb.AppendLine($"### {group.Key}");
            sb.AppendLine();
            foreach (var diagnostic in group)
            {
                var path = string.IsNullOrWhiteSpace(diagnostic.Path) ? string.Empty : $" `{diagnostic.Path}`";
                sb.AppendLine($"- `{diagnostic.Code}`{path}: {diagnostic.Message}");
            }

            sb.AppendLine();
        }
    }

    private static void AppendRequiredExampleDiagnostics(StringBuilder sb, IEnumerable<Diagnostic> diagnostics)
    {
        var items = diagnostics
            .OrderBy(d => d.Namespace ?? string.Empty, StringComparer.Ordinal)
            .ThenBy(d => d.Path ?? string.Empty, StringComparer.Ordinal)
            .ThenBy(d => d.Message, StringComparer.Ordinal)
            .ToList();

        sb.AppendLine("## Required Example Inventory");
        sb.AppendLine();
        if (items.Count == 0)
        {
            sb.AppendLine("None.");
            sb.AppendLine();
            return;
        }

        sb.AppendLine("Treat this section as the authoritative example work queue. Namespace overview pages and `Extension Members` tables are not complete until each item below maps to a concrete overwrite example and rerunning `docfx.cs --json` removes the diagnostic.");
        sb.AppendLine();
        sb.AppendLine("| Namespace | Expected overwrite location | Diagnostic | Required action |");
        sb.AppendLine("|---|---|---|---|");

        foreach (var diagnostic in items)
        {
            var ns = EscapeTable(diagnostic.Namespace ?? "(repository)");
            var path = EscapeTable(string.IsNullOrWhiteSpace(diagnostic.Path) ? "(method UID, declaring type UID, or namespace page)" : diagnostic.Path);
            var message = EscapeTable(diagnostic.Message);
            var action = diagnostic.Message.Contains("Public non-abstraction type", StringComparison.Ordinal)
                ? "Create or update the type-targeting overwrite file under `api/namespaces/`, keep `api/namespaces/**/*.md` under `build.overwrite` only, add a compiling Examples section, then rerun validation."
                : "Add a compiling Examples section on the declaring extension class or namespace page that explicitly calls the extension method, then rerun validation.";
            sb.AppendLine($"| {ns} | `{path}` | `EXAMPLE_MISSING` | {EscapeTable(action)} {message} |");
        }

        sb.AppendLine();
    }

    private static string EscapeTable(string value)
    {
        return value.Replace("|", "\\|", StringComparison.Ordinal).ReplaceLineEndings(" ");
    }

    // ----------------------------------------------------------------------
    // Argument parsing
    // ----------------------------------------------------------------------

    private static bool TryParse(string[] args, out Options options, out string error, out bool wantHelp)
    {
        options = new Options();
        error = string.Empty;
        wantHelp = false;

        for (int i = 0; i < args.Length; i++)
        {
            var arg = args[i];
            switch (arg)
            {
                case "--help":
                case "-h":
                    options.Help = true;
                    wantHelp = true;
                    return true;
                case "--repo-root":
                    if (!Next(args, ref i, out var rr)) { error = "--repo-root requires a path."; return false; }
                    options.RepoRoot = rr;
                    break;
                case "--docfx":
                    if (!Next(args, ref i, out var dx)) { error = "--docfx requires a path."; return false; }
                    options.DocfxPath = dx;
                    break;
                case "--configuration":
                    if (!Next(args, ref i, out var cfg)) { error = "--configuration requires a name."; return false; }
                    options.Configuration = cfg;
                    break;
                case "--framework":
                    if (!Next(args, ref i, out var fw)) { error = "--framework requires a TFM."; return false; }
                    options.Framework = fw;
                    break;
                case "--validate-samples":
                    options.ValidateSamples = true;
                    break;
                case "--no-validate-samples":
                    options.ValidateSamples = false;
                    break;
                case "--changed-only":
                    options.ChangedOnly = true;
                    break;
                case "--verify-docfx-build":
                    options.VerifyDocfxBuild = true;
                    break;
                case "--repair-plan":
                    if (!Next(args, ref i, out var rp)) { error = "--repair-plan requires a path."; return false; }
                    options.RepairPlanPath = rp;
                    break;
                case "--clean-generated-metadata":
                    options.CleanGeneratedMetadata = true;
                    break;
                case "--no-clean-generated-metadata":
                    options.CleanGeneratedMetadata = false;
                    break;
                case "--json":
                    options.Json = true;
                    break;
                default:
                    if (TrySplit(arg, "--repo-root", out var v1)) { options.RepoRoot = v1; break; }
                    if (TrySplit(arg, "--docfx", out var v2)) { options.DocfxPath = v2; break; }
                    if (TrySplit(arg, "--configuration", out var v3)) { options.Configuration = v3; break; }
                    if (TrySplit(arg, "--framework", out var v4)) { options.Framework = v4; break; }
                    if (TrySplit(arg, "--repair-plan", out var v5)) { options.RepairPlanPath = v5; break; }
                    error = $"Unknown argument: {arg}";
                    return false;
            }
        }

        return true;
    }

    private static bool Next(string[] args, ref int i, out string value)
    {
        if (i + 1 >= args.Length)
        {
            value = string.Empty;
            return false;
        }

        value = args[++i];
        return true;
    }

    private static bool TrySplit(string arg, string name, out string value)
    {
        var prefix = name + "=";
        if (arg.StartsWith(prefix, StringComparison.Ordinal))
        {
            value = arg[prefix.Length..];
            return true;
        }

        value = string.Empty;
        return false;
    }

    private static void PrintUsage()
    {
        Console.WriteLine(
            $"""
            {ScriptId} - validate DocFX documentation for .NET public APIs.

            Usage:
              dotnet run --file docfx.cs -- [options]

            Options:
              --repo-root <path>       Repository root. Default: current directory.
              --docfx <path>           Path to docfx.json. Default: .docfx/docfx.json under repo root.
              --configuration <name>   Build configuration. Default: Release.
              --framework <tfm>        Optional target framework to validate against.
              --validate-samples       Compile C# samples. Default: enabled.
              --no-validate-samples    Skip C# sample compilation.
              --changed-only           Validate only files changed according to git.
              --verify-docfx-build     Run DocFX against a temp copy of the repository so generated output stays outside the working tree.
              --repair-plan <path>     Write a deterministic Markdown repair plan from validation diagnostics.
              --clean-generated-metadata
                                      Remove DocFX-generated *.yml and manifest files under metadata.dest. Default: enabled.
              --no-clean-generated-metadata
                                      Leave DocFX-generated metadata files untouched.
              --json                   Emit a machine-readable JSON summary.
              --help                   Print this usage.

            Exit codes:
              0  Validation passed.
              1  Validation failed.
              2  Invalid arguments.
              3  Repository root does not exist.
              4  DocFX configuration file not found.
              5  Build failed.
              6  Public API discovery failed.
              7  Sample compilation failed.
              8  Unexpected internal error.
            """);
    }

    private enum ExitCode
    {
        Success = 0,
        ValidationFailed = 1,
        InvalidArguments = 2,
        RepoRootMissing = 3,
        DocfxConfigMissing = 4,
        BuildFailed = 5,
        PublicApiDiscoveryFailed = 6,
        SampleCompilationFailed = 7,
        InternalError = 8
    }

    private sealed class Options
    {
        public string? RepoRoot { get; set; }
        public string? DocfxPath { get; set; }
        public string Configuration { get; set; } = "Release";
        public string? Framework { get; set; }
        public string? RepairPlanPath { get; set; }
        public bool ValidateSamples { get; set; } = true;
        public bool ChangedOnly { get; set; }
        public bool VerifyDocfxBuild { get; set; }
        public bool CleanGeneratedMetadata { get; set; } = true;
        public bool Json { get; set; }
        public bool Help { get; set; }
    }

    private sealed record ProjectInfo(string Path, string AssemblyName, List<string> TargetFrameworks, bool IsTest);

    private sealed record ExtensionMethodInfo(string MethodName, string ExtendedType, string DeclaringClass);

    private sealed record ApiTargetInfo(string Uid, string Namespace, ApiTargetKind Kind, string DisplayName, string? DeclaringTypeUid = null);

    private enum ApiTargetKind
    {
        Type,
        ExtensionMethod
    }

    private sealed class NamespaceInfo(string name)
    {
        public string Name { get; } = name;
        public List<ApiTargetInfo> RequiredExampleTargets { get; } = new();
        public List<ExtensionMethodInfo> ExtensionMethods { get; } = new();
    }

    private sealed record ApiModel(List<NamespaceInfo> Namespaces, List<ApiTargetInfo> RequiredExampleTargets);

    private sealed record SampleFence(string File, int FenceIndex, int StartLine, string Code);

    private sealed record OverwriteSection(string File, string Uid, string Body);

    private sealed record ProcessResult(int ExitCode, string StdOut, string StdErr);
}

internal sealed class Diagnostic
{
    public Diagnostic(string code, string? path, string? @namespace, string message)
    {
        Code = code;
        Path = path;
        Namespace = @namespace;
        Message = message;
    }

    [JsonPropertyName("code")] public string Code { get; }
    [JsonPropertyName("path")] public string? Path { get; }
    [JsonPropertyName("namespace")] public string? Namespace { get; }
    [JsonPropertyName("message")] public string Message { get; }
}

internal sealed class Summary
{
    public int PublicNamespaces { get; set; }
    public int NamespacePagesValidated { get; set; }
    public int RequiredExampleTargets { get; set; }
    public int RequiredExamples { get; set; }
    public int ExtensionMethods { get; set; }
    public int SamplesCompiled { get; set; }
    public int SamplesSkipped { get; set; }
    public int GeneratedMetadataFilesRemoved { get; set; }
    public int GeneratedOutputDirectoriesRemoved { get; set; }
    public int DocfxBuildsVerified { get; set; }
    public int Errors { get; set; }
    public int Warnings { get; set; }
}

internal sealed class Report
{
    public string Script { get; set; } = string.Empty;
    public string RepoRoot { get; set; } = string.Empty;
    public string? DocfxPath { get; set; }
    public string? RepairPlanPath { get; set; }
    public string? Status { get; set; }
    public Summary Summary { get; set; } = new();
    public List<Diagnostic> Errors { get; set; } = new();
    public List<Diagnostic> Warnings { get; set; } = new();
}
