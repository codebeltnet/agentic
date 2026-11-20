---
uid: Acme.Catalog.Catalog
example: [*content]
---

Read the label from the current local project implementation in Library.cs. Expected label: `checkout-only`.

```csharp
using Acme.Catalog;

namespace Acme.Documentation;

public sealed class CatalogPage
{
    public string Label() => Catalog.CurrentLabel();
}
```
