#!/usr/bin/env bash
# usage: run-tester.sh <run-dir> <lane> <round>
# Runs one tester round. Blocking. Writes lanes/<lane>/round<N>/{prompt.md,tester.log,report.json,DONE}
# and updates lanes/<lane>/state.json. Start it detached (nohup ... &) and wait with watch-round.sh.
set -u
# Run from a frozen copy so edits to this file never corrupt a round that is already running.
if [ -z "${RUNNER_FROZEN:-}" ]; then
  C="$1/.runner/$2-$3"; mkdir -p "$C"; cp "$0" "$C/run-tester.sh"
  RUNNER_FROZEN=1 exec bash "$C/run-tester.sh" "$@"
fi
RUN="$1"; LANE="$2"; ROUND="$3"
. "$RUN/config.env"
LD="$RUN/lanes/$LANE"; OUT="$LD/round$ROUND"
mkdir -p "$OUT/shots"; rm -f "$OUT/DONE"
SESSION="qa-$LANE"

state() {  # state <status> [extra-json-fields]
  python3 - "$LD/state.json" "$LANE" "$ROUND" "$1" "${2:-}" <<'EOF'
import json,sys,os,time
p,lane,rnd,status,extra=sys.argv[1:6]
d=json.load(open(p)) if os.path.exists(p) else {"lane":lane}
d.update({"round":int(rnd),"status":status,"updated":time.strftime("%Y-%m-%dT%H:%M:%S")})
if extra: d.update(json.loads(extra))
json.dump(d,open(p,"w"),indent=1)
EOF
}
done_with() { echo "$1" > "$OUT/DONE"; state "done" "{\"done\": \"$1\"}"; rm -f "$RUN/.active/$LANE"; exit 0; }

# Quota paused and the policy is to wait: do not start.
MODEL="$TESTER_MODEL"
if [ -f "$RUN/QUOTA_PAUSE" ]; then
  if [ "$ON_LIMIT" = switch ] && [ -n "$FALLBACK_MODEL" ]; then MODEL="$FALLBACK_MODEL"; else done_with "exit=quota rc=paused-before-start"; fi
fi

state "waiting-capacity"
bash "$RUN/scripts/capacity.sh" "$RUN" wait "$LANE" $$
state "running" "{\"model\": \"$MODEL\"}"

# Interrupted earlier in this same round (quota pause, reboot)? Keep its report and resume its session.
RESUME=""
[ -s "$OUT/report.json" ] && { cp "$OUT/report.json" "$OUT/report.partial.json"; RESUME=1; }
SID=$(grep -h -m1 '^session id:' "$OUT"/tester*.log 2>/dev/null | tail -1 | awk '{print $3}')

if [ "$TARGET" = web ]; then BRIEF="$RUN/templates/tester-brief-web.md"; else BRIEF="$RUN/templates/tester-brief-mobile.md"; fi
{
  sed -e "s|\$SESSION|$SESSION|g" -e "s|\$OUT|$OUT|g" -e "s|\$RUN|$RUN|g" \
      -e "s|\$APP_URL|$APP_URL|g" -e "s|\$APP_ID|$APP_ID|g" -e "s|\$TARGET|$TARGET|g" "$BRIEF"
  [ -f "$RUN/context.md" ] && { echo; cat "$RUN/context.md"; }
  echo; echo "## Lane: $LANE, round $ROUND"
  echo; echo "## Scenarios"; cat "$LD/scenarios.md"
  PREV=$((ROUND-1))
  if [ -f "$LD/feedback-r$PREV.md" ]; then
    echo; echo "## Reviewer feedback on round $PREV (address all of it)"; cat "$LD/feedback-r$PREV.md"
    [ -f "$LD/round$PREV/report.json" ] && echo "Previous report: $LD/round$PREV/report.json (carry forward still-valid results with their evidence paths, re-verify, extend)."
  fi
  [ -f "$RUN/filed.txt" ] && { echo; echo "## Already filed (do not re-report)"; cat "$RUN/filed.txt"; }
} > "$OUT/prompt.md"

cd "$OUT"
N=$(ls "$OUT"/tester*.log 2>/dev/null | wc -l | tr -d ' ')
if [ -n "$RESUME" ] && [ -n "$SID" ] && [ "$MODEL" = "$TESTER_MODEL" ]; then
  echo "$(date) resume session $SID" >> "$OUT/resume.log"
  timeout "$ROUND_TIMEOUT_S" codex exec resume "$SID" --dangerously-bypass-approvals-and-sandbox --skip-git-repo-check \
    -m "$MODEL" -c model_reasoning_effort="$TESTER_EFFORT" \
    "You were interrupted (quota pause or restart). Continue exactly where you stopped: reopen session $SESSION (sign in again if needed), keep updating $OUT/report.json, finish every not_run scenario and the exhaustive sweep, then give the 2-line summary." \
    > "$OUT/tester.resume$N.log" 2>&1
  RC=$?
else
  if [ -n "$RESUME" ]; then
    printf '\n## RESUME\nThis round was interrupted. Partial progress: %s/report.partial.json, screenshots in %s/shots/. Copy it to report.json, keep valid pass/fail results, continue with every not_run scenario.\n' "$OUT" "$OUT" >> "$OUT/prompt.md"
  fi
  LOG="$OUT/tester.log"; [ "$N" -gt 0 ] && LOG="$OUT/tester.run$N.log"
  timeout "$ROUND_TIMEOUT_S" codex exec --dangerously-bypass-approvals-and-sandbox --skip-git-repo-check \
    -m "$MODEL" -c model_reasoning_effort="$TESTER_EFFORT" < "$OUT/prompt.md" > "$LOG" 2>&1
  RC=$?
fi
# close this lane's browser / device session
if [ "$TARGET" = web ]; then AGENT_BROWSER_SESSION="$SESSION" agent-browser close >/dev/null 2>&1; else agent-device close --session "$SESSION" >/dev/null 2>&1; fi

if [ -f "$RUN/QUOTA_PAUSE" ] && [ "$ON_LIMIT" != switch ]; then done_with "exit=quota rc=$RC guard-paused"
elif cat "$OUT"/tester*.log 2>/dev/null | tail -c 4000 | grep -qE "^(ERROR: ?)?You.ve hit your usage limit"; then done_with "exit=quota rc=$RC"
else done_with "exit=$RC"; fi
