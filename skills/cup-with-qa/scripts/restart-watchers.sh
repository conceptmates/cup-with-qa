#!/usr/bin/env bash
# usage: restart-watchers.sh <run-dir>
# Safe to run any time, and the first thing to run after a reboot. Starts whatever is not already
# running: quota-guard.sh, memlog.sh, and the app's dev server when config.env sets DEV_CMD and
# APP_URL does not answer. Prints what it did and whether the machine rebooted since the last memlog line.
RUN="$1"
. "$RUN/config.env"

boot=$(sysctl -n kern.boottime 2>/dev/null | sed -n 's/^{ sec = \([0-9]*\),.*/\1/p')
[ -z "$boot" ] && boot=$(( $(date +%s) - $(awk '{print int($1)}' /proc/uptime 2>/dev/null || echo 0) ))
last=$(tail -1 "$RUN/memlog.txt" 2>/dev/null)
if [ -n "$last" ] && [ "$(stat -f %m "$RUN/memlog.txt" 2>/dev/null || stat -c %Y "$RUN/memlog.txt")" -lt "$boot" ]; then
  echo "rebooted since the last memlog line: $last"
  echo "$(date +%H:%M:%S) REBOOT detected; last memlog line: $last" >> "$RUN/quota.log"
fi

if pgrep -f "quota-guard.sh $RUN" >/dev/null; then echo "quota-guard: running"
else nohup bash "$RUN/scripts/quota-guard.sh" "$RUN" >/dev/null 2>&1 & echo "quota-guard: started"; fi

if pgrep -f "memlog.sh $RUN" >/dev/null; then echo "memlog: running"
else nohup bash "$RUN/scripts/memlog.sh" "$RUN" >/dev/null 2>&1 & echo "memlog: started"; fi

if [ "$TARGET" = web ] && [ -n "${DEV_CMD:-}" ]; then
  if curl -s -o /dev/null -m 5 "$APP_URL"; then echo "dev server: answering at $APP_URL"
  else
    (cd "${DEV_DIR:-.}" && nohup sh -c "$DEV_CMD" > "$RUN/devserver.log" 2>&1 &)
    for _ in $(seq 1 40); do curl -s -o /dev/null -m 3 "$APP_URL" && break; sleep 3; done
    curl -s -o /dev/null -m 3 "$APP_URL" && echo "dev server: started" || echo "dev server: NOT answering, see $RUN/devserver.log"
  fi
elif [ "$TARGET" != web ]; then
  echo "mobile target: boot the simulator/emulator and install the app before resuming"
fi

# testers still alive after a Claude restart (not after a reboot) are left alone; round agents re-attach
n=$(pgrep -f "run-tester.sh $RUN " | wc -l | tr -d ' ')
echo "testers running: $n"
