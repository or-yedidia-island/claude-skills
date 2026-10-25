---
description: Send a message to ANOTHER Claude Code session running in a cmux tab — resolves the target automatically from cmux (tab/workspace titles → the Claude session in it) and delivers via native SendMessage. Use whenever the user says "send/tell/message/update/relay/write to the <X> tab|session", "tell the orchestrator/lead", "did you relay to <X>", "draft a message to the <X> tab", or whenever you are about to hand off to, report to, or notify a peer Claude session. Use it instead of guessing session names from ListAgents or poking cmux --help. Not for spawning a new tab (that's cmux-claude-tab).
---

You deliver a message from this Claude session to a peer Claude session that lives in a cmux tab.
Or names targets loosely ("the gcp session tab", "appmodule", "the orchestrator"); resolve them
from cmux, never by guessing a session name.

# 1. Resolve the target

```bash
~/.claude/skills/cmux-message-session/resolve.sh "<what Or called it>"
```

Returns JSON `{verdict, self, candidates[]}`. Each candidate has `workspace_title`, `tab_title`,
`tab_index`, `session_name`, `status` (`idle` / `busy` / `waiting` = has a dialog open), `cwd`,
`socket`, `peer`, `score`. Your own tab is never a candidate.

How it ranks: tabs in your own workspace first, then your workspace group, then everything else.
It matches tab title, session name, workspace title, cwd and group, ignoring emoji, case and hyphens.
"orchestrator" / "lead" / "first one" means the first tab of your workspace, unless a tab is
titled with that word.

- `unique` → use `candidates[0]`.
- `ambiguous` → **AskUserQuestion** with the top candidates as options (label = tab title,
  description = workspace · session · status), best first. After Or picks, **rename that tab** so
  the same words resolve next time:
  ```bash
  cmux rename-tab --workspace <workspace_ref> --surface <surface_ref> "<Alias> · <old title without ✳/◑ prefix>"
  ```
  `<Alias>` is the word Or used, capitalized (e.g. `Orchestrator · Shipyard build kickoff`).
- `none` → run `resolve.sh` with no query to list every Claude tab, then ask Or with the likeliest
  options. Don't guess.

# 2. Write the message (handoff style)

- **Short (≤ ~5 lines, no data/decisions to preserve):** send it inline.
- **Anything longer:** write a handoff doc to your scratchpad dir (else `$TMPDIR/claude-handoffs/<short-slug>.md`), with a summary of
  what the peer needs, references by path/URL instead of copying artifacts, a "suggested skills"
  section, and secrets redacted. The message then points to it.

The first line must make sense on its own. Start it with who it's from:

```
From the <your tab title> tab (<your session_name>): <gist>. Read <path> and <what to do>. Reply only if <condition>.
```

If the target's `status` is `waiting` or it asked Or a question, add "(not an answer to your
pending question)".

# 3. Deliver

**Primary: native SendMessage** (when `peer` is true):
`SendMessage(to: "uds:<socket>", summary: "<5-8 words>", message: "<the message>")`.
The socket path is tied to the live process, so it never hits a stale name. (`session_name` also
works, but names change when a session restarts.)

**Fallback (`peer` false, or SendMessage fails):** type it into the tab without stealing focus:
```bash
~/.claude/skills/cmux-message-session/send-fallback.sh <workspace_ref> <surface_ref> "<one-line message>"
```
Exit codes: 0 = delivered. 3 = the target has a dialog open or its input box has text, so nothing
was sent; tell Or. 2 = sent but not confirmed; check with `cmux capture-pane`. In the fallback, keep
the message to one line and put the rest in the handoff doc.

Then tell Or in one line: who it went to (`tab title · session_name`) and the channel. If the
target was `waiting`, say the message is queued until its dialog is answered.

# Who may trigger a send

- **Or asked** ("send it to…", "tell the … tab") → resolve and send. Ask only when the target is ambiguous.
- **You decided on your own** (handoff, report, FYI) → first ask **AskUserQuestion** with the
  resolved target and the draft: *Send* (recommended) / *Edit* / *Don't send*.

# cmux cheat sheet (don't re-read --help)

- Never use `focus-pane`, `surface.send_text` or plain `cmux send` without `--surface`. They act on the focused tab and steal focus.
- `cmux tree --all [--json]`: every window/workspace/pane/surface with titles and tty.
- `cmux workspace-group list --json`: groups and their member workspaces.
- `cmux capture-pane --workspace <ws> --surface <surf> --lines N`: read a tab's screen.
- `cmux send-panel --panel <surf> --workspace <ws> -- "<text>"` + `cmux send-key-panel --panel <surf> --workspace <ws> Enter`: focus-free typing.
- `cmux rename-tab --workspace <ws> --surface <surf> "<title>"`: rename a tab.
