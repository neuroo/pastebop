---
name: deslop
description: Strip AI-style slop from code and docs - comments that narrate, restate, hedge or tell war stories; docs on the obvious; abstractions with one caller; defensive noise; history that belongs in git. Use when asked to deslop, tighten, clean up, or before a release. Behaviour never changes.
---

# Deslop

Slop is text that costs the reader attention and pays back nothing. Generated
code is prone to it because generating an explanation is free; reading one is
not. This pass removes it without changing what the program does.

## What slop looks like

**Comments that restate the line.** If the code says it, the comment is noise.

```swift
// Increment the index
index += 1
```

**Narration.** The comment tells the story of writing the code rather than
explaining the code: "first we…", "now that…", "note that…", "hoisted so…".

**War stories.** "This was 60% slower until measured", "that turned X into Y".
The lesson may be worth keeping — as a *why*, in one clause — but the history
belongs in git, the test that guards it, or CLAUDE.md. Not inline.

**Docs on the obvious.** A doc comment on `count` that says "the count". A doc
comment on a private helper whose name already says everything. `/// Returns
true if enabled` on `isEnabled`.

**Hedging.** "Should be fine", "probably", "in most cases", "for now". Either
it is right, in which case say nothing, or it is a known gap, in which case
say exactly what the gap is.

**Markdown furniture in code.** Tables, headings and bullet lists inside doc
comments. One sentence beats a table the reader has to parse in a monospace
font.

**Abstractions with one caller.** A helper, protocol or type introduced "for
clarity" that has exactly one use and hides more than it names.

**Defensive noise.** Guards against states the type system already rules out.
`guard !array.isEmpty` before a loop that handles empty fine. `?? default` on
a value that cannot be nil.

**Section markers in small files.** `// MARK:` earns its place in a file you
scroll. In sixty lines it is clutter.

**Docs that repeat docs.** README says it, CLAUDE.md says it, the skill says
it, the file header says it. Say it once where it is looked for.

## What is not slop

Keep, and do not "tidy" away:

- **Why-comments on surprising code.** A non-obvious construct with a one-line
  reason: "not `padding(toLength:)`, which truncates". The reason, not the
  story.
- **Invariants the code depends on.** "Nothing below U+00A0 is ever rewritten,
  so this compare is safe." Delete that and the next person breaks it.
- **Safety and security rationale.** Why a flavour is skipped, why input is
  capped, why escaping comes from the active rules. These are the comments
  most worth having.
- **Public API docs.** A public type or method gets one clear sentence.
- **Test names.** Swift Testing names are sentences by design.

The test: cover the comment with your thumb. If you now have a question the
code cannot answer, the comment stays. If you have no question, it goes.

## Process

1. Read the file top to bottom. Do not skim; slop hides in the middle.
2. For each comment, apply the thumb test. For each helper, count callers.
3. Cut. Do not rephrase slop into shorter slop.
4. Where a war story guarded something real, make sure a test guards it
   instead, then delete the story.
5. Run everything. Behaviour must be identical:

```bash
swift test && swiftlint lint --strict
PASTEBOP_BENCHMARK=1 swift test -c release --filter Throughput
```

If a number moved, you changed behaviour. Put it back.

## Scope

One file at a time, whole file, then the next. A pass that touches every file
"a little" is how slop survives. Docs get the same treatment as code: the
README describes the app, not the sessions that built it.
