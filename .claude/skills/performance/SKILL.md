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

## Rules

- Do not add a branch to `nextRewrite` for a feature that is not needed on
  every character. Counting lives in a separate pass for exactly this reason.
- Do not convert the byte scanner back to `Character` or `Unicode.Scalar`
  iteration for readability. It was measured; it is 200x.
- The bounded tripwires in `TextNormalizerTests` catch a collapse, not a 2x
  regression. They are not a substitute for reading the benchmark.
- A clipboard is usually a few kilobytes against a 250 ms poll budget, so do
  not trade correctness or clarity for speed that no user can perceive. If a
  change makes the code harder to follow for less than a 2x gain, drop it.
