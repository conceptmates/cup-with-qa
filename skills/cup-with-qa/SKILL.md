---
name: cup-with-qa
description: End-to-end QA campaign for a web or mobile app. Opus plans real-life happy and failure scenarios per feature lane, a tester model (Codex by default) drives the app in isolated browser or device sessions, Opus judges every round from screenshots and source, then files tracker issues with embedded evidence. Use whenever the user asks to E2E test or QA a whole app, test every feature, button or flow, run real-life scenarios, do rapid click testing, validate UI/UX or mobile view, or file bugs with screenshots, even if they never say "QA campaign".
---

# cup-with-qa

A QA campaign has two roles that never swap:

- **Opus (you)** is the conductor: preflight, scenario design, orchestration, judging, filing.
- **The tester** (default Codex `gpt-6-luna`, effort `max`) is the only thing that touches the app. You never click through the app yourself; a finding you did not get from the tester's evidence does not exist.

Everything lives in a **run dir** on real disk (never `/tmp`; a reboot wipes it) and every state change is written there, so any stop — reboot, Claude limit, tester quota — resumes from files instead of from memory.

## Step 1 — Preflight

Ask every decision with `AskUserQuestion`, in rounds: a round only asks what earlier answers have settled. Put the recommended option first with "(Recommended)". Look up facts yourself (routes, framework, running dev server, connected devices, `codex --version`, free RAM, `gh auth status`) and report them before asking.

1. **Target** — web URL (tester uses `agent-browser`) or mobile: iOS simulator / Android emulator (tester uses `agent-device`). Which app, build or bundle id.
2. **Tester** — model and effort. Default Codex `gpt-6-luna` / `max`.
3. **Access** — credentials and test accounts. Grill: for every scenario family you will plan, ask for what it needs that you do not have — 2FA/OTP, OAuth, payment test cards, third-party API keys, test phone numbers, a second account for multi-user flows. A missing credential becomes a `blocked` scenario, so ask now.
4. **Safety** — which backend (prod / staging / local) and how far the tester may mutate: read-only, create/edit own data, or full (send, publish, pay). Data it must never touch.
5. **Limits** — tester quota pause threshold (default 94% of the 5-hour window, 95% weekly) and what happens at the limit: wait for reset and resume the same session (default), or switch to a fallback model.
6. **Scale** — hard cap on concurrent lanes (default 6), RAM per lane (web ≈2500 MB, mobile ≈4000 MB), max rounds per lane (default 3).
7. **Output** — tracker (GitHub via `gh`, or another), repo, evidence branch name, run label (e.g. `e2e-2026-09-23`), what to do with existing open issues. Destructive actions (closing/deleting issues) are confirmed separately.
8. **Read-back** — restate the full plan in a short summary and ask "anything unclear or missing?" Loop until the user confirms. Nothing starts before this.

## Step 2 — Set up the run dir

```bash
SKILL=<this skill's directory>
RUN=<durable path, e.g. ~/qa-runs/<project>-<date>>
bash "$SKILL/scripts/init-run.sh" "$RUN"
```

Then write, from the preflight answers:

- `$RUN/config.env` — target, tester model/effort, limits, scale.
- `$RUN/context.md` — the "Run context" every tester reads: credentials and test accounts, mutation policy, data to leave alone, source paths (read-only), device name for mobile, anything a tester would otherwise ask.
- `$RUN/filed.txt` — already-filed issues, one `#N title` per line.
- `$RUN/HANDOFF.md` — what this run is, where things are, how to resume.

For mobile, check the general `agent-device` CLI works (`npx -y agent-device --help`); some IDE wrappers named `agent-device` only work through their own tool. Start the watchers, detached so they survive the session:

```bash
bash "$RUN/scripts/restart-watchers.sh" "$RUN"   # quota guard + memlog (+ dev server if DEV_CMD is set)
```

Smoke-test before any fan-out: one tiny tester call that signs in and saves a screenshot. If it fails, fix it now; thirteen lanes failing the same way costs thirteen times as much.

## Step 3 — Plan lanes and scenarios

Read the code (routes, screens, forms, integrations) and research on the web how real users use this kind of product and what they get wrong. Split the app into **lanes**: one per feature area, plus four that every campaign has:

- **real-life** — end-to-end journeys a real customer or operator runs (book a slot, order by DM, sign up then pay), each with its happy path and its failures.
- **rapid-clicks** — every clickable element on every route; crashes, dead buttons, dialogs that will not close, back/refresh on deep links.
- **uiux** — hierarchy, copy, empty/loading/error states, focus and keyboard, contrast, dark mode; each problem paired with a concrete improvement.
- **mobile-view** — phone and tablet sizes (web) or both platforms (mobile).

