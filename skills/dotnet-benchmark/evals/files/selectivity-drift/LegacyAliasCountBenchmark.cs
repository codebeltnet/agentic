using System;
using System.Collections.Generic;
using System.Linq;
using BenchmarkDotNet.Attributes;
using BenchmarkDotNet.Configs;

namespace Acme.Search;

[MemoryDiagnoser]
[GroupBenchmarksBy(BenchmarkLogicalGroupRule.ByCategory)]
public class LegacyAliasCountBenchmark
{
    [Params(8, 256, 4_096)]
    public int Size { get; set; }

    private List<string> _aliases = null!;

    [GlobalSetup]
    public void Setup()
    {
        _aliases = Enumerable.Range(0, Size)
            .Select(i => $"USR{i}")
            .ToList();

        var expectedMatches = LegacyAliasQuery.CountLegacyAliases(_aliases);
        if (expectedMatches == 0)
        {
            throw new InvalidOperationException("Workload must have at least one legacy alias.");
        }
    }

    [Benchmark(Baseline = true, Description = "List.Count")]
    public int CountAll() => _aliases.Count;

    [Benchmark(Description = "Where(alias.Length == 6).Count()")]
    public int CountLegacy() => _aliases.Where(alias => alias.Length == 6).Count();
}
