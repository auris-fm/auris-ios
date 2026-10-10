// Structural checks on the workflow file itself.
//
// These read the workflow back and assert properties that a shell guard cannot see and
// that a green run does not reveal, because each of the failures below looks exactly
// like success from the outside.
import {readFileSync} from 'node:fs';
import assert from 'node:assert/strict';

const path = new URL('../../.github/workflows/claude-code-review.yml', import.meta.url);
const src = readFileSync(path, 'utf8');

// A consumed job header leaves valid YAML that declares one job while the review can
// never run — the failure GitHub reports only as "a workflow file issue".
function jobNames(text) {
  const jobs = text.split(/\njobs:\n/)[1] ?? '';
  return [...jobs.matchAll(/^  ([A-Za-z0-9_-]+):\s*$/gm)].map(m => m[1]);
}

export function check(text) {
  const jobs = jobNames(text);
  assert.deepEqual(jobs, ['claude-review'], `expected exactly one job, got ${jobs.join(', ')}`);

  const body = text.split(/\njobs:\n/)[1];
  assert.match(body, /^    runs-on:/m, 'claude-review has no runs-on');
  assert.match(body, /^    steps:/m, 'claude-review has no steps');

  // Every job that writes a status must declare the permission for it.
  //
  // This is a cross-artifact requirement: it is visible only by relating a step's API call
  // to the job's own permission block, and neither half shows the defect on its own, which
  // is why no shell guard or single-file scan catches it.
  //
  // The failure is a 403 from the statuses call, which throws out of the script's
  // `execFileSync` and fails the step — so the job goes red. That is loud rather than
  // silent. An earlier note here claimed the job stays green with no status; that was a
  // plausible mechanism offered without checking the exit path, which is the exact error
  // this workflow exists to reduce. What the check buys is that the defect is caught
  // before a run at all, rather than by reading a red job's logs.
  const permissions = text.split(/\n    permissions:\n/)[1]?.split(/\n    [a-z]/)[0] ?? '';
  // The status is written by the review-control script, which the job invokes, so the
  // workflow itself need not contain the word. What identifies a status-writing job is
  // that it runs the script's `finish` phase — an earlier version of this check looked for
  // `statuses/` or `contextName` in the workflow, found neither, and silently skipped the
  // assertion, so removing the permission still reported success.
  const writesAStatus = /claude-review\.mjs"?\s+finish/.test(body);
  if (writesAStatus) {
    assert.match(permissions, /^      statuses: write$/m,
      'the job writes a status but does not declare statuses: write');
  }

  // Duplicate keys in a permissions block silently override, so there must be one.
  const blocks = [...text.matchAll(/^    permissions:/gm)].length;
  assert.equal(blocks, 1, `expected one permissions block, found ${blocks}`);
  return true;
}

if (process.argv[1] && import.meta.url === new URL(process.argv[1], 'file:').href) {
  check(src);
  console.log('workflow structure OK');
}
