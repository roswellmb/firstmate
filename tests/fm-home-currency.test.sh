#!/usr/bin/env bash
# Behavior tests for the home-currency check: does a firstmate home report that
# it is running instructions, skills, and scripts that no longer match the fleet?
#
# The check has one job and one anti-job. Its job is to say, out loud and at
# session start, that this home is not at its origin default-branch commit. Its
# anti-job is to change anything: updating a home belongs to /updatefirstmate,
# and a home that fast-forwarded itself under a live validation run would be a
# worse failure than a stale one. Both are pinned here.
#
# Every case asserts the POSITIVE reported line, not merely the absence of a
# wrong one - a test that asserts only absence passes on empty output, which
# means it passes when the check never ran. The two cases that legitimately
# expect silence (a current home, and the suppressed suite mode) therefore also
# assert an independent positive control from the same run, so silence is proved
# to be a verdict rather than a check that did not execute.
#
# All origins are local bare repos reached over file://, so the whole suite runs
# with no external network and no forge credentials.
set -u

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

BASE_PATH=${FM_TEST_BASE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}
TMP_ROOT=$(fm_test_tmproot fm-home-currency-tests)
fm_git_identity

# Ambient runtime markers must not leak into the backend resolution bin/fm-bootstrap.sh
# performs at load time - the same hermeticity discipline as pinning PATH.
unset TMUX TMUX_PANE HERDR_ENV HERDR_PANE_ID HERDR_SESSION HERDR_SOCKET_PATH \
  CMUX_WORKSPACE_ID CMUX_SURFACE_ID CMUX_SOCKET_PATH CMUX_TAB_ID CMUX_PANEL_ID 2>/dev/null || true

LIB="$ROOT/bin/fm-home-currency-lib.sh"

# --- fixtures ---------------------------------------------------------------

# make_fleet <dir> <commits>: a bare origin plus a checkout on main carrying
# <commits> commits, both current with each other. Echoes "<checkout> <origin>".
make_fleet() {
  local dir=$1 commits=$2 i
  mkdir -p "$dir"
  git init -q --bare "$dir/origin.git"
  git -C "$dir/origin.git" symbolic-ref HEAD refs/heads/main
  git init -q "$dir/home"
  git -C "$dir/home" checkout -q -b main
  git -C "$dir/home" remote add origin "file://$(cd "$dir/origin.git" && pwd)"
  i=1
  while [ "$i" -le "$commits" ]; do
    printf 'commit %s\n' "$i" > "$dir/home/AGENTS.md"
    git -C "$dir/home" add AGENTS.md
    git -C "$dir/home" commit -qm "commit $i"
    i=$((i + 1))
  done
  git -C "$dir/home" push -q origin main
  printf '%s %s\n' "$dir/home" "$dir/origin.git"
}

# advance_origin <dir> <n>: push <n> further commits to the fleet's origin from
# a separate clone, so the home under test is left behind without being touched.
advance_origin() {
  local dir=$1 n=$2 i
  rm -rf "$dir/pusher"
  git clone -q "$dir/origin.git" "$dir/pusher"
  git -C "$dir/pusher" checkout -q main
  i=1
  while [ "$i" -le "$n" ]; do
    printf 'upstream %s\n' "$i" > "$dir/pusher/AGENTS.md"
    git -C "$dir/pusher" add AGENTS.md
    git -C "$dir/pusher" commit -qm "upstream $i"
    i=$((i + 1))
  done
  git -C "$dir/pusher" push -q origin main
}

# A content fingerprint of a checkout and of the object store it shares: HEAD,
# every ref, the object counts, and a checksum of every file in both the git
# directory and the working tree. A fetch, a fast-forward, a checkout, or a
# stray FETCH_HEAD all change this; a pure read cannot.
fingerprint() {
  local dir=$1 gitdir
  gitdir=$(git -C "$dir" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)
  git -C "$dir" rev-parse HEAD 2>/dev/null
  git -C "$dir" show-ref 2>/dev/null | LC_ALL=C sort
  git -C "$dir" count-objects -v 2>/dev/null
  ( cd "$gitdir" && find . -type f ! -name 'index' ! -name '*.lock' -exec cksum {} \; ) | LC_ALL=C sort
  ( cd "$dir" && find . -path ./.git -prune -o -type f -exec cksum {} \; ) | LC_ALL=C sort
}

