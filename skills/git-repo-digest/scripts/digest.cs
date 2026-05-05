#:property TargetFramework=net10.0
#:property Nullable=enable
#:property LangVersion=latest
#:property PublishAot=false

using System.Diagnostics;
using System.Text;
using System.Text.Json;
using System.Text.RegularExpressions;
using System.Xml.Linq;

return await DigestScript.RunAsync(args);

internal static class DigestScript
{
    private const string ResultDirectoryName = "result";
    private const string SourceDirectoryName = "src";
    private const string TestDirectoryName = "test";
    private const int MaxContextChunkBodyBytes = 36 * 1024;
    private static readonly string[] OwnedTestProjectSuffixes = ["Tests", "FunctionalTests"];
    private static readonly Regex PublicTypeExpression = new(
        @"(?m)^\s*(?:\[[^\]]+\]\s*)*(?:public|protected\s+internal|internal\s+protected)\s+(?:(?:static|abstract|sealed|partial|readonly|unsafe)\s+)*(?<kind>record\s+class|record\s+struct|class|interface|struct|record|enum)\s+(?<name>[A-Za-z_][A-Za-z0-9_]*(?:<[^>{};]+>)?)\s*(?::\s*(?<base>[^{]+))?",
        RegexOptions.Compiled);

    private static readonly Regex PublicMemberExpression = new(
        @"(?m)^\s*(?:\[[^\]]+\]\s*)*(?:public|protected(?:\s+internal)?|internal\s+protected)\s+(?<decl>[^\r\n{;]+(?:\([^\r\n;{}]*\))?)",
        RegexOptions.Compiled);

    public static async Task<int> RunAsync(string[] args)
    {
        if (args.Length == 0 || HasFlag(args, "--help") || HasFlag(args, "-h"))
        {
            PrintUsage();
            return 0;
        }

        try
        {
            var options = ParseOptions(args);
            var repoId = DeriveRepoId(options.RepoUrl);
            var workspace = Path.GetFullPath(Path.Combine(options.OutputRoot, repoId));
            var resultDir = Path.Combine(workspace, ResultDirectoryName);

            Directory.CreateDirectory(workspace);
            Directory.CreateDirectory(resultDir);

            Console.WriteLine($"[digest] repo-url={options.RepoUrl}");
            Console.WriteLine($"[digest] output-root={options.OutputRoot}");
            Console.WriteLine($"[digest] repo-id={repoId}");
            Console.WriteLine();

            var tempRoot = Path.Combine(Path.GetTempPath(), "git-repo-digest-" + Guid.NewGuid().ToString("N"));
            Directory.CreateDirectory(tempRoot);

            try
            {
                var cloneDir = Path.Combine(tempRoot, "repo");
                await CloneRepositoryAsync(options.RepoUrl, cloneDir);

                var packages = DiscoverPackages(cloneDir);
                Console.WriteLine($"[digest] discovered {packages.Count} package(s)");

                var packageEntries = new List<PackageManifestEntry>();
                foreach (var package in packages)
                {
                    var contextFileName = package.Name + ".context.md";
                    var resultPath = Path.Combine(ResultDirectoryName, package.Name + ".md").Replace('\\', '/');
                    var context = await BuildPackageContextAsync(options.RepoUrl, cloneDir, package);
                    var contextArtifacts = await WriteContextArtifactsAsync(workspace, contextFileName, context);

                    packageEntries.Add(new PackageManifestEntry(
                        "package",
                        package.Name,
                        contextArtifacts.ContextPath,
                        contextArtifacts.IndexPath,
                        contextArtifacts.ChunkPaths,
                        resultPath));
                }

                var overviewContextName = "overview.context.md";
                var overviewContext = await BuildOverviewContextAsync(options.RepoUrl, cloneDir, repoId, packages);
                var overviewArtifacts = await WriteContextArtifactsAsync(workspace, overviewContextName, overviewContext);

                await WriteUtf8Async(Path.Combine(workspace, "instructions.md"), BuildInstructions(options.RepoUrl, repoId));
                await WriteManifestAsync(
                    Path.Combine(workspace, "manifest.json"),
                    options,
                    repoId,
                    workspace,
                    packageEntries,
                    overviewArtifacts);

                Console.WriteLine();
                Console.WriteLine("[digest] deterministic workspace written:");
                Console.WriteLine("  " + workspace);
                Console.WriteLine("[digest] result files are agent-authored and were not overwritten.");
                return 0;
            }
            finally
            {
                TryDeleteDirectory(tempRoot);
            }
        }
        catch (Exception ex)
        {
            Console.Error.WriteLine("Error: " + ex.Message);
            return 1;
        }
    }

    private static DigestOptions ParseOptions(string[] args)
    {
        var repoUrl = GetOption(args, "--repo-url");
        var outputRoot = GetOption(args, "--output-root");

        if (string.IsNullOrWhiteSpace(repoUrl))
        {
            throw new InvalidOperationException("Missing required option --repo-url.");
        }

        if (string.IsNullOrWhiteSpace(outputRoot))
        {
            throw new InvalidOperationException("Missing required option --output-root.");
        }

        ValidateRepositoryUrl(repoUrl);
        return new DigestOptions(repoUrl.Trim(), Path.GetFullPath(outputRoot.Trim()));
    }

    private static string? GetOption(string[] args, string name)
    {
        var index = Array.IndexOf(args, name);
        return index >= 0 && index + 1 < args.Length ? args[index + 1] : null;
    }

    private static bool HasFlag(string[] args, string name) => Array.IndexOf(args, name) >= 0;

    private static void ValidateRepositoryUrl(string repoUrl)
    {
        if (!Uri.TryCreate(repoUrl, UriKind.Absolute, out var uri))
        {
            throw new InvalidOperationException("--repo-url must be a fully qualified repository URL.");
        }

        if (uri.Scheme is not ("http" or "https" or "ssh" or "git"))
        {
            throw new InvalidOperationException("--repo-url must use http, https, ssh, or git scheme.");
        }
    }

    private static string DeriveRepoId(string repoUrl)
    {
        var uri = new Uri(repoUrl);
        var path = uri.AbsolutePath.Trim('/');
        if (string.IsNullOrWhiteSpace(path))
        {
            throw new InvalidOperationException("Could not derive repo id because --repo-url has no path segment.");
        }

        var lastSegment = path.Split('/', StringSplitOptions.RemoveEmptyEntries).Last();
        if (lastSegment.EndsWith(".git", StringComparison.OrdinalIgnoreCase))
        {
            lastSegment = lastSegment[..^4];
        }

        var sanitized = Regex.Replace(lastSegment, "[^A-Za-z0-9._-]", "-").Trim('-', '.', '_');
        if (string.IsNullOrWhiteSpace(sanitized))
        {
            throw new InvalidOperationException("Could not derive a filesystem-safe repo id from --repo-url.");
        }

        return sanitized.ToLowerInvariant();
    }

    private static async Task CloneRepositoryAsync(string repoUrl, string cloneDir)
    {
        Console.WriteLine("[digest] cloning repository for discovery...");
        await RunProcessAsync("git", ["clone", "--depth", "1", repoUrl, cloneDir], Directory.GetCurrentDirectory());
    }

    private static IReadOnlyList<PackageInfo> DiscoverPackages(string cloneDir)
    {
        var srcDir = Path.Combine(cloneDir, SourceDirectoryName);
        if (!Directory.Exists(srcDir))
        {
            return [];
        }

        var projectFiles = Directory.EnumerateFiles(srcDir, "*.csproj", SearchOption.AllDirectories)
            .OrderBy(p => Path.GetRelativePath(cloneDir, p), StringComparer.OrdinalIgnoreCase)
            .ToList();

        var packages = new List<PackageInfo>();
        foreach (var projectFile in projectFiles)
        {
            var metadata = ReadProjectMetadata(projectFile);
            if (metadata.IsPackable is false)
            {
                continue;
            }

            var name = FirstNonEmpty(
                metadata.PackageId,
                metadata.AssemblyName,
                Path.GetFileNameWithoutExtension(projectFile));

            var sourceDir = Path.GetDirectoryName(projectFile)
                ?? throw new InvalidOperationException($"Could not resolve source directory for '{projectFile}'.");

            var testDir = FindTestDirectory(cloneDir, projectFile, name);
            var sourceFiles = Directory.EnumerateFiles(sourceDir, "*.cs", SearchOption.AllDirectories)
                .Where(p => !IsUnderDirectoryName(p, "bin") && !IsUnderDirectoryName(p, "obj"))
                .ToList();

            packages.Add(new PackageInfo(
                name,
                Path.GetRelativePath(cloneDir, sourceDir).Replace('\\', '/'),
                testDir is null ? null : Path.GetRelativePath(cloneDir, testDir).Replace('\\', '/'),
                sourceFiles.Count == 0,
                metadata.BundledPackages));
        }

        return packages;
    }

