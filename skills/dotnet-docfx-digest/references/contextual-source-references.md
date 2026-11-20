# Contextual source references

Make the example sufficient for learning, and the references valuable for mastering. A reader should understand the developer task, essential API usage, dependencies and expected result without leaving the page. Keep feasible copy/run/adapt paths complete under the existing [one-shot execution contract](one-shot-examples.md).

## Select references during existing discovery

Reuse the package-ID-first discovery, tests, READMEs, consumer examples and implementation already inspected for the example. When one contributes evidence, consider whether it also teaches useful additional context. Record the selected URL, inspected source/revision, API relationship and added learning value briefly in the existing inventory evidence cell. An explicit decision that no reference adds value is sufficient for a simple API. Do not add a repository search subsystem, network checks to the fast validator, or a link quota.

Prefer direct files or focused directories showing actual usage: maintained applications, composition roots, functional/integration tests, configuration variants, package READMEs and conceptual tutorials. Implementation internals can clarify lifecycle, but prioritize how a consumer uses the API. A repository homepage, unrelated passing test, or arbitrary nearby file is not useful merely because it exists.

Before adding a link, open its target, inspect the content, and confirm the claimed relationship to this API. Verify file paths, test names, project references and any configuration/lifecycle claims. If a new target cannot be verified, omit that proposed reference or report the unresolved evidence; do not invent a replacement. Preserve existing valid links and `Related:` sections. Under the historical-link policy, only a directly verified HTTP 404 justifies removing or replacing an existing URL; timeouts, authentication failures, rate limits and unconfirmed lookup failures do not.

Use commit/release-pinned links for reproducible source and execution evidence. Maintained branch links are suitable for ongoing exploration. When both appear, explain which revision the runnable command verifies and that branch content can evolve; a branch link is not evidence that today's source was executed. Avoid duplicate destinations or repeated material unless the distinct revision or learning purpose matters.

## Write for progressive learning

Use the logical sequence **Purpose → Example → Outcome → Execution → Further exploration**. These are content roles, not five mandatory headings. Keep the concise explanation and meaningful C# first, state the observation and reproduction path, then offer optional depth in a short paragraph or small `Further exploration` section. Long execution blocks may remain in the existing immediately linked conceptual page or disclosure; source browsing is never a prerequisite for a working one-shot path.

Explain what each reference adds, in its link text or adjacent sentence: omitted application setup, integration with a larger workflow, extra configuration, lifecycle ownership or verification technique. Replace “See GitHub for more information” with a specific reason to follow the link. Keep descriptions brief and factual, with no promotional language.

- **Simple API:** a meaningful conversion or parsing example may need only purpose, C# and its result. Do not attach unrelated hosting or repository links.
- **Runnable integration:** retain its complete reproduction path and optionally link the composition root and functional test to show registration ownership or broader configuration. Successful execution does not make further reading redundant.
- **Non-standalone illustration:** state exactly what setup is omitted, where the code belongs, prerequisites and unverified behavior. Link the maintained implementation/test/project with a reason for each. Do not use this fallback when faithful standalone or repository-backed one-shot execution is available. Source-bound compilation and existing diagnostic gates still apply.

## Principal example: ManagedApplicationFixture

Explain on the page that `ManagedApplicationFixture<TEntryPoint>` lets an xUnit fixture exercise the application's real entry point, with startup and service registration owned by that application. Preserve the meaningful `ApplicationTest` test, fixture injection, assertions and separate application/test assemblies. The [existing worker example and one-shot blocks](one-shot-examples.md) supply the concise usage, expected marker/environment/lifetime observations and complete reproduction without manual project assembly.

After that example's outcome and execution guidance, optional exploration can read:

> To see the application setup behind this test, explore the maintained [minimal worker entry point](https://github.com/codebeltnet/xunit/blob/main/app/Codebelt.Extensions.Xunit.Hosting.BootstrapperMinimalWorker.App/Program.cs): it constructs the host, registers the marker and hosted service, and runs the application. The corresponding [worker functional test](https://github.com/codebeltnet/xunit/blob/main/test/Codebelt.Extensions.Xunit.Hosting.FunctionalTests/BootstrapperMinimalWorkerApplicationTestTest.cs) shows how `ApplicationTest` and `ManagedApplicationFixture` resolve that application-owned marker and verify its value, the Development environment and host lifetime service. The [functional test project](https://github.com/codebeltnet/xunit/blob/main/test/Codebelt.Extensions.Xunit.Hosting.FunctionalTests/Codebelt.Extensions.Xunit.Hosting.FunctionalTests.csproj) shows the application/library project references and declared target frameworks; inspect its shared build settings for inherited runner and dependency configuration.

These maintained branch links support exploration; the one-shot blocks and their evidence retain their exact pinned commit. Reinspect the branch targets before reusing this paragraph so its claims remain accurate. This is guidance for authoring the upstream page, not a claim that the published page has been changed.

## Review boundary

Human editorial review establishes whether a reference teaches useful depth and whether its explanation is accurate. Deterministic regressions can check exact destinations in curated fixtures, local source bindings, preserved links, C# structure, compilation and unchanged completion behavior. They must not infer educational value from word counts or keywords, crawl GitHub during fast validation, or treat a link as proof of execution.
