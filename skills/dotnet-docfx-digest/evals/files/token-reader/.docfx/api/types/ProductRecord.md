---
uid: Cuemon.Data.TokenBuilder
example:
- *content
---

Read a three-field product record whose quoted description contains a semicolon. Inspect the completed buffer to see that the description and price survived parsing.

```csharp
// Program.cs
using System;
using Cuemon.Data;

var product = new TokenBuilder(';', '"', 3);
product.Append("Product A;\"Description with ; semicolon\";$49.99");
Console.WriteLine(product.IsValid);
Console.WriteLine(product);
```
