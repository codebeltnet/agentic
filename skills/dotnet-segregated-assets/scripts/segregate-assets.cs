#:property TargetFramework=net10.0
#:property Nullable=enable
#:property LangVersion=latest
#:property PublishAot=false

// dotnet-segregated-assets deterministic runner.
//
// This file is the *execution / inspection layer* for the dotnet-segregated-assets skill. The AI skill
// is the *orchestration layer*: it understands intent, resolves repository conventions, makes the
// repository-appropriate edits, and resolves the App-vs-CDN semantic choices. Everything that must be
// deterministic — discovering candidate web projects, classifying the static-asset topology, detecting
// risky Static Web Assets scenarios that require explicit generated-asset handling, checking idempotency, validating
// the local Static Content Provider topology, and proving that application-owned wwwroot files are absent
// from the deployed web-application publish artifact — lives here so it is repeatable instead of
// re-improvised on every call.
//
// The runner is deliberately conservative. It NEVER rewrites Program.cs, csproj, launchSettings.json,
// Dockerfiles, or Compose files in the target repository. `inspect`/`plan` are read-only; `verify` only
// writes into an isolated temp directory that it owns. Making a repository edit is the agent's job, using
// the literal templates in references/ adapted to the project's real conventions.

using System.Diagnostics;
using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;
using System.Text.RegularExpressions;

return await SegregateAssetsProgram.RunAsync(args);

internal static class SegregateAssetsProgram
{
    internal const string ToolName = "dotnet-segregated-assets";
    internal const string OriginImage = "codebeltnet/web-cdn-origin:2.0.0";
    internal const string DerivedDockerfileName = "Assets.Dockerfile";
    internal const string ComposeFileName = "compose.assets.yml";
    internal const int OriginContainerPort = 8080;
    internal const string OriginContentRoot = "/cdnroot";
    internal const string OriginUser = "65532";
    internal const string AssetsProfileSuffix = ".Assets";
    internal const string CuemonPackageId = "Cuemon.AspNetCore.Razor.TagHelpers";
    internal const string NuGetServiceIndex = "https://api.nuget.org/v3/index.json";

    internal static readonly JsonSerializerOptions JsonOut = new()
    {
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
        DefaultIgnoreCondition = JsonIgnoreCondition.WhenWritingNull,
        WriteIndented = true
    };

    public static async Task<int> RunAsync(string[] args)
    {
        Options options;
        try
        {
            options = Options.Parse(args);
        }
        catch (ArgumentException ex)
        {
            Console.Error.WriteLine($"{ToolName}: {ex.Message}");
            Options.PrintUsage(Console.Error);
            return (int)ExitCode.InvalidArguments;
        }

        if (options.ShowHelp)
        {
            Options.PrintUsage(Console.Out);
            return (int)ExitCode.Success;
        }

        try
        {
            return options.Command switch
            {
                Command.SelfTest => await SelfTest.RunAsync(options),
                Command.Inspect => Commands.Inspect(options),
                Command.Plan => await Commands.PlanAsync(options),
                Command.Verify => Commands.Verify(options),
                _ => Fail(options, ExitCode.InvalidArguments, "No command specified. Use inspect, plan, verify, or --self-test."),
            };
        }
        catch (Exception ex)
        {
            return Fail(options, ExitCode.UnexpectedError, $"Unhandled error: {ex.Message}");
        }
    }

    internal static int Fail(Options options, ExitCode code, string message)
    {
        if (options.Json)
        {
            Console.WriteLine(JsonSerializer.Serialize(new { tool = ToolName, ok = false, failureKind = code.ToString(), message }, JsonOut));
        }
        else
        {
            Console.Error.WriteLine($"{ToolName}: {message}");
        }
        return (int)code;
    }

    internal static void Emit(Options options, object payload, Func<string> human)
    {
        if (options.Json)
        {
            Console.WriteLine(JsonSerializer.Serialize(payload, JsonOut));
        }
        else
        {
            Console.WriteLine(human());
        }
    }
}

internal enum ExitCode
{
    Success = 0,
    InvalidArguments = 64,
    InspectionError = 65,
    VerificationFailed = 66,
    RiskyStaticAssets = 67,
    PublishError = 68,
    DependencyResolutionFailed = 69,
    SelfTestFailed = 70,
    UnexpectedError = 71,
}

internal enum Command { None, Inspect, Plan, Verify, SelfTest }

internal sealed class Options
{
    public Command Command { get; private set; } = Command.None;
    public bool Json { get; private set; }
    public bool ShowHelp { get; private set; }
    public bool FailOnRisk { get; private set; }
    public bool RunPublish { get; private set; }
    public bool CheckLocal { get; private set; }
    public string RepoRoot { get; private set; } = Directory.GetCurrentDirectory();
    public string? Project { get; private set; }
    public string? PublishDir { get; private set; }
    public bool CdnEquivalent { get; private set; }
    public int AppPort { get; private set; } = 8080;
    public int CdnPort { get; private set; } = 8081;

    public static Options Parse(string[] args)
    {
        var o = new Options();
        if (args.Length == 0) { o.ShowHelp = true; return o; }

        var positional = new List<string>();
        for (var i = 0; i < args.Length; i++)
        {
            var a = args[i];
            switch (a)
            {
                case "-h" or "--help": o.ShowHelp = true; break;
                case "--self-test": o.Command = Command.SelfTest; break;
                case "--json": o.Json = true; break;
                case "--fail-on-risk": o.FailOnRisk = true; break;
                case "--run-publish": o.RunPublish = true; break;
                case "--check-local": o.CheckLocal = true; break;
                case "--cdn-equivalent": o.CdnEquivalent = true; break;
                case "--repo-root": o.RepoRoot = RequireValue(args, ref i, a); break;
                case "-p" or "--project": o.Project = RequireValue(args, ref i, a); break;
                case "--publish-dir": o.PublishDir = RequireValue(args, ref i, a); break;
                case "--app-port": o.AppPort = ParseInt(RequireValue(args, ref i, a), a); break;
                case "--cdn-port": o.CdnPort = ParseInt(RequireValue(args, ref i, a), a); break;
                default:
                    if (a.StartsWith('-')) throw new ArgumentException($"Unknown option '{a}'.");
                    positional.Add(a);
                    break;
            }
        }

        foreach (var token in positional)
        {
            var parsed = token.ToLowerInvariant() switch
            {
                "inspect" => Command.Inspect,
                "plan" => Command.Plan,
                "verify" => Command.Verify,
                _ => Command.None,
            };
            if (parsed == Command.None) throw new ArgumentException($"Unknown command '{token}'.");
            if (o.Command != Command.None && o.Command != Command.SelfTest && o.Command != parsed)
                throw new ArgumentException("Specify exactly one command.");
            o.Command = parsed;
        }

        o.RepoRoot = Path.GetFullPath(o.RepoRoot);
        return o;
    }

    private static string RequireValue(string[] args, ref int i, string name)
    {
        if (i + 1 >= args.Length) throw new ArgumentException($"Option '{name}' requires a value.");
        return args[++i];
    }

    private static int ParseInt(string value, string name) =>
        int.TryParse(value, out var n) ? n : throw new ArgumentException($"Option '{name}' requires an integer, got '{value}'.");

    public static void PrintUsage(TextWriter w)
    {
        w.WriteLine($"""
        {SegregateAssetsProgram.ToolName} — segregate ASP.NET Core static assets to Codebelt Static Content Provider.

        Usage:
          dotnet run --file segregate-assets.cs -- <command> [options]

        Commands:
          inspect    Discover candidate web projects, classify static-asset topology, detect risky
                     Static Web Assets scenarios, and report existing segregation (idempotency).
          plan       Resolve the target project, ports, latest stable version of an existing Cuemon
                     package from NuGet.org, and the ordered decisions without writing files.
          verify     Prove application-owned wwwroot files are absent from the publish artifact and,
                     with --check-local, validate the local Static Content Provider topology.
          --self-test  Run the built-in deterministic tests (no dotnet/docker/network required).

        Options:
          --repo-root <dir>     Repository root to inspect (default: current directory).
          -p, --project <path>  Target web project (.csproj), relative to repo root or absolute.
          --publish-dir <dir>   Existing publish output to inspect for verify.
          --run-publish         Run `dotnet publish -c Release` into an isolated temp dir for verify.
          --check-local         Validate launchSettings.json, the local Compose origin topology, and
                                the artifact-first contract (Dockerfile placement, no source
                                compilation, .dockerignore, LocalPublishDirectory, CI artifact).
          --cdn-equivalent      A shared CDN/asset equivalent exists (affects plan output).
          --app-port <n>        Local App Static Content Provider host port (default: 8080).
          --cdn-port <n>        Local CDN Static Content Provider host port (default: 8081).
          --fail-on-risk        Exit non-zero when risky Static Web Assets scenarios are detected.
          --json                Emit machine-readable JSON.
          -h, --help            Show this help.
        """);
    }
}

// ---------------------------------------------------------------------------
// Models
// ---------------------------------------------------------------------------

internal sealed record WebProjectInfo(
    string Path,
    string RelativePath,
    string? Sdk,
    bool IsWebApp,
    bool HasWwwroot);

internal sealed record RiskSignal(string Code, string Detail);

internal sealed record ExistingSegregation(
    bool PublishExclusion,
    bool SegregatedLaunchProfile,
    bool ComposeService,
    bool DerivedDockerfile,
    bool CuemonAppOptions)
{
    // Cuemon options are an application abstraction signal, not evidence that the
    // segregation topology itself is already present.
    public bool Any => PublishExclusion || SegregatedLaunchProfile || ComposeService || DerivedDockerfile;
    public bool Complete => PublishExclusion && SegregatedLaunchProfile;
}

internal sealed record CuemonDetection(
    bool PackageReference,
    bool ProjectReference,
    bool NamespaceUsing,
    bool AppOptions,
    bool CdnOptions,
    bool ViewImportsRegistration,
    bool AppLinkMarkup,
    bool AppScriptMarkup,
    bool AppImageMarkup,
    bool CdnLinkMarkup,
    bool CdnScriptMarkup,
    bool CdnImageMarkup,
    bool LegacyAttributeSyntax,
    bool MicrosoftAppendVersion,
    bool CuemonCacheBusting)
{
    // Markup is useful evidence, but by itself it does not prove that the Cuemon
    // package is available. Availability requires a package/project/options/registration signal.
    public bool Available => PackageReference || ProjectReference || NamespaceUsing || AppOptions || CdnOptions || ViewImportsRegistration;
    public bool Present => Available || AppLinkMarkup || AppScriptMarkup || AppImageMarkup || CdnLinkMarkup || CdnScriptMarkup || CdnImageMarkup;

    public bool OptionsDetected => AppOptions || CdnOptions;

    public IReadOnlyList<string> Evidence
    {
        get
        {
            var evidence = new List<string>();
            if (PackageReference) evidence.Add("Cuemon.AspNetCore.Razor.TagHelpers package reference");
            if (ProjectReference) evidence.Add("referenced project uses Cuemon.AspNetCore.Razor.TagHelpers");
            if (NamespaceUsing) evidence.Add("Cuemon.AspNetCore.Razor.TagHelpers namespace import");
            if (AppOptions) evidence.Add("AppTagHelperOptions");
            if (CdnOptions) evidence.Add("CdnTagHelperOptions");
            if (ViewImportsRegistration) evidence.Add("_ViewImports.cshtml Cuemon tag-helper registration");
            if (AppLinkMarkup) evidence.Add("app-link markup");
            if (AppScriptMarkup) evidence.Add("app-script markup");
            if (AppImageMarkup) evidence.Add("app-img markup");
            if (CdnLinkMarkup) evidence.Add("cdn-link markup");
            if (CdnScriptMarkup) evidence.Add("cdn-script markup");
            if (CdnImageMarkup) evidence.Add("cdn-img markup");
            if (LegacyAttributeSyntax) evidence.Add("legacy attribute-style Cuemon syntax");
            if (MicrosoftAppendVersion) evidence.Add("asp-append-version");
            if (CuemonCacheBusting) evidence.Add("Cuemon cache-busting interface/registration");
            return evidence;
        }
    }
}

internal sealed record CustomAssetDetection(
    bool OptionsType,
    bool UrlCalls,
    bool OptionsRegistration,
    bool RazorInjection)
{
    public bool Present => OptionsType || UrlCalls || OptionsRegistration || RazorInjection;

    public IReadOnlyList<string> Evidence
    {
        get
        {
            var evidence = new List<string>();
            if (OptionsType) evidence.Add("AppAssetOptions-style type");
            if (UrlCalls) evidence.Add("custom asset GetUrl/GetAssetUrl call");
            if (OptionsRegistration) evidence.Add("custom asset options registration");
            if (RazorInjection) evidence.Add("Razor injection of a custom asset abstraction");
            return evidence;
        }
    }
}

internal sealed record AssetAbstractionInspection(
    CuemonDetection Cuemon,
    CustomAssetDetection Custom)
{
    public bool CuemonPresent => Cuemon.Available;
    public bool CompetingAbstractions => Cuemon.Available && Custom.Present;

    public static AssetAbstractionInspection Empty => new(
        new CuemonDetection(false, false, false, false, false, false, false, false, false, false, false, false, false, false, false),
        new CustomAssetDetection(false, false, false, false));
}

internal sealed record InspectionResult(
    string Tool,
    string RepoRoot,
    IReadOnlyList<WebProjectInfo> WebProjects,
    string? SelectedProject,
    string Classification,
    IReadOnlyList<RiskSignal> RiskSignals,
    ExistingSegregation ExistingSegregation,
    bool CuemonPresent,
    AssetAbstractionInspection AssetAbstractions,
    string Recommendation)
{
    public bool Ok => true;
}

internal sealed record ResolvedNuGetPackage(
    string PackageId,
    string Version,
    string Policy,
    string Source);

internal sealed class NuGetResolutionException(string message, Exception? innerException = null)
    : Exception(message, innerException);

// ---------------------------------------------------------------------------
// NuGet resolution (networked in plan; fake-handler covered in --self-test)
// ---------------------------------------------------------------------------

internal static class NuGetVersionResolver
{
    internal const string LatestStablePolicy = "latest-stable";

    public static async Task<ResolvedNuGetPackage> ResolveLatestStableAsync(
        string packageId,
        HttpClient? httpClient = null,
        Uri? serviceIndexUri = null,
        CancellationToken cancellationToken = default)
    {
        if (string.IsNullOrWhiteSpace(packageId))
            throw new ArgumentException("A NuGet package ID is required.", nameof(packageId));

        using var ownedClient = httpClient is null
            ? new HttpClient { Timeout = TimeSpan.FromSeconds(30) }
            : null;
        var client = httpClient ?? ownedClient!;
        if (httpClient is null)
            client.DefaultRequestHeaders.UserAgent.ParseAdd("dotnet-segregated-assets/1.0");

        var resolvedServiceIndex = serviceIndexUri ?? new Uri(SegregateAssetsProgram.NuGetServiceIndex);
        try
        {
            using var serviceIndex = await GetJsonAsync(client, resolvedServiceIndex, cancellationToken);
            var packageBaseAddress = FindPackageBaseAddress(serviceIndex.RootElement);
            var packageIndexUri = new Uri(
                packageBaseAddress.ToString().TrimEnd('/') + "/" +
                Uri.EscapeDataString(packageId.ToLowerInvariant()) + "/index.json");

            using var packageIndex = await GetJsonAsync(client, packageIndexUri, cancellationToken);
            var version = SelectLatestStable(packageId, packageIndex.RootElement);
            return new ResolvedNuGetPackage(packageId, version, LatestStablePolicy, packageIndexUri.AbsoluteUri);
        }
        catch (NuGetResolutionException)
        {
            throw;
        }
        catch (Exception ex) when (ex is HttpRequestException or TaskCanceledException or JsonException or UriFormatException)
        {
            throw new NuGetResolutionException(
                $"Could not resolve the latest stable version of '{packageId}' from NuGet.org: {ex.Message}", ex);
        }
    }

    private static async Task<JsonDocument> GetJsonAsync(
        HttpClient client,
        Uri uri,
        CancellationToken cancellationToken)
    {
        using var response = await client.GetAsync(uri, HttpCompletionOption.ResponseHeadersRead, cancellationToken);
        if (!response.IsSuccessStatusCode)
        {
            throw new NuGetResolutionException(
                $"NuGet returned HTTP {(int)response.StatusCode} ({response.ReasonPhrase}) for {uri}.");
        }

        await using var stream = await response.Content.ReadAsStreamAsync(cancellationToken);
        return await JsonDocument.ParseAsync(stream, cancellationToken: cancellationToken);
    }

    private static Uri FindPackageBaseAddress(JsonElement serviceIndex)
    {
        if (!serviceIndex.TryGetProperty("resources", out var resources) || resources.ValueKind != JsonValueKind.Array)
            throw new NuGetResolutionException("NuGet service index did not contain a resources array.");

        foreach (var resource in resources.EnumerateArray())
        {
            if (!resource.TryGetProperty("@type", out var type) || !HasPackageBaseAddressType(type)) continue;
            if (!resource.TryGetProperty("@id", out var id) || id.ValueKind != JsonValueKind.String) continue;
            if (Uri.TryCreate(id.GetString(), UriKind.Absolute, out var packageBaseAddress))
                return packageBaseAddress;
        }

        throw new NuGetResolutionException("NuGet service index did not expose PackageBaseAddress/3.0.0.");
    }

    private static bool HasPackageBaseAddressType(JsonElement type) => type.ValueKind switch
    {
        JsonValueKind.String => string.Equals(type.GetString(), "PackageBaseAddress/3.0.0", StringComparison.Ordinal),
        JsonValueKind.Array => type.EnumerateArray().Any(item =>
            item.ValueKind == JsonValueKind.String &&
            string.Equals(item.GetString(), "PackageBaseAddress/3.0.0", StringComparison.Ordinal)),
        _ => false,
    };

    private static string SelectLatestStable(string packageId, JsonElement packageIndex)
    {
        if (!packageIndex.TryGetProperty("versions", out var versions) || versions.ValueKind != JsonValueKind.Array)
            throw new NuGetResolutionException($"NuGet returned no version list for '{packageId}'.");

        string? latest = null;
        string[]? latestKey = null;
        foreach (var item in versions.EnumerateArray())
        {
            if (item.ValueKind != JsonValueKind.String) continue;
            var candidate = item.GetString();
            if (!TryGetStableVersionKey(candidate, out var candidateKey)) continue;
            if (latestKey is null || CompareVersionKeys(candidateKey, latestKey) > 0 ||
                (CompareVersionKeys(candidateKey, latestKey) == 0 && string.CompareOrdinal(candidate, latest) > 0))
            {
                latest = candidate;
                latestKey = candidateKey;
            }
        }

        return latest ?? throw new NuGetResolutionException(
            $"NuGet returned no stable versions for '{packageId}'; prerelease versions are not selected automatically.");
    }

