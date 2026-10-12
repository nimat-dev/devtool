# shellcheck shell=bash
# Shared by tests/test-devtools-sh.sh, tests/test-setup-sh.sh and tests/test-uninstall-sh.sh.
# Source it:   . "$(dirname "$0")/lib.sh"
#
#   check_eq NAME ACTUAL EXPECTED       check_has NAME TEXT NEEDLE       check_lacks NAME TEXT NEEDLE
#   check_ok NAME COMMAND...            check_no NAME COMMAND...
#   check_same NAME FILE1 FILE2         the two files are byte for byte the same
#   check_skip NAME WHY                 check_summary
#   new_project DIR                     a fresh copy of what setup.sh and uninstall.sh need
#   run_script PROJECT HOME SCRIPT ARGS...   run it with that home folder; OUT = output, RC = exit code
#                                       (SCRIPT_INPUT=FILE gives it something to read, default none)
#   install_fake_docker                 a recording fake `docker` is first on PATH (docker.exe on Windows)
#   to_native PATH                      C:/Users/... in Git Bash, the path unchanged elsewhere
#   is_windows                          true in Git Bash / MSYS2 / Cygwin
#
# The fake docker and its knobs are described at the top of tests/fakebin/docker. On Windows it is a
# docker.exe compiled from tests/fakebin/docker.cs, which is what makes Git Bash treat it as a native
# program (its arguments are converted to Windows paths unless the code under test prevents it).

TEST_ROOT=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
passes=0
failures=0
skipped=0

is_windows() { case "${OSTYPE:-}" in msys* | cygwin* | mingw*) return 0 ;; *) return 1 ;; esac; }

to_native() {
  if is_windows && command -v cygpath > /dev/null 2>&1; then cygpath -m -- "$1"; else printf '%s\n' "$1"; fi
}

check_pass() {
  echo "PASS  $1"
  passes=$((passes + 1))
}

check_fail() {
  echo "FAIL  $1"
  if [ -n "${2:-}" ]; then printf '%s\n' "$2" | sed 's/^/      /'; fi
  failures=$((failures + 1))
}

check_skip() {
  echo "SKIP  $1 ($2)"
  skipped=$((skipped + 1))
}

check_eq() {
  if [ "$2" = "$3" ]; then check_pass "$1"; else check_fail "$1" "expected: $3"$'\n'"actual:   $2"; fi
}

check_has() {
  case $2 in
    *"$3"*) check_pass "$1" ;;
    *) check_fail "$1" "missing: $3"$'\n'"in:      ${2:0:700}" ;;
  esac
}

check_lacks() {
  case $2 in
    *"$3"*) check_fail "$1" "should not be there: $3"$'\n'"in:      ${2:0:700}" ;;
    *) check_pass "$1" ;;
  esac
}

check_ok() {
  local name=$1
  shift
  if "$@" > /dev/null 2>&1; then check_pass "$name"; else check_fail "$name" "this failed: $*"; fi
}

check_no() {
  local name=$1
  shift
  if "$@" > /dev/null 2>&1; then check_fail "$name" "this should have failed: $*"; else check_pass "$name"; fi
}

check_same() {
  if cmp -s -- "$2" "$3"; then
    check_pass "$1"
  else
    check_fail "$1" "$2 and $3 differ:"$'\n'"$(diff -- "$2" "$3" 2>&1 | head -n 20)"
  fi
}

check_summary() {
  echo
  if [ "$skipped" -gt 0 ]; then echo "$skipped check(s) skipped"; fi
  if [ "$failures" -eq 0 ]; then
    echo "ALL TESTS PASSED ($passes checks)"
    exit 0
  fi
  echo "$failures TEST(S) FAILED ($passes passed)"
  exit 1
}

# Puts the fake docker first on PATH. FAKEBIN is the folder it is in.
install_fake_docker() {
  if is_windows; then
    FAKEBIN=$(mktemp -d)
    local cs exe
    cs=$(cygpath -w "$TEST_ROOT/tests/fakebin/docker.cs")
    exe=$(cygpath -w "$FAKEBIN/docker.exe")
    # Add-Type -OutputAssembly only exists in Windows PowerShell, which is what powershell.exe is.
    powershell.exe -NoProfile -ExecutionPolicy Bypass -Command \
      "Add-Type -TypeDefinition (Get-Content -Raw -LiteralPath '$cs') -OutputAssembly '$exe' -OutputType ConsoleApplication" > /dev/null
    if [ ! -f "$FAKEBIN/docker.exe" ]; then
      echo "FAIL  could not build the fake docker.exe from tests/fakebin/docker.cs"
      exit 1
    fi
  else
    FAKEBIN=$TEST_ROOT/tests/fakebin
    chmod +x "$FAKEBIN/docker"
  fi
  PATH=$FAKEBIN:$PATH
  export PATH FAKEBIN
}

ENV_BIN=$(command -v env)

# A fresh copy of the files setup.sh and uninstall.sh work with.
new_project() {
  rm -rf "$1"
  mkdir -p "$1/scripts/shell" "$1/certs"
  local f
  for f in setup.sh uninstall.sh devtools.sh Dockerfile docker-compose.yml .env.example; do cp "$TEST_ROOT/$f" "$1/"; done
  cp "$TEST_ROOT/scripts/shell/aliases.sh" "$1/scripts/shell/"
}

# Runs PROJECT/SCRIPT in a child bash whose home folder is HOME. Nothing can be typed to it unless
# SCRIPT_INPUT names a file. OUT = everything it printed, RC = its exit code.
# shellcheck disable=SC2034
run_script() {
  local proj=$1 home=$2 script=$3
  shift 3
  RC=0
  OUT=$(cd "$proj" && "$ENV_BIN" HOME="$home" "$BASH" "./$script" "$@" 2>&1 < "${SCRIPT_INPUT:-/dev/null}") || RC=$?
  OUT=${OUT//$'\r'/}   # docker.exe ends its lines with CR LF
}
