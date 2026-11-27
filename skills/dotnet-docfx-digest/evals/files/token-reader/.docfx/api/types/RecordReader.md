---
uid: Cuemon.Data.TokenBuilder
example:
- *content
---

Read a person record in two chunks and a product record with a quoted separator. Run both readers to see the partial and complete states and the preserved product description.

```csharp
using System;
using Cuemon.Data;

namespace Import;

public static class RecordReader
{
    public static void ReadPerson()
    {
        var person = new TokenBuilder(',', '"', 4);
        person.Append("Alice,30,");
        Console.WriteLine(person.IsValid);
        person.Append("New York,Engineer");
        Console.WriteLine(person);
    }

    public static void ReadProduct()
    {
        var product = new TokenBuilder(';', '"', 3);
        product.Append("Product A;\"Description with ; semicolon\";$49.99");
        Console.WriteLine(product);
    }
}
```
