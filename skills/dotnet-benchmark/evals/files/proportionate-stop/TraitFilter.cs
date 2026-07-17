using System;
using System.Collections.Generic;
using System.Linq;

namespace Acme.Testing;

public static class TraitFilter
{
    public static string[] Matching(IReadOnlyList<string> traits, string prefix) =>
        traits.Where(trait => trait.StartsWith(prefix, StringComparison.Ordinal)).ToArray();
}
