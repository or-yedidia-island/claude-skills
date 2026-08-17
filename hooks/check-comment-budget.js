#!/usr/bin/env node

/**
 * Comment-budget checker — deterministic over-commenting detector (user-global).
 *
 * Judges only `//` and `#` LINE comments — the "narrating my thought process"
 * spam. Block comments and XML doc comments (triple-slash) are treated as
 * intentional documentation and excluded from every count. Flags:
 *   1. Volume  — NET line-comment growth (added − removed) spiking density.
 *                Net + rewrite-pairing, so reflowing an existing comment ~0s out.
 *   2. Pattern — "narrating the change" openers + un-ticketed TODOs, plus runs of
 *                >=3 adjacent added line-comments (a "multi-line // block"). Findings
 *                carry file:line where the input provides it (diff / whole-file write).
 * It does NOT adjudicate whether one comment earns its place (that is semantic —
 * hand it to a model/Stop-hook prompt).
 *
 * Input modes, auto-detected from the hook JSON on stdin:
 *   • PostToolUse (tool_input present) — per-edit: uses old_string vs new_string
 *     (patterns only; density needs the whole change). Records the edited path
 *     for this session_id so Stop can scope to it.
 *   • Stop (no tool_input) — diffs ONLY the paths this session touched
 *     (git diff HEAD -- <paths>), so pre-existing/unrelated debt is ignored.
 *   • CLI (TTY) — `git diff --unified=0 HEAD [-- pathspec]`, full gate.
 *
 * Exit 0 = within budget, exit 2 = over budget (stderr = report → Claude fixes).
 * Tunables (env): CB_MIN_COMMENTS (6), CB_MAX_DENSITY (0.28), CB_MAX_NARRATIVE (3).
 */

const { execSync } = require('node:child_process');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');

const MIN_COMMENTS = Number(process.env.CB_MIN_COMMENTS ?? 6);
const MAX_DENSITY = Number(process.env.CB_MAX_DENSITY ?? 0.28);
const MAX_NARRATIVE = Number(process.env.CB_MAX_NARRATIVE ?? 3);

const HASH_LANGS = new Set([
  'py', 'sh', 'bash', 'zsh', 'yaml', 'yml', 'rb', 'pl', 'tf', 'toml', 'dockerfile',
]);
const C_FAMILY = new Set([
  'cs', 'ts', 'tsx', 'js', 'jsx', 'mjs', 'cjs', 'java', 'go', 'c', 'cc', 'cpp', 'h', 'hpp', 'css', 'scss',
]);

