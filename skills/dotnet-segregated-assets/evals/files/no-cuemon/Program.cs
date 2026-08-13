var builder = WebApplication.CreateBuilder(args);
// The application already prefixes asset URLs from its own configuration section.
var assetBase = builder.Configuration["Assets:BaseUrl"] ?? "";
var app = builder.Build();
app.MapStaticAssets();
app.MapGet("/asset-base", () => assetBase);
app.Run();
