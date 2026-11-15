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


def github_authors(repository, sha):
    """Resolve trailer identities through GitHub, never through name/email guesses."""
    owner, name = repository.split("/")
    query = """query($owner:String!, $name:String!, $sha:String!, $endCursor:String) {
      repository(owner:$owner, name:$name) { object(expression:$sha) { ... on Commit {
        authors(first:100, after:$endCursor) {
          totalCount nodes { name user { login } }
          pageInfo { hasNextPage endCursor }
        }
      } } }
    }"""
    result = subprocess.run(
        ["gh", "api", "graphql", "--paginate", "--slurp", "-f", "query=" + query,
         "-f", "owner=" + owner, "-f", "name=" + name, "-f", "sha=" + sha],
        capture_output=True, text=True, encoding="utf-8", timeout=120,
    )
    if result.returncode:
        raise RuntimeError(f"Commit {sha} authors: {result.stderr.strip()}")
    pages = json.loads(result.stdout)
    authors = []
    for page in pages:
        if page.get("errors"):
            raise ValueError(f"Commit {sha} authors: {page['errors']}")
        connection = page["data"]["repository"]["object"]["authors"]
        authors.extend(connection["nodes"])
    if not pages or connection["pageInfo"]["hasNextPage"] or len(authors) != connection["totalCount"]:
        raise ValueError(f"Commit {sha}: incomplete author inventory")
    accounts = {}
    for actor in authors:
        if actor.get("user"):
            login = actor["user"]["login"]
            if login.casefold() not in accounts:
                accounts[login.casefold()] = github("users/" + quote(login, safe=""))[0]
            actor["user"] = accounts[login.casefold()]
    return authors


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
        if "github_authors" in commit:
            for actor in commit["github_authors"]:
                user = actor.get("user") or {}
                add("@" + user["login"] if user.get("login") else actor["name"])
        else:
            # A trailer alone does not prove a GitHub account mapping.
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
    alert_has_content = False
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
            if within_alert_block and not alert_has_content:
                errors.append("GitHub alert blocks must be followed by at least one content line")
            within_alert_block = True
            alert_has_content = False
            continue

        if line.startswith(">"):
            marker = ANY_ALERT_MARKER.match(line)
            if within_alert_block:
                if marker:
                    errors.append("GitHub alert blocks must use only supported alert markers on standalone marker lines")
                elif line[1:].strip():
                    alert_has_content = True
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

    if within_alert_block and not alert_has_content:
        errors.append("GitHub alert blocks must be followed by at least one content line")

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


def check_generation_range(evidence, request, body):
    """Bind a saved generate-notes response to the exact repository and range being collected."""
    if not isinstance(request, dict):
        raise ValueError("Saved generation must record its request inputs")
    repository, previous, current = evidence["repository"], evidence["previous"], evidence["current"]
    if str(request.get("repository", "")).casefold() != repository.casefold():
        raise ValueError("Generation request repository does not match the collected repository")
    if request.get("previous_tag_name") != previous:
        raise ValueError("Generation request previous_tag_name does not match the collected previous ref")
    tag = request.get("tag_name")
    if not isinstance(tag, str) or not tag:
        raise ValueError("Generation request must name tag_name")
    target = request.get("target_commitish")
    if tag != current and (target is None or target not in (current, evidence["resolved_refs"][-1])):
        raise ValueError("Generation request tag_name or target_commitish does not match the collected current ref")
    link = f"commits/{tag}" if previous is None else f"compare/{previous}...{tag}"
    expected = f"**Full Changelog**: https://github.com/{repository}/{link}"
    changelog = [line.strip() for line in body.splitlines() if line.startswith("**Full Changelog**:")]
    if len(changelog) != 1 or changelog[0].casefold() != expected.casefold():
        raise ValueError("Generated notes do not describe the requested range: expected " + expected)


