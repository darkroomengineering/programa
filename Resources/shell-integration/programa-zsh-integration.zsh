# cmux shell integration for zsh
# Injected automatically — do not source manually

# Prefer zsh/net/unix for socket sends (no fork, ~0.2ms per send vs ~3ms
# for fork+exec of ncat/socat/nc).  Falls back to external tools if the
# module is unavailable.
typeset -g _PROGRAMA_HAS_ZSOCKET=0
if zmodload zsh/net/unix 2>/dev/null; then
    _PROGRAMA_HAS_ZSOCKET=1
fi

_cmux_send() {
    local payload="$1"
    if (( _PROGRAMA_HAS_ZSOCKET )); then
        local fd
        zsocket "$PROGRAMA_SOCKET_PATH" 2>/dev/null || return 1
        fd=$REPLY
        print -u $fd -r -- "$payload" 2>/dev/null
        exec {fd}>&- 2>/dev/null
        return 0
    fi
    if command -v ncat >/dev/null 2>&1; then
        print -r -- "$payload" | ncat -w 1 -U "$PROGRAMA_SOCKET_PATH" --send-only
    elif command -v socat >/dev/null 2>&1; then
        print -r -- "$payload" | socat -T 1 - "UNIX-CONNECT:$PROGRAMA_SOCKET_PATH" >/dev/null 2>&1
    elif command -v nc >/dev/null 2>&1; then
        if print -r -- "$payload" | nc -N -U "$PROGRAMA_SOCKET_PATH" >/dev/null 2>&1; then
            :
        else
            print -r -- "$payload" | nc -w 1 -U "$PROGRAMA_SOCKET_PATH" >/dev/null 2>&1 || true
        fi
    fi
}

# Fire-and-forget send: synchronous when zsocket is available (fast, no fork),
# backgrounded otherwise.
_cmux_send_bg() {
    if (( _PROGRAMA_HAS_ZSOCKET )); then
        _cmux_send "$1"
    else
        { _cmux_send "$1" } >/dev/null 2>&1 &!
    fi
}

_cmux_socket_is_unix() {
    [[ -n "$PROGRAMA_SOCKET_PATH" && -S "$PROGRAMA_SOCKET_PATH" ]]
}

_cmux_relay_cli_path() {
    if [[ -n "${PROGRAMA_BUNDLED_CLI_PATH:-}" && -x "${PROGRAMA_BUNDLED_CLI_PATH}" ]]; then
        print -r -- "${PROGRAMA_BUNDLED_CLI_PATH}"
        return 0
    fi
    # Rebranded CLI binary ships as "programa"; fall back to the pre-rebrand
    # "cmux" name for older installs that only symlinked that binary.
    command -v programa 2>/dev/null || command -v cmux 2>/dev/null
}

