#!/usr/bin/env bash
# bin/fm-redaction-guard.sh must keep archive document titles out of committed
# history, and must refuse rather than pass whenever it cannot evaluate.
#
# Firstmate's private records under data/ are gitignored, so they never enter a
# commit themselves. The exposure this guard covers is text copied OUT of those
# records into the two surfaces that do land: the staged diff of tracked files,
# and the commit message. A third path exists whenever .gitignore is weakened or
# bypassed with `git add -f`, so a staged private path is refused on its own.
#
# Every title used below is synthesised for the test. No fixture in this file
# reproduces any real document title, and no test reads any live archive.
#
# The document-context fixtures are composed from variables rather than written
# as literal text, so this test's own source never places a quoted title-shaped
# string next to a document anchor. That keeps the suite honest: the guard would
# reject its own test file otherwise.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GUARD="$ROOT/bin/fm-redaction-guard.sh"

TMPROOT=
cleanup() { [ -n "$TMPROOT" ] && rm -rf "$TMPROOT"; }
trap cleanup EXIT

fail() {
  printf 'not ok - %s\n' "$1" >&2
  exit 1
}

pass() {
  printf 'ok - %s\n' "$1"
}

TMPROOT="$(mktemp -d "${TMPDIR:-/tmp}/fm-redaction-guard.XXXXXX")"

# A scratch repository shaped like a firstmate home: private roots ignored,
# tracked material visible.
new_repo() {
  local repo
  repo="$TMPROOT/repo-$1"
  mkdir -p "$repo"
  git -C "$repo" init -q
  git -C "$repo" config user.email test@example.invalid
  git -C "$repo" config user.name 'Redaction Guard Test'
  git -C "$repo" config commit.gpgsign false
  printf 'data/\nstate/\nconfig/\n' >"$repo/.gitignore"
  mkdir -p "$repo/docs" "$repo/data"
  printf 'seed\n' >"$repo/docs/seed.md"
  git -C "$repo" add .gitignore docs/seed.md
  git -C "$repo" commit -qm 'seed'
  printf '%s\n' "$repo"
}

# Write a message file and run the guard's commit-msg entry point against the
# repository's current index.
run_guard() {
  local repo=$1 msg=$2
  printf '%s\n' "$msg" >"$repo/.msg"
  ( cd "$repo" && bash "$GUARD" check-commit-msg .msg ) 2>&1
}

run_guard_status() {
  local repo=$1 msg=$2
  printf '%s\n' "$msg" >"$repo/.msg"
  ( cd "$repo" && bash "$GUARD" check-commit-msg .msg ) >"$repo/.out" 2>&1
  printf '%s\n' "$?"
}

# --- the leak this guard exists to stop -------------------------------------

test_document_context_title_is_refused() {
  local repo anchor title out rc
  repo="$(new_repo doc-title)"
  anchor='document'
  title='Northwind Municipal Waterworks - Annual Meter Reading 2019'
  # Composed, so this test's source carries no anchor-adjacent quoted title.
  printf -- '- reprocessed the %s "%s"\n' "$anchor" "$title" >"$repo/docs/notes.md"
  git -C "$repo" add docs/notes.md
  rc="$(run_guard_status "$repo" 'docs: record reprocessing')"
  out="$(cat "$repo/.out")"
  [ "$rc" = "1" ] \
    || fail "a title-shaped literal in a document context must refuse the commit (got exit $rc: $out)"
  case "$out" in
    *docs/notes.md*) : ;;
    *) fail "refusal must name the offending file (got: $out)" ;;
  esac
  pass "a quoted title-shaped literal in a document context refuses the commit"
}

test_id_reference_is_accepted() {
  local repo anchor rc out
  repo="$(new_repo doc-id)"
  anchor='document'
  # The same sentence, referring to the document by ID instead of by title.
  printf -- '- reprocessed %s 4711 and confirmed its text layer\n' "$anchor" >"$repo/docs/notes.md"
  git -C "$repo" add docs/notes.md
  rc="$(run_guard_status "$repo" 'docs: record reprocessing')"
  out="$(cat "$repo/.out")"
  [ "$rc" = "0" ] \
    || fail "an ID reference in a document context must pass (got exit $rc: $out)"
  pass "an ID reference in the same document context passes"
}

test_commit_message_is_covered() {
  local repo anchor title rc out msg
  repo="$(new_repo msg-title)"
  anchor='document'
  title='Northwind Municipal Waterworks - Annual Meter Reading 2019'
  printf 'unrelated tracked edit\n' >"$repo/docs/notes.md"
  git -C "$repo" add docs/notes.md
  msg="$(printf 'fix: reprocess the %s "%s"' "$anchor" "$title")"
  rc="$(run_guard_status "$repo" "$msg")"
  out="$(cat "$repo/.out")"
  [ "$rc" = "1" ] \
    || fail "a title in the commit message must refuse the commit (got exit $rc: $out)"
  pass "the commit message is checked, not only the staged diff"
}

