---
description: Run `yarn build:dev` for the Island extension in a cmux split next to the current tab. If a tab named "build:dev" already exists in this workspace, reuse it (stop any running build and re-run) instead of spawning a new tab. Use when the user asks to build the extension, rebuild it, or run `build:dev`.
---

# What this does

Opens (or reuses) a cmux terminal split in the current workspace that runs
`yarn build:dev` in the current working directory. If a sibling surface
titled `build:dev` already exists in the same workspace, the skill reuses
it — sending `Ctrl+C` first and then re-running the command — instead of
creating another tab.

# How to invoke

Run the helper script from the working directory you want the build to
run in:

```bash
~/.claude/skills/build-extension/cmux-run-or-reuse.sh "build:dev" "yarn build:dev" "$(pwd)"
```

- Arg 1: tab name (must be exactly `build:dev` so reuse matching works)
- Arg 2: command to run
- Arg 3: working directory — pass the current `pwd` so the build targets
  the right worktree

# Notes

- This must be run inside a cmux terminal (the script relies on
  `CMUX_WORKSPACE_ID` / `CMUX_SURFACE_ID`).
- The split opens to the right of the caller surface.
- Reuse is scoped to the current workspace, so parallel worktrees each
  get their own `build:dev` tab.
