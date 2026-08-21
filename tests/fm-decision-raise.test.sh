#!/usr/bin/env bash
# tests/fm-decision-raise.test.sh - structured decisions: a worker raises a
# decision as separate fields (the question, the options, the recommendation)
# and those fields survive every hop to the surface the captain answers on.
#
# The two properties under test are the ones the feature exists for:
#   1. a structured decision arrives structured - question, options and
#      recommendation still separate at the relay, not re-flattened into prose;
#   2. a decision that is NOT actually structured is VISIBLE as such, at the
#      relay, rather than reaching the captain looking structured. Fields that
#      can be faked are prose with extra steps, so the padded-blob case is
#      tested as carefully as the honest one.
# Free-text decisions are the majority case and are tested to be unchanged.
#
# No test here runs git: the decision record is plain file I/O, so the suite has
# no reason to be near a repository and cannot escape into one.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

RAISE="$ROOT/bin/fm-decision-raise.sh"
DRAIN="$ROOT/bin/fm-wake-drain.sh"
TMP_ROOT=$(fm_test_tmproot fm-decision-raise)

# FM_GATE_REFUSE_BYPASS is the harness escape documented by
# bin/fm-gate-refuse-lib.sh; it also keeps the gate probe from running git.
export FM_GATE_REFUSE_BYPASS=1

make_state() {  # <name> -> state dir
  local d="$TMP_ROOT/$1"
  mkdir -p "$d/state"
  printf '%s\n' "$d/state"
}

# Raise a decision that is genuinely a choice, with distinct fields.
raise_sound() {  # <status-file> <key>
  "$RAISE" raise --status "$1" --key "$2" \
    --question "Should the importer retry per request or per session?" \
    --option-id per-request "Retry per request - stateless, matches the gateway" \
    --option-id per-session "Retry per session - better under burst, needs a store" \
    --recommend per-request \
    --because "The gateway already carries a per-request token; a store is new infrastructure."
}

drain_section() {  # <state-dir> -> the OPEN DECISIONS section
  FM_STATE_OVERRIDE="$1" FM_GUARD_GRACE=99999 "$DRAIN" 2>/dev/null \
    | sed -n '/^OPEN DECISIONS (/,$p'
}

# The whole point: raised as fields, still fields at the relay. Asserted through
# the JSON payload a surface would read AND through the operator-facing digest,
# because a field that survives the first hop and is flattened at the second is
# worth nothing.
test_structured_decision_survives_the_relay() {
  local state status json section
  state=$(make_state survives)
  status="$state/importer.status"
  raise_sound "$status" retry-budget >/dev/null || fail "raising a sound decision failed"

  # The status line keeps the unchanged grammar and now carries the question.
  assert_grep 'needs-decision [key=retry-budget]: Should the importer retry per request or per session?' \
    "$status" "the raise must append an ordinary keyed status line carrying the question"

  json=$("$RAISE" show --status "$status" --key retry-budget --json) \
    || fail "show --json failed for a sound decision"
  assert_contains "$json" '"structured":true' "a raised decision must report as structured"
  assert_contains "$json" '"degenerate":[]' "a sound decision must carry no defects"
  assert_contains "$json" '"question":"Should the importer retry per request or per session?"' \
    "the question must survive as its own field"
  assert_contains "$json" '"id":"per-request"' "each option must keep its own identity"
  assert_contains "$json" '"id":"per-session"' "each option must keep its own identity"
  assert_contains "$json" '"recommend":{"option":"per-request"' \
    "the recommendation must name an option, separately from the question"

  # The relay firstmate actually reads.
  section=$(drain_section "$state")
  assert_contains "$section" 'Should the importer retry per request or per session?' \
    "the digest must show the question"
  assert_contains "$section" '(per-request) Retry per request' \
    "the digest must show each option distinctly"
  assert_contains "$section" '(per-session) Retry per session' \
    "the digest must show each option distinctly"
  assert_contains "$section" '-> recommends (per-request)' \
    "the digest must show the recommendation separately from the question"
  pass "a structured decision keeps question, options and recommendation separate to the relay"
}

