# Comment-budget hook — what it is & how to tell if it worked

**Installed:** 2026-08-13 · **Owner:** or.yedidia@island.io · **Scope:** user-global (`~/.claude/`), applies to every repo.

This doc is written for a **future Claude Code session** to (a) understand what was
installed and why, and (b) evaluate whether it actually reduced over-commenting after
some time has passed. If you're that session: read §1–3 for context, then run §5.

---

## 1. The problem it targets

Claude Code was writing excessive comments — narrating its own thought process in the
code ("First we…", "Now we…", "This method…"), spamming diffs with useless/stale
comments. Instruction text alone (a `.claude/rules/comments-style.md` rule) did **not**
stop it: CLAUDE.md/rules are *context, not enforcement*, so the model under-follows them.
Origin thread: Island Slack `#` channel `C0A7LK9CFL2` (2026-08-13), "Claude code is
commenting paragraphs like crazy".

Conclusion reached: enforce with **hooks**, not more instructions — and do it in a way
that does **not** slow the code-writing loop.

## 2. What was installed

| File | Role |
|---|---|
| `~/.claude/hooks/check-comment-budget.js` | The checker (Node, no deps). |
| `~/.claude/settings.json` → `hooks.PostToolUse` (`Edit\|Write\|MultiEdit`) | Per-edit, immediate pattern feedback. |
| `~/.claude/settings.json` → `hooks.Stop` | End-of-turn density gate over the whole change. |

Nothing was committed to any project repo — this is deliberately a personal/global setup.

## 3. How it works (design decisions that matter for evaluation)

- **Only `//` and `#` LINE comments are judged.** Block comments (`/*…*/`, `/**…*/`) and
  `///` XML docs are treated as intentional documentation and **excluded**. Rationale:
  the spam pattern is line-comment narration; excluding doc blocks kills false positives
  on headers/JSDoc/XML docs.
- **Net counting + rewrite pairing.** Volume = added − removed line-comments; a reworded
  or reflowed existing comment nets ~0 and is not counted as new commenting.
- **Two input modes, auto-detected from the hook JSON on stdin:**
  - *PostToolUse* (has `tool_input`): per-edit, uses `old_string` vs `new_string`. Runs
    **patterns only** (narration openers, un-ticketed TODO, 3+ line `//` blocks). Density
    is suppressed here — a single edit may hold only comments or only code, so the ratio
    is meaningless per-edit. Also records the edited path under the `session_id`.
  - *Stop* (no `tool_input`): diffs **only the files this session touched**
    (`git diff HEAD -- <recorded paths>`), then applies the full gate incl. density.
    If the session touched nothing, it exits 0 — so it never nags about pre-existing or
    unrelated comment debt.
- **Speed:** deterministic, <50 ms, runs *after* a write (PostToolUse) or at end of turn
  (Stop). It never sits inside the generation loop.
- **Exit codes:** 0 = within budget; 2 = over budget → stderr report is fed back to Claude
  to fix. Any internal error → exit 0 (never blocks work on its own failure).

**Signals it emits:** net line-comment density over budget; N comments that narrate the
change (each shown as `file:line: text`); N new multi-line `//` blocks (each shown as
`file:line  // <first line of the block>`); N un-ticketed TODO/FIXME.

### 3a. Field-feedback fixes (2026-08-17)

From a real session where the density/block check proved hard to act on and mis-fired:

