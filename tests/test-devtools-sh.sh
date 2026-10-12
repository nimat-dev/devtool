#!/usr/bin/env bash
# Tests for devtools.sh (the bash wrappers). No Docker daemon is needed: a fake `docker` records the
# arguments it was called with (see tests/fakebin/docker and tests/lib.sh). Every scenario runs in a
# fresh child bash with a scratch home folder, so nothing of yours is read or changed.
#
#     bash tests/test-devtools-sh.sh
#
# Works in bash on Linux and macOS, and in Git Bash on Windows, where the fake is a docker.exe: that
# is what makes Git Bash treat docker as a native program, so the checks on /work, /subscriptions/...
# and the Windows form of the current folder mean something there.
# shellcheck disable=SC1091,SC2016
# (SC1091: lib.sh is next to this file; SC2016: the snippets that run in a child bash are single-quoted on purpose.)
set -u
. "$(dirname -- "$0")/lib.sh"

echo "bash $BASH_VERSION on ${OSTYPE:-unknown}"
install_fake_docker

TMP_POSIX=$(mktemp -d)
trap 'rm -rf "$TMP_POSIX"' EXIT
TMP=$(to_native "$TMP_POSIX")
HOME_DIR=$TMP/home
WORK="$TMP/work dir"                 # a space on purpose
mkdir -p "$HOME_DIR" "$WORK"
export DOCKER_ARGS_FILE=$TMP/args.txt
export DEVTOOLS_SH=$TEST_ROOT/devtools.sh
export TEST_ROOT
unset DEVTOOLS_IMAGE DEVTOOLS_VOLUME DEVTOOLS_BASH_ALIASES DEVTOOLS_WINPTY DEVTOOLS_NO_READLINE \
  AKS_RG AKS_NAME DOCKER_RUN_FILE DOCKER_FORCE_EXIT DOCKER_FAIL_ON DOCKER_FAKE_OUTPUT TERM_PROGRAM

ENV_BIN=$(command -v env)
ALIASES_SH=$TEST_ROOT/scripts/shell/aliases.sh

