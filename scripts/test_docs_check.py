#!/usr/bin/env python3
"""Tests for docs-check.py on a made-up workspace of git repos."""

from __future__ import annotations

import contextlib
import importlib.util
import io
import json
import subprocess
import sys
import tempfile
import textwrap
import unittest
from pathlib import Path
from unittest import mock

spec = importlib.util.spec_from_file_location(
    "docs_check", Path(__file__).resolve().parent / "docs-check.py"
)
docs_check = importlib.util.module_from_spec(spec)
sys.modules["docs_check"] = docs_check
spec.loader.exec_module(docs_check)

GOOD_README = "# {name}\n\nWhat it is.\n\n## Licence\n\nMIT, see [LICENSE](LICENSE).\n"


class Workspace:
    def __init__(self, base: Path) -> None:
        self.root = base / "ws"
        (self.root / "repos").mkdir(parents=True)
        self.manifest: list[str] = ["repos:"]
        self.repo("", {"README.md": GOOD_README.format(name="khe-workspace"), "LICENSE": "x"}, root=True)

    def repo(self, name: str, files: dict[str, str], root: bool = False, **keys: str) -> Path:
        path = self.root if root else self.root / "repos" / name
        path.mkdir(parents=True, exist_ok=True)
        for rel, text in files.items():
            (path / rel).parent.mkdir(parents=True, exist_ok=True)
            (path / rel).write_text(textwrap.dedent(text), encoding="utf-8")
        if not (path / ".git").exists():
            subprocess.run(["git", "init", "-q", str(path)], check=True)
        subprocess.run(["git", "-C", str(path), "add", "-A"], check=True)
        if not root:
            self.manifest.append(f"  - name: {name}")
            self.manifest.append(f"    url: https://github.com/khelias/{name}.git")
            self.manifest += [f"    {k}: {v}" for k, v in keys.items()]
        return path

    def run(self, *args: str) -> tuple[int, list[str]]:
        (self.root / "repos" / "repos.yaml").write_text("\n".join(self.manifest) + "\n")
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            code = docs_check.main(["--root", str(self.root), *args])
        return code, out.getvalue().splitlines()