    private static bool TryGetStableVersionKey(string? version, out string[] key)
    {
        key = Array.Empty<string>();
        if (string.IsNullOrWhiteSpace(version) || version.Contains('-', StringComparison.Ordinal)) return false;

        var core = version.Split('+', 2)[0];
        var parts = core.Split('.');
        if (parts.Length is < 1 or > 4 || parts.Any(part => part.Length == 0 || part.Any(ch => !char.IsAsciiDigit(ch))))
            return false;

        key = parts.Select(NormalizeNumericIdentifier).ToArray();
        return true;
    }

    private static string NormalizeNumericIdentifier(string value)
    {
        var normalized = value.TrimStart('0');
        return normalized.Length == 0 ? "0" : normalized;
    }

    private static int CompareVersionKeys(IReadOnlyList<string> left, IReadOnlyList<string> right)
    {
        var count = Math.Max(left.Count, right.Count);
        for (var i = 0; i < count; i++)
        {
            var leftPart = i < left.Count ? left[i] : "0";
            var rightPart = i < right.Count ? right[i] : "0";
            var lengthComparison = leftPart.Length.CompareTo(rightPart.Length);
            if (lengthComparison != 0) return lengthComparison;
            var valueComparison = string.CompareOrdinal(leftPart, rightPart);
            if (valueComparison != 0) return valueComparison;
        }
        return 0;
    }
}

// ---------------------------------------------------------------------------
// Detectors (pure over the filesystem)
// ---------------------------------------------------------------------------

internal static class ProjectScanner
{
    private static readonly Regex SdkAttr = new("<Project[^>]*\\bSdk\\s*=\\s*\"(?<sdk>[^\"]+)\"", RegexOptions.IgnoreCase | RegexOptions.Compiled);

    public static string? ReadSdk(string csprojText)
    {
        var m = SdkAttr.Match(csprojText);
        return m.Success ? m.Groups["sdk"].Value : null;
    }

    public static bool IsWebSdk(string? sdk) =>
        sdk is not null && sdk.Contains("Microsoft.NET.Sdk.Web", StringComparison.OrdinalIgnoreCase);

    public static IReadOnlyList<WebProjectInfo> Discover(string repoRoot)
    {
        var projects = new List<WebProjectInfo>();
        foreach (var csproj in EnumerateProjects(repoRoot))
        {
            string text;
            try { text = File.ReadAllText(csproj); } catch { continue; }
            var sdk = ReadSdk(text);
            var isWeb = IsWebSdk(sdk);
            var dir = Path.GetDirectoryName(csproj)!;
            var hasWwwroot = Directory.Exists(Path.Combine(dir, "wwwroot"));
            if (!isWeb) continue; // only web-application projects are candidates
            projects.Add(new WebProjectInfo(
                csproj,
                Rel(repoRoot, csproj),
                sdk,
                isWeb,
                hasWwwroot));
        }
        return projects
            .OrderBy(p => p.RelativePath, StringComparer.OrdinalIgnoreCase)
            .ToList();
    }

    public static IEnumerable<string> EnumerateProjects(string root)
    {
        var options = new EnumerationOptions { RecurseSubdirectories = true, IgnoreInaccessible = true };
        foreach (var file in Directory.EnumerateFiles(root, "*.csproj", options))
        {
            var normalized = file.Replace('\\', '/');
            if (normalized.Contains("/bin/", StringComparison.OrdinalIgnoreCase)) continue;
            if (normalized.Contains("/obj/", StringComparison.OrdinalIgnoreCase)) continue;
            yield return file;
        }
    }

    public static string Rel(string root, string path)
    {
        var rel = Path.GetRelativePath(root, path);
        return rel.Replace('\\', '/');
    }
}

internal static class StaticWebAssetRiskDetector
{
    // Detects generated / static-web-asset scenarios that must NOT be blindly excluded from publish.
    public static IReadOnlyList<RiskSignal> Detect(string projectPath, string repoRoot)
    {
        var signals = new List<RiskSignal>();
        var dir = Path.GetDirectoryName(projectPath)!;
        string csproj;
        try { csproj = File.ReadAllText(projectPath); } catch { csproj = string.Empty; }
        var sdk = ProjectScanner.ReadSdk(csproj) ?? string.Empty;

        void Add(string code, string detail)
        {
            if (!signals.Any(s => s.Code == code)) signals.Add(new RiskSignal(code, detail));
        }

        if (sdk.Contains("BlazorWebAssembly", StringComparison.OrdinalIgnoreCase))
            Add("BLAZOR_WEBASSEMBLY", "Project SDK is Microsoft.NET.Sdk.BlazorWebAssembly.");

        if (Regex.IsMatch(csproj, "Microsoft\\.AspNetCore\\.Components\\.WebAssembly", RegexOptions.IgnoreCase))
            Add("BLAZOR_WEBASSEMBLY", "PackageReference to Microsoft.AspNetCore.Components.WebAssembly.");

        var programFiles = SafeFiles(dir, "Program.cs");
        var programText = string.Concat(programFiles.Select(SafeRead));
        var razorFiles = SafeFiles(dir, "*.razor");
        if (razorFiles.Count > 0 &&
            (Regex.IsMatch(programText, "AddRazorComponents|MapRazorComponents", RegexOptions.IgnoreCase) ||
             Regex.IsMatch(csproj, "Microsoft\\.AspNetCore\\.Components\\.Web\\b", RegexOptions.IgnoreCase)))
            Add("BLAZOR_WEB_APP", "Razor components (*.razor) with AddRazorComponents/MapRazorComponents or Components.Web reference.");

        if (SafeFiles(dir, "*.razor.css").Count > 0 || SafeFiles(dir, "*.cshtml.css").Count > 0)
            Add("SCOPED_CSS", "Scoped CSS files (*.razor.css / *.cshtml.css) generate a bundled <project>.styles.css static web asset.");

        if (SafeFiles(dir, "*.razor.js").Count > 0)
            Add("RAZOR_COMPONENT_JS", "Collocated JavaScript modules (*.razor.js) are emitted as static web assets.");

        // Reference to framework/content asset paths inside markup or code.
        foreach (var ext in new[] { "*.cshtml", "*.razor", "*.html", "*.cs" })
        {
            foreach (var f in SafeFiles(dir, ext))
            {
                var t = SafeRead(f);
                if (t.Contains("_framework/", StringComparison.OrdinalIgnoreCase) || t.Contains("blazor.web.js", StringComparison.OrdinalIgnoreCase) || t.Contains("blazor.webassembly.js", StringComparison.OrdinalIgnoreCase))
                    Add("FRAMEWORK_ASSETS_REFERENCE", "Markup references _framework/ (Blazor runtime static web assets).");
                if (t.Contains("_content/", StringComparison.OrdinalIgnoreCase))
                    Add("CONTENT_ASSETS_REFERENCE", "Markup references _content/ (Razor Class Library static web assets).");
            }
        }

        // Referenced Razor Class Libraries that contribute wwwroot static web assets.
        foreach (var refProj in ResolveProjectReferences(projectPath, csproj))
        {
            string refText;
            try { refText = File.ReadAllText(refProj); } catch { continue; }
            var refSdk = ProjectScanner.ReadSdk(refText) ?? string.Empty;
            var refDir = Path.GetDirectoryName(refProj)!;
            var isRazorSdk = refSdk.Contains("Microsoft.NET.Sdk.Razor", StringComparison.OrdinalIgnoreCase);
            if ((isRazorSdk || Regex.IsMatch(refText, "AddRazorSupportForMvc|StaticWebAssetBasePath|RazorLangVersion", RegexOptions.IgnoreCase))
                && Directory.Exists(Path.Combine(refDir, "wwwroot")))
                Add("RAZOR_CLASS_LIBRARY_ASSETS", $"Referenced project '{ProjectScanner.Rel(repoRoot, refProj)}' contributes wwwroot static web assets (published under _content/).");
        }

        if (Regex.IsMatch(csproj, "<StaticWebAssetsEnabled>\\s*false\\s*</StaticWebAssetsEnabled>", RegexOptions.IgnoreCase))
            Add("STATIC_WEB_ASSETS_CONFIGURATION", "Static Web Assets configuration requires explicit generated-asset review before segregation.");

        if (HasFrontendBuildPipeline(dir))
            Add("FRONTEND_BUILD_PIPELINE", "A frontend build (package.json + bundler) generates final wwwroot output; the image must ship generated output, not source inputs.");

        return signals;
    }

    private static bool HasFrontendBuildPipeline(string dir)
    {
        var packageJson = Path.Combine(dir, "package.json");
        if (!File.Exists(packageJson)) return false;
        var text = SafeRead(packageJson);
        var hasBuildScript = Regex.IsMatch(text, "\"scripts\"\\s*:\\s*\\{[^}]*\"(build|bundle|dist)\"", RegexOptions.IgnoreCase | RegexOptions.Singleline);
        var hasBundler = Regex.IsMatch(text, "webpack|vite|rollup|esbuild|parcel|gulp|@angular|react-scripts", RegexOptions.IgnoreCase);
        return hasBuildScript || hasBundler;
    }

    public static IReadOnlyList<string> ResolveProjectReferences(string projectPath, string csprojText)
    {
        var dir = Path.GetDirectoryName(projectPath)!;
        var refs = new List<string>();
        foreach (Match m in Regex.Matches(csprojText, "<ProjectReference[^>]*Include\\s*=\\s*\"(?<inc>[^\"]+)\"", RegexOptions.IgnoreCase))
        {
            var inc = m.Groups["inc"].Value.Replace('\\', Path.DirectorySeparatorChar).Replace('/', Path.DirectorySeparatorChar);
            var full = Path.GetFullPath(Path.Combine(dir, inc));
            if (File.Exists(full)) refs.Add(full);
        }
        return refs;
    }

    private static List<string> SafeFiles(string dir, string pattern)
    {
        try
        {
            var options = new EnumerationOptions { RecurseSubdirectories = true, IgnoreInaccessible = true };
            return Directory.EnumerateFiles(dir, pattern, options)
                .Where(f => { var n = f.Replace('\\', '/'); return !n.Contains("/bin/") && !n.Contains("/obj/") && !n.Contains("/node_modules/"); })
                .ToList();
        }
        catch { return new List<string>(); }
    }

    private static string SafeRead(string file)
    {
        try { return File.ReadAllText(file); } catch { return string.Empty; }
    }
}

internal static class AssetSourceVersioningDetector
{
    public static IReadOnlyList<RiskSignal> Detect(string projectPath, string repoRoot)
    {
        var assetRoot = Path.Combine(Path.GetDirectoryName(projectPath)!, "wwwroot");
        if (!Directory.Exists(assetRoot) || !Directory.EnumerateFiles(assetRoot, "*", SearchOption.AllDirectories).Any())
            return Array.Empty<RiskSignal>();

        var (rootExitCode, gitRootOutput) = RunGit(repoRoot, "rev-parse", "--show-toplevel");
        if (rootExitCode != 0) return Array.Empty<RiskSignal>();

        var gitRoot = gitRootOutput.Trim();
        if (string.IsNullOrWhiteSpace(gitRoot)) return Array.Empty<RiskSignal>();
        var relativeAssetRoot = Path.GetRelativePath(gitRoot, assetRoot).Replace('\\', '/');
        if (relativeAssetRoot.StartsWith("../", StringComparison.Ordinal)) return Array.Empty<RiskSignal>();

        var (ignoreExitCode, _) = RunGit(gitRoot, "check-ignore", "--quiet", "--", relativeAssetRoot);
        var (_, trackedOutput) = RunGit(gitRoot, "ls-files", "--", relativeAssetRoot);
        var hasTrackedAssets = !string.IsNullOrWhiteSpace(trackedOutput);
        if (hasTrackedAssets) return Array.Empty<RiskSignal>();

        var reason = ignoreExitCode == 0
            ? $"Asset source '{relativeAssetRoot}' is ignored by Git"
            : $"Asset source '{relativeAssetRoot}' has no Git-tracked files";
        return new[]
        {
            new RiskSignal(
                "ASSET_SOURCE_NOT_VERSIONED",
                $"{reason}. A clean checkout cannot reproduce Assets.Dockerfile; track the source, use Git LFS, or materialize it from a pinned immutable artifact before building the asset image."),
        };
    }

    private static (int ExitCode, string Output) RunGit(string workingDirectory, params string[] arguments)
    {
        try
        {
            var startInfo = new ProcessStartInfo("git")
            {
                WorkingDirectory = workingDirectory,
                RedirectStandardOutput = true,
                RedirectStandardError = true,
                UseShellExecute = false,
            };
            foreach (var argument in arguments) startInfo.ArgumentList.Add(argument);
            using var process = Process.Start(startInfo);
            if (process is null) return (-1, string.Empty);
            var standardOutput = process.StandardOutput.ReadToEnd();
            process.StandardError.ReadToEnd();
            process.WaitForExit();
            return (process.ExitCode, standardOutput);
        }
        catch
        {
            return (-1, string.Empty);
        }
    }
}

internal static class AssetImageCiDetector
{
    public static IReadOnlyList<RiskSignal> Detect(string repoRoot)
    {
        var hasAssetDockerfile = IdempotencyDetector.EnumerateDockerfiles(repoRoot)
            .Any(path => Path.GetFileName(path).Equals(SegregateAssetsProgram.DerivedDockerfileName, StringComparison.OrdinalIgnoreCase));
        if (!hasAssetDockerfile) return Array.Empty<RiskSignal>();

        var workflowRoot = Path.Combine(repoRoot, ".github", "workflows");
        if (!Directory.Exists(workflowRoot)) return Array.Empty<RiskSignal>();

        var workflows = Directory.EnumerateFiles(workflowRoot, "*.y*ml", SearchOption.TopDirectoryOnly)
            .Select(File.ReadAllText)
            .ToList();
        var buildsContainerImages = workflows.Any(text =>
            text.Contains("docker/build-push-action", StringComparison.OrdinalIgnoreCase) ||
            Regex.IsMatch(text, "\\bdocker\\s+build\\b", RegexOptions.IgnoreCase));
        var buildsAssetImage = workflows.Any(text =>
            text.Contains(SegregateAssetsProgram.DerivedDockerfileName, StringComparison.OrdinalIgnoreCase));
        if (!buildsContainerImages || buildsAssetImage) return Array.Empty<RiskSignal>();

        return new[]
        {
            new RiskSignal(
                "ASSET_IMAGE_NOT_VALIDATED_IN_CI",
                $"The repository builds container images in GitHub Actions but no workflow references {SegregateAssetsProgram.DerivedDockerfileName}. Build or validate the asset image from the same commit as the web image so a clean hosted run proves the deployment pair."),
        };
    }
}

internal static class AssetAbstractionDetector
{
    public static AssetAbstractionInspection Detect(string projectPath, string repoRoot)
    {
        var projectDirectory = Path.GetDirectoryName(projectPath)!;
        var files = EnumerateSourceFiles(projectDirectory).ToList();
        var code = string.Concat(files.Where(IsCodeFile).Select(SafeRead).Select(t => t + "\n"));
        var markup = string.Concat(files.Where(IsMarkupFile).Select(SafeRead).Select(t => t + "\n"));
        var all = code + markup;
        var projectText = SafeRead(projectPath);

        var packageReference = ContainsCuemonPackageReference(projectText) ||
                               EnumerateAncestorBuildFiles(projectDirectory, repoRoot)
                                   .Any(f => ContainsCuemonPackageReference(SafeRead(f)));
        var projectReference = StaticWebAssetRiskDetector.ResolveProjectReferences(projectPath, projectText)
            .Any(p => ContainsCuemonPackageReference(SafeRead(p)) ||
                      EnumerateAncestorBuildFiles(Path.GetDirectoryName(p)!, repoRoot)
                          .Any(f => ContainsCuemonPackageReference(SafeRead(f))));
        var namespaceUsing = Regex.IsMatch(all, @"\busing\s+(?:global\s+)?Cuemon\.AspNetCore\.Razor\.TagHelpers\b", RegexOptions.IgnoreCase);
        var appOptions = Regex.IsMatch(all, @"\bAppTagHelperOptions\b", RegexOptions.IgnoreCase);
        var cdnOptions = Regex.IsMatch(all, @"\bCdnTagHelperOptions\b", RegexOptions.IgnoreCase);
        var viewImportsRegistration = files
            .Where(f => string.Equals(Path.GetFileName(f), "_ViewImports.cshtml", StringComparison.OrdinalIgnoreCase))
            .Select(SafeRead)
            .Any(t => Regex.IsMatch(t, @"@(?:addTagHelper|using)\b[^\r\n]*Cuemon\.AspNetCore\.Razor\.TagHelpers", RegexOptions.IgnoreCase));

        var cuemon = new CuemonDetection(
            packageReference,
            projectReference,
            namespaceUsing,
            appOptions,
            cdnOptions,
            viewImportsRegistration,
            Regex.IsMatch(markup, @"<app-link\b", RegexOptions.IgnoreCase),
            Regex.IsMatch(markup, @"<app-script\b", RegexOptions.IgnoreCase),
            Regex.IsMatch(markup, @"<app-img\b", RegexOptions.IgnoreCase),
            Regex.IsMatch(markup, @"<cdn-link\b", RegexOptions.IgnoreCase),
            Regex.IsMatch(markup, @"<cdn-script\b", RegexOptions.IgnoreCase),
            Regex.IsMatch(markup, @"<cdn-img\b", RegexOptions.IgnoreCase),
            Regex.IsMatch(markup, @"\b(?:app|cdn)-(?:href|src)\s*=", RegexOptions.IgnoreCase),
            Regex.IsMatch(markup, @"\basp-append-version\b", RegexOptions.IgnoreCase),
            Regex.IsMatch(all, @"\b(?:ICacheBusting|Add(?:Assembly|Dynamic)?CacheBusting)\b", RegexOptions.IgnoreCase));

        var custom = new CustomAssetDetection(
            Regex.IsMatch(all, @"\b(?:AppAssetOptions|SegregatedAssetsOptions|AssetOptions|AssetsOptions)\b|\b(?:class|record)\s+\w*(?:Asset|Assets)Options\b", RegexOptions.IgnoreCase),
            Regex.IsMatch(all, @"\b(?:AppAssets|AssetOptions|Assets|\w*(?:Asset|Assets|Options))\s*(?:\.\s*Value)?\s*\.\s*Get(?:Asset)?Url\s*\(", RegexOptions.IgnoreCase),
            Regex.IsMatch(code, @"\b(?:Configure|Add(?:Singleton|Scoped|Transient)|TryAdd(?:Singleton|Scoped|Transient))\s*<\s*[^>]*(?:AppAsset|SegregatedAssets|Asset)Options\b", RegexOptions.IgnoreCase),
            Regex.IsMatch(markup, @"@inject\s+[^\r\n]*(?:AppAssets|AppAssetOptions|AssetOptions|Assets)\b", RegexOptions.IgnoreCase));

        return new AssetAbstractionInspection(cuemon, custom);
    }