# A PATH shim carrying only what bin/fm-bootstrap.sh's network phase touches.
# `gh auth status` is the positive control for "the network phase ran": it fails
# here on purpose, so NEEDS_GH_AUTH proves execution even in the cases where the
# currency check is correctly silent.
make_probe_bin() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/gh" <<'SH'
#!/usr/bin/env bash
exit 1
SH
  chmod +x "$fakebin/gh"
  printf '%s\n' "$fakebin"
}

# One bin/fm-bootstrap.sh network-phase run for <home>, with the suite's
# hermeticity suppression lifted so the real check executes.
boot_network() {
  local home=$1 fakebin=$2
  PATH="$fakebin:$BASE_PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$home" \
    FM_HOME_CURRENCY_TEST_SKIP=0 FM_BOOTSTRAP_NETWORK=only FM_BOOTSTRAP_DETECT_ONLY=1 \
    "$ROOT/bin/fm-bootstrap.sh" 2>&1
}

# --- 1. a current home is silent, and that silence is a verdict -------------
(
  read -r home _origin <<EOF
$(make_fleet "$TMP_ROOT/current" 3)
EOF
  # shellcheck source=bin/fm-home-currency-lib.sh disable=SC1091
  . "$LIB"
  out=$(fm_home_currency_report 'this home' "$home")
  fm_home_currency_evaluate "$home"
  [ "$FM_HOME_CURRENCY_STATUS" = current ] \
    || fail "a home at origin's tip was classified $FM_HOME_CURRENCY_STATUS, not current"
  [ "$FM_HOME_CURRENCY_BRANCH" = main ] \
    || fail "the origin default branch resolved to '$FM_HOME_CURRENCY_BRANCH', not main"
  [ -z "$out" ] || fail "a current home printed a line: $out"
  pass "home currency: a home at origin's default-branch tip reports current and prints nothing"
)

# --- 2. behind, with the origin commits already in the object store ---------
(
  dir="$TMP_ROOT/behind"
  read -r home _origin <<EOF
$(make_fleet "$dir" 2)
EOF
  advance_origin "$dir" 8
  git -C "$home" fetch -q origin
  # shellcheck source=bin/fm-home-currency-lib.sh disable=SC1091
  . "$LIB"
  out=$(fm_home_currency_report 'this home' "$home")
  assert_contains "$out" "HOME_CURRENCY: this home is 8 commits behind origin/main" \
    "a home eight commits behind origin did not name the distance"
  assert_contains "$out" "older instructions, skills and scripts than the fleet" \
    "the behind line did not say what being behind costs"
  assert_contains "$out" "/updatefirstmate" \
    "the behind line did not point at the path that actually updates a home"
  pass "home currency: a home behind origin reports exactly how far behind it is"
)

# --- 3. behind, with the origin commit absent from the object store ---------
#
# The home has never fetched, so the distance cannot be counted. That must read
# as "does not match the fleet", never as a pass.
(
  dir="$TMP_ROOT/unfetched"
  read -r home _origin <<EOF
$(make_fleet "$dir" 2)
EOF
  advance_origin "$dir" 4
  # shellcheck source=bin/fm-home-currency-lib.sh disable=SC1091
  . "$LIB"
  out=$(fm_home_currency_report 'this home' "$home")
  fm_home_currency_evaluate "$home"
  [ "$FM_HOME_CURRENCY_STATUS" = differs ] \
    || fail "an unfetched home behind origin was classified $FM_HOME_CURRENCY_STATUS"
  assert_contains "$out" "is not at origin/main" \
    "an unfetched home behind origin did not report the mismatch"
  assert_contains "$out" "absent from its object store" \
    "the line did not say why the distance could not be measured"
  assert_contains "$out" "a fetch this check will not perform" \
    "the line did not say that the check declines to fetch rather than cannot"
  assert_contains "$out" "treat it as not matching the fleet" \
    "an unmeasurable distance was not resolved against the fleet"
  pass "home currency: a home that cannot measure its distance still reports not matching the fleet"
)

