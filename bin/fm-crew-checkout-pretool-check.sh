#!/usr/bin/env bash
# PreToolUse guard against a crew/scout writing to a foreign firstmate checkout.
#
# A crewmate/scout runs in its own linked git worktree of the firstmate repo.
# The launch-time isolation assertion only proves the crew STARTS there; nothing
# stops a later command from reaching over into the PRIMARY firstmate checkout
# (or a sibling worktree) and committing onto its branch. That happened: a crew
# `cd`'d into the primary checkout and committed onto its local main, because the
# primary-session cd-guard (bin/fm-cd-pretool-check.sh) is deliberately inert in
# a crew worktree - it only protects the primary session.
#
# This guard is the inverse scope: it fires ONLY in a crew/scout task worktree
# and DENIES a tool action that `cd`s into, `git -C`/`--git-dir`/`--work-tree`
# targets, or writes a file under any firstmate checkout that is not the crew's
# OWN worktree. It keys on the git-common-dir relationship, not repo identity:
# the primary and every worktree share one object store, so a target under a
# worktree whose common-dir matches ours but whose top-level differs is a foreign
# firstmate checkout. The crew's own worktree is always allowed, reads are always
# allowed, and it is a silent no-op in the primary session and secondmate homes.
# See docs/crew-checkout-guard.md for the complete contract and validation record.
#
# Usage:
#   <PreToolUse JSON on stdin> | bin/fm-crew-checkout-pretool-check.sh
#   bin/fm-crew-checkout-pretool-check.sh --command '<cmd>'
#   bin/fm-crew-checkout-pretool-check.sh --file '<absolute-path>'
#
# Stdin mode reads .tool_name/.toolName plus .tool_input/.toolInput and pulls the
# Bash command or the write tool's file_path/notebook_path. CLI mode is used by
# adapters that already hold the exact string (OpenCode, Pi, and the pi crew
# extension pass --command; a file tool passes --file).
#
# Exit/output contract (identical shape to bin/fm-cd-pretool-check.sh):
#   ALLOW - exit 0 and no output.
#   DENY - exit 2, a Claude-shaped deny object on stderr, and a Grok-shaped
#          deny object on stdout unless --claude was supplied.
#   INERT - not a crew/scout task worktree (the primary session, a secondmate
#           home, or a non-firstmate repo): exit 0 with no output, like ALLOW.
#   FAIL OPEN - malformed or empty stdin, missing jq for stdin transport, or a
#               scope/topology that cannot be resolved: exit 0, so a broken
#               environment never denies a legitimate in-worktree command. A
#               cross-checkout write that IS resolvable always denies (the guard
#               fails toward blocking that specific case, never toward allowing).
#
# Claude requires stdout to remain empty on deny.
# Codex blocks on exit 2 and displays stderr.
# Grok consumes the stdout decision object.
# OpenCode and Pi consume exit 2 plus stderr.
set -u

REASON_CODE='crew-cross-checkout-write'

# Write-capable tools whose payload names a target path. A read-only tool never
# reaches the deny path even if a matcher is misconfigured to include it, because
# reads anywhere are allowed. Lowercased before comparison.
READONLY_TOOLS='read grep glob ls notebookread webfetch websearch bashoutput'

CMD=""
CMD_SET=0
FILE=""
FILE_SET=0
CLAUDE_MODE=0

usage() {
  cat <<'EOF'
Usage: fm-crew-checkout-pretool-check.sh [--command <cmd>] [--file <path>] [--claude]

With neither --command nor --file, reads a PreToolUse-style JSON payload on
stdin (Claude/Codex tool_name+tool_input, or Grok toolName+toolInput).
Fires only in a crewmate/scout task worktree (a linked firstmate worktree); it
is a silent no-op in the primary session, a secondmate home, or a non-firstmate
repo. Denies a command or file write that targets the primary firstmate checkout
or any firstmate worktree other than the crew's own.
Exits 0 to allow and 2 to deny. The deny reason is written to stderr, with a
Grok decision object on stdout unless --claude is supplied.
Malformed transport and an unresolvable scope fail open.
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --command)
      [ "$#" -gt 1 ] || { echo "error: --command requires a value" >&2; exit 2; }
      CMD=$2
      CMD_SET=1
      shift 2
      ;;
    --command=*)
      CMD=${1#--command=}
      CMD_SET=1
      shift
      ;;
    --file)
      [ "$#" -gt 1 ] || { echo "error: --file requires a value" >&2; exit 2; }
      FILE=$2
      FILE_SET=1
      shift 2
      ;;
    --file=*)
      FILE=${1#--file=}
      FILE_SET=1
      shift
      ;;
    --claude)
      CLAUDE_MODE=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "error: unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