_cmux_socket_uses_remote_relay() {
    [[ -n "$PROGRAMA_SOCKET_PATH" ]] || return 1
    [[ "$PROGRAMA_SOCKET_PATH" == /* ]] && return 1
    [[ "$PROGRAMA_SOCKET_PATH" == *:* ]] || return 1
    [[ -n "$(_cmux_relay_cli_path)" ]]
}

_cmux_has_port_scan_transport() {
    _cmux_socket_is_unix && return 0
    _cmux_socket_uses_remote_relay
}

_cmux_json_escape() {
    local value="$1"
    value="${value//\\/\\\\}"
    value="${value//\"/\\\"}"
    value="${value//$'\n'/\\n}"
    value="${value//$'\r'/\\r}"
    value="${value//$'\t'/\\t}"
    print -r -- "$value"
}

# Build a single-line v2 JSON-RPC request frame for the direct-socket
# (fire-and-forget) path. `params_json` must already be a well-formed JSON
# object string (see call sites, which use _cmux_json_escape on any
# user-controlled values before interpolating them).
_cmux_json_rpc_frame() {
    local method="$1"
    local params_json="$2"
    print -r -- "{\"id\":1,\"method\":\"$method\",\"params\":$params_json}"
}

_cmux_relay_rpc_bg() {
    local method="$1"
    local params="$2"
    local relay_cli=""
    _cmux_socket_uses_remote_relay || return 1
    relay_cli="$(_cmux_relay_cli_path)" || return 1
    { "$relay_cli" rpc "$method" "$params" >/dev/null 2>&1 || true } >/dev/null 2>&1 &!
}

_cmux_relay_rpc() {
    local method="$1"
    local params="$2"
    local relay_cli=""
    local response=""
    _cmux_socket_uses_remote_relay || return 1
    # Relay `cmux rpc` exits nonzero on server error. The real remote CLI prints
    # only the JSON result payload on success, while some test stubs return the
    # full `{"ok":...}` envelope. Retry only on explicit `ok:false`.
    relay_cli="$(_cmux_relay_cli_path)" || return 1
    response="$("$relay_cli" rpc "$method" "$params" 2>/dev/null)" || return 1
    response="${response//$'\n'/}"
    response="${response//$'\r'/}"
    [[ "$response" == *'"ok":false'* || "$response" == *'"ok": false'* ]] && return 1
    return 0
}

_cmux_relay_workspace_id() {
    if [[ -n "$PROGRAMA_WORKSPACE_ID" ]]; then
        print -r -- "$PROGRAMA_WORKSPACE_ID"
        return 0
    fi
    [[ -n "$PROGRAMA_TAB_ID" ]] || return 1
    print -r -- "$PROGRAMA_TAB_ID"
}

_cmux_report_tty_via_relay() {
    _cmux_socket_uses_remote_relay || return 1
    local workspace_id=""
    workspace_id="$(_cmux_relay_workspace_id)" || return 1
    [[ -n "$_PROGRAMA_TTY_NAME" ]] || return 1

    local tty_name_json params
    tty_name_json="$(_cmux_json_escape "$_PROGRAMA_TTY_NAME")"
    params="{\"workspace_id\":\"$workspace_id\",\"tty_name\":\"$tty_name_json\""
    if [[ -n "$PROGRAMA_PANEL_ID" ]]; then
        params+=",\"surface_id\":\"$PROGRAMA_PANEL_ID\""
    fi
    params+="}"
    _cmux_relay_rpc "surface.report_tty" "$params"
}

_cmux_ports_kick_via_relay() {
    local reason="${1:-command}"
    _cmux_socket_uses_remote_relay || return 1
    local workspace_id=""
    workspace_id="$(_cmux_relay_workspace_id)" || return 1
    local params="{\"workspace_id\":\"$workspace_id\",\"reason\":\"$reason\""
    if [[ -n "$PROGRAMA_PANEL_ID" ]]; then
        params+=",\"surface_id\":\"$PROGRAMA_PANEL_ID\""
    fi
    params+="}"
    _cmux_relay_rpc_bg "surface.ports_kick" "$params"
}

_cmux_restore_scrollback_once() {
    local path="${PROGRAMA_RESTORE_SCROLLBACK_FILE:-}"
    [[ -n "$path" ]] || return 0
    unset PROGRAMA_RESTORE_SCROLLBACK_FILE

    if [[ -r "$path" ]]; then
        /bin/cat -- "$path" 2>/dev/null || true
        /bin/rm -f -- "$path" >/dev/null 2>&1 || true
    fi
}
_cmux_restore_scrollback_once

_cmux_now() {
    print -r -- "${EPOCHSECONDS:-$SECONDS}"
}

typeset -g _PROGRAMA_CLAUDE_WRAPPER=""
_cmux_install_claude_wrapper() {
    local integration_dir="${PROGRAMA_SHELL_INTEGRATION_DIR:-}"
    [[ -n "$integration_dir" ]] || return 0

    integration_dir="${integration_dir%/}"
    local bundle_dir="${integration_dir%/shell-integration}"
    local wrapper_path="$bundle_dir/bin/claude"
    [[ -x "$wrapper_path" ]] || return 0

    # Keep the bundled claude wrapper ahead of later PATH mutations. Install it
    # via eval so an existing `alias claude=...` cannot break parsing.
    _PROGRAMA_CLAUDE_WRAPPER="$wrapper_path"
    builtin unalias claude >/dev/null 2>&1 || true
    eval 'claude() { "$_PROGRAMA_CLAUDE_WRAPPER" "$@"; }'
}
_cmux_install_claude_wrapper

# Throttle heavy work to avoid prompt latency.
typeset -g _PROGRAMA_PWD_LAST_PWD=""
typeset -g _PROGRAMA_GIT_LAST_PWD=""
typeset -g _PROGRAMA_GIT_LAST_RUN=0
typeset -g _PROGRAMA_GIT_JOB_PID=""
typeset -g _PROGRAMA_GIT_JOB_STARTED_AT=0
typeset -g _PROGRAMA_GIT_FORCE=0
typeset -g _PROGRAMA_GIT_HEAD_LAST_PWD=""
typeset -g _PROGRAMA_GIT_HEAD_PATH=""
typeset -g _PROGRAMA_GIT_HEAD_SIGNATURE=""
typeset -g _PROGRAMA_GIT_HEAD_WATCH_PID=""
typeset -g _PROGRAMA_PR_POLL_PID=""
typeset -g _PROGRAMA_PR_POLL_PWD=""
typeset -g _PROGRAMA_PR_LAST_BRANCH=""
typeset -g _PROGRAMA_PR_NO_PR_BRANCH=""
typeset -g _PROGRAMA_PR_POLL_INTERVAL=45
typeset -g _PROGRAMA_PR_FORCE=0
typeset -g _PROGRAMA_PR_DEBUG=${_PROGRAMA_PR_DEBUG:-0}
typeset -g _PROGRAMA_ASYNC_JOB_TIMEOUT=20

typeset -g _PROGRAMA_PORTS_LAST_RUN=0
typeset -g _PROGRAMA_CMD_START=0
typeset -g _PROGRAMA_SHELL_ACTIVITY_LAST=""
typeset -g _PROGRAMA_TTY_NAME=""
typeset -g _PROGRAMA_TTY_REPORTED=0
typeset -g _PROGRAMA_GHOSTTY_SEMANTIC_PATCHED=0
typeset -g _PROGRAMA_WINCH_GUARD_INSTALLED=0
typeset -g _PROGRAMA_TMUX_PUSH_SIGNATURE=""
typeset -g _PROGRAMA_TMUX_PULL_SIGNATURE=""
typeset -ga _PROGRAMA_TMUX_SYNC_KEYS=(
    PROGRAMA_BUNDLED_CLI_PATH
    PROGRAMA_BUNDLE_ID
    CMUXD_UNIX_PATH
    CMUXTERM_REPO_ROOT
    PROGRAMA_DEBUG_LOG
    PROGRAMA_LOAD_GHOSTTY_ZSH_INTEGRATION
    PROGRAMA_PORT
    PROGRAMA_PORT_END
    PROGRAMA_PORT_RANGE
    PROGRAMA_REMOTE_DAEMON_ALLOW_LOCAL_BUILD
    PROGRAMA_SHELL_INTEGRATION
    PROGRAMA_SHELL_INTEGRATION_DIR
    PROGRAMA_SOCKET_ENABLE
    PROGRAMA_SOCKET_MODE
    PROGRAMA_SOCKET_PATH
    PROGRAMA_TAB_ID
    PROGRAMA_TAG
    PROGRAMA_WORKSPACE_ID
)
typeset -ga _PROGRAMA_TMUX_SURFACE_SCOPED_KEYS=(
    PROGRAMA_PANEL_ID
    PROGRAMA_SURFACE_ID
)

_cmux_tmux_sync_key_is_managed() {
    local candidate="$1"
    local key
    for key in "${_PROGRAMA_TMUX_SYNC_KEYS[@]}"; do
        [[ "$key" == "$candidate" ]] && return 0
    done
    return 1
}

_cmux_tmux_shell_env_signature() {
    local key value
    local -a parts
    for key in "${_PROGRAMA_TMUX_SYNC_KEYS[@]}"; do
        value="${(P)key}"
        [[ -n "$value" ]] || continue
        parts+=("${key}=${value}")
    done
    print -r -- "${(j:\x1f:)parts}"
}

_cmux_tmux_publish_cmux_environment() {
    [[ -z "$TMUX" ]] || return 0
    command -v tmux >/dev/null 2>&1 || return 0

    local signature
    signature="$(_cmux_tmux_shell_env_signature)"
    [[ -n "$signature" ]] || return 0
    [[ "$signature" == "$_PROGRAMA_TMUX_PUSH_SIGNATURE" ]] && return 0

    local key value
    for key in "${_PROGRAMA_TMUX_SYNC_KEYS[@]}"; do
        value="${(P)key}"
        [[ -n "$value" ]] || continue
        tmux set-environment -g "$key" "$value" >/dev/null 2>&1 || return 0
    done

    for key in "${_PROGRAMA_TMUX_SURFACE_SCOPED_KEYS[@]}"; do
        tmux set-environment -gu "$key" >/dev/null 2>&1 || return 0
    done

    _PROGRAMA_TMUX_PUSH_SIGNATURE="$signature"
}

_cmux_tmux_refresh_cmux_environment() {
    [[ -n "$TMUX" ]] || return 0
    command -v tmux >/dev/null 2>&1 || return 0

    local output
    output="$(tmux show-environment -g 2>/dev/null)" || return 0

    local line key filtered="" did_change=0
    while IFS= read -r line; do
        [[ "$line" == PROGRAMA_* ]] || continue
        key="${line%%=*}"
        _cmux_tmux_sync_key_is_managed "$key" || continue
        filtered+="${line}"$'\n'
    done <<< "$output"

    [[ -n "$filtered" ]] || return 0
    [[ "$filtered" == "$_PROGRAMA_TMUX_PULL_SIGNATURE" ]] && return 0

    local value
    while IFS= read -r line; do
        [[ "$line" == PROGRAMA_* ]] || continue
        key="${line%%=*}"
        _cmux_tmux_sync_key_is_managed "$key" || continue
        value="${line#*=}"
        if [[ "${(P)key}" != "$value" ]]; then
            export "$key=$value"
            did_change=1
        fi
    done <<< "$filtered"

    _PROGRAMA_TMUX_PULL_SIGNATURE="$filtered"
    if (( did_change )); then
        _PROGRAMA_TTY_REPORTED=0
        _PROGRAMA_SHELL_ACTIVITY_LAST=""
        _PROGRAMA_PWD_LAST_PWD=""
        _PROGRAMA_GIT_LAST_PWD=""
        _PROGRAMA_GIT_HEAD_LAST_PWD=""
        _PROGRAMA_GIT_HEAD_PATH=""
        _PROGRAMA_GIT_HEAD_SIGNATURE=""
        _PROGRAMA_GIT_FORCE=1
        _PROGRAMA_PR_FORCE=1
        _cmux_stop_pr_poll_loop
        _cmux_stop_git_head_watch
    fi
}

_cmux_tmux_sync_cmux_environment() {
    if [[ -n "$TMUX" ]]; then
        _cmux_tmux_refresh_cmux_environment
    else
        _cmux_tmux_publish_cmux_environment
    fi
}

_cmux_ensure_ghostty_preexec_strips_both_marks() {
    local fn_name="$1"
    (( $+functions[$fn_name] )) || return 0

    local old_strip new_strip updated
    old_strip=$'PS1=${PS1//$\'%{\\e]133;A;cl=line\\a%}\'}'
    new_strip=$'PS1=${PS1//$\'%{\\e]133;A;redraw=last;cl=line\\a%}\'}'
    updated="${functions[$fn_name]}"

    if [[ "$updated" == *"$new_strip"* && "$updated" != *"$old_strip"* ]]; then
        updated="${updated/$new_strip/$old_strip
        $new_strip}"
        functions[$fn_name]="$updated"
        _PROGRAMA_GHOSTTY_SEMANTIC_PATCHED=1
        return 0
    fi
    if [[ "$updated" == *"$old_strip"* && "$updated" != *"$new_strip"* ]]; then
        updated="${updated/$old_strip/$old_strip
        $new_strip}"
        functions[$fn_name]="$updated"
        _PROGRAMA_GHOSTTY_SEMANTIC_PATCHED=1
    fi
}

_cmux_patch_ghostty_semantic_redraw() {
    local old_frag new_frag
    old_frag='133;A;cl=line'
    new_frag='133;A;redraw=last;cl=line'

    # Patch both deferred and live hook definitions, depending on init timing.
    if (( $+functions[_ghostty_deferred_init] )); then
        functions[_ghostty_deferred_init]="${functions[_ghostty_deferred_init]//$old_frag/$new_frag}"
        _PROGRAMA_GHOSTTY_SEMANTIC_PATCHED=1
    fi
    if (( $+functions[_ghostty_precmd] )); then
        functions[_ghostty_precmd]="${functions[_ghostty_precmd]//$old_frag/$new_frag}"
        _PROGRAMA_GHOSTTY_SEMANTIC_PATCHED=1
    fi
    if (( $+functions[_ghostty_preexec] )); then
        functions[_ghostty_preexec]="${functions[_ghostty_preexec]//$old_frag/$new_frag}"
        _PROGRAMA_GHOSTTY_SEMANTIC_PATCHED=1
    fi

    # Keep legacy + redraw-aware strip lines so prompts created before patching
    # are still cleared by preexec.
    _cmux_ensure_ghostty_preexec_strips_both_marks _ghostty_deferred_init
    _cmux_ensure_ghostty_preexec_strips_both_marks _ghostty_preexec
}
_cmux_patch_ghostty_semantic_redraw

_cmux_prompt_wrap_guard() {
    local cmd_start="$1"
    local pwd="$2"
    [[ -n "$cmd_start" && "$cmd_start" != 0 ]] || return 0

    local cols="${COLUMNS:-0}"
    (( cols > 0 )) || return 0

    local budget=$(( cols - 24 ))
    (( budget < 20 )) && budget=20
    (( ${#pwd} >= budget )) || return 0

    # Keep a spacer line between command output and a wrapped prompt so
    # resize-driven prompt redraw cannot overwrite the command tail.
    builtin print -r -- ""
}

_cmux_install_winch_guard() {
    (( _PROGRAMA_WINCH_GUARD_INSTALLED )) && return 0

    # Respect user-defined WINCH handlers (function-based or trap-based).
    local existing_winch_trap=""
    existing_winch_trap="$(trap -p WINCH 2>/dev/null || true)"
    if (( $+functions[TRAPWINCH] )) || [[ -n "$existing_winch_trap" ]]; then
        _PROGRAMA_WINCH_GUARD_INSTALLED=1
        return 0
    fi

    TRAPWINCH() {
        [[ -n "$PROGRAMA_TAB_ID" ]] || return 0
        [[ -n "$PROGRAMA_PANEL_ID" ]] || return 0

        # Ghostty already marks prompt redraws on SIGWINCH. Writing to the PTY
        # here grows the screen and makes resize look like a fresh prompt.
        return 0
    }

    _PROGRAMA_WINCH_GUARD_INSTALLED=1
}
_cmux_install_winch_guard

_cmux_git_resolve_head_path() {
    # Resolve the HEAD file path without invoking git (fast; works for worktrees).
    local dir="$PWD"
    while true; do
        if [[ -d "$dir/.git" ]]; then
            print -r -- "$dir/.git/HEAD"
            return 0
        fi
        if [[ -f "$dir/.git" ]]; then
            local line gitdir
            line="$(<"$dir/.git")"
            if [[ "$line" == gitdir:* ]]; then
                gitdir="${line#gitdir:}"
                gitdir="${gitdir## }"
                gitdir="${gitdir%% }"
                [[ -n "$gitdir" ]] || return 1
                [[ "$gitdir" != /* ]] && gitdir="$dir/$gitdir"
                print -r -- "$gitdir/HEAD"
                return 0
            fi
        fi
        [[ "$dir" == "/" || -z "$dir" ]] && break
        dir="${dir:h}"
    done
    return 1
}

_cmux_git_head_signature() {
    local head_path="$1"
    [[ -n "$head_path" && -r "$head_path" ]] || return 1
    local line=""
    if IFS= read -r line < "$head_path"; then
        print -r -- "$line"
        return 0
    fi
    return 1
}

_cmux_report_tty_payload() {
    [[ -n "$PROGRAMA_TAB_ID" ]] || return 0
    [[ -n "$_PROGRAMA_TTY_NAME" ]] || return 0

    local workspace_id="" tty_name_json params
    workspace_id="$(_cmux_relay_workspace_id)" || workspace_id="$PROGRAMA_TAB_ID"
    tty_name_json="$(_cmux_json_escape "$_PROGRAMA_TTY_NAME")"
    params="{\"workspace_id\":\"$workspace_id\",\"tty_name\":\"$tty_name_json\""
    if [[ -z "$TMUX" ]]; then
        [[ -n "$PROGRAMA_PANEL_ID" ]] || return 0
        params+=",\"surface_id\":\"$PROGRAMA_PANEL_ID\""
    fi
    params+="}"

    _cmux_json_rpc_frame "surface.report_tty" "$params"
}

_cmux_report_tty_once() {
    # Send the TTY name to the app once per session so the batched port scanner
    # knows which TTY belongs to this panel.
    (( _PROGRAMA_TTY_REPORTED )) && return 0
    _cmux_has_port_scan_transport || return 0

    if _cmux_socket_is_unix; then
        local payload=""
        payload="$(_cmux_report_tty_payload)"
        [[ -n "$payload" ]] || return 0
        _PROGRAMA_TTY_REPORTED=1
        _cmux_send_bg "$payload"
    else
        [[ -n "$_PROGRAMA_TTY_NAME" ]] || return 0
        # Keep the first relay TTY report synchronous so the server can resolve
        # the target surface before command-start kicks begin their scan burst.
        _cmux_report_tty_via_relay || return 0
        _PROGRAMA_TTY_REPORTED=1
    fi
}

_cmux_report_shell_activity_state() {
    local state="$1"
    [[ -n "$state" ]] || return 0
    [[ -S "$PROGRAMA_SOCKET_PATH" ]] || return 0
    [[ -n "$PROGRAMA_TAB_ID" ]] || return 0
    [[ -n "$PROGRAMA_PANEL_ID" ]] || return 0
    [[ "$_PROGRAMA_SHELL_ACTIVITY_LAST" == "$state" ]] && return 0
    _PROGRAMA_SHELL_ACTIVITY_LAST="$state"
    local workspace_id="" state_json params
    workspace_id="$(_cmux_relay_workspace_id)" || workspace_id="$PROGRAMA_TAB_ID"
    state_json="$(_cmux_json_escape "$state")"
    params="{\"workspace_id\":\"$workspace_id\",\"surface_id\":\"$PROGRAMA_PANEL_ID\",\"state\":\"$state_json\"}"
    _cmux_send_bg "$(_cmux_json_rpc_frame "surface.report_shell_state" "$params")"
}

_cmux_ports_kick() {
    local reason="${1:-command}"
    # Lightweight: just tell the app to run a batched scan for this panel.
    # The app coalesces kicks across all panels and runs a single ps+lsof.
    _cmux_has_port_scan_transport || return 0
    [[ -n "$PROGRAMA_TAB_ID" ]] || return 0
    if _cmux_socket_is_unix; then
        [[ -n "$PROGRAMA_PANEL_ID" ]] || return 0
    fi
    _PROGRAMA_PORTS_LAST_RUN="$(_cmux_now)"
    if _cmux_socket_is_unix; then
        local workspace_id="" reason_json params
        workspace_id="$(_cmux_relay_workspace_id)" || workspace_id="$PROGRAMA_TAB_ID"
        reason_json="$(_cmux_json_escape "$reason")"
        params="{\"workspace_id\":\"$workspace_id\",\"surface_id\":\"$PROGRAMA_PANEL_ID\",\"reason\":\"$reason_json\"}"
        _cmux_send_bg "$(_cmux_json_rpc_frame "surface.ports_kick" "$params")"
    else
        _cmux_ports_kick_via_relay "$reason"
    fi
}

_cmux_report_git_branch_for_path() {
    local repo_path="$1"
    [[ -n "$repo_path" ]] || return 0
    [[ -S "$PROGRAMA_SOCKET_PATH" ]] || return 0
    [[ -n "$PROGRAMA_TAB_ID" ]] || return 0
    [[ -n "$PROGRAMA_PANEL_ID" ]] || return 0

    # Skip git operations if not in a git repository to avoid TCC prompts
    git -C "$repo_path" rev-parse --git-dir >/dev/null 2>&1 || return 0

    local branch dirty=false first workspace_id="" params
    branch="$(git -C "$repo_path" branch --show-current 2>/dev/null)"
    workspace_id="$(_cmux_relay_workspace_id)" || workspace_id="$PROGRAMA_TAB_ID"
    if [[ -n "$branch" ]]; then
        first="$(git -C "$repo_path" status --porcelain -uno 2>/dev/null | head -1)"
        [[ -n "$first" ]] && dirty=true
        local branch_json
        branch_json="$(_cmux_json_escape "$branch")"
        params="{\"workspace_id\":\"$workspace_id\",\"surface_id\":\"$PROGRAMA_PANEL_ID\",\"branch\":\"$branch_json\",\"dirty\":$dirty}"
        _cmux_send "$(_cmux_json_rpc_frame "surface.report_git_branch" "$params")"
    else
        params="{\"workspace_id\":\"$workspace_id\",\"surface_id\":\"$PROGRAMA_PANEL_ID\"}"
        _cmux_send "$(_cmux_json_rpc_frame "surface.clear_git_branch" "$params")"
    fi
}

_cmux_clear_pr_for_panel() {
    [[ -S "$PROGRAMA_SOCKET_PATH" ]] || return 0
    [[ -n "$PROGRAMA_TAB_ID" ]] || return 0
    [[ -n "$PROGRAMA_PANEL_ID" ]] || return 0
    local workspace_id="" params
    workspace_id="$(_cmux_relay_workspace_id)" || workspace_id="$PROGRAMA_TAB_ID"
    params="{\"workspace_id\":\"$workspace_id\",\"surface_id\":\"$PROGRAMA_PANEL_ID\"}"
    _cmux_send_bg "$(_cmux_json_rpc_frame "surface.clear_pr" "$params")"
}

_cmux_pr_output_indicates_no_pull_request() {
    local output="${1:l}"
    [[ "$output" == *"no pull requests found"* \
        || "$output" == *"no pull request found"* \
        || "$output" == *"no pull requests associated"* \
        || "$output" == *"no pull request associated"* ]]
}

_cmux_github_repo_slug_for_path() {
    local repo_path="$1"
    local remote_url="" path_part=""
    [[ -n "$repo_path" ]] || return 0

    remote_url="$(git -C "$repo_path" remote get-url origin 2>/dev/null)"
    [[ -n "$remote_url" ]] || return 0

    case "$remote_url" in
        git@github.com:*)
            path_part="${remote_url#git@github.com:}"
            ;;
        ssh://git@github.com/*)
            path_part="${remote_url#ssh://git@github.com/}"
            ;;
        https://github.com/*)
            path_part="${remote_url#https://github.com/}"
            ;;
        http://github.com/*)
            path_part="${remote_url#http://github.com/}"
            ;;
        git://github.com/*)
            path_part="${remote_url#git://github.com/}"
            ;;
        *)
            return 0
            ;;
    esac

    path_part="${path_part%.git}"
    [[ "$path_part" == */* ]] || return 0
    print -r -- "$path_part"
}