# The majority case. A worker that writes an ordinary line must not be broken by
# this contract, and must not be reported as defective for declining it.
test_free_text_decision_is_unchanged() {
  local state status json section
  state=$(make_state freetext)
  status="$state/scope.status"
  printf 'needs-decision [key=scope]: should the legacy importer move in this pass?\n' >> "$status"

  json=$("$RAISE" show --status "$status" --key scope --json) \
    || fail "show --json must succeed for an unstructured decision"
  assert_contains "$json" '"structured":false' "a free-text decision must report as unstructured"
  assert_contains "$json" '"degenerate":[]' \
    "declining the structure is not a defect and must not be flagged as one"
  assert_contains "$json" '"note":"should the legacy importer move in this pass?"' \
    "the note must be carried through untouched"

  section=$(drain_section "$state")
  assert_contains "$section" 'scope [key=scope] needs-decision: should the legacy importer move in this pass?' \
    "a free-text decision must render in the digest exactly as before"
  assert_not_contains "$section" 'MALFORMED' \
    "a free-text decision must never be marked malformed"
  pass "an ordinary free-text decision folds, renders and reports exactly as before"
}

# The failure mode this feature invites: required fields filled by pasting the
# same blob into each one. It must be refused, and refused without writing.
test_padded_blob_is_refused_and_writes_nothing() {
  local state status err rc blob
  state=$(make_state padded)
  status="$state/t.status"
  blob="I looked at the retry path and there are several ways to go here. We could count per request, which matches the existing call sites, or per session, which behaves better under burst but needs a store we do not have. There are real tradeoffs either way and I am not certain which is right."
  err="$state/err.txt"
  rc=0
  "$RAISE" raise --status "$status" --key retry \
    --question "$blob" --option "$blob" --option "$blob" \
    --recommend 1 --because "$blob" >/dev/null 2>"$err" || rc=$?
  [ "$rc" -ne 0 ] || fail "a decision whose fields are one pasted blob must be refused"

  assert_grep 'question-too-long' "$err" "an over-long question must be named as a defect"
  assert_grep 'question-duplicated' "$err" "the same text in two fields must be named as a defect"
  assert_grep 'duplicate-options' "$err" "two identical options must be named as a defect"
  assert_grep 'raise it as free text' "$err" \
    "a refusal must point at the free-text line, so the pressure is never to pad the fields"

  assert_absent "$status" "a refused raise must not append a status line"
  assert_absent "${status%.status}.decisions" "a refused raise must not write a record"
  pass "a decision padded with one blob is refused, names every defect, and writes nothing"
}

# A recommendation that points at nothing is the coin flip the whole path exists
# to remove, so it must never be recordable.
test_recommendation_must_name_a_real_option() {
  local state status err rc
  state=$(make_state recommend)
  status="$state/t.status"
  err="$state/err.txt"
  rc=0
  "$RAISE" raise --status "$status" --key ship \
    --question "Ship the importer change now or after the freeze?" \
    --option "Ship now" --option "Ship after the freeze" \
    --recommend 7 --because "The freeze is three weeks out." >/dev/null 2>"$err" || rc=$?
  [ "$rc" -ne 0 ] || fail "a recommendation naming no real option must be refused"
  assert_grep 'recommend-unknown-option' "$err" "the dangling recommendation must be named"
  assert_absent "$status" "a refused raise must not append a status line"

  rc=0
  "$RAISE" raise --status "$status" --key ship \
    --question "Ship the importer change now or after the freeze?" \
    --option "Ship now" --option "Ship after the freeze" \
    --because "The freeze is three weeks out." >/dev/null 2>"$err" || rc=$?
  [ "$rc" -ne 0 ] || fail "a decision with no recommendation must be refused"
  assert_grep 'no-recommendation' "$err" "a missing recommendation must be named"
  pass "a recommendation must name a real option, or the decision is not recorded"
}