    private static bool ContainsCuemonPackageReference(string text) =>
        Regex.IsMatch(text, $@"<PackageReference\b[^>]*\b(?:Include|Update)\s*=\s*['""]{Regex.Escape(SegregateAssetsProgram.CuemonPackageId)}['""]", RegexOptions.IgnoreCase);

    private static IEnumerable<string> EnumerateAncestorBuildFiles(string directory, string repoRoot)
    {
        var current = new DirectoryInfo(Path.GetFullPath(directory));
        var root = new DirectoryInfo(Path.GetFullPath(repoRoot));
        while (current is not null)
        {
            foreach (var fileName in new[] { "Directory.Build.props", "Directory.Build.targets" })
            {
                var buildFile = Path.Combine(current.FullName, fileName);
                if (File.Exists(buildFile)) yield return buildFile;
            }
            if (string.Equals(current.FullName, root.FullName, StringComparison.OrdinalIgnoreCase)) break;
            current = current.Parent!;
        }
    }

    private static IEnumerable<string> EnumerateSourceFiles(string directory)
    {
        var options = new EnumerationOptions { RecurseSubdirectories = true, IgnoreInaccessible = true };
        IEnumerable<string> files;
        try { files = Directory.EnumerateFiles(directory, "*", options); }
        catch { return Array.Empty<string>(); }

        return files
            .Where(f =>
            {
                var normalized = f.Replace('\\', '/');
                var name = Path.GetFileName(f);
                return (IsCodeFile(f) || IsMarkupFile(f)) &&
                       !normalized.Contains("/bin/", StringComparison.OrdinalIgnoreCase) &&
                       !normalized.Contains("/obj/", StringComparison.OrdinalIgnoreCase) &&
                       !normalized.Contains("/node_modules/", StringComparison.OrdinalIgnoreCase) &&
                       !name.Equals("Directory.Packages.props", StringComparison.OrdinalIgnoreCase);
            })
            .OrderBy(f => f, StringComparer.OrdinalIgnoreCase);
    }

    private static bool IsCodeFile(string file) =>
        file.EndsWith(".cs", StringComparison.OrdinalIgnoreCase);

    private static bool IsMarkupFile(string file) =>
        file.EndsWith(".cshtml", StringComparison.OrdinalIgnoreCase) ||
        file.EndsWith(".razor", StringComparison.OrdinalIgnoreCase) ||
        file.EndsWith(".html", StringComparison.OrdinalIgnoreCase);

    private static string SafeRead(string file)
    {
        try { return File.ReadAllText(file); } catch { return string.Empty; }
    }
}

internal static class IdempotencyDetector
{
    public static ExistingSegregation Detect(string projectPath, string repoRoot, AssetAbstractionInspection? abstractions = null)
    {
        var dir = Path.GetDirectoryName(projectPath)!;
        var csproj = SafeRead(projectPath);

        var publishExclusion = Regex.IsMatch(
            csproj,
            "<Content\\b[^>]*Update\\s*=\\s*\"wwwroot[\\\\/][*][*][^\"]*\"[^>]*CopyToPublishDirectory\\s*=\\s*\"Never\"",
            RegexOptions.IgnoreCase)
            || Regex.IsMatch(csproj, "CopyToPublishDirectory\\s*=\\s*\"Never\"[^>]*Update\\s*=\\s*\"wwwroot", RegexOptions.IgnoreCase);

        var projectLaunchSettings = Path.Combine(dir, "Properties", "launchSettings.json");
        var composeLaunchSettings = Path.Combine(repoRoot, "launchSettings.json");
        var segregatedProfileName = LaunchProfileNaming.Resolve(projectPath);
        var segregatedProfile = new[] { composeLaunchSettings, projectLaunchSettings }
            .Any(path => File.Exists(path) &&
                         SafeRead(path).Contains(segregatedProfileName, StringComparison.OrdinalIgnoreCase));

        var composeService = EnumerateComposeFiles(repoRoot)
            .Select(SafeRead)
            .Any(t => t.Contains("codebeltnet/web-cdn-origin", StringComparison.OrdinalIgnoreCase) ||
                      t.Contains(SegregateAssetsProgram.DerivedDockerfileName, StringComparison.OrdinalIgnoreCase));

        var derivedDockerfile = EnumerateDockerfiles(repoRoot)
            .Select(SafeRead)
            .Any(t => Regex.IsMatch(t, "^\\s*FROM\\s+codebeltnet/web-cdn-origin", RegexOptions.IgnoreCase | RegexOptions.Multiline));

        var cuemonAppOptions = (abstractions ?? AssetAbstractionDetector.Detect(projectPath, repoRoot)).Cuemon.OptionsDetected;

        return new ExistingSegregation(publishExclusion, segregatedProfile, composeService, derivedDockerfile, cuemonAppOptions);
    }

    public static IEnumerable<string> EnumerateComposeFiles(string root)
    {
        var options = new EnumerationOptions { RecurseSubdirectories = true, IgnoreInaccessible = true };
        foreach (var f in Directory.EnumerateFiles(root, "*.y*ml", options))
        {
            var name = Path.GetFileName(f).ToLowerInvariant();
            var n = f.Replace('\\', '/');
            if (n.Contains("/bin/") || n.Contains("/obj/")) continue;
            if (name.Contains("compose") || name.Contains("docker-compose")) yield return f;
        }
    }

    public static IEnumerable<string> EnumerateDockerfiles(string root)
    {
        var options = new EnumerationOptions { RecurseSubdirectories = true, IgnoreInaccessible = true };
        foreach (var f in Directory.EnumerateFiles(root, "*", options))
        {
            var name = Path.GetFileName(f);
            var n = f.Replace('\\', '/');
            if (n.Contains("/bin/") || n.Contains("/obj/")) continue;
            if (name.Equals("Dockerfile", StringComparison.OrdinalIgnoreCase) ||
                name.StartsWith("Dockerfile.", StringComparison.OrdinalIgnoreCase) ||
                name.EndsWith(".Dockerfile", StringComparison.OrdinalIgnoreCase))
                yield return f;
        }
    }

    private static List<string> SafeFiles(string dir, string pattern)
    {
        try
        {
            var options = new EnumerationOptions { RecurseSubdirectories = true, IgnoreInaccessible = true };
            return Directory.EnumerateFiles(dir, pattern, options)
                .Where(f => { var n = f.Replace('\\', '/'); return !n.Contains("/bin/") && !n.Contains("/obj/"); })
                .ToList();
        }
        catch { return new List<string>(); }
    }

    private static string SafeRead(string file)
    {
        try { return File.ReadAllText(file); } catch { return string.Empty; }
    }
}

internal static class Classifier
{
    public const string NotAWebApp = "NotAWebApp";
    public const string Ambiguous = "Ambiguous";
    public const string NoWwwroot = "NoWwwroot";
    public const string AlreadySegregated = "AlreadySegregated";
    public const string RiskyGeneratedAssets = "RiskyGeneratedAssets";
    public const string Simple = "Simple";

    public static string Classify(
        IReadOnlyList<WebProjectInfo> webProjects,
        WebProjectInfo? selected,
        IReadOnlyList<RiskSignal> risks,
        ExistingSegregation existing)
    {
        if (webProjects.Count == 0) return NotAWebApp;
        if (selected is null) return Ambiguous;
        if (risks.Count > 0) return RiskyGeneratedAssets;
        if (existing.Complete) return AlreadySegregated;
        if (!selected.HasWwwroot) return NoWwwroot;
        return Simple;
    }

    public static string Recommend(string classification, ExistingSegregation existing, AssetAbstractionInspection? abstractions = null)
    {
        if (classification == Simple && abstractions is not null)
        {
            if (abstractions.CompetingAbstractions)
                return "Cuemon App/CDN TagHelpers and a competing custom asset abstraction coexist. Migrate Razor references by ownership, then remove the custom abstraction only after all consumers are gone.";
            if (abstractions.CuemonPresent)
                return "Cuemon App/CDN TagHelpers are available. Reuse AppTagHelperOptions/CdnTagHelperOptions and migrate ownership-aware Razor references to app-* or cdn-* elements; do not create another URL abstraction.";
            if (abstractions.Custom.Present)
                return "An existing non-Cuemon asset abstraction is present. Reuse it and do not add Cuemon solely for segregation.";
        }

        return classification switch
        {
            NotAWebApp => "No Microsoft.NET.Sdk.Web project found. Nothing to segregate; confirm the target repository.",
            Ambiguous => "Multiple web projects found. Ask which web project to segregate (pass --project).",
            NoWwwroot => "No wwwroot found. Configure only the CDN/shared-asset consumption if a CDN equivalent exists; otherwise nothing to do.",
            AlreadySegregated => "Segregation is already present. Reconcile existing configuration; do not create duplicate items, profiles, services, or Dockerfiles.",
            RiskyGeneratedAssets => "Generated, contributed, or unreproducible asset sources detected. Preserve the asset pipeline and establish a reproducible versioned or pinned input before proceeding.",
            Simple => existing.Any
                ? "Simple physical wwwroot with partial existing segregation. Complete the missing pieces idempotently."
                : "Simple physical wwwroot. Apply App-asset segregation: targeted publish exclusion, segregated launch profile, local origin, derived production image, and documentation.",
            _ => "Review findings.",
        };
    }
}

internal static class LaunchProfileNaming
{
    public static string Resolve(string projectPath)
    {
        var projectName = Path.GetFileNameWithoutExtension(projectPath);
        var launchSettings = Path.Combine(Path.GetDirectoryName(projectPath)!, "Properties", "launchSettings.json");
        if (!File.Exists(launchSettings)) return projectName + SegregateAssetsProgram.AssetsProfileSuffix;

        try
        {
            using var document = JsonDocument.Parse(File.ReadAllText(launchSettings));
            if (!document.RootElement.TryGetProperty("profiles", out var profiles) || profiles.ValueKind != JsonValueKind.Object)
                return projectName + SegregateAssetsProgram.AssetsProfileSuffix;

            var projectProfiles = profiles.EnumerateObject()
                .Where(profile => profile.Value.TryGetProperty("commandName", out var command) &&
                                  string.Equals(command.GetString(), "Project", StringComparison.OrdinalIgnoreCase))
                .Select(profile => profile.Name)
                .ToList();
            var exact = projectProfiles.FirstOrDefault(name => string.Equals(name, projectName, StringComparison.OrdinalIgnoreCase));
            var ordinaryProfile = exact ?? (projectProfiles.Count == 1 ? projectProfiles[0] : projectName);
            return ordinaryProfile + SegregateAssetsProgram.AssetsProfileSuffix;
        }
        catch
        {
            return projectName + SegregateAssetsProgram.AssetsProfileSuffix;
        }
    }
}

internal static class LaunchProfileValidator
{
    public sealed record Result(bool ProfileExists, bool IsDockerCompose, bool IsHttp, bool HasHttpLocalOrigin, bool HasUnsafeProtocol, IReadOnlyList<string> Findings);

    // Validates the segregated launch profile in launchSettings.json JSON text.
    public static Result Validate(string launchSettingsJson, string profileName)
    {
        var findings = new List<string>();
        JsonDocument doc;
        try { doc = JsonDocument.Parse(launchSettingsJson); }
        catch (Exception ex) { return new Result(false, false, false, false, false, new[] { $"launchSettings.json is not valid JSON: {ex.Message}" }); }

        using (doc)
        {
            if (!doc.RootElement.TryGetProperty("profiles", out var profiles) ||
                !profiles.TryGetProperty(profileName, out var profile))
            {
                findings.Add($"Profile '{profileName}' is not present.");
                return new Result(false, false, false, false, false, findings);
            }

            var commandName = profile.TryGetProperty("commandName", out var command) ? (command.GetString() ?? string.Empty) : string.Empty;
            var isDockerCompose = commandName.Equals("DockerCompose", StringComparison.OrdinalIgnoreCase);
            var appUrlProperty = isDockerCompose ? "composeLaunchUrl" : "applicationUrl";
            var appUrl = profile.TryGetProperty(appUrlProperty, out var u) ? (u.GetString() ?? string.Empty) : string.Empty;
            var isHttp = appUrl.Contains("http://", StringComparison.OrdinalIgnoreCase) && !appUrl.Contains("https://", StringComparison.OrdinalIgnoreCase);
            if (!isHttp)
                findings.Add($"Segregated profile {appUrlProperty} should be HTTP-only so an HTTP local origin is not requested from an HTTPS page.");

            var envValues = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
            if (profile.TryGetProperty("environmentVariables", out var env) && env.ValueKind == JsonValueKind.Object)
            {
                foreach (var p in env.EnumerateObject())
                    envValues[p.Name] = p.Value.GetString() ?? string.Empty;
            }
            var envBlob = string.Join("\n", envValues.Select(p => $"{p.Key}={p.Value}"));

            var hasExplicitHttpLocalOrigin = Regex.IsMatch(envBlob, "http://localhost:\\d+", RegexOptions.IgnoreCase);
            var hasHostOnlyLocalOrigin = envValues.Any(p =>
                p.Key.EndsWith("__BaseUrl", StringComparison.OrdinalIgnoreCase) &&
                Regex.IsMatch(p.Value, "^localhost:\\d+/?$", RegexOptions.IgnoreCase));
            var hasHttpScheme = envValues.Any(p =>
                p.Key.EndsWith("__Scheme", StringComparison.OrdinalIgnoreCase) &&
                p.Value.Equals("Http", StringComparison.OrdinalIgnoreCase));
            var hasHttpLocalOrigin = hasExplicitHttpLocalOrigin || (hasHostOnlyLocalOrigin && hasHttpScheme);
            if (!hasHttpLocalOrigin && !isDockerCompose)
                findings.Add("Segregated profile should point App asset URLs at an HTTP localhost origin, either as http://localhost:<port> or host-only localhost:<port> with Scheme=Http.");

            var hasUnsafeProtocol = UnsafeOriginDetector.Detect(envBlob);
            if (hasUnsafeProtocol)
                findings.Add("Segregated profile uses a protocol-relative (//localhost) or https://localhost URL that would break an HTTP-only local origin.");

            return new Result(true, isDockerCompose, isHttp, hasHttpLocalOrigin, hasUnsafeProtocol, findings);
        }
    }
}

// Detects origins that would break the HTTP-only local Static Content Provider: protocol-relative
// //localhost and https://localhost. The scheme prefixes are neutralized first so a perfectly valid
// http://localhost:<port> value is not mistaken for a protocol-relative one.
internal static class UnsafeOriginDetector
{
    public static bool Detect(string text)
    {
        if (string.IsNullOrEmpty(text)) return false;
        if (Regex.IsMatch(text, "https://localhost", RegexOptions.IgnoreCase)) return true;
        var schemeless = Regex.Replace(text, "https?://", "", RegexOptions.IgnoreCase);
        return Regex.IsMatch(schemeless, "//localhost", RegexOptions.IgnoreCase);
    }
}

// Picks the asset-origin Compose file that belongs to the SELECTED project. A repository-wide
// "first match wins" scan lets a sibling project's healthy topology stand in for the selected
// project's broken one, so verification would prove something it was never asked about.
internal static class ComposeFileSelector
{
    public sealed record Selection(string? ComposeFile, bool BelongsToAnotherProject);

    public static Selection Select(string repoRoot, string projectPath, IEnumerable<string> webProjectRelativePaths)
    {
        var candidates = IdempotencyDetector.EnumerateComposeFiles(repoRoot)
            .Select(path => (Path: path, Text: SafeRead(path)))
            .Where(candidate => IsAssetOrigin(candidate.Text))
            .OrderBy(candidate => candidate.Path, StringComparer.OrdinalIgnoreCase)
            .ToList();
        if (candidates.Count == 0) return new Selection(null, false);

        var selectedDirectory = RelativeDirectory(repoRoot, Path.GetDirectoryName(projectPath)!);
        var otherDirectories = webProjectRelativePaths
            .Select(relative => NormalizeDirectory(Path.GetDirectoryName(relative) ?? string.Empty))
            .Where(directory => directory.Length > 0 && !directory.Equals(selectedDirectory, StringComparison.OrdinalIgnoreCase))
            .Distinct(StringComparer.OrdinalIgnoreCase)
            .ToList();

        if (selectedDirectory.Length > 0)
        {
            var mine = candidates.FirstOrDefault(candidate => Mentions(candidate.Text, selectedDirectory));
            if (mine.Path is not null) return new Selection(mine.Path, false);
        }

        // Nothing names the selected project. A file that names a different web project is that
        // project's topology; anything left is unattributed and safe to use when it is unambiguous.
        var unattributed = candidates
            .Where(candidate => !otherDirectories.Any(directory => Mentions(candidate.Text, directory)))
            .ToList();
        if (unattributed.Count == 1 || (unattributed.Count > 1 && selectedDirectory.Length == 0))
            return new Selection(unattributed[0].Path, false);

        return new Selection(null, unattributed.Count == 0);
    }

    private static bool IsAssetOrigin(string text) =>
        text.Contains(SegregateAssetsProgram.OriginImage, StringComparison.OrdinalIgnoreCase) ||
        text.Contains("codebeltnet/web-cdn-origin", StringComparison.OrdinalIgnoreCase) ||
        text.Contains(SegregateAssetsProgram.DerivedDockerfileName, StringComparison.OrdinalIgnoreCase);

    // Matches a repository-relative directory as a whole path segment so 'src/Acme.Api' never
    // matches 'src/Acme.ApiGateway'. Backslashes are normalized first.
    private static bool Mentions(string composeText, string relativeDirectory) =>
        Regex.IsMatch(
            composeText.Replace('\\', '/'),
            $"(?<![A-Za-z0-9_.-]){Regex.Escape(relativeDirectory)}(?![A-Za-z0-9_.-])",
            RegexOptions.IgnoreCase);

