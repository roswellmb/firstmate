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
# ONE SCAN AT A TIME. The whole scan runs under a per-home lock in the state
# directory, because surfacing a verdict is a read-modify-write of
# state/.dispatch-poll and two concurrent scans would both read the same stale
# signature and both queue a wake for one verdict. The lock is NON-blocking: a
# scan that finds it held exits 0 silently, because the holder is computing the
# identical verdict and a second wake for it is exactly the duplicate this check
# exists to avoid. Neither the watcher poll loop nor the synchronous session
# start ever waits on it.
#
# NO REPEATS. A verdict is surfaced only when its signature differs from the one
# last surfaced (state/.dispatch-poll). "Changed" means the set of dispatchable
# task ids changed, or one of them gained or lost a usable brief - the two facts
# that change what firstmate would actually do. It deliberately does NOT include
# titles or notes, so editing a note is not a wake. A blocked or unknown verdict
# additionally re-surfaces once per FM_DISPATCH_RESURFACE_SECS, because a fault
# that goes quiet forever is how a fault rots invisibly; an unchanged ready set
# never re-surfaces on that cadence. The durable wake record is keyed by the
# CONSTANT string "dispatch", not by the signature, so the drain's kind+key
# collapse keeps only the newest verdict: a superseded verdict describes a ready
# set that no longer exists and must never be presented as its own row.
#
# NOTHING RUNS UNBOUNDED, AND THE BOUNDS DO NOT COMPOSE. A scan performs exactly
# THREE bounded units of work, each capped at FM_DISPATCH_BUDGET_SECS through
# bin/fm-timeout-lib.sh: the tasks-axi ready read, the tasks-axi list
# cross-check, and the whole copy measurement. The copy measurement walks an
# unbounded number of directories, so it gets ONE AGGREGATE deadline rather than
# a bound per directory: the deadline is computed once, and each du runs under
# whatever remains of it. A per-directory bound would multiply without limit and
# let many individually-legal walks add up past the caller's backstop, which
# would turn a reportable timeout back into silence. Hitting any of the three is
# REPORTED as its own inability class (backlog-tool-timed-out,
# copy-reserve-timed-out) rather than silently killed.
#
# The two call sites bound the whole scan as well, and they size that backstop
# differently on purpose. bin/fm-watch.sh has no enclosing deadline, so its
# backstop sits above three times the largest legal FM_DISPATCH_BUDGET_SECS and
# therefore cannot preempt an inner bound. bin/fm-session-start.sh runs inside
# its own total startup budget at an early stage, so a backstop long enough to
# never preempt an inner bound would instead let a hung scan truncate the whole
# digest; it deliberately takes a short bound derived from that enclosing budget,
# accepting that it can cut a slow scan short. Nothing is lost when it does: the
# scan is idempotent, holds no lock afterwards, and the watcher runs the same
# scan on its own cadence where the inner bound gets to report.
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
#   2. The cost of ONE more isolated working copy, taken as the largest single
#      copy on disk across two sources, whichever is bigger. A live pool
#      worktree carries build output that a bare clone does not, so the pool is
#      the truer measure of what one more copy costs; projects/ is the fallback
#      that still yields a number on a machine that has never dispatched
#      anything. Taking the maximum means neither an empty pool nor an empty
#      projects directory can silently produce a zero.
#
#      THE TWO SOURCES ARE READ AT DIFFERENT DEPTHS, because a copy sits at a
#      different depth in each. Under $FM_HOME/projects a clone IS the immediate
#      child, so that source is read at CHILD depth. Under the pool root the
#      layout is <pool-root>/<repo>-<hash>/<N>: the immediate child is a per-repo
#      POOL holding several worktrees, and one isolated copy is the numbered
#      directory below it, so that source is read at GRANDCHILD depth. Measuring
#      a pool would report the sum of every worktree in it as the cost of one
#      copy, which on this fleet overstates it by more than half and widens the
#      deadband below by the same factor. A pool-root child that holds no
#      subdirectory of its own is taken as a copy itself, so a pool root that
#      holds copies directly still yields a number.
#
#      Measured at most once per FM_DISPATCH_COPY_MEASURE_SECS and cached, so
#      the ordinary scan is a df. A directory that yields no number at all from
#      du is an inability, never a zero. When the pool root is only the $FM_HOME
#      fallback - no configured pool root and no $HOME/.treehouse - its children
#      are the home's own directories rather than a pool, so only projects/ is
#      measured there; a fallback pool root is a filesystem handle for df.
#      If BOTH sources hold no measurable copy the clone reserve is 0, the floor
#      degrades to the operating-system reserve alone, and the deadband below
#      degrades to zero. That is the honest answer for a home that has never
#      made an isolated copy, not an inability: there is no measured per-copy
#      cost to report and the check must not invent one. The reported evidence
#      names the clone reserve in every verdict, so a reader can see the zero.
# There is deliberately NO cap on the number of live workers. AGENTS.md section
# 7 already forbids a concurrency cap for independently validatable work, so a
# number here would be firstmate policy smuggled into a shell script - and a
# limit derived from how much is running is exactly the circular rule this
# design is meant to avoid. The live-worker count is reported as evidence and
# gates nothing.
#
# THE CAPACITY DEADBAND. A bare comparison against the floor flaps: a build or a
# pool warm cycle pushes free space across the line and back, and every crossing
# is a genuine signature change that costs a firstmate turn with nothing new to
# do. The boundary is therefore sticky in one direction. ENTERING blocked keeps
# the plain test, free below the floor. LEAVING it requires free space to exceed
# the floor by one more copy, so the release threshold is floor plus copy. That
# unit is measured from the pool rather than chosen, because one dispatch costs
# roughly one isolated copy - the deadband moves in the same unit as the thing
# it is damping.
#
# The boundary has its OWN durable field, capacity_blocked, and the deadband
# reads that field and never the verdict field. The verdict is overwritten by
# every none and every unknown, and reading it would mean an emptied ready set
# or one transient timeout silently erased the boundary and let the next scan
# flip to ready with the disk in the state that was blocked a minute earlier.
# capacity_blocked is set only when a CAPACITY evaluation concludes blocked, is
# cleared only when a capacity evaluation concludes ready - which means free
# space genuinely cleared floor plus one copy - and is carried through unchanged
# by every record write that does not evaluate capacity.
#
# Environment overrides (all optional):
#   FM_DISPATCH_POOL_ROOT           pool root: df'd for free space, and walked
#                                   at grandchild depth for the copy size
#   FM_DISPATCH_OS_RESERVE_MB       operating-system reserve, in MiB
#   FM_DISPATCH_BUDGET_SECS         bound per bounded unit, 1..30, default 20
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
SCAN_LOCK="$STATE/.dispatch-poll.lock"

# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-timeout-lib.sh
. "$SCRIPT_DIR/fm-timeout-lib.sh"

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
    printf 'schema=fm-dispatch-poll.v2\n'
    printf 'verdict=%s\n' "$1"
    printf 'signature=%s\n' "$2"
    printf 'surfaced_epoch=%s\n' "$3"
    printf 'capacity_blocked=%s\n' "$CAPACITY_BLOCKED"
  } > "$tmp" || { rm -f "$tmp"; return 1; }
  mv -f "$tmp" "$RECORD" || { rm -f "$tmp"; return 1; }
}

# --- one scan at a time -----------------------------------------------------
#
# Taken before the previous verdict is read, so the read-decide-write cycle
# below observes a record no other scan can move underneath it.
fm_lock_try_acquire "$SCAN_LOCK" || exit 0
trap 'fm_lock_release "$SCAN_LOCK"' EXIT

# The previous record is read ONCE, here; two reads could straddle a rewrite.
# CAPACITY_BLOCKED starts as whatever the last capacity evaluation concluded and
# is changed ONLY by another capacity evaluation, so every record written by a
# none or unknown verdict carries the boundary through untouched. A record
# predating this field, or no record at all, means no boundary is in force.
PREV_VERDICT=$(record_value verdict)
PREV_SIG=$(record_value signature)
PREV_EPOCH=$(record_value surfaced_epoch)
case "$PREV_EPOCH" in ''|*[!0-9]*) PREV_EPOCH=0 ;; esac
CAPACITY_BLOCKED=$(record_value capacity_blocked)
[ "$CAPACITY_BLOCKED" = yes ] || CAPACITY_BLOCKED=no

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
  local epoch age
  epoch=$(now_epoch)

  if [ "$VERDICT" = none ]; then
    # Nothing to say, and nothing to remember either: a home that has never
    # surfaced a verdict stays untouched rather than acquiring a record that
    # only says "still quiet".
    if [ -n "$PREV_VERDICT" ] && [ "$PREV_VERDICT" != none ]; then
      record_write none "$SIGNATURE" "$epoch" || exit 1
    fi
    return 0
  fi

  if [ "$SIGNATURE" = "$PREV_SIG" ] && [ -n "$PREV_SIG" ]; then
    # An unchanged ready set is never repeated. A persisting fault or a
    # persisting lack of room re-surfaces only on the bounded cadence.
    [ "$VERDICT" = ready ] && return 0
    age=$((epoch - PREV_EPOCH))
    [ "$age" -ge 0 ] || age=0
    [ "$age" -ge "$RESURFACE_SECS" ] || return 0
  fi

  # The key is constant on purpose. fm_wake_print_deduped collapses queued
  # records on kind+key and keeps the newest per key, which is exactly right
  # here: only the latest verdict is true. The signature stays in the record
  # above, where it belongs, as the change detector.
  fm_wake_append check dispatch "$PAYLOAD" || exit 1
  record_write "$VERDICT" "$SIGNATURE" "$epoch" || exit 1
  printf 'actionable: %s\n' "$PAYLOAD"
}

