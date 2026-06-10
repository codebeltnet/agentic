#:property TargetFramework=net10.0
#:property Nullable=enable
#:property LangVersion=latest
#:property PublishAot=false

using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;

return AgentsScript.Run(args);

internal static class AgentsScript
{
    private const string ScriptId = "ensure-agents-docfx-digest";
    private const string AgentsFileName = "AGENTS.md";
    private const string StartMarker = "<!-- dotnet-docfx-digest:start -->";
    private const string EndMarker = "<!-- dotnet-docfx-digest:end -->";

    private static readonly Encoding Utf8NoBom = new UTF8Encoding(encoderShouldEmitUTF8Identifier: false);

    // Canonical managed block content. Stored with LF line endings; rendered with the
    // host file's detected line ending at write time. Begins with StartMarker and ends
    // with EndMarker so the prefix/suffix of the host file is preserved exactly.
    private const string ManagedBlock =
        """
        <!-- dotnet-docfx-digest:start -->
        ## DocFX Documentation Maintenance

        When changing public .NET APIs, keep the DocFX documentation current in the same change set.

        Documentation updates must cover public API only. Do not document private or internal types or members. Do not create namespace overview pages for namespaces that contain no public API.

        Public non-abstraction types — including enums, structs, records, plain classes, and static extension containers — are valid documentation targets. Generic public types and generic extension methods are valid documentation targets too. Do not exclude a type solely because it is generic or because reflection reports it as abstract and sealed (that is the IL pattern for a static class).

        For public non-abstraction types, include at least one realistic, copy/paste-ready usage example on the generated type page/overwrite section for that type UID. For example, a public `Class1` requires an example on the `Class1` API page, not only on the namespace page. Prefer deriving examples from existing unit, functional, or integration tests, but convert test code into real-life consumer-oriented usage.

        Missing type examples must be added through per-type DocFX overwrite files under `.docfx/api/types/{TypeUid}.md` in Codebelt repositories. Namespace overview text and `Extension Members` tables are not substitutes for type-page examples.

        Public extension methods must have examples too. Listing an extension method in an `Extension Members` table is required, but it is not enough.

        All added or changed code samples must be deterministic and verified to compile. Do not add pseudo-code, ellipses, hidden test helpers, or examples that rely on unverified behavior.

        Every namespace containing public API must have a DocFX namespace overview page named after the namespace, such as `X.Y.Z.md`, under `.docfx/api/namespaces/`, using DocFX overwrite front matter with the namespace `uid`.

        Namespaces exposing public extension methods must document those extension members at namespace level. The namespace page must include an `Extension Members` table listing the extended type, the extension marker, and the public extension methods. Extension members are rendered under the heading `Extension Members`.

        Both namespace overwrite files and type overwrite files are required deliverables in the same run. Generating only namespace pages or only type pages is incomplete.

        `docfx.json` must keep namespace and type overwrite files in separate subdirectories. `build.overwrite` must include both `api/namespaces/**/*.md` (for namespace pages) and `api/types/**/*.md` (for type pages). `build.content` must exclude both `api/namespaces/**` and `api/types/**` to prevent overwrite Markdown from being treated as conceptual content. Do not use `api/**/*.md` under `build.overwrite` or `build.content`.

        Availability must be documented by referencing the appropriate include file when one exists, or by adding explicit availability text when no suitable include exists. Availability must reflect the actual target frameworks, conditional compilation, and project configuration.

        Preserve manual documentation edits. Prefer additive changes, but correct stale or contradictory information so documentation remains accurate.

        Before completing documentation work, run the relevant verification commands, normally:

        ```bash
        dotnet build
        dotnet test
        dotnet run --file skills/dotnet-docfx-digest/scripts/docfx.cs -- --repo-root . --verify-docfx-build
        ```

        Codebelt repositories are normally strong-name signed with a `.snk` file in the repository root on the main author's codespace. Preserve and copy that root `.snk` file when building a temporary copy. If the repository or temp copy has no root `.snk`, run build and test verification with `-p:SkipSignAssembly=true`, for example `dotnet build -p:SkipSignAssembly=true` and `dotnet test -p:SkipSignAssembly=true`.

        The DocFX build verification must run outside the working tree when possible. The `--verify-docfx-build` option copies the repository to a temp workspace, runs DocFX against the resolved `docfx.json` there, and removes the temp workspace afterward so generated API YAML, manifest files, and site output do not flood git status.

        If a command cannot be run, report the exact limitation or failure instead of claiming the documentation was verified.
        <!-- dotnet-docfx-digest:end -->
        """;

