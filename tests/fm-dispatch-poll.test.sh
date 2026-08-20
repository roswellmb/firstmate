#!/usr/bin/env bash
# Behavioral coverage for the dispatch-readiness pull check.
#
# The check exists so that work becoming dispatchable WAKES firstmate instead of
# waiting to be noticed. These cases pin the three things that make that signal
# worth reading: it is silent when nothing is dispatchable, it speaks ONLY when
# something actionable appeared (bin/fm-dispatch-poll.sh owns that definition -
# a gain in the dispatchable-and-briefed set), and it REPORTS rather than goes
# silent when it cannot establish an answer. That last one is the whole value of
# the check: silence must mean "nothing is ready", never "I could not tell".
#
# tasks-axi owns backlog state (blocks, holds, date gates), so the cases that
# need a real dispatchable set use the real tool and skip without it. The
# cannot-evaluate cases deliberately do NOT need it - one of them proves the
# check reports when the tool is missing.
set -u

# wake-helpers.sh pulls in tests/lib.sh and, for the watcher case at the bottom,
# neutralizes the tangle banner and the real desktop wedge alarm.
# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"

POLL="$ROOT/bin/fm-dispatch-poll.sh"
TMP_ROOT=$(fm_test_tmproot fm-dispatch-poll)

have_tasks_axi() { command -v tasks-axi >/dev/null 2>&1; }

skip_case() { # <name> <why>
  printf 'ok - %s (skipped: %s)\n' "$1" "$2"
}

# make_home <name>: a bare firstmate home with the standard child directories,
# plus a poisoned fakebin. Anything that could start, place, or touch a worker
# is replaced by a recorder that also fails, so a scan that reaches for one both
# leaves evidence and cannot succeed quietly.
make_home() { # <name>
  local name=$1 tool
  HOME_DIR="$TMP_ROOT/$name"
  STATE="$HOME_DIR/state"
  DATA="$HOME_DIR/data"
  FAKEBIN="$HOME_DIR/fakebin"
  SPAWN_LOG="$HOME_DIR/spawn.log"
  mkdir -p "$STATE" "$DATA" "$HOME_DIR/config" "$HOME_DIR/projects" "$FAKEBIN"
  : > "$SPAWN_LOG"
  for tool in fm-spawn.sh fm-send.sh fm-control.sh fm-brief.sh treehouse tmux herdr zellij git; do
    cat > "$FAKEBIN/$tool" <<SH
#!/usr/bin/env bash
printf '%s %s\n' "\$(basename "\$0")" "\$*" >> "$SPAWN_LOG"
exit 91
SH
    chmod +x "$FAKEBIN/$tool"
  done
}

