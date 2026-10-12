#!/usr/bin/env bash
# devtools-pty-run.sh HEX     (started by winpty on behalf of devtools.sh; nothing to type here)
#
# Why it exists: in the Git Bash window (mintty) docker needs winpty to get a terminal, and Git
# for Windows' winpty rewrites every argument that looks like a path into a Windows path before
# the program sees it. MSYS_NO_PATHCONV and MSYS2_ARG_CONV_EXCL do not stop it. That turned
#     docker run ... -w /work ...
# into  -w C:/Users/me/AppData/Local/Programs/Git/work  and docker refused it.
#
# So devtools.sh does not give winpty docker's arguments. It gives it this script and ONE
# argument: the real arguments written as hex digits (two for every byte, and 00 after each
# argument), which nothing can take for a path. This script, running in a bash that winpty
# started, writes them back as arguments and runs docker.exe with them. Because winpty is
# running it, docker.exe has a real console and -t works.
set -u

hex=${1:-}
if [ -z "$hex" ] || [[ $hex == *[![:xdigit:]]* ]] || [ $((${#hex} % 2)) -ne 0 ]; then
  echo "devtools-pty-run.sh is started by devtools.sh, through winpty. It is not meant to be run by hand." >&2
  exit 2
fi

args=()
arg=''
len=${#hex}
i=0
while [ "$i" -lt "$len" ]; do
  byte=${hex:i:2}
  i=$((i + 2))
  if [ "$byte" = 00 ]; then
    args+=("$arg")
    arg=''
  else
    printf -v char '%b' "\\x$byte"
    arg+=$char
  fi
done
if [ "${#args[@]}" -eq 0 ] || [ -n "$arg" ]; then
  echo "devtools-pty-run.sh: the arguments it was given are cut short." >&2
  exit 2
fi

# The shell must not rewrite /work, /root or /subscriptions/... on the way to docker.exe either.
export MSYS_NO_PATHCONV=1 MSYS2_ARG_CONV_EXCL='*'
docker=docker
if type -P docker.exe > /dev/null 2>&1; then docker=docker.exe; fi
exec "$docker" "${args[@]}"
