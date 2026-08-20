#!/usr/bin/env bash
# fm-dispatch-poll.sh - fleet-level dispatch-readiness check.
#
# Usage:
#   fm-dispatch-poll.sh scan
#
# WHAT IT IS FOR. Work that becomes dispatchable used to wait until firstmate
# happened to look at the backlog. This makes the queue pull: it notices that a
# dispatch is now possible and wakes firstmate through the durable wake queue.
#
# WHAT IT NEVER DOES. It never spawns, never starts a task, never writes a
# brief, and never ranks or recommends work. Deciding to dispatch needs the
# judgement AGENTS.md sections 7 and 11 place with firstmate - project, delivery
# mode, autonomy posture, and a task-specific brief. Only NOTICING that a
# dispatch is possible needs no judgement, and only that is automated here.
#
# HOW IT IS ARMED. This is a fleet-level check, not a per-task one, so it takes
# no state/<id>.check.sh file and needs no bin/fm-check-register.sh binding. The
# watcher's check sweep is keyed by task id (bin/fm-check-lib.sh validates the
# id through fm_pr_task_id_valid), and a fleet-level concern has no task id to
# be keyed by; minting a synthetic one would put a non-task into the task
# namespace where a real task could collide with it. Registration exists to bind
# the bytes of a PRIVATE, per-home, hand-written check before the watcher will
# execute it. This check is neither private nor hand-written: it is a tracked
# repository script, linted, tested, and refreshed by self-update, so the
# watcher dispatches it directly - the same shape it already uses for its other
# two non-task checks (the PR poll through bin/fm-pr-poll.sh from validated
# data, and Relay through bin/fm-x-poll.sh behind the byte-identified
# x-watch.check.sh shim). A per-home registered copy would be strictly worse: no
# lint, no test, and no update would ever reach it. The sweep's rule that every
# other state/*.check.sh is rejected without execution is untouched.
#
# OUTPUT CONTRACT. At most one line on stdout, and only when firstmate should
# wake. Silence means "nothing is dispatchable" and never "I could not tell":
# every inability to establish an answer is reported as its own verdict. Exit 0
# whether or not it printed; exit 1 only when the durable wake queue itself
# could not be appended; exit 2 on a usage error.
#
# The three verdicts, each printed with the "actionable: " prefix the watcher
# poll loop already expects from a scan of this shape:
#   dispatch ready:   work is dispatchable and the machine has room for it
#   dispatch blocked: work is dispatchable but the machine has no room
#   dispatch unknown: the answer could not be established, with the reason class
#
# NO REPEATS. A verdict is surfaced only when its signature differs from the one
# last surfaced (state/.dispatch-poll). "Changed" means the set of dispatchable
# task ids changed, or one of them gained or lost a usable brief - the two facts
# that change what firstmate would actually do. It deliberately does NOT include
# titles or notes, so editing a note is not a wake. A blocked or unknown verdict
# additionally re-surfaces once per FM_DISPATCH_RESURFACE_SECS, because a fault
# that goes quiet forever is how a fault rots invisibly; an unchanged ready set
# never re-surfaces on that cadence.
#
# WHERE THE CAPACITY NUMBERS COME FROM. The gate is the machine, and only the
# machine. Both terms of the floor are measured from sources that do not depend
# on how much firstmate is currently running, so the rule cannot conclude that
# whatever is running now is the right amount:
#   1. The operating system's own reserve, taken as installed physical RAM
#      (sysctl hw.memsize on Darwin, MemTotal on Linux). macOS backs its dynamic
#      pager with swap on the same data volume, and that demand exists whether
#      or not firstmate dispatches anything, so it is never space a worker may
#      have. It is a property of the machine, read from the machine.
#   2. The cost of one more isolated working copy, taken as the largest single
#      project clone under $FM_HOME/projects. A clone's size is a property of
#      the repository, not of the fleet, and those clones exist whether or not
#      anything is dispatched. Measured at most once per
#      FM_DISPATCH_COPY_MEASURE_SECS and cached, so the ordinary scan is a df.
# There is deliberately NO cap on the number of live workers. AGENTS.md section
# 7 already forbids a concurrency cap for independently validatable work, so a
# number here would be firstmate policy smuggled into a shell script - and a
# limit derived from how much is running is exactly the circular rule this
# design is meant to avoid. The live-worker count is reported as evidence and
# gates nothing.
#
# Environment overrides (all optional):
#   FM_DISPATCH_POOL_ROOT           path whose filesystem hosts isolated copies
#   FM_DISPATCH_OS_RESERVE_MB       operating-system reserve, in MiB
#   FM_DISPATCH_RESURFACE_SECS      bounded re-surface for blocked/unknown
#   FM_DISPATCH_COPY_MEASURE_SECS   cache lifetime for the clone measurement
#   FM_DISPATCH_LIST_LIMIT          identifiers named per group before "+N more"
set -u
export LC_ALL=C

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="$FM_HOME/data"
BACKLOG="$DATA/backlog.md"
RECORD="$STATE/.dispatch-poll"
COPY_CACHE="$STATE/.dispatch-copy-reserve"

# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"

RESURFACE_SECS=${FM_DISPATCH_RESURFACE_SECS:-21600}
case "$RESURFACE_SECS" in
  ''|*[!0-9]*) RESURFACE_SECS=21600 ;;
esac
COPY_MEASURE_SECS=${FM_DISPATCH_COPY_MEASURE_SECS:-21600}
case "$COPY_MEASURE_SECS" in
  ''|*[!0-9]*) COPY_MEASURE_SECS=21600 ;;
esac
# One wake payload is one line, and a home can hold dozens of dispatchable
# items, so the identifier lists are bounded. What is cut is always stated -
# never silently dropped - and the change signature covers the WHOLE set, so an
# item beyond the display limit still wakes when it appears.
LIST_LIMIT=${FM_DISPATCH_LIST_LIMIT:-12}
case "$LIST_LIMIT" in
  ''|*[!0-9]*|0) LIST_LIMIT=12 ;;
esac

if [ "$#" -ne 1 ] || [ "${1:-}" != scan ]; then
  printf 'usage: fm-dispatch-poll.sh scan\n' >&2
  exit 2
fi

[ -d "$STATE" ] && [ ! -L "$STATE" ] || {
  printf 'fm-dispatch-poll: state directory is unavailable: %s\n' "$STATE" >&2
  exit 1
}

if [ "$(uname)" = Darwin ]; then
  file_mtime() { stat -f %m "$1" 2>/dev/null; }
else
  file_mtime() { stat -c %Y "$1" 2>/dev/null; }
fi

now_epoch() { date +%s; }

# Change detection only, never a security boundary, so a cksum last resort is
# an acceptable fallback on a host with neither sha256 tool.
sig_hash() {
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 | awk '{print $1}'
  elif command -v sha256sum >/dev/null 2>&1; then
    sha256sum | awk '{print $1}'
  else
    cksum | tr -cd '0-9'
  fi
}

record_value() { # <key>
  [ -f "$RECORD" ] || return 0
  sed -n "s/^$1=//p" "$RECORD" 2>/dev/null | tail -1
}

record_write() { # <verdict> <signature> <epoch>
  local tmp
  tmp=$(umask 077; mktemp "$STATE/.dispatch-poll.XXXXXX") || return 1
  {
    printf 'schema=fm-dispatch-poll.v1\n'
    printf 'verdict=%s\n' "$1"
    printf 'signature=%s\n' "$2"
    printf 'surfaced_epoch=%s\n' "$3"
  } > "$tmp" || { rm -f "$tmp"; return 1; }
  mv -f "$tmp" "$RECORD" || { rm -f "$tmp"; return 1; }
}

# --- verdict assembly -------------------------------------------------------
#
# Each stage either establishes its fact or hands control to `undecidable`,
# which is the single place a "could not tell" answer is produced. There is no
# path from an inability to an empty result.

