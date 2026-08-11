#!/usr/bin/env bash
# Targeted tests for GitHub Enterprise Server support via config/github-hosts.
# Covers: fm_pr_ghe_host_listed, fm_pr_url_parse (GHE), fm-pr-poll.sh --hostname,
# fm-pr-merge.sh --hostname, and fm-bootstrap.sh github_hosts_validate.
set -u

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=bin/fm-pr-lib.sh disable=SC1091
. "$ROOT/bin/fm-pr-lib.sh"

PR_MERGE="$ROOT/bin/fm-pr-merge.sh"
PR_POLL="$ROOT/bin/fm-pr-poll.sh"
TMP_ROOT=$(fm_test_tmproot fm-github-hosts)
BASE_PATH=${FM_TEST_BASE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}

# ---------------------------------------------------------------------------
# 1. fm_pr_ghe_host_listed: list-based host lookup
# ---------------------------------------------------------------------------

test_ghe_host_listed() {
  local hosts_file dir
  dir="$TMP_ROOT/ghe-host-listed"
  mkdir -p "$dir"
  hosts_file="$dir/github-hosts"

  # No file -> false
  FM_PR_GHE_HOSTS_FILE="$hosts_file" fm_pr_ghe_host_listed github.mpi-internal.com \
    && fail "ghe_host_listed returned true with missing file" || true

  # File with host -> true
  printf 'github.mpi-internal.com\n' > "$hosts_file"
  FM_PR_GHE_HOSTS_FILE="$hosts_file" fm_pr_ghe_host_listed github.mpi-internal.com \
    || fail "ghe_host_listed returned false for a listed host"

  # Comments and blank lines are skipped
  printf '# comment\n\ngithub.mpi-internal.com\n' > "$hosts_file"
  FM_PR_GHE_HOSTS_FILE="$hosts_file" fm_pr_ghe_host_listed github.mpi-internal.com \
    || fail "ghe_host_listed returned false when host listed after comment/blank"

  # Unlisted host -> false
  FM_PR_GHE_HOSTS_FILE="$hosts_file" fm_pr_ghe_host_listed other.host.example \
    && fail "ghe_host_listed returned true for an unlisted host" || true

  # File resolves from FM_HOME when FM_PR_GHE_HOSTS_FILE is unset
  mkdir -p "$dir/home/config"
  printf 'github.mpi-internal.com\n' > "$dir/home/config/github-hosts"
  FM_HOME="$dir/home" FM_PR_GHE_HOSTS_FILE='' fm_pr_ghe_host_listed github.mpi-internal.com \
    || fail "ghe_host_listed could not resolve host via FM_HOME"

  pass "fm_pr_ghe_host_listed correctly gates on file presence and hostname match"
}

# ---------------------------------------------------------------------------
# 2. fm_pr_url_parse: GHE URLs accepted as provider=github
# ---------------------------------------------------------------------------

test_ghe_url_parse_accepted() {
  local hosts_file dir
  dir="$TMP_ROOT/ghe-url-parse"
  mkdir -p "$dir"
  hosts_file="$dir/github-hosts"
  printf 'github.mpi-internal.com\n' > "$hosts_file"

  FM_PR_GHE_HOSTS_FILE="$hosts_file" \
    fm_pr_url_parse "https://github.mpi-internal.com/my-org/my-repo/pull/42" \
    || fail "url_parse rejected a GHE PR URL for a listed host"

  [ "$FM_PR_PROVIDER" = github ] \
    || fail "url_parse set provider='$FM_PR_PROVIDER' instead of github for a GHE URL"
  [ "$FM_PR_HOST" = github.mpi-internal.com ] \
    || fail "url_parse set host='$FM_PR_HOST' instead of the GHE hostname"
  [ "$FM_PR_OWNER" = my-org ] \
    || fail "url_parse set owner='$FM_PR_OWNER' instead of my-org"
  [ "$FM_PR_REPO" = my-repo ] \
    || fail "url_parse set repo='$FM_PR_REPO' instead of my-repo"
  [ "$FM_PR_NUMBER" = 42 ] \
    || fail "url_parse set number='$FM_PR_NUMBER' instead of 42"
  [ "$FM_PR_URL" = "https://github.mpi-internal.com/my-org/my-repo/pull/42" ] \
    || fail "url_parse mutated the URL"

  pass "fm_pr_url_parse accepts a GHE PR URL and sets provider=github with correct fields"
}

