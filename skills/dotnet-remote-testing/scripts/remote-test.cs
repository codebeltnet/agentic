#:property TargetFramework=net10.0
#:property Nullable=enable
#:property LangVersion=latest
#:property PublishAot=false

// dotnet-remote-testing deterministic runner.
//
// This file is the *execution layer* for the dotnet-remote-testing skill. The AI skill is only the
// orchestration layer: it decides intent (list, plan, run) and which environment the developer means,
// then hands the actual work to this program. Everything between "choose an environment" and "see
// results" — configuration discovery, .NET release discovery, image resolution, source staging, NuGet
// caching, container execution, result collection, failure classification, and cleanup — lives here so
// remote testing stays deterministic and reproducible instead of being re-improvised on every call.
//
// Docker is the first (and currently only) supported transport. The code is organized so other
// transports (WSL, SSH, ...) could be added later without disturbing the Docker path, but none of that
// is implemented now on purpose.

using System.Diagnostics;
using System.Globalization;
using System.Net;
using System.Net.Http.Headers;
using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;
using System.Text.RegularExpressions;
using System.Xml.Linq;

return await RemoteTestProgram.RunAsync(args);

internal static class RemoteTestProgram
{
    internal const string ToolName = "dotnet-remote-testing";
    internal const string SdkRepository = "mcr.microsoft.com/dotnet/sdk";
    internal const string SdkRepositoryPath = "dotnet/sdk";
    internal const string ReleasesIndexUrl =
        "https://raw.githubusercontent.com/dotnet/core/refs/heads/main/release-notes/releases-index.json";

    // Microsoft's SDK images carry exactly one runtime, so a repository that multi-targets several .NET
    // majors cannot execute its lower target frameworks there — it builds, then fails for want of a
    // runtime. The Codebelt test runner ships several SDKs in one image (tags such as "8-9-10-11"), so
    // one container covers every target framework in a single run.
    internal const string MultiSdkRepository = "codebeltnet/ubuntu-testrunner";
    internal const string MultiSdkTagsUrl =
        "https://hub.docker.com/v2/repositories/codebeltnet/ubuntu-testrunner/tags?page_size=100";

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
        catch (OptionException ex)
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
                Command.SelfTest => SelfTest.Run(),
                Command.List => await Commands.ListAsync(options),
                Command.Plan => await Commands.PlanAsync(options),
                Command.Run => await Commands.RunAsync(options),
                _ => Fail(options, ExitCode.InvalidArguments, "No command specified. Use list, plan, run, or --self-test."),
            };
        }
        catch (OperationCanceledException)
        {
            return (int)ExitCode.Cancelled;
        }
        catch (Exception ex)
        {
            return Fail(options, ExitCode.ResultProcessing, $"Unhandled error: {ex.Message}");
        }
    }

    private static int Fail(Options options, ExitCode code, string message)
    {
        if (options.Json)
        {
            Console.WriteLine(JsonSerializer.Serialize(
                new { tool = ToolName, status = "error", failureKind = code.ToString(), message },
                JsonOut));
        }
        else
        {
            Console.Error.WriteLine($"{ToolName}: {message}");
        }

        return (int)code;
    }
}

// External exit codes. These map onto the failure taxonomy required by the skill so a caller (human or
// CI) can tell a container/infrastructure problem apart from an actual failing unit test.
internal enum ExitCode
{
    Success = 0,
    TestFailures = 1,
    InvalidArguments = 2,
    Configuration = 3,
    UnsupportedEnvironment = 4,
    DockerUnavailable = 5,
    ImageResolution = 6,
    SdkIncompatibility = 7,
    SourceStaging = 8,
    Restore = 9,
    Compilation = 10,
    TestHost = 11,
    ResultProcessing = 12,
    Cleanup = 13,
    Cancelled = 14,
    ReleaseMetadataUnavailable = 15,
    SelectionRequired = 16,
}

internal enum Command { None, List, Plan, Run, SelfTest }

internal sealed class OptionException(string message) : Exception(message);

internal sealed class Options
{
    public Command Command { get; private set; } = Command.None;
    public bool ShowHelp { get; private set; }
    public bool Json { get; private set; }
    public bool Offline { get; private set; }
    public bool NoRegistryCheck { get; private set; }

    public string RepoRoot { get; private set; } = Directory.GetCurrentDirectory();
    public string? ConfigPath { get; private set; }
    public string? EnvironmentName { get; private set; }
    public string? ReleasesIndexFile { get; private set; }
    public string? MultiSdkTagsFile { get; private set; }
    public string? CacheRoot { get; private set; }

    // Test scoping. These flow into the container command plan; they never mutate the repository.
    public string? Project { get; private set; }
    public string? Filter { get; private set; }
    public string? Test { get; private set; }
    public string Configuration { get; private set; } = "Debug";
    public string? Framework { get; private set; }
    public bool Coverage { get; private set; }
    public int TimeoutSeconds { get; private set; }

    // Staging/reporting fidelity switches. Defaults reproduce what the developer sees locally.
    public bool NoGitMetadata { get; private set; }
    public bool ShowLog { get; private set; }

    public static Options Parse(string[] args)
    {
        var o = new Options();
        for (var i = 0; i < args.Length; i++)
        {
            var a = args[i];
            switch (a)
            {
                case "list": o.SetCommand(Command.List); break;
                case "plan": o.SetCommand(Command.Plan); break;
                case "run": o.SetCommand(Command.Run); break;
                case "--self-test": o.SetCommand(Command.SelfTest); break;
                case "-h" or "--help": o.ShowHelp = true; break;
                case "--json": o.Json = true; break;
                case "--offline": o.Offline = true; break;
                case "--no-registry-check": o.NoRegistryCheck = true; break;
                case "--coverage": o.Coverage = true; break;
                case "--no-git-metadata": o.NoGitMetadata = true; break;
                case "--show-log": o.ShowLog = true; break;
                case "--repo-root": o.RepoRoot = Path.GetFullPath(Next(args, ref i, a)); break;
                case "--config-path": o.ConfigPath = Next(args, ref i, a); break;
                case "--environment" or "-e": o.EnvironmentName = Next(args, ref i, a); break;
                case "--releases-index-file": o.ReleasesIndexFile = Next(args, ref i, a); break;
                case "--multi-sdk-tags-file": o.MultiSdkTagsFile = Next(args, ref i, a); break;
                case "--cache-root": o.CacheRoot = Next(args, ref i, a); break;
                case "--project" or "-p": o.Project = Next(args, ref i, a); break;
                case "--filter": o.Filter = Next(args, ref i, a); break;
                case "--test": o.Test = Next(args, ref i, a); break;
                case "--configuration" or "-c": o.Configuration = Next(args, ref i, a); break;
                case "--framework" or "-f": o.Framework = Next(args, ref i, a); break;
                case "--timeout": o.TimeoutSeconds = ParseInt(Next(args, ref i, a)); break;
                default:
                    if (a.StartsWith("--repo-root=", StringComparison.Ordinal)) { o.RepoRoot = Path.GetFullPath(a["--repo-root=".Length..]); break; }
                    throw new OptionException($"Unknown argument: {a}");
            }
        }

        if (o.Command == Command.None && !o.ShowHelp)
        {
            throw new OptionException("No command specified.");
        }

        return o;
    }

    private void SetCommand(Command c)
    {
        if (Command != Command.None)
        {
            throw new OptionException($"Only one command may be specified (already '{Command}').");
        }

        Command = c;
    }

    private static string Next(string[] args, ref int i, string flag)
    {
        if (i + 1 >= args.Length)
        {
            throw new OptionException($"Missing value for {flag}.");
        }

        return args[++i];
    }

    private static int ParseInt(string s) =>
        int.TryParse(s, NumberStyles.Integer, CultureInfo.InvariantCulture, out var v) && v >= 0
            ? v
            : throw new OptionException($"Invalid integer: {s}");

    public string CacheDirectory => CacheRoot ?? DefaultCacheRoot();

    private static string DefaultCacheRoot()
    {
        var baseDir = Environment.GetEnvironmentVariable("LOCALAPPDATA")
            ?? Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);
        if (string.IsNullOrWhiteSpace(baseDir))
        {
            baseDir = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), ".cache");
        }

        return Path.Combine(baseDir, "dotnet-remote-testing");
    }

    public static void PrintUsage(TextWriter w) => w.WriteLine(
        $$"""
        {{RemoteTestProgram.ToolName}} - run .NET tests in a resolved remote (Docker) environment.

        Usage:
          dotnet run --file remote-test.cs -- <command> [options]

        Commands:
          list          List available remote test environments (configured or Microsoft-derived).
          plan          Resolve an environment + image and print the deterministic execution plan without running.
          run           Execute restore/build/test inside the resolved Docker environment.
          --self-test   Run the built-in deterministic unit tests and exit.

        Selection:
          -e, --environment <name>   Select an environment by name.
              --config-path <path>   Path to testenvironments.json (default: search from --repo-root upward).
              --repo-root <path>     Workspace/solution root (default: current directory).

        Test scoping (plan/run):
          -p, --project <path>       Solution/project to test (relative to the source root).
              --filter <expr>        dotnet test --filter expression.
              --test <fqn>           Shortcut for --filter "FullyQualifiedName~<fqn>".
          -c, --configuration <cfg>  Build configuration (default: Debug).
          -f, --framework <tfm>      Restrict multi-targeted test projects to one TFM.
              --coverage             Collect code coverage (XPlat Code Coverage) when the project supports it.
              --timeout <seconds>    Abort the container run after N seconds (0 = no timeout).
              --no-git-metadata      Do not stage .git into the workspace (faster for a very large
                                     repository, but repository-root detection, MinVer/Nerdbank
                                     versioning and SourceLink will differ from the host).

        Release discovery / networking:
              --offline              Use cached release metadata only; never reach the network.
              --no-registry-check    Skip Docker registry tag validation and digest pre-resolution.
              --releases-index-file <path>  Load Microsoft release metadata from a local file instead of the network.
              --multi-sdk-tags-file <path>  Load Codebelt multi-SDK runner tags from a local file instead of the network.
              --cache-root <path>    Override the metadata/NuGet cache root (outside the repository).

        Output:
              --json                 Emit machine-readable JSON.
              --show-log             Print the container's restore/build/test log in full.
          -h, --help                 Show this help.

        Exit codes: 0 success, 1 test failures, 2 invalid args, 3 configuration, 4 unsupported environment,
          5 docker unavailable, 6 image resolution, 7 sdk incompatibility, 8 source staging, 9 restore,
          10 compilation, 11 test host, 12 result processing, 13 cleanup, 14 cancelled,
          15 release metadata unavailable, 16 selection required.
        """);
}

// ---------------------------------------------------------------------------------------------------
// testenvironments.json — Microsoft's version 1 configuration contract.
// We honor the existing schema rather than invent a competing format. Only Docker is supported now;
// WSL/SSH are recognized so we can report them as unsupported instead of silently ignoring them.
// ---------------------------------------------------------------------------------------------------

internal enum EnvironmentType { Docker, Wsl, Ssh, Unknown }

internal sealed record EnvironmentDefinition
{
    public required string Name { get; init; }
    public EnvironmentType Type { get; init; }
    public string RawType { get; init; } = "";
    public string? DockerImage { get; init; }
    public string? DockerFile { get; init; }
    public string? LocalRoot { get; init; }
    public string? WslDistribution { get; init; }
    public string? RemoteUri { get; init; }

    // A configured environment is deliberate repository intent, so its dockerImage is exempt from the
    // Microsoft-only image restriction that governs auto-generated environments.
    public bool IsConfigured => true;
}

internal sealed record ConfigDiagnostic(string Code, string Message, string? EnvironmentName = null);

internal sealed record TestEnvironmentsConfig
{
    public string? Version { get; init; }
    public IReadOnlyList<EnvironmentDefinition> Environments { get; init; } = [];
    public IReadOnlyList<ConfigDiagnostic> Diagnostics { get; init; } = [];
    public string? SourcePath { get; init; }

    public bool VersionSupported => Version == "1";

    // Docker environments that are structurally valid enough to use.
    public IReadOnlyList<EnvironmentDefinition> SupportedDockerEnvironments =>
        [.. Environments.Where(e => e.Type == EnvironmentType.Docker
            && !string.IsNullOrWhiteSpace(e.Name)
            && (!string.IsNullOrWhiteSpace(e.DockerImage) ^ !string.IsNullOrWhiteSpace(e.DockerFile)))];

    public IReadOnlyList<EnvironmentDefinition> UnsupportedEnvironments =>
        [.. Environments.Where(e => e.Type is EnvironmentType.Wsl or EnvironmentType.Ssh or EnvironmentType.Unknown)];
}

internal static class TestEnvironmentsConfigReader
{
    // Search order: explicit --config-path, then testenvironments.json at repoRoot, then nearest ancestor.
    public static string? Locate(string repoRoot, string? explicitPath)
    {
        if (!string.IsNullOrWhiteSpace(explicitPath))
        {
            return File.Exists(explicitPath) ? Path.GetFullPath(explicitPath) : null;
        }

        var dir = new DirectoryInfo(repoRoot);
        while (dir is not null)
        {
            var candidate = Path.Combine(dir.FullName, "testenvironments.json");
            if (File.Exists(candidate))
            {
                return candidate;
            }

            dir = dir.Parent;
        }

        return null;
    }

    public static TestEnvironmentsConfig Parse(string json, string? sourcePath = null)
    {
        var diagnostics = new List<ConfigDiagnostic>();
        var environments = new List<EnvironmentDefinition>();
        string? version = null;

        JsonDocument doc;
        try
        {
            doc = JsonDocument.Parse(json);
        }
        catch (JsonException ex)
        {
            return new TestEnvironmentsConfig
            {
                SourcePath = sourcePath,
                Diagnostics = [new ConfigDiagnostic("INVALID_JSON", $"testenvironments.json is not valid JSON: {ex.Message}")],
            };
        }

        using (doc)
        {
            var root = doc.RootElement;
            if (root.ValueKind != JsonValueKind.Object)
            {
                diagnostics.Add(new ConfigDiagnostic("INVALID_ROOT", "testenvironments.json must be a JSON object."));
                return new TestEnvironmentsConfig { SourcePath = sourcePath, Diagnostics = diagnostics };
            }

            if (root.TryGetProperty("version", out var v))
            {
                version = v.ValueKind == JsonValueKind.String ? v.GetString() : v.GetRawText();
            }

            if (version != "1")
            {
                diagnostics.Add(new ConfigDiagnostic("UNSUPPORTED_VERSION",
                    $"Only testenvironments.json version \"1\" is supported; found {version ?? "<none>"}."));
            }

            if (root.TryGetProperty("environments", out var envs) && envs.ValueKind == JsonValueKind.Array)
            {
                var index = 0;
                foreach (var e in envs.EnumerateArray())
                {
                    index++;
                    var name = GetString(e, "name");
                    var rawType = GetString(e, "type") ?? "";
                    var type = ParseType(rawType);
                    var def = new EnvironmentDefinition
                    {
                        Name = name ?? $"<unnamed #{index}>",
                        Type = type,
                        RawType = rawType,
                        DockerImage = GetString(e, "dockerImage"),
                        DockerFile = GetString(e, "dockerFile"),
                        LocalRoot = GetString(e, "localRoot"),
                        WslDistribution = GetString(e, "wslDistribution"),
                        RemoteUri = GetString(e, "remoteUri"),
                    };
                    environments.Add(def);

                    if (string.IsNullOrWhiteSpace(name))
                    {
                        diagnostics.Add(new ConfigDiagnostic("MISSING_NAME", $"Environment #{index} has no name.", def.Name));
                    }

                    switch (type)
                    {
                        case EnvironmentType.Docker:
                            var hasImage = !string.IsNullOrWhiteSpace(def.DockerImage);
                            var hasFile = !string.IsNullOrWhiteSpace(def.DockerFile);
                            if (hasImage && hasFile)
                            {
                                diagnostics.Add(new ConfigDiagnostic("CONFLICTING_DOCKER_SOURCE",
                                    "A docker environment uses either dockerImage or dockerFile, not both.", def.Name));
                            }
                            else if (!hasImage && !hasFile)
                            {
                                diagnostics.Add(new ConfigDiagnostic("MISSING_DOCKER_SOURCE",
                                    "A docker environment requires dockerImage or dockerFile.", def.Name));
                            }

                            break;
                        case EnvironmentType.Wsl:
                        case EnvironmentType.Ssh:
                            diagnostics.Add(new ConfigDiagnostic("UNSUPPORTED_TYPE",
                                $"Environment type '{rawType}' is defined by Microsoft but not supported yet (Docker only).", def.Name));
                            break;
                        default:
                            diagnostics.Add(new ConfigDiagnostic("UNKNOWN_TYPE",
                                $"Unknown environment type '{rawType}'.", def.Name));
                            break;
                    }
                }
            }
        }

        return new TestEnvironmentsConfig
        {
            Version = version,
            Environments = environments,
            Diagnostics = diagnostics,
            SourcePath = sourcePath,
        };
    }

    private static string? GetString(JsonElement e, string name) =>
        e.TryGetProperty(name, out var v) && v.ValueKind == JsonValueKind.String ? v.GetString() : null;

    private static EnvironmentType ParseType(string raw) => raw.Trim().ToLowerInvariant() switch
    {
        "docker" => EnvironmentType.Docker,
        "wsl" => EnvironmentType.Wsl,
        "ssh" => EnvironmentType.Ssh,
        _ => EnvironmentType.Unknown,
    };
}

// ---------------------------------------------------------------------------------------------------
// Microsoft .NET release discovery (releases-index.json).
// The lifecycle status comes from the metadata itself — never from assumptions like "even = LTS" or
// "highest = preview". We treat support-phase and release-type as the contract.
// ---------------------------------------------------------------------------------------------------

internal sealed record ReleaseChannel
{
    public required string ChannelVersion { get; init; }
    public string? LatestRelease { get; init; }
    public string? LatestReleaseDate { get; init; }
    public string? LatestRuntime { get; init; }
    public string? LatestSdk { get; init; }
    public string SupportPhase { get; init; } = "";
    public string ReleaseType { get; init; } = "";
    public string? EolDate { get; init; }
    public string? Product { get; init; }

    public bool IsEol => string.Equals(SupportPhase, "eol", StringComparison.OrdinalIgnoreCase);
    public bool IsPreview => string.Equals(SupportPhase, "preview", StringComparison.OrdinalIgnoreCase)
        || string.Equals(SupportPhase, "go-live", StringComparison.OrdinalIgnoreCase);

    public bool IsLts => string.Equals(ReleaseType, "lts", StringComparison.OrdinalIgnoreCase);
    public bool IsSts => string.Equals(ReleaseType, "sts", StringComparison.OrdinalIgnoreCase);

    // A stable, supported channel: not EOL, not preview, and an LTS or STS release type.
    public bool IsSupportedStable => !IsEol && !IsPreview && (IsLts || IsSts);

    public int MajorVersion =>
        int.TryParse(ChannelVersion.Split('.')[0], NumberStyles.Integer, CultureInfo.InvariantCulture, out var m) ? m : 0;
}

internal sealed record ReleaseMetadata
{
    public IReadOnlyList<ReleaseChannel> Channels { get; init; } = [];
    public DateTimeOffset RetrievedAt { get; init; }
    public string Source { get; init; } = "";
    public bool IsStale { get; init; }

    public IReadOnlyList<ReleaseChannel> SupportedStableChannels =>
        [.. Channels.Where(c => c.IsSupportedStable).OrderByDescending(c => c.MajorVersion)];

    public IReadOnlyList<ReleaseChannel> PreviewChannels =>
        [.. Channels.Where(c => c.IsPreview && !c.IsEol).OrderByDescending(c => c.MajorVersion)];
}

internal static class ReleaseIndexReader
{
    public static IReadOnlyList<ReleaseChannel> Parse(string json)
    {
        var channels = new List<ReleaseChannel>();
        using var doc = JsonDocument.Parse(json);
        if (!doc.RootElement.TryGetProperty("releases-index", out var arr) || arr.ValueKind != JsonValueKind.Array)
        {
            return channels;
        }

        foreach (var e in arr.EnumerateArray())
        {
            var channelVersion = Str(e, "channel-version");
            if (string.IsNullOrWhiteSpace(channelVersion))
            {
                continue;
            }

            channels.Add(new ReleaseChannel
            {
                ChannelVersion = channelVersion,
                LatestRelease = Str(e, "latest-release"),
                LatestReleaseDate = Str(e, "latest-release-date"),
                LatestRuntime = Str(e, "latest-runtime"),
                LatestSdk = Str(e, "latest-sdk"),
                SupportPhase = Str(e, "support-phase") ?? "",
                ReleaseType = Str(e, "release-type") ?? "",
                EolDate = Str(e, "eol-date"),
                Product = Str(e, "product"),
            });
        }

        return channels;
    }

    private static string? Str(JsonElement e, string name) =>
        e.TryGetProperty(name, out var v) && v.ValueKind == JsonValueKind.String ? v.GetString() : null;
}

// A parsed .NET SDK version: major.minor.feature with an optional prerelease label such as
// "preview.6" or "rc.1". Build metadata (the trailing ".26359.118") is intentionally discarded because
// Microsoft's SDK container image tags do not include it.
internal sealed record SdkVersion(int Major, int Minor, int Feature, string? PreLabel, int? PreNumber, string Raw)
{
    private static readonly Regex Pattern = new(
        @"^(?<major>\d+)\.(?<minor>\d+)\.(?<feature>\d+)(?:-(?<pre>[a-zA-Z]+)\.(?<pren>\d+))?",
        RegexOptions.Compiled | RegexOptions.CultureInvariant);

    public bool IsPrerelease => PreLabel is not null;

    public static SdkVersion? TryParse(string? value)
    {
        if (string.IsNullOrWhiteSpace(value))
        {
            return null;
        }

        var m = Pattern.Match(value.Trim());
        if (!m.Success)
        {
            return null;
        }

        return new SdkVersion(
            int.Parse(m.Groups["major"].Value, CultureInfo.InvariantCulture),
            int.Parse(m.Groups["minor"].Value, CultureInfo.InvariantCulture),
            int.Parse(m.Groups["feature"].Value, CultureInfo.InvariantCulture),
            m.Groups["pre"].Success ? m.Groups["pre"].Value : null,
            m.Groups["pren"].Success ? int.Parse(m.Groups["pren"].Value, CultureInfo.InvariantCulture) : null,
            value.Trim());
    }

    // The image-compatible SDK tag. Stable: "10.0.302". Preview: "11.0.100-preview.6".
    public string ImageTag => IsPrerelease
        ? $"{Major}.{Minor}.{Feature}-{PreLabel}.{PreNumber}"
        : $"{Major}.{Minor}.{Feature}";

