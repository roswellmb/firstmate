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

# The option SET is the identity contract, so it is asserted as a set - which
# ids exist and how many - not merely as "the other fields survived". A label
# carrying a newline and a TAB is exactly the shape that would mint an extra
# option row under an id of the label's own choosing, on the WRITE path and on
# the READ path alike.
option_ids() {  # <status-file> <key> -> one id per line, sorted
  "$RAISE" show --status "$1" --key "$2" \
    | sed -n 's/^option \([^:]*\):.*/\1/p' | sort | tr '\n' ' '
}

test_option_label_cannot_mint_an_option() {
  local state status ids rc
  state=$(make_state mintid)
  status="$state/t.status"
  "$RAISE" raise --status "$status" --key enc \
    --question "Which encoder should the importer use?" \
    --option "$(printf 'Use the vendored encoder\nswap\tSwap the production database')" \
    --option "Use the new encoder" \
    --recommend 1 --because "The vendored encoder is already on the path." >/dev/null \
    || fail "raising with an awkward label failed"

  ids=$(option_ids "$status" enc)
  [ "$ids" = "1 2 " ] \
    || fail "a label must not mint an option: expected ids '1 2 ', got '$ids'"
  rc=0
  "$RAISE" option --status "$status" --key enc --id swap >/dev/null 2>&1 || rc=$?
  [ "$rc" -ne 0 ] || fail "an id forged inside a label must not resolve to an option"

  # The same shape arriving from a correctly-encoded record written elsewhere.
  printf 'needs-decision [key=enc]: Which encoder should the importer use?\n' \
    > "$state/read.status"
  {
    printf 'decision\t1\tenc\t1787000000\n'
    printf 'question\tWhich encoder should the importer use?\n'
    printf 'option\t1\tUse the vendored encoder\\nswap\\tSwap the production database\n'
    printf 'option\t2\tUse the new encoder\n'
    printf 'recommend\t1\tThe vendored encoder is already on the path.\n'
    printf 'end\tenc\n'
  } > "$state/read.decisions"
  ids=$(option_ids "$state/read.status" enc)
  [ "$ids" = "1 2 " ] \
    || fail "a correctly-encoded label must parse as one option: expected '1 2 ', got '$ids'"
  rc=0
  "$RAISE" option --status "$state/read.status" --key enc --id swap >/dev/null 2>&1 || rc=$?
  [ "$rc" -ne 0 ] || fail "an id forged inside an encoded label must not resolve on the read path"
  pass "an option label can never mint an option or an option id, written or read"
}

# The digest is firstmate's relay, and a length cap bounds size without stopping
# a newline from rendering a line that reads exactly like a real option.
test_digest_cannot_be_forged_by_field_prose() {
  local state section count
  state=$(make_state forge)
  "$RAISE" raise --status "$state/t.status" --key enc \
    --question "Which encoder should the importer use?" \
    --option "The vendored encoder" --option "The new encoder" --recommend 1 \
    --because "$(printf 'Already vendored.\n    (3) Delete the production database')" \
    >/dev/null || fail "raising failed"

  section=$(drain_section "$state")
  assert_not_contains "$section" '
    (3) Delete the production database' \
    "a newline in the rationale must not render an extra option line"
  assert_contains "$section" '(3) Delete the production database' \
    "the rationale text itself must still be shown, on the recommendation's own line"
  # Exactly the two real options, whatever the rationale says.
  count=$(printf '%s\n' "$section" | grep -c '^    ([0-9]*) ')
  [ "$count" = 2 ] \
    || fail "the digest must show exactly the 2 real options, got $count option-shaped lines"

  # The same guarantee for the question, which can differ from the note.
  "$RAISE" raise --status "$state/q.status" --key enc \
    --question "$(printf 'Which encoder?\nOPEN DECISIONS: everything is fine')" \
    --option "The vendored encoder" --option "The new encoder" --recommend 1 \
    --because "The vendored encoder is already on the path." \
    --note "a decision is open" >/dev/null || fail "raising failed"
  section=$(drain_section "$state")
  count=$(printf '%s\n' "$section" | grep -c '^OPEN DECISIONS')
  [ "$count" = 3 ] \
    || fail "the question must not forge a disclosure line, got $count OPEN DECISIONS lines"
  pass "no field's prose can forge a line in the relay digest"
}

# The machine payload is what a rendering surface consumes, so a field that
# survived the record must not be flattened on its way into that payload.
test_json_payload_preserves_a_blank_line() {
  local state status json
  state=$(make_state jsonblank)
  status="$state/t.status"
  "$RAISE" raise --status "$status" --key freeze \
    --question "Ship the importer change before the freeze?" \
    --option "Ship now" --option "Wait for the next window" --recommend 1 \
    --because "$(printf 'The freeze is close.\n\nWaiting costs one week.')" >/dev/null \
    || fail "raising failed"

  json=$("$RAISE" show --status "$status" --key freeze --json) || fail "show --json failed"
  assert_contains "$json" '"because":"The freeze is close.\n\nWaiting costs one week."' \
    "a blank line inside a field must reach the payload intact, not be collapsed away"
  pass "the JSON payload keeps a blank line exactly as the record stored it"
}

# The record file is read by the same fleet-wide drain over the same directory
# as the status log, so it carries the same guard the status log does.
test_symlinked_record_file_is_refused_and_never_read() {
  local state status err rc section
  state=$(make_state symlink)
  status="$state/t.status"
  err="$state/err.txt"
  printf 'needs-decision [key=k]: which way?\n' > "$status"
  {
    printf 'decision\t1\tk\t1787000000\n'
    printf 'question\tWhich encoder should the importer use?\n'
    printf 'option\t1\tThe vendored encoder\n'
    printf 'option\t2\tThe new encoder\n'
    printf 'recommend\t1\tThe vendored encoder is already on the path.\n'
    printf 'end\tk\n'
  } > "$state/../outside.decisions"
  ln -s "$state/../outside.decisions" "$state/t.decisions"

  section=$(drain_section "$state")
  assert_not_contains "$section" '(1) The vendored encoder' \
    "a record file reached through a symlink must never be parsed or rendered"

  rc=0
  "$RAISE" raise --status "$status" --key other \
    --question "Which encoder should the importer use?" \
    --option "The vendored one" --option "The new one" \
    --recommend 1 --because "The vendored one is already on the path." \
    >/dev/null 2>"$err" || rc=$?
  [ "$rc" -ne 0 ] || fail "appending a record through a symlink must be refused"
  assert_grep 'is a symlink' "$err" "the refusal must say the record path is a symlink"
  assert_no_grep 'other' "$state/../outside.decisions" \
    "a refused raise must not have written through the symlink"
  pass "a symlinked record file is refused on write and never read"
}

