# PasteBop

A macOS menu bar app that rewrites typographic and invisible characters on the
clipboard into the ones on a keyboard. Apple silicon, macOS 14+, Swift 6.

## Commands

```bash
swift test                                    # the suite, ~0.05s
swift test -c release                         # release mode, where the fast paths exist
swiftlint lint --strict                       # must be zero before committing
Scripts/build-app.sh                          # dist/PasteBop.app, arm64, ad-hoc signed
Scripts/package.sh                            # .dmg and .zip
swift Scripts/make-icons.swift                # regenerate App/ assets from img/
swift Scripts/make-dmg-background.swift      # regenerate the disk image background
Scripts/make-dmg-layout.sh                   # regenerate the disk image window layout
PASTEBOP_BENCHMARK=1 swift test -c release --filter Throughput
```

Dead-code rules need a compiler log:

```bash
swift build --build-tests -v > /tmp/build.log 2>&1
swiftlint analyze --strict --compiler-log-path /tmp/build.log
```

## Layout

| Path | What it is |
| --- | --- |
| `Sources/PasteBopCore` | the table, scanner, and pasteboard handling. All the testable logic, no UI. |
| `Sources/PasteBop` | the menu bar app. SwiftUI `MenuBarExtra`, clipboard monitor, login item. |
| `App/` | `Info.plist`, asset catalog, icon set |
| `Scripts/` | build, package, version, icon generation |

## Invariants

These are what the tests actually protect. Breaking one is a silent
correctness bug, not a style issue.

- **`Replacements.all` is the single source of truth** for the *defaults*. The
  table shipped in the binary, the file written on first launch and the README
  table all come from it. Never add a lookup that reads anything else.
- **At runtime the rules come from the file, not from `Replacements.all`.**
  Everything that rewrites or describes text takes a `RewriteRules`. Reaching
  for the built-in table in app code would silently ignore the user's edits.
- **A bad rules file must never stop PasteBop working.** Parsing keeps the last
  rules that worked and surfaces the line number; it does not fall back to the
  defaults, because that would silently undo someone's edits mid-keystroke.
- **No single-scalar rule fires below `U+00A0`.** The scanner rejects ASCII
  with one compare, so the parser refuses such rules rather than accept ones
  that would never fire. Only an ASCII-leading substring rule changes that,
  and it moves the scanner to a slower loop while it exists.
- **Every built-in replacement is ASCII**, and none contains a character the
  built-in table rewrites, so one pass over the defaults reaches a fixed point.
  User rules are not held to this; the scanner never re-scans its own output,
  so they cannot loop, only leave a character un-normalised.
- **Ask the rule set in force, never the built-in table.** Anything describing
  the rules goes through `RewriteRules`, so a customised table can never be
  described by the default one.
- **Be conservative.** A wrong rewrite corrupts someone's text silently. When
  a character is meaningful anywhere (accented letters, ZWNJ/ZWJ, LRM/RLM, CJK
  punctuation, `·`), leave it alone and say why in the table's doc comment.

## Speed

The scanner runs on every copy, so it stays a byte scanner: ASCII rejected with
a single compare, unchanged runs copied as raw memory, lookups through dense
per-block arrays with a page bitmap in front of the long tail.

Measure before and after any change to `TextNormalizer` or `ScalarTable`, in
release mode, with `PASTEBOP_BENCHMARK=1 swift test -c release --filter
Throughput`. The tripwires in `TextNormalizerTests` catch a collapse, not a
2x regression. Two things that look harmless and are not: formatting any
string inside the scanner's loop, and giving `Hit` a refcounted field.

## State on disk

| Where | What |
| --- | --- |
| `UserDefaults` | settings and statistics: enabled, copy count, tally, counting-since |
| `~/Library/Application Support/PasteBop/rules.yaml` | the rewrite table, user editable, watched for changes |
| `~/Library/Application Support/PasteBop/update-state.json` | when updates were last checked, and the newest release the user has been told about |

Settings belong in `UserDefaults`. Application Support is for state a user
might reasonably open, edit or delete by hand, so it is readable JSON with
ISO 8601 dates — set the encoder *and* the decoder, or the state silently
resets every launch.

## Substring rules

A rule matches one scalar, a range, or a substring (`Pattern`). Substrings are
indexed by first scalar and tried longest-first before the single-scalar
lookup, so they always win for their first character. Two flags on
`ScalarTable` keep the default table on the fast path: `hasSequences` (false
by default, skips matching entirely) and `hasASCIISequenceStarts` (false
unless a substring begins with ASCII, the one case where ASCII bytes cannot
be skipped blind). The scanner has two loop shapes and picks by that flag
*outside* the loop.

Single-scalar rules below `U+00A0` are refused by the parser, not ignored by
the scanner: accepting a rule that can never fire is a silent lie.

## Provenance

`Provenance` guesses where a copy came from out of `RewriteTally` and the
character count, both of which were computed anyway. It reads integers, never
text, so there is no privacy story to tell and no network call to justify.

