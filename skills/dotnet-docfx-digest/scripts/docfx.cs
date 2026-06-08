#:property TargetFramework=net10.0
#:property Nullable=enable
#:property LangVersion=latest
#:property PublishAot=false
#:package System.Reflection.MetadataLoadContext@9.0.0

using System.Diagnostics;
using System.Reflection;
using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;
using System.Text.RegularExpressions;
using System.Xml.Linq;

return DocfxValidator.Run(args);

internal static class DocfxValidator
{
    private const string ScriptId = "validate-docfx-digest";
    private const string StartMarker = "<!-- dotnet-docfx-digest:start -->";
    private const string EndMarker = "<!-- dotnet-docfx-digest:end -->";
    private const string ExtensionAttributeFullName = "System.Runtime.CompilerServices.ExtensionAttribute";
    private const string SkipMarker = "dotnet-docfx-digest:skip-compile";

    private static readonly string[] IgnoredDirectorySegments = ["bin", "obj", "_site", ".git", "node_modules"];
    private static readonly TimeSpan ProcessTimeout = TimeSpan.FromMinutes(10);

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

        // 3. Verify AGENTS.md contains the managed block.
        var agentsPath = Path.Combine(repoRoot, "AGENTS.md");
        if (!AgentsBlockPresent(agentsPath))
        {
            report.Errors.Add(new Diagnostic("AGENTS_BLOCK_MISSING", agentsPath, null,
                "AGENTS.md does not contain the dotnet-docfx-digest managed block. Run scripts/agents.cs first."));
        }

        // Optional changed-only scoping.
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

        // 4. Build the repository before metadata inspection.
        var (buildOk, buildOutput) = BuildRepository(repoRoot, options.Configuration);
        if (!buildOk)
        {
            report.Errors.Add(new Diagnostic("BUILD_FAILED", null, null,
                $"dotnet build failed (configuration {options.Configuration}).\n{Trim(buildOutput)}"));
            return Emit(options, report, ExitCode.BuildFailed, "Build failed.");
        }

        // 5-7. Discover public API, namespaces and extension methods from compiled metadata.
        var projects = DiscoverProjects(repoRoot);
        var libraryProjects = projects.Where(p => !p.IsTest).ToList();
        ApiModel api;
        try
        {
            api = DiscoverApi(libraryProjects, options.Configuration, options.Framework, report);
        }
        catch (Exception ex)
        {
            report.Errors.Add(new Diagnostic("PUBLIC_API_DISCOVERY_FAILED", null, null,
                $"Public API discovery failed: {ex.Message}"));
            return Emit(options, report, ExitCode.PublicApiDiscoveryFailed, "Public API discovery failed.");
        }

        if (api.Namespaces.Count == 0)
        {
            report.Errors.Add(new Diagnostic("PUBLIC_API_DISCOVERY_FAILED", null, null,
                "No public API could be discovered from the compiled library assemblies. Ensure the repository builds and exposes public types."));
            return Emit(options, report, ExitCode.PublicApiDiscoveryFailed, "Public API discovery failed.");
        }

        report.Summary.PublicNamespaces = api.Namespaces.Count;
        report.Summary.ConcreteApiTargets = api.ConcreteTargets.Count;
        report.Summary.ExtensionMethods = api.Namespaces.Sum(n => n.ExtensionMethods.Count);

        // 8. Discover DocFX Markdown files under the workspace.
        var markdownFiles = DiscoverMarkdown(docfxWorkspace);

        // 9-11. Validate namespace overview pages, extension tables and availability.
        foreach (var ns in api.Namespaces.OrderBy(n => n.Name, StringComparer.Ordinal))
        {
            var page = markdownFiles.FirstOrDefault(f =>
                string.Equals(Path.GetFileNameWithoutExtension(f), ns.Name, StringComparison.Ordinal));

            if (page is null)
            {
                report.Errors.Add(new Diagnostic("NAMESPACE_PAGE_MISSING", null, ns.Name,
                    $"Missing namespace overview page for namespace {ns.Name}. Expected a file named {ns.Name}.md under {Rel(repoRoot, docfxWorkspace)}."));
                continue;
            }

            if (options.ChangedOnly && changedFiles is not null && !changedFiles.Contains(Path.GetFullPath(page)))
            {
                continue;
            }

            ValidateNamespacePage(repoRoot, page, ns, report);
            report.Summary.NamespacePagesValidated++;
        }

