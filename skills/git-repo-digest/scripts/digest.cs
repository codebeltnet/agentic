#:property TargetFramework=net10.0
#:property Nullable=enable
#:property LangVersion=latest
#:property PublishAot=false

using System.Diagnostics;
using System.Globalization;
using System.Net;
using System.Text;
using System.Text.Json;
using System.Text.RegularExpressions;
using System.Xml.Linq;

return await DigestScript.RunAsync(args);

internal static class DigestScript
{
    private const string ToolName = "git-repo-digest";
    private const string ResultDirectoryName = "result";
    private const string PromptDirectoryName = "prompts";
    private const string EvidenceDirectoryName = "evidence";
    private const string SourceDirectoryName = "src";
    private const string TestDirectoryName = "test";
    private const string AgentGeneratedBy = "git-repo-digest";
    private const string ExampleValidationProjectName = "DigestBasicUsageValidation";

    private const int MaxEvidenceChunkBodyBytes = 36 * 1024;
    private const int MaxExternalUsageFilesPerPackage = 96;
    private const int MaxApiSummaryTypes = 512;
    private const int MaxApiSummaryMembersPerType = 32;

    private static readonly TimeSpan DefaultProcessTimeout = TimeSpan.FromMinutes(5);
    private static readonly HttpClient HttpClient = new()
    {
        Timeout = TimeSpan.FromSeconds(10)
    };
    private static readonly Encoding Utf8NoBom = new UTF8Encoding(encoderShouldEmitUTF8Identifier: false);
    private static readonly string[] EngineeringRoleSuffixes =
    [
        "Base",
        "Binder",
        "Builder",
        "Converter",
        "Decorator",
        "Dispatcher",
        "Endpoint",
        "Extensions",
        "Factory",
        "Filter",
        "Handler",
        "Mapper",
        "Middleware",
        "Options",
        "Parser",
        "Provider",
        "Resolver",
        "Serializer",
        "Specification",
        "Strategy",
        "Validator"
    ];

    private static readonly string[] LowSignalLifecycleValues =
    [
        "Application",
        "ConfigureAwait",
        "ConfiguredTaskAwaitable",
        "Host",
        "Hosting",
        "Initialized",
        "Initializes"
    ];

    private static readonly string[] ExampleRoleSuffixes =
    [
        "Builder",
        "Client",
        "Collector",
        "Comparer",
        "Context",
        "Dispatcher",
        "Factory",
        "Fixture",
        "Host",
        "Logger",
        "Pipeline",
        "Provider",
        "Recorder",
        "Sink",
        "Store",
        "Test"
    ];

    private static readonly string[] DirectWriteMemberNames =
    [
        "Add",
        "Append",
        "Capture",
        "Dispatch",
        "Emit",
        "Enqueue",
        "Log",
        "Publish",
        "Raise",
        "Record",
        "Save",
        "Send",
        "Set",
        "Write"
    ];

    private static readonly string[] DirectReadMemberNames =
    [
        "Any",
        "Contains",
        "Count",
        "Find",
        "Get",
        "Query",
        "QueryFor",
        "Read",
        "Single"
    ];

    private static readonly string[] ToyExampleTerms =
    [
        "BuildHost",
        "CreateClient",
        "CreateService",
        "Dummy",
        "FakeRepository",
        "Foo",
        "FormatInvoice",
        "GenerateReport",
        "Greeting",
        "Hello",
        "IMessageService",
        "IMyRepository",
        "IMyService",
        "MessageService",
        "MyRepository",
        "MyService",
        "OK",
        "Sample",
        "SampleController",
        "SampleMiddleware",
        "World"
    ];

    private static readonly string[] OwnedTestProjectSuffixes = ["Tests", "FunctionalTests"];
    private static readonly string[] RootProjectMetadataFileNames =
    [
        "Directory.Build.props",
        "Directory.Build.targets",
        "Directory.Packages.props",
        "NuGet.config",
        "global.json"
    ];

    private static readonly Regex PublicTypeExpression = new(
        @"(?m)^\s*(?:\[[^\]]+\]\s*)*(?:public|protected\s+internal|internal\s+protected)\s+(?:(?:static|abstract|sealed|partial|readonly|unsafe)\s+)*(?<kind>record\s+class|record\s+struct|class|interface|struct|record|enum)\s+(?<name>[A-Za-z_][A-Za-z0-9_]*(?:<[^>{};]+>)?)\s*(?::\s*(?<base>[^{]+))?",
        RegexOptions.Compiled | RegexOptions.CultureInvariant);

    private static readonly Regex PublicMemberExpression = new(
        @"(?m)^\s*(?:\[[^\]]+\]\s*)*(?:public|protected(?:\s+internal)?|internal\s+protected)\s+(?<decl>[^\r\n{;]+(?:\([^\r\n;{}]*\))?)",
        RegexOptions.Compiled | RegexOptions.CultureInvariant);

    private static readonly Regex CSharpCodeBlockExpression = new(
        @"(?ms)^```csharp[^\r\n]*\r?\n(?<code>.*?)(?:\r?\n)^```[ \t]*$",
        RegexOptions.Compiled | RegexOptions.CultureInvariant);

    private static readonly Regex ClassDeclarationExpression = new(
        @"(?m)^\s*(?:public\s+)?(?:(?:sealed|abstract|partial)\s+)*class\s+(?<name>[A-Za-z_][A-Za-z0-9_]*)\s*(?::\s*(?<base>[^{\r\n]+))?",
        RegexOptions.Compiled | RegexOptions.CultureInvariant);

    private static readonly Regex ConstructorParameterExpression = new(
        @"(?m)\b(?<ctor>[A-Za-z_][A-Za-z0-9_]*)\s*\((?<parameters>[^)]*)\)",
        RegexOptions.Compiled | RegexOptions.CultureInvariant);

    private static readonly Regex TypedVariableDeclarationExpression = new(
        @"(?m)\b(?<type>[A-Z][A-Za-z0-9_.]*(?:<[^;=()]+>)?)\s+(?<name>_?[A-Za-z_][A-Za-z0-9_]*)\s*(?:=|;)",
        RegexOptions.Compiled | RegexOptions.CultureInvariant);

    private static readonly Regex VarConstructionExpression = new(
        @"(?m)\b(?:using\s+)?var\s+(?<name>_?[A-Za-z_][A-Za-z0-9_]*)\s*=\s*new\s+(?<type>[A-Z][A-Za-z0-9_.]*(?:<[^;=()]+>)?)",
        RegexOptions.Compiled | RegexOptions.CultureInvariant);

    private static readonly Regex MemberAccessExpression = new(
        @"\b(?<receiver>[A-Za-z_][A-Za-z0-9_]*)\.(?<member>[A-Z][A-Za-z0-9_]*)\b",
        RegexOptions.Compiled | RegexOptions.CultureInvariant);

    private static readonly Regex ToyExampleTermExpression = new(
        @"\b(?<term>" + string.Join("|", ToyExampleTerms.Select(Regex.Escape)) + @")\b",
        RegexOptions.Compiled | RegexOptions.CultureInvariant | RegexOptions.IgnoreCase);

    private static readonly Regex CodebeltTestConstructorExpression = new(
        @"(?ms)\bpublic\s+[A-Za-z_][A-Za-z0-9_]*\s*\([^)]*\bITestOutputHelper\s+(?<output>[A-Za-z_][A-Za-z0-9_]*)[^)]*\)\s*:\s*base\s*\([^)]*\k<output>[^)]*\)",
        RegexOptions.Compiled | RegexOptions.CultureInvariant);

    private static readonly Regex TestOutputExpression = new(
        @"\bTestOutput\.(?:Write|WriteLine|WriteLines)\s*\(",
        RegexOptions.Compiled | RegexOptions.CultureInvariant);

    private static readonly Regex FenceLineInsideCodeExpression = new(
        @"(?m)^```",
        RegexOptions.Compiled | RegexOptions.CultureInvariant);

    private static readonly Regex MarkdownHeadingInsideCodeExpression = new(
        @"(?m)^##\s+",
        RegexOptions.Compiled | RegexOptions.CultureInvariant);

    private static readonly Regex FileScopedNamespaceExpression = new(
        @"(?m)^\s*namespace\s+[A-Za-z_][A-Za-z0-9_.]*\s*;",
        RegexOptions.Compiled | RegexOptions.CultureInvariant);

    private static readonly Regex BlockScopedNamespaceExpression = new(
        @"(?m)^\s*namespace\s+[A-Za-z_][A-Za-z0-9_.]*\s*(?:\r?\n\s*)?\{",
        RegexOptions.Compiled | RegexOptions.CultureInvariant);

