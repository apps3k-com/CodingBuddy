#!/usr/bin/env node
// project-sync.mjs — keep an Epic's Project status + open/closed state in sync with
// its sub-issues. GitHub Projects has no native parent/child propagation, so this
// reconciler fills the gap. Dependency-free (Node ESM + `gh api graphql`).
//
// Rules (parent = an issue whose Issue Type is "Epic"):
//   • a sub-issue leaves "Backlog" (started or closed) → Epic Status → "In Progress"
//     (only when the Epic is still in Backlog — never downgrades In Review/etc.).
//   • ALL sub-issues closed → close the Epic + Epic Status → "Done".
//   • a sub-issue re-opens while the Epic is closed → re-open the Epic + "In Progress".
//
// Auth: uses `gh`'s token. In CI set GH_TOKEN to a GitHub App token with Issues:RW
// + Projects:RW. Locally run `gh auth refresh -s project` first.
//
// Usage:
//   node scripts/github/project-sync.mjs --all                 # reconcile every Epic (schedule)
//   node scripts/github/project-sync.mjs --issue N --repo O/R  # reconcile the Epic touched by issue N
//   node scripts/github/project-sync.mjs --all --dry-run       # log intended changes only
//
// Config (env or flag):
//   PROJECT_OWNER / --project-owner     org that owns the Project (required)
//   PROJECT_NUMBER / --project-number   Project number (required)
//   STATUS_FIELD       (default "Status")
//   STATUS_BACKLOG     (default "Backlog")
//   STATUS_IN_PROGRESS (default "In Progress")
//   STATUS_DONE        (default "Done")
//   EPIC_TYPE          (default "Epic")

import { execFileSync } from 'node:child_process';

const CFG = {
  statusField: process.env.STATUS_FIELD || 'Status',
  backlog: process.env.STATUS_BACKLOG || 'Backlog',
  inProgress: process.env.STATUS_IN_PROGRESS || 'In Progress',
  done: process.env.STATUS_DONE || 'Done',
  epicType: process.env.EPIC_TYPE || 'Epic',
};

/** Run a GraphQL operation via `gh api graphql`; returns `data`, throws on errors. */
function graphql(query, vars = {}) {
  const args = ['api', 'graphql', '-f', `query=${query}`];
  for (const [k, v] of Object.entries(vars)) {
    if (v === undefined || v === null) continue;
    args.push(typeof v === 'number' ? '-F' : '-f', `${k}=${v}`);
  }
  const out = execFileSync('gh', args, { encoding: 'utf8', timeout: 60000 });
  const json = JSON.parse(out);
  if (json.errors) throw new Error(json.errors.map((e) => e.message).join('; '));
  return json.data;
}

/** Resolve the Project node id + the Status single-select field (id + option map). */
function loadProject(owner, number) {
  const q = `query($owner:String!,$number:Int!,$field:String!){
    organization(login:$owner){ projectV2(number:$number){ id title
      field(name:$field){ ... on ProjectV2SingleSelectField { id options { id name } } } } } }`;
  const p = graphql(q, { owner, number, field: CFG.statusField }).organization?.projectV2;
  if (!p) throw new Error(`Project ${owner}/#${number} not found (token scope?).`);
  if (!p.field?.id) throw new Error(`Status field "${CFG.statusField}" not found on the project.`);
  const options = new Map(p.field.options.map((o) => [o.name.toLowerCase(), o.id]));
  return { id: p.id, statusFieldId: p.field.id, options, title: p.title };
}

const STATUS_FRAGMENT = `... on ProjectV2ItemFieldSingleSelectValue { name }`;

/** Fetch one issue with the fields the reconciler needs. */
function fetchIssue(owner, repo, number) {
  const q = `query($owner:String!,$repo:String!,$number:Int!,$field:String!){
    repository(owner:$owner,name:$repo){ issue(number:$number){
      id number state title
      issueType { name }
      parent { number issueType { name } repository { owner { login } name } }
      subIssues(first:100){ totalCount nodes {
        number state
        projectItems(first:100){ nodes { project { id } fieldValueByName(name:$field){ ${STATUS_FRAGMENT} } } } } }
      projectItems(first:100){ nodes { id project { id } fieldValueByName(name:$field){ ${STATUS_FRAGMENT} } } }
    } } }`;
  return graphql(q, { owner, repo, number, field: CFG.statusField }).repository?.issue;
}

