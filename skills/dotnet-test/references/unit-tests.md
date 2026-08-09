# Ordinary unit tests

Use this role when the test exercises a type or collaboration without starting an application entry point.

## Codebelt shape

The behavioral source is `Codebelt.Extensions.Xunit.Test` and the Codebelt xUnit test suite:

```csharp
using Codebelt.Extensions.Xunit;
using Xunit;

namespace Acme.Product;

public class WidgetTest : Test
{
    public WidgetTest(ITestOutputHelper output) : base(output)
    {
    }

    [Fact]
    public void ShouldReturnExpectedValue_WhenInputIsValid()
    {
        // Arrange, act, and assert observable behavior.
    }
}
```

Preserve an established base class when it already derives from `Test` and carries real shared behavior. Do not flatten it merely to make every class inherit `Test` directly.

## Bootstrap selection

Read the selected production source and choose a deterministic public behavior. Prefer a small logic boundary over a slow application boundary. A generated test must fail for a plausible defect; placeholders and construction-only assertions do not qualify.

Use the production namespace, not a `.Tests` suffix, when applying Codebelt conventions to new files. Preserve existing namespaces during a scoped modernization unless namespace migration is explicitly requested.

