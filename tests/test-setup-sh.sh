#!/usr/bin/env bash
# Tests for setup.sh. Every scenario copies the project into a scratch folder (its name has a space in
# it on purpose), runs setup.sh there in a child bash with a scratch home folder and a fake `docker`,
# and checks the exit code, the output, the docker calls it made and the startup files it wrote. No
# Docker daemon is needed, and your own ~/.bashrc is never read or changed.
#
#     bash tests/test-setup-sh.sh
#
# Works in bash on Linux and macOS and in Git Bash on Windows (where the fake is a docker.exe).
# The fake docker and its knobs are described at the top of tests/fakebin/docker.
# shellcheck disable=SC1091,SC2016
set -u
. "$(dirname -- "$0")/lib.sh"

echo "bash $BASH_VERSION on ${OSTYPE:-unknown}"
install_fake_docker

TMP_POSIX=$(mktemp -d)
trap 'rm -rf "$TMP_POSIX"' EXIT
TMP=$(to_native "$TMP_POSIX")
HOME_DIR=$TMP/home
PROJ="$TMP/my project"                # a space on purpose
LOG=$TMP/docker.log
export DOCKER_ARGS_FILE=$TMP/args.txt
export DOCKER_LOG_FILE=$LOG           # every docker call is appended here
export DOCKER_FAKE_OUTPUT=1           # `docker run` prints a line, like a tool printing its version
unset DEVTOOLS_IMAGE DEVTOOLS_VOLUME DEVTOOLS_BASH_ALIASES DEVTOOLS_WINPTY DEVTOOLS_NO_READLINE TERM_PROGRAM NO_COLOR \
  AKS_RG AKS_NAME DOCKER_RUN_FILE DOCKER_FORCE_EXIT DOCKER_FAIL_ON DOCKER_SERVER DOCKER_VERSION_EXIT \
  DOCKER_COMPOSE_EXIT DOCKER_BUILD_EXIT DOCKER_IMAGE_EXIT DOCKER_PS_FILE DOCKER_VOLUMES SCRIPT_INPUT

MARKER='# DevOps toolbox: az, kubectl, terraform, helm, flux ... run in Docker'
LOGIN_MARKER='# DevOps toolbox: make login shells read ~/.bashrc too'
LOGIN_LINE='[ -r ~/.bashrc ] && . ~/.bashrc'
ALIASES_FILE=$HOME_DIR/.devtools-aliases.sh
expected_count=$(($(grep -c '^alias ' "$TEST_ROOT/scripts/shell/aliases.sh") + $(grep -c '^aks[a-z]*() {' "$TEST_ROOT/scripts/shell/aliases.sh")))

