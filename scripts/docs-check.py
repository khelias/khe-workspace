#!/usr/bin/env python3
"""Report where the estate's docs leave the standard in AGENTS.md "Code and docs".

Prints one line per problem and exits 1 if it printed any. Changes nothing:
each --meta line ends with the gh command that would fix it.

  python3 scripts/docs-check.py            links, orphans, READMEs, layout
  python3 scripts/docs-check.py --meta     also what GitHub shows (needs gh)
"""

from __future__ import annotations

import argparse
import json
import posixpath
import re
import shlex
import subprocess
import sys
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
from urllib.parse import unquote

ROOT_NAME = "khe-workspace"

# Public repos outside repos/repos.yaml, which --meta still checks.
EXTRA_META = [
    {
        "name": "khe-workspace",
        "url": "https://github.com/khelias/khe-workspace.git",
        "visibility": "public",
        "description": "The KHE workspace root: agent rules, hooks and the list of repos cloned under repos/",
        "homepage": "https://khe.ee/agents/",
        "topics": "ai-agents,claude-code,developer-tools,git-hooks,workspace",
    },
    {
        "name": "khelias",
        "url": "https://github.com/khelias/khelias.git",
        "visibility": "public",
        "description": "GitHub profile page",
        "homepage": "https://khe.ee",
        "topics": "",
    },
    {
        "name": ".github",
        "url": "https://github.com/khelias/.github.git",
        "visibility": "public",
        "description": "Default security policy, contributing note and code of conduct for khelias repos",
        "homepage": "",
        "topics": "",
    },
]

# The link text may hold one level of brackets, as an image inside a link does.
LINK_RE = re.compile(
    r"\]\(\s*(?:<([^>\n]*)>|([^)\s]+))(?:\s+(?:\"[^\"]*\"|'[^']*'|\([^)]*\)))?\s*\)"
)
REF_RE = re.compile(r"^\s{0,3}\[[^\]]+\]:\s*(?:<([^>]*)>|(\S+))")
CODE_SPAN_RE = re.compile(r"`+[^`]*`+")
# Any indent, since a fence inside a list item sits deeper than three spaces.
FENCE_RE = re.compile(r"^\s*(`{3,}|~{3,})\s*(\S*)")
LICENCE_FILES = ("LICENSE", "LICENSE.md", "LICENSE.txt", "LICENCE")


def read_manifest(path: Path) -> list[dict[str, str]]:
    """A line parser for the flat shape repos.yaml documents: one "- name:"
    per entry, key: value lines under it. Unlike workspace.sh, it keeps every key."""
    entries: list[dict[str, str]] = []
    for line in path.read_text(encoding="utf-8").splitlines():
        m = re.match(r"^\s*-\s+name:\s*(.*)$", line)
        if m:
            entries.append({"name": m.group(1).strip()})
            continue
        m = re.match(r"^\s+([a-z_]+):\s*(.*)$", line)
        if m and entries:
            value = m.group(2).strip()
            if len(value) > 1 and value[0] == value[-1] == '"':
                value = value[1:-1]
            entries[-1][m.group(1)] = value
    return entries


def tracked(repo: Path) -> list[str]:
    out = subprocess.run(
        ["git", "-C", str(repo), "ls-files", "-z"],
        capture_output=True, text=True, check=True,
    ).stdout
    return [f for f in out.split("\0") if f]


def link_targets(text: str) -> tuple[list[str], bool]:
    """Relative link targets outside code, and whether a Mermaid fence appears."""
    targets: list[str] = []
    mermaid = False
    fence = ""
    for line in text.splitlines():
        m = FENCE_RE.match(line)
        if m:
            if not fence:
                fence = m.group(1)
                mermaid = mermaid or m.group(2).lower() == "mermaid"
                continue
            # CommonMark: only a bare fence of the same character, at least as long, closes it.
            if m.group(1)[0] == fence[0] and len(m.group(1)) >= len(fence) and not m.group(2):
                fence = ""
                continue
        if fence:
            continue
        line = CODE_SPAN_RE.sub("", line)
        targets += [a or b for a, b in LINK_RE.findall(line)]
        m = REF_RE.match(line)
        if m:
            targets.append(m.group(1) or m.group(2))
    relative = [
        t for t in targets
        if not re.match(r"^[a-zA-Z][a-zA-Z0-9+.-]*:", t) and not t.startswith(("#", "//"))
    ]
    return relative, mermaid


def resolve(doc: str, target: str) -> str:
    """The target as a path from the repo root; it starts with ".." when it
    leaves the repo. Case is kept, since GitHub's paths are case-sensitive."""
    path = unquote(target.split("#", 1)[0].split("?", 1)[0])
    base = "" if path.startswith("/") else posixpath.dirname(doc)
    return posixpath.normpath(posixpath.join(base, path.lstrip("/")))