# scan: run one scan against the current home with a deterministic capacity
# floor, and capture stdout plus the exit code. A case varies the run through
# the OS_RESERVE_MB, RESURFACE_SECS, and FM_DISPATCH_POOL_ROOT_OVERRIDE
# variables rather than arguments, so the same call site reads identically
# whichever fact a case is driving.
scan() {
  SCAN_OUT=$(PATH="$FAKEBIN:$PATH" \
    FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$STATE" \
    FM_DISPATCH_POOL_ROOT="${FM_DISPATCH_POOL_ROOT_OVERRIDE:-$HOME_DIR}" \
    FM_DISPATCH_OS_RESERVE_MB="${OS_RESERVE_MB:-1}" \
    FM_DISPATCH_RESURFACE_SECS="${RESURFACE_SECS:-99999}" \
    "$POLL" scan 2>&1)
  SCAN_CODE=$?
  printf '%s' "$SCAN_OUT"
}

# free_kb_of <path>: the volume's own free space, read with its own df so a case
# can size a floor against the real number rather than a guess.
free_kb_of() {
  df -Pk "$1" | awk 'NR == 2 {print $4}'
}

wakes() { # count queued wake records mentioning dispatch
  grep -c 'dispatch' "$STATE/.wake-queue" 2>/dev/null || printf '0\n'
}

add_task() { # <id> <title>
  tasks-axi add "$1" "$2" --file "$DATA/backlog.md" >/dev/null 2>&1 \
    || fail "fixture: could not add task $1"
}

give_brief() { # <id>
  mkdir -p "$DATA/$1"
  printf '# Brief\n\nReal task text for %s.\n' "$1" > "$DATA/$1/brief.md"
}

# --- silence when nothing is dispatchable -----------------------------------

test_silent_with_empty_backlog() {
  have_tasks_axi || { skip_case silent-empty-backlog "tasks-axi not found"; return 0; }
  make_home silent-empty
  add_task solo "only task"
  tasks-axi "done" solo --file "$DATA/backlog.md" >/dev/null 2>&1 || true
  scan >/dev/null
  expect_code 0 "$SCAN_CODE" "empty ready set did not exit 0"
  [ -z "$SCAN_OUT" ] || fail "empty ready set printed a line: $SCAN_OUT"
  [ "$(wakes)" = 0 ] || fail "empty ready set queued a wake"
  pass "silent when nothing is dispatchable"
}

# --- the signal itself ------------------------------------------------------

test_dispatchable_work_wakes() {
  have_tasks_axi || { skip_case dispatchable-wakes "tasks-axi not found"; return 0; }
  make_home dispatchable
  add_task alpha "first"
  add_task beta "second"
  give_brief alpha
  scan >/dev/null
  expect_code 0 "$SCAN_CODE" "dispatchable scan did not exit 0"
  assert_contains "$SCAN_OUT" "dispatch ready:" "dispatchable work did not report a ready verdict"
  assert_contains "$SCAN_OUT" "2 dispatchable" "ready verdict did not count both tasks"
  [ "$(wakes)" = 1 ] || fail "dispatchable work did not queue exactly one wake"
  pass "dispatchable work wakes firstmate"
}

test_briefed_is_distinguishable_from_intake() {
  have_tasks_axi || { skip_case briefed-vs-intake "tasks-axi not found"; return 0; }
  make_home briefed
  add_task written "has a brief"
  add_task bare "has only a title"
  add_task scaffolded "brief still a placeholder"
  give_brief written
  mkdir -p "$DATA/scaffolded"
  printf '# Brief\n\n{TASK}\n' > "$DATA/scaffolded/brief.md"
  scan >/dev/null
  assert_contains "$SCAN_OUT" "briefed: written" "a written brief was not reported as briefed"
  assert_contains "$SCAN_OUT" "needs intake: bare, scaffolded" \
    "a title-only task and an unfilled scaffold were not both reported as needing intake"
  pass "ready-and-briefed is distinguishable from ready-but-needs-intake"
}

test_blocked_and_gated_work_is_not_dispatchable() {
  have_tasks_axi || { skip_case blocked-and-gated "tasks-axi not found"; return 0; }
  make_home gated
  add_task leader "the blocker"
  add_task follower "waits on leader"
  add_task waiting "waits on a date that has not come"
  add_task lapsed "waited on a date that has passed"
  tasks-axi block follower --by leader --file "$DATA/backlog.md" >/dev/null 2>&1 \
    || fail "fixture: could not block follower"
  tasks-axi hold waiting --reason "external disk has not arrived" --kind external \
    --until 2099-01-01 --file "$DATA/backlog.md" >/dev/null 2>&1 \
    || fail "fixture: could not hold waiting"
  tasks-axi hold lapsed --reason "gate has passed" --kind external \
    --until 2000-01-01 --file "$DATA/backlog.md" >/dev/null 2>&1 \
    || fail "fixture: could not hold lapsed"
  give_brief leader
  give_brief lapsed
  scan >/dev/null
  assert_contains "$SCAN_OUT" "2 dispatchable in all" \
    "blocked work or an active date gate was counted as dispatchable"
  assert_not_contains "$SCAN_OUT" "follower" "a blocked task was reported dispatchable"
  assert_not_contains "$SCAN_OUT" "waiting" "a task held behind a future date was reported dispatchable"
  assert_contains "$SCAN_OUT" "lapsed" "a task whose date gate has passed was not reported dispatchable"
  pass "blocked work and active date gates are not dispatchable"
}

test_work_already_under_way_is_not_dispatchable() {
  have_tasks_axi || { skip_case under-way-excluded "tasks-axi not found"; return 0; }
  make_home underway
  add_task queued-one "genuinely waiting"
  add_task running-one "already has a worker"
  give_brief queued-one
  fm_write_meta "$STATE/running-one.meta" "window=fm:1" "kind=ship" "harness=claude"
  scan >/dev/null
  assert_contains "$SCAN_OUT" "1 dispatchable in all" \
    "a task that already has a live worker was counted as dispatchable"
  assert_contains "$SCAN_OUT" "queued-one" "the genuinely waiting task was not reported"
  pass "work that already has a worker is not reported as dispatchable"
}

# --- only an ACTIONABLE change speaks ---------------------------------------
#
# bin/fm-dispatch-poll.sh owns the definition: a ready verdict is actionable
# only when the dispatchable-AND-BRIEFED set GAINED a member, because that is
# the only movement that leaves firstmate something it can spawn right now.
# These cases drive that from both sides - what must speak, and what must stay
# quiet - because a check that speaks with nothing to act on trains its reader
# to ignore it, which costs more than the signal was ever worth.

test_unchanged_ready_set_does_not_repeat() {
  have_tasks_axi || { skip_case no-repeat "tasks-axi not found"; return 0; }
  make_home norepeat
  add_task alpha "first"
  give_brief alpha
  RESURFACE_SECS=0 scan >/dev/null
  [ "$(wakes)" = 1 ] || fail "first scan did not queue a wake"
  RESURFACE_SECS=0 scan >/dev/null
  [ -z "$SCAN_OUT" ] || fail "unchanged ready set printed again: $SCAN_OUT"
  [ "$(wakes)" = 1 ] || fail "unchanged ready set queued a second wake"
  unset RESURFACE_SECS
  pass "an unchanged ready set never wakes anyone twice"
}

# The live 2026-08-20 case, end to end. One briefed task sitting among a large
# standing intake queue wakes firstmate; firstmate dispatches it; the total
# drops by one and there is nothing left to act on. The first event is the
# signal. The second is the cry-wolf, and it must be silent.
test_dispatching_the_only_briefed_task_is_silent() {
  have_tasks_axi || { skip_case dispatch-then-silent "tasks-axi not found"; return 0; }
  make_home dispatchsilent
  add_task alpha "the one with instructions"
  add_task beta "still needs intake"
  add_task gamma "still needs intake too"
  give_brief alpha
  scan >/dev/null
  assert_contains "$SCAN_OUT" "newly briefed and ready to dispatch: alpha" \
    "the one dispatchable briefed task was not named as the actionable change"
  assert_contains "$SCAN_OUT" "3 dispatchable in all (1 briefed, 2 need intake)" \
    "the ready verdict lost the standing queue it sits in"
  [ "$(wakes)" = 1 ] || fail "the first briefed task did not queue exactly one wake"

  tasks-axi start alpha --file "$DATA/backlog.md" >/dev/null 2>&1 \
    || fail "fixture: could not start alpha"
  scan >/dev/null
  [ -z "$SCAN_OUT" ] || fail "dispatching the only briefed task woke firstmate again: $SCAN_OUT"
  [ "$(wakes)" = 1 ] || fail "dispatching the only briefed task queued a second wake"
  pass "dispatching the only briefed task is silent, because nothing new became actionable"
}

# A queue nobody has intaken is a standing condition, not news. It stays silent
# however large it grows, and however often the total moves.
test_an_unbriefed_queue_never_wakes_on_its_own() {
  have_tasks_axi || { skip_case unbriefed-queue "tasks-axi not found"; return 0; }
  make_home unbriefedqueue
  local i
  for i in 1 2 3; do
    add_task "queued-$i" "queued item $i"
    scan >/dev/null
    [ -z "$SCAN_OUT" ] || fail "an unbriefed ready task woke firstmate: $SCAN_OUT"
  done
  [ "$(wakes)" = 0 ] || fail "a queue of unbriefed ready work queued a wake"
  pass "a ready queue that nobody has intaken never wakes on its own"
}

test_a_task_arriving_without_a_brief_is_not_a_wake() {
  have_tasks_axi || { skip_case intake-arrival-silent "tasks-axi not found"; return 0; }
  make_home intakearrival
  add_task alpha "first"
  give_brief alpha
  scan >/dev/null
  [ "$(wakes)" = 1 ] || fail "the briefed task did not queue a wake"
  add_task beta "arrives with no instructions"
  scan >/dev/null
  [ -z "$SCAN_OUT" ] || fail "a task arriving without a brief woke firstmate: $SCAN_OUT"
  [ "$(wakes)" = 1 ] || fail "a task arriving without a brief queued a wake"
  pass "a task arriving without a brief moves the total and nothing else"
}

test_a_brief_arriving_on_a_standing_queue_wakes_and_names_it() {
  have_tasks_axi || { skip_case brief-arrival "tasks-axi not found"; return 0; }
  make_home briefarrival
  add_task alpha "first"
  add_task beta "second"
  scan >/dev/null
  [ -z "$SCAN_OUT" ] || fail "an entirely unbriefed ready set woke firstmate: $SCAN_OUT"
  give_brief alpha
  scan >/dev/null
  assert_contains "$SCAN_OUT" "1 newly briefed and ready to dispatch: alpha" \
    "a task acquiring a brief did not surface as the actionable change"
  assert_contains "$SCAN_OUT" "needs intake: beta" \
    "the ready verdict lost the rest of the queue it reports alongside"
  [ "$(wakes)" = 1 ] || fail "a task acquiring a brief did not queue exactly one wake"
  pass "a brief arriving on a standing queue is the change worth waking for"
}

test_a_second_brief_wakes_for_itself_alone() {
  have_tasks_axi || { skip_case second-brief "tasks-axi not found"; return 0; }
  make_home secondbrief
  add_task alpha "first"
  add_task beta "second"
  give_brief alpha
  scan >/dev/null
  [ "$(wakes)" = 1 ] || fail "the first brief did not queue a wake"
  give_brief beta
  scan >/dev/null
  assert_contains "$SCAN_OUT" "1 newly briefed and ready to dispatch: beta" \
    "the second brief did not surface, or did not name itself alone as the gain"
  assert_contains "$SCAN_OUT" "briefed: alpha, beta" \
    "the ready verdict lost the briefed work that was already waiting"
  [ "$(wakes)" = 2 ] || fail "the second brief did not queue its own wake"
  pass "a second brief wakes for itself alone, never re-announcing the first"
}

# The record has to follow what is actually dispatchable, including on a scan
# that says nothing, or a task that is dispatched now and re-queued later would
# be measured against a set it never left and could never be a gain again.
test_a_re_queued_task_can_be_a_gain_again() {
  have_tasks_axi || { skip_case requeued-gain "tasks-axi not found"; return 0; }
  make_home requeued
  add_task alpha "first"
  add_task beta "second"
  give_brief alpha
  give_brief beta
  scan >/dev/null
  [ "$(wakes)" = 1 ] || fail "the first scan did not queue a wake"
  tasks-axi start alpha --file "$DATA/backlog.md" >/dev/null 2>&1 \
    || fail "fixture: could not start alpha"
  scan >/dev/null
  [ -z "$SCAN_OUT" ] || fail "dispatching one of two briefed tasks woke firstmate: $SCAN_OUT"
  tasks-axi reopen alpha --file "$DATA/backlog.md" >/dev/null 2>&1 \
    || fail "fixture: could not reopen alpha"
  scan >/dev/null
  assert_contains "$SCAN_OUT" "1 newly briefed and ready to dispatch: alpha" \
    "a re-queued briefed task was not a gain again, so the silent scan had forgotten to record the loss"
  [ "$(wakes)" = 2 ] || fail "a re-queued briefed task did not queue its own wake"
  pass "a briefed task that is dispatched and later re-queued is a gain again"
}

test_a_ready_set_returning_after_going_empty_wakes_again() {
  have_tasks_axi || { skip_case empty-then-return "tasks-axi not found"; return 0; }
  make_home returning
  add_task alpha "first"
  give_brief alpha
  scan >/dev/null
  [ "$(wakes)" = 1 ] || fail "first scan did not queue a wake"
  tasks-axi start alpha --file "$DATA/backlog.md" >/dev/null 2>&1 \
    || fail "fixture: could not start alpha"
  scan >/dev/null
  [ -z "$SCAN_OUT" ] || fail "an emptied ready set printed a line: $SCAN_OUT"
  tasks-axi reopen alpha --file "$DATA/backlog.md" >/dev/null 2>&1 \
    || fail "fixture: could not reopen alpha"
  scan >/dev/null
  assert_contains "$SCAN_OUT" "1 dispatchable in all" "a ready set returning after empty did not re-surface"
  pass "a ready set that empties and returns wakes again"
}

# The other direction of the same invariant: a scan may only ever REMOVE ids
# from the gain baseline unless it is the scan that announced them. A briefed
# task that arrives during a machine-measurement inability is never named by
# that scan's payload, so absorbing it into the baseline would consume the gain
# in silence and firstmate would never be told the work is dispatchable.
test_a_gain_arriving_during_a_machine_inability_still_surfaces() {
  have_tasks_axi || { skip_case gain-during-inability "tasks-axi not found"; return 0; }
  make_home gainduringinability
  local pool i
  pool="$HOME_DIR/pool"
  for i in 1 2 3 4 5 6; do
    mkdir -p "$pool/repo-$i/1"
  done
  cat > "$FAKEBIN/du" <<SH
#!/usr/bin/env bash
[ ! -f "$HOME_DIR/slow-du" ] || sleep 1
printf '1024\t%s\n' "\${!#}"
SH
  chmod +x "$FAKEBIN/du"

  # Nothing briefed has ever been seen, and alpha arrives briefed on the very
  # scan whose machine measurement runs out of time.
  add_task alpha "first"
  give_brief alpha
  : > "$HOME_DIR/slow-du"
  FM_DISPATCH_POOL_ROOT_OVERRIDE="$pool" FM_DISPATCH_BUDGET_SECS=5 \
    FM_DISPATCH_COPY_MEASURE_SECS=0 scan >/dev/null
  assert_contains "$SCAN_OUT" "copy-reserve-timed-out" \
    "the fixture did not produce the machine-measurement inability it needs"
  assert_not_contains "$SCAN_OUT" "alpha" \
    "the inability payload named the briefed work it never actually offered"
  [ "$(wakes)" = 1 ] || fail "the reported inability did not queue its own wake"

  # The disk recovers. alpha has been dispatchable and briefed the whole time
  # and nobody has ever been told, so this scan owes firstmate the gain.
  rm -f "$HOME_DIR/slow-du"
  FM_DISPATCH_POOL_ROOT_OVERRIDE="$pool" FM_DISPATCH_COPY_MEASURE_SECS=0 scan >/dev/null
  assert_contains "$SCAN_OUT" "1 newly briefed and ready to dispatch: alpha" \
    "a gain that arrived during a machine inability was absorbed by the scan that never announced it"
  [ "$(wakes)" = 2 ] || fail "the absorbed gain did not queue its own wake once the machine could be read"
  rm -f "$FAKEBIN/du"
  pass "a gain arriving during a machine inability is never absorbed by the scan that stayed quiet about it"
}

# An inability that failed only on the MACHINE measurement DID observe the
# briefed set, and must record what it saw. Carrying the previous set through
# instead leaves the record naming ids that have since been dispatched, so their
# re-arrival is measured against a set they never left and can never be a gain
# again - a real wake swallowed permanently by one transient timeout.
test_an_inability_after_the_briefed_set_records_what_it_saw() {
  have_tasks_axi || { skip_case inability-records-observed "tasks-axi not found"; return 0; }
  make_home inabilityobserved
  local pool i
  add_task alpha "first"
  add_task beta "second"
  give_brief alpha
  scan >/dev/null
  assert_contains "$SCAN_OUT" "1 newly briefed and ready to dispatch: alpha" \
    "the first scan did not record alpha as the briefed set"
  [ "$(wakes)" = 1 ] || fail "the first scan did not queue a wake"

  # alpha is dispatched, so the briefed set this scan sees is empty. beta keeps
  # the ready set non-empty, so the scan runs on to the machine measurement -
  # and that is where it fails, well after the briefed set was established.
  tasks-axi start alpha --file "$DATA/backlog.md" >/dev/null 2>&1 \
    || fail "fixture: could not start alpha"
  pool="$HOME_DIR/pool"
  for i in 1 2 3 4 5 6; do
    mkdir -p "$pool/repo-$i/1"
  done
  cat > "$FAKEBIN/du" <<'SH'
#!/usr/bin/env bash
sleep 1
printf '1024	%s
' "${!#}"
SH
  chmod +x "$FAKEBIN/du"
  FM_DISPATCH_POOL_ROOT_OVERRIDE="$pool" FM_DISPATCH_BUDGET_SECS=5 \
    FM_DISPATCH_COPY_MEASURE_SECS=0 scan >/dev/null
  assert_contains "$SCAN_OUT" "copy-reserve-timed-out" \
    "the fixture did not produce the machine-measurement inability it needs"
  rm -f "$FAKEBIN/du"
  [ "$(wakes)" = 2 ] || fail "the reported inability did not queue its own wake"

  # alpha comes back, brief intact. It is immediately dispatchable again, so it
  # is news however the scan before it happened to fail.
  tasks-axi reopen alpha --file "$DATA/backlog.md" >/dev/null 2>&1 \
    || fail "fixture: could not reopen alpha"
  scan >/dev/null
  assert_contains "$SCAN_OUT" "1 newly briefed and ready to dispatch: alpha" \
    "a timeout after the briefed set was established discarded it, so re-queued briefed work never woke firstmate"
  [ "$(wakes)" = 3 ] || fail "the re-queued briefed task did not queue its own wake"
  pass "an inability raised after the briefed set was established records what it saw"
}

# An inability observed nothing. It must not erase what was known, and it must
# not manufacture a gain out of the same briefed set when it clears.
test_an_inability_never_manufactures_a_gain() {
  have_tasks_axi || { skip_case inability-no-gain "tasks-axi not found"; return 0; }
  make_home inabilitygain
  add_task alpha "first"
  give_brief alpha
  scan >/dev/null
  [ "$(wakes)" = 1 ] || fail "the briefed task did not queue a wake"
  chmod 000 "$DATA/backlog.md"
  RESURFACE_SECS=0 scan >/dev/null
  chmod 644 "$DATA/backlog.md"
  assert_contains "$SCAN_OUT" "backlog-unreadable" "the intervening inability was not reported"
  scan >/dev/null
  [ -z "$SCAN_OUT" ] || fail "an inability that cleared was re-reported as newly briefed work: $SCAN_OUT"
  [ "$(wakes)" = 2 ] || fail "an inability that cleared queued a third wake for unchanged work"
  unset RESURFACE_SECS
  pass "an inability that clears does not manufacture a gain out of unchanged work"
}

# With no room nothing is dispatchable, so a blocked verdict records the empty
# set. That is what re-arms the wake: the moment room returns, whatever is
# briefed is a gain again and firstmate hears about it rather than waiting for
# some unrelated change to the queue.
test_room_returning_re_offers_the_briefed_work() {
  have_tasks_axi || { skip_case room-returns "tasks-axi not found"; return 0; }
  make_home roomreturns
  add_task alpha "first"
  give_brief alpha
  OS_RESERVE_MB=999999999 scan >/dev/null
  assert_contains "$SCAN_OUT" "dispatch blocked:" "an exhausted disk did not block"
  [ -z "$(sed -n 's/^dispatchable_briefed=//p' "$STATE/.dispatch-poll")" ] \
    || fail "a blocked verdict kept work on the dispatchable record while there was no room for it"
  OS_RESERVE_MB=1 scan >/dev/null
  assert_contains "$SCAN_OUT" "1 newly briefed and ready to dispatch: alpha" \
    "room returning did not re-offer the briefed work that had nowhere to go"
  unset OS_RESERVE_MB
  pass "room returning re-offers the briefed work that had nowhere to go"
}

# --- it must not decide which work matters ----------------------------------

test_never_ranks_and_never_spawns() {
  have_tasks_axi || { skip_case no-rank-no-spawn "tasks-axi not found"; return 0; }
  make_home norank
  add_task zulu "filed first"
  add_task alpha "filed second"
  add_task mike "filed third"
  give_brief zulu
  give_brief alpha
  give_brief mike
  scan >/dev/null
  assert_contains "$SCAN_OUT" "briefed: alpha, mike, zulu" \
    "the ready set was not reported in a fixed identifier order"
  assert_not_contains "$SCAN_OUT" "priority" "the report carried a priority judgement"
  assert_not_contains "$SCAN_OUT" "recommend" "the report carried a recommendation"
  [ ! -s "$SPAWN_LOG" ] || fail "the scan reached for a worker tool: $(cat "$SPAWN_LOG")"
  [ -z "$(ls "$STATE"/*.meta 2>/dev/null)" ] || fail "the scan created a task record"
  pass "the check never ranks the work and never spawns"
}

test_long_ready_set_is_bounded_and_the_cut_is_disclosed() {
  have_tasks_axi || { skip_case bounded-list "tasks-axi not found"; return 0; }
  make_home bounded
  local i
  for i in 1 2 3 4 5; do
    add_task "task-$i" "queued item $i"
    give_brief "task-$i"
  done
  FM_DISPATCH_LIST_LIMIT=2 scan >/dev/null
  assert_contains "$SCAN_OUT" "5 dispatchable in all (5 briefed, 0 need intake)" \
    "the bounded report lost the true group counts"
  assert_contains "$SCAN_OUT" "briefed: task-1, task-2 (+3 more)" \
    "the identifier list was not bounded with the cut disclosed"
  assert_contains "$SCAN_OUT" "5 newly briefed and ready to dispatch: task-1, task-2 (+3 more)" \
    "the newly-briefed list was not bounded with the cut disclosed"
  # The comparison must cover every briefed item, or one beyond the display
  # limit could arrive without ever waking anyone.
  add_task task-9 "beyond the display limit"
  give_brief task-9
  FM_DISPATCH_LIST_LIMIT=2 scan >/dev/null
  assert_contains "$SCAN_OUT" "6 dispatchable in all" \
    "an item added beyond the display limit did not re-surface"
  assert_contains "$SCAN_OUT" "1 newly briefed and ready to dispatch: task-9" \
    "an item added beyond the display limit was not named as the gain"
  pass "a long ready set is bounded and the cut is disclosed, never silent"
}

# --- capacity ---------------------------------------------------------------

test_no_room_is_reported_not_claimed_ready() {
  have_tasks_axi || { skip_case no-room "tasks-axi not found"; return 0; }
  make_home noroom
  add_task alpha "first"
  OS_RESERVE_MB=999999999 scan >/dev/null
  unset OS_RESERVE_MB
  assert_contains "$SCAN_OUT" "dispatch blocked:" \
    "an exhausted disk did not report a blocked verdict"
  assert_not_contains "$SCAN_OUT" "dispatch ready:" \
    "an exhausted disk still claimed work was dispatchable"
  [ "$(wakes)" = 1 ] || fail "an exhausted disk did not queue a wake"
  pass "no room for another isolated copy is reported, never claimed as ready"
}

test_ready_verdict_carries_its_capacity_evidence() {
  have_tasks_axi || { skip_case capacity-evidence "tasks-axi not found"; return 0; }
  make_home evidence
  add_task alpha "first"
  give_brief alpha
  fm_write_meta "$STATE/live-one.meta" "window=fm:1" "kind=ship" "harness=claude"
  fm_write_meta "$STATE/mate.meta" "window=fm:2" "kind=secondmate" "harness=claude"
  scan >/dev/null
  assert_contains "$SCAN_OUT" "live workers 1" \
    "the ready verdict did not report the live worker count, or counted a second mate as one"
  assert_contains "$SCAN_OUT" "MiB floor" "the ready verdict did not report its capacity floor"
  pass "the ready verdict carries the capacity evidence it decided on"
}

# --- it must report rather than pass when it cannot evaluate ----------------

test_unreadable_backlog_reports_rather_than_passes() {
  have_tasks_axi || { skip_case unreadable-backlog "tasks-axi not found"; return 0; }
  make_home unreadable
  add_task alpha "first"
  chmod 000 "$DATA/backlog.md"
  scan >/dev/null
  chmod 644 "$DATA/backlog.md"
  assert_contains "$SCAN_OUT" "dispatch unknown" \
    "an unreadable backlog was not reported as an inability to evaluate"
  assert_contains "$SCAN_OUT" "backlog-unreadable" "the report did not name why it could not evaluate"
  [ "$(wakes)" = 1 ] || fail "an unreadable backlog did not queue a wake"
  pass "an unreadable backlog reports rather than passing as nothing ready"
}

# A home with no backlog file has no queue to pull from, so the check is inert
# there rather than reporting a fault every cadence. Absence and unreadability
# are different facts, and only the second one is an inability to evaluate.
test_absent_backlog_is_inert() {
  make_home absentbacklog
  scan >/dev/null
  expect_code 0 "$SCAN_CODE" "a home with no backlog did not exit 0"
  [ -z "$SCAN_OUT" ] || fail "a home with no backlog printed a line: $SCAN_OUT"
  [ "$(wakes)" = 0 ] || fail "a home with no backlog queued a wake"
  assert_absent "$STATE/.dispatch-poll" "a home with no backlog acquired a verdict record"
  pass "a home with no backlog file is inert"
}

test_backlog_that_does_not_parse_reports_rather_than_passes() {
  have_tasks_axi || { skip_case unparseable-backlog "tasks-axi not found"; return 0; }
  make_home unparseable
  add_task alpha "first"
  # Task lines are present but the surrounding structure is destroyed, which the
  # markdown backend reads as an empty backlog. Reading that as "nothing ready"
  # is exactly the silent zero this check exists to refuse.
  sed 's/^## .*//' "$DATA/backlog.md" > "$DATA/backlog.md.tmp"
  printf 'not a backlog at all\n' | cat - "$DATA/backlog.md.tmp" > "$DATA/backlog.md"
  rm -f "$DATA/backlog.md.tmp"
  scan >/dev/null
  assert_contains "$SCAN_OUT" "dispatch unknown" \
    "a backlog whose task lines the tool cannot see was reported as nothing ready"
  assert_contains "$SCAN_OUT" "backlog-parse-disagreement" \
    "the report did not name the disagreement between the file and the tool"
  pass "a backlog the tool cannot parse reports rather than passing as nothing ready"
}

test_missing_backlog_tool_reports_rather_than_passes() {
  make_home notool
  printf '# Backlog\n\n## In flight\n## Queued\n- [ ] alpha - first (since 2026-01-01)\n## Done\n' \
    > "$DATA/backlog.md"
  # An empty PATH element set that still resolves the coreutils the check needs,
  # but never tasks-axi.
  SCAN_OUT=$(PATH="$FAKEBIN:/usr/bin:/bin" \
    FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$STATE" \
    FM_DISPATCH_POOL_ROOT="$HOME_DIR" FM_DISPATCH_OS_RESERVE_MB=1 \
    "$POLL" scan 2>&1)
  assert_contains "$SCAN_OUT" "dispatch unknown" \
    "a missing backlog tool was not reported as an inability to evaluate"
  assert_contains "$SCAN_OUT" "tasks-axi" "the report did not name the missing tool"
  pass "a missing backlog tool reports rather than passing as nothing ready"
}

test_unmeasurable_disk_reports_rather_than_passes() {
  have_tasks_axi || { skip_case unmeasurable-disk "tasks-axi not found"; return 0; }
  make_home nodisk
  add_task alpha "first"
  FM_DISPATCH_POOL_ROOT_OVERRIDE="$TMP_ROOT/nodisk/no-such-volume" scan >/dev/null
  unset FM_DISPATCH_POOL_ROOT_OVERRIDE
  assert_contains "$SCAN_OUT" "dispatch unknown" \
    "an unmeasurable disk was not reported as an inability to evaluate"
  assert_contains "$SCAN_OUT" "disk-unmeasurable" "the report did not name why it could not evaluate"
  pass "an unmeasurable disk reports rather than passing as nothing ready"
}

test_unreadable_task_record_reports_rather_than_passes() {
  have_tasks_axi || { skip_case unreadable-record "tasks-axi not found"; return 0; }
  make_home norecords
  add_task alpha "first"
  fm_write_meta "$STATE/opaque.meta" "window=fm:1" "kind=ship"
  chmod 000 "$STATE/opaque.meta"
  scan >/dev/null
  chmod 644 "$STATE/opaque.meta"
  assert_contains "$SCAN_OUT" "dispatch unknown" \
    "an unreadable task record was not reported as an inability to enumerate live work"
  assert_contains "$SCAN_OUT" "live-work-unreadable" "the report did not name why it could not evaluate"
  pass "an unreadable task record reports rather than passing as nothing ready"
}

test_invalid_capacity_configuration_reports_rather_than_passes() {
  have_tasks_axi || { skip_case invalid-reserve "tasks-axi not found"; return 0; }
  make_home badreserve
  add_task alpha "first"
  OS_RESERVE_MB="not-a-number" scan >/dev/null
  unset OS_RESERVE_MB
  assert_contains "$SCAN_OUT" "dispatch unknown" \
    "an unusable capacity setting was silently ignored"
  assert_contains "$SCAN_OUT" "os-reserve-invalid" "the report did not name the unusable setting"
  pass "an unusable capacity setting reports rather than silently defaulting"
}

test_persisting_fault_resurfaces_on_a_bounded_cadence() {
  make_home persisting
  printf '# Backlog\n\n## In flight\n## Queued\n## Done\n' > "$DATA/backlog.md"
  chmod 000 "$DATA/backlog.md"
  scan >/dev/null
  assert_contains "$SCAN_OUT" "backlog-unreadable" "the first fault was not reported"
  scan >/dev/null
  [ -z "$SCAN_OUT" ] || fail "the same fault repeated immediately: $SCAN_OUT"
  RESURFACE_SECS=0 scan >/dev/null
  unset RESURFACE_SECS
  chmod 644 "$DATA/backlog.md"
  assert_contains "$SCAN_OUT" "backlog-unreadable" \
    "a persisting fault never re-surfaced, so it could rot invisibly"
  pass "a persisting fault re-surfaces on a bounded cadence rather than going quiet forever"
}

test_ready_verdict_never_resurfaces_on_cadence() {
  have_tasks_axi || { skip_case ready-no-cadence "tasks-axi not found"; return 0; }
  make_home readycadence
  add_task alpha "first"
  give_brief alpha
  RESURFACE_SECS=0 scan >/dev/null
  [ "$(wakes)" = 1 ] || fail "first scan did not queue a wake"
  RESURFACE_SECS=0 scan >/dev/null
  unset RESURFACE_SECS
  [ -z "$SCAN_OUT" ] || fail "an unchanged ready set re-surfaced on the fault cadence: $SCAN_OUT"
  pass "the bounded re-surface cadence never applies to an unchanged ready set"
}

# A ready scan that says nothing must not reset the no-repeat baseline of the
# verdict that DID speak. Only the briefed set moves on a silent write; stamping
# the ready verdict over a fault's signature would make the very next occurrence
# of that same fault look new and wake firstmate for it twice inside the bound.
test_a_silent_ready_scan_keeps_the_fault_cadence() {
  have_tasks_axi || { skip_case silent-ready-keeps-cadence "tasks-axi not found"; return 0; }
  make_home silentcadence
  local pool i
  pool="$HOME_DIR/pool"
  for i in 1 2 3 4 5 6; do
    mkdir -p "$pool/repo-$i/1"
  done
  # Slow only while the marker is there, so the same fixture produces the
  # identical inability twice with a healthy scan in between.
  cat > "$FAKEBIN/du" <<SH
#!/usr/bin/env bash
[ ! -f "$HOME_DIR/slow-du" ] || sleep 1
printf '1024\t%s\n' "\${!#}"
SH
  chmod +x "$FAKEBIN/du"

  add_task alpha "first"
  add_task beta "second"
  give_brief alpha
  give_brief beta
  FM_DISPATCH_POOL_ROOT_OVERRIDE="$pool" FM_DISPATCH_COPY_MEASURE_SECS=0 scan >/dev/null
  assert_contains "$SCAN_OUT" "dispatch ready:" "the briefed pair did not establish a baseline"
  [ "$(wakes)" = 1 ] || fail "the briefed pair did not queue a wake"

  : > "$HOME_DIR/slow-du"
  FM_DISPATCH_POOL_ROOT_OVERRIDE="$pool" FM_DISPATCH_BUDGET_SECS=5 \
    FM_DISPATCH_COPY_MEASURE_SECS=0 scan >/dev/null
  assert_contains "$SCAN_OUT" "copy-reserve-timed-out" "the first inability was not reported"
  [ "$(wakes)" = 2 ] || fail "the first inability did not queue its own wake"

  # A healthy ready scan whose briefed set only SHRINKS: no gain, so it stays
  # silent - and a silent scan has said nothing the cadence should count.
  rm -f "$HOME_DIR/slow-du"
  tasks-axi start beta --file "$DATA/backlog.md" >/dev/null 2>&1 \
    || fail "fixture: could not start beta"
  FM_DISPATCH_POOL_ROOT_OVERRIDE="$pool" FM_DISPATCH_COPY_MEASURE_SECS=0 scan >/dev/null
  [ -z "$SCAN_OUT" ] || fail "a shrinking briefed set woke firstmate: $SCAN_OUT"
  [ "$(wakes)" = 2 ] || fail "a silent ready scan queued a wake"

  : > "$HOME_DIR/slow-du"
  FM_DISPATCH_POOL_ROOT_OVERRIDE="$pool" FM_DISPATCH_BUDGET_SECS=5 \
    FM_DISPATCH_COPY_MEASURE_SECS=0 scan >/dev/null
  [ -z "$SCAN_OUT" ] || fail "the identical inability surfaced again inside its bound: $SCAN_OUT"
  [ "$(wakes)" = 2 ] || fail "the identical inability queued a second wake inside its bound"

  # Still bounded, not silenced: once the cadence elapses it speaks again.
  FM_DISPATCH_POOL_ROOT_OVERRIDE="$pool" FM_DISPATCH_BUDGET_SECS=5 \
    FM_DISPATCH_COPY_MEASURE_SECS=0 RESURFACE_SECS=0 scan >/dev/null
  unset RESURFACE_SECS
  rm -f "$HOME_DIR/slow-du" "$FAKEBIN/du"
  assert_contains "$SCAN_OUT" "copy-reserve-timed-out" \
    "the persisting inability never re-surfaced once its bound elapsed"
  pass "a silent ready scan leaves the blocked-or-unknown re-surface cadence intact"
}

# The same invariant, on the other silent path. A none verdict prints nothing
# and queues nothing, so it has announced nothing, so it may not move the
# baseline the bounded cadence is measured against.
test_a_silent_none_scan_keeps_the_fault_cadence() {
  have_tasks_axi || { skip_case silent-none-keeps-cadence "tasks-axi not found"; return 0; }
  make_home silentnonecadence
  local pool i
  pool="$HOME_DIR/pool"
  for i in 1 2 3 4 5 6; do
    mkdir -p "$pool/repo-$i/1"
  done
  cat > "$FAKEBIN/du" <<SH
#!/usr/bin/env bash
[ ! -f "$HOME_DIR/slow-du" ] || sleep 1
printf '1024\t%s\n' "\${!#}"
SH
  chmod +x "$FAKEBIN/du"

  add_task alpha "first"
  give_brief alpha
  : > "$HOME_DIR/slow-du"
  FM_DISPATCH_POOL_ROOT_OVERRIDE="$pool" FM_DISPATCH_BUDGET_SECS=5 \
    FM_DISPATCH_COPY_MEASURE_SECS=0 scan >/dev/null
  assert_contains "$SCAN_OUT" "copy-reserve-timed-out" "the first inability was not reported"
  [ "$(wakes)" = 1 ] || fail "the first inability did not queue its own wake"

  # Every queued item is dispatched, so the verdict is none: it surfaces nothing
  # and therefore has nothing to say about when the fault last spoke.
  rm -f "$HOME_DIR/slow-du"
  tasks-axi start alpha --file "$DATA/backlog.md" >/dev/null 2>&1 \
    || fail "fixture: could not start alpha"
  FM_DISPATCH_POOL_ROOT_OVERRIDE="$pool" FM_DISPATCH_COPY_MEASURE_SECS=0 scan >/dev/null
  [ -z "$SCAN_OUT" ] || fail "an emptied ready set printed a line: $SCAN_OUT"
  [ "$(wakes)" = 1 ] || fail "an emptied ready set queued a wake"

  tasks-axi reopen alpha --file "$DATA/backlog.md" >/dev/null 2>&1 \
    || fail "fixture: could not reopen alpha"
  : > "$HOME_DIR/slow-du"
  FM_DISPATCH_POOL_ROOT_OVERRIDE="$pool" FM_DISPATCH_BUDGET_SECS=5 \
    FM_DISPATCH_COPY_MEASURE_SECS=0 scan >/dev/null
  [ -z "$SCAN_OUT" ] || fail "the identical inability surfaced again inside its bound: $SCAN_OUT"
  [ "$(wakes)" = 1 ] || fail "the identical inability queued a second wake inside its bound"

  # Still bounded, not silenced: once the cadence elapses it speaks again.
  FM_DISPATCH_POOL_ROOT_OVERRIDE="$pool" FM_DISPATCH_BUDGET_SECS=5 \
    FM_DISPATCH_COPY_MEASURE_SECS=0 RESURFACE_SECS=0 scan >/dev/null
  unset RESURFACE_SECS
  rm -f "$HOME_DIR/slow-du" "$FAKEBIN/du"
  assert_contains "$SCAN_OUT" "copy-reserve-timed-out" \
    "the persisting inability never re-surfaced once its bound elapsed"
  pass "a silent none scan leaves the blocked-or-unknown re-surface cadence intact"
}

# --- the copy measurement reads copies, not pools ---------------------------

# Treehouse lays the pool out as <pool-root>/<repo>-<hash>/<N>, so a pool-root
# child is a per-repo POOL holding several worktrees and one isolated copy is
# the numbered directory below it. Measuring the child would report the sum of
# every worktree as the cost of one copy.
test_pool_copies_are_measured_below_the_per_repo_pool() {
  have_tasks_axi || { skip_case pool-depth "tasks-axi not found"; return 0; }
  make_home pooldepth
  local pool copy_kb pool_kb reserve_mb
  pool="$HOME_DIR/pool"
  mkdir -p "$pool/repo-abc123/1" "$pool/repo-abc123/2"
  dd if=/dev/urandom of="$pool/repo-abc123/1/blob" bs=1048576 count=48 2>/dev/null \
    || fail "fixture: could not write the first worktree"
  dd if=/dev/urandom of="$pool/repo-abc123/2/blob" bs=1048576 count=48 2>/dev/null \
    || fail "fixture: could not write the second worktree"
  printf '{}\n' > "$pool/repo-abc123/treehouse-state.json"
  add_task alpha "first"
  give_brief alpha
  copy_kb=$(du -sk "$pool/repo-abc123/1" | awk 'NR == 1 {print $1}')
  pool_kb=$(du -sk "$pool/repo-abc123" | awk 'NR == 1 {print $1}')
  case "$copy_kb$pool_kb" in *[!0-9]*|'') fail "fixture: could not size the pool" ;; esac
  [ "$pool_kb" -gt "$((copy_kb + copy_kb / 2))" ] \
    || fail "fixture: the pool is not meaningfully larger than one worktree"

  # Both numbers the capacity rule is computed from are in the payload, so the
  # depth is observable through the executable interface rather than inferred:
  # the clone reserve must be ONE worktree, and the floor must be the reserve
  # plus that same one worktree, not the reserve plus the whole pool.
  reserve_mb=7
  FM_DISPATCH_POOL_ROOT_OVERRIDE="$pool" OS_RESERVE_MB="$reserve_mb" scan >/dev/null
  assert_contains "$SCAN_OUT" "clone reserve $((copy_kb / 1024)) MiB" \
    "the reported clone reserve is the sum of every worktree in the pool, not one isolated copy"
  assert_contains "$SCAN_OUT" "against a $(( (reserve_mb * 1024 + copy_kb) / 1024 )) MiB floor" \
    "the capacity floor was built from pool depth rather than from one isolated copy"
  assert_not_contains "$SCAN_OUT" "clone reserve $((pool_kb / 1024)) MiB" \
    "the clone reserve matched the whole pool"
  pass "the pool is read one level down, so the clone reserve is one copy and not a whole pool"
}

# A pool root that holds copies directly, with no per-repo level, must still
# yield a number rather than silently measuring nothing.
test_a_pool_root_holding_copies_directly_still_measures() {
  have_tasks_axi || { skip_case pool-depth-fallback "tasks-axi not found"; return 0; }
  make_home pooldirect
  local pool copy_kb reserve_mb
  pool="$HOME_DIR/pool"
  mkdir -p "$pool/lone-copy"
  dd if=/dev/urandom of="$pool/lone-copy/blob" bs=1048576 count=48 2>/dev/null \
    || fail "fixture: could not write the copy"
  add_task alpha "first"
  give_brief alpha
  copy_kb=$(du -sk "$pool/lone-copy" | awk 'NR == 1 {print $1}')
  reserve_mb=7
  FM_DISPATCH_POOL_ROOT_OVERRIDE="$pool" OS_RESERVE_MB="$reserve_mb" scan >/dev/null
  assert_contains "$SCAN_OUT" "clone reserve $((copy_kb / 1024)) MiB" \
    "a pool root holding copies directly did not fall back to measuring the child itself"
  pass "a pool root that holds copies directly still yields a clone reserve"
}

test_the_copy_measurement_shares_one_deadline() {
  make_home copydeadline
  local pool i
  printf '# Backlog\n\n## In flight\n## Queued\n- [ ] alpha - first (since 2026-01-01)\n## Done\n' \
    > "$DATA/backlog.md"
  pool="$HOME_DIR/pool"
  for i in 1 2 3 4 5 6; do
    mkdir -p "$pool/repo-$i/1"
  done
  # Each du individually finishes well inside the per-unit bound, so only a
  # SHARED deadline can stop the walk; a per-directory bound would let six legal
  # walks add up past the caller's backstop and report nothing at all.
  cat > "$FAKEBIN/du" <<'SH'
#!/usr/bin/env bash
sleep 1
printf '1024	%s
' "${!#}"
SH
  chmod +x "$FAKEBIN/du"
  cat > "$FAKEBIN/tasks-axi" <<'SH'
#!/usr/bin/env bash
printf 'ready[1]{id,state,kind,repo,title}
'
printf '  alpha,queued,ship,none,first
'
SH
  chmod +x "$FAKEBIN/tasks-axi"
  FM_DISPATCH_POOL_ROOT_OVERRIDE="$pool" FM_DISPATCH_BUDGET_SECS=2 scan >/dev/null
  expect_code 0 "$SCAN_CODE" "an exhausted measurement deadline did not exit 0"
  assert_contains "$SCAN_OUT" "dispatch unknown" \
    "a copy measurement that ran past its shared deadline was not reported"
  assert_contains "$SCAN_OUT" "copy-reserve-timed-out" \
    "the report did not name the measurement budget it exhausted"
  [ "$(wakes)" = 1 ] || fail "an exhausted measurement deadline did not queue a wake"
  pass "the copy measurement shares one deadline rather than multiplying a per-directory bound"
}

# --- the deadband survives an intervening verdict ---------------------------

# The blocked boundary lives in its own record field, so a verdict that does not
# evaluate capacity carries it through instead of erasing it. Reading the
# verdict field instead would let an emptied ready set, or one transient
# timeout, release the boundary with the disk unchanged.
deadband_holds_across() { # <label> <how-to-produce-the-intervening-verdict>
  local label=$1 intervene=$2 pool copy_kb free_kb reserve_mb
  make_home "deadband-$label"
  pool="$HOME_DIR/pool"
  mkdir -p "$pool/repo-abc/1"
  dd if=/dev/urandom of="$pool/repo-abc/1/blob" bs=1048576 count=64 2>/dev/null \
    || fail "fixture: could not write a measurable isolated copy"
  add_task alpha "first"
  give_brief alpha
  copy_kb=$(du -sk "$pool/repo-abc/1" | awk 'NR == 1 {print $1}')
  free_kb=$(free_kb_of "$pool")
  case "$copy_kb$free_kb" in *[!0-9]*|'') fail "fixture: could not size the pool" ;; esac

  reserve_mb=$(( free_kb / 1024 + 1024 ))
  FM_DISPATCH_POOL_ROOT_OVERRIDE="$pool" OS_RESERVE_MB="$reserve_mb" scan >/dev/null
  assert_contains "$SCAN_OUT" "dispatch blocked:" "the boundary was never entered"
  assert_grep 'capacity_blocked=yes' "$STATE/.dispatch-poll" \
    "entering the blocked boundary did not record it in its own field"

  "$intervene"
  assert_grep 'capacity_blocked=yes' "$STATE/.dispatch-poll" \
    "an intervening $label verdict erased the blocked boundary"

  # Free space back above the floor but not by a whole copy. The boundary must
  # still hold, which it can only do if the intervening verdict carried it.
  reserve_mb=$(( (free_kb - copy_kb) / 1024 - 16 ))
  FM_DISPATCH_POOL_ROOT_OVERRIDE="$pool" OS_RESERVE_MB="$reserve_mb" scan >/dev/null
  assert_not_contains "$SCAN_OUT" "dispatch ready:" \
    "an intervening $label verdict let the deadband release with the disk unchanged"
  assert_grep 'capacity_blocked=yes' "$STATE/.dispatch-poll" \
    "the blocked boundary did not survive an intervening $label verdict"

  # And it still releases for real once a whole copy of room returns.
  reserve_mb=$(( (free_kb - 2 * copy_kb) / 1024 - 64 ))
  FM_DISPATCH_POOL_ROOT_OVERRIDE="$pool" OS_RESERVE_MB="$reserve_mb" scan >/dev/null
  assert_contains "$SCAN_OUT" "dispatch ready:" \
    "a whole copy of room above the floor did not release the boundary"
  assert_grep 'capacity_blocked=no' "$STATE/.dispatch-poll" \
    "releasing the boundary did not clear its field"
}

