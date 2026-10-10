import {test} from 'node:test';
import assert from 'node:assert/strict';
import {prepare, requested, eligible, trusted, completed, completion, skippedNotice} from './claude-review.mjs';
const pr = {number: 9, state: 'open', draft: false, user: {login: 'author'},
  head: {sha: 'a'.repeat(40), repo: {full_name: 'owner/repo'}}, base: {sha: 'b'.repeat(40)}};
test('only ready conversion or exact new PR command requests review', () => {
  for (const action of ['opened', 'synchronize', 'reopened']) assert.equal(requested({action}, 'pull_request'), false);
  assert.equal(requested({action: 'ready_for_review'}, 'pull_request'), true);
  for (const body of ['/review please', '@claude', '/review\nextra', ' /review', '/review '] )
    assert.equal(requested({action: 'created', issue: {pull_request: {}}, comment: {body}}, 'issue_comment'), false);
  assert.equal(requested({action: 'created', issue: {pull_request: {}}, comment: {body: '/review'}}, 'issue_comment'), true);
  assert.equal(requested({action: 'edited', issue: {pull_request: {}}, comment: {body: '/review'}}, 'issue_comment'), false);
});
test('draft, closed, fork and dependabot guards', () => {
  assert.equal(eligible(pr, 'owner/repo'), true);
  for (const changed of [{draft: true}, {state: 'closed'}, {head: {...pr.head, repo: null}}, {user: {login: 'dependabot[bot]'}}])
    assert.equal(eligible({...pr, ...changed}, 'owner/repo'), false);
});
test('permission and newest status are load bearing', () => {
  for (const p of ['read', 'triage', 'none']) assert.equal(trusted(p), false);
  for (const p of ['write', 'maintain', 'admin']) assert.equal(trusted(p), true);
  assert.equal(completed([{context: 'Claude review', state: 'error'}, {context: 'Claude review', state: 'success'}]), false);
  assert.equal(completed([{context: 'Claude review', state: 'success'}]), true);
});
test('current permission is checked before PR access; ready pins head; workflow edits skip', async () => {
  const event = {action: 'created', issue: {number: 9, pull_request: {}}, comment: {body: '/review', user: {login: 'reader'}}};
  let calls = [];
  const api = async path => {calls.push(path); if (path.endsWith('/permission')) return {permission: 'read'}; throw Error('Unauthorized PR access');};
  assert.equal((await prepare({event, name: 'issue_comment', repo: 'owner/repo', api})).run, false);
  assert.equal(calls.length, 1);
  const run = async (event, files = [], statuses = []) => prepare({event, name: 'pull_request', repo: 'owner/repo', api: async path =>
    path.includes('/statuses') ? statuses : path.includes('/files') ? files : pr});
  assert.equal((await run({action: 'ready_for_review', pull_request: {...pr, head: {...pr.head, sha: 'old'}}})).run, false);
  const ready = {action: 'ready_for_review', pull_request: pr};
  assert.equal((await run(ready, [{filename: '.github/scripts/claude-review.mjs'}])).run, false);
  assert.equal((await run(ready, [], [{context: 'Claude review', state: 'success'}])).run, false);
  assert.deepEqual(await run(ready), {run: true, number: 9, head: pr.head.sha, base: pr.base.sha});
});

test('only successful action and model conclusion on the unchanged head records completion', () => {
  assert.equal(completion(pr, pr.head.sha, 'success', 'success').state, 'success');
  for (const [outcome, conclusion] of [['failure','success'], ['success','failure'], ['cancelled','success'], ['success','']])
    assert.equal(completion(pr, pr.head.sha, outcome, conclusion).state, 'error');
  assert.equal(completion(pr, 'old', 'success', 'success').state, 'error');
  assert.equal(completion({...pr, draft:true}, pr.head.sha, 'success', 'success').state, 'error');
});

// A review that completed but was discarded as stale writes no status (correct, since
// the head moved) AND fires no "did not complete" path (also correct, since it did
// complete). Without a comment it therefore reaches nobody, and a reader cannot tell it
// from "not reviewed yet" — the two states are indistinguishable on the PR.
test('a review discarded as stale comments on the PR with both heads', () => {
  const stale = completion(pr, 'old', 'success', 'success');
  assert.equal(stale.state, 'error');
  assert.match(stale.comment, /old/);
  assert.match(stale.comment, new RegExp(pr.head.sha));
});

// A failure and a skip must both comment, so the reason is visible rather than implied
// by a red or absent check.
test('a failed or skipped review comments with the reason', () => {
  // The wording says "did not complete" rather than "failed", because it covers both an
  // action failure and a model failure and the distinction is not the reader's to make.
  assert.match(completion(pr, pr.head.sha, 'failure', '').comment, /did not complete/i);
  const skipped = skippedNotice(pr);
  assert.match(skipped.comment, /skipped/i);
});