def check_repo(name: str, repo: Path, entry: dict[str, str]) -> list[str]:
    problems: list[str] = []
    files = tracked(repo)
    fork = bool(entry.get("upstream"))
    docs = [f for f in files if f.endswith(".md")]
    if name == "khe-meta":
        docs = [f for f in docs if not f.startswith("plans/")]

    known = set(files)
    dirs = {"/".join(f.split("/")[:i]) or "." for f in files for i in range(f.count("/") + 1)}
    linked: set[str] = set()
    for doc in docs:
        targets, mermaid = link_targets((repo / doc).read_text(encoding="utf-8", errors="replace"))
        if mermaid:
            problems.append(f"LAYOUT {name} {doc}: a Mermaid block; use a table, text or an SVG")
        for target in targets:
            path = resolve(doc, target)
            if path == ".." or path.startswith("../"):
                problems.append(f"LINK {name} {doc}: {target} leaves the repo; link it by URL")
            elif path in dirs:
                linked.update(f for f in docs if (posixpath.dirname(f) or ".") == path and f != doc)
            elif path not in known:
                problems.append(f"LINK {name} {doc}: {target} is not a file of the repo")
            elif path != doc:
                linked.add(path)

    if any(f.startswith("docs/adr/") for f in files):
        problems.append(f"LAYOUT {name} docs/adr/: decisions go in docs/decisions/")

    if not fork:
        for doc in docs:
            if doc.startswith("docs/") and doc not in linked:
                problems.append(f"ORPHAN {name} {doc}: no other doc links it")
        readme = repo / "README.md"
        text = readme.read_text(encoding="utf-8") if readme.exists() else ""
        if text.splitlines()[:1] != [f"# {name}"]:
            problems.append(f"README {name} README.md: line 1 is not '# {name}'")
        if entry.get("visibility") == "public":
            if not any((repo / f).exists() for f in LICENCE_FILES):
                problems.append(f"README {name}: a public repo without LICENSE")
            if text and not re.search(r"^## Licence\s*$", text, re.M):
                problems.append(f"README {name} README.md: no '## Licence' section")
    return problems


def gh_json(*args: str) -> object:
    try:
        out = subprocess.run(["gh", *args], capture_output=True, text=True)
    except OSError as err:
        raise RuntimeError(f"cannot run gh: {err}") from err
    if out.returncode != 0:
        raise RuntimeError(out.stderr.strip() or out.stdout.strip())
    return json.loads(out.stdout)


def slug(entry: dict[str, str]) -> str:
    m = re.search(r"github\.com[/:]([^/]+/[^/]+?)(?:\.git)?$", entry.get("url", ""))
    return m.group(1) if m else f"khelias/{entry['name']}"


def check_meta(entry: dict[str, str]) -> list[str]:
    name, repo = entry["name"], slug(entry)
    edit = f"gh repo edit {repo}"
    try:
        data = gh_json(
            "repo", "view", repo, "--json",
            "description,homepageUrl,repositoryTopics,hasWikiEnabled,hasProjectsEnabled,visibility",
        )
    except RuntimeError as err:
        return [f"META {name}: gh repo view failed: {err}"]
    problems: list[str] = []
    for key, field in (("description", "description"), ("homepage", "homepageUrl")):
        want = entry.get(key, "")
        if (data.get(field) or "") != want:
            problems.append(f"META {name}: {key} differs; {edit} --{key} {shlex.quote(want)}")
    have = {t["name"] for t in data.get("repositoryTopics") or []}
    want_topics = {t.strip() for t in entry.get("topics", "").split(",") if t.strip()}
    if have != want_topics:
        flags = [f"--add-topic {t}" for t in sorted(want_topics - have)]
        flags += [f"--remove-topic {t}" for t in sorted(have - want_topics)]
        problems.append(f"META {name}: topics differ; {edit} {' '.join(flags)}")
    for field, what, flag in (("hasWikiEnabled", "wiki is", "wiki"), ("hasProjectsEnabled", "projects are", "projects")):
        if data.get(field):
            problems.append(f"META {name}: {what} on; {edit} --enable-{flag}=false")
    visibility = (data.get("visibility") or "").lower()
    if visibility != entry.get("visibility", ""):
        problems.append(
            f"META {name}: GitHub says {visibility or 'nothing'}, repos.yaml says "
            f"{entry.get('visibility') or 'nothing'}; check ESTATE.md"
        )
    if visibility == "public":
        try:
            pvr = gh_json("api", f"repos/{repo}/private-vulnerability-reporting")
        except RuntimeError as err:
            pvr = {"enabled": True}
            problems.append(f"META {name}: private vulnerability reporting unreadable: {err}")
        if not pvr.get("enabled"):
            problems.append(
                f"META {name}: private vulnerability reporting is off; "
                f"gh api -X PUT repos/{repo}/private-vulnerability-reporting"
            )
    return problems


def clones_dir(root: Path) -> Path:
    """repos/ of this root, or of the main checkout when this is a worktree
    of the root, whose repos/ holds only repos.yaml."""
    if (root / ".git").is_dir():
        return root / "repos"
    common = subprocess.run(
        ["git", "-C", str(root), "rev-parse", "--path-format=absolute", "--git-common-dir"],
        capture_output=True, text=True, check=True,
    ).stdout.strip()
    return Path(common).parent / "repos"


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--meta", action="store_true", help="also compare what GitHub shows (needs gh)")
    parser.add_argument("--root", type=Path, default=Path(__file__).resolve().parent.parent)
    args = parser.parse_args(argv)

    root = args.root.resolve()
    entries = read_manifest(root / "repos" / "repos.yaml")
    clones = clones_dir(root)
    problems = check_repo(ROOT_NAME, root, {"visibility": "public"})
    for entry in entries:
        repo = clones / entry["name"]
        if not (repo / ".git").exists():
            problems.append(f"MISSING {entry['name']}: not cloned at {repo}")
            continue
        problems += check_repo(entry["name"], repo, entry)
    if args.meta:
        with ThreadPoolExecutor(max_workers=8) as pool:
            for lines in pool.map(check_meta, entries + EXTRA_META):
                problems += lines

    for line in problems:
        print(line)
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main())