        // 12. Verify mandatory examples exist before compiling the examples that were found.
        ValidateRequiredExamples(repoRoot, markdownFiles, api, options, changedFiles, report);

        // 13. Extract and compile C# documentation samples.
        if (options.ValidateSamples)
        {
            ValidateSamples(repoRoot, markdownFiles, libraryProjects, options, changedFiles, report);
        }

        // 14-15. Produce report and return a deterministic exit code.
        bool hasSampleError = report.Errors.Any(e => e.Code is "SAMPLE_COMPILE_FAILED");
        bool hasOtherError = report.Errors.Any(e => e.Code is not "SAMPLE_COMPILE_FAILED");

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

        // Fall back to the first docfx.json found anywhere under the repo (excluding build output).
        foreach (var file in EnumerateFiles(repoRoot, "docfx.json"))
        {
            return file;
        }

        return null;
    }

    private static List<string> DiscoverMarkdown(string docfxWorkspace)
    {
        var list = new List<string>();
        foreach (var file in EnumerateFiles(docfxWorkspace, "*.md"))
        {
            list.Add(Path.GetFullPath(file));
        }

        return list;
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
    // Build
    // ----------------------------------------------------------------------

    private static (bool Ok, string Output) BuildRepository(string repoRoot, string configuration)
    {
        // Build a solution if one is present, otherwise let dotnet resolve the project in the repo root.
        var target = Directory.GetFiles(repoRoot, "*.slnx").Concat(Directory.GetFiles(repoRoot, "*.sln")).FirstOrDefault();
        var args = target is null
            ? $"build -c {configuration} --nologo"
            : $"build \"{target}\" -c {configuration} --nologo";
        var result = RunProcess("dotnet", args, repoRoot);
        return (result.ExitCode == 0, result.StdOut + result.StdErr);
    }

    // ----------------------------------------------------------------------
    // Project + API discovery
    // ----------------------------------------------------------------------

    private static List<ProjectInfo> DiscoverProjects(string repoRoot)
    {
        var projects = new List<ProjectInfo>();
        foreach (var proj in EnumerateFiles(repoRoot, "*.csproj"))
        {
            var info = ReadProject(proj);
            projects.Add(info);
        }

        return projects;
    }

    private static ProjectInfo ReadProject(string projectPath)
    {
        string? assemblyName = null;
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

        return new ProjectInfo(projectPath, assemblyName, tfms, isTest);
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

        foreach (var dll in assemblyPaths)
        {
            var dir = Path.GetDirectoryName(dll)!;
            foreach (var sibling in Directory.GetFiles(dir, "*.dll"))
            {
                resolverPaths.Add(sibling);
            }
        }

        var resolver = new PathAssemblyResolver(resolverPaths);
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

                CollectApiTargets(type, info);
                CollectExtensionMethods(type, info);
            }
        }

        var concreteTargets = namespaces.Values
            .SelectMany(ns => ns.ConcreteTargets)
            .OrderBy(t => t.Uid, StringComparer.Ordinal)
            .ToList();

        return new ApiModel(namespaces.Values.ToList(), concreteTargets);
    }

    private static void CollectApiTargets(Type type, NamespaceInfo ns)
    {
        var typeUid = TypeUid(type);
        if (typeUid is null)
        {
            return;
        }

        if (IsConcreteDocumentableType(type))
        {
            ns.ConcreteTargets.Add(new ApiTargetInfo(typeUid, ns.Name, ApiTargetKind.Type, SimpleTypeName(type)));
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

            ns.ConcreteTargets.Add(new ApiTargetInfo(MethodUid(typeUid, method), ns.Name, ApiTargetKind.ExtensionMethod, method.Name, typeUid));
        }
    }

    private static void CollectExtensionMethods(Type type, NamespaceInfo ns)
    {
        // A public extension method lives on a public static (abstract+sealed) non-generic class.
        if (!type.IsClass || !type.IsAbstract || !type.IsSealed || type.IsGenericType || !type.IsPublic)
        {
            return;
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

            var extendedType = SimpleTypeName(parameters[0].ParameterType);
            ns.ExtensionMethods.Add(new ExtensionMethodInfo(method.Name, extendedType, type.Name));
        }
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

    private static bool IsConcreteDocumentableType(Type type)
    {
        if (type.IsInterface || type.IsAbstract || type.IsEnum || type.IsValueType)
        {
            return false;
        }

        if (InheritsFrom(type, "System.Attribute") || InheritsFrom(type, "System.MulticastDelegate"))
        {
            return false;
        }

        return true;
    }

    private static bool InheritsFrom(Type type, string baseTypeFullName)
    {
        try
        {
            var current = type.BaseType;
            while (current is not null)
            {
                if (string.Equals(current.FullName, baseTypeFullName, StringComparison.Ordinal))
                {
                    return true;
                }

                current = current.BaseType;
            }
        }
        catch
        {
            // ignore
        }

        return false;
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

        return typeUid + "." + method.Name + "(" + string.Join(",", parameters) + ")";
    }

    private static string SimpleTypeName(Type type)
    {
        var name = type.Name;
        var tick = name.IndexOf('`');
        return tick >= 0 ? name[..tick] : name;
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

    private static void ValidateNamespacePage(string repoRoot, string page, NamespaceInfo ns, Report report)
    {
        var rel = Rel(repoRoot, page);
        string text;
        try
        {
            text = File.ReadAllText(page);
        }
        catch (Exception ex)
        {
            report.Errors.Add(new Diagnostic("NAMESPACE_PAGE_MISSING", rel, ns.Name, $"Unable to read namespace page: {ex.Message}"));
            return;
        }

        var (frontMatter, body) = SplitFrontMatter(text);

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

        // fly-in paragraph
        if (!HasFlyIn(body))
        {
            report.Errors.Add(new Diagnostic("NAMESPACE_FLYIN_MISSING", rel, ns.Name,
                "Namespace page has no human-written fly-in paragraph, or contains only placeholder text."));
        }

        // availability
        if (!HasAvailability(body))
        {
            report.Errors.Add(new Diagnostic("AVAILABILITY_MISSING", rel, ns.Name,
                "Namespace page has no availability information (expected an availability include or explicit 'Availability:' text)."));
        }

        // extension members
        if (ns.ExtensionMethods.Count > 0)
        {
            ValidateExtensionSection(rel, body, ns, report);
        }
    }

    private static void ValidateExtensionSection(string rel, string body, NamespaceInfo ns, Report report)
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

        // Every discovered extension method name must appear (backticked) in the section.
        foreach (var group in ns.ExtensionMethods.GroupBy(m => m.MethodName, StringComparer.Ordinal))
        {
            var methodName = group.Key;
            var pattern = "`" + Regex.Escape(methodName);
            if (!Regex.IsMatch(section, pattern + @"[`(]"))
            {
                report.Errors.Add(new Diagnostic("EXTENSION_METHOD_MISSING", rel, ns.Name,
                    $"Extension method `{methodName}` (extending {group.First().ExtendedType}) is not listed in the 'Extension Members' table for namespace {ns.Name}."));
            }
        }
    }

    private static bool HasFlyIn(string body)
    {
        foreach (var raw in body.Split('\n'))
        {
            var line = raw.Trim();
            if (line.Length == 0)
            {
                continue;
            }

            if (line.StartsWith('#') || line.StartsWith('|') || line.StartsWith("[!INCLUDE", StringComparison.OrdinalIgnoreCase) ||
                line.StartsWith("```", StringComparison.Ordinal) || line.StartsWith("---", StringComparison.Ordinal))
            {
                continue;
            }

            // Reject template placeholders like "contains types that ..." or bare ellipses / TODO.
            if (line.Contains("...", StringComparison.Ordinal) || line.Contains("TODO", StringComparison.OrdinalIgnoreCase) ||
                line.EndsWith("contains types that", StringComparison.OrdinalIgnoreCase))
            {
                continue;
            }

            if (line.Length >= 20)
            {
                return true;
            }
        }

        return false;
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
    // Required example validation
    // ----------------------------------------------------------------------

    private static void ValidateRequiredExamples(string repoRoot, List<string> markdownFiles, ApiModel api,
        Options options, HashSet<string>? changedFiles, Report report)
    {
        if (options.ChangedOnly && changedFiles is not null)
        {
            return;
        }

        var sections = new List<OverwriteSection>();
        foreach (var md in markdownFiles)
        {
            sections.AddRange(ExtractOverwriteSections(md));
        }

        foreach (var target in api.ConcreteTargets)
        {
            var candidates = sections.Where(s => IsExampleCandidate(s, target)).ToList();
            if (candidates.Any(s => HasExampleForTarget(s, target)))
            {
                report.Summary.RequiredExamples++;
                continue;
            }

            var expectedUid = target.Kind == ApiTargetKind.Type
                ? target.Uid
                : target.DeclaringTypeUid ?? target.Uid;

            var message = target.Kind == ApiTargetKind.Type
                ? $"Concrete public type `{target.DisplayName}` requires a DocFX overwrite section with uid `{target.Uid}` and an Examples section containing a C# code fence."
                : $"Public extension method `{target.DisplayName}` requires a DocFX overwrite example. Add an Examples section with a C# code fence to uid `{target.Uid}`, its declaring type uid `{expectedUid}`, or the namespace page `{target.Namespace}`.";

            report.Errors.Add(new Diagnostic("EXAMPLE_MISSING", null, target.Namespace, message));
        }
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

    private static bool HasExampleForTarget(OverwriteSection section, ApiTargetInfo target)
    {
        if (!HasExampleSectionWithCSharpFence(section.Body))
        {
            return false;
        }

        if (target.Kind == ApiTargetKind.ExtensionMethod &&
            !section.Body.Contains(target.DisplayName, StringComparison.Ordinal))
        {
            return false;
        }

        return true;
    }

    private static bool HasExampleSectionWithCSharpFence(string body)
    {
        var match = Regex.Match(body, @"(?im)^#{2,5}\s+Examples?\s*$");
        if (!match.Success)
        {
            return false;
        }

        var section = body[match.Index..];
        var nextHeading = Regex.Match(section[match.Length..], @"(?im)^#{1,5}\s+\S");
        if (nextHeading.Success)
        {
            section = section[..(match.Length + nextHeading.Index)];
        }

        return Regex.IsMatch(section, @"(?im)^```\s*(csharp|cs)\s*$");
    }

    // ----------------------------------------------------------------------
    // Sample validation
    // ----------------------------------------------------------------------

    private static void ValidateSamples(string repoRoot, List<string> markdownFiles, List<ProjectInfo> libraryProjects,
        Options options, HashSet<string>? changedFiles, Report report)
    {
        var samples = new List<SampleFence>();
        foreach (var md in markdownFiles)
        {
            if (options.ChangedOnly && changedFiles is not null && !changedFiles.Contains(Path.GetFullPath(md)))
            {
                continue;
            }

            samples.AddRange(ExtractFences(md));
        }

        if (samples.Count == 0)
        {
            return;
        }

        var tempRoot = Path.Combine(Path.GetTempPath(), "docfx-digest-samples-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(tempRoot);
        try
        {
            int index = 0;
            foreach (var sample in samples)
            {
                index++;
                var skip = FindSkip(sample.Code);
                if (skip.Found)
                {
                    if (string.IsNullOrWhiteSpace(skip.Reason))
                    {
                        report.Errors.Add(new Diagnostic("SAMPLE_SKIP_REASON_MISSING", Rel(repoRoot, sample.File), null,
                            $"A C# sample at fence #{sample.FenceIndex} (line {sample.StartLine}) uses the skip-compile marker without a mandatory reason."));
                    }
                    else
                    {
                        report.Summary.SamplesSkipped++;
                    }

                    continue;
                }

                var (ok, diagnostics, exitCode) = CompileSample(tempRoot, index, sample, libraryProjects, options.Configuration);
                if (ok)
                {
                    report.Summary.SamplesCompiled++;
                }
                else
                {
                    report.Errors.Add(new Diagnostic("SAMPLE_COMPILE_FAILED", Rel(repoRoot, sample.File), null,
                        $"C# sample at fence #{sample.FenceIndex} (line {sample.StartLine}) failed to compile (exit {exitCode}).\n{Trim(diagnostics)}"));
                }
            }
        }
        finally
        {
            TryDeleteDirectory(tempRoot);
        }
    }

    private static (bool Ok, string Diagnostics, int ExitCode) CompileSample(string tempRoot, int index, SampleFence sample,
        List<ProjectInfo> libraryProjects, string configuration)
    {
        var dir = Path.Combine(tempRoot, "sample_" + index);
        Directory.CreateDirectory(dir);
        var file = Path.Combine(dir, "sample.cs");

        var sb = new StringBuilder();
        sb.Append("#:property TargetFramework=net10.0\n");
        sb.Append("#:property PublishAot=false\n");
        sb.Append("#:property Nullable=enable\n");
        foreach (var proj in libraryProjects)
        {
            sb.Append("#:project ").Append(proj.Path).Append('\n');
        }

        sb.Append('\n');
        sb.Append(sample.Code);
        if (!sample.Code.EndsWith('\n'))
        {
            sb.Append('\n');
        }

        File.WriteAllText(file, sb.ToString(), new UTF8Encoding(false));

        var result = RunProcess("dotnet", $"build \"{file}\" -c {configuration} --nologo", dir);
        return (result.ExitCode == 0, result.StdOut + result.StdErr, result.ExitCode);
    }

    private static List<SampleFence> ExtractFences(string mdFile)
    {
        var fences = new List<SampleFence>();
        string[] lines;
        try
        {
            lines = File.ReadAllLines(mdFile);
        }
        catch
        {
            return fences;
        }

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
        var sections = new List<OverwriteSection>();
        string text;
        try
        {
            text = File.ReadAllText(mdFile);
        }
        catch
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
            sections.Add(new OverwriteSection(mdFile, uid, body));
        }

        return sections;
    }

    private static (bool Found, string Reason) FindSkip(string code)
    {
        foreach (var line in code.Split('\n'))
        {
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

            return (true, after);
        }

        return (false, string.Empty);
    }

    // ----------------------------------------------------------------------
    // git changed-only
    // ----------------------------------------------------------------------

    private static HashSet<string>? GetChangedFiles(string repoRoot, Report report)
    {
        var result = RunProcess("git", "rev-parse --verify HEAD", repoRoot);
        if (result.ExitCode != 0)
        {
            return null;
        }

        var diff = RunProcess("git", "diff --name-only --diff-filter=ACMRTUXB HEAD", repoRoot);
        if (diff.ExitCode != 0)
        {
            return null;
        }

        var set = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        foreach (var line in diff.StdOut.Split('\n', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries))
        {
            set.Add(Path.GetFullPath(Path.Combine(repoRoot, line)));
        }

        return set;
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

    private static ProcessResult RunProcess(string fileName, string arguments, string workingDirectory)
    {
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

        try
        {
            using var process = Process.Start(psi);
            if (process is null)
            {
                return new ProcessResult(-1, string.Empty, $"Failed to start process '{fileName}'.");
            }

            var stdout = process.StandardOutput.ReadToEnd();
            var stderr = process.StandardError.ReadToEnd();
            if (!process.WaitForExit(ProcessTimeout))
            {
                try
                {
                    process.Kill(entireProcessTree: true);
                }
                catch
                {
                    // ignore
                }

                return new ProcessResult(-1, stdout, stderr + $"\nProcess '{fileName}' timed out after {ProcessTimeout.TotalMinutes} minutes.");
            }

            return new ProcessResult(process.ExitCode, stdout, stderr);
        }
        catch (Exception ex)
        {
            return new ProcessResult(-1, string.Empty, $"Failed to run '{fileName} {arguments}': {ex.Message}");
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
                $"  Summary: namespaces={report.Summary.PublicNamespaces}, pages={report.Summary.NamespacePagesValidated}, " +
                $"concreteTargets={report.Summary.ConcreteApiTargets}, requiredExamples={report.Summary.RequiredExamples}, " +
                $"extMethods={report.Summary.ExtensionMethods}, samplesCompiled={report.Summary.SamplesCompiled}, " +
                $"samplesSkipped={report.Summary.SamplesSkipped}, errors={report.Summary.Errors}, warnings={report.Summary.Warnings}");
        }

        return (int)code;
    }

    private static string Describe(Diagnostic d)
    {
        var location = d.Namespace is not null ? $"({d.Namespace}) " : string.Empty;
        var path = d.Path is not null ? $"{d.Path}: " : string.Empty;
        return $"{path}{location}{d.Message}";
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
                case "--json":
                    options.Json = true;
                    break;
                default:
                    if (TrySplit(arg, "--repo-root", out var v1)) { options.RepoRoot = v1; break; }
                    if (TrySplit(arg, "--docfx", out var v2)) { options.DocfxPath = v2; break; }
                    if (TrySplit(arg, "--configuration", out var v3)) { options.Configuration = v3; break; }
                    if (TrySplit(arg, "--framework", out var v4)) { options.Framework = v4; break; }
                    error = $"Unknown argument: {arg}";
                    return false;
            }
        }

        return true;
    }

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

            Usage:
              dotnet run --file docfx.cs -- [options]

            Options:
              --repo-root <path>       Repository root. Default: current directory.
              --docfx <path>           Path to docfx.json. Default: .docfx/docfx.json under repo root.
              --configuration <name>   Build configuration. Default: Release.
              --framework <tfm>        Optional target framework to validate against.
              --validate-samples       Compile C# samples. Default: enabled.
              --no-validate-samples    Skip C# sample compilation.
              --changed-only           Validate only files changed according to git.
              --json                   Emit a machine-readable JSON summary.
              --help                   Print this usage.

            Exit codes:
              0  Validation passed.
              1  Validation failed.
              2  Invalid arguments.
              3  Repository root does not exist.
              4  DocFX configuration file not found.
              5  Build failed.
              6  Public API discovery failed.
              7  Sample compilation failed.
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
        public bool ValidateSamples { get; set; } = true;
        public bool ChangedOnly { get; set; }
        public bool Json { get; set; }
        public bool Help { get; set; }
    }

    private sealed record ProjectInfo(string Path, string AssemblyName, List<string> TargetFrameworks, bool IsTest);

    private sealed record ExtensionMethodInfo(string MethodName, string ExtendedType, string DeclaringClass);

    private sealed record ApiTargetInfo(string Uid, string Namespace, ApiTargetKind Kind, string DisplayName, string? DeclaringTypeUid = null);

    private enum ApiTargetKind
    {
        Type,
        ExtensionMethod
    }

    private sealed class NamespaceInfo(string name)
    {
        public string Name { get; } = name;
        public List<ApiTargetInfo> ConcreteTargets { get; } = new();
        public List<ExtensionMethodInfo> ExtensionMethods { get; } = new();
    }

    private sealed record ApiModel(List<NamespaceInfo> Namespaces, List<ApiTargetInfo> ConcreteTargets);

    private sealed record SampleFence(string File, int FenceIndex, int StartLine, string Code);

    private sealed record OverwriteSection(string File, string Uid, string Body);

    private sealed record ProcessResult(int ExitCode, string StdOut, string StdErr);
}

internal sealed class Diagnostic
{
    public Diagnostic(string code, string? path, string? @namespace, string message)
    {
        Code = code;
        Path = path;
        Namespace = @namespace;
        Message = message;
    }

    [JsonPropertyName("code")] public string Code { get; }
    [JsonPropertyName("path")] public string? Path { get; }
    [JsonPropertyName("namespace")] public string? Namespace { get; }
    [JsonPropertyName("message")] public string Message { get; }
}

internal sealed class Summary
{
    public int PublicNamespaces { get; set; }
    public int NamespacePagesValidated { get; set; }
    public int ConcreteApiTargets { get; set; }
    public int RequiredExamples { get; set; }
    public int ExtensionMethods { get; set; }
    public int SamplesCompiled { get; set; }
    public int SamplesSkipped { get; set; }
    public int Errors { get; set; }
    public int Warnings { get; set; }
}

internal sealed class Report
{
    public string Script { get; set; } = string.Empty;
    public string RepoRoot { get; set; } = string.Empty;
    public string? DocfxPath { get; set; }
    public string? Status { get; set; }
    public Summary Summary { get; set; } = new();
    public List<Diagnostic> Errors { get; set; } = new();
    public List<Diagnostic> Warnings { get; set; } = new();
}
