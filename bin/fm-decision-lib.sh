# shellcheck shell=bash
# Shared structured-decision RECORD contract: the question, the options and the
# recommendation a worker raises, kept as separate fields all the way to
# whatever surface the captain answers on.
#
# WHY THIS EXISTS. A `needs-decision:` status line carries ONE line of prose, so
# a decision arrives as a blob and any surface wanting to show "the question"
# would have to guess which sentence that is - inventing structure it cannot
# verify. This file is the producer of those fields, so no reader has to guess.
#
# WHAT IT DOES NOT OWN. bin/fm-classify-lib.sh owns the open/resolved grammar -
# which lines OPEN a keyed decision and which CLOSE it - and this library never
# restates or re-derives it. The status line is unchanged and remains the wake
# event and the sole thing the fold reads; this record is a SIDECAR joined to it
# by (task id, decision key). A decision with no record folds and renders exactly
# as it always has, which is what keeps ordinary free-text decisions working.
#
# THE RECORD FILE is append-only, one per task, beside its status log:
#   state/<task-id>.decisions
# It is written by bin/fm-decision-raise.sh and read by every consumer through
# this library. Being a separate file rather than a longer status line is what
# survives the relay: the fold, the wake digest and the deck all keep reading the
# status stream byte-for-byte as before.
#
# WIRE FORMAT - one record is a block of TAB-separated lines:
#   decision<TAB><format-version><TAB><key><TAB><epoch>
#   question<TAB><encoded>
#   option<TAB><option-id><TAB><encoded label>      (repeated)
#   recommend<TAB><option-id><TAB><encoded rationale>
#   end<TAB><key>
# Field values are backslash-encoded (see fm_decision_encode) so a value can
# never contain a raw TAB or newline and therefore can never forge a field or a
# block boundary. A block missing its `end` line is TRUNCATED and is never used
# in part; the last COMPLETE block for a key wins, so re-raising a key after it
# was resolved supersedes cleanly without rewriting history.
#
# OPTION IDENTITY - the half of this contract another surface must agree with.
# An option is identified by the triple (task id, decision key, option id).
# The option id is a slug over [A-Za-z0-9._-], assigned when the decision is
# raised and immutable for the life of that record. It is an IDENTIFIER, never a
# label: it is safe in a URL, a payload or an answer, and a surface must not
# render it as the name of a control. The option's prose LABEL is separate,
# is always rendered as text, and can be rewritten without changing identity.
# That separation is what lets a surface offer options without a worker's
# untrusted prose ever naming a button. Ids default to the option's 1-based
# ordinal ("1", "2", ...) so the common case needs no ceremony.
#
# DEGENERACY - fields that can be faked are prose with extra steps.
# A required field with nothing checking it becomes a field holding the whole
# blob pasted three times, so fm_decision_defects is the ONE place that decides
# whether a record is real, and BOTH sides call it: the writer refuses to record
# a degenerate decision at all (and points at the free-text path instead of
# pushing the worker to pad the fields), and every reader re-checks on the way
# out so a record that reached the file some other way is shown as MALFORMED at
# the relay rather than reaching the captain looking structured.
#
# Bash 3.2 compatible: no associative arrays, no ${var,,}.

# Current record format version. Bump only on an incompatible field change; a
# reader ignores a block whose version it does not know rather than guessing.
FM_DECISION_FORMAT_VERSION=1

# Bounds. A question is one statement and an option is a short label; prose past
# these lengths is reasoning that belongs behind the decision, not in front of
# it. They are deliberately generous - they separate "a sentence" from "a
# pasted paragraph", not "short" from "long".
FM_DECISION_MAX_QUESTION=240
FM_DECISION_MAX_OPTION=200
FM_DECISION_MAX_RATIONALE=400
# Refuse to parse an implausibly large record file rather than reading forever.
FM_DECISION_MAX_FILE_BYTES=262144

