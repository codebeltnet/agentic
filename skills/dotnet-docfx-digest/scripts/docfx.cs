#:property TargetFramework=net10.0
#:property Nullable=enable
#:property LangVersion=latest
#:property PublishAot=false
#:package System.Reflection.MetadataLoadContext@9.0.0

using System.Diagnostics;
using System.Globalization;
using System.Reflection;
using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;
using System.Text.RegularExpressions;
using System.Threading;
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
    private const string SkipAllowlistFileName = "skip-compile-allowlist.json";
    private const int DefaultSampleValidationParallelism = 2;
    private const int DefaultProcessTimeoutMinutes = 30;
    private const long HighCapacityMemoryThresholdBytes = 32L * 1024 * 1024 * 1024;

    private static readonly string[] IgnoredDirectorySegments = ["bin", "obj", "_site", ".git", ".vs", ".vscode", ".idea", "node_modules"];
    private static TimeSpan _processTimeout = TimeSpan.FromMinutes(DefaultProcessTimeoutMinutes);
    private static readonly TimeSpan ProcessStreamDrainTimeout = TimeSpan.FromSeconds(5);
    private static readonly TimeSpan ProcessHeartbeatInterval = TimeSpan.FromSeconds(10);
    private static readonly Regex SyntheticExtensionBlockUidMarkerRegex = new(
        @"(?:^|\.)(?:<[GM]>|\uF03C[GM]\uF03E|%3c[GM]%3e)(?:\$|%24)[0-9A-Fa-f]{8,}",
        RegexOptions.IgnoreCase | RegexOptions.CultureInvariant | RegexOptions.Compiled);

    // xref link detection: [label](xref:UID) and <xref:UID> patterns in DocFX markdown.
    private static readonly Regex XrefMarkdownLinkRegex = new(
        @"\[(?:[^\]]*)\]\(xref:([^)\s]+)\)",
        RegexOptions.CultureInvariant | RegexOptions.Compiled);
    private static readonly Regex XrefInlineTagRegex = new(
        @"<xref:([^>\s]+)>",
        RegexOptions.CultureInvariant | RegexOptions.Compiled);

    // Process guard state. The fast (default) path forbids dotnet/msbuild/docfx/gh entirely;
    // each external process is tagged with the permission that authorizes it, and the set of
    // allowed permissions is configured from the parsed options before any process runs.
    private static readonly object ProcessGuardLock = new();
    private static readonly Dictionary<string, int> ProcessCounts =
        new(StringComparer.OrdinalIgnoreCase) { ["dotnet"] = 0, ["msbuild"] = 0, ["docfx"] = 0, ["gh"] = 0, ["git"] = 0 };
    private static HashSet<ProcessPermission> _allowedPermissions = new() { ProcessPermission.Git };
    private static bool _quietProgress;

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
            if (options.WriteOverwriteRequestPath is not null)
            {
                _quietProgress = options.QuietProgress;
                ConfigureProcessGuard(options);
                return WriteOverwriteCommand(options);
            }

            _quietProgress = options.QuietProgress;
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
        var phaseTimer = new Stopwatch();

        var mode = options.BuildApiModel ? ValidationMode.BuildBackedApiModel : ValidationMode.FastMarkdown;
        report.Summary.ValidationMode = mode == ValidationMode.BuildBackedApiModel
            ? "build-backed-api-model"
            : "fast-markdown";
        var execution = ResolveExecutionSettings(options);
        _processTimeout = TimeSpan.FromMinutes(execution.ProcessTimeoutMinutes);
        report.Summary.Execution = new ExecutionSummary
        {
            Profile = execution.Profile,
            LogicalProcessors = execution.LogicalProcessors,
            AvailableMemoryBytes = execution.AvailableMemoryBytes,
            BuildParallelism = execution.BuildParallelism,
            SampleParallelism = execution.SampleParallelism,
            ProcessTimeoutMinutes = execution.ProcessTimeoutMinutes,
            ConcurrentDocfxVerification = execution.ConcurrentDocfxVerification
        };

        // Configure the process guard from options BEFORE anything can shell out. In the default
        // fast path this leaves dotnet/msbuild/docfx/gh entirely disallowed.
        ConfigureProcessGuard(options);

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
        phaseTimer.Restart();
        options.Framework ??= ResolveDefaultFramework(docfxPath, report);
        WritePhase(options, report, "docfx config", phaseTimer.Elapsed);

        // No-build layout validation: confirm the overwrite directory split without compiling.
        ValidateApiOverwriteLayout(repoRoot, docfxPath, docfxWorkspace, report);

        // 3. Verify AGENTS.md contains the managed block.
        var agentsPath = Path.Combine(repoRoot, "AGENTS.md");
        if (!AgentsBlockPresent(agentsPath))
        {
            report.Errors.Add(new Diagnostic("AGENTS_BLOCK_MISSING", agentsPath, null,
                "AGENTS.md does not contain the dotnet-docfx-digest managed block. Run scripts/agents.cs first."));
        }

        // Optional changed-only scoping (git only — read-only, allowed on the fast path).
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

        // Cache: compute once for the full validation run so callers do not repeatedly scan the repo root.
        var hasStrongNameKey = HasRootStrongNameKey(repoRoot);

        // 4. Discover DocFX metadata projects from the active docfx.json (no build required).
        phaseTimer.Restart();
        var projects = DiscoverProjects(docfxPath, docfxWorkspace, report, out var metadataGroups);
        WritePhase(options, report, "project discovery", phaseTimer.Elapsed);
        if (projects.Count == 0)
        {
            return Emit(options, report, ExitCode.PublicApiDiscoveryFailed, "Project discovery failed.");
        }

        var libraryProjects = projects.Where(p => !p.IsTest).ToList();

        // Store package IDs for use in the assessment work queue GitHub search section.
        report.PackageIds.AddRange(
            libraryProjects
                .Select(p => p.PackageId ?? p.AssemblyName)
                .Distinct(StringComparer.OrdinalIgnoreCase)
                .OrderBy(id => id, StringComparer.OrdinalIgnoreCase));

        // Discover and cache DocFX Markdown inputs + overwrite sections once.
        phaseTimer.Restart();
        var markdownFiles = DiscoverMarkdown(repoRoot, docfxPath, docfxWorkspace, report);
        var workspace = new ValidationWorkspace
        {
            RepoRoot = repoRoot,
            DocfxPath = docfxPath,
            DocfxWorkspace = docfxWorkspace,
            Projects = projects,
            LibraryProjects = libraryProjects,
            MarkdownFiles = markdownFiles,
            MarkdownTextByPath = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase),
            OverwriteSections = new List<OverwriteSection>(),
            SkipAllowlistEntries = new List<ApprovedSkipEntry>()
        };
        foreach (var md in markdownFiles)
        {
            var text = workspace.ReadMarkdown(md);
            workspace.OverwriteSections.AddRange(ExtractOverwriteSections(md, text));
        }

        workspace.SkipAllowlistEntries.AddRange(LoadApprovedSkipEntries(repoRoot, docfxWorkspace, report));

        WritePhase(options, report, "markdown discovery", phaseTimer.Elapsed,
            $"{markdownFiles.Count} file(s)");

        CancellationTokenSource? concurrentDocfxCancellation = null;
        Task<DocfxVerificationResult>? concurrentDocfxTask = null;
        if (options.VerifyDocfxBuild && execution.ConcurrentDocfxVerification)
        {
            concurrentDocfxCancellation = new CancellationTokenSource();
            var cancellationToken = concurrentDocfxCancellation.Token;
            concurrentDocfxTask = Task.Run(
                () => VerifyDocfxBuild(repoRoot, docfxPath, hasStrongNameKey, cancellationToken),
                cancellationToken);
        }

        try
        {
        // 5. Build the API model. The default fast path never builds: it reads existing DocFX
        //    YAML metadata when present, otherwise falls back to a conservative source scan.
        //    --build-api-model opts into reflection-backed discovery from compiled assemblies.
        phaseTimer.Restart();
        ApiModel api;
        ApiModelSource apiModelSource;
        if (mode == ValidationMode.BuildBackedApiModel)
        {
            var (buildOk, buildOutput) = BuildDocfxProjects(libraryProjects, repoRoot, options.Configuration,
                hasStrongNameKey, execution.BuildParallelism);
            if (!buildOk)
            {
                CancelConcurrentDocfxVerification(concurrentDocfxTask, concurrentDocfxCancellation);
                report.Errors.Add(new Diagnostic("BUILD_FAILED", null, null,
                    $"dotnet build failed (configuration {options.Configuration}).\n{Trim(buildOutput)}"));
                return Emit(options, report, ExitCode.BuildFailed, "Build failed.");
            }

            try
            {
                api = DiscoverApi(libraryProjects, options.Configuration, options.Framework, report);
            }
            catch (Exception ex)
            {
                CancelConcurrentDocfxVerification(concurrentDocfxTask, concurrentDocfxCancellation);
                report.Errors.Add(new Diagnostic("PUBLIC_API_DISCOVERY_FAILED", null, null,
                    $"Public API discovery failed: {ex.Message}"));
                return Emit(options, report, ExitCode.PublicApiDiscoveryFailed, "Public API discovery failed.");
            }

            report.Summary.ApiModelSource = "build-backed";
            apiModelSource = ApiModelSource.BuildBacked;
            WritePhase(options, report, "api model", phaseTimer.Elapsed, "build-backed");

            if (api.Namespaces.Count == 0)
            {
                CancelConcurrentDocfxVerification(concurrentDocfxTask, concurrentDocfxCancellation);
                report.Errors.Add(new Diagnostic("PUBLIC_API_DISCOVERY_FAILED", null, null,
                    "No public API could be discovered from the compiled library assemblies. Ensure the repository builds and exposes public types."));
                return Emit(options, report, ExitCode.PublicApiDiscoveryFailed, "Public API discovery failed.");
            }
        }
        else
        {
            api = BuildNoBuildApiModel(workspace, report, out var apiSource);
            apiModelSource = apiSource;
            report.Summary.ApiModelSource = apiSource == ApiModelSource.DocfxYaml ? "docfx-yaml" : "source-scan";
            WritePhase(options, report, "api model", phaseTimer.Elapsed, report.Summary.ApiModelSource);

            if (api.Namespaces.Count == 0)
            {
                // Conservative: do not fail the whole run just because no-build discovery found
                // nothing. Markdown/overwrite/encoding/layout checks above still apply.
                report.Warnings.Add(new Diagnostic("API_MODEL_EMPTY", null, null,
                    "No public API was discovered without building. Markdown, encoding, and overwrite-layout checks still ran. Use --build-api-model for reflection-backed namespace and required-example validation."));
            }
        }

        report.Summary.PublicNamespaces = api.Namespaces.Count;
        report.Summary.RequiredExampleTargets = api.RequiredExampleTargets.Count;
        report.Summary.ExtensionMethods = api.Namespaces.Sum(n => n.ExtensionMethods.Count);

        // 6. Validate documentation file encoding corruption (mojibake).
        phaseTimer.Restart();
        ValidateDocumentationEncoding(repoRoot, markdownFiles, report);
        WritePhase(options, report, "encoding validation", phaseTimer.Elapsed);

        // Build a filename-keyed index to replace the O(N*M) FirstOrDefault scan per namespace.
        var namespacePageIndex = markdownFiles
            .GroupBy(f => Path.GetFileNameWithoutExtension(f), StringComparer.OrdinalIgnoreCase)
            .ToDictionary(g => g.Key, g => g.First(), StringComparer.OrdinalIgnoreCase);

        var allOverwriteSections = workspace.OverwriteSections;

        // 6b. Project-scoped discovery: git state, packets, skipped generic-arity families, symbol ownership,
        //     and scope selection (full / explicit hints / seeded dry-run) before validation so the
        //     namespace and required-example checks can be scoped to the selected packets.
        phaseTimer.Restart();
        EnsureNamespaceProjectMap(workspace);
        var gitState = GetGitState(repoRoot);
        ValidateInterimArtifacts(repoRoot, docfxPath, docfxWorkspace, workspace, api, gitState, report);
        var resumeScope = options.ResumeProjectManifestPath is null
            ? null
            : LoadResumeProjectManifest(options.ResumeProjectManifestPath, repoRoot, report);
        var packets = BuildProjectPackets(workspace, api, gitState, metadataGroups, repoRoot, docfxWorkspace,
            resumeScope?.InitialDirtyPaths);
        var families = DetectGenericArityFamilies(repoRoot, docfxWorkspace, api, workspace, namespacePageIndex, report);
        ApplySkippedFamilies(api, families);
        report.Summary.RequiredExampleTargets = api.RequiredExampleTargets.Count;
        var scope = ResolveScope(options, packets, metadataGroups, apiModelSource, repoRoot, report, resumeScope);
        ValidateSymbolOwnership(api, workspace, scope, report);
        report.Summary.RunMode = scope.Mode;
        report.Summary.Seed = scope.Seed;
        report.Summary.ScopeState = scope.ScopeState;
        WritePhase(options, report, "project scope", phaseTimer.Elapsed,
            $"{scope.Mode}; {packets.Count(p => p.Selected)}/{packets.Count} packet(s)");

        // Append-only packet selection status on stderr keeps the single-document JSON stdout clean
        // while still giving a live view of which project packet is active (Phase 11 heartbeats).
        var selectedPackets = packets.Where(p => p.Selected).ToList();
        if (!options.QuietProgress)
        {
            for (var pi = 0; pi < selectedPackets.Count; pi++)
            {
                var pkt = selectedPackets[pi];
                Console.Error.WriteLine($"[ ] project {pi + 1}/{selectedPackets.Count} | {pkt.Project.AssemblyName} | scope={scope.Mode} | {pkt.Targets.Count} target(s){(pkt.SharedNamespaces.Count > 0 ? $" | shared:{string.Join(",", pkt.SharedNamespaces)}" : string.Empty)}");
            }
        }

        // 7. Validate namespace overview pages, extension tables and availability.
        phaseTimer.Restart();
        var proseFingerprints = new List<(string Namespace, string Path, string Fingerprint)>();
        var globalExtensionMethodBaseNames = new HashSet<string>(
            api.Namespaces.SelectMany(n => n.ExtensionMethods).Select(method => method.MethodName),
            StringComparer.Ordinal);
        foreach (var ns in api.Namespaces.OrderBy(n => n.Name, StringComparer.Ordinal))
        {
            if (!scope.IncludesNamespace(ns.Name))
            {
                continue;
            }

            namespacePageIndex.TryGetValue(ns.Name, out var page);
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

            ValidateNamespacePage(repoRoot, page, workspace.ReadMarkdown(page), ns, report, proseFingerprints, globalExtensionMethodBaseNames);
            report.Summary.NamespacePagesValidated++;
        }

        ValidateNamespaceProseRepetition(proseFingerprints, report);

        WritePhase(options, report, "namespace validation", phaseTimer.Elapsed);

        // 7b. Detect xref member/method links that render as broken links outside a DocFX build.
        phaseTimer.Restart();
        ValidateXrefMemberLinks(repoRoot, markdownFiles, workspace,
            ReadDocfxSiteBaseUrl(docfxPath), api, apiModelSource, report);
        WritePhase(options, report, "xref link validation", phaseTimer.Elapsed);

        // 8. Verify mandatory examples exist before compiling the examples that were found.
        phaseTimer.Restart();
        ValidateRequiredExamples(repoRoot, docfxWorkspace, allOverwriteSections, api, options, changedFiles, scope, workspace.NamespaceProjects, report);
        WritePhase(options, report, "required example validation", phaseTimer.Elapsed);

        // 9. Extract and compile C# documentation samples (opt-in: the only path that compiles).
        if (options.ValidateSamples)
        {
            ValidateSamples(workspace, options, changedFiles, hasStrongNameKey, execution.SampleParallelism, report);
        }
        else
        {
            WriteSkippedPhase(options, report, "sample validation", "pass --validate-samples to compile");
        }

        // Optional DocFX build verification happens in a temp copy so generated output never lands in the working tree.
        if (options.VerifyDocfxBuild)
        {
            var result = concurrentDocfxTask is null
                ? VerifyDocfxBuild(repoRoot, docfxPath, hasStrongNameKey, CancellationToken.None)
                : concurrentDocfxTask.GetAwaiter().GetResult();
            MergeDocfxVerification(result, docfxPath, report);
            WritePhase(options, report, "docfx build verification", result.Elapsed,
                concurrentDocfxTask is null ? "sequential" : "concurrent lane");
            concurrentDocfxCancellation?.Dispose();
        }

        // Optional GitHub example search to embed real usage snippets in the assessment work queue.
        if (options.SearchExamples && report.PackageIds.Count > 0)
        {
            phaseTimer.Restart();
            SearchGitHubForExamples(report.PackageIds, report);
            WritePhase(options, report, "github example search", phaseTimer.Elapsed);
        }

        // 10. Optional generated-metadata cleanup. Opt-in only, and only after the API model has
        //     been built so we never delete YAML the fast path may have relied on.
        if (options.CleanGeneratedMetadata)
        {
            phaseTimer.Restart();
            CleanupGeneratedMetadata(repoRoot, docfxPath, docfxWorkspace, options, report);
            WritePhase(options, report, "generated metadata cleanup", phaseTimer.Elapsed);
        }

        // 11. Produce report and return a deterministic exit code.
        if (options.ResumeProjectManifestPath is not null)
        {
            ValidateChangedPageReview(options.ReviewReportPath, repoRoot, packets, gitState, report);
        }

        report.Scope = BuildScopeReport(scope, packets, metadataGroups, gitState, families, repoRoot, report);
        if (options.ProjectManifestPath is not null)
        {
            try
            {
                WriteProjectManifest(options.ProjectManifestPath, repoRoot, docfxPath, report.Scope,
                    report.Summary.ApiModelSource ?? "unknown", report);
            }
            catch (Exception ex)
            {
                report.Warnings.Add(new Diagnostic("PROJECT_MANIFEST_WRITE_FAILED", options.ProjectManifestPath, null,
                    $"Unable to write the project manifest: {ex.Message}"));
            }
        }

        bool hasSampleError = report.Errors.Any(e => e.Code is "SAMPLE_COMPILE_FAILED" or "SAMPLE_STRUCTURE_INVALID");
        bool hasOtherError = report.Errors.Any(e => e.Code is not "SAMPLE_COMPILE_FAILED" and not "SAMPLE_STRUCTURE_INVALID");

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
        catch
        {
            CancelConcurrentDocfxVerification(concurrentDocfxTask, concurrentDocfxCancellation);
            throw;
        }
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

        return null;
    }

    /// <summary>
    /// Reads the deployed site base URL from <c>build.sitemap.baseUrl</c> in the DocFX configuration.
    /// Returns <see langword="null"/> when the property is absent or the file cannot be read.
    /// </summary>
    private static string? ReadDocfxSiteBaseUrl(string docfxPath)
    {
        try
        {
            using var doc = JsonDocument.Parse(File.ReadAllText(docfxPath), new JsonDocumentOptions
            {
                AllowTrailingCommas = true,
                CommentHandling = JsonCommentHandling.Skip
            });

            if (!doc.RootElement.TryGetProperty("build", out var build) || build.ValueKind != JsonValueKind.Object)
            {
                return null;
            }

            if (!build.TryGetProperty("sitemap", out var sitemap) || sitemap.ValueKind != JsonValueKind.Object)
            {
                return null;
            }

            if (sitemap.TryGetProperty("baseUrl", out var baseUrl) && baseUrl.ValueKind == JsonValueKind.String)
            {
                var url = baseUrl.GetString()?.Trim().TrimEnd('/');
                return string.IsNullOrEmpty(url) ? null : url;
            }
        }
        catch
        {
            // Best-effort: site URL is optional guidance for diagnostic messages.
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
            if (contentFiles.Any(pattern => DocfxPatternEquals(pattern, "api/**/*.md") || DocfxPatternEquals(pattern, "api/namespaces/**/*.md") || DocfxPatternEquals(pattern, "api/types/**/*.md")))
            {
                configProblems.Add("Do not include `api/**/*.md`, `api/namespaces/**/*.md`, or `api/types/**/*.md` under `build.content`.");
            }

            if (!contentExclude.Any(pattern => DocfxPatternEquals(pattern, "api/namespaces/**")))
            {
                configProblems.Add(DescribeMissingDocfxPattern(contentExclude, "api/namespaces/**",
                    "build.content exclusions", "Add"));
            }

            if (!contentExclude.Any(pattern => DocfxPatternEquals(pattern, "api/types/**")))
            {
                configProblems.Add(DescribeMissingDocfxPattern(contentExclude, "api/types/**",
                    "build.content exclusions", "Add"));
            }

            if (!overwriteFiles.Any(pattern => DocfxPatternEquals(pattern, "api/namespaces/**/*.md")))
            {
                configProblems.Add(DescribeMissingDocfxPattern(overwriteFiles, "api/namespaces/**/*.md",
                    "build.overwrite", "Include"));
            }

            if (!overwriteFiles.Any(pattern => DocfxPatternEquals(pattern, "api/types/**/*.md")))
            {
                configProblems.Add(DescribeMissingDocfxPattern(overwriteFiles, "api/types/**/*.md",
                    "build.overwrite", "Include"));
            }

            if (overwriteFiles.Any(pattern => DocfxPatternEquals(pattern, "api/**/*.md")))
            {
                configProblems.Add("Do not include `api/**/*.md` under `build.overwrite`.");
            }

            if (configProblems.Count > 0)
            {
                report.Errors.Add(new Diagnostic("API_OVERWRITE_CONFIG_INVALID", docfxPath, null,
                    $"DocFX API overwrite Markdown must use separate namespace and type subdirectories so overwrite content merges into managed API pages without being treated as normal content. Pattern checks use normalized literal equality after trimming and slash normalization; near-miss globs do not count. {string.Join(" ", configProblems)}"));
            }
        }

        if (!Directory.Exists(apiDirectory))
        {
            return;
        }

        var typesDirectory = Path.Combine(apiDirectory, "types");
        foreach (var file in Directory.EnumerateFiles(apiDirectory, "*.md", SearchOption.TopDirectoryOnly)
                     .Where(path => !string.Equals(Path.GetFileName(path), "toc.md", StringComparison.OrdinalIgnoreCase)))
        {
            report.Errors.Add(new Diagnostic("API_OVERWRITE_FILE_MISPLACED", file, null,
                $"Authored API overwrite Markdown must not live directly under `{Rel(repoRoot, apiDirectory)}`. Move namespace overwrite files to `{Rel(repoRoot, namespacesDirectory)}` and type overwrite files to `{Rel(repoRoot, typesDirectory)}`. Preserve YAML front matter and Markdown content. Do not move generated `.yml` metadata files."));
        }

        foreach (var file in EnumerateFiles(apiDirectory, "*.md")
                     .Where(path => !string.Equals(Path.GetFileName(path), "toc.md", StringComparison.OrdinalIgnoreCase) &&
                                    ContainsSyntheticExtensionBlockUidMarker(Path.GetFileNameWithoutExtension(path))))
        {
            report.Errors.Add(new Diagnostic("API_OVERWRITE_SYNTHETIC_UID_FILENAME", file, NamespaceFromUid(Path.GetFileNameWithoutExtension(file)),
                $"Authored API overwrite Markdown must not mirror a compiler-generated C# extension-block UID in `{Rel(repoRoot, file)}`. Move the content to the readable declaring-class overwrite file under `api/types/` and let the YAML `uid` target the generated model when needed."));
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

    private static string DescribeMissingDocfxPattern(IReadOnlyCollection<string> actualPatterns, string expected, string location, string verb)
    {
        var message = $"{verb} `{expected}` under `{location}`.";
        var nearMisses = actualPatterns
            .Select(NormalizeDocfxPattern)
            .Where(pattern => LooksLikeDocfxPatternNearMiss(pattern, expected))
            .Distinct(StringComparer.OrdinalIgnoreCase)
            .Take(3)
            .ToList();

        if (nearMisses.Count == 0)
        {
            return message;
        }

        return message + $" Closest configured pattern(s): {string.Join(", ", nearMisses.Select(p => $"`{p}`"))}.";
    }

    private static bool LooksLikeDocfxPatternNearMiss(string actual, string expected)
    {
        if (string.IsNullOrWhiteSpace(actual))
        {
            return false;
        }

        var expectedSegment = expected.Contains("api/namespaces/", StringComparison.OrdinalIgnoreCase)
            ? "api/namespaces/"
            : expected.Contains("api/types/", StringComparison.OrdinalIgnoreCase)
                ? "api/types/"
                : expected.Contains("api/", StringComparison.OrdinalIgnoreCase)
                    ? "api/"
                    : expected;

        return actual.Contains(expectedSegment, StringComparison.OrdinalIgnoreCase) ||
               LevenshteinDistance(actual, expected) <= 3;
    }

    private static int LevenshteinDistance(string left, string right)
    {
        var previous = new int[right.Length + 1];
        var current = new int[right.Length + 1];
        for (var j = 0; j <= right.Length; j++)
        {
            previous[j] = j;
        }

        for (var i = 1; i <= left.Length; i++)
        {
            current[0] = i;
            for (var j = 1; j <= right.Length; j++)
            {
                var cost = char.ToUpperInvariant(left[i - 1]) == char.ToUpperInvariant(right[j - 1]) ? 0 : 1;
                current[j] = Math.Min(
                    Math.Min(current[j - 1] + 1, previous[j] + 1),
                    previous[j - 1] + cost);
            }

            (previous, current) = (current, previous);
        }

        return previous[right.Length];
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

    private static DocfxVerificationResult VerifyDocfxBuild(
        string repoRoot, string docfxPath, bool hasStrongNameKey, CancellationToken cancellationToken)
    {
        var stopwatch = Stopwatch.StartNew();
        var docfxExecutable = ResolveDocfxExecutable();
        if (docfxExecutable is null)
        {
            return new DocfxVerificationResult(false,
                "Unable to find the DocFX CLI on PATH. Install the docfx .NET tool or make docfx.exe available on PATH.",
                stopwatch.Elapsed);
        }

        var tempRoot = Path.Combine(Path.GetTempPath(), "docfx-digest-build-" + Guid.NewGuid().ToString("N"));
        try
        {
            CopyDirectory(repoRoot, tempRoot, cancellationToken);
            var relativeDocfxPath = Path.GetRelativePath(repoRoot, docfxPath);
            var tempDocfxPath = Path.Combine(tempRoot, relativeDocfxPath);
            var environment = hasStrongNameKey
                ? null
                : new Dictionary<string, string> { ["SkipSignAssembly"] = "true" };
            var result = RunProcess(docfxExecutable, $"\"{tempDocfxPath}\"", tempRoot, environment,
                ProcessPermission.DocfxBuild, cancellationToken,
                new ProcessProgress("DocFX build", "isolated temp workspace"));
            if (result.ExitCode != 0)
            {
                return new DocfxVerificationResult(false,
                    $"DocFX build failed in a temp workspace (exit {result.ExitCode}).\n{Trim(result.StdOut + result.StdErr)}",
                    stopwatch.Elapsed, result.ExitCode == -2);
            }

            return new DocfxVerificationResult(true, null, stopwatch.Elapsed);
        }
        catch (OperationCanceledException)
        {
            return new DocfxVerificationResult(false, "DocFX build verification was cancelled.", stopwatch.Elapsed, true);
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
        {
            return new DocfxVerificationResult(false,
                $"Unable to verify DocFX build in a temp workspace: {ex.Message}", stopwatch.Elapsed);
        }
        finally
        {
            TryDeleteDirectory(tempRoot);
        }
    }

    private static void MergeDocfxVerification(DocfxVerificationResult result, string docfxPath, Report report)
    {
        if (result.Success)
        {
            report.Summary.DocfxBuildsVerified++;
            return;
        }

        if (!result.Cancelled)
        {
            report.Errors.Add(new Diagnostic("DOCFX_BUILD_FAILED", docfxPath, null,
                result.Error ?? "DocFX build verification failed."));
        }
    }

    private static void CancelConcurrentDocfxVerification(
        Task<DocfxVerificationResult>? task, CancellationTokenSource? cancellation)
    {
        if (task is null || cancellation is null)
        {
            return;
        }

        try
        {
            cancellation.Cancel();
        }
        catch (ObjectDisposedException)
        {
            return;
        }
        try
        {
            task.GetAwaiter().GetResult();
        }
        catch (OperationCanceledException)
        {
            // Expected when the primary validation lane fails before final verification can complete.
        }
        finally
        {
            cancellation.Dispose();
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

    private static void CopyDirectory(
        string sourceDirectory, string destinationDirectory, CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        Directory.CreateDirectory(destinationDirectory);

        foreach (var file in Directory.GetFiles(sourceDirectory))
        {
            cancellationToken.ThrowIfCancellationRequested();
            File.Copy(file, Path.Combine(destinationDirectory, Path.GetFileName(file)), overwrite: true);
        }

        foreach (var directory in Directory.GetDirectories(sourceDirectory))
        {
            var name = Path.GetFileName(directory);
            if (IgnoredDirectorySegments.Contains(name, StringComparer.OrdinalIgnoreCase))
            {
                continue;
            }

            CopyDirectory(directory, Path.Combine(destinationDirectory, name), cancellationToken);
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
    // File encoding validation
    // ----------------------------------------------------------------------

    private static void ValidateDocumentationEncoding(string repoRoot, List<string> markdownFiles, Report report)
    {
        foreach (var file in markdownFiles)
        {
            byte[] bytes;
            try
            {
                bytes = File.ReadAllBytes(file);
            }
            catch
            {
                continue;
            }

            if (bytes.Length == 0)
            {
                continue;
            }

            var rel = Rel(repoRoot, file);

            // Check for double-encoded UTF-8 sequences (mojibake).
            // The most reliable indicator for Codebelt documentation files is C3 A2 C2 AC:
            // the UTF-8 re-encoding of 'â' (U+00E2) followed by '¬' (U+00AC), which is what
            // U+2B07 ⬇ (UTF-8: E2 AC 87) looks like after a Windows-1252 round-trip.
            if (HasMojibakePattern(bytes))
            {
                report.Errors.Add(new Diagnostic("ENCODING_CORRUPTION", rel, null,
                    $"File contains double-encoded UTF-8 sequences (mojibake). Multi-byte characters such as ⬇️ " +
                    $"were likely written through a PowerShell Get-Content/Set-Content round-trip, which re-encodes " +
                    $"UTF-8 bytes through Windows-1252. Restore: `git checkout HEAD -- {rel}` if the committed " +
                    $"version was correct. To add or rewrite content safely, use the edit tool or byte-level operations: " +
                    $"[System.IO.File]::WriteAllBytes($path, ...). Never use Get-Content + [System.Text.Encoding]::UTF8.GetBytes()."));
            }

        }
    }

    private static bool HasMojibakePattern(byte[] bytes)
    {
        // C3 A2 C2 AC is the UTF-8 encoding of â (U+00E2) followed by ¬ (U+00AC).
        // This sequence is the mojibake fingerprint of U+2B07 (⬇, UTF-8: E2 AC 87) after a
        // Windows-1252 round-trip: E2→â→C3A2, AC→¬→C2AC. Highly specific to the Extension
        // Members table arrow emoji and unlikely to appear legitimately in .NET API documentation.
        for (int i = 0; i + 3 < bytes.Length; i++)
        {
            if (bytes[i] == 0xC3 && bytes[i + 1] == 0xA2 && bytes[i + 2] == 0xC2 && bytes[i + 3] == 0xAC)
            {
                return true;
            }
        }

        return false;
    }

    /// <summary>
    /// Restores and builds only the library projects referenced by the active docfx.json.
    /// A single temporary <c>.slnx</c> graph build is preferred so the whole documented
    /// dependency graph is restored and compiled in one pass instead of N per-project builds,
    /// and the unrelated remainder of a large product solution is never built. Only reached
    /// when the caller passes <c>--build-api-model</c>.
    /// </summary>
    private static (bool Ok, string Output) BuildDocfxProjects(
        List<ProjectInfo> libraryProjects, string repoRoot, string configuration, bool hasStrongNameKey,
        int parallelism)
    {
        if (libraryProjects.Count == 0)
        {
            return (true, string.Empty);
        }

        var signingProperty = hasStrongNameKey ? string.Empty : " -p:SkipSignAssembly=true";

        // Build the documented projects through a temporary .slnx so MSBuild restores and
        // compiles the documented dependency graph in a single pass. This keeps the build
        // scoped to docfx.json inputs and avoids building the entire product solution.
        var tempSolution = Path.Combine(Path.GetTempPath(), "docfx-digest-build-" + Guid.NewGuid().ToString("N") + ".slnx");
        try
        {
            var sln = new StringBuilder();
            sln.AppendLine("<Solution>");
            foreach (var proj in libraryProjects)
            {
                sln.AppendLine($"  <Project Path=\"{proj.Path}\" />");
            }

            sln.AppendLine("</Solution>");
            File.WriteAllText(tempSolution, sln.ToString(), new UTF8Encoding(false));

            var result = RunProcess("dotnet",
                $"build \"{tempSolution}\" -c {configuration} --nologo -m:{parallelism}{signingProperty}", repoRoot,
                permission: ProcessPermission.BuildApiModel,
                progress: new ProcessProgress("API build",
                    $"{libraryProjects.Count} project(s), {parallelism} runner(s)"));
            if (result.ExitCode != 0)
            {
                return (false, result.StdOut + result.StdErr);
            }

            return (true, result.StdOut + result.StdErr);
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
        {
            return (false, $"Unable to prepare a scoped build solution: {ex.Message}");
        }
        finally
        {
            try
            {
                if (File.Exists(tempSolution))
                {
                    File.Delete(tempSolution);
                }
            }
            catch
            {
                // best effort
            }
        }
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

    /// <summary>
    /// Resolves the candidate project list exclusively from the active <c>docfx.json</c>
    /// metadata configuration.  Only <c>.csproj</c> files matched by a
    /// <c>metadata[].src[].files</c> include pattern and not excluded by a corresponding
    /// <c>exclude</c> pattern are returned.  Paths are resolved relative to the
    /// <c>docfx.json</c> file location, de-duplicated, and sorted by normalised full path
    /// for deterministic ordering.
    /// </summary>
    private static List<ProjectInfo> DiscoverProjects(string docfxPath, string docfxWorkspace, Report report)
        => DiscoverProjects(docfxPath, docfxWorkspace, report, out _);

    private static List<ProjectInfo> DiscoverProjects(string docfxPath, string docfxWorkspace, Report report,
        out List<MetadataGroupInfo> groups)
    {
        groups = new List<MetadataGroupInfo>();
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
            report.Errors.Add(new Diagnostic("PROJECT_DISCOVERY_FAILED", docfxPath, null,
                $"Unable to read docfx.json at '{docfxPath}' for project discovery: {ex.Message}"));
            return new List<ProjectInfo>();
        }

        var resolvedPaths = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        var resolvedProjects = new List<(string NormalizedPath, ProjectInfo Project)>();
        var groupsByDest = new Dictionary<string, MetadataGroupInfo>(StringComparer.OrdinalIgnoreCase);

        using (doc)
        {
            if (!doc.RootElement.TryGetProperty("metadata", out var metadata))
            {
                report.Errors.Add(new Diagnostic("PROJECT_DISCOVERY_FAILED", docfxPath, null,
                    $"docfx.json at '{docfxPath}' has no 'metadata' section. " +
                    "Cannot determine which projects are included in the documentation surface."));
                return new List<ProjectInfo>();
            }

            var metadataIndex = -1;
            foreach (var entry in EnumerateMetadataEntries(metadata))
            {
                metadataIndex++;
                if (entry.ValueKind != JsonValueKind.Object || !entry.TryGetProperty("src", out var srcArray))
                {
                    continue;
                }

                // A metadata destination ("dest", default "api") defines a sampling group. Every
                // src.files mapping feeding that destination belongs to it; distinct destinations
                // are never collapsed into one ownership-free list.
                var dest = entry.TryGetProperty("dest", out var destEl) && destEl.ValueKind == JsonValueKind.String &&
                           !string.IsNullOrWhiteSpace(destEl.GetString())
                    ? NormalizeDocfxPath(destEl.GetString()!.Trim())
                    : "api";
                if (!groupsByDest.TryGetValue(dest, out var group))
                {
                    group = new MetadataGroupInfo(dest, metadataIndex, dest);
                    groupsByDest[dest] = group;
                    groups.Add(group);
                }

                if (entry.TryGetProperty("properties", out var props) && props.ValueKind == JsonValueKind.Object)
                {
                    foreach (var prop in props.EnumerateObject())
                    {
                        if (prop.Value.ValueKind == JsonValueKind.String)
                        {
                            group.Properties[prop.Name] = prop.Value.GetString() ?? string.Empty;
                        }
                    }
                }

                foreach (var srcEntry in EnumerateDocfxFileMappingEntries(srcArray))
                {
                    // Default base directory is the docfx.json workspace; overridden by src[].src.
                    var baseDir = docfxWorkspace;
                    var includePatterns = new List<string>();
                    var excludePatterns = new List<string>();

                    if (srcEntry.ValueKind == JsonValueKind.String)
                    {
                        includePatterns.Add(srcEntry.GetString() ?? string.Empty);
                    }
                    else if (srcEntry.ValueKind == JsonValueKind.Object)
                    {
                        if (srcEntry.TryGetProperty("src", out var srcBase) &&
                            srcBase.ValueKind == JsonValueKind.String &&
                            !string.IsNullOrWhiteSpace(srcBase.GetString()))
                        {
                            baseDir = Path.GetFullPath(srcBase.GetString()!, docfxWorkspace);
                        }

                        if (srcEntry.TryGetProperty("files", out var files))
                        {
                            includePatterns.AddRange(ReadDocfxGlobPatterns(files));
                        }

                        if (srcEntry.TryGetProperty("exclude", out var exclude))
                        {
                            excludePatterns.AddRange(ReadDocfxGlobPatterns(exclude));
                        }
                    }

                    foreach (var projectPath in ResolveCsprojGlobPatterns(baseDir, includePatterns, excludePatterns))
                    {
                        var normalizedPath = Path.GetFullPath(projectPath);
                        if (resolvedPaths.Add(normalizedPath))
                        {
                            resolvedProjects.Add((normalizedPath, ReadProject(normalizedPath)));
                        }

                        if (!group.ProjectPaths.Contains(normalizedPath, StringComparer.OrdinalIgnoreCase))
                        {
                            group.ProjectPaths.Add(normalizedPath);
                        }
                    }
                }
            }
        }

        if (resolvedProjects.Count == 0)
        {
            report.Errors.Add(new Diagnostic("PROJECT_DISCOVERY_FAILED", docfxPath, null,
                $"No projects were resolved from docfx.json at '{docfxPath}'. " +
                "Review the metadata[].src[].files and metadata[].src[].exclude configuration to ensure " +
                "it resolves to .csproj files in this repository. Projects not referenced by the active " +
                "docfx.json metadata configuration are intentionally excluded."));
            return new List<ProjectInfo>();
        }

        foreach (var group in groups)
        {
            group.ProjectPaths.Sort((a, b) => string.Compare(NormalizeDocfxPath(a), NormalizeDocfxPath(b), StringComparison.OrdinalIgnoreCase));
        }

        groups.Sort((a, b) => string.Compare(a.Dest, b.Dest, StringComparison.OrdinalIgnoreCase));

        // Sort by normalised path for deterministic, idempotent ordering.
        return resolvedProjects
            .OrderBy(p => NormalizeDocfxPath(p.NormalizedPath), StringComparer.OrdinalIgnoreCase)
            .Select(p => p.Project)
            .ToList();
    }

    /// <summary>
    /// Resolves <c>.csproj</c> files from <paramref name="srcRoot"/> using DocFX-style glob
    /// <paramref name="includePatterns"/>, excluding paths matched by
    /// <paramref name="excludePatterns"/>. All patterns are resolved relative to
    /// <paramref name="srcRoot"/> and converted to case-insensitive regular expressions using
    /// the same <see cref="GlobToRegex"/> logic used for Markdown inputs.
    /// </summary>
    private static IEnumerable<string> ResolveCsprojGlobPatterns(
        string srcRoot,
        IEnumerable<string> includePatterns,
        IEnumerable<string> excludePatterns)
    {
        var excludes = excludePatterns
            .Where(p => !string.IsNullOrWhiteSpace(p))
            .Select(GlobToRegex)
            .ToList();

        foreach (var pattern in includePatterns)
        {
            if (string.IsNullOrWhiteSpace(pattern))
            {
                continue;
            }

            var searchRoot = ResolveGlobSearchRoot(srcRoot, pattern);

            if (!Directory.Exists(searchRoot))
            {
                // May be an exact path rather than a glob.
                var exactFile = Path.GetFullPath(pattern, srcRoot);
                if (File.Exists(exactFile) &&
                    string.Equals(Path.GetExtension(exactFile), ".csproj", StringComparison.OrdinalIgnoreCase))
                {
                    var rel = NormalizeDocfxPath(Path.GetRelativePath(srcRoot, exactFile));
                    if (!excludes.Any(excl => excl.IsMatch(rel)))
                    {
                        yield return exactFile;
                    }
                }

                continue;
            }

            var includeRegex = GlobToRegex(pattern);
            foreach (var file in EnumerateFiles(searchRoot, "*.csproj"))
            {
                var relative = NormalizeDocfxPath(Path.GetRelativePath(srcRoot, file));
                if (includeRegex.IsMatch(relative) && !excludes.Any(excl => excl.IsMatch(relative)))
                {
                    yield return Path.GetFullPath(file);
                }
            }
        }
    }

    private static ProjectInfo ReadProject(string projectPath)
    {
        string? assemblyName = null;
        string? packageId = null;
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
                    case "PackageId":
                        if (!string.IsNullOrWhiteSpace(el.Value))
                        {
                            packageId = el.Value.Trim();
                        }

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

        return new ProjectInfo(projectPath, assemblyName, tfms, isTest, packageId);
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
            AddProjectOutputResolverPaths(proj, configuration, framework, resolverPaths);

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

                // Track synthetic C# 14 extension-block containers so we can warn about DocFX #11010.
                if (IsSyntheticExtensionBlockContainer(type))
                {
                    info.HasCSharp14ExtensionBlocks = true;
                }

                CollectApiTargets(type, info);
                CollectExtensionMethods(type, info);
            }
        }

        AddExtensionBlockWarnings(namespaces.Values, report);

        var requiredExampleTargets = namespaces.Values
            .SelectMany(ns => ns.RequiredExampleTargets)
            .OrderBy(t => t.Uid, StringComparer.Ordinal)
            .ToList();

        return new ApiModel(namespaces.Values.ToList(), requiredExampleTargets);
    }

    // ----------------------------------------------------------------------
    // No-build API model (YAML metadata + source scanner)
    // ----------------------------------------------------------------------

    private static readonly string[] YamlTypeKinds = ["Class", "Struct", "Interface", "Enum", "Delegate"];

    /// <summary>
    /// Builds the API model without compiling. Prefers existing DocFX ManagedReference YAML under
    /// the configured metadata destinations; falls back to a conservative source scan of the
    /// projects referenced by <c>docfx.json</c>. Never builds, restores, or deletes YAML.
    /// </summary>
    private static ApiModel BuildNoBuildApiModel(ValidationWorkspace ws, Report report, out ApiModelSource source)
    {
        var yaml = DiscoverApiFromYaml(ws, report);
        if (yaml is not null && yaml.Namespaces.Count > 0)
        {
            source = ApiModelSource.DocfxYaml;
            return yaml;
        }

        source = ApiModelSource.SourceScan;
        report.Warnings.Add(new Diagnostic("API_MODEL_SOURCE_SCANNER_LIMITED", null, null,
            "Fast source-based API discovery is conservative and may miss generic, nested, or conditionally compiled members. Run with --build-api-model for reflection-backed validation."));
        return DiscoverApiFromSource(ws, report);
    }

    private static ApiModel? DiscoverApiFromYaml(ValidationWorkspace ws, Report report)
    {
        var yamlFiles = new List<string>();
        foreach (var dest in ResolveMetadataDestinations(ws.DocfxPath, ws.DocfxWorkspace, report)
                     .Distinct(StringComparer.OrdinalIgnoreCase))
        {
            if (!Directory.Exists(dest))
            {
                continue;
            }

            foreach (var file in EnumerateFiles(dest, "*.yml"))
            {
                if (string.Equals(Path.GetFileName(file), "toc.yml", StringComparison.OrdinalIgnoreCase))
                {
                    continue;
                }

                yamlFiles.Add(file);
            }
        }

        if (yamlFiles.Count == 0)
        {
            return null;
        }

        var namespaces = new Dictionary<string, NamespaceInfo>(StringComparer.Ordinal);
        var staticClassExtensionCounts = new Dictionary<string, (string Namespace, string DisplayName, int Count)>(StringComparer.Ordinal);
        var allItems = new List<YamlApiItem>();
        foreach (var file in yamlFiles.OrderBy(f => f, StringComparer.OrdinalIgnoreCase))
        {
            allItems.AddRange(ParseManagedReferenceItems(file));
        }

        var yamlTypeItemsByUid = allItems
            .Where(item => item.Type is not null && YamlTypeKinds.Contains(item.Type, StringComparer.OrdinalIgnoreCase))
            .GroupBy(item => item.Uid, StringComparer.Ordinal)
            .ToDictionary(group => group.Key, group => group.First(), StringComparer.Ordinal);

        var typeContextByUid = new Dictionary<string, (string Namespace, bool IsStatic)>(StringComparer.Ordinal);
        foreach (var item in allItems)
        {
            if (item.Type is null || !YamlTypeKinds.Contains(item.Type, StringComparer.OrdinalIgnoreCase))
            {
                continue;
            }

            var nsName = !string.IsNullOrEmpty(item.Namespace) ? item.Namespace! : NamespaceFromUid(item.Uid);
            if (string.IsNullOrEmpty(nsName))
            {
                continue;
            }

            var ns = GetOrAddNamespace(namespaces, nsName);
            if (TryGetCSharp14ExtensionBlockOwnerUid(item.Uid, yamlTypeItemsByUid, out _))
            {
                ns.HasCSharp14ExtensionBlocks = true;
                continue;
            }

            AddTypeUid(ns, item.Uid);
            var isStatic = Regex.IsMatch(item.Syntax, @"\bstatic\b");
            typeContextByUid[item.Uid] = (nsName, isStatic);

            if (isStatic && string.Equals(item.Type, "Class", StringComparison.OrdinalIgnoreCase))
            {
                staticClassExtensionCounts.TryAdd(item.Uid, (nsName, SimpleNameFromUid(item.Uid), 0));
            }
            else if (IsExampleRequiredKind(item.Type, item.Syntax))
            {
                AddTypeTarget(ns, item.Uid, nsName, SimpleNameFromUid(item.Uid));
            }
        }

        foreach (var item in allItems)
        {
            if (!string.Equals(item.Type, "Method", StringComparison.OrdinalIgnoreCase))
            {
                continue;
            }

            if (!TryParseExtensionSignature(item.Syntax, out var extendedType, out var methodName, out var methodDisplayName))
            {
                continue;
            }

            var declaringUid = !string.IsNullOrEmpty(item.Parent) ? item.Parent! : DeclaringTypeUidFromMethodUid(item.Uid);
            if (string.IsNullOrEmpty(declaringUid))
            {
                continue;
            }

            var hasSyntheticExtensionBlockOwner = TryGetCSharp14ExtensionBlockOwnerUid(declaringUid, yamlTypeItemsByUid, out var authoredDeclaringUid);
            if (hasSyntheticExtensionBlockOwner)
            {
                declaringUid = authoredDeclaringUid;
            }

            var nsName = typeContextByUid.TryGetValue(declaringUid, out var ctx) && !string.IsNullOrEmpty(ctx.Namespace)
                ? ctx.Namespace
                : (!string.IsNullOrEmpty(item.Namespace) ? item.Namespace! : NamespaceFromUid(declaringUid));
            if (string.IsNullOrEmpty(nsName))
            {
                continue;
            }

            var ns = GetOrAddNamespace(namespaces, nsName);
            if (hasSyntheticExtensionBlockOwner)
            {
                ns.HasCSharp14ExtensionBlocks = true;
            }

            var declaringClass = SimpleNameFromUid(declaringUid);
            AddExtensionMethod(ns, methodName, methodDisplayName, extendedType, declaringClass);
            AddExtensionTarget(ns, item.Uid, nsName, methodDisplayName, declaringUid);

            if (staticClassExtensionCounts.TryGetValue(declaringUid, out var sc))
            {
                staticClassExtensionCounts[declaringUid] = (sc.Namespace, sc.DisplayName, sc.Count + 1);
            }
        }

        // Static extension containers (static classes that declare extension methods) are
        // themselves documentation targets that require a type-level example, mirroring the
        // reflection-backed model.
        foreach (var (uid, info) in staticClassExtensionCounts)
        {
            if (info.Count > 0 && namespaces.TryGetValue(info.Namespace, out var ns))
            {
                AddTypeTarget(ns, uid, info.Namespace, info.DisplayName);
            }
        }

        AddExtensionBlockWarnings(namespaces.Values, report);

        if (namespaces.Count == 0)
        {
            return null;
        }

        var requiredExampleTargets = namespaces.Values
            .SelectMany(ns => ns.RequiredExampleTargets)
            .OrderBy(t => t.Uid, StringComparer.Ordinal)
            .ToList();

        return new ApiModel(namespaces.Values.ToList(), requiredExampleTargets);
    }

    private static ApiModel DiscoverApiFromSource(ValidationWorkspace ws, Report report)
    {
        var namespaces = new Dictionary<string, NamespaceInfo>(StringComparer.Ordinal);
        var staticExtensionContainers = new Dictionary<string, (string Namespace, string DisplayName, int Count)>(StringComparer.Ordinal);

        foreach (var project in ws.LibraryProjects)
        {
            foreach (var file in EnumerateProjectSourceFiles(project))
            {
                string text;
                try
                {
                    text = File.ReadAllText(file);
                }
                catch
                {
                    continue;
                }

                ScanSourceFile(text, namespaces, staticExtensionContainers, ws, project, report);
            }
        }

        foreach (var (key, info) in staticExtensionContainers)
        {
            if (info.Count > 0 && namespaces.TryGetValue(info.Namespace, out var ns))
            {
                AddTypeTarget(ns, key, info.Namespace, info.DisplayName);
            }
        }

        AddExtensionBlockWarnings(namespaces.Values, report);

        var requiredExampleTargets = namespaces.Values
            .SelectMany(ns => ns.RequiredExampleTargets)
            .OrderBy(t => t.Uid, StringComparer.Ordinal)
            .ToList();

        return new ApiModel(namespaces.Values.ToList(), requiredExampleTargets);
    }

    private static void ScanSourceFile(
        string text,
        Dictionary<string, NamespaceInfo> namespaces,
        Dictionary<string, (string Namespace, string DisplayName, int Count)> staticExtensionContainers,
        ValidationWorkspace ws,
        ProjectInfo project,
        Report report)
    {
        var lines = text.Replace("\r\n", "\n").Replace("\r", "\n").Split('\n');
        var cleaned = StripCommentsAndStrings(lines);

        string? currentNamespace = null;
        var namespaceBodyDepth = 0;
        var pendingNamespaceBrace = false;
        var depth = 0;
        string? currentTopLevelStaticClass = null;
        var currentTopLevelStaticClassDepth = -1;
        var currentStaticClassEntered = false;

        for (var i = 0; i < lines.Length; i++)
        {
            var clean = cleaned[i];

            var nsMatch = Regex.Match(clean, @"^\s*namespace\s+(?<ns>[\w.]+)\s*(?<brace>\{)?\s*(?<semi>;)?\s*$");
            if (nsMatch.Success)
            {
                currentNamespace = nsMatch.Groups["ns"].Value;
                RegisterNamespaceProject(ws, currentNamespace, project);
                GetOrAddNamespace(namespaces, currentNamespace);
                if (nsMatch.Groups["brace"].Success)
                {
                    // Block namespace whose opening brace is on the declaration line.
                    namespaceBodyDepth = depth + 1;
                    pendingNamespaceBrace = false;
                }
                else if (nsMatch.Groups["semi"].Success)
                {
                    // File-scoped namespace: the body shares the current brace depth.
                    namespaceBodyDepth = depth;
                    pendingNamespaceBrace = false;
                }
                else
                {
                    // Block namespace whose opening brace appears on a later line. Defer the
                    // body-depth decision until that brace is seen so the common Cuemon style
                    //     namespace Foo
                    //     {
                    // is not silently under-reported (the brace pushes real depth past a
                    // prematurely fixed namespaceBodyDepth, hiding every top-level type).
                    pendingNamespaceBrace = true;
                }

                depth += CountChar(clean, '{') - CountChar(clean, '}');
                continue;
            }

            if (pendingNamespaceBrace)
            {
                // Only trivia (comments, blank lines) is legal between a block namespace
                // declaration and its opening brace, so the first '{' opens the body.
                if (clean.IndexOf('{') >= 0)
                {
                    namespaceBodyDepth = depth + 1;
                    pendingNamespaceBrace = false;
                }

                depth += CountChar(clean, '{') - CountChar(clean, '}');
                continue;
            }

            if (currentNamespace is not null)
            {
                var isTopLevel = depth == namespaceBodyDepth;

                if (isTopLevel && Regex.IsMatch(clean, @"\bextension\s*\("))
                {
                    GetOrAddNamespace(namespaces, currentNamespace).HasCSharp14ExtensionBlocks = true;
                }

                var typeMatch = Regex.Match(clean,
                    @"(?<mods>(?:public|abstract|sealed|static|partial|readonly|unsafe|ref|\s)*)\b(?<kind>class|struct|interface|enum|record)\b(?:\s+(?<recstruct>struct|class))?\s+(?<name>\w+)(?<generic><[^>]*>)?");
                if (isTopLevel && typeMatch.Success && Regex.IsMatch(typeMatch.Groups["mods"].Value, @"\bpublic\b"))
                {
                    var ns = GetOrAddNamespace(namespaces, currentNamespace);
                    var name = typeMatch.Groups["name"].Value;
                    var arity = CountGenericArity(typeMatch.Groups["generic"].Value);
                    var uid = currentNamespace + "." + name + (arity > 0 ? "`" + arity : string.Empty);
                    var mods = typeMatch.Groups["mods"].Value;
                    var kind = typeMatch.Groups["kind"].Value;
                    var isStatic = Regex.IsMatch(mods, @"\bstatic\b");

                    AddTypeUid(ns, uid);
                    if (isStatic && string.Equals(kind, "class", StringComparison.Ordinal))
                    {
                        // Public static classes are valid non-abstraction documentation targets
                        // even when they are not extension containers.
                        AddTypeTarget(ns, uid, currentNamespace, name);
                        currentTopLevelStaticClass = uid;
                        currentTopLevelStaticClassDepth = depth;
                        currentStaticClassEntered = false;
                        staticExtensionContainers.TryAdd(uid, (currentNamespace, name, 0));
                    }
                    else if (IsExampleRequiredSourceKind(kind, mods))
                    {
                        AddTypeTarget(ns, uid, currentNamespace, name);
                    }
                }

                // Public delegate types are required example targets: a delegate is a public
                // non-abstraction type, and the source scanner must surface it the same way it
                // surfaces classes, structs, interfaces, enums, and records. C# syntax:
                //     public delegate ReturnType Name[<GenericArgs>](parameters);
                // The return type can be a simple identifier or a generic like IReadOnlyList<T>;
                // the optional generic argument list supports variance modifiers such as
                // `in T` / `out T`.
                var delegateMatch = Regex.Match(clean,
                    @"\bpublic\s+delegate\s+(?<return>.+?)\s+(?<name>\w+)\s*(?<generic><[^>]+>)?\s*\(");
                if (isTopLevel && delegateMatch.Success)
                {
                    var delegateNs = GetOrAddNamespace(namespaces, currentNamespace);
                    var delegateName = delegateMatch.Groups["name"].Value;
                    var delegateArity = CountGenericArity(delegateMatch.Groups["generic"].Value);
                    var delegateUid = currentNamespace + "." + delegateName + (delegateArity > 0 ? "`" + delegateArity : string.Empty);
                    AddTypeTarget(delegateNs, delegateUid, currentNamespace, delegateName);
                }

                // Classic extension methods inside the current top-level static class.
                if (currentTopLevelStaticClass is not null)
                {
                    if (TryParseExtensionSignature(clean, out var extendedType, out var methodName, out var methodDisplayName))
                    {
                        var ns = GetOrAddNamespace(namespaces, currentNamespace);
                        AddExtensionMethod(ns, methodName, methodDisplayName, extendedType, SimpleNameFromUid(currentTopLevelStaticClass));
                        AddExtensionTarget(ns, currentTopLevelStaticClass + "." + methodName, currentNamespace, methodDisplayName, currentTopLevelStaticClass);
                        if (staticExtensionContainers.TryGetValue(currentTopLevelStaticClass, out var sc))
                        {
                            staticExtensionContainers[currentTopLevelStaticClass] = (sc.Namespace, sc.DisplayName, sc.Count + 1);
                        }
                    }
                }
            }

            depth += CountChar(clean, '{') - CountChar(clean, '}');
            if (currentTopLevelStaticClass is not null)
            {
                if (depth > currentTopLevelStaticClassDepth)
                {
                    currentStaticClassEntered = true;
                }
                else if (currentStaticClassEntered && depth <= currentTopLevelStaticClassDepth)
                {
                    currentTopLevelStaticClass = null;
                    currentTopLevelStaticClassDepth = -1;
                    currentStaticClassEntered = false;
                }
            }
        }

        if (pendingNamespaceBrace && currentNamespace is not null)
        {
            // A block namespace declaration was never paired with an opening brace. Surface this
            // rather than silently under-reporting the file's public types.
            report.Warnings.Add(new Diagnostic("API_MODEL_SOURCE_SCANNER_INCOMPLETE", null, currentNamespace,
                $"Source scanner could not pair the block namespace declaration '{currentNamespace}' with an opening brace, so its public types may be under-reported. Confirm the documentation scope with a build-backed audit before authoring."));
        }
    }

    private static IEnumerable<string> EnumerateProjectSourceFiles(ProjectInfo project)
    {
        var projectDir = Path.GetDirectoryName(project.Path);
        if (string.IsNullOrEmpty(projectDir) || !Directory.Exists(projectDir))
        {
            yield break;
        }

        foreach (var file in EnumerateFiles(projectDir, "*.cs"))
        {
            var name = Path.GetFileName(file);
            if (name.EndsWith(".g.cs", StringComparison.OrdinalIgnoreCase) ||
                name.EndsWith(".Designer.cs", StringComparison.OrdinalIgnoreCase) ||
                name.Equals("AssemblyInfo.cs", StringComparison.OrdinalIgnoreCase) ||
                name.Equals("GlobalUsings.cs", StringComparison.OrdinalIgnoreCase))
            {
                continue;
            }

            yield return file;
        }
    }

    private static void EnsureNamespaceProjectMap(ValidationWorkspace ws)
    {
        if (ws.NamespaceProjects.Count > 0)
        {
            return;
        }

        foreach (var project in ws.LibraryProjects)
        {
            foreach (var file in EnumerateProjectSourceFiles(project))
            {
                string text;
                try
                {
                    text = File.ReadAllText(file);
                }
                catch
                {
                    continue;
                }

                foreach (Match m in Regex.Matches(text, @"(?m)^\s*namespace\s+(?<ns>[\w.]+)"))
                {
                    RegisterNamespaceProject(ws, m.Groups["ns"].Value, project);
                }
            }
        }
    }

    private static void RegisterNamespaceProject(ValidationWorkspace ws, string ns, ProjectInfo project)
    {
        if (string.IsNullOrEmpty(ns))
        {
            return;
        }

        if (!ws.NamespaceProjects.TryGetValue(ns, out var list))
        {
            list = new List<ProjectInfo>();
            ws.NamespaceProjects[ns] = list;
        }

        if (!list.Any(p => PathsEqual(p.Path, project.Path)))
        {
            list.Add(project);
        }
    }

    private static NamespaceInfo GetOrAddNamespace(Dictionary<string, NamespaceInfo> namespaces, string name)
    {
        if (!namespaces.TryGetValue(name, out var info))
        {
            info = new NamespaceInfo(name);
            namespaces[name] = info;
        }

        return info;
    }

    private static void AddExtensionBlockWarnings(IEnumerable<NamespaceInfo> namespaces, Report report)
    {
        foreach (var ns in namespaces.Where(n => n.HasCSharp14ExtensionBlocks))
        {
            report.Warnings.Add(new Diagnostic("DOCFX_EXTENSION_BLOCK_UNSUPPORTED", null, ns.Name,
                $"Namespace {ns.Name} contains C# 14 extension-block types. DocFX (issue #11010) does not currently generate correct API metadata for extension blocks, so generated UIDs for those members may be missing or synthetic. Classic static extension methods with 'this' parameters remain fully supported. Do not exclude these APIs or invent special rules; continue generating docs for all discoverable public APIs and document the limitation in the overwrite file when needed."));
        }
    }

    private static void AddTypeTarget(NamespaceInfo ns, string uid, string nsName, string displayName)
    {
        AddTypeUid(ns, uid);
        var target = new ApiTargetInfo(uid, nsName, ApiTargetKind.Type, displayName);
        if (!ns.RequiredExampleTargets.Contains(target))
        {
            ns.RequiredExampleTargets.Add(target);
        }
    }

    private static void AddTypeUid(NamespaceInfo ns, string uid)
    {
        if (!string.IsNullOrEmpty(uid))
        {
            ns.TypeUids.Add(uid);
        }
    }

    private static void AddExtensionTarget(NamespaceInfo ns, string uid, string nsName, string displayName, string declaringTypeUid)
    {
        var target = new ApiTargetInfo(uid, nsName, ApiTargetKind.ExtensionMethod, displayName, declaringTypeUid);
        if (!ns.RequiredExampleTargets.Contains(target))
        {
            ns.RequiredExampleTargets.Add(target);
        }
    }

    private static void AddExtensionMethod(NamespaceInfo ns, string methodName, string methodDisplayName, string extendedType, string declaringClass)
    {
        var info = new ExtensionMethodInfo(methodName, methodDisplayName, extendedType, declaringClass);
        if (!ns.ExtensionMethods.Contains(info))
        {
            ns.ExtensionMethods.Add(info);
        }
    }

    private static bool IsExampleRequiredKind(string yamlType, string syntax)
    {
        if (string.Equals(yamlType, "Interface", StringComparison.OrdinalIgnoreCase))
        {
            return false;
        }

        if (Regex.IsMatch(syntax, @"\bstatic\b"))
        {
            // Static containers are added separately only when they declare extension methods.
            return false;
        }

        if (Regex.IsMatch(syntax, @"\babstract\b"))
        {
            return false;
        }

        return true;
    }

    private static bool IsExampleRequiredSourceKind(string kind, string mods)
    {
        if (string.Equals(kind, "interface", StringComparison.Ordinal))
        {
            return false;
        }

        if (Regex.IsMatch(mods, @"\bstatic\b") || Regex.IsMatch(mods, @"\babstract\b"))
        {
            return false;
        }

        return true;
    }

    private static bool TryParseExtensionSignature(string syntax, out string extendedType, out string methodName, out string methodDisplayName)
    {
        extendedType = string.Empty;
        methodName = string.Empty;
        methodDisplayName = string.Empty;
        // Require 'public' as the leading visibility modifier so 'private', 'protected', and
        // 'internal' 'static' helpers with 'this' parameters are not surfaced as extension
        // methods. Implementation helpers in those visibility tiers are not part of the
        // documented public API and must not appear as required extension method targets.
        if (!Regex.IsMatch(syntax, @"\bpublic\s+([\w]+\s+)*?static\b"))
        {
            return false;
        }

        var m = Regex.Match(syntax,
            @"\bpublic\s+([\w]+\s+)*?static\b[^\r\n{;=]*?\b(?<name>\w+)\s*(?<generic><[^>(]*>)?\s*\(\s*(?:\[[^\]]*\]\s*)*this\s+(?<ext>.+?)\s+\w+\s*(?:,|\))");
        if (!m.Success)
        {
            return false;
        }

        methodName = m.Groups["name"].Value;
        methodDisplayName = ComposeMethodDisplayName(methodName, m.Groups["generic"].Value);
        extendedType = SimplifyTypeReference(m.Groups["ext"].Value);
        return true;
    }

    private static string ComposeMethodDisplayName(string methodName, string genericPart)
    {
        var normalizedGenericPart = NormalizeGenericArgumentList(genericPart);
        return normalizedGenericPart.Length == 0 ? methodName : methodName + normalizedGenericPart;
    }

    private static string NormalizeGenericArgumentList(string genericPart)
    {
        var trimmed = genericPart.Trim();
        if (trimmed.Length == 0)
        {
            return string.Empty;
        }

        if (!trimmed.StartsWith('<') || !trimmed.EndsWith('>'))
        {
            return trimmed;
        }

        var inner = trimmed[1..^1].Trim();
        if (inner.Length == 0)
        {
            return string.Empty;
        }

        var parts = SplitTopLevelCommaSeparated(inner)
            .Select(part => part.Trim())
            .Where(part => part.Length > 0)
            .ToList();
        return parts.Count == 0 ? string.Empty : "<" + string.Join(", ", parts) + ">";
    }

    private static List<string> SplitTopLevelCommaSeparated(string text)
    {
        var parts = new List<string>();
        var depth = 0;
        var start = 0;
        for (var i = 0; i < text.Length; i++)
        {
            var c = text[i];
            if (c == '<')
            {
                depth++;
            }
            else if (c == '>')
            {
                depth--;
            }
            else if (c == ',' && depth == 0)
            {
                parts.Add(text[start..i]);
                start = i + 1;
            }
        }

        parts.Add(text[start..]);
        return parts;
    }

    private static string SimplifyTypeReference(string typeRef)
    {
        var trimmed = typeRef.Trim();
        trimmed = Regex.Replace(trimmed, @"^(?:ref|in|out|scoped|params|readonly)\s+", string.Empty);
        trimmed = trimmed.Replace("global::", string.Empty, StringComparison.Ordinal);

        var arraySuffix = string.Empty;
        while (trimmed.EndsWith("[]", StringComparison.Ordinal))
        {
            arraySuffix += "[]";
            trimmed = trimmed[..^2].TrimEnd();
        }

        var nullableSuffix = string.Empty;
        if (trimmed.EndsWith("?", StringComparison.Ordinal))
        {
            nullableSuffix = "?";
            trimmed = trimmed[..^1].TrimEnd();
        }

        var genericStart = trimmed.IndexOf('<');
        if (genericStart >= 0)
        {
            var genericEnd = trimmed.LastIndexOf('>');
            if (genericEnd > genericStart)
            {
                var baseName = SimplifyTypeName(trimmed[..genericStart]);
                var inner = trimmed[(genericStart + 1)..genericEnd];
                var args = SplitTopLevelCommaSeparated(inner)
                    .Select(arg => SimplifyTypeReference(arg))
                    .ToList();
                return $"{baseName}<{string.Join(", ", args)}>{nullableSuffix}{arraySuffix}";
            }
        }

        return SimplifyTypeName(trimmed) + nullableSuffix + arraySuffix;
    }

    private static string SimplifyTypeName(string typeName)
    {
        var trimmed = typeName.Trim();
        var lastDot = trimmed.LastIndexOf('.');
        if (lastDot >= 0)
        {
            trimmed = trimmed[(lastDot + 1)..];
        }

        var tick = trimmed.IndexOf('`');
        if (tick >= 0)
        {
            trimmed = trimmed[..tick];
        }

        return trimmed switch
        {
            "bool" => "Boolean",
            "byte" => "Byte",
            "sbyte" => "SByte",
            "short" => "Int16",
            "ushort" => "UInt16",
            "int" => "Int32",
            "uint" => "UInt32",
            "long" => "Int64",
            "ulong" => "UInt64",
            "nint" => "IntPtr",
            "nuint" => "UIntPtr",
            "char" => "Char",
            "string" => "String",
            "object" => "Object",
            "decimal" => "Decimal",
            "float" => "Single",
            "double" => "Double",
            "void" => "Void",
            _ => trimmed
        };
    }

    private static string SimpleNameFromUid(string uid)
    {
        var beforeGeneric = uid;
        var tick = beforeGeneric.IndexOf('`');
        if (tick >= 0)
        {
            beforeGeneric = beforeGeneric[..tick];
        }

        var lastDot = beforeGeneric.LastIndexOf('.');
        return lastDot >= 0 ? beforeGeneric[(lastDot + 1)..] : beforeGeneric;
    }

    private static string NamespaceFromUid(string uid)
    {
        var lastDot = uid.LastIndexOf('.');
        return lastDot > 0 ? uid[..lastDot] : string.Empty;
    }

    private static string MethodNameFromUid(string methodUid)
    {
        var paren = methodUid.IndexOf('(');
        var head = paren >= 0 ? methodUid[..paren] : methodUid;
        return SimpleNameFromUid(head);
    }

    private static string DeclaringTypeUidFromMethodUid(string methodUid)
    {
        var paren = methodUid.IndexOf('(');
        var head = paren >= 0 ? methodUid[..paren] : methodUid;
        var lastDot = head.LastIndexOf('.');
        return lastDot > 0 ? head[..lastDot] : string.Empty;
    }

    private static bool TryGetCSharp14ExtensionBlockOwnerUid(string uid, IReadOnlyDictionary<string, YamlApiItem> yamlTypeItemsByUid, out string ownerUid)
    {
        ownerUid = string.Empty;

        var markerIndex = IndexOfSyntheticExtensionBlockUidMarker(uid);
        if (markerIndex <= 0)
        {
            return false;
        }

        var candidateOwnerUid = uid[..markerIndex];
        if (!yamlTypeItemsByUid.TryGetValue(candidateOwnerUid, out var ownerItem) ||
            !string.Equals(ownerItem.Type, "Class", StringComparison.OrdinalIgnoreCase) ||
            !Regex.IsMatch(ownerItem.Syntax, @"\bstatic\b"))
        {
            return false;
        }

        ownerUid = candidateOwnerUid;
        return true;
    }

    private static int IndexOfSyntheticExtensionBlockUidMarker(string value)
    {
        var match = SyntheticExtensionBlockUidMarkerRegex.Match(value);
        return match.Success ? match.Index : -1;
    }

    private static bool ContainsSyntheticExtensionBlockUidMarker(string value)
    {
        return SyntheticExtensionBlockUidMarkerRegex.IsMatch(value);
    }

    private static int CountGenericArity(string generic)
    {
        if (string.IsNullOrEmpty(generic))
        {
            return 0;
        }

        var inner = generic.Trim();
        if (inner.StartsWith('<') && inner.EndsWith('>'))
        {
            inner = inner[1..^1];
        }

        if (string.IsNullOrWhiteSpace(inner))
        {
            return 0;
        }

        var depth = 0;
        var count = 1;
        foreach (var c in inner)
        {
            if (c == '<')
            {
                depth++;
            }
            else if (c == '>')
            {
                depth--;
            }
            else if (c == ',' && depth == 0)
            {
                count++;
            }
        }

        return count;
    }

    private static int CountChar(string text, char c)
    {
        var count = 0;
        foreach (var ch in text)
        {
            if (ch == c)
            {
                count++;
            }
        }

        return count;
    }

    /// <summary>
    /// Returns a copy of <paramref name="lines"/> with line comments, block comments, and string
    /// and character literals blanked so brace counting and declaration matching ignore braces or
    /// keywords that appear inside comments or strings. Conservative, not a full C# lexer.
    /// </summary>
    private static string[] StripCommentsAndStrings(string[] lines)
    {
        var result = new string[lines.Length];
        var inBlockComment = false;
        for (var i = 0; i < lines.Length; i++)
        {
            var line = lines[i];
            var sb = new StringBuilder(line.Length);
            for (var j = 0; j < line.Length; j++)
            {
                var c = line[j];
                if (inBlockComment)
                {
                    if (c == '*' && j + 1 < line.Length && line[j + 1] == '/')
                    {
                        inBlockComment = false;
                        j++;
                    }

                    continue;
                }

                if (c == '/' && j + 1 < line.Length && line[j + 1] == '/')
                {
                    break;
                }

                if (c == '/' && j + 1 < line.Length && line[j + 1] == '*')
                {
                    inBlockComment = true;
                    j++;
                    continue;
                }

                if (c == '"')
                {
                    j = SkipStringLiteral(line, j);
                    sb.Append("\"\"");
                    continue;
                }

                if (c == '\'')
                {
                    j = SkipCharLiteral(line, j);
                    sb.Append("' '");
                    continue;
                }

                sb.Append(c);
            }

            result[i] = sb.ToString();
        }

        return result;
    }

    private static int SkipStringLiteral(string line, int start)
    {
        for (var j = start + 1; j < line.Length; j++)
        {
            if (line[j] == '\\')
            {
                j++;
                continue;
            }

            if (line[j] == '"')
            {
                return j;
            }
        }

        return line.Length - 1;
    }

    private static int SkipCharLiteral(string line, int start)
    {
        for (var j = start + 1; j < line.Length; j++)
        {
            if (line[j] == '\\')
            {
                j++;
                continue;
            }

            if (line[j] == '\'')
            {
                return j;
            }
        }

        return line.Length - 1;
    }

    private sealed record YamlApiItem(string Uid, string? Type, string? Namespace, string? Name, string? Parent, string Syntax);

    private static List<YamlApiItem> ParseManagedReferenceItems(string yamlFile)
    {
        string[] lines;
        try
        {
            lines = File.ReadAllLines(yamlFile);
        }
        catch
        {
            return new List<YamlApiItem>();
        }

        var items = new List<YamlApiItem>();
        var inItems = false;
        string? uid = null, type = null, ns = null, name = null, parent = null, syntax = null;

        void Flush()
        {
            if (uid is not null)
            {
                items.Add(new YamlApiItem(uid, type, ns, name, parent, syntax ?? string.Empty));
            }

            uid = type = ns = name = parent = syntax = null;
        }

        for (var i = 0; i < lines.Length; i++)
        {
            var line = lines[i];
            if (!inItems)
            {
                if (line.StartsWith("items:", StringComparison.Ordinal))
                {
                    inItems = true;
                }

                continue;
            }

            if (line.Length > 0 && line[0] != ' ' && line[0] != '-' && line[0] != '#')
            {
                // references: / shouldSkipMarkup: etc. — end of the items section.
                break;
            }

            var itemStart = Regex.Match(line, @"^- uid:\s*(.+?)\s*$");
            if (itemStart.Success)
            {
                Flush();
                uid = StripYamlScalar(itemStart.Groups[1].Value);
                continue;
            }

            if (uid is null)
            {
                continue;
            }

            var prop = Regex.Match(line, @"^  (?<key>[\w.]+):\s?(?<val>.*)$");
            if (prop.Success)
            {
                var key = prop.Groups["key"].Value;
                var val = prop.Groups["val"].Value;
                switch (key)
                {
                    case "type":
                        type ??= StripYamlScalar(val.Trim());
                        break;
                    case "namespace":
                        ns = StripYamlScalar(val.Trim());
                        break;
                    case "name":
                        name ??= StripYamlScalar(val.Trim());
                        break;
                    case "parent":
                        parent = StripYamlScalar(val.Trim());
                        break;
                }

                continue;
            }

            var content = Regex.Match(line, @"^    content:\s?(?<val>.*)$");
            if (content.Success && syntax is null)
            {
                var val = content.Groups["val"].Value.Trim();
                if (val.Length == 0 || val is ">" or ">-" or ">+" or "|" or "|-" or "|+")
                {
                    var sb = new StringBuilder();
                    var j = i + 1;
                    while (j < lines.Length)
                    {
                        var bl = lines[j];
                        if (bl.Trim().Length == 0)
                        {
                            j++;
                            continue;
                        }

                        var indent = bl.Length - bl.TrimStart().Length;
                        if (indent <= 4)
                        {
                            break;
                        }

                        if (sb.Length > 0)
                        {
                            sb.Append(' ');
                        }

                        sb.Append(bl.Trim());
                        j++;
                    }

                    syntax = sb.ToString();
                    i = j - 1;
                }
                else
                {
                    syntax = StripYamlScalar(val);
                }
            }
        }

        Flush();
        return items;
    }

    private static string StripYamlScalar(string value)
    {
        var v = value.Trim();
        if (v.Length >= 2 && ((v[0] == '"' && v[^1] == '"') || (v[0] == '\'' && v[^1] == '\'')))
        {
            v = v[1..^1];
        }

        return v;
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

    private static void AddProjectOutputResolverPaths(ProjectInfo project, string configuration, string? framework,
        HashSet<string> resolverPaths)
    {
        var projectDir = Path.GetDirectoryName(project.Path)!;
        var outputRoot = Path.Combine(projectDir, "bin", configuration);
        var searchRoot = string.IsNullOrWhiteSpace(framework)
            ? outputRoot
            : Path.Combine(outputRoot, framework);
        if (!Directory.Exists(searchRoot))
        {
            return;
        }

        foreach (var dll in Directory.GetFiles(searchRoot, "*.dll", SearchOption.TopDirectoryOnly))
        {
            resolverPaths.Add(dll);
        }
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
        var documentedType = DocumentedApiOwnerType(type);
        var typeUid = TypeUid(documentedType);
        if (typeUid is null)
        {
            return;
        }

        AddTypeUid(ns, typeUid);
        if (ReferenceEquals(documentedType, type) && IsExampleRequiredType(documentedType))
        {
            var typeTarget = new ApiTargetInfo(typeUid, ns.Name, ApiTargetKind.Type, SimpleTypeName(documentedType));
            if (!ns.RequiredExampleTargets.Contains(typeTarget))
            {
                ns.RequiredExampleTargets.Add(typeTarget);
            }
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

            var methodTarget = new ApiTargetInfo(MethodUid(typeUid, method), ns.Name, ApiTargetKind.ExtensionMethod, MethodDisplayName(method), typeUid);
            if (!ns.RequiredExampleTargets.Contains(methodTarget))
            {
                ns.RequiredExampleTargets.Add(methodTarget);
            }
        }
    }

    private static void CollectExtensionMethods(Type type, NamespaceInfo ns)
    {
        if (!type.IsClass || !IsExternallyVisible(type))
        {
            return;
        }

        var documentedType = DocumentedApiOwnerType(type);
        var declaringClass = SimpleTypeName(documentedType);

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

            var extendedType = ExtensionReceiverDisplayName(parameters[0].ParameterType);
            var extensionInfo = new ExtensionMethodInfo(method.Name, MethodDisplayName(method), extendedType, declaringClass);
            if (!ns.ExtensionMethods.Contains(extensionInfo))
            {
                ns.ExtensionMethods.Add(extensionInfo);
            }
        }
    }

    private static Type DocumentedApiOwnerType(Type type)
    {
        while (IsSyntheticExtensionBlockContainer(type))
        {
            type = type.DeclaringType!;
        }

        return type;
    }

    private static bool IsSyntheticExtensionBlockContainer(Type type)
    {
        if (!type.IsNested || !ContainsSyntheticExtensionBlockUidMarker(type.Name) || type.DeclaringType is null)
        {
            return false;
        }

        var authoredOwner = type.DeclaringType;
        while (authoredOwner.IsNested &&
               ContainsSyntheticExtensionBlockUidMarker(authoredOwner.Name) &&
               authoredOwner.DeclaringType is not null)
        {
            authoredOwner = authoredOwner.DeclaringType;
        }

        return authoredOwner.IsClass &&
               authoredOwner.IsAbstract &&
               authoredOwner.IsSealed &&
               IsExternallyVisible(authoredOwner);
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
        if (type.IsInterface)
        {
            return false;
        }

        // Exclude abstract types, but allow every public static class (abstract+sealed in IL).
        // Static factories and other non-extension entry points are documentation targets too.
        if (type.IsAbstract && (!type.IsClass || !type.IsSealed))
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
        var genericArity = method.IsGenericMethodDefinition || method.IsGenericMethod
            ? "``" + method.GetGenericArguments().Length
            : string.Empty;

        return typeUid + "." + method.Name + genericArity + "(" + string.Join(",", parameters) + ")";
    }

    private static string SimpleTypeName(Type type)
    {
        var name = type.Name;
        var tick = name.IndexOf('`');
        return tick >= 0 ? name[..tick] : name;
    }

    private static string ExtensionReceiverDisplayName(Type type)
    {
        if (type.IsByRef)
        {
            type = type.GetElementType()!;
        }

        if (type.IsArray)
        {
            return ExtensionReceiverDisplayName(type.GetElementType()!) + "[]";
        }

        if (type.IsGenericParameter)
        {
            return type.Name;
        }

        var name = SimpleTypeName(type);
        if (!type.IsGenericType)
        {
            return name;
        }

        var args = type.GetGenericArguments().Select(ExtensionReceiverDisplayName);
        return name + "<" + string.Join(", ", args) + ">";
    }

    private static string MethodDisplayName(MethodInfo method)
    {
        if (!method.IsGenericMethodDefinition && !method.IsGenericMethod)
        {
            return method.Name;
        }

        return ComposeMethodDisplayName(method.Name,
            "<" + string.Join(", ", method.GetGenericArguments().Select(argument => argument.Name)) + ">");
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

    private static void ValidateNamespacePage(string repoRoot, string page, string text, NamespaceInfo ns, Report report,
        List<(string Namespace, string Path, string Fingerprint)>? proseFingerprints = null,
        HashSet<string>? globalExtensionMethodBaseNames = null)
    {
        var rel = Rel(repoRoot, page);
        if (string.IsNullOrEmpty(text))
        {
            report.Errors.Add(new Diagnostic("NAMESPACE_PAGE_MISSING", rel, ns.Name, "Unable to read namespace page."));
            return;
        }

        var (frontMatter, body) = SplitFrontMatter(text);
        var namespaceBody = TrimNamespaceBody(body);

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

        ValidateNamespacePageOwnership(page, rel, text, ns, report);

        // Concept-led namespace prose. A namespace inventory is useful reference material, but it
        // is not a developer-facing overview unless it explains when to use the surface and where
        // a newcomer should begin.
        var proseParagraphs = ExtractNamespaceProseParagraphs(namespaceBody);
        if (proseParagraphs.Count == 0)
        {
            report.Errors.Add(new Diagnostic("NAMESPACE_FLYIN_MISSING", rel, ns.Name,
                "Namespace page has no human-written fly-in paragraph, or contains only placeholder text."));
        }
        else
        {
            var firstParagraph = proseParagraphs[0];
            var laterParagraphs = proseParagraphs.Skip(1).ToList();
            var prose = string.Join(" ", proseParagraphs.Take(3));
            if (IsInventoryOnlyNamespaceProse(firstParagraph))
            {
                report.Errors.Add(new Diagnostic("NAMESPACE_PROSE_INVENTORY_ONLY", rel, ns.Name,
                    "The namespace overview only inventories types or extension methods. Rewrite the opening around the developer problem it solves, the outcome it enables, and when a consumer should use it."));
            }

            // Append-only repair: a weak inventory-led opening was left intact while the real usage
            // or start-here guidance was tacked on in a later paragraph. The opening must be rewritten
            // around the developer problem rather than patched beneath, even when the lead contains a
            // generic verb such as "enable" or "provide".
            if (IsInventoryLedOpening(firstParagraph) && !HasNamespaceProblemFraming(firstParagraph) &&
                laterParagraphs.Any(p => HasNamespaceUsageGuidance(p) || HasNamespaceStartHereGuidance(p)))
            {
                report.Errors.Add(new Diagnostic("NAMESPACE_APPEND_ONLY_REPAIR", rel, ns.Name,
                    "The opening paragraph still leads with a type inventory while usage or start-here guidance is appended in a later paragraph. Rewrite the opening cohesively around the developer problem and outcome instead of leaving the weak lead intact beneath an appended sentence."));
            }

            if (!HasNamespaceUsageGuidance(prose))
            {
                report.Errors.Add(new Diagnostic("NAMESPACE_USAGE_GUIDANCE_MISSING", rel, ns.Name,
                    "The namespace overview does not explain when or why a developer should use this API surface. Add concrete usage guidance grounded in source, tests, or package documentation."));
            }

            var surfaceSize = ns.RequiredExampleTargets.Count + ns.ExtensionMethods.Count;
            if (surfaceSize > 1 && !HasNamespaceStartHereGuidance(prose))
            {
                report.Errors.Add(new Diagnostic("NAMESPACE_START_HERE_MISSING", rel, ns.Name,
                    "The namespace exposes multiple public entry points but does not direct a newcomer to a useful starting type or method. Name the API to start with and distinguish the nearby alternatives."));
            }

            var skeleton = NormalizeProseSkeleton(prose);
            if (proseFingerprints is not null && skeleton.Length >= 40)
            {
                proseFingerprints.Add((ns.Name, rel, "lexical:" + skeleton));
                var rhetoricalSkeleton = NormalizeNamespaceRhetoricalSkeleton(prose);
                if (rhetoricalSkeleton is not null)
                {
                    proseFingerprints.Add((ns.Name, rel, "rhetorical:" + rhetoricalSkeleton));
                }
            }
        }

        // availability
        if (!HasAvailability(namespaceBody))
        {
            report.Errors.Add(new Diagnostic("AVAILABILITY_MISSING", rel, ns.Name,
                "Namespace page has no availability information (expected an availability include or explicit 'Availability:' text)."));
        }

        // extension members
        if (ns.ExtensionMethods.Count > 0)
        {
            ValidateExtensionSection(rel, namespaceBody, ns, report, globalExtensionMethodBaseNames ?? []);
        }
    }

    private static void ValidateNamespacePageOwnership(string page, string rel, string text, NamespaceInfo ns, Report report)
    {
        var sections = ExtractOverwriteSections(page, text);
        if (sections.Count <= 1)
        {
            return;
        }

        var embedded = sections.Skip(1).ToList();
        var offendingUids = embedded.Select(section => $"`{section.Uid}`")
            .Distinct(StringComparer.Ordinal)
            .Take(6)
            .ToList();
        var remaining = embedded.Select(section => section.Uid).Distinct(StringComparer.Ordinal).Count() - offendingUids.Count;
        var suffix = remaining > 0 ? $" and {remaining} more" : string.Empty;
        report.Errors.Add(new Diagnostic("NAMESPACE_EMBEDDED_OVERWRITE_SECTION", rel, ns.Name,
            $"Namespace page `{ns.Name}` contains additional overwrite section(s) after the namespace overview ({string.Join(", ", offendingUids)}{suffix}). " +
            "Keep namespace overview files single-UID and namespace-scoped. Move type/member `uid:` / `example:` mappings to readable files under `api/types/`, " +
            "typically the declaring extension class page, instead of appending them after `Extension Members`."));
    }

    private static void ValidateExtensionSection(string rel, string body, NamespaceInfo ns, Report report, HashSet<string> globalExtensionMethodBaseNames)
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

        // Validate that data rows use the correct ⬇️ emoji (U+2B07 U+FE0F) in the Ext column.
        // A missing or mojibake-encoded emoji passes the table-header check but renders incorrectly.
        bool dataRowChecked = false;
        foreach (Match row in Regex.Matches(section, @"^\|([^|\r\n]+)\|([^|\r\n]+)\|([^|\r\n]+)\|", RegexOptions.Multiline))
        {
            var extCell = row.Groups[2].Value.Trim();
            // Skip the header row and separator rows.
            if (extCell.Equals("Ext", StringComparison.OrdinalIgnoreCase) ||
                Regex.IsMatch(extCell, @"^[\-: ]+$"))
            {
                continue;
            }

            dataRowChecked = true;
            if (!extCell.Contains('\u2B07'))
            {
                report.Errors.Add(new Diagnostic("EXTENSION_TABLE_ENCODING", rel, ns.Name,
                    $"A data row in the 'Extension Members' table for namespace {ns.Name} is missing the ⬇️ (U+2B07) " +
                    $"character in the Ext column. Either the emoji is absent or it has been corrupted through an ANSI/OEM " +
                    $"encoding round-trip (mojibake). Use the literal ⬇️ character: |TypeName|⬇️|MethodName|. " +
                    $"Do not use HTML entities, Unicode escapes, or text substitutes. " +
                    $"If the file was recently written by PowerShell, check for ENCODING_CORRUPTION and restore with git checkout."));
                break;
            }
        }

        if (!dataRowChecked && ns.ExtensionMethods.Count > 0)
        {
            report.Errors.Add(new Diagnostic("EXTENSION_TABLE_MISSING", rel, ns.Name,
                $"The 'Extension Members' table for namespace {ns.Name} has a header row but no data rows listing extension methods."));
            return;
        }

        var tableRows = ParseExtensionTableRows(section);
        var rowsByType = tableRows
            .GroupBy(row => NormalizeTypeDisplay(row.TypeDisplay), StringComparer.Ordinal)
            .ToDictionary(group => group.Key, group => group.ToList(), StringComparer.Ordinal);
        var expectedMethodsByType = ns.ExtensionMethods
            .GroupBy(method => NormalizeTypeDisplay(method.ExtendedType), StringComparer.Ordinal)
            .ToDictionary(group => group.Key, group => group.ToList(), StringComparer.Ordinal);
        var expectedMethodBaseNames = new HashSet<string>(
            ns.ExtensionMethods.Select(method => method.MethodName),
            StringComparer.Ordinal);

        foreach (var row in tableRows)
        {
            expectedMethodsByType.TryGetValue(NormalizeTypeDisplay(row.TypeDisplay), out var expectedForType);
            if (expectedForType is null)
            {
                continue;
            }

            foreach (var actualMethod in row.Methods)
            {
                var actualBaseName = MethodBaseName(actualMethod);
                var matchesExpectedForType = expectedForType.Any(expected =>
                    string.Equals(NormalizeMethodDisplay(actualMethod), NormalizeMethodDisplay(expected.DisplayName), StringComparison.Ordinal));
                if (matchesExpectedForType || expectedMethodBaseNames.Contains(actualBaseName) || globalExtensionMethodBaseNames.Contains(actualBaseName))
                {
                    continue;
                }

                report.Errors.Add(new Diagnostic("EXTENSION_METHOD_UNKNOWN", rel, ns.Name,
                    $"The 'Extension Members' table for namespace {ns.Name} lists `{actualMethod}` under `{row.TypeDisplay}`, but no public extension method with that name exists in the namespace API model. Remove the invented method name or replace it with a source-backed public extension method."));
            }
        }

        foreach (var expectedTypeGroup in ns.ExtensionMethods.GroupBy(method => NormalizeTypeDisplay(method.ExtendedType), StringComparer.Ordinal))
        {
            var expectedMethods = expectedTypeGroup.ToList();
            var expectedTypeDisplay = expectedMethods[0].ExtendedType;
            if (!rowsByType.TryGetValue(expectedTypeGroup.Key, out var matchingRows))
            {
                if (TryUnwrapDecoratorDisplay(expectedTypeDisplay, out var wrappedTypeDisplay) &&
                    rowsByType.TryGetValue(NormalizeTypeDisplay(wrappedTypeDisplay), out var collapsedRows))
                {
                    var overlapping = expectedMethods
                        .Where(expected => collapsedRows.Any(row =>
                            row.Methods.Any(actual => string.Equals(MethodBaseName(actual), expected.MethodName, StringComparison.Ordinal))))
                        .ToList();
                    if (overlapping.Count > 0)
                    {
                        var actualRows = collapsedRows
                            .Select(row => $"`{row.TypeDisplay}`")
                            .Distinct(StringComparer.Ordinal)
                            .ToList();
                        var affectedMethods = overlapping
                            .Select(method => $"`{method.DisplayName}`")
                            .Distinct(StringComparer.Ordinal)
                            .Take(6)
                            .ToList();
                        var remaining = overlapping
                            .Select(method => method.DisplayName)
                            .Distinct(StringComparer.Ordinal)
                            .Count() - affectedMethods.Count;
                        var suffix = remaining > 0 ? $" and {remaining} more" : string.Empty;
                        report.Errors.Add(new Diagnostic("EXTENSION_RECEIVER_MISMATCH", rel, ns.Name,
                            $"Extension members that extend `{expectedTypeDisplay}` are listed under {string.Join(", ", actualRows)} in the 'Extension Members' table for namespace {ns.Name}. Keep the actual decorated receiver signature in the Type column instead of collapsing it to the wrapped type. Affected methods: {string.Join(", ", affectedMethods)}{suffix}."));
                    }
                }

                foreach (var expected in expectedMethods)
                {
                    if (HasGenericMethodSignature(expected.DisplayName) &&
                        SectionContainsMethodBase(section, expected.MethodName) &&
                        !SectionContainsMethodDisplay(section, expected.DisplayName))
                    {
                        report.Errors.Add(new Diagnostic("EXTENSION_METHOD_SIGNATURE_MISSING", rel, ns.Name,
                            $"Extension method `{expected.DisplayName}` (extending {expected.ExtendedType}) is listed without its generic signature in the 'Extension Members' table for namespace {ns.Name}. Preserve method type parameters in the Methods column, for example `{expected.DisplayName}` instead of bare `{expected.MethodName}`."));
                        continue;
                    }

                    if (!SectionContainsMethodBase(section, expected.MethodName))
                    {
                        report.Errors.Add(new Diagnostic("EXTENSION_METHOD_MISSING", rel, ns.Name,
                            $"Extension method `{expected.DisplayName}` (extending {expected.ExtendedType}) is not listed in the 'Extension Members' table for namespace {ns.Name}."));
                    }
                }

                continue;
            }

            foreach (var expected in expectedMethods)
            {
                if (matchingRows.Any(row =>
                        row.Methods.Any(actual =>
                            string.Equals(NormalizeMethodDisplay(actual), NormalizeMethodDisplay(expected.DisplayName), StringComparison.Ordinal))))
                {
                    continue;
                }

                if (HasGenericMethodSignature(expected.DisplayName) &&
                    matchingRows.Any(row =>
                        row.Methods.Any(actual => string.Equals(MethodBaseName(actual), expected.MethodName, StringComparison.Ordinal))))
                {
                    report.Errors.Add(new Diagnostic("EXTENSION_METHOD_SIGNATURE_MISSING", rel, ns.Name,
                        $"Extension method `{expected.DisplayName}` (extending {expected.ExtendedType}) is listed without its generic signature in the 'Extension Members' table for namespace {ns.Name}. Preserve method type parameters in the Methods column, for example `{expected.DisplayName}` instead of bare `{expected.MethodName}`."));
                    continue;
                }

                if (!SectionContainsMethodBase(section, expected.MethodName))
                {
                    report.Errors.Add(new Diagnostic("EXTENSION_METHOD_MISSING", rel, ns.Name,
                        $"Extension method `{expected.DisplayName}` (extending {expected.ExtendedType}) is not listed in the 'Extension Members' table for namespace {ns.Name}."));
                }
            }
        }
    }

    private static List<ExtensionTableRow> ParseExtensionTableRows(string section)
    {
        var rows = new List<ExtensionTableRow>();
        foreach (Match row in Regex.Matches(section, @"^\|([^|\r\n]+)\|([^|\r\n]+)\|([^|\r\n]+)\|", RegexOptions.Multiline))
        {
            var typeCell = row.Groups[1].Value.Trim();
            var extCell = row.Groups[2].Value.Trim();
            var methodCell = row.Groups[3].Value.Trim();
            if (Regex.IsMatch(typeCell, @"^[\-: ]+$") ||
                extCell.Equals("Ext", StringComparison.OrdinalIgnoreCase) ||
                Regex.IsMatch(extCell, @"^[\-: ]+$"))
            {
                continue;
            }

            var methods = Regex.Matches(methodCell, @"`(?<name>[^`]+)`")
                .Cast<Match>()
                .Select(match => match.Groups["name"].Value.Trim())
                .Where(name => name.Length > 0)
                .ToList();
            if (methods.Count == 0)
            {
                methods = methodCell.Split(',')
                    .Select(part => part.Trim())
                    .Where(part => part.Length > 0)
                    .ToList();
            }

            rows.Add(new ExtensionTableRow(typeCell, methods));
        }

        return rows;
    }

    private static bool HasGenericMethodSignature(string methodDisplayName)
    {
        return methodDisplayName.IndexOf('<') >= 0;
    }

    private static bool SectionContainsMethodBase(string section, string methodName)
    {
        return Regex.IsMatch(section, "`" + Regex.Escape(methodName) + @"[`(]");
    }

    private static bool SectionContainsMethodDisplay(string section, string methodDisplayName)
    {
        return Regex.IsMatch(section, "`" + Regex.Escape(methodDisplayName) + @"`");
    }

    private static string NormalizeTypeDisplay(string typeDisplay)
    {
        return Regex.Replace(SimplifyTypeReference(typeDisplay), @"\s+", string.Empty);
    }

    private static string NormalizeMethodDisplay(string methodDisplayName)
    {
        var trimmed = methodDisplayName.Trim();
        var genericStart = trimmed.IndexOf('<');
        if (genericStart < 0)
        {
            return MethodBaseName(trimmed);
        }

        return MethodBaseName(trimmed) + NormalizeGenericArgumentList(trimmed[genericStart..]);
    }

    private static string MethodBaseName(string methodDisplayName)
    {
        var trimmed = methodDisplayName.Trim();
        var genericStart = trimmed.IndexOf('<');
        return genericStart >= 0 ? trimmed[..genericStart].Trim() : trimmed;
    }

    private static bool TryUnwrapDecoratorDisplay(string typeDisplay, out string wrappedTypeDisplay)
    {
        const string prefix = "IDecorator<";
        wrappedTypeDisplay = string.Empty;
        var trimmed = typeDisplay.Trim();
        if (!trimmed.StartsWith(prefix, StringComparison.Ordinal) || !trimmed.EndsWith(">", StringComparison.Ordinal))
        {
            return false;
        }

        wrappedTypeDisplay = trimmed[prefix.Length..^1].Trim();
        return wrappedTypeDisplay.Length > 0;
    }

    private static List<string> ExtractNamespaceProseParagraphs(string body)
    {
        var paragraphs = new List<string>();
        var current = new List<string>();
        var inFence = false;

        void Flush()
        {
            if (current.Count == 0)
            {
                return;
            }

            var paragraph = string.Join(" ", current).Trim();
            current.Clear();
            if (paragraph.Length >= 20 &&
                !paragraph.Contains("...", StringComparison.Ordinal) &&
                !paragraph.Contains("TODO", StringComparison.OrdinalIgnoreCase) &&
                !paragraph.EndsWith("contains types that", StringComparison.OrdinalIgnoreCase))
            {
                paragraphs.Add(paragraph);
            }
        }

        foreach (var raw in body.Replace("\r\n", "\n", StringComparison.Ordinal).Replace('\r', '\n').Split('\n'))
        {
            var line = raw.Trim();
            if (line.StartsWith("```", StringComparison.Ordinal))
            {
                Flush();
                inFence = !inFence;
                continue;
            }

            if (inFence)
            {
                continue;
            }

            if (line.Length == 0)
            {
                Flush();
                continue;
            }

            if (line.StartsWith('#') || line.StartsWith('|') || line.StartsWith("[!INCLUDE", StringComparison.OrdinalIgnoreCase) ||
                line.StartsWith("---", StringComparison.Ordinal) || line.StartsWith("<!--", StringComparison.Ordinal) ||
                line.StartsWith("Availability:", StringComparison.OrdinalIgnoreCase) ||
                line.StartsWith("Complements:", StringComparison.OrdinalIgnoreCase) ||
                line.StartsWith("Related:", StringComparison.OrdinalIgnoreCase))
            {
                Flush();
                continue;
            }

            current.Add(line);
        }

        Flush();
        return paragraphs;
    }

    private static string TrimNamespaceBody(string body)
    {
        var nextOverwrite = Regex.Match(body, @"(?im)^---\s*$\nuid\s*:");
        return nextOverwrite.Success ? body[..nextOverwrite.Index] : body;
    }

    private static bool IsInventoryOnlyNamespaceProse(string paragraph)
    {
        return Regex.IsMatch(paragraph,
            @"(?i)^(?:the\s+)?(?:`?[\w.]+`?\s+)?namespace\s+(?:contains|provides|includes|exposes|groups|collects)\b") &&
               !HasNamespaceUsageGuidance(paragraph);
    }

    // An inventory-led opening begins by listing what the surface holds ("contains types",
    // "provides helpers", "the X namespace exposes ..."). This is independent of generic guidance
    // verbs, so it still matches a lead that ends with "... to enable Y".
    private static bool IsInventoryLedOpening(string paragraph)
    {
        var firstSentence = Regex.Match(paragraph, @"^(.*?[.!?])(?:\s|$)").Groups[1].Value;
        if (string.IsNullOrEmpty(firstSentence))
        {
            firstSentence = paragraph;
        }

        return Regex.IsMatch(firstSentence,
            @"(?i)^(?:the\s+)?(?:`?[\w.]+`?\s+)?namespace\s+(?:contains|provides|includes|exposes|groups|collects|offers|defines|holds)\b") ||
               Regex.IsMatch(firstSentence,
            @"(?i)\b(?:contains|provides|includes|exposes|groups|collects|offers|defines|holds)\s+(?:a\s+(?:set|collection|number|group)\s+of\s+)?(?:the\s+)?(?:types|classes|helpers?|members?|utilities|extension\s+methods|functionality|apis?|abstractions?)\b");
    }

    // Problem framing means the opening explains the developer problem or outcome rather than the
    // surface contents: it leads with the reader's task ("use X when ...", "to ... without ...").
    private static bool HasNamespaceProblemFraming(string paragraph)
    {
        var firstSentence = Regex.Match(paragraph, @"^(.*?[.!?])(?:\s|$)").Groups[1].Value;
        if (string.IsNullOrEmpty(firstSentence))
        {
            firstSentence = paragraph;
        }

        return !IsInventoryLedOpening(firstSentence) &&
               Regex.IsMatch(firstSentence,
                   @"(?i)\b(?:use\b|when\b|need\b|want\b|choose\b|prefer\b|reach for\b|so that\b|without having to\b|without\b|to\s+\w+\s+(?:a|an|the|your))\b");
    }

    // Collapses namespace prose to a sentence skeleton: inline code, identifiers, namespace names
    // and numbers become placeholders so two pages that share a mechanical template (only type names
    // substituted) normalize to the same value.
    private static string NormalizeProseSkeleton(string prose)
    {
        var text = Regex.Replace(prose, @"`[^`]*`", " CODE ");
        text = Regex.Replace(text, @"\b[A-Z][A-Za-z0-9_]*(?:\.[A-Z][A-Za-z0-9_]*)+\b", " QNAME ");
        text = Regex.Replace(text, @"\b[A-Z][A-Za-z0-9_]{2,}\b", " NAME ");
        text = Regex.Replace(text, @"\d+(?:\.\d+)?", " NUM ");
        text = text.ToLowerInvariant();
        text = Regex.Replace(text, @"[^a-z ]", " ");
        text = Regex.Replace(text, @"\s+", " ").Trim();
        return text;
    }

    // Detects the specific mass-authoring cadence that survived the broader lexical fingerprint:
    // "The X namespace helps you ..." followed by "Use it when ..." and "Start with Y ...".
    // The content words may differ completely, but repeating this three-part rhetorical frame across
    // even two unrelated namespaces reads as substituted boilerplate. Ordinary shared guidance such
    // as a standalone "Use X when ..." sentence does not produce this signature.
    private static string? NormalizeNamespaceRhetoricalSkeleton(string prose)
    {
        var text = Regex.Replace(prose, @"`[^`]*`", " CODE ");
        text = Regex.Replace(text, @"\s+", " ").Trim();
        var hasStartThen = Regex.IsMatch(text,
            @"(?i)(?:^|[.!?]\s+)(?:start|begin)\s+with\s+CODE\b[^.!?]{0,220}\bthen\b");
        if (hasStartThen)
        {
            return "start-code-then-navigation";
        }

        var hasNamespaceHelpsLead = Regex.IsMatch(text,
            @"(?i)^(?:the\s+)?(?:CODE|[\w.]+)\s+namespace\s+helps\s+you\b");
        var hasUseItWhen = Regex.IsMatch(text, @"(?i)(?:^|[.!?]\s+)use\s+it\s+when\b");
        var hasConditionalStart = Regex.IsMatch(text,
            @"(?i)(?:^|[.!?]\s+)(?:start|begin)\s+with\s+CODE\b|(?:^|[.!?]\s+)if\s+you\b[^.!?]{0,160}\b(?:start|begin)\s+with\s+CODE\b");
        if (hasNamespaceHelpsLead && hasUseItWhen && hasConditionalStart)
        {
            return "namespace-helps-you|use-it-when|conditional-start-code";
        }

        var hasUseNamespaceWhenLead = Regex.IsMatch(text,
            @"(?i)^use\s+the\s+CODE\s+namespace\s+when\b");
        var hasNamespaceOutcomeSentence = Regex.IsMatch(text,
            @"(?i)[.!?]\s+the\s+namespace\s+(?:helps|keeps|lets|enables|separates|centralizes)\b");
        var hasChooseNamespaceWhen = Regex.IsMatch(text,
            @"(?i)(?:^|[.!?]\s+)choose\s+this\s+namespace\s+when\b");
        return hasUseNamespaceWhenLead && hasNamespaceOutcomeSentence && hasStartThen && hasChooseNamespaceWhen
            ? "use-namespace-when|namespace-outcome|start-then|choose-namespace-when"
            : null;
    }

    private static void ValidateNamespaceProseRepetition(
        List<(string Namespace, string Path, string Fingerprint)> proseFingerprints, Report report)
    {
        foreach (var group in proseFingerprints
                     .GroupBy(entry => entry.Fingerprint, StringComparer.Ordinal)
                     .Where(group => group.Select(entry => entry.Namespace).Distinct(StringComparer.Ordinal).Count() >=
                         (group.Key.StartsWith("rhetorical:", StringComparison.Ordinal) ? 2 : 3)))
        {
            var namespaces = group.Select(entry => entry.Namespace)
                .Distinct(StringComparer.Ordinal)
                .OrderBy(name => name, StringComparer.Ordinal)
                .ToList();
            foreach (var entry in group.GroupBy(e => e.Path, StringComparer.OrdinalIgnoreCase).Select(g => g.First()))
            {
                report.Errors.Add(new Diagnostic("NAMESPACE_PROSE_TEMPLATE_REPETITION", entry.Path, entry.Namespace,
                    $"This namespace overview shares a normalized {(group.Key.StartsWith("rhetorical:", StringComparison.Ordinal) ? "rhetorical frame" : "prose skeleton")} with {namespaces.Count - 1} other namespace page(s) ({string.Join(", ", namespaces.Where(n => !string.Equals(n, entry.Namespace, StringComparison.Ordinal)))}). Write each opening from the namespace's own purpose instead of a substituted template."));
            }
        }
    }

    private static bool HasNamespaceUsageGuidance(string prose)
    {
        return Regex.IsMatch(prose,
            @"(?i)\b(?:use(?:ful)?\b|when\b|choose\b|prefer\b|reach for\b|designed for\b|suited for\b|helps?\b|enables?\b|lets?\s+you\b|so that\b|without having to\b)");
    }

    private static bool HasNamespaceStartHereGuidance(string prose)
    {
        return Regex.IsMatch(prose,
            @"(?i)\b(?:start with|begin with|entry point|first reach for|reach for|choose|prefer|use\s+`?[A-Z][A-Za-z0-9_]*(?:<[^>]+>)?`?\s+(?:to|when|for|as))\b");
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
    // Xref member/method link validation
    // ----------------------------------------------------------------------

    /// <summary>
    /// Scans all DocFX Markdown files for <c>xref:</c> links that point to method or member UIDs.
    /// Such links do not resolve outside a DocFX build (GitHub, NuGet README, and other Markdown
    /// renderers render them as broken links) and must be replaced with absolute anchor URLs
    /// built from the deployed site's <c>xrefmap.yml</c>.
    /// </summary>
    private static void ValidateXrefMemberLinks(
        string repoRoot,
        IReadOnlyList<string> markdownFiles,
        ValidationWorkspace workspace,
        string? siteBaseUrl,
        ApiModel api,
        ApiModelSource apiModelSource,
        Report report)
    {
        // On the build-backed path, build a UID lookup so we can also flag non-method member UIDs
        // (properties, fields, events) that are not types or namespaces in the discovered API.
        var knownTypeUids = new HashSet<string>(StringComparer.Ordinal);
        var knownNamespaceUids = new HashSet<string>(StringComparer.Ordinal);
        if (apiModelSource == ApiModelSource.BuildBacked)
        {
            foreach (var ns in api.Namespaces)
            {
                knownNamespaceUids.Add(ns.Name);
                foreach (var uid in ns.TypeUids)
                {
                    knownTypeUids.Add(uid);
                }
            }
        }

        // Track (relPath, uid) pairs so the same broken xref in the same file is reported once.
        var seen = new HashSet<(string, string)>();

        foreach (var md in markdownFiles)
        {
            var text = workspace.ReadMarkdown(md);
            if (string.IsNullOrEmpty(text))
            {
                continue;
            }

            var rel = Rel(repoRoot, md);

            // [label](xref:UID) — standard Markdown link with xref protocol.
            foreach (Match m in XrefMarkdownLinkRegex.Matches(text))
            {
                var uid = m.Groups[1].Value.Trim();
                if (seen.Add((rel, uid)) && IsXrefMemberUid(uid, knownTypeUids, knownNamespaceUids, apiModelSource))
                {
                    EmitXrefMemberLinkDiagnostic(rel, uid, m.Value, siteBaseUrl, report);
                }
            }

            // <xref:UID> — inline DocFX xref tag (supports literal parentheses in the UID).
            foreach (Match m in XrefInlineTagRegex.Matches(text))
            {
                var uid = m.Groups[1].Value.Trim();
                if (seen.Add((rel, uid)) && IsXrefMemberUid(uid, knownTypeUids, knownNamespaceUids, apiModelSource))
                {
                    EmitXrefMemberLinkDiagnostic(rel, uid, m.Value, siteBaseUrl, report);
                }
            }
        }
    }

    /// <summary>
    /// Returns <see langword="true"/> when the xref UID refers to a method or other member (not a
    /// type or namespace) and will therefore produce a broken link outside a DocFX build.
    /// </summary>
    private static bool IsXrefMemberUid(
        string uid,
        HashSet<string> knownTypeUids,
        HashSet<string> knownNamespaceUids,
        ApiModelSource apiModelSource)
    {
        if (string.IsNullOrEmpty(uid))
        {
            return false;
        }

        // Method UIDs always contain '(' (literal or URL-encoded) — reliably detectable without
        // the API model and always broken outside a DocFX build.
        if (uid.Contains('(') || uid.Contains("%28", StringComparison.OrdinalIgnoreCase))
        {
            return true;
        }

        // On the build-backed path, also flag dotted UIDs that are not known types or namespaces.
        // A UID with at least two segments that resolves to neither a type nor a namespace is
        // a property, field, event, or parameterless method reference.
        if (apiModelSource == ApiModelSource.BuildBacked &&
            uid.Contains('.') &&
            !knownTypeUids.Contains(uid) &&
            !knownNamespaceUids.Contains(uid))
        {
            return true;
        }

        return false;
    }

    private static void EmitXrefMemberLinkDiagnostic(
        string rel,
        string uid,
        string rawLink,
        string? siteBaseUrl,
        Report report)
    {
        string fixGuidance;
        if (siteBaseUrl is not null)
        {
            fixGuidance =
                $"Replace with an absolute anchor URL. " +
                $"Fetch `{siteBaseUrl}/xrefmap.yml`, find the entry where `uid: {uid}`, " +
                $"extract the `href` value, and construct: `[label]({siteBaseUrl}/{{href}})`. " +
                $"The `href` follows the pattern `api/TypePage.html#TypePage_Member_ParamTypes_` " +
                $"with namespace and type dots, parentheses, and commas replaced by underscores.";
        }
        else
        {
            fixGuidance =
                $"Replace with an absolute anchor URL. " +
                $"Fetch `xrefmap.yml` from the deployed docs site, find the entry where `uid: {uid}`, " +
                $"extract the `href` value, and construct `{{siteBaseUrl}}/{{href}}`. " +
                $"The `href` follows the pattern `api/TypePage.html#TypePage_Member_ParamTypes_` " +
                $"with dots, parentheses, and commas replaced by underscores. " +
                $"Set `build.sitemap.baseUrl` in `docfx.json` to enable site-aware resolution guidance.";
        }

        report.Errors.Add(new Diagnostic(
            "XREF_MEMBER_LINK",
            rel,
            null,
            $"Member-level `xref:` link `{rawLink}` (UID: `{uid}`) does not resolve outside a DocFX build. " +
            $"In GitHub, NuGet README, and other Markdown renderers, `xref:` links to method and member UIDs " +
            $"render as broken links rather than deep anchor links. " + fixGuidance,
            uid: uid,
            symbol: rawLink));
    }

    // ----------------------------------------------------------------------
    // Required example validation
    // ----------------------------------------------------------------------

    private static void ValidateRequiredExamples(string repoRoot, string docfxWorkspace, IReadOnlyList<OverwriteSection> sections, ApiModel api,
        Options options, HashSet<string>? changedFiles, ScopePlan scope, Dictionary<string, List<ProjectInfo>> namespaceOwners, Report report)
    {
        foreach (var duplicate in sections
                     .Where(section => section.MappedToExample)
                     .Where(section => !options.ChangedOnly || changedFiles is null ||
                                       changedFiles.Contains(Path.GetFullPath(section.File)) ||
                                       changedFiles.Any(IsChangedDocfxConfig))
                     .GroupBy(section => section.Uid, StringComparer.Ordinal)
                     .Where(group => group.Count() > 1))
        {
            var paths = duplicate.Select(section => Rel(repoRoot, section.File))
                .Distinct(StringComparer.OrdinalIgnoreCase)
                .OrderBy(path => path, StringComparer.OrdinalIgnoreCase)
                .ToList();
            report.Errors.Add(new Diagnostic("EXAMPLE_UID_DUPLICATE", string.Join(", ", paths), NamespaceFromUid(duplicate.Key),
                $"UID `{duplicate.Key}` is mapped to {duplicate.Count()} example sections. Keep one coherent, scenario-led example for a UID; merge or remove the duplicate `example: *content` sections."));
        }

        var exampleFingerprints = new List<(string SectionUid, string Path, string Fingerprint)>();

        foreach (var target in api.RequiredExampleTargets)
        {
            if (!scope.IncludesNamespace(target.Namespace))
            {
                continue;
            }

            if (options.ChangedOnly && changedFiles is not null &&
                !ShouldValidateRequiredExampleTarget(target, changedFiles))
            {
                continue;
            }

            var candidates = sections.Where(s => IsExampleCandidate(s, target)).ToList();
            var relatedExtensionMethods = target.Kind == ApiTargetKind.Type
                ? api.RequiredExampleTargets
                    .Where(candidate => candidate.Kind == ApiTargetKind.ExtensionMethod &&
                                        string.Equals(candidate.DeclaringTypeUid, target.Uid, StringComparison.Ordinal))
                    .Select(candidate => candidate.DisplayName)
                    .Distinct(StringComparer.Ordinal)
                    .ToList()
                : new List<string>();
            var qualityResults = candidates
                .Select(section => ValidateExampleQuality(section, target, relatedExtensionMethods))
                .ToList();
            var validIndex = qualityResults.FindIndex(result => result.Valid);
            if (validIndex >= 0)
            {
                report.Summary.RequiredExamples++;
                var validSection = candidates[validIndex];
                var fingerprint = NormalizeExampleStructure(validSection.MappedToExample
                    ? validSection.Body
                    : ExtractExampleSection(validSection.Body));
                if (fingerprint.Length >= 40)
                {
                    var path = Rel(repoRoot, validSection.File);
                    if (!exampleFingerprints.Any(entry =>
                            string.Equals(entry.SectionUid, validSection.Uid, StringComparison.Ordinal) &&
                            string.Equals(entry.Path, path, StringComparison.OrdinalIgnoreCase) &&
                            string.Equals(entry.Fingerprint, fingerprint, StringComparison.Ordinal)))
                    {
                        exampleFingerprints.Add((validSection.Uid, path, fingerprint));
                    }
                }

                continue;
            }

            var expectedUid = target.Kind == ApiTargetKind.Type
                ? target.Uid
                : target.DeclaringTypeUid ?? target.Uid;
            var expectedPath = target.Kind == ApiTargetKind.Type
                ? Rel(repoRoot, Path.Combine(docfxWorkspace, "api", "types", $"{target.Uid}.md"))
                : target.DeclaringTypeUid is null
                    ? null
                    : Rel(repoRoot, Path.Combine(docfxWorkspace, "api", "types", $"{target.DeclaringTypeUid}.md"));
            var expectedPathText = expectedPath is null ? "a readable overwrite file under `api/types/`" : $"`{expectedPath}`";

            if (qualityResults.Count > 0)
            {
                var qualityFailure = qualityResults
                    .Where(result => !result.Valid && result.Code is not null)
                    .OrderBy(result => result.Priority)
                    .FirstOrDefault();
                if (qualityFailure is not null)
                {
                    report.Errors.Add(new Diagnostic(qualityFailure.Code!, expectedPath, target.Namespace,
                        qualityFailure.Message ?? "The example does not demonstrate the documented API."));
                    continue;
                }
            }

            var message = target.Kind == ApiTargetKind.Type
                ? $"Public non-abstraction type `{target.DisplayName}` requires a type-page DocFX overwrite example. Add an Examples section with a C# code fence to uid `{target.Uid}` in `{expectedPath}` or another overwrite file under `api/types/` that targets this exact type UID. Namespace overview examples do not satisfy this diagnostic. Keep `api/types/**/*.md` under `build.overwrite`, exclude `api/types/**` from `build.content`, and do not use `api/**/*.md` under either section."
                : $"Public extension method `{target.DisplayName}` (declaring type `{target.DeclaringTypeUid ?? "(unknown)"}`, owner {DescribeOwner(target.Namespace, namespaceOwners)}) requires a DocFX overwrite example. Add an Examples section with a C# code fence to the declaring extension class uid `{expectedUid}` in {expectedPathText} or another readable overwrite file under `api/types/` that targets that class UID. The example must explicitly call `{target.DisplayName}`{(namespaceOwners.TryGetValue(target.Namespace, out var owns) && owns.Count(o => !o.IsTest) > 1 ? " — prefer receiver extension syntax because the container name is shared across assemblies" : string.Empty)}. Candidate overwrite sections inspected: {DescribeExtensionCandidates(candidates, qualityResults, repoRoot)}. Do not create URL-encoded or hash-like method UID filenames; use a method UID section only when the exact generated UID is verified and can live in a readable overwrite file.";

            report.Errors.Add(new Diagnostic("EXAMPLE_MISSING", expectedPath, target.Namespace, message));
        }

        // Cross-file template repetition: examples that normalize to the same structural skeleton
        // across several unrelated targets are mechanical fills, not authored scenarios. A
        // conservative threshold (three or more distinct UIDs) avoids rejecting a coherent family
        // or conventional one-line setup that legitimately recurs.
        foreach (var group in exampleFingerprints
                     .GroupBy(entry => entry.Fingerprint, StringComparer.Ordinal)
                     .Where(group => group
                         .Select(entry => (entry.SectionUid, entry.Path))
                         .Distinct()
                         .Count() >= 3))
        {
            var paths = group.Select(entry => entry.Path)
                .Distinct(StringComparer.OrdinalIgnoreCase)
                .OrderBy(path => path, StringComparer.OrdinalIgnoreCase)
                .ToList();
            var uids = group.Select(entry => entry.SectionUid)
                .Distinct(StringComparer.Ordinal)
                .OrderBy(uid => uid, StringComparer.Ordinal)
                .ToList();
            report.Errors.Add(new Diagnostic("EXAMPLE_TEMPLATE_REPETITION", string.Join(", ", paths), NamespaceFromUid(uids[0]),
                $"{uids.Count} unrelated examples ({string.Join(", ", uids)}) share one normalized code template and differ only by identifiers or literals. Author distinct scenarios that reflect each type's real behavior instead of reusing a single skeleton."));
        }
    }

    private static string DescribeOwner(string ns, Dictionary<string, List<ProjectInfo>> namespaceOwners)
    {
        if (!namespaceOwners.TryGetValue(ns, out var owners) || owners.Count == 0)
        {
            return "(unresolved)";
        }

        return string.Join(", ", owners.Where(o => !o.IsTest).Select(o => o.AssemblyName)
            .Distinct(StringComparer.OrdinalIgnoreCase).OrderBy(n => n, StringComparer.OrdinalIgnoreCase));
    }

    private static string DescribeExtensionCandidates(List<OverwriteSection> candidates, List<ExampleQualityResult> results, string repoRoot)
    {
        if (candidates.Count == 0)
        {
            return "none found (no overwrite section targets the declaring type UID or namespace page)";
        }

        var parts = new List<string>();
        for (var i = 0; i < candidates.Count; i++)
        {
            var stage = results[i].Code switch
            {
                "EXAMPLE_MISSING" => "no C# fence",
                "EXTENSION_EXAMPLE_NOT_INVOKED" => "fence present but method never invoked",
                "EXAMPLE_REFLECTION_ONLY" => "reflection/metadata lookup instead of a call",
                null => "valid",
                _ => results[i].Code!
            };
            parts.Add($"`{Rel(repoRoot, candidates[i].File)}` ({stage})");
        }

        return string.Join("; ", parts);
    }

    // Normalizes example code to a structural skeleton: comments and string contents are removed,
    // numeric literals and non-keyword identifiers are collapsed to placeholders, and whitespace is
    // dropped. Two examples that differ only by type or identifier names produce identical skeletons.
    private static string NormalizeExampleStructure(string body)
    {
        var code = string.Join("\n", ExtractCSharpCodeBlocks(body));
        if (string.IsNullOrWhiteSpace(code))
        {
            return string.Empty;
        }

        code = StripCodeCommentsAndStrings(code);
        var sb = new StringBuilder(code.Length);
        foreach (Match token in Regex.Matches(code, @"[A-Za-z_]\w*|\d+(?:\.\d+)?|[^\sA-Za-z0-9_]"))
        {
            var value = token.Value;
            if (Regex.IsMatch(value, @"^[A-Za-z_]\w*$"))
            {
                sb.Append(CSharpStructuralKeywords.Contains(value) ? value : "ID");
            }
            else if (Regex.IsMatch(value, @"^\d"))
            {
                sb.Append('0');
            }
            else
            {
                sb.Append(value);
            }
        }

        return sb.ToString();
    }

    private static readonly HashSet<string> CSharpStructuralKeywords = new(StringComparer.Ordinal)
    {
        "abstract", "as", "async", "await", "base", "bool", "break", "byte", "case", "catch", "char",
        "checked", "class", "const", "continue", "decimal", "default", "delegate", "do", "double",
        "else", "enum", "event", "explicit", "extern", "false", "finally", "fixed", "float", "for",
        "foreach", "goto", "if", "implicit", "in", "int", "interface", "internal", "is", "lock", "long",
        "namespace", "new", "null", "object", "operator", "out", "override", "params", "private",
        "protected", "public", "readonly", "ref", "return", "sbyte", "sealed", "short", "sizeof",
        "stackalloc", "static", "string", "struct", "switch", "this", "throw", "true", "try", "typeof",
        "uint", "ulong", "unchecked", "unsafe", "ushort", "using", "var", "virtual", "void", "volatile",
        "while", "yield", "record", "init", "nameof", "when", "with", "global",
    };

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

        var methodName = MethodBaseName(target.DisplayName);
        return Regex.IsMatch(sourceText, $@"(?s)\b{Regex.Escape(methodName)}(?:\s*<[^>\r\n]+>)?\s*\([^)]*\bthis\b") ||
               Regex.IsMatch(sourceText,
                   $@"(?s)\bextension\s*\([^)]*\)\s*\{{.*?\b{Regex.Escape(methodName)}(?:\s*<[^>\r\n]+>)?\s*\(");
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

    private static ExampleQualityResult ValidateExampleQuality(
        OverwriteSection section, ApiTargetInfo target, IReadOnlyList<string> relatedExtensionMethods)
    {
        // MappedToExample (front-matter example: *content or - *content) only requires
        // a bare csharp fence; the heading is added automatically by DocFX.
        // The summary: *content form (MappedToExample=false) still requires the explicit
        // heading to delimit the embedded example within conceptual content.
        var scope = section.MappedToExample ? section.Body : ExtractExampleSection(section.Body);
        var codeBlocks = ExtractCSharpCodeBlocks(scope);
        if (codeBlocks.Count == 0)
        {
            return new ExampleQualityResult(false, "EXAMPLE_MISSING",
                $"The overwrite section for `{target.DisplayName}` does not contain a C# fence in its mapped example content.", 50);
        }

        var combinedCode = string.Join(Environment.NewLine, codeBlocks);
        var codeWithoutCommentsOrStrings = StripCodeCommentsAndStrings(combinedCode);
        if (Regex.IsMatch(codeWithoutCommentsOrStrings,
                @"\.\s*GetType\s*\(\s*\)\s*\.\s*(?:Name|FullName)\b"))
        {
            return new ExampleQualityResult(false, "EXAMPLE_RUNTIME_TYPE_NAME_OUTCOME",
                $"The example for `{target.DisplayName}` uses a runtime implementation type name as its visible outcome. Show application behavior, resolved data, configured state, an HTTP response, or another result that explains why a caller uses the API.", 13);
        }

        if (Regex.IsMatch(section.Body,
                @"(?i)\b(?:the documented type|the documented extension method|documented API at runtime|starting point for the extension surface)\b") ||
            Regex.IsMatch(combinedCode,
                @"(?i)\b(?:DocumentedTypeExample|DocumentedExtensionExample|Cuemon\.DocFxExamples)\b") ||
            Regex.IsMatch(combinedCode,
                @"(?is)\bclass\s+\w*(?:Documented|Example)\w*\b.*\b(?:string|Type)\s+Describe\s*\(\s*\)"))
        {
            return new ExampleQualityResult(false, "EXAMPLE_PLACEHOLDER",
                $"The example for `{target.DisplayName}` contains generic generated scaffolding instead of a consumer scenario. Replace placeholder prose and helper names with a focused example derived from tests, source, or package documentation.", 10);
        }

        var hasReflectionLookup = Regex.IsMatch(combinedCode, @"\b(?:Type|Assembly)\.GetType\s*\(") ||
                                  Regex.IsMatch(combinedCode, @"\.Assembly\.GetType\s*\(");

        if (IsApplicationEntryPointTarget(target) && HasEmptyProgramStub(codeWithoutCommentsOrStrings))
        {
            return new ExampleQualityResult(false, "EXAMPLE_EMPTY_ENTRY_POINT_STUB",
                $"The example for `{target.DisplayName}` declares an empty local `Program` type while claiming to bootstrap an application entry point. Use a real minimal or conventional entry point, identify the application-project prerequisite, and demonstrate behavior supplied by that application.", 15);
        }

        if (target.Kind == ApiTargetKind.ExtensionMethod)
        {
            if (!HasMethodInvocation(codeWithoutCommentsOrStrings, target.DisplayName))
            {
                if (hasReflectionLookup)
                {
                    return new ExampleQualityResult(false, "EXAMPLE_REFLECTION_ONLY",
                        $"The example for `{target.DisplayName}` substitutes reflection metadata lookup for an extension-method call. Show a real receiver and invoke the method in C#.", 20);
                }

                return new ExampleQualityResult(false, "EXTENSION_EXAMPLE_NOT_INVOKED",
                    $"The C# example for extension method `{target.DisplayName}` never invokes that method. Mentions in prose, comments, strings, or metadata lookups do not satisfy the example requirement.", 30);
            }

            if (TryFindAvoidableFrameworkQualification(codeWithoutCommentsOrStrings, out var frameworkQualifiedReference))
            {
                return new ExampleQualityResult(false, "EXAMPLE_FULLY_QUALIFIED_FRAMEWORK_TYPE",
                    $"The example for `{target.DisplayName}` uses fully qualified framework reference `{frameworkQualifiedReference}` in executable code. Add the matching `using` directive and keep the call site focused on the documented API unless qualification is genuinely required to disambiguate.", 18);
            }

            var extensionNarrative = ValidateExampleNarrative(scope, target, codeBlocks);
            if (!extensionNarrative.Valid)
            {
                return extensionNarrative;
            }

            return ExampleQualityResult.Success;
        }

        var usesTargetType = Regex.IsMatch(codeWithoutCommentsOrStrings,
            $@"\b{Regex.Escape(target.DisplayName)}\b");
        var invokesRelatedExtension = relatedExtensionMethods.Any(method =>
            HasMethodInvocation(codeWithoutCommentsOrStrings, method));
        if (!usesTargetType && !invokesRelatedExtension)
        {
            if (hasReflectionLookup)
            {
                return new ExampleQualityResult(false, "EXAMPLE_REFLECTION_ONLY",
                    $"The example for `{target.DisplayName}` substitutes reflection metadata lookup for real API use. Show a real input, construct or call the API, and make the result or next action visible.", 20);
            }

            return new ExampleQualityResult(false, "EXAMPLE_TARGET_NOT_USED",
                $"The C# example mapped to `{target.Uid}` does not use `{target.DisplayName}`. Reference or exercise the documented type in code; mentions in prose, comments, strings, `typeof`, `nameof`, or reflection do not count.", 40);
        }

        var metadataOnly = Regex.Replace(codeWithoutCommentsOrStrings,
            $@"\b(?:typeof|nameof)\s*\(\s*{Regex.Escape(target.DisplayName)}(?:<[^>]+>)?\s*\)", string.Empty);
        if (!invokesRelatedExtension && !Regex.IsMatch(metadataOnly, $@"\b{Regex.Escape(target.DisplayName)}\b"))
        {
            return new ExampleQualityResult(false, "EXAMPLE_TARGET_NOT_USED",
                $"The C# example for `{target.DisplayName}` only names the type as metadata. Construct it, call it, configure it, or otherwise demonstrate a consumer-visible operation.", 40);
        }

        // The target is referenced beyond metadata; now reject scaffolds that mention it without
        // demonstrating a real consumer scenario. These are the dominant Cuemon filler patterns.
        if (!invokesRelatedExtension)
        {
            if (IsDefaultTargetHolder(codeWithoutCommentsOrStrings, target.DisplayName))
            {
                return new ExampleQualityResult(false, "EXAMPLE_DEFAULT_PLACEHOLDER",
                    $"The example for `{target.DisplayName}` only parks the type in a `default!`/`null!` holder property or field instead of constructing and using it. Replace the placeholder with a scenario that builds the type and produces an observable result or next action.", 8);
            }

            if (IsForwardingScaffold(codeWithoutCommentsOrStrings))
            {
                return new ExampleQualityResult(false, "EXAMPLE_FORWARDING_SCAFFOLD",
                    $"The example for `{target.DisplayName}` is dominated by one-line pass-through members that only re-expose documented API without a scenario. Show a consumer task with an operation and a visible result instead of a mechanical forwarding wrapper.", 12);
            }

            if (!HasObservableOutcome(codeWithoutCommentsOrStrings))
            {
                return new ExampleQualityResult(false, "EXAMPLE_NO_OBSERVABLE_OUTCOME",
                    $"The example for `{target.DisplayName}` only holds, returns, or constructs the type without an observable outcome. Configure it, invoke a member, pass it to an API, or otherwise produce a result a reader can see. For example, `return new {target.DisplayName}();` or a branch with placeholder comments still fails; printing a value produced by the API, showing configured state, or passing the value to a real consumer API gives the reader an observable result.", 14);
            }
        }

        if (relatedExtensionMethods.Count > 0)
        {
            var leadParagraph = ExtractLeadingNarrativeParagraph(section.Body);
            if (HasExtensionBlockSyntaxLedProse(leadParagraph))
            {
                return new ExampleQualityResult(false, "EXAMPLE_EXTENSION_CONTAINER_LANGUAGE_FOCUS",
                    $"The overwrite page for `{target.DisplayName}` leads with C# extension-block syntax instead of the caller task and outcome. Rewrite the opening around what the extensions let the receiver do, and keep any DocFX limitation note separate from the lead paragraph.", 16);
            }
        }

        if (TryFindAvoidableFrameworkQualification(codeWithoutCommentsOrStrings, out var fullyQualifiedFrameworkReference))
        {
            return new ExampleQualityResult(false, "EXAMPLE_FULLY_QUALIFIED_FRAMEWORK_TYPE",
                $"The example for `{target.DisplayName}` uses fully qualified framework reference `{fullyQualifiedFrameworkReference}` in executable code. Add the matching `using` directive and keep the call site focused on the documented API unless qualification is genuinely required to disambiguate.", 18);
        }

        var narrative = ValidateExampleNarrative(scope, target, codeBlocks);
        if (!narrative.Valid)
        {
            return narrative;
        }

        return ExampleQualityResult.Success;
    }

    private static bool IsApplicationEntryPointTarget(ApiTargetInfo target)
    {
        return target.Kind == ApiTargetKind.Type &&
               Regex.IsMatch(target.DisplayName,
                   @"^(?:(?:Web)?Application(?:Test)?|App|WebTest|Host)(?:Factory|Fixture)(?:<.*>)?$");
    }

    private static bool HasEmptyProgramStub(string code)
    {
        if (!Regex.IsMatch(code, @"<\s*Program\s*>") &&
            !Regex.IsMatch(code, @"<\s*Program\s*,") &&
            !Regex.IsMatch(code, @",\s*Program\s*>"))
        {
            return false;
        }

        return Regex.IsMatch(code,
            @"(?s)\b(?:class|record(?:\s+class)?|struct)\s+Program\b(?:\s*:\s*[^\{;\r\n]+)?\s*(?:\{\s*\}|;)");
    }

    private static ExampleQualityResult ValidateExampleNarrative(string scope, ApiTargetInfo target, List<string> codeBlocks)
    {
        var lead = ExtractExampleLeadParagraph(scope);
        if (!IsMeaningfulExampleLead(lead))
        {
            return new ExampleQualityResult(false, "EXAMPLE_LEAD_MISSING",
                $"The example for `{target.DisplayName}` starts with code or thin placeholder prose. Add a short human-written fly-in before the C# fence that explains the consumer task and expected outcome.", 22);
        }

        if (IsAdvancedExample(codeBlocks) && !HasAdvancedExampleContext(lead))
        {
            return new ExampleQualityResult(false, "EXAMPLE_ADVANCED_LEAD_MISSING",
                $"The example for `{target.DisplayName}` is large or multi-part but its fly-in does not explain the setup, prerequisite, or workflow outcome. Add a more in-depth lead paragraph before the C# fence.", 24);
        }

        return ExampleQualityResult.Success;
    }

    // A target-typed property/field whose initializer is `default`, `default!`, or `null!` only
    // names the type. Treat it as a placeholder unless the example also constructs the type, which
    // would indicate a legitimate field that a later operation consumes.
    private static bool IsDefaultTargetHolder(string code, string target)
    {
        var holder = Regex.IsMatch(code,
            $@"(?<![\w.]){Regex.Escape(target)}(?:<[^>]*>)?\s+[A-Za-z_]\w*\s*(?:\{{[^{{}}]*\}}\s*)?=\s*(?:default\s*!?|null\s*!)\s*;");
        if (!holder)
        {
            return false;
        }

        var constructsTarget = Regex.IsMatch(code, $@"\bnew\s+{Regex.Escape(target)}\b") ||
                               Regex.IsMatch(code, $@"\bnew\s*\(\s*\)\s*;?\s*$");
        return !constructsTarget;
    }

    // Mass forwarding shells re-expose documented members through several one-line, expression-bodied
    // pass-throughs (`Name(args) => other.Member(args);`) and contain no other behavior. A single
    // forwarder is the normal shape of an extension example, so this only fires when forwarders
    // dominate and no statement body, local, initializer, or output demonstrates a scenario.
    private static bool IsForwardingScaffold(string code)
    {
        var forwarders = Regex.Matches(code,
            @"\b[A-Za-z_]\w*\s*\([^()]*\)\s*=>\s*[^;{}]*\b[A-Za-z_]\w*\s*(?:\.[A-Za-z_]\w*)*\s*(?:\([^;]*\))?\s*;")
            .Count;
        if (forwarders < 2)
        {
            return false;
        }

        var hasStatementBody = Regex.IsMatch(code, @"\)\s*\{[^{}]*;[^{}]*\}");
        var hasLocal = Regex.IsMatch(code, @"(?<![\w.])(?:var|return)\s+") &&
                       !Regex.IsMatch(code, @"=>\s*[^;{}]*\breturn\b");
        var hasInitializer = Regex.IsMatch(code, @"\{\s*[@A-Za-z_]\w*\s*=");
        var hasOutput = Regex.IsMatch(code, @"\b(?:Console|Debug|Trace)\s*\.");
        if (forwarders >= 3)
        {
            return !hasStatementBody && !hasInitializer && !hasOutput;
        }

        return !hasStatementBody && !hasLocal && !hasInitializer && !hasOutput;
    }

    // An observable outcome is a member invocation, an object/collection initializer that configures
    // state, an awaited operation, or visible output. Examples that merely construct, hold, or return
    // the target without any of these do not teach what the API does.
    private static bool HasObservableOutcome(string code)
    {
        return Regex.IsMatch(code, @"(?<![\w.])(?!new\b)[A-Za-z_]\w*\s*\.\s*[A-Za-z_]\w*\s*\(") ||
               Regex.IsMatch(code, @"\{\s*[@A-Za-z_]\w*\s*=") ||
               Regex.IsMatch(code, @"\bawait\b") ||
               Regex.IsMatch(code, @"\b(?:Console|Debug|Trace)\s*\.");
    }

    private static string? ExtractLeadingNarrativeParagraph(string body)
    {
        foreach (var paragraph in body.Replace("\r\n", "\n", StringComparison.Ordinal).Replace('\r', '\n')
                     .Split("\n\n", StringSplitOptions.None))
        {
            var trimmed = paragraph.Trim();
            if (trimmed.Length == 0)
            {
                continue;
            }

            if (trimmed.StartsWith("[!INCLUDE", StringComparison.OrdinalIgnoreCase) ||
                trimmed.StartsWith("<!--", StringComparison.Ordinal) ||
                trimmed.StartsWith('#') ||
                trimmed.StartsWith("```", StringComparison.Ordinal) ||
                trimmed.StartsWith('|') ||
                Regex.IsMatch(trimmed, @"^(?i)(?:Availability|Related)\s*:"))
            {
                continue;
            }

            return Regex.Replace(trimmed, @"\s+", " ");
        }

        return null;
    }

    private static string? ExtractExampleLeadParagraph(string scope)
    {
        var normalized = scope.Replace("\r\n", "\n", StringComparison.Ordinal).Replace('\r', '\n');
        var firstFence = Regex.Match(normalized, @"(?im)^```\s*(?:csharp|cs)\s*$");
        var beforeFence = firstFence.Success ? normalized[..firstFence.Index] : normalized;
        return ExtractLeadingNarrativeParagraph(beforeFence);
    }

    private static bool IsMeaningfulExampleLead(string? prose)
    {
        if (string.IsNullOrWhiteSpace(prose))
        {
            return false;
        }

        if (Regex.IsMatch(prose,
                @"(?i)\b(?:the documented type|the documented extension method|documented API|example placeholder|todo)\b"))
        {
            return false;
        }

        return CountWords(prose) >= 8;
    }

    private static bool IsAdvancedExample(List<string> codeBlocks)
    {
        if (codeBlocks.Count > 1)
        {
            return true;
        }

        var combined = string.Join(Environment.NewLine, codeBlocks);
        var nonBlankLines = combined.Replace("\r\n", "\n", StringComparison.Ordinal).Replace('\r', '\n')
            .Split('\n')
            .Count(line => line.Trim().Length > 0);
        if (nonBlankLines >= 35)
        {
            return true;
        }

        var typeDeclarations = Regex.Matches(combined, @"(?m)^\s*(?:public|private|internal)?\s*(?:sealed\s+|static\s+|partial\s+|abstract\s+)*\b(?:class|struct|record)\b").Count;
        if (typeDeclarations >= 3)
        {
            return true;
        }

        return nonBlankLines >= 20 && Regex.IsMatch(combined,
            @"(?i)\b(?:Host\.Create|WebApplication|ServiceCollection|ConfigurationBuilder|IServiceCollection|await|async|HttpClient|JsonSerializerOptions)\b");
    }

    private static bool HasAdvancedExampleContext(string? prose)
    {
        if (string.IsNullOrWhiteSpace(prose))
        {
            return false;
        }

        if (CountSentenceLikeSegments(prose) >= 2)
        {
            return true;
        }

        return CountWords(prose) >= 16 &&
               Regex.IsMatch(prose,
                   @"(?i)\b(?:when|before|after|because|so that|requires?|configure|register|wire|build|pipeline|workflow|scenario|setup|prerequisite|outcome|result)\b");
    }

    private static int CountWords(string prose)
    {
        return Regex.Matches(prose, @"\b[\p{L}\p{N}][\p{L}\p{N}'-]*\b").Count;
    }

    private static int CountSentenceLikeSegments(string prose)
    {
        return Regex.Matches(prose, @"[.!?](?:\s|$)").Count;
    }

    private static bool HasExtensionBlockSyntaxLedProse(string? prose)
    {
        if (string.IsNullOrWhiteSpace(prose))
        {
            return false;
        }

        return Regex.IsMatch(prose,
            @"(?i)\b(?:through|via|using|declared with)\s+(?:C#\s*\d+\s+)?extension blocks?\b") ||
               Regex.IsMatch(prose, @"(?i)\bC#\s*\d+\s+extension blocks?\b");
    }

    private static bool TryFindAvoidableFrameworkQualification(string code, out string qualifiedReference)
    {
        foreach (var rawLine in code.Replace("\r\n", "\n", StringComparison.Ordinal).Replace('\r', '\n').Split('\n'))
        {
            var line = rawLine.Trim();
            if (line.Length == 0 ||
                line.StartsWith("using ", StringComparison.Ordinal) ||
                line.StartsWith("global using ", StringComparison.Ordinal) ||
                line.StartsWith("namespace ", StringComparison.Ordinal))
            {
                continue;
            }

            var match = Regex.Match(line, @"\b(?<qualified>(?:System|Microsoft)(?:\.[A-Za-z_][A-Za-z0-9_]*){2,})\b");
            if (match.Success)
            {
                qualifiedReference = match.Groups["qualified"].Value;
                return true;
            }
        }

        qualifiedReference = string.Empty;
        return false;
    }

    private static string StripCodeCommentsAndStrings(string code)
    {
        var lines = code.Replace("\r\n", "\n", StringComparison.Ordinal).Replace('\r', '\n').Split('\n');
        return string.Join("\n", StripCommentsAndStrings(lines));
    }

    private static bool HasMethodInvocation(string code, string methodName)
    {
        methodName = MethodBaseName(methodName);
        return Regex.IsMatch(code,
            $@"(?:\.|\b){Regex.Escape(methodName)}(?:\s*<[^>\r\n]+>)?\s*\(");
    }

    private static List<string> ExtractCSharpCodeBlocks(string body)
    {
        if (string.IsNullOrEmpty(body))
        {
            return new List<string>();
        }

        var normalized = body.Replace("\r\n", "\n", StringComparison.Ordinal).Replace('\r', '\n');
        return Regex.Matches(normalized,
                @"(?ms)^```\s*(?:csharp|cs)\s*$\n(?<code>.*?)^```\s*$")
            .Select(match => match.Groups["code"].Value)
            .ToList();
    }

    private static string ExtractExampleSection(string body)
    {
        var match = Regex.Match(body, @"(?im)^#{2,5}\s+Examples?\s*$");
        if (!match.Success)
        {
            return string.Empty;
        }

        var section = body[match.Index..];
        var nextHeading = Regex.Match(section[match.Length..], @"(?im)^#{1,5}\s+\S");
        if (nextHeading.Success)
        {
            section = section[..(match.Length + nextHeading.Index)];
        }

        return section;
    }

    // ----------------------------------------------------------------------
    // Sample validation
    // ----------------------------------------------------------------------

    private static void ValidateSamples(ValidationWorkspace ws, Options options, HashSet<string>? changedFiles,
        bool hasStrongNameKey, int defaultParallelism, Report report)
    {
        var repoRoot = ws.RepoRoot;

        // 1. Extract all C# samples from cached Markdown text.
        var phaseTimer = Stopwatch.StartNew();
        var samples = new List<SampleFence>();
        foreach (var md in ws.MarkdownFiles)
        {
            if (options.ChangedOnly && changedFiles is not null && !changedFiles.Contains(Path.GetFullPath(md)))
            {
                continue;
            }

            samples.AddRange(ExtractFences(md, ws.ReadMarkdown(md)));
        }

        WritePhase(options, report, "sample extraction", phaseTimer.Elapsed, $"{samples.Count} fence(s)");
        if (samples.Count == 0)
        {
            WriteSkippedPhase(options, report, "sample validation", "no C# samples found");
            return;
        }

        // 2. Pre-validate structure (skip/structure checks) — no compilation.
        //    Record which samples need compilation and their original index for deterministic ordering.
        var toCompile = new List<(SampleFence Sample, int OriginalIndex)>(samples.Count);
        for (int i = 0; i < samples.Count; i++)
        {
            var sample = samples[i];
            var skip = FindSkip(sample.Code);
            if (skip.Found)
            {
                var owner = ResolveSampleOwner(ws, sample);
                var existedBeforeRun = SkipMarkerExistedBeforeRun(ws, sample, owner, skip);
                var approvedEntry = FindApprovedSkipEntry(ws, sample, owner, skip);
                report.SkipMarkers.Add(new SkipMarkerReport
                {
                    DiagnosticCode = approvedEntry is not null ? approvedEntry.DiagnosticCode : "SAMPLE_COMPILE_FAILED",
                    FilePath = Rel(repoRoot, sample.File),
                    Uid = owner.Uid,
                    Symbol = owner.Symbol,
                    MarkerText = skip.Text,
                    Reason = skip.Reason,
                    Approved = approvedEntry is not null,
                    ExistedBeforeRun = existedBeforeRun,
                    Approval = approvedEntry?.Approval,
                    Lifetime = approvedEntry?.Lifetime
                });

                if (!existedBeforeRun)
                {
                    report.Summary.NewlyIntroducedSkipMarkers++;
                    report.Errors.Add(new Diagnostic("FAIL_NEW_SKIP_MARKER_INTRODUCED", Rel(repoRoot, sample.File), null,
                        $"C# sample at fence #{sample.FenceIndex} (line {sample.StartLine}) introduced a new skip marker during the current run. UID/symbol: '{owner.DisplayName}'. Marker: '{skip.Text}'. Reason: '{skip.Reason}'. existedBeforeRun=false. New skip markers are fail-level diagnostics and do not permit a completion claim.",
                        owner.Uid, owner.Symbol));
                }

                if (string.IsNullOrWhiteSpace(skip.Reason))
                {
                    report.Errors.Add(new Diagnostic("SAMPLE_SKIP_REASON_MISSING", Rel(repoRoot, sample.File), null,
                        $"A C# sample at fence #{sample.FenceIndex} (line {sample.StartLine}) uses the skip-compile marker without a mandatory reason. UID/symbol: '{owner.DisplayName}'. Marker: '{skip.Text}'. existedBeforeRun={existedBeforeRun.ToString().ToLowerInvariant()}.",
                        owner.Uid, owner.Symbol));
                }
                else if (IsInsufficientSkipReason(skip.Reason))
                {
                    report.Errors.Add(new Diagnostic("SAMPLE_SKIP_REASON_INSUFFICIENT", Rel(repoRoot, sample.File), null,
                        $"A C# sample at fence #{sample.FenceIndex} (line {sample.StartLine}) uses a weak skip-compile reason: '{skip.Reason}'. UID/symbol: '{owner.DisplayName}'. Marker: '{skip.Text}'. existedBeforeRun={existedBeforeRun.ToString().ToLowerInvariant()}. Package requirements, framework-pattern explanations, or full-example notes are documentation work, not a compile opt-out. Make the sample compile, document the package requirement outside the code fence, or use a deterministic blocker such as an external service or host environment that the sample compiler cannot provide.",
                        owner.Uid, owner.Symbol));
                }
                else if (approvedEntry is null)
                {
                    report.Summary.UnapprovedSkipMarkers++;
                    report.Errors.Add(new Diagnostic("SAMPLE_SKIP_NOT_ALLOWLISTED", Rel(repoRoot, sample.File), null,
                        $"A C# sample at fence #{sample.FenceIndex} (line {sample.StartLine}) uses the skip-compile marker without a matching pre-approved allowlist entry in '{SkipAllowlistFileName}'. UID/symbol: '{owner.DisplayName}'. Marker: '{skip.Text}'. Reason: '{skip.Reason}'. existedBeforeRun={existedBeforeRun.ToString().ToLowerInvariant()}. Unapproved or newly introduced skip markers do not suppress compilation; the sample must still compile or fail deterministically.",
                        owner.Uid, owner.Symbol));
                }
                else if (existedBeforeRun)
                {
                    report.Summary.PreExistingApprovedSkipMarkers++;
                    report.Summary.SamplesSkipped++;
                    continue;
                }
            }

            var structureError = ValidateSampleStructure(sample.Code);
            if (structureError is not null)
            {
                report.Errors.Add(new Diagnostic("SAMPLE_STRUCTURE_INVALID", Rel(repoRoot, sample.File), null,
                    $"C# sample at fence #{sample.FenceIndex} (line {sample.StartLine}) failed structure validation: {structureError}"));
                continue;
            }

            toCompile.Add((sample, i));
        }

        if (toCompile.Count == 0)
        {
            WriteSkippedPhase(options, report, "sample validation", "no compilable samples");
            return;
        }

        // 3. Resolve a scoped project/package reference set per sample, then group samples that
        //    share a reference set. Each group compiles against ONLY the documented project(s)
        //    that own the sample's namespace (and their transitive references resolved by MSBuild),
        //    never every documented library project. Samples whose owner cannot be resolved fall
        //    back to the full documented project set, which forms a single shared group.
        EnsureNamespaceProjectMap(ws);
        var framework = options.Framework ?? "net10.0";
        var packageMode = string.Equals(options.SampleReferenceMode, "package", StringComparison.OrdinalIgnoreCase);

        var groups = new Dictionary<string, List<(SampleFence Sample, int OriginalIndex)>>(StringComparer.Ordinal);
        var sampleRefs = new Dictionary<int, SampleReferenceSet>();
        foreach (var entry in toCompile)
        {
            var kind = IsProgramCsExample(entry.Sample.Code) ? "app" : "lib";
            var refSet = ResolveSampleReferenceSet(entry.Sample, ws, kind, packageMode);
            var key = $"{kind}::{(refSet.IsPackageMode ? "pkg" : "proj")}::{string.Join(";", refSet.Items)}";
            if (!groups.TryGetValue(key, out var list))
            {
                list = new List<(SampleFence, int)>();
                groups[key] = list;
            }

            list.Add(entry);
            sampleRefs[entry.OriginalIndex] = refSet;
        }

        var tempRoot = Path.Combine(Path.GetTempPath(), "docfx-digest-samples-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(tempRoot);
        try
        {
            var parallelism = GetSampleValidationParallelism(options, defaultParallelism);
            var workerCount = Math.Min(parallelism, toCompile.Count);
            WritePhaseStart(options, "sample validation", workerCount, toCompile.Count);
            phaseTimer.Restart();

            // Results are stored in a pre-sized indexed array to guarantee deterministic
            // diagnostic ordering regardless of MSBuild project completion order.
            var results = new SampleCompileResult?[samples.Count];
            var workers = new List<SampleWorker>(toCompile.Count);
            for (var i = 0; i < toCompile.Count; i++)
            {
                var (sample, originalIndex) = toCompile[i];
                workers.Add(CreateSampleWorker(tempRoot, i + 1, originalIndex, sample,
                    sampleRefs[originalIndex], framework));
            }

            var batchResult = CompileSampleBatch(tempRoot, workers, options.Configuration,
                parallelism, hasStrongNameKey);
            foreach (var worker in workers)
            {
                var outputAssembly = Path.Combine(worker.Directory, "bin", options.Configuration,
                    framework, worker.AssemblyName + ".dll");
                var ok = batchResult.ExitCode == 0 || File.Exists(outputAssembly);
                var diagnostics = ok ? string.Empty : ExtractSampleDiagnostics(batchResult, worker);
                results[worker.OriginalIndex] = new SampleCompileResult(ok, diagnostics, batchResult.ExitCode);
            }

            WritePhase(options, report, "sample validation", phaseTimer.Elapsed,
                $"1 batch, {groups.Count} reference set(s), {toCompile.Count} sample(s), max {parallelism} worker(s)");

            // 4. Merge results in original sample order for deterministic diagnostics.
            for (int i = 0; i < samples.Count; i++)
            {
                var result = results[i];
                if (result is null)
                {
                    continue; // was skipped or had a structure error
                }

                if (result.Ok)
                {
                    report.Summary.SamplesCompiled++;
                }
                else
                {
                    var sample = samples[i];
                    report.Errors.Add(new Diagnostic("SAMPLE_COMPILE_FAILED", Rel(repoRoot, sample.File), null,
                        $"C# sample at fence #{sample.FenceIndex} (line {sample.StartLine}) failed to compile (exit {result.ExitCode}).\n{Trim(result.Diagnostics)}"));
                }
            }
        }
        finally
        {
            TryDeleteDirectory(tempRoot);
        }
    }

    /// <summary>
    /// Resolves the minimal set of documented project (or package) references a sample needs by
    /// mapping the sample's owning namespace to the project(s) that declare it. Falls back to the
    /// full documented project set only when the owner cannot be determined.
    /// </summary>
    private static SampleReferenceSet ResolveSampleReferenceSet(SampleFence sample, ValidationWorkspace ws, string kind, bool packageMode)
    {
        var owners = ResolveOwningProjects(sample, ws);
        if (owners.Count == 0)
        {
            owners = ws.LibraryProjects;
        }

        owners = owners
            .GroupBy(p => Path.GetFullPath(p.Path), StringComparer.OrdinalIgnoreCase)
            .Select(g => g.First())
            .OrderBy(p => Path.GetFullPath(p.Path), StringComparer.OrdinalIgnoreCase)
            .ToList();

        if (packageMode)
        {
            var packageRefs = new List<(string Id, string Version)>();
            var projectRefs = new List<ProjectInfo>();
            foreach (var owner in owners)
            {
                if (!string.IsNullOrWhiteSpace(owner.PackageId))
                {
                    packageRefs.Add((owner.PackageId!, "*"));
                }
                else
                {
                    projectRefs.Add(owner);
                }
            }

            var items = packageRefs.Select(p => $"pkg:{p.Id}@{p.Version}")
                .Concat(projectRefs.Select(p => $"proj:{Path.GetFullPath(p.Path)}"))
                .OrderBy(s => s, StringComparer.OrdinalIgnoreCase)
                .ToList();
            return new SampleReferenceSet(kind, true, items, projectRefs, packageRefs);
        }

        var projectItems = owners.Select(p => Path.GetFullPath(p.Path))
            .OrderBy(s => s, StringComparer.OrdinalIgnoreCase)
            .ToList();
        return new SampleReferenceSet(kind, false, projectItems, owners, new List<(string, string)>());
    }

    private static List<ProjectInfo> ResolveOwningProjects(SampleFence sample, ValidationWorkspace ws)
    {
        var ns = ResolveSampleNamespace(sample, ws);
        if (ns is not null && ws.NamespaceProjects.TryGetValue(ns, out var projects) && projects.Count > 0)
        {
            return projects.ToList();
        }

        return new List<ProjectInfo>();
    }

    private static string? ResolveSampleNamespace(SampleFence sample, ValidationWorkspace ws)
    {
        // Prefer the overwrite uid(s) authored in the sample's file.
        foreach (var section in ws.OverwriteSections.Where(s => PathsEqual(s.File, sample.File)))
        {
            if (ws.NamespaceProjects.ContainsKey(section.Uid))
            {
                return section.Uid;
            }

            var prefix = LongestNamespacePrefix(section.Uid, ws);
            if (prefix is not null)
            {
                return prefix;
            }
        }

        // Fall back to the file stem (namespace pages are named after the namespace).
        var stem = Path.GetFileNameWithoutExtension(sample.File);
        if (ws.NamespaceProjects.ContainsKey(stem))
        {
            return stem;
        }

        return LongestNamespacePrefix(stem, ws);
    }

    private static string? LongestNamespacePrefix(string uid, ValidationWorkspace ws)
    {
        string? best = null;
        foreach (var ns in ws.NamespaceProjects.Keys)
        {
            if (string.Equals(uid, ns, StringComparison.Ordinal) ||
                uid.StartsWith(ns + ".", StringComparison.Ordinal))
            {
                if (best is null || ns.Length > best.Length)
                {
                    best = ns;
                }
            }
        }

        return best;
    }

    private static int GetSampleValidationParallelism(Options options, int defaultParallelism)
    {
        var processorCount = Math.Max(1, Environment.ProcessorCount);
        const int MaxSupportedParallelism = 16;

        // CLI argument takes precedence over the environment variable.
        if (options.SampleParallelism.HasValue)
        {
            return Math.Max(1, Math.Min(options.SampleParallelism.Value, Math.Min(processorCount, MaxSupportedParallelism)));
        }

        var rawValue = Environment.GetEnvironmentVariable("DOCFX_DIGEST_SAMPLE_PARALLELISM");
        if (int.TryParse(rawValue, System.Globalization.NumberStyles.Integer,
                System.Globalization.CultureInfo.InvariantCulture, out var configured) && configured > 0)
        {
            return Math.Min(configured, Math.Min(processorCount, MaxSupportedParallelism));
        }

        return defaultParallelism;
    }

    /// <summary>
    /// Creates an isolated sample project under <paramref name="tempRoot"/> that references only
    /// the resolved scoped project/package set. All sample projects are later restored and built
    /// together through one temporary solution graph.
    /// </summary>
    private static SampleWorker CreateSampleWorker(
        string tempRoot, int sampleNumber, int originalIndex, SampleFence sample,
        SampleReferenceSet refSet, string framework)
    {
        var isApp = string.Equals(refSet.Kind, "app", StringComparison.Ordinal);
        var assemblyName = $"DocfxSample{sampleNumber:D4}";
        var workerDir = Path.Combine(tempRoot, "docfx-sample-workers", assemblyName);
        Directory.CreateDirectory(workerDir);

        var projPath = Path.Combine(workerDir, assemblyName + ".csproj");
        File.WriteAllText(projPath, GenerateSampleProject(refSet, framework, isApp), new UTF8Encoding(false));

        var sourceName = isApp ? "Program.cs" : "Sample.cs";
        var sourcePath = Path.Combine(workerDir, sourceName);
        File.WriteAllText(sourcePath, sample.Code, new UTF8Encoding(false));

        return new SampleWorker(originalIndex, workerDir, projPath, sourcePath, assemblyName);
    }

    private static string GenerateSampleProject(SampleReferenceSet refSet, string framework, bool isApp)
    {
        var sb = new StringBuilder();
        sb.AppendLine("""<Project Sdk="Microsoft.NET.Sdk">""");
        sb.AppendLine("  <PropertyGroup>");
        sb.AppendLine($"    <TargetFramework>{framework}</TargetFramework>");
        sb.AppendLine(isApp ? "    <OutputType>Exe</OutputType>" : "    <OutputType>Library</OutputType>");
        sb.AppendLine("    <Nullable>enable</Nullable>");
        sb.AppendLine("    <LangVersion>latest</LangVersion>");
        sb.AppendLine(isApp ? "    <PublishAot>false</PublishAot>" : "    <ImplicitUsings>disable</ImplicitUsings>");
        sb.AppendLine("  </PropertyGroup>");

        if (refSet.ProjectReferences.Count > 0 || refSet.PackageReferences.Count > 0)
        {
            sb.AppendLine("  <ItemGroup>");
            foreach (var proj in refSet.ProjectReferences)
            {
                sb.AppendLine($"    <ProjectReference Include=\"{proj.Path}\" />");
            }

            foreach (var (id, version) in refSet.PackageReferences)
            {
                sb.AppendLine($"    <PackageReference Include=\"{id}\" Version=\"{version}\" />");
            }

            sb.AppendLine("  </ItemGroup>");
        }

        sb.AppendLine("</Project>");
        return sb.ToString();
    }

    private static ProcessResult CompileSampleBatch(
        string tempRoot, List<SampleWorker> workers, string configuration, int parallelism,
        bool hasStrongNameKey)
    {
        var solutionPath = Path.Combine(tempRoot, "DocfxSamples.slnx");
        var solution = new StringBuilder();
        solution.AppendLine("<Solution>");
        foreach (var worker in workers)
        {
            solution.AppendLine($"  <Project Path=\"{worker.ProjectPath}\" />");
        }

        solution.AppendLine("</Solution>");
        File.WriteAllText(solutionPath, solution.ToString(), new UTF8Encoding(false));

        var signingProperty = hasStrongNameKey ? string.Empty : " -p:SkipSignAssembly=true";
        return RunProcess("dotnet",
            $"build \"{solutionPath}\" -c {configuration} --nologo -m:{parallelism}{signingProperty}",
            tempRoot, permission: ProcessPermission.SampleCompile,
            progress: new ProcessProgress("sample compilation",
                $"{workers.Count} sample project(s), {parallelism} runner(s)"));
    }

    private static string ExtractSampleDiagnostics(ProcessResult result, SampleWorker worker)
    {
        var output = result.StdOut + result.StdErr;
        var relevant = output
            .Replace("\r\n", "\n", StringComparison.Ordinal)
            .Replace('\r', '\n')
            .Split('\n', StringSplitOptions.RemoveEmptyEntries)
            .Where(line => line.Contains(worker.ProjectPath, StringComparison.OrdinalIgnoreCase) ||
                           line.Contains(worker.SourcePath, StringComparison.OrdinalIgnoreCase))
            .Distinct(StringComparer.Ordinal)
            .ToList();

        var diagnostics = relevant.Count > 0 ? string.Join(Environment.NewLine, relevant) : output;
        return AddSampleCompileHints(diagnostics);
    }

    private static string AddSampleCompileHints(string diagnostics)
    {
        var hints = new List<string>();
        foreach (Match match in Regex.Matches(diagnostics,
                     @"CS1061: .*?definition for '([^']+)' and no accessible extension method",
                     RegexOptions.IgnoreCase | RegexOptions.CultureInvariant))
        {
            var method = match.Groups[1].Value;
            if (IsLinqExtensionMethod(method))
            {
                hints.Add($"Hint: CS1061 for LINQ method `{method}` usually means the sample is missing `using System.Linq;`.");
            }
            else if (string.Equals(method, "AddJob", StringComparison.Ordinal))
            {
                hints.Add("Hint: CS1061 for BenchmarkDotNet `AddJob` usually means the sample is missing `using BenchmarkDotNet.Configs;`, which brings the extension method into scope.");
            }
            else
            {
                hints.Add($"Hint: CS1061 can mean the sample is missing the namespace that defines extension method `{method}`. Add the source-backed `using` directive for that extension method, then rerun `docfx.cs --validate-samples`.");
            }
        }

        if (hints.Count == 0)
        {
            return diagnostics;
        }

        return diagnostics + Environment.NewLine + string.Join(Environment.NewLine, hints.Distinct(StringComparer.Ordinal));
    }

    private static bool IsLinqExtensionMethod(string method)
    {
        return method is "Aggregate" or "All" or "Any" or "Append" or "Average" or "Cast" or "Concat" or
            "Contains" or "Count" or "DefaultIfEmpty" or "Distinct" or "ElementAt" or "Except" or
            "First" or "FirstOrDefault" or "GroupBy" or "GroupJoin" or "Intersect" or "Join" or
            "Last" or "LastOrDefault" or "LongCount" or "Max" or "Min" or "OfType" or "OrderBy" or
            "OrderByDescending" or "Prepend" or "Reverse" or "Select" or "SelectMany" or "SequenceEqual" or
            "Single" or "SingleOrDefault" or "Skip" or "SkipLast" or "SkipWhile" or "Sum" or "Take" or
            "TakeLast" or "TakeWhile" or "ThenBy" or "ThenByDescending" or "ToArray" or "ToDictionary" or
            "ToHashSet" or "ToList" or "ToLookup" or "Union" or "Where" or "Zip";
    }

    private static void WritePhase(Options options, Report report, string name, TimeSpan elapsed, string? detail = null)
    {
        report.Summary.Phases.Add(new PhaseTiming(name, Math.Round(elapsed.TotalSeconds, 2), detail));
        if (!options.Json)
        {
            var suffix = string.IsNullOrEmpty(detail) ? string.Empty : $" {detail}";
            Console.WriteLine($"  [phase] {name}: {elapsed.TotalSeconds:F2}s{suffix}");
        }
    }

    private static void WriteSkippedPhase(Options options, Report report, string name, string reason)
    {
        report.Summary.Phases.Add(new PhaseTiming(name, 0, reason));
        if (!options.Json)
        {
            Console.WriteLine($"  [phase] {name}: skipped ({reason})");
        }
    }

    private static void WritePhaseStart(Options options, string name, int workers, int count)
    {
        if (!options.Json)
        {
            Console.WriteLine($"  [phase] {name}: {count} sample(s), {workers} worker(s)");
        }
    }

    private static List<SampleFence> ExtractFences(string mdFile)
    {
        string[] lines;
        try
        {
            lines = File.ReadAllLines(mdFile);
        }
        catch
        {
            return new List<SampleFence>();
        }

        return ExtractFencesFromLines(mdFile, lines);
    }

    private static List<SampleFence> ExtractFences(string mdFile, string text)
    {
        var lines = text.Replace("\r\n", "\n").Replace("\r", "\n").Split('\n');
        return ExtractFencesFromLines(mdFile, lines);
    }

    private static List<SampleFence> ExtractFencesFromLines(string mdFile, string[] lines)
    {
        var fences = new List<SampleFence>();
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
        string text;
        try
        {
            text = File.ReadAllText(mdFile);
        }
        catch
        {
            return new List<OverwriteSection>();
        }

        return ExtractOverwriteSections(mdFile, text);
    }

    private static List<OverwriteSection> ExtractOverwriteSections(string mdFile, string text)
    {
        var sections = new List<OverwriteSection>();
        if (string.IsNullOrEmpty(text))
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
            var bodyStartLine = GetLineNumberForIndex(normalized, bodyStart);
            var bodyEndLine = Math.Max(bodyStartLine, GetLineNumberForIndex(normalized, Math.Max(bodyStart, bodyEnd - 1)));
            sections.Add(new OverwriteSection(mdFile, uid, body, IsMappedToExample(yaml), bodyStartLine, bodyEndLine));
        }

        return sections;
    }

    private static int GetLineNumberForIndex(string text, int index)
    {
        if (index <= 0)
        {
            return 1;
        }

        var line = 1;
        for (var i = 0; i < index && i < text.Length; i++)
        {
            if (text[i] == '\n')
            {
                line++;
            }
        }

        return line;
    }

    private static bool IsMappedToExample(string yaml)
    {
        // Form A: example: *content  (inline scalar)
        if (ReadYamlScalar(yaml, "example") is "*content")
        {
            return true;
        }

        // Form B: example:\n  - *content  (sequence / list form)
        var lines = yaml.Split('\n');
        for (var i = 0; i < lines.Length - 1; i++)
        {
            if (lines[i].Trim() == "example:")
            {
                var next = lines[i + 1].Trim();
                if (next == "- *content")
                {
                    return true;
                }
            }
        }

        return false;
    }

    private static string? ValidateSampleStructure(string code)
    {
        // Examples explicitly labelled // Program.cs may use top-level statements.
        if (IsProgramCsExample(code))
        {
            return null;
        }

        // A namespace declaration: file-scoped (namespace X;) or block-scoped (namespace X {)
        bool hasNamespace = Regex.IsMatch(code, @"^\s*namespace\s+[\w.]+", RegexOptions.Multiline);

        // A type declaration: class Foo, struct Foo, or record Foo (with or without access modifiers)
        bool hasTypeDeclaration = Regex.IsMatch(code, @"\b(class|struct|record)\s+\w+");

        if (!hasNamespace && !hasTypeDeclaration)
        {
            return "Example uses top-level statements without a namespace or type declaration. " +
                   "All csharp code blocks must include a file-scoped namespace declaration (e.g., 'namespace X.Y;') " +
                   "and at least one class, struct, or record declaration wrapping the usage code. " +
                   "Label the example '// Program.cs' at the very top to allow top-level statements for console app examples.";
        }

        if (!hasNamespace)
        {
            return "Example has a type declaration but is missing a namespace declaration. " +
                   "Add a file-scoped namespace such as 'namespace X.Y;' before the type declaration.";
        }

        if (!hasTypeDeclaration)
        {
            return "Example declares a namespace but contains no class, struct, or record declaration. " +
                   "Wrap the usage code inside a class.";
        }

        return null;
    }

    private static bool IsProgramCsExample(string code)
    {
        foreach (var line in code.Split('\n'))
        {
            var trimmed = line.Trim();
            if (trimmed.StartsWith("//", StringComparison.Ordinal) &&
                trimmed.Contains("Program.cs", StringComparison.OrdinalIgnoreCase))
            {
                return true;
            }

            // Stop checking once non-blank, non-comment, non-directive content begins.
            if (trimmed.Length > 0 &&
                !trimmed.StartsWith("//", StringComparison.Ordinal) &&
                !trimmed.StartsWith("#", StringComparison.Ordinal))
            {
                break;
            }
        }

        return false;
    }

    private static SkipMarkerInfo FindSkip(string code)
    {
        var lines = code.Split('\n');
        for (var i = 0; i < lines.Length; i++)
        {
            var line = lines[i];
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

            return new SkipMarkerInfo(true, line.Trim(), after, i + 1);
        }

        return new SkipMarkerInfo(false, string.Empty, string.Empty, 0);
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

        // Missing compile-time references are validator defects, not valid skip reasons.
        // All ordinary NuGet, project, and framework references resolve through ProjectReference items.
        if (Regex.IsMatch(reason, @"(?i)\btransitive\s+(assembly|dependency)\b"))
        {
            return true;
        }

        if (Regex.IsMatch(reason, @"(?i)\bsample\s+worker\s+does\s+not\s+include\b"))
        {
            return true;
        }

        if (Regex.IsMatch(reason, @"(?i)\bmissing\s+assembly\b"))
        {
            return true;
        }

        if (Regex.IsMatch(reason, @"(?i)\breferenced\s+assembly\b"))
        {
            return true;
        }

        if (Regex.IsMatch(reason, @"(?i)\bdoes\s+not\s+include\s+that\s+assembly\b"))
        {
            return true;
        }

        if (Regex.IsMatch(reason, @"(?i)\bpublic\s+signature\s+includes\b"))
        {
            return true;
        }

        if (Regex.IsMatch(reason, @"(?i)\bbase\s+class\s+from\s+a\s+transitive\s+assembly\b"))
        {
            return true;
        }

        return false;
    }

    private static SampleOwnerInfo ResolveSampleOwner(ValidationWorkspace ws, SampleFence sample)
    {
        var sections = ws.OverwriteSections
            .Where(section => PathsEqual(section.File, sample.File))
            .OrderBy(section => section.BodyStartLine)
            .ToList();
        return ResolveSampleOwner(sections, sample);
    }

    private static SampleOwnerInfo ResolveSampleOwner(List<OverwriteSection> sections, SampleFence sample)
    {
        var owner = sections.FirstOrDefault(section =>
                        sample.StartLine >= section.BodyStartLine &&
                        sample.StartLine <= section.BodyEndLine) ??
                    sections.FirstOrDefault();

        var uid = owner?.Uid;
        var symbol = !string.IsNullOrWhiteSpace(uid)
            ? uid
            : ExtractPrimarySymbol(sample.Code) ?? Path.GetFileNameWithoutExtension(sample.File);

        return new SampleOwnerInfo(uid, symbol);
    }

    private static string? ExtractPrimarySymbol(string code)
    {
        var match = Regex.Match(code, @"\b(class|struct|record|interface|enum)\s+(?<name>\w+)");
        return match.Success ? match.Groups["name"].Value : null;
    }

    private static ApprovedSkipEntry? FindApprovedSkipEntry(ValidationWorkspace ws, SampleFence sample, SampleOwnerInfo owner,
        SkipMarkerInfo skip)
    {
        return ws.SkipAllowlistEntries.FirstOrDefault(entry =>
            string.Equals(entry.DiagnosticCode, "SAMPLE_COMPILE_FAILED", StringComparison.OrdinalIgnoreCase) &&
            PathsEqual(entry.FullFilePath, sample.File) &&
            (entry.Uid is null || string.Equals(entry.Uid, owner.Uid, StringComparison.Ordinal)) &&
            (entry.Symbol is null || string.Equals(entry.Symbol, owner.Symbol, StringComparison.Ordinal)) &&
            string.Equals(NormalizeSkipReason(entry.Reason), NormalizeSkipReason(skip.Reason), StringComparison.Ordinal));
    }

    private static string NormalizeSkipReason(string reason)
    {
        return Regex.Replace(reason.Trim(), @"\s+", " ");
    }

    private static bool SkipMarkerExistedBeforeRun(ValidationWorkspace ws, SampleFence sample, SampleOwnerInfo owner,
        SkipMarkerInfo skip)
    {
        var baselineMarkers = GetBaselineSkipMarkers(ws, sample.File);
        if (baselineMarkers.Count == 0)
        {
            return false;
        }

        var normalizedReason = NormalizeSkipReason(skip.Reason);
        return baselineMarkers.Any(marker =>
            marker.FenceIndex == sample.FenceIndex &&
            string.Equals(marker.MarkerText, skip.Text, StringComparison.Ordinal) &&
            string.Equals(marker.Reason, normalizedReason, StringComparison.Ordinal) &&
            (owner.Uid is null || marker.Uid is null || string.Equals(marker.Uid, owner.Uid, StringComparison.Ordinal))) ||
               baselineMarkers.Any(marker =>
                   string.Equals(marker.MarkerText, skip.Text, StringComparison.Ordinal) &&
                   string.Equals(marker.Reason, normalizedReason, StringComparison.Ordinal) &&
                   (owner.Uid is null || marker.Uid is null || string.Equals(marker.Uid, owner.Uid, StringComparison.Ordinal)));
    }

    private static List<BaselineSkipMarker> GetBaselineSkipMarkers(ValidationWorkspace ws, string file)
    {
        var fullPath = Path.GetFullPath(file);
        if (ws.BaselineSkipMarkersByFile.TryGetValue(fullPath, out var cached))
        {
            return cached;
        }

        var relativePath = Path.GetRelativePath(ws.RepoRoot, fullPath).Replace('\\', '/');
        var baseline = RunProcess("git", $"show \"HEAD:{relativePath}\"", ws.RepoRoot, permission: ProcessPermission.Git);
        if (baseline.ExitCode != 0 || string.IsNullOrWhiteSpace(baseline.StdOut))
        {
            cached = new List<BaselineSkipMarker>();
            ws.BaselineSkipMarkersByFile[fullPath] = cached;
            return cached;
        }

        var sections = ExtractOverwriteSections(fullPath, baseline.StdOut);
        cached = ExtractFences(fullPath, baseline.StdOut)
            .Select(fence =>
            {
                var marker = FindSkip(fence.Code);
                if (!marker.Found)
                {
                    return null;
                }

                var owner = ResolveSampleOwner(sections, fence);
                return new BaselineSkipMarker(fence.FenceIndex, marker.Text, NormalizeSkipReason(marker.Reason), owner.Uid, owner.Symbol);
            })
            .Where(marker => marker is not null)
            .Cast<BaselineSkipMarker>()
            .ToList();

        ws.BaselineSkipMarkersByFile[fullPath] = cached;
        return cached;
    }

    private static List<ApprovedSkipEntry> LoadApprovedSkipEntries(string repoRoot, string docfxWorkspace, Report report)
    {
        var path = Path.Combine(docfxWorkspace, SkipAllowlistFileName);
        report.SkipAllowlistPath = File.Exists(path) ? Rel(repoRoot, path) : null;
        if (!File.Exists(path))
        {
            return new List<ApprovedSkipEntry>();
        }

        try
        {
            using var doc = JsonDocument.Parse(File.ReadAllText(path), new JsonDocumentOptions
            {
                AllowTrailingCommas = true,
                CommentHandling = JsonCommentHandling.Skip
            });

            if (doc.RootElement.ValueKind != JsonValueKind.Object ||
                !doc.RootElement.TryGetProperty("entries", out var entriesElement) ||
                entriesElement.ValueKind != JsonValueKind.Array)
            {
                report.Errors.Add(new Diagnostic("SKIP_ALLOWLIST_INVALID", Rel(repoRoot, path), null,
                    $"'{SkipAllowlistFileName}' must be a JSON object with an 'entries' array."));
                return new List<ApprovedSkipEntry>();
            }

            var entries = new List<ApprovedSkipEntry>();
            foreach (var entryElement in entriesElement.EnumerateArray())
            {
                if (!TryReadAllowlistEntry(repoRoot, path, entryElement, out var entry, out var error))
                {
                    report.Errors.Add(new Diagnostic("SKIP_ALLOWLIST_INVALID", Rel(repoRoot, path), null, error ?? "Invalid allowlist entry."));
                    continue;
                }

                entries.Add(entry!);
            }

            return entries;
        }
        catch (Exception ex) when (ex is IOException or JsonException)
        {
            report.Errors.Add(new Diagnostic("SKIP_ALLOWLIST_INVALID", Rel(repoRoot, path), null,
                $"Unable to parse '{SkipAllowlistFileName}': {ex.Message}"));
            return new List<ApprovedSkipEntry>();
        }
    }

    private static bool TryReadAllowlistEntry(string repoRoot, string allowlistPath, JsonElement entryElement,
        out ApprovedSkipEntry? entry, out string? error)
    {
        entry = null;
        error = null;
        if (entryElement.ValueKind != JsonValueKind.Object)
        {
            error = $"Entries in '{SkipAllowlistFileName}' must be JSON objects.";
            return false;
        }

        var diagnosticCode = ReadRequiredJsonString(entryElement, "diagnosticCode");
        var filePath = ReadRequiredJsonString(entryElement, "filePath");
        var uid = ReadOptionalJsonString(entryElement, "uid");
        var symbol = ReadOptionalJsonString(entryElement, "symbol");
        var reason = ReadRequiredJsonString(entryElement, "reason");
        var approval = ReadRequiredJsonString(entryElement, "approval");
        var lifetime = ReadRequiredJsonString(entryElement, "lifetime");

        if (string.IsNullOrWhiteSpace(diagnosticCode) ||
            string.IsNullOrWhiteSpace(filePath) ||
            string.IsNullOrWhiteSpace(reason) ||
            string.IsNullOrWhiteSpace(approval) ||
            string.IsNullOrWhiteSpace(lifetime))
        {
            error = $"Each '{SkipAllowlistFileName}' entry must include diagnosticCode, filePath, reason, approval, and lifetime.";
            return false;
        }

        if (string.IsNullOrWhiteSpace(uid) && string.IsNullOrWhiteSpace(symbol))
        {
            error = $"Each '{SkipAllowlistFileName}' entry must include either uid or symbol.";
            return false;
        }

        if (!string.Equals(lifetime, "temporary", StringComparison.OrdinalIgnoreCase) &&
            !string.Equals(lifetime, "permanent", StringComparison.OrdinalIgnoreCase))
        {
            error = $"'{SkipAllowlistFileName}' entry lifetime must be 'temporary' or 'permanent'.";
            return false;
        }

        var fullFilePath = Path.GetFullPath(Path.Combine(repoRoot, filePath));
        entry = new ApprovedSkipEntry(
            diagnosticCode,
            filePath,
            fullFilePath,
            string.IsNullOrWhiteSpace(uid) ? null : uid,
            string.IsNullOrWhiteSpace(symbol) ? null : symbol,
            reason,
            approval,
            lifetime.ToLowerInvariant());
        return true;
    }

    private static string? ReadOptionalJsonString(JsonElement element, string propertyName)
    {
        return element.TryGetProperty(propertyName, out var property) && property.ValueKind == JsonValueKind.String
            ? property.GetString()
            : null;
    }

    private static string ReadRequiredJsonString(JsonElement element, string propertyName)
    {
        return element.TryGetProperty(propertyName, out var property) && property.ValueKind == JsonValueKind.String
            ? property.GetString() ?? string.Empty
            : string.Empty;
    }

    // ----------------------------------------------------------------------
    // git changed-only
    // ----------------------------------------------------------------------

    private static HashSet<string>? GetChangedFiles(string repoRoot, Report report)
    {
        var result = RunProcess("git", "rev-parse --verify HEAD", repoRoot, permission: ProcessPermission.Git);
        if (result.ExitCode != 0)
        {
            return null;
        }

        var diff = RunProcess("git", "diff --name-only --diff-filter=ACMRTUXB HEAD", repoRoot, permission: ProcessPermission.Git);
        if (diff.ExitCode != 0)
        {
            return null;
        }

        var set = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        foreach (var line in diff.StdOut.Split('\n', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries))
        {
            set.Add(Path.GetFullPath(Path.Combine(repoRoot, line)));
        }

        // Include untracked files so --changed-only still validates samples in new
        // documentation files that have not been staged yet.
        var untracked = RunProcess("git", "ls-files --others --exclude-standard", repoRoot, permission: ProcessPermission.Git);
        if (untracked.ExitCode == 0)
        {
            foreach (var line in untracked.StdOut.Split('\n', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries))
            {
                set.Add(Path.GetFullPath(Path.Combine(repoRoot, line)));
            }
        }

        return set;
    }

    // ----------------------------------------------------------------------
    // Project-scoped discovery: git state, packets, scope selection, families,
    // symbol ownership, manifest, and the safe overwrite writer.
    // ----------------------------------------------------------------------

    private static GitState GetGitState(string repoRoot)
    {
        var head = RunProcess("git", "rev-parse --verify HEAD", repoRoot, permission: ProcessPermission.Git);
        var state = new GitState { Available = head.ExitCode == 0 };

        string Abs(string rel) => Path.GetFullPath(Path.Combine(repoRoot, rel.Trim()));

        void AddLines(string args, HashSet<string> target)
        {
            var r = RunProcess("git", args, repoRoot, permission: ProcessPermission.Git);
            if (r.ExitCode != 0)
            {
                return;
            }

            foreach (var line in r.StdOut.Split('\n', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries))
            {
                target.Add(Abs(line));
            }
        }

        if (state.Available)
        {
            AddLines("diff --name-only --diff-filter=A HEAD", state.Added);
            AddLines("diff --name-only --cached --diff-filter=ACM", state.Staged);
            AddLines("diff --name-only --diff-filter=ACM", state.Unstaged);
            AddLines("diff --name-only --cached --diff-filter=D", state.Deleted);
            AddLines("diff --name-only --diff-filter=D", state.Deleted);

            var renames = RunProcess("git", "diff --cached --name-status --diff-filter=R", repoRoot, permission: ProcessPermission.Git);
            if (renames.ExitCode == 0)
            {
                foreach (var line in renames.StdOut.Split('\n', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries))
                {
                    var parts = line.Split('\t', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries);
                    for (var k = 1; k < parts.Length; k++)
                    {
                        state.Renamed.Add(Abs(parts[k]));
                    }
                }
            }
        }

        // Untracked files are visible even when there is no HEAD yet.
        var untracked = RunProcess("git", "ls-files --others --exclude-standard", repoRoot, permission: ProcessPermission.Git);
        if (untracked.ExitCode == 0)
        {
            foreach (var line in untracked.StdOut.Split('\n', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries))
            {
                state.Untracked.Add(Abs(line));
            }
        }

        return state;
    }

    private static void ValidateInterimArtifacts(string repoRoot, string docfxPath, string docfxWorkspace,
        ValidationWorkspace ws, ApiModel api, GitState gitState, Report report)
    {
        var candidates = gitState.Added
            .Concat(gitState.Untracked)
            .Where(candidate => !gitState.Deleted.Contains(candidate))
            .Where(candidate => IsInterimArtifactScopeCandidate(repoRoot, docfxWorkspace, candidate))
            .Distinct(StringComparer.OrdinalIgnoreCase)
            .OrderBy(path => path, StringComparer.OrdinalIgnoreCase)
            .ToList();
        if (candidates.Count == 0)
        {
            return;
        }

        var knownNamespaces = new HashSet<string>(
            api.Namespaces.Select(n => n.Name).Concat(ws.NamespaceProjects.Keys),
            StringComparer.Ordinal);
        var knownTypePageStems = new HashSet<string>(
            api.RequiredExampleTargets
                .Where(t => t.Kind == ApiTargetKind.Type)
                .Select(t => t.Uid)
                .Concat(api.RequiredExampleTargets
                    .Where(t => t.Kind == ApiTargetKind.ExtensionMethod && !string.IsNullOrWhiteSpace(t.DeclaringTypeUid))
                    .Select(t => t.DeclaringTypeUid!)),
            StringComparer.Ordinal);
        var knownTypeSectionUids = new HashSet<string>(knownTypePageStems, StringComparer.Ordinal);
        foreach (var uid in api.RequiredExampleTargets
                     .Where(t => t.Kind == ApiTargetKind.ExtensionMethod)
                     .Select(t => t.Uid))
        {
            knownTypeSectionUids.Add(uid);
        }

        foreach (var candidate in candidates)
        {
            if (IsKnownInterimArtifactDeliverable(repoRoot, docfxPath, docfxWorkspace, ws, knownNamespaces,
                    knownTypePageStems, knownTypeSectionUids, candidate))
            {
                continue;
            }

            report.Errors.Add(new Diagnostic("INTERIM_ARTIFACT_IN_WORKTREE", Rel(repoRoot, candidate), null,
                "Unexpected new file in the repository working tree. dotnet-docfx-digest deliverables are limited to the managed AGENTS.md block, the active docfx.json, and DocFX-authored namespace/type Markdown that maps to real public API. Move everything else to temp/session storage or delete it before claiming completion."));
        }
    }

    private static bool IsInterimArtifactScopeCandidate(string repoRoot, string docfxWorkspace, string candidate)
    {
        if (IsRepoRootTopLevelFile(repoRoot, candidate))
        {
            return true;
        }

        if (PathsEqual(repoRoot, docfxWorkspace))
        {
            return IsPathUnderDirectory(candidate, Path.Combine(docfxWorkspace, "api"));
        }

        return IsPathUnderDirectory(candidate, docfxWorkspace);
    }

    private static bool IsKnownInterimArtifactDeliverable(string repoRoot, string docfxPath, string docfxWorkspace,
        ValidationWorkspace ws, HashSet<string> knownNamespaces, HashSet<string> knownTypePageStems,
        HashSet<string> knownTypeSectionUids, string candidate)
    {
        if (PathsEqual(candidate, Path.Combine(repoRoot, "AGENTS.md")) ||
            PathsEqual(candidate, docfxPath) ||
            PathsEqual(candidate, Path.Combine(docfxWorkspace, SkipAllowlistFileName)))
        {
            return true;
        }

        return IsKnownNamespaceMarkdown(candidate, docfxWorkspace, ws, knownNamespaces) ||
               IsKnownTypeMarkdown(candidate, docfxWorkspace, ws, knownTypePageStems, knownTypeSectionUids);
    }

    private static bool IsKnownNamespaceMarkdown(string candidate, string docfxWorkspace, ValidationWorkspace ws,
        HashSet<string> knownNamespaces)
    {
        if (!candidate.EndsWith(".md", StringComparison.OrdinalIgnoreCase) ||
            !IsPathUnderDirectory(candidate, Path.Combine(docfxWorkspace, "api", "namespaces")))
        {
            return false;
        }

        var stem = Path.GetFileNameWithoutExtension(candidate);
        if (knownNamespaces.Contains(stem))
        {
            return true;
        }

        return GetOverwriteSectionsForCandidate(ws, candidate)
            .Any(section => knownNamespaces.Contains(section.Uid));
    }

    private static bool IsKnownTypeMarkdown(string candidate, string docfxWorkspace, ValidationWorkspace ws,
        HashSet<string> knownTypePageStems, HashSet<string> knownTypeSectionUids)
    {
        if (!candidate.EndsWith(".md", StringComparison.OrdinalIgnoreCase) ||
            !IsPathUnderDirectory(candidate, Path.Combine(docfxWorkspace, "api", "types")))
        {
            return false;
        }

        var stem = Path.GetFileNameWithoutExtension(candidate);
        if (knownTypePageStems.Contains(stem))
        {
            return true;
        }

        return GetOverwriteSectionsForCandidate(ws, candidate)
            .Any(section => knownTypeSectionUids.Contains(section.Uid));
    }

    private static List<OverwriteSection> GetOverwriteSectionsForCandidate(ValidationWorkspace ws, string candidate)
    {
        var sections = ws.OverwriteSections
            .Where(section => PathsEqual(section.File, candidate))
            .ToList();
        if (sections.Count > 0 || !File.Exists(candidate))
        {
            return sections;
        }

        try
        {
            return ExtractOverwriteSections(candidate);
        }
        catch
        {
            return [];
        }
    }

    private static bool IsRepoRootTopLevelFile(string repoRoot, string path)
    {
        var parent = Path.GetDirectoryName(path);
        return parent is not null && PathsEqual(parent, repoRoot);
    }

    private static bool IsPathUnderDirectory(string path, string directory)
    {
        try
        {
            var relative = Path.GetRelativePath(directory, path);
            return relative != "." &&
                   !relative.StartsWith("..", StringComparison.Ordinal) &&
                   !Path.IsPathRooted(relative);
        }
        catch
        {
            return false;
        }
    }

    private static List<ProjectPacket> BuildProjectPackets(ValidationWorkspace ws, ApiModel api, GitState gitState,
        List<MetadataGroupInfo> groups, string repoRoot, string docfxWorkspace,
        HashSet<string>? protectedDirtyPaths = null)
    {
        EnsureNamespaceProjectMap(ws);

        var projectNamespaces = new Dictionary<string, List<string>>(StringComparer.OrdinalIgnoreCase);
        var sharedNamespaces = new HashSet<string>(StringComparer.Ordinal);
        foreach (var (ns, owners) in ws.NamespaceProjects)
        {
            var libOwners = owners.Where(o => !o.IsTest).ToList();
            if (libOwners.Count > 1)
            {
                sharedNamespaces.Add(ns);
            }

            foreach (var owner in libOwners)
            {
                var key = Path.GetFullPath(owner.Path);
                if (!projectNamespaces.TryGetValue(key, out var list))
                {
                    list = new List<string>();
                    projectNamespaces[key] = list;
                }

                if (!list.Contains(ns, StringComparer.Ordinal))
                {
                    list.Add(ns);
                }
            }
        }

        var targetsByNs = api.RequiredExampleTargets
            .GroupBy(t => t.Namespace, StringComparer.Ordinal)
            .ToDictionary(g => g.Key, g => g.ToList(), StringComparer.Ordinal);

        // A resumed authoring session protects only paths that were dirty when its manifest was
        // created. Files authored after that baseline must remain selectable for scoped
        // verification; otherwise the validator would mistake its own dry-run output for
        // pre-existing user work and make completion impossible.
        var dirty = protectedDirtyPaths is null
            ? new HashSet<string>(gitState.AllDirty, StringComparer.OrdinalIgnoreCase)
            : new HashSet<string>(protectedDirtyPaths, StringComparer.OrdinalIgnoreCase);

        var packets = new List<ProjectPacket>();
        foreach (var project in ws.LibraryProjects.OrderBy(p => NormalizeDocfxPath(p.Path), StringComparer.OrdinalIgnoreCase))
        {
            var key = Path.GetFullPath(project.Path);
            var packet = new ProjectPacket { Project = project, NormalizedPath = key };

            foreach (var group in groups)
            {
                if (group.ProjectPaths.Any(p => PathsEqual(p, key)))
                {
                    packet.MetadataGroupIds.Add(group.Id);
                }
            }

            var ownedUids = new HashSet<string>(StringComparer.Ordinal);
            if (projectNamespaces.TryGetValue(key, out var nss))
            {
                foreach (var ns in nss.OrderBy(n => n, StringComparer.Ordinal))
                {
                    packet.Namespaces.Add(ns);
                    ownedUids.Add(ns);
                    if (sharedNamespaces.Contains(ns))
                    {
                        packet.SharedNamespaces.Add(ns);
                    }

                    if (targetsByNs.TryGetValue(ns, out var ts))
                    {
                        foreach (var t in ts)
                        {
                            packet.Targets.Add(t);
                            ownedUids.Add(t.Uid);
                            if (t.DeclaringTypeUid is not null)
                            {
                                ownedUids.Add(t.DeclaringTypeUid);
                            }
                        }
                    }
                }
            }

            foreach (var section in ws.OverwriteSections)
            {
                if (ownedUids.Contains(section.Uid) || packet.Namespaces.Contains(NamespaceFromUid(section.Uid), StringComparer.Ordinal))
                {
                    var rel = Rel(repoRoot, section.File);
                    if (!packet.OverwritePaths.Contains(rel, StringComparer.OrdinalIgnoreCase))
                    {
                        packet.OverwritePaths.Add(rel);
                    }
                }
            }

            packet.OverwritePaths.Sort(StringComparer.OrdinalIgnoreCase);

            var related = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
            foreach (var file in EnumerateProjectSourceFiles(project))
            {
                related.Add(Path.GetFullPath(file));
            }

            foreach (var ns in packet.Namespaces)
            {
                related.Add(Path.GetFullPath(Path.Combine(docfxWorkspace, "api", "namespaces", ns + ".md")));
            }

            foreach (var target in packet.Targets.Where(t => t.Kind == ApiTargetKind.Type))
            {
                related.Add(Path.GetFullPath(Path.Combine(docfxWorkspace, "api", "types", target.Uid + ".md")));
            }

            foreach (var rel in packet.OverwritePaths)
            {
                related.Add(Path.GetFullPath(Path.Combine(repoRoot, rel)));
            }

            foreach (var path in related)
            {
                if (dirty.Contains(path))
                {
                    packet.DirtyRelatedPaths.Add(Rel(repoRoot, path));
                }
            }

            packet.DirtyRelatedPaths.Sort(StringComparer.OrdinalIgnoreCase);
            packets.Add(packet);
        }

        return packets;
    }

    private static bool HintMatches(ProjectPacket packet, string hint)
    {
        var h = hint.Trim();
        if (string.IsNullOrEmpty(h))
        {
            return false;
        }

        if (string.Equals(packet.Project.AssemblyName, h, StringComparison.OrdinalIgnoreCase) ||
            string.Equals(packet.Project.PackageId, h, StringComparison.OrdinalIgnoreCase) ||
            string.Equals(Path.GetFileNameWithoutExtension(packet.NormalizedPath), h, StringComparison.OrdinalIgnoreCase))
        {
            return true;
        }

        var nh = NormalizeDocfxPath(h);
        var np = NormalizeDocfxPath(packet.NormalizedPath);
        return string.Equals(np, nh, StringComparison.OrdinalIgnoreCase) ||
               np.EndsWith("/" + nh, StringComparison.OrdinalIgnoreCase) ||
               np.EndsWith(nh, StringComparison.OrdinalIgnoreCase) && nh.Contains('/');
    }

    private static List<ProjectPacket> SeededShuffle(List<ProjectPacket> source, Random rng)
    {
        var list = new List<ProjectPacket>(source);
        for (var i = list.Count - 1; i > 0; i--)
        {
            var j = rng.Next(i + 1);
            (list[i], list[j]) = (list[j], list[i]);
        }

        return list;
    }

    private static long GenerateSeed() => Random.Shared.NextInt64(1, long.MaxValue);

    private static ResumeProjectScope? LoadResumeProjectManifest(string path, string repoRoot, Report report)
    {
        string full;
        try
        {
            full = Path.GetFullPath(path, repoRoot);
        }
        catch (Exception ex)
        {
            report.Errors.Add(new Diagnostic("PROJECT_MANIFEST_INVALID", path, null,
                $"Unable to resolve the project manifest path: {ex.Message}"));
            return null;
        }

        if (!File.Exists(full))
        {
            report.Errors.Add(new Diagnostic("PROJECT_MANIFEST_INVALID", Rel(repoRoot, full), null,
                "The project manifest does not exist."));
            return null;
        }

        try
        {
            using var doc = JsonDocument.Parse(File.ReadAllText(full), new JsonDocumentOptions
            {
                AllowTrailingCommas = true,
                CommentHandling = JsonCommentHandling.Skip
            });
            var root = doc.RootElement;
            if (!root.TryGetProperty("schemaVersion", out var schema) || schema.GetInt32() is not (1 or 2) ||
                !root.TryGetProperty("packets", out var packets) || packets.ValueKind != JsonValueKind.Array)
            {
                report.Errors.Add(new Diagnostic("PROJECT_MANIFEST_INVALID", Rel(repoRoot, full), null,
                    "The project manifest must use schemaVersion 1 or 2 and contain a packets array."));
                return null;
            }

            var result = new ResumeProjectScope();
            if (root.TryGetProperty("runMode", out var mode) && mode.ValueKind == JsonValueKind.String)
            {
                result.Mode = mode.GetString() is "dry-run" ? "dry-run" : "scoped";
            }

            if (root.TryGetProperty("seed", out var seed) && seed.ValueKind == JsonValueKind.Number && seed.TryGetInt64(out var seedValue))
            {
                result.Seed = seedValue;
            }

            foreach (var packet in packets.EnumerateArray())
            {
                if (!packet.TryGetProperty("selected", out var selected) || selected.ValueKind != JsonValueKind.True ||
                    !packet.TryGetProperty("project", out var project) || project.ValueKind != JsonValueKind.String)
                {
                    continue;
                }

                var projectPath = project.GetString();
                if (!string.IsNullOrWhiteSpace(projectPath))
                {
                    var selectedPath = Path.GetFullPath(projectPath, repoRoot);
                    if (!IsInsideDirectory(selectedPath, repoRoot))
                    {
                        report.Errors.Add(new Diagnostic("PROJECT_MANIFEST_INVALID", Rel(repoRoot, full), null,
                            $"Selected project path '{projectPath}' resolves outside the repository root."));
                        return null;
                    }

                    result.SelectedProjectPaths.Add(selectedPath);
                }
            }

            if (root.TryGetProperty("dirty", out var dirty) && dirty.ValueKind == JsonValueKind.Object)
            {
                foreach (var propertyName in new[] { "staged", "unstaged", "renamed", "deleted", "untracked" })
                {
                    if (!dirty.TryGetProperty(propertyName, out var paths) || paths.ValueKind != JsonValueKind.Array)
                    {
                        continue;
                    }

                    foreach (var item in paths.EnumerateArray())
                    {
                        if (item.ValueKind == JsonValueKind.String && !string.IsNullOrWhiteSpace(item.GetString()))
                        {
                            var dirtyPath = Path.GetFullPath(item.GetString()!, repoRoot);
                            if (!IsInsideDirectory(dirtyPath, repoRoot))
                            {
                                report.Errors.Add(new Diagnostic("PROJECT_MANIFEST_INVALID", Rel(repoRoot, full), null,
                                    $"Dirty baseline path '{item.GetString()}' resolves outside the repository root."));
                                return null;
                            }

                            result.InitialDirtyPaths.Add(dirtyPath);
                        }
                    }
                }
            }

            if (result.SelectedProjectPaths.Count == 0)
            {
                report.Errors.Add(new Diagnostic("PROJECT_MANIFEST_INVALID", Rel(repoRoot, full), null,
                    "The project manifest contains no selected project packets to resume."));
                return null;
            }

            report.ResumedProjectManifestPath = Rel(repoRoot, full);
            return result;
        }
        catch (Exception ex) when (ex is IOException or JsonException or InvalidOperationException or ArgumentException or NotSupportedException)
        {
            report.Errors.Add(new Diagnostic("PROJECT_MANIFEST_INVALID", Rel(repoRoot, full), null,
                $"Unable to read the project manifest: {ex.Message}"));
            return null;
        }
    }

    private static ScopePlan ResolveScope(Options options, List<ProjectPacket> packets, List<MetadataGroupInfo> groups,
        ApiModelSource apiSource, string repoRoot, Report report, ResumeProjectScope? resumeScope)
    {
        var plan = new ScopePlan();
        var authoringIntent = options.DryRun || options.ProjectHints.Count > 0 || options.ProjectManifestPath is not null ||
                              options.ResumeProjectManifestPath is not null;
        var authoritative = apiSource != ApiModelSource.SourceScan;
        plan.ScopeState = authoritative ? "authoritative" : "provisional";

        if (authoringIntent && !authoritative)
        {
            report.Warnings.Add(new Diagnostic("BUILD_BACKED_SCOPE_REQUIRED", null, null,
                "Authoring scope was requested but the API model came from the conservative source scanner. Run --build-api-model (or generate DocFX managed-reference YAML) before authoring; the current packet inventory is provisional and may under-report public types."));
        }

        if (options.ResumeProjectManifestPath is not null && resumeScope is null)
        {
            // Loading a requested baseline failed. Keep the scope empty so an invalid or stale
            // manifest can never silently broaden into a repository-wide authoring run.
            plan.Mode = "scoped";
            plan.ScopeRestricted = true;
        }
        else if (resumeScope is not null)
        {
            plan.Mode = resumeScope.Mode;
            plan.Seed = resumeScope.Seed;
            plan.ScopeRestricted = true;
            foreach (var projectPath in resumeScope.SelectedProjectPaths)
            {
                var packet = packets.FirstOrDefault(p => PathsEqual(p.NormalizedPath, projectPath));
                if (packet is null)
                {
                    report.Errors.Add(new Diagnostic("PROJECT_MANIFEST_PROJECT_MISSING", Rel(repoRoot, projectPath), null,
                        "The resumed project manifest selects a project that is no longer present in the active DocFX metadata graph. Regenerate the manifest before continuing."));
                    continue;
                }

                if (packet.Dirty)
                {
                    report.Errors.Add(new Diagnostic("PROJECT_MANIFEST_DIRTY_CONFLICT", Rel(repoRoot, packet.NormalizedPath), null,
                        $"The resumed project was already dirty when the manifest baseline was created and remains protected: {string.Join(", ", packet.DirtyRelatedPaths)}."));
                    continue;
                }

                packet.Selected = true;
                plan.SelectedProjectPaths.Add(packet.NormalizedPath);
            }
        }
        else if (options.ProjectHints.Count > 0)
        {
            plan.Mode = options.DryRun ? "dry-run" : "scoped";
            plan.ScopeRestricted = true;
            foreach (var hint in options.ProjectHints)
            {
                var matches = packets.Where(p => HintMatches(p, hint)).ToList();
                if (matches.Count == 0)
                {
                    report.Errors.Add(new Diagnostic("PROJECT_HINT_NOT_FOUND", null, null,
                        $"Project hint '{hint}' did not match any documented project. Candidates: {string.Join(", ", packets.Select(p => p.Project.AssemblyName).Distinct(StringComparer.OrdinalIgnoreCase).OrderBy(n => n, StringComparer.OrdinalIgnoreCase))}."));
                    continue;
                }

                if (matches.Count > 1)
                {
                    report.Errors.Add(new Diagnostic("PROJECT_HINT_AMBIGUOUS", null, null,
                        $"Project hint '{hint}' matched {matches.Count} projects: {string.Join(", ", matches.Select(m => Rel(repoRoot, m.NormalizedPath)))}. Use a more specific path, assembly name, or package id."));
                    continue;
                }

                var packet = matches[0];
                if (packet.Dirty)
                {
                    report.Warnings.Add(new Diagnostic("PROJECT_DIRTY_SKIPPED", Rel(repoRoot, packet.NormalizedPath), null,
                        $"Explicitly selected project '{packet.Project.AssemblyName}' has pre-existing changes to related files and was not selected for editing: {string.Join(", ", packet.DirtyRelatedPaths)}. Resolve or deliberately continue in a later run."));
                    continue;
                }

                packet.Selected = true;
                plan.SelectedProjectPaths.Add(packet.NormalizedPath);
            }
        }
        else if (options.DryRun)
        {
            plan.Mode = "dry-run";
            plan.ScopeRestricted = true;
            var seed = options.Seed ?? GenerateSeed();
            plan.Seed = seed;
            var rng = new Random(unchecked((int)(seed ^ (seed >> 32))));
            foreach (var group in groups.OrderBy(g => g.Id, StringComparer.Ordinal))
            {
                var candidates = packets
                    .Where(p => p.MetadataGroupIds.Contains(group.Id, StringComparer.Ordinal))
                    .OrderBy(p => NormalizeDocfxPath(p.NormalizedPath), StringComparer.OrdinalIgnoreCase)
                    .ToList();
                if (candidates.Count == 0)
                {
                    continue;
                }

                var clean = SeededShuffle(candidates, rng).FirstOrDefault(p => !p.Dirty);
                if (clean is null)
                {
                    report.Warnings.Add(new Diagnostic("DRY_RUN_GROUP_UNSELECTED", null, group.Id,
                        $"Metadata destination group '{group.Id}' has no clean project to sample; every candidate has pre-existing related changes. No documentation was selected for this group."));
                    continue;
                }

                clean.Selected = true;
                plan.SelectedProjectPaths.Add(clean.NormalizedPath);
            }
        }
        else
        {
            plan.Mode = "full";
            foreach (var packet in packets)
            {
                packet.Selected = true;
                plan.SelectedProjectPaths.Add(packet.NormalizedPath);
            }
        }

        foreach (var packet in packets.Where(p => p.Selected))
        {
            foreach (var ns in packet.Namespaces)
            {
                plan.SelectedNamespaces.Add(ns);
            }
        }

        return plan;
    }

    // Auto-detected generic-arity families: a type series that shares one base name and differs
    // only by generic arity (Foo`1, Foo`2, ... Foo`N) may replace redundant standalone sibling
    // examples with one anchor example plus deep namespace guidance. The family is detected from
    // the public API surface — no manifest file is written into the target repository.
    private static List<SkippedFamily> DetectGenericArityFamilies(string repoRoot, string docfxWorkspace,
        ApiModel api, ValidationWorkspace ws, Dictionary<string, string> namespacePages, Report report)
    {
        var result = new List<SkippedFamily>();

        // Group non-abstraction type targets by their arity-stripped base key. Only types whose
        // UID carries a trailing `N arity suffix (N >= 1) are candidates; a non-generic type with
        // the same base name keeps its own standalone-example obligation.
        var groups = new Dictionary<string, List<ApiTargetInfo>>(StringComparer.Ordinal);
        foreach (var target in api.RequiredExampleTargets.Where(t => t.Kind == ApiTargetKind.Type))
        {
            var (baseKey, arity) = SplitAritySuffix(target.Uid);
            if (arity < 1)
            {
                continue;
            }
            if (!groups.TryGetValue(baseKey, out var list))
            {
                list = new List<ApiTargetInfo>();
                groups[baseKey] = list;
            }
            list.Add(target);
        }

        foreach (var group in groups.Values)
        {
            if (group.Count < 2)
            {
                continue;
            }

            // Anchor = lowest arity present. Covered siblings = the remaining members.
            var ordered = group.OrderBy(t => SplitAritySuffix(t.Uid).Arity)
                .ThenBy(t => t.Uid, StringComparer.Ordinal).ToList();
            var anchorUid = ordered[0].Uid;
            var coveredUids = ordered.Skip(1).Select(t => t.Uid).ToList();
            var namespaceUid = NamespaceFromUid(anchorUid);
            var familyId = SimpleNameFromUid(anchorUid) + "-arity";

            // The anchor must still carry a real, behavioral example before siblings can be skipped.
            var anchorPath = Rel(repoRoot, Path.Combine(docfxWorkspace, "api", "types", anchorUid + ".md"));
            var anchorHasExample = AnchorHasValidExample(anchorUid, ws, api);
            if (!anchorHasExample)
            {
                report.Errors.Add(new Diagnostic("FAMILY_ANCHOR_EXAMPLE_MISSING", anchorPath, namespaceUid,
                    $"Auto-detected generic-arity family '{familyId}' anchor '{anchorUid}' has no valid, behavioral example. The anchor must demonstrate the shared workflow before siblings can be skipped from standalone examples."));
            }

            // The namespace page must name the anchor and explain how consumers choose among siblings.
            string? guidancePath = namespacePages.TryGetValue(namespaceUid, out var page) ? Rel(repoRoot, page) : null;
            if (!NamespaceExplainsFamily(namespaceUid, anchorUid, namespacePages, ws))
            {
                report.Errors.Add(new Diagnostic("FAMILY_NAMESPACE_GUIDANCE_MISSING", guidancePath, namespaceUid,
                    $"Auto-detected generic-arity family '{familyId}' requires the namespace page '{namespaceUid}' to name the anchor '{SimpleNameFromUid(anchorUid)}' and explain how consumers choose among the arity siblings."));
            }

            var valid = anchorHasExample && NamespaceExplainsFamily(namespaceUid, anchorUid, namespacePages, ws);
            result.Add(new SkippedFamily(familyId, namespaceUid, anchorUid, coveredUids, "generic-arity")
            {
                Valid = valid
            });
        }

        return result;
    }

    // Splits a DocFX type UID into its arity-stripped base key and generic arity.
    // "Cuemon.MutableTuple`1" -> ("Cuemon.MutableTuple", 1). A UID whose trailing backtick is not
    // followed by digits returns arity 0 and the UID unchanged, so non-generic types never group.
    private static (string BaseKey, int Arity) SplitAritySuffix(string uid)
    {
        var tick = uid.LastIndexOf('`');
        if (tick < 0)
        {
            return (uid, 0);
        }

        var suffix = uid[(tick + 1)..];
        if (suffix.Length == 0 || !suffix.All(char.IsDigit))
        {
            return (uid, 0);
        }

        return (uid[..tick], int.Parse(suffix, CultureInfo.InvariantCulture));
    }

    private static bool AnchorHasValidExample(string anchorUid, ValidationWorkspace ws, ApiModel api)
    {
        var target = api.RequiredExampleTargets.FirstOrDefault(t => string.Equals(t.Uid, anchorUid, StringComparison.Ordinal));
        if (target is null)
        {
            return false;
        }

        var candidates = ws.OverwriteSections.Where(s => IsExampleCandidate(s, target)).ToList();
        return candidates.Any(section => ValidateExampleQuality(section, target, new List<string>()).Valid);
    }

    private static bool NamespaceExplainsFamily(string namespaceUid, string anchorUid,
        Dictionary<string, string> namespacePages, ValidationWorkspace ws)
    {
        if (!namespacePages.TryGetValue(namespaceUid, out var page))
        {
            return false;
        }

        var text = ws.ReadMarkdown(page);
        var (_, body) = SplitFrontMatter(text);
        var anchorName = SimpleNameFromUid(anchorUid);
        var namesAnchor = body.Contains(anchorName, StringComparison.Ordinal);
        var explainsSelection = Regex.IsMatch(body,
            @"(?i)\b(?:choose|select|pick|which|differ|arity|overload|type parameter|specialization|when you need|use\s+\w+\s+when)\b");
        return namesAnchor && explainsSelection;
    }

    private static void ApplySkippedFamilies(ApiModel api, List<SkippedFamily> families)
    {
        var covered = new HashSet<string>(
            families.Where(f => f.Valid).SelectMany(f => f.CoveredUids),
            StringComparer.Ordinal);
        if (covered.Count == 0)
        {
            return;
        }

        api.RequiredExampleTargets.RemoveAll(t => t.Kind == ApiTargetKind.Type && covered.Contains(t.Uid));
        foreach (var ns in api.Namespaces)
        {
            ns.RequiredExampleTargets.RemoveAll(t => t.Kind == ApiTargetKind.Type && covered.Contains(t.Uid));
        }
    }

    private static string? ReadJsonString(JsonElement element, string name)
        => element.TryGetProperty(name, out var v) && v.ValueKind == JsonValueKind.String ? v.GetString() : null;

    // Symbol ownership: duplicate simple type names across owning projects, type forwarding that
    // cannot be attributed, and extension containers that cross project boundaries. Collisions are
    // valid API shapes; only missing exact-UID or receiver-call evidence is a blocking diagnostic.
    private static void ValidateSymbolOwnership(ApiModel api, ValidationWorkspace ws, ScopePlan scope, Report report)
    {
        var ownerByNamespace = ws.NamespaceProjects;
        string OwnersOf(string ns) => ownerByNamespace.TryGetValue(ns, out var list)
            ? string.Join(", ", list.Where(o => !o.IsTest).Select(o => o.AssemblyName).Distinct(StringComparer.OrdinalIgnoreCase).OrderBy(n => n, StringComparer.OrdinalIgnoreCase))
            : "(unknown)";

        // Duplicate simple type names whose owning projects differ.
        foreach (var group in api.RequiredExampleTargets
                     .Where(t => t.Kind == ApiTargetKind.Type && scope.IncludesNamespace(t.Namespace))
                     .GroupBy(t => SimpleNameFromUid(t.Uid), StringComparer.Ordinal))
        {
            var distinctUids = group.Select(t => t.Uid).Distinct(StringComparer.Ordinal).ToList();
            if (distinctUids.Count < 2)
            {
                continue;
            }

            var owners = group
                .SelectMany(t => ownerByNamespace.TryGetValue(t.Namespace, out var l) ? l.Where(o => !o.IsTest) : Enumerable.Empty<ProjectInfo>())
                .Select(o => Path.GetFullPath(o.Path))
                .Distinct(StringComparer.OrdinalIgnoreCase)
                .ToList();
            if (owners.Count >= 2)
            {
                var unresolvedUids = distinctUids
                    .Where(uid => !HasExactUidExample(ws.OverwriteSections, uid))
                    .OrderBy(uid => uid, StringComparer.Ordinal)
                    .ToList();
                if (unresolvedUids.Count > 0)
                {
                    report.Errors.Add(new Diagnostic("SYMBOL_COLLISION_UNRESOLVED", null, group.First().Namespace,
                        $"Simple type name '{group.Key}' exists in multiple assemblies/namespaces ({string.Join("; ", distinctUids.Select(u => $"{u} [{OwnersOf(NamespaceFromUid(u))}]"))}), and exact-UID example mappings are still missing for {string.Join(", ", unresolvedUids.Select(uid => $"`{uid}`"))}. Add a C# example mapped to each exact type UID; a namespace-level or simple-name mapping does not establish ownership."));
                }
            }
        }

        // Type forwarding declared in source that cannot be attributed to a documented owner.
        foreach (var project in ws.LibraryProjects)
        {
            foreach (var file in EnumerateProjectSourceFiles(project))
            {
                string text;
                try
                {
                    text = File.ReadAllText(file);
                }
                catch
                {
                    continue;
                }

                foreach (Match m in Regex.Matches(text, @"\[\s*assembly\s*:\s*TypeForwardedTo\s*\(\s*typeof\s*\(\s*(?<type>[\w.<>, ]+?)\s*\)\s*\)\s*\]"))
                {
                    var forwardedType = m.Groups["type"].Value.Trim();
                    var simple = forwardedType.Contains('.') ? forwardedType[(forwardedType.LastIndexOf('.') + 1)..] : forwardedType;
                    simple = simple.Split('<')[0];
                    var documented = api.RequiredExampleTargets.Any(t => string.Equals(SimpleNameFromUid(t.Uid), simple, StringComparison.Ordinal));
                    if (!documented)
                    {
                        report.Warnings.Add(new Diagnostic("TYPE_FORWARDING_UNRESOLVED", Rel(ws.RepoRoot, file), null,
                            $"Type '{forwardedType}' is forwarded from '{project.AssemblyName}' but cannot be matched to a documented type target. Resolve which project and UID documents the forwarded family before authoring."));
                    }
                }
            }
        }

        // Extension containers whose simple name appears in more than one namespace/project.
        foreach (var group in api.RequiredExampleTargets
                     .Where(target => target.Kind == ApiTargetKind.ExtensionMethod &&
                                      target.DeclaringTypeUid is not null &&
                                      scope.IncludesNamespace(target.Namespace))
                     .GroupBy(target => SimpleNameFromUid(target.DeclaringTypeUid!), StringComparer.Ordinal))
        {
            var namespaces = group.Select(target => target.Namespace).Distinct(StringComparer.Ordinal).ToList();
            if (namespaces.Count < 2)
            {
                continue;
            }

            var owners = namespaces
                .SelectMany(ns => ownerByNamespace.TryGetValue(ns, out var l) ? l.Where(o => !o.IsTest) : Enumerable.Empty<ProjectInfo>())
                .Select(o => Path.GetFullPath(o.Path))
                .Distinct(StringComparer.OrdinalIgnoreCase)
                .ToList();
            if (owners.Count >= 2)
            {
                var unresolvedTargets = group
                    .Where(target => !HasExactOwnerReceiverExample(ws.OverwriteSections, target))
                    .OrderBy(target => target.Uid, StringComparer.Ordinal)
                    .ToList();
                if (unresolvedTargets.Count > 0)
                {
                    var exampleMethod = MethodBaseName(unresolvedTargets[0].DisplayName);
                    report.Errors.Add(new Diagnostic("EXTENSION_OWNER_AMBIGUOUS", null, namespaces[0],
                        $"Extension container '{group.Key}' is declared in multiple namespaces/assemblies ({string.Join(", ", namespaces.Select(ns => $"{ns} [{OwnersOf(ns)}]"))}), and receiver-style ownership evidence is still missing for {string.Join(", ", unresolvedTargets.Select(target => $"`{target.Uid}`"))}. Map each example to its exact declaring-type or method UID and invoke it through receiver syntax such as `receiver.{exampleMethod}(...)`; namespace-level mappings and static `{group.Key}.{exampleMethod}(receiver)` calls do not disambiguate the owner."));
                }
            }
        }
    }

    private static bool HasExactUidExample(IReadOnlyList<OverwriteSection> sections, string uid)
        => sections.Any(section =>
            string.Equals(section.Uid, uid, StringComparison.Ordinal) &&
            GetExampleCodeBlocks(section).Count > 0);

    private static bool HasExactOwnerReceiverExample(IReadOnlyList<OverwriteSection> sections, ApiTargetInfo target)
    {
        if (target.DeclaringTypeUid is null)
        {
            return false;
        }

        return sections
            .Where(section =>
                string.Equals(section.Uid, target.DeclaringTypeUid, StringComparison.Ordinal) ||
                string.Equals(section.Uid, target.Uid, StringComparison.Ordinal))
            .SelectMany(GetExampleCodeBlocks)
            .Any(code => HasReceiverMethodInvocation(code, target.DisplayName, target.DeclaringTypeUid));
    }

    private static List<string> GetExampleCodeBlocks(OverwriteSection section)
    {
        var scope = section.MappedToExample ? section.Body : ExtractExampleSection(section.Body);
        return ExtractCSharpCodeBlocks(scope);
    }

    private static bool HasReceiverMethodInvocation(string code, string methodDisplayName, string declaringTypeUid)
    {
        var stripped = StripCodeCommentsAndStrings(code);
        var methodName = MethodBaseName(methodDisplayName);
        var declaringTypeName = SimpleNameFromUid(declaringTypeUid);
        var staticReceivers = new HashSet<string>(StringComparer.Ordinal)
        {
            declaringTypeName
        };

        foreach (Match alias in Regex.Matches(stripped,
                     @"(?m)^\s*using\s+(?<alias>[A-Za-z_]\w*)\s*=\s*(?:global::)?(?<type>[A-Za-z_]\w*(?:\.[A-Za-z_]\w*)*)\s*;"))
        {
            var aliasedType = alias.Groups["type"].Value;
            if (string.Equals(aliasedType, declaringTypeUid, StringComparison.Ordinal) ||
                string.Equals(aliasedType, declaringTypeName, StringComparison.Ordinal))
            {
                staticReceivers.Add(alias.Groups["alias"].Value);
            }
        }

        foreach (Match invocation in Regex.Matches(stripped,
                     $@"(?<receiver>[A-Za-z_]\w*|\)|\])\s*\??\.\s*{Regex.Escape(methodName)}(?:\s*<[^>\r\n]+>)?\s*\("))
        {
            if (!staticReceivers.Contains(invocation.Groups["receiver"].Value))
            {
                return true;
            }
        }

        return false;
    }

    private static ScopeReport BuildScopeReport(ScopePlan scope, List<ProjectPacket> packets,
        List<MetadataGroupInfo> groups, GitState gitState, List<SkippedFamily> families, string repoRoot, Report report)
    {
        string RelPath(string abs) => Rel(repoRoot, abs);

        var diagnosticsByNamespace = report.Errors
            .Where(e => e.Namespace is not null)
            .GroupBy(e => e.Namespace!, StringComparer.Ordinal)
            .ToDictionary(g => g.Key, g => g.ToList(), StringComparer.Ordinal);

        var scopeReport = new ScopeReport
        {
            Mode = scope.Mode,
            Seed = scope.Seed,
            ScopeState = scope.ScopeState,
            SelectedProjects = packets.Where(p => p.Selected).Select(p => RelPath(p.NormalizedPath)).OrderBy(p => p, StringComparer.OrdinalIgnoreCase).ToList()
        };

        foreach (var group in groups)
        {
            var selected = packets.FirstOrDefault(p => p.Selected && p.MetadataGroupIds.Contains(group.Id, StringComparer.Ordinal));
            scopeReport.MetadataGroups.Add(new MetadataGroupReport
            {
                Id = group.Id,
                MetadataIndex = group.MetadataIndex,
                Dest = group.Dest,
                Projects = group.ProjectPaths.Select(RelPath).OrderBy(p => p, StringComparer.OrdinalIgnoreCase).ToList(),
                SelectedProject = selected is null ? null : RelPath(selected.NormalizedPath)
            });
        }

        foreach (var packet in packets)
        {
            var counts = new Dictionary<string, int>(StringComparer.Ordinal);
            foreach (var ns in packet.Namespaces)
            {
                if (diagnosticsByNamespace.TryGetValue(ns, out var diags))
                {
                    foreach (var d in diags)
                    {
                        counts[d.Code] = counts.GetValueOrDefault(d.Code) + 1;
                    }
                }
            }

            scopeReport.Packets.Add(new PacketReport
            {
                Project = RelPath(packet.NormalizedPath),
                AssemblyName = packet.Project.AssemblyName,
                PackageId = packet.Project.PackageId,
                MetadataGroups = packet.MetadataGroupIds.OrderBy(g => g, StringComparer.Ordinal).ToList(),
                Namespaces = packet.Namespaces.OrderBy(n => n, StringComparer.Ordinal).ToList(),
                SharedNamespaces = packet.SharedNamespaces.OrderBy(n => n, StringComparer.Ordinal).ToList(),
                TypeTargets = packet.Targets.Count(t => t.Kind == ApiTargetKind.Type),
                ExtensionTargets = packet.Targets.Count(t => t.Kind == ApiTargetKind.ExtensionMethod),
                OverwritePaths = packet.OverwritePaths,
                ReviewPaths = packet.Namespaces
                    .Select(ns => RelPath(Path.Combine(Path.GetDirectoryName(report.DocfxPath!)!, "api", "namespaces", ns + ".md")))
                    .Concat(packet.Targets.Where(t => t.Kind == ApiTargetKind.Type)
                        .Select(t => RelPath(Path.Combine(Path.GetDirectoryName(report.DocfxPath!)!, "api", "types", t.Uid + ".md"))))
                    .Concat(packet.OverwritePaths)
                    .Distinct(StringComparer.OrdinalIgnoreCase)
                    .OrderBy(path => path, StringComparer.OrdinalIgnoreCase)
                    .ToList(),
                DirtyRelatedPaths = packet.DirtyRelatedPaths,
                Dirty = packet.Dirty,
                Selected = packet.Selected,
                DiagnosticCounts = counts
            });
        }

        foreach (var skipped in packets.Where(p => !p.Selected))
        {
            scopeReport.SkippedProjects.Add(new SkippedProjectReport
            {
                Project = RelPath(skipped.NormalizedPath),
                Reason = skipped.Dirty ? "dirty-related-paths" : (scope.Mode == "full" ? "n/a" : "not-selected"),
                ConflictingPaths = skipped.DirtyRelatedPaths
            });
        }

        foreach (var family in families)
        {
            scopeReport.SkippedFamilies.Add(new SkippedFamilyReport
            {
                FamilyId = family.FamilyId,
                NamespaceUid = family.NamespaceUid,
                AnchorUid = family.AnchorUid,
                CoveredUids = family.CoveredUids,
                Rationale = family.Rationale,
                Valid = family.Valid
            });
        }

        scopeReport.Dirty = new GitStateReport
        {
            Available = gitState.Available,
            Staged = gitState.Staged.Select(RelPath).OrderBy(p => p, StringComparer.OrdinalIgnoreCase).ToList(),
            Unstaged = gitState.Unstaged.Select(RelPath).OrderBy(p => p, StringComparer.OrdinalIgnoreCase).ToList(),
            Renamed = gitState.Renamed.Select(RelPath).OrderBy(p => p, StringComparer.OrdinalIgnoreCase).ToList(),
            Deleted = gitState.Deleted.Select(RelPath).OrderBy(p => p, StringComparer.OrdinalIgnoreCase).ToList(),
            Untracked = gitState.Untracked.Select(RelPath).OrderBy(p => p, StringComparer.OrdinalIgnoreCase).ToList()
        };

        if (scope.Mode == "dry-run")
        {
            var projectArgs = string.Join(" ", scopeReport.SelectedProjects.Select(p => $"--project {p}"));
            scopeReport.ReproduceCommand = scope.Seed is not null
                ? $"docfx.cs --repo-root <root> --dry-run --seed {scope.Seed}"
                : $"docfx.cs --repo-root <root> --dry-run {projectArgs}".TrimEnd();
        }

        return scopeReport;
    }

    private static void WriteProjectManifest(string path, string repoRoot, string docfxPath, ScopeReport scope,
        string apiModelSource, Report report)
    {
        var manifest = new
        {
            schemaVersion = 2,
            repoRoot = ".",
            docfxPath = Rel(repoRoot, docfxPath),
            apiModelSource,
            runMode = scope.Mode,
            seed = scope.Seed,
            scopeState = scope.ScopeState,
            metadataGroups = scope.MetadataGroups,
            packets = scope.Packets,
            dirty = scope.Dirty,
            skippedFamilies = scope.SkippedFamilies
        };

        var json = JsonSerializer.Serialize(manifest, JsonOptions);
        var full = Path.GetFullPath(path, repoRoot);
        var dir = Path.GetDirectoryName(full);
        if (!string.IsNullOrEmpty(dir) && !Directory.Exists(dir))
        {
            Directory.CreateDirectory(dir);
        }

        File.WriteAllText(full, json, new UTF8Encoding(false));
        report.ProjectManifestPath = Rel(repoRoot, full);
        var reviewFull = Path.Combine(Path.GetDirectoryName(full) ?? repoRoot,
            Path.GetFileNameWithoutExtension(full) + ".review.json");
        if (!File.Exists(reviewFull))
        {
            var reviewTemplate = new
            {
                schemaVersion = 1,
                pages = scope.Packets
                    .Where(packet => packet.Selected)
                    .SelectMany(packet => packet.ReviewPaths)
                    .Distinct(StringComparer.OrdinalIgnoreCase)
                    .OrderBy(reviewPath => reviewPath, StringComparer.OrdinalIgnoreCase)
                    .Select(reviewPath => new
                    {
                        path = reviewPath,
                        evidence = string.Empty,
                        purpose = string.Empty,
                        observableOutcome = string.Empty,
                        patternComparison = string.Empty
                    })
            };
            File.WriteAllText(reviewFull, JsonSerializer.Serialize(reviewTemplate, JsonOptions), new UTF8Encoding(false));
        }

        report.ReviewReportPath = Rel(repoRoot, reviewFull);
        scope.ResumeCommand =
            $"docfx.cs --repo-root <root> --resume-project-manifest \"{full}\" --review-report \"{reviewFull}\" --build-api-model --validate-samples --verify-docfx-build --json";
    }

    private static void ValidateChangedPageReview(string? path, string repoRoot, List<ProjectPacket> packets,
        GitState gitState, Report report)
    {
        if (string.IsNullOrWhiteSpace(path))
        {
            report.Errors.Add(new Diagnostic("REVIEW_REPORT_MISSING", null, null,
                "Resumed project authoring requires --review-report <path>. Complete the template emitted beside the project manifest so every changed page is reviewed before scoped completion."));
            return;
        }

        var full = Path.GetFullPath(path, repoRoot);
        if (!File.Exists(full))
        {
            report.Errors.Add(new Diagnostic("REVIEW_REPORT_MISSING", Rel(repoRoot, full), null,
                "The changed-page review report does not exist."));
            return;
        }

        var expected = packets.Where(packet => packet.Selected)
            .SelectMany(packet => packet.Namespaces.Select(ns => Path.Combine(Path.GetDirectoryName(report.DocfxPath!)!, "api", "namespaces", ns + ".md"))
                .Concat(packet.Targets.Where(t => t.Kind == ApiTargetKind.Type)
                    .Select(t => Path.Combine(Path.GetDirectoryName(report.DocfxPath!)!, "api", "types", t.Uid + ".md")))
                .Concat(packet.OverwritePaths.Select(rel => Path.Combine(repoRoot, rel))))
            .Select(Path.GetFullPath)
            .Where(candidate => File.Exists(candidate) && gitState.AllDirty.Contains(candidate))
            .Select(candidate => Rel(repoRoot, candidate))
            .Distinct(StringComparer.OrdinalIgnoreCase)
            .OrderBy(candidate => candidate, StringComparer.OrdinalIgnoreCase)
            .ToList();

        try
        {
            using var doc = JsonDocument.Parse(File.ReadAllText(full), new JsonDocumentOptions
            {
                AllowTrailingCommas = true,
                CommentHandling = JsonCommentHandling.Skip
            });
            if (!doc.RootElement.TryGetProperty("schemaVersion", out var schema) || schema.GetInt32() != 1 ||
                !doc.RootElement.TryGetProperty("pages", out var pages) || pages.ValueKind != JsonValueKind.Array)
            {
                report.Errors.Add(new Diagnostic("REVIEW_REPORT_INVALID", Rel(repoRoot, full), null,
                    "The review report must use schemaVersion 1 and contain a pages array."));
                return;
            }

            var reviewed = new Dictionary<string, JsonElement>(StringComparer.OrdinalIgnoreCase);
            foreach (var page in pages.EnumerateArray())
            {
                var reviewPath = ReadJsonString(page, "path");
                if (!string.IsNullOrWhiteSpace(reviewPath))
                {
                    reviewed[NormalizeDocfxPath(reviewPath)] = page;
                }
            }

            foreach (var expectedPath in expected)
            {
                if (!reviewed.TryGetValue(NormalizeDocfxPath(expectedPath), out var page))
                {
                    report.Errors.Add(new Diagnostic("REVIEW_REPORT_INCOMPLETE", expectedPath, null,
                        "The changed page is missing from the review report."));
                    continue;
                }

                var fields = new[]
                {
                    (Name: "evidence", Minimum: 5),
                    (Name: "purpose", Minimum: 20),
                    (Name: "observableOutcome", Minimum: 10),
                    (Name: "patternComparison", Minimum: 20)
                };
                foreach (var field in fields)
                {
                    var value = ReadJsonString(page, field.Name);
                    if (string.IsNullOrWhiteSpace(value) || value.Trim().Length < field.Minimum ||
                        Regex.IsMatch(value, @"(?i)^(?:todo|tbd|n/?a|none|same as above|looks good)[.!]?$"))
                    {
                        report.Errors.Add(new Diagnostic("REVIEW_REPORT_INCOMPLETE", expectedPath, null,
                            $"Review field '{field.Name}' must contain page-specific evidence or analysis (minimum {field.Minimum} characters)."));
                    }
                }
            }

            report.ReviewReportPath = Rel(repoRoot, full);
        }
        catch (Exception ex) when (ex is IOException or JsonException or InvalidOperationException)
        {
            report.Errors.Add(new Diagnostic("REVIEW_REPORT_INVALID", Rel(repoRoot, full), null,
                $"Unable to read the changed-page review report: {ex.Message}"));
        }
    }

    // Safe structured overwrite writer: accepts an authored UID, mapping kind, prose, and C# fence,
    // validates them, preserves BOM/line-endings, and refuses to clobber dirty paths it does not own.
    private static int WriteOverwriteCommand(Options options)
    {
        var report = new Report { Script = ScriptId };
        string requestPath;
        try
        {
            requestPath = Path.GetFullPath(options.WriteOverwriteRequestPath!);
        }
        catch (Exception ex)
        {
            return EmitOverwrite(options, report, ExitCode.InvalidArguments, $"Invalid request path: {ex.Message}");
        }

        if (!File.Exists(requestPath))
        {
            report.Errors.Add(new Diagnostic("OVERWRITE_REQUEST_MISSING", requestPath, null, "The overwrite request JSON file does not exist."));
            return EmitOverwrite(options, report, ExitCode.InvalidArguments, "Request file missing.");
        }

        JsonDocument doc;
        try
        {
            doc = JsonDocument.Parse(File.ReadAllText(requestPath), new JsonDocumentOptions { AllowTrailingCommas = true, CommentHandling = JsonCommentHandling.Skip });
        }
        catch (Exception ex)
        {
            report.Errors.Add(new Diagnostic("OVERWRITE_REQUEST_INVALID", requestPath, null, $"Unable to parse the overwrite request: {ex.Message}"));
            return EmitOverwrite(options, report, ExitCode.InvalidArguments, "Request invalid.");
        }

        string? file, uid, mapping, prose, fence;
        using (doc)
        {
            file = ReadJsonString(doc.RootElement, "file");
            uid = ReadJsonString(doc.RootElement, "uid");
            mapping = ReadJsonString(doc.RootElement, "mapping") ?? "example";
            prose = ReadJsonString(doc.RootElement, "prose");
            fence = ReadJsonString(doc.RootElement, "fence");
        }

        if (string.IsNullOrWhiteSpace(file) || string.IsNullOrWhiteSpace(uid))
        {
            report.Errors.Add(new Diagnostic("OVERWRITE_REQUEST_INVALID", requestPath, null, "The request must specify 'file' and 'uid'."));
            return EmitOverwrite(options, report, ExitCode.InvalidArguments, "Request invalid.");
        }

        if (mapping is not ("example" or "summary" or "remarks"))
        {
            report.Errors.Add(new Diagnostic("OVERWRITE_REQUEST_INVALID", requestPath, uid, "mapping must be 'example', 'summary', or 'remarks'."));
            return EmitOverwrite(options, report, ExitCode.InvalidArguments, "Request invalid.");
        }

        if (!string.IsNullOrEmpty(fence) && CountOccurrences(fence, "```") % 2 != 0)
        {
            report.Errors.Add(new Diagnostic("OVERWRITE_FENCE_UNBALANCED", uid, uid, "The supplied C# fence content has unbalanced ``` fences."));
            return EmitOverwrite(options, report, ExitCode.ValidationFailed, "Unbalanced fence.");
        }

        var repoRoot = Path.GetFullPath(string.IsNullOrWhiteSpace(options.RepoRoot) ? "." : options.RepoRoot);
        var fullFile = Path.GetFullPath(file!, repoRoot);
        var existedBefore = File.Exists(fullFile);

        // Dirty-path protection: refuse to *replace* a file that already had uncommitted changes.
        // Creating a brand-new overwrite file is always allowed.
        var gitState = GetGitState(repoRoot);
        if (existedBefore && gitState.AllDirty.Any(p => PathsEqual(p, fullFile)))
        {
            report.Errors.Add(new Diagnostic("OVERWRITE_DIRTY_REFUSED", Rel(repoRoot, fullFile), uid,
                "Refusing to overwrite a file that has pre-existing uncommitted changes. Resolve or stage it deliberately first."));
            return EmitOverwrite(options, report, ExitCode.ValidationFailed, "Dirty path refused.");
        }

        // Duplicate UID guard within the same file.
        var existing = existedBefore ? File.ReadAllText(fullFile) : string.Empty;
        if (!string.IsNullOrEmpty(existing) && Regex.Matches(existing, $@"(?m)^\s*uid\s*:\s*{Regex.Escape(uid!)}\s*$").Count > 0)
        {
            report.Errors.Add(new Diagnostic("OVERWRITE_UID_DUPLICATE", Rel(repoRoot, fullFile), uid,
                $"UID '{uid}' already has an overwrite section in this file. Edit it in place instead of appending a duplicate."));
            return EmitOverwrite(options, report, ExitCode.ValidationFailed, "Duplicate UID.");
        }

        var hasBom = existing.Length > 0 && File.ReadAllBytes(fullFile).Length >= 3 &&
                     File.ReadAllBytes(fullFile)[0] == 0xEF;
        var newline = existing.Contains("\r\n", StringComparison.Ordinal) ? "\r\n" : "\n";

        var sb = new StringBuilder();
        if (existing.Length > 0 && !existing.EndsWith("\n", StringComparison.Ordinal))
        {
            sb.Append(newline);
        }

        sb.Append("---").Append(newline);
        sb.Append("uid: ").Append(uid).Append(newline);
        sb.Append(mapping).Append(": *content").Append(newline);
        sb.Append("---").Append(newline);
        if (!string.IsNullOrWhiteSpace(prose))
        {
            sb.Append(prose!.Replace("\r\n", "\n", StringComparison.Ordinal).Replace("\n", newline, StringComparison.Ordinal)).Append(newline).Append(newline);
        }

        if (!string.IsNullOrWhiteSpace(fence))
        {
            sb.Append(fence!.Replace("\r\n", "\n", StringComparison.Ordinal).Replace("\n", newline, StringComparison.Ordinal));
            if (!fence.EndsWith("\n", StringComparison.Ordinal))
            {
                sb.Append(newline);
            }
        }

        var addition = sb.ToString();
        var finalText = existing + addition;

        var dir = Path.GetDirectoryName(fullFile);
        if (!string.IsNullOrEmpty(dir) && !Directory.Exists(dir))
        {
            Directory.CreateDirectory(dir);
        }

        var encoding = new UTF8Encoding(hasBom);
        File.WriteAllText(fullFile, finalText, encoding);

        report.Status = "passed";
        report.Summary.CompletionState = "overwrite-written";
        report.Summary.CanClaimCompletion = false;
        if (options.Json)
        {
            var preview = new
            {
                script = ScriptId,
                status = "passed",
                file = Rel(repoRoot, fullFile),
                uid,
                mapping,
                bomPreserved = hasBom,
                lineEnding = newline == "\r\n" ? "crlf" : "lf",
                bytesWritten = encoding.GetByteCount(finalText),
                preview = addition
            };
            Console.WriteLine(JsonSerializer.Serialize(preview, JsonOptions));
        }
        else
        {
            Console.WriteLine($"{ScriptId}: wrote {mapping} overwrite for {uid} into {Rel(repoRoot, fullFile)} (bom={hasBom}, eol={(newline == "\r\n" ? "crlf" : "lf")}).");
        }

        return (int)ExitCode.Success;
    }

    private static int EmitOverwrite(Options options, Report report, ExitCode code, string message)
    {
        report.Status = code == ExitCode.Success ? "passed" : "failed";
        if (options.Json)
        {
            Console.WriteLine(JsonSerializer.Serialize(report, JsonOptions));
        }
        else
        {
            Console.Error.WriteLine($"{ScriptId}: {message}");
            foreach (var error in report.Errors)
            {
                Console.Error.WriteLine($"  ERROR  [{error.Code}] {error.Message}");
            }
        }

        return (int)code;
    }

    private static int CountOccurrences(string text, string token)
    {
        var count = 0;
        var index = 0;
        while ((index = text.IndexOf(token, index, StringComparison.Ordinal)) >= 0)
        {
            count++;
            index += token.Length;
        }

        return count;
    }

    private static void SearchGitHubForExamples(List<string> packageIds, Report report)
    {
        if (packageIds.Count == 0)
        {
            return;
        }

        report.ExampleSearchSnippets.Add("## GitHub Search Results");
        report.ExampleSearchSnippets.Add(string.Empty);
        report.ExampleSearchSnippets.Add("Results from `gh search code` for documented packages. Prefer usage from repositories other than the target repository.");
        report.ExampleSearchSnippets.Add(string.Empty);

        foreach (var packageId in packageIds)
        {
            report.ExampleSearchSnippets.Add($"### Package: `{packageId}`");
            report.ExampleSearchSnippets.Add(string.Empty);

            var result = RunProcess(
                "gh",
                $"search code \"{packageId}\" --language C# --limit 5 --json path,repository",
                Directory.GetCurrentDirectory(),
                permission: ProcessPermission.GitHubSearch);

            if (result.ExitCode != 0 || string.IsNullOrWhiteSpace(result.StdOut))
            {
                report.ExampleSearchSnippets.Add($"Search unavailable (gh exit {result.ExitCode}). Use the URL below.");
                report.ExampleSearchSnippets.Add(string.Empty);
                continue;
            }

            try
            {
                using var doc = JsonDocument.Parse(result.StdOut);
                if (doc.RootElement.ValueKind != JsonValueKind.Array || doc.RootElement.GetArrayLength() == 0)
                {
                    report.ExampleSearchSnippets.Add("No results found.");
                    report.ExampleSearchSnippets.Add(string.Empty);
                    continue;
                }

                foreach (var hit in doc.RootElement.EnumerateArray())
                {
                    var path = hit.TryGetProperty("path", out var pathEl) ? pathEl.GetString() ?? string.Empty : string.Empty;
                    var repoName = string.Empty;
                    if (hit.TryGetProperty("repository", out var repoEl) && repoEl.ValueKind == JsonValueKind.Object)
                    {
                        repoName = repoEl.TryGetProperty("fullName", out var fn) ? fn.GetString() ?? string.Empty : string.Empty;
                        if (string.IsNullOrEmpty(repoName))
                        {
                            repoName = repoEl.TryGetProperty("nameWithOwner", out var nwo) ? nwo.GetString() ?? string.Empty : string.Empty;
                        }
                    }

                    if (!string.IsNullOrEmpty(repoName) || !string.IsNullOrEmpty(path))
                    {
                        report.ExampleSearchSnippets.Add($"- `{repoName}`: `{path}`");
                    }
                }

                report.ExampleSearchSnippets.Add(string.Empty);
            }
            catch
            {
                report.ExampleSearchSnippets.Add("Unable to parse search results.");
                report.ExampleSearchSnippets.Add(string.Empty);
            }
        }
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

    private static ExecutionSettings ResolveExecutionSettings(Options options)
    {
        var logicalProcessors = Math.Max(1, Environment.ProcessorCount);
        var availableMemoryBytes = Math.Max(0, GC.GetGCMemoryInfo().TotalAvailableMemoryBytes);
        var detectedHighCapacity = logicalProcessors > 8 && availableMemoryBytes > HighCapacityMemoryThresholdBytes;

        var requestedProfile = options.ExecutionProfile ??
                               Environment.GetEnvironmentVariable("DOCFX_DIGEST_EXECUTION_PROFILE") ??
                               "auto";
        var highCapacity = requestedProfile.ToLowerInvariant() switch
        {
            "high-capacity" => true,
            "conservative" => false,
            _ => detectedHighCapacity
        };

        var adaptiveParallelism = highCapacity
            ? Math.Clamp(logicalProcessors / 2, 4, 16)
            : Math.Min(DefaultSampleValidationParallelism, logicalProcessors);
        var buildParallelism = ResolveParallelism(options.BuildParallelism,
            "DOCFX_DIGEST_BUILD_PARALLELISM", adaptiveParallelism, logicalProcessors, 16);
        var sampleParallelism = ResolveParallelism(options.SampleParallelism,
            "DOCFX_DIGEST_SAMPLE_PARALLELISM", adaptiveParallelism, logicalProcessors, 16);
        var timeoutMinutes = ResolvePositiveInteger(options.ProcessTimeoutMinutes,
            "DOCFX_DIGEST_PROCESS_TIMEOUT_MINUTES", DefaultProcessTimeoutMinutes, 1, 180);

        return new ExecutionSettings(
            highCapacity ? "high-capacity" : "conservative",
            logicalProcessors,
            availableMemoryBytes,
            buildParallelism,
            sampleParallelism,
            timeoutMinutes,
            highCapacity && options.VerifyDocfxBuild);
    }

    private static int ResolveParallelism(
        int? optionValue, string environmentVariable, int fallback, int processorCount, int maximum)
    {
        var requested = optionValue ?? ParsePositiveInteger(Environment.GetEnvironmentVariable(environmentVariable));
        return Math.Clamp(requested ?? fallback, 1, Math.Min(processorCount, maximum));
    }

    private static int ResolvePositiveInteger(
        int? optionValue, string environmentVariable, int fallback, int minimum, int maximum)
    {
        var requested = optionValue ?? ParsePositiveInteger(Environment.GetEnvironmentVariable(environmentVariable));
        return Math.Clamp(requested ?? fallback, minimum, maximum);
    }

    private static int? ParsePositiveInteger(string? value)
    {
        return int.TryParse(value, System.Globalization.NumberStyles.Integer,
                   System.Globalization.CultureInfo.InvariantCulture, out var parsed) && parsed > 0
            ? parsed
            : null;
    }

    private static void ConfigureProcessGuard(Options options)
    {
        var allowed = new HashSet<ProcessPermission> { ProcessPermission.Git };
        if (options.BuildApiModel)
        {
            allowed.Add(ProcessPermission.BuildApiModel);
        }

        if (options.ValidateSamples)
        {
            allowed.Add(ProcessPermission.SampleCompile);
        }

        if (options.VerifyDocfxBuild)
        {
            allowed.Add(ProcessPermission.DocfxBuild);
        }

        if (options.SearchExamples)
        {
            allowed.Add(ProcessPermission.GitHubSearch);
        }

        lock (ProcessGuardLock)
        {
            _allowedPermissions = allowed;
            foreach (var key in ProcessCounts.Keys.ToList())
            {
                ProcessCounts[key] = 0;
            }
        }
    }

    private static Dictionary<string, int> SnapshotProcessCounts()
    {
        lock (ProcessGuardLock)
        {
            return new Dictionary<string, int>(ProcessCounts, StringComparer.OrdinalIgnoreCase);
        }
    }

    private static string NormalizeProcessKey(string fileName)
    {
        var name = Path.GetFileNameWithoutExtension(fileName);
        return string.IsNullOrWhiteSpace(name) ? fileName : name.ToLowerInvariant();
    }

    private static string DescribePermissionOption(ProcessPermission permission) => permission switch
    {
        ProcessPermission.BuildApiModel => "--build-api-model",
        ProcessPermission.SampleCompile => "--validate-samples",
        ProcessPermission.DocfxBuild => "--verify-docfx-build",
        ProcessPermission.GitHubSearch => "--search-examples",
        _ => "an explicit build option"
    };

    private static ProcessResult RunProcess(string fileName, string arguments, string workingDirectory,
        IReadOnlyDictionary<string, string>? environment = null,
        ProcessPermission permission = ProcessPermission.NoBuild,
        CancellationToken cancellationToken = default,
        ProcessProgress? progress = null)
    {
        // Process guard: count every external process and refuse to launch build/doc/network
        // tooling unless the active options explicitly authorize the corresponding permission.
        // This keeps the default fast path honest — it can never silently shell out to a build.
        lock (ProcessGuardLock)
        {
            var key = NormalizeProcessKey(fileName);
            ProcessCounts[key] = ProcessCounts.TryGetValue(key, out var current) ? current + 1 : 1;

            if (!_allowedPermissions.Contains(permission))
            {
                throw new InvalidOperationException(
                    $"Process '{fileName}' was blocked by the no-build guard (permission '{permission}'). " +
                    $"The fast Markdown/API-overwrite validation path must not run dotnet, msbuild, docfx, or gh. " +
                    $"Enable the matching option ({DescribePermissionOption(permission)}) to allow it.");
            }
        }

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

            var stopwatch = Stopwatch.StartNew();
            var progressState = new ProcessProgressState();
            var stdout = new StringBuilder();
            var stderr = new StringBuilder();
            var stdoutTask = PumpProcessOutputAsync(process.StandardOutput, stdout, progressState);
            var stderrTask = PumpProcessOutputAsync(process.StandardError, stderr, progressState);
            using var heartbeatCancellation = new CancellationTokenSource();
            var heartbeatTask = progress is null
                ? Task.CompletedTask
                : ReportProcessProgressAsync(process, progress, stopwatch, progressState, heartbeatCancellation.Token);

            if (progress is not null)
            {
                WriteProcessProgress("pending", progress, process.Id, stopwatch.Elapsed, TimeSpan.Zero, null);
            }

            using var timeout = new CancellationTokenSource(_processTimeout);
            using var linked = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken, timeout.Token);
            try
            {
                process.WaitForExitAsync(linked.Token).GetAwaiter().GetResult();
            }
            catch (OperationCanceledException)
            {
                TryKillProcess(process);
                process.WaitForExit(ProcessStreamDrainTimeout);
                Task.WaitAll([stdoutTask, stderrTask], ProcessStreamDrainTimeout);
                var reason = cancellationToken.IsCancellationRequested
                    ? "was cancelled"
                    : $"timed out after {_processTimeout.TotalMinutes:0.##} minutes";

                if (progress is not null)
                {
                    WriteProcessProgress("failed", progress, process.Id, stopwatch.Elapsed,
                        progressState.TimeSinceLastOutput, reason);
                }

                var stdoutText = stdoutTask.IsCompletedSuccessfully ? stdout.ToString() : string.Empty;
                var stderrText = stderrTask.IsCompletedSuccessfully ? stderr.ToString() : string.Empty;
                return new ProcessResult(cancellationToken.IsCancellationRequested ? -2 : -1,
                    stdoutText, stderrText + $"\nProcess '{fileName}' {reason}.");
            }
            finally
            {
                heartbeatCancellation.Cancel();
                try
                {
                    heartbeatTask.GetAwaiter().GetResult();
                }
                catch (OperationCanceledException)
                {
                    // Expected when the process completes between heartbeat intervals.
                }
            }

            Task.WaitAll([stdoutTask, stderrTask]);
            if (progress is not null)
            {
                WriteProcessProgress(process.ExitCode == 0 ? "completed" : "failed", progress, process.Id,
                    stopwatch.Elapsed, progressState.TimeSinceLastOutput,
                    process.ExitCode == 0 ? null : $"exit {process.ExitCode}");
            }

            return new ProcessResult(process.ExitCode, stdout.ToString(), stderr.ToString());
        }
        catch (Exception ex)
        {
            return new ProcessResult(-1, string.Empty, $"Failed to run '{fileName} {arguments}': {ex.Message}");
        }
    }

    private static async Task PumpProcessOutputAsync(
        StreamReader reader, StringBuilder output, ProcessProgressState progressState)
    {
        while (await reader.ReadLineAsync() is { } line)
        {
            output.AppendLine(line);
            progressState.Record(line);
        }
    }

    private static async Task ReportProcessProgressAsync(
        Process process,
        ProcessProgress progress,
        Stopwatch stopwatch,
        ProcessProgressState progressState,
        CancellationToken cancellationToken)
    {
        while (true)
        {
            await Task.Delay(ProcessHeartbeatInterval, cancellationToken);
            var snapshot = progressState.Snapshot();
            WriteProcessProgress("working", progress, process.Id, stopwatch.Elapsed,
                snapshot.TimeSinceLastOutput, snapshot.LastOutputLine);
        }
    }

    private static void WriteProcessProgress(
        string state,
        ProcessProgress progress,
        int processId,
        TimeSpan elapsed,
        TimeSpan timeSinceLastOutput,
        string? status)
    {
        var marker = state switch
        {
            "completed" => ColorizeProgressMarker("[\u2713]", "32"),
            "failed" => ColorizeProgressMarker("[x]", "31"),
            "working" => ColorizeProgressMarker("[ ]", "33"),
            _ => "[ ]"
        };
        if (_quietProgress && state is "pending" or "working")
        {
            return;
        }

        var idle = state == "pending"
            ? string.Empty
            : $" | last output {FormatElapsed(timeSinceLastOutput)} ago";
        var current = string.IsNullOrWhiteSpace(status)
            ? string.Empty
            : $" | current: {SanitizeProgressText(status)}";

        Console.Error.WriteLine(
            $"  {marker} {progress.Phase} | {progress.Detail} | pid {processId} | elapsed {FormatElapsed(elapsed)}{idle}{current}");
    }

    private static string ColorizeProgressMarker(string marker, string ansiColor)
    {
        return Console.IsErrorRedirected ? marker : $"\u001b[{ansiColor}m{marker}\u001b[0m";
    }

    private static string FormatElapsed(TimeSpan elapsed)
    {
        return elapsed.TotalHours >= 1
            ? elapsed.ToString(@"hh\:mm\:ss", System.Globalization.CultureInfo.InvariantCulture)
            : elapsed.ToString(@"mm\:ss", System.Globalization.CultureInfo.InvariantCulture);
    }

    private static string SanitizeProgressText(string text)
    {
        var withoutAnsi = Regex.Replace(text, @"\x1B\[[0-?]*[ -/]*[@-~]", string.Empty);
        var sanitized = Regex.Replace(withoutAnsi.Trim(), @"\s+", " ");
        const int maxLength = 180;
        return sanitized.Length <= maxLength ? sanitized : sanitized[..maxLength] + "...";
    }

    private static void TryKillProcess(Process process)
    {
        try
        {
            process.Kill(entireProcessTree: true);
        }
        catch
        {
            // best effort
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

        report.Summary.Errors = report.Errors.Count;
        report.Summary.Warnings = report.Warnings.Count;
        report.Summary.FullVerificationRan = options.BuildApiModel && options.ValidateSamples && options.VerifyDocfxBuild;
        report.Summary.RemainingGates = new List<string>();
        if (!options.BuildApiModel)
        {
            report.Summary.RemainingGates.Add("--build-api-model");
        }

        if (!options.ValidateSamples)
        {
            report.Summary.RemainingGates.Add("--validate-samples");
        }

        if (!options.VerifyDocfxBuild)
        {
            report.Summary.RemainingGates.Add("--verify-docfx-build");
        }

        report.Summary.CanClaimCompletion = code == ExitCode.Success &&
                                            report.Errors.Count == 0 &&
                                            report.Summary.RemainingGates.Count == 0;
        report.Summary.CompletionState = report.Summary.CanClaimCompletion
            ? "complete"
            : report.Errors.Count > 0 ? "incomplete" : "verification-required";

        // A dry run or an explicitly scoped run never claims repository-wide completion; it reports
        // only the state of the selected scope so a passing subset is not mistaken for a full digest.
        if (report.Summary.RunMode is "dry-run" or "scoped")
        {
            report.Summary.CanClaimCompletion = false;
            var prefix = report.Summary.RunMode;
            report.Summary.CompletionState = code == ExitCode.Success &&
                                             report.Errors.Count == 0 &&
                                             report.Summary.RemainingGates.Count == 0
                ? $"{prefix}-passed"
                : $"{prefix}-failed";
        }

        report.Summary.RemainingWorkItems = report.Errors.Count + report.Summary.RemainingGates.Count;
        report.Summary.RemainingDiagnosticsByCode = report.Errors
            .GroupBy(error => error.Code, StringComparer.Ordinal)
            .OrderBy(group => group.Key, StringComparer.Ordinal)
            .ToDictionary(group => group.Key, group => group.Count(), StringComparer.Ordinal);
        report.Summary.WarningDiagnosticsByCode = report.Warnings
            .GroupBy(warning => warning.Code, StringComparer.Ordinal)
            .OrderBy(group => group.Key, StringComparer.Ordinal)
            .ToDictionary(group => group.Key, group => group.Count(), StringComparer.Ordinal);
        report.Summary.InterimArtifacts = report.Summary.RemainingDiagnosticsByCode.GetValueOrDefault("INTERIM_ARTIFACT_IN_WORKTREE");

        WriteAssessmentQueueIfRequested(options, report);

        // Capture the process tally on every exit path so the result always proves whether the
        // fast path actually shelled out to dotnet/msbuild/docfx/gh.
        var processCounts = SnapshotProcessCounts();
        report.Summary.Processes = new Dictionary<string, int>
        {
            ["dotnet"] = processCounts.GetValueOrDefault("dotnet"),
            ["msbuild"] = processCounts.GetValueOrDefault("msbuild"),
            ["docfx"] = processCounts.GetValueOrDefault("docfx"),
            ["gh"] = processCounts.GetValueOrDefault("gh"),
            ["git"] = processCounts.GetValueOrDefault("git")
        };

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
                $"  Summary: completion={report.Summary.CompletionState}, canClaimCompletion={report.Summary.CanClaimCompletion.ToString().ToLowerInvariant()}, " +
                $"remainingWorkItems={report.Summary.RemainingWorkItems}, remainingGates={string.Join(',', report.Summary.RemainingGates)}, " +
                $"mode={report.Summary.ValidationMode}, apiModel={report.Summary.ApiModelSource ?? "n/a"}, " +
                $"namespaces={report.Summary.PublicNamespaces}, pages={report.Summary.NamespacePagesValidated}, " +
                $"requiredExampleTargets={report.Summary.RequiredExampleTargets}, requiredExamples={report.Summary.RequiredExamples}, " +
                $"extMethods={report.Summary.ExtensionMethods}, samplesCompiled={report.Summary.SamplesCompiled}, " +
                $"samplesSkipped={report.Summary.SamplesSkipped}, preApprovedSkips={report.Summary.PreExistingApprovedSkipMarkers}, " +
                $"newSkipMarkers={report.Summary.NewlyIntroducedSkipMarkers}, unapprovedSkips={report.Summary.UnapprovedSkipMarkers}, " +
                $"interimArtifacts={report.Summary.InterimArtifacts}, fullVerificationRan={report.Summary.FullVerificationRan.ToString().ToLowerInvariant()}, " +
                $"generatedMetadataRemoved={report.Summary.GeneratedMetadataFilesRemoved}, " +
                $"generatedOutputDirectoriesRemoved={report.Summary.GeneratedOutputDirectoriesRemoved}, " +
                $"docfxBuildsVerified={report.Summary.DocfxBuildsVerified}, errors={report.Summary.Errors}, warnings={report.Summary.Warnings}");

            Console.WriteLine(
                $"  [execution] profile={report.Summary.Execution.Profile} processors={report.Summary.Execution.LogicalProcessors} " +
                $"memoryGiB={report.Summary.Execution.AvailableMemoryBytes / (1024d * 1024 * 1024):F1} " +
                $"buildWorkers={report.Summary.Execution.BuildParallelism} sampleWorkers={report.Summary.Execution.SampleParallelism} " +
                $"timeoutMinutes={report.Summary.Execution.ProcessTimeoutMinutes} " +
                $"concurrentDocfx={report.Summary.Execution.ConcurrentDocfxVerification.ToString().ToLowerInvariant()}");

            Console.WriteLine(
                $"  [processes] dotnet={report.Summary.Processes["dotnet"]} msbuild={report.Summary.Processes["msbuild"]} " +
                $"docfx={report.Summary.Processes["docfx"]} gh={report.Summary.Processes["gh"]}");

            if (!report.Summary.CanClaimCompletion)
            {
                Console.WriteLine(
                    "  [completion] INCOMPLETE: treat every remaining diagnostic as repair work. " +
                    "Diagnostic age or volume is not a blocker and does not justify stopping after a partial digest.");
            }
        }

        return (int)code;
    }

    private static string Describe(Diagnostic d)
    {
        var location = d.Namespace is not null ? $"({d.Namespace}) " : string.Empty;
        var uid = d.Uid is not null ? $"[uid: {d.Uid}] " : string.Empty;
        var symbol = d.Symbol is not null && d.Uid is null ? $"[symbol: {d.Symbol}] " : string.Empty;
        var path = d.Path is not null ? $"{d.Path}: " : string.Empty;
        return $"{path}{location}{uid}{symbol}{d.Message}";
    }

    private static void WriteAssessmentQueueIfRequested(Options options, Report report)
    {
        if (string.IsNullOrWhiteSpace(options.AssessmentQueuePath))
        {
            return;
        }

        try
        {
            var basePath = Directory.Exists(report.RepoRoot) ? report.RepoRoot : Directory.GetCurrentDirectory();
            var planPath = Path.GetFullPath(options.AssessmentQueuePath, basePath);
            var directory = Path.GetDirectoryName(planPath);
            if (!string.IsNullOrWhiteSpace(directory))
            {
                Directory.CreateDirectory(directory);
            }

            File.WriteAllText(planPath, BuildAssessmentQueue(report), new UTF8Encoding(false));
            report.AssessmentQueuePath = planPath;
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException or ArgumentException or NotSupportedException)
        {
            report.Warnings.Add(new Diagnostic("ASSESSMENT_QUEUE_WRITE_FAILED", options.AssessmentQueuePath, null,
                $"Unable to write assessment work queue: {ex.Message}"));
        }
    }

    private static string BuildAssessmentQueue(Report report)
    {
        var sb = new StringBuilder();
        sb.AppendLine("# DocFX Assessment Work Queue");
        sb.AppendLine();
        sb.AppendLine($"Repository: `{report.RepoRoot}`");
        if (!string.IsNullOrWhiteSpace(report.DocfxPath))
        {
            sb.AppendLine($"DocFX config: `{report.DocfxPath}`");
        }

        sb.AppendLine($"Status: `{report.Status ?? "unknown"}`");
        sb.AppendLine();
        sb.AppendLine("## Completion Contract");
        sb.AppendLine();
        sb.AppendLine($"- Completion state: `{report.Summary.CompletionState ?? "unknown"}`");
        sb.AppendLine($"- Can claim completion: `{report.Summary.CanClaimCompletion.ToString().ToLowerInvariant()}`");
        sb.AppendLine($"- Remaining work items: {report.Summary.RemainingWorkItems}");
        sb.AppendLine($"- Remaining final-verification gates: {(report.Summary.RemainingGates.Count == 0 ? "none" : string.Join(", ", report.Summary.RemainingGates.Select(gate => $"`{gate}`")))}");
        sb.AppendLine($"- Full verification ran: `{report.Summary.FullVerificationRan.ToString().ToLowerInvariant()}`");
        sb.AppendLine($"- Pre-existing approved skip markers: {report.Summary.PreExistingApprovedSkipMarkers}");
        sb.AppendLine($"- Newly introduced skip markers: {report.Summary.NewlyIntroducedSkipMarkers}");
        sb.AppendLine($"- Unapproved skip markers: {report.Summary.UnapprovedSkipMarkers}");
        sb.AppendLine($"- Interim artifacts: {report.Summary.InterimArtifacts}");
        if (!string.IsNullOrWhiteSpace(report.SkipAllowlistPath))
        {
            sb.AppendLine($"- Skip allowlist: `{report.SkipAllowlistPath}`");
        }
        sb.AppendLine($"- Execution profile: `{report.Summary.Execution.Profile}` ({report.Summary.Execution.LogicalProcessors} processors, {report.Summary.Execution.AvailableMemoryBytes / (1024d * 1024 * 1024):F1} GiB available, build workers {report.Summary.Execution.BuildParallelism}, sample workers {report.Summary.Execution.SampleParallelism}, timeout {report.Summary.Execution.ProcessTimeoutMinutes} minutes, concurrent DocFX `{report.Summary.Execution.ConcurrentDocfxVerification.ToString().ToLowerInvariant()}`)");
        sb.AppendLine("- Every error below is an active repair item. Its age, pre-existing status, or the number of similar diagnostics does not make it a blocker or move it out of scope for a repo-wide digest.");
        sb.AppendLine("- Do not relabel prose, cleanup, or unresolved ownership errors as quality backlog. `EXAMPLE_LEAD_MISSING`, `EXAMPLE_ADVANCED_LEAD_MISSING`, `FAMILY_ANCHOR_EXAMPLE_MISSING`, `SAMPLE_STRUCTURE_INVALID`, `INTERIM_ARTIFACT_IN_WORKTREE`, `SYMBOL_COLLISION_UNRESOLVED`, and `EXTENSION_OWNER_AMBIGUOUS` are blocking repair items until the completion contract is clean.");
        sb.AppendLine("- Do not stop after repairing only a sample of namespaces, types, extension sections, or examples. Rerun the validator and continue until `canClaimCompletion` is `true`.");
        sb.AppendLine("- No premature handoff: while `canClaimCompletion` is `false`, `remainingWorkItems` is greater than `0`, `remainingGates` is non-empty, fail-level diagnostics remain, full verification has not run, newly introduced skip markers are non-zero, or interim artifacts are non-zero, do not emit a final report, handoff, audit result, or completion-shaped summary.");
        sb.AppendLine("- Invalid stop reasons include large queues, many changed/generated files, an active queue, remaining prose/examples, missing full verification, repetitive next steps, or a run taking longer than expected. Those are repair-loop inputs, not blockers.");
        sb.AppendLine("- While `remainingWorkItems` is greater than `0`, the next action must be another remediation batch, a required validator rerun, a validator/tooling fix, or a true blocker with the exact command, exit code, and failure output.");
        sb.AppendLine("- Skip markers are waivers, not fixes. Only pre-existing approved entries from the deterministic skip allowlist count as real waivers; newly introduced or unapproved skip markers stay in the fail-level queue and do not suppress compilation.");
        sb.AppendLine("- An unrelated build or test failure may be reported separately, but it does not end documentation repair unless it prevents the validator or required evidence inspection from running.");
        sb.AppendLine("- Stop incomplete only when the user pauses the task or an external condition still prevents progress after concrete repair attempts. Report the exact command, exit code, blocker, and remaining diagnostic counts; never describe that state as complete.");
        sb.AppendLine();
        sb.AppendLine("## Summary");
        sb.AppendLine();
        sb.AppendLine($"- Public namespaces: {report.Summary.PublicNamespaces}");
        sb.AppendLine($"- Namespace pages validated: {report.Summary.NamespacePagesValidated}");
        sb.AppendLine($"- Required example targets: {report.Summary.RequiredExampleTargets}");
        sb.AppendLine($"- Required examples found: {report.Summary.RequiredExamples}");
        sb.AppendLine($"- Extension methods: {report.Summary.ExtensionMethods}");
        sb.AppendLine($"- Samples compiled: {report.Summary.SamplesCompiled}");
        sb.AppendLine($"- Samples skipped by pre-existing approved waivers: {report.Summary.SamplesSkipped}");
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
        sb.AppendLine("- Keep captured validator output, manifests, queues, progress notes, and one-off helper scripts in temp/session storage instead of the repository.");
        sb.AppendLine("- Treat `Extension Members` tables as incomplete until required examples exist.");
        sb.AppendLine("- Repair related namespace pages together; do not update only the first page that exposes a shared issue.");
        sb.AppendLine("- After edits, inspect `git diff` for the touched documentation paths before final verification.");
        sb.AppendLine("- If an example does not compile, inspect the API shape, project references, tests, and package evidence and repair it; a compile diagnostic is work, not a reason to skip the rest of the queue.");
        sb.AppendLine("- Rerun build-backed validation with `--build-api-model --validate-samples --verify-docfx-build` before claiming completion.");
        sb.AppendLine();

        AppendDiagnostics(sb, "Repository Guidance", report.Errors.Where(e => e.Code is "AGENTS_BLOCK_MISSING"));
        AppendDiagnostics(sb, "Interim Scratch Cleanup", report.Errors.Where(e => e.Code is "INTERIM_ARTIFACT_IN_WORKTREE"));
        AppendDiagnostics(sb, "Encoding Repairs", report.Errors.Where(e =>
            e.Code.StartsWith("ENCODING_", StringComparison.Ordinal)));
        AppendDiagnostics(sb, "Symbol Ownership Repairs", report.Errors.Where(e =>
            e.Code is "SYMBOL_COLLISION_UNRESOLVED" or "EXTENSION_OWNER_AMBIGUOUS"));
        AppendDiagnostics(sb, "Namespace And Extension Table Repairs", report.Errors.Where(e =>
            e.Code.StartsWith("NAMESPACE_", StringComparison.Ordinal) ||
            e.Code.StartsWith("EXTENSION_", StringComparison.Ordinal) &&
            e.Code is not "EXTENSION_OWNER_AMBIGUOUS" &&
            !IsExampleQualityDiagnostic(e)));
        AppendRequiredExampleDiagnostics(sb, report.Errors.Where(IsExampleQualityDiagnostic), report.PackageIds);
        AppendGitHubExampleSources(sb, report.PackageIds, report.ExampleSearchSnippets);
        AppendDiagnostics(sb, "Sample Compilation Repairs", report.Errors.Where(e =>
            e.Code is "SAMPLE_COMPILE_FAILED" or "SAMPLE_SKIP_REASON_MISSING" or "SAMPLE_SKIP_REASON_INSUFFICIENT" or "SAMPLE_SKIP_NOT_ALLOWLISTED" or "FAIL_NEW_SKIP_MARKER_INTRODUCED" or "SAMPLE_STRUCTURE_INVALID" or "SKIP_ALLOWLIST_INVALID"));
        AppendDiagnostics(sb, "Xref Member Link Repairs", report.Errors.Where(e => e.Code is "XREF_MEMBER_LINK"));
        AppendDiagnostics(sb, "Other Errors", report.Errors.Where(e =>
            e.Code is not "AGENTS_BLOCK_MISSING" &&
            e.Code is not "INTERIM_ARTIFACT_IN_WORKTREE" &&
            !e.Code.StartsWith("ENCODING_", StringComparison.Ordinal) &&
            !e.Code.StartsWith("NAMESPACE_", StringComparison.Ordinal) &&
            !e.Code.StartsWith("EXTENSION_", StringComparison.Ordinal) &&
            e.Code is not "SYMBOL_COLLISION_UNRESOLVED" &&
            !IsExampleQualityDiagnostic(e) &&
            e.Code is not "SAMPLE_COMPILE_FAILED" and not "SAMPLE_SKIP_REASON_MISSING" and not "SAMPLE_SKIP_REASON_INSUFFICIENT" and not "SAMPLE_SKIP_NOT_ALLOWLISTED" and not "FAIL_NEW_SKIP_MARKER_INTRODUCED" and not "SAMPLE_STRUCTURE_INVALID" and not "SKIP_ALLOWLIST_INVALID" and not "XREF_MEMBER_LINK"));
        AppendDiagnostics(sb, "Warnings", report.Warnings);

        sb.AppendLine("## Completion Checklist");
        sb.AppendLine();
        sb.AppendLine("- [ ] `agents.cs` has run successfully when `AGENTS_BLOCK_MISSING` appears.");
        sb.AppendLine("- [ ] `ENCODING_CORRUPTION` files restored from git or rewritten using byte-level operations.");
        sb.AppendLine("- [ ] Every symbol-ownership, namespace, and extension diagnostic above has been resolved; zero remain in the final report.");
        sb.AppendLine("- [ ] GitHub example sources consulted before writing any new example (see 'GitHub Example Sources' section).");
        sb.AppendLine("- [ ] Every missing, duplicate, placeholder, reflection-only, target-use, lead, advanced-lead, family-anchor, and extension-invocation example diagnostic above has been resolved.");
        sb.AppendLine("- [ ] Changed C# examples pass structural validation (namespace + type declaration, or labelled `// Program.cs`).");
        sb.AppendLine("- [ ] Every sample that is not a pre-existing approved allowlist waiver compiles successfully.");
        sb.AppendLine("- [ ] Any remaining skip markers are pre-existing approved allowlist entries in `skip-compile-allowlist.json`; zero newly introduced or unapproved skip markers remain.");
        sb.AppendLine("- [ ] Every `XREF_MEMBER_LINK` diagnostic has been repaired: `xref:` links to method/member UIDs replaced with absolute anchor URLs resolved from `xrefmap.yml`.");
        sb.AppendLine("- [ ] Authored Markdown files still exist after generated-artifact cleanup.");
        sb.AppendLine("- [ ] Final JSON reports `fullVerificationRan: true`, `canClaimCompletion: true`, `remainingWorkItems: 0`, no remaining gates, no remaining fail-level diagnostic counts, `newlyIntroducedSkipMarkers: 0`, and `interimArtifacts: 0`.");
        sb.AppendLine("- [ ] Final validation command and exit code are reported.");

        return sb.ToString();
    }

    private static void AppendGitHubExampleSources(StringBuilder sb, List<string> packageIds, List<string> searchSnippets)
    {
        sb.AppendLine("## GitHub Example Sources");
        sb.AppendLine();
        sb.AppendLine("Search for real consumer usage of the documented packages **before** writing examples. " +
                      "Prefer hits from repositories other than the target repository. " +
                      "Use package-ID searches first, then type-name or method-name searches only as fallback.");
        sb.AppendLine();

        if (packageIds.Count > 0)
        {
            sb.AppendLine("### Search Commands");
            sb.AppendLine();
            sb.AppendLine("Run with the `gh` CLI (requires authentication):");
            sb.AppendLine();
            sb.AppendLine("```bash");
            foreach (var pkg in packageIds)
            {
                sb.AppendLine($"gh search code \"{pkg}\" --language \"C#\" --limit 10 --json path,repository,textMatches");
            }

            sb.AppendLine("```");
            sb.AppendLine();
            sb.AppendLine("### GitHub Search URLs");
            sb.AppendLine();
            foreach (var pkg in packageIds)
            {
                var encoded = Uri.EscapeDataString($"\"{pkg}\"");
                sb.AppendLine($"- [{pkg}](https://github.com/search?q={encoded}+language%3AC%23&type=code)");
            }

            sb.AppendLine();
        }

        if (searchSnippets.Count > 0)
        {
            foreach (var line in searchSnippets)
            {
                sb.AppendLine(line);
            }
        }
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

    private static void AppendRequiredExampleDiagnostics(StringBuilder sb, IEnumerable<Diagnostic> diagnostics, List<string> packageIds)
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
        sb.AppendLine("**Before writing any example:** search GitHub for real consumer usage using the 'GitHub Example Sources' section below. " +
                      "Base examples on actual evidence — do not invent API members, constructor signatures, or methods that are not verified in source or tests.");
        sb.AppendLine();
        sb.AppendLine("| Namespace | Expected overwrite location | Diagnostic | Required action |");
        sb.AppendLine("|---|---|---|---|");

        foreach (var diagnostic in items)
        {
            var ns = EscapeTable(diagnostic.Namespace ?? "(repository)");
            var path = EscapeTable(string.IsNullOrWhiteSpace(diagnostic.Path) ? "(method UID, declaring type UID, or namespace page)" : diagnostic.Path);
            var message = EscapeTable(diagnostic.Message);
            var action = diagnostic.Code switch
            {
                "EXAMPLE_UID_DUPLICATE" => "Merge the duplicate mappings into one coherent example section for the UID, then rerun validation.",
                "EXAMPLE_PLACEHOLDER" or "EXAMPLE_REFLECTION_ONLY" or "EXAMPLE_TARGET_NOT_USED" or
                "EXAMPLE_DEFAULT_PLACEHOLDER" or "EXAMPLE_NO_OBSERVABLE_OUTCOME" or "EXAMPLE_FORWARDING_SCAFFOLD" or
                "EXAMPLE_RUNTIME_TYPE_NAME_OUTCOME" or "EXAMPLE_EMPTY_ENTRY_POINT_STUB" =>
                    "Inspect exact test, package README, sample, XML-comment, or source evidence; replace the scaffold with a consumer task that constructs or invokes the target in C# and exposes a result or next action.",
                "EXAMPLE_EXTENSION_CONTAINER_LANGUAGE_FOCUS" =>
                    "Rewrite the extension-container opening around the caller task and receiver outcome instead of foregrounding C# extension-block syntax.",
                "EXAMPLE_FULLY_QUALIFIED_FRAMEWORK_TYPE" =>
                    "Replace avoidable `System.*` / `Microsoft.*` fully qualified references with matching `using` directives so the sample stays focused on the documented API.",
                "EXAMPLE_LEAD_MISSING" =>
                    "Add a short human-written fly-in before the C# fence that names the consumer task and expected outcome.",
                "EXAMPLE_ADVANCED_LEAD_MISSING" =>
                    "Add a more in-depth lead before the C# fence that explains the setup, prerequisite, or workflow outcome for the larger scenario.",
                "EXAMPLE_TEMPLATE_REPETITION" =>
                    "Rewrite each implicated example around the distinct behavior of its own type; do not reuse one normalized skeleton across unrelated targets.",
                "EXTENSION_EXAMPLE_NOT_INVOKED" =>
                    "Replace prose-only or metadata-only coverage with a C# scenario that invokes the extension method on a valid receiver.",
                _ when diagnostic.Message.Contains("Public non-abstraction type", StringComparison.Ordinal) =>
                    "Search GitHub (see below), verify public API surface, create or update the type-targeting overwrite file under `api/types/`, keep `api/types/**/*.md` under `build.overwrite` only, add a compiling Examples section, then rerun validation.",
                _ => "Search GitHub (see below), verify public API surface, add a compiling Examples section on the declaring extension class page or another readable overwrite file under `api/types/` that explicitly calls the extension method, then rerun validation."
            };
            sb.AppendLine($"| {ns} | `{path}` | `{diagnostic.Code}` | {EscapeTable(action)} {message} |");
        }

        sb.AppendLine();
    }

    private static bool IsExampleQualityDiagnostic(Diagnostic diagnostic)
    {
        return diagnostic.Code is "EXAMPLE_MISSING" or "EXAMPLE_UID_DUPLICATE" or "EXAMPLE_PLACEHOLDER" or
            "EXAMPLE_REFLECTION_ONLY" or "EXAMPLE_TARGET_NOT_USED" or "EXTENSION_EXAMPLE_NOT_INVOKED" or
            "EXAMPLE_DEFAULT_PLACEHOLDER" or "EXAMPLE_NO_OBSERVABLE_OUTCOME" or "EXAMPLE_FORWARDING_SCAFFOLD" or
            "EXAMPLE_RUNTIME_TYPE_NAME_OUTCOME" or "EXAMPLE_EMPTY_ENTRY_POINT_STUB" or
            "EXAMPLE_TEMPLATE_REPETITION" or "EXAMPLE_EXTENSION_CONTAINER_LANGUAGE_FOCUS" or
            "EXAMPLE_FULLY_QUALIFIED_FRAMEWORK_TYPE" or "EXAMPLE_LEAD_MISSING" or
            "EXAMPLE_ADVANCED_LEAD_MISSING";
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
                case "--assessment-queue":
                    if (!Next(args, ref i, out var rp)) { error = "--assessment-queue requires a path."; return false; }
                    options.AssessmentQueuePath = rp;
                    break;
                case "--search-examples":
                    options.SearchExamples = true;
                    break;
                case "--build-api-model":
                case "--strict-api-discovery":
                    options.BuildApiModel = true;
                    break;
                case "--sample-reference-mode":
                    if (!Next(args, ref i, out var srm)) { error = "--sample-reference-mode requires 'project' or 'package'."; return false; }
                    if (!IsValidSampleReferenceMode(srm)) { error = "--sample-reference-mode must be 'project' or 'package'."; return false; }
                    options.SampleReferenceMode = srm.ToLowerInvariant();
                    break;
                case "--sample-parallelism":
                    if (!Next(args, ref i, out var sp)) { error = "--sample-parallelism requires a count."; return false; }
                    if (!int.TryParse(sp, out var spv) || spv < 1) { error = "--sample-parallelism must be a positive integer."; return false; }
                    options.SampleParallelism = spv;
                    break;
                case "--build-parallelism":
                    if (!Next(args, ref i, out var bp)) { error = "--build-parallelism requires a count."; return false; }
                    if (!int.TryParse(bp, out var bpv) || bpv < 1) { error = "--build-parallelism must be a positive integer."; return false; }
                    options.BuildParallelism = bpv;
                    break;
                case "--process-timeout-minutes":
                    if (!Next(args, ref i, out var pt)) { error = "--process-timeout-minutes requires a count."; return false; }
                    if (!int.TryParse(pt, out var ptv) || ptv < 1 || ptv > 180) { error = "--process-timeout-minutes must be between 1 and 180."; return false; }
                    options.ProcessTimeoutMinutes = ptv;
                    break;
                case "--quiet":
                case "--no-heartbeat":
                    options.QuietProgress = true;
                    break;
                case "--execution-profile":
                    if (!Next(args, ref i, out var ep)) { error = "--execution-profile requires auto, conservative, or high-capacity."; return false; }
                    if (!IsValidExecutionProfile(ep)) { error = "--execution-profile must be auto, conservative, or high-capacity."; return false; }
                    options.ExecutionProfile = ep.ToLowerInvariant();
                    break;
                case "--clean-generated-metadata":
                    options.CleanGeneratedMetadata = true;
                    break;
                case "--no-clean-generated-metadata":
                    options.CleanGeneratedMetadata = false;
                    break;
                case "--project":
                    if (!Next(args, ref i, out var ph)) { error = "--project requires a project hint."; return false; }
                    options.ProjectHints.Add(ph);
                    break;
                case "--dry-run":
                    options.DryRun = true;
                    break;
                case "--seed":
                    if (!Next(args, ref i, out var sd)) { error = "--seed requires an integer."; return false; }
                    if (!long.TryParse(sd, out var sdv)) { error = "--seed must be an integer."; return false; }
                    options.Seed = sdv;
                    break;
                case "--project-manifest":
                    if (!Next(args, ref i, out var pm)) { error = "--project-manifest requires a path."; return false; }
                    options.ProjectManifestPath = pm;
                    break;
                case "--resume-project-manifest":
                    if (!Next(args, ref i, out var rpm)) { error = "--resume-project-manifest requires a path."; return false; }
                    options.ResumeProjectManifestPath = rpm;
                    break;
                case "--review-report":
                    if (!Next(args, ref i, out var rrp)) { error = "--review-report requires a path."; return false; }
                    options.ReviewReportPath = rrp;
                    break;
                case "--write-overwrite":
                    if (!Next(args, ref i, out var wo)) { error = "--write-overwrite requires a request JSON path."; return false; }
                    options.WriteOverwriteRequestPath = wo;
                    break;
                case "--json":
                    options.Json = true;
                    break;
                default:
                    if (TrySplit(arg, "--repo-root", out var v1)) { options.RepoRoot = v1; break; }
                    if (TrySplit(arg, "--docfx", out var v2)) { options.DocfxPath = v2; break; }
                    if (TrySplit(arg, "--configuration", out var v3)) { options.Configuration = v3; break; }
                    if (TrySplit(arg, "--framework", out var v4)) { options.Framework = v4; break; }
                    if (TrySplit(arg, "--assessment-queue", out var v5a)) { options.AssessmentQueuePath = v5a; break; }
                    if (TrySplit(arg, "--sample-reference-mode", out var v7))
                    {
                        if (!IsValidSampleReferenceMode(v7)) { error = "--sample-reference-mode must be 'project' or 'package'."; return false; }
                        options.SampleReferenceMode = v7.ToLowerInvariant();
                        break;
                    }
                    if (TrySplit(arg, "--sample-parallelism", out var v6) &&
                        int.TryParse(v6, out var spvInline) && spvInline >= 1)
                    {
                        options.SampleParallelism = spvInline;
                        break;
                    }
                    if (TrySplit(arg, "--build-parallelism", out var v8) &&
                        int.TryParse(v8, out var bpvInline) && bpvInline >= 1)
                    {
                        options.BuildParallelism = bpvInline;
                        break;
                    }
                    if (TrySplit(arg, "--process-timeout-minutes", out var v9) &&
                        int.TryParse(v9, out var ptvInline) && ptvInline is >= 1 and <= 180)
                    {
                        options.ProcessTimeoutMinutes = ptvInline;
                        break;
                    }
                    if (TrySplit(arg, "--execution-profile", out var v10) && IsValidExecutionProfile(v10))
                    {
                        options.ExecutionProfile = v10.ToLowerInvariant();
                        break;
                    }
                    if (TrySplit(arg, "--project", out var v11) && !string.IsNullOrWhiteSpace(v11))
                    {
                        options.ProjectHints.Add(v11);
                        break;
                    }
                    if (TrySplit(arg, "--seed", out var v12) && long.TryParse(v12, out var seedInline))
                    {
                        options.Seed = seedInline;
                        break;
                    }
                    if (TrySplit(arg, "--project-manifest", out var v13) && !string.IsNullOrWhiteSpace(v13))
                    {
                        options.ProjectManifestPath = v13;
                        break;
                    }
                    if (TrySplit(arg, "--resume-project-manifest", out var v18) && !string.IsNullOrWhiteSpace(v18))
                    {
                        options.ResumeProjectManifestPath = v18;
                        break;
                    }
                    if (TrySplit(arg, "--review-report", out var v19) && !string.IsNullOrWhiteSpace(v19))
                    {
                        options.ReviewReportPath = v19;
                        break;
                    }
                    if (TrySplit(arg, "--write-overwrite", out var v14) && !string.IsNullOrWhiteSpace(v14))
                    {
                        options.WriteOverwriteRequestPath = v14;
                        break;
                    }
                    error = $"Unknown argument: {arg}";
                    return false;
            }
        }

        return true;
    }

    private static bool IsValidSampleReferenceMode(string value) =>
        string.Equals(value, "project", StringComparison.OrdinalIgnoreCase) ||
        string.Equals(value, "package", StringComparison.OrdinalIgnoreCase);

    private static bool IsValidExecutionProfile(string value) =>
        string.Equals(value, "auto", StringComparison.OrdinalIgnoreCase) ||
        string.Equals(value, "conservative", StringComparison.OrdinalIgnoreCase) ||
        string.Equals(value, "high-capacity", StringComparison.OrdinalIgnoreCase);

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

            By default this performs FAST, no-build validation of Markdown, prose, and DocFX
            API-overwrite layout. The default path never runs dotnet, msbuild, docfx, or gh; it
            reads existing DocFX YAML metadata when present and otherwise scans source for a
            conservative API model. Compilation and network access are strictly opt-in.

            Usage:
              dotnet run --file docfx.cs -- [options]

            Modes (opt-in, each enables exactly one class of external process):
              (default)                Fast Markdown/overwrite/API-overwrite validation. No build.
              --validate-samples       Compile generated C# documentation samples (dotnet). The only
                                      default-supported path that compiles samples. Each sample has an
                                      isolated project; one batched solution build compiles them all.
              --build-api-model        Reflection-backed API discovery from compiled assemblies. Builds
                                      only the documented project graph (dotnet). Alias: --strict-api-discovery.
              --verify-docfx-build     Run DocFX against a temp copy of the repository (docfx).
              --search-examples        Run GitHub code search per documented package (gh). Use with --assessment-queue.

            Options:
              --repo-root <path>       Repository root. Default: current directory.
              --docfx <path>           Path to docfx.json. Default: .docfx/docfx.json under repo root.
              --configuration <name>   Build configuration (only used by build/sample paths). Default: Release.
              --framework <tfm>        Optional runnable consumer TFM to validate against. Choose the
                                      TFM that selects the asset containing a conditional API; use net48
                                      for NETSTANDARD2_0 assets when modern assets omit the API. Never
                                      use netstandard* as an executable target.
              --validate-samples       Compile C# samples (opt-in). Default: disabled.
              --no-validate-samples    Explicitly disable sample compilation (already the default).
              --sample-reference-mode <project|package>
                                      Sample reference resolution. project (default) references the owning
                                      documented project(s); package references NuGet package ids where available.
              --sample-parallelism <n> Maximum MSBuild nodes for the batched sample build (1-16).
                                      Default: adaptive (2 conservative; up to half the available processors,
                                      capped at 16, on high-capacity machines).
                                      Override with env var DOCFX_DIGEST_SAMPLE_PARALLELISM.
              --build-parallelism <n> Maximum MSBuild nodes for the documented project build (1-16).
                                      Override with env var DOCFX_DIGEST_BUILD_PARALLELISM.
              --execution-profile <auto|conservative|high-capacity>
                                      auto (default) selects high-capacity above 8 available logical processors
                                      and 32 GiB available memory; high-capacity overlaps DocFX verification with
                                      API/sample work and favors resource use over wall-clock time.
                                      Override with env var DOCFX_DIGEST_EXECUTION_PROFILE.
              --process-timeout-minutes <n>
                                      Child-process timeout from 1-180 minutes. Default: 30.
                                      Override with env var DOCFX_DIGEST_PROCESS_TIMEOUT_MINUTES.
              --quiet, --no-heartbeat
                                      Suppress start/heartbeat progress chatter on stderr for long-running
                                      child processes while keeping final [✓]/[x] phase markers.
              --build-api-model        Reflection-backed API discovery (opt-in). Default: no-build discovery.
              --changed-only           Validate only files changed according to git (git is read-only and allowed).
              --verify-docfx-build     Run DocFX against a temp copy of the repository (opt-in).
              --assessment-queue <path>
                                      Write a deterministic Markdown assessment work queue from validation diagnostics.
              --search-examples        Run GitHub code search for each documented package and embed real usage snippets in the
                                      assessment work queue. Requires the gh CLI to be authenticated. Use together with --assessment-queue.
              --clean-generated-metadata
                                      Remove DocFX-generated *.yml and manifest files under metadata.dest (opt-in).
                                      Runs only after the API model is built, so it never deletes YAML the fast path used.
              --no-clean-generated-metadata
                                      Leave DocFX-generated metadata files untouched (already the default).

            Project-scoped authoring:
              --project <hint>         Repeatable. Document only the matching project packet(s). A hint
                                      resolves against project path, file name, assembly name, or package id
                                      and must match exactly one project. Scoped runs never claim repo completion.
              --dry-run                Representative run: select one clean project from each metadata
                                      destination group (or all explicit --project packets). Persist the initial
                                      baseline with --project-manifest, author the selected packets, then resume it.
              --seed <integer>         Seed the dry-run selection so it is reproducible. A seed is generated and
                                      reported when omitted.
              --project-manifest <path>
                                      Write a deterministic BOM-less project packet manifest (groups, packets,
                                      ownership, initial dirty paths, and family exemptions) and continue.
              --resume-project-manifest <path>
                                      Resume the exact selected packets and initial dirty-file baseline from a
                                      prior manifest. Use this after authoring so newly created dry-run files are
                                      validated without treating them as pre-existing user work.
              --review-report <path>  Required with --resume-project-manifest. Complete the generated sibling
                                      *.review.json file with page-specific evidence, purpose/outcome, observable
                                      result, and cross-page pattern comparison before scoped completion.
              --write-overwrite <path> Safe structured overwrite writer. Reads a JSON request with
                                      file/uid/mapping/prose/fence fields, validates it, preserves BOM/line
                                      endings, refuses to replace dirty or duplicate-UID files, and exits.
              --json                   Emit a machine-readable JSON summary (includes processes + phase timings).
              --help                   Print this usage.

            Exit codes:
              0  Validation passed.
              1  Validation failed.
              2  Invalid arguments.
              3  Repository root does not exist.
              4  DocFX configuration file not found.
              5  Build failed (only reachable with --build-api-model).
              6  Public API discovery failed (only reachable with --build-api-model).
              7  Sample compilation failed (only reachable with --validate-samples).
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
        public string? AssessmentQueuePath { get; set; }
        public bool ValidateSamples { get; set; }
        public bool ChangedOnly { get; set; }
        public bool VerifyDocfxBuild { get; set; }
        public bool SearchExamples { get; set; }
        public bool BuildApiModel { get; set; }
        public bool CleanGeneratedMetadata { get; set; }
        public bool Json { get; set; }
        public bool Help { get; set; }
        public int? SampleParallelism { get; set; }
        public int? BuildParallelism { get; set; }
        public int? ProcessTimeoutMinutes { get; set; }
        public bool QuietProgress { get; set; }
        public string? ExecutionProfile { get; set; }
        public string SampleReferenceMode { get; set; } = "project";
        public List<string> ProjectHints { get; } = new();
        public bool DryRun { get; set; }
        public long? Seed { get; set; }
        public string? ProjectManifestPath { get; set; }
        public string? ResumeProjectManifestPath { get; set; }
        public string? ReviewReportPath { get; set; }
        public string? WriteOverwriteRequestPath { get; set; }
    }

    private sealed record ProjectInfo(string Path, string AssemblyName, List<string> TargetFrameworks, bool IsTest, string? PackageId = null);

    private sealed record MetadataGroupInfo(string Id, int MetadataIndex, string Dest)
    {
        public Dictionary<string, string> Properties { get; } = new(StringComparer.OrdinalIgnoreCase);
        public List<string> ProjectPaths { get; } = new();
    }

    private sealed class GitState
    {
        public bool Available { get; init; }
        public HashSet<string> Added { get; } = new(StringComparer.OrdinalIgnoreCase);
        public HashSet<string> Staged { get; } = new(StringComparer.OrdinalIgnoreCase);
        public HashSet<string> Unstaged { get; } = new(StringComparer.OrdinalIgnoreCase);
        public HashSet<string> Renamed { get; } = new(StringComparer.OrdinalIgnoreCase);
        public HashSet<string> Deleted { get; } = new(StringComparer.OrdinalIgnoreCase);
        public HashSet<string> Untracked { get; } = new(StringComparer.OrdinalIgnoreCase);

        public IEnumerable<string> AllDirty =>
            Staged.Concat(Unstaged).Concat(Renamed).Concat(Deleted).Concat(Untracked)
                .Distinct(StringComparer.OrdinalIgnoreCase);
    }

    private sealed class ProjectPacket
    {
        public required ProjectInfo Project { get; init; }
        public required string NormalizedPath { get; init; }
        public List<string> MetadataGroupIds { get; } = new();
        public List<string> Namespaces { get; } = new();
        public List<string> SharedNamespaces { get; } = new();
        public List<ApiTargetInfo> Targets { get; } = new();
        public List<string> OverwritePaths { get; } = new();
        public List<string> DirtyRelatedPaths { get; } = new();
        public bool Selected { get; set; }
        public bool Dirty => DirtyRelatedPaths.Count > 0;
    }

    private sealed record SkippedFamily(
        string FamilyId,
        string NamespaceUid,
        string AnchorUid,
        List<string> CoveredUids,
        string Rationale)
    {
        public bool Valid { get; set; }
    }

    private sealed class ScopePlan
    {
        public string Mode { get; set; } = "full";
        public long? Seed { get; set; }
        public string ScopeState { get; set; } = "authoritative";
        public HashSet<string> SelectedProjectPaths { get; } = new(StringComparer.OrdinalIgnoreCase);
        public HashSet<string> SelectedNamespaces { get; } = new(StringComparer.Ordinal);
        public bool ScopeRestricted { get; set; }
        public bool IncludesNamespace(string ns) => !ScopeRestricted || SelectedNamespaces.Contains(ns);
    }

    private sealed class ResumeProjectScope
    {
        public string Mode { get; set; } = "dry-run";
        public long? Seed { get; set; }
        public HashSet<string> SelectedProjectPaths { get; } = new(StringComparer.OrdinalIgnoreCase);
        public HashSet<string> InitialDirtyPaths { get; } = new(StringComparer.OrdinalIgnoreCase);
    }

    private sealed record ExtensionMethodInfo(string MethodName, string DisplayName, string ExtendedType, string DeclaringClass);

    private sealed record ExtensionTableRow(string TypeDisplay, List<string> Methods);

    private sealed record ApiTargetInfo(string Uid, string Namespace, ApiTargetKind Kind, string DisplayName, string? DeclaringTypeUid = null);

    private enum ApiTargetKind
    {
        Type,
        ExtensionMethod
    }

    private enum ProcessPermission
    {
        NoBuild,
        Git,
        BuildApiModel,
        SampleCompile,
        DocfxBuild,
        GitHubSearch
    }

    private enum ValidationMode
    {
        FastMarkdown,
        BuildBackedApiModel
    }

    private enum ApiModelSource
    {
        DocfxYaml,
        SourceScan,
        BuildBacked
    }

    private sealed class NamespaceInfo(string name)
    {
        public string Name { get; } = name;
        public HashSet<string> TypeUids { get; } = new(StringComparer.Ordinal);
        public List<ApiTargetInfo> RequiredExampleTargets { get; } = new();
        public List<ExtensionMethodInfo> ExtensionMethods { get; } = new();
        public bool HasCSharp14ExtensionBlocks { get; set; }
    }

    private sealed record ApiModel(List<NamespaceInfo> Namespaces, List<ApiTargetInfo> RequiredExampleTargets);

    /// <summary>
    /// Per-run cache of repository and documentation inputs. Built once so callers never
    /// re-parse <c>docfx.json</c>, re-enumerate Markdown, re-read Markdown, re-extract overwrite
    /// sections, or re-scan project files. The namespace-to-project map is filled by whichever
    /// API-model discovery runs and is used to scope sample compilation.
    /// </summary>
    private sealed class ValidationWorkspace
    {
        public required string RepoRoot { get; init; }
        public required string DocfxPath { get; init; }
        public required string DocfxWorkspace { get; init; }
        public required List<ProjectInfo> Projects { get; init; }
        public required List<ProjectInfo> LibraryProjects { get; init; }
        public required List<string> MarkdownFiles { get; init; }
        public required Dictionary<string, string> MarkdownTextByPath { get; init; }
        public required List<OverwriteSection> OverwriteSections { get; init; }
        public required List<ApprovedSkipEntry> SkipAllowlistEntries { get; init; }
        public Dictionary<string, List<ProjectInfo>> NamespaceProjects { get; } =
            new(StringComparer.Ordinal);
        public Dictionary<string, List<BaselineSkipMarker>> BaselineSkipMarkersByFile { get; } =
            new(StringComparer.OrdinalIgnoreCase);

        public string ReadMarkdown(string path)
        {
            var full = Path.GetFullPath(path);
            if (MarkdownTextByPath.TryGetValue(full, out var cached))
            {
                return cached;
            }

            try
            {
                cached = File.ReadAllText(full);
            }
            catch
            {
                cached = string.Empty;
            }

            MarkdownTextByPath[full] = cached;
            return cached;
        }
    }

    private sealed record SampleFence(string File, int FenceIndex, int StartLine, string Code);

    private sealed record OverwriteSection(
        string File,
        string Uid,
        string Body,
        bool MappedToExample = false,
        int BodyStartLine = 0,
        int BodyEndLine = 0);

    private sealed record SkipMarkerInfo(bool Found, string Text, string Reason, int LineOffset);

    private sealed record SampleOwnerInfo(string? Uid, string Symbol)
    {
        public string DisplayName => Uid ?? Symbol;
    }

    private sealed record ApprovedSkipEntry(
        string DiagnosticCode,
        string FilePath,
        string FullFilePath,
        string? Uid,
        string? Symbol,
        string Reason,
        string Approval,
        string Lifetime);

    private sealed record BaselineSkipMarker(int FenceIndex, string MarkerText, string Reason, string? Uid, string Symbol);

    private sealed record ExampleQualityResult(bool Valid, string? Code, string? Message, int Priority)
    {
        public static ExampleQualityResult Success { get; } = new(true, null, null, int.MaxValue);
    }

    private sealed record ProcessResult(int ExitCode, string StdOut, string StdErr);

    private sealed record ProcessProgress(string Phase, string Detail);

    private sealed class ProcessProgressState
    {
        private readonly object _lock = new();
        private long _lastOutputTimestamp = Stopwatch.GetTimestamp();
        private string? _lastOutputLine;

        public TimeSpan TimeSinceLastOutput => Stopwatch.GetElapsedTime(Volatile.Read(ref _lastOutputTimestamp));

        public void Record(string line)
        {
            if (string.IsNullOrWhiteSpace(line))
            {
                return;
            }

            lock (_lock)
            {
                _lastOutputLine = line;
                Volatile.Write(ref _lastOutputTimestamp, Stopwatch.GetTimestamp());
            }
        }

        public (TimeSpan TimeSinceLastOutput, string? LastOutputLine) Snapshot()
        {
            lock (_lock)
            {
                return (Stopwatch.GetElapsedTime(_lastOutputTimestamp), _lastOutputLine);
            }
        }
    }

    private sealed record DocfxVerificationResult(
        bool Success, string? Error, TimeSpan Elapsed, bool Cancelled = false);

    private sealed record ExecutionSettings(
        string Profile,
        int LogicalProcessors,
        long AvailableMemoryBytes,
        int BuildParallelism,
        int SampleParallelism,
        int ProcessTimeoutMinutes,
        bool ConcurrentDocfxVerification);

    private sealed record SampleWorker(
        int OriginalIndex,
        string Directory,
        string ProjectPath,
        string SourcePath,
        string AssemblyName);

    private sealed record SampleReferenceSet(
        string Kind,
        bool IsPackageMode,
        List<string> Items,
        List<ProjectInfo> ProjectReferences,
        List<(string Id, string Version)> PackageReferences);

    private sealed record SampleCompileResult(bool Ok, string Diagnostics, int ExitCode);
}

internal sealed class Diagnostic
{
    public Diagnostic(string code, string? path, string? @namespace, string message, string? uid = null, string? symbol = null)
    {
        Code = code;
        Path = path;
        Namespace = @namespace;
        Message = message;
        Uid = uid;
        Symbol = symbol;
    }

    [JsonPropertyName("code")] public string Code { get; }
    [JsonPropertyName("path")] public string? Path { get; }
    [JsonPropertyName("namespace")] public string? Namespace { get; }
    [JsonPropertyName("message")] public string Message { get; }
    [JsonPropertyName("uid")] public string? Uid { get; }
    [JsonPropertyName("symbol")] public string? Symbol { get; }
}

internal sealed class Summary
{
    public string? CompletionState { get; set; }
    public bool CanClaimCompletion { get; set; }
    public bool FullVerificationRan { get; set; }
    public int RemainingWorkItems { get; set; }
    public Dictionary<string, int> RemainingDiagnosticsByCode { get; set; } = new();
    public Dictionary<string, int> WarningDiagnosticsByCode { get; set; } = new();
    public List<string> RemainingGates { get; set; } = new();
    public ExecutionSummary Execution { get; set; } = new();
    public string? ValidationMode { get; set; }
    public string? ApiModelSource { get; set; }
    public string RunMode { get; set; } = "full";
    public string? ScopeState { get; set; }
    public long? Seed { get; set; }
    public int PublicNamespaces { get; set; }
    public int NamespacePagesValidated { get; set; }
    public int RequiredExampleTargets { get; set; }
    public int RequiredExamples { get; set; }
    public int ExtensionMethods { get; set; }
    public int SamplesCompiled { get; set; }
    public int SamplesSkipped { get; set; }
    public int PreExistingApprovedSkipMarkers { get; set; }
    public int NewlyIntroducedSkipMarkers { get; set; }
    public int UnapprovedSkipMarkers { get; set; }
    public int InterimArtifacts { get; set; }
    public int GeneratedMetadataFilesRemoved { get; set; }
    public int GeneratedOutputDirectoriesRemoved { get; set; }
    public int DocfxBuildsVerified { get; set; }
    public int Errors { get; set; }
    public int Warnings { get; set; }
    public Dictionary<string, int> Processes { get; set; } = new();
    public List<PhaseTiming> Phases { get; set; } = new();
}

internal sealed class ExecutionSummary
{
    public string Profile { get; set; } = "conservative";
    public int LogicalProcessors { get; set; }
    public long AvailableMemoryBytes { get; set; }
    public int BuildParallelism { get; set; }
    public int SampleParallelism { get; set; }
    public int ProcessTimeoutMinutes { get; set; }
    public bool ConcurrentDocfxVerification { get; set; }
}

internal sealed class PhaseTiming
{
    public PhaseTiming(string name, double seconds, string? detail = null)
    {
        Name = name;
        Seconds = seconds;
        Detail = detail;
    }

    [JsonPropertyName("name")] public string Name { get; }
    [JsonPropertyName("seconds")] public double Seconds { get; }
    [JsonPropertyName("detail")] public string? Detail { get; }
}

internal sealed class Report
{
    public string Script { get; set; } = string.Empty;
    public string RepoRoot { get; set; } = string.Empty;
    public string? DocfxPath { get; set; }
    public string? SkipAllowlistPath { get; set; }
    public string? AssessmentQueuePath { get; set; }
    public string? ProjectManifestPath { get; set; }
    public string? ResumedProjectManifestPath { get; set; }
    public string? ReviewReportPath { get; set; }
    public string? Status { get; set; }
    public Summary Summary { get; set; } = new();
    public ScopeReport? Scope { get; set; }
    public List<Diagnostic> Errors { get; set; } = new();
    public List<Diagnostic> Warnings { get; set; } = new();
    public List<SkipMarkerReport> SkipMarkers { get; set; } = new();
    public List<string> PackageIds { get; set; } = new();
    public List<string> ExampleSearchSnippets { get; set; } = new();
}

internal sealed class SkipMarkerReport
{
    public string DiagnosticCode { get; set; } = "SAMPLE_COMPILE_FAILED";
    public string FilePath { get; set; } = string.Empty;
    public string? Uid { get; set; }
    public string? Symbol { get; set; }
    public string MarkerText { get; set; } = string.Empty;
    public string Reason { get; set; } = string.Empty;
    public bool Approved { get; set; }
    public bool ExistedBeforeRun { get; set; }
    public string? Approval { get; set; }
    public string? Lifetime { get; set; }
}

internal sealed class ScopeReport
{
    public string Mode { get; set; } = "full";
    public long? Seed { get; set; }
    public string? ScopeState { get; set; }
    public List<MetadataGroupReport> MetadataGroups { get; set; } = new();
    public List<string> SelectedProjects { get; set; } = new();
    public List<SkippedProjectReport> SkippedProjects { get; set; } = new();
    public List<PacketReport> Packets { get; set; } = new();
    public GitStateReport Dirty { get; set; } = new();
    public List<SkippedFamilyReport> SkippedFamilies { get; set; } = new();
    public string? ReproduceCommand { get; set; }
    public string? ResumeCommand { get; set; }
}

internal sealed class MetadataGroupReport
{
    public string Id { get; set; } = string.Empty;
    public int MetadataIndex { get; set; }
    public string Dest { get; set; } = string.Empty;
    public List<string> Projects { get; set; } = new();
    public string? SelectedProject { get; set; }
}

internal sealed class SkippedProjectReport
{
    public string Project { get; set; } = string.Empty;
    public string Reason { get; set; } = string.Empty;
    public List<string> ConflictingPaths { get; set; } = new();
}

internal sealed class PacketReport
{
    public string Project { get; set; } = string.Empty;
    public string AssemblyName { get; set; } = string.Empty;
    public string? PackageId { get; set; }
    public List<string> MetadataGroups { get; set; } = new();
    public List<string> Namespaces { get; set; } = new();
    public List<string> SharedNamespaces { get; set; } = new();
    public int TypeTargets { get; set; }
    public int ExtensionTargets { get; set; }
    public List<string> OverwritePaths { get; set; } = new();
    public List<string> ReviewPaths { get; set; } = new();
    public List<string> DirtyRelatedPaths { get; set; } = new();
    public bool Dirty { get; set; }
    public bool Selected { get; set; }
    public Dictionary<string, int> DiagnosticCounts { get; set; } = new();
}

internal sealed class GitStateReport
{
    public bool Available { get; set; }
    public List<string> Staged { get; set; } = new();
    public List<string> Unstaged { get; set; } = new();
    public List<string> Renamed { get; set; } = new();
    public List<string> Deleted { get; set; } = new();
    public List<string> Untracked { get; set; } = new();
}

internal sealed class SkippedFamilyReport
{
    public string FamilyId { get; set; } = string.Empty;
    public string NamespaceUid { get; set; } = string.Empty;
    public string AnchorUid { get; set; } = string.Empty;
    public List<string> CoveredUids { get; set; } = new();
    public string Rationale { get; set; } = string.Empty;
    public bool Valid { get; set; }
}
