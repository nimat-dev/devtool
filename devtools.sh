# shellcheck shell=bash
# devtools.sh - run the toolbox CLIs transparently from bash.
#
# After sourcing it, `az`, `kubectl`, `terraform`, `flux`, `helm`, `kustomize`, `azd`, `gh`,
# `kubectx` and `kubens` each run inside the devtools container against a persistent creds
# volume, with your current directory mounted at /work. They are shell functions, so they shadow
# any same-named program installed on this machine (`command az` runs the installed one).
#
# Works in Git Bash, WSL, Linux and macOS (bash 4.2 or newer). It is the same toolbox, image and
# credentials volume as Devtools.psm1 (PowerShell): a login made from either shows up in both.
#
# Install (setup.sh adds this line to ~/.bashrc for you):
#     . /path/to/devtools-toolbox/devtools.sh
#
# First run (device-code login, there is no browser inside the container):
#     az login --use-device-code
#
# Typing comfort (all of it loads with this file):
#     Shortcuts       k, kgp, tfp, azl, aksx ...   `devtools-alias` lists them; your own go in
#                     ~/.devtools-aliases.sh (read last, so it wins)
#     Tab completion  az, kubectl, terraform, helm, flux ... the real tool in the container answers
#     History         the Up and Down arrows search your history for what you have typed
#
# Commands this adds besides the tools: dev, devtools-info, devtools-alias, devtools-import-kube,
# devtools-unload.
#
# Optional overrides (set before sourcing, e.g. in ~/.bashrc):
#     DEVTOOLS_IMAGE=devtools:latest      image tag to run
#     DEVTOOLS_VOLUME=devtools-home       named volume that keeps your logins
#     DEVTOOLS_BASH_ALIASES=FILE          your shortcuts file (default ~/.devtools-aliases.sh)
#     DEVTOOLS_NO_READLINE=1              leave the arrow keys and readline settings alone
#     DEVTOOLS_WINPTY=auto|1|0            Git Bash in the mintty window needs winpty for an
#                                         interactive docker; auto uses it there and nowhere else
#     AKS_RG, AKS_NAME                    your AKS cluster, for aksc / aksup / aksx

# shellcheck disable=SC2317
if [ -z "${BASH_VERSION:-}" ]; then
  echo "devtools.sh is for bash. In PowerShell use Devtools.psm1 (run setup.ps1)." >&2
  return 1 2> /dev/null || exit 1
fi
# shellcheck disable=SC2317
if [ "${BASH_VERSINFO[0]}" -lt 4 ] || { [ "${BASH_VERSINFO[0]}" -eq 4 ] && [ "${BASH_VERSINFO[1]}" -lt 2 ]; }; then
  echo "devtools.sh needs bash 4.2 or newer (this is bash ${BASH_VERSION}). On macOS: brew install bash" >&2
  return 1 2> /dev/null || exit 1
fi

: "${DEVTOOLS_IMAGE:=devtools:latest}"
: "${DEVTOOLS_VOLUME:=devtools-home}"
_DEVTOOLS_ALIASES_FILE=${DEVTOOLS_BASH_ALIASES:-$HOME/.devtools-aliases.sh}

