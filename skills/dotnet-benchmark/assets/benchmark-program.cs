// Emit these runtime-job using directives only when extra AddJob(...) runtimes were selected.
{RUNTIME_USINGS}
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
                // If the user chose "Runner default only", leave the next line as `return c;`.
                // Otherwise append newline-prefixed chained `.AddJob(...)` calls to the return expression.
                return c{RUNTIME_JOBS};
            });
        });
    }
}
