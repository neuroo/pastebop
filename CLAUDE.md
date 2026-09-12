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
Scripts/make-demo.sh                         # regenerate the README demo gif
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
  table shipped in the binary, the README table and every character nobody has
  an opinion about come from it. Never add a lookup that reads anything else.
- **The file holds what someone changed, not the table.** `RewriteRules` is
  the defaults with a `RuleOverrides` laid over them, so a character no entry
  mentions keeps its built-in rule — which is how a new version's additions
  reach a Mac that already has a file.
- **At runtime the rules come from that combination, never from
  `Replacements.all` alone.** Everything that rewrites or describes text takes
  a `RewriteRules`. Reaching for the built-in table in app code would silently
  ignore the user's changes.
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

RTF is rewritten as bytes, like HTML: `RTFTextRewriter` decodes only the text
tokens (`\'hh`, `\uN`, `\emdash` and friends), scans them with the same
scanner, and splices the matches back, so control words, the font table and
anything AppKit does not model stay byte-identical. Only RTFD goes through
`NSAttributedString`; build that rewritten string in one forward pass, because
`replaceCharacters` per rewrite is quadratic in the attribute runs after it.

## State on disk

| Where | What |
| --- | --- |
| `UserDefaults` | settings and statistics: enabled, copy count, tally, counting-since |
| `~/Library/Application Support/PasteBop/rules.yaml` | the rewrite table, user editable, watched for changes |

Under the App Sandbox all of this moves inside the container
(`~/Library/Containers/info.neuroo.PasteBop/Data/…`), `UserDefaults`
included. That needs no code: `AppSupport.directory()` asks for
`.applicationSupportDirectory` and the sandbox resolves it, which is why
there is exactly one path derivation in the app and nothing that constructs
a path of its own.

Data does not carry over from an unsandboxed install, and **that is
accepted**. A sandboxed build cannot read the old location — it can stat it,
but opening is denied — so bringing it across would mean an `NSOpenPanel`,
the user picking the file being what grants access. Since the file now holds
only *changes*, anyone who has not customised anything loses nothing at all,
and the rest is a few switches. Not worth the only piece of code in the app
that would reach outside its own container.

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

## The demo gif

`Scripts/make-demo.sh` renders `img/demo.gif`. The before and after text, which
characters are boxed, and the menu lines all come from the real table and a
real `ActivityReport`, so the demo cannot claim something the app does not do.
Re-run it whenever the menu wording or the table changes.

## Polling

`changeCount` costs 0.8 µs to read; the cost of a poll is the wakeup. The
timer is a flat 100 ms with 25 ms leeway (`ClipboardMonitor.pollInterval`):
under human reaction time, so the rewrite lands before the fastest
copy-then-paste, with a 125 ms worst case. Do not add adaptive back-off. A
slower idle band opens a race the user can see in same-app copy-and-paste
(chat tab to mail tab in one browser), and what it would save does not
register: at ten fires a second the app bills under half a milliwatt and
0.005 % of a core.

What keeps ten polls a second free is never doing the same work twice. A poll
that finds the count unchanged touches nothing else. A change is claimed
before the scan starts, so later ticks do not re-read a large document being
rewritten off the main thread. The count produced by our own write is adopted
from the outcome, so the rewritten text is not scanned again.

**Measuring:** `Scripts/measure-idle.sh [seconds]` against the installed app.
It reads `proc_pid_rusage` for the running process — timer fires (interrupt
wakeups), CPU time, cycles, instructions and billed energy — all charged to
PasteBop alone, so the figures hold on a busy machine. Do not use `top`'s
`IDLEW`: it counts wakeups *from package idle* and reads zero for every
variant the moment anything else keeps the CPU awake.
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

## Threading

`NSPasteboard` is not safe off the main thread, so the work is split:
`snapshot` (main) reads the text flavours into a `Sendable` value, `rewrite`
(anywhere) transforms it, `apply` (main) writes it back. `apply` refuses if the
change count moved, so a slow rewrite can never clobber something copied while
it was running.

`PasteboardWork` decides where it runs. Under `inlineTextBytes` (256 KB) it is
done inline, because dispatching costs more than the work. Above it, the
clipboard path goes to a queue and never blocks, while the Services path goes
to a queue and *waits*, because the system reads the pasteboard the moment the
handler returns and there is nowhere to hand a late answer. The wait has a five
second deadline; past it the selection is left alone.

**SelectBop** declares `NSReturnTypes`, so macOS replaces the selection with
what comes back, and only offers it where the responder says the text is
editable. The app cannot detect editability itself: a service provider gets a
pasteboard and nothing else. A send-only companion for read-only text was
tried and removed — copying the text does the same job in one keystroke, and
the clipboard watcher is the whole app.

**A service pasteboard must be read one flavour at a time.** It belongs to the
app that invoked the service, and that app is blocked inside the call. Asking
it to materialise a derived flavour — which `pasteboardItems` plus
`data(forType:)` does while enumerating — waits on an app that is waiting on
you, and the service dies on the system's 30 second timeout. `normalizeSelection`
therefore uses `availableType(from:)` and reads exactly one type. There is a
test with a counting data provider asserting nothing else is touched.

## Security

The rules file is user-controlled input and the scanner walks raw bytes, so:

