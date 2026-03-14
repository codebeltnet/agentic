namespace {ROOT_NAMESPACE}.{AppType};

public class Program : WorkerProgram<Startup>
{
    static async Task Main(string[] args)
    {
        await CreateHostBuilder(args)
            .Build()
            .RunAsync()
            .ConfigureAwait(false);
    }
}
