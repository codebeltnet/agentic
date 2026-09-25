"""Read-only GitHub collection and deterministic release-note source verification."""

import argparse
import json
import re
import subprocess
from pathlib import Path
from urllib.parse import quote


def github(endpoint):
    result = subprocess.run(
        ["gh", "api", "--method", "GET", "--paginate", "--slurp", endpoint],
        capture_output=True, text=True, encoding="utf-8", timeout=120,
    )
    if result.returncode:
        raise RuntimeError(f"{endpoint}: {result.stderr.strip()}")
    pages = json.loads(result.stdout)
    if not isinstance(pages, list) or not pages:
        raise ValueError(f"Invalid page envelope: {endpoint}")
    return pages


def contributors(commits, opener=None):
    result = []
    seen = set()

    def add(value):
        if value.casefold() not in seen:
            seen.add(value.casefold())
            result.append(value)

    if opener:
        add("@" + opener)
    for commit in commits:
        login = (commit.get("author") or {}).get("login")
        add("@" + login if login else commit["commit"]["author"]["name"])
        # A trailer records authorship, but does not prove a GitHub account mapping.
        for name in re.findall(r"^Co-authored-by:\s*(.*?)\s*<[^>]+>\s*$",
                               commit["commit"]["message"], re.I | re.M):
            add(name)
    return result


def source(title, url, authors):
    credit = authors[0] if len(authors) == 1 else ", ".join(authors[:-1]) + " and " + authors[-1]
    return f"* {title.splitlines()[0]} by {credit} in {url}"


SUPPORTED_ALERT_START = re.compile(r"^> \[!(NOTE|TIP|IMPORTANT|WARNING|CAUTION)\]$")
ANY_ALERT_MARKER = re.compile(r"^> \[!([A-Z]+)\]")


def verify_summary(lines):
    errors = []
    source_index = lines.index("Sources:")
    section = lines[1:source_index]
    content_positions = [index for index, line in enumerate(section) if line.strip()]

    if not content_positions:
        return ["Missing release summary before Sources"]

    opening_index = content_positions[0]
    opening = section[opening_index]
    if not opening.startswith("This release "):
        if opening.startswith("**"):
            errors.append("Bold-leading prose paragraphs are not allowed; start with 'This release ' and use dash bullets for release highlights")
        else:
            errors.append("First non-empty summary line must begin with 'This release '")

    remaining = content_positions[1:]
    if not remaining:
        errors.append("Release summary must include at least one dash bullet after the opening paragraph")
        return errors

    first_after_opening = remaining[0]
    if section[first_after_opening].startswith("**"):
        errors.append("Bold-leading prose paragraphs are not allowed; use dash bullets for release highlights")
    if not section[first_after_opening].startswith("- "):
        errors.append("Opening summary paragraph must be followed by release-highlight bullets")

    bullets = []
    within_alert_block = False
    for line in section[first_after_opening:]:
        if not line.strip():
            continue
        if line.startswith("- "):
            if within_alert_block:
                errors.append("Release-highlight bullets must appear before any alert blocks")
            else:
                bullets.append(line.rstrip())
            continue

        if SUPPORTED_ALERT_START.fullmatch(line):
            within_alert_block = True
            continue

        if line.startswith(">"):
            marker = ANY_ALERT_MARKER.match(line)
            if within_alert_block:
                if marker:
                    errors.append("GitHub alert blocks must use only supported alert markers on standalone marker lines")
                continue
            if marker:
                errors.append("GitHub alert blocks must use only supported alert markers on standalone marker lines")
            else:
                errors.append("Plain blockquotes are not allowed after the release highlights; use supported GitHub alert blocks only")
            continue

        within_alert_block = False
        if line.startswith("**"):
            errors.append("Bold-leading prose paragraphs are not allowed; use dash bullets for release highlights")
        else:
            errors.append("Only release-highlight bullets and supported GitHub alert blocks may follow the opening paragraph")

    if not bullets:
        errors.append("At least one release-highlight bullet is required before Sources")
        return errors

    for bullet in bullets:
        if re.match(r"^- \*\*[^*]+\*\*\s*[:—-]", bullet):
            errors.append("Release-highlight bullets must continue naturally after the bold lead-in, not with label punctuation")
            break
        match = re.match(r"^- \*\*[^*]+\*\*\s+(.+)$", bullet)
        if not match:
            errors.append("Release-highlight bullets must use a bold lead-in followed by natural sentence prose")
            break
        if not re.search(r"[\w`]", match.group(1)):
            errors.append("Release-highlight bullets must include explanatory prose after the bold lead-in")
            break

    for bullet in bullets[:-1]:
        if not bullet.endswith(","):
            errors.append("Each non-final release-highlight bullet must end with a comma")
            break
    if not bullets[-1].endswith("."):
        errors.append("The final release-highlight bullet must end with a period")

    return errors


