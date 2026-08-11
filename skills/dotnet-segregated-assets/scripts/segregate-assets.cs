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

return SegregateAssetsProgram.Run(args);

internal static class SegregateAssetsProgram
{
    internal const string ToolName = "dotnet-segregated-assets";
    internal const string OriginImage = "codebeltnet/web-cdn-origin:2.0.0";
    internal const string DerivedDockerfileName = "Assets.Dockerfile";
    internal const string ComposeFileName = "compose.assets.yml";
    internal const int OriginContainerPort = 8080;
    internal const string OriginContentRoot = "/cdnroot";
    internal const string OriginUser = "65532";
    internal const string SegregatedProfileName = "http-segregated-assets";

    internal static readonly JsonSerializerOptions JsonOut = new()
    {
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
        DefaultIgnoreCondition = JsonIgnoreCondition.WhenWritingNull,
        WriteIndented = true
    };

    public static int Run(string[] args)
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
                Command.SelfTest => SelfTest.Run(options),
                Command.Inspect => Commands.Inspect(options),
                Command.Plan => Commands.Plan(options),
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
          plan       Resolve the target project, ports, and the ordered set of segregation decisions
                     without writing any files.
          verify     Prove application-owned wwwroot files are absent from the publish artifact and,
                     with --check-local, validate the local Static Content Provider topology.
          --self-test  Run the built-in deterministic tests (no dotnet/docker/network required).

