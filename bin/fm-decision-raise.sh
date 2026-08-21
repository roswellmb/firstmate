#!/usr/bin/env bash
# fm-decision-raise.sh - raise ONE decision as separate fields (the question,
# the options, what each option would cost, the recommendation) instead of a
# single line of prose, and read one back.
#
# The captain's test, which is why this exists: "If he has to READ to find the
# question, it failed. A decision should present the question, the options, and
# the recommendation. Everything else - the reasoning chain, the evidence, the
# worker's account, the alternatives considered - belongs BEHIND it."
# A surface cannot present "the question" from prose without guessing which
# sentence that is, so something has to PRODUCE the fields. This does.
#
# bin/fm-decision-lib.sh owns the record format, the option-identity rule and
# the degeneracy check; bin/fm-classify-lib.sh owns the open/resolved grammar.
# This script owns only the command surface over them.
#
# Usage:
#   fm-decision-raise.sh raise --status <status-file> --key <slug>
#        --question <text>
#        (--option <label> | --option-id <id> <label>)...
#        [--consequence <option-id> <text>]...
#        --recommend <id> --because <text>
#        [--verb needs-decision|blocked] [--note <line>]
#   fm-decision-raise.sh show   --status <status-file> --key <slug> [--json]
#   fm-decision-raise.sh option --status <status-file> --key <slug> --id <id>
#   fm-decision-raise.sh -h | --help
#
# --status is the absolute path a crewmate is already given in its brief; the
# record lands beside it as <status-file-without-.status>.decisions, so a worker
# running in any worktree writes to the right home without being told a second
# path. A task id may be passed instead of --status, resolved against this
# home's state directory.
#
# raise WRITES TWO THINGS, record first so a supervisor woken by the status line
# always finds the fields already there:
#   1. the structured record, appended to state/<task>.decisions
#   2. the ordinary status line, `<verb> [key=<slug>]: <question>`
# The status line's grammar is UNCHANGED, so the fold, the wake digest and every
# existing reader keep working byte-for-byte. The note defaults to the question,
# which means even a reader that knows nothing about this record now sees the
# question in the log instead of a blob.
#
# --consequence SAYS WHAT FOLLOWS IF THAT OPTION IS PICKED, and it is what
# turns a recommendation into something the captain can disagree with. Without
# it a set of labels gives him nothing to weigh, so he takes the marked one and
# the decision is a rubber stamp wearing the costume of a decision. Ids default
# to the option's 1-based ordinal, so `--option A --option B --consequence 1
# "..." --consequence 2 "..."` is the whole of it.
#
# It is OPTIONAL and it is not all-or-nothing. Covering some options and not
# others is recorded, rendered in full, and REPORTED as "n of m carry a
# consequence", because the alternative - refusing the record - would make a
# worker holding one real consequence invent two, which is the padded field this
# whole path exists to keep out. What is refused is a consequence that was
# padded rather than written: empty, the same sentence as another option's, the
# option's own label again, the rationale again, the question again, or one that
# swallowed the argument while its siblings got a token. Nothing scores or
# grades a consequence, here or in the library: whether it is TRUE or USEFUL is
# a question only the reader can answer.
#
# STRUCTURE IS AVAILABLE, NOT COMPULSORY. Most decisions are not multiple choice.
# A worker that writes a plain `needs-decision: ...` line is doing something
# correct, not something deprecated: it folds, wakes, renders and closes exactly
# as before, and `show` reports it as unstructured rather than as broken.
#
# raise REFUSES rather than recording a decision that only looks structured,
# because a field that can be faked is prose with extra steps. Every refusal
# names the defect and points at the free-text line as the honest alternative,
# so the pressure is never "pad the fields until it passes". Nothing is written
# on a refusal - no record and no status line - so a refused raise cannot leave
# a half-open decision behind.
#
# It also refuses when the key is ALREADY OPEN for this task: two option sets
# under one key is precisely the ambiguity that makes an answer a coin flip.
# Resolve the open one, or raise the new question under its own key.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

# shellcheck source=bin/fm-decision-lib.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/fm-decision-lib.sh"
# shellcheck source=bin/fm-classify-lib.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/fm-classify-lib.sh"
# shellcheck source=bin/fm-pr-lib.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-gate-refuse-lib.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/fm-gate-refuse-lib.sh"

