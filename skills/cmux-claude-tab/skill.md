---
description: Create a new cmux tab with Claude and send it a prompt. Use when the user wants to spawn a parallel Claude session in a new terminal tab, run Claude in a separate tab, or delegate work to another Claude instance.
---

You are a helper that creates new cmux terminal tabs with Claude sessions.

# What This Does

Creates a new terminal tab in cmux, renames it, and launches Claude with a specified prompt. This is useful for parallelizing work across multiple Claude instances.

# Usage

Run the script from its skill directory:

```bash
~/.claude/skills/cmux-claude-tab/cmux-claude-tab.sh "<Tab Name>" "<Prompt to send to Claude>" [/path/to/working-directory]
```

# Examples

```bash
# Spawn a Claude to investigate something
./cmux-claude-tab.sh "Investigation" "Read @pr-fix-investigation-needed.md and investigate"

# Spawn a Claude to fix tests
./cmux-claude-tab.sh "Fix Tests" "Run the failing tests in libs/utils and fix them"

# Spawn a Claude for a review
./cmux-claude-tab.sh "Review" "Review the changes on this branch for security issues"

# Spawn a Claude in a specific directory
./cmux-claude-tab.sh "Cloud Work" "Fix the auth module" /Users/me/work/cloud
```

# Parameters

1. **Tab Name** (required) - The display name for the new terminal tab
2. **Prompt** (required) - The prompt to send to Claude in the new tab
3. **Working Directory** (optional) - Path to cd into before launching Claude

# Requirements

- `cmux` must be available in PATH (the terminal multiplexer)
- The script must be run from a directory where Claude can be launched

# Workflow

When the user asks to spawn parallel Claude sessions or delegate tasks to other tabs:

1. Determine an appropriate tab name based on the task
2. Craft a clear, self-contained prompt (the new Claude instance has no context from this conversation)
3. Run the script with both arguments
4. Report back that the tab was created

# Important Notes

- The new Claude instance starts fresh with NO context from the current conversation
- Make prompts self-contained: include file paths, context, and clear instructions
- Use this for truly parallel/independent work — not for sequential tasks
- The script will fail if cmux is not running
