namespace Acme.Routing;

public sealed class RouteTable(RouteMatcher matcher, IReadOnlyList<string> patterns)
{
    public string? Find(string path)
    {
        foreach (var pattern in patterns)
        {
            if (matcher.IsMatch(pattern, path))
            {
                return pattern;
            }
        }

        return null;
    }
}
