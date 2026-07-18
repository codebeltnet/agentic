# LegacyAliasCountBenchmark summary excerpt

| Method | Size | Mean | Error | Allocated |
|---|---:|---:|---:|---:|
| CountAll | 8 | 0.381 ns | 0.02 ns | 0 B |
| CountLegacy | 8 | NA | NA | NA |
| CountAll | 256 | 0.380 ns | 0.02 ns | 0 B |
| CountLegacy | 256 | 1.206 us | 0.03 us | 40 B |
| CountAll | 4096 | 0.381 ns | 0.02 ns | 0 B |
| CountLegacy | 4096 | 10.944 us | 0.19 us | 40 B |

Benchmarks with issues:
  LegacyAliasCountBenchmark.CountLegacy(Size: 8, Job: DefaultJob)
    GlobalSetup failed: InvalidOperationException: Workload must have at least one legacy alias.