    public string ChannelTag => $"{Major}.{Minor}";
}

internal static class ImageTagResolver
{
    // Ordered candidate tags for an SDK. The exact SDK-version tag is preferred over the moving channel
    // tag so an execution pins to a specific SDK rather than "whatever the channel points at today".
    public static IReadOnlyList<string> CandidateTags(SdkVersion sdk)
    {
        var tags = new List<string> { sdk.ImageTag };
        if (!tags.Contains(sdk.ChannelTag))
        {
            tags.Add(sdk.ChannelTag);
        }

        return tags;
    }

    public static string SdkImageReference(string tag) => $"{RemoteTestProgram.SdkRepository}:{tag}";
}

// ---------------------------------------------------------------------------------------------------
// Multi-SDK runner discovery (codebeltnet/ubuntu-testrunner).
//
// A Microsoft SDK image contains one runtime. That is fine for a single-target repository, but a
// repository multi-targeting several .NET majors can only *build* the lower targets there — executing
// their tests needs the matching runtimes. The Codebelt runner publishes combined tags ("8-9-10-11")
// carrying several SDKs, so the whole target-framework matrix runs in one container.
//
// The available tags are discovered from the published tag feed at runtime. Nothing here is hardcoded:
// when a new major joins the combined tags, it is picked up without a skill change.
// ---------------------------------------------------------------------------------------------------

internal sealed record MultiSdkRunner
{
    public required string Tag { get; init; }
    public IReadOnlyList<int> Majors { get; init; } = [];

    public string Reference => $"{RemoteTestProgram.MultiSdkRepository}:{Tag}";

    public bool Covers(IReadOnlyList<int> requiredMajors) => requiredMajors.All(Majors.Contains);
}

internal static class MultiSdkTagReader
{
    // Only the major-only combined form ("8-9-10-11") is used. It is a moving tag that tracks the
    // current patch of each major, and it is the form the publisher documents for consumers. Single
    // majors ("10"), channel forms ("10.0"), and fully pinned combinations are deliberately ignored
    // here — single majors are already covered by Microsoft's images.
    private static readonly Regex CombinedMajorTag = new(@"^\d+(?:-\d+)+$", RegexOptions.Compiled);

    public static IReadOnlyList<MultiSdkRunner> Parse(string json)
    {
        var runners = new List<MultiSdkRunner>();
        JsonDocument document;
        try
        {
            document = JsonDocument.Parse(json);
        }
        catch (JsonException)
        {
            return runners;
        }

        using (document)
        {
            if (!document.RootElement.TryGetProperty("results", out var results) ||
                results.ValueKind != JsonValueKind.Array)
            {
                return runners;
            }

            foreach (var entry in results.EnumerateArray())
            {
                if (!entry.TryGetProperty("name", out var nameElement) ||
                    nameElement.GetString() is not { } name ||
                    !CombinedMajorTag.IsMatch(name))
                {
                    continue;
                }

                var majors = new List<int>();
                var usable = true;
                foreach (var part in name.Split('-'))
                {
                    if (int.TryParse(part, NumberStyles.Integer, CultureInfo.InvariantCulture, out var major) && major > 0)
                    {
                        majors.Add(major);
                    }
                    else
                    {
                        usable = false;
                        break;
                    }
                }

                if (usable && majors.Count > 1)
                {
                    runners.Add(new MultiSdkRunner { Tag = name, Majors = [.. majors.Distinct().OrderBy(m => m)] });
                }
            }
        }

        return runners;
    }

    // Tightest fit wins: the fewest extra SDKs that still cover every required major. Ties break on the
    // tag name so the same repository always resolves to the same image.
    public static MultiSdkRunner? Select(IReadOnlyList<MultiSdkRunner> runners, IReadOnlyList<int> requiredMajors)
    {
        if (requiredMajors.Count < 2)
        {
            return null;
        }

        return runners
            .Where(r => r.Covers(requiredMajors))
            .OrderBy(r => r.Majors.Count)
            .ThenBy(r => r.Tag, StringComparer.Ordinal)
            .FirstOrDefault();
    }
}

internal sealed record MultiSdkResult(IReadOnlyList<MultiSdkRunner> Runners, string? Error);

internal static class MultiSdkRunnerStore
{
    private static readonly HttpClient Http = new() { Timeout = TimeSpan.FromSeconds(15) };

    private static string CacheFile(string cacheRoot) => Path.Combine(cacheRoot, "multi-sdk-tags.cache.json");

    public static async Task<MultiSdkResult> LoadAsync(Options options, CancellationToken ct)
    {
        // An explicit local file is a deliberate input (used by the deterministic test harness).
        if (!string.IsNullOrWhiteSpace(options.MultiSdkTagsFile))
        {
            return File.Exists(options.MultiSdkTagsFile)
                ? new MultiSdkResult(MultiSdkTagReader.Parse(await File.ReadAllTextAsync(options.MultiSdkTagsFile, ct)), null)
                : new MultiSdkResult([], $"multi-SDK tags file not found: {options.MultiSdkTagsFile}");
        }

        var cacheFile = CacheFile(options.CacheDirectory);
        if (options.Offline)
        {
            return LoadFromCache(cacheFile, "Offline mode: ");
        }

        try
        {
            var json = await Http.GetStringAsync(RemoteTestProgram.MultiSdkTagsUrl, ct);
            var runners = MultiSdkTagReader.Parse(json);
            if (runners.Count == 0)
            {
                return LoadFromCache(cacheFile, "Multi-SDK tag feed returned no combined tags: ");
            }

            TryWriteCache(cacheFile, json);
            return new MultiSdkResult(runners, null);
        }
        catch (Exception ex) when (ex is HttpRequestException or TaskCanceledException or IOException)
        {
            return LoadFromCache(cacheFile, $"Could not reach the multi-SDK tag feed ({ex.Message}); ");
        }
    }

    private static MultiSdkResult LoadFromCache(string cacheFile, string prefix)
    {
        if (!File.Exists(cacheFile))
        {
            return new MultiSdkResult([], prefix + "no cached multi-SDK runner tags are available.");
        }

        try
        {
            return new MultiSdkResult(MultiSdkTagReader.Parse(File.ReadAllText(cacheFile)), null);
        }
        catch (IOException ex)
        {
            return new MultiSdkResult([], prefix + $"the cached multi-SDK runner tags could not be read ({ex.Message}).");
        }
    }

    private static void TryWriteCache(string cacheFile, string json)
    {
        try
        {
            Directory.CreateDirectory(Path.GetDirectoryName(cacheFile)!);
            File.WriteAllText(cacheFile, json);
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
        {
            // Caching is an optimization; never fail discovery because the cache could not be written.
        }
    }
}

// ---------------------------------------------------------------------------------------------------
// Environment resolution.
// A resolved environment is what the runner actually executes against, whether it came from
// testenvironments.json or was generated from Microsoft release metadata.
// ---------------------------------------------------------------------------------------------------

internal enum EnvironmentOrigin { Configured, Generated }

internal sealed record ResolvedEnvironment
{
    public required string Name { get; init; }
    public EnvironmentOrigin Origin { get; init; }
    public string? Channel { get; init; }
    public string? ReleaseType { get; init; }   // LTS / STS / Preview (for generated) 
    public string? Sdk { get; init; }

    // Exactly one of these is set for a runnable Docker environment.
    public string? DockerImage { get; init; }
    public string? DockerFile { get; init; }

    public string? LocalRoot { get; init; }

    // The .NET majors this environment can both build and *run*. Empty means "single SDK, inferred from
    // Channel/Sdk". A multi-SDK runner states them explicitly, which is what makes it usable for a
    // repository whose target frameworks span several majors.
    public IReadOnlyList<int> SupportedMajors { get; init; } = [];

    public bool IsMultiSdk => SupportedMajors.Count > 1;

    // Whether this environment's image came from the repository's own configuration rather than being
    // generated. Configured images are deliberate intent and are always used exactly as written.
    public bool ImageIsConfigured => Origin == EnvironmentOrigin.Configured;

    // The .NET major version this environment's channel represents ("10.0" -> 10), or 0 when the channel
    // is unknown (configured environments carry no channel).
    public int ChannelMajor
    {
        get
        {
            if (string.IsNullOrWhiteSpace(Channel))
            {
                return 0;
            }

            var head = Channel.Split('.')[0];
            return int.TryParse(head, NumberStyles.Integer, CultureInfo.InvariantCulture, out var major) && major > 0
                ? major
                : 0;
        }
    }
}

internal static class GeneratedEnvironments
{
    // Turn Microsoft release metadata into ready-to-run zero-configuration environments. No files are
    // ever written to the repository to make these exist.
    public static IReadOnlyList<ResolvedEnvironment> FromMetadata(ReleaseMetadata metadata)
    {
        var result = new List<ResolvedEnvironment>();

        foreach (var c in metadata.SupportedStableChannels)
        {
            var sdk = SdkVersion.TryParse(c.LatestSdk);
            var suffix = c.IsLts ? "lts" : "sts";
            result.Add(new ResolvedEnvironment
            {
                Name = $"dotnet-{c.MajorVersion}-{suffix}",
                Origin = EnvironmentOrigin.Generated,
                Channel = c.ChannelVersion,
                ReleaseType = c.ReleaseType.ToUpperInvariant(),
                Sdk = c.LatestSdk,
                DockerImage = sdk is null ? null : ImageTagResolver.SdkImageReference(sdk.ImageTag),
            });
        }

        foreach (var c in metadata.PreviewChannels)
        {
            var sdk = SdkVersion.TryParse(c.LatestSdk);
            result.Add(new ResolvedEnvironment
            {
                Name = $"dotnet-{c.MajorVersion}-preview",
                Origin = EnvironmentOrigin.Generated,
                Channel = c.ChannelVersion,
                ReleaseType = "Preview",
                Sdk = c.LatestSdk,
                DockerImage = sdk is null ? null : ImageTagResolver.SdkImageReference(sdk.ImageTag),
            });
        }

        return result;
    }

    // A multi-SDK runner environment. It carries no single channel: its value is that every listed major
    // is present, so a multi-targeted repository runs its whole matrix in one container.
    public static ResolvedEnvironment FromMultiSdkRunner(MultiSdkRunner runner) => new()
    {
        Name = $"ubuntu-testrunner-{runner.Tag}",
        Origin = EnvironmentOrigin.Generated,
        ReleaseType = "Multi-SDK",
        DockerImage = runner.Reference,
        SupportedMajors = runner.Majors,
    };

    public static ResolvedEnvironment FromConfigured(EnvironmentDefinition def) => new()
    {
        Name = def.Name,
        Origin = EnvironmentOrigin.Configured,
        DockerImage = def.DockerImage,
        DockerFile = def.DockerFile,
        LocalRoot = def.LocalRoot,
    };
}

internal enum ResolutionStatus { Resolved, NotFound, Ambiguous, Unsupported, NoEnvironments }

internal sealed record EnvironmentResolution
{
    public ResolutionStatus Status { get; init; }
    public ResolvedEnvironment? Environment { get; init; }
    public IReadOnlyList<string> Candidates { get; init; } = [];
    public string? Message { get; init; }

    // Why this environment was chosen when the caller did not name one. Surfaced so an automatic
    // selection is always explainable rather than looking arbitrary.
    public string? SelectionReason { get; init; }
}

internal static class EnvironmentResolver
{
    // Deterministic precedence:
    //   1. An environment explicitly named by the user (configured first, then generated).
    //   2. An applicable Docker environment from testenvironments.json (authoritative when present).
    //   3. Microsoft-derived environments when no testenvironments.json exists. When several are
    //      derived, the repository's own highest .NET target framework picks exactly one of them
    //      (see SelectByTargetFramework) so "run my tests" does not need a question to answer.
    public static EnvironmentResolution Resolve(
        TestEnvironmentsConfig? config,
        IReadOnlyList<ResolvedEnvironment> generated,
        string? requestedName,
        TargetFrameworkInfo? repoTargets = null)
    {
        var configured = config?.SupportedDockerEnvironments ?? [];

        if (!string.IsNullOrWhiteSpace(requestedName))
        {
            var byConfig = configured.FirstOrDefault(e =>
                string.Equals(e.Name, requestedName, StringComparison.OrdinalIgnoreCase));
            if (byConfig is not null)
            {
                return Resolved(GeneratedEnvironments.FromConfigured(byConfig));
            }

            // A configured but unsupported environment was named explicitly: report it as unsupported
            // rather than pretending it does not exist.
            var unsupported = config?.UnsupportedEnvironments.FirstOrDefault(e =>
                string.Equals(e.Name, requestedName, StringComparison.OrdinalIgnoreCase));
            if (unsupported is not null)
            {
                return new EnvironmentResolution
                {
                    Status = ResolutionStatus.Unsupported,
                    Message = $"Environment '{requestedName}' has unsupported type '{unsupported.RawType}'. Only Docker is supported.",
                };
            }

            var byGenerated = generated.FirstOrDefault(e =>
                string.Equals(e.Name, requestedName, StringComparison.OrdinalIgnoreCase));
            if (byGenerated is not null)
            {
                return Resolved(byGenerated);
            }

            return new EnvironmentResolution
            {
                Status = ResolutionStatus.NotFound,
                Candidates = [.. configured.Select(e => e.Name), .. generated.Select(e => e.Name)],
                Message = $"No environment named '{requestedName}' was found.",
            };
        }

        // No explicit name. If testenvironments.json exists, it is authoritative — do not supplement it
        // with generated environments.
        if (config is not null && config.SourcePath is not null)
        {
            if (configured.Count == 1)
            {
                return Resolved(GeneratedEnvironments.FromConfigured(configured[0]));
            }

            if (configured.Count > 1)
            {
                return new EnvironmentResolution
                {
                    Status = ResolutionStatus.Ambiguous,
                    Candidates = [.. configured.Select(e => e.Name)],
                    Message = "Multiple Docker environments are configured. Select one with --environment <name>.",
                };
            }

            // A config exists but defines no usable Docker environment.
            return new EnvironmentResolution
            {
                Status = ResolutionStatus.NoEnvironments,
                Message = "testenvironments.json defines no supported Docker environment.",
            };
        }

        // Zero-configuration: use Microsoft-derived environments.
        if (generated.Count == 0)
        {
            return new EnvironmentResolution
            {
                Status = ResolutionStatus.NoEnvironments,
                Message = "No environments could be derived from Microsoft release metadata.",
            };
        }

        if (generated.Count == 1)
        {
            return Resolved(generated[0]);
        }

        // Several channels are available. The repository already states which .NET it targets, so use
        // that instead of asking a question the source code has already answered.
        var byTargetFramework = SelectByTargetFramework(generated, repoTargets);
        if (byTargetFramework is not null)
        {
            return byTargetFramework;
        }

        return new EnvironmentResolution
        {
            Status = ResolutionStatus.Ambiguous,
            Candidates = [.. generated.Select(e => e.Name)],
            Message = "Multiple Microsoft-derived environments are available. Select one with --environment <name>.",
        };
    }

    // Deterministic tie-break: the repository's highest .NET target framework major must match exactly
    // one derived channel. Highest wins because an SDK builds its own major and every lower one, so the
    // newest target is the only channel guaranteed to build the whole repository.
    //
    // This deliberately does not "pick something close". No target frameworks, no .NET target (only
    // netstandard/net48), or more than one channel for the same major all fall through to a question —
    // guessing an SDK the repository never asked for is worse than asking once.
    private static EnvironmentResolution? SelectByTargetFramework(
        IReadOnlyList<ResolvedEnvironment> generated,
        TargetFrameworkInfo? repoTargets)
    {
        if (repoTargets is null)
        {
            return null;
        }

        var majors = repoTargets.NetCoreMajors;
        if (majors.Count == 0)
        {
            return null;
        }

        // Multi-targeted repositories need every runtime present, not just the newest SDK, so a runner
        // covering the whole matrix wins outright when one is available.
        if (majors.Count > 1)
        {
            var covering = generated.Where(e => e.IsMultiSdk && majors.All(e.SupportedMajors.Contains)).ToList();
            if (covering.Count == 0)
            {
                return null;
            }

            var runner = covering
                .OrderBy(e => e.SupportedMajors.Count)
                .ThenBy(e => e.Name, StringComparer.Ordinal)
                .First();

            var targeted = string.Join(", ", majors.Select(m => $"net{m}.0"));
            return Resolved(runner) with
            {
                SelectionReason =
                    $"Selected automatically: the repository targets {targeted}, and this runner provides every one of them, "
                    + "so the whole target-framework matrix runs in a single container.",
            };
        }

        var targetMajor = majors.Max();
        var matches = generated.Where(e => !e.IsMultiSdk && e.ChannelMajor == targetMajor).ToList();
        if (matches.Count != 1)
        {
            return null;
        }

        var tfm = repoTargets.TargetFrameworks
            .FirstOrDefault(t => TargetFrameworkInspector.NetMajor(t) == targetMajor) ?? $"net{targetMajor}.0";

        return Resolved(matches[0]) with
        {
            SelectionReason = $"Selected automatically: the only environment matching the repository's target framework '{tfm}'.",
        };
    }

    private static EnvironmentResolution Resolved(ResolvedEnvironment env) =>
        new() { Status = ResolutionStatus.Resolved, Environment = env };
}

// ---------------------------------------------------------------------------------------------------
// Target-framework awareness.
// We must not pick an SDK that cannot build the requested target framework, and we must respect an
// existing global.json rather than modifying it. We never rewrite project files or TFMs.
// ---------------------------------------------------------------------------------------------------

internal sealed record TargetFrameworkInfo
{
    public IReadOnlyList<string> TargetFrameworks { get; init; } = [];
    public string? GlobalJsonSdkVersion { get; init; }
    public string? GlobalJsonRollForward { get; init; }

    public IReadOnlyList<int> NetCoreMajors =>
        [.. TargetFrameworks.Select(TargetFrameworkInspector.NetMajor).Where(m => m > 0).Distinct().OrderBy(m => m)];

    public bool HasNetFramework => TargetFrameworks.Any(t =>
        t.StartsWith("net4", StringComparison.OrdinalIgnoreCase)
        || t.StartsWith("net3", StringComparison.OrdinalIgnoreCase) && !t.Contains('.'));
}

internal sealed record SdkCompatibility(bool Compatible, string? Reason);

internal static class TargetFrameworkInspector
{
    private static readonly Regex TfmRegex = new(
        @"<TargetFrameworks?>(?<v>[^<]+)</TargetFrameworks?>",
        RegexOptions.Compiled | RegexOptions.IgnoreCase);

    // netX.0 / netcoreappX.0 → X; netstandard/net4x → 0 (not a modern runnable major).
    public static int NetMajor(string tfm)
    {
        tfm = tfm.Trim();
        var m = Regex.Match(tfm, @"^net(?:coreapp)?(?<maj>\d+)\.\d+", RegexOptions.IgnoreCase);
        return m.Success ? int.Parse(m.Groups["maj"].Value, CultureInfo.InvariantCulture) : 0;
    }

    public static IReadOnlyList<string> ExtractTargetFrameworks(string projectXml)
    {
        var set = new List<string>();
        foreach (Match m in TfmRegex.Matches(projectXml))
        {
            foreach (var tfm in m.Groups["v"].Value.Split(';', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries))
            {
                if (!tfm.Contains("$(") && !set.Contains(tfm))
                {
                    set.Add(tfm);
                }
            }
        }

        return set;
    }

    public static (string? sdkVersion, string? rollForward) ParseGlobalJson(string json)
    {
        try
        {
            using var doc = JsonDocument.Parse(json);
            if (doc.RootElement.TryGetProperty("sdk", out var sdk) && sdk.ValueKind == JsonValueKind.Object)
            {
                var version = sdk.TryGetProperty("version", out var v) && v.ValueKind == JsonValueKind.String ? v.GetString() : null;
                var roll = sdk.TryGetProperty("rollForward", out var r) && r.ValueKind == JsonValueKind.String ? r.GetString() : null;
                return (version, roll);
            }
        }
        catch (JsonException)
        {
            // A malformed global.json is reported at execution time by the SDK; we do not fail discovery on it.
        }

        return (null, null);
    }

    // Inspect the source root for target frameworks and an optional global.json.
    public static TargetFrameworkInfo Inspect(string sourceRoot, string? project)
    {
        var frameworks = new List<string>();
        IEnumerable<string> projectFiles;
        if (!string.IsNullOrWhiteSpace(project))
        {
            var full = Path.IsPathRooted(project) ? project : Path.Combine(sourceRoot, project);
            projectFiles = File.Exists(full) ? [full] : [];
        }
        else
        {
            projectFiles = SafeEnumerate(sourceRoot, "*.csproj");
        }

        foreach (var file in projectFiles)
        {
            try
            {
                foreach (var tfm in ExtractTargetFrameworks(File.ReadAllText(file)))
                {
                    if (!frameworks.Contains(tfm))
                    {
                        frameworks.Add(tfm);
                    }
                }
            }
            catch (IOException)
            {
                // Ignore unreadable project files; discovery is best-effort.
            }
        }

        string? sdkVersion = null, rollForward = null;
        var globalJson = Path.Combine(sourceRoot, "global.json");
        if (File.Exists(globalJson))
        {
            (sdkVersion, rollForward) = ParseGlobalJson(File.ReadAllText(globalJson));
        }

        return new TargetFrameworkInfo
        {
            TargetFrameworks = frameworks,
            GlobalJsonSdkVersion = sdkVersion,
            GlobalJsonRollForward = rollForward,
        };
    }