# --- 3b. a stale home that fetched long ago still gets a truthful number ----
#
# This is the ordinary shape of a home that has not updated in months: its
# remote-tracking ref is old, and origin has moved on past it. The exact
# distance needs a fetch, but the old ref bounds it from below, which is far
# more use than no number at all.
(
  dir="$TMP_ROOT/lower-bound"
  read -r home _origin <<EOF
$(make_fleet "$dir" 2)
EOF
  advance_origin "$dir" 3
  git -C "$home" fetch -q origin          # the last /updatefirstmate this home saw
  advance_origin "$dir" 4                 # ... and the fleet moved on since
  # shellcheck source=bin/fm-home-currency-lib.sh disable=SC1091
  . "$LIB"
  out=$(fm_home_currency_report 'this home' "$home")
  fm_home_currency_evaluate "$home"
  [ "$FM_HOME_CURRENCY_STATUS" = differs ] \
    || fail "a home behind an unfetched origin tip was classified $FM_HOME_CURRENCY_STATUS"
  assert_contains "$out" "HOME_CURRENCY: this home is at least 3 commits behind origin/main" \
    "the lower bound from the last-fetched ref was not reported"
  assert_contains "$out" "the exact distance needs a fetch this check will not perform" \
    "the line did not distinguish the bound from the exact distance"
  pass "home currency: a home whose origin moved past its last fetch reports a truthful lower bound"
)

# --- 4. a detached HEAD at origin's tip is current, not an error ------------
#
# Secondmate homes are leased detached on the default branch, so detachment must
# never be mistaken for a failed check.
(
  dir="$TMP_ROOT/detached"
  read -r home _origin <<EOF
$(make_fleet "$dir" 3)
EOF
  git -C "$home" checkout -q --detach HEAD
  # shellcheck source=bin/fm-home-currency-lib.sh disable=SC1091
  . "$LIB"
  out=$(fm_home_currency_report 'this home' "$home")
  fm_home_currency_evaluate "$home"
  [ -z "$(git -C "$home" symbolic-ref --quiet --short HEAD 2>/dev/null || true)" ] \
    || fail "the fixture was not actually detached, so this case proves nothing"
  [ "$FM_HOME_CURRENCY_STATUS" = current ] \
    || fail "a detached home at origin's tip was classified $FM_HOME_CURRENCY_STATUS, not current"
  [ -z "$out" ] || fail "a detached home at origin's tip printed a line: $out"
  pass "home currency: a detached HEAD at origin's tip is current, the way a leased secondmate home sits"
)

# --- 5. ahead ---------------------------------------------------------------
(
  dir="$TMP_ROOT/ahead"
  read -r home _origin <<EOF
$(make_fleet "$dir" 2)
EOF
  printf 'local only\n' > "$home/AGENTS.md"
  git -C "$home" add AGENTS.md
  git -C "$home" commit -qm "unlanded"
  # shellcheck source=bin/fm-home-currency-lib.sh disable=SC1091
  . "$LIB"
  out=$(fm_home_currency_report 'this home' "$home")
  assert_contains "$out" "HOME_CURRENCY: this home is 1 commit ahead of origin/main" \
    "a home ahead of origin did not name the distance"
  assert_contains "$out" "the fleet does not have" \
    "the ahead line did not say what running unlanded instructions means"
  pass "home currency: a home ahead of origin reports the instructions the fleet does not have"
)

# --- 6. diverged ------------------------------------------------------------
(
  dir="$TMP_ROOT/diverged"
  read -r home _origin <<EOF
$(make_fleet "$dir" 2)
EOF
  advance_origin "$dir" 2
  git -C "$home" fetch -q origin
  printf 'local divergence\n' > "$home/AGENTS.md"
  git -C "$home" add AGENTS.md
  git -C "$home" commit -qm "divergent"
  # shellcheck source=bin/fm-home-currency-lib.sh disable=SC1091
  . "$LIB"
  out=$(fm_home_currency_report 'this home' "$home")
  assert_contains "$out" "HOME_CURRENCY: this home has diverged from origin/main (1 commit ahead, 2 commits behind" \
    "a diverged home did not report both distances"
  pass "home currency: a diverged home reports both distances rather than picking one"
)

