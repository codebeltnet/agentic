using System.Collections.Generic;

namespace Acme.Testing;

public sealed class TraitDiscovery
{
    public IReadOnlyList<string> SelectIntegrationTraits(IReadOnlyList<string> traits) =>
        TraitFilter.Matching(traits, "integration:");
}
