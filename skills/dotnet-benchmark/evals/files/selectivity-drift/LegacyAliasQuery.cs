using System.Collections.Generic;
using System.Linq;

namespace Acme.Search;

public static class LegacyAliasQuery
{
    public static int CountLegacyAliases(IEnumerable<string> aliases) => aliases.Count(alias => alias.Length == 6);
}