    private static ProjectMetadata ReadProjectMetadata(string projectFile)
    {
        var doc = XDocument.Load(projectFile, LoadOptions.PreserveWhitespace);
        var packageId = ElementValue(doc, "PackageId");
        var assemblyName = ElementValue(doc, "AssemblyName");
        var isPackableText = ElementValue(doc, "IsPackable");
        bool? isPackable = null;
        if (!string.IsNullOrWhiteSpace(isPackableText) && bool.TryParse(isPackableText, out var parsed))
        {
            isPackable = parsed;
        }

        var bundledPackages = doc.Descendants()
            .Where(e => e.Name.LocalName is "PackageReference" or "ProjectReference")
            .Select(e => e.Attribute("Include")?.Value)
            .Where(v => !string.IsNullOrWhiteSpace(v))
            .Select(v => v!)
            .Distinct(StringComparer.OrdinalIgnoreCase)
            .OrderBy(v => v, StringComparer.OrdinalIgnoreCase)
            .ToList();

        return new ProjectMetadata(packageId, assemblyName, isPackable, bundledPackages);
    }

    private static string ElementValue(XDocument doc, string localName) =>
        doc.Descendants().FirstOrDefault(e => e.Name.LocalName == localName)?.Value.Trim() ?? string.Empty;

    private static string FirstNonEmpty(params string[] values) =>
        values.First(v => !string.IsNullOrWhiteSpace(v)).Trim();

    private static string? FindTestDirectory(string cloneDir, string sourceProjectFile, string packageName)
    {
        var testRoot = Path.Combine(cloneDir, TestDirectoryName);
        if (!Directory.Exists(testRoot))
        {
            return null;
        }

        var normalizedPackage = NormalizeForMatch(packageName);
        var candidates = new List<TestProjectMatch>();
        var testProjects = Directory.EnumerateFiles(testRoot, "*.csproj", SearchOption.AllDirectories)
            .OrderBy(p => p, StringComparer.OrdinalIgnoreCase)
            .ToList();

        foreach (var testProject in testProjects)
        {
            candidates.Add(new TestProjectMatch(
                testProject,
                IsOwnTestProjectName(testProject, normalizedPackage),
                ReferencesProject(testProject, sourceProjectFile)));
        }

        var ownMatch = candidates
            .Where(c => c.IsOwnTestProjectName)
            .OrderByDescending(c => c.ReferencesProject)
            .ThenBy(c => c.ProjectFile, StringComparer.OrdinalIgnoreCase)
            .FirstOrDefault();
        if (ownMatch is not null)
        {
            return Path.GetDirectoryName(ownMatch.ProjectFile);
        }

        var directMatches = candidates
            .Where(c => c.ReferencesProject)
            .OrderBy(c => c.ProjectFile, StringComparer.OrdinalIgnoreCase)
            .ToList();
        return directMatches.Count == 1 ? Path.GetDirectoryName(directMatches[0].ProjectFile) : null;
    }

    private static bool IsOwnTestProjectName(string testProjectFile, string normalizedPackage)
    {
        var normalizedProjectName = NormalizeForMatch(Path.GetFileNameWithoutExtension(testProjectFile));
        return OwnedTestProjectSuffixes
            .Select(NormalizeForMatch)
            .Any(suffix => string.Equals(normalizedProjectName, normalizedPackage + suffix, StringComparison.OrdinalIgnoreCase));
    }

    private static bool ReferencesProject(string testProjectFile, string sourceProjectFile)
    {
        var testProjectDir = Path.GetDirectoryName(testProjectFile)
            ?? throw new InvalidOperationException($"Could not resolve project directory for '{testProjectFile}'.");

        var sourceFullPath = Path.GetFullPath(sourceProjectFile);
        var doc = XDocument.Load(testProjectFile, LoadOptions.PreserveWhitespace);
        foreach (var include in doc.Descendants().Where(e => e.Name.LocalName == "ProjectReference").Select(e => e.Attribute("Include")?.Value))
        {
            if (string.IsNullOrWhiteSpace(include))
            {
                continue;
            }

            var referenced = Path.GetFullPath(Path.Combine(testProjectDir, include));
            if (string.Equals(referenced, sourceFullPath, StringComparison.OrdinalIgnoreCase))
            {
                return true;
            }
        }

        return false;
    }

    private static string NormalizeForMatch(string value) =>
        Regex.Replace(value, "[^A-Za-z0-9]", string.Empty).ToLowerInvariant();

    private static bool IsUnderDirectoryName(string path, string directoryName)
    {
        var segments = Path.GetFullPath(path).Split(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar);
        return segments.Any(s => string.Equals(s, directoryName, StringComparison.OrdinalIgnoreCase));
    }

    private static async Task<string> BuildPackageContextAsync(string repoUrl, string cloneDir, PackageInfo package)
    {
        Console.WriteLine($"[digest] packing context for {package.Name}...");

        var includeParts = new List<string>
        {
            "README.md",
            "Directory.Build.props",
            "Directory.Build.targets",
            "Directory.Packages.props",
            package.SourcePath + "/**"
        };

        if (!string.IsNullOrWhiteSpace(package.TestPath))
        {
            includeParts.Add(package.TestPath + "/**");
        }

        includeParts.Add(".nuget/**/README.md");
        var packedContent = await PackRepositoryContentAsync(cloneDir, string.Join(',', includeParts));

        var sb = new StringBuilder();
        AppendHeader(sb, "PACKAGE IDENTITY");
        sb.AppendLine($"Repository: {repoUrl}");
        sb.AppendLine($"Package: {package.Name}");
        sb.AppendLine("Kind: package");
        sb.AppendLine($"Source path: {package.SourcePath}");
        sb.AppendLine($"Test path: {package.TestPath ?? "(not discovered)"}");
        sb.AppendLine($"Metadata-only package: {package.IsConveniencePackage}");
        sb.AppendLine($"Result path: result/{package.Name}.md");
        sb.AppendLine();

        if (package.BundledPackages.Count > 0)
        {
            AppendHeader(sb, "DECLARED REFERENCES");
            foreach (var reference in package.BundledPackages)
            {
                sb.AppendLine("- " + reference);
            }
            sb.AppendLine();
        }

        AppendHeader(sb, "PUBLIC API SUMMARY (GENERATED)");
        AppendMultiline(sb, BuildPublicApiSummary(cloneDir, package));

        AppendHeader(sb, "ENGINEERING SIGNALS (GENERATED)");
        AppendMultiline(sb, BuildEngineeringSignals(cloneDir, package));

        AppendHeader(sb, "PACKAGE DIGEST PROMPT");
        AppendMultiline(sb, BuildPackageDigestPrompt(package.Name));

        AppendHeader(sb, "PACKED REPOSITORY CONTENT");
        sb.AppendLine(packedContent.Trim());
        sb.AppendLine();

        return sb.ToString();
    }

    private static async Task<string> BuildOverviewContextAsync(string repoUrl, string cloneDir, string repoId, IReadOnlyList<PackageInfo> packages)
    {
        Console.WriteLine("[digest] packing overview context...");
        var packedContent = await PackRepositoryContentAsync(
            cloneDir,
            "README.md,.nuget/**/README.md,Directory.Build.props,Directory.Build.targets,Directory.Packages.props,src/**/*.csproj,test/**/*.csproj");

        var sb = new StringBuilder();
        AppendHeader(sb, "REPOSITORY IDENTITY");
        sb.AppendLine($"Repository: {repoUrl}");
        sb.AppendLine($"Repository id: {repoId}");
        sb.AppendLine($"Packages: {packages.Count}");
        sb.AppendLine("Result path: result/Index.md");
        sb.AppendLine();

        AppendHeader(sb, "REQUIRED COMPLETED PACKAGE DIGEST SOURCES");
        if (packages.Count == 0)
        {
            sb.AppendLine("No packages were discovered under src/. Write an overview only if the repository context is sufficient.");
        }
        else
        {
            sb.AppendLine("Before writing result/Index.md, open and read every completed package digest listed below.");
            sb.AppendLine("These completed package digests are the primary source for the overview; this overview context file is only supplementary.");
            sb.AppendLine("If your execution log would show only overview.context.md being read for the overview phase, stop and read the package digests first.");
            sb.AppendLine();
            foreach (var package in packages)
            {
                sb.AppendLine($"- {package.Name}: result/{package.Name}.md");
            }
        }
        sb.AppendLine();

        AppendHeader(sb, "OVERVIEW DIGEST PROMPT");
        AppendMultiline(sb, BuildOverviewDigestPrompt(repoId, packages));

        AppendHeader(sb, "SUPPLEMENTARY REPOSITORY CONTENT");
        sb.AppendLine(packedContent.Trim());
        sb.AppendLine();

        return sb.ToString();
    }

