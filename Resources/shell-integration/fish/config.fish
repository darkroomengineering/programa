# programa shell integration for fish
# Injected automatically — do not source manually

set -l _cmux_integration_enabled 1
if set -q PROGRAMA_SHELL_INTEGRATION; and test "$PROGRAMA_SHELL_INTEGRATION" = 0
    set _cmux_integration_enabled 0
end

function _cmux_restore_scrollback_once
    set -l path "$PROGRAMA_RESTORE_SCROLLBACK_FILE"
    test -n "$path"; or return 0
    set -e PROGRAMA_RESTORE_SCROLLBACK_FILE

    if test -r "$path"
        /bin/cat -- "$path" 2>/dev/null
        /bin/rm -f -- "$path" >/dev/null 2>&1
    end
end
_cmux_restore_scrollback_once

if test "$_cmux_integration_enabled" != 0
    set -g _CMUX_SEND_TOOL ""
    if command -sq ncat
        set -g _CMUX_SEND_TOOL ncat
    else if command -sq socat
        set -g _CMUX_SEND_TOOL socat
    else if command -sq nc
        set -g _CMUX_SEND_TOOL nc
    end

    set -g _PROGRAMA_SHELL_ACTIVITY_LAST ""
    set -g _PROGRAMA_PORTS_LAST_RUN 0
    set -g _PROGRAMA_TTY_NAME ""
    set -g _PROGRAMA_TTY_REPORTED 0
    set -g _PROGRAMA_TMUX_PUSH_SIGNATURE ""
    set -g _PROGRAMA_TMUX_PULL_SIGNATURE ""
    set -g _PROGRAMA_TMUX_SYNC_KEYS \
        PROGRAMA_BUNDLED_CLI_PATH \
        PROGRAMA_BUNDLE_ID \
        CMUXD_UNIX_PATH \
        CMUXTERM_REPO_ROOT \
        PROGRAMA_DEBUG_LOG \
        PROGRAMA_PORT \
        PROGRAMA_PORT_END \
        PROGRAMA_PORT_RANGE \
        PROGRAMA_REMOTE_DAEMON_ALLOW_LOCAL_BUILD \
        PROGRAMA_SHELL_INTEGRATION \
        PROGRAMA_SHELL_INTEGRATION_DIR \
        PROGRAMA_SOCKET_ENABLE \
        PROGRAMA_SOCKET_MODE \
        PROGRAMA_SOCKET_PATH \
        PROGRAMA_TAB_ID \
        PROGRAMA_TAG \
        PROGRAMA_WORKSPACE_ID
    set -g _PROGRAMA_TMUX_SURFACE_SCOPED_KEYS PROGRAMA_PANEL_ID PROGRAMA_SURFACE_ID

    function _cmux_now
        if set -q EPOCHSECONDS
            printf '%s\n' "$EPOCHSECONDS"
        else
            date +%s
        end
    end

    function _cmux_socket_is_unix
        test -n "$PROGRAMA_SOCKET_PATH"; and test -S "$PROGRAMA_SOCKET_PATH"
    end

    function _cmux_relay_cli_path
        if test -n "$PROGRAMA_BUNDLED_CLI_PATH"; and test -x "$PROGRAMA_BUNDLED_CLI_PATH"
            printf '%s\n' "$PROGRAMA_BUNDLED_CLI_PATH"
            return 0
        end
        # Rebranded CLI binary ships as "programa"; fall back to the pre-rebrand
        # "cmux" name for older installs that only symlinked that binary.
        command -v programa 2>/dev/null; or command -v cmux 2>/dev/null
    end

    function _cmux_socket_uses_remote_relay
        test -n "$PROGRAMA_SOCKET_PATH"; or return 1
        string match -q '/*' -- "$PROGRAMA_SOCKET_PATH"; and return 1
        string match -q '*:*' -- "$PROGRAMA_SOCKET_PATH"; or return 1
        set -l relay_cli (_cmux_relay_cli_path)
        test -n "$relay_cli"
    end

    function _cmux_has_port_scan_transport
        _cmux_socket_is_unix; and return 0
        _cmux_socket_uses_remote_relay
    end

    function _cmux_send --argument-names payload
        test -n "$payload"; or return 0
        test -n "$PROGRAMA_SOCKET_PATH"; or return 0
        switch "$_CMUX_SEND_TOOL"
            case ncat
                printf '%s\n' "$payload" | ncat -w 1 -U "$PROGRAMA_SOCKET_PATH" --send-only >/dev/null 2>&1
            case socat
                printf '%s\n' "$payload" | socat -T 1 - "UNIX-CONNECT:$PROGRAMA_SOCKET_PATH" >/dev/null 2>&1
            case nc
                printf '%s\n' "$payload" | nc -N -U "$PROGRAMA_SOCKET_PATH" >/dev/null 2>&1; or printf '%s\n' "$payload" | nc -w 1 -U "$PROGRAMA_SOCKET_PATH" >/dev/null 2>&1
        end
    end

    function _cmux_send_bg --argument-names payload
        _cmux_send "$payload" >/dev/null 2>&1 &
    end

    function _cmux_json_escape --argument-names value
        set -l backslash "\\"
        set -l escaped_backslash "\\\\"
        set -l quote '"'
        set -l escaped_quote '\"'
        string replace -a "$backslash" "$escaped_backslash" -- "$value" \
            | string replace -a "$quote" "$escaped_quote" \
            | string replace -a (printf '\n') "\\n" \
            | string replace -a (printf '\r') "\\r" \
            | string replace -a (printf '\t') "\\t"
    end

    # Build a single-line v2 JSON-RPC request frame for the direct-socket
    # (fire-and-forget) path. `params_json` must already be a well-formed JSON
    # object string (call sites use _cmux_json_escape on any user-controlled
    # values before interpolating them).
    function _cmux_json_rpc_frame --argument-names method params_json
        printf '%s\n' "{\"id\":1,\"method\":\"$method\",\"params\":$params_json}"
    end

    function _cmux_relay_workspace_id
        if test -n "$PROGRAMA_WORKSPACE_ID"
            printf '%s\n' "$PROGRAMA_WORKSPACE_ID"
            return 0
        end
        test -n "$PROGRAMA_TAB_ID"; or return 1
        printf '%s\n' "$PROGRAMA_TAB_ID"
    end

    function _cmux_relay_rpc_bg --argument-names method params
        _cmux_socket_uses_remote_relay; or return 1
        set -l relay_cli (_cmux_relay_cli_path)
        test -n "$relay_cli"; or return 1
        "$relay_cli" rpc "$method" "$params" >/dev/null 2>&1 &
    end

    function _cmux_relay_rpc --argument-names method params
        _cmux_socket_uses_remote_relay; or return 1
        set -l relay_cli (_cmux_relay_cli_path)
        test -n "$relay_cli"; or return 1
        # Relay `programa rpc` exits nonzero on server error. The real remote CLI
        # prints only the JSON result payload on success, while some test stubs
        # return the full `{"ok":...}` envelope. Retry only on explicit `ok:false`.
        set -l response ("$relay_cli" rpc "$method" "$params" 2>/dev/null | string collect)
        test -n "$response"; or return 0
        string match -q '*"ok":false*' -- "$response"; and return 1
        string match -q '*"ok": false*' -- "$response"; and return 1
        return 0
    end

    function _cmux_report_tty_via_relay
        _cmux_socket_uses_remote_relay; or return 1
        set -l workspace_id (_cmux_relay_workspace_id); or return 1
        test -n "$_PROGRAMA_TTY_NAME"; or return 1
        set -l tty_name_json (_cmux_json_escape "$_PROGRAMA_TTY_NAME")
        set -l params "{\"workspace_id\":\"$workspace_id\",\"tty_name\":\"$tty_name_json\""
        if test -n "$PROGRAMA_PANEL_ID"
            set params "$params,\"surface_id\":\"$PROGRAMA_PANEL_ID\""
        end
        set params "$params}"
        _cmux_relay_rpc "surface.report_tty" "$params"
    end

    function _cmux_report_tty_payload
        test -n "$PROGRAMA_TAB_ID"; or return 1
        test -n "$_PROGRAMA_TTY_NAME"; or return 1
        set -l workspace_id (_cmux_relay_workspace_id)
        test -n "$workspace_id"; or set workspace_id "$PROGRAMA_TAB_ID"
        set -l tty_name_json (_cmux_json_escape "$_PROGRAMA_TTY_NAME")
        set -l params "{\"workspace_id\":\"$workspace_id\",\"tty_name\":\"$tty_name_json\""
        if test -z "$TMUX"
            test -n "$PROGRAMA_PANEL_ID"; or return 1
            set params "$params,\"surface_id\":\"$PROGRAMA_PANEL_ID\""
        end
        set params "$params}"
        _cmux_json_rpc_frame "surface.report_tty" "$params"
    end

    function _cmux_report_tty_once
        # Send the TTY name to the app once per session so the batched port
        # scanner knows which TTY belongs to this panel.
        test "$_PROGRAMA_TTY_REPORTED" = 1; and return 0
        _cmux_has_port_scan_transport; or return 0

        if _cmux_socket_is_unix
            set -l payload (_cmux_report_tty_payload)
            test -n "$payload"; or return 0
            set -g _PROGRAMA_TTY_REPORTED 1
            _cmux_send_bg "$payload"
        else
            test -n "$_PROGRAMA_TTY_NAME"; or return 0
            # Keep the first relay TTY report synchronous so the server can
            # resolve the target surface before command-start kicks begin.
            _cmux_report_tty_via_relay; or return 0
            set -g _PROGRAMA_TTY_REPORTED 1
        end
    end

    function _cmux_report_shell_activity_state --argument-names state
        test -n "$state"; or return 0
        _cmux_socket_is_unix; or return 0
        test -n "$PROGRAMA_TAB_ID"; or return 0
        test -n "$PROGRAMA_PANEL_ID"; or return 0
        test "$_PROGRAMA_SHELL_ACTIVITY_LAST" = "$state"; and return 0
        set -g _PROGRAMA_SHELL_ACTIVITY_LAST "$state"
        set -l workspace_id (_cmux_relay_workspace_id)
        test -n "$workspace_id"; or set workspace_id "$PROGRAMA_TAB_ID"
        set -l state_json (_cmux_json_escape "$state")
        set -l params "{\"workspace_id\":\"$workspace_id\",\"surface_id\":\"$PROGRAMA_PANEL_ID\",\"state\":\"$state_json\"}"
        _cmux_send_bg (_cmux_json_rpc_frame "surface.report_shell_state" "$params")
    end

    function _cmux_ports_kick_via_relay --argument-names reason
        _cmux_socket_uses_remote_relay; or return 1
        set -l workspace_id (_cmux_relay_workspace_id); or return 1
        test -n "$reason"; or set reason command
        set -l params "{\"workspace_id\":\"$workspace_id\",\"reason\":\"$reason\""
        if test -n "$PROGRAMA_PANEL_ID"
            set params "$params,\"surface_id\":\"$PROGRAMA_PANEL_ID\""
        end
        set params "$params}"
        _cmux_relay_rpc_bg "surface.ports_kick" "$params"
    end

    function _cmux_ports_kick --argument-names reason
        test -n "$reason"; or set reason command
        # Lightweight: just tell the app to run a batched scan for this panel.
        # The app coalesces kicks across all panels and runs a single ps+lsof.
        _cmux_has_port_scan_transport; or return 0
        test -n "$PROGRAMA_TAB_ID"; or return 0
        if _cmux_socket_is_unix
            test -n "$PROGRAMA_PANEL_ID"; or return 0
        end
        set -g _PROGRAMA_PORTS_LAST_RUN (_cmux_now)
        if _cmux_socket_is_unix
            set -l workspace_id (_cmux_relay_workspace_id)
            test -n "$workspace_id"; or set workspace_id "$PROGRAMA_TAB_ID"
            set -l reason_json (_cmux_json_escape "$reason")
            set -l params "{\"workspace_id\":\"$workspace_id\",\"surface_id\":\"$PROGRAMA_PANEL_ID\",\"reason\":\"$reason_json\"}"
            _cmux_send_bg (_cmux_json_rpc_frame "surface.ports_kick" "$params")
        else
            _cmux_ports_kick_via_relay "$reason"
        end
    end

    function _cmux_reset_terminal_keyboard_protocols
        isatty stdout; or test -n "$PROGRAMA_TEST_FORCE_KEYBOARD_RESET$PROGRAMA_TEST_FORCE_KITTY_RESET"; or return 0
        printf '\033[>m\033[<8u'
    end

    function _cmux_tmux_sync_key_is_managed --argument-names candidate
        contains -- "$candidate" $_PROGRAMA_TMUX_SYNC_KEYS
    end

    function _cmux_tmux_shell_env_signature
        set -l parts
        for key in $_PROGRAMA_TMUX_SYNC_KEYS
            set -l value $$key
            test -n "$value"; or continue
            set -a parts "$key=$value"
        end
        string join \x1f -- $parts
    end

    function _cmux_tmux_publish_cmux_environment
        test -z "$TMUX"; or return 0
        command -sq tmux; or return 0

        set -l signature (_cmux_tmux_shell_env_signature)
        test -n "$signature"; or return 0
        test "$signature" != "$_PROGRAMA_TMUX_PUSH_SIGNATURE"; or return 0

        for key in $_PROGRAMA_TMUX_SYNC_KEYS
            set -l value $$key
            test -n "$value"; or continue
            tmux set-environment -g "$key" "$value" >/dev/null 2>&1; or return 0
        end
        for key in $_PROGRAMA_TMUX_SURFACE_SCOPED_KEYS
            tmux set-environment -gu "$key" >/dev/null 2>&1; or return 0
        end

        set -g _PROGRAMA_TMUX_PUSH_SIGNATURE "$signature"
    end

    function _cmux_tmux_refresh_cmux_environment
        test -n "$TMUX"; or return 0
        command -sq tmux; or return 0

        set -l output (tmux show-environment -g 2>/dev/null)
        test -n "$output"; or return 0

        set -l filtered
        for line in $output
            string match -q 'PROGRAMA_*' -- "$line"; or continue
            set -l key (string split -m 1 = -- "$line")[1]
            _cmux_tmux_sync_key_is_managed "$key"; or continue
            set -a filtered "$line"
        end
        test -n "$filtered"; or return 0
        set -l joined (string join \n -- $filtered)
        test "$joined" != "$_PROGRAMA_TMUX_PULL_SIGNATURE"; or return 0

        set -l did_change 0
        for line in $filtered
            set -l parts (string split -m 1 = -- "$line")
            set -l key $parts[1]
            _cmux_tmux_sync_key_is_managed "$key"; or continue
            set -l value $parts[2]
            if test "$$key" != "$value"
                set -gx $key "$value"
                set did_change 1
            end
        end

        set -g _PROGRAMA_TMUX_PULL_SIGNATURE "$joined"
        if test "$did_change" = 1
            set -g _PROGRAMA_TTY_REPORTED 0
            set -g _PROGRAMA_SHELL_ACTIVITY_LAST ""
        end
    end

    function _cmux_tmux_sync_cmux_environment
        if test -n "$TMUX"
            _cmux_tmux_refresh_cmux_environment
        else
            _cmux_tmux_publish_cmux_environment
        end
    end

    function _cmux_preexec --on-event fish_preexec
        _cmux_tmux_sync_cmux_environment
        _cmux_report_tty_once
        _cmux_report_shell_activity_state running
        _cmux_ports_kick command
    end

    function _cmux_prompt --on-event fish_prompt
        _cmux_reset_terminal_keyboard_protocols
        _cmux_tmux_sync_cmux_environment
        _cmux_report_tty_once
        _cmux_report_shell_activity_state prompt
        set -l now (_cmux_now)
        if test (math "$now - $_PROGRAMA_PORTS_LAST_RUN") -ge 5
            _cmux_ports_kick refresh
        end
    end
