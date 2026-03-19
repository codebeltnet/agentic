---
description: 'Writing Unit Tests'
applyTo: "**/*.{cs,csproj}"
---

# Writing Unit Tests
This document provides instructions for writing unit tests for a project/solution. Please follow these guidelines to ensure consistency and maintainability.

## 1. Base Class

**Always inherit from the `Test` base class** for all unit test classes. This ensures consistent setup, teardown, and output handling across all tests.

> Important: Do NOT add `using Xunit.Abstractions`. xUnit v3 no longer exposes that namespace; including it is incorrect and will cause compilation errors. Use the `Codebelt.Extensions.Xunit` Test base class and `using Xunit;` as shown in the examples below. If you need access to test output, rely on the Test base class (which accepts the appropriate output helper) rather than importing `Xunit.Abstractions`.

```csharp
using Codebelt.Extensions.Xunit;
using Xunit;

namespace Your.Namespace
{
    public class YourTestClass : Test
    {
        public YourTestClass(ITestOutputHelper output) : base(output)
        {
        }

        // Your tests here
    }
}
```

## 2. Test Method Attributes

- Use `[Fact]` for standard unit tests.
- Use `[Theory]` with `[InlineData]` or other data sources for parameterized tests.

## 3. Naming Conventions

- **Test classes**: End with `Test` (e.g., `DateSpanTest`).
- **Test methods**: Use descriptive names that state the expected behavior (e.g., `ShouldReturnTrue_WhenConditionIsMet`).

## 4. Assertions

- Use `Assert` methods from xUnit for all assertions.
- Prefer explicit and expressive assertions (e.g., `Assert.Equal`, `Assert.NotNull`, `Assert.Contains`).

## 5. File and Namespace Organization

- Place test files in the appropriate test project and folder structure.
- Use namespaces that mirror the source code structure. The namespace of a test file MUST match the namespace of the System Under Test (SUT). Do NOT append ".Tests", ".Benchmarks" or similar suffixes to the namespace. Only the assembly/project name should indicate that the file is a test/benchmark.
    - Example: If the SUT class is declared as:
        ```csharp
        namespace YourProject.Foo.Bar
        {
                public class Zoo { /* ... */ }
        }
        ```
then the corresponding unit test class must use the exact same namespace:
        ```csharp
        namespace YourProject.Foo.Bar
        {
                public class ZooTest : Test { /* ... */ }
        }
        ```
    - Do NOT use:
        ```csharp
        namespace YourProject.Foo.Bar.Tests { /* ... */ } // ❌
        namespace YourProject.Foo.Bar.Benchmarks { /* ... */ } // ❌
        ```
 - The unit tests for the YourProject.Foo assembly live in the YourProject.Foo.Tests assembly.
 - The functional tests for the YourProject.Foo assembly live in the YourProject.Foo.FunctionalTests assembly.
 - Test class names end with Test and live in the same namespace as the class being tested, e.g., the unit tests for the Boo class that resides in the YourProject.Foo assembly would be named BooTest and placed in the YourProject.Foo namespace in the YourProject.Foo.Tests assembly.
 - Modify the associated .csproj file to override the root namespace so the compiled namespace matches the SUT. Example:
    ```xml
    <PropertyGroup>
        <RootNamespace>YourProject.Foo</RootNamespace>
    </PropertyGroup>
    ```
- When generating test scaffolding automatically, resolve the SUT's namespace from the source file (or project/assembly metadata) and use that exact namespace in the test file header.

- Notes:
  - This rule ensures type discovery and XML doc links behave consistently and reduces confusion when reading tests.
  - Keep folder structure aligned with the production code layout to make locating SUT <-> test pairs straightforward.

## 6. Example Test

```csharp
using System;
using Codebelt.Extensions.Xunit;
using Xunit;

namespace YourProject
{
    public class SampleTest : Test
    {
        public SampleTest(ITestOutputHelper output) : base(output)
        {
        }

        [Fact]
        public void ShouldReturnExpectedResult_WhenGivenValidInput()
        {
            var sut = new SampleClass();

            var result = sut.Process("input");

            Assert.NotNull(result);
            Assert.Equal("expected", result.Value);

            TestOutput.WriteLine(result.ToString());
        }

        [Theory]
        [InlineData(1, "one")]
        [InlineData(2, "two")]
        public void ShouldMapCorrectly_WhenGivenNumber(int input, string expected)
        {
            var sut = new SampleClass();

            var result = sut.MapToString(input);

            Assert.Equal(expected, result);
        }
    }
}
```

