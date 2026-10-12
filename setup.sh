#!/usr/bin/env bash
# setup.sh - one-file setup for the DevOps toolbox, from bash (Git Bash, WSL, Linux, macOS).
# The bash twin of setup.ps1: same image, same credentials volume, same shortcuts.
#
# From the project folder (no admin rights needed):
#
#     ./setup.sh            (or:  bash setup.sh)
#
#   1  checks that Docker is running with Linux containers
#   2  creates .env from .env.example (kept if it already exists)
#   3  builds the image                        (docker compose build)
#   4  adds a line to ~/.bashrc that loads devtools.sh, and makes sure login shells read ~/.bashrc
#      (Git Bash and macOS Terminal start login shells)
#   5  loads the wrappers (az, kubectl, terraform ... run in the container), with the shortcuts
#      (k, kgp, tfp, azl ...), Tab completion and history search on the arrow keys;
#      creates ~/.devtools-aliases.sh for your own shortcuts (never overwritten)
#   6  verifies every tool
#   then offers the Azure login and the Docker Desktop Kubernetes import.
#
# Safe to run again at any time: every step checks before it changes anything.
# Exit code: 0 all good, 1 setup could not finish, 2 setup finished but something above failed.
#
# Options:
#   --skip-build      Do not build the image (it is already built).
#   --skip-profile    Do not touch your bash startup files.
#   --skip-verify     Do not run the tool checks.
#   --login           Run 'az login --use-device-code' at the end without asking.
#   --import-kube     Import Docker Desktop's Kubernetes context at the end without asking.
#   --no-prompt       Never ask a question (for automation). The two optional steps then run
#                     only when --login / --import-kube are given.
#   --rc-file FILE    Startup file to edit instead of ~/.bashrc (login shells are then not checked).
#   -h, --help        This text.
#
# The part before the version check below is kept free of newer bash syntax, so that an old bash
# (macOS ships 3.2) gets the plain message instead of a syntax error.

set -u

# shellcheck disable=SC2317
if [ -z "${BASH_VERSION:-}" ]; then
  echo "setup.sh is for bash. In PowerShell run setup.ps1." >&2
  exit 1
fi
# shellcheck disable=SC2317
if [ "${BASH_VERSINFO[0]}" -lt 4 ] || { [ "${BASH_VERSINFO[0]}" -eq 4 ] && [ "${BASH_VERSINFO[1]}" -lt 2 ]; }; then
  echo "setup.sh needs bash 4.2 or newer (this is bash $BASH_VERSION). On macOS: brew install bash, then run this with that bash." >&2
  exit 1
fi
# shellcheck disable=SC2317
if [ "${BASH_SOURCE[0]}" != "$0" ]; then
  echo "Run setup.sh, do not source it:  ./setup.sh" >&2
  return 1 2> /dev/null || exit 1
fi

usage() {
  sed -n '2,/^# The part before/p' "${BASH_SOURCE[0]}" | sed -e '$d' -e 's/^# \{0,1\}//'
}

skip_build=0 skip_profile=0 skip_verify=0 want_login=0 want_kube=0 no_prompt=0 rc_file=''
while [ $# -gt 0 ]; do
  case $1 in
    --skip-build) skip_build=1 ;;
    --skip-profile) skip_profile=1 ;;
    --skip-verify) skip_verify=1 ;;
    --login) want_login=1 ;;
    --import-kube) want_kube=1 ;;
    --no-prompt) no_prompt=1 ;;
    --rc-file)
      if [ $# -lt 2 ]; then echo "--rc-file needs a file name" >&2; exit 1; fi
      rc_file=$2
      shift ;;
    --rc-file=*) rc_file=${1#--rc-file=} ;;
    -h | --help) usage; exit 0 ;;
    *) echo "Unknown option: $1  (see ./setup.sh --help)" >&2; exit 1 ;;
  esac
  shift
done