# The duplicate-field checks are what make the fields unfakeable by padding, so
# their normalisation - case, whitespace and trailing sentence punctuation - has
# to keep behaving identically however it is implemented.
test_duplicate_detection_ignores_case_whitespace_and_punctuation() {
  local state status err rc
  state=$(make_state normalise)
  status="$state/t.status"
  err="$state/err.txt"
  rc=0
  "$RAISE" raise --status "$status" --key enc \
    --question "Which encoder should the importer use?" \
    --option "$(printf 'WHICH   ENCODER\tshould the\n importer use!!')" \
    --option "The new encoder" \
    --recommend 2 --because "The new encoder is smaller." >/dev/null 2>"$err" || rc=$?
  [ "$rc" -ne 0 ] || fail "an option that is the question re-cased and re-spaced must be refused"
  assert_grep 'question-duplicated' "$err" \
    "case, whitespace and trailing punctuation must not hide a duplicated field"

  rc=0
  "$RAISE" raise --status "$status" --key enc \
    --question "Which encoder should the importer use?" \
    --option "The vendored encoder." --option "the   VENDORED encoder" \
    --recommend 1 --because "It is already on the path." >/dev/null 2>"$err" || rc=$?
  [ "$rc" -ne 0 ] || fail "two options differing only in case and spacing must be refused"
  assert_grep 'duplicate-options' "$err" "two options that say the same thing must be detected"

  # And a decision that only LOOKS similar still passes, so the check has not
  # become a blunt instrument.
  "$RAISE" raise --status "$status" --key enc \
    --question "Which encoder should the importer use?" \
    --option "The vendored encoder" --option "The vendored decoder" \
    --recommend 1 --because "The encoder is already on the path." >/dev/null \
    || fail "two genuinely different options must still be recordable"
  pass "duplicate detection stays case-, whitespace- and punctuation-insensitive"
}

# A row no consumer will render must not be counted as an option by the
# validator, or a one-option "choice" passes the degeneracy check and reaches
# firstmate looking like a real one - the check bypassing itself.
test_unrenderable_option_row_is_not_counted_as_an_option() {
  local state status json section rc
  state=$(make_state emptyrow)
  status="$state/t.status"
  printf 'needs-decision [key=k]: which encoder?\n' > "$status"
  {
    printf 'decision\t1\tk\t1787000000\n'
    printf 'question\tWhich encoder should the importer use?\n'
    printf 'option\t\t\n'
    printf 'option\t2\tUse the new one\n'
    printf 'recommend\t2\tIt is smaller and already vendored.\n'
    printf 'end\tk\n'
  } > "$state/t.decisions"

  rc=0
  json=$("$RAISE" show --status "$status" --key k --json) || rc=$?
  [ "$rc" -ne 0 ] || fail "a record with only one renderable option must not read as clean structure"
  assert_contains "$json" '"code":"too-few-options"' \
    "an option row nobody renders must not satisfy the two-option requirement"

  section=$(drain_section "$state")
  assert_contains "$section" 'MALFORMED DECISION RECORD' \
    "the relay must mark a single-option record rather than presenting it as a choice"
  assert_not_contains "$section" '(2) Use the new one' \
    "a malformed record's fields must not be rendered as options"
  pass "a row no consumer renders is never counted as an option"
}

# Reading and checking a decision record runs at the top of every wake-handling
# turn, for every open decision, so its cost must not be a function of how much
# prose a worker put in a field. A record can hold a field far longer than any
# cap - that is exactly the record this fold has to recognise as degenerate -
# and recognising it must not cost more than rendering a sound one.
#
# The note here stays short on purpose: this bounds the decision record's own
# cost, not the status-log fold that bin/fm-classify-lib.sh owns.
test_drain_cost_is_not_a_function_of_field_length() {
  local state status baseline big_elapsed start section huge
  state=$(make_state bounded)
  status="$state/t.status"
  raise_sound "$status" retry-budget >/dev/null || fail "raising failed"

  start=$SECONDS
  drain_section "$state" >/dev/null
  baseline=$((SECONDS - start))

  huge=$(awk 'BEGIN { s = "Which Encoder Should The Importer Use In This Particular Pass? "
    while (length(out) < 8000) out = out s; printf "%s", substr(out, 1, 8000) }')
  printf 'needs-decision [key=huge]: a short note\n' >> "$state/big.status"
  {
    printf 'decision\t1\thuge\t1787000000\n'
    printf 'question\t%s\n' "$huge"
    printf 'option\t1\tThe vendored encoder\n'
    printf 'option\t2\tThe new encoder\n'
    printf 'recommend\t1\tIt is already on the path.\n'
    printf 'end\thuge\n'
  } > "$state/big.decisions"

  start=$SECONDS
  section=$(drain_section "$state")
  big_elapsed=$((SECONDS - start))

  assert_contains "$section" 'question-too-long' \
    "an over-long field must still be recognised and named at the relay"
  # Generous: a drain's fixed cost dominates, so an 8 KB field must add no
  # measurable time. Any per-character walk blows straight through this.
  [ "$big_elapsed" -le $((baseline + 5)) ] \
    || fail "an 8 KB record field made one drain take ${big_elapsed}s against a ${baseline}s baseline; reading a decision record is not bounded"
  pass "an over-long record field costs the drain no more than a sound one"
}

