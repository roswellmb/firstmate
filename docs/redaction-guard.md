# Redaction guard

A firstmate home's private records under `data/` describe real documents from the owner's archive.
This guard keeps the text of those documents out of committed history from here on.
The rule it enforces is short: an archived document is referred to by its ID, never by its title.

`bin/fm-redaction-guard.sh` is the single owner of the rule, the exit contract, and the mechanics.
Run `bin/fm-redaction-guard.sh --help` for exact modes and flags.
This document owns what the guard covers, what it deliberately does not, the measured false-positive rate, and the escape-hatch policy.

## Which door it sits on

`data/`, `state/`, `projects/`, `config/`, `.no-mistakes/` and `.lavish/` are gitignored in this repository, so the private records themselves never enter a commit.
The archive files are not the exposure.
The exposure is text copied *out* of those records into the two surfaces that do land in history:

1. the added lines of the staged diff of tracked files
2. the commit message

The second is the one nothing else covers.
A commit message that quotes a task note lands in history permanently, and no diff-shaped check ever sees it.

A third path opens whenever the ignore rules are weakened or bypassed with `git add -f`.
That is what `.gitignore` is doing today, and it is exactly the kind of protection that stops working by accident.

The guard therefore runs as a `commit-msg` hook rather than a `pre-commit` hook.
The commit message is only readable at `commit-msg` time, and the escape hatch below lives in that message, so both halves of the check are only evaluable there.
Both hooks run before the commit object exists, so either keeps the text out of the head.

## The rules

**Rule P, private path.**
No staged path may sit under a private root, and no staged path may be `.env`.
Refused on the path alone, without reading the file.

**Rule T, a document reference must be an ID.**
Within one line, a *quoted literal* that is *title-shaped* and is preceded, inside a 64-character window, by a *document-reference anchor word* is refused.
Referring to the same document by its ID leaves no quoted literal at all, so it passes.

A literal is title-shaped when every one of these holds:

- 12 to 120 characters, and 3 to 12 whitespace-separated words
- every character is a letter, digit, space, or one of `. , & : # ' -`
- at least two words begin with a capital letter
- at least one of those capitalised words is four or more characters and is not an all-caps token
- the last word is not a filename

A document-reference anchor is a whole word from a fixed built-in vocabulary, printable with `--list-anchors`.
Path components and filenames are stripped from the window first, so `docs/configuration.md "Some Section"` is a cross-reference and not a document context.

### Where the expected value comes from

The anchor vocabulary and the title-shape test above are the guard's entire expected value.
Both are hand-written English structure.
Neither is derived from, compared against, or refreshed from any archive, index, export, or live document service.

This is deliberate and it is the reason the guard has this shape.
A guard that learned its forbidden titles by reading the live instance would mirror whatever that instance already held: it would pass every document it had already seen and catch nothing new, while copying the archive into the check in order to do it.
Because this guard never knows a single real title, it cannot pass a leak on the grounds that it recognises it.
It rejects the *shape* of a leak, not its content, which is why it also flags synthesised examples.

## Stated gaps

A structural rule has gaps.
These are the known ones, and the list is more useful than an implied guarantee:

- **`git commit --no-verify` bypasses it completely.** Git offers no way for a hook to prevent this. Server-side or CI enforcement is the only answer, and the repository's CI check is what closes it for anything reaching the default branch.
- **An unquoted title is not detected.** The rule requires a quoted literal, because quoting is what turns prose into a reproduced value. A title written as bare prose passes.
- **A title outside the anchor window passes.** If the document reference and the title are more than 64 characters apart, or the anchor word is not in the vocabulary, nothing fires.
- **A title that does not look like a title passes.** An all-lowercase title, a one or two word title, a title under 12 characters, or one containing characters outside the whitelist, will not match.
- **Document *content*, as opposed to a document *title*, is only covered incidentally.** A quoted sentence from inside a document is refused only if it happens to be title-shaped, which most prose is not.
- **A title split across lines is not detected.** The scanner works one line at a time.
- **A line longer than 100,000 characters is not scanned.** Scanning costs quadratic time in the length of a line, so this cap is measured rather than guessed: the worst case is 0.4 seconds at 100,000 characters, 3 seconds at 300,000, and 34 seconds at 1,000,000, with the figures recorded in `scan_lines`. The cap is 833 times the longest literal that can be title-shaped at all, so a pasted chunk of document content is scanned and a whole minified bundle on one line is not.
- **Only the added lines of the staged diff are read.** Content already in a file is not rescanned, so the five accepted files under `data/` and anything else already present are untouched by design.
- **It knows nothing about other repositories.** The private roots are firstmate's own layout.