# The backstop. The writer refuses, but a record can still reach the file some
# other way - hand-written, or from a future writer. It must look wrong AT THE
# RELAY, to firstmate, rather than arrive at the captain looking structured.
test_degenerate_record_on_disk_is_visible_at_the_relay() {
  local state status section json rc
  state=$(make_state ondisk)
  status="$state/faked.status"
  printf 'needs-decision [key=blob]: there are a few ways to go and I am not sure\n' >> "$status"
  {
    printf 'decision\t1\tblob\t1787000000\n'
    printf 'question\tthere are a few ways to go and I am not sure\n'
    printf 'option\t1\tthere are a few ways to go and I am not sure\n'
    printf 'recommend\t9\t\n'
    printf 'end\tblob\n'
  } >> "$state/faked.decisions"

  section=$(drain_section "$state")
  assert_contains "$section" 'MALFORMED DECISION RECORD' \
    "a record that is not really structured must be marked malformed at the relay"
  assert_contains "$section" 'too-few-options' "the relay must name what is wrong"
  assert_contains "$section" 'recommend-unknown-option' "the relay must name what is wrong"
  assert_contains "$section" 'relay the note above, not these as options' \
    "the relay must say not to present the fields as options"
  assert_not_contains "$section" '(1) there are a few ways' \
    "a malformed record's fields must NOT be rendered as if they were options"

  rc=0
  json=$("$RAISE" show --status "$status" --key blob --json) || rc=$?
  [ "$rc" -ne 0 ] || fail "reading a degenerate record must report failure to its caller"
  assert_contains "$json" '"code":"too-few-options"' \
    "the machine payload must carry the defects, not just the human view"
  pass "a record that only looks structured is marked malformed at the relay, not relayed as options"
}

# A torn append must never be shown in part: half a decision presented as a
# whole one is the same defect wearing a different hat.
test_truncated_record_is_never_partly_used() {
  local state status section
  state=$(make_state torn)
  status="$state/torn.status"
  printf 'needs-decision [key=half]: half a question\n' >> "$status"
  {
    printf 'decision\t1\thalf\t1787000000\n'
    printf 'question\thalf a question\n'
    printf 'option\t1\tone option that was written before the crash\n'
  } >> "$state/torn.decisions"

  section=$(drain_section "$state")
  assert_contains "$section" 'truncated-record' "an unterminated record must be reported as truncated"
  assert_not_contains "$section" 'one option that was written before the crash' \
    "a truncated record must never have its fields rendered"
  pass "a torn record is reported as truncated and never rendered in part"
}

# The identity half of the contract, which the answering surface must agree
# with: an option id resolves to exactly one option, and an id that names no
# option is refused rather than guessed at.
test_option_identity_resolves_or_refuses() {
  local state status out rc
  state=$(make_state identity)
  status="$state/t.status"
  raise_sound "$status" retry-budget >/dev/null || fail "raising failed"

  out=$("$RAISE" option --status "$status" --key retry-budget --id per-session) \
    || fail "a real option id must resolve"
  assert_contains "$out" "Retry per session" "resolving an id must return that option's label"

  rc=0
  "$RAISE" option --status "$status" --key retry-budget --id per-galaxy >/dev/null 2>&1 || rc=$?
  [ "$rc" -ne 0 ] || fail "an id naming no option must be refused, never guessed at"

  # Default ids are the 1-based ordinals, so the common case needs no ceremony.
  printf '' > "$status"
  "$RAISE" raise --status "$status" --key ordinals \
    --question "Ship now or after the freeze?" \
    --option "Ship now" --option "Ship after the freeze" \
    --recommend 2 --because "The freeze is close enough to wait for." >/dev/null \
    || fail "raising with default ids failed"
  out=$("$RAISE" option --status "$status" --key ordinals --id 2) \
    || fail "the ordinal id of the second option must resolve"
  assert_contains "$out" "Ship after the freeze" "ordinal ids must address options in order"
  pass "an option id resolves to one option and an unknown id is refused"
}