VERDICT=
SIGNATURE=
PAYLOAD=

undecidable() { # <class> <reason>
  VERDICT=unknown
  SIGNATURE=$(printf 'unknown\t%s\n' "$1" | sig_hash)
  PAYLOAD="dispatch unknown ($1): $2"
  surface
  exit 0
}

surface() {
  local prev_verdict prev_sig prev_epoch epoch age key
  epoch=$(now_epoch)
  prev_verdict=$(record_value verdict)
  prev_sig=$(record_value signature)
  prev_epoch=$(record_value surfaced_epoch)
  case "$prev_epoch" in ''|*[!0-9]*) prev_epoch=0 ;; esac

  if [ "$VERDICT" = none ]; then
    # Nothing to say, and nothing to remember either: a home that has never
    # surfaced a verdict stays untouched rather than acquiring a record that
    # only says "still quiet".
    if [ -n "$prev_verdict" ] && [ "$prev_verdict" != none ]; then
      record_write none "$SIGNATURE" "$epoch" || exit 1
    fi
    return 0
  fi

  if [ "$SIGNATURE" = "$prev_sig" ] && [ -n "$prev_sig" ]; then
    # An unchanged ready set is never repeated. A persisting fault or a
    # persisting lack of room re-surfaces only on the bounded cadence.
    [ "$VERDICT" = ready ] && return 0
    age=$((epoch - prev_epoch))
    [ "$age" -ge 0 ] || age=0
    [ "$age" -ge "$RESURFACE_SECS" ] || return 0
  fi

  key="dispatch:$(printf '%s' "$SIGNATURE" | cut -c1-12)"
  fm_wake_append check "$key" "$PAYLOAD" || exit 1
  record_write "$VERDICT" "$SIGNATURE" "$epoch" || exit 1
  printf 'actionable: %s\n' "$PAYLOAD"
}

# --- 1. the backlog file ----------------------------------------------------
#
# An absent backlog file is NOT an inability to evaluate. A home with no backlog
# has no queue to pull from, so "nothing is dispatchable" is the true answer and
# this check is simply inert there - a bare home must not be nagged every
# cadence about a file it was never meant to have. What must never be read as
# quiet is a backlog that EXISTS and cannot be read or cannot be parsed, and
# both of those are reported below. Session start separately prints an explicit
# ABSENT marker for every missing data file, so a deleted backlog is still
# visible where absence is the meaningful signal.
[ -e "$BACKLOG" ] || {
  VERDICT=none
  SIGNATURE=none
  surface
  exit 0
}
[ -f "$BACKLOG" ] || undecidable backlog-unreadable \
  "the backlog path is not a regular file: $BACKLOG"
cat "$BACKLOG" > /dev/null 2>&1 || undecidable backlog-unreadable \
  "the backlog file cannot be read: $BACKLOG"

# --- 2. the tool that owns backlog state ------------------------------------
#
# tasks-axi owns blocks, holds, and date gates. Re-deriving them here would make
# this a second owner of the backlog contract, so an absent tool is an inability
# to evaluate rather than a reason to guess. A manual backlog backend governs
# MUTATIONS; reading with the tool stays correct, and bin/fm-bootstrap.sh
# separately reports an incompatible build.
command -v tasks-axi >/dev/null 2>&1 || undecidable tasks-axi-unavailable \
  "tasks-axi is not on PATH, so dispatchable work cannot be established"

READY_OUT=$(tasks-axi ready --file "$BACKLOG" 2>&1) || undecidable tasks-axi-failed \
  "tasks-axi ready failed: $(printf '%s' "$READY_OUT" | head -1)"
case "$READY_OUT" in
  error:*|*$'\n'error:*) undecidable tasks-axi-failed \
    "tasks-axi ready reported an error: $(printf '%s' "$READY_OUT" | grep '^error:' | head -1)" ;;
esac

