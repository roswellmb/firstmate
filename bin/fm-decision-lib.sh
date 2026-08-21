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
#   consequence<TAB><option-id><TAB><encoded text>  (repeated, OPTIONAL)
#   recommend<TAB><option-id><TAB><encoded rationale>
#   end<TAB><key>
# Field values are backslash-encoded (see fm_decision_encode) so a value can
# never contain a raw TAB or newline and therefore can never forge a field or a
# block boundary. A block missing its `end` line is TRUNCATED and is never used
# in part; the last COMPLETE block for a key wins, so re-raising a key after it
# was resolved supersedes cleanly without rewriting history.
#
# THE FORMAT VERSION DID NOT CHANGE when `consequence` was added, and that is
# the whole compatibility story rather than an oversight. A reader that predates
# the line skips it, exactly as it already skips any line whose kind it does not
# recognise, and renders the same question, options and recommendation it always
# did. Bumping the version would have done the opposite: an older reader
# discards a block whose version it does not know, so every decision carrying a
# consequence would have gone dark on every surface that had not updated yet.
# A line older readers ignore is additive; changing what an existing line MEANS
# would not be, and would need the bump.
#
# PER-OPTION CONSEQUENCE - what follows if the captain picks THIS option.
# A recommendation is only honest when the reader could have disagreed with it,
# and three labels that cannot be weighed against each other are not a choice:
# the marked one gets taken because it is the only argued one. The consequence
# is where that weighing material lives, attached to the option it belongs to.
#
# It is OPTIONAL, and a decision without it is not a defective decision - it is
# the ordinary decision this contract has always recorded. Nothing here compels
# the field, because compulsion produces the degenerate case it is meant to
# prevent: a worker required to write one consequence per option writes the same
# sentence three times. What this file does instead is make a FAKED consequence
# detectable (see DEGENERACY below) and make partial coverage VISIBLE, so an
# unargued option is seen as unargued rather than presented as an equal choice.
#
# It is attached BY OPTION ID, never by position, for the same reason the option
# id exists at all: identity is the half of this contract another surface has to
# agree with, and a positional attachment would silently re-point every
# consequence the moment an option row was dropped as unrenderable.
#
# COVERAGE IS A COUNT, NOT A GRADE. `covered of options` is a fact - it is
# decided by matching ids, it cannot be argued with, and one of three is
# decisive on its own. Nothing in this file scores, rates or grades a
# consequence, and nothing may be added that does: a threshold standing in for
# judgement becomes a target, and a worker clearing it writes three distinct
# useless sentences that now look verified. Whether a consequence is TRUE, is
# the RIGHT one, or would actually have let the reader disagree is a question
# only a reader can answer, and this file must never appear to have answered it.
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
# The separation only holds if the encoding does, so FM_DECISION_OPTIONS - the
# in-memory option list, which is itself TAB/newline delimited - holds ENCODED
# labels from parse to render, and each label is decoded only where exactly one
# of them is being used. A decoded label put back into that list would let a
# label carrying a newline mint an option under an id of its own choosing,
# which is the identity contract failing at the last hop rather than the first.
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
# That same function also publishes COVERAGE - how many options carry a
# consequence - and coverage is deliberately NOT a defect. Every defect code
# says "this is not structure" and costs the record its fields; coverage says
# "this much of it is argued", which is true of a perfectly sound record and
# must not withhold anything. Keeping the two apart is what lets a partially
# covered decision be recorded, rendered and honestly labelled instead of
# refused - and a refusal here would be the compulsion that manufactures the
# padded field in the first place.
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
# A consequence is what follows from ONE option - a sentence the captain weighs
# against the other options' sentences. Past this it is the reasoning chain,
# which belongs behind the decision like every other cap here says.
FM_DECISION_MAX_CONSEQUENCE=240

# THERE IS DELIBERATELY NO RATIO BETWEEN ONE CONSEQUENCE'S LENGTH AND ANOTHER'S,
# and nobody may add one back. A "one consequence carries everything" check once
# lived here, tripping when the longest outweighed the others put together; it
# was removed because BYTE LENGTH CANNOT TELL AN HONEST TERSE CONSEQUENCE FROM A
# WAVED-AT ONE - that distinction is about meaning, not size. Measured against
# the check as it was built, a 192-byte consequence refused "Ships today." (12
# bytes), "Two services to run and page on." (32 bytes) and "Needs a store we do
# not run yet, so it lands after the freeze." (62 bytes) - all honest, all well
# inside the cap above. No factor rescues it either: letting "Ships today."
# through needs a factor of 16 or more, at which point the check only separates
# a 4-byte consequence from a 12-byte one. A length ratio is therefore a quality
# proxy wearing a shape-fact costume, and this file's governing rule is that
# nothing scores, rates or grades a consequence, because a bar a worker must
# clear is a bar a worker writes to. Its only escapes were padding the short
# consequence or dropping the field - the exact compulsion this field exists to
# avoid.
#
# WHAT BOUNDS THE REAL BLOB INSTEAD: FM_DECISION_MAX_CONSEQUENCE above refuses a
# consequence that swallowed the argument, consequence-duplicates-rationale
# catches the reasoning chain pasted in, and the relay prints every consequence
# so the reader can see a token for what it is. Showing beats scoring.

