using Cuemon.AspNetCore.Razor.TagHelpers;
using Tolk.Web;

var builder = WebApplication.CreateBuilder(args);
builder.Services.AddControllersWithViews();

// Deployed configuration binds absolute HTTPS bases; local Development overrides via the segregated launch profile.
builder.Services.Configure<AppTagHelperOptions>(builder.Configuration.GetSection("App"));
builder.Services.Configure<CdnTagHelperOptions>(builder.Configuration.GetSection("Cdn"));
builder.Services.Configure<AppAssetOptions>(builder.Configuration.GetSection("Assets"));

var app = builder.Build();
app.MapStaticAssets();
app.MapDefaultControllerRoute();
app.Run();