def collect(repository, previous, current, api=github):
    if not re.fullmatch(r"[\w.-]+/[\w.-]+", repository):
        raise ValueError("Repository must be owner/repo")
    root = f"repos/{repository}"
    evidence = {"repository": repository, "previous": previous, "current": current,
                "complete": False, "issues": [], "commits": [], "pull_requests": [],
                "files": [], "sources": [], "associations": {}}
    issues = evidence["issues"]

    def read(endpoint):
        try:
            return api(endpoint)
        except (RuntimeError, ValueError, OSError, subprocess.TimeoutExpired) as error:
            issues.append(str(error))
            return None

    # Resolve once so moving branches cannot change the range during collection.
    refs = []
    for ref in (previous, current):
        pages = read(f"{root}/commits/{quote(ref, safe='')}")
        if pages is None:
            return evidence
        refs.append(pages[0]["sha"])
    evidence["resolved_refs"] = refs
    pages = read(f"{root}/compare/{refs[0]}...{refs[1]}?per_page=100")
    if pages is None:
        return evidence
    commits = [commit for page in pages for commit in page["commits"]]
    evidence["commits"] = commits
    shas = {commit["sha"] for commit in commits}
    if len(commits) != pages[0]["total_commits"] or len(shas) != len(commits):
        issues.append("Comparison commit count mismatch or duplicate SHAs")
    evidence["files"] = pages[0]["files"]
    if len(evidence["files"]) >= 300:
        issues.append("Comparison files may be capped at 300; collect the final diff through another route")
    evidence["files_without_patch"] = [f["filename"] for f in evidence["files"] if "patch" not in f]
    details = {}
    covered = set()
    unresolved = set()
    source_order = {}
    deferred_review = {}
    deferred_fetch_failed = set()
    for position, commit in enumerate(commits):
        sha = commit["sha"]
        pages = read(f"{root}/commits/{sha}/pulls?per_page=100")
        if pages is None:
            unresolved.add(sha)
            evidence["associations"][sha] = None
            continue
        associated = [pr for page in pages for pr in page]
        evidence["associations"][sha] = [pr["number"] for pr in associated]
        pending_review = []
        pending_fetch_failed = False
        for candidate in sorted(associated, key=lambda pr: pr["number"]):
            number = candidate["number"]
            if number not in details:
                pages = read(f"{root}/pulls/{number}")
                details[number] = pages[0] if pages else None
            pr = details[number]
            if pr is None:
                pending_fetch_failed = True
                continue
            if not pr["merged_at"] or pr["base"]["repo"]["full_name"].casefold() != repository.casefold():
                continue
            if pr["merge_commit_sha"] not in shas:
                # Do not guess about rebase, partial, or later integration histories.
                # Defer: a later-merged PR outside the range is simply excluded when
                # another associated PR already covers this commit.
                pending_review.append(number)
                continue
            covered.add(sha)
            if any(item["number"] == number for item in evidence["pull_requests"]):
                continue
            commit_pages = read(f"{root}/pulls/{number}/commits?per_page=100")
            file_pages = read(f"{root}/pulls/{number}/files?per_page=100")
            original = [c for page in (commit_pages or []) for c in page]
            files = [f for page in (file_pages or []) for f in page]
            covered.update(c["sha"] for c in original if c["sha"] in shas)
            if len(original) != pr["commits"] or len({c["sha"] for c in original}) != len(original):
                issues.append(f"PR #{number}: expected {pr['commits']} commits, collected {len(original)}")
            if len(files) != pr["changed_files"] or len({f["filename"] for f in files}) != len(files):
                issues.append(f"PR #{number}: changed-file count mismatch")
            authors = contributors(original, pr["user"]["login"])
            evidence["pull_requests"].append({"number": number, "metadata": pr,
                "commits": original, "files": files, "contributors": authors})
            line = source(pr["title"], pr["html_url"], authors)
            evidence["sources"].append(line)
            source_order[line] = (position, number)
        # Defer reachability decisions until all commits are processed: a commit
        # covered directly or via another PR's original commits excludes any
        # later-merged outside-range association instead of failing the run.
        if pending_review:
            deferred_review.setdefault(sha, []).extend(pending_review)
        if pending_fetch_failed:
            deferred_fetch_failed.add(sha)
    for sha, numbers in deferred_review.items():
        if sha not in covered:
            for number in numbers:
                issues.append(f"Commit {sha}: PR #{number} integration needs reachability review")
            unresolved.add(sha)
    for sha in deferred_fetch_failed:
        if sha not in covered:
            unresolved.add(sha)
    for position, commit in enumerate(commits):
        if commit["sha"] not in covered | unresolved:
            line = source(commit["commit"]["message"], commit["html_url"], contributors([commit]))
            evidence["sources"].append(line)
            source_order[line] = (position, 0)
    evidence["sources"].sort(key=source_order.__getitem__)
    evidence["complete"] = not issues
    return evidence


