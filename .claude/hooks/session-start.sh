#!/bin/bash
# SessionStart: bring the repos and the memory up to date, then say what needs
# a look and which plans are running. Never blocks a session: always exits 0.

deadline_seconds=15

common="$(git -C "${CLAUDE_PROJECT_DIR:-$PWD}" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" || exit 0
main="$(dirname "$common")"
[ -x "$main/scripts/workspace.sh" ] || exit 0

output="$(mktemp -d)" || exit 0
trap 'rm -rf "$output"' EXIT

"$main/scripts/workspace.sh" sync >"$output/repos" 2>&1 </dev/null &
repos_pid=$!
python3 "$main/scripts/memory-sync.py" >"$output/memory" 2>&1 </dev/null &
memory_pid=$!

running() { kill -0 "$repos_pid" 2>/dev/null || kill -0 "$memory_pid" 2>/dev/null; }

started=$SECONDS
while running && [ $((SECONDS - started)) -lt "$deadline_seconds" ]; do
    sleep 0.2
done
if running; then
    # TERM lets the sync finish a merge in progress and release its lock. The
    # redirect also hides the notice bash prints for a job it stopped.
    {
        kill -TERM "$repos_pid" "$memory_pid"
        sleep 1
        kill -KILL "$repos_pid" "$memory_pid"
    } 2>/dev/null
    echo "Session sync stopped at its ${deadline_seconds}-second limit; the lines below are what finished."
fi
wait "$repos_pid" "$memory_pid" 2>/dev/null

cat "$output/repos" "$output/memory" 2>/dev/null

plans="$("$main/scripts/workspace.sh" running 2>/dev/null)"
if [ -n "$plans" ]; then
    echo "Plans running now (ask the operator before changing a repo named here):"
    echo "$plans" | sed 's/^/  /'
fi

exit 0
