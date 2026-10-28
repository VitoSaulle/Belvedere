#!/bin/sh
# Hook PermissionRequest di prova: registra inizio/fine, attende, opzionalmente decide.
LOG=/tmp/belvedere-spike/hook.log
cat > /dev/null
echo "start $(perl -MTime::HiRes=time -e "printf q(%d), time*1000")" >> "$LOG"
sleep "${SPIKE_SLEEP:-20}"
echo "end $(perl -MTime::HiRes=time -e "printf q(%d), time*1000")" >> "$LOG"
if [ "$SPIKE_DECISION" = "allow" ]; then
  printf '{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"allow"}}}'
fi
exit 0