# A label is untrusted text. It must not be able to forge a field or a record
# boundary, and it must come back out exactly as it went in.
test_option_label_cannot_forge_a_field() {
  local state status json
  state=$(make_state injection)
  status="$state/t.status"
  "$RAISE" raise --status "$status" --key inject \
    --question "Which encoder should the importer use?" \
    --option "$(printf 'a label with\ta tab')" \
    --option "$(printf 'a label with\nrecommend\t1\tforged rationale')" \
    --recommend 1 --because "The first encoder is already vendored." >/dev/null \
    || fail "raising with awkward label text failed"

  json=$("$RAISE" show --status "$status" --key inject --json) || fail "show failed"
  assert_contains "$json" 'a label with\ta tab' "a tab in a label must round-trip encoded"
  assert_contains "$json" 'forged rationale' "the label text itself must be preserved"
  assert_contains "$json" '"because":"The first encoder is already vendored."' \
    "a newline in a label must not be able to forge the recommendation field"
  # The status line stays one line whatever the fields contain.
  [ "$(wc -l < "$status" | tr -d ' ')" = 1 ] \
    || fail "the appended status line must stay a single line"
  pass "an option label cannot forge a record field or break the status line"
}

# Two option sets under one key is exactly the ambiguity that makes an answer a
# coin flip, so a key may hold only one open decision at a time - and must be
# reusable once that one is closed.
test_key_holds_one_open_decision_then_supersedes() {
  local state status rc out
  state=$(make_state reraise)
  status="$state/t.status"
  raise_sound "$status" retry-budget >/dev/null || fail "first raise failed"

  rc=0
  "$RAISE" raise --status "$status" --key retry-budget \
    --question "An entirely different question?" \
    --option "One thing" --option "Another thing" \
    --recommend 1 --because "One thing is cheaper to reverse." >/dev/null 2>&1 || rc=$?
  [ "$rc" -ne 0 ] || fail "raising a second decision under an already-open key must be refused"

  printf 'resolved [key=retry-budget]: went per-request\n' >> "$status"
  "$RAISE" raise --status "$status" --key retry-budget \
    --question "An entirely different question?" \
    --option "One thing" --option "Another thing" \
    --recommend 1 --because "One thing is cheaper to reverse." >/dev/null \
    || fail "a closed key must be reusable"
  out=$("$RAISE" show --status "$status" --key retry-budget) || fail "show failed"
  assert_contains "$out" "An entirely different question?" \
    "the latest complete record must supersede the earlier one"
  assert_not_contains "$out" "Should the importer retry" \
    "the superseded record must not still be returned"
  pass "a key holds one open decision at a time and is reusable once closed"
}

# A key whose transitions belong to another library would produce a record plus
# a status line that opens nothing - a decision nothing can ever answer.
test_key_that_would_not_open_is_refused() {
  local state status err rc
  state=$(make_state reserved)
  status="$state/t.status"
  err="$state/err.txt"
  rc=0
  "$RAISE" raise --status "$status" --key pending-reply-abc123 \
    --question "Which way should the importer go?" \
    --option "This way" --option "That way" \
    --recommend 1 --because "This way is already vendored." >/dev/null 2>"$err" || rc=$?
  [ "$rc" -ne 0 ] || fail "a key that would not open a decision must be refused"
  assert_grep 'would not open a decision' "$err" "the refusal must say the line would not open anything"
  assert_absent "$status" "a refused raise must not append a status line"
  assert_absent "${status%.status}.decisions" "a refused raise must not write a record"
  pass "a key whose line would not open a decision is refused before anything is written"
}

# A secondmate escalating to its parent writes to the PARENT's status file. The
# record must follow the status file rather than the home the worker runs in, or
# the fields never reach the home that renders the decision.
test_record_follows_the_status_file_across_homes() {
  local parent child section
  parent=$(make_state parenthome)
  child=$(make_state childhome)
  FM_HOME="$child/.." "$RAISE" raise --status "$parent/domain-audit.status" --key vendor-swap \
    --question "Should the audit swap the vendor client or wrap it?" \
    --option-id swap "Swap to the new client - smaller surface, a breaking upgrade" \
    --option-id wrap "Wrap the current client - no upgrade, one more layer" \
    --recommend wrap --because "The upgrade lands mid-quarter; wrapping defers it." >/dev/null \
    || fail "raising against a parent status file failed"

  assert_present "$parent/domain-audit.decisions" \
    "the record must land beside the status file it belongs to"
  assert_absent "$child/domain-audit.decisions" \
    "the record must not land in the home the worker happened to run in"

  section=$(drain_section "$parent")
  assert_contains "$section" '(wrap) Wrap the current client' \
    "the parent home's digest must show the escalated decision's options"
  pass "the record follows the status file across homes, so an escalation arrives structured"
}

