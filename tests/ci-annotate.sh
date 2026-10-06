#!/usr/bin/env bash
# Turn the interesting lines of a log file into ONE GitHub Actions annotation.
#
#   tests/ci-annotate.sh NAME OUTCOME LOGFILE [PATTERN]
#
#   NAME     what ran, e.g. "smoke test"
#   OUTCOME  the step outcome: success -> notice, failure -> error, anything else -> nothing
#   LOGFILE  the captured output of the step
#   PATTERN  extended regex; only matching lines are kept (default: all lines)
#
# Annotations appear on the run page and through the checks API, so a result can be read
# without opening the raw job log. The last 60 matching lines are kept.
set -u

name=$1
outcome=$2
file=$3
pattern=${4:-.}

case "$outcome" in
  success) level=notice ;;
  failure) level=error ;;
  *) exit 0 ;;
esac

# Workflow-command escaping: % -> %25, newline -> %0A. Strip CRs and ANSI colour codes first.
msg=$(grep -E -- "$pattern" "$file" 2>/dev/null \
  | tr -d '\r' | sed 's/\x1b\[[0-9;]*[A-Za-z]//g' \
  | tail -n 60 | cut -c1-220 | sed 's/%/%25/g' | awk '{printf "%s%%0A", $0}')

echo "::${level} title=${name} (${outcome})::${msg:-no matching output}"
