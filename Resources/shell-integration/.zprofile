# vim:ft=zsh
#
# Compatibility shim: with the current integration model, programa restores
# ZDOTDIR in .zshenv so this file should never be reached. If it is, restore
# ZDOTDIR and behave like vanilla zsh by sourcing the user's .zprofile.

if [[ -n "${GHOSTTY_ZSH_ZDOTDIR+X}" ]]; then
    builtin export ZDOTDIR="$GHOSTTY_ZSH_ZDOTDIR"
    builtin unset GHOSTTY_ZSH_ZDOTDIR
elif [[ -n "${PROGRAMA_ZSH_ZDOTDIR+X}" ]]; then
    builtin export ZDOTDIR="$PROGRAMA_ZSH_ZDOTDIR"
    builtin unset PROGRAMA_ZSH_ZDOTDIR
else
    builtin unset ZDOTDIR
fi

builtin typeset _programa_file="${ZDOTDIR-$HOME}/.zprofile"
[[ ! -r "$_programa_file" ]] || builtin source -- "$_programa_file"
builtin unset _programa_file