_cmux_pr_cache_prefix() {
    [[ -n "$PROGRAMA_PANEL_ID" ]] || return 1
    print -r -- "/tmp/cmux-pr-cache-${PROGRAMA_PANEL_ID}"
}

_cmux_pr_force_signal_path() {
    [[ -n "$PROGRAMA_PANEL_ID" ]] || return 1
    print -r -- "/tmp/cmux-pr-force-${PROGRAMA_PANEL_ID}"
}

_cmux_pr_debug_log() {
    (( _PROGRAMA_PR_DEBUG )) || return 0

    local branch="$1"
    local event="$2"
    local now="${EPOCHSECONDS:-$SECONDS}"
    printf '%s\tbranch=%s\tevent=%s\n' "$now" "$branch" "$event" >> /tmp/cmux-pr-debug.log
}

_cmux_pr_cache_clear() {
    local prefix=""
    prefix="$(_cmux_pr_cache_prefix 2>/dev/null || true)"
    if [[ -n "$prefix" ]]; then
        /bin/rm -f -- \
            "${prefix}.branch" \
            "${prefix}.repo" \
            "${prefix}.result" \
            "${prefix}.timestamp" \
            "${prefix}.no-pr-branch" \
            >/dev/null 2>&1 || true
    fi

    _PROGRAMA_PR_LAST_BRANCH=""
    _PROGRAMA_PR_NO_PR_BRANCH=""
}