What it measures is typographic polish. A word processor produces that too,
so **variety across marker families is the discriminator, not volume** — one
family used heavily is autocorrect, three families together is a language
model. Keep the wording hedged ("reads machine-written", not "is AI"): the
heuristic is wrong about anyone who types em dashes by hand.

Not yet built: the lifetime "Clipboard Wrapped" write-up. That is the one
place an API call would earn its keep, since it would ship only aggregate
integers and prose is what a model is good at. It needs a key and a privacy
story, so it is a deliberate next step rather than an omission.

## Security

The rules file is user-controlled input and the scanner walks raw bytes, so:

- `RuleFile.Limits` caps file size, rule count, substring length and
  replacement length. A pathological file must not make the scanner slow or
  the process large.
- HTML escaping of replacements comes from the table *in force*
  (`ScalarTable.htmlEscaped`), never from `Replacements.all`. A user rule
  outputting `<b>` must land in the clipboard's HTML flavour as text, not
  markup.
- Plain and attributed text share one scanner; `FuzzTests` asserts they agree
  on every input, so RTF can never diverge from plain text.
- `FuzzTests` throws seeded garbage at the parser (only `ParseError` may come
  back) and the scanner (never a crash, never a read past the end). Replay a
  failure from its seed.
- The workflow reads the `workflow_dispatch` version through `env:`, never
  `${{ }}` inside `run:`, which would splice free text into the shell.
- Workflows are least-privilege (`contents: read`, raised to `write` only on
  the job that creates a release), check out with `persist-credentials: false`
  so the token is not left in `.git/config` for the build to find, and pin
  every action to a commit SHA.
- Both workflows must stay clean under `actionlint` and
  `zizmor --persona=pedantic`. Install with `brew install actionlint zizmor`.

## Rules file

`RuleFile` parses a small subset of YAML in-process rather than depending on a
YAML library, since the schema is a flat mapping and a dependency would be the
only third-party code here. The cost is that valid-but-unsupported YAML is
rejected, so **every rejection must name the line and say what was expected**.

`RuleFile.encode` is hand-written for the same reason a serialiser will not do:
the grouping and the per-character comments are the point. A file of 258 bare
mappings would be accurate and unusable.

Round-tripping is tested: encode, decode, and the result must equal the table
you started with; re-encoding must be byte-stable.

## Updates

A weekly background check plus a manual one from the menu. It never installs
anything: builds are ad-hoc signed, so replacing the binary behind the user's
back is exactly the thing signing is meant to stop. The scheduled check is
silent unless there is news and never repeats itself; the manual one always
reports, because the user just asked.

Checks need a public repository. GitHub answers 404 for anonymous requests to
a private one, which is surfaced as a plain-English message rather than a
mystery failure.

## Dependencies

- **Pin every GitHub Action to a full commit SHA**, with the version as a
  trailing comment. A tag is mutable and a moving `uses:` is a supply-chain
  hole. Dependabot updates both the SHA and the comment weekly.
- Keep dependencies current and free of known advisories. The package currently
  has **no third-party Swift dependencies** — keep it that way unless something
  genuinely cannot be written in a few dozen lines.
- `Package.resolved` is SwiftPM's lockfile. It does not exist yet because there
  is nothing to lock; **commit it** as soon as a dependency is added, since this
  is an app rather than a library. CI runs
  `swift build --only-use-versions-from-resolved-file`, which fails on a
  missing or stale lockfile, so a dependency can never be silently upgraded.
- CI runs on `macos-latest` with the preinstalled toolchain.

## Releasing

Versions are dates: `2026.09.11`, with a fourth component for a second release
the same day. `CFBundleVersion` is the zero-padded `YYYYMMDDNN`.

```bash
Scripts/bump-version.sh
git commit -am "Release $(cat VERSION)"
git tag "v$(cat VERSION)" && git push --follow-tags
```

The release workflow refuses to run if `VERSION` and the tag disagree, and
runs `Scripts/verify-release.sh` before publishing: it mounts the disk image
and checks the app is present, signed, the right version and architecture.

GitHub immutable releases are planned but not yet enabled. The workflow already
suits them -- a single `gh release create` with both assets, no later `upload`
or `edit`, no tag rewriting -- so turning it on is a repository setting rather
than a change here. Once on, a bad release can only be superseded by a new
version, never repaired, which is what the pre-publish verification is for.

The `.dmg` opens to a laid-out window: background, app on the left, Applications
alias on the right. That layout is a committed `.DS_Store` (`App/dmg/DS_Store`)
because Finder stores window geometry there and the background is referenced by
an alias embedding the volume path — which is why the volume name is the fixed
string `PasteBop` and must not gain a version. Regenerating it needs a mounted
scratch volume and a Python package, so it is done by hand and committed;
`Scripts/package.sh` only copies it, and CI needs nothing but `hdiutil`.

## Conventions

- The repository has a single author. Do not add co-author trailers, tool
  attribution, or "generated by" notes to commits, code, or docs.
- Comments explain *why*, not *what*. If a line needs a comment to say what it
  does, rewrite the line. History belongs in git and tests, not inline; the
  `deslop` skill has the full test.
- Tests assert behaviour. A test that cannot fail is noise: delete it.