1. **Multi-line `//` blocks now carry `file:line`.** Previously the Stop message said only
   "N new multi-line // comment block(s)" with no location, forcing the user to re-derive
   the hook's logic against the diff by hand. Block findings now report the file and the
   starting line (from the diff's hunk headers / whole-file write offsets), like the other
   findings.
2. **The consecutive-comment run resets across line-number gaps.** The run counter was built
   from the diff's *added-line stream*, which only reset on added code/blank lines. Unchanged
   context lines are absent from a `--unified=0` diff, so two legitimately-separate 2-line
   comment groups split by untouched code could look adjacent and trip a **phantom** 4-line
   block. The counter now also resets on any gap in new-file line numbers, so untouched code
   between two comment groups keeps them separate.
3. **Narrative openers are tiered so domain prose isn't caught.** Full narration clauses
   ("We'll…", "This ensures…", "Here we…") always count. Collision-prone openers
   (`First/Now/Then/Next/Finally` + imperative verbs like `Set/Get/Create/Loop/Return…`)
   count **only** when followed by a comma or an action subject ("First, we…", "Now we
   compute…"). Domain prose like `// First advertised authorization server` or `// Next hop`
   is no longer flagged, while real step-by-step narration still is.

## 4. Tunables (env vars, set inline in the settings command)

| Var | Default | Meaning |
|---|---|---|
| `CB_MIN_COMMENTS` | 6 | Floor before density can fire (ignores tiny diffs). |
| `CB_MAX_DENSITY` | 0.28 | Max net line-comment / (comment+code) before flagging. |
| `CB_MAX_NARRATIVE` | 3 | Narration-opener hits before flagging. |

Example: `"command": "CB_MAX_DENSITY=0.33 CB_MAX_NARRATIVE=5 node ~/.claude/hooks/check-comment-budget.js"`

## 5. How to evaluate whether it worked (future session: run this)

### 5a. Is it still wired and functional?
```bash
node ~/.claude/hooks/check-comment-budget.js --self-test   # expect all ✓, exit 0
node --check ~/.claude/hooks/check-comment-budget.js        # syntax OK
node -e "const s=require(require('os').homedir()+'/.claude/settings.json'); console.log(Object.keys(s.hooks))"
# expect: PreToolUse, PostToolUse, Stop  — and both budget entries point at this script
```
If the hooks are missing, someone removed them → effectiveness question is moot; report that.

### 5b. Did over-commenting actually go down? (directional proxy)
Effectiveness is confounded (model updates, task mix, other habits), so treat this as
**directional, not proof.** Pick a repo the user works in heavily, then compare the
density of *added* line-comments in commits **before vs after** the install date
(2026-08-13). Run inside that repo:

```bash
INSTALL=2026-08-13
# added // line-comments vs added code lines, for a commit window
measure () { # $1=since $2=until
  local diff; diff=$(git log --since="$1" --until="$2" -p --no-merges -- '*.cs' '*.ts' '*.js' 2>/dev/null)
  local com code
  com=$(printf '%s\n' "$diff" | grep -cE '^\+[[:space:]]*//')
  code=$(printf '%s\n' "$diff" | grep -E '^\+' | grep -vE '^\+\+\+|^\+[[:space:]]*//|^\+[[:space:]]*/?\*|^\+[[:space:]]*$' | wc -l)
  awk -v c="$com" -v k="$code" 'BEGIN{ if(c+k==0){print "no data"} else printf "line-comment density: %.1f%% (%d comment / %d code added)\n", 100*c/(c+k), c, k }'
}
echo "BEFORE:"; measure 2026-05-13 $INSTALL
echo "AFTER: "; measure $INSTALL 2026-11-13   # adjust the end date to 'now'
```
Interpretation: a meaningful **drop in AFTER density** (and fewer `// First/Now/This…`
narration lines) is the win. If AFTER ≈ BEFORE or higher, the hook isn't changing behavior
— check whether it's actually firing (§5c) before concluding it failed.

### 5c. Is it firing in practice?
- Session-scope stores live at `${TMPDIR}/cc-comment-budget-<session_id>.txt` — presence of
  recent files means PostToolUse ran and recorded edits.
- Ask the user: has it been surfacing "Over-commenting detected…" messages, and did Claude
  then trim comments in the same turn? Too-frequent nags → loosen thresholds (§4);
  never fires → verify `node` is on PATH for hooks and the matcher still matches.

### 5d. Quick qualitative check
Grep a few recently-touched files for the narration tells and eyeball whether they're gone:
```bash
git diff HEAD~20..HEAD -- '*.cs' | grep -E '^\+[[:space:]]*//[[:space:]]*(First|Now|Then|Finally|This (is|method)|We (will|now))'
```
Few/none since install = working as intended.

## 6. Known limitations (so a future session doesn't misread results)

- **Heuristic, not semantic.** It measures volume + loud patterns; it cannot tell a
  genuinely useful comment from filler. A couple of legit "gotcha" comments may still trip
  the narration regex (advisory) — that's expected, not a bug. The 2026-08-17 tiering (§3a)
  narrows this, but it can't be eliminated deterministically.
- **Per-edit block/line locations are approximate.** In diff and whole-file-write modes
  block findings carry true new-file line numbers; for partial `Edit`/`MultiEdit` payloads
  the absolute file position isn't known, so those findings show the file path without a
  line (the Stop pass over the real diff always has the line).
- **New/untracked files** are checked at write time (PostToolUse) but not by the Stop
  density pass (`git diff HEAD` doesn't see untracked files until `git add`).
- **Stop scope depends on `session_id`** in the hook payload; if a Claude Code version stops
  sending it, Stop falls back to a shared store and scoping degrades.
- **Directional metric only** — do not treat §5b as a controlled measurement.