here=${BASH_SOURCE[0]%/*}
if [ "$here" = "${BASH_SOURCE[0]}" ]; then here=.; fi
root=$(CDPATH='' cd -- "$here" 2> /dev/null && pwd) || { echo "Cannot work out which folder setup.sh is in." >&2; exit 1; }
image=devtools:latest
problems=0
devtools_sh=$root/devtools.sh
aliases_file=${DEVTOOLS_BASH_ALIASES:-$HOME/.devtools-aliases.sh}

# What gets written to the startup files. Keep these in step with uninstall.sh (the tests check it).
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
stop_setup() { fail "$1"; exit 1; }

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

# A string inside single quotes, safe to put in a shell line (a quote inside becomes '\'').
sq() {
  local s=$1 out="'" q="'"
  while [[ $s == *"$q"* ]]; do
    out+="${s%%"$q"*}'\\''"
    s=${s#*"$q"}
  done
  out+="$s'"
  printf '%s' "$out"
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

# True when this is Git Bash / MSYS2 / Cygwin, where docker is a native Windows program.
is_windows() { case "${OSTYPE:-}" in msys* | cygwin* | mingw*) return 0 ;; *) return 1 ;; esac; }
is_wsl() { [ -r /proc/version ] && [[ $(< /proc/version) == *[Mm]icrosoft* ]]; }

# True when the switch was given, or (interactive only) when the user answers yes.
wanted() {
  local switch=$1 question=$2 answer=''
  if [ "$switch" = 1 ]; then return 0; fi
  if [ "$no_prompt" = 1 ] || [ ! -t 0 ]; then return 1; fi
  printf '        %s [y/N] ' "$question"
  read -r answer || answer=''
  case $answer in [yY] | [yY][eE][sS]) return 0 ;; *) return 1 ;; esac
}

# ---- startup files ---------------------------------------------------------------------------
# Adds (or corrects) the line that loads devtools.sh. RESULT = present | updated | added.
import_line=". $(sq "$devtools_sh")"
add_import_line() {
  local file=$1 i=0 n=0 first=-1 exact=0 l
  if [ -f "$file" ]; then read_lines "$file"; else LINES=(); TRAILING_NL=1; fi
  while [ "$i" -lt "${#LINES[@]}" ]; do
    if [[ ${LINES[$i]} =~ $rx_import ]]; then
      if [ "$first" -lt 0 ]; then first=$i; fi
      n=$((n + 1))
      l=$(trim "${LINES[$i]}")
      if [ "$l" = "$import_line" ]; then exact=1; fi
    fi
    i=$((i + 1))
  done

  if [ "$n" -eq 1 ] && [ "$exact" -eq 1 ]; then
    RESULT=present
    return 0
  fi

  if [ "$n" -gt 0 ]; then
    # An older line points at another folder (the project was moved or re-extracted).
    write_lines "$file.bak" || return 1          # LINES still holds the file as it was
    local -a out=()
    i=0
    while [ "$i" -lt "${#LINES[@]}" ]; do
      if [[ ${LINES[$i]} =~ $rx_import ]]; then
        if [ "$i" -eq "$first" ]; then out+=("$import_line"); fi
      else
        out+=("${LINES[$i]}")
      fi
      i=$((i + 1))
    done
    LINES=("${out[@]+"${out[@]}"}")
    write_lines "$file" || return 1
    RESULT=updated
    return 0
  fi

  mkdir -p -- "$(dirname -- "$file")" || return 1
  # A blank line first when the file has something in it (and the end of its last line, if missing).
  local lead=''
  if [ -s "$file" ]; then
    lead=$'\n'
    if [ "$TRAILING_NL" != 1 ]; then lead=$'\n\n'; fi
  fi
  printf '%s%s\n%s\n' "$lead" "$marker" "$import_line" >> "$file" || return 1
  RESULT=added
}

# Login shells (Git Bash windows, macOS Terminal) read ~/.bash_profile, or else ~/.bash_login, or
# else ~/.profile, and NOT ~/.bashrc, unless that file loads it. RESULT = ok:FILE | added:FILE.
ensure_login_reads_bashrc() {
  local f='' cand l t
  for cand in "$HOME/.bash_profile" "$HOME/.bash_login" "$HOME/.profile"; do
    if [ -f "$cand" ]; then f=$cand; break; fi
  done
  if [ -n "$f" ]; then
    while IFS= read -r l || [ -n "$l" ]; do
      t=$(trim "$l")
      case $t in '#'*) continue ;; esac
      case $t in *bashrc*) RESULT=ok:$f; return 0 ;; esac
    done < "$f"
  else
    f=$HOME/.bash_profile
  fi
  read_lines_or_empty "$f"
  local lead=''
  if [ -s "$f" ]; then
    lead=$'\n'
    if [ "$TRAILING_NL" != 1 ]; then lead=$'\n\n'; fi
  fi
  printf '%s%s\n%s\n' "$lead" "$login_marker" "$login_line" >> "$f" || return 1
  RESULT=added:$f
}
read_lines_or_empty() { if [ -f "$1" ]; then read_lines "$1"; else LINES=(); TRAILING_NL=1; fi; }

# The file for your own shortcuts. Created once, never overwritten.
write_aliases_template() {
  mkdir -p -- "$(dirname -- "$1")" || return 1
  cat > "$1" << 'TEMPLATE'
# Your own bash shortcuts for the toolbox. setup.sh made this file once and never changes it.
# It is read when the toolbox loads, after the built-in shortcuts, so what you define here wins.
#
# A shortcut is an alias. Whatever you type after it is added at the end:
#
#   alias kgj='kubectl get pods -o json'
#   alias tfpl='terraform plan -out=tfplan'
#
# One that needs your words in the middle is a function:
#
#   kgpn() { kubectl get pods -n "$1"; }
#
# Your AKS cluster (stays on this laptop; used by aksc, aksup and aksx):
#
#   export AKS_RG='my-resource-group'
#   export AKS_NAME='my-cluster'
#
# List every shortcut:  devtools-alias
TEMPLATE
}

echo "${c_cyan}DevOps toolbox setup  ($root)${c_off}"

# ---- 1. Docker -------------------------------------------------------------------------------
step '1/6  Docker'
for f in Dockerfile docker-compose.yml devtools.sh scripts/shell/aliases.sh; do
  if [ ! -e "$root/$f" ]; then
    stop_setup "Cannot find $f next to setup.sh. Run it from the project folder (the one that holds the Dockerfile)."
  fi
done
if ! type -P docker > /dev/null 2>&1; then
  fail 'docker was not found on PATH. Start Docker Desktop, open a NEW terminal and run this again.'
  if is_wsl; then
    info 'In WSL: Docker Desktop > Settings > Resources > WSL integration, switch on this distribution.'
  fi
  exit 1
fi
quiet dk version --format '{{.Server.Os}}/{{.Server.Version}}'
engine=''
while IFS= read -r l; do
  if [[ $l =~ ^[A-Za-z]+/[^[:space:]]+$ ]]; then engine=$l; break; fi
done <<< "$OUT"
if [ "$CODE" -ne 0 ] || [ -z "$engine" ]; then
  stop_setup 'Docker is installed but its engine is not running. Start Docker Desktop, wait for "Engine running", then run this again.'
fi
if [ "${engine%%/*}" != linux ]; then
  stop_setup "Docker is set to ${engine%%/*} containers but the toolbox is a Linux image. Right-click the Docker Desktop tray icon and choose 'Switch to Linux containers'."
fi
ok "Docker engine ${engine#*/}, Linux containers"
have_compose=0
quiet dk compose version
if [ "$CODE" -eq 0 ]; then have_compose=1; else warn "'docker compose' is not available, using 'docker build' (.env settings are ignored)."; fi
if is_windows; then
  if [ "${TERM_PROGRAM:-}" = mintty ]; then
    if type -P winpty > /dev/null 2>&1; then
      ok 'Git Bash (mintty): interactive commands such as az login go through winpty automatically'
    else
      warn 'Git Bash (mintty) without winpty: an interactive command can fail with "the input device is not a TTY".'
      info 'Use the Windows Terminal or the VS Code terminal for Git Bash, or install winpty.'
    fi
  fi
