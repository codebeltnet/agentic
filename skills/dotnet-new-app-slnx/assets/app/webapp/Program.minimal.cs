using Codebelt.Bootstrapper.Web;

namespace {ROOT_NAMESPACE}.{AppType};

public class Program : MinimalWebProgram
{
    static Task Main(string[] args)
    {
        var builder = CreateHostBuilder(args);
        builder.Services.AddRazorPages();
        var app = builder.Build();
        app.UseHttpsRedirection();
        app.UseStaticFiles();
        app.UseRouting();
        app.UseAuthorization();
        app.MapRazorPages();
        return app.RunAsync();
    }
}
