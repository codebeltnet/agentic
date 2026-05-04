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
    private const int MaxContextChunkBodyBytes = 36 * 1024;
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
        var srcDir = Path.Combine(cloneDir, "src");
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
        var testRoots = new[] { "test", "tests" }
            .Select(r => Path.Combine(cloneDir, r))
            .Where(Directory.Exists)
            .ToList();

        var normalizedPackage = NormalizeForMatch(packageName);
        var candidates = new List<TestProjectMatch>();
        foreach (var root in testRoots)
        {
            var testProjects = Directory.EnumerateFiles(root, "*.csproj", SearchOption.AllDirectories)
                .OrderBy(p => p, StringComparer.OrdinalIgnoreCase)
                .ToList();

            foreach (var testProject in testProjects)
            {
                candidates.Add(new TestProjectMatch(
                    testProject,
                    IsOwnTestProjectName(testProject, normalizedPackage),
                    ReferencesProject(testProject, sourceProjectFile)));
            }
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
        var suffixes = new[] { "tests", "test", "unittests", "unittest", "integrationtests", "integrationtest", "functionaltests", "functionaltest" };
        return suffixes.Any(suffix => string.Equals(normalizedProjectName, normalizedPackage + suffix, StringComparison.OrdinalIgnoreCase));
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
        var packedContent = await PackRepositoryContentAsync(cloneDir, "README.md,.nuget/**/README.md,Directory.Build.props,Directory.Build.targets,Directory.Packages.props,src/**/*.csproj");

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

    private static bool IsProbablyTestFile(string relativePath) =>
        relativePath.Contains(".Tests/", StringComparison.OrdinalIgnoreCase)
        || relativePath.Contains("/Tests/", StringComparison.OrdinalIgnoreCase)
        || relativePath.EndsWith("Test.cs", StringComparison.OrdinalIgnoreCase)
        || relativePath.EndsWith("Tests.cs", StringComparison.OrdinalIgnoreCase);

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

    private static string BuildSharedEditorialRules() =>
        """
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

        Use source files to understand what the package exposes and owns.
        Use test files to understand how consumers are expected to use the package.
        Use project files to understand dependencies and package relationships.
        Use README and metadata files as editorial context, but prefer source and tests when there is a conflict.

        You must not invent APIs, features, package relationships, dependencies, examples, use cases, or architectural claims not supported by the supplied context.

        Write with authority.
        Be concrete.
        Surface the non-obvious.
        Respect the reader's intelligence.
        Avoid marketing fluff.
        Avoid vague claims such as "robust", "seamless", "powerful", "easy-to-use", or "comprehensive" unless the supplied evidence makes the claim specific.

        Style rules:
        - Always include every required section heading verbatim on its own line, including the very first one. Never omit a heading.
        - Do not use em dashes in prose.
        - Do not use "Furthermore".
        - Do not use "In conclusion".
        - Do not use filler phrases.
        - Keep the writing tight.
        - Cut anything that does not add information.
        - Final output must be Markdown only.
        - Do not include analysis notes, confidence scores, citations, XML, JSON, or chat commentary unless the package prompt explicitly requests them.
        """;

    private static string BuildPackageDigestPrompt(string packageName) =>
        $$"""
        Write the documentation page for {{packageName}}.

        Output file:
        `result/{{packageName}}.md`

        Audience:
        Experienced .NET developers who are evaluating whether this NuGet package belongs in their project.
        Assume they understand .NET, NuGet, dependency injection, testing, hosting, ASP.NET Core, and common framework terminology.
        Do not explain basic .NET concepts.

        Grounding rules:
        Use only the supplied package context.
        Source files define the public API and package responsibility.
        Test files show intended usage.
        Project files show dependencies and package relationships.
        XML documentation is evidence, but rewrite descriptions for clarity when needed.
        README and metadata files may guide tone and positioning, but do not let them override source and tests.
        Do not invent features, scenarios, dependencies, method names, constructor overloads, namespaces, return types, or package relationships.
        Ignore internal implementation details unless they explain the public API.
        Prefer public types, extension methods, options/configuration types, factories, abstractions, and test-visible usage patterns.
        If the package has obsolete or deprecated APIs, do not present them as the recommended path.
        If the package is metadata-only, aggregate, or convenience-only, say that clearly and do not invent public APIs.
        The generated public API summary and engineering signals are reading aids, not final evidence. Validate them against the packed source and tests before turning them into claims.

        Engineering depth requirements:
        Look for design invariants, lifecycle contracts, callback wiring, factory boundaries, generic type constraints, exception guards, and test-backed edge cases.
        Explain a non-obvious design choice only when the source or tests make it visible.
        For each important API, prefer the useful engineering detail over a generic description: inheritance chain, why a generic parameter exists, what lifecycle it participates in, or what contract a consumer must respect.
        Name what the package deliberately does not solve when package boundaries, dependencies, or sibling packages make that clear.
        If generated context appears to pair the package with surprising or weak test evidence, report that as a confidence risk instead of smoothing it over.

        Before writing the final page, internally identify:
        - the package's specific responsibility inside the repository
        - the primary developer scenario
        - the 3-5 public types that matter most to consumers
        - the most representative usage pattern found in tests
        - the design invariants, lifecycle contracts, or guardrails that matter to consumers
        - what this package deliberately does not solve
        - any confidence risks caused by missing tests or unclear source

        Write exactly these sections.

        ## Overview

        1-2 concise paragraphs.
        Explain the specific responsibility this package owns.
        If it extends another package in the same repository, name that package explicitly.
        Be concrete.
        Avoid generic phrases such as "provides utilities" unless the package is genuinely a utility package.
        Do not oversell the package.

        ## Key APIs

        List the 3-5 most important public consumer-facing types, extension methods, options types, factories, abstractions, or helpers.

        Format each item exactly:

        `ApiName` - Description.

        Rules:
        - Mention only APIs visible in the supplied source.
        - Prefer APIs that a consumer would directly inherit from, instantiate, configure, call, or implement.
        - Descriptions should explain practical role, not merely repeat generic XML documentation wording.
        - Do not include incidental internal helpers, test-only types, or implementation details.
        - If fewer than 3 important public APIs exist, list fewer.

        ## Basic usage

        Write one complete C# example that demonstrates the package's central usage pattern from a consumer's point of view.

        Rules:
        - The example may be newly written for documentation.
        - It must be grounded in the supplied source files and tests.
        - Use tests to understand intended behavior, common setup, required constructor arguments, and expected usage flow.
        - Do not copy awkward regression tests, edge-case tests, silly sample values, or maintainer-internal namespaces unless they are the clearest documentation example.
        - Prefer a happy-path example unless an error path is the most important pattern.
        - Prefer a consumer namespace such as `MyProject.Tests` unless the original namespace is required for compilation.
        - The example should demonstrate at least two central package features when possible.
        - Avoid examples where the domain object is more prominent than the package itself.
        - Use real namespaces, real type names, real method calls, and real constructor signatures from the supplied content.
        - Do not invent APIs, overloads, extension methods, options, return types, helper methods, or setup that are not supported by the supplied content.
        - Keep it between 10 and 20 lines when feasible.
        - Use a ```csharp fenced code block.
        - Do not include ellipses, pseudocode, placeholders, or unexplained magic.
        - Do not override lifecycle or cleanup hooks unless the example cleans up a real resource or demonstrates lifecycle behavior as the main point.

        After the code block, write exactly 2 sentences:
        1. When to use this pattern.
        2. Why it matters.

        ## Installation

        ```bash
        dotnet add package {{packageName}}
        ```

        ## Usage guidance

        One honest paragraph.
        Explain when plain framework APIs, a lower-level package, a sibling package, or no package at all would be a better choice.
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

        Before writing the final page, internally identify:
        - the unifying purpose of the repository
        - the foundation or primary package, if one exists
        - optional add-on packages, if any exist
        - convenience or meta packages, if any exist
        - the recommended starting point
        - scenarios where installing or using less is better
        - recurring engineering patterns across packages, such as classic versus minimal hosting styles, shared fixture lifecycles, or layered package boundaries, when visible in the evidence
        - the one non-obvious insight developers should understand

        Write exactly these three sections.

        ## Overview

        Start with 2-3 sentences that explain the unifying purpose across the packages.
        Make clear what kind of developer problem this repository solves.
        Do not use broad marketing language.

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

        After the table, add one short paragraph with the primary selection rule.

        ## Package selection

        Start with one short introductory paragraph before the package subheadings.
        The paragraph must be specific to this repository.
        It should explain the selection principle, conceptual layering, or main trade-off across the packages.
        Do not repeat the Overview table row by row.
        Do not use generic phrases such as "the following packages are available".

        Then use one third-level heading per package.

        Format:

        ### Package.Name

        1 short paragraph.
        Explain what this package is for, what it adds, and when a developer should choose it.
        If it extends another package in the same repository, say so.
        If it is a convenience or meta package, say that clearly.
        Do not create bullets unless the package has genuinely enumerable capabilities.
        Use package names exactly as supplied.

        ## Usage guidance

        One or two paragraphs.
        Explain the non-obvious guidance that helps developers choose and use the repository correctly.
        Focus on boundaries, trade-offs, and common mistakes.
        It must be grounded in the actual package responsibilities and APIs.
        Do not use generic advice.
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
        sb.AppendLine("| Chunk | Path | Body bytes | Headings |");
        sb.AppendLine("|---|---|---:|---|");
        for (var i = 0; i < chunks.Count; i++)
        {
            var headings = ExtractHeadings(chunks[i]).ToList();
            var headingText = headings.Count == 0
                ? "(none)"
                : string.Join("; ", headings.Take(4));
            if (headings.Count > 4)
            {
                headingText += "; ...";
            }

            sb.AppendLine($"| {i + 1} | `{chunkPaths[i]}` | {Encoding.UTF8.GetByteCount(chunks[i])} | {EscapeMarkdownTableCell(headingText)} |");
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
