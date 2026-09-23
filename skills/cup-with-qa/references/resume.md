# Resuming a run

Every piece of state is a file in the run dir, so a resume reads files, not memory.

| File | Written by | Means |
|---|---|---|
| `lanes/<lane>/scenarios.md` | designer | plan exists; the designer returns immediately on resume |
| `lanes/<lane>/state.json` | run-tester.sh | round, status (`waiting-capacity`, `running`, `done`), model |
| `lanes/<lane>/round<N>/report.json` | tester | progress, updated after each scenario |
| `lanes/<lane>/round<N>/DONE` | run-tester.sh / watch-round.sh | round finished: `exit=0`, `exit=quota ...`, `exit=1 rc=runner-died` |
| `lanes/<lane>/round<N>/verdict.json` | judge | round judged; a re-run judge returns it unchanged |
| `lanes/<lane>/feedback-r<N>.md` | judge | what round N+1 must do |
| `QUOTA_PAUSE` | quota-guard.sh | testers paused; lifted automatically after the reset |
| workflow `journal.jsonl` | Workflow tool | completed agent calls; replayed for free with `resumeFromRunId` |

## Procedure

1. `python3 <run>/scripts/status.py <run>` — see where every lane stands.
2. `uptime`. If the machine rebooted: restart the dev server or device, then
   `nohup bash <run>/scripts/quota-guard.sh <run> >/dev/null 2>&1 &` and the same for `memlog.sh`.
   Read the last lines of `memlog.txt` to see whether memory preceded the crash.
3. Testers still running (`pgrep -fl "run-tester.sh <run> "`) are left alone; the new round agents find them
   and wait on them instead of starting another copy.
4. Relaunch the workflow with `resumeFromRunId` and the same args. If you edited the script or args, relaunch
   fresh instead, with `start` set to each lane's current round and `done_lanes` for satisfied lanes; the
   files above make that cheap.

## Failure modes seen in practice

- **Stale quota markers.** A `DONE` saying `quota` from before a reset looks like a fresh pause. Round agents
  rename it to `DONE.stale-quota` before starting; if you relaunch by hand, do the same.
- **Editing a running script.** Bash reads scripts lazily, so editing `run-tester.sh` under a live round can
  run garbage. Runners execute from a frozen copy in `.runner/`; edit the source freely.
- **Runner died without DONE.** `watch-round.sh` writes `DONE` (`rc=runner-died`) so nothing waits forever.
- **Reboot under memory pressure.** Two reboots happened with 3-5 testers plus heavy apps on 16 GB. The
  capacity gate prevents new lanes under pressure; it cannot stop other apps from using memory.
- **Tester quota weekly window.** Waiting days is not useful; weekly pauses stop the lane and are reported.
- **Early quota reset.** A window can reset before its recorded `resets_at`. The guard probes every 20 minutes
  while paused and lifts the pause as soon as both windows read under the thresholds.
- **Lanes shifting the active workspace.** Lanes that create organizations or workspaces can make a fresh
  sign-in land in an empty one, and a tester then reports every scenario as blocked. Tell testers in
  `context.md` which workspace holds the test data and to switch back to it after every sign-in.
