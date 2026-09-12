---
name: performance
description: Measure and protect PasteBop's scanner throughput. Use before and after any change to TextNormalizer, ScalarTable, HTMLTextRewriter or PasteboardNormalizer, or when asked about speed, benchmarks, or optimisation.
---

# Keeping PasteBop fast

The scanner runs on every copy the user makes. It is currently 200x faster than
the first working version, and every one of those gains came from measuring
rather than guessing.

## Measure first

```bash
PASTEBOP_BENCHMARK=1 swift test -c release --filter Throughput
```

Five profiles, because they stress different paths:

| Profile | Exercises | Current |
| --- | --- | --- |
| pure ascii | the reject-on-first-compare path | ~2900 MB/s |
| accented prose | decode + miss, no output built | ~2500 MB/s |
| ai prose | the real workload: mostly ASCII, some hits | ~700 MB/s |
| cjk | three-byte decode + miss on every scalar | ~380 MB/s |
| all rewrites | the output-building path | ~170 MB/s |

**Always run release mode.** Debug is roughly 10x slower and hides which path
is actually hot. Record the numbers before your change and after.

## The design being protected

- ASCII bytes are rejected with one compare. Nothing below `U+00A0` is
  rewritten, so this is safe by construction, not by luck.
- Unchanged runs between rewrites are copied as raw memory, never re-encoded
  scalar by scalar. Appending through `String.unicodeScalars` is 200x slower.
- Lookups go through dense arrays for the two blocks holding most rules, then a
  page bitmap, then a dictionary. The bitmap exists so CJK and emoji do not pay
  for a hash to be told "no".
- `ScalarTable` is a value fetched once per scan, not a namespace of
  `static let`s, because a lazy global costs a `swift_once` check per access.

## The slow path is styled text

The scanner is not the bottleneck for RTF; AppKit's decode and re-encode are,
at roughly 4 MB/s. Two rules follow:

- Build the rewritten `NSAttributedString` in **one forward pass**. A
  `replaceCharacters` per rewrite is quadratic and turns 17 MB into minutes.
- Anything past `inlineTextBytes` goes to a queue. Never do megabytes of RTF
  on the main thread: for the Services entry that freezes the app the user is
  typing in, not just PasteBop.

Measure the real thing through the real dispatch, not just the library call:

```bash
# with the app running and registered
swift - <<'EOF'
import AppKit
let pb = NSPasteboard(name: .init("probe"))
pb.clearContents(); pb.setString("a\u{2014}b", forType: .string)
print(NSPerformService("PasteBop/SelectBop", pb), pb.string(forType: .string) ?? "")
EOF
```

## The poll timer

A `changeCount` read is 0.8 µs; wakeups are the cost. The timer is a flat
100 ms with 25 ms leeway (`ClipboardMonitor.pollInterval`), chosen because it
is under human reaction time: a same-app copy is rewritten within 125 ms worst
case. Do not add adaptive back-off; ten fires a second bill under half a milliwatt, and a
slower idle band opens a race the user can see. The poll stays free because
no work is repeated: an unchanged count ends the poll, a change is claimed
before the scan, and the count our own write produces is adopted.

Measure with `Scripts/measure-idle.sh 60` against the installed app: it reads
the kernel's per-process accounting (`proc_pid_rusage`), so timer fires, CPU
time and billed energy are exact whatever else the machine is doing. Do not
use `top`'s `IDLEW`: it counts wakeups *from package idle* and reads 0 for
every variant on a busy machine. For latency, write curly text to the
pasteboard and watch `changeCount` at 1 ms until the ASCII appears; expect an
even spread between 0 and 125 ms (measured: 7–98 ms, median 63) and no second bump of the count afterwards.
## Rules

- Do not add a branch to `nextRewrite` for a feature that is not needed on
  every character. Counting lives in a separate pass for exactly this reason.
- Do not convert the byte scanner back to `Character` or `Unicode.Scalar`
  iteration for readability. It was measured; it is 200x.
- The bounded tripwires in `TextNormalizerTests` catch a collapse, not a 2x
  regression. They are not a substitute for reading the benchmark.
- A clipboard is usually a few kilobytes against a 100 ms poll budget, so do
  not trade correctness or clarity for speed that no user can perceive. If a
  change makes the code harder to follow for less than a 2x gain, drop it.