# On the bash 3.2 that stock macOS ships, `.` on a file it cannot find ends the
# whole script with status 0 - a silent success that would look exactly like a
# raise that wrote nothing. Assert one function from each sourced library so a
# broken install refuses loudly instead. (The general fix for this class is
# being made upstream; this assertion is correct either way.)
for _fm_required in fm_decision_record_path status_open_decisions \
  fm_task_id_path_safe fm_refuse_if_gate_agent; do
  command -v "$_fm_required" >/dev/null 2>&1 || {
    printf 'fm-decision-raise: required library function %s is missing; refusing to run\n' \
      "$_fm_required" >&2
    exit 1
  }
done
unset _fm_required

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0"
}

fail() {
  printf 'fm-decision-raise: %s\n' "$*" >&2
  exit 1
}

STATUS_FILE=
KEY=
resolve_status() {  # <task-id-or-empty>
  local id=$1
  if [ -n "$STATUS_FILE" ]; then
    [ -z "$id" ] || fail "pass either a task id or --status, not both"
    return 0
  fi
  [ -n "$id" ] || fail "need --status <status-file> or a task id"
  fm_task_id_path_safe "$id" || fail "invalid task id '$id'"
  STATUS_FILE="$STATE/$id.status"
}

# JSON string escaping, so the structured payload can leave this home without a
# jq dependency on the core decision path (jq is required only for Relay).
#
# Done with the same parameter expansions fm_decision_encode uses rather than
# through awk: awk stores RS as a C string, so the "read the whole input as one
# record" idiom RS="\0" is an EMPTY RS - paragraph mode - on the BSD awk stock
# macOS ships, which silently drops blank lines, their newlines and a trailing
# newline. A field that survived the record and is flattened on its way into the
# payload is worth nothing, so the escaping stays in the shell where the value
# is never re-split. Control characters below 0x20 that have no short escape are
# emitted as \u00XX, because a raw one makes the payload invalid per RFC 8259.
# The codes and the characters they name, in the same order, so the loop below
# never has to build a character from a variable.
FM_JSON_CTL_CODES='01 02 03 04 05 06 07 0b 0e 0f 10 11 12 13 14 15 16 17 18 19 1a 1b 1c 1d 1e 1f'
FM_JSON_CTL_CHARS=$'\x01\x02\x03\x04\x05\x06\x07\x0b\x0e\x0f\x10\x11\x12\x13\x14\x15\x16\x17\x18\x19\x1a\x1b\x1c\x1d\x1e\x1f'
json_str() {  # <value> -> quoted JSON string on stdout
  local s=$1 ctl c i=0
  s=${s//\\/\\\\}
  s=${s//\"/\\\"}
  s=${s//$'\b'/\\b}
  s=${s//$'\f'/\\f}
  s=${s//$'\n'/\\n}
  s=${s//$'\r'/\\r}
  s=${s//$'\t'/\\t}
  for ctl in $FM_JSON_CTL_CODES; do
    c=${FM_JSON_CTL_CHARS:$i:1}
    i=$((i + 1))
    case "$s" in *"$c"*) s=${s//"$c"/\\u00$ctl} ;; esac
  done
  printf '"%s"' "$s"
}

# Emit the parsed record as JSON for a rendering surface. `degenerate` is a
# LIST, never a boolean: a surface that knows nothing else still learns that
# this record must not be presented as clean structure, and which checks failed.
emit_json() {  # <key> <structured:0|1> <note>
  local key=$1 structured=$2 note=$3 id label first=1 code consequence
  printf '{'
  printf '"key":%s' "$(json_str "$key")"
  printf ',"structured":%s' "$([ "$structured" = 1 ] && echo true || echo false)"
  printf ',"note":%s' "$(json_str "$note")"
  if [ "$structured" = 1 ]; then
    printf ',"question":%s' "$(json_str "$FM_DECISION_QUESTION")"
    printf ',"options":['
    while IFS=$'\t' read -r id label; do
      [ -n "$id$label" ] || continue
      [ "$first" = 1 ] || printf ','
      first=0
      fm_decision_decode_var "$label"
      printf '{"id":%s,"label":%s' "$(json_str "$id")" "$(json_str "$FM_DECISION_VALUE")"
      # null, never "", for an option carrying no consequence. Absence is
      # load-bearing on this field - an unargued option and an option argued
      # with an empty sentence are different things, and a surface that cannot
      # tell them apart will render the second as if it were the first.
      if consequence=$(fm_decision_option_consequence "$id"); then
        printf ',"consequence":%s' "$(json_str "$consequence")"
      else
        printf ',"consequence":null'
      fi
      printf '}'
    done <<EOF
$FM_DECISION_OPTIONS
EOF
    printf ']'
    printf ',"consequences":{"covered":%d,"of":%d,"partial":%s,"note":%s}' \
      "$FM_DECISION_CONSEQUENCE_COVERED" "$FM_DECISION_OPTION_COUNT" \
      "$([ -n "$FM_DECISION_COVERAGE_CODE" ] && echo true || echo false)" \
      "$([ -n "$FM_DECISION_COVERAGE_CODE" ] \
        && json_str "$(fm_decision_defect_help "$FM_DECISION_COVERAGE_CODE")" \
        || printf 'null')"
    printf ',"recommend":{"option":%s,"because":%s}' \
      "$(json_str "$FM_DECISION_RECOMMEND_ID")" "$(json_str "$FM_DECISION_RECOMMEND_WHY")"
  fi
  printf ',"degenerate":['
  first=1
  for code in $FM_DECISION_DEFECTS; do
    [ "$first" = 1 ] || printf ','
    first=0
    printf '{"code":%s,"detail":%s}' \
      "$(json_str "$code")" "$(json_str "$(fm_decision_defect_help "$code")")"
  done
  printf ']}\n'
}

# The note the status line carries. Whitespace is collapsed because a status log
# line is one line; the record keeps the question exactly as written. The same
# flattening the relay applies to every field it renders, from one owner.
collapse() {  # <text>
  fm_decision_flatten_var "$1"
  printf '%s' "$FM_DECISION_FLAT"
}

cmd_raise() {
  local question='' recommend='' because='' verb='needs-decision' note=''
  local opts='' pos=0 id label task='' defects code record block now
  local cons='' text
  while [ $# -gt 0 ]; do
    case "$1" in
      --status) [ $# -ge 2 ] || fail "--status requires a path"; STATUS_FILE=$2; shift 2 ;;
      --key) [ $# -ge 2 ] || fail "--key requires a slug"; KEY=$2; shift 2 ;;
      --question) [ $# -ge 2 ] || fail "--question requires text"; question=$2; shift 2 ;;
      --option)
        [ $# -ge 2 ] || fail "--option requires a label"
        pos=$((pos + 1))
        opts="$opts$pos	$(fm_decision_encode "$2")
"
        shift 2 ;;
      --option-id)
        [ $# -ge 3 ] || fail "--option-id requires an id and a label"
        pos=$((pos + 1))
        fm_decision_option_id_valid "$2" || fail "option id '$2' is not a slug (allowed: A-Z a-z 0-9 . _ -)"
        opts="$opts$2	$(fm_decision_encode "$3")
"
        shift 3 ;;
      --consequence)
        [ $# -ge 3 ] || fail "--consequence requires an option id and text"
        fm_decision_option_id_valid "$2" || fail "option id '$2' is not a slug (allowed: A-Z a-z 0-9 . _ -)"
        cons="$cons$2	$(fm_decision_encode "$3")
"
        shift 3 ;;
      --recommend) [ $# -ge 2 ] || fail "--recommend requires an option id"; recommend=$2; shift 2 ;;
      --because) [ $# -ge 2 ] || fail "--because requires text"; because=$2; shift 2 ;;
      --note) [ $# -ge 2 ] || fail "--note requires a line"; note=$2; shift 2 ;;
      --verb)
        [ $# -ge 2 ] || fail "--verb requires a verb"
        case "$2" in
          needs-decision|blocked) verb=$2 ;;
          *) fail "--verb must be needs-decision or blocked (got '$2'); only those two open a decision" ;;
        esac
        shift 2 ;;
      -*) fail "unknown flag '$1'" ;;
      *) [ -z "$task" ] || fail "unexpected argument '$1'"; task=$1; shift ;;
    esac
  done
  resolve_status "$task"
  [ -n "$KEY" ] || fail "--key is required: a structured decision must be answerable by key"
  fm_decision_option_id_valid "$KEY" || fail "invalid decision key '$KEY' (allowed: A-Z a-z 0-9 . _ -)"

  # Checked on the RAW argument, before anything transforms it and before
  # anything is written, so the refusal costs a length test however much prose
  # was pasted - and so the words are still in front of the worker who can
  # shorten them, rather than shortened for them somewhere they cannot see.
  if [ "${#note}" -gt "$FM_DECISION_MAX_NOTE" ]; then
    {
      printf 'fm-decision-raise: refusing to write a status note that would not fit the line.\n'
      printf 'Nothing was written - no record and no status line.\n\n'
      printf '  --note is %s characters; the limit is %s.\n\n' \
        "${#note}" "$FM_DECISION_MAX_NOTE"
      printf 'The note is one line of a durable log, so it is refused rather than\n'
      printf 'shortened: your words are still yours to edit. Shorten it, or put the\n'
      printf 'detail in the report and leave the note pointing at it.\n\n'
      printf 'If this is not a set of options at all, the plain free-text line is\n'
      printf 'still the honest alternative, and it folds, wakes and closes as before:\n'
      printf "  echo '%s [key=%s]: <the question>' >> %s\n" \
        "$verb" "${KEY:-<slug>}" "$STATUS_FILE"
    } >&2
    exit 2
  fi

  # Populate the shared globals so the ONE degeneracy check runs over exactly
  # what would be recorded - including the labels in their ENCODED form, which
  # is the form the record holds and the only form that cannot forge a row.
  # fm_decision_defects decodes each label itself to measure and compare it.
  fm_decision_reset
  FM_DECISION_QUESTION=$question
  FM_DECISION_OPTIONS=${opts%$'\n'}
  FM_DECISION_OPTION_COUNT=$pos
  FM_DECISION_CONSEQUENCES=${cons%$'\n'}
  FM_DECISION_RECOMMEND_ID=$recommend
  FM_DECISION_RECOMMEND_WHY=$because

  # Called in-process rather than through the printing wrapper: the check also
  # publishes the coverage counters this command reports below, and a command
  # substitution would lose them with the subshell.
  fm_decision_defects_var
  defects=$FM_DECISION_DEFECT_CODES
  if [ -n "$defects" ]; then
    {
      printf 'fm-decision-raise: refusing to record a decision that is not actually structured.\n'
      printf 'Nothing was written - no record and no status line.\n\n'
      for code in $defects; do
        printf '  %-24s %s\n' "$code" "$(fm_decision_defect_help "$code")"
      done
      printf '\nIf this decision genuinely is not a set of options, that is normal and\n'
      printf 'supported - raise it as free text instead, and it will fold, wake and\n'
      printf 'close exactly as before:\n'
      printf "  echo '%s [key=%s]: <the question>' >> %s\n" \
        "$verb" "${KEY:-<slug>}" "$STATUS_FILE"
    } >&2
    exit 2
  fi

  # Two option sets under one key is the ambiguity that makes an answer a coin
  # flip, so refuse while the key is open. The fold in fm-classify-lib.sh is the
  # only thing consulted for "open"; this script never re-derives it.
  # Every refusal below runs BEFORE the status file is created, so a refused
  # raise leaves the task exactly as it found it.
  if [ -f "$STATUS_FILE" ] \
    && status_open_decisions "$STATUS_FILE" | cut -f1 | grep -qxF -- "$KEY"; then
    fail "decision key '$KEY' is already open for this task; answer it first, or raise this question under its own key"
  fi

  # Would this exact line actually OPEN this key? Asked of the fold itself
  # rather than re-derived here, so a key in a library-owned namespace - whose
  # transitions only its owner's vocabulary may make - cannot produce a record
  # plus a status line that opens nothing. Checked BEFORE anything is written.
  local probe
  probe=$(mktemp "${TMPDIR:-/tmp}/fm-decision-probe.XXXXXX") || fail "cannot create a temporary file"
  [ -n "$note" ] || note=$question
  note=$(collapse "$note")
  printf '%s [key=%s]: %s\n' "$verb" "$KEY" "$note" > "$probe"
  if ! status_open_decisions "$probe" | cut -f1 | grep -qxF -- "$KEY"; then
    rm -f "$probe"
    fail "a '$verb [key=$KEY]' line would not open a decision in the fold (bin/fm-classify-lib.sh); '$KEY' is most likely in a namespace owned by another library. Nothing was written - choose a key of your own."
  fi
  rm -f "$probe"

  # The reader rejects a symlinked record file outright, exactly as the sibling
  # fold rejects a symlinked status log; refuse to APPEND through one too, so a
  # record path pointing out of the state directory is never written and never
  # read. Checked before anything is created, so this refusal writes nothing.
  record=$(fm_decision_record_path "$STATUS_FILE")
  [ ! -L "$record" ] \
    || fail "record path '$record' is a symlink; refusing to write a decision record through it"

  [ -f "$STATUS_FILE" ] || : > "$STATUS_FILE" 2>/dev/null \
    || fail "cannot write status file '$STATUS_FILE'"
  now=$(date +%s)
  block="decision	$FM_DECISION_FORMAT_VERSION	$KEY	$now
question	$(fm_decision_encode "$question")
"
  while IFS=$'\t' read -r id label; do
    [ -n "$id$label" ] || continue
    block="${block}option	$id	$label
"
  done <<EOF
$FM_DECISION_OPTIONS
EOF
  # Consequences follow the options as their own rows rather than being folded
  # into them, which is what keeps the addition invisible to a reader that
  # predates it: those rows are a kind it does not recognise, so it skips them
  # and renders exactly the record it always did.
  while IFS=$'\t' read -r id text; do
    [ -n "$id$text" ] || continue
    block="${block}consequence	$id	$text
"
  done <<EOF
$FM_DECISION_CONSEQUENCES
EOF
  block="${block}recommend	$recommend	$(fm_decision_encode "$because")
end	$KEY
"
  printf '%s' "$block" >> "$record" || fail "cannot append to record file '$record'"

  printf '%s [key=%s]: %s\n' "$verb" "$KEY" "$note" >> "$STATUS_FILE" \
    || fail "record written to '$record' but the status line could not be appended to '$STATUS_FILE'"
  # A decision that declined consequences reports exactly what it always did:
  # declining the field is not a lesser raise and must not read as one.
  if [ "$FM_DECISION_CONSEQUENCE_COVERED" -eq 0 ]; then
    printf 'raised %s [key=%s] with %d options; recommendation: %s\n' \
      "$verb" "$KEY" "$FM_DECISION_OPTION_COUNT" "$recommend"
    return 0
  fi
  printf 'raised %s [key=%s] with %d options, %d of them carrying a consequence; recommendation: %s\n' \
    "$verb" "$KEY" "$FM_DECISION_OPTION_COUNT" "$FM_DECISION_CONSEQUENCE_COVERED" "$recommend"
  # Partial coverage said in words as well as in numbers, at the moment the
  # worker could still add the missing ones.
  [ -z "$FM_DECISION_COVERAGE_CODE" ] \
    || printf '  %s\n' "$(fm_decision_defect_help "$FM_DECISION_COVERAGE_CODE")"
}

# The still-open note for a key, empty when the key is not open. Read through
# the fold rather than by scanning the log, so "open" has one owner.
open_note() {  # <status-file> <key>
  local f=$1 want=$2 k v n
  [ -f "$f" ] || return 0
  while IFS=$'\t' read -r k v n; do
    [ "$k" = "$want" ] || continue
    printf '%s' "$n"
    return 0
  done <<EOF
$(status_open_decisions "$f")
EOF
}

cmd_show() {
  local as_json=0 task='' note structured=0 id label code consequence rc=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --status) [ $# -ge 2 ] || fail "--status requires a path"; STATUS_FILE=$2; shift 2 ;;
      --key) [ $# -ge 2 ] || fail "--key requires a slug"; KEY=$2; shift 2 ;;
      --json) as_json=1; shift ;;
      -*) fail "unknown flag '$1'" ;;
      *) [ -z "$task" ] || fail "unexpected argument '$1'"; task=$1; shift ;;
    esac
  done
  resolve_status "$task"
  [ -n "$KEY" ] || fail "--key is required"
  note=$(open_note "$STATUS_FILE" "$KEY")
  if fm_decision_record_read "$(fm_decision_record_path "$STATUS_FILE")" "$KEY"; then
    structured=1
  fi
  [ -z "$FM_DECISION_DEFECTS" ] || rc=1

  if [ "$as_json" = 1 ]; then
    emit_json "$KEY" "$structured" "$note"
    return "$rc"
  fi

  if [ "$structured" = 0 ]; then
    # An ordinary free-text decision. Not a failure and not a defect: it is the
    # majority case and it is supported.
    if [ -n "$FM_DECISION_DEFECTS" ]; then
      printf 'MALFORMED DECISION RECORD [key=%s]\n' "$KEY"
      for code in $FM_DECISION_DEFECTS; do
        printf '  %-24s %s\n' "$code" "$(fm_decision_defect_help "$code")"
      done
      printf '  treat as unstructured; the note below is all that is trustworthy\n'
    else
      printf 'unstructured decision [key=%s] (no structured record - this is normal)\n' "$KEY"
    fi
    printf 'note: %s\n' "$note"
    return "$rc"
  fi

  if [ -n "$FM_DECISION_DEFECTS" ]; then
    printf 'MALFORMED DECISION RECORD [key=%s] - do not present these fields as structure\n' "$KEY"
    for code in $FM_DECISION_DEFECTS; do
      printf '  %-24s %s\n' "$code" "$(fm_decision_defect_help "$code")"
    done
  fi
  printf 'question: %s\n' "$FM_DECISION_QUESTION"
  while IFS=$'\t' read -r id label; do
    [ -n "$id$label" ] || continue
    fm_decision_decode_var "$label"
    printf 'option %s: %s\n' "$id" "$FM_DECISION_VALUE"
    # Directly under the option it belongs to, because an option and its
    # consequence read as one thing and a separate list would make the reader
    # do the joining that the id already did.
    if consequence=$(fm_decision_option_consequence "$id"); then
      printf '  => %s\n' "$consequence"
    fi
  done <<EOF
$FM_DECISION_OPTIONS
EOF
  # Silent when the decision declined the field, which is the ordinary case and
  # not a lesser one; stated whenever any option carries a consequence, so a
  # reader is never left to assume the ones without were argued somewhere else.
  if [ "$FM_DECISION_CONSEQUENCE_COVERED" -gt 0 ]; then
    printf 'consequences: %d of %d options\n' \
      "$FM_DECISION_CONSEQUENCE_COVERED" "$FM_DECISION_OPTION_COUNT"
    [ -z "$FM_DECISION_COVERAGE_CODE" ] \
      || printf '  %-24s %s\n' "$FM_DECISION_COVERAGE_CODE" \
        "$(fm_decision_defect_help "$FM_DECISION_COVERAGE_CODE")"
  fi
  printf 'recommend: %s\n' "$FM_DECISION_RECOMMEND_ID"
  printf 'because: %s\n' "$FM_DECISION_RECOMMEND_WHY"
  return "$rc"
}

# Resolve one option id against a decision. Exit 0 and print the label when the
# id names a real option of that decision, exit 1 when it does not. This is the
# check that lets an answering surface prove which option was chosen instead of
# asserting it.
cmd_option() {
  local task='' want=''
  while [ $# -gt 0 ]; do
    case "$1" in
      --status) [ $# -ge 2 ] || fail "--status requires a path"; STATUS_FILE=$2; shift 2 ;;
      --key) [ $# -ge 2 ] || fail "--key requires a slug"; KEY=$2; shift 2 ;;
      --id) [ $# -ge 2 ] || fail "--id requires an option id"; want=$2; shift 2 ;;
      -*) fail "unknown flag '$1'" ;;
      *) [ -z "$task" ] || fail "unexpected argument '$1'"; task=$1; shift ;;
    esac
  done
  resolve_status "$task"
  [ -n "$KEY" ] || fail "--key is required"
  [ -n "$want" ] || fail "--id is required"
  if ! fm_decision_record_read "$(fm_decision_record_path "$STATUS_FILE")" "$KEY"; then
    printf 'fm-decision-raise: no structured decision [key=%s] for this task\n' "$KEY" >&2
    return 1
  fi
  if [ -n "$FM_DECISION_DEFECTS" ]; then
    printf 'fm-decision-raise: decision [key=%s] is malformed (%s); its options are not trustworthy\n' \
      "$KEY" "$FM_DECISION_DEFECTS" >&2
    return 1
  fi
  fm_decision_option_label "$want" || {
    printf 'fm-decision-raise: option id %s is not an option of [key=%s]\n' "$want" "$KEY" >&2
    return 1
  }
  printf '\n'
}

case "${1:-}" in
  -h|--help|'') usage; exit 0 ;;
esac
SUB=$1
shift
case "$SUB" in
  raise)
    # Fail closed before any durable mutation: a no-mistakes gate agent must
    # never write into a task's decision ledger (bin/fm-gate-refuse-lib.sh).
    fm_refuse_if_gate_agent
    cmd_raise "$@" ;;
  show) cmd_show "$@" ;;
  option) cmd_option "$@" ;;
  *) fail "unknown subcommand '$SUB' (expected raise, show or option)" ;;
esac
