namespace {ROOT_NAMESPACE}.{AppType};

public class Program : ConsoleProgram<Startup>
{
    static async Task Main(string[] args)
    {
        await CreateHostBuilder(args)
            .Build()
            .RunAsync()
            .ConfigureAwait(false);
    }
}