        Options:
          --repo-root <dir>     Repository root to inspect (default: current directory).
          -p, --project <path>  Target web project (.csproj), relative to repo root or absolute.
          --publish-dir <dir>   Existing publish output to inspect for verify.
          --run-publish         Run `dotnet publish -c Release` into an isolated temp dir for verify.
          --check-local         Validate launchSettings.json and the local Compose origin topology.
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
    public bool Any => PublishExclusion || SegregatedLaunchProfile || ComposeService || DerivedDockerfile || CuemonAppOptions;
    public bool Complete => PublishExclusion && SegregatedLaunchProfile;
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
    string Recommendation)
{
    public bool Ok => true;
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

internal static class IdempotencyDetector
{
    public static ExistingSegregation Detect(string projectPath, string repoRoot)
    {
        var dir = Path.GetDirectoryName(projectPath)!;
        var csproj = SafeRead(projectPath);

        var publishExclusion = Regex.IsMatch(
            csproj,
            "<Content\\b[^>]*Update\\s*=\\s*\"wwwroot[\\\\/][*][*][^\"]*\"[^>]*CopyToPublishDirectory\\s*=\\s*\"Never\"",
            RegexOptions.IgnoreCase)
            || Regex.IsMatch(csproj, "CopyToPublishDirectory\\s*=\\s*\"Never\"[^>]*Update\\s*=\\s*\"wwwroot", RegexOptions.IgnoreCase);

        var launchSettings = Path.Combine(dir, "Properties", "launchSettings.json");
        var segregatedProfile = File.Exists(launchSettings) &&
            SafeRead(launchSettings).Contains(SegregateAssetsProgram.SegregatedProfileName, StringComparison.OrdinalIgnoreCase);

        var composeService = EnumerateComposeFiles(repoRoot)
            .Select(SafeRead)
            .Any(t => t.Contains("codebeltnet/web-cdn-origin", StringComparison.OrdinalIgnoreCase));

        var derivedDockerfile = EnumerateDockerfiles(repoRoot)
            .Select(SafeRead)
            .Any(t => Regex.IsMatch(t, "^\\s*FROM\\s+codebeltnet/web-cdn-origin", RegexOptions.IgnoreCase | RegexOptions.Multiline));

        var cuemonAppOptions = Regex.IsMatch(
            string.Concat(SafeFiles(dir, "*.cs").Select(SafeRead)),
            "AppTagHelperOptions|CdnTagHelperOptions",
            RegexOptions.IgnoreCase);

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

    public static string Recommend(string classification, ExistingSegregation existing) => classification switch
    {
        NotAWebApp => "No Microsoft.NET.Sdk.Web project found. Nothing to segregate; confirm the target repository.",
        Ambiguous => "Multiple web projects found. Ask which web project to segregate (pass --project).",
        NoWwwroot => "No wwwroot found. Configure only the CDN/shared-asset consumption if a CDN equivalent exists; otherwise nothing to do.",
        AlreadySegregated => "Segregation is already present. Reconcile existing configuration; do not create duplicate items, profiles, services, or Dockerfiles.",
        RiskyGeneratedAssets => "Generated/Static Web Assets detected. Preserve the generated-asset pipeline and establish an explicit generated-static-assets segregation design before proceeding.",
        Simple => existing.Any
            ? "Simple physical wwwroot with partial existing segregation. Complete the missing pieces idempotently."
            : "Simple physical wwwroot. Apply App-asset segregation: targeted publish exclusion, segregated launch profile, local origin, derived production image, and documentation.",
        _ => "Review findings.",
    };
}

internal static class LaunchProfileValidator
{
    public sealed record Result(bool ProfileExists, bool IsHttp, bool HasHttpLocalOrigin, bool HasUnsafeProtocol, IReadOnlyList<string> Findings);

    // Validates the segregated launch profile in launchSettings.json JSON text.
    public static Result Validate(string launchSettingsJson, string profileName)
    {
        var findings = new List<string>();
        JsonDocument doc;
        try { doc = JsonDocument.Parse(launchSettingsJson); }
        catch (Exception ex) { return new Result(false, false, false, false, new[] { $"launchSettings.json is not valid JSON: {ex.Message}" }); }

        using (doc)
        {
            if (!doc.RootElement.TryGetProperty("profiles", out var profiles) ||
                !profiles.TryGetProperty(profileName, out var profile))
            {
                findings.Add($"Profile '{profileName}' is not present.");
                return new Result(false, false, false, false, findings);
            }

            var appUrl = profile.TryGetProperty("applicationUrl", out var u) ? (u.GetString() ?? string.Empty) : string.Empty;
            var isHttp = appUrl.Contains("http://", StringComparison.OrdinalIgnoreCase) && !appUrl.Contains("https://", StringComparison.OrdinalIgnoreCase);
            if (!isHttp)
                findings.Add("Segregated profile applicationUrl should be HTTP-only so an HTTP local origin is not requested from an HTTPS page.");

            var envValues = new List<string>();
            if (profile.TryGetProperty("environmentVariables", out var env) && env.ValueKind == JsonValueKind.Object)
            {
                foreach (var p in env.EnumerateObject())
                    envValues.Add($"{p.Name}={p.Value.GetString() ?? string.Empty}");
            }
            var envBlob = string.Join("\n", envValues);

            var hasHttpLocalOrigin = Regex.IsMatch(envBlob, "http://localhost:\\d+", RegexOptions.IgnoreCase);
            if (!hasHttpLocalOrigin)
                findings.Add("Segregated profile should point App asset URLs at an http://localhost:<port> origin.");

            var hasUnsafeProtocol =
                Regex.IsMatch(envBlob, "(^|=)//localhost", RegexOptions.IgnoreCase | RegexOptions.Multiline) ||
                Regex.IsMatch(envBlob, "https://localhost", RegexOptions.IgnoreCase);
            if (hasUnsafeProtocol)
                findings.Add("Segregated profile uses a protocol-relative (//localhost) or https://localhost URL that would break an HTTP-only local origin.");

            return new Result(true, isHttp, hasHttpLocalOrigin, hasUnsafeProtocol, findings);
        }
    }
}

internal static class ComposeValidator
{
    public sealed record Result(bool UsesOriginImage, bool ReadOnlyMount, bool ReadOnlyRootFs, bool NonPrivileged, bool NoDockerSocket, IReadOnlyList<string> Findings);

    // Lightweight, line-oriented validation of the local origin service posture.
    public static Result Validate(string composeText)
    {
        var findings = new List<string>();

        var usesOrigin = composeText.Contains(SegregateAssetsProgram.OriginImage, StringComparison.OrdinalIgnoreCase);
        if (!usesOrigin) findings.Add($"Compose does not reference {SegregateAssetsProgram.OriginImage}.");

        var readOnlyMount = Regex.IsMatch(composeText, ":/cdnroot:ro\\b", RegexOptions.IgnoreCase) ||
                            Regex.IsMatch(composeText, "target:\\s*/cdnroot[\\s\\S]{0,120}read_only:\\s*true", RegexOptions.IgnoreCase);
        if (!readOnlyMount) findings.Add("wwwroot should be mounted into /cdnroot read-only (':/cdnroot:ro').");

        var readOnlyRootFs = Regex.IsMatch(composeText, "read_only:\\s*true", RegexOptions.IgnoreCase);
        if (!readOnlyRootFs) findings.Add("Prefer a read-only root filesystem (read_only: true) where practical.");

        var nonPrivileged = !Regex.IsMatch(composeText, "privileged:\\s*true", RegexOptions.IgnoreCase);
        if (!nonPrivileged) findings.Add("Do not run the origin in privileged mode.");

        var noDockerSocket = !composeText.Contains("docker.sock", StringComparison.OrdinalIgnoreCase);
        if (!noDockerSocket) findings.Add("Do not mount the Docker socket into the origin container.");

        return new Result(usesOrigin, readOnlyMount, readOnlyRootFs, nonPrivileged, noDockerSocket, findings);
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

        var risks = selected is not null ? StaticWebAssetRiskDetector.Detect(selected.Path, repoRoot) : Array.Empty<RiskSignal>();
        var existing = selected is not null ? IdempotencyDetector.Detect(selected.Path, repoRoot) : new ExistingSegregation(false, false, false, false, false);
        var classification = Classifier.Classify(webProjects, selected, risks, existing);
        var cuemonPresent = existing.CuemonAppOptions ||
            (selected is not null && File.Exists(selected.Path) && File.ReadAllText(selected.Path).Contains("Cuemon.AspNetCore", StringComparison.OrdinalIgnoreCase));
        var recommendation = Classifier.Recommend(classification, existing);

        return new InspectionResult(
            SegregateAssetsProgram.ToolName,
            repoRoot,
            webProjects,
            selected?.RelativePath,
            classification,
            risks,
            existing,
            cuemonPresent,
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

    public static int Plan(Options options)
    {
        var inspection = Inspect(options.RepoRoot, options.Project);
        var decisions = BuildPlan(inspection, options);
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
            decisions,
            recommendation = inspection.Recommendation,
        };
        SegregateAssetsProgram.Emit(options, payload, () => RenderPlan(inspection, options, decisions));
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
            if (options.CheckLocal)
            {
                var launchSettings = Path.Combine(Path.GetDirectoryName(projectPath)!, "Properties", "launchSettings.json");
                if (File.Exists(launchSettings))
                    launch = LaunchProfileValidator.Validate(File.ReadAllText(launchSettings), SegregateAssetsProgram.SegregatedProfileName);

                var composeFile = IdempotencyDetector.EnumerateComposeFiles(options.RepoRoot)
                    .FirstOrDefault(f => File.ReadAllText(f).Contains("codebeltnet/web-cdn-origin", StringComparison.OrdinalIgnoreCase));
                if (composeFile is not null)
                    compose = ComposeValidator.Validate(File.ReadAllText(composeFile));
            }

            var localOk = launch is not null &&
                          !launch.HasUnsafeProtocol && launch.HasHttpLocalOrigin && launch.IsHttp &&
                          compose is not null &&
                          compose.UsesOriginImage && compose.ReadOnlyMount && compose.NonPrivileged && compose.NoDockerSocket;
            var ok = leak.Passed && (!options.CheckLocal || localOk);

            var payload = new
            {
                tool = SegregateAssetsProgram.ToolName,
                ok,
                selectedProject = selected,
                publishInspected = publishDir,
                publishInvariant = leak.Passed ? "application-owned wwwroot is ABSENT from the publish artifact" : "application-owned wwwroot LEAKED into the publish artifact",
                leakedAppAssets = leak.LeakedAppAssets,
                preservedSharedAssets = leak.PreservedSharedAssets,
                launch,
                compose,
            };
            SegregateAssetsProgram.Emit(options, payload, () => RenderVerify(selected, publishDir!, leak, launch, compose, ok));
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

    private static List<object> BuildPlan(InspectionResult inspection, Options options)
    {
        var e = inspection.ExistingSegregation;
        string StatusFor(bool present) => present ? "already-present" : "create";

        if (inspection.Classification == Classifier.RiskyGeneratedAssets)
        {
            return new List<object>
            {
                new { step = "escalate", status = "blocked", detail = "Risky Static Web Assets detected. Preserve the generated-asset pipeline and request an explicit generated-static-assets segregation design." },
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

        var plan = new List<object>
        {
            new { step = "publish-exclusion", status = StatusFor(e.PublishExclusion), detail = "Add <Content Update=\"wwwroot/**\" CopyToPublishDirectory=\"Never\" /> to the web project for application-owned wwwroot content while preserving generated and contributed Static Web Assets." },
            new { step = "segregated-launch-profile", status = StatusFor(e.SegregatedLaunchProfile), detail = $"Add the '{SegregateAssetsProgram.SegregatedProfileName}' HTTP launch profile pointing App asset URLs at http://localhost:{options.AppPort}." },
            new { step = "local-origin", status = StatusFor(e.ComposeService), detail = $"Provide {SegregateAssetsProgram.ComposeFileName} with a local {SegregateAssetsProgram.OriginImage} service mounting wwwroot into /cdnroot read-only on host port {options.AppPort}." },
            new { step = "production-image", status = StatusFor(e.DerivedDockerfile), detail = $"Add {SegregateAssetsProgram.DerivedDockerfileName} (PascalCase <something>.Dockerfile) and select it with --file: FROM {SegregateAssetsProgram.OriginImage} + COPY --chown={SegregateAssetsProgram.OriginUser}:{SegregateAssetsProgram.OriginUser} ./wwwroot/ {SegregateAssetsProgram.OriginContentRoot}/." },
            new { step = "documentation", status = "create-or-update", detail = "Document that deployed static content is served by Codebelt Static Content Provider, and that wwwroot remains the authoring root." },
        };

        if (options.CdnEquivalent)
        {
            plan.Add(new { step = "cdn-equivalent", status = "create", detail = $"A CDN/shared equivalent exists: provision a second local origin on host port {options.CdnPort} from its own shared-asset root; do NOT duplicate CDN assets into the application's wwwroot." });
        }
        else
        {
            plan.Add(new { step = "cdn-equivalent", status = "skip", detail = "No CDN/shared equivalent: configure only App-asset segregation." });
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
        sb.AppendLine();
        sb.AppendLine($"Web projects ({r.WebProjects.Count}):");
        foreach (var p in r.WebProjects)
            sb.AppendLine($"  - {p.RelativePath} [sdk={p.Sdk}] wwwroot={p.HasWwwroot}");
        if (r.RiskSignals.Count > 0)
        {
            sb.AppendLine();
            sb.AppendLine("Risk signals (do NOT blindly exclude):");
            foreach (var s in r.RiskSignals) sb.AppendLine($"  ! {s.Code}: {s.Detail}");
        }
        var e = r.ExistingSegregation;
        sb.AppendLine();
        sb.AppendLine("Existing segregation:");
        sb.AppendLine($"  publish-exclusion={e.PublishExclusion} launch-profile={e.SegregatedLaunchProfile} compose={e.ComposeService} dockerfile={e.DerivedDockerfile} cuemon={e.CuemonAppOptions}");
        sb.AppendLine();
        sb.AppendLine($"Recommendation: {r.Recommendation}");
        return sb.ToString().TrimEnd();
    }

    private static string RenderPlan(InspectionResult r, Options o, List<object> decisions)
    {
        var sb = new StringBuilder();
        sb.AppendLine($"Plan for {r.SelectedProject ?? "(unresolved)"} [{r.Classification}]");
        sb.AppendLine($"App origin port: {o.AppPort}" + (o.CdnEquivalent ? $"  CDN origin port: {o.CdnPort}" : "  (no CDN equivalent)"));
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

    private static string RenderVerify(string project, string publishDir, PublishLeakDetector.Result leak,
        LaunchProfileValidator.Result? launch, ComposeValidator.Result? compose, bool ok)
    {
        var sb = new StringBuilder();
        sb.AppendLine($"Verify: {project}");
        sb.AppendLine($"Publish inspected: {publishDir}");
        sb.AppendLine(leak.Passed
            ? "PASS  application-owned wwwroot is ABSENT from the publish artifact."
            : "FAIL  application-owned wwwroot LEAKED into the publish artifact:");
        foreach (var f in leak.LeakedAppAssets) sb.AppendLine($"    leaked: {f}");
        if (leak.PreservedSharedAssets.Count > 0)
            sb.AppendLine($"  preserved shared/framework assets: {leak.PreservedSharedAssets.Count} (e.g. {leak.PreservedSharedAssets[0]})");
        if (launch is not null)
        {
            sb.AppendLine();
            sb.AppendLine($"Local launch profile: exists={launch.ProfileExists} http={launch.IsHttp} httpLocalOrigin={launch.HasHttpLocalOrigin} unsafeProtocol={launch.HasUnsafeProtocol}");
            foreach (var f in launch.Findings) sb.AppendLine($"    - {f}");
        }
        if (compose is not null)
        {
            sb.AppendLine($"Local origin compose: originImage={compose.UsesOriginImage} roMount={compose.ReadOnlyMount} roRootFs={compose.ReadOnlyRootFs} nonPrivileged={compose.NonPrivileged} noDockerSocket={compose.NoDockerSocket}");
            foreach (var f in compose.Findings) sb.AppendLine($"    - {f}");
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

    public static int Run(Options options)
    {
        var root = Path.Combine(Path.GetTempPath(), $"segregated-selftest-{Guid.NewGuid():N}");
        Directory.CreateDirectory(root);
        try
        {
            TestWebSdkDetection();
            TestSimpleWebAppClassification(root);
            TestBlazorWebAssemblyIsRisky(root);
            TestRazorClassLibraryIsRisky(root);
            TestScopedCssIsRisky(root);
            TestFrontendBuildIsRisky(root);
            TestAmbiguousMultiProject(root);
            TestNoWwwroot(root);
            TestIdempotencyDetection(root);
            TestAlreadySegregatedClassification(root);
            TestAlreadySegregatedRiskIsRisky(root);
            TestLaunchProfileValidatorSafe();
            TestLaunchProfileValidatorRejectsProtocolRelative();
            TestLaunchProfileValidatorRejectsHttpsLocal();
            TestComposeValidatorSafe();
            TestComposeValidatorRejectsPrivilegedAndSocket();
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

    private static void TestSimpleWebAppClassification(string root)
    {
        var dir = NewProject(root, "simple", webApp: true, wwwroot: true);
        var inspection = Commands.Inspect(dir, null);
        Assert("simple: classified Simple", inspection.Classification == Classifier.Simple);
        Assert("simple: no risk signals", inspection.RiskSignals.Count == 0);
        Assert("simple: selected resolved", inspection.SelectedProject is not null);
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
        Directory.CreateDirectory(Path.Combine(dir, "Properties"));
        File.WriteAllText(Path.Combine(dir, "Properties", "launchSettings.json"), """
        { "profiles": { "http-segregated-assets": { "commandName": "Project" } } }
        """);
        File.WriteAllText(Path.Combine(dir, SegregateAssetsProgram.ComposeFileName),
            "services:\n  app-assets:\n    image: codebeltnet/web-cdn-origin:2.0.0\n");
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
        Directory.CreateDirectory(Path.Combine(dir, "Properties"));
        File.WriteAllText(Path.Combine(dir, "Properties", "launchSettings.json"),
            "{ \"profiles\": { \"http-segregated-assets\": { \"commandName\": \"Project\" } } }");
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
        Directory.CreateDirectory(Path.Combine(dir, "Properties"));
        File.WriteAllText(Path.Combine(dir, "Properties", "launchSettings.json"),
            "{ \"profiles\": { \"http-segregated-assets\": { \"commandName\": \"Project\" } } }");
        File.WriteAllText(Path.Combine(dir, "Index.cshtml.css"), "h1{color:red}");

        var inspection = Commands.Inspect(dir, null);
        Assert("already-risky: existing segregation is complete", inspection.ExistingSegregation.Complete);
        Assert("already-risky: risk takes precedence", inspection.Classification == Classifier.RiskyGeneratedAssets);
    }

    private static void TestLaunchProfileValidatorSafe()
    {
        var json = """
        { "profiles": { "http-segregated-assets": {
            "commandName": "Project",
            "applicationUrl": "http://localhost:5080",
            "environmentVariables": {
              "ASPNETCORE_ENVIRONMENT": "Development",
              "SegregatedAssets__App__BaseUrl": "http://localhost:8080",
              "SegregatedAssets__App__Scheme": "Http"
            }
          } } }
        """;
        var r = LaunchProfileValidator.Validate(json, "http-segregated-assets");
        Assert("launch-safe: profile exists", r.ProfileExists);
        Assert("launch-safe: http", r.IsHttp);
        Assert("launch-safe: http local origin", r.HasHttpLocalOrigin);
        Assert("launch-safe: no unsafe protocol", !r.HasUnsafeProtocol);
    }

    private static void TestLaunchProfileValidatorRejectsProtocolRelative()
    {
        var json = """
        { "profiles": { "http-segregated-assets": {
            "applicationUrl": "http://localhost:5080",
            "environmentVariables": { "SegregatedAssets__App__BaseUrl": "//localhost:8080" }
          } } }
        """;
        var r = LaunchProfileValidator.Validate(json, "http-segregated-assets");
        Assert("launch-protorel: flagged unsafe", r.HasUnsafeProtocol);
    }

    private static void TestLaunchProfileValidatorRejectsHttpsLocal()
    {
        var json = """
        { "profiles": { "http-segregated-assets": {
            "applicationUrl": "https://localhost:5443",
            "environmentVariables": { "SegregatedAssets__App__BaseUrl": "https://localhost:8080" }
          } } }
        """;
        var r = LaunchProfileValidator.Validate(json, "http-segregated-assets");
        Assert("launch-httpslocal: not http", !r.IsHttp);
        Assert("launch-httpslocal: flagged unsafe", r.HasUnsafeProtocol);
    }

    private static void TestComposeValidatorSafe()
    {
        var compose = """
        services:
          app-assets:
            image: codebeltnet/web-cdn-origin:2.0.0
            read_only: true
            cap_drop: [ALL]
            ports: ["8080:8080"]
            volumes:
              - ./src/Web/wwwroot:/cdnroot:ro
        """;
        var r = ComposeValidator.Validate(compose);
        Assert("compose-safe: origin image", r.UsesOriginImage);
        Assert("compose-safe: read-only mount", r.ReadOnlyMount);
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
        Assert("compose-bad: privileged flagged", !r.NonPrivileged);
        Assert("compose-bad: docker socket flagged", !r.NoDockerSocket);
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
}
