using Cuemon.AspNetCore.Razor.TagHelpers;

var builder = WebApplication.CreateBuilder(args);
builder.Services.AddControllersWithViews();

// Deployed configuration binds absolute HTTPS bases; local Development overrides via the segregated launch profile.
builder.Services.Configure<AppTagHelperOptions>(builder.Configuration.GetSection("App"));
builder.Services.Configure<CdnTagHelperOptions>(builder.Configuration.GetSection("Cdn"));

var app = builder.Build();
app.MapStaticAssets();
app.MapDefaultControllerRoute();
app.Run();
