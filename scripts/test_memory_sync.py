#!/usr/bin/env python3
"""Tests for memory-sync.py: two local folders, with ssh replaced by a local
shell so the real listing and write scripts run."""

from __future__ import annotations

import contextlib
import fcntl
import importlib.util
import io
import json
import os
import stat
import subprocess
import sys
import tarfile
import tempfile
import time
import unittest
from pathlib import Path
from unittest import mock

spec = importlib.util.spec_from_file_location(
    "memory_sync", Path(__file__).resolve().parent / "memory-sync.py"
)
memory_sync = importlib.util.module_from_spec(spec)
sys.modules["memory_sync"] = memory_sync
spec.loader.exec_module(memory_sync)


class ShellRemote(memory_sync.RemoteSide):
    """Runs the remote scripts in a local folder instead of over ssh."""

    def __init__(self, home: Path) -> None:
        super().__init__(memory_sync.Deadline(60), "memory")
        self.home = home
        self.down = False
        self.exit_code: int | None = None
        self.cut_listing_to: int | None = None
        self.before_write = None
        self.fail_writes = False
        self.calls = 0

    def run(self, script: str, stdin: bytes) -> tuple[int, bytes]:
        self.calls += 1
        if self.down:
            raise memory_sync.Unreachable("down")
        writing = "mktemp" in script
        if writing and self.fail_writes:
            raise memory_sync.Unreachable("down")
        if writing and self.before_write:
            self.before_write()
        env = {**os.environ, "COPYFILE_DISABLE": "1"}
        done = subprocess.run(
            ["bash", "-c", script], cwd=self.home, input=stdin, capture_output=True, env=env, check=False
        )
        output = done.stdout
        if not writing and self.cut_listing_to is not None:
            output = output[: self.cut_listing_to]
        return (self.exit_code if self.exit_code is not None else done.returncode), output


class ChangingLocal(memory_sync.LocalSide):
    """Lets a test change a file between the listing and the write."""

    before_apply = None

    def apply(self, ops):
        if ops and self.before_apply:
            self.before_apply()
        return super().apply(ops)


class SyncCase(unittest.TestCase):
    def setUp(self) -> None:
        holder = tempfile.TemporaryDirectory()
        self.addCleanup(holder.cleanup)
        self.base = Path(holder.name)
        self.local_dir = self.base / "local"
        self.remote_dir = self.base / "home" / "memory"
        self.local_dir.mkdir()
        self.remote_dir.mkdir(parents=True)
        self.paths = memory_sync.Paths.under(self.base / "state")
        self.local = ChangingLocal(self.local_dir)
        self.remote = ShellRemote(self.base / "home")

    def put(self, folder: Path, name: str, text: str, age: int = 0) -> None:
        path = folder / name
        path.write_text(text)
        moment = int(time.time()) - age
        os.utime(path, (moment, moment))

    def run_sync(self, dry_run: bool = False) -> str:
        output = io.StringIO()
        with contextlib.redirect_stdout(output):
            code = memory_sync.sync(self.local, self.remote, self.paths, dry_run)
        self.assertEqual(code, 0)
        return output.getvalue()

    def names(self, folder: Path) -> list[str]:
        return sorted(path.name for path in folder.iterdir())

    def backups(self) -> list[Path]:
        return sorted(self.paths.backups.iterdir()) if self.paths.backups.exists() else []

    def in_step(self, **files: str) -> None:
        """Both sides hold these files and a sync has recorded them."""
        for name, text in files.items():
            self.put(self.local_dir, f"{name}.md", text, age=100)
            self.put(self.remote_dir, f"{name}.md", text, age=100)
        self.run_sync()


