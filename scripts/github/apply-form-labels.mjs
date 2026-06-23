#!/usr/bin/env node
// Parse a GitHub issue-form body for the Module and Product selections and print the labels
// to apply, one per line: `module:<value>` / `product:<value>`. Placeholders / empty answers
// ("n/a", "_No response_", "none") are skipped. The workflow reconciles these onto the issue.
//
// Env: ISSUE_BODY (the rendered issue body).
const body = process.env.ISSUE_BODY || '';

/** Value rendered under an issue-form section heading `### <label>`. */
function field(label) {
  const re = new RegExp(`(?:^|\\n)###\\s+${label}\\s*\\n+([^\\n]+)`, 'i');
  const m = body.match(re);
  return m ? m[1].trim() : '';
}

const SKIP = /^(n\/a|_no response_|none|—|-)$/i;
const out = [];
for (const [label, prefix] of [['Module', 'module'], ['Product', 'product']]) {
  const v = field(label);
  if (v && !SKIP.test(v)) out.push(`${prefix}:${v}`);
}
console.log(out.join('\n'));