# --- value encoding ---------------------------------------------------------
# Encode one field value so it cannot contain a raw TAB or newline. Backslash is
# escaped FIRST so decoding is unambiguous.
fm_decision_encode() {  # <value> -> encoded on stdout
  local s=$1
  s=${s//\\/\\\\}
  s=${s//$'\t'/\\t}
  s=${s//$'\n'/\\n}
  s=${s//$'\r'/\\r}
  printf '%s' "$s"
}

# Decode one encoded field value. Walks left to right so an escaped backslash is
# never re-interpreted as introducing an escape.
fm_decision_decode() {  # <encoded> -> value on stdout
  local s=$1 out='' c rest bs=$'\\'
  while [ -n "$s" ]; do
    c=${s%"${s#?}"}
    rest=${s#?}
    if [ "$c" = "$bs" ] && [ -n "$rest" ]; then
      c=${rest%"${rest#?}"}
      rest=${rest#?}
      case "$c" in
        t) out="$out"$'\t' ;;
        n) out="$out"$'\n' ;;
        r) out="$out"$'\r' ;;
        "$bs") out="$out$bs" ;;
        *) out="$out\\$c" ;;
      esac
    else
      out="$out$c"
    fi
    s=$rest
  done
  printf '%s' "$out"
}

# --- identifiers ------------------------------------------------------------
# An option id uses the SAME charset as a decision key (fm-classify-lib.sh's
# _fm_decision_key), so one identifier rule covers the whole path and an answer
# carrying "<key>/<option-id>" needs no second escaping story.
fm_decision_option_id_valid() {  # <id>
  case "$1" in
    ''|*[!A-Za-z0-9._-]*) return 1 ;;
    *) return 0 ;;
  esac
}

# --- normalisation used by the duplicate-field checks -----------------------
# Lowercase, collapse whitespace, drop trailing sentence punctuation. Two fields
# that normalise equal are the same text pasted twice, whatever their casing or
# trailing period.
fm_decision_normalise() {  # <text> -> normalised on stdout
  printf '%s' "$1" \
    | tr '[:upper:]' '[:lower:]' \
    | tr -s '[:space:]' ' ' \
    | sed -e 's/^ //' -e 's/ $//' -e 's/[.?!]*$//'
}

# --- parsed-record globals --------------------------------------------------
# Set by fm_decision_record_read and read by that function's CALLERS
# (bin/fm-decision-raise.sh, bin/fm-wake-drain.sh), not within this file.
# shellcheck disable=SC2034

fm_decision_reset() {
  FM_DECISION_FOUND=0
  FM_DECISION_KEY=
  FM_DECISION_RAISED=
  FM_DECISION_QUESTION=
  FM_DECISION_OPTIONS=
  FM_DECISION_OPTION_COUNT=0
  FM_DECISION_RECOMMEND_ID=
  FM_DECISION_RECOMMEND_WHY=
  FM_DECISION_DEFECTS=
}
fm_decision_reset

# Record path for a task's status file. Derived from the status path the worker
# already has in its brief, so the record always lands beside the log it belongs
# to and never in whichever home the worker happens to be running from.
fm_decision_record_path() {  # <status-file> -> record path on stdout
  printf '%s' "${1%.status}.decisions"
}

# Look up one option's label. Prints the label and returns 0 when <id> is an
# option of the record currently parsed; returns 1 when it is not. This is the
# check that turns an answer into an answer instead of a coin flip.
fm_decision_option_label() {  # <id> -> label on stdout
  local want=$1 id label
  while IFS=$'\t' read -r id label; do
    [ -n "$id" ] || continue
    if [ "$id" = "$want" ]; then
      printf '%s' "$label"
      return 0
    fi
  done <<EOF
$FM_DECISION_OPTIONS
EOF
  return 1
}

