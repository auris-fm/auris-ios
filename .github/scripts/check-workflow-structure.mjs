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
  // Extracted by OWNING JOB, not by first match. The first `permissions:` block in the
  // file belongs to whichever job appears first, so reading it by position reports the
  // wrong job's block as soon as a second job exists — and the requirement is the
  // relationship between a job and its own permissions, not the presence of a block.
  const jobBlock = text.split(/\n  claude-review:\n/)[1]?.split(/\n  [a-zA-Z0-9_-]+:\s*$/m)[0] ?? '';
  const permissions = jobBlock.split(/\n    permissions:\n/)[1]?.split(/\n    [a-z]/)[0] ?? '';
  // Which shapes write a status: an inline statuses call, or invoking the review-control
  // script's `finish` phase. **Both are needed and neither covers the other** — Android and
  // core call `gh api .../statuses/` inline while iOS and core invoke the script, and I
  // measured this detector against Android's workflow: keying on the script alone silently
  // skipped the file it exists to guard.
  //
  // **Commands, not comments.** An earlier version matched the text anywhere in the job, so
  // commenting out the invocation and removing the permission still demanded `statuses: write`
  // — the guard was satisfied by a call that would never run, which is the shape of the defect
  // it exists to catch. Only lines that would execute count, so a commented `# run:` line is not
  // a writer while a live `run:` line is.
  const commandLines = body.split('\n')
    .filter(line => !/^\s*#/.test(line))
    .join('\n');
  const writesAStatus = /statuses\//.test(commandLines) || /claude-review\.mjs"?\s+finish/.test(commandLines);

  // **The detector must prove it matched.** A text-keyed detector is exactly as strong as
  // the stability of the text it keys on, so a workflow whose invocation is reflowed or
  // renamed would skip the assertion below and report OK — which is how the first version
  // of this check became inert. Failing closed here turns an unmatched pattern into a loud
  // failure rather than a silent pass.
  assert.ok(writesAStatus,
    'the detector did not match: no status-writing job detected, so this check proved nothing');

  assert.match(permissions, /^      statuses: write$/m,
    'the job writes a status but does not declare statuses: write');

  // Within the job, a duplicate `permissions:` key silently overrides, so assert one.
  const blocks = [...jobBlock.matchAll(/^    permissions:/gm)].length;
  assert.equal(blocks, 1, `expected one permissions block in claude-review, found ${blocks}`);
  assert.ok(permissions.includes('contents:'),
    'claude-review declares no permissions block (defaults apply — verify)');
  return true;
}

if (process.argv[1] && import.meta.url === new URL(process.argv[1], 'file:').href) {
  check(src);
  console.log('workflow structure OK');
}
