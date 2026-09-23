export const meta = {
  name: 'cup-with-qa',
  description: 'QA campaign: Opus designs scenarios per lane, a tester model runs rounds behind a RAM/CPU admission gate, Opus judges each round, then files issues with evidence',
  phases: [
    { title: 'Design', detail: 'Opus writes scenarios.md per lane (skipped if it exists)' },
    { title: 'Test', detail: 'waiter starts run-tester.sh and watches the round' },
    { title: 'Wait', detail: 'waits out a tester quota pause' },
    { title: 'Judge', detail: 'Opus verifies evidence and coverage, writes verdict.json + feedback' },
    { title: 'Dedupe', detail: 'merge findings across lanes, drop already-filed' },
    { title: 'File', detail: 'push evidence, create issues, read them back' },
  ],
}

// args (pass as a JSON object, not a string):
// {
//   run_dir: '/abs/path/to/run',              // durable run dir created by init-run.sh
//   lanes: [{ id: 'checkout', scope: '...' }],
//   start: { checkout: 2 },                   // optional: first round per lane (resume)
//   done_lanes: ['auth'],                     // optional: lanes already satisfied
//   max_rounds: 3, pool: 6,                   // pool = HARD_CAP; capacity.sh throttles real testers
//   max_quota_waits: 6,
//   source_paths: ['/abs/frontend', '/abs/backend'],
//   research_notes: '...',                    // optional product/usage context for designers
//   filed: ['#87 Instagram Add File dialog ...'],   // already-filed titles, compact
//   tracker: { repo: 'owner/name', evidence_branch: 'qa-evidence', run_label: 'e2e-2026-09-23',
//              date: '2026-09-23', tester_label: 'Codex gpt-6-luna' },
// }
const A = args
const RUN = A.run_dir
const MAX_ROUNDS = A.max_rounds || 3
const POOL = A.pool || 6
const MAX_WAITS = A.max_quota_waits || 6
const FILED = (A.filed || []).join('\n')
const DONE_LANES = new Set(A.done_lanes || [])
const START = A.start || {}
const SRC = (A.source_paths || []).join(', ')

const DESIGN_SCHEMA = { type: 'object', properties: { scenario_count: { type: 'number' }, failure_share: { type: 'number' } }, required: ['scenario_count'] }
const ROUND_SCHEMA = { type: 'object', properties: { done_line: { type: 'string' } }, required: ['done_line'] }
const WAIT_SCHEMA = { type: 'object', properties: { resumed: { type: 'boolean' }, reason: { type: 'string' } }, required: ['resumed', 'reason'] }
const FINDING = {
  type: 'object',
  properties: {
    title: { type: 'string' }, type: { type: 'string' }, severity: { type: 'string' }, route: { type: 'string' },
    viewport: { type: 'string' }, steps: { type: 'array', items: { type: 'string' } }, expected: { type: 'string' },
    actual: { type: 'string' }, mechanism: { type: 'string' }, console_errors: { type: 'array', items: { type: 'string' } },
    screenshots: { type: 'array', items: { type: 'string' }, description: 'absolute paths to PNGs the judge opened' },
  },
  required: ['title', 'type', 'severity', 'route', 'steps', 'expected', 'actual', 'screenshots'],
}
const VERDICT_SCHEMA = {
  type: 'object',
  properties: { satisfied: { type: 'boolean' }, coverage_score: { type: 'number' }, reason: { type: 'string' }, verified_findings: { type: 'array', items: FINDING } },
  required: ['satisfied', 'coverage_score', 'reason', 'verified_findings'],
}

const designPrompt = l => `You are the Opus test designer for lane "${l.id}" of a QA campaign. Run dir: ${RUN} (config in config.env, run context in context.md). Source: ${SRC}.
If ${RUN}/lanes/${l.id}/scenarios.md already exists and is non-empty, do nothing else: return its scenario count.
Otherwise: lane scope — ${l.scope}
${A.research_notes ? 'Product research notes: ' + A.research_notes : ''}
1. Read the source for this scope (screens, forms, validation, integrations) so steps use real labels and routes, and note server-side rules that produce user-visible errors.
2. Research on the web how real users use this kind of product for this area and what they commonly get wrong.
3. Write ${RUN}/lanes/${l.id}/scenarios.md following ${RUN}/templates/scenario-format.md exactly: at least 60% failure/edge paths, at least two failures per happy path, exact steps and test data, expected results, then the exhaustive sweep.
Do not open the app yourself. Return the scenario count and the failure share (0-1).`

