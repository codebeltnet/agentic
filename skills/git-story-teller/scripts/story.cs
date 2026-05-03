#:property TargetFramework=net10.0
#:property Nullable=enable
#:property LangVersion=latest
#:property PublishAot=false

using System.Diagnostics;
using System.Net.Http;
using System.Text;
using System.Text.Json;
using System.Text.RegularExpressions;
using System.Xml.Linq;

return await StoryScript.RunAsync(args);

internal static class StoryScript
{
    private const string ResultDirectoryName = "result";

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

            Console.WriteLine($"[story] repo-url={options.RepoUrl}");
            Console.WriteLine($"[story] output-root={options.OutputRoot}");
            Console.WriteLine($"[story] repo-id={repoId}");
            Console.WriteLine();

            var tempRoot = Path.Combine(Path.GetTempPath(), "git-story-teller-" + Guid.NewGuid().ToString("N"));
            Directory.CreateDirectory(tempRoot);

            try
            {
                var cloneDir = Path.Combine(tempRoot, "repo");
                await CloneRepositoryAsync(options.RepoUrl, cloneDir);

                var targets = DiscoverTargets(cloneDir);
                Console.WriteLine($"[story] discovered {targets.Count} target(s)");

                var targetEntries = new List<TargetManifestEntry>();
                foreach (var target in targets)
                {
                    var contextFileName = target.Name + ".context.md";
                    var resultPath = Path.Combine(ResultDirectoryName, target.Name + ".md").Replace('\\', '/');
                    var context = await BuildTargetContextAsync(options.RepoUrl, cloneDir, target);
                    await WriteUtf8Async(Path.Combine(workspace, contextFileName), context);

                    targetEntries.Add(new TargetManifestEntry(
                        "package",
                        target.Name,
                        contextFileName,
                        resultPath));
                }

                var overviewContextName = "overview.context.md";
                var overviewContext = await BuildOverviewContextAsync(options.RepoUrl, cloneDir, repoId, targets);
                await WriteUtf8Async(Path.Combine(workspace, overviewContextName), overviewContext);

                await WriteUtf8Async(Path.Combine(workspace, "instructions.md"), BuildInstructions(options.RepoUrl, repoId));
                await WriteManifestAsync(
                    Path.Combine(workspace, "manifest.json"),
                    options,
                    repoId,
                    workspace,
                    targetEntries,
                    overviewContextName);

                Console.WriteLine();
                Console.WriteLine("[story] deterministic workspace written:");
                Console.WriteLine("  " + workspace);
                Console.WriteLine("[story] result files are agent-authored and were not overwritten.");
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

    private static StoryOptions ParseOptions(string[] args)
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
        return new StoryOptions(repoUrl.Trim(), Path.GetFullPath(outputRoot.Trim()));
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
        Console.WriteLine("[story] cloning repository for discovery...");
        await RunProcessAsync("git", ["clone", "--depth", "1", repoUrl, cloneDir], Directory.GetCurrentDirectory());
    }

    private static IReadOnlyList<TargetInfo> DiscoverTargets(string cloneDir)
    {
        var srcDir = Path.Combine(cloneDir, "src");
        if (!Directory.Exists(srcDir))
        {
            return [];
        }

        var projectFiles = Directory.EnumerateFiles(srcDir, "*.csproj", SearchOption.AllDirectories)
            .OrderBy(p => Path.GetRelativePath(cloneDir, p), StringComparer.OrdinalIgnoreCase)
            .ToList();

        var targets = new List<TargetInfo>();
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

            targets.Add(new TargetInfo(
                name,
                Path.GetRelativePath(cloneDir, sourceDir).Replace('\\', '/'),
                testDir is null ? null : Path.GetRelativePath(cloneDir, testDir).Replace('\\', '/'),
                sourceFiles.Count == 0,
                metadata.BundledPackages));
        }

        return targets;
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

