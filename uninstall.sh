#!/usr/bin/env bash
# uninstall.sh - stops the DevOps toolbox and removes its bash setup. The undo for setup.sh.
# The bash twin of uninstall.ps1.
#
# From the project folder (no admin rights needed):
#
#     ./uninstall.sh            (or:  bash uninstall.sh)
#
#   1  removes the devtools.sh line from your bash startup files (a .bak copy is kept), and the
#      line setup.sh added so that login shells read ~/.bashrc
#   2  tells you how to unload the functions from terminals that are open now
#   3  stops and removes the toolbox containers: docker compose down, then anything still running
#      from the image, such as a "dev" shell open in another terminal
#   4  only when you ask: deletes the image and/or the volume that holds your saved logins
#
# The image takes minutes to build and the volume holds your Azure, GitHub and Kubernetes logins,
# so both are KEPT unless you pass --remove-image / --remove-volume. The project folder and .env
# are never touched, and neither is your own shortcuts file (~/.devtools-aliases.sh, or the file
# named by DEVTOOLS_BASH_ALIASES), which holds what you wrote yourself. With the line gone, new
# terminals have no shortcuts, Tab completion or arrow-key history search from the toolbox. Run
# setup.sh to put everything back.
#
# Safe to run again at any time. It works without Docker running: the startup files are cleaned
# first. Only the default names are handled (image devtools:latest, volumes devtools-home and
# devtools_devtools-home), not ones you chose with DEVTOOLS_IMAGE or DEVTOOLS_VOLUME.
# Exit code: 0 done, 1 could not run, 2 finished but something above failed.
#
# Options:
#   --remove-image    Also delete the image devtools:latest (setup.sh builds it again).
#   --remove-volume   Also delete the volume with your saved logins. Asks first.
#   --force           Do not ask before deleting the volume.
#   --skip-profile    Do not touch your startup files (new terminals then load the toolbox again).
#   --no-prompt       Never ask a question (for automation). The volume is then deleted only with --force.
#   --rc-file FILE    Clean this one file instead of looking through your startup files.
#   -h, --help        This text.
#
# The part before the version check below is kept free of newer bash syntax, so that an old bash
# (macOS ships 3.2) gets the plain message instead of a syntax error.

set -u

# shellcheck disable=SC2317
if [ -z "${BASH_VERSION:-}" ]; then
  echo "uninstall.sh is for bash. In PowerShell run uninstall.ps1." >&2
  exit 1
fi
# shellcheck disable=SC2317
if [ "${BASH_VERSINFO[0]}" -lt 4 ] || { [ "${BASH_VERSINFO[0]}" -eq 4 ] && [ "${BASH_VERSINFO[1]}" -lt 2 ]; }; then
  echo "uninstall.sh needs bash 4.2 or newer (this is bash $BASH_VERSION). On macOS: brew install bash, then run this with that bash." >&2
  exit 1
fi
# shellcheck disable=SC2317
if [ "${BASH_SOURCE[0]}" != "$0" ]; then
  echo "Run uninstall.sh, do not source it:  ./uninstall.sh" >&2
  return 1 2> /dev/null || exit 1
fi

usage() {
  sed -n '2,/^# The part before/p' "${BASH_SOURCE[0]}" | sed -e '$d' -e 's/^# \{0,1\}//'
}

remove_image=0 remove_volume=0 force=0 skip_profile=0 no_prompt=0 rc_file=''
while [ $# -gt 0 ]; do
  case $1 in
    --remove-image) remove_image=1 ;;
    --remove-volume) remove_volume=1 ;;
    --force) force=1 ;;
    --skip-profile) skip_profile=1 ;;
    --no-prompt) no_prompt=1 ;;
    --rc-file)
      if [ $# -lt 2 ]; then echo "--rc-file needs a file name" >&2; exit 1; fi
      rc_file=$2
      shift ;;
    --rc-file=*) rc_file=${1#--rc-file=} ;;
    -h | --help) usage; exit 0 ;;
    *) echo "Unknown option: $1  (see ./uninstall.sh --help)" >&2; exit 1 ;;
  esac
  shift
done

