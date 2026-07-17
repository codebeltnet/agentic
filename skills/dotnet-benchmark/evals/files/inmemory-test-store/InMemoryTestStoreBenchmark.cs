using System;
using System.Linq;
using BenchmarkDotNet.Attributes;
using BenchmarkDotNet.Configs;

namespace Codebelt.Extensions.Xunit;

/// <summary>
/// Benchmarks for the <see cref="InMemoryTestStore{T}"/> query operations.
/// </summary>
[MemoryDiagnoser]
[GroupBenchmarksBy(BenchmarkLogicalGroupRule.ByCategory)]
public class InMemoryTestStoreBenchmark
{
    private InMemoryTestStore<int> _store;
    private Func<int, bool> _low10PercentSelectivity;
    private Func<int, bool> _mid50PercentSelectivity;
    private Func<int, bool> _high100PercentSelectivity;

    [Params(8, 256, 4096)]
    public int ItemCount { get; set; }

    [GlobalSetup]
    public void Setup()
    {
        _store = new InMemoryTestStore<int>();
        for (int i = 0; i < ItemCount; i++)
        {
            _store.Add(i);
        }

        // Predicates with different selectivity levels.
        var threshold10 = (int)(ItemCount * 0.1);
        var threshold50 = ItemCount / 2;

        _low10PercentSelectivity = x => x < threshold10;
        _mid50PercentSelectivity = x => x < threshold50;
        _high100PercentSelectivity = x => x >= 0;
    }

    [Benchmark(Baseline = true, Description = "Query - no predicate")]
    [BenchmarkCategory("Query")]
    public int Query_NoPredicate()
    {
        var result = _store.Query();
        return result.Count();
    }

    [Benchmark(Description = "Query - 10% selectivity")]
    [BenchmarkCategory("Query")]
    public int Query_10PercentSelectivity()
    {
        var result = _store.Query(_low10PercentSelectivity);
        return result.Count();
    }

    [Benchmark(Description = "Query - 50% selectivity")]
    [BenchmarkCategory("Query")]
    public int Query_50PercentSelectivity()
    {
        var result = _store.Query(_mid50PercentSelectivity);
        return result.Count();
    }

    [Benchmark(Description = "Query - 100% selectivity")]
    [BenchmarkCategory("Query")]
    public int Query_100PercentSelectivity()
    {
        var result = _store.Query(_high100PercentSelectivity);
        return result.Count();
    }

    [Benchmark(Description = "QueryFor - filtered by type")]
    [BenchmarkCategory("QueryFor")]
    public int QueryFor_TypeFilter()
    {
        var result = _store.QueryFor<int>();
        return result.Count();
    }
}
