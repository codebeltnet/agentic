# Branch evidence

The requested scope is the full feature branch. Its merge-base with `main` is `a111111`, and `HEAD` is `b999999`. The working tree is clean. The feature branch is synchronized with `origin/feature/worker-maintenance`. The configured Git user is Alice. The following is the complete cumulative diff, with no omitted text hunks.

## History

```text
b222222 Alice <alice@example.test> handle worker cancellation
b333333 Bob <bob@example.test> redact access tokens
b444444 Alice <alice@example.test> correct setup instructions
b555555 Bob <bob@example.test> test on Windows
b666666 dependency-bot <bot@example.test> update Newtonsoft.Json
b777777 Bob <bob@example.test> remove obsolete configuration
b888888 Alice <alice@example.test> correct release date
b999998 Bob <bob@example.test> replace logo
b999999 Bob <bob@example.test> make check script executable
```

## Name-status inventory

```text
M src/Worker.cs
M docs/setup.md
M .github/workflows/test.yml
M Directory.Packages.props
D legacy.conf
M CHANGELOG.md
M assets/logo.png
M scripts/check.sh
```

## Cumulative diff

```diff
diff --git a/src/Worker.cs b/src/Worker.cs
--- a/src/Worker.cs
+++ b/src/Worker.cs
@@ -10,1 +10,1 @@
-await client.SendAsync(request, CancellationToken.None);
+await client.SendAsync(request, cancellationToken);
@@ -30,1 +30,1 @@
-logger.LogDebug("Access token: {Token}", accessToken);
+logger.LogDebug("Access token: [REDACTED]");
diff --git a/docs/setup.md b/docs/setup.md
--- a/docs/setup.md
+++ b/docs/setup.md
@@ -4,1 +4,1 @@
-Run `dontet restore` before building.
+Run `dotnet restore` before building.
diff --git a/.github/workflows/test.yml b/.github/workflows/test.yml
--- a/.github/workflows/test.yml
+++ b/.github/workflows/test.yml
@@ -2,1 +2,6 @@
 jobs:
+  windows:
+    runs-on: windows-latest
+    steps:
+      - uses: actions/checkout@v4
+      - run: dotnet test
diff --git a/Directory.Packages.props b/Directory.Packages.props
--- a/Directory.Packages.props
+++ b/Directory.Packages.props
@@ -3,1 +3,1 @@
-    <PackageVersion Include="Newtonsoft.Json" Version="13.0.2" />
+    <PackageVersion Include="Newtonsoft.Json" Version="13.0.3" />
diff --git a/legacy.conf b/legacy.conf
deleted file mode 100644
--- a/legacy.conf
+++ /dev/null
@@ -1,1 +0,0 @@
-legacy_transport=enabled
diff --git a/CHANGELOG.md b/CHANGELOG.md
--- a/CHANGELOG.md
+++ b/CHANGELOG.md
@@ -3,1 +3,1 @@
-## [1.2.0] - 2026-08-31
+## [1.2.0] - 2026-09-01
diff --git a/assets/logo.png b/assets/logo.png
index 1111111..2222222 100644
Binary files a/assets/logo.png and b/assets/logo.png differ
diff --git a/scripts/check.sh b/scripts/check.sh
old mode 100644
new mode 100755
```