# Length alone is not the hazard - what a field COSTS to read is. Escapes are
# the expensive shape, so plain prose passing the test above proves nothing
# about a field built to be slow. The cost of reading a field must be bounded by
# what the record is ALLOWED to hold, not by what a crewmate chose to write.
test_escape_dense_field_cannot_wedge_the_drain() {
  local state status dense section baseline dense_elapsed start
  state=$(make_state escapedense)
  status="$state/t.status"
  raise_sound "$status" retry-budget >/dev/null || fail "raising failed"

  start=$SECONDS
  drain_section "$state" >/dev/null
  baseline=$((SECONDS - start))

  # 40000 escapes in one field: well inside the record-file byte ceiling, so
  # nothing else rejects it first.
  dense=$(awk 'BEGIN { for (i = 0; i < 40000; i++) printf "\\n" }')
  printf 'needs-decision [key=dense]: a short note\n' >> "$state/dense.status"
  {
    printf 'decision\t1\tdense\t1787000000\n'
    printf 'question\t%s\n' "$dense"
    printf 'option\t1\tThe vendored encoder\n'
    printf 'option\t2\tThe new encoder\n'
    printf 'recommend\t1\tIt is already on the path.\n'
    printf 'end\tdense\n'
  } > "$state/dense.decisions"

  start=$SECONDS
  section=$(drain_section "$state")
  dense_elapsed=$((SECONDS - start))

  assert_contains "$section" 'MALFORMED DECISION RECORD' \
    "a field too big to read must surface as malformed, not as structure"
  assert_contains "$section" 'oversized-field' \
    "the relay must name the field that was withheld rather than decoded"
  assert_not_contains "$section" '(1) The vendored encoder' \
    "a malformed record's fields must stay withheld"
  # The sound decision raised above must still be rendered: one unreadable
  # record must not cost the whole section.
  assert_contains "$section" '(per-request) Retry per request' \
    "the other open decisions must still render"
  [ "$dense_elapsed" -le $((baseline + 5)) ] \
    || fail "a 40000-escape record field made one drain take ${dense_elapsed}s against a ${baseline}s baseline; the cost of reading a field is not bounded"
  pass "a field built to be expensive is withheld, not paid for"
}

# The bound has to hold wherever a label is READ BACK, not only where the record
# is parsed. Resolving an option id is the lookup an answering surface makes, so
# an unreadable label must come back as a refusal, promptly, rather than as the
# cost of decoding it.
test_option_lookup_refuses_an_unreadable_label() {
  local state status dense rc start elapsed
  state=$(make_state lookupbound)
  status="$state/t.status"
  dense=$(awk 'BEGIN { for (i = 0; i < 40000; i++) printf "\\t" }')
  printf 'needs-decision [key=k]: a short note\n' > "$status"
  {
    printf 'decision\t1\tk\t1787000000\n'
    printf 'question\tWhich encoder should the importer use?\n'
    printf 'option\t1\t%s\n' "$dense"
    printf 'option\t2\tThe new encoder\n'
    printf 'recommend\t2\tIt is already on the path.\n'
    printf 'end\tk\n'
  } > "$state/t.decisions"

  start=$SECONDS
  rc=0
  "$RAISE" option --status "$status" --key k --id 1 >/dev/null 2>&1 || rc=$?
  elapsed=$((SECONDS - start))
  [ "$rc" -ne 0 ] || fail "resolving an option whose label cannot be read must refuse"
  [ "$elapsed" -le 5 ] \
    || fail "resolving an unreadable option label took ${elapsed}s; the lookup pays the decode cost instead of refusing"
  pass "an option id whose label is unreadable is refused, not decoded"
}

# The same bound on the WRITE side. A worker who pastes a blob into --option and
# then recommends it must get the refusal that points at the free-text line
# straight away - the diagnostic only works if it arrives.
test_raise_refuses_a_recommended_blob_promptly() {
  local state status blob err rc start elapsed
  state=$(make_state raisebound)
  status="$state/t.status"
  err="$state/err.txt"
  blob=$(awk 'BEGIN { for (i = 0; i < 20000; i++) printf "\t" }')

  start=$SECONDS
  rc=0
  "$RAISE" raise --status "$status" --key k \
    --question "Which encoder should the importer use?" \
    --option "$blob" --option "The new encoder" \
    --recommend 1 --because "It is already on the path." >/dev/null 2>"$err" || rc=$?
  elapsed=$((SECONDS - start))

  [ "$rc" -ne 0 ] || fail "a raise whose recommended option is a pasted blob must be refused"
  assert_grep 'oversized-field' "$err" "the refusal must name the field that could not be read"
  assert_grep 'raise it as free text' "$err" \
    "the refusal must still point at the free-text line, which is the whole point of refusing"
  assert_absent "$status" "a refused raise must not append a status line"
  [ "$elapsed" -le 5 ] \
    || fail "refusing a recommended blob took ${elapsed}s; the raise decodes it before refusing"
  pass "a recommended blob is refused promptly, with the free-text line named"
}

# The blob does not have to be the recommended one, and it does not have to be
# read back: a worker pastes it into --option and the raise ENCODES it on the
# way in. The refusal is the diagnostic that points at the free-text line, so it
# has to arrive whatever was pasted - and it must still name the ordinary cap,
# not just the structural ceiling.
test_raise_refuses_a_pasted_option_promptly() {
  local state status blob err rc start elapsed
  state=$(make_state encodebound)
  status="$state/t.status"
  err="$state/err.txt"
  blob=$(awk 'BEGIN { for (i = 0; i < 20000; i++) printf "\t" }')

  start=$SECONDS
  rc=0
  "$RAISE" raise --status "$status" --key k \
    --question "Which encoder should the importer use?" \
    --option "$blob" --option "The new encoder" \
    --recommend 2 --because "It is already on the path." >/dev/null 2>"$err" || rc=$?
  elapsed=$((SECONDS - start))

  [ "$rc" -ne 0 ] || fail "a raise carrying a pasted option must be refused"
  assert_grep 'option-too-long' "$err" \
    "the refusal must name the ordinary option cap the worker actually exceeded"
  assert_grep 'raise it as free text' "$err" \
    "the refusal must point at the free-text line"
  assert_absent "$status" "a refused raise must not append a status line"
  assert_absent "${status%.status}.decisions" "a refused raise must not write a record"
  [ "$elapsed" -le 5 ] \
    || fail "refusing a pasted option took ${elapsed}s; the raise encodes it before checking its length"

  # The same blob under an explicit option id takes the other handler.
  start=$SECONDS
  rc=0
  "$RAISE" raise --status "$status" --key k2 \
    --question "Which encoder should the importer use?" \
    --option-id vend "$blob" --option-id new "The new encoder" \
    --recommend new --because "It is already on the path." >/dev/null 2>"$err" || rc=$?
  elapsed=$((SECONDS - start))
  [ "$rc" -ne 0 ] || fail "a raise carrying a pasted --option-id label must be refused"
  [ "$elapsed" -le 5 ] \
    || fail "refusing a pasted --option-id label took ${elapsed}s; that handler encodes before checking"
  pass "a pasted option label is refused promptly by both option handlers"
}