# Run a snippet in a fresh bash that has devtools.sh loaded, from the scratch folder.
# OUT = what it printed (output and errors), RC = its exit code.
dt() {
  RC=0
  OUT=$(cd "$WORK" && "$ENV_BIN" HOME="$HOME_DIR" "$BASH" -c '. "$DEVTOOLS_SH" || echo "LOAD FAILED"; '"$1" 2>&1) || RC=$?
  OUT=${OUT//$'\r'/}   # docker.exe ends its lines with CR LF
}
# The same without loading devtools.sh first.
bare() {
  RC=0
  OUT=$(cd "$WORK" && "$ENV_BIN" HOME="$HOME_DIR" "$BASH" -c "$1" 2>&1) || RC=$?
  OUT=${OUT//$'\r'/}
}
# The arguments of the last docker call, joined with |.
last_args() {
  local s
  s=$(tr -d '\r' < "$DOCKER_ARGS_FILE" | tr '\n' '|')
  printf '%s' "${s%|}"
}

WORK_NATIVE=$(cd "$WORK" && to_native "$PWD")
BASE="run|--rm|-i|-v|devtools-home:/root|-v|$WORK_NATIVE:/work|-w|/work|devtools:latest"

# ---- Loading ---------------------------------------------------------------------------------------
dt ''
check_eq 'sourcing devtools.sh prints nothing' "$OUT" ''
check_eq 'sourcing devtools.sh succeeds' "$RC" 0

bare 'set -u; . "$DEVTOOLS_SH"; az --version; echo done-$?'
check_has 'it loads and runs under set -u' "$OUT" 'done-0'
check_lacks 'set -u finds nothing unset' "$OUT" 'unbound'

bare 'set -eu; . "$DEVTOOLS_SH"; echo done'
check_eq 'it loads under set -eu' "$OUT" 'done'

expected_count=$(($(grep -c '^alias ' "$ALIASES_SH") + $(grep -c '^aks[a-z]*() {' "$ALIASES_SH")))
bare 'cd "$TEST_ROOT/tests" && CDPATH=/tmp . ../devtools.sh && devtools-alias --count'
check_eq 'a relative path and a CDPATH do not confuse it' "$OUT" "$expected_count"

mkdir -p "$TMP/a folder/scripts/shell"
cp "$TEST_ROOT/devtools.sh" "$TMP/a folder/"
cp "$ALIASES_SH" "$TMP/a folder/scripts/shell/"
bare ". '$TMP/a folder/devtools.sh' && devtools-alias --count"
check_eq 'it loads from a folder with a space in its name' "$OUT" "$expected_count"

mkdir -p "$TMP/lonely"
cp "$TEST_ROOT/devtools.sh" "$TMP/lonely/"
bare ". '$TMP/lonely/devtools.sh'; az x; echo rc=\$?"
check_has 'without its shortcuts file it says so' "$OUT" 'shortcuts file'
check_has 'and the tools still work' "$OUT" 'rc=0'

if [ -z "$(sh -c 'echo "${BASH_VERSION:-}"' 2> /dev/null)" ]; then
  RC=0
  OUT=$(cd "$WORK" && sh -c '. "$DEVTOOLS_SH"; echo "rc=$?"' 2>&1) || RC=$?
  check_has 'another shell is told to use bash' "$OUT" 'is for bash'
  check_has 'and sourcing fails there' "$OUT" 'rc=1'
else
  check_skip 'another shell is told to use bash' 'sh is bash here'
fi

# ---- The tools -------------------------------------------------------------------------------------
dt 'az account show -o table'
check_eq 'az runs in the container: volume, current folder, image' "$(last_args)" "$BASE|az|account|show|-o|table"
check_eq 'it prints what the container prints' "$OUT" ''
for tool in kubectl terraform flux helm kustomize azd gh kubectx kubens; do
  dt "$tool one two"
  check_eq "$tool runs in the container" "$(last_args)" "$BASE|$tool|one|two"
done
if is_windows; then
  check_has 'the folder is mounted in its Windows form' "$(last_args)" ":/work|-w|/work"
  if [[ $WORK_NATIVE =~ ^[A-Za-z]:/ ]]; then check_pass 'and that form starts with a drive letter'; else check_fail 'and that form starts with a drive letter' "$WORK_NATIVE"; fi
fi

SNIPPET=$(
  cat << 'EOF'
kubectl patch deploy x -p '{"a":"b c"}' '' '*' /subscriptions/x --flag=/path '~' '$HOME' "it's" 'two  spaces' -o jsonpath='{.items[*].metadata.name}'
EOF
)
dt "$SNIPPET"
check_eq 'arguments arrive exactly as typed (quotes, spaces, empty, glob, /paths)' "$(last_args)" \
  "$BASE|kubectl|patch|deploy|x|-p|{\"a\":\"b c\"}||*|/subscriptions/x|--flag=/path|~|\$HOME|it's|two  spaces|-o|jsonpath={.items[*].metadata.name}"

DOCKER_FORCE_EXIT=3 dt 'az fail'
check_eq "the tool's exit code is the function's" "$RC" 3

DOCKER_FAKE_OUTPUT=1 dt 'az x | cat'
check_eq 'output goes through a pipe untouched' "$OUT" 'fake docker run ok'

DEVTOOLS_IMAGE=my/img:1 DEVTOOLS_VOLUME=myvol dt 'az x'
check_eq 'DEVTOOLS_IMAGE and DEVTOOLS_VOLUME are honoured' "$(last_args)" "run|--rm|-i|-v|myvol:/root|-v|$WORK_NATIVE:/work|-w|/work|my/img:1|az|x"

mkdir -p "$TMP/other dir"
OTHER_NATIVE=$(cd "$TMP/other dir" && to_native "$PWD")
bare ". '$DEVTOOLS_SH'; cd '$TMP/other dir' && az x"
check_eq 'the folder you are in is the one that is mounted' "$(last_args)" "run|--rm|-i|-v|devtools-home:/root|-v|$OTHER_NATIVE:/work|-w|/work|devtools:latest|az|x"

dt 'type -t az kubectl terraform kubectx dev devtools-info'
check_eq 'the tools are shell functions' "$OUT" "$(printf 'function\nfunction\nfunction\nfunction\nfunction\nfunction')"

mkdir -p "$TMP_POSIX/realbin"
printf '#!/bin/sh\necho REAL-AZ\n' > "$TMP_POSIX/realbin/az"
chmod +x "$TMP_POSIX/realbin/az"
PATH="$TMP_POSIX/realbin:$PATH" dt 'az x; command az'
check_eq 'an installed az is shadowed, and `command az` still reaches it' "$OUT" 'REAL-AZ'
PATH="$TMP_POSIX/realbin:$PATH" dt 'az x'
check_eq 'the shadowing call went to the container' "$(last_args)" "$BASE|az|x"

mkdir -p "$TMP_POSIX/empty"
PATH="$TMP_POSIX/empty" dt 'az x; echo rc=$?'
check_has 'without docker on PATH it says so' "$OUT" 'docker was not found on PATH'
check_has 'and returns 127' "$OUT" 'rc=127'

# ---- dev -------------------------------------------------------------------------------------------
dt 'dev'
check_eq 'dev starts the image default shell' "$(last_args)" "$BASE"
dt 'dev bash -c "echo hi"'
check_eq 'dev runs the command you give' "$(last_args)" "$BASE|bash|-c|echo hi"
AKS_RG=my-rg AKS_NAME='my cluster' dt 'dev'
check_eq 'AKS_RG and AKS_NAME are handed to the shell inside' "$(last_args)" \
  "run|--rm|-i|-v|devtools-home:/root|-v|$WORK_NATIVE:/work|-w|/work|-e|AKS_RG=my-rg|-e|AKS_NAME=my cluster|devtools:latest"
dt 'AKS_RG=not-exported; dev'
check_eq 'an AKS_RG that was set without export is passed too' "$(last_args)" \
  "run|--rm|-i|-v|devtools-home:/root|-v|$WORK_NATIVE:/work|-w|/work|-e|AKS_RG=not-exported|devtools:latest"

# ---- Shortcuts -------------------------------------------------------------------------------------
dt 'devtools-alias --count'
check_eq 'devtools-alias --count counts aliases.sh (aliases plus aksc, aksup, aksx)' "$OUT" "$expected_count"
dt 'devtools-alias'
check_has 'devtools-alias lists the Azure shortcuts' "$OUT" 'Azure      azwho      az account show -o table'
check_has 'devtools-alias lists the AKS shortcuts' "$OUT" 'AKS        aksl       az aks list -o table'
check_has 'devtools-alias lists the kubectl shortcuts' "$OUT" 'kubectl    kgp        kubectl get pods'
check_has 'devtools-alias lists the Terraform shortcuts' "$OUT" 'Terraform  tfp        terraform plan -out=tfplan'
check_has 'devtools-alias lists the AKS helpers' "$OUT" 'aksx'
check_lacks 'and none is marked as yours' "$OUT" 'Yours'
dt "devtools-alias 'kg*'"
check_has 'devtools-alias PATTERN filters' "$OUT" 'kgpa'
check_lacks 'devtools-alias PATTERN leaves the others out' "$OUT" 'Terraform'

dt 'shopt -s expand_aliases; eval "kgp -n kube-system"'
check_eq 'kgp -n kube-system runs kubectl get pods -n kube-system' "$(last_args)" "$BASE|kubectl|get|pods|-n|kube-system"
dt 'shopt -s expand_aliases; eval "tfp -var x=1"'
check_eq 'tfp -var x=1 runs terraform plan -out=tfplan -var x=1' "$(last_args)" "$BASE|terraform|plan|-out=tfplan|-var|x=1"
dt 'shopt -s expand_aliases; eval "kex my-pod -- ls -la"'
check_eq 'kex pod -- ls -la keeps the double dash' "$(last_args)" "$BASE|kubectl|exec|-it|my-pod|--|ls|-la"
dt 'shopt -s expand_aliases; eval "kx; kn"'
check_eq 'kx and kn are kubectx and kubens' "$(last_args)" "$BASE|kubens"

AKS_RG=my-rg AKS_NAME=my-cluster dt 'aksc'
check_eq 'aksc uses AKS_RG and AKS_NAME' "$(last_args)" "$BASE|az|aks|get-credentials|-g|my-rg|-n|my-cluster|--overwrite-existing"
dt 'aksc other-rg other-name --admin'
check_eq 'aksc RG NAME [flags] takes them from the line' "$(last_args)" "$BASE|az|aks|get-credentials|-g|other-rg|-n|other-name|--overwrite-existing|--admin"
AKS_RG=my-rg AKS_NAME=my-cluster dt 'aksup'
check_eq 'aksup asks for the upgrades' "$(last_args)" "$BASE|az|aks|get-upgrades|-g|my-rg|-n|my-cluster|-o|table"
AKS_RG=my-rg AKS_NAME=my-cluster dt 'aksx kubectl get nodes'
check_eq 'aksx runs a command inside the private cluster' "$(last_args)" "$BASE|az|aks|command|invoke|-g|my-rg|-n|my-cluster|--command|kubectl get nodes"
dt 'aksc; echo rc=$?'
check_has 'aksc without a cluster says what to set' "$OUT" 'set AKS_RG and AKS_NAME'
check_has 'and returns 1' "$OUT" 'rc=1'

# ---- Your own shortcuts ----------------------------------------------------------------------------
cat > "$HOME_DIR/.devtools-aliases.sh" << 'EOF'
alias kgi='kubectl get ingress'
alias kgp='kubectl get pods -o wide'
mything() { echo hi; }
aksx() { echo "my own aksx"; }
export MY_EXPORT=kept
EOF
dt 'shopt -s expand_aliases; eval "kgi -A"; echo "MY_EXPORT=$MY_EXPORT"; devtools-alias | grep Yours'
check_has 'an alias from your file works' "$(last_args)" "kubectl|get|ingress|-A"
check_has 'what your file exports stays exported' "$OUT" 'MY_EXPORT=kept'
check_has 'your new alias is listed as yours' "$OUT" 'Yours      kgi'
check_has 'your new function is listed as yours' "$OUT" 'Yours      mything'
check_has 'a built-in you replaced is listed as yours' "$OUT" 'Yours      kgp'
check_has 'a built-in function you replaced is listed as yours' "$OUT" 'Yours      aksx'
dt 'shopt -s expand_aliases; eval "kgp"'
check_eq 'your kgp wins over the built-in one' "$(last_args)" "$BASE|kubectl|get|pods|-o|wide"
dt 'aksx; echo rc=$?'
check_has 'your aksx wins too' "$OUT" 'my own aksx'
dt 'devtools-alias --count'
check_eq 'the count is of the built-in shortcuts only' "$OUT" "$expected_count"
dt 'complete -p kgi az 2>&1'
check_has 'your alias for a tool gets Tab completion' "$OUT" '-F _devtools_complete kgi'
check_has 'and so does the tool' "$OUT" '-F _devtools_complete az'

printf 'this_command_does_not_exist_xyz\n' >> "$HOME_DIR/.devtools-aliases.sh"
dt 'type -t az'
check_has 'a failing line in your file is reported by bash with the file name' "$OUT" '.devtools-aliases.sh: line 6'
check_has 'and the toolbox still loads' "$OUT" 'function'

printf 'fi\n' >> "$HOME_DIR/.devtools-aliases.sh"
dt 'type -t az'
check_has 'a syntax error in your file is reported' "$OUT" 'syntax error'
check_has 'and the toolbox still loads after it' "$OUT" 'function'

printf 'alias viaenv=%s\n' "'kubectl get ns'" > "$TMP/elsewhere.sh"
DEVTOOLS_BASH_ALIASES=$TMP/elsewhere.sh dt 'shopt -s expand_aliases; eval "viaenv"; devtools-info'
check_has 'DEVTOOLS_BASH_ALIASES names another file' "$(last_args)" 'kubectl|get|ns'
check_has 'devtools-info shows which file it is' "$OUT" "AliasesFile  $TMP/elsewhere.sh"
rm -f "$HOME_DIR/.devtools-aliases.sh"

dt 'devtools-info'
check_has 'devtools-info shows the image' "$OUT" 'Image        devtools:latest'
check_has 'devtools-info shows the volume' "$OUT" 'Volume       devtools-home'
check_has 'devtools-info lists the tools' "$OUT" 'az, kubectl, terraform, flux, helm, kustomize, azd, gh, kubectx, kubens, dev'

# ---- Docker Desktop Kubernetes -----------------------------------------------------------------------
dt 'devtools-import-kube; echo rc=$?'
check_has 'devtools-import-kube without a kubeconfig says where to get one' "$OUT" 'No kubeconfig at'
check_has 'and points at Docker Desktop > Settings > Kubernetes' "$OUT" 'Settings > Kubernetes'
check_has 'and fails' "$OUT" 'rc=1'
mkdir -p "$HOME_DIR/.kube"
printf 'apiVersion: v1\n' > "$HOME_DIR/.kube/config"
KUBE_NATIVE=$(to_native "$HOME_DIR/.kube/config")
dt 'devtools-import-kube'
check_eq 'it mounts the one kubeconfig read-only and runs the importer' "$(last_args)" \
  "run|--rm|-i|-v|devtools-home:/root|-v|$KUBE_NATIVE:/hostkube/config:ro|devtools:latest|import-docker-desktop-kube|docker-desktop"
dt "devtools-import-kube my-ctx '$HOME_DIR/.kube/config'"
check_eq 'a context and a kubeconfig can be given' "$(last_args)" \
  "run|--rm|-i|-v|devtools-home:/root|-v|$KUBE_NATIVE:/hostkube/config:ro|devtools:latest|import-docker-desktop-kube|my-ctx"
DOCKER_FORCE_EXIT=127 dt 'devtools-import-kube; echo rc=$?'
check_has 'an image without the importer says to rebuild' "$OUT" 'docker compose build'
check_has 'and returns 127' "$OUT" 'rc=127'

# ---- Tab completion --------------------------------------------------------------------------------
# _devtools_complete is called the way bash calls a completion function; the fake docker plays the container.
PRELUDE='comp() { COMP_LINE=$1; COMP_POINT=${2:-${#1}}; read -ra COMP_WORDS <<< "${1:0:$COMP_POINT}"; case ${1:0:$COMP_POINT} in *" ") COMP_WORDS+=("");; esac; COMP_CWORD=$(( ${#COMP_WORDS[@]} - 1 )); _devtools_complete; echo "[$1] -> ${COMPREPLY[*]}"; }; '
printf 'pods\tPod list\nport-forward\nservices\n' > "$TMP/canned"
export DOCKER_RUN_FILE=$TMP/canned
dt "$PRELUDE"'comp "kubectl get "'
check_has 'Tab on kubectl offers what the container answers (descriptions dropped)' "$OUT" '[kubectl get ] -> pods port-forward services'
check_eq 'the container is asked with the tool, the line and the cursor' "$(last_args)" \
  'run|--rm|-v|devtools-home:/root|devtools:latest|devtools-complete|kubectl|kubectl get |12'
dt "$PRELUDE"'comp "kgp -n "'
check_eq 'a shortcut is completed as the command it stands for' "$(last_args)" \
  'run|--rm|-v|devtools-home:/root|devtools:latest|devtools-complete|kubectl|kubectl get pods -n |20'
dt "$PRELUDE"'comp "  tf ap"'
check_eq 'leading blanks do not matter' "$(last_args)" \
  'run|--rm|-v|devtools-home:/root|devtools:latest|devtools-complete|terraform|terraform ap|12'
dt "$PRELUDE"'comp "kubectl get pods" 11'
check_eq 'only the text before the cursor is sent' "$(last_args)" \
  'run|--rm|-v|devtools-home:/root|devtools:latest|devtools-complete|kubectl|kubectl get|11'
rm -f "$DOCKER_ARGS_FILE"
dt "$PRELUDE"'comp "ls -l "'
check_has 'a command that is not a toolbox tool gets nothing' "$OUT" '[ls -l ] -> '
check_no 'and docker is not even called for it' test -e "$DOCKER_ARGS_FILE"
printf -- '--output=json\n--output=table\n--output=tsv\n' > "$TMP/canned"
dt "$PRELUDE"'comp "az account show --output="'
check_has 'the part of the word before = is taken off (bash completes after it)' "$OUT" '-> json table tsv'
printf 'default.azurecr.io:latest\ndefault.azurecr.io:v2\n' > "$TMP/canned"
dt "$PRELUDE"'comp "az acr repository show --image default.azurecr.io:"'
check_has 'the same for a colon' "$OUT" '-> latest v2'
printf 'my file/\nplain\nplain\n\n  spaced  \n' > "$TMP/canned"
dt "$PRELUDE"'comp "terraform "'
check_has 'values are quoted for the shell, duplicates and blank lines dropped' "$OUT" '-> my\ file/ plain spaced'
awk 'BEGIN { for (i = 1; i <= 300; i++) printf "value%03d\n", i }' > "$TMP/canned"
dt "$PRELUDE"'comp "helm "; set -- $COMPREPLY; echo count=${#COMPREPLY[@]}'
check_has 'at most 200 answers are used' "$OUT" 'count=200'
: > "$TMP/canned"
DOCKER_FORCE_EXIT=1 dt "$PRELUDE"'comp "kubectl get "'
check_has 'a docker that fails gives no answers and no error' "$OUT" '[kubectl get ] -> '
dt 'complete -p az kubectl terraform flux helm kustomize azd gh kgp tfp azl 2>&1'
check_lacks 'every tool and shortcut that stands for one is registered' "$OUT" 'no completion specification'
check_has 'the registration uses _devtools_complete' "$OUT" '-F _devtools_complete kgp'
dt 'complete -p ls 2>&1'
check_has 'other commands are left alone' "$OUT" 'no completion specification'
unset DOCKER_RUN_FILE

# ---- Taking it out again -----------------------------------------------------------------------------
dt 'unset DEVTOOLS_SH; devtools-unload; echo "type: $(type -t az || echo none)"; echo "aliases: $(alias | wc -l | tr -d " ")"; echo "specs: $(complete -p | grep -c -i devtools)"; echo "funcs: $(compgen -A function | grep -c -i devtools)"; echo "vars: $(compgen -v | grep -c -i devtools)"; echo "aks: $(type -t aksc || echo none)"'
check_lacks 'devtools-unload removes the tool functions' "$OUT" 'type: function'
check_has 'and the shortcuts' "$OUT" 'aliases: 0'
check_has 'and the helper functions of the shortcuts' "$OUT" 'aks: none'
check_has 'and the Tab completion' "$OUT" 'specs: 0'
check_has 'and every function of its own' "$OUT" 'funcs: 0'
check_has 'and every variable of its own' "$OUT" 'vars: 0'

# ---- Written for bash 4.2 ----------------------------------------------------------------------------
newer=$(grep -nE '\$\{[A-Za-z_]+@[QEPAaKk]\}|(local|declare|typeset) -[a-zA-Z]*n |\[-[0-9]+\]\}|\$EPOCH(SECONDS|REALTIME)|\$BASH_ARGV0|wait -n|mapfile -d|read -N|\$SRANDOM|\$\{[A-Za-z_]+\[-' \
  "$TEST_ROOT/devtools.sh" "$TEST_ROOT/setup.sh" "$TEST_ROOT/uninstall.sh" || true)
check_eq 'the scripts use nothing newer than bash 4.2 (namerefs, negative indexes, @Q ...)' "$newer" ''

check_summary
