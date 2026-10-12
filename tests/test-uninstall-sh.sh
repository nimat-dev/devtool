#!/usr/bin/env bash
# Tests for uninstall.sh. Every scenario copies the project into a scratch folder (its name has a
# space in it on purpose), makes the state setup.sh leaves behind, runs uninstall.sh in a child bash
# with a scratch home folder and a fake `docker`, and checks the exit code, the output, the docker
# calls it made and what is left of the startup files. No Docker daemon is needed, and your own
# ~/.bashrc is never read or changed.
#
#     bash tests/test-uninstall-sh.sh
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
unset DEVTOOLS_IMAGE DEVTOOLS_VOLUME DEVTOOLS_BASH_ALIASES DEVTOOLS_WINPTY DEVTOOLS_NO_READLINE TERM_PROGRAM NO_COLOR \
  AKS_RG AKS_NAME DOCKER_RUN_FILE DOCKER_FORCE_EXIT DOCKER_FAIL_ON DOCKER_SERVER DOCKER_VERSION_EXIT \
  DOCKER_COMPOSE_EXIT DOCKER_BUILD_EXIT DOCKER_IMAGE_EXIT DOCKER_PS_FILE DOCKER_VOLUMES SCRIPT_INPUT DOCKER_FAKE_OUTPUT

ALIASES_FILE=$HOME_DIR/.devtools-aliases.sh
# The scripts print the home folder the way their bash sees it (/c/Users/... in Git Bash).
CHILD_HOME=$("$ENV_BIN" HOME="$HOME_DIR" "$BASH" -c 'printf %s "$HOME"')

# A fresh project, an empty home folder and an empty docker log.
fresh() {
  new_project "$PROJ"
  rm -rf "$HOME_DIR"
  mkdir -p "$HOME_DIR"
  : > "$LOG"
}
setup() { run_script "$PROJ" "$HOME_DIR" setup.sh --no-prompt > /dev/null; }
uninstall() { run_script "$PROJ" "$HOME_DIR" uninstall.sh "$@"; }
logged() { grep -cF -- "$1" "$LOG"; }
check_file() { # NAME FILE EXACT-CONTENT
  printf '%s' "$3" > "$TMP/expected"
  check_same "$1" "$2" "$TMP/expected"
}

# ---- After setup.sh: back to what was there before --------------------------------------------------------------------
fresh
printf '# my bashrc\nexport EDITOR=vim\nalias ll='"'"'ls -l'"'"'\n# caf\xc3\xa9 \xc3\xbcn\xc3\xafcode  \n\n\nexport LAST=1\n' > "$HOME_DIR/.bashrc"
printf 'export P=1\n' > "$HOME_DIR/.bash_profile"
cp "$HOME_DIR/.bashrc" "$TMP/bashrc.original"
cp "$HOME_DIR/.bash_profile" "$TMP/bash_profile.original"
setup
check_has 'setup.sh left its line behind' "$(cat "$HOME_DIR/.bashrc")" 'devtools.sh'
check_has 'and its login line' "$(cat "$HOME_DIR/.bash_profile")" '[ -r ~/.bashrc ] && . ~/.bashrc'
cp "$HOME_DIR/.bashrc" "$TMP/bashrc.after-setup"
uninstall --no-prompt
check_eq 'uninstall succeeds' "$RC" 0
check_has 'it says it is done' "$OUT" 'Done.'
check_same '.bashrc is back to what it was, byte for byte (accents, blank lines, spaces)' "$HOME_DIR/.bashrc" "$TMP/bashrc.original"
check_same '.bash_profile too' "$HOME_DIR/.bash_profile" "$TMP/bash_profile.original"
check_same 'a copy of the file as it was before is kept' "$HOME_DIR/.bashrc.bak" "$TMP/bashrc.after-setup"
check_has 'it names what it removed' "$OUT" 'removed: . '
check_has 'and where the backup is' "$OUT" "backup:  $CHILD_HOME/.bashrc.bak"
check_has 'your own shortcuts file is kept' "$OUT" 'Your own shortcuts file was kept'
check_ok 'and really is' test -f "$ALIASES_FILE"
check_has 'open terminals are told how to unload' "$OUT" 'devtools-unload'
check_has 'the project folder is said to be untouched' "$OUT" 'were not touched'
check_ok 'the project folder still has everything' test -f "$PROJ/devtools.sh" -a -f "$PROJ/setup.sh" -a -f "$PROJ/.env"