# --- 7-10. a check that cannot check never looks like a check that passed ---
(
  dir="$TMP_ROOT/unverifiable"
  read -r home _origin <<EOF
$(make_fleet "$dir" 1)
EOF
  # shellcheck source=bin/fm-home-currency-lib.sh disable=SC1091
  . "$LIB"

  git -C "$home" remote remove origin
  FM_HOME_CURRENCY_CACHE=""
  out=$(fm_home_currency_report 'this home' "$home")
  assert_contains "$out" "HOME_CURRENCY: cannot verify this home against origin" \
    "a home with no origin remote did not report an unverifiable check"
  assert_contains "$out" "no origin remote" "the reason did not name the missing remote"
  assert_contains "$out" "UNVERIFIED against the fleet, which is not the same as confirmed current" \
    "an unverifiable check did not distinguish itself from a pass"

  git -C "$home" remote add origin "file://$dir/absent-origin.git"
  FM_HOME_CURRENCY_CACHE=""
  out=$(fm_home_currency_report 'this home' "$home")
  assert_contains "$out" "HOME_CURRENCY: cannot verify this home against origin" \
    "an unreachable origin did not report an unverifiable check"
  assert_contains "$out" "origin could not be read" "the reason did not name the failed read"

  FM_HOME_CURRENCY_CACHE=""
  out=$(fm_home_currency_report 'secondmate ops' "$dir/pusher-that-never-existed")
  assert_contains "$out" "HOME_CURRENCY: cannot verify secondmate ops against origin" \
    "a missing home directory did not report an unverifiable check"
  assert_contains "$out" "does not exist" "the reason did not name the missing directory"

  mkdir -p "$dir/plain"
  FM_HOME_CURRENCY_CACHE=""
  out=$(fm_home_currency_report 'secondmate ops' "$dir/plain")
  assert_contains "$out" "HOME_CURRENCY: cannot verify secondmate ops against origin" \
    "a non-git home did not report an unverifiable check"
  assert_contains "$out" "not a git checkout" "the reason did not name the missing checkout"

  pass "home currency: no origin, an unreachable origin, a missing home, and a non-git home each report unverified, not current"
)

# --- 11. a credential in an origin URL never reaches the reported line ------
(
  dir="$TMP_ROOT/redaction"
  read -r home _origin <<EOF
$(make_fleet "$dir" 1)
EOF
  git -C "$home" remote set-url origin "https://fmtest:s3cr3t-token@127.0.0.1:1/firstmate.git"
  # shellcheck source=bin/fm-home-currency-lib.sh disable=SC1091
  . "$LIB"
  out=$(FM_HOME_CURRENCY_TIMEOUT=5 fm_home_currency_report 'this home' "$home")
  assert_contains "$out" "HOME_CURRENCY: cannot verify this home against origin" \
    "an unreachable authenticated origin did not report an unverifiable check"
  assert_not_contains "$out" "s3cr3t-token" "the reported line leaked the origin credential"
  pass "home currency: an origin credential is redacted out of the reported failure"
)

# --- 12. the check never mutates the home it reports on ---------------------
(
  dir="$TMP_ROOT/readonly-lib"
  read -r home _origin <<EOF
$(make_fleet "$dir" 2)
EOF
  advance_origin "$dir" 3
  git -C "$home" fetch -q origin
  before=$(fingerprint "$home")
  # shellcheck source=bin/fm-home-currency-lib.sh disable=SC1091
  . "$LIB"
  out=$(fm_home_currency_report 'this home' "$home")
  after=$(fingerprint "$home")
  assert_contains "$out" "is 3 commits behind origin/main" \
    "the non-mutation case did not actually exercise a reporting run"
  [ "$before" = "$after" ] || {
    printf '%s\n' "$before" > "$dir/before.txt"
    printf '%s\n' "$after" > "$dir/after.txt"
    fail "reporting on a stale home changed it:"$'\n'"$(diff "$dir/before.txt" "$dir/after.txt" || true)"
  }
  [ "$(git -C "$home" rev-list --count HEAD)" = 2 ] \
    || fail "the home advanced past the commits it had before the check"
  pass "home currency: reporting a stale home leaves its refs, objects, and working tree byte-identical"
)

# --- 13. bin/fm-bootstrap.sh reports a stale home in its network phase ------
(
  dir="$TMP_ROOT/boot-stale"
  read -r home _origin <<EOF
$(make_fleet "$dir" 2)
EOF
  advance_origin "$dir" 8
  git -C "$home" fetch -q origin
  mkdir -p "$home/state" "$home/data" "$home/config"
  fakebin=$(make_probe_bin "$dir")
  out=$(boot_network "$home" "$fakebin")
  assert_contains "$out" "HOME_CURRENCY: this home is 8 commits behind origin/main" \
    "bootstrap did not report its own home as behind the fleet"
  assert_contains "$out" "NEEDS_GH_AUTH" "the network phase did not run at all"
  pass "home currency: bin/fm-bootstrap.sh reports its own home as eight commits behind"
)