    // Can a channel (identified by its SDK version) build these target frameworks? An SDK builds its own
    // major and every lower one; it cannot build a newer runtime major, and the Linux SDK cannot build
    // .NET Framework (net4x) targets.
    public static SdkCompatibility CanBuild(
        SdkVersion? channelSdk,
        TargetFrameworkInfo tfms,
        IReadOnlyList<int>? supportedMajors = null)
    {
        if (tfms.HasNetFramework)
        {
            return new SdkCompatibility(false,
                "The project targets .NET Framework (net4x), which cannot be built by a Linux .NET SDK container.");
        }

        // An environment that states its majors explicitly (a multi-SDK runner) is judged on that list:
        // every target framework must be present, because presence is what allows the tests to run.
        if (supportedMajors is { Count: > 0 })
        {
            var missing = tfms.NetCoreMajors.Where(m => !supportedMajors.Contains(m)).ToList();
            return missing.Count == 0
                ? new SdkCompatibility(true, null)
                : new SdkCompatibility(false,
                    $"The project targets {string.Join(", ", missing.Select(m => $"net{m}.0"))}, which the selected image does not provide.");
        }

        if (channelSdk is null)
        {
            return new SdkCompatibility(false, "The environment SDK version could not be determined.");
        }

        foreach (var major in tfms.NetCoreMajors)
        {
            if (major > channelSdk.Major)
            {
                return new SdkCompatibility(false,
                    $"The project targets net{major}.0 but the selected SDK is {channelSdk.Major}.x and cannot build a newer runtime.");
            }
        }

        // A single-SDK image ships exactly one runtime. Lower target frameworks compile there but have
        // no runtime to execute on, so a multi-targeted repository needs a multi-SDK runner instead of
        // a silently doomed run.
        var unrunnable = tfms.NetCoreMajors.Where(m => m != channelSdk.Major).ToList();
        if (unrunnable.Count > 0)
        {
            return new SdkCompatibility(false,
                $"The project targets {string.Join(", ", unrunnable.Select(m => $"net{m}.0"))} in addition to net{channelSdk.Major}.0, "
                + $"but the selected image ships only the {channelSdk.Major}.x runtime. Use a multi-SDK runner image "
                + $"({RemoteTestProgram.MultiSdkRepository}) or restrict the run with --framework.");
        }

        // Honor an explicit global.json pin: the container SDK major must satisfy it.
        var pinned = SdkVersion.TryParse(tfms.GlobalJsonSdkVersion);
        if (pinned is not null
            && string.Equals(tfms.GlobalJsonRollForward, "disable", StringComparison.OrdinalIgnoreCase)
            && (pinned.Major != channelSdk.Major || pinned.Minor != channelSdk.Minor || pinned.Feature != channelSdk.Feature))
        {
            return new SdkCompatibility(false,
                $"global.json pins SDK {pinned.Raw} with rollForward disabled, which the selected image SDK {channelSdk.Raw} does not satisfy.");
        }

        if (pinned is not null && pinned.Major > channelSdk.Major)
        {
            return new SdkCompatibility(false,
                $"global.json requires SDK {pinned.Major}.x but the selected image provides {channelSdk.Major}.x.");
        }

        return new SdkCompatibility(true, null);
    }

    private static IEnumerable<string> SafeEnumerate(string root, string pattern)
    {
        if (!Directory.Exists(root))
        {
            return [];
        }

        try
        {
            return Directory.EnumerateFiles(root, pattern, new EnumerationOptions
            {
                RecurseSubdirectories = true,
                IgnoreInaccessible = true,
                MatchCasing = MatchCasing.CaseInsensitive,
            }).Where(p => !p.Contains($"{Path.DirectorySeparatorChar}bin{Path.DirectorySeparatorChar}")
                && !p.Contains($"{Path.DirectorySeparatorChar}obj{Path.DirectorySeparatorChar}"));
        }
        catch (IOException)
        {
            return [];
        }
    }
}

// ---------------------------------------------------------------------------------------------------
// Container command planning.
// The docker command line and the in-container entrypoint are built here as pure functions so the plan
// can be asserted deterministically (and printed by `plan`) without ever launching Docker.
// ---------------------------------------------------------------------------------------------------

internal sealed record ContainerMount(string HostPath, string ContainerPath, bool ReadOnly);

internal sealed record TestCommandOptions
{
    public string? Target { get; init; }
    public string Configuration { get; init; } = "Debug";
    public string? Framework { get; init; }
    public string? Filter { get; init; }
    public bool Coverage { get; init; }
    public string WorkDir { get; init; } = "/workspace";
    public string NuGetDir { get; init; } = "/nuget";
    public string ResultsDir { get; init; } = "/results";
}

internal sealed record ContainerPlan
{
    public required string Image { get; init; }
    public required string ContainerName { get; init; }
    public required IReadOnlyList<ContainerMount> Mounts { get; init; }
    public required IReadOnlyDictionary<string, string> Environment { get; init; }
    public required string Entrypoint { get; init; }
    public required IReadOnlyList<string> DockerRunArgs { get; init; }
}

internal static class ContainerPlanner
{
    internal const string PhaseMarkerPrefix = "##RT_PHASE_END:";

    // Resolve the dotnet test --filter expression. --test is sugar for a FullyQualifiedName contains match.
    public static string? ResolveFilter(string? filter, string? test)
    {
        if (!string.IsNullOrWhiteSpace(filter))
        {
            return filter;
        }

        return string.IsNullOrWhiteSpace(test) ? null : $"FullyQualifiedName~{test}";
    }

    // NuGet's package root becomes an MSBuild SourceRoot, and SourceLink rejects a SourceRoot that does
    // not end in a separator ("SourceRoot paths are required to end with a slash or backslash"). The
    // mount target stays clean; only the environment value carries the trailing slash.
    public static string NuGetPackagesPath(string containerDir) =>
        containerDir.EndsWith('/') ? containerDir : containerDir + "/";

    // The in-container script. Phases run in order; each emits a machine-readable end marker with its
    // exit code so the host can classify restore vs build vs test outcomes precisely. restore/build stop
    // the run on failure; test always runs to completion so a TRX is produced even when tests fail.
    public static string BuildEntrypoint(TestCommandOptions o)
    {
        var target = string.IsNullOrWhiteSpace(o.Target) ? "" : $" {Shell.Quote(o.Target)}";
        var fw = string.IsNullOrWhiteSpace(o.Framework) ? "" : $" --framework {Shell.Quote(o.Framework)}";
        var cfg = $" -c {Shell.Quote(o.Configuration)}";
        var filter = string.IsNullOrWhiteSpace(o.Filter) ? "" : $" --filter {Shell.Quote(o.Filter)}";
        var coverage = o.Coverage ? " --collect \"XPlat Code Coverage\"" : "";

        var sb = new StringBuilder();
        sb.Append("set -o pipefail\n");
        sb.Append($"export NUGET_PACKAGES={Shell.Quote(NuGetPackagesPath(o.NuGetDir))}\n");
        sb.Append("export DOTNET_CLI_TELEMETRY_OPTOUT=1\n");
        sb.Append("export DOTNET_NOLOGO=1\n");
        sb.Append("export DOTNET_SKIP_FIRST_TIME_EXPERIENCE=1\n");
        sb.Append($"cd {Shell.Quote(o.WorkDir)} || {{ echo '{PhaseMarkerPrefix}staging:1##'; exit 8; }}\n");
        sb.Append("run_phase() { name=\"$1\"; shift; \"$@\"; code=$?; echo \"" + PhaseMarkerPrefix + "${name}:${code}##\"; return $code; }\n");
        sb.Append($"run_phase restore dotnet restore{target}{fw} || exit 9\n");
        sb.Append($"run_phase build dotnet build{target}{cfg}{fw} --no-restore || exit 10\n");
        sb.Append($"run_phase test dotnet test{target}{cfg}{fw} --no-build{filter}{coverage} --results-directory {Shell.Quote(o.ResultsDir)} --logger trx\n");
        sb.Append("exit $?\n");
        return sb.ToString();
    }

    public static ContainerPlan Build(
        string image,
        string containerName,
        IReadOnlyList<ContainerMount> mounts,
        TestCommandOptions test)
    {
        var env = new Dictionary<string, string>
        {
            ["DOTNET_CLI_TELEMETRY_OPTOUT"] = "1",
            ["DOTNET_NOLOGO"] = "1",
            ["NUGET_PACKAGES"] = NuGetPackagesPath(test.NuGetDir),
        };

        var entrypoint = BuildEntrypoint(test);
        var args = new List<string> { "run", "--rm", "--name", containerName, "-w", test.WorkDir };

        // Security posture: no --privileged, no docker socket, no host profile mount, no port publishing.
        foreach (var m in mounts)
        {
            var spec = $"type=bind,source={m.HostPath},target={m.ContainerPath}";
            if (m.ReadOnly)
            {
                spec += ",readonly";
            }

            args.Add("--mount");
            args.Add(spec);
        }

        foreach (var (k, v) in env)
        {
            args.Add("-e");
            args.Add($"{k}={v}");
        }

        args.Add(image);
        args.Add("bash");
        args.Add("-c");
        args.Add(entrypoint);

        return new ContainerPlan
        {
            Image = image,
            ContainerName = containerName,
            Mounts = mounts,
            Environment = env,
            Entrypoint = entrypoint,
            DockerRunArgs = args,
        };
    }

    // A deterministic, knowable container name so cancellation and cleanup can always target it.
    public static string ContainerName(string runId) =>
        $"dotnet-remote-testing-{runId}";
}

internal static class Shell
{
    // Minimal POSIX single-quote quoting for values embedded in the container bash script.
    public static string Quote(string value) =>
        "'" + value.Replace("'", "'\\''", StringComparison.Ordinal) + "'";
}

// Only Microsoft-derived (generated) environments block on an SDK/target-framework incompatibility,
// because their SDK version is known from release metadata. A configured environment's image SDK is not
// statically known, so it is trusted as provided and validated at run time rather than failing planning.
internal static class SdkCompatibilityPolicy
{
    public static bool IsBlocking(EnvironmentOrigin origin, bool compatible) =>
        origin == EnvironmentOrigin.Generated && !compatible;
}

// Resolve the dotnet test target (project/solution) as a container-relative, forward-slashed path.
// Preference: explicit --project, then a solution at the source root, then a single solution anywhere,
// then a single project anywhere. Null means "let dotnet discover in the working directory".
internal static class TargetResolver
{
    public static string? Resolve(string sourceRoot, string? project)
    {
        if (!string.IsNullOrWhiteSpace(project))
        {
            return project.Replace('\\', '/');
        }

        if (!Directory.Exists(sourceRoot))
        {
            return null;
        }

        var rootSolution = TopLevel(sourceRoot, "*.slnx").Concat(TopLevel(sourceRoot, "*.sln")).FirstOrDefault();
        if (rootSolution is not null)
        {
            return Relative(sourceRoot, rootSolution);
        }

        var solutions = Recursive(sourceRoot, "*.slnx").Concat(Recursive(sourceRoot, "*.sln")).ToList();
        if (solutions.Count == 1)
        {
            return Relative(sourceRoot, solutions[0]);
        }

        if (solutions.Count == 0)
        {
            var projects = Recursive(sourceRoot, "*.csproj").ToList();
            if (projects.Count == 1)
            {
                return Relative(sourceRoot, projects[0]);
            }
        }

        return null;
    }

    private static IEnumerable<string> TopLevel(string root, string pattern) =>
        Directory.EnumerateFiles(root, pattern, SearchOption.TopDirectoryOnly);

    private static IEnumerable<string> Recursive(string root, string pattern) =>
        Directory.EnumerateFiles(root, pattern, new EnumerationOptions
        {
            RecurseSubdirectories = true,
            IgnoreInaccessible = true,
        }).Where(p => !p.Contains($"{Path.DirectorySeparatorChar}bin{Path.DirectorySeparatorChar}")
            && !p.Contains($"{Path.DirectorySeparatorChar}obj{Path.DirectorySeparatorChar}"));

    private static string Relative(string root, string path) =>
        Path.GetRelativePath(root, path).Replace('\\', '/');
}

// ---------------------------------------------------------------------------------------------------
// TRX result parsing.
// dotnet test writes Visual Studio TRX. We aggregate every TRX produced (multi-targeted test projects
// emit one per TFM) into a single structured result, prioritizing actionable failure detail.
// ---------------------------------------------------------------------------------------------------

// One failing test, with everything `dotnet test` would have printed about it: where it lives, what it
// asserted, where it threw, and whatever the test itself wrote to the output helper.
internal sealed record TestFailureDetail(
    string TestName,
    string? ClassName,
    string? Message,
    string? StackTrace,
    string? Output = null,
    string? Assembly = null,
    string? Framework = null,
    double DurationSeconds = 0);

// One test assembly/TFM pair — the unit `dotnet test` reports a Passed!/Failed! line for.
internal sealed record TestAssemblyResult(
    string Assembly,
    string? Framework,
    int Total,
    int Passed,
    int Failed,
    int Skipped,
    double DurationSeconds)
{
    public string Display => Framework is null ? Assembly : $"{Assembly} ({Framework})";
}

internal sealed record TestRunResult
{
    public int Total { get; init; }
    public int Passed { get; init; }
    public int Failed { get; init; }
    public int Skipped { get; init; }
    public int NotExecuted { get; init; }
    public double DurationSeconds { get; init; }
    public IReadOnlyList<TestFailureDetail> Failures { get; init; } = [];
    public IReadOnlyList<TestAssemblyResult> Assemblies { get; init; } = [];
    public int TrxFilesParsed { get; init; }

    public static TestRunResult Empty => new();

    public TestRunResult Merge(TestRunResult other) => new()
    {
        Total = Total + other.Total,
        Passed = Passed + other.Passed,
        Failed = Failed + other.Failed,
        Skipped = Skipped + other.Skipped,
        NotExecuted = NotExecuted + other.NotExecuted,
        DurationSeconds = DurationSeconds + other.DurationSeconds,
        Failures = [.. Failures, .. other.Failures],
        Assemblies = [.. Assemblies, .. other.Assemblies],
        TrxFilesParsed = TrxFilesParsed + other.TrxFilesParsed,
    };
}

// VSTest records the test assembly's path in lower case, so a TRX alone would report
// "acme.tests.dll" for an assembly the developer knows as "Acme.Tests.dll". The repository's own
// project files carry the authoritative casing.
internal static class AssemblyNameIndex
{
    private static readonly string[] ProjectPatterns = ["*.csproj", "*.fsproj", "*.vbproj"];

    public static IReadOnlyDictionary<string, string> Build(string sourceRoot)
    {
        var map = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        if (!Directory.Exists(sourceRoot))
        {
            return map;
        }

        foreach (var pattern in ProjectPatterns)
        {
            IEnumerable<string> files;
            try
            {
                files = Directory.EnumerateFiles(sourceRoot, pattern, SearchOption.AllDirectories);
            }
            catch (Exception)
            {
                continue;
            }

            foreach (var project in files)
            {
                var name = Path.GetFileNameWithoutExtension(project) + ".dll";
                map[name] = name;
            }
        }

        return map;
    }
}

internal static class TrxParser
{
    private static readonly XNamespace Ns = "http://microsoft.com/schemas/VisualStudio/TeamTest/2010";

    public static TestRunResult ParseFile(string path, IReadOnlyDictionary<string, string>? assemblyNames = null) =>
        Parse(File.ReadAllText(path), assemblyNames);

    public static TestRunResult Parse(string trxXml, IReadOnlyDictionary<string, string>? assemblyNames = null)
    {
        var doc = XDocument.Parse(trxXml);
        var root = doc.Root ?? throw new InvalidOperationException("TRX has no root element.");

        // Map testId -> class name / storage via TestDefinitions so failures carry their owning class and
        // the assembly they came from. Multi-targeted projects emit one TRX per TFM, and only the storage
        // path distinguishes them.
        var classById = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        string? storage = null;
        string? classAssembly = null;
        foreach (var ut in root.Descendants(Ns + "UnitTest"))
        {
            var id = ut.Attribute("id")?.Value;
            var className = ut.Element(Ns + "TestMethod")?.Attribute("className")?.Value;
            if (className is not null)
            {
                var parts = className.Split(',', 2);
                if (id is not null)
                {
                    classById[id] = parts[0];
                }

                if (classAssembly is null && parts.Length == 2)
                {
                    classAssembly = parts[1].Trim();
                }
            }

            storage ??= ut.Attribute("storage")?.Value
                ?? ut.Element(Ns + "TestMethod")?.Attribute("codeBase")?.Value;
        }

        var assemblyName = AssemblyDisplayName(storage, classAssembly, assemblyNames);
        var framework = FrameworkFrom(storage);

        int passed = 0, failed = 0, skipped = 0, notExecuted = 0, total = 0;
        var failures = new List<TestFailureDetail>();
        double duration = 0;

        var summary = root.Element(Ns + "ResultSummary")?.Element(Ns + "Counters");
        if (summary is not null)
        {
            total = IntAttr(summary, "total");
            passed = IntAttr(summary, "passed");
            failed = IntAttr(summary, "failed");
            notExecuted = IntAttr(summary, "notExecuted");
        }

        foreach (var r in root.Descendants(Ns + "UnitTestResult"))
        {
            var outcome = r.Attribute("outcome")?.Value ?? "";
            var testDuration = ParseDuration(r.Attribute("duration")?.Value);
            duration += testDuration;

            if (string.Equals(outcome, "Failed", StringComparison.OrdinalIgnoreCase))
            {
                var testId = r.Attribute("testId")?.Value;
                var testName = r.Attribute("testName")?.Value ?? "(unknown test)";
                var output = r.Element(Ns + "Output");
                var error = output?.Element(Ns + "ErrorInfo");
                failures.Add(new TestFailureDetail(
                    testName,
                    testId is not null && classById.TryGetValue(testId, out var cls) ? cls : null,
                    error?.Element(Ns + "Message")?.Value?.Trim(),
                    error?.Element(Ns + "StackTrace")?.Value?.Trim(),
                    output?.Element(Ns + "StdOut")?.Value?.Trim(),
                    assemblyName,
                    framework,
                    Math.Round(testDuration, 3)));
            }
            else if (outcome is "NotExecuted" or "Skipped")
            {
                skipped++;
            }
        }

        // notExecuted in the TRX counters is the authoritative skipped count when present.
        if (notExecuted > 0)
        {
            skipped = notExecuted;
        }

        if (total == 0)
        {
            total = passed + failed + skipped;
        }

        return new TestRunResult
        {
            Total = total,
            Passed = passed,
            Failed = failed,
            Skipped = skipped,
            NotExecuted = notExecuted,
            DurationSeconds = Math.Round(duration, 3),
            Failures = failures,
            Assemblies = assemblyName is null
                ? []
                : [new TestAssemblyResult(assemblyName, framework, total, passed, failed, skipped, Math.Round(duration, 3))],
            TrxFilesParsed = 1,
        };
    }

    public static TestRunResult ParseDirectory(string directory, IReadOnlyDictionary<string, string>? assemblyNames = null)
    {
        var result = TestRunResult.Empty;
        if (!Directory.Exists(directory))
        {
            return result;
        }

        foreach (var file in Directory.EnumerateFiles(directory, "*.trx", SearchOption.AllDirectories))
        {
            try
            {
                result = result.Merge(ParseFile(file, assemblyNames));
            }
            catch (Exception)
            {
                // A single unreadable TRX must not lose the results of the others.
            }
        }

        return result with
        {
            Assemblies = [.. result.Assemblies.OrderBy(a => a.Assembly, StringComparer.OrdinalIgnoreCase).ThenBy(a => a.Framework, StringComparer.OrdinalIgnoreCase)],
        };
    }

    // "/workspace/test/Acme.Tests/bin/Debug/net10.0/Acme.Tests.dll" -> "Acme.Tests.dll".
    internal static string? AssemblyNameFrom(string? storage) =>
        string.IsNullOrWhiteSpace(storage) ? null : Path.GetFileName(storage.Replace('\\', '/'));

    // VSTest lower-cases the storage path it records, which would report "acme.tests.dll" for an assembly
    // the developer knows as "Acme.Tests.dll". Two sources restore the real casing, in order of
    // authority: the repository's own project files, then the class name's assembly part
    // ("Namespace.Type, Acme.Tests"), which some loggers include and which keeps its casing.
    internal static string? AssemblyDisplayName(
        string? storage, string? classAssembly, IReadOnlyDictionary<string, string>? assemblyNames = null)
    {
        var fromStorage = AssemblyNameFrom(storage);
        if (fromStorage is not null && assemblyNames is not null && assemblyNames.TryGetValue(fromStorage, out var known))
        {
            return known;
        }

        var simpleName = classAssembly?.Split(',')[0].Trim();
        if (string.IsNullOrWhiteSpace(simpleName))
        {
            return fromStorage;
        }

        var candidate = simpleName + ".dll";
        return fromStorage is null || string.Equals(candidate, fromStorage, StringComparison.OrdinalIgnoreCase)
            ? candidate
            : fromStorage;
    }

    // The TFM is the output folder the test assembly was built into; it is the only place a TRX records
    // which target framework produced it.
    internal static string? FrameworkFrom(string? storage)
    {
        if (string.IsNullOrWhiteSpace(storage))
        {
            return null;
        }

        var segments = storage.Replace('\\', '/').Split('/', StringSplitOptions.RemoveEmptyEntries);
        for (var i = segments.Length - 2; i >= 0; i--)
        {
            if (Regex.IsMatch(segments[i], @"^net(standard|coreapp|framework)?\d+(\.\d+)*(-[a-z0-9.]+)?$", RegexOptions.IgnoreCase)
                || Regex.IsMatch(segments[i], @"^net\d{2,3}$", RegexOptions.IgnoreCase))
            {
                return segments[i];
            }
        }

        return null;
    }

    private static int IntAttr(XElement e, string name) =>
        int.TryParse(e.Attribute(name)?.Value, NumberStyles.Integer, CultureInfo.InvariantCulture, out var v) ? v : 0;

    private static double ParseDuration(string? value) =>
        TimeSpan.TryParse(value, CultureInfo.InvariantCulture, out var ts) ? ts.TotalSeconds : 0;
}

// ---------------------------------------------------------------------------------------------------
// Failure classification.
// A container/infrastructure failure must never be reported as a failing unit test, and we never fall
// back to running tests locally. Each phase maps to a distinct failure kind.
// ---------------------------------------------------------------------------------------------------

internal enum FailureKind
{
    None,
    Configuration,
    UnsupportedEnvironment,
    DockerUnavailable,
    ImageResolution,
    SdkIncompatibility,
    SourceStaging,
    Restore,
    Compilation,
    TestHost,
    TestFailure,
    ResultProcessing,
    Cleanup,
    Cancelled,
    ReleaseMetadataUnavailable,
}

internal sealed record ExecutionOutcome(FailureKind Kind, string Phase, int ExitCode, string Message);

internal static class FailureClassifier
{
    public static ExitCode ToExitCode(FailureKind kind) => kind switch
    {
        FailureKind.None => ExitCode.Success,
        FailureKind.Configuration => ExitCode.Configuration,
        FailureKind.UnsupportedEnvironment => ExitCode.UnsupportedEnvironment,
        FailureKind.DockerUnavailable => ExitCode.DockerUnavailable,
        FailureKind.ImageResolution => ExitCode.ImageResolution,
        FailureKind.SdkIncompatibility => ExitCode.SdkIncompatibility,
        FailureKind.SourceStaging => ExitCode.SourceStaging,
        FailureKind.Restore => ExitCode.Restore,
        FailureKind.Compilation => ExitCode.Compilation,
        FailureKind.TestHost => ExitCode.TestHost,
        FailureKind.TestFailure => ExitCode.TestFailures,
        FailureKind.ResultProcessing => ExitCode.ResultProcessing,
        FailureKind.Cleanup => ExitCode.Cleanup,
        FailureKind.Cancelled => ExitCode.Cancelled,
        FailureKind.ReleaseMetadataUnavailable => ExitCode.ReleaseMetadataUnavailable,
        _ => ExitCode.ResultProcessing,
    };