    private static string BuildPublicApiSummary(string cloneDir, PackageInfo package)
    {
        var discoveredApiTypes = DiscoverPublicApiTypes(cloneDir, package);
        var apiTypes = discoveredApiTypes.Take(20).ToList();
        if (apiTypes.Count == 0)
        {
            return "No public or protected API candidates were discovered by the lightweight source scanner. Treat the packed source context as authoritative.";
        }

        var sb = new StringBuilder();
        sb.AppendLine("This section is a deterministic navigation aid extracted from source text. Use it to focus the complete read, but treat the packed source context below as authoritative.");
        sb.AppendLine();
        sb.AppendLine("| Type | Kind | Inherits / implements | Public or protected member candidates | Source |");
        sb.AppendLine("|---|---|---|---|---|");
        foreach (var apiType in apiTypes)
        {
            var members = apiType.Members.Count == 0
                ? "(none discovered)"
                : string.Join("<br>", apiType.Members.Take(6).Select(EscapeMarkdownTableCell));

            sb.AppendLine($"| `{EscapeMarkdownTableCell(apiType.Name)}` | {EscapeMarkdownTableCell(apiType.Kind)} | {EscapeMarkdownTableCell(apiType.BaseTypes)} | {members} | `{EscapeMarkdownTableCell(apiType.SourcePath)}` |");
        }

        if (discoveredApiTypes.Count > apiTypes.Count)
        {
            sb.AppendLine();
            sb.AppendLine($"Only the first {apiTypes.Count} of {discoveredApiTypes.Count} API candidates are shown. Read the packed source context for the full surface.");
        }

        return sb.ToString();
    }

    private static IReadOnlyList<ApiTypeSummary> DiscoverPublicApiTypes(string cloneDir, PackageInfo package)
    {
        var sourceDir = Path.Combine(cloneDir, package.SourcePath.Replace('/', Path.DirectorySeparatorChar));
        if (!Directory.Exists(sourceDir))
        {
            return [];
        }

        var sourceFiles = Directory.EnumerateFiles(sourceDir, "*.cs", SearchOption.AllDirectories)
            .Where(p => !IsUnderDirectoryName(p, "bin") && !IsUnderDirectoryName(p, "obj"))
            .Where(p => !ShouldSkipLowSignalFile(Path.GetRelativePath(cloneDir, p).Replace('\\', '/')))
            .OrderBy(p => Path.GetRelativePath(cloneDir, p), StringComparer.OrdinalIgnoreCase)
            .ToList();

        var summaries = new List<ApiTypeSummary>();
        foreach (var sourceFile in sourceFiles)
        {
            var text = File.ReadAllText(sourceFile, Encoding.UTF8);
            var relativePath = Path.GetRelativePath(cloneDir, sourceFile).Replace('\\', '/');
            foreach (Match match in PublicTypeRegex().Matches(text))
            {
                var name = NormalizeDeclaration(match.Groups["name"].Value);
                var kind = NormalizeDeclaration(match.Groups["kind"].Value);
                var baseTypes = NormalizeDeclaration(match.Groups["base"].Success ? match.Groups["base"].Value : string.Empty);
                if (string.IsNullOrWhiteSpace(baseTypes))
                {
                    baseTypes = "(none declared)";
                }

                var body = TryExtractTypeBody(text, match.Index);
                var members = body is null
                    ? Array.Empty<string>()
                    : ExtractPublicMemberCandidates(body, GetSimpleTypeName(name)).Take(8).ToArray();

                summaries.Add(new ApiTypeSummary(name, kind, baseTypes, members, relativePath));
            }
        }

        return summaries
            .OrderBy(s => s.SourcePath, StringComparer.OrdinalIgnoreCase)
            .ThenBy(s => s.Name, StringComparer.OrdinalIgnoreCase)
            .ToList();
    }

    private static string BuildEngineeringSignals(string cloneDir, PackageInfo package)
    {
        var files = EnumerateSignalFiles(cloneDir, package).ToList();
        var exceptionSignals = FindSignals(files, @"(?:throw\s+new|Assert\.Throws(?:Async)?)\s*<?([A-Za-z0-9_.]+Exception)", "exception guard").Take(12).ToList();
        var lifecycleSignals = FindSignals(files, @"\b([A-Za-z0-9_]*(?:Configure|Callback|Fixture|Factory|Initialize|Dispose|Lifetime|Host|Application)[A-Za-z0-9_]*)\b", "lifecycle or composition name").Take(16).ToList();
        var hostingSignals = FindSignals(files, @"\b(IHostBuilder|HostApplicationBuilder|Host\.CreateApplicationBuilder|WebApplicationBuilder|IApplicationBuilder|WebApplicationFactory|TestServer)\b", "hosting model").Take(12).ToList();
        var testSignals = files
            .Where(f => IsProbablyTestFile(f.RelativePath))
            .Select(f => f.RelativePath)
            .Distinct(StringComparer.OrdinalIgnoreCase)
            .OrderBy(p => p, StringComparer.OrdinalIgnoreCase)
            .Take(12)
            .ToList();

        var sb = new StringBuilder();
        sb.AppendLine("This section is a deterministic signal map. It highlights places where the code may reveal design invariants, lifecycle contracts, package boundaries, or test-backed behavior. Validate every claim against the raw source context before writing.");
        sb.AppendLine();

        AppendSignalGroup(sb, "Exception guards and validation evidence", exceptionSignals);
        AppendSignalGroup(sb, "Lifecycle, callback, factory, and composition names", lifecycleSignals);
        AppendSignalGroup(sb, "Hosting model markers", hostingSignals);

        sb.AppendLine("### Test evidence files");
        if (testSignals.Count == 0)
        {
            sb.AppendLine("- No test files were discovered for this package.");
        }
        else
        {
            foreach (var path in testSignals)
            {
                sb.AppendLine("- `" + path + "`");
            }
        }

        return sb.ToString();
    }

    private static IEnumerable<SignalFile> EnumerateSignalFiles(string cloneDir, PackageInfo package)
    {
        var roots = new[] { package.SourcePath, package.TestPath }
            .Where(p => !string.IsNullOrWhiteSpace(p))
            .Select(p => Path.Combine(cloneDir, p!.Replace('/', Path.DirectorySeparatorChar)))
            .Where(Directory.Exists)
            .Distinct(StringComparer.OrdinalIgnoreCase);

        foreach (var root in roots)
        {
            foreach (var file in Directory.EnumerateFiles(root, "*.cs", SearchOption.AllDirectories)
                         .Where(p => !IsUnderDirectoryName(p, "bin") && !IsUnderDirectoryName(p, "obj"))
                         .Where(p => !ShouldSkipLowSignalFile(Path.GetRelativePath(cloneDir, p).Replace('\\', '/')))
                         .OrderBy(p => Path.GetRelativePath(cloneDir, p), StringComparer.OrdinalIgnoreCase))
            {
                yield return new SignalFile(
                    Path.GetRelativePath(cloneDir, file).Replace('\\', '/'),
                    File.ReadAllText(file, Encoding.UTF8));
            }
        }
    }

    private static IEnumerable<EngineeringSignal> FindSignals(IEnumerable<SignalFile> files, string pattern, string kind)
    {
        var seen = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        foreach (var file in files)
        {
            foreach (Match match in Regex.Matches(file.Content, pattern, RegexOptions.Multiline))
            {
                var value = match.Groups.Count > 1 && match.Groups[1].Success
                    ? match.Groups[1].Value
                    : match.Value;
                value = NormalizeDeclaration(value);
                if (string.IsNullOrWhiteSpace(value))
                {
                    continue;
                }

                var key = file.RelativePath + "|" + value;
                if (!seen.Add(key))
                {
                    continue;
                }

                yield return new EngineeringSignal(kind, value, file.RelativePath);
            }
        }
    }

    private static void AppendSignalGroup(StringBuilder sb, string heading, IReadOnlyList<EngineeringSignal> signals)
    {
        sb.AppendLine("### " + heading);
        if (signals.Count == 0)
        {
            sb.AppendLine("- None discovered by the lightweight scanner.");
            sb.AppendLine();
            return;
        }

        foreach (var signal in signals)
        {
            sb.AppendLine($"- `{signal.Value}` in `{signal.SourcePath}`");
        }
        sb.AppendLine();
    }

    private static string? TryExtractTypeBody(string text, int typeStartIndex)
    {
        var openBrace = text.IndexOf('{', typeStartIndex);
        if (openBrace < 0)
        {
            return null;
        }

        var depth = 0;
        for (var i = openBrace; i < text.Length; i++)
        {
            if (text[i] == '{')
            {
                depth++;
            }
            else if (text[i] == '}')
            {
                depth--;
                if (depth == 0)
                {
                    return text[(openBrace + 1)..i];
                }
            }
        }

        return null;
    }

    private static IEnumerable<string> ExtractPublicMemberCandidates(string body, string simpleTypeName)
    {
        var members = new List<string>();
        foreach (Match match in PublicMemberRegex().Matches(body))
        {
            var declaration = NormalizeDeclaration(match.Groups["decl"].Value);
            if (string.IsNullOrWhiteSpace(declaration))
            {
                continue;
            }

            if (declaration.Contains(" class ", StringComparison.Ordinal)
                || declaration.Contains(" interface ", StringComparison.Ordinal)
                || declaration.Contains(" struct ", StringComparison.Ordinal)
                || declaration.Contains(" record ", StringComparison.Ordinal))
            {
                continue;
            }

            members.Add(declaration);
        }

        return members
            .Distinct(StringComparer.OrdinalIgnoreCase)
            .OrderByDescending(m => m.Contains(simpleTypeName + "(", StringComparison.Ordinal))
            .ThenBy(m => m, StringComparer.OrdinalIgnoreCase);
    }

