var app = WebApplication.CreateBuilder(args).Build();
app.MapStaticAssets();
app.MapGet("/", () => "portal");
app.Run();
