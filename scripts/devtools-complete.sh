#!/usr/bin/env bash
# devtools-complete TOOL LINE [POINT]
#
# Tab-completion candidates for a command line typed in PowerShell on Windows. The real tools
# exist only inside this image, so the PowerShell wrappers (Devtools.psm1) ask here, one
# container per Tab press.
#
#   TOOL    az, terraform, or a Cobra tool: kubectl, helm, flux, kustomize, azd, gh
#   LINE    what has been typed so far, starting with the tool name
#   POINT   cursor position in LINE (default: the end)
#
# Prints one candidate per line, either "value" or "value<TAB>description". Prints nothing and
# exits 0 when there is nothing to offer, the tool fails, or it takes too long: a Tab press must
# never hang or break the prompt.
set -u

tool=${1:-}
line=${2:-}
point=${3:-${#line}}

case $tool in
  az|terraform|kubectl|helm|flux|kustomize|azd|gh) ;;
  *) exit 0 ;;
esac
case $point in
  ''|*[!0-9]*) point=${#line} ;;
esac
if [ "$point" -gt "${#line}" ]; then point=${#line}; fi

prefix=${line:0:point}
read -r -a words <<< "$prefix"
if [ "${#words[@]}" -eq 0 ]; then exit 0; fi

# The word being completed is the last one, unless the cursor sits after a space.
if [[ $prefix =~ [[:space:]]$ ]]; then
  current=''
else
  current=${words[${#words[@]}-1]}
  words=("${words[@]:0:${#words[@]}-1}")
fi
# Nothing before the cursor but the command name itself: nothing to complete.
if [ "${#words[@]}" -eq 0 ]; then exit 0; fi

# az: argcomplete. With _ARGCOMPLETE set, az prints the candidates to a file instead of running.
complete_az() {
  local tmp
  tmp=$(mktemp) || return 0
  _ARGCOMPLETE=1 ARGCOMPLETE_USE_TEMPFILES=1 _ARGCOMPLETE_STDOUT_FILENAME=$tmp \
    COMP_LINE=$prefix COMP_POINT=${#prefix} \
    _ARGCOMPLETE_SUPPRESS_SPACE=0 _ARGCOMPLETE_IFS=$'\n' _ARGCOMPLETE_SHELL=powershell \
    timeout 8 az > /dev/null 2>&1
  cat "$tmp" 2> /dev/null
  rm -f "$tmp"
}

# terraform: prints the candidates itself when COMP_LINE is set (what "complete -C" relies on).
complete_terraform() {
  COMP_LINE=$prefix COMP_POINT=${#prefix} timeout 5 terraform 2> /dev/null
}

# Cobra tools (kubectl, helm, flux, ...): the hidden __complete command prints the candidates,
# then a last line ":<directive>". The directive's lowest bit means "error": offer nothing.
complete_cobra() {
  local out directive='' last
  local -a rows=()
  out=$(timeout 5 "$tool" __complete "${words[@]:1}" "$current" 2> /dev/null) || true
  while IFS= read -r row; do
    if [ -n "$row" ]; then rows+=("$row"); fi
  done <<< "$out"
  if [ "${#rows[@]}" -eq 0 ]; then return 0; fi
  last=${rows[${#rows[@]}-1]}
  if [[ $last =~ ^:([0-9]+)$ ]]; then
    directive=${BASH_REMATCH[1]}
    rows=("${rows[@]:0:${#rows[@]}-1}")
  fi
  if [ -n "$directive" ] && [ $((directive & 1)) -eq 1 ]; then return 0; fi
  if [ "${#rows[@]}" -gt 0 ]; then printf '%s\n' "${rows[@]}"; fi
}

case $tool in
  az)        complete_az ;;
  terraform) complete_terraform ;;
  *)         complete_cobra ;;
esac | head -n 300
exit 0