# --- reading ----------------------------------------------------------------
# Parse the LAST COMPLETE record for <key> out of a task's record file into the
# globals above, then re-run the defect check so no caller can render a record
# without also seeing what is wrong with it.
#
# Returns 0 when a complete record was found (FM_DECISION_FOUND=1), 1 when there
# is none. "None" is the ordinary free-text decision and is NOT an error: the
# caller renders the status note exactly as it did before this contract existed.
#
# A truncated block - one interrupted by the next `decision` line or by end of
# file before its `end` - is discarded whole and reported through the
# truncated-record defect only when nothing complete for that key exists, so a
# torn append can never be shown as if it were the decision.
# shellcheck disable=SC2034 # FM_DECISION_* are this library's published outputs, read by its callers.
fm_decision_record_read() {  # <record-file> <key>
  local file=$1 want=$2
  local line kind a b c
  local in_block=0 blk_key='' blk_ver='' blk_raised=''
  local blk_q='' blk_opts='' blk_rid='' blk_why='' blk_count=0 blk_seen_q=0
  local saw_truncated=0 bytes

  fm_decision_reset
  [ -n "$file" ] && [ -f "$file" ] || return 1

  bytes=$(wc -c < "$file" 2>/dev/null || echo 0)
  bytes=${bytes//[[:space:]]/}
  if [ -n "$bytes" ] && [ "$bytes" -gt "$FM_DECISION_MAX_FILE_BYTES" ] 2>/dev/null; then
    FM_DECISION_DEFECTS='oversized-record-file'
    return 1
  fi

  while IFS= read -r line || [ -n "$line" ]; do
    [ -n "$line" ] || continue
    IFS=$'\t' read -r kind a b c <<EOF
$line
EOF
    case "$kind" in
      decision)
        # A new block starts here; anything still open was never terminated.
        [ "$in_block" -eq 0 ] || saw_truncated=1
        in_block=0
        blk_key=$b; blk_ver=$a; blk_raised=$c
        blk_q=''; blk_opts=''; blk_rid=''; blk_why=''; blk_count=0; blk_seen_q=0
        # Ignore a block written by a format version this reader does not know
        # rather than guessing at its fields.
        if [ "$blk_ver" = "$FM_DECISION_FORMAT_VERSION" ] && [ "$blk_key" = "$want" ]; then
          in_block=1
        fi
        ;;
      question)
        [ "$in_block" -eq 1 ] || continue
        blk_q=$(fm_decision_decode "$a")
        blk_seen_q=1
        ;;
      option)
        [ "$in_block" -eq 1 ] || continue
        blk_opts="$blk_opts$a	$(fm_decision_decode "$b")
"
        blk_count=$((blk_count + 1))
        ;;
      recommend)
        [ "$in_block" -eq 1 ] || continue
        blk_rid=$a
        blk_why=$(fm_decision_decode "$b")
        ;;
      end)
        [ "$in_block" -eq 1 ] || continue
        if [ "$a" = "$blk_key" ]; then
          # Complete block for the wanted key: it supersedes any earlier one.
          FM_DECISION_FOUND=1
          FM_DECISION_KEY=$blk_key
          FM_DECISION_RAISED=$blk_raised
          FM_DECISION_QUESTION=$blk_q
          FM_DECISION_OPTIONS=${blk_opts%$'\n'}
          FM_DECISION_OPTION_COUNT=$blk_count
          FM_DECISION_RECOMMEND_ID=$blk_rid
          FM_DECISION_RECOMMEND_WHY=$blk_why
          [ "$blk_seen_q" -eq 1 ] || FM_DECISION_QUESTION=''
        else
          saw_truncated=1
        fi
        in_block=0
        ;;
    esac
  done < "$file"
  [ "$in_block" -eq 0 ] || saw_truncated=1

  if [ "$FM_DECISION_FOUND" -eq 0 ]; then
    [ "$saw_truncated" -eq 0 ] || FM_DECISION_DEFECTS='truncated-record'
    return 1
  fi

  FM_DECISION_DEFECTS=$(fm_decision_defects)
  return 0
}

# --- degeneracy -------------------------------------------------------------
# THE ONE PLACE that decides whether a structured decision is real, called by
# the writer to refuse and by every reader to flag. Prints a space-separated
# list of defect codes, empty when the record is sound.
#
# Every check answers the captain's test - "if he has to READ to find the
# question, it failed" - by catching the two ways a field stops being a field:
# it is missing, or it holds text that was pasted rather than written for it.
# The duplicate checks are what make the fields unfakeable by padding: pasting
# the same blob into question, option and rationale is exactly what they detect.
fm_decision_defects() {  # -> defect codes on stdout
  local d='' id label ids='' norms='' n qn rn seen
  local dup_opt=0 empty_opt=0 long_opt=0 bad_id=0 dup_id=0

  qn=$(fm_decision_normalise "$FM_DECISION_QUESTION")
  rn=$(fm_decision_normalise "$FM_DECISION_RECOMMEND_WHY")

  [ -n "$qn" ] || d="$d no-question"
  [ "${#FM_DECISION_QUESTION}" -le "$FM_DECISION_MAX_QUESTION" ] || d="$d question-too-long"

  while IFS=$'\t' read -r id label; do
    [ -n "$id" ] || continue
    fm_decision_option_id_valid "$id" || bad_id=1
    case " $ids " in *" $id "*) dup_id=1 ;; esac
    ids="$ids $id"
    n=$(fm_decision_normalise "$label")
    if [ -z "$n" ]; then
      empty_opt=1
      continue
    fi
    [ "${#label}" -le "$FM_DECISION_MAX_OPTION" ] || long_opt=1
    seen=$(printf '%s' "$norms" | grep -Fxc -- "$n" 2>/dev/null || true)
    [ "${seen:-0}" = 0 ] || dup_opt=1
    norms="$norms$n
