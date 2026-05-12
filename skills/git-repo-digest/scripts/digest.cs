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
    private const string ToolName = "git-repo-digest";
    private const string ResultDirectoryName = "result";
    private const string PromptDirectoryName = "prompts";
    private const string EvidenceDirectoryName = "evidence";
    private const string SourceDirectoryName = "src";
    private const string TestDirectoryName = "test";
    private const string AgentGeneratedBy = "git-repo-digest";

    private const int MaxEvidenceChunkBodyBytes = 36 * 1024;
    private const int MaxExternalUsageFilesPerPackage = 96;
    private const int MaxApiSummaryTypes = 512;
    private const int MaxApiSummaryMembersPerType = 32;

    private static readonly TimeSpan DefaultProcessTimeout = TimeSpan.FromMinutes(5);
    private static readonly Encoding Utf8NoBom = new UTF8Encoding(encoderShouldEmitUTF8Identifier: false);

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
                    var packageArtifacts = await WritePackageWorkspaceAsync(workspace, repositoryDirectory, package, packages, externalRepositories);

                    packageEntries.Add(new PackageManifestEntry(
                        Kind: "package",
                        Name: package.Name,
                        Prompt: packageArtifacts.PromptPath,
                        Evidence: packageArtifacts.Evidence,
                        Result: resultPath));
                }

                var overviewPromptPath = ToRepositoryPath(PromptDirectoryName, "overview.prompt.md");
                await WriteUtf8Async(Path.Combine(workspace, overviewPromptPath), BuildOverviewPrompt(packages));
                await WriteUtf8Async(Path.Combine(workspace, "instructions.md"), BuildInstructions(options.RepoUrl, repoId));
                await WriteManifestAsync(Path.Combine(workspace, "manifest.json"), options, repoId, runId, workspace, packageEntries, overviewPromptPath);

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
            var metadata = ReadProjectMetadata(projectFile);
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
                BundledPackages: metadata.BundledPackages));
        }

        return packages;
    }

    private static ProjectMetadata ReadProjectMetadata(string projectFile)
    {
        var document = XDocument.Load(projectFile, LoadOptions.PreserveWhitespace);
        var packageId = ElementValue(document, "PackageId");
        var assemblyName = ElementValue(document, "AssemblyName");
        var isPackable = TryParseBoolean(ElementValue(document, "IsPackable"));
        var bundledPackages = document.Descendants()
            .Where(element => element.Name.LocalName is "PackageReference" or "ProjectReference")
            .Select(element => element.Attribute("Include")?.Value)
            .Where(value => !string.IsNullOrWhiteSpace(value))
            .Select(value => value!)
            .Distinct(StringComparer.OrdinalIgnoreCase)
            .OrderBy(value => value, StringComparer.OrdinalIgnoreCase)
            .ToList();

        return new ProjectMetadata(packageId, assemblyName, isPackable, bundledPackages);
    }

    private static bool? TryParseBoolean(string value) =>
        bool.TryParse(value, out var parsed) ? parsed : null;

    private static string ElementValue(XDocument document, string localName) =>
        document.Descendants().FirstOrDefault(element => element.Name.LocalName == localName)?.Value.Trim() ?? string.Empty;

    private static string FirstNonEmpty(params string[] values) =>
        values.First(value => !string.IsNullOrWhiteSpace(value)).Trim();

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
        IReadOnlyList<ExternalRepository> externalRepositories)
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

        await WriteUtf8Async(Path.Combine(workspace, promptPath), BuildPackageDigestPrompt(package, evidence));
        return new PackageWorkspaceArtifacts(promptPath, evidence);
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
        var lifecycleSignals = FindSignals(files, @"\b([A-Za-z0-9_]*(?:Configure|Callback|Fixture|Factory|Initialize|Dispose|Lifetime|Host|Application)[A-Za-z0-9_]*)\b", "lifecycle or composition name").Take(16).ToList();
        var hostingSignals = FindSignals(files, @"\b(IHostBuilder|HostApplicationBuilder|Host\.CreateApplicationBuilder|WebApplicationBuilder|IApplicationBuilder|WebApplicationFactory|TestServer)\b", "hosting model").Take(12).ToList();
        var testSignals = files
            .Where(file => IsTestEvidenceFile(file.RelativePath, package))
            .Select(file => file.RelativePath)
            .Distinct(StringComparer.OrdinalIgnoreCase)
            .OrderBy(path => path, StringComparer.OrdinalIgnoreCase)
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

    private static IEnumerable<EngineeringSignal> FindSignals(IEnumerable<SignalFile> files, string pattern, string kind)
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

                var key = file.RelativePath + "|" + value;
                if (seen.Add(key))
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
        string overviewPromptPath)
    {
        var packageTargets = packages.Select(package => new
        {
            package.Kind,
            package.Name,
            package.Prompt,
            package.Evidence,
            package.Result
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
            result = "result/Index.md"
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
        9. Validate that all manifest result paths exist.
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

    private static string BuildPackageDigestPrompt(PackageInfo package, PackageEvidenceArtifacts evidence) =>
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

        ## Package metadata

        - Source path: `{{package.SourcePath}}`
        - Test path: `{{package.TestPath ?? "(not discovered)"}}`
        - Metadata-only package: `{{package.IsConveniencePackage}}`
        - Referenced packages: {{(package.BundledPackages.Count == 0 ? "(none declared)" : string.Join(", ", package.BundledPackages))}}

        {{BuildSharedEditorialRules()}}

        ## Grounding contract for this page

        Use only the supplied evidence set.
        Read raw evidence directly when possible. If a raw evidence file is capped or unsafe to read completely, read every chunk in numeric order.
        Validate `api-summary.md` and `engineering-signals.md` against raw evidence before using their hints.
        Treat source as authoritative for API shape. Treat tests as authoritative for usage. Treat projects as authoritative for package relationships. Treat README as editorial context.
        Use external usage only when it references this package or a transitive package discovered by the runner and current source confirms the API shape.
        If source evidence is unclear and README is the only source for a claim, either write conservatively or omit the claim.

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
        - the 3-6 package-owned public APIs that matter most
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

        List the 3-6 most important consumer-facing APIs.
        Format each item exactly:

        `ApiName` - Description.

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
        - use a consumer namespace such as `MyProject.Tests`
        - contain exactly one `[Fact]` or `[Theory]` method unless tests are clearly irrelevant for this package type
        - include at least one assertion or observable result
        - demonstrate the current package's central API, normally one declared by this package
        - use only real namespaces, type names, constructors, methods, overloads, return types, and extension methods from the evidence
        - define any helper, fake service, fake domain type, or derived class it needs inside the snippet
        - avoid external files, network resources, databases, environment variables, and machine-specific resources
        - avoid pseudocode, ellipses, TODO comments, placeholder methods, and unexplained magic
        - stay between 10 and 35 lines when feasible

        For normal code packages, after the code block write exactly two sentences:
        1. When to use this pattern.
        2. Why it matters.

        Before choosing the normal-package example, internally compare four candidates:
        1. a minimal happy path from external usage when available, otherwise tests
        2. a candidate combining two central package-owned APIs
        3. the most representative test-backed usage
        4. a full-strength example showing the package's distinctive feature, including a package-owned base class or lifecycle hook when relevant

        Reject any candidate that invents APIs, hides setup, demonstrates a lower-level package instead of this package, lacks assertions, contains placeholder helpers, or lets framework setup dominate the package-specific API.
        Output only the best candidate.

        For metadata-only, aggregate, convenience, or no-assembly packages:
        - Write exactly one C# example for each referenced code package with consumer-facing APIs.
        - Use a third-level heading for each example: `### Referenced.Package.Name`.
        - Each example must contain exactly one `[Fact]` or `[Theory]` method and at least one assertion.
        - Each example must make an API declared by the referenced package the central API.
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

    private static string BuildOverviewPrompt(IReadOnlyList<PackageInfo> packages)
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

    private static void PrintUsage()
    {
        Console.WriteLine(
            $$"""
            {{ToolName}} deterministic evidence generator

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

internal sealed record ProjectMetadata(string PackageId, string AssemblyName, bool? IsPackable, IReadOnlyList<string> BundledPackages);

internal sealed record PackageInfo(string Name, string SourcePath, string? TestPath, bool IsConveniencePackage, IReadOnlyList<string> BundledPackages);

internal sealed record TestProjectMatch(string ProjectFile, bool IsOwnTestProjectName, bool ReferencesProject);

internal sealed record PackageWorkspaceArtifacts(string PromptPath, PackageEvidenceArtifacts Evidence);

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

internal sealed record PackageManifestEntry(string Kind, string Name, string Prompt, PackageEvidenceArtifacts Evidence, string Result);

internal sealed record PackedFile(string FullPath, string RelativePath);