/** The item + current Status name for `issue` within `project` (or nulls). */
function itemInProject(issue, projectId) {
  const node = issue.projectItems?.nodes?.find((n) => n.project?.id === projectId);
  return { itemId: node?.id || null, status: node?.fieldValueByName?.name || null };
}

/** Set a Project item's Status to a named option (idempotent at the caller). */
function setStatus(project, itemId, name, dry) {
  const optionId = project.options.get(name.toLowerCase());
  if (!optionId) { console.log(`    ! status option "${name}" missing on project — skipped`); return; }
  if (dry) { console.log(`    [dry-run] status → ${name}`); return; }
  const m = `mutation($p:ID!,$i:ID!,$f:ID!,$o:String!){ updateProjectV2ItemFieldValue(input:{projectId:$p,itemId:$i,fieldId:$f,value:{singleSelectOptionId:$o}}){ projectV2Item { id } } }`;
  graphql(m, { p: project.id, i: itemId, f: project.statusFieldId, o: optionId });
  console.log(`    status → ${name}`);
}

/** Close or reopen the Epic issue (idempotent at the caller). */
function setIssueState(issueId, open, dry) {
  if (dry) { console.log(`    [dry-run] ${open ? 'reopen' : 'close'} epic`); return; }
  const m = open
    ? `mutation($id:ID!){ reopenIssue(input:{issueId:$id}){ issue { number } } }`
    : `mutation($id:ID!){ closeIssue(input:{issueId:$id}){ issue { number } } }`;
  graphql(m, { id: issueId });
  console.log(`    ${open ? 'reopened' : 'closed'} epic`);
}

/** Apply the propagation rules to one Epic issue. */
function reconcileEpic(project, epic, dry) {
  const children = epic.subIssues?.nodes || [];
  const total = epic.subIssues?.totalCount ?? children.length;
  console.log(`\n#${epic.number} ${epic.title} — ${total} sub-issue(s), state ${epic.state}`);
  if (total === 0) { console.log('    no sub-issues — nothing to do'); return; }
  // Only the first 100 sub-issues are fetched. Acting on a partial set could wrongly
  // close an active Epic or miss progress, so skip when the page is incomplete.
  if (children.length < total) {
    console.log(`    only ${children.length}/${total} sub-issues fetched — skipping to avoid an incorrect decision`);
    return;
  }

  const { itemId, status } = itemInProject(epic, project.id);
  // Critical: only ever mutate an Epic that is actually an item in the TARGET project.
  // In --issue mode the touched (parent) Epic may not be in the configured project at all;
  // closing/reopening or restatusing it then would corrupt unrelated work.
  if (!itemId) {
    console.log('    epic is not an item in the target project — skipping');
    return;
  }
  const backlog = CFG.backlog.toLowerCase();
  const allClosed = children.every((c) => c.state === 'CLOSED');
  const anyStarted = children.some((c) => {
    if (c.state === 'CLOSED') return true;
    const s = c.projectItems?.nodes?.find((n) => n.project?.id === project.id)?.fieldValueByName?.name;
    return s && s.toLowerCase() !== backlog;
  });

  if (allClosed) {
    if (epic.state !== 'CLOSED') setIssueState(epic.id, false, dry);
    if (itemId && (status || '').toLowerCase() !== CFG.done.toLowerCase()) setStatus(project, itemId, CFG.done, dry);
  } else if (epic.state === 'CLOSED') {
    // A child re-opened (or was added) after the Epic was closed. State is fetched
    // fresh each run, so this is idempotent across retries; guard the mutation too.
    if (epic.state !== 'OPEN') setIssueState(epic.id, true, dry);
    if (itemId) setStatus(project, itemId, CFG.inProgress, dry);
  } else if (anyStarted && (status === null || status.toLowerCase() === backlog)) {
    if (itemId) setStatus(project, itemId, CFG.inProgress, dry);
    else console.log('    epic not in project — cannot set status');
  } else {
    console.log('    already consistent');
  }
}