    private static string RelativeDirectory(string repoRoot, string directory)
    {
        var relative = Path.GetRelativePath(repoRoot, directory);
        return NormalizeDirectory(relative);
    }

    private static string NormalizeDirectory(string value)
    {
        var normalized = value.Replace('\\', '/').Trim('/');
        return normalized is "." or ".." ? string.Empty : normalized;
    }

    private static string SafeRead(string file)
    {
        try { return File.ReadAllText(file); } catch { return string.Empty; }
    }
}

internal static class ComposeValidator
{
    public sealed record Result(bool UsesOriginImage, bool HasAssetContent, bool UsesLocalDevelopmentImage, bool HasVisualStudioProjectOptOut, bool HasHttpLocalOrigin, bool HasUnsafeProtocol, bool ReadOnlyRootFs, bool NonPrivileged, bool NoDockerSocket, bool NoObsoleteVersionKey, IReadOnlyList<string> Findings);

    // Lightweight, line-oriented validation of the local origin service posture.
    public static Result Validate(string composeText)
    {
        var findings = new List<string>();

        var usesDerivedAssetImage = composeText.Contains(SegregateAssetsProgram.DerivedDockerfileName, StringComparison.OrdinalIgnoreCase);
        var usesOrigin = composeText.Contains(SegregateAssetsProgram.OriginImage, StringComparison.OrdinalIgnoreCase) || usesDerivedAssetImage;
        if (!usesOrigin) findings.Add($"Compose does not reference {SegregateAssetsProgram.OriginImage} or {SegregateAssetsProgram.DerivedDockerfileName}.");

        var readOnlyMount = Regex.IsMatch(composeText, ":/cdnroot:ro\\b", RegexOptions.IgnoreCase) ||
                            Regex.IsMatch(composeText, "target:\\s*/cdnroot[\\s\\S]{0,120}read_only:\\s*true", RegexOptions.IgnoreCase);
        var hasAssetContent = usesDerivedAssetImage || readOnlyMount;
        if (!hasAssetContent) findings.Add($"Compose should build {SegregateAssetsProgram.DerivedDockerfileName} or mount content into /cdnroot read-only.");

        var usesLocalDevelopmentImage = composeText.Contains("LocalDevelopment.Dockerfile", StringComparison.OrdinalIgnoreCase);
        if (!usesLocalDevelopmentImage) findings.Add("Compose should build the web application with LocalDevelopment.Dockerfile.");

        var assetService = FindAssetService(composeText);
        var hasVisualStudioProjectOptOut = assetService is not null && Regex.IsMatch(
            assetService,
            "(?m)^\\s+com\\.microsoft\\.visual-studio\\.project-name:\\s*(?:\"\"|'')\\s*$",
            RegexOptions.IgnoreCase);
        if (!hasVisualStudioProjectOptOut)
            findings.Add("The asset service must set com.microsoft.visual-studio.project-name: \"\" so Visual Studio does not inject the web project's debugger bootstrap into it.");

        var hasExplicitHttpLocalOrigin = Regex.IsMatch(composeText, "http://localhost:\\d+", RegexOptions.IgnoreCase);
        var hasHostOnlyLocalOrigin = Regex.IsMatch(composeText, "__BaseUrl\\s*:\\s*[\\\"']?localhost:\\d+/?[\\\"']?", RegexOptions.IgnoreCase);
        var hasHttpScheme = Regex.IsMatch(composeText, "__Scheme\\s*:\\s*[\\\"']?Http[\\\"']?", RegexOptions.IgnoreCase);
        var hasHttpLocalOrigin = hasExplicitHttpLocalOrigin || (hasHostOnlyLocalOrigin && hasHttpScheme);
        if (!hasHttpLocalOrigin) findings.Add("Compose should configure App asset URLs for an HTTP localhost origin.");

        var hasUnsafeProtocol = UnsafeOriginDetector.Detect(composeText);
        if (hasUnsafeProtocol) findings.Add("Compose uses a protocol-relative or HTTPS localhost asset origin that is unsafe for the HTTP-only local origin.");

        var readOnlyRootFs = Regex.IsMatch(composeText, "read_only:\\s*true", RegexOptions.IgnoreCase);
        if (!readOnlyRootFs) findings.Add("Prefer a read-only root filesystem (read_only: true) where practical.");

        var nonPrivileged = !Regex.IsMatch(composeText, "privileged:\\s*true", RegexOptions.IgnoreCase);
        if (!nonPrivileged) findings.Add("Do not run the origin in privileged mode.");

        var noDockerSocket = !composeText.Contains("docker.sock", StringComparison.OrdinalIgnoreCase);
        if (!noDockerSocket) findings.Add("Do not mount the Docker socket into the origin container.");

        var noObsoleteVersionKey = !Regex.IsMatch(composeText, "(?m)^version:\\s*[\\\"']?\\d", RegexOptions.IgnoreCase);
        if (!noObsoleteVersionKey) findings.Add("Remove the obsolete top-level Compose 'version:' key; current Docker Compose ignores it and warns about it.");

        return new Result(usesOrigin, hasAssetContent, usesLocalDevelopmentImage, hasVisualStudioProjectOptOut, hasHttpLocalOrigin, hasUnsafeProtocol, readOnlyRootFs, nonPrivileged, noDockerSocket, noObsoleteVersionKey, findings);
    }

    private static string? FindAssetService(string composeText)
    {
        var lines = composeText.Replace("\r\n", "\n").Split('\n');
        var services = new List<string>();
        StringBuilder? current = null;
        var insideServices = false;

        foreach (var line in lines)
        {
            if (!insideServices)
            {
                insideServices = Regex.IsMatch(line, "^services:\\s*$", RegexOptions.IgnoreCase);
                continue;
            }

            if (line.Length > 0 && !char.IsWhiteSpace(line[0])) break;
            if (Regex.IsMatch(line, "^  [A-Za-z0-9_.-]+:\\s*$"))
            {
                if (current is not null) services.Add(current.ToString());
                current = new StringBuilder().AppendLine(line);
            }
            else
            {
                current?.AppendLine(line);
            }
        }
        if (current is not null) services.Add(current.ToString());

        return services.FirstOrDefault(service =>
            service.Contains(SegregateAssetsProgram.DerivedDockerfileName, StringComparison.OrdinalIgnoreCase) ||
            service.Contains(SegregateAssetsProgram.OriginImage, StringComparison.OrdinalIgnoreCase));
    }
}

// Proves the artifact-first topology contract once a segregated Compose file exists: the three
// Dockerfiles sit beside the web project, neither application Dockerfile compiles source, the build
// context is trimmed by a .dockerignore that still carries the published artifact, the project
// declares LocalPublishDirectory behind a guarded publish target, CI produces the artifact both
// application Dockerfiles copy, and a Visual Studio Compose launch surface is registered completely.
internal static class ArtifactFirstValidator
{
    private const string LocalDevelopmentDockerfileName = "LocalDevelopment.Dockerfile";

    public sealed record Result(
        bool DockerfilesColocated,
        bool NoRootDockerfile,
        bool NoSourceCompilation,
        bool HasDockerIgnore,
        bool ArtifactsReachable,
        bool HasLocalPublishDirectory,
        bool HasGuardedPublishTarget,
        bool CiPublishesArtifact,
        bool VisualStudioComposeComplete,
        IReadOnlyList<string> Findings);

    // composeText drives what is required: a topology that mounts /cdnroot read-only instead of
    // building Assets.Dockerfile is not asked for an asset image it never uses.
    public static Result Validate(string repoRoot, string projectPath, string composeText)
    {
        var findings = new List<string>();
        var projectDir = Path.GetDirectoryName(projectPath)!;
        var projectRelativeDir = Path.GetRelativePath(repoRoot, projectDir).Replace('\\', '/');
        var projectIsRepoRoot = projectDir.TrimEnd('\\', '/').Equals(repoRoot.TrimEnd('\\', '/'), StringComparison.OrdinalIgnoreCase);

        var applicationImageInPlay = composeText.Contains(LocalDevelopmentDockerfileName, StringComparison.OrdinalIgnoreCase);
        var assetImageInPlay = composeText.Contains(SegregateAssetsProgram.DerivedDockerfileName, StringComparison.OrdinalIgnoreCase);

        var applicationDockerfiles = applicationImageInPlay
            ? new[] { "Dockerfile", LocalDevelopmentDockerfileName }
            : Array.Empty<string>();
        var expected = assetImageInPlay
            ? applicationDockerfiles.Append(SegregateAssetsProgram.DerivedDockerfileName).ToArray()
            : applicationDockerfiles;

        var misplaced = expected.Where(name => !File.Exists(Path.Combine(projectDir, name))).ToList();
        var dockerfilesColocated = misplaced.Count == 0;
        if (!dockerfilesColocated)
            findings.Add($"Expected {string.Join(", ", misplaced)} beside the web project in '{projectRelativeDir}/'. Dockerfiles for this topology live with the .csproj, not at the repository root.");

        var strayRootDockerfiles = projectIsRepoRoot
            ? new List<string>()
            : expected.Where(name => File.Exists(Path.Combine(repoRoot, name))).ToList();
        var noRootDockerfile = strayRootDockerfiles.Count == 0;
        if (!noRootDockerfile)
            findings.Add($"Repository root holds {string.Join(", ", strayRootDockerfiles)}; move them beside the web project so Visual Studio Container Tools discovery and the per-service Compose build contexts stay correct.");

        var compileFindings = new List<string>();
        foreach (var name in applicationDockerfiles)
        {
            foreach (var candidate in new[] { Path.Combine(projectDir, name), Path.Combine(repoRoot, name) })
            {
                if (!File.Exists(candidate)) continue;
                compileFindings.AddRange(InspectApplicationDockerfile(name, SafeRead(candidate)));
                break;
            }
        }
        var noSourceCompilation = compileFindings.Count == 0;
        findings.AddRange(compileFindings);

        var dockerIgnorePath = Path.Combine(repoRoot, ".dockerignore");
        var dockerIgnoreExists = File.Exists(dockerIgnorePath);
        var hasDockerIgnore = !applicationImageInPlay || dockerIgnoreExists;
        if (!hasDockerIgnore)
            findings.Add("Add a repository-root .dockerignore; the web service builds from the repository root and would otherwise send .git, bin, and obj to the daemon.");

        var artifactsReachable = !dockerIgnoreExists || !Regex.IsMatch(
            SafeRead(dockerIgnorePath),
            "(?m)^\\s*(\\*\\*[\\\\/])?artifacts([\\\\/][^\\r\\n]*)?\\s*$",
            RegexOptions.IgnoreCase);
        if (!artifactsReachable)
            findings.Add(".dockerignore excludes artifacts/, but Dockerfile and LocalDevelopment.Dockerfile copy artifacts/publish/ from the build context.");

        var csproj = SafeRead(projectPath);
        var hasLocalPublishDirectory = !applicationImageInPlay || csproj.Contains("<LocalPublishDirectory>", StringComparison.OrdinalIgnoreCase);
        if (!hasLocalPublishDirectory)
            findings.Add("The web project does not declare <LocalPublishDirectory>; an ordinary local build then never materializes the artifact both application Dockerfiles copy.");

        var hasGuardedPublishTarget = !applicationImageInPlay || EnumerateBuildFiles(repoRoot, projectDir)
            .Select(SafeRead)
            .Any(text => text.Contains("$(LocalPublishDirectory)", StringComparison.OrdinalIgnoreCase) &&
                         text.Contains("<Target", StringComparison.OrdinalIgnoreCase) &&
                         Regex.IsMatch(text, "'\\$\\(CI\\)'\\s*!=\\s*'true'", RegexOptions.IgnoreCase) &&
                         Regex.IsMatch(text, "'\\$\\(DesignTimeBuild\\)'\\s*!=\\s*'true'", RegexOptions.IgnoreCase));
        if (!hasGuardedPublishTarget)
            findings.Add("No MSBuild target publishes to $(LocalPublishDirectory) behind non-CI and non-design-time guards. See assets/LocalPublishTarget.targets.");

        var ciPublishesArtifact = !applicationImageInPlay || CiPublishesArtifact(repoRoot);
        if (!ciPublishesArtifact)
            findings.Add("No GitHub Actions workflow publishes the application to artifacts/publish. An artifact-first Dockerfile has no producer in a clean hosted checkout. Extend an existing workflow with assets/ci-artifact-jobs.yml, or create one from assets/ci-pipeline.yml when the repository has none.");

        var visualStudioComposeComplete = ValidateVisualStudioCompose(repoRoot, csproj, findings);

        return new Result(
            dockerfilesColocated,
            noRootDockerfile,
            noSourceCompilation,
            hasDockerIgnore,
            artifactsReachable,
            hasLocalPublishDirectory,
            hasGuardedPublishTarget,
            ciPublishesArtifact,
            visualStudioComposeComplete,
            findings);
    }

    private static IEnumerable<string> InspectApplicationDockerfile(string name, string text)
    {
        if (string.IsNullOrWhiteSpace(text)) yield break;

        if (Regex.IsMatch(text, "(?im)^\\s*FROM\\s+\\S*dotnet/sdk"))
            yield return $"{name} declares a .NET SDK stage. Application Dockerfiles in this topology package artifacts/publish/ and never compile source.";

        if (Regex.IsMatch(text, "(?im)^\\s*RUN\\b.*\\bdotnet\\s+(restore|build|publish)\\b"))
            yield return $"{name} runs dotnet restore/build/publish. The artifact is produced by the guarded local target or CI, not inside the image.";

        if (Regex.IsMatch(text, "(?im)^\\s*RUN\\b.*\\b(adduser|addgroup|useradd|groupadd)\\b"))
            yield return $"{name} creates a runtime user with RUN. The dhi.io base images already run as UID 65532, and the shell-less production base cannot execute RUN.";

        if (Regex.IsMatch(text, "(?im)^\\s*FROM\\s+mcr\\.microsoft\\.com/dotnet/(aspnetcore|runtime)"))
            yield return $"{name} uses an mcr.microsoft.com runtime. This topology targets the shell-less dhi.io/aspnetcore Alpine runtime and its matching -dev variant.";

        if (Regex.IsMatch(text, "(?im)^\\s*USER\\s+root\\b"))
            yield return $"{name} escalates to root. Keep the non-root 65532 runtime user.";

        if (!Regex.IsMatch(text, "(?im)^\\s*COPY\\b.*artifacts/publish/"))
            yield return $"{name} does not copy artifacts/publish/. Package the already-published artifact instead of rebuilding it.";
    }

    private static bool ValidateVisualStudioCompose(string repoRoot, string csproj, List<string> findings)
    {
        var rootLaunchSettings = Path.Combine(repoRoot, "launchSettings.json");
        var hasComposeLaunchSurface = File.Exists(rootLaunchSettings) &&
                                      SafeRead(rootLaunchSettings).Contains("DockerCompose", StringComparison.OrdinalIgnoreCase);
        var composeProjects = SafeEnumerate(repoRoot, "*.dcproj").ToList();
        if (!hasComposeLaunchSurface && composeProjects.Count == 0) return true;

        var complete = true;
        if (!hasComposeLaunchSurface)
        {
            findings.Add("A .dcproj exists but no repository-root launchSettings.json declares a commandName: DockerCompose profile, so Visual Studio has nothing to launch.");
            complete = false;
        }

        if (composeProjects.Count == 0)
        {
            findings.Add("A repository-root DockerCompose launch profile exists but no Microsoft.Docker.Sdk .dcproj registers it with Visual Studio.");
            complete = false;
        }
        else if (!composeProjects.Any(p => SafeRead(p).Contains("<DockerComposeBaseFilePath>compose.assets<", StringComparison.OrdinalIgnoreCase)))
        {
            findings.Add("No .dcproj points DockerComposeBaseFilePath at compose.assets, so Visual Studio would not resolve compose.assets.yml.");
            complete = false;
        }

        if (!csproj.Contains("<DockerComposeProjectPath>", StringComparison.OrdinalIgnoreCase))
        {
            findings.Add("The web project does not declare <DockerComposeProjectPath>, so Visual Studio cannot associate it with the Compose project.");
            complete = false;
        }

        return complete;
    }

    // GitHub Actions is the assumed and only supported delivery surface for these skills, so a
    // missing producer for the artifact-first image is a failure rather than a portability question.
    private static bool CiPublishesArtifact(string repoRoot)
    {
        var workflowRoot = Path.Combine(repoRoot, ".github", "workflows");
        return Directory.Exists(workflowRoot) &&
            Directory.EnumerateFiles(workflowRoot, "*.y*ml", SearchOption.TopDirectoryOnly)
                .Select(SafeRead)
                .Any(text => Regex.IsMatch(text, "dotnet\\s+publish[^\\r\\n]*artifacts[\\\\/]publish", RegexOptions.IgnoreCase));
    }

    private static IEnumerable<string> EnumerateBuildFiles(string repoRoot, string projectDir)
    {
        foreach (var name in new[] { "Directory.Build.targets", "Directory.Build.props" })
        {
            var directory = projectDir;
            while (!string.IsNullOrEmpty(directory))
            {
                var candidate = Path.Combine(directory, name);
                if (File.Exists(candidate)) yield return candidate;
                if (directory.TrimEnd('\\', '/').Equals(repoRoot.TrimEnd('\\', '/'), StringComparison.OrdinalIgnoreCase)) break;
                var parent = Path.GetDirectoryName(directory);
                if (parent is null || parent == directory) break;
                directory = parent;
            }
        }
    }

    private static IEnumerable<string> SafeEnumerate(string root, string pattern)
    {
        try
        {
            var options = new EnumerationOptions { RecurseSubdirectories = true, IgnoreInaccessible = true };
            return Directory.EnumerateFiles(root, pattern, options)
                .Where(f => { var n = f.Replace('\\', '/'); return !n.Contains("/bin/") && !n.Contains("/obj/"); })
                .ToList();
        }
        catch { return Array.Empty<string>(); }
    }

    private static string SafeRead(string file)
    {
        try { return File.ReadAllText(file); } catch { return string.Empty; }
    }
}

internal static class PublishLeakDetector
{
    public sealed record Result(bool Passed, IReadOnlyList<string> LeakedAppAssets, IReadOnlyList<string> PreservedSharedAssets);