test_forced_private_path_is_refused() {
  local repo rc out
  repo="$(new_repo private-path)"
  printf 'private record\n' >"$repo/data/archive-notes.md"
  git -C "$repo" add -f data/archive-notes.md
  rc="$(run_guard_status "$repo" 'chore: add notes')"
  out="$(cat "$repo/.out")"
  [ "$rc" = "1" ] \
    || fail "a force-added private path must refuse the commit (got exit $rc: $out)"
  case "$out" in
    *data/archive-notes.md*) : ;;
    *) fail "refusal must name the staged private path (got: $out)" ;;
  esac
  pass "a staged private path is refused on its own, without reading its content"
}

# --- ordinary work must not trip the guard ----------------------------------

test_ordinary_repo_prose_passes() {
  local repo rc out
  repo="$(new_repo ordinary)"
  {
    # Backticked code spans are deliberate corpus: a backtick literal must not
    # read as a quoted title. SC2016 is the point, not a mistake.
    # shellcheck disable=SC2016
    printf -- '- `bin/fm-spawn.sh` now validates the worktree before dispatch\n'
    printf -- '- see docs/configuration.md for the Runtime backend contract\n'
    printf -- '- fixed a race in fm-watch.sh reported as issue #2191\n'
    printf -- '- the Herdr backend and the Orca backend both pass the smoke lane\n'
  } >"$repo/docs/notes.md"
  git -C "$repo" add docs/notes.md
  rc="$(run_guard_status "$repo" 'fix(spawn): let projects with no origin spawn workers')"
  out="$(cat "$repo/.out")"
  [ "$rc" = "0" ] \
    || fail "ordinary firstmate prose must not trip the guard (got exit $rc: $out)"
  pass "ordinary firstmate prose, paths and identifiers pass cleanly"
}

test_title_outside_document_context_passes() {
  local repo rc out title
  repo="$(new_repo no-anchor)"
  title='Northwind Municipal Waterworks - Annual Meter Reading 2019'
  # Title-shaped, but nothing marks it as a document reference.
  printf -- '- the release is named "%s"\n' "$title" >"$repo/docs/notes.md"
  git -C "$repo" add docs/notes.md
  rc="$(run_guard_status "$repo" 'docs: name the release')"
  out="$(cat "$repo/.out")"
  [ "$rc" = "0" ] \
    || fail "a title-shaped string with no document context must pass (got exit $rc: $out)"
  pass "a title-shaped string outside a document context passes"
}

test_doc_cross_reference_passes() {
  local repo rc out section
  repo="$(new_repo cross-ref)"
  # Measured false-positive class: an ordinary cross-reference to a section of a
  # documentation file. The path component must not read as a document context.
  section='Runtime Backend Selection'
  printf -- '- see docs/configuration.md "%s" for the contract\n' "$section" >"$repo/docs/notes.md"
  git -C "$repo" add docs/notes.md
  rc="$(run_guard_status "$repo" 'docs: point at the contract')"
  out="$(cat "$repo/.out")"
  [ "$rc" = "0" ] \
    || fail "a documentation cross-reference must not trip the guard (got exit $rc: $out)"
  pass "a documentation cross-reference with a quoted section name passes"
}

test_scanner_is_not_vacuous() {
  local anchor title out rc
  # A positive control for the false-positive measurement: prove the same
  # scanner that reports zero on real content still fires on a synthesised leak.
  anchor='document'
  title='Northwind Municipal Waterworks - Annual Meter Reading 2019'
  out="$(printf -- '- reprocessed the %s "%s"\n' "$anchor" "$title" \
    | bash "$GUARD" check-text --label CONTROL 2>&1)" && rc=0 || rc=$?
  [ "${rc:-0}" = "1" ] \
    || fail "check-text must refuse a synthesised leak (got exit ${rc:-0}: $out)"
  pass "the scanner fires on a synthesised leak, so a zero measurement is not vacuous"
}

# --- it must refuse rather than pass when it cannot evaluate ----------------

test_unknown_mode_refuses() {
  local out rc
  out="$(bash "$GUARD" check-the-vibes 2>&1)" && rc=0 || rc=$?
  [ "${rc:-0}" = "2" ] \
    || fail "an unrecognised mode must refuse with exit 2, not pass (got exit ${rc:-0}: $out)"
  case "$out" in
    *cannot\ evaluate*) : ;;
    *) fail "an unrecognised mode must say it cannot evaluate (got: $out)" ;;
  esac
  pass "an unrecognised mode refuses with exit 2 and says why"
}

