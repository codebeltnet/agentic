var builder = WebApplication.CreateBuilder(args);
var app = builder.Build();
if (app.Environment.IsDevelopment())
{
    app.MapStaticAssets();
}
app.MapGet("/", () => "Fabrikam");
app.Run();
