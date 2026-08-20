#!/usr/bin/env bash
# tests/fm-status-decision-close.test.sh - the deliberate close for status-log
# decisions, and the teardown refusal that makes it necessary.
#
# The hole these cover: bin/fm-send.sh's --resolve-key writes the closing
# `resolved [key=...]` line only after a crewmate's submit is CONFIRMED, so a
# decision whose worker is gone can be neither answered nor closed by any
# supported command - while bin/fm-teardown.sh deletes state/<id>.status and the
# question with it. The property under test is that no open decision leaves the
# record without something being written about why.
#
# Everything here runs the real executables and asserts through real consumers -
# bin/fm-wake-drain.sh's OPEN DECISIONS section for openness, the closer's own
# exit status and the status log for closure - never against implementation text.
#
#   (a) isolation proof: the fixture's git never resolves outside the fixture,
#       and the firstmate checkout this suite runs from is byte-identical after.
#   (b) a genuinely dead endpoint (real tmux on a private socket, window killed,
#       the backend's own reader reporting it gone) still leaves fm-send's
#       --resolve-key unable to close: the answer is not delivered and the
#       decision is still open. fm-send is unchanged by this work.
#   (c) the deliberate close closes that same decision, with its substance in the
#       log, against that same dead endpoint.
#   (d) both dispositions are recorded distinguishably, and one is mandatory.
#   (e) a key that matches nothing open refuses and prints what IS open.
#   (f) a reserved-namespace key refuses BEFORE writing, so a line the fold would
#       ignore never lands in an append-only log.
#   (g) teardown refuses while a decision is open, naming the open decision and
#       the command that closes it; closing it deliberately lets teardown run.
#   (h) teardown's refusal agrees with bin/fm-classify-lib.sh's fold on every
#       grammar case, including the misplaced-key fold to `default` - the two are
#       compared against the same logs rather than against each other's source.
#   (i) --force still completes, and writes what became of the open decision.
#   (j) --force refuses when that record cannot be written, rather than losing it.
set -u

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# Git exports its environment into every child, and GIT_DIR outranks `git -C
# <dir>`: a stray one turns a fixture's commit into a commit in whatever repo
# that variable names. This suite runs git by definition, so it strips the whole
# family for itself rather than assuming the runner did, and case (a) proves the
# result empirically instead of trusting the strip.
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_OBJECT_DIRECTORY \
  GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_COMMON_DIR GIT_NAMESPACE 2>/dev/null || true
export GIT_TERMINAL_PROMPT=0
fm_git_identity fmtest fmtest@example.invalid

CLOSE="$ROOT/bin/fm-status-decision-close.sh"
TEARDOWN="$ROOT/bin/fm-teardown.sh"
SEND="$ROOT/bin/fm-send.sh"
DRAIN="$ROOT/bin/fm-wake-drain.sh"

TMP_ROOT=$(fm_test_tmproot fm-status-decision-close)
# The physical path too: on macOS TMPDIR lives under the /var -> /private/var
# symlink, and git reports resolved paths.
TMP_ROOT_REAL=$(cd "$TMP_ROOT" && pwd -P)
# Stop git's upward repo search at the fixture root so no fixture command can
# discover an ancestor repository even if one ever existed above TMPDIR. Both
# spellings, because git matches this list literally.
export GIT_CEILING_DIRECTORIES="$TMP_ROOT:$TMP_ROOT_REAL"

# The firstmate checkout this suite runs from. Recorded now, compared in case (a).
CHECKOUT_HEAD_BEFORE=$(git -C "$ROOT" rev-parse HEAD)
CHECKOUT_STATUS_BEFORE=$(git -C "$ROOT" status --porcelain)

# --- fixtures ---------------------------------------------------------------

# A bare firstmate home: state/, data/, config/, and a fresh watcher beacon so
# fm-guard stays quiet. Echoes the home dir. Nothing here needs git.
make_home() {  # <name>
  local home="$TMP_ROOT/$1/home"
  mkdir -p "$home/state" "$home/data" "$home/config"
  touch "$home/state/.last-watcher-beat"
  printf '%s\n' "$home"
}

# Write a task's status log from the lines given after the id.
write_status() {  # <home> <id> <line>...
  local home=$1 id=$2 line
  shift 2
  : > "$home/state/$id.status"
  for line in "$@"; do
    printf '%s\n' "$line" >> "$home/state/$id.status"
  done
}