end

# --- User config chain-load -------------------------------------------------
# Our bootstrap points fish at this file via `--init-command 'source ...'` on a
# plain `fish -il` invocation, so fish's own normal login-shell startup already
# ran the user's real ~/.config/fish/config.fish, functions/, completions/, and
# conf.d/*.fish *before* this file was sourced (Swift sets
# PROGRAMA_FISH_USER_CONFIG_ALREADY_LOADED=1 for that path — see
# GhosttyTerminalView.swift). This block only fires when that flag is absent,
# e.g. a future remote-relay bootstrap that overrides HOME/XDG_CONFIG_HOME
# before fish's normal startup can find the real user config.
set -l _cmux_user_config_home ""
if set -q PROGRAMA_FISH_CONFIG_HOME
    set _cmux_user_config_home "$PROGRAMA_FISH_CONFIG_HOME"
else if set -q HOME
    set _cmux_user_config_home "$HOME/.config"
end

set -l _cmux_user_config "$_cmux_user_config_home/fish/config.fish"
if not set -q PROGRAMA_FISH_USER_CONFIG_ALREADY_LOADED; and test -n "$_cmux_user_config_home"; and test "$_cmux_user_config_home" != "$XDG_CONFIG_HOME"
    set -gx XDG_CONFIG_HOME "$_cmux_user_config_home"

    set -l _cmux_user_functions "$_cmux_user_config_home/fish/functions"
    if test -d "$_cmux_user_functions"; and not contains -- "$_cmux_user_functions" $fish_function_path
        set -g fish_function_path "$_cmux_user_functions" $fish_function_path
    end

    set -l _cmux_user_completions "$_cmux_user_config_home/fish/completions"
    if test -d "$_cmux_user_completions"; and not contains -- "$_cmux_user_completions" $fish_complete_path
        set -g fish_complete_path "$_cmux_user_completions" $fish_complete_path
    end

    for _cmux_user_conf in "$_cmux_user_config_home"/fish/conf.d/*.fish
        if test -r "$_cmux_user_conf"
            source "$_cmux_user_conf"
        end
    end

    if test -r "$_cmux_user_config"
        source "$_cmux_user_config"
    end
end
