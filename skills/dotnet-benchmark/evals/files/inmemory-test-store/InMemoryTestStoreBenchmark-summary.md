# InMemoryTestStoreBenchmark summary excerpt

The benchmark already executed successfully; the concern is whether the workloads and labels are semantically true.

| Method | Runtime | ItemCount | Mean | Allocated |
|---|---|---:|---:|---:|
| Query - no predicate | .NET 10.0 | 8 | 0.7339 ns | - |
| Query - 10% selectivity | .NET 10.0 | 8 | 10.7615 ns | 72 B |
| Query - 50% selectivity | .NET 10.0 | 8 | 13.6044 ns | 72 B |
| Query - 100% selectivity | .NET 10.0 | 8 | 9.9140 ns | 72 B |
| QueryFor - filtered by type | .NET 10.0 | 8 | 9.0760 ns | 72 B |
| Query - no predicate | .NET 10.0 | 256 | 0.6446 ns | - |
| Query - 10% selectivity | .NET 10.0 | 256 | 80.3261 ns | 72 B |
| Query - 50% selectivity | .NET 10.0 | 256 | 100.6783 ns | 72 B |
| Query - 100% selectivity | .NET 10.0 | 256 | 96.9278 ns | 72 B |
| QueryFor - filtered by type | .NET 10.0 | 256 | 72.5479 ns | 72 B |
| Query - no predicate | .NET 10.0 | 4096 | 0.6269 ns | - |
| Query - 10% selectivity | .NET 10.0 | 4096 | 953.6987 ns | 72 B |
| Query - 50% selectivity | .NET 10.0 | 4096 | 1,103.5284 ns | 72 B |
| Query - 100% selectivity | .NET 10.0 | 4096 | 1,376.7703 ns | 72 B |
| QueryFor - filtered by type | .NET 10.0 | 4096 | 868.7072 ns | 72 B |
