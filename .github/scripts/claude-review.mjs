import {execFileSync} from 'node:child_process';
import {readFileSync, appendFileSync} from 'node:fs';
import {pathToFileURL} from 'node:url';

export const contextName = 'Claude review';
export function requested(event, name) {
  return name === 'pull_request'
    ? event.action === 'ready_for_review'
    : name === 'issue_comment' && event.action === 'created' &&
      Boolean(event.issue?.pull_request) && event.comment?.body === '/review';
}
export function eligible(pr, repo) {
  return pr.state === 'open' && !pr.draft && pr.head.repo?.full_name === repo &&
    pr.user.login !== 'dependabot[bot]';
}
export function trusted(permission) {
  return ['write', 'maintain', 'admin'].includes(permission);
}
export function completed(statuses) {
  // The first matching status is the newest. A failed retry must not inherit an old success.
  return statuses.find(s => s.context === contextName)?.state === 'success';
}
export async function prepare({event, name, repo, api}) {
  if (!requested(event, name)) return {run: false};
  const number = event.pull_request?.number ?? event.issue.number;
  if (name === 'issue_comment') {
    const permission = await api(`repos/${repo}/collaborators/${encodeURIComponent(event.comment.user.login)}/permission`);
    if (!trusted(permission.permission)) return {run: false};
  }
  const pr = await api(`repos/${repo}/pulls/${number}`);
  if (!eligible(pr, repo)) return {run: false};
  // A ready event for an old head must not spend review tokens on its replacement.
  if (name === 'pull_request' && event.pull_request.head.sha !== pr.head.sha) return {run: false};
  const statuses = await api(`repos/${repo}/commits/${pr.head.sha}/statuses?per_page=100`, true);
  if (completed(statuses)) return {run: false};
  const files = await api(`repos/${repo}/pulls/${number}/files?per_page=100`, true);
  if (files.some(f => f.filename === '.github/workflows/claude-code-review.yml' ||
    f.filename.startsWith('.github/scripts/claude-review'))) return {run: false};
  return {run: true, number, head: pr.head.sha, base: pr.base.sha};
}
export function completion(pr, head, outcome, conclusion) {
  const fresh = pr.state === 'open' && !pr.draft && pr.head.sha === head;
  const succeeded = outcome === 'success' && conclusion === 'success';
  // **Every non-success outcome carries a comment, not just a status description.**
  // A status description is only visible where statuses are shown, and the stale case is
  // the one that needs a reader: the review completed, so nothing failed, so no failure
  // notice fires; and no status is written, because the head moved. Without a comment the
  // review reaches nobody and the PR looks identical to one never reviewed.
  return {
    state: fresh && succeeded ? 'success' : 'error',
    description: !fresh ? 'Head changed; request /review after local review' :
      succeeded ? 'Review completed; findings still require disposition' : 'Review failed; retry required',
    comment: !fresh
      ? `A Claude review ran against \`${head}\` but was discarded: the PR head has since moved to \`${pr.head.sha}\`.\n\n` +
        'No status was recorded, because a status belongs to the commit it reviewed and this one is no longer the head. ' +
        'That is why this comment exists — otherwise the run would be indistinguishable from a PR that has not been reviewed.\n\n' +
        'Request a review of the current head with `/review` once local review has passed.'
      : succeeded ? null
      : 'The Claude review did not complete (action or model failure), so no completed review is recorded for this head. ' +
        'Re-request with `/review`.'
  };
}

/// The comment posted when the preflight declines to run a review.
///
/// A skipped review records no status — correctly, since nothing was reviewed — so without
/// a comment a declined run is invisible. The reason is included because "skipped" alone
/// does not tell a reader what to do about it.
export function skippedNotice(pr, reason) {
  return {comment: `The Claude review was skipped: ${reason}. No review was performed and no status was recorded.`};
}
function api(path, paginate = false, body) {
  const args = ['api', path];
  if (paginate) args.push('--paginate', '--slurp');
  if (body) args.push('--method', 'POST', '--input', '-');
  const result = JSON.parse(execFileSync('gh', args, {encoding: 'utf8', input: body && JSON.stringify(body)}));
  return paginate ? result.flat() : result;
}
function output(values) {
  for (const [key, value] of Object.entries(values)) appendFileSync(process.env.GITHUB_OUTPUT, `${key}=${value}\n`);
}
async function main() {
  const repo = process.env.GITHUB_REPOSITORY;
  const url = `${process.env.GITHUB_SERVER_URL}/${repo}/actions/runs/${process.env.GITHUB_RUN_ID}`;
  if (process.argv[2] === 'prepare') {
    const result = await prepare({event: JSON.parse(readFileSync(process.env.GITHUB_EVENT_PATH)),
      name: process.env.GITHUB_EVENT_NAME, repo, api});
    output(result);
    if (result.run) api(`repos/${repo}/statuses/${result.head}`, false,
      {state: 'pending', context: contextName, description: 'Reviewing this head', target_url: url});
  } else if (process.argv[2] === 'finish') {
    const pr = api(`repos/${repo}/pulls/${process.env.REVIEW_NUMBER}`);
    const statuses = api(`repos/${repo}/commits/${process.env.REVIEW_HEAD}/statuses?per_page=100`, true);
    // A canceled request must not overwrite the record claimed by its successor.
    if (statuses.find(s => s.context === contextName)?.target_url !== url) return;
    const record = completion(pr, process.env.REVIEW_HEAD, process.env.REVIEW_OUTCOME, process.env.MODEL_CONCLUSION);
    api(`repos/${repo}/statuses/${process.env.REVIEW_HEAD}`, false,
      {...record, context: contextName, target_url: url});
    // The comment is what makes a non-success visible; the status alone reaches only
    // whoever is looking at the checks list.
    if (record.comment) api(`repos/${repo}/issues/${process.env.REVIEW_NUMBER}/comments`, false, {body: record.comment});
  } else throw new Error('Expected prepare or finish');
}
if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) await main();
