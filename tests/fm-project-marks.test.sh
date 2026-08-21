#!/usr/bin/env bash
# Behavior tests for captain project marks: the refusal that makes working a
# project the captain excluded something firstmate CANNOT do quietly, rather
# than something it is reminded not to do.
#
# The mark is read by bin/fm-project-mode.sh --mark, which stays the single
# owner of "what posture did the captain register for this project", and it is
# enforced by bin/fm-spawn.sh at the same point that already consults that
# script for the standing delivery mode. The two verdicts differ deliberately:
# shipping at less rigor than the standing posture is a judgment firstmate is
# permitted to make and must state, so it warns and continues; working a marked
# project is not firstmate's judgment at all, so it refuses.
#
# Every case here asserts the POSITIVE refusal - its exact wording and its exit
# status - because a test that asserts only "no spawn happened" also passes when
# the command never ran.
#
# Every spawn case stops before any endpoint exists: the mark check runs ahead of
# backend creation, and a fake `tmux` that exits non-zero backstops the cases
# meant to get past it, so no window or worktree is ever created.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
PROJECT_MODE="$ROOT/bin/fm-project-mode.sh"
TMP_ROOT=$(fm_test_tmproot fm-project-marks)

EXCLUDED_MARK='hiaaa excluded 2026-08-21 the captain said twice not to work on hiaaa'
BLOCKED_MARK='hiaaa blocked-on-captain 2026-08-20 the archive holds 7 documents against the 60-100 these items need'

# A home with one registered project, one project directory, and a fake tmux that
# refuses, so a spawn that clears the mark check still creates nothing.
# Echoes "<home>|<project-dir>|<fakebin>".
make_home() {  # <name>
  local name=$1 home projects fakebin
  home="$TMP_ROOT/$name/home"
  projects="$TMP_ROOT/$name/projects"
  fakebin="$TMP_ROOT/$name/bin"
  mkdir -p "$home/data" "$home/state" "$home/config" "$projects/hiaaa" "$fakebin"
  printf '#!/bin/sh\nexit 1\n' > "$fakebin/tmux"
  chmod +x "$fakebin/tmux"
  printf -- '- hiaaa [no-mistakes] - fixture (added 2026-01-01)\n' > "$home/data/projects.md"
  printf '%s\n' "$home|$projects/hiaaa|$fakebin"
}

set_marks() {  # <home> [<line>...]
  local home=$1
  shift
  if [ "$#" -eq 0 ]; then
    rm -f "$home/config/project-marks"
  else
    printf '%s\n' "$@" > "$home/config/project-marks"
  fi
}

write_brief() {  # <home> <id> [<recorded-mode>]
  local home=$1 id=$2 mode=${3:-}
  mkdir -p "$home/data/$id"
  {
    printf 'You are a crewmate.\n\n# Definition of done\n'
    [ -z "$mode" ] || printf 'Delivery contract: mode=%s\n' "$mode"
  } > "$home/data/$id/brief.md"
}

run_spawn() {  # <home> <fakebin> <spawn-args...>
  local home=$1 fakebin=$2
  shift 2
  FM_ROOT_OVERRIDE='' FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$TMP_ROOT/projects-unused" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 FM_BACKEND=tmux PATH="$fakebin:$PATH" \
    "$SPAWN" "$@" 2>&1
}

run_mark() {  # <home> <project>
  FM_HOME="$1" FM_CONFIG_OVERRIDE="$1/config" FM_DATA_OVERRIDE="$1/data" \
    "$PROJECT_MODE" --mark "$2" 2>/dev/null
}

