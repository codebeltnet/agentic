var app = WebApplication.CreateBuilder(args).Build();
app.MapStaticAssets();
app.MapGet("/", () => "orders");
app.Run();