# The property the blank-line case was one instance of: a crewmate's value
# crosses raise, the record and the JSON payload unchanged. The payload is the
# layer a rendering surface reads, so a divergence here shows the captain
# something the crewmate never wrote.
test_awkward_values_round_trip_through_the_json_payload() {
  local state status json label because tab
  state=$(make_state roundtrip)
  status="$state/t.status"
  tab=$(printf '\t')
  label="a label with${tab}a tab, a \"quote\", a \\ backslash and a trailing one \\"
  because=$(printf 'Line one with a \\ backslash.\n\nLine three after a blank line, with a "quote" and a\ttab.')

  "$RAISE" raise --status "$status" --key round \
    --question "Which encoder should the importer use?" \
    --option "$label" --option "An altogether different second option" \
    --recommend 1 --because "$because" >/dev/null \
    || fail "raising with awkward values failed"

  json=$("$RAISE" show --status "$status" --key round --json) \
    || fail "show --json failed for awkward values"

  # Decode the payload and compare against exactly what was handed to the raise.
  FM_EXPECT_LABEL=$label FM_EXPECT_BECAUSE=$because FM_JSON=$json python3 - <<'PY' \
    || fail "the JSON payload did not decode back to the values the raise was given"
import json, os, sys
d = json.loads(os.environ["FM_JSON"])
opts = d["options"]
if len(opts) != 2:
    sys.exit("expected 2 options, got %d" % len(opts))
if opts[0]["label"] != os.environ["FM_EXPECT_LABEL"]:
    sys.exit("label differs:\n got %r\nwant %r" % (opts[0]["label"], os.environ["FM_EXPECT_LABEL"]))
if d["recommend"]["because"] != os.environ["FM_EXPECT_BECAUSE"]:
    sys.exit("because differs:\n got %r\nwant %r" % (d["recommend"]["because"], os.environ["FM_EXPECT_BECAUSE"]))
PY

  # And the values really did travel through the record, one row per option.
  [ "$(grep -c '^option	' "$state/t.decisions")" = 2 ] \
    || fail "the record must hold exactly one row per option whatever the labels contain"
  pass "awkward values cross the raise, the record and the JSON payload unchanged"
}

# THE BOUND IS A PROPERTY OF EVERY ENTRANCE, not of any one helper.
#
# Six review rounds each found one more value-processing helper that ran an
# expensive transform on a worker's value before any length check could reject
# it, and each round bounded the helper it was told about. Enumerating helpers
# is what kept missing one, so this test enumerates ENTRANCES instead: every
# worker-controlled input of every public subcommand, each fed the same hostile
# value, each asserted to come back promptly with the right answer.
#
# That is the difference that closes the class. A new helper cannot escape it,
# because the test never mentions helpers; a new subcommand cannot escape it
# either, because the coverage check below reads the tool's own usage and fails
# when a subcommand has no case here.
#
# Each case is: <name>|<expect>|<pattern>, where <expect> is refuse, accept or
# malformed, and <pattern> is the text the outcome must contain.
FM_BOUND_CEILING=5

# A value built to be expensive: thousands of exactly the characters every
# transform in this path has to substitute, in the shape a worker produces by
# pasting a log or a diff into a field.
hostile_value() {
  awk 'BEGIN { for (i = 0; i < 8000; i++) printf "\t\\\n" }'
}

# A record whose encoded field is far past the ceiling, for the read path.
write_oversized_record() {  # <state> <name> <key>
  local dense
  dense=$(awk 'BEGIN { for (i = 0; i < 40000; i++) printf "\\t" }')
  printf 'needs-decision [key=%s]: a short note\n' "$3" > "$1/$2.status"
  {
    printf 'decision\t1\t%s\t1787000000\n' "$3"
    printf 'question\t%s\n' "$dense"
    printf 'option\t1\tThe vendored encoder\n'
    printf 'option\t2\tThe new encoder\n'
    printf 'recommend\t1\tIt is already on the path.\n'
    printf 'end\t%s\n' "$3"
  } > "$1/$2.decisions"
}

# Run one case, assert its outcome and that it did not spend the cost.
bound_case() {  # <label> <expect> <pattern> <command...>
  local label=$1 expect=$2 pattern=$3 out rc start elapsed
  shift 3
  start=$SECONDS
  rc=0
  out=$("$@" 2>&1) || rc=$?
  elapsed=$((SECONDS - start))

  case "$expect" in
    refuse)
      [ "$rc" -ne 0 ] || fail "$label: a hostile value must be refused, got exit 0"
      ;;
    accept)
      [ "$rc" -eq 0 ] || fail "$label: a valid raise must succeed, got exit $rc"$'\n'"$out"
      ;;
    malformed)
      [ "$rc" -ne 0 ] || fail "$label: an unreadable record must not read as clean structure"
      ;;
  esac
  case "$out" in
    *"$pattern"*) : ;;
    *) fail "$label: expected '$pattern' in the outcome"$'\n'"--- output ---"$'\n'"$out" ;;
  esac
  [ "$elapsed" -le "$FM_BOUND_CEILING" ] \
    || fail "$label: took ${elapsed}s against a ${FM_BOUND_CEILING}s ceiling - this entrance processes a worker's value before its length is checked"
}