    private static string NormalizeDeclaration(string value) =>
        Regex.Replace(value.ReplaceLineEndings(" "), @"\s+", " ").Trim().TrimEnd('{', ';').Trim();

    private static string GetSimpleTypeName(string name)
    {
        var index = name.IndexOf('<', StringComparison.Ordinal);
        return index >= 0 ? name[..index] : name;
    }

    private static bool IsProbablyTestFile(string relativePath)
    {
        var normalizedPath = relativePath.Replace('\\', '/');
        return normalizedPath.StartsWith(TestDirectoryName + "/", StringComparison.OrdinalIgnoreCase)
            || normalizedPath.Contains(".Tests/", StringComparison.OrdinalIgnoreCase)
            || normalizedPath.Contains(".FunctionalTests/", StringComparison.OrdinalIgnoreCase)
            || normalizedPath.EndsWith("Test.cs", StringComparison.OrdinalIgnoreCase)
            || normalizedPath.EndsWith("FunctionalTest.cs", StringComparison.OrdinalIgnoreCase);
    }

    private static string BuildInstructions(string repoUrl, string repoId) =>
        $$"""
        # Digest Writing Instructions

        Repository: {{repoUrl}}
        Repository id: {{repoId}}

        The deterministic runner generated this workspace. The agent writes Markdown digests; this script does not call an LLM and does not overwrite result files.

        ## Contract

        - Treat `manifest.json` as authoritative for context and result paths.
        - Process package contexts one at a time.
        - Write every package result before writing the overview.
        - Each context has a full `*.context.md` file, a `*.context.index.md` navigation file, and ordered `*.context.chunks/*.md` raw-evidence chunks.
        - If the full context file is capped, truncated, summarized, or too large to read safely, read the index and then every listed chunk in numeric order.
        - Do not treat an index file as source evidence. It helps navigation only.
        - Do not treat generated public API summaries or engineering signals as standalone evidence. They help you decide what to inspect in the raw context.
        - For the overview, read `overview.context.md` or every overview chunk, then read every completed package result file listed by the manifest.
        - Treat completed package result files as the primary overview source; `overview.context.md` is supplementary.
        - Write package digests to `result/{PackageName}.md`.
        - Write the overview to `result/Index.md`.
        - Use the generated prompt sections in each `.context.md` file or its ordered chunks as the task contract.
        - Do not invent APIs, package relationships, examples, dependencies, support statements, performance claims, or architectural claims.
        - If context is missing, stale, contradictory, or too large to use safely, stop and report the blocker.

        ## Shared Editorial Rules

        {{BuildSharedEditorialRules()}}

        ## Suggested Order

        1. Read `manifest.json`.
        2. Read this file.
        3. For each package in the `packages` phase, read its context directly if possible; otherwise read its context index and then all chunks in order.
        4. Write each package result file only after its full raw context has been inspected.
        5. Read `overview.context.md` or every overview chunk, then read every completed package result file listed by the manifest.
        6. Write `result/Index.md`.
        7. Validate that all manifest result paths exist.
        """;