# running it again changes nothing
cp "$HOME_DIR/.bashrc.bak" "$TMP/bak.before"
uninstall --no-prompt
check_eq 'a second run succeeds' "$RC" 0
check_has 'a second run has nothing to remove' "$OUT" 'nothing to remove'
check_same 'and does not touch the backup' "$HOME_DIR/.bashrc.bak" "$TMP/bak.before"
check_same 'or the file' "$HOME_DIR/.bashrc" "$TMP/bashrc.original"

# files that did not exist before setup.sh are left empty
fresh
setup
uninstall --no-prompt
check_eq 'a .bashrc that setup.sh made is empty afterwards' "$(wc -c < "$HOME_DIR/.bashrc" | tr -d ' ')" 0
check_eq 'and so is the .bash_profile it made' "$(wc -c < "$HOME_DIR/.bash_profile" | tr -d ' ')" 0

# a file without a final newline
fresh
printf 'export A=1' > "$HOME_DIR/.bashrc"
setup
uninstall --no-prompt
check_file 'a file without a final newline gets one, nothing else changes' "$HOME_DIR/.bashrc" $'export A=1\n'

# Windows line endings
fresh
printf 'export A=1\r\nalias ll="ls -l"\r\n' > "$HOME_DIR/.bashrc"
cp "$HOME_DIR/.bashrc" "$TMP/crlf.original"
setup
uninstall --no-prompt
check_same 'a file with Windows line endings is back to what it was' "$HOME_DIR/.bashrc" "$TMP/crlf.original"

# ---- Lines written by hand ---------------------------------------------------------------------------------------------
fresh
cat > "$HOME_DIR/.bashrc" << 'EOF'
export A=1
source "/some/where/devtools.sh"
   .   ~/dev/devtools.sh
# . ~/old/devtools.sh
export B=2
EOF
uninstall --no-prompt
check_eq 'lines typed by hand (source, ". file", with quotes or blanks): exit code 0' "$RC" 0
check_file 'are removed, a commented-out one is not' "$HOME_DIR/.bashrc" $'export A=1\n# . ~/old/devtools.sh\nexport B=2\n'

fresh
cat > "$HOME_DIR/.bashrc" << 'EOF'
export A=1
if [ -f ~/dt/devtools.sh ]; then . ~/dt/devtools.sh; fi
EOF
cp "$HOME_DIR/.bashrc" "$TMP/odd.original"
uninstall --no-prompt
check_eq 'a line it does not recognise: exit code 2' "$RC" 2
check_has 'a line it does not recognise: it says which one' "$OUT" 'still mentions devtools.sh, line 2'
check_has 'a line it does not recognise: and to delete it by hand' "$OUT" 'Delete it by hand'
check_same 'a line it does not recognise: the file is left alone' "$HOME_DIR/.bashrc" "$TMP/odd.original"

# ---- Which files ---------------------------------------------------------------------------------------------------------
fresh
setup
cp "$HOME_DIR/.bashrc" "$TMP/rc.with-toolbox"
cp "$HOME_DIR/.bash_profile" "$TMP/bp.with-toolbox"
uninstall --skip-profile --no-prompt
check_eq '--skip-profile: succeeds' "$RC" 0
check_same '--skip-profile: .bashrc is untouched' "$HOME_DIR/.bashrc" "$TMP/rc.with-toolbox"
check_same '--skip-profile: so is .bash_profile' "$HOME_DIR/.bash_profile" "$TMP/bp.with-toolbox"
check_has '--skip-profile: it says new terminals still load the toolbox' "$OUT" 'new terminals load the toolbox again'

printf '%s\n%s\n' '# DevOps toolbox: az, kubectl, terraform, helm, flux ... run in Docker' ". '/x/devtools.sh'" > "$TMP/other rc"
uninstall --rc-file "$TMP/other rc" --no-prompt
check_eq '--rc-file: succeeds' "$RC" 0
check_eq '--rc-file: that file is cleaned' "$(wc -c < "$TMP/other rc" | tr -d ' ')" 0
check_same '--rc-file: the others are not looked at' "$HOME_DIR/.bashrc" "$TMP/rc.with-toolbox"
rm -f "$TMP/other rc" "$TMP/other rc.bak"

fresh
uninstall --no-prompt
check_eq 'no startup file at all: exit code 0' "$RC" 0
check_has 'no startup file at all: it says so' "$OUT" 'no startup file exists'

fresh
printf 'export A=1\n' > "$HOME_DIR/.profile"
uninstall --no-prompt
check_has 'a startup file without the toolbox is reported as looked at' "$OUT" "looked in: $CHILD_HOME/.profile"