class CopyAndDelete(SyncCase):
    def test_new_files_cross_both_ways(self) -> None:
        self.put(self.local_dir, "ours.md", "from the laptop")
        self.put(self.remote_dir, "theirs.md", "from the vm")
        self.assertEqual(self.run_sync(), "memory sync: changed here from agent-vm: theirs.md\n")
        self.assertEqual((self.remote_dir / "ours.md").read_text(), "from the laptop")
        self.assertEqual((self.local_dir / "theirs.md").read_text(), "from the vm")

    def test_modification_time_survives_the_copy(self) -> None:
        self.put(self.local_dir, "ours.md", "x", age=5000)
        self.put(self.remote_dir, "theirs.md", "y", age=7000)
        self.run_sync()
        self.assertEqual(
            int((self.remote_dir / "ours.md").stat().st_mtime),
            int((self.local_dir / "ours.md").stat().st_mtime),
        )
        self.assertEqual(
            int((self.local_dir / "theirs.md").stat().st_mtime),
            int((self.remote_dir / "theirs.md").stat().st_mtime),
        )

    def test_change_on_one_side_is_copied(self) -> None:
        self.in_step(a="one", b="one")
        self.put(self.local_dir, "a.md", "laptop edit", age=500)
        self.put(self.remote_dir, "b.md", "vm edit", age=500)
        self.assertEqual(self.run_sync(), "memory sync: changed here from agent-vm: b.md\n")
        self.assertEqual((self.remote_dir / "a.md").read_text(), "laptop edit")
        self.assertEqual((self.local_dir / "b.md").read_text(), "vm edit")

    def test_older_copy_of_a_change_on_one_side_still_wins(self) -> None:
        self.in_step(a="one")
        self.put(self.remote_dir, "a.md", "one", age=0)
        self.put(self.local_dir, "a.md", "edit with an old clock", age=9000)
        self.run_sync()
        self.assertEqual((self.remote_dir / "a.md").read_text(), "edit with an old clock")

    def test_deletion_follows_both_ways(self) -> None:
        self.in_step(a="one", b="two", c="three")
        (self.local_dir / "a.md").unlink()
        (self.remote_dir / "b.md").unlink()
        self.run_sync()
        self.assertEqual(self.names(self.local_dir), ["c.md"])
        self.assertEqual(self.names(self.remote_dir), ["c.md"])

    def test_change_beats_a_deletion_both_ways(self) -> None:
        self.in_step(a="one", b="two")
        (self.local_dir / "a.md").unlink()
        self.put(self.remote_dir, "a.md", "vm kept editing")
        (self.remote_dir / "b.md").unlink()
        self.put(self.local_dir, "b.md", "laptop kept editing")
        self.run_sync()
        self.assertEqual((self.local_dir / "a.md").read_text(), "vm kept editing")
        self.assertEqual((self.remote_dir / "b.md").read_text(), "laptop kept editing")

    def test_second_run_does_nothing(self) -> None:
        self.put(self.local_dir, "a.md", "one")
        self.run_sync()
        count = len(self.backups())
        calls = self.remote.calls
        self.assertEqual(self.run_sync(), "")
        self.assertEqual(len(self.backups()), count)
        self.assertEqual(self.remote.calls, calls + 1)

    def test_only_flat_markdown_names_are_handled(self) -> None:
        self.put(self.remote_dir, "good-name_1.md", "yes")
        self.put(self.remote_dir, "has space.md", "no")
        self.put(self.remote_dir, "notes.txt", "no")
        (self.remote_dir / "sub").mkdir()
        self.put(self.remote_dir / "sub", "deep.md", "no")
        self.put(self.local_dir, "semi;colon.md", "no")
        self.run_sync()
        self.assertEqual(self.names(self.local_dir), ["good-name_1.md", "semi;colon.md"])
        self.assertEqual(
            self.names(self.remote_dir), ["good-name_1.md", "has space.md", "notes.txt", "sub"]
        )

    def test_no_temporary_files_are_left(self) -> None:
        self.put(self.local_dir, "ours.md", "x")
        self.put(self.remote_dir, "theirs.md", "y")
        self.run_sync()
        self.assertEqual(self.names(self.local_dir), ["ours.md", "theirs.md"])
        self.assertEqual(self.names(self.remote_dir), ["ours.md", "theirs.md"])
        self.assertEqual(self.names(self.base / "home"), ["memory"])


