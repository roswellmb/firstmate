# shellcheck shell=bash
# fm-home-currency-lib.sh - the single owner of "is this firstmate home running
# the fleet's current instructions and scripts, or older ones?".
#
# Usage: . bin/fm-home-currency-lib.sh
#
# WHY THIS EXISTS. A firstmate home loads its operating instructions
# (AGENTS.md), its agent-loaded skills (.agents/skills/) and its tooling (bin/)
# from its OWN checkout, and nothing compared that checkout against origin.
# bin/fm-fleet-sync.sh fetches and reports drift for PROJECT clones under
# projects/; the secondmate sweep in bin/fm-bootstrap.sh fast-forwards secondmate
# homes to the PRIMARY checkout's local commit. Neither ever asks whether the
# home itself matches the fleet, so a home could run months-old instructions and
# start completely silently - the meta-failure family recorded in
# data/learnings.md, a component whose job is to report problems staying silent
# about its own.
#
# WHAT THIS IS NOT. It never fetches, fast-forwards, merges, checks out, resets,
# or writes anything. `git ls-remote` reads the remote's advertised refs and
# leaves no object, ref, config entry, or file behind; every other command here
# is a local read. Updating a home is /updatefirstmate's job (AGENTS.md section
# 12) and stays there deliberately: a home that fast-forwarded itself under a
# live validation run would be a worse failure than a stale one.
#
# A HOME IS NOT ITS BRANCH. Secondmate homes are leased at a DETACHED HEAD on the
# default branch (bin/fm-ff-lib.sh), so detachment is a normal state here rather
# than an error. The comparison is HEAD's COMMIT against the origin default
# branch tip and reads identically attached or detached.
#
# ORIGIN IS THE AUTHORITY, NOT THE LOCAL REMOTE-TRACKING REF. refs/remotes/origin/*
# is only as fresh as the last fetch, and a home that has not fetched in 166
# commits would compare itself against its own stale copy and pass. The probe
# therefore asks origin directly, and when it cannot, it says so instead of
# passing - a check that cannot check must never look like a check that passed.

# shellcheck source=bin/fm-tangle-lib.sh disable=SC1091
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/fm-tangle-lib.sh"
# shellcheck source=bin/fm-timeout-lib.sh disable=SC1091
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/fm-timeout-lib.sh"

# Bound for one origin probe, in seconds. An unreachable or hanging host must
# cost this at most, never the whole deferred network stage.
fm_home_currency_timeout() {
  local bound=${FM_HOME_CURRENCY_TIMEOUT:-15}
  case "$bound" in
    ''|*[!0-9]*) bound=15 ;;
  esac
  [ "$bound" -gt 0 ] || bound=15
  printf '%s\n' "$bound"
}

# A credential or host in a git error message must not be echoed into a digest
# the captain may paste elsewhere.
fm_home_currency_sanitize() {
  printf '%s' "$1" | sed -n '1s|://[^/@[:space:]]*@|://<redacted>@|g;1s/[[:space:]]\{1,\}/ /g;1p'
}

# --- origin probe -----------------------------------------------------------
#
# The primary checkout and every linked-worktree secondmate home share one
# origin, so the advertised tip is cached per origin URL and one bootstrap run
# pays for at most one round trip per distinct remote.

FM_HOME_CURRENCY_CACHE=""
FM_HOME_CURRENCY_PROBE_SHA=""
FM_HOME_CURRENCY_PROBE_BRANCH=""
FM_HOME_CURRENCY_PROBE_ERROR=""

fm_home_currency_cache_lookup() {  # <url>
  local url=$1 c_url c_sha c_branch c_err
  [ -n "$FM_HOME_CURRENCY_CACHE" ] || return 1
  while IFS=$'\t' read -r c_url c_sha c_branch c_err; do
    [ "$c_url" = "$url" ] || continue
    FM_HOME_CURRENCY_PROBE_SHA=$c_sha
    FM_HOME_CURRENCY_PROBE_BRANCH=$c_branch
    FM_HOME_CURRENCY_PROBE_ERROR=$c_err
    [ -z "$c_err" ]
    return
  done <<EOF
$FM_HOME_CURRENCY_CACHE
EOF
  return 1
}