fi

# ---- 2. Settings -----------------------------------------------------------------------------
step '2/6  Settings (.env)'
if [ -e "$root/.env" ]; then
  ok '.env already exists, keeping it'
elif [ -f "$root/.env.example" ]; then
  cp -- "$root/.env.example" "$root/.env"
  ok 'created .env from .env.example (edit it to set a proxy or pin tool versions)'
else
  warn 'no .env.example found, using the built-in defaults'
fi
certs=0
for f in "$root"/certs/*.crt; do
  if [ -e "$f" ]; then certs=$((certs + 1)); fi
done
if [ "$certs" -gt 0 ]; then ok "$certs corporate CA certificate(s) in certs/ will be trusted during the build"; fi

# ---- 3. Build --------------------------------------------------------------------------------
step '3/6  Build the image (the first build takes a few minutes)'
if [ "$skip_build" = 1 ]; then
  quiet dk image inspect "$image"
  if [ "$CODE" -ne 0 ]; then stop_setup "--skip-build was given but the image $image does not exist yet. Run again without it."; fi
  ok "skipped (--skip-build), using the existing image $image"
else
  started=$SECONDS
  if [ "$have_compose" = 1 ]; then
    (cd -- "$root" && dk compose build)
  else
    (cd -- "$root" && dk build -t "$image" .)
  fi
  code=$?
  if [ "$code" -ne 0 ]; then
    info 'Behind a corporate network the usual causes are:'
    info '- TLS inspection: put your company root CA (PEM, *.crt) in certs/ and run this again'
    info '- proxy: set HTTP_PROXY and HTTPS_PROXY in .env (and in Docker Desktop > Settings > Resources > Proxies)'
    info 'More in README.md under Troubleshooting.'
    stop_setup "The image build failed (exit code $code)."
  fi
  ok "image $image built in $((SECONDS - started))s"
fi

# ---- 4. Startup files ------------------------------------------------------------------------
step '4/6  bash startup file'
if [ "$skip_profile" = 1 ]; then
  info 'skipped (--skip-profile)'
else
  target=${rc_file:-$HOME/.bashrc}
  RESULT=''
  if add_import_line "$target" 2> /dev/null; then
    case $RESULT in
      present) ok "already set up in $target" ;;
      updated) ok "updated the existing devtools.sh line in $target (backup: $target.bak)" ;;
      *) ok "added the devtools.sh line to $target" ;;
    esac
  else
    # Locked-down machines: a read-only home folder, a managed dotfile ...
    fail "Could not update your startup file ($target)."
    info 'Add this line to it yourself, or run it in each terminal you want the tools in:'
    info "    $import_line"
    problems=$((problems + 1))
  fi
  if [ -z "$rc_file" ]; then
    RESULT=''
    if ensure_login_reads_bashrc 2> /dev/null; then
      case $RESULT in
        ok:*) ok "login shells already read ~/.bashrc (via ${RESULT#ok:})" ;;
        added:*) ok "${RESULT#added:} now loads ~/.bashrc, so login shells (Git Bash windows, macOS Terminal) get the toolbox too" ;;
      esac
    else
      warn "Could not check which file login shells read. If the tools are missing in a new Git Bash window, add this to ~/.bash_profile:"
      info "    $login_line"
    fi
  fi
fi

# ---- 5. Load the wrappers --------------------------------------------------------------------
step '5/6  Load the wrappers'
loaded=0
# shellcheck source=devtools.sh
if DEVTOOLS_NO_READLINE=1 . "$devtools_sh"; then loaded=1; fi
if [ "$loaded" = 1 ] && declare -F devtools-alias > /dev/null; then
  ok 'az, kubectl, terraform, flux, helm, kustomize, azd, gh, kubectx, kubens and dev now run in the container'
  ok "$(devtools-alias --count) shortcuts: k, kgp, tfp, azl, aksx ...  (devtools-alias lists them all)"
  if [ -f "$aliases_file" ]; then
    ok "your own shortcuts file already exists, keeping it: $aliases_file"
  elif write_aliases_template "$aliases_file" 2> /dev/null; then
    ok "made a file for your own shortcuts: $aliases_file"
  else
    warn "Could not prepare your shortcuts file ($aliases_file)."
  fi
  ok 'Tab completion for az, kubectl, terraform, helm, flux ... (the real tool answers from the container, about a second per Tab)'
  ok 'history: type the start of a command, then Up or Down finds it'
  info 'bash cannot show grey suggestions as you type; the toolbox shell, dev, has them (zsh).'
else
  stop_setup "Could not load $devtools_sh (see the message above)."
fi

# ---- 6. Verify -------------------------------------------------------------------------------
step '6/6  Verify every tool (one container per tool)'
if [ "$skip_verify" = 1 ]; then
  info 'skipped (--skip-verify)'
else
  info "image $DEVTOOLS_IMAGE, credentials volume $DEVTOOLS_VOLUME"
  for check in 'az --version' 'kubectl version --client' 'terraform version' 'helm version --short' 'flux --version' \
    'kustomize version' 'azd version' 'gh --version' 'kubectx -h' 'kubens -h'; do
    read -r -a words <<< "$check"
    name=${words[0]}
    quiet "${words[@]}"
    text=$(first_line "$OUT" 60)
    case $name in kubectx | kubens) text=ready ;; esac
    if [ "$CODE" -eq 0 ]; then
      ok "$(printf '%-10s %s' "$name" "$text")"
    else
      fail "$(printf '%-10s exit code %s  %s' "$name" "$CODE" "$text")"
      problems=$((problems + 1))
    fi
  done
  # Tab completion asks the image; an image built before that feature has no helper.
  quiet dk run --rm "$DEVTOOLS_IMAGE" devtools-complete
  if [ "$CODE" -eq 0 ]; then
    ok "$(printf '%-10s Tab completion helper is in the image' complete)"
  else
    warn "This image has no Tab completion helper yet (exit code $CODE). Run setup.sh again without --skip-build to rebuild it."
  fi
fi

# ---- Optional: Azure login and Docker Desktop Kubernetes -------------------------------------
did_login=0
did_kube=0
if wanted "$want_login" 'Sign in to Azure now (device code, no browser needed in the container)?'; then
  step 'Azure login'
  if az login --use-device-code; then did_login=1; else warn 'the login did not finish; run  az login --use-device-code  when you are ready'; fi
fi
if wanted "$want_kube" "Import Docker Desktop's Kubernetes context now (Kubernetes must be enabled in Docker Desktop)?"; then
  step 'Docker Desktop Kubernetes'
  if devtools-import-kube; then did_kube=1; else warn 'not imported; fix the message above and run  devtools-import-kube'; fi
fi

# ---- Summary ---------------------------------------------------------------------------------
echo
if [ "$problems" -gt 0 ]; then
  fail "$problems problem(s) above need attention."
  exit 2
fi
echo "${c_green}All set.${c_off}"
if [ "$skip_profile" = 1 ]; then
  info 'Your startup files were not changed. In any terminal, load the tools with:'
else
  info 'Open a NEW terminal: az, kubectl, terraform ... now run in the container there.'
  info 'To use them in the terminal you started this from, run:'
fi
info "    $import_line"
echo 'Next:'
if [ "$did_login" = 0 ]; then info 'az login --use-device-code      sign in to Azure (the token stays in the toolbox volume)'; fi
if [ "$did_kube" = 0 ]; then info "devtools-import-kube            use Docker Desktop's Kubernetes (enable it in Docker Desktop first)"; fi
info 'kubectx, kubens, kubectl ...    work like the real tools'
info 'devtools-alias                  the shortcuts (k, kgp, tfp ...); your own go in the file named above'
info 'dev                             a full shell inside the toolbox: grey history suggestions, Tab completion, the same shortcuts'
exit 0
