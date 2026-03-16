using Codebelt.Bootstrapper.Web;
using Microsoft.AspNetCore.Builder;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Hosting;

namespace {ROOT_NAMESPACE}.{AppType};

public class Startup : WebStartup
{
    public Startup(IConfiguration configuration, IHostEnvironment environment) : base(configuration, environment)
    {
    }

    public override void ConfigureServices(IServiceCollection services)
    {
        services.AddControllers();
    }

    public override void ConfigurePipeline(IApplicationBuilder app)
    {
        app.UseHttpsRedirection();
        app.UseRouting();
        app.UseAuthorization();
        app.UseEndpoints(endpoints =>
        {
            endpoints.MapControllers();
        });
    }
}