TOOL=""
if [ "$CMD_SET" -eq 0 ] && [ "$FILE_SET" -eq 0 ]; then
  PAYLOAD=$(cat 2>/dev/null || true)
  [ -n "$PAYLOAD" ] || exit 0
  command -v jq >/dev/null 2>&1 || exit 0
  TOOL=$(printf '%s' "$PAYLOAD" | jq -r '(.tool_name // .toolName // empty)' 2>/dev/null) || exit 0
  CMD=$(printf '%s' "$PAYLOAD" | jq -r '(.tool_input.command // .toolInput.command // empty)' 2>/dev/null) || exit 0
  FILE=$(printf '%s' "$PAYLOAD" | jq -r '(.tool_input.file_path // .tool_input.notebook_path // .toolInput.file_path // .toolInput.notebook_path // empty)' 2>/dev/null) || exit 0
fi

# A read-only tool never denies: reads anywhere are legitimate.
if [ -n "$TOOL" ]; then
  LC_ALL=C tool_lc=$(printf '%s' "$TOOL" | tr '[:upper:]' '[:lower:]' | tr -cd 'a-z0-9')
  for ro in $READONLY_TOOLS; do
    [ "$tool_lc" != "$ro" ] || exit 0
  done
fi

[ -n "$CMD" ] || [ -n "$FILE" ] || exit 0

# Strict-superset prefilter for the command path (transport only, no semantics):
# a foreign-checkout command must relocate the shell (cd/pushd) or drive git at a
# path, so a command with none of those tokens can never be a deniable command
# and skips scope resolution. This can only over-include, never under-include.
if [ -n "$CMD" ] && [ -z "$FILE" ]; then
  case "$CMD" in
    *cd*|*pushd*|*git*) ;;
    *) exit 0 ;;
  esac
fi

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" 2>/dev/null && pwd -P) || exit 0
OWN=${FM_ROOT_OVERRIDE:-$(CDPATH='' cd -- "$SCRIPT_DIR/.." 2>/dev/null && pwd -P)} || exit 0
FM_HOME=${FM_HOME:-${FM_ROOT_OVERRIDE:-$OWN}}
STATE=${FM_STATE_OVERRIDE:-$FM_HOME/state}

# Scope: fire ONLY in a genuine crew/scout task worktree. fm_primary_scope_matches
# is true for the primary checkout OR a marked secondmate home - both operate a
# fleet and are NOT crews - so those exit inert here, the exact inverse of the
# subagent and cd guards. Any failure to positively confirm a firstmate linked
# worktree is inert (exit 0), never a block, so a broken environment never denies.
# shellcheck source=bin/fm-primary-scope-lib.sh
. "$SCRIPT_DIR/fm-primary-scope-lib.sh"
fm_primary_scope_matches "$OWN" "$STATE" && exit 0

[ -f "$OWN/AGENTS.md" ] || exit 0
[ -d "$OWN/bin" ] || exit 0
command -v git >/dev/null 2>&1 || exit 0
GIT_DIR=$(git -C "$OWN" rev-parse --git-dir 2>/dev/null) || exit 0
GIT_COMMON_DIR=$(git -C "$OWN" rev-parse --git-common-dir 2>/dev/null) || exit 0
# A crew/scout worktree is a LINKED worktree: git-dir and git-common-dir differ.
# A plain checkout (the primary) has them equal and is already excluded above,
# but re-confirm the linked shape so a non-worktree firstmate clone stays inert.
[ "$GIT_DIR" != "$GIT_COMMON_DIR" ] || exit 0