## 7. Additional Guidelines

- Keep tests focused and isolated.
- Do not rely on external systems except for xUnit itself and Codebelt.Extensions.Xunit (and derived from this).
- Ensure tests are deterministic and repeatable.

## 8. Test Doubles

- Preferred test doubles include dummies, fakes, stubs and spies if and when the design allows it.
- Under special circumstances, mock can be used (using Moq library).
- Before overriding methods, verify that the method is virtual or abstract; this rule also applies to mocks.
- Never mock IMarshaller; always use a new instance of JsonMarshaller.

## 9. Avoid `InternalsVisibleTo` in Tests

- **Do not** use `InternalsVisibleTo` to access internal types or members from test projects.
- Prefer **indirect testing via public APIs** that depend on the internal implementation (public facades, public extension methods, or other public entry points).

### Preferred Pattern

**Pattern name:** Public Facade Testing (also referred to as *Public API Proxy Testing*)

**Description:** Internal classes and methods must be validated by exercising the public API that consumes them. Tests should assert observable behavior exposed by the public surface rather than targeting internal implementation details directly.

### Example Mapping

- **Internal helper:** `DelimitedString` (internal static class)
- **Public API:** `TestOutputHelperExtensions.WriteLines()` (public extension method)
- **Test strategy:** Write tests for `WriteLines()` and verify its public behavior. The internal call to `DelimitedString.Create()` is exercised implicitly.

### Benefits

- Avoids exposing internal types to test assemblies.
- Ensures tests reflect real-world usage patterns.
- Maintains strong encapsulation and a clean public API.
- Tests remain resilient to internal refactoring as long as public behavior is preserved.

### When to Apply

- Internal logic is fully exercised through existing public APIs.
- Public entry points provide sufficient coverage of internal code paths.
- The internal implementation exists solely as a helper or utility for public-facing functionality.

---
description: 'Writing Performance Tests'
applyTo: "tuning/**, **/*Benchmark*.cs"
---

# Writing Performance Tests
This document provides guidance for writing performance tests (benchmarks) for a project/solution using BenchmarkDotNet. Follow these guidelines to keep benchmarks consistent, readable, and comparable.

## 1. Naming and Placement

- Place micro- and component-benchmarks under the `tuning/` folder or in projects named `*.Benchmarks`.
- Place benchmark files in the appropriate benchmark project and folder structure.
- Use namespaces that mirror the source code structure, e.g. do not suffix with `Benchmarks`.
Namespace rule: DO NOT append `.Benchmarks` to the namespace. Benchmarks must live in the same namespace as the production assembly. Example: if the production assembly uses `namespace YourProject.Security.Cryptography`, the benchmark file should also use:
  ```
  namespace YourProject.Security.Cryptography
  {
      public class Sha512256Benchmark { /* ... */ }
  }
  ```
The class name must end with `Benchmark`, but the namespace must match the assembly (no `.Benchmarks` suffix). - The benchmarks for the YourProject.Bar assembly live in the YourProject.Bar.Benchmarks assembly. - Benchmark class names end with Benchmark and live in the same namespace as the class being measured, e.g., the benchmarks for the Zoo class that resides in the YourProject.Bar assembly would be named ZooBenchmark and placed in the YourProject.Bar namespace in the YourProject.Bar.Benchmarks assembly. - Modify the associated .csproj file to override the root namespace, e.g., <RootNamespace>YourProject.Bar</RootNamespace>.

## 2. Attributes and Configuration

- Use `BenchmarkDotNet` attributes to express intent and collect relevant metrics:
    - `[MemoryDiagnoser]` to capture memory allocations.
    - `[GroupBenchmarksBy(BenchmarkLogicalGroupRule.ByCategory)]` to group related benchmarks.
    - `[Params]` for input sizes or variations to exercise multiple scenarios.
    - `[GlobalSetup]` for one-time initialization that's not part of measured work.
    - `[Benchmark]` on methods representing measured operations; consider `Baseline = true` and `Description` to improve report clarity.
- Keep benchmark configuration minimal and explicit; prefer in-class attributes over large shared configs unless re-used widely.

## 3. Structure and Best Practices

- Keep benchmarks focused: each `Benchmark` method should measure a single logical operation.
- Avoid doing expensive setup work inside a measured method; use `[GlobalSetup]`, `[IterationSetup]`, or cached fields instead.
- Use `Params` to cover micro, mid and macro input sizes (for example: small, medium, large) and verify performance trends across them.
- Use small, deterministic data sets and avoid external systems (network, disk, DB). If external systems are necessary, mark them clearly and do not include them in CI benchmark runs by default.
- Capture results that are meaningful: time, allocations, and if needed custom counters. Prefer `MemoryDiagnoser` and descriptive `Description` values.