    // Interpret the container run from the phase markers it emitted, its exit code, whether it was
    // cancelled, and the parsed test results. This is the crux of never misreporting infrastructure as
    // a unit-test failure.
    public static ExecutionOutcome Classify(
        IReadOnlyDictionary<string, int> phaseExitCodes,
        int containerExitCode,
        bool cancelled,
        TestRunResult results)
    {
        if (cancelled)
        {
            return new ExecutionOutcome(FailureKind.Cancelled, "test", containerExitCode, "The remote test run was cancelled.");
        }

        if (phaseExitCodes.TryGetValue("staging", out var stage) && stage != 0)
        {
            return new ExecutionOutcome(FailureKind.SourceStaging, "staging", stage, "The staged workspace was not available inside the container.");
        }

        if (phaseExitCodes.TryGetValue("restore", out var restore) && restore != 0)
        {
            return new ExecutionOutcome(FailureKind.Restore, "restore", restore, "dotnet restore failed inside the container.");
        }

        if (phaseExitCodes.TryGetValue("build", out var build) && build != 0)
        {
            return new ExecutionOutcome(FailureKind.Compilation, "build", build, "dotnet build failed inside the container.");
        }

        var testRan = phaseExitCodes.TryGetValue("test", out var test);
        if (testRan && test != 0)
        {
            // dotnet test returned non-zero. If a TRX with failures exists, these are real test failures;
            // otherwise the test host itself failed (crash, no tests discovered, adapter missing).
            if (results.TrxFilesParsed > 0 && results.Failed > 0)
            {
                return new ExecutionOutcome(FailureKind.TestFailure, "test", test, $"{results.Failed} test(s) failed.");
            }

            return new ExecutionOutcome(FailureKind.TestHost, "test", test,
                "The test host exited non-zero without producing failing test results (crash, no discovered tests, or missing adapter).");
        }

        if (!testRan && containerExitCode != 0)
        {
            return new ExecutionOutcome(FailureKind.TestHost, "test", containerExitCode,
                "The container exited before the test phase completed.");
        }

        if (results.Failed > 0)
        {
            return new ExecutionOutcome(FailureKind.TestFailure, "test", containerExitCode, $"{results.Failed} test(s) failed.");
        }

        return new ExecutionOutcome(FailureKind.None, "test", 0, "All tests passed.");
    }

    // Extract "##RT_PHASE_END:<name>:<code>##" markers from captured container stdout.
    public static IReadOnlyDictionary<string, int> ParsePhaseMarkers(string output)
    {
        var map = new Dictionary<string, int>(StringComparer.OrdinalIgnoreCase);
        foreach (Match m in MarkerPattern.Matches(output))
        {
            map[m.Groups["name"].Value] = int.Parse(m.Groups["code"].Value, CultureInfo.InvariantCulture);
        }

        return map;
    }

    // The container emits one marker per phase, so the text between two markers is exactly that phase's
    // log. Reporting the failing phase's own output — instead of a tail of everything — is what turns
    // "the build failed" into "this file, this line, this compiler error".
    public static string PhaseOutput(string output, string phase)
    {
        if (string.IsNullOrEmpty(output))
        {
            return "";
        }

        var start = 0;
        foreach (Match m in MarkerPattern.Matches(output))
        {
            if (string.Equals(m.Groups["name"].Value, phase, StringComparison.OrdinalIgnoreCase))
            {
                return output[start..m.Index].Trim('\r', '\n');
            }

            start = m.Index + m.Length;
        }

        // The phase never completed (crash, cancellation): everything after the last marker is its log.
        return output[start..].Trim('\r', '\n');
    }

    private static readonly Regex MarkerPattern = new(
        Regex.Escape(ContainerPlanner.PhaseMarkerPrefix) + @"(?<name>[a-zA-Z]+):(?<code>-?\d+)##",
        RegexOptions.Compiled);
}

// ---------------------------------------------------------------------------------------------------
// Process execution utility.
// ---------------------------------------------------------------------------------------------------

internal sealed record ProcessResult(int ExitCode, string StdOut, string StdErr, bool TimedOut);

internal static class ProcessRunner
{
    public static async Task<ProcessResult> RunAsync(
        string fileName,
        IReadOnlyList<string> arguments,
        string? workingDirectory = null,
        CancellationToken cancellationToken = default)
    {
        var psi = new ProcessStartInfo
        {
            FileName = fileName,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            UseShellExecute = false,
            CreateNoWindow = true,
            WorkingDirectory = workingDirectory ?? Directory.GetCurrentDirectory(),
        };

        foreach (var a in arguments)
        {
            psi.ArgumentList.Add(a);
        }

        using var process = new Process { StartInfo = psi };
        var stdout = new StringBuilder();
        var stderr = new StringBuilder();
        process.OutputDataReceived += (_, e) => { if (e.Data is not null) { lock (stdout) { stdout.AppendLine(e.Data); } } };
        process.ErrorDataReceived += (_, e) => { if (e.Data is not null) { lock (stderr) { stderr.AppendLine(e.Data); } } };

        process.Start();
        process.BeginOutputReadLine();
        process.BeginErrorReadLine();

        try
        {
            await process.WaitForExitAsync(cancellationToken);
        }
        catch (OperationCanceledException)
        {
            TryKill(process);
            return new ProcessResult(-1, stdout.ToString(), stderr.ToString(), TimedOut: true);
        }

        return new ProcessResult(process.ExitCode, stdout.ToString(), stderr.ToString(), TimedOut: false);
    }

    private static void TryKill(Process process)
    {
        try
        {
            if (!process.HasExited)
            {
                process.Kill(entireProcessTree: true);
            }
        }
        catch (Exception)
        {
            // Best effort; the caller handles container cleanup separately.
        }
    }
}

// ---------------------------------------------------------------------------------------------------
// Release metadata store — network fetch with an outside-the-repo cache and offline fallback.
// ---------------------------------------------------------------------------------------------------

internal sealed record ReleaseMetadataResult(ReleaseMetadata? Metadata, string? Error);

internal static class ReleaseMetadataStore
{
    private static readonly HttpClient Http = new() { Timeout = TimeSpan.FromSeconds(15) };

    private static string CacheFile(string cacheRoot) => Path.Combine(cacheRoot, "releases-index.cache.json");

    public static async Task<ReleaseMetadataResult> LoadAsync(Options options, CancellationToken ct)
    {
        // Explicit local file wins: it is a deliberate input (used by tests and controlled environments).
        if (!string.IsNullOrWhiteSpace(options.ReleasesIndexFile))
        {
            if (!File.Exists(options.ReleasesIndexFile))
            {
                return new ReleaseMetadataResult(null, $"releases-index file not found: {options.ReleasesIndexFile}");
            }

            var channels = ReleaseIndexReader.Parse(await File.ReadAllTextAsync(options.ReleasesIndexFile, ct));
            return new ReleaseMetadataResult(new ReleaseMetadata
            {
                Channels = channels,
                RetrievedAt = File.GetLastWriteTimeUtc(options.ReleasesIndexFile),
                Source = $"file:{options.ReleasesIndexFile}",
            }, null);
        }

        var cacheFile = CacheFile(options.CacheDirectory);

        if (options.Offline)
        {
            return LoadFromCache(cacheFile, "Offline mode: ");
        }

        try
        {
            var json = await Http.GetStringAsync(RemoteTestProgram.ReleasesIndexUrl, ct);
            var channels = ReleaseIndexReader.Parse(json);
            if (channels.Count == 0)
            {
                return LoadFromCache(cacheFile, "Release index returned no channels: ");
            }

            var now = DateTimeOffset.UtcNow;
            TryWriteCache(cacheFile, json, now);
            return new ReleaseMetadataResult(new ReleaseMetadata
            {
                Channels = channels,
                RetrievedAt = now,
                Source = RemoteTestProgram.ReleasesIndexUrl,
            }, null);
        }
        catch (Exception ex) when (ex is HttpRequestException or TaskCanceledException or IOException)
        {
            return LoadFromCache(cacheFile, $"Could not reach Microsoft release metadata ({ex.Message}); ");
        }
    }

    private static ReleaseMetadataResult LoadFromCache(string cacheFile, string prefix)
    {
        if (!File.Exists(cacheFile))
        {
            return new ReleaseMetadataResult(null,
                prefix + "no cached release metadata is available. Automatic environment discovery cannot proceed.");
        }

        try
        {
            using var doc = JsonDocument.Parse(File.ReadAllText(cacheFile));
            var root = doc.RootElement;
            var retrievedAt = root.TryGetProperty("retrievedAt", out var r) && r.ValueKind == JsonValueKind.String
                ? DateTimeOffset.Parse(r.GetString()!, CultureInfo.InvariantCulture)
                : File.GetLastWriteTimeUtc(cacheFile);
            var releasesIndex = root.GetProperty("releasesIndex");
            if (releasesIndex.ValueKind != JsonValueKind.Array)
            {
                throw new JsonException("Cached releasesIndex must be an array.");
            }

            // The cache stores only the releases-index array, while ReleaseIndexReader consumes the
            // original object-shaped releases-index.json contract.
            var rawJson = $$"""{"releases-index":{{releasesIndex.GetRawText()}}}""";
            var channels = ReleaseIndexReader.Parse(rawJson);
            return new ReleaseMetadataResult(new ReleaseMetadata
            {
                Channels = channels,
                RetrievedAt = retrievedAt,
                Source = $"cache:{cacheFile}",
                IsStale = true,
            }, null);
        }
        catch (Exception ex)
        {
            return new ReleaseMetadataResult(null, prefix + $"cached release metadata is unreadable ({ex.Message}).");
        }
    }

    private static void TryWriteCache(string cacheFile, string rawIndexJson, DateTimeOffset retrievedAt)
    {
        try
        {
            Directory.CreateDirectory(Path.GetDirectoryName(cacheFile)!);
            using var indexDoc = JsonDocument.Parse(rawIndexJson);
            var payload = new
            {
                retrievedAt = retrievedAt.ToString("O", CultureInfo.InvariantCulture),
                source = RemoteTestProgram.ReleasesIndexUrl,
                releasesIndex = indexDoc.RootElement.GetProperty("releases-index"),
            };
            File.WriteAllText(cacheFile, JsonSerializer.Serialize(payload, RemoteTestProgram.JsonOut));
        }
        catch (Exception)
        {
            // A cache write failure must not fail an otherwise successful online run.
        }
    }
}

// ---------------------------------------------------------------------------------------------------
// Docker registry client (MCR) — validate an SDK tag and pre-resolve its digest without pulling.
// ---------------------------------------------------------------------------------------------------

internal sealed record RegistryResolution(bool Exists, string? Digest, string? Error);

internal static class RegistryClient
{
    private static readonly HttpClient Http = new() { Timeout = TimeSpan.FromSeconds(15) };

    // mcr.microsoft.com implements the anonymous Docker Registry v2 API. A manifest request for a tag
    // returns 200 and a Docker-Content-Digest header when the tag exists.
    public static async Task<RegistryResolution> ResolveAsync(string repository, string tag, CancellationToken ct)
    {
        var url = $"https://mcr.microsoft.com/v2/{repository}/manifests/{tag}";
        using var request = new HttpRequestMessage(HttpMethod.Get, url);
        request.Headers.Accept.ParseAdd("application/vnd.docker.distribution.manifest.list.v2+json");
        request.Headers.Accept.ParseAdd("application/vnd.oci.image.index.v1+json");
        request.Headers.Accept.ParseAdd("application/vnd.docker.distribution.manifest.v2+json");
        request.Headers.Accept.ParseAdd("application/vnd.oci.image.manifest.v1+json");

        try
        {
            using var response = await Http.SendAsync(request, HttpCompletionOption.ResponseHeadersRead, ct);
            if (response.StatusCode == HttpStatusCode.NotFound)
            {
                return new RegistryResolution(false, null, null);
            }

            if (!response.IsSuccessStatusCode)
            {
                return new RegistryResolution(false, null, $"Registry returned HTTP {(int)response.StatusCode} for tag '{tag}'.");
            }

            var digest = response.Headers.TryGetValues("Docker-Content-Digest", out var values)
                ? values.FirstOrDefault()
                : null;
            return new RegistryResolution(true, digest, null);
        }
        catch (Exception ex) when (ex is HttpRequestException or TaskCanceledException)
        {
            return new RegistryResolution(false, null, ex.Message);
        }
    }

    // Try each candidate tag in order; return the first that exists.
    public static async Task<(string? tag, RegistryResolution resolution)> ResolveFirstAsync(
        string repository, IReadOnlyList<string> tags, CancellationToken ct)
    {
        RegistryResolution last = new(false, null, "No candidate tags.");
        foreach (var tag in tags)
        {
            var r = await ResolveAsync(repository, tag, ct);
            if (r.Exists)
            {
                return (tag, r);
            }

            last = r;
        }

        return (null, last);
    }
}

// ---------------------------------------------------------------------------------------------------
// Docker client — a thin, deterministic wrapper over the docker CLI.
// ---------------------------------------------------------------------------------------------------

internal static class DockerClient
{
    public static async Task<bool> IsAvailableAsync(CancellationToken ct)
    {
        try
        {
            var r = await ProcessRunner.RunAsync("docker", ["version", "--format", "{{.Server.Version}}"], null, ct);
            return r.ExitCode == 0 && !string.IsNullOrWhiteSpace(r.StdOut);
        }
        catch (Exception)
        {
            return false;
        }
    }

    public static Task<ProcessResult> PullAsync(string image, CancellationToken ct) =>
        ProcessRunner.RunAsync("docker", ["pull", image], null, ct);

    // Resolve the immutable digest of a locally present image (its manifest-list RepoDigest).
    public static async Task<string?> ResolveDigestAsync(string image, CancellationToken ct)
    {
        var r = await ProcessRunner.RunAsync(
            "docker", ["inspect", "--format", "{{join .RepoDigests \"\\n\"}}", image], null, ct);
        if (r.ExitCode != 0)
        {
            return null;
        }

        var line = r.StdOut.Split('\n', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries)
            .FirstOrDefault(l => l.Contains('@'));
        return line?[(line.IndexOf('@') + 1)..];
    }

    public static async Task<string?> ResolveImageIdAsync(string image, CancellationToken ct)
    {
        var r = await ProcessRunner.RunAsync("docker", ["inspect", "--format", "{{.Id}}", image], null, ct);
        return r.ExitCode == 0 ? r.StdOut.Trim() : null;
    }

    // The user an image is configured to run as. Empty means the image sets none, i.e. root.
    public static async Task<string?> ResolveUserAsync(string image, CancellationToken ct)
    {
        var r = await ProcessRunner.RunAsync("docker", ["inspect", "--format", "{{.Config.User}}", image], null, ct);
        if (r.ExitCode != 0)
        {
            return null;
        }

        var user = r.StdOut.Trim();
        return user.Length == 0 ? null : user;
    }

    public static Task<ProcessResult> BuildAsync(string dockerfile, string context, string tag, CancellationToken ct) =>
        ProcessRunner.RunAsync("docker", ["build", "-f", dockerfile, "-t", tag, context], null, ct);

    public static Task<ProcessResult> RunAsync(IReadOnlyList<string> runArgs, CancellationToken ct) =>
        ProcessRunner.RunAsync("docker", runArgs, null, ct);

    // Force-remove a container by name. Returns true if the container is gone afterward.
    public static async Task<bool> RemoveContainerAsync(string name, CancellationToken ct)
    {
        var r = await ProcessRunner.RunAsync("docker", ["rm", "-f", name], null, CancellationToken.None);
        if (r.ExitCode == 0)
        {
            return true;
        }

        // "No such container" means it is already gone (e.g. --rm cleaned it up) — treat as success.
        return r.StdErr.Contains("No such container", StringComparison.OrdinalIgnoreCase);
    }
}

// ---------------------------------------------------------------------------------------------------
// Image preparation — a .NET build routinely shells out to host tooling: MinVer, Nerdbank.GitVersioning,
// GitInfo and SourceLink all invoke `git` while building. An image without it fails the build (MinVer
// reports MINVER1007) even though the code compiles fine, which reads as a repository problem when it is
// really a missing tool in the image. Microsoft's SDK images ship git; a minimal runner image may not.
// When it is missing, one thin layer is derived from the resolved base image and cached under a
// digest-addressed tag, so the cost is paid once per image and never inside the repository.
// ---------------------------------------------------------------------------------------------------

internal sealed record PreparedImage(string Reference, bool Provisioned, string? Note = null);

internal static class ImageProvisioner
{
    // Tooling the container must expose on PATH for a build to behave the way it does on the host.
    public static readonly string[] RequiredTools = ["git"];

    private const string TagPrefix = "dotnet-remote-testing/prepared";

    public static string ToolList => string.Join(", ", RequiredTools);

    // Content-addressed tag: the same base image and tool set always produce the same prepared image,
    // so a later run reuses the cached layer instead of rebuilding it.
    public static string DerivedTag(string baseReference, string? digest)
    {
        var key = digest is not null && digest.Contains(':', StringComparison.Ordinal)
            ? digest[(digest.IndexOf(':', StringComparison.Ordinal) + 1)..]
            : StableHash(baseReference);
        var shortKey = key.Length > 16 ? key[..16] : key;
        return $"{TagPrefix}:{string.Join('-', RequiredTools)}-{shortKey}";
    }

    // Verifies the tools are on PATH inside the image, without assuming a specific shell or entrypoint.
    public static string ProbeCommand() =>
        string.Join(" && ", RequiredTools.Select(t => $"command -v {t} >/dev/null 2>&1"));

    // A single RUN that adapts to whichever package manager the base image ships. The Dockerfile is
    // written to the run's own temporary directory — never into the repository being tested.
    //
    // Installing packages needs root, but the identity the tests run under is part of the environment
    // being reproduced: a base image that runs as a non-root user must keep doing so, or the prepared
    // image writes build and test output with different ownership than the configured image would.
    // baseUser is that image's configured user, or null when it sets none (already root).
    public static string Dockerfile(string baseReference, string? baseUser = null)
    {
        var tools = string.Join(' ', RequiredTools);
        var restore = string.IsNullOrWhiteSpace(baseUser) ? string.Empty : $"USER {baseUser.Trim()}\n";
        return $"""
        FROM {baseReference}
        USER root
        RUN set -e; \
            if command -v apt-get >/dev/null 2>&1; then \
                apt-get update && apt-get install -y --no-install-recommends {tools} && rm -rf /var/lib/apt/lists/*; \
            elif command -v apk >/dev/null 2>&1; then \
                apk add --no-cache {tools}; \
            elif command -v microdnf >/dev/null 2>&1; then \
                microdnf install -y {tools} && microdnf clean all; \
            elif command -v dnf >/dev/null 2>&1; then \
                dnf install -y {tools} && dnf clean all; \
            elif command -v yum >/dev/null 2>&1; then \
                yum install -y {tools} && yum clean all; \
            else \
                echo 'No supported package manager in the base image.' >&2; exit 1; \
            fi
        {restore}
        """;
    }

    // Best effort by design: when the tooling cannot be added, the base image is used anyway and the
    // reason is reported, because a repository that never invokes git still runs perfectly well there.
    public static async Task<PreparedImage> EnsureAsync(
        string baseReference, string? digest, string workRoot, bool offline, CancellationToken ct)
    {
        var tag = DerivedTag(baseReference, digest);

        if (await DockerClient.ResolveImageIdAsync(tag, ct) is not null)
        {
            return new PreparedImage(tag, true, $"Reused prepared image providing {ToolList}.");
        }

        var probe = await DockerClient.RunAsync(
            ["run", "--rm", "--entrypoint", "sh", baseReference, "-c", ProbeCommand()], ct);
        if (probe.ExitCode == 0)
        {
            return new PreparedImage(baseReference, false);
        }

        if (offline)
        {
            return new PreparedImage(baseReference, false,
                $"The image does not provide {ToolList} and adding it needs network access (--offline). "
                + "A build that invokes it will fail.");
        }

        // Read the identity off the base image before deriving from it, so the prepared image keeps
        // running as whoever the configured image runs as instead of silently switching to root.
        var baseUser = await DockerClient.ResolveUserAsync(baseReference, ct);

        var contextDir = Path.Combine(workRoot, "image-prep");
        Directory.CreateDirectory(contextDir);
        var dockerfile = Path.Combine(contextDir, "Dockerfile");
        await File.WriteAllTextAsync(dockerfile, Dockerfile(baseReference, baseUser), ct);

        var build = await DockerClient.BuildAsync(dockerfile, contextDir, tag, ct);
        if (build.ExitCode != 0)
        {
            var reason = build.StdErr.Split('\n', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries)
                .LastOrDefault() ?? "docker build failed.";
            return new PreparedImage(baseReference, false,
                $"The image does not provide {ToolList} and it could not be added: {reason}");
        }

        return new PreparedImage(tag, true, $"Added {ToolList} to the image (cached for later runs).");
    }

    private static string StableHash(string value)
    {
        var bytes = System.Security.Cryptography.SHA256.HashData(Encoding.UTF8.GetBytes(value));
        return Convert.ToHexStringLower(bytes);
    }
}

// ---------------------------------------------------------------------------------------------------
// Source staging — copy the source into an isolated, disposable workspace so container builds never
// pollute the developer's working tree with Linux bin/obj artifacts.
//
// The staged copy must still *be* a repository. Dropping .git changes observable behavior: MinVer and
// Nerdbank.GitVersioning fall back to 0.0.0, SourceLink stops embedding, and any repository-root probe
// ("walk up until a .git directory exists") resolves somewhere else entirely — which silently changes
// what the tests under it see. That is the difference between "it passes in Visual Studio's remote
// testing and fails here", so .git is staged too, as a disposable copy the container may freely write.
// ---------------------------------------------------------------------------------------------------

internal sealed record StagingResult(
    string? StagedPath,
    string? Error,
    int FileCount,
    bool GitMetadataStaged = false,
    long GitMetadataBytes = 0,
    string? GitMetadataNote = null);

internal static class SourceStager
{
    private static readonly string[] ExcludedDirs = ["bin", "obj", ".git", ".vs", ".vscode", "node_modules", "TestResults"];