_cmux_pr_request_probe() {
    local signal_path=""
    signal_path="$(_cmux_pr_force_signal_path 2>/dev/null || true)"
    [[ -n "$signal_path" ]] || return 0
    : >| "$signal_path"
}

_cmux_report_pr_for_path() {
    local repo_path="$1"
    local force_probe="${2:-0}"
    [[ -n "$repo_path" ]] || {
        _cmux_pr_cache_clear
        _cmux_clear_pr_for_panel
        return 0
    }
    [[ -d "$repo_path" ]] || {
        _cmux_pr_cache_clear
        _cmux_clear_pr_for_panel
        return 0
    }
    [[ -S "$PROGRAMA_SOCKET_PATH" ]] || return 0
    [[ -n "$PROGRAMA_TAB_ID" ]] || return 0
    [[ -n "$PROGRAMA_PANEL_ID" ]] || return 0

    local branch repo_slug="" gh_output="" gh_error="" err_file="" number state url status_opt="" gh_status
    local now="${EPOCHSECONDS:-$SECONDS}"
    local prefix="" branch_file="" repo_file="" result_file="" timestamp_file="" no_pr_branch_file=""
    local cache_branch="" cache_result="" cache_no_pr_branch=""
    local -a gh_repo_args
    gh_repo_args=()
    branch="$(git -C "$repo_path" branch --show-current 2>/dev/null)"
    if [[ -z "$branch" ]] || ! command -v gh >/dev/null 2>&1; then
        _cmux_pr_debug_log "$branch" "cache-miss:clear"
        _cmux_pr_cache_clear
        _cmux_clear_pr_for_panel
        return 0
    fi

    prefix="$(_cmux_pr_cache_prefix 2>/dev/null || true)"
    if [[ -n "$prefix" ]]; then
        branch_file="${prefix}.branch"
        repo_file="${prefix}.repo"
        result_file="${prefix}.result"
        timestamp_file="${prefix}.timestamp"
        no_pr_branch_file="${prefix}.no-pr-branch"
        [[ -r "$branch_file" ]] && cache_branch="$(<"$branch_file")"
        [[ -r "$result_file" ]] && cache_result="$(<"$result_file")"
        [[ -r "$no_pr_branch_file" ]] && cache_no_pr_branch="$(<"$no_pr_branch_file")"
    fi

    _PROGRAMA_PR_LAST_BRANCH="$cache_branch"
    _PROGRAMA_PR_NO_PR_BRANCH="$cache_no_pr_branch"
    if [[ "$cache_branch" == "$branch" && -n "$cache_result" ]]; then
        _cmux_pr_debug_log "$branch" "cache-refresh"
    else
        _cmux_pr_debug_log "$branch" "cache-miss"
    fi

    repo_slug="$(_cmux_github_repo_slug_for_path "$repo_path")"
    if [[ -n "$repo_slug" ]]; then
        gh_repo_args=(--repo "$repo_slug")
    fi

    err_file="$(/usr/bin/mktemp "${TMPDIR:-/tmp}/cmux-gh-pr-view.XXXXXX" 2>/dev/null || true)"
    [[ -n "$err_file" ]] || return 1
    gh_output="$(
        builtin cd "$repo_path" 2>/dev/null \
            && gh pr view "$branch" \
                "${gh_repo_args[@]}" \
                --json number,state,url \
                --jq '[.number, .state, .url] | @tsv' \
                2>"$err_file"
    )"
    gh_status=$?
    if [[ -f "$err_file" ]]; then
        gh_error="$("/bin/cat" -- "$err_file" 2>/dev/null || true)"
        /bin/rm -f -- "$err_file" >/dev/null 2>&1 || true
    fi

    if (( gh_status != 0 )) || [[ -z "$gh_output" ]]; then
        if (( gh_status == 0 )) && [[ -z "$gh_output" ]]; then
            if [[ -n "$prefix" ]]; then
                print -r -- "$branch" >| "$branch_file"
                print -r -- "$repo_path" >| "$repo_file"
                print -r -- "$now" >| "$timestamp_file"
                print -r -- "none" >| "$result_file"
                print -r -- "$branch" >| "$no_pr_branch_file"
            fi
            _PROGRAMA_PR_LAST_BRANCH="$branch"
            _PROGRAMA_PR_NO_PR_BRANCH="$branch"
            _cmux_clear_pr_for_panel
            return 0
        fi
        if _cmux_pr_output_indicates_no_pull_request "$gh_error"; then
            if [[ -n "$prefix" ]]; then
                print -r -- "$branch" >| "$branch_file"
                print -r -- "$repo_path" >| "$repo_file"
                print -r -- "$now" >| "$timestamp_file"
                print -r -- "none" >| "$result_file"
                print -r -- "$branch" >| "$no_pr_branch_file"
            fi
            _PROGRAMA_PR_LAST_BRANCH="$branch"
            _PROGRAMA_PR_NO_PR_BRANCH="$branch"
            _cmux_clear_pr_for_panel
            return 0
        fi

        # Always scope PR detection to the exact current branch. When gh fails
        # transiently (auth hiccups, API lag, rate limiting), keep the last-known
        # badge and retry on the next poll instead of showing a mismatched PR.
        return 1
    fi

    local IFS=$'\t'
    read -r number state url <<< "$gh_output"
    if [[ -z "$number" ]] || [[ -z "$url" ]]; then
        return 1
    fi

    case "$state" in
        MERGED) status_opt="merged" ;;
        OPEN) status_opt="open" ;;
        CLOSED) status_opt="closed" ;;
        *) return 1 ;;
    esac

    if [[ -n "$prefix" ]]; then
        print -r -- "$branch" >| "$branch_file"
        print -r -- "$repo_path" >| "$repo_file"
        print -r -- "$now" >| "$timestamp_file"
        printf '%s\t%s\t%s\t%s\n' "pr" "$number" "$state" "$url" >| "$result_file"
        /bin/rm -f -- "$no_pr_branch_file" >/dev/null 2>&1 || true
    fi
    _PROGRAMA_PR_LAST_BRANCH="$branch"
    _PROGRAMA_PR_NO_PR_BRANCH=""

    local workspace_id="" branch_json url_json params
    workspace_id="$(_cmux_relay_workspace_id)" || workspace_id="$PROGRAMA_TAB_ID"
    branch_json="$(_cmux_json_escape "$branch")"
    url_json="$(_cmux_json_escape "$url")"
    params="{\"workspace_id\":\"$workspace_id\",\"surface_id\":\"$PROGRAMA_PANEL_ID\",\"number\":$number,\"url\":\"$url_json\",\"state\":\"$status_opt\",\"branch\":\"$branch_json\"}"
    _cmux_send "$(_cmux_json_rpc_frame "surface.report_pr" "$params")"
}