# Refuse to parse an implausibly large record file rather than reading forever.
FM_DECISION_MAX_FILE_BYTES=262144

# The ceiling an ENCODED field must clear BEFORE anything decodes it.
#
# The caps above are the real limits, but they describe decoded text, so
# enforcing them alone means the expensive operation runs before the check that
# would have rejected its input. A field is crewmate-controlled and this path
# runs at the top of every wake-handling turn, so the order is reversed here:
# the cheap length test on the encoded form comes first, and a value past this
# ceiling is never decoded at all.
#
# One ceiling covers all three fields. Encoding replaces a character with at
# most two, so encoded length is never more than twice the text's length: a
# field encoded longer than twice the LARGEST cap must decode to more than that
# largest cap, and is therefore already too long whichever of the three it is.
# Rejecting it cannot change a verdict - it only declines to spend the work of
# reaching one that is already certain. The exact per-field cap still decides
# every field that clears this ceiling.
#
# FM_DECISION_MAX_RAW is the same ceiling stated for a value that has not been
# encoded yet: one past the largest cap, so a value longer than it has already
# failed whichever cap applies to it. Both directions of the wire format cut
# their input to their own ceiling, so no value a worker supplies can reach an
# expensive transform before a length check has had the chance to reject it.
FM_DECISION_MAX_RAW=$FM_DECISION_MAX_QUESTION
[ "$FM_DECISION_MAX_OPTION" -le "$FM_DECISION_MAX_RAW" ] \
  || FM_DECISION_MAX_RAW=$FM_DECISION_MAX_OPTION
[ "$FM_DECISION_MAX_RATIONALE" -le "$FM_DECISION_MAX_RAW" ] \
  || FM_DECISION_MAX_RAW=$FM_DECISION_MAX_RATIONALE
[ "$FM_DECISION_MAX_CONSEQUENCE" -le "$FM_DECISION_MAX_RAW" ] \
  || FM_DECISION_MAX_RAW=$FM_DECISION_MAX_CONSEQUENCE
FM_DECISION_MAX_ENCODED=$((2 * FM_DECISION_MAX_RAW))
FM_DECISION_MAX_RAW=$((FM_DECISION_MAX_RAW + 1))

# The status note carries its own cap, because it is the one bounded value that
# gets STORED. Everywhere else a bound is invisible - a cut value is already
# past its own cap and is therefore refused, so the cut can never reach the
# record - but the note is written to a durable append-only log, and shortening
# it there would lose a worker's words in the one place they no longer exist.
# So an over-long note is REFUSED at write time, while the words are still in
# front of the person who can shorten them.
#
# The cap sits one BELOW FM_DECISION_MAX_RAW, which is what makes truncation
# unreachable rather than merely unlikely: a note that passes this check is
# shorter than the cut fm_decision_flatten_var applies, so that cut is a cost
# guard that can never alter what lands.
# shellcheck disable=SC2034 # read by bin/fm-decision-raise.sh's note refusal, not here.
FM_DECISION_MAX_NOTE=$((FM_DECISION_MAX_RAW - 1))