test_missing_message_file_refuses() {
  local repo out rc
  repo="$(new_repo no-msg)"
  out="$( cd "$repo" && bash "$GUARD" check-commit-msg .no-such-message 2>&1 )" && rc=0 || rc=$?
  [ "${rc:-0}" = "2" ] \
    || fail "an unreadable commit-message path must refuse with exit 2 (got exit ${rc:-0}: $out)"
  case "$out" in
    *cannot\ evaluate*) : ;;
    *) fail "an unreadable commit-message path must say it cannot evaluate (got: $out)" ;;
  esac
  pass "an unreadable commit-message path refuses with exit 2 and says why"
}

test_missing_dependency_refuses() {
  local repo out rc
  repo="$(new_repo no-dep)"
  # No git on PATH: the guard cannot read the index, so it must stop the commit.
  # An absolute interpreter, because the point of this case is an empty PATH.
  out="$( cd "$repo" && PATH=/nonexistent "$BASH" "$GUARD" check-commit-msg .gitignore 2>&1 )" && rc=0 || rc=$?
  [ "${rc:-0}" = "2" ] \
    || fail "a missing dependency must refuse with exit 2, not pass (got exit ${rc:-0}: $out)"
  case "$out" in
    *cannot\ evaluate*) : ;;
    *) fail "a missing dependency must say it cannot evaluate (got: $out)" ;;
  esac
  case "$out" in
    *git*) : ;;
    *) fail "a missing dependency must name the dependency (got: $out)" ;;
  esac
  pass "a missing dependency refuses with exit 2 and names what is missing"
}

test_outside_repository_refuses() {
  local out rc dir
  dir="$TMPROOT/not-a-repo"
  mkdir -p "$dir"
  out="$( cd "$dir" && bash "$GUARD" check-commit-msg /dev/null 2>&1 )" && rc=0 || rc=$?
  [ "${rc:-0}" = "2" ] \
    || fail "running outside a repository must refuse with exit 2 (got exit ${rc:-0}: $out)"
  pass "running outside a git repository refuses with exit 2"
}

# --- the escape hatch -------------------------------------------------------

test_exception_token_releases_only_its_own_finding() {
  local repo anchor title out token rc
  repo="$(new_repo exception)"
  anchor='document'
  title='Northwind Municipal Waterworks - Annual Meter Reading 2019'
  printf -- '- reprocessed the %s "%s"\n' "$anchor" "$title" >"$repo/docs/notes.md"
  git -C "$repo" add docs/notes.md

  out="$(run_guard "$repo" 'docs: record reprocessing')"
  token="$(printf '%s\n' "$out" | sed -n 's/.*\[exception-token \([0-9a-f]*\)\].*/\1/p' | head -1)"
  [ -n "$token" ] \
    || fail "each refusal must print an exception token (got: $out)"

  rc="$(run_guard_status "$repo" "$(printf 'docs: record reprocessing\n\nRedaction-Exception: %s synthesised example, checked against the archive by hand\n' "$token")")"
  [ "$rc" = "0" ] \
    || fail "the matching exception token must release the commit (got exit $rc: $(cat "$repo/.out"))"

  rc="$(run_guard_status "$repo" 'docs: record reprocessing

Redaction-Exception: deadbeef synthesised example, checked against the archive by hand')"
  [ "$rc" = "1" ] \
    || fail "a non-matching exception token must not release the commit (got exit $rc)"

  rc="$(run_guard_status "$repo" 'docs: record reprocessing

Redaction-Exception: all everything here is fine, honestly')"
  [ "$rc" = "1" ] \
    || fail "a blanket exception must not release the commit (got exit $rc)"

  rc="$(run_guard_status "$repo" "$(printf 'docs: record reprocessing\n\nRedaction-Exception: %s ok\n' "$token")")"
  [ "$rc" = "1" ] \
    || fail "an exception with no substantive reason must not release the commit (got exit $rc)"

  pass "an exception token releases exactly its own finding, and needs a stated reason"
}