# ---- The containers ----------------------------------------------------------------------------------------------------------
fresh
printf 'abcdef123456\n0123456789abcdef0123\n' > "$TMP/ps.txt"
DOCKER_PS_FILE=$TMP/ps.txt uninstall --no-prompt
check_eq 'containers: exit code 0' "$RC" 0
check_has 'containers: docker compose down' "$OUT" 'docker compose down'
check_eq 'containers: compose down removes orphans' "$(logged 'compose down --remove-orphans')" 1
check_eq 'containers: the ones started from the image are looked for' "$(logged 'ps -aq --filter ancestor=devtools:latest')" 2
check_has 'containers: they are removed' "$OUT" 'stopped and removed 2 container(s) started from devtools:latest'
check_eq 'containers: in one rm -f call' "$(logged 'rm -f abcdef123456 0123456789abcdef0123')" 1

fresh
DOCKER_PS_FILE=$TMP/none.txt uninstall --no-prompt
check_has 'no containers: it says so' "$OUT" 'no container is running from devtools:latest'
check_eq 'no containers: and removes nothing' "$(logged 'rm -f')" 0

fresh
printf 'abcdef123456\n' > "$TMP/ps.txt"
DOCKER_PS_FILE=$TMP/ps.txt DOCKER_FAIL_ON='rm' uninstall --no-prompt
check_eq 'a container that cannot be removed: exit code 2' "$RC" 2
check_has 'a container that cannot be removed: it is named' "$OUT" '1 container(s) started from devtools:latest are still there: abcdef123456'

fresh
DOCKER_FAIL_ON=down uninstall --no-prompt
check_eq 'a compose down that fails: still exit code 0' "$RC" 0
check_has 'a compose down that fails: it warns' "$OUT" 'docker compose down did not finish'

fresh
setup
mkdir -p "$TMP_POSIX/empty"
PATH="$TMP_POSIX/empty" uninstall --no-prompt
check_eq 'no docker: exit code 0' "$RC" 0
check_has 'no docker: it says so' "$OUT" 'docker was not found on PATH, so no containers were checked'
check_eq 'no docker: the startup file is still cleaned' "$(wc -c < "$HOME_DIR/.bashrc" | tr -d ' ')" 0

fresh
DOCKER_VERSION_EXIT=1 uninstall --no-prompt
check_eq 'engine not running: exit code 0' "$RC" 0
check_has 'engine not running: it says so' "$OUT" 'the Docker engine is not running, so no containers were checked'

fresh
DOCKER_SERVER=windows/99.0.0 uninstall --no-prompt
check_has 'Windows containers: it says so' "$OUT" 'Docker is set to Windows containers'
check_has 'Windows containers: and how to switch' "$OUT" "Switch to Linux containers"

# ---- The image ------------------------------------------------------------------------------------------------------------------
fresh
uninstall --no-prompt
check_has 'the image is kept by default' "$OUT" 'kept the image devtools:latest'
check_eq 'and not touched' "$(logged 'image')" 0

fresh
uninstall --remove-image --no-prompt
check_eq '--remove-image: exit code 0' "$RC" 0
check_has '--remove-image: deleted' "$OUT" 'deleted the image devtools:latest'
check_eq '--remove-image: with docker image rm' "$(logged 'image rm devtools:latest')" 1

fresh
DOCKER_IMAGE_EXIT=1 uninstall --remove-image --no-prompt
check_eq '--remove-image when it is not there: exit code 0' "$RC" 0
check_has '--remove-image when it is not there: it says so' "$OUT" 'the image devtools:latest is not there'

fresh
DOCKER_FAIL_ON='rm' uninstall --remove-image --no-prompt
check_eq '--remove-image that fails: exit code 2' "$RC" 2
check_has '--remove-image that fails: it says so' "$OUT" 'Could not delete the image devtools:latest'

fresh
DOCKER_VERSION_EXIT=1 uninstall --remove-image --no-prompt
check_eq '--remove-image without a running engine: exit code 2' "$RC" 2
check_has '--remove-image without a running engine: it says why' "$OUT" 'The image devtools:latest was not removed'

# ---- The saved logins ------------------------------------------------------------------------------------------------------------
fresh
uninstall --no-prompt
check_has 'the logins are kept by default' "$OUT" 'kept your saved logins (volume devtools-home)'
check_eq 'and the volumes are not even looked at' "$(logged 'volume')" 0