    public static async Task<StagingResult> StageAsync(
        string sourceRoot, string stagingRoot, CancellationToken ct, bool includeGitMetadata = true)
    {
        if (!Directory.Exists(sourceRoot))
        {
            return new StagingResult(null, $"Source root does not exist: {sourceRoot}", 0);
        }

        try
        {
            Directory.CreateDirectory(stagingRoot);

            // Prefer git to enumerate tracked + untracked-not-ignored files; this keeps ignored build
            // output out of the staged copy without reimplementing .gitignore.
            var files = await TryGitEnumerateAsync(sourceRoot, ct);
            var count = files is not null
                ? CopyEnumerated(sourceRoot, stagingRoot, files)
                : CopyRecursive(sourceRoot, stagingRoot);

            var git = includeGitMetadata
                ? StageGitMetadata(sourceRoot, stagingRoot)
                : new GitStagingResult(false, 0, "Git metadata staging disabled; repository-root detection and version stamping will differ from the host.");

            return new StagingResult(stagingRoot, null, count, git.Staged, git.Bytes, git.Note);
        }
        catch (Exception ex)
        {
            return new StagingResult(null, $"Failed to stage source: {ex.Message}", 0);
        }
    }

    private sealed record GitStagingResult(bool Staged, long Bytes, string? Note);

    // Copy the repository's git directory verbatim into the staged workspace. Best-effort by design: a
    // missing or unreadable .git is a fidelity note, never a reason to fail a run that can still execute.
    private static GitStagingResult StageGitMetadata(string sourceRoot, string stagingRoot)
    {
        var gitDir = ResolveGitDirectory(sourceRoot);
        if (gitDir is null)
        {
            return new GitStagingResult(false, 0, null);
        }

        var destination = Path.Combine(stagingRoot, ".git");
        try
        {
            // A linked worktree stages its "gitdir:" pointer file as ordinary content; the real git
            // directory has to replace it, because the path it points at does not exist in the container.
            if (File.Exists(destination))
            {
                File.Delete(destination);
            }

            // A linked worktree's git directory holds only per-worktree state (HEAD, index, logs). The
            // objects, refs and config live in the shared directory its "commondir" points at, outside
            // the staged copy. Staging the worktree half alone produces a git directory git cannot read,
            // so versioning falls back to 0.0.0 and SourceLink stops embedding — the exact fidelity loss
            // staging .git exists to prevent. The shared half is copied first and the per-worktree files
            // are layered over it, which collapses the pair into an ordinary standalone repository.
            var commonDir = ResolveCommonDirectory(gitDir);
            if (commonDir is not null)
            {
                // "worktrees/" only registers linked worktrees by host path; none of them exist in the
                // container, and this worktree's own entry is exactly what is being flattened here.
                CopyDirectory(commonDir, destination, excludeTopLevelDirectory: "worktrees");
            }

            var bytes = CopyDirectory(gitDir, destination);
            if (commonDir is not null)
            {
                // The staged repository is standalone now; leaving the pointers behind would send git
                // back out to host paths that do not exist in the container.
                foreach (var pointer in new[] { "commondir", "gitdir" })
                {
                    var stale = Path.Combine(destination, pointer);
                    if (File.Exists(stale))
                    {
                        File.Delete(stale);
                    }
                }

                bytes = MeasureDirectory(destination);
            }

            return new GitStagingResult(true, bytes, null);
        }
        catch (Exception ex)
        {
            return new GitStagingResult(false, 0,
                $"Git metadata could not be staged ({ex.Message}); repository-root detection and version stamping may differ from the host.");
        }
    }

    // .git is a directory in an ordinary clone and a "gitdir: <path>" pointer file in a linked worktree
    // or submodule. Both resolve to a real directory that carries the repository state.
    private static string? ResolveGitDirectory(string sourceRoot)
    {
        var candidate = Path.Combine(sourceRoot, ".git");
        if (Directory.Exists(candidate))
        {
            return candidate;
        }

        if (!File.Exists(candidate))
        {
            return null;
        }

        var pointer = File.ReadAllText(candidate).Trim();
        const string Prefix = "gitdir:";
        if (!pointer.StartsWith(Prefix, StringComparison.OrdinalIgnoreCase))
        {
            return null;
        }

        var target = pointer[Prefix.Length..].Trim();
        if (!Path.IsPathRooted(target))
        {
            target = Path.GetFullPath(Path.Combine(sourceRoot, target));
        }

        return Directory.Exists(target) ? target : null;
    }

    // A linked worktree's git directory carries a "commondir" file naming the shared repository
    // directory that actually holds objects, refs and config. An ordinary clone has no such file.
    private static string? ResolveCommonDirectory(string gitDir)
    {
        var marker = Path.Combine(gitDir, "commondir");
        if (!File.Exists(marker))
        {
            return null;
        }

        var target = File.ReadAllText(marker).Trim();
        if (target.Length == 0)
        {
            return null;
        }

        if (!Path.IsPathRooted(target))
        {
            target = Path.GetFullPath(Path.Combine(gitDir, target));
        }

        return Directory.Exists(target) ? target : null;
    }

    private static long MeasureDirectory(string root) =>
        Directory.EnumerateFiles(root, "*", SearchOption.AllDirectories).Sum(f => new FileInfo(f).Length);

    private static long CopyDirectory(string source, string destination, string? excludeTopLevelDirectory = null)
    {
        long bytes = 0;
        var stack = new Stack<(string Source, string Destination)>();
        stack.Push((source, destination));
        while (stack.Count > 0)
        {
            var (from, to) = stack.Pop();
            Directory.CreateDirectory(to);
            foreach (var file in Directory.EnumerateFiles(from))
            {
                var target = Path.Combine(to, Path.GetFileName(file));
                File.Copy(file, target, overwrite: true);
                // The source .git may be read-only in places (packed objects); the staged copy is
                // disposable and the container must be able to write to it.
                new FileInfo(target).IsReadOnly = false;
                bytes += new FileInfo(target).Length;
            }

            foreach (var dir in Directory.EnumerateDirectories(from))
            {
                var name = Path.GetFileName(dir);
                if (excludeTopLevelDirectory is not null
                    && string.Equals(from, source, StringComparison.Ordinal)
                    && string.Equals(name, excludeTopLevelDirectory, StringComparison.OrdinalIgnoreCase))
                {
                    continue;
                }

                stack.Push((dir, Path.Combine(to, name)));
            }
        }

        return bytes;
    }

    private static async Task<IReadOnlyList<string>?> TryGitEnumerateAsync(string sourceRoot, CancellationToken ct)
    {
        // .git is a directory in an ordinary clone and a "gitdir:" pointer file in a linked worktree;
        // git enumerates both, and skipping the pointer form would stage ignored build output.
        var marker = Path.Combine(sourceRoot, ".git");
        if (!Directory.Exists(marker) && !File.Exists(marker))
        {
            return null;
        }

        try
        {
            var r = await ProcessRunner.RunAsync(
                "git", ["-C", sourceRoot, "ls-files", "-co", "--exclude-standard"], sourceRoot, ct);
            if (r.ExitCode != 0)
            {
                return null;
            }

            return [.. r.StdOut.Split('\n', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries)];
        }
        catch (Exception)
        {
            return null;
        }
    }

    private static int CopyEnumerated(string sourceRoot, string stagingRoot, IReadOnlyList<string> relativeFiles)
    {
        var count = 0;
        foreach (var rel in relativeFiles)
        {
            var normalized = rel.Replace('/', Path.DirectorySeparatorChar);
            var src = Path.Combine(sourceRoot, normalized);
            if (!File.Exists(src))
            {
                continue;
            }

            var dest = Path.Combine(stagingRoot, normalized);
            Directory.CreateDirectory(Path.GetDirectoryName(dest)!);
            File.Copy(src, dest, overwrite: true);
            count++;
        }

        return count;
    }

    private static int CopyRecursive(string sourceRoot, string stagingRoot)
    {
        var count = 0;
        var stack = new Stack<string>();
        stack.Push(sourceRoot);
        while (stack.Count > 0)
        {
            var dir = stack.Pop();
            foreach (var sub in Directory.EnumerateDirectories(dir))
            {
                var name = Path.GetFileName(sub);
                if (!ExcludedDirs.Contains(name, StringComparer.OrdinalIgnoreCase))
                {
                    stack.Push(sub);
                }
            }

            foreach (var file in Directory.EnumerateFiles(dir))
            {
                var rel = Path.GetRelativePath(sourceRoot, file);
                var dest = Path.Combine(stagingRoot, rel);
                Directory.CreateDirectory(Path.GetDirectoryName(dest)!);
                File.Copy(file, dest, overwrite: true);
                count++;
            }
        }

        return count;
    }
}

// ---------------------------------------------------------------------------------------------------
// Commands: list, plan, run. This is the boundary the AI orchestration layer calls.
// ---------------------------------------------------------------------------------------------------

internal sealed record ResolveContext(
    TestEnvironmentsConfig? Config,
    ReleaseMetadata? Metadata,
    string? MetadataError,
    IReadOnlyList<ResolvedEnvironment> Generated,
    EnvironmentResolution Resolution,
    string? MultiSdkError = null);

internal static class Commands
{
    private static async Task<ResolveContext> BuildContextAsync(Options options, CancellationToken ct)
    {
        var configPath = TestEnvironmentsConfigReader.Locate(options.RepoRoot, options.ConfigPath);
        TestEnvironmentsConfig? config = configPath is not null
            ? TestEnvironmentsConfigReader.Parse(await File.ReadAllTextAsync(configPath, ct), configPath)
            : null;

        var nameInConfig = options.EnvironmentName is not null && config is not null &&
            (config.SupportedDockerEnvironments.Any(Match) || config.UnsupportedEnvironments.Any(Match));
        bool Match(EnvironmentDefinition e) =>
            string.Equals(e.Name, options.EnvironmentName, StringComparison.OrdinalIgnoreCase);

        var authoritativeNoName = options.EnvironmentName is null && config?.SourcePath is not null;
        var needMetadata = !authoritativeNoName && !nameInConfig;

        ReleaseMetadata? metadata = null;
        string? metadataError = null;
        IReadOnlyList<ResolvedEnvironment> generated = [];
        if (needMetadata)
        {
            var result = await ReleaseMetadataStore.LoadAsync(options, ct);
            metadata = result.Metadata;
            metadataError = result.Error;
            if (metadata is not null)
            {
                generated = GeneratedEnvironments.FromMetadata(metadata);
            }
        }

        // Generated environments are resolved against the repository's own target frameworks. Configured
        // environments never need this (they are deliberate intent), and a named environment short-circuits
        // before it is used, so the inspection only runs when it can actually decide something.
        TargetFrameworkInfo? repoTargets = null;
        string? multiSdkError = null;
        if (options.EnvironmentName is null && config?.SourcePath is null && generated.Count > 1)
        {
            repoTargets = NarrowToRequestedFramework(
                TargetFrameworkInspector.Inspect(options.RepoRoot, options.Project), options.Framework);

            // Only a genuinely multi-targeted repository needs the multi-SDK runner feed; do not spend a
            // network call to answer a question a single target framework already answers.
            if (repoTargets.NetCoreMajors.Count > 1)
            {
                var multi = await MultiSdkRunnerStore.LoadAsync(options, ct);
                multiSdkError = multi.Error;
                var runner = MultiSdkTagReader.Select(multi.Runners, repoTargets.NetCoreMajors);
                if (runner is not null)
                {
                    generated = [.. generated, GeneratedEnvironments.FromMultiSdkRunner(runner)];
                }
            }
        }

        var resolution = EnvironmentResolver.Resolve(config, generated, options.EnvironmentName, repoTargets);
        return new ResolveContext(config, metadata, metadataError, generated, resolution, multiSdkError);
    }

    // --framework narrows what actually runs, so it must narrow what the environment is chosen for too.
    // Without this, "-f net10.0" on a multi-targeted repository would still be resolved as multi-targeted.
    private static TargetFrameworkInfo NarrowToRequestedFramework(TargetFrameworkInfo info, string? framework)
    {
        if (string.IsNullOrWhiteSpace(framework))
        {
            return info;
        }

        var match = info.TargetFrameworks.FirstOrDefault(
            t => string.Equals(t, framework, StringComparison.OrdinalIgnoreCase));

        return info with { TargetFrameworks = match is null ? [framework] : [match] };
    }

    public static async Task<int> ListAsync(Options options)
    {
        using var cts = new CancellationTokenSource();
        var configPath = TestEnvironmentsConfigReader.Locate(options.RepoRoot, options.ConfigPath);
        TestEnvironmentsConfig? config = configPath is not null
            ? TestEnvironmentsConfigReader.Parse(await File.ReadAllTextAsync(configPath, cts.Token), configPath)
            : null;

        ReleaseMetadata? metadata = null;
        string? metadataError = null;
        IReadOnlyList<ResolvedEnvironment> environments;
        IReadOnlyList<EnvironmentDefinition> unsupported = [];

        if (config?.SourcePath is not null)
        {
            environments = [.. config.SupportedDockerEnvironments.Select(GeneratedEnvironments.FromConfigured)];
            unsupported = config.UnsupportedEnvironments;
        }
        else
        {
            var result = await ReleaseMetadataStore.LoadAsync(options, cts.Token);
            metadata = result.Metadata;
            metadataError = result.Error;
            environments = metadata is not null ? GeneratedEnvironments.FromMetadata(metadata) : [];

            // A multi-targeted repository cannot execute its lower target frameworks on a single-SDK
            // image, so offer the runner that can — listing only what cannot work would be misleading.
            var repoMajors = NarrowToRequestedFramework(
                TargetFrameworkInspector.Inspect(options.RepoRoot, options.Project), options.Framework).NetCoreMajors;
            if (repoMajors.Count > 1)
            {
                var multi = await MultiSdkRunnerStore.LoadAsync(options, cts.Token);
                var runner = MultiSdkTagReader.Select(multi.Runners, repoMajors);
                if (runner is not null)
                {
                    environments = [GeneratedEnvironments.FromMultiSdkRunner(runner), .. environments];
                }
            }
        }

        if (options.Json)
        {
            Console.WriteLine(JsonSerializer.Serialize(new
            {
                tool = RemoteTestProgram.ToolName,
                source = config?.SourcePath ?? metadata?.Source,
                metadata = metadata is null ? null : new { retrievedAt = metadata.RetrievedAt, stale = metadata.IsStale, source = metadata.Source },
                metadataError,
                environments = environments.Select(e => new
                {
                    e.Name, origin = e.Origin.ToString(), e.Channel, e.ReleaseType, e.Sdk,
                    image = e.DockerImage, dockerFile = e.DockerFile,
                    supportedMajors = e.SupportedMajors.Count > 0 ? e.SupportedMajors : null,
                }),
                unsupported = unsupported.Select(e => new { e.Name, type = e.RawType }),
                configDiagnostics = config?.Diagnostics.Select(d => new { d.Code, d.Message, environment = d.EnvironmentName }),
            }, RemoteTestProgram.JsonOut));
            return environments.Count > 0 || metadataError is null
                ? (int)ExitCode.Success
                : (int)ExitCode.ReleaseMetadataUnavailable;
        }

        Console.WriteLine("Remote test environments");
        Console.WriteLine();
        if (environments.Count == 0)
        {
            Console.WriteLine(metadataError ?? "  (none)");
        }

        foreach (var e in environments)
        {
            Console.WriteLine($"{e.Name}");
            if (e.Channel is not null)
            {
                Console.WriteLine($"  .NET {e.Channel}");
            }

            if (e.ReleaseType is not null)
            {
                Console.WriteLine($"  {e.ReleaseType}");
            }

            if (e.SupportedMajors.Count > 0)
            {
                Console.WriteLine($"  Provides .NET {string.Join(", ", e.SupportedMajors)} in one image");
            }

            if (e.Sdk is not null)
            {
                Console.WriteLine($"  SDK {e.Sdk}");
            }

            if (e.DockerImage is not null)
            {
                Console.WriteLine($"  Image {e.DockerImage}");
            }

            if (e.DockerFile is not null)
            {
                Console.WriteLine($"  Dockerfile {e.DockerFile}");
            }

            Console.WriteLine();
        }

        if (unsupported.Count > 0)
        {
            Console.WriteLine("Unsupported (reported, not run):");
            foreach (var e in unsupported)
            {
                Console.WriteLine($"  {e.Name} — type '{e.RawType}' is not supported (Docker only).");
            }
        }

        if (metadata?.IsStale == true)
        {
            Console.WriteLine($"Note: using cached release metadata from {metadata.RetrievedAt:u}.");
        }

        return (int)ExitCode.Success;
    }

    public static async Task<int> PlanAsync(Options options)
    {
        using var cts = new CancellationTokenSource();
        var ctx = await BuildContextAsync(options, cts.Token);

        if (ctx.Resolution.Status != ResolutionStatus.Resolved)
        {
            return ReportResolutionProblem(options, ctx);
        }

        var env = ctx.Resolution.Environment!;
        var sourceRoot = ResolveSourceRoot(options, env);
        var tfmInfo = NarrowToRequestedFramework(
            TargetFrameworkInspector.Inspect(sourceRoot, options.Project), options.Framework);

        // Image identity: for generated environments, validate candidate tags against MCR and pre-resolve
        // the digest without pulling. Offline / --no-registry-check skips the network probe.
        string? requestedTag = null;
        string? reference = env.DockerImage;
        string? digest = null;
        string? imageNote = null;
        SdkVersion? channelSdk = SdkVersion.TryParse(env.Sdk);

        if (env.DockerFile is not null)
        {
            imageNote = $"Configured Dockerfile '{env.DockerFile}' will be built into a local image.";
        }
        else if (env.IsMultiSdk)
        {
            // The tag came from the publisher's own tag feed, so it exists by construction. Its digest is
            // resolved at pull time in `run`; there is no Microsoft registry probe to make here.
            requestedTag = env.DockerImage?.Split(':').Last();
            imageNote = $"Multi-SDK runner providing .NET {string.Join(", ", env.SupportedMajors)}; "
                + "the whole target-framework matrix runs in one container.";
        }
        else if (env.Origin == EnvironmentOrigin.Generated && channelSdk is not null)
        {
            var candidates = ImageTagResolver.CandidateTags(channelSdk);
            if (options.Offline || options.NoRegistryCheck)
            {
                requestedTag = candidates[0];
                reference = ImageTagResolver.SdkImageReference(requestedTag);
                imageNote = "Registry validation skipped; tag derived from release metadata.";
            }
            else
            {
                var (tag, resolution) = await RegistryClient.ResolveFirstAsync(RemoteTestProgram.SdkRepositoryPath, candidates, cts.Token);
                if (tag is null)
                {
                    imageNote = $"None of the candidate tags [{string.Join(", ", candidates)}] were found on {RemoteTestProgram.SdkRepository}. {resolution.Error}";
                    requestedTag = candidates[0];
                    reference = ImageTagResolver.SdkImageReference(requestedTag);
                }
                else
                {
                    requestedTag = tag;
                    reference = ImageTagResolver.SdkImageReference(tag);
                    digest = resolution.Digest;
                }
            }
        }

        var compatibility = TargetFrameworkInspector.CanBuild(channelSdk, tfmInfo, env.SupportedMajors);
        var compatibilityBlocking = SdkCompatibilityPolicy.IsBlocking(env.Origin, compatibility.Compatible);
        // Configured environments trust their image SDK (validated at run time); do not present or fail
        // them as incompatible just because the SDK could not be determined statically.
        var displayCompatible = env.Origin == EnvironmentOrigin.Generated ? compatibility.Compatible : true;
        var displayReason = env.Origin == EnvironmentOrigin.Generated
            ? compatibility.Reason
            : "Configured environment; the image SDK is trusted as provided and validated at run time.";
        var containerName = ContainerPlanner.ContainerName("planned");
        var testOptions = BuildTestOptions(options, sourceRoot);
        var mounts = new[]
        {
            new ContainerMount("<staged-workspace>", "/workspace", ReadOnly: false),
            new ContainerMount("<nuget-cache>", "/nuget", ReadOnly: false),
            new ContainerMount("<results-dir>", "/results", ReadOnly: false),
        };
        var plan = ContainerPlanner.Build(reference ?? "<unresolved-image>", containerName, mounts, testOptions);

        if (options.Json)
        {
            Console.WriteLine(JsonSerializer.Serialize(new
            {
                tool = RemoteTestProgram.ToolName,
                environment = new
                {
                    env.Name,
                    origin = env.Origin.ToString(),
                    env.Channel,
                    env.ReleaseType,
                    env.Sdk,
                    selectionReason = ctx.Resolution.SelectionReason,
                },
                image = new
                {
                    requested = env.DockerImage ?? reference,
                    tag = requestedTag,
                    reference,
                    dockerFile = env.DockerFile,
                    digest,
                    digestResolved = digest is not null,
                    recommendedPublisher = IsRecommendedPublisher(env.DockerImage ?? reference),
                    note = imageNote,
                },
                targetFrameworks = new
                {
                    frameworks = tfmInfo.TargetFrameworks,
                    globalJsonSdk = tfmInfo.GlobalJsonSdkVersion,
                    globalJsonRollForward = tfmInfo.GlobalJsonRollForward,
                },
                compatibility = new { Compatible = displayCompatible, Reason = displayReason },
                test = new { testOptions.Target, testOptions.Configuration, testOptions.Framework, testOptions.Filter, testOptions.Coverage },
                container = new { plan.ContainerName, mounts = plan.Mounts, environmentVariables = plan.Environment },
                entrypoint = plan.Entrypoint,
                dockerRunArgs = plan.DockerRunArgs,
            }, RemoteTestProgram.JsonOut));
        }
        else
        {
            Console.WriteLine($"Plan: {env.Name}");
            if (ctx.Resolution.SelectionReason is not null)
            {
                Console.WriteLine($"  Selection:   {ctx.Resolution.SelectionReason}");
            }

            Console.WriteLine($"  Image:       {env.DockerImage ?? reference ?? "(from Dockerfile)"}");
            if (requestedTag is not null)
            {
                Console.WriteLine($"  Tag:         {requestedTag}");
            }

            if (digest is not null)
            {
                Console.WriteLine($"  Digest:      {digest}");
            }

            if (imageNote is not null)
            {
                Console.WriteLine($"  Note:        {imageNote}");
            }

            Console.WriteLine($"  Frameworks:  {(tfmInfo.TargetFrameworks.Count > 0 ? string.Join(", ", tfmInfo.TargetFrameworks) : "(none detected)")}");
            Console.WriteLine($"  Compatible:  {displayCompatible}{(displayReason is null ? "" : $" — {displayReason}")}");
            Console.WriteLine($"  Container:   {plan.ContainerName}");
        }

        return compatibilityBlocking ? (int)ExitCode.SdkIncompatibility : (int)ExitCode.Success;
    }

    private static TestCommandOptions BuildTestOptions(Options options, string sourceRoot) => new()
    {
        Target = TargetResolver.Resolve(sourceRoot, options.Project),
        Configuration = options.Configuration,
        Framework = options.Framework,
        Filter = ContainerPlanner.ResolveFilter(options.Filter, options.Test),
        Coverage = options.Coverage,
    };