## 4. Naming Conventions for Methods

- Method names should be descriptive and indicate the scenario, e.g., `Parse_Short`, `ComputeHash_Large`.
- When comparing implementations, mark one method with `Baseline = true` and use similar names so reports are easy to read.

## 5. Example Benchmark

```csharp
using BenchmarkDotNet.Attributes;
using BenchmarkDotNet.Configs;

namespace YourProject
{
    [MemoryDiagnoser]
    [GroupBenchmarksBy(BenchmarkLogicalGroupRule.ByCategory)]
    public class SampleOperationBenchmark
    {
        [Params(8, 256, 4096)]
        public int Count { get; set; }

        private byte[] _payload;

        [GlobalSetup]
        public void Setup()
        {
            _payload = new byte[Count];
        }

        [Benchmark(Baseline = true, Description = "Operation - baseline")]
        public int Operation_Baseline() => SampleOperation.Process(_payload);

        [Benchmark(Description = "Operation - optimized")]
        public int Operation_Optimized() => SampleOperation.ProcessOptimized(_payload);
    }
}
```

## 6. Reporting and CI

- Benchmarks are primarily for local and tuning runs; be cautious about running heavy BenchmarkDotNet workloads in CI. Prefer targeted runs or harnesses for CI where appropriate.
- Keep benchmark projects isolated (e.g., `tuning/*.csproj`) so they don't affect package builds or production artifacts.

## 7. Additional Guidelines

- Keep benchmarks readable and well-documented; add comments explaining non-obvious choices.
- If a benchmark exposes regressions or optimizations, add a short note in the benchmark file referencing the relevant issue or PR.
- For any shared helpers for benchmarking, prefer small utility classes inside the `tuning` projects rather than cross-cutting changes to production code.

For further examples, refer to the benchmark files under the `tuning/` folder.

---
description: 'Writing XML documentation'
applyTo: "**/*.cs"
---

# Writing XML Documentation
This document provides instructions for writing XML documentation.

## 1. Documentation Style

- Use the same documentation style as found throughout the codebase.
- Add XML doc comments to all public and protected classes, methods, properties, and constructors.
- Use `<summary>` for type and member descriptions.
- Use `<param>` for method parameters.
- Use `<returns>` for return values.
- Use `<typeparam>` for generic type parameters.
- Use `<remarks>` for additional context, especially default property values using `<list type="table">`.
- Use `<seealso cref="..."/>` to reference related types and interfaces.
- Use `<see cref="..."/>` inline to reference types, members, and parameters.
- Use `<exception cref="...">` to document thrown exceptions.

## 2. Example

```csharp
namespace YourProject
{
    /// <summary>
    /// Provides utility methods for processing data.
    /// </summary>
    /// <typeparam name="TOptions">The type of the configured options.</typeparam>
    /// <seealso cref="IConfigurable{TOptions}" />
    public class DataProcessor<TOptions> where TOptions : class, new()
    {
        /// <summary>
        /// Initializes a new instance of the <see cref="DataProcessor{TOptions}"/> class.
        /// </summary>
        /// <param name="setup">The <see cref="Action{TOptions}"/> which may be configured.</param>
        public DataProcessor(Action<TOptions> setup)
        {
            Options = setup != null ? Configure(setup) : new TOptions();
        }

        /// <summary>
        /// Gets the configured options of this instance.
        /// </summary>
        /// <value>The configured options of this instance.</value>
        public TOptions Options { get; }

        /// <summary>
        /// Processes the specified <paramref name="input"/> and returns the result.
        /// </summary>
        /// <param name="input">The input data to process.</param>
        /// <returns>A <see cref="string"/> containing the processed result.</returns>
        /// <exception cref="ArgumentNullException">
        /// <paramref name="input"/> is null.
        /// </exception>
        public string Process(string input)
        {
            if (input == null) throw new ArgumentNullException(nameof(input));
            return input.ToUpperInvariant();
        }
    }
}
```

## 3. Additional Guidelines

- Keep descriptions concise but informative.
- Use consistent phrasing: "Gets or sets", "Initializes a new instance of", "Provides", "Represents".
- Reference parameter names with `<paramref name="..."/>` in descriptions.
- For options/settings classes, document default values in `<remarks>` using a table format.
