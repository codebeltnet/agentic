var app = WebApplication.CreateBuilder(args).Build();
app.MapStaticAssets();
app.MapGet("/", () => "storefront");
app.Run();
