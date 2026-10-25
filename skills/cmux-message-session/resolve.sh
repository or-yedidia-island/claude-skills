#!/bin/bash

# Resolve a fuzzy target ("gcp session", "orchestrator") to the Claude session in a cmux tab.
# Usage: ./resolve.sh [--from <surface-ref>] [query]   (no query -> list every Claude tab)

# Join: cmux surface tty -> claude pid on that tty -> ~/.claude/sessions/<pid>.json

FROM=""
if [ "$1" = "--from" ]; then FROM="$2"; shift 2; fi
QUERY="$*"

command -v cmux >/dev/null || { echo '{"error":"cmux not in PATH"}'; exit 1; }

TREE=$(CMUX_QUIET=1 cmux tree --all --json 2>/dev/null) || { echo '{"error":"cmux tree failed (is cmux running?)"}'; exit 1; }
GROUPS_JSON=$(CMUX_QUIET=1 cmux workspace-group list --json 2>/dev/null || echo '{"groups":[]}')

# "<tty> <pid>" for every claude process attached to a terminal
PIDS=$(ps -A -o pid=,tty=,comm= | awk '$3 ~ /(^|\/)claude$/ && $2 != "??" {print $2, $1}')

SESSIONS=$(
  echo "$PIDS" | while read -r tty pid; do
    [ -z "$pid" ] && continue
    f="$HOME/.claude/sessions/$pid.json"
    if [ -f "$f" ]; then
      jq -c --arg tty "$tty" '{tty: $tty, pid, name, status, cwd, socket: .messagingSocketPath, peer: (.peerProtocol != null)}' "$f"
    else
      jq -nc --arg tty "$tty" --argjson pid "$pid" '{tty: $tty, pid: $pid, name: null, status: null, cwd: null, socket: null, peer: false}'
    fi
  done | jq -s '.'
)

jq -n \
  --argjson tree "$TREE" \
  --argjson groups "$GROUPS_JSON" \
  --argjson sessions "${SESSIONS:-[]}" \
  --arg query "$QUERY" \
  --arg from "$FROM" '
  def norm: ascii_downcase | gsub("[^a-z0-9]+"; " ") | ltrimstr(" ") | rtrimstr(" ");
  def squash: norm | gsub(" "; "");
  def stop: ["the","tab","tabs","session","sessions","claude","agent","workspace","in","this","my","that","to"];
  def basename: if . == null then "" else split("/") | last end;

  # 0-100: how well query q (raw string) matches field f
  def fscore($q; $f):
    ($q | squash) as $qs | ($f // "" | squash) as $fs
    | if $qs == "" or $fs == "" then 0
      elif $qs == $fs then 100
      elif ($qs | length) > 1 and ($fs | contains($qs)) then 80
      else ([$q | norm | split(" ")[] | select(length > 1)] ) as $toks
        | if ($toks | length) == 0 then 0
          else ([$toks[] | select(. as $t | $fs | contains($t))] | length) as $hit
            | if $hit == 0 then 0 else (60 * $hit / ($toks | length)) end
          end
      end;

  # score with the full query and with filler words dropped; keep the best
  def qscore($q; $f):
    ([$q | norm | split(" ")[] | select(. as $w | stop | index($w) | not)] | join(" ")) as $core
    | [fscore($q; $f), (if $core != "" then fscore($core; $f) else 0 end)] | max;

  ($query | norm) as $nq
  | ([$nq | split(" ")[] | select(. as $w | stop | index($w) | not)] | join(" ")) as $core
  | (["orchestrator","lead","first","first one","main"] | index($core)) as $isAlias

  | [ $tree.windows[].workspaces[] as $w
      | ([$w.panes[].surfaces[]] | to_entries) as $surfs
      | $surfs[] | .key as $i | .value as $s
      | select($s.type == "terminal")
      | { workspace_ref: $w.ref, workspace_title: $w.title, surface_ref: $s.ref,
          tab_title: $s.title, tab_index: $i, tty: $s.tty,
          here: (if $from != "" then $s.ref == $from else ($s.here // false) end) } ] as $tabs

  | ($tabs | map(select(.here)) | first) as $me
  | ($groups.groups // []) as $gs
  | def group_of($ws): ($gs | map(select(.member_workspace_refs | index($ws))) | first | .name) // null;
    (if $me then group_of($me.workspace_ref) else null end) as $mygroup

  | [ $tabs[] as $t
      | ($sessions | map(select(.tty == $t.tty)) | first) as $s
      | select($s != null)
      | ($t + { group: group_of($t.workspace_ref) } + {
          session_name: $s.name, status: $s.status, cwd: $s.cwd, pid: $s.pid,
          socket: $s.socket, peer: $s.peer,
          self: ($t.here or ($me != null and $t.tty == $me.tty)),
          same_workspace: ($me != null and $t.workspace_ref == $me.workspace_ref),
          same_group: ($mygroup != null and group_of($t.workspace_ref) == $mygroup) }) ] as $cands

  | if $query == "" then
      { verdict: "list", query: $query, self: ($cands | map(select(.self)) | first),
        candidates: ($cands | map(select(.self | not))) }
    else
      [ $cands[] | select(.self | not)
        | . as $c
        | ([ qscore($query; $c.tab_title) * 1.0,
             qscore($query; $c.session_name) * 0.8,
             qscore($query; $c.workspace_title) * 0.7,
             qscore($query; ($c.cwd | basename)) * 0.6,
             qscore($query; $c.group) * 0.5 ] | max) as $m
        # "orchestrator"/"lead": first tab of my workspace, unless a tab is titled with it
        | (if $isAlias != null and $c.same_workspace and $c.tab_index == 0 then [$m, 75] | max else $m end) as $m
        | select($m >= 25)
        | . + { score: ((if $c.same_workspace then $m + 30 elif $c.same_group then $m + 15 else $m end) | floor) } ]
      | sort_by(-.score) as $ranked
      | ($ranked[0].score // 0) as $top
      | ($ranked[1].score // 0) as $second
      | { verdict: (if $top < 50 then "none" elif ($top - $second) >= 20 then "unique" else "ambiguous" end),
          query: $query,
          self: ($cands | map(select(.self)) | first),
          candidates: ($ranked | .[0:6]) }
    end
'