// The workflow's own structure: a consumed job header, a duplicate permissions block, or
// a status-writing job without the permission. Each is caught before a run rather than by
// reading a red job — the permission failure throws out of the script and fails the step,
// which is loud, but only after a run that spends a review to discover it.
test('the workflow declares one job, and every status writer declares the permission', async () => {
  const {check} = await import('./check-workflow-structure.mjs');
  const {readFileSync} = await import('node:fs');
  const src = readFileSync(new URL('../../.github/workflows/claude-code-review.yml', import.meta.url), 'utf8');
  assert.equal(check(src), true);
  // A consumed job header leaves valid YAML with no job at all.
  assert.throws(() => check(src.replace('  claude-review:', '')), /exactly one job/);
  // A second permissions block silently overrides.
  assert.throws(() => check(src.replace('    steps:', '    permissions:\n      contents: read\n    steps:')), /one permissions block/);
  // A status writer without the permission fails the step, so the job goes red.
  assert.throws(() => check(src.replace('      statuses: write\n', '')), /statuses: write/);
  // And the permission must belong to the job that writes the status. Extracting the
  // first `permissions:` block in the file reads a different job's block as soon as one
  // exists, so removing the real job's permission would still pass. The check relates the
  // job to its own block rather than matching the nearest one.
  // The masking case keeps one job (so the job-set assertion is satisfied) and puts an
  // earlier `permissions:` block in the file, which a first-match extractor would read.
  const withEarlierBlock = src.replace(/^    steps:\n/m,
    '    permissions:\n      statuses: write\n    steps:\n');
  const permissionRemoved = withEarlierBlock.replace('      statuses: write\n      # Unused', '      # Unused');
  assert.throws(() => check(permissionRemoved), /statuses: write/,
    "a preceding permissions block masked the defect");
});

// The status payload must carry only fields the statuses API documents. `completion`
// also returns `comment` for the issue-comment channel, and spreading the whole object
// sent it to the statuses endpoint too — harmless only because the API tolerates the
// extra field, which is not something to depend on.
test('the status payload carries only documented fields', async () => {
  const {readFileSync} = await import('node:fs');
  const src = readFileSync(new URL('./claude-review.mjs', import.meta.url), 'utf8');
  // The LAST statuses call, which is the `finish` phase's. Slicing from the FIRST
  // occurrence inspected `prepare`'s pending call instead — a different site with
  // different fields — so the case passed while the `finish` payload still spread an
  // object. The search has to name the call it means.
  const call = src.slice(src.lastIndexOf('repos/${repo}/statuses/'));
  const payload = call.slice(call.indexOf('{'), call.indexOf('});') + 1);
  assert.ok(!payload.includes('...'), 'the status payload spreads an object rather than naming fields');
  for (const field of ['state', 'description', 'context', 'target_url']) assert.ok(payload.includes(field), `missing ${field}`);
});

// The status `description` is the text a reader sees in the checks tab, so it is a real
// output and not just a diagnostic. It had no assertion while the comment — the channel
// added second — was pinned for both SHAs, which is the wrong way round: the channel that
// existed first should not be the one nothing checks.
test('the status description names the state that produced it', () => {
  assert.equal(completion(pr, pr.head.sha, 'success', 'success').description,
    'Review completed; findings still require disposition');
  assert.match(completion(pr, 'old', 'success', 'success').description, /head changed/i);
  assert.match(completion(pr, pr.head.sha, 'failure', '').description, /failed/i);
  // A draft PR is not fresh either, and its description must send the reader to /review
  // rather than reporting a completed review on a head nobody will merge.
  assert.match(completion({...pr, draft: true}, pr.head.sha, 'success', 'success').description, /head changed/i);
});

// The pending description is written before any model call, so it must exist for every
// state — including one where the review later fails — and must not claim a result.
test('the pending description claims no outcome', async () => {
  const {readFileSync} = await import('node:fs');
  const src = readFileSync(new URL('./claude-review.mjs', import.meta.url), 'utf8');
  const pending = src.slice(src.indexOf("description: 'Reviewing"));
  assert.match(pending.slice(0, 60), /Reviewing this head/);
});

// The detector keys on text, so it is only as strong as the stability of that text. If a
// rename or reflow stops it matching, the assertion below it would be skipped and the
// check would report OK having proved nothing. It must fail closed instead.
test('the detector fails loudly when it matches nothing', async () => {
  const {check} = await import('./check-workflow-structure.mjs');
  const {readFileSync} = await import('node:fs');
  const src = readFileSync(new URL('../../.github/workflows/claude-code-review.yml', import.meta.url), 'utf8');
  assert.throws(() => check(src.replace(/claude-review\.mjs/g, 'renamed-review.mjs')),
    /detector did not match/);
});

// Both shapes count, and neither covers the other: Android and core call
// `gh api .../statuses/` inline, iOS and core invoke the script. Keying on the script alone
// silently skipped Android's file, which is a live shape rather than a hypothetical one.
test('an inline status call is detected, not skipped', async () => {
  const {check} = await import('./check-workflow-structure.mjs');
  const {readFileSync} = await import('node:fs');
  const src = readFileSync(new URL('../../.github/workflows/claude-code-review.yml', import.meta.url), 'utf8');
  const inline = src
    .replace('        run: node "$RUNNER_TEMP/claude-review.mjs" finish',
      '        run: gh api "repos/x/statuses/y" -f state=success')
    .replace('      statuses: write\n      # Unused', '      # Unused');
  assert.throws(() => check(inline), /statuses: write/,
    'an inline status writer without the permission was not caught');
});
