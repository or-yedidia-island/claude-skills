#!/bin/bash
# Run a shell command in a cmux surface next to the caller.
#
# Resolution order:
#   1. If a surface titled <tab-name> exists in the workspace → reuse it
#      (Ctrl+C, then re-run the command in place).
#   2. Else if the workspace has any other pane (i.e. a split the user
#      made) → split that pane DOWN, rename the new surface to
#      <tab-name>, and run there.
#   3. Else → split the caller's pane to the right and run there.
#
# Usage:
#   cmux-run-or-reuse.sh <tab-name> <command> [working-directory]
#
# Env required (auto-set inside any cmux terminal):
#   CMUX_WORKSPACE_ID, CMUX_SURFACE_ID

set -euo pipefail

if [ $# -lt 2 ]; then
    echo "Usage: $0 <tab-name> <command> [working-directory]" >&2
    exit 1
fi

TAB_NAME="$1"
CMD="$2"
WORK_DIR="${3:-}"

if [ -z "${CMUX_WORKSPACE_ID:-}" ]; then
    echo "❌ CMUX_WORKSPACE_ID is not set — this must run inside a cmux terminal." >&2
    exit 1
fi

WS="$CMUX_WORKSPACE_ID"

# Resolve caller's pane ref so we can exclude it when hunting siblings.
CALLER_PANE=$(cmux identify --no-caller=false 2>/dev/null \
    | awk -F'"' '/"caller"/ {in_caller=1} in_caller && /pane_ref/ {print $4; exit}')

# --- Step 1: look for an existing surface with this exact tab name ---
# `list-pane-surfaces --workspace` only returns the focused pane's
# surfaces, so parse `tree` for cross-pane visibility. Tree lines look
# like: `<tree chars> surface surface:N [terminal] "<title>" ...`.
EXISTING=$(cmux tree --workspace "$WS" 2>/dev/null \
    | grep -E 'surface surface:[0-9]+' \
    | awk -F'"' -v name="$TAB_NAME" '
        $2 == name {
            n = split($1, parts, " ")
            for (i = 1; i <= n; i++) {
                if (parts[i] ~ /^surface:/) { print parts[i]; exit }
            }
        }')

SURFACE=""
CREATED_NEW=0

if [ -n "$EXISTING" ]; then
    SURFACE="$EXISTING"
    echo "✓ Reusing existing tab '$TAB_NAME' ($SURFACE)"
    cmux send-key --surface "$SURFACE" ctrl+c >/dev/null 2>&1 || true
    cmux send-key --surface "$SURFACE" ctrl+u >/dev/null 2>&1 || true
else
    # --- Step 2: find a sibling pane the user made. ---
    SIBLING_PANE=$(cmux list-panes --workspace "$WS" 2>/dev/null \
        | awk -v caller="$CALLER_PANE" '
            {
                sub(/^[*[:space:]]+/, "")
                ref = $1
                if (ref ~ /^pane:/ && ref != caller) { print ref; exit }
            }')

    if [ -n "$SIBLING_PANE" ]; then
        # Split the sibling pane downward. Need a surface inside that
        # pane to target — grab its selected/first surface.
        SIBLING_SURFACE=$(cmux list-pane-surfaces --workspace "$WS" --pane "$SIBLING_PANE" 2>/dev/null \
            | awk '{
                sub(/^[*[:space:]]+/, "")
                if ($1 ~ /^surface:/) { print $1; exit }
            }')
        if [ -z "$SIBLING_SURFACE" ]; then
            echo "❌ Could not find a surface inside sibling pane $SIBLING_PANE" >&2
            exit 1
        fi
        OUT=$(cmux new-split down --workspace "$WS" --surface "$SIBLING_SURFACE")
        SURFACE=$(echo "$OUT" | awk '{print $2}')
        if [ -z "$SURFACE" ]; then
            echo "❌ Failed to split sibling pane: $OUT" >&2
            exit 1
        fi
        echo "✓ Split user's pane down: $SURFACE (from $SIBLING_SURFACE)"
        CREATED_NEW=1
    else
        # --- Step 3: no sibling at all — split right from caller. ---
        SPLIT_ARGS=(--workspace "$WS")
        if [ -n "${CMUX_SURFACE_ID:-}" ]; then
            SPLIT_ARGS+=(--surface "$CMUX_SURFACE_ID")
        fi
        OUT=$(cmux new-split right "${SPLIT_ARGS[@]}")
        SURFACE=$(echo "$OUT" | awk '{print $2}')
        if [ -z "$SURFACE" ]; then
            echo "❌ Failed to create split: $OUT" >&2
            exit 1
        fi
        echo "✓ Created split right of caller: $SURFACE"
        CREATED_NEW=1
    fi

    cmux rename-tab --surface "$SURFACE" "$TAB_NAME" >/dev/null
    echo "✓ Renamed tab to: $TAB_NAME"
fi

if [ -n "$WORK_DIR" ]; then
    FULL_CMD="cd \"$WORK_DIR\" && $CMD"
else
    FULL_CMD="$CMD"
fi

cmux send --surface "$SURFACE" "$FULL_CMD"
cmux send-key --surface "$SURFACE" enter
echo "✓ Running: $FULL_CMD"
