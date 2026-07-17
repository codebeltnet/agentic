namespace Acme.Reporting;

public sealed class ReportImportJob(ReportLoader loader)
{
    public IReadOnlyList<Report> Import(IEnumerable<string> paths) => paths.Select(loader.Load).ToArray();
}