# --- 14. a current home adds no line, and the run is proved to have happened -
(
  dir="$TMP_ROOT/boot-current"
  read -r home _origin <<EOF
$(make_fleet "$dir" 4)
EOF
  mkdir -p "$home/state" "$home/data" "$home/config"
  fakebin=$(make_probe_bin "$dir")
  out=$(boot_network "$home" "$fakebin")
  assert_contains "$out" "NEEDS_GH_AUTH" \
    "the positive control is missing, so this run proves nothing about silence"
  assert_not_contains "$out" "HOME_CURRENCY" "a current home added routine noise to a clean start"
  pass "home currency: a current home stays silent while the surrounding network phase demonstrably ran"
)

# --- 15. the case that failed: a stale SECONDMATE home, seen from its parent -
#
# Both secondmate homes stale on 2026-08-21 were linked worktrees leased detached
# on the default branch, exactly this shape, and the home that owned them saw
# nothing.
(
  dir="$TMP_ROOT/boot-secondmate"
  read -r home _origin <<EOF
$(make_fleet "$dir" 9)
EOF
  old=$(git -C "$home" rev-parse HEAD~8)
  git -C "$home" worktree add -q --detach "$dir/ops-home" "$old"
  printf 'ops\n' > "$dir/ops-home/.fm-secondmate-home"
  mkdir -p "$home/state" "$home/data" "$home/config" "$dir/ops-home/state" "$dir/ops-home/data"
  fm_write_secondmate_meta "$home/state/ops.meta" "$dir/ops-home"
  fakebin=$(make_probe_bin "$dir")

  out=$(boot_network "$home" "$fakebin")
  assert_contains "$out" "HOME_CURRENCY: secondmate ops is 8 commits behind origin/main" \
    "the parent home did not report its stale secondmate"
  assert_not_contains "$out" "HOME_CURRENCY: this home" \
    "the current parent home reported itself as drifted"

  # And the same secondmate home reports itself when it is the one starting.
  own=$(boot_network "$dir/ops-home" "$fakebin")
  assert_contains "$own" "HOME_CURRENCY: this home is 8 commits behind origin/main" \
    "a secondmate home did not report its own staleness at its own session start"

  pass "home currency: a stale secondmate home is reported both by its parent and by its own session start"
)

# --- 16. a remote-routed secondmate is left to its own session start --------
(
  dir="$TMP_ROOT/boot-remote-secondmate"
  read -r home _origin <<EOF
$(make_fleet "$dir" 9)
EOF
  old=$(git -C "$home" rev-parse HEAD~8)
  git -C "$home" worktree add -q --detach "$dir/remote-home" "$old"
  mkdir -p "$home/state" "$home/data" "$home/config"
  fm_write_secondmate_meta "$home/state/far.meta" "$dir/remote-home"
  printf 'remote_host=far.example.invalid\n' >> "$home/state/far.meta"
  fm_write_secondmate_meta "$home/state/near.meta" "$dir/remote-home"
  # A second local record naming the same directory: one home, one line.
  fm_write_secondmate_meta "$home/state/nearer.meta" "$dir/remote-home"
  fakebin=$(make_probe_bin "$dir")
  out=$(boot_network "$home" "$fakebin")
  assert_contains "$out" "HOME_CURRENCY: secondmate near is 8 commits behind origin/main" \
    "the local secondmate control was not reported, so this case proves nothing"
  assert_not_contains "$out" "secondmate far" \
    "a remote-routed secondmate was probed across ssh from its parent"
  lines=$(printf '%s\n' "$out" | grep -c 'HOME_CURRENCY: secondmate ' || true)
  [ "$lines" = 1 ] \
    || fail "one secondmate home produced $lines HOME_CURRENCY lines, expected 1"
  pass "home currency: a remote-routed secondmate is not probed from its parent, its local twin still is, and one home reports once"
)