fm_home_currency_cache_store() {  # <url>
  FM_HOME_CURRENCY_CACHE="${FM_HOME_CURRENCY_CACHE:+$FM_HOME_CURRENCY_CACHE
}$1	$FM_HOME_CURRENCY_PROBE_SHA	$FM_HOME_CURRENCY_PROBE_BRANCH	$FM_HOME_CURRENCY_PROBE_ERROR"
}

# Ask origin for its default branch tip. Sets FM_HOME_CURRENCY_PROBE_SHA and
# FM_HOME_CURRENCY_PROBE_BRANCH and returns 0, or sets
# FM_HOME_CURRENCY_PROBE_ERROR and returns 1.
fm_home_currency_probe() {  # <dir>
  local dir=$1 url out rc bound
  FM_HOME_CURRENCY_PROBE_SHA=""
  FM_HOME_CURRENCY_PROBE_BRANCH=""
  FM_HOME_CURRENCY_PROBE_ERROR=""

  url=$(git -C "$dir" remote get-url origin 2>/dev/null || true)
  if [ -z "$url" ]; then
    FM_HOME_CURRENCY_PROBE_ERROR="it has no origin remote, so there is no fleet version to compare it against"
    return 1
  fi
  fm_home_currency_cache_lookup "$url" && return 0
  [ -z "$FM_HOME_CURRENCY_PROBE_ERROR" ] || return 1

  bound=$(fm_home_currency_timeout)
  # GIT_TERMINAL_PROMPT and ssh BatchMode keep an unauthenticated remote a fast
  # failure instead of a session start blocked on a credential prompt. An
  # operator's own GIT_SSH_COMMAND is preserved when they set one.
  out=$(fm_run_timed "$bound" env \
    GIT_TERMINAL_PROMPT=0 \
    GIT_SSH_COMMAND="${GIT_SSH_COMMAND:-ssh -o BatchMode=yes}" \
    git -C "$dir" ls-remote --symref origin HEAD 2>&1)
  rc=$?
  if [ "$rc" -eq 124 ]; then
    FM_HOME_CURRENCY_PROBE_ERROR="the origin probe hit its ${bound}s bound, so origin's current commit is unknown"
  elif [ "$rc" -ne 0 ]; then
    FM_HOME_CURRENCY_PROBE_ERROR="origin could not be read: $(fm_home_currency_sanitize "$out")"
  else
    FM_HOME_CURRENCY_PROBE_BRANCH=$(printf '%s\n' "$out" \
      | sed -n 's|^ref: refs/heads/\([^[:space:]]*\)[[:space:]].*|\1|p' | head -n 1)
    FM_HOME_CURRENCY_PROBE_SHA=$(printf '%s\n' "$out" \
      | sed -n 's/^\([0-9a-f]\{7,40\}\)[[:space:]].*$/\1/p' | head -n 1)
    [ -n "$FM_HOME_CURRENCY_PROBE_SHA" ] \
      || FM_HOME_CURRENCY_PROBE_ERROR="origin advertised no default branch commit"
  fi
  fm_home_currency_cache_store "$url"
  [ -z "$FM_HOME_CURRENCY_PROBE_ERROR" ]
}

# --- evaluation -------------------------------------------------------------
#
# FM_HOME_CURRENCY_STATUS is one of:
#   current   HEAD is exactly origin's default-branch tip
#   behind    HEAD is an ancestor of that tip; BEHIND carries the distance
#   ahead     that tip is an ancestor of HEAD; AHEAD carries the distance
#   diverged  neither contains the other; AHEAD and BEHIND carry both distances
#   differs   HEAD is not that tip and the tip is not in this object store, so
#             the exact distance cannot be measured without fetching. BEHIND
#             then carries a LOWER BOUND when the last-fetched
#             refs/remotes/origin/<branch> still contains HEAD - which is the
#             ordinary shape of a home that has not updated in a long time - and
#             is empty when even that is unavailable
#   unknown   the comparison could not be made at all; REASON says why

FM_HOME_CURRENCY_STATUS=""
FM_HOME_CURRENCY_BRANCH=""
FM_HOME_CURRENCY_BEHIND=""
FM_HOME_CURRENCY_AHEAD=""
FM_HOME_CURRENCY_LOCAL=""
FM_HOME_CURRENCY_REMOTE=""
FM_HOME_CURRENCY_REASON=""

