using System.Text.Json;

namespace Acme.Reporting;

public sealed class ReportLoader
{
    public Report Load(string path) => Parse(File.ReadAllBytes(path));

    public Report Parse(ReadOnlySpan<byte> utf8) => JsonSerializer.Deserialize<Report>(utf8)!;
}

public sealed record Report(string Name, IReadOnlyList<ReportRow> Rows);

public sealed record ReportRow(string Key, decimal Value, string? Comment);
