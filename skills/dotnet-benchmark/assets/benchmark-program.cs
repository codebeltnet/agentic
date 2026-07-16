using BenchmarkDotNet.Configs;
using BenchmarkDotNet.Environments;
using BenchmarkDotNet.Jobs;
using Codebelt.Extensions.BenchmarkDotNet;
using Codebelt.Extensions.BenchmarkDotNet.Console;

namespace {RUNNER_NAMESPACE};

public class Program
{
    public static void Main(string[] args)
    {
        BenchmarkProgram.Run(args, o =>
        {
            o.AllowDebugBuild = BenchmarkProgram.IsDebugBuild;
            o.SkipBenchmarksWithReports = true;
            o.ConfigureBenchmarkDotNet(c =>
            {
                var slimJob = BenchmarkWorkspaceOptions.Slim;
                return c
{RUNTIME_JOBS};
            });
        });
    }
}