    // App-owned wwwroot files must be absent from the publish artifact. RCL/framework assets under
    // _content/ and _framework/ are allowed (and expected) to survive.
    public static Result Detect(string sourceWwwroot, string publishDir)
    {
        var leaked = new List<string>();
        var preserved = new List<string>();

        var publishWwwroot = Path.Combine(publishDir, "wwwroot");
        if (Directory.Exists(publishWwwroot))
        {
            var options = new EnumerationOptions { RecurseSubdirectories = true, IgnoreInaccessible = true };
            foreach (var f in Directory.EnumerateFiles(publishWwwroot, "*", options))
            {
                var rel = Path.GetRelativePath(publishWwwroot, f).Replace('\\', '/');
                if (rel.StartsWith("_content/", StringComparison.OrdinalIgnoreCase) ||
                    rel.StartsWith("_framework/", StringComparison.OrdinalIgnoreCase))
                {
                    preserved.Add(rel);
                    continue;
                }
                leaked.Add(rel);
            }
        }

        // Cross-check specifically against the application-owned source files (ignoring compressed variants).
        var sourceRel = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        if (Directory.Exists(sourceWwwroot))
        {
            var options = new EnumerationOptions { RecurseSubdirectories = true, IgnoreInaccessible = true };
            foreach (var f in Directory.EnumerateFiles(sourceWwwroot, "*", options))
                sourceRel.Add(Path.GetRelativePath(sourceWwwroot, f).Replace('\\', '/'));
        }

        var appLeaked = leaked
            .Where(r => sourceRel.Contains(r) || sourceRel.Contains(StripCompression(r)))
            .OrderBy(r => r, StringComparer.OrdinalIgnoreCase)
            .ToList();

        // If no source list is available, any non-shared file under publish/wwwroot is treated as a leak.
        var effectiveLeaks = sourceRel.Count > 0 ? appLeaked : leaked.OrderBy(r => r, StringComparer.OrdinalIgnoreCase).ToList();

        return new Result(effectiveLeaks.Count == 0, effectiveLeaks, preserved.OrderBy(p => p, StringComparer.OrdinalIgnoreCase).ToList());
    }

    private static string StripCompression(string rel) =>
        rel.EndsWith(".br", StringComparison.OrdinalIgnoreCase) || rel.EndsWith(".gz", StringComparison.OrdinalIgnoreCase)
            ? rel[..rel.LastIndexOf('.')]
            : rel;
}

// ---------------------------------------------------------------------------
// Commands
// ---------------------------------------------------------------------------

internal static class Commands
{
    public static InspectionResult Inspect(string repoRoot, string? projectOption)
    {
        var webProjects = ProjectScanner.Discover(repoRoot);
        WebProjectInfo? selected = null;
        if (projectOption is not null)
        {
            var full = Path.GetFullPath(Path.Combine(repoRoot, projectOption));
            selected = webProjects.FirstOrDefault(p => string.Equals(p.Path, full, StringComparison.OrdinalIgnoreCase))
                       ?? webProjects.FirstOrDefault(p => string.Equals(p.RelativePath, projectOption.Replace('\\', '/'), StringComparison.OrdinalIgnoreCase));
        }
        else if (webProjects.Count == 1)
        {
            selected = webProjects[0];
        }

        IReadOnlyList<RiskSignal> risks = selected is not null
            ? StaticWebAssetRiskDetector.Detect(selected.Path, repoRoot)
                .Concat(AssetSourceVersioningDetector.Detect(selected.Path, repoRoot))
                .Concat(AssetImageCiDetector.Detect(repoRoot))
                .ToList()
            : Array.Empty<RiskSignal>();
        var abstractions = selected is not null ? AssetAbstractionDetector.Detect(selected.Path, repoRoot) : AssetAbstractionInspection.Empty;
        var existing = selected is not null ? IdempotencyDetector.Detect(selected.Path, repoRoot, abstractions) : new ExistingSegregation(false, false, false, false, false);
        var classification = Classifier.Classify(webProjects, selected, risks, existing);
        var cuemonPresent = abstractions.CuemonPresent;
        var recommendation = Classifier.Recommend(classification, existing, abstractions);

        return new InspectionResult(
            SegregateAssetsProgram.ToolName,
            repoRoot,
            webProjects,
            selected?.RelativePath,
            classification,
            risks,
            existing,
            cuemonPresent,
            abstractions,
            recommendation);
    }

    public static int Inspect(Options options)
    {
        var result = Inspect(options.RepoRoot, options.Project);
        SegregateAssetsProgram.Emit(options, result, () => RenderInspection(result));
        if (options.FailOnRisk && result.Classification == Classifier.RiskyGeneratedAssets)
            return (int)ExitCode.RiskyStaticAssets;
        return (int)ExitCode.Success;
    }

    public static async Task<int> PlanAsync(Options options)
    {
        var inspection = Inspect(options.RepoRoot, options.Project);
        ResolvedNuGetPackage? resolvedCuemonPackage = null;
        var canPlanPackageChanges = inspection.SelectedProject is not null &&
                                    inspection.Classification is not Classifier.RiskyGeneratedAssets and
                                        not Classifier.NotAWebApp and
                                        not Classifier.Ambiguous and
                                        not Classifier.NoWwwroot;
        if (canPlanPackageChanges && inspection.AssetAbstractions.Cuemon.PackageReference)
        {
            try
            {
                resolvedCuemonPackage = await NuGetVersionResolver.ResolveLatestStableAsync(
                    SegregateAssetsProgram.CuemonPackageId);
            }
            catch (NuGetResolutionException ex)
            {
                return SegregateAssetsProgram.Fail(
                    options,
                    ExitCode.DependencyResolutionFailed,
                    $"{ex.Message} No package version was planned; retry when NuGet.org is reachable.");
            }
        }

        var decisions = BuildPlan(inspection, options, resolvedCuemonPackage);
        var payload = new
        {
            tool = SegregateAssetsProgram.ToolName,
            repoRoot = inspection.RepoRoot,
            selectedProject = inspection.SelectedProject,
            classification = inspection.Classification,
            cdnEquivalent = options.CdnEquivalent,
            appPort = options.AppPort,
            cdnPort = options.CdnEquivalent ? options.CdnPort : (int?)null,
            originImage = SegregateAssetsProgram.OriginImage,
            resolvedNuGetPackages = resolvedCuemonPackage is null
                ? Array.Empty<ResolvedNuGetPackage>()
                : new[] { resolvedCuemonPackage },
            assetAbstractions = inspection.AssetAbstractions,
            decisions,
            recommendation = inspection.Recommendation,
        };
        SegregateAssetsProgram.Emit(options, payload, () => RenderPlan(inspection, options, decisions, resolvedCuemonPackage));
        return (int)ExitCode.Success;
    }

    public static int Verify(Options options)
    {
        var inspection = Inspect(options.RepoRoot, options.Project);
        var selected = inspection.SelectedProject;
        if (selected is null)
            return SegregateAssetsProgram.Fail(options, ExitCode.InspectionError,
                inspection.Classification == Classifier.Ambiguous
                    ? "Multiple web projects found; pass --project to choose one."
                    : "No web project resolved; pass --project.");

        var projectPath = Path.GetFullPath(Path.Combine(options.RepoRoot, selected));
        var sourceWwwroot = Path.Combine(Path.GetDirectoryName(projectPath)!, "wwwroot");
        var segregatedProfileName = LaunchProfileNaming.Resolve(projectPath);

        string? publishDir = options.PublishDir is not null ? Path.GetFullPath(options.PublishDir) : null;
        string? tempDir = null;
        try
        {
            if (publishDir is null && options.RunPublish)
            {
                tempDir = Path.Combine(Path.GetTempPath(), $"segregated-verify-{Guid.NewGuid():N}");
                Directory.CreateDirectory(tempDir);
                var (code, output) = RunDotnetPublish(projectPath, tempDir);
                if (code != 0)
                    return SegregateAssetsProgram.Fail(options, ExitCode.PublishError, $"dotnet publish failed (exit {code}).\n{output}");
                publishDir = tempDir;
            }

            if (publishDir is null)
                return SegregateAssetsProgram.Fail(options, ExitCode.InvalidArguments,
                    "verify needs an existing --publish-dir or --run-publish to produce one.");

            var leak = PublishLeakDetector.Detect(sourceWwwroot, publishDir);

            LaunchProfileValidator.Result? launch = null;
            ComposeValidator.Result? compose = null;
            ArtifactFirstValidator.Result? artifactFirst = null;
            string? composeFile = null;
            string? composeSelection = null;
            if (options.CheckLocal)
            {
                var rootLaunchSettings = Path.Combine(options.RepoRoot, "launchSettings.json");
                var projectLaunchSettings = Path.Combine(Path.GetDirectoryName(projectPath)!, "Properties", "launchSettings.json");
                var launchSettings = File.Exists(rootLaunchSettings) ? rootLaunchSettings : projectLaunchSettings;
                if (File.Exists(launchSettings))
                    launch = LaunchProfileValidator.Validate(File.ReadAllText(launchSettings), segregatedProfileName);

                var selection = ComposeFileSelector.Select(
                    options.RepoRoot,
                    projectPath,
                    inspection.WebProjects.Select(project => project.RelativePath));
                composeFile = selection.ComposeFile;
                if (composeFile is not null)
                {
                    var composeText = File.ReadAllText(composeFile);
                    compose = ComposeValidator.Validate(composeText);
                    artifactFirst = ArtifactFirstValidator.Validate(options.RepoRoot, projectPath, composeText);
                }
                else if (selection.BelongsToAnotherProject)
                {
                    composeSelection = $"Asset-origin Compose files exist but none reference '{selected}'; they belong to other web projects and were not used to verify this one.";
                }
            }

            var artifactFirstOk = artifactFirst is null ||
                                  (artifactFirst.DockerfilesColocated && artifactFirst.NoRootDockerfile &&
                                   artifactFirst.NoSourceCompilation && artifactFirst.HasDockerIgnore &&
                                   artifactFirst.ArtifactsReachable && artifactFirst.HasLocalPublishDirectory &&
                                   artifactFirst.HasGuardedPublishTarget && artifactFirst.CiPublishesArtifact &&
                                   artifactFirst.VisualStudioComposeComplete);
            var localOk = launch is not null &&
                          !launch.HasUnsafeProtocol && launch.IsHttp &&
                          compose is not null &&
                          (launch.HasHttpLocalOrigin || compose.HasHttpLocalOrigin) &&
                          (!launch.IsDockerCompose || compose.UsesLocalDevelopmentImage) &&
                          (!launch.IsDockerCompose || compose.HasVisualStudioProjectOptOut) &&
                          compose.UsesOriginImage && compose.HasAssetContent && !compose.HasUnsafeProtocol &&
                          compose.NonPrivileged && compose.NoDockerSocket && compose.NoObsoleteVersionKey &&
                          artifactFirstOk;
            var sourceReproducible = !inspection.RiskSignals.Any(signal => signal.Code == "ASSET_SOURCE_NOT_VERSIONED");
            var assetImageValidatedInCi = !inspection.RiskSignals.Any(signal => signal.Code == "ASSET_IMAGE_NOT_VALIDATED_IN_CI");
            var ok = leak.Passed && sourceReproducible && assetImageValidatedInCi && (!options.CheckLocal || localOk);

            var payload = new
            {
                tool = SegregateAssetsProgram.ToolName,
                ok,
                selectedProject = selected,
                publishInspected = publishDir,
                publishInvariant = leak.Passed ? "application-owned wwwroot is ABSENT from the publish artifact" : "application-owned wwwroot LEAKED into the publish artifact",
                sourceReproducible,
                assetImageValidatedInCi,
                leakedAppAssets = leak.LeakedAppAssets,
                preservedSharedAssets = leak.PreservedSharedAssets,
                launch,
                compose,
                composeFile,
                composeSelection,
                artifactFirst,
            };
            SegregateAssetsProgram.Emit(options, payload, () => RenderVerify(selected, publishDir!, leak, sourceReproducible, assetImageValidatedInCi, launch, compose, composeFile, composeSelection, artifactFirst, ok));
            return ok ? (int)ExitCode.Success : (int)ExitCode.VerificationFailed;
        }
        finally
        {
            if (tempDir is not null && Directory.Exists(tempDir))
            {
                try { Directory.Delete(tempDir, recursive: true); } catch { /* best effort */ }
            }
        }
    }

    private static (int Code, string Output) RunDotnetPublish(string projectPath, string outputDir)
    {
        var psi = new ProcessStartInfo("dotnet")
        {
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            UseShellExecute = false,
            WorkingDirectory = Path.GetDirectoryName(projectPath)!,
        };
        psi.ArgumentList.Add("publish");
        psi.ArgumentList.Add(projectPath);
        psi.ArgumentList.Add("-c");
        psi.ArgumentList.Add("Release");
        psi.ArgumentList.Add("-o");
        psi.ArgumentList.Add(outputDir);
        psi.ArgumentList.Add("--nologo");

        using var proc = Process.Start(psi)!;
        var stdout = proc.StandardOutput.ReadToEnd();
        var stderr = proc.StandardError.ReadToEnd();
        proc.WaitForExit();
        return (proc.ExitCode, stdout + stderr);
    }

    internal static List<object> BuildPlan(
        InspectionResult inspection,
        Options options,
        ResolvedNuGetPackage? resolvedCuemonPackage = null)
    {
        var e = inspection.ExistingSegregation;
        string StatusFor(bool present) => present ? "already-present" : "create";
        var projectPath = inspection.SelectedProject is null
            ? null
            : Path.GetFullPath(Path.Combine(inspection.RepoRoot, inspection.SelectedProject));
        var segregatedProfileName = projectPath is null
            ? "<ordinary-project-profile>.Assets"
            : LaunchProfileNaming.Resolve(projectPath);

        if (inspection.Classification == Classifier.RiskyGeneratedAssets)
        {
            return new List<object>
            {
                new { step = "escalate", status = "blocked", detail = "Risky or unreproducible Static Web Assets detected. Preserve the asset pipeline and establish a reproducible versioned or pinned input before proceeding." },
            };
        }
        if (inspection.Classification is Classifier.NotAWebApp or Classifier.Ambiguous)
        {
            return new List<object>
            {
                new { step = "resolve", status = "blocked", detail = inspection.Recommendation },
            };
        }
        if (inspection.Classification == Classifier.NoWwwroot)
        {
            return options.CdnEquivalent
                ? new List<object>
                {
                    new { step = "cdn-equivalent", status = "create", detail = $"Configure shared/CDN asset consumption and provision a local origin on host port {options.CdnPort} from its own shared-asset root." },
                }
                : new List<object>
                {
                    new { step = "resolve", status = "blocked", detail = inspection.Recommendation },
                };
        }

        var abstractionStatus = inspection.AssetAbstractions.CompetingAbstractions
            ? "migrate-and-remove"
            : inspection.AssetAbstractions.CuemonPresent
                ? "reuse-cuemon"
                : inspection.AssetAbstractions.Custom.Present
                    ? "reuse-existing"
                    : "introduce-only-if-needed";
        var abstractionDetail = inspection.AssetAbstractions.CompetingAbstractions
            ? "Cuemon App/CDN TagHelpers and a custom asset abstraction coexist. Migrate each Razor reference by ownership to app-link/app-script/app-img or cdn-link/cdn-script/cdn-img, remove redundant injections and registrations, and delete the custom abstraction only after no consumers remain. Configure AppTagHelperOptions.BaseUrlMode as TagHelperBaseUrlMode.Automatic and keep CdnTagHelperOptions explicitly Configured."
            : inspection.AssetAbstractions.CuemonPresent
                ? "Reuse the referenced Cuemon App/CDN TagHelpers, AppTagHelperOptions, and CdnTagHelperOptions. Use the current public custom-element syntax and BaseUrlMode API; do not invent an attribute or GetUrl abstraction."
                : inspection.AssetAbstractions.Custom.Present
                    ? "Reuse the existing non-Cuemon asset abstraction. Do not add Cuemon solely for this migration."
                    : "No suitable asset abstraction detected. Introduce only the smallest app-owned configuration mechanism required by the existing application.";

        var plan = new List<object>();
        if (resolvedCuemonPackage is not null)
        {
            plan.Add(new
            {
                step = "nuget-package-version",
                status = "update-or-confirm",
                detail = $"Use {resolvedCuemonPackage.PackageId} {resolvedCuemonPackage.Version}, resolved as the latest stable version from NuGet.org during this plan. Preserve the repository's package-management convention: update the existing PackageVersion when Central Package Management owns the version; otherwise update the existing PackageReference. Do not reuse a version from templates, fixtures, examples, or memory.",
            });
        }

        plan.AddRange(new object[]
        {
            new { step = "asset-abstraction", status = abstractionStatus, detail = abstractionDetail },
            new { step = "publish-exclusion", status = StatusFor(e.PublishExclusion), detail = "Add <Content Update=\"wwwroot/**\" CopyToPublishDirectory=\"Never\" /> to the web project for application-owned wwwroot content while preserving generated and contributed Static Web Assets." },
            new { step = "segregated-launch-profile", status = StatusFor(e.SegregatedLaunchProfile), detail = $"Keep the ordinary project profile unchanged and add the root '{segregatedProfileName}' DockerCompose profile for the full segregated topology. Derive the name by appending .Assets to the ordinary commandName Project profile. Put the host-only App BaseUrl localhost:{options.AppPort}, BaseUrlMode=Automatic, and Scheme=Http in the Compose web service environment." },
            new { step = "local-origin", status = StatusFor(e.ComposeService), detail = $"Provide {SegregateAssetsProgram.ComposeFileName}: build the web service directly with LocalDevelopment.Dockerfile and build the asset service directly with {SegregateAssetsProgram.DerivedDockerfileName}. Set com.microsoft.visual-studio.project-name: \"\" on the asset service so Visual Studio does not associate it with the web project or inject the web debugger bootstrap. Do not add a redundant project-level segregated profile or docker-compose.vs.release.yml." },
            new { step = "production-image", status = StatusFor(e.DerivedDockerfile), detail = $"Add {SegregateAssetsProgram.DerivedDockerfileName} (PascalCase <something>.Dockerfile) and select it with --file: FROM {SegregateAssetsProgram.OriginImage} + COPY --chown={SegregateAssetsProgram.OriginUser}:{SegregateAssetsProgram.OriginUser} ./wwwroot/ {SegregateAssetsProgram.OriginContentRoot}/." },
            new { step = "documentation", status = "create-or-update", detail = "Document that deployed static content is served by Codebelt Static Content Provider, and that wwwroot remains the authoring root." },
        });

        if (options.CdnEquivalent)
        {
            plan.Add(new { step = "cdn-equivalent", status = "create", detail = $"A CDN/shared equivalent exists: provision a second local origin on host port {options.CdnPort} from its own shared-asset root, configure CdnTagHelperOptions with BaseUrlMode = TagHelperBaseUrlMode.Configured and explicit Scheme = ProtocolUriScheme.Http locally, and never fall back to the application host or duplicate CDN assets into the application's wwwroot." });
        }
        else
        {
            plan.Add(new { step = "cdn-equivalent", status = "skip", detail = "No CDN/shared equivalent: configure only App-asset segregation and do not create CDN origin/configuration." });
        }

        return plan;
    }

