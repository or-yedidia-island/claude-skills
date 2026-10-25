#!/bin/bash

# Type a one-line message into a Claude tab without stealing focus (only when SendMessage can't reach it).
# Usage: ./send-fallback.sh <workspace-ref> <surface-ref> "<message>"

if [ $# -lt 3 ]; then
    echo "Usage: $0 <workspace-ref> <surface-ref> <message>"
    exit 1
fi

WS="$1"
SURF="$2"
# A newline would submit early, so flatten to one line
MSG=$(printf '%s' "$3" | tr '\n' ' ')

screen() { CMUX_QUIET=1 cmux capture-pane --workspace "$WS" --surface "$SURF" --lines "${1:-15}" 2>/dev/null; }

SCREEN=$(screen 15)
[ -n "$SCREEN" ] || { echo "❌ Can't read $SURF in $WS"; exit 1; }

if echo "$SCREEN" | grep -q -E 'Enter to (confirm|select)|Esc to cancel|Do you want to'; then
    echo "❌ Target is showing a dialog/question; not typing into it:"
    echo "$SCREEN" | grep -v '^\s*$' | tail -8
    exit 3
fi

if echo "$SCREEN" | grep -E '^\s*❯' | tail -1 | grep -q -E '❯\s*\S'; then
    echo "❌ Target input box already has text (someone is typing); not sending."
    exit 3
fi

cmux send-panel --panel "$SURF" --workspace "$WS" -- "$MSG" >/dev/null || { echo "❌ send-panel failed"; exit 1; }
sleep 1
cmux send-key-panel --panel "$SURF" --workspace "$WS" Enter >/dev/null

# Long pastes sometimes need a second Enter before Claude picks them up
for attempt in 1 2; do
    sleep 3
    if screen 12 | grep -q -E 'esc to interrupt|running .*hooks|Incubating|Thinking'; then
        echo "✅ Delivered to $SURF ($WS)"
        exit 0
    fi
    [ "$attempt" = 1 ] && cmux send-key-panel --panel "$SURF" --workspace "$WS" Enter >/dev/null
done

echo "⚠️ Sent, but couldn't confirm the target started working. Screen tail:"
screen 10 | grep -v '^\s*$' | tail -6
exit 2