class Conflicts(SyncCase):
    def test_changed_on_both_goes_to_the_newer_and_names_it(self) -> None:
        self.in_step(a="one", b="two")
        self.put(self.local_dir, "a.md", "laptop newer", age=10)
        self.put(self.remote_dir, "a.md", "vm older", age=500)
        self.put(self.local_dir, "b.md", "laptop older", age=500)
        self.put(self.remote_dir, "b.md", "vm newer", age=10)
        output = self.run_sync()
        self.assertEqual((self.remote_dir / "a.md").read_text(), "laptop newer")
        self.assertEqual((self.local_dir / "b.md").read_text(), "vm newer")
        self.assertIn("a.md differed on both machines, kept the laptop copy", output)
        self.assertIn("b.md differed on both machines, kept the agent-vm copy", output)
        self.assertEqual(len(output.splitlines()), 3)
        self.assertIn("changed here from agent-vm: b.md", output)

    def test_no_earlier_hash_goes_to_the_newer(self) -> None:
        self.put(self.local_dir, "a.md", "laptop older", age=500)
        self.put(self.remote_dir, "a.md", "vm newer", age=10)
        output = self.run_sync()
        self.assertEqual((self.local_dir / "a.md").read_text(), "vm newer")
        self.assertIn("a.md", output)


class ChangedJustBeforeReplace(SyncCase):
    def test_remote_file_changed_after_the_listing_is_left(self) -> None:
        self.in_step(a="one")
        self.put(self.local_dir, "a.md", "laptop edit")
        self.remote.before_write = lambda: self.put(self.remote_dir, "a.md", "vm saved late")
        self.run_sync()
        self.assertEqual((self.remote_dir / "a.md").read_text(), "vm saved late")
        self.assertEqual((self.local_dir / "a.md").read_text(), "laptop edit")

        self.remote.before_write = None
        self.put(self.remote_dir, "a.md", "vm saved late", age=1000)
        output = self.run_sync()
        self.assertIn("a.md differed on both machines", output)
        self.assertEqual((self.remote_dir / "a.md").read_text(), "laptop edit")

    def test_local_file_changed_after_the_listing_is_left(self) -> None:
        self.in_step(a="one")
        self.put(self.remote_dir, "a.md", "vm edit")
        self.local.before_apply = lambda: self.put(self.local_dir, "a.md", "laptop saved late")
        self.run_sync()
        self.assertEqual((self.local_dir / "a.md").read_text(), "laptop saved late")
        self.assertEqual((self.remote_dir / "a.md").read_text(), "vm edit")

    def test_remote_deletion_is_left_when_the_vm_file_changed_late(self) -> None:
        self.in_step(a="one", b="two")
        (self.local_dir / "a.md").unlink()
        self.remote.before_write = lambda: self.put(self.remote_dir, "a.md", "vm saved late")
        self.run_sync()
        self.assertEqual((self.remote_dir / "a.md").read_text(), "vm saved late")

    def test_deletion_is_left_when_the_file_changed_late(self) -> None:
        self.in_step(a="one", b="two")
        (self.remote_dir / "a.md").unlink()
        self.local.before_apply = lambda: self.put(self.local_dir, "a.md", "laptop saved late")
        self.run_sync()
        self.assertEqual((self.local_dir / "a.md").read_text(), "laptop saved late")


class Index(SyncCase):
    def line(self, name: str, hook: str = "hook") -> str:
        return f"- [{name}]({name}.md) - {hook}"

    def test_merges_lines_and_drops_gone_files(self) -> None:
        self.in_step(kept="k", gone="g")
        (self.local_dir / "gone.md").unlink()
        (self.remote_dir / "gone.md").unlink()
        self.put(self.local_dir, "only-laptop.md", "l")
        self.put(self.remote_dir, "only-vm.md", "v")
        newer = "\n".join(["# Index", self.line("kept", "newer words"), self.line("gone"), self.line("only-laptop")])
        older = "\n".join([self.line("kept", "older words"), self.line("only-vm"), self.line("gone"), "stray text"])
        self.put(self.local_dir, "MEMORY.md", newer + "\n", age=10)
        self.put(self.remote_dir, "MEMORY.md", older + "\n", age=500)
        self.run_sync()
        expected = "\n".join(
            ["# Index", self.line("kept", "newer words"), self.line("only-laptop"), self.line("only-vm")]
        )
        self.assertEqual((self.local_dir / "MEMORY.md").read_text(), expected + "\n")
        self.assertEqual((self.remote_dir / "MEMORY.md").read_text(), expected + "\n")

    def test_line_of_a_file_deleted_in_this_run_goes(self) -> None:
        self.in_step(a="one", b="two")
        index = self.line("a") + "\n" + self.line("b") + "\n"
        self.put(self.local_dir, "MEMORY.md", index)
        self.put(self.remote_dir, "MEMORY.md", index)
        self.run_sync()
        (self.remote_dir / "a.md").unlink()
        self.run_sync()
        self.assertEqual((self.local_dir / "MEMORY.md").read_text(), self.line("b") + "\n")
        self.assertEqual((self.remote_dir / "MEMORY.md").read_text(), self.line("b") + "\n")

    def test_index_on_one_side_only_is_copied(self) -> None:
        self.in_step(a="one")
        self.put(self.remote_dir, "MEMORY.md", self.line("a") + "\n")
        self.run_sync()
        self.assertEqual((self.local_dir / "MEMORY.md").read_text(), self.line("a") + "\n")