    private static string RenderInspection(InspectionResult r)
    {
        var sb = new StringBuilder();
        sb.AppendLine($"Inspection: {r.RepoRoot}");
        sb.AppendLine($"Classification: {r.Classification}");
        sb.AppendLine($"Selected project: {r.SelectedProject ?? "(none)"}");
        sb.AppendLine($"Cuemon present: {r.CuemonPresent}");
        var cuemon = r.AssetAbstractions.Cuemon;
        sb.AppendLine($"Cuemon evidence: available={cuemon.Available} package={cuemon.PackageReference} project={cuemon.ProjectReference} using={cuemon.NamespaceUsing} app-options={cuemon.AppOptions} cdn-options={cuemon.CdnOptions} view-imports={cuemon.ViewImportsRegistration}");
        sb.AppendLine($"Cuemon markup: app-link={cuemon.AppLinkMarkup} app-script={cuemon.AppScriptMarkup} app-img={cuemon.AppImageMarkup} cdn-link={cuemon.CdnLinkMarkup} cdn-script={cuemon.CdnScriptMarkup} cdn-img={cuemon.CdnImageMarkup}");
        sb.AppendLine($"Custom asset abstraction: present={r.AssetAbstractions.Custom.Present} competing={r.AssetAbstractions.CompetingAbstractions} legacy-attribute-syntax={cuemon.LegacyAttributeSyntax} asp-append-version={cuemon.MicrosoftAppendVersion} ICacheBusting={cuemon.CuemonCacheBusting}");
        sb.AppendLine();
        sb.AppendLine($"Web projects ({r.WebProjects.Count}):");
        foreach (var p in r.WebProjects)
            sb.AppendLine($"  - {p.RelativePath} [sdk={p.Sdk}] wwwroot={p.HasWwwroot}");
        if (r.RiskSignals.Count > 0)
        {
            sb.AppendLine();
            sb.AppendLine("Risk signals (do NOT blindly exclude or package):");
            foreach (var s in r.RiskSignals) sb.AppendLine($"  ! {s.Code}: {s.Detail}");
        }
        var e = r.ExistingSegregation;
        sb.AppendLine();
        sb.AppendLine("Existing segregation:");
        sb.AppendLine($"  publish-exclusion={e.PublishExclusion} launch-profile={e.SegregatedLaunchProfile} compose={e.ComposeService} dockerfile={e.DerivedDockerfile} cuemon={e.CuemonAppOptions}");
        if (cuemon.Evidence.Count > 0)
            sb.AppendLine($"  Cuemon signals: {string.Join(", ", cuemon.Evidence)}");
        if (r.AssetAbstractions.Custom.Evidence.Count > 0)
            sb.AppendLine($"  custom signals: {string.Join(", ", r.AssetAbstractions.Custom.Evidence)}");
        sb.AppendLine();
        sb.AppendLine($"Recommendation: {r.Recommendation}");
        return sb.ToString().TrimEnd();
    }

    private static string RenderPlan(
        InspectionResult r,
        Options o,
        List<object> decisions,
        ResolvedNuGetPackage? resolvedCuemonPackage)
    {
        var sb = new StringBuilder();
        sb.AppendLine($"Plan for {r.SelectedProject ?? "(unresolved)"} [{r.Classification}]");
        sb.AppendLine($"App origin port: {o.AppPort}" + (o.CdnEquivalent ? $"  CDN origin port: {o.CdnPort}" : "  (no CDN equivalent)"));
        if (resolvedCuemonPackage is not null)
            sb.AppendLine($"NuGet: {resolvedCuemonPackage.PackageId} {resolvedCuemonPackage.Version} ({resolvedCuemonPackage.Policy})");
        sb.AppendLine();
        foreach (var d in decisions)
        {
            var json = JsonSerializer.Serialize(d, SegregateAssetsProgram.JsonOut);
            using var doc = JsonDocument.Parse(json);
            var step = doc.RootElement.GetProperty("step").GetString();
            var status = doc.RootElement.GetProperty("status").GetString();
            var detail = doc.RootElement.GetProperty("detail").GetString();
            sb.AppendLine($"  [{status}] {step}: {detail}");
        }
        return sb.ToString().TrimEnd();
    }

    private static string RenderVerify(string project, string publishDir, PublishLeakDetector.Result leak, bool sourceReproducible, bool assetImageValidatedInCi,
        LaunchProfileValidator.Result? launch, ComposeValidator.Result? compose, string? composeFile, string? composeSelection,
        ArtifactFirstValidator.Result? artifactFirst, bool ok)
    {
        var sb = new StringBuilder();
        sb.AppendLine($"Verify: {project}");
        sb.AppendLine($"Publish inspected: {publishDir}");
        sb.AppendLine(leak.Passed
            ? "PASS  application-owned wwwroot is ABSENT from the publish artifact."
            : "FAIL  application-owned wwwroot LEAKED into the publish artifact:");
        foreach (var f in leak.LeakedAppAssets) sb.AppendLine($"    leaked: {f}");
        sb.AppendLine(sourceReproducible
            ? "PASS  asset-image source is reproducible from Git-tracked input."
            : "FAIL  asset-image source is ignored or wholly untracked; a clean checkout cannot reproduce it.");
        sb.AppendLine(assetImageValidatedInCi
            ? "PASS  repository CI does not omit Assets.Dockerfile from its container-image build surface."
            : "FAIL  repository CI builds container images but does not build or validate Assets.Dockerfile.");
        if (leak.PreservedSharedAssets.Count > 0)
            sb.AppendLine($"  preserved shared/framework assets: {leak.PreservedSharedAssets.Count} (e.g. {leak.PreservedSharedAssets[0]})");
        if (launch is not null)
        {
            sb.AppendLine();
            sb.AppendLine($"Local launch profile: exists={launch.ProfileExists} dockerCompose={launch.IsDockerCompose} http={launch.IsHttp} httpLocalOrigin={launch.HasHttpLocalOrigin} unsafeProtocol={launch.HasUnsafeProtocol}");
            foreach (var f in launch.Findings) sb.AppendLine($"    - {f}");
        }
        if (composeSelection is not null)
        {
            sb.AppendLine();
            sb.AppendLine($"Local origin compose: none for this project.");
            sb.AppendLine($"    - {composeSelection}");
        }
        if (compose is not null)
        {
            if (composeFile is not null) sb.AppendLine($"Local origin compose file: {composeFile}");
            sb.AppendLine($"Local origin compose: originImage={compose.UsesOriginImage} assetContent={compose.HasAssetContent} localDevelopmentImage={compose.UsesLocalDevelopmentImage} vsProjectOptOut={compose.HasVisualStudioProjectOptOut} httpLocalOrigin={compose.HasHttpLocalOrigin} unsafeProtocol={compose.HasUnsafeProtocol} roRootFs={compose.ReadOnlyRootFs} nonPrivileged={compose.NonPrivileged} noDockerSocket={compose.NoDockerSocket} noVersionKey={compose.NoObsoleteVersionKey}");
            foreach (var f in compose.Findings) sb.AppendLine($"    - {f}");
        }
        if (artifactFirst is not null)
        {
            sb.AppendLine($"Artifact-first topology: colocated={artifactFirst.DockerfilesColocated} noRootDockerfile={artifactFirst.NoRootDockerfile} noSourceCompilation={artifactFirst.NoSourceCompilation} dockerIgnore={artifactFirst.HasDockerIgnore} artifactsReachable={artifactFirst.ArtifactsReachable} localPublishDirectory={artifactFirst.HasLocalPublishDirectory} guardedPublishTarget={artifactFirst.HasGuardedPublishTarget} ciPublishesArtifact={artifactFirst.CiPublishesArtifact} vsComposeComplete={artifactFirst.VisualStudioComposeComplete}");
            foreach (var f in artifactFirst.Findings) sb.AppendLine($"    - {f}");
        }
        sb.AppendLine();
        sb.AppendLine(ok ? "RESULT: PASS" : "RESULT: FAIL");
        return sb.ToString().TrimEnd();
    }
}

// ---------------------------------------------------------------------------
// Self-test — hermetic; creates synthetic fixtures in a temp directory and asserts
// the deterministic detectors. Requires no dotnet build, no Docker, and no network.
// ---------------------------------------------------------------------------

internal static class SelfTest
{
    private static int _passed;
    private static readonly List<string> _failures = new();

    public static async Task<int> RunAsync(Options options)
    {
        var root = Path.Combine(Path.GetTempPath(), $"segregated-selftest-{Guid.NewGuid():N}");
        Directory.CreateDirectory(root);
        try
        {
            TestWebSdkDetection();
            await TestNuGetVersionResolverSelectsLatestStable(root);
            TestSimpleWebAppClassification(root);
            TestCuemonAndCompetingAbstractionDetection(root);
            TestCentralPackageDefinitionDoesNotImplyCuemonUsage(root);
            TestBlazorWebAssemblyIsRisky(root);
            TestRazorClassLibraryIsRisky(root);
            TestScopedCssIsRisky(root);
            TestFrontendBuildIsRisky(root);
            TestAmbiguousMultiProject(root);
            TestNoWwwroot(root);
            TestLaunchProfileNaming(root);
            TestIdempotencyDetection(root);
            TestAlreadySegregatedClassification(root);
            TestAlreadySegregatedRiskIsRisky(root);
            TestLaunchProfileValidatorSafe();
            TestLaunchProfileValidatorRejectsHostOnlyWithoutScheme();
            TestLaunchProfileValidatorRejectsProtocolRelative();
            TestLaunchProfileValidatorRejectsHttpsLocal();
            TestComposeValidatorSafe();
            TestComposeValidatorRejectsPrivilegedAndSocket();
            TestComposeValidatorAcceptsHttpLocalhostOrigin();
            TestComposeValidatorRejectsObsoleteVersionKey();
            TestArtifactFirstValidatorAcceptsCanonicalLayout(root);
            TestArtifactFirstValidatorRejectsRootDockerfiles(root);
            TestArtifactFirstValidatorRejectsSourceCompilingDockerfile(root);
            TestArtifactFirstValidatorSkipsWhenNoApplicationImage(root);
            TestArtifactFirstValidatorRequiresCiArtifactProducer(root);
            TestComposeFileSelectorCorrelatesToSelectedProject(root);
            TestComposeFileSelectorAcceptsUnambiguousLayouts(root);
            TestPublishLeakDetected();
            TestPublishLeakCleanWithPreservedSharedAssets();
        }
        finally
        {
            try { Directory.Delete(root, recursive: true); } catch { /* best effort */ }
        }

        var total = _passed + _failures.Count;
        if (options.Json)
        {
            Console.WriteLine(JsonSerializer.Serialize(new
            {
                tool = SegregateAssetsProgram.ToolName,
                ok = _failures.Count == 0,
                passed = _passed,
                failed = _failures.Count,
                total,
                failures = _failures,
            }, SegregateAssetsProgram.JsonOut));
        }
        else
        {
            foreach (var f in _failures) Console.Error.WriteLine($"FAIL: {f}");
            Console.WriteLine($"{SegregateAssetsProgram.ToolName} self-test: {_passed}/{total} passed.");
        }
        return _failures.Count == 0 ? (int)ExitCode.Success : (int)ExitCode.SelfTestFailed;
    }

    private static void TestWebSdkDetection()
    {
        Assert("web SDK detected", ProjectScanner.IsWebSdk(ProjectScanner.ReadSdk("<Project Sdk=\"Microsoft.NET.Sdk.Web\">")));
        Assert("class-library SDK not web", !ProjectScanner.IsWebSdk(ProjectScanner.ReadSdk("<Project Sdk=\"Microsoft.NET.Sdk\">")));
        Assert("razor SDK not web", !ProjectScanner.IsWebSdk(ProjectScanner.ReadSdk("<Project Sdk=\"Microsoft.NET.Sdk.Razor\">")));
    }

    private static async Task TestNuGetVersionResolverSelectsLatestStable(string root)
    {
        var serviceIndexUri = new Uri("https://unit.test/v3/index.json");
        var packageIndexUri = "https://unit.test/v3-flatcontainer/cuemon.aspnetcore.razor.taghelpers/index.json";
        using var client = new HttpClient(new StaticJsonHandler(new Dictionary<string, string>
        {
            [serviceIndexUri.AbsoluteUri] = """
            {
              "resources": [
                {
                  "@id": "https://unit.test/v3-flatcontainer/",
                  "@type": "PackageBaseAddress/3.0.0"
                }
              ]
            }
            """,
            [packageIndexUri] = """
            {
              "versions": [
                "99.0.0-preview.1",
                "6.1.0",
                "42.3.7",
                "42.3.7-rc.1"
              ]
            }
            """,
        }));

        var resolved = await NuGetVersionResolver.ResolveLatestStableAsync(
            SegregateAssetsProgram.CuemonPackageId,
            client,
            serviceIndexUri);
        Assert("nuget: latest stable selected instead of stale or prerelease", resolved.Version == "42.3.7");
        Assert("nuget: stable policy reported", resolved.Policy == NuGetVersionResolver.LatestStablePolicy);
        Assert("nuget: package index source reported", resolved.Source == packageIndexUri);

        var dir = NewProject(root, "nuget-plan", webApp: true, wwwroot: true,
            extraCsproj: $"<ItemGroup><PackageReference Include=\"{SegregateAssetsProgram.CuemonPackageId}\" /></ItemGroup>");
        File.WriteAllText(Path.Combine(dir, "Directory.Packages.props"), $"""
        <Project>
          <PropertyGroup><ManagePackageVersionsCentrally>true</ManagePackageVersionsCentrally></PropertyGroup>
          <ItemGroup><PackageVersion Include="{SegregateAssetsProgram.CuemonPackageId}" Version="6.1.0" /></ItemGroup>
        </Project>
        """);
        var inspection = Commands.Inspect(dir, null);
        var decisions = Commands.BuildPlan(inspection, new Options(), resolved);
        var planJson = JsonSerializer.Serialize(decisions, SegregateAssetsProgram.JsonOut);
        Assert("nuget: plan includes resolved package-version step", planJson.Contains("nuget-package-version", StringComparison.Ordinal));
        Assert("nuget: plan emits latest stable version", planJson.Contains("42.3.7", StringComparison.Ordinal));
        Assert("nuget: plan preserves Central Package Management", planJson.Contains("Central Package Management", StringComparison.Ordinal));
    }

    private static void TestSimpleWebAppClassification(string root)
    {
        var dir = NewProject(root, "simple", webApp: true, wwwroot: true);
        var inspection = Commands.Inspect(dir, null);
        Assert("simple: classified Simple", inspection.Classification == Classifier.Simple);
        Assert("simple: no risk signals", inspection.RiskSignals.Count == 0);
        Assert("simple: selected resolved", inspection.SelectedProject is not null);
    }

    private static void TestCuemonAndCompetingAbstractionDetection(string root)
    {
        var dir = NewProject(root, "cuemon", webApp: true, wwwroot: true,
            extraCsproj: "<ItemGroup><PackageReference Include=\"Cuemon.AspNetCore.Razor.TagHelpers\" Version=\"1.0.0\" /></ItemGroup>");
        var views = Path.Combine(dir, "Views", "Shared");
        Directory.CreateDirectory(views);
        File.WriteAllText(Path.Combine(dir, "Program.cs"), """
        using Cuemon.AspNetCore.Razor.TagHelpers;
        var builder = WebApplication.CreateBuilder(args);
        builder.Services.Configure<AppTagHelperOptions>(builder.Configuration.GetSection("App"));
        builder.Services.Configure<CdnTagHelperOptions>(builder.Configuration.GetSection("Cdn"));
        builder.Services.AddAssemblyCacheBusting();
        builder.Services.Configure<AppAssetOptions>(builder.Configuration.GetSection("Assets"));
        """);
        File.WriteAllText(Path.Combine(dir, "AppAssetOptions.cs"), """
        public sealed class AppAssetOptions
        {
            public string GetUrl(string path) => path;
        }
        """);
        File.WriteAllText(Path.Combine(dir, "Views", "_ViewImports.cshtml"), "@addTagHelper *, Cuemon.AspNetCore.Razor.TagHelpers");
        File.WriteAllText(Path.Combine(views, "_Layout.cshtml"), """
        @inject Microsoft.Extensions.Options.IOptions<AppAssetOptions> AppAssets
        <app-link href="css/site.css" />
        <app-script src="js/site.js"></app-script>
        <app-img src="images/logo.svg" alt="Logo" />
        <cdn-link href="packages/bootstrap/5.3.3/css/bootstrap.min.css" />
        <cdn-script src="packages/htmx/2.0.4/htmx.min.js"></cdn-script>
        <cdn-img src="packages/icons/logo.svg" alt="Shared logo" />
        <link app-href="legacy.css" />
        @AppAssets.Value.GetUrl("~/css/site.css")
        """);

        var csproj = Directory.GetFiles(dir, "*.csproj").Single();
        var inspection = Commands.Inspect(dir, null);
        var c = inspection.AssetAbstractions.Cuemon;
        var custom = inspection.AssetAbstractions.Custom;
        Assert("cuemon: package reference detected", c.PackageReference);
        Assert("cuemon: namespace using detected", c.NamespaceUsing);
        Assert("cuemon: AppTagHelperOptions detected", c.AppOptions);
        Assert("cuemon: CdnTagHelperOptions detected", c.CdnOptions);
        Assert("cuemon: _ViewImports registration detected", c.ViewImportsRegistration);
        Assert("cuemon: app-link detected", c.AppLinkMarkup);
        Assert("cuemon: app-script detected", c.AppScriptMarkup);
        Assert("cuemon: app-img detected", c.AppImageMarkup);
        Assert("cuemon: cdn-link detected", c.CdnLinkMarkup);
        Assert("cuemon: cdn-script detected", c.CdnScriptMarkup);
        Assert("cuemon: cdn-img detected", c.CdnImageMarkup);
        Assert("cuemon: legacy attribute syntax reported", c.LegacyAttributeSyntax);
        Assert("cuemon: cache-busting registration detected", c.CuemonCacheBusting);
        Assert("cuemon: custom options detected", custom.OptionsType);
        Assert("cuemon: custom GetUrl detected", custom.UrlCalls);
        Assert("cuemon: competing abstractions detected", inspection.AssetAbstractions.CompetingAbstractions);
        Assert("cuemon: existing options do not imply segregation", !inspection.ExistingSegregation.Any);
        Assert("cuemon: recommendation reports migration", inspection.Recommendation.Contains("competing", StringComparison.OrdinalIgnoreCase));
        Assert("cuemon: project remains readable", File.Exists(csproj));
    }

