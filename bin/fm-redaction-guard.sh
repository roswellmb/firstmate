#!/usr/bin/env bash
# fm-redaction-guard.sh - the single owner of firstmate's commit-time redaction
# rule: a document from a private archive is referenced by ID, never by title.
#
# WHAT DOOR THIS SITS ON
#   A firstmate home's private records live under data/, which .gitignore
#   already keeps out of every commit. So the archive files themselves are not
#   the exposure. The exposure is text copied OUT of them into the two surfaces
#   that do land in history:
#     1. the added lines of the staged diff of TRACKED files
#     2. the commit message
#   Both are evaluated here. The commit message is only readable at commit-msg
#   time, and the escape hatch below lives in that message, so this guard is a
#   commit-msg hook rather than a pre-commit hook. Both run before the commit
#   object exists, so either keeps the text out of the head.
#   A third path opens whenever .gitignore is weakened or bypassed with
#   `git add -f`; rule P below refuses that on its own.
#
# THE RULES
#   Rule P (private path): no staged path may be under a private root
#     (data/, state/, projects/, config/, .no-mistakes/, .lavish/, .env).
#     Refused on the path alone, without reading the file.
#   Rule T (title-shaped literal in a document context): within one line, a
#     quoted literal that is title-shaped and is preceded, inside a bounded
#     window, by a document-reference anchor word is refused. Referring to the
#     same document by ID leaves no quoted literal, so it passes.
#
#   The guard's expected value is the built-in anchor vocabulary and the
#   title-shape test below. Both are hand-written English structure. Neither is
#   derived from, nor ever compared against, any archive, index, or live
#   document service. The guard never learns a real title, so it cannot pass a
#   leak merely because it has already seen it.
#
# WHAT IT DOES NOT CATCH
#   See docs/redaction-guard.md "Stated gaps" - that document is the owner of
#   the gap list, the false-positive measurement, and the escape-hatch policy.
#
# EXIT STATUS
#   0  evaluated, nothing to refuse
#   1  evaluated, refused (violations printed)
#   2  could NOT evaluate (missing dependency, unreadable input, unknown mode).
#      This also stops the commit. The guard never exits 0 on an error path.
#
# Usage:
#   fm-redaction-guard.sh install [--repo <dir>]
#         wire this guard as the repository's commit-msg hook (idempotent)
#   fm-redaction-guard.sh uninstall [--repo <dir>]
#         remove the hook this guard installed, leaving any other hook alone
#   fm-redaction-guard.sh check-commit-msg <message-file>
#         the hook entry point: staged paths + staged added lines + message
#   fm-redaction-guard.sh check-rev <rev>
#         apply the same rules to an existing commit; used to measure the
#         false-positive rate against real history
#   fm-redaction-guard.sh check-range <base>..<head>
#         apply the same rules to every non-merge commit in a range; this is
#         the CI entry point, and the only one --no-verify cannot bypass
#   fm-redaction-guard.sh check-text [--label <name>] < text
#         apply rule T to text on stdin
#   fm-redaction-guard.sh --list-anchors
#         print the built-in anchor vocabulary
#   fm-redaction-guard.sh --help
set -u

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SELF="$SELF_DIR/fm-redaction-guard.sh"

HOOK_MARKER='fm-redaction-guard'
EXCEPTION_TRAILER='Redaction-Exception:'
EXCEPTION_MIN_REASON=20

# Private roots. A staged path under any of these is refused on the path alone.
PRIVATE_ROOTS='data state projects config .no-mistakes .lavish'
PRIVATE_FILES='.env'

# Document-reference anchors. Hand-written, archive-independent: these are the
# English words that mark "an archived document is being referred to here".
# Matched as whole lowercase words inside a bounded window before a literal.
ANCHORS='document documents doc docs scan scans scanned rescan rescanned ocr correspondence invoice invoices receipt receipts statement statements attachment attachments paperless titled entitled'

die_cannot_evaluate() {
  printf '%s: cannot evaluate: %s\n' "$HOOK_MARKER" "$1" >&2
  printf '%s: refusing the commit rather than passing silently.\n' "$HOOK_MARKER" >&2
  exit 2
}

usage() {
  sed -n '2,/^set -u$/p' "$SELF" | sed 's/^# \{0,1\}//; $d'
}

require_deps() {
  local dep
  for dep in "$@"; do
    command -v "$dep" >/dev/null 2>&1 \
      || die_cannot_evaluate "required dependency '$dep' is not on PATH"
  done
}