# --- value encoding ---------------------------------------------------------
# Encode one field value so it cannot contain a raw TAB or newline. Backslash is
# escaped FIRST so decoding is unambiguous.
#
# THIS FUNCTION APPLIES THE BOUND, on the same terms and for the same reason as
# fm_decision_decode_var applies it in the other direction: bash 3.2 rebuilds
# the whole string on every substitution match, so encoding an unbounded value
# costs more than linearly in its length, and the value here comes straight off
# a worker's command line. Cutting to FM_DECISION_MAX_RAW makes the work
# constant however much prose was pasted.
#
# The cut cannot reach anything that gets STORED. A value bound for the record
# is encoded only after fm_decision_defects has passed it, so it is already
# inside its own cap and shorter than this ceiling; a value still awaiting that
# check is one the validator will reject, because what survives the cut is
# longer than every cap and still trips the same *-too-long code it would have.
fm_decision_encode() {  # <value> -> encoded on stdout
  local s=${1:0:$FM_DECISION_MAX_RAW}
  s=${s//\\/\\\\}
  s=${s//$'\t'/\\t}
  s=${s//$'\n'/\\n}
  s=${s//$'\r'/\\r}
  printf '%s' "$s"
}

# Decode one encoded field value into FM_DECISION_VALUE. Walks left to right so
# an escaped backslash is never re-interpreted as introducing an escape.
#
# DECODING IS THE BOUNDARY. An encoded value cannot hold a raw TAB or newline,
# so it can never forge a field or a block boundary; a DECODED one can hold
# both. Every accumulator that keeps more than one value - FM_DECISION_OPTIONS
# above all - therefore holds ENCODED values, and decoding happens only at the
# point a single value is finally used (measured, compared or rendered). A
# decoded value must never be put back into a delimited structure.
#
# Assigns rather than prints so a caller on the drain path never pays a command
# substitution per option.
#
# It also moves a RUN at a time rather than a character at a time. Every string
# operation in bash copies the whole remaining string, so stepping one character
# per iteration costs more than linearly in the value's length, and this runs on
# every field of every open decision on every drain. Text carrying no escape -
# which is what ordinary prose is - is therefore copied once, and the loop turns
# only as many times as the value has escapes to resolve.
#
# Its cost is bounded because THIS FUNCTION applies the bound, before the loop
# and on every path into it. A caller cannot forget the gate, because there is
# no way past it: a value too long to belong to any sound field is WITHHELD -
# FM_DECISION_VALUE is empty and FM_DECISION_VALUE_WITHHELD is 1 - and the loop
# never runs. The run-at-a-time walk below is then defence in depth behind a
# bound that holds structurally, rather than the whole of the defence.
#
# It never fails: a caller that does not care about the distinction reads an
# empty value, and the record carries oversized-field through the one validator
# so the withholding surfaces as a malformed record rather than as an error.
fm_decision_decode_var() {  # <encoded> -> FM_DECISION_VALUE, FM_DECISION_VALUE_WITHHELD
  local s=$1 out='' head rest c bs=$'\\'
  if ! fm_decision_encoded_within_bound "$s"; then
    FM_DECISION_VALUE=
    FM_DECISION_VALUE_WITHHELD=1
    return 0
  fi
  FM_DECISION_VALUE_WITHHELD=0
  while :; do
    case "$s" in
      *"$bs"*) : ;;
      *) out="$out$s"; break ;;
    esac
    head=${s%%"$bs"*}
    out="$out$head"
    rest=${s#*"$bs"}
    if [ -z "$rest" ]; then
      out="$out$bs"
      break
    fi
    c=${rest%"${rest#?}"}
    rest=${rest#?}
    case "$c" in
      t) out="$out"$'\t' ;;
      n) out="$out"$'\n' ;;
      r) out="$out"$'\r' ;;
      "$bs") out="$out$bs" ;;
      *) out="$out$bs$c" ;;
    esac
    s=$rest
  done
  FM_DECISION_VALUE=$out
}
FM_DECISION_VALUE=
FM_DECISION_VALUE_WITHHELD=0

# The bound itself: is this encoded value small enough to be worth decoding at
# all? fm_decision_decode_var applies it to every value it is given, so a caller
# only asks this directly when it must decide something WITHOUT decoding - which
# rows belong in the option list, say.
fm_decision_encoded_within_bound() {  # <encoded>
  [ "${#1}" -le "$FM_DECISION_MAX_ENCODED" ]
}