Write `$RUN/lanes.json` (`[{"id": "...", "scope": "..."}]`). Scenario files are written per lane by designer agents inside the workflow, following `templates/scenario-format.md`: at least **60% failure and edge paths**, at least two failures for every happy path.

## Step 4 — Launch the orchestration workflow

Run the workflow straight from the template — it is driven entirely by `args` (documented at its top), so there is nothing to edit.

First write `$RUN/launch.json` with the script path and the exact args object, then launch with those same values:

```
Workflow({ scriptPath: "$RUN/templates/workflow.template.js",
           args: { run_dir, lanes, max_rounds, pool: HARD_CAP, source_paths, research_notes, filed, tracker } })
```

Then `python3 "$RUN/scripts/launch.py" "$RUN" record <run id>` and note the run id in `HANDOFF.md`. Replay after a stop only works with the same script and args, so `launch.json` is what lets "continue" pick up this run instead of starting over. The template already handles:

- **dynamic spawning** — every round starts through `scripts/capacity.sh`, which admits a lane only while free RAM, swap growth and CPU load leave headroom, up to the hard cap. Lanes wait at the gate and start as memory frees; running testers are never killed.
- **the round loop** — a cheap waiter agent starts `scripts/run-tester.sh` and blocks on `scripts/watch-round.sh`; a judge agent reads the report, looks at every finding's screenshots, checks the claimed cause in the source, and writes `verdict.json` + `feedback-r<N>.md`. The lane stops when the judge is satisfied or after max rounds.
- **quota** — when `quota-guard.sh` raises `QUOTA_PAUSE`, testers stop with their reports saved; a waiter agent sleeps until the guard lifts it, then the same round resumes the **same tester session**.
- **filing** — after all lanes, a dedupe pass, evidence push, then issues in the format of `templates/issue-template.md`.

## Step 5 — Monitor

`python3 "$RUN/scripts/status.py" "$RUN"` shows every lane's round, scenarios by status, findings, screenshots, plus quota, capacity and memory. Use it for every status question; do not spawn an agent to find out.

Swap climbing steadily or free memory under ~15% is the pattern that preceded both reboots in the campaign this skill came from. Tell the user and suggest closing heavy apps; the capacity gate already stops new lanes.

## Step 6 — Resume after any stop

When the user says "continue", or after a reboot or Claude limit, read `references/resume.md`. In short:

1. `bash "$RUN/scripts/restart-watchers.sh" "$RUN"` — restarts the quota guard, memlog and dev server if they are down, and reports a reboot.
2. `python3 "$RUN/scripts/launch.py" "$RUN" show`, then resume the **same run**: `Workflow({ scriptPath, args, resumeFromRunId })` with exactly those values. Completed agents replay from the journal for free; only agents that were mid-work re-run, and they re-attach to a live tester or resume its session.
3. If the tool refuses (a new Claude session) or the args changed, launch fresh with `start` = each lane's current round and `done_lanes`. Judges return an existing `verdict.json` and interrupted rounds resume their tester session, so this stays cheap.

## Step 7 — Report

List the issues filed (number, severity, title, URL), lanes that finished satisfied vs paused, and what was not covered and why. Quote only URLs the tracker returned.

## Rules the judge enforces

- A finding needs a screenshot the judge opened that shows the problem. No screenshot, no issue.
- "Likely cause" names a file and line the judge opened, or says "not confirmed".
- Intended behaviour documented in the project's CLAUDE.md or specs is not a bug.
- Duplicates of already-filed issues are dropped, not refiled.

## Files

- `scripts/init-run.sh` — create a run dir with config and scripts
- `scripts/run-tester.sh` — one tester round; frozen copy, capacity gate, same-session resume, quota handling, `DONE` + `state.json`
- `scripts/watch-round.sh` — bounded wait on a round; writes `DONE` if the runner died
- `scripts/capacity.sh` — admission gate on RAM, swap, CPU
- `scripts/quota-guard.sh` — pause at threshold, lift after reset
- `scripts/restart-watchers.sh` — start guard, memlog and dev server if down; detects a reboot
- `scripts/launch.py` — record run ids next to the saved launch args; print what a resume needs
- `scripts/memlog.sh`, `scripts/status.py`
- `templates/` — tester briefs (web, mobile), scenario format, issue template, workflow template
- `references/resume.md` — resume procedure and failure modes
