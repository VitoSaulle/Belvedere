#!/bin/sh
# Esegue swift test e mostra solo l'essenziale. Uso: ./scripts-t.sh [argomenti di swift test]
OUT=.superpowers/test-last.log
mkdir -p .superpowers
swift test "$@" > "$OUT" 2>&1; rc=$?
grep -E "error:|✘|Test run|passed after|failed after|issue" "$OUT" | grep -v "^.*Failed frontend" | cut -c1-300 | tail -25
exit $rc