test_deadband_survives_an_intervening_none_verdict() {
  have_tasks_axi || { skip_case deadband-none "tasks-axi not found"; return 0; }
  deadband_holds_across none intervene_with_none
  pass "an emptied ready set does not release the capacity deadband"
}

intervene_with_none() {
  tasks-axi start alpha --file "$DATA/backlog.md" >/dev/null 2>&1 \
    || fail "fixture: could not start alpha"
  FM_DISPATCH_POOL_ROOT_OVERRIDE="$HOME_DIR/pool" scan >/dev/null
  [ -z "$SCAN_OUT" ] || fail "the intervening scan was not a silent none verdict: $SCAN_OUT"
  tasks-axi reopen alpha --file "$DATA/backlog.md" >/dev/null 2>&1 \
    || fail "fixture: could not reopen alpha"
}

test_deadband_survives_an_intervening_unknown_verdict() {
  have_tasks_axi || { skip_case deadband-unknown "tasks-axi not found"; return 0; }
  deadband_holds_across unknown intervene_with_unknown
  pass "a transient inability does not release the capacity deadband"
}

intervene_with_unknown() {
  chmod 000 "$DATA/backlog.md"
  RESURFACE_SECS=0 FM_DISPATCH_POOL_ROOT_OVERRIDE="$HOME_DIR/pool" scan >/dev/null
  chmod 644 "$DATA/backlog.md"
  assert_contains "$SCAN_OUT" "dispatch unknown" "the intervening verdict was not unknown"
}

