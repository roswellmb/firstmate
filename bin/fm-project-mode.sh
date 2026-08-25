#!/usr/bin/env bash
# Resolve a project's REGISTERED delivery posture from the data/projects.md registry.
# Prints two words to stdout: "<mode> <yolo>" where mode is one of
# no-mistakes|direct-PR|local-only and yolo is on|off.
#
# MECHANICAL CONSUMERS ONLY. This answers "what posture did the captain register
# for this project", never "how does this task ship". A task's delivery mode and
# yolo are resolved by firstmate at intake and passed explicitly to
# bin/fm-brief.sh, bin/fm-spawn.sh, and bin/fm-promote.sh (AGENTS.md section 7).
# The consumers are bin/fm-fleet-sync.sh (skip local-only clones),
# bin/fm-home-seed.sh (refuse local-only seeding, run no-mistakes init), and
# bin/fm-spawn.sh's advisory registry-deviation notice.
#
# Registry line format (data/projects.md):
#   - <name> - <desc> (added <date>)                  -> no-mistakes off  (legacy default)
#   - <name> [<mode>] - <desc> (added <date>)          -> <mode> off
#   - <name> [<mode> +yolo] - <desc> (added <date>)    -> <mode> on
#
# Registered modes:
#   no-mistakes            full pipeline -> PR -> configured merge authority (default)
#   direct-PR              push + PR via gh-axi, no pipeline
#   local-only             local branch, no remote/PR, guarded local merge
#   no-mistakes-prod-only  a conditional policy, not a task mode: firstmate
#                          classifies each task's surface at intake (the
#                          project-management skill owns that classification).
#                          Mechanical output maps it to its most rigorous leg,
#                          no-mistakes, so sync, seeding, and init treat such a
#                          project as the remote-backed pipeline project it is.
# yolo (orthogonal) = when on, firstmate may make routine approval decisions itself.
#   AGENTS.md section 7 is the single owner of authority exceptions, including
#   ask-user contract expansion and stronger captain boundaries.
#
# --raw prints the registered annotation unmapped, so a caller that must tell a
# conditional policy apart from a flat mode sees "no-mistakes-prod-only" itself.
#
# An unknown/missing project or unknown mode falls back to "no-mistakes off" and warns
# to stderr, so a typo never silently drops the gate.
#
# --mark <project-name> answers a DIFFERENT question, from a DIFFERENT file:
# "has the captain marked this project as one firstmate must not quietly start
# work on".
# Marks live in config/project-marks, NOT on a registry line, because a mark has
# to bind every home in the fleet. config/ is the primary-authoritative
# inheritance channel (bin/fm-config-inherit-lib.sh's FM_INHERITABLE_CONFIG), so
# a mark set in the primary home is pushed into every local and remote secondmate
# home and re-pushed on every convergence; data/projects.md is per-home,
# gitignored, and propagates nowhere, so a mark written there would bind only the
# home that set it.
#
# config/project-marks format, one mark per line (blank lines and #-comments are
# ignored):
#   <project-name> <kind> <YYYY-MM-DD> <reason to end of line>
# Kinds:
#   excluded            an AUTHORITY state. The captain decided it, the block is
#                       total, and only the captain lifts it by removing the
#                       line. No condition, observation, or elapsed time clears
#                       it, and firstmate never sets or clears one on its own.
#   blocked-on-captain  a FEASIBILITY state. The work cannot succeed until
#                       something the captain owes arrives. The block is
#                       partial: work that does not depend on that input may
#                       proceed on an explicit, stated acknowledgement
#                       (bin/fm-spawn.sh's --despite-block). It clears when the
#                       named condition is met, and firstmate may observe that.
# Two marks for the same project resolve to the stricter one (excluded wins).
#
# --mark output contract:
#   exit 0, no stdout                        not marked
#   exit 0, "<kind> <YYYY-MM-DD> <reason>"   marked
#   exit 2, stderr diagnostic                the marks file cannot be parsed
# A caller MUST refuse on a non-empty mark and on exit 2. Exit 2 is deliberately
# fleet-wide rather than per-project: a marks file that cannot be parsed may be
# hiding an exclusion, and a mark that silently fails open is worse than no mark,
# because it reads as protection.
#
# Usage: fm-project-mode.sh [--raw] <project-name>
#        fm-project-mode.sh --mark <project-name>
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
REG="$DATA/projects.md"
MARKS="$CONFIG/project-marks"
RAW=0
MARK=0
case "${1:-}" in
  --raw) RAW=1; shift ;;
  --mark) MARK=1; shift ;;