/** Collect {owner,repo,number} of every Epic that is an item in the project. */
function listEpics(owner, number) {
  const epics = [];
  let after = null;
  do {
    const afterArg = after ? `, after: "${after}"` : '';
    const q = `query($owner:String!,$number:Int!){
      organization(login:$owner){ projectV2(number:$number){ items(first:100${afterArg}){
        pageInfo { hasNextPage endCursor }
        nodes { content { ... on Issue { number issueType { name } repository { owner { login } name } } } } } } } }`;
    const items = graphql(q, { owner, number }).organization?.projectV2?.items;
    for (const n of items?.nodes || []) {
      const c = n.content;
      if (c?.issueType?.name === CFG.epicType) epics.push({ owner: c.repository.owner.login, repo: c.repository.name, number: c.number });
    }
    after = items?.pageInfo?.hasNextPage ? items.pageInfo.endCursor : null;
  } while (after);
  return epics;
}

/**
 * Parse argv. Flags: --all, --dry-run, --issue N, --repo OWNER/REPO,
 * --project-owner, --project-number, -h/--help. Exits with code 2 on an unknown
 * flag. PROJECT_OWNER/PROJECT_NUMBER and DRY_RUN env vars are read later in main().
 * @param {string[]} argv process.argv.slice(2)
 * @returns {{dry:boolean,all:boolean,issue?:number,repo?:string,owner?:string,number?:number,help?:boolean}}
 */
function parseArgs(argv) {
  const o = { dry: false, all: false };
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (a === '--all') o.all = true;
    else if (a === '--dry-run') o.dry = true;
    else if (a === '--issue') o.issue = Number(argv[++i]);
    else if (a === '--repo') o.repo = argv[++i];
    else if (a === '--project-owner') o.owner = argv[++i];
    else if (a === '--project-number') o.number = Number(argv[++i]);
    else if (a === '-h' || a === '--help') o.help = true;
    else { console.error(`Unknown argument: ${a}`); process.exit(2); }
  }
  return o;
}

/**
 * Entry point. Resolves the project (env/flags), then reconciles either every Epic
 * in the project (--all) or the Epic touched by a single issue (--issue N --repo R).
 * Read-only when --dry-run / DRY_RUN=1. Requires `gh` authenticated with project scope.
 */
function main() {
  const opts = parseArgs(process.argv.slice(2));
  if (opts.help) { console.log('See header of this file for usage.'); return; }
  const owner = opts.owner || process.env.PROJECT_OWNER;
  const number = opts.number || Number(process.env.PROJECT_NUMBER);
  if (!owner || !number) { console.error('PROJECT_OWNER and PROJECT_NUMBER are required.'); process.exit(2); }
  const dry = opts.dry || process.env.DRY_RUN === '1';

  const project = loadProject(owner, number);
  console.log(`Project: ${project.title} (${owner}/#${number})${dry ? '  [DRY RUN]' : ''}`);

  /** Resolve the Epic(s) to reconcile for a single issue event. */
  const epicsForIssue = (iss) => {
    const out = [];
    if (iss.issueType?.name === CFG.epicType) out.push(iss);
    const p = iss.parent;
    if (p && p.issueType?.name === CFG.epicType) {
      const full = fetchIssue(p.repository.owner.login, p.repository.name, p.number);
      if (full) out.push(full);
    }
    return out;
  };

  let targets = [];
  if (opts.all) {
    targets = listEpics(owner, number).map((e) => fetchIssue(e.owner, e.repo, e.number)).filter(Boolean);
  } else if (opts.issue && opts.repo) {
    const [o, r] = opts.repo.split('/');
    const iss = fetchIssue(o, r, opts.issue);
    if (!iss) { console.error(`Issue ${opts.repo}#${opts.issue} not found`); process.exit(1); }
    targets = epicsForIssue(iss);
    if (targets.length === 0) { console.log('Touched issue is neither an Epic nor a child of one — nothing to do.'); return; }
  } else {
    console.error('Provide --all OR --issue N --repo OWNER/REPO.'); process.exit(2);
  }

  for (const epic of targets) reconcileEpic(project, epic, dry);
  console.log(`\nReconciled ${targets.length} epic(s)${dry ? ' (dry-run)' : ''}.`);
}

main();