    // Recommended publishers for auto-generated environments: Microsoft's official SDK images and the
    // Codebelt multi-SDK test runner. This is reported, not enforced — an image from anywhere else is
    // allowed (a configured dockerImage is deliberate intent), it simply is not one we vouch for.
    private static bool IsRecommendedPublisher(string? reference) =>
        reference is not null
        && (reference.StartsWith(RemoteTestProgram.SdkRepository + ":", StringComparison.Ordinal)
            || reference.StartsWith(RemoteTestProgram.MultiSdkRepository + ":", StringComparison.Ordinal));

    private static string ResolveSourceRoot(Options options, ResolvedEnvironment env)
    {
        if (string.IsNullOrWhiteSpace(env.LocalRoot))
        {
            return options.RepoRoot;
        }

        return Path.IsPathRooted(env.LocalRoot)
            ? env.LocalRoot
            : Path.GetFullPath(Path.Combine(options.RepoRoot, env.LocalRoot));
    }

    private static int ReportResolutionProblem(Options options, ResolveContext ctx)
    {
        var res = ctx.Resolution;
        var kind = res.Status switch
        {
            ResolutionStatus.Unsupported => ExitCode.UnsupportedEnvironment,
            ResolutionStatus.Ambiguous => ExitCode.SelectionRequired,
            ResolutionStatus.NoEnvironments when ctx.MetadataError is not null => ExitCode.ReleaseMetadataUnavailable,
            ResolutionStatus.NoEnvironments => ExitCode.Configuration,
            _ => ExitCode.Configuration,
        };

        var message = res.Message ?? ctx.MetadataError ?? "Environment could not be resolved.";
        if (options.Json)
        {
            Console.WriteLine(JsonSerializer.Serialize(new
            {
                tool = RemoteTestProgram.ToolName,
                status = "error",
                failureKind = kind.ToString(),
                message,
                candidates = res.Candidates,
                metadataError = ctx.MetadataError,
                multiSdkError = ctx.MultiSdkError,
            }, RemoteTestProgram.JsonOut));
        }
        else
        {
            Console.Error.WriteLine($"{RemoteTestProgram.ToolName}: {message}");
            if (res.Candidates.Count > 0)
            {
                Console.Error.WriteLine("Available: " + string.Join(", ", res.Candidates));
            }

            if (ctx.MultiSdkError is not null)
            {
                Console.Error.WriteLine($"Multi-SDK runner discovery: {ctx.MultiSdkError}");
            }
        }

        return (int)kind;
    }

    private sealed record RunImage(
        string? Reference = null,
        string? Digest = null,
        string? RequestedTag = null,
        string? Sdk = null,
        FailureKind Kind = FailureKind.None,
        string? Error = null,
        string? PreparedReference = null,
        string? ProvisionNote = null);

    private sealed record CleanupReport(bool ContainerRemoved, bool WorkspaceRemoved, IReadOnlyList<string> Leftovers);

    public static async Task<int> RunAsync(Options options)
    {
        using var cts = new CancellationTokenSource();
        if (options.TimeoutSeconds > 0)
        {
            cts.CancelAfter(TimeSpan.FromSeconds(options.TimeoutSeconds));
        }

        var cancelled = false;
        void OnCancel(object? _, ConsoleCancelEventArgs e) { e.Cancel = true; cancelled = true; cts.Cancel(); }
        Console.CancelKeyPress += OnCancel;

        // Wall clock for the whole operation. Reported alongside the test duration from the TRX so a
        // fast test suite behind a slow image pull never looks like the run itself took no time.
        var wallClock = Stopwatch.StartNew();

        var containerName = ContainerPlanner.ContainerName(Guid.NewGuid().ToString("N")[..8]);
        var runRoot = Path.Combine(Path.GetTempPath(), "dotnet-remote-testing", containerName);
        string? stagingRoot = null;

        try
        {
            var ctx = await BuildContextAsync(options, cts.Token);
            if (ctx.Resolution.Status != ResolutionStatus.Resolved)
            {
                return ReportResolutionProblem(options, ctx);
            }

            var env = ctx.Resolution.Environment!;

            if (!await DockerClient.IsAvailableAsync(cts.Token))
            {
                return Error(options, FailureKind.DockerUnavailable,
                    "Docker is not available. Start Docker Desktop / the Docker daemon and retry. Remote testing never falls back to the local host.");
            }

            var sourceRoot = ResolveSourceRoot(options, env);
            var tfmInfo = NarrowToRequestedFramework(
                TargetFrameworkInspector.Inspect(sourceRoot, options.Project), options.Framework);
            var channelSdk = SdkVersion.TryParse(env.Sdk);
            var compat = TargetFrameworkInspector.CanBuild(channelSdk, tfmInfo, env.SupportedMajors);
            if (SdkCompatibilityPolicy.IsBlocking(env.Origin, compat.Compatible))
            {
                return Error(options, FailureKind.SdkIncompatibility, compat.Reason ?? "The selected SDK cannot build the requested target framework.");
            }

            var image = await ResolveImageForRunAsync(options, env, channelSdk, cts.Token);
            if (image.Error is not null)
            {
                return Error(options, image.Kind, image.Error);
            }

            // The image runs the build, not just the tests, so it must carry what the build shells out to.
            var prepared = await ImageProvisioner.EnsureAsync(
                image.Reference!, image.Digest, runRoot, options.Offline, cts.Token);
            image = image with { PreparedReference = prepared.Provisioned ? prepared.Reference : null, ProvisionNote = prepared.Note };

            var resultsRoot = Path.Combine(runRoot, "results");
            stagingRoot = Path.Combine(runRoot, "workspace");
            Directory.CreateDirectory(resultsRoot);

            var staging = await SourceStager.StageAsync(sourceRoot, stagingRoot, cts.Token, includeGitMetadata: !options.NoGitMetadata);
            if (staging.Error is not null || staging.StagedPath is null)
            {
                return Error(options, FailureKind.SourceStaging, staging.Error ?? "Source staging produced no workspace.");
            }

            // NuGet packages cache persists across runs and lives outside the repository.
            var nugetCache = Path.Combine(options.CacheDirectory, "nuget");
            Directory.CreateDirectory(nugetCache);

            var testOptions = BuildTestOptions(options, sourceRoot);
            var mounts = new[]
            {
                new ContainerMount(staging.StagedPath, "/workspace", ReadOnly: false),
                new ContainerMount(nugetCache, "/nuget", ReadOnly: false),
                new ContainerMount(resultsRoot, "/results", ReadOnly: false),
            };
            var plan = ContainerPlanner.Build(prepared.Reference, containerName, mounts, testOptions);

            ProcessResult proc;
            try
            {
                proc = await DockerClient.RunAsync(plan.DockerRunArgs, cts.Token);
            }
            catch (OperationCanceledException)
            {
                cancelled = true;
                proc = new ProcessResult(-1, "", "", TimedOut: true);
            }

            cancelled |= proc.TimedOut;

            var results = TrxParser.ParseDirectory(resultsRoot, AssemblyNameIndex.Build(sourceRoot));
            var phaseMarkers = FailureClassifier.ParsePhaseMarkers(proc.StdOut);
            var outcome = FailureClassifier.Classify(phaseMarkers, proc.ExitCode, cancelled, results);

            var cleanup = await CleanupAsync(containerName, runRoot, cts.Token);

            return EmitRunResult(
                options, env, image, tfmInfo, results, outcome, proc, cleanup,
                ctx.Resolution.SelectionReason, wallClock.Elapsed.TotalSeconds, staging);
        }
        catch (OperationCanceledException)
        {
            await CleanupAsync(containerName, runRoot, CancellationToken.None);
            return Error(options, FailureKind.Cancelled, "The remote test run was cancelled.");
        }
        finally
        {
            Console.CancelKeyPress -= OnCancel;
            // Safety net: ensure nothing is left running even if an exception escaped before cleanup.
            await CleanupAsync(containerName, runRoot, CancellationToken.None);
        }
    }

    private static async Task<RunImage> ResolveImageForRunAsync(
        Options options, ResolvedEnvironment env, SdkVersion? channelSdk, CancellationToken ct)
    {
        // Configured Dockerfile: honor it exactly. We never generate one; we only build an existing one.
        if (env.DockerFile is not null)
        {
            var dockerfilePath = Path.IsPathRooted(env.DockerFile) ? env.DockerFile : Path.Combine(options.RepoRoot, env.DockerFile);
            if (!File.Exists(dockerfilePath))
            {
                return new RunImage(Kind: FailureKind.ImageResolution, Error: $"Configured dockerFile not found: {env.DockerFile}");
            }

            var localTag = $"dotnet-remote-testing/{SanitizeTag(env.Name)}:local";
            var context = Path.GetDirectoryName(dockerfilePath)!;
            var build = await DockerClient.BuildAsync(dockerfilePath, context, localTag, ct);
            if (build.ExitCode != 0)
            {
                return new RunImage(Kind: FailureKind.ImageResolution, Error: $"docker build of '{env.DockerFile}' failed: {LastLine(build.StdErr)}");
            }

            var id = await DockerClient.ResolveImageIdAsync(localTag, ct);
            return new RunImage(Reference: localTag, Digest: id, RequestedTag: localTag, Sdk: env.Sdk);
        }

        string reference;
        string? requestedTag = null;
        if (env.Origin == EnvironmentOrigin.Generated && channelSdk is not null)
        {
            var candidates = ImageTagResolver.CandidateTags(channelSdk);
            if (options.Offline || options.NoRegistryCheck)
            {
                requestedTag = candidates[0];
            }
            else
            {
                var (tag, _) = await RegistryClient.ResolveFirstAsync(RemoteTestProgram.SdkRepositoryPath, candidates, ct);
                requestedTag = tag ?? candidates[0];
            }

            reference = ImageTagResolver.SdkImageReference(requestedTag);
        }
        else
        {
            // A configured dockerImage (deliberate repository intent) or a multi-SDK runner tag taken
            // from the publisher's tag feed. Both are used exactly as written; the digest is resolved
            // from the pulled image below.
            reference = env.DockerImage!;
        }

        var pull = await DockerClient.PullAsync(reference, ct);
        if (pull.ExitCode != 0)
        {
            return new RunImage(Kind: FailureKind.ImageResolution, Error: $"Could not pull image '{reference}': {LastLine(pull.StdErr)}");
        }

        var digest = await DockerClient.ResolveDigestAsync(reference, ct) ?? await DockerClient.ResolveImageIdAsync(reference, ct);
        return new RunImage(Reference: reference, Digest: digest, RequestedTag: requestedTag, Sdk: env.Sdk);
    }

    private static async Task<CleanupReport> CleanupAsync(string containerName, string runRoot, CancellationToken ct)
    {
        var leftovers = new List<string>();

        var removed = await DockerClient.RemoveContainerAsync(containerName, ct);
        if (!removed)
        {
            leftovers.Add($"container:{containerName}");
        }

        var workspaceRemoved = true;
        if (Directory.Exists(runRoot))
        {
            try
            {
                Directory.Delete(runRoot, recursive: true);
            }
            catch (Exception)
            {
                workspaceRemoved = false;
                leftovers.Add($"workspace:{runRoot}");
            }
        }

        return new CleanupReport(removed, workspaceRemoved, leftovers);
    }

    private static int EmitRunResult(
        Options options,
        ResolvedEnvironment env,
        RunImage image,
        TargetFrameworkInfo tfmInfo,
        TestRunResult results,
        ExecutionOutcome outcome,
        ProcessResult proc,
        CleanupReport cleanup,
        string? selectionReason = null,
        double? elapsedSeconds = null,
        StagingResult? staging = null)
    {
        var exit = FailureClassifier.ToExitCode(outcome.Kind);
        if (outcome.Kind == FailureKind.None && cleanup.Leftovers.Count > 0)
        {
            exit = ExitCode.Cleanup;
        }

        var status = outcome.Kind switch
        {
            FailureKind.None => "passed",
            FailureKind.TestFailure => "failed",
            _ => "error",
        };

        if (options.Json)
        {
            Console.WriteLine(JsonSerializer.Serialize(new
            {
                tool = RemoteTestProgram.ToolName,
                status,
                failureKind = outcome.Kind == FailureKind.None ? null : outcome.Kind.ToString(),
                phase = outcome.Phase,
                message = outcome.Message,
                environment = new { env.Name, origin = env.Origin.ToString(), env.Channel, env.ReleaseType, selectionReason },
                image = new
                {
                    requested = image.RequestedTag,
                    reference = image.Reference,
                    digest = image.Digest,
                    sdk = image.Sdk,
                    prepared = image.PreparedReference,
                    provisioning = image.ProvisionNote,
                },
                targetFrameworks = tfmInfo.TargetFrameworks,
                workspace = new { gitMetadataStaged = staging?.GitMetadataStaged, gitMetadataNote = staging?.GitMetadataNote },
                tests = new { results.Total, results.Passed, results.Skipped, results.Failed, results.DurationSeconds, trxFiles = results.TrxFilesParsed },
                testAssemblies = results.Assemblies.Select(a => new { a.Assembly, a.Framework, a.Total, a.Passed, a.Failed, a.Skipped, a.DurationSeconds }),
                elapsedSeconds = elapsedSeconds is null ? (double?)null : Math.Round(elapsedSeconds.Value, 1),
                failures = results.Failures.Select(f => new { f.TestName, f.ClassName, f.Assembly, f.Framework, f.DurationSeconds, f.Message, f.StackTrace, f.Output }),
                cleanup = new { cleanup.ContainerRemoved, cleanup.WorkspaceRemoved, cleanup.Leftovers },
                diagnostics = status == "error"
                    ? new { containerExitCode = proc.ExitCode, phaseLogTail = LastLines(FailureClassifier.PhaseOutput(proc.StdOut, outcome.Phase), 40), stderrTail = LastLines(proc.StdErr, 20) }
                    : null,
                containerLog = options.ShowLog ? proc.StdOut : null,
            }, RemoteTestProgram.JsonOut));
            return (int)exit;
        }

        // Concise human result: environment → image/digest/sdk → tests → duration, actionable on failure.
        Console.WriteLine($"Remote Test: {env.Name}");
        if (selectionReason is not null)
        {
            Console.WriteLine(selectionReason);
        }

        Console.WriteLine();
        Console.WriteLine($"Image:  {image.Reference}");
        if (image.Digest is not null)
        {
            Console.WriteLine($"Digest: {image.Digest}");
        }

        if (image.Sdk is not null)
        {
            Console.WriteLine($"SDK:    {image.Sdk}");
        }

        if (image.ProvisionNote is not null)
        {
            Console.WriteLine($"Tools:  {image.ProvisionNote}");
        }

        if (staging?.GitMetadataNote is not null)
        {
            Console.WriteLine($"Note:   {staging.GitMetadataNote}");
        }

        Console.WriteLine();

        if (outcome.Kind is FailureKind.None or FailureKind.TestFailure)
        {
            // Per assembly/TFM first — the same unit `dotnet test` reports on, so a failure is
            // immediately attributable to one test project and one target framework.
            var width = results.Assemblies.Count == 0 ? 0 : results.Assemblies.Max(a => a.Display.Length);
            foreach (var a in results.Assemblies)
            {
                var verdict = a.Failed > 0 ? "Failed!" : "Passed!";
                Console.WriteLine(
                    $"{verdict,-8} {a.Display.PadRight(width)}  —  {a.Passed} passed, {a.Skipped} skipped, {a.Failed} failed, {a.DurationSeconds.ToString("0.0", CultureInfo.InvariantCulture)} s");
            }

            if (results.Assemblies.Count > 0)
            {
                Console.WriteLine();
            }

            Console.WriteLine($"Tests:  {results.Passed} passed, {results.Skipped} skipped, {results.Failed} failed");
            Console.WriteLine($"Time:   {results.DurationSeconds.ToString("0.0", CultureInfo.InvariantCulture)} s (tests)");
            if (elapsedSeconds is not null)
            {
                Console.WriteLine($"Total:  {elapsedSeconds.Value.ToString("0.0", CultureInfo.InvariantCulture)} s (including image pull, restore and build)");
            }

            WriteFailureDetail(results);
        }
        else
        {
            Console.Error.WriteLine($"{outcome.Kind}: {outcome.Message}");

            // Any TRX that was produced before the failure still names real failing tests; report those
            // first so a test-host crash after a genuine assertion failure is not reduced to a log tail.
            WriteFailureDetail(results);

            // The container writes compiler/restore/test diagnostics to stdout, so a stderr-only tail
            // would leave the developer with a verdict and no cause. Prefer the failing phase's own log.
            var phaseLog = FailureClassifier.PhaseOutput(proc.StdOut, outcome.Phase);
            var detail = FirstNonEmpty(
                ErrorLines(phaseLog, 20), LastLines(phaseLog, 40), LastLines(proc.StdErr, 20), LastLines(proc.StdOut, 40));
            if (!string.IsNullOrWhiteSpace(detail))
            {
                Console.Error.WriteLine();
                Console.Error.WriteLine($"--- {outcome.Phase} output ---");
                Console.Error.WriteLine(detail);
            }
        }

        if (options.ShowLog && !string.IsNullOrWhiteSpace(proc.StdOut))
        {
            Console.WriteLine();
            Console.WriteLine("--- container log ---");
            Console.WriteLine(proc.StdOut.TrimEnd());
        }

        if (cleanup.Leftovers.Count > 0)
        {
            Console.Error.WriteLine("Cleanup left resources: " + string.Join(", ", cleanup.Leftovers));
        }

        return (int)exit;
    }

    // Caps so a suite that fails wholesale stays readable; the counts above remain authoritative and the
    // full detail is always available in --json.
    private const int MaxReportedFailures = 15;
    private const int MaxStackFrames = 10;
    private const int MaxOutputLines = 15;

    // The detail a developer actually needs to fix a red test: fully-qualified name, which TFM, the
    // assertion message, the stack, and whatever the test wrote to its output helper.
    private static void WriteFailureDetail(TestRunResult results)
    {
        if (results.Failures.Count == 0)
        {
            return;
        }

        Console.WriteLine();
        Console.WriteLine(results.Failures.Count == 1 ? "1 test failed:" : $"{results.Failures.Count} tests failed:");

        foreach (var f in results.Failures.Take(MaxReportedFailures))
        {
            var name = f.ClassName is not null && !f.TestName.StartsWith(f.ClassName, StringComparison.Ordinal)
                ? $"{f.ClassName}.{f.TestName}"
                : f.TestName;
            var where = f.Framework is null ? "" : $" [{f.Framework}]";
            var took = f.DurationSeconds > 0 ? $" ({(f.DurationSeconds * 1000).ToString("0", CultureInfo.InvariantCulture)} ms)" : "";

            Console.WriteLine();
            Console.WriteLine($"  Failed {name}{where}{took}");
            WriteIndented(f.Message, "    ", int.MaxValue);

            if (!string.IsNullOrWhiteSpace(f.StackTrace))
            {
                Console.WriteLine("    Stack trace:");
                WriteIndented(f.StackTrace, "      ", MaxStackFrames);
            }

            if (!string.IsNullOrWhiteSpace(f.Output))
            {
                Console.WriteLine("    Output:");
                WriteIndented(f.Output, "      ", MaxOutputLines);
            }
        }

        if (results.Failures.Count > MaxReportedFailures)
        {
            Console.WriteLine();
            Console.WriteLine($"  … and {results.Failures.Count - MaxReportedFailures} more failing test(s); rerun with --json for the full list.");
        }
    }

    private static void WriteIndented(string? text, string indent, int maxLines)
    {
        if (string.IsNullOrWhiteSpace(text))
        {
            return;
        }

        var lines = text.Replace("\r\n", "\n", StringComparison.Ordinal).Split('\n');
        foreach (var line in lines.Take(maxLines))
        {
            Console.WriteLine(indent + line.TrimEnd());
        }

        if (lines.Length > maxLines)
        {
            Console.WriteLine($"{indent}… {lines.Length - maxLines} more line(s)");
        }
    }

    private static int Error(Options options, FailureKind kind, string message)
    {
        if (options.Json)
        {
            Console.WriteLine(JsonSerializer.Serialize(new
            {
                tool = RemoteTestProgram.ToolName,
                status = "error",
                failureKind = kind.ToString(),
                message,
            }, RemoteTestProgram.JsonOut));
        }
        else
        {
            Console.Error.WriteLine($"{RemoteTestProgram.ToolName}: {message}");
        }

        return (int)FailureClassifier.ToExitCode(kind);
    }

    private static string SanitizeTag(string name)
    {
        var sb = new StringBuilder();
        foreach (var c in name.ToLowerInvariant())
        {
            sb.Append(char.IsLetterOrDigit(c) || c is '.' or '_' or '-' ? c : '-');
        }

        return sb.ToString();
    }

    private static string LastLine(string s) =>
        s.Split('\n', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries).LastOrDefault() ?? "";

    private static string LastLines(string s, int count)
    {
        var lines = s.Split('\n', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries);
        return string.Join('\n', lines.TakeLast(count));
    }

    // MSBuild/NuGet diagnostics, distilled from the build log so a failure names its cause.
    private static string ErrorLines(string s, int count)
    {
        var lines = s.Split('\n', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries)
            .Where(l => l.Contains(" error ", StringComparison.OrdinalIgnoreCase)
                || l.Contains(": error", StringComparison.OrdinalIgnoreCase)
                || l.StartsWith("error", StringComparison.OrdinalIgnoreCase))
            .Distinct(StringComparer.Ordinal)
            .ToList();
        return string.Join('\n', lines.TakeLast(count));
    }

    private static string FirstNonEmpty(params string[] candidates) =>
        candidates.FirstOrDefault(c => !string.IsNullOrWhiteSpace(c)) ?? "";
}

// ---------------------------------------------------------------------------------------------------
// Deterministic self-test suite. Covers configuration discovery, release metadata parsing, environment
// selection, unsupported-environment handling, image resolution/tag derivation, command planning,
// result parsing, failure classification, cancellation, and cleanup — all without Docker or network.
// ---------------------------------------------------------------------------------------------------

internal static class SelfTest
{
    private static int _passed;
    private static int _failed;

    public static int Run()
    {
        Console.WriteLine($"{RemoteTestProgram.ToolName} self-test");
        Console.WriteLine();

        ConfigDiscoveryTests();
        ReleaseMetadataTests();
        SdkAndImageTagTests();
        EnvironmentSelectionTests();
        MultiSdkRunnerTests();
        UnsupportedEnvironmentTests();
        TargetFrameworkTests();
        CommandPlanningTests();
        ImagePreparationTests();
        SourceStagingTests();
        ResultParsingTests();
        FailureClassificationTests();
        CancellationAndCleanupTests();

        Console.WriteLine();
        Console.WriteLine($"Self-test: {_passed} passed, {_failed} failed.");
        return _failed == 0 ? (int)ExitCode.Success : (int)ExitCode.TestFailures;
    }