def add_new_contributors(evidence, generated_notes):
    """Validate generated first-contribution claims against in-range source identities."""
    evidence["generated_notes"] = generated_notes
    if not isinstance(generated_notes, dict):
        raise ValueError("Saved generation must be a request and response envelope")
    body = generated_notes["response"]["body"]
    if not isinstance(body, str):
        raise ValueError("Generated release notes body must be text")
    check_generation_range(evidence, generated_notes.get("request"), body)
    lines = body.splitlines()
    headings = [i for i, line in enumerate(lines) if line.strip() == "## New Contributors"]
    if len(headings) > 1:
        raise ValueError("Duplicate New Contributors sections in generated notes")
    result = []
    seen = set()
    if headings:
        for line in lines[headings[0] + 1:]:
            if line.startswith("## ") or line.startswith("**Full Changelog**:"):
                break
            if not line.strip():
                continue
            match = re.fullmatch(r"[*-] @([\w\[\]-]+) made their first contribution in (https://github\.com/[^\s]+/pull/\d+)\s*", line)
            if not match:
                raise ValueError("Unrecognized first-contribution entry: " + line)
            login, url = match.groups()
            item = next((item for item in evidence["pull_requests"]
                         if item["metadata"]["html_url"].casefold() == url.casefold()), None)
            identities = ([item["metadata"]["user"]] + list(commit_accounts(item.get("commits", [])))) if item else []
            account = next((user for user in identities if user["login"].casefold() == login.casefold()), None)
            if account is None:
                raise ValueError("First contribution is not a verified in-range PR by that author: " + line)
            if login.casefold() not in seen:
                seen.add(login.casefold())
                pr = item["metadata"]
                result.append(f"* **@{account['login']}** made their first contribution in [#{pr['number']}]({pr['html_url']}).")
    evidence["new_contributors"] = result


def commit_accounts(commits):
    for commit in commits:
        if commit.get("author"):
            yield commit["author"]
        for actor in commit.get("github_authors", []):
            if actor.get("user"):
                yield actor["user"]


def contribution_accounts(evidence):
    """Original PR authorship, plus direct commits; never merge-only attribution."""
    for item in evidence["pull_requests"]:
        pr = item["metadata"]
        for user in [pr["user"], *commit_accounts(item["commits"])]:
            yield user, f"[#{pr['number']}]({pr['html_url']})"
    for commit in evidence["direct_commits"]:
        for user in commit_accounts([commit]):
            yield user, f"[{commit['sha'][:7]}]({commit['html_url']})"


def supplement_new_contributors(evidence, api, author_api):
    candidates = {}
    for user, link in contribution_accounts(evidence):
        if user.get("type") == "User":
            candidates.setdefault(user["login"].casefold(), (user["login"], link))
    if not candidates:
        return
    previous_accounts = set()
    if evidence["previous"] is not None:
        # Expand prior squash PRs too: a compare-base commit author alone loses contributors.
        history = collect(evidence["repository"], None, evidence["resolved_refs"][0], api,
                          author_api=author_api, identify_new=False)
        evidence["contributor_history"] = history
        if not history["complete"]:
            raise ValueError("Prior contributor history is incomplete: " + "; ".join(history["issues"]))
        previous_accounts = {user["login"].casefold() for user, _ in contribution_accounts(history)}
    result = list(evidence.get("new_contributors", []))
    seen = {re.match(r"\* \*\*@([^*]+)\*\*", line).group(1).casefold() for line in result}
    if seen & previous_accounts:
        raise ValueError("Generated newcomer claims conflict with verified prior contributor history")
    for key, (login, link) in candidates.items():
        if key not in previous_accounts and key not in seen:
            result.append(f"* **@{login}** made their first contribution in {link}.")
            seen.add(key)
    evidence["new_contributors"] = result


