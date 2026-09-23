#!/usr/bin/env bash
# usage: quota-guard.sh <run-dir>     (start detached with nohup; one per run)
# Every 60s reads the newest Codex rate_limits from ~/.codex/sessions and logs them to quota.log.
# At PRIMARY_MAX% of the 5-hour window or WEEKLY_MAX% of the weekly window it writes QUOTA_PAUSE and
# stops this run's testers (reports are written incrementally, so only the scenario in progress is lost).
# Once the window that tripped the pause has reset and a tiny probe succeeds, it lifts the pause.
# With ON_LIMIT=switch, run-tester.sh keeps going on FALLBACK_MODEL instead of pausing.
RUN="$1"
. "$RUN/config.env"

stop_testers() {  # SIGTERM every tester process under this run's runners
  kids() { for c in $(pgrep -P "$1"); do kids "$c"; echo "$c"; done; }
  for r in $(pgrep -f "run-tester.sh $RUN "); do
    for k in $(kids "$r"); do ps -o command= -p "$k" | grep -q "codex" && kill -TERM "$k" 2>/dev/null; done
  done
}

while :; do
  read -r P W PR WR < <(python3 - <<'EOF'
import glob,os,json
files=sorted(glob.glob(os.path.expanduser('~/.codex/sessions/*/*/*/*.jsonl')),key=os.path.getmtime)[-15:]
best=None
def find(o):
    if isinstance(o,dict):
        if isinstance(o.get('rate_limits'),dict): return o['rate_limits']
        for v in o.values():
            r=find(v)
            if r: return r
    elif isinstance(o,list):
        for v in o:
            r=find(v)
            if r: return r
for f in files:
    for line in open(f,errors='ignore'):
        if '"rate_limits"' not in line: continue
        try: d=json.loads(line)
        except Exception: continue
        rl=find(d); ts=d.get('timestamp','')
        if rl and rl.get('primary') and (best is None or ts>=best[0]): best=(ts,rl)
if best:
    p=best[1]['primary']; s=best[1].get('secondary') or {}
    print(p.get('used_percent',0), s.get('used_percent',0), int(p.get('resets_at',0)), int(s.get('resets_at',0)))
else: print(0,0,0,0)
EOF
)
  echo "$(date +%H:%M:%S) primary=${P}% weekly=${W}% primary_resets=$(date -r "$PR" +%H:%M 2>/dev/null || date -d "@$PR" +%H:%M 2>/dev/null) weekly_resets=$(date -r "$WR" '+%a %H:%M' 2>/dev/null || date -d "@$WR" '+%a %H:%M' 2>/dev/null)" >> "$RUN/quota.log"

  if [ ! -f "$RUN/QUOTA_PAUSE" ] && python3 -c "import sys;sys.exit(0 if float('$P')>=$PRIMARY_MAX or float('$W')>=$WEEKLY_MAX else 1)"; then
    if python3 -c "import sys;sys.exit(0 if float('$W')>=$WEEKLY_MAX else 1)"; then WHICH=weekly; RA=$WR; else WHICH=primary; RA=$PR; fi
    echo "which=$WHICH reset_at=$RA primary=$P weekly=$W at $(date)" > "$RUN/QUOTA_PAUSE"
    echo "$(date +%H:%M:%S) PAUSE ($WHICH) — testers stopped, reports kept" >> "$RUN/quota.log"
    [ "$ON_LIMIT" = switch ] || stop_testers
  fi

  if [ -f "$RUN/QUOTA_PAUSE" ]; then
    RESET_AT=$(sed -n 's/.*reset_at=\([0-9]*\).*/\1/p' "$RUN/QUOTA_PAUSE")
    if [ -n "$RESET_AT" ] && [ "$(date +%s)" -ge $((RESET_AT + 120)) ]; then
      if ! timeout 180 codex exec --skip-git-repo-check -m "$TESTER_MODEL" -c model_reasoning_effort=low "reply ok" 2>&1 | grep -qi "usage limit"; then
        mv "$RUN/QUOTA_PAUSE" "$RUN/QUOTA_PAUSE.lifted-$(date +%m%d-%H%M)"
        echo "$(date +%H:%M:%S) RESUME — window reset, pause lifted" >> "$RUN/quota.log"
      fi
    fi
  fi
  sleep 60
done
