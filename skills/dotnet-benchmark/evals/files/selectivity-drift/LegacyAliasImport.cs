using System.Collections.Generic;
using System.Linq;

namespace Acme.Search;

public sealed class LegacyAliasImport
{
    public IReadOnlyList<string> BuildAliases(int count) =>
        Enumerable.Range(0, count)
            .Select(i => $"USR{i:D3}")
            .ToArray();
}
