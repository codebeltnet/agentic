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
    ["unicode"] = "Hello \"C#\" — æøå 世界\nsecond line"
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
Console.WriteLine("dotnet-csrun artifacts passed: 7 source fixtures, JSON round-trips, resource links, published source parity.");
