#!/usr/bin/env node
// Generate the Module/Product dropdown options inside .github/ISSUE_TEMPLATE/*.yml and ensure
// the matching module:* / product:* labels exist. The option lists are delimited by marker
// comments, so only the generated block is rewritten — the rest of each form is untouched.
//
// Sources of truth (no duplication):
//   - Modules  → .github/modules.yaml (per repo; PR-reviewed, versioned, CODEOWNERS-gateable;
//                a push to it re-runs this workflow).
//   - Products → PRODUCTS org variable (org-wide taxonomy for cross-repo boards).
// The dropdown enforces the vocabulary at input; the labels keep (cross-repo) Project
// filtering working. See docs/github-projects.md.
//
// Env: REPO=owner/name, PRODUCTS="x,y" (org variable), GH_TOKEN.
import { readFileSync, writeFileSync, readdirSync } from 'node:fs';
import { execFileSync } from 'node:child_process';

const DIR = '.github/ISSUE_TEMPLATE';
const MODULES_FILE = '.github/modules.yaml';
const REPO = process.env.REPO;

/** Read the simple `modules:` list from .github/modules.yaml (dependency-free parser).
 *  A MISSING file means "no modules configured yet" (return []); any other read error is
 *  fatal — silently emptying the dropdown on a transient/permission error would corrupt the
 *  taxonomy. */
function readModules(path) {
  let text;
  try {
    text = readFileSync(path, 'utf8');
  } catch (err) {
    if (err && err.code === 'ENOENT') return [];
    throw err;
  }
  const out = [];
  let inBlock = false;
  for (const raw of text.split('\n')) {
    const line = raw.replace(/#.*$/, ''); // strip comments
    if (/^modules\s*:/.test(line)) {
      inBlock = true;
      continue;
    }
    if (!inBlock) continue;
    const m = line.match(/^\s*-\s+(.+?)\s*$/);
    if (m) {
      out.push(m[1].replace(/^["']|["']$/g, '').trim());
    } else if (line.trim() !== '' && /^\S/.test(line)) {
      break; // a new top-level key ends the modules block
    }
  }
  return [...new Set(out.filter(Boolean))];
}

const parseCsv = (s) => [...new Set((s || '').split(',').map((x) => x.trim()).filter(Boolean))];
const modules = readModules(MODULES_FILE);
const products = parseCsv(process.env.PRODUCTS);

/** Render the indented option lines for a dropdown (falls back to a single "n/a" placeholder). */
function optionBlock(values) {
  const opts = values.length ? values : ['n/a'];
  return opts.map((v) => `        - ${JSON.stringify(v)}`).join('\n');
}

/** Replace the lines between the `# >>> <key>-options` / `# <<< <key>-options` markers.
 *  Returns { out, found } so the caller can flag a form that is missing its marker block. */
function replaceMarked(text, key, values) {
  const re = new RegExp(`( *# >>> ${key}-options[^\\n]*\\n)[\\s\\S]*?( *# <<< ${key}-options)`, 'g');
  let found = false;
  const out = text.replace(re, (_m, start, end) => {
    found = true;
    return `${start}${optionBlock(values)}\n${end}`;
  });
  return { out, found };
}

const changed = [];
const missingMarkers = [];
for (const f of readdirSync(DIR).filter((f) => f.endsWith('.yml') && f !== 'config.yml')) {
  const p = `${DIR}/${f}`;
  const orig = readFileSync(p, 'utf8');
  const mod = replaceMarked(orig, 'module', modules);
  const prod = replaceMarked(mod.out, 'product', products);
  if (!mod.found) missingMarkers.push(`${f} (module)`);
  if (!prod.found) missingMarkers.push(`${f} (product)`);
  if (prod.out !== orig) {
    writeFileSync(p, prod.out);
    changed.push(f);
  }
}
console.log(`Modules: [${modules.join(', ')}] · Products: [${products.join(', ')}]`);
console.log(`Dropdown options updated in: ${changed.join(', ') || '(no change)'}`);
if (missingMarkers.length) {
  // A form without the marker block would silently never receive options — fail loudly.
  console.error(`ERROR: missing option marker block in: ${missingMarkers.join(', ')}`);
  process.exitCode = 1;
}

/** Ensure a label exists for every value (idempotent via --force). Requires gh + issues:write.
 *  Returns the number of failures so the caller can surface them (never silently swallowed). */
function ensureLabels(prefix, values, color) {
  let failed = 0;
  for (const v of values) {
    const name = `${prefix}:${v}`;
    try {
      execFileSync('gh', ['label', 'create', name, '--repo', REPO, '--color', color,
        '--description', `${prefix}: ${v}`, '--force'], { stdio: 'ignore', timeout: 30000 });
    } catch {
      console.error(`ERROR: could not ensure label ${name}`);
      failed += 1;
    }
  }
  return failed;
}
if (REPO) {
  const failed = ensureLabels('module', modules, '8250DF') // module:* hue (prior convention)
    + ensureLabels('product', products, '1D76DB'); // product:* hue
  if (failed > 0) process.exitCode = 1; // surface label-sync failures (CI must not go green)
}
