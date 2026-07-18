namespace Acme.Routing.Tests;

public class RouteMatcherTests
{
    // Representative cases: exact hit, wildcard hit, single-character wildcard, and miss.
    private static readonly (string Pattern, string Path, bool Expected)[] Cases =
    [
        ("api/health", "api/health", true),
        ("api/*/orders/*", "api/v2/orders/2026-000042", true),
        ("tenant-?/reports/*.json", "tenant-a/reports/monthly-2026-06.json", true),
        ("assets/*.css", "assets/app.js", false)
    ];
}
