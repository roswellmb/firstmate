# Watcher lock budget verification

Audience: maintainer verification.

This record supports the split between `FM_LOCK_WAIT_TIMEOUT` (the global ceiling, sized for locks with deliberate long holds) and `FM_WATCH_LOCK_WAIT_TIMEOUT` (the watcher process's own budget).
The operative constraint and its bounds live beside the definitions in `bin/fm-wake-lib.sh` and in `docs/configuration.md`; this file records only what was measured.

## Beacon age under a wedged wake-queue lock

Measured on 2026-08-21 at stock defaults (`FM_POLL=15`, `FM_INACTIVE_RECONCILE_BUDGET_SECS=10`, `FM_CHECK_TIMEOUT=30`, `FM_WATCH_LOCK_WAIT_TIMEOUT=30`, `FM_GUARD_GRACE=300`).

Method: start a real watcher, wait for its first beacon, then wedge `state/.wake-queue.lock` with a live holder pid and append a key to `state/.wake-queue` so both contended waits in the poll cycle are reachable.
Sample the beacon's age once per second for the run and keep the maximum.

```sh
# harness: /tmp/beacon-age-measure.sh <repo-root> <N> <seconds>
for n in 0 1 2; do bash /tmp/beacon-age-measure.sh "$PWD" "$n" $((200 + n*60)); done
```

Observed:

```
N=0 max_beacon_age=76s observed_over=200s watcher_alive=yes guard_grace=300
N=1 max_beacon_age=77s observed_over=260s watcher_alive=yes guard_grace=300
N=2 max_beacon_age=77s observed_over=320s watcher_alive=yes guard_grace=300
```

The watcher survived the wedge in all three runs and its beacon never left the 300s guard grace.

Limitation, stated because the numbers invite the wrong reading: N=1 and N=2 placed one and two `state/*.check.sh` files, but their ages are indistinguishable from N=0, so the check sweep did not spend `FM_CHECK_TIMEOUT` on them.
These runs therefore verify the contended-wait and cycle-tail terms only.
The `FM_CHECK_TIMEOUT*N` term of the documented constraint remains an analytic bound that this measurement does not exercise, and the unbounded-N caveat recorded at the definition site is unaffected.

## Coverage boundary

The watcher sets a private, never-exported `_FM_LOCK_WAIT_BUDGET` that `fm_lock_acquire_wait` reads in preference to `FM_LOCK_WAIT_TIMEOUT`, so the boundary is process membership rather than a list of call sites.

In-process, and therefore covered: `procevent_surface_queued`'s wake-queue acquire; `fm_recovery_marker_arm_check` at startup and in `resurface_after_downtime`; `fm_recovery_marker_snapshot`; `fm_recovery_transition` in the `watcher_cleanup` EXIT trap; all eleven `fm_wake_append` call sites; and the locks taken by libraries sourced into the watcher shell, which are `fm-pending-reply-lib.sh` and `fm-x-lib.sh` (three acquire sites each; the other sourced libraries take none).

Subprocesses keep the global ceiling: `fm-pr-check-migrate.sh`, `fm-procevent.sh reconcile`, `fm-inactive-reconcile.sh scan`, `fm-dispatch-poll.sh scan`, `fm-x-poll.sh` and `fm-pr-poll.sh` via `run_check_capture`, every registered `*.check.sh`, and `fm-crew-state.sh`.
No claim is made that these are covered by the watcher budget.

Re-verified on 2026-08-21 after the mechanism changed from overwriting `FM_LOCK_WAIT_TIMEOUT` to reading a private variable.
Both directions of the property were checked:

```
operator exported nothing:            in-process budget=30  subprocess FM_LOCK_WAIT_TIMEOUT=<unset>
operator exported FM_LOCK_WAIT_TIMEOUT=555: in-process budget=30  subprocess FM_LOCK_WAIT_TIMEOUT=555
                                           subprocess _FM_LOCK_WAIT_BUDGET=<unset>
```

The watcher's own waits use the watcher budget in both cases, and an operator's exported global now reaches the watcher's subprocesses unchanged.

This supersedes an earlier record on this branch which stated the opposite - that an operator exporting a tuned global lost it for the watcher's subprocesses.
That was accurate for the `export -n` mechanism it described and is no longer accurate for the current one.

A malformed override does not disable the ceiling.
The empty/zero/non-numeric fallback is applied to the resolved value, so `_FM_LOCK_WAIT_BUDGET` set to empty, `abc`, or `0` all yield the documented 300 default rather than an unbounded wait.
