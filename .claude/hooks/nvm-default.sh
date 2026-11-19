# Sourced by the commit gate and the node-path hook: sets node_bin_dir to the
# bin folder of nvm's default Node, or to "" without nvm or a usable default,
# and brew_bin_dir to Homebrew's bin, or to "" without Homebrew (agent-vm).
# The desktop app hands hooks and the Bash tool a PATH with every nvm version
# on it, oldest first, and /usr/bin before Homebrew, so python3 is macOS's
# 3.9, while a terminal runs the defaults. Runs under macOS /bin/bash 3.2 and
# bash 5.

node_bin_dir=unset
resolve_nvm_default() {
    [[ "$node_bin_dir" == unset ]] || return 0
    node_bin_dir=""
    local nvm="${NVM_DIR:-$HOME/.nvm}" v="" d key bkey=-1 i
    local f="$nvm/alias/default"
    for i in 1 2 3 4; do
        [[ -f "$f" && -r "$f" ]] || return 0
        read -r v < "$f" || [[ -n "$v" ]] || return 0
        [[ "$v" == lts/* ]] || break
        f="$nvm/alias/$v"
    done
    case "$v" in
        node|stable) set -- "$nvm/versions/node/v"* ;;
        *)
            v="${v#v}"
            [[ "$v" =~ ^[0-9]+(\.[0-9]+){0,2}$ ]] || return 0
            set -- "$nvm/versions/node/v$v"{,.*}
            ;;
    esac
    for d in "$@"; do
        [[ -x "$d/bin/node" && "${d##*/v}" =~ ^([0-9]+)\.([0-9]+)\.([0-9]+)$ ]] || continue
        key=$((10#${BASH_REMATCH[1]} * 1000000 + 10#${BASH_REMATCH[2]} * 1000 + 10#${BASH_REMATCH[3]}))
        (( key > bkey )) && node_bin_dir="$d/bin" bkey=$key
    done
    return 0
}

resolve_brew_bin() {
    brew_bin_dir="${HOMEBREW_PREFIX:-/opt/homebrew}/bin"
    [[ "$brew_bin_dir" == /* && -x "$brew_bin_dir/brew" ]] || brew_bin_dir=""
    return 0
}

# The folders to put before PATH, nvm's Node first, in tool_path_prefix.
resolve_tool_path() {
    resolve_nvm_default
    resolve_brew_bin
    [[ "$node_bin_dir" == /* ]] || node_bin_dir=""
    tool_path_prefix="$node_bin_dir"
    [[ -z "$brew_bin_dir" ]] || tool_path_prefix="${tool_path_prefix:+$tool_path_prefix:}$brew_bin_dir"
    return 0
}