# On the bash 3.2 that stock macOS ships, a sibling library that cannot be
# sourced can end a script silently. A raise that wrote nothing while looking
# like it succeeded is the worst outcome this path has, so a broken install must
# refuse by name.
test_broken_install_refuses_by_name() {
  local state root err rc
  state=$(make_state brokeninstall)
  root="$state/../root"
  mkdir -p "$root"
  cp -R "$ROOT/bin" "$root/bin"
  : > "$root/bin/fm-decision-lib.sh"
  err="$state/err.txt"
  rc=0
  "$root/bin/fm-decision-raise.sh" raise --status "$state/t.status" --key k \
    --question "Which encoder should the importer use?" \
    --option "The vendored one" --option "The new one" \
    --recommend 1 --because "The vendored one is already on the path." \
    >/dev/null 2>"$err" || rc=$?
  [ "$rc" -ne 0 ] || fail "a raise with an unusable library must not report success"
  assert_grep 'required library function' "$err" \
    "a broken install must name the missing function rather than failing silently"
  assert_absent "$state/t.status" "a refused raise must not append a status line"
  pass "an unusable library refuses by name instead of silently writing nothing"
}

test_structured_decision_survives_the_relay
test_free_text_decision_is_unchanged
test_padded_blob_is_refused_and_writes_nothing
test_recommendation_must_name_a_real_option
test_degenerate_record_on_disk_is_visible_at_the_relay
test_truncated_record_is_never_partly_used
test_option_identity_resolves_or_refuses
test_option_label_cannot_forge_a_field
test_key_holds_one_open_decision_then_supersedes
test_key_that_would_not_open_is_refused
test_record_follows_the_status_file_across_homes
# One drain renders many decisions in a row. Each must be described by its OWN
# record: a structured decision must not lend its fields to the free-text one
# after it, and a malformed one must not borrow the sound one before it.
test_mixed_decisions_do_not_borrow_each_others_fields() {
  local state section
  state=$(make_state mixed)
  raise_sound "$state/sound.status" retry-budget >/dev/null || fail "raising failed"
  printf 'needs-decision [key=blob]: there are a few ways to go and I am not sure\n' \
    >> "$state/faked.status"
  {
    printf 'decision\t1\tblob\t1787000000\n'
    printf 'question\tthere are a few ways to go and I am not sure\n'
    printf 'option\t1\tthere are a few ways to go and I am not sure\n'
    printf 'recommend\t9\t\n'
    printf 'end\tblob\n'
  } >> "$state/faked.decisions"
  printf 'needs-decision [key=scope]: should the legacy importer move in this pass?\n' \
    >> "$state/zplain.status"

  section=$(drain_section "$state")
  # The sound one keeps its fields.
  assert_contains "$section" '(per-request) Retry per request'     "the structured decision must still show its own options"
  # The malformed one is named, and shows no options at all.
  assert_contains "$section" 'MALFORMED DECISION RECORD'     "the malformed decision must be marked at the relay"
  # Exactly one recommendation line in the whole section: only the sound one has
  # one. A leak would print the sound record's recommendation again.
  [ "$(printf '%s\n' "$section" | grep -c -- '-> recommends')" = 1 ] \
    || fail "a decision borrowed another decision's recommendation"
  # The free-text decision renders bare.
  assert_contains "$section" 'zplain [key=scope] needs-decision: should the legacy importer move in this pass?'     "the free-text decision must still render as itself"
  pass "each decision in one drain is described only by its own record"
}

test_broken_install_refuses_by_name
test_mixed_decisions_do_not_borrow_each_others_fields