// Narrative-opener detection, split into tiers so domain prose isn't caught:
//   • PHRASE  — full narration clauses ("We'll…", "This ensures…", "Here we…").
//               These are unambiguous, so they always count.
//   • OPENER  — collision-prone openers (First/Now/Then/Next/Finally + imperative
//               verbs like Set/Get/Create/Loop/Return…). "First advertised server",
//               "Next hop", "Set the flag" are legitimate domain prose. So an opener
//               counts as narrative ONLY when it's followed by a comma or an action
//               subject ("First, we…", "Now we compute", "Set the → we/it/this/…"),
//               i.e. it actually captions a step rather than naming a thing.
const NARRATIVE_PHRASE = new RegExp(
  '^(?:Note(?: that)?|We(?:\'ll| will| now| then| also| need)?' +
    '|Here(?: we| is)|This (?:is|will|method|function|class|ensures|handles|creates|returns|loops|checks)' +
    '|For now|Let\'?s|Let us)\\b',
  'i'
);
const NARRATIVE_OPENER = new RegExp(
  '^(?:Now|First|Firstly|Then|Next|Finally|Loop (?:over|through)|Iterate|Assign|Increment|Decrement' +
    '|Set (?:the|up)|Get the|Return the|Create (?:a|the|an)|Build (?:a|the)|Call (?:the|into)' +
    '|Check (?:if|whether|that)|Start by|Add (?:a|the))\\b',
  'i'
);
// After an OPENER, a comma or one of these subjects marks it as narration.
const NARRATIVE_CONTINUATION = /^\W*(?:we|i|you|it|this|that|they|there|let'?s|then|here)\b/i;
function isNarrative(text) {
  if (!text) return false;
  if (NARRATIVE_PHRASE.test(text)) return true;
  const m = NARRATIVE_OPENER.exec(text);
  if (!m) return false;
  const rest = text.slice(m[0].length); // text after the opener token
  return /^\s*,/.test(rest) || NARRATIVE_CONTINUATION.test(rest);
}
const TODO = /\b(TODO|FIXME|HACK|XXX)\b/;
const TICKETED_TODO = /\b(TODO|FIXME)\((?:IL-\d+|[A-Z]+-\d+)\)/;

function ext(p) {
  const base = (p || '').split('/').pop() || '';
  if (base.toLowerCase() === 'dockerfile') return 'dockerfile';
  const dot = base.lastIndexOf('.');
  return dot === -1 ? '' : base.slice(dot + 1).toLowerCase();
}

const norm = (t) => (t || '').replace(/\s+/g, ' ').trim().toLowerCase();

// Classify one line. kind: 'code' | 'line-comment' | 'doc' | 'blank' | 'ignore'.
// 'doc' (block comments, XML docs) and 'ignore' (unknown langs) don't count.
function classify(rawLine, e) {
  const t = rawLine.trim();
  if (t === '') return { kind: 'blank' };
  const hash = HASH_LANGS.has(e);
  const cfam = C_FAMILY.has(e);
  if (!hash && !cfam) return { kind: 'ignore' };

  if (cfam) {
    if (t.startsWith('///')) return { kind: 'doc' };                 // XML doc — intentional
    if (t.startsWith('/*') || t.startsWith('*/') || /^\*(?!\/)/.test(t)) return { kind: 'doc' }; // block
    if (t.startsWith('//')) return { kind: 'line-comment', text: t.slice(2).trim(), raw: t };
    return { kind: 'code' };
  }
  if (t.startsWith('#!')) return { kind: 'ignore' };                 // shebang
  if (t.startsWith('#')) return { kind: 'line-comment', text: t.slice(1).trim(), raw: t };
  return { kind: 'code' };
}

// An added line is either a plain string (per-edit payloads, no file position) or
// { text, line } where `line` is its NEW-FILE line number (diff / whole-file modes).
const addedText = (a) => (typeof a === 'string' ? a : a.text);
const addedLine = (a) => (typeof a === 'string' ? null : a.line);

function analyzeFile(f) {
  const e = ext(f.path);
  let addComment = 0, addCode = 0, remComment = 0, remCode = 0;
  const narrative = [], todos = [], blocks = [];

  const removed = new Map(); // normalized removed line-comment text → count, for rewrite pairing
  for (const raw of f.removed) {
    const c = classify(addedText(raw), e);
    if (c.kind === 'line-comment') { remComment++; removed.set(norm(c.text), (removed.get(norm(c.text)) || 0) + 1); }
    else if (c.kind === 'code') remCode++;
  }

  // A "multi-line // block" is >=3 line-comments that are ADJACENT IN THE FILE.
  // We track the current run and where it started; a run is broken by code, a
  // blank/doc/reflowed line, OR — crucially — a gap in new-file line numbers.
  // Unchanged context lines are absent from `--unified=0` diffs, so without the
  // line-number gap check two separate comment groups split by untouched code
  // would look adjacent and trip a phantom block (see README).
  let run = 0, runStartLine = null, runStartText = null, prevLine = null;
  const endRun = () => { run = 0; runStartLine = null; runStartText = null; };

  for (const rawEntry of f.added) {
    const raw = addedText(rawEntry);
    const line = addedLine(rawEntry);
    const c = classify(raw, e);

    // Line-number gap ⇒ untouched lines sat between this and the previous added
    // line ⇒ the run cannot continue across the gap.
    if (line != null && prevLine != null && line !== prevLine + 1) endRun();
    if (line != null) prevLine = line;

    if (c.kind === 'code') { addCode++; endRun(); continue; }
    if (c.kind !== 'line-comment') { endRun(); continue; } // doc/blank/ignore
    addComment++;

    const k = norm(c.text);
    if (removed.get(k) > 0) { removed.set(k, removed.get(k) - 1); endRun(); continue; } // moved/reflowed

    if (run === 0) { runStartLine = line; runStartText = c.text; }
    run++;
    if (run === 3) {
      const loc = runStartLine != null ? `${f.path}:${runStartLine}` : f.path;
      blocks.push(runStartText ? `${loc}  // ${runStartText}` : loc);
    }
    if (isNarrative(c.text)) narrative.push(`${locate(f.path, line)}: ${c.text}`);
    if (TODO.test(c.raw) && !TICKETED_TODO.test(c.raw)) todos.push(`${locate(f.path, line)}: ${c.raw}`);
  }

  return {
    netComment: Math.max(0, addComment - remComment),
    netCode: Math.max(0, addCode - remCode),
    paragraphs: blocks.length, blocks, narrative, todos,
  };
}
const locate = (p, line) => (line != null ? `${p}:${line}` : p);

function analyze(files) {
  const agg = { netComment: 0, netCode: 0, paragraphs: 0, blocks: [], narrative: [], todos: [] };
  for (const f of files) {
    const r = analyzeFile(f);
    agg.netComment += r.netComment;
    agg.netCode += r.netCode;
    agg.paragraphs += r.paragraphs;
    agg.blocks.push(...r.blocks);
    agg.narrative.push(...r.narrative);
    agg.todos.push(...r.todos);
  }
  agg.density = agg.netComment + agg.netCode === 0 ? 0 : agg.netComment / (agg.netComment + agg.netCode);
  return agg;
}

// perEdit suppresses density (a single edit may hold only comments or only code;
// the ratio is only sound over the whole change → Stop/diff mode owns it).
function verdict(a, { perEdit = false } = {}) {
  const reasons = [];
  if (!perEdit && a.netComment >= MIN_COMMENTS && a.density > MAX_DENSITY) {
    reasons.push(
      `net line-comment density ${(a.density * 100).toFixed(0)}% (${a.netComment} net comment / ${a.netCode} net code) ` +
        `exceeds budget ${(MAX_DENSITY * 100).toFixed(0)}%`
    );
  }
  if (a.narrative.length >= MAX_NARRATIVE) reasons.push(`${a.narrative.length} comments narrate the change (see below)`);
  if (a.paragraphs > 0) reasons.push(`${a.paragraphs} new multi-line // comment block(s) (see below)`);
  if (a.todos.length > 0) reasons.push(`${a.todos.length} un-ticketed TODO/FIXME`);
  return reasons;
}

function report(a, reasons) {
  const lines = [
    'Over-commenting detected in your changes — comments that narrate the change or restate the code:',
    ...reasons.map((r) => `  • ${r}`),
  ];
  if (a.narrative.length) {
    lines.push('Narrating-the-change comments:');
    lines.push(...a.narrative.slice(0, 12).map((n) => `    - ${n}`));
  }
  if (a.blocks && a.blocks.length) {
    lines.push('Multi-line // comment blocks (>=3 consecutive added comment lines — split or trim to <=2):');
    lines.push(...a.blocks.slice(0, 12).map((b) => `    - ${b}`));
  }
  if (a.todos.length) {
    lines.push('Un-ticketed TODOs (use // TODO(TICKET-123): ... or drop):');
    lines.push(...a.todos.slice(0, 12).map((n) => `    - ${n}`));
  }
  lines.push('Apply the "swap test": if the comment is still true after renaming the symbol, delete it.');
  return lines.join('\n');
}

// ---- session-touched store (scopes the Stop hook to this session's edits) ---
function storePath(sessionId) {
  const safe = String(sessionId || 'default').replace(/[^\w.-]/g, '_');
  return path.join(os.tmpdir(), `cc-comment-budget-${safe}.txt`);
}
function recordTouched(sessionId, filePath) {
  if (!filePath) return;
  try {
    const sp = storePath(sessionId);
    const seen = fs.existsSync(sp) ? new Set(fs.readFileSync(sp, 'utf8').split('\n').filter(Boolean)) : new Set();
    if (!seen.has(filePath)) fs.appendFileSync(sp, filePath + '\n');
  } catch { /* best effort */ }
}
function readTouched(sessionId) {
  try {
    const sp = storePath(sessionId);
    return fs.existsSync(sp) ? [...new Set(fs.readFileSync(sp, 'utf8').split('\n').filter(Boolean))] : [];
  } catch { return []; }
}

// ---- input adapters -------------------------------------------------------
function gitShow(p) {
  try { return execSync(`git show HEAD:'${p}'`, { encoding: 'utf8', maxBuffer: 32 * 1024 * 1024, stdio: ['ignore', 'pipe', 'ignore'] }); }
  catch { return ''; } // new/untracked file — no prior version
}

function payloadToFiles(json) {
  const ti = json.tool_input || {};
  const p = ti.file_path || json.file_path || '';
  if (Array.isArray(ti.edits)) {
    return [{ path: p,
      added: ti.edits.map((e) => e.new_string ?? '').join('\n').split('\n'),
      removed: ti.edits.map((e) => e.old_string ?? '').join('\n').split('\n') }];
  }
  if (ti.new_string !== undefined) return [{ path: p, added: String(ti.new_string).split('\n'), removed: String(ti.old_string ?? '').split('\n') }];
  // Whole-file write: added lines carry real 1-based file line numbers.
  if (ti.content !== undefined) return [{ path: p, added: String(ti.content).split('\n').map((text, i) => ({ text, line: i + 1 })), removed: gitShow(p).split('\n') }];
  return null;
}

function parseDiff(diff) {
  const files = [];
  let cur = null;
  let newLine = 0; // running NEW-FILE line number, reset per hunk header
  for (const line of diff.split('\n')) {
    if (line.startsWith('+++ b/')) { cur = { path: line.slice(6), added: [], removed: [] }; files.push(cur); newLine = 0; }
    else if (line.startsWith('+++ ') || line.startsWith('--- ')) { /* header */ }
    else if (line.startsWith('@@')) { const m = /\+(\d+)/.exec(line); newLine = m ? Number(m[1]) : 0; } // @@ -a,b +c,d @@
    else if (cur && line.startsWith('+')) { cur.added.push({ text: line.slice(1), line: newLine }); newLine++; }
    else if (cur && line.startsWith('-')) cur.removed.push(line.slice(1)); // removed lines don't advance new-file numbering
  }
  return files;
}
function gitDiffFiles(pathspec) {
  const spec = pathspec.length ? ' -- ' + pathspec.map((p) => `'${p.replace(/'/g, "'\\''")}'`).join(' ') : '';
  return parseDiff(execSync(`git diff --unified=0 HEAD${spec}`, { encoding: 'utf8', maxBuffer: 64 * 1024 * 1024 }));
}

// ---- self-test ------------------------------------------------------------
function selfTest() {
  const spammy = { path: 'Bar.cs', removed: [], added: [
    '// First we validate the inputs', '// Now we compute the sum of a and b',
    '// This ensures the result is correct', 'var sum = a + b; // return the sum',
    '// Finally we return the result', 'return sum;', '// TODO clean this up later' ] };
  const clean = { path: 'Baz.cs', removed: [], added: [
    '/// <summary>Adds two numbers.</summary>', 'public int Add(int a, int b)',
    '// AutoMapper does NOT promote base maps to derived types — map each explicitly.',
    'return a + b;', '// TODO(IL-42): fold into MathUtil once shared.' ] };
  const rewrite = { path: 'Qux.cs',
    removed: ['// Now we compute the sum', '// then clamp it', '// and return'],
    added: ['// Now we compute the sum', '// then clamp it', '// and return', 'return Clamp(a + b);'] };
  const docBlock = { path: 'Doc.cs', removed: [], added: [
    '/**', ' * Adds two numbers together and returns the sum.', ' * This is a long-form doc comment.',
    ' * It spans several lines describing the contract.', ' * @param a first', ' * @param b second', ' */',
    'public int Add(int a, int b) => a + b;' ] };

  const cases = { spammy, clean, rewrite, docBlock };
  const want = { spammy: true, clean: false, rewrite: false, docBlock: false };
  let ok = true;
  const check = (name, pass) => { ok = ok && pass; console.log(`${name.padEnd(18)} ${pass ? '✓' : '✗ FAIL'}`); };

  for (const [name, f] of Object.entries(cases)) {
    const flagged = verdict(analyze([f])).length > 0;
    check(name, flagged === want[name]);
  }

  // --- regression: located `paragraphs` output (fix #1) ---------------------
  // A real 3-line block, via a diff so it carries new-file line numbers.
  const locatedDiff = [
    '--- a/Spam.cs', '+++ b/Spam.cs', '@@ -5,0 +6,3 @@',
    '+// grab the raw payload from the socket',
    '+// widen every byte into an int slot',
    '+// hand the buffer to the parser stage',
  ].join('\n');
  const locatedAgg = analyze(parseDiff(locatedDiff));
  check('located-flagged', verdict(locatedAgg).length > 0 && locatedAgg.paragraphs === 1);
  check('located-has-file:line', locatedAgg.blocks.length === 1 && locatedAgg.blocks[0].startsWith('Spam.cs:6'));

  // --- regression: phantom block from diff adjacency (fix #2) ---------------
  // Two legitimately-separate 2-line comment groups split by UNCHANGED context
  // (absent from a --unified=0 diff → different hunks). Must NOT become a block.
  const phantomDiff = [
    '--- a/BaseDcrOAuthProvider.cs', '+++ b/BaseDcrOAuthProvider.cs',
    '@@ -10,0 +11,2 @@',
    '+// Base provider for Dynamic Client Registration OAuth flows.',
    '+// Concrete providers override the per-issuer bits.',
    '@@ -30,0 +40,2 @@',
    '+// Credentials this provider requires from the caller.',
    '+// Empty when the issuer needs none.',
  ].join('\n');
  const phantomAgg = analyze(parseDiff(phantomDiff));
  check('phantom-no-block', phantomAgg.paragraphs === 0 && verdict(phantomAgg).length === 0);

  // --- regression: narrative openers vs domain prose (fix #3) ---------------
  // Sequencer/imperative openers used as domain nouns must NOT be flagged.
  const domainProse = { path: 'Prov.cs', removed: [], added: [
    { text: '// First advertised authorization server; a per-issuer selector is deferred.', line: 10 },
    { text: '// Next hop resolves lazily from the routing table.', line: 20 },
    { text: '// Set the discovery document as the source of truth.', line: 30 } ] };
  check('narrative-domain-ok', analyze([domainProse]).narrative.length === 0);
  // …but genuine narration ("First, we…", "Now we…") must still be caught.
  const realNarration = { path: 'N.cs', removed: [], added: [
    { text: '// First, we validate the inputs', line: 10 },
    { text: '// Now we compute the running total', line: 20 },
    { text: '// Then we clamp and return', line: 30 } ] };
  const narrAgg = analyze([realNarration]);
  check('narrative-real-caught', narrAgg.narrative.length === 3 && verdict(narrAgg).length > 0);

  process.exit(ok ? 0 : 1);
}

// ---- main -----------------------------------------------------------------
function run(files, perEdit) {
  const a = analyze(files);
  const reasons = verdict(a, { perEdit });
  if (reasons.length) { process.stderr.write(report(a, reasons) + '\n'); process.exit(2); }
  process.exit(0);
}

const argv = process.argv.slice(2);
if (argv.includes('--self-test')) {
  selfTest();
} else if (process.stdin.isTTY) {
  run(gitDiffFiles(argv.includes('--') ? argv.slice(argv.indexOf('--') + 1) : []), false);
} else {
  let raw = '';
  process.stdin.setEncoding('utf8');
  process.stdin.on('data', (c) => (raw += c));
  process.stdin.on('end', () => {
    let json = null;
    try { json = JSON.parse(raw); } catch { /* not JSON */ }
    try {
      const files = json ? payloadToFiles(json) : null;
      if (files) {
        recordTouched(json.session_id, files[0].path); // remember what this session edited
        run(files, true);                              // per-edit: patterns only
      } else if (json) {
        const touched = readTouched(json.session_id);  // Stop: only this session's files
        if (!touched.length) process.exit(0);
        run(gitDiffFiles(touched), false);
      } else {
        run(gitDiffFiles([]), false);
      }
    } catch { process.exit(0); } // never block on our own failure
  });
}