_cmux_child_pids() {
    local parent_pid="$1"
    [[ -n "$parent_pid" ]] || return 0
    /bin/ps -ax -o pid= -o ppid= 2>/dev/null | /usr/bin/awk -v parent="$parent_pid" '$2 == parent { print $1 }'
}

_cmux_kill_process_tree() {
    local pid="$1"
    local signal="${2:-TERM}"
    local child_pid=""
    [[ -n "$pid" ]] || return 0

    while IFS= read -r child_pid; do
        [[ -n "$child_pid" ]] || continue
        [[ "$child_pid" == "$pid" ]] && continue
        _cmux_kill_process_tree "$child_pid" "$signal"
    done < <(_cmux_child_pids "$pid")

    kill "-$signal" "$pid" >/dev/null 2>&1 || true
}

_cmux_run_pr_probe_with_timeout() {
    local repo_path="$1"
    local force_probe="${2:-0}"
    local probe_pid=""
    local started_at="${EPOCHSECONDS:-$SECONDS}"
    local now=$started_at

    (
        _cmux_report_pr_for_path "$repo_path" "$force_probe"
    ) &
    probe_pid=$!

    while kill -0 "$probe_pid" >/dev/null 2>&1; do
        sleep 1
        now="${EPOCHSECONDS:-$SECONDS}"
        if (( _PROGRAMA_ASYNC_JOB_TIMEOUT > 0 )) && (( now - started_at >= _PROGRAMA_ASYNC_JOB_TIMEOUT )); then
            _cmux_kill_process_tree "$probe_pid" TERM
            sleep 0.2
            if kill -0 "$probe_pid" >/dev/null 2>&1; then
                _cmux_kill_process_tree "$probe_pid" KILL
                sleep 0.2
            fi
            if ! kill -0 "$probe_pid" >/dev/null 2>&1; then
                wait "$probe_pid" >/dev/null 2>&1 || true
            fi
            return 1
        fi
    done

    wait "$probe_pid"
}

