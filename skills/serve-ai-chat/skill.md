---
description: Run `yarn run ai-chat:serve:dev` in a cmux split next to the current tab. If a tab named "ai-chat:serve:dev" already exists in this workspace, reuse it (stop any running server and re-run) instead of spawning a new tab. Use when the user asks to serve ai-chat, start the ai-chat dev server, or run `ai-chat:serve:dev`.
---

# What this does

Opens (or reuses) a cmux terminal split in the current workspace that
runs `yarn run ai-chat:serve:dev` in the current working directory. If a
sibling surface titled `ai-chat:serve:dev` already exists in the same
workspace, the skill reuses it — sending `Ctrl+C` first to stop the
running server, then re-running the command — instead of creating
another tab.

# How to invoke

Run the helper script from the working directory you want the server to
run in:

```bash
~/.claude/skills/serve-ai-chat/cmux-run-or-reuse.sh "ai-chat:serve:dev" "yarn run ai-chat:serve:dev" "$(pwd)"
```

- Arg 1: tab name (must be exactly `ai-chat:serve:dev` so reuse matching works)
- Arg 2: command to run
- Arg 3: working directory — pass the current `pwd` so the server runs
  against the right worktree

# Notes

- This must be run inside a cmux terminal (the script relies on
  `CMUX_WORKSPACE_ID` / `CMUX_SURFACE_ID`).
- The split opens to the right of the caller surface.
- Reuse is scoped to the current workspace, so parallel worktrees each
  get their own `ai-chat:serve:dev` tab.
