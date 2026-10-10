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
// a status-writing job without the permission all leave the file looking healthy while
// the review silently cannot run or cannot record.
test('the workflow declares one job, and every status writer declares the permission', async () => {
  const {check} = await import('./check-workflow-structure.mjs');
  const {readFileSync} = await import('node:fs');
  const src = readFileSync(new URL('../../.github/workflows/claude-code-review.yml', import.meta.url), 'utf8');
  assert.equal(check(src), true);
  // A consumed job header leaves valid YAML with no job at all.
  assert.throws(() => check(src.replace('  claude-review:', '')), /exactly one job/);
  // A second permissions block silently overrides.
  assert.throws(() => check(src.replace('    steps:', '    permissions:\n      contents: read\n    steps:')), /one permissions block/);
  // A status writer without the permission fails invisibly under `if: always()`.
  assert.throws(() => check(src.replace('      statuses: write\n', '')), /statuses: write/);
});