_cmux_halt_pr_poll_loop() {
    if [[ -n "$_PROGRAMA_PR_POLL_PID" ]]; then
        # Process-group kill: background jobs are process-group leaders, so
        # negative PID kills the loop + all descendants (gh, sleep) without
        # the synchronous /bin/ps + awk of tree-kill (~5-13ms).
        kill -KILL -- -"$_PROGRAMA_PR_POLL_PID" 2>/dev/null || true
    fi
    local signal_path=""
    signal_path="$(_cmux_pr_force_signal_path 2>/dev/null || true)"
    [[ -n "$signal_path" ]] && /bin/rm -f -- "$signal_path" >/dev/null 2>&1 || true
    _PROGRAMA_PR_POLL_PID=""
    _PROGRAMA_PR_POLL_PWD=""
}

_cmux_stop_pr_poll_loop() {
    _cmux_halt_pr_poll_loop
    _cmux_pr_cache_clear
}

_cmux_start_pr_poll_loop() {
    [[ -S "$PROGRAMA_SOCKET_PATH" ]] || return 0
    [[ -n "$PROGRAMA_TAB_ID" ]] || return 0
    [[ -n "$PROGRAMA_PANEL_ID" ]] || return 0

    local watch_pwd="${1:-$PWD}"
    local force_restart="${2:-0}"
    local watch_shell_pid="$$"
    local interval="${_PROGRAMA_PR_POLL_INTERVAL:-45}"

    if [[ "$force_restart" != "1" && "$watch_pwd" == "$_PROGRAMA_PR_POLL_PWD" && -n "$_PROGRAMA_PR_POLL_PID" ]] \
        && kill -0 "$_PROGRAMA_PR_POLL_PID" 2>/dev/null; then
        return 0
    fi

    if [[ -n "$_PROGRAMA_PR_POLL_PID" ]] && kill -0 "$_PROGRAMA_PR_POLL_PID" 2>/dev/null; then
        _cmux_halt_pr_poll_loop
    else
        _PROGRAMA_PR_POLL_PID=""
    fi
    _PROGRAMA_PR_POLL_PWD="$watch_pwd"

    {
        local signal_path=""
        signal_path="$(_cmux_pr_force_signal_path 2>/dev/null || true)"
        while true; do
            kill -0 "$watch_shell_pid" >/dev/null 2>&1 || break
            local force_probe=0
            if [[ -n "$signal_path" && -f "$signal_path" ]]; then
                force_probe=1
                /bin/rm -f -- "$signal_path" >/dev/null 2>&1 || true
            fi
            _cmux_run_pr_probe_with_timeout "$watch_pwd" "$force_probe" || true

            local slept=0
            while (( slept < interval )); do
                kill -0 "$watch_shell_pid" >/dev/null 2>&1 || exit 0
                if [[ -n "$signal_path" && -f "$signal_path" ]]; then
                    break
                fi
                sleep 1
                slept=$(( slept + 1 ))
            done
        done
    } >/dev/null 2>&1 &!
    _PROGRAMA_PR_POLL_PID=$!
}

_cmux_stop_git_head_watch() {
    if [[ -n "$_PROGRAMA_GIT_HEAD_WATCH_PID" ]]; then
        kill "$_PROGRAMA_GIT_HEAD_WATCH_PID" >/dev/null 2>&1 || true
        _PROGRAMA_GIT_HEAD_WATCH_PID=""
    fi
}

_cmux_start_git_head_watch() {
    [[ -S "$PROGRAMA_SOCKET_PATH" ]] || return 0
    [[ -n "$PROGRAMA_TAB_ID" ]] || return 0
    [[ -n "$PROGRAMA_PANEL_ID" ]] || return 0

    local watch_pwd="$PWD"
    local watch_head_path
    watch_head_path="$(_cmux_git_resolve_head_path 2>/dev/null || true)"
    [[ -n "$watch_head_path" ]] || return 0

    local watch_head_signature
    watch_head_signature="$(_cmux_git_head_signature "$watch_head_path" 2>/dev/null || true)"

    _PROGRAMA_GIT_HEAD_LAST_PWD="$watch_pwd"
    _PROGRAMA_GIT_HEAD_PATH="$watch_head_path"
    _PROGRAMA_GIT_HEAD_SIGNATURE="$watch_head_signature"

    _cmux_stop_git_head_watch
    {
        local last_signature="$watch_head_signature"
        while true; do
            sleep 1

            local signature
            signature="$(_cmux_git_head_signature "$watch_head_path" 2>/dev/null || true)"
            if [[ -n "$signature" && "$signature" != "$last_signature" ]]; then
                last_signature="$signature"
                _cmux_pr_cache_clear
                _cmux_report_git_branch_for_path "$watch_pwd"
                _cmux_clear_pr_for_panel
                if [[ -n "$_PROGRAMA_PR_POLL_PID" ]] && kill -0 "$_PROGRAMA_PR_POLL_PID" 2>/dev/null; then
                    _cmux_pr_request_probe
                else
                    _cmux_run_pr_probe_with_timeout "$watch_pwd" 1 || true
                fi
            fi
        done
    } >/dev/null 2>&1 &!
    _PROGRAMA_GIT_HEAD_WATCH_PID=$!
}