    private static void TestCentralPackageDefinitionDoesNotImplyCuemonUsage(string root)
    {
        var dir = NewProject(root, "central-package-only", webApp: true, wwwroot: true);
        File.WriteAllText(Path.Combine(dir, "Directory.Packages.props"), """
        <Project>
          <ItemGroup>
            <PackageVersion Include="Cuemon.AspNetCore.Razor.TagHelpers" Version="1.0.0" />
          </ItemGroup>
        </Project>
        """);
        var inspection = Commands.Inspect(dir, null);
        Assert("cuemon: central package definition without PackageReference is not usage", !inspection.CuemonPresent);

        var markupOnly = NewProject(root, "markup-only", webApp: true, wwwroot: true);
        var views = Path.Combine(markupOnly, "Views", "Shared");
        Directory.CreateDirectory(views);
        File.WriteAllText(Path.Combine(views, "_Layout.cshtml"), "<app-link href=\"css/site.css\" />");
        var markupInspection = Commands.Inspect(markupOnly, null);
        Assert("cuemon: markup is reported without proving package availability", markupInspection.AssetAbstractions.Cuemon.AppLinkMarkup && !markupInspection.CuemonPresent);

        var inferredImageAliases = NewProject(root, "inferred-image-aliases", webApp: true, wwwroot: true);
        var aliasViews = Path.Combine(inferredImageAliases, "Views", "Shared");
        Directory.CreateDirectory(aliasViews);
        File.WriteAllText(Path.Combine(aliasViews, "_Layout.cshtml"), "<app-image src=\"logo.svg\" /><cdn-image src=\"shared.svg\" />");
        var aliasInspection = Commands.Inspect(inferredImageAliases, null).AssetAbstractions.Cuemon;
        Assert("cuemon: class-name-inferred image aliases are not reported as public selectors", !aliasInspection.AppImageMarkup && !aliasInspection.CdnImageMarkup);
    }

    private static void TestBlazorWebAssemblyIsRisky(string root)
    {
        var dir = NewProject(root, "blazorwasm", webApp: true, wwwroot: true, extraCsproj:
            "<ItemGroup><PackageReference Include=\"Microsoft.AspNetCore.Components.WebAssembly\" Version=\"10.0.0\" /></ItemGroup>");
        var inspection = Commands.Inspect(dir, null);
        Assert("blazor-wasm: risky classification", inspection.Classification == Classifier.RiskyGeneratedAssets);
        Assert("blazor-wasm: has BLAZOR_WEBASSEMBLY", inspection.RiskSignals.Any(s => s.Code == "BLAZOR_WEBASSEMBLY"));
    }

    private static void TestRazorClassLibraryIsRisky(string root)
    {
        var appDir = NewProject(root, "rcl-app", webApp: true, wwwroot: true);
        var libDir = NewProject(root, "rcl-lib", webApp: false, wwwroot: true, sdk: "Microsoft.NET.Sdk.Razor");
        var appCsproj = Directory.GetFiles(appDir, "*.csproj").First();
        var libCsproj = Directory.GetFiles(libDir, "*.csproj").First();
        var rel = Path.GetRelativePath(appDir, libCsproj);
        File.WriteAllText(appCsproj, $"""
        <Project Sdk="Microsoft.NET.Sdk.Web">
          <PropertyGroup><TargetFramework>net10.0</TargetFramework></PropertyGroup>
          <ItemGroup><ProjectReference Include="{rel}" /></ItemGroup>
        </Project>
        """);
        var risks = StaticWebAssetRiskDetector.Detect(appCsproj, root);
        Assert("rcl: RAZOR_CLASS_LIBRARY_ASSETS detected", risks.Any(s => s.Code == "RAZOR_CLASS_LIBRARY_ASSETS"));
    }

    private static void TestScopedCssIsRisky(string root)
    {
        var dir = NewProject(root, "scopedcss", webApp: true, wwwroot: true);
        File.WriteAllText(Path.Combine(dir, "Index.cshtml.css"), "h1{color:red}");
        var csproj = Directory.GetFiles(dir, "*.csproj").First();
        var risks = StaticWebAssetRiskDetector.Detect(csproj, root);
        Assert("scoped-css: SCOPED_CSS detected", risks.Any(s => s.Code == "SCOPED_CSS"));
    }

    private static void TestFrontendBuildIsRisky(string root)
    {
        var dir = NewProject(root, "frontend", webApp: true, wwwroot: true);
        File.WriteAllText(Path.Combine(dir, "package.json"),
            "{ \"scripts\": { \"build\": \"vite build\" }, \"devDependencies\": { \"vite\": \"^5.0.0\" } }");
        var csproj = Directory.GetFiles(dir, "*.csproj").First();
        var risks = StaticWebAssetRiskDetector.Detect(csproj, root);
        Assert("frontend: FRONTEND_BUILD_PIPELINE detected", risks.Any(s => s.Code == "FRONTEND_BUILD_PIPELINE"));
    }

    private static void TestAmbiguousMultiProject(string root)
    {
        var multiRoot = Path.Combine(root, "multi");
        Directory.CreateDirectory(multiRoot);
        NewProject(multiRoot, "web-a", webApp: true, wwwroot: true);
        NewProject(multiRoot, "web-b", webApp: true, wwwroot: true);
        var inspection = Commands.Inspect(multiRoot, null);
        Assert("multi: ambiguous without --project", inspection.Classification == Classifier.Ambiguous);
        Assert("multi: two web projects", inspection.WebProjects.Count == 2);
        var chosen = Commands.Inspect(multiRoot, inspection.WebProjects[0].RelativePath);
        Assert("multi: resolves with --project", chosen.SelectedProject is not null && chosen.Classification == Classifier.Simple);
    }

    private static void TestNoWwwroot(string root)
    {
        var dir = NewProject(root, "nowwwroot", webApp: true, wwwroot: false);
        var inspection = Commands.Inspect(dir, null);
        Assert("no-wwwroot: classified NoWwwroot", inspection.Classification == Classifier.NoWwwroot);
    }

    private static void TestLaunchProfileNaming(string root)
    {
        var dir = NewProject(root, "named-profile", webApp: true, wwwroot: true);
        var properties = Path.Combine(dir, "Properties");
        Directory.CreateDirectory(properties);
        File.WriteAllText(Path.Combine(properties, "launchSettings.json"), """
        { "profiles": { "Friendly.Web": { "commandName": "Project" } } }
        """);
        var project = Directory.GetFiles(dir, "*.csproj").Single();
        Assert("profile-name: follows ordinary Project profile", LaunchProfileNaming.Resolve(project) == "Friendly.Web.Assets");
    }

    private static void TestIdempotencyDetection(string root)
    {
        var dir = NewProject(root, "idem", webApp: true, wwwroot: true);
        var csproj = Directory.GetFiles(dir, "*.csproj").First();
        File.WriteAllText(csproj, """
        <Project Sdk="Microsoft.NET.Sdk.Web">
          <PropertyGroup><TargetFramework>net10.0</TargetFramework></PropertyGroup>
          <ItemGroup>
            <Content Update="wwwroot/**" CopyToPublishDirectory="Never" />
          </ItemGroup>
        </Project>
        """);
        File.WriteAllText(Path.Combine(dir, "launchSettings.json"), """
        { "profiles": { "idem.Assets": { "commandName": "DockerCompose" } } }
        """);
        File.WriteAllText(Path.Combine(dir, SegregateAssetsProgram.ComposeFileName),
            "services:\n  web-app:\n    build:\n      dockerfile: LocalDevelopment.Dockerfile\n  app-assets:\n    build:\n      dockerfile: Assets.Dockerfile\n");
        File.WriteAllText(Path.Combine(dir, SegregateAssetsProgram.DerivedDockerfileName),
            "FROM codebeltnet/web-cdn-origin:2.0.0\nCOPY --chown=65532:65532 ./wwwroot/ /cdnroot/\n");
        var existing = IdempotencyDetector.Detect(csproj, dir);
        Assert("idem: publish exclusion present", existing.PublishExclusion);
        Assert("idem: launch profile present", existing.SegregatedLaunchProfile);
        Assert("idem: compose service present", existing.ComposeService);
        Assert("idem: derived dockerfile present", existing.DerivedDockerfile);
    }

    private static void TestAlreadySegregatedClassification(string root)
    {
        var dir = NewProject(root, "done", webApp: true, wwwroot: true);
        var csproj = Directory.GetFiles(dir, "*.csproj").First();
        File.WriteAllText(csproj, """
        <Project Sdk="Microsoft.NET.Sdk.Web">
          <PropertyGroup><TargetFramework>net10.0</TargetFramework></PropertyGroup>
          <ItemGroup><Content Update="wwwroot/**" CopyToPublishDirectory="Never" /></ItemGroup>
        </Project>
        """);
        File.WriteAllText(Path.Combine(dir, "launchSettings.json"),
            "{ \"profiles\": { \"done.Assets\": { \"commandName\": \"DockerCompose\" } } }");
        var inspection = Commands.Inspect(dir, null);
        Assert("already: classified AlreadySegregated", inspection.Classification == Classifier.AlreadySegregated);
    }

    private static void TestAlreadySegregatedRiskIsRisky(string root)
    {
        var dir = NewProject(root, "done-risky", webApp: true, wwwroot: true);
        var csproj = Directory.GetFiles(dir, "*.csproj").First();
        File.WriteAllText(csproj, """
        <Project Sdk="Microsoft.NET.Sdk.Web">
          <PropertyGroup><TargetFramework>net10.0</TargetFramework></PropertyGroup>
          <ItemGroup><Content Update="wwwroot/**" CopyToPublishDirectory="Never" /></ItemGroup>
        </Project>
        """);
        File.WriteAllText(Path.Combine(dir, "launchSettings.json"),
            "{ \"profiles\": { \"done-risky.Assets\": { \"commandName\": \"DockerCompose\" } } }");
        File.WriteAllText(Path.Combine(dir, "Index.cshtml.css"), "h1{color:red}");

        var inspection = Commands.Inspect(dir, null);
        Assert("already-risky: existing segregation is complete", inspection.ExistingSegregation.Complete);
        Assert("already-risky: risk takes precedence", inspection.Classification == Classifier.RiskyGeneratedAssets);
    }

    private static void TestLaunchProfileValidatorSafe()
    {
        var json = """
        { "profiles": { "Contoso.Web.Assets": {
            "commandName": "DockerCompose",
            "composeLaunchUrl": "http://localhost:5080"
          } } }
        """;
        var r = LaunchProfileValidator.Validate(json, "Contoso.Web.Assets");
        Assert("launch-safe: profile exists", r.ProfileExists);
        Assert("launch-safe: docker compose", r.IsDockerCompose);
        Assert("launch-safe: http", r.IsHttp);
        Assert("launch-safe: origin belongs to compose", !r.HasHttpLocalOrigin);
        Assert("launch-safe: no unsafe protocol", !r.HasUnsafeProtocol);
    }

    private static void TestLaunchProfileValidatorRejectsHostOnlyWithoutScheme()
    {
        var json = """
        { "profiles": { "Contoso.Web.Assets": {
            "commandName": "Project",
            "applicationUrl": "http://localhost:5080",
            "environmentVariables": { "SegregatedAssets__App__BaseUrl": "localhost:8080" }
          } } }
        """;
        var r = LaunchProfileValidator.Validate(json, "Contoso.Web.Assets");
        Assert("launch-hostonly-noscheme: local origin not proven", !r.HasHttpLocalOrigin);
    }

    private static void TestLaunchProfileValidatorRejectsProtocolRelative()
    {
        var json = """
        { "profiles": { "Contoso.Web.Assets": {
            "applicationUrl": "http://localhost:5080",
            "environmentVariables": { "SegregatedAssets__App__BaseUrl": "//localhost:8080" }
          } } }
        """;
        var r = LaunchProfileValidator.Validate(json, "Contoso.Web.Assets");
        Assert("launch-protorel: flagged unsafe", r.HasUnsafeProtocol);
    }

    private static void TestLaunchProfileValidatorRejectsHttpsLocal()
    {
        var json = """
        { "profiles": { "Contoso.Web.Assets": {
            "applicationUrl": "https://localhost:5443",
            "environmentVariables": { "SegregatedAssets__App__BaseUrl": "https://localhost:8080" }
          } } }
        """;
        var r = LaunchProfileValidator.Validate(json, "Contoso.Web.Assets");
        Assert("launch-httpslocal: not http", !r.IsHttp);
        Assert("launch-httpslocal: flagged unsafe", r.HasUnsafeProtocol);
    }

    private static void TestComposeValidatorSafe()
    {
        var compose = """
        services:
          web-app:
            build:
              dockerfile: src/Web/LocalDevelopment.Dockerfile
            environment:
              SegregatedAssets__App__BaseUrl: localhost:8080
              SegregatedAssets__App__Scheme: Http
          app-assets:
            build:
              context: ./src/Web
              dockerfile: Assets.Dockerfile
            labels:
              com.microsoft.visual-studio.project-name: ""
            read_only: true
            cap_drop: [ALL]
            ports: ["8080:8080"]
        """;
        var r = ComposeValidator.Validate(compose);
        Assert("compose-safe: origin image", r.UsesOriginImage);
        Assert("compose-safe: asset content", r.HasAssetContent);
        Assert("compose-safe: local development image", r.UsesLocalDevelopmentImage);
        Assert("compose-safe: Visual Studio project opt-out", r.HasVisualStudioProjectOptOut);
        Assert("compose-safe: http local origin", r.HasHttpLocalOrigin);
        Assert("compose-safe: safe protocol", !r.HasUnsafeProtocol);
        Assert("compose-safe: read-only rootfs", r.ReadOnlyRootFs);
        Assert("compose-safe: non-privileged", r.NonPrivileged);
        Assert("compose-safe: no docker socket", r.NoDockerSocket);
    }

    private static void TestComposeValidatorRejectsPrivilegedAndSocket()
    {
        var compose = """
        services:
          app-assets:
            image: codebeltnet/web-cdn-origin:2.0.0
            privileged: true
            volumes:
              - ./src/Web/wwwroot:/cdnroot:ro
              - /var/run/docker.sock:/var/run/docker.sock
        """;
        var r = ComposeValidator.Validate(compose);
        Assert("compose-bad: missing Visual Studio project opt-out flagged", !r.HasVisualStudioProjectOptOut);
        Assert("compose-bad: privileged flagged", !r.NonPrivileged);
        Assert("compose-bad: docker socket flagged", !r.NoDockerSocket);
    }

    // Regression: http://localhost:<port> is the canonical safe local origin and must never be
    // mistaken for the protocol-relative //localhost form.
    private static void TestComposeValidatorAcceptsHttpLocalhostOrigin()
    {
        var compose = """
        services:
          web-app:
            build:
              dockerfile: src/Web/LocalDevelopment.Dockerfile
            environment:
              SegregatedAssets__App__BaseUrl: http://localhost:8080
          app-assets:
            build:
              context: ./src/Web
              dockerfile: Assets.Dockerfile
            labels:
              com.microsoft.visual-studio.project-name: ""
        """;
        var r = ComposeValidator.Validate(compose);
        Assert("compose-http-origin: http local origin accepted", r.HasHttpLocalOrigin);
        Assert("compose-http-origin: not flagged unsafe", !r.HasUnsafeProtocol);
        Assert("compose-http-origin: protocol-relative still flagged",
            ComposeValidator.Validate(compose.Replace("http://localhost:8080", "//localhost:8080")).HasUnsafeProtocol);
    }

    private static void TestComposeValidatorRejectsObsoleteVersionKey()
    {
        var compose = """
        version: '3.8'
        services:
          app-assets:
            image: codebeltnet/web-cdn-origin:2.0.0
        """;
        var r = ComposeValidator.Validate(compose);
        Assert("compose-version-key: obsolete version flagged", !r.NoObsoleteVersionKey);
    }

    private static string NewArtifactFirstRepo(string root, string name, bool colocated, string? dockerfileOverride = null)
    {
        var repo = Path.Combine(root, name);
        var projectDir = Path.Combine(repo, "src", "Web");
        Directory.CreateDirectory(projectDir);
        File.WriteAllText(Path.Combine(projectDir, "Web.csproj"), """
        <Project Sdk="Microsoft.NET.Sdk.Web">
          <PropertyGroup>
            <TargetFramework>net10.0</TargetFramework>
            <LocalPublishDirectory>artifacts\publish\</LocalPublishDirectory>
            <DockerComposeProjectPath>..\..\docker-compose.dcproj</DockerComposeProjectPath>
          </PropertyGroup>
        </Project>
        """);

        var dockerfileHome = colocated ? projectDir : repo;
        File.WriteAllText(Path.Combine(dockerfileHome, "Dockerfile"), dockerfileOverride ?? """
        FROM dhi.io/aspnetcore:10-alpine3.23
        WORKDIR /app
        COPY --chown=65532:65532 artifacts/publish/ .
        ENTRYPOINT ["dotnet", "Web.dll"]
        """);
        File.WriteAllText(Path.Combine(dockerfileHome, "LocalDevelopment.Dockerfile"), """
        FROM dhi.io/aspnetcore:10-alpine3.23-dev
        WORKDIR /app
        COPY --chown=65532:65532 artifacts/publish/ .
        USER 65532
        ENTRYPOINT ["dotnet", "Web.dll"]
        """);
        File.WriteAllText(Path.Combine(dockerfileHome, "Assets.Dockerfile"),
            "FROM codebeltnet/web-cdn-origin:2.0.0\nCOPY --chown=65532:65532 ./wwwroot/ /cdnroot/\n");

        File.WriteAllText(Path.Combine(repo, ".dockerignore"), ".git\n**/bin\n**/obj\n");
        File.WriteAllText(Path.Combine(repo, "Directory.Build.targets"), """
        <Project>
          <Target Name="PublishRunnerArtifacts" AfterTargets="Build" Condition="'$(CI)' != 'true' and '$(DesignTimeBuild)' != 'true' and '$(LocalPublishDirectory)' != ''">
            <MSBuild Projects="$(MSBuildProjectFullPath)" Targets="Publish" Properties="PublishDir=$(LocalPublishDirectory)" />
          </Target>
        </Project>
        """);
        File.WriteAllText(Path.Combine(repo, "docker-compose.dcproj"), """
        <Project Sdk="Microsoft.Docker.Sdk">
          <PropertyGroup Label="Globals">
            <DockerComposeBaseFilePath>compose.assets</DockerComposeBaseFilePath>
          </PropertyGroup>
        </Project>
        """);
        File.WriteAllText(Path.Combine(repo, "launchSettings.json"),
            "{ \"profiles\": { \"Web.Assets\": { \"commandName\": \"DockerCompose\" } } }");

        var workflows = Path.Combine(repo, ".github", "workflows");
        Directory.CreateDirectory(workflows);
        File.WriteAllText(Path.Combine(workflows, "ci-pipeline.yml"),
            "jobs:\n  publish:\n    steps:\n      - run: dotnet publish src/Web/Web.csproj --output artifacts/publish\n");

        return repo;
    }