READY_DECLARED=$(printf '%s\n' "$READY_OUT" | sed -n 's/^ready\[\([0-9][0-9]*\)\]{.*/\1/p' | head -1)
if [ -z "$READY_DECLARED" ]; then
  if printf '%s\n' "$READY_OUT" | grep -q '^ready: 0 '; then
    READY_DECLARED=0
  else
    undecidable tasks-axi-unparseable \
      "tasks-axi ready produced no recognizable ready group"
  fi
fi

READY_IDS=$(printf '%s\n' "$READY_OUT" | awk '
  /^help\[/ { exit }
  /^ready\[/ { rows = 1; next }
  rows && /^[[:space:]]/ {
    line = $0
    sub(/^[[:space:]]+/, "", line)
    split(line, field, ",")
    if (field[1] != "") print field[1]
    next
  }
  { rows = 0 }
' | LC_ALL=C sort)

READY_PARSED=0
[ -z "$READY_IDS" ] || READY_PARSED=$(printf '%s\n' "$READY_IDS" | grep -c .)
[ "$READY_PARSED" = "$READY_DECLARED" ] || undecidable tasks-axi-unparseable \
  "tasks-axi ready declared $READY_DECLARED dispatchable rows but $READY_PARSED could be read"

# --- 3. the silent-zero cross-check -----------------------------------------
#
# A markdown backlog whose structure is damaged parses as an empty backlog and
# reports zero ready work with a clean exit, which is indistinguishable from a
# genuinely quiet queue. Two independent readers of the same bytes settle it:
# if the file plainly carries item lines while the tool sees no task in ANY
# state, the file and the parser disagree and the answer is not established.
# This runs only on the zero path, which is the only place the confusion exists.
if [ "$READY_DECLARED" -eq 0 ]; then
  ITEM_LINES=$(grep -c '^[-*][[:space:]]' "$BACKLOG" 2>/dev/null || printf '0')
  case "$ITEM_LINES" in ''|*[!0-9]*) ITEM_LINES=0 ;; esac
  if [ "$ITEM_LINES" -gt 0 ]; then
    LIST_OUT=$(tasks-axi list --file "$BACKLOG" 2>&1) || undecidable tasks-axi-failed \
      "tasks-axi list failed while cross-checking an empty ready set"
    LIST_TOTAL=$(printf '%s\n' "$LIST_OUT" | sed -n 's/^count: \([0-9][0-9]*\)$/\1/p' | head -1)
    case "$LIST_TOTAL" in
      ''|*[!0-9]*) undecidable tasks-axi-unparseable \
        "tasks-axi list produced no recognizable count while cross-checking an empty ready set" ;;
    esac
    [ "$LIST_TOTAL" -gt 0 ] || undecidable backlog-parse-disagreement \
      "$BACKLOG carries $ITEM_LINES item line(s) that tasks-axi cannot see at all"
  fi
  VERDICT=none
  SIGNATURE=none
  surface
  exit 0
fi

# --- 4. live work -----------------------------------------------------------
#
# Both the reported worker count and the exclusion below depend on reading every
# task record, so a record that cannot be read is an inability to enumerate live
# work rather than a record that silently does not count.
LIVE_WORKERS=0
UNDER_WAY=
for meta in "$STATE"/*.meta; do
  [ -e "$meta" ] || continue
  META_TEXT=$(cat "$meta" 2>/dev/null) || undecidable live-work-unreadable \
    "a task record cannot be read: $meta"
  META_ID=$(basename "$meta" .meta)
  UNDER_WAY="$UNDER_WAY $META_ID"
  case "$META_TEXT" in
    kind=secondmate|kind=secondmate$'\n'*|*$'\n'kind=secondmate|*$'\n'kind=secondmate$'\n'*) continue ;;
  esac
  LIVE_WORKERS=$((LIVE_WORKERS + 1))
done

# A queued item that already has a live task record cannot be dispatched again,
# whatever the backlog still says, so it is not reported as dispatchable.
DISPATCHABLE=
for id in $READY_IDS; do
  case " $UNDER_WAY " in
    *" $id "*) continue ;;
  esac
  DISPATCHABLE="$DISPATCHABLE $id"
done

if [ -z "$DISPATCHABLE" ]; then
  VERDICT=none
  SIGNATURE=none
  surface
  exit 0
fi

# --- 5. ready to go, or needs intake first ----------------------------------

brief_state() { # <id>
  local brief="$DATA/$1/brief.md" text
  [ -f "$brief" ] || { printf intake; return; }
  text=$(cat "$brief" 2>/dev/null) || { printf intake; return; }
  [ -n "$text" ] || { printf intake; return; }
  # A scaffold whose {TASK} placeholder is still unreplaced is not a brief: it
  # carries no task, and AGENTS.md section 11 makes replacing it part of intake.
  case "$text" in
    *'{TASK}'*) printf intake ;;
    *) printf briefed ;;
  esac
}

BRIEFED=
INTAKE=
BRIEFED_N=0
INTAKE_N=0
COUNT=0
SIG_BODY=
for id in $DISPATCHABLE; do
  COUNT=$((COUNT + 1))
  state=$(brief_state "$id")
  SIG_BODY="$SIG_BODY$id	$state
"
  if [ "$state" = briefed ]; then
    BRIEFED_N=$((BRIEFED_N + 1))
    [ "$BRIEFED_N" -gt "$LIST_LIMIT" ] || BRIEFED="$BRIEFED, $id"
  else
    INTAKE_N=$((INTAKE_N + 1))
    [ "$INTAKE_N" -gt "$LIST_LIMIT" ] || INTAKE="$INTAKE, $id"
  fi
done
BRIEFED=${BRIEFED#, }
INTAKE=${INTAKE#, }
[ -n "$BRIEFED" ] || BRIEFED=none
[ -n "$INTAKE" ] || INTAKE=none
[ "$BRIEFED_N" -le "$LIST_LIMIT" ] || BRIEFED="$BRIEFED (+$((BRIEFED_N - LIST_LIMIT)) more)"
[ "$INTAKE_N" -le "$LIST_LIMIT" ] || INTAKE="$INTAKE (+$((INTAKE_N - LIST_LIMIT)) more)"

# --- 6. the machine ---------------------------------------------------------

if [ -n "${FM_DISPATCH_OS_RESERVE_MB:-}" ]; then
  case "$FM_DISPATCH_OS_RESERVE_MB" in
    *[!0-9]*|'') undecidable os-reserve-invalid \
      "FM_DISPATCH_OS_RESERVE_MB is not a whole number of MiB: $FM_DISPATCH_OS_RESERVE_MB" ;;
  esac
  OS_RESERVE_KB=$((FM_DISPATCH_OS_RESERVE_MB * 1024))
else
  if [ "$(uname)" = Darwin ]; then
    MEM_BYTES=$(sysctl -n hw.memsize 2>/dev/null || true)
    case "$MEM_BYTES" in
      ''|*[!0-9]*) undecidable os-reserve-unmeasurable \
        "installed memory could not be read, so the operating-system reserve is unknown" ;;
    esac
    OS_RESERVE_KB=$((MEM_BYTES / 1024))
  else
    OS_RESERVE_KB=$(awk '/^MemTotal:/ {print $2; exit}' /proc/meminfo 2>/dev/null || true)
    case "$OS_RESERVE_KB" in
      ''|*[!0-9]*) undecidable os-reserve-unmeasurable \
        "installed memory could not be read, so the operating-system reserve is unknown" ;;
    esac
  fi
fi

POOL_ROOT=${FM_DISPATCH_POOL_ROOT:-}
if [ -z "$POOL_ROOT" ]; then
  if [ -n "${HOME:-}" ] && [ -d "$HOME/.treehouse" ]; then
    POOL_ROOT="$HOME/.treehouse"
  else
    POOL_ROOT="$FM_HOME"
  fi
fi
[ -d "$POOL_ROOT" ] || undecidable disk-unmeasurable \
  "the filesystem that would hold another isolated copy cannot be found: $POOL_ROOT"
DF_OUT=$(df -Pk "$POOL_ROOT" 2>/dev/null) || undecidable disk-unmeasurable \
  "free space on $POOL_ROOT could not be measured"
FREE_KB=$(printf '%s\n' "$DF_OUT" | awk 'NR == 2 {print $4}')
case "$FREE_KB" in
  ''|*[!0-9]*) undecidable disk-unmeasurable \
    "free space on $POOL_ROOT could not be read from df output" ;;
esac

# The clone measurement is cached because it is the one part of the floor that
# walks the disk; everything else in a scan is a handful of stats.
COPY_KB=
if [ -f "$COPY_CACHE" ]; then
  CACHE_MTIME=$(file_mtime "$COPY_CACHE" || true)
  case "$CACHE_MTIME" in
    ''|*[!0-9]*) : ;;
    *)
      CACHE_AGE=$(( $(now_epoch) - CACHE_MTIME ))
      [ "$CACHE_AGE" -ge 0 ] || CACHE_AGE=0
      if [ "$CACHE_AGE" -lt "$COPY_MEASURE_SECS" ]; then
        CACHED=$(cat "$COPY_CACHE" 2>/dev/null || true)
        case "$CACHED" in
          ''|*[!0-9]*) : ;;
          *) COPY_KB=$CACHED ;;
        esac
      fi
      ;;
  esac
fi
if [ -z "$COPY_KB" ]; then
  COPY_KB=0
  for clone in "$FM_HOME"/projects/*/; do
    [ -d "$clone" ] || continue
    # du reports its total even when it could not stat everything underneath, and
    # a live clone churns while it is walked, so the number is what matters here;
    # producing no number at all is the genuine inability.
    CLONE_KB=$(du -sk "$clone" 2>/dev/null | awk 'NR == 1 {print $1}')
    case "$CLONE_KB" in
      ''|*[!0-9]*) undecidable copy-reserve-unmeasurable \
        "the size of the project clone at $clone could not be measured" ;;
    esac
    [ "$CLONE_KB" -le "$COPY_KB" ] || COPY_KB=$CLONE_KB
  done
  TMP_CACHE=$(umask 077; mktemp "$STATE/.dispatch-copy-reserve.XXXXXX") || TMP_CACHE=
  if [ -n "$TMP_CACHE" ]; then
    if printf '%s\n' "$COPY_KB" > "$TMP_CACHE"; then
      mv -f "$TMP_CACHE" "$COPY_CACHE" || rm -f "$TMP_CACHE"
    else
      rm -f "$TMP_CACHE"
    fi
  fi
fi

FLOOR_KB=$((OS_RESERVE_KB + COPY_KB))
FREE_MIB=$((FREE_KB / 1024))
FLOOR_MIB=$((FLOOR_KB / 1024))

# --- 7. the verdict ---------------------------------------------------------

if [ "$FREE_KB" -lt "$FLOOR_KB" ]; then
  VERDICT=blocked
  SIGNATURE=$(printf 'blocked\n' | sig_hash)
  PAYLOAD="dispatch blocked: $COUNT dispatchable but no room for another isolated copy; disk free $FREE_MIB MiB against a $FLOOR_MIB MiB floor; live workers $LIVE_WORKERS"
else
  VERDICT=ready
  SIGNATURE=$(printf 'ready\n%s' "$SIG_BODY" | sig_hash)
  PAYLOAD="dispatch ready: $COUNT dispatchable ($BRIEFED_N briefed, $INTAKE_N need intake); briefed: $BRIEFED; needs intake: $INTAKE; live workers $LIVE_WORKERS; disk free $FREE_MIB MiB against a $FLOOR_MIB MiB floor; full list: tasks-axi ready --file $BACKLOG"
fi
surface
exit 0