test_ghe_url_parse_unlisted_rejected() {
  local hosts_file dir
  dir="$TMP_ROOT/ghe-url-reject"
  mkdir -p "$dir"
  hosts_file="$dir/github-hosts"
  printf 'github.mpi-internal.com\n' > "$hosts_file"

  FM_PR_GHE_HOSTS_FILE="$hosts_file" \
    fm_pr_url_parse "https://evil.example.com/my-org/my-repo/pull/1" \
    && fail "url_parse accepted a PR URL for an unlisted host" || true

  pass "fm_pr_url_parse rejects a GitHub-shaped URL for a host not in config/github-hosts"
}

# ---------------------------------------------------------------------------
# 3. fm-pr-poll.sh: --hostname passed for GHE host
# ---------------------------------------------------------------------------

make_poll_case() {
  local name=$1 host=$2
  local dir="$TMP_ROOT/poll-$name"
  mkdir -p "$dir/home/state" "$dir/fakebin"

  # gh mock: records invocation args, returns state
  cat > "$dir/fakebin/gh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_TEST_GH_LOG"
case " $* " in
  *" state "*) printf '%s\n' "${FM_TEST_GH_STATE:-OPEN}" ;;
esac
SH
  chmod +x "$dir/fakebin/gh"

  # Poll sidecar: 5-line format (provider url host path number)
  local url="https://$host/my-org/my-repo/pull/7"
  printf '%s\n%s\n%s\n%s\n%s\n' "github" "$url" "$host" "my-org/my-repo" "7" \
    > "$dir/home/state/task-a.pr-poll"
  chmod 0600 "$dir/home/state/task-a.pr-poll"
  cp "$PR_POLL" "$dir/home/state/task-a.check.sh"
  chmod 0600 "$dir/home/state/task-a.check.sh"
  printf '%s\n' "$dir"
}

run_poll() {
  local dir=$1
  FM_TEST_GH_LOG="$dir/gh.log" \
    PATH="$dir/fakebin:$BASE_PATH" \
    bash "$dir/home/state/task-a.check.sh"
}

test_poll_uses_hostname_for_ghe() {
  local dir out
  dir=$(make_poll_case ghe-hostname github.mpi-internal.com)
  : > "$dir/gh.log"

  out=$(FM_TEST_GH_STATE=MERGED run_poll "$dir")
  [ "$out" = merged ] || fail "poll did not emit 'merged' for a MERGED GHE PR"

  grep -q -- '--hostname github.mpi-internal.com' "$dir/gh.log" \
    || fail "poll did not pass --hostname for a non-github.com host: $(cat "$dir/gh.log")"

  pass "fm-pr-poll.sh passes --hostname <ghe-host> to gh pr view for GHE hosts"
}

test_poll_no_hostname_for_github_com() {
  local dir out
  dir=$(make_poll_case dotcom github.com)
  : > "$dir/gh.log"

  out=$(FM_TEST_GH_STATE=MERGED run_poll "$dir")
  [ "$out" = merged ] || fail "poll did not emit 'merged' for a MERGED github.com PR"

  grep -q -- '--hostname' "$dir/gh.log" \
    && fail "poll passed --hostname for github.com (should not)" || true

  pass "fm-pr-poll.sh does NOT pass --hostname for github.com"
}

# ---------------------------------------------------------------------------
# 4. fm-pr-merge.sh: --hostname passed for GHE host
# ---------------------------------------------------------------------------