test_every_entrance_is_bounded_against_a_hostile_value() {
  local state blob covered sub dense
  state=$(make_state bounded_entrances)
  blob=$(hostile_value)

  # --- the write path: every field a worker fills -------------------------
  bound_case "raise --question" refuse 'question-too-long' \
    "$RAISE" raise --status "$state/q.status" --key q \
    --question "$blob" --option "A one" --option "B two" \
    --recommend 1 --because "It is already on the path."

  bound_case "raise --option" refuse 'option-too-long' \
    "$RAISE" raise --status "$state/o.status" --key o \
    --question "Which encoder should the importer use?" \
    --option "$blob" --option "B two" \
    --recommend 2 --because "It is already on the path."

  bound_case "raise --option-id label" refuse 'option-too-long' \
    "$RAISE" raise --status "$state/oi.status" --key oi \
    --question "Which encoder should the importer use?" \
    --option-id vend "$blob" --option-id new "The new encoder" \
    --recommend new --because "It is already on the path."

  bound_case "raise --consequence" refuse 'consequence-too-long' \
    "$RAISE" raise --status "$state/c.status" --key c \
    --question "Which encoder should the importer use?" \
    --option "A one" --option "B two" \
    --consequence 1 "$blob" --consequence 2 "It needs a vendor bump." \
    --recommend 1 --because "It is already on the path."
  assert_absent "$state/c.status" "a refused raise must not append a status line"

  bound_case "raise --because" refuse 'rationale-too-long' \
    "$RAISE" raise --status "$state/b.status" --key b \
    --question "Which encoder should the importer use?" \
    --option "A one" --option "B two" \
    --recommend 1 --because "$blob"

  bound_case "raise --note" refuse 'the limit is' \
    "$RAISE" raise --status "$state/n.status" --key n \
    --question "Which encoder should the importer use?" \
    --option "A one" --option "B two" \
    --recommend 1 --because "It is already on the path." --note "$blob"
  assert_absent "$state/n.status" "a refused raise must not append a status line"

  # A note that IS within the cap but whitespace-dense still does the real
  # flattening work, and that is the case that has to be timed: a success path
  # has no diagnostic whose lateness would give a delay away. The worker just
  # waits.
  bound_case "raise --note at the cap" accept 'raised needs-decision' \
    "$RAISE" raise --status "$state/nc.status" --key nc \
    --question "Which encoder should the importer use?" \
    --option "A one" --option "B two" \
    --recommend 1 --because "It is already on the path." \
    --note "$(awk 'BEGIN { for (i = 0; i < 133; i++) printf "\t \n" }')"
  assert_grep 'needs-decision [key=nc]:' "$state/nc.status" \
    "a raise with a dense but legal note must still append its ordinary status line"

  # --- the read path: every way a record is read back ---------------------
  write_oversized_record "$state" r read-key

  bound_case "show" malformed 'MALFORMED DECISION RECORD' \
    "$RAISE" show --status "$state/r.status" --key read-key

  bound_case "show --json" malformed '"code":"oversized-field"' \
    "$RAISE" show --status "$state/r.status" --key read-key --json

  bound_case "option --id" refuse 'malformed' \
    "$RAISE" option --status "$state/r.status" --key read-key --id 1

  # The same read path for the consequence accumulator, which a record can fill
  # just as hostilely as the question: it must be WITHHELD rather than decoded,
  # and the record must say so rather than paying for it.
  dense=$(awk 'BEGIN { for (i = 0; i < 40000; i++) printf "\\t" }')
  printf 'needs-decision [key=dense]: a short note\n' > "$state/dc.status"
  {
    printf 'decision\t1\tdense\t1787000000\n'
    printf 'question\tWhich encoder should the importer use?\n'
    printf 'option\t1\tThe vendored encoder\n'
    printf 'option\t2\tThe new encoder\n'
    printf 'consequence\t1\t%s\n' "$dense"
    printf 'recommend\t1\tIt is already on the path.\n'
    printf 'end\tdense\n'
  } > "$state/dc.decisions"
  bound_case "show --json (dense consequence)" malformed '"code":"consequence-too-long"' \
    "$RAISE" show --status "$state/dc.status" --key dense --json

  # --- the relay: the drain that runs at the top of every wake turn --------
  bound_case "wake drain" accept 'MALFORMED DECISION RECORD' \
    env FM_STATE_OVERRIDE="$state" FM_GUARD_GRACE=99999 "$DRAIN"

  # --- coverage: a new subcommand cannot slip past this test ---------------
  # Read the tool's own usage rather than its source, so this survives a
  # refactor and still fails when an entrance is added without a bound case.
  covered=" raise show option "
  for sub in $("$RAISE" --help 2>&1 \
    | sed -n 's|^ *fm-decision-raise\.sh \([a-z][a-z-]*\) .*|\1|p' | sort -u); do
    case "$covered" in
      *" $sub "*) : ;;
      *) fail "subcommand '$sub' has no bound case in this test; every entrance a worker can reach must be exercised with a hostile value" ;;
    esac
  done
  pass "every worker-controlled entrance stays bounded against a hostile value"
}

# --- per-option consequences ------------------------------------------------
#
# The property this half of the contract exists for: a recommendation is only
# honest when the reader could have DISAGREED with it. Three labels that cannot
# be weighed against each other are not a choice - the marked one gets taken
# because it is the only argued one - so each option may carry its own
# consequence, and these tests assert that it survives to the relay attached to
# the right option, that declining it changes nothing, and that a consequence
# which was padded rather than written is named and refused.
#
# Every assertion here is POSITIVE - the exact record accepted, the exact codes
# emitted - because a test that only checks "nothing was rejected" passes on
# empty output.

# Raise the same choice as raise_sound, with a consequence on each option.
raise_with_consequences() {  # <status-file> <key>
  "$RAISE" raise --status "$1" --key "$2" \
    --question "Should the importer retry per request or per session?" \
    --option-id per-request "Retry per request" \
    --option-id per-session "Retry per session" \
    --consequence per-request "Ships today; every call site grows a header." \
    --consequence per-session "Needs a store we do not run yet, so it lands after the freeze." \
    --recommend per-request \
    --because "The gateway already carries a per-request token; a store is new infrastructure."
}

# The whole point of the field, asserted as the exact record that lands and the
# exact lines the relay prints: the consequence is attached to ITS option, on
# both sides of the wire, and the reader can weigh the two against each other.
test_a_consequence_reaches_the_relay_attached_to_its_option() {
  local state status out json section record expected
  state=$(make_state consequences)
  status="$state/importer.status"
  out=$(raise_with_consequences "$status" retry-budget) \
    || fail "raising a decision with consequences failed"
  assert_contains "$out" '2 of them carrying a consequence' \
    "the raise must report how many options it argued"

  # The exact bytes of the accepted record, so the wire format is pinned rather
  # than merely exercised: `consequence` rows carry the OPTION ID they belong
  # to, which is what makes the attachment survive a dropped or reordered row.
  record="${status%.status}.decisions"
  expected="question	Should the importer retry per request or per session?
option	per-request	Retry per request
option	per-session	Retry per session
consequence	per-request	Ships today; every call site grows a header.
consequence	per-session	Needs a store we do not run yet, so it lands after the freeze.
recommend	per-request	The gateway already carries a per-request token; a store is new infrastructure.
end	retry-budget"
  out=$(sed -n '2,$p' "$record")
  [ "$out" = "$expected" ] \
    || fail "the accepted record is not the record this contract writes"$'\n'"--- got ---"$'\n'"$out"$'\n'"--- want ---"$'\n'"$expected"

  json=$("$RAISE" show --status "$status" --key retry-budget --json) \
    || fail "show --json failed for a sound decision carrying consequences"
  assert_contains "$json" '"degenerate":[]' \
    "a decision whose options are argued must carry no defects"
  assert_contains "$json" '"id":"per-request","label":"Retry per request","consequence":"Ships today; every call site grows a header."' \
    "each option must carry its own consequence in the payload a surface reads"
  assert_contains "$json" '"id":"per-session","label":"Retry per session","consequence":"Needs a store we do not run yet, so it lands after the freeze."' \
    "each option must carry its own consequence in the payload a surface reads"
  assert_contains "$json" '"consequences":{"covered":2,"of":2,"partial":false,"note":null}' \
    "full coverage must be reported as the count it is"

  section=$(drain_section "$state")
  assert_contains "$section" '    (per-request) Retry per request
        => Ships today; every call site grows a header.' \
    "the relay must print each consequence under the option it belongs to"
  assert_contains "$section" '    (per-session) Retry per session
        => Needs a store we do not run yet, so it lands after the freeze.' \
    "the relay must print each consequence under the option it belongs to"
  assert_not_contains "$section" 'consequences: ' \
    "a fully argued decision has already said so option by option"
  pass "a consequence reaches the relay attached to the option it belongs to"
}