class Backups(SyncCase):
    def test_both_sides_are_saved_before_a_write(self) -> None:
        self.in_step(a="original")
        self.put(self.remote_dir, "a.md", "vm edit")
        self.run_sync()
        latest = self.backups()[-1]
        self.assertEqual((latest / "laptop" / "a.md").read_text(), "original")
        self.assertEqual((latest / "agent-vm" / "a.md").read_text(), "vm edit")
        self.assertEqual(stat.S_IMODE(self.paths.backups.stat().st_mode), 0o700)
        self.assertEqual(stat.S_IMODE(latest.stat().st_mode), 0o700)

    def test_only_the_last_ten_are_kept(self) -> None:
        self.paths.backups.mkdir(parents=True)
        for number in range(12):
            (self.paths.backups / f"20000101T0000{number:02d}-1").mkdir()
        self.put(self.local_dir, "a.md", "one")
        self.run_sync()
        kept = self.backups()
        self.assertEqual(len(kept), 10)
        self.assertNotIn("20000101T000000-1", [path.name for path in kept])


class Limits(SyncCase):
    def test_more_than_five_deletions_stop_the_run(self) -> None:
        self.in_step(**{f"n{number}": "x" for number in range(14)})
        for number in range(6):
            (self.remote_dir / f"n{number}.md").unlink()
        self.put(self.local_dir, "new.md", "must not cross")
        output = self.run_sync()
        self.assertIn("would delete 6 files", output)
        self.assertEqual(len(output.splitlines()), 1)
        self.assertTrue((self.local_dir / "n0.md").exists())
        self.assertFalse((self.remote_dir / "new.md").exists())

    def test_five_deletions_go_through(self) -> None:
        self.in_step(**{f"n{number}": "x" for number in range(14)})
        for number in range(5):
            (self.remote_dir / f"n{number}.md").unlink()
        output = self.run_sync()
        self.assertEqual(output, "memory sync: changed here from agent-vm: n0.md, n1.md, n2.md, n3.md, n4.md\n")
        self.assertFalse((self.local_dir / "n0.md").exists())

    def test_an_oversized_note_stops_the_run_and_says_so(self) -> None:
        self.in_step(a="one")
        self.put(self.remote_dir, "huge.md", "x" * (memory_sync.MAX_NOTE_BYTES + 1))
        output = self.run_sync()
        self.assertIn("memory sync: stopped, huge.md on agent-vm is over 1 MB", output)
        self.assertFalse((self.local_dir / "huge.md").exists())

    def test_an_oversized_laptop_note_stops_the_run_and_says_so(self) -> None:
        self.in_step(a="one")
        self.put(self.local_dir, "huge.md", "x" * (memory_sync.MAX_NOTE_BYTES + 1))
        output = self.run_sync()
        self.assertIn("memory sync: stopped, huge.md on the laptop is over 1 MB", output)
        self.assertFalse((self.remote_dir / "huge.md").exists())

    def test_an_oversized_remote_folder_stops_the_run_and_says_so(self) -> None:
        self.in_step(a="one")
        self.put(self.remote_dir, "b.md", "two")
        with mock.patch.object(memory_sync, "MAX_ARCHIVE_BYTES", 4096):
            output = self.run_sync()
        self.assertIn("memory folder is over", output)
        self.assertFalse((self.local_dir / "b.md").exists())

    def test_a_laptop_with_under_half_of_the_files_stops_the_run(self) -> None:
        self.in_step(a="1", b="2", c="3", d="4", e="5")
        for name in "abc":
            (self.local_dir / f"{name}.md").unlink()
        output = self.run_sync()
        self.assertIn("laptop holds 2 files of the last sync's 5", output)
        self.assertTrue((self.remote_dir / "a.md").exists())

    def test_a_side_with_under_half_of_the_files_stops_the_run(self) -> None:
        self.in_step(a="1", b="2", c="3", d="4", e="5")
        for name in "abc":
            (self.remote_dir / f"{name}.md").unlink()
        output = self.run_sync()
        self.assertIn("agent-vm holds 2 files of the last sync's 5", output)
        self.assertTrue((self.local_dir / "a.md").exists())