# The mark reader is the whole schema owner, so pin its output contract directly:
# an unmarked project and an absent file are silent successes, a marked one names
# the kind, the date it was set, and the reason, and two marks for one project
# resolve to the stricter of them whatever order they were written in.
test_mark_reader_reports_the_kind_date_and_reason() {
  local rec home proj fakebin out status
  rec=$(make_home reader)
  IFS='|' read -r home proj fakebin <<EOF
$rec
EOF

  set_marks "$home"
  out=$(run_mark "$home" hiaaa); status=$?
  expect_code 0 "$status" "an absent marks file should be a silent success"
  [ -z "$out" ] || fail "an absent marks file reported a mark: $out"

  set_marks "$home" '# the captain marks projects here' '' "$EXCLUDED_MARK"
  out=$(run_mark "$home" firstmate); status=$?
  expect_code 0 "$status" "an unmarked project should be a silent success"
  [ -z "$out" ] || fail "an unmarked project reported a mark: $out"

  out=$(run_mark "$home" hiaaa)
  [ "$out" = "excluded 2026-08-21 the captain said twice not to work on hiaaa" ] \
    || fail "the mark did not carry kind, date, and reason (got '$out')"

  set_marks "$home" "$BLOCKED_MARK"
  out=$(run_mark "$home" hiaaa)
  [ "$out" = "blocked-on-captain 2026-08-20 the archive holds 7 documents against the 60-100 these items need" ] \
    || fail "the feasibility mark did not carry kind, date, and reason (got '$out')"

  # A feasibility mark must never mask an authority one, in either order.
  set_marks "$home" "$BLOCKED_MARK" "$EXCLUDED_MARK"
  out=$(run_mark "$home" hiaaa)
  case "$out" in
    excluded\ *) ;;
    *) fail "a blocked-on-captain line masked an exclusion written after it (got '$out')" ;;
  esac
  set_marks "$home" "$EXCLUDED_MARK" "$BLOCKED_MARK"
  out=$(run_mark "$home" hiaaa)
  case "$out" in
    excluded\ *) ;;
    *) fail "a blocked-on-captain line masked an exclusion written before it (got '$out')" ;;
  esac
  pass "fm-project-mode --mark: reports kind, date, and reason, and resolves to the stricter mark"
}

# A mark that cannot be parsed must refuse rather than read as "not marked": a
# marks file nobody can read may be hiding an exclusion.
test_an_unparseable_marks_file_refuses_instead_of_reading_as_clean() {
  local rec home proj fakebin label line out status n=0
  rec=$(make_home malformed)
  IFS='|' read -r home proj fakebin <<EOF
$rec
EOF
  while IFS='|' read -r label line; do
    [ -n "$label" ] || continue
    n=$((n + 1))
    set_marks "$home" "$line"
    out=$(FM_HOME="$home" FM_CONFIG_OVERRIDE="$home/config" FM_DATA_OVERRIDE="$home/data" \
      "$PROJECT_MODE" --mark hiaaa 2>&1); status=$?
    expect_code 2 "$status" "$label: an unparseable marks file should exit 2"
    assert_contains "$out" "may be hiding an exclusion" \
      "$label: the refusal did not say why an unreadable marks file is not 'not marked'"
  done <<'ROWS'
unknown kind|hiaaa paused 2026-08-21 waiting a bit
non-ISO date|hiaaa excluded 21/08/2026 the captain said so
no date at all|hiaaa excluded the captain said so
no reason|hiaaa excluded 2026-08-21
ROWS
  [ "$n" -eq 4 ] || fail "expected 4 malformed cases, ran $n"

  # An unparseable line about ANOTHER project still refuses: the file is the unit
  # of trust, so a garbled name cannot be used to slip a mark past the check.
  set_marks "$home" 'somewhere-else excluded nope no-date-here' "$EXCLUDED_MARK"
  out=$(FM_HOME="$home" FM_CONFIG_OVERRIDE="$home/config" FM_DATA_OVERRIDE="$home/data" \
    "$PROJECT_MODE" --mark firstmate 2>&1); status=$?
  expect_code 2 "$status" "a malformed line about another project should still refuse"
  pass "fm-project-mode --mark: an unparseable marks file refuses rather than failing open"
}