make_merge_case() {
  local name=$1 dir fakebin
  dir="$TMP_ROOT/merge-$name"
  fakebin="$dir/fakebin"
  mkdir -p "$dir/state" "$fakebin"
  fm_write_meta "$dir/state/task-x1.meta" \
    "window=fm-task-x1" \
    "worktree=$dir/wt" \
    "project=$dir/project" \
    "kind=ship" \
    "mode=no-mistakes"
  cat > "$fakebin/gh-axi" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_TEST_GH_AXI_LOG"
exit 0
SH
  cat > "$fakebin/gh" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$fakebin/gh-axi" "$fakebin/gh"
  printf '%s\n' "$dir"
}

run_pr_merge() {
  local dir=$1 hosts_file=$2; shift 2
  FM_ROOT_OVERRIDE="$ROOT" \
  FM_STATE_OVERRIDE="$dir/state" \
  FM_PR_GHE_HOSTS_FILE="$hosts_file" \
  FM_TEST_GH_AXI_LOG="$dir/gh-axi.log" \
  PATH="$dir/fakebin:$PATH" \
    "$PR_MERGE" "$@"
}

test_merge_uses_hostname_for_ghe() {
  local dir hosts_file
  dir=$(make_merge_case ghe-hostname)
  hosts_file="$TMP_ROOT/merge-ghe-hostname.hosts"
  printf 'github.mpi-internal.com\n' > "$hosts_file"
  : > "$dir/gh-axi.log"

  run_pr_merge "$dir" "$hosts_file" task-x1 \
    "https://github.mpi-internal.com/my-org/my-repo/pull/99" \
    > "$dir/stdout" 2> "$dir/stderr" \
    || fail "merge failed for a GHE PR URL: $(cat "$dir/stderr")"

  grep -q -- '--hostname github.mpi-internal.com' "$dir/gh-axi.log" \
    || fail "merge did not pass --hostname for a GHE host: $(cat "$dir/gh-axi.log")"
  grep -q 'pr merge 99 --repo my-org/my-repo' "$dir/gh-axi.log" \
    || fail "merge did not pass correct PR number and --repo: $(cat "$dir/gh-axi.log")"

  pass "fm-pr-merge.sh passes --hostname <ghe-host> to gh-axi pr merge for GHE hosts"
}

test_merge_no_hostname_for_github_com() {
  local dir hosts_file
  dir=$(make_merge_case dotcom)
  hosts_file="$TMP_ROOT/merge-dotcom.hosts"
  printf 'github.mpi-internal.com\n' > "$hosts_file"
  : > "$dir/gh-axi.log"

  run_pr_merge "$dir" "$hosts_file" task-x1 \
    "https://github.com/my-org/my-repo/pull/5" \
    > "$dir/stdout" 2> "$dir/stderr" \
    || fail "merge failed for a github.com PR URL"

  grep -q -- '--hostname' "$dir/gh-axi.log" \
    && fail "merge passed --hostname for github.com (should not)" || true
  grep -qxF 'pr merge 5 --repo my-org/my-repo --squash' "$dir/gh-axi.log" \
    || fail "merge invocation was not as expected: $(cat "$dir/gh-axi.log")"

  pass "fm-pr-merge.sh does NOT pass --hostname for github.com"
}

# ---------------------------------------------------------------------------
# 5. fm-bootstrap.sh: github_hosts_validate emits BOOTSTRAP_INFO for bad lines
# ---------------------------------------------------------------------------

# Build a minimal fake toolchain so the full bootstrap script exits cleanly.
make_bootstrap_toolchain() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  fm_fake_exit0 "$fakebin" tmux node gh-axi chrome-devtools-axi lavish-axi treehouse no-mistakes tasks-axi quota-axi
  cat > "$fakebin/gh" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = auth ] && [ "${2:-}" = status ]; then exit 0; fi
