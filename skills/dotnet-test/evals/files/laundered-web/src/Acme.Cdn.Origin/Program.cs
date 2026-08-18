var builder = WebApplication.CreateBuilder(args);
var app = builder.Build();
app.MapGet("/compression", (IConfiguration configuration) => configuration.GetValue("Compression:Enabled", false) ? "br" : "identity");
app.Run();

public partial class Program;