# ALONGSIDE MEANS ALONGSIDE. Most decisions will not carry the field for a long
# time, and a decision without it is not a defective decision. Asserted as an
# identity rather than as an absence: the record a raise writes without
# consequences is EXACTLY the record it writes with them, minus those rows.
test_declining_consequences_changes_nothing() {
  local state with without out json section
  state=$(make_state declined)
  raise_with_consequences "$state/with.status" k >/dev/null || fail "raising with consequences failed"

  out=$("$RAISE" raise --status "$state/without.status" --key k \
    --question "Should the importer retry per request or per session?" \
    --option-id per-request "Retry per request" \
    --option-id per-session "Retry per session" \
    --recommend per-request \
    --because "The gateway already carries a per-request token; a store is new infrastructure.") \
    || fail "raising without consequences failed"
  [ "$out" = "raised needs-decision [key=k] with 2 options; recommendation: per-request" ] \
    || fail "declining the field must report exactly what it always did, got: $out"

  with=$(grep -v '^consequence	' "$state/with.decisions" | sed -n '2,$p')
  without=$(sed -n '2,$p' "$state/without.decisions")
  [ "$with" = "$without" ] \
    || fail "a record without consequences must be the same record minus those rows"$'\n'"--- with ---"$'\n'"$with"$'\n'"--- without ---"$'\n'"$without"

  json=$("$RAISE" show --status "$state/without.status" --key k --json) \
    || fail "show --json must succeed for a decision that declined consequences"
  assert_contains "$json" '"degenerate":[]' \
    "declining the field is not a defect and must never be flagged as one"
  assert_contains "$json" '"consequences":{"covered":0,"of":2,"partial":false,"note":null}' \
    "no coverage is reported as zero, not as a defect"
  assert_contains "$json" '"consequence":null' \
    "an option carrying no consequence must be null, never an empty string"

  # The relay renders it exactly as it did before the field existed.
  section=$(FM_STATE_OVERRIDE="$state" FM_GUARD_GRACE=99999 "$DRAIN" 2>/dev/null \
    | sed -n '/^without \[key=k\]/,/^OPEN DECISIONS:/p')
  assert_contains "$section" '(per-request) Retry per request' "the options must still render"
  assert_not_contains "$section" '=>' "no consequence line may appear for a decision that has none"
  assert_not_contains "$section" 'consequences:' "no coverage line may appear for a decision that has none"
  assert_not_contains "$section" 'MALFORMED' "declining the field must never make a record malformed"
  pass "a decision raised without consequences is unchanged, byte for byte, and is not a defect"
}

# The honest common case while the field spreads, and the one the surface must
# not hide: some options argued, others not. It is RECORDED and RENDERED - a
# refusal here would force a worker holding one real consequence to invent two,
# which is the padded field this contract exists to keep out - and it SAYS how
# many, so an unargued option is visible as unargued.
test_partial_coverage_is_recorded_rendered_and_counted() {
  local state status out json section
  state=$(make_state partial)
  status="$state/ship.status"
  out=$("$RAISE" raise --status "$status" --key ship \
    --question "Ship the importer now, after the freeze, or behind a flag?" \
    --option "Ship now" --option "Ship after the freeze" --option "Ship behind a flag" \
    --consequence 1 "Two weeks of the old path stays live and we carry both." \
    --recommend 1 --because "The freeze is three weeks out and the old path is the one leaking.") \
    || fail "a partially argued decision must be recorded, not refused"
  assert_contains "$out" '3 options, 1 of them carrying a consequence' \
    "the raise must report the coverage it recorded"
  assert_contains "$out" '1 of 3 options carry a consequence - the rest are unargued' \
    "the raise must say in words what the count means, while the worker can still act on it"
  assert_grep 'needs-decision [key=ship]:' "$status" \
    "a partially argued decision must still append its ordinary status line"

  json=$("$RAISE" show --status "$status" --key ship --json) \
    || fail "show --json must succeed for a partially argued decision"
  assert_contains "$json" '"degenerate":[]' \
    "partial coverage is a count, not a defect: the fields stay trustworthy"
  assert_contains "$json" '"covered":1,"of":3,"partial":true' \
    "the payload must carry the coverage as numbers a surface can render"
  assert_contains "$json" '"note":"1 of 3 options carry a consequence - the rest are unargued, so they cannot be weighed against the ones that are"' \
    "the payload must carry the operator-facing sentence too"

  section=$(drain_section "$state")
  assert_not_contains "$section" 'MALFORMED' \
    "partial coverage must never withhold a sound decision's fields"
  assert_contains "$section" '    (1) Ship now
        => Two weeks of the old path stays live and we carry both.' \
    "the argued option must render with its consequence"
  assert_contains "$section" '    (2) Ship after the freeze
    (3) Ship behind a flag' \
    "the unargued options must still render, with no consequence line invented for them"
  assert_contains "$section" 'consequences: 1 of 3 options - the rest are unargued' \
    "the relay must state the coverage, or it asserts more structure than it has"
  pass "partial coverage is recorded, rendered in full, and reported as 1 of 3"
}