    private static string ArtifactFirstCompose(string projectDirectory) => $"""
        services:
          web-app:
            build:
              context: .
              dockerfile: {projectDirectory}/LocalDevelopment.Dockerfile
          app-assets:
            build:
              context: ./{projectDirectory}
              dockerfile: Assets.Dockerfile
        """;

    private static void TestArtifactFirstValidatorAcceptsCanonicalLayout(string root)
    {
        var repo = NewArtifactFirstRepo(root, "artifact-ok", colocated: true);
        var r = ArtifactFirstValidator.Validate(repo, Path.Combine(repo, "src", "Web", "Web.csproj"), ArtifactFirstCompose("src/Web"));
        Assert("artifact-ok: dockerfiles colocated", r.DockerfilesColocated);
        Assert("artifact-ok: no root dockerfile", r.NoRootDockerfile);
        Assert("artifact-ok: no source compilation", r.NoSourceCompilation);
        Assert("artifact-ok: dockerignore present", r.HasDockerIgnore);
        Assert("artifact-ok: artifacts reachable", r.ArtifactsReachable);
        Assert("artifact-ok: LocalPublishDirectory declared", r.HasLocalPublishDirectory);
        Assert("artifact-ok: guarded publish target", r.HasGuardedPublishTarget);
        Assert("artifact-ok: CI publishes artifact", r.CiPublishesArtifact);
        Assert("artifact-ok: Visual Studio Compose complete", r.VisualStudioComposeComplete);
        Assert("artifact-ok: no findings", r.Findings.Count == 0);
    }

    // Regression: the observed failure placed all three Dockerfiles at the repository root.
    private static void TestArtifactFirstValidatorRejectsRootDockerfiles(string root)
    {
        var repo = NewArtifactFirstRepo(root, "artifact-rooted", colocated: false);
        var r = ArtifactFirstValidator.Validate(repo, Path.Combine(repo, "src", "Web", "Web.csproj"), ArtifactFirstCompose("src/Web"));
        Assert("artifact-rooted: colocation flagged", !r.DockerfilesColocated);
        Assert("artifact-rooted: stray root dockerfiles flagged", !r.NoRootDockerfile);
    }

    // Regression: the observed failure emitted SDK multi-stage builds that compiled the application
    // inside the image and created the runtime user with RUN.
    private static void TestArtifactFirstValidatorRejectsSourceCompilingDockerfile(string root)
    {
        var repo = NewArtifactFirstRepo(root, "artifact-sdk", colocated: true, dockerfileOverride: """
        FROM mcr.microsoft.com/dotnet/sdk:10.0-alpine as build
        WORKDIR /src
        RUN dotnet publish "src/Web/Web.csproj" -c Release -o /app/publish
        FROM mcr.microsoft.com/dotnet/aspnetcore:10.0-alpine as final
        RUN addgroup -g 65532 appuser && adduser -D -u 65532 -G appuser appuser
        COPY --from=build /app/publish .
        ENTRYPOINT ["dotnet", "Web.dll"]
        """);
        var r = ArtifactFirstValidator.Validate(repo, Path.Combine(repo, "src", "Web", "Web.csproj"), ArtifactFirstCompose("src/Web"));
        Assert("artifact-sdk: source compilation flagged", !r.NoSourceCompilation);
        Assert("artifact-sdk: SDK stage reported", r.Findings.Any(f => f.Contains("SDK stage", StringComparison.OrdinalIgnoreCase)));
        Assert("artifact-sdk: RUN user creation reported", r.Findings.Any(f => f.Contains("RUN", StringComparison.Ordinal) && f.Contains("65532", StringComparison.Ordinal)));
        Assert("artifact-sdk: mcr runtime reported", r.Findings.Any(f => f.Contains("mcr.microsoft.com", StringComparison.OrdinalIgnoreCase)));
    }

    // A mount-only topology never builds an application image, so the artifact-first obligations
    // must not be demanded of it.
    private static void TestArtifactFirstValidatorSkipsWhenNoApplicationImage(string root)
    {
        var repo = Path.Combine(root, "artifact-mount");
        var projectDir = Path.Combine(repo, "src", "Web");
        Directory.CreateDirectory(projectDir);
        File.WriteAllText(Path.Combine(projectDir, "Web.csproj"),
            "<Project Sdk=\"Microsoft.NET.Sdk.Web\"><PropertyGroup><TargetFramework>net10.0</TargetFramework></PropertyGroup></Project>");
        var compose = """
        services:
          app-assets:
            image: codebeltnet/web-cdn-origin:2.0.0
            volumes:
              - ./src/Web/wwwroot:/cdnroot:ro
        """;
        var r = ArtifactFirstValidator.Validate(repo, Path.Combine(projectDir, "Web.csproj"), compose);
        Assert("artifact-mount: colocation not demanded", r.DockerfilesColocated);
        Assert("artifact-mount: dockerignore not demanded", r.HasDockerIgnore);
        Assert("artifact-mount: LocalPublishDirectory not demanded", r.HasLocalPublishDirectory);
        Assert("artifact-mount: CI artifact not demanded", r.CiPublishesArtifact);
        Assert("artifact-mount: no findings", r.Findings.Count == 0);
    }

    // GitHub Actions is the only supported delivery surface, so a repository with no workflow that
    // publishes the artifact leaves the artifact-first image without a producer.
    private static void TestArtifactFirstValidatorRequiresCiArtifactProducer(string root)
    {
        var noCi = NewArtifactFirstRepo(root, "artifact-no-ci", colocated: true);
        Directory.Delete(Path.Combine(noCi, ".github"), recursive: true);
        var withoutCi = ArtifactFirstValidator.Validate(noCi, Path.Combine(noCi, "src", "Web", "Web.csproj"), ArtifactFirstCompose("src/Web"));
        Assert("artifact-no-ci: missing producer flagged", !withoutCi.CiPublishesArtifact);
        Assert("artifact-no-ci: template referenced in the finding",
            withoutCi.Findings.Any(f => f.Contains("assets/ci-pipeline.yml", StringComparison.Ordinal)));

        var buildOnlyCi = NewArtifactFirstRepo(root, "artifact-build-only-ci", colocated: true);
        File.WriteAllText(Path.Combine(buildOnlyCi, ".github", "workflows", "ci-pipeline.yml"),
            "jobs:\n  build:\n    uses: codebeltnet/jobs-dotnet-build/.github/workflows/default.yml@v3\n");
        var withoutProducer = ArtifactFirstValidator.Validate(buildOnlyCi, Path.Combine(buildOnlyCi, "src", "Web", "Web.csproj"), ArtifactFirstCompose("src/Web"));
        Assert("artifact-build-only-ci: build without publish still flagged", !withoutProducer.CiPublishesArtifact);
    }

    // Regression: a repository-wide "first asset-origin Compose file wins" scan let a sibling
    // project's healthy topology satisfy verification for the selected project.
    private static void TestComposeFileSelectorCorrelatesToSelectedProject(string root)
    {
        var repo = Path.Combine(root, "compose-selection");
        var site = Path.Combine(repo, "src", "Acme.Site");
        var api = Path.Combine(repo, "src", "Acme.Api");
        Directory.CreateDirectory(site);
        Directory.CreateDirectory(api);
        File.WriteAllText(Path.Combine(site, "Acme.Site.csproj"), "<Project Sdk=\"Microsoft.NET.Sdk.Web\" />");
        File.WriteAllText(Path.Combine(api, "Acme.Api.csproj"), "<Project Sdk=\"Microsoft.NET.Sdk.Web\" />");
        var webProjects = new[] { "src/Acme.Site/Acme.Site.csproj", "src/Acme.Api/Acme.Api.csproj" };

        File.WriteAllText(Path.Combine(repo, "compose.acme-site.yml"),
            "services:\n  web-app:\n    build:\n      dockerfile: src/Acme.Site/LocalDevelopment.Dockerfile\n  app-assets:\n    build:\n      context: ./src/Acme.Site\n      dockerfile: Assets.Dockerfile\n");

        var withoutOwn = ComposeFileSelector.Select(repo, Path.Combine(api, "Acme.Api.csproj"), webProjects);
        Assert("compose-select: sibling topology is not borrowed", withoutOwn.ComposeFile is null);
        Assert("compose-select: reports the topology belongs elsewhere", withoutOwn.BelongsToAnotherProject);

        File.WriteAllText(Path.Combine(repo, "compose.api.assets.yml"),
            "services:\n  api-app:\n    build:\n      dockerfile: src/Acme.Api/LocalDevelopment.Dockerfile\n  api-assets:\n    build:\n      context: ./src/Acme.Api\n      dockerfile: Assets.Dockerfile\n");

        var apiSelection = ComposeFileSelector.Select(repo, Path.Combine(api, "Acme.Api.csproj"), webProjects);
        Assert("compose-select: selects the project's own file even when another sorts first",
            apiSelection.ComposeFile is not null && Path.GetFileName(apiSelection.ComposeFile).Equals("compose.api.assets.yml", StringComparison.OrdinalIgnoreCase));
        var siteSelection = ComposeFileSelector.Select(repo, Path.Combine(site, "Acme.Site.csproj"), webProjects);
        Assert("compose-select: each project resolves to its own file",
            siteSelection.ComposeFile is not null && Path.GetFileName(siteSelection.ComposeFile).Equals("compose.acme-site.yml", StringComparison.OrdinalIgnoreCase));
    }

    private static void TestComposeFileSelectorAcceptsUnambiguousLayouts(string root)
    {
        // Single project nested under src/: the canonical template names its directory.
        var nested = Path.Combine(root, "compose-single-nested");
        var web = Path.Combine(nested, "src", "Web");
        Directory.CreateDirectory(web);
        File.WriteAllText(Path.Combine(web, "Web.csproj"), "<Project Sdk=\"Microsoft.NET.Sdk.Web\" />");
        File.WriteAllText(Path.Combine(nested, SegregateAssetsProgram.ComposeFileName),
            "services:\n  web-app:\n    build:\n      dockerfile: src/Web/LocalDevelopment.Dockerfile\n  app-assets:\n    build:\n      context: ./src/Web\n      dockerfile: Assets.Dockerfile\n");
        Assert("compose-select: nested single project resolves",
            ComposeFileSelector.Select(nested, Path.Combine(web, "Web.csproj"), new[] { "src/Web/Web.csproj" }).ComposeFile is not null);

        // Project at the repository root: Compose paths are root-relative, so there is nothing to
        // correlate against and the sole candidate is still correct.
        var flat = Path.Combine(root, "compose-flat");
        Directory.CreateDirectory(flat);
        File.WriteAllText(Path.Combine(flat, "Web.csproj"), "<Project Sdk=\"Microsoft.NET.Sdk.Web\" />");
        File.WriteAllText(Path.Combine(flat, SegregateAssetsProgram.ComposeFileName),
            "services:\n  app-assets:\n    build:\n      dockerfile: Assets.Dockerfile\n");
        Assert("compose-select: root-level project resolves",
            ComposeFileSelector.Select(flat, Path.Combine(flat, "Web.csproj"), new[] { "Web.csproj" }).ComposeFile is not null);

        // A sole candidate whose paths this runner does not recognize is still unattributed, so it
        // is used rather than reported as another project's topology.
        var opaque = Path.Combine(root, "compose-opaque");
        var opaqueWeb = Path.Combine(opaque, "app");
        Directory.CreateDirectory(opaqueWeb);
        File.WriteAllText(Path.Combine(opaqueWeb, "Web.csproj"), "<Project Sdk=\"Microsoft.NET.Sdk.Web\" />");
        File.WriteAllText(Path.Combine(opaque, SegregateAssetsProgram.ComposeFileName),
            "services:\n  app-assets:\n    image: codebeltnet/web-cdn-origin:2.0.0\n    volumes:\n      - /elsewhere:/cdnroot:ro\n");
        Assert("compose-select: sole unattributed candidate is used",
            ComposeFileSelector.Select(opaque, Path.Combine(opaqueWeb, "Web.csproj"), new[] { "app/Web.csproj" }).ComposeFile is not null);

        // Segment-boundary safety: Acme.Api must not match Acme.ApiGateway.
        var prefix = Path.Combine(root, "compose-prefix");
        var gateway = Path.Combine(prefix, "src", "Acme.ApiGateway");
        var apiOnly = Path.Combine(prefix, "src", "Acme.Api");
        Directory.CreateDirectory(gateway);
        Directory.CreateDirectory(apiOnly);
        File.WriteAllText(Path.Combine(gateway, "Acme.ApiGateway.csproj"), "<Project Sdk=\"Microsoft.NET.Sdk.Web\" />");
        File.WriteAllText(Path.Combine(apiOnly, "Acme.Api.csproj"), "<Project Sdk=\"Microsoft.NET.Sdk.Web\" />");
        File.WriteAllText(Path.Combine(prefix, SegregateAssetsProgram.ComposeFileName),
            "services:\n  web-app:\n    build:\n      context: ./src/Acme.ApiGateway\n      dockerfile: Assets.Dockerfile\n");
        var prefixProjects = new[] { "src/Acme.ApiGateway/Acme.ApiGateway.csproj", "src/Acme.Api/Acme.Api.csproj" };
        Assert("compose-select: prefix name does not match a longer sibling directory",
            ComposeFileSelector.Select(prefix, Path.Combine(apiOnly, "Acme.Api.csproj"), prefixProjects).ComposeFile is null);
        Assert("compose-select: the longer sibling still resolves its own file",
            ComposeFileSelector.Select(prefix, Path.Combine(gateway, "Acme.ApiGateway.csproj"), prefixProjects).ComposeFile is not null);
    }

    private static void TestPublishLeakDetected()
    {
        var probe = Path.Combine(Path.GetTempPath(), $"segregated-leak-{Guid.NewGuid():N}");
        var src = Path.Combine(probe, "src", "wwwroot");
        var pub = Path.Combine(probe, "pub");
        Directory.CreateDirectory(Path.Combine(src, "css"));
        Directory.CreateDirectory(Path.Combine(pub, "wwwroot", "css"));
        File.WriteAllText(Path.Combine(src, "app.js"), "x");
        File.WriteAllText(Path.Combine(src, "css", "site.css"), "y");
        File.WriteAllText(Path.Combine(pub, "wwwroot", "app.js"), "x");
        File.WriteAllText(Path.Combine(pub, "wwwroot", "css", "site.css"), "y");
        try
        {
            var r = PublishLeakDetector.Detect(src, pub);
            Assert("leak: detected as failed", !r.Passed);
            Assert("leak: two app assets leaked", r.LeakedAppAssets.Count == 2);
        }
        finally { try { Directory.Delete(probe, true); } catch { } }
    }

    private static void TestPublishLeakCleanWithPreservedSharedAssets()
    {
        var probe = Path.Combine(Path.GetTempPath(), $"segregated-clean-{Guid.NewGuid():N}");
        var src = Path.Combine(probe, "src", "wwwroot");
        var pub = Path.Combine(probe, "pub");
        Directory.CreateDirectory(src);
        Directory.CreateDirectory(Path.Combine(pub, "wwwroot", "_content", "Lib"));
        File.WriteAllText(Path.Combine(src, "app.js"), "x");
        File.WriteAllText(Path.Combine(pub, "wwwroot", "_content", "Lib", "shared.css"), "z");
        try
        {
            var r = PublishLeakDetector.Detect(src, pub);
            Assert("clean: passed (app asset absent)", r.Passed);
            Assert("clean: shared asset preserved", r.PreservedSharedAssets.Any(p => p.Contains("_content/Lib/shared.css")));
        }
        finally { try { Directory.Delete(probe, true); } catch { } }
    }

    // --- helpers ---

    private static string NewProject(string root, string name, bool webApp, bool wwwroot,
        string? sdk = null, string? extraCsproj = null)
    {
        var dir = Path.Combine(root, name);
        Directory.CreateDirectory(dir);
        var resolvedSdk = sdk ?? (webApp ? "Microsoft.NET.Sdk.Web" : "Microsoft.NET.Sdk");
        File.WriteAllText(Path.Combine(dir, $"{name}.csproj"), $"""
        <Project Sdk="{resolvedSdk}">
          <PropertyGroup><TargetFramework>net10.0</TargetFramework></PropertyGroup>
          {extraCsproj ?? string.Empty}
        </Project>
        """);
        File.WriteAllText(Path.Combine(dir, "Program.cs"), "// entrypoint");
        if (wwwroot)
        {
            Directory.CreateDirectory(Path.Combine(dir, "wwwroot"));
            File.WriteAllText(Path.Combine(dir, "wwwroot", "site.css"), "body{}");
        }
        return dir;
    }

    private static void Assert(string name, bool condition)
    {
        if (condition) _passed++;
        else _failures.Add(name);
    }

    private sealed class StaticJsonHandler(IReadOnlyDictionary<string, string> responses) : HttpMessageHandler
    {
        protected override Task<HttpResponseMessage> SendAsync(
            HttpRequestMessage request,
            CancellationToken cancellationToken)
        {
            if (request.RequestUri is not null && responses.TryGetValue(request.RequestUri.AbsoluteUri, out var json))
            {
                return Task.FromResult(new HttpResponseMessage(System.Net.HttpStatusCode.OK)
                {
                    Content = new StringContent(json, Encoding.UTF8, "application/json"),
                });
            }

            return Task.FromResult(new HttpResponseMessage(System.Net.HttpStatusCode.NotFound));
        }
    }
}