# --- the watcher actually runs it -------------------------------------------

test_watcher_sweep_surfaces_a_changed_verdict() {
  have_tasks_axi || { skip_case watcher-sweep "tasks-axi not found"; return 0; }
  make_home watchersweep
  add_task alpha "first"
  give_brief alpha
  local out=$HOME_DIR/watch.out pid i=0
  FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$STATE" FM_ROOT_OVERRIDE="$FM_ROOT_OVERRIDE" \
    FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=1 FM_HEARTBEAT=999999 \
    FM_DISPATCH_POOL_ROOT="$HOME_DIR" FM_DISPATCH_OS_RESERVE_MB=1 \
    "$ROOT/bin/fm-watch.sh" > "$out" 2>/dev/null &
  pid=$!
  while [ "$i" -lt 100 ]; do
    kill -0 "$pid" 2>/dev/null || break
    sleep 0.1
    i=$((i + 1))
  done
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  assert_grep 'check: dispatch' "$out" \
    "the watcher check sweep did not surface the dispatch-readiness verdict"
  assert_grep 'dispatch ready:' "$STATE/.wake-queue" \
    "the watcher check sweep did not leave a durable dispatch wake record"
  pass "the watcher check sweep runs the dispatch-readiness check and surfaces a changed verdict"
}

