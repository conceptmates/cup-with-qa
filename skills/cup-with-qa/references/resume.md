# Resuming a run

Every piece of state is a file in the run dir, so a resume reads files, not memory.

| File | Written by | Means |
|---|---|---|
| `launch.json` | you, before launch; `launch.py record` after | script path, the exact args, every run id |
| `lanes/<lane>/scenarios.md` | designer | plan exists; the designer returns immediately on resume |
| `lanes/<lane>/state.json` | run-tester.sh | round, status (`waiting-capacity`, `running`, `done`), model |
| `lanes/<lane>/round<N>/report.json` | tester | progress, updated after each scenario |
| `lanes/<lane>/round<N>/DONE` | run-tester.sh / watch-round.sh | round finished: `exit=0`, `exit=quota ...`, `exit=1 rc=runner-died` |
| `lanes/<lane>/round<N>/verdict.json` | judge | round judged; a re-run judge returns it unchanged |
| `lanes/<lane>/feedback-r<N>.md` | judge | what round N+1 must do |
| `QUOTA_PAUSE` | quota-guard.sh | testers paused; lifted automatically after the reset |
| workflow `journal.jsonl` | Workflow tool | completed agent calls; replayed for free with `resumeFromRunId` |

## Procedure (after a reboot, a Claude limit, or "continue")

1. `bash <run>/scripts/restart-watchers.sh <run>` — starts the quota guard, memlog and (when `DEV_CMD` is set)
   the dev server if they are not running, and says whether the machine rebooted. For a reboot, read the last
   `memlog.txt` lines it prints: memory pressure before the crash means lowering `HARD_CAP`.
2. `python3 <run>/scripts/status.py <run>` — where every lane stands.
3. `python3 <run>/scripts/launch.py <run> show` — the script path, args and last run id.
4. **Resume the same run.** Call `Workflow({ scriptPath, args, resumeFromRunId })` with exactly those values.
   Completed agents (judged rounds, filings, waits) replay from the journal at no cost; only agents that were
   mid-work re-run, and the round agents re-attach to a live tester or resume the same tester session. Record
   the new run id with `launch.py <run> record <id>`.
5. **If the Workflow tool refuses the resume** (a new Claude session: replay only works in the session that
   started the run) or you changed the script or args: launch fresh from the same template, with `start` set to
   each lane's current round and `done_lanes` listing the satisfied lanes. Write the new args to `launch.json`
   first. The files keep this cheap: designers skip existing plans, judges return existing `verdict.json`, and
   run-tester.sh resumes interrupted rounds in their tester session.

Testers still running (`pgrep -fl "run-tester.sh <run> "`) are left alone either way; round agents wait on
them instead of starting a second copy.

## Failure modes seen in practice

- **Stale quota markers.** A `DONE` saying `quota` from before a reset looks like a fresh pause. Round agents
  rename it to `DONE.stale-quota` before starting; if you relaunch by hand, do the same.
- **Editing a running script.** Bash reads scripts lazily, so editing `run-tester.sh` under a live round can
  run garbage. Runners execute from a frozen copy in `.runner/`; edit the source freely.
- **Runner died without DONE.** `watch-round.sh` writes `DONE` (`rc=runner-died`) so nothing waits forever.
- **Lost launch args.** Without the exact args, replay misses every cached agent and re-runs judged rounds.
  That is why `launch.json` is written before the launch, not after.
- **Reboot under memory pressure.** Two reboots happened with 3-5 testers plus heavy apps on 16 GB. The
  capacity gate prevents new lanes under pressure; it cannot stop other apps from using memory. Two later
  reboots happened while the run was paused with plenty of free memory; memlog tells the two apart.
- **Tester quota weekly window.** Waiting days is not useful; weekly pauses stop the lane and are reported.
- **Early quota reset.** A window can reset before its recorded `resets_at`. The guard probes every 20 minutes
  while paused and lifts the pause as soon as both windows read under the thresholds.
- **Lanes shifting the active workspace.** Lanes that create organizations or workspaces can make a fresh
  sign-in land in an empty one, and a tester then reports every scenario as blocked. Tell testers in
  `context.md` which workspace holds the test data and to switch back to it after every sign-in.
- **Quota false positive.** A tester that quotes earlier feedback about a usage limit must not count as a
  quota stop; only the tester CLI's own error line does.