    public static int Run(string[] args)
    {
        var options = new Options();
        try
        {
            if (!TryParse(args, options, out var parseError, out var wantHelp))
            {
                if (wantHelp)
                {
                    PrintUsage(Console.Out);
                    return 0;
                }

                return Fail(options.Json, ExitCode.InvalidArguments, "failed", parseError, options);
            }

            if (options.Help)
            {
                PrintUsage(Console.Out);
                return 0;
            }
        }
        catch (Exception ex)
        {
            Console.Error.WriteLine($"{ScriptId}: argument parsing failed: {ex.Message}");
            return (int)ExitCode.InvalidArguments;
        }

        string repoRoot;
        try
        {
            repoRoot = Path.GetFullPath(string.IsNullOrWhiteSpace(options.RepoRoot) ? "." : options.RepoRoot);
        }
        catch (Exception ex)
        {
            return Fail(options.Json, ExitCode.RepoRootMissing, "failed", $"Invalid repository root: {ex.Message}", options);
        }

        options.ResolvedRepoRoot = repoRoot;

        if (!Directory.Exists(repoRoot))
        {
            return Fail(options.Json, ExitCode.RepoRootMissing, "failed", $"Repository root does not exist: {repoRoot}", options);
        }

        var agentsPath = Path.Combine(repoRoot, AgentsFileName);
        options.AgentsPath = agentsPath;

        string? existing = null;
        if (File.Exists(agentsPath))
        {
            try
            {
                existing = File.ReadAllText(agentsPath);
            }
            catch (Exception ex)
            {
                return Fail(options.Json, ExitCode.WriteFailed, "failed", $"Unable to read {AgentsFileName}: {ex.Message}", options);
            }
        }

        var eol = DetectLineEnding(existing);
        var renderedBlock = RenderBlock(eol);

        // Locate markers and reject a corrupt (single-marker or out-of-order) block.
        int startIdx = existing?.IndexOf(StartMarker, StringComparison.Ordinal) ?? -1;
        int endIdx = existing?.IndexOf(EndMarker, StringComparison.Ordinal) ?? -1;

        bool hasStart = startIdx >= 0;
        bool hasEnd = endIdx >= 0;

        if (hasStart ^ hasEnd)
        {
            return Fail(options.Json, ExitCode.CorruptBlock, "failed",
                $"{AgentsFileName} contains a corrupt managed block: only one of the start/end markers was found.", options);
        }

        if (hasStart && hasEnd && startIdx > endIdx)
        {
            return Fail(options.Json, ExitCode.CorruptBlock, "failed",
                $"{AgentsFileName} contains a corrupt managed block: the end marker appears before the start marker.", options);
        }

        string newContent;
        bool fileMissing = existing is null;
        if (hasStart && hasEnd)
        {
            var prefix = existing!.Substring(0, startIdx);
            var suffix = existing.Substring(endIdx + EndMarker.Length);
            newContent = prefix + renderedBlock + suffix;
        }
        else if (fileMissing)
        {
            newContent = renderedBlock + eol;
        }
        else
        {
            var baseText = existing!;
            if (baseText.Length == 0)
            {
                newContent = renderedBlock + eol;
            }
            else
            {
                if (!baseText.EndsWith("\n", StringComparison.Ordinal))
                {
                    baseText += eol;
                }

                baseText += eol;
                newContent = baseText + renderedBlock + eol;
            }
        }

        bool changed = fileMissing || !string.Equals(existing, newContent, StringComparison.Ordinal);

        // CHECK: read-only CI enforcement.
        if (options.Mode == RunMode.Check)
        {
            if (!changed)
            {
                return Done(options, ExitCode.Success, "unchanged", false,
                    $"{AgentsFileName} already contains an up-to-date managed block.");
            }

            var status = fileMissing ? "would-create" : "would-update";
            var msg = fileMissing
                ? $"{AgentsFileName} is missing and would be created."
                : $"{AgentsFileName} managed block is stale and would be updated.";
            return Done(options, ExitCode.ValidationFailed, status, true, msg);
        }

        // DRY-RUN: report intended action without writing.
        if (options.Mode == RunMode.DryRun)
        {
            if (!changed)
            {
                return Done(options, ExitCode.Success, "unchanged", false,
                    $"{AgentsFileName} already contains an up-to-date managed block.");
            }

            var status = fileMissing ? "would-create" : "would-update";
            var msg = fileMissing
                ? $"{AgentsFileName} would be created with the managed block."
                : $"{AgentsFileName} managed block would be updated.";
            return Done(options, ExitCode.Success, status, true, msg);
        }

        // WRITE: persist changes.
        if (!changed)
        {
            return Done(options, ExitCode.Success, "unchanged", false,
                $"{AgentsFileName} already contains an up-to-date managed block.");
        }

        try
        {
            File.WriteAllText(agentsPath, newContent, Utf8NoBom);
        }
        catch (Exception ex)
        {
            return Fail(options.Json, ExitCode.WriteFailed, "failed", $"Failed to write {AgentsFileName}: {ex.Message}", options);
        }

        var writeStatus = fileMissing ? "created" : "updated";
        var writeMsg = fileMissing
            ? $"Created {AgentsFileName} with the managed DocFX documentation maintenance block."
            : $"Updated the managed DocFX documentation maintenance block in {AgentsFileName}.";
        return Done(options, ExitCode.Success, writeStatus, true, writeMsg);
    }

    private static string RenderBlock(string eol)
    {
        // ManagedBlock is normalized to LF; render with the host file's line ending.
        var normalized = ManagedBlock.Replace("\r\n", "\n").Replace("\r", "\n");
        return eol == "\n" ? normalized : normalized.Replace("\n", eol);
    }

