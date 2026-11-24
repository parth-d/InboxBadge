#!/bin/bash
# Applies each mutant from tools/mutants.txt to a throwaway copy of the repo and requires the
# named test to fail. Usage: tools/mutation-check.sh [mutants-file]
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd)
LIST=${1:-$ROOT/tools/mutants.txt}
PLUGINS=/Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing
FLAGS=()
[ -d "$PLUGINS" ] && FLAGS=(-Xswiftc -plugin-path -Xswiftc "$PLUGINS")
WORK=$(mktemp -d "${TMPDIR:-/tmp}/inboxbadge-mutants.XXXXXX")
trap 'rm -rf "$WORK"' EXIT
rsync -a --exclude .git "$ROOT/" "$WORK/"
nl=$'\n'
killed=0; bad=0; n=0
while IFS= read -r line; do
  case "$line" in ''|'#'*) continue ;; esac
  n=$((n + 1))
  file=${line%%@@@*}; rest=${line#*@@@}
  old=${rest%%@@@*}; rest=${rest#*@@@}
  new=${rest%%@@@*}; want=${rest#*@@@}
  old=${old//<NL>/$nl}; new=${new//<NL>/$nl}
  rsync -a "$ROOT/Sources/" "$WORK/Sources/"
  OLD="$old" NEW="$new" perl -0pi -e 's/\Q$ENV{OLD}\E/$ENV{NEW}/' "$WORK/$file"
  if cmp -s "$ROOT/$file" "$WORK/$file"; then
    echo "NOT-APPLIED  $file: ${old:0:60}"; bad=$((bad + 1)); continue
  fi
  (cd "$WORK" && perl -e 'alarm 240; exec @ARGV' swift test ${FLAGS[@]+"${FLAGS[@]}"} > "$WORK/out.txt" 2>&1)
  code=$?
  pkill -f "$WORK/.build" 2>/dev/null
  if [ $code -eq 0 ]; then
    echo "SURVIVED     $file: ${old:0:60} -> ${new:0:40}"; bad=$((bad + 1))
  elif grep -q "✘ Test $want()" "$WORK/out.txt"; then
    echo "killed       $want <- ${old:0:50}"; killed=$((killed + 1))
  elif grep -q "error:" "$WORK/out.txt" && ! grep -q "Test run" "$WORK/out.txt"; then
    echo "BUILD-ERROR  $file: ${old:0:60}"; bad=$((bad + 1))
  elif [ $code -eq 142 ]; then
    echo "killed(hang) $want <- ${old:0:50}"; killed=$((killed + 1))
  else
    echo "WRONG-TEST   wanted $want; failed: $(grep -o '✘ Test [A-Za-z0-9_]*' "$WORK/out.txt" | sort -u | tr '\n' ' ')"; bad=$((bad + 1))
  fi
done < "$LIST"
echo "mutants: $n, killed as expected: $killed, problems: $bad"
[ $bad -eq 0 ]