if [ "${1:-}" = --version ]; then printf 'gh version 2.0.0\n'; exit 0; fi
exit 0
SH
  chmod +x "$fakebin/gh"
  cat > "$fakebin/no-mistakes" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = --version ]; then
  printf 'no-mistakes version v1.31.2 (fake) 2026-06-27T00:02:18Z\n'; exit 0
fi
exit 0
SH
  chmod +x "$fakebin/no-mistakes"
  cat > "$fakebin/tasks-axi" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = --version ]; then printf '0.1.1\n'; exit 0; fi
if [ "${1:-}" = update ] && [ "${2:-}" = --help ]; then
  printf 'usage: tasks-axi update <id>\n  --body-file <path>\n  --archive-body\n'; exit 0
fi
if [ "${1:-}" = mv ] && [ "${2:-}" = --help ]; then
  printf 'usage: tasks-axi mv <id> [<id>...] --to <path-or-dir>\n'; exit 0
fi
exit 0
SH
  chmod +x "$fakebin/tasks-axi"
  printf '%s\n' "$fakebin"
}

run_bootstrap() {
  local home=$1 fakebin=$2
  PATH="$fakebin:$BASE_PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$home" \
    FM_FAKE_TREEHOUSE_LEASE_HELP=1 "$ROOT/bin/fm-bootstrap.sh"
}

test_bootstrap_validates_github_hosts() {
  local dir fakebin home out

  dir="$TMP_ROOT/bootstrap-validate"
  mkdir -p "$dir"
  fakebin=$(make_bootstrap_toolchain "$dir")
  home="$dir/home"
  mkdir -p "$home/config"
  # manual backlog backend keeps tasks-axi output silent
  printf 'manual\n' > "$home/config/backlog-backend"

  # Valid file: no BOOTSTRAP_INFO about github-hosts
  printf 'github.mpi-internal.com\n# a comment\n\nghe.corp.example\n' > "$home/config/github-hosts"
  out=$(run_bootstrap "$home" "$fakebin" 2>&1)
  printf '%s\n' "$out" | grep -q 'github-hosts' \
    && fail "bootstrap emitted github-hosts warning for a valid file: $out" || true

  # Invalid hostname (has a scheme): should emit BOOTSTRAP_INFO
  printf 'https://github.mpi-internal.com\n' > "$home/config/github-hosts"
  out=$(run_bootstrap "$home" "$fakebin" 2>&1)
  printf '%s\n' "$out" | grep -q 'BOOTSTRAP_INFO:.*github-hosts.*invalid hostname' \
    || fail "bootstrap did not warn about a hostname with scheme: '$out'"

  # Invalid hostname (trailing dot): should emit BOOTSTRAP_INFO
  printf 'github.mpi-internal.com.\n' > "$home/config/github-hosts"
  out=$(run_bootstrap "$home" "$fakebin" 2>&1)
  printf '%s\n' "$out" | grep -q 'BOOTSTRAP_INFO:.*github-hosts.*invalid hostname' \
    || fail "bootstrap did not warn about a hostname with trailing dot: '$out'"

  # Missing file: no github-hosts mention
  rm -f "$home/config/github-hosts"
  out=$(run_bootstrap "$home" "$fakebin" 2>&1)
  printf '%s\n' "$out" | grep -q 'github-hosts' \
    && fail "bootstrap mentioned github-hosts when file is absent: $out" || true

  pass "fm-bootstrap.sh github_hosts_validate emits BOOTSTRAP_INFO for invalid hostnames"
}

# ---------------------------------------------------------------------------
# Run all tests
# ---------------------------------------------------------------------------

test_ghe_host_listed
test_ghe_url_parse_accepted
test_ghe_url_parse_unlisted_rejected
test_poll_uses_hostname_for_ghe
test_poll_no_hostname_for_github_com
test_merge_uses_hostname_for_ghe
test_merge_no_hostname_for_github_com
test_bootstrap_validates_github_hosts