esac
NAME=${1:?usage: fm-project-mode.sh [--raw|--mark] <project-name>}

# --mark: read the inherited marks file and print this project's mark, if any.
# Kept in this script so the captain's registered posture for a project - its
# delivery mode, its yolo, and whether firstmate may work it at all - has exactly
# one parser. See the header for the file format and the output contract.
if [ "$MARK" -eq 1 ]; then
  [ -f "$MARKS" ] || exit 0
  # awk validates EVERY line before answering about any of them: a file with one
  # unparseable line may be hiding an exclusion, so it refuses wholesale rather
  # than answering "not marked" from the lines it happened to understand.
  if ! found=$(awk -v want="$NAME" '
    function bad(msg) { printf "fm-project-mode: %s at %s:%d: %s\n", msg, FILENAME, FNR, $0 > "/dev/stderr"; broken = 1 }
    { sub(/\r$/, "") }
    /^[[:space:]]*(#|$)/ { next }
    {
      if (NF < 4) { bad("mark needs <project> <kind> <YYYY-MM-DD> <reason>"); next }
      kind = $2
      if (kind != "excluded" && kind != "blocked-on-captain") { bad("unknown mark kind \"" kind "\"") ; next }
      if ($3 !~ /^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]$/) { bad("mark date must be YYYY-MM-DD") ; next }
      reason = $0
      sub(/^[[:space:]]*[^[:space:]]+[[:space:]]+[^[:space:]]+[[:space:]]+[^[:space:]]+[[:space:]]+/, "", reason)
      if (reason ~ /^[[:space:]]*$/) { bad("mark carries no reason") ; next }
      if ($1 != want) next
      # Stricter wins, so an excluded line can never be masked by a
      # blocked-on-captain line for the same project, whatever their order.
      if (kind == "excluded" || hit == "") hit = kind " " $3 " " reason
    }
    END { if (broken) exit 2; if (hit != "") print hit }
  ' "$MARKS"); then
    echo "fm-project-mode: refusing to answer about \"$NAME\": $MARKS is unparseable (see above); a marks file that cannot be read may be hiding an exclusion" >&2
    exit 2
  fi
  [ -z "$found" ] || printf '%s\n' "$found"
  exit 0
fi

if [ ! -f "$REG" ]; then
  echo "warn: no registry at $REG; defaulting $NAME to no-mistakes off" >&2
  echo "no-mistakes off"
  exit 0
fi

# awk emits "<mode> <yolo>" (one line) or nothing if the project is absent.
parsed=$(awk -v n="$NAME" '
  $1=="-" && $2==n {
    mode="no-mistakes"; yolo="off";
    if ($3 ~ /^\[/) {
      s="";
      for (i=3; i<=NF; i++) { s = s (s==""?"":" ") $i; if ($i ~ /\]$/) break }
      gsub(/^\[|\]$/, "", s);           # strip the surrounding brackets
      k = split(s, a, " ");
      if (a[1] != "" && a[1] != "+yolo") mode = a[1];
      for (j=1; j<=k; j++) if (a[j]=="+yolo") yolo="on";
    }
    print mode, yolo; exit
  }
' "$REG")

if [ -z "$parsed" ]; then
  echo "warn: project \"$NAME\" not in registry; defaulting to no-mistakes off" >&2
  echo "no-mistakes off"
  exit 0
fi

mode=${parsed%% *}
yolo=${parsed##* }
case "$mode" in
  no-mistakes|direct-PR|local-only|no-mistakes-prod-only) ;;
  *) echo "warn: unknown mode \"$mode\" for $NAME; defaulting to no-mistakes off" >&2; mode=no-mistakes; yolo=off ;;
esac
case "$yolo" in on|off) ;; *) yolo=off ;; esac
# A conditional policy is not a task mode. Mechanical callers get its most
# rigorous leg; --raw callers get the annotation itself (see the header).
if [ "$RAW" -eq 0 ] && [ "$mode" = no-mistakes-prod-only ]; then
  mode=no-mistakes
fi
echo "$mode $yolo"
