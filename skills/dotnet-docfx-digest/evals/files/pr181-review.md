# Runnable example review packet

Extracts and condensed review notes from [Cuemon PR 181 at the reviewed revision](https://github.com/codebeltnet/Cuemon/tree/544d368fb1d29effa30295fdfbe09dac26b9d0ec). Both script links are present on the pages.

| Page claim | Displayed operations |
| --- | --- |
| XmlDataReader reads each nested record as one row with id, name and score columns. | The input contains repeated `<record><id>1</id><name>Alice</name><score>95.5</score></record>` elements. The loop reads those three field names on every row. |
| TokenBuilder still needs a fourth field after New York. | See the fence and console capture below. |
| CacheValidatorFactory prints a SHA-256 checksum. | The factory delegate calls `HashFactory.CreateFnv128()`. The output label is `SHA-256`. |
| HttpRequestEvidence displays a body with customerId redacted. | The captured stream contains `customerId=42`. The example constructs `new HttpRequestEvidence(context.Request)` and prints `evidence.Body`. |
| Middleware adds the configured response header. | The example configures the header value and prints the same setting. |
| The authentication handler authenticates an incoming request. | The example registers the scheme and displays its options. |

```csharp
var builder = new TokenBuilder(',', '"', 4);
builder.Append("Alice");
builder.Append(",30,");
builder.Append("New York");
Console.WriteLine(builder.IsValid); // false
builder.Append("Engineer");
Console.WriteLine(builder.ToString());
```

The first validity check printed True. The final buffer was `Alice,30,New YorkE`. The process exited successfully. The other rows have no captured runtime results in this packet.