# Canonicalize a path for containment. An existing dir resolves through pwd -P;
# an existing file resolves its parent; a not-yet-created path (a new file to be
# written) is normalized lexically against its existing parent. A non-absolute
# path is skipped (echo empty): a relative target resolves against the crew's own
# cwd, which is its own worktree, and is never a cross-checkout reach.
canon() {
  local p=$1 d b dc
  if [ "$p" = '~' ]; then
    p=${HOME:-/}
  elif [ "${p#\~/}" != "$p" ]; then
    p=${HOME:-}/${p#\~/}
  fi
  case "$p" in
    /*) ;;
    *) return 0 ;;
  esac
  p=${p%/}
  [ -n "$p" ] || p=/
  if [ -d "$p" ]; then
    (CDPATH='' cd -- "$p" 2>/dev/null && pwd -P)
    return 0
  fi
  d=$(dirname -- "$p")
  b=$(basename -- "$p")
  if [ -d "$d" ] && dc=$(CDPATH='' cd -- "$d" 2>/dev/null && pwd -P); then
    printf '%s/%s\n' "${dc%/}" "$b"
    return 0
  fi
  printf '%s\n' "$p"
}

# Build the set of firstmate checkouts that share OWN's object store: every
# worktree git knows about, plus a floor of the primary derived from the common
# dir so the primary (the actual accident target) is covered even if worktree
# enumeration fails.
OWN_CANON=$(canon "$OWN")
WT=()
while IFS= read -r line; do
  case "$line" in
    'worktree '*)
      wt=$(canon "${line#worktree }")
      [ -n "$wt" ] && WT+=("$wt")
      ;;
  esac
done < <(git -C "$OWN" worktree list --porcelain 2>/dev/null)

# Primary floor: the common dir is <primary>/.git for a standard worktree setup.
COMMON_ABS=$GIT_COMMON_DIR
case "$COMMON_ABS" in
  /*) ;;
  *) COMMON_ABS=$OWN/$COMMON_ABS ;;
esac
PRIMARY=$(canon "$(dirname -- "$COMMON_ABS")")
if [ -n "$PRIMARY" ]; then
  present=0
  for w in "${WT[@]}"; do
    [ "$w" != "$PRIMARY" ] || { present=1; break; }
  done
  [ "$present" -eq 1 ] || WT+=("$PRIMARY")
fi

# under_dir <child> <parent>: true when child is parent or lives beneath it.
under_dir() {
  local c=$1 p=$2
  [ -n "$c" ] && [ -n "$p" ] || return 1
  [ "$c" != "$p" ] || return 0
  case "$c" in
    "$p"/*) return 0 ;;
    *) return 1 ;;
  esac
}

FOREIGN_WT=""
# foreign_target <canonical-target>: true (and sets FOREIGN_WT) when the target
# lives under a firstmate checkout other than the crew's own worktree. A target
# under OWN never matches, because worktrees never nest.
foreign_target() {
  local t=$1 w
  [ -n "$t" ] || return 1
  under_dir "$t" "$OWN_CANON" && return 1
  for w in "${WT[@]}"; do
    [ "$w" != "$OWN_CANON" ] || continue
    if under_dir "$t" "$w"; then
      FOREIGN_WT=$w
      return 0
    fi
  done
  return 1
}

unquote() {
  local s=$1
  s=${s%%[\&\;\|]*}
  s=${s#[\"\']}
  s=${s%[\"\']}
  printf '%s' "$s"
}

DENY_DETAIL=""
kind_for() {
  # $1 canonical foreign worktree -> "the primary firstmate checkout" or a sibling
  if [ "$1" = "$PRIMARY" ]; then
    printf 'the primary firstmate checkout'
  else
    printf 'another firstmate worktree'
  fi
}

# Command path: extract cd/pushd targets and git -C/--git-dir/--work-tree targets.
# Keyword detection uses the raw token (quotes NOT stripped) so `echo "cd /x"`
# does not arm on a quoted word; target extraction strips quotes and any trailing
# shell operator. Word-splitting is deliberate: deeper obfuscation is out of scope
# by the same agent-mistake threat model the cd-guard uses, and the accident used
# a plain absolute-path `cd` + `git commit`.
analyze_command() {
  local cmd=$1
  local -a toks
  # shellcheck disable=SC2206
  read -ra toks <<<"$cmd" || return 0
  local i n=${#toks[@]} raw tgt cd_armed=0 git_mode=0 want_C=0 t
  for ((i = 0; i < n; i++)); do
    raw=${toks[$i]}
    if [ "$want_C" -eq 1 ]; then
      want_C=0
      tgt=$(canon "$(unquote "$raw")")
      if foreign_target "$tgt"; then
        DENY_DETAIL="[$REASON_CODE] blocked a git command targeting $(kind_for "$FOREIGN_WT") at $FOREIGN_WT from this crew task worktree ($OWN). A crew works only in its own worktree, which is the same repo and shares its full git history: drop the '-C $tgt' and run git here. Reads are fine; only cross-checkout writes are blocked."
        return 0
      fi
      continue
    fi
    if [ "$cd_armed" -eq 1 ]; then
      [ "$raw" = "--" ] && continue
      cd_armed=0
      tgt=$(canon "$(unquote "$raw")")
      if foreign_target "$tgt"; then
        DENY_DETAIL="[$REASON_CODE] blocked a 'cd' into $(kind_for "$FOREIGN_WT") at $FOREIGN_WT from this crew task worktree ($OWN). Relocating into another firstmate checkout is how a crew accidentally commits onto the primary's branch. Stay in this worktree; it is the same repo and shares its git history. Reads are fine; only cross-checkout writes are blocked."
        return 0
      fi
      continue
    fi
    case "$raw" in
      cd|pushd) cd_armed=1 ;;
      git) git_mode=1 ;;
      -C) [ "$git_mode" -eq 1 ] && want_C=1 ;;
      -C?*)
        if [ "$git_mode" -eq 1 ]; then
          tgt=$(canon "$(unquote "${raw#-C}")")
          if foreign_target "$tgt"; then
            DENY_DETAIL="[$REASON_CODE] blocked a git command targeting $(kind_for "$FOREIGN_WT") at $FOREIGN_WT from this crew task worktree ($OWN). Drop the '-C' target and run git in this worktree, which shares the same repo history. Reads are fine; only cross-checkout writes are blocked."
            return 0
          fi
        fi
        ;;
      --git-dir=*)
        t=$(unquote "${raw#--git-dir=}")
        t=${t%/.git}
        tgt=$(canon "$t")
        if foreign_target "$tgt"; then
          DENY_DETAIL="[$REASON_CODE] blocked a git command whose --git-dir points into $(kind_for "$FOREIGN_WT") at $FOREIGN_WT from this crew task worktree ($OWN). Run git in this worktree instead. Reads are fine; only cross-checkout writes are blocked."
          return 0
        fi
        ;;
      --work-tree=*)
        tgt=$(canon "$(unquote "${raw#--work-tree=}")")
        if foreign_target "$tgt"; then
          DENY_DETAIL="[$REASON_CODE] blocked a git command whose --work-tree points into $(kind_for "$FOREIGN_WT") at $FOREIGN_WT from this crew task worktree ($OWN). Run git in this worktree instead. Reads are fine; only cross-checkout writes are blocked."
          return 0
        fi
        ;;
    esac
  done
  return 0
}

if [ -n "$FILE" ]; then
  tgt=$(canon "$FILE")
  if foreign_target "$tgt"; then
    DENY_DETAIL="[$REASON_CODE] blocked a write to $tgt under $(kind_for "$FOREIGN_WT") at $FOREIGN_WT from this crew task worktree ($OWN). Changes to another firstmate checkout are not the crew's to make; write under $OWN instead."
  fi
fi

if [ -z "$DENY_DETAIL" ] && [ -n "$CMD" ]; then
  analyze_command "$CMD"
fi

[ -n "$DENY_DETAIL" ] || exit 0

json_escape() {
  printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' | tr '\n' ' '
}

ESCAPED=$(json_escape "$DENY_DETAIL")
printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny"},"systemMessage":"%s"}\n' "$ESCAPED" >&2
[ "$CLAUDE_MODE" -eq 1 ] || printf '{"decision":"deny","reason":"%s"}\n' "$ESCAPED"
exit 2