fresh
DOCKER_VOLUMES='devtools-home devtools_devtools-home' uninstall --remove-volume --force --no-prompt
check_eq '--remove-volume --force: exit code 0' "$RC" 0
check_has '--remove-volume --force: the wrappers volume is deleted' "$OUT" 'deleted the volume devtools-home (your saved logins)'
check_has '--remove-volume --force: and the one docker compose makes' "$OUT" 'deleted the volume devtools_devtools-home'
check_eq '--remove-volume --force: with docker volume rm' "$(logged 'volume rm devtools-home')$(logged 'volume rm devtools_devtools-home')" 11

fresh
DOCKER_VOLUMES='devtools-home' uninstall --remove-volume --force --no-prompt
check_eq '--remove-volume with only one of the two: deletes it' "$(logged 'volume rm devtools-home')" 1
check_eq '--remove-volume with only one of the two: and not the other' "$(logged 'volume rm devtools_devtools-home')" 0

fresh
uninstall --remove-volume --force --no-prompt
check_eq '--remove-volume with no volume: exit code 0' "$RC" 0
check_has '--remove-volume with no volume: nothing to delete' "$OUT" 'no toolbox volume found'

fresh
DOCKER_VOLUMES='devtools-home' uninstall --remove-volume --no-prompt
check_eq '--remove-volume --no-prompt without --force: exit code 0' "$RC" 0
check_has '--remove-volume --no-prompt without --force: kept, and why' "$OUT" 'deleting it needs --force when no question can be asked'
check_eq '--remove-volume --no-prompt without --force: nothing deleted' "$(logged 'volume rm')" 0

for answer in y Y yes YES; do
  fresh
  printf '%s\n' "$answer" > "$TMP/answer.txt"
  SCRIPT_INPUT=$TMP/answer.txt DOCKER_VOLUMES='devtools-home' uninstall --remove-volume
  check_has "the question answered with '$answer': the volume is deleted" "$OUT" 'deleted the volume devtools-home'
done
check_has 'the question says what is at stake' "$OUT" 'It holds your saved az, gh and kubectl logins'
for answer in n N no ''; do
  fresh
  printf '%s\n' "$answer" > "$TMP/answer.txt"
  SCRIPT_INPUT=$TMP/answer.txt DOCKER_VOLUMES='devtools-home' uninstall --remove-volume
  check_has "the question answered with '$answer': the volume is kept" "$OUT" 'kept devtools-home'
  check_eq "the question answered with '$answer': nothing is deleted" "$(logged 'volume rm')" 0
done
fresh
: > "$TMP/answer.txt"
SCRIPT_INPUT=$TMP/answer.txt DOCKER_VOLUMES='devtools-home' uninstall --remove-volume
check_eq 'the question with nothing to read (no terminal): nothing is deleted' "$(logged 'volume rm')" 0

fresh
DOCKER_VOLUMES='devtools-home' DOCKER_FAIL_ON='rm' uninstall --remove-volume --force --no-prompt
check_eq 'a volume that cannot be deleted: exit code 2' "$RC" 2
check_has 'a volume that cannot be deleted: it says so' "$OUT" 'Could not delete the volume devtools-home'

fresh
DOCKER_VERSION_EXIT=1 uninstall --remove-volume --force --no-prompt
check_eq '--remove-volume without a running engine: exit code 2' "$RC" 2
check_has '--remove-volume without a running engine: it says why' "$OUT" 'The saved logins were not removed'

# ---- The command line ----------------------------------------------------------------------------------------------------------------
fresh
uninstall --help
check_eq '--help: exit code 0' "$RC" 0
check_has '--help: lists the options' "$OUT" '--remove-volume'
check_has '--help: and what the steps do' "$OUT" 'stops and removes the toolbox containers'
check_lacks '--help: without the note about old bash' "$OUT" 'kept free of newer bash syntax'
uninstall --nonsense
check_eq 'an unknown option: exit code 1' "$RC" 1
check_has 'an unknown option: it is named' "$OUT" 'Unknown option: --nonsense'
uninstall --rc-file
check_eq '--rc-file without a file: exit code 1' "$RC" 1
check_eq 'nothing was run for the bad command lines' "$(wc -l < "$LOG" | tr -d ' ')" 0
RC=0
OUT=$(cd "$PROJ" && "$ENV_BIN" HOME="$HOME_DIR" "$BASH" -c '. ./uninstall.sh; echo "still here"' 2>&1) || RC=$?
check_has 'sourcing it is refused' "$OUT" 'do not source it'
check_has 'and does not close your terminal' "$OUT" 'still here'

check_summary
