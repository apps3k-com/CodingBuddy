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

/** Read the simple `modules:` list from .github/modules.yaml (dependency-free parser). */
function readModules(path) {
  let text;
  try {
    text = readFileSync(path, 'utf8');
  } catch {
    return [];
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

/** Replace the lines between the `# >>> <key>-options` / `# <<< <key>-options` markers. */
function replaceMarked(text, key, values) {
  const re = new RegExp(`( *# >>> ${key}-options[^\\n]*\\n)[\\s\\S]*?( *# <<< ${key}-options)`, 'g');
  return text.replace(re, (_m, start, end) => `${start}${optionBlock(values)}\n${end}`);
}

const changed = [];
for (const f of readdirSync(DIR).filter((f) => f.endsWith('.yml') && f !== 'config.yml')) {
  const p = `${DIR}/${f}`;
  const orig = readFileSync(p, 'utf8');
  let out = replaceMarked(orig, 'module', modules);
  out = replaceMarked(out, 'product', products);
  if (out !== orig) {
    writeFileSync(p, out);
    changed.push(f);
  }
}
console.log(`Modules: [${modules.join(', ')}] · Products: [${products.join(', ')}]`);
console.log(`Dropdown options updated in: ${changed.join(', ') || '(no change)'}`);

/** Ensure a label exists for every value (idempotent via --force). Requires gh + issues:write. */
function ensureLabels(prefix, values, color) {
  for (const v of values) {
    const name = `${prefix}:${v}`;
    try {
      execFileSync('gh', ['label', 'create', name, '--repo', REPO, '--color', color,
        '--description', `${prefix}: ${v}`, '--force'], { stdio: 'ignore' });
    } catch {
      console.error(`warn: could not ensure label ${name}`);
    }
  }
}
if (REPO) {
  ensureLabels('module', modules, '8250DF'); // module:* hue (matches the prior convention)
  ensureLabels('product', products, '1D76DB'); // product:* hue
}