    public static async Task<int> RunAsync(string[] args)
    {
        if (args.Length == 0 || HasFlag(args, "--help") || HasFlag(args, "-h"))
        {
            PrintUsage();
            return 0;
        }

        try
        {
            if (HasFlag(args, "--validate-results"))
            {
                var validationOptions = ParseValidationOptions(args);
                var report = await ValidateResultWorkspaceAsync(validationOptions);
                PrintValidationReport(report);
                return report.Diagnostics.Count == 0 ? 0 : 1;
            }

            var options = ParseOptions(args);
            var repoId = DeriveRepoId(options.RepoUrl);
            var runId = CreateRunId();
            var workspace = ResolveWorkspacePath(options.OutputRoot, repoId, runId);
            var resultDirectory = Path.Combine(workspace, ResultDirectoryName);
            var tempRoot = Path.Combine(Path.GetTempPath(), ToolName + "-" + Guid.NewGuid().ToString("N", CultureInfo.InvariantCulture));

            Directory.CreateDirectory(workspace);
            Directory.CreateDirectory(resultDirectory);
            Directory.CreateDirectory(tempRoot);
            DeleteLegacyContextArtifacts(workspace);

            WriteRunHeader(options, repoId, runId);

            try
            {
                var repositoryDirectory = Path.Combine(tempRoot, "repo");
                await CloneRepositoryAsync(options.RepoUrl, repositoryDirectory);

                var externalRepositories = await CloneExternalRepositoriesAsync(options, tempRoot);
                var packages = DiscoverPackages(repositoryDirectory);
                Console.WriteLine($"[digest] discovered {packages.Count} package(s)");

                var packageEntries = new List<PackageManifestEntry>(packages.Count);
                foreach (var package in packages)
                {
                    var resultPath = ToRepositoryPath(ResultDirectoryName, package.Name + ".md");
                    var packageArtifacts = await WritePackageWorkspaceAsync(workspace, repositoryDirectory, package, packages, externalRepositories, options.RepoUrl);

                    packageEntries.Add(new PackageManifestEntry(
                        Kind: "package",
                        Name: package.Name,
                        Prompt: packageArtifacts.PromptPath,
                        Evidence: packageArtifacts.Evidence,
                        Result: resultPath,
                        FrontmatterHints: packageArtifacts.FrontmatterHints));
                }

                var overviewPromptPath = ToRepositoryPath(PromptDirectoryName, "overview.prompt.md");
                var overviewFrontmatterHints = await BuildOverviewFrontmatterHintsAsync(repositoryDirectory, repoId, options.RepoUrl, packages);
                await WriteUtf8Async(Path.Combine(workspace, overviewPromptPath), BuildOverviewPrompt(packages, overviewFrontmatterHints));
                await WriteUtf8Async(Path.Combine(workspace, "instructions.md"), BuildInstructions(options.RepoUrl, repoId));
                await WriteManifestAsync(Path.Combine(workspace, "manifest.json"), options, repoId, runId, workspace, packageEntries, overviewPromptPath, overviewFrontmatterHints);

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
        var parser = new OptionReader(args);
        var repoUrl = parser.GetRequired("--repo-url").Trim();
        var outputRoot = Path.GetFullPath(parser.GetRequired("--output-root").Trim());
        var externalRepoUrls = parser.GetMany("--external-repo-url")
            .Select(url => url.Trim())
            .Where(url => !string.IsNullOrWhiteSpace(url))
            .Distinct(StringComparer.OrdinalIgnoreCase)
            .ToList();

        parser.ThrowIfUnknownOptions("--repo-url", "--output-root", "--external-repo-url", "--help", "-h");

        ValidateRepositoryUrl(repoUrl, "--repo-url");
        foreach (var externalRepoUrl in externalRepoUrls)
        {
            ValidateRepositoryUrl(externalRepoUrl, "--external-repo-url");
        }

        var sourceIdentity = NormalizeRepositoryIdentity(repoUrl);
        foreach (var externalIdentity in externalRepoUrls.Select(NormalizeRepositoryIdentity))
        {
            if (externalIdentity.Equals(sourceIdentity))
            {
                throw new InvalidOperationException("--external-repo-url cannot point to the repository currently under digest.");
            }
        }

        return new DigestOptions(repoUrl, outputRoot, externalRepoUrls);
    }

    private static ResultValidationOptions ParseValidationOptions(string[] args)
    {
        var parser = new OptionReader(args);
        var workspace = Path.GetFullPath(parser.GetRequired("--workspace").Trim());
        parser.ThrowIfUnknownOptions("--validate-results", "--workspace", "--help", "-h");
        if (!Directory.Exists(workspace))
        {
            throw new InvalidOperationException($"Workspace does not exist: {workspace}");
        }

        return new ResultValidationOptions(workspace);
    }

    private static bool HasFlag(string[] args, string name) => args.Contains(name, StringComparer.Ordinal);

    private static void ValidateRepositoryUrl(string repoUrl, string optionName)
    {
        if (!Uri.TryCreate(repoUrl, UriKind.Absolute, out var uri))
        {
            throw new InvalidOperationException($"{optionName} must be a fully qualified repository URL.");
        }

        if (uri.Scheme is not ("http" or "https" or "ssh" or "git"))
        {
            throw new InvalidOperationException($"{optionName} must use the http, https, ssh, or git scheme.");
        }

        if (string.IsNullOrWhiteSpace(uri.Host) || string.IsNullOrWhiteSpace(uri.AbsolutePath.Trim('/')))
        {
            throw new InvalidOperationException($"{optionName} must include a host and repository path.");
        }
    }

    private static string DeriveRepoId(string repoUrl)
    {
        var uri = new Uri(repoUrl);
        var lastSegment = uri.AbsolutePath
            .Trim('/')
            .Split('/', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries)
            .LastOrDefault();

        if (string.IsNullOrWhiteSpace(lastSegment))
        {
            throw new InvalidOperationException("Could not derive repo id because --repo-url has no path segment.");
        }

        if (lastSegment.EndsWith(".git", StringComparison.OrdinalIgnoreCase))
        {
            lastSegment = lastSegment[..^4];
        }

        var sanitized = Regex.Replace(lastSegment, "[^A-Za-z0-9._-]", "-", RegexOptions.CultureInvariant).Trim('-', '.', '_');
        if (string.IsNullOrWhiteSpace(sanitized))
        {
            throw new InvalidOperationException("Could not derive a filesystem-safe repo id from --repo-url.");
        }

        return sanitized.ToLowerInvariant();
    }

    private static string CreateRunId() =>
        DateTimeOffset.UtcNow.ToString("yyyyMMdd-HHmmss'Z'", CultureInfo.InvariantCulture);

    private static string ResolveWorkspacePath(string outputRoot, string repoId, string runId) =>
        Path.GetFullPath(Path.Combine(outputRoot, repoId, runId));

    private static void WriteRunHeader(DigestOptions options, string repoId, string runId)
    {
        Console.WriteLine($"[digest] repo-url={options.RepoUrl}");
        Console.WriteLine($"[digest] output-root={options.OutputRoot}");
        Console.WriteLine($"[digest] repo-id={repoId}");
        Console.WriteLine($"[digest] run-id={runId}");
        Console.WriteLine($"[digest] external-repo-count={options.ExternalRepoUrls.Count}");
        Console.WriteLine();
    }

    private static async Task CloneRepositoryAsync(string repoUrl, string cloneDirectory)
    {
        Console.WriteLine("[digest] cloning repository for discovery...");
        await RunProcessAsync("git", ["clone", "--depth", "1", repoUrl, cloneDirectory], Directory.GetCurrentDirectory());
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
        foreach (var repoUrl in options.ExternalRepoUrls)
        {
            var identity = NormalizeRepositoryIdentity(repoUrl);
            if (!seen.Add(identity))
            {
                continue;
            }

            var cloneDirectory = Path.Combine(tempRoot, "external-" + repositories.Count.ToString("D2", CultureInfo.InvariantCulture));
            Console.WriteLine($"[digest] external usage clone {repositories.Count + 1}: {repoUrl}");
            await RunProcessAsync("git", ["clone", "--depth", "1", repoUrl, cloneDirectory], Directory.GetCurrentDirectory());
            repositories.Add(new ExternalRepository(repoUrl, cloneDirectory, identity));
        }

        return repositories;
    }

    private static IReadOnlyList<PackageInfo> DiscoverPackages(string repositoryDirectory)
    {
        var sourceRoot = Path.Combine(repositoryDirectory, SourceDirectoryName);
        if (!Directory.Exists(sourceRoot))
        {
            return [];
        }

        var projectFiles = Directory.EnumerateFiles(sourceRoot, "*.csproj", SearchOption.AllDirectories)
            .OrderBy(path => Path.GetRelativePath(repositoryDirectory, path), StringComparer.OrdinalIgnoreCase)
            .ToList();

        var packages = new List<PackageInfo>();
        foreach (var projectFile in projectFiles)
        {
            var metadata = ReadProjectMetadata(repositoryDirectory, projectFile);
            if (metadata.IsPackable is false)
            {
                continue;
            }

            var name = FirstNonEmpty(metadata.PackageId, metadata.AssemblyName, Path.GetFileNameWithoutExtension(projectFile));
            var sourceDirectory = Path.GetDirectoryName(projectFile)
                ?? throw new InvalidOperationException($"Could not resolve source directory for '{projectFile}'.");

            var sourceFiles = Directory.EnumerateFiles(sourceDirectory, "*.cs", SearchOption.AllDirectories)
                .Where(path => !IsUnderDirectoryName(path, "bin") && !IsUnderDirectoryName(path, "obj"))
                .ToList();

            var testDirectory = FindTestDirectory(repositoryDirectory, projectFile, name);
            packages.Add(new PackageInfo(
                Name: name,
                SourcePath: ToRepositoryPath(Path.GetRelativePath(repositoryDirectory, sourceDirectory)),
                TestPath: testDirectory is null ? null : ToRepositoryPath(Path.GetRelativePath(repositoryDirectory, testDirectory)),
                IsConveniencePackage: sourceFiles.Count == 0,
                BundledPackages: metadata.BundledPackages,
                TargetFrameworkMonikers: metadata.TargetFrameworkMonikers,
                TargetFrameworks: metadata.TargetFrameworks,
                License: metadata.License,
                Title: metadata.Title,
                Description: metadata.Description,
                ProjectUrl: metadata.ProjectUrl,
                RepositoryUrl: metadata.RepositoryUrl));
        }

        return packages;
    }

    private static ProjectMetadata ReadProjectMetadata(string repositoryDirectory, string projectFile)
    {
        var documents = LoadProjectMetadataDocuments(repositoryDirectory, projectFile);
        var projectDocument = XDocument.Load(projectFile, LoadOptions.PreserveWhitespace);
        var packageId = ElementValue(documents, "PackageId");
        var assemblyName = ElementValue(documents, "AssemblyName");
        var isPackable = TryParseBoolean(ProjectElementValue(projectDocument, "IsPackable"));
        var targetFrameworkMonikers = ReadTargetFrameworkMonikers(documents);
        var targetFrameworks = targetFrameworkMonikers.Select(ToFriendlyTargetFramework).ToList();
        var license = FirstNonEmptyOrDefault(ElementValue(documents, "PackageLicenseExpression"), ElementValue(documents, "PackageLicenseFile"));
        var title = ElementValue(documents, "Title");
        var description = ElementValue(documents, "Description");
        var projectUrl = ElementValue(documents, "PackageProjectUrl");
        var repositoryUrl = ElementValue(documents, "RepositoryUrl");
        var bundledPackages = projectDocument.Descendants()
            .Where(element => element.Name.LocalName is "PackageReference" or "ProjectReference")
            .Select(element => element.Attribute("Include")?.Value)
            .Where(value => !string.IsNullOrWhiteSpace(value))
            .Select(value => value!)
            .Distinct(StringComparer.OrdinalIgnoreCase)
            .OrderBy(value => value, StringComparer.OrdinalIgnoreCase)
            .ToList();

        return new ProjectMetadata(
            PackageId: packageId,
            AssemblyName: assemblyName,
            IsPackable: isPackable,
            BundledPackages: bundledPackages,
            TargetFrameworkMonikers: targetFrameworkMonikers,
            TargetFrameworks: targetFrameworks,
            License: license,
            Title: title,
            Description: description,
            ProjectUrl: projectUrl,
            RepositoryUrl: repositoryUrl);
    }

    private static IReadOnlyList<XDocument> LoadProjectMetadataDocuments(string repositoryDirectory, string projectFile)
    {
        var candidates = new[]
        {
            Path.Combine(repositoryDirectory, "Directory.Build.props"),
            Path.Combine(repositoryDirectory, "Directory.Packages.props"),
            projectFile,
            Path.Combine(repositoryDirectory, "Directory.Build.targets")
        };

        return candidates
            .Where(File.Exists)
            .Select(path => XDocument.Load(path, LoadOptions.PreserveWhitespace))
            .ToList();
    }

    private static bool? TryParseBoolean(string value) =>
        bool.TryParse(value, out var parsed) ? parsed : null;

    private static string ElementValue(IReadOnlyList<XDocument> documents, string localName) =>
        documents
            .SelectMany(document => document.Descendants())
            .Where(element => element.Name.LocalName == localName)
            .Select(element => element.Value.Trim())
            .Where(value => !string.IsNullOrWhiteSpace(value))
            .LastOrDefault() ?? string.Empty;

    private static string ProjectElementValue(XDocument document, string localName) =>
        document
            .Descendants()
            .Where(element => element.Name.LocalName == localName)
            .Select(element => element.Value.Trim())
            .Where(value => !string.IsNullOrWhiteSpace(value))
            .LastOrDefault() ?? string.Empty;

    private static IReadOnlyList<string> ReadTargetFrameworkMonikers(IReadOnlyList<XDocument> documents)
    {
        var plural = ElementValue(documents, "TargetFrameworks");
        var singular = ElementValue(documents, "TargetFramework");
        return new[] { plural, singular }
            .SelectMany(value => value.Split(';', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries))
            .Where(value => !string.IsNullOrWhiteSpace(value))
            .Where(value => !value.Contains("$(", StringComparison.Ordinal))
            .Distinct(StringComparer.OrdinalIgnoreCase)
            .OrderBy(value => value, StringComparer.OrdinalIgnoreCase)
            .ToList();
    }

    private static string FirstNonEmpty(params string[] values) =>
        values.First(value => !string.IsNullOrWhiteSpace(value)).Trim();

    private static string FirstNonEmptyOrDefault(params string[] values) =>
        values.FirstOrDefault(value => !string.IsNullOrWhiteSpace(value))?.Trim() ?? string.Empty;

    private static string ToFriendlyTargetFramework(string moniker)
    {
        var normalized = moniker.Trim();
        if (Regex.IsMatch(normalized, @"^net\d+\.\d+$", RegexOptions.CultureInvariant))
        {
            return ".NET " + normalized[3..];
        }

        if (Regex.IsMatch(normalized, @"^netstandard\d+\.\d+$", RegexOptions.CultureInvariant))
        {
            return ".NET Standard " + normalized["netstandard".Length..];
        }

        if (Regex.IsMatch(normalized, @"^netcoreapp\d+\.\d+$", RegexOptions.CultureInvariant))
        {
            return ".NET Core " + normalized["netcoreapp".Length..];
        }

        if (Regex.IsMatch(normalized, @"^net\d+$", RegexOptions.CultureInvariant) && normalized.Length >= 5)
        {
            return ".NET Framework " + normalized[3] + "." + normalized[4..];
        }

        return normalized;
    }

    private static string? FindTestDirectory(string repositoryDirectory, string sourceProjectFile, string packageName)
    {
        var testRoot = Path.Combine(repositoryDirectory, TestDirectoryName);
        if (!Directory.Exists(testRoot))
        {
            return null;
        }

        var normalizedPackageName = NormalizeForMatch(packageName);
        var matches = Directory.EnumerateFiles(testRoot, "*.csproj", SearchOption.AllDirectories)
            .OrderBy(path => path, StringComparer.OrdinalIgnoreCase)
            .Select(testProjectFile => new TestProjectMatch(
                ProjectFile: testProjectFile,
                IsOwnTestProjectName: IsOwnTestProjectName(testProjectFile, normalizedPackageName),
                ReferencesProject: ReferencesProject(testProjectFile, sourceProjectFile)))
            .ToList();

        var ownMatch = matches
            .Where(match => match.IsOwnTestProjectName)
            .OrderByDescending(match => match.ReferencesProject)
            .ThenBy(match => match.ProjectFile, StringComparer.OrdinalIgnoreCase)
            .FirstOrDefault();

        if (ownMatch is not null)
        {
            return Path.GetDirectoryName(ownMatch.ProjectFile);
        }

        var directMatches = matches
            .Where(match => match.ReferencesProject)
            .OrderBy(match => match.ProjectFile, StringComparer.OrdinalIgnoreCase)
            .ToList();

        return directMatches.Count == 1 ? Path.GetDirectoryName(directMatches[0].ProjectFile) : null;
    }

    private static bool IsOwnTestProjectName(string testProjectFile, string normalizedPackageName)
    {
        var normalizedProjectName = NormalizeForMatch(Path.GetFileNameWithoutExtension(testProjectFile));
        return OwnedTestProjectSuffixes
            .Select(NormalizeForMatch)
            .Any(suffix => string.Equals(normalizedProjectName, normalizedPackageName + suffix, StringComparison.OrdinalIgnoreCase));
    }

    private static bool ReferencesProject(string testProjectFile, string sourceProjectFile)
    {
        var testProjectDirectory = Path.GetDirectoryName(testProjectFile)
            ?? throw new InvalidOperationException($"Could not resolve project directory for '{testProjectFile}'.");

        var sourceFullPath = Path.GetFullPath(sourceProjectFile);
        var document = XDocument.Load(testProjectFile, LoadOptions.PreserveWhitespace);
        return document.Descendants()
            .Where(element => element.Name.LocalName == "ProjectReference")
            .Select(element => element.Attribute("Include")?.Value)
            .Where(include => !string.IsNullOrWhiteSpace(include))
            .Select(include => Path.GetFullPath(Path.Combine(testProjectDirectory, include!)))
            .Any(referenced => string.Equals(referenced, sourceFullPath, StringComparison.OrdinalIgnoreCase));
    }

    private static async Task<PackageWorkspaceArtifacts> WritePackageWorkspaceAsync(
        string workspace,
        string repositoryDirectory,
        PackageInfo package,
        IReadOnlyList<PackageInfo> packages,
        IReadOnlyList<ExternalRepository> externalRepositories,
        string repoUrl)
    {
        Console.WriteLine($"[digest] writing evidence for {package.Name}...");

        var evidenceRoot = ToRepositoryPath(EvidenceDirectoryName, package.Name);
        var promptPath = ToRepositoryPath(PromptDirectoryName, package.Name + ".prompt.md");
        var trackedFiles = await GetPackableTrackedFilesAsync(repositoryDirectory);

        var sourceArtifacts = await WriteEvidenceArtifactsAsync(
            workspace,
            evidenceRoot,
            EvidenceDescriptor.Source,
            package.Name,
            trackedFiles.Where(file => IsSourceEvidenceFile(file.RelativePath, package)).ToList());

        var testFiles = string.IsNullOrWhiteSpace(package.TestPath)
            ? []
            : trackedFiles.Where(file => IsTestEvidenceFile(file.RelativePath, package)).ToList();

        var testNote = string.IsNullOrWhiteSpace(package.TestPath)
            ? $"No owned test path was discovered for {package.Name}."
            : testFiles.Count == 0
                ? $"Owned test path {package.TestPath} contained no tracked test source files."
                : null;

        var testArtifacts = await WriteEvidenceArtifactsAsync(
            workspace,
            evidenceRoot,
            EvidenceDescriptor.Tests,
            package.Name,
            testFiles,
            testNote);

        var projectArtifacts = await WriteEvidenceArtifactsAsync(
            workspace,
            evidenceRoot,
            EvidenceDescriptor.Projects,
            package.Name,
            trackedFiles.Where(file => IsProjectEvidenceFile(file.RelativePath, package)).ToList());

        var readmeArtifacts = await WriteEvidenceArtifactsAsync(
            workspace,
            evidenceRoot,
            EvidenceDescriptor.Readmes,
            package.Name,
            trackedFiles.Where(file => IsReadmeEvidenceFile(file.RelativePath, package)).ToList());

        var externalUsageFiles = await FindExternalUsageFilesAsync(repositoryDirectory, package, packages, externalRepositories);
        var externalUsageNote = externalRepositories.Count == 0
            ? "No external usage repositories were provided."
            : externalUsageFiles.Count == 0
                ? $"External usage repositories were cloned, but no reference-plus-code usage matches were found for {package.Name}."
                : null;

        var externalUsageArtifacts = await WriteEvidenceArtifactsAsync(
            workspace,
            evidenceRoot,
            EvidenceDescriptor.ExternalUsage,
            package.Name,
            externalUsageFiles,
            externalUsageNote);

        var apiSummaryPath = ToRepositoryPath(evidenceRoot, "api-summary.md");
        await WriteUtf8Async(Path.Combine(workspace, apiSummaryPath), BuildPublicApiSummary(repositoryDirectory, package));

        var engineeringSignalsPath = ToRepositoryPath(evidenceRoot, "engineering-signals.md");
        await WriteUtf8Async(Path.Combine(workspace, engineeringSignalsPath), BuildEngineeringSignals(repositoryDirectory, package));

        var evidence = new PackageEvidenceArtifacts(
            Source: sourceArtifacts,
            Tests: testArtifacts,
            Projects: projectArtifacts,
            Readmes: readmeArtifacts,
            ExternalUsage: externalUsageArtifacts,
            ApiSummary: apiSummaryPath,
            EngineeringSignals: engineeringSignalsPath);

        var frontmatterHints = await BuildPackageFrontmatterHintsAsync(repositoryDirectory, package, repoUrl, packages);
        await WriteUtf8Async(Path.Combine(workspace, promptPath), BuildPackageDigestPrompt(package, packages, evidence, frontmatterHints));
        return new PackageWorkspaceArtifacts(promptPath, evidence, frontmatterHints);
    }

    private static async Task<EvidenceArtifacts> WriteEvidenceArtifactsAsync(
        string workspace,
        string packageEvidenceRoot,
        EvidenceDescriptor descriptor,
        string packageName,
        IReadOnlyList<PackedFile> files,
        string? note = null)
    {
        var evidencePath = ToRepositoryPath(packageEvidenceRoot, descriptor.FileName);
        var evidenceXml = await BuildEvidenceXmlAsync(descriptor.RootElementName, packageName, files, note);
        await WriteUtf8Async(Path.Combine(workspace, evidencePath), evidenceXml);

        var chunks = Encoding.UTF8.GetByteCount(evidenceXml) > MaxEvidenceChunkBodyBytes
            ? SplitContextIntoChunks(evidenceXml).ToList()
            : [];

        var chunkPaths = new List<string>(chunks.Count);
        var chunkDirectoryPath = ToRepositoryPath(packageEvidenceRoot, descriptor.ChunkDirectoryName);
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
                var chunkPath = ToRepositoryPath(chunkDirectoryPath, chunkNumber.ToString("D4", CultureInfo.InvariantCulture) + ".xml");
                chunkPaths.Add(chunkPath);
                await WriteUtf8Async(Path.Combine(workspace, chunkPath), BuildEvidenceChunkFile(descriptor.FileName, chunkNumber, chunks.Count, chunks[i]));
            }
        }

        var indexPath = ToRepositoryPath(packageEvidenceRoot, descriptor.IndexFileName);
        await WriteUtf8Async(
            Path.Combine(workspace, indexPath),
            BuildEvidenceIndex(descriptor, evidencePath, indexPath, chunkPaths, chunks, evidenceXml));

        return new EvidenceArtifacts(evidencePath, indexPath, chunkPaths, descriptor.Authority);
    }

    private static async Task<string> BuildEvidenceXmlAsync(
        string rootElementName,
        string packageName,
        IReadOnlyList<PackedFile> files,
        string? note)
    {
        var sb = new StringBuilder();
        sb.Append('<').Append(rootElementName)
            .Append(" package=\"").Append(EscapeXmlAttribute(packageName))
            .Append("\" generatedBy=\"").Append(AgentGeneratedBy).AppendLine("\">");

        if (!string.IsNullOrWhiteSpace(note))
        {
            sb.Append("  <note>").Append(EscapeXmlText(note)).AppendLine("</note>");
        }

        foreach (var file in files.OrderBy(file => file.RelativePath, StringComparer.OrdinalIgnoreCase))
        {
            var content = await File.ReadAllTextAsync(file.FullPath, Encoding.UTF8);
            sb.Append("  <file path=\"").Append(EscapeXmlAttribute(file.RelativePath)).AppendLine("\">");
            AppendCData(sb, content);
            sb.AppendLine();
            sb.AppendLine("  </file>");
        }

        sb.Append("</").Append(rootElementName).AppendLine(">");
        return sb.ToString();
    }

    private static string BuildEvidenceChunkFile(string sourceFileName, int chunkNumber, int chunkCount, string chunkBody)
    {
        var sb = new StringBuilder();
        sb.Append("<contextChunk source=\"").Append(EscapeXmlAttribute(sourceFileName))
            .Append("\" chunk=\"").Append(chunkNumber.ToString(CultureInfo.InvariantCulture))
            .Append("\" chunks=\"").Append(chunkCount.ToString(CultureInfo.InvariantCulture))
            .Append("\" generatedBy=\"").Append(AgentGeneratedBy).AppendLine("\">");
        AppendCData(sb, chunkBody);
        sb.AppendLine();
        sb.AppendLine("</contextChunk>");
        return sb.ToString();
    }

    private static string BuildEvidenceIndex(
        EvidenceDescriptor descriptor,
        string evidencePath,
        string indexPath,
        IReadOnlyList<string> chunkPaths,
        IReadOnlyList<string> chunks,
        string evidenceXml)
    {
        var sb = new StringBuilder();
        sb.AppendLine("# Evidence Index");
        sb.AppendLine();
        sb.AppendLine("Evidence file: `" + evidencePath + "`");
        sb.AppendLine("Index path: `" + indexPath + "`");
        sb.AppendLine("Authority: " + descriptor.Authority);
        sb.AppendLine("Chunk count: " + chunkPaths.Count.ToString(CultureInfo.InvariantCulture));
        sb.AppendLine("Evidence bytes: " + Encoding.UTF8.GetByteCount(evidenceXml).ToString(CultureInfo.InvariantCulture));
        sb.AppendLine();
        sb.AppendLine($"This index is not source evidence. Read `{descriptor.FileName}` directly when possible. If the full evidence file is capped, unavailable, or unsafe to read in one pass, read every `{descriptor.ChunkDirectoryName}/*.xml` file in numeric order.");
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

    private static IEnumerable<string> SplitContextIntoChunks(string context)
    {
        var normalized = context.Replace("\r\n", "\n", StringComparison.Ordinal).Replace('\r', '\n');
        var builder = new StringBuilder();
        var currentBytes = 0;

        foreach (var line in normalized.Split('\n'))
        {
            var lineWithNewline = line + Environment.NewLine;
            var lineBytes = Encoding.UTF8.GetByteCount(lineWithNewline);
            if (lineBytes > MaxEvidenceChunkBodyBytes)
            {
                if (builder.Length > 0)
                {
                    yield return builder.ToString();
                    builder.Clear();
                    currentBytes = 0;
                }

                foreach (var part in SplitOversizedLine(lineWithNewline))
                {
                    yield return part;
                }

                continue;
            }

            if (builder.Length > 0 && currentBytes + lineBytes > MaxEvidenceChunkBodyBytes)
            {
                yield return builder.ToString();
                builder.Clear();
                currentBytes = 0;
            }

            builder.Append(lineWithNewline);
            currentBytes += lineBytes;
        }

        if (builder.Length > 0)
        {
            yield return builder.ToString();
        }
    }

    private static IEnumerable<string> SplitOversizedLine(string line)
    {
        var builder = new StringBuilder();
        var currentBytes = 0;
        foreach (var rune in line.EnumerateRunes())
        {
            var text = rune.ToString();
            var bytes = Encoding.UTF8.GetByteCount(text);
            if (builder.Length > 0 && currentBytes + bytes > MaxEvidenceChunkBodyBytes)
            {
                yield return builder.ToString();
                builder.Clear();
                currentBytes = 0;
            }

            builder.Append(text);
            currentBytes += bytes;
        }

        if (builder.Length > 0)
        {
            yield return builder.ToString();
        }
    }

    private static string BuildPublicApiSummary(string repositoryDirectory, PackageInfo package)
    {
        var discoveredApiTypes = DiscoverPublicApiTypes(repositoryDirectory, package);
        var apiTypes = discoveredApiTypes.Take(MaxApiSummaryTypes).ToList();
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
                : string.Join("<br>", apiType.Members.Take(MaxApiSummaryMembersPerType).Select(EscapeMarkdownTableCell));

            sb.AppendLine($"| `{EscapeMarkdownTableCell(apiType.Name)}` | {EscapeMarkdownTableCell(apiType.Kind)} | {EscapeMarkdownTableCell(apiType.BaseTypes)} | {members} | `{EscapeMarkdownTableCell(apiType.SourcePath)}` |");
        }

        if (discoveredApiTypes.Count > apiTypes.Count)
        {
            sb.AppendLine();
            sb.AppendLine($"Only the first {apiTypes.Count} of {discoveredApiTypes.Count} API candidates are shown. Read source.xml or the complete ordered source chunks for the full surface.");
        }

        return sb.ToString();
    }

    private static IReadOnlyList<ApiTypeSummary> DiscoverPublicApiTypes(string repositoryDirectory, PackageInfo package)
    {
        var sourceDirectory = Path.Combine(repositoryDirectory, ToPlatformPath(package.SourcePath));
        if (!Directory.Exists(sourceDirectory))
        {
            return [];
        }

        var sourceFiles = Directory.EnumerateFiles(sourceDirectory, "*.cs", SearchOption.AllDirectories)
            .Where(path => !IsUnderDirectoryName(path, "bin") && !IsUnderDirectoryName(path, "obj"))
            .Where(path => !ShouldSkipLowSignalFile(ToRepositoryPath(Path.GetRelativePath(repositoryDirectory, path))))
            .OrderBy(path => Path.GetRelativePath(repositoryDirectory, path), StringComparer.OrdinalIgnoreCase)
            .ToList();

        var summaries = new List<ApiTypeSummary>();
        foreach (var sourceFile in sourceFiles)
        {
            var text = File.ReadAllText(sourceFile, Encoding.UTF8);
            var relativePath = ToRepositoryPath(Path.GetRelativePath(repositoryDirectory, sourceFile));
            foreach (Match match in PublicTypeExpression.Matches(text))
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
                    ? []
                    : ExtractPublicMemberCandidates(body, GetSimpleTypeName(name)).Take(8).ToArray();

                summaries.Add(new ApiTypeSummary(name, kind, baseTypes, members, relativePath));
            }
        }

