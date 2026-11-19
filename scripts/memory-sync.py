#!/usr/bin/env python3
"""Keep this workspace's auto memory the same on the laptop and agent-vm.

The laptop drives the sync over ssh, because agent-vm cannot reach the laptop.
A file changed on one side is copied to the other, a deletion follows unless
the other side changed the file, and a file changed on both sides goes to the
newer copy. Both sides are backed up before any write.
"""

from __future__ import annotations

import argparse
import fcntl
import hashlib
import io
import json
import os
import re
import shlex
import shutil
import subprocess
import sys
import tarfile
import tempfile
import time
from dataclasses import dataclass, field
from pathlib import Path

INDEX = "MEMORY.md"
NAME_RE = re.compile(r"[A-Za-z0-9_.-]+\.md")
LINK_RE = re.compile(r"\]\(([^)\s]+)\)")

REMOTE_HOST = "khe@agent-vm"
REMOTE_DIR = ".claude/projects/-home-khe-khe/memory"
SSH = [
    "ssh",
    "-o", "BatchMode=yes",
    "-o", "ConnectTimeout=3",
    "-o", "ServerAliveInterval=3",
    "-o", "ServerAliveCountMax=2",
]

TOTAL_SECONDS = 10
MAX_NOTE_BYTES = 1 << 20
MAX_ARCHIVE_BYTES = 32 << 20
MAX_DELETES = 5
BACKUPS_KEPT = 10
ABSENT = "absent"
SYMLINK = "symlink"

# pipefail: a find that fails partway would otherwise read as deleted notes.
READ_SCRIPT = "set -o pipefail; find . -maxdepth 1 -type f -name '*.md' -print0 | tar --null -T - -cf -"

# The expected hash is checked again here, so a note an agent-vm session saved
# after the listing is left for the next run instead of being overwritten.
WRITE_SCRIPT = r"""set -eu
tmp=$(mktemp -d ../.memory-sync.XXXXXX)
trap 'rm -rf -- "$tmp"' EXIT
tar -xf - -C "$tmp"
current() {
  if [ -L "$1" ]; then echo symlink
  elif [ -f "$1" ]; then sha256sum < "$1" | cut -d' ' -f1
  else echo absent
  fi
}
while read -r op name expected; do
  if [ "$(current "./$name")" = "$expected" ]; then
    if [ "$op" = put ]; then mv -f -- "$tmp/files/$name" "./$name"; else rm -f -- "./$name"; fi
    echo "done $name"
  fi
done < "$tmp/manifest"
"""


class Unreachable(Exception):
    """agent-vm did not answer, or its answer was not complete."""


class Refused(Exception):
    """A side holds something the sync will not carry; the operator is told."""


class Deadline:
    def __init__(self, seconds: float) -> None:
        self.ends = time.monotonic() + seconds

    def remaining(self) -> float:
        left = self.ends - time.monotonic()
        if left <= 0:
            raise Unreachable("out of time")
        return left


@dataclass(frozen=True)
class Note:
    data: bytes
    mtime: int
    digest: str


@dataclass(frozen=True)
class Op:
    kind: str  # "put" or "del"
    name: str
    expected: str  # the hash the target must still have when it is replaced
    note: Note | None = None


@dataclass
class Plan:
    to_local: list[Op] = field(default_factory=list)
    to_remote: list[Op] = field(default_factory=list)
    conflicts: list[str] = field(default_factory=list)
    settled: dict[str, str] = field(default_factory=dict)


@dataclass(frozen=True)
class Paths:
    state: Path
    lock: Path
    backups: Path

    @classmethod
    def under(cls, folder: Path) -> "Paths":
        return cls(
            folder / "memory-sync.json",
            folder / "memory-sync.lock",
            folder / "memory-backups",
        )