    private static string? FindTestDirectory(string cloneDir, string sourceProjectFile, string targetName)
    {
        var testRoots = new[] { "test", "tests" }
            .Select(r => Path.Combine(cloneDir, r))
            .Where(Directory.Exists)
            .ToList();

        foreach (var root in testRoots)
        {
            var testProjects = Directory.EnumerateFiles(root, "*.csproj", SearchOption.AllDirectories)
                .OrderBy(p => p, StringComparer.OrdinalIgnoreCase)
                .ToList();

            foreach (var testProject in testProjects)
            {
                if (ReferencesProject(testProject, sourceProjectFile))
                {
                    return Path.GetDirectoryName(testProject);
                }
            }

            var normalizedTarget = NormalizeForMatch(targetName);
            var byName = testProjects.FirstOrDefault(p => NormalizeForMatch(Path.GetFileNameWithoutExtension(p)).Contains(normalizedTarget, StringComparison.OrdinalIgnoreCase));
            if (byName is not null)
            {
                return Path.GetDirectoryName(byName);
            }
        }

        return null;
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

    private static async Task<string> BuildTargetContextAsync(string repoUrl, string cloneDir, TargetInfo target)
    {
        Console.WriteLine($"[story] packing context for {target.Name}...");

        var includeParts = new List<string>
        {
            "README.md",
            "Directory.Build.props",
            "Directory.Build.targets",
            "Directory.Packages.props",
            target.SourcePath + "/**"
        };

        if (!string.IsNullOrWhiteSpace(target.TestPath))
        {
            includeParts.Add(target.TestPath + "/**");
        }

        includeParts.Add(".nuget/**/README.md");
        var repomix = await PackRepositoryContentAsync(repoUrl, cloneDir, string.Join(',', includeParts));

        var sb = new StringBuilder();
        AppendHeader(sb, "TARGET IDENTITY");
        sb.AppendLine($"Repository: {repoUrl}");
        sb.AppendLine($"Target: {target.Name}");
        sb.AppendLine("Kind: package");
        sb.AppendLine($"Source path: {target.SourcePath}");
        sb.AppendLine($"Test path: {target.TestPath ?? "(not discovered)"}");
        sb.AppendLine($"Metadata-only target: {target.IsConveniencePackage}");
        sb.AppendLine($"Result path: result/{target.Name}.md");
        sb.AppendLine();

        if (target.BundledPackages.Count > 0)
        {
            AppendHeader(sb, "DECLARED REFERENCES");
            foreach (var package in target.BundledPackages)
            {
                sb.AppendLine("- " + package);
            }
            sb.AppendLine();
        }

        AppendHeader(sb, "PACKAGE STORY PROMPT");
        AppendMultiline(sb, BuildPackageStoryPrompt(target.Name));

        AppendHeader(sb, "PACKED REPOSITORY CONTENT");
        sb.AppendLine(repomix.Trim());
        sb.AppendLine();

        return sb.ToString();
    }

    private static async Task<string> BuildOverviewContextAsync(string repoUrl, string cloneDir, string repoId, IReadOnlyList<TargetInfo> targets)
    {
        Console.WriteLine("[story] packing overview context...");
        var repomix = await PackRepositoryContentAsync(repoUrl, cloneDir, "README.md,.nuget/**/README.md,Directory.Build.props,Directory.Build.targets,Directory.Packages.props,src/**/*.csproj");

        var sb = new StringBuilder();
        AppendHeader(sb, "REPOSITORY IDENTITY");
        sb.AppendLine($"Repository: {repoUrl}");
        sb.AppendLine($"Repository id: {repoId}");
        sb.AppendLine($"Targets: {targets.Count}");
        sb.AppendLine("Result path: result/Index.md");
        sb.AppendLine();

        AppendHeader(sb, "TARGET STORIES TO READ FIRST");
        if (targets.Count == 0)
        {
            sb.AppendLine("No package targets were discovered under src/. Write an overview only if the repository context is sufficient.");
        }
        else
        {
            foreach (var target in targets)
            {
                sb.AppendLine($"- {target.Name}: result/{target.Name}.md");
            }
        }
        sb.AppendLine();

        AppendHeader(sb, "OVERVIEW STORY PROMPT");
        AppendMultiline(sb, BuildOverviewStoryPrompt(repoId, targets));

        AppendHeader(sb, "SUPPLEMENTARY REPOSITORY CONTENT");
        sb.AppendLine(repomix.Trim());
        sb.AppendLine();

        return sb.ToString();
    }

    private static string BuildInstructions(string repoUrl, string repoId) =>
        $$"""
        # Story Writing Instructions

        Repository: {{repoUrl}}
        Repository id: {{repoId}}

        The deterministic runner generated this workspace. The agent writes Markdown stories; this script does not call an LLM and does not overwrite result files.

        ## Contract

        - Treat `manifest.json` as authoritative for context and result paths.
        - Process target contexts one at a time.
        - Write every target result before writing the overview.
        - Write target stories to `result/{TargetName}.md`.
        - Write the overview to `result/Index.md`.
        - Use the generated prompt sections in each `.context.md` file as the task contract.
        - Do not invent APIs, package relationships, examples, dependencies, support statements, performance claims, or architectural claims.
        - If context is missing, stale, contradictory, or too large to use safely, stop and report the blocker.

        ## Shared Editorial Rules

        {{BuildSharedEditorialRules()}}

        ## Suggested Order

        1. Read `manifest.json`.
        2. Read this file.
        3. For each target in the `packages` phase, read its context and write its result file.
        4. Read `overview.context.md` and the completed target result files.
        5. Write `result/Index.md`.
        6. Validate that all manifest result paths exist.
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

        Use source files to understand what the target exposes and owns.
        Use test files to understand how consumers are expected to use the target.
        Use project files to understand dependencies and package relationships.
        Use README and metadata files as editorial context, but prefer source and tests when there is a conflict.

        You must not invent APIs, features, target relationships, dependencies, examples, use cases, or architectural claims not supported by the supplied context.

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
        - Do not include analysis notes, confidence scores, citations, XML, JSON, or chat commentary unless the target prompt explicitly requests them.
        """;

    private static string BuildPackageStoryPrompt(string targetName) =>
        $$"""
        Write the documentation page for {{targetName}}.

        Output file:
        `result/{{targetName}}.md`

        Audience:
        Experienced .NET developers who are evaluating whether this NuGet package belongs in their project.
        Assume they understand .NET, NuGet, dependency injection, testing, hosting, ASP.NET Core, and common framework terminology.
        Do not explain basic .NET concepts.

        Grounding rules:
        Use only the supplied target context.
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

        Before writing the final page, internally identify:
        - the package's specific responsibility inside the repository
        - the primary developer scenario
        - the 3-5 public types that matter most to consumers
        - the most representative usage pattern found in tests
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
        dotnet add package {{targetName}}
        ```

        ## Usage guidance

        One honest paragraph.
        Explain when plain framework APIs, a lower-level package, a sibling package, or no package at all would be a better choice.
        Do not insult the package.
        Do not oversell it.
        """;

    private static string BuildOverviewStoryPrompt(string repoId, IReadOnlyList<TargetInfo> targets)
    {
        var targetList = targets.Count == 0
            ? "- No package targets discovered."
            : string.Join(Environment.NewLine, targets.Select(t => "- " + t.Name));

        return $$"""
        Write the overview page for this repository.

        Output file:
        `result/Index.md`

        Primary editorial context:
        Read the completed target stories before writing this page:
        {{targetList}}

        Audience:
        Experienced .NET developers who need a mental model before choosing an individual package or target from this repository.
        Assume they understand .NET, NuGet, dependency injection, testing, hosting, ASP.NET Core, and common framework terminology.
        Do not explain basic .NET concepts.

        Grounding rules:
        The completed target stories are the primary editorial context.
        Supplementary README, package README, project, dependency, and metadata information may be used to clarify relationships.
        Do not invent package purposes, dependencies, recommended installation paths, scenarios, APIs, or architectural claims.
        Do not amplify unsupported claims from a target story.
        Prefer concrete responsibilities and decision guidance over marketing language.
        Keep the overview focused on how developers should understand and choose between the targets.

        Before writing the final page, internally identify:
        - the unifying purpose of the repository
        - the foundation package or primary target, if one exists
        - optional add-on packages, if any exist
        - convenience or meta packages, if any exist
        - the recommended starting point
        - scenarios where installing or using less is better
        - the one non-obvious insight developers should understand

        Write exactly these three sections.

        ## Overview

        Start with 2-3 sentences that explain the unifying purpose across the packages.
        Make clear what kind of developer problem this repository solves.
        Do not use broad marketing language.

        After the opening sentences, include a compact packages selection table.

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

        ## Target selection

        Start with one short introductory paragraph before the target subheadings.
        The paragraph must be specific to this repository.
        It should explain the selection principle, conceptual layering, or main trade-off across the targets.
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

    private static async Task<string> PackRepositoryContentAsync(string repoUrl, string cloneDir, string includes)
    {
        try
        {
            return await PackWithRepomixAsync(cloneDir, includes);
        }
        catch (Exception ex) when (CanUseDotNetPackerFallback(ex))
        {
            Console.WriteLine("[story] local repomix unavailable: " + ex.Message.Split(Environment.NewLine)[0]);

            if (CanUseRepomixWebApi(repoUrl))
            {
                try
                {
                    Console.WriteLine("[story] trying Repomix web API fallback.");
                    return await PackWithRepomixWebApiAsync(repoUrl, includes);
                }
                catch (Exception webEx)
                {
                    Console.WriteLine("[story] Repomix web API fallback unavailable: " + webEx.Message.Split(Environment.NewLine)[0]);
                }
            }

            Console.WriteLine("[story] using built-in .NET context packer fallback.");
            return await PackWithDotNetPackerAsync(cloneDir, includes);
        }
    }

    private static async Task<string> PackWithRepomixAsync(string cloneDir, string includes)
    {
        var outputFile = Path.Combine(Path.GetTempPath(), "repomix-story-" + Guid.NewGuid().ToString("N") + ".xml");
        try
        {
            var executable = ResolveNpxExecutable();
            await RunProcessAsync(executable,
                ["--yes", "repomix", "--include", includes, "--style", "xml", "--output", outputFile, "--no-file-summary", "--quiet"],
                cloneDir);

            if (!File.Exists(outputFile))
            {
                throw new InvalidOperationException("repomix completed without creating the expected output file.");
            }

            return await File.ReadAllTextAsync(outputFile, Encoding.UTF8);
        }
        finally
        {
            TryDeleteFile(outputFile);
        }
    }

    private static bool CanUseDotNetPackerFallback(Exception ex)
    {
        var message = ex.ToString();
        var fallbackSignals = new[]
        {
            "Could not start",
            "error occurred trying to start process",
            "The system cannot find the file specified",
            "No such file or directory",
            "could not determine executable to run",
            "ENOTFOUND",
            "EAI_AGAIN",
            "ETIMEDOUT",
            "ECONNRESET",
            "ECONNREFUSED",
            "registry.npmjs.org",
            "npm ERR! code"
        };

        return fallbackSignals.Any(signal => message.Contains(signal, StringComparison.OrdinalIgnoreCase));
    }

    private static bool CanUseRepomixWebApi(string repoUrl)
    {
        return Uri.TryCreate(repoUrl, UriKind.Absolute, out var uri)
            && uri.Scheme is "http" or "https"
            && string.Equals(uri.Host, "github.com", StringComparison.OrdinalIgnoreCase);
    }

    private static async Task<string> PackWithRepomixWebApiAsync(string repoUrl, string includes)
    {
        using var http = new HttpClient();
        using var content = new MultipartFormDataContent
        {
            { new StringContent(repoUrl, Encoding.UTF8), "url" },
            { new StringContent("xml", Encoding.UTF8), "format" },
            { new StringContent(BuildRepomixWebOptions(includes), Encoding.UTF8), "options" }
        };

        using var response = await http.PostAsync("https://api.repomix.com/api/pack", content);
        var body = await response.Content.ReadAsStringAsync();
        if (!response.IsSuccessStatusCode)
        {
            throw new InvalidOperationException($"Repomix web API returned HTTP {(int)response.StatusCode}.");
        }

        foreach (var line in body.Split('\n', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries))
        {
            using var json = JsonDocument.Parse(line);
            var root = json.RootElement;
            if (root.TryGetProperty("type", out var type) && string.Equals(type.GetString(), "result", StringComparison.OrdinalIgnoreCase))
            {
                return root.GetProperty("data").GetProperty("content").GetString()
                    ?? throw new InvalidOperationException("Repomix web API returned an empty result.");
            }

            if (root.TryGetProperty("type", out var errorType) && string.Equals(errorType.GetString(), "error", StringComparison.OrdinalIgnoreCase))
            {
                var message = root.TryGetProperty("message", out var messageElement)
                    ? messageElement.GetString()
                    : "Repomix web API returned an error.";
                throw new InvalidOperationException(message);
            }
        }

        throw new InvalidOperationException("Repomix web API did not return a result event.");
    }

    private static string BuildRepomixWebOptions(string includes)
    {
        var options = new
        {
            removeComments = false,
            removeEmptyLines = false,
            showLineNumbers = false,
            fileSummary = false,
            directoryStructure = true,
            includePatterns = includes,
            outputParsable = false,
            compress = false
        };

        return JsonSerializer.Serialize(options);
    }

    private static async Task<string> PackWithDotNetPackerAsync(string cloneDir, string includes)
    {
        var includePatterns = includes
            .Split(',', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries)
            .ToList();

        var files = Directory.EnumerateFiles(cloneDir, "*", SearchOption.AllDirectories)
            .Select(path => new PackedFile(path, Path.GetRelativePath(cloneDir, path).Replace('\\', '/')))
            .Where(file => ShouldIncludeFile(file.RelativePath, includePatterns))
            .Where(file => !IsUnderSkippedDirectory(file.RelativePath))
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
                new XAttribute("generatedBy", "git-story-teller-dotnet-fallback"),
                new XElement("note", "Repomix was unavailable, so this fallback packed selected text files with a simple .NET reader. It does not provide Repomix token counts, Secretlint checks, or exact gitignore semantics."),
                new XElement("includePatterns", includePatterns.Select(pattern => new XElement("pattern", pattern))),
                new XElement("directoryStructure", BuildDirectoryStructure(files.Select(file => file.RelativePath))),
                filesElement));

        return doc.ToString(SaveOptions.DisableFormatting);
    }

    private static bool ShouldIncludeFile(string relativePath, IReadOnlyList<string> includePatterns) =>
        includePatterns.Any(pattern => MatchesIncludePattern(relativePath, pattern));

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
            return relativePath.StartsWith(parts[0].TrimEnd('/') + "/", StringComparison.OrdinalIgnoreCase)
                && relativePath.EndsWith("/" + parts[1].TrimStart('/'), StringComparison.OrdinalIgnoreCase);
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

    private static string ResolveNpxExecutable()
    {
        if (!OperatingSystem.IsWindows())
        {
            return "npx";
        }

        var programFiles = Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles);
        if (!string.IsNullOrWhiteSpace(programFiles))
        {
            var nodeNpx = Path.Combine(programFiles, "nodejs", "npx.cmd");
            if (File.Exists(nodeNpx))
            {
                return nodeNpx;
            }
        }

        var programFilesX86 = Environment.GetFolderPath(Environment.SpecialFolder.ProgramFilesX86);
        if (!string.IsNullOrWhiteSpace(programFilesX86))
        {
            var nodeNpx = Path.Combine(programFilesX86, "nodejs", "npx.cmd");
            if (File.Exists(nodeNpx))
            {
                return nodeNpx;
            }
        }

        return "npx.cmd";
    }

    private static async Task WriteManifestAsync(
        string manifestPath,
        StoryOptions options,
        string repoId,
        string workspace,
        IReadOnlyList<TargetManifestEntry> targets,
        string overviewContextName)
    {
        var packagesPhase = new
        {
            name = "packages",
            targets = targets.Select(t => new { t.kind, t.name, t.context, t.result }).ToList()
        };

        var overviewPhase = new
        {
            name = "overview",
            dependsOn = "packages",
            target = new
            {
                kind = "overview",
                name = "Index",
                context = overviewContextName,
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
            targets,
            overview = overviewPhase.target
        };

        var json = JsonSerializer.Serialize(manifest, new JsonSerializerOptions { WriteIndented = true });
        await WriteUtf8Async(manifestPath, json + Environment.NewLine);
    }

    private static async Task RunProcessAsync(string executable, IReadOnlyList<string> arguments, string workingDirectory)
    {
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

        await process.WaitForExitAsync();
        var stdout = await stdoutTask;
        var stderr = await stderrTask;

        if (process.ExitCode != 0)
        {
            var details = string.Join(Environment.NewLine, new[] { stdout.Trim(), stderr.Trim() }.Where(s => !string.IsNullOrWhiteSpace(s)));
            throw new InvalidOperationException($"'{executable}' failed with exit code {process.ExitCode}.{Environment.NewLine}{details}".Trim());
        }
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

    private static void TryDeleteFile(string path)
    {
        try
        {
            if (File.Exists(path))
            {
                File.Delete(path);
            }
        }
        catch
        {
            // Temp cleanup failure should not hide the real result.
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
            // Temp cleanup failure should not hide the real result.
        }
    }

    private static void PrintUsage()
    {
        Console.WriteLine(
            """
            git-story-teller deterministic context generator

            Usage:
              dotnet run --file scripts/story.cs -- --repo-url <url> --output-root <path>

            Required:
              --repo-url      Fully qualified git repository URL, for example https://github.com/owner/repo
              --output-root   Directory where the {repo-id} story workspace will be written

            Fixed conventions:
              repo-id      Derived from the final repository URL path segment
              result dir   result

            Output:
              {output-root}/{repo-id}/manifest.json
              {output-root}/{repo-id}/instructions.md
              {output-root}/{repo-id}/*.context.md
              {output-root}/{repo-id}/result/

            Notes:
              - This script writes deterministic context only.
              - This script does not call an LLM.
              - Existing result/*.md files are not overwritten.
              - Context packing prefers local Repomix, then the Repomix web API for GitHub HTTPS URLs, then the built-in .NET fallback.
            """);
    }
}

internal sealed record StoryOptions(string RepoUrl, string OutputRoot);

internal sealed record ProjectMetadata(
    string PackageId,
    string AssemblyName,
    bool? IsPackable,
    IReadOnlyList<string> BundledPackages);

internal sealed record TargetInfo(
    string Name,
    string SourcePath,
    string? TestPath,
    bool IsConveniencePackage,
    IReadOnlyList<string> BundledPackages);

internal sealed record TargetManifestEntry(
    string kind,
    string name,
    string context,
    string result);

internal sealed record PackedFile(string FullPath, string RelativePath);