- `RuleFile.Limits` caps file size, rule count, substring length and
  replacement length. A pathological file must not make the scanner slow or
  the process large.
- HTML escaping of replacements comes from the table *in force*
  (`ScalarTable.htmlEscaped`), never from `Replacements.all`. A user rule
  outputting `<b>` must land in the clipboard's HTML flavour as text, not
  markup.
- Plain, attributed, HTML and RTF text share one scanner; `FuzzTests` asserts
  the attributed and RTF paths agree with plain text on every input, so no
  flavour can diverge from another.
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

**The file holds changes, not the table.** `decode` returns a `RuleOverrides`
and `RewriteRules` lays it over `Replacements.all`. An entry is `off` to leave
a character alone, or a quoted replacement — which overrides a default or adds
a character that had none. `off` is the only unquoted value, so `"off"` is
still the literal text.

Saying nothing is how you ask for the defaults, not how you turn everything
off. That inversion is the whole reason a new version's characters reach a Mac
that already has a file.

`RuleFile.encode` is hand-written because the per-character comments are the
point; a bare mapping of code points is accurate and unreadable. It aligns on
single-scalar keys and lets the rare range or substring key overflow, rather
than pushing every colon out to match the longest.

Round-tripping is tested: encode, decode, and the result must equal the
changes you started with; re-encoding must be byte-stable.

## The rules window

The window edits a `RuleSelection` and writes the file through the same path
as Restore Default Rules: write, reload, rebuild the watch.

Switching a rule off *removes* it, so the set on offer is fixed when editing
starts — everything in force, plus any default the file no longer carries, or
a family someone deleted by hand could never be switched back on. **The
in-force version of a rule wins over the built-in one**, so switching a
customised rule off and on again gives back their replacement, not the
default; restoring from `Replacements.all` would lose the edit silently. Any
subset of a valid table is valid, so the window cannot write a file the parser
would refuse — including the empty one, which leaves the clipboard untouched
rather than rewriting it to itself.

Writes are debounced, and the window reloads on any change to
`RuleStore.revision` — a hand edit picked up by the watcher, or a table
arriving from iCloud. Without that, the next switch would put a stale table
over whatever had landed.

## iCloud

The changes are settings, not a document, and there are usually a handful.
They sync through `NSUbiquitousKeyValueStore` — no file coordination, no
download states, no conflict versions, none of which the `O_EVTONLY` watcher
would survive.

**One key per changed character.** That is what makes iCloud keep both when
two Macs change different ones; a single blob would let last-writer-wins throw
one away before the other Mac ever saw it. The value is the same line the file
would hold, so what comes back is read by the same parser — and a line this
build cannot read is skipped rather than allowed to discard everything beside
it.

**The local file stays the source of truth.** A change arriving from iCloud is
written to it, so it reaches the rules through the same parse and the same
error reporting as an edit made by hand.

`RuleSync.merge` is a three-way merge against a **base**: the changes as they
stood when this Mac last agreed with iCloud, kept in `UserDefaults`. Without
it an entry missing here cannot be told apart from one this Mac has never
seen, and a newly signed-in Mac would erase everyone's changes. A character
only one side touched takes that side's answer; one both sides touched takes
this Mac's, so the machine someone is sitting at is never overruled. A missing
entry is a value like any other, which is how switching a character back on
travels instead of being put back by the other Mac.

The store holds 1024 keys, so a set past `maxSyncedEntries` stays local and
says so rather than syncing half of itself.

`RuleStore.revision` is still load-bearing: the window writes the *whole* set
of changes, so a window showing a stale set would revert whatever arrived
while it was open. It reloads when the revision moves.

**Off in every default build, and it has to be.** The container belongs to
this project's team, so a build signed with anyone else's certificate — or
ad-hoc, which is what building from source gives you — has no profile
granting it. Shipping it on by default would hand contributors a broken app
rather than a feature.

Two gates, so neither alone can go wrong:

- `PASTEBOP_ICLOUD` compiles it in. Unset everywhere except
  `PASTEBOP_ICLOUD=1 Scripts/build-app.sh`; without it the code is not in the
  binary at all and `standard(store:)` returns `NoCloud`.
- The entitlement makes the store usable. Even with the flag, the app checks
  for `com.apple.developer.ubiquity-kvstore-identifier` at runtime and falls
  back to `NoCloud`. Reaching `NSUbiquitousKeyValueStore` without the
  entitlement is not reliably a no-op.

Turning it on needs an App ID with iCloud key-value storage, a provisioning
profile granting the container, and the entitlement. All three exist for this
project, and the path has been run end to end: a change published, then the
local file *and* the recorded base deleted, and the change came back from
iCloud on relaunch.

```bash
PASTEBOP_ICLOUD=1 PASTEBOP_PROFILE=<profile> CODESIGN_IDENTITY=<identity> Scripts/build-app.sh
```

`Scripts/find-profile.sh` locates the profile when `PASTEBOP_PROFILE` is not
set. The build refuses ad-hoc signing, a missing profile, a profile for
another bundle or one that does not grant the container, and finally checks
the entitlement survived into the signature — an entitlement that silently
fails to land produces an app that launches and never syncs.

Key-value storage **is** available to Developer ID builds, not App Store only.

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