# Written independently of setup.sh: a string in single quotes, each ' in it as '\''.
quote_sq() {
  local s=$1 out="'" i ch
  for ((i = 0; i < ${#s}; i++)); do
    ch=${s:i:1}
    if [ "$ch" = "'" ]; then out+="'\\''"; else out+=$ch; fi
  done
  printf '%s' "$out'"
}

fresh() {
  new_project "$PROJ"
  rm -rf "$HOME_DIR"
  mkdir -p "$HOME_DIR"
  : > "$LOG"
}
setup() { run_script "$PROJ" "$HOME_DIR" setup.sh "$@"; }
logged() { grep -cF -- "$1" "$LOG"; }
check_file() { # NAME FILE EXACT-CONTENT
  printf '%s' "$3" > "$TMP/expected"
  check_same "$1" "$2" "$TMP/expected"
}

fresh
PROJ_ROOT=$(cd "$PROJ" && pwd)         # the form setup.sh sees (/c/Users/... in Git Bash)
PROJ_NATIVE=$(cd "$PROJ" && to_native "$PWD")
IMPORT_LINE=". $(quote_sq "$PROJ_ROOT/devtools.sh")"

# ---- A first run -------------------------------------------------------------------------------------
setup --no-prompt
check_eq 'a first run succeeds' "$RC" 0
check_has 'it says it is done' "$OUT" 'All set.'
check_has 'it found a Linux engine' "$OUT" 'Docker engine 99.0.0-fake, Linux containers'
check_eq 'the engine question reaches docker unchanged' "$(logged 'version --format {{.Server.Os}}/{{.Server.Version}}')" 1
check_eq '.env is made from .env.example' "$(cmp -s "$PROJ/.env" "$PROJ/.env.example" && echo same)" same
check_eq 'the image is built with docker compose' "$(logged 'compose build')" 1
check_file 'the startup file gets the comment and the line that loads devtools.sh' "$HOME_DIR/.bashrc" "$MARKER"$'\n'"$IMPORT_LINE"$'\n'
check_file 'login shells are made to read ~/.bashrc' "$HOME_DIR/.bash_profile" "$LOGIN_MARKER"$'\n'"$LOGIN_LINE"$'\n'
check_ok 'a file for your own shortcuts is made' test -f "$ALIASES_FILE"
check_has 'and it explains how to add one' "$(cat "$ALIASES_FILE")" "alias kgj='kubectl get pods -o json'"
check_has 'the built-in shortcuts are counted' "$OUT" "$expected_count shortcuts"
check_eq 'every tool is checked inside the container, plus the completion helper' "$(grep -c '^run ' "$LOG")" 11
for check in 'az --version' 'kubectl version --client' 'terraform version' 'helm version --short' 'flux --version' \
  'kustomize version' 'azd version' 'gh --version' 'kubectx -h' 'kubens -h'; do
  check_eq "it ran: $check" "$(logged "run --rm -i -v devtools-home:/root -v $PROJ_NATIVE:/work -w /work devtools:latest $check")" 1
done
check_eq 'the completion helper is looked for in the image' "$(logged 'run --rm devtools:latest devtools-complete')" 1
check_has 'a tool answers with its first line' "$OUT" 'OK    az         fake docker run ok'
check_has 'the end tells how to load it in this terminal' "$OUT" "    $IMPORT_LINE"
check_has 'and what to do next' "$OUT" 'az login --use-device-code'
check_eq 'nothing in the project folder changed except .env' "$(cd "$PROJ" && shopt -s dotglob nullglob && printf '%s\n' * | LC_ALL=C sort | tr '\n' ' ')" \
  '.env .env.example Dockerfile certs devtools.sh docker-compose.yml scripts setup.sh uninstall.sh '

# The line works: a new terminal gets the functions, also a login shell.
RC=0
OUT=$("$ENV_BIN" HOME="$HOME_DIR" "$BASH" -c '. "$HOME/.bashrc"; echo "T:$(type -t az) $(type -t kubectl) $(type -t dev)"' 2>&1) || RC=$?
check_eq 'a new interactive-style shell has the tools after the startup file' "$OUT" 'T:function function function'
OUT=$("$ENV_BIN" HOME="$HOME_DIR" "$BASH" --login -c 'echo "T:$(type -t az)"' 2>&1 | tail -n 1) || true
check_eq 'a login shell has them too, through the line in .bash_profile' "$OUT" 'T:function'

# ---- Running it again --------------------------------------------------------------------------------
cp "$HOME_DIR/.bashrc" "$TMP/bashrc.first"
cp "$HOME_DIR/.bash_profile" "$TMP/bash_profile.first"
printf 'MARK\n' >> "$PROJ/.env"
printf '# mine\nalias zz="echo zz"\n' > "$ALIASES_FILE"
cp "$ALIASES_FILE" "$TMP/aliases.mine"
: > "$LOG"
setup --no-prompt
check_eq 'a second run succeeds' "$RC" 0
check_has 'it knows the line is there' "$OUT" 'already set up in'
check_same 'the startup file is the same, byte for byte' "$HOME_DIR/.bashrc" "$TMP/bashrc.first"
check_same 'so is .bash_profile' "$HOME_DIR/.bash_profile" "$TMP/bash_profile.first"
check_same 'your shortcuts file is never overwritten' "$ALIASES_FILE" "$TMP/aliases.mine"
check_has '.env is kept' "$OUT" '.env already exists, keeping it'
check_has 'and has what you put in it' "$(cat "$PROJ/.env")" 'MARK'
check_has 'login shells are recognised as set up' "$OUT" 'login shells already read ~/.bashrc'
check_ok 'no backup is made when nothing changes' test ! -e "$HOME_DIR/.bashrc.bak"

# ---- An older line, the project moved ------------------------------------------------------------------
fresh
printf '# my stuff\nexport FOO=1\n\n%s\n. '"'"'/old/place/devtools.sh'"'"'\nalias ll="ls -l"\n' "$MARKER" > "$HOME_DIR/.bashrc"
cp "$HOME_DIR/.bashrc" "$TMP/bashrc.before"
setup --no-prompt
check_eq 'an older line is replaced' "$RC" 0
check_has 'it says so' "$OUT" 'updated the existing devtools.sh line'
check_file 'only that line changed' "$HOME_DIR/.bashrc" $'# my stuff\nexport FOO=1\n\n'"$MARKER"$'\n'"$IMPORT_LINE"$'\nalias ll="ls -l"\n'
check_same 'the old file is kept as .bak' "$HOME_DIR/.bashrc.bak" "$TMP/bashrc.before"

fresh
printf '. /a/devtools.sh\nexport X=1\nsource "/b/devtools.sh"\n  . ~/c/devtools.sh  \n' > "$HOME_DIR/.bashrc"
setup --no-prompt
check_file 'several older lines become one' "$HOME_DIR/.bashrc" "$IMPORT_LINE"$'\nexport X=1\n'

# ---- Where the line goes ---------------------------------------------------------------------------------
fresh
printf 'export A=1' > "$HOME_DIR/.bashrc"
setup --no-prompt
check_file 'a startup file without a final newline is finished first' "$HOME_DIR/.bashrc" $'export A=1\n\n'"$MARKER"$'\n'"$IMPORT_LINE"$'\n'

fresh
printf 'export A=1\r\nalias ll="ls -l"\r\n' > "$HOME_DIR/.bashrc"
setup --no-prompt
check_file 'a file with Windows line endings keeps them, the new lines are added after' "$HOME_DIR/.bashrc" $'export A=1\r\nalias ll="ls -l"\r\n\n'"$MARKER"$'\n'"$IMPORT_LINE"$'\n'
setup --no-prompt
check_has 'and is recognised the next time' "$OUT" 'already set up in'

fresh
setup --skip-profile --no-prompt
check_eq '--skip-profile: succeeds' "$RC" 0
check_ok '--skip-profile: no .bashrc is made' test ! -e "$HOME_DIR/.bashrc"
check_ok '--skip-profile: no .bash_profile either' test ! -e "$HOME_DIR/.bash_profile"
check_has '--skip-profile: it says how to load the tools by hand' "$OUT" 'Your startup files were not changed'

fresh
setup --rc-file "$TMP/custom rc" --no-prompt
check_eq '--rc-file: succeeds' "$RC" 0
check_file '--rc-file: that file gets the line' "$TMP/custom rc" "$MARKER"$'\n'"$IMPORT_LINE"$'\n'
check_ok '--rc-file: ~/.bashrc is not touched' test ! -e "$HOME_DIR/.bashrc"
check_ok '--rc-file: nor .bash_profile' test ! -e "$HOME_DIR/.bash_profile"
rm -f "$TMP/custom rc"

# --- login shells
fresh
printf 'export P=1\n' > "$HOME_DIR/.bash_profile"
setup --no-prompt
check_file 'a .bash_profile that does not read ~/.bashrc gets the line, below what is there' "$HOME_DIR/.bash_profile" $'export P=1\n\n'"$LOGIN_MARKER"$'\n'"$LOGIN_LINE"$'\n'

fresh
printf 'if [ -f ~/.bashrc ]; then . ~/.bashrc; fi\n' > "$HOME_DIR/.bash_profile"
cp "$HOME_DIR/.bash_profile" "$TMP/bp.before"
setup --no-prompt
check_same 'a .bash_profile that reads ~/.bashrc is left alone' "$HOME_DIR/.bash_profile" "$TMP/bp.before"

fresh
printf '# . ~/.bashrc\nexport P=1\n' > "$HOME_DIR/.bash_profile"
setup --no-prompt
check_has 'a commented-out mention of .bashrc does not count' "$(cat "$HOME_DIR/.bash_profile")" "$LOGIN_LINE"

fresh
printf 'if [ -n "$BASH_VERSION" ]; then\n  if [ -f "$HOME/.bashrc" ]; then\n    . "$HOME/.bashrc"\n  fi\nfi\n' > "$HOME_DIR/.profile"
cp "$HOME_DIR/.profile" "$TMP/profile.before"
setup --no-prompt
check_same 'only a .profile, as on Ubuntu, that reads ~/.bashrc: left alone' "$HOME_DIR/.profile" "$TMP/profile.before"
check_ok 'and no .bash_profile is made (it would hide .profile)' test ! -e "$HOME_DIR/.bash_profile"

fresh
printf 'export L=1\n' > "$HOME_DIR/.bash_login"
setup --no-prompt
check_has 'with only a .bash_login, that is the file login shells read, so it gets the line' "$(cat "$HOME_DIR/.bash_login")" "$LOGIN_LINE"
check_ok 'and no .bash_profile is made' test ! -e "$HOME_DIR/.bash_profile"

# ---- A folder name with a quote in it -----------------------------------------------------------------------
QPROJ="$TMP/it's here"
new_project "$QPROJ"
fresh_home=$HOME_DIR
rm -rf "$fresh_home"
mkdir -p "$fresh_home"
run_script "$QPROJ" "$fresh_home" setup.sh --no-prompt
check_eq 'a project folder with a quote in its name: succeeds' "$RC" 0
QROOT=$(cd "$QPROJ" && pwd)
check_file 'and the quote is escaped in the line' "$HOME_DIR/.bashrc" "$MARKER"$'\n'". $(quote_sq "$QROOT/devtools.sh")"$'\n'
RC=0
OUT=$("$ENV_BIN" HOME="$HOME_DIR" "$BASH" -c '. "$HOME/.bashrc"; echo "T:$(type -t az)"' 2>&1) || RC=$?
check_eq 'and the line loads the toolbox' "$OUT" 'T:function'
rm -rf "$QPROJ"

# ---- Things that go wrong ---------------------------------------------------------------------------------------
fresh
mkdir -p "$TMP_POSIX/empty"
PATH="$TMP_POSIX/empty" setup --no-prompt
check_eq 'no docker: exit code 1' "$RC" 1
check_has 'no docker: it says so' "$OUT" 'docker was not found on PATH'
check_ok 'no docker: nothing was written' test ! -e "$HOME_DIR/.bashrc"

fresh
DOCKER_VERSION_EXIT=1 setup --no-prompt
check_eq 'engine not running: exit code 1' "$RC" 1
check_has 'engine not running: it says so' "$OUT" 'engine is not running'

fresh
DOCKER_SERVER=windows/99.0.0 setup --no-prompt
check_eq 'Windows containers: exit code 1' "$RC" 1
check_has 'Windows containers: it says to switch' "$OUT" "Switch to Linux containers"

fresh
DOCKER_BUILD_EXIT=1 setup --no-prompt
check_eq 'a failed build: exit code 1' "$RC" 1
check_has 'a failed build: it gives the usual causes' "$OUT" 'TLS inspection'
check_has 'a failed build: and the exit code' "$OUT" 'The image build failed (exit code 1)'
check_ok 'a failed build: the startup file is not touched' test ! -e "$HOME_DIR/.bashrc"

fresh
DOCKER_IMAGE_EXIT=1 setup --skip-build --no-prompt
check_eq '--skip-build without an image: exit code 1' "$RC" 1
check_has '--skip-build without an image: it says so' "$OUT" 'does not exist yet'

fresh
setup --skip-build --no-prompt
check_eq '--skip-build with an image: succeeds' "$RC" 0
check_eq '--skip-build with an image: nothing is built' "$(logged 'build')" 0

fresh
setup --skip-verify --no-prompt
check_eq '--skip-verify: succeeds' "$RC" 0
check_eq '--skip-verify: no tool is run' "$(grep -c '^run ' "$LOG")" 0

fresh
DOCKER_FAIL_ON=terraform setup --no-prompt
check_eq 'a tool that fails its check: exit code 2' "$RC" 2
check_has 'a tool that fails its check: it is named' "$OUT" 'FAIL  terraform'
check_has 'a tool that fails its check: and counted' "$OUT" '1 problem(s) above need attention'
check_has 'a tool that fails its check: the rest was still set up' "$(cat "$HOME_DIR/.bashrc")" "$IMPORT_LINE"

fresh
DOCKER_FAIL_ON=devtools-complete setup --no-prompt
check_eq 'an image without the completion helper: still exit code 0' "$RC" 0
check_has 'an image without the completion helper: it warns' "$OUT" 'no Tab completion helper yet'

fresh
rm "$PROJ/Dockerfile"
setup --no-prompt
check_eq 'run from a folder without the Dockerfile: exit code 1' "$RC" 1
check_has 'run from a folder without the Dockerfile: it says what is missing' "$OUT" 'Cannot find Dockerfile'

fresh
DOCKER_COMPOSE_EXIT=1 setup --no-prompt
check_eq 'without docker compose: succeeds' "$RC" 0
check_has 'without docker compose: it says so' "$OUT" "'docker compose' is not available"
check_eq 'without docker compose: docker build is used' "$(logged 'build -t devtools:latest .')" 1

fresh
setup --rc-file /dev/null/x --no-prompt
check_eq 'a startup file that cannot be written: exit code 2' "$RC" 2
check_has 'a startup file that cannot be written: it gives the line to add by hand' "$OUT" "    $IMPORT_LINE"

fresh
printf -- '-----BEGIN CERTIFICATE-----\n' > "$PROJ/certs/corp.crt"
setup --no-prompt
check_has 'a CA certificate in certs/ is noticed' "$OUT" '1 corporate CA certificate(s) in certs/'

# ---- The two optional steps -------------------------------------------------------------------------------------
fresh
setup --login --no-prompt
check_eq '--login: succeeds' "$RC" 0
check_eq '--login: signs in with a device code' "$(logged 'devtools:latest az login --use-device-code')" 1
check_has '--login: the next-steps list no longer offers it' "$(printf '%s' "$OUT" | sed -n '/^Next:/,$p')" 'devtools-import-kube'
check_lacks '--login: the next-steps list no longer offers the login' "$(printf '%s' "$OUT" | sed -n '/^Next:/,$p')" 'az login --use-device-code'

fresh
DOCKER_FAIL_ON=login setup --login --no-prompt
check_eq '--login that does not finish: still exit code 0' "$RC" 0
check_has '--login that does not finish: it says how to try again' "$OUT" 'the login did not finish'

fresh
setup --import-kube --no-prompt
check_eq '--import-kube without a kubeconfig: succeeds' "$RC" 0
check_has '--import-kube without a kubeconfig: it says how to get one' "$OUT" 'No kubeconfig at'
check_has '--import-kube without a kubeconfig: and that nothing was imported' "$OUT" 'not imported'
fresh
mkdir -p "$HOME_DIR/.kube"
printf 'apiVersion: v1\n' > "$HOME_DIR/.kube/config"
setup --import-kube --no-prompt
check_eq '--import-kube with a kubeconfig: succeeds' "$RC" 0
check_eq '--import-kube with a kubeconfig: runs the importer' "$(logged 'devtools:latest import-docker-desktop-kube docker-desktop')" 1

fresh
setup --no-prompt
check_eq 'without a switch and without a question, neither optional step runs' "$(logged 'import-docker-desktop-kube')$(logged 'az login')" 00

# ---- The command line ---------------------------------------------------------------------------------------------
fresh
setup --help
check_eq '--help: exit code 0' "$RC" 0
check_has '--help: lists the options' "$OUT" '--skip-profile'
check_has '--help: and what the steps do' "$OUT" 'verifies every tool'
check_lacks '--help: without the note about old bash' "$OUT" 'kept free of newer bash syntax'
setup --nonsense
check_eq 'an unknown option: exit code 1' "$RC" 1
check_has 'an unknown option: it is named' "$OUT" 'Unknown option: --nonsense'
setup --rc-file
check_eq '--rc-file without a file: exit code 1' "$RC" 1
check_eq 'nothing was run for the bad command lines' "$(wc -l < "$LOG" | tr -d ' ')" 0

RC=0
OUT=$(cd "$PROJ" && "$ENV_BIN" HOME="$HOME_DIR" "$BASH" -c '. ./setup.sh; echo "still here"' 2>&1) || RC=$?
check_has 'sourcing it is refused' "$OUT" 'do not source it'
check_has 'and does not close your terminal' "$OUT" 'still here'

# ---- The two scripts agree on what goes into the startup files ---------------------------------------------------------
check_ok 'setup.sh and uninstall.sh use the same comment' bash -c 'grep -qF "$1" "$2" && grep -qF "$1" "$3"' _ "$MARKER" "$TEST_ROOT/setup.sh" "$TEST_ROOT/uninstall.sh"
check_ok 'and the same login lines' bash -c 'grep -qF "$1" "$3" && grep -qF "$1" "$4" && grep -qF "$2" "$3" && grep -qF "$2" "$4"' _ "$LOGIN_MARKER" "$LOGIN_LINE" "$TEST_ROOT/setup.sh" "$TEST_ROOT/uninstall.sh"

check_summary