# The trap this field invites: a required-looking field filled by pasting
# something into it. Each case below is a way a consequence can be produced
# without being written, each is mechanically decidable, and each must be named
# by its own code and refused without writing anything.
#
# NOTE WHAT IS NOT HERE. Nothing checks whether a consequence is TRUE, is the
# RIGHT one, or is informative rather than merely distinct. Those are a reader's
# questions, and a check that appeared to answer them would be worse than none:
# a bar a worker must clear is a bar a worker writes to, and three distinct
# useless sentences that cleared it would now look verified.
test_every_faked_consequence_is_refused_by_name() {
  local state case_name expect rest err rc
  state=$(make_state faked)
  # <name>|<expected code>|<consequence for option 1>|<consequence for option 2>
  while IFS='|' read -r case_name expect rest; do
    [ -n "$case_name" ] || continue
    err="$state/$case_name.err"
    rc=0
    # shellcheck disable=SC2086 # the two consequences are deliberately split on the delimiter.
    "$RAISE" raise --status "$state/$case_name.status" --key "$case_name" \
      --question "One endpoint or two?" \
      --option "One endpoint" --option "Two endpoints" \
      --consequence 1 "${rest%%|*}" --consequence 2 "${rest##*|}" \
      --recommend 1 --because "Fewer moving parts than a second service." \
      >/dev/null 2>"$err" || rc=$?
    [ "$rc" -ne 0 ] || fail "$case_name: a consequence that was pasted rather than written must be refused"
    assert_grep "$expect" "$err" "$case_name: the refusal must name '$expect'"
    assert_grep 'raise it as free text' "$err" \
      "$case_name: a refusal must point at the free-text line, never at padding the field"
    assert_absent "$state/$case_name.status" "$case_name: a refused raise must not append a status line"
    assert_absent "$state/$case_name.decisions" "$case_name: a refused raise must not write a record"
  done <<'EOF'
empty|empty-consequence|   |Two services to run instead of one.
same-as-each-other|duplicate-consequences|It is a tradeoff.|It is a tradeoff.
same-as-its-label|consequence-duplicates-option|One endpoint|Two services to run instead of one.
same-as-the-rationale|consequence-duplicates-rationale|Fewer moving parts than a second service.|Two services to run instead of one.
same-as-the-question|consequence-duplicates-question|One endpoint or two?|Two services to run instead of one.
EOF

  # One field holding the whole argument while the other got a token. Both are
  # inside the length cap, so this is the disproportion and nothing else.
  err="$state/blob.err"
  rc=0
  "$RAISE" raise --status "$state/blob.status" --key blob \
    --question "One endpoint or two?" \
    --option "One endpoint" --option "Two endpoints" \
    --consequence 1 "The read path stays on one service, so the cache stays warm, nothing new gets deployed, and the on-call rotation does not grow a second page target this quarter." \
    --consequence 2 "Two." \
    --recommend 1 --because "Fewer moving parts than a second service." \
    >/dev/null 2>"$err" || rc=$?
  [ "$rc" -ne 0 ] || fail "one consequence carrying the whole argument must be refused"
  assert_grep 'consequence-carries-everything' "$err" \
    "the field holding the whole blob must be named as that, not as a length problem"
  assert_no_grep 'consequence-too-long' "$err" \
    "the disproportion case must be the disproportion, not a cap it also happened to break"
  pass "every way a consequence can be pasted rather than written is refused by name"
}

# A consequence attaches BY ID, which is the half of the contract an answering
# surface has to agree with. Attached to nothing, or to an option twice, and the
# attachment this field rests on is broken.
test_a_consequence_must_belong_to_exactly_one_real_option() {
  local state err rc
  state=$(make_state attach)
  err="$state/err.txt"

  rc=0
  "$RAISE" raise --status "$state/unknown.status" --key unknown \
    --question "One endpoint or two?" \
    --option "One endpoint" --option "Two endpoints" \
    --consequence 9 "Two services to run instead of one." \
    --recommend 1 --because "Fewer moving parts than a second service." \
    >/dev/null 2>"$err" || rc=$?
  [ "$rc" -ne 0 ] || fail "a consequence naming no option must be refused, never re-pointed"
  assert_grep 'consequence-unknown-option' "$err" "an unattached consequence must be named"
  assert_absent "$state/unknown.status" "a refused raise must not append a status line"

  rc=0
  "$RAISE" raise --status "$state/twice.status" --key twice \
    --question "One endpoint or two?" \
    --option "One endpoint" --option "Two endpoints" \
    --consequence 1 "It ships today." \
    --consequence 1 "Two services to run instead of one." \
    --recommend 1 --because "Fewer moving parts than a second service." \
    >/dev/null 2>"$err" || rc=$?
  [ "$rc" -ne 0 ] || fail "two consequences under one option id must be refused, never merged"
  assert_grep 'duplicate-consequence-id' "$err" "the ambiguous attachment must be named"
  pass "a consequence belongs to exactly one real option, or the decision is not recorded"
}

# The backstop, matching the one the other fields have: the writer refuses, but
# a record can still reach the file hand-written or from a future writer. A
# faked consequence must look wrong AT THE RELAY, to firstmate, rather than
# reach the captain as two options that look separately argued.
test_a_faked_consequence_on_disk_is_visible_at_the_relay() {
  local state section json rc
  state=$(make_state ondisk_consequence)
  printf 'needs-decision [key=blob]: one endpoint or two?\n' >> "$state/faked.status"
  {
    printf 'decision\t1\tblob\t1787000000\n'
    printf 'question\tOne endpoint or two?\n'
    printf 'option\t1\tOne endpoint\n'
    printf 'option\t2\tTwo endpoints\n'
    printf 'consequence\t1\tIt is a tradeoff either way.\n'
    printf 'consequence\t2\tIt is a tradeoff either way.\n'
    printf 'recommend\t1\tFewer moving parts.\n'
    printf 'end\tblob\n'
  } >> "$state/faked.decisions"

  section=$(drain_section "$state")
  assert_contains "$section" 'MALFORMED DECISION RECORD (duplicate-consequences)' \
    "two options given the same consequence must be marked malformed at the relay"
  assert_contains "$section" 'relay the note above, not these as options' \
    "the relay must say not to present the fields as options"
  assert_not_contains "$section" 'It is a tradeoff either way.' \
    "a malformed record's consequences must never be rendered as if they argued anything"

  rc=0
  json=$("$RAISE" show --status "$state/faked.status" --key blob --json) || rc=$?
  [ "$rc" -ne 0 ] || fail "reading a record with faked consequences must report failure to its caller"
  assert_contains "$json" '"code":"duplicate-consequences"' \
    "the machine payload must carry the defect, not just the human view"
  pass "a faked consequence on disk is malformed at the relay, not relayed as an argued option"
}