    private static string BuildSharedEditorialRules() => """
        You are a senior .NET library documentation editor.

        Your job is to turn repository context into accurate, developer-facing Markdown documentation.

        Priorities, in order:
        1. Accuracy.
        2. Grounding in the supplied source, tests, project files, README files, and metadata.
        3. Clear ecosystem positioning.
        4. Concise, useful website or documentation copy.
        5. Polished but restrained language.

        Your reader is a professional .NET engineer.
        They know .NET, NuGet, dependency injection, testing, hosting, ASP.NET Core, and common framework terminology.
        They do not know this specific repository or package.

        Use source files as the authoritative source for public APIs, inheritance, interfaces, generic constraints, method signatures, overloads, virtual/abstract members, lifecycle hooks, and consumer-facing behavior.
        Use test files as authoritative evidence for intended usage, behavioral contracts, common setup, and edge cases.
        Use project files as authoritative evidence for dependencies, target frameworks, package references, project references, and package relationships.
        Use README and metadata files only as editorial context for positioning, vocabulary, and high-level intent.
        Do not use README or metadata files as evidence for API shape when source code is available.
        If README, package README, catalog metadata, generated summaries, or engineering signals disagree with source code, follow the source code.
        If tests disagree with README examples, prefer tests for usage patterns.

        You must not invent APIs, features, package relationships, dependencies, examples, use cases, support statements, performance claims, or architectural claims not supported by the supplied context.

        Write with authority.
        Be concrete.
        Surface the non-obvious.
        Respect the reader's intelligence.
        Avoid marketing fluff.
        Avoid vague claims such as "robust", "seamless", "powerful", "easy-to-use", or "comprehensive" unless the supplied evidence makes the claim specific.

        Style rules:
        - Always include every required section heading verbatim on its own line, including the very first one. Never omit a heading.
        - Use Microsoft Learn-style headings: short, neutral, predictable, and task-oriented.
        - Do not use em dashes in prose.
        - Do not use "Furthermore".
        - Do not use "In conclusion".
        - Do not use filler phrases.
        - Keep the writing tight.
        - Cut anything that does not add information.
        - Final output must be Markdown only.
        - Do not include analysis notes, confidence scores, citations, XML, JSON, or chat commentary unless the package prompt explicitly requests them.
        """;

private static string BuildPackageDigestPrompt(string packageName) => $$"""
        Write the documentation page for {{packageName}}.

        Output file:
        `result/{{packageName}}.md`

        Audience:
        Experienced .NET developers who are evaluating whether this NuGet package belongs in their project.
        Assume they understand .NET, NuGet, dependency injection, testing, hosting, ASP.NET Core, and common framework terminology.
        Do not explain basic .NET concepts.

        Grounding rules:
        Use only the supplied package context.

        Evidence precedence:
        1. Source files are authoritative for public APIs, inheritance, interfaces, generic constraints, method signatures, overloads, virtual/abstract members, lifecycle hooks, callbacks, and consumer-facing behavior.
        2. Test files are authoritative for intended usage, behavioral contracts, common setup, and edge cases.
        3. Project files are authoritative for dependencies, target frameworks, package references, project references, and package relationships.
        4. XML documentation is useful evidence for intent, but source declarations and tests still win when there is a conflict.
        5. README, package README, catalog metadata, and generated prose are editorial context only. They may guide positioning and vocabulary, but they are not authoritative for API shape.

        Do not use README or metadata files as evidence for method names, inheritance, interfaces, overloads, required overrides, constructor signatures, target frameworks, package relationships, or examples when source or project files are available.
        If README, package README, catalog metadata, generated summaries, or engineering signals disagree with source code, follow the source code.
        If README examples disagree with tests, prefer tests.
        If source code is unclear and README is the only evidence for a claim, either write conservatively or omit the claim.

        Do not invent features, scenarios, dependencies, method names, constructor overloads, namespaces, return types, or package relationships.
        Ignore internal implementation details unless they explain the public API or a consumer-facing contract.
        Prefer public types, extension methods, options/configuration types, factories, abstractions, and test-visible usage patterns.
        If the package has obsolete or deprecated APIs, do not present them as the recommended path.

        If the package is metadata-only, aggregate-only, convenience-only, or produces no assembly of its own:
        - Say that clearly.
        - Do not invent public APIs owned by this package.
        - Treat project references and package references as authoritative evidence for what the package aggregates.
        - Make API ownership clear: the convenience package provides the single package reference, while APIs come from the referenced packages.

        The generated public API summary and engineering signals are reading aids, not final evidence. Validate them against the packed source and tests before turning them into claims.

        Engineering depth requirements:
        Look for design invariants, lifecycle contracts, callback wiring, factory boundaries, generic type constraints, exception guards, and test-backed edge cases.
        Explain a non-obvious design choice only when the source or tests make it visible.
        For each important API, prefer the useful engineering detail over a generic description: inheritance chain, why a generic parameter exists, what lifecycle it participates in, what callback must be supplied, or what contract a consumer must respect.
        Name what the package deliberately does not solve when package boundaries, dependencies, or sibling packages make that clear.
        If generated context appears to pair the package with surprising or weak test evidence, reflect that conservatively instead of smoothing it over.

        Metadata guidance:
        Do not include target frameworks, dependency lists, package metadata, or repository facts in the Overview.
        Do not describe implementation mechanics before describing the consumer-facing responsibility.
        Do not use "targets netX" as a substitute for explaining what the package does.

        Before writing the final page, internally identify:
        - the package's specific responsibility inside the repository
        - the primary developer scenario
        - the 3-6 public APIs that matter most to consumers
        - the most representative usage pattern found in source and tests
        - the design invariants, lifecycle contracts, or guardrails that matter to consumers
        - what this package deliberately does not solve
        - any confidence risks caused by missing tests or unclear source

        Write exactly these sections.

        ## Overview

        1-2 concise paragraphs.
        Explain the specific responsibility this package owns.
        If it extends another package in the same repository, name that package explicitly.
        Start with the consumer-facing purpose, not implementation details.
        Be concrete.
        Avoid generic phrases such as "provides utilities" unless the package is genuinely a utility package.
        Do not oversell the package.
        Do not mention target frameworks, dependency lists, package references, or repository metadata in this section.

        ## Key APIs

        List the 3-6 most important public consumer-facing types, extension methods, options types, factories, abstractions, or helpers.

        Format each item exactly:

        `ApiName` - Description.

        Rules:
        - Mention only APIs visible in the supplied source.
        - Prefer APIs that a consumer would directly inherit from, instantiate, configure, call, or implement.
        - Include static factory methods or extension methods when they are more important to consumers than their containing type.
        - Descriptions should explain practical role, not merely repeat generic XML documentation wording.
        - Include generic constraints or required callbacks when they are important to correct usage.
        - Do not include incidental internal helpers, test-only types, or implementation details.
        - If fewer than 3 important public APIs exist, list fewer.
        - If the package is metadata-only, aggregate-only, convenience-only, or produces no assembly of its own, write one sentence explaining that it exposes no additional public APIs and that APIs come from referenced packages.

        ## Basic usage

        Write Basic usage examples from a consumer's point of view.

        First determine whether this is a normal code package or a metadata-only / aggregate / convenience / no-assembly package.

        If this is a metadata-only, aggregate-only, convenience-only, or no-assembly package that references other code packages:
        - Still write C# examples for consistency.
        - Do not use a bash installation block in this section.
        - Write one separate C# example for each referenced package when the referenced package provides consumer-facing APIs.
        - Write exactly one C# example for each referenced code package that provides consumer-facing APIs.
        - The number of C# examples must equal the number of referenced code packages with consumer-facing APIs.
        - Do not cap, merge, sample, summarize, or omit referenced code packages from Basic usage.
        - If the package references 42 code packages that provide consumer-facing APIs, write exactly 42 C# examples.
        - Each example must be introduced by a third-level heading using this exact format: `### Referenced.Package.Name`.
        - Each referenced-package example must contain exactly one `[Fact]` or `[Theory]` method.
        - Each referenced-package example must focus on a distinct use case from that referenced package.
        - Do not reuse the Basic usage examples already authored for the referenced package pages.
        - Do not paste unrelated snippets from the referenced package pages.
        - Do not imply that the convenience package owns the APIs. The APIs are supplied by the referenced packages.
        - Include explicit using statements for every referenced package namespace used by each example.
        - Use a consumer namespace such as `MyProject.Tests`.
        - Include at least one assertion or observable result in each example.
        - Prefer small, realistic examples that demonstrate why installing the bundle is convenient across multiple testing styles.
        - For base xUnit packages, prefer examples that use the shared base class plus directly exposed helper APIs such as output, matching, stores, or lifecycle behavior.
        - For generic-host packages, prefer examples that show host, DI, configuration, or logging behavior without fake services unless the fake type is defined inside the snippet.
        - For ASP.NET Core packages, prefer inline middleware such as `app.Run(...)` or inline `app.Use(...)` over `UseMiddleware<T>` unless `T` exists in the supplied context or is defined inside the snippet.
        - After all examples, write exactly one short paragraph explaining that the convenience package provides a single package reference while the APIs come from the referenced packages.

        If this is a normal code package:
        Write one complete C# example that demonstrates the package's central usage pattern from a consumer's point of view.

        The final normal-package C# example is invalid unless it satisfies all valid-example requirements.

        Valid-example requirements for normal code packages:
        - Include all necessary `using` statements.
        - Prefer explicit using statements over relying on implicit or global usings.
        - If the example uses a base type or API from a lower-level package, include the namespace for that package explicitly.
        - Include a consumer namespace such as `MyProject.Tests` unless the original namespace is required for compilation.
        - Include exactly one `[Fact]` or `[Theory]` method unless the package cannot be demonstrated correctly with one test.
        - Include at least one assertion or observable result.
        - Demonstrate the package itself, not a fake application domain.
        - Use only APIs, constructors, methods, overloads, options, return types, and extension methods visible in the supplied context.
        - Use a complete documentation snippet that a developer can understand without hidden files, hidden helpers, hidden services, or unexplained setup.
        - Keep the example focused on one central pattern.
        - Do not use top-level statements unless the package is a console/application package.
        - For base test packages, prefer demonstrating the base class plus directly exposed helper APIs such as output, matching, stores, or lifecycle behavior.
        - For hosting packages, prefer the smallest realistic host setup that demonstrates the package API.
        - For ASP.NET Core packages, prefer inline middleware such as `app.Run(...)` or inline `app.Use(...)` over `UseMiddleware<T>` unless `T` exists in the supplied context.

        Before writing a normal-package final example, internally draft and evaluate 4 candidate examples:
        1. A minimal happy-path example.
        2. An example that combines two central APIs.
        3. An example based on the most representative test usage.
        4. An example that demonstrates the package's most distinctive feature.

        Internally reject any candidate that violates one or more invalid-example rules.

        Invalid-example rules:
        - Reject examples that lack `using` statements when the snippet needs them.
        - Reject examples that lack a namespace unless omitting the namespace is clearly normal for the snippet.
        - Reject examples that lack a `[Fact]` or `[Theory]` method unless the package type makes tests irrelevant.
        - Reject examples that lack an assertion or observable result.
        - Reject examples that override a lifecycle or cleanup hook only to call the base implementation.
        - Reject examples that include placeholder comments such as `// dispose managed resources here`.
        - Reject examples that include a disposable field unless the field is actually used by the test and disposed by the hook.
        - Reject examples that open external files, network resources, databases, environment variables, or machine-specific resources.
        - Reject examples that call fake helper methods such as `GenerateReport()`, `CreateService()`, `BuildHost()`, `FormatInvoice()`, `CreateClient()`, or similar unless that exact method exists in the supplied content.
        - Reject examples that introduce fake production services, fake middleware, fake controllers, fake repositories, fake options, fake validators, or fake domain types unless their implementation is included in the example.
        - Reject examples that register fake services such as `IMyService` / `MyService` unless those types are defined in the snippet or exist in the supplied context.
        - Reject examples that use `UseMiddleware<T>` unless `T` is defined in the snippet or exists in the supplied context.
        - Reject examples where setup plumbing is more prominent than the package API.
        - Reject examples that require hidden registrations, hidden helper classes, hidden extension methods, hidden middleware, or unexplained magic.
        - Reject examples that use maintainer-internal namespaces unless the original namespace is required for compilation.
        - Reject examples that demonstrate only a failure path unless the package's central feature is error handling.
        - Reject examples that use multiple `[Fact]` or `[Theory]` methods to compensate for a weak central example.
        - Reject examples that mention a package feature in the explanation but do not demonstrate it in the code.
        - Reject examples that use file-local types such as `file class`, `file record`, or `file struct`.

        Selection criteria for normal code packages:
        - Prefer the candidate that is most likely to compile.
        - Prefer the candidate that demonstrates the package itself more than a fake domain.
        - Prefer the candidate that uses the fewest invented names.
        - Prefer the candidate that shows the smallest realistic consumer setup.
        - Prefer a happy-path example unless an error path is the most important pattern.
        - Prefer a consumer namespace such as `MyProject.Tests` unless the original namespace is required for compilation.
        - Prefer examples that demonstrate at least two central package features when this can be done naturally.
        - For hosting packages, prefer inline framework-native setup over fake services or fake middleware.
        - For factory APIs, prefer the smallest factory-based example when it demonstrates the package better than a fixture class.
        - For base-class APIs, prefer inheriting from the base class and using one or two of its directly exposed members.

        Output only the best candidate for normal code packages.

        Rules for all C# examples:
        - The example may be newly written for documentation.
        - It must be grounded in the supplied source files and tests.
        - Use tests to understand intended behavior, common setup, required constructor arguments, and expected usage flow.
        - Use real namespaces, real type names, real method calls, and real constructor signatures from the supplied content.
        - Do not invent APIs, overloads, extension methods, options, return types, helper methods, setup methods, fake service methods, fake domain methods, or fake factory methods.
        - Prefer inline values over fake helper methods.
        - Keep each code block between 10 and 25 lines when feasible.
        - Use ```csharp fenced code blocks.
        - Do not include ellipses, pseudocode, placeholders, TODO comments, or unexplained magic.
        - Do not add a cleanup hook unless the hook cleans up a real resource used by the example.
        - Do not add a service registration unless the registered service type and implementation are defined in the example or exist in the supplied context.
        - Do not add middleware unless the middleware type exists in the supplied context or the example uses inline middleware such as `app.Run(...)` or `app.Use(...)`.

        For normal code packages, after the code block, write exactly 2 sentences:
        1. When to use this pattern.
        2. Why it matters.

        For convenience, aggregate, metadata-only, or no-assembly packages, do not write the normal two-sentence explanation after each code block. Instead, write one short explanatory paragraph after all referenced-package examples.

        ## Installation

        ```bash
        dotnet add package {{packageName}}
        ```

        ## Usage guidance

        One honest paragraph.
        Explain when plain framework APIs, a lower-level package, a sibling package, or no package at all would be a better choice.
        Mention the nearest sibling package only when the context supports that relationship.
        Do not insult the package.
        Do not oversell it.
        """;

