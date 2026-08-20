#!/usr/bin/env bash
# fm-status-decision-close.sh - close ONE open status-log decision deliberately,
# recording its substance, when there is no live worker to deliver an answer to.
#
# The object this owns is a keyed `needs-decision:`/`blocked:` record in
# state/<id>.status, closed by a `resolved [key=<key>]:` line.
# bin/fm-classify-lib.sh owns that open/resolved grammar and this script never
# restates it; every openness and closure question here is folded through that
# library. The structured captain holds owned by bin/fm-decision-hold.sh are a
# DIFFERENT object with their own completion gate, and this script neither reads
# nor writes them.
#
# Why it exists. bin/fm-send.sh's --resolve-key is the answerer-closes path and
# couples closure to a CONFIRMED submit, which is exactly right while a worker is
# there to answer. When that worker's endpoint is dead, missing, or already torn
# down, the same coupling leaves the decision unclosable by any supported command
# while the record itself keeps surfacing in OPEN DECISIONS (observed 2026-08-19:
# an approval tapped from a phone came back "text not submitted; delivery
# unconfirmed" because nothing was left in that terminal to answer to). This is
# the missing path, not a relaxation of that one: fm-send is unchanged.
#
# Usage:
#   fm-status-decision-close.sh <task-id> --key <key> --answered-elsewhere <text>
#   fm-status-decision-close.sh <task-id> --key <key> --moot <text>
#   fm-status-decision-close.sh -h | --help
#
# Exactly one disposition per invocation, and its text is mandatory:
#   --answered-elsewhere  the answer already exists somewhere else (the captain
#                         said it in chat, another task settled it) - record it
#                         here rather than inventing one or dropping the question.
#   --moot                an explicit statement that the decision no longer needs
#                         an answer, and why.
# One key per invocation, and no --all: a decision closed in a batch is a decision
# nobody wrote a reason for. Auto-closing is the only disposition that can
# silently destroy a question nobody has put to the captain yet.
#
# Endpoint liveness is deliberately NOT consulted. Coupling closure to endpoint
# state is what produced the hole this closes, and what makes a close correct is
# the recorded substance, not whether a pane happens to exist - a live worker
# whose decision has genuinely gone moot is a real case too. Prefer
# `fm-send.sh --resolve-key` whenever there IS a worker to answer, so the answer
# reaches it as well as the ledger.
#
# Refusals, none of which write anything:
#   - the named key is not open right now (already closed, mistyped, or
#     transferred): prints what IS open for that task instead of guessing. A key
#     written AFTER the colon of a status line folds to `default`, so the key an
#     operator reads in a human note is not always the key the fold holds.
#   - the closing line would not take effect per the fold: a reserved key
#     namespace transitions only on its owner's vocabulary, and this is checked
#     BEFORE the append so a line the fold ignores never lands in the log.
#   - another lifecycle action holds the task's control lock.
#
# Exit status is 0 only after the closing line is written and the fold agrees the
# decision is closed.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

# shellcheck source=bin/fm-classify-lib.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/fm-classify-lib.sh"
# shellcheck source=bin/fm-line-cap-lib.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/fm-line-cap-lib.sh"
# shellcheck source=bin/fm-pr-lib.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-wake-lib.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-gate-refuse-lib.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/fm-gate-refuse-lib.sh"

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0"
}

fail() {
  printf 'fm-status-decision-close: %s\n' "$*" >&2
  exit 1
}

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
esac

# Fail closed before any durable mutation: a no-mistakes gate agent must never
# write into a task's decision ledger (see bin/fm-gate-refuse-lib.sh).
fm_refuse_if_gate_agent

ID=${1:-}
[ -n "$ID" ] || fail "usage: fm-status-decision-close.sh <task-id> --key <key> (--answered-elsewhere <text> | --moot <text>)"
fm_task_id_path_safe "$ID" || fail "invalid task id '$ID'"
shift

KEY=
DISPOSITION=
SUBSTANCE=
set_disposition() {  # <--flag> <text>
  [ -z "$DISPOSITION" ] || fail "pass exactly one of --answered-elsewhere or --moot"
  [ -n "$2" ] || fail "$1 requires the text that closes the decision"
  DISPOSITION=${1#--}
  SUBSTANCE=$2
}
while [ $# -gt 0 ]; do
  case "$1" in
    --key)
      [ $# -ge 2 ] || fail "--key requires a decision key"
      [ -z "$KEY" ] || fail "pass exactly one --key; close each decision with its own reason"
      KEY=$2
      shift 2
      ;;
    --key=*)
      [ -z "$KEY" ] || fail "pass exactly one --key; close each decision with its own reason"
      KEY=${1#--key=}
      shift
      ;;
    --answered-elsewhere|--moot)
      [ $# -ge 2 ] || fail "$1 requires the text that closes the decision"
      set_disposition "$1" "$2"
      shift 2
      ;;
    --answered-elsewhere=*|--moot=*)
      set_disposition "${1%%=*}" "${1#*=}"
      shift
      ;;
    -h|--help) usage; exit 0 ;;
    *) fail "unknown argument '$1'" ;;
  esac