# --- 0. the per-call bound --------------------------------------------------
#
# An unusable bound is rejected rather than quietly replaced by the default: a
# bound that is not what the operator asked for is a fact this check could not
# establish, and every one of those is reported. A non-positive value is not a
# bound at all - `timeout 0` and the perl fallback's `alarm 0` both disable the
# deadline outright - so zero is rejected with the rest.
BUDGET_SECS=${FM_DISPATCH_BUDGET_SECS:-20}
case "$BUDGET_SECS" in
  ''|*[!0-9]*|0) undecidable budget-invalid \
    "FM_DISPATCH_BUDGET_SECS must be a whole number of seconds from 1 to 30: $BUDGET_SECS" ;;
esac
[ "$BUDGET_SECS" -le 30 ] || undecidable budget-invalid \
  "FM_DISPATCH_BUDGET_SECS must be a whole number of seconds from 1 to 30: $BUDGET_SECS"

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

READY_OUT=$(fm_run_timed "$BUDGET_SECS" tasks-axi ready --file "$BACKLOG" 2>&1)
READY_RC=$?
[ "$READY_RC" -ne 124 ] || undecidable backlog-tool-timed-out \
  "tasks-axi ready did not finish within ${BUDGET_SECS}s and was stopped"
[ "$READY_RC" -eq 0 ] || undecidable tasks-axi-failed \
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
    LIST_OUT=$(fm_run_timed "$BUDGET_SECS" tasks-axi list --file "$BACKLOG" 2>&1)
    LIST_RC=$?
    [ "$LIST_RC" -ne 124 ] || undecidable backlog-tool-timed-out \
      "tasks-axi list did not finish within ${BUDGET_SECS}s while cross-checking an empty ready set"
    [ "$LIST_RC" -eq 0 ] || undecidable tasks-axi-failed \
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
#
# An absent brief and an empty brief are genuine answers: there is no brief, so
# the task needs intake. A brief that EXISTS and cannot be read is neither - it
# is an inability to establish the fact, and calling it "needs intake" would
# tell firstmate to write a brief that already exists while never naming the
# unreadable file. The caller routes that third answer to `undecidable`, which
# is why this prints a state rather than deciding one.
brief_state() { # <id>
  local brief="$DATA/$1/brief.md" text
  [ -f "$brief" ] || { printf intake; return; }
  text=$(cat "$brief" 2>/dev/null) || { printf unreadable; return; }
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
  [ "$state" != unreadable ] || undecidable brief-unreadable \
    "a brief exists but cannot be read: $DATA/$id/brief.md"
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

# A configured pool root, or the real one, is a pool directory whose contents are
# measured as isolated copies at the depth rule the header states. The $FM_HOME
# fallback is not: it is only a filesystem handle so df has a path, and its
# children are the home's own state, data, and projects directories.
POOL_ROOT=${FM_DISPATCH_POOL_ROOT:-}
POOL_HOLDS_COPIES=1
if [ -z "$POOL_ROOT" ]; then
  if [ -n "${HOME:-}" ] && [ -d "$HOME/.treehouse" ]; then
    POOL_ROOT="$HOME/.treehouse"
  else
    POOL_ROOT="$FM_HOME"
    POOL_HOLDS_COPIES=0
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

# The whole measurement shares ONE deadline, set once below, and each du runs
# under whatever remains of it. du reports its total even when it could not stat
# everything underneath, and a live copy churns while it is walked, so the
# number is what matters here; producing no number at all is the genuine
# inability, and so is running the shared deadline out.
MEASURED_KB=0
COPY_DEADLINE=0
measure_copy() { # <copy-dir>
  local copy=$1 copy_kb du_out du_rc remaining
  remaining=$((COPY_DEADLINE - $(now_epoch)))
  [ "$remaining" -gt 0 ] || undecidable copy-reserve-timed-out \
    "measuring the isolated copies did not finish within ${BUDGET_SECS}s; stopped at $copy"
  du_out=$(fm_run_timed "$remaining" du -sk "$copy" 2>/dev/null)
  du_rc=$?
  [ "$du_rc" -ne 124 ] || undecidable copy-reserve-timed-out \
    "measuring the isolated copy at $copy did not finish within the ${BUDGET_SECS}s measurement budget"
  copy_kb=$(printf '%s\n' "$du_out" | awk 'NR == 1 {print $1}')
  case "$copy_kb" in
    ''|*[!0-9]*) undecidable copy-reserve-unmeasurable \
      "the size of the isolated copy at $copy could not be measured" ;;
  esac
  [ "$copy_kb" -le "$MEASURED_KB" ] || MEASURED_KB=$copy_kb
}