    private static string BuildOverviewDigestPrompt(string repoId, IReadOnlyList<PackageInfo> packages)
    {
        var packageList = packages.Count == 0
            ? "- No packages discovered."
            : string.Join(Environment.NewLine, packages.Select(p => "- " + p.Name));

        return $$"""
        Write the overview page for this repository.

        Output file:
        `result/Index.md`

        Primary editorial context:
        Read every completed package digest below before writing this page:
        {{packageList}}

        If packages exist, do not write `result/Index.md` from `overview.context.md` alone.
        The overview is invalid unless the completed package digest files have been opened and used as source material.

        Audience:
        Experienced .NET developers who need a mental model before choosing an individual package from this repository.
        Assume they understand .NET, NuGet, dependency injection, testing, hosting, ASP.NET Core, and common framework terminology.
        Do not explain basic .NET concepts.

        Grounding rules:
        The completed package digests are the primary editorial context.
        Use the overview context only as supplementary repository evidence.
        Supplementary README, package README, project, dependency, and metadata information may be used to clarify relationships.
        Do not invent package purposes, dependencies, recommended installation paths, scenarios, APIs, or architectural claims.
        Do not amplify unsupported claims from a package digest.
        Prefer concrete responsibilities and decision guidance over marketing language.
        Keep the overview focused on how developers should understand and choose between the packages.
        If package digests disagree with each other, prefer the more specific package page and write conservatively.

        Before writing the final page, internally identify:
        - the unifying purpose of the repository
        - the foundation or primary package, if one exists
        - optional add-on packages, if any exist
        - convenience, aggregate, or meta packages, if any exist
        - the recommended starting point
        - scenarios where installing or using less is better
        - recurring engineering patterns across packages, such as classic versus minimal hosting styles, shared fixture lifecycles, factory shortcuts, or layered package boundaries, when visible in the evidence
        - the one non-obvious insight developers should understand

        Write exactly these three sections.

        ## Overview

        Start with 2-3 sentences that explain the unifying purpose across the packages.
        Make clear what kind of developer problem this repository solves.
        Do not use broad marketing language.
        Do not lead with repository metadata, target frameworks, or package counts.

        After the opening sentences, include a compact package selection table.

        Columns:

        | Scenario | Package |
        |---|---|

        Rules:
        - Each row must map a concrete developer scenario to one or more package names.
        - Keep the scenarios practical and non-overlapping.
        - Prefer fewer, sharper rows over exhaustive rows.
        - Do not create separate rows for scenarios that are effectively the same decision.
        - Include convenience or aggregate packages only if they exist and their role is clear.
        - Avoid internal phrasing unless the repository content clearly explains it in user-facing terms.
        - Do not include a row just to mention every API. Rows are for package choice, not API inventory.

        After the table, add one short paragraph with the primary selection rule.
        The paragraph should help the reader choose the smallest appropriate package or the right layer.

        ## Package selection

        Start with one short introductory paragraph before the package subheadings.
        The paragraph must be specific to this repository.
        It should explain the selection principle, conceptual layering, or main trade-off across the packages.
        Do not repeat the Overview table row by row.
        Do not use generic phrases such as "the following packages are available".
        Do not leave this section heading immediately followed by a package subheading.

        Then use one third-level heading per package.

        Format:

        ### Package.Name

        1 short paragraph.
        Explain what this package is for, what it adds, and when a developer should choose it.
        If it extends another package in the same repository, say so.
        If it is a convenience, aggregate, or meta package, say that clearly and identify what it aggregates when the context supports it.
        Do not create bullets unless the package has genuinely enumerable capabilities.
        Use package names exactly as supplied.
        Keep each package paragraph roughly similar in length unless one package is clearly metadata-only or much smaller.

        ## Usage guidance

        One or two paragraphs.
        Explain the non-obvious guidance that helps developers choose and use the repository correctly.
        Focus on boundaries, trade-offs, and common mistakes.
        It must be grounded in the actual package responsibilities and APIs.
        Do not use generic advice.
        Do not repeat the package table.
        Prefer a practical decision rule over a slogan.
        """;
    }

    private static void AppendMultiline(StringBuilder sb, string value)
    {
        sb.AppendLine(value.Trim());
        sb.AppendLine();
    }

    private static async Task<ContextArtifacts> WriteContextArtifactsAsync(string workspace, string contextFileName, string context)
    {
        await WriteUtf8Async(Path.Combine(workspace, contextFileName), context);

        var chunkDirectoryName = Path.GetFileNameWithoutExtension(contextFileName) + ".chunks";
        var chunkDirectory = Path.Combine(workspace, chunkDirectoryName);
        if (Directory.Exists(chunkDirectory))
        {
            Directory.Delete(chunkDirectory, recursive: true);
        }

        Directory.CreateDirectory(chunkDirectory);

        var chunks = SplitContextIntoChunks(context).ToList();
        var chunkPaths = new List<string>(chunks.Count);
        for (var i = 0; i < chunks.Count; i++)
        {
            var chunkNumber = i + 1;
            var chunkFileName = chunkNumber.ToString("D4") + ".md";
            var chunkPath = (chunkDirectoryName + "/" + chunkFileName).Replace('\\', '/');
            chunkPaths.Add(chunkPath);

            var chunkContent = BuildChunkFile(contextFileName, chunkNumber, chunks.Count, chunks[i]);
            await WriteUtf8Async(Path.Combine(workspace, chunkPath), chunkContent);
        }

        var indexPath = Path.GetFileNameWithoutExtension(contextFileName) + ".index.md";
        var index = BuildContextIndex(contextFileName, indexPath, chunkPaths, chunks, context);
        await WriteUtf8Async(Path.Combine(workspace, indexPath), index);

        return new ContextArtifacts(contextFileName, indexPath, chunkPaths);
    }

    private static IEnumerable<string> SplitContextIntoChunks(string context)
    {
        var normalized = context.Replace("\r\n", "\n", StringComparison.Ordinal).Replace('\r', '\n');
        var lines = normalized.Split('\n');
        var sb = new StringBuilder();
        var currentBytes = 0;

        foreach (var line in lines)
        {
            var lineWithNewline = line + Environment.NewLine;
            var lineBytes = Encoding.UTF8.GetByteCount(lineWithNewline);
            if (lineBytes > MaxContextChunkBodyBytes)
            {
                if (sb.Length > 0)
                {
                    yield return sb.ToString();
                    sb.Clear();
                    currentBytes = 0;
                }

                foreach (var part in SplitOversizedLine(lineWithNewline))
                {
                    yield return part;
                }

                continue;
            }

            if (sb.Length > 0 && currentBytes + lineBytes > MaxContextChunkBodyBytes)
            {
                yield return sb.ToString();
                sb.Clear();
                currentBytes = 0;
            }

            sb.Append(lineWithNewline);
            currentBytes += lineBytes;
        }

        if (sb.Length > 0)
        {
            yield return sb.ToString();
        }
    }

    private static IEnumerable<string> SplitOversizedLine(string line)
    {
        var sb = new StringBuilder();
        var currentBytes = 0;
        foreach (var rune in line.EnumerateRunes())
        {
            var next = rune.ToString();
            var nextBytes = Encoding.UTF8.GetByteCount(next);
            if (sb.Length > 0 && currentBytes + nextBytes > MaxContextChunkBodyBytes)
            {
                yield return sb.ToString();
                sb.Clear();
                currentBytes = 0;
            }

            sb.Append(next);
            currentBytes += nextBytes;
        }

        if (sb.Length > 0)
        {
            yield return sb.ToString();
        }
    }

    private static string BuildChunkFile(string contextFileName, int chunkNumber, int chunkCount, string chunkBody)
    {
        var sb = new StringBuilder();
        sb.AppendLine("# Context Chunk " + chunkNumber.ToString("D4"));
        sb.AppendLine();
        sb.AppendLine("Source context: `" + contextFileName + "`");
        sb.AppendLine("Chunk: " + chunkNumber + " of " + chunkCount);
        sb.AppendLine();
        sb.AppendLine("Read this chunk as raw evidence. The index file is only a navigation aid.");
        sb.AppendLine();
        sb.AppendLine("---");
        sb.AppendLine();
        sb.Append(chunkBody);
        return sb.ToString();
    }

