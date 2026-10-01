#!/bin/bash
# Claude Code statusline — display-only port of claude-flame's statusline
# (dev-utils c5c92c5, claude-flame/statusline/statusline-command.sh).
# Kept: cache countdown, ctx, floor cost, waste%, spend figures. Dropped: every
# cmux interaction (FocusLight), WarmCompact triggering/dialogs and the
# MechanicalCompact hint/badges. Read-only apart from the per-session cost
# state under ~/.claude/statusline-state/cost (needed for $last and $life).

# Rates are $/MTok INPUT (vendored from claude-flame lib/costs.sh). Patterns
# match both model ids ("claude-fable-5") and display names ("Fable 5").
model_in_rate() {
  case "$1" in
    *[Hh]aiku*)             echo 1 ;;
    *[Ss]onnet*)            echo 3 ;;
    *[Ff]able*|*[Mm]ythos*) echo 10 ;;
    *[Oo]pus*)              echo 5 ;;
    *)                      echo 5 ;;   # unknown -> assume Opus-tier
  esac
}

input=$(cat)

model=$(echo "$input" | jq -r '.model.display_name // "Unknown Model"')
effort=$(echo "$input" | jq -r '.effort.level // empty')

used_pct=$(echo "$input" | jq -r '.context_window.used_percentage // empty')
remaining_pct=$(echo "$input" | jq -r '.context_window.remaining_percentage // empty')

# Context-window size (e.g. 1M) — shown next to the model as its capacity.
ctx_window=$(echo "$input" | jq -r '.context_window.context_window_size // empty')
win_label=""
if [ -n "$ctx_window" ] && [ "$ctx_window" -gt 0 ] 2>/dev/null; then
  if [ "$ctx_window" -ge 1000000 ]; then win_label="$((ctx_window/1000000))M"; else win_label="$((ctx_window/1000))k"; fi
fi

session_id=$(echo "$input" | jq -r '.session_id // ""')
transcript_path=$(echo "$input" | jq -r '.transcript_path // ""')

# Authoritative run cost (cost.total_cost_usd). Exact, but tracks only the current
# claude process/run and resets on resume — so it is the building block for both
# "run" (shown as-is) and "life" (accumulated across resets below), never estimated.
run_raw=$(echo "$input" | jq -r '.cost.total_cost_usd // empty')