"
    # The paste tells: a field holding the question again, or the rationale
    # again, is not that field being filled in.
    [ -z "$qn" ] || [ "$n" != "$qn" ] || d="$d question-duplicated"
    [ -z "$rn" ] || [ "$n" != "$rn" ] || d="$d rationale-duplicated"
  done <<EOF
$FM_DECISION_OPTIONS
EOF

  [ "$FM_DECISION_OPTION_COUNT" -ge 2 ] || d="$d too-few-options"
  [ "$bad_id" -eq 0 ] || d="$d bad-option-id"
  [ "$dup_id" -eq 0 ] || d="$d duplicate-option-id"
  [ "$empty_opt" -eq 0 ] || d="$d empty-option"
  [ "$long_opt" -eq 0 ] || d="$d option-too-long"
  [ "$dup_opt" -eq 0 ] || d="$d duplicate-options"

  if [ -z "$FM_DECISION_RECOMMEND_ID" ]; then
    d="$d no-recommendation"
  elif ! fm_decision_option_label "$FM_DECISION_RECOMMEND_ID" >/dev/null; then
    # A recommendation pointing at nothing is the coin flip this whole path
    # exists to remove.
    d="$d recommend-unknown-option"
  fi

  if [ -z "$rn" ]; then
    d="$d no-rationale"
  else
    [ "${#FM_DECISION_RECOMMEND_WHY}" -le "$FM_DECISION_MAX_RATIONALE" ] || d="$d rationale-too-long"
    [ -z "$qn" ] || [ "$rn" != "$qn" ] || d="$d question-duplicated"
  fi

  # Deduplicate: question-duplicated can be raised by more than one field.
  printf '%s' "$d" | tr ' ' '\n' | grep -v '^$' | sort -u | tr '\n' ' ' \
    | sed -e 's/ $//'
}

# Human-readable explanation for one defect code, used by the writer's refusal
# and by the relay's MALFORMED banner so an operator sees the same words in
# both places.
fm_decision_defect_help() {  # <code>
  case "$1" in
    no-question) printf 'the question is empty - state in one sentence what is being asked' ;;
    question-too-long) printf 'the question is over %s characters - that is a paragraph, not a question; put the reasoning in --because or the report' "$FM_DECISION_MAX_QUESTION" ;;
    question-duplicated) printf 'the question text is repeated in an option or in --because - fields filled with the same blob are not separate fields' ;;
    too-few-options) printf 'fewer than two options - a choice needs at least two; if it is not a choice, raise it as free text' ;;
    empty-option) printf 'an option has no label' ;;
    option-too-long) printf 'an option label is over %s characters - an option is a label, not its argument' "$FM_DECISION_MAX_OPTION" ;;
    duplicate-options) printf 'two options say the same thing' ;;
    duplicate-option-id) printf 'two options share an id - an id must identify exactly one option' ;;
    bad-option-id) printf 'an option id is not a slug (allowed: A-Z a-z 0-9 . _ -)' ;;
    no-recommendation) printf 'no recommendation - name the option you would pick with --recommend <id>' ;;
    recommend-unknown-option) printf 'the recommendation names an option id that does not exist' ;;
    no-rationale) printf 'no rationale - say why with --because' ;;
    rationale-too-long) printf 'the rationale is over %s characters - keep the reasoning chain behind the decision' "$FM_DECISION_MAX_RATIONALE" ;;
    rationale-duplicated) printf 'the rationale repeats an option label verbatim' ;;
    truncated-record) printf 'the record on disk is incomplete (a torn or interrupted write)' ;;
    oversized-record-file) printf 'the record file is implausibly large and was not parsed' ;;
    *) printf 'unrecognised defect' ;;
  esac
}