here=${BASH_SOURCE[0]%/*}
if [ "$here" = "${BASH_SOURCE[0]}" ]; then here=.; fi
root=$(CDPATH='' cd -- "$here" 2> /dev/null && pwd) || { echo "Cannot work out which folder uninstall.sh is in." >&2; exit 1; }
image=devtools:latest
volumes=(devtools-home devtools_devtools-home)    # the wrappers' volume, and the one docker compose makes
aliases_file=${DEVTOOLS_BASH_ALIASES:-$HOME/.devtools-aliases.sh}
problems=0

# What setup.sh puts in the startup files. Keep these in step with setup.sh (the tests check it).
marker='# DevOps toolbox: az, kubectl, terraform, helm, flux ... run in Docker'
login_marker='# DevOps toolbox: make login shells read ~/.bashrc too'
login_line='[ -r ~/.bashrc ] && . ~/.bashrc'
rx_import="^[[:space:]]*(\\.|source)[[:space:]]+.*devtools\\.sh[\"']?[[:space:]]*\$"

# ---- output helpers --------------------------------------------------------------------------
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
  c_cyan=$'\e[36m' c_green=$'\e[32m' c_yellow=$'\e[33m' c_red=$'\e[31m' c_off=$'\e[0m'
else
  c_cyan='' c_green='' c_yellow='' c_red='' c_off=''
fi
step() { printf '\n%s== %s%s\n' "$c_cyan" "$1" "$c_off"; }
ok() { printf '  %sOK%s    %s\n' "$c_green" "$c_off" "$1"; }
warn() { printf '  %sWARN%s  %s\n' "$c_yellow" "$c_off" "$1"; }
fail() { printf '  %sFAIL%s  %s\n' "$c_red" "$c_off" "$1"; }
info() { printf '        %s\n' "$1"; }

# ---- small helpers ---------------------------------------------------------------------------
# Docker exactly as given: Git Bash must not turn /work or a {{.Server.Os}}/... format into a Windows path.
dk() { MSYS_NO_PATHCONV=1 MSYS2_ARG_CONV_EXCL='*' command docker "$@"; }

# Run a command with its output captured into OUT and its exit code into CODE. Never stops the script.
quiet() {
  OUT=$("$@" 2>&1 < /dev/null)
  CODE=$?
  OUT=${OUT//$'\r'/} # docker.exe on Windows ends its lines with CR LF
}

trim() {
  local s=$1
  s=${s#"${s%%[![:space:]]*}"}
  s=${s%"${s##*[![:space:]]}"}
  printf '%s' "$s"
}

# The first line of some text that is not blank, trimmed and cut to $2 characters.
first_line() {
  local l
  while IFS= read -r l; do
    l=$(trim "$l")
    if [ -n "$l" ]; then printf '%s' "${l:0:${2:-160}}"; return 0; fi
  done <<< "$1"
  return 1
}

# Read a file into LINES (one element per line) and say whether it ended with a newline.
read_lines() {
  local line=''
  LINES=()
  TRAILING_NL=1
  while IFS= read -r line; do LINES+=("$line"); done < "$1"
  if [ -n "$line" ]; then
    LINES+=("$line")
    TRAILING_NL=0
  fi
}

# Write LINES back; the file ends with a newline when it did before.
write_lines() {
  local i=0 last=$((${#LINES[@]} - 1))
  : > "$1" || return 1
  while [ "$i" -le "$last" ]; do
    if [ "$i" -lt "$last" ] || [ "$TRAILING_NL" = 1 ]; then
      printf '%s\n' "${LINES[$i]}" >> "$1" || return 1
    else
      printf '%s' "${LINES[$i]}" >> "$1" || return 1
    fi
    i=$((i + 1))
  done
}

# Every startup file that might hold the toolbox lines. A file named with --rc-file is used on its own.
startup_files() {
  if [ -n "$rc_file" ]; then
    printf '%s\n' "$rc_file"
    return 0
  fi
  local f
  for f in "$HOME/.bashrc" "$HOME/.bash_profile" "$HOME/.bash_login" "$HOME/.profile"; do
    printf '%s\n' "$f"
  done
}

# Take the toolbox lines out of one startup file; everything else stays exactly as it was. Sets
# CHANGED (0/1), REMOVED (the lines taken out) and LEFT (lines that still mention devtools.sh).
remove_toolbox_lines() {
  local file=$1 i l t n
  local -a kept=()
  CHANGED=0 REMOVED=() LEFT=()
  read_lines "$file"
  n=${#LINES[@]}

  # Pass 1: the lines that load devtools.sh.
  i=0
  while [ "$i" -lt "$n" ]; do
    if [[ ${LINES[$i]} =~ $rx_import ]]; then
      REMOVED+=("$(trim "${LINES[$i]}")")
      CHANGED=1
    else
      kept+=("${LINES[$i]}")
    fi
    i=$((i + 1))
  done

  # Pass 2: the comment above them, and the stanza that makes login shells read ~/.bashrc, each with
  # the blank line that precedes it.
  local -a out=()
  local skip_next=0
  i=0
  n=${#kept[@]}
  while [ "$i" -lt "$n" ]; do
    l=${kept[$i]}
    t=$(trim "$l")
    if [ "$skip_next" = 1 ]; then
      skip_next=0
      if [ "$t" = "$login_line" ]; then
        REMOVED+=("$t")
        CHANGED=1
        i=$((i + 1))
        continue
      fi
    fi
    if [ "$t" = "$marker" ] || [ "$t" = "$login_marker" ]; then
      if [ "$t" = "$login_marker" ]; then skip_next=1; fi
      if [ "${#out[@]}" -gt 0 ]; then
        l=$(trim "${out[${#out[@]} - 1]}")
        if [ -z "$l" ]; then unset "out[${#out[@]}-1]"; fi
      fi
      CHANGED=1
      i=$((i + 1))
      continue
    fi
    out+=("$l")
    i=$((i + 1))
  done

  if [ "$CHANGED" = 1 ]; then
    write_lines "$file.bak" || return 1          # LINES still holds the file as it was
    if [ "${#out[@]}" -gt 0 ]; then LINES=("${out[@]}"); else LINES=(); fi
    write_lines "$file" || return 1
  fi

  # A line this cleanup does not recognise (an "if [ -f ... ]; then . .../devtools.sh; fi" you wrote yourself).
  if [ "${#out[@]}" -gt 0 ]; then
    i=0
    while [ "$i" -lt "${#out[@]}" ]; do
      t=$(trim "${out[$i]}")
      case $t in
        '#'*) ;;
        *devtools.sh*) LEFT+=("line $((i + 1)): $t") ;;
      esac
      i=$((i + 1))
    done
  fi
  return 0
}

echo "${c_cyan}DevOps toolbox uninstall  ($root)${c_off}"

# ---- 1. Startup files ------------------------------------------------------------------------
step '1/4  bash startup files'
if [ "$skip_profile" = 1 ]; then
  info 'skipped (--skip-profile): new terminals will still load the toolbox'
else
  before=$problems
  cleaned=0
  looked=()
  while IFS= read -r file; do
    if [ ! -f "$file" ]; then continue; fi
    looked+=("$file")
    if remove_toolbox_lines "$file" 2> /dev/null; then
      if [ "$CHANGED" = 1 ]; then
        cleaned=$((cleaned + 1))
        ok "cleaned $file"
        for l in "${REMOVED[@]+"${REMOVED[@]}"}"; do info "removed: $l"; done
        info "backup:  $file.bak"
      fi
      for l in "${LEFT[@]+"${LEFT[@]}"}"; do
        warn "$file still mentions devtools.sh, $l"
        info 'It is not a plain line that loads it, so it was left alone. Delete it by hand.'
        problems=$((problems + 1))
      done
    else
      # Locked-down machines: a read-only home folder, a managed dotfile ...
      fail "Could not update $file"
      info 'Open it in an editor and delete the line that loads devtools.sh.'
      problems=$((problems + 1))
    fi
  done < <(startup_files)
  if [ "$cleaned" -eq 0 ] && [ "$problems" -eq "$before" ]; then
    ok 'no toolbox line in your bash startup files, nothing to remove'
    if [ "${#looked[@]}" -eq 0 ]; then info 'no startup file exists'; fi
    for file in "${looked[@]+"${looked[@]}"}"; do info "looked in: $file"; done
  fi
fi

# ---- 2. Open terminals -----------------------------------------------------------------------
step '2/4  Terminals that are open now'
info 'A script cannot change the terminal it was started from. Terminals that are open keep the'
info 'toolbox until you close them, or run this in them:  devtools-unload'

# ---- 3. Stop the toolbox ---------------------------------------------------------------------
step '3/4  Stop the toolbox'
docker_ready=0
docker_why=''
docker_hint='The toolbox only runs inside Docker, so there is nothing to stop.'
if ! type -P docker > /dev/null 2>&1; then
  docker_why='docker was not found on PATH'
else
  quiet dk version --format '{{.Server.Os}}/{{.Server.Version}}'
  engine=''
  while IFS= read -r l; do
    if [[ $l =~ ^[A-Za-z]+/[^[:space:]]+$ ]]; then engine=$l; break; fi
  done <<< "$OUT"
  if [ "$CODE" -ne 0 ] || [ -z "$engine" ]; then
    docker_why='the Docker engine is not running'
  elif [ "${engine%%/*}" != linux ]; then
    # The Linux engine can still be running behind it, so do not claim there is nothing to stop.
    docker_why='Docker is set to Windows containers (the toolbox is a Linux image)'
    docker_hint="Right-click the Docker Desktop tray icon, choose 'Switch to Linux containers' and run this again."
  else
    docker_ready=1
  fi
fi

# The ids of every container started from the toolbox image, one per line.
toolbox_containers() {
  local l
  quiet dk ps -aq --filter "ancestor=$image"
  while IFS= read -r l; do
    if [[ $l =~ ^[0-9a-f]{12,64}$ ]]; then printf '%s\n' "$l"; fi
  done <<< "$OUT"
}

if [ "$docker_ready" != 1 ]; then
  warn "$docker_why, so no containers were checked."
  info "$docker_hint"
else
  quiet dk compose version
  if [ -f "$root/docker-compose.yml" ] && [ "$CODE" -eq 0 ]; then
    down_out=$(cd -- "$root" && dk compose down --remove-orphans 2>&1 < /dev/null)
    code=$?
    if [ "$code" -eq 0 ]; then
      ok 'docker compose down'
    else
      warn "docker compose down did not finish: $(first_line "$down_out" || echo "exit code $code")"
    fi
  fi

  # Anything still started from the image: a "dev" shell, a port-forward, a tool that is mid-run.
  ids=()
  while IFS= read -r l; do ids+=("$l"); done < <(toolbox_containers)
  if [ "${#ids[@]}" -eq 0 ]; then
    ok "no container is running from $image"
  else
    quiet dk rm -f "${ids[@]}"    # stops and removes; judged by what is left, not by the exit code
    left=()
    while IFS= read -r l; do left+=("$l"); done < <(toolbox_containers)
    if [ "${#left[@]}" -eq 0 ]; then
      ok "stopped and removed ${#ids[@]} container(s) started from $image"
    else
      fail "${#left[@]} container(s) started from $image are still there: ${left[*]}"
      info 'Stop them in Docker Desktop (Containers) and run this again.'
      problems=$((problems + 1))
    fi
  fi
fi

# ---- 4. Image and saved logins ---------------------------------------------------------------
step '4/4  Image and saved logins'
if [ "$remove_image" = 1 ]; then
  if [ "$docker_ready" != 1 ]; then
    fail "The image $image was not removed: $docker_why. Start Docker Desktop and run this again with --remove-image."
    problems=$((problems + 1))
  else
    quiet dk image inspect "$image"
    if [ "$CODE" -ne 0 ]; then
      ok "the image $image is not there"
    else
      quiet dk image rm "$image"
      if [ "$CODE" -eq 0 ]; then
        ok "deleted the image $image"
      else
        fail "Could not delete the image $image : $(first_line "$OUT" || echo "exit code $CODE")"
        problems=$((problems + 1))
      fi
    fi
  fi
else
  info "kept the image $image (setup.sh would rebuild it in a few minutes); add --remove-image to delete it"
fi

if [ "$remove_volume" = 1 ]; then
  if [ "$docker_ready" != 1 ]; then
    fail "The saved logins were not removed: $docker_why. Start Docker Desktop and run this again with --remove-volume."
    problems=$((problems + 1))
  else
    present=()
    for v in "${volumes[@]}"; do
      quiet dk volume inspect "$v"
      if [ "$CODE" -eq 0 ]; then present+=("$v"); fi
    done
    if [ "${#present[@]}" -eq 0 ]; then
      ok 'no toolbox volume found, nothing to delete'
    else
      names=${present[0]}
      if [ "${#present[@]}" -gt 1 ]; then names="${present[0]} and ${present[1]}"; fi
      go=0
      if [ "$force" = 1 ]; then
        go=1
      elif [ "$no_prompt" = 1 ]; then
        warn "kept $names : deleting it needs --force when no question can be asked"
      else
        # The question is written as a normal line so that it also shows in a log, where a prompt does not.
        warn "Delete $names? It holds your saved az, gh and kubectl logins and everything else in the toolbox home folder."
        answer=''
        printf '        Delete it? [y/N] '
        read -r answer || answer=''
        case $answer in
          [yY] | [yY][eE][sS]) go=1 ;;
          *) echo; info "kept $names" ;;
        esac
      fi
      if [ "$go" = 1 ]; then
        for v in "${present[@]}"; do
          quiet dk volume rm "$v"
          if [ "$CODE" -eq 0 ]; then
            ok "deleted the volume $v (your saved logins)"
          else
            fail "Could not delete the volume $v : $(first_line "$OUT" || echo "exit code $CODE")"
            problems=$((problems + 1))
          fi
        done
      fi
    fi
  fi
else
  info "kept your saved logins (volume ${volumes[0]}); add --remove-volume to delete them"
fi

# ---- Summary ---------------------------------------------------------------------------------
echo
if [ "$problems" -gt 0 ]; then
  fail "$problems problem(s) above need attention."
  exit 2
fi
echo "${c_green}Done.${c_off}"
if [ "$skip_profile" = 1 ]; then
  info 'Your startup files were not changed, so new terminals load the toolbox again.'
fi
info "The project folder ($root) and your .env were not touched."
if [ -f "$aliases_file" ]; then
  info "Your own shortcuts file was kept: $aliases_file (delete it yourself if you do not want it)"
fi
info 'To set everything up again:  ./setup.sh'
exit 0