# A project clone IS the immediate child of $FM_HOME/projects.
measure_project_clones() { # <projects-dir>
  local parent=$1 clone
  [ -d "$parent" ] || return 0
  for clone in "$parent"/*/; do
    [ -d "$clone" ] || continue
    measure_copy "$clone"
  done
}

# A pool-root child is a per-repo POOL, and one isolated copy is the numbered
# directory below it, so this reads a level deeper. A child holding no
# subdirectory of its own is taken as a copy itself, so a pool root that holds
# copies directly still yields a number.
measure_pool_copies() { # <pool-root>
  local parent=$1 pool copy found
  [ -d "$parent" ] || return 0
  for pool in "$parent"/*/; do
    [ -d "$pool" ] || continue
    found=0
    for copy in "$pool"*/; do
      [ -d "$copy" ] || continue
      found=1
      measure_copy "$copy"
    done
    [ "$found" -eq 1 ] || measure_copy "$pool"
  done
}

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
  COPY_DEADLINE=$(( $(now_epoch) + BUDGET_SECS ))
  if [ "$POOL_HOLDS_COPIES" -eq 1 ]; then
    measure_pool_copies "$POOL_ROOT"
  fi
  measure_project_clones "$FM_HOME/projects"
  COPY_KB=$MEASURED_KB
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
# One more copy of room above the floor before a blocked boundary is released.
# With no measurable copy anywhere the deadband is zero and the test below is
# the plain one.
RELEASE_KB=$((FLOOR_KB + COPY_KB))
FREE_MIB=$((FREE_KB / 1024))
FLOOR_MIB=$((FLOOR_KB / 1024))
RELEASE_MIB=$((RELEASE_KB / 1024))
COPY_MIB=$((COPY_KB / 1024))

# --- 7. the verdict ---------------------------------------------------------

if [ "$CAPACITY_BLOCKED" = yes ]; then
  THRESHOLD_KB=$RELEASE_KB
else
  THRESHOLD_KB=$FLOOR_KB
fi

if [ "$FREE_KB" -lt "$THRESHOLD_KB" ]; then
  CAPACITY_BLOCKED=yes
  VERDICT=blocked
  SIGNATURE=$(printf 'blocked\n' | sig_hash)
  PAYLOAD="dispatch blocked: $COUNT dispatchable but no room for another isolated copy; disk free $FREE_MIB MiB against a $FLOOR_MIB MiB floor, and $RELEASE_MIB MiB is the release threshold; clone reserve $COPY_MIB MiB; live workers $LIVE_WORKERS"
else
  CAPACITY_BLOCKED=no
  VERDICT=ready
  SIGNATURE=$(printf 'ready\n%s' "$SIG_BODY" | sig_hash)
  PAYLOAD="dispatch ready: $COUNT dispatchable ($BRIEFED_N briefed, $INTAKE_N need intake); briefed: $BRIEFED; needs intake: $INTAKE; live workers $LIVE_WORKERS; disk free $FREE_MIB MiB against a $FLOOR_MIB MiB floor; clone reserve $COPY_MIB MiB; full list: tasks-axi ready --file $BACKLOG"
fi
surface
exit 0