repo_root() {
  local root
  root="$(git rev-parse --show-toplevel 2>/dev/null)" \
    || die_cannot_evaluate "not inside a git repository (git rev-parse --show-toplevel failed)"
  [ -n "$root" ] \
    || die_cannot_evaluate "git reported an empty repository root"
  printf '%s\n' "$root"
}

# ---------------------------------------------------------------------------
# Rule T: the line scanner.
#
# Emits one TAB-separated record per violation:
#   <label> <lineno> <literal>
# ---------------------------------------------------------------------------
# Input on stdin is TAB-separated: <label> <lineno> <line>
scan_lines() {
  awk -v anchors="$ANCHORS" -F '\t' '
  BEGIN {
    n = split(anchors, a, " ")
    for (i = 1; i <= n; i++) if (a[i] != "") ANCHOR[a[i]] = 1
    WINDOW = 64
    MAXLINE = 2000
  }

  # A literal is title-shaped when every one of these holds. This is the whole
  # of the guards expected value: no archive is consulted to decide it.
  function title_shaped(s,   len, cnt, i, w, arr, cap, caplong) {
    len = length(s)
    if (len < 12 || len > 120) return 0
    # Character whitelist. Anything outside it reads as code, a path, a URL, a
    # glob, a command or an expression rather than as a document title.
    if (s !~ /^[A-Za-z0-9 .,&:#'"'"'-]+$/) return 0
    cnt = split(s, arr, " ")
    if (cnt < 3 || cnt > 12) return 0
    # A filename is not a title.
    if (arr[cnt] ~ /^[A-Za-z0-9-]+\.[A-Za-z0-9]+$/) return 0
    cap = 0; caplong = 0
    for (i = 1; i <= cnt; i++) {
      w = arr[i]
      if (w ~ /^[A-Z]/) {
        cap++
        # A capitalised word of real length that is not an all-caps token:
        # this is what separates prose-with-a-capital from a proper name.
        if (length(w) >= 4 && w ~ /[a-z]/) caplong = 1
      }
    }
    if (cap < 2) return 0
    if (!caplong) return 0
    return 1
  }

  function anchored(prefix,   tail, cnt, i, arr, w) {
    tail = (length(prefix) > WINDOW) ? substr(prefix, length(prefix) - WINDOW + 1) : prefix
    # A path component or a filename is not a document reference. Without this,
    # an ordinary cross-reference such as docs/<file>.md followed by a quoted
    # section name would read as a document context. Strip both shapes before
    # looking for anchor words.
    gsub(/[A-Za-z0-9_.-]*\/[A-Za-z0-9_.\/-]*/, " ", tail)
    gsub(/[A-Za-z0-9_-]+\.[A-Za-z0-9_.-]+/, " ", tail)
    gsub(/[^A-Za-z0-9]+/, " ", tail)
    cnt = split(tail, arr, " ")
    for (i = 1; i <= cnt; i++) {
      w = tolower(arr[i])
      if (w in ANCHOR) return 1
    }
    return 0
  }

  # A quote character only opens or closes a literal at a word edge. Without
  # this an apostrophe inside ordinary prose would open a spurious literal.
  function edge(c) { return (c == "" || c !~ /[A-Za-z0-9]/) }

  {
    label = $1; lineno = $2
    line = $0
    sub(/^[^\t]*\t[^\t]*\t/, "", line)
    L = length(line)
    if (L > MAXLINE) next
    i = 1
    while (i <= L) {
      c = substr(line, i, 1)
      if (c == "\"" || c == "`" || c == "'"'"'") {
        before = (i > 1) ? substr(line, i - 1, 1) : ""
        if (!edge(before)) { i++; continue }
        j = i + 1
        found = 0
        while (j <= L) {
          if (substr(line, j, 1) == c) {
            after = (j < L) ? substr(line, j + 1, 1) : ""
            if (edge(after)) { found = 1; break }
          }
          j++
        }
        if (!found) { i++; continue }
        lit = substr(line, i + 1, j - i - 1)
        if (title_shaped(lit) && anchored(substr(line, 1, i - 1)))
          printf "%s\t%s\t%s\n", label, lineno, lit
        i = j + 1
      } else i++
    }
  }
  '
}

# ---------------------------------------------------------------------------
# Findings
# ---------------------------------------------------------------------------
FINDINGS_FILE=

finding_token() {
  # Bound to the exact rule, location and literal. A different literal, or the
  # same literal in a different file, is a different finding with a different
  # token, so an exception can never be reused for a second leak.
  local sum
  sum="$(printf '%s\037%s\037%s' "$1" "$2" "$3" | cksum | awk '{print $1}')" \
    || die_cannot_evaluate "could not compute a finding token (cksum failed)"
  printf '%08x\n' "$sum"
}

record_finding() {
  # rule, location, literal, human message
  local rule=$1 loc=$2 lit=$3 msg=$4 token
  token="$(finding_token "$rule" "$loc" "$lit")"
  printf '%s\t%s\t%s\n' "$token" "$rule" "$msg" >>"$FINDINGS_FILE"
}

# ---------------------------------------------------------------------------
# Rule P
# ---------------------------------------------------------------------------
check_private_paths() {
  local path root_name
  while IFS= read -r path; do
    [ -n "$path" ] || continue
    root_name=${path%%/*}
    case " $PRIVATE_ROOTS " in
      *" $root_name "*)
        [ "$root_name" != "$path" ] || continue
        record_finding P "$path" "$path" \
          "staged path is under the private root '$root_name/': $path"
        continue
        ;;
    esac
    case " $PRIVATE_FILES " in
      *" $path "*)
        record_finding P "$path" "$path" "staged path is a private file: $path"
        ;;
    esac
  done
}

# ---------------------------------------------------------------------------
# Added lines of a diff, as <label> <lineno> <line>
# ---------------------------------------------------------------------------
added_lines() {
  awk -F '\t' '
  /^\+\+\+ / {
    path = substr($0, 7)
    if (path == "/dev/null") path = ""
    next
  }
  /^@@ / {
    m = $0
    sub(/^@@ [^+]*\+/, "", m)
    sub(/[ ,].*$/, "", m)
    lineno = m + 0
    next
  }
  /^\+/ {
    if (path == "") next
    printf "%s\t%d\t%s\n", path, lineno, substr($0, 2)
    lineno++
  }
  '
}

report_and_exit() {
  local count token rule msg
  count=$(wc -l <"$FINDINGS_FILE" | tr -d ' ')
  if [ "$count" = "0" ]; then
    exit 0
  fi
  printf '%s: refusing this commit. %s finding(s).\n\n' "$HOOK_MARKER" "$count" >&2
  while IFS=$'\t' read -r token rule msg; do
    printf '  [%s] %s\n' "$rule" "$msg" >&2
    printf '      [exception-token %s]\n' "$token" >&2
  done <"$FINDINGS_FILE"
  cat >&2 <<EOF

Rule P: private records are referenced, never committed. Unstage the path.
Rule T: refer to an archived document by its ID, not by its title.

If a finding is genuinely wrong, add one trailer per finding to the commit
message, each naming that finding's own token and stating why:

  $EXCEPTION_TRAILER <token> <reason of at least $EXCEPTION_MIN_REASON characters>

The token is bound to that exact text in that exact place, so it releases
nothing else and it does not survive the next edit.
EOF
  exit 1
}

# ---------------------------------------------------------------------------
# Exceptions
# ---------------------------------------------------------------------------
apply_exceptions() {
  local msg_file=$1 kept token rule msg line ex_token ex_reason released
  kept="$(mktemp "${TMPDIR:-/tmp}/fm-redaction-kept.XXXXXX")" \
    || die_cannot_evaluate "could not create a temporary file"
  while IFS=$'\t' read -r token rule msg; do
    released=0
    while IFS= read -r line; do
      case "$line" in
        "$EXCEPTION_TRAILER"*) : ;;
        *) continue ;;
      esac
      line=${line#"$EXCEPTION_TRAILER"}
      line=${line# }
      ex_token=${line%% *}
      ex_reason=${line#* }
      [ "$ex_token" = "$line" ] && ex_reason=
      # A blanket exception is not a thing. Only a real token releases a finding.
      [ "$ex_token" = "$token" ] || continue
      if [ "${#ex_reason}" -lt "$EXCEPTION_MIN_REASON" ]; then
        printf '%s: exception for %s ignored: its reason is shorter than %s characters.\n' \
          "$HOOK_MARKER" "$token" "$EXCEPTION_MIN_REASON" >&2
        continue
      fi
      released=1
      break
    done <"$msg_file"
    [ "$released" -eq 1 ] || printf '%s\t%s\t%s\n' "$token" "$rule" "$msg" >>"$kept"
  done <"$FINDINGS_FILE"
  mv "$kept" "$FINDINGS_FILE" \
    || die_cannot_evaluate "could not rewrite the findings list"
}

# ---------------------------------------------------------------------------
# Modes
# ---------------------------------------------------------------------------
new_findings_file() {
  FINDINGS_FILE="$(mktemp "${TMPDIR:-/tmp}/fm-redaction-findings.XXXXXX")" \
    || die_cannot_evaluate "could not create a temporary file"
  trap 'rm -f "$FINDINGS_FILE"' EXIT
}

scan_into_findings() {
  # stdin: <label> <lineno> <line>
  # The scanner's own failure is a cannot-evaluate condition, not a clean pass.
  local label lineno lit out err
  out="$(mktemp "${TMPDIR:-/tmp}/fm-redaction-scan.XXXXXX")" \
    || die_cannot_evaluate "could not create a temporary file"
  err="$out.err"
  if ! scan_lines >"$out" 2>"$err"; then
    printf '%s\n' "$(cat "$err" 2>/dev/null)" >&2
    rm -f "$out" "$err"
    die_cannot_evaluate "the line scanner failed"
  fi
  if [ -s "$err" ]; then
    printf '%s\n' "$(cat "$err")" >&2
    rm -f "$out" "$err"
    die_cannot_evaluate "the line scanner reported errors"
  fi
  while IFS=$'\t' read -r label lineno lit; do
    record_finding T "$label" "$lit" \
      "$label:$lineno refers to a document by a quoted title; use the document ID instead"
  done <"$out"
  rm -f "$out" "$err"
}

mode_check_commit_msg() {
  local msg_file=$1 root staged
  [ -n "$msg_file" ] || die_cannot_evaluate "check-commit-msg needs a message-file path"
  require_deps git awk sed cksum wc mktemp
  root="$(repo_root)"
  [ -r "$msg_file" ] || die_cannot_evaluate "commit message file is not readable: $msg_file"
  new_findings_file

  staged="$(git -C "$root" diff --cached --name-only --diff-filter=ACMR 2>/dev/null)" \
    || die_cannot_evaluate "could not read the staged file list (git diff --cached failed)"
  printf '%s\n' "$staged" | check_private_paths

  git -C "$root" diff --cached --unified=0 --no-color --no-ext-diff --diff-filter=ACMR 2>/dev/null \
    >"$FINDINGS_FILE.diff" \
    || die_cannot_evaluate "could not read the staged diff (git diff --cached failed)"
  added_lines <"$FINDINGS_FILE.diff" | scan_into_findings
  rm -f "$FINDINGS_FILE.diff"

  awk -v label=COMMIT_MSG '{ printf "%s\t%d\t%s\n", label, NR, $0 }' "$msg_file" \
    | scan_into_findings

  apply_exceptions "$msg_file"
  report_and_exit
}

mode_check_rev() {
  local rev=$1 root msg_file
  [ -n "$rev" ] || die_cannot_evaluate "check-rev needs a revision"
  require_deps git awk sed cksum wc mktemp
  root="$(repo_root)"
  git -C "$root" rev-parse --verify --quiet "$rev^{commit}" >/dev/null \
    || die_cannot_evaluate "not a commit: $rev"
  new_findings_file

  git -C "$root" show --pretty=format: --name-only --diff-filter=ACMR "$rev" 2>/dev/null \
    | check_private_paths \
    || die_cannot_evaluate "could not read the file list for $rev"

  git -C "$root" show --pretty=format: --unified=0 --no-color --no-ext-diff \
    --diff-filter=ACMR "$rev" 2>/dev/null >"$FINDINGS_FILE.diff" \
    || die_cannot_evaluate "could not read the diff for $rev"
  added_lines <"$FINDINGS_FILE.diff" | scan_into_findings
  rm -f "$FINDINGS_FILE.diff"

  msg_file="$FINDINGS_FILE.msg"
  git -C "$root" log -1 --format=%B "$rev" >"$msg_file" 2>/dev/null \
    || die_cannot_evaluate "could not read the commit message for $rev"
  awk -v label=COMMIT_MSG '{ printf "%s\t%d\t%s\n", label, NR, $0 }' "$msg_file" \
    | scan_into_findings
  apply_exceptions "$msg_file"
  rm -f "$msg_file"
  report_and_exit
}

mode_check_range() {
  # Apply check-rev to every non-merge commit in a range. This is the CI entry
  # point: local hooks are per clone and `git commit --no-verify` bypasses them,
  # so the range check is what actually stops a leak reaching the default branch.
  local range=$1 root revs rev out rc worst=0 count
  [ -n "$range" ] || die_cannot_evaluate "check-range needs a revision range"
  require_deps git awk sed cksum wc mktemp
  root="$(repo_root)"
  revs="$(git -C "$root" rev-list --no-merges "$range" 2>/dev/null)" \
    || die_cannot_evaluate "could not resolve the revision range: $range"
  if [ -z "$revs" ]; then
    printf '%s: no commits to check in %s\n' "$HOOK_MARKER" "$range"
    return 0
  fi
  count=$(printf '%s\n' "$revs" | wc -l | tr -d ' ')
  while IFS= read -r rev; do
    [ -n "$rev" ] || continue
    out="$( ( mode_check_rev "$rev" ) 2>&1 )" && continue
    rc=$?
    printf '%s: %s\n' "$HOOK_MARKER" \
      "$(git -C "$root" log -1 --format='%h %s' "$rev" 2>/dev/null)" >&2
    printf '%s\n' "$out" >&2
    [ "$rc" -gt "$worst" ] && worst=$rc
  done <<RANGE
$revs
RANGE
  [ "$worst" -eq 0 ] || exit "$worst"
  printf '%s: %s commit(s) clean in %s\n' "$HOOK_MARKER" "$count" "$range"
}

mode_check_text() {
  local label=$1
  require_deps awk cksum wc mktemp
  new_findings_file
  awk -v label="$label" '{ printf "%s\t%d\t%s\n", label, NR, $0 }' | scan_into_findings
  report_and_exit
}

hook_body() {
  cat <<EOF
#!/usr/bin/env sh
# Installed by $HOOK_MARKER. Remove with: fm-redaction-guard.sh uninstall
exec '$SELF' check-commit-msg "\$1"
EOF
}

mode_install() {
  local root hook
  require_deps git
  root="$(repo_root)"
  hook="$root/.git/hooks/commit-msg"
  [ -d "$root/.git/hooks" ] || mkdir -p "$root/.git/hooks" \
    || die_cannot_evaluate "could not create $root/.git/hooks"
  if [ -e "$hook" ] && ! grep -q "$HOOK_MARKER" "$hook" 2>/dev/null; then
    die_cannot_evaluate "$hook already exists and was not installed by $HOOK_MARKER; merge it by hand"
  fi
  hook_body >"$hook" || die_cannot_evaluate "could not write $hook"
  chmod +x "$hook" || die_cannot_evaluate "could not make $hook executable"
  printf '%s: installed commit-msg hook at %s\n' "$HOOK_MARKER" "$hook"
}

mode_uninstall() {
  local root hook
  require_deps git
  root="$(repo_root)"
  hook="$root/.git/hooks/commit-msg"
  if [ ! -e "$hook" ]; then
    printf '%s: no commit-msg hook to remove\n' "$HOOK_MARKER"
    return 0
  fi
  grep -q "$HOOK_MARKER" "$hook" 2>/dev/null \
    || die_cannot_evaluate "$hook was not installed by $HOOK_MARKER; leaving it alone"
  rm -f "$hook" || die_cannot_evaluate "could not remove $hook"
  printf '%s: removed commit-msg hook at %s\n' "$HOOK_MARKER" "$hook"
}

main() {
  local mode label
  [ "$#" -gt 0 ] || die_cannot_evaluate "no mode given (see --help)"
  mode=$1
  shift
  case "$mode" in
    -h|--help|help) usage; exit 0 ;;
    --list-anchors) printf '%s' "$ANCHORS" | tr ' ' '\n'; exit 0 ;;
    install)
      case "${1:-}" in --repo) cd "${2:?--repo needs a directory}" || die_cannot_evaluate "cannot enter ${2}" ;; esac
      mode_install
      ;;
    uninstall)
      case "${1:-}" in --repo) cd "${2:?--repo needs a directory}" || die_cannot_evaluate "cannot enter ${2}" ;; esac
      mode_uninstall
      ;;
    check-commit-msg) mode_check_commit_msg "${1:-}" ;;
    check-rev) mode_check_rev "${1:-}" ;;
    check-range) mode_check_range "${1:-}" ;;
    check-text)
      label=STDIN
      case "${1:-}" in --label) label=${2:?--label needs a name} ;; esac
      mode_check_text "$label"
      ;;
    *) die_cannot_evaluate "unrecognised mode '$mode' (see --help)" ;;
  esac
}

main "$@"