fm_home_currency_evaluate() {  # <dir>
  local dir=$1 head remote branch bound
  FM_HOME_CURRENCY_STATUS=unknown
  FM_HOME_CURRENCY_BRANCH=""
  FM_HOME_CURRENCY_BEHIND=""
  FM_HOME_CURRENCY_AHEAD=""
  FM_HOME_CURRENCY_LOCAL=""
  FM_HOME_CURRENCY_REMOTE=""
  FM_HOME_CURRENCY_REASON=""

  if [ -z "$dir" ] || [ ! -d "$dir" ]; then
    FM_HOME_CURRENCY_REASON="its recorded directory does not exist"
    return 0
  fi
  if ! git -C "$dir" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    FM_HOME_CURRENCY_REASON="it is not a git checkout, so it carries no fleet version"
    return 0
  fi
  head=$(git -C "$dir" rev-parse HEAD 2>/dev/null || true)
  if [ -z "$head" ]; then
    FM_HOME_CURRENCY_REASON="its HEAD commit cannot be read"
    return 0
  fi
  FM_HOME_CURRENCY_LOCAL=$(git -C "$dir" rev-parse --short HEAD 2>/dev/null || printf '%.7s' "$head")

  if ! fm_home_currency_probe "$dir"; then
    FM_HOME_CURRENCY_REASON=$FM_HOME_CURRENCY_PROBE_ERROR
    return 0
  fi
  remote=$FM_HOME_CURRENCY_PROBE_SHA
  branch=$FM_HOME_CURRENCY_PROBE_BRANCH
  [ -n "$branch" ] || branch=$(fm_default_branch "$dir" 2>/dev/null || true)
  [ -n "$branch" ] || branch=HEAD
  FM_HOME_CURRENCY_BRANCH=$branch
  FM_HOME_CURRENCY_REMOTE=$(printf '%.7s' "$remote")

  if [ "$head" = "$remote" ]; then
    FM_HOME_CURRENCY_STATUS=current
    return 0
  fi
  if ! git -C "$dir" cat-file -e "${remote}^{commit}" 2>/dev/null; then
    # The home has never fetched this far, so the exact distance is unavailable
    # without a fetch this check will not perform. The last-fetched
    # remote-tracking ref still gives a truthful LOWER bound whenever it
    # contains HEAD, which beats reporting no number at all for the very case
    # this check exists to catch.
    FM_HOME_CURRENCY_STATUS=differs
    bound=""
    if git -C "$dir" rev-parse --verify --quiet "refs/remotes/origin/$branch^{commit}" >/dev/null 2>&1 \
      && git -C "$dir" merge-base --is-ancestor "$head" "refs/remotes/origin/$branch" 2>/dev/null; then
      bound=$(git -C "$dir" rev-list --count "$head..refs/remotes/origin/$branch" 2>/dev/null || true)
    fi
    # A bound of zero is no bound at all - the stale ref simply agrees with HEAD -
    # so it must not be dressed up as "at least 0 commits behind".
    case "$bound" in
      ''|0|*[!0-9]*) ;;
      *) FM_HOME_CURRENCY_BEHIND=$bound ;;
    esac
    return 0
  fi
  if git -C "$dir" merge-base --is-ancestor "$head" "$remote" 2>/dev/null; then
    FM_HOME_CURRENCY_STATUS=behind
    FM_HOME_CURRENCY_BEHIND=$(git -C "$dir" rev-list --count "$head..$remote" 2>/dev/null || true)
    return 0
  fi
  if git -C "$dir" merge-base --is-ancestor "$remote" "$head" 2>/dev/null; then
    FM_HOME_CURRENCY_STATUS=ahead
    FM_HOME_CURRENCY_AHEAD=$(git -C "$dir" rev-list --count "$remote..$head" 2>/dev/null || true)
    return 0
  fi
  FM_HOME_CURRENCY_STATUS=diverged
  FM_HOME_CURRENCY_AHEAD=$(git -C "$dir" rev-list --count "$remote..$head" 2>/dev/null || true)
  FM_HOME_CURRENCY_BEHIND=$(git -C "$dir" rev-list --count "$head..$remote" 2>/dev/null || true)
  return 0
}

