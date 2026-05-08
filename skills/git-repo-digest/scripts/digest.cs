#:property TargetFramework=net10.0
#:property Nullable=enable
#:property LangVersion=latest
#:property PublishAot=false

using System.Diagnostics;
using System.Globalization;
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
    private const int MaxExternalUsageFilesPerPackage = 40;
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
            var runId = CreateRunId();
            var workspace = ResolveWorkspacePath(options.OutputRoot, repoId, runId);
            var resultDir = Path.Combine(workspace, ResultDirectoryName);

            Directory.CreateDirectory(workspace);
            Directory.CreateDirectory(resultDir);
            DeleteLegacyContextArtifacts(workspace);

            Console.WriteLine($"[digest] repo-url={options.RepoUrl}");
            Console.WriteLine($"[digest] output-root={options.OutputRoot}");
            Console.WriteLine($"[digest] repo-id={repoId}");
            Console.WriteLine($"[digest] run-id={runId}");
            Console.WriteLine($"[digest] external-repo-count={options.ExternalRepoUrls.Count}");
            Console.WriteLine();

            var tempRoot = Path.Combine(Path.GetTempPath(), "git-repo-digest-" + Guid.NewGuid().ToString("N"));
            Directory.CreateDirectory(tempRoot);

            try
            {
                var cloneDir = Path.Combine(tempRoot, "repo");
                await CloneRepositoryAsync(options.RepoUrl, cloneDir);
                var externalRepositories = await CloneExternalRepositoriesAsync(options, tempRoot);

                var packages = DiscoverPackages(cloneDir);
                Console.WriteLine($"[digest] discovered {packages.Count} package(s)");

                var packageEntries = new List<PackageManifestEntry>();
                foreach (var package in packages)
                {
                    var resultPath = Path.Combine(ResultDirectoryName, package.Name + ".md").Replace('\\', '/');
                    var packageArtifacts = await WritePackageWorkspaceAsync(workspace, cloneDir, package, packages, externalRepositories);

                    packageEntries.Add(new PackageManifestEntry(
                        "package",
                        package.Name,
                        packageArtifacts.PromptPath,
                        packageArtifacts.Evidence,
                        resultPath));
                }

                var overviewPromptPath = Path.Combine("prompts", "overview.prompt.md").Replace('\\', '/');
                await WriteUtf8Async(
                    Path.Combine(workspace, overviewPromptPath),
                    BuildConceptualDigestPrompt(repoId, packages));

                await WriteUtf8Async(Path.Combine(workspace, "instructions.md"), BuildInstructions(options.RepoUrl, repoId));
                await WriteManifestAsync(
                    Path.Combine(workspace, "manifest.json"),
                    options,
                    repoId,
                    runId,
                    workspace,
                    packageEntries,
                    overviewPromptPath);

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
        var externalRepoUrls = GetOptions(args, "--external-repo-url")
            .Select(url => url.Trim())
            .Where(url => !string.IsNullOrWhiteSpace(url))
            .ToList();

        if (string.IsNullOrWhiteSpace(repoUrl))
        {
            throw new InvalidOperationException("Missing required option --repo-url.");
        }

        if (string.IsNullOrWhiteSpace(outputRoot))
        {
            throw new InvalidOperationException("Missing required option --output-root.");
        }

        ValidateRepositoryUrl(repoUrl);
        foreach (var externalRepoUrl in externalRepoUrls)
        {
            ValidateRepositoryUrl(externalRepoUrl);
        }

        var normalizedRepo = NormalizeRepositoryIdentity(repoUrl);
        foreach (var externalRepoUrl in externalRepoUrls)
        {
            var normalizedExternalRepo = NormalizeRepositoryIdentity(externalRepoUrl);
            if (normalizedExternalRepo.Equals(normalizedRepo))
            {
                throw new InvalidOperationException("--external-repo-url cannot point to the repository currently under digest.");
            }
        }

        return new DigestOptions(repoUrl.Trim(), Path.GetFullPath(outputRoot.Trim()), externalRepoUrls);
    }

    private static string? GetOption(string[] args, string name)
    {
        var index = Array.IndexOf(args, name);
        return index >= 0 && index + 1 < args.Length ? args[index + 1] : null;
    }

    private static IEnumerable<string> GetOptions(string[] args, string name)
    {
        for (var i = 0; i < args.Length; i++)
        {
            if (!string.Equals(args[i], name, StringComparison.Ordinal))
            {
                continue;
            }

            if (i + 1 >= args.Length || args[i + 1].StartsWith("--", StringComparison.Ordinal))
            {
                throw new InvalidOperationException($"Missing value for {name}.");
            }

            yield return args[i + 1];
            i++;
        }
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

    private static string CreateRunId() =>
        DateTimeOffset.UtcNow.ToString("yyyyMMdd-HHmmss'Z'", CultureInfo.InvariantCulture);

    private static string ResolveWorkspacePath(string outputRoot, string repoId, string runId)
    {
        var workspace = Path.Combine(outputRoot, repoId, runId);
        return Path.GetFullPath(workspace);
    }

    private static async Task CloneRepositoryAsync(string repoUrl, string cloneDir)
    {
        Console.WriteLine("[digest] cloning repository for discovery...");
        await RunProcessAsync("git", ["clone", "--depth", "1", repoUrl, cloneDir], Directory.GetCurrentDirectory());
    }

    private static async Task<IReadOnlyList<ExternalRepository>> CloneExternalRepositoriesAsync(DigestOptions options, string tempRoot)
    {
        if (options.ExternalRepoUrls.Count == 0)
        {
            return [];
        }

        Console.WriteLine("[digest] cloning external usage repositories...");

        var repositories = new List<ExternalRepository>();
        var seen = new HashSet<RepositoryIdentity>();
        for (var i = 0; i < options.ExternalRepoUrls.Count; i++)
        {
            var repoUrl = options.ExternalRepoUrls[i];
            var identity = NormalizeRepositoryIdentity(repoUrl);
            if (!seen.Add(identity))
            {
                continue;
            }

            var cloneDir = Path.Combine(tempRoot, "external-" + repositories.Count.ToString("D2"));
            Console.WriteLine($"[digest] external usage clone {repositories.Count + 1}: {repoUrl}");
            await RunProcessAsync("git", ["clone", "--depth", "1", repoUrl, cloneDir], Directory.GetCurrentDirectory());
            repositories.Add(new ExternalRepository(repoUrl, cloneDir, identity));
        }

        return repositories;
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

    private static async Task<PackageWorkspaceArtifacts> WritePackageWorkspaceAsync(
        string workspace,
        string cloneDir,
        PackageInfo package,
        IReadOnlyList<PackageInfo> packages,
        IReadOnlyList<ExternalRepository> externalRepositories)
    {
        Console.WriteLine($"[digest] writing evidence for {package.Name}...");

        var packageEvidenceRoot = Path.Combine("evidence", package.Name).Replace('\\', '/');
        var promptPath = Path.Combine("prompts", package.Name + ".prompt.md").Replace('\\', '/');
        var trackedFiles = await GetPackableTrackedFilesAsync(cloneDir);

        var sourceArtifacts = await WriteEvidenceArtifactsAsync(
            workspace,
            packageEvidenceRoot,
            "source",
            "sourceEvidence",
            package.Name,
            "api-shape",
            trackedFiles.Where(file => IsSourceEvidenceFile(file.RelativePath, package)).ToList());

        var testFiles = string.IsNullOrWhiteSpace(package.TestPath)
            ? new List<PackedFile>()
            : trackedFiles.Where(file => IsTestEvidenceFile(file.RelativePath, package)).ToList();
        var testsNote = string.IsNullOrWhiteSpace(package.TestPath)
            ? $"No owned test path was discovered for {package.Name}."
            : testFiles.Count == 0
                ? $"Owned test path {package.TestPath} contained no tracked test source files."
            : null;
        var testArtifacts = await WriteEvidenceArtifactsAsync(
            workspace,
            packageEvidenceRoot,
            "tests",
            "testEvidence",
            package.Name,
            "usage",
            testFiles,
            testsNote);

        var projectArtifacts = await WriteEvidenceArtifactsAsync(
            workspace,
            packageEvidenceRoot,
            "projects",
            "projectEvidence",
            package.Name,
            "project-metadata",
            trackedFiles.Where(file => IsProjectEvidenceFile(file.RelativePath, package)).ToList());

        var readmeArtifacts = await WriteEvidenceArtifactsAsync(
            workspace,
            packageEvidenceRoot,
            "readmes",
            "readmeEvidence",
            package.Name,
            "editorial-context",
            trackedFiles.Where(file => IsReadmeEvidenceFile(file.RelativePath, package)).ToList());

        var externalUsageFiles = await FindExternalUsageFilesAsync(cloneDir, package, packages, externalRepositories);
        var externalUsageNote = externalRepositories.Count == 0
            ? "No external usage repositories were provided."
            : externalUsageFiles.Count == 0
                ? $"External usage repositories were cloned, but no reference-plus-code usage matches were found for {package.Name}."
                : null;
        var externalUsageArtifacts = await WriteEvidenceArtifactsAsync(
            workspace,
            packageEvidenceRoot,
            "external-usage",
            "externalUsageEvidence",
            package.Name,
            "curated-external-usage",
            externalUsageFiles,
            externalUsageNote);

        var apiSummaryPath = Path.Combine(packageEvidenceRoot, "api-summary.md").Replace('\\', '/');
        await WriteUtf8Async(Path.Combine(workspace, apiSummaryPath), BuildPublicApiSummary(cloneDir, package));

        var engineeringSignalsPath = Path.Combine(packageEvidenceRoot, "engineering-signals.md").Replace('\\', '/');
        await WriteUtf8Async(Path.Combine(workspace, engineeringSignalsPath), BuildEngineeringSignals(cloneDir, package));

        var evidence = new PackageEvidenceArtifacts(
            sourceArtifacts,
            testArtifacts,
            projectArtifacts,
            readmeArtifacts,
            externalUsageArtifacts,
            apiSummaryPath,
            engineeringSignalsPath);

        await WriteUtf8Async(
            Path.Combine(workspace, promptPath),
            BuildPackageDigestPrompt(package, evidence));

        return new PackageWorkspaceArtifacts(promptPath, evidence);
    }

    private static string BuildPublicApiSummary(string cloneDir, PackageInfo package)
    {
        var discoveredApiTypes = DiscoverPublicApiTypes(cloneDir, package);
        var apiTypes = discoveredApiTypes.Take(20).ToList();
        if (apiTypes.Count == 0)
        {
            return "No public or protected API candidates were discovered by the lightweight source scanner. Treat source.xml or the complete ordered source chunks as authoritative.";
        }

        var sb = new StringBuilder();
        sb.AppendLine("This section is a deterministic navigation aid extracted from source text. Use it to focus the complete read, but treat source.xml or the complete ordered source chunks as authoritative.");
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
            sb.AppendLine($"Only the first {apiTypes.Count} of {discoveredApiTypes.Count} API candidates are shown. Read source.xml or the complete ordered source chunks for the full surface.");
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
            .Where(f => IsTestEvidenceFile(f.RelativePath, package))
            .Select(f => f.RelativePath)
            .Distinct(StringComparer.OrdinalIgnoreCase)
            .OrderBy(p => p, StringComparer.OrdinalIgnoreCase)
            .Take(12)
            .ToList();

        var sb = new StringBuilder();
        sb.AppendLine("This section is a deterministic signal map. It highlights places where the code may reveal design invariants, lifecycle contracts, package boundaries, or test-backed behavior. Validate every claim against source.xml, tests.xml, projects.xml, or their complete ordered chunks before writing.");
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

    private static async Task<IReadOnlyList<PackedFile>> FindExternalUsageFilesAsync(
        string digestCloneDir,
        PackageInfo package,
        IReadOnlyList<PackageInfo> packages,
        IReadOnlyList<ExternalRepository> externalRepositories)
    {
        if (externalRepositories.Count == 0)
        {
            return [];
        }

        var searchTerms = BuildExternalUsageSearchTerms(digestCloneDir, package).ToList();
        if (searchTerms.Count == 0)
        {
            return [];
        }

        var referencePackageNames = BuildExternalUsageReferencePackageNames(package, packages).ToList();
        var selected = new List<PackedFile>();
        var selectedPaths = new HashSet<string>(StringComparer.OrdinalIgnoreCase);

        foreach (var externalRepository in externalRepositories)
        {
            var trackedFiles = await GetPackableTrackedFilesAsync(externalRepository.CloneDir);
            var trackedFilesByPath = trackedFiles.ToDictionary(file => file.RelativePath, StringComparer.OrdinalIgnoreCase);
            var projectFiles = trackedFiles
                .Where(file => file.RelativePath.EndsWith(".csproj", StringComparison.OrdinalIgnoreCase))
                .Select(file => new
                {
                    ProjectFile = file,
                    ReferenceFiles = FindPackageReferenceFilesForProject(file, trackedFilesByPath, referencePackageNames)
                })
                .Where(match => match.ReferenceFiles.Count > 0)
                .OrderBy(match => match.ProjectFile.RelativePath, StringComparer.OrdinalIgnoreCase)
                .ToList();

            foreach (var projectMatch in projectFiles)
            {
                var projectFile = projectMatch.ProjectFile;
                var projectDirectory = Path.GetDirectoryName(projectFile.RelativePath)?.Replace('\\', '/') ?? string.Empty;
                var codeFiles = trackedFiles
                    .Where(file => file.RelativePath.EndsWith(".cs", StringComparison.OrdinalIgnoreCase))
                    .Where(file => string.IsNullOrWhiteSpace(projectDirectory) || IsUnderPath(file.RelativePath, projectDirectory))
                    .Select(file => new { File = file, Score = GetExternalUsageScore(file.FullPath, searchTerms) })
                    .Where(file => file.Score > 0)
                    .OrderByDescending(file => file.Score)
                    .ThenBy(file => file.File.RelativePath, StringComparer.OrdinalIgnoreCase)
                    .Take(8)
                    .Select(file => file.File)
                    .ToList();

                if (codeFiles.Count == 0)
                {
                    continue;
                }

                AddExternalUsageFile(selected, selectedPaths, externalRepository, projectFile);
                foreach (var referenceFile in projectMatch.ReferenceFiles.Where(file => !string.Equals(file.RelativePath, projectFile.RelativePath, StringComparison.OrdinalIgnoreCase)))
                {
                    AddExternalUsageFile(selected, selectedPaths, externalRepository, referenceFile);
                }

                foreach (var codeFile in codeFiles)
                {
                    AddExternalUsageFile(selected, selectedPaths, externalRepository, codeFile);
                }

                if (selected.Count >= MaxExternalUsageFilesPerPackage)
                {
                    return selected.Take(MaxExternalUsageFilesPerPackage).ToList();
                }
            }
        }

        return selected;
    }

    private static IReadOnlyList<PackedFile> FindPackageReferenceFilesForProject(
        PackedFile projectFile,
        IReadOnlyDictionary<string, PackedFile> trackedFilesByPath,
        IReadOnlyList<string> packageNames)
    {
        var referenceFiles = new List<PackedFile>();
        if (FileReferencesAnyPackage(projectFile.FullPath, packageNames))
        {
            referenceFiles.Add(projectFile);
        }

        foreach (var buildFileName in new[] { "Directory.Build.props", "Directory.Build.targets" })
        {
            var buildFile = FindNearestAncestorBuildFile(projectFile.RelativePath, buildFileName, trackedFilesByPath);
            if (buildFile is not null && FileReferencesAnyPackage(buildFile.FullPath, packageNames))
            {
                referenceFiles.Add(buildFile);
            }
        }

        return referenceFiles
            .DistinctBy(file => file.RelativePath, StringComparer.OrdinalIgnoreCase)
            .OrderBy(file => file.RelativePath, StringComparer.OrdinalIgnoreCase)
            .ToList();
    }

    private static PackedFile? FindNearestAncestorBuildFile(
        string projectRelativePath,
        string buildFileName,
        IReadOnlyDictionary<string, PackedFile> trackedFilesByPath)
    {
        var projectDirectory = Path.GetDirectoryName(projectRelativePath)?.Replace('\\', '/') ?? string.Empty;
        while (true)
        {
            var candidatePath = string.IsNullOrWhiteSpace(projectDirectory)
                ? buildFileName
                : projectDirectory.TrimEnd('/') + "/" + buildFileName;

            if (trackedFilesByPath.TryGetValue(candidatePath, out var buildFile))
            {
                return buildFile;
            }

            if (string.IsNullOrWhiteSpace(projectDirectory))
            {
                return null;
            }

            var parent = Path.GetDirectoryName(projectDirectory)?.Replace('\\', '/') ?? string.Empty;
            projectDirectory = string.Equals(parent, projectDirectory, StringComparison.OrdinalIgnoreCase) ? string.Empty : parent;
        }
    }

    private static IEnumerable<string> BuildExternalUsageReferencePackageNames(PackageInfo package, IReadOnlyList<PackageInfo> packages)
    {
        yield return package.Name;

        foreach (var candidate in packages.Where(candidate => !string.Equals(candidate.Name, package.Name, StringComparison.OrdinalIgnoreCase)))
        {
            if (PackageTransitivelyReferencesPackage(candidate, package, packages, []))
            {
                yield return candidate.Name;
            }
        }
    }

    private static bool PackageTransitivelyReferencesPackage(
        PackageInfo candidate,
        PackageInfo target,
        IReadOnlyList<PackageInfo> packages,
        HashSet<string> visited)
    {
        if (!visited.Add(candidate.Name))
        {
            return false;
        }

        foreach (var reference in candidate.BundledPackages)
        {
            if (ReferenceMatchesPackage(reference, target))
            {
                return true;
            }

            var referencedPackage = packages.FirstOrDefault(package => ReferenceMatchesPackage(reference, package));
            if (referencedPackage is not null && PackageTransitivelyReferencesPackage(referencedPackage, target, packages, visited))
            {
                return true;
            }
        }

        return false;
    }

    private static bool ReferenceMatchesPackage(string reference, PackageInfo package)
    {
        return string.Equals(reference, package.Name, StringComparison.OrdinalIgnoreCase)
               || string.Equals(Path.GetFileNameWithoutExtension(reference), package.Name, StringComparison.OrdinalIgnoreCase);
    }

    private static void AddExternalUsageFile(
        List<PackedFile> selected,
        HashSet<string> selectedPaths,
        ExternalRepository externalRepository,
        PackedFile file)
    {
        var externalPath = BuildExternalUsagePath(externalRepository.Identity, file.RelativePath);
        if (selectedPaths.Add(externalPath))
        {
            selected.Add(new PackedFile(file.FullPath, externalPath));
        }
    }

    private static string BuildExternalUsagePath(RepositoryIdentity identity, string relativePath)
    {
        var prefix = ("external/" + identity.Host + "/" + identity.Path).Replace('\\', '/').TrimEnd('/');
        return prefix + "/" + relativePath.Replace('\\', '/').TrimStart('/');
    }

    private static IEnumerable<ExternalUsageSearchTerm> BuildExternalUsageSearchTerms(string cloneDir, PackageInfo package)
    {
        var terms = new Dictionary<string, bool>(StringComparer.OrdinalIgnoreCase);
        AddExternalUsageSearchTerm(terms, package.Name, isStrong: true);

        foreach (var apiType in DiscoverPublicApiTypes(cloneDir, package))
        {
            AddExternalUsageSearchTerm(terms, GetSimpleTypeName(apiType.Name), isStrong: false);
        }

        var sourceDir = Path.Combine(cloneDir, package.SourcePath.Replace('/', Path.DirectorySeparatorChar));
        if (Directory.Exists(sourceDir))
        {
            foreach (var sourceFile in Directory.EnumerateFiles(sourceDir, "*.cs", SearchOption.AllDirectories))
            {
                if (ShouldSkipLowSignalFile(Path.GetRelativePath(cloneDir, sourceFile).Replace('\\', '/')))
                {
                    continue;
                }

                var content = File.ReadAllText(sourceFile, Encoding.UTF8);
                foreach (Match match in Regex.Matches(content, @"\bnamespace\s+([A-Za-z_][A-Za-z0-9_.]*)"))
                {
                    AddExternalUsageSearchTerm(terms, match.Groups[1].Value, isStrong: true);
                }
            }
        }

        return terms
            .Where(term => term.Key.Length > 2)
            .Select(term => new ExternalUsageSearchTerm(term.Key, term.Value))
            .OrderByDescending(term => term.IsStrong)
            .ThenByDescending(term => term.Value.Length)
            .ThenBy(term => term.Value, StringComparer.OrdinalIgnoreCase);
    }

    private static void AddExternalUsageSearchTerm(Dictionary<string, bool> terms, string value, bool isStrong)
    {
        if (string.IsNullOrWhiteSpace(value))
        {
            return;
        }

        terms[value] = isStrong || (terms.TryGetValue(value, out var existing) && existing);
    }

    private static int GetExternalUsageScore(string fullPath, IReadOnlyList<ExternalUsageSearchTerm> searchTerms)
    {
        var content = File.ReadAllText(fullPath, Encoding.UTF8);
        var score = 0;
        var hasStrongMatch = false;
        foreach (var term in searchTerms)
        {
            if (content.Contains(term.Value, StringComparison.Ordinal))
            {
                score += term.IsStrong ? 4 : 1;
                hasStrongMatch |= term.IsStrong;
            }
        }

        return hasStrongMatch ? score : 0;
    }

    private static bool FileReferencesAnyPackage(string projectFile, IReadOnlyList<string> packageNames)
    {
        try
        {
            var doc = XDocument.Load(projectFile, LoadOptions.PreserveWhitespace);
            return doc.Descendants()
                .Where(element => string.Equals(element.Name.LocalName, "PackageReference", StringComparison.OrdinalIgnoreCase))
                .Any(element => packageNames.Any(packageName =>
                    string.Equals((string?)element.Attribute("Include"), packageName, StringComparison.OrdinalIgnoreCase)
                    || string.Equals((string?)element.Attribute("Update"), packageName, StringComparison.OrdinalIgnoreCase)));
        }
        catch
        {
            var content = File.ReadAllText(projectFile, Encoding.UTF8);
            return packageNames.Any(packageName =>
            {
                var escapedPackageName = Regex.Escape(packageName);
                return Regex.IsMatch(
                    content,
                    @"<PackageReference\s+[^>]*(?:Include|Update)\s*=\s*[""']" + escapedPackageName + @"[""']",
                    RegexOptions.IgnoreCase);
            });
        }
    }

    private static RepositoryIdentity NormalizeRepositoryIdentity(string repoUrl)
    {
        var uri = new Uri(repoUrl);
        var host = uri.Host.Trim().ToLowerInvariant();
        var path = uri.AbsolutePath.Trim('/');
        if (path.EndsWith(".git", StringComparison.OrdinalIgnoreCase))
        {
            path = path[..^4];
        }

        path = Regex.Replace(path, "/+", "/", RegexOptions.None).Trim('/').ToLowerInvariant();
        if (string.IsNullOrWhiteSpace(host) || string.IsNullOrWhiteSpace(path))
        {
            throw new InvalidOperationException($"Could not normalize repository URL '{repoUrl}'.");
        }

        return new RepositoryIdentity(host, path);
    }

    private static string BuildInstructions(string repoUrl, string repoId) =>
        $$"""
        # Digest Writing Instructions

        Repository: {{repoUrl}}
        Repository id: {{repoId}}

        The deterministic runner generated this workspace. The agent writes Markdown digests; this script does not call an LLM and does not overwrite result files.

        ## Contract

        - Treat `manifest.json` as authoritative for prompt paths, evidence paths, phase order, and result paths.
        - Process package evidence sets one at a time.
        - Write every package result before writing the overview.
        - Each package prompt lives under `prompts/{PackageName}.prompt.md`.
        - Raw evidence lives under `evidence/{PackageName}/` as `source.xml`, `tests.xml`, `projects.xml`, `readmes.xml`, and `external-usage.xml`.
        - If a full evidence file is capped, truncated, summarized, or too large to read safely, read its index and then every listed chunk in numeric order.
        - Do not treat an index file as source evidence. It helps navigation only.
        - Do not treat generated public API summaries or engineering signals as standalone evidence. They help you decide what to inspect in raw evidence files.
        - For the overview, read `prompts/overview.prompt.md`, every completed package result file listed by the manifest, and supplementary project/readme evidence as needed.
        - Treat completed package result files as the primary overview source; project and README evidence is supplementary.
        - Write package digests to `result/{PackageName}.md`.
        - Write the overview to `result/Index.md`.
        - README/readme evidence is not authoritative for API shape.
        - If README and source disagree, source wins.
        - If README examples and tests disagree, tests win.
        - If external usage disagrees with current source, source wins.
        - Do not invent APIs, package relationships, examples, dependencies, support statements, performance claims, or architectural claims.
        - If evidence is missing, stale, contradictory, or too large to use safely, stop and report the blocker.

        ## Shared Editorial Rules

        {{BuildSharedEditorialRules()}}

        ## Suggested Order

        1. Read `manifest.json`.
        2. Read this file.
        3. For each package in the `packages` phase, read `prompts/{PackageName}.prompt.md`.
        4. Read source evidence directly if possible, or every source chunk in numeric order.
        5. Read project evidence directly if possible, or every project chunk in numeric order.
        6. Read test evidence directly if possible, or every test chunk in numeric order.
        7. Read external usage evidence directly if possible, or every external-usage chunk in numeric order.
        8. Read README evidence as editorial context only.
        9. Use `api-summary.md` and `engineering-signals.md` as navigation aids only.
        10. Write each package result file only after its required raw evidence has been inspected.
        11. Read `prompts/overview.prompt.md`, then read every completed package result file listed by the manifest.
        12. Read overview project/readme evidence as needed.
        13. Write `result/Index.md`.
        14. Validate that all manifest result paths exist.
        """;

    private static string BuildSharedEditorialRules() => """
        You are a senior .NET library documentation editor.

        Your job is to turn repository evidence into accurate, developer-facing Markdown documentation.

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
        Use external usage files as curated evidence for real consumer scenario shape only. They can influence Basic usage examples when current source evidence validates the APIs.
        Use project files as authoritative evidence for dependencies, target frameworks, package references, project references, and package relationships.
        Use README and metadata files only as editorial context for positioning, vocabulary, and high-level intent.
        Do not use README or metadata files as evidence for API shape when source code is available.
        If README, package README, catalog metadata, generated summaries, or engineering signals disagree with source code, follow the source code.
        If external usage disagrees with source code, follow the source code.
        If tests disagree with README examples, prefer tests for usage patterns.

        You must not invent APIs, features, package relationships, dependencies, examples, use cases, support statements, performance claims, or architectural claims not supported by the supplied evidence.

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

    private static string BuildPackageDigestPrompt(PackageInfo package, PackageEvidenceArtifacts evidence) => $$"""
        Write the documentation page for {{package.Name}}.

        Output file:
        `result/{{package.Name}}.md`

        Evidence set:
        - Source evidence: `{{evidence.Source.Path}}`
        - Source index: `{{evidence.Source.Index}}`
        - Test evidence: `{{evidence.Tests.Path}}`
        - Test index: `{{evidence.Tests.Index}}`
        - Project evidence: `{{evidence.Projects.Path}}`
        - Project index: `{{evidence.Projects.Index}}`
        - README evidence: `{{evidence.Readmes.Path}}`
        - README index: `{{evidence.Readmes.Index}}`
        - External usage evidence: `{{evidence.ExternalUsage.Path}}`
        - External usage index: `{{evidence.ExternalUsage.Index}}`
        - API summary: `{{evidence.ApiSummary}}`
        - Engineering signals: `{{evidence.EngineeringSignals}}`

        Package metadata:
        - Source path: `{{package.SourcePath}}`
        - Test path: `{{package.TestPath ?? "(not discovered)"}}`
        - Metadata-only package: `{{package.IsConveniencePackage}}`
        - Referenced packages: {{(package.BundledPackages.Count == 0 ? "(none declared)" : string.Join(", ", package.BundledPackages))}}

        Audience:
        Experienced .NET developers who are evaluating whether this NuGet package belongs in their project.
        Assume they understand .NET, NuGet, dependency injection, testing, hosting, ASP.NET Core, and common framework terminology.
        Do not explain basic .NET concepts.

        Grounding rules:
        Use only the supplied evidence set.

        Evidence authority:
        - `source.xml` or all source chunks are authoritative for API shape, inheritance, interfaces, generic constraints, method signatures, overloads, virtual/abstract members, lifecycle hooks, callbacks, and consumer-facing behavior.
        - `tests.xml` or all test chunks are authoritative for intended usage, behavioral contracts, common setup, edge cases, and test-backed usage flow.
        - `external-usage.xml` or all external-usage chunks contain curated consumer code selected from user-provided repositories. The runner includes only external projects that reference this package, or a discovered package that transitively references this package, in the project file or nearest ancestor Directory.Build.props / Directory.Build.targets and source or test C# files that contain a strong current-package marker such as this package's namespace or package id.
        - For `## Basic usage`, prefer representative external usage when it exists, validates against current source evidence, and shows a clearer consumer scenario than owned tests.
        - External usage is authority only for observed consumer usage shape, naming, setup style, and scenario selection. It is not authority for current API shape.
        - If external usage is stale, uses APIs missing from current source evidence, or only shows noisy plumbing, prefer `tests.xml`.
        - When external usage is unavailable or weak, use `tests.xml` as the primary inspiration source. Identify representative test setup, API calls, assertions, and usage flow, then rewrite those patterns into clean consumer-facing documentation examples.
        - Do not copy awkward regression tests, edge-case-only tests, silly test values, maintainer-internal namespaces, or maintainer-internal names verbatim unless they are the clearest usage evidence.
        - If test evidence is missing or weak, derive the smallest valid example from `source.xml` and write conservatively.
        - `projects.xml` or all projects chunks are authoritative for dependencies, target frameworks, package references, project references, packability, package metadata, and package relationships.
        - `readmes.xml` or all readmes chunks are editorial context only. Do not use README evidence as authority for API shape when source evidence exists.
        - `api-summary.md` and `engineering-signals.md` are reading aids only. They help focus inspection but are not final evidence.
        - XML documentation is useful evidence for intent, but source declarations and tests still win when there is a conflict.

        Do not use external usage, README, or metadata files as evidence for method names, inheritance, interfaces, overloads, required overrides, constructor signatures, target frameworks, package relationships, or examples when source, test, or project evidence is available.
        If README, package README, catalog metadata, generated summaries, or engineering signals disagree with source evidence, follow source evidence.
        If external usage disagrees with current source evidence, follow source evidence.
        If README examples disagree with test evidence, prefer test evidence.
        If source evidence is unclear and README is the only evidence for a claim, either write conservatively or omit the claim.

        Do not invent features, scenarios, dependencies, method names, constructor overloads, namespaces, return types, or package relationships.
        Ignore internal implementation details unless they explain the public API or a consumer-facing contract.
        Prefer public types, extension methods, options/configuration types, factories, abstractions, and test-visible usage patterns.
        Treat public base classes, abstract classes, virtual members, protected hooks, and template-method style APIs as important consumer-facing APIs when source or tests show that consumers inherit from them.
        If the package has obsolete or deprecated APIs, do not present them as the recommended path.

        Package-local API preference:
        - For normal code packages, prioritize APIs declared by the current package over APIs inherited from, referenced from, or re-exported from lower-level packages.
        - In `## Key APIs`, prefer APIs whose declarations are in the current package's source evidence.
        - In `## Basic usage`, the central demonstrated API should normally be declared by the current package.
        - If the current package declares a public base class that is intended for consumers to inherit from, treat that base class as a central package API, not as incidental inheritance detail.
        - When several base classes or abstractions are available, prefer the one declared in the current package's primary namespace or the same namespace as the package's main consumer-facing APIs.
        - If tests or external usage show a derived test fixture, host, provider, adapter, or other subclass, strongly consider a derived-class example that uses the package-owned base class and one or two of its exposed members.
        - If this package extends another package, demonstrate what this package adds, not only what the lower-level package already does.
        - If the current package provides a more specific abstraction, factory, adapter, provider, options type, middleware, serializer, mapper, host, client, store, validator, converter, extension method, integration type, or configuration model, make that the central API.
        - Lower-level APIs may appear as setup or supporting code only when they make the current package API easier to understand.
        - For convenience packages, each referenced-package example must favor APIs declared by that referenced package, not APIs from packages lower in that referenced package's dependency stack.

        If the package is metadata-only, aggregate-only, convenience-only, or produces no assembly of its own:
        - Say that clearly.
        - Do not invent public APIs owned by this package.
        - Treat project references and package references as authoritative evidence for what the package aggregates.
        - Make API ownership clear: the convenience package provides the single package reference, while APIs come from the referenced packages.

        Validate generated public API summaries and engineering signals against source evidence and test evidence before turning them into claims.

        Engineering depth requirements:
        Look for design invariants, lifecycle contracts, callback wiring, factory boundaries, generic type constraints, exception guards, and test-backed edge cases.
        Explain a non-obvious design choice only when the source or tests make it visible.
        For each important API, prefer the useful engineering detail over a generic description: inheritance chain, why a generic parameter exists, what lifecycle it participates in, what callback must be supplied, or what contract a consumer must respect.
        Name what the package deliberately does not solve when package boundaries, dependencies, or sibling packages make that clear.
        If the generated evidence set appears to pair the package with surprising or weak test evidence, reflect that conservatively instead of smoothing it over.

        Metadata guidance:
        Do not include target frameworks, dependency lists, package metadata, or repository facts in the Overview.
        Do not describe implementation mechanics before describing the consumer-facing responsibility.
        Do not use "targets netX" as a substitute for explaining what the package does.

        Before writing the final page, internally identify:
        - the package's specific responsibility inside the repository
        - the primary developer scenario
        - the 3-6 public APIs declared by this package that matter most to consumers
        - the most representative usage pattern found in source evidence, test evidence, and external usage evidence
        - any package-owned base class, abstract class, virtual hook, or protected member that represents the intended extension model
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
        - Mention only APIs visible in source evidence.
        - Prefer APIs declared by the current package over lower-level APIs made available through referenced packages.
        - Prefer APIs that a consumer would directly inherit from, instantiate, configure, call, or implement.
        - Include package-owned base classes when inheritance is the primary way consumers use the package.
        - For base classes, mention the required override, protected hook, lifecycle method, or directly exposed member that makes the base class useful.
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
        - Write exactly one C# example for each referenced code package that provides consumer-facing APIs.
        - The number of C# examples must equal the number of referenced code packages with consumer-facing APIs.
        - Do not cap, merge, sample, summarize, or omit referenced code packages from Basic usage.
        - Each example must be introduced by a third-level heading using this exact format: `### Referenced.Package.Name`.
        - Each referenced-package example must contain exactly one `[Fact]` or `[Theory]` method.
        - Each referenced-package example must focus on a distinct use case from that referenced package.
        - Each referenced-package example must make an API declared by that referenced package the central API.
        - If a referenced package extends a lower-level package, demonstrate what the referenced package adds, not only what the lower-level package already does.
        - Lower-level APIs may appear as setup or supporting code only.
        - Use each referenced package's test evidence as the primary inspiration source when available.
        - Prefer external usage for a referenced package when the referenced package has external usage evidence that validates against source and shows a clearer consumer scenario than owned tests.
        - Derive each example's setup, API calls, assertions, and usage flow from observed tests when available.
        - Rewrite test-inspired code into documentation-quality examples with clearer names and simpler values.
        - If a referenced package has missing or weak test evidence, derive the smallest valid example from that referenced package's source evidence and write conservatively.
        - Do not reuse the Basic usage examples already authored for the referenced package pages.
        - Do not paste unrelated snippets from the referenced package pages.
        - Do not copy awkward regression tests, edge-case-only tests, silly test values, maintainer-internal namespaces, or maintainer-internal names verbatim unless they are the clearest usage evidence.
        - Do not imply that the convenience package owns the APIs. The APIs are supplied by the referenced packages.
        - Include explicit using statements for every referenced package namespace used by each example.
        - Use a consumer namespace such as `MyProject.Tests`.
        - Include at least one assertion or observable result in each example.
        - Prefer small, realistic examples that demonstrate why installing the bundle is convenient across multiple testing styles.
        - Keep convenience-package examples straight to the point; show one clear use case per referenced package instead of trying to demonstrate that package's full depth.
        - If a referenced package is a framework integration package, prefer a small framework-native setup that demonstrates the referenced package API directly.
        - If a framework integration package requires setup code, prefer inline framework-native setup over fake application types unless the fake type is defined inside the snippet or exists in the supplied evidence.
        - Do not use framework-specific helper types, middleware, services, controllers, repositories, validators, adapters, options, or configuration objects unless they exist in the supplied evidence or are defined inside the snippet.
        - After all examples, write exactly one short paragraph explaining that the convenience package provides a single package reference while the APIs come from the referenced packages.

        If this is a normal code package:
        Write one complete C# example that demonstrates the package's central usage pattern from a consumer's point of view.
        Prefer a real-life, full-strength example over an artificially minimal snippet when source, tests, or external usage show that the richer example better demonstrates what the package is good at.
        A slightly more complex example is acceptable when it stays grounded, readable, and focused on the current package's API.

        The final normal-package C# example is invalid unless it satisfies all valid-example requirements.

        Valid-example requirements for normal code packages:
        - Include all necessary `using` statements.
        - Prefer explicit using statements over relying on implicit or global usings.
        - If the example uses a base type or API from a lower-level package, include the namespace for that package explicitly.
        - Include a consumer namespace such as `MyProject.Tests` unless the original namespace is required for compilation.
        - Include exactly one `[Fact]` or `[Theory]` method unless the package cannot be demonstrated correctly with one test.
        - Include at least one assertion or observable result.
        - Demonstrate the current package itself, not a fake application domain and not merely a lower-level referenced package.
        - The central demonstrated API must normally be declared by the current package.
        - If the package-owned base class is the central API, define a small derived class in the snippet when that is the clearest way to demonstrate the extension model.
        - If the example defines a derived class, keep it close to the test code and use the package base class from its real namespace.
        - If this package extends another package, demonstrate what this package adds, not only what the lower-level package already does.
        - Lower-level APIs may appear as setup or supporting code only.
        - Use `external-usage.xml` or all external-usage chunks as the primary inspiration source when it exists, validates against source, and shows a clearer consumer scenario than owned tests.
        - Use `tests.xml` or all test chunks as the primary inspiration source when external usage is unavailable, stale, or weaker than test evidence.
        - Derive setup, API calls, assertions, and usage flow from observed tests when available.
        - Rewrite test-inspired code into a documentation-quality consumer example with clearer names and simpler values.
        - If test evidence is missing or weak, derive the smallest valid example from source evidence and write conservatively.
        - Use only APIs, constructors, methods, overloads, options, return types, and extension methods visible in the supplied evidence.
        - Use a complete documentation snippet that a developer can understand without hidden files, hidden helpers, hidden services, or unexplained setup.
        - Keep the example focused on one central pattern.
        - Do not use top-level statements unless the package is a console/application package.
        - If the current package is a framework integration package, prefer a small framework-native setup that demonstrates the package API directly.
        - Do not introduce fake framework types, services, middleware, controllers, repositories, validators, adapters, options, or configuration objects unless they exist in the supplied evidence or are defined inside the snippet.

        Before writing a normal-package final example, internally draft and evaluate 4 candidate examples:
        1. A minimal happy-path example inspired by representative external usage when available, otherwise representative test evidence.
        2. An example that combines two central APIs declared by the current package when possible.
        3. An example based on the most representative test usage of the current package.
        4. A full-strength real-life example that demonstrates the current package's most distinctive feature, including a package-owned base class or lifecycle hook when that is how the package is meant to be used.

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
        - Reject examples that call fake helper methods such as `GenerateReport()`, `CreateService()`, `BuildHost()`, `FormatInvoice()`, `CreateClient()`, or similar unless that exact method exists in the supplied evidence.
        - Reject examples that introduce fake production services, fake middleware, fake controllers, fake repositories, fake options, fake validators, or fake domain types unless their implementation is included in the example.
        - Reject examples that register fake services such as `IMyService` / `MyService` unless those types are defined in the snippet or exist in the supplied evidence.
        - Reject examples that use framework-specific helper types, middleware, services, controllers, repositories, validators, adapters, options, or configuration objects unless they exist in the supplied evidence or are defined inside the snippet.
        - Reject examples where setup plumbing is more prominent than the package API.
        - Reject examples that require hidden registrations, hidden helper classes, hidden extension methods, hidden middleware, or unexplained magic.
        - Reject examples that use maintainer-internal namespaces unless the original namespace is required for compilation.
        - Reject examples that demonstrate only a failure path unless the package's central feature is error handling.
        - Reject examples that use multiple `[Fact]` or `[Theory]` methods to compensate for a weak central example.
        - Reject examples that mention a package feature in the explanation but do not demonstrate it in the code.
        - Reject examples that copy awkward regression tests, edge-case-only tests, silly test values, maintainer-internal namespaces, or maintainer-internal names verbatim unless they are the clearest usage evidence.
        - Reject examples for layered packages where a lower-level API is the central demonstrated API even though the current package declares a more specific API for the same scenario.
        - Reject examples where the current package's API is only incidental setup rather than the main concept being demonstrated.
        - Reject examples for framework integration packages where generic lower-level setup dominates and the package-specific integration API is only incidental.

        Selection criteria for normal code packages:
        - Prefer the candidate that is most likely to compile.
        - Prefer an external-usage-inspired candidate when it validates against current source and is clearer than maintainer-owned test code.
        - Prefer the candidate that is most strongly inspired by representative test evidence.
        - Prefer the candidate that demonstrates APIs declared by the current package.
        - Prefer the candidate that demonstrates the package itself more than a fake domain.
        - Prefer the candidate that uses the fewest invented names.
        - Prefer the smallest realistic consumer setup that still shows the package's real strength.
        - Prefer a richer full-strength candidate over a thin minimal candidate when both are grounded and the richer candidate better explains why the package exists.
        - Prefer a happy-path example unless an error path is the most important pattern.
        - Prefer a consumer namespace such as `MyProject.Tests` unless the original namespace is required for compilation.
        - Prefer examples that demonstrate at least two central package features when this can be done naturally.
        - For framework integration packages, prefer inline framework-native setup over fake application types.
        - For factory APIs, prefer the smallest factory-based example when it demonstrates the package better than a fixture class.
        - For base-class APIs, prefer inheriting from the package-owned base class and using one or two of its directly exposed members, required overrides, or lifecycle hooks.

        Output only the best candidate for normal code packages.

        Rules for all C# examples:
        - The example may be newly written for documentation.
        - It must be grounded in source evidence, test evidence, and external usage evidence when external usage is available.
        - Use external usage to understand real consumer scenario shape, naming, setup style, and which APIs appear together.
        - Use tests to understand intended behavior, common setup, required constructor arguments, expected usage flow, and meaningful assertions.
        - Use real namespaces, real type names, real method calls, and real constructor signatures from the supplied evidence.
        - Do not invent APIs, overloads, extension methods, options, return types, helper methods, setup methods, fake service methods, fake domain methods, or fake factory methods.
        - Prefer inline values over fake helper methods.
        - Keep each code block between 10 and 35 lines when feasible; use the extra space only when it reveals real package capability.
        - Use ```csharp fenced code blocks.
        - Do not include ellipses, pseudocode, placeholders, TODO comments, or unexplained magic.
        - Do not add a cleanup hook unless the hook cleans up a real resource used by the example.
        - Do not add a service registration unless the registered service type and implementation are defined in the example or exist in the supplied evidence.
        - Do not add framework pipeline or integration setup unless the setup exists in the supplied evidence or the example uses inline framework-native setup.

        For normal code packages, after the code block, write exactly 2 sentences:
        1. When to use this pattern.
        2. Why it matters.

        For convenience, aggregate, metadata-only, or no-assembly packages, do not write the normal two-sentence explanation after each code block. Instead, write one short explanatory paragraph after all referenced-package examples.

        ## Installation

        ```bash
        dotnet add package {{package.Name}}
        ```

        ## Usage guidance

        One honest paragraph.
        Start by explaining why this package is a good choice when the evidence-backed scenario fits.
        Name the positive adoption case first: the capability, extension model, integration point, or developer workflow that makes this package worth adding.
        Then, if useful, add one boundary sentence explaining when plain framework APIs, a lower-level package, a sibling package, or no package at all would be a better choice.
        Mention the nearest sibling package only when the evidence supports that relationship.
        Do not insult the package.
        Do not oversell it.
    """;

    private static string BuildConceptualDigestPrompt(string repoId, IReadOnlyList<PackageInfo> packages)
    {
        var packageList = packages.Count == 0
            ? "- No packages discovered."
            : string.Join(Environment.NewLine, packages.Select(p => $"- `{Path.Combine(ResultDirectoryName, p.Name + ".md").Replace('\\', '/')}`"));

        var supplementaryEvidence = packages.Count == 0
            ? "- No package evidence discovered."
            : string.Join(
                Environment.NewLine,
                packages.SelectMany(p => new[]
                {
                    $"- `{Path.Combine("evidence", p.Name, "projects.xml").Replace('\\', '/')}`",
                    $"- `{Path.Combine("evidence", p.Name, "readmes.xml").Replace('\\', '/')}`"
                }));

        return $$"""
        Write the conceptual overview page for this repository.

        Output file:
        `result/Index.md`

        Primary editorial context:
        Read every completed package digest below before writing this page:
        {{packageList}}

        Supplementary evidence:
        Read project/readme evidence only as needed to clarify package relationships, target frameworks, dependency boundaries, and repository positioning:
        {{supplementaryEvidence}}

        If packages exist, do not write `result/Index.md` from repository README or project evidence alone.
        The overview is invalid unless the completed package digest files have been opened and used as source material.

        Audience:
        Experienced .NET developers who need a mental model before opening an individual package page.
        Assume they understand .NET, NuGet, dependency injection, testing, hosting, ASP.NET Core, and common framework terminology.
        Do not explain basic .NET concepts.

        Grounding rules:
        The completed package digests are the primary editorial context.
        Use project and README evidence only as supplementary repository evidence.
        Supplementary README, package README, project, dependency, and metadata information may be used to clarify relationships.
        Do not invent package purposes, dependencies, recommended installation paths, scenarios, APIs, or architectural claims.
        Do not amplify unsupported claims from a package digest.
        Prefer concrete responsibilities and conceptual guidance over marketing language.
        Keep the overview focused on how developers should understand the repository's ideas, boundaries, and design vocabulary.
        If package digests disagree with each other, prefer the more specific package page and write conservatively.
        Link to package pages only as inline signposts, using relative Markdown links such as `[Package.Name](Package.Name.md)`.
        Do not organize this page around package inventory.
        Do not create a package-selection table.
        Do not create package-named subsections.
        Do not repeat package-page API lists, Basic usage examples, installation commands, or package-specific summaries.

        Before writing the final page, internally identify:
        - the unifying purpose of the repository
        - the concepts, patterns, or boundaries a developer must understand before package-level details
        - the important package-page `## Overview` and `## Key APIs` details that reveal each concept
        - which packages cover or extend each concept, when package relationships are visible in the evidence
        - how package APIs and responsibilities connect across layers, integrations, aggregate packages, or sibling packages
        - recurring engineering patterns such as classic versus minimal hosting styles, shared fixture lifecycles, factory shortcuts, or layered package boundaries, when visible in the evidence
        - scenarios where using a smaller package or fewer abstractions is better
        - the one non-obvious insight developers should understand

        Write exactly these three sections.

        ## Overview

        Start with 2-3 sentences that explain the unifying purpose across the repository.
        Make clear what kind of developer problem this repository solves.
        Do not use broad marketing language.
        Do not lead with repository metadata, target frameworks, or package counts.
        Do not include a package selection table.
        Do not summarize every package.

        ## Concepts

        Explain the concepts a developer should understand before reading package-specific pages.
        Start this section with one short introductory paragraph before the first concept heading.
        The introductory paragraph should frame the concept map for the repository and explain how the concepts relate at a high level.
        Do not place a third-level heading immediately after `## Concepts`.
        Use one third-level heading per concept.
        Include as many concept subsections as the completed package digests genuinely support.
        Do not impose a fixed concept count.
        Concepts must reflect the full picture from the completed package digests, especially each package's `## Overview` and `## Key APIs`.

        Format:

        Introductory paragraph.

        ### Concept name

        Rules:
        - Concept headings must describe ideas, patterns, boundaries, responsibilities, or trade-offs, not package names.
        - Each concept subsection should explain the idea first, then connect the relevant package responsibilities and key APIs when that helps the reader understand the full picture.
        - Link package names inline with relative links such as `[Package.Name](Package.Name.md)`.
        - Use completed package `## Key APIs` sections to identify the real APIs that define the concept, but summarize them in prose instead of copying API inventories.
        - If one package covers several concepts, link to it naturally in each relevant concept instead of creating a package section.
        - If several packages share or layer the same concept, mention those package links inline in the same concept prose.
        - Prefer connecting dots between packages over describing each package in isolation.
        - Do not end concept subsections with a repeated "Covered by" line.
        - Do not create concept-to-package tables.
        - Do not list every API, usage example, or installation command.
        - Do not copy package page overview paragraphs.
        - For a single-package repository, still write real concept subsections and skip all package-selection framing.

        ## Usage guidance

        One or two paragraphs.
        Explain the non-obvious guidance that helps developers apply the concepts correctly.
        Focus on boundaries, trade-offs, and mistakes implied by package responsibilities or API design.
        It must be grounded in the actual package responsibilities and APIs.
        Do not use generic advice.
        Do not repeat the concept section.
        Do not introduce package-page details that belong in an individual package deep dive.
        Prefer a practical decision rule over a slogan.
        """;
    }

    private static void AppendMultiline(StringBuilder sb, string value)
    {
        sb.AppendLine(value.Trim());
        sb.AppendLine();
    }

    private static async Task<EvidenceArtifacts> WriteEvidenceArtifactsAsync(
        string workspace,
        string packageEvidenceRoot,
        string evidenceName,
        string rootElementName,
        string packageName,
        string authority,
        IReadOnlyList<PackedFile> files,
        string? note = null)
    {
        var evidencePath = Path.Combine(packageEvidenceRoot, evidenceName + ".xml").Replace('\\', '/');
        var evidenceXml = await BuildEvidenceXmlAsync(rootElementName, packageName, files, note);
        await WriteUtf8Async(Path.Combine(workspace, evidencePath), evidenceXml);

        var chunks = Encoding.UTF8.GetByteCount(evidenceXml) > MaxContextChunkBodyBytes
            ? SplitContextIntoChunks(evidenceXml).ToList()
            : new List<string>();

        var chunkPaths = new List<string>(chunks.Count);
        var chunkDirectoryPath = Path.Combine(packageEvidenceRoot, evidenceName + ".chunks").Replace('\\', '/');
        var chunkDirectory = Path.Combine(workspace, chunkDirectoryPath);
        if (Directory.Exists(chunkDirectory))
        {
            Directory.Delete(chunkDirectory, recursive: true);
        }

        if (chunks.Count > 0)
        {
            Directory.CreateDirectory(chunkDirectory);
            for (var i = 0; i < chunks.Count; i++)
            {
                var chunkNumber = i + 1;
                var chunkFileName = chunkNumber.ToString("D4") + ".xml";
                var chunkPath = Path.Combine(chunkDirectoryPath, chunkFileName).Replace('\\', '/');
                chunkPaths.Add(chunkPath);

                var chunkContent = BuildEvidenceChunkFile(evidenceName + ".xml", chunkNumber, chunks.Count, chunks[i]);
                await WriteUtf8Async(Path.Combine(workspace, chunkPath), chunkContent);
            }
        }

        var indexPath = Path.Combine(packageEvidenceRoot, evidenceName + ".index.md").Replace('\\', '/');
        var index = BuildEvidenceIndex(evidenceName, evidencePath, indexPath, chunkPaths, chunks, evidenceXml, authority);
        await WriteUtf8Async(Path.Combine(workspace, indexPath), index);

        return new EvidenceArtifacts(evidencePath, indexPath, chunkPaths, authority);
    }

    private static async Task<string> BuildEvidenceXmlAsync(
        string rootElementName,
        string packageName,
        IReadOnlyList<PackedFile> files,
        string? note)
    {
        var sb = new StringBuilder();
        sb.Append("<");
        sb.Append(rootElementName);
        sb.Append(" package=\"");
        sb.Append(EscapeXmlAttribute(packageName));
        sb.AppendLine("\" generatedBy=\"git-repo-digest\">");

        if (!string.IsNullOrWhiteSpace(note))
        {
            sb.Append("  <note>");
            sb.Append(EscapeXmlText(note));
            sb.AppendLine("</note>");
        }

        foreach (var file in files.OrderBy(file => file.RelativePath, StringComparer.OrdinalIgnoreCase))
        {
            var content = await File.ReadAllTextAsync(file.FullPath, Encoding.UTF8);
            sb.Append("  <file path=\"");
            sb.Append(EscapeXmlAttribute(file.RelativePath));
            sb.AppendLine("\">");
            AppendCData(sb, content);
            sb.AppendLine();
            sb.AppendLine("  </file>");
        }

        sb.Append("</");
        sb.Append(rootElementName);
        sb.AppendLine(">");
        return sb.ToString();
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

    private static string BuildEvidenceChunkFile(string sourceFileName, int chunkNumber, int chunkCount, string chunkBody)
    {
        var sb = new StringBuilder();
        sb.Append("<contextChunk source=\"");
        sb.Append(EscapeXmlAttribute(sourceFileName));
        sb.Append("\" chunk=\"");
        sb.Append(chunkNumber);
        sb.Append("\" chunks=\"");
        sb.Append(chunkCount);
        sb.AppendLine("\" generatedBy=\"git-repo-digest\">");
        AppendCData(sb, chunkBody);
        sb.AppendLine();
        sb.AppendLine("</contextChunk>");
        return sb.ToString();
    }

    private static string BuildEvidenceIndex(
        string evidenceName,
        string evidencePath,
        string indexPath,
        IReadOnlyList<string> chunkPaths,
        IReadOnlyList<string> chunks,
        string evidenceXml,
        string authority)
    {
        var sb = new StringBuilder();
        sb.AppendLine("# Evidence Index");
        sb.AppendLine();
        sb.AppendLine("Evidence file: `" + evidencePath + "`");
        sb.AppendLine("Index path: `" + indexPath + "`");
        sb.AppendLine("Authority: " + authority);
        sb.AppendLine("Chunk count: " + chunkPaths.Count);
        sb.AppendLine("Evidence bytes: " + Encoding.UTF8.GetByteCount(evidenceXml));
        sb.AppendLine();
        sb.AppendLine($"This index is not source evidence. Read {evidenceName}.xml directly when possible, or every {evidenceName}.chunks/*.xml file in numeric order.");
        sb.AppendLine();

        sb.AppendLine("## Read Order");
        sb.AppendLine();
        sb.AppendLine("1. Read this index to understand the evidence layout.");
        sb.AppendLine("2. Read the full evidence file directly when your tools can read it completely without truncation.");
        sb.AppendLine("3. If the full evidence file is capped or unavailable, read every listed chunk in numeric order.");
        sb.AppendLine();

        if (chunkPaths.Count > 0)
        {
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
        }

        var evidenceHeadings = ExtractHeadings(evidenceXml).ToList();
        if (evidenceHeadings.Count > 0)
        {
            sb.AppendLine("## Evidence Sections");
            sb.AppendLine();
            foreach (var heading in evidenceHeadings)
            {
                sb.AppendLine("- " + heading);
            }
            sb.AppendLine();
        }

        var packedPaths = ExtractPackedFilePaths(evidenceXml).Take(200).ToList();
        if (packedPaths.Count > 0)
        {
            sb.AppendLine("## Evidence File Inventory");
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

        if (normalized.StartsWith("external/", StringComparison.OrdinalIgnoreCase))
        {
            return "External Usage";
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

    private static string EscapeXmlAttribute(string value) =>
        value.Replace("&", "&amp;", StringComparison.Ordinal)
            .Replace("\"", "&quot;", StringComparison.Ordinal)
            .Replace("<", "&lt;", StringComparison.Ordinal)
            .Replace(">", "&gt;", StringComparison.Ordinal);

    private static string EscapeXmlText(string value) =>
        value.Replace("&", "&amp;", StringComparison.Ordinal)
            .Replace("<", "&lt;", StringComparison.Ordinal)
            .Replace(">", "&gt;", StringComparison.Ordinal);

    private static void AppendCData(StringBuilder sb, string value)
    {
        sb.Append("<![CDATA[");
        sb.Append(value.Replace("]]>", "]]]]><![CDATA[>", StringComparison.Ordinal));
        sb.Append("]]>");
    }

    private static Regex PublicTypeRegex() => PublicTypeExpression;

    private static Regex PublicMemberRegex() => PublicMemberExpression;

    private static async Task<IReadOnlyList<PackedFile>> GetPackableTrackedFilesAsync(string cloneDir)
    {
        return (await GetTrackedFilesAsync(cloneDir))
            .Where(file => !IsUnderSkippedDirectory(file.RelativePath))
            .Where(file => !ShouldSkipLowSignalFile(file.RelativePath))
            .Where(file => IsTextFile(file.FullPath))
            .OrderBy(file => file.RelativePath, StringComparer.OrdinalIgnoreCase)
            .ToList();
    }

    private static bool IsSourceEvidenceFile(string relativePath, PackageInfo package)
    {
        return IsUnderPath(relativePath, package.SourcePath)
            && relativePath.EndsWith(".cs", StringComparison.OrdinalIgnoreCase)
            && !IsReadmeFile(relativePath)
            && !IsProjectMetadataFile(relativePath);
    }

    private static bool IsTestEvidenceFile(string relativePath, PackageInfo package)
    {
        return !string.IsNullOrWhiteSpace(package.TestPath)
            && IsUnderPath(relativePath, package.TestPath!)
            && relativePath.EndsWith(".cs", StringComparison.OrdinalIgnoreCase)
            && !IsReadmeFile(relativePath)
            && !IsProjectMetadataFile(relativePath);
    }

    private static bool IsProjectEvidenceFile(string relativePath, PackageInfo package)
    {
        var fileName = Path.GetFileName(relativePath);
        if (IsRootProjectMetadataFile(relativePath))
        {
            return true;
        }

        if (!fileName.EndsWith(".csproj", StringComparison.OrdinalIgnoreCase))
        {
            return false;
        }

        return IsUnderPath(relativePath, package.SourcePath)
            || (!string.IsNullOrWhiteSpace(package.TestPath) && IsUnderPath(relativePath, package.TestPath!));
    }

    private static bool IsReadmeEvidenceFile(string relativePath, PackageInfo package)
    {
        if (!relativePath.EndsWith(".md", StringComparison.OrdinalIgnoreCase))
        {
            return false;
        }

        var fileName = Path.GetFileName(relativePath);
        return string.Equals(relativePath, "README.md", StringComparison.OrdinalIgnoreCase)
            || (relativePath.StartsWith(".nuget/", StringComparison.OrdinalIgnoreCase)
                && string.Equals(fileName, "README.md", StringComparison.OrdinalIgnoreCase))
            || (relativePath.StartsWith("docs/", StringComparison.OrdinalIgnoreCase)
                && fileName.StartsWith("README", StringComparison.OrdinalIgnoreCase))
            || (IsUnderPath(relativePath, package.SourcePath)
                && fileName.StartsWith("README", StringComparison.OrdinalIgnoreCase))
            || (!string.IsNullOrWhiteSpace(package.TestPath)
                && IsUnderPath(relativePath, package.TestPath!)
                && fileName.StartsWith("README", StringComparison.OrdinalIgnoreCase));
    }

    private static bool IsUnderPath(string relativePath, string root)
    {
        var normalizedRoot = root.Replace('\\', '/').TrimEnd('/');
        return string.Equals(relativePath, normalizedRoot, StringComparison.OrdinalIgnoreCase)
            || relativePath.StartsWith(normalizedRoot + "/", StringComparison.OrdinalIgnoreCase);
    }

    private static bool IsReadmeFile(string relativePath) =>
        Path.GetFileName(relativePath).StartsWith("README", StringComparison.OrdinalIgnoreCase);

    private static bool IsProjectMetadataFile(string relativePath) =>
        IsRootProjectMetadataFile(relativePath)
        || Path.GetFileName(relativePath).EndsWith(".csproj", StringComparison.OrdinalIgnoreCase);

    private static bool IsRootProjectMetadataFile(string relativePath)
    {
        return string.Equals(relativePath, "Directory.Build.props", StringComparison.OrdinalIgnoreCase)
            || string.Equals(relativePath, "Directory.Build.targets", StringComparison.OrdinalIgnoreCase)
            || string.Equals(relativePath, "Directory.Packages.props", StringComparison.OrdinalIgnoreCase)
            || string.Equals(relativePath, "NuGet.config", StringComparison.OrdinalIgnoreCase)
            || string.Equals(relativePath, "global.json", StringComparison.OrdinalIgnoreCase);
    }

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
        string? runId,
        string workspace,
        IReadOnlyList<PackageManifestEntry> packages,
        string overviewPromptPath)
    {
        var packagesPhase = new
        {
            name = "packages",
            packages = packages.Select(p => new { p.kind, p.name, p.prompt, p.evidence, p.result }).ToList(),
            targets = packages.Select(p => new { p.kind, p.name, p.prompt, p.evidence, p.result }).ToList()
        };

        var overviewPhase = new
        {
            name = "overview",
            dependsOn = "packages",
            package = new
            {
                kind = "overview",
                name = "Index",
                prompt = overviewPromptPath,
                sourceResults = packages.Select(p => p.result).ToList(),
                supplementalEvidence = packages.Select(p => new
                {
                    package = p.name,
                    projects = p.evidence.Projects.Path,
                    readmes = p.evidence.Readmes.Path
                }).ToList(),
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
                id = repoId,
                runId,
                externalUsageRepositories = options.ExternalRepoUrls
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

        var json = JsonSerializer.Serialize(
            manifest,
            new JsonSerializerOptions
            {
                PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
                WriteIndented = true
            });
        await WriteUtf8Async(manifestPath, json + Environment.NewLine);
    }

    private static void DeleteLegacyContextArtifacts(string workspace)
    {
        var workspaceRoot = Path.GetFullPath(workspace).TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar)
            + Path.DirectorySeparatorChar;

        foreach (var file in Directory.EnumerateFiles(workspace, "*.context.md")
                     .Concat(Directory.EnumerateFiles(workspace, "*.context.index.md")))
        {
            var fullPath = Path.GetFullPath(file);
            if (fullPath.StartsWith(workspaceRoot, StringComparison.OrdinalIgnoreCase))
            {
                File.Delete(fullPath);
            }
        }

        foreach (var directory in Directory.EnumerateDirectories(workspace, "*.context.chunks"))
        {
            var fullPath = Path.GetFullPath(directory).TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar)
                + Path.DirectorySeparatorChar;
            if (fullPath.StartsWith(workspaceRoot, StringComparison.OrdinalIgnoreCase))
            {
                Directory.Delete(directory, recursive: true);
            }
        }
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
            git-repo-digest deterministic evidence generator

            Usage:
              dotnet run --file scripts/digest.cs -- --repo-url <url> --output-root <path>
              dotnet run --file scripts/digest.cs -- --repo-url <url> --output-root <path> --external-repo-url <url> [--external-repo-url <url>]

            Required:
              --repo-url      Fully qualified git repository URL, for example https://github.com/owner/repo
              --output-root   Directory where the {repo-id} digest workspace will be written

            Optional:
              --external-repo-url  Public repository URL to clone and search locally for curated consumer usage.
                                   Repeat this option to provide multiple external usage repositories.

            Fixed conventions:
              repo-id      Derived from the final repository URL path segment
              run-id       UTC timestamp folder formatted yyyyMMdd-HHmmssZ
              result dir   result

            Output:
              {output-root}/{repo-id}/{run-id}/manifest.json
              {output-root}/{repo-id}/{run-id}/instructions.md
              {output-root}/{repo-id}/{run-id}/prompts/{PackageName}.prompt.md
              {output-root}/{repo-id}/{run-id}/prompts/overview.prompt.md
              {output-root}/{repo-id}/{run-id}/evidence/{PackageName}/source.xml
              {output-root}/{repo-id}/{run-id}/evidence/{PackageName}/tests.xml
              {output-root}/{repo-id}/{run-id}/evidence/{PackageName}/projects.xml
              {output-root}/{repo-id}/{run-id}/evidence/{PackageName}/readmes.xml
              {output-root}/{repo-id}/{run-id}/evidence/{PackageName}/external-usage.xml
              {output-root}/{repo-id}/{run-id}/evidence/{PackageName}/*.index.md
              {output-root}/{repo-id}/{run-id}/evidence/{PackageName}/*.chunks/*.xml
              {output-root}/{repo-id}/{run-id}/result/

            Notes:
              - This script writes deterministic evidence and prompts only.
              - This script does not call an LLM.
              - Existing result/*.md files are not overwritten.
              - Evidence packing uses the bundled C# packer over the cloned repository's tracked files.
            """);
    }
}

internal sealed record DigestOptions(
    string RepoUrl,
    string OutputRoot,
    IReadOnlyList<string> ExternalRepoUrls);

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

internal sealed record PackageWorkspaceArtifacts(
    string PromptPath,
    PackageEvidenceArtifacts Evidence);

internal sealed record PackageEvidenceArtifacts(
    EvidenceArtifacts Source,
    EvidenceArtifacts Tests,
    EvidenceArtifacts Projects,
    EvidenceArtifacts Readmes,
    EvidenceArtifacts ExternalUsage,
    string ApiSummary,
    string EngineeringSignals);

internal sealed record EvidenceArtifacts(
    string Path,
    string Index,
    IReadOnlyList<string> Chunks,
    string Authority);

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

internal sealed record RepositoryIdentity(string Host, string Path);

internal sealed record ExternalRepository(
    string Url,
    string CloneDir,
    RepositoryIdentity Identity);

internal sealed record ExternalUsageSearchTerm(
    string Value,
    bool IsStrong);

internal sealed record PackageManifestEntry(
    string kind,
    string name,
    string prompt,
    PackageEvidenceArtifacts evidence,
    string result);

internal sealed record PackedFile(string FullPath, string RelativePath);