    private static string DetectLineEnding(string? content)
    {
        if (!string.IsNullOrEmpty(content) && content.Contains("\r\n", StringComparison.Ordinal))
        {
            return "\r\n";
        }

        return "\n";
    }

    private static bool TryParse(string[] args, Options options, out string error, out bool wantHelp)
    {
        error = string.Empty;
        wantHelp = false;
        bool sawCheck = false, sawWrite = false, sawDryRun = false;

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
                    if (i + 1 >= args.Length)
                    {
                        error = "--repo-root requires a path argument.";
                        return false;
                    }

                    options.RepoRoot = args[++i];
                    break;
                case "--check":
                    sawCheck = true;
                    break;
                case "--write":
                    sawWrite = true;
                    break;
                case "--dry-run":
                    sawDryRun = true;
                    break;
                case "--json":
                    options.Json = true;
                    break;
                default:
                    if (arg.StartsWith("--repo-root=", StringComparison.Ordinal))
                    {
                        options.RepoRoot = arg["--repo-root=".Length..];
                        break;
                    }

                    error = $"Unknown argument: {arg}";
                    return false;
            }
        }

        // Precedence: --check wins over --dry-run wins over --write; default is write.
        if (sawCheck)
        {
            options.Mode = RunMode.Check;
        }
        else if (sawDryRun)
        {
            options.Mode = RunMode.DryRun;
        }
        else
        {
            options.Mode = RunMode.Write;
        }

        _ = sawWrite;
        return true;
    }

    private static int Fail(bool json, ExitCode code, string status, string message, Options options)
    {
        if (json)
        {
            EmitJson(options, status, message, changed: false);
        }
        else
        {
            Console.Error.WriteLine($"{ScriptId}: {message}");
        }

        return (int)code;
    }

    private static int Done(Options options, ExitCode code, string status, bool changed, string message)
    {
        if (options.Json)
        {
            EmitJson(options, status, message, changed);
        }
        else
        {
            Console.WriteLine($"{ScriptId}: {status}: {message}");
        }

        return (int)code;
    }

    private static void EmitJson(Options options, string status, string message, bool changed)
    {
        var payload = new JsonSummary
        {
            Script = ScriptId,
            RepoRoot = options.ResolvedRepoRoot ?? options.RepoRoot ?? string.Empty,
            AgentsPath = options.AgentsPath ?? string.Empty,
            Mode = options.Mode switch
            {
                RunMode.Check => "check",
                RunMode.DryRun => "dry-run",
                _ => "write"
            },
            Status = status,
            Changed = changed,
            Message = message
        };

        Console.WriteLine(JsonSerializer.Serialize(payload, JsonContext.Default.JsonSummary));
    }

    private static void PrintUsage(TextWriter writer)
    {
        writer.WriteLine(
            $"""
            {ScriptId} - ensure the repository AGENTS.md contains the dotnet-docfx-digest managed block.

            Usage:
              dotnet run --file agents.cs -- [options]

            Options:
              --repo-root <path>   Repository root. Default: current directory.
              --check              Do not write. Exit non-zero if AGENTS.md is missing or stale.
              --write              Write changes. Default mode when neither --check nor --dry-run is supplied.
              --dry-run            Show what would change without writing.
              --json               Emit a machine-readable JSON summary.
              --help               Print this usage.

            Exit codes:
              0  Success; file already compliant or successfully updated.
              1  Validation failed in --check mode.
              2  Invalid arguments.
              3  Repository root does not exist.
              4  AGENTS.md contains a corrupt managed block.
              5  Write failed.
            """);
    }

    private enum RunMode
    {
        Write,
        Check,
        DryRun
    }

    private enum ExitCode
    {
        Success = 0,
        ValidationFailed = 1,
        InvalidArguments = 2,
        RepoRootMissing = 3,
        CorruptBlock = 4,
        WriteFailed = 5
    }

    private sealed class Options
    {
        public string? RepoRoot { get; set; }
        public string? ResolvedRepoRoot { get; set; }
        public string? AgentsPath { get; set; }
        public bool Json { get; set; }
        public bool Help { get; set; }
        public RunMode Mode { get; set; } = RunMode.Write;
    }
}

internal sealed class JsonSummary
{
    [JsonPropertyName("script")] public string Script { get; set; } = string.Empty;
    [JsonPropertyName("repoRoot")] public string RepoRoot { get; set; } = string.Empty;
    [JsonPropertyName("agentsPath")] public string AgentsPath { get; set; } = string.Empty;
    [JsonPropertyName("mode")] public string Mode { get; set; } = string.Empty;
    [JsonPropertyName("status")] public string Status { get; set; } = string.Empty;
    [JsonPropertyName("changed")] public bool Changed { get; set; }
    [JsonPropertyName("message")] public string Message { get; set; } = string.Empty;
}

[JsonSerializable(typeof(JsonSummary))]
[JsonSourceGenerationOptions(WriteIndented = true)]
internal partial class JsonContext : JsonSerializerContext
{
}
