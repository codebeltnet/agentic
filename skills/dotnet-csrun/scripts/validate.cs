using System.Text.Json;
using System.Text.RegularExpressions;

// Validates only maintained skill artifacts, never the csrun manifest contract.
var root = Path.GetFullPath(args.Single());
var skill = File.ReadAllText(Path.Combine(root, "SKILL.md"));
foreach (Match link in Regex.Matches(skill, @"\]\(([^)]+)\)"))
{
    var path = link.Groups[1].Value;
    if (!path.Contains("://") && !File.Exists(Path.Combine(root, path)))
        throw new InvalidDataException($"Broken resource link: {path}");
}
var expectedSources = new Dictionary<string, string>
{
    ["console"] = "Console.WriteLine(42)",
    ["passing"] = "Assert.Equal(42, value + 22)",
    ["failing"] = "Assert.Equal(42, 41)",
    ["invalid"] = "missingValue",
    ["empty"] = "public class NoTests",
    ["package"] = "new DateSpan",
    ["unicode"] = "Hello \"C#\" — æøå 世界\nsecond line",
    ["inventory-worker"] = "ApplicationTest<WorkerProgram, ManagedApplicationFixture<WorkerProgram>>",
    ["standalone-host"] = "StandaloneHostResolvesRegisteredIdentity",
    ["multiple-entrypoints"] = "public static void Main(string[] args)",
    ["safe-adaptation"] = "Assert.Equal(42, await Task.FromResult(42))"
};
foreach (var (name, fragment) in expectedSources)
{
    using var fixture = JsonDocument.Parse(File.ReadAllText(Path.Combine(root, "evals", "files", name + ".json")));
    var source = fixture.RootElement.GetProperty("source").GetString()!;
    if (!source.Contains(fragment, StringComparison.Ordinal)) throw new InvalidDataException($"Fixture intent drift: {name}");
    var options = new JsonSerializerOptions { TypeInfoResolver = new System.Text.Json.Serialization.Metadata.DefaultJsonTypeInfoResolver() };
    var roundTrip = JsonSerializer.Deserialize<string>(JsonSerializer.Serialize(source, options), options);
    if (source != roundTrip) throw new InvalidDataException($"Source round-trip failed: {name}");
}
// Ensure the published journey and the executable fixture describe the same program.
using var console = JsonDocument.Parse(File.ReadAllText(Path.Combine(root, "evals", "files", "console.json")));
var documented = Regex.Match(skill, "source = @'\\r?\\n(.*?)\\r?\\n'@", RegexOptions.Singleline).Groups[1].Value;
if (documented.Replace("\r\n", "\n") != console.RootElement.GetProperty("source").GetString()!.Replace("\r\n", "\n"))
    throw new InvalidDataException("Published console source differs from fixture.");
// Lock the exact regression, including its composition root and Main, against false repairs.
using var inventory = JsonDocument.Parse(File.ReadAllText(Path.Combine(root, "evals", "files", "inventory-worker.json")));
var original = inventory.RootElement.GetProperty("source").GetString()!;
var originalHash = Convert.ToHexString(System.Security.Cryptography.SHA256.HashData(System.Text.Encoding.UTF8.GetBytes(original.Replace("\r\n", "\n"))));
if (originalHash != "6B54B2CA6E2D3EDF8EC3ED4B7CB1E1CFA7E28265F41B228E3EE9465DD9B7D9A4") throw new InvalidDataException("Original InventoryWorker source changed; do not remove the behavior under test.");
foreach (var name in new[] { "inventory-worker", "standalone-host", "multiple-entrypoints", "safe-adaptation" })
{
    using var fixture = JsonDocument.Parse(File.ReadAllText(Path.Combine(root, "evals", "files", name + ".json")));
    var item = fixture.RootElement;
    var allowed = new[] { "schemaVersion", "mode", "framework", "dependsOn", "source" };
    if (item.EnumerateObject().Any(p => !allowed.Contains(p.Name)) || item.GetProperty("schemaVersion").GetInt32() != 1 || item.GetProperty("framework").GetString() != "net10.0" || item.GetProperty("mode").GetString() != "test")
        throw new InvalidDataException($"Regression manifest drift: {name}");
    var expectedPins = name is "inventory-worker" or "standalone-host" ? new[] { "Codebelt.Extensions.Xunit.App@13.0.0", "xunit.v3@4.0.3" } : new[] { "xunit.v3@4.0.3" };
    if (!item.GetProperty("dependsOn").EnumerateArray().Select(p => p.GetString()).SequenceEqual(expectedPins))
        throw new InvalidDataException($"Regression package pins changed: {name}");
}
Console.WriteLine($"dotnet-csrun artifacts passed: {expectedSources.Count} source fixtures, JSON round-trips, resource links, published source parity, original regression identity and pins.");