# --- flattening for single-line surfaces ------------------------------------
# Fold a value onto ONE line: every newline, CR, TAB and other whitespace run
# becomes a single space, and the ends are trimmed. A digest line is a line, so
# a value that reaches one must not be able to add another - a length cap bounds
# size, it does not stop a forged line. Fork-free: this runs per rendered field
# at the top of every wake-handling turn.
#
# It bounds its own input, like every other transform in this file, because the
# value can arrive straight from a worker's command line: the five substitutions
# below each rebuild the whole string on bash 3.2, so an unbounded value costs
# more than linearly in its length. Every field this renders is already inside
# its own cap by the time it gets here, so the cut is invisible to them; what it
# does bound is the status note, which is one line of a log and is cut to the
# same ceiling as the longest field a decision may carry.
fm_decision_flatten_var() {  # <text> -> FM_DECISION_FLAT
  local s=${1:0:$FM_DECISION_MAX_RAW}
  s=${s//$'\n'/ }
  s=${s//$'\r'/ }
  s=${s//$'\t'/ }
  s=${s//$'\v'/ }
  s=${s//$'\f'/ }
  while [ "$s" != "${s//  / }" ]; do s=${s//  / }; done
  s=${s# }
  s=${s% }
  FM_DECISION_FLAT=$s
}
# shellcheck disable=SC2034 # read by this library's callers (the wake digest and the raise command), not here.
FM_DECISION_FLAT=

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
#
# Builtins only - no tr, no sed, no subshell. This is called for every field of
# every open decision on every drain, and bin/fm-line-cap-lib.sh documents the
# same intent for the same caller: this path must never pay a process per item.
# Bash 3.2 has no ${var,,}, so the case fold is 26 substitutions instead.
#
# COST IS BOUNDED, NOT MERELY FORK-FREE. Bash 3.2 rebuilds the whole string on
# every pattern-substitution match, so folding an unbounded value costs more
# than linearly in its length - and a worker's status note has no length limit.
# Firstmate's supervision latency must not be a function of what a crewmate
# wrote, so the value is cut to FM_DECISION_MAX_RAW first and the work below is
# therefore constant however long the input is.
#
# The bound is one past the LARGEST field cap, which is what makes the cut
# invisible to every verdict this function feeds: a value that passes its length
# check is shorter than the bound and is normalised in full, so the duplicate
# checks are exact; a value long enough to be cut here has already failed its
# cap and made the record degenerate whatever the duplicate checks then say.
fm_decision_normalise_var() {  # <text> -> FM_DECISION_NORM
  local s=${1:0:$FM_DECISION_MAX_RAW}
  s=${s//A/a}; s=${s//B/b}; s=${s//C/c}; s=${s//D/d}; s=${s//E/e}
  s=${s//F/f}; s=${s//G/g}; s=${s//H/h}; s=${s//I/i}; s=${s//J/j}
  s=${s//K/k}; s=${s//L/l}; s=${s//M/m}; s=${s//N/n}; s=${s//O/o}
  s=${s//P/p}; s=${s//Q/q}; s=${s//R/r}; s=${s//S/s}; s=${s//T/t}
  s=${s//U/u}; s=${s//V/v}; s=${s//W/w}; s=${s//X/x}; s=${s//Y/y}
  s=${s//Z/z}
  s=${s//$'\n'/ }
  s=${s//$'\r'/ }
  s=${s//$'\t'/ }
  s=${s//$'\v'/ }
  s=${s//$'\f'/ }
  while [ "$s" != "${s//  / }" ]; do s=${s//  / }; done
  s=${s# }
  s=${s% }
  while :; do
    case "$s" in
      *[.?!]) s=${s%?} ;;
      *) break ;;
    esac
  done
  FM_DECISION_NORM=$s
}
FM_DECISION_NORM=

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
  FM_DECISION_CONSEQUENCES=
  FM_DECISION_CONSEQUENCE_COVERED=0
  FM_DECISION_COVERAGE_CODE=
  FM_DECISION_RECOMMEND_ID=
  FM_DECISION_RECOMMEND_WHY=
  FM_DECISION_DEFECTS=
  FM_DECISION_PARSE_DEFECTS=
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
#
# FM_DECISION_OPTIONS holds ENCODED labels (see fm_decision_decode_var), so this
# is one of the few places allowed to decode: it hands back exactly one label.
#
# A label the decoder withheld is reported as a MISS rather than as an empty
# label: an option whose text cannot be read is not an option a recommendation
# can name, and every caller already treats a miss as recommend-unknown-option.
fm_decision_option_label() {  # <id> -> label on stdout
  local want=$1 id label
  while IFS=$'\t' read -r id label; do
    [ -n "$id$label" ] || continue
    if [ "$id" = "$want" ]; then
      fm_decision_decode_var "$label"
      [ "$FM_DECISION_VALUE_WITHHELD" -eq 0 ] || return 1
      printf '%s' "$FM_DECISION_VALUE"
      return 0
    fi
  done <<EOF
$FM_DECISION_OPTIONS
EOF
  return 1
}

# One option's CONSEQUENCE - what follows if the captain picks it. ASSIGNS the
# text to FM_DECISION_CONSEQUENCE and sets FM_DECISION_CONSEQUENCE_FOUND to 1
# when <id> carries one, to 0 when it does not - which is the ordinary case for
# a decision that declined the field and for every option a partially covered
# decision left unargued.
#
# IT ASSIGNS RATHER THAN PRINTS for exactly the reason fm_decision_decode_var's
# header gives, and for exactly the same caller: bin/fm-wake-drain.sh calls this
# ONCE PER RENDERED OPTION at the top of every wake-handling turn, and must
# never pay a command substitution per option. The option count is a crewmate's
# number, not a cap of ours, so a fork per option is a fork per row of an
# untrusted file. The printing wrapper below is for the raise and show/--json
# callers, which run once by hand and are not on that path.
#
# The same decode discipline as fm_decision_option_label, and for the same
# reason: FM_DECISION_CONSEQUENCES holds ENCODED text, and this hands back
# exactly one value. Withheld text is a MISS rather than an empty consequence,
# so a renderer never prints an empty `=>` where a field it could not read was.
#
# IT LOOKS THE ROW UP RATHER THAN WALKING TO IT, which its option-label sibling
# does not need to: that one is called ONCE per record, to check the
# recommendation, while this is called once per rendered OPTION. A walk would
# make rendering cost options times consequences, and both lists come from the
# same untrusted file - a record can carry thousands of each and still be sound,
# so a product of two attacker-chosen counts sits on the path that runs at the
# top of every wake-handling turn. Two parameter expansions cost one scan of the
# accumulator instead of one loop turn per row in it.
#
# The match is exact for the same reason the format is safe: an encoded value
# can hold neither a raw TAB nor a newline, so `<newline><id><TAB>` can only
# begin a real row and the row ends at the next newline. The leading newline is
# prepended so the first row is reachable by the same pattern as the rest, and
# the SHORTEST match wins, so an id repeated by a hand-written record resolves
# to its first row exactly as a walk would have.
# shellcheck disable=SC2034 # FM_DECISION_CONSEQUENCE* are published outputs, read by this library's callers.
fm_decision_option_consequence_var() {  # <id> -> FM_DECISION_CONSEQUENCE, FM_DECISION_CONSEQUENCE_FOUND
  local want=$1 all rest
  FM_DECISION_CONSEQUENCE=
  FM_DECISION_CONSEQUENCE_FOUND=0
  all=$'\n'$FM_DECISION_CONSEQUENCES
  case "$all" in
    *$'\n'"$want"$'\t'*) : ;;
    *) return 0 ;;
  esac
  rest=${all#*$'\n'"$want"$'\t'}
  fm_decision_decode_var "${rest%%$'\n'*}"
  [ "$FM_DECISION_VALUE_WITHHELD" -eq 0 ] || return 0
  FM_DECISION_CONSEQUENCE=$FM_DECISION_VALUE
  FM_DECISION_CONSEQUENCE_FOUND=1
}
FM_DECISION_CONSEQUENCE=
FM_DECISION_CONSEQUENCE_FOUND=0

# The printing form of the above, for the callers that read one consequence at a
# time by hand: prints the text and returns 0 on a hit, returns 1 on a miss. The
# drain must use the assigning form instead - see its header.
fm_decision_option_consequence() {  # <id> -> consequence text on stdout
  fm_decision_option_consequence_var "$1"
  [ "$FM_DECISION_CONSEQUENCE_FOUND" -eq 1 ] || return 1
  printf '%s' "$FM_DECISION_CONSEQUENCE"
  return 0
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
  local blk_cons='' blk_pd='' saw_truncated=0 bytes

  fm_decision_reset
  # The same guard the sibling fold uses on the status log this record is joined
  # to (bin/fm-classify-lib.sh's status_open_decisions): a record file that is
  # itself a symlink - e.g. escaping the state directory - is rejected outright
  # with a plain builtin check before any read.
  [ -n "$file" ] && [ -f "$file" ] && [ -r "$file" ] && [ ! -L "$file" ] || return 1

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
        blk_cons=''; blk_pd=''
        # Ignore a block written by a format version this reader does not know
        # rather than guessing at its fields.
        if [ "$blk_ver" = "$FM_DECISION_FORMAT_VERSION" ] && [ "$blk_key" = "$want" ]; then
          in_block=1
        fi
        ;;
      question)
        [ "$in_block" -eq 1 ] || continue
        blk_seen_q=1
        fm_decision_decode_var "$a"
        blk_q=$FM_DECISION_VALUE
        [ "$FM_DECISION_VALUE_WITHHELD" -eq 0 ] \
          || blk_pd="$blk_pd oversized-field question-too-long"
        ;;
      option)
        [ "$in_block" -eq 1 ] || continue
        # ONE rule decides what an option row IS, and it governs the accumulator
        # and the count in the same breath. A row every consumer would skip must
        # not be counted as an option by the validator, or a record can satisfy
        # too-few-options while rendering as a single option - the degeneracy
        # check bypassing itself. A row dropped here is not absorbed: the record
        # simply has fewer options, which is what makes it degenerate.
        [ -n "$a$b" ] || continue
        # A label too long to be any sound option never enters the accumulator,
        # so no consumer downstream can be handed one to decode. Same shape as
        # the empty-row rule above: what an option IS is decided here, once.
        if ! fm_decision_encoded_within_bound "$b"; then
          blk_pd="$blk_pd oversized-field option-too-long"
          continue
        fi
        # The label stays ENCODED here. Decoding it into this accumulator is
        # what would let a label carrying a newline mint an extra option row
        # with an id of its own choosing; fm_decision_defects and every
        # renderer decode one label at a time instead.
        blk_opts="$blk_opts$a	$b
"
        blk_count=$((blk_count + 1))
        ;;
      consequence)
        [ "$in_block" -eq 1 ] || continue
        # THE SAME ROW RULE AS `option` ABOVE, deliberately, because the two
        # accumulators are read by the same discipline: a wholly empty row is
        # not a row, a row too long to be any sound consequence never enters the
        # accumulator so no consumer downstream can be handed it to decode, and
        # the text stays ENCODED here so it can neither mint a row nor forge a
        # field. A dropped row is not absorbed - the record simply covers fewer
        # options, which is a fact the coverage count then states out loud.
        [ -n "$a$b" ] || continue
        if ! fm_decision_encoded_within_bound "$b"; then
          blk_pd="$blk_pd oversized-field consequence-too-long"
          continue
        fi
        blk_cons="$blk_cons$a	$b
"
        ;;
      recommend)
        [ "$in_block" -eq 1 ] || continue
        blk_rid=$a
        fm_decision_decode_var "$b"
        blk_why=$FM_DECISION_VALUE
        [ "$FM_DECISION_VALUE_WITHHELD" -eq 0 ] \
          || blk_pd="$blk_pd oversized-field rationale-too-long"
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
          FM_DECISION_CONSEQUENCES=${blk_cons%$'\n'}
          FM_DECISION_RECOMMEND_ID=$blk_rid
          FM_DECISION_RECOMMEND_WHY=$blk_why
          FM_DECISION_PARSE_DEFECTS=$blk_pd
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

  fm_decision_defects_var
  FM_DECISION_DEFECTS=$FM_DECISION_DEFECT_CODES
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
# Builtins only, for the same reason fm_decision_normalise_var is: every reader
# re-runs this on every drain.
fm_decision_defects_var() {  # -> FM_DECISION_DEFECT_CODES, FM_DECISION_CONSEQUENCE_COVERED, FM_DECISION_COVERAGE_CODE
  local d=$FM_DECISION_PARSE_DEFECTS
  local id label text ids='' norms=$'\n' n qn rn code out=''
  local dup_opt=0 empty_opt=0 long_opt=0 bad_id=0 dup_id=0 oversized=0
  local opt_norms=$'\n' want_opt_norms=0 cid cn cids='' cnorms=$'\n' cseen covered=0
  local dup_cons=0 empty_cons=0 long_cons=0 dup_cid=0 unknown_cid=0 bad_cid=0

  [ -z "$FM_DECISION_CONSEQUENCES" ] || want_opt_norms=1

  fm_decision_normalise_var "$FM_DECISION_QUESTION"; qn=$FM_DECISION_NORM
  fm_decision_normalise_var "$FM_DECISION_RECOMMEND_WHY"; rn=$FM_DECISION_NORM

  # A field the parser withheld as oversized is not a MISSING field, so the
  # "nothing there" codes stay quiet for it and the length code speaks instead.
  case " $d " in
    *' question-too-long '*) : ;;
    *) [ -n "$qn" ] || d="$d no-question" ;;
  esac
  [ "${#FM_DECISION_QUESTION}" -le "$FM_DECISION_MAX_QUESTION" ] || d="$d question-too-long"

  while IFS=$'\t' read -r id label; do
    # Only a wholly empty accumulator line is skipped, so a row that carries a
    # label under an EMPTY or non-slug id still reaches the id check below
    # rather than being quietly accepted.
    [ -n "$id$label" ] || continue
    fm_decision_option_id_valid "$id" || bad_id=1
    case " $ids " in *" $id "*) dup_id=1 ;; esac
    ids="$ids $id"
    # The label is encoded in the accumulator; measure and compare the text it
    # actually is. A label the decoder withheld is past every cap by definition,
    # so the writer refuses it on the same terms the reader withholds one.
    fm_decision_decode_var "$label"; text=$FM_DECISION_VALUE
    if [ "$FM_DECISION_VALUE_WITHHELD" -ne 0 ]; then
      oversized=1
      long_opt=1
      continue
    fi
    fm_decision_normalise_var "$text"; n=$FM_DECISION_NORM
    if [ -z "$n" ]; then
      empty_opt=1
      continue
    fi
    [ "${#text}" -le "$FM_DECISION_MAX_OPTION" ] || long_opt=1
    # A normalised label has no newline left in it, so newline-delimited
    # membership is an exact match without a grep per option.
    case "$norms" in *$'\n'"$n"$'\n'*) dup_opt=1 ;; esac
    norms="$norms$n"$'\n'
    # Remember each option's normalised label against its id, so the
    # consequence checks below can ask "is this consequence just its own
    # option's label again?" without a second pass over the option list.
    #
    # THIS PUTS A DERIVED VALUE BACK INTO A DELIMITED STRUCTURE, which the
    # header forbids for a DECODED one - so note exactly why it is safe here
    # and only here: fm_decision_normalise_var replaces every newline, CR and
    # TAB with a space, so a normalised label provably contains neither
    # delimiter and cannot forge a row of this structure the way the decoded
    # label it came from could. Nothing decoded may follow it in.
    #
    # Built only when there is something to check it against. Bash rebuilds the
    # whole string on every append, so accumulating it costs more than linearly
    # in the option count - and a record that declined consequences would be
    # paying that for a comparison that never happens. Declining the field has
    # to cost exactly what it cost before the field existed.
    [ "$want_opt_norms" -eq 0 ] || opt_norms="$opt_norms$id"$'\t'"$n"$'\n'
    # The paste tells: a field holding the question again, or the rationale
    # again, is not that field being filled in.
    [ -z "$qn" ] || [ "$n" != "$qn" ] || d="$d question-duplicated"
    [ -z "$rn" ] || [ "$n" != "$rn" ] || d="$d rationale-duplicated"
  done <<EOF
$FM_DECISION_OPTIONS
EOF

  # --- consequences ---------------------------------------------------------
  # Optional, so an EMPTY accumulator produces nothing at all here: no code, no
  # coverage line, no trace. That silence is the contract - a decision that
  # declined the field is an ordinary decision, and a surface must not be able
  # to tell it apart from one raised before the field existed.
  #
  # What is checked is the same thing every check in this function checks: has
  # this field been filled in, or does it hold text that was pasted rather than
  # written for it? A consequence repeating its own option's label, another
  # option's consequence, the rationale or the question is the padding tell, and
  # it is exactly what a worker produces when made to fill a field it has
  # nothing to put in.
  while IFS=$'\t' read -r cid text; do
    [ -n "$cid$text" ] || continue
    # THE ID IS VALIDATED ON EXACTLY THE TERMS THE OPTION ROW'S ID IS, and it
    # has to be, because attachment below is decided by a SPACE-DELIMITED
    # membership test. An option id is a slug, so it can never contain a space;
    # that is what makes the cheap test sound - but only once the id being
    # looked up is known to be a slug too. A hand-written `consequence<TAB>1 2`
    # beside options `1` and `2` matches " 1 2 " in " $ids " and would be
    # credited as coverage, while fm_decision_option_consequence - which matches
    # ONE id exactly - finds nothing under either. That is a record claiming
    # coverage it does not have, which is the backstop case this file exists to
    # catch. Validating the id here closes it without a second structure.
    #
    # A row that fails is not credited, not remembered as seen, and not checked
    # for paste tells: it is attached to no option, so there is nothing for its
    # text to be weighed against and nothing coverage could honestly count.
    if ! fm_decision_option_id_valid "$cid"; then
      bad_cid=1
      continue
    fi
    cseen=0
    case " $cids " in *" $cid "*) cseen=1 ;; esac
    if [ "$cseen" -eq 1 ]; then
      # Two consequences under one id: which one belongs to that option is
      # unanswerable, so the attachment this whole field rests on is broken.
      dup_cid=1
    else
      cids="$cids $cid"
    fi
    # A consequence attaches BY ID. One naming no option of this record is
    # attached to nothing, and an unattached consequence cannot be weighed
    # against anything - it is not the option's argument, it is a loose line.
    case " $ids " in
      *" $cid "*) [ "$cseen" -eq 1 ] || covered=$((covered + 1)) ;;
      *) unknown_cid=1 ;;
    esac
    fm_decision_decode_var "$text"; text=$FM_DECISION_VALUE
    if [ "$FM_DECISION_VALUE_WITHHELD" -ne 0 ]; then
      oversized=1
      long_cons=1
      continue
    fi
    fm_decision_normalise_var "$text"; cn=$FM_DECISION_NORM
    if [ -z "$cn" ]; then
      empty_cons=1
      continue
    fi
    [ "${#text}" -le "$FM_DECISION_MAX_CONSEQUENCE" ] || long_cons=1
    # Two options whose stated consequence is the same sentence cannot be
    # weighed against each other, which is the captain's own test failing.
    case "$cnorms" in *$'\n'"$cn"$'\n'*) dup_cons=1 ;; esac
    cnorms="$cnorms$cn"$'\n'
    # Restating the label adds nothing: the reader already has the label.
    case "$opt_norms" in *$'\n'"$cid"$'\t'"$cn"$'\n'*) d="$d consequence-duplicates-option" ;; esac
    [ -z "$rn" ] || [ "$cn" != "$rn" ] || d="$d consequence-duplicates-rationale"
    [ -z "$qn" ] || [ "$cn" != "$qn" ] || d="$d consequence-duplicates-question"
  done <<EOF
$FM_DECISION_CONSEQUENCES
EOF

  # NOTHING COMPARES ONE CONSEQUENCE'S LENGTH AGAINST ANOTHER'S HERE, on purpose
  # - see the comment above FM_DECISION_MAX_CONSEQUENCE for the measurements
  # that removed the check that did. Byte length cannot tell an honest terse
  # consequence from a waved-at one, and a ratio dressed up as a shape fact is
  # still a quality proxy. The cap, consequence-duplicates-rationale and the
  # relay printing every consequence are what bound the real blob.

  # COVERAGE, the strongest signal and the one that is purely a count. It is
  # published rather than turned into a refusal on purpose: refusing a record
  # for covering some options and not others would force a worker holding one
  # real consequence to invent two, which is the degeneracy this field exists to
  # avoid. So a partially covered decision is recorded, is rendered in full, and
  # SAYS SO - the unargued options are visible as unargued instead of sitting
  # beside an argued one looking like equal choices.
  FM_DECISION_CONSEQUENCE_COVERED=$covered
  # shellcheck disable=SC2034 # published output, read by this library's callers (the raise command and the wake digest), not here.
  FM_DECISION_COVERAGE_CODE=
  if [ "$covered" -gt 0 ] && [ "$covered" -lt "$FM_DECISION_OPTION_COUNT" ]; then
    # shellcheck disable=SC2034 # published output, read by this library's callers, not here.
    FM_DECISION_COVERAGE_CODE=consequences-partial
  fi

  [ "$FM_DECISION_OPTION_COUNT" -ge 2 ] || d="$d too-few-options"
  [ "$bad_id" -eq 0 ] || d="$d bad-option-id"
  [ "$dup_id" -eq 0 ] || d="$d duplicate-option-id"
  [ "$empty_opt" -eq 0 ] || d="$d empty-option"
  [ "$long_opt" -eq 0 ] || d="$d option-too-long"
  [ "$dup_opt" -eq 0 ] || d="$d duplicate-options"
  [ "$bad_cid" -eq 0 ] || d="$d bad-consequence-option-id"
  [ "$dup_cid" -eq 0 ] || d="$d duplicate-consequence-id"
  [ "$unknown_cid" -eq 0 ] || d="$d consequence-unknown-option"
  [ "$empty_cons" -eq 0 ] || d="$d empty-consequence"
  [ "$long_cons" -eq 0 ] || d="$d consequence-too-long"
  [ "$dup_cons" -eq 0 ] || d="$d duplicate-consequences"
  [ "$oversized" -eq 0 ] || d="$d oversized-field"

  if [ -z "$FM_DECISION_RECOMMEND_ID" ]; then
    d="$d no-recommendation"
  elif ! fm_decision_option_label "$FM_DECISION_RECOMMEND_ID" >/dev/null; then
    # A recommendation pointing at nothing is the coin flip this whole path
    # exists to remove.
    d="$d recommend-unknown-option"
  fi

  case " $d " in
    *' rationale-too-long '*) : ;;
    *)
      if [ -z "$rn" ]; then
        d="$d no-rationale"
      else
        [ "${#FM_DECISION_RECOMMEND_WHY}" -le "$FM_DECISION_MAX_RATIONALE" ] || d="$d rationale-too-long"
        [ -z "$qn" ] || [ "$rn" != "$qn" ] || d="$d question-duplicated"
      fi
      ;;
  esac

  # Deduplicate: question-duplicated can be raised by more than one field.
  for code in $d; do
    case " $out " in *" $code "*) continue ;; esac
    out="$out $code"
  done
  FM_DECISION_DEFECT_CODES=${out# }
}
FM_DECISION_DEFECT_CODES=

fm_decision_defects() {  # -> defect codes on stdout
  fm_decision_defects_var
  printf '%s' "$FM_DECISION_DEFECT_CODES"
}

# Human-readable explanation for one defect code, used by the writer's refusal
# and by the relay's MALFORMED banner so an operator sees the same words in
# both places. It also explains FM_DECISION_COVERAGE_CODE, which is not a defect
# but is reported in the same voice, so a surface needs one lookup rather than
# two.
#
# `consequences-partial` reads the coverage counters the validator just set, so
# ask for it while the record it describes is the one parsed - the same
# already-parsed state every other caller of this file works from.
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
    empty-consequence) printf 'an option carries an empty consequence - drop it, or say what actually follows if that option is picked' ;;
    consequence-too-long) printf 'a consequence is over %s characters - state what follows in a sentence and keep the reasoning chain behind the decision' "$FM_DECISION_MAX_CONSEQUENCE" ;;
    duplicate-consequences) printf 'two options state the same consequence - options whose consequences are identical cannot be weighed against each other' ;;
    duplicate-consequence-id) printf 'two consequences name the same option - a consequence must belong to exactly one option' ;;
    consequence-unknown-option) printf 'a consequence names an option id that does not exist, so it is attached to nothing' ;;
    bad-consequence-option-id) printf 'a consequence names an option id that is not a slug (allowed: A-Z a-z 0-9 . _ -), so it can attach to no option and counts toward no coverage' ;;
    consequence-duplicates-option) printf "a consequence repeats its own option's label - the reader already has the label; say what follows from it" ;;
    consequence-duplicates-rationale) printf 'a consequence repeats the recommendation rationale - the same text in two fields is not two fields' ;;
    consequence-duplicates-question) printf 'a consequence repeats the question - the same text in two fields is not two fields' ;;
    consequences-partial) printf '%s of %s options carry a consequence - the rest are unargued, so they cannot be weighed against the ones that are' \
      "$FM_DECISION_CONSEQUENCE_COVERED" "$FM_DECISION_OPTION_COUNT" ;;
    truncated-record) printf 'the record on disk is incomplete (a torn or interrupted write)' ;;
    oversized-record-file) printf 'the record file is implausibly large and was not parsed' ;;
    oversized-field) printf 'a field is longer than %s encoded characters - far past any field cap, so it was withheld rather than decoded; shorten it, or raise this as free text' "$FM_DECISION_MAX_ENCODED" ;;
    *) printf 'unrecognised defect' ;;
  esac
}