# The folder this file is in (the shortcuts are read from scripts/shell/aliases.sh next to it).
_DEVTOOLS_DIR=${BASH_SOURCE[0]%/*}
if [ "$_DEVTOOLS_DIR" = "${BASH_SOURCE[0]}" ]; then _DEVTOOLS_DIR=.; fi
_DEVTOOLS_DIR=$(CDPATH='' cd -- "$_DEVTOOLS_DIR" 2> /dev/null && pwd) || _DEVTOOLS_DIR=

# Git Bash (MSYS2) and Cygwin start native Windows programs, which docker.exe is.
case "${OSTYPE:-}" in
  msys* | cygwin* | mingw*) _DEVTOOLS_WINDOWS=1 ;;
  *) _DEVTOOLS_WINDOWS= ;;
esac

# The tools that have Tab completion (the same list as Devtools.psm1).
_DEVTOOLS_COMPLETABLE=' az kubectl terraform flux helm kustomize azd gh '

# ---- Running docker --------------------------------------------------------------------------------

_devtools_say_no_docker() {
  echo "docker was not found on PATH. Start Docker Desktop and make sure 'docker' runs in this shell." >&2
  if [ -r /proc/version ] && [[ $(< /proc/version) == *[Mm]icrosoft* ]]; then
    echo "In WSL: Docker Desktop > Settings > Resources > WSL integration, switch on this distribution." >&2
  fi
}

# Finds the docker program: _DEVTOOLS_DOCKER is its name, and the result says whether it is there.
# In Git Bash that is docker.exe by name, so that a plain file called docker (a script, say) in
# front of it on the PATH is not what runs.
_devtools_find_docker() {
  _DEVTOOLS_DOCKER=docker
  if [ -n "$_DEVTOOLS_WINDOWS" ] && type -P docker.exe > /dev/null 2>&1; then _DEVTOOLS_DOCKER=docker.exe; fi
  type -P "$_DEVTOOLS_DOCKER" > /dev/null 2>&1
}

# _devtools_hex VAR ARG...   puts the arguments into VAR as one string of hex digits: two for every
# byte and 00 after each argument (an argument cannot hold a NUL byte, so 00 only ever ends one).
_devtools_hex() {
  local _hex_out
  _hex_out=$(printf '%s\0' "${@:2}" | od -An -v -tx1) || return 1
  printf -v "$1" '%s' "${_hex_out//[[:space:]]/}"
}

# Run the real docker (never a function or an alias of the same name) with these arguments, each
# one arriving exactly as given. Git Bash must not rewrite /work, /root or a tool argument such as
# /subscriptions/... into a Windows path on the way to docker.exe, so that is switched off here.
#
# With --winpty first, docker gets a terminal through winpty, which Git Bash in the mintty window
# needs ("the input device is not a TTY" without it). But winpty rewrites every argument that looks
# like a path on its own account and cannot be told not to: it turned -w /work into
# -w C:/Users/me/AppData/Local/Programs/Git/work, and docker refused that. So docker's arguments
# never go past winpty as they are. They go as ONE argument of hex digits, which nothing can take
# for a path, to scripts/devtools-pty-run.sh. winpty starts that in a bash of its own, and it turns
# the digits back into the arguments and runs docker.exe.
_devtools_docker() {
  local pty='' helper hex
  if [ "${1:-}" = "--winpty" ]; then
    pty=1
    shift
  fi
  if ! _devtools_find_docker; then
    _devtools_say_no_docker
    return 127
  fi
  if [ -z "$pty" ]; then
    MSYS_NO_PATHCONV=1 MSYS2_ARG_CONV_EXCL='*' command "$_DEVTOOLS_DOCKER" "$@"
    return
  fi
  helper=$_DEVTOOLS_DIR/scripts/devtools-pty-run.sh
  if [ ! -r "$helper" ]; then
    echo "devtools: $helper is missing, so docker cannot get a terminal in this window. Extract the whole toolbox folder again." >&2
    return 1
  fi
  if ! _devtools_hex hex "$@"; then
    echo "devtools: could not prepare the arguments for winpty (is od installed?)." >&2
    return 1
  fi
  # A Windows command line holds 32767 characters; this leaves room for the rest of it.
  if [ "${#hex}" -gt 30000 ]; then
    echo "devtools: these arguments are too long to pass through winpty in the Git Bash window. Run this one from PowerShell or Windows Terminal." >&2
    return 1
  fi
  command winpty "$BASH" "$helper" "$hex"
}

# A path the way the docker CLI wants it: C:/Users/me/project in Git Bash, unchanged elsewhere.
_devtools_hostpath() {
  if [ -n "$_DEVTOOLS_WINDOWS" ] && type -P cygpath > /dev/null 2>&1; then
    cygpath -m -- "$1"
  else
    printf '%s\n' "$1"
  fi
}

# Git Bash in its own mintty window cannot hand its terminal to docker.exe ("the input device is
# not a TTY"); winpty sits in between. Windows Terminal, VS Code and the like do not need it.
_devtools_use_winpty() {
  case "${DEVTOOLS_WINPTY:-auto}" in
    1 | yes | true | always) type -P winpty > /dev/null 2>&1; return ;;
    0 | no | false | never) return 1 ;;
  esac
  [ -n "$_DEVTOOLS_WINDOWS" ] && [ "${TERM_PROGRAM:-}" = mintty ] && type -P winpty > /dev/null 2>&1
}

# True when a person is at the keyboard and the screen. Only then does docker get a terminal.
_devtools_is_tty() { [ -t 0 ] && [ -t 1 ]; }

# Fills _DEVTOOLS_RUN with the docker arguments every call shares (up to the image name) and
# _DEVTOOLS_PTY with --winpty when docker has to go through winpty.
_devtools_prepare() {
  _DEVTOOLS_RUN=(run --rm -i)
  _DEVTOOLS_PTY=
  # A TTY only for genuine interactive use: with -t, piped or captured output gets corrupted.
  if _devtools_is_tty; then
    _DEVTOOLS_RUN+=(-t)
    if _devtools_use_winpty; then _DEVTOOLS_PTY=--winpty; fi
  fi
  _DEVTOOLS_RUN+=(-v "${DEVTOOLS_VOLUME}:/root" -v "$(_devtools_hostpath "$PWD"):/work" -w /work)
  return 0
}

# Core runner: a one-shot `docker run` of one tool in the toolbox image.
_devtools_run() {
  local tool=$1
  shift
  _devtools_prepare
  _devtools_docker ${_DEVTOOLS_PTY:+"$_DEVTOOLS_PTY"} "${_DEVTOOLS_RUN[@]}" "$DEVTOOLS_IMAGE" "$tool" "$@"
}

# ---- The tools -------------------------------------------------------------------------------------
az()        { _devtools_run az "$@"; }
kubectl()   { _devtools_run kubectl "$@"; }
terraform() { _devtools_run terraform "$@"; }
flux()      { _devtools_run flux "$@"; }
helm()      { _devtools_run helm "$@"; }
kustomize() { _devtools_run kustomize "$@"; }
azd()       { _devtools_run azd "$@"; }
gh()        { _devtools_run gh "$@"; }
kubectx()   { _devtools_run kubectx "$@"; }
kubens()    { _devtools_run kubens "$@"; }

# Open an interactive shell in the toolbox with the same mounts: whatever the image starts by
# default (zsh with suggestions and completion), or the command you give, for example  dev bash.
# AKS_RG and AKS_NAME, when set, are handed to the shell inside.
dev() {
  _devtools_prepare
  local n
  for n in AKS_RG AKS_NAME; do
    if [ -n "${!n:-}" ]; then _DEVTOOLS_RUN+=(-e "$n=${!n}"); fi
  done
  _devtools_docker ${_DEVTOOLS_PTY:+"$_DEVTOOLS_PTY"} "${_DEVTOOLS_RUN[@]}" "$DEVTOOLS_IMAGE" "$@"
}

# Make Docker Desktop's Kubernetes usable from the toolbox. The container keeps its own kubeconfig
# on the volume and cannot see the Windows one, so this copies ONE context out of ~/.kube/config
# (that single file is mounted read-only for this one call) and points it at the Docker Desktop
# host. Needs Kubernetes enabled in Docker Desktop. Re-run it after "Reset Kubernetes Cluster".
#   devtools-import-kube [CONTEXT] [KUBECONFIG]
devtools-import-kube() {
  local context=${1:-docker-desktop} kubeconfig=${2:-$HOME/.kube/config} code
  if [ ! -f "$kubeconfig" ]; then
    echo "No kubeconfig at $kubeconfig. In Docker Desktop open Settings > Kubernetes, enable it, wait until it shows Running, then run this again." >&2
    if [ -r /proc/version ] && [[ $(< /proc/version) == *[Mm]icrosoft* ]]; then
      echo "In WSL the file Docker Desktop writes is the Windows one: devtools-import-kube docker-desktop /mnt/c/Users/NAME/.kube/config" >&2
    fi
    return 1
  fi
  _devtools_docker run --rm -i -v "${DEVTOOLS_VOLUME}:/root" \
    -v "$(_devtools_hostpath "$kubeconfig"):/hostkube/config:ro" \
    "$DEVTOOLS_IMAGE" import-docker-desktop-kube "$context"
  code=$?
  # 127 = "executable not found": the image predates the helper scripts.
  if [ "$code" -eq 127 ]; then
    echo "warning: This image has no import-docker-desktop-kube yet. Rebuild it first:  docker compose build" >&2
  fi
  return "$code"
}

# Show what the wrappers are pointed at.
devtools-info() {
  local docker terminal=direct
  if _devtools_find_docker; then docker=$(type -P "$_DEVTOOLS_DOCKER"); else docker='not found on PATH'; fi
  if _devtools_use_winpty; then terminal='winpty (this Git Bash window needs it for docker -t)'; fi
  printf '%-12s %s\n' Image "$DEVTOOLS_IMAGE" Volume "$DEVTOOLS_VOLUME" \
    Tools 'az, kubectl, terraform, flux, helm, kustomize, azd, gh, kubectx, kubens, dev' \
    AliasesFile "$_DEVTOOLS_ALIASES_FILE" Docker "$docker" Terminal "$terminal"
}

# ---- Shortcuts -------------------------------------------------------------------------------------
# scripts/shell/aliases.sh holds them: the same file the shell inside the toolbox reads, and the
# same list as Devtools.psm1 (a test keeps the two in step). They are aliases, so whatever you type
# after one is added at the end: `kgp -n kube-system` runs `kubectl get pods -n kube-system`.
# `devtools-alias` lists them. Your own go in ~/.devtools-aliases.sh (read last, so it wins).
declare -ga _DEVTOOLS_ALIAS_NAMES=()      # the built-in shortcuts, in the order of the file
declare -gA _DEVTOOLS_SNAPSHOT=()         # name -> definition, to see which ones your file replaces
declare -ga _DEVTOOLS_PERSONAL=()         # names your file adds
declare -ga _DEVTOOLS_OVERRIDDEN=()       # built-in names your file replaces
declare -ga _DEVTOOLS_SPECIAL=(aksc aksup aksx)

if [ -r "$_DEVTOOLS_DIR/scripts/shell/aliases.sh" ]; then
  while IFS= read -r _devtools_line || [ -n "$_devtools_line" ]; do
    case $_devtools_line in
      "alias "*=*)
        _devtools_name=${_devtools_line#alias }
        _DEVTOOLS_ALIAS_NAMES+=("${_devtools_name%%=*}") ;;
    esac
  done < "$_DEVTOOLS_DIR/scripts/shell/aliases.sh"
  # shellcheck source=scripts/shell/aliases.sh
  . "$_DEVTOOLS_DIR/scripts/shell/aliases.sh"
else
  echo "devtools.sh: the shortcuts file $_DEVTOOLS_DIR/scripts/shell/aliases.sh is missing, so there are no shortcuts." >&2
fi
unset _devtools_line _devtools_name

# ---- Your own shortcuts ----------------------------------------------------------------------------
# A mistake in the file is reported by bash (file and line) and does not stop the toolbox from
# loading. It is read here, at the top level of this file, so that anything it exports stays exported.
if [ -f "$_DEVTOOLS_ALIASES_FILE" ]; then
  for _devtools_name in "${_DEVTOOLS_ALIAS_NAMES[@]}"; do
    _DEVTOOLS_SNAPSHOT[$_devtools_name]=${BASH_ALIASES[$_devtools_name]-}
  done
  for _devtools_name in "${_DEVTOOLS_SPECIAL[@]}"; do
    _DEVTOOLS_SNAPSHOT[$_devtools_name]=$(declare -f "$_devtools_name" 2> /dev/null)
  done
  _devtools_aliases_before=" ${!BASH_ALIASES[*]} "
  _devtools_functions_before=" $(compgen -A function | tr '\n' ' ') "

  # A mistake in it is reported by bash itself, with the file and the line.
  # shellcheck disable=SC1090
  . "$_DEVTOOLS_ALIASES_FILE"

  for _devtools_name in "${!BASH_ALIASES[@]}"; do
    case $_devtools_aliases_before in *" $_devtools_name "*) ;; *) _DEVTOOLS_PERSONAL+=("$_devtools_name") ;; esac
  done
  for _devtools_name in $(compgen -A function); do
    case $_devtools_name in _*) continue ;; esac
    case $_devtools_functions_before in *" $_devtools_name "*) ;; *) _DEVTOOLS_PERSONAL+=("$_devtools_name") ;; esac
  done
  for _devtools_name in "${_DEVTOOLS_ALIAS_NAMES[@]}"; do
    if [ "${BASH_ALIASES[$_devtools_name]-}" != "${_DEVTOOLS_SNAPSHOT[$_devtools_name]}" ]; then _DEVTOOLS_OVERRIDDEN+=("$_devtools_name"); fi
  done
  for _devtools_name in "${_DEVTOOLS_SPECIAL[@]}"; do
    if [ "$(declare -f "$_devtools_name" 2> /dev/null)" != "${_DEVTOOLS_SNAPSHOT[$_devtools_name]}" ]; then _DEVTOOLS_OVERRIDDEN+=("$_devtools_name"); fi
  done
  unset _devtools_name _devtools_aliases_before _devtools_functions_before
fi

# Every shortcut, grouped: the toolbox's own, the ones your file replaces, the ones it adds.
#   devtools-alias [PATTERN]     only the names that match the pattern (a glob, such as 'kg*')
#   devtools-alias --count       how many built-in shortcuts there are
devtools-alias() {
  local pattern=${1:-*} name runs group yours kind
  if [ "$pattern" = "--count" ]; then
    echo $((${#_DEVTOOLS_ALIAS_NAMES[@]} + ${#_DEVTOOLS_SPECIAL[@]}))
    return 0
  fi
  _devtools_is_overridden() {
    local o
    for o in "${_DEVTOOLS_OVERRIDDEN[@]+"${_DEVTOOLS_OVERRIDDEN[@]}"}"; do [ "$o" = "$1" ] && return 0; done
    return 1
  }
  printf '%-10s %-10s %s\n' GROUP ALIAS RUNS
  for group in Azure AKS kubectl Terraform; do
    for name in "${_DEVTOOLS_ALIAS_NAMES[@]}" "${_DEVTOOLS_SPECIAL[@]}"; do
      # shellcheck disable=SC2254
      case $name in $pattern) ;; *) continue ;; esac
      yours=
      if _devtools_is_overridden "$name"; then yours=1; fi
      case $name in
        aksc)  runs='az aks get-credentials -g RG -n NAME --overwrite-existing   (RG NAME, or AKS_RG and AKS_NAME)'; kind=AKS ;;
        aksup) runs='az aks get-upgrades -g RG -n NAME -o table   (RG NAME, or AKS_RG and AKS_NAME)'; kind=AKS ;;
        aksx)  runs='az aks command invoke -g AKS_RG -n AKS_NAME --command "..."   (for a private cluster)'; kind=AKS ;;
        *)
          runs=${_DEVTOOLS_SNAPSHOT[$name]-}
          runs=${BASH_ALIASES[$name]-$runs}
          kind=kubectl
          case $runs in
            "az aks"*) kind=AKS ;;
            "az "*) kind=Azure ;;
            terraform*) kind=Terraform ;;
          esac ;;
      esac
      if [ -n "$yours" ]; then continue; fi
      if [ "$kind" = "$group" ]; then printf '%-10s %-10s %s\n' "$group" "$name" "$runs"; fi
    done
  done
  for name in "${_DEVTOOLS_OVERRIDDEN[@]+"${_DEVTOOLS_OVERRIDDEN[@]}"}"; do
    # shellcheck disable=SC2254
    case $name in $pattern) printf '%-10s %-10s %s\n' Yours "$name" '(your own, replaces the default)' ;; esac
  done
  for name in "${_DEVTOOLS_PERSONAL[@]+"${_DEVTOOLS_PERSONAL[@]}"}"; do
    # shellcheck disable=SC2254
    case $name in $pattern) printf '%-10s %-10s %s\n' Yours "$name" "(from $_DEVTOOLS_ALIASES_FILE)" ;; esac
  done
  unset -f _devtools_is_overridden
  return 0
}

# ---- Tab completion --------------------------------------------------------------------------------
# The real tools exist only in the container, so a Tab press asks it: one short-lived container,
# about a second. It needs an image that has devtools-complete (rebuild with setup.sh or
# setup.ps1). When the image is older, docker is not running or the tool has no answer, the result
# is nothing and bash completes file names as usual.
_devtools_complete() {
  local name=${COMP_WORDS[0]} line=${COMP_LINE:0:COMP_POINT} expansion tool rows row value
  COMPREPLY=()
  line=${line#"${line%%[![:space:]]*}"}                 # no leading blanks
  # A shortcut completes like the command it stands for: kgp -n <Tab> asks about kubectl get pods -n.
  expansion=${BASH_ALIASES[$name]-}
  if [ -n "$expansion" ]; then line=$expansion${line#"$name"}; fi
  tool=${line%%[[:space:]]*}
  case $_DEVTOOLS_COMPLETABLE in *" $tool "*) ;; *) return 0 ;; esac

  rows=$(_devtools_docker run --rm -v "${DEVTOOLS_VOLUME}:/root" "$DEVTOOLS_IMAGE" \
    devtools-complete "$tool" "$line" "${#line}" 2> /dev/null) || return 0

  # bash completes the part of the word after the last = or :, so take that much off the front.
  local token=${line##*[[:space:]]} after drop=''
  case $token in
    *[=:]*)
      after=${token##*[=:]}
      drop=${token%"$after"} ;;
  esac

  local -A seen=()
  local -a found=()
  while IFS= read -r row || [ -n "$row" ]; do
    value=${row%%$'\t'*}
    value=${value#"${value%%[![:space:]]*}"}
    value=${value%"${value##*[![:space:]]}"}
    [ -n "$value" ] || continue
    if [ -n "$drop" ] && [ "${value#"$drop"}" != "$value" ]; then value=${value#"$drop"}; fi
    [ -n "$value" ] || continue
    [ -z "${seen[$value]+x}" ] || continue
    seen[$value]=1
    printf -v row '%q' "$value"
    found+=("$row")
    [ "${#found[@]}" -lt 200 ] || break
  done <<< "$rows"
  COMPREPLY=("${found[@]+"${found[@]}"}")

  # Nothing to type after a word that ends in = or /.
  if [ "${#COMPREPLY[@]}" -eq 1 ]; then
    case ${COMPREPLY[0]} in *= | */) compopt -o nospace 2> /dev/null ;; esac
  fi
  return 0
}