# --- 17. the check lives in the network half, not the blocking local one ----
(
  dir="$TMP_ROOT/boot-phase"
  read -r home _origin <<EOF
$(make_fleet "$dir" 2)
EOF
  advance_origin "$dir" 5
  git -C "$home" fetch -q origin
  mkdir -p "$home/state" "$home/data" "$home/config"
  fakebin=$(make_probe_bin "$dir")
  skip_out=$(PATH="$fakebin:$BASE_PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$home" \
    FM_HOME_CURRENCY_TEST_SKIP=0 FM_BOOTSTRAP_NETWORK=skip FM_BOOTSTRAP_DETECT_ONLY=1 \
    "$ROOT/bin/fm-bootstrap.sh" 2>&1)
  only_out=$(boot_network "$home" "$fakebin")
  assert_contains "$only_out" "HOME_CURRENCY: this home is 5 commits behind origin/main" \
    "the network half lost the currency check"
  assert_not_contains "$skip_out" "HOME_CURRENCY" \
    "the local half made an origin call on the session start's blocking path"
  pass "home currency: the origin probe is in the network half, so no session start blocks on it"
)

# --- 18. the suite's hermeticity suppression is a real, pinned switch -------
#
# tests/lib.sh exports FM_HOME_CURRENCY_TEST_SKIP so no case reaches the real
# forge. Its meaning is pinned here in both directions, so it cannot quietly
# become the reason a future regression goes unnoticed.
(
  dir="$TMP_ROOT/boot-skip"
  read -r home _origin <<EOF
$(make_fleet "$dir" 2)
EOF
  advance_origin "$dir" 6
  git -C "$home" fetch -q origin
  mkdir -p "$home/state" "$home/data" "$home/config"
  fakebin=$(make_probe_bin "$dir")

  suppressed=$(PATH="$fakebin:$BASE_PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$home" \
    FM_HOME_CURRENCY_TEST_SKIP=1 FM_BOOTSTRAP_NETWORK=only FM_BOOTSTRAP_DETECT_ONLY=1 \
    "$ROOT/bin/fm-bootstrap.sh" 2>&1)
  assert_contains "$suppressed" "NEEDS_GH_AUTH" \
    "the suppressed run did not execute its network phase, so this case proves nothing"
  assert_not_contains "$suppressed" "HOME_CURRENCY" \
    "FM_HOME_CURRENCY_TEST_SKIP=1 did not suppress the check"

  unset_out=$(env -u FM_HOME_CURRENCY_TEST_SKIP \
    PATH="$fakebin:$BASE_PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$home" \
    FM_BOOTSTRAP_NETWORK=only FM_BOOTSTRAP_DETECT_ONLY=1 \
    "$ROOT/bin/fm-bootstrap.sh" 2>&1)
  assert_contains "$unset_out" "HOME_CURRENCY: this home is 6 commits behind origin/main" \
    "the check did not run with the suppression variable unset, which is how a real home runs"
  pass "home currency: the suite's suppression switch is off by default and pinned in both directions"
)

# --- 19. a full bootstrap network pass mutates no home it reported on -------
(
  dir="$TMP_ROOT/boot-readonly"
  read -r home _origin <<EOF
$(make_fleet "$dir" 9)
EOF
  old=$(git -C "$home" rev-parse HEAD~8)
  git -C "$home" worktree add -q --detach "$dir/ops-home" "$old"
  mkdir -p "$home/state" "$home/data" "$home/config"
  fm_write_secondmate_meta "$home/state/ops.meta" "$dir/ops-home"
  fakebin=$(make_probe_bin "$dir")

  before_home=$(fingerprint "$home")
  before_sub=$(fingerprint "$dir/ops-home")
  out=$(boot_network "$home" "$fakebin")
  after_home=$(fingerprint "$home")
  after_sub=$(fingerprint "$dir/ops-home")

  assert_contains "$out" "HOME_CURRENCY: secondmate ops is 8 commits behind origin/main" \
    "the non-mutation case did not actually exercise a reporting run"
  [ "$before_home" = "$after_home" ] || fail "the bootstrap network pass changed the home it ran in"
  [ "$before_sub" = "$after_sub" ] || fail "the bootstrap network pass changed the stale secondmate home it reported"
  [ "$(git -C "$dir/ops-home" rev-parse HEAD)" = "$old" ] \
    || fail "the stale secondmate home was fast-forwarded by a check that only reports"
  pass "home currency: a bootstrap network pass reports drift and fast-forwards nothing"
)