# --- one durable record per verdict, newest wins ----------------------------

# Every dispatch verdict is queued under the CONSTANT key "dispatch", so the
# drain's kind+key collapse keeps only the newest. A superseded verdict names a
# ready set that no longer exists, and presenting it as its own row is exactly
# the noise that trains a reader to ignore the signal.
test_superseded_verdicts_collapse_to_the_latest() {
  have_tasks_axi || { skip_case constant-wake-key "tasks-axi not found"; return 0; }
  make_home wakekey
  local keys shown
  add_task alpha "first"
  give_brief alpha
  scan >/dev/null
  add_task beta "second"
  give_brief beta
  scan >/dev/null
  add_task gamma "third"
  give_brief gamma
  scan >/dev/null
  [ "$(wakes)" = 3 ] || fail "three distinct verdicts did not queue three durable records"
  keys=$(awk -F '\t' '$3 == "check" { print $4 }' "$STATE/.wake-queue" | LC_ALL=C sort -u)
  [ "$keys" = dispatch ] \
    || fail "dispatch wake records did not share one key, so the drain cannot collapse them: $keys"
  shown=$(FM_STATE_OVERRIDE="$STATE" bash -c '
    # shellcheck disable=SC1090,SC1091
    . "$1"
    fm_wake_print_deduped "$2"
  ' _ "$ROOT/bin/fm-wake-lib.sh" "$STATE/.wake-queue")
  [ "$(printf '%s\n' "$shown" | grep -c 'dispatch ready:')" = 1 ] \
    || fail "the drain would present more than the current verdict: $shown"
  assert_contains "$shown" "3 dispatchable in all" "the drain kept a superseded verdict instead of the newest"
  pass "superseded verdicts collapse so only the current one is ever presented"
}

# --- nothing runs unbounded -------------------------------------------------

test_a_hung_backlog_tool_is_reported_not_silently_killed() {
  make_home hungtool
  printf '# Backlog\n\n## In flight\n## Queued\n- [ ] alpha - first (since 2026-01-01)\n## Done\n' \
    > "$DATA/backlog.md"
  cat > "$FAKEBIN/tasks-axi" <<'SH'
#!/usr/bin/env bash
sleep 30
SH
  chmod +x "$FAKEBIN/tasks-axi"
  FM_DISPATCH_BUDGET_SECS=1 scan >/dev/null
  expect_code 0 "$SCAN_CODE" "a bounded backlog read that timed out did not exit 0"
  assert_contains "$SCAN_OUT" "dispatch unknown" \
    "a backlog tool that never returned was silently killed instead of reported"
  assert_contains "$SCAN_OUT" "backlog-tool-timed-out" "the report did not name the bound it hit"
  [ "$(wakes)" = 1 ] || fail "a bounded read that timed out did not queue a wake"
  pass "an external call that hits its bound is reported, never silently killed"
}

test_an_unusable_budget_reports_rather_than_defaulting() {
  make_home badbudget
  printf '# Backlog\n\n## In flight\n## Queued\n- [ ] alpha - first (since 2026-01-01)\n## Done\n' \
    > "$DATA/backlog.md"
  FM_DISPATCH_BUDGET_SECS=not-a-number scan >/dev/null
  assert_contains "$SCAN_OUT" "budget-invalid" "a non-numeric per-call bound was silently defaulted"
  # Zero is not a bound: it disables the deadline outright in every mechanism
  # bin/fm-timeout-lib.sh selects, so it must be rejected with the rest.
  RESURFACE_SECS=0 FM_DISPATCH_BUDGET_SECS=0 scan >/dev/null
  assert_contains "$SCAN_OUT" "budget-invalid" "a zero per-call bound was accepted as a bound"
  RESURFACE_SECS=0 FM_DISPATCH_BUDGET_SECS=31 scan >/dev/null
  assert_contains "$SCAN_OUT" "budget-invalid" "an out-of-range per-call bound was accepted"
  pass "an unusable per-call bound reports rather than silently defaulting"
}

# --- one scan at a time -----------------------------------------------------

test_a_scan_that_finds_the_lock_held_stays_silent() {
  have_tasks_axi || { skip_case scan-lock "tasks-axi not found"; return 0; }
  make_home scanlock
  local holder
  add_task alpha "first"
  give_brief alpha
  mkdir -p "$STATE/.dispatch-poll.lock"
  sleep 30 &
  holder=$!
  printf '%s\n' "$holder" > "$STATE/.dispatch-poll.lock/pid"
  scan >/dev/null
  kill "$holder" 2>/dev/null || true
  wait "$holder" 2>/dev/null || true
  rm -rf "$STATE/.dispatch-poll.lock"
  expect_code 0 "$SCAN_CODE" "a scan that found the lock held did not exit 0"
  [ -z "$SCAN_OUT" ] || fail "a scan that found the lock held printed a line: $SCAN_OUT"
  [ "$(wakes)" = 0 ] || fail "a scan that found the lock held duplicated the holder's wake"
  assert_absent "$STATE/.dispatch-poll" "a scan that found the lock held rewrote the verdict record"
  # The lock must not outlive a scan that took it, or the check would wedge shut.
  scan >/dev/null
  assert_contains "$SCAN_OUT" "dispatch ready:" "the scan lock was not released for the next scan"
  pass "a concurrent scan exits silently rather than queueing a second wake for one verdict"
}

# --- an unreadable brief is an inability, not an answer ---------------------

test_unreadable_brief_reports_rather_than_claiming_intake() {
  have_tasks_axi || { skip_case unreadable-brief "tasks-axi not found"; return 0; }
  make_home unreadablebrief
  add_task alpha "first"
  give_brief alpha
  chmod 000 "$DATA/alpha/brief.md"
  scan >/dev/null
  chmod 644 "$DATA/alpha/brief.md"
  assert_contains "$SCAN_OUT" "dispatch unknown" \
    "a brief that exists but cannot be read was not reported as an inability"
  assert_contains "$SCAN_OUT" "brief-unreadable" "the report did not name why it could not evaluate"
  assert_contains "$SCAN_OUT" "$DATA/alpha/brief.md" "the report did not name the unreadable brief"
  assert_not_contains "$SCAN_OUT" "needs intake" \
    "an unreadable brief was reported as a task needing a brief that already exists"
  pass "a brief that exists but cannot be read reports rather than claiming the task needs intake"
}

# --- the capacity deadband --------------------------------------------------

# A dispatch costs roughly one isolated copy, so the boundary moves in that same
# unit: entering blocked is the plain test, leaving it needs one more copy of
# room. Driven through the executable interface with a real pool directory of
# measured size, and with generous margins so a few KiB of drift cannot flake it.
test_blocked_verdict_holds_until_a_whole_clone_of_room_returns() {
  have_tasks_axi || { skip_case capacity-deadband "tasks-axi not found"; return 0; }
  make_home deadband
  local pool clone_kb free_kb reserve_mb
  pool="$HOME_DIR/pool"
  mkdir -p "$pool/copy"
  dd if=/dev/urandom of="$pool/copy/blob" bs=1048576 count=64 2>/dev/null \
    || fail "fixture: could not write a measurable isolated copy"
  add_task alpha "first"
  give_brief alpha
  clone_kb=$(du -sk "$pool/copy" | awk 'NR == 1 {print $1}')
  free_kb=$(free_kb_of "$pool")
  case "$clone_kb$free_kb" in *[!0-9]*|'') fail "fixture: could not size the pool" ;; esac
  [ "$clone_kb" -gt 32768 ] || fail "fixture: the measured copy is too small to damp with"

  # 1. Free space below the floor: blocked, on the plain test.
  reserve_mb=$(( free_kb / 1024 + 1024 ))
  FM_DISPATCH_POOL_ROOT_OVERRIDE="$pool" OS_RESERVE_MB="$reserve_mb" scan >/dev/null
  assert_contains "$SCAN_OUT" "dispatch blocked:" "an exhausted disk did not block"
  assert_contains "$SCAN_OUT" "release threshold" \
    "the blocked verdict did not name how much room is needed to clear it"
  [ "$(wakes)" = 1 ] || fail "the first blocked verdict did not queue a wake"

  # 2. Free space back above the floor but not by a whole copy: still blocked,
  #    and still silent, which is the entire point of the deadband.
  reserve_mb=$(( (free_kb - clone_kb) / 1024 - 16 ))
  FM_DISPATCH_POOL_ROOT_OVERRIDE="$pool" OS_RESERVE_MB="$reserve_mb" scan >/dev/null
  [ -z "$SCAN_OUT" ] || fail "a verdict inside the deadband woke firstmate again: $SCAN_OUT"
  [ "$(wakes)" = 1 ] || fail "a verdict inside the deadband queued a second wake"
  assert_grep 'announced_verdict=blocked' "$STATE/.dispatch-poll" \
    "free space barely above the floor released the blocked verdict"

  # 3. Free space above the floor by a whole copy: released, and worth a wake.
  reserve_mb=$(( (free_kb - 2 * clone_kb) / 1024 - 64 ))
  FM_DISPATCH_POOL_ROOT_OVERRIDE="$pool" OS_RESERVE_MB="$reserve_mb" scan >/dev/null
  assert_contains "$SCAN_OUT" "dispatch ready:" \
    "a whole copy of room above the floor did not release the blocked verdict"
  [ "$(wakes)" = 2 ] || fail "releasing the blocked verdict did not queue a wake"
  pass "a blocked verdict holds until a whole isolated copy of room returns"
}

