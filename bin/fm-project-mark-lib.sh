#!/usr/bin/env bash
# fm-project-mark-lib.sh - the shared POLICY for captain project marks: given a
# project and whatever acknowledgement the caller holds, decide whether work may
# start there.
#
# bin/fm-project-mode.sh --mark stays the single READER and the single owner of
# the config/project-marks schema; this library never opens that file. What it
# owns is the one step above reading: which kind of mark refuses, which one an
# explicit acknowledgement may carry work past, and what an unreadable marks file
# means. That policy has two callers and they must never disagree:
#
#   bin/fm-spawn.sh    the enforcement point where work actually starts - a ship
#                      spawn, a scout spawn, or a relaunch - and the backstop
#                      that refuses however the spawn was reached.
#   bin/fm-control.sh  the relaunch PREFLIGHT, which asks the same question
#                      BEFORE it stops the running agent. A mark exists to stop
#                      new work; a refusal that first tore down the work it is
#                      refusing to restart would do the opposite.
#
# The two kinds differ in who may clear them, and the policy encodes exactly that
# difference:
#   excluded            an AUTHORITY state. Total, and liftable only by the
#                       captain removing the line. No acknowledgement any caller
#                       can pass itself may carry work past it - a flag firstmate
#                       hands itself would make the strongest mark advisory.
#   blocked-on-captain  a FEASIBILITY state. Partial: work that genuinely does
#                       not depend on the named input may proceed on an explicit
#                       STATED reason, which the caller records durably so the
#                       answer outlives the conversation that gave it.
#
# Callers render their own refusals, because their next action differs: a spawn
# has created nothing yet, while a relaunch has a live agent and a worktree full
# of work to account for. The verdict they render from is decided here.
#
# fm_project_mark_decide <project-name> [<stated-reason>] [<recorded-reason>]
#   Returns 0 when work may proceed, 1 when the caller MUST refuse, and sets:
#     FM_PROJECT_MARK_VERDICT  one of
#       unmarked                no mark; proceed
#       acknowledged            blocked-on-captain, carried by <stated-reason>
#       recorded                blocked-on-captain, carried by the reason the
#                               task already recorded when it launched
#       excluded                refuse; only the captain lifts it
#       blocked                 refuse; blocked-on-captain with no acknowledgement
#       stray-acknowledgement   refuse; an acknowledgement was offered for a
#                               project that carries no mark, so it grants
#                               nothing and must not be carried habitually
#       unknown-kind            refuse; the reader reported a kind this policy
#                               does not know
#       unreadable              refuse; the marks file could not be read at all
#     FM_PROJECT_MARK_KIND     the mark's kind, empty when unmarked/unreadable
#     FM_PROJECT_MARK_DATE     the date the mark was set, same emptiness rule
#     FM_PROJECT_MARK_REASON   the captain's stated reason, same emptiness rule
#     FM_PROJECT_MARK_ACK      the acknowledgement that carried the work, for the
#                               acknowledged/recorded verdicts only
#
# An unreadable marks file refuses rather than reading as "not marked": a marks
# file nobody can parse may be hiding an exclusion, and a mark that silently
# fails open is worse than no mark because it reads as protection.

_FM_PROJECT_MARK_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd 2>/dev/null)" || _FM_PROJECT_MARK_LIB_DIR="."

FM_PROJECT_MARK_VERDICT=
FM_PROJECT_MARK_KIND=
FM_PROJECT_MARK_DATE=
FM_PROJECT_MARK_REASON=
FM_PROJECT_MARK_ACK=

# shellcheck disable=SC2034 # FM_PROJECT_MARK_* are this library's published outputs, read by its callers.
fm_project_mark_decide() {  # <project-name> [<stated-reason>] [<recorded-reason>]
  local name=$1 stated=${2:-} recorded=${3:-} mark rest status=0
  FM_PROJECT_MARK_VERDICT=
  FM_PROJECT_MARK_KIND=
  FM_PROJECT_MARK_DATE=
  FM_PROJECT_MARK_REASON=
  FM_PROJECT_MARK_ACK=
  mark=$("$_FM_PROJECT_MARK_LIB_DIR/fm-project-mode.sh" --mark "$name") || status=$?
  if [ "$status" -ne 0 ]; then
    FM_PROJECT_MARK_VERDICT=unreadable
    return 1
  fi
  if [ -z "$mark" ]; then
    if [ -n "$stated" ]; then
      FM_PROJECT_MARK_VERDICT=stray-acknowledgement
      return 1
    fi
    FM_PROJECT_MARK_VERDICT=unmarked
    return 0
  fi
  FM_PROJECT_MARK_KIND=${mark%% *}
  rest=${mark#* }
  FM_PROJECT_MARK_DATE=${rest%% *}
  FM_PROJECT_MARK_REASON=${rest#* }
  case "$FM_PROJECT_MARK_KIND" in
    excluded)
      FM_PROJECT_MARK_VERDICT=excluded
      return 1
      ;;
    blocked-on-captain)
      if [ -n "$stated" ]; then
        FM_PROJECT_MARK_VERDICT=acknowledged
        FM_PROJECT_MARK_ACK=$stated
        return 0
      fi
      if [ -n "$recorded" ]; then
        FM_PROJECT_MARK_VERDICT=recorded
        FM_PROJECT_MARK_ACK=$recorded
        return 0
      fi
      FM_PROJECT_MARK_VERDICT=blocked
      return 1
      ;;
    *)
      # Unreachable while this policy and the reader agree on the kind set; kept
      # so a kind added there refuses here instead of falling through unchecked.
      FM_PROJECT_MARK_VERDICT=unknown-kind
      return 1
      ;;
  esac
}
