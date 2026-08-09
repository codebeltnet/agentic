var builder = WebApplication.CreateBuilder(args);
builder.Services.AddSingleton(new StatusMarker("ready"));
var app = builder.Build();
app.MapGet("/status", (StatusMarker marker, IConfiguration configuration, IHostEnvironment environment) => $"{marker.Value}|{configuration["Status:Lane"]}|{environment.EnvironmentName}");
app.Run();

public sealed record StatusMarker(string Value);
public partial class Program;