def collect(repository, previous, current, api=github, generated_notes=None,
            author_api=github_authors, identify_new=True):
    if not re.fullmatch(r"[\w.-]+/[\w.-]+", repository):
        raise ValueError("Repository must be owner/repo")
    root = f"repos/{repository}"
    evidence = {"repository": repository, "previous": previous, "current": current,
                "complete": False, "issues": [], "commits": [], "pull_requests": [],
                "files": [], "sources": [], "associations": {}, "direct_commits": []}
    issues = evidence["issues"]

    def read(endpoint):
        try:
            return api(endpoint)
        except (RuntimeError, ValueError, OSError, subprocess.TimeoutExpired) as error:
            issues.append(str(error))
            return None

    author_cache = {}

    def enrich_authors(commits):
        for commit in commits:
            if not re.search(r"^Co-authored-by:", commit["commit"]["message"], re.I | re.M):
                continue
            sha = commit["sha"]
            if sha not in author_cache:
                try:
                    author_cache[sha] = author_api(repository, sha)
                except (RuntimeError, ValueError, OSError, KeyError, TypeError, subprocess.TimeoutExpired) as error:
                    issues.append(f"Commit {sha} co-author identities: {error}")
                    author_cache[sha] = None
            if author_cache[sha] is not None:
                commit["github_authors"] = author_cache[sha]

    # Resolve once so moving branches cannot change the range during collection.
    refs = []
    for ref in ((previous, current) if previous is not None else (current,)):
        pages = read(f"{root}/commits/{quote(ref, safe='')}")
        if pages is None:
            return evidence
        refs.append(pages[0]["sha"])
    evidence["resolved_refs"] = refs
    if previous is None:
        # Initial releases include the whole reachable history, oldest first.
        tree_sha = pages[0]["commit"]["tree"]["sha"]
        history = read(f"{root}/commits?sha={refs[0]}&per_page=100")
        tree = read(f"{root}/git/trees/{tree_sha}?recursive=1")
        if history is None or tree is None:
            return evidence
        commits = list(reversed([commit for page in history for commit in page]))
        evidence["files"] = [{"filename": item["path"], "status": "added"}
                             for item in tree[0]["tree"] if item["type"] in ("blob", "commit")]
        if tree[0].get("truncated"):
            issues.append("Initial release tree is truncated; collect the complete final tree through another route")
    else:
        pages = read(f"{root}/compare/{refs[0]}...{refs[1]}?per_page=100")
        if pages is None:
            return evidence
        commits = [commit for page in pages for commit in page["commits"]]
        if len(commits) != pages[0]["total_commits"]:
            issues.append("Comparison commit count mismatch")
        evidence["files"] = pages[0]["files"]
        if len(evidence["files"]) >= 300:
            issues.append("Comparison files may be capped at 300; collect the final diff through another route")
    evidence["commits"] = commits
    enrich_authors(commits)
    shas = {commit["sha"] for commit in commits}
    if previous is None and refs[0] not in shas:
        issues.append("Initial release history does not include the resolved current commit")
    if len(shas) != len(commits):
        issues.append("Duplicate commit SHAs")
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
            enrich_authors(original)
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
            evidence["direct_commits"].append(commit)
            line = source(commit["commit"]["message"], commit["html_url"], contributors([commit]))
            evidence["sources"].append(line)
            source_order[line] = (position, 0)
    evidence["sources"].sort(key=source_order.__getitem__)
    if generated_notes is not None:
        try:
            add_new_contributors(evidence, generated_notes)
        except (KeyError, TypeError, ValueError) as error:
            issues.append("New contributor evidence: " + str(error))
    if identify_new and not issues:
        try:
            supplement_new_contributors(evidence, api, author_api)
        except (KeyError, TypeError, ValueError) as error:
            issues.append("New contributor evidence: " + str(error))
    evidence["complete"] = not issues
    return evidence


def verify(evidence, draft):
    errors = []
    if not evidence["complete"]:
        errors.append("Evidence is incomplete: " + "; ".join(evidence["issues"]))
    lines = draft.strip().splitlines()
    if lines.count("Sources:") == 1:
        authored_lines = lines[:lines.index("Sources:")]
        if "## New Contributors" in lines:
            authored_lines += lines[lines.index("## New Contributors"):]
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
        tail = [line for line in lines[lines.index("Sources:") + 1:-1] if line.strip()]
        newcomers = evidence.get("new_contributors", [])
        expected_tail = evidence["sources"] + (["## New Contributors"] + newcomers if newcomers else [])
        actual = tail[:len(evidence["sources"])]
        if actual != evidence["sources"]:
            errors.append("Sources must match collected source lines, including all contributors, exactly")
        if tail != expected_tail:
            errors.append("Sources and verified New Contributors must appear exactly once in order before Full Changelog; omit empty or unverified contributor sections")
    target = (f"compare/{evidence['previous']}...{evidence['current']}" if evidence['previous'] is not None
              else f"commits/{evidence['current']}")
    expected = f"**Full Changelog**: https://github.com/{evidence['repository']}/{target}"
    if not lines or lines[-1] != expected:
        errors.append("Missing final changelog link or content follows it")
    return errors


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    gather = commands.add_parser("collect")
    gather.add_argument("repository")
    gather.add_argument("previous")
    gather.add_argument("current", nargs="?")
    gather.add_argument("--initial-release", action="store_true",
                        help="Collect all history: supply only repository and current ref, with no previous ref")
    gather.add_argument("--output", type=Path, required=True)
    gather.add_argument("--generated-notes", type=Path,
                        help="Saved {request, response} envelope from GitHub generate-notes for this exact range")
    check = commands.add_parser("verify")
    check.add_argument("evidence", type=Path)
    check.add_argument("draft", type=Path)
    args = parser.parse_args()
    if args.command == "collect":
        if args.initial_release:
            if args.current is not None:
                parser.error("--initial-release accepts only repository and current ref, without a previous ref")
            args.current, args.previous = args.previous, None
        elif args.current is None:
            parser.error("Supply previous and current refs, or use --initial-release")
        generated_notes = (json.loads(args.generated_notes.read_text(encoding="utf-8-sig"))
                           if args.generated_notes else None)
        evidence = collect(args.repository, args.previous, args.current, generated_notes=generated_notes)
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