const roundPrompt = (l, r) => `You orchestrate one tester round for lane "${l.id}", round ${r}. You never test the app yourself; the tester does.
Run dir: ${RUN}. Round dir: ${RUN}/lanes/${l.id}/round${r}.
1. If round${r}/DONE exists and contains "quota", it is stale from an earlier pause: rename it to DONE.stale-quota.
2. If round${r}/DONE exists with exit=0, skip to step 4.
3. If no process matches pgrep -f "run-tester.sh ${RUN} ${l.id} ${r}$", start it detached: nohup bash ${RUN}/scripts/run-tester.sh ${RUN} ${l.id} ${r} >/dev/null 2>&1 &
   Never start a second copy.
4. Wait: run bash ${RUN}/scripts/watch-round.sh ${RUN} ${l.id} ${r} (Bash tool timeout 600000). Exit 2 means still running or waiting for capacity — run it again, as many times as needed (a round can take hours). Exit 0 or 3 means finished.
Return the DONE line verbatim.`

const waitPrompt = (l, r) => `The tester quota paused lane "${l.id}" (round ${r}) with its progress saved. Your only job is to wait for the pause to lift. Run dir: ${RUN}.
1. If ${RUN}/QUOTA_PAUSE does not exist, wait up to 3 minutes for it: timeout 180 bash -c 'until [ -f ${RUN}/QUOTA_PAUSE ]; do sleep 15; done'. Still absent: return resumed=true, reason="no pause file".
2. If it contains which=weekly: return resumed=false with the reset date — do not wait days.
3. Otherwise repeat (Bash tool timeout 600000): timeout 580 bash -c 'until [ ! -f ${RUN}/QUOTA_PAUSE ]; do sleep 60; done'; tail -1 ${RUN}/quota.log
   until the file is gone. Over 6 hours total: return resumed=false, reason="waited >6h".
4. Rename ${RUN}/lanes/${l.id}/round${r}/DONE to DONE.stale-quota if it contains "quota". Return resumed=true.`

const judgePrompt = (l, r, doneLine) => `You are the Opus judge for lane "${l.id}", round ${r} of at most ${MAX_ROUNDS}. Runner finished with: ${doneLine}.
If ${RUN}/lanes/${l.id}/round${r}/verdict.json exists, return its contents unchanged and stop.
Inputs: scenario plan ${RUN}/lanes/${l.id}/scenarios.md; report ${RUN}/lanes/${l.id}/round${r}/report.json (screenshot paths relative to the round dir); tester log tester*.log in the round dir; source ${SRC}; project rules in the repos' CLAUDE.md.
Be demanding:
A. Coverage — every scenario has a real status and a final-state screenshot; the exhaustive sweep happened; failure paths were genuinely tried; "blocked" is justified.
B. Each finding — open its screenshots and confirm they show the claimed problem; open the cited file and confirm the cause, else write "not confirmed". Reject findings without a screenshot, speculation, intended behaviour, and duplicates of already-filed issues:
${FILED || '(none filed yet)'}
Rewrite titles as specific user-visible symptoms.
C. verified_findings use ABSOLUTE screenshot paths you opened.
D. satisfied=true only if coverage is essentially complete and findings are evidence-backed.
Write ${RUN}/lanes/${l.id}/feedback-r${r}.md (numbered list of what the next round must do, or "satisfied"), then write the verdict JSON to ${RUN}/lanes/${l.id}/round${r}/verdict.json, then return it.`

async function runLane(l) {
  const found = new Map()
  const design = await agent(designPrompt(l), { label: `design:${l.id}`, phase: 'Design', schema: DESIGN_SCHEMA, effort: 'high' })
  if (!design) { log(`${l.id}: design failed — lane skipped`); return { lane: l.id, findings: [], paused: true } }
  let verdict = null
  let r
  for (r = START[l.id] || 1; r <= MAX_ROUNDS; r++) {
    let waits = 0, run = null
    while (true) {
      run = await agent(roundPrompt(l, r), { label: `round:${l.id}:r${r}${waits ? '#' + (waits + 1) : ''}`, phase: 'Test', schema: ROUND_SCHEMA, effort: 'low' })
      if (!run) { log(`${l.id} r${r}: orchestrator failed — lane paused`); return { lane: l.id, findings: [...found.values()], round: r, paused: true } }
      if (!/quota/.test(run.done_line)) break
      if (waits >= MAX_WAITS) { log(`${l.id} r${r}: quota waits exhausted — lane paused`); return { lane: l.id, findings: [...found.values()], round: r, paused: true } }
      const w = await agent(waitPrompt(l, r), { label: `wait-quota:${l.id}:r${r}#${waits + 1}`, phase: 'Wait', schema: WAIT_SCHEMA, effort: 'low' })
      if (!w || !w.resumed) { log(`${l.id} r${r}: not resuming (${w ? w.reason : 'waiter failed'}) — lane paused`); return { lane: l.id, findings: [...found.values()], round: r, paused: true } }
      waits++
    }
    verdict = await agent(judgePrompt(l, r, run.done_line), { label: `judge:${l.id}:r${r}`, phase: 'Judge', schema: VERDICT_SCHEMA, effort: 'high' })
    if (!verdict) { log(`${l.id} r${r}: judge failed — lane paused`); return { lane: l.id, findings: [...found.values()], round: r, paused: true } }
    for (const f of verdict.verified_findings) found.set(f.title, { ...f, lane: l.id })
    log(`${l.id} r${r}: coverage ${verdict.coverage_score}, ${verdict.verified_findings.length} verified, satisfied=${verdict.satisfied}`)
    if (verdict.satisfied) break
  }
  return { lane: l.id, findings: [...found.values()], round: Math.min(r, MAX_ROUNDS), satisfied: !!(verdict && verdict.satisfied), coverage: verdict ? verdict.coverage_score : 0 }
}

