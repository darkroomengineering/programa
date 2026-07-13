# Programa bash prompt bootstrap.
#
# macOS ships /bin/bash 3.2, where Ghostty's automatic bash integration is
# unsupported and HOME-based wrapper startup is not reliable. Programa instead
# exports this script as PROMPT_COMMAND so it runs once on the first
# interactive prompt: it sources Programa's bash integration and then hands
# control to _programa_prompt_command.
#
# This file is the single source of truth. Sources/GhosttyTerminalView.swift
# reads it (stripping these comments) and exports it as PROMPT_COMMAND, and
# programaTests/GhosttyConfigTests.swift exercises it.
unset PROMPT_COMMAND
if [[ "${PROGRAMA_LOAD_GHOSTTY_BASH_INTEGRATION:-0}" == "1" && -n "${GHOSTTY_RESOURCES_DIR:-}" ]]; then
    _programa_ghostty_bash="$GHOSTTY_RESOURCES_DIR/shell-integration/bash/ghostty.bash"
    [[ -r "$_programa_ghostty_bash" ]] && source "$_programa_ghostty_bash"
fi
if [[ "${PROGRAMA_SHELL_INTEGRATION:-1}" != "0" && -n "${PROGRAMA_SHELL_INTEGRATION_DIR:-}" ]]; then
    _programa_bash_integration="$PROGRAMA_SHELL_INTEGRATION_DIR/programa-bash-integration.bash"
    [[ -r "$_programa_bash_integration" ]] && source "$_programa_bash_integration"
fi
unset _programa_ghostty_bash _programa_bash_integration
if declare -F _programa_prompt_command >/dev/null 2>&1; then _programa_prompt_command; fi