_cmux_command_starts_nested_shell() {
    local cmd="$1"
    local -a words
    words=("${(z)cmd}")

    local index=1
    local word base
    while (( index <= ${#words} )); do
        word="${words[index]}"

        case "$word" in
            *=*)
                index=$(( index + 1 ))
                continue ;;
            exec|command|builtin|noglob|time)
                index=$(( index + 1 ))
                continue ;;
            env)
                index=$(( index + 1 ))
                while (( index <= ${#words} )); do
                    word="${words[index]}"
                    case "$word" in
                        -*|*=*)
                            index=$(( index + 1 ))
                            continue ;;
                    esac
                    break
                done
                continue ;;
        esac

        base="${word:t}"
        case "$base" in
            bash|zsh|sh|fish|nu|nix-shell)
                return 0 ;;
            nix)
                local next_index=$(( index + 1 ))
                local next_word="${words[next_index]}"
                case "$next_word" in
                    develop|shell)
                        return 0 ;;
                esac ;;
        esac

        return 1
    done

    return 1
}

_cmux_preexec() {
    _cmux_restore_terminal_identity_after_startup
    _cmux_tmux_sync_cmux_environment

    if [[ -z "$_PROGRAMA_TTY_NAME" ]]; then
        local t
        t="$(tty 2>/dev/null || true)"
        t="${t##*/}"
        [[ -n "$t" && "$t" != "not a tty" ]] && _PROGRAMA_TTY_NAME="$t"
    fi

    _PROGRAMA_CMD_START="$(_cmux_now)"
    _cmux_report_shell_activity_state running

    # Heuristic: commands that may change git branch/dirty state without changing $PWD.
    local cmd="${1## }"
    case "$cmd" in
        git\ *|git|gh\ *|lazygit|lazygit\ *|tig|tig\ *|gitui|gitui\ *|stg\ *|jj\ *)
            _PROGRAMA_GIT_FORCE=1
            _PROGRAMA_PR_FORCE=1 ;;
    esac

    # Register TTY + kick batched port scan for foreground commands (servers).
    _cmux_report_tty_once
    _cmux_ports_kick command
    _cmux_halt_pr_poll_loop
    _cmux_stop_git_head_watch
    if _cmux_command_starts_nested_shell "$cmd"; then
        return 0
    fi
    _cmux_start_git_head_watch
}

