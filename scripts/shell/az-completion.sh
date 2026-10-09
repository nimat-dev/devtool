# Tab completion for az in bash and zsh (zsh needs bashcompinit first; see zshrc).
# az uses argcomplete: when _ARGCOMPLETE is set it prints the candidates to file descriptor 8
# instead of running the command.
_devtools_az_complete() {
  local IFS=$'\013'
  local suppress=0
  if [ -n "${ZSH_VERSION:-}" ]; then setopt localoptions shwordsplit; fi
  if compopt +o nospace 2> /dev/null; then suppress=1; fi
  # shellcheck disable=SC2207
  COMPREPLY=($(IFS="$IFS" COMP_LINE="$COMP_LINE" COMP_POINT="$COMP_POINT" COMP_TYPE="${COMP_TYPE:-}" \
    _ARGCOMPLETE_COMP_WORDBREAKS="${COMP_WORDBREAKS:-}" _ARGCOMPLETE=1 _ARGCOMPLETE_SUPPRESS_SPACE=$suppress \
    "$1" 8>&1 9>&2 1> /dev/null 2> /dev/null))
  # shellcheck disable=SC2181
  if [[ $? != 0 ]]; then
    unset COMPREPLY
  elif [[ $suppress == 1 ]] && [[ ${COMPREPLY[0]:-} =~ [=/:]$ ]]; then
    compopt -o nospace
  fi
}
complete -o nospace -o default -F _devtools_az_complete az