class Unreachable(SyncCase):
    def assert_silent_and_untouched(self) -> None:
        before = self.paths.state.read_text()
        self.put(self.local_dir, "new.md", "stays here")
        self.assertEqual(self.run_sync(), "")
        self.assertEqual(self.paths.state.read_text(), before)
        self.assertFalse((self.remote_dir / "new.md").exists())
        self.assertEqual(self.backups(), [])

    def test_no_answer(self) -> None:
        self.in_step(a="one")
        self.remote.down = True
        self.assert_silent_and_untouched()

    def test_ssh_failure(self) -> None:
        self.in_step(a="one")
        self.remote.exit_code = 255
        self.assert_silent_and_untouched()

    def test_cut_off_listing(self) -> None:
        self.in_step(a="one", b="two")
        self.remote.cut_listing_to = 512
        self.assert_silent_and_untouched()

    def test_empty_listing(self) -> None:
        self.in_step(a="one")
        self.remote.cut_listing_to = 0
        self.assert_silent_and_untouched()

    def test_listing_with_a_failing_find_counts_as_unreachable(self) -> None:
        self.in_step(a="one", b="two")
        fake = self.base / "bin"
        fake.mkdir()
        (fake / "find").write_text("#!/bin/sh\nprintf './a.md\\0'\nexit 1\n")
        (fake / "find").chmod(0o755)
        with mock.patch.dict(os.environ, {"PATH": f"{fake}:{os.environ['PATH']}"}):
            self.assertEqual(self.run_sync(), "")
        self.assertTrue((self.local_dir / "b.md").exists())

    def test_remote_folder_gone_before_the_write_writes_nothing_elsewhere(self) -> None:
        self.in_step(a="one")
        self.put(self.local_dir, "new.md", "stays here")
        moved = self.base / "home" / "moved"
        self.remote.before_write = lambda: self.remote_dir.rename(moved)
        output = self.run_sync()
        self.assertIn("stopped answering", output)
        self.assertEqual(self.names(self.base / "home"), ["moved"])
        self.assertEqual(self.names(moved), ["a.md"])

    def test_a_sparse_member_fails_the_listing(self) -> None:
        archive = io.BytesIO()
        info = tarfile.TarInfo("a.md")
        info.type = tarfile.GNUTYPE_SPARSE
        info.size = 0
        with tarfile.open(fileobj=archive, mode="w", format=tarfile.GNU_FORMAT) as handle:
            handle.addfile(info, io.BytesIO(b""))
        with self.assertRaises(memory_sync.Refused):
            memory_sync.parse_archive(archive.getvalue())

    def test_timeout_counts_as_unreachable_and_uses_the_ssh_options(self) -> None:
        seen = []

        def slow(argv, **kwargs):
            seen.append((argv, kwargs["timeout"]))
            raise subprocess.TimeoutExpired(argv, kwargs["timeout"])

        remote = memory_sync.RemoteSide(memory_sync.Deadline(memory_sync.TOTAL_SECONDS))
        with mock.patch.object(memory_sync.subprocess, "run", side_effect=slow):
            with self.assertRaises(memory_sync.Unreachable):
                remote.read()
        argv, timeout = seen[0]
        self.assertEqual(argv[: len(memory_sync.SSH)], memory_sync.SSH)
        self.assertIn("BatchMode=yes", argv)
        self.assertEqual(argv[len(memory_sync.SSH)], memory_sync.REMOTE_HOST)
        self.assertLessEqual(timeout, memory_sync.TOTAL_SECONDS)

    def test_spent_deadline_counts_as_unreachable(self) -> None:
        with self.assertRaises(memory_sync.Unreachable):
            memory_sync.Deadline(0).remaining()

    def test_lost_during_the_write_keeps_the_state(self) -> None:
        self.in_step(a="one")
        before = self.paths.state.read_text()
        self.put(self.local_dir, "new.md", "crosses next time")
        self.remote.fail_writes = True
        output = self.run_sync()
        self.assertIn("stopped answering", output)
        self.assertEqual(self.paths.state.read_text(), before)
        self.remote.fail_writes = False
        self.run_sync()
        self.assertEqual((self.remote_dir / "new.md").read_text(), "crosses next time")


