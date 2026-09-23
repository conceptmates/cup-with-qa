#!/usr/bin/env bash
# usage: init-run.sh <run-dir>
# Creates a durable run dir with config.env, copies of the scripts and templates, and empty state.
set -eu
RUN="$1"
case "$RUN" in /tmp/*|/private/tmp/*) echo "refusing /tmp: a reboot wipes it; use a path on real disk" >&2; exit 1;; esac
SKILL="$(cd "$(dirname "$0")/.." && pwd)"
mkdir -p "$RUN"/{lanes,scripts,templates,.runner}
cp "$SKILL"/scripts/*.sh "$SKILL"/scripts/*.py "$RUN/scripts/"
cp "$SKILL"/templates/* "$RUN/templates/"
chmod +x "$RUN"/scripts/*.sh
if [ ! -f "$RUN/config.env" ]; then
cat > "$RUN/config.env" <<EOF
# cup-with-qa run config — edit with the preflight answers
RUN_DIR="$RUN"
TARGET="web"                    # web | ios | android
APP_URL="http://localhost:3000" # web target
APP_ID=""                       # mobile bundle id / package
TESTER="codex"                  # tester CLI
TESTER_MODEL="gpt-6-luna"
TESTER_EFFORT="max"
ROUND_TIMEOUT_S=7200
PRIMARY_MAX=94                  # pause at this % of the 5-hour window
WEEKLY_MAX=95                   # pause at this % of the weekly window
ON_LIMIT="wait"                 # wait | switch
FALLBACK_MODEL=""               # used when ON_LIMIT=switch
HARD_CAP=6                      # max concurrent lanes
LANE_RAM_MB=2500                # web ~2500, mobile ~4000
MIN_FREE_PCT=15                 # never admit a lane below this free-memory %
MAX_LOAD_PER_CORE=1.5
MAX_ROUNDS=3
EOF
fi
[ -f "$RUN/HANDOFF.md" ] || echo "# QA run handoff" > "$RUN/HANDOFF.md"
echo "run dir ready: $RUN"