# Current main-thread context tokens + last-activity timestamp + real user prompts
# + digest ("keep") size since the last compact/reset — one streaming pass over
# the transcript. Cost is NOT derived here anymore (it comes from the
# authoritative run figure below).
#   U rows = assistant usages. last U = current context tokens + last-activity ts.
#            Also carries the row's assistant TEXT chars (digest content).
#   C rows = compaction boundaries (reset the message counter and keep tally)
#   P rows = real user prompts (excludes tool_result, meta, and /slash-command
#            entries). Carries the prompt's text chars (digest content).
#   T rows = tool_result payload chars. Summed per turn; the last TWO turns'
#            worth (recent_chars) is treated as still-live working set, not
#            waste — older results are almost never queried again.
# keep_chars = what a mechanical extract would retain (user + assistant text);
# everything else in context (thinking, tool results, attachments) is "waste".
main_tokens=0
msgs=0
last_ts=0
keep_chars=0
recent_chars=0
if [ -n "$transcript_path" ] && [ -f "$transcript_path" ]; then
  # TZ=UTC0: jq's fromdateiso8601 otherwise applies the local DST offset on some
  # platforms (e.g. macOS), parsing a "...Z" timestamp up to an hour off and making
  # the cache clock read into the future. Forcing UTC makes the parse match date -u.
  read -r main_tokens msgs last_ts keep_chars recent_chars < <(
    TZ=UTC0 jq -rc '
      if (.type=="assistant" and (.isSidechain != true) and (.message.usage != null)) then
        "U\t\((.message.usage.input_tokens//0)+(.message.usage.cache_read_input_tokens//0)+(.message.usage.cache_creation_input_tokens//0))\t\(try ((.timestamp // "") | sub("\\.[0-9]+Z$";"Z") | fromdateiso8601) catch 0)\t\([.message.content[]? | select(.type=="text") | .text | length] | add // 0)"
      elif ((.compactMetadata != null) or (.isCompactSummary == true)) then "C\t\((.message.content // "") | if type=="string" then length else ([.[]? | select(.type=="text") | .text | length] | add // 0) end)\t\(try ((.timestamp // "") | sub("\\.[0-9]+Z$";"Z") | fromdateiso8601) catch 0)"
      elif (.type=="user" and (.isSidechain != true) and ((.isMeta // false) != true)
            and ((.message.content | type) == "array") and ((.message.content[0].type // "") == "tool_result")
           ) then "T\t\([.message.content[]? | select(.type=="tool_result") | (.content // "") | if type=="string" then length else (tojson|length) end] | add // 0)"
      elif (.type=="user" and (.isSidechain != true) and ((.isMeta // false) != true)
            and (((.message.content | type) != "array") or ((.message.content[0].type // "") != "tool_result"))
            and ((((.message.content | type)=="string") and ((.message.content|startswith("<command-")) or (.message.content|startswith("<local-command")) or (.message.content|startswith("<task-notification")))) | not)
           ) then "P\t\(.message.content | if type=="string" then length else ([.[]? | select(.type=="text") | .text | length] | add // 0) end)"
      else empty end
    ' "$transcript_path" 2>/dev/null \
    | awk -F'\t' 'BEGIN{ctx=0;m=0;ts=0;keep=0;tc=0;tp=0}
        $1=="U"{ctx=$2; ts=$3; keep+=$4}
        $1=="C"{m=0; keep=$2+0; tc=0; tp=0; if ($3+0>ts) ts=$3+0}
        $1=="P"{m++; keep+=$2; tp=tc; tc=0}
        $1=="T"{tc+=$2}
        END{printf "%d %d %d %d %d", ctx, m, ts, keep, tc+tp}'
  )
  [ -n "$main_tokens" ] || main_tokens=0
  [ -n "$msgs" ] || msgs=0
  [ -n "$last_ts" ] || last_ts=0
  [ -n "$keep_chars" ] || keep_chars=0
  [ -n "$recent_chars" ] || recent_chars=0
fi

# Live context size — the payload's used_percentage x window. It updates
# immediately on /compact, unlike the transcript's last assistant-usage row,
# which holds the PRE-compact value until the next reply lands (verified: a 250k
# context stayed 250k for ~14h across a compact).
# CRITICAL: trust the payload even when it reads ~0. Right after /compact it
# reports ~0% until the first new turn — that is CLOSER to truth (context was
# just cleared) than the stale transcript number. Treating 0 as "missing" and
# falling back to the transcript was the bug that showed ctx:257k after compact.
# Only fall back when used_percentage is genuinely ABSENT (empty).
if [ -n "$used_pct" ] && [ -n "$ctx_window" ] && [ "$ctx_window" -gt 0 ] 2>/dev/null; then
  ctx_tokens=$(awk -v p="$used_pct" -v w="$ctx_window" 'BEGIN{printf "%d", (p/100.0)*w}')
else
  ctx_tokens="$main_tokens"
fi
[ -n "$ctx_tokens" ] || ctx_tokens=0

# Life (lifetime spend) and last (current-turn spend) from the AUTHORITATIVE run
# figure — no token math. A tiny per-session state file survives process resets.
# run (cost.total_cost_usd) resets to ~0 when a session is resumed in a new
# process, so to keep a lifetime total we "bank" a finished instance's spend when
# it restarts. run only grows within a process, so a resume shows up as run
# collapsing far below the peak. Detect that and bank the peak, exactly once:
#   run_peak = high-water run of the CURRENT process instance
#   armed    = may we bank? (1 once real spend seen, 0 after a bank)
# Bank when armed AND peak >= $1 AND run dropped to within ~10% of the peak
# (run < 0.10 + 0.10*peak) -- i.e. a ~90% collapse, which only a resume produces
# (normal spend keeps run == peak). Banking DISARMS; nothing re-arms until a new
# instance itself spends >= $1. The armed flag is the double-bank guard: while run
# sits low across many renders, armed=0 blocks any re-bank. No timer needed.
# life = accumulated + run ; last = run - turn_start_run (baseline resets when the
# prompt count changes). Old-schema files (no run_peak) are auto-repaired:
# accumulated resets to 0 so a runaway lifetime from the old rule cannot carry forward.
life_fmt="0.00"; last_fmt="0.00"; cost_note=""
cost_now=$(printf "%.2f" "${run_raw:-0}" 2>/dev/null || echo "0.00")
if [ -n "$run_raw" ] && [ -n "$session_id" ]; then
  # Own dir, separate from claude-flame's ~/.claude/claude-flame/cost, so the
  # two never fight over one file. Nothing prunes it: a file is ~100 bytes.
  STATE_DIR="$HOME/.claude/statusline-state/cost"
  mkdir -p "$STATE_DIR" 2>/dev/null
  sf="$STATE_DIR/${session_id}.json"
  prev_acc=0; prev_peak=0; prev_armed=0; prev_tstart=0; prev_tmsgs=-1
  state_readable=1
  if [ -f "$sf" ]; then
    # A present-but-unparseable file (e.g. half-written after a crash) must NOT
    # be treated like a missing one: resetting to 0 and rewriting would erase
    # the real lifetime total for good. Keep it, skip the write below, and flag.
    if jq -e . "$sf" >/dev/null 2>&1; then
      read -r prev_acc prev_peak prev_armed prev_tstart prev_tmsgs < <(
        jq -r 'if (.run_peak == null) then "0 0 0 0 -1"
               else "\(.accumulated//0) \(.run_peak//0) \(.armed//0) \(.turn_start_run//0) \(.turn_msgs//-1)" end' "$sf" 2>/dev/null)
      [ -n "$prev_acc" ] || { prev_acc=0; prev_peak=0; prev_armed=0; prev_tstart=0; prev_tmsgs=-1; }
    else
      state_readable=0
      cost_note="cost-state corrupt"
    fi
  fi
  read -r life_fmt last_fmt new_acc new_peak new_armed new_tstart < <(
    awk -v run="$run_raw" -v acc="$prev_acc" -v peak="$prev_peak" -v armed="$prev_armed" \
        -v ts="$prev_tstart" -v pmsgs="$prev_tmsgs" -v cmsgs="$msgs" 'BEGIN{
      REARM=1.00; DROP_BASE=0.10; DROP_SLOPE=0.10
      if (run > peak) peak = run
      if (armed==1 && peak >= REARM && run < DROP_BASE + DROP_SLOPE*peak) {
        acc += peak; armed=0; peak=run              # resume: bank the peak, once
      }
      if (armed==0 && run >= REARM) armed=1         # re-arm only after real new spend
      if (cmsgs != pmsgs) ts = run                  # new prompt -> fresh turn baseline
      last = run - ts; if (last < 0) last = 0
      printf "%.2f %.2f %.6f %.6f %d %.6f", acc+run, last, acc, peak, armed, ts
    }')
  # Persist only when the prior file was readable — never overwrite a corrupt
  # file, or the real lifetime total is destroyed. Surface a write failure too
  # (unwritable dir, full disk), so the figures are not silently trusted when
  # they are not actually being saved.
  if [ "$state_readable" -eq 1 ]; then
    tmp="$sf.tmp.$$"
    # stderr suppressed at the GROUP level so even a failed '> "$tmp"' redirection
    # (dir not writable) stays silent — the render loop must never print errors.
    if ! { printf '{"accumulated":%s,"run_peak":%s,"armed":%s,"turn_start_run":%s,"turn_msgs":%s}\n' \
             "$new_acc" "$new_peak" "$new_armed" "$new_tstart" "$msgs" > "$tmp" && mv -f "$tmp" "$sf"; } 2>/dev/null; then
      rm -f "$tmp" 2>/dev/null
      cost_note="cost-state unwritable"
    fi
  fi
fi

# Compute duration from transcript file mtime vs now
duration=""
if [ -n "$transcript_path" ] && [ -f "$transcript_path" ]; then
  start_time=$(stat -f "%B" "$transcript_path" 2>/dev/null || stat -c "%W" "$transcript_path" 2>/dev/null || echo "")
  if [ -z "$start_time" ] || [ "$start_time" = "0" ]; then
    start_time=$(stat -f "%m" "$transcript_path" 2>/dev/null || stat -c "%m" "$transcript_path" 2>/dev/null || echo "")
  fi
  if [ -n "$start_time" ]; then
    now=$(date +%s)
    elapsed=$((now - start_time))
    h=$((elapsed / 3600))
    m=$(((elapsed % 3600) / 60))
    s=$((elapsed % 60))
    if [ "$h" -gt 0 ]; then
      duration=$(printf "%dh %02dm" "$h" "$m")
    else
      duration=$(printf "%dm" "$m")
    fi
  fi
fi

# Cache warmth — minutes left before the prompt-cache TTL lapses. The clock is
# the LAST assistant API round-trip (the event that actually warmed the
# server-side cache), taken from the last usage row's timestamp. We deliberately
# avoid the transcript file mtime: any stray write (compaction, hooks, tooling)
# bumps it and makes a cold cache look warm. Fall back to mtime only for old
# transcripts whose rows predate timestamps. TTL here is the Claude Code 1-hour
# window.
CACHE_TTL_MIN=60
cache_remaining=""
last_activity=""
if [ -n "$last_ts" ] && [ "$last_ts" -gt 0 ] 2>/dev/null; then
  last_activity="$last_ts"
elif [ -n "$transcript_path" ] && [ -f "$transcript_path" ]; then
  last_activity=$(stat -f "%m" "$transcript_path" 2>/dev/null || stat -c "%Y" "$transcript_path" 2>/dev/null || echo "")
fi
if [ -n "$last_activity" ]; then
  idle_min=$(( ( $(date +%s) - last_activity ) / 60 ))
  # Defensive: a genuinely future last_activity (real clock skew) would push
  # cache_remaining above the TTL. Clamp idle to >=0 so the readout never exceeds it.
  [ "$idle_min" -lt 0 ] && idle_min=0
  # -1 safety margin: count down from TTL-1 (59m) so the readout never overstates
  # warmth — better to believe the cache died a minute early than a minute late.
  cache_remaining=$(( CACHE_TTL_MIN - 1 - idle_min ))
fi

# Floor — the entry cost of the NEXT turn: re-processing the current context
# before you even type. It's a reliable minimum (ctx x rate), not the full turn
# cost (which adds your new message + the reply on top). Two knobs decide it:
#   warm cache -> re-READ the context  = 0.1 x input rate
#   cold cache -> re-WRITE (re-prefill) = 2 x input rate  (a ~20x jump)
# Base input rate comes from model_in_rate above (the single rate table); the cache
# multiples are fixed ratios that never change, so read/write are derived.
in_rate=$(model_in_rate "$model")
floor_fmt=""
floor_cents=0
if [ "$ctx_tokens" -ge 0 ] 2>/dev/null; then
  cold=0
  { [ -z "$cache_remaining" ] || [ "$cache_remaining" -le 0 ] 2>/dev/null; } && cold=1
  read -r floor_fmt floor_cents < <(
    awk -v t="$ctx_tokens" -v r="$in_rate" -v cold="$cold" 'BEGIN{
      rate = (cold ? r*2 : r*0.1)          # $/MTok: cold=write(1h)=2x, warm=read=0.1x
      d = t/1000000.0 * rate
      printf "%.2f %d", d, int(d*100 + 0.5)
    }')
fi

# ANSI colors (will be dimmed by terminal)
RESET="\033[0m"
BOLD="\033[1m"
YELLOW="\033[33m"
GREEN="\033[32m"
WHITE="\033[37m"
RED="\033[31m"
GRAY="\033[90m"
BOLD_RED="\033[1;31m"
# Emphasized alert: bold, bright-white text on a red background
ALERT="\033[1;97;41m"

# Shared traffic-light ramp: green → yellow → red → bold red → critical(red bg).
# Same styling logic for every metric; each caller passes its own thresholds.
#   args: value t1 t2 t3 t4  -> echoes the ANSI style for that value
sev_style() {
  local v=$1 t1=$2 t2=$3 t3=$4 t4=$5
  if   [ "$v" -ge "$t4" ]; then printf '%s' "$ALERT"
  elif [ "$v" -ge "$t3" ]; then printf '%s' "$BOLD_RED"
  elif [ "$v" -ge "$t2" ]; then printf '%s' "$RED"
  elif [ "$v" -ge "$t1" ]; then printf '%s' "$YELLOW"
  else                          printf '%s' "$GREEN"
  fi
}

# Cache warmth — same traffic-light ramp as ctx/msg, driven by idle time
# (worse as the cache ages). Idle-minute thresholds: 20 / 40 / 50 / 58.
cache_seg=""
if [ -n "$cache_remaining" ]; then
  cache_idle=$(( CACHE_TTL_MIN - cache_remaining ))
  cstyle=$(sev_style "$cache_idle" 20 40 50 58)
  if [ "$cache_remaining" -le 0 ]; then
    cache_seg="${cstyle} cache:cold ${RESET}"
  else
    cache_seg="${cstyle}cache:${cache_remaining}m${RESET}"
  fi
fi

# Floor segment — colored by its own dollar amount, which already fuses the two
# drivers (big ctx OR cold cache -> high floor). Dollar bands: <$1 green,
# <$2.25 yellow, <$3.50 red, <$5 dark red, >=$5 alert (red bg). Warm stays green
# (a 900k warm floor is ~$0.45); cold climbs the ramp. The one number that
# reddens on its own.
floor_seg=""
if [ -n "$floor_fmt" ]; then
  fstyle=$(sev_style "$floor_cents" 100 225 350 500)
  floor_seg="${fstyle}floor:\$${floor_fmt}${RESET}"
fi

# Waste segment — share of the DROPPABLE context that a mechanical extract
# would discard. keep = user + assistant text since the last compact, including
# the compact summary (~4 chars/token). The denominator excludes the fixed
# baseline (system prompt, tools, MCPs, skills, CLAUDE.md — ~55k, measured
# empirically across compacts): it re-loads identically in a fresh session, so
# it is neither kept nor lost. waste = (ctx - baseline - keep)/(ctx - baseline):
# attachments + tool calls/results + old dialogue overhead. Shown as soon as
# ctx exceeds the baseline (below that there is nothing to measure); with a
# small denominator the percentage is noisy — accepted, a rough number beats
# a missing one. Neutral color for now.
BASELINE_TOKENS=55000
waste_seg=""
if [ "$ctx_tokens" -gt 0 ] 2>/dev/null; then
  denom=$(( ctx_tokens - BASELINE_TOKENS ))
  if [ "$denom" -gt 0 ]; then
    live_tok=$(( (keep_chars + recent_chars) / 4 ))
    [ "$live_tok" -gt "$denom" ] && live_tok=$denom
    waste_pct=$(( 100 * (denom - live_tok) / denom ))
    waste_seg="${WHITE}waste:~${waste_pct}%${RESET}"
  fi
fi

# Three sections joined by a dim separator. Severity color lives ONLY in the
# center (ctx / cache / floor) — the signals that need attention. The left
# (identity) and right (passive info) stay neutral so the center stands out.
SEP="${GRAY} │ ${RESET}"

# --- Left: identity — model family, context window, effort (all one neutral) ---
left="${WHITE}${model%% *}${RESET}"
[ -n "$win_label" ] && left="${left} ${WHITE}${win_label}${RESET}"
[ -n "$effort" ] && left="${left} ${WHITE}${effort}${RESET}"

# --- Center: the signals that matter (the only colored section). Order:
# cache, ctx, floor. ctx/floor use the live payload size (ctx_tokens), so they
# track /compact instead of lagging. ---
center=""
[ -n "$cache_seg" ] && center="$cache_seg"
if [ "$ctx_tokens" -ge 0 ] 2>/dev/null; then
  main_k=$(( ctx_tokens / 1000 ))
  ctx_style=$(sev_style "$ctx_tokens" 200000 300000 400000 500000)
  # Remaining % kept from the old one-line statusline ("Context: N% remaining").
  rem=""
  [ -n "$remaining_pct" ] && rem=$(printf " (%.0f%% left)" "$remaining_pct" 2>/dev/null)
  center="${center:+${center}  }${ctx_style}ctx:${main_k}k${rem}${RESET}"
fi
[ -n "$floor_seg" ] && center="${center:+${center}  }${floor_seg}"

# --- Money: three figures, no labels, ordered granular -> broad so each is a
# subset of the next: last turn -> current run -> lifetime. All one neutral white
# (no hue — color stays on ctx/cache/floor); only "last" is set apart, by weight
# (BOLD), as the one to watch. ---
money="${BOLD}\$${last_fmt}${RESET} ${WHITE}\$${cost_now}${RESET} ${WHITE}\$${life_fmt}${RESET}"

# --- Info: passive stats — %, messages, time (all one neutral color) ---
info=""
[ -n "$waste_seg" ] && info="${waste_seg}"
[ "$msgs" -gt 0 ] 2>/dev/null && info="${info:+${info}  }${WHITE}${msgs}msg${RESET}"
[ -n "$duration" ] && info="${info:+${info}  }${WHITE}${duration}${RESET}"

# --- Cost-state health: a far-right red badge when the per-session cost file
# can't be trusted — corrupt (kept, not overwritten) or unwritable. Tells you
# the money figures are unreliable this render. Absent in the normal case. ---
note_seg=""
[ -n "$cost_note" ] && note_seg="${ALERT} ${cost_note} ${RESET}"

# Join non-empty sections.
line="$left"
[ -n "$center" ] && line="${line}${SEP}${center}"
line="${line}${SEP}${money}"
[ -n "$info" ] && line="${line}${SEP}${info}"
[ -n "$note_seg" ] && line="${line}${SEP}${note_seg}"

printf '%b\n' "$line"
