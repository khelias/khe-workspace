#!/bin/bash
# SessionStart: put nvm's default Node first in the Bash tool's PATH, as the
# commit gate does for checks (see nvm-default.sh). Never blocks a session.
[ -n "${CLAUDE_ENV_FILE:-}" ] || exit 0
. "${BASH_SOURCE[0]%/*}/nvm-default.sh" 2>/dev/null || exit 0
resolve_nvm_default
case "$node_bin_dir" in
    /*) printf 'case "$PATH" in %q:*) ;; *) PATH=%q:"$PATH" ;; esac\n' "$node_bin_dir" "$node_bin_dir" >> "$CLAUDE_ENV_FILE" ;;
esac
exit 0