# Consequence text is untrusted prose, exactly as a label is. It must not be
# able to mint a row, forge a field, or render a line at the relay that reads
# like a real one - and it must come back out exactly as it went in.
test_consequence_text_cannot_forge_a_row_or_a_line() {
  local state status json section ids
  state=$(make_state inject_consequence)
  status="$state/t.status"
  "$RAISE" raise --status "$status" --key inject \
    --question "Which encoder should the importer use?" \
    --option "The vendored encoder" --option "The new encoder" \
    --consequence 1 "$(printf 'ships today\noption\t3\tA MINTED OPTION')" \
    --consequence 2 "$(printf 'needs a\tvendor bump')" \
    --recommend 1 --because "It is already on the path." >/dev/null \
    || fail "raising with awkward consequence text failed"

  json=$("$RAISE" show --status "$status" --key inject --json) \
    || fail "show --json failed after awkward consequence text"
  assert_contains "$json" '"degenerate":[]' \
    "awkward text is not a defect: it is text, and it must survive as text"
  assert_contains "$json" '"consequence":"ships today\noption\t3\tA MINTED OPTION"' \
    "a consequence must come back out exactly as it went in"
  assert_contains "$json" '"consequence":"needs a\tvendor bump"' \
    "a consequence must come back out exactly as it went in"

  # The option SET is the identity contract: exactly the two ids raised, and
  # not the one the consequence text tried to mint.
  ids=$(option_ids "$status" inject)
  [ "$ids" = "1 2 " ] \
    || fail "consequence text minted an option: expected ids '1 2 ', got '$ids'"

  section=$(drain_section "$state")
  assert_not_contains "$section" '(3) A MINTED OPTION' \
    "consequence prose must never render a line that reads like a real option"
  assert_contains "$section" '        => ships today option 3 A MINTED OPTION
    (2) The new encoder' \
    "the text must render flattened onto its own single line, with the next option after it"
  pass "consequence text can neither mint an option nor forge a line at the relay"
}

# The relay's per-decision field budget, asserted as the all-or-nothing thing it
# is. The drain stops BUILDING a block once it is past the allowance, because
# the option count is a crewmate's number and the loop would otherwise run once
# per row of a record nothing bounds - on the path that runs at the top of every
# wake-handling turn. Stopping early must change the cost and nothing else, so
# this pins the output either side of that line: the decision's own line is
# still printed, not one field line leaks, and the cut is counted and named.
test_an_over_budget_field_block_is_dropped_whole_and_counted() {
  local state status i section
  state=$(make_state overbudget)
  status="$state/wide.status"
  printf 'needs-decision [key=wide]: which encoder should the importer use?\n' >> "$status"
  {
    printf 'decision\t1\twide\t1787000000\n'
    printf 'question\tWhich encoder should the importer use?\n'
    i=1
    while [ "$i" -le 60 ]; do
      printf 'option\t%s\tEncoder number %s, one of a great many candidates on the list\n' "$i" "$i"
      i=$((i + 1))
    done
    i=1
    while [ "$i" -le 60 ]; do
      printf 'consequence\t%s\tPicking encoder %s means carrying its vendor bump for the rest of the year\n' "$i" "$i"
      i=$((i + 1))
    done
    printf 'recommend\t1\tIt is already on the path.\n'
    printf 'end\twide\n'
  } >> "$state/wide.decisions"

  section=$(drain_section "$state")
  assert_contains "$section" 'wide [key=wide] needs-decision: which encoder should the importer use?' \
    "a decision whose fields do not fit must still be listed"
  assert_not_contains "$section" 'Encoder number' \
    "an over-budget block must be dropped whole, never printed in part"
  assert_not_contains "$section" '=>' \
    "an over-budget block must take its consequences with it"
  assert_not_contains "$section" 'recommends' \
    "an over-budget block must take its recommendation with it"
  assert_contains "$section" 'OPEN DECISIONS: fields omitted for 1 (byte cap) - read them with bin/fm-decision-raise.sh show <task> --key <key>' \
    "a bounded view must say what it cut and where to read it"
  pass "a field block over the relay's budget is dropped whole, counted, and never printed in part"
}

# A durable log line is never shortened behind the worker's back. An over-long
# note is refused while the words are still theirs to edit, and the refusal
# carries both numbers so shortening is one edit rather than a guessing game.
test_over_long_note_is_refused_rather_than_truncated() {
  local state status note err rc stored
  state=$(make_state notecap)
  status="$state/t.status"
  err="$state/err.txt"
  note="corr=ab12cd34 $(awk 'BEGIN { for (i = 0; i < 500; i++) printf "x" }')"

  rc=0
  "$RAISE" raise --status "$status" --key k \
    --question "Which encoder should the importer use?" \
    --option "A one" --option "B two" \
    --recommend 1 --because "It is already on the path." \
    --note "$note" >/dev/null 2>"$err" || rc=$?

  [ "$rc" -ne 0 ] || fail "an over-long note must be refused, not silently shortened"
  assert_grep "${#note} characters" "$err" \
    "the refusal must say how long the note actually is"
  assert_grep 'the limit is' "$err" "the refusal must say what the limit is"
  assert_grep 'echo ' "$err" \
    "the refusal must still point at the plain free-text line"
  assert_absent "$status" "a refused raise must not append a status line"
  assert_absent "${status%.status}.decisions" "a refused raise must not write a record"

  # And nothing that DOES land is ever cut: a note one character under the
  # limit is stored whole.
  note=$(awk 'BEGIN { for (i = 0; i < 399; i++) printf "y" }')
  "$RAISE" raise --status "$status" --key k2 \
    --question "Which encoder should the importer use?" \
    --option "A one" --option "B two" \
    --recommend 1 --because "It is already on the path." \
    --note "$note" >/dev/null 2>&1 || fail "a note inside the limit must be accepted"
  stored=$(sed 's/^[^:]*: //' "$status")
  [ "$stored" = "$note" ] \
    || fail "a note inside the limit must be stored whole: wrote ${#note}, log holds ${#stored}"
  pass "an over-long note is refused with both numbers, and a legal note is never cut"
}

# Run EVERY test this file declares, rather than a hand-kept list of names.
#
# A list has to be edited in two places to add a test and in two places to keep
# one, and an edit that touches only the definitions leaves a test that still
# looks present while never running - which is worse than a missing test,
# because the file reads as if the case is covered. This loop removes the
# second place: declaring a test IS running it, so a guard cannot be dropped by
# an edit somewhere else in the file.
#
# It asks the shell which functions exist rather than reading this file's text,
# so it keeps working however the tests are laid out.
fm_run_declared_tests() {
  local fn ran=0
  for fn in $(declare -F | sed -n 's/^declare -f \(test_[a-z_]*\)$/\1/p' | sort); do
    "$fn"
    ran=$((ran + 1))
  done
  [ "$ran" -gt 0 ] || fail "no test functions were declared - this file ran nothing"
}

fm_run_declared_tests