# A home that has never made an isolated copy has no measured per-copy cost. The
# honest answer is zero - not an inability, and not an invented number - which
# degrades the floor to the operating-system reserve and the deadband to nothing.
test_a_pool_with_no_copies_uses_the_plain_comparison() {
  have_tasks_axi || { skip_case empty-pool "tasks-axi not found"; return 0; }
  make_home emptypool
  local pool
  pool="$HOME_DIR/pool"
  mkdir -p "$pool"
  add_task alpha "first"
  give_brief alpha
  FM_DISPATCH_POOL_ROOT_OVERRIDE="$pool" OS_RESERVE_MB=7 scan >/dev/null
  assert_contains "$SCAN_OUT" "dispatch ready:" "an empty pool did not evaluate the plain comparison"
  assert_contains "$SCAN_OUT" "clone reserve 0 MiB" \
    "an empty pool did not report a zero clone reserve, so a reader cannot see which case applied"
  assert_contains "$SCAN_OUT" "against a 7 MiB floor" \
    "an empty pool did not degrade the floor to the operating-system reserve alone"
  pass "a pool with no isolated copy reports a zero clone reserve and the plain comparison"
}

# --- the harness must not let the operator's own home into a scan -----------

# Every script here resolves FM_HOME before FM_ROOT_OVERRIDE, so an FM_HOME
# exported by the surrounding firstmate session outranks the hermetic root
# tests/wake-helpers.sh installs, and outranks every case-local override under
# it. A suite run from inside a live session would then scan the OPERATOR's
# backlog - real queued work, surfacing a real wake, inside cases that assert
# silence - and its failures would follow the operator's backlog rather than the
# code under test. The harness removes the ambient value; this pins that it
# stays removed, by running the real check exactly the way a suite that sources
# the harness leaves the environment.
test_the_harness_keeps_the_operators_home_out_of_a_scan() {
  have_tasks_axi || { skip_case harness-home "tasks-axi not found"; return 0; }
  make_home harnesshome
  local operator out
  operator="$TMP_ROOT/harness-operator-home"
  mkdir -p "$operator/data/alpha"
  tasks-axi add alpha "the operator's own queued work" --file "$operator/data/backlog.md" \
    >/dev/null 2>&1 || fail "fixture: could not stock the operator home's backlog"
  printf '# Brief\n\nA real brief sitting in the operator home.\n' \
    > "$operator/data/alpha/brief.md"
  out=$(FM_HOME="$operator" bash -c '
    # shellcheck disable=SC1090,SC1091
    . "$1/tests/wake-helpers.sh" >/dev/null 2>&1
    FM_STATE_OVERRIDE="$2" FM_DISPATCH_POOL_ROOT="$3" FM_DISPATCH_OS_RESERVE_MB=1 \
      "$1/bin/fm-dispatch-poll.sh" scan 2>&1
  ' _ "$ROOT" "$STATE" "$HOME_DIR")
  [ -z "$out" ] || fail "the harness let the operator's own backlog into a scan: $out"
  [ "$(wakes)" = 0 ] || fail "the harness let the operator's own backlog queue a wake"
  pass "the harness keeps an ambient FM_HOME out of a scan, whatever the operator's backlog holds"
}

# --- usage ------------------------------------------------------------------

test_rejects_an_unknown_verb() {
  make_home usage
  SCAN_OUT=$(PATH="$FAKEBIN:$PATH" FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$STATE" \
    "$POLL" definitely-not-a-verb 2>&1) && SCAN_CODE=0 || SCAN_CODE=$?
  expect_code 2 "$SCAN_CODE" "an unknown verb was not a usage error"
  pass "an unknown verb is a usage error"
}

test_silent_with_empty_backlog
test_dispatchable_work_wakes
test_briefed_is_distinguishable_from_intake
test_blocked_and_gated_work_is_not_dispatchable
test_work_already_under_way_is_not_dispatchable
test_unchanged_ready_set_does_not_repeat
test_dispatching_the_only_briefed_task_is_silent
test_an_unbriefed_queue_never_wakes_on_its_own
test_a_task_arriving_without_a_brief_is_not_a_wake
test_a_brief_arriving_on_a_standing_queue_wakes_and_names_it
test_a_second_brief_wakes_for_itself_alone
test_a_re_queued_task_can_be_a_gain_again
test_a_ready_set_returning_after_going_empty_wakes_again
test_an_inability_never_manufactures_a_gain
test_an_inability_after_the_briefed_set_records_what_it_saw
test_a_gain_arriving_during_a_machine_inability_still_surfaces
test_room_returning_re_offers_the_briefed_work
test_never_ranks_and_never_spawns
test_long_ready_set_is_bounded_and_the_cut_is_disclosed
test_no_room_is_reported_not_claimed_ready
test_ready_verdict_carries_its_capacity_evidence
test_unreadable_backlog_reports_rather_than_passes
test_absent_backlog_is_inert
test_backlog_that_does_not_parse_reports_rather_than_passes
test_missing_backlog_tool_reports_rather_than_passes
test_unmeasurable_disk_reports_rather_than_passes
test_unreadable_task_record_reports_rather_than_passes
test_invalid_capacity_configuration_reports_rather_than_passes
test_persisting_fault_resurfaces_on_a_bounded_cadence
test_ready_verdict_never_resurfaces_on_cadence
test_a_silent_ready_scan_keeps_the_fault_cadence
test_a_silent_none_scan_keeps_the_fault_cadence
test_superseded_verdicts_collapse_to_the_latest
test_a_hung_backlog_tool_is_reported_not_silently_killed
test_an_unusable_budget_reports_rather_than_defaulting
test_a_scan_that_finds_the_lock_held_stays_silent
test_unreadable_brief_reports_rather_than_claiming_intake
test_blocked_verdict_holds_until_a_whole_clone_of_room_returns
test_a_pool_with_no_copies_uses_the_plain_comparison
test_pool_copies_are_measured_below_the_per_repo_pool
test_a_pool_root_holding_copies_directly_still_measures
test_the_copy_measurement_shares_one_deadline
test_deadband_survives_an_intervening_none_verdict
test_deadband_survives_an_intervening_unknown_verdict
test_watcher_sweep_surfaces_a_changed_verdict
test_the_harness_keeps_the_operators_home_out_of_a_scan
test_rejects_an_unknown_verb