# The refusal itself, for both kinds and for both kinds of work. The two messages
# must differ, because the reader's next action differs: one needs the captain,
# the other needs a condition met.
test_a_marked_project_refuses_every_spawn_and_names_the_mark() {
  local rec home proj fakebin out status
  rec=$(make_home refuse)
  IFS='|' read -r home proj fakebin <<EOF
$rec
EOF

  set_marks "$home" "$EXCLUDED_MARK"
  write_brief "$home" marks-excl-ship no-mistakes
  out=$(run_spawn "$home" "$fakebin" marks-excl-ship "$proj" claude --mode no-mistakes --yolo off); status=$?
  [ "$status" -ne 0 ] || fail "a ship spawn into an excluded project should exit non-zero"
  assert_contains "$out" "hiaaa is marked excluded (set 2026-08-21): the captain said twice not to work on hiaaa" \
    "the exclusion refusal did not name the kind, the date, and the reason"
  assert_contains "$out" "Only the captain lifts it" \
    "the exclusion refusal did not say who can lift it"
  assert_contains "$out" "Refusing to create task marks-excl-ship" \
    "the exclusion refusal did not name what it refused"
  assert_absent "$home/state/marks-excl-ship.meta" "a refused spawn wrote a task record"

  # An investigation is still working the project, so a scout refuses too.
  write_brief "$home" marks-excl-scout
  out=$(run_spawn "$home" "$fakebin" marks-excl-scout "$proj" claude --scout); status=$?
  [ "$status" -ne 0 ] || fail "a scout spawn into an excluded project should exit non-zero"
  assert_contains "$out" "hiaaa is marked excluded (set 2026-08-21)" \
    "the exclusion refusal did not name the mark on a scout spawn"
  assert_absent "$home/state/marks-excl-scout.meta" "a refused scout spawn wrote a task record"

  set_marks "$home" "$BLOCKED_MARK"
  write_brief "$home" marks-block-ship no-mistakes
  out=$(run_spawn "$home" "$fakebin" marks-block-ship "$proj" claude --mode no-mistakes --yolo off); status=$?
  [ "$status" -ne 0 ] || fail "a ship spawn into a blocked-on-captain project should exit non-zero"
  assert_contains "$out" "hiaaa is marked blocked-on-captain (set 2026-08-20): the archive holds 7 documents against the 60-100 these items need" \
    "the feasibility refusal did not name the kind, the date, and the reason"
  assert_contains "$out" "--despite-block" \
    "the feasibility refusal did not name the action that clears it for an independent task"
  assert_absent "$home/state/marks-block-ship.meta" "a refused spawn wrote a task record"

  # The two refusals must not read alike: an exclusion offers no way through.
  set_marks "$home" "$EXCLUDED_MARK"
  out=$(run_spawn "$home" "$fakebin" marks-excl-ship "$proj" claude --mode no-mistakes --yolo off || true)
  assert_not_contains "$out" "re-run with --despite-block" \
    "the exclusion refusal offered the feasibility mark's way through"
  pass "fm-spawn: a marked project refuses every spawn, and the two kinds refuse differently"
}

# An exclusion is an authority state, so no flag lifts it - only the captain
# removing the line does.
test_no_flag_overrides_an_exclusion() {
  local rec home proj fakebin out status
  rec=$(make_home authority)
  IFS='|' read -r home proj fakebin <<EOF
$rec
EOF
  set_marks "$home" "$EXCLUDED_MARK"
  write_brief "$home" marks-auth-1 no-mistakes
  out=$(run_spawn "$home" "$fakebin" marks-auth-1 "$proj" claude --mode no-mistakes --yolo off \
    --despite-block "internal tooling only, touches no scanned document"); status=$?
  [ "$status" -ne 0 ] || fail "--despite-block should not carry a spawn past an exclusion"
  assert_contains "$out" "--despite-block does not apply to an exclusion" \
    "the refusal did not say the flag has no authority over an exclusion"
  assert_contains "$out" "hiaaa is marked excluded (set 2026-08-21)" \
    "the refusal stopped naming the mark once the flag was passed"
  assert_absent "$home/state/marks-auth-1.meta" "a refused spawn wrote a task record"
  pass "fm-spawn: an exclusion has no override; only the captain lifts it"
}

# A feasibility block is partial: work that does not depend on the missing input
# may proceed, but only on an explicit stated reason, never silently.
test_a_stated_reason_carries_a_spawn_past_a_feasibility_block() {
  local rec home proj fakebin out
  rec=$(make_home feasibility)
  IFS='|' read -r home proj fakebin <<EOF
$rec
EOF
  set_marks "$home" "$BLOCKED_MARK"
  write_brief "$home" marks-feas-1 no-mistakes
  out=$(run_spawn "$home" "$fakebin" marks-feas-1 "$proj" claude --mode no-mistakes --yolo off \
    --despite-block "reindexes the CLI, touches no scanned document" || true)
  assert_not_contains "$out" "Refusing to create task marks-feas-1" \
    "a stated reason did not carry the spawn past the feasibility block"
  assert_contains "$out" "despite its blocked-on-captain mark (set 2026-08-20)" \
    "proceeding past a feasibility block was not announced"
  assert_contains "$out" "reindexes the CLI, touches no scanned document" \
    "the announcement did not carry the stated reason"
  pass "fm-spawn: a feasibility block is partial and opens only on a stated reason"
}

