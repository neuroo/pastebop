---
name: rewrite-rules
description: Add, remove or change a character in PasteBop's rewrite table. Use when asked to make PasteBop handle a new character, stop rewriting something, or change what a character becomes.
---

# Changing the rewrite table

There are two ways a rule changes, and they are not the same job.

**A user changing their own copy** edits
`~/Library/Application Support/PasteBop/rules.yaml`, which is watched and
applied on save. Nothing in this repository needs to change for that, and the
answer to "make PasteBop stop rewriting X for me" is to delete that line.

**Changing what PasteBop ships with** is what follows.

`Sources/PasteBopCore/Replacements.swift` is the single source of truth. The
lookup structures, the Help window and the README table are all derived from
it. Edit it and nothing else.

## Adding a rule

Put it in the family it belongs to, keep the list in code-point order, and give
the real Unicode name:

```swift
Replacement(0x2014, "--", "EM DASH", .dashes),
```

A contiguous block uses the range form:

```swift
Replacement(0xE0000...0xE007F, "", "TAG CHARACTERS", .invisibles),
```

A substring uses `Pattern.sequence`. Be sparing: every substring rule that
starts with an ASCII character moves the whole scanner off its fastest loop
while that rule exists.

```swift
Replacement(pattern: .sequence([0x20, 0x2014, 0x20]), output: " - ",
            name: "SPACED EM DASH", category: .dashes),
```

An empty output deletes the character. That is different from having no rule.

## The bar for adding one

PasteBop rewrites text people did not ask it to touch, so a wrong rule corrupts
someone's writing silently. Before adding one, answer:

1. **Is the character ever meaningful?** Accented letters are typable on
   international layouts. `U+200C` and `U+200D` are load-bearing in Persian,
   Hindi and emoji sequences. `U+200E`/`U+200F` do real work in right-to-left
   text. `·` is a letter in Catalan. CJK punctuation is correct punctuation.
   If the answer is yes anywhere, do not add it -- and record why in the
   "deliberately not rewritten" comment at the top of the table.
2. **Is the replacement typable ASCII?** If not, the rule is wrong.
3. **Does the replacement contain a character the table rewrites?** If so, one
   pass will not reach a fixed point.

The invisible bidi characters the table *does* delete are the embeddings,
overrides and isolates used in Trojan Source attacks, plus the tag block used
to smuggle hidden instructions. Those have no legitimate use in copied text.

## After editing

```bash
swift test
```

The round-trip tests also check that the table survives being written to a
rules file and read back, so a new rule needs no extra work there.

The table tests check the invariants automatically: no duplicate scalars, every
rule above the ASCII floor, every replacement typable ASCII, no replacement
that reintroduces a rewritten character, every rule reachable at both ends of
its range, and a list of characters that must never be rewritten.

Then update the table and the total in `README.md`. The family counts come from:

```bash
swift test -c release --filter "Replacement table"
```

and the total is `RewriteRules.builtIn.scalarCount`.

## Removing a rule

Delete the line. If it was removed because the character is meaningful, add it
to the "deliberately not rewritten" comment and to the `preservedCharacters`
test, so nobody adds it back next year.