done

[ -n "$KEY" ] || fail "--key is required; the OPEN DECISIONS listing names each open key"
case "$KEY" in
  ''|*[!A-Za-z0-9._-]*)
    fail "--key '$KEY' is not a valid decision key (allowed: A-Z a-z 0-9 . _ -)"
    ;;
esac
[ -n "$DISPOSITION" ] || fail "pass --answered-elsewhere '<the answer>' or --moot '<why it no longer needs one>'; a decision closed with no reason is a decision lost"

STATUS="$STATE/$ID.status"

# Serialize against the lifecycle actions that remove this exact status file, so
# a close can never resurrect the ledger of a task teardown is erasing.
CONTROL_LOCK="$STATE/.control-$ID.lock"
CONTROL_LOCK_HELD=0
release_control_lock() {
  local status=$?
  if [ "$CONTROL_LOCK_HELD" = 1 ]; then
    fm_lock_release "$CONTROL_LOCK" || true
    CONTROL_LOCK_HELD=0
  fi
  return "$status"
}
trap release_control_lock EXIT
fm_lock_try_acquire "$CONTROL_LOCK" \
  || fail "another lifecycle action is already running for task $ID; nothing was changed"
CONTROL_LOCK_HELD=1

# Print the task's currently open decisions, so a refusal shows what IS open
# rather than leaving the operator to guess which key the fold actually holds.
print_open_set() {  # <open-set>
  local key verb note
  if [ -z "$1" ]; then
    printf 'No decision is open for %s in %s.\n' "$ID" "$STATUS" >&2
    return 0
  fi
  printf 'Open right now for %s:\n' "$ID" >&2
  while IFS=$'\t' read -r key verb note; do
    [ -n "$key" ] || continue
    printf '  [key=%s] %s: %s\n' "$key" "$verb" "$note" >&2
  done <<EOF
$1
EOF
}

[ -e "$STATUS" ] || fail "task $ID has no status log at $STATUS; there is no decision here to close"
[ ! -L "$STATUS" ] && [ -f "$STATUS" ] && [ -r "$STATUS" ] \
  || fail "status log $STATUS is not a readable regular file; refusing to write into it"

OPEN=$(status_open_decisions "$STATUS")
case "$OPEN" in
  "$KEY"$'\t'*|*$'\n'"$KEY"$'\t'*) ;;
  *)
    print_open_set "$OPEN"
    fail "no open decision or blocker with key '$KEY' in $STATUS (already closed, mistyped, or transferred); nothing was written"
    ;;
esac

# Same one-line shape and sanitization the answerer-closes path writes, so both
# closers leave a log a single reader can parse. The disposition token is what
# distinguishes a close made without delivery from fm-send's "answered:".
NOTE=$(printf '%s' "$SUBSTANCE" | tr '\n\r\t' '   ' | LC_ALL=C tr -d '\000-\037\177')
NOTE=${NOTE#"${NOTE%%[![:space:]]*}"}
NOTE=${NOTE%"${NOTE##*[![:space:]]}"}
[ -n "$NOTE" ] \
  || fail "the text for --$DISPOSITION is empty once control characters are stripped; a decision closed with no reason is a decision lost"
case "$DISPOSITION" in
  answered-elsewhere) NOTE="answered elsewhere: $NOTE" ;;
  moot) NOTE="moot: $NOTE" ;;
esac
fm_cap_line_var "resolved [key=$KEY]: $NOTE"
LINE=$FM_LINE_CAP_LINE

# Prove the append takes effect BEFORE making it: the fold, not this script,
# decides whether a line closes a key, and a line it would ignore must never
# land in an append-only log next to the decision it claims to have closed.
status_line_closes_key "$OPEN" "$LINE" "$KEY" || {
  print_open_set "$OPEN"
  fail "this close would not take effect on key '$KEY': that key transitions only on its owning namespace's own vocabulary, so close it through the owner that opened it; nothing was written"
}

printf '%s\n' "$LINE" >> "$STATUS" \
  || fail "could not append the closing line to $STATUS; decision '$KEY' is still open"

printf 'closed %s decision [key=%s] in %s\n' "$ID" "$KEY" "$STATUS"
printf '%s\n' "$LINE"