# A flag that grants nothing where it is passed would train firstmate to carry it
# everywhere, so it is refused rather than ignored.
test_the_override_flag_is_refused_where_it_grants_nothing() {
  local rec home proj fakebin out status
  rec=$(make_home hygiene)
  IFS='|' read -r home proj fakebin <<EOF
$rec
EOF
  set_marks "$home"
  write_brief "$home" marks-hyg-1 no-mistakes
  out=$(run_spawn "$home" "$fakebin" marks-hyg-1 "$proj" claude --mode no-mistakes --yolo off \
    --despite-block "no reason to be here"); status=$?
  [ "$status" -ne 0 ] || fail "--despite-block on an unmarked project should exit non-zero"
  assert_contains "$out" "carries no mark" \
    "the refusal did not say the flag grants nothing on an unmarked project"

  out=$(run_spawn "$home" "$fakebin" marks-hyg-1 "$proj" claude --mode no-mistakes --yolo off \
    --despite-block ""); status=$?
  [ "$status" -ne 0 ] || fail "an empty --despite-block value should exit non-zero"
  assert_contains "$out" "--despite-block requires a non-empty value" \
    "an empty stated reason was accepted"

  # The stated reason becomes one key=value line in the task record, so a value
  # carrying a newline must never reach it.
  out=$(run_spawn "$home" "$fakebin" marks-hyg-1 "$proj" claude --mode no-mistakes --yolo off \
    --despite-block "first line
kind=forged"); status=$?
  [ "$status" -ne 0 ] || fail "a multi-line --despite-block value should exit non-zero"
  assert_contains "$out" "--despite-block must be a single line" \
    "a multi-line stated reason was accepted into the task record"
  out=$(run_spawn "$home" "$fakebin" marks-hyg-sm --secondmate --despite-block "no project here"); status=$?
  [ "$status" -ne 0 ] || fail "--despite-block on a secondmate spawn should exit non-zero"
  assert_contains "$out" "a secondmate spawn stands up a home, not work in a project" \
    "the refusal did not say why the flag has no meaning for a secondmate spawn"
  pass "fm-spawn: the override flag is refused where it grants nothing or would forge a record"
}

# An unreadable marks file must stop dispatch, not wave it through.
test_an_unparseable_marks_file_refuses_the_spawn() {
  local rec home proj fakebin out status
  rec=$(make_home unreadable)
  IFS='|' read -r home proj fakebin <<EOF
$rec
EOF
  set_marks "$home" 'hiaaa excluded yesterday the captain said so'
  write_brief "$home" marks-unread-1 no-mistakes
  out=$(run_spawn "$home" "$fakebin" marks-unread-1 "$proj" claude --mode no-mistakes --yolo off); status=$?
  [ "$status" -ne 0 ] || fail "an unparseable marks file should stop the spawn"
  assert_contains "$out" "could not read this home's captain project marks" \
    "the refusal did not name the unreadable marks as the reason"
  assert_contains "$out" "refusing to create task marks-unread-1" \
    "the refusal did not name what it refused"
  assert_absent "$home/state/marks-unread-1.meta" "a refused spawn wrote a task record"
  pass "fm-spawn: an unreadable marks file refuses rather than dispatching"
}

# The normal path must be untouched: no new refusal, no new prompt, no new output
# on a clean dispatch into an unmarked project.
test_an_unmarked_project_is_entirely_unaffected() {
  local rec home proj fakebin marked_out clean_out
  rec=$(make_home clean)
  IFS='|' read -r home proj fakebin <<EOF
$rec
EOF
  set_marks "$home"
  write_brief "$home" marks-clean-1 no-mistakes
  clean_out=$(run_spawn "$home" "$fakebin" marks-clean-1 "$proj" claude --mode no-mistakes --yolo off || true)
  assert_not_contains "$clean_out" "is marked" "an unmarked project reported a mark"
  assert_not_contains "$clean_out" "project marks" "an unmarked project mentioned the marks file"
  assert_not_contains "$clean_out" "despite-block" "an unmarked project mentioned the override flag"

  # A marks file that exists but names other projects is equally a clean path.
  set_marks "$home" '# marks for other projects' 'somewhere-else excluded 2026-08-21 not this project'
  marked_out=$(run_spawn "$home" "$fakebin" marks-clean-1 "$proj" claude --mode no-mistakes --yolo off || true)
  [ "$marked_out" = "$clean_out" ] \
    || fail "a mark on another project changed this project's dispatch"$'\n'"$marked_out"
  pass "fm-spawn: an unmarked project dispatches exactly as it did before"
}

test_mark_reader_reports_the_kind_date_and_reason
test_an_unparseable_marks_file_refuses_instead_of_reading_as_clean
test_a_marked_project_refuses_every_spawn_and_names_the_mark
test_no_flag_overrides_an_exclusion
test_a_stated_reason_carries_a_spawn_past_a_feasibility_block
test_the_override_flag_is_refused_where_it_grants_nothing
test_an_unparseable_marks_file_refuses_the_spawn
test_an_unmarked_project_is_entirely_unaffected
echo "# all fm-project-marks tests passed"