// worker pool: POOL lanes in flight; capacity.sh decides how many testers actually run
const queue = A.lanes.filter(l => !DONE_LANES.has(l.id))
const results = []
await parallel(Array.from({ length: Math.min(POOL, queue.length) }, () => async () => {
  while (queue.length) { const l = queue.shift(); const res = await runLane(l); if (res) results.push(res) }
}))
const all = results.flatMap(x => x.findings)
log(`${all.length} verified findings from ${results.length} lanes`)

phase('Dedupe')
const T = A.tracker || {}
const ISSUES_SCHEMA = { type: 'object', properties: { issues: { type: 'array', items: { ...FINDING, properties: { ...FINDING.properties, lanes: { type: 'array', items: { type: 'string' } }, labels: { type: 'array', items: { type: 'string' } } } } } }, required: ['issues'] }
const merged = all.length ? await agent(`Merge these verified QA findings into a final issue list. Merge true duplicates (same root cause, or same symptom on the same screen), keeping the best steps and the union of screenshots (absolute paths) and lanes. Drop anything that duplicates an already-filed issue:
${FILED || '(none)'}
Labels per ${RUN}/templates/issue-template.md: one of bug/ux/a11y/enhancement, severity:<level>, area:<lane>. Sort by severity.
Findings: ${JSON.stringify(all)}`, { label: 'dedupe', schema: ISSUES_SCHEMA, effort: 'high' }) : { issues: [] }
const issues = (merged && merged.issues) || []

phase('File')
let filed = []
if (issues.length && T.repo) {
  const push = await agent(`Push QA screenshots to the evidence branch, once.
Evidence clone: ${RUN}/evidence (create it if missing: git clone --single-branch -b ${T.evidence_branch} https://github.com/${T.repo}.git ${RUN}/evidence; if the branch does not exist, create an orphan branch ${T.evidence_branch} with a README and push it).
For issue i (1-based, order below) copy each screenshot to ${RUN}/evidence/${T.run_label}/issue-<i>/<basename> (prefix the basename with its lane if two collide). git add that folder only, commit "qa-evidence: ${T.run_label}", push, verify with git ls-remote. Return each i with its repo-relative paths.
Issues: ${JSON.stringify(issues.map((x, i) => ({ i: i + 1, screenshots: x.screenshots })))}`,
    { label: 'push-evidence', effort: 'low', schema: { type: 'object', properties: { pushed: { type: 'boolean' }, map: { type: 'array', items: { type: 'object', properties: { i: { type: 'number' }, paths: { type: 'array', items: { type: 'string' } } }, required: ['i', 'paths'] } } }, required: ['pushed', 'map'] } })
  const paths = new Map(((push && push.map) || []).map(m => [m.i, m.paths]))
  const chunks = []
  for (let s = 0; s < issues.length; s += 8) chunks.push(issues.slice(s, s + 8).map((x, k) => ({ ...x, i: s + k + 1, evidence: paths.get(s + k + 1) || [] })))
  const FILE_SCHEMA = { type: 'object', properties: { created: { type: 'array', items: { type: 'object', properties: { i: { type: 'number' }, url: { type: 'string' }, title: { type: 'string' } }, required: ['i', 'url'] } } }, required: ['created'] }
  filed = (await parallel(chunks.map((c, n) => () => agent(`Create GitHub issues in ${T.repo} with gh, following ${RUN}/templates/issue-template.md exactly (title, labels incl. ${T.run_label}, body sections in order, evidence embedded as https://github.com/${T.repo}/blob/${T.evidence_branch}/<path>?raw=true, footer "Found by the ${T.date} E2E run (tested by ${T.tester_label}, verified by Claude Opus)."). Plain, specific prose. Create missing labels with gh label create --force. Write each body to a file and use --body-file. After creating, gh issue view each one; report only URLs gh returned.
Issues: ${JSON.stringify(c)}`, { label: `file:${n + 1}`, effort: 'medium', schema: FILE_SCHEMA })))).filter(Boolean).flatMap(x => x.created)
}

return {
  lanes: results.map(x => ({ lane: x.lane, round: x.round, satisfied: !!x.satisfied, paused: !!x.paused, coverage: x.coverage || 0, verified: x.findings.length })),
  issues_filed: filed.length,
  issues: filed,
}