    private const string SampleReleaseIndex = """
    {
      "releases-index": [
        { "channel-version": "11.0", "latest-sdk": "11.0.100-preview.6.26359.118", "support-phase": "preview", "release-type": "sts" },
        { "channel-version": "10.0", "latest-sdk": "10.0.302", "support-phase": "active", "release-type": "lts", "eol-date": "2028-11-14" },
        { "channel-version": "9.0", "latest-sdk": "9.0.316", "support-phase": "maintenance", "release-type": "sts", "eol-date": "2026-11-10" },
        { "channel-version": "8.0", "latest-sdk": "8.0.423", "support-phase": "maintenance", "release-type": "lts", "eol-date": "2026-11-10" },
        { "channel-version": "7.0", "latest-sdk": "7.0.410", "support-phase": "eol", "release-type": "sts" },
        { "channel-version": "6.0", "latest-sdk": "6.0.428", "support-phase": "eol", "release-type": "lts" }
      ]
    }
    """;

    private static void ConfigDiscoveryTests()
    {
        Section("Configuration discovery");

        var valid = TestEnvironmentsConfigReader.Parse("""
        { "version": "1", "environments": [ { "name": "dotnet-10", "type": "docker", "dockerImage": "mcr.microsoft.com/dotnet/sdk:10.0" } ] }
        """, "testenvironments.json");
        Check("version 1 supported", valid.VersionSupported);
        Check("single docker env recognized", valid.SupportedDockerEnvironments.Count == 1);
        Check("dockerImage captured", valid.SupportedDockerEnvironments[0].DockerImage == "mcr.microsoft.com/dotnet/sdk:10.0");
        Check("no diagnostics for valid config", valid.Diagnostics.Count == 0);

        var localRoot = TestEnvironmentsConfigReader.Parse("""
        { "version": "1", "environments": [ { "name": "d", "type": "docker", "dockerFile": "Dockerfile.test", "localRoot": "src" } ] }
        """);
        Check("dockerFile captured", localRoot.SupportedDockerEnvironments.Count == 1 && localRoot.SupportedDockerEnvironments[0].DockerFile == "Dockerfile.test");
        Check("localRoot honored", localRoot.Environments[0].LocalRoot == "src");

        var badVersion = TestEnvironmentsConfigReader.Parse("""{ "version": "2", "environments": [] }""");
        Check("version 2 rejected", !badVersion.VersionSupported && badVersion.Diagnostics.Any(d => d.Code == "UNSUPPORTED_VERSION"));

        var conflicting = TestEnvironmentsConfigReader.Parse("""
        { "version": "1", "environments": [ { "name": "x", "type": "docker", "dockerImage": "a", "dockerFile": "b" } ] }
        """);
        Check("dockerImage+dockerFile conflict flagged", conflicting.Diagnostics.Any(d => d.Code == "CONFLICTING_DOCKER_SOURCE"));
        Check("conflicting docker env is not usable", conflicting.SupportedDockerEnvironments.Count == 0);

        var missing = TestEnvironmentsConfigReader.Parse("""
        { "version": "1", "environments": [ { "name": "x", "type": "docker" } ] }
        """);
        Check("docker env without image or file flagged", missing.Diagnostics.Any(d => d.Code == "MISSING_DOCKER_SOURCE"));

        var invalid = TestEnvironmentsConfigReader.Parse("{ not json ");
        Check("invalid json reported", invalid.Diagnostics.Any(d => d.Code == "INVALID_JSON"));
    }

    private static void ReleaseMetadataTests()
    {
        Section("Release metadata parsing");

        var channels = ReleaseIndexReader.Parse(SampleReleaseIndex);
        var metadata = new ReleaseMetadata { Channels = channels };

        Check("all channels parsed", channels.Count == 6);
        Check("eol excluded from stable", metadata.SupportedStableChannels.All(c => !c.IsEol));
        Check("preview excluded from stable", metadata.SupportedStableChannels.All(c => !c.IsPreview));
        Check("stable channels are 10, 9, 8", metadata.SupportedStableChannels.Select(c => c.MajorVersion).SequenceEqual([10, 9, 8]));
        Check("preview channel is 11", metadata.PreviewChannels.Count == 1 && metadata.PreviewChannels[0].MajorVersion == 11);
        Check("release-type drives lts/sts, not parity", channels.First(c => c.ChannelVersion == "9.0").IsSts && channels.First(c => c.ChannelVersion == "8.0").IsLts);

        var generated = GeneratedEnvironments.FromMetadata(metadata);
        Check("generated names derived from metadata", generated.Select(e => e.Name).SequenceEqual(
            ["dotnet-10-lts", "dotnet-9-sts", "dotnet-8-lts", "dotnet-11-preview"]));
        Check("generated images use mcr sdk repo", generated.All(e => e.DockerImage!.StartsWith("mcr.microsoft.com/dotnet/sdk:")));
        Check("preview env labeled Preview", generated.First(e => e.Name == "dotnet-11-preview").ReleaseType == "Preview");

        var cacheRoot = Path.Combine(Path.GetTempPath(), "dotnet-remote-testing-self-test-" + Guid.NewGuid().ToString("N"));
        try
        {
            Directory.CreateDirectory(cacheRoot);
            using var indexDocument = JsonDocument.Parse(SampleReleaseIndex);
            var cachePayload = new
            {
                retrievedAt = "2026-08-10T00:00:00.0000000+00:00",
                source = RemoteTestProgram.ReleasesIndexUrl,
                releasesIndex = indexDocument.RootElement.GetProperty("releases-index"),
            };
            File.WriteAllText(
                Path.Combine(cacheRoot, "releases-index.cache.json"),
                JsonSerializer.Serialize(cachePayload, RemoteTestProgram.JsonOut));

            var cached = ReleaseMetadataStore.LoadAsync(
                Options.Parse(["list", "--offline", "--cache-root", cacheRoot]),
                CancellationToken.None).GetAwaiter().GetResult();
            Check("cached release array is parsed as release metadata",
                cached.Error is null && cached.Metadata is not null && cached.Metadata.IsStale && cached.Metadata.Channels.Count == 6);
        }
        finally
        {
            try { Directory.Delete(cacheRoot, recursive: true); }
            catch (IOException) { }
            catch (UnauthorizedAccessException) { }
        }
    }

    private static void SdkAndImageTagTests()
    {
        Section("SDK version and image tag derivation");

        var stable = SdkVersion.TryParse("10.0.302")!;
        Check("stable sdk parsed", stable is { Major: 10, Minor: 0, Feature: 302 } && !stable.IsPrerelease);
        Check("stable image tag is exact sdk", stable.ImageTag == "10.0.302");
        Check("channel tag is major.minor", stable.ChannelTag == "10.0");

        var preview = SdkVersion.TryParse("11.0.100-preview.6.26359.118")!;
        Check("preview sdk parsed", preview is { Major: 11, PreLabel: "preview", PreNumber: 6 } && preview.IsPrerelease);
        Check("preview build metadata stripped from tag", preview.ImageTag == "11.0.100-preview.6");

        var candidates = ImageTagResolver.CandidateTags(stable);
        Check("exact sdk tag preferred over channel tag", candidates[0] == "10.0.302" && candidates[1] == "10.0");
        Check("full reference built", ImageTagResolver.SdkImageReference("10.0.302") == "mcr.microsoft.com/dotnet/sdk:10.0.302");

        Check("garbage sdk returns null", SdkVersion.TryParse("not-a-version") is null);
    }

    private static void EnvironmentSelectionTests()
    {
        Section("Environment selection");

        var config = TestEnvironmentsConfigReader.Parse("""
        { "version": "1", "environments": [ { "name": "ci-docker", "type": "docker", "dockerImage": "mcr.microsoft.com/dotnet/sdk:10.0" } ] }
        """, "testenvironments.json");
        var generated = GeneratedEnvironments.FromMetadata(new ReleaseMetadata { Channels = ReleaseIndexReader.Parse(SampleReleaseIndex) });

        var single = EnvironmentResolver.Resolve(config, [], null);
        Check("single configured docker env auto-selected", single.Status == ResolutionStatus.Resolved && single.Environment!.Name == "ci-docker");

        var named = EnvironmentResolver.Resolve(config, generated, "dotnet-10-lts");
        Check("explicit name can select a generated env even when config exists", named.Status == ResolutionStatus.Resolved && named.Environment!.Origin == EnvironmentOrigin.Generated);

        var twoConfig = TestEnvironmentsConfigReader.Parse("""
        { "version": "1", "environments": [
          { "name": "a", "type": "docker", "dockerImage": "img-a" },
          { "name": "b", "type": "docker", "dockerImage": "img-b" } ] }
        """, "testenvironments.json");
        var ambiguous = EnvironmentResolver.Resolve(twoConfig, [], null);
        Check("multiple configured envs require selection", ambiguous.Status == ResolutionStatus.Ambiguous && ambiguous.Candidates.SequenceEqual(["a", "b"]));

        var authoritative = EnvironmentResolver.Resolve(twoConfig, generated, null);
        Check("config is authoritative — generated not silently added", authoritative.Status == ResolutionStatus.Ambiguous && !authoritative.Candidates.Contains("dotnet-10-lts"));

        var zeroConfigSingle = EnvironmentResolver.Resolve(null, [generated[0]], null);
        Check("single generated env used with no config", zeroConfigSingle.Status == ResolutionStatus.Resolved);

        var zeroConfigMany = EnvironmentResolver.Resolve(null, generated, null);
        Check("multiple generated envs require selection", zeroConfigMany.Status == ResolutionStatus.Ambiguous);

        var notFound = EnvironmentResolver.Resolve(config, generated, "does-not-exist");
        Check("unknown name reported as not found", notFound.Status == ResolutionStatus.NotFound);

        // Deterministic tie-break: the repository's own target framework answers the question.
        var net10 = new TargetFrameworkInfo { TargetFrameworks = ["net10.0"] };
        var byTfm = EnvironmentResolver.Resolve(null, generated, null, net10);
        Check("target framework selects the matching channel without asking",
            byTfm.Status == ResolutionStatus.Resolved && byTfm.Environment!.Name == "dotnet-10-lts");
        Check("automatic selection explains itself", byTfm.SelectionReason is not null && byTfm.SelectionReason.Contains("net10.0"));

        // A single-SDK image ships one runtime, so a multi-targeted repository must not be silently
        // pointed at the newest channel — those lower target frameworks would build and then fail to run.
        var multiTargeted = new TargetFrameworkInfo { TargetFrameworks = ["net8.0", "net9.0", "net10.0"] };
        Check("multi-targeted repository is not sent to a single-SDK image",
            EnvironmentResolver.Resolve(null, generated, null, multiTargeted).Status == ResolutionStatus.Ambiguous);

        var runner = GeneratedEnvironments.FromMultiSdkRunner(
            new MultiSdkRunner { Tag = "8-9-10-11", Majors = [8, 9, 10, 11] });
        var withRunner = EnvironmentResolver.Resolve(null, [.. generated, runner], null, multiTargeted);
        Check("multi-targeted repository selects the covering multi-SDK runner",
            withRunner.Status == ResolutionStatus.Resolved && withRunner.Environment!.Name == "ubuntu-testrunner-8-9-10-11");
        Check("multi-SDK selection explains the whole-matrix benefit",
            withRunner.SelectionReason is not null && withRunner.SelectionReason.Contains("single container"));

        Check("single-target repository still prefers the matching single-SDK channel",
            EnvironmentResolver.Resolve(null, [.. generated, runner], null, net10).Environment!.Name == "dotnet-10-lts");

        var uncovered = new TargetFrameworkInfo { TargetFrameworks = ["net7.0", "net10.0"] };
        Check("a runner that does not cover every target framework is not selected",
            EnvironmentResolver.Resolve(null, [.. generated, runner], null, uncovered).Status == ResolutionStatus.Ambiguous);

        var previewOnly = new TargetFrameworkInfo { TargetFrameworks = ["net11.0"] };
        Check("preview channel is selectable by target framework",
            EnvironmentResolver.Resolve(null, generated, null, previewOnly).Environment!.Name == "dotnet-11-preview");

        var unsupportedMajor = new TargetFrameworkInfo { TargetFrameworks = ["net7.0"] };
        Check("target framework with no supported channel still asks",
            EnvironmentResolver.Resolve(null, generated, null, unsupportedMajor).Status == ResolutionStatus.Ambiguous);

        var noNetTarget = new TargetFrameworkInfo { TargetFrameworks = ["netstandard2.0"] };
        Check("non-.NET target framework does not guess a channel",
            EnvironmentResolver.Resolve(null, generated, null, noNetTarget).Status == ResolutionStatus.Ambiguous);

        Check("empty target framework info does not guess a channel",
            EnvironmentResolver.Resolve(null, generated, null, new TargetFrameworkInfo()).Status == ResolutionStatus.Ambiguous);

        var duplicateMajor = new List<ResolvedEnvironment>(generated)
        {
            generated.First(e => e.ChannelMajor == 10) with { Name = "dotnet-10-alt" },
        };
        Check("two channels for the same major stay ambiguous",
            EnvironmentResolver.Resolve(null, duplicateMajor, null, net10).Status == ResolutionStatus.Ambiguous);

        Check("configured environments are never auto-selected by target framework",
            EnvironmentResolver.Resolve(twoConfig, generated, null, net10).Status == ResolutionStatus.Ambiguous);

        Check("channel major parsed from channel version",
            generated.First(e => e.Name == "dotnet-10-lts").ChannelMajor == 10);
        Check("configured environment has no channel major",
            GeneratedEnvironments.FromConfigured(config.SupportedDockerEnvironments[0]).ChannelMajor == 0);
    }

    private const string SampleMultiSdkTags = """
    {
      "count": 8,
      "results": [
        { "name": "11.0.100-preview.7" },
        { "name": "10" },
        { "name": "10.0" },
        { "name": "8-9-10-11" },
        { "name": "8.0-9.0-10.0-11.0" },
        { "name": "9-10" },
        { "name": "8.0.421-9.0.314-10.0.300-11.0.100-preview.4" },
        { "name": "mono-net8.0.418-9.0.311-10.0.103" }
      ]
    }
    """;

    private static void MultiSdkRunnerTests()
    {
        Section("Multi-SDK runner discovery");

        var runners = MultiSdkTagReader.Parse(SampleMultiSdkTags);
        var tags = runners.Select(r => r.Tag).ToList();
        Check("combined major tags are discovered", tags.Contains("8-9-10-11") && tags.Contains("9-10"));
        Check("single-major tags are ignored", !tags.Contains("10") && !tags.Contains("10.0"));
        Check("channel and pinned combination forms are ignored",
            !tags.Contains("8.0-9.0-10.0-11.0") && !tags.Contains("8.0.421-9.0.314-10.0.300-11.0.100-preview.4"));
        Check("prefixed tags are ignored", !tags.Any(t => t.StartsWith("mono", StringComparison.Ordinal)));
        Check("majors parsed from the tag",
            runners.Single(r => r.Tag == "8-9-10-11").Majors.SequenceEqual([8, 9, 10, 11]));
        Check("image reference built from the publisher repository",
            runners.Single(r => r.Tag == "9-10").Reference == "codebeltnet/ubuntu-testrunner:9-10");

        Check("malformed feed yields no runners", MultiSdkTagReader.Parse("not json").Count == 0);
        Check("feed without results yields no runners", MultiSdkTagReader.Parse("""{ "count": 0 }""").Count == 0);

        // Tightest fit: cover every required major without dragging in SDKs the repository never asked for.
        Check("tightest covering tag wins",
            MultiSdkTagReader.Select(runners, [9, 10])!.Tag == "9-10");
        Check("wider tag used when the tight one does not cover",
            MultiSdkTagReader.Select(runners, [8, 10])!.Tag == "8-9-10-11");
        Check("no covering tag returns null",
            MultiSdkTagReader.Select(runners, [7, 10]) is null);
        Check("single major never selects a multi-SDK runner",
            MultiSdkTagReader.Select(runners, [10]) is null);

        var env = GeneratedEnvironments.FromMultiSdkRunner(runners.Single(r => r.Tag == "8-9-10-11"));
        Check("runner environment is named after its tag", env.Name == "ubuntu-testrunner-8-9-10-11");
        Check("runner environment is multi-SDK", env.IsMultiSdk && env.SupportedMajors.SequenceEqual([8, 9, 10, 11]));
        Check("runner environment carries no single channel", env.Channel is null && env.ChannelMajor == 0);

        // Compatibility is judged on declared majors, because presence is what lets the tests run.
        var spread = new TargetFrameworkInfo { TargetFrameworks = ["net8.0", "net10.0"] };
        Check("multi-SDK image is compatible with every provided target",
            TargetFrameworkInspector.CanBuild(null, spread, env.SupportedMajors).Compatible);
        Check("multi-SDK image rejects a target it does not provide",
            !TargetFrameworkInspector.CanBuild(null, new TargetFrameworkInfo { TargetFrameworks = ["net7.0"] }, env.SupportedMajors).Compatible);
        Check("multi-SDK image still cannot build .NET Framework",
            !TargetFrameworkInspector.CanBuild(null, new TargetFrameworkInfo { TargetFrameworks = ["net48"] }, env.SupportedMajors).Compatible);

        // The runtime gap that motivates the multi-SDK runner in the first place.
        var sdk10 = SdkVersion.TryParse("10.0.302");
        var singleSdkSpread = TargetFrameworkInspector.CanBuild(sdk10, spread);
        Check("single-SDK image is incompatible with a multi-targeted repository", !singleSdkSpread.Compatible);
        Check("the incompatibility names the missing runtime and the remedy",
            singleSdkSpread.Reason is not null
            && singleSdkSpread.Reason.Contains("net8.0")
            && singleSdkSpread.Reason.Contains(RemoteTestProgram.MultiSdkRepository));
        Check("single-SDK image remains compatible with its own single target",
            TargetFrameworkInspector.CanBuild(sdk10, new TargetFrameworkInfo { TargetFrameworks = ["net10.0"] }).Compatible);
    }

    private static void UnsupportedEnvironmentTests()
    {
        Section("Unsupported environment handling");

        var config = TestEnvironmentsConfigReader.Parse("""
        { "version": "1", "environments": [
          { "name": "wsl-env", "type": "wsl", "wslDistribution": "Ubuntu" },
          { "name": "ssh-env", "type": "ssh", "remoteUri": "ssh://user@host:22" } ] }
        """, "testenvironments.json");

        Check("wsl flagged unsupported", config.Diagnostics.Any(d => d.Code == "UNSUPPORTED_TYPE" && d.EnvironmentName == "wsl-env"));
        Check("ssh flagged unsupported", config.Diagnostics.Any(d => d.Code == "UNSUPPORTED_TYPE" && d.EnvironmentName == "ssh-env"));
        Check("unsupported envs excluded from docker set", config.SupportedDockerEnvironments.Count == 0);
        Check("unsupported envs still enumerated for reporting", config.UnsupportedEnvironments.Count == 2);

        var namedUnsupported = EnvironmentResolver.Resolve(config, [], "wsl-env");
        Check("naming an unsupported env reports Unsupported, not NotFound", namedUnsupported.Status == ResolutionStatus.Unsupported);

        var unknown = TestEnvironmentsConfigReader.Parse("""
        { "version": "1", "environments": [ { "name": "k8s", "type": "kubernetes" } ] }
        """);
        Check("unknown type flagged", unknown.Diagnostics.Any(d => d.Code == "UNKNOWN_TYPE"));
    }

    private static void TargetFrameworkTests()
    {
        Section("Target framework awareness");

        var single = TargetFrameworkInspector.ExtractTargetFrameworks("<Project><PropertyGroup><TargetFramework>net10.0</TargetFramework></PropertyGroup></Project>");
        Check("single TFM extracted", single.SequenceEqual(["net10.0"]));

        var multi = TargetFrameworkInspector.ExtractTargetFrameworks("<TargetFrameworks>net8.0;net10.0</TargetFrameworks>");
        Check("multi-targeting extracted", multi.SequenceEqual(["net8.0", "net10.0"]));

        Check("net major parsed", TargetFrameworkInspector.NetMajor("net10.0") == 10 && TargetFrameworkInspector.NetMajor("netcoreapp3.1") == 3);
        Check("netstandard has no core major", TargetFrameworkInspector.NetMajor("netstandard2.0") == 0);

        var (sdk, roll) = TargetFrameworkInspector.ParseGlobalJson("""{ "sdk": { "version": "10.0.302", "rollForward": "latestFeature" } }""");
        Check("global.json parsed", sdk == "10.0.302" && roll == "latestFeature");

        var sdk10 = SdkVersion.TryParse("10.0.302");
        Check("sdk builds and runs its own target", TargetFrameworkInspector.CanBuild(sdk10, new TargetFrameworkInfo { TargetFrameworks = ["net10.0"] }).Compatible);
        // A lower target compiles on a newer SDK but has no runtime in that image, so it is not runnable
        // there. This is why a multi-targeted repository needs a multi-SDK runner.
        Check("sdk alone cannot run a lower target it can build",
            !TargetFrameworkInspector.CanBuild(sdk10, new TargetFrameworkInfo { TargetFrameworks = ["net8.0", "net10.0"] }).Compatible);
        Check("sdk cannot build newer target", !TargetFrameworkInspector.CanBuild(sdk10, new TargetFrameworkInfo { TargetFrameworks = ["net11.0"] }).Compatible);
        Check("linux sdk cannot build net framework", !TargetFrameworkInspector.CanBuild(sdk10, new TargetFrameworkInfo { TargetFrameworks = ["net48"] }).Compatible);
        Check("global.json disable pin mismatch is incompatible", !TargetFrameworkInspector.CanBuild(sdk10,
            new TargetFrameworkInfo { TargetFrameworks = ["net10.0"], GlobalJsonSdkVersion = "11.0.100", GlobalJsonRollForward = "disable" }).Compatible);

        // Only generated environments block on incompatibility; configured images are trusted (validated at run time).
        Check("generated env with incompatible SDK is blocking", SdkCompatibilityPolicy.IsBlocking(EnvironmentOrigin.Generated, compatible: false));
        Check("generated env with compatible SDK is not blocking", !SdkCompatibilityPolicy.IsBlocking(EnvironmentOrigin.Generated, compatible: true));
        Check("configured env is never blocked on undetermined SDK", !SdkCompatibilityPolicy.IsBlocking(EnvironmentOrigin.Configured, compatible: false));
    }

