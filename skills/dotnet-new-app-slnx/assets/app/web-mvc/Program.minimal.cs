using Codebelt.Bootstrapper.Web;

namespace {ROOT_NAMESPACE}.{AppType};

public class Program : MinimalWebProgram
{
    static Task Main(string[] args)
    {
        var builder = CreateHostBuilder(args);
        builder.Services.AddControllersWithViews();
        var app = builder.Build();
        app.UseHttpsRedirection();
        app.UseStaticFiles();
        app.UseRouting();
        app.UseAuthorization();
        app.MapControllerRoute(
            name: "default",
            pattern: "{controller=Home}/{action=Index}/{id?}");
        return app.RunAsync();
    }
}