The gaps share a shape: the guard stops the careless reproduction of a title next to a document reference, which is how this content actually travels, and it does not attempt to be a content classifier.

## It refuses rather than passes

The guard has three exit states, and two of them stop the commit:

- `0` evaluated, nothing to refuse
- `1` evaluated, refused, with the findings printed
- `2` **could not evaluate**, and therefore refused

A missing dependency, an unreadable commit-message file, a `git` invocation that fails, a directory that is not a repository, a scanner that errors, or a mode it does not recognise all produce exit `2` with a named reason.
There is no path on which the guard exits `0` because something went wrong.
A check that quietly steps aside is worse than no check, because it is believed.

`tests/fm-redaction-guard.test.sh` proves this: it puts the guard in seven separate unevaluable states and asserts it refuses each one.
Those states are an unrecognised mode, an unreadable message file, a missing dependency, a directory that is not a repository, a scanner that fails, a malformed invocation, and an unresolvable range.
The scanner case is the one that matters most, because a scanner failure is the only unevaluable state the guard reaches after it has already started reading content.

## Measured false-positive rate

Measured against this repository's real content, not invented examples, on 2026-08-20 over this branch's history and working tree.

| Corpus | Size | Refused by rule T | Refused by rule P |
| --- | --- | --- | --- |
| Every non-merge commit on every ref, diff and message together | 404 commits | 0 | 1 |
| Every added content line across all of history | 210,628 lines | 0 | not applicable |
| Every line of every tracked text file in the working tree | 168,491 lines in 392 files | 0 | not applicable |
| Every commit message on every ref, merges included | 406 commits, 9,319 lines | 0 | not applicable |

Rule T's false-positive rate on real repository content is **0**, across all four corpora.

The single rule P refusal is the repository's first commit, which staged `.no-mistakes/evidence/...` before that path was ignored.
Staging that path today would be a bypass, so this is a correct refusal applied retroactively rather than a false positive on current work.
No commit since has tripped either rule.

One genuine false-positive class was found during measurement and fixed: an ordinary cross-reference of the form `docs/<file>.md "Some Section"` read as a document context, because the anchor matched the `docs` path component.
Anchors no longer match inside a path or a filename, and `tests/fm-redaction-guard.test.sh` pins that case.

A zero measured on real content is only meaningful if the scanner can fire at all, so the same test suite runs a permanent positive control: the identical scanner, given one synthesised leak line, refuses it.
The measurement above was re-run after the diff parser was corrected, so the counts describe what the guard reads today rather than what an earlier parser happened to reach.

## The escape hatch

A finding is released by a trailer in the commit message, one per finding:

```
Redaction-Exception: <token> <reason of at least 20 characters>
```

The token is printed with the finding it belongs to.
It is derived from the rule, the location, and the exact offending literal.

The shape is chosen so it cannot become a habit:

- **It is per finding, never blanket.** `Redaction-Exception: all` releases nothing. Each finding needs its own token.
- **It is bound to the exact literal.** Change the text and the token changes, so a stale exception never covers a fresh leak in the same place.
- **It expires with the commit.** The next commit needs its own trailer. There is no file to set once and forget.
- **It is permanently visible.** It lives in the commit message, so it shows up in `git log`, in the PR, and in review, forever.
- **It requires a stated reason.** A reason under 20 characters is ignored and the finding stands.

The cost of using it is paid again on every use and is visible to everyone afterwards.
A configuration toggle would be paid once, in private, and would then protect nothing.

## Installing it

```
bin/fm-redaction-guard.sh install      # wire the commit-msg hook, idempotent
bin/fm-redaction-guard.sh uninstall    # remove it again
```

`install` refuses rather than overwriting a `commit-msg` hook it did not write.
Local hooks are per clone, so each home installs it once.
CI applies the same rules to every commit on a pull request, which is what stops a `--no-verify` commit from reaching the default branch.

## Maintaining this file

This document owns the coverage boundary, the gap list, the measurement, and the escape-hatch policy.
`bin/fm-redaction-guard.sh`'s header and `--help` own the modes, flags, and exit contract; do not restate them here.
When the rule changes, re-run the measurement above against current history and replace the table rather than appending a second one.