    private static string BuildContextIndex(
        string contextFileName,
        string indexPath,
        IReadOnlyList<string> chunkPaths,
        IReadOnlyList<string> chunks,
        string context)
    {
        var sb = new StringBuilder();
        sb.AppendLine("# Context Index");
        sb.AppendLine();
        sb.AppendLine("Source context: `" + contextFileName + "`");
        sb.AppendLine("Index path: `" + indexPath + "`");
        sb.AppendLine("Chunk count: " + chunkPaths.Count);
        sb.AppendLine("Full context bytes: " + Encoding.UTF8.GetByteCount(context));
        sb.AppendLine();
        sb.AppendLine("This file is a deterministic navigation aid. Do not use it as a substitute for reading the raw context or every chunk listed below.");
        sb.AppendLine();

        sb.AppendLine("## Read Order");
        sb.AppendLine();
        sb.AppendLine("1. Read this index to understand the context layout.");
        sb.AppendLine("2. Read each chunk in numeric order before writing from this context.");
        sb.AppendLine("3. Use the full source context only when your tools can read it completely without truncation.");
        sb.AppendLine();

        sb.AppendLine("## Chunks");
        sb.AppendLine();
        sb.AppendLine("| Chunk | Path | Body bytes | Contents |");
        sb.AppendLine("|---|---|---:|---|");
        for (var i = 0; i < chunks.Count; i++)
        {
            var contents = BuildChunkContents(chunks[i]);
            sb.AppendLine($"| {i + 1} | `{chunkPaths[i]}` | {Encoding.UTF8.GetByteCount(chunks[i])} | {EscapeMarkdownTableCell(contents)} |");
        }
        sb.AppendLine();

        var contextHeadings = ExtractHeadings(context).ToList();
        if (contextHeadings.Count > 0)
        {
            sb.AppendLine("## Context Sections");
            sb.AppendLine();
            foreach (var heading in contextHeadings)
            {
                sb.AppendLine("- " + heading);
            }
            sb.AppendLine();
        }

        var packedPaths = ExtractPackedFilePaths(context).Take(200).ToList();
        if (packedPaths.Count > 0)
        {
            sb.AppendLine("## Packed File Inventory");
            sb.AppendLine();
            foreach (var path in packedPaths)
            {
                sb.AppendLine("- `" + path + "`");
            }
            sb.AppendLine();
        }

        return sb.ToString();
    }

    private static IEnumerable<string> ExtractHeadings(string markdown)
    {
        foreach (Match match in Regex.Matches(markdown, @"^##\s+(.+)$", RegexOptions.Multiline))
        {
            yield return match.Groups[1].Value.Trim();
        }
    }

    private static string BuildChunkContents(string chunk)
    {
        var entries = ExtractHeadings(chunk)
            .Concat(ExtractInferredChunkLabels(chunk))
            .Distinct(StringComparer.OrdinalIgnoreCase)
            .ToList();

        if (entries.Count == 0)
        {
            entries.Add("Packed Content");
        }

        return string.Join("; ", entries);
    }

    private static IEnumerable<string> ExtractInferredChunkLabels(string chunk)
    {
        var packedPaths = ExtractPackedFilePaths(chunk).ToList();
        if (packedPaths.Count == 0)
        {
            yield break;
        }

        foreach (var group in packedPaths
            .GroupBy(ClassifyPackedFilePath, StringComparer.OrdinalIgnoreCase)
            .Select(group => new { Heading = group.Key, Count = group.Count() })
            .OrderByDescending(group => group.Count)
            .ThenBy(group => group.Heading, StringComparer.OrdinalIgnoreCase))
        {
            yield return group.Heading;
        }
    }

    private static string ClassifyPackedFilePath(string path)
    {
        var normalized = path.Replace('\\', '/').TrimStart('/');
        var fileName = Path.GetFileName(normalized);

        if (normalized.StartsWith("test/", StringComparison.OrdinalIgnoreCase))
        {
            return "Test Coverage";
        }

        if (normalized.StartsWith("src/", StringComparison.OrdinalIgnoreCase))
        {
            return "Source Code";
        }

        if (normalized.StartsWith(".nuget/", StringComparison.OrdinalIgnoreCase))
        {
            return "NuGet Documentation";
        }

        if (string.Equals(fileName, "README.md", StringComparison.OrdinalIgnoreCase))
        {
            return "Documentation";
        }

        if (string.Equals(fileName, "Directory.Build.props", StringComparison.OrdinalIgnoreCase)
            || string.Equals(fileName, "Directory.Build.targets", StringComparison.OrdinalIgnoreCase)
            || string.Equals(fileName, "Directory.Packages.props", StringComparison.OrdinalIgnoreCase)
            || fileName.EndsWith(".csproj", StringComparison.OrdinalIgnoreCase))
        {
            return "Project Metadata";
        }

        return "Repository Metadata";
    }

    private static IEnumerable<string> ExtractPackedFilePaths(string context)
    {
        var paths = new SortedSet<string>(StringComparer.OrdinalIgnoreCase);
        foreach (Match match in Regex.Matches(context, @"<file\s+path=""([^""]+)"""))
        {
            paths.Add(match.Groups[1].Value);
        }

        return paths;
    }

    private static string EscapeMarkdownTableCell(string value) =>
        value.Replace("|", "\\|", StringComparison.Ordinal);

    private static Regex PublicTypeRegex() => PublicTypeExpression;

    private static Regex PublicMemberRegex() => PublicMemberExpression;

    private static async Task<string> PackRepositoryContentAsync(string cloneDir, string includes)
    {
        return FilterLowSignalPackedContent(await PackWithLocalPackerAsync(cloneDir, includes));
    }

    private static async Task<string> PackWithLocalPackerAsync(string cloneDir, string includes)
    {
        var includePatterns = includes
            .Split(',', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries)
            .ToList();

        var files = (await GetTrackedFilesAsync(cloneDir))
            .Where(file => ShouldIncludeFile(file.RelativePath, includePatterns))
            .Where(file => !IsUnderSkippedDirectory(file.RelativePath))
            .Where(file => !ShouldSkipLowSignalFile(file.RelativePath))
            .Where(file => IsTextFile(file.FullPath))
            .OrderBy(file => file.RelativePath, StringComparer.OrdinalIgnoreCase)
            .ToList();

        var filesElement = new XElement("files");
        foreach (var file in files)
        {
            var content = await File.ReadAllTextAsync(file.FullPath, Encoding.UTF8);
            filesElement.Add(new XElement("file", new XAttribute("path", file.RelativePath), content));
        }

        var doc = new XDocument(
            new XElement(
                "repository-context",
                new XAttribute("generatedBy", "git-repo-digest-local-packer"),
                new XElement("note", "Packed by the bundled git-repo-digest C# runner from tracked files in the cloned repository. The packer uses git ls-files for deterministic repository membership, applies the runner include patterns, skips known generated or low-signal paths, and includes text files only."),
                new XElement("includePatterns", includePatterns.Select(pattern => new XElement("pattern", pattern))),
                new XElement("directoryStructure", BuildDirectoryStructure(files.Select(file => file.RelativePath))),
                filesElement));

        return doc.ToString(SaveOptions.DisableFormatting);
    }

    private static async Task<IReadOnlyList<PackedFile>> GetTrackedFilesAsync(string cloneDir)
    {
        var output = await RunProcessCaptureAsync("git", ["ls-files", "-z"], cloneDir);
        return output
            .Split('\0', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries)
            .Select(path => path.Replace('\\', '/'))
            .Select(relativePath => new PackedFile(ResolveRepositoryPath(cloneDir, relativePath), relativePath))
            .OrderBy(file => file.RelativePath, StringComparer.OrdinalIgnoreCase)
            .ToList();
    }

    private static string ResolveRepositoryPath(string cloneDir, string relativePath)
    {
        var fullPath = Path.GetFullPath(Path.Combine(cloneDir, relativePath.Replace('/', Path.DirectorySeparatorChar)));
        var root = Path.GetFullPath(cloneDir).TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar)
            + Path.DirectorySeparatorChar;
        if (!fullPath.StartsWith(root, StringComparison.OrdinalIgnoreCase))
        {
            throw new InvalidOperationException($"Git returned a path outside the cloned repository: '{relativePath}'.");
        }

