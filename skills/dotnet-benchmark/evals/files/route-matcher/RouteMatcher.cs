using System.Text.RegularExpressions;

namespace Acme.Routing;

public sealed class RouteMatcher
{
    public bool IsMatch(string pattern, string path)
    {
        var regexPattern = "^" + Regex.Escape(pattern).Replace("\\*", ".*").Replace("\\?", ".") + "$";
        return Regex.IsMatch(path, regexPattern, RegexOptions.IgnoreCase | RegexOptions.CultureInvariant);
    }

    public string Normalize(string path) => path.Trim().Trim('/').ToLowerInvariant();

    public override string ToString() => nameof(RouteMatcher);
}
