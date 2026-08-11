var app = WebApplication.CreateBuilder(args).Build();
app.MapStaticAssets();
app.MapGet("/", () => "site");
app.Run();