        return fullPath;
    }

    private static bool ShouldIncludeFile(string relativePath, IReadOnlyList<string> includePatterns) =>
        includePatterns.Any(pattern => MatchesIncludePattern(relativePath, pattern));

    private static string FilterLowSignalPackedContent(string content)
    {
        try
        {
            var doc = XDocument.Parse(content, LoadOptions.PreserveWhitespace);
            var removedAny = false;
            foreach (var file in doc.Descendants().Where(e => e.Name.LocalName == "file").ToList())
            {
                var path = file.Attribute("path")?.Value;
                if (path is not null && ShouldSkipLowSignalFile(path))
                {
                    file.Remove();
                    removedAny = true;
                }
            }

            foreach (var directoryStructure in doc.Descendants().Where(e => e.Name.LocalName == "directoryStructure").ToList())
            {
                var filtered = string.Join(
                    Environment.NewLine,
                    directoryStructure.Value.Split('\n', StringSplitOptions.None)
                        .Select(line => line.TrimEnd('\r'))
                        .Where(line => !ShouldSkipLowSignalFile(line.Trim())));

                if (!string.Equals(filtered, directoryStructure.Value, StringComparison.Ordinal))
                {
                    directoryStructure.Value = filtered;
                    removedAny = true;
                }
            }

            if (removedAny)
            {
                return doc.ToString(SaveOptions.DisableFormatting);
            }
        }
        catch
        {
            // The packer emits XML; keep a text fallback in case a future shape changes.
        }

        var withoutFileBlocks = Regex.Replace(
            content,
            @"(?s)<file\s+path=""[^""]*GlobalSuppressions\.cs""[^>]*>.*?</file>\s*",
            string.Empty,
            RegexOptions.IgnoreCase);

        return Regex.Replace(
            withoutFileBlocks,
            @"(?im)^[^\r\n]*GlobalSuppressions\.cs[^\r\n]*(?:\r?\n)?",
            string.Empty);
    }

    private static bool ShouldSkipLowSignalFile(string relativePath) =>
        string.Equals(Path.GetFileName(relativePath), "GlobalSuppressions.cs", StringComparison.OrdinalIgnoreCase);

    private static bool MatchesIncludePattern(string relativePath, string pattern)
    {
        var normalizedPattern = pattern.Replace('\\', '/').TrimStart('/');

        if (normalizedPattern.EndsWith("/**", StringComparison.Ordinal))
        {
            var prefix = normalizedPattern[..^3].TrimEnd('/');
            return string.Equals(relativePath, prefix, StringComparison.OrdinalIgnoreCase)
                || relativePath.StartsWith(prefix + "/", StringComparison.OrdinalIgnoreCase);
        }

        if (normalizedPattern.Contains("/**/", StringComparison.Ordinal))
        {
            var parts = normalizedPattern.Split("/**/", 2, StringSplitOptions.None);
            var prefix = parts[0].TrimEnd('/') + "/";
            var suffix = "/" + parts[1].TrimStart('/');
            var direct = parts[0].TrimEnd('/') + "/" + parts[1].TrimStart('/');
            return (relativePath.StartsWith(prefix, StringComparison.OrdinalIgnoreCase)
                    && relativePath.EndsWith(suffix, StringComparison.OrdinalIgnoreCase))
                || string.Equals(relativePath, direct, StringComparison.OrdinalIgnoreCase);
        }

        if (normalizedPattern.Contains('*'))
        {
            var regex = "^" + Regex.Escape(normalizedPattern)
                .Replace("\\*\\*", ".*", StringComparison.Ordinal)
                .Replace("\\*", "[^/]*", StringComparison.Ordinal) + "$";
            return Regex.IsMatch(relativePath, regex, RegexOptions.IgnoreCase);
        }

        return string.Equals(relativePath, normalizedPattern, StringComparison.OrdinalIgnoreCase);
    }

    private static bool IsUnderSkippedDirectory(string relativePath)
    {
        var segments = relativePath.Split('/', StringSplitOptions.RemoveEmptyEntries);
        return segments.Any(segment => segment is ".git" or ".svn" or ".hg" or "bin" or "obj" or "node_modules");
    }

    private static bool IsTextFile(string path)
    {
        using var stream = File.OpenRead(path);
        var buffer = new byte[Math.Min(4096, (int)Math.Min(stream.Length, int.MaxValue))];
        var read = stream.Read(buffer, 0, buffer.Length);
        return !buffer.Take(read).Contains((byte)0);
    }

    private static string BuildDirectoryStructure(IEnumerable<string> relativePaths)
    {
        var entries = new SortedSet<string>(StringComparer.OrdinalIgnoreCase);
        foreach (var path in relativePaths)
        {
            var parts = path.Split('/', StringSplitOptions.RemoveEmptyEntries);
            for (var i = 0; i < parts.Length; i++)
            {
                var prefix = string.Join('/', parts.Take(i + 1));
                entries.Add(prefix + (i == parts.Length - 1 ? string.Empty : "/"));
            }
        }

        return string.Join(Environment.NewLine, entries);
    }

    private static async Task WriteManifestAsync(
        string manifestPath,
        DigestOptions options,
        string repoId,
        string workspace,
        IReadOnlyList<PackageManifestEntry> packages,
        ContextArtifacts overviewArtifacts)
    {
        var packagesPhase = new
        {
            name = "packages",
            packages = packages.Select(p => new { p.kind, p.name, p.context, p.contextIndex, p.contextChunks, p.result }).ToList(),
            targets = packages.Select(p => new { p.kind, p.name, p.context, p.contextIndex, p.contextChunks, p.result }).ToList()
        };

        var overviewPhase = new
        {
            name = "overview",
            dependsOn = "packages",
            package = new
            {
                kind = "overview",
                name = "Index",
                context = overviewArtifacts.ContextPath,
                contextIndex = overviewArtifacts.IndexPath,
                contextChunks = overviewArtifacts.ChunkPaths,
                sourceResults = packages.Select(p => p.result).ToList(),
                result = "result/Index.md"
            }
        };

        var manifest = new
        {
            schemaVersion = 1,
            generatedAt = DateTimeOffset.UtcNow.ToString("O"),
            repository = new
            {
                url = options.RepoUrl,
                id = repoId
            },
            output = new
            {
                root = options.OutputRoot,
                workspace,
                resultDirectory = ResultDirectoryName
            },
            phases = new object[] { packagesPhase, overviewPhase },
            packages,
            targets = packages,
            overview = overviewPhase.package
        };

        var json = JsonSerializer.Serialize(manifest, new JsonSerializerOptions { WriteIndented = true });
        await WriteUtf8Async(manifestPath, json + Environment.NewLine);
    }

    private static async Task RunProcessAsync(string executable, IReadOnlyList<string> arguments, string workingDirectory, TimeSpan timeout = default)
    {
        await RunProcessCaptureAsync(executable, arguments, workingDirectory, timeout);
    }

    private static async Task<string> RunProcessCaptureAsync(string executable, IReadOnlyList<string> arguments, string workingDirectory, TimeSpan timeout = default)
    {
        if (timeout == default) timeout = TimeSpan.FromMinutes(5);

        var startInfo = new ProcessStartInfo(executable)
        {
            WorkingDirectory = workingDirectory,
            UseShellExecute = false,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            CreateNoWindow = true
        };

        foreach (var argument in arguments)
        {
            startInfo.ArgumentList.Add(argument);
        }

        using var process = Process.Start(startInfo)
            ?? throw new InvalidOperationException($"Could not start '{executable}'.");

        var stdoutTask = process.StandardOutput.ReadToEndAsync();
        var stderrTask = process.StandardError.ReadToEndAsync();

        using var cts = new CancellationTokenSource(timeout);
        try
        {
            await process.WaitForExitAsync(cts.Token);
        }
        catch (OperationCanceledException)
        {
            process.Kill(entireProcessTree: true);
            throw new TimeoutException($"'{executable}' did not complete within {timeout}.");
        }

        var stdout = await stdoutTask;
        var stderr = await stderrTask;

        if (process.ExitCode != 0)
        {
            var details = string.Join(Environment.NewLine, new[] { stdout.Trim(), stderr.Trim() }.Where(s => !string.IsNullOrWhiteSpace(s)));
            throw new InvalidOperationException($"'{executable}' failed with exit code {process.ExitCode}.{Environment.NewLine}{details}".Trim());
        }

        return stdout;
    }

    private static void AppendHeader(StringBuilder sb, string value)
    {
        sb.AppendLine("## " + value);
        sb.AppendLine();
    }

    private static async Task WriteUtf8Async(string path, string content)
    {
        Directory.CreateDirectory(Path.GetDirectoryName(path) ?? Directory.GetCurrentDirectory());
        await File.WriteAllTextAsync(path, content, new UTF8Encoding(false));
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
            // Temp cleanup failure should not hide the real result.
        }
    }

    private static void PrintUsage()
    {
        Console.WriteLine(
            """
            git-repo-digest deterministic context generator

            Usage:
              dotnet run --file scripts/digest.cs -- --repo-url <url> --output-root <path>

            Required:
              --repo-url      Fully qualified git repository URL, for example https://github.com/owner/repo
              --output-root   Directory where the {repo-id} digest workspace will be written

            Fixed conventions:
              repo-id      Derived from the final repository URL path segment
              result dir   result

            Output:
              {output-root}/{repo-id}/manifest.json
              {output-root}/{repo-id}/instructions.md
              {output-root}/{repo-id}/*.context.md
              {output-root}/{repo-id}/*.context.index.md
              {output-root}/{repo-id}/*.context.chunks/*.md
              {output-root}/{repo-id}/result/

            Notes:
              - This script writes deterministic context only.
              - This script does not call an LLM.
              - Existing result/*.md files are not overwritten.
              - Context packing uses the bundled C# packer over the cloned repository's tracked files.
            """);
    }
}

internal sealed record DigestOptions(string RepoUrl, string OutputRoot);

internal sealed record ProjectMetadata(
    string PackageId,
    string AssemblyName,
    bool? IsPackable,
    IReadOnlyList<string> BundledPackages);

internal sealed record PackageInfo(
    string Name,
    string SourcePath,
    string? TestPath,
    bool IsConveniencePackage,
    IReadOnlyList<string> BundledPackages);

internal sealed record TestProjectMatch(
    string ProjectFile,
    bool IsOwnTestProjectName,
    bool ReferencesProject);

internal sealed record ContextArtifacts(
    string ContextPath,
    string IndexPath,
    IReadOnlyList<string> ChunkPaths);

internal sealed record ApiTypeSummary(
    string Name,
    string Kind,
    string BaseTypes,
    IReadOnlyList<string> Members,
    string SourcePath);

internal sealed record SignalFile(
    string RelativePath,
    string Content);

internal sealed record EngineeringSignal(
    string Kind,
    string Value,
    string SourcePath);

internal sealed record PackageManifestEntry(
    string kind,
    string name,
    string context,
    string contextIndex,
    IReadOnlyList<string> contextChunks,
    string result);

internal sealed record PackedFile(string FullPath, string RelativePath);