class Running(SyncCase):
    def test_dry_run_writes_nothing(self) -> None:
        self.put(self.local_dir, "ours.md", "x")
        self.put(self.remote_dir, "theirs.md", "y")
        self.put(self.local_dir, "both.md", "laptop copy")
        self.put(self.remote_dir, "both.md", "vm copy")
        output = self.run_sync(dry_run=True)
        self.assertIn("would copy to the agent-vm: ours.md", output)
        self.assertIn("would copy to the laptop: theirs.md", output)
        self.assertNotIn("kept the", output)
        self.assertEqual(self.names(self.local_dir), ["both.md", "ours.md"])
        self.assertEqual(self.names(self.remote_dir), ["both.md", "theirs.md"])
        self.assertFalse(self.paths.state.parent.exists())

    def test_second_run_at_the_same_time_leaves_at_once(self) -> None:
        self.paths.state.parent.mkdir(parents=True)
        self.put(self.local_dir, "ours.md", "x")
        with self.paths.lock.open("w") as held:
            fcntl.flock(held, fcntl.LOCK_EX)
            self.assertEqual(self.run_sync(), "")
        self.assertEqual(self.remote.calls, 0)
        self.assertFalse((self.remote_dir / "ours.md").exists())

    def test_state_records_the_hashes(self) -> None:
        self.put(self.local_dir, "a.md", "one")
        self.run_sync()
        files = json.loads(self.paths.state.read_text())["files"]
        self.assertEqual(files, {"a.md": memory_sync.digest_of(b"one")})


class LocalFolder(unittest.TestCase):
    def test_found_through_the_symlink_from_the_main_checkout(self) -> None:
        main = Path(__file__).resolve().parent.parent
        key = "".join(ch if ch.isalnum() else "-" for ch in str(main))
        with tempfile.TemporaryDirectory() as holder:
            base = Path(holder).resolve()
            real = base / "work" / "memory"
            real.mkdir(parents=True)
            project = base / "config" / "projects" / key
            project.mkdir(parents=True)
            (project / "memory").symlink_to(real)
            found = memory_sync.local_memory_folder(base / "config", memory_sync.Deadline(10))
        self.assertEqual(found, real)

    def test_missing_folder_is_none(self) -> None:
        with tempfile.TemporaryDirectory() as holder:
            self.assertIsNone(memory_sync.local_memory_folder(Path(holder), memory_sync.Deadline(10)))


class Gate(unittest.TestCase):
    def assert_no_connection(self, platform: str, config: str) -> None:
        with mock.patch.object(memory_sync.sys, "platform", platform), mock.patch.dict(
            os.environ, {"CLAUDE_CONFIG_DIR": config}
        ), mock.patch.object(memory_sync.subprocess, "run", side_effect=AssertionError("connected")):
            self.assertEqual(memory_sync.main([]), 0)

    def test_work_instance_never_connects(self) -> None:
        self.assert_no_connection("darwin", "/Users/someone/.claude")

    def test_unset_config_never_connects(self) -> None:
        self.assert_no_connection("darwin", "")

    def test_linux_never_connects(self) -> None:
        self.assert_no_connection("linux", "/home/khe/.claude-isiklik")


if __name__ == "__main__":
    unittest.main()