_cmux_precmd() {
    _cmux_stop_git_head_watch
    _cmux_tmux_sync_cmux_environment

    local programa_has_unix_socket=0
    _cmux_socket_is_unix && programa_has_unix_socket=1
    (( programa_has_unix_socket )) || _cmux_has_port_scan_transport || return 0
    [[ -n "$PROGRAMA_TAB_ID" ]] || return 0
    if [[ -n "$PROGRAMA_PANEL_ID" ]]; then
        _cmux_report_shell_activity_state prompt
    fi

    # Handle cases where Ghostty integration initializes after this file.
    (( _PROGRAMA_GHOSTTY_SEMANTIC_PATCHED )) || _cmux_patch_ghostty_semantic_redraw

    if [[ -z "$_PROGRAMA_TTY_NAME" ]]; then
        local t
        t="$(tty 2>/dev/null || true)"
        t="${t##*/}"
        [[ -n "$t" && "$t" != "not a tty" ]] && _PROGRAMA_TTY_NAME="$t"
    fi

    _cmux_report_tty_once

    local now="$(_cmux_now)"
    local cmd_start="$_PROGRAMA_CMD_START"
    _PROGRAMA_CMD_START=0
    local cmd_dur=0
    if [[ -n "$cmd_start" && "$cmd_start" != 0 ]]; then
        cmd_dur=$(( now - cmd_start ))
    fi

    if (( ! programa_has_unix_socket )); then
        if (( cmd_dur >= 2 || now - _PROGRAMA_PORTS_LAST_RUN >= 10 )); then
            _cmux_ports_kick refresh
        fi
        return 0
    fi

    [[ -n "$PROGRAMA_PANEL_ID" ]] || return 0
    local pwd="$PWD"

    _cmux_prompt_wrap_guard "$cmd_start" "$pwd"

    # Post-wake socket writes can occasionally leave a probe process wedged.
    # If one probe is stale, clear the guard so fresh async probes can resume.
    if [[ -n "$_PROGRAMA_GIT_JOB_PID" ]]; then
        if ! kill -0 "$_PROGRAMA_GIT_JOB_PID" 2>/dev/null; then
            _PROGRAMA_GIT_JOB_PID=""
            _PROGRAMA_GIT_JOB_STARTED_AT=0
        elif (( _PROGRAMA_GIT_JOB_STARTED_AT > 0 )) && (( now - _PROGRAMA_GIT_JOB_STARTED_AT >= _PROGRAMA_ASYNC_JOB_TIMEOUT )); then
            _PROGRAMA_GIT_JOB_PID=""
            _PROGRAMA_GIT_JOB_STARTED_AT=0
            _PROGRAMA_GIT_FORCE=1
        fi
    fi

    # CWD: keep the app in sync with the actual shell directory.
    # This is also the simplest way to test sidebar directory behavior end-to-end.
    if [[ "$pwd" != "$_PROGRAMA_PWD_LAST_PWD" ]]; then
        _PROGRAMA_PWD_LAST_PWD="$pwd"
        local workspace_id="" pwd_json params
        workspace_id="$(_cmux_relay_workspace_id)" || workspace_id="$PROGRAMA_TAB_ID"
        pwd_json="$(_cmux_json_escape "$pwd")"
        params="{\"workspace_id\":\"$workspace_id\",\"surface_id\":\"$PROGRAMA_PANEL_ID\",\"path\":\"$pwd_json\"}"
        _cmux_send_bg "$(_cmux_json_rpc_frame "surface.report_pwd" "$params")"
    fi

    # Git branch/dirty: update immediately on directory change, otherwise every ~3s.
    # While a foreground command is running, _cmux_start_git_head_watch probes HEAD
    # once per second so agent-initiated git checkouts still surface quickly.
    local should_git=0
    local git_head_changed=0

    # Git branch can change without a `git ...`-prefixed command (aliases like `gco`,
    # tools like `gh pr checkout`, etc.). Detect HEAD changes and force a refresh.
    if [[ "$pwd" != "$_PROGRAMA_GIT_HEAD_LAST_PWD" ]]; then
        _PROGRAMA_GIT_HEAD_LAST_PWD="$pwd"
        _PROGRAMA_GIT_HEAD_PATH="$(_cmux_git_resolve_head_path 2>/dev/null || true)"
        _PROGRAMA_GIT_HEAD_SIGNATURE=""
    fi
    if [[ -n "$_PROGRAMA_GIT_HEAD_PATH" ]]; then
        local head_signature
        head_signature="$(_cmux_git_head_signature "$_PROGRAMA_GIT_HEAD_PATH" 2>/dev/null || true)"
        if [[ -n "$head_signature" ]]; then
            if [[ -z "$_PROGRAMA_GIT_HEAD_SIGNATURE" ]]; then
                # The first observed HEAD value establishes the baseline for this
                # shell session. Don't treat it as a branch change or we'll clear
                # restore-seeded PR badges before the first background probe runs.
                _PROGRAMA_GIT_HEAD_SIGNATURE="$head_signature"
            elif [[ "$head_signature" != "$_PROGRAMA_GIT_HEAD_SIGNATURE" ]]; then
                _PROGRAMA_GIT_HEAD_SIGNATURE="$head_signature"
                git_head_changed=1
                # Treat HEAD file change like a git command — force-replace any
                # running probe so the sidebar picks up the new branch immediately.
                _PROGRAMA_GIT_FORCE=1
                _PROGRAMA_PR_FORCE=1
                should_git=1
            fi
        fi
    fi

    if [[ "$pwd" != "$_PROGRAMA_GIT_LAST_PWD" ]]; then
        should_git=1
    elif (( _PROGRAMA_GIT_FORCE )); then
        should_git=1
    elif (( now - _PROGRAMA_GIT_LAST_RUN >= 3 )); then
        should_git=1
    fi

    if (( should_git )); then
        local can_launch_git=1
        if [[ -n "$_PROGRAMA_GIT_JOB_PID" ]] && kill -0 "$_PROGRAMA_GIT_JOB_PID" 2>/dev/null; then
            # If a stale probe is still running but the cwd changed (or we just ran
            # a git command), restart immediately so branch state isn't delayed
            # until the next user command/prompt.
            # Note: this repeats the cwd check above on purpose. The first check
            # decides whether we should refresh at all; this one decides whether
            # an in-flight older probe can be reused vs. replaced.
            if [[ "$pwd" != "$_PROGRAMA_GIT_LAST_PWD" ]] || (( _PROGRAMA_GIT_FORCE )); then
                kill "$_PROGRAMA_GIT_JOB_PID" >/dev/null 2>&1 || true
                _PROGRAMA_GIT_JOB_PID=""
                _PROGRAMA_GIT_JOB_STARTED_AT=0
            else
                can_launch_git=0
            fi
        fi

        if (( can_launch_git )); then
            _PROGRAMA_GIT_FORCE=0
            _PROGRAMA_GIT_LAST_PWD="$pwd"
            _PROGRAMA_GIT_LAST_RUN=$now
            {
                _cmux_report_git_branch_for_path "$pwd"
            } >/dev/null 2>&1 &!
            _PROGRAMA_GIT_JOB_PID=$!
            _PROGRAMA_GIT_JOB_STARTED_AT=$now
        fi
    fi

    # Pull request metadata is remote state. Keep a lightweight background poll
    # alive while the shell is idle so gh-created PRs and merge status changes
    # appear even without another prompt.
    local should_restart_pr_poll=0
    local should_signal_pr_probe=0
    local pr_context_changed=0
    if [[ -n "$_PROGRAMA_PR_POLL_PWD" && "$pwd" != "$_PROGRAMA_PR_POLL_PWD" ]]; then
        pr_context_changed=1
    elif (( git_head_changed )); then
        pr_context_changed=1
    fi
    if [[ "$pwd" != "$_PROGRAMA_PR_POLL_PWD" ]]; then
        should_restart_pr_poll=1
    elif (( _PROGRAMA_PR_FORCE )); then
        if [[ -n "$_PROGRAMA_PR_POLL_PID" ]] && kill -0 "$_PROGRAMA_PR_POLL_PID" 2>/dev/null; then
            should_signal_pr_probe=1
        else
            should_restart_pr_poll=1
        fi
    elif [[ -z "$_PROGRAMA_PR_POLL_PID" ]] || ! kill -0 "$_PROGRAMA_PR_POLL_PID" 2>/dev/null; then
        should_restart_pr_poll=1
    fi

    if (( pr_context_changed )); then
        _cmux_pr_cache_clear
        _cmux_clear_pr_for_panel
    fi

    if (( should_signal_pr_probe )); then
        _PROGRAMA_PR_FORCE=0
        _cmux_pr_request_probe
    fi

    if (( should_restart_pr_poll )); then
        _PROGRAMA_PR_FORCE=0
        _cmux_start_pr_poll_loop "$pwd" 1
    fi

    # Ports: lightweight kick to the app's batched scanner.
    # - Periodic scan to avoid stale values.
    # - Forced scan when a long-running command returns to the prompt (common when stopping a server).
    if (( cmd_dur >= 2 || now - _PROGRAMA_PORTS_LAST_RUN >= 10 )); then
        _cmux_ports_kick refresh
    fi
}

# Ensure Resources/bin is at the front of PATH, and remove the app's
# Contents/MacOS entry so the GUI cmux binary cannot shadow the CLI cmux.
# Shell init (.zprofile/.zshrc) may prepend other dirs after launch.
# We fix this once on first prompt (after all init files have run).
_cmux_fix_path() {
    if [[ -n "${GHOSTTY_BIN_DIR:-}" ]]; then
        local gui_dir="${GHOSTTY_BIN_DIR%/}"
        local bin_dir="${gui_dir%/MacOS}/Resources/bin"
        if [[ -d "$bin_dir" ]]; then
            # Remove existing entries and re-prepend the CLI bin dir.
            local -a parts=("${(@s/:/)PATH}")
            parts=("${(@)parts:#$bin_dir}")
            parts=("${(@)parts:#$gui_dir}")
            PATH="${bin_dir}:${(j/:/)parts}"
        fi
    fi
    add-zsh-hook -d precmd _cmux_fix_path
}

_cmux_restore_terminal_identity_after_startup() {
    if [[ -n "${PROGRAMA_ZSH_RESTORE_TERM:-}" ]]; then
        builtin export TERM="$PROGRAMA_ZSH_RESTORE_TERM"
        builtin unset PROGRAMA_ZSH_RESTORE_TERM
    fi
}

_cmux_zshexit() {
    _cmux_stop_git_head_watch
    _cmux_stop_pr_poll_loop
}

autoload -Uz add-zsh-hook
add-zsh-hook preexec _cmux_preexec
add-zsh-hook precmd _cmux_precmd
add-zsh-hook precmd _cmux_fix_path
add-zsh-hook zshexit _cmux_zshexit