# Print the OPEN DECISIONS entry lines the drain emits for <id> (the section's
# own entries begin with the task id; the hint lines begin with "OPEN DECISIONS").
drain_entries() {  # <home> <id>
  local home=$1 id=$2
  FM_STATE_OVERRIDE="$home/state" "$DRAIN" 2>/dev/null \
    | grep -E "^${id}( |\$)" || true
}

run_close() {  # <home> <args>...
  local home=$1
  shift
  FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    "$CLOSE" "$@"
}

# --- (a) isolation proof ----------------------------------------------------

test_fixture_git_never_escapes_the_fixture() {
  local home case_dir top
  home=$(make_home isolation)
  case_dir=$(dirname "$home")
  mkdir -p "$case_dir/repo"
  git -C "$case_dir/repo" init -q
  git -C "$case_dir/repo" commit -q --allow-empty -m seed
  top=$(git -C "$case_dir/repo" rev-parse --show-toplevel)
  case "$top" in
    "$TMP_ROOT"/*|"$TMP_ROOT_REAL"/*) ;;
    *) fail "fixture git resolved outside the fixture root: $top" ;;
  esac
  # A directory that is NOT a repo must not resolve to one either: that is the
  # signature of an escape into an ancestor (or GIT_DIR-named) repository.
  if git -C "$case_dir" rev-parse --show-toplevel >/dev/null 2>&1; then
    fail "a non-repo fixture directory resolved to a git repository: $(git -C "$case_dir" rev-parse --show-toplevel)"
  fi
  pass "fixture git resolves only inside the fixture and never up into another repo"
}

# --- shared dead-endpoint fixture -------------------------------------------
#
# A REAL tmux server on a private socket. The task's recorded window is created
# and then killed, and the backend's own reader is asked to confirm it is gone,
# so "no live worker" is an observed fact about a real endpoint rather than an
# assumption written into a stub.
TMUX_SOCKET="fm-sdc-$$"
REAL_TMUX=$(command -v tmux 2>/dev/null || true)

tmux_cleanup() {
  [ -z "$REAL_TMUX" ] || "$REAL_TMUX" -L "$TMUX_SOCKET" kill-server >/dev/null 2>&1 || true
  fm_test_cleanup
}
trap tmux_cleanup EXIT
trap 'tmux_cleanup; exit 130' INT
trap 'tmux_cleanup; exit 143' TERM

# Echoes a shim dir holding a `tmux` that reaches only the private socket, so a
# fixture can never touch the developer's own sessions.
make_tmux_shim() {  # <case-dir>
  local shim="$1/shim"
  mkdir -p "$shim"
  cat > "$shim/tmux" <<SH
#!/usr/bin/env bash
exec "$REAL_TMUX" -L "$TMUX_SOCKET" "\$@"
SH
  chmod +x "$shim/tmux"
  printf '%s\n' "$shim"
}

# The backend's own recovery-grade endpoint reader, run over the shim.
endpoint_state() {  # <shim> <target>
  PATH="$1:$PATH" bash -c '
    . "$1/bin/fm-backend.sh"
    fm_backend_agent_state tmux "$2"
  ' _ "$ROOT" "$2"
}

test_dead_endpoint_blocks_fm_send_but_not_the_deliberate_close() {
  local home case_dir shim id target state out rc sleep_bin
  [ -n "$REAL_TMUX" ] || { echo "skip: tmux not found"; return 0; }
  id=ghost-routing
  home=$(make_home dead-endpoint)
  case_dir=$(dirname "$home")
  shim=$(make_tmux_shim "$case_dir")

  fm_write_meta "$home/state/$id.meta" \
    "window=fmsdc:fm-$id" \
    "endpoint_task_id=$id" \
    "worktree=$case_dir/wt" \
    "project=$case_dir/project" \
    "harness=claude" \
    "kind=ship" \
    "mode=no-mistakes"
  target="fmsdc:fm-$id"

  # Live first, so the fixture proves it can tell the two apart. The pane runs a
  # real long-lived process under a harness name (a SYMLINK, never a copy: a
  # copied platform binary fails code-signing validation on macOS arm64), so the
  # backend's classifier sees a genuine live agent rather than a bare shell.
  sleep_bin=$(command -v sleep) || { echo "skip: sleep not found"; return 0; }
  mkdir -p "$case_dir/harness"
  ln -sf "$sleep_bin" "$case_dir/harness/claude"
  PATH="$shim:$PATH" tmux new-session -d -s fmsdc -n "fm-$id" "$case_dir/harness/claude 600" \
    || fail "could not start the private tmux fixture session"
  state=$(endpoint_state "$shim" "$target")
  [ "$state" = alive ] || fail "fixture endpoint should be alive before the kill, got '$state'"

  PATH="$shim:$PATH" tmux kill-session -t fmsdc >/dev/null 2>&1
  state=$(endpoint_state "$shim" "$target")
  case "$state" in
    dead|missing) ;;
    *) fail "fixture endpoint should be gone after the kill, got '$state'" ;;
  esac

  write_status "$home" "$id" \
    'needs-decision [key=routing]: route ghosts through the queue or inline?' \
    'done: everything else finished'

  # fm-send is the answerer-closes path and stays exactly as it is: with nothing
  # left to deliver to, it must not close the decision.
  out=$(PATH="$shim:$PATH" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_SEND_RETRIES=1 FM_SEND_SLEEP=0 FM_SEND_SETTLE=0 \
    "$SEND" "$id" --resolve-key routing 'route them inline' 2>&1) && rc=0 || rc=$?
  [ "$rc" -ne 0 ] || fail "fm-send reported success against a dead endpoint: $out"
  grep -Fq 'resolved [key=routing]' "$home/state/$id.status" \
    && fail "fm-send closed a decision it could not deliver an answer to"
  drain_entries "$home" "$id" | grep -Fq '[key=routing]' \
    || fail "the decision should still be open after the undeliverable answer"

  # The deliberate close is the path that does not exist otherwise.
  run_close "$home" "$id" --key routing \
    --answered-elsewhere 'captain approved the queue route from his phone' \
    >/dev/null || fail "the deliberate close failed against a dead endpoint"

  grep -Fq 'captain approved the queue route from his phone' "$home/state/$id.status" \
    || fail "the substance of the close was not recorded in the status log"
  # This second drain reads through the cursor the first one left behind, so the
  # close has to be visible to the incremental fold the fleet actually runs, not
  # only to a whole-file re-read.
  if drain_entries "$home" "$id" | grep -Fq '[key=routing]'; then
    fail "the decision is still open after a deliberate close: $(drain_entries "$home" "$id")"
  fi
  pass "a decision on a genuinely dead endpoint resists fm-send and closes deliberately"
}

# --- (d) dispositions -------------------------------------------------------

test_dispositions_are_recorded_and_one_is_required() {
  local home rc out
  home=$(make_home dispositions)
  write_status "$home" t-moot 'blocked [key=vendor]: waiting on a vendor fix that was cancelled'
  write_status "$home" t-answered 'needs-decision [key=shape]: REST or gRPC'

  out=$(run_close "$home" t-moot --key vendor 2>&1) && rc=0 || rc=$?
  [ "$rc" -ne 0 ] || fail "a close with no disposition succeeded"
  assert_contains "$out" 'answered-elsewhere' "the no-disposition refusal should name both dispositions"
  grep -Fq resolved "$home/state/t-moot.status" \
    && fail "the no-disposition refusal still wrote to the log"

  run_close "$home" t-moot --key vendor --moot 'the vendor withdrew the change' >/dev/null \
    || fail "--moot close failed"
  run_close "$home" t-answered --key shape --answered-elsewhere 'gRPC, decided in chat' >/dev/null \
    || fail "--answered-elsewhere close failed"

  grep -Fq 'resolved [key=vendor]: moot: the vendor withdrew the change' "$home/state/t-moot.status" \
    || fail "the moot disposition was not recorded distinguishably: $(cat "$home/state/t-moot.status")"
  grep -Fq 'resolved [key=shape]: answered elsewhere: gRPC, decided in chat' "$home/state/t-answered.status" \
    || fail "the answered-elsewhere disposition was not recorded distinguishably: $(cat "$home/state/t-answered.status")"
  pass "each disposition is recorded distinguishably and one of them is mandatory"
}

# --- (e) key mismatch -------------------------------------------------------

test_unmatched_key_refuses_and_shows_what_is_open() {
  local home rc out before
  home=$(make_home unmatched-key)
  # The key is written AFTER the colon, so the fold holds `default` and NOT the
  # key an operator reads in the note. A close must say so, not guess.
  write_status "$home" t1 'needs-decision: [key=api-shape] pick REST or gRPC'
  before=$(cat "$home/state/t1.status")

  out=$(run_close "$home" t1 --key api-shape --moot 'never mind' 2>&1) && rc=0 || rc=$?
  [ "$rc" -ne 0 ] || fail "a key that matches nothing open reported success"
  assert_contains "$out" '[key=default]' "the refusal should show the key that IS open"
  assert_contains "$out" 'pick REST or gRPC' "the refusal should show the open decision's note"
  [ "$(cat "$home/state/t1.status")" = "$before" ] \
    || fail "an unmatched key still wrote to the status log"

  # The key the fold actually holds closes it.
  run_close "$home" t1 --key default --moot 'superseded by the platform decision' >/dev/null \
    || fail "closing the key the fold holds failed"
  if drain_entries "$home" t1 | grep -Fq 'needs-decision'; then
    fail "the decision is still open after closing its real key"
  fi
  pass "an unmatched key refuses, prints what IS open, and writes nothing"
}

# --- (f) reserved namespace -------------------------------------------------

test_reserved_namespace_refuses_before_writing() {
  local home rc out before
  home=$(make_home reserved)
  write_status "$home" t9 \
    'blocked [key=pending-reply-abcdef0123456789]: pending-reply-missed: task=ios request=ship it'
  before=$(cat "$home/state/t9.status")

  out=$(run_close "$home" t9 --key pending-reply-abcdef0123456789 --moot 'the mate was retired' 2>&1) && rc=0 || rc=$?
  [ "$rc" -ne 0 ] || fail "a close the fold would ignore reported success"
  assert_contains "$out" 'would not take effect' "the refusal should say the close would not take effect"
  [ "$(cat "$home/state/t9.status")" = "$before" ] \
    || fail "a close the fold would ignore still appended a misleading resolved line"
  drain_entries "$home" t9 | grep -Fq 'pending-reply-abcdef0123456789' \
    || fail "the reserved decision should still be open"
  pass "a close the fold would ignore refuses before writing anything"
}

# --- teardown fixture -------------------------------------------------------
#
# A landed ship task: a bare origin, a project clone, and a task worktree whose
# branch is pushed, so teardown's landed-work check passes and the open-decision
# gate is the only thing standing between it and cleanup.
make_teardown_case() {  # <name>
  local name=$1 case_dir home fakebin
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  fakebin="$case_dir/fakebin"
  mkdir -p "$home/state" "$home/data" "$home/config" "$fakebin"
  touch "$home/state/.last-watcher-beat"

  cat > "$fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  cat > "$fakebin/gh-axi" <<'SH'
#!/usr/bin/env bash
case "${1:-} ${2:-}" in
  "pr list") printf '%s\n' "count: 0 (showing first 0)" "pull_requests[]: []"; exit 0 ;;
  "pr view") echo "error: pull request not found" >&2; exit 1 ;;
esac
exit 0
SH
  cat > "$fakebin/gh" <<'SH'
#!/usr/bin/env bash
case "${1:-} ${2:-}" in
  "pr view") echo "error: pull request not found" >&2; exit 1 ;;
esac
exit 0
SH
  # Hermetic no-mistakes: no active run, so the pre-teardown abort is a no-op.
  cat > "$fakebin/no-mistakes" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  fm_fake_browser_tool "$fakebin"
  chmod +x "$fakebin/treehouse" "$fakebin/tmux" "$fakebin/gh-axi" "$fakebin/gh" "$fakebin/no-mistakes"

  git init -q --bare "$case_dir/origin.git"
  git -C "$case_dir/origin.git" symbolic-ref HEAD refs/heads/main
  git clone -q "$case_dir/origin.git" "$case_dir/_seed" 2>/dev/null
  git -C "$case_dir/_seed" commit -q --allow-empty -m "origin baseline"
  git -C "$case_dir/_seed" push -q origin main
  rm -rf "$case_dir/_seed"
  git clone -q "$case_dir/origin.git" "$case_dir/project"
  git -C "$case_dir/project" remote set-head origin main 2>/dev/null || true
  git -C "$case_dir/project" worktree add -q -b fm/task-x1 "$case_dir/wt" main

  fm_write_meta "$home/state/task-x1.meta" \
    "window=firstmate:fm-task-x1" \
    "endpoint_task_id=task-x1" \
    "worktree=$case_dir/wt" \
    "project=$case_dir/project" \
    "kind=ship" \
    "mode=no-mistakes"

  # Commit on the task branch and push it, so the work is provably landed and
  # only the decision gate can refuse.
  git -C "$case_dir/wt" commit -q --allow-empty -m "task work"
  git -C "$case_dir/wt" push -q origin fm/task-x1
  git -C "$case_dir/project" fetch -q origin

  printf '%s\n' "$case_dir"
}

run_teardown() {  # <case-dir> [args...]
  local case_dir=$1
  shift
  FM_ROOT_OVERRIDE="$ROOT" \
  FM_HOME="$case_dir/home" \
  FM_STATE_OVERRIDE="$case_dir/home/state" \
  FM_DATA_OVERRIDE="$case_dir/home/data" \
  FM_CONFIG_OVERRIDE="$case_dir/home/config" \
  FM_TEARDOWN_GUARD_DONE=1 \
  PATH="$case_dir/fakebin:$PATH" \
    "$TEARDOWN" task-x1 "$@"
}

# --- (g) the refusal --------------------------------------------------------

test_teardown_refuses_while_a_decision_is_open() {
  local case_dir rc out
  case_dir=$(make_teardown_case refuse)
  write_status "$case_dir/home" task-x1 \
    'needs-decision [key=api-shape]: pick REST or gRPC before the migration' \
    'done: everything else finished'

  out=$(run_teardown "$case_dir" 2>&1) && rc=0 || rc=$?
  [ "$rc" -ne 0 ] || fail "teardown completed with an open decision: $out"
  assert_contains "$out" 'REFUSED' "the open decision should produce a refusal"
  assert_contains "$out" '[key=api-shape]' "the refusal should name the open decision's key"
  assert_contains "$out" 'pick REST or gRPC before the migration' \
    "the refusal should name the open decision itself"
  assert_contains "$out" 'fm-status-decision-close.sh' \
    "the refusal should name the command that closes it"
  [ -f "$case_dir/home/state/task-x1.status" ] \
    || fail "a refused teardown removed the status log anyway"
  [ -d "$case_dir/wt" ] || fail "a refused teardown removed the worktree anyway"

  # Closing it deliberately is the way through.
  FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$case_dir/home" \
    FM_STATE_OVERRIDE="$case_dir/home/state" \
    "$CLOSE" task-x1 --key api-shape --answered-elsewhere 'gRPC, captain said so in chat' \
    >/dev/null || fail "the deliberate close failed on the teardown fixture"

  out=$(run_teardown "$case_dir" 2>&1) && rc=0 || rc=$?
  [ "$rc" -eq 0 ] || fail "teardown still refused after the decision was closed: $out"
  [ -f "$case_dir/home/state/task-x1.status" ] \
    && fail "a completed teardown left the status log behind"
  pass "teardown refuses while a decision is open, names the close, and runs once it is closed"
}

# --- (h) one grammar, two readers -------------------------------------------

test_refusal_agrees_with_the_fold_on_every_grammar_case() {
  local case_dir name lines expect_open out rc entries row rest
  # Each row: <name>|<expect-open: yes|no>|<line>::<line>...
  # The rows deliberately include the cases where the grammar is not obvious:
  # a later terminal line does not close a decision, a bare resolved closes only
  # `default`, and a key written after the colon folds to `default`.
  local -a rows=(
    'buried|yes|needs-decision [key=api-shape]: pick one::working: other work::done: shipped'
    'keyed-resolve|no|needs-decision [key=api-shape]: pick one::resolved [key=api-shape]: picked REST'
    'wrong-key-resolve|yes|needs-decision [key=api-shape]: pick one::resolved [key=other]: unrelated'
    'bare-resolve-closes-default|no|blocked: waiting on infra::resolved: infra came back'
    'bare-resolve-misses-keyed|yes|needs-decision [key=api-shape]: pick one::resolved: something else'
    'misplaced-key-folds-to-default|yes|needs-decision: [key=api-shape] pick one'
    'captain-held-closes|no|needs-decision [key=api-shape]: pick one::captain-held [key=api-shape]: moved to the backlog'
    'nothing-open|no|working: still going::done: shipped'
  )
  for row in "${rows[@]}"; do
    name=${row%%|*}
    rest=${row#*|}
    expect_open=${rest%%|*}
    lines=${rest#*|}
    case_dir=$(make_teardown_case "grammar-$name")
    : > "$case_dir/home/state/task-x1.status"
    while [ -n "$lines" ]; do
      case "$lines" in
        *::*) printf '%s\n' "${lines%%::*}" >> "$case_dir/home/state/task-x1.status"; lines=${lines#*::} ;;
        *) printf '%s\n' "$lines" >> "$case_dir/home/state/task-x1.status"; lines= ;;
      esac
    done

    entries=$(drain_entries "$case_dir/home" task-x1)
    out=$(run_teardown "$case_dir" 2>&1) && rc=0 || rc=$?

    if [ "$expect_open" = yes ]; then
      [ -n "$entries" ] \
        || fail "grammar $name: the fold's own consumer reports nothing open, so this row's expectation is wrong"
      [ "$rc" -ne 0 ] \
        || fail "grammar $name: the fold reports a decision open but teardown did not refuse: $out"
      assert_contains "$out" 'still has an open decision' \
        "grammar $name: teardown refused for some other reason than the open decision"
    else
      [ -z "$entries" ] \
        || fail "grammar $name: the fold's own consumer reports a decision open, so this row's expectation is wrong: $entries"
      case "$out" in
        *'still has an open decision'*)
          fail "grammar $name: the fold reports nothing open but teardown refused for an open decision: $out"
          ;;
      esac
    fi
  done
  pass "teardown's refusal agrees with the fold's own consumer on every grammar case"
}

# --- (i) --force records what it discards -----------------------------------

test_force_completes_and_records_the_discarded_decision() {
  local case_dir rc out record
  case_dir=$(make_teardown_case force-records)
  write_status "$case_dir/home" task-x1 \
    'needs-decision [key=api-shape]: pick REST or gRPC before the migration' \
    'blocked [key=infra]: the staging cluster is down'

  out=$(run_teardown "$case_dir" --force 2>&1) && rc=0 || rc=$?
  [ "$rc" -eq 0 ] || fail "--force teardown did not complete with an open decision: $out"

  record="$case_dir/home/data/task-x1/discarded-decisions.md"
  [ -f "$record" ] || fail "--force discarded an open decision without recording it"
  grep -Fq '[key=api-shape]' "$record" || fail "the discard record is missing the open decision's key"
  grep -Fq 'pick REST or gRPC before the migration' "$record" \
    || fail "the discard record is missing the open decision's substance"
  grep -Fq '[key=infra]' "$record" || fail "the discard record dropped the second open decision"
  grep -Fq 'forced teardown' "$record" || fail "the discard record does not say what happened to them"
  assert_contains "$out" "$record" "--force should tell the operator where the record went"
  [ -f "$case_dir/home/state/task-x1.status" ] \
    && fail "--force teardown left the status log behind"
  pass "--force completes and writes what became of every open decision"
}

# --- (j) an unwritable record refuses rather than losing the question --------

test_force_refuses_when_the_record_cannot_be_written() {
  local case_dir rc out
  case_dir=$(make_teardown_case force-unwritable)
  write_status "$case_dir/home" task-x1 \
    'needs-decision [key=api-shape]: pick REST or gRPC before the migration'
  # A non-regular file where the record belongs: writing would lose the question.
  mkdir -p "$case_dir/home/data/task-x1/discarded-decisions.md"

  out=$(run_teardown "$case_dir" --force 2>&1) && rc=0 || rc=$?
  [ "$rc" -ne 0 ] || fail "--force discarded an open decision it could not record: $out"
  assert_contains "$out" 'REFUSED' "an unrecordable discard should refuse"
  [ -f "$case_dir/home/state/task-x1.status" ] \
    || fail "an unrecordable discard removed the status log anyway"
  [ -d "$case_dir/wt" ] || fail "an unrecordable discard removed the worktree anyway"
  pass "--force refuses when the discard record cannot be written"
}

# --- (a, concluded) the checkout is untouched -------------------------------

test_checkout_is_unchanged_after_the_suite() {
  local head_after status_after
  head_after=$(git -C "$ROOT" rev-parse HEAD)
  status_after=$(git -C "$ROOT" status --porcelain)
  [ "$head_after" = "$CHECKOUT_HEAD_BEFORE" ] \
    || fail "the firstmate checkout's HEAD moved during the suite: $CHECKOUT_HEAD_BEFORE -> $head_after"
  [ "$status_after" = "$CHECKOUT_STATUS_BEFORE" ] \
    || fail "the firstmate checkout's working tree changed during the suite"
  pass "the firstmate checkout this suite runs from is unchanged"
}

test_fixture_git_never_escapes_the_fixture
test_dead_endpoint_blocks_fm_send_but_not_the_deliberate_close
test_dispositions_are_recorded_and_one_is_required
test_unmatched_key_refuses_and_shows_what_is_open
test_reserved_namespace_refuses_before_writing
test_teardown_refuses_while_a_decision_is_open
test_refusal_agrees_with_the_fold_on_every_grammar_case
test_force_completes_and_records_the_discarded_decision
test_force_refuses_when_the_record_cannot_be_written
test_checkout_is_unchanged_after_the_suite