# Render a commit distance as text. A count that could not be measured degrades
# to a phrase rather than to a number the reader would trust.
fm_home_currency_count() {  # <value>
  case "$1" in
    ''|*[!0-9]*) printf 'an unknown number of commits' ;;
    1) printf '1 commit' ;;
    *) printf '%s commits' "$1" ;;
  esac
}

# Evaluate one home and print its single actionable HOME_CURRENCY: line, or
# nothing at all when it is exactly at the fleet's current commit. <subject> is
# the noun the line opens with: "this home", or "secondmate <id>".
fm_home_currency_report() {  # <subject> <dir>
  local subject=$1 dir=$2
  fm_home_currency_evaluate "$dir"
  case "$FM_HOME_CURRENCY_STATUS" in
    current)
      return 0
      ;;
    behind)
      printf 'HOME_CURRENCY: %s is %s behind origin/%s (local %s, origin %s) - it is running older instructions, skills and scripts than the fleet, so its own version floors and checks are that older copy too; nothing here updated it, /updatefirstmate does that\n' \
        "$subject" "$(fm_home_currency_count "$FM_HOME_CURRENCY_BEHIND")" \
        "$FM_HOME_CURRENCY_BRANCH" "$FM_HOME_CURRENCY_LOCAL" "$FM_HOME_CURRENCY_REMOTE"
      ;;
    differs)
      case "$FM_HOME_CURRENCY_BEHIND" in
        ''|*[!0-9]*)
          printf 'HOME_CURRENCY: %s is not at origin/%s (local %s, origin %s) and that origin commit is absent from its object store, so the distance cannot be measured without a fetch this check will not perform - treat it as not matching the fleet; nothing here updated it, /updatefirstmate does that\n' \
            "$subject" "$FM_HOME_CURRENCY_BRANCH" "$FM_HOME_CURRENCY_LOCAL" "$FM_HOME_CURRENCY_REMOTE"
          ;;
        *)
          printf 'HOME_CURRENCY: %s is at least %s behind origin/%s (local %s, origin %s) - that origin commit is absent from its object store, so the exact distance needs a fetch this check will not perform; it is running older instructions, skills and scripts than the fleet, so its own version floors and checks are that older copy too; nothing here updated it, /updatefirstmate does that\n' \
            "$subject" "$(fm_home_currency_count "$FM_HOME_CURRENCY_BEHIND")" \
            "$FM_HOME_CURRENCY_BRANCH" "$FM_HOME_CURRENCY_LOCAL" "$FM_HOME_CURRENCY_REMOTE"
          ;;
      esac
      ;;
    ahead)
      printf 'HOME_CURRENCY: %s is %s ahead of origin/%s (local %s, origin %s) - it is running instructions, skills and scripts the fleet does not have; nothing here changed it\n' \
        "$subject" "$(fm_home_currency_count "$FM_HOME_CURRENCY_AHEAD")" \
        "$FM_HOME_CURRENCY_BRANCH" "$FM_HOME_CURRENCY_LOCAL" "$FM_HOME_CURRENCY_REMOTE"
      ;;
    diverged)
      printf 'HOME_CURRENCY: %s has diverged from origin/%s (%s ahead, %s behind; local %s, origin %s) - it is running instructions, skills and scripts that do not match the fleet; nothing here changed it\n' \
        "$subject" "$FM_HOME_CURRENCY_BRANCH" \
        "$(fm_home_currency_count "$FM_HOME_CURRENCY_AHEAD")" \
        "$(fm_home_currency_count "$FM_HOME_CURRENCY_BEHIND")" \
        "$FM_HOME_CURRENCY_LOCAL" "$FM_HOME_CURRENCY_REMOTE"
      ;;
    *)
      printf 'HOME_CURRENCY: cannot verify %s against origin - %s; its instructions, skills and scripts are UNVERIFIED against the fleet, which is not the same as confirmed current\n' \
        "$subject" "${FM_HOME_CURRENCY_REASON:-no reason was recorded}"
      ;;
  esac
  return 0
}