class DocsCheckTest(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self.ws = Workspace(Path(self.tmp.name))

    def tearDown(self) -> None:
        self.tmp.cleanup()

    def good(self, name: str = "app", **extra: str) -> dict[str, str]:
        return {"README.md": GOOD_README.format(name=name), "LICENSE": "MIT", **extra}

    def test_clean_workspace_prints_nothing(self) -> None:
        self.ws.repo("app", self.good(**{
            "README.md": GOOD_README.format(name="app") + "See [the guide](docs/guide.md).\n",
            "docs/guide.md": "# Guide\n",
        }), visibility="public")
        self.assertEqual(self.ws.run(), (0, []))

    def test_missing_link_is_reported_but_not_inside_code(self) -> None:
        self.ws.repo("app", self.good(**{
            "AGENTS.md": """\
                [gone](docs/gone.md) and `[skip](nope.md)`
                [ok](README.md#licence) [web](https://example.com) [anchor](#x)
                ```
                [fenced](nope.md)
                ```
                [ref]: missing-ref.md
                """,
        }), visibility="public")
        code, lines = self.ws.run()
        self.assertEqual(code, 1)
        self.assertEqual(lines, [
            "LINK app AGENTS.md: docs/gone.md is not a file of the repo",
            "LINK app AGENTS.md: missing-ref.md is not a file of the repo",
        ])

    def test_link_with_spaces_and_root_path(self) -> None:
        self.ws.repo("app", self.good(**{
            "docs/a b.md": "x\n",
            "AGENTS.md": "[a](docs/a%20b.md) [b](</docs/a b.md>)\n",
        }), visibility="public")
        self.assertEqual(self.ws.run(), (0, []))

    def test_broken_links_in_every_link_form(self) -> None:
        self.ws.repo("app", self.good(**{
            "docs/s.png": "x",
            "AGENTS.md": """\
                [a](</docs/gone file.md>) [b](gone-b.md 'Title') [c](gone-c.md (Title))
                [![s](docs/s.png)](gone-d.md)
                """,
        }), visibility="public")
        self.assertEqual(self.ws.run()[1], [
            "LINK app AGENTS.md: /docs/gone file.md is not a file of the repo",
            "LINK app AGENTS.md: gone-b.md is not a file of the repo",
            "LINK app AGENTS.md: gone-c.md is not a file of the repo",
            "LINK app AGENTS.md: gone-d.md is not a file of the repo",
        ])

    def test_link_must_be_a_tracked_file_inside_the_repo(self) -> None:
        path = self.ws.repo("app", self.good(**{
            "docs/Guide.md": "x\n",
            "AGENTS.md": "[a](docs/guide.md) [b](notes.md) [c](../other/README.md) [d](docs/Guide.md)\n",
        }), visibility="public")
        (path / "notes.md").write_text("untracked\n")
        self.assertEqual(self.ws.run()[1], [
            "LINK app AGENTS.md: docs/guide.md is not a file of the repo",
            "LINK app AGENTS.md: notes.md is not a file of the repo",
            "LINK app AGENTS.md: ../other/README.md leaves the repo; link it by URL",
        ])

    def test_long_and_indented_fences(self) -> None:
        self.ws.repo("app", self.good(**{
            "AGENTS.md": """\
                ````
                ```
                [in](gone.md)
                ```
                ````
                - item

                    ```mermaid
                    graph TD
                    ```
                """,
        }), visibility="public")
        self.assertEqual(self.ws.run()[1], [
            "LAYOUT app AGENTS.md: a Mermaid block; use a table, text or an SVG",
        ])

    def test_orphan_doc_and_folder_link(self) -> None:
        self.ws.repo("app", self.good(**{
            "docs/lonely.md": "x\n",
            "docs/decisions/001-a.md": "x\n",
            "AGENTS.md": "[decisions](docs/decisions/)\n",
        }), visibility="public")
        self.assertEqual(self.ws.run()[1], ["ORPHAN app docs/lonely.md: no other doc links it"])

    def test_a_doc_linking_itself_is_still_an_orphan(self) -> None:
        self.ws.repo("app", self.good(**{"docs/self.md": "[me](self.md)\n"}), visibility="public")
        self.assertEqual(self.ws.run()[1], ["ORPHAN app docs/self.md: no other doc links it"])

    def test_readme_title_and_public_licence(self) -> None:
        self.ws.repo("pub", {"README.md": "# Product\n"}, visibility="public")
        self.ws.repo("priv", {"README.md": "# priv\n"}, visibility="private")
        self.assertEqual(self.ws.run()[1], [
            "README pub README.md: line 1 is not '# pub'",
            "README pub: a public repo without LICENSE",
            "README pub README.md: no '## Licence' section",
        ])

    def test_fork_is_skipped_by_readme_and_orphan_rules(self) -> None:
        self.ws.repo("fork", {"README.md": "# Upstream name\n", "docs/x.md": "x\n"},
                     visibility="public", upstream="https://github.com/other/fork.git")
        self.assertEqual(self.ws.run(), (0, []))

    def test_layout_adr_folder_and_mermaid(self) -> None:
        self.ws.repo("app", self.good(**{
            "docs/adr/001-a.md": "```mermaid\ngraph TD\n```\n",
            "AGENTS.md": "[a](docs/adr/001-a.md)\n",
        }), visibility="public")
        self.assertEqual(self.ws.run()[1], [
            "LAYOUT app docs/adr/001-a.md: a Mermaid block; use a table, text or an SVG",
            "LAYOUT app docs/adr/: decisions go in docs/decisions/",
        ])

    def test_khe_meta_plans_are_left_out(self) -> None:
        self.ws.repo("khe-meta", {"README.md": "# khe-meta\n", "plans/p.md": "[x](gone.md)\n"},
                     visibility="private")
        self.assertEqual(self.ws.run(), (0, []))

    def test_untracked_files_are_left_out(self) -> None:
        path = self.ws.repo("app", self.good(), visibility="public")
        (path / "notes.md").write_text("[x](gone.md)\n")
        self.assertEqual(self.ws.run(), (0, []))

    def test_manifest_reads_one_line_keys_with_colons(self) -> None:
        manifest = Path(self.tmp.name) / "m.yaml"
        manifest.write_text(
            "repos:\n  - name: a\n    check: x: y\n    topics: one,two\n"
            '  - name: b\n    description: "Quoted: with a colon"\n'
        )
        self.assertEqual(docs_check.read_manifest(manifest), [
            {"name": "a", "check": "x: y", "topics": "one,two"},
            {"name": "b", "description": "Quoted: with a colon"},
        ])


class MetaTest(unittest.TestCase):
    VIEW = {"description": "An app", "homepageUrl": "https://khe.ee",
            "repositoryTopics": [{"name": "a"}, {"name": "b"}],
            "hasWikiEnabled": False, "hasProjectsEnabled": False, "visibility": "PUBLIC"}
    ENTRY = {
        "name": "app", "url": "https://github.com/khelias/app.git", "visibility": "public",
        "description": "An app", "homepage": "https://khe.ee", "topics": "a,b",
    }

    def fake_gh(self, view: dict, pvr: dict | None = None):
        def run(cmd, **_):
            body = view if cmd[1] == "repo" else (pvr or {"enabled": True})
            return subprocess.CompletedProcess(cmd, 0, json.dumps(body), "")
        return mock.patch.object(docs_check.subprocess, "run", side_effect=run)

    def test_matching_repo_prints_nothing(self) -> None:
        with self.fake_gh(self.VIEW):
            self.assertEqual(docs_check.check_meta(self.ENTRY), [])

    def test_every_difference_has_its_fix(self) -> None:
        view = {"description": "Old", "homepageUrl": None, "repositoryTopics": [{"name": "c"}],
                "hasWikiEnabled": True, "hasProjectsEnabled": True, "visibility": "PUBLIC"}
        with self.fake_gh(view, {"enabled": False}):
            lines = docs_check.check_meta(self.ENTRY)
        self.assertEqual(lines, [
            "META app: description differs; gh repo edit khelias/app --description 'An app'",
            "META app: homepage differs; gh repo edit khelias/app --homepage https://khe.ee",
            "META app: topics differ; gh repo edit khelias/app --add-topic a --add-topic b --remove-topic c",
            "META app: wiki is on; gh repo edit khelias/app --enable-wiki=false",
            "META app: projects are on; gh repo edit khelias/app --enable-projects=false",
            "META app: private vulnerability reporting is off; "
            "gh api -X PUT repos/khelias/app/private-vulnerability-reporting",
        ])

    def test_private_repo_skips_vulnerability_reporting(self) -> None:
        entry = {**self.ENTRY, "visibility": "private"}
        with self.fake_gh({**self.VIEW, "visibility": "PRIVATE"}, {"enabled": False}):
            self.assertEqual(docs_check.check_meta(entry), [])

    def test_missing_gh_is_a_line_not_a_crash(self) -> None:
        with mock.patch.object(docs_check.subprocess, "run", side_effect=FileNotFoundError("gh")):
            lines = docs_check.check_meta(self.ENTRY)
        self.assertEqual(len(lines), 1)
        self.assertTrue(lines[0].startswith("META app: gh repo view failed: cannot run gh"))

    def test_visibility_mismatch_is_reported(self) -> None:
        entry = {**self.ENTRY, "visibility": "private"}
        with self.fake_gh(self.VIEW):
            self.assertEqual(docs_check.check_meta(entry), [
                "META app: GitHub says public, repos.yaml says private; check ESTATE.md",
            ])


if __name__ == "__main__":
    unittest.main()