def digest_of(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def make_note(data: bytes, mtime: int) -> Note:
    return Note(data, mtime, digest_of(data))


def atomic_write(path: Path, data: bytes, mtime: int | None = None) -> None:
    handle, temporary = tempfile.mkstemp(dir=path.parent, prefix=".memory-sync-", suffix=".tmp")
    try:
        with os.fdopen(handle, "wb") as stream:
            stream.write(data)
        if mtime is not None:
            os.utime(temporary, (mtime, mtime))
        os.replace(temporary, path)
    except BaseException:
        Path(temporary).unlink(missing_ok=True)
        raise


def put_op(name: str, note: Note, current: Note | None) -> Op:
    return Op("put", name, current.digest if current else ABSENT, note)


class LocalSide:
    def __init__(self, folder: Path) -> None:
        self.folder = folder

    def read(self) -> dict[str, Note]:
        notes = {}
        for path in self.folder.iterdir():
            if NAME_RE.fullmatch(path.name) and path.is_file() and not path.is_symlink():
                if path.stat().st_size > MAX_NOTE_BYTES:
                    raise Refused(f"{path.name} on the laptop is over {MAX_NOTE_BYTES >> 20} MB")
                notes[path.name] = make_note(path.read_bytes(), int(path.stat().st_mtime))
        return notes

    def _current(self, path: Path) -> str:
        if path.is_symlink():
            return SYMLINK
        return digest_of(path.read_bytes()) if path.is_file() else ABSENT

    def apply(self, ops: list[Op]) -> set[str]:
        done = set()
        for op in ops:
            path = self.folder / op.name
            if self._current(path) != op.expected:
                continue
            if op.kind == "del":
                path.unlink(missing_ok=True)
            else:
                atomic_write(path, op.note.data, op.note.mtime)
            done.add(op.name)
        return done


class RemoteSide:
    def __init__(self, deadline: Deadline, directory: str = REMOTE_DIR) -> None:
        self.deadline = deadline
        self.directory = directory

    def run(self, script: str, stdin: bytes) -> tuple[int, bytes]:
        try:
            done = subprocess.run(
                [*SSH, REMOTE_HOST, script],
                input=stdin,
                capture_output=True,
                timeout=self.deadline.remaining(),
            )
        except (subprocess.TimeoutExpired, OSError) as error:
            raise Unreachable(str(error)) from error
        return done.returncode, done.stdout

    def _in_folder(self, script: str) -> str:
        return f"cd {shlex.quote(self.directory)} || exit 1\n{script}"

    def read(self) -> dict[str, Note]:
        code, raw = self.run(self._in_folder(READ_SCRIPT), b"")
        if code != 0:
            raise Unreachable(f"listing exited {code}")
        return parse_archive(raw)

    def apply(self, ops: list[Op]) -> set[str]:
        if not ops:
            return set()
        code, output = self.run(self._in_folder(WRITE_SCRIPT), build_archive(ops))
        if code != 0:
            raise Unreachable(f"write exited {code}")
        lines = output.decode("utf-8", "replace").splitlines()
        return {line.split(" ", 1)[1] for line in lines if line.startswith("done ")}


def parse_archive(raw: bytes) -> dict[str, Note]:
    # A tar ends in two zero blocks; without them the listing was cut short.
    if len(raw) < 1024 or len(raw) % 512 or raw[-1024:].strip(b"\0"):
        raise Unreachable("incomplete archive")
    # Too large stops the run rather than skipping a note: a skipped note would
    # read as deleted on agent-vm and be deleted here.
    if len(raw) > MAX_ARCHIVE_BYTES:
        raise Refused(f"agent-vm's memory folder is over {MAX_ARCHIVE_BYTES >> 20} MB")
    notes = {}
    try:
        with tarfile.open(fileobj=io.BytesIO(raw), mode="r:") as archive:
            for member in archive:
                name = member.name.removeprefix("./")
                if member.isreg() and NAME_RE.fullmatch(name):
                    if member.issparse() or member.size > MAX_NOTE_BYTES:
                        raise Refused(f"{name} on agent-vm is over {MAX_NOTE_BYTES >> 20} MB or sparse")
                    stream = archive.extractfile(member)
                    notes[name] = make_note(stream.read(), int(member.mtime))
    except (tarfile.TarError, OSError, EOFError) as error:
        raise Unreachable(str(error)) from error
    return notes


def build_archive(ops: list[Op]) -> bytes:
    buffer = io.BytesIO()

    def add(archive: tarfile.TarFile, name: str, data: bytes, mtime: int) -> None:
        info = tarfile.TarInfo(name)
        info.size = len(data)
        info.mtime = mtime
        info.mode = 0o600
        archive.addfile(info, io.BytesIO(data))

    with tarfile.open(fileobj=buffer, mode="w", format=tarfile.GNU_FORMAT) as archive:
        manifest = "".join(f"{op.kind} {op.name} {op.expected}\n" for op in ops)
        add(archive, "manifest", manifest.encode(), int(time.time()))
        for op in ops:
            if op.kind == "put":
                add(archive, f"files/{op.name}", op.note.data, op.note.mtime)
    return buffer.getvalue()


def reconcile(local: dict[str, Note], remote: dict[str, Note], last: dict[str, str]) -> Plan:
    plan = Plan()
    for name in sorted((set(local) | set(remote) | set(last)) - {INDEX}):
        ours, theirs, base = local.get(name), remote.get(name), last.get(name)
        if ours and theirs:
            if ours.digest == theirs.digest:
                plan.settled[name] = ours.digest
            elif base == theirs.digest:
                plan.to_remote.append(put_op(name, ours, theirs))
            elif base == ours.digest:
                plan.to_local.append(put_op(name, theirs, ours))
            elif ours.mtime >= theirs.mtime:
                plan.to_remote.append(put_op(name, ours, theirs))
                plan.conflicts.append(f"memory sync: {name} differed on both machines, kept the laptop copy")
            else:
                plan.to_local.append(put_op(name, theirs, ours))
                plan.conflicts.append(f"memory sync: {name} differed on both machines, kept the agent-vm copy")
        elif ours:
            if base == ours.digest:
                plan.to_local.append(Op("del", name, ours.digest))
            else:
                plan.to_remote.append(put_op(name, ours, None))
        elif theirs:
            if base == theirs.digest:
                plan.to_remote.append(Op("del", name, theirs.digest))
            else:
                plan.to_local.append(put_op(name, theirs, None))
    return plan


def refusal(local: dict[str, Note], remote: dict[str, Note], last: dict[str, str], plan: Plan) -> str | None:
    deletes = sum(op.kind == "del" for op in plan.to_local + plan.to_remote)
    if deletes > MAX_DELETES:
        return f"memory sync: stopped, this run would delete {deletes} files (limit {MAX_DELETES})"
    for label, notes in (("laptop", local), ("agent-vm", remote)):
        held = len(set(notes) - {INDEX})
        if held * 2 < len(last):
            return f"memory sync: stopped, the {label} holds {held} files of the last sync's {len(last)}"
    return None


def pointer(line: str) -> str | None:
    match = LINK_RE.search(line)
    if match and NAME_RE.fullmatch(match.group(1)):
        return match.group(1)
    return None


def merge_index(newer: str, older: str, existing: set[str]) -> str:
    kept: list[str] = []
    seen: set[str] = set()
    for line in newer.splitlines():
        target = pointer(line)
        if target is None or target in existing:
            kept.append(line)
            if target:
                seen.add(target)
    for line in older.splitlines():
        target = pointer(line)
        if target and target in existing and target not in seen:
            kept.append(line)
            seen.add(target)
    return "\n".join(kept) + "\n"


def index_ops(local: dict[str, Note], remote: dict[str, Note], existing: set[str]) -> tuple[list[Op], list[Op]]:
    ours, theirs = local.get(INDEX), remote.get(INDEX)
    if ours is None and theirs is None:
        return [], []
    if theirs is None or (ours is not None and ours.mtime >= theirs.mtime):
        newer, older = ours, theirs
    else:
        newer, older = theirs, ours
    merged = merge_index(
        newer.data.decode("utf-8", "surrogateescape"),
        older.data.decode("utf-8", "surrogateescape") if older else "",
        existing,
    )
    note = make_note(merged.encode("utf-8", "surrogateescape"), int(time.time()))

    def ops_for(current: Note | None) -> list[Op]:
        if current and current.digest == note.digest:
            return []
        return [put_op(INDEX, note, current)]

    return ops_for(ours), ops_for(theirs)


def load_state(path: Path) -> dict[str, str]:
    try:
        files = json.loads(path.read_text()).get("files", {})
    except (OSError, ValueError, AttributeError):
        return {}
    return files if isinstance(files, dict) else {}


def save_state(path: Path, files: dict[str, str]) -> None:
    atomic_write(path, json.dumps({"files": files}, indent=2, sort_keys=True).encode())


def save_backup(root: Path, local: dict[str, Note], remote: dict[str, Note]) -> None:
    root.mkdir(parents=True, exist_ok=True)
    root.chmod(0o700)
    target = Path(tempfile.mkdtemp(dir=root, prefix=f"{time.strftime('%Y%m%dT%H%M%S')}-"))
    for label, notes in (("laptop", local), ("agent-vm", remote)):
        folder = target / label
        folder.mkdir(mode=0o700)
        for name, note in notes.items():
            descriptor = os.open(folder / name, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
            with os.fdopen(descriptor, "wb") as stream:
                stream.write(note.data)
    for old in sorted(path for path in root.iterdir() if path.is_dir())[:-BACKUPS_KEPT]:
        shutil.rmtree(old)


def describe(side: str, ops: list[Op]) -> list[str]:
    verbs = {"put": "copy to", "del": "delete on"}
    return [f"memory sync: would {verbs[op.kind]} the {side}: {op.name}" for op in ops]


def sync(local_side: LocalSide, remote_side: RemoteSide, paths: Paths, dry_run: bool = False) -> int:
    if dry_run:
        return sync_sides(local_side, remote_side, paths, dry_run)
    paths.state.parent.mkdir(parents=True, exist_ok=True)
    paths.state.parent.chmod(0o700)
    with paths.lock.open("w") as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except OSError:
            return 0
        return sync_sides(local_side, remote_side, paths, dry_run)


def sync_sides(local_side: LocalSide, remote_side: RemoteSide, paths: Paths, dry_run: bool) -> int:
    try:
        remote = remote_side.read()
        local = local_side.read()
    except Unreachable:
        return 0
    except Refused as error:
        print(f"memory sync: stopped, {error}")
        return 0
    last = load_state(paths.state)
    plan = reconcile(local, remote, last)

    reason = refusal(local, remote, last, plan)
    if reason:
        print(reason)
        return 0

    known = (set(local) | set(remote)) - {INDEX}
    ops = plan.to_local + plan.to_remote
    deleted = {op.name for op in ops if op.kind == "del"}
    index_local, index_remote = index_ops(local, remote, known - deleted)
    if dry_run:
        for line in describe("laptop", plan.to_local + index_local) + describe("agent-vm", plan.to_remote + index_remote):
            print(line)
        return 0

    for line in plan.conflicts:
        print(line)
    if ops or index_local or index_remote:
        save_backup(paths.backups, local, remote)

    try:
        done_local = local_side.apply(plan.to_local)
        done = done_local | remote_side.apply(plan.to_remote)

        settled = dict(plan.settled)
        for op in ops:
            if op.name not in done:
                if op.name in last:
                    settled[op.name] = last[op.name]
            elif op.kind == "put":
                settled[op.name] = op.note.digest

        gone = {op.name for op in ops if op.kind == "del" and op.name in done}
        index_local, index_remote = index_ops(local, remote, known - gone)
        arrived = sorted(done_local | local_side.apply(index_local))
        remote_side.apply(index_remote)
    except Unreachable:
        print("memory sync: agent-vm stopped answering during the sync, the next session finishes it")
        return 0

    save_state(paths.state, settled)
    # agent-vm sessions write these notes and laptop sessions load them, so
    # the operator sees each one that crossed; names only, never the text.
    if arrived:
        print(f"memory sync: changed here from agent-vm: {', '.join(arrived)}")
    return 0


def local_memory_folder(config: Path, deadline: Deadline) -> Path | None:
    try:
        common = subprocess.run(
            ["git", "-C", str(Path(__file__).resolve().parent), "rev-parse",
             "--path-format=absolute", "--git-common-dir"],
            capture_output=True, text=True, timeout=deadline.remaining(), check=True,
        ).stdout.strip()
    except (subprocess.SubprocessError, OSError, Unreachable):
        return None
    key = re.sub(r"[^A-Za-z0-9]", "-", str(Path(common).parent))
    folder = (config / "projects" / key / "memory").resolve()
    return folder if folder.is_dir() else None


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--dry-run", action="store_true", help="print what would change and write nothing")
    args = parser.parse_args(argv)

    # The work instance shares this checkout and must never open this connection.
    config = os.environ.get("CLAUDE_CONFIG_DIR", "").rstrip("/")
    if sys.platform != "darwin" or not config.endswith(".claude-isiklik"):
        return 0

    deadline = Deadline(TOTAL_SECONDS)
    folder = local_memory_folder(Path(config), deadline)
    if folder is None:
        return 0
    paths = Paths.under(Path.home() / ".local" / "state" / "khe")
    return sync(LocalSide(folder), RemoteSide(deadline), paths, args.dry_run)


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception as error:  # a session start must never show a traceback
        print(f"memory sync: failed ({type(error).__name__})")
        sys.exit(0)