# The tools themselves and every shortcut that stands for one of them (also your own).
_devtools_register_completion() {
  local name first
  local -a names=(az kubectl terraform flux helm kustomize azd gh)
  for name in "${!BASH_ALIASES[@]}"; do
    first=${BASH_ALIASES[$name]%%[[:space:]]*}
    case $_DEVTOOLS_COMPLETABLE in *" $first "*) names+=("$name") ;; esac
  done
  complete -o default -F _devtools_complete "${names[@]}"
}
_devtools_register_completion

# ---- History search on the arrow keys (interactive shells) -----------------------------------------
# bash cannot draw a grey suggestion the way zsh or PowerShell can. The nearest thing: type the
# start of a command, then Up or Down finds the earlier commands that begin with it. Only the
# default bindings are replaced, so a setting of your own is left alone, and devtools-unload puts
# everything back. DEVTOOLS_NO_READLINE=1 skips all of it.
declare -ga _DEVTOOLS_KEYS_UNDO=()

_devtools_readline() {
  local bound pair seq was now
  bound=$'\n'$(bind -p 2> /dev/null)$'\n'
  for pair in '\e[A|previous-history|history-search-backward' '\eOA|previous-history|history-search-backward' \
              '\e[B|next-history|history-search-forward' '\eOB|next-history|history-search-forward'; do
    IFS='|' read -r seq was now <<< "$pair"
    case $bound in
      *$'\n'"\"$seq\": $was"$'\n'*)
        bind "\"$seq\": $now"
        _DEVTOOLS_KEYS_UNDO+=("\"$seq\": $was") ;;
    esac
  done
  # With several choices, list them on the first Tab instead of ringing the bell.
  case $(bind -v 2> /dev/null) in
    *"set show-all-if-ambiguous off"*)
      bind 'set show-all-if-ambiguous on'
      _DEVTOOLS_KEYS_UNDO+=('set show-all-if-ambiguous off') ;;
  esac
  return 0
}