        return summaries
            .OrderBy(summary => summary.SourcePath, StringComparer.OrdinalIgnoreCase)
            .ThenBy(summary => summary.Name, StringComparer.OrdinalIgnoreCase)
            .ToList();
    }

    private static string BuildEngineeringSignals(string repositoryDirectory, PackageInfo package)
    {
        var files = EnumerateSignalFiles(repositoryDirectory, package).ToList();
        var exceptionSignals = FindSignals(files, @"(?:throw\s+new|Assert\.Throws(?:Async)?)\s*<?([A-Za-z0-9_.]+Exception)", "exception guard").Take(12).ToList();
        var declarationSignals = FindDeclarationSignals(files.Where(file => !IsTestEvidenceFile(file.RelativePath, package))).Take(16).ToList();
        var lifecycleSignals = FindSignals(files, @"\b([A-Za-z0-9_]*(?:Configure|Callback|Fixture|Factory|Initialize|Dispose|Lifetime|Host|Application)[A-Za-z0-9_]*)\b", "lifecycle or composition name", IsUsefulLifecycleSignal).Take(16).ToList();
        var hostingSignals = FindSignals(files, @"\b(IHostBuilder|HostApplicationBuilder|Host\.CreateApplicationBuilder|WebApplicationBuilder|IApplicationBuilder|WebApplicationFactory|TestServer)\b", "hosting model").Take(12).ToList();
        var testSignals = files
            .Where(file => IsTestEvidenceFile(file.RelativePath, package))
            .Select(file => file.RelativePath)
            .Distinct(StringComparer.OrdinalIgnoreCase)
            .OrderBy(path => path, StringComparer.OrdinalIgnoreCase)
            .Take(12)
            .ToList();

        var sb = new StringBuilder();
        sb.AppendLine("This section is a deterministic signal map. It highlights places where the code may reveal abstractions, extension points, design invariants, lifecycle contracts, package boundaries, or test-backed behavior. Validate every claim against source.xml, tests.xml, projects.xml, or their complete ordered chunks before writing.");
        sb.AppendLine();

        AppendSignalGroup(sb, "Exception guards and validation evidence", exceptionSignals);
        AppendSignalGroup(sb, "Abstraction and extension-point declarations", declarationSignals);
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

    private static IEnumerable<SignalFile> EnumerateSignalFiles(string repositoryDirectory, PackageInfo package)
    {
        var roots = new[] { package.SourcePath, package.TestPath }
            .Where(path => !string.IsNullOrWhiteSpace(path))
            .Select(path => Path.Combine(repositoryDirectory, ToPlatformPath(path!)))
            .Where(Directory.Exists)
            .Distinct(StringComparer.OrdinalIgnoreCase);

        foreach (var root in roots)
        {
            foreach (var file in Directory.EnumerateFiles(root, "*.cs", SearchOption.AllDirectories)
                         .Where(path => !IsUnderDirectoryName(path, "bin") && !IsUnderDirectoryName(path, "obj"))
                         .Where(path => !ShouldSkipLowSignalFile(ToRepositoryPath(Path.GetRelativePath(repositoryDirectory, path))))
                         .OrderBy(path => Path.GetRelativePath(repositoryDirectory, path), StringComparer.OrdinalIgnoreCase))
            {
                yield return new SignalFile(ToRepositoryPath(Path.GetRelativePath(repositoryDirectory, file)), File.ReadAllText(file, Encoding.UTF8));
            }
        }
    }

    private static IEnumerable<EngineeringSignal> FindDeclarationSignals(IEnumerable<SignalFile> files)
    {
        var expression = new Regex(
            @"(?m)^\s*(?:\[[^\]]+\]\s*)*(?:(?:public|internal|protected\s+internal|internal\s+protected|protected|private)\s+)?(?<modifiers>(?:(?:static|sealed|abstract|partial|readonly|unsafe|file)\s+)*)(?<kind>record\s+class|record\s+struct|class|interface|struct|record)\s+(?<name>[A-Za-z_][A-Za-z0-9_]*(?:<[^>{};]+>)?)",
            RegexOptions.Multiline | RegexOptions.CultureInvariant);
        var seen = new HashSet<string>(StringComparer.OrdinalIgnoreCase);

        foreach (var file in files)
        {
            foreach (Match match in expression.Matches(file.Content))
            {
                var modifiers = NormalizeDeclaration(match.Groups["modifiers"].Value);
                var kind = NormalizeDeclaration(match.Groups["kind"].Value);
                var name = NormalizeDeclaration(match.Groups["name"].Value);
                if (!IsUsefulDeclarationSignal(modifiers, kind, name))
                {
                    continue;
                }

                var value = FormatDeclarationSignal(modifiers, kind, name);
                if (seen.Add(value))
                {
                    yield return new EngineeringSignal("abstraction or extension point", value, file.RelativePath);
                }
            }
        }
    }

    private static bool IsUsefulDeclarationSignal(string modifiers, string kind, string name) =>
        kind.Equals("interface", StringComparison.OrdinalIgnoreCase)
        || modifiers.Split(' ', StringSplitOptions.RemoveEmptyEntries).Contains("abstract", StringComparer.OrdinalIgnoreCase)
        || EngineeringRoleSuffixes.Any(suffix => name.EndsWith(suffix, StringComparison.OrdinalIgnoreCase));

    private static string FormatDeclarationSignal(string modifiers, string kind, string name)
    {
        var hasAbstractModifier = modifiers.Split(' ', StringSplitOptions.RemoveEmptyEntries).Contains("abstract", StringComparer.OrdinalIgnoreCase);
        var displayKind = hasAbstractModifier && !kind.StartsWith("abstract ", StringComparison.OrdinalIgnoreCase)
            ? "abstract " + kind
            : kind;
        return displayKind + " " + name;
    }

    private static bool IsUsefulLifecycleSignal(string relativePath, string value)
    {
        if (LowSignalLifecycleValues.Contains(value, StringComparer.OrdinalIgnoreCase))
        {
            return false;
        }

        if (value.Contains("_Should", StringComparison.OrdinalIgnoreCase)
            || value.Contains("_Verify", StringComparison.OrdinalIgnoreCase))
        {
            return false;
        }

        return true;
    }

    private static IEnumerable<EngineeringSignal> FindSignals(IEnumerable<SignalFile> files, string pattern, string kind, Func<string, string, bool>? shouldInclude = null)
    {
        var expression = new Regex(pattern, RegexOptions.Multiline | RegexOptions.CultureInvariant);
        var seen = new HashSet<string>(StringComparer.OrdinalIgnoreCase);

        foreach (var file in files)
        {
            foreach (Match match in expression.Matches(file.Content))
            {
                var value = match.Groups.Count > 1 && match.Groups[1].Success ? match.Groups[1].Value : match.Value;
                value = NormalizeDeclaration(value);
                if (string.IsNullOrWhiteSpace(value))
                {
                    continue;
                }

                if (shouldInclude is not null && !shouldInclude(file.RelativePath, value))
                {
                    continue;
                }

                if (seen.Add(value))
                {
                    yield return new EngineeringSignal(kind, value, file.RelativePath);
                }
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
            switch (text[i])
            {
                case '{':
                    depth++;
                    break;
                case '}':
                    depth--;
                    if (depth == 0)
                    {
                        return text[(openBrace + 1)..i];
                    }
                    break;
            }
        }

        return null;
    }

    private static IEnumerable<string> ExtractPublicMemberCandidates(string body, string simpleTypeName)
    {
        return PublicMemberExpression.Matches(body)
            .Select(match => NormalizeDeclaration(match.Groups["decl"].Value))
            .Where(declaration => !string.IsNullOrWhiteSpace(declaration))
            .Where(declaration => !IsNestedTypeDeclaration(declaration))
            .Distinct(StringComparer.OrdinalIgnoreCase)
            .OrderByDescending(member => member.Contains(simpleTypeName + "(", StringComparison.Ordinal))
            .ThenBy(member => member, StringComparer.OrdinalIgnoreCase);
    }

    private static bool IsNestedTypeDeclaration(string declaration) =>
        declaration.Contains(" class ", StringComparison.Ordinal)
        || declaration.Contains(" interface ", StringComparison.Ordinal)
        || declaration.Contains(" struct ", StringComparison.Ordinal)
        || declaration.Contains(" record ", StringComparison.Ordinal);

    private static async Task<IReadOnlyList<PackedFile>> FindExternalUsageFilesAsync(
        string repositoryDirectory,
        PackageInfo package,
        IReadOnlyList<PackageInfo> packages,
        IReadOnlyList<ExternalRepository> externalRepositories)
    {
        if (externalRepositories.Count == 0)
        {
            return [];
        }

        var searchTerms = BuildExternalUsageSearchTerms(repositoryDirectory, package).ToList();
        if (searchTerms.Count == 0)
        {
            return [];
        }

        var packageReferenceNames = BuildExternalUsageReferencePackageNames(package, packages).ToList();
        var selected = new List<PackedFile>();
        var selectedPaths = new HashSet<string>(StringComparer.OrdinalIgnoreCase);

        foreach (var externalRepository in externalRepositories)
        {
            var trackedFiles = await GetPackableTrackedFilesAsync(externalRepository.CloneDir);
            var filesByPath = trackedFiles.ToDictionary(file => file.RelativePath, StringComparer.OrdinalIgnoreCase);
            var projectMatches = trackedFiles
                .Where(file => file.RelativePath.EndsWith(".csproj", StringComparison.OrdinalIgnoreCase))
                .Select(projectFile => new
                {
                    ProjectFile = projectFile,
                    ReferenceFiles = FindPackageReferenceFilesForProject(projectFile, filesByPath, packageReferenceNames)
                })
                .Where(match => match.ReferenceFiles.Count > 0)
                .OrderBy(match => match.ProjectFile.RelativePath, StringComparer.OrdinalIgnoreCase)
                .ToList();

            foreach (var match in projectMatches)
            {
                var projectDirectory = ToRepositoryPath(Path.GetDirectoryName(match.ProjectFile.RelativePath) ?? string.Empty);
                var usageFiles = trackedFiles
                    .Where(file => file.RelativePath.EndsWith(".cs", StringComparison.OrdinalIgnoreCase))
                    .Where(file => string.IsNullOrWhiteSpace(projectDirectory) || IsUnderPath(file.RelativePath, projectDirectory))
                    .Select(file => new { File = file, Score = GetExternalUsageScore(file.FullPath, searchTerms) })
                    .Where(file => file.Score > 0)
                    .OrderByDescending(file => file.Score)
                    .ThenBy(file => file.File.RelativePath, StringComparer.OrdinalIgnoreCase)
                    .Take(8)
                    .Select(file => file.File)
                    .ToList();

                if (usageFiles.Count == 0)
                {
                    continue;
                }

                AddExternalUsageFile(selected, selectedPaths, externalRepository, match.ProjectFile);
                foreach (var referenceFile in match.ReferenceFiles.Where(file => !string.Equals(file.RelativePath, match.ProjectFile.RelativePath, StringComparison.OrdinalIgnoreCase)))
                {
                    AddExternalUsageFile(selected, selectedPaths, externalRepository, referenceFile);
                }

                foreach (var usageFile in usageFiles)
                {
                    AddExternalUsageFile(selected, selectedPaths, externalRepository, usageFile);
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
        IReadOnlyDictionary<string, PackedFile> filesByPath,
        IReadOnlyList<string> packageNames)
    {
        var referenceFiles = new List<PackedFile>();
        if (FileReferencesAnyPackage(projectFile.FullPath, packageNames))
        {
            referenceFiles.Add(projectFile);
        }

        foreach (var buildFileName in new[] { "Directory.Build.props", "Directory.Build.targets" })
        {
            var buildFile = FindNearestAncestorBuildFile(projectFile.RelativePath, buildFileName, filesByPath);
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
        IReadOnlyDictionary<string, PackedFile> filesByPath)
    {
        var projectDirectory = ToRepositoryPath(Path.GetDirectoryName(projectRelativePath) ?? string.Empty);
        while (true)
        {
            var candidatePath = string.IsNullOrWhiteSpace(projectDirectory)
                ? buildFileName
                : projectDirectory.TrimEnd('/') + "/" + buildFileName;

            if (filesByPath.TryGetValue(candidatePath, out var buildFile))
            {
                return buildFile;
            }

            if (string.IsNullOrWhiteSpace(projectDirectory))
            {
                return null;
            }

            var parent = ToRepositoryPath(Path.GetDirectoryName(projectDirectory) ?? string.Empty);
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

    private static bool ReferenceMatchesPackage(string reference, PackageInfo package) =>
        string.Equals(reference, package.Name, StringComparison.OrdinalIgnoreCase)
        || string.Equals(Path.GetFileNameWithoutExtension(reference), package.Name, StringComparison.OrdinalIgnoreCase);

    private static void AddExternalUsageFile(
        List<PackedFile> selected,
        HashSet<string> selectedPaths,
        ExternalRepository externalRepository,
        PackedFile file)
    {
        var externalPath = ToRepositoryPath("external", externalRepository.Identity.Host, externalRepository.Identity.Path, file.RelativePath);
        if (selectedPaths.Add(externalPath))
        {
            selected.Add(new PackedFile(file.FullPath, externalPath));
        }
    }

    private static IEnumerable<ExternalUsageSearchTerm> BuildExternalUsageSearchTerms(string repositoryDirectory, PackageInfo package)
    {
        var terms = new Dictionary<string, bool>(StringComparer.OrdinalIgnoreCase);
        AddExternalUsageSearchTerm(terms, package.Name, isStrong: true);

        foreach (var apiType in DiscoverPublicApiTypes(repositoryDirectory, package))
        {
            AddExternalUsageSearchTerm(terms, GetSimpleTypeName(apiType.Name), isStrong: false);
        }

        var sourceDirectory = Path.Combine(repositoryDirectory, ToPlatformPath(package.SourcePath));
        if (Directory.Exists(sourceDirectory))
        {
            foreach (var sourceFile in Directory.EnumerateFiles(sourceDirectory, "*.cs", SearchOption.AllDirectories))
            {
                var relativePath = ToRepositoryPath(Path.GetRelativePath(repositoryDirectory, sourceFile));
                if (ShouldSkipLowSignalFile(relativePath))
                {
                    continue;
                }

                var content = File.ReadAllText(sourceFile, Encoding.UTF8);
                foreach (Match match in Regex.Matches(content, @"\bnamespace\s+([A-Za-z_][A-Za-z0-9_.]*)", RegexOptions.CultureInvariant))
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
            if (!content.Contains(term.Value, StringComparison.Ordinal))
            {
                continue;
            }

            score += term.IsStrong ? 4 : 1;
            hasStrongMatch |= term.IsStrong;
        }

        return hasStrongMatch ? score : 0;
    }

    private static bool FileReferencesAnyPackage(string projectFile, IReadOnlyList<string> packageNames)
    {
        try
        {
            var document = XDocument.Load(projectFile, LoadOptions.PreserveWhitespace);
            return document.Descendants()
                .Where(element => string.Equals(element.Name.LocalName, "PackageReference", StringComparison.OrdinalIgnoreCase))
                .Any(element => packageNames.Any(packageName =>
                    string.Equals((string?)element.Attribute("Include"), packageName, StringComparison.OrdinalIgnoreCase)
                    || string.Equals((string?)element.Attribute("Update"), packageName, StringComparison.OrdinalIgnoreCase)));
        }
        catch
        {
            var content = File.ReadAllText(projectFile, Encoding.UTF8);
            return packageNames.Any(packageName => Regex.IsMatch(
                content,
                @"<PackageReference\s+[^>]*(?:Include|Update)\s*=\s*[""']" + Regex.Escape(packageName) + @"[""']",
                RegexOptions.IgnoreCase | RegexOptions.CultureInvariant));
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

        path = Regex.Replace(path, "/+", "/", RegexOptions.CultureInvariant).Trim('/').ToLowerInvariant();
        if (string.IsNullOrWhiteSpace(host) || string.IsNullOrWhiteSpace(path))
        {
            throw new InvalidOperationException($"Could not normalize repository URL '{repoUrl}'.");
        }

        return new RepositoryIdentity(host, path);
    }

    private static async Task<IReadOnlyList<PackedFile>> GetPackableTrackedFilesAsync(string repositoryDirectory)
    {
        return (await GetTrackedFilesAsync(repositoryDirectory))
            .Where(file => !IsUnderSkippedDirectory(file.RelativePath))
            .Where(file => !ShouldSkipLowSignalFile(file.RelativePath))
            .Where(file => IsTextFile(file.FullPath))
            .OrderBy(file => file.RelativePath, StringComparer.OrdinalIgnoreCase)
            .ToList();
    }

    private static async Task<IReadOnlyList<PackedFile>> GetTrackedFilesAsync(string repositoryDirectory)
    {
        var output = await RunProcessCaptureAsync("git", ["ls-files", "-z"], repositoryDirectory);
        return output
            .Split('\0', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries)
            .Select(ToRepositoryPath)
            .Select(relativePath => new PackedFile(ResolveRepositoryPath(repositoryDirectory, relativePath), relativePath))
            .OrderBy(file => file.RelativePath, StringComparer.OrdinalIgnoreCase)
            .ToList();
    }

    private static string ResolveRepositoryPath(string repositoryDirectory, string relativePath)
    {
        var fullPath = Path.GetFullPath(Path.Combine(repositoryDirectory, ToPlatformPath(relativePath)));
        var root = Path.GetFullPath(repositoryDirectory).TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar) + Path.DirectorySeparatorChar;
        if (!fullPath.StartsWith(root, StringComparison.OrdinalIgnoreCase))
        {
            throw new InvalidOperationException($"Git returned a path outside the cloned repository: '{relativePath}'.");
        }

        return fullPath;
    }

    private static bool IsSourceEvidenceFile(string relativePath, PackageInfo package) =>
        IsUnderPath(relativePath, package.SourcePath)
        && relativePath.EndsWith(".cs", StringComparison.OrdinalIgnoreCase)
        && !IsReadmeFile(relativePath)
        && !IsProjectMetadataFile(relativePath);

    private static bool IsTestEvidenceFile(string relativePath, PackageInfo package) =>
        !string.IsNullOrWhiteSpace(package.TestPath)
        && IsUnderPath(relativePath, package.TestPath!)
        && relativePath.EndsWith(".cs", StringComparison.OrdinalIgnoreCase)
        && !IsReadmeFile(relativePath)
        && !IsProjectMetadataFile(relativePath);

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
            || (relativePath.StartsWith(".nuget/", StringComparison.OrdinalIgnoreCase) && string.Equals(fileName, "README.md", StringComparison.OrdinalIgnoreCase))
            || (relativePath.StartsWith("docs/", StringComparison.OrdinalIgnoreCase) && fileName.StartsWith("README", StringComparison.OrdinalIgnoreCase))
            || (IsUnderPath(relativePath, package.SourcePath) && fileName.StartsWith("README", StringComparison.OrdinalIgnoreCase))
            || (!string.IsNullOrWhiteSpace(package.TestPath) && IsUnderPath(relativePath, package.TestPath!) && fileName.StartsWith("README", StringComparison.OrdinalIgnoreCase));
    }

    private static bool IsUnderPath(string relativePath, string root)
    {
        var normalizedRelativePath = ToRepositoryPath(relativePath);
        var normalizedRoot = ToRepositoryPath(root).TrimEnd('/');
        return string.Equals(normalizedRelativePath, normalizedRoot, StringComparison.OrdinalIgnoreCase)
            || normalizedRelativePath.StartsWith(normalizedRoot + "/", StringComparison.OrdinalIgnoreCase);
    }

    private static bool IsReadmeFile(string relativePath) =>
        Path.GetFileName(relativePath).StartsWith("README", StringComparison.OrdinalIgnoreCase);

    private static bool IsProjectMetadataFile(string relativePath) =>
        IsRootProjectMetadataFile(relativePath)
        || Path.GetFileName(relativePath).EndsWith(".csproj", StringComparison.OrdinalIgnoreCase);

    private static bool IsRootProjectMetadataFile(string relativePath)
    {
        var normalized = ToRepositoryPath(relativePath);
        return RootProjectMetadataFileNames.Any(name => string.Equals(normalized, name, StringComparison.OrdinalIgnoreCase));
    }

    private static bool IsUnderSkippedDirectory(string relativePath)
    {
        var segments = ToRepositoryPath(relativePath).Split('/', StringSplitOptions.RemoveEmptyEntries);
        return segments.Any(segment => segment is ".git" or ".svn" or ".hg" or "bin" or "obj" or "node_modules");
    }

    private static bool ShouldSkipLowSignalFile(string relativePath) =>
        string.Equals(Path.GetFileName(relativePath), "GlobalSuppressions.cs", StringComparison.OrdinalIgnoreCase);

    private static bool IsUnderDirectoryName(string path, string directoryName)
    {
        var segments = Path.GetFullPath(path).Split(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar);
        return segments.Any(segment => string.Equals(segment, directoryName, StringComparison.OrdinalIgnoreCase));
    }

    private static bool IsTextFile(string path)
    {
        using var stream = File.OpenRead(path);
        var buffer = new byte[Math.Min(4096, (int)Math.Min(stream.Length, int.MaxValue))];
        var read = stream.Read(buffer, 0, buffer.Length);
        return !buffer.AsSpan(0, read).Contains((byte)0);
    }

    private static IEnumerable<string> ExtractHeadings(string markdown)
    {
        foreach (Match match in Regex.Matches(markdown, @"^##\s+(.+)$", RegexOptions.Multiline | RegexOptions.CultureInvariant))
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
        var normalized = ToRepositoryPath(path).TrimStart('/');
        var fileName = Path.GetFileName(normalized);

        if (normalized.StartsWith("test/", StringComparison.OrdinalIgnoreCase)) return "Test Coverage";
        if (normalized.StartsWith("src/", StringComparison.OrdinalIgnoreCase)) return "Source Code";
        if (normalized.StartsWith(".nuget/", StringComparison.OrdinalIgnoreCase)) return "NuGet Documentation";
        if (normalized.StartsWith("external/", StringComparison.OrdinalIgnoreCase)) return "External Usage";
        if (string.Equals(fileName, "README.md", StringComparison.OrdinalIgnoreCase)) return "Documentation";
        if (IsRootProjectMetadataFile(fileName) || fileName.EndsWith(".csproj", StringComparison.OrdinalIgnoreCase)) return "Project Metadata";
        return "Repository Metadata";
    }

    private static IEnumerable<string> ExtractPackedFilePaths(string context)
    {
        var paths = new SortedSet<string>(StringComparer.OrdinalIgnoreCase);
        foreach (Match match in Regex.Matches(context, @"<file\s+path=""([^""]+)""", RegexOptions.CultureInvariant))
        {
            paths.Add(match.Groups[1].Value);
        }

        return paths;
    }

    private static string NormalizeForMatch(string value) =>
        Regex.Replace(value, "[^A-Za-z0-9]", string.Empty, RegexOptions.CultureInvariant).ToLowerInvariant();

    private static string NormalizeDeclaration(string value) =>
        Regex.Replace(value.ReplaceLineEndings(" "), @"\s+", " ", RegexOptions.CultureInvariant).Trim().TrimEnd('{', ';').Trim();

    private static string GetSimpleTypeName(string name)
    {
        var index = name.IndexOf('<', StringComparison.Ordinal);
        return index >= 0 ? name[..index] : name;
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

    private static async Task RunProcessAsync(string executable, IReadOnlyList<string> arguments, string workingDirectory, TimeSpan timeout = default) =>
        _ = await RunProcessCaptureAsync(executable, arguments, workingDirectory, timeout);

    private static async Task<string> RunProcessCaptureAsync(string executable, IReadOnlyList<string> arguments, string workingDirectory, TimeSpan timeout = default)
    {
        timeout = timeout == default ? DefaultProcessTimeout : timeout;

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

        using var timeoutSource = new CancellationTokenSource(timeout);
        try
        {
            await process.WaitForExitAsync(timeoutSource.Token);
        }
        catch (OperationCanceledException)
        {
            TryKillProcessTree(process);
            throw new TimeoutException($"'{executable}' did not complete within {timeout}.");
        }

        var stdout = await stdoutTask;
        var stderr = await stderrTask;
        if (process.ExitCode == 0)
        {
            return stdout;
        }

        var details = string.Join(Environment.NewLine, new[] { stdout.Trim(), stderr.Trim() }.Where(text => !string.IsNullOrWhiteSpace(text)));
        throw new InvalidOperationException($"'{executable}' failed with exit code {process.ExitCode}.{Environment.NewLine}{details}".Trim());
    }

    private static void TryKillProcessTree(Process process)
    {
        try
        {
            process.Kill(entireProcessTree: true);
        }
        catch
        {
            // Best-effort cleanup. The timeout exception is the actionable failure.
        }
    }

    private static async Task WriteManifestAsync(
        string manifestPath,
        DigestOptions options,
        string repoId,
        string runId,
        string workspace,
        IReadOnlyList<PackageManifestEntry> packages,
        string overviewPromptPath,
        PageFrontmatterHints overviewFrontmatterHints)
    {
        var packageTargets = packages.Select(package => new
        {
            package.Kind,
            package.Name,
            package.Prompt,
            package.Evidence,
            package.Result,
            package.FrontmatterHints
        }).ToList();

        var packagesPhase = new
        {
            name = "packages",
            packages = packageTargets,
            targets = packageTargets
        };

        var overviewTarget = new
        {
            kind = "overview",
            name = "Index",
            prompt = overviewPromptPath,
            sourceResults = packages.Select(package => package.Result).ToList(),
            supplementalEvidence = packages.Select(package => new
            {
                package = package.Name,
                projects = package.Evidence.Projects.Path,
                readmes = package.Evidence.Readmes.Path
            }).ToList(),
            result = "result/Index.md",
            frontmatterHints = overviewFrontmatterHints
        };

        var overviewPhase = new
        {
            name = "overview",
            dependsOn = "packages",
            package = overviewTarget
        };

        var manifest = new
        {
            schemaVersion = 1,
            generatedAt = DateTimeOffset.UtcNow.ToString("O", CultureInfo.InvariantCulture),
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
            overview = overviewTarget
        };

        var json = JsonSerializer.Serialize(manifest, new JsonSerializerOptions
        {
            PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
            WriteIndented = true
        });

        await WriteUtf8Async(manifestPath, json + Environment.NewLine);
    }

    private static async Task WriteUtf8Async(string path, string content)
    {
        Directory.CreateDirectory(Path.GetDirectoryName(path) ?? Directory.GetCurrentDirectory());
        await File.WriteAllTextAsync(path, content, Utf8NoBom);
    }

    private static void DeleteLegacyContextArtifacts(string workspace)
    {
        var workspaceRoot = Path.GetFullPath(workspace).TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar) + Path.DirectorySeparatorChar;

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
            var fullPath = Path.GetFullPath(directory).TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar) + Path.DirectorySeparatorChar;
            if (fullPath.StartsWith(workspaceRoot, StringComparison.OrdinalIgnoreCase))
            {
                Directory.Delete(directory, recursive: true);
            }
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
            // Temporary cleanup failure should not hide the real result.
        }
    }

    private static string ToRepositoryPath(params string[] parts) =>
        string.Join('/', parts.Select(ToRepositoryPath).Where(part => part.Length > 0));

    private static string ToRepositoryPath(string path) =>
        path.Replace('\\', '/').Trim('/');

    private static string ToPlatformPath(string repositoryPath) =>
        ToRepositoryPath(repositoryPath).Replace('/', Path.DirectorySeparatorChar);

    private static string BuildInstructions(string repoUrl, string repoId) =>
        $$"""
        # Digest Writing Instructions

        Repository: {{repoUrl}}
        Repository id: {{repoId}}

        This workspace was generated deterministically by the script. The script does not call an LLM and does not overwrite `result/*.md` files.

        ## Contract

        - Treat `manifest.json` as authoritative for prompt paths, evidence paths, phase order, and result paths.
        - Complete every package page before writing the overview page.
        - For each package, read `prompts/{PackageName}.prompt.md` before reading evidence.
        - Read raw evidence files directly when possible: `source.xml`, `tests.xml`, `projects.xml`, `readmes.xml`, and `external-usage.xml`.
        - If a raw evidence file is capped, truncated, unavailable, or too large to read safely, read its index and then every listed chunk in numeric order.
        - Index files, `api-summary.md`, and `engineering-signals.md` are navigation aids only. Do not use them as standalone evidence.
        - Source evidence wins for API shape and consumer-facing behavior.
        - Test evidence wins for intended usage and behavioral contracts.
        - Project evidence wins for dependencies, target frameworks, packability, and package relationships.
        - README evidence is editorial context only when source or project evidence exists.
        - External usage evidence may guide realistic examples only after validating the API shape against current source evidence.
        - For every C# example, validate API shape before finalizing: map each real package-owned variable or receiver to its static type, then verify every member access, method call, constructor call, override, generic constraint, namespace, and extension method against the declaring package's source evidence.
        - For every C# test example, use the Codebelt.Extensions.Xunit shape: import `Codebelt.Extensions.Xunit` and `Xunit`, never import `Xunit.Abstractions`, inherit the test class from `Test`, wire `ITestOutputHelper output` through `base(output)`, and write useful `TestOutput` context.
        - For convenience, aggregate, metadata-only, or no-assembly package examples, use the referenced package evidence paths in the generated prompt; the aggregate package's own metadata-only evidence is not enough to validate referenced APIs.
        - Every result file starts with YAML frontmatter using the generated prompt's schema and static metadata hints.
        - Replace editorial frontmatter placeholders with grounded page-specific `title`, `description`, and `lede` values before writing.
        - If evidence is missing, stale, contradictory, or unsafe to use completely, stop and report the blocker instead of filling gaps.

        ## Shared Editorial Rules

        {{BuildSharedEditorialRules()}}

        ## Suggested Order

        1. Read `manifest.json`.
        2. Read this file.
        3. For each package target, read its package prompt.
        4. Read source, project, test, external usage, and README evidence in that priority order.
        5. Use `api-summary.md` and `engineering-signals.md` only to decide where to inspect raw evidence more carefully.
        6. Write every `result/{PackageName}.md` file.
        7. Read `prompts/overview.prompt.md` and every completed package result listed by the manifest.
        8. Write `result/Index.md`.
        9. Validate that all manifest result paths exist and begin with complete YAML frontmatter.
        10. Validate every C# example against source evidence and revise any example that uses plausible but undeclared APIs or misses the Codebelt.Extensions.Xunit test shape.
        11. Run `dotnet run --file <skill-root>/scripts/digest.cs -- --validate-results --workspace <workspace>`. Revise any reported result errors from source evidence and rerun until validation passes.

        ## Validation Repair Discipline

        - Treat targeted `rg` searches as triage only. A search hit is not automatically a defect; decide from context and source evidence. For example, `HttpStatusCode.OK` is not the same as a toy literal response body.
        - Create a short repair ledger for each validation diagnostic: result file, exact diagnostic, affected Basic usage block, source evidence needed, and planned edit.
        - Inspect the failing snippet and exact failing line before speculating about framework internals, overload resolution, dependency injection, logger categories, or validator behavior.
        - Allow at most one quick hypothesis pass. If the cause is not confirmed from source, tests, or the executable failure line, replace the example from source-backed evidence instead of continuing an open-ended investigation.
        - Prefer one focused edit per diagnostic, then rerun `--validate-results`. Do not treat unrelated preflight search hits as reasons to rewrite passing examples.

        ## Result Edit Discipline

        - Read the affected `result/*.md` file immediately before editing it.
        - Replace named sections from the `## ` heading through the complete section body, not from inside a paragraph or code block.
        - When replacing a fenced code example, include the opening fence, the whole code block, the closing fence, and any section-specific explanatory prose in the replacement boundary.
        - After every result-file edit, re-read the affected section and verify the heading appears exactly once, code fences are balanced, and no old fragment remains.
        - Rerun `--validate-results` after the final result-file edit. A previous validation pass is stale after any `result/*.md` change.
        """;

    private static string BuildSharedEditorialRules() =>
        """
        You are a senior .NET library documentation editor writing for professional .NET engineers.

        Priorities, in order:
        1. Accuracy.
        2. Evidence-grounded claims.
        3. Clear package responsibility and ecosystem positioning.
        4. Useful, concise documentation copy.
        5. Polished but restrained language.

        Use source files as the authority for public APIs, inheritance, interfaces, constraints, signatures, overloads, virtual or abstract members, lifecycle hooks, and consumer-facing behavior.
        Use tests as the authority for intended usage, behavioral contracts, common setup, and edge cases.
        Use project files as the authority for dependencies, target frameworks, package references, project references, packability, and package relationships.
        Use external usage only for observed consumer scenario shape, naming, setup style, and example selection after the current source confirms the API shape.
        Use README and metadata files only for positioning, vocabulary, and high-level intent.

        Never invent APIs, dependencies, package relationships, scenarios, examples, support statements, performance claims, or architectural claims.
        Treat property access as an API claim, not harmless syntax. A receiver such as a fixture, builder, options object, context, factory result, client, service, or base class exposes only the members declared by its static type or inherited framework type.
        Prefer public types, extension methods, options/configuration types, factories, abstractions, protected hooks, and test-visible usage patterns.
        Ignore implementation details unless they explain a public contract.
        If evidence conflicts, prefer source for API shape, tests for usage, projects for packaging, and current source over external usage.

        Write with authority and precision.
        Be concrete.
        Surface the non-obvious.
        Avoid marketing language and vague adjectives such as "robust", "seamless", "powerful", "easy-to-use", or "comprehensive" unless the evidence supports a specific version of the claim.

        Style rules:
        - Output Markdown only.
        - Include every required heading verbatim.
        - Use short, neutral, Microsoft Learn-style headings.
        - Do not use em dashes in prose.
        - Do not use "Furthermore" or "In conclusion".
        - Do not include analysis notes, confidence scores, citations, XML, JSON, or chat commentary unless explicitly requested by the prompt.
        """;

    private static async Task<PageFrontmatterHints> BuildPackageFrontmatterHintsAsync(string repositoryDirectory, PackageInfo package, string repoUrl, IReadOnlyList<PackageInfo> packages)
    {
        var packageNugetUrl = BuildNugetPackageUrl(package.Name);
        var repositoryUrl = FirstNonEmptyOrDefault(package.RepositoryUrl, repoUrl);
        var documentationProjectUrl = package.IsConveniencePackage
            ? ResolveRepositoryPackageProjectUrl(repositoryDirectory, packages)
            : package.ProjectUrl;
        var documentationPackageName = package.IsConveniencePackage ? null : package.Name;
        var documentationUrl = await ResolveDocumentationUrlAsync(repositoryDirectory, documentationProjectUrl, documentationPackageName);
        var links = BuildImportantLinks(packageNugetUrl, repositoryUrl, documentationUrl).ToList();
        var familyLinks = BuildFamilyLinks(repositoryDirectory, packages).ToList();

        return new PageFrontmatterHints(
            PageKind: "package",
            Title: FirstNonEmptyOrDefault(package.Title, package.Name),
            Description: package.Description,
            Lede: string.Empty,
            PackageId: package.Name,
            PackageCount: 1,
            LibraryCount: package.IsConveniencePackage ? Math.Max(1, package.BundledPackages.Count) : 1,
            TargetFrameworks: package.TargetFrameworks,
            TargetFrameworkMonikers: package.TargetFrameworkMonikers,
            License: package.License,
            Links: links,
            FamilyLinks: familyLinks);
    }

    private static async Task<PageFrontmatterHints> BuildOverviewFrontmatterHintsAsync(string repositoryDirectory, string repoId, string repoUrl, IReadOnlyList<PackageInfo> packages)
    {
        var targetFrameworkMonikers = packages
            .SelectMany(package => package.TargetFrameworkMonikers)
            .Distinct(StringComparer.OrdinalIgnoreCase)
            .OrderBy(value => value, StringComparer.OrdinalIgnoreCase)
            .ToList();
        var targetFrameworks = targetFrameworkMonikers.Select(ToFriendlyTargetFramework).ToList();
        var licenses = packages
            .Select(package => package.License)
            .Where(value => !string.IsNullOrWhiteSpace(value))
            .Distinct(StringComparer.OrdinalIgnoreCase)
            .OrderBy(value => value, StringComparer.OrdinalIgnoreCase)
            .ToList();
        var license = licenses.Count switch
        {
            0 => string.Empty,
            1 => licenses[0],
            _ => "Mixed"
        };
        var nugetUrl = BuildNugetQueryUrl(BuildNugetQuery(repoId, packages));
        var projectUrl = ResolveRepositoryPackageProjectUrl(repositoryDirectory, packages);
        var documentationUrl = await ResolveDocumentationUrlAsync(repositoryDirectory, projectUrl, packageName: null);
        var links = BuildImportantLinks(nugetUrl, repoUrl, documentationUrl).ToList();
        var familyLinks = BuildFamilyLinks(repositoryDirectory, packages).ToList();
        var title = ResolveRepositoryProductTitle(repositoryDirectory);

        return new PageFrontmatterHints(
            PageKind: "index",
            Title: title,
            Description: string.Empty,
            Lede: string.Empty,
            PackageId: null,
            PackageCount: packages.Count,
            LibraryCount: packages.Count,
            TargetFrameworks: targetFrameworks,
            TargetFrameworkMonikers: targetFrameworkMonikers,
            License: license,
            Links: links,
            FamilyLinks: familyLinks);
    }

    private static string ResolveRepositoryProductTitle(string repositoryDirectory)
    {
        var rootProduct = ReadRootProduct(repositoryDirectory);
        if (!string.IsNullOrWhiteSpace(rootProduct))
        {
            return rootProduct;
        }

        var candidates = DiscoverProjectProductCandidates(repositoryDirectory);
        if (candidates.Count == 0)
        {
            throw new InvalidOperationException("Could not resolve repository Product for result/Index.md. Add a literal <Product> value to the root Directory.Build.props file or to the top-level packable .csproj.");
        }

        var highestReferenceCount = candidates.Max(candidate => candidate.ReferenceCount);
        var topCandidates = candidates
            .Where(candidate => candidate.ReferenceCount == highestReferenceCount)
            .ToList();
        var products = topCandidates
            .Select(candidate => candidate.Product)
            .Distinct(StringComparer.OrdinalIgnoreCase)
            .ToList();

        if (products.Count == 1)
        {
            return products[0];
        }

        var projectList = string.Join(", ", topCandidates.Select(candidate => ToRepositoryPath(Path.GetRelativePath(repositoryDirectory, candidate.ProjectFile))));
        throw new InvalidOperationException($"Could not resolve repository Product for result/Index.md because multiple top-level packable projects define different <Product> values: {projectList}. Add a literal <Product> value to the root Directory.Build.props file.");
    }

    private static string ReadRootProduct(string repositoryDirectory)
    {
        var rootProps = Path.Combine(repositoryDirectory, "Directory.Build.props");
        if (!File.Exists(rootProps))
        {
            return string.Empty;
        }

        var document = XDocument.Load(rootProps, LoadOptions.PreserveWhitespace);
        return NormalizeProductValue(ProjectElementValue(document, "Product"), "Directory.Build.props");
    }

    private static IReadOnlyList<ProjectProductCandidate> DiscoverProjectProductCandidates(string repositoryDirectory)
    {
        var sourceRoot = Path.Combine(repositoryDirectory, SourceDirectoryName);
        if (!Directory.Exists(sourceRoot))
        {
            return [];
        }

        var projectFiles = Directory.EnumerateFiles(sourceRoot, "*.csproj", SearchOption.AllDirectories)
            .Select(Path.GetFullPath)
            .OrderBy(path => Path.GetRelativePath(repositoryDirectory, path), StringComparer.OrdinalIgnoreCase)
            .ToList();
        var referenceCounts = projectFiles.ToDictionary(path => path, _ => 0, StringComparer.OrdinalIgnoreCase);

        foreach (var projectFile in projectFiles)
        {
            var projectDirectory = Path.GetDirectoryName(projectFile)
                ?? throw new InvalidOperationException($"Could not resolve project directory for '{projectFile}'.");
            var document = XDocument.Load(projectFile, LoadOptions.PreserveWhitespace);
            foreach (var referencedProject in document.Descendants()
                         .Where(element => element.Name.LocalName == "ProjectReference")
                         .Select(element => element.Attribute("Include")?.Value)
                         .Where(value => !string.IsNullOrWhiteSpace(value))
                         .Select(value => Path.GetFullPath(Path.Combine(projectDirectory, value!))))
            {
                if (referenceCounts.ContainsKey(referencedProject))
                {
                    referenceCounts[referencedProject]++;
                }
            }
        }

        var candidates = new List<ProjectProductCandidate>();
        foreach (var projectFile in projectFiles)
        {
            var document = XDocument.Load(projectFile, LoadOptions.PreserveWhitespace);
            if (TryParseBoolean(ProjectElementValue(document, "IsPackable")) is false)
            {
                continue;
            }

            var product = NormalizeProductValue(ProjectElementValue(document, "Product"), ToRepositoryPath(Path.GetRelativePath(repositoryDirectory, projectFile)));
            if (string.IsNullOrWhiteSpace(product))
            {
                continue;
            }

            candidates.Add(new ProjectProductCandidate(projectFile, product, referenceCounts[projectFile]));
        }

        return candidates
            .OrderByDescending(candidate => candidate.ReferenceCount)
            .ThenBy(candidate => Path.GetRelativePath(repositoryDirectory, candidate.ProjectFile), StringComparer.OrdinalIgnoreCase)
            .ToList();
    }

    private static string NormalizeProductValue(string value, string source)
    {
        var product = value.Trim();
        if (product.Length == 0)
        {
            return string.Empty;
        }

        if (product.Contains("$(", StringComparison.Ordinal))
        {
            throw new InvalidOperationException($"Could not resolve repository Product for result/Index.md because <Product> in {source} contains an unresolved MSBuild property expression: {product}");
        }

        return product;
    }

    private static string BuildNugetPackageUrl(string packageId) =>
        "https://www.nuget.org/packages/" + Uri.EscapeDataString(packageId);

    private static string BuildNugetQueryUrl(string query) =>
        "https://www.nuget.org/packages?q=" + Uri.EscapeDataString(query);

    private static string BuildNugetQuery(string repoId, IReadOnlyList<PackageInfo> packages)
    {
        if (packages.Count == 0)
        {
            return repoId;
        }

        var packageNames = packages.Select(package => package.Name).ToList();
        if (packageNames.Count == 1)
        {
            return packageNames[0];
        }

        var commonSegments = packageNames[0].Split('.');
        foreach (var packageName in packageNames.Skip(1))
        {
            var segments = packageName.Split('.');
            var length = Math.Min(commonSegments.Length, segments.Length);
            var i = 0;
            while (i < length && string.Equals(commonSegments[i], segments[i], StringComparison.OrdinalIgnoreCase))
            {
                i++;
            }

            commonSegments = commonSegments.Take(i).ToArray();
            if (commonSegments.Length == 0)
            {
                break;
            }
        }

        return commonSegments.Length == 0 ? repoId : string.Join('.', commonSegments);
    }

    private static IEnumerable<FrontmatterLink> BuildImportantLinks(string nugetUrl, string repoUrl, string documentationUrl)
    {
        if (!string.IsNullOrWhiteSpace(nugetUrl))
        {
            yield return new FrontmatterLink("NuGet", nugetUrl, "\U0001F4E6");
        }

        var repositoryUrl = NormalizeWebUrl(repoUrl);
        if (!string.IsNullOrWhiteSpace(repositoryUrl))
        {
            yield return new FrontmatterLink("Repository", repositoryUrl, "\U0001F419");

            if (IsGitHubUrl(repositoryUrl))
            {
                yield return new FrontmatterLink("Releases", repositoryUrl + "/releases", "\U0001F3F7\uFE0F");
                yield return new FrontmatterLink("Issues", repositoryUrl + "/issues", "\U0001F41B");
            }
        }

        if (!string.IsNullOrWhiteSpace(documentationUrl))
        {
            yield return new FrontmatterLink("Documentation", documentationUrl, "\U0001F4DA");
        }

    }

    private static IEnumerable<FamilyLink> BuildFamilyLinks(string repositoryDirectory, IReadOnlyList<PackageInfo> packages)
    {
        var packageGlyphs = ReadRelatedPackageGlyphs(repositoryDirectory, packages);
        foreach (var package in packages.OrderBy(package => package.Name, StringComparer.OrdinalIgnoreCase))
        {
            var glyph = packageGlyphs.TryGetValue(package.Name, out var relatedGlyph)
                ? relatedGlyph
                : InferPackageGlyph(package);
            yield return new FamilyLink(
                Label: package.Name,
                PackageId: package.Name,
                Url: package.Name + ".md",
                Glyph: glyph);
        }
    }

    private static IReadOnlyDictionary<string, string> ReadRelatedPackageGlyphs(string repositoryDirectory, IReadOnlyList<PackageInfo> packages)
    {
        var glyphs = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        if (string.IsNullOrWhiteSpace(repositoryDirectory) || !Directory.Exists(repositoryDirectory))
        {
            return glyphs;
        }

        var nugetDirectory = Path.Combine(repositoryDirectory, ".nuget");
        if (!Directory.Exists(nugetDirectory))
        {
            return glyphs;
        }

        var packageNames = packages.Select(package => package.Name).ToList();
        foreach (var readmePath in Directory.EnumerateFiles(nugetDirectory, "README.md", SearchOption.AllDirectories))
        {
            var markdown = File.ReadAllText(readmePath, Utf8NoBom);
            foreach (var line in ExtractMarkdownSection(markdown, "Related Packages"))
            {
                foreach (var packageName in packageNames)
                {
                    if (glyphs.ContainsKey(packageName) || !line.Contains(packageName, StringComparison.OrdinalIgnoreCase))
                    {
                        continue;
                    }

                    var glyph = ExtractLeadingGlyph(line, packageName);
                    if (!string.IsNullOrWhiteSpace(glyph))
                    {
                        glyphs[packageName] = glyph;
                    }
                }
            }
        }

        return glyphs;
    }

    private static IEnumerable<string> ExtractMarkdownSection(string markdown, string heading)
    {
        var inSection = false;
        foreach (var line in markdown.ReplaceLineEndings("\n").Split('\n'))
        {
            var headingMatch = Regex.Match(line, @"^\s{0,3}(?<level>#{1,6})\s+(?<text>.+?)\s*#*\s*$", RegexOptions.CultureInvariant);
            if (headingMatch.Success)
            {
                var text = headingMatch.Groups["text"].Value.Trim();
                if (inSection)
                {
                    yield break;
                }

                inSection = string.Equals(text, heading, StringComparison.OrdinalIgnoreCase);
                continue;
            }

            if (inSection)
            {
                yield return line;
            }
        }
    }

    private static string ExtractLeadingGlyph(string line, string packageName)
    {
        var packageIndex = line.IndexOf(packageName, StringComparison.OrdinalIgnoreCase);
        if (packageIndex <= 0)
        {
            return string.Empty;
        }

        var prefix = line[..packageIndex];
        var matches = Regex.Matches(prefix, @"[\p{So}\p{Sk}][\uFE0F\u20E3]?", RegexOptions.CultureInvariant);
        return matches.Count == 0 ? string.Empty : matches[^1].Value;
    }

    private static string InferPackageGlyph(PackageInfo package)
    {
        var normalized = package.Name.ToLowerInvariant();
        var glyph = "\U0001F4E6";
        if (normalized.Contains("xunit", StringComparison.Ordinal)) glyph = "\U0001F9EA";
        else if (normalized.Contains("test", StringComparison.Ordinal)) glyph = "\U0001F9EA";
        else if (normalized.Contains("kernel", StringComparison.Ordinal)) glyph = "\u2699\uFE0F";
        else if (normalized.Contains("aspnet", StringComparison.Ordinal) || normalized.Contains("web", StringComparison.Ordinal)) glyph = "\U0001F310";
        else if (normalized.Contains("hosting", StringComparison.Ordinal)) glyph = "\U0001F3D7\uFE0F";
        else if (normalized.Contains("security", StringComparison.Ordinal) || normalized.Contains("crypt", StringComparison.Ordinal)) glyph = "\U0001F510";
        else if (normalized.Contains("data", StringComparison.Ordinal) || normalized.Contains("sql", StringComparison.Ordinal)) glyph = "\U0001F5C4\uFE0F";
        else if (normalized.Contains("cache", StringComparison.Ordinal)) glyph = "\U0001F4BE";
        else if (normalized.Contains("diagnostic", StringComparison.Ordinal) || normalized.Contains("logging", StringComparison.Ordinal)) glyph = "\U0001FA7A";
        else if (normalized.Contains("json", StringComparison.Ordinal) || normalized.Contains("text", StringComparison.Ordinal)) glyph = "\U0001F4DD";
        else if (normalized.EndsWith(".app", StringComparison.Ordinal)) glyph = "\U0001F9E9";
        return package.IsConveniencePackage ? "\U0001F3ED" : glyph;
    }

    private static string ResolveRepositoryPackageProjectUrl(string repositoryDirectory, IReadOnlyList<PackageInfo> packages)
    {
        var rootProps = Path.Combine(repositoryDirectory, "Directory.Build.props");
        if (File.Exists(rootProps))
        {
            var document = XDocument.Load(rootProps, LoadOptions.PreserveWhitespace);
            var rootProjectUrl = ProjectElementValue(document, "PackageProjectUrl");
            if (!string.IsNullOrWhiteSpace(rootProjectUrl))
            {
                return rootProjectUrl;
            }
        }

        var projectUrls = packages
            .Select(package => package.ProjectUrl)
            .Where(value => !string.IsNullOrWhiteSpace(value))
            .Distinct(StringComparer.OrdinalIgnoreCase)
            .ToList();

        return projectUrls.Count == 1 ? projectUrls[0] : string.Empty;
    }

    private static async Task<string> ResolveDocumentationUrlAsync(string repositoryDirectory, string projectUrl, string? packageName)
    {
        var errors = new List<string>();

        foreach (var candidate in BuildDocumentationCandidates(repositoryDirectory, projectUrl, packageName, includeReadmeFallbacks: false))
        {
            if (await IsHttpOkAsync(candidate))
            {
                return candidate;
            }

            errors.Add(candidate);
        }

        foreach (var candidate in BuildDocumentationCandidates(repositoryDirectory, projectUrl, packageName, includeReadmeFallbacks: true))
        {
            if (errors.Contains(candidate, StringComparer.OrdinalIgnoreCase))
            {
                continue;
            }

            if (await IsHttpOkAsync(candidate))
            {
                return candidate;
            }

            errors.Add(candidate);
        }

        var target = string.IsNullOrWhiteSpace(packageName) ? "result/Index.md" : packageName;
        var attempted = errors.Count == 0 ? "No documentation URL candidates could be derived." : "Attempted: " + string.Join(", ", errors);
        throw new InvalidOperationException($"Could not resolve a validated documentation URL for {target}. Documentation links must return HTTP 200 OK. {attempted}");
    }

    private static IEnumerable<string> BuildDocumentationCandidates(string repositoryDirectory, string projectUrl, string? packageName, bool includeReadmeFallbacks)
    {
        if (includeReadmeFallbacks && !string.IsNullOrWhiteSpace(packageName))
        {
            foreach (var readmeUrl in ReadDocumentationUrlsFromReadmes(repositoryDirectory, packageName)
                         .Where(url => TryCreateDocumentationUri(url, out _))
                         .Select(NormalizeWebUrl)
                         .Where(url => url.Length > 0)
                         .Distinct(StringComparer.OrdinalIgnoreCase))
            {
                yield return readmeUrl;
            }
        }

        var roots = new List<string>();
        if (!includeReadmeFallbacks)
        {
            roots.AddRange(ExtractDocumentationRootCandidates([projectUrl]));
        }
        else
        {
            roots.AddRange(ExtractDocumentationRootCandidates(ReadDocumentationUrlsFromReadmes(repositoryDirectory, packageName)));
        }

        foreach (var root in roots.Distinct(StringComparer.OrdinalIgnoreCase))
        {
            if (string.IsNullOrWhiteSpace(packageName))
            {
                yield return root;
                continue;
            }

            if (!includeReadmeFallbacks && TryNormalizePackageSpecificDocumentationUrl(projectUrl, packageName, out var packageSpecificUrl))
            {
                yield return packageSpecificUrl;
            }

            var docfxApiPathCandidates = BuildDocfxApiPathCandidates(repositoryDirectory, packageName);
            if (docfxApiPathCandidates.Count == 0)
            {
                if (includeReadmeFallbacks)
                {
                    yield return root;
                }

                continue;
            }

            foreach (var relativePath in docfxApiPathCandidates)
            {
                yield return CombineUrl(root, relativePath);
            }
        }
    }

    private static IReadOnlyList<string> ExtractDocumentationRootCandidates(IEnumerable<string> urls)
    {
        var roots = new List<string>();
        foreach (var url in urls)
        {
            if (!TryCreateDocumentationUri(url, out var uri))
            {
                continue;
            }

            roots.Add(uri.GetLeftPart(UriPartial.Authority).TrimEnd('/'));
        }

        return roots
            .Distinct(StringComparer.OrdinalIgnoreCase)
            .ToList();
    }

    private static bool TryNormalizePackageSpecificDocumentationUrl(string url, string packageName, out string normalized)
    {
        normalized = string.Empty;
        if (!TryCreateDocumentationUri(url, out var uri))
        {
            return false;
        }

        var path = uri.AbsolutePath.Trim('/');
        if (!path.EndsWith(".html", StringComparison.OrdinalIgnoreCase) && !path.Contains(packageName, StringComparison.OrdinalIgnoreCase))
        {
            return false;
        }

        normalized = NormalizeWebUrl(url);
        return normalized.Length > 0;
    }

    private static bool TryCreateDocumentationUri(string url, out Uri uri)
    {
        uri = null!;
        if (!Uri.TryCreate(url, UriKind.Absolute, out var parsed) || parsed.Scheme is not ("http" or "https"))
        {
            return false;
        }

        var hostParts = parsed.Host.Split('.', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries);
        if (hostParts.Length < 3)
        {
            return false;
        }

        uri = parsed;
        return true;
    }

    private static IEnumerable<string> ReadDocumentationUrlsFromReadmes(string repositoryDirectory, string? packageName)
    {
        foreach (var readmePath in EnumerateDocumentationReadmes(repositoryDirectory, packageName))
        {
            var markdown = File.ReadAllText(readmePath, Utf8NoBom);
            foreach (var line in ExtractMarkdownSection(markdown, "Documentation"))
            {
                foreach (Match match in Regex.Matches(line, @"https?://[^\s\)>'""]+", RegexOptions.CultureInvariant | RegexOptions.IgnoreCase))
                {
                    yield return match.Value.TrimEnd('.', ',', ';', ':');
                }
            }

            if (!string.IsNullOrWhiteSpace(packageName) && readmePath.Contains(packageName, StringComparison.OrdinalIgnoreCase))
            {
                foreach (var line in ExtractDocumentationBlockLines(markdown))
                {
                    foreach (Match match in Regex.Matches(line, @"https?://[^\s\)>'""]+", RegexOptions.CultureInvariant | RegexOptions.IgnoreCase))
                    {
                        yield return match.Value.TrimEnd('.', ',', ';', ':');
                    }
                }
            }
        }
    }

    private static IEnumerable<string> ExtractDocumentationBlockLines(string markdown)
    {
        var inDocumentationBlock = false;
        foreach (var line in markdown.Split(["\r\n", "\n"], StringSplitOptions.None))
        {
            if (Regex.IsMatch(line, @"\bdocumentation\b", RegexOptions.CultureInvariant | RegexOptions.IgnoreCase))
            {
                inDocumentationBlock = true;
                yield return line;
                continue;
            }

            if (!inDocumentationBlock)
            {
                continue;
            }

            if (line.StartsWith("#", StringComparison.Ordinal))
            {
                inDocumentationBlock = false;
                continue;
            }

            yield return line;
        }
    }

    private static IEnumerable<string> EnumerateDocumentationReadmes(string repositoryDirectory, string? packageName)
    {
        var nugetDirectory = Path.Combine(repositoryDirectory, ".nuget");
        var readmes = Directory.Exists(nugetDirectory)
            ? Directory.EnumerateFiles(nugetDirectory, "README.md", SearchOption.AllDirectories)
                .OrderBy(path => Path.GetRelativePath(nugetDirectory, path), StringComparer.OrdinalIgnoreCase)
                .ToList()
            : [];

        if (!string.IsNullOrWhiteSpace(packageName))
        {
            foreach (var readme in readmes.Where(path => path.Contains(packageName, StringComparison.OrdinalIgnoreCase)))
            {
                yield return readme;
            }
        }

        var rootReadme = Path.Combine(repositoryDirectory, "README.md");
        if (File.Exists(rootReadme))
        {
            yield return rootReadme;
        }

        foreach (var readme in readmes)
        {
            yield return readme;
        }
    }

    private static IReadOnlyList<string> BuildDocfxApiPathCandidates(string repositoryDirectory, string packageName)
    {
        var docfxDirectory = Path.Combine(repositoryDirectory, ".docfx");
        if (!Directory.Exists(docfxDirectory))
        {
            return [];
        }

        var paths = new List<string>();
        var packageSeenInDocfx = false;
        foreach (var file in Directory.EnumerateFiles(docfxDirectory, "docfx.json", SearchOption.AllDirectories)
                     .OrderBy(path => Path.GetRelativePath(docfxDirectory, path), StringComparer.OrdinalIgnoreCase))
        {
            var text = File.ReadAllText(file, Utf8NoBom);
            var destPaths = ExtractDocfxDestPaths(text, packageName);
            if (destPaths.Count == 0 && !text.Contains(packageName, StringComparison.OrdinalIgnoreCase))
            {
                continue;
            }

            packageSeenInDocfx = true;
            foreach (var destPath in destPaths)
            {
                paths.Add(ToRepositoryPath(destPath, packageName + ".html"));
            }

            foreach (Match match in Regex.Matches(text, @"(?<path>[A-Za-z0-9_.\-/]*" + Regex.Escape(packageName) + @"[A-Za-z0-9_.\-/]*\.html)", RegexOptions.CultureInvariant | RegexOptions.IgnoreCase))
            {
                var path = ToRepositoryPath(match.Groups["path"].Value);
                if (path.Length > 0 && !path.StartsWith("http", StringComparison.OrdinalIgnoreCase))
                {
                    paths.Add(path);
                }
            }
        }

        if (packageSeenInDocfx)
        {
            paths.Add(ToRepositoryPath("api", packageName + ".html"));
        }

        return paths
            .Distinct(StringComparer.OrdinalIgnoreCase)
            .ToList();
    }

    private static IReadOnlyList<string> ExtractDocfxDestPaths(string text, string packageName)
    {
        try
        {
            using var document = JsonDocument.Parse(text);
            if (!document.RootElement.TryGetProperty("metadata", out var metadata) || metadata.ValueKind != JsonValueKind.Array)
            {
                return [];
            }

            var destPaths = new List<string>();
            foreach (var entry in metadata.EnumerateArray())
            {
                if (!entry.TryGetProperty("dest", out var destElement) || destElement.ValueKind != JsonValueKind.String)
                {
                    continue;
                }

                if (!entry.TryGetProperty("src", out var sourceElement) || sourceElement.ValueKind != JsonValueKind.Array)
                {
                    continue;
                }

                if (!DocfxMetadataContainsPackage(sourceElement, packageName))
                {
                    continue;
                }

                var destPath = ToRepositoryPath(destElement.GetString() ?? string.Empty);
                if (destPath.Length > 0)
                {
                    destPaths.Add(destPath);
                }
            }

            return destPaths
                .Distinct(StringComparer.OrdinalIgnoreCase)
                .ToList();
        }
        catch (JsonException)
        {
            return [];
        }
    }

    private static bool DocfxMetadataContainsPackage(JsonElement sourceElement, string packageName)
    {
        foreach (var sourceEntry in sourceElement.EnumerateArray())
        {
            if (!sourceEntry.TryGetProperty("files", out var filesElement) || filesElement.ValueKind != JsonValueKind.Array)
            {
                continue;
            }

            foreach (var fileElement in filesElement.EnumerateArray())
            {
                if (fileElement.ValueKind != JsonValueKind.String)
                {
                    continue;
                }

                var pattern = fileElement.GetString();
                if (!string.IsNullOrWhiteSpace(pattern) && pattern.Contains(packageName, StringComparison.OrdinalIgnoreCase))
                {
                    return true;
                }
            }
        }

        return false;
    }

    private static string CombineUrl(string root, string relativePath) =>
        root.TrimEnd('/') + "/" + ToRepositoryPath(relativePath);

    private static async Task<bool> IsHttpOkAsync(string url)
    {
        try
        {
            using var headRequest = new HttpRequestMessage(HttpMethod.Head, url);
            using var headResponse = await HttpClient.SendAsync(headRequest, HttpCompletionOption.ResponseHeadersRead);
            if (headResponse.StatusCode == HttpStatusCode.OK)
            {
                return true;
            }

            if (headResponse.StatusCode is not HttpStatusCode.MethodNotAllowed and not HttpStatusCode.Forbidden and not HttpStatusCode.NotFound)
            {
                return false;
            }
        }
        catch (HttpRequestException)
        {
            return false;
        }
        catch (TaskCanceledException)
        {
            return false;
        }

        try
        {
            using var getRequest = new HttpRequestMessage(HttpMethod.Get, url);
            using var getResponse = await HttpClient.SendAsync(getRequest, HttpCompletionOption.ResponseHeadersRead);
            return getResponse.StatusCode == HttpStatusCode.OK;
        }
        catch (HttpRequestException)
        {
            return false;
        }
        catch (TaskCanceledException)
        {
            return false;
        }
    }

    private static string NormalizeWebUrl(string url)
    {
        if (!Uri.TryCreate(url, UriKind.Absolute, out var uri) || (uri.Scheme is not "http" and not "https"))
        {
            return string.Empty;
        }

        var builder = new UriBuilder(uri)
        {
            Fragment = string.Empty,
            Query = string.Empty
        };
        var normalized = builder.Uri.GetLeftPart(UriPartial.Path).TrimEnd('/');
        return normalized.EndsWith(".git", StringComparison.OrdinalIgnoreCase)
            ? normalized[..^4]
            : normalized;
    }

    private static bool IsGitHubUrl(string url) =>
        Uri.TryCreate(url, UriKind.Absolute, out var uri)
        && string.Equals(uri.Host, "github.com", StringComparison.OrdinalIgnoreCase);

    private static string BuildFrontmatterContract(PageFrontmatterHints hints)
    {
        var builder = new StringBuilder();
        builder.AppendLine("## YAML frontmatter");
        builder.AppendLine();
        builder.AppendLine("Start the file with YAML frontmatter before the first Markdown heading.");
        builder.AppendLine("Use the generated static values below unless the raw evidence proves they are wrong.");
        if (string.Equals(hints.PageKind, "index", StringComparison.OrdinalIgnoreCase))
        {
            builder.AppendLine("Preserve the generated `title` because it comes from repository-owned `<Product>` metadata.");
            builder.AppendLine("Replace empty or editorial values for `description` and `lede` with grounded page-specific prose.");
        }
        else
        {
            builder.AppendLine("Replace empty or editorial values for `title`, `description`, and `lede` with grounded page-specific prose.");
        }
        builder.AppendLine("Keep link glyphs paired with their context.");
        builder.AppendLine("Keep every `familyLinks.url` value exactly as generated with the `.md` suffix so website importers recognize it as an internal Markdown link.");
        builder.AppendLine();
        builder.AppendLine("```yaml");
        builder.AppendLine("---");
        AppendYamlScalar(builder, "title", hints.Title);
        AppendYamlScalar(builder, "description", string.IsNullOrWhiteSpace(hints.Description) ? "Write a source-grounded one-sentence description." : hints.Description);
        AppendYamlScalar(builder, "lede", string.IsNullOrWhiteSpace(hints.Lede) ? "Write a short lede for listing cards and previews." : hints.Lede);
        AppendYamlScalar(builder, "pageKind", hints.PageKind);
        if (!string.IsNullOrWhiteSpace(hints.PackageId))
        {
            AppendYamlScalar(builder, "packageId", hints.PackageId);
        }

        builder.AppendLine(FormattableString.Invariant($"packageCount: {hints.PackageCount}"));
        builder.AppendLine(FormattableString.Invariant($"libraryCount: {hints.LibraryCount}"));
        AppendYamlList(builder, "targetFrameworks", hints.TargetFrameworks);
        AppendYamlList(builder, "targetFrameworkMonikers", hints.TargetFrameworkMonikers);
        AppendYamlScalar(builder, "license", hints.License);
        AppendYamlLinks(builder, hints.Links);
        AppendYamlFamilyLinks(builder, hints.FamilyLinks);
        builder.AppendLine("---");
        builder.AppendLine("```");
        builder.AppendLine();
        builder.AppendLine("Do not leave placeholder wording such as `Write a source-grounded` or `Write a short lede` in the final frontmatter.");
        return builder.ToString();
    }

    private static void AppendYamlScalar(StringBuilder builder, string key, string value) =>
        builder.AppendLine($"{key}: {ToYamlSingleQuoted(value)}");

    private static void AppendYamlList(StringBuilder builder, string key, IReadOnlyList<string> values)
    {
        if (values.Count == 0)
        {
            builder.AppendLine($"{key}: []");
            return;
        }

        builder.AppendLine(key + ":");
        foreach (var value in values)
        {
            builder.AppendLine("  - " + ToYamlSingleQuoted(value));
        }
    }

    private static void AppendYamlLinks(StringBuilder builder, IReadOnlyList<FrontmatterLink> links)
    {
        if (links.Count == 0)
        {
            builder.AppendLine("links: []");
            return;
        }

        builder.AppendLine("links:");
        foreach (var link in links)
        {
            builder.AppendLine("  - label: " + ToYamlSingleQuoted(link.Label));
            builder.AppendLine("    url: " + ToYamlSingleQuoted(link.Url));
            builder.AppendLine("    glyph: " + ToYamlSingleQuoted(link.Glyph));
        }
    }

    private static void AppendYamlFamilyLinks(StringBuilder builder, IReadOnlyList<FamilyLink> links)
    {
        if (links.Count == 0)
        {
            builder.AppendLine("familyLinks: []");
            return;
        }

        builder.AppendLine("familyLinks:");
        foreach (var link in links)
        {
            builder.AppendLine("  - label: " + ToYamlSingleQuoted(link.Label));
            builder.AppendLine("    packageId: " + ToYamlSingleQuoted(link.PackageId));
            builder.AppendLine("    url: " + ToYamlSingleQuoted(link.Url));
            builder.AppendLine("    glyph: " + ToYamlSingleQuoted(link.Glyph));
        }
    }

    private static string ToYamlSingleQuoted(string value) =>
        "'" + value.Replace("'", "''", StringComparison.Ordinal) + "'";

    private static string BuildReferencedPackageEvidenceMap(PackageInfo package, IReadOnlyList<PackageInfo> packages)
    {
        var referencedPackages = package.BundledPackages
            .Select(reference => packages.FirstOrDefault(candidate => !string.Equals(candidate.Name, package.Name, StringComparison.OrdinalIgnoreCase)
                && ReferenceMatchesPackage(reference, candidate)))
            .OfType<PackageInfo>()
            .DistinctBy(candidate => candidate.Name, StringComparer.OrdinalIgnoreCase)
            .OrderBy(candidate => candidate.Name, StringComparer.OrdinalIgnoreCase)
            .ToList();

        if (referencedPackages.Count == 0)
        {
            return "- No repository-local referenced package evidence was discovered.";
        }

        return string.Join(Environment.NewLine, referencedPackages.Select(referencedPackage =>
            $"- `{referencedPackage.Name}`: source `{ToRepositoryPath(EvidenceDirectoryName, referencedPackage.Name, "source.xml")}`, tests `{ToRepositoryPath(EvidenceDirectoryName, referencedPackage.Name, "tests.xml")}`, API summary `{ToRepositoryPath(EvidenceDirectoryName, referencedPackage.Name, "api-summary.md")}`"));
    }

    private static string BuildPackageDigestPrompt(PackageInfo package, IReadOnlyList<PackageInfo> packages, PackageEvidenceArtifacts evidence, PageFrontmatterHints frontmatterHints) =>
        $$"""
        Write the documentation page for `{{package.Name}}`.

        Output file: `result/{{package.Name}}.md`

        ## Evidence map

        - Source: `{{evidence.Source.Path}}` with index `{{evidence.Source.Index}}`
        - Tests: `{{evidence.Tests.Path}}` with index `{{evidence.Tests.Index}}`
        - Projects: `{{evidence.Projects.Path}}` with index `{{evidence.Projects.Index}}`
        - README: `{{evidence.Readmes.Path}}` with index `{{evidence.Readmes.Index}}`
        - External usage: `{{evidence.ExternalUsage.Path}}` with index `{{evidence.ExternalUsage.Index}}`
        - API summary: `{{evidence.ApiSummary}}`
        - Engineering signals: `{{evidence.EngineeringSignals}}`

        Referenced package evidence, for convenience, aggregate, metadata-only, or no-assembly package examples:
        {{BuildReferencedPackageEvidenceMap(package, packages)}}

        ## Package metadata

        - Source path: `{{package.SourcePath}}`
        - Test path: `{{package.TestPath ?? "(not discovered)"}}`
        - Metadata-only package: `{{package.IsConveniencePackage}}`
        - Referenced packages: {{(package.BundledPackages.Count == 0 ? "(none declared)" : string.Join(", ", package.BundledPackages))}}
        - Target framework monikers: {{(package.TargetFrameworkMonikers.Count == 0 ? "(not declared in project metadata)" : string.Join(", ", package.TargetFrameworkMonikers))}}
        - License: {{(string.IsNullOrWhiteSpace(package.License) ? "(not declared in project metadata)" : package.License)}}

        {{BuildFrontmatterContract(frontmatterHints)}}

        {{BuildSharedEditorialRules()}}

        ## Grounding contract for this page

        Use only the supplied evidence set.
        Read raw evidence directly when possible. If a raw evidence file is capped or unsafe to read completely, read every chunk in numeric order.
        Validate `api-summary.md` and `engineering-signals.md` against raw evidence before using their hints.
        Treat source as authoritative for API shape. Treat tests as authoritative for usage. Treat projects as authoritative for package relationships. Treat README as editorial context.
        Use external usage only when it references this package or a transitive package discovered by the runner and current source confirms the API shape.
        If source evidence is unclear and README is the only source for a claim, either write conservatively or omit the claim.
        For examples that demonstrate a referenced package, read that referenced package's source evidence or complete ordered source chunks before writing the example.
        Verify every property access, method call, constructor call, override, generic constraint, namespace, and extension method in each example against the package that declares the API.
        Before finalizing each C# example, internally build an API-shape ledger:
        - receiver or constructed type
        - static type declared or implied by the snippet
        - member, constructor, override, namespace, or extension method used
        - source evidence file or chunk that declares it
        Revise the example until every ledger entry is verified.

        ## Package-local API preference

        Prioritize APIs declared by this package over inherited, referenced, or lower-level APIs.
        If this package extends another package, demonstrate what this package adds.
        Include public base classes, abstract classes, virtual hooks, and protected members when they are the intended extension model.
        Lower-level APIs may appear as setup only when they clarify the current package API.
        For convenience, aggregate, metadata-only, or no-assembly packages, make ownership explicit: the package provides a single reference; APIs come from referenced packages.

        ## Before writing

        Internally identify:
        - the package's specific responsibility
        - the primary developer scenario
        - the 3-9 package-owned public APIs that matter most
        - the representative usage pattern from source, tests, and external usage
        - relevant base classes, hooks, lifecycle contracts, guards, and package boundaries
        - what the package deliberately does not solve
        - any confidence risks caused by missing or weak evidence

        Write exactly these sections.

        ## Overview

        Write 1-2 concise paragraphs.
        Start with the consumer-facing responsibility.
        If this package extends another package in the repository, name that package.
        Do not mention target frameworks, dependency lists, repository metadata, or package references here.
        Do not use generic phrases such as "provides utilities" unless that is the most accurate description.

        ## Key APIs

        List the 3-9 most important consumer-facing APIs.
        Write one short paragraph per API.
        Start each paragraph with the API name in code formatting, then continue as a natural sentence.
        Do not use definition-list or glossary-style separators such as `` `ApiName` - Description.``, `` `ApiName`: Description.``, or `` `ApiName` -- Description.`` unless the entry is intentionally terse and the generated evidence leaves no useful prose to write.

        Rules:
        - Mention only APIs visible in source evidence.
        - Prefer APIs declared by the current package.
        - Include APIs consumers inherit from, instantiate, configure, call, or implement.
        - For base classes, mention the required override, protected hook, lifecycle method, or directly exposed member that makes the base class useful.
        - Include generic constraints or required callbacks when they are important to correct usage.
        - Do not include incidental helpers, test-only types, or implementation details.
        - If fewer than 3 important APIs exist, list fewer.
        - If this package exposes no additional public APIs, write one sentence saying so and identify where the APIs come from.

        ## Basic usage

        Determine whether this is a normal code package or a metadata-only, aggregate, convenience, or no-assembly package.

        For a normal code package, write exactly one complete C# example from a consumer's point of view.
        The example must:
        - include explicit `using` statements
        - include `using Codebelt.Extensions.Xunit;` and `using Xunit;`
        - not include `using Xunit.Abstractions;`
        - use a file-scoped consumer namespace such as `namespace MyProject.Tests;`
        - compile as a complete Codebelt-style xUnit snippet with a namespace, a public test class that inherits from `Test` or a source-backed Codebelt test base class that the evidence shows derives from `Test`, a constructor that accepts `ITestOutputHelper output` and passes it to the base constructor, and exactly one `[Fact]` or `[Theory]` method unless tests are clearly irrelevant for this package type
        - include at least one assertion or observable result
        - use `TestOutput.Write`, `TestOutput.WriteLine`, or `TestOutput.WriteLines` to emit concise, human-friendly information about the scenario or observable result
        - demonstrate the current package's central API, normally one declared by this package
        - show a realistic consumer task where the package API changes how the code is written, not just a smoke test that calls one method with a literal value
        - show a system under test interacting through the package API when the package supports DI, pipelines, handlers, factories, lifecycle hooks, loggers, collectors, stores, recorders, fixtures, or test hosts
        - use only real namespaces, type names, constructors, methods, overloads, return types, and extension methods from the evidence
        - define any helper, fake service, fake domain type, or derived class it needs inside the snippet
        - avoid external files, network resources, databases, environment variables, and machine-specific resources
        - avoid pseudocode, ellipses, TODO comments, placeholder methods, and unexplained magic
        - avoid toy/greeting-oriented names and literal-only bodies such as `Greeting`, `MessageService`, `Hello World`, `OK`, `Foo`, `Bar`, `Sample`, or `Dummy` unless those exact terms are source-backed and central to the package
        - avoid direct helper round-trips where the test only writes to a package-owned store/logger/sink/collector/recorder/provider/factory/fixture/host and then reads the same object back
        - be copy/paste ready: the deterministic validator will place the snippet in a temporary Codebelt.Extensions.Xunit test project, install the page's NuGet package plus xUnit test packages and `Codebelt.Extensions.Xunit`, run `dotnet test`, and fail validation unless the test compiles and passes
        - stay between 10 and 35 lines when feasible
        - avoid top-level statements; assertions must live inside the single test method

        For normal code packages, after the code block write exactly two sentences:
        1. When to use this pattern.
        2. Why it matters.

        Before choosing the normal-package example, internally compare four candidates:
        1. a minimal happy path from external usage when available, otherwise tests
        2. a candidate combining two central package-owned APIs
        3. the most representative test-backed usage
        4. a full-strength example showing the package's distinctive feature, including a package-owned base class or lifecycle hook when relevant

        Prefer the candidate that makes the package's primary value obvious to a consumer.
        For foundational packages, prefer a small domain-like example that combines the central validation, configuration, decorator, option, or lifecycle pattern when evidence supports it.
        For collector, logger, store, sink, recorder, fixture, factory, host, or provider APIs, prefer indirect observation: a producer, handler, pipeline, service, lifecycle hook, or hosted component should produce the observable artifact; the test should query/assert it afterward.
        Reject any candidate that invents APIs, hides setup, demonstrates a lower-level package instead of this package, lacks assertions, uses top-level statements, contains placeholder helpers, only proves that a trivial literal round-trips, writes and reads the same package-owned helper directly, relies on greeting/message/sample naming, fails as an executable xUnit test, or lets framework setup dominate the package-specific API.
        Output only the best candidate.

        For metadata-only, aggregate, convenience, or no-assembly packages:
        - Write exactly one C# example for each referenced code package with consumer-facing APIs.
        - Use a third-level heading for each example: `### Referenced.Package.Name`.
        - Each example must follow the Codebelt-style xUnit shape: `using Codebelt.Extensions.Xunit;`, `using Xunit;`, a file-scoped consumer namespace, no `using Xunit.Abstractions;`, a public test class inheriting from `Test` or a source-backed Codebelt test base class that the evidence shows derives from `Test`, a constructor with `ITestOutputHelper output` passed to the base constructor, exactly one `[Fact]` or `[Theory]` method, at least one assertion, and useful `TestOutput.Write`, `TestOutput.WriteLine`, or `TestOutput.WriteLines` output.
        - Each example must make an API declared by the referenced package the central API.
        - Before writing each example, use the referenced package evidence map above to read and validate the referenced package's API shape.
        - Do not assume a fixture, base class, builder, options type, service, or other object exposes a member just because the member is common in a framework or plausible from its name.
        - Do not use the same toy/greeting scenario across referenced packages; each example should demonstrate the referenced package's distinct engineering role.
        - Do not imply that the convenience package owns the referenced APIs.
        - After all examples, write one short paragraph explaining that this package provides a single package reference while APIs come from the referenced packages.

        ## Installation

        ```bash
        dotnet add package {{package.Name}}
        ```

        ## Usage guidance

        Write one honest paragraph.
        Start with the positive adoption case that the evidence supports.
        Add one boundary sentence when plain framework APIs, a lower-level package, a sibling package, or no package would be the better choice.
        Do not oversell the package.
        """;

    private static string BuildOverviewPrompt(IReadOnlyList<PackageInfo> packages, PageFrontmatterHints frontmatterHints)
    {
        var packageResults = packages.Count == 0
            ? "- No packages discovered."
            : string.Join(Environment.NewLine, packages.Select(package => $"- `{ToRepositoryPath(ResultDirectoryName, package.Name + ".md")}`"));

        var supplementaryEvidence = packages.Count == 0
            ? "- No package evidence discovered."
            : string.Join(Environment.NewLine, packages.SelectMany(package => new[]
            {
                $"- `{ToRepositoryPath(EvidenceDirectoryName, package.Name, "projects.xml")}`",
                $"- `{ToRepositoryPath(EvidenceDirectoryName, package.Name, "readmes.xml")}`"
            }));

        return $$"""
        Write the conceptual overview page for this repository.

        Output file: `result/Index.md`

        Primary editorial context:
        Read every completed package digest below before writing this page:
        {{packageResults}}

        Supplementary evidence:
        Read project and README evidence only as needed to clarify package relationships, target frameworks, dependency boundaries, and repository positioning:
        {{supplementaryEvidence}}

        {{BuildFrontmatterContract(frontmatterHints)}}

        {{BuildSharedEditorialRules()}}

        ## Grounding contract for this page

        Completed package digests are the primary source material.
        Do not write the overview from repository README or project evidence alone when package digests exist.
        Use project and README evidence only as supplementary context.
        Do not invent package purposes, dependencies, recommended installation paths, scenarios, APIs, or architectural claims.
        Do not amplify unsupported claims from a package digest.
        If package digests disagree, prefer the more specific package page and write conservatively.
        Link package pages inline using relative Markdown links such as `[Package.Name](Package.Name.md)`.
        Do not create a package inventory, package-selection table, or package-named subsections.
        Do not repeat package-page API lists, examples, installation commands, or summaries.

        Before writing, internally identify:
        - the repository's unifying purpose
        - concept candidates from every completed package digest, using its Overview, Key APIs, Basic usage, and Usage guidance sections
        - the concepts and boundaries a developer must understand first
        - distinct capability domains that represent real package work, even when they are only part of a broader layer
        - package relationships and layering shown by completed package pages
        - recurring engineering patterns and extension models
        - scenarios where using a smaller package or fewer abstractions is better
        - the one non-obvious insight developers should understand

        Build the concept list from coverage first, then merge.
        For each completed package digest, ask what capability, model, extension point, or trade-off would be lost if that package's Key APIs were ignored.
        Preserve substantial distinct domains instead of collapsing them into a broad umbrella just because they share dependencies or factory patterns.
        Merge candidates only when the same concept would make the same point with the same packages and APIs.
        If a repository has many supported domains, prefer more precise concept subsections over a short polished list that hides important work.
        Do a final coverage pass against the completed package digest names and Key APIs before writing; any package-owned domain that disappears needs either its own concept or an explicit merge into a named related concept.

        Write exactly these three sections.

        ## Overview

        Start with 2-3 sentences explaining the unifying purpose and developer problem.
        Do not lead with repository metadata, target frameworks, or package counts.
        Do not summarize every package.

        ## Concepts

        Required shape:

        ```markdown
        ## Concepts

        [One short introductory paragraph that frames the concepts in this repository. This paragraph is required output.]

        ### [Concept heading]
        ```

        The first nonblank line after `## Concepts` must be that introductory paragraph, not a `###` heading.
        Treat a `## Concepts` section that starts immediately with `###` as invalid and revise before finishing.
        Use one third-level heading per concept.
        Concept headings must describe ideas, patterns, boundaries, responsibilities, or trade-offs, not package names.
        Explain each concept first, then connect relevant packages and APIs inline when that helps.
        Cover all substantial concepts supported by completed package digests.
        Do not omit a domain represented by package-owned Key APIs merely because it belongs under a larger architectural theme.
        Link package names inline with relative links.
        Prefer connecting dots between packages over describing packages in isolation.
        Do not end subsections with repeated "Covered by" lines.
        Do not create concept-to-package tables.

        ## Usage guidance

        Write one or two paragraphs.
        Explain practical boundaries, trade-offs, and common mistakes implied by package responsibilities or API design.
        Prefer concrete decision rules over slogans.
        Do not repeat the concept section or introduce package-page details that belong in individual pages.

        Before finalizing `result/Index.md`, verify that `## Concepts` is followed by a paragraph before the first `###` concept heading and that every completed package digest contributed either to a concept subsection or to an intentional merge with a named related concept.
        """;
    }

    private static async Task<ResultValidationReport> ValidateResultWorkspaceAsync(ResultValidationOptions options)
    {
        var evidenceDirectory = Path.Combine(options.Workspace, EvidenceDirectoryName);
        var resultDirectory = Path.Combine(options.Workspace, ResultDirectoryName);
        if (!Directory.Exists(evidenceDirectory))
        {
            throw new InvalidOperationException($"Evidence directory does not exist: {evidenceDirectory}");
        }

        if (!Directory.Exists(resultDirectory))
        {
            throw new InvalidOperationException($"Result directory does not exist: {resultDirectory}");
        }

        var apiSurface = BuildWorkspaceApiSurface(evidenceDirectory);
        var diagnostics = new List<ResultValidationDiagnostic>();
        var resultFiles = Directory.EnumerateFiles(resultDirectory, "*.md", SearchOption.TopDirectoryOnly)
            .OrderBy(path => path, StringComparer.OrdinalIgnoreCase)
            .Select(path => new MarkdownResultFile(path, File.ReadAllText(path, Utf8NoBom)))
            .ToList();

        foreach (var resultFile in resultFiles)
        {
            ValidateResultMarkdown(resultFile.Path, resultFile.Markdown, apiSurface, diagnostics);
        }

        await ValidateExecutableBasicUsageExamplesAsync(options, resultFiles, diagnostics);
        return new ResultValidationReport(options.Workspace, diagnostics);
    }

    private static void ValidateResultMarkdown(
        string resultFile,
        string markdown,
        IReadOnlyDictionary<string, ApiTypeSurface> apiSurface,
        List<ResultValidationDiagnostic> diagnostics)
    {
        foreach (Match match in CSharpCodeBlockExpression.Matches(markdown))
        {
            ValidateCSharpExample(resultFile, match.Groups["code"].Value, apiSurface, diagnostics);
        }

        var basicUsageSections = ExtractMarkdownSections(markdown, "## Basic usage");
        if (basicUsageSections.Count > 1)
        {
            diagnostics.Add(new ResultValidationDiagnostic(resultFile, "error", $"Result file contains {basicUsageSections.Count} top-level Basic usage sections. Keep exactly one `## Basic usage` section per package page."));
        }

        foreach (var basicUsage in basicUsageSections)
        {
            var codeBlocks = CSharpCodeBlockExpression.Matches(basicUsage);
            if (codeBlocks.Count == 0)
            {
                diagnostics.Add(new ResultValidationDiagnostic(resultFile, "error", "Basic usage section must contain at least one complete fenced C# code block."));
            }

            foreach (Match match in CSharpCodeBlockExpression.Matches(basicUsage))
            {
                ValidateBasicUsageQuality(resultFile, match.Groups["code"].Value, apiSurface, diagnostics);
            }
        }
    }

    private static async Task ValidateExecutableBasicUsageExamplesAsync(
        ResultValidationOptions options,
        IReadOnlyList<MarkdownResultFile> resultFiles,
        List<ResultValidationDiagnostic> diagnostics)
    {
        var examples = resultFiles
            .SelectMany(resultFile => ExtractBasicUsageExamples(resultFile.Path, resultFile.Markdown))
            .ToList();
        if (examples.Count == 0)
        {
            return;
        }

        var tempRoot = Path.Combine(Path.GetTempPath(), ToolName + "-example-tests-" + Guid.NewGuid().ToString("N", CultureInfo.InvariantCulture));
        Directory.CreateDirectory(tempRoot);

        try
        {
            for (var i = 0; i < examples.Count; i++)
            {
                await ValidateExecutableBasicUsageExampleAsync(tempRoot, examples[i], i + 1, diagnostics);
            }
        }
        finally
        {
            TryDeleteDirectory(tempRoot);
        }
    }

    private static IEnumerable<BasicUsageExample> ExtractBasicUsageExamples(string resultFile, string markdown)
    {
        var basicUsageSections = ExtractMarkdownSections(markdown, "## Basic usage");
        if (basicUsageSections.Count == 0)
        {
            yield break;
        }

        var index = 0;
        foreach (var basicUsage in basicUsageSections)
        {
            foreach (Match match in CSharpCodeBlockExpression.Matches(basicUsage))
            {
                index++;
                yield return new BasicUsageExample(resultFile, index, ResolveResultPackageId(resultFile, markdown), match.Groups["code"].Value.Trim());
            }
        }
    }

    private static async Task ValidateExecutableBasicUsageExampleAsync(
        string tempRoot,
        BasicUsageExample example,
        int exampleNumber,
        List<ResultValidationDiagnostic> diagnostics)
    {
        var exampleDirectory = Path.Combine(tempRoot, "example-" + exampleNumber.ToString("D3", CultureInfo.InvariantCulture));
        Directory.CreateDirectory(exampleDirectory);

        if (string.IsNullOrWhiteSpace(example.PackageId))
        {
            diagnostics.Add(new ResultValidationDiagnostic(example.ResultFile, "error", $"Basic usage example #{example.CodeBlockIndex} cannot be executable-validated because no packageId was found in frontmatter or the result filename."));
            return;
        }

        var projectPath = Path.Combine(exampleDirectory, ExampleValidationProjectName + ".csproj");
        await WriteUtf8Async(projectPath, BuildExampleValidationProject());
        await WriteUtf8Async(Path.Combine(exampleDirectory, "BasicUsageExampleTests.cs"), example.Code + Environment.NewLine);

        var outputPath = Path.Combine(exampleDirectory, "bin") + Path.DirectorySeparatorChar;
        var intermediatePath = Path.Combine(exampleDirectory, "obj") + Path.DirectorySeparatorChar;

        try
        {
            await AddExampleValidationPackageAsync(exampleDirectory, projectPath, "Microsoft.NET.Test.Sdk");
            await AddExampleValidationPackageAsync(exampleDirectory, projectPath, "xunit.v3");
            await AddExampleValidationPackageAsync(exampleDirectory, projectPath, "xunit.runner.visualstudio");
            await AddExampleValidationPackageAsync(exampleDirectory, projectPath, "Codebelt.Extensions.Xunit");
            if (!string.Equals(example.PackageId, "Codebelt.Extensions.Xunit", StringComparison.OrdinalIgnoreCase))
            {
                await AddExampleValidationPackageAsync(exampleDirectory, projectPath, example.PackageId);
            }
            await RunProcessCaptureAsync(
                "dotnet",
                [
                    "test",
                    ExampleValidationProjectName + ".csproj",
                    "--nologo",
                    "/p:BaseOutputPath=" + outputPath,
                    "/p:BaseIntermediateOutputPath=" + intermediatePath
                ],
                exampleDirectory,
                TimeSpan.FromMinutes(3));
        }
        catch (Exception ex)
        {
            var message = $"Basic usage example #{example.CodeBlockIndex} does not compile and pass as a copy/paste Codebelt.Extensions.Xunit test. Rewrite the example from source evidence and rerun validation. {TrimDiagnostic(ex.Message)}";
            diagnostics.Add(new ResultValidationDiagnostic(example.ResultFile, "error", message));
        }
    }

    private static async Task AddExampleValidationPackageAsync(string exampleDirectory, string projectPath, string packageId)
    {
        await RunProcessCaptureAsync("dotnet", ["add", projectPath, "package", packageId], exampleDirectory, TimeSpan.FromMinutes(2));
    }

    private static string BuildExampleValidationProject()
    {
        var sb = new StringBuilder();
        sb.AppendLine("""<Project Sdk="Microsoft.NET.Sdk">""");
        sb.AppendLine("  <PropertyGroup>");
        sb.AppendLine("    <TargetFramework>net10.0</TargetFramework>");
        sb.AppendLine("    <Nullable>enable</Nullable>");
        sb.AppendLine("    <ImplicitUsings>enable</ImplicitUsings>");
        sb.AppendLine("    <IsPackable>false</IsPackable>");
        sb.AppendLine("  </PropertyGroup>");
        sb.AppendLine("</Project>");
        return sb.ToString();
    }

    private static string ResolveResultPackageId(string resultFile, string markdown)
    {
        var frontmatterMatch = Regex.Match(markdown, @"(?m)^packageId:\s*['""]?(?<packageId>[^'""\r\n]+)['""]?\s*$", RegexOptions.CultureInvariant);
        if (frontmatterMatch.Success)
        {
            return frontmatterMatch.Groups["packageId"].Value.Trim();
        }

        var fileName = Path.GetFileNameWithoutExtension(resultFile);
        return string.Equals(fileName, "Index", StringComparison.OrdinalIgnoreCase) ? string.Empty : fileName;
    }

    private static string TrimDiagnostic(string message)
    {
        var normalized = message.Replace("\r\n", "\n", StringComparison.Ordinal).Trim();
        return normalized.Length <= 4000 ? normalized : normalized[..4000] + "...";
    }

    private static void ValidateCSharpExample(
        string resultFile,
        string code,
        IReadOnlyDictionary<string, ApiTypeSurface> apiSurface,
        List<ResultValidationDiagnostic> diagnostics)
    {
        var typeByVariable = InferSnippetVariables(code);
        foreach (Match access in MemberAccessExpression.Matches(code))
        {
            var receiver = access.Groups["receiver"].Value;
            var member = access.Groups["member"].Value;
            if (!typeByVariable.TryGetValue(receiver, out var receiverType))
            {
                continue;
            }

            if (!apiSurface.ContainsKey(StripGenericArity(receiverType)))
            {
                continue;
            }

            if (IsMemberDeclared(apiSurface, receiverType, member))
            {
                continue;
            }

            var message = $"`{receiver}.{member}` is not declared on `{receiverType}` in source evidence.";
            diagnostics.Add(new ResultValidationDiagnostic(resultFile, "error", message));
        }
    }

    private static void ValidateBasicUsageQuality(
        string resultFile,
        string code,
        IReadOnlyDictionary<string, ApiTypeSurface> apiSurface,
        List<ResultValidationDiagnostic> diagnostics)
    {
        ValidateBasicUsageCodeBlockStructure(resultFile, code, diagnostics);
        ValidateFileScopedNamespace(resultFile, code, diagnostics);
        ValidateCodebeltXunitShape(resultFile, code, apiSurface, diagnostics);
        ValidateToyExampleTerms(resultFile, code, diagnostics);
        ValidateDirectRoleRoundTrip(resultFile, code, apiSurface, diagnostics);
    }

    private static void ValidateBasicUsageCodeBlockStructure(
        string resultFile,
        string code,
        List<ResultValidationDiagnostic> diagnostics)
    {
        if (FenceLineInsideCodeExpression.IsMatch(code) || MarkdownHeadingInsideCodeExpression.IsMatch(code))
        {
            diagnostics.Add(new ResultValidationDiagnostic(resultFile, "error", "Basic usage C# code block appears to contain nested Markdown fences or headings. Repair the Markdown so each Basic usage example is one complete fenced C# block."));
        }
    }

    private static void ValidateFileScopedNamespace(
        string resultFile,
        string code,
        List<ResultValidationDiagnostic> diagnostics)
    {
        if (!FileScopedNamespaceExpression.IsMatch(code))
        {
            diagnostics.Add(new ResultValidationDiagnostic(resultFile, "error", "Basic usage example must use a file-scoped consumer namespace such as `namespace MyProject.Tests;`."));
        }

        if (BlockScopedNamespaceExpression.IsMatch(code))
        {
            diagnostics.Add(new ResultValidationDiagnostic(resultFile, "error", "Basic usage example must not use a block-scoped namespace. Use file-scoped namespace syntax instead."));
        }
    }

    private static void ValidateCodebeltXunitShape(
        string resultFile,
        string code,
        IReadOnlyDictionary<string, ApiTypeSurface> apiSurface,
        List<ResultValidationDiagnostic> diagnostics)
    {
        var missing = new List<string>();
        if (!code.Contains("using Codebelt.Extensions.Xunit;", StringComparison.Ordinal))
        {
            missing.Add("using Codebelt.Extensions.Xunit;");
        }

        if (!code.Contains("using Xunit;", StringComparison.Ordinal))
        {
            missing.Add("using Xunit;");
        }

        if (code.Contains("using Xunit.Abstractions;", StringComparison.Ordinal))
        {
            diagnostics.Add(new ResultValidationDiagnostic(resultFile, "error", "Basic usage example must not import Xunit.Abstractions; xUnit v3 exposes ITestOutputHelper through the Xunit namespace and Codebelt.Extensions.Xunit.Test handles output."));
        }

        if (!HasCodebeltTestBaseClass(code, apiSurface))
        {
            missing.Add("a public test class inheriting from Codebelt.Extensions.Xunit.Test or a source-evidence type derived from Test");
        }

        if (!CodebeltTestConstructorExpression.IsMatch(code))
        {
            missing.Add("a constructor that accepts ITestOutputHelper output and calls base(output)");
        }

        if (!TestOutputExpression.IsMatch(code))
        {
            missing.Add("TestOutput.Write, TestOutput.WriteLine, or TestOutput.WriteLines with human-friendly scenario output");
        }

        if (missing.Count > 0)
        {
            diagnostics.Add(new ResultValidationDiagnostic(resultFile, "error", "Basic usage example must follow the Codebelt.Extensions.Xunit test shape: " + string.Join("; ", missing) + "."));
        }
    }

    private static bool HasCodebeltTestBaseClass(string code, IReadOnlyDictionary<string, ApiTypeSurface> apiSurface)
    {
        foreach (Match classMatch in ClassDeclarationExpression.Matches(code))
        {
            var body = TryExtractTypeBody(code, classMatch.Index);
            if (body is null || !ContainsXunitTestMethod(body))
            {
                continue;
            }

            if (!classMatch.Groups["base"].Success)
            {
                continue;
            }

            foreach (var baseType in SplitBaseTypes(classMatch.Groups["base"].Value))
            {
                if (IsTestOrDerivedFromTest(apiSurface, baseType))
                {
                    return true;
                }
            }
        }

        return false;
    }

    private static bool ContainsXunitTestMethod(string body) =>
        body.Contains("[Fact]", StringComparison.Ordinal) ||
        body.Contains("[Theory]", StringComparison.Ordinal);

    private static bool IsTestOrDerivedFromTest(IReadOnlyDictionary<string, ApiTypeSurface> apiSurface, string typeName)
    {
        var visited = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        return IsTestOrDerivedFromTest(apiSurface, NormalizeTypeReference(typeName), visited);
    }

    private static bool IsTestOrDerivedFromTest(IReadOnlyDictionary<string, ApiTypeSurface> apiSurface, string typeName, HashSet<string> visited)
    {
        if (string.Equals(typeName, "Test", StringComparison.OrdinalIgnoreCase))
        {
            return true;
        }

        if (!visited.Add(typeName))
        {
            return false;
        }

        return apiSurface.TryGetValue(typeName, out var surface) &&
               surface.BaseTypes.Any(baseType => IsTestOrDerivedFromTest(apiSurface, NormalizeTypeReference(baseType), visited));
    }

    private static void ValidateToyExampleTerms(
        string resultFile,
        string code,
        List<ResultValidationDiagnostic> diagnostics)
    {
        var terms = ToyExampleTermExpression.Matches(code)
            .Select(match => match.Groups["term"].Value)
            .Distinct(StringComparer.OrdinalIgnoreCase)
            .OrderBy(term => term, StringComparer.OrdinalIgnoreCase)
            .ToList();

        if (terms.Count < 2)
        {
            return;
        }

        var message = "Basic usage example looks toy or greeting-oriented because it uses low-signal terms: " + string.Join(", ", terms) + ". Prefer a source-backed engineering scenario unless those terms are central in the evidence.";
        diagnostics.Add(new ResultValidationDiagnostic(resultFile, "error", message));
    }

    private static void ValidateDirectRoleRoundTrip(
        string resultFile,
        string code,
        IReadOnlyDictionary<string, ApiTypeSurface> apiSurface,
        List<ResultValidationDiagnostic> diagnostics)
    {
        var typeByVariable = InferSnippetVariables(code);
        var membersByReceiver = MemberAccessExpression.Matches(code)
            .GroupBy(match => match.Groups["receiver"].Value, StringComparer.OrdinalIgnoreCase)
            .ToDictionary(
                group => group.Key,
                group => group.Select(match => match.Groups["member"].Value).ToHashSet(StringComparer.OrdinalIgnoreCase),
                StringComparer.OrdinalIgnoreCase);

        foreach (var (variableName, typeName) in typeByVariable)
        {
            var simpleTypeName = StripGenericArity(typeName);
            if (!apiSurface.ContainsKey(simpleTypeName) || !IsExampleRoleType(simpleTypeName))
            {
                continue;
            }

            if (!membersByReceiver.TryGetValue(variableName, out var members))
            {
                continue;
            }

            var writeMembers = members.Where(member => DirectWriteMemberNames.Contains(member, StringComparer.OrdinalIgnoreCase)).ToList();
            var readMembers = members.Where(member => DirectReadMemberNames.Contains(member, StringComparer.OrdinalIgnoreCase)).ToList();
            if (writeMembers.Count == 0 || readMembers.Count == 0)
            {
                continue;
            }

            var message = $"Basic usage example directly writes to and reads from package-owned `{simpleTypeName}` via `{variableName}` ({string.Join(", ", writeMembers.Concat(readMembers).Distinct(StringComparer.OrdinalIgnoreCase))}). Prefer an indirect scenario where a producer, service, handler, pipeline, or lifecycle hook creates the observable result.";
            diagnostics.Add(new ResultValidationDiagnostic(resultFile, "error", message));
        }
    }

    private static string ExtractMarkdownSectionText(string markdown, string heading)
    {
        var sections = ExtractMarkdownSections(markdown, heading);
        return sections.Count == 0 ? string.Empty : sections[0];
    }

    private static IReadOnlyList<string> ExtractMarkdownSections(string markdown, string heading)
    {
        var sections = new List<string>();
        var inFence = false;
        var fenceMarker = string.Empty;
        int? sectionStart = null;

        foreach (var line in EnumerateMarkdownLines(markdown))
        {
            if (!inFence && IsLevelTwoHeadingLine(line.Text))
            {
                if (sectionStart.HasValue)
                {
                    sections.Add(markdown[sectionStart.Value..line.Start]);
                    sectionStart = null;
                }

                if (IsExactHeadingLine(line.Text, heading))
                {
                    sectionStart = line.Start;
                }
            }

            var trimmed = line.Text.TrimStart();
            if (inFence)
            {
                if (IsFenceClosingLine(trimmed, fenceMarker))
                {
                    inFence = false;
                    fenceMarker = string.Empty;
                }
            }
            else if (TryGetFenceOpeningMarker(trimmed, out var marker))
            {
                inFence = true;
                fenceMarker = marker;
            }
        }

        if (sectionStart.HasValue)
        {
            sections.Add(markdown[sectionStart.Value..]);
        }

        return sections;
    }

    private static IEnumerable<MarkdownLine> EnumerateMarkdownLines(string markdown)
    {
        for (var index = 0; index < markdown.Length;)
        {
            var start = index;
            var newlineIndex = markdown.IndexOf('\n', index);
            var next = newlineIndex < 0 ? markdown.Length : newlineIndex + 1;
            var end = newlineIndex < 0 ? markdown.Length : newlineIndex;
            if (end > start && markdown[end - 1] == '\r')
            {
                end--;
            }

            yield return new MarkdownLine(start, markdown[start..end]);
            index = next;
        }
    }

    private static bool IsExactHeadingLine(string line, string heading) =>
        string.Equals(line.Trim(), heading, StringComparison.OrdinalIgnoreCase);

    private static bool IsLevelTwoHeadingLine(string line)
    {
        var trimmed = line.TrimStart();
        return trimmed.StartsWith("## ", StringComparison.Ordinal) ||
               trimmed.StartsWith("##\t", StringComparison.Ordinal);
    }

    private static bool TryGetFenceOpeningMarker(string trimmedLine, out string marker)
    {
        if (trimmedLine.StartsWith("```", StringComparison.Ordinal))
        {
            marker = "```";
            return true;
        }

        if (trimmedLine.StartsWith("~~~", StringComparison.Ordinal))
        {
            marker = "~~~";
            return true;
        }

        marker = string.Empty;
        return false;
    }

    private static bool IsFenceClosingLine(string trimmedLine, string marker)
    {
        if (!trimmedLine.StartsWith(marker, StringComparison.Ordinal))
        {
            return false;
        }

        return trimmedLine[marker.Length..].Trim().Length == 0;
    }

    private static bool IsExampleRoleType(string typeName) =>
        ExampleRoleSuffixes.Any(suffix => typeName.EndsWith(suffix, StringComparison.OrdinalIgnoreCase));

    private static IReadOnlyDictionary<string, string> InferSnippetVariables(string code)
    {
        var variables = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        foreach (Match classMatch in ClassDeclarationExpression.Matches(code))
        {
            var name = classMatch.Groups["name"].Value;
            variables["this"] = name;
        }

        foreach (Match constructorMatch in ConstructorParameterExpression.Matches(code))
        {
            foreach (var parameter in SplitCommaSeparatedTopLevel(constructorMatch.Groups["parameters"].Value))
            {
                var parts = parameter.Split(' ', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries);
                if (parts.Length < 2)
                {
                    continue;
                }

                var variableName = parts[^1].TrimStart('@');
                var typeName = StripGenericArity(parts[^2]);
                variables[variableName] = typeName;
            }
        }

        foreach (Match variableMatch in TypedVariableDeclarationExpression.Matches(code))
        {
            var variableName = variableMatch.Groups["name"].Value.TrimStart('@');
            var typeName = StripGenericArity(variableMatch.Groups["type"].Value);
            variables[variableName] = typeName;
        }

        foreach (Match variableMatch in VarConstructionExpression.Matches(code))
        {
            var variableName = variableMatch.Groups["name"].Value.TrimStart('@');
            var typeName = StripGenericArity(variableMatch.Groups["type"].Value);
            variables[variableName] = typeName;
        }

        return variables;
    }

    private static bool IsMemberDeclared(IReadOnlyDictionary<string, ApiTypeSurface> apiSurface, string typeName, string member)
    {
        var visited = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        return IsMemberDeclared(apiSurface, StripGenericArity(typeName), member, visited);
    }

    private static bool IsMemberDeclared(IReadOnlyDictionary<string, ApiTypeSurface> apiSurface, string typeName, string member, HashSet<string> visited)
    {
        if (!visited.Add(typeName))
        {
            return false;
        }

        if (!apiSurface.TryGetValue(typeName, out var surface))
        {
            return false;
        }

        if (surface.Members.Contains(member))
        {
            return true;
        }

        return surface.BaseTypes.Any(baseType => IsMemberDeclared(apiSurface, baseType, member, visited));
    }

    private static IReadOnlyDictionary<string, ApiTypeSurface> BuildWorkspaceApiSurface(string evidenceDirectory)
    {
        var surfaces = new Dictionary<string, ApiTypeSurface>(StringComparer.OrdinalIgnoreCase);
        foreach (var sourceFile in Directory.EnumerateFiles(evidenceDirectory, "source.xml", SearchOption.AllDirectories)
                     .OrderBy(path => path, StringComparer.OrdinalIgnoreCase))
        {
            var text = File.ReadAllText(sourceFile, Utf8NoBom);
            foreach (Match match in PublicTypeExpression.Matches(text))
            {
                var name = StripGenericArity(NormalizeDeclaration(match.Groups["name"].Value));
                var body = TryExtractTypeBody(text, match.Index);
                var members = body is null
                    ? []
                    : ExtractPublicMemberCandidates(body, name).Select(ExtractMemberName).Where(value => !string.IsNullOrWhiteSpace(value)).ToHashSet(StringComparer.OrdinalIgnoreCase);
                var baseTypes = match.Groups["base"].Success
                    ? SplitBaseTypes(match.Groups["base"].Value).Select(StripGenericArity).Where(value => !string.IsNullOrWhiteSpace(value)).ToHashSet(StringComparer.OrdinalIgnoreCase)
                    : new HashSet<string>(StringComparer.OrdinalIgnoreCase);

                if (surfaces.TryGetValue(name, out var existing))
                {
                    existing.Members.UnionWith(members);
                    existing.BaseTypes.UnionWith(baseTypes);
                }
                else
                {
                    surfaces[name] = new ApiTypeSurface(name, members, baseTypes);
                }
            }
        }

        return surfaces;
    }

    private static IEnumerable<string> SplitBaseTypes(string baseTypes)
    {
        var constraintIndex = baseTypes.IndexOf(" where ", StringComparison.Ordinal);
        var declarationBaseTypes = constraintIndex < 0 ? baseTypes : baseTypes[..constraintIndex];
        return SplitCommaSeparatedTopLevel(declarationBaseTypes)
            .Select(type => type.Split(' ', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries).FirstOrDefault() ?? string.Empty)
            .Select(type => type.Trim())
            .Where(type => !string.IsNullOrWhiteSpace(type));
    }

    private static IEnumerable<string> SplitCommaSeparatedTopLevel(string value)
    {
        var start = 0;
        var depth = 0;
        for (var i = 0; i < value.Length; i++)
        {
            switch (value[i])
            {
                case '<':
                    depth++;
                    break;
                case '>':
                    if (depth > 0)
                    {
                        depth--;
                    }
                    break;
                case ',':
                    if (depth == 0)
                    {
                        var segment = value[start..i].Trim();
                        if (segment.Length > 0)
                        {
                            yield return segment;
                        }

                        start = i + 1;
                    }
                    break;
            }
        }

        var last = value[start..].Trim();
        if (last.Length > 0)
        {
            yield return last;
        }
    }

    private static string StripGenericArity(string typeName)
    {
        var normalized = NormalizeDeclaration(typeName);
        var genericIndex = normalized.IndexOf('<', StringComparison.Ordinal);
        normalized = genericIndex < 0 ? normalized : normalized[..genericIndex];
        normalized = normalized.Trim().TrimEnd('?');
        while (normalized.EndsWith("[]", StringComparison.Ordinal))
        {
            normalized = normalized[..^2];
        }

        if (normalized.StartsWith("global::", StringComparison.Ordinal))
        {
            normalized = normalized["global::".Length..];
        }

        var namespaceIndex = normalized.LastIndexOf('.');
        return namespaceIndex < 0 ? normalized : normalized[(namespaceIndex + 1)..];
    }

    private static string NormalizeTypeReference(string typeName) => StripGenericArity(typeName);

    private static string ExtractMemberName(string declaration)
    {
        var constructorMatch = Regex.Match(declaration, @"^(?<name>[A-Za-z_][A-Za-z0-9_]*)\s*\(", RegexOptions.CultureInvariant);
        if (constructorMatch.Success)
        {
            return constructorMatch.Groups["name"].Value;
        }

        var methodMatch = Regex.Match(declaration, @"\b(?<name>[A-Za-z_][A-Za-z0-9_]*)(?:<[^>]+>)?\s*\(", RegexOptions.CultureInvariant);
        if (methodMatch.Success)
        {
            return methodMatch.Groups["name"].Value;
        }

        var propertyMatch = Regex.Match(declaration, @"\b(?<name>[A-Za-z_][A-Za-z0-9_]*)\s*$", RegexOptions.CultureInvariant);
        return propertyMatch.Success ? propertyMatch.Groups["name"].Value : string.Empty;
    }

    private static void PrintValidationReport(ResultValidationReport report)
    {
        Console.WriteLine($"[digest] result validation workspace={report.Workspace}");
        if (report.Diagnostics.Count == 0)
        {
            Console.WriteLine("[digest] result validation passed.");
            return;
        }

        foreach (var diagnostic in report.Diagnostics)
        {
            Console.WriteLine($"[{diagnostic.Severity}] {diagnostic.File}: {diagnostic.Message}");
        }
    }

    private static void PrintUsage()
    {
        Console.WriteLine(
            $$"""
            {{ToolName}} deterministic evidence generator

            Usage:
              dotnet run --file scripts/digest.cs -- --repo-url <url> --output-root <path>
              dotnet run --file scripts/digest.cs -- --repo-url <url> --output-root <path> --external-repo-url <url> [--external-repo-url <url>]
              dotnet run --file scripts/digest.cs -- --validate-results --workspace <path>

            Required:
              --repo-url      Fully qualified git repository URL, for example https://github.com/owner/repo
              --output-root   Directory where the {repo-id} digest workspace will be written

            Optional:
              --external-repo-url  Public repository URL to clone and search locally for curated consumer usage.
                                   Repeat this option to provide multiple external usage repositories.
              --validate-results   Validate authored result/*.md examples against source evidence.
              --workspace          Existing digest workspace to validate.

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
              - Evidence packing uses git ls-files over the cloned repository's tracked files.
            """);
    }

    private sealed class OptionReader(string[] args)
    {
        public string GetRequired(string name)
        {
            var values = GetMany(name).ToList();
            return values.Count switch
            {
                0 => throw new InvalidOperationException($"Missing required option {name}."),
                1 => values[0],
                _ => throw new InvalidOperationException($"Option {name} can only be specified once.")
            };
        }

        public IEnumerable<string> GetMany(string name)
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

        public void ThrowIfUnknownOptions(params string[] knownOptions)
        {
            var known = new HashSet<string>(knownOptions, StringComparer.Ordinal);
            for (var i = 0; i < args.Length; i++)
            {
                var arg = args[i];
                if (!arg.StartsWith("-", StringComparison.Ordinal))
                {
                    continue;
                }

                if (!known.Contains(arg))
                {
                    throw new InvalidOperationException($"Unknown option {arg}.");
                }

                if (arg is not "--help" and not "-h")
                {
                    i++;
                }
            }
        }
    }

    private sealed record EvidenceDescriptor(string Name, string FileName, string IndexFileName, string ChunkDirectoryName, string RootElementName, string Authority)
    {
        public static readonly EvidenceDescriptor Source = new("source", "source.xml", "source.index.md", "source.chunks", "sourceEvidence", "api-shape");
        public static readonly EvidenceDescriptor Tests = new("tests", "tests.xml", "tests.index.md", "tests.chunks", "testEvidence", "usage");
        public static readonly EvidenceDescriptor Projects = new("projects", "projects.xml", "projects.index.md", "projects.chunks", "projectEvidence", "project-metadata");
        public static readonly EvidenceDescriptor Readmes = new("readmes", "readmes.xml", "readmes.index.md", "readmes.chunks", "readmeEvidence", "editorial-context");
        public static readonly EvidenceDescriptor ExternalUsage = new("external-usage", "external-usage.xml", "external-usage.index.md", "external-usage.chunks", "externalUsageEvidence", "curated-external-usage");
    }
}

internal sealed record DigestOptions(string RepoUrl, string OutputRoot, IReadOnlyList<string> ExternalRepoUrls);

internal sealed record ResultValidationOptions(string Workspace);

internal sealed record ProjectMetadata(
    string PackageId,
    string AssemblyName,
    bool? IsPackable,
    IReadOnlyList<string> BundledPackages,
    IReadOnlyList<string> TargetFrameworkMonikers,
    IReadOnlyList<string> TargetFrameworks,
    string License,
    string Title,
    string Description,
    string ProjectUrl,
    string RepositoryUrl);

internal sealed record PackageInfo(
    string Name,
    string SourcePath,
    string? TestPath,
    bool IsConveniencePackage,
    IReadOnlyList<string> BundledPackages,
    IReadOnlyList<string> TargetFrameworkMonikers,
    IReadOnlyList<string> TargetFrameworks,
    string License,
    string Title,
    string Description,
    string ProjectUrl,
    string RepositoryUrl);

internal sealed record ProjectProductCandidate(string ProjectFile, string Product, int ReferenceCount);

internal sealed record TestProjectMatch(string ProjectFile, bool IsOwnTestProjectName, bool ReferencesProject);

internal sealed record PackageWorkspaceArtifacts(string PromptPath, PackageEvidenceArtifacts Evidence, PageFrontmatterHints FrontmatterHints);

internal sealed record PackageEvidenceArtifacts(
    EvidenceArtifacts Source,
    EvidenceArtifacts Tests,
    EvidenceArtifacts Projects,
    EvidenceArtifacts Readmes,
    EvidenceArtifacts ExternalUsage,
    string ApiSummary,
    string EngineeringSignals);

internal sealed record EvidenceArtifacts(string Path, string Index, IReadOnlyList<string> Chunks, string Authority);

internal sealed record ApiTypeSummary(string Name, string Kind, string BaseTypes, IReadOnlyList<string> Members, string SourcePath);

internal sealed record SignalFile(string RelativePath, string Content);

internal sealed record EngineeringSignal(string Kind, string Value, string SourcePath);

internal sealed record RepositoryIdentity(string Host, string Path);

internal sealed record ExternalRepository(string Url, string CloneDir, RepositoryIdentity Identity);

internal sealed record ExternalUsageSearchTerm(string Value, bool IsStrong);

internal sealed record ApiTypeSurface(string Name, HashSet<string> Members, HashSet<string> BaseTypes);

internal sealed record ResultValidationDiagnostic(string File, string Severity, string Message);

internal sealed record ResultValidationReport(string Workspace, IReadOnlyList<ResultValidationDiagnostic> Diagnostics);

internal sealed record MarkdownResultFile(string Path, string Markdown);

internal sealed record MarkdownLine(int Start, string Text);

internal sealed record BasicUsageExample(string ResultFile, int CodeBlockIndex, string PackageId, string Code);

internal sealed record PageFrontmatterHints(
    string PageKind,
    string Title,
    string Description,
    string Lede,
    string? PackageId,
    int PackageCount,
    int LibraryCount,
    IReadOnlyList<string> TargetFrameworks,
    IReadOnlyList<string> TargetFrameworkMonikers,
    string License,
    IReadOnlyList<FrontmatterLink> Links,
    IReadOnlyList<FamilyLink> FamilyLinks);

internal sealed record FrontmatterLink(string Label, string Url, string Glyph);

internal sealed record FamilyLink(string Label, string PackageId, string Url, string Glyph);

internal sealed record PackageManifestEntry(string Kind, string Name, string Prompt, PackageEvidenceArtifacts Evidence, string Result, PageFrontmatterHints FrontmatterHints);

internal sealed record PackedFile(string FullPath, string RelativePath);
