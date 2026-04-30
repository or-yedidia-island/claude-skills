#!/bin/bash

# Create a new cmux tab with Claude and send it a prompt
#
# Usage: ./cmux-claude-tab.sh "Tab Name" "Prompt to send to Claude" [/path/to/dir]
#
# Example: ./cmux-claude-tab.sh "Investigation" "Read @file.md and investigate"
# Example: ./cmux-claude-tab.sh "Fix Tests" "Fix failing tests" /Users/me/work/libs

if [ $# -lt 2 ]; then
    echo "Usage: $0 <tab-name> <prompt> [working-directory]"
    echo ""
    echo "Example:"
    echo "  $0 \"Investigation\" \"Read @pr-fix-investigation-needed.md\""
    echo "  $0 \"Fix Tests\" \"Fix failing tests\" /path/to/dir"
    exit 1
fi

TAB_NAME="$1"
PROMPT="$2"
WORK_DIR="$3"

echo "Creating tab: $TAB_NAME"

# Create new terminal surface
SURFACE_ID=$(cmux new-surface --type terminal | awk '{print $2}')

if [ -z "$SURFACE_ID" ]; then
    echo "❌ Failed to create surface"
    exit 1
fi

echo "✓ Created surface: $SURFACE_ID"

# Rename the tab
cmux rename-tab --surface "$SURFACE_ID" "$TAB_NAME"
echo "✓ Renamed tab to: $TAB_NAME"

# Optionally cd to working directory, then start Claude
if [ -n "$WORK_DIR" ]; then
    cmux send --surface "$SURFACE_ID" "cd \"$WORK_DIR\" && claude \"$PROMPT\""
else
    cmux send --surface "$SURFACE_ID" "claude \"$PROMPT\""
fi
cmux send-key --surface "$SURFACE_ID" "Enter"
echo "✓ Started Claude with prompt: ${PROMPT:0:50}..."

echo ""
echo "✅ Tab '$TAB_NAME' ready with Claude"