if [[ $- == *i* ]] && [ -z "${DEVTOOLS_NO_READLINE:-}" ]; then
  _DEVTOOLS_KEYS_UNDO=()
  _devtools_readline
fi

# ---- Taking it all out again ------------------------------------------------------------------------
# For this shell only; setup.sh and uninstall.sh deal with ~/.bashrc. Your own shortcuts stay.
devtools-unload() {
  local name binding
  for name in "${_DEVTOOLS_ALIAS_NAMES[@]}"; do unalias "$name" 2> /dev/null; done
  complete -r az kubectl terraform flux helm kustomize azd gh 2> /dev/null
  for name in "${_DEVTOOLS_ALIAS_NAMES[@]}"; do complete -r "$name" 2> /dev/null; done
  for binding in "${_DEVTOOLS_KEYS_UNDO[@]+"${_DEVTOOLS_KEYS_UNDO[@]}"}"; do bind "$binding" 2> /dev/null; done
  unset -f az kubectl terraform flux helm kustomize azd gh kubectx kubens dev aksc aksup aksx \
    devtools-import-kube devtools-info devtools-alias \
    _devtools_say_no_docker _devtools_find_docker _devtools_hex _devtools_docker _devtools_hostpath \
    _devtools_use_winpty _devtools_is_tty _devtools_prepare \
    _devtools_run _devtools_complete _devtools_register_completion _devtools_readline
  unset DEVTOOLS_IMAGE DEVTOOLS_VOLUME \
    _DEVTOOLS_ALIASES_FILE _DEVTOOLS_DIR _DEVTOOLS_WINDOWS _DEVTOOLS_COMPLETABLE _DEVTOOLS_RUN _DEVTOOLS_PTY _DEVTOOLS_DOCKER \
    _DEVTOOLS_ALIAS_NAMES _DEVTOOLS_SNAPSHOT _DEVTOOLS_PERSONAL _DEVTOOLS_OVERRIDDEN _DEVTOOLS_SPECIAL _DEVTOOLS_KEYS_UNDO
  unset -f devtools-unload
  return 0
}