test_exception_token_is_bound_to_the_literal() {
  local repo anchor title out token rc
  repo="$(new_repo exception-bound)"
  anchor='document'
  title='Northwind Municipal Waterworks - Annual Meter Reading 2019'
  printf -- '- reprocessed the %s "%s"\n' "$anchor" "$title" >"$repo/docs/notes.md"
  git -C "$repo" add docs/notes.md
  out="$(run_guard "$repo" 'docs: record reprocessing')"
  token="$(printf '%s\n' "$out" | sed -n 's/.*\[exception-token \([0-9a-f]*\)\].*/\1/p' | head -1)"

  # A different title in the same place is a different finding: the old token
  # must not carry over, which is what stops the hatch becoming a habit.
  title='Eastvale Regional Transit Authority - Quarterly Fare Review'
  printf -- '- reprocessed the %s "%s"\n' "$anchor" "$title" >"$repo/docs/notes.md"
  git -C "$repo" add docs/notes.md
  rc="$(run_guard_status "$repo" "$(printf 'docs: record reprocessing\n\nRedaction-Exception: %s synthesised example, checked against the archive by hand\n' "$token")")"
  [ "$rc" = "1" ] \
    || fail "an exception token must not carry over to a different literal (got exit $rc)"
  pass "an exception token is bound to the exact literal it was issued for"
}

# --- the CI entry point -----------------------------------------------------

test_check_range_covers_every_commit_in_the_range() {
  local repo anchor title out rc base
  repo="$(new_repo range)"
  base="$(git -C "$repo" rev-parse HEAD)"
  anchor='document'
  title='Northwind Municipal Waterworks - Annual Meter Reading 2019'

  printf 'a clean edit\n' >"$repo/docs/notes.md"
  git -C "$repo" add docs/notes.md
  git -C "$repo" commit -qm 'docs: a clean edit'
  out="$( cd "$repo" && bash "$GUARD" check-range "$base..HEAD" 2>&1 )" && rc=0 || rc=$?
  [ "${rc:-0}" = "0" ] \
    || fail "a clean range must pass (got exit ${rc:-0}: $out)"

  # A leak in an EARLIER commit of the range must still be caught, which is what
  # separates a range check from checking only the tip.
  printf -- '- reprocessed the %s "%s"\n' "$anchor" "$title" >"$repo/docs/notes.md"
  git -C "$repo" add docs/notes.md
  git -C "$repo" commit -qm 'docs: record reprocessing'
  printf 'another clean edit\n' >"$repo/docs/notes.md"
  git -C "$repo" add docs/notes.md
  git -C "$repo" commit -qm 'docs: another clean edit'

  out="$( cd "$repo" && bash "$GUARD" check-range "$base..HEAD" 2>&1 )" && rc=0 || rc=$?
  [ "${rc:-0}" = "1" ] \
    || fail "a range whose middle commit leaks must be refused (got exit ${rc:-0}: $out)"
  pass "check-range refuses a leak anywhere in the range, not only at the tip"
}

test_check_range_refuses_an_unresolvable_range() {
  local repo out rc
  repo="$(new_repo range-bad)"
  out="$( cd "$repo" && bash "$GUARD" check-range 'no-such-ref..HEAD' 2>&1 )" && rc=0 || rc=$?
  [ "${rc:-0}" = "2" ] \
    || fail "an unresolvable range must refuse with exit 2, not pass (got exit ${rc:-0}: $out)"
  pass "an unresolvable range refuses with exit 2"
}

# --- installation -----------------------------------------------------------

test_install_is_idempotent_and_hooks_run() {
  local repo rc out anchor title
  repo="$(new_repo install)"
  ( cd "$repo" && bash "$GUARD" install >/dev/null 2>&1 ) || fail "install must succeed in a repository"
  ( cd "$repo" && bash "$GUARD" install >/dev/null 2>&1 ) || fail "install must be idempotent"
  anchor='document'
  title='Northwind Municipal Waterworks - Annual Meter Reading 2019'
  printf -- '- reprocessed the %s "%s"\n' "$anchor" "$title" >"$repo/docs/notes.md"
  git -C "$repo" add docs/notes.md
  out="$( cd "$repo" && git commit -m 'docs: record reprocessing' 2>&1 )" && rc=0 || rc=$?
  [ "${rc:-0}" != "0" ] \
    || fail "after install, git commit must be stopped by the guard (got: $out)"
  pass "install wires the hook so a real git commit is stopped"
}

test_document_context_title_is_refused
test_id_reference_is_accepted
test_commit_message_is_covered
test_forced_private_path_is_refused
test_ordinary_repo_prose_passes
test_title_outside_document_context_passes
test_doc_cross_reference_passes
test_scanner_is_not_vacuous
test_unknown_mode_refuses
test_missing_message_file_refuses
test_missing_dependency_refuses
test_outside_repository_refuses
test_exception_token_releases_only_its_own_finding
test_exception_token_is_bound_to_the_literal
test_check_range_covers_every_commit_in_the_range
test_check_range_refuses_an_unresolvable_range
test_install_is_idempotent_and_hooks_run