def verify(evidence, draft):
    errors = []
    if not evidence["complete"]:
        errors.append("Evidence is incomplete: " + "; ".join(evidence["issues"]))
    lines = draft.strip().splitlines()
    if lines.count("Sources:") == 1:
        authored_lines = lines[:lines.index("Sources:")]
    else:
        authored_lines = lines
    if any("—" in line for line in authored_lines):
        errors.append("Unicode em dash is not allowed in authored release-note prose")
    if not lines or lines[0] != "## What's Changed":
        errors.append("Missing required opening heading")
    if lines.count("Sources:") != 1:
        errors.append("Expected exactly one Sources section")
    else:
        errors.extend(verify_summary(lines))
        actual = [line for line in lines[lines.index("Sources:") + 1:-1] if line.strip()]
        if actual != evidence["sources"]:
            errors.append("Sources must match collected source lines, including all contributors, exactly")
    expected = (f"**Full Changelog**: https://github.com/{evidence['repository']}/compare/"
                f"{evidence['previous']}...{evidence['current']}")
    if not lines or lines[-1] != expected:
        errors.append("Missing final changelog link or content follows it")
    return errors


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    gather = commands.add_parser("collect")
    gather.add_argument("repository")
    gather.add_argument("previous")
    gather.add_argument("current")
    gather.add_argument("--output", type=Path, required=True)
    check = commands.add_parser("verify")
    check.add_argument("evidence", type=Path)
    check.add_argument("draft", type=Path)
    args = parser.parse_args()
    if args.command == "collect":
        evidence = collect(args.repository, args.previous, args.current)
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(json.dumps(evidence, ensure_ascii=False, indent=2), encoding="utf-8")
        print(json.dumps({"complete": evidence["complete"], "issues": evidence["issues"],
                          "sources": evidence["sources"]}, ensure_ascii=False))
        return 0 if evidence["complete"] else 1
    errors = verify(json.loads(args.evidence.read_text(encoding="utf-8")), args.draft.read_text(encoding="utf-8"))
    print("\n".join(errors) if errors else "Release source verification passed")
    return 1 if errors else 0


if __name__ == "__main__":
    raise SystemExit(main())