    private static void CommandPlanningTests()
    {
        Section("Command planning");

        Check("filter passthrough", ContainerPlanner.ResolveFilter("Category=Unit", null) == "Category=Unit");
        Check("--test becomes FullyQualifiedName filter", ContainerPlanner.ResolveFilter(null, "StringUtilityTest") == "FullyQualifiedName~StringUtilityTest");

        var entry = ContainerPlanner.BuildEntrypoint(new TestCommandOptions
        {
            Target = "test/Foo/Foo.csproj",
            Configuration = "Release",
            Framework = "net10.0",
            Filter = "Category=Unit",
            Coverage = true,
        });
        Check("entrypoint runs restore/build/test in order",
            entry.IndexOf("run_phase restore", StringComparison.Ordinal) < entry.IndexOf("run_phase build", StringComparison.Ordinal)
            && entry.IndexOf("run_phase build", StringComparison.Ordinal) < entry.IndexOf("run_phase test", StringComparison.Ordinal));
        // Trailing slash is required: NuGet's package root becomes an MSBuild SourceRoot and SourceLink
        // fails the build without it.
        Check("entrypoint sets NUGET_PACKAGES to the cache mount", entry.Contains("export NUGET_PACKAGES='/nuget/'"));
        Check("nuget package root ends with a separator",
            ContainerPlanner.NuGetPackagesPath("/nuget") == "/nuget/" && ContainerPlanner.NuGetPackagesPath("/nuget/") == "/nuget/");
        Check("entrypoint uses --no-restore/--no-build to reuse phases", entry.Contains("--no-restore") && entry.Contains("--no-build"));
        Check("entrypoint honors configuration/framework/filter/coverage",
            entry.Contains("-c 'Release'") && entry.Contains("--framework 'net10.0'") && entry.Contains("--filter 'Category=Unit'") && entry.Contains("XPlat Code Coverage"));
        Check("entrypoint writes trx to results mount", entry.Contains("--results-directory '/results'") && entry.Contains("--logger trx"));

        var plan = ContainerPlanner.Build(
            "mcr.microsoft.com/dotnet/sdk:10.0.302",
            ContainerPlanner.ContainerName("abc123"),
            [
                new ContainerMount("/host/src", "/workspace", false),
                new ContainerMount("/host/nuget", "/nuget", false),
                new ContainerMount("/host/results", "/results", false),
            ],
            new TestCommandOptions());
        Check("container name is deterministic", plan.ContainerName == "dotnet-remote-testing-abc123");
        Check("docker run auto-removes the container", plan.DockerRunArgs.Contains("--rm"));
        Check("docker run names the container for cleanup", plan.DockerRunArgs.Contains("--name") && plan.DockerRunArgs.Contains("dotnet-remote-testing-abc123"));
        Check("bind mounts wired for workspace/nuget/results",
            plan.DockerRunArgs.Any(a => a.Contains("target=/workspace"))
            && plan.DockerRunArgs.Any(a => a.Contains("target=/nuget"))
            && plan.DockerRunArgs.Any(a => a.Contains("target=/results")));
        Check("security: no privileged flag", !plan.DockerRunArgs.Contains("--privileged"));
        Check("security: docker socket never mounted", !plan.DockerRunArgs.Any(a => a.Contains("/var/run/docker.sock")));
        Check("security: no port publishing", !plan.DockerRunArgs.Contains("-p") && !plan.DockerRunArgs.Contains("--publish"));
        Check("image is the last-but-command arg", plan.DockerRunArgs.Contains("mcr.microsoft.com/dotnet/sdk:10.0.302"));

        // Target resolution against a temp source tree.
        var tempRoot = Path.Combine(Path.GetTempPath(), "drt-selftest-" + Guid.NewGuid().ToString("N"));
        try
        {
            Directory.CreateDirectory(Path.Combine(tempRoot, "test", "Foo"));
            File.WriteAllText(Path.Combine(tempRoot, "test", "Foo", "Foo.csproj"), "<Project/>");
            Check("single project auto-resolved when no solution", TargetResolver.Resolve(tempRoot, null) == "test/Foo/Foo.csproj");
            File.WriteAllText(Path.Combine(tempRoot, "App.slnx"), "<Solution/>");
            Check("root solution preferred over project", TargetResolver.Resolve(tempRoot, null) == "App.slnx");
            Check("explicit project overrides discovery", TargetResolver.Resolve(tempRoot, "test/Foo/Foo.csproj") == "test/Foo/Foo.csproj");
        }
        finally
        {
            try { Directory.Delete(tempRoot, true); } catch (Exception) { /* best effort */ }
        }
    }

    private static void ImagePreparationTests()
    {
        Section("Image preparation");

        const string digest = "sha256:990d47a4f925dedf27c875271c8b592e201666536f955befef9147745652f29f";
        var tag = ImageProvisioner.DerivedTag("codebeltnet/ubuntu-testrunner:8-9-10-11", digest);
        Check("prepared tag is derived from the base digest", tag == "dotnet-remote-testing/prepared:git-990d47a4f925dedf");
        Check("prepared tag is stable for the same image", ImageProvisioner.DerivedTag("other:tag", digest) == tag);
        Check("prepared tag changes with the base image",
            ImageProvisioner.DerivedTag("x:1", "sha256:abcdef0123456789abcdef") != tag);
        Check("prepared tag needs no digest", ImageProvisioner.DerivedTag("x:1", null).StartsWith("dotnet-remote-testing/prepared:git-", StringComparison.Ordinal));

        Check("probe asks the image for the tooling", ImageProvisioner.ProbeCommand() == "command -v git >/dev/null 2>&1");

        var dockerfile = ImageProvisioner.Dockerfile("codebeltnet/ubuntu-testrunner:8-9-10-11");
        Check("provisioning layers onto the resolved base image", dockerfile.StartsWith("FROM codebeltnet/ubuntu-testrunner:8-9-10-11", StringComparison.Ordinal));
        Check("provisioning installs the required tooling", dockerfile.Contains("install -y --no-install-recommends git"));
        Check("provisioning adapts to the image's package manager",
            dockerfile.Contains("command -v apt-get") && dockerfile.Contains("command -v apk") && dockerfile.Contains("command -v microdnf"));
        Check("provisioning fails loudly on an unknown package manager", dockerfile.Contains("No supported package manager"));

        // Installing needs root, but the prepared image must still run as whoever the base image runs
        // as; switching the image to root changes file ownership and permission-sensitive results.
        Check("provisioning does not leave a root-only image as root", !dockerfile.TrimEnd().EndsWith("USER root", StringComparison.Ordinal));
        var nonRoot = ImageProvisioner.Dockerfile("acme/runner:1", "app");
        Check("provisioning restores the base image's user", nonRoot.TrimEnd().EndsWith("USER app", StringComparison.Ordinal));
        Check("provisioning still installs as root", nonRoot.Contains("USER root", StringComparison.Ordinal));
        Check("provisioning adds no user line when the base image sets none",
            !ImageProvisioner.Dockerfile("acme/runner:1", "  ").Contains("USER app", StringComparison.Ordinal));
    }

    private static void SourceStagingTests()
    {
        Section("Source staging");

        var root = Path.Combine(Path.GetTempPath(), "rt-stage-" + Guid.NewGuid().ToString("N")[..8]);
        var source = Path.Combine(root, "repo");
        try
        {
            Directory.CreateDirectory(Path.Combine(source, "src"));
            Directory.CreateDirectory(Path.Combine(source, "bin"));
            Directory.CreateDirectory(Path.Combine(source, ".git", "refs"));
            File.WriteAllText(Path.Combine(source, "src", "App.csproj"), "<Project />");
            File.WriteAllText(Path.Combine(source, "bin", "stale.dll"), "x");
            File.WriteAllText(Path.Combine(source, ".git", "HEAD"), "ref: refs/heads/main");

            var staged = Path.Combine(root, "staged");
            var result = SourceStager.StageAsync(source, staged, CancellationToken.None).GetAwaiter().GetResult();

            Check("staging succeeds", result.Error is null && result.StagedPath == staged);
            Check("sources are staged", File.Exists(Path.Combine(staged, "src", "App.csproj")));

            var index = AssemblyNameIndex.Build(source);
            Check("project files provide the authoritative assembly casing", index["app.dll"] == "App.dll");
            Check("host build output is not staged", !Directory.Exists(Path.Combine(staged, "bin")));

            // Without .git the staged workspace stops being a repository: MinVer/Nerdbank fall back to
            // 0.0.0, SourceLink stops embedding, and any "walk up to the .git directory" repository-root
            // probe resolves elsewhere — which silently changes what the tests under it observe.
            Check("git metadata is staged", result.GitMetadataStaged && Directory.Exists(Path.Combine(staged, ".git")));
            Check("git metadata is staged verbatim",
                File.ReadAllText(Path.Combine(staged, ".git", "HEAD")) == "ref: refs/heads/main"
                && Directory.Exists(Path.Combine(staged, ".git", "refs")));
            Check("git metadata size is reported", result.GitMetadataBytes > 0);

            var without = Path.Combine(root, "staged-no-git");
            var opted = SourceStager.StageAsync(source, without, CancellationToken.None, includeGitMetadata: false).GetAwaiter().GetResult();
            Check("git metadata can be opted out", !opted.GitMetadataStaged && !Directory.Exists(Path.Combine(without, ".git")));
            Check("opting out is explained, not silent", opted.GitMetadataNote is not null);

            // A linked worktree or submodule stores .git as a "gitdir:" pointer file, not a directory.
            var linked = Path.Combine(root, "linked");
            Directory.CreateDirectory(linked);
            File.WriteAllText(Path.Combine(linked, "a.txt"), "a");
            File.WriteAllText(Path.Combine(linked, ".git"), $"gitdir: {Path.Combine(source, ".git")}");
            var linkedStaged = Path.Combine(root, "staged-linked");
            var linkedResult = SourceStager.StageAsync(linked, linkedStaged, CancellationToken.None).GetAwaiter().GetResult();
            Check("gitdir pointer file is resolved to the real git directory",
                linkedResult.GitMetadataStaged && File.Exists(Path.Combine(linkedStaged, ".git", "HEAD")));

            // A real linked worktree splits its git directory in two: per-worktree state here, objects
            // and refs in the shared "commondir". Staging only the near half leaves a git directory git
            // cannot read, so MinVer/Nerdbank fall back to 0.0.0 and SourceLink stops embedding.
            var common = Path.Combine(root, "main", ".git");
            var worktreeGit = Path.Combine(common, "worktrees", "wt");
            Directory.CreateDirectory(Path.Combine(common, "objects", "pack"));
            Directory.CreateDirectory(Path.Combine(common, "refs", "heads"));
            Directory.CreateDirectory(worktreeGit);
            File.WriteAllText(Path.Combine(common, "HEAD"), "ref: refs/heads/main");
            File.WriteAllText(Path.Combine(common, "config"), "[core]\n\tbare = false");
            File.WriteAllText(Path.Combine(common, "objects", "pack", "pack-1.pack"), "objects");
            File.WriteAllText(Path.Combine(common, "refs", "heads", "main"), "0123456789abcdef");
            File.WriteAllText(Path.Combine(worktreeGit, "HEAD"), "ref: refs/heads/feature");
            File.WriteAllText(Path.Combine(worktreeGit, "commondir"), "../..");
            File.WriteAllText(Path.Combine(worktreeGit, "gitdir"), Path.Combine(root, "wt", ".git"));

            var worktree = Path.Combine(root, "wt");
            Directory.CreateDirectory(worktree);
            File.WriteAllText(Path.Combine(worktree, "a.txt"), "a");
            File.WriteAllText(Path.Combine(worktree, ".git"), $"gitdir: {worktreeGit}");

            var worktreeStaged = Path.Combine(root, "staged-worktree");
            var worktreeResult = SourceStager.StageAsync(worktree, worktreeStaged, CancellationToken.None).GetAwaiter().GetResult();
            var stagedGit = Path.Combine(worktreeStaged, ".git");

            Check("worktree staging carries the shared objects and refs",
                worktreeResult.GitMetadataStaged
                && File.Exists(Path.Combine(stagedGit, "objects", "pack", "pack-1.pack"))
                && File.Exists(Path.Combine(stagedGit, "refs", "heads", "main"))
                && File.Exists(Path.Combine(stagedGit, "config")));
            Check("worktree staging keeps the worktree's own HEAD",
                File.ReadAllText(Path.Combine(stagedGit, "HEAD")) == "ref: refs/heads/feature");
            Check("worktree staging drops pointers to host paths",
                !File.Exists(Path.Combine(stagedGit, "commondir")) && !File.Exists(Path.Combine(stagedGit, "gitdir")));
            Check("worktree staging does not register host worktrees", !Directory.Exists(Path.Combine(stagedGit, "worktrees")));
            Check("worktree staging reports the merged size", worktreeResult.GitMetadataBytes > 0);

            // A repository with no git metadata at all is ordinary, not an error.
            var plain = Path.Combine(root, "plain");
            Directory.CreateDirectory(plain);
            File.WriteAllText(Path.Combine(plain, "a.txt"), "a");
            var plainResult = SourceStager.StageAsync(plain, Path.Combine(root, "staged-plain"), CancellationToken.None).GetAwaiter().GetResult();
            Check("a non-git source stages without a note", plainResult.Error is null && !plainResult.GitMetadataStaged && plainResult.GitMetadataNote is null);
        }
        finally
        {
            try { Directory.Delete(root, recursive: true); } catch (Exception) { /* temp cleanup is best-effort */ }
        }
    }

    private static void ResultParsingTests()
    {
        Section("Result parsing");

        const string trx = """
        <?xml version="1.0" encoding="UTF-8"?>
        <TestRun xmlns="http://microsoft.com/schemas/VisualStudio/TeamTest/2010">
          <Results>
            <UnitTestResult testId="id1" testName="StringUtilityTest.Passes" outcome="Passed" duration="00:00:00.1000000" />
            <UnitTestResult testId="id2" testName="Sanitize_WithUnicode_ReturnsExpectedValue" outcome="Failed" duration="00:00:00.2000000">
              <Output><StdOut>probing /workspace/tuning</StdOut><ErrorInfo><Message>Expected: foo Actual: bar</Message><StackTrace>at StringUtilityTest.cs:line 142</StackTrace></ErrorInfo></Output>
            </UnitTestResult>
            <UnitTestResult testId="id3" testName="StringUtilityTest.Skipped" outcome="NotExecuted" />
          </Results>
          <TestDefinitions>
            <UnitTest id="id2" name="Sanitize" storage="/workspace/test/Cuemon.Text.Tests/bin/Debug/net10.0/Cuemon.Text.Tests.dll"><TestMethod className="Cuemon.Text.Tests.StringUtilityTest, Cuemon.Text.Tests" name="Sanitize" /></UnitTest>
          </TestDefinitions>
          <ResultSummary outcome="Failed"><Counters total="3" executed="2" passed="1" failed="1" notExecuted="1" /></ResultSummary>
        </TestRun>
        """;

        var result = TrxParser.Parse(trx);
        Check("trx totals parsed", result is { Total: 3, Passed: 1, Failed: 1 });
        Check("skipped derived from notExecuted", result.Skipped == 1);
        Check("failure detail captured", result.Failures.Count == 1 && result.Failures[0].TestName == "Sanitize_WithUnicode_ReturnsExpectedValue");
        Check("failure class resolved from TestDefinitions", result.Failures[0].ClassName == "Cuemon.Text.Tests.StringUtilityTest");
        Check("failure message captured", result.Failures[0].Message == "Expected: foo Actual: bar");
        Check("failure stack trace captured", result.Failures[0].StackTrace == "at StringUtilityTest.cs:line 142");
        Check("test-written output captured", result.Failures[0].Output == "probing /workspace/tuning");
        Check("failure carries its assembly and framework",
            result.Failures[0].Assembly == "Cuemon.Text.Tests.dll" && result.Failures[0].Framework == "net10.0");

        Check("per-assembly summary produced",
            result.Assemblies.Count == 1 && result.Assemblies[0] is { Assembly: "Cuemon.Text.Tests.dll", Framework: "net10.0", Failed: 1 });
        Check("assembly summary displays framework", result.Assemblies[0].Display == "Cuemon.Text.Tests.dll (net10.0)");

        Check("framework derived from the output path",
            TrxParser.FrameworkFrom("/w/bin/Debug/net9.0/A.dll") == "net9.0"
            && TrxParser.FrameworkFrom(@"C:\w\bin\Release\net10.0-windows\A.dll") == "net10.0-windows"
            && TrxParser.FrameworkFrom("/w/bin/Debug/netstandard2.0/A.dll") == "netstandard2.0");
        Check("framework absent when the path has none", TrxParser.FrameworkFrom("/w/A.dll") is null);
        Check("assembly name derived from the storage path", TrxParser.AssemblyNameFrom(@"C:\w\bin\Debug\net10.0\A.Tests.dll") == "A.Tests.dll");

        // VSTest lower-cases the storage path; the developer knows the assembly by its real casing.
        var known = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase) { ["Acme.Tests.dll"] = "Acme.Tests.dll" };
        Check("assembly casing recovered from the repository's project files",
            TrxParser.AssemblyDisplayName("/w/bin/debug/net10.0/acme.tests.dll", null, known) == "Acme.Tests.dll");
        Check("an unknown assembly keeps the name the TRX recorded",
            TrxParser.AssemblyDisplayName("/w/bin/debug/net10.0/other.tests.dll", null, known) == "other.tests.dll");
        Check("assembly casing recovered from the class name",
            TrxParser.AssemblyDisplayName("/w/bin/debug/net10.0/acme.tests.dll", "Acme.Tests") == "Acme.Tests.dll");
        Check("a qualified display name is reduced to its simple name",
            TrxParser.AssemblyDisplayName("/w/bin/debug/net10.0/acme.tests.dll", "Acme.Tests, Version=1.0.0.0, Culture=neutral") == "Acme.Tests.dll");
        Check("a class name from another assembly never overrides storage",
            TrxParser.AssemblyDisplayName("/w/bin/Debug/net10.0/Acme.Tests.dll", "Shared.Fixtures") == "Acme.Tests.dll");
        Check("class name alone still names the assembly",
            TrxParser.AssemblyDisplayName(null, "Acme.Tests") == "Acme.Tests.dll");
        Check("neither source yields no assembly name", TrxParser.AssemblyDisplayName(null, null) is null);

        var merged = result.Merge(TrxParser.Parse(trx));
        Check("multiple trx files aggregate", merged is { Total: 6, Failed: 2, TrxFilesParsed: 2 });
        Check("assembly summaries aggregate too", merged.Assemblies.Count == 2);
    }

    private static void FailureClassificationTests()
    {
        Section("Failure classification");

        var passing = new TestRunResult { Total = 5, Passed = 5, TrxFilesParsed = 1 };
        var withFailures = new TestRunResult { Total = 5, Passed = 3, Failed = 2, TrxFilesParsed = 1 };

        Check("restore failure classified from phase marker",
            FailureClassifier.Classify(new Dictionary<string, int> { ["restore"] = 1 }, 9, false, TestRunResult.Empty).Kind == FailureKind.Restore);
        Check("build failure classified",
            FailureClassifier.Classify(new Dictionary<string, int> { ["restore"] = 0, ["build"] = 1 }, 10, false, TestRunResult.Empty).Kind == FailureKind.Compilation);
        Check("real test failures classified as TestFailure, not infrastructure",
            FailureClassifier.Classify(new Dictionary<string, int> { ["restore"] = 0, ["build"] = 0, ["test"] = 1 }, 1, false, withFailures).Kind == FailureKind.TestFailure);
        Check("nonzero test exit without failing trx is a test-host failure",
            FailureClassifier.Classify(new Dictionary<string, int> { ["restore"] = 0, ["build"] = 0, ["test"] = 1 }, 1, false, TestRunResult.Empty).Kind == FailureKind.TestHost);
        Check("all passing classified as None",
            FailureClassifier.Classify(new Dictionary<string, int> { ["restore"] = 0, ["build"] = 0, ["test"] = 0 }, 0, false, passing).Kind == FailureKind.None);
        Check("cancellation wins over everything",
            FailureClassifier.Classify(new Dictionary<string, int> { ["restore"] = 0 }, -1, true, passing).Kind == FailureKind.Cancelled);

        Check("test failure maps to exit code 1", FailureClassifier.ToExitCode(FailureKind.TestFailure) == ExitCode.TestFailures);
        Check("docker unavailable maps to distinct exit code", FailureClassifier.ToExitCode(FailureKind.DockerUnavailable) == ExitCode.DockerUnavailable);

        var markers = FailureClassifier.ParsePhaseMarkers("noise\n##RT_PHASE_END:restore:0##\nmore\n##RT_PHASE_END:build:2##\n");
        Check("phase markers parsed from output", markers["restore"] == 0 && markers["build"] == 2);

        // Reporting the failing phase's own log — not a tail of everything — is what makes a build
        // failure name the offending file instead of trailing test-runner chatter.
        const string log = "restoring\n##RT_PHASE_END:restore:0##\nApp.cs(3,5): error CS1002: ; expected\n##RT_PHASE_END:build:1##\ntest chatter\n";
        Check("phase log isolates restore", FailureClassifier.PhaseOutput(log, "restore") == "restoring");
        Check("phase log isolates build", FailureClassifier.PhaseOutput(log, "build") == "App.cs(3,5): error CS1002: ; expected");
        Check("an incomplete phase yields everything after the last marker",
            FailureClassifier.PhaseOutput(log, "test") == "test chatter");
        Check("phase log is empty when there is no output", FailureClassifier.PhaseOutput("", "build") == "");
    }

    private static void CancellationAndCleanupTests()
    {
        Section("Cancellation and cleanup");

        var name1 = ContainerPlanner.ContainerName("run-01");
        var name2 = ContainerPlanner.ContainerName("run-02");
        Check("container name is derivable and unique per run id", name1 != name2 && name1.StartsWith("dotnet-remote-testing-"));

        var outcome = FailureClassifier.Classify(new Dictionary<string, int>(), -1, cancelled: true, TestRunResult.Empty);
        Check("cancelled run classified as Cancelled", outcome.Kind == FailureKind.Cancelled);
        Check("cancelled maps to exit 14", FailureClassifier.ToExitCode(FailureKind.Cancelled) == ExitCode.Cancelled);

        // The knowable container name is what makes deterministic cleanup possible even after cancellation.
        var plan = ContainerPlanner.Build("img", name1, [], new TestCommandOptions());
        Check("cleanup target (container name) is embedded in the run args", plan.DockerRunArgs.Contains(name1));
    }

    private static void Section(string name) => Console.WriteLine($"[{name}]");

    private static void Check(string description, bool condition)
    {
        if (condition)
        {
            _passed++;
            Console.WriteLine($"  PASS  {description}");
        }
        else
        {
            _failed++;
            Console.WriteLine($"  FAIL  {description}");
        }
    }
}
