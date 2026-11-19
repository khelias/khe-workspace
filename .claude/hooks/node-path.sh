#!/bin/bash
# SessionStart: put nvm's default Node and Homebrew's bin first in the Bash
# tool's PATH, as the commit gate does for checks (see nvm-default.sh). Never
# blocks a session.
[ -n "${CLAUDE_ENV_FILE:-}" ] || exit 0
. "${BASH_SOURCE[0]%/*}/nvm-default.sh" 2>/dev/null || exit 0
resolve_tool_path
case "$tool_path_prefix" in
    /*) printf 'case "$PATH" in %q:*) ;; *) PATH=%q:"$PATH" ;; esac\n' "$tool_path_prefix" "$tool_path_prefix" >> "$CLAUDE_ENV_FILE" ;;
esac
exit 0
