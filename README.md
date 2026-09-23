# cup-with-qa

[![skills.sh](https://skills.sh/b/conceptmates/cup-with-qa)](https://skills.sh/conceptmates/cup-with-qa)

An agent skill for end-to-end QA campaigns on web and mobile apps. Claude Opus plans real-life happy and
failure scenarios per feature lane, a tester model (Codex by default) drives the app in isolated browser
or device sessions, Opus judges every round from screenshots and source, and verified findings become
issues with the screenshots embedded.

## Install

```bash
npx skills add conceptmates/cup-with-qa -g        # from GitHub
npx skills add ./path/to/cup-with-qa -g           # from a local checkout
```

Listed on [skills.sh](https://skills.sh/conceptmates/cup-with-qa).

```bash
# update later
npx skills update cup-with-qa -g
```

## Requirements

- Claude Code with the Workflow tool (multi-agent orchestration)
- `codex` CLI, signed in (the default tester)
- Web targets: `agent-browser`. Mobile targets: `agent-device` (`npx -y agent-device`), plus an iOS
  simulator or Android emulator
- `gh`, signed in, for GitHub issue filing
- `python3`, `bash`

## What it handles

- Preflight questions for target, tester model, credentials, mutation safety, quota limits, scale and
  issue tracker, confirmed before anything runs
- Scenario plans with at least 60% failure and edge paths, plus real-life, click-everything, UI/UX and
  mobile-view lanes
- An admission gate that starts lanes only while RAM, swap and CPU leave headroom
- A quota guard that pauses testers at a threshold and resumes the same tester session after the reset
- File-based state, so a reboot or session stop resumes without redoing finished work
- Issues in a fixed format: where, steps, expected, actual, likely cause, console errors, evidence

## Layout

```
skills/cup-with-qa/
  SKILL.md
  scripts/     init-run.sh run-tester.sh watch-round.sh capacity.sh quota-guard.sh memlog.sh status.py
  templates/   tester-brief-web.md tester-brief-mobile.md scenario-format.md issue-template.md workflow.template.js
  references/  resume.md
```
